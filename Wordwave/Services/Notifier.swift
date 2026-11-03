import Foundation
import UserNotifications

/// Posts a system notification per transcribed voice note and routes clicks back to the store.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let noteIDKey = "noteID"

    var onOpen: ((Int64) -> Void)?

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
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = response.notification.request.content.userInfo[Self.noteIDKey] as? Int64 else { return }
        await MainActor.run { onOpen?(id) }
    }
}

extension Int {
    /// `75` → `1:15`.
    var durationLabel: String {
        String(format: "%d:%02d", self / 60, self % 60)
    }
}
