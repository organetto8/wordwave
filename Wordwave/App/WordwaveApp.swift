import AppKit
import ServiceManagement
import SwiftUI

@main
struct WordwaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: appDelegate.store)
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let notifier = Notifier()
    lazy var store = VoiceNoteStore(notifier: notifier)

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifier.onOpen = { [weak self] id in self?.store.open(noteID: id) }
        notifier.requestAuthorization()
        store.start()
        enableLaunchAtLoginOnFirstInstall()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-window") { showPreviewWindow() }
        #endif
    }

    /// Turns on launch at login the first time the app runs from an Applications folder.
    /// Afterwards the "Avvia al login" toggle is the only thing that changes it.
    private func enableLaunchAtLoginOnFirstInstall() {
        let key = "didConfigureLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key),
              Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Applications" else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    #if DEBUG
    private var previewWindow: NSWindow?

    /// Shows the panel in a regular window, so it can be inspected without clicking the status item.
    private func showPreviewWindow() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentViewController: NSHostingController(rootView: PanelView(store: store, showSeen: true)))
        window.title = "Wordwave Preview"
        window.makeKeyAndOrderFront(nil)
        previewWindow = window
    }
    #endif
}

private struct MenuBarLabel: View {
    let store: VoiceNoteStore

    var body: some View {
        let count = store.unseenCount
        HStack(spacing: 3) {
            Image(systemName: count > 0 ? "waveform.circle.fill" : "waveform")
            if count > 0 {
                Text("\(count)")
            }
        }
        .accessibilityLabel(count > 0 ? Text("\(count) unread voice notes") : Text("No unread voice notes"))
    }
}
