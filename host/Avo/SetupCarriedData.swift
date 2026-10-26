import AppKit
import AvoKit
import AvoPackages
import SwiftUI

// The Setup Assistant on a new Mac: Android's data from another Mac, in the
// "Avo Android Data" folder Avo made there (on an external drive, say). Avo
// uses it where it is before Android first starts, so that start never makes
// new data in Avo's own storage; then the Android step chooses a version that
// can use the data (StorageLocations, AndroidDataFolder: data from a newer
// Android than an image can never start with that image), downloading it
// when this Mac has none.

/// What the assistant adopted, for the Android step's words.
struct CarriedAndroidData: Equatable {
    var summary: AndroidDataSummary
    /// The newest Android that used it.
    var release: AndroidRelease?
    var volume: String?
}

/// Welcome's "Use Android Data from Another Mac…": the folder panel, macOS's
/// question about the drive, the daemon's look, then SetupCarriedDataSheet.
struct SetupCarriedDataButton: View {
    @Environment(ControlPanelModel.self) private var model
    @State private var flow = StorageLocationFlow()

    var body: some View {
        Button {
            flow.chooseFolder(model, message: String(localized: "Choose the “Avo Android Data” folder Avo made on your other Mac, for example on an external drive."))
        } label: {
            Label("Use Android Data from Another Mac…", systemImage: "externaldrive")
                .labelStyle(HazeLabelStyle(spacing: 7, iconSize: 12.5))
        }
        .buttonStyle(HazeLinkButtonStyle())
        .font(.mona(13))
        .foregroundStyle(Haze.textSecondary)
        .disabled(flow.inspecting || model.daemonState != .connected)
        .help("Android’s apps and data from another Mac, in the “Avo Android Data” folder Avo made there. Android starts with them, where they are.")
        .sheet(item: Binding(get: { flow.candidate.map(Found.init) }, set: { flow.candidate = $0?.candidate })) { found in
            SetupCarriedDataSheet(candidate: found.candidate, flow: flow)
        }
    }

    private struct Found: Identifiable {
        let candidate: StorageCandidate
        var id: String { candidate.folder }
    }
}

/// What is in the folder (Android version, size, the Mac that used it last),
/// whether this Mac can start it, and Use This Data.
struct SetupCarriedDataSheet: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(SetupAssistant.self) private var assistant
    @Environment(AndroidImageManager.self) private var images
    @Environment(\.dismiss) private var dismiss
    let candidate: StorageCandidate
    let flow: StorageLocationFlow
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.hubot(24, 740))
                .tracking(-0.3)
            Text(verbatim: StoragePane.abbreviated(candidate.folder))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Haze.textTertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.top, 8)
            if let data = candidate.existing, !isBlocked {
                card(data).padding(.top, 18)
            }
            notes.padding(.top, 16)
            if let failure {
                note(symbol: "xmark.octagon.fill", tint: Haze.danger, Text(verbatim: failure)).padding(.top, 10)
            }
            buttons.padding(.top, 22)
        }
        .padding(28)
        .frame(width: 520, alignment: .leading)
        .background(Haze.windowBase)
        .foregroundStyle(Haze.text)
        .tint(Haze.accent)
        .task { await images.loadCatalog() }
        // Back from System Settings (Files & Folders): look again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if notPermitted { flow.recheck(model) }
        }
    }

    // MARK: What it says

    private var title: LocalizedStringKey {
        if notPermitted { return "Allow Avo to Read This Folder" }
        if candidate.existing == nil || isBlocked { return "No Android Data Avo Can Use" }
        return "Use This Android Data?"
    }

    private var notPermitted: Bool { if case .notPermitted? = candidate.problem { true } else { false } }

    /// A problem Setup can't get past here (only a newer Android it downloads next is).
    private var isBlocked: Bool {
        if candidate.isCurrent { return false }
        if candidate.problem != nil, !candidate.existingNeedsNewerAndroid { return true }
        return candidate.issues(for: .existing).contains { $0.severity == .error }
    }

    /// The newest Android that used the data (its own record in the folder).
    private var release: AndroidRelease? {
        let folder = AndroidDataFolder(URL(filePath: candidate.folder, directoryHint: .isDirectory))
        return folder.newestAndroid(manifest: try? AndroidDataManifest.load(from: folder.url))?.release
    }

    /// The version Setup would use with it, and whether it is on this Mac.
    private var fitting: AndroidVersionRow? { release.flatMap { images.rowFitting($0) } }

    private func card(_ data: AndroidDataSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            row("candybarphone", Text(verbatim: Self.android(data)))
            row("internaldrive", Text("\(StoragePane.bytes(data.allocatedBytes)) of apps and data"))
            if let mac = data.lastMac, let date = data.lastUsedAt {
                row("laptopcomputer", Text("Last used on \(mac), \(date.formatted(date: .abbreviated, time: .shortened))"))
            }
            if data.googleApps == true {
                row("play.fill", Text("Google apps are installed"))
            }
            if let volume = candidate.volume, !volume.isInternal {
                row("externaldrive", Text("On “\(volume.name)” (\(volume.formatName))"))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Haze.cardQuiet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Haze.text.opacity(0.06)) }
    }

    /// "Android 17 · build 16373615".
    static func android(_ data: AndroidDataSummary) -> String {
        let name = data.android ?? String(localized: "Android")
        return data.build.map { String(localized: "\(name) · build \($0)") } ?? name
    }

    private func row(_ symbol: String, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Haze.running)
                .frame(width: 18)
            text.font(.mona(13.5)).foregroundStyle(Haze.textSecondary)
        }
    }

    private func note(symbol: String, tint: Color, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(tint)
            text.font(.mona(13)).hazeParagraph(1.45, size: 13).foregroundStyle(Haze.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            if candidate.isCurrent {
                note(symbol: "checkmark.circle.fill", tint: Haze.running, Text("Android already uses this data."))
            } else if candidate.existing == nil {
                note(symbol: "questionmark.folder", tint: Haze.warning,
                     Text("There is no Android data in this folder. Choose the “Avo Android Data” folder Avo made on your other Mac."))
            } else if notPermitted {
                note(symbol: "lock.fill", tint: Haze.warning, Text(verbatim: candidate.problem?.message ?? ""))
            } else if isBlocked {
                if let problem = candidate.problem {
                    note(symbol: "exclamationmark.triangle.fill", tint: Haze.warning, Text(verbatim: problem.message))
                }
                ForEach(Array(candidate.issues(for: .existing).filter { $0.severity == .error }.enumerated()), id: \.offset) { _, issue in
                    note(symbol: "xmark.octagon.fill", tint: Haze.danger, Text(verbatim: issue.message))
                }
            } else {
                versionNote
                note(symbol: "arrow.triangle.branch", tint: Haze.running,
                     Text("Avo uses the data where it is: Android starts with your apps, accounts and files, and nothing is copied to this Mac."))
                ForEach(Array(candidate.issues(for: .existing).filter { $0.severity == .warning }.enumerated()), id: \.offset) { _, issue in
                    note(symbol: "exclamationmark.triangle", tint: Haze.warning, Text(verbatim: issue.message))
                }
            }
        }
    }

    /// Which Android starts with the data: one on this Mac, one Avo downloads next, or none.
    @ViewBuilder private var versionNote: some View {
        if let release {
            if let fitting, fitting.image != nil {
                note(symbol: "checkmark.seal", tint: Haze.running, Text("\(fitting.name) is on this Mac and can use this data."))
            } else if let fitting, let offer = fitting.offer {
                note(symbol: "arrow.down.to.line", tint: Haze.running,
                     Text("This data needs \(release.name) or newer. Avo downloads \(fitting.name) next (\(formatBytes(offer.downloadSize)))."))
            } else if case .loaded = images.catalog {
                note(symbol: "exclamationmark.triangle.fill", tint: Haze.warning,
                     Text("This data needs \(release.name) or newer, and Avo can’t find one to download. You can use the data once that Android is on this Mac."))
            } else {
                note(symbol: "arrow.down.to.line", tint: Haze.running, Text("This data needs \(release.name) or newer. Avo finds it next."))
            }
        }
    }

    // MARK: Using it

    private var canUse: Bool {
        guard !working, !candidate.isCurrent, candidate.existing != nil, !isBlocked else { return false }
        // Data no Android Avo knows of can use: not until one is there.
        if let release, case .loaded = images.catalog, images.rowFitting(release) == nil { return false }
        return true
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if notPermitted {
                Button("Open System Settings") { StorageLocationFlow.openFilesAndFolders() }
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 40, fontSize: 13.5, horizontalPadding: 16))
                Button("Check Again") { flow.recheck(model) }
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 40, fontSize: 13.5, horizontalPadding: 16))
            } else if candidate.existing == nil || isBlocked {
                Button("Choose Another…") {
                    dismiss()
                    flow.chooseFolder(model, message: String(localized: "Choose the “Avo Android Data” folder Avo made on your other Mac, for example on an external drive."))
                }
                .buttonStyle(HazeButtonStyle(kind: .secondary, height: 40, fontSize: 13.5, horizontalPadding: 16))
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(HazeLinkButtonStyle())
                .font(.mona(14))
                .foregroundStyle(Haze.textTertiary)
                .padding(.horizontal, 8)
                .keyboardShortcut(.cancelAction)
            if candidate.isCurrent {
                Button("Continue") {
                    dismiss()
                    assistant.next()
                }
                .buttonStyle(HazeButtonStyle(kind: .primary, height: 40, fontSize: 14, horizontalPadding: 22))
                .keyboardShortcut(.defaultAction)
            } else if !(candidate.existing == nil || isBlocked || notPermitted) {
                Button {
                    use()
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Use This Data") }
                }
                .buttonStyle(HazeButtonStyle(kind: .primary, height: 40, fontSize: 14, horizontalPadding: 22))
                .keyboardShortcut(.defaultAction)
                .disabled(!canUse)
            }
        }
    }

    /// Android's data is in the folder from now on; the Android step chooses a version for it.
    private func use() {
        let running = ![.stopped, .notInstalled, .failed].contains(model.status.state)
        let request = StorageChangeRequest(destination: candidate.chosen, action: .useExisting, stopAndroid: running,
                                           allowNewerAndroid: true)
        let carried = candidate.existing.map { CarriedAndroidData(summary: $0, release: release, volume: candidate.volume?.name) }
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                try await model.changeStorage(request)
                images.refresh()
                assistant.carriedData = carried
                assistant.firstStart = false
                if let release = carried?.release, let row = images.rowFitting(release) { assistant.selection = row.id }
                dismiss()
                assistant.step = .android
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
