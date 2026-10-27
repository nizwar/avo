import AvoHazeUI
import AvoKit
import AvoWindowHost
import SwiftUI

// Settings › Fingerprints: the user's fingers, kept in Avo. Android's
// Settings app adds one to Android (its virtual fingerprint sensor) when it
// is touched with it, so apps' fingerprint prompts and the lock screen take a
// finger chosen in an app window's title bar (the fingerprint button). The
// daemon side is AvoDaemonCore's Fingerprints.swift.

struct FingerprintsPane: View {
    @Environment(ControlPanelModel.self) private var model
    @State private var newName = ""
    @State private var removal: Fingerprint?
    @State private var touchResult: String?

    private var status: FingerprintStatus {
        model.fingerprints ?? FingerprintStatus(availability: model.status.state == .running ? .ready : .androidStopped)
    }

    var body: some View {
        Form {
            StateSection(status: status)
            Section {
                if status.fingers.isEmpty {
                    Text("No fingers registered.").foregroundStyle(Haze.textTertiary)
                }
                ForEach(status.fingers) { finger in
                    // While Android's Settings adds a fingerprint, a touch adds that finger: one Android has is done.
                    FingerRow(finger: finger, editable: status.canEdit && !model.fingerprintsBusy,
                              canTouch: status.canTouch && !(status.enrolling && finger.enrolled),
                              remove: { removal = finger }, touch: { touch(finger.id, name: finger.name) })
                }
                if status.canEdit {
                    AddFingerRow(name: $newName, fingers: status.fingers)
                }
            } header: {
                HelpTitle("Fingers") {
                    Text("Your fingers live in Avo: add, rename or remove them any time, also while Android is off.")
                    Text("To add one to Android, open Android’s Settings app and choose Security & privacy › Device unlock › Fingerprint › Add fingerprint. When it asks for your finger, choose the finger with the fingerprint button in the window’s title bar (or Touch here). Android keeps it under the same name.")
                    Text("When an app or the lock screen asks for a fingerprint, choose a finger the same way. Android recognizes only the fingers it has, as a phone does.")
                    Text("Android takes up to \(FingerprintStatus.androidMaximum) fingerprints. Renaming one in Android’s Settings app renames it here too. Removing a finger here removes it from Android as well; removing it in Android, removing Android’s screen lock or Reset Android only takes it out of Android.")
                    Text("Apps that unlock a key with your fingerprint, as some banking apps and password managers do, see the touch but cannot use that key: Android’s virtual sensor has no secure hardware to vouch for it.")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let touchResult { Text(verbatim: touchResult) }
                    // Settings adds only Avo's fingers.
                    if status.canTouch && !status.enrolling && !status.fingers.isEmpty {
                        Button("Touch with an Unregistered Finger") { touch(nil, name: nil) }
                            .buttonStyle(HazeLinkButtonStyle())
                            .foregroundStyle(Haze.accent)
                    }
                }
                .font(.mona(12))
                .foregroundStyle(Haze.textTertiary)
            }
            if status.availability != .androidStopped, status.canEdit, !status.enrolling, status.fingers.contains(where: { !$0.enrolled }),
               let settings = model.apps.first(where: { $0.package == "com.android.settings" }) {
                Section {
                    HStack(spacing: 12) {
                        Label("Add fingers to Android in its Settings app.", systemImage: "touchid")
                            .foregroundStyle(Haze.textSecondary)
                        Spacer()
                        Button("Open Android Settings") { model.open(settings) }
                    }
                }
            }
        }
        .task(id: model.status.state) { await model.refreshFingerprints() }
        .confirmationDialog(removal.map { Text("Remove “\($0.name)”?") } ?? Text(verbatim: ""),
                            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
                            titleVisibility: .visible, presenting: removal) { finger in
            Button("Remove Finger", role: .destructive) { Task { await model.removeFingerprint(finger.id) } }
        } message: { _ in
            Text("Android forgets this fingerprint; apps and the lock screen no longer take it.")
        }
    }

    private func touch(_ id: Int?, name: String?) {
        Task {
            guard let result = await model.touchFingerprint(id) else { return }
            touchResult = Self.message(result, finger: name)
        }
    }

    static func message(_ result: FingerprintTouchResult, finger: String?) -> String {
        switch result {
        case .recognized:
            finger.map { String(localized: "Android recognized “\($0)”.") } ?? String(localized: "Android recognized the finger.")
        case .notRecognized: String(localized: "Android did not recognize that finger.")
        case .enrolled:
            finger.map { String(localized: "Android added “\($0)”.") } ?? String(localized: "Android added the fingerprint.")
        case .lockedOut: String(localized: "Too many tries: Android takes no fingerprints for now.")
        case .credentialRequired: String(localized: "Android wants its PIN, pattern or password before a fingerprint.")
        case .nobodyAsked: String(localized: "Nothing in Android is asking for a fingerprint right now.")
        case .touched: String(localized: "Touched the fingerprint sensor.")
        }
    }
}

/// Why fingers cannot be used now, and what to do about it.
private struct StateSection: View {
    @Environment(ControlPanelModel.self) private var model
    let status: FingerprintStatus

    var body: some View {
        switch status.availability {
        case .androidStopped:
            Section {
                Label("Start Android to touch its fingerprint sensor with these fingers.", systemImage: "power")
                    .foregroundStyle(Haze.textSecondary)
            }
        case .unsupported:
            Section {
                Label("This Android has no fingerprint sensor Avo can use. Fingerprints need a userdebug Android image with Android’s virtual fingerprint sensor, as Avo’s Cuttlefish images have.",
                      systemImage: "xmark.octagon")
                    .foregroundStyle(Haze.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .noScreenLock:
            Section {
                Label("Android has no screen lock yet: its Settings app asks for one when you add a fingerprint.", systemImage: "lock")
                    .foregroundStyle(Haze.textSecondary)
            }
        case .ready:
            if status.lockout != .none || status.credentialRequired || status.request != nil {
                Section {
                    if status.lockout == .timed {
                        Label("Too many tries: Android takes fingerprints again in about 30 seconds.", systemImage: "hand.raised")
                            .foregroundStyle(Haze.warning)
                    } else if status.lockout == .permanent {
                        Label("Too many tries: Android takes fingerprints again once its PIN, pattern or password is entered.", systemImage: "hand.raised")
                            .foregroundStyle(Haze.warning)
                        Button("Lock Android to Enter It") { Task { await model.lockAndroidForFingerprints() } }
                    } else if status.credentialRequired {
                        Label("Android wants its PIN, pattern or password once after it starts; fingerprints work after that.", systemImage: "lock")
                            .foregroundStyle(Haze.textSecondary)
                    } else if let request = status.request {
                        RequestLabel(request: request)
                    }
                }
            }
        }
    }
}

private struct RequestLabel: View {
    @Environment(ControlPanelModel.self) private var model
    let request: FingerprintRequest

    var body: some View {
        if request.purpose == .enroll {
            Label("Android’s Settings is adding a fingerprint: touch with the finger to add.", systemImage: "touchid")
                .foregroundStyle(Haze.accent)
        } else if request.isLockScreen {
            Label("The lock screen is asking for a fingerprint.", systemImage: "touchid")
                .foregroundStyle(Haze.accent)
        } else {
            let name = model.apps.first { $0.package == request.package }?.displayName ?? request.package
            Label("\(name) is asking for a fingerprint.", systemImage: "touchid")
                .foregroundStyle(Haze.accent)
        }
    }
}

/// A finger: its name (Return renames it), Touch and Remove.
private struct FingerRow: View {
    @Environment(ControlPanelModel.self) private var model
    let finger: Fingerprint
    let editable: Bool
    let canTouch: Bool
    let remove: () -> Void
    let touch: () -> Void
    @State private var name = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "touchid")
                    .font(.system(size: 16))
                    .foregroundStyle(finger.enrolled ? Haze.accent : Haze.textTertiary)
                    .help(finger.enrolled ? Text("Android has this finger") : Text("Not in Android yet"))
                if editable {
                    TextField("Name", text: $name)
                        .labelsHidden()
                        .hazeField()
                        .frame(maxWidth: 220)
                        .onSubmit(rename)
                } else {
                    Text(finger.name)
                }
                if !finger.enrolled {
                    Tag(text: "Not in Android", tint: Haze.textSecondary).fixedSize()
                }
                Spacer()
                Button("Touch", action: touch)
                    .disabled(!canTouch)
                    .help("Touches Android’s fingerprint sensor with this finger")
                Button(action: remove) {
                    Image(systemName: "minus.circle").foregroundStyle(Haze.textTertiary)
                }
                .buttonStyle(HazeLinkButtonStyle())
                .disabled(!editable)
                .help("Remove this finger (from Android too)")
                .accessibilityLabel(Text("Remove this finger (from Android too)"))
            }
            if let problem {
                Text(verbatim: problem).font(.mona(12)).foregroundStyle(Haze.danger)
            }
        }
        .onAppear { name = finger.name }
        .onChange(of: finger.name) { _, new in name = new }
    }

    private func rename() {
        guard name != finger.name else { return }
        switch FingerprintName.validated(name, among: model.fingerprints?.fingers ?? [], renaming: finger.id) {
        case .failure(let failure):
            problem = failure.message
        case .success(let valid):
            problem = nil
            Task { await model.renameFingerprint(finger.id, to: valid) }
        }
    }
}

/// A name (typed, or one of the ten fingers) and Add Finger.
private struct AddFingerRow: View {
    @Environment(ControlPanelModel.self) private var model
    @Binding var name: String
    let fingers: [Fingerprint]
    @State private var problem: String?

    var body: some View {
        let suggestions = FingerprintName.unusedSuggestions(among: fingers)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("New finger", text: $name, prompt: Text(verbatim: suggestions.first ?? ""))
                    .labelsHidden()
                    .hazeField()
                    .onSubmit(add)
                HazeMenuButton {
                    suggestions.map { suggestion in .item(HazeMenuItem(title: suggestion) { name = suggestion }) }
                } label: {
                    Image(systemName: "hand.raised.fingers.spread")
                        .foregroundStyle(Haze.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(suggestions.isEmpty)
                .help("Choose a finger")
                Button("Add Finger", action: add)
                    .disabled(model.fingerprintsBusy || fingers.count >= FingerprintStatus.maximumFingers)
            }
            if let problem {
                Text(verbatim: problem).font(.mona(12)).foregroundStyle(Haze.danger)
            }
        }
    }

    private func add() {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = typed.isEmpty ? (FingerprintName.unusedSuggestions(among: fingers).first ?? "") : typed
        switch FingerprintName.validated(wanted, among: fingers) {
        case .failure(let failure):
            problem = failure.message
        case .success(let valid):
            problem = nil
            Task {
                if await model.addFingerprint(named: valid) { name = "" }
            }
        }
    }
}

// MARK: - The model's calls

extension ControlPanelModel {
    func refreshFingerprints() async {
        guard let client = daemonClient else { return }
        if let status = try? await client.fingerprints(refresh: true) { fingerprints = status }
    }

    /// True when Avo took the finger.
    func addFingerprint(named name: String) async -> Bool {
        await changeFingerprints { _ = try await $0.addFingerprint(named: name) }
    }

    func renameFingerprint(_ id: Int, to name: String) async {
        await changeFingerprints { try await $0.renameFingerprint(id, to: name) }
    }

    func removeFingerprint(_ id: Int) async {
        await changeFingerprints { try await $0.removeFingerprint(id) }
    }

    func touchFingerprint(_ id: Int?) async -> FingerprintTouchResult? {
        do {
            let result = try await connectedClient().touchFingerprint(id)
            await refreshFingerprints()
            return result
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func lockAndroidForFingerprints() async {
        do {
            try await connectedClient().lockAndroidForFingerprints()
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    private func changeFingerprints(_ change: @escaping @Sendable (DaemonClient) async throws -> Void) async -> Bool {
        guard !fingerprintsBusy else { return false }
        fingerprintsBusy = true
        defer { fingerprintsBusy = false }
        do {
            try await change(connectedClient())
            await refreshFingerprints()
            return true
        } catch {
            lastError = error.localizedDescription
            await refreshFingerprints()
            return false
        }
    }
}
