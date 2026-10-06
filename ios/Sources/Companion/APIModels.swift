import Foundation
import ReadiumShared

enum WireJSON: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: WireJSON]), array([WireJSON]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: WireJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([WireJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let v): try c.encode(v); case .number(let v): try c.encode(v); case .bool(let v): try c.encode(v); case .object(let v): try c.encode(v); case .array(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
    var locator: Locator? {
        guard let data = try? JSONEncoder().encode(self), let string = String(data: data, encoding: .utf8) else { return nil }
        return try? Locator(jsonString: string)
    }
}

struct RemoteBook: Codable, Identifiable {
    var id: String
    var title: String
    var author: String
    var language: String
    var sourceSha256: String
    var chapters: [RemoteChapter]
    var segments: [RemoteSegment] { chapters.flatMap(\.segments) }
}
struct RemoteChapter: Codable, Identifiable {
    var id: String
    var title: String
    var href: String
    var segments: [RemoteSegment]
}
struct RemoteSegment: Codable, Identifiable {
    var id: String
    var text: String
    var kind: String
    var locator: WireJSON
}
struct RemoteVoice: Codable, Identifiable {
    var id: String
    var name: String
    var engine: String
    var kind: String
    var language: String
}
struct RemoteEngine: Codable, Identifiable {
    var id: String
    var name: String
    var available: Bool
    var supportsCloning: Bool
    var languages: [String]
    var license: String
    var reason: String?
}
struct AudioTiming: Codable, Equatable {
    var start: Double
    var end: Double
    var startOffset: Int
    var endOffset: Int
}
struct AudioAsset: Codable, Identifiable {
    var id: String
    var segmentId: String?
    var mediaType: String
    var duration: Double
    var sha256: String
    var bytes: Int
    var url: String
    var timings: [AudioTiming]
    var sourceStart: Int?
    var sourceEnd: Int?
    var narrationMode: String? = nil
    var castSpans: [NarrationSpan]? = nil
    var alignment: String? = nil
    var sourceTimings: [AudioTiming]? = nil
}
struct RemoteJob: Codable, Identifiable {
    var id: String
    var bookId: String
    var status: String
    var engine: String
    var voiceId: String
    var segmentIds: [String]
    var completedSegments: Int
    var totalSegments: Int
    var generationSeconds: Double?
    var error: String?
    var assets: [AudioAsset]
    var createdAt: String?
    var sourceRanges: [SourceRange]?
    var narrationMode: String? = nil
    var narrationPlan: [NarrationSpan]? = nil
    var cast: [String: String]? = nil
    var voiceName: String? = nil
    var alignmentStatus: String? = nil
    var alignmentError: String? = nil
}
struct PronunciationRule: Codable, Identifiable, Equatable {
    var term: String
    var replacement: String
    var enabled = true
    var id: String { term }
}
struct PronunciationSettings: Codable {
    var pronunciationRules: [PronunciationRule]
    var revision: Int?
}
struct GenerationRequest: Codable {
    var requestId: String
    var bookId: String
    var segmentIds: [String]
    var engine: String
    var voiceId: String
    var language: String
    var pronunciationRules: [PronunciationRule]
    var announceChapters: Bool
    var cast: [String: String]?
    var narrationPlan: [NarrationSpan]?
    var takeId: String?
    var sourceRanges: [SourceRange]?
    var narrationMode: String? = nil
}
struct SourceRange: Codable, Equatable {
    var segmentId: String
    var startOffset: Int
    var endOffset: Int
}
struct CastCharacter: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var aliases: [String]
    var voiceId: String?
}
struct CastAssignment: Codable, Identifiable, Equatable {
    var id: String
    var segmentId: String
    var startOffset: Int
    var endOffset: Int
    var characterId: String
    var confidence: Double
    var reviewed: Bool
}
struct BookCast: Codable, Equatable {
    var characters: [CastCharacter] = []
    var assignments: [CastAssignment] = []
}
struct NarrationSpan: Codable, Equatable {
    var segmentId: String
    var startOffset: Int
    var endOffset: Int
    var voiceId: String
}
struct CastAnalysisRequest: Codable, Equatable {
    var requestId: String
    var allowHosted: Bool
    var chapterIds: [String]? = nil
    var forceReanalyze: Bool? = nil
}
struct AnalysisJob: Codable, Identifiable {
    var id: String
    var bookId: String
    var status: String
    var completedSegments: Int
    var totalSegments: Int
    var error: String?
    var warnings: [String]?
    var chapterIds: [String]? = nil
    var reusedChapterIds: [String]? = nil
}
struct ChapterAnalysisStatus: Codable, Identifiable {
    var chapterId: String
    var status: String
    var analysisId: String?
    var error: String?
    var id: String { chapterId }
}
struct VoicePreviewRequest: Codable, Equatable {
    var requestId: String
    var voiceId: String
    var text: String
    var language: String
}
struct VoicePreviewJob: Codable, Identifiable {
    var id: String
    var voiceId: String
    var status: String
    var createdAt: String?
    var error: String?
    var asset: AudioAsset?
}
struct SavedVoiceAudition: Codable {
    var request: VoicePreviewRequest
    var job: VoicePreviewJob?
}
struct PairingQR: Codable {
    var url: String
    var certificateSha256: String?
    var code: String
}
struct PairingStatus: Decodable {
    var id: String?
    var pollToken: String?
    var status: String
    var deviceToken: String?
    var deviceId: String?
}
struct CompanionIdentity: Codable {
    var url: URL
    var fingerprint: String?
    var deviceID: String
}
struct DownloadRecord: Codable, Identifiable {
    var id: String { jobID + ":" + asset.id }
    var localBookID: String
    var jobID: String
    var asset: AudioAsset
    var file: String
    var segment: RemoteSegment?
    var legacyTitle: String?
    var legacyMapping: String?
}
struct DownloadedChapter: Identifiable {
    var id: String
    var title: String
    var firstRecord: DownloadRecord
}
struct DownloadedChapterGroup: Identifiable {
    var id: String
    var title: String
    var takes: [DownloadedChapterTake]
}
struct DownloadedChapterTake: Identifiable {
    var id: String
    var jobID: String
    var description: String
    var scope: String
    var recordIDs: [String]
    var firstRecord: DownloadRecord
}
struct LegacyRecording: Codable, Identifiable {
    var id: String
    var bookId: String
    var title: String
    var asset: AudioAsset
    var mapping: String
    var sourceText: String?
}
