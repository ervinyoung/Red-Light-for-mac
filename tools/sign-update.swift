// Prints the base64 Ed25519 signature of a file, made with the update key in the login Keychain
// ("Red Light update signing key"). The app only installs updates whose signature matches its built-in public key.
//   swift tools/sign-update.swift dist/Red-Light.zip [expected-public-key] > dist/Red-Light.zip.sig
import Foundation
import CryptoKit
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
p.arguments = ["find-generic-password", "-s", "Red Light update signing key", "-a", "redlight", "-w"]
let out = Pipe(); p.standardOutput = out; try! p.run(); p.waitUntilExit()
guard p.terminationStatus == 0, let b64 = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
      let raw = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    FileHandle.standardError.write("no update signing key in the Keychain\n".data(using: .utf8)!); exit(1) }
// With the app's public key as a second argument (release.sh passes Updater.publicKey), a key that the shipped app
// wouldn't accept is refused here, instead of every copy in the field quietly rejecting the release.
if CommandLine.arguments.count > 2, key.publicKey.rawRepresentation.base64EncodedString() != CommandLine.arguments[2] {
    FileHandle.standardError.write("the Keychain's update key doesn't match the app's public key \(CommandLine.arguments[2])\n".data(using: .utf8)!); exit(1) }
let file = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
print(try! key.signature(for: file).base64EncodedString())
