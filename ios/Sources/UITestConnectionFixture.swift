#if DEBUG
import Foundation

/// Explicit UI transport fixture. No network, Keychain pairing or voice engine.
enum UITestConnectionFixture {
    static var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--connection-fixture")
    }
    @MainActor static func store(root: URL) throws -> CompanionStore {
        URLProtocol.registerClass(ConnectionUITestProtocol.self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
    override class func canInit(with request: URLRequest) -> Bool { UITestConnectionFixture.enabled }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
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
