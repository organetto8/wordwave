import Foundation

/// A bug report or feature request, sent by opening GitHub's issue form with its fields already filled in.
/// Nothing leaves the app by itself: the user reviews the issue in the browser and submits it there, from their
/// own GitHub account, so the app holds no token. Field names match the `id`s in `.github/ISSUE_TEMPLATE`.
struct IssueReport: Sendable {
    enum Kind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
        case bug
        case feature

        var id: String { rawValue }

        var template: String {
            switch self {
            case .bug: "bug_report.yml"
            case .feature: "feature_request.yml"
            }
        }
    }

    /// Options of the feature form's `kind` dropdown, as written in `feature_request.yml`.
    static let featureKinds = ["Transcription", "Menu bar panel or cards", "Notifications", "Opening chats in WhatsApp", "Something else"]

    var kind: Kind = .bug
    var title = ""
    var whatHappened = ""
    var steps = ""
    var expected = ""
    var featureKind = featureKinds[0]
    var need = ""
    var idea = ""
    var diagnostics = ""

    private static let fieldLimit = 1_500
    private static let diagnosticsLimit = 2_500
    /// GitHub answers "414 URI Too Long" a little above 8 KB. Encoded, an accented letter takes 6 bytes.
    static let urlBudget = 7_500

    var canSubmit: Bool {
        let required = kind == .bug ? [whatHappened] : [need]
        return !title.trimmed.isEmpty && required.allSatisfy { !$0.trimmed.isEmpty }
    }

    func url(repository: String) -> URL {
        var fields: [(String, String)] = [("template", kind.template), ("title", title.trimmed.limited(to: 200))]
        switch kind {
        case .bug:
            fields += [
                ("diagnostics", diagnostics.limited(to: Self.diagnosticsLimit)),
                ("what-happened", whatHappened.trimmed.limited(to: Self.fieldLimit)),
                ("steps", steps.trimmed.limited(to: Self.fieldLimit)),
                ("expected", expected.trimmed.limited(to: Self.fieldLimit)),
            ]
        case .feature:
            fields += [
                ("kind", featureKind),
                ("need", need.trimmed.limited(to: Self.fieldLimit)),
                ("idea", idea.trimmed.limited(to: Self.fieldLimit)),
                ("diagnostics", diagnostics.limited(to: Self.diagnosticsLimit)),
            ]
        }
        func encoded() -> String {
            fields.filter { !$0.1.isEmpty }.map { "\($0.0)=\($0.1.queryEscaped)" }.joined(separator: "&")
        }
        var query = encoded()
        // Too long for GitHub: halve the text that takes the most bytes, never the template name, until the link fits.
        // Every pass makes a field strictly shorter or empties it, so the loop ends even for text made of a few
        // enormous characters (letters stacked with combining marks).
        while query.utf8.count > Self.urlBudget,
              let index = fields.indices.filter({ fields[$0].0 != "template" && !fields[$0].1.isEmpty })
                  .max(by: { fields[$0].1.utf8.count < fields[$1].1.utf8.count }) {
            let text = fields[index].1
            fields[index].1 = text.count > 2 ? String(text.prefix(text.count / 2)) + "…" : ""
            query = encoded()
        }
        return URL(string: "https://github.com/\(repository)/issues/new?\(query)")!
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    func limited(to count: Int) -> String {
        self.count <= count ? self : String(prefix(count)) + "…"
    }

    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Percent-encodes everything but URL-unreserved ASCII, so `&`, `=`, `+` and `#` in the text stay text.
    var queryEscaped: String {
        addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
    }
}
