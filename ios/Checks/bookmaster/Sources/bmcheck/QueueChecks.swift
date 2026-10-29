import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class BridgeState: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [URLRequest] = []
    private var held: BridgeProtocol?
    private var status = 503
    private var holdFirst = false

    func reset(status: Int = 503, holdFirst: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        records = []; held = nil; self.status = status; self.holdFirst = holdFirst
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return records }
    var isHolding: Bool { lock.lock(); defer { lock.unlock() }; return held != nil }
    func setStatus(_ value: Int) { lock.lock(); defer { lock.unlock() }; status = value }
    func receive(_ task: BridgeProtocol) {
        lock.lock()
        records.append(task.request)
        if holdFirst, records.count == 1 { held = task; lock.unlock(); return }
        let reply = status
        lock.unlock()
        task.respond(reply)
    }
    func release(_ status: Int) {
        lock.lock(); let task = held; held = nil; lock.unlock()
        task?.respond(status)
    }
}

private final class BridgeProtocol: URLProtocol, @unchecked Sendable {
    static let state = BridgeState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.state.receive(self) }
    override func stopLoading() {}
    func respond(_ status: Int) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
func runQueueChecks() async {
    section("Native serialized BookMaster queue")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "queue-checks-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(try? JSONEncoder().encode(BMUser(username: "reader", displayName: "Reader")), forKey: "bm-user")
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [BridgeProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let queueURL = root.appendingPathComponent("queue.json")
    let bm = BookMaster(defaults: defaults, session: session, queueURL: queueURL)
    let ref = BMBookRef(title: "It", author: "Stephen King", userBookId: "king")
    func entries() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: queueURL),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return rows
    }
    func body(_ entry: [String: Any]) -> [String: Any] {
        guard let base64 = entry["body"] as? String, let data = Data(base64Encoded: base64) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    func progress(_ value: Double, ref: BMBookRef, key: String = "king", force: Bool = true) async {
        await bm.syncProgress(bookKey: key, ref: ref, percent: value, isAudio: false, force: force, pinned: { _ in })
    }
    BridgeProtocol.state.reset(holdFirst: true)
    let old = Task { await progress(0.1, ref: ref) }
    // waits as long as the machine needs (a busy one — a build running beside — made 200 ms too short), and no longer than it must
    for _ in 0..<10_000 where !BridgeProtocol.state.isHolding { try? await Task.sleep(nanoseconds: 1_000_000) }
    check("older push is in flight", BridgeProtocol.state.isHolding)
    let new = Task { await progress(0.5, ref: ref) }
    for _ in 0..<10_000 where body(entries().first ?? [:])["percent"] as? Double != 50 { try? await Task.sleep(nanoseconds: 1_000_000) }
    check("newer progress is persisted before transport", body(entries().first ?? [:])["percent"] as? Double == 50)
    check("fresh pushes do not overtake the active request", BridgeProtocol.state.requests.count == 1)
    BridgeProtocol.state.release(503)
    await old.value; await new.value
    check("delayed older failure cannot replace newer progress", body(entries().first ?? [:])["percent"] as? Double == 50)
    BridgeProtocol.state.setStatus(200)
    await bm.flush()
    check("recovered bridge drains newest progress", entries().isEmpty)

    BridgeProtocol.state.reset()
    await progress(0.2, ref: ref)
    let other = BMBookRef(title: "It", author: "Alexa Chung", userBookId: "chung")
    await progress(0.6, ref: other, key: "chung")
    check("same-title pinned books both remain queued", entries().count == 2)
    await bm.flush()
    BridgeProtocol.state.setStatus(200)
    await bm.flush()
    BridgeProtocol.state.reset(status: 200)
    await progress(0.3, ref: ref, key: "king-throttle", force: false)
    await progress(0.7, ref: other, key: "chung-throttle", force: false)
    check("local book identities have independent throttles", BridgeProtocol.state.requests.count == 2)

    BridgeProtocol.state.reset()
    let unpinned = BMBookRef(title: "Shared", author: "A")
    await progress(0.1, ref: unpinned, key: "a")
    await progress(0.2, ref: BMBookRef(title: "Shared", author: "B"), key: "b")
    check("same-title unpinned authors stay separate", entries().count == 2)
    bm.syncEnabled = false
    BridgeProtocol.state.reset(status: 200)
    let quote = await bm.postQuote(ref: ref, content: "Kept passage", percent: nil)
    check("explicit quote sends while automatic progress is paused", quote == .sent && BridgeProtocol.state.requests.count == 1)
    check("paused automatic entries remain queued", entries().count == 2)
    BridgeProtocol.state.reset()
    let parked = await bm.postQuote(ref: ref, content: "Offline passage", percent: nil)
    check("offline quote reports queued, not delivered", parked == .queued)
    BridgeProtocol.state.setStatus(200)
    await bm.flush()
    check("offline quote replays while sync is paused", entries().count == 2 && entries().allSatisfy { $0["kind"] as? String == "progress" })
    bm.unlink()
    check("unlink clears pending account data", !FileManager.default.fileExists(atPath: queueURL.path))

    // a denied gate must not push the window forward — an app that comes forward more
    // often than the interval would otherwise never be due again
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    check("first auto pull is due", bm.autoPullDue(now: t0))
    check("a re-entry inside the window is not", !bm.autoPullDue(now: t0 + 60))
    check("a no does not reset the five-minute clock", !bm.autoPullDue(now: t0 + 299))
    check("the window opens five minutes after the yes, not the no", bm.autoPullDue(now: t0 + 300))
}
