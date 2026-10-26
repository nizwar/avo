import AppKit
import AvoKit
import AvoPackages
import SwiftUI

/// The Setup Assistant: shown on a first launch and whenever no Android image
/// is installed; Help › Setup Assistant… opens it again. Welcome, Android
/// version, permissions, Google apps (optional), then it starts Android.
@MainActor
@Observable
final class SetupAssistant {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, android, permissions, googleApps, ready

        var id: Int { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .welcome: "Welcome"
            case .android: "Android Version"
            case .permissions: "Permissions"
            case .googleApps: "Google Apps"
            case .ready: "Ready"
            }
        }
    }

    var isPresented = false
    /// Its window is on screen (SetupWindow): asking to show stops there.
    var windowOpen = false
    var step: Step = .welcome
    var selection: AndroidVersionRow.ID?
    /// Settings › Google Apps opens when the assistant closes (Google apps step).
    var openGoogleAppsSettings = false
    /// The assistant started Android once (the Ready step does it by itself).
    var startedAndroid = false
    /// Android has no data yet: its first start sets itself up (Ready says so).
    var firstStart = false
    /// Android's data from another Mac, used where it is (SetupCarriedData.swift).
    var carriedData: CarriedAndroidData?

    static let completedKey = "AvoSetupAssistantCompleted"

    /// On launch: a first launch (never completed, and Android never ran), or no image to start.
    func presentIfNeeded(images: AndroidImageManager, paths: AvoPaths = AvoPaths()) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "AvoSkipSetupAssistant") { return }
        // Android's data in a folder of its own (an external drive, maybe not connected) is not a first launch.
        let firstLaunch = !defaults.bool(forKey: Self.completedKey) && !FileManager.default.fileExists(atPath: paths.dataDisk.path)
            && paths.isDataInternal
        if firstLaunch || images.needsImage { show(paths: paths) }
    }

    func show(paths: AvoPaths = AvoPaths()) {
        step = .welcome
        startedAndroid = false
        carriedData = nil
        firstStart = !FileManager.default.fileExists(atPath: paths.dataDisk.path) && FileManager.default.fileExists(atPath: paths.data.path)
        isPresented = true
    }

    /// Done: closes and remembers it was completed. Returns whether Settings ›
    /// Google Apps should open now (the Google apps step's checkbox).
    @discardableResult
    func finish() -> Bool {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        isPresented = false
        defer { openGoogleAppsSettings = false }
        return openGoogleAppsSettings
    }

    func next() {
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }

    func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }
}

// MARK: - The window

/// The Setup Assistant's window: the welcome screen, then each step beside a
/// rail that shows where you are, in Avo's haze.
struct SetupAssistantView: View {
    @Environment(SetupAssistant.self) private var assistant
    @Environment(AndroidImageManager.self) private var images
    @Environment(ControlPanelModel.self) private var model
    /// Called when Done should open Settings › Google Apps.
    var openGoogleAppsSettings: () -> Void = {}
    @State private var confirming: AndroidVersionChange?
    /// Another Android version than the data on this Mac: which data it uses.
    @State private var choosingData: AndroidVersionChange?
    /// The step before this one, for which way the next slides in.
    @State private var lastStep: SetupAssistant.Step = .welcome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 960, height: 640)
    /// The hidden title bar's height (its safe area), part of `size`.
    static let titleBarInset: CGFloat = 32
    /// Around a step's content, below the title bar and above the footer.
    static let pageInsets = EdgeInsets(top: 18, leading: 44, bottom: 16, trailing: 44)

    var body: some View {
        ZStack {
            if assistant.step == .welcome {
                WelcomeScreen()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.02)))
            } else {
                HStack(spacing: 0) {
                    SetupRail(current: assistant.step, download: downloadPercent)
                    VStack(alignment: .leading, spacing: 0) {
                        // Each step slides in from the side it comes from as the last one fades.
                        ZStack(alignment: .topLeading) {
                            page
                                .id(assistant.step)
                                .transition(stepTransition)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        footer
                            .padding(.horizontal, Self.pageInsets.leading)
                            .padding(.bottom, 24)
                    }
                    // Below the hidden title bar: what scrolls never slides under it.
                    .padding(.top, Self.titleBarInset)
                    .background(alignment: .topLeading) { SetupStepGlow(step: assistant.step) }
                }
                .transition(.opacity)
            }
        }
        // Fills its window. SwiftUI adds the hidden title bar's inset to the
        // smallest window it makes for this view: 960 × 640, which the
        // Setup window keeps (SetupWindow).
        .frame(minWidth: Self.size.width, maxWidth: .infinity, minHeight: Self.size.height - Self.titleBarInset, maxHeight: .infinity)
        .windowDragArea()
        .background(Haze.windowBase)
        // Under the hidden title bar too: the rail leaves room for the window buttons.
        .ignoresSafeArea()
        .foregroundStyle(Haze.text)
        .tint(Haze.accent)
        .animation(Haze.Motion.animation(Haze.Motion.content, reduceMotion: reduceMotion), value: assistant.step)
        .onChange(of: assistant.step) { _, step in lastStep = step }
        .task {
            // The list is usually there by the time the Android step opens.
            await images.loadCatalog()
        }
        // A start writes which image it used (needsRestart).
        .onChange(of: model.status.state) { _, _ in images.refresh() }
        .confirmationDialog(confirming?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { change in
            Button(change.confirmLabel) {
                images.apply(change, model: model)
                // A download shows its progress here first (Continue goes on meanwhile).
                if change.row.image != nil { assistant.next() }
            }
        } message: { change in
            Text(change.message)
        }
        .sheet(item: $choosingData) { change in
            AndroidDataSheet(change: change) {
                if change.row.image != nil { assistant.next() }
            }
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let forward = assistant.step.rawValue >= lastStep.rawValue
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 36 : -36)), removal: .opacity)
    }

    /// A step's page, between the title bar and the footer, which stays in
    /// view: what is taller than the window (longer words in another
    /// language, a failed download's message) scrolls. The Android step's
    /// list scrolls by itself, in the height the rest leaves it.
    @ViewBuilder private var page: some View {
        switch assistant.step {
        case .welcome: EmptyView()
        case .android:
            AndroidStep()
                .padding(Self.pageInsets)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .permissions: SetupPage { PermissionsStep() }
        case .googleApps: SetupPage { GoogleAppsStep() }
        case .ready: SetupPage { ReadyStep() }
        }
    }

    /// The download running for the Android step ("42%" in the rail).
    private var downloadPercent: Int? {
        guard let job = images.job, job.offer != nil, !job.isDone else { return nil }
        switch job.phase {
        case .downloading(let progress): return Int((progress.fraction * 100).rounded(.down))
        case .paused(let progress?): return Int((progress.fraction * 100).rounded(.down))
        case .verifying, .unpacking, .finishing: return 100
        default: return nil
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if assistant.step == .ready {
                Text("You can close this: Android keeps starting.")
                    .font(.mona(12.5))
                    .foregroundStyle(Haze.sectionLabel)
            } else {
                Button("Not Now") { assistant.isPresented = false }
                    .buttonStyle(HazeLinkButtonStyle())
                    .font(.mona(14))
                    .foregroundStyle(Haze.textTertiary)
                    .padding(.horizontal, 6)
                    .frame(height: 44)
                    .keyboardShortcut(.cancelAction)
                    .help("Close the Setup Assistant. Help › Setup Assistant… opens it again.")
            }
            Spacer(minLength: 8)
            if assistant.step == .android, images.job.map({ !$0.isDone }) ?? false, images.job?.offer != nil {
                Text("Keeps downloading in the background")
                    .font(.mona(12.5))
                    .foregroundStyle(Haze.sectionLabel)
                    .lineLimit(1)
            }
            Button("Back") { assistant.back() }
                .buttonStyle(HazeButtonStyle(kind: .secondary, height: 44, fontSize: 14, horizontalPadding: 20))
                .keyboardShortcut("[", modifiers: .command)
            if assistant.step == .ready {
                Button("Done") {
                    if assistant.finish() { openGoogleAppsSettings() }
                }
                .buttonStyle(HazeButtonStyle(kind: .primary, height: 44, fontSize: 14, horizontalPadding: 26))
                .shadow(color: Haze.accent.opacity(0.24), radius: 13, y: 8)
                .keyboardShortcut(.defaultAction)
            } else {
                Button { proceed() } label: {
                    if let download = downloadLabel {
                        Label(download, systemImage: "arrow.down.to.line").labelStyle(HazeLabelStyle(spacing: 8, iconSize: 13))
                    } else {
                        Text("Continue")
                    }
                }
                .buttonStyle(HazeButtonStyle(kind: .primary, height: 44, fontSize: 14, horizontalPadding: downloadLabel == nil ? 24 : 22))
                .shadow(color: Haze.accent.opacity(0.24), radius: 13, y: 8)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { Rectangle().fill(Haze.text.opacity(0.06)).frame(height: 1) }
    }

    private var selectedRow: AndroidVersionRow? { images.allRows.first { $0.id == assistant.selection } }

    /// "Download Android 17": the chosen version is not on this Mac yet.
    private var downloadLabel: String? {
        guard assistant.step == .android, images.job?.isRunning != true, let row = selectedRow, row.image == nil, row.offer != nil else { return nil }
        return String(localized: "Download \(row.name)")
    }

    private var canContinue: Bool {
        guard assistant.step == .android else { return true }
        // An import or download running: it goes on in the background.
        if images.job?.isRunning == true { return true }
        return selectedRow != nil || images.current != nil
    }

    private func proceed() {
        guard assistant.step == .android else {
            assistant.next()
            return
        }
        if images.job?.isRunning == true {
            // A download of the chosen row, or an import, goes on; it is used when done.
            images.useWhenInstalled()
            assistant.next()
            return
        }
        guard let row = selectedRow else {
            assistant.next()
            return
        }
        let change = AndroidVersionChange(row: row, images: images, googleAppsInstalled: model.googleAppsInstalled)
        // Data carried from another Mac is never erased here: only a version that can use it goes on.
        if change.change == .downgrade, let carried = assistant.carriedData {
            let name = carried.release?.name ?? carried.summary.android ?? String(localized: "Android")
            images.problem = String(localized: "\(row.name) can’t use your Android data from the other Mac. Choose \(name) or newer.")
            return
        }
        if change.change == .same {
            assistant.next()
        } else if change.needsData, assistant.carriedData == nil {
            choosingData = change
        } else if change.needsConfirmation {
            confirming = change
        } else {
            images.apply(change, model: model)
            // A download shows its progress here first (Continue goes on meanwhile).
            if row.image != nil { assistant.next() }
        }
    }
}

// MARK: - Welcome

/// The first screen: Avo's mark in its glow, what Avo is, and Get Started.
private struct WelcomeScreen: View {
    @Environment(SetupAssistant.self) private var assistant
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The first impression: the mark rises in its glow, then the words and cards.
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .top) {
            HazeBackground(glows: [
                HazeGlow(x: .fraction(0.5), y: .fraction(0.02), rx: 560, ry: 380, color: 0xD8E8A7, alpha: 0.26),
                HazeGlow(x: .fraction(0.5), y: .fraction(0.10), rx: 300, ry: 200, color: 0xFBF8F1, alpha: 0.14),
                HazeGlow(x: .fraction(1.04), y: .fraction(1.04), rx: 520, ry: 300, color: 0xEAA970, alpha: 0.10),
                HazeGlow(x: .fraction(-0.04), y: .fraction(1.04), rx: 520, ry: 300, color: 0xBCDC8F, alpha: 0.12),
            ])
            // Rings of haze around the mark.
            Group {
                Circle().strokeBorder(Haze.accent.opacity(0.10)).frame(width: 300, height: 300).offset(y: -58)
                Circle().strokeBorder(Haze.accent.opacity(0.06)).frame(width: 460, height: 460).offset(y: -138)
            }
            .scaleEffect(appeared || reduceMotion ? 1 : 0.92)
            .opacity(appeared ? 1 : 0)
            .animation(Haze.Motion.animation(.spring(response: 1.1, dampingFraction: 0.9), reduceMotion: reduceMotion), value: appeared)
            // The dots keep to the bottom; what is above them scrolls if it
            // is taller than the window (longer words in another language).
            VStack(spacing: 0) {
                ScrollView(.vertical) {
                    welcome
                        .frame(maxWidth: .infinity)
                        .padding(.top, 46)
                        .padding(.horizontal, 64)
                        .padding(.bottom, 12)
                }
                .windowDragArea()
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.automatic)
                StepDots(count: SetupAssistant.Step.allCases.count, current: 0)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { appeared = true }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            AvoGlowMark(size: 96, markSize: 70)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.86)
                .opacity(appeared ? 1 : 0)
                .animation(Haze.Motion.animation(.spring(response: 0.6, dampingFraction: 0.75), reduceMotion: reduceMotion).delay(0.05),
                           value: appeared)
            Group {
                Text("Welcome to Avo")
                    .textCase(.uppercase)
                    .font(.hazeMono(11))
                    .tracking(1.8)
                    .foregroundStyle(Haze.running)
                    .padding(.top, 24)
                Text("Android apps, at home on your Mac")
                    .font(.hubot(36, 750))
                    .tracking(-0.6)
                    .multilineTextAlignment(.center)
                    .hazeLineHeight(1.1, size: 36)
                    .padding(.top, 10)
                Text("Avo runs Android in a light virtual machine on Apple silicon. Every app opens in its own Mac window, and games draw with your Mac’s GPU.")
                    .font(.mona(15))
                    .hazeParagraph(1.55, size: 15)
                    .foregroundStyle(Haze.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 540)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            .hazeEntrance(appeared, delay: 0.14, rise: 10)
            HStack(alignment: .top, spacing: 14) {
                FeatureCard(symbol: "macwindow", tint: 0xD8E8A7, tintAlpha: 0.14, title: "Mac windows",
                            text: "Each app gets its own window, Dock icon and shortcuts.")
                    .hazeEntrance(appeared, delay: 0.24)
                FeatureCard(symbol: "gamecontroller", tint: 0xEAA970, tintAlpha: 0.16, title: "Made for games",
                            text: "GPU rendering, MetalFX upscaling and key mapping.")
                    .hazeEntrance(appeared, delay: 0.29)
                FeatureCard(symbol: "chevron.left.forwardslash.chevron.right", tint: 0xA9CFEE, tintAlpha: 0.14, title: "Open source",
                            text: "Free to use, and built in the open.")
                    .hazeEntrance(appeared, delay: 0.34)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 26)
            HStack(spacing: 12) {
                Button { assistant.next() } label: {
                    HStack(spacing: 10) {
                        Text("Get Started")
                        Image(systemName: "arrow.right").font(.system(size: 14, weight: .bold))
                    }
                }
                .buttonStyle(HazeButtonStyle(kind: .primary, height: 48, fontSize: 15, horizontalPadding: 26))
                .shadow(color: Haze.accent.opacity(0.28), radius: 15, y: 10)
                .keyboardShortcut(.defaultAction)
                Button("Not Now") { assistant.isPresented = false }
                    .buttonStyle(HazeLinkButtonStyle())
                    .font(.mona(15))
                    .foregroundStyle(Haze.textSecondary)
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 28)
            .hazeEntrance(appeared, delay: 0.42, rise: 8)
            // A new Mac: Android's data from the old one, on a drive.
            SetupCarriedDataButton()
                .padding(.top, 10)
                .hazeEntrance(appeared, delay: 0.48, rise: 6)
        }
    }
}

/// Avo's mark on a glowing disc (Welcome, and inside Ready's ring).
struct AvoGlowMark: View {
    let size: CGFloat
    let markSize: CGFloat
    var ring = true

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(haze: 0xFBF8F1), Color(haze: 0xE6EFC6), Color(haze: 0xC9DD96)],
                                     center: UnitPoint(x: 0.5, y: 0.32), startRadius: 0, endRadius: size * 0.68))
            AvoMark().frame(width: markSize, height: markSize)
        }
        .frame(width: size, height: size)
        .background { if ring { Circle().fill(Haze.accent.opacity(0.08)).padding(-8) } }
        .shadow(color: Haze.accent.opacity(0.45), radius: 40)
        .shadow(color: Haze.shadow.opacity(0.45), radius: 20, y: 18)
        .accessibilityHidden(true)
    }
}

private struct FeatureCard: View {
    let symbol: String
    let tint: UInt32
    let tintAlpha: Double
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    @State private var hovering = false
    @State private var bounce = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Haze.tint(tint))
                .symbolEffect(.bounce, value: bounce)
                .frame(width: 34, height: 34)
                .background(Haze.tint(tint, alpha: tintAlpha), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title).font(.mona(14, 600))
            Text(text)
                .font(.mona(12.5))
                .hazeParagraph(1.45, size: 12.5)
                .foregroundStyle(Haze.purpose)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(hovering ? Haze.text.opacity(0.065) : Haze.cardQuiet, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Haze.text.opacity(hovering ? 0.1 : 0.05)) }
        .hazeLift(hovering)
        .hazeHover($hovering)
        .onChange(of: hovering) { _, now in if now && !reduceMotion { bounce += 1 } }
    }
}

/// Where the assistant is, as dots (Welcome).
private struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Haze.accent : Haze.text.opacity(0.22))
                    .frame(width: index == current ? 22 : 6, height: 6)
                    .shadow(color: index == current ? Haze.accent.opacity(0.6) : .clear, radius: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The rail

/// The steps, done, current and to come, and the keys that move on.
private struct SetupRail: View {
    let current: SetupAssistant.Step
    /// The download's percent, beside Android Version.
    let download: Int?
    /// The current step's light, which slides down the rail.
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AvoMark().frame(width: 26, height: 26)
                Text(verbatim: "Avo").font(.hubot(18, 700)).tracking(-0.2)
                Text("Setup")
                    .textCase(.uppercase)
                    .font(.hazeMono(10.5))
                    .tracking(1.4)
                    .foregroundStyle(Haze.sectionLabel)
                    .padding(.leading, 2)
            }
            .padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SetupAssistant.Step.allCases) { step in
                    row(step)
                }
            }
            .padding(.top, 28)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Steps"))
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 8) {
                KeyHint(key: "↩", label: current == .ready ? "Done" : "Continue")
                if current != .ready { KeyHint(key: "esc", label: "Not now") }
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, 58)
        .padding(.horizontal, 16)
        .padding(.bottom, 22)
        .frame(width: 256)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                Haze.sidebar
                HazeBackground(glows: [HazeGlow(x: .fraction(0.2), y: .fraction(-0.06), rx: 300, ry: 260, color: 0xD8E8A7, alpha: 0.20),
                                       HazeGlow(x: .fraction(0.9), y: .fraction(1.08), rx: 260, ry: 220, color: 0xBCDC8F, alpha: 0.08)])
            }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Haze.text.opacity(0.05)).frame(width: 1) }
    }

    private func row(_ step: SetupAssistant.Step) -> some View {
        let done = step.rawValue < current.rawValue
        let isCurrent = step == current
        return HStack(spacing: 12) {
            StepMarker(number: step.rawValue + 1, state: done ? .done : isCurrent ? .current : .later)
            Text(step.title)
                .font(.mona(14, isCurrent ? 600 : 400))
                .foregroundStyle(isCurrent ? Haze.accentText : done ? Haze.textSecondary : Haze.sectionLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
            if step == .android, let download {
                Text(verbatim: "\(download)%")
                    .font(.mona(11.5, 600))
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? Haze.running : Haze.sectionLabel)
                    .contentTransition(.numericText(value: Double(download)))
                    .animation(Haze.Motion.press, value: download)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Haze.selection)
                    .matchedGeometryEffect(id: reduceMotion ? AnyHashable(step) : AnyHashable("current"), in: highlight)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// A step's mark: a check when done, a lit ring now, its number later.
private struct StepMarker: View {
    enum State { case done, current, later }
    let number: Int
    let state: State

    var body: some View {
        ZStack {
            switch state {
            case .done:
                // The check draws itself as the step is done.
                Circle().fill(Haze.accent)
                    .overlay { HazeCheck(color: Haze.onAccent, lineWidth: 2.1, drawsOnAppear: true).frame(width: 9, height: 8) }
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            case .current:
                Circle().strokeBorder(Haze.accent, lineWidth: 2)
                    .overlay { Circle().fill(Haze.accent).frame(width: 8, height: 8) }
                    .shadow(color: Haze.accent.opacity(0.45), radius: 6)
                    .background { StepPing() }
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            case .later:
                Circle().strokeBorder(Haze.text.opacity(0.22), lineWidth: 1.5)
                    .overlay { Text(number, format: .number).font(.mona(11, 600)) }
                    .transition(.opacity)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// A ring that leaves the marker once as its step becomes the current one.
private struct StepPing: View {
    @State private var out = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            Circle()
                .stroke(Haze.accent, lineWidth: 1.5)
                .scaleEffect(out ? 1.9 : 1)
                .opacity(out ? 0 : 0.7)
                .onAppear { withAnimation(.easeOut(duration: 0.9).delay(0.15)) { out = true } }
                .allowsHitTesting(false)
        }
    }
}

private struct KeyHint: View {
    let key: String
    let label: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: key)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Haze.textSecondary)
                .padding(.horizontal, 6)
                .frame(minWidth: 24, minHeight: 20)
                .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Haze.text.opacity(0.18)) }
            Text(label).font(.mona(12)).foregroundStyle(Haze.sectionLabel)
        }
        .accessibilityHidden(true)
    }
}

/// The glow above a step's content (Ready's sits behind its ring).
private struct SetupStepGlow: View {
    let step: SetupAssistant.Step

    var body: some View {
        // The window's glows over the content area, from the window's top
        // (the rail has its own). Ready's sits behind its ring (ReadyStep).
        GeometryReader { geometry in
            let ring = ReadyStep.ringCenter(in: geometry.size)
            ZStack {
                HazeBackground(glows: step == .ready
                    ? [HazeGlow(x: .points(ring.x), y: .points(ring.y), rx: 400, ry: 340, color: 0xD8E8A7, alpha: 0.22),
                       HazeGlow(x: .points(geometry.size.width * 1.04), y: .points(-8), rx: 240, ry: 170, color: 0xFBF8F1, alpha: 0.10)]
                    : [HazeGlow(x: .points(geometry.size.width * 1.0), y: .points(-96), rx: 520, ry: 320, color: 0xD8E8A7, alpha: 0.20),
                       HazeGlow(x: .points(geometry.size.width * 1.04), y: .points(-15), rx: 240, ry: 170, color: 0xFBF8F1, alpha: 0.12),
                       HazeGlow(x: .points(geometry.size.width * 0.16), y: .points(geometry.size.height * 1.16), rx: 420, ry: 300, color: 0xBCDC8F, alpha: 0.10)])
                    .id(step == .ready)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A step's content, scrolling only when it is taller than the space it has,
/// and fading out at the edges as it scrolls.
private struct SetupPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical) {
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(SetupAssistantView.pageInsets)
        }
        .windowDragArea()
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        // Within the insets: content at rest is never faded.
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 14)
            }
        }
    }
}

/// A step's small capitals, title and one paragraph.
private struct StepHeader: View {
    let kicker: Text
    let title: Text
    let subtitle: Text
    var subtitleWidth: CGFloat = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            kicker
                .textCase(.uppercase)
                .font(.hazeMono(11))
                .tracking(1.6)
                .foregroundStyle(Haze.running)
            title
                .font(.hubot(30, 750))
                .tracking(-0.4)
                .hazeLineHeight(1.12, size: 30)
                .padding(.top, 10)
            subtitle
                .font(.mona(14.5))
                .hazeParagraph(1.5, size: 14.5)
                .foregroundStyle(Haze.textSecondary)
                .frame(maxWidth: subtitleWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    /// "Step 2 of 5", "Step 4 of 5 · Optional".
    static func kicker(_ step: SetupAssistant.Step, _ suffix: Text? = nil) -> Text {
        let count = SetupAssistant.Step.allCases.count
        let text = Text("Step \(step.rawValue + 1) of \(count)")
        guard let suffix else { return text }
        return text + Text(verbatim: " · ") + suffix
    }
}

// MARK: - Steps

private struct AndroidStep: View {
    @Environment(SetupAssistant.self) private var assistant
    @Environment(AndroidImageManager.self) private var images

    var body: some View {
        @Bindable var assistant = assistant
        let downloading = images.job.map { $0.offer != nil && !$0.isDone && !isFailed($0) } ?? false
        VStack(alignment: .leading, spacing: 0) {
            if let job = images.job, let offer = job.offer, !job.isDone, !isFailed(job) {
                StepHeader(kicker: StepHeader.kicker(.android, Text("Downloading")),
                           title: Text("Downloading \(offer.release.name)"),
                           subtitle: Text("Carry on with the next steps meanwhile. If you quit Avo, the download picks up where it stopped."))
                AndroidImageJobView(job: job)
                    .padding(.top, 24)
                Label {
                    Text("Checked against Google’s checksum before it’s unpacked.")
                } icon: {
                    Image(systemName: "checkmark.shield").foregroundStyle(Haze.running)
                }
                .font(.mona(13))
                .foregroundStyle(Haze.purpose)
                .padding(.top, 16)
                .transition(.opacity)
            } else if let carried = assistant.carriedData {
                StepHeader(kicker: StepHeader.kicker(.android), title: Text("Choose Android for your data"),
                           subtitle: Text(carriedSubtitle(carried)))
                AndroidVersionList(selection: $assistant.selection, maxCardsHeight: .infinity)
                    .padding(.top, 24)
                if let job = images.job {
                    AndroidImageJobView(job: job).padding(.top, 12)
                } else if let problem = images.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.mona(13))
                        .foregroundStyle(Haze.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
            } else {
                StepHeader(kicker: StepHeader.kicker(.android), title: Text("Choose your Android"),
                           subtitle: Text("Avo downloads Android from Google’s public build servers: about 1 GB, 2 GB on disk. You can switch versions later in Settings."))
                AndroidVersionList(selection: $assistant.selection, maxCardsHeight: .infinity)
                    .padding(.top, 24)
                if let job = images.job {
                    AndroidImageJobView(job: job).padding(.top, 12)
                } else if let problem = images.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.mona(13))
                        .foregroundStyle(Haze.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
            }
        }
        .animation(Haze.Motion.content, value: downloading)
        .animation(Haze.Motion.content, value: images.job == nil)
        .onAppear {
            images.problem = nil
            if assistant.selection == nil { assistant.selection = images.defaultRow?.id }
            dismissIfCancelled()
        }
        // A download cancelled here goes back to the list as it was, without a card to dismiss.
        .onChange(of: images.job?.phase) { _, _ in dismissIfCancelled() }
        .onChange(of: images.allRows.map(\.id)) { _, ids in
            if assistant.selection == nil || !ids.contains(assistant.selection ?? "") { assistant.selection = images.defaultRow?.id }
        }
    }

    private func isFailed(_ job: AndroidImageJob) -> Bool {
        if case .failed = job.phase { return true }
        return false
    }

    private func dismissIfCancelled() {
        if case .cancelled? = images.job?.phase { images.dismissJob() }
    }

    /// What the carried data needs.
    private func carriedSubtitle(_ carried: CarriedAndroidData) -> String {
        let name = carried.release?.name ?? carried.summary.android ?? String(localized: "Android")
        if let mac = carried.summary.lastMac {
            return String(localized: "Your apps and data from \(mac) were last used by \(name). Choose \(name) or newer: an older Android can’t use them. Avo chose a version that can.")
        }
        return String(localized: "Your apps and data were last used by \(name). Choose \(name) or newer: an older Android can’t use them. Avo chose a version that can.")
    }
}

private struct PermissionsStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(kicker: StepHeader.kicker(.permissions), title: Text("Allow what Android apps use"),
                       subtitle: Text("Each one is up to you. Android works without them, and you can change them later in System Settings."))
            SetupPermissionsList()
                .padding(.top, 22)
        }
    }
}

private struct GoogleAppsStep: View {
    @Environment(SetupAssistant.self) private var assistant
    @Environment(AndroidImageManager.self) private var images

    var body: some View {
        @Bindable var assistant = assistant
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(kicker: StepHeader.kicker(.googleApps, Text("Optional")), title: Text("Google Play, only if you want it"),
                       subtitle: Text("Avo doesn’t include Google apps. Most apps work without them, and F-Droid or Aurora Store can install apps."))
            VStack(spacing: 0) {
                InfoRow(symbol: "arrow.down.to.line", tint: 0xD8E8A7, tintAlpha: 0.14,
                        text: Text("If you need Google Play, install a MindTheGapps package you download yourself, in Settings › Google Apps, once Android runs."))
                Rectangle().fill(Haze.text.opacity(0.06)).frame(height: 1)
                InfoRow(symbol: "exclamationmark.triangle", tint: 0xEAA970, tintAlpha: 0.16, text: Text(matchText))
                Rectangle().fill(Haze.text.opacity(0.06)).frame(height: 1)
                InfoRow(symbol: "person.badge.shield.checkmark", tint: 0xA9CFEE, tintAlpha: 0.14,
                        text: Text("Google treats Avo as an uncertified device: you register it once before you sign in. Settings shows how."))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Haze.tile)
                    HazeBackground(glows: [HazeGlow(x: .fraction(1), y: .fraction(0), rx: 340, ry: 170, color: 0xD8E8A7, alpha: 0.12)])
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Haze.text.opacity(0.06))
                }
            }
            .padding(.top, 22)
            Toggle(isOn: $assistant.openGoogleAppsSettings) {
                Text("Open Google apps settings when setup is done").font(.mona(14))
            }
            .toggleStyle(HazeCheckboxStyle(boxLeading: true))
            .frame(minHeight: 30)
            .padding(.top, 18)
        }
    }

    /// Which package fits the chosen Android.
    private var matchText: String {
        let version = images.allRows.first { $0.id == assistant.selection }?.release?.version ?? images.current?.release?.version
        guard let version else { return String(localized: "The package must match your Android version.") }
        return String(localized: "The package must match your Android: MindTheGapps \(version).0.0 for arm64, for Android \(version).")
    }

    private struct InfoRow: View {
        let symbol: String
        let tint: UInt32
        let tintAlpha: Double
        let text: Text

        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Haze.tint(tint))
                    .frame(width: 32, height: 32)
                    .background(Haze.tint(tint, alpha: tintAlpha), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                text
                    .font(.mona(13.5))
                    .hazeParagraph(1.5, size: 13.5)
                    .foregroundStyle(Haze.noteText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 14)
        }
    }
}

private struct ReadyStep: View {
    @Environment(SetupAssistant.self) private var assistant
    @Environment(AndroidImageManager.self) private var images
    @Environment(ControlPanelModel.self) private var model

    /// The column on the left, the ring beside it: they never overlap.
    static let columnWidth: CGFloat = 360
    static let ringSize: CGFloat = 220
    static let ringTop: CGFloat = 12

    /// Where the ring's center is in the content area (its glow, SetupStepGlow).
    static func ringCenter(in area: CGSize) -> CGPoint {
        let insets = SetupAssistantView.pageInsets
        return CGPoint(x: area.width - insets.trailing - ringSize / 2,
                       y: SetupAssistantView.titleBarInset + insets.top + ringTop + ringSize / 2)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                StepHeader(kicker: StepHeader.kicker(.ready), title: Text(headline), subtitle: Text(subtitle), subtitleWidth: Self.columnWidth)
                Group {
                    if let job = images.job, !job.isDone {
                        AndroidImageJobView(job: job)
                    }
                    state
                }
                .padding(.top, 22)
            }
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
            if images.current != nil || waitingForImage {
                Spacer(minLength: 0)
                BootRing(fraction: StartStages.fraction(status: model.status, needsRestart: needsRestart, waiting: waitingForImage),
                         underWay: model.status.state == .starting || waitingForImage)
                    .frame(width: Self.ringSize, height: Self.ringSize)
                    .padding(.top, Self.ringTop)
            }
        }
        .task(id: Readiness(path: images.current?.path, downloading: images.job?.isRunning == true || images.job?.canResume == true,
                            state: model.status.state, connected: model.daemonState == .connected)) {
            startIfReady()
        }
    }

    private struct Readiness: Hashable {
        var path: String?
        var downloading: Bool
        var state: VMState
        var connected: Bool
    }

    private var waitingForImage: Bool { images.job.map { !$0.isDone } ?? false }
    private var needsRestart: Bool { images.needsRestart(running: model.status.state == .running) }

    private var headline: LocalizedStringKey {
        if model.status.state == .running && !images.needsRestart(running: true) { return "Android is ready" }
        return "Starting Android"
    }

    private var subtitle: LocalizedStringKey {
        if waitingForImage { return "Android starts as soon as it is downloaded. You can close this window: the download goes on." }
        switch model.status.state {
        case .running where !images.needsRestart(running: true):
            return "Install apps by double-clicking .apk files or dropping them on Avo’s window. Each app gets its own window and Dock icon."
        case .starting:
            return "The first start takes a minute or two. Android keeps running in the background, so apps open fast later."
        default:
            return "Avo starts Android in the background."
        }
    }

    @ViewBuilder private var state: some View {
        if model.daemonState != .connected {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bolt.horizontal.circle").font(.system(size: 18)).foregroundStyle(Haze.warning)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Avo’s background service isn’t running yet.").font(.mona(14, 600))
                    if model.daemonState == .needsApproval {
                        Text("Allow Avo in System Settings › General › Login Items & Extensions.")
                            .font(.mona(12.5)).foregroundStyle(Haze.purpose)
                        Button("Open System Settings") { model.openLoginItemsSettings() }
                            .buttonStyle(HazeButtonStyle(kind: .secondary, height: 34, fontSize: 13, horizontalPadding: 14))
                    }
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
        } else if images.current == nil && !waitingForImage {
            Label("Choose an Android version first.", systemImage: "arrow.uturn.backward.circle")
                .font(.mona(14))
                .foregroundStyle(Haze.textSecondary)
        } else if !waitingForImage {
            AndroidStartProgress(status: model.status, image: images.current?.title, machine: machine,
                                 firstStart: assistant.firstStart, needsRestart: needsRestart) {
                if model.status.state == .running {
                    model.restartVM()
                } else {
                    model.startVM()
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
        }
    }

    /// "8 cores · 8 GB memory · GPU": the virtual machine Android runs in.
    private var machine: String? {
        guard let config = model.config else { return nil }
        let memory = (Double(config.memoryMiB) / 1024).formatted(.number.precision(.fractionLength(0...1)))
        var parts = [String(localized: "\(config.cpuCount) cores"), String(localized: "\(memory) GB memory")]
        switch model.status.renderer?.mode {
        case .gpu?: parts.append("GPU")
        case .software?: parts.append(String(localized: "Software"))
        case nil: if config.rendererMode != .software { parts.append("GPU") }
        }
        return parts.joined(separator: " · ")
    }

    /// Starts Android once, when an image is there and Android is not running.
    private func startIfReady() {
        guard !assistant.startedAndroid, images.current != nil, !waitingForImage, model.daemonState == .connected else { return }
        switch model.status.state {
        case .stopped, .failed, .notInstalled:
            assistant.startedAndroid = true
            model.startVM()
        default:
            break
        }
    }
}

/// Ready's ring: how far the start is, around Avo's mark. It breathes while
/// the start is under way (and its window active), and flashes once when
/// Android is ready.
private struct BootRing: View {
    let fraction: Double
    let underWay: Bool
    @Environment(\.appearsActive) private var windowActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().strokeBorder(Haze.accent.opacity(0.07))
            Circle().strokeBorder(Haze.accent.opacity(0.10)).padding(34)
            if underWay && fraction < 1 && windowActive {
                HazeLoop(period: 2.4) { phase in
                    let breath = 0.5 - 0.5 * cos(phase * 2 * .pi)
                    Circle()
                        .strokeBorder(Haze.accent.opacity(0.05 + 0.11 * breath), lineWidth: 12)
                        .padding(28)
                        .scaleEffect(reduceMotion ? 1 : 1 + 0.025 * breath)
                }
                .transition(.opacity)
            }
            Circle()
                .stroke(Haze.text.opacity(0.08), lineWidth: 4)
                .padding(34)
            Circle()
                .trim(from: 0, to: max(0.02, min(fraction, 1)))
                .stroke(Haze.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(34)
                .shadow(color: Haze.accent.opacity(0.55), radius: 5)
            if fraction >= 1 { ReadyFlash() }
            AvoGlowMark(size: 88, markSize: 64, ring: false)
        }
        .animation(.easeInOut(duration: 0.6), value: fraction)
        .animation(Haze.Motion.fade, value: underWay && windowActive)
        .accessibilityHidden(true)
    }
}

/// The ring's light going out once, wide, as Android is ready.
private struct ReadyFlash: View {
    @State private var out = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .stroke(Haze.accent, lineWidth: 4)
            .padding(34)
            .scaleEffect(out && !reduceMotion ? 1.14 : 1)
            .opacity(out ? 0 : 0.8)
            .onAppear { withAnimation(.easeOut(duration: 1.1).delay(0.45)) { out = true } }
            .allowsHitTesting(false)
    }
}

/// Android starting (with the daemon's words for where it is), running, or failed.
struct AndroidStartProgress: View {
    let status: VMStatus
    let image: String?
    /// "8 cores · 8 GB memory · GPU".
    var machine: String?
    var firstStart = false
    let needsRestart: Bool
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StartStages(status: status, image: image, machine: machine, firstStart: firstStart, needsRestart: needsRestart)
            switch status.state {
            case .running where needsRestart:
                Text("Android runs with another version. Restart it to use the new one.")
                    .font(.mona(13)).foregroundStyle(Haze.textSecondary)
                Button("Restart Android", action: start)
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 36, fontSize: 13, horizontalPadding: 16))
            case .failed, .notInstalled:
                if let detail = status.detail {
                    Text(detail).font(.mona(12.5)).foregroundStyle(Haze.purpose).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Try Again", action: start)
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 36, fontSize: 13, horizontalPadding: 16))
            case .stopped, .suspended:
                Button("Start Android", action: start)
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 36, fontSize: 13, horizontalPadding: 16))
            default:
                EmptyView()
            }
        }
    }
}

/// Image, virtual machine, boot, ready: where a start is.
private struct StartStages: View {
    let status: VMStatus
    let image: String?
    let machine: String?
    let firstStart: Bool
    let needsRestart: Bool
    @State private var since = Date()

    enum Mark { case done, active, waiting, failed }

    /// VMManager says "Waiting for Android to boot" once the engine runs.
    static func booting(_ status: VMStatus) -> Bool {
        status.state == .starting && status.detail == String(localized: "Waiting for Android to boot", bundle: .avoKit)
    }

    private var booting: Bool { Self.booting(status) }
    private var failed: Bool { status.state == .failed || status.state == .notInstalled }
    private var running: Bool { status.state == .running && !needsRestart }

    /// How far along, for Ready's ring: each stage a quarter, the one under way half done.
    static func fraction(status: VMStatus, needsRestart: Bool, waiting: Bool) -> Double {
        if waiting { return 0.125 }
        if status.state == .running && !needsRestart { return 1 }
        if booting(status) { return 0.625 }
        if status.state == .starting { return 0.375 }
        return 0.25
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(.done, "Android image", detail: image.map { Text(verbatim: $0) })
            row(running || booting ? .done : status.state == .starting ? .active : failed && !booting ? .failed : .waiting,
                "Virtual machine", detail: machine.map { Text(verbatim: $0) })
            row(running ? .done : booting ? .active : .waiting, "Waiting for Android to boot",
                detail: firstStart && !running ? Text("First start: Android sets itself up") : nil)
            row(running ? .done : .waiting, "Ready", detail: running ? status.androidVersion.map { Text(verbatim: $0) } : nil)
        }
        .onChange(of: status.state) { old, new in
            if new == .starting && old != .starting { since = Date() }
        }
    }

    private func row(_ mark: Mark, _ title: LocalizedStringKey, detail: Text?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            StageMark(mark: mark)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.mona(14.5, 600))
                        .foregroundStyle(mark == .waiting ? Haze.sectionLabel : mark == .active ? Haze.accentText : Haze.text)
                    if mark == .active {
                        // How long this start has taken so far.
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            Text(Duration.seconds(max(0, context.date.timeIntervalSince(since))).formatted(.time(pattern: .minuteSecond)))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Haze.accent)
                                .padding(.horizontal, 7)
                                .frame(height: 20)
                                .background(Haze.selection, in: Capsule())
                        }
                    }
                }
                .frame(minHeight: 24)
                if let detail {
                    detail.font(.mona(12.5)).foregroundStyle(Haze.purpose)
                }
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

/// A stage's mark: a check that draws itself, a turning arc in a soft
/// pulse of light (while its window is active), an empty ring, or a cross.
private struct StageMark: View {
    let mark: StartStages.Mark
    @Environment(\.appearsActive) private var windowActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch mark {
            case .done:
                Circle().fill(Haze.accent)
                    .overlay { HazeCheck(color: Haze.onAccent, lineWidth: 2.3, drawsOnAppear: true).frame(width: 10, height: 9) }
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            case .active:
                HazeLoop(period: reduceMotion ? 2 : 1.2, running: windowActive) { phase in
                    let breath = 0.5 - 0.5 * cos(phase * 2 * .pi)
                    ZStack {
                        Circle().fill(Haze.accent.opacity(0.16 * breath)).padding(-4)
                        Circle().stroke(Haze.text.opacity(0.16), lineWidth: 2.5)
                        Circle().trim(from: 0, to: 0.25)
                            .stroke(Haze.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(reduceMotion ? -90 : -90 + phase * 360))
                            .opacity(reduceMotion ? 0.55 + 0.45 * breath : 1)
                            .shadow(color: Haze.accent.opacity(0.6), radius: 3)
                    }
                }
                .padding(1.25)
                .transition(.opacity)
            case .waiting:
                Circle().strokeBorder(Haze.text.opacity(0.22), lineWidth: 1.5)
            case .failed:
                Circle().fill(Haze.danger.opacity(0.18))
                    .overlay { Image(systemName: "xmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Haze.danger) }
                    .transition(.opacity)
            }
        }
        .frame(width: 24, height: 24)
        .animation(Haze.Motion.animation(Haze.Motion.content, reduceMotion: reduceMotion), value: mark)
        .accessibilityHidden(true)
    }
}

/// Above the panes while Android has no image and the assistant is closed.
struct SetupBanner: View {
    @Environment(SetupAssistant.self) private var assistant
    @Environment(AndroidImageManager.self) private var images

    var body: some View {
        if images.needsImage && !assistant.isPresented {
            Banner(symbol: "shippingbox", tint: .accentColor, text: "Android isn’t set up yet. Choose a version to download or an image on this Mac.") {
                Button("Set Up Android…") { assistant.show() }
            }
        }
    }
}
