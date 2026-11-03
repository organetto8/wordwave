import SwiftUI

/// Collects a bug report or a feature request with the same fields as the GitHub issue forms, then opens the
/// form on GitHub already filled in. The user submits it there, so Wordwave never posts anything by itself.
struct ReportView: View {
    static let windowID = "report"

    let store: VoiceNoteStore
    let updater: Updater

    @State private var report: IssueReport
    @State private var isLoadingDiagnostics = true
    @Environment(\.dismiss) private var dismiss

    init(store: VoiceNoteStore, updater: Updater, kind: IssueReport.Kind) {
        self.store = store
        self.updater = updater
        _report = State(initialValue: IssueReport(kind: kind))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Report", selection: $report.kind) {
                    Text("Bug").tag(IssueReport.Kind.bug)
                    Text("Feature Request").tag(IssueReport.Kind.feature)
                }
                .pickerStyle(.segmented)

                TextField("Title", text: $report.title, prompt: Text(report.kind == .bug ? "Transcript is empty for long voice notes" : "Show the transcript language on each card"))

                switch report.kind {
                case .bug:
                    field("What happened", text: $report.whatHappened, prompt: "What you saw, including the exact text of any error message.")
                    field("Steps to reproduce", text: $report.steps, prompt: "1. Receive a voice note longer than 2 minutes\n2. Open the panel\n3. …")
                    field("What you expected", text: $report.expected, prompt: "The full transcript.")
                case .feature:
                    Picker("Kind of request", selection: $report.featureKind) {
                        ForEach(IssueReport.featureKinds, id: \.self) { Text(LocalizedStringKey($0)).tag($0) }
                    }
                    field("What you want to do", text: $report.need, prompt: "The task you're trying to get done, and how you do it today.")
                    field("How it could work", text: $report.idea, prompt: "Optional. Where it goes and what you'd see.")
                }

                Section {
                    if isLoadingDiagnostics {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(verbatim: report.diagnostics)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    Text("Diagnostic info")
                } footer: {
                    Text("Versions, settings and counts only: no names, phone numbers or transcripts. It is added to the issue.")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Opens GitHub with the issue filled in. Review it there, in English, and click Create.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open on GitHub") {
                    NSWorkspace.shared.open(report.url(repository: Updater.repository))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!report.canSubmit || isLoadingDiagnostics)
            }
            .padding(12)
        }
        // A grouped Form scrolls and has no height of its own: without one, the window shrinks to the button bar.
        .frame(width: 540, height: 680)
        .task {
            report.diagnostics = await Diagnostics.report(store: store, updater: updater)
            isLoadingDiagnostics = false
        }
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        TextField(title, text: text, prompt: Text(prompt), axis: .vertical)
            .lineLimit(3...8)
    }
}
