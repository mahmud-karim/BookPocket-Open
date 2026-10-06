import SwiftUI

struct CastReviewView: View {
    let book: RemoteBook
    let relevantRanges: [SourceRange]?
    @Bindable var draft: CastDraft
    @State var inventory: CastReviewInventory
    @State var issue: CastReviewIssue
    @Environment(CompanionStore.self) private var companion
    @Environment(\.dismiss) private var dismiss
    @State private var characterID = ""
    @State private var voiceID = ""
    @State private var name = ""
    @State private var newCharacters: [CastCharacter] = []
    @State private var creatingVoice = false
    @State private var selectedStart = 0
    @State private var selectedEnd = 0
    @State private var remainingNarrator = false
    @State private var initialized = false
    @State private var multipleSpeakers = false
    @State private var additionalRanges: [CastReviewRange] = []
    @State private var error: String?
    private var characters: [CastCharacter] { draft.value.characters + newCharacters }
    private var narratorEngine: String? {
        draft.value.characters.first { $0.id == "narrator" }?.voiceId.flatMap { id in companion.voices.first { $0.id == id }?.engine }
    }
    private var compatibleVoices: [RemoteVoice] {
        companion.voices.filter { voice in (narratorEngine == nil || voice.engine == narratorEngine) && companion.engines.contains { $0.id == voice.engine && $0.available } }
    }
    private var recovering: SavedCastReviewRequest? { companion.castReviewRequests.first { $0.bookId == book.id && $0.issueId == issue.id } }
    private var selectionValid: Bool { selectedStart >= issue.startOffset && selectedEnd <= issue.endOffset && selectedStart < selectedEnd }
    private var selectedRange: CastReviewRange? { selectionValid ? .init(startOffset: selectedStart, endOffset: selectedEnd, characterId: characterID) : nil }
    private var resolvedRanges: [CastReviewRange]? {
        CastReview.resolutionRanges(issue: issue, selected: selectedRange, additional: additionalRanges, narratorRemainder: remainingNarrator && narratorEngine != nil)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Unclear passage") {
                    Text(issue.message).font(.callout).foregroundStyle(.secondary)
                    Text(issue.sourceText).font(.system(.title3, design: .serif)).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Obsidian.accent.opacity(0.15), in: .rect(cornerRadius: 10))
                        .accessibilityIdentifier("cast.review.exact")
                    if let segment = book.segments.first(where: { $0.id == issue.segmentId }),
                       let range = SourceIdentity.scalarRange(issue.startOffset, issue.endOffset, in: segment.text) {
                        (Text(String(segment.text[..<range.lowerBound])) + Text(String(segment.text[range])).bold().foregroundColor(Obsidian.accent) + Text(String(segment.text[range.upperBound...])))
                            .font(.system(.body, design: .serif)).textSelection(.enabled).accessibilityIdentifier("cast.review.context")
                    }
                    Text("These are the original words. Saving assigns their speaker and voice; it does not rewrite the book.").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Select the words this speaker reads") {
                        Text("Touch and hold to adjust the selection. Assign the other words explicitly to the narrator.").font(.caption)
                        SourceSelectionView(text: issue.sourceText, initialSelection: (0, issue.sourceText.unicodeScalars.count)) { start, end in
                            selectedStart = issue.startOffset + start; selectedEnd = issue.startOffset + end
                        }.id(issue.id).frame(minHeight: 180).accessibilityIdentifier("cast.review.selection")
                        Toggle("Use narrator for remaining words", isOn: $remainingNarrator).accessibilityIdentifier("cast.review.remainingNarrator")
                        Toggle("Edit multiple speakers", isOn: $multipleSpeakers).accessibilityIdentifier("cast.review.multipleSpeakers")
                        if multipleSpeakers {
                            Text("Add exact ranges for characters whose voices are already saved in Cast Studio. Each remaining word needs an explicit speaker or narrator choice.").font(.caption)
                            Button("Add this speaker range") {
                                if let selectedRange { additionalRanges.append(selectedRange); selectedStart = 0; selectedEnd = 0 }
                            }.disabled(!selectionValid || !characters.contains { $0.id == characterID && $0.voiceId == voiceID && compatibleVoices.contains { $0.id == voiceID } })
                                .accessibilityIdentifier("cast.review.addRange")
                            ForEach(Array(additionalRanges.enumerated()), id: \.offset) { index, row in
                                HStack {
                                    Text(characters.first { $0.id == row.characterId }?.name ?? row.characterId)
                                    if let range = SourceIdentity.scalarRange(row.startOffset - issue.startOffset, row.endOffset - issue.startOffset, in: issue.sourceText) { Text(String(issue.sourceText[range])).lineLimit(2) }
                                    Button("Remove", role: .destructive) { additionalRanges.remove(at: index) }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }.disabled(draft.busy || recovering != nil)
                }
                Section("Who is speaking?") {
                    Picker("Speaker", selection: $characterID) {
                        Text("Choose speaker").tag("")
                        ForEach(characters) { Text($0.id == "narrator" ? "Narrator" : $0.name).tag($0.id) }
                    }.accessibilityIdentifier("cast.review.speaker")
                    HStack {
                        TextField("New character name", text: $name).accessibilityIdentifier("cast.review.newCharacter")
                        Button("Add") {
                            let character = CastCharacter(id: UUID().uuidString.lowercased(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), aliases: [], voiceId: nil)
                            newCharacters.append(character); characterID = character.id; name = ""
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("cast.review.addCharacter")
                    }
                    Picker("Voice", selection: $voiceID) {
                        Text("Choose voice").tag("")
                        ForEach(compatibleVoices) { Text($0.name).tag($0.id) }
                    }.accessibilityIdentifier("cast.review.voice")
                    Button("Create voice", systemImage: "plus") { creatingVoice = true }.disabled(characterID.isEmpty).accessibilityIdentifier("cast.review.createVoice")
                    if characterID != "narrator", let narrator = draft.value.characters.first(where: { $0.id == "narrator" })?.voiceId {
                        Button("Use narrator voice") { voiceID = narrator }.accessibilityIdentifier("cast.review.useNarrator")
                    }
                }.disabled(draft.busy || recovering != nil)
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("cast.review.error") }
                if recovering != nil { Text("Recovering your earlier save uses the same speaker, voice and request. Your current choices stay here.").font(.caption) }
                Button(draft.busy ? "Saving…" : recovering != nil ? "Recover save" : "Save & next") { Task { await save() } }
                    .disabled(draft.busy || (recovering == nil && (characterID.isEmpty || !compatibleVoices.contains { $0.id == voiceID } || resolvedRanges == nil)))
                    .accessibilityIdentifier("cast.review.save")
            }.navigationTitle("Review dialogue").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("cast.review.cancel") } }
                .onAppear { if !initialized { initialized = true; selectSuggested() } }
                .onChange(of: characterID) { voiceID = characters.first { $0.id == characterID }?.voiceId ?? "" }
                .sheet(isPresented: $creatingVoice) {
                    VoiceCreationView(initialName: characters.first { $0.id == characterID }?.name ?? "", initialEngine: narratorEngine ?? "omnivoice") { voice in voiceID = voice.id }
                }
        }.tint(Obsidian.accent)
    }
    private func selectSuggested() {
        selectedStart = issue.startOffset; selectedEnd = issue.endOffset; remainingNarrator = false; additionalRanges = []; multipleSpeakers = false
        characterID = issue.suggestedCharacterId.flatMap { id in characters.contains { $0.id == id } ? id : nil } ?? ""
        voiceID = characters.first { $0.id == characterID }?.voiceId ?? ""
    }
    private func save() async {
        error = nil
        let request = recovering?.request ?? CastReviewRequest(requestId: UUID().uuidString.lowercased(), expectedRevision: inventory.revision,
            characterId: characterID, voiceId: voiceID, newCharacter: newCharacters.first { $0.id == characterID }, ranges: resolutionRanges())
        guard let response = await draft.resolve(issue: issue, book: book, request: request, operation: { request in
            try await companion.resolveCastReview(issue, book: book, request: request)
        }) else {
            error = draft.error
            // A rejected revision never overwrites the user's choices. A later
            // explicit save uses the refreshed revision; uncertain requests keep
            // their captured UUID until the server confirms their outcome.
            if recovering == nil, let fresh = try? await companion.castReview(book) { inventory = fresh }
            return
        }
        inventory.revision = response.revision
        inventory.issues.removeAll { $0.id == issue.id }; inventory.issues.append(response.issue)
        do {
            inventory = try await companion.castReview(book)
            if let next = CastReview.pending(inventory, ranges: relevantRanges).first {
                issue = next; newCharacters = []; selectSuggested()
            } else { dismiss() }
        } catch { self.error = error.localizedDescription }
    }
    private func resolutionRanges() -> [CastReviewRange]? {
        guard let resolvedRanges else { return nil }
        if resolvedRanges.count == 1, resolvedRanges[0].startOffset == issue.startOffset, resolvedRanges[0].endOffset == issue.endOffset { return nil }
        return resolvedRanges
    }
}
