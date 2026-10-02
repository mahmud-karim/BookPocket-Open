import SwiftUI
import UIKit

struct CastView: View {
    let book: RemoteBook
    @Environment(CompanionStore.self) private var companion
    @Environment(\.dismiss) private var dismiss
    @State private var cast = BookCast()
    @State private var name = ""
    @State private var adding = false
    @State private var dirty = false
    @State private var busy = false
    @State private var allowHosted = false
    @State private var analysis: AnalysisJob?
    @State private var error: String?
    @State private var showingAssignment = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Build a cast for every conversation. Voices stay attached to the original words.").foregroundStyle(.secondary)
                    Toggle("Allow configured hosted analysis", isOn: $allowHosted)
                    Text(allowHosted ? "Analysis will send book text to the hosted API configured on your PC." : "Analysis uses your PC's local model. Hosted APIs are blocked.").font(.caption).foregroundStyle(.secondary)
                    Button("Analyze speakers", systemImage: "person.2.wave.2") { startAnalysis() }.disabled(busy || dirty)
                    if let analysis {
                        Text("\(analysis.status.capitalized) · \(analysis.completedSegments)/\(analysis.totalSegments) passages").font(.caption)
                        if let message = analysis.error { Text(message).foregroundStyle(.red) }
                    }
                }
                Section("Characters") {
                    ForEach($cast.characters) { $character in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Character name", text: $character.name)
                            TextField("Aliases, separated by commas", text: Binding(get: { character.aliases.joined(separator: ", ") }, set: { character.aliases = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
                                .font(.caption).foregroundStyle(.secondary)
                            Picker("Voice", selection: Binding(get: { character.voiceId ?? "" }, set: { character.voiceId = $0.isEmpty ? nil : $0 })) {
                                Text("Use narrator").tag("")
                                ForEach(companion.voices) { Text($0.name).tag($0.id) }
                            }
                        }
                    }
                    HStack { TextField("New character", text: $name); Button("Add") { cast.characters.append(CastCharacter(id: UUID().uuidString, name: name, aliases: [], voiceId: nil)); name = ""; dirty = true }.disabled(name.isEmpty) }
                }
                Section {
                    ForEach($cast.assignments) { $assignment in
                        VStack(alignment: .leading, spacing: 10) {
                            if let text = excerpt(assignment) { Text(text).font(.system(.body, design: .serif)).lineLimit(5) }
                            Picker("Speaker", selection: $assignment.characterId) { ForEach(cast.characters) { Text($0.name).tag($0.id) } }
                            if !assignment.reviewed { Label(assignment.confidence < 0.8 ? "Uncertain speaker — review required" : "Suggested speaker", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary) }
                            Toggle("Reviewed", isOn: $assignment.reviewed)
                        }.padding(.vertical, 6)
                    }.onDelete { cast.assignments.remove(atOffsets: $0); dirty = true }
                    Button("Assign selected words", systemImage: "text.cursor") { showingAssignment = true }.disabled(cast.characters.isEmpty)
                } header: { Text("Dialogue & narration") } footer: { Text("Delete an incorrect range and select its exact replacement. Unassigned words use the narrator.") }
                if let error { Text(error).foregroundStyle(.red) }
                Button(busy ? "Saving…" : "Save cast") { save() }.disabled(busy)
            }
            .navigationTitle("Cast studio").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { do { cast = try await companion.fetchCast(book.id) } catch { self.error = error.localizedDescription } }
            .sheet(isPresented: $showingAssignment) { SpanAssignmentView(book: book, characters: cast.characters) { assignment in
                let overlaps = cast.assignments.contains { $0.segmentId == assignment.segmentId && $0.startOffset < assignment.endOffset && assignment.startOffset < $0.endOffset }
                if overlaps { error = "Those words already have a speaker. Delete the overlapping assignment first." }
                else { cast.assignments.append(assignment); dirty = true }
            } }
        }
    }
    private func excerpt(_ assignment: CastAssignment) -> String? {
        guard let segment = book.segments.first(where: { $0.id == assignment.segmentId }), let range = SourceIdentity.scalarRange(assignment.startOffset, assignment.endOffset, in: segment.text) else { return nil }
        return String(segment.text[range])
    }
    private func save() { busy = true; Task { do { try await companion.saveCast(cast, bookID: book.id); dirty = false } catch { self.error = error.localizedDescription }; busy = false } }
    private func startAnalysis() {
        busy = true; error = nil
        Task {
            do {
                analysis = try await companion.analyze(book.id, allowHosted: allowHosted)
                while let current = analysis, ["queued", "running"].contains(current.status) {
                    try await Task.sleep(for: .seconds(3)); analysis = try await companion.analysis(current.id)
                }
                cast = try await companion.fetchCast(book.id)
            } catch { self.error = error.localizedDescription }
            busy = false
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
            onSelection(a, b)
        }
    }
}
