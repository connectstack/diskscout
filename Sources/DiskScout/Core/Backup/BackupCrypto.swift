import Foundation
import CommonCrypto

// Encrypted iPhone backups (Finder / iTunes format).
//
// Manifest.plist holds a keybag: per-protection-class keys, each wrapped (RFC 3394) with a key
// derived from the backup password — PBKDF2-HMAC-SHA256 (DPSL/DPIC, iOS 10.2+) then
// PBKDF2-HMAC-SHA1 (SALT/ITER). Manifest.db and every file are AES-256-CBC with a zero IV, each
// under its own key wrapped by its protection class key. Only Apple's CommonCrypto is used.

enum BackupCryptoError: LocalizedError, Equatable {
    case wrongPassword
    case badKeybag(String)
    case noKeyForClass(Int)
    case unwrapFailed
    case decryptFailed

    var errorDescription: String? {
        switch self {
        case .wrongPassword: return "That password doesn't unlock this backup."
        case .badKeybag(let why): return "The backup's key information is damaged (\(why))."
        case .noKeyForClass(let c): return "The backup has no usable key for protection class \(c)."
        case .unwrapFailed: return "A key in the backup couldn't be unwrapped."
        case .decryptFailed: return "A file in the backup couldn't be decrypted."
        }
    }
}

struct BackupKeybag {
    struct ClassKey {
        var protectionClass: Int
        var wrap: Int
        var wrappedKey: Data
        var key: Data?
    }

    private(set) var attributes: [String: Data] = [:]
    private(set) var classKeys: [Int: ClassKey] = [:]

    private static let wrapPasscode = 2

    /// Parses the TLV keybag: 4-byte tag, 4-byte big-endian length, value. The first UUID/WRAP
    /// describe the keybag; each later UUID starts a class key (CLAS, WRAP, WPKY, KTYP, PBKY).
    init(_ data: Data) throws {
        var offset = data.startIndex
        var sawUUID = false, sawWrap = false
        var current: [String: Data]?
        func flush() throws {
            guard let c = current else { return }
            guard let clas = c["CLAS"].map(Self.int), let wpky = c["WPKY"] else { return }
            classKeys[clas] = ClassKey(protectionClass: clas, wrap: c["WRAP"].map(Self.int) ?? 0, wrappedKey: wpky)
        }
        while offset + 8 <= data.endIndex {
            let tag = String(decoding: data[offset ..< offset + 4], as: UTF8.self)
            let length = Int(Self.int(data[offset + 4 ..< offset + 8]))
            let start = offset + 8
            guard length >= 0, start + length <= data.endIndex else { throw BackupCryptoError.badKeybag("truncated \(tag)") }
            let value = Data(data[start ..< start + length])
            offset = start + length
            switch tag {
            case "UUID" where !sawUUID:
                sawUUID = true
                attributes["UUID"] = value
            case "WRAP" where !sawWrap:
                sawWrap = true
                attributes["WRAP"] = value
            case "UUID":
                try flush()
                current = ["UUID": value]
            case "CLAS", "WRAP", "WPKY", "KTYP", "PBKY":
                current?[tag] = value
            default:
                attributes[tag] = value
            }
        }
        try flush()
        guard !classKeys.isEmpty else { throw BackupCryptoError.badKeybag("no class keys") }
    }

    static func int(_ d: Data) -> Int {
        d.reduce(0) { $0 << 8 | Int($1) }
    }

    func attributeInt(_ tag: String) -> Int? { attributes[tag].map(Self.int) }

    /// Derives the passcode key from the backup password and unwraps the class keys.
    /// Throws `wrongPassword` when the password is wrong (the RFC 3394 integrity check fails).
    /// Slow on purpose (about ten million PBKDF2 rounds): call off the main thread.
    mutating func unlock(password: String) throws {
        guard let salt = attributes["SALT"], !salt.isEmpty, let iter = attributeInt("ITER") else { throw BackupCryptoError.badKeybag("no salt") }
        // Real backups use about 10,000 and 10,000,000 rounds. Anything outside a sane range is a
        // damaged file, and would otherwise crash or run for hours.
        let sane = 1...100_000_000
        guard sane.contains(iter) else { throw BackupCryptoError.badKeybag("bad round count") }
        var secret = Data(password.utf8)
        if let dpsl = attributes["DPSL"], let dpic = attributeInt("DPIC") {
            guard !dpsl.isEmpty, sane.contains(dpic), let first = BackupAES.pbkdf2(secret, salt: dpsl, rounds: dpic, sha256: true) else {
                throw BackupCryptoError.badKeybag("bad round count")
            }
            secret = first
        }
        guard let passcodeKey = BackupAES.pbkdf2(secret, salt: salt, rounds: iter, sha256: false) else { throw BackupCryptoError.badKeybag("key derivation failed") }
        var unlocked = classKeys
        var any = false
        for (clas, ck) in classKeys where ck.wrap & Self.wrapPasscode != 0 {
            guard let key = BackupAES.unwrap(kek: passcodeKey, wrapped: ck.wrappedKey) else { throw BackupCryptoError.wrongPassword }
            unlocked[clas]?.key = key
            any = true
        }
        guard any else { throw BackupCryptoError.badKeybag("no password-protected keys") }
        classKeys = unlocked
    }

    /// Unwraps a per-file (or manifest) key with its protection class key.
    func unwrap(_ wrapped: Data, protectionClass: Int) throws -> Data {
        guard let classKey = classKeys[protectionClass]?.key else { throw BackupCryptoError.noKeyForClass(protectionClass) }
        guard let key = BackupAES.unwrap(kek: classKey, wrapped: wrapped) else { throw BackupCryptoError.unwrapFailed }
        return key
    }

    /// `ManifestKey` / `EncryptionKey` blobs: a 4-byte little-endian protection class, then the wrapped key.
    func unwrapClassPrefixed(_ blob: Data) throws -> Data {
        guard blob.count > 4 + 8 else { throw BackupCryptoError.unwrapFailed }
        let b = [UInt8](blob.prefix(4))
        let clas = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
        return try unwrap(Data(blob.dropFirst(4)), protectionClass: clas)
    }
}

enum BackupAES {
    static func pbkdf2(_ password: Data, salt: Data, rounds: Int, sha256: Bool, length: Int = 32) -> Data? {
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { outBuf in
            password.withUnsafeBytes { pw in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(sha256 ? kCCPRFHmacAlgSHA256 : kCCPRFHmacAlgSHA1),
                                         UInt32(clamping: rounds),
                                         outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        return status == kCCSuccess ? out : nil
    }

    /// RFC 3394 AES key unwrap. Returns nil when the integrity check fails (wrong key).
    static func unwrap(kek: Data, wrapped: Data) -> Data? {
        guard wrapped.count >= 24, wrapped.count % 8 == 0 else { return nil }
        var rawLength = CCSymmetricUnwrappedSize(CCWrappingAlgorithm(kCCWRAPAES), wrapped.count)
        var raw = Data(count: rawLength)
        let status = raw.withUnsafeMutableBytes { rawBuf in
            kek.withUnsafeBytes { k in
                wrapped.withUnsafeBytes { w in
                    CCSymmetricKeyUnwrap(CCWrappingAlgorithm(kCCWRAPAES), CCrfc3394_iv, CCrfc3394_ivLen,
                                         k.baseAddress?.assumingMemoryBound(to: UInt8.self), kek.count,
                                         w.baseAddress?.assumingMemoryBound(to: UInt8.self), wrapped.count,
                                         rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), &rawLength)
                }
            }
        }
        return status == kCCSuccess ? raw.prefix(rawLength) : nil
    }

    /// RFC 3394 AES key wrap (used to build encrypted test backups).
    static func wrap(kek: Data, key: Data) -> Data? {
        var length = CCSymmetricWrappedSize(CCWrappingAlgorithm(kCCWRAPAES), key.count)
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { o in
            kek.withUnsafeBytes { k in
                key.withUnsafeBytes { r in
                    CCSymmetricKeyWrap(CCWrappingAlgorithm(kCCWRAPAES), CCrfc3394_iv, CCrfc3394_ivLen,
                                       k.baseAddress?.assumingMemoryBound(to: UInt8.self), kek.count,
                                       r.baseAddress?.assumingMemoryBound(to: UInt8.self), key.count,
                                       o.baseAddress?.assumingMemoryBound(to: UInt8.self), &length)
                }
            }
        }
        return status == kCCSuccess ? out.prefix(length) : nil
    }

    /// AES-256-CBC with a zero IV, no padding handling (callers trim to the recorded size).
    static func crypt(_ data: Data, key: Data, encrypt: Bool) throws -> Data {
        guard data.count % kCCBlockSizeAES128 == 0 else { throw BackupCryptoError.decryptFailed }
        var out = Data(count: data.count)
        var moved = 0
        let iv = Data(count: kCCBlockSizeAES128)
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                k.baseAddress, key.count, v.baseAddress,
                                i.baseAddress, data.count, o.baseAddress, data.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw BackupCryptoError.decryptFailed }
        return out.prefix(moved)
    }

    /// Streams a file through AES-256-CBC decryption, truncating to `size` (drops the padding).
    static func decryptFile(at source: URL, to destination: URL, key: Data, size: Int64) throws {
        var cryptor: CCCryptorRef?
        let iv = Data(count: kCCBlockSizeAES128)
        let created = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0, k.baseAddress, key.count, v.baseAddress, &cryptor)
            }
        }
        guard created == kCCSuccess, let cryptor else { throw BackupCryptoError.decryptFailed }
        defer { CCCryptorRelease(cryptor) }

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var written: Int64 = 0
        let chunk = 1 << 20
        var outBuf = Data(count: chunk + kCCBlockSizeAES128)
        while written < size, let block = try input.read(upToCount: chunk), !block.isEmpty {
            var moved = 0
            let status = outBuf.withUnsafeMutableBytes { o in
                block.withUnsafeBytes { i in
                    CCCryptorUpdate(cryptor, i.baseAddress, block.count, o.baseAddress, o.count, &moved)
                }
            }
            guard status == kCCSuccess else { throw BackupCryptoError.decryptFailed }
            let keep = Int(min(Int64(moved), size - written))
            try output.write(contentsOf: outBuf.prefix(keep))
            written += Int64(keep)
        }
        guard written == size else { throw BackupCryptoError.decryptFailed }
    }
}
