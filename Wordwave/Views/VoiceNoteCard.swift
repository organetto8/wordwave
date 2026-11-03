import SwiftUI

struct VoiceNoteCard: View {
    let note: VoiceNote
    let store: VoiceNoteStore

    @State private var isHovering = false

    var body: some View {
        Button { store.open(note) } label: {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(path: note.avatarPath, name: note.senderName)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if !note.seen {
                            Circle()
                                .fill(.tint)
                                .frame(width: 7, height: 7)
                        }
                        Text(note.senderName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(note.receivedAt.arrivalLabel)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    if let group = note.groupName {
                        Label(group, systemImage: "person.3.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    transcript

                    Label(note.durationSeconds.durationLabel, systemImage: "waveform")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.09 : 0.045))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(note.phoneNumber == nil ? Text("Open WhatsApp and mark as seen") : Text("Open the chat and mark as seen"))
        .contextMenu { menu }
    }

    @ViewBuilder
    private var transcript: some View {
        switch note.transcription {
        case .done(let text):
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(note.seen ? .secondary : .primary)
                .lineLimit(note.seen ? 3 : nil)
                .fixedSize(horizontal: false, vertical: true)
        case .pending, .transcribing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Transcribing…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .waitingForAudio:
            Label("Waiting for WhatsApp to download the audio…", systemImage: "arrow.down.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open Chat", systemImage: "bubble.left") { store.open(note) }
        if note.transcriptText != nil {
            Button("Copy Transcript", systemImage: "doc.on.doc") { store.copyTranscript(note) }
        }
        if note.seen {
            Button("Mark as Unseen", systemImage: "circle") { store.markSeen(note, false) }
        } else {
            Button("Mark as Seen", systemImage: "checkmark.circle") { store.markSeen(note, true) }
        }
        if case .failed = note.transcription {
            Button("Retry Transcription", systemImage: "arrow.clockwise") { store.retryTranscription(note) }
        }
    }
}

private extension Date {
    /// `14:52`, `Yesterday 14:52`, or `3 Nov, 14:52`.
    var arrivalLabel: String {
        let time = formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(self) { return time }
        if Calendar.current.isDateInYesterday(self) { return String(localized: "Yesterday \(time)") }
        return formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}
