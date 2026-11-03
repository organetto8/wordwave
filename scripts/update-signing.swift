// Signs releases for Wordwave's updater with an Ed25519 key kept in the login keychain.
//
//   swift scripts/update-signing.swift generate            new key; its public half goes into project.yml
//   swift scripts/update-signing.swift sign <app> <zip>    writes <zip>.sig for the app the zip was made from
//   swift scripts/update-signing.swift verify <zip>        checks <zip>.sig the way installed copies will
//   swift scripts/update-signing.swift export              prints the private key (base64) for an offline backup
//   swift scripts/update-signing.swift import              reads a backed-up key from standard input
//   swift scripts/update-signing.swift rotate              next key; the next release, still signed with the
//                                                          current key, carries the new public half
//   swift scripts/update-signing.swift finish-rotation     after publishing that release: the next key becomes current
//
// The app installs an update only if <zip>.sig is this key's signature of
//   "wordwave-update-1\n<bundle identifier>\n<version>\n<SHA-256 of the zip, lowercase hex>\n"
// (UpdateSignature.message in Wordwave/Updates/UpdateCheck.swift). The private key never goes into the repository or CI.
import CryptoKit
import Foundation
import Security

let service = "com.ssquillante.Wordwave.update-signing"
let currentAccount = "ed25519"
let nextAccount = "ed25519-next"
let projectFile = "project.yml"
let publicKeyField = "WordwaveUpdatePublicKey"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
}

func storedKey(_ account: String = currentAccount) -> Curve25519.Signing.PrivateKey? {
    var search = query(account)
    search[kSecReturnData as String] = true
    search[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(search as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { fail("can't read the signing key from the keychain (\(status))") }
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { fail("the keychain item isn't an Ed25519 key") }
    return key
}

func store(_ key: Curve25519.Signing.PrivateKey, as account: String = currentAccount) {
    guard storedKey(account) == nil else { fail("a signing key is already in the keychain (\(service), \(account))") }
    var item = query(account)
    item[kSecAttrLabel as String] = account == currentAccount ? "Wordwave update signing key" : "Wordwave update signing key (next)"
    item[kSecValueData as String] = key.rawRepresentation
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("can't save the signing key in the keychain (\(status))") }
}

func delete(_ account: String) {
    let status = SecItemDelete(query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { fail("can't delete the \(account) key from the keychain (\(status))") }
}

func base64(_ key: Curve25519.Signing.PublicKey) -> String { key.rawRepresentation.base64EncodedString() }

func contents(ofPlist plist: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: plist),
          let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { fail("can't read \(plist)") }
    return values
}

/// The value of `WordwaveUpdatePublicKey:` in project.yml, which XcodeGen copies into Info.plist.
func projectPublicKey() -> String? {
    guard let text = try? String(contentsOfFile: projectFile, encoding: .utf8) else { fail("can't read \(projectFile): run from the repository root") }
    for line in text.split(separator: "\n") where line.trimmingCharacters(in: .whitespaces).hasPrefix(publicKeyField + ":") {
        return line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
    }
    return nil
}

func publish(_ key: Curve25519.Signing.PublicKey) {
    guard let text = try? String(contentsOfFile: projectFile, encoding: .utf8) else { fail("can't read \(projectFile): run from the repository root") }
    var replaced = 0
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        guard line.trimmingCharacters(in: .whitespaces).hasPrefix(publicKeyField + ":") else { return String(line) }
        replaced += 1
        let indent = line.prefix { $0 == " " }
        return "\(indent)\(publicKeyField): \"\(base64(key))\""
    }
    guard replaced == 1 else { fail("\(projectFile) must contain exactly one \(publicKeyField) line") }
    do {
        try lines.joined(separator: "\n").write(toFile: projectFile, atomically: true, encoding: .utf8)
    } catch {
        fail("can't write \(projectFile): \(error.localizedDescription)")
    }
    print("Wrote the public key into \(projectFile) (\(publicKeyField)). Commit it, and back up the private key: see docs/RELEASING.md.")
}

func sha256(_ file: String) -> String {
    guard let handle = FileHandle(forReadingAtPath: file) else { fail("can't read \(file)") }
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    store(key)
    publish(key.publicKey)

case "sign":
    guard arguments.count == 3 else { fail("usage: sign <Wordwave.app> <Wordwave-x.y.z.zip>") }
    let app = arguments[1], zip = arguments[2]
    guard let key = storedKey() else { fail("no signing key in the keychain: run `swift scripts/update-signing.swift generate` once (docs/RELEASING.md)") }
    let next = storedKey(nextAccount)
    let appInfo = contents(ofPlist: app + "/Contents/Info.plist")
    guard let identifier = appInfo["CFBundleIdentifier"] as? String, let version = appInfo["CFBundleShortVersionString"] as? String else {
        fail("\(app) has no bundle identifier or version")
    }
    // Copies installed today check with the current key; the app being released must trust the key that signs
    // the release after it: the current one, or the next one while rotating.
    let carried = appInfo[publicKeyField] as? String
    guard carried == base64(key.publicKey) || (next != nil && carried == next.map { base64($0.publicKey) }) else {
        fail("\(app) carries a different \(publicKeyField) than the keychain's key: fix \(projectFile) and rebuild")
    }
    guard (zip as NSString).lastPathComponent == "Wordwave-\(version).zip" else { fail("\(zip) should be named Wordwave-\(version).zip") }
    let message = Data("wordwave-update-1\n\(identifier)\n\(version)\n\(sha256(zip))\n".utf8)
    guard let signature = try? key.signature(for: message), key.publicKey.isValidSignature(signature, for: message) else { fail("signing failed") }
    do {
        try Data((signature.base64EncodedString() + "\n").utf8).write(to: URL(fileURLWithPath: zip + ".sig"))
    } catch {
        fail("can't write \(zip).sig: \(error.localizedDescription)")
    }
    print("Signed \(zip) for \(identifier) \(version)")
    if next != nil {
        print("This release moves users to the next key. Once it is published, run: swift scripts/update-signing.swift finish-rotation")
    }

case "verify":
    guard arguments.count == 2 else { fail("usage: verify <Wordwave-x.y.z.zip>") }
    let zip = arguments[1]
    guard let projectKey = projectPublicKey(), let keyData = Data(base64Encoded: projectKey),
          let projectPublic = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { fail("\(projectFile) has no valid \(publicKeyField)") }
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-p", zip, "Wordwave.app/Contents/Info.plist"]
    let pipe = Pipe()
    unzip.standardOutput = pipe
    do { try unzip.run() } catch { fail("can't run unzip: \(error.localizedDescription)") }
    let plist = pipe.fileHandleForReading.readDataToEndOfFile()
    unzip.waitUntilExit()
    guard unzip.terminationStatus == 0,
          let info = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
          let identifier = info["CFBundleIdentifier"] as? String, let version = info["CFBundleShortVersionString"] as? String else {
        fail("\(zip) doesn't contain Wordwave.app with a bundle identifier and version")
    }
    guard info[publicKeyField] as? String == projectKey else { fail("the app in \(zip) carries a different \(publicKeyField) than \(projectFile)") }
    guard (zip as NSString).lastPathComponent == "Wordwave-\(version).zip" else { fail("\(zip) should be named Wordwave-\(version).zip") }
    guard let text = try? String(contentsOfFile: zip + ".sig", encoding: .utf8),
          let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), signature.count == 64 else {
        fail("\(zip).sig is missing or isn't one line of base64 for 64 bytes")
    }
    let message = Data("wordwave-update-1\n\(identifier)\n\(version)\n\(sha256(zip))\n".utf8)
    // Installed copies trust the key in project.yml; while rotating, they still trust the current keychain key.
    let trusted = [projectPublic] + (storedKey(nextAccount) != nil ? [storedKey()?.publicKey].compactMap { $0 } : [])
    guard trusted.contains(where: { $0.isValidSignature(signature, for: message) }) else {
        fail("\(zip).sig is not a valid signature for \(identifier) \(version) by the release key")
    }
    print("Verified \(zip): \(identifier) \(version), signed with the release key")

case "export":
    guard let key = storedKey() else { fail("no signing key in the keychain") }
    FileHandle.standardError.write(Data("This is the private key. Keep it offline (a password manager), never in the repository.\n".utf8))
    print(key.rawRepresentation.base64EncodedString())

case "import":
    guard let text = readLine(strippingNewline: true), let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespaces)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { fail("paste the base64 key printed by export") }
    store(key)
    if projectPublicKey() != base64(key.publicKey) { publish(key.publicKey) }

case "rotate":
    guard storedKey() != nil else { fail("no current key to rotate from") }
    let next = Curve25519.Signing.PrivateKey()
    store(next, as: nextAccount)
    publish(next.publicKey)
    print("Release the next version as usual: it is signed with the current key and carries the new one. Then run finish-rotation.")

case "finish-rotation":
    guard let next = storedKey(nextAccount) else { fail("no rotation in progress") }
    delete(currentAccount)
    store(next)
    delete(nextAccount)
    print("The new key is now the signing key. Back it up: swift scripts/update-signing.swift export")

default:
    fail("usage: swift scripts/update-signing.swift generate | sign <app> <zip> | verify <zip> | export | import | rotate | finish-rotation")
}
