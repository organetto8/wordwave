import AppKit
import OSLog

/// Keeps Wordwave current from its GitHub releases. Every few hours, or when asked, it reads the release list.
/// A newer stable version is downloaded, checked against the release key in Info.plist
/// (`WordwaveUpdatePublicKey`) and installed by itself as soon as Wordwave is idle. A newer beta is only
/// announced: it installs only if the user chooses it. Debug builds, builds without the key and copies outside an
/// Applications folder never check on their own.
@MainActor
final class Updater {
    static let repository = "organetto8/wordwave"
    private static let interval: TimeInterval = 6 * 3600
    /// After a failed check (offline, GitHub busy) the next one waits this long, not a minute.
    private static let retryInterval: TimeInterval = 3600

    private enum Keys {
        static let lastCheck = "lastUpdateCheck"
        static let skippedBeta = "skippedBetaVersion"
        static let postponedBeta = "postponedBetaVersion"
        static let postponedBetaAt = "postponedBetaDate"
        static let updatedFrom = "updatedFromVersion"
        static let rejected = "rejectedUpdateVersions"
    }

    /// The public half of the release key; only the maintainer's keychain holds the private half.
    static let publicKey: Data? = {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "WordwaveUpdatePublicKey") as? String,
              let key = Data(base64Encoded: text), key.count == 32 else { return nil }
        return key
    }()

    static let installedVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        .flatMap { ReleaseVersion($0) }

    static var isAvailable: Bool { publicKey != nil && installedVersion != nil }

    /// Only an installed Release build looks for updates on its own.
    static var checksAutomatically: Bool {
        #if DEBUG
        false
        #else
        isAvailable && Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Applications"
        #endif
    }

    static func releasePage(_ version: ReleaseVersion) -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/v\(version)")!
    }

    /// Whether relaunching now would interrupt the user (a transcription running, a window or the panel open).
    var isBusy: () -> Bool = { false }
    /// Tells the user a beta is out without interrupting them; choosing it calls `presentBetaOffer()`.
    var announceBeta: (ReleaseVersion) -> Void = { _ in }

    var lastCheck: Date? { UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date }

    /// A stable update, downloaded and verified, waiting for Wordwave to be idle.
    private var pending: PreparedUpdate?
    /// The beta last announced, until the user answers.
    private var offeredBeta: UpdateRelease?
    private var checking = false
    private var nextCheck = Date.distantPast
    /// The version last offered as a manual download, so the periodic check doesn't repeat itself.
    private var announced: ReleaseVersion?
    private var schedule: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.ssquillante.Wordwave", category: "updates")

    /// The first check comes shortly after launch. Then, every minute, the release list is read again once it is
    /// due (also while an update waits, so a withdrawn or superseded release never installs), and a waiting
    /// update installs if Wordwave is idle.
    func start() {
        guard Self.checksAutomatically, schedule == nil else { return }
        nextCheck = (lastCheck ?? .distantPast).addingTimeInterval(Self.interval)
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                guard let self else { return }
                if Date.now >= self.nextCheck { await self.check(userInitiated: false) }
                if let pending = self.pending, !self.isBusy() { self.install(pending) }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// The version this copy was updated from, once, right after an update relaunched it.
    func takeUpdatedFrom() -> ReleaseVersion? {
        defer { UserDefaults.standard.removeObject(forKey: Keys.updatedFrom) }
        guard let text = UserDefaults.standard.string(forKey: Keys.updatedFrom), let previous = ReleaseVersion(text),
              let installed = Self.installedVersion, previous != installed else { return nil }
        return previous
    }

    /// A check the user asked for reports every outcome and asks before relaunching; the periodic one stays silent
    /// unless there is something the user must act on.
    func check(userInitiated: Bool) async {
        guard let publicKey = Self.publicKey, let installed = Self.installedVersion else {
            if userInitiated {
                inform(String(localized: "This copy of Wordwave can't update itself"),
                       String(localized: "It was built without the release key. Download Wordwave from its GitHub releases instead."))
            }
            return
        }
        guard !checking else { return }
        checking = true
        defer { checking = false }

        let candidates: UpdateCandidates
        do {
            candidates = try await UpdateFeed.candidates(repository: Self.repository, after: installed)
        } catch {
            nextCheck = Date.now.addingTimeInterval(Self.retryInterval)
            logger.error("update check failed: \(error.localizedDescription, privacy: .public)")
            if userInitiated { inform(String(localized: "Couldn't check for updates"), error.localizedDescription) }
            return
        }
        UserDefaults.standard.set(Date.now, forKey: Keys.lastCheck)
        nextCheck = Date.now.addingTimeInterval(Self.interval)

        let rejected = rejectedVersions
        // Newest first; a release that fails verification is skipped for good, so it can't hide an older genuine one.
        for stable in candidates.stables where !rejected.contains(stable.version.description) {
            switch await prepare(stable, publicKey: publicKey) {
            case .ready(let update):
                if userInitiated { confirmInstall(update, installed: installed) }
                return
            case .rejected:
                continue
            case .failed(let error):
                nextCheck = Date.now.addingTimeInterval(Self.retryInterval)
                offerDownload(stable.version, reason: error, userInitiated: userInitiated)
                return
            }
        }
        discardPending()
        if let beta = candidates.betas.first(where: { !rejected.contains($0.version.description) }) {
            offerBeta(beta, userInitiated: userInitiated)
        } else if userInitiated {
            inform(String(localized: "Wordwave is up to date"), String(localized: "Version \(installed.description)"))
        }
    }

    // MARK: - Stable: automatic

    private enum Preparation {
        case ready(PreparedUpdate)
        /// Not a genuine release: bad signature, wrong contents, or too large.
        case rejected
        case failed(any Error)
    }

    /// Downloads and verifies `release`, unless it is already waiting. A waiting update is replaced only once a
    /// newer one has verified.
    private func prepare(_ release: UpdateRelease, publicKey: Data) async -> Preparation {
        if let pending, pending.version == release.version { return .ready(pending) }
        do {
            let update = try await UpdateInstaller.prepare(release, repository: Self.repository, publicKey: publicKey,
                                                           replacing: Bundle.main.bundleURL)
            discardPending()
            pending = update
            logger.info("update \(release.version.description, privacy: .public) downloaded and verified")
            return .ready(update)
        } catch let error as UpdateError where error.isVerificationFailure {
            reject(release.version, error)
            return .rejected
        } catch {
            logger.error("update \(release.version.description, privacy: .public) not prepared: \(error.localizedDescription, privacy: .public)")
            return .failed(error)
        }
    }

    /// Asked for by hand: the user decides when to relaunch. "Later" leaves it to the idle install.
    private func confirmInstall(_ update: PreparedUpdate, installed: ReleaseVersion) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Wordwave \(update.version.description) is ready to install")
        alert.informativeText = String(localized: "You have version \(installed.description). The new version was downloaded from GitHub and its signature verified. Wordwave will quit and open again; a transcription in progress starts over.")
        alert.addButton(withTitle: String(localized: "Install and Relaunch"))
        alert.addButton(withTitle: String(localized: "Later"))
        alert.addButton(withTitle: String(localized: "What's New"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(update)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(Self.releasePage(update.version))
        default: break
        }
    }

    private func install(_ update: PreparedUpdate) {
        if pending?.version == update.version { pending = nil }
        Task {
            do {
                try await UpdateInstaller.install(update)
                UpdateInstaller.discard(update)
                UserDefaults.standard.set(Self.installedVersion?.description, forKey: Keys.updatedFrom)
                logger.info("installed \(update.version.description, privacy: .public), relaunching")
                AppRelaunch.now()
            } catch UpdateError.outdated {
                UpdateInstaller.discard(update)
            } catch UpdateError.restoreFailed(let path) {
                // The staging folder holds the previous version: it is kept, and shown to the user.
                logger.fault("update swap and restore both failed")
                inform(String(localized: "Wordwave couldn't finish the update"), UpdateError.restoreFailed(path).localizedDescription)
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } catch {
                UpdateInstaller.discard(update)
                logger.error("install failed: \(error.localizedDescription, privacy: .public)")
                offerDownload(update.version, reason: error, userInitiated: true)
            }
        }
    }

    private func discardPending() {
        if let pending { UpdateInstaller.discard(pending) }
        pending = nil
    }

    // MARK: - Beta: only on request

    /// The periodic check only announces a beta (a notification, at most once a day, never after "Skip This Beta");
    /// the choice itself is always an alert the user opened.
    private func offerBeta(_ beta: UpdateRelease, userInitiated: Bool) {
        offeredBeta = beta
        if userInitiated {
            presentBetaOffer()
            return
        }
        let defaults = UserDefaults.standard
        let version = beta.version.description
        if defaults.string(forKey: Keys.skippedBeta) == version { return }
        if defaults.string(forKey: Keys.postponedBeta) == version,
           let postponed = defaults.object(forKey: Keys.postponedBetaAt) as? Date, Date.now.timeIntervalSince(postponed) < 24 * 3600 { return }
        defaults.set(version, forKey: Keys.postponedBeta)
        defaults.set(Date.now, forKey: Keys.postponedBetaAt)
        announceBeta(beta.version)
    }

    func presentBetaOffer() {
        guard let beta = offeredBeta, let publicKey = Self.publicKey, let installed = Self.installedVersion else { return }
        let version = beta.version.description
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Wordwave \(version) beta is available")
        alert.informativeText = String(localized: "You have version \(installed.description). Betas are test versions and can have bugs: Wordwave installs one only if you ask. The download is checked against Wordwave's release key, then Wordwave quits and opens again.")
        alert.addButton(withTitle: String(localized: "Install Beta"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        alert.addButton(withTitle: String(localized: "Skip This Beta"))
        alert.addButton(withTitle: String(localized: "What's New"))
        // Return must never mean yes to a beta: "Not Now" is the default button.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        let defaults = UserDefaults.standard
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            offeredBeta = nil
            Task { await installBeta(beta, publicKey: publicKey) }
        case .alertSecondButtonReturn:
            defaults.set(version, forKey: Keys.postponedBeta)
            defaults.set(Date.now, forKey: Keys.postponedBetaAt)
        case .alertThirdButtonReturn:
            offeredBeta = nil
            defaults.set(version, forKey: Keys.skippedBeta)
        default:
            NSWorkspace.shared.open(Self.releasePage(beta.version))
        }
    }

    private func installBeta(_ beta: UpdateRelease, publicKey: Data) async {
        do {
            install(try await UpdateInstaller.prepare(beta, repository: Self.repository, publicKey: publicKey,
                                                      replacing: Bundle.main.bundleURL))
        } catch let error as UpdateError where error.isVerificationFailure {
            reject(beta.version, error)
            inform(String(localized: "The beta wasn't installed"), error.localizedDescription)
        } catch {
            offerDownload(beta.version, reason: error, userInitiated: true)
        }
    }

    // MARK: - Rejected releases

    /// Versions whose download failed verification. They are never downloaded again or shown to the user.
    private var rejectedVersions: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Keys.rejected) ?? [])
    }

    private func reject(_ version: ReleaseVersion, _ error: UpdateError) {
        logger.error("release \(version.description, privacy: .public) failed verification: \(error.localizedDescription, privacy: .public)")
        var list = UserDefaults.standard.stringArray(forKey: Keys.rejected) ?? []
        if !list.contains(version.description) { list.append(version.description) }
        UserDefaults.standard.set(Array(list.suffix(20)), forKey: Keys.rejected)
    }

    // MARK: - Alerts

    /// Points to the release page when Wordwave can't install a genuine update by itself. A periodic check speaks
    /// only when the user can fix it (the app's location or App Management), and once per version.
    private func offerDownload(_ version: ReleaseVersion, reason: any Error, userInitiated: Bool) {
        let actionable = (reason as? UpdateError).map { $0 == .cannotReplace || $0 == .notPermitted } ?? false
        guard userInitiated || (actionable && announced != version) else { return }
        announced = version
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Wordwave \(version.description) is available")
        alert.informativeText = reason.localizedDescription
        alert.addButton(withTitle: String(localized: "Open Download Page"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(Self.releasePage(version)) }
    }

    private func inform(_ title: String, _ detail: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}

enum AppRelaunch {
    /// Opens a fresh copy once this one has quit, so the new version is the one that runs.
    @MainActor
    static func now() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
