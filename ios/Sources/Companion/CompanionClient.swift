import Foundation
import Security
import CryptoKit

enum DeviceKeychain {
    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.bookpocket.open.companion", kSecAttrAccount as String: account]
        let update: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            let add = query.merging(update) { _, new in new }
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw BookError.message("Unable to save this companion's credential in Keychain.") }
        } else if status != errSecSuccess { throw BookError.message("Unable to update this companion's credential in Keychain.") }
    }
    static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.bookpocket.open.companion", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func remove(account: String) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.bookpocket.open.companion", kSecAttrAccount as String: account] as CFDictionary) }
}

/// Trust is confined to one origin and one QR-verified leaf certificate.
final class PinnedSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let origin: URL
    let fingerprint: String?
    init(origin: URL, fingerprint: String?) { self.origin = origin; self.fingerprint = fingerprint }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let fingerprint else { completionHandler(.performDefaultHandling, nil); return }
        guard challenge.protectionSpace.host.lowercased() == origin.host?.lowercased(), challenge.protectionSpace.port == (origin.port ?? 443), let trust = challenge.protectionSpace.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let actual = SourceIdentity.hash(SecCertificateCopyData(leaf) as Data)
        guard actual == fingerprint else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        if !Self.isLocalHost(challenge.protectionSpace.host), !SecTrustEvaluateWithError(trust, nil) { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") || (!host.contains(".") && !host.contains(":")) { return true }
        if host == "::1" || (host.contains(":") && (host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:"))) { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 10 || octets[0] == 127 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 169 && octets[1] == 254) || (octets[0] == 100 && (64...127).contains(octets[1]))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == origin.scheme, url.host == origin.host, (url.port ?? 443) == (origin.port ?? 443) else { completionHandler(nil); return }
        completionHandler(request)
    }
}

final class CompanionClient {
    let baseURL: URL
    let fingerprint: String?
    var token: String?
    private let delegate: PinnedSessionDelegate
    private let session: URLSession
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }()
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; e.outputFormatting = [.sortedKeys]; return e }()
    init(url: URL, fingerprint: String?, token: String? = nil, configuration: URLSessionConfiguration? = nil) throws {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw BookError.message("Use the companion's HTTPS address without credentials, queries, or fragments.") }
        let cleaned = fingerprint?.replacingOccurrences(of: ":", with: "").lowercased()
        if let cleaned, !cleaned.isEmpty, cleaned.count != 64 || cleaned.contains(where: { !$0.isHexDigit }) { throw BookError.message("The certificate fingerprint must contain 64 hexadecimal characters.") }
        baseURL = url; self.fingerprint = cleaned?.isEmpty == false ? cleaned : nil; self.token = token
        delegate = PinnedSessionDelegate(origin: url, fingerprint: self.fingerprint)
        let config = configuration ?? URLSessionConfiguration.default
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 3600
        config.urlCache = nil; config.httpCookieStorage = nil; config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json", bearer: String? = nil) throws -> URLRequest {
        guard path.starts(with: "/v1/"), !path.contains(".."), let url = URL(string: path, relativeTo: baseURL)?.absoluteURL, url.host == baseURL.host, url.scheme == baseURL.scheme, url.port == baseURL.port else { throw BookError.message("The companion returned an invalid resource address.") }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        if path == "/v1/health" { request.timeoutInterval = 8 }
        if path.hasSuffix("/export") { request.timeoutInterval = 3600 }
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let bearer = bearer ?? token { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        return request
    }
    static func narrationMessage(for error: Error) -> String {
        guard let failure = error as? URLError else { return error.localizedDescription }
        switch failure.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet:
            return "PC companion is offline or unreachable. Open Book Pocket Open on your PC, check that both devices are on the same Wi-Fi or connected through Tailscale, then refresh."
        default: return error.localizedDescription
        }
    }
    func send<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json", bearer: String? = nil) async throws -> T {
        let (data, response) = try await session.data(for: request(path, method: method, body: body, contentType: contentType, bearer: bearer))
        try validate(response, data: data)
        return try Self.decoder.decode(T.self, from: data)
    }
    func command(_ path: String) async throws {
        let (data, response) = try await session.data(for: request(path, method: "DELETE"))
        try validate(response, data: data)
    }
    func download(_ asset: AudioAsset, to destination: URL) async throws {
        let (temp, response) = try await session.download(for: request(asset.url))
        try validate(response, data: nil)
        let data = try Data(contentsOf: temp, options: .mappedIfSafe)
        guard data.count == asset.bytes, SourceIdentity.hash(data) == asset.sha256.lowercased() else { throw BookError.message("This audio download was incomplete or did not match its checksum. Retry the download.") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }
    func uploadBook(_ url: URL, displayName: String) async throws -> RemoteBook {
        let boundary = UUID().uuidString
        let body = try multipart(boundary: boundary, fields: [:], fileURL: url, field: "file", filename: displayName)
        return try await send("/v1/books", method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }
    func downloadBookSource(_ book: RemoteBook) async throws -> URL {
        let (temporary, response) = try await session.download(for: request("/v1/books/\(book.id)/source"))
        try validate(response, data: nil)
        let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
        guard SourceIdentity.hash(data) == book.sourceSha256.lowercased() else { throw BookError.message("The downloaded book did not match its original checksum. Retry the download.") }
        let ext = data.starts(with: [0x50, 0x4b]) ? "epub" : "txt"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(book.title.prefix(100)).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        let destination = folder.appendingPathComponent(name.isEmpty ? "Book" : name).appendingPathExtension(ext)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
    func cloneVoice(name: String, engine: String, language: String, transcript: String, sample: URL) async throws -> RemoteVoice {
        let boundary = UUID().uuidString
        let body = try multipart(boundary: boundary, fields: ["name": name, "engine": engine, "language": language, "transcript": transcript], fileURL: sample, field: "reference", filename: sample.lastPathComponent)
        return try await send("/v1/voices", method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }
    private func multipart(boundary: String, fields: [String: String], fileURL: URL, field: String, filename: String) throws -> Data {
        var data = Data()
        func append(_ text: String) { data.append(Data(text.utf8)) }
        for (name, value) in fields { append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n") }
        let safeName = filename.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        data.append(try Data(contentsOf: fileURL)); append("\r\n--\(boundary)--\r\n"); return data
    }
    private func validate(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["detail"] as? String
            throw BookError.message(detail ?? "Companion request failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)). Check that your PC is awake and this device is still paired.")
        }
    }
}
