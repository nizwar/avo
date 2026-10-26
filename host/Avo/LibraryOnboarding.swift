import AppKit
import SwiftUI

// The Setup Assistant (SetupAssistant.swift) beside the Library: its banner
// while Android has no image, in the haze, and its own window, which opens
// when the assistant asks to show (first launch, no image, Help › Setup
// Assistant…) and closes when it is done or put off.

struct LibrarySetupBanner: View {
    @Environment(SetupAssistant.self) private var assistant
    @Environment(AndroidImageManager.self) private var images

    var body: some View {
        if images.needsImage && !assistant.isPresented {
            HazeBanner(symbol: "shippingbox", tint: Haze.accent,
                       text: "Android isn’t set up yet. Choose a version to download or an image on this Mac.") {
                Button("Set Up Android…") { assistant.show() }
            }
        }
    }
}

/// The Setup Assistant's window.
struct SetupWindow: View {
    static let id = "setup"
    @Environment(SetupAssistant.self) private var assistant
    @Environment(LibraryRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        SetupAssistantView {
            router.requestedSettingsPane = .googleApps
            openWindow(id: SettingsWindow.id)
        }
        // Opened some other way than the assistant (a restored window): it
        // starts over, so Done and Not Now close it.
        .onAppear {
            assistant.windowOpen = true
            if !assistant.isPresented { assistant.show() }
        }
        .onChange(of: assistant.isPresented) { _, shown in
            if !shown { dismissWindow(id: Self.id) }
        }
        // Closed with its close button: put off until Help › Setup Assistant….
        .onDisappear {
            assistant.windowOpen = false
            assistant.isPresented = false
        }
        .background { SetupWindowAccessor() }
    }
}

/// The Setup window keeps the design's size: no resizing, no zoom.
private struct SetupWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        view.onWindow = { window in
            window.styleMask.remove(.resizable)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.backgroundColor = NSColor(Haze.windowBase)
        }
        return view
    }

    func updateNSView(_ nsView: WindowAccessorView, context: Context) {}
}

private struct SetupAssistantPresenter: ViewModifier {
    @Environment(SetupAssistant.self) private var assistant
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: assistant.isPresented, initial: true) { _, shown in
            guard shown, !assistant.windowOpen else { return }
            openWindow(id: SetupWindow.id)
            // At launch the Library's window is still being made: a request
            // made then is dropped without a word (the assistant only showed
            // once Settings opened). Asked again until its window is there.
            Task { @MainActor in
                for _ in 0..<12 {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard assistant.isPresented, !assistant.windowOpen else { return }
                    openWindow(id: SetupWindow.id)
                }
            }
        }
    }
}

extension View {
    /// Opens the Setup Assistant's window when it asks to show.
    func presentsSetupAssistant() -> some View {
        modifier(SetupAssistantPresenter())
    }
}
