import SwiftUI

struct ConnectionView: View {
    @Environment(CompanionStore.self) private var companion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var editConnection = false
    @State private var pair = false
    @State private var forget = false
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            ViewThatFits(in: .vertical) {
                content(compact: false)
                content(compact: true)
                ScrollView { content(compact: true) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Obsidian.background)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $editConnection) { CompanionConnectionView() }
            .sheet(isPresented: $pair) { PairingView() }
            .alert("Forget this PC?", isPresented: $forget) {
                Button("Forget PC", role: .destructive) {
                    do { try companion.forgetConnection() } catch { actionError = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes the saved pairing from your iPhone. Books and downloaded narration stay available. Pair again to reconnect.") }
            .alert("Connection", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK") { actionError = nil }
            } message: { Text(actionError ?? "") }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await companion.checkConnection()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    await companion.checkConnection()
                }
            }
        }
    }

    private func content(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: compact ? 3 : 8) {
                    if !compact { Label("BookPocket", systemImage: "book").font(.subheadline).foregroundStyle(Obsidian.accent) }
                    Text("Connection").font(compact ? .title.bold() : .largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Text("Your PC, in one place.").font(compact ? .subheadline : .body).foregroundStyle(.secondary)
                }
                Spacer()
                if canRefresh && !dynamicTypeSize.isAccessibilitySize { refreshButton }
            }
            if canRefresh && dynamicTypeSize.isAccessibilitySize { HStack { Spacer(); refreshButton } }
            if companion.identity != nil {
                savedPC(compact: compact)
                Button {
                    if !companion.paired { pair = true }
                    else if companion.connectionPaused { Task { await companion.resumeConnection() } }
                    else { do { try companion.pauseConnection() } catch { actionError = error.localizedDescription } }
                } label: {
                    Text(!companion.paired ? "Pair again" : companion.connectionPaused ? "Connect" : "Disconnect").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain).foregroundStyle(Obsidian.accent)
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(Obsidian.accent.opacity(0.8), lineWidth: 1) }
                .disabled(companion.updatingConnection || companion.pairing)
                .accessibilityIdentifier("connection.toggle")
                VStack(alignment: .leading, spacing: compact ? 6 : 12) {
                    Text("Saved PC").font(.headline)
                    VStack(spacing: 0) {
                        Button { editConnection = true } label: { settingsRow("Edit connection details", icon: "pencil") }
                            .accessibilityIdentifier("connection.edit")
                        Divider().padding(.horizontal, 16)
                        Button { forget = true } label: { settingsRow("Forget this PC", icon: "trash") }
                            .accessibilityIdentifier("connection.forget")
                    }.buttonStyle(.plain).background(Obsidian.surface, in: .rect(cornerRadius: 16))
                        .disabled(companion.updatingConnection || companion.pairing)
                }
                Text("Pairing stays saved when disconnected.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center).accessibilityIdentifier("connection.retention")
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "desktopcomputer").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(Obsidian.accent).accessibilityHidden(true)
                    Text("Connect your PC").font(.title2.bold())
                    Text("Generate narration on your PC, then take it with you. Reading and downloaded audio always work offline.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Pair a companion", systemImage: "qrcode.viewfinder") { pair = true }
                        .buttonStyle(.borderedProminent).foregroundStyle(Obsidian.onAccent).controlSize(.large)
                        .accessibilityIdentifier("connection.pair")
                }.padding(24).frame(maxWidth: .infinity).background(Obsidian.surface, in: .rect(cornerRadius: 22))
            }
        }
        .padding(compact ? 16 : 24).frame(maxWidth: 620)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func savedPC(compact: Bool) -> some View {
        VStack(spacing: compact ? 7 : 12) {
            Image(systemName: "desktopcomputer").font(.system(size: compact ? 34 : 60, weight: .ultraLight))
                .foregroundStyle(Obsidian.accent).accessibilityHidden(true)
            HStack(spacing: 7) {
                Image(systemName: companion.connectionState == .connected ? "circle.fill" : "circle").accessibilityHidden(true)
                Text(statusTitle).accessibilityIdentifier("connection.status")
            }
                .font(.caption.weight(.medium)).foregroundStyle(statusColor)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(statusColor.opacity(0.08), in: .capsule)
                .overlay { Capsule().stroke(statusColor.opacity(0.5), lineWidth: 1) }
            Text("Home PC").font(compact ? .title3.bold() : .title2.bold())
            Text(supportingText).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .accessibilityIdentifier("connection.help")
            VStack(spacing: compact ? 6 : 8) {
                statusRow("Pairing", icon: "link", value: companion.paired ? "Saved" : "Pair again", live: false)
                statusRow("Connection", icon: "wifi", value: statusTitle == "Connected" ? "Live" : statusTitle, live: companion.connectionState == .connected)
            }.padding(.top, compact ? 2 : 8)
        }.padding(compact ? 14 : 20).frame(maxWidth: .infinity)
            .background(Obsidian.surface, in: .rect(cornerRadius: 22))
    }
    private func statusRow(_ title: String, icon: String, value: String, live: Bool) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    Label { Text(title) } icon: { Image(systemName: icon).font(.system(size: 20)).frame(width: 24).accessibilityHidden(true) }
                    Text(value).foregroundStyle(live ? connectedColor : .secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: icon).font(.system(size: 20)).frame(width: 24).accessibilityHidden(true)
                    Text(title)
                    Spacer()
                    if live { Circle().fill(connectedColor).frame(width: 7, height: 7).accessibilityHidden(true) }
                    Text(value).foregroundStyle(live ? connectedColor : .secondary)
                }
            }
        }.font(.subheadline).padding(.horizontal, 14).frame(minHeight: 44)
            .background(.primary.opacity(0.025), in: .rect(cornerRadius: 12))
    }
    private func settingsRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 20)).frame(width: 24).foregroundStyle(Obsidian.accent).accessibilityHidden(true)
            Text(title).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            Image(systemName: "chevron.right").font(.system(size: 11)).frame(width: 12).foregroundStyle(.secondary).accessibilityHidden(true)
        }.font(.subheadline).padding(.horizontal, 16).frame(minHeight: 44).contentShape(.rect)
    }
    private var statusTitle: String {
        switch companion.connectionState {
        case .notChecked: "Not checked"
        case .checking: "Checking…"
        case .connected: "Connected"
        case .unavailable: "Unavailable"
        case .disconnected: "Disconnected"
        }
    }
    private var connectedColor: Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .systemGreen : UIColor(red: 0, green: 0.4, blue: 0.2, alpha: 1) })
    }
    private var canRefresh: Bool { companion.identity != nil && !companion.connectionPaused }
    private var refreshButton: some View {
        Button { Task { await companion.checkConnection() } } label: {
            Label("Refresh connection", systemImage: "arrow.clockwise").labelStyle(.iconOnly).font(.system(size: 20)).frame(width: 44, height: 44)
        }.disabled(companion.connectionState == .checking).accessibilityIdentifier("connection.refresh")
    }
    private var statusColor: Color { companion.connectionState == .connected ? connectedColor : Obsidian.accent }
    private var supportingText: String {
        if !companion.paired { return "Pair this iPhone again to restore access." }
        switch companion.connectionState {
        case .connected: return "Ready for transfers and narration."
        case .checking: return "Checking your saved PC…"
        case .disconnected: return "Pairing saved. Downloads stay available."
        case .unavailable: return "Your PC is unreachable. Check it is running or edit the connection details."
        case .notChecked: return "Pairing saved. Check the connection to your PC."
        }
    }
}
