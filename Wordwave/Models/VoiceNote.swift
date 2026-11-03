import Foundation

/// A WhatsApp voice message received by the user, plus its transcription state.
struct VoiceNote: Identifiable, Codable, Sendable, Hashable {
    enum TranscriptionState: Codable, Sendable, Hashable {
        /// Audio not downloaded by WhatsApp yet.
        case waitingForAudio
        case pending
        case transcribing
        case done(String)
        case failed(String)
    }

    /// WhatsApp message primary key (`ZWAMESSAGE.Z_PK`).
    let id: Int64
    let receivedAt: Date
    let durationSeconds: Int
    let chatJID: String
    /// Sender display name (contact name, or phone number as fallback).
    let senderName: String
    /// Group name when the message was sent in a group chat.
    let groupName: String?
    /// Absolute path of the profile picture on disk, if WhatsApp cached one.
    var avatarPath: String?
    /// Phone number (digits only) used to open the chat in WhatsApp.
    var phoneNumber: String?
    /// Absolute path of the `.opus` file, once WhatsApp downloaded it.
    var audioPath: String?
    var transcription: TranscriptionState
    var seen: Bool
    var seenAt: Date?

    var isGroup: Bool { groupName != nil }

    var transcriptText: String? {
        if case .done(let text) = transcription { return text }
        return nil
    }
}
