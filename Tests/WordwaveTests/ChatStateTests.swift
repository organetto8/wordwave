import Foundation
import SQLite3
import Testing

/// Muted and archived chats, read from made-up databases laid out the ways WhatsApp may keep them.
struct ChatStateTests {
    /// Core Data seconds, late 2024: mutes ending before it are over.
    private static let now = Date(timeIntervalSinceReferenceDate: 750_000_000)

    /// The chats Wordwave skips, and where it found their state, in a database built from `schema`.
    private func skippedChats(_ schema: String) throws -> (ids: [Int64], summary: String) {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "wordwave-test-\(UUID().uuidString).sqlite").path(percentEncoded: false)
        defer { try? FileManager.default.removeItem(atPath: path) }
        var handle: OpaquePointer?
        let rc = sqlite3_open(path, &handle)
        defer { sqlite3_close(handle) }
        guard rc == SQLITE_OK, sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
        }

        // Read-only, the way Wordwave opens WhatsApp's database.
        let db = try SQLiteConnection(path: path)
        let columns = try ChatStateColumns(reading: db)
        var ids: [Int64] = []
        try db.query("SELECT c.Z_PK, \(columns.selectSQL) FROM ZWACHATSESSION c ORDER BY c.Z_PK") { row in
            if let id = row.int(0), ChatStateColumns.isMutedOrArchived(row, from: 1, at: Self.now) { ids.append(id) }
        }
        return (ids, columns.summary)
    }

    @Test func readsBothStatesFromTheChatRow() throws {
        let result = try skippedChats("""
            CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZARCHIVED INTEGER, ZCONTACTJID VARCHAR, ZMUTEEXPIRATION TIMESTAMP);
            INSERT INTO ZWACHATSESSION VALUES
                (1, 0, 'a@s.whatsapp.net', NULL),
                (2, 1, 'b@s.whatsapp.net', NULL),
                (3, 0, 'c@g.us', 800000000),
                (4, 0, 'd@s.whatsapp.net', 700000000),
                (5, NULL, 'e@s.whatsapp.net', -1),
                (6, 0, 'f@s.whatsapp.net', 0);
            """)
        #expect(result.ids == [2, 3, 5], "archived, muted until later, muted always; not unmuted, mute over, or 0")
        #expect(result.summary == "archived: ZWACHATSESSION.ZARCHIVED · muted: ZWACHATSESSION.ZMUTEEXPIRATION")
    }

    @Test func readsTheMuteFromATableKeyedByJID() throws {
        let result = try skippedChats("""
            CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZARCHIVED INTEGER, ZCONTACTJID VARCHAR);
            CREATE TABLE ZWACHATPUSHCONFIG (Z_PK INTEGER PRIMARY KEY, ZJID VARCHAR, ZMUTEDUNTIL TIMESTAMP);
            INSERT INTO ZWACHATSESSION VALUES (1, 0, 'a@s.whatsapp.net'), (2, 0, 'b@g.us'), (3, 0, 'c@g.us');
            INSERT INTO ZWACHATPUSHCONFIG VALUES (1, 'b@g.us', 63113904000), (2, 'c@g.us', 700000000);
            """)
        #expect(result.ids == [2])
        #expect(result.summary == "archived: ZWACHATSESSION.ZARCHIVED · muted: ZWACHATPUSHCONFIG.ZMUTEDUNTIL")
    }

    @Test func readsTheMuteFromATableLinkedToTheChatRow() throws {
        let result = try skippedChats("""
            CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID VARCHAR);
            CREATE TABLE ZWACHATPROPERTIES (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZMUTEENDDATE TIMESTAMP);
            INSERT INTO ZWACHATSESSION VALUES (1, 'a@s.whatsapp.net'), (2, 'b@s.whatsapp.net');
            INSERT INTO ZWACHATPROPERTIES VALUES (1, 1, 800000000);
            """)
        #expect(result.ids == [1])
        #expect(result.summary == "archived: not found · muted: ZWACHATPROPERTIES.ZMUTEENDDATE")
    }

    @Test func skipsNothingWhenNoColumnSaysWhenAMuteEnds() throws {
        let result = try skippedChats("""
            CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID VARCHAR, ZMUTED INTEGER, ZLASTMUTEDATE TIMESTAMP);
            CREATE TABLE ZWAOTHER (Z_PK INTEGER PRIMARY KEY, ZMUTEDUNTIL TIMESTAMP);
            INSERT INTO ZWACHATSESSION VALUES (1, 'a@s.whatsapp.net', 1, 800000000);
            INSERT INTO ZWAOTHER VALUES (1, 800000000);
            """)
        #expect(result.ids.isEmpty, "not a date, a date that isn't an end, and a table with no link to the chat")
        #expect(result.summary == "archived: not found · muted: not found")
    }
}
