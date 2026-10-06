import SwiftUI

struct PronunciationEditorView: View {
    var selectedText = ""
    var language = "en"
    var onRegenerate: (() -> Void)?
    @Environment(CompanionStore.self) private var companion
    @Environment(PlaybackController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var term = ""
    @State private var replacement = ""
    @State private var sample = ""
    @State private var enabled = true
    @State private var editingTerm: String?
    @State private var editRevision = 0
    @State private var error: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var conflict = false
    @State private var preview = PronunciationPreview()
    @FocusState private var editing: Bool
    private var proposed: PronunciationRule { .init(term: term, replacement: replacement, enabled: enabled) }
    private var valid: Bool { (try? PronunciationCorrections.validate([proposed])) != nil }
    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            Form {
                Section {
                    Text("Change how a name or word is spoken. The text in your book stays exactly as written.").id("pronunciation.draft")
                    TextField("Written word or phrase", text: $term).textInputAutocapitalization(.never).autocorrectionDisabled().focused($editing).accessibilityIdentifier("pronunciation.term")
                    TextField("Speak as", text: $replacement).textInputAutocapitalization(.never).autocorrectionDisabled().focused($editing).accessibilityIdentifier("pronunciation.replacement")
                    Toggle("Enabled", isOn: $enabled).accessibilityIdentifier("pronunciation.enabled")
                    Button(editingTerm == nil ? "Save correction" : "Update correction") { save() }
                        .disabled(!valid || busy).accessibilityIdentifier("pronunciation.save")
                    if editingTerm != nil { Button("New correction") { reset() }.accessibilityIdentifier("pronunciation.new") }
                } header: { Text(editingTerm == nil ? "Try a pronunciation" : "Edit correction") }
                Section("On-device preview") {
                    TextField("Test sentence (optional)", text: $sample, axis: .vertical).focused($editing).accessibilityIdentifier("pronunciation.sample")
                    Button("Preview original", systemImage: "play.circle") { play(corrected: false) }.disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("pronunciation.preview.original")
                    Button("Preview correction", systemImage: "play.circle") { play(corrected: true) }.disabled(!valid).accessibilityIdentifier("pronunciation.preview.corrected")
                    if preview.playing { Button("Stop preview") { preview.stop() }.accessibilityIdentifier("pronunciation.preview.stop") }
                    Text("Apple voice previews your draft without saving it. Kyon and full cast use saved corrections when you generate new audio.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Saved corrections") {
                    ForEach(companion.narrationPronunciations) { rule in
                        VStack(alignment: .leading) {
                            Button { term = rule.term; replacement = rule.replacement; enabled = rule.enabled; editingTerm = rule.term; editRevision += 1 } label: { Label("\(rule.term) → \(rule.replacement)", systemImage: "pencil") }
                                .buttonStyle(.borderless).frame(minHeight: 44)
                                .accessibilityIdentifier("pronunciation.edit." + rule.term)
                            Toggle("Enabled", isOn: Binding(get: { companion.narrationPronunciations.first { $0.term == rule.term }?.enabled ?? false }, set: { value in update(rule, enabled: value) }))
                                .accessibilityIdentifier("pronunciation.toggle." + rule.term)
                            Button("Remove correction", role: .destructive) { remove(rule) }.buttonStyle(.borderless).frame(minHeight: 44).accessibilityIdentifier("pronunciation.remove." + rule.term)
                        }
                    }
                    if companion.narrationPronunciations.isEmpty { Text("No corrections saved.").foregroundStyle(.secondary) }
                }
                Section("Sync & recordings") {
                    Text(companion.pronunciationDraft == nil ? "Saved corrections are available on this iPhone." : "Saved on this iPhone. New audio requests include these corrections, even before you sync.").font(.caption)
                        .accessibilityIdentifier("pronunciation.persistence")
                    Button("Save corrections to PC") { sync() }.disabled(!companion.paired || busy).accessibilityIdentifier("pronunciation.sync")
                    Text("Existing recordings stay unchanged. Generate the page or chapter again to hear your corrections.").font(.caption)
                    if let onRegenerate { Button("Regenerate page or chapter") { preview.stop(); dismiss(); onRegenerate() }.accessibilityIdentifier("pronunciation.regenerate") }
                }
                if let notice { Section { Text(notice).accessibilityIdentifier("pronunciation.notice") } }
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("pronunciation.error") } }
            }.scrollContentBackground(.hidden).background(Obsidian.background)
                .navigationTitle("Pronunciation").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("pronunciation.done") }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done typing") { editing = false }.accessibilityIdentifier("pronunciation.keyboard.done") }
                }
                .onAppear { if term.isEmpty { term = selectedText } }
                .onChange(of: editRevision) {
                    // Editing a saved row brings its populated fields into view
                    // on smaller phones, without unexpectedly opening a keyboard.
                    withAnimation(.easeInOut(duration: 0.2)) { scroll.scrollTo("pronunciation.draft", anchor: .top) }
                }
                .onDisappear { preview.stop() }
                .confirmationDialog("The PC corrections changed. Your phone draft is kept.", isPresented: $conflict, titleVisibility: .visible) {
                    Button("Load PC corrections", role: .destructive) { Task { do { try await companion.reloadPronunciationsFromPC(); notice = "PC corrections loaded." } catch { self.error = error.localizedDescription } } }
                    Button("Keep phone draft", role: .cancel) {}
                } message: { Text("Loading the PC list replaces your phone draft. Review both lists before saving again.") }
            }
        }.tint(Obsidian.accent)
    }
    private func reset() { term = ""; replacement = ""; sample = ""; editingTerm = nil; enabled = true }
    private func save() {
        do {
            let normalized = try PronunciationCorrections.validate([proposed])[0]
            var rules = companion.narrationPronunciations
            rules.removeAll { $0.term == editingTerm || $0.term.caseInsensitiveCompare(normalized.term) == .orderedSame }
            rules.append(normalized); try companion.savePronunciationsOnPhone(rules)
            notice = "Correction saved for new audio. Regenerate existing recordings to apply it."; error = nil; reset()
        } catch { self.error = error.localizedDescription }
    }
    private func update(_ rule: PronunciationRule, enabled: Bool) {
        do { try companion.savePronunciationsOnPhone(companion.narrationPronunciations.map { $0.term == rule.term ? .init(term: rule.term, replacement: rule.replacement, enabled: enabled) : $0 }) }
        catch { self.error = error.localizedDescription }
    }
    private func remove(_ rule: PronunciationRule) {
        do { try companion.savePronunciationsOnPhone(companion.narrationPronunciations.filter { $0.term != rule.term }); if editingTerm == rule.term { reset() } }
        catch { self.error = error.localizedDescription }
    }
    private func play(corrected: Bool) {
        let original = sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? term : sample
        player.pause()
        do { try preview.play(corrected ? PronunciationCorrections.apply([proposed], to: original) : original, language: language) }
        catch { self.error = error.localizedDescription }
    }
    private func sync() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await companion.savePronunciationsToPC(); notice = "Corrections saved to PC." }
            catch let failure as CompanionHTTPError where failure.statusCode == 409 { error = failure.detail; conflict = true }
            catch { self.error = error.localizedDescription }
        }
    }
}
