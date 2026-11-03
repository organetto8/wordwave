import CryptoKit
import Foundation

/// A release version as Wordwave tags it (`v1.2.3`, `v1.2.3-beta.1`), ordered by Semantic Versioning 2.0.
/// Parsing is strict because the text ends up in download URLs and in the signed message.
struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// Pre-release identifiers, such as ["beta", "1"]; empty for a stable release.
    let prerelease: [String]

    init?(_ text: String) {
        guard text.utf8.count <= 64 else { return nil }
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3, numbers.allSatisfy({ Self.isNumber($0) }),
              let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2]) else { return nil }
        var identifiers: [String] = []
        if parts.count == 2 {
            identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard identifiers.allSatisfy(Self.isIdentifier) else { return nil }
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = identifiers
    }

    /// A release tag: "v" followed by the version.
    init?(tag: String) {
        guard tag.hasPrefix("v") else { return nil }
        self.init(String(tag.dropFirst()))
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // A pre-release comes before its release; between two, the first different identifier decides.
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (numericValue(left), numericValue(right)) {
            case let (leftNumber?, rightNumber?): return leftNumber < rightNumber
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    /// ASCII digits only ("١" or "+1" never pass), at most 9, and no leading zero.
    private static func isNumber<S: StringProtocol>(_ text: S) -> Bool {
        let bytes = text.utf8
        guard (1...9).contains(bytes.count), bytes.allSatisfy(isDigit) else { return false }
        return bytes.count == 1 || bytes.first != UInt8(ascii: "0")
    }

    /// Letters, digits and hyphens; an all-digit identifier follows the number rule.
    private static func isIdentifier(_ text: String) -> Bool {
        let bytes = text.utf8
        guard !bytes.isEmpty, bytes.allSatisfy({ isDigit($0) || isLetter($0) || $0 == UInt8(ascii: "-") }) else { return false }
        return !bytes.allSatisfy(isDigit) || isNumber(text)
    }

    private static func numericValue(_ identifier: String) -> Int? {
        identifier.utf8.allSatisfy(isDigit) ? Int(identifier) : nil
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }
}

/// A newer release that carries the two files the updater needs.
struct UpdateRelease: Equatable, Sendable {
    let version: ReleaseVersion

    var archiveName: String { "Wordwave-\(version).zip" }
    var signatureName: String { archiveName + ".sig" }
}

/// What the release list offers above the installed version, newest first. Nothing here is verified yet: the
/// updater tries each stable in turn, so one release that fails its signature can't hide an older genuine one.
struct UpdateCandidates: Equatable, Sendable {
    /// Stable releases: installed without asking.
    var stables: [UpdateRelease] = []
    /// Betas: installed only if the user agrees, and only when no stable release verifies.
    var betas: [UpdateRelease] = []
}

/// GitHub's release list. Only tags, the draft and pre-release flags, and asset names and sizes are read:
/// nothing in it is trusted to decide what gets installed, which is the signature's job.
enum UpdateFeed {
    /// Far larger than any Wordwave download; a bigger archive is skipped, or stopped mid-transfer.
    static let maxArchiveSize = 100_000_000

    static func candidates(repository: String, after installed: ReleaseVersion) async throws -> UpdateCandidates {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100") else { throw UpdateError.unreachable }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Wordwave releases \(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try await Transfer.run(request, to: file, limit: 4_000_000)
        return try candidates(in: Data(contentsOf: file), after: installed)
    }

    /// The stable and beta versions above `installed` whose archive and signature are both uploaded, newest first.
    /// A release is a beta when GitHub flags it as a pre-release or its tag has a hyphen.
    static func candidates(in json: Data, after installed: ReleaseVersion) throws -> UpdateCandidates {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let releases = try? decoder.decode([Release].self, from: json) else { throw UpdateError.unreachable }
        let usable = releases.compactMap { release -> (release: UpdateRelease, isBeta: Bool)? in
            guard !release.draft, let version = ReleaseVersion(tag: release.tagName), version > installed else { return nil }
            let candidate = UpdateRelease(version: version)
            let files = release.assets.filter { $0.state == nil || $0.state == "uploaded" }
            guard let archive = files.first(where: { $0.name == candidate.archiveName }), (1...maxArchiveSize).contains(archive.size),
                  files.contains(where: { $0.name == candidate.signatureName }) else { return nil }
            return (candidate, release.prerelease || version.isPrerelease)
        }
        let newestFirst = usable.sorted { $0.release.version > $1.release.version }
        return UpdateCandidates(stables: newestFirst.filter { !$0.isBeta }.map(\.release),
                                betas: newestFirst.filter(\.isBeta).map(\.release))
    }

    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let size: Int
        let state: String?
    }
}

/// The release key's Ed25519 signature of an archive, made by `scripts/update-signing.swift` at release time.
/// Only the public half is in the app (Info.plist `WordwaveUpdatePublicKey`); the private half never leaves
/// the maintainer's keychain, so taking over the GitHub account or the network is not enough to ship an update.
enum UpdateSignature {
    /// What gets signed. It names the app, the version and the archive's SHA-256, so a signature can't be moved
    /// to another file, or replayed under a newer tag to bring back an old version with a known flaw.
    static func message(bundleIdentifier: String, version: ReleaseVersion, archiveDigest: String) -> Data {
        Data("wordwave-update-1\n\(bundleIdentifier)\n\(version)\n\(archiveDigest)\n".utf8)
    }

    /// A `.sig` file: one line of base64 that decodes to exactly 64 bytes.
    static func parse(_ file: Data) -> Data? {
        guard file.count <= 1024, let text = String(data: file, encoding: .utf8),
              let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), signature.count == 64 else { return nil }
        return signature
    }

    static func isValid(_ signature: Data, publicKey: Data, message: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    /// Lowercase hex SHA-256 of a file, read a megabyte at a time.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum UpdateError: LocalizedError, Sendable, Equatable {
    case unreachable
    case tooLarge
    case badSignature
    case badArchive
    case cannotReplace
    case notPermitted
    /// The copy on disk is already this version or newer (installed by hand meanwhile).
    case outdated
    /// The swap failed and the previous version couldn't be put back: it waits at this path.
    case restoreFailed(String)

    /// The download itself is not a genuine Wordwave release: never point the user at it.
    var isVerificationFailure: Bool {
        self == .badSignature || self == .badArchive || self == .tooLarge
    }

    var errorDescription: String? {
        switch self {
        case .unreachable: String(localized: "GitHub didn't answer as expected. Try again later.")
        case .tooLarge: String(localized: "The download is larger than any Wordwave release, so it was stopped.")
        case .badSignature: String(localized: "The download isn't signed with Wordwave's release key, so it wasn't installed.")
        case .badArchive: String(localized: "The download doesn't contain a valid copy of Wordwave, so it wasn't installed.")
        case .cannotReplace: String(localized: "Wordwave can't replace itself where it is. Move it into the Applications folder, or install the new version by hand.")
        case .notPermitted: String(localized: "macOS didn't let Wordwave replace itself. Allow Wordwave in System Settings ▸ Privacy & Security ▸ App Management and try again, or install the new version by hand.")
        case .outdated: String(localized: "This version of Wordwave is already installed.")
        case .restoreFailed(let path): String(localized: "Wordwave couldn't finish the update or put the previous version back. The previous version is in \(path): move it into the Applications folder.")
        }
    }
}
