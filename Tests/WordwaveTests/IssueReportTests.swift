import Foundation
import Testing

struct IssueReportTests {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func fillsTheBugFormFields() {
        var report = IssueReport(kind: .bug)
        report.title = "Empty transcript"
        report.whatHappened = "Nothing shows"
        report.steps = "1. Receive a note"
        report.diagnostics = "Wordwave 0.1.0 (2)"
        let url = report.url(repository: "organetto8/wordwave")
        #expect(url.absoluteString.hasPrefix("https://github.com/organetto8/wordwave/issues/new?"))
        let fields = query(url)
        #expect(fields["template"] == "bug_report.yml")
        #expect(fields["title"] == "Empty transcript")
        #expect(fields["what-happened"] == "Nothing shows")
        #expect(fields["steps"] == "1. Receive a note")
        #expect(fields["diagnostics"] == "Wordwave 0.1.0 (2)")
        #expect(fields["expected"] == nil, "empty fields are left out")
    }

    @Test func fillsTheFeatureFormFields() {
        var report = IssueReport(kind: .feature)
        report.title = "Languages"
        report.featureKind = "Transcription"
        report.need = "Spanish notes"
        let fields = query(report.url(repository: "organetto8/wordwave"))
        #expect(fields["template"] == "feature_request.yml")
        #expect(fields["kind"] == "Transcription")
        #expect(fields["need"] == "Spanish notes")
        #expect(fields["what-happened"] == nil)
    }

    @Test func keepsReservedCharactersAsText() {
        var report = IssueReport(kind: .bug)
        report.title = "a&b=c+d#e?f/g %"
        report.whatHappened = "x"
        let url = report.url(repository: "organetto8/wordwave")
        #expect(url.absoluteString.contains("title=a%26b%3Dc%2Bd%23e%3Ff%2Fg%20%25"))
        #expect(query(url)["title"] == "a&b=c+d#e?f/g %")
    }

    @Test func staysUnderGitHubsURLLimit() {
        var report = IssueReport(kind: .bug)
        report.title = String(repeating: "t", count: 1_000)
        report.whatHappened = String(repeating: "è", count: 10_000)
        report.steps = String(repeating: "s", count: 10_000)
        report.expected = String(repeating: "e", count: 10_000)
        report.diagnostics = String(repeating: "d", count: 10_000)
        let url = report.url(repository: "organetto8/wordwave")
        #expect(url.absoluteString.utf8.count <= IssueReport.urlBudget + 60)
        #expect(query(url)["template"] == "bug_report.yml")
        #expect(query(url)["what-happened"]?.hasPrefix("èèè") == true)
    }

    /// Letters stacked with thousands of combining marks: a few characters, many kilobytes.
    @Test(.timeLimit(.minutes(1))) func shortensTextMadeOfHugeCharacters() {
        let huge = "a" + String(repeating: "\u{0301}", count: 3_000)
        var report = IssueReport(kind: .bug)
        report.title = String(repeating: huge, count: 3)
        report.whatHappened = String(repeating: huge, count: 4)
        report.steps = String(repeating: huge, count: 2)
        let url = report.url(repository: "organetto8/wordwave")
        #expect(url.absoluteString.utf8.count <= IssueReport.urlBudget + 60)
        #expect(query(url)["template"] == "bug_report.yml")
    }

    @Test func cutsTheTitleAt200Characters() {
        var report = IssueReport(kind: .bug)
        report.title = String(repeating: "t", count: 1_000)
        #expect(query(report.url(repository: "organetto8/wordwave"))["title"] == String(repeating: "t", count: 200) + "…")
    }

    @Test func needsATitleAndTheRequiredField() {
        var report = IssueReport(kind: .bug)
        #expect(!report.canSubmit)
        report.title = "Crash"
        #expect(!report.canSubmit)
        report.whatHappened = "  \n "
        #expect(!report.canSubmit)
        report.whatHappened = "It quit"
        #expect(report.canSubmit)
        report.kind = .feature
        #expect(!report.canSubmit)
        report.need = "Something"
        #expect(report.canSubmit)
    }
}
