import SwiftUI
import UIKit

struct CastView: View {
    let book: RemoteBook
    var relevantRanges: [SourceRange]? = nil
    @Environment(CompanionStore.self) private var companion
    var body: some View { CastDraftView(book: book, relevantRanges: relevantRanges, draft: companion.castDraft(for: book.id)) }
}

private struct CastDraftView: View {
    let book: RemoteBook
    let relevantRanges: [SourceRange]?
    @Bindable var draft: CastDraft
    @Environment(CompanionStore.self) private var companion
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var allowHosted = false
    @State private var showingAssignment = false
    @State private var action: Task<Void, Never>?
    @State private var chapterID = ""
    @State private var chapterStatuses: [ChapterAnalysisStatus] = []
    @State private var creatingCharacter: CastCharacter?
    @State private var auditionVoice: RemoteVoice?
    private var relevantCharacters: Set<String>? {
        relevantRanges.map { ranges in Set(draft.value.assignments.filter { row in ranges.contains { $0.segmentId == row.segmentId && $0.startOffset < row.endOffset && row.startOffset < $0.endOffset } }.map(\.characterId) + ["narrator"]) }
    }
    private var service: CastService {
        CastService(fetch: { try await companion.fetchCast(book.id) },
                    save: { try await companion.saveCast($0, bookID: book.id) },
                    analyze: { try await companion.analyze(book.id, request: $0) },
                    poll: { try await companion.analysis($0) },
                    requireReliableAnalysis: { try await companion.requireReliableAnalysis() })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Build a cast for every conversation. Voices stay attached to the original words.").foregroundStyle(.secondary)
                    Toggle("Allow configured hosted analysis", isOn: $allowHosted)
                    Text(allowHosted ? "Analysis will send book text to the hosted API configured on your PC." : "Analysis uses your PC's local model. Hosted APIs are blocked.").font(.caption).foregroundStyle(.secondary)
                    Picker("Chapter", selection: $chapterID) { ForEach(book.chapters) { Text($0.title).tag($0.id) } }.accessibilityIdentifier("cast.chapter")
                    if let status = chapterStatuses.first(where: { $0.chapterId == chapterID }) { Text(status.status.replacingOccurrences(of: "_", with: " ").capitalized).accessibilityIdentifier("cast.chapter.status"); if let error = status.error { Text(error).foregroundStyle(.red) } }
                    Button("Analyze chapter", systemImage: "person.2.wave.2") { startAnalysis(chapters: [chapterID]) }.disabled(draft.busy || chapterID.isEmpty).accessibilityIdentifier("cast.analyze.chapter")
                    Button("Reanalyze chapter") { startAnalysis(chapters: [chapterID], force: true) }.disabled(draft.busy || chapterID.isEmpty).accessibilityIdentifier("cast.reanalyze.chapter")
                    Button("Analyze entire book") { startAnalysis(chapters: book.chapters.map(\.id)) }.disabled(draft.busy).accessibilityIdentifier("cast.analyze.book")
                    if draft.loading { ProgressView("Loading saved cast…") }
                    if let analysis = draft.analysis {
                        if draft.mergingResults { ProgressView("Loading suggestions…") }
                        else { Text("\(analysis.status.capitalized) · \(analysis.completedSegments)/\(analysis.totalSegments) passages").font(.caption) }
                        if let message = analysis.error { Text(message).foregroundStyle(.red) }
                        ForEach(Array((analysis.warnings ?? []).enumerated()), id: \.offset) { _, warning in
                            Label(warning, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Characters") {
                    if !draft.value.characters.contains(where: { $0.id == "narrator" }) {
                        Button("Add narrator", systemImage: "person.wave.2") { draft.value.characters.append(.init(id: "narrator", name: "Narrator", aliases: [], voiceId: nil)) }
                    }
                    ForEach($draft.value.characters) { $character in
                        if relevantCharacters == nil || relevantCharacters!.contains(character.id) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Character name", text: $character.name)
                            TextField("Aliases, separated by commas", text: Binding(get: { character.aliases.joined(separator: ", ") }, set: { character.aliases = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
                                .font(.caption).foregroundStyle(.secondary)
                            Picker("Voice", selection: Binding(get: { character.voiceId ?? "" }, set: { character.voiceId = $0.isEmpty ? nil : $0 })) {
                                Text("Choose voice").tag("")
                                ForEach(companion.voices.filter { voice in character.id == "narrator" || draft.value.characters.first(where: { $0.id == "narrator" })?.voiceId.flatMap { id in companion.voices.first { $0.id == id } }?.engine == voice.engine }) { Text($0.name).tag($0.id) }
                            }
                            HStack {
                                Button("Create voice", systemImage: "plus") { creatingCharacter = character }.buttonStyle(.borderless).accessibilityIdentifier("cast.voice.create." + character.id)
                                if character.id != "narrator", let narrator = draft.value.characters.first(where: { $0.id == "narrator" })?.voiceId {
                                    Button("Use narrator") { character.voiceId = narrator }.buttonStyle(.borderless).accessibilityIdentifier("cast.voice.narrator." + character.id)
                                }
                                if let voice = companion.voices.first(where: { $0.id == character.voiceId }) { Button("Audition") { auditionVoice = voice }.buttonStyle(.borderless).accessibilityIdentifier("cast.voice.audition." + character.id) }
                            }.frame(minHeight: 44)
                        }.deleteDisabled(relevantRanges != nil)
                        }
                    }.onDelete { offsets in
                        guard relevantRanges == nil else { return }
                        let removed = Set(offsets.map { draft.value.characters[$0].id })
                        draft.value.characters.remove(atOffsets: offsets)
                        draft.value.assignments.removeAll { removed.contains($0.characterId) }
                    }
                    HStack { TextField("New character", text: $name); Button("Add") { draft.value.characters.append(CastCharacter(id: UUID().uuidString, name: name, aliases: [], voiceId: nil)); name = "" }.disabled(name.isEmpty) }
                }
                Section {
                    ForEach($draft.value.assignments) { $assignment in
                        if relevantRanges == nil || relevantRanges!.contains(where: { $0.segmentId == assignment.segmentId && $0.startOffset < assignment.endOffset && assignment.startOffset < $0.endOffset }) {
                        VStack(alignment: .leading, spacing: 10) {
                            if let text = excerpt(assignment) { Text(text).font(.system(.body, design: .serif)).lineLimit(5) }
                            Picker("Speaker", selection: $assignment.characterId) { ForEach(draft.value.characters) { Text($0.name).tag($0.id) } }
                            if !assignment.reviewed { Label(assignment.confidence < 0.8 ? "Uncertain speaker — review required" : "Suggested speaker", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary) }
                            Toggle("Reviewed", isOn: $assignment.reviewed)
                            if relevantRanges != nil {
                                Button("Delete assignment", role: .destructive) { let id = assignment.id; draft.value.assignments.removeAll { $0.id == id } }.buttonStyle(.borderless)
                            }
                        }.padding(.vertical, 6).deleteDisabled(relevantRanges != nil)
                        }
                    }.onDelete { if relevantRanges == nil { draft.value.assignments.remove(atOffsets: $0) } }
                    Button("Assign selected words", systemImage: "text.cursor") { showingAssignment = true }.disabled(draft.value.characters.isEmpty)
                } header: { Text("Dialogue & narration") } footer: { Text("Delete an incorrect range and select its exact replacement. Unassigned words use the narrator.") }
                if let error = draft.error { Text(error).foregroundStyle(.red) }
                if draft.canResumeAnalysis {
                    Button(draft.analysis == nil ? "Recover analysis request" : "Refresh analysis results", systemImage: "arrow.clockwise") {
                        action = Task { await draft.load(book: book, service: service) }
                    }
                }
                if let request = draft.pendingAnalysisRequest, draft.analysis == nil {
                    Text(request.allowHosted ? "This pending request keeps your original hosted-analysis consent. Recovery uses the same request and does not upload your newer cast edits." : "This pending request remains local-only. Recovery uses the same request and does not upload your newer cast edits.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draft.dirty { Text("Unsaved edits are kept while this app stays open.").font(.caption).foregroundStyle(.secondary) }
                Button("Save cast") { save() }.disabled(draft.busy)
            }
            .navigationTitle("Cast studio").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save & close") { save(close: true) }.disabled(draft.busy) } }
            .task {
                if chapterID.isEmpty { chapterID = book.chapters.first(where: { chapter in relevantRanges?.contains { range in chapter.segments.contains { $0.id == range.segmentId } } == true })?.id ?? book.chapters.first?.id ?? "" }
                await draft.load(book: book, service: service)
                do { chapterStatuses = try await companion.chapterAnalysisStatus(book.id) } catch { draft.error = error.localizedDescription }
            }
            .onDisappear {
                guard !showingAssignment, creatingCharacter == nil, auditionVoice == nil else { return }
                if !draft.awaitingAnalysisConfirmation { action?.cancel() }
                draft.cancel()
            }
            .sheet(isPresented: $showingAssignment) { SpanAssignmentView(book: book, characters: draft.value.characters) { assignment in
                let overlaps = draft.value.assignments.contains { CastMerge.overlaps($0, assignment) }
                if overlaps { draft.error = "Those words already have a speaker. Delete the overlapping assignment first." }
                else { draft.value.assignments.append(assignment) }
            } }
            .sheet(item: $creatingCharacter) { character in
                VoiceCreationView(initialName: character.name, initialEngine: draft.value.characters.first(where: { $0.id == "narrator" })?.voiceId.flatMap { id in companion.voices.first { $0.id == id } }?.engine ?? "omnivoice") { voice in
                    if let index = draft.value.characters.firstIndex(where: { $0.id == character.id }) { draft.value.characters[index].voiceId = voice.id }
                }
            }
            .sheet(item: $auditionVoice) { VoiceAuditionView(voice: $0) }
        }
    }
    private func excerpt(_ assignment: CastAssignment) -> String? {
        guard let segment = book.segments.first(where: { $0.id == assignment.segmentId }), let range = SourceIdentity.scalarRange(assignment.startOffset, assignment.endOffset, in: segment.text) else { return nil }
        return String(segment.text[range])
    }
    private func save(close: Bool = false) {
        action = Task {
            let saved = await draft.save(service: service)
            if close && saved && !Task.isCancelled { dismiss() }
        }
    }
    private func startAnalysis(chapters: [String], force: Bool = false) {
        action = Task {
            await draft.analyze(book: book, hosted: allowHosted, service: service, chapterIDs: chapters, force: force)
            do { chapterStatuses = try await companion.chapterAnalysisStatus(book.id) } catch { draft.error = error.localizedDescription }
        }
    }
}

struct SpanAssignmentView: View {
    let book: RemoteBook
    let characters: [CastCharacter]
    let onSave: (CastAssignment) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var segmentID = ""
    @State private var characterID = ""
    @State private var start = 0
    @State private var end = 0
    var body: some View {
        NavigationStack {
            Form {
                Picker("Passage", selection: $segmentID) { Text("Choose passage").tag(""); ForEach(book.segments) { Text(String($0.text.prefix(80))).tag($0.id) } }
                if let segment = book.segments.first(where: { $0.id == segmentID }) {
                    Text("Select the exact words spoken by this character.").font(.caption).foregroundStyle(.secondary)
                    SourceSelectionView(text: segment.text) { a, b in start = a; end = b }.frame(minHeight: 200)
                    if let range = SourceIdentity.scalarRange(start, end, in: segment.text), start < end { Text("Selected: \(String(segment.text[range]))").font(.caption) }
                }
                Picker("Speaker", selection: $characterID) { Text("Choose character").tag(""); ForEach(characters) { Text($0.name).tag($0.id) } }
                Button("Assign voice to selection") {
                    onSave(CastAssignment(id: UUID().uuidString, segmentId: segmentID, startOffset: start, endOffset: end, characterId: characterID, confidence: 1, reviewed: true)); dismiss()
                }.disabled(start >= end || characterID.isEmpty || segmentID.isEmpty)
            }.navigationTitle("Assign words").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: segmentID) { start = 0; end = 0 }
        }
    }
}

struct SourceSelectionView: UIViewRepresentable {
    let text: String
    let onSelection: (Int, Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.isEditable = false; view.isSelectable = true; view.font = .preferredFont(forTextStyle: .body); view.adjustsFontForContentSizeCategory = true; view.backgroundColor = .clear; view.delegate = context.coordinator; return view
    }
    func updateUIView(_ view: UITextView, context: Context) { if view.text != text { view.text = text } }
    final class Coordinator: NSObject, UITextViewDelegate {
        let onSelection: (Int, Int) -> Void
        init(onSelection: @escaping (Int, Int) -> Void) { self.onSelection = onSelection }
        func textViewDidChangeSelection(_ view: UITextView) {
            guard let text = view.text, let range = Range(view.selectedRange, in: text) else { return }
            let a = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.lowerBound)
            let b = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.upperBound)
            let callback = onSelection
            DispatchQueue.main.async { callback(a, b) }
        }
    }
}
