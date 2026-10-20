import AvoProtocol
import Testing
@testable import AvoDaemonCore

@Suite struct EngineGamepadTests {
    @Test func atRestEverythingIsZero() {
        #expect(EngineGamepad.command(for: GamepadState(pad: 0)) == "gamepad 0 0 0 0 0 0 0 0 0")
    }

    @Test func sticksAndHatTurnYDownAndTriggersSpanTheXboxRange() {
        var state = GamepadState(pad: 0, buttons: 0b101)
        state[.leftX] = 1
        state[.leftY] = 1 // up on the Mac
        state[.rightX] = -0.5
        state[.rightY] = -1
        state[.leftTrigger] = 0.5
        state[.rightTrigger] = 1
        state[.hatX] = -1
        state[.hatY] = 1 // d-pad up
        #expect(EngineGamepad.command(for: state) == "gamepad 5 32767 -32767 -16384 32767 512 1023 -1 -1")
    }

    @Test func outOfRangeAndNaNValuesStayInRange() {
        var state = GamepadState(pad: 0)
        state[.leftX] = 7
        state[.leftY] = .nan
        state[.rightX] = -.infinity
        state[.leftTrigger] = -1
        state[.rightTrigger] = .nan
        state[.hatX] = 0.2
        state[.hatY] = .nan
        #expect(EngineGamepad.command(for: state) == "gamepad 0 32767 0 -32767 0 0 0 0 0")
    }

    @Test func scriptsFindTheGamepadByNameAndRebindOnlyAnUnboundInputDevice() {
        #expect(EngineGamepad.detachScript.contains("= 'Xbox Wireless Controller' ]"))
        #expect(EngineGamepad.detachScript.contains("/sys/bus/virtio/drivers/virtio_input/unbind"))
        #expect(EngineGamepad.attachScript.contains("= 0x0012 ] && [ ! -e $v/driver ]"))
        #expect(!EngineGamepad.attachScript.contains("\n"), "one shell line")
    }

    @Test func gamepadRecordsNameTheDisplayTheirSenderMustOwn() {
        #expect(InputChannel.displayID(of: .gamepad(GamepadState(displayID: 3, pad: 0))) == 3)
    }
}
