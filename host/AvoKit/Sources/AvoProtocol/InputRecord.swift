import Foundation

// Input channel (vsock 6001) records. Layout is documented in docs/protocol.md
// and mirrored by com.avodroid.bridge.input.InputDecoder in the Bridge Agent.

public enum TouchAction: UInt8, Sendable, Equatable {
    case down = 0
    case up = 1
    case move = 2
    case cancel = 3
    case pointerDown = 5
    case pointerUp = 6
}

public struct TouchPointer: Sendable, Equatable {
    public var id: UInt32
    public var x: Float
    public var y: Float
    public var pressure: Float

    public init(id: UInt32, x: Float, y: Float, pressure: Float = 1) {
        self.id = id
        self.x = x
        self.y = y
        self.pressure = pressure
    }
}

/// A complete MotionEvent: the action plus every pointer currently down.
public struct TouchEvent: Sendable, Equatable {
    public static let maxPointers = 16

    public var displayID: UInt32
    public var action: TouchAction
    /// Index into `pointers` of the pointer that went down/up for POINTER_DOWN/UP.
    public var actionIndex: UInt8
    public var pointers: [TouchPointer]

    public init(displayID: UInt32, action: TouchAction, actionIndex: UInt8 = 0, pointers: [TouchPointer]) {
        self.displayID = displayID
        self.action = action
        self.actionIndex = actionIndex
        self.pointers = pointers
    }
}

public enum KeyAction: UInt8, Sendable, Equatable {
    case down = 0
    case up = 1
}

public struct KeyEvent: Sendable, Equatable {
    public var displayID: UInt32
    public var action: KeyAction
    /// Android `KeyEvent.KEYCODE_*`.
    public var keyCode: UInt32
    /// Android `KeyEvent.META_*` bits.
    public var metaState: UInt32
    public var repeatCount: UInt32
    public var scanCode: UInt32

    public init(displayID: UInt32, action: KeyAction, keyCode: UInt32, metaState: UInt32 = 0,
                repeatCount: UInt32 = 0, scanCode: UInt32 = 0) {
        self.displayID = displayID
        self.action = action
        self.keyCode = keyCode
        self.metaState = metaState
        self.repeatCount = repeatCount
        self.scanCode = scanCode
    }
}

public struct ScrollEvent: Sendable, Equatable {
    public var displayID: UInt32
    public var x: Float
    public var y: Float
    /// AXIS_HSCROLL, 1.0 = one notch.
    public var horizontal: Float
    /// AXIS_VSCROLL, positive scrolls content up (wheel away from the user).
    public var vertical: Float
    public var buttons: UInt32

    public init(displayID: UInt32, x: Float, y: Float, horizontal: Float, vertical: Float, buttons: UInt32 = 0) {
        self.displayID = displayID
        self.x = x
        self.y = y
        self.horizontal = horizontal
        self.vertical = vertical
        self.buttons = buttons
    }
}

public struct MouseEvent: Sendable, Equatable {
    /// Android MotionEvent actions used with SOURCE_MOUSE.
    public enum Action: UInt8, Sendable {
        case down = 0, up = 1, move = 2, hoverMove = 7, hoverEnter = 9, hoverExit = 10
        case buttonPress = 11, buttonRelease = 12
    }

    public var displayID: UInt32
    public var action: Action
    public var x: Float
    public var y: Float
    public var buttons: UInt32
    public var actionButton: UInt32

    public init(displayID: UInt32, action: Action, x: Float, y: Float, buttons: UInt32 = 0, actionButton: UInt32 = 0) {
        self.displayID = displayID
        self.action = action
        self.x = x
        self.y = y
        self.buttons = buttons
        self.actionButton = actionButton
    }
}

public struct GamepadState: Sendable, Equatable {
    public enum Axis: Int, CaseIterable, Sendable {
        case leftX, leftY, rightX, rightY, leftTrigger, rightTrigger, hatX, hatY
    }

    /// The display of the window that drives the gamepad (0 when unknown):
    /// the daemon checks the sender owns it, and the guest unplugs the
    /// gamepad when that display closes (a shim that quit or crashed).
    public var displayID: UInt32
    public var pad: UInt8
    public var connected: Bool
    public var buttons: UInt32
    public var axes: [Float]

    public init(displayID: UInt32 = 0, pad: UInt8, connected: Bool = true, buttons: UInt32 = 0,
                axes: [Float] = Array(repeating: 0, count: 8)) {
        precondition(axes.count == Axis.allCases.count, "GamepadState needs exactly 8 axes")
        self.displayID = displayID
        self.pad = pad
        self.connected = connected
        self.buttons = buttons
        self.axes = axes
    }

    public subscript(axis: Axis) -> Float {
        get { axes[axis.rawValue] }
        set { axes[axis.rawValue] = newValue }
    }
}

public enum InputRecord: Sendable, Equatable {
    case touch(TouchEvent)
    case key(KeyEvent)
    case scroll(ScrollEvent)
    case text(displayID: UInt32, String)
    case mouse(MouseEvent)
    case gamepad(GamepadState)
    case ping(token: UInt64)
}

public enum InputWireError: Error, Equatable, Sendable {
    case badPreamble
    case recordTooShort(type: UInt8, length: Int)
    case recordTooLong(Int)
    case tooManyPointers(Int)
    case invalidAction(UInt8)
    case textTooLong(Int)
}

public enum InputWire {
    public static let magic: [UInt8] = Array("AVOI".utf8)
    public static let version: UInt16 = 1
    public static let headerLength = 8
    public static let maxRecordLength = 1024
    public static let maxTextBytes = maxRecordLength - headerLength - 2

    enum RecordType: UInt8 {
        case touch = 0x01, key = 0x02, scroll = 0x03, text = 0x04, mouse = 0x05, gamepad = 0x06, ping = 0x7F
    }

    public static func preamble(version: UInt16 = InputWire.version) -> [UInt8] {
        var writer = ByteWriter()
        writer.bytes(magic)
        writer.u16(version)
        writer.u16(0)
        return writer.buffer
    }

    /// Parses the peer's preamble and returns the version to use.
    public static func negotiate(peerPreamble bytes: [UInt8]) throws(InputWireError) -> UInt16 {
        guard bytes.count == 8, Array(bytes[0..<4]) == magic else { throw .badPreamble }
        let peer = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
        guard peer >= 1 else { throw .badPreamble }
        return min(peer, version)
    }

    public static func encode(_ record: InputRecord) throws(InputWireError) -> [UInt8] {
        var writer = ByteWriter()
        try encode(record, into: &writer)
        return writer.buffer
    }

    public static func encode(_ record: InputRecord, into writer: inout ByteWriter) throws(InputWireError) {
        let start = writer.buffer.count
        func header(_ type: RecordType, displayID: UInt32) {
            writer.u8(type.rawValue)
            writer.u8(0)
            writer.u16(0) // patched below
            writer.u32(displayID)
        }
        switch record {
        case let .touch(event):
            guard (1...TouchEvent.maxPointers).contains(event.pointers.count) else {
                throw .tooManyPointers(event.pointers.count)
            }
            header(.touch, displayID: event.displayID)
            writer.u8(event.action.rawValue)
            writer.u8(event.actionIndex)
            writer.u8(UInt8(event.pointers.count))
            writer.u8(0)
            writer.u32(0)
            for pointer in event.pointers {
                writer.u32(pointer.id)
                writer.f32(pointer.x)
                writer.f32(pointer.y)
                writer.f32(pointer.pressure)
            }
        case let .key(event):
            header(.key, displayID: event.displayID)
            writer.u8(event.action.rawValue)
            writer.u8(0); writer.u16(0)
            writer.u32(event.keyCode)
            writer.u32(event.metaState)
            writer.u32(event.repeatCount)
            writer.u32(event.scanCode)
        case let .scroll(event):
            header(.scroll, displayID: event.displayID)
            writer.f32(event.x)
            writer.f32(event.y)
            writer.f32(event.horizontal)
            writer.f32(event.vertical)
            writer.u32(event.buttons)
        case let .text(displayID, text):
            let utf8 = Array(text.utf8)
            guard utf8.count <= maxTextBytes else { throw .textTooLong(utf8.count) }
            header(.text, displayID: displayID)
            writer.u16(UInt16(utf8.count))
            writer.bytes(utf8)
        case let .mouse(event):
            header(.mouse, displayID: event.displayID)
            writer.u8(event.action.rawValue)
            writer.u8(0); writer.u16(0)
            writer.f32(event.x)
            writer.f32(event.y)
            writer.u32(event.buttons)
            writer.u32(event.actionButton)
        case let .gamepad(state):
            header(.gamepad, displayID: state.displayID)
            writer.u8(state.pad)
            writer.u8(state.connected ? 1 : 0)
            writer.u16(0)
            writer.u32(state.buttons)
            for axis in state.axes { writer.f32(axis) }
        case let .ping(token):
            header(.ping, displayID: 0)
            writer.u64(token)
        }
        let length = writer.buffer.count - start
        writer.patchU16(at: start + 2, UInt16(length))
    }

    /// Decodes one record from the front of `bytes`.
    ///
    /// - Returns: the record and the number of bytes consumed, `nil` if more
    ///   bytes are needed, or `(nil, length)` for an unknown record type that
    ///   should be skipped.
    public static func decode(_ bytes: ArraySlice<UInt8>) throws(InputWireError) -> (record: InputRecord?, consumed: Int)? {
        guard bytes.count >= headerLength else { return nil }
        var reader = ByteReader(bytes)
        let rawType = reader.u8()
        _ = reader.u8()
        let length = Int(reader.u16())
        let displayID = reader.u32()
        guard length >= headerLength else { throw .recordTooShort(type: rawType, length: length) }
        guard length <= maxRecordLength else { throw .recordTooLong(length) }
        guard bytes.count >= length else { return nil }
        guard let type = RecordType(rawValue: rawType) else { return (nil, length) }

        func require(_ minimum: Int) throws(InputWireError) {
            if length < minimum { throw .recordTooShort(type: rawType, length: length) }
        }

        let record: InputRecord
        switch type {
        case .touch:
            try require(16)
            guard let action = TouchAction(rawValue: reader.u8()) else { throw .invalidAction(bytes[bytes.startIndex + 8]) }
            let actionIndex = reader.u8()
            let count = Int(reader.u8())
            _ = reader.u8(); _ = reader.u32()
            guard (1...TouchEvent.maxPointers).contains(count) else { throw .tooManyPointers(count) }
            try require(16 + 16 * count)
            var pointers: [TouchPointer] = []
            pointers.reserveCapacity(count)
            for _ in 0..<count {
                pointers.append(TouchPointer(id: reader.u32(), x: reader.f32(), y: reader.f32(), pressure: reader.f32()))
            }
            record = .touch(TouchEvent(displayID: displayID, action: action, actionIndex: actionIndex, pointers: pointers))
        case .key:
            try require(28)
            let rawAction = reader.u8()
            guard let action = KeyAction(rawValue: rawAction) else { throw .invalidAction(rawAction) }
            _ = reader.u8(); _ = reader.u16()
            record = .key(KeyEvent(displayID: displayID, action: action, keyCode: reader.u32(),
                                   metaState: reader.u32(), repeatCount: reader.u32(), scanCode: reader.u32()))
        case .scroll:
            try require(28)
            record = .scroll(ScrollEvent(displayID: displayID, x: reader.f32(), y: reader.f32(),
                                         horizontal: reader.f32(), vertical: reader.f32(), buttons: reader.u32()))
        case .text:
            try require(10)
            let count = Int(reader.u16())
            try require(10 + count)
            record = .text(displayID: displayID, String(decoding: reader.bytes(count), as: UTF8.self))
        case .mouse:
            try require(28)
            let rawAction = reader.u8()
            guard let action = MouseEvent.Action(rawValue: rawAction) else { throw .invalidAction(rawAction) }
            _ = reader.u8(); _ = reader.u16()
            record = .mouse(MouseEvent(displayID: displayID, action: action, x: reader.f32(), y: reader.f32(),
                                       buttons: reader.u32(), actionButton: reader.u32()))
        case .gamepad:
            try require(48)
            let pad = reader.u8()
            let connected = reader.u8() != 0
            _ = reader.u16()
            let buttons = reader.u32()
            let axes = (0..<8).map { _ in reader.f32() }
            record = .gamepad(GamepadState(displayID: displayID, pad: pad, connected: connected, buttons: buttons, axes: axes))
        case .ping:
            try require(16)
            record = .ping(token: reader.u64())
        }
        return (record, length)
    }
}

/// Incremental decoder for an Input channel byte stream (after the preamble).
public struct InputRecordDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    public mutating func append(_ bytes: some Sequence<UInt8>) {
        buffer.append(contentsOf: bytes)
    }

    public mutating func next() throws(InputWireError) -> InputRecord? {
        while let (record, consumed) = try InputWire.decode(buffer[start...]) {
            start += consumed
            if start == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                start = 0
            }
            if let record { return record }
        }
        return nil
    }
}

// MARK: - Little-endian helpers

public struct ByteWriter: Sendable {
    public private(set) var buffer: [UInt8] = []

    public init(capacity: Int = 64) {
        buffer.reserveCapacity(capacity)
    }

    public mutating func u8(_ v: UInt8) { buffer.append(v) }
    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { buffer.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { buffer.append(contentsOf: $0) } }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { buffer.append(contentsOf: $0) } }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func bytes(_ b: some Sequence<UInt8>) { buffer.append(contentsOf: b) }

    mutating func patchU16(at offset: Int, _ v: UInt16) {
        buffer[offset] = UInt8(v & 0xFF)
        buffer[offset + 1] = UInt8(v >> 8)
    }
}

public struct ByteReader {
    private let bytes: ArraySlice<UInt8>
    private var offset: Int

    public init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.offset = bytes.startIndex
    }

    public mutating func u8() -> UInt8 {
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func u16() -> UInt16 {
        UInt16(u8()) | UInt16(u8()) << 8
    }

    public mutating func u32() -> UInt32 {
        UInt32(u16()) | UInt32(u16()) << 16
    }

    public mutating func u64() -> UInt64 {
        UInt64(u32()) | UInt64(u32()) << 32
    }

    public mutating func f32() -> Float { Float(bitPattern: u32()) }

    public mutating func bytes(_ count: Int) -> ArraySlice<UInt8> {
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }
}
