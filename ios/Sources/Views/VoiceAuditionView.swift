import SwiftUI
import AVFoundation

/// Plays only a completed, checksum-verified generated companion audition.
/// Reference previews remain separately labelled in the voice creation editor.
struct VoiceAuditionView: View {
    let voice: RemoteVoice
    @Environment(CompanionStore.self) private var companion
    @Environment(PlaybackController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var text = "The lantern casts a warm light across the room."
    @State private var job: VoicePreviewJob?
    @State private var request: VoicePreviewRequest?
    @State private var audio: AVAudioPlayer?
    @State private var busy = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section(voice.name) {
                    Text("Generated audition · \(voice.engine)").accessibilityIdentifier("voice.audition.kind")
                    TextField("Audition text", text: $text, axis: .vertical).lineLimit(3...8).disabled(request != nil).accessibilityIdentifier("voice.audition.text")
                    Text("Your paired PC generates this sample with the selected voice. It does not alter a book or create an audiobook take.").font(.caption).foregroundStyle(.secondary)
                }
                if let job { Text(job.status.capitalized).accessibilityIdentifier("voice.audition.status"); if let error = job.error { Text(error).foregroundStyle(.red) } }
                if busy { ProgressView("Generating audition…") }
                if let error { Text(error).foregroundStyle(.red) }
                Button(request == nil ? "Generate audition" : "Recover or refresh audition") { start() }.disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 1000).accessibilityIdentifier("voice.audition.generate")
                Button("Play generated audition", systemImage: "play.fill") {
                    operation = Task {
                        do {
                            guard let job else { return }; let url = try await companion.voicePreviewAudio(job)
                            guard !Task.isCancelled else { return }; player.pause(); audio = try AVAudioPlayer(contentsOf: url); audio?.play()
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(job?.status != "completed").accessibilityIdentifier("voice.audition.play")
                if let job {
                    Button("Delete audition and start new", role: .destructive) {
                        operation = Task { do { try await companion.removeVoicePreview(job.id); audio?.stop(); self.job = nil; request = nil } catch { self.error = error.localizedDescription } }
                    }.disabled(busy).accessibilityIdentifier("voice.audition.delete")
                }
            }.navigationTitle("Voice audition").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .onAppear { if let saved = companion.voiceAuditions.last(where: { $0.request.voiceId == voice.id }) { request = saved.request; text = saved.request.text; job = saved.job } }
                .onDisappear { operation?.cancel(); audio?.stop() }
        }
    }
    private func start() {
        error = nil; busy = true
        if request == nil { request = VoicePreviewRequest(requestId: UUID().uuidString.lowercased(), voiceId: voice.id, text: text, language: voice.language) }
        guard let request else { busy = false; return }
        operation = Task {
            defer { busy = false }
            do {
                // Lost confirmation retries the persisted original request UUID.
                var current = try await companion.voicePreview(request); job = current
                while ["queued", "running"].contains(current.status) {
                    try await Task.sleep(for: .seconds(3)); try Task.checkCancellation()
                    current = try await companion.voicePreviewStatus(current.id); job = current
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
