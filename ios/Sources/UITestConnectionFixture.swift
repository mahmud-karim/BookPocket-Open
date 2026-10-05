#if DEBUG
import Foundation

/// Explicit UI transport fixture. No network, Keychain pairing or voice engine.
enum UITestConnectionFixture {
    static var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--connection-fixture")
    }
    static func configure(_ configuration: URLSessionConfiguration) {
        configuration.protocolClasses = [ConnectionUITestProtocol.self]
    }
    @MainActor static func store(root: URL) throws -> CompanionStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.arguments.contains("--connection-unpaired") { return CompanionStore(root: root) }
        let identity = CompanionIdentity(url: URL(string: "https://old-connection.invalid")!, fingerprint: nil, deviceID: "test-only-connection-device")
        let client = try CompanionClient(url: identity.url, fingerprint: nil, token: "test-only-connection-token")
        let store = CompanionStore(root: root, client: client)
        store.identity = identity
        let database = try LibraryDatabase(url: root.appendingPathComponent("companion.sqlite"))
        try database.write("identity", value: identity)
        return store
    }
}

private final class ConnectionUITestProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var started = false
    override class func canInit(with request: URLRequest) -> Bool { UITestConnectionFixture.enabled }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let arguments = ProcessInfo.processInfo.arguments
        let isStart = url.path.hasSuffix("/companion/start") && request.httpMethod == "POST"
        let startable = arguments.contains("--connection-startable")
        if startable && isStart {
            let failure = arguments.contains("--connection-start-fails")
            if !failure { Self.lock.withLock { Self.started = true } }
            let json = failure ? #"{"detail":"Pocket Hub test receiver could not acknowledge the launch."}"# : #"{"status":"starting"}"#
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: failure ? 503 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
            return
        }
        if arguments.contains("--connection-unavailable") || (startable && !Self.lock.withLock { Self.started }) {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let allowed = ["old-connection.invalid", "new-connection.invalid"].contains(url.host ?? "")
        let health = url.path.hasSuffix("/health")
        let authorized = allowed && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-connection-token"
        let status = health || authorized ? 200 : 401
        let json: String
        if status == 401 { json = #"{"detail":"Test companion rejected this device."}"# }
        else if health { json = #"{"api_version":"1","capabilities":[]}"# }
        else if url.path.hasSuffix("/engines") { json = #"{"engines":[]}"# }
        else if url.path.hasSuffix("/voices") { json = #"{"voices":[]}"# }
        else if url.path.hasSuffix("/jobs") { json = #"{"jobs":[]}"# }
        else if url.path.hasSuffix("/books") { json = #"{"books":[]}"# }
        else if url.path.hasSuffix("/pronunciations") { json = #"{"pronunciation_rules":[]}"# }
        else { json = #"{"recordings":[]}"# }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
