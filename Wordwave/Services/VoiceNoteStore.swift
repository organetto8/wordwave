import AppKit
import Foundation
import Observation
import OSLog

/// Owns the voice note list: polls WhatsApp, transcribes new notes, tracks seen state, persists to disk.
@MainActor
@Observable
final class VoiceNoteStore {
    enum Status: Equatable {
        case starting
        case running
        case needsAccess
        case error(String)
    }

    private struct PersistedState: Codable {
        var lastMessageID: Int64
        var notes: [VoiceNote]
    }

    private enum Tuning {
        static let pollInterval: Duration = .seconds(3)
        /// On first launch, import voice notes received in this window.
        static let firstLaunchLookback: TimeInterval = 3 * 3600
        /// After a restart, never catch up on notes older than this.
        static let maxCatchUp: TimeInterval = 24 * 3600
        /// Only notes this recent trigger a system notification.
        static let notifyWindow: TimeInterval = 10 * 60
        static let giveUpWaitingForAudio: TimeInterval = 30 * 60
        static let keepSeenFor: TimeInterval = 7 * 24 * 3600
        static let maxNotes = 300
    }

    private(set) var notes: [VoiceNote] = []
    private(set) var status: Status = .starting

    var unseen: [VoiceNote] { notes.filter { !$0.seen }.sorted { $0.receivedAt > $1.receivedAt } }
    var seen: [VoiceNote] { notes.filter(\.seen).sorted { $0.receivedAt > $1.receivedAt } }
    var unseenCount: Int { notes.count(where: { !$0.seen }) }
    var isTranscribing: Bool { transcriptionTask != nil }

    @ObservationIgnored private let database = WhatsAppDatabase()
    @ObservationIgnored private let transcriber = Transcriber()
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private var lastMessageID: Int64 = 0
    @ObservationIgnored private var isFirstLaunch = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.ssquillante.Wordwave", category: "store")

    private static let stateURL: URL = {
        let directory = URL.applicationSupportDirectory.appending(path: "Wordwave", directoryHint: .isDirectory)
        // Transcripts are private: the folder is readable by the current user only.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
        return directory.appending(path: "state.json")
    }()

    init(notifier: Notifier) {
        self.notifier = notifier
    }

    func start() {
        guard pollTask == nil else { return }
        load()
        for index in notes.indices where notes[index].transcription == .transcribing {
            notes[index].transcription = .pending
        }
        if prune() { save() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: Tuning.pollInterval)
            }
        }
        scheduleTranscriptions()
    }

    // MARK: - User actions

    func open(_ note: VoiceNote) {
        WhatsAppOpener.openChat(for: note)
        markSeen(note, true)
    }

    func open(noteID: Int64) {
        if let note = notes.first(where: { $0.id == noteID }) { open(note) }
    }

    func markSeen(_ note: VoiceNote, _ seen: Bool) {
        update(note.id) {
            $0.seen = seen
            $0.seenAt = seen ? .now : nil
        }
        if seen { notifier.remove(noteID: note.id) }
        save()
    }

    func markAllSeen() {
        for index in notes.indices where !notes[index].seen {
            notes[index].seen = true
            notes[index].seenAt = .now
            notifier.remove(noteID: notes[index].id)
        }
        save()
    }

    func retryTranscription(_ note: VoiceNote) {
        update(note.id) { $0.transcription = $0.audioPath == nil ? .waitingForAudio : .pending }
        save()
        scheduleTranscriptions()
    }

    func copyTranscript(_ note: VoiceNote) {
        guard let text = note.transcriptText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Polling

    private func poll() async {
        let since = isFirstLaunch
            ? Date.now.addingTimeInterval(-Tuning.firstLaunchLookback)
            : Date.now.addingTimeInterval(-Tuning.maxCatchUp)
        do {
            let fresh = try await database.fetchVoiceNotes(afterID: lastMessageID, since: since)
            let waitingIDs = notes.filter { $0.transcription == .waitingForAudio }.map(\.id)
            let downloaded = try await database.downloadedAudioPaths(for: waitingIDs)
            status = .running
            ingest(fresh, downloaded: downloaded)
        } catch WhatsAppDatabaseError.accessDenied {
            status = .needsAccess
            await database.reset()
        } catch {
            logger.error("poll failed: \(error.localizedDescription, privacy: .public)")
            status = .error(error.localizedDescription)
            await database.reset()
        }
    }

    private func ingest(_ fresh: [VoiceNote], downloaded: [Int64: String]) {
        var changed = false

        for (id, path) in downloaded {
            update(id) {
                $0.audioPath = path
                $0.transcription = .pending
            }
            changed = true
        }
        for index in notes.indices where notes[index].transcription == .waitingForAudio
            && notes[index].receivedAt.timeIntervalSinceNow < -Tuning.giveUpWaitingForAudio {
            notes[index].transcription = .failed(String(localized: "WhatsApp didn't download the audio."))
            changed = true
        }

        let known = Set(notes.map(\.id))
        let added = fresh.filter { !known.contains($0.id) }
        if let maxID = fresh.map(\.id).max(), maxID > lastMessageID {
            lastMessageID = maxID
            changed = true
        }
        if !added.isEmpty {
            notes.append(contentsOf: added)
            logger.info("ingested \(added.count) voice notes")
        }
        if isFirstLaunch {
            isFirstLaunch = false
            changed = true
        }

        if prune() { changed = true }
        guard changed else { return }
        save()
        scheduleTranscriptions()
    }

    // MARK: - Transcription

    private func scheduleTranscriptions() {
        guard transcriptionTask == nil else { return }
        transcriptionTask = Task { [weak self] in
            while let self, let note = self.nextPendingNote() {
                await self.transcribe(note)
            }
            self?.transcriptionTask = nil
        }
    }

    /// Newest pending note first: the one the user is most likely waiting for.
    private func nextPendingNote() -> VoiceNote? {
        notes.filter { $0.transcription == .pending && $0.audioPath != nil }.max { $0.receivedAt < $1.receivedAt }
    }

    private func transcribe(_ note: VoiceNote) async {
        guard let path = note.audioPath else { return }
        update(note.id) { $0.transcription = .transcribing }

        let result: VoiceNote.TranscriptionState
        do {
            result = .done(try await transcriber.transcribe(fileAt: path))
        } catch {
            logger.error("transcription failed for \(note.id): \(error.localizedDescription, privacy: .public)")
            result = .failed(error.localizedDescription)
        }
        update(note.id) { $0.transcription = result }
        save()

        if let updated = notes.first(where: { $0.id == note.id }), !updated.seen,
           updated.receivedAt.timeIntervalSinceNow > -Tuning.notifyWindow {
            notifier.post(updated)
        }
    }

    // MARK: - Persistence

    private func update(_ id: Int64, _ change: (inout VoiceNote) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[index])
    }

    /// Drops old seen notes. Returns whether anything was removed.
    @discardableResult
    private func prune() -> Bool {
        let before = notes.count
        let cutoff = Date.now.addingTimeInterval(-Tuning.keepSeenFor)
        notes.removeAll { $0.seen && ($0.seenAt ?? $0.receivedAt) < cutoff }
        if notes.count > Tuning.maxNotes {
            notes = Array(notes.sorted { $0.receivedAt > $1.receivedAt }.prefix(Tuning.maxNotes))
        }
        return notes.count != before
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            isFirstLaunch = true
            return
        }
        lastMessageID = state.lastMessageID
        notes = state.notes
    }

    private func save() {
        let state = PersistedState(lastMessageID: lastMessageID, notes: notes)
        do {
            // Transcripts are private: keep the file readable by the current user only, from the moment it exists.
            let previousMask = umask(0o077)
            defer { umask(previousMask) }
            try JSONEncoder().encode(state).write(to: Self.stateURL, options: .atomic)
        } catch {
            logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
