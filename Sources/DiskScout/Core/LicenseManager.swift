import Foundation
import CryptoKit
import SwiftUI

struct LicenseInfo: Codable, Equatable {
    let email: String
    let issued: Date
    let expires: Date?
    let key: String

    var isExpired: Bool {
        guard let expires else { return false }
        return expires < Date()
    }
}

enum LicenseStatus: Equatable {
    case trial(daysLeft: Int)
    case expired
    case licensed(LicenseInfo)

    var isLicensed: Bool { if case .licensed = self { return true } else { return false } }
    var isTrial: Bool { if case .trial = self { return true } else { return false } }
}

enum LicenseError: LocalizedError, Equatable {
    case malformed
    case badSignature
    case expired
    case notConfigured
    case rejected(String)
    case network(String)
    var errorDescription: String? {
        switch self {
        case .malformed: return "That doesn't look like a DiskScout license key. Keys start with “DS1.” or look like XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX."
        case .badSignature: return "This key isn't valid. Check for typos, or paste it again from your purchase email."
        case .expired: return "This license has expired."
        case .notConfigured: return "This build of DiskScout can't check Gumroad keys yet. Please contact support for a DS1 key."
        case .rejected(let why): return why
        case .network(let why): return "Couldn't reach Gumroad to check the key (\(why)). Check your connection and try again."
        }
    }
}

/// License validation. Two kinds of key are accepted:
///
/// 1. DiskScout keys, validated offline with Ed25519 and issued with Scripts/licensing/sign-license.swift
///    (for Patreon supporters, refunds, support cases).
///    Format:  DS1.<base64url(payload JSON)>.<base64url(signature)>   payload {"e":"email","i":<issued>,"x":<expires or 0>}
/// 2. Gumroad license keys (XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX), checked once against Gumroad's
///    licence API and then cached; re-checked quietly about once a week so refunds revoke access.
@MainActor
final class LicenseManager: ObservableObject {
    /// Production public key; the matching private key lives outside the repo (Scripts/licensing/keys/).
    nonisolated static let publicKeyHex = "1e534c7dcfe6c0d4c06fccc5ee4db3d95f82b58ffe9a645fc97215b4db4ad349"

    static let trialDays = 14
    static let price = "$19"

    /// Where "Buy" goes. `build-app.sh` writes PURCHASE_URL into Info.plist so the store link can change without a code edit.
    static var purchaseURL: URL {
        if let s = Bundle.main.infoDictionary?["DiskScoutPurchaseURL"] as? String, let u = URL(string: s), !s.isEmpty { return u }
        return URL(string: "https://diskscout.app/buy")!
    }

    /// Gumroad product ID (from the product's edit page / API). Set via GUMROAD_PRODUCT_ID when running build-app.sh.
    nonisolated static var gumroadProductID: String {
        (Bundle.main.infoDictionary?["DiskScoutGumroadProductID"] as? String) ?? ""
    }
    nonisolated static let gumroadVerifyURL = URL(string: "https://api.gumroad.com/v2/licenses/verify")!
    private let gumroadInfoDefault = "gumroadLicenseInfo"
    private let gumroadCheckedDefault = "gumroadLastChecked"

    @Published private(set) var status: LicenseStatus = .trial(daysLeft: trialDays)

    private let defaults = UserDefaults.standard
    private let licenseKeyDefault = "licenseKey"
    private let trialStartDefault = "trialStart"

    init() { refresh() }

    /// Cleaning is allowed during the trial and when licensed.
    var canClean: Bool { status != .expired }

    func refresh() {
        if let key = defaults.string(forKey: licenseKeyDefault) {
            if case .success(let info) = Self.verify(key), !info.isExpired {
                status = .licensed(info)
                return
            }
            if Self.isGumroadKey(key), let data = defaults.data(forKey: gumroadInfoDefault),
               let info = try? JSONDecoder().decode(LicenseInfo.self, from: data) {
                status = .licensed(info)
                revalidateGumroadIfStale(key)
                return
            }
        }
        let start = trialStart()
        let elapsedDays = Int(Date().timeIntervalSince(start) / 86_400)
        let left = Self.trialDays - elapsedDays
        status = left > 0 ? .trial(daysLeft: left) : .expired
    }

    @discardableResult
    func activate(_ rawKey: String) async -> Result<LicenseInfo, LicenseError> {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isGumroadKey(key) {
            let result = await Self.verifyGumroad(key)
            if case .success(let info) = result {
                defaults.set(key, forKey: licenseKeyDefault)
                defaults.set(try? JSONEncoder().encode(info), forKey: gumroadInfoDefault)
                defaults.set(Date(), forKey: gumroadCheckedDefault)
                status = .licensed(info)
            }
            return result
        }
        let result = Self.verify(key)
        if case .success(let info) = result {
            if info.isExpired { return .failure(.expired) }
            defaults.set(key, forKey: licenseKeyDefault)
            status = .licensed(info)
        }
        return result
    }

    func deactivate() {
        defaults.removeObject(forKey: licenseKeyDefault)
        defaults.removeObject(forKey: gumroadInfoDefault)
        defaults.removeObject(forKey: gumroadCheckedDefault)
        refresh()
    }

    // MARK: - Gumroad

    nonisolated static func isGumroadKey(_ key: String) -> Bool {
        let k = key.uppercased()
        let parts = k.split(separator: "-")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { $0.count == 8 && $0.allSatisfy { $0.isHexDigit } }
    }

    /// Re-checks a Gumroad key about once a week so a refund or chargeback revokes access.
    /// Network failures are ignored: an offline Mac keeps working.
    private func revalidateGumroadIfStale(_ key: String) {
        let last = defaults.object(forKey: gumroadCheckedDefault) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 7 * 86_400, !Self.gumroadProductID.isEmpty else { return }
        Task { [weak self] in
            let result = await Self.verifyGumroad(key, countUse: false)
            guard let self else { return }
            switch result {
            case .success(let info):
                self.defaults.set(try? JSONEncoder().encode(info), forKey: self.gumroadInfoDefault)
                self.defaults.set(Date(), forKey: self.gumroadCheckedDefault)
            case .failure(.rejected):
                self.deactivate()
            case .failure:
                break
            }
        }
    }

    nonisolated static func verifyGumroad(_ key: String, countUse: Bool = true) async -> Result<LicenseInfo, LicenseError> {
        let product = gumroadProductID
        guard !product.isEmpty else { return .failure(.notConfigured) }
        var req = URLRequest(url: gumroadVerifyURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        req.httpBody = "product_id=\(enc(product))&license_key=\(enc(key))&increment_uses_count=\(countUse)".data(using: .utf8)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { return .failure(.network(error.localizedDescription)) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.network("unexpected reply"))
        }
        let http = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard json["success"] as? Bool == true, let purchase = json["purchase"] as? [String: Any] else {
            if http == 404 {
                return .failure(.rejected("Gumroad doesn't recognise this key for DiskScout. Copy it from your Gumroad receipt or library."))
            }
            // Rate limits, timeouts and server errors say nothing about the key: never revoke on those.
            if http == 429 || http == 408 || http >= 500 || http == 0 {
                return .failure(.network("Gumroad is busy (\(http)). Try again in a moment."))
            }
            return .failure(.rejected((json["message"] as? String) ?? "Gumroad rejected this key."))
        }
        if purchase["refunded"] as? Bool == true || purchase["chargebacked"] as? Bool == true || purchase["disputed"] as? Bool == true {
            return .failure(.rejected("This purchase was refunded, so the key no longer unlocks DiskScout."))
        }
        if purchase["subscription_ended_at"] != nil && !(purchase["subscription_ended_at"] is NSNull) ||
           purchase["subscription_failed_at"] != nil && !(purchase["subscription_failed_at"] is NSNull) {
            return .failure(.rejected("This subscription has ended."))
        }
        let email = (purchase["email"] as? String) ?? "Gumroad customer"
        var issued = Date()
        if let ts = purchase["sale_timestamp"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            issued = f.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) ?? issued
        }
        return .success(LicenseInfo(email: email, issued: issued, expires: nil, key: key))
    }

    // MARK: - Trial bookkeeping

    private func trialStart() -> Date {
        let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskScout/.trial")
        var candidates: [Date] = []
        if let d = defaults.object(forKey: trialStartDefault) as? Date { candidates.append(d) }
        if let s = try? String(contentsOf: fileURL, encoding: .utf8), let t = TimeInterval(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            candidates.append(Date(timeIntervalSince1970: t))
        }
        if let earliest = candidates.min() { return earliest }
        let now = Date()
        defaults.set(now, forKey: trialStartDefault)
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(now.timeIntervalSince1970).write(to: fileURL, atomically: true, encoding: .utf8)
        return now
    }

    // MARK: - Verification

    nonisolated static func verify(_ key: String) -> Result<LicenseInfo, LicenseError> {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "DS1",
              let payload = Data(base64URL: parts[1]),
              let signature = Data(base64URL: parts[2]) else { return .failure(.malformed) }
        guard let pubData = Data(hex: publicKeyHex), pubData.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData) else {
            return .failure(.badSignature)
        }
        guard publicKey.isValidSignature(signature, for: payload) else { return .failure(.badSignature) }
        struct Payload: Decodable { let e: String; let i: Double; let x: Double }
        guard let p = try? JSONDecoder().decode(Payload.self, from: payload) else { return .failure(.malformed) }
        let info = LicenseInfo(email: p.e, issued: Date(timeIntervalSince1970: p.i),
                               expires: p.x > 0 ? Date(timeIntervalSince1970: p.x) : nil, key: key)
        return .success(info)
    }
}

extension Data {
    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        self.init(base64Encoded: s)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(hex: String) {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }
        var data = Data(capacity: clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let b = UInt8(clean[idx..<next], radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        self = data
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
