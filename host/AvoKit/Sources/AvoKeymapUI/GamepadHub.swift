import AppKit
import AvoKeymap
import CoreHaptics
import GameController

/// The Mac's game controllers, for every part of the app that wants them:
/// Android's gamepad (GamepadForwarder), the key window's key mapping
/// (KeymapController) and the controller editor (ControllerPanel).
/// GameController gives a controller's input to the app in front and keeps
/// one handler per element, so the hub alone sets them and hands each change
/// to every listener, as the key mapping's input and the whole reading.
@MainActor
public final class GamepadHub {
    public static let shared = GamepadHub()
    /// Posted when a controller connects, disconnects or becomes the one in use.
    public static let changed = Notification.Name("com.avodroid.GamepadHubChanged")

    /// What the editor shows of the controller in use.
    struct Info: Equatable {
        var name: String
        var layout: GamepadLayout
        /// It has motors GameController can drive (GCController.haptics).
        var canVibrate: Bool
        /// 0…1, nil when the controller does not say.
        var battery: Float?
        var charging: Bool
    }

    public typealias Listener = @MainActor (_ inputs: [KeymapEngine.Input], _ reading: GamepadReading) -> Void

    private var listeners: [UUID: Listener] = [:]
    /// Each controller's last reading, to tell what changed.
    private var readings: [ObjectIdentifier: GamepadReading] = [:]
    /// The reading of the controller that moved last.
    private(set) var reading = GamepadReading()
    private var engines: [ObjectIdentifier: CHHapticEngine] = [:]

    private init() {
        for controller in GCController.controllers() { attach(controller) }
        let center = NotificationCenter.default
        _ = center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            // Delivered on the main queue; GCController is not Sendable.
            nonisolated(unsafe) let controller = note.object as? GCController
            MainActor.assumeIsolated {
                if let controller { self?.attach(controller) }
                self?.announce()
            }
        }
        _ = center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let controller = note.object as? GCController
            MainActor.assumeIsolated {
                if let controller { self?.detach(controller) }
                self?.announce()
            }
        }
        _ = center.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.announce() }
        }
    }

    /// `listener` hears every change of every controller from now on.
    public func addListener(_ listener: @escaping Listener) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    public func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    /// The controller used last, else any with the full set of controls.
    public static func activePad() -> GCExtendedGamepad? {
        GCController.current?.extendedGamepad ?? GCController.controllers().lazy.compactMap(\.extendedGamepad).first
    }

    private static var activeController: GCController? {
        GCController.current.flatMap { $0.extendedGamepad == nil ? nil : $0 }
            ?? GCController.controllers().first { $0.extendedGamepad != nil }
    }

    /// The controller in use, nil while none is connected.
    var info: Info? {
        guard let controller = Self.activeController else { return nil }
        let battery = controller.battery
        return Info(name: controller.vendorName ?? controller.productCategory,
                    layout: GamepadLayout(productCategory: controller.productCategory),
                    canVibrate: controller.haptics != nil,
                    battery: battery.flatMap { $0.batteryState == .unknown ? nil : $0.batteryLevel },
                    charging: battery?.batteryState == .charging)
    }

    /// How button legends read: the controller in use, else the one used
    /// last (remembered), so a layout keeps its legends between sessions.
    var layout: GamepadLayout {
        if let layout = info?.layout { return layout }
        return UserDefaults.standard.string(forKey: Self.lastLayoutKey).flatMap(GamepadLayout.init(rawValue:)) ?? .xbox
    }

    private static let lastLayoutKey = "AvoLastControllerLayout"

    public static func reading(of pad: GCExtendedGamepad) -> GamepadReading {
        let buttons: [(GCControllerButtonInput?, GamepadButton)] = [
            (pad.buttonA, .a), (pad.buttonB, .b), (pad.buttonX, .x), (pad.buttonY, .y),
            (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder),
            (pad.leftTrigger, .leftTrigger), (pad.rightTrigger, .rightTrigger),
            (pad.dpad.up, .dpadUp), (pad.dpad.down, .dpadDown), (pad.dpad.left, .dpadLeft), (pad.dpad.right, .dpadRight),
            (pad.leftThumbstickButton, .leftThumbstick), (pad.rightThumbstickButton, .rightThumbstick),
            (pad.buttonMenu, .menu), (pad.buttonOptions, .options),
        ]
        return GamepadReading(pressed: Set(buttons.compactMap { $0.0?.isPressed == true ? $0.1 : nil }),
                              home: pad.buttonHome?.isPressed == true,
                              leftX: pad.leftThumbstick.xAxis.value, leftY: pad.leftThumbstick.yAxis.value,
                              rightX: pad.rightThumbstick.xAxis.value, rightY: pad.rightThumbstick.yAxis.value,
                              leftTrigger: pad.leftTrigger.value, rightTrigger: pad.rightTrigger.value)
    }

    // MARK: Vibration

    /// A short, light pulse on the controller in use (a button touched the
    /// screen), when it can vibrate.
    public func pulse() {
        guard let controller = Self.activeController, let haptics = controller.haptics else { return }
        let key = ObjectIdentifier(controller)
        let engine: CHHapticEngine
        if let running = engines[key] {
            engine = running
        } else {
            guard let made = haptics.createEngine(withLocality: .default) else { return }
            made.playsHapticsOnly = true
            // Stops between pulses by itself, and starts again on the next one.
            made.isAutoShutdownEnabled = true
            engines[key] = made
            engine = made
        }
        do {
            try engine.start()
            // Continuous, not transient: a controller's rumble motors need a little time to spin.
            let event = CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55),
                                                   CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)],
                                      relativeTime: 0, duration: 0.05)
            try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: [])).start(atTime: CHHapticTimeImmediate)
        } catch {
            // Reset by the system (the controller slept): a new engine next time.
            engines[key] = nil
        }
    }

    // MARK: Controllers

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        let key = ObjectIdentifier(controller)
        readings[key] = Self.reading(of: pad)
        // The profile's own handler, called for each element that changed.
        pad.valueChangedHandler = { [weak self] gamepad, _ in
            MainActor.assumeIsolated { self?.changed(gamepad, key: key) }
        }
    }

    private func detach(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        engines[key] = nil
        // Whatever it held lets go.
        guard let last = readings.removeValue(forKey: key) else { return }
        let rest = GamepadReading()
        reading = rest
        tell(rest.inputs(since: last), rest)
    }

    private func changed(_ pad: GCExtendedGamepad, key: ObjectIdentifier) {
        let new = Self.reading(of: pad)
        let old = readings[key] ?? GamepadReading()
        readings[key] = new
        reading = new
        tell(new.inputs(since: old), new)
    }

    private func tell(_ inputs: [KeymapEngine.Input], _ reading: GamepadReading) {
        for listener in Array(listeners.values) { listener(inputs, reading) }
    }

    private func announce() {
        if let layout = info?.layout { UserDefaults.standard.set(layout.rawValue, forKey: Self.lastLayoutKey) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
