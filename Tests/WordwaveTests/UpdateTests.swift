import CryptoKit
import Foundation
import Testing

struct ReleaseVersionTests {
    @Test func parsesVersionsAndTags() {
        #expect(ReleaseVersion("0.1.0")?.description == "0.1.0")
        #expect(ReleaseVersion(tag: "v0.2.0-beta.1")?.prerelease == ["beta", "1"])
        #expect(ReleaseVersion(tag: "v0.2.0-beta.1")?.isPrerelease == true)
        #expect(ReleaseVersion(tag: "0.2.0") == nil)
    }

    @Test(arguments: ["0.1", "v0.1.0", "01.0.0", "1.0.0-", "1.0.0-beta..1", "1.0.0-beta.01", "١.0.0", "1.0.0+build", "1.0.0 ", "1.0.0-be_ta"])
    func rejectsMalformedVersions(_ text: String) {
        #expect(ReleaseVersion(text) == nil)
    }

    @Test func ordersBySemanticVersioning() throws {
        let ordered = ["0.0.1", "0.1.0-alpha", "0.1.0-alpha.1", "0.1.0-alpha.beta", "0.1.0-beta", "0.1.0-beta.2",
                       "0.1.0-beta.11", "0.1.0-rc.1", "0.1.0", "0.1.1", "0.10.0", "1.0.0"]
        let versions = try ordered.map { try #require(ReleaseVersion($0)) }
        for (lower, higher) in zip(versions, versions.dropFirst()) {
            #expect(lower < higher, "\(lower) < \(higher)")
        }
    }
}

struct UpdateFeedTests {
    private struct Fixture: Encodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        struct Asset: Encodable {
            let name: String
            let size: Int
            let state: String
        }

        init(_ tag: String, prerelease: Bool = false, draft: Bool = false, signed: Bool = true, size: Int = 2_000_000) {
            let version = tag.dropFirst()
            tag_name = tag
            self.draft = draft
            self.prerelease = prerelease
            assets = [Asset(name: "Wordwave-\(version).zip", size: size, state: "uploaded"),
                      Asset(name: "Wordwave-\(version).dmg", size: size, state: "uploaded")]
                + (signed ? [Asset(name: "Wordwave-\(version).zip.sig", size: 89, state: "uploaded")] : [])
        }
    }

    private func candidates(_ releases: [Fixture], installed: String) throws -> UpdateCandidates {
        try UpdateFeed.candidates(in: JSONEncoder().encode(releases), after: #require(ReleaseVersion(installed)))
    }

    private func versions(_ releases: [UpdateRelease]) -> [String] { releases.map(\.version.description) }

    @Test func listsUsableCandidatesNewestFirst() throws {
        let result = try candidates([
            Fixture("v0.1.5"),
            Fixture("v0.2.0"),
            Fixture("v0.3.0-beta.1", prerelease: true),
            Fixture("v0.4.0", draft: true),
            Fixture("v0.5.0", signed: false),
            Fixture("v0.6.0", size: 500_000_000),
            Fixture("v0.0.9"),
        ], installed: "0.1.0")
        #expect(versions(result.stables) == ["0.2.0", "0.1.5"])
        #expect(versions(result.betas) == ["0.3.0-beta.1"])
    }

    /// A newest release that won't verify (published without the key) must not hide the genuine one below it.
    @Test func keepsOlderStablesBehindANewerOne() throws {
        let result = try candidates([Fixture("v99.0.0"), Fixture("v0.2.0")], installed: "0.1.0")
        #expect(versions(result.stables) == ["99.0.0", "0.2.0"])
    }

    @Test func listsTheStableReleaseForBetaUsers() throws {
        let result = try candidates([Fixture("v0.2.0"), Fixture("v0.2.0-beta.2", prerelease: true)], installed: "0.2.0-beta.1")
        #expect(versions(result.stables) == ["0.2.0"])
        #expect(versions(result.betas) == ["0.2.0-beta.2"])
    }

    @Test func treatsHyphenatedTagsAsBetasEvenWhenNotFlagged() throws {
        let result = try candidates([Fixture("v0.2.0-beta.1")], installed: "0.1.0")
        #expect(result.stables.isEmpty)
        #expect(versions(result.betas) == ["0.2.0-beta.1"])
    }

    @Test func offersNothingWhenUpToDate() throws {
        let result = try candidates([Fixture("v0.1.0"), Fixture("v0.0.1")], installed: "0.1.0")
        #expect(result == UpdateCandidates())
    }

    @Test func rejectsUnexpectedJSON() {
        #expect(throws: UpdateError.unreachable) {
            try UpdateFeed.candidates(in: Data(#"{"message":"rate limited"}"#.utf8), after: ReleaseVersion("0.1.0")!)
        }
    }
}

struct UpdateSignatureTests {
    private let key = Curve25519.Signing.PrivateKey()
    private let version = ReleaseVersion("0.2.0")!

    private func message(id: String = "com.ssquillante.Wordwave", version: ReleaseVersion? = nil, digest: String = "abc") -> Data {
        UpdateSignature.message(bundleIdentifier: id, version: version ?? self.version, archiveDigest: digest)
    }

    @Test func acceptsTheReleaseKeysSignature() throws {
        let signature = try key.signature(for: message())
        #expect(UpdateSignature.isValid(signature, publicKey: key.publicKey.rawRepresentation, message: message()))
    }

    @Test func rejectsAnyChangeToTheSignedFacts() throws {
        let signature = try key.signature(for: message())
        let publicKey = key.publicKey.rawRepresentation
        #expect(!UpdateSignature.isValid(signature, publicKey: publicKey, message: message(id: "com.example.Other")))
        #expect(!UpdateSignature.isValid(signature, publicKey: publicKey, message: message(version: ReleaseVersion("0.3.0"))))
        #expect(!UpdateSignature.isValid(signature, publicKey: publicKey, message: message(digest: "abd")))
        #expect(!UpdateSignature.isValid(signature, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, message: message()))
        #expect(!UpdateSignature.isValid(signature, publicKey: Data(repeating: 0, count: 5), message: message()))
    }

    @Test func parsesOnlyOneLineOfBase64Of64Bytes() {
        let valid = Data(repeating: 7, count: 64).base64EncodedString()
        #expect(UpdateSignature.parse(Data((valid + "\n").utf8))?.count == 64)
        #expect(UpdateSignature.parse(Data(Data(repeating: 7, count: 63).base64EncodedString().utf8)) == nil)
        #expect(UpdateSignature.parse(Data("not base64!".utf8)) == nil)
        #expect(UpdateSignature.parse(Data(repeating: 65, count: 2_000)) == nil)
    }

    @Test func hashesFilesAsLowercaseHex() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wordwave-hash-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try UpdateSignature.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func refusesToUnpackAnArchiveWithoutTheRightSignature() async throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("wordwave-unpack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("Wordwave-0.2.0.zip")
        try Data("not really a zip".utf8).write(to: archive)
        let otherKey = Curve25519.Signing.PrivateKey()
        let signature = try otherKey.signature(for: message(digest: UpdateSignature.sha256(of: archive)))
        await #expect(throws: UpdateError.badSignature) {
            _ = try await UpdateInstaller.unpack(archive, signature: signature, publicKey: key.publicKey.rawRepresentation,
                                                 bundleIdentifier: "com.ssquillante.Wordwave", version: version, into: staging)
        }
        #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("Unpacked").path))
    }
}

struct TransferTests {
    @Test(arguments: ["https://github.com/organetto8/wordwave/releases/download/v0.2.0/Wordwave-0.2.0.zip",
                      "https://api.github.com/repos/organetto8/wordwave/releases",
                      "https://release-assets.githubusercontent.com/abc"])
    func allowsGitHubOverHTTPS(_ text: String) {
        #expect(Transfer.isAllowed(URL(string: text)!))
    }

    @Test(arguments: ["http://github.com/x", "https://github.com.evil.example/x", "https://user@github.com/x",
                      "https://github.com:8443/x", "https://evilgithubusercontent.com/x", "file:///etc/passwd"])
    func refusesEverythingElse(_ text: String) {
        #expect(!Transfer.isAllowed(URL(string: text)!))
    }
}
