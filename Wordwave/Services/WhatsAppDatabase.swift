import Foundation

enum WhatsAppPaths {
    static let bundleIdentifier = "net.whatsapp.WhatsApp"

    static let container = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Group Containers/group.net.whatsapp.WhatsApp.shared", directoryHint: .isDirectory)

    static let chatStorage = container.appending(path: "ChatStorage.sqlite")
    static let contacts = container.appending(path: "ContactsV2.sqlite")
    static let lid = container.appending(path: "LID.sqlite")
    static let messageDirectory = container.appending(path: "Message", directoryHint: .isDirectory)
    static let profileDirectory = container.appending(path: "Media/Profile", directoryHint: .isDirectory)
}

enum WhatsAppDatabaseError: Error, LocalizedError {
    case notInstalled
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .notInstalled: String(localized: "WhatsApp Desktop data not found. Install WhatsApp from the Mac App Store and sign in.")
        case .accessDenied: String(localized: "macOS is blocking access to WhatsApp data.")
        }
    }
}

/// Reads incoming voice messages from WhatsApp Desktop's local Core Data store (read-only).
actor WhatsAppDatabase {
    private enum MessageType { static let audio: Int64 = 3 }
    /// `ZWACHATSESSION.ZSESSIONTYPE`: 0 = 1:1 chat, 1 = group, 4 = community group.
    private static let groupSessionTypes: Set<Int64> = [1, 4]

    /// Incoming voice notes read in one poll.
    struct Batch: Sendable {
        /// Voice notes to transcribe, oldest first.
        var notes: [VoiceNote] = []
        /// Voice notes left out because their chat is muted or archived.
        var skipped = 0
        /// Highest message ID read, skipped notes included, so a skipped note is never picked up later.
        var lastID: Int64?
    }

    private var chatDB: SQLiteConnection?
    private var contactsDB: SQLiteConnection?
    private var lidDB: SQLiteConnection?
    private var chatState: ChatStateColumns?

    /// Incoming voice notes with `Z_PK > afterID` received after `since`, oldest first. Notes from a chat that is
    /// muted or archived right now are counted as skipped instead.
    func fetchVoiceNotes(afterID: Int64, since: Date) throws -> Batch {
        let db = try chatConnection()
        let chatState = try chatStateColumns(db)
        let avatars = AvatarIndex()
        let now = Date.now
        var batch = Batch()

        let sql = """
            SELECT m.Z_PK, m.ZMESSAGEDATE, i.ZMOVIEDURATION, i.ZMEDIALOCALPATH,
                   c.ZCONTACTJID, c.ZPARTNERNAME, c.ZSESSIONTYPE,
                   g.ZMEMBERJID, COALESCE(g.ZCONTACTNAME, g.ZFIRSTNAME),
                   \(chatState.selectSQL)
            FROM ZWAMESSAGE m
            JOIN ZWAMEDIAITEM i ON i.Z_PK = m.ZMEDIAITEM
            JOIN ZWACHATSESSION c ON c.Z_PK = m.ZCHATSESSION
            LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER
            WHERE m.ZMESSAGETYPE = ?1 AND m.ZISFROMME = 0
              AND m.Z_PK > ?2 AND m.ZMESSAGEDATE > ?3
              AND c.ZSESSIONTYPE IN (0, 1, 4)
            ORDER BY m.Z_PK
            """
        try db.query(sql, [.int(MessageType.audio), .int(afterID), .double(since.timeIntervalSinceReferenceDate)]) { row in
            guard let id = row.int(0), let date = row.double(1), let chatJID = row.text(4) else { return }
            batch.lastID = max(batch.lastID ?? id, id)
            if ChatStateColumns.isMutedOrArchived(row, from: 9, at: now) {
                batch.skipped += 1
                return
            }
            let isGroup = Self.groupSessionTypes.contains(row.int(6) ?? 0)
            let chatName = row.text(5)?.nilIfBlank

            let senderJID = isGroup ? row.text(7) : chatJID
            let phone = senderJID.flatMap(phoneNumber(for:))
            let senderName = (isGroup ? row.text(8)?.nilIfBlank : chatName)
                ?? senderJID.flatMap(contactName(for:))
                ?? phone.map { "+\($0)" }
                ?? String(localized: "Unknown sender")

            batch.notes.append(VoiceNote(
                id: id,
                receivedAt: Date(timeIntervalSinceReferenceDate: date),
                durationSeconds: Int(row.int(2) ?? 0),
                chatJID: chatJID,
                senderName: senderName,
                groupName: isGroup ? (chatName ?? String(localized: "Group")) : nil,
                avatarPath: senderJID.flatMap { avatars.path(for: $0) } ?? phone.flatMap { avatars.path(for: $0) },
                phoneNumber: isGroup ? nil : phone,
                audioPath: Self.existingAudioPath(row.text(3)),
                transcription: .pending,
                seen: false
            ))
        }

        for index in batch.notes.indices where batch.notes[index].audioPath == nil {
            batch.notes[index].transcription = .waitingForAudio
        }
        return batch
    }

    /// Where muted and archived state was found, for the diagnostic info; nil until WhatsApp's data was read.
    func chatStateSummary() -> String? {
        chatState?.summary
    }

    /// Audio file paths for messages whose audio has been downloaded in the meantime.
    func downloadedAudioPaths(for ids: [Int64]) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        let db = try chatConnection()
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var paths: [Int64: String] = [:]
        try db.query(
            "SELECT m.Z_PK, i.ZMEDIALOCALPATH FROM ZWAMESSAGE m JOIN ZWAMEDIAITEM i ON i.Z_PK = m.ZMEDIAITEM WHERE m.Z_PK IN (\(placeholders))",
            ids.map { .int($0) }
        ) { row in
            if let id = row.int(0), let path = Self.existingAudioPath(row.text(1)) { paths[id] = path }
        }
        return paths
    }

    // MARK: - Connections

    private func chatConnection() throws -> SQLiteConnection {
        if let chatDB { return chatDB }
        let path = WhatsAppPaths.chatStorage.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { throw WhatsAppDatabaseError.notInstalled }
        // TCC denies the open(2) call even when POSIX permissions allow it: probe before SQLite does.
        do {
            try FileHandle(forReadingFrom: WhatsAppPaths.chatStorage).close()
        } catch {
            throw WhatsAppDatabaseError.accessDenied
        }
        let connection = try SQLiteConnection(path: path)
        chatDB = connection
        return connection
    }

    /// Looked up once per connection: a WhatsApp update that changes the layout fails a query, which reconnects.
    private func chatStateColumns(_ db: SQLiteConnection) throws -> ChatStateColumns {
        if let chatState { return chatState }
        let columns = try ChatStateColumns(reading: db)
        chatState = columns
        return columns
    }

    /// Drops cached connections so the next call reopens them (e.g. after an I/O error).
    func reset() {
        chatDB = nil
        contactsDB = nil
        lidDB = nil
        chatState = nil
    }

    private func optionalConnection(_ url: URL, cache: inout SQLiteConnection?) -> SQLiteConnection? {
        if let cache { return cache }
        cache = try? SQLiteConnection(path: url.path(percentEncoded: false))
        return cache
    }

    // MARK: - Contact lookups

    private func contactName(for jid: String) -> String? {
        if let db = optionalConnection(WhatsAppPaths.contacts, cache: &contactsDB) {
            var name: String?
            try? db.query(
                "SELECT COALESCE(ZFULLNAME, ZBUSINESSNAME, ZGIVENNAME) FROM ZWAADDRESSBOOKCONTACT WHERE ZLID = ?1 OR ZIDENTIFIER = ?1 LIMIT 1",
                [.text(jid)]
            ) { name = $0.text(0)?.nilIfBlank }
            if let name { return name }
        }
        if let db = optionalConnection(WhatsAppPaths.lid, cache: &lidDB) {
            var name: String?
            try? db.query("SELECT ZDISPLAYNAME FROM ZWALIDPROPERTIES WHERE ZLID = ?1 LIMIT 1", [.text(jid)]) {
                name = $0.text(0)?.nilIfBlank
            }
            return name
        }
        return nil
    }

    /// Phone number as digits only (e.g. `15551234567`).
    private func phoneNumber(for jid: String) -> String? {
        let user = jid.jidUser
        if jid.hasSuffix("@s.whatsapp.net") { return user.digitsOnly.nilIfBlank }
        guard jid.hasSuffix("@lid") else { return nil }

        var phone: String?
        if let db = optionalConnection(WhatsAppPaths.contacts, cache: &contactsDB) {
            try? db.query("SELECT ZPHONENUMBER FROM ZWAADDRESSBOOKCONTACT WHERE ZLID = ?1 AND ZPHONENUMBER IS NOT NULL LIMIT 1", [.text(jid)]) {
                phone = $0.text(0)
            }
        }
        if phone == nil, let db = optionalConnection(WhatsAppPaths.lid, cache: &lidDB) {
            try? db.query("SELECT ZPHONENUMBER FROM ZWAPHONENUMBERLIDPAIR WHERE ZLID = ?1 ORDER BY ZTIMESTAMP DESC LIMIT 1", [.text(jid)]) {
                phone = $0.text(0)
            }
        }
        return phone?.jidUser.digitsOnly.nilIfBlank
    }

    private static func existingAudioPath(_ relativePath: String?) -> String? {
        guard let relativePath = relativePath?.nilIfBlank else { return nil }
        let root = WhatsAppPaths.messageDirectory.standardizedFileURL.path(percentEncoded: false)
        let path = WhatsAppPaths.messageDirectory.appending(path: relativePath).standardizedFileURL.path(percentEncoded: false)
        // The path comes from WhatsApp's database: never follow it outside WhatsApp's message media folder.
        guard path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}

/// Maps a JID user part to its cached profile picture (`Media/Profile/<user>-<timestamp>.jpg|.thumb`).
private struct AvatarIndex {
    private var best: [String: (timestamp: Int, isFullSize: Bool, path: String)] = [:]

    init() {
        let directory = WhatsAppPaths.profileDirectory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for file in files {
            let name = (file as NSString).deletingPathExtension
            let ext = (file as NSString).pathExtension
            guard ext == "jpg" || ext == "thumb",
                  let dash = name.lastIndex(of: "-"),
                  let timestamp = Int(name[name.index(after: dash)...]) else { continue }
            let user = String(name[..<dash])
            let candidate = (timestamp, ext == "jpg", directory.appending(path: file).path(percentEncoded: false))
            if let current = best[user], (current.timestamp, current.isFullSize ? 1 : 0) >= (timestamp, candidate.1 ? 1 : 0) {
                continue
            }
            best[user] = candidate
        }
    }

    func path(for jidOrPhone: String) -> String? {
        best[jidOrPhone.jidUser]?.path
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }

    /// User part of a JID: `15551234567@s.whatsapp.net` → `15551234567`.
    var jidUser: String {
        String(split(separator: "@", maxSplits: 1).first ?? Substring(self))
    }

    var digitsOnly: String {
        filter(\.isNumber)
    }
}
