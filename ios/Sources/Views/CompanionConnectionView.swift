import SwiftUI

struct CompanionConnectionView: View {
    @Environment(CompanionStore.self) private var companion
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var fingerprint = ""
    @State private var message: String?
    @State private var task: Task<Void, Never>?
    @FocusState private var editingAddress: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("HTTPS companion address", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($editingAddress).submitLabel(.done).onSubmit { editingAddress = false }
                            .accessibilityIdentifier("connection.address")
                        if !address.isEmpty {
                            Button { address = "" } label: { Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44) }
                                .buttonStyle(.plain).accessibilityLabel("Clear address").accessibilityIdentifier("connection.clear")
                        }
                    }.disabled(companion.updatingConnection)
                    TextField("Certificate SHA-256 (if supplied)", text: $fingerprint, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled().font(.caption.monospaced())
                        .accessibilityIdentifier("connection.fingerprint")
                } header: { Text("Reach your paired PC") } footer: {
                    Text("Enter your PC's public HTTPS address to connect away from home. Leave the fingerprint blank for a publicly trusted certificate. For a local connection, use the fingerprint supplied by your PC.")
                }
                Section {
                    Button(companion.updatingConnection ? "Verifying connection…" : "Verify & save address") {
                        message = nil
                        task = Task {
                            do {
                                guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw BookError.message("Enter a valid HTTPS companion address.") }
                                try await companion.updateConnection(url: url, fingerprint: fingerprint.trimmingCharacters(in: .whitespacesAndNewlines))
                                dismiss()
                            } catch is CancellationError {} catch { message = CompanionClient.narrationMessage(for: error) }
                        }
                    }.disabled(address.isEmpty || companion.updatingConnection).accessibilityIdentifier("connection.save")
                } footer: { Text("Your existing pairing and downloads are kept. The previous address remains saved until the new connection verifies successfully.") }
                if let message { Text(message).foregroundStyle(.red).accessibilityIdentifier("connection.error") }
            }.navigationTitle("Companion connection").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { task?.cancel(); dismiss() } } }
                .onAppear { address = companion.identity?.url.absoluteString ?? ""; fingerprint = companion.identity?.fingerprint ?? "" }
                .onDisappear { task?.cancel() }
        }.tint(Obsidian.accent)
    }
}
