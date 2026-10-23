import AppKit
import AVFoundation
import AvoKeymap
import AvoKit
import AvoWindowHost
import SwiftUI

// Control Panel tabs from spec §6. Changes apply immediately; the daemon
// decides whether they need a VM restart and the restart banner appears.
// The forms take their look from where they show: the Settings window's
// HazeFormStyle makes each Section a card in the haze.

private struct SettingsForm<Content: View>: View {
    @Environment(ControlPanelModel.self) private var model
    @ViewBuilder var content: (VMConfig) -> Content

    var body: some View {
        if let config = model.config {
            Form { content(config) }
        } else {
            // The cards' shapes until the settings arrive.
            HazeSkeleton(bars: [(0.3, 16), (1, 40), (1, 40), (0.36, 16), (1, 40)], spacing: 14)
                .padding(.horizontal, 34)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct IssueText: View {
    @Environment(ControlPanelModel.self) private var model
    let field: String

    var body: some View {
        if let issue = model.issue(for: field) {
            Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.mona(12))
                .foregroundStyle(issue.severity == .error ? Haze.danger : Haze.warning)
                .fixedSize(horizontal: false, vertical: true)
                .hazeRowNote()
        }
    }
}

struct RestartNote: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.mona(12))
            .foregroundStyle(Haze.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .hazeRowNote()
    }
}

/// What the Mac's screens make of the frame rate cap, under its control:
/// only when none shows it evenly (FrameRates.screenNote).
struct FrameRateNote: View {
    let cap: Int

    var body: some View {
        if let note = FrameRates.screenNote(cap: cap, screens: ScreenRefresh.attached) {
            Text(verbatim: note)
                .font(.mona(12))
                .foregroundStyle(Haze.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .hazeRowNote()
        }
    }
}

// MARK: Performa

struct PerformancePane: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        SettingsForm { config in
            let host = model.host
            Section {
                LabeledContent {
                    HStack(spacing: 12) {
                        HazeSlider(value: Binding(get: { Double(config.memoryMiB) },
                                                  set: { value in model.update { $0.memoryMiB = Int(value / 512) * 512 } }),
                                   range: Double(VMConfig.memoryRangeMiB.lowerBound)...Double(max(host.maxGuestMemoryMiB, VMConfig.memoryRangeMiB.lowerBound + 512)),
                                   step: 512)
                            .frame(width: 220)
                            .accessibilityLabel(Text("Memory"))
                        Text("\(Double(config.memoryMiB) / 1024, format: .number.precision(.fractionLength(0...1))) GB")
                            .monospacedDigit()
                            .foregroundStyle(Haze.text)
                            .frame(width: 64, alignment: .trailing)
                    }
                } label: {
                    HelpTitle("Memory", help: "Applies after Android restarts. This Mac has \(host.performanceCores) performance cores and \(host.physicalMemoryBytes / 1_073_741_824) GB of memory.")
                }
                IssueText(field: "memoryMiB")
                // The phone's own memory wins while its hardware is emulated.
                if let profile = model.profiles.first(where: { $0.id == config.deviceProfileID }),
                   config.emulateHardware, let phoneGB = profile.hardware?.memoryGB {
                    let gigabytes = DeviceSpecCard.gigabytes(config.androidMemoryMiB(profile: profile, host: host))
                    RestartNote(text: phoneGB * 1024 == config.androidMemoryMiB(profile: profile, host: host)
                        ? "While “Emulate this phone’s hardware” is on, Android gets the \(profile.name)’s \(gigabytes) GB instead."
                        : "While “Emulate this phone’s hardware” is on, Android gets \(gigabytes) GB, the most this Mac allows of the \(profile.name)’s \(phoneGB) GB.")
                }
                LabeledContent {
                    HazeStepper(value: Binding(get: { config.cpuCount }, set: { value in model.update { $0.cpuCount = value } }),
                                range: 1...host.totalCores) {
                        Text("\(config.cpuCount) of \(host.totalCores)").foregroundStyle(Haze.text)
                    }
                    .accessibilityLabel(Text("CPU cores"))
                } label: {
                    HelpTitle("CPU cores", help: "Applies after Android restarts. Up to this Mac’s performance cores keeps macOS responsive.")
                }
                IssueText(field: "cpuCount")
            }
            PauseWhenIdleSection(config: config)
            // Each further Section (or view of Sections) is a card of its own.
        }
    }
}

// MARK: Storage

struct StoragePane: View {
    @Environment(ControlPanelModel.self) private var model
    @State private var resizing = false
    @State private var confirmClearCache = false

    var body: some View {
        SettingsForm { config in
            Section {
                if model.storageLocation?.problem != nil {
                    LabeledContent("Android storage") {
                        Text("Not available").foregroundStyle(.secondary)
                    }
                } else if let disk = model.dataDisk, disk.created {
                    LabeledContent {
                        if let android = disk.android {
                            Text("\(android.settingsTotalGB) GB").monospacedDigit()
                        } else {
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: disk.diskBytes, countStyle: .decimal))
                        }
                    } label: {
                        HelpTitle("Android storage") {
                            Text("The size Android’s Settings shows. Like a phone, Android rounds its storage up to a standard size.")
                            Text("Android set it when it created its storage, and it stays: Android’s storage can change size only when it is empty, so Change Size erases Android’s data.")
                        }
                    }
                    if let android = disk.android {
                        LabeledContent("Available") {
                            Text("\(Self.bytes(android.freeBytes)) of \(Self.bytes(android.dataBytes))").monospacedDigit()
                        }
                        if android.settingsTotalGB != config.dataDiskGiB {
                            RestartNote(text: "Android created this storage before the size was \(config.dataDiskGiB) GB. Change Size erases Android’s data and creates its storage again at the size you choose.")
                        }
                    } else {
                        RestartNote(text: "Start Android to see how much of it is free.")
                    }
                    LabeledContent("Size") {
                        Button("Change Size…") { resizing = true }
                            .disabled(model.isInstallingGoogleApps)
                    }
                } else {
                    LabeledContent {
                        HazePicker("Android storage", selection: Binding(get: { config.dataDiskGiB }, set: { value in model.update { $0.dataDiskGiB = value } })) {
                            for size in Self.choices(including: config.dataDiskGiB) { HazeOption("\(size) GB", size) }
                        }
                    } label: {
                        HelpTitle("Android storage", help: "Android creates its storage at this size when it first starts, and its Settings show this size. After that the size stays: changing it erases Android’s data. The disk only takes up the space Android fills.")
                    }
                }
                IssueText(field: "dataDiskGiB")
                // Where the data is, and choosing another place (StorageLocationViews.swift).
                StorageLocationRows()
            }
            // A Mac folder Android sees as /sdcard/Avo Shared (SharedFolderViews.swift).
            SharedFolderSection()
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        if let cache = model.gpuCache {
                            Text(verbatim: Self.bytes(cache.bytes)).monospacedDigit()
                        }
                        Button("Clear GPU Cache…") { confirmClearCache = true }
                            .disabled(model.gpuCache.map { $0.bytes == 0 } ?? true)
                    }
                } label: {
                    HelpTitle("GPU shader cache", help: "Shaders that games compiled for this Mac’s GPU, kept so they start smoothly. After you clear it, the first launch of each game compiles its shaders again, so it stutters once.")
                }
            }
            .task { await model.refreshGPUCache() }
        }
        .sheet(isPresented: $resizing) { ResizeStorageSheet() }
        .confirmationDialog("Clear the GPU shader cache?", isPresented: $confirmClearCache, titleVisibility: .visible) {
            Button("Clear GPU Cache", role: .destructive) { model.clearGPUCache() }
        } message: {
            Text("The first launch of each game afterwards compiles its shaders again, so it stutters once.")
        }
    }

    /// The standard sizes, and a size an older Avo or avoctl set.
    static func choices(including current: Int) -> [Int] {
        (VMConfig.dataDiskChoices + [current]).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }.sorted()
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .decimal) }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Settings › Storage › Change Size: Android's storage can change size only
/// empty, so this erases Android's data, then sets the new size.
private struct ResizeStorageSheet: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var size = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change Android’s Storage Size")
                .font(.hubot(21, 750))
                .tracking(-0.3)
            LabeledContent {
                HazePicker("Size", selection: $size) {
                    for choice in VMConfig.dataDiskChoices { HazeOption("\(choice) GB", choice) }
                }
            } label: {
                Text("Size")
            }
            .labeledContentStyle(HazeLabeledContentStyle())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Haze.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            message
                .font(.mona(13))
                .foregroundStyle(Haze.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 34, fontSize: 13, horizontalPadding: 18))
                    .keyboardShortcut(.cancelAction)
                Button("Erase and Use \(size) GB", role: .destructive) {
                    model.eraseAndResizeStorage(to: size)
                    dismiss()
                }
                .buttonStyle(HazeButtonStyle(kind: .destructive, height: 34, fontSize: 13, horizontalPadding: 18))
            }
        }
        .padding(24)
        .frame(width: 460)
        .background { HazeSheetBackground() }
        .foregroundStyle(Haze.text)
        .tint(Haze.accent)
        .environment(\.colorScheme, .dark)
        .onAppear {
            let current = model.config?.dataDiskGiB ?? 64
            size = VMConfig.dataDiskChoices.contains(current) ? current : 64
        }
    }

    private var message: Text {
        var text = Text("Android’s storage can change size only when it is empty. All Android apps, accounts and files are erased; Avo’s settings and the Android image are kept. Android creates its storage at the new size when it next starts.")
        if model.googleAppsInstalled {
            text = text + Text(verbatim: " ") + Text("Google apps are removed too: install them again under Google apps and register the new Android ID.")
        }
        return text
    }
}

// MARK: Grafis

/// Settings › Graphics: how Android renders, the Apps and Games profiles
/// (resolution and scaling), app windows' default size and the performance HUD.
struct GraphicsPane: View {
    @Environment(ControlPanelModel.self) private var model
    /// Which profile the editor shows; not a setting.
    @State private var profile: GraphicsProfile = .apps

    /// The preset's key in the configuration (issues name their fields with it).
    private static func field(of profile: GraphicsProfile) -> String {
        switch profile {
        case .apps: "appGraphics"
        case .games: "gameGraphics"
        case .phone: "phoneGraphics"
        }
    }
    @State private var confirmResetAll = false

    var body: some View {
        SettingsForm { config in
            Section("Rendering") {
                LabeledContent {
                    HazePicker("Renderer", selection: Binding(get: { config.rendererMode }, set: { value in model.update { $0.rendererMode = value } })) {
                        HazeOption("Automatic", VMConfig.RendererMode.auto)
                        HazeOption("GPU (Metal)", VMConfig.RendererMode.gpu)
                        HazeOption("Software", VMConfig.RendererMode.software)
                    }
                } label: {
                    HelpTitle("Renderer") {
                        Text("Automatic uses this Mac’s GPU, and software rendering when the GPU cannot start.")
                        Text("Applies after Android restarts.")
                    }
                }
                RendererStatusRow()
                LabeledContent {
                    // 90 and 120 always, and a screen's own rate (75 Hz; FrameRates).
                    let rates = FrameRates.choices(for: ScreenRefresh.attached, keeping: config.fpsLimit)
                    HazeSegmented.inset(rates.map { ($0, Text(verbatim: "\($0)")) },
                                        selection: Binding(get: { config.fpsLimit },
                                                           set: { value in model.update { $0.fpsLimit = value } }))
                        .fixedSize()
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Text("Max FPS"))
                } label: {
                    HelpTitle("Max FPS", help: "Android draws at most this many frames per second, in every app. A screen’s own rate between 60 and 120 appears too, so Android runs in step with it. A rate above the one Android started at applies after a restart. 30 saves power and heat.")
                }
                FrameRateNote(cap: config.fpsLimit)
                IssueText(field: "fpsLimit")
            }
            Section {
                LabeledContent {
                    HazeSegmented.inset([(GraphicsProfile.apps, Text("Apps")), (GraphicsProfile.games, Text("Games")),
                                         (GraphicsProfile.phone, Text("Phone"))], selection: $profile)
                        .fixedSize()
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Text("Edit preset"))
                } label: {
                    HelpTitle("Edit preset", help: "The settings below are the Apps, Games or Phone preset’s. Games are apps with a key mapping, or apps you set to the Games preset on their page. Phone is for apps you set to it on their page: the phone’s own screen, at its density.")
                }
                GraphicsSettingsEditor(settings: Binding(get: { config.settings(for: profile) }, set: { value in
                    let profile = profile
                    model.update { config in
                        switch profile {
                        case .apps: config.appGraphics = value
                        case .games: config.gameGraphics = value
                        case .phone: config.phoneGraphics = value
                        }
                    }
                }), fieldPrefix: Self.field(of: profile))
                .id(profile)
                if !config.graphicsOverrides.isEmpty {
                    LabeledContent("Apps with their own settings: \(config.graphicsOverrides.count)") {
                        Button("Reset All…") { confirmResetAll = true }
                    }
                }
            } header: {
                HelpTitle("Resolution and Scaling", help: "Open windows adjust right away. Some apps reload their screen for a moment. Upscaling and sharpness change instantly.")
            }
            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        PointsField(title: "Width", value: Binding(get: { config.defaultWindowSize.width },
                                                                   set: { value in model.update { $0.defaultWindowSize.width = value } }))
                        Text(verbatim: "×")
                        PointsField(title: "Height", value: Binding(get: { config.defaultWindowSize.height },
                                                                    set: { value in model.update { $0.defaultWindowSize.height = value } }))
                        Text("points").foregroundStyle(.secondary)
                    }
                } label: {
                    HelpTitle("Default window size", help: "The size of an app’s first window, turned to the orientation under Resolution and Scaling; no restart needed. After that, each app’s window opens where and as big as you left it.")
                }
                IssueText(field: "defaultWindowSize")
                LabeledContent {
                    HazePicker("App bar style", selection: Binding(get: { config.appBarStyle }, set: { value in model.update { $0.appBarStyle = value } })) {
                        HazeOption("Standard", AppBarStyle.standard)
                        HazeOption("Phone style", AppBarStyle.phone)
                    }
                } label: {
                    HelpTitle("App bar style") {
                        HelpTerm("Standard", "A Mac window: Back, game controls, Translate Screen, Device and Quick Settings always show in its title bar.")
                        HelpTerm("Phone style", "The app’s screen alone, with a phone’s rounded corners. Its title bar shows when the pointer leaves the screen at the top.")
                        Text("Open windows change right away. An app can have its own: Phone Style in its window’s Device menu, or App bar style in its Quick Settings.")
                    }
                }
                AskBeforeQuittingRow()
            } header: {
                Text("App windows")
            }
            Section {
                LabeledContent("Show in app windows") {
                    HazePicker("Show in app windows", selection: Binding(get: { config.performanceHUD },
                                                                         set: { value in model.update { $0.performanceHUD = value } })) {
                        HazeOption("Off", PerformanceHUDLevel.off)
                        HazeOption("FPS Only", PerformanceHUDLevel.fps)
                        HazeOption("Detailed", PerformanceHUDLevel.detailed)
                    }
                }
            } header: {
                HelpTitle("Performance HUD", help: "Open windows show it right away. ⌥⌘P in an app window shows or hides it for that window. It isn't included in Avo's screenshots and screen recordings.")
            }
            Section {
                HStack(spacing: 4) {
                    Button("Use “Heavy game” preset") {
                        let host = model.host
                        model.update { $0.applyHeavyGamePreset(host: host) }
                    }
                    HelpButton("Use “Heavy game” preset", "GPU rendering at Android’s full 60 FPS, at least 8 GB of memory, and games at 720p 16:9 with MetalFX upscaling. For games like Genshin Impact, PUBG Mobile and Delta Force. The renderer and memory apply after Android restarts.")
                }
                IssueText(field: "memoryMiB")
            }
        }
        .confirmationDialog("Use the default graphics settings for all apps?", isPresented: $confirmResetAll, titleVisibility: .visible) {
            Button("Reset All") {
                for package in model.config?.graphicsOverrides.keys.sorted() ?? [] { model.setAppGraphics(nil, for: package) }
            }
        }
    }
}

/// A number field without its own label, so it fits a form row.
private struct PointsField: View {
    let title: LocalizedStringKey
    @Binding var value: Int

    var body: some View {
        TextField(title, value: $value, format: .number.grouping(.never))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .hazeField()
            .frame(width: 68)
            .help(title)
    }
}

// MARK: Sistem

struct SystemPane: View {
    @Environment(ControlPanelModel.self) private var model
    /// The sections to show: the Settings window spreads them over its panes.
    var sections: SystemSections = .all
    @State private var confirmADB = false
    @State private var confirmRoot = false
    @State private var confirmReset = false

    var body: some View {
        SettingsForm { config in
            AndroidVersionSection()
                .shown(sections.contains(.androidVersion))
            Section("Device profile") {
                LabeledContent {
                    HazePicker("Identify as", selection: Binding(get: { config.deviceProfileID },
                                                                 set: { value in model.update { $0.deviceProfileID = value } })) {
                        // Avo's honest identity first, then the phones it can impersonate.
                        let phones = model.profiles.filter { !$0.isAvoIdentity }
                        for profile in model.profiles.filter(\.isAvoIdentity) { HazeOption(verbatim: profile.name, profile.id) }
                        if !phones.isEmpty {
                            HazeSection("Impersonate a phone") {
                                for phone in phones { HazeOption(verbatim: phone.name, phone.id) }
                            }
                        }
                    }
                } label: {
                    HelpTitle("Identify as") {
                        Text("Avo tells apps what it is: a device made by Avo, model AVO-Droid, running on a Mac. Games can recognize it and treat it like a PC.")
                        Text("A phone profile is impersonation: apps read that phone’s name and model instead. It does not pass hardware attestation, so banking and DRM apps may still refuse to run. Apps that check for Avo still find it.")
                    }
                }
                // The selected profile's hardware, and the checkbox that turns
                // it on. Hidden for the honest identity, which has none.
                if let profile = model.profiles.first(where: { $0.id == config.deviceProfileID }), profile.hasHardware {
                    Toggle(isOn: Binding(get: { config.emulateHardware },
                                         set: { value in model.update { $0.emulateHardware = value } })) {
                        HelpTitle("Emulate this phone’s hardware") {
                            Text("For development: apps read this phone’s SoC, hardware name, CPU, GPU, memory and screen, so a build’s per-device code paths (a chipset or brand check) run as they would on the real phone. Android gets the phone’s memory while it is on.")
                            Text("Names and IDs change; abilities (ABI, API level, GPU features) stay this Mac’s. It does not pass hardware attestation, and Avo still identifies itself. Applies after Android restarts.")
                        }
                    }
                    if config.emulateHardware, let hardware = profile.hardware {
                        DeviceSpecCard(hardware: hardware, display: profile.display, vcpus: config.cpuCount,
                                       androidMemoryMiB: config.androidMemoryMiB(profile: profile, host: model.host))
                            .hazeRowNote()
                    }
                }
            }
            .shown(sections.contains(.identity))
            Section {
                // Read-only: the mode follows what Android has. Installing
                // Google apps sets it, Reset Android sets it back; Android
                // never reads it, so choosing one by hand would change nothing.
                LabeledContent("Mode") {
                    switch config.gms {
                    case .none: Text("None (F-Droid, Aurora Store)")
                    case .microG: Text("microG (not available yet)")
                    case .bringYourOwn: Text("Bring your own GApps")
                    }
                }
            } header: {
                HelpTitle("Google services") {
                    Text("Avo never ships Google apps. To use Google Play, install a MindTheGapps package you download yourself under Google apps below.")
                    if model.googleAppsInstalled {
                        Text("Google apps are installed. Reset Android removes them.")
                    }
                }
            }
            .shown(sections.contains(.googleApps))
            GoogleAppsSection(confirmReset: $confirmReset)
                .shown(sections.contains(.googleApps))
            Section("Network") {
                Toggle(isOn: Binding(get: { config.wifiEnabled }, set: { value in model.update { $0.wifiEnabled = value } })) {
                    HelpTitle("Wi-Fi", help: "Android reaches the internet through this Mac, over Wi-Fi. Turned off, Android is offline, as a phone with Wi-Fi off and no mobile data.")
                }
                LabeledContent {
                    HazePicker("Speed", selection: Binding(get: { config.networkSpeed }, set: { value in model.update { $0.networkSpeed = value } })) {
                        for speed in NetworkSpeed.allCases { HazeOption(verbatim: Self.title(of: speed), speed) }
                    }
                } label: {
                    HelpTitle("Network speed") {
                        Text("Slows Android’s connection down to what a mobile network of that kind usually gives, speed and delay both, to try an app on a slow connection. Full speed is this Mac’s own.")
                        Text("It applies at once, to every app; Android still says it is on Wi-Fi.")
                    }
                }
            }
            .shown(sections.contains(.network))
            Section("Mobile network") {
                Toggle(isOn: Binding(get: { config.cellularEnabled }, set: { value in model.update { $0.cellularEnabled = value } })) {
                    HelpTitle("SIM card") {
                        Text("Android gets a SIM on a simulated mobile network: the status bar shows its type and signal, apps read them, and with Wi-Fi off mobile data reaches the internet through this Mac.")
                        Text("Its speed is Network speed’s: choose the same type there for a connection as slow as the badge says.")
                    }
                }
                if config.cellularEnabled {
                    LabeledContent("Network type") {
                        HazePicker("Network type", selection: Binding(get: { config.mobileNetworkType },
                                                                       set: { value in model.update { $0.mobileNetworkType = value } })) {
                            for type in MobileNetworkType.allCases.reversed() { HazeOption(verbatim: Self.title(of: type), type) }
                        }
                    }
                    LabeledContent("Signal") {
                        HazePicker("Signal", selection: Binding(get: { config.cellularSignal }, set: { value in model.update { $0.cellularSignal = value } })) {
                            for bars in (0...4).reversed() { HazeOption(verbatim: Self.signalTitle(bars), bars) }
                        }
                    }
                }
            }
            .shown(sections.contains(.mobile))
            // Each of the Mac's devices Android may use, with a switch: off,
            // Android has no such hardware and Avo never asks macOS for it.
            Section("Bluetooth") {
                Toggle(isOn: Binding(get: { config.bluetoothEnabled }, set: { value in model.update { $0.bluetoothEnabled = value } })) {
                    HelpTitle("Bluetooth") {
                        Text("Android has Bluetooth: its apps can turn it on, scan and connect, as on a phone. The devices it finds are the ones this Mac shares, below.")
                        Text("Off, Android has no Bluetooth, and Avo never uses the Mac’s. Applies when Android restarts.")
                    }
                }
                if config.bluetoothEnabled {
                    Toggle(isOn: Binding(get: { config.shareMacBluetooth }, set: { value in model.update { $0.shareMacBluetooth = value } })) {
                        HelpTitle("Share this Mac’s Bluetooth devices") {
                            Text("While Bluetooth is on in Android, its apps find and use the Bluetooth LE devices this Mac sees: watches, sensors, beacons. macOS asks for permission the first time.")
                            Text("Headsets and other classic Bluetooth devices, and pairing, are not supported yet.")
                        }
                    }
                }
            }
            .shown(sections.contains(.bluetooth))
            Section {
                Toggle("Cameras", isOn: Binding(get: { config.camerasEnabled }, set: { value in model.update { $0.camerasEnabled = value } }))
                if config.camerasEnabled {
                    CameraPicker(title: "Back camera", selection: Binding(get: { config.backCamera },
                                                                          set: { value in model.update { $0.backCamera = value } }))
                    CameraPicker(title: "Front camera", selection: Binding(get: { config.frontCamera },
                                                                           set: { value in model.update { $0.frontCamera = value } }))
                }
                RestartNote(text: "Turning cameras on or off, or giving Android a Mac camera or no camera, applies when Android restarts; switching between cameras after that applies at once.")
            } header: {
                HelpTitle("Cameras") {
                    Text("Emulated shows a picture drawn for the camera, with no camera needed. One of this Mac’s cameras shows what it sees while an Android app uses it (its light is on only then). macOS asks for permission the first time.")
                    Text("Android apps find the back camera and the front one as on a phone. The Mac’s camera is not mirrored; apps mirror their own preview of the front one.")
                    Text("Off, Android has no camera, and Avo never uses the Mac’s.")
                }
            }
            .shown(sections.contains(.cameras))
            Section("Sound") {
                AndroidVolumeRow()
                RecordAndroidSoundRow()
            }
            .shown(sections.contains(.sound))
            Section("Microphone") {
                Toggle(isOn: Binding(get: { config.microphoneEnabled }, set: { value in model.update { $0.microphoneEnabled = value } })) {
                    HelpTitle("Microphone") {
                        Text("Android’s apps hear this Mac’s microphone while they record, like voice notes and calls. macOS asks for permission the first time.")
                        Text("Off, they record silence, and Avo never opens the microphone. Applies at once.")
                    }
                }
            }
            .shown(sections.contains(.microphone))
            Section("Location") {
                Toggle(isOn: Binding(get: { config.shareLocation }, set: { value in model.update { $0.shareLocation = value } })) {
                    HelpTitle("Share this Mac’s location with Android",
                              help: "Apps that ask for GPS get where this Mac is (as macOS knows it, usually from Wi-Fi). macOS asks for permission the first time.")
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(verbatim: LocationNames.summary(source: model.location?.source, name: model.location?.pointName,
                                                             point: model.location?.fix?.point))
                            .foregroundStyle(Haze.textSecondary)
                        Button("Choose…") { model.showLocationWindow() }
                    }
                } label: {
                    HelpTitle("All apps",
                              help: "Where Android is for every app: this Mac’s location, a place, or a route Android moves along. A place stays for the next start. Choose… shows it on a map.")
                }
                ForEach(model.location?.apps ?? [], id: \.package) { app in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(verbatim: LocationNames.summary(source: app.source, name: app.pointName, point: app.point))
                                .foregroundStyle(Haze.textSecondary)
                            Button("Use All Apps’ Location") { model.removeAppLocation(app.package) }
                        }
                    } label: {
                        Text(verbatim: model.apps.first { $0.package == app.package }?.displayName ?? app.package)
                    }
                }
                // The Location window (AvoWindowHost/LocationPanel.swift), here or in an app window.
                RestartNote(text: "To give one app a location of its own, choose Game Controls › Location… in its window (⌥⌘L), then This App. Android reports it while that app’s window is in front.")
            }
            .shown(sections.contains(.location))
            .onAppear { model.watchLocation(true) }
            .onDisappear { model.watchLocation(false) }
            Section("Clipboard") {
                Toggle(isOn: Binding(get: { config.shareClipboard }, set: { value in model.update { $0.shareClipboard = value } })) {
                    HelpTitle("Share the clipboard") {
                        Text("Text copied on the Mac can be pasted in Android, and text copied in Android on the Mac.")
                        Text("Off, Avo never reads or writes the Mac’s clipboard. Applies at once.")
                    }
                }
            }
            .shown(sections.contains(.clipboard))
            Section("Mouse and trackpad") {
                ScrollingDefaultRow()
            }
            .shown(sections.contains(.scrolling))
            MacNotificationsSection()
                .shown(sections.contains(.notifications))
            Section("Developer") {
                // What ADB support exposes is said again before it turns on.
                Toggle(isOn: Binding(get: { config.adbEnabled }, set: { value in
                    if value { confirmADB = true } else { model.update { $0.adbEnabled = false } }
                })) {
                    HelpTitle("ADB support") {
                        Text("Lets adb, Android Studio or scrcpy on this Mac control Android. Only this Mac can connect, but any app on it can then install apps and read Android’s data, so turn it off when you don’t need it.")
                        if let adb = model.snapshot?.adb, adb.problem == nil, adb.port == VMConfig.defaultADBPort {
                            Text("adb also finds Android by itself, as emulator-5554, while it runs.")
                        }
                    }
                }
                if config.adbEnabled {
                    LabeledContent("Port") {
                        PointsField(title: "Port", value: Binding(get: { config.adbPort }, set: { value in model.update { $0.adbPort = value } }))
                    }
                    IssueText(field: "adbPort")
                    ADBStatusRow()
                }
                // Magisk (MagiskRoot in the daemon); what it costs is said again before it turns on.
                Toggle(isOn: Binding(get: { config.rooted }, set: { value in
                    if value { confirmRoot = true } else { model.update { $0.rooted = false } }
                })) {
                    HelpTitle("Root access (Magisk)") {
                        Text("Apps can ask for root, and Magisk asks you about each one. Avo downloads Magisk from its GitHub page, adds it to Android’s boot ramdisk and starts Android again with it. Android’s data stays as it is.")
                        Text("Apps that check the device’s integrity (banking, payments, some games) may refuse to run while Android is rooted. Turned off, Android starts without Magisk the next time.")
                    }
                }
            }
            .shown(sections.contains(.developer))
            Section("Shortcuts") {
                // Both apply to every app at once, and to apps installed later.
                Toggle(isOn: Binding(get: { config.createDesktopAlias }, set: { value in model.update { $0.createDesktopAlias = value } })) {
                    HelpTitle("Aliases on the Desktop", help: "Each Android app gets an alias on the Desktop. Turning this off removes Avo’s aliases; turning it on adds one for every app, and for apps you install later.")
                }
                Toggle(isOn: Binding(get: { config.addToDock }, set: { value in model.update { $0.addToDock = value } })) {
                    HelpTitle("Apps in the Dock", help: "Each Android app gets a tile in the Dock. Turning this off removes Avo’s tiles; turning it on adds one for every app, and for apps you install later.")
                }
                LabeledContent {
                    Button("Recreate Shortcuts") { model.recreateShortcuts() }
                } label: {
                    HelpTitle("App shortcuts", help: "Makes every app’s Mac app, icon, alias and Dock tile again, for example after moving Avo.")
                }
            }
            .shown(sections.contains(.shortcuts))
            Section("Translate Screen") {
                // One engine in the daemon for every app (ScreenTextEngine).
                Toggle(isOn: Binding(get: { config.translationAtStartup }, set: { value in model.update { $0.translationAtStartup = value } })) {
                    HelpTitle("Start the translation engine with Avo") {
                        Text("Translate Screen (⇧⌘T in an app window) reads the text on screen and translates it on this Mac. One engine does it for every app.")
                        Text("On, the engine gets ready as Avo starts, so the first translation in any app shows at once. Off, it starts when an app first translates, and the apps after it use the same engine.")
                    }
                }
                TranslateIntoRow()
            }
            .shown(sections.contains(.translation))
            CheckpointsSection()
                .shown(sections.contains(.checkpoints))
            Section("Maintenance") {
                Button("Reset Android…", role: .destructive) { confirmReset = true }
                    .disabled(model.isInstallingGoogleApps)
                if model.isInstallingGoogleApps {
                    RestartNote(text: "Available again when Avo finishes changing Google apps.")
                }
            }
            .shown(sections.contains(.maintenance))
        }
        .confirmationDialog("Turn on ADB support?", isPresented: $confirmADB, titleVisibility: .visible) {
            Button("Turn On ADB Support") { model.update { $0.adbEnabled = true } }
        } message: {
            Text("Lets adb, Android Studio or scrcpy on this Mac control Android. Only this Mac can connect, but any app on it can then install apps and read Android’s data, so turn it off when you don’t need it.")
        }
        .confirmationDialog("Turn on root access?", isPresented: $confirmRoot, titleVisibility: .visible) {
            Button("Turn On Root") { model.update { $0.rooted = true } }
        } message: {
            Text("Avo downloads Magisk from GitHub and starts Android again with it. Apps that check the device’s integrity (banking, payments, some games) may refuse to run while Android is rooted.")
        }
        .confirmationDialog("Reset Android?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Erase All Apps and Data", role: .destructive) { model.resetAndroid() }
        } message: {
            resetMessage
        }
    }

    /// A mobile network type as Settings › Devices lists it, by its status bar badge.
    static func title(of type: MobileNetworkType) -> String {
        switch type {
        case .nr: "5G"
        case .lte: String(localized: "4G LTE")
        case .hspa: String(localized: "3G (HSPA)")
        case .umts: String(localized: "3G (UMTS)")
        case .edge: String(localized: "E (EDGE)")
        case .gprs: String(localized: "G (GPRS)")
        }
    }

    static func signalTitle(_ bars: Int) -> String {
        switch bars {
        case 0: String(localized: "No signal")
        case 4: String(localized: "4 bars (full)")
        default: String(localized: "\(bars) bars")
        }
    }

    /// A network speed as Settings › Devices lists it, with its download speed.
    static func title(of speed: NetworkSpeed) -> String {
        switch speed {
        case .full: String(localized: "Full speed")
        case .nr: String(localized: "5G · 200 Mbit/s")
        case .lte: String(localized: "4G LTE · 30 Mbit/s")
        case .hspa: String(localized: "H+ · 7.2 Mbit/s")
        case .umts: String(localized: "3G · 1.9 Mbit/s")
        case .edge: String(localized: "E (EDGE) · 237 kbit/s")
        case .gprs: String(localized: "G (GPRS) · 80 kbit/s")
        }
    }

    /// What Reset Android takes away: Google apps live on the data disk too,
    /// with an Android ID of their own; verified boot stays as it is.
    private var resetMessage: Text {
        var text = Text("All Android apps, accounts and files are erased. Avo’s settings and the Android image are kept.")
        if model.googleAppsInstalled {
            text = text + Text(verbatim: " ")
                + Text("Google apps are removed too: install them again under Google apps and register the new Android ID.")
        }
        if model.verityKnownOff {
            text = text + Text(verbatim: " ") + Text("Verified boot stays off.")
        }
        if model.fingerprints?.fingers.contains(where: \.enrolled) ?? false {
            text = text + Text(verbatim: " ") + Text("Android forgets its fingerprints; your fingers stay in Settings › Fingerprints, to add again.")
        }
        if !(model.checkpoints?.checkpoints.isEmpty ?? true) {
            text = text + Text(verbatim: " ") + Text("Its checkpoints are erased too.")
        }
        return text
    }
}

/// SystemPane's sections, for the Settings window's panes.
struct SystemSections: OptionSet {
    let rawValue: Int

    static let androidVersion = SystemSections(rawValue: 1 << 0)
    static let identity = SystemSections(rawValue: 1 << 2)
    static let googleApps = SystemSections(rawValue: 1 << 3)
    static let location = SystemSections(rawValue: 1 << 4)
    static let notifications = SystemSections(rawValue: 1 << 5)
    static let developer = SystemSections(rawValue: 1 << 6)
    static let shortcuts = SystemSections(rawValue: 1 << 7)
    static let maintenance = SystemSections(rawValue: 1 << 8)
    static let network = SystemSections(rawValue: 1 << 9)
    static let bluetooth = SystemSections(rawValue: 1 << 10)
    static let mobile = SystemSections(rawValue: 1 << 11)
    static let cameras = SystemSections(rawValue: 1 << 12)
    static let microphone = SystemSections(rawValue: 1 << 13)
    static let clipboard = SystemSections(rawValue: 1 << 14)
    static let translation = SystemSections(rawValue: 1 << 15)
    static let sound = SystemSections(rawValue: 1 << 16)
    static let scrolling = SystemSections(rawValue: 1 << 17)
    static let checkpoints = SystemSections(rawValue: 1 << 18)
    static let all = SystemSections(rawValue: (1 << 19) - 1)
}

/// Android's media volume, every app's: a slider while Android runs (also
/// in an app window's Quick Settings).
private struct AndroidVolumeRow: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        LabeledContent {
            if let volume = model.androidVolume {
                HStack(spacing: 12) {
                    HazeSlider(value: Binding(get: { Double(volume.level) }, set: { model.setAndroidVolume(Int($0.rounded())) }),
                               range: 0...Double(volume.maximum), step: 1)
                        .frame(width: 220)
                        .accessibilityLabel(Text("Android volume"))
                    Text(Double(volume.level) / Double(max(volume.maximum, 1)), format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(Haze.text)
                        .frame(width: 48, alignment: .trailing)
                }
            } else {
                Text("Available while Android is running")
                    .foregroundStyle(Haze.textTertiary)
            }
        } label: {
            HelpTitle("Android volume", help: "How loud Android plays, in every app, under your Mac’s volume. At 100%, your Mac’s volume alone sets how loud Android is, as with other Mac apps.")
        }
        .task(id: model.status.state) { await model.loadAndroidVolume() }
    }
}

// Every app's settings that app windows also change (File › Record Android’s
// Sound, Translate Into, Game Controls › Scrolling › Default for All Apps): kept in
// the Window Host's defaults, which every App Shim reads.

/// Whether screen recordings take Android's sound (CaptureSettings).
private struct RecordAndroidSoundRow: View {
    @AppStorage(CaptureSettings.recordSoundKey, store: UserDefaults(suiteName: AvoIdentifiers.windowHost))
    private var recordsSound = true

    var body: some View {
        Toggle(isOn: $recordsSound) {
            HelpTitle("Record Android’s sound", help: "Screen recordings made in app windows (⇧⌘R) include what Android plays. Off, they have no sound. File › Record Android’s Sound in an app window changes it too.")
        }
    }
}

/// Whether closing a game's window asks first (QuitSettings; its Don't Ask
/// Again turns this off).
private struct AskBeforeQuittingRow: View {
    @AppStorage(QuitSettings.askKey, store: UserDefaults(suiteName: AvoIdentifiers.windowHost))
    private var asks = true

    var body: some View {
        Toggle(isOn: $asks) {
            HelpTitle("Ask before quitting a game", help: "The red button and Picture in Picture’s ✕ end the game in Android. Avo asks first, so one wrong click doesn’t end a match, and offers Run in Background instead.")
        }
    }
}

/// The language Translate Screen translates into, in every app.
private struct TranslateIntoRow: View {
    @State private var languages: [TranslateIntoChoice.Language] = []
    @State private var chosen = TranslateIntoChoice.chosen
    @State private var systemLanguage = TranslateIntoChoice.systemLanguageName

    var body: some View {
        LabeledContent {
            HazePicker("Translate into", selection: Binding(get: { chosen }, set: { value in
                chosen = value
                TranslateIntoChoice.chosen = value
            })) {
                HazeOption(verbatim: String(localized: "System Language (\(systemLanguage))"), String?.none)
                for language in languages { HazeOption(verbatim: language.name, Optional(language.identifier)) }
                // A choice macOS no longer lists still shows as chosen.
                if let chosen, !languages.contains(where: { $0.identifier == chosen }) {
                    HazeOption(verbatim: Locale.current.localizedString(forIdentifier: chosen) ?? chosen, Optional(chosen))
                }
            }
        } label: {
            HelpTitle("Translate into", help: "The language Translate Screen shows the text in, in every app. View › Translate Into and Quick Settings in an app window change it too.")
        }
        .task {
            // Every language, once macOS has said which it has.
            languages = await TranslateIntoChoice.languages()
            chosen = TranslateIntoChoice.chosen
            systemLanguage = TranslateIntoChoice.systemLanguageName
        }
    }
}

/// How the mouse wheel and the trackpad scroll apps without a choice of their own.
private struct ScrollingDefaultRow: View {
    @AppStorage(ScrollModeSettings.defaultKey, store: UserDefaults(suiteName: AvoIdentifiers.windowHost))
    private var stored = ScrollMode.automatic.rawValue

    var body: some View {
        LabeledContent {
            HazePicker("Scrolling", selection: Binding(get: { ScrollMode(rawValue: stored) ?? .automatic },
                                                      set: { ScrollingDefaultChoice.mode = $0 })) {
                for mode in ScrollMode.allCases { HazeOption(verbatim: ScrollingDefaultChoice.name(of: mode), mode) }
            }
        } label: {
            HelpTitle("Scrolling") {
                ForEach(ScrollMode.allCases, id: \.self) { mode in
                    Text(verbatim: "\(ScrollingDefaultChoice.name(of: mode)): \(ScrollingDefaultChoice.explanation(of: mode)).")
                }
                Text("Every app scrolls this way unless it has its own choice: Scrolling in its window’s Quick Settings or Game Controls menu.")
            }
        }
    }
}

extension View {
    /// This section, or nothing.
    @ViewBuilder func shown(_ visible: Bool) -> some View {
        if visible { self }
    }
}

/// How to reach Android once ADB support is on (or why it cannot listen);
/// that adb also finds it as emulator-5554 is in ADB support's help.
private struct ADBStatusRow: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        if let adb = model.snapshot?.adb {
            if let problem = adb.problem {
                Label(problem, systemImage: "xmark.octagon.fill")
                    .font(.mona(12))
                    .foregroundStyle(Haze.danger)
                    .hazeRowNote()
            } else {
                LabeledContent("Connect with") {
                    HStack(spacing: 6) {
                        Text(verbatim: adb.connectCommand)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Haze.text)
                            .textSelection(.enabled)
                        CopyButton(text: adb.connectCommand)
                    }
                }
            }
        }
    }
}

/// Copies `text`, showing a checkmark for a moment.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(copied ? Haze.running : Haze.textSecondary)
        }
        .buttonStyle(HazeLinkButtonStyle())
        .help(copied ? Text("Copied") : Text("Copy"))
    }
}

/// One of Android's cameras (CameraSource): emulated, none, or one of this
/// Mac's cameras, which come and go as they are plugged in. A chosen camera
/// that is not connected stays chosen (CameraFeed then uses the Mac's
/// default camera).
struct CameraPicker: View {
    let title: LocalizedStringKey
    @Binding var selection: CameraSource
    @State private var cameras = Self.macCameras()

    var body: some View {
        LabeledContent(title) {
            HazePicker(title, selection: $selection) {
                HazeOption("Emulated", CameraSource.emulated)
                HazeOption("None", CameraSource.none)
                HazeSection("This Mac") {
                    for camera in cameras { HazeOption(verbatim: camera.name, CameraSource.mac(camera.uniqueID)) }
                    if let id = selection.macCameraID, !cameras.contains(where: { $0.uniqueID == id }) {
                        HazeOption("Not connected", selection)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in cameras = Self.macCameras() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in cameras = Self.macCameras() }
    }

    /// The Mac's cameras, built in, plugged in and Continuity (an iPhone).
    static func macCameras() -> [(uniqueID: String, name: String)] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified)
            .devices.map { ($0.uniqueID, $0.localizedName) }
    }
}

/// A location as Settings names it.
enum LocationNames {
    static func summary(source: LocationStatus.Source?, name: String?, point: GeoPoint?) -> String {
        switch source {
        case .mac?, nil: return String(localized: "This Mac’s location")
        case .route?: return name.map { String(localized: "Route: \($0)") } ?? String(localized: "A route")
        case .point?:
            if let name { return name }
            guard let point else { return String(localized: "A chosen place") }
            return String(format: "%.5f, %.5f", point.latitude, point.longitude)
        }
    }
}

extension ControlPanelModel {
    /// Settings › Devices › Location or its Location window shows (every
    /// change comes as `DaemonEvent.location` while one does) or not.
    func watchLocation(_ on: Bool) {
        locationWatchers = max(locationWatchers + (on ? 1 : -1), 0)
        guard let client = daemonClient else { return }
        let watching = locationWatchers > 0
        Task { @MainActor in
            if let status = try? await client.location(watch: watching), watching { location = status }
        }
    }

    /// Settings › Devices › Location › Choose…: every app's location, on a map.
    func showLocationWindow() {
        ControlPanelLocationWindow.show()
    }

    /// The app uses every app's location again.
    func removeAppLocation(_ package: String) {
        guard let client = daemonClient else { return }
        Task { @MainActor in
            if let status = try? await client.changeLocation(.removeApp(package)) { location = status }
        }
    }
}
