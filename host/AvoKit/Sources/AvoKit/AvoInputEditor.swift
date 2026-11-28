import Foundation

/// Absolute selection and composing ranges are UTF-16 offsets in the Android editor, as in NSTextInputClient.
public struct AvoInputEditorState: Codable, Equatable, Sendable {
    public var session: String
    public var ack: Int
    public var start: Int
    public var end: Int
    public var markStart: Int
    public var markEnd: Int
    public var offset: Int?
    public var text: String?
    public var privateEditor: Bool?
}

public struct AvoInputEdit: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case mark, commit, finish, cancel, keyDown, keyUp }
    public static let maximumMessageBytes = 8 * 1024 * 1024
    public var session: String
    public var sequence: Int
    public var action: Action
    public var text: String?
    public var from: Int?
    public var to: Int?
    public var caretStart: Int?
    public var caretEnd: Int?
    public var keyCode: UInt32?
    public var metaState: UInt32?
    public var repeatCount: UInt32?
}

/// AppKit asks synchronously, including between two edits in the same key event. Keep an
/// optimistic view until the same Android editor acknowledges those edits.
public struct AvoInputTextBuffer {
    public init() {}
    public private(set) var state: AvoInputEditorState?

    public mutating func update(_ incoming: AvoInputEditorState?) {
        if let state, var incoming, incoming.session == state.session {
            guard incoming.ack >= state.ack else { return }
            if incoming.privateEditor != true && incoming.text == nil && incoming.ack == state.ack
                && incoming.start == state.start && incoming.end == state.end {
                incoming.text = state.text
                incoming.offset = state.offset
            }
            self.state = incoming
        } else {
            state = incoming
        }
    }

    private static func range(_ a: Int, _ b: Int) -> NSRange? {
        guard a >= 0, b >= 0, a <= Int(Int32.max), b <= Int(Int32.max) else { return nil }
        return NSRange(location: min(a, b), length: abs(b - a))
    }

    public var selection: NSRange? { state.flatMap { Self.range($0.start, $0.end) } }
    public var marked: NSRange? { state.flatMap { Self.range($0.markStart, $0.markEnd) } }

    public func substring(_ range: NSRange) -> (String, NSRange)? {
        guard let state, let text = state.text as NSString?, let offset = state.offset,
              range.location >= 0, range.length >= 0, range.location <= Int(Int32.max),
              range.length <= Int(Int32.max) - range.location else { return nil }
        let shared = NSIntersectionRange(range, NSRange(location: offset, length: text.length))
        guard shared.length > 0 else { return nil }
        return (text.substring(with: NSRange(location: shared.location - offset, length: shared.length)), shared)
    }

    /// The editor decides where a navigation key moves its selection.
    public mutating func key(_ code: UInt32, down: Bool, meta: UInt32, repeatCount: UInt32) -> AvoInputEdit? {
        guard var state else { return nil }
        state.ack += 1
        self.state = state
        return AvoInputEdit(session: state.session, sequence: state.ack, action: down ? .keyDown : .keyUp,
                            keyCode: code, metaState: meta, repeatCount: repeatCount)
    }

    public mutating func edit(_ action: AvoInputEdit.Action, text: String? = nil,
                              selection caret: NSRange? = nil, replacement: NSRange? = nil) -> AvoInputEdit? {
        guard var state else { return nil }
        let explicit = replacement.flatMap { $0.location == NSNotFound ? nil : $0 }
        if let range = explicit {
            guard range.location >= 0, range.length >= 0, range.location <= Int(Int32.max),
                  range.length <= Int(Int32.max) - range.location else { return nil }
        }
        let replaced = explicit ?? marked ?? selection
        let value = text ?? ""
        let length = value.utf16.count
        guard length <= Int(Int32.max) - (replaced?.location ?? 0) else { return nil }
        let cursor = caret.flatMap { r in
            r.location >= 0 && r.length >= 0 && r.location <= length && r.length <= length - r.location ? r : nil
        }
        state.ack += 1
        let edit = AvoInputEdit(session: state.session, sequence: state.ack, action: action, text: text,
                                from: explicit?.location, to: explicit.map(NSMaxRange),
                                caretStart: cursor?.location, caretEnd: cursor.map(NSMaxRange))
        // JSON may use six bytes for one control character. Keep normal keystrokes off the encoding path.
        if value.utf8.count > (AvoInputEdit.maximumMessageBytes - 512) / 6,
           AvoXPC.encode(edit).count >= AvoInputEdit.maximumMessageBytes { return nil }
        let hadMark = marked != nil
        state.markStart = -1
        state.markEnd = -1
        if let range = replaced, action != .finish, action != .cancel || hadMark {
            if state.privateEditor == true {
                state.offset = nil
                state.text = nil
            } else if let context = state.text as NSString?, let offset = state.offset,
               range.location >= offset, NSMaxRange(range) <= offset + context.length {
                state.text = context.replacingCharacters(in: NSRange(location: range.location - offset, length: range.length), with: value)
            } else {
                state.offset = range.location
                state.text = value
            }
            state.start = range.location + (cursor?.location ?? length)
            state.end = range.location + (cursor.map(NSMaxRange) ?? length)
            if let context = state.text as NSString?, let offset = state.offset, context.length > 2048 {
                let cursor = min(context.length, max(0, state.start - offset))
                let lower = max(0, cursor - 512), upper = min(context.length, cursor + 512)
                let slice = context.rangeOfComposedCharacterSequences(for: NSRange(location: lower, length: upper - lower))
                state.text = slice.length <= 2048 ? context.substring(with: slice) : nil
                state.offset = state.text != nil ? offset + slice.location : nil
            }
            if action == .mark, length > 0 {
                state.markStart = range.location
                state.markEnd = range.location + length
            }
        }
        self.state = state
        return edit
    }
}
