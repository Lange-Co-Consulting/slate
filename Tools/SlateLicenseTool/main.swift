import CryptoKit
import Foundation
import SlateCore

enum ToolError: Error, LocalizedError {
    case usage(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .invalid(let message): return message
        }
    }
}

private func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

private func required(_ flag: String, in arguments: [String]) throws -> String {
    guard let result = value(after: flag, in: arguments), !result.isEmpty else {
        throw ToolError.usage("Missing required option: \(flag)")
    }
    return result
}

private let help = """
Slate signing tool (owner-only; never distribute a private key)

Generate a signing key:
  swift run SlateLicenseTool generate-key --private-key /secure/path/slate-production.slatekey

Print the public half of an existing private key:
  swift run SlateLicenseTool public-key --private-key /secure/path/slate-production.slatekey

Issue a licence:
  swift run SlateLicenseTool issue --private-key /secure/path/slate-production.slatekey \\
    --output Customer.slatelicense --license-id order-123 --tier pro \\
    [--customer "Name"] [--device-code SHA256] [--expires 2027-07-14T00:00:00Z]

Verify a licence without opening Slate:
  swift run SlateLicenseTool verify --public-key BASE64 --input Customer.slatelicense
    [--installation-id local-test-installation]

Create a signed update manifest (the DMG itself is never signed by this tool):
  swift run SlateLicenseTool sign-update --private-key /secure/path/slate-update.slatekey \
    --version 1.2.3 --build 42 --dmg-url https://example.com/Slate.dmg \
    --sha256 HEX --output update.json [--notes "What's new"] [--minimum-os 26.0]

Verify a signed update manifest:
  swift run SlateLicenseTool verify-update --public-key BASE64 --input update.json

The public key printed by generate-key is safe to embed. Licence and update
signing use separate keys in SlateApp/Packaging/Info.plist.
"""

private func generateKey(arguments: [String]) throws {
    let path = try required("--private-key", in: arguments)
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard !FileManager.default.fileExists(atPath: url.path) else {
        throw ToolError.invalid("Refusing to overwrite existing private key: \(url.path)")
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let privateKey = Curve25519.Signing.PrivateKey()
    // `Data.WritingOptions.atomic` and `.withoutOverwriting` cannot be combined
    // on Apple platforms. The explicit existence check above provides the
    // overwrite protection; atomic writing avoids ever leaving a partial key.
    try privateKey.rawRepresentation.base64EncodedData().write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    print("Private key written with mode 0600: \(url.path)")
    print("Public key (safe to embed in Slate):")
    print(privateKey.publicKey.rawRepresentation.base64EncodedString())
}

private func issue(arguments: [String]) throws {
    let privatePath = try required("--private-key", in: arguments)
    let outputPath = try required("--output", in: arguments)
    let licenseID = try required("--license-id", in: arguments)
    let tierValue = try required("--tier", in: arguments)
    guard let tier = LicenseTier(rawValue: tierValue) else {
        throw ToolError.invalid("--tier must be pro or founder")
    }
    let rawKey = try Data(contentsOf: URL(fileURLWithPath: privatePath))
    let trimmedKey = String(decoding: rawKey, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let keyData = Data(base64Encoded: trimmedKey) else {
        throw ToolError.invalid("Private key is not valid base64")
    }
    let privateKey: Curve25519.Signing.PrivateKey
    do { privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData) }
    catch { throw ToolError.invalid("Private key is not a valid Ed25519 signing key") }

    let expiresAt: Date?
    if let rawExpiry = value(after: "--expires", in: arguments) {
        guard let parsed = ISO8601DateFormatter().date(from: rawExpiry) else {
            throw ToolError.invalid("--expires must be ISO-8601, for example 2027-07-14T00:00:00Z")
        }
        expiresAt = parsed
    } else {
        expiresAt = nil
    }
    let deviceCode = value(after: "--device-code", in: arguments)
    if let deviceCode,
       (deviceCode.count != 64 || deviceCode.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil) {
        throw ToolError.invalid("--device-code must be the 64-character code copied from Slate")
    }
    let payload = OfflineLicensePayload(
        licenseID: licenseID,
        tier: tier,
        issuedAt: Date(),
        expiresAt: expiresAt,
        deviceIDHash: deviceCode,
        customerName: value(after: "--customer", in: arguments)
    )
    let payloadData = try JSONEncoder().encode(payload)
    let document = OfflineLicenseDocument(
        payload: payloadData.base64EncodedString(),
        signature: try privateKey.signature(for: payloadData).base64EncodedString()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
    try encoder.encode(document).write(to: outputURL, options: [.atomic])
    print("Issued \(tier.rawValue) offline licence: \(outputURL.path)")
    print(deviceCode == nil ? "Device binding: none" : "Device binding: enabled")
    print(expiresAt == nil ? "Expiry: perpetual" : "Expiry: \(expiresAt!)")
}

private func verify(arguments: [String]) throws {
    let publicKey = try required("--public-key", in: arguments)
    let inputPath = try required("--input", in: arguments)
    let installationID = value(after: "--installation-id", in: arguments) ?? "slate-license-verifier"
    let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
    let payload = try OfflineLicenseVerifier.verify(documentData: data,
                                                    publicKeyBase64: publicKey,
                                                    installationID: installationID)
    print("Verified \(payload.tier.rawValue) offline licence: \(payload.licenseID)")
    print(payload.deviceIDHash == nil ? "Device binding: none" : "Device binding: enabled")
    print(payload.expiresAt == nil ? "Expiry: perpetual" : "Expiry: \(payload.expiresAt!)")
}

private func loadPrivateKey(_ path: String) throws -> Curve25519.Signing.PrivateKey {
    let rawKey = try Data(contentsOf: URL(fileURLWithPath: path))
    let trimmedKey = String(decoding: rawKey, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let keyData = Data(base64Encoded: trimmedKey) else {
        throw ToolError.invalid("Private key is not valid base64")
    }
    do { return try Curve25519.Signing.PrivateKey(rawRepresentation: keyData) }
    catch { throw ToolError.invalid("Private key is not a valid Ed25519 signing key") }
}

private func printPublicKey(arguments: [String]) throws {
    let privatePath = try required("--private-key", in: arguments)
    print(try loadPrivateKey(privatePath).publicKey.rawRepresentation.base64EncodedString())
}

private func signUpdate(arguments: [String]) throws {
    let privatePath = try required("--private-key", in: arguments)
    let version = try required("--version", in: arguments)
    guard let build = Int(try required("--build", in: arguments)), build > 0 else {
        throw ToolError.invalid("--build must be a positive integer")
    }
    let dmgURL = try required("--dmg-url", in: arguments)
    let sha256 = try required("--sha256", in: arguments).lowercased()
    let output = try required("--output", in: arguments)
    let notes = value(after: "--notes", in: arguments) ?? ""
    let minimumOS = value(after: "--minimum-os", in: arguments)
    var manifest = UpdateManifest(version: version, build: build, notes: notes, dmgURL: dmgURL,
                                  sha256: sha256, minimumOS: minimumOS)
    guard manifest.hasSecureURL, manifest.hasValidDigest else {
        throw ToolError.invalid("--dmg-url must be HTTPS and --sha256 must be 64 lowercase/uppercase hex characters")
    }
    let signature = try loadPrivateKey(privatePath).signature(for: manifest.signingPayload()).base64EncodedString()
    manifest = UpdateManifest(version: version, build: build, notes: notes, dmgURL: dmgURL,
                              sha256: sha256, signature: signature, minimumOS: minimumOS)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(manifest).write(to: URL(fileURLWithPath: output), options: .atomic)
    print("Signed update manifest: \(output)")
}

private func verifyUpdate(arguments: [String]) throws {
    let publicKey = try required("--public-key", in: arguments)
    let inputPath = try required("--input", in: arguments)
    let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
    let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
    guard manifest.isValidSignature(publicKeyBase64: publicKey) else {
        throw ToolError.invalid("Update manifest signature or payload is invalid")
    }
    print("Verified signed update manifest: \(manifest.version) (\(manifest.build))")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { throw ToolError.usage(help) }
    switch command {
    case "generate-key": try generateKey(arguments: arguments)
    case "public-key": try printPublicKey(arguments: arguments)
    case "issue": try issue(arguments: arguments)
    case "verify": try verify(arguments: arguments)
    case "sign-update": try signUpdate(arguments: arguments)
    case "verify-update": try verifyUpdate(arguments: arguments)
    case "help", "--help", "-h": print(help)
    default: throw ToolError.usage("Unknown command: \(command)\n\n\(help)")
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(2)
}
