import SwiftUI

struct ReaderNarrationPresentation: Identifiable {
    var id = UUID()
    var snapshot: ReaderScopeSnapshot?
    var jobID: String?
}

enum ReaderNarrator {
    static func kyon(voices: [RemoteVoice], engines: [RemoteEngine]) throws -> RemoteVoice {
        guard engines.contains(where: { $0.id == "voicestudio" && $0.available }) else {
            throw BookError.message("OmniVoice is unavailable. Start VoiceStudio on your PC and check its external engine connection in Studio.")
        }
        let matches = voices.filter { $0.engine == "voicestudio" && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Kyon") == .orderedSame }
        guard matches.count == 1, let voice = matches.first else {
            throw BookError.message(matches.isEmpty ? "Kyon is not available from your paired PC. Add the Kyon voice in VoiceStudio, then refresh." : "More than one Kyon voice is available. Give the intended voice a unique Kyon name in VoiceStudio, then refresh.")
        }
        return voice
    }
}

struct ReaderNarrationView: View {
    let presentation: ReaderNarrationPresentation
    let reader: ReaderModel
    @Environment(CompanionStore.self) private var companion
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var remote: RemoteBook?
    @State private var selection: ReaderSourceSelection?
    @State private var voice: RemoteVoice?
    @State private var jobID: String?
    @State private var preparing = false
    @State private var working = false
    @State private var error: String?
    @State private var showPairing = false
    @State private var playWhenReady = true
    @State private var startedHere = false
    @State private var pollingRevision = 0
    private var job: RemoteJob? { companion.jobs.first { $0.id == (jobID ?? presentation.jobID) } }
    private var preview: String {
        if let selection { return selection.text }
        if let job, let book = companion.books.first(where: { $0.id == job.bookId }) {
            return (job.sourceRanges ?? []).compactMap { span in
                guard let text = book.segments.first(where: { $0.id == span.segmentId })?.text, let range = SourceIdentity.scalarRange(span.startOffset, span.endOffset, in: text) else { return nil }
                return String(text[range])
            }.joined(separator: "\n\n")
        }
        guard let snapshot = presentation.snapshot else { return "" }
        if snapshot.scope == .chapter { return "The chapter boundaries are captured. Connect your PC to verify the original source and preview the exact text." }
        return snapshot.documents[snapshot.hrefs[snapshot.current.resource]]?.blocks.flatMap { block in
            block.visible.compactMap { span -> String? in
                guard let range = SourceIdentity.scalarRange(span.start, span.end, in: block.text) else { return nil }
                return String(block.text[range])
            }
        }.joined(separator: "\n\n") ?? ""
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Label("PC NARRATION", systemImage: "waveform").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(Obsidian.accent)
                    Text(selection?.title ?? presentation.snapshot?.scope.title ?? "Your narration").font(.system(.largeTitle, design: .serif))
                    Text("Kyon · OmniVoice").font(.headline)
                    Text("One narrator, using the original words. Your PC generates the audio; the download stays available offline.").font(.subheadline).foregroundStyle(.secondary)
                    if preparing { ProgressView("Verifying original source…") }
                    if let job { production(job) }
                    else if !companion.paired {
                        Button("Pair your PC", systemImage: "qrcode.viewfinder") { showPairing = true }.buttonStyle(.borderedProminent).foregroundStyle(Obsidian.onAccent)
                    } else {
                        Toggle("Play when ready", isOn: $playWhenReady)
                        Button(working ? "Submitting…" : "Generate with Kyon", systemImage: "waveform.badge.plus") { Task { await generate() } }
                            .buttonStyle(.borderedProminent).foregroundStyle(Obsidian.onAccent)
                            .disabled(working || preparing || selection == nil || voice == nil)
                            .accessibilityIdentifier("reader.generation.submit")
                    }
                    if let error { Text(error).foregroundStyle(.red); Button("Refresh connection") { Task { await prepare() } }.disabled(preparing || working) }
                    if !preview.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Text to narrate").font(.headline)
                            Text(preview).font(.system(.body, design: .serif)).textSelection(.enabled).accessibilityIdentifier("reader.generation.preview")
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Obsidian.surface, in: .rect(cornerRadius: 18))
                    }
                    Text("The selection was captured before this panel opened. Close it and capture again after turning a page or changing text size.").font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }.background(Obsidian.background)
                .navigationTitle("Narrate").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .sheet(isPresented: $showPairing) { PairingView() }
                .task(id: companion.paired) { await prepare() }
                .task(id: (job?.id ?? "") + ":\(pollingRevision)") {
                    guard let id = job?.id else { return }
                    while !Task.isCancelled {
                        do { _ = try await companion.refreshJob(id) } catch { self.error = error.localizedDescription }
                        if job?.status == "completed" { if startedHere && playWhenReady { await downloadAndPlay() }; return }
                        if ["failed", "cancelled"].contains(job?.status ?? "") { return }
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    }
                }
        }.tint(Obsidian.accent)
    }
    @ViewBuilder private func production(_ job: RemoteJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(job.status.capitalized).font(.title3.bold()).accessibilityIdentifier("reader.generation.status")
            ProgressView(value: Double(job.completedSegments), total: Double(max(1, job.totalSegments)))
            Text("\(job.completedSegments) of \(job.totalSegments) passages").font(.caption).foregroundStyle(.secondary)
            if let message = job.error { Text(message).foregroundStyle(.red) }
            if ["queued", "running", "paused"].contains(job.status) {
                HStack {
                    Button(job.status == "paused" ? "Resume" : "Pause") { Task { await act(job, job.status == "paused" ? "resume" : "pause") } }
                    Button("Cancel generation", role: .destructive) { Task { await act(job, "cancel") } }
                }
                Text("You can close this panel. Your PC keeps the job; reopen Recent narration in the reader to check it.").font(.caption).foregroundStyle(.secondary)
            }
            if ["failed", "cancelled"].contains(job.status) {
                Button("Retry generation") { Task { await act(job, "retry") } }
            }
            if job.status == "completed" {
                Button(working ? "Downloading…" : "Download & play in reader", systemImage: "play.circle.fill") { Task { await downloadAndPlay() } }
                    .buttonStyle(.borderedProminent).foregroundStyle(Obsidian.onAccent).disabled(working)
                Text("\(companion.orderedDownloads(jobID: job.id).count) of \(job.assets.count) audio passages on this device").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).background(Obsidian.surface, in: .rect(cornerRadius: 18))
    }
    private func act(_ job: RemoteJob, _ action: String) async {
        if await companion.jobAction(job, action) {
            error = nil
            if action == "retry" { startedHere = true; pollingRevision += 1 }
        } else { error = companion.error ?? "Reconnect to your PC and try again." }
    }
    private func prepare() async {
        guard !preparing, companion.paired else { return }
        preparing = true; error = nil; defer { preparing = false }
        if let id = presentation.jobID { jobID = id; return }
        do {
            try await companion.requireSourceRanges()
            await companion.refresh(reportErrors: false)
            voice = try ReaderNarrator.kyon(voices: companion.voices, engines: companion.engines)
            guard let local = reader.book, let snapshot = presentation.snapshot else { throw BookError.message("Reopen this book and capture its page again.") }
            let book = try await companion.upload(local, library: library)
            let selected = try ReaderSourceMapper.resolve(snapshot, book: book)
            remote = book; selection = selected
        } catch { self.error = error.localizedDescription }
    }
    private func generate() async {
        guard let remote, let selection, let voice, !working else { return }
        working = true; error = nil; defer { working = false }
        do {
            let result = try await companion.generate(book: remote, segments: selection.ranges.map(\.segmentId), voice: voice, rules: companion.importedPronunciations, announce: false, sourceRanges: selection.ranges)
            startedHere = true; jobID = result.id
        } catch { self.error = error.localizedDescription }
    }
    private func downloadAndPlay() async {
        guard let job, let local = reader.book, !working else { return }
        working = true; error = nil; defer { working = false }
        await companion.download(job, localBook: local)
        let sequence = companion.orderedDownloads(jobID: job.id)
        guard sequence.count == job.assets.count, !sequence.isEmpty, let record = sequence.first else { error = companion.error ?? "Some audio is still missing. Reconnect your PC and retry the download."; return }
        companion.play(record, library: library, player: player)
        guard player.isPlaying else { error = player.error ?? companion.error ?? "The downloaded narration could not start."; return }
        reader.connectPlayback(player); dismiss()
    }
}
