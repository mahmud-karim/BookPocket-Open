import AVFoundation
import Observation

@MainActor @Observable final class VoiceSampleEditor {
    var source: URL?
    var duration = 0.0
    var start = 0.0
    var end = 0.0
    var playing = false
    private var audio: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?
    func load(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
        try FileManager.default.copyItem(at: url, to: copy)
        let player = try AVAudioPlayer(contentsOf: copy)
        guard player.duration >= 3 else { try? FileManager.default.removeItem(at: copy); throw BookError.message("Choose at least three seconds of clear speech.") }
        stop(); if let source { try? FileManager.default.removeItem(at: source) }
        source = copy; duration = player.duration; start = 0; end = min(30, duration); audio = player
    }
    func preview() throws {
        guard let audio else { return }
        stop()
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        audio.currentTime = start; playing = audio.play()
        stopTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, end - start))) } catch { return }
            self?.stop()
        }
    }
    func stop() { stopTask?.cancel(); audio?.stop(); playing = false }
    func export() async throws -> URL {
        guard let source, end - start >= 3, end - start <= 120, start >= 0, end <= duration else { throw BookError.message("Trim the sample to between 3 and 120 seconds.") }
        stop()
        guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else { throw BookError.message("This recording cannot be trimmed. Choose WAV, M4A, or MP3 audio.") }
        exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        try await exporter.export(to: output, as: .m4a)
        return output
    }
    func cleanUp() { stop(); if let source { try? FileManager.default.removeItem(at: source) }; source = nil; audio = nil }
}
