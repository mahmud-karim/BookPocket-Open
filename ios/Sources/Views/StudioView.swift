import SwiftUI
import UniformTypeIdentifiers

struct StudioView: View {
    @Environment(CompanionStore.self) private var companion
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackController.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPairing = false
    @State private var showVoice = false
    @State private var showGenerate = false
    @State private var revoke = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(companion.paired ? "YOUR COMPANION" : "PERSONAL AUDIO STUDIO", systemImage: "waveform").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(Obsidian.accent)
                        Text(companion.paired ? "Give your stories\na voice." : "Your books.\nYour voices.").font(.system(.largeTitle, design: .serif))
                        Text(companion.paired ? (companion.status ?? "Your PC generates. Your library stays with you.") : "Connect your PC to create natural narration, build a cast, and take complete audiobooks with you.").foregroundStyle(.secondary)
                        Button(companion.paired ? "Create narration" : "Pair a companion", systemImage: companion.paired ? "waveform.badge.plus" : "qrcode.viewfinder") { if companion.paired { showGenerate = true } else { showPairing = true } }.buttonStyle(.borderedProminent).accessibilityIdentifier("studio.primary")
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(Obsidian.surface, in: .rect(cornerRadius: 22))
                    if companion.paired {
                        HStack { Text("Voice collection").font(.title2.bold()); Spacer(); Button("Add voice", systemImage: "plus") { showVoice = true }.labelStyle(.iconOnly) }
                        if companion.voices.isEmpty { Text("Install a voice engine in your PC Studio, then refresh here.").foregroundStyle(.secondary) }
                        ForEach(companion.voices) { voice in
                            HStack(spacing: 14) {
                                Image(systemName: voice.kind == "clone" ? "person.wave.2" : "waveform").frame(width: 44, height: 44).background(Obsidian.accent.opacity(0.10), in: .circle).foregroundStyle(Obsidian.accent)
                                VStack(alignment: .leading) { Text(voice.name).font(.headline); Text("\(voice.kind.capitalized) · \(voice.language.uppercased())").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                            }.padding(16).background(Obsidian.surface, in: .rect(cornerRadius: 16))
                        }
                        if !companion.pendingRequests.isEmpty {
                            Text("Awaiting confirmation").font(.title2.bold())
                            ForEach(companion.pendingRequests, id: \.requestId) { request in
                                Button("Retry submission · \(request.segmentIds.count) passages") { Task { do { try await companion.submit(request) } catch { companion.error = error.localizedDescription } } }
                            }
                            Text("Retries keep the same request ID, preventing duplicate generation.").font(.caption).foregroundStyle(.secondary)
                        }
                        if !companion.jobs.isEmpty {
                            Text("Production queue").font(.title2.bold())
                            ForEach(companion.jobs) { job in jobCard(job) }
                        }
                        DisclosureGroup("Available engines") {
                            ForEach(companion.engines) { engine in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack { Text(engine.name).font(.headline); Spacer(); Text(engine.available ? "Ready" : "Unavailable").font(.caption).foregroundStyle(engine.available ? .green : .secondary) }
                                    Text(engine.license).font(.caption).foregroundStyle(.secondary)
                                    if let reason = engine.reason, !engine.available { Text(reason).font(.caption).foregroundStyle(.secondary) }
                                }.padding(.vertical, 8)
                            }
                        }
                    }
                    if !companion.downloads.isEmpty {
                        Text("On this device").font(.title2.bold())
                        ForEach(Array(Set(companion.downloads.map(\.jobID))).sorted(), id: \.self) { id in
                            if let first = companion.orderedDownloads(jobID: id).first, let book = library.book(first.localBookID) {
                                Button { companion.play(first, library: library, player: player) } label: { Label("\(book.title) · \(companion.orderedDownloads(jobID: id).count) passages", systemImage: "play.circle.fill") }.padding(.vertical, 8)
                            }
                        }
                    }
                }.padding(24)
            }.background(Obsidian.background).navigationTitle("Studio")
            .toolbar {
                if companion.paired {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await companion.refresh() } }.disabled(companion.refreshing)
                        Menu { Button("Revoke this device", role: .destructive) { revoke = true } } label: { Label("Companion settings", systemImage: "ellipsis.circle") }
                    }
                }
            }
            .refreshable { await companion.refresh() }
            .sheet(isPresented: $showPairing) { PairingView() }
            .sheet(isPresented: $showVoice) { VoiceCreationView() }
            .sheet(isPresented: $showGenerate) { GenerationView() }
            .confirmationDialog("Revoke this device's companion access? Downloaded audio will remain available.", isPresented: $revoke, titleVisibility: .visible) { Button("Revoke device", role: .destructive) { Task { await companion.disconnect() } } }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await companion.refresh()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    if companion.jobs.contains(where: { ["queued", "running"].contains($0.status) }) { await companion.refresh() }
                }
            }
            .alert("Companion", isPresented: Binding(get: { companion.error != nil }, set: { if !$0 { companion.error = nil } })) { Button("OK") { companion.error = nil } } message: { Text(companion.error ?? "") }
        }
    }
    private func jobCard(_ job: RemoteJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(companion.books.first { $0.id == job.bookId }?.title ?? "Narration").font(.headline); Spacer(); Text(job.status.capitalized).font(.caption).foregroundStyle(.secondary) }
            ProgressView(value: Double(job.completedSegments), total: Double(max(1, job.totalSegments)))
            Text("\(job.completedSegments) of \(job.totalSegments) passages").font(.caption).foregroundStyle(.secondary)
            if let error = job.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if ["queued", "running"].contains(job.status) { Button("Pause") { Task { await companion.jobAction(job, "pause") } }; Button("Cancel", role: .destructive) { Task { await companion.jobAction(job, "cancel") } } }
                if job.status == "paused" { Button("Resume") { Task { await companion.jobAction(job, "resume") } } }
                if ["failed", "cancelled"].contains(job.status) { Button("Retry") { Task { await companion.jobAction(job, "retry") } } }
                if !job.assets.isEmpty, let local = library.books.first(where: { $0.companionBookID == job.bookId || $0.sourceSHA256 == companion.books.first(where: { $0.id == job.bookId })?.sourceSha256 }) {
                    Button(companion.downloading == job.id ? "Downloading…" : "Download", systemImage: "arrow.down.circle") { Task { await companion.download(job, localBook: local) } }.disabled(companion.downloading != nil)
                }
            }.font(.subheadline)
        }.padding(18).background(Obsidian.surface, in: .rect(cornerRadius: 16))
    }
}

struct PairingView: View {
    @Environment(CompanionStore.self) private var companion
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var fingerprint = ""
    @State private var code = ""
    @State private var scanner = false
    @State private var connectTask: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section { Button("Scan companion QR", systemImage: "qrcode.viewfinder") { scanner = true } } footer: { Text("Open Settings → Pair device in your PC Studio. The QR verifies your companion's HTTPS identity.") }
                Section("Or enter pairing details") {
                    TextField("https://your-pc:8765", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Pairing code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    TextField("Certificate SHA-256", text: $fingerprint, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled().font(.caption.monospaced())
                }
                if let status = companion.status { Text(status).foregroundStyle(.secondary) }
                if let error = companion.error { Text(error).foregroundStyle(.red) }
                Button(companion.pairing ? "Waiting for PC approval…" : "Request pairing") { begin() }.disabled(url.isEmpty || code.isEmpty || companion.pairing)
            }.navigationTitle("Pair companion").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { connectTask?.cancel(); dismiss() } } }
            .sheet(isPresented: $scanner) {
                QRScanner { string in
                    do {
                        let qr = try CompanionClient.decoder.decode(PairingQR.self, from: Data(string.utf8))
                        url = qr.url; code = qr.code; fingerprint = qr.certificateSha256 ?? ""; scanner = false
                    } catch { companion.error = "This QR is not a Book Pocket companion pairing code."; scanner = false }
                }
            }
            .onDisappear { connectTask?.cancel() }
        }
    }
    private func begin() {
        companion.error = nil
        connectTask = Task { await companion.connect(qr: PairingQR(url: url.trimmingCharacters(in: .whitespacesAndNewlines), certificateSha256: fingerprint.trimmingCharacters(in: .whitespacesAndNewlines), code: code.trimmingCharacters(in: .whitespacesAndNewlines))); if companion.paired { dismiss() } }
    }
}

struct VoiceCreationView: View {
    @Environment(CompanionStore.self) private var companion
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var engine = ""
    @State private var language = "en"
    @State private var transcript = ""
    @State private var sample: URL?
    @State private var importing = false
    @State private var creating = false
    @State private var authorized = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Voice profile") {
                    TextField("Voice name", text: $name)
                    Picker("Engine", selection: $engine) { Text("Choose engine").tag(""); ForEach(companion.engines.filter { $0.available && $0.supportsCloning }) { Text($0.name).tag($0.id) } }
                    TextField("Language code", text: $language).textInputAutocapitalization(.never)
                }
                Section {
                    Button(sample?.lastPathComponent ?? "Choose audio sample", systemImage: "waveform") { importing = true }
                    TextField("Exact transcript, if required by the engine", text: $transcript, axis: .vertical).lineLimit(3...8)
                    Toggle("I have permission to use this voice", isOn: $authorized)
                } header: { Text("Reference recording") } footer: { Text("Use a clean recording of one speaker. The reference is sent only to your paired PC and stays private.") }
                if let error { Text(error).foregroundStyle(.red) }
                Button(creating ? "Creating voice…" : "Create voice") {
                    guard let sample else { return }; creating = true
                    Task { do { try await companion.clone(name: name, engine: engine, language: language, transcript: transcript, sample: sample); dismiss() } catch { self.error = error.localizedDescription }; creating = false }
                }.disabled(creating || name.isEmpty || engine.isEmpty || sample == nil || !authorized)
            }.navigationTitle("New voice").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in do { sample = try result.get() } catch { self.error = error.localizedDescription } }
        }
    }
}
