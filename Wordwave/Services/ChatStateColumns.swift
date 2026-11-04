import Foundation

/// Where this WhatsApp version keeps whether a chat is archived or muted. WhatsApp's database is undocumented and
/// changes between versions, so the columns are found by looking at the database itself rather than assumed.
struct ChatStateColumns: Sendable {
    /// SQL, non-zero when chat `c` (its `ZWACHATSESSION` row) is archived; `NULL` when no column says so.
    private let archivedSQL: String
    /// SQL for the Core Data date chat `c` is muted until; `NULL` when no column says so.
    private let mutedUntilSQL: String
    /// `TABLE.COLUMN` each state was read from.
    private let archivedSource: String?
    private let mutedSource: String?

    /// The two result columns to add to a query that has the chat as `c`: archived, then muted until.
    var selectSQL: String { "\(archivedSQL), \(mutedUntilSQL)" }

    /// Where each state was found: table and column names only, safe for the diagnostic info.
    var summary: String {
        "archived: \(archivedSource ?? "not found") · muted: \(mutedSource ?? "not found")"
    }

    /// Whether the chat in `row`, whose `selectSQL` columns start at `index`, is archived or muted at `date`.
    static func isMutedOrArchived(_ row: SQLiteConnection.Row, from index: Int32, at date: Date) -> Bool {
        (row.int(index) ?? 0) != 0 || isMuted(until: row.double(index + 1), at: date)
    }

    /// A mute that ended is over. "Always" can be stored as a far-future date or as a negative number: no real
    /// mute ends before 2001, Core Data's reference date, so a negative value counts as muted too.
    private static func isMuted(until mutedUntil: Double?, at date: Date) -> Bool {
        guard let mutedUntil else { return false }
        return mutedUntil < 0 || mutedUntil > date.timeIntervalSinceReferenceDate
    }
}

extension ChatStateColumns {
    private struct Column {
        let name: String
        let type: String
    }

    private static let chatTable = "ZWACHATSESSION"
    private static let archivedColumns = ["ZARCHIVED", "ZISARCHIVED"]
    /// Columns that hold a chat's WhatsApp ID, in tables keyed by it rather than by the chat row.
    private static let jidColumns = ["ZJID", "ZCHATJID", "ZCONTACTJID"]

    init(reading db: SQLiteConnection) throws {
        let chatColumns = try Self.columns(of: Self.chatTable, in: db)
        let archived = Self.archivedColumns.first { name in chatColumns.contains { $0.name == name } }
        archivedSQL = archived.map { "c.\($0)" } ?? "NULL"
        archivedSource = archived.map { "\(Self.chatTable).\($0)" }

        let muted = try Self.mutedUntil(chatColumns: chatColumns, in: db)
        mutedUntilSQL = muted?.sql ?? "NULL"
        mutedSource = muted?.source
    }

    /// The mute end date: on the chat row itself, else in another table linked to the chat by its row or its JID.
    private static func mutedUntil(chatColumns: [Column], in db: SQLiteConnection) throws -> (sql: String, source: String)? {
        if let column = chatColumns.first(where: isMuteEnd) {
            return ("c.\(column.name)", "\(chatTable).\(column.name)")
        }
        for table in try tables(in: db) where table != chatTable {
            let tableColumns = try columns(of: table, in: db)
            guard let column = tableColumns.first(where: isMuteEnd) else { continue }
            let names = Set(tableColumns.map(\.name))
            let link: String
            if names.contains("ZCHATSESSION") {
                link = "ms.ZCHATSESSION = c.Z_PK"
            } else if let jid = jidColumns.first(where: names.contains) {
                link = "ms.\(jid) = c.ZCONTACTJID"
            } else {
                continue
            }
            return ("(SELECT MAX(ms.\(column.name)) FROM \(table) ms WHERE \(link))", "\(table).\(column.name)")
        }
        return nil
    }

    /// A Core Data date whose name says when a mute ends, such as `ZMUTEDUNTIL` or `ZMUTEEXPIRATION`.
    private static func isMuteEnd(_ column: Column) -> Bool {
        column.type == "TIMESTAMP" && column.name.contains("MUTE")
            && ["UNTIL", "EXPIR", "END"].contains { column.name.contains($0) }
    }

    private static func tables(in db: SQLiteConnection) throws -> [String] {
        var tables: [String] = []
        try db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") { row in
            if let name = row.text(0), isPlainIdentifier(name) { tables.append(name) }
        }
        return tables
    }

    private static func columns(of table: String, in db: SQLiteConnection) throws -> [Column] {
        var columns: [Column] = []
        try db.query("SELECT name, type FROM pragma_table_info(?1)", [.text(table)]) { row in
            if let name = row.text(0), isPlainIdentifier(name) {
                columns.append(Column(name: name, type: row.text(1)?.uppercased() ?? ""))
            }
        }
        return columns
    }

    /// Core Data names tables and columns in plain upper case: any other name never goes into SQL.
    private static func isPlainIdentifier(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }
    }
}
