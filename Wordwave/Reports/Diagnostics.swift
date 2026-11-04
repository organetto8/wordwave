import AppKit
import OSLog
import ServiceManagement
import UserNotifications

/// Plain-text facts for a bug report: versions, system, settings and counts. No names, phone numbers, chats or
/// transcripts, so it is safe to paste in a public issue.
@MainActor
enum Diagnostics {
    static func report(store: VoiceNoteStore, updater: Updater) async -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let whatsApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: WhatsAppPaths.bundleIdentifier)
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "not installed"
        let notifications = switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional: "allowed"
        case .denied: "denied"
        case .notDetermined: "not asked yet"
        default: "?"
        }
        let notes = store.notes
        let failed = notes.count(where: { if case .failed = $0.transcription { true } else { false } })
        let waiting = notes.count(where: { $0.transcription == .waitingForAudio })
        let updates = !Updater.isAvailable ? "not available in this build"
            : (Updater.checksAutomatically ? "automatic" : "manual only (not in an Applications folder)")
            + (updater.lastCheck.map { ", last check \($0.formatted(.iso8601))" } ?? "")
        let chatState = await store.chatStateSummary() ?? "not read yet"
        let errors = await recentErrors()

        // English labels, whatever language the app shows: the report is read by the maintainer.
        let report = """
        Wordwave \(version) (\(build))
        macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(sysctl("kern.osversion"))) · \(sysctl("hw.model")) · \(sysctl("machdep.cpu.brand_string"))
        Language: \(Bundle.main.preferredLocalizations.first ?? "?") (system \(Locale.preferredLanguages.first ?? "?"))
        Transcription: \(await Transcriber.diagnosticSummary())
        WhatsApp Desktop: \(whatsApp) · data access: \(statusText(store.status))
        Notifications: \(notifications) · launch at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")
        Updates: \(updates)
        Voice notes: \(notes.count) kept, \(store.unseenCount) unread, \(waiting) waiting for audio, \(failed) failed
        Muted or archived chats: \(store.skippedCount) voice notes skipped since launch · \(chatState)
        Recent errors: \(errors.isEmpty ? "none" : "\n" + errors.map { "  \($0)" }.joined(separator: "\n"))
        """
        // Any error text in it could name a file in the home folder: the user name stays out of a public issue.
        return report.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func statusText(_ status: VoiceNoteStore.Status) -> String {
        switch status {
        case .starting: "starting"
        case .running: "granted"
        case .needsAccess: "blocked by macOS"
        case .error(let message): "error (\(message))"
        }
    }

    /// The last errors Wordwave logged since it started. They hold system error text, never message content.
    private static func recentErrors() async -> [String] {
        await Task.detached(priority: .utility) {
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
                  let entries = try? store.getEntries(matching: NSPredicate(format: "subsystem == %@", "com.ssquillante.Wordwave")) else { return [] }
            let errors = entries.compactMap { $0 as? OSLogEntryLog }.filter { $0.level == .error || $0.level == .fault }
            return errors.suffix(10).map { "\($0.date.formatted(.iso8601)) [\($0.category)] \($0.composedMessage)" }
        }.value
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
