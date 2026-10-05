import XCTest
import SQLite3
@testable import BookPocketOpen

private final class ConnectionProtocol: URLProtocol {
    static var handler: ((URLRequest) async throws -> (Int, String))?
    private var operation: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        operation = Task {
            do {
                let (status, json) = try await Self.handler!(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { operation?.cancel() }
}

@MainActor private final class ConnectionGate {
    let entered = XCTestExpectation(description: "Authenticated verification is pending")
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
    func finish() { continuation?.resume(); continuation = nil }
}

final class CompanionConnectionTests: XCTestCase {
    private let health = #"{"api_version":"1","capabilities":["source_ranges"]}"#
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionProtocol.self]
        return configuration
    }
    @MainActor private func fixture(_ root: URL) throws -> (CompanionStore, CompanionIdentity) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = CompanionIdentity(url: URL(string: "https://old-fixture.example:8783")!, fingerprint: nil, deviceID: "connection-test-" + UUID().uuidString)
        let database = try LibraryDatabase(url: root.appendingPathComponent("companion.sqlite"))
        try database.write("identity", value: identity)
        let client = try CompanionClient(url: identity.url, fingerprint: nil, token: "unchanged-test-token", configuration: configuration())
        return (CompanionStore(root: root, client: client), identity)
    }
    private func sql(_ statement: String, root: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("companion.sqlite").path, &database) == SQLITE_OK else { throw BookError.message("Cannot open fixture database") }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else { throw BookError.message("Fixture SQL failed") }
    }
    @MainActor func testConnectionStatusRequiresAuthenticatedResponseAndHandlesOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { ConnectionProtocol.handler = nil; try? FileManager.default.removeItem(at: root) }
        let (store, _) = try fixture(root)
        XCTAssertEqual(store.connectionState, .notChecked)
        var authorized = false
        ConnectionProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unchanged-test-token")
            if request.url?.path.hasSuffix("/health") == true { return (200, self.health) }
            return authorized ? (200, #"{"engines":[]}"#) : (401, #"{"detail":"Pair again"}"#)
        }
        await store.checkConnection()
        XCTAssertEqual(store.connectionState, .unavailable, "Public health cannot establish Connected")
        XCTAssertTrue(store.paired, "Offline or revoked access cannot erase saved pairing automatically")
        authorized = true
        await store.checkConnection()
        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertNil(store.connectionError)
        ConnectionProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await store.checkConnection()
        XCTAssertEqual(store.connectionState, .unavailable)
        XCTAssertNotNil(store.connectionError)
        XCTAssertTrue(store.status?.contains("unavailable") == true, "Other screens must not retain a stale Connected message")
    }
    @MainActor func testDisconnectPersistsWithoutRevokingAndForgetKeepsDownloadsOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let (store, old) = try fixture(root)
        defer { DeviceKeychain.remove(account: old.deviceID); ConnectionProtocol.handler = nil; try? FileManager.default.removeItem(at: root) }
        try DeviceKeychain.save("retained-test-token", account: old.deviceID)
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "wav")))
        try bytes.write(to: root.appendingPathComponent("retained.wav"))
        let asset = AudioAsset(id: "retained", segmentId: "source", mediaType: "audio/wav", duration: 0.25, sha256: SourceIdentity.hash(bytes), bytes: bytes.count, url: "/v1/assets/retained", timings: [])
        store.downloads = [DownloadRecord(localBookID: "local", jobID: "job", asset: asset, file: "retained.wav")]
        store.jobs = [RemoteJob(id: "job", bookId: "book", status: "completed", engine: "test", voiceId: "test", segmentIds: ["source"], completedSegments: 1, totalSegments: 1, assets: [asset])]
        var calls = 0
        ConnectionProtocol.handler = { request in
            calls += 1
            XCTAssertNotEqual(request.url?.path, "/v1/devices/current", "Disconnect must never revoke")
            return (200, request.url?.path.hasSuffix("/health") == true ? self.health : #"{"engines":[]}"#)
        }
        try store.pauseConnection()
        XCTAssertTrue(store.paired); XCTAssertEqual(store.identity?.deviceID, old.deviceID)
        XCTAssertEqual(DeviceKeychain.read(account: old.deviceID), "retained-test-token")
        await store.checkConnection(); await store.refresh()
        XCTAssertEqual(calls, 0, "Paused connection must not poll")
        let testClient = try CompanionClient(url: old.url, fingerprint: nil, token: "retained-test-token", configuration: configuration())
        let restored = CompanionStore(root: root, client: testClient)
        XCTAssertTrue(restored.connectionPaused); XCTAssertTrue(restored.paired)
        XCTAssertEqual(restored.connectionState, .disconnected)
        await restored.resumeConnection()
        XCTAssertEqual(restored.connectionState, .connected); XCTAssertEqual(calls, 2)
        XCTAssertFalse(CompanionStore(root: root).connectionPaused)
        ConnectionProtocol.handler = { _ in XCTFail("Forget must work locally without contacting PC"); throw URLError(.notConnectedToInternet) }
        try sql("CREATE TRIGGER reject_forget BEFORE UPDATE OF value ON records WHEN NEW.key = 'identity' BEGIN SELECT RAISE(ABORT, 'test rollback'); END", root: root)
        XCTAssertThrowsError(try restored.forgetConnection())
        XCTAssertEqual(restored.identity?.deviceID, old.deviceID)
        XCTAssertNotNil(DeviceKeychain.read(account: old.deviceID))
        try sql("DROP TRIGGER reject_forget", root: root)
        try restored.forgetConnection()
        XCTAssertFalse(restored.paired); XCTAssertNil(restored.identity)
        XCTAssertNil(DeviceKeychain.read(account: old.deviceID))
        let forgotten = CompanionStore(root: root)
        XCTAssertNil(forgotten.identity); XCTAssertEqual(forgotten.downloads.count, 1)
        XCTAssertEqual(forgotten.orderedDownloads(jobID: "job").count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("retained.wav")), bytes)
    }
    @MainActor func testLateConnectionCheckCannotRestoreLiveStateAfterDisconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { ConnectionProtocol.handler = nil; try? FileManager.default.removeItem(at: root) }
        let (store, _) = try fixture(root)
        let gate = ConnectionGate()
        ConnectionProtocol.handler = { request in
            if request.url?.path.hasSuffix("/health") == true { return (200, self.health) }
            await gate.wait(); return (200, #"{"engines":[]}"#)
        }
        let checking = Task { await store.checkConnection() }
        await fulfillment(of: [gate.entered], timeout: 3)
        try store.pauseConnection(); gate.finish(); await checking.value
        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertTrue(store.connectionPaused); XCTAssertTrue(store.paired)
    }
    @MainActor func testPausedAddressCanChangeWithoutResumingPhoneRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { ConnectionProtocol.handler = nil; try? FileManager.default.removeItem(at: root) }
        let (store, _) = try fixture(root)
        try store.pauseConnection()
        var urls: [String] = []
        ConnectionProtocol.handler = { request in
            urls.append(request.url!.absoluteString)
            return (200, request.url?.path.hasSuffix("/health") == true ? self.health : #"{"engines":[]}"#)
        }
        try await store.updateConnection(url: URL(string: "https://new-fixture.example/bookpocket")!, fingerprint: nil, configuration: configuration())
        XCTAssertEqual(store.connectionState, .disconnected); XCTAssertTrue(store.connectionPaused)
        XCTAssertTrue(store.status?.contains("Disconnected") == true, "Verifying a new address cannot announce that a paused connection resumed")
        await store.checkConnection(); XCTAssertEqual(urls.count, 2)
        await store.resumeConnection()
        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertEqual(urls.last, "https://new-fixture.example/bookpocket/v1/engines")
    }
    @MainActor func testEndpointChangeRequiresAuthenticationAndAtomicallyKeepsExistingIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { ConnectionProtocol.handler = nil; try? FileManager.default.removeItem(at: root) }
        let (store, old) = try fixture(root)
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "wav")))
        try bytes.write(to: root.appendingPathComponent("retained-tone.wav"))
        let asset = AudioAsset(id: "retained-asset", segmentId: "segment", mediaType: "audio/wav", duration: 0.25, sha256: SourceIdentity.hash(bytes), bytes: bytes.count, url: "/v1/assets/retained-asset", timings: [])
        let record = DownloadRecord(localBookID: "local", jobID: "retained-job", asset: asset, file: "retained-tone.wav")
        store.downloads = [record]
        store.jobs = [RemoteJob(id: record.jobID, bookId: "book", status: "completed", engine: "test-tone", voiceId: "test", segmentIds: ["segment"], completedSegments: 1, totalSegments: 1, assets: [asset])]
        let destination = URL(string: "https://public-fixture.ts.net:10000/bookpocket/")!
        var authorized = false, paths: [String] = []
        ConnectionProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unchanged-test-token")
            paths.append(url.absoluteString)
            if url.path.hasSuffix("/health") { return (200, self.health) }
            return authorized ? (200, #"{"engines":[]}"#) : (401, #"{"detail":"Device not paired"}"#)
        }
        do { try await store.updateConnection(url: destination, fingerprint: "", configuration: configuration()); XCTFail("Public health cannot authorize migration") }
        catch { XCTAssertEqual((error as? CompanionHTTPError)?.statusCode, 401) }
        XCTAssertEqual(store.identity?.url, old.url); XCTAssertTrue(store.paired)
        try await store.requireSourceRanges()
        XCTAssertTrue(paths.last?.hasPrefix(old.url.absoluteString) == true, "Failed verification must retain the old working client")
        authorized = true
        try sql("CREATE TRIGGER reject_connection BEFORE UPDATE OF value ON records WHEN NEW.key = 'identity' BEGIN SELECT RAISE(ABORT, 'test rollback'); END", root: root)
        do { try await store.updateConnection(url: destination, fingerprint: nil, configuration: configuration()); XCTFail("A failed commit cannot replace the connection") } catch {}
        XCTAssertEqual(store.identity?.url, old.url)
        XCTAssertEqual(CompanionStore(root: root).identity?.url, old.url)
        try await store.requireSourceRanges()
        XCTAssertTrue(paths.last?.hasPrefix(old.url.absoluteString) == true)
        try sql("DROP TRIGGER reject_connection", root: root)
        let pending = GenerationRequest(requestId: "unchanged-request", bookId: "book", segmentIds: ["segment"], engine: "test", voiceId: "test", language: "en", pronunciationRules: [], announceChapters: false)
        store.pendingRequests = [pending]
        try await store.updateConnection(url: destination, fingerprint: "", configuration: configuration())
        XCTAssertEqual(store.identity?.url.absoluteString, "https://public-fixture.ts.net:10000/bookpocket")
        XCTAssertEqual(store.identity?.deviceID, old.deviceID); XCTAssertNil(store.identity?.fingerprint)
        try await store.requireSourceRanges()
        XCTAssertEqual(paths.last, "https://public-fixture.ts.net:10000/bookpocket/v1/health")
        let restored = CompanionStore(root: root)
        XCTAssertEqual(restored.identity?.url, store.identity?.url)
        XCTAssertEqual(restored.identity?.deviceID, old.deviceID)
        XCTAssertEqual(restored.pendingRequests.first?.requestId, "unchanged-request")
        XCTAssertEqual(restored.jobs.first?.id, record.jobID)
        XCTAssertEqual(restored.downloads.first?.id, record.id)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(record.file)), bytes)
        XCTAssertNil(DeviceKeychain.read(account: old.deviceID), "Changing an endpoint must not create or rewrite the Keychain entry")
    }
    @MainActor func testCancelledOrDisconnectedVerificationCannotInstallLateEndpoint() async throws {
        for disconnect in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { ConnectionProtocol.handler = nil; try? FileManager.default.removeItem(at: root) }
            let (store, old) = try fixture(root)
            let gate = ConnectionGate()
            ConnectionProtocol.handler = { request in
                if request.url?.path == "/v1/devices/current" { return (200, "{}") }
                if request.url?.path.hasSuffix("/health") == true { return (200, self.health) }
                await gate.wait()
                return (200, #"{"engines":[]}"#)
            }
            let operation = Task { try await store.updateConnection(url: URL(string: "https://new-fixture.example/bookpocket")!, fingerprint: nil, configuration: configuration()) }
            await fulfillment(of: [gate.entered], timeout: 3)
            if disconnect { await store.disconnect() } else { operation.cancel() }
            gate.finish()
            do { try await operation.value; XCTFail("Late response must not install a canceled or obsolete endpoint") } catch {}
            XCTAssertEqual(store.identity?.url, disconnect ? nil : old.url)
            XCTAssertEqual(CompanionStore(root: root).identity?.url, disconnect ? nil : old.url)
            XCTAssertFalse(store.updatingConnection)
        }
    }
}
