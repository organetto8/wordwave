import ServiceManagement
import SwiftUI

struct PanelView: View {
    let store: VoiceNoteStore

    @State private var showSeen: Bool
    @State private var contentHeight: CGFloat = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(Transcriber.localeDefaultsKey) private var transcriptionLocale = Transcriber.automaticLocale

    init(store: VoiceNoteStore, showSeen: Bool = false) {
        self.store = store
        _showSeen = State(initialValue: showSeen)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statusBanner
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    unseenSection
                    seenSection
                }
                .padding(12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 90), 540))
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(.tint)
            Text("Voice Notes")
                .font(.headline)
            if store.unseenCount > 0 {
                Text("\(store.unseenCount)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.tint))
                    .foregroundStyle(.white)
            }
            Spacer()
            Menu {
                Button("Mark All as Seen", systemImage: "checkmark.circle") { store.markAllSeen() }
                    .disabled(store.unseenCount == 0)
                Button("Open WhatsApp", systemImage: "arrow.up.forward.app") { WhatsAppOpener.openApp() }
                Divider()
                transcriptionLanguagePicker
                Toggle("Launch at Login", isOn: $launchAtLogin)
                Divider()
                Button("Quit Wordwave") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onChange(of: launchAtLogin) { _, enabled in
            do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private var transcriptionLanguagePicker: some View {
        Picker("Transcription Language", selection: $transcriptionLocale) {
            Text("Automatic (System)").tag(Transcriber.automaticLocale)
            Divider()
            ForEach(Transcriber.offeredLocales, id: \.self) { identifier in
                Text(verbatim: Locale.current.localizedString(forIdentifier: identifier) ?? identifier).tag(identifier)
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch store.status {
        case .needsAccess:
            AccessRequiredView()
            Divider()
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            Divider()
        case .starting, .running:
            EmptyView()
        }
    }

    @ViewBuilder
    private var unseenSection: some View {
        let unseen = store.unseen
        if unseen.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.title2)
                Text("No new voice notes")
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            ForEach(unseen) { note in
                VoiceNoteCard(note: note, store: store)
            }
        }
    }

    @ViewBuilder
    private var seenSection: some View {
        let seen = store.seen
        if !seen.isEmpty {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showSeen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showSeen ? 90 : 0))
                    Text("Seen")
                        .font(.subheadline.weight(.semibold))
                    Text("\(seen.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .padding(.horizontal, 2)

            if showSeen {
                ForEach(seen) { note in
                    VoiceNoteCard(note: note, store: store)
                }
            }
        }
    }
}

private struct AccessRequiredView: View {
    private static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Wordwave needs access to WhatsApp data", systemImage: "lock.fill")
                .font(.callout.weight(.semibold))
            Text("If macOS asks to access data from other apps, choose Allow. Otherwise add Wordwave under Full Disk Access.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Full Disk Access Settings") {
                NSWorkspace.shared.open(Self.fullDiskAccessURL)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
