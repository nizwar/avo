import AvoKit
import CoreGraphics

/// The per-frame drawing choices from the resolved graphics settings. They
/// apply on the next frame, with no re-plug: only Android's size and density
/// make Android lay out again, so they live in `DisplayRequest` instead.
struct RenderOptions: Equatable, Sendable {
    var filter: GraphicsSettings.Filter
    /// 0...100; 0 turns the RCAS pass off.
    var sharpness: Int
    /// FXAA on Android's frame, at its own size, before it is scaled.
    var fxaa = false
}

/// Why a frame that asked for MetalFX was drawn bilinearly instead. The HUD
/// shows it, so a soft picture always has a visible reason.
enum ScalerFallback: Sendable, Equatable {
    /// The scaler for this input and output is still being built (off the render queue).
    case preparing
    /// MetalFX could not build a scaler for this size; remembered until the swapchain changes.
    case failed
    /// A live resize or full-screen transition is in progress, or the size changed under 150 ms ago.
    case resizing
    /// The system reported critical memory pressure; held until the destination changes.
    case memoryPressure
    /// This GPU has no MetalFX spatial scaler.
    case unavailable
}

/// A snapshot of what the renderer is doing, for the performance HUD. Taken
/// under the renderer's lock, so every field describes the same moment.
struct RenderStatistics: Sendable {
    /// Frames from Android in the last second.
    var framesPerSecond: Double
    /// Mean and longest interval between Android's frames over the last two seconds.
    var averageFrameMs: Double
    var maxFrameMs: Double
    /// Frames since the swapchain began that were never drawn: sequence gaps
    /// (frames that never reached this window) and frames a newer one
    /// overtook while the render queue was busy.
    var skippedFrames: Int
    /// Android's frame on screen (the held one while holding) and the drawable it is presented in.
    var source: PixelSize?
    var destination: PixelSize?
    /// The path the last draw took, and why it is not the one the settings asked for.
    var path: ScalingPath?
    var fallback: ScalerFallback?
    var sharpened: Bool
    /// GPU time of the last draws (scaling, sharpening and the final pass), smoothed.
    var scalingMs: Double?
    /// No frame from Android for a second: the screen is static, so FPS means nothing.
    var idle: Bool
    /// The renderer keeps the last frame up while Android re-plugs its display.
    var waitingForAndroid: Bool
}

extension PixelSize {
    /// A Core Graphics size rounded to whole pixels (a drawable or texture size).
    /// Non-finite or negative lengths count as 0, so a view that has not been
    /// laid out yet never traps here.
    init(_ size: CGSize) {
        self.init(width: Self.pixels(size.width), height: Self.pixels(size.height))
    }

    private static func pixels(_ length: CGFloat) -> Int {
        length.isFinite ? Int(max(0, length).rounded()) : 0
    }
}
