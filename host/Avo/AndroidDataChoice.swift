import AppKit
import AvoKit
import AvoPackages
import SwiftUI

// Each Android version keeps its own data. Changing to another version asks
// which data it uses: the data that version used before, Android data in
// another folder, or new data in an empty folder (an upgrade may also take
// the current data along). The data left behind stays where it is, untouched,
// to come back to.

/// A place with Android data that Avo has used, remembered by the Control
/// Panel so that changing versions can offer each version's data again.
struct RememberedAndroidData: Codable, Hashable, Identifiable {
    /// The data folder; nil for Avo's own storage.
    var path: String?
    /// The newest Android that used the data.
    var sdk: Int
    var android: String
    var lastSeen: Date

    var id: String { path ?? "internal" }
}

/// The places with Android data, kept in the Control Panel's defaults.
@MainActor
enum AndroidDataMemory {
    static let key = "AvoAndroidDataPlaces"

    static func all(_ defaults: UserDefaults = .standard) -> [RememberedAndroidData] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RememberedAndroidData].self, from: data)) ?? []
    }

    /// The data in use now and the copy in Avo's own storage, as the daemon
    /// reports them. A place whose data moved to a newer Android is updated.
    static func note(_ status: StorageLocationStatus, defaults: UserDefaults = .standard, now: Date = Date()) {
        var places = all(defaults)
        func upsert(_ path: String?, _ summary: AndroidDataSummary?) {
            guard let summary, let sdk = summary.sdk else { return }
            let place = RememberedAndroidData(path: path, sdk: sdk, android: summary.android ?? "Android \(sdk)", lastSeen: now)
            places.removeAll { $0.id == place.id }
            places.append(place)
        }
        if status.problem == nil { upsert(status.isInternal ? nil : status.path, status.data) }
        if !status.isInternal { upsert(nil, status.internalCopy) }
        save(places, defaults)
    }

    static func forget(_ place: RememberedAndroidData, defaults: UserDefaults = .standard) {
        save(all(defaults).filter { $0.id != place.id }, defaults)
    }

    /// The places whose data `release` can use as it is (the same API level),
    /// most recently seen first, without the place in use now.
    static func places(for release: AndroidRelease, excluding current: StorageLocationStatus?,
                       defaults: UserDefaults = .standard) -> [RememberedAndroidData] {
        let currentID = current.map { $0.isInternal ? "internal" : $0.path }
        return all(defaults).filter { $0.sdk == release.sdk && $0.id != currentID }.sorted { $0.lastSeen > $1.lastSeen }
    }

    private static func save(_ places: [RememberedAndroidData], _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(places) { defaults.set(data, forKey: key) }
    }
}

/// What the chosen version uses as its data.
enum AndroidDataPlan: Equatable {
    /// The current data goes along (an upgrade).
    case keep
    /// Another place, by the daemon's storage change (use the data there, or start fresh).
    case change(StorageChangeRequest)
}

/// Which data the chosen Android version uses.
struct AndroidDataSheet: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(AndroidImageManager.self) private var images
    @Environment(\.dismiss) private var dismiss
    let change: AndroidVersionChange
    /// After the choice is made (the Setup Assistant goes on).
    var done: () -> Void = {}

    enum Choice: Hashable {
        case keep
        case remembered(String)
        case existing
        case fresh
    }

    @State private var choice: Choice?
    @State private var existing: StorageCandidate?
    @State private var fresh: StorageCandidate?
    @State private var size = 64
    @State private var inspecting = false
    @State private var working = false
    @State private var failure: String?

    private var target: AndroidRelease? { change.row.release }
    private var remembered: [RememberedAndroidData] {
        target.map { AndroidDataMemory.places(for: $0, excluding: model.storageLocation) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Android Data for \(change.row.name)")
                .font(.hubot(21, 750))
                .tracking(-0.3)
            Text(intro)
                .font(.mona(13))
                .foregroundStyle(Haze.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if change.change == .upgrade {
                        option(.keep, title: "Upgrade the current data",
                               detail: String(localized: "Apps and data go along to \(change.row.name). \(change.currentName ?? String(localized: "The older Android")) can’t use them afterwards."))
                    }
                    ForEach(remembered) { place in
                        option(.remembered(place.id), title: "\(place.android) data in \(Self.placeName(place.path))",
                               detail: String(localized: "Last used \(place.lastSeen.formatted(date: .abbreviated, time: .shortened))."))
                    }
                    option(.existing, title: "Use Android data in another folder", detail: existingDetail) {
                        Button("Choose…") { choose(.existing) }
                    }
                    option(.fresh, title: "Start new data in a folder", detail: freshDetail) {
                        Button("Choose…") { choose(.fresh) }
                    }
                    if choice == .fresh, fresh != nil {
                        HStack(spacing: 10) {
                            Text("Size")
                            HazePicker("Size", selection: $size) {
                                for choice in VMConfig.dataDiskChoices { HazeOption("\(choice) GB", choice) }
                            }
                        }
                        .padding(.leading, 24)
                    }
                }
                .padding(2)
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            if let googleApps = googleAppsNote {
                Label(googleApps, systemImage: "g.circle").font(.mona(12)).foregroundStyle(Haze.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if running {
                Label("Android stops first; open apps close.", systemImage: "stop.circle")
                    .font(.mona(12)).foregroundStyle(Haze.textTertiary)
            }
            if working, let progress = model.storageProgress, !progress.isDone {
                Text(StorageProgressText.text(progress)).font(.mona(12)).foregroundStyle(Haze.textSecondary)
            }
            if let failure {
                Label { Text(verbatim: failure) } icon: { Image(systemName: "xmark.octagon.fill").foregroundStyle(Haze.danger) }
                    .font(.mona(13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 34, fontSize: 13, horizontalPadding: 18))
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button(primaryLabel) { confirm() }
                    .buttonStyle(HazeButtonStyle(kind: .primary, height: 34, fontSize: 13, horizontalPadding: 18))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready || working || inspecting)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background { HazeSheetBackground() }
        .hazeFormControls()
        .environment(\.colorScheme, .dark)
        .onAppear {
            if choice == nil {
                choice = remembered.first.map { .remembered($0.id) } ?? (change.change == .upgrade ? .keep : nil)
            }
            let current = model.config?.dataDiskGiB ?? 64
            size = VMConfig.dataDiskChoices.contains(current) ? current : 64
        }
    }

    // MARK: Words

    private var intro: String {
        let place = model.storageLocation.map { Self.placeName($0.isInternal ? nil : $0.path) } ?? String(localized: "Avo’s own storage")
        let name = change.currentName ?? String(localized: "Android")
        return String(localized: "Each Android version keeps its own data. Your \(name) data stays in \(place), as it is, for when you switch back.")
    }

    static func placeName(_ path: String?) -> String {
        guard let path else { return String(localized: "Avo’s own storage") }
        return StoragePane.abbreviated(path)
    }

    private var existingDetail: String {
        guard let existing else {
            return String(localized: "A folder with Android data from \(change.row.name) or an older Android, for example from another Mac.")
        }
        let place = StoragePane.abbreviated(existing.folder)
        if let problem = existingProblem(existing) { return "\(place): \(problem)" }
        let android = existing.existing?.android ?? String(localized: "Android")
        return String(localized: "\(place): \(android) data, \(StoragePane.bytes(existing.existing?.allocatedBytes ?? 0)).")
    }

    private var freshDetail: String {
        guard let fresh else { return String(localized: "Android starts empty there, like a new phone. Choose an empty folder.") }
        let place = StoragePane.abbreviated(fresh.folder)
        if let problem = freshProblem(fresh) { return "\(place): \(problem)" }
        return String(localized: "\(place): Android starts empty there, like a new phone.")
    }

    private var googleAppsNote: String? {
        guard change.googleAppsMismatch else { return nil }
        return String(localized: "Google apps must match the Android version: install them for \(change.row.name) once it runs.")
    }

    private var primaryLabel: String {
        change.row.image == nil ? String(localized: "Download and Use") : String(localized: "Use \(change.row.name)")
    }

    private var running: Bool {
        let state = model.status.state
        return state != .stopped && state != .notInstalled && state != .failed
    }

    // MARK: Checks

    /// Why the data in `candidate` will not do for the chosen version.
    private func existingProblem(_ candidate: StorageCandidate) -> String? {
        if case .notPermitted? = candidate.problem { return candidate.problem?.message }
        guard let data = candidate.existing else { return String(localized: "There is no Android data in this folder.") }
        if candidate.isCurrent { return String(localized: "This is the data Android uses now.") }
        if let error = candidate.issues(for: .existing).first(where: { $0.severity == .error }) { return error.message }
        if let sdk = data.sdk, let target, sdk > target.sdk {
            return String(localized: "\(data.android ?? "Its Android") is newer than \(change.row.name), which can’t use its data.")
        }
        if let problem = candidate.problem, !candidate.existingNeedsNewerAndroid { return problem.message }
        return nil
    }

    private func freshProblem(_ candidate: StorageCandidate) -> String? {
        if case .notPermitted? = candidate.problem { return candidate.problem?.message }
        if candidate.existing != nil { return String(localized: "This folder has Android data already: use it, or choose an empty folder.") }
        if let error = candidate.issues(for: .fresh).first(where: { $0.severity == .error }) { return error.message }
        if let issue = candidate.freshIssue(gb: size), issue.severity == .error { return issue.message }
        guard candidate.allows(.fresh), !candidate.isInternal else { return String(localized: "Android can’t start fresh there.") }
        return nil
    }

    private var ready: Bool {
        switch choice {
        case .keep?: true
        case .remembered?: true
        case .existing?: existing.map { existingProblem($0) == nil } ?? false
        case .fresh?: fresh.map { freshProblem($0) == nil } ?? false
        case nil: false
        }
    }

    // MARK: Actions

    private func choose(_ kind: Choice) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = kind == .fresh
            ? String(localized: "Choose an empty folder for \(change.row.name)’s data, for example on an external drive.")
            : String(localized: "Choose the folder with the Android data to use (a folder named “Avo Android Data”, or the folder that holds it).")
        guard panel.runModal() == .OK, let url = panel.url,
              StorageLocationFlow.explainRemovableVolume(url), StorageLocationFlow.explainProtectedFolder(url) else { return }
        choice = kind
        inspecting = true
        failure = nil
        Task {
            defer { inspecting = false }
            do {
                let candidate = try await model.inspectStorage(url.path)
                if kind == .fresh { fresh = candidate } else { existing = candidate }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func option<Accessory: View>(_ value: Choice, title: LocalizedStringKey, detail: String,
                                         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let selected = choice == value
        return HStack(alignment: .center, spacing: 10) {
            Button {
                choice = value
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Haze.accent : Haze.textTertiary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.mona(13.5, 600)).foregroundStyle(Haze.text)
                        Text(verbatim: detail).font(.mona(12)).foregroundStyle(Haze.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(HazeCardButtonStyle())
            .accessibilityAddTraits(selected ? .isSelected : [])
            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(selected ? Haze.selection : Haze.tile, in: shape)
        .overlay { shape.strokeBorder(selected ? Haze.accent.opacity(0.5) : Haze.text.opacity(0.05)) }
        .animation(Haze.Motion.hover, value: choice)
    }

    private func confirm() {
        guard let choice else { return }
        failure = nil
        switch choice {
        case .keep:
            finish(.keep)
        case .existing:
            guard let existing else { return }
            finish(.change(request(existing, action: .useExisting)))
        case .fresh:
            guard let fresh else { return }
            finish(.change(request(fresh, action: .startFresh(gb: size))))
        case .remembered(let id):
            guard let place = remembered.first(where: { $0.id == id }) else { return }
            inspecting = true
            Task {
                defer { inspecting = false }
                do {
                    // Looked at again: the drive may be gone, or the data changed meanwhile.
                    let candidate = try await model.inspectStorage(place.path)
                    if let problem = existingProblem(candidate) {
                        failure = problem
                        if candidate.existing == nil { AndroidDataMemory.forget(place) }
                        return
                    }
                    finish(.change(request(candidate, action: .useExisting)))
                } catch {
                    failure = error.localizedDescription
                }
            }
        }
    }

    private func request(_ candidate: StorageCandidate, action: StorageChangeAction) -> StorageChangeRequest {
        // Android stops for the change (also when it started while a download ran).
        StorageChangeRequest(destination: candidate.isInternal ? nil : candidate.chosen, action: action, stopAndroid: true)
    }

    private func finish(_ plan: AndroidDataPlan) {
        // A version to download first: the data changes once it is there.
        guard change.row.image != nil else {
            images.apply(change, data: plan, model: model)
            dismiss()
            done()
            return
        }
        working = true
        Task {
            defer { working = false }
            if await images.switchTo(change, data: plan, model: model) {
                dismiss()
                done()
            } else {
                failure = images.problem
            }
        }
    }
}
