import AppKit
import AvoKit
import SwiftUI

// Settings › Storage › Location, and the Library's banner for a drive that
// is not connected: choosing a folder, what the daemon finds there, and the
// change (move, use the data there, or start fresh) with its progress.

/// One window's way through choosing a place: the folder panel, macOS's
/// question about removable volumes, the daemon's look at the folder, then
/// the sheet (StorageLocationSheet).
@MainActor
@Observable
final class StorageLocationFlow {
    /// What the daemon found; the sheet shows while it is set.
    var candidate: StorageCandidate?
    private(set) var inspecting = false
    /// The folder looked at last (nil: Avo's own storage), for Check Again.
    private var lastPath: String?

    static let explainedKey = "AvoRemovableVolumeExplained"

    /// "Change Location…" and "Choose Another…" (`message`: the panel's own words).
    func chooseFolder(_ model: ControlPanelModel, message: String? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = message ?? String(localized: "Choose where Android’s data should be, for example an external drive. Avo keeps it in a folder named “Avo Android Data”, which you can take to another Mac.")
        guard panel.runModal() == .OK, let url = panel.url, Self.explainRemovableVolume(url), Self.explainProtectedFolder(url) else { return }
        inspect(url.path, model)
    }

    /// "Use Avo’s Own Storage…".
    func useOwnStorage(_ model: ControlPanelModel) {
        inspect(nil, model)
    }

    /// Looks again (after the user allowed Avo in System Settings).
    func recheck(_ model: ControlPanelModel) {
        inspect(lastPath, model)
    }

    private func inspect(_ path: String?, _ model: ControlPanelModel) {
        guard !inspecting else { return }
        inspecting = true
        lastPath = path
        Task {
            defer { inspecting = false }
            do {
                let found = try await model.inspectStorage(path)
                if path != nil, found.problem.map({ if case .notPermitted = $0 { false } else { true } }) ?? true {
                    UserDefaults.standard.set(true, forKey: Self.explainedKey)
                }
                candidate = found
            } catch {
                model.lastError = error.localizedDescription
            }
        }
    }

    /// The daemon reads the folder, and on a drive macOS asks first whether
    /// Avo may: said before it asks (once), so the answer is Allow.
    static func explainRemovableVolume(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeNameKey]
        let values = try? url.resourceValues(forKeys: keys)
        let removable = values?.volumeIsInternal == false || values?.volumeIsRemovable == true || values?.volumeIsEjectable == true
        guard removable, !UserDefaults.standard.bool(forKey: explainedKey) else { return true }
        let name = values?.volumeName ?? url.lastPathComponent
        let alert = NSAlert()
        alert.messageText = String(localized: "Allow Avo to use “\(name)”")
        alert.informativeText = String(localized: "Avo reads and writes Android’s data on this drive while Android runs. macOS asks next whether “Avo” may access files on a removable volume: choose Allow. Without it Android can’t use the drive.")
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The same for Documents, Desktop and Downloads, which macOS guards too.
    static func explainProtectedFolder(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard let folder = ["Documents", "Desktop", "Downloads"].first(where: { path == "\(home)/\($0)" || path.hasPrefix("\(home)/\($0)/") })
        else { return true }
        let name = FileManager.default.displayName(atPath: "\(home)/\(folder)")
        let alert = NSAlert()
        alert.messageText = String(localized: "Allow Avo to use your \(name) folder")
        alert.informativeText = String(localized: "Avo reads and writes Android’s data in this folder while Android runs. macOS may ask next whether “Avo” may access files in your \(name) folder: choose Allow.")
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// System Settings › Privacy & Security › Files & Folders.
    static func openFilesAndFolders() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension View {
    /// Presents the flow's sheet in this window.
    func storageLocationSheet(_ flow: StorageLocationFlow) -> some View {
        sheet(item: Binding(get: { flow.candidate.map(CandidateItem.init) }, set: { flow.candidate = $0?.candidate })) { item in
            StorageLocationSheet(candidate: item.candidate, recheck: { flow.recheck($0) })
        }
    }
}

private struct CandidateItem: Identifiable {
    let candidate: StorageCandidate
    var id: String { candidate.folder }
}

// MARK: Settings › Storage › Location

/// The Location rows of Settings › Storage.
struct StorageLocationRows: View {
    @Environment(ControlPanelModel.self) private var model
    @State private var flow = StorageLocationFlow()
    @State private var confirmRemoveCopy = false

    var body: some View {
        if let location = model.storageLocation {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: location.isInternal ? "internaldrive" : "externaldrive")
                            .foregroundStyle(.secondary)
                        Text(verbatim: StoragePane.abbreviated(location.path))
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .help(Text(verbatim: location.path))
                    }
                    HStack(spacing: 6) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: location.path)]) }
                            .disabled(location.problem != nil)
                        Button("Change Location…") { flow.chooseFolder(model) }
                            .disabled(flow.inspecting || model.isInstallingGoogleApps || (model.storageProgress.map { !$0.isDone } ?? false))
                    }
                }
            } label: {
                HelpTitle("Location") {
                    Text("Where Android’s apps and data are kept. Choose a folder on an external drive to take Android’s data to another Mac: Avo keeps it in a folder named “Avo Android Data”, which Avo on the other Mac uses with Change Location… › Use the Android data already there.")
                    Text("Android images, Avo’s settings and key mappings stay on each Mac.")
                }
            }
            .storageLocationSheet(flow)
            if let volume = location.volume, !location.isInternal {
                LabeledContent("Drive") {
                    Text("\(volume.name), \(volume.formatName), \(StoragePane.bytes(volume.freeBytes)) free")
                        .foregroundStyle(.secondary)
                }
            }
            if let problem = location.problem {
                StorageProblemRow(problem: problem, flow: flow)
                    .hazeRowNote()
            }
            if let copy = location.internalCopy {
                LabeledContent {
                    Button("Remove Copy…") { confirmRemoveCopy = true }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copy in Avo’s own storage")
                        Text(Self.copyDescription(copy)).font(.mona(12)).foregroundStyle(Haze.textTertiary)
                    }
                }
                .confirmationDialog("Remove the copy of Android’s data in Avo’s own storage?", isPresented: $confirmRemoveCopy,
                                    titleVisibility: .visible) {
                    Button("Remove Copy", role: .destructive) { model.removeInternalStorageCopy() }
                } message: {
                    Text("Android keeps using its data in \(StoragePane.abbreviated(location.path)). Without the copy, Use Avo’s Own Storage can only start fresh.")
                }
            }
            if let progress = model.storageProgress, !progress.isDone {
                StorageProgressRow(progress: progress)
                    .hazeRowNote()
            }
        } else {
            // An older daemon: the data is where it always was.
            LabeledContent("Location") {
                Text(verbatim: StoragePane.abbreviated(AvoPaths().dataDisk.path)).foregroundStyle(.secondary)
            }
        }
    }

    static func copyDescription(_ copy: AndroidDataSummary) -> String {
        let size = StoragePane.bytes(copy.allocatedBytes)
        if let date = copy.lastUsedAt {
            return String(localized: "\(size), last used \(date.formatted(date: .abbreviated, time: .shortened))")
        }
        return size
    }
}

/// Why Android's data cannot be used, with the ways out.
struct StorageProblemRow: View {
    @Environment(ControlPanelModel.self) private var model
    let problem: StorageProblem
    let flow: StorageLocationFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: problem.message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(Haze.warning)
            }
            .font(.mona(13))
            HStack {
                Spacer()
                if case .notPermitted = problem {
                    Button("Open System Settings") { StorageLocationFlow.openFilesAndFolders() }
                }
                Button("Choose Another…") { flow.chooseFolder(model) }
                Button("Use Avo’s Own Storage…") { flow.useOwnStorage(model) }
            }
            .disabled(flow.inspecting)
        }
        // Allowed in System Settings, or the drive connected meanwhile: the status follows.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshStorageLocation() }
        }
    }
}

private struct StorageProgressRow: View {
    let progress: StorageChangeProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GlowBar(fraction: progress.fraction, moving: true)
                .accessibilityLabel(Text(StorageProgressText.text(progress)))
            Text(StorageProgressText.text(progress)).font(.mona(12)).foregroundStyle(Haze.textSecondary).monospacedDigit()
        }
    }
}

@MainActor
enum StorageProgressText {
    static func text(_ progress: StorageChangeProgress) -> String {
        let done = StoragePane.bytes(progress.doneBytes)
        let total = StoragePane.bytes(progress.totalBytes)
        switch progress.phase {
        case .stopping: return String(localized: "Stopping Android…")
        case .checking: return String(localized: "Checking…")
        case .copying: return String(localized: "Copying Android’s data: \(done) of \(total)")
        case .verifying: return String(localized: "Checking the copy: \(done) of \(total)")
        case .switching: return String(localized: "Switching to the new place…")
        case .removingOld: return String(localized: "Removing the old copy…")
        case .finished: return String(localized: "Done")
        case .failed, .cancelled: return progress.message ?? String(localized: "Stopped")
        }
    }
}

// MARK: The Library's banner

/// Android's data cannot be used (its drive is not connected): the Library says so.
struct StorageProblemBanner: View {
    @Environment(ControlPanelModel.self) private var model
    @State private var flow = StorageLocationFlow()

    var body: some View {
        if model.daemonState == .connected, let problem = model.storageLocation?.problem {
            HazeBanner(symbol: "externaldrive.badge.exclamationmark", tint: Haze.warning, text: "\(problem.message)") {
                if case .notPermitted = problem {
                    Button("Open System Settings") { StorageLocationFlow.openFilesAndFolders() }
                } else {
                    Button("Choose Another…") { flow.chooseFolder(model) }
                    Button("Use Avo’s Own Storage…") { flow.useOwnStorage(model) }
                }
            }
            .storageLocationSheet(flow)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.refreshStorageLocation() }
            }
        }
    }
}

// MARK: The sheet

/// What the daemon found at the chosen place, the choices it allows, and the
/// change with its progress.
struct StorageLocationSheet: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    let candidate: StorageCandidate
    /// Looks at the folder again (macOS's permission changed meanwhile).
    var recheck: ((ControlPanelModel) -> Void)?

    enum Choice: Hashable { case move, existing, fresh }

    @State private var choice: Choice = .move
    @State private var keepOldCopy = false
    @State private var size = 64
    @State private var request: StorageChangeRequest?
    @State private var failure: String?
    @State private var confirmReplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.hubot(21, 750))
                .tracking(-0.3)
            place
            if candidate.isCurrent {
                Text("Android’s data is there already.").foregroundStyle(Haze.textSecondary)
            } else if case .notPermitted = candidate.problem {
                notPermitted
            } else if request == nil {
                choices
            }
            if let request {
                running(request)
            }
            if let failure {
                Label { Text(verbatim: failure) } icon: { Image(systemName: "xmark.octagon.fill").foregroundStyle(Haze.danger) }
                    .font(.mona(13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(24)
        .frame(width: 520)
        .background { HazeSheetBackground() }
        // In the haze, as the Library and Settings it opens from.
        .hazeFormControls()
        .environment(\.colorScheme, .dark)
        .onAppear(perform: chooseDefault)
        .confirmationDialog("Replace the copy in Avo’s own storage?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace Copy", role: .destructive) { start(replacing: true) }
        } message: {
            Text("Avo’s own storage still holds a copy of Android’s data from before. It is erased first.")
        }
    }

    private var title: LocalizedStringKey {
        if candidate.isInternal { return "Use Avo’s Own Storage" }
        if let name = candidate.volume?.name, candidate.volume?.isInternal == false { return "Keep Android’s Data on “\(name)”" }
        return "Change Where Android’s Data Is"
    }

    private var place: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: StoragePane.abbreviated(candidate.folder))
                .font(.system(size: 12.5, design: .monospaced))
                .truncationMode(.middle)
                .lineLimit(2)
            if let volume = candidate.volume {
                Text("\(volume.name): \(volume.formatName), \(StoragePane.bytes(volume.freeBytes)) free of \(StoragePane.bytes(volume.capacityBytes))")
                    .font(.mona(12)).foregroundStyle(Haze.textTertiary)
            }
        }
    }

    private var notPermitted: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: candidate.problem?.message ?? "")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings") { StorageLocationFlow.openFilesAndFolders() }
                if let recheck { Button("Check Again") { recheck(model) } }
            }
        }
        // Back from System Settings: look again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in recheck?(model) }
    }

    @ViewBuilder private var choices: some View {
        let movable = candidate.allows(.move) || (candidate.isInternal && candidate.currentAvailable)
        let usable = candidate.allows(.existing)
        let fresh = candidate.allows(.fresh) || candidate.isInternal
        VStack(alignment: .leading, spacing: 10) {
            option(.move, enabled: movable, title: "Move my Android data there",
                   detail: candidate.isInternal
                       ? "Avo copies Android’s data back to this Mac (\(StoragePane.bytes(candidate.moveBytes))), checks the copy, then uses it."
                       : "Avo copies Android’s data there (\(StoragePane.bytes(candidate.moveBytes))), checks every byte of the copy, then uses it.")
            if choice == .move, movable {
                Toggle(isOn: $keepOldCopy) { Text(keepLabel) }
                    .padding(.leading, 24)
                    .help("Android goes on with the new place either way; the old copy stays as it is now.")
            }
            option(.existing, enabled: usable, title: "Use the Android data already there", detail: existingDetail)
            option(.fresh, enabled: fresh, title: "Start fresh there",
                   detail: "Android starts empty there, like a new phone. The data it has now stays where it is.")
            if choice == .fresh, fresh {
                HStack(spacing: 10) {
                    Text("Size")
                    HazePicker("Size", selection: $size) {
                        for choice in VMConfig.dataDiskChoices { HazeOption("\(choice) GB", choice) }
                    }
                }
                .padding(.leading, 24)
            }
            issues
            if model.status.state != .stopped, model.status.state != .notInstalled, model.status.state != .failed {
                Label("Android stops first; open apps close.", systemImage: "stop.circle")
                    .font(.mona(12)).foregroundStyle(Haze.textTertiary)
            }
        }
    }

    private func option(_ value: Choice, enabled: Bool, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button {
            choice = value
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: choice == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice == value ? Haze.accent : Haze.textTertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.mona(13.5, 600)).foregroundStyle(Haze.text)
                    Text(detail).font(.mona(12)).foregroundStyle(Haze.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(choice == value ? Haze.selection : Haze.tile, in: shape)
            .overlay { shape.strokeBorder(choice == value ? Haze.accent.opacity(0.5) : Haze.text.opacity(0.05)) }
            .contentShape(shape)
            .animation(Haze.Motion.hover, value: choice)
        }
        .buttonStyle(HazeCardButtonStyle())
        .accessibilityAddTraits(choice == value ? .isSelected : [])
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private var keepLabel: LocalizedStringKey {
        model.storageLocation?.isInternal == true ? "Keep a copy in Avo’s own storage" : "Keep the old copy"
    }

    private var existingDetail: LocalizedStringKey {
        guard let data = candidate.existing else { return "There is no Android data in this folder." }
        if let problem = candidate.problem { return "\(problem.message)" }
        let android = data.android ?? String(localized: "Android")
        let size = StoragePane.bytes(data.allocatedBytes)
        if let mac = data.lastMac, let date = data.lastUsedAt {
            return "\(android), \(size). Last used on \(mac), \(date.formatted(date: .abbreviated, time: .shortened))."
        }
        return "\(android), \(size)."
    }

    private var scope: StorageIssue.Scope {
        switch choice {
        case .move: .move
        case .existing: .existing
        case .fresh: .fresh
        }
    }

    private var shownIssues: [StorageIssue] {
        var list = candidate.issues(for: scope)
        if choice == .fresh, let issue = candidate.freshIssue(gb: size) { list.append(issue) }
        return list
    }

    @ViewBuilder private var issues: some View {
        ForEach(Array(shownIssues.enumerated()), id: \.offset) { _, issue in
            Label {
                Text(verbatim: issue.message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.severity == .error ? Haze.danger : Haze.warning)
            }
            .font(.mona(12))
        }
    }

    private var allowed: Bool {
        guard !candidate.isCurrent, !shownIssues.contains(where: { $0.severity == .error }) else { return false }
        switch choice {
        case .move: return candidate.allows(.move) || (candidate.isInternal && candidate.currentAvailable)
        case .existing: return candidate.allows(.existing)
        case .fresh: return candidate.allows(.fresh) || candidate.isInternal
        }
    }

    private var actionTitle: LocalizedStringKey {
        switch choice {
        case .move: "Move"
        case .existing: "Use This Data"
        case .fresh: "Start Fresh"
        }
    }

    @ViewBuilder private func running(_ request: StorageChangeRequest) -> some View {
        if let progress = model.storageProgress, progress.id == request.id {
            StorageProgressRow(progress: progress)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var buttons: some View {
        HStack {
            if case .newerAndroid? = candidate.problem, request == nil {
                // Download or choose the Android the data needs (Settings › Android).
                Button("Android Versions…") {
                    router.requestedSettingsPane = .android
                    openWindow(id: SettingsWindow.id)
                    dismiss()
                }
            }
            Spacer()
            if let request {
                let copying = model.storageProgress.map { $0.id == request.id && ($0.phase == .copying || $0.phase == .verifying) } ?? false
                Button("Stop") { model.cancelStorageChange() }
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 34, fontSize: 13, horizontalPadding: 18))
                    .disabled(!copying)
            } else {
                Button(failure == nil ? "Cancel" : "Close", role: .cancel) { dismiss() }
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 34, fontSize: 13, horizontalPadding: 18))
                    .keyboardShortcut(.cancelAction)
                if !candidate.isCurrent, candidate.problem.map({ if case .notPermitted = $0 { false } else { true } }) ?? true {
                    Button(actionTitle) {
                        if candidate.isInternal, candidate.existing != nil, choice != .existing {
                            confirmReplace = true
                        } else {
                            start(replacing: false)
                        }
                    }
                    .buttonStyle(HazeButtonStyle(kind: .primary, height: 34, fontSize: 13, horizontalPadding: 18))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allowed)
                }
            }
        }
    }

    private func chooseDefault() {
        if candidate.allows(.existing) {
            choice = .existing
        } else if candidate.allows(.move) || (candidate.isInternal && candidate.currentAvailable) {
            choice = .move
        } else {
            choice = .fresh
        }
        let current = model.config?.dataDiskGiB ?? 64
        size = VMConfig.dataDiskChoices.contains(current) ? current : 64
    }

    private func start(replacing: Bool) {
        let action: StorageChangeAction = switch choice {
        case .move: .move(keepOldCopy: keepOldCopy)
        case .existing: .useExisting
        case .fresh: .startFresh(gb: size)
        }
        let running = model.status.state != .stopped && model.status.state != .notInstalled && model.status.state != .failed
        let request = StorageChangeRequest(destination: candidate.isInternal ? nil : candidate.chosen, action: action,
                                           stopAndroid: running, replaceExisting: replacing)
        self.request = request
        failure = nil
        Task {
            do {
                try await model.changeStorage(request)
                dismiss()
            } catch {
                failure = error.localizedDescription
                self.request = nil
            }
        }
    }
}
