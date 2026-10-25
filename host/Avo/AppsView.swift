import AvoKit
import SwiftUI

/// Spec §2: grid of installed apps with icon, name, version and size,
/// updated live from AppInstalled / AppRemoved.
struct AppsView: View {
    @Environment(ControlPanelModel.self) private var model
    @State private var search = ""
    @State private var inspected: AppRecord?
    @State private var graphicsApp: AppRecord?
    @State private var confirmUninstall: AppRecord?

    private var filtered: [AppRecord] {
        guard !search.isEmpty else { return model.apps }
        return model.apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) || $0.package.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        Group {
            if model.apps.isEmpty {
                EmptyAppsView()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 160), spacing: 20)], spacing: 24) {
                        ForEach(filtered) { app in
                            AppTile(app: app, icon: model.icons[app.package])
                                .onTapGesture(count: 2) { model.open(app) }
                                .contextMenu { menu(for: app) }
                        }
                    }
                    .padding(24)
                }
                .windowDragArea()
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps")
        .sheet(item: $inspected) { app in
            AppInfoSheet(app: app)
        }
        .sheet(item: $graphicsApp) { app in
            AppGraphicsSheet(app: app)
        }
        .confirmationDialog(confirmUninstall.map { String(localized: "Uninstall \($0.displayName)?") } ?? "",
                            isPresented: Binding(get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } }),
                            titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) {
                if let app = confirmUninstall { model.uninstall(app) }
            }
        } message: {
            Text("The app, its data and its shortcut in Android Apps are removed.")
        }
    }

    @ViewBuilder private func menu(for app: AppRecord) -> some View {
        Button("Open") { model.open(app) }
        Button("App Info…") { inspected = app }
        Button("Graphics Settings…") { graphicsApp = app }
        Divider()
        Button("Force Stop") { model.forceStop(app) }
        if let shim = app.shortcuts.shimPath {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: shim)]) }
        }
        // A system app (the Play Store, the Google app) cannot be
        // uninstalled: `pm uninstall` fails or only removes its update.
        // Reset Android removes Google apps.
        if !app.systemApp {
            Divider()
            Button("Uninstall…", role: .destructive) { confirmUninstall = app }
        }
    }
}

private struct AppTile: View {
    @Environment(ControlPanelModel.self) private var model
    let app: AppRecord
    let icon: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color("AvoFlesh"))
                        .overlay { Image(systemName: "app.dashed").font(.largeTitle).foregroundStyle(Color("AvoSkin")) }
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 2)

            Text(app.displayName)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text([app.versionName.isEmpty ? nil : app.versionName, formatBytes(app.sizeBytes)]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ActivityBadge(activity: model.activity[app.package])
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .help(app.package)
    }
}

/// Under each app: open, minimized, in the background, or nothing when it
/// does not run (like the dot under running apps in the Dock).
private struct ActivityBadge: View {
    let activity: AppActivity?

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            label.font(.caption2)
        }
        .foregroundStyle(.secondary)
        .opacity(activity == nil ? 0 : 1)
        .accessibilityHidden(activity == nil)
    }

    private var color: Color {
        switch activity {
        case .open?: .green
        case .minimized?: .orange
        case .background?: .secondary
        case nil: .clear
        }
    }

    private var label: Text {
        switch activity {
        case .open?: Text("Window open")
        case .minimized?: Text("Minimized")
        case .background?: Text("In background")
        case nil: Text(verbatim: " ")
        }
    }
}

private struct EmptyAppsView: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("No Android apps yet", systemImage: "square.grid.2x2")
        } description: {
            Text("Double-click an .apk file in Finder, or drop it here. Apps you install from F-Droid or Aurora Store inside Android show up here too.")
        } actions: {
            Button("Install App…") { model.chooseAndInstall() }
        }
    }
}

/// Settings › Aplikasi: permissions, force stop, clear data, uninstall (spec §6).
struct AppInfoSheet: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let app: AppRecord
    @State private var permissions: [AppPermission] = []
    @State private var loading = true
    @State private var confirmClear = false
    @State private var showGraphics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                if let icon = model.icons[app.package] {
                    Image(nsImage: icon).resizable().frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName).font(.title2.weight(.semibold))
                    Text(app.package).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Version").foregroundStyle(.secondary); Text("\(app.versionName) (\(app.versionCode))") }
                GridRow { Text("Size").foregroundStyle(.secondary); Text(formatBytes(app.sizeBytes)) }
                if let installer = app.installer {
                    GridRow { Text("Installed by").foregroundStyle(.secondary); Text(installer) }
                }
                if let date = app.updatedAt {
                    GridRow { Text("Updated").foregroundStyle(.secondary); Text(date, style: .date) }
                }
                if let graphics = model.graphics(for: app.package) {
                    GridRow {
                        Text("Graphics").foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(graphics.summary)
                            Button("Change…") { showGraphics = true }.controlSize(.small)
                        }
                    }
                }
            }
            .font(.callout)

            Text("Permissions").font(.headline)
            if loading {
                ProgressView().controlSize(.small)
            } else if permissions.filter(\.runtime).isEmpty {
                Text("This app has no permissions you can change.").foregroundStyle(.secondary).font(.callout)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(permissions.filter(\.runtime), id: \.name) { permission in
                            Toggle(isOn: Binding(get: { permission.granted }, set: { granted in
                                Task {
                                    await model.setPermission(permission, granted: granted, for: app)
                                    permissions = await model.permissions(for: app)
                                }
                            })) {
                                Text(PermissionNames.label(for: permission.name, fallback: permission.label))
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            HStack {
                Button("Force Stop") { model.forceStop(app) }
                Button("Clear Data…") { confirmClear = true }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .task {
            // The Graphics row says "automatic" from the key mappings, which
            // a window's key-mapping editor may have changed since.
            model.refreshKeyMappings()
            permissions = await model.permissions(for: app)
            loading = false
        }
        .sheet(isPresented: $showGraphics) {
            AppGraphicsSheet(app: app)
        }
        .confirmationDialog("Clear all data of \(app.displayName)?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Data", role: .destructive) { model.deleteData(app) }
        } message: {
            Text("Accounts, settings and files stored by the app are deleted.")
        }
    }
}
