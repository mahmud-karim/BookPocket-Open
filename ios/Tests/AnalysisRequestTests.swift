import XCTest
@testable import BookPocketOpen

private final class AnalysisRequestProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    static var statusCode = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { throw BookError.message("Missing test request body") }
        stream.open(); defer { stream.close() }
        var data = Data(); var bytes = [UInt8](repeating: 0, count: 1024)
        while true {
            let capacity = bytes.count
            let count = stream.read(&bytes, maxLength: capacity)
            if count == 0 { return data }
            guard count > 0 else { throw stream.streamError ?? BookError.message("Test body stream failed") }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
}

final class AnalysisRequestTests: XCTestCase {
    override func tearDown() {
        AnalysisRequestProtocol.handler = nil; AnalysisRequestProtocol.statusCode = 200
        super.tearDown()
    }
    @MainActor func testActualAnalysisPostRequiresCapabilityAndPreservesRequestPayload() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { AnalysisRequestProtocol.handler = nil; try? FileManager.default.removeItem(at: folder) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AnalysisRequestProtocol.self]
        let client = try CompanionClient(url: URL(string: "https://analysis-fixture.example")!, fingerprint: nil, configuration: configuration)
        let store = CompanionStore(root: folder, client: client)
        let request = CastAnalysisRequest(requestId: UUID().uuidString.lowercased(), allowHosted: true)
        var capable = false; var paths: [String] = []; var received: [CastAnalysisRequest] = []
        AnalysisRequestProtocol.handler = { networkRequest in
            paths.append(networkRequest.url!.path)
            if networkRequest.url!.path == "/v1/health" { return Data((capable ? #"{"capabilities":["analysis_request_id"]}"# : #"{"capabilities":["source_ranges"]}"#).utf8) }
            XCTAssertEqual(networkRequest.httpMethod, "POST")
            let body = try AnalysisRequestProtocol.body(networkRequest)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["request_id"] as? String, request.requestId)
            XCTAssertEqual(json["allow_hosted"] as? Bool, true)
            received.append(try CompanionClient.decoder.decode(CastAnalysisRequest.self, from: body))
            return Data(#"{"id":"original-analysis","book_id":"book","status":"completed","completed_segments":1,"total_segments":1}"#.utf8)
        }
        do { _ = try await store.analyze("book", request: request); XCTFail("Old companions cannot safely receive this request") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Update PC Companion")) }
        XCTAssertEqual(paths, ["/v1/health"])
        capable = true
        let first = try await store.analyze("book", request: request)
        let recovered = try await store.analyze("book", request: request)
        XCTAssertEqual(first.id, recovered.id)
        XCTAssertEqual(received, [request, request])
        XCTAssertEqual(paths.filter { $0 == "/v1/health" }.count, 3, "Every actual POST attempt must check current capability")
    }
    @MainActor func testHTTPAnalysisRejectionRetainsStatusAndActionableDetail() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AnalysisRequestProtocol.self]
        let client = try CompanionClient(url: URL(string: "https://analysis-fixture.example")!, fingerprint: nil, configuration: configuration)
        let store = CompanionStore(root: folder, client: client)
        AnalysisRequestProtocol.handler = { request in
            if request.url!.path == "/v1/health" {
                AnalysisRequestProtocol.statusCode = 200
                return Data(#"{"capabilities":["analysis_request_id"]}"#.utf8)
            }
            AnalysisRequestProtocol.statusCode = 409
            return Data(#"{"detail":"Another casting analysis is running"}"#.utf8)
        }
        do {
            _ = try await store.analyze("book", request: .init(requestId: UUID().uuidString.lowercased(), allowHosted: false))
            XCTFail("A rejected analysis must surface its HTTP status")
        } catch let error as CompanionHTTPError {
            XCTAssertEqual(error.statusCode, 409)
            XCTAssertTrue(error.definitivelyRejected)
            XCTAssertEqual(error.localizedDescription, "Another casting analysis is running")
        }
    }
}
