#!/usr/bin/env swift
// Generates an Ed25519 keypair for DiskScout license signing.
//   swift Scripts/licensing/generate-keys.swift
// Writes Scripts/licensing/keys/private.key (KEEP SECRET, never commit) and prints the
// public key to paste into LicenseManager.publicKeyHex.
import Foundation
import CryptoKit

let key = Curve25519.Signing.PrivateKey()
let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("keys")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let privPath = dir.appendingPathComponent("private.key")
if FileManager.default.fileExists(atPath: privPath.path) {
    print("Refusing to overwrite existing \(privPath.path). Delete it first if you really want a new keypair.")
    exit(1)
}
let hex = { (d: Data) in d.map { String(format: "%02x", $0) }.joined() }
try hex(key.rawRepresentation).write(to: privPath, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privPath.path)
print("Private key written to \(privPath.path)")
print("Public key (paste into LicenseManager.publicKeyHex):")
print(hex(key.publicKey.rawRepresentation))
