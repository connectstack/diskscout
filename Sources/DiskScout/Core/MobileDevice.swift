import Foundation
import AppKit

// Bridge to Apple's MobileDevice framework: the private framework Finder uses to sync iPhones.
// It ships with every Mac (no Xcode needed). It's loaded with dlopen so DiskScout still launches
// if Apple ever moves or changes it; the iPhone features simply don't appear.
//
// Everything here is synchronous and must run on the owning DeviceLink's queue (session calls)
// or on any single background thread (an already-open service connection).

typealias MDRef = UnsafeMutableRawPointer

final class MobileDeviceAPI: @unchecked Sendable {
    typealias NotificationCallback = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer?) -> Void

    static let shared: MobileDeviceAPI? = MobileDeviceAPI()

    let subscribe: @convention(c) (NotificationCallback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    let copyDeviceIdentifier: @convention(c) (MDRef) -> Unmanaged<CFString>?
    let getInterfaceType: @convention(c) (MDRef) -> Int32
    let connect, disconnect, isPaired, pair, validatePairing, startSession, stopSession: @convention(c) (MDRef) -> Int32
    let copyValue: @convention(c) (MDRef, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
    let secureStartService: @convention(c) (MDRef, CFString, CFDictionary?, UnsafeMutablePointer<MDRef?>) -> Int32
    let lookupApplications: @convention(c) (MDRef, CFDictionary?, UnsafeMutablePointer<Unmanaged<CFDictionary>?>) -> Int32
    let copyErrorText: (@convention(c) (Int32) -> Unmanaged<CFString>?)?

    let serviceSend: @convention(c) (MDRef, CFPropertyList, Int) -> Int32
    let serviceReceive: @convention(c) (MDRef, UnsafeMutablePointer<Unmanaged<CFPropertyList>?>, UnsafeMutablePointer<Int>?) -> Int32
    let serviceInvalidate: @convention(c) (MDRef) -> Void
    let serviceGetSocket: @convention(c) (MDRef) -> Int32
    let serviceGetSecureContext: @convention(c) (MDRef) -> MDRef?

    let afcConnectionOpen: @convention(c) (Int32, UInt32, UnsafeMutablePointer<MDRef?>) -> Int32
    let afcSetSecureContext: @convention(c) (MDRef, MDRef?) -> Int32
    let afcConnectionClose: @convention(c) (MDRef) -> Int32
    let afcDirectoryOpen: @convention(c) (MDRef, UnsafePointer<CChar>, UnsafeMutablePointer<MDRef?>) -> Int32
    let afcDirectoryRead: @convention(c) (MDRef, MDRef, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    let afcDirectoryClose: @convention(c) (MDRef, MDRef) -> Int32
    let afcDirectoryCreate: @convention(c) (MDRef, UnsafePointer<CChar>) -> Int32
    let afcFileInfoOpen: @convention(c) (MDRef, UnsafePointer<CChar>, UnsafeMutablePointer<MDRef?>) -> Int32
    let afcKeyValueRead: @convention(c) (MDRef, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    let afcKeyValueClose: @convention(c) (MDRef) -> Int32
    let afcRemovePath: @convention(c) (MDRef, UnsafePointer<CChar>) -> Int32
    let afcFileRefOpen: @convention(c) (MDRef, UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UInt64>) -> Int32
    let afcFileRefWrite: @convention(c) (MDRef, UInt64, UnsafeRawPointer, UInt32) -> Int32
    let afcFileRefClose: @convention(c) (MDRef, UInt64) -> Int32
    // The length is in/out and its width isn't documented; an 8-byte slot is safe whether the
    // framework writes 4 bytes (low half, little-endian) or 8. A 4-byte slot corrupted the stack.
    let afcFileRefRead: @convention(c) (MDRef, UInt64, UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    let afcFileRefSeek: @convention(c) (MDRef, UInt64, Int64, UInt64) -> Int32

    private init?() {
        let paths = [
            "/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
            "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice",
        ]
        guard let h = paths.lazy.compactMap({ dlopen($0, RTLD_NOW) }).first else { return nil }
        var missing = false
        func f<T>(_ name: String, _: T.Type = T.self) -> T {
            guard let p = dlsym(h, name) else {
                missing = true
                // Any non-null placeholder; init fails before it could be called.
                return unsafeBitCast(dlsym(h, "AMDeviceConnect") ?? UnsafeMutableRawPointer(bitPattern: 1)!, to: T.self)
            }
            return unsafeBitCast(p, to: T.self)
        }
        subscribe = f("AMDeviceNotificationSubscribe")
        copyDeviceIdentifier = f("AMDeviceCopyDeviceIdentifier")
        getInterfaceType = f("AMDeviceGetInterfaceType")
        connect = f("AMDeviceConnect")
        disconnect = f("AMDeviceDisconnect")
        isPaired = f("AMDeviceIsPaired")
        pair = f("AMDevicePair")
        validatePairing = f("AMDeviceValidatePairing")
        startSession = f("AMDeviceStartSession")
        stopSession = f("AMDeviceStopSession")
        copyValue = f("AMDeviceCopyValue")
        secureStartService = f("AMDeviceSecureStartService")
        lookupApplications = f("AMDeviceLookupApplications")
        copyErrorText = dlsym(h, "AMDCopyErrorText").map { unsafeBitCast($0, to: (@convention(c) (Int32) -> Unmanaged<CFString>?).self) }
        serviceSend = f("AMDServiceConnectionSendMessage")
        serviceReceive = f("AMDServiceConnectionReceiveMessage")
        serviceInvalidate = f("AMDServiceConnectionInvalidate")
        serviceGetSocket = f("AMDServiceConnectionGetSocket")
        serviceGetSecureContext = f("AMDServiceConnectionGetSecureIOContext")
        afcConnectionOpen = f("AFCConnectionOpen")
        afcSetSecureContext = f("AFCConnectionSetSecureContext")
        afcConnectionClose = f("AFCConnectionClose")
        afcDirectoryOpen = f("AFCDirectoryOpen")
        afcDirectoryRead = f("AFCDirectoryRead")
        afcDirectoryClose = f("AFCDirectoryClose")
        afcDirectoryCreate = f("AFCDirectoryCreate")
        afcFileInfoOpen = f("AFCFileInfoOpen")
        afcKeyValueRead = f("AFCKeyValueRead")
        afcKeyValueClose = f("AFCKeyValueClose")
        afcRemovePath = f("AFCRemovePath")
        afcFileRefOpen = f("AFCFileRefOpen")
        afcFileRefWrite = f("AFCFileRefWrite")
        afcFileRefClose = f("AFCFileRefClose")
        afcFileRefRead = f("AFCFileRefRead")
        afcFileRefSeek = f("AFCFileRefSeek")
        if missing { return nil }
    }

    func errorText(_ code: Int32) -> String? {
        copyErrorText?(code)?.takeRetainedValue() as String?
    }
}

// MARK: - Errors

enum DeviceError: LocalizedError, Equatable {
    /// The iPhone hasn't trusted this Mac yet (or the trust was reset).
    case notTrusted
    /// First-time pairing needs the iPhone unlocked.
    case locked
    case disconnected
    case failed(step: String, code: Int32, text: String?)
    case message(String)

    // Meanings confirmed with the framework's own AMDCopyErrorText.
    static let passcodeProtected: Int32 = Int32(bitPattern: 0xE800_001A)   // "The device is passcode protected."
    static let notPaired: Int32 = Int32(bitPattern: 0xE800_0025)           // "The host is not paired with the device."
    static let pairingPending: Int32 = Int32(bitPattern: 0xE800_0096)      // "The user has not yet responded to the pairing request."
    static let pairingProhibited: Int32 = Int32(bitPattern: 0xE800_009A)   // "Pairing is prohibited by a policy on the device."

    var errorDescription: String? {
        switch self {
        case .notTrusted: return "Unlock your iPhone and tap Trust when it asks whether to trust this Mac."
        case .locked: return "Unlock your iPhone so it can pair with this Mac, then tap Trust."
        case .disconnected: return "The iPhone was disconnected."
        case .failed(let step, let code, let text):
            let hex = String(UInt32(bitPattern: code), radix: 16)
            let detail = text.map { " (\($0))" } ?? ""
            return "The iPhone didn't respond while \(step)\(detail). Unplug it, unlock it and plug it back in. [0x\(hex)]"
        case .message(let m): return m
        }
    }

    var needsTrust: Bool { self == .notTrusted || self == .locked }
}

// MARK: - Device link

/// One connection path (USB or Wi-Fi) to one device. Owns a retained AMDevice and a serial
/// queue; every lockdown call for this device goes through that queue.
final class DeviceLink: @unchecked Sendable {
    let api: MobileDeviceAPI
    let ref: MDRef
    let udid: String
    let isWiFi: Bool
    let queue: DispatchQueue

    init?(api: MobileDeviceAPI, ref: MDRef) {
        guard let id = api.copyDeviceIdentifier(ref)?.takeRetainedValue() as String? else { return nil }
        self.api = api
        self.ref = ref
        self.udid = id
        self.isWiFi = api.getInterfaceType(ref) == 2
        self.queue = DispatchQueue(label: "DiskScout.device.\(id).\(isWiFi ? "wifi" : "usb")", qos: .userInitiated)
        _ = Unmanaged<AnyObject>.fromOpaque(ref).retain()
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(ref).release()
    }

    private func check(_ code: Int32, _ step: String) throws {
        guard code != 0 else { return }
        if code == DeviceError.passcodeProtected { throw DeviceError.locked }
        if code == DeviceError.notPaired || code == DeviceError.pairingPending { throw DeviceError.notTrusted }
        if code == DeviceError.pairingProhibited {
            throw DeviceError.message("This iPhone doesn't allow pairing with computers (a school, company or Screen Time setting).")
        }
        throw DeviceError.failed(step: step, code: code, text: api.errorText(code))
    }

    /// Opens a lockdown session around `body`. Must be called on `queue`.
    func withSession<T>(_ body: () throws -> T) throws -> T {
        dispatchPrecondition(condition: .onQueue(queue))
        try check(api.connect(ref), "connecting")
        defer { _ = api.disconnect(ref) }
        if api.isPaired(ref) == 0 { throw DeviceError.notTrusted }
        if api.validatePairing(ref) != 0 { throw DeviceError.notTrusted }
        try check(api.startSession(ref), "starting a session")
        defer { _ = api.stopSession(ref) }
        return try body()
    }

    /// Runs `body` inside a session on the device queue.
    func perform<T>(_ body: @escaping (DeviceLink) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                cont.resume(with: Result { try self.withSession { try body(self) } })
            }
        }
    }

    /// Asks the iPhone to trust this Mac. Shows the Trust prompt on the phone; returns nil once
    /// paired, or the reason it isn't yet (call again after the user taps Trust).
    func requestTrust() async -> DeviceError? {
        await withCheckedContinuation { cont in
            queue.async {
                let api = self.api, ref = self.ref
                guard api.connect(ref) == 0 else { cont.resume(returning: .notTrusted); return }
                defer { _ = api.disconnect(ref) }
                if api.isPaired(ref) != 0 && api.validatePairing(ref) == 0 { cont.resume(returning: nil); return }
                let r = api.pair(ref)
                if r == 0 && api.validatePairing(ref) == 0 { cont.resume(returning: nil); return }
                cont.resume(returning: r == DeviceError.passcodeProtected ? .locked : .notTrusted)
            }
        }
    }

    // MARK: Session-only helpers (call inside `withSession`)

    func value(_ key: String?, domain: String? = nil) -> Any? {
        api.copyValue(ref, domain as CFString?, key as CFString?)?.takeRetainedValue()
    }

    func startService(_ name: String) throws -> ServiceConnection {
        var conn: MDRef?
        try check(api.secureStartService(ref, name as CFString, nil, &conn), "opening \(name)")
        guard let conn else { throw DeviceError.message("The iPhone refused to open \(name).") }
        return ServiceConnection(api: api, conn: conn)
    }

    func lookupApps(attributes: [String]) throws -> [String: [String: Any]] {
        let opts: [String: Any] = ["ApplicationType": "User", "ReturnAttributes": attributes]
        var out: Unmanaged<CFDictionary>?
        try check(api.lookupApplications(ref, opts as CFDictionary, &out), "listing apps")
        return (out?.takeRetainedValue() as? [String: [String: Any]]) ?? [:]
    }
}

// MARK: - Service connection

/// A lockdown service (installation_proxy, springboardservices, AFC…). Usable from any one
/// thread once open; doesn't need the session to stay open.
final class ServiceConnection: @unchecked Sendable {
    let api: MobileDeviceAPI
    let conn: MDRef

    init(api: MobileDeviceAPI, conn: MDRef) {
        self.api = api
        self.conn = conn
    }

    // Invalidate closes the socket. The connection object itself is deliberately not released:
    // ownership of what AMDeviceSecureStartService returns isn't documented, and a tiny leak per
    // refresh beats a crash from an over-release.
    deinit { api.serviceInvalidate(conn) }

    func send(_ message: [String: Any]) throws {
        let r = api.serviceSend(conn, message as CFDictionary, Int(PropertyListSerialization.PropertyListFormat.xml.rawValue))
        if r != 0 { throw DeviceError.failed(step: "sending a request", code: r, text: api.errorText(r)) }
    }

    func receive() throws -> [String: Any] {
        var out: Unmanaged<CFPropertyList>?
        var fmt = 0
        let r = api.serviceReceive(conn, &out, &fmt)
        if r != 0 { throw DeviceError.failed(step: "reading a reply", code: r, text: api.errorText(r)) }
        return (out?.takeRetainedValue() as? [String: Any]) ?? [:]
    }

    func afc() throws -> AFCClient {
        // AFC gets its own duplicate of the socket so closing AFC and invalidating the service
        // each close their own descriptor (never one that's been reused elsewhere).
        let fd = dup(api.serviceGetSocket(conn))
        guard fd >= 0 else { throw DeviceError.message("Couldn't open a file connection to the iPhone.") }
        var afc: MDRef?
        let r = api.afcConnectionOpen(fd, 0, &afc)
        guard r == 0, let afc else {
            close(fd)
            throw DeviceError.failed(step: "opening files", code: r, text: api.errorText(r))
        }
        if let ctx = api.serviceGetSecureContext(conn) { _ = api.afcSetSecureContext(afc, ctx) }
        return AFCClient(api: api, afc: afc, service: self)
    }
}

// MARK: - AFC (file access)

final class AFCClient: @unchecked Sendable {
    let api: MobileDeviceAPI
    let afc: MDRef
    private let service: ServiceConnection   // keeps the service (and its socket) alive

    init(api: MobileDeviceAPI, afc: MDRef, service: ServiceConnection) {
        self.api = api
        self.afc = afc
        self.service = service
    }

    deinit { _ = api.afcConnectionClose(afc) }

    struct Entry {
        let path: String
        let size: Int64
        let isDirectory: Bool
        /// Creation time on the device (falls back to modification time).
        let date: Date?
    }

    func list(_ path: String) -> [String] { listing(path) ?? [] }

    /// Names in a folder, or nil when the folder couldn't be opened (as opposed to being empty).
    func listing(_ path: String) -> [String]? {
        var dir: MDRef?
        guard api.afcDirectoryOpen(afc, path, &dir) == 0, let dir else { return nil }
        defer { _ = api.afcDirectoryClose(afc, dir) }
        var out: [String] = []
        var name: UnsafeMutablePointer<CChar>?
        while api.afcDirectoryRead(afc, dir, &name) == 0, let n = name {
            let s = String(cString: n)
            if s != "." && s != ".." { out.append(s) }
        }
        return out
    }

    func info(_ path: String) -> [String: String]? {
        var i: MDRef?
        guard api.afcFileInfoOpen(afc, path, &i) == 0, let i else { return nil }
        defer { _ = api.afcKeyValueClose(i) }
        var out: [String: String] = [:]
        var k: UnsafeMutablePointer<CChar>?, v: UnsafeMutablePointer<CChar>?
        while api.afcKeyValueRead(i, &k, &v) == 0, let k, let v { out[String(cString: k)] = String(cString: v) }
        return out
    }

    func entry(_ path: String) -> Entry? {
        guard let i = info(path) else { return nil }
        let ns = Double(i["st_birthtime"] ?? i["st_mtime"] ?? "")
        return Entry(path: path, size: Int64(i["st_size"] ?? "") ?? 0, isDirectory: i["st_ifmt"] == "S_IFDIR",
                     date: ns.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1_000_000_000) : nil })
    }

    /// Entries directly inside `path`, with sizes and dates.
    func entries(in path: String) -> [Entry] {
        list(path).compactMap { entry((path == "/" ? "" : path) + "/" + $0) }
    }

    /// Streams a file in chunks. `chunk` returns false to stop early.
    func read(_ path: String, from offset: Int64 = 0, length: Int64? = nil, chunkSize: Int = 1 << 20, chunk: (Data) throws -> Bool) throws {
        var ref: UInt64 = 0
        let r = api.afcFileRefOpen(afc, path, 1, &ref)
        if r != 0 { throw DeviceError.failed(step: "opening \((path as NSString).lastPathComponent)", code: r, text: api.errorText(r)) }
        defer { _ = api.afcFileRefClose(afc, ref) }
        if offset > 0 {
            let s = api.afcFileRefSeek(afc, ref, offset, 0)
            if s != 0 { throw DeviceError.failed(step: "reading \((path as NSString).lastPathComponent)", code: s, text: api.errorText(s)) }
        }
        var remaining = length ?? Int64.max
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buf.deallocate() }
        while remaining > 0 {
            var len = UInt64(min(Int64(chunkSize), remaining))
            let e = api.afcFileRefRead(afc, ref, buf, &len)
            if e != 0 { throw DeviceError.failed(step: "reading \((path as NSString).lastPathComponent)", code: e, text: api.errorText(e)) }
            if len == 0 { break }
            remaining -= Int64(len)
            if try !chunk(Data(bytes: buf, count: Int(len))) { break }
        }
    }

    func readAll(_ path: String, limit: Int64 = 200_000_000) throws -> Data {
        var data = Data()
        try read(path) { c in
            data.append(c)
            if Int64(data.count) > limit { throw DeviceError.message("File is too large to preview.") }
            return true
        }
        return data
    }

    /// Depth-first walk. `visit` returns false to stop early. Returns false when the connection
    /// was lost part-way, so callers don't present a partial walk as the whole picture. (A single
    /// unreadable folder doesn't count: the walk carries on past it.)
    @discardableResult
    func walk(_ root: String, visit: (Entry) -> Bool) -> Bool {
        var stack = [root]
        while let dir = stack.popLast() {
            guard let names = listing(dir) else {
                if info(root) == nil { return false }   // even the starting folder is gone: disconnected
                continue
            }
            for name in names {
                let path = (dir == "/" ? "" : dir) + "/" + name
                guard let e = entry(path) else { continue }
                if !visit(e) { return true }
                if e.isDirectory { stack.append(path) }
            }
        }
        return true
    }

    func remove(_ path: String) throws {
        let r = api.afcRemovePath(afc, path)
        if r != 0 { throw DeviceError.failed(step: "deleting \((path as NSString).lastPathComponent)", code: r, text: api.errorText(r)) }
    }

    /// Removes everything inside `root` (files first, then emptied folders), keeping `root` itself.
    /// Carries on past files it can't delete and reports how many were left.
    @discardableResult
    func removeContents(of root: String) throws -> (files: Int, bytes: Int64, failed: Int) {
        var files: [Entry] = [], dirs: [String] = []
        guard walk(root, visit: { e in
            if e.isDirectory { dirs.append(e.path) } else { files.append(e) }
            return true
        }) else { throw DeviceError.disconnected }
        var removed = 0, failed = 0, bytes: Int64 = 0
        for f in files {
            if api.afcRemovePath(afc, f.path) == 0 {
                removed += 1
                bytes += f.size
            } else {
                failed += 1
            }
        }
        for d in dirs.sorted(by: { $0.count > $1.count }) { try? remove(d) }
        return (removed, bytes, failed)
    }

    func createDirectory(_ path: String) throws {
        let r = api.afcDirectoryCreate(afc, path)
        if r != 0 { throw DeviceError.failed(step: "creating a folder", code: r, text: api.errorText(r)) }
    }

    func write(_ data: Data, to path: String) throws {
        var ref: UInt64 = 0
        // Mode 3 = read/write, create or truncate (what Xcode and ios-deploy use for uploads).
        let r = api.afcFileRefOpen(afc, path, 3, &ref)
        if r != 0 { throw DeviceError.failed(step: "creating a file", code: r, text: api.errorText(r)) }
        defer { _ = api.afcFileRefClose(afc, ref) }
        try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress, buf.count > 0 else { return }
            let w = api.afcFileRefWrite(afc, ref, base, UInt32(buf.count))
            if w != 0 { throw DeviceError.failed(step: "writing a file", code: w, text: api.errorText(w)) }
        }
    }
}
