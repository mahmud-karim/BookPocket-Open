import AVFoundation
import ReadiumNavigator
import ReadiumShared

/// Apple's callbacks use UTF-16, while publication source offsets use scalars.
/// Keep the original utterance and convert its real spoken range explicitly.
final class SystemWordSpeechEngine: NSObject, TTSEngine, AVSpeechSynthesizerDelegate {
    var availableVoices: [TTSVoice] { AVTTSEngine().availableVoices }
    private struct Request {
        let id: UUID
        let utterance: AVSpeechUtterance
        let text: String
        let progress: (Range<String.Index>) -> Void
        let continuation: CheckedContinuation<Result<Void, TTSError>, Never>
        var cancelled = false
    }
    @MainActor private var synthesizer: AVSpeechSynthesizer?
    @MainActor private var active: Request?
    @MainActor private var pending: [Request] = []
    @MainActor private var cancelled: Set<UUID> = []

    static func spokenRange(_ range: NSRange, in original: String) -> Range<String.Index>? {
        guard range.location != NSNotFound, range.length > 0, range.location >= 0,
              range.location <= original.utf16.count, range.length <= original.utf16.count - range.location else { return nil }
        return Range(range, in: original)
    }
    func speak(_ utterance: TTSUtterance, onSpeakRange: @escaping (Range<String.Index>) -> Void) async -> Result<Void, TTSError> {
        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            if Task.isCancelled { return .failure(.other(CancellationError())) }
            return await withCheckedContinuation { continuation in
                Task { @MainActor in
                    if self.cancelled.remove(id) != nil { continuation.resume(returning: .failure(.other(CancellationError()))); return }
                    let voice: AVSpeechSynthesisVoice?
                    switch utterance.voiceOrLanguage {
                    case .left(let chosen): voice = AVSpeechSynthesisVoice(identifier: chosen.identifier)
                    case .right(let language): voice = AVSpeechSynthesisVoice(language: language.code.bcp47)
                    }
                    guard let voice else { continuation.resume(returning: .failure(.languageNotSupported(language: utterance.language, cause: nil))); return }
                    let native = AVSpeechUtterance(string: utterance.text)
                    native.voice = voice; native.preUtteranceDelay = utterance.delay
                    let speed = UserDefaults.standard.double(forKey: "playbackRate")
                    native.rate = min(0.65, max(0.2, AVSpeechUtteranceDefaultSpeechRate * Float(speed == 0 ? 1 : speed)))
                    self.pending.append(.init(id: id, utterance: native, text: utterance.text, progress: onSpeakRange, continuation: continuation))
                    self.startNext()
                }
            }
        }, onCancel: { Task { @MainActor in self.cancel(id) } })
    }
    @MainActor private func startNext() {
        guard active == nil, !pending.isEmpty else { return }
        if synthesizer == nil { synthesizer = AVSpeechSynthesizer(); synthesizer?.delegate = self }
        active = pending.removeFirst(); synthesizer?.speak(active!.utterance)
    }
    @MainActor private func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index).continuation.resume(returning: .failure(.other(CancellationError())))
        } else if active?.id == id {
            active?.cancelled = true
            // Wait for didCancel before starting a new utterance, so its callback
            // cannot finish the next request or resume a continuation twice.
            if synthesizer?.stopSpeaking(at: .immediate) != true, let request = active {
                active = nil; request.continuation.resume(returning: .failure(.other(CancellationError()))); startNext()
            }
        } else { cancelled.insert(id) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard let request = self.active, !request.cancelled, request.utterance === utterance,
                  let originalRange = Self.spokenRange(range, in: request.text) else { return }
            request.progress(originalRange)
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { Task { @MainActor in self.finish(utterance, cancelled: false) } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { Task { @MainActor in self.finish(utterance, cancelled: true) } }
    @MainActor private func finish(_ utterance: AVSpeechUtterance, cancelled: Bool) {
        guard let request = active, request.utterance === utterance else { return }
        active = nil
        request.continuation.resume(returning: (cancelled || request.cancelled) ? .failure(.other(CancellationError())) : .success(()))
        startNext()
    }
}
