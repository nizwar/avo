import AvoKit
import AvoPackages
import SwiftUI

/// Spec §3: confirmation sheet with name, version and permissions, then
/// progress (including booting Android when it is not running).
struct InstallSheet: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let pending = model.pendingInstall {
                if let summary = pending.summary {
                    Header(summary: summary)
                    if let progress = pending.progress {
                        ProgressSection(progress: progress)
                    } else {
                        Details(summary: summary)
                    }
                } else if let error = pending.inspectionError {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(pending.url.lastPathComponent) can’t be installed").font(.headline)
                            Text(error).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title)
                    }
                } else {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Reading \(pending.url.lastPathComponent)…")
                    }
                }
                Buttons(pending: pending)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private struct Header: View {
        let summary: PackageSummary

        var body: some View {
            HStack(spacing: 14) {
                PackageIconView(icon: summary.icon)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.label).font(.title2.weight(.semibold))
                    Text(summary.packageName).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Version \(summary.versionName ?? "\(summary.versionCode)") · \(formatBytes(Int64(summary.installBytes + summary.obbBytes)))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private struct Details: View {
        let summary: PackageSummary

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(summary.compatibility.enumerated()), id: \.offset) { _, issue in
                    Label(issue.message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let dangerous = PermissionNames.notable(summary.permissions)
                if !dangerous.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This app can ask for").font(.headline)
                        ForEach(dangerous, id: \.self) { label in
                            Label(label, systemImage: "checkmark.shield")
                                .labelStyle(.titleAndIcon)
                                .font(.callout)
                        }
                    }
                }
                if summary.parts.count > 1 || !summary.obbFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        if summary.parts.count > 1 {
                            Text("\(summary.format.rawValue.uppercased()) bundle with \(summary.parts.count) APKs.")
                        }
                        if !summary.obbFiles.isEmpty {
                            Text("Installing also copies \(summary.obbFiles.count) game data files (OBB) to Android/obb.")
                        }
                        if !summary.skippedSplits.isEmpty {
                            Text("Parts for other devices are left out: \(summary.skippedSplits.joined(separator: ", ")).")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private struct ProgressSection: View {
        let progress: InstallProgress

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                switch progress.phase {
                case .failed:
                    Label {
                        if let message = progress.message { Text(verbatim: message) } else { Text("Installation failed.") }
                    } icon: {
                        Image(systemName: "xmark.octagon.fill")
                    }
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                case .finished:
                    Label("Installed. The app is in Launchpad and Android Apps.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                default:
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction) { Text(title) }
                    } else {
                        ProgressView { Text(title) }
                    }
                }
            }
        }

        private var title: LocalizedStringKey {
            switch progress.phase {
            case .inspecting: "Checking the package…"
            case .startingVM: "Starting Android…"
            case .transferring: "Copying to Android…"
            case .installing: "Installing…"
            case .copyingOBB: "Copying game data (OBB)…"
            case .creatingShortcuts: "Creating the shortcut…"
            case .finished, .failed: ""
            }
        }
    }

    private struct Buttons: View {
        @Environment(ControlPanelModel.self) private var model
        let pending: ControlPanelModel.PendingInstall

        var body: some View {
            HStack {
                Spacer()
                switch pending.progress?.phase {
                case nil:
                    Button("Cancel", role: .cancel) { model.dismissInstall() }
                        .keyboardShortcut(.cancelAction)
                    Button("Install") { model.confirmInstall() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!(pending.summary?.isInstallable ?? false))
                case .finished?:
                    if let package = pending.finishedPackage, let app = model.apps.first(where: { $0.package == package }) {
                        Button("Open") {
                            model.open(app)
                            model.dismissInstall()
                        }
                    }
                    Button("Done") { model.dismissInstall() }.keyboardShortcut(.defaultAction)
                case .failed?:
                    Button("Close") { model.dismissInstall() }.keyboardShortcut(.defaultAction)
                default:
                    HideButton(startedAt: pending.startedAt) { model.dismissInstall() }
                }
            }
        }
    }

    /// Hide takes the place Install had, where the second click of a
    /// double-click lands: it waits a moment before it takes clicks.
    private struct HideButton: View {
        let startedAt: Date?
        let action: () -> Void
        @State private var ready = false

        var body: some View {
            Button("Hide", action: action)
                .disabled(!ready)
                .task {
                    let wait = 0.8 - Date().timeIntervalSince(startedAt ?? .distantPast)
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    ready = true
                }
        }
    }
}

/// Renders a package's icon before installation (bitmap or adaptive layers).
struct PackageIconView: View {
    let icon: PackageIcon?

    var body: some View {
        ZStack {
            switch icon {
            case .bitmap(let data)?:
                image(data)
            case let .adaptive(background, foreground, _)?:
                layer(background)
                    .scaleEffect(1.5) // 108 dp layer, 72 dp visible
                layer(foreground)
                    .scaleEffect(1.5)
            case nil:
                Color("AvoFlesh")
                Image(systemName: "shippingbox").font(.largeTitle).foregroundStyle(Color("AvoSkin"))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private func layer(_ layer: IconLayer?) -> some View {
        switch layer {
        case .color(let argb)?:
            Color(.sRGB, red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255,
                  blue: Double(argb & 0xFF) / 255, opacity: Double(argb >> 24) / 255)
        case .bitmap(let data)?:
            image(data)
        case .vector?, nil:
            Color.clear
        }
    }

    @ViewBuilder private func image(_ data: Data) -> some View {
        if let image = NSImage(data: data) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Color("AvoFlesh")
        }
    }
}
