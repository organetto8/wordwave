import AppKit
import UserNotifications

/// Posts a system notification per transcribed voice note and routes clicks back to the store.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let noteIDKey = "noteID"
    nonisolated private static let releasePageKey = "releasePage"
    nonisolated private static let betaOfferKey = "betaOffer"

    var onOpen: ((Int64) -> Void)?
    var onBetaOffer: (() -> Void)?

    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ note: VoiceNote) {
        let content = UNMutableNotificationContent()
        content.title = note.groupName.map { "\(note.senderName) · \($0)" } ?? note.senderName
        content.subtitle = String(localized: "Voice message · \(note.durationSeconds.durationLabel)")
        content.body = note.transcriptText ?? String(localized: "Transcript not available")
        content.sound = .default
        content.userInfo = [Self.noteIDKey: note.id]
        center.add(UNNotificationRequest(identifier: Self.identifier(note.id), content: content, trigger: nil))
    }

    /// Shown once after an update relaunched Wordwave; a click opens the release notes.
    func postUpdate(to version: ReleaseVersion, from previous: ReleaseVersion, releasePage: URL) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Wordwave updated to \(version.description)")
        content.body = String(localized: "From version \(previous.description). Click to see what's new.")
        content.userInfo = [Self.releasePageKey: releasePage.absoluteString]
        center.add(UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil))
    }

    /// A beta is out: the notification only announces it, and a click opens the choice.
    func postBetaAvailable(_ version: ReleaseVersion) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Wordwave \(version.description) beta is available")
        content.body = String(localized: "Click to choose whether to install it. Betas never install on their own.")
        content.userInfo = [Self.betaOfferKey: true]
        center.add(UNNotificationRequest(identifier: "beta-\(version)", content: content, trigger: nil))
    }

    func remove(noteID: Int64) {
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(noteID)])
    }

    private static func identifier(_ id: Int64) -> String { "voice-note-\(id)" }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let userInfo = response.notification.request.content.userInfo
        if let page = (userInfo[Self.releasePageKey] as? String).flatMap(URL.init(string:)), page.host() == "github.com" {
            await MainActor.run { _ = NSWorkspace.shared.open(page) }
        } else if userInfo[Self.betaOfferKey] as? Bool == true {
            await MainActor.run { onBetaOffer?() }
        } else if let id = userInfo[Self.noteIDKey] as? Int64 {
            await MainActor.run { onOpen?(id) }
        }
    }
}

extension Int {
    /// `75` → `1:15`.
    var durationLabel: String {
        String(format: "%d:%02d", self / 60, self % 60)
    }
}
