import AppKit

enum WhatsAppOpener {
    /// Opens the 1:1 chat via deep link when the phone number is known, otherwise just brings WhatsApp to front.
    /// WhatsApp exposes no public link to a specific message or group, so that is the closest we can get.
    @MainActor
    static func openChat(for note: VoiceNote) {
        if let phone = note.phoneNumber, let url = URL(string: "whatsapp://send?phone=\(phone)") {
            NSWorkspace.shared.open(url)
        } else {
            openApp()
        }
    }

    @MainActor
    static func openApp() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: WhatsAppPaths.bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}
