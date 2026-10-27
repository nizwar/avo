import AvoKit
import SwiftUI

// Graphics › Renderer: how Android renders right now (VMStatus.renderer from
// the daemon), and the way back to the GPU after a failed GPU start.

/// Under the Renderer picker: what Android uses now (what Automatic means is
/// in the picker's help).
struct RendererStatusRow: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        if let renderer = model.status.renderer {
            // Asked for the GPU but not getting it: worth noticing.
            let missed = renderer.requested == .gpu && renderer.mode == .software
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    message(renderer)
                        .foregroundStyle(missed ? Haze.warning : Haze.textSecondary)
                } icon: {
                    Image(systemName: renderer.mode == .gpu ? "cpu.fill" : (missed ? "exclamationmark.triangle.fill" : "cpu"))
                        .foregroundStyle(missed ? Haze.warning : (renderer.mode == .gpu ? Haze.positive : Haze.textTertiary))
                }
                .fixedSize(horizontal: false, vertical: true)
                if renderer.reason == .failed {
                    if let failure = renderer.failure {
                        Text(failure.description)
                            .font(.mona(12))
                            .foregroundStyle(Haze.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Try GPU Again") { model.retryGPU() }
                        .disabled(model.googleAppsChangingAndroid)
                }
            }
            .font(.mona(13))
            .hazeRowNote()
        }
    }

    private func message(_ renderer: RendererStatus) -> Text {
        if renderer.mode == .gpu {
            if let device = renderer.detail, !device.isEmpty { return Text("Android renders on this Mac’s GPU (\(device)).") }
            return Text("Android renders on this Mac’s GPU.")
        }
        switch renderer.reason {
        case .emulatorMissing?:
            // Avo.app brings its GPU renderer: only a damaged copy lacks it.
            return Text("This copy of Avo is missing its GPU renderer, so Android renders in software. Install Avo again to use the GPU.")
        case .emulatorUnsupported?:
            // Avo.app brings its own: only an old or damaged copy has one too old.
            return Text("This copy of Avo has an old GPU renderer (\(renderer.emulatorVersion ?? "?")), so Android renders in software. Install the latest Avo to use the GPU.")
        case .failed?:
            return Text("GPU rendering failed to start, so Android uses software rendering.")
        case .chosen?, nil:
            return Text("Android renders in software on this Mac’s CPU.")
        }
    }
}
