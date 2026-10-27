import AppKit
import AvoKit
import AvoPackages
import SwiftUI

// Settings › Google Apps (spec: Strategi GMS, "Bring your own GApps"): the
// MindTheGapps build that fits the Android that runs, or starts next
// (GoogleAppsLine), as GitHub lists it (GoogleAppsCatalog, kept for when
// GitHub can't be asked), or a package the user chose; the daemon installs
// it as privileged system apps. When Android's version and the Google apps
// on its storage no longer match, the pane says what to do instead
// (GoogleAppsSituation).

/// The builds of a package line, the kept listing at once, then GitHub's answer.
@MainActor
@Observable
final class GoogleAppsBuildList {
    private(set) var result: GoogleAppsCatalog.Result?
    private(set) var loading = false
    @ObservationIgnored private let catalog = GoogleAppsCatalog()
    /// Bumped by each load, so an older answer does not replace a newer one.
    @ObservationIgnored private var generation = 0

    func load(_ line: GoogleAppsLine, force: Bool = false) async {
        if result?.line != line { result = catalog.cached(line).map { GoogleAppsCatalog.Result(line: line, listing: $0) } }
        generation += 1
        let mine = generation
        loading = true
        let answer = await catalog.builds(for: line, force: force)
        guard mine == generation else { return }
        loading = false
        result = answer
    }
}

/// Google apps: what Android has, the install running now, the build that
/// fits (or what to do first), and the registration Google asks for.
struct GoogleAppsSection: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(AndroidImageManager.self) private var images
    /// Reset Android's confirmation (SystemPane's).
    @Binding var confirmReset: Bool
    @State private var builds = GoogleAppsBuildList()
    @State private var pending: Source?
    @State private var showsOlder = false
    @State private var showsAdvanced = false
    @State private var confirmRemove = false
    /// Advanced: a release or package link of the user's own.
    @AppStorage("AvoGoogleAppsLink") private var customLink = ""

    private enum Source: Equatable {
        case file(URL)
        case github(String)
    }

    private var running: GoogleAppsProgress? { model.googleAppsProgress.flatMap { $0.isDone ? nil : $0 } }
    private var supported: Bool { model.googleApps?.supported ?? true }

    /// What the pane can offer now, from the Android that runs (or starts
    /// next) and the Google apps on Android's storage.
    private var situation: GoogleAppsSituation {
        let runningRelease = model.status.state == .running ? (images.booted?.release ?? images.current?.release) : nil
        return GoogleAppsSituation.decide(running: runningRelease, next: images.current?.release, record: model.googleAppsRecord,
                                          listed: model.googleApps?.installed, modeInstalled: model.config?.gms == .bringYourOwn)
    }

    /// The package line to list: the one of the Android to install for.
    private var line: GoogleAppsLine? { situation.installTarget.flatMap { GoogleAppsLine(release: $0) } }

    var body: some View {
        Section {
            // Only the rows, so the header's help stays available.
            Group { rows }
                .disabled(!supported && running == nil)
        } header: {
            HelpTitle("Google apps") {
                Text("Avo installs the MindTheGapps package for Android’s version (arm64): the newest build from MindTheGapps’ GitHub releases, which Avo checks against its SHA-256, or a .zip or unzipped folder you downloaded.")
                Text("Google apps become system apps, which turns off verified boot for Android’s system partitions. They work only with the Android version they were installed for. Reset Android removes them again.")
            }
        }
        .task(id: model.status.state) {
            images.refresh()
            await model.refreshGoogleApps()
            // Android runs, but Avo's side of it is not ready yet: ask again shortly.
            for _ in 0..<24 where model.status.state == .running && supported && model.googleApps?.installed == nil {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                await model.refreshGoogleApps()
            }
        }
        .task(id: line) {
            if let line { await builds.load(line) }
        }
        .confirmationDialog("Install Google apps?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { source in
            Button("Install Google Apps") {
                switch source {
                case .file(let url): model.installGoogleApps(from: url)
                case .github(let link): model.downloadGoogleApps(from: link)
                }
            }
        } message: { _ in
            Text("Installing Google apps turns off Android’s verified boot for the system partitions of this Avo VM, so they can hold Google’s system apps. Android restarts up to three times, and open Android apps close. If something goes wrong, Avo takes the files out again and restores Android.\n\nThis Android is an uncertified test build: before you sign in to Google, register its Android ID at google.com/android/uncertified. Avo shows the ID here once Google Play services has one. Reset Android removes Google apps again; the next install gets a new Android ID to register.")
        }
        .confirmationDialog("Remove Google apps?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Google Apps", role: .destructive) { model.removeGoogleApps() }
        } message: {
            Text("Avo takes Google apps out of Android’s system partitions and uninstalls Google Play services, the Play Store and the Google app with their data, which signs this device out of Google. Your other apps and their data stay. Android may restart, and open Android apps close.\n\nYou can then install Google apps again here. They get a new Android ID, which you register again before you sign in.")
        }
    }

    @ViewBuilder private var rows: some View {
        LabeledContent("Status") {
            StatusText(status: model.googleApps, state: model.status.state, running: running, situation: situation)
        }
        if model.verityKnownOff {
            LabeledContent {
                Text("Off")
            } label: {
                HelpTitle("Verified boot", help: "Turned off so the system partitions can hold Google apps. It stays off for this Avo VM, also after Reset Android.")
            }
        }
        if let running {
            // An install runs (from here, another Control Panel or avoctl): its progress, nothing else to start.
            GoogleAppsProgressRow(progress: running) { model.cancelGoogleApps() }
        } else {
            lastResult
            situationRows
        }
        if model.googleApps?.installed == true, running == nil {
            RegistrationRows(androidID: model.googleApps?.androidID)
            if model.status.state == .running, model.googleApps?.systemApps != false {
                LabeledContent {
                    Button("Remove Google Apps…", role: .destructive) { confirmRemove = true }
                } label: {
                    HelpTitle("Remove", help: "Takes Google apps out again and keeps your other apps and their data, for example to install them again when Google sign-in stopped working.")
                }
            }
        }
    }

    /// How the last install ended.
    @ViewBuilder private var lastResult: some View {
        if let last = model.googleAppsProgress {
            switch last.phase {
            case .failed:
                Label(last.message ?? (last.removal ? String(localized: "Google apps were not removed.") : String(localized: "Google apps were not installed.")),
                      systemImage: "xmark.octagon.fill")
                    .font(.mona(12))
                    .foregroundStyle(Haze.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            case .cancelled:
                Label(last.message ?? String(localized: "Install stopped. Android was not changed."), systemImage: "stop.circle")
                    .font(.mona(12))
                    .foregroundStyle(Haze.textTertiary)
            case .finished where last.removal && model.googleApps?.installed != true:
                Label("Google apps were removed. Your other apps and their data are still there; install Google apps again below.", systemImage: "checkmark.circle.fill")
                    .font(.mona(12))
                    .foregroundStyle(Haze.positive)
                    .fixedSize(horizontal: false, vertical: true)
            case .finished where !last.removal && model.googleApps?.installed == true:
                Label("Google apps are installed. Register this device (below) before you sign in to Google.", systemImage: "checkmark.circle.fill")
                    .font(.mona(12))
                    .foregroundStyle(Haze.positive)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var situationRows: some View {
        switch situation {
        case .canInstall(let android):
            if let line = GoogleAppsLine(release: android) {
                GoogleAppsOffer(line: line, android: android, builds: builds, showsOlder: $showsOlder,
                                install: { pending = .github($0.link) }, useFile: { chooseFile(line) })
            } else {
                // A codename: MindTheGapps names its lines by version number.
                HazeNote(symbol: "questionmark.circle", tint: Haze.warning,
                         text: Text("MindTheGapps names its packages by Android version, and \(android.name) has no number to match. Use a package made for it.")) {
                    Button("Use a File…") { chooseFile(nil) }
                }
            }
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                CustomLinkRow(link: $customLink, android: android) { pending = .github($0) }
            }
        case .restartFirst(let now, let next):
            HazeNote(symbol: "arrow.triangle.2.circlepath", tint: Haze.accent,
                     text: Text("\(next.name) starts the next time Android restarts. Restart Android first, then install Google apps for \(next.name): those for \(now.name) don’t work with it.")) {
                Button("Restart Android") { model.restartVM() }
                    .disabled(model.googleAppsChangingAndroid || model.status.state.isBusy)
            }
        case .stopsWorkingAtRestart(let installed, let next):
            HazeNote(symbol: "exclamationmark.triangle", tint: Haze.warning, text: stopText(installed: installed, next: next))
        case .leftOver(let installed, let android):
            HazeNote(symbol: "exclamationmark.triangle", tint: Haze.warning, text: leftOverText(installed: installed, android: android)) {
                Button("Reset Android…", role: .destructive) { confirmReset = true }
                    .disabled(model.googleAppsChangingAndroid)
            }
        case .noAndroid:
            HazeNote(symbol: "candybarphone", tint: Haze.textTertiary,
                     text: Text("Choose an Android version first, in Settings › Android. Avo then lists the Google apps that fit it."))
        case .installed:
            if model.status.state == .running, model.googleApps?.installed == true, model.googleApps?.systemApps == false {
                // Only Google Play's updates are left (the system files went
                // with an overlay Android no longer mounts): sign-in fails.
                HazeNote(symbol: "exclamationmark.triangle", tint: Haze.warning,
                         text: Text("Google Play services is no longer a system app: its system files are gone and only Google Play’s update of it is left, so Google sign-in fails. Remove Google apps, then install them again.")) {
                    Button("Remove Google Apps…") { confirmRemove = true }
                        .disabled(model.googleAppsChangingAndroid)
                }
            }
        case .checking:
            EmptyView()
        }
    }

    private func stopText(installed: AndroidRelease?, next: AndroidRelease) -> Text {
        if let installed {
            return Text("\(next.name) starts the next time Android restarts. These Google apps are for \(installed.name) and stop working then. To use Google Play on \(next.name), reset Android after the restart and install Google apps for it.")
        }
        return Text("\(next.name) starts the next time Android restarts, and these Google apps stop working then. To use Google Play on \(next.name), reset Android after the restart and install Google apps for it.")
    }

    private func leftOverText(installed: AndroidRelease?, android: AndroidRelease) -> Text {
        if let installed, installed.version != android.version {
            return Text("Google apps for \(installed.name) are still on Android’s storage, but they don’t work with \(android.name). Reset Android to remove them, then install Google apps for \(android.name).")
        }
        return Text("Google apps from an earlier install are still on Android’s storage, but Android doesn’t use them since its version changed. Reset Android to remove them, then install Google apps again.")
    }

    private func chooseFile(_ line: GoogleAppsLine?) {
        if let url = model.chooseGoogleAppsPackage(for: line) { pending = .file(url) }
    }

    private struct StatusText: View {
        @Environment(ControlPanelModel.self) private var model
        let status: GoogleAppsStatus?
        let state: VMState
        let running: GoogleAppsProgress?
        let situation: GoogleAppsSituation

        var body: some View {
            if let status, !status.supported {
                Text("Not available with this Android image")
            } else if let running {
                // The progress below says what is happening.
                running.removal ? Text("Removing…") : Text("Installing…")
            } else if let installed = status?.installed {
                if installed, let status {
                    Group {
                        switch (status.playStoreVersion, status.playServicesVersion) {
                        case let (store?, services?): Text("Installed (Play Store \(store), Play services \(services))")
                        case let (store?, nil): Text("Installed (Play Store \(store))")
                        default: Text("Installed")
                        }
                    }
                    .foregroundStyle(Haze.text)
                } else {
                    Text("Not installed")
                }
            } else if case .installed(let android?) = situation, state != .running {
                // Not asked while Android is stopped, but Avo knows.
                Text("Installed for \(android.name)").foregroundStyle(Haze.text)
            } else {
                switch state {
                case .starting: Text("Android is starting…")
                case .stopping: Text("Android is stopping…")
                case .running: Text("Checking…")
                default:
                    HStack(spacing: 8) {
                        Text("Start Android to see whether they are installed")
                        Button("Start Android") { model.startVM() }
                            .disabled(state.isBusy || model.daemonState != .connected)
                    }
                }
            }
        }
    }

    /// AOSP test-keys builds are uncertified: Google refuses to sign in until
    /// the GSF Android ID is registered.
    private struct RegistrationRows: View {
        @Environment(ControlPanelModel.self) private var model
        let androidID: String?

        var body: some View {
            LabeledContent("Android ID") {
                HStack(spacing: 6) {
                    if let androidID {
                        Text(verbatim: androidID)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Haze.text)
                            .textSelection(.enabled)
                        CopyButton(text: androidID)
                    } else {
                        Text("Not assigned yet")
                        if model.isRefreshingGoogleApps {
                            ProgressView().controlSize(.small)
                        } else {
                            Button {
                                Task { await model.refreshGoogleApps() }
                            } label: {
                                Image(systemName: "arrow.clockwise").foregroundStyle(Haze.textSecondary)
                            }
                            .buttonStyle(HazeLinkButtonStyle())
                            .help("Check Again")
                            .accessibilityLabel(Text("Check Again"))
                        }
                    }
                }
            }
            // Google Play services checks in minutes after Android first
            // starts online with it: keep asking until the ID is there.
            .task(id: androidID == nil) {
                guard androidID == nil else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    if Task.isCancelled { break }
                    // Each ask runs commands in Android: only while Avo shows.
                    if NSApp.occlusionState.contains(.visible) { await model.refreshGoogleApps() }
                }
            }
            // The row says to register before signing in; how, and why, is its help.
            LabeledContent {
                if let androidID {
                    Button("Copy ID and Register…") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(androidID, forType: .string)
                        NSWorkspace.shared.open(GoogleApps.registrationURL)
                    }
                    .buttonStyle(HazeButtonStyle(kind: .primary, height: 30, fontSize: 12.5, horizontalPadding: 14))
                    .help("Copies the Android ID, then opens google.com/android/uncertified.")
                } else {
                    Button("Register This Device…") { NSWorkspace.shared.open(GoogleApps.registrationURL) }
                }
            } label: {
                HelpTitle("Before signing in", help: "This Android is an uncertified test build. Register its Android ID at google.com/android/uncertified, wait a few minutes, then sign in to Google in the Play Store. Google Play services gets the ID a few minutes after Android first starts online with Google apps.")
            }
        }
    }
}

// MARK: - The build that fits

/// The newest build of the line as a card to install, older ones under it,
/// a package from a file, and where the list comes from; or why there is
/// nothing to list.
private struct GoogleAppsOffer: View {
    let line: GoogleAppsLine
    let android: AndroidRelease
    let builds: GoogleAppsBuildList
    @Binding var showsOlder: Bool
    let install: (GoogleAppsBuild) -> Void
    let useFile: () -> Void

    var body: some View {
        let result = builds.result?.line == line ? builds.result : nil
        let listing = result?.listing
        VStack(alignment: .leading, spacing: 14) {
            if let listing, let recommended = listing.recommended {
                GoogleAppsBuildCard(line: line, android: android, build: recommended, install: install)
                if let problem = result?.problem {
                    note(problem, listedAt: listing.checked)
                }
                if !listing.older.isEmpty {
                    DisclosureGroup(isExpanded: $showsOlder) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(listing.older) { build in
                                OlderBuildRow(build: build, install: install)
                            }
                        }
                    } label: {
                        Text("Older builds (\(listing.older.count))")
                    }
                }
            } else if let listing {
                // GitHub answered: no repository for this Android, or nothing in it to install.
                HazeNote(symbol: "shippingbox", tint: Haze.warning,
                         text: listing.missing
                             ? Text("MindTheGapps has no package for \(android.name) yet. Avo looks again each time you open this pane; a package you downloaded works too.")
                             : Text("MindTheGapps has no build for \(android.name) that Avo can check yet. Avo looks again each time you open this pane; a package you downloaded works too."))
                if let problem = result?.problem {
                    note(problem, listedAt: listing.checked)
                }
            } else if let problem = result?.problem {
                note(problem, listedAt: nil)
            } else {
                // The card's shape while GitHub answers, a light passing over it.
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Haze.text.opacity(0.08))
                        .frame(width: 46, height: 46)
                    Text("Looking for \(line.name) on GitHub…")
                        .font(.mona(13))
                        .foregroundStyle(Haze.textSecondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Haze.tile, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .hazeSheen(true, in: RoundedRectangle(cornerRadius: 16, style: .continuous), intensity: 0.07)
            }
            HStack(spacing: 10) {
                Button("Use a File…", action: useFile)
                    .help("A MindTheGapps .zip, or the folder it unzips to, that you downloaded yourself")
                Spacer(minLength: 8)
                Button {
                    NSWorkspace.shared.open(line.page)
                } label: {
                    Text(verbatim: "github.com/\(GoogleAppsLine.owner)/\(line.repository)")
                        .font(.mona(12))
                        .foregroundStyle(Haze.accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(HazeLinkButtonStyle())
                .help("Opens MindTheGapps’ releases for \(android.name) on GitHub")
                if builds.loading {
                    ProgressView().controlSize(.small)
                        .frame(width: 26, height: 26)
                } else {
                    Button {
                        Task { await builds.load(line, force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(HazeIconButtonStyle(size: 26, fill: Haze.text.opacity(0.06), foreground: Haze.textSecondary))
                    .help("Look for new builds on GitHub")
                    .accessibilityLabel(Text("Check Again"))
                }
            }
        }
        .animation(Haze.Motion.fade, value: listing?.builds.map(\.id))
    }

    /// Why GitHub gave no new list, and what is shown instead.
    @ViewBuilder private func note(_ problem: GoogleAppsCatalog.Problem, listedAt: Date?) -> some View {
        HazeNote(symbol: problemSymbol(problem), tint: Haze.warning, text: problemText(problem, listedAt: listedAt)) {
            if listedAt == nil {
                Button("Try Again") { Task { await builds.load(line, force: true) } }
            }
        }
    }

    private func problemSymbol(_ problem: GoogleAppsCatalog.Problem) -> String {
        switch problem {
        case .unreachable: "wifi.exclamationmark"
        case .rateLimited: "hourglass"
        case .status, .unreadable: "exclamationmark.triangle"
        }
    }

    private func problemText(_ problem: GoogleAppsCatalog.Problem, listedAt: Date?) -> Text {
        let reason: Text = switch problem {
        case .unreachable:
            Text("GitHub can’t be reached right now.")
        case .rateLimited(let until?):
            Text("GitHub limits how often this network may ask for its lists. Try again after \(until.formatted(date: .omitted, time: .shortened)).")
        case .rateLimited(nil):
            Text("GitHub limits how often this network may ask for its lists. Try again in a while.")
        case .status(let code):
            Text("GitHub answered with HTTP status \(code).")
        case .unreadable:
            Text("GitHub’s answer was not a list of releases.")
        }
        guard let listedAt else { return reason + Text(verbatim: " ") + Text("You can still install a package you downloaded.") }
        return reason + Text(verbatim: " ") + Text("These are the builds GitHub listed \(listedAt.formatted(.relative(presentation: .named))).")
    }
}

/// The build to install: its version on a tile, name, date and size, and Install.
private struct GoogleAppsBuildCard: View {
    let line: GoogleAppsLine
    let android: AndroidRelease
    let build: GoogleAppsBuild
    let install: (GoogleAppsBuild) -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack(spacing: 14) {
            // The tile turns toward the pointer and catches its light.
            VersionBadge(version: String(line.android), size: 46)
                .hazeEdgeLight(cornerRadius: 46 * 0.28, reach: 140)
                .hazeTilt(degrees: 8, reach: 160)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(verbatim: "MindTheGapps \(line.version)")
                        .font(.hubot(16, 700))
                        .foregroundStyle(Haze.text)
                        .lineLimit(1)
                    Tag(text: "Recommended", tint: Haze.accent)
                }
                Text(detail)
                    .font(.mona(12.5))
                    .foregroundStyle(Haze.purpose)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { install(build) } label: {
                Label("Install", systemImage: "arrow.down.to.line").labelStyle(HazeLabelStyle(spacing: 7, iconSize: 12))
            }
            .buttonStyle(HazeButtonStyle(kind: .primary, height: 34, fontSize: 13, horizontalPadding: 16))
            .help("Downloads \(build.file) from GitHub, checks its SHA-256 and installs it")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            ZStack {
                shape.fill(LinearGradient(colors: [Haze.accent.opacity(0.12), Haze.accent.opacity(0.03)], startPoint: .leading, endPoint: .trailing))
                shape.strokeBorder(Haze.accent.opacity(hovering ? 0.5 : 0.25))
            }
        }
        .hazeCard(hovering: hovering, cornerRadius: 16, lifts: false)
        .hazeHover($hovering)
        .accessibilityElement(children: .contain)
    }

    /// "For Android 17 (arm64) · 6 Oct 2026 · 544 MB".
    private var detail: String {
        var parts = [String(localized: "For \(android.name) (\(line.arch))")]
        if let date = build.date { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        parts.append(formatBytes(Int64(clamping: build.size)))
        return parts.joined(separator: " · ")
    }
}

/// An older build: when it came out, its size, and Install.
private struct OlderBuildRow: View {
    let build: GoogleAppsBuild
    let install: (GoogleAppsBuild) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let date = build.date {
                    Text(date, format: .dateTime.day().month(.abbreviated).year())
                } else {
                    Text(verbatim: build.tag)
                }
            }
            .foregroundStyle(Haze.text)
            .lineLimit(1)
            Text(verbatim: formatBytes(Int64(clamping: build.size)))
                .font(.mona(12))
                .foregroundStyle(Haze.textTertiary)
                .monospacedDigit()
            Spacer(minLength: 8)
            Button("Install") { install(build) }
                .help(Text(verbatim: build.file))
        }
        .font(.mona(13))
    }
}

/// Advanced: a GitHub link of the user's own, for a package Avo doesn't list.
private struct CustomLinkRow: View {
    @Binding var link: String
    let android: AndroidRelease
    let install: (String) -> Void

    var body: some View {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 8) {
            Text("A GitHub release or package link, for a package Avo doesn’t list. It must be made for \(android.name) (arm64); Avo checks it against the release’s SHA-256.")
                .font(.mona(12))
                .foregroundStyle(Haze.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("GitHub link", text: $link, prompt: Text(verbatim: "https://github.com/…/releases/…"))
                    .labelsHidden()
                    .hazeField()
                    .onSubmit { if !trimmed.isEmpty { install(trimmed) } }
                Button("Download and Install") { install(trimmed) }
                    .disabled(trimmed.isEmpty)
            }
        }
    }
}

/// The install running now: a glowing bar, what it is doing, and Stop
/// while nothing in Android has changed yet.
struct GoogleAppsProgressRow: View {
    let progress: GoogleAppsProgress
    let stop: () -> Void
    /// The bar: the whole install so far (`GoogleAppsProgress.overall`),
    /// never going back while a step without its own share runs.
    @State private var shown = 0.0
    @State private var install: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                GlowBar(fraction: shown, moving: true)
                    .accessibilityLabel(phase)
                    .accessibilityValue(Text(shown.formatted(.percent.precision(.fractionLength(0)))))
                if progress.isCancellable { Button("Stop", action: stop) }
            }
            phase
                .font(.mona(12))
                .foregroundStyle(Haze.textSecondary)
                .monospacedDigit()
            if progress.changesAndroid {
                Label("Avo restarts Android by itself. Don’t stop or reset Android until this finishes.", systemImage: "exclamationmark.triangle")
                    .font(.mona(12))
                    .foregroundStyle(Haze.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { follow(progress) }
        .onChange(of: progress) { _, new in follow(new) }
    }

    private func follow(_ progress: GoogleAppsProgress) {
        if install != progress.id {
            install = progress.id
            shown = 0
        }
        if let overall = progress.overall { shown = max(shown, overall) }
    }

    private var percent: String {
        (progress.fraction ?? 0).formatted(.percent.precision(.fractionLength(0)))
    }

    private var phase: Text {
        switch progress.phase {
        case .preparing: Text("Reading the package…")
        case .downloading: Text("Downloading from GitHub… \(percent)")
        case .verifying: Text("Checking the download’s SHA-256…")
        case .startingVM: Text("Starting Android…")
        case .disablingVerity: Text("Turning off verified boot…")
        case .restarting: progress.message.map { Text(verbatim: $0) } ?? Text("Restarting Android…")
        case .remounting: Text("Making the system partitions writable…")
        case .transferring: Text("Copying Google apps to Android… \(percent)")
        case .installing: Text("Installing Google apps as system apps…")
        case .checking: Text("Checking that Android lists Google Play…")
        case .restoring: Text("Something went wrong: taking the copied files out and restoring Android…")
        case .removing:
            (progress.fraction ?? 0) < 1 ? Text("Taking Google apps out of the system partitions…") : Text("Uninstalling what Google Play’s updates left behind…")
        case .finished, .failed, .cancelled: Text(verbatim: progress.message ?? "")
        }
    }
}
