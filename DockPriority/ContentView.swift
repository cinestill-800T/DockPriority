import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var coordinator: DockPriorityCoordinator
    @EnvironmentObject private var appSettings: AppSettings
    @State private var showingSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusCard
                prioritySection
                temporarySection
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 560)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(appSettings)
        }
        .task { coordinator.refresh() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("DockPriority").font(.largeTitle.bold())
                Text("Keep the Dock on the highest-priority available display.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
                .accessibilityIdentifier("settingsButton")
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(protectionTitle, systemImage: isProtectionActive ? "shield.checkered" : "shield")
                    .font(.headline)
                    .foregroundStyle(isProtectionActive ? .green : .secondary)
                Spacer()
                Button(isProtectionActive ? "Stop Protection" : "Start Protection") {
                    isProtectionActive ? coordinator.stop() : coordinator.start()
                }
                .accessibilityIdentifier("protectionToggle")
                .keyboardShortcut("p", modifiers: [.command, .option])
            }

            LabeledContent("Effective target", value: targetName(for: coordinator.effectiveTarget))
                .accessibilityIdentifier("effectiveTarget")
            LabeledContent("Dock location", value: targetName(for: coordinator.dockLocation))
                .accessibilityIdentifier("dockLocation")
            LabeledContent("Mode", value: coordinator.temporaryTarget == nil ? "Priority" : "Temporary")
                .accessibilityIdentifier("targetMode")

            if !statusMessage.isEmpty {
                Label(statusMessage, systemImage: statusMessage.lowercased().contains("permission") ? "exclamationmark.triangle" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(statusMessage.lowercased().contains("error") ? .red : .secondary)
                    .accessibilityIdentifier("statusMessage")
            }

            if coordinator.status == .accessibilityPermissionRequired {
                Button("Open Accessibility Settings", systemImage: "gear") {
                    openAccessibilitySettings()
                }
                .accessibilityIdentifier("openAccessibilitySettings")
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statusCard")
    }

    private var prioritySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display Priority").font(.title3.bold())
            Text("The first available display is the normal Dock target. Disconnected displays stay in this list.")
                .font(.callout).foregroundStyle(.secondary)

            if coordinator.rememberedDisplays.isEmpty {
                ContentUnavailableView("No remembered displays", systemImage: "display")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                List {
                    ForEach(Array(coordinator.rememberedDisplays.enumerated()), id: \.element.id) { index, display in
                        priorityRow(display, priority: index + 1)
                    }
                    .onMove { offsets, destination in
                        coordinator.movePriority(fromOffsets: offsets, toOffset: destination)
                    }
                }
                .frame(minHeight: 180, maxHeight: 300)
                .accessibilityIdentifier("priorityList")
            }
        }
    }

    private func priorityRow(_ display: RememberedDisplay, priority: Int) -> some View {
        let isAvailable = coordinator.activeDisplays.contains { $0.identity == display.identity }
        let isEffective = coordinator.effectiveTarget == display.identity
        return HStack(spacing: 12) {
            Text("\(priority)").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
            Image(systemName: isAvailable ? "display" : "display.slash")
                .foregroundStyle(isAvailable ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(display.lastKnownName)
                Text(isAvailable ? "Connected" : "Disconnected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isEffective {
                Text(coordinator.temporaryTarget == display.identity ? "Temporary target" : "Effective target")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
            Button("Move up", systemImage: "chevron.up") { coordinator.movePriorityUp(display.identity) }
                .disabled(priority == 1)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Move \(display.lastKnownName) up")
                .accessibilityIdentifier("priorityUp.\(priority)")
            Button("Move down", systemImage: "chevron.down") { coordinator.movePriorityDown(display.identity) }
                .disabled(priority == coordinator.rememberedDisplays.count)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Move \(display.lastKnownName) down")
                .accessibilityIdentifier("priorityDown.\(priority)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("priorityRow.\(priority)")
    }

    private var temporarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Show Temporarily On").font(.title3.bold())
                Spacer()
                if coordinator.temporaryTarget != nil {
                    Button("Return to Priority", systemImage: "arrow.uturn.backward") {
                        coordinator.returnToPriority()
                    }
                    .accessibilityIdentifier("returnToPriorityButton")
                }
            }
            Text("This one-click choice does not change your saved priority and resets after a display or wake event.")
                .font(.callout).foregroundStyle(.secondary)

            if coordinator.activeDisplays.isEmpty {
                Text("No connected displays are available.").foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(Array(coordinator.activeDisplays.enumerated()), id: \.element.id) { index, display in
                        Button(display.name, systemImage: "display") {
                            coordinator.chooseTemporaryTarget(display.identity)
                        }
                        .buttonStyle(.bordered)
                        .tint(coordinator.temporaryTarget == display.identity ? .accentColor : nil)
                        .accessibilityLabel("Show Dock temporarily on \(display.name)")
                        .accessibilityIdentifier("temporaryTarget.\(index)")
                    }
                }
                .accessibilityIdentifier("temporaryTargetList")
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var isProtectionActive: Bool { coordinator.protectionState.isActive }
    private var protectionTitle: String { isProtectionActive ? "Protection is active" : "Protection is stopped" }
    private var statusMessage: String { coordinator.status.message }

    private func targetName(for identity: DisplayIdentity?) -> String {
        guard let identity else { return "Unknown" }
        return coordinator.activeDisplays.first(where: { $0.identity == identity })?.name
            ?? coordinator.rememberedDisplays.first(where: { $0.identity == identity })?.lastKnownName
            ?? "Unknown display"
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Form {
                Section("Startup") {
                    Toggle("Start at Login", isOn: $appSettings.startAtLogin)
                    Toggle("Run in Background", isOn: $appSettings.runInBackground)
                }
                Section("Dock Movement") {
                    Picker("Cursor position", selection: $appSettings.cursorPosition) {
                        ForEach(CursorXPosition.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if appSettings.cursorPosition != .center {
                        TextField("Cursor offset", value: $appSettings.cursorOffset, format: .number)
                    }
                }
                Section("Appearance") {
                    Toggle("Show Menu Bar Icon", isOn: $appSettings.showStatusIcon)
                    Toggle("Hide from Dock", isOn: $appSettings.hideFromDock)
                    Picker("Theme", selection: $appSettings.appTheme) {
                        ForEach(AppTheme.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// A compact wrapping stack for the active-display buttons.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + (x > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = bounds.origin
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x > bounds.minX, point.x + size.width > bounds.maxX {
                point.x = bounds.minX
                point.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: point, proposal: ProposedViewSize(size))
            point.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
