// Verify release archives against the public key embedded in the app, without
// needing (or reading) the private signing key.
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4,
      let signature = Data(base64Encoded: CommandLine.arguments[2]),
      let keyData = Data(base64Encoded: CommandLine.arguments[3]) else {
    fputs("Usage: verify-update.swift ARCHIVE SIGNATURE PUBLIC_KEY\n", stderr)
    exit(2)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: archive) else {
        fputs("Update signature does not match the app's SUPublicEDKey.\n", stderr)
        exit(1)
    }
    print("Archive signature matches the app's public key.")
} catch {
    fputs("Cannot verify update: \(error.localizedDescription)\n", stderr)
    exit(1)
}
