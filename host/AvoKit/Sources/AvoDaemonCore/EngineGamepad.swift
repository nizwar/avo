import AvoProtocol

/// The engine's gamepad: an Xbox pad on virtio-input (Description::gamepad
/// in engine/hvf/vmm/src/virtio/input.rs) that avo-vmm's `gamepad` command
/// drives. HostAgent plays the Input channel's GAMEPAD records on it.
enum EngineGamepad {
    /// Its name in Android (/sys/class/input/input*/name): the one an Xbox
    /// controller has there, since some games (Call of Duty: Mobile) accept
    /// only controllers whose name they know.
    static let name = "Xbox Wireless Controller"

    /// The engine command for `state`, from GameController units (-1…1 with
    /// y up, triggers 0…1) to evdev ones: sticks ±32767 with y down,
    /// triggers 0…1023, hat -1…1 with y down. The button mask goes as it is:
    /// the engine knows its bits (GamepadButton order, Home on bit 16).
    static func command(for state: GamepadState) -> String {
        func clamp(_ value: Float, _ lowest: Float) -> Float { value.isNaN ? 0 : min(max(value, lowest), 1) }
        func stick(_ value: Float) -> Int { Int((clamp(value, -1) * 32767).rounded()) }
        func trigger(_ value: Float) -> Int { Int((clamp(value, 0) * 1023).rounded()) }
        func hat(_ value: Float) -> Int { value > 0.5 ? 1 : value < -0.5 ? -1 : 0 }
        let values = [Int(state.buttons),
                      stick(state[.leftX]), -stick(state[.leftY]), stick(state[.rightX]), -stick(state[.rightY]),
                      trigger(state[.leftTrigger]), trigger(state[.rightTrigger]),
                      hat(state[.hatX]), -hat(state[.hatY])]
        return "gamepad " + values.map(String.init).joined(separator: " ")
    }

    /// Plugs the gamepad into Android: binds its virtio driver again, and
    /// Android opens it like a controller plugged in (the stock Xbox key
    /// layout maps it). Its driver is the only one Avo leaves unbound.
    static let attachScript = """
        for v in /sys/bus/virtio/devices/virtio*; do \
          if [ "$(cat $v/device)" = 0x0012 ] && [ ! -e $v/driver ]; then \
            basename $v > /sys/bus/virtio/drivers/virtio_input/bind; \
          fi; \
        done
        """

    /// Unplugs it: unbinds its virtio driver, and Android drops the input
    /// device like a controller pulled out.
    static let detachScript = """
        for d in /sys/class/input/input*; do \
          if [ "$(cat $d/name)" = \(HostAgent.quote(name)) ]; then \
            basename $(readlink -f $d/device) > /sys/bus/virtio/drivers/virtio_input/unbind; \
          fi; \
        done
        """
}
