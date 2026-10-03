import XCTest
@testable import BookPocketOpen

private final class PrefixedCompanionProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class CompanionPrefixTests: XCTestCase {
    func testPrefixedHealthPairingAndVerifiedAssetUseSamePublicHTTPSOrigin() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrefixedCompanionProtocol.self]
        let client = try CompanionClient(url: URL(string: "https://fixture.ts.net:10000/bookpocket/")!, fingerprint: nil, token: "test-device", configuration: configuration)
        XCTAssertEqual(client.baseURL.absoluteString, "https://fixture.ts.net:10000/bookpocket")
        XCTAssertNil(client.fingerprint, "Public HTTPS must retain system PKI, without inventing a LAN pin")
        let bytes = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "wav")))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { PrefixedCompanionProtocol.handler = nil; try? FileManager.default.removeItem(at: destination) }
        var paths: [String] = []
        PrefixedCompanionProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.scheme, "https"); XCTAssertEqual(url.host, "fixture.ts.net"); XCTAssertEqual(url.port, 10000)
            paths.append(url.path)
            switch url.path {
            case "/bookpocket/v1/health":
                XCTAssertEqual(request.timeoutInterval, 8)
                return Data(#"{"status":"ok"}"#.utf8)
            case "/bookpocket/v1/pairings":
                XCTAssertEqual(request.httpMethod, "POST")
                return Data(#"{"status":"pending","id":"request","poll_token":"test-poll"}"#.utf8)
            case "/bookpocket/v1/pairings/request":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-poll")
                return Data(#"{"status":"approved","device_id":"fixture-device","device_token":"test-device"}"#.utf8)
            case "/bookpocket/v1/assets/tone":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-device")
                return bytes
            default: throw URLError(.badURL)
            }
        }
        struct Health: Decodable { var status: String }
        let health: Health = try await client.send("/v1/health")
        XCTAssertEqual(health.status, "ok")
        let pending: PairingStatus = try await client.send("/v1/pairings", method: "POST", body: Data(#"{"code":"TEST"}"#.utf8))
        let approved: PairingStatus = try await client.send("/v1/pairings/" + XCTUnwrap(pending.id), bearer: pending.pollToken)
        XCTAssertEqual(approved.status, "approved")
        let asset = AudioAsset(id: "tone", segmentId: "segment", mediaType: "audio/wav", duration: 0.25, sha256: SourceIdentity.hash(bytes), bytes: bytes.count, url: "/v1/assets/tone", timings: [])
        try await client.download(asset, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(paths, ["/bookpocket/v1/health", "/bookpocket/v1/pairings", "/bookpocket/v1/pairings/request", "/bookpocket/v1/assets/tone"])
    }

    func testPublicQRAndManualBlankPinPreservePKIWhileLANPinIsRetained() throws {
        let offline = CompanionClient.narrationMessage(for: URLError(.cannotConnectToHost))
        XCTAssertTrue(offline.contains("companion address"))
        XCTAssertFalse(offline.contains("same Wi-Fi")); XCTAssertFalse(offline.contains("Tailscale"))
        for field in ["", #", "certificate_sha256":null"#] {
            let json = #"{"url":"https://fixture.ts.net:10000/bookpocket/","code":"TEST""# + field + "}"
            let qr = try CompanionClient.decoder.decode(PairingQR.self, from: Data(json.utf8))
            XCTAssertNil(qr.certificateSha256)
            let client = try CompanionClient(url: XCTUnwrap(URL(string: qr.url)), fingerprint: qr.certificateSha256)
            XCTAssertEqual(try client.request("/v1/pairings").url?.path, "/bookpocket/v1/pairings")
            XCTAssertNil(client.fingerprint)
        }
        let manual = try CompanionClient(url: URL(string: "https://fixture.ts.net:10000/bookpocket")!, fingerprint: "")
        XCTAssertNil(manual.fingerprint)
        let pin = String(repeating: "ab", count: 32)
        let local = try CompanionClient(url: URL(string: "https://192.168.1.20:8783/")!, fingerprint: pin)
        XCTAssertEqual(local.fingerprint, pin)
        XCTAssertEqual(try local.request("/v1/health").url?.absoluteString, "https://192.168.1.20:8783/v1/health")
    }

    func testPrefixParsingAndRedirectsRejectOriginOrPathConfusion() throws {
        let origin = URL(string: "https://fixture.ts.net:10000/bookpocket")!
        let client = try CompanionClient(url: origin, fingerprint: nil)
        for path in ["/v1/../secret", "/v1/./health", "/v1/%2e%2e/secret", "/v1/%252e%252e/secret", "/v1/assets%2ftone", "/v1/assets\\tone", "/v1//health", "//evil.example/v1/health", "https://evil.example/v1/health", "/v1/health?redirect=evil", "/v1/health#fragment", "/v1/health\n"] {
            XCTAssertThrowsError(try client.request(path), path)
        }
        for address in ["https://user:secret@fixture.ts.net/bookpocket", "https://fixture.ts.net/bookpocket?x=1", "https://fixture.ts.net/bookpocket#x", "https://fixture.ts.net/book%70ocket", "https://fixture.ts.net/bookpocket/../other", "https://fixture.ts.net/bookpocket/./other", "https://fixture.ts.net/bookpocket//other", "https://fixture.ts.net/book%2fpocket", "https://fixture.ts.net/book%5cpocket"] {
            XCTAssertThrowsError(try CompanionClient(url: XCTUnwrap(URL(string: address)), fingerprint: nil), address)
        }
        XCTAssertTrue(CompanionEndpoint.allows(URL(string: "https://fixture.ts.net:10000/bookpocket/v1/assets/tone")!, base: origin))
        for address in ["http://fixture.ts.net:10000/bookpocket/v1/health", "https://evil.example:10000/bookpocket/v1/health", "https://fixture.ts.net/bookpocket/v1/health", "https://fixture.ts.net:10000/v1/health", "https://fixture.ts.net:10000/bookpocket-evil/v1/health", "https://fixture.ts.net:10000/bookpocket/v1/../other", "https://fixture.ts.net:10000/bookpocket/v1/%2e%2e/other", "https://user:secret@fixture.ts.net:10000/bookpocket/v1/health", "https://fixture.ts.net:10000/bookpocket/v1/health?token=x"] {
            XCTAssertFalse(CompanionEndpoint.allows(try XCTUnwrap(URL(string: address)), base: origin), address)
        }
    }
}
