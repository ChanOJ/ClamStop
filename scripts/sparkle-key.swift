// Sparkle EdDSA key helper, without the Keychain:
//   swift scripts/sparkle-key.swift public < private-key   prints the public key of a private key
//   swift scripts/sparkle-key.swift generate               prints a new private key, then its
//                                                          public key (throwaway keys for tests)
// Private key format: base64 of the 32-byte seed, as exported by Sparkle's `generate_keys -x`
// (older 96-byte exports start with the seed too).
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

switch CommandLine.arguments.dropFirst().first {
case "public":
    let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          data.count == 32 || data.count == 96,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data.prefix(32)) else {
        fail("not a Sparkle EdDSA private key")
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    print(key.rawRepresentation.base64EncodedString())
    print(key.publicKey.rawRepresentation.base64EncodedString())
default:
    fail("usage: sparkle-key.swift public|generate")
}
