import Foundation
import AVFoundation
import Observation

enum PronunciationCorrections {
    static func validate(_ rules: [PronunciationRule]) throws -> [PronunciationRule] {
        guard rules.count <= 500 else { throw BookError.message("Keep pronunciation corrections to 500 entries or fewer.") }
        var terms = Set<String>()
        return try rules.map { rule in
            let term = rule.term.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = rule.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= 256, !replacement.isEmpty, replacement.count <= 1024,
                  !(term + replacement).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  terms.insert(term.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted else {
                throw BookError.message("Enter a unique written word and a pronunciation, without control characters.")
            }
            return .init(term: term, replacement: replacement, enabled: rule.enabled)
        }
    }
    static func apply(_ rules: [PronunciationRule], to original: String) -> String {
        var result = original
        for rule in rules where rule.enabled && !rule.term.isEmpty {
            let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: rule.term) + "(?![\\p{L}\\p{N}_])"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = expression.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: rule.replacement) }
            }
        }
        return result
    }
}

/// Draft comparison uses Apple speech only; it never claims a Kyon preview.
@MainActor @Observable final class PronunciationPreview: NSObject, AVSpeechSynthesizerDelegate {
    private let speech = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?
    var playing = false
    override init() { super.init(); speech.delegate = self }
    func play(_ text: String, language: String) throws {
        stop()
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        activeUtterance = utterance; playing = true; speech.speak(utterance)
    }
    func stop() { activeUtterance = nil; speech.stopSpeaking(at: .immediate); playing = false }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { Task { @MainActor in self.finished(utterance) } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { Task { @MainActor in self.finished(utterance) } }
    private func finished(_ utterance: AVSpeechUtterance) { guard activeUtterance === utterance else { return }; activeUtterance = nil; playing = false }
}
