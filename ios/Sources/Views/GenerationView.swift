import SwiftUI

struct GenerationView: View {
    @Environment(CompanionStore.self) private var companion
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var localID = ""
    @State private var remote: RemoteBook?
    @State private var voiceID = ""
    @State private var chapterID = "all"
    @State private var selectedSegments: Set<String> = []
    @State private var customSelection = false
    @State private var cast: [String: String] = [:]
    @State private var announce = true
    @State private var rules: [PronunciationRule] = []
    @State private var term = ""
    @State private var replacement = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showCast = false
    @State private var useCast = false
    @State private var uncertainAsNarrator = false
    @State private var newTake = false
    @State private var takeID: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Book") {
                    Picker("From your library", selection: $localID) { Text("Choose book").tag(""); ForEach(library.books) { Text($0.title).tag($0.id) } }.disabled(busy)
                    if remote == nil { Button(busy ? "Uploading…" : "Send book to companion") { upload() }.disabled(localID.isEmpty || busy) }
                    Text("Generation takes place on your PC. Your original text stays unchanged.").font(.caption).foregroundStyle(.secondary)
                }
                if let remote {
                    Section("Narration") {
                        Picker("Narrator", selection: $voiceID) { Text("Choose voice").tag(""); ForEach(companion.voices.filter { voice in companion.engines.contains { $0.id == voice.engine && $0.available } }) { Text($0.name).tag($0.id) } }
                        Picker("Generate", selection: $chapterID) { Text("Entire book").tag("all"); ForEach(remote.chapters) { Text($0.title).tag($0.id) } }
                        Toggle("Select individual passages", isOn: $customSelection)
                        Toggle("Announce chapter titles", isOn: $announce)
                        Toggle("Render a new take", isOn: $newTake)
                        if newTake { Text("Render these passages again. Some engines produce the same performance with unchanged settings.").font(.caption).foregroundStyle(.secondary) }
                        Toggle("Use full cast", isOn: $useCast)
                        if useCast {
                            Text("A narrator voice assigned in Cast Studio also reads the unassigned words.").font(.caption).foregroundStyle(.secondary)
                            Button("Review characters & dialogue") { showCast = true }
                            Toggle("Use narrator for unreviewed lines", isOn: $uncertainAsNarrator)
                        }
                    }
                    if customSelection {
                        Section {
                            ForEach(availableSegments(remote)) { segment in
                                VStack(alignment: .leading, spacing: 10) {
                                    Toggle(isOn: Binding(get: { selectedSegments.contains(segment.id) }, set: { if $0 { selectedSegments.insert(segment.id) } else { selectedSegments.remove(segment.id) } })) { Text(segment.text).lineLimit(4) }
                                    Picker("Voice", selection: Binding(get: { cast[segment.id] ?? "" }, set: { cast[segment.id] = $0.isEmpty ? nil : $0 })) {
                                        Text("Narrator").tag("")
                                        ForEach(companion.voices.filter { $0.engine == companion.voices.first(where: { $0.id == voiceID })?.engine }) { Text($0.name).tag($0.id) }
                                    }.font(.caption)
                                }.padding(.vertical, 6)
                            }
                        } header: { Text("Passages & cast") } footer: { Text("Assign a different voice to any passage. Only selected passages are generated.") }
                    }
                    Section("Pronunciation") {
                        ForEach(rules) { rule in HStack { Text(rule.term); Image(systemName: "arrow.right"); Text(rule.replacement) } }.onDelete { rules.remove(atOffsets: $0) }
                        TextField("Written word or name", text: $term)
                        TextField("Speak as", text: $replacement)
                        Button("Add pronunciation") { rules.removeAll { $0.term == term }; rules.append(.init(term: term, replacement: replacement)); term = ""; replacement = "" }.disabled(term.isEmpty || replacement.isEmpty)
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                    Button(busy ? "Submitting…" : "Generate narration", systemImage: "waveform") { generate(remote) }.disabled(busy || voiceID.isEmpty || (customSelection && selectedSegments.isEmpty))
                }
            }.navigationTitle("Create narration").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onChange(of: localID) { remote = nil; selectedSegments = []; cast = [:]; chapterID = "all" }
            .sheet(isPresented: $showCast) { if let remote { CastView(book: remote) } }
            .task { if rules.isEmpty { rules = companion.importedPronunciations } }
            .onChange(of: newTake) { takeID = newTake ? UUID().uuidString.lowercased() : nil }
        }
    }
    private func availableSegments(_ book: RemoteBook) -> [RemoteSegment] { chapterID == "all" ? book.segments : book.chapters.first { $0.id == chapterID }?.segments ?? [] }
    private func upload() {
        guard let book = library.book(localID) else { return }; busy = true; error = nil
        Task { do { remote = try await companion.upload(book, library: library) } catch { self.error = error.localizedDescription }; busy = false }
    }
    private func generate(_ book: RemoteBook) {
        guard let voice = companion.voices.first(where: { $0.id == voiceID }) else { return }
        let ids = availableSegments(book).map(\.id).filter { !customSelection || selectedSegments.contains($0) }
        guard !ids.isEmpty else { error = "Select at least one passage."; return }
        busy = true; error = nil
        Task {
            do {
                var plan: [NarrationSpan] = []
                var narrator = voice
                if useCast {
                    let approved = try await companion.fetchCast(book.id)
                    if let narratorID = approved.characters.first(where: { $0.id == "narrator" })?.voiceId {
                        guard let assigned = companion.voices.first(where: { $0.id == narratorID }) else { throw BookError.message("The cast narrator voice is unavailable. Choose a replacement in Cast Studio.") }
                        narrator = assigned
                    }
                    let assignments = approved.assignments.filter { ids.contains($0.segmentId) }
                    guard uncertainAsNarrator || !assignments.contains(where: { !$0.reviewed }) else { throw BookError.message("Review suggested speakers, or explicitly choose narrator fallback for unreviewed lines.") }
                    for assignment in assignments where assignment.reviewed {
                        let assignedVoice = approved.characters.first { $0.id == assignment.characterId }?.voiceId ?? narrator.id
                        guard companion.voices.contains(where: { $0.id == assignedVoice && $0.engine == narrator.engine }) else { throw BookError.message("Every cast voice must use the narrator's engine for this production.") }
                        plan.append(NarrationSpan(segmentId: assignment.segmentId, startOffset: assignment.startOffset, endOffset: assignment.endOffset, voiceId: assignedVoice))
                    }
                }
                let selectedCast = cast.filter { ids.contains($0.key) }
                try await companion.generate(book: book, segments: ids, voice: narrator, rules: rules, announce: announce, cast: selectedCast.isEmpty ? nil : selectedCast, narrationPlan: plan.isEmpty ? nil : plan, takeID: takeID, narrationMode: useCast || !selectedCast.isEmpty ? "full_cast" : "single")
                dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
