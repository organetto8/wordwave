import AppKit
import ServiceManagement
import SwiftUI

@main
struct WordwaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: appDelegate.store, updater: appDelegate.updater)
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Report", id: ReportView.windowID, for: IssueReport.Kind.self) { $kind in
            ReportView(store: appDelegate.store, updater: appDelegate.updater, kind: kind ?? .bug)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let notifier = Notifier()
    let updater = Updater()
    lazy var store = VoiceNoteStore(notifier: notifier)

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifier.onOpen = { [weak self] id in self?.store.open(noteID: id) }
        notifier.requestAuthorization()
        store.start()
        enableLaunchAtLoginOnFirstInstall()
        startUpdates()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-window") { showPreviewWindow() }
        if ProcessInfo.processInfo.arguments.contains("--preview-report") { showPreviewReport() }
        #endif
    }

    /// Stable updates install while nothing is going on: no transcription running, no panel or window open.
    private func startUpdates() {
        updater.isBusy = { [weak self] in NSApp.isActive || (self?.store.isTranscribing ?? false) }
        updater.announceBeta = { [weak self] in self?.notifier.postBetaAvailable($0) }
        notifier.onBetaOffer = { [weak self] in self?.updater.presentBetaOffer() }
        if let previous = updater.takeUpdatedFrom(), let installed = Updater.installedVersion {
            notifier.postUpdate(to: installed, from: previous, releasePage: Updater.releasePage(installed))
        }
        updater.start()
    }

    /// Turns on launch at login the first time the app runs from an Applications folder.
    /// Afterwards the "Launch at Login" toggle is the only thing that changes it.
    private func enableLaunchAtLoginOnFirstInstall() {
        let key = "didConfigureLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key),
              Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Applications" else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    #if DEBUG
    private var previewWindow: NSWindow?
    private var previewReport: NSWindow?

    /// Shows the report form in a regular window, as the Report a Bug… menu item would.
    private func showPreviewReport() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentViewController: NSHostingController(rootView: ReportView(store: store, updater: updater, kind: .bug)))
        window.title = "Wordwave Report Preview"
        window.makeKeyAndOrderFront(nil)
        previewReport = window
    }

    /// Shows the panel in a regular window, so it can be inspected without clicking the status item.
    private func showPreviewWindow() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentViewController: NSHostingController(rootView: PanelView(store: store, updater: updater, showSeen: true)))
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
