import Foundation
import CryptoKit
import ReadiumShared

struct LocalBook: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var author: String
    var language: String
    var sourceFile: String
    var readingFile: String
    var sourceSHA256: String
    var coverFile: String?
    var locatorJSON: String?
    var progress: Double = 0
    var importedAt: Date = Date()
    var lastOpenedAt: Date = Date()
    var annotations: [BookAnnotation] = []
    var companionBookID: String?
    var audioAssetID: String?
    var audioSeconds: Double = 0
    var locator: Locator? { locatorJSON.flatMap { try? Locator(jsonString: $0) } }
}

struct BookAnnotation: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var kind: String
    var text: String
    var locatorJSON: String
    var date = Date()
    var locator: Locator? { try? Locator(jsonString: locatorJSON) }
}

enum BookError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum SourceIdentity {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func scalarRange(_ start: Int, _ end: Int, in text: String) -> Range<String.Index>? {
        let scalars = text.unicodeScalars
        guard start >= 0, end >= start, end <= scalars.count else { return nil }
        return scalars.index(scalars.startIndex, offsetBy: start)..<scalars.index(scalars.startIndex, offsetBy: end)
    }
}
