#!/usr/bin/env swift
// Issues a DiskScout license key.
//   swift Scripts/licensing/sign-license.swift customer@example.com            # perpetual
//   swift Scripts/licensing/sign-license.swift customer@example.com 2027-12-31 # expiring
// Hook this up to your payment provider's webhook (Lemon Squeezy, Paddle, Gumroad, Stripe)
// or run it by hand and email the key.
import Foundation
import CryptoKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: sign-license.swift <email> [expiry YYYY-MM-DD]"); exit(1)
}
let email = args[1]
var expires: TimeInterval = 0
if args.count >= 3 {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
    guard let d = f.date(from: args[2]) else { print("Bad date \(args[2])"); exit(1) }
    expires = d.timeIntervalSince1970
}
let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("keys")
let privHex = try String(contentsOf: dir.appendingPathComponent("private.key"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
func data(hex: String) -> Data {
    var d = Data(); var i = hex.startIndex
    while i < hex.endIndex { let n = hex.index(i, offsetBy: 2); d.append(UInt8(hex[i..<n], radix: 16)!); i = n }
    return d
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: data(hex: privHex))
let payload: [String: Any] = ["e": email, "i": Date().timeIntervalSince1970.rounded(), "x": expires]
let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
let sig = try key.signature(for: payloadData)
func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
print("DS1.\(b64url(payloadData)).\(b64url(sig))")
