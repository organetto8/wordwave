import AVFoundation
import Foundation
import Speech

enum TranscriberError: Error, LocalizedError {
    case unavailable
    case unsupportedLocale(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "On-device transcription isn't available on this Mac.")
        case .unsupportedLocale(let id): String(localized: "On-device transcription doesn't support \(id).")
        case .empty: String(localized: "No speech recognized.")
        }
    }
}

/// On-device speech-to-text using macOS 26 `SpeechAnalyzer` + `SpeechTranscriber`.
actor Transcriber {
    static let localeDefaultsKey = "transcriptionLocale"
    /// Stored value meaning "follow the system language".
    static let automaticLocale = "auto"
    /// Languages offered in the menu. Any other locale SpeechTranscriber supports works if set in defaults.
    static let offeredLocales = ["en-US", "en-GB", "it-IT", "es-ES", "fr-FR", "de-DE", "pt-BR"]

    private var resolvedLocale: (requested: String, locale: Locale)?
    private var installedAssetsFor: Locale?

    func transcribe(fileAt path: String) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw TranscriberError.unavailable }
        let locale = try await locale()
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        if installedAssetsFor != locale {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            installedAssetsFor = locale
        }

        let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        // Start consuming results before feeding audio, so no result is dropped.
        let collector = Task {
            var segments: [String] = []
            for try await result in transcriber.results where result.isFinal {
                let segment = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty { segments.append(segment) }
            }
            return segments.joined(separator: " ")
        }
        let analyzer = try await SpeechAnalyzer(inputAudioFile: audioFile, modules: [transcriber], finishAfterFile: true)
        let text = try await withTaskCancellationHandler {
            try await collector.value
        } onCancel: {
            collector.cancel()
        }
        withExtendedLifetime(analyzer) {}

        guard !text.isEmpty else { throw TranscriberError.empty }
        return text
    }

    private func locale() async throws -> Locale {
        let stored = UserDefaults.standard.string(forKey: Self.localeDefaultsKey) ?? Self.automaticLocale
        let requested = stored == Self.automaticLocale ? (Locale.preferredLanguages.first ?? "en-US") : stored
        if let resolvedLocale, resolvedLocale.requested == requested { return resolvedLocale.locale }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: requested)) else {
            throw TranscriberError.unsupportedLocale(requested)
        }
        resolvedLocale = (requested, locale)
        return locale
    }
}
