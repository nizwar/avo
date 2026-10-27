import Darwin
import Foundation
import Synchronization

// Android's sound in screen recordings. avo-vmm copies every period the Mac
// has played into a ring in shared memory, with the host time it played at
// (engine/hvf/vmm/src/virtio/sound/tap.rs); the daemon passes on where the
// ring is (`DaemonEvent.audioTap`), and a recording window reads it
// (`AudioTapReader`) and puts each block at its time in the movie's audio
// track (`AudioTimeline`), next to the frames shown then.

/// Where avo-vmm's ring of played sound is, from its sticky event
/// `audio playback <epoch> <path…>`. A new engine process makes a new ring
/// (a new epoch) under the same name.
public struct AudioTapLocation: Codable, Sendable, Equatable {
    public var path: String
    public var epoch: UInt64

    public init(path: String, epoch: UInt64) {
        self.path = path
        self.epoch = epoch
    }

    /// The event's location; nil for any other line.
    public init?(event line: String) {
        let words = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard words.count == 4, words[0] == "audio", words[1] == "playback", let epoch = UInt64(words[2]), !words[3].isEmpty
        else { return nil }
        self.init(path: String(words[3]), epoch: epoch)
    }
}

/// One stretch of what Android played: S16 samples, interleaved.
public struct AudioBlock: Sendable, Equatable {
    /// Host time of its first frame (mach ticks).
    public var hostTime: UInt64
    public var rate: Int
    public var channels: Int
    /// The first audio of a stream: its time starts it anew.
    public var runStart: Bool
    public var samples: [Int16]

    public init(hostTime: UInt64, rate: Int, channels: Int, runStart: Bool = false, samples: [Int16]) {
        self.hostTime = hostTime
        self.rate = rate
        self.channels = channels
        self.runStart = runStart
        self.samples = samples
    }

    public var frames: Int { channels > 0 ? samples.count / channels : 0 }
}

/// The ring's layout (tap.rs has the table).
public enum AudioRing {
    public static let magic: [UInt8] = Array("AVOA".utf8)
    public static let headerSize = 4096
    public static let slotHeaderSize = 32
    static let formatS16 = 1
    static let runStartFlag: UInt32 = 1

    public struct Header: Sendable, Equatable {
        public var slots: Int
        public var slotSize: Int
        public var epoch: UInt64
        /// The newest complete slot's sequence (0: none yet).
        public var newest: UInt64
    }

    /// The header of `length` bytes at `base`, nil when it is not a ring
    /// (yet) or does not fit.
    public static func header(at base: UnsafeRawPointer, length: Int) -> Header? {
        guard length >= headerSize else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        guard (0..<4).allSatisfy({ bytes[$0] == magic[$0] }) else { return nil }
        atomicMemoryFence(ordering: .acquiring)
        let word = { (offset: Int) in Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
        guard word(4) == 1 else { return nil }
        let slots = word(8), slotSize = word(12)
        guard slots > 0, slotSize > slotHeaderSize, word(16) == slotSize - slotHeaderSize,
              headerSize + slots * slotSize <= length else { return nil }
        return Header(slots: slots, slotSize: slotSize, epoch: UInt64(littleEndian: base.loadUnaligned(fromByteOffset: 24, as: UInt64.self)),
                      newest: newest(at: base))
    }

    static func newest(at base: UnsafeRawPointer) -> UInt64 {
        let value = UInt64(littleEndian: base.load(fromByteOffset: 32, as: UInt64.self))
        atomicMemoryFence(ordering: .acquiring)
        return value
    }

    /// Slot `sequence`, copied out; nil when the engine wrote over it (or is
    /// writing it) meanwhile.
    static func slot(_ sequence: UInt64, at base: UnsafeRawPointer, header: Header) -> AudioBlock? {
        let slot = base.advanced(by: headerSize + Int(sequence % UInt64(header.slots)) * header.slotSize)
        let stamp = { () -> UInt64 in
            let value = UInt64(littleEndian: slot.load(as: UInt64.self))
            atomicMemoryFence(ordering: .acquiring)
            return value
        }
        guard stamp() == sequence else { return nil }
        let hostTime = UInt64(littleEndian: slot.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        let rate = Int(UInt32(littleEndian: slot.loadUnaligned(fromByteOffset: 16, as: UInt32.self)))
        let channels = Int(UInt16(littleEndian: slot.loadUnaligned(fromByteOffset: 20, as: UInt16.self)))
        let format = Int(UInt16(littleEndian: slot.loadUnaligned(fromByteOffset: 22, as: UInt16.self)))
        let frames = Int(UInt32(littleEndian: slot.loadUnaligned(fromByteOffset: 24, as: UInt32.self)))
        let flags = UInt32(littleEndian: slot.loadUnaligned(fromByteOffset: 28, as: UInt32.self))
        let count = frames * channels
        guard format == formatS16, rate > 0, (1...2).contains(channels), count * 2 <= header.slotSize - slotHeaderSize else { return nil }
        let samples = [Int16](unsafeUninitializedCapacity: count) { buffer, initialized in
            memcpy(buffer.baseAddress!, slot.advanced(by: slotHeaderSize), count * 2)
            initialized = count
        }
        // A torn copy (the engine came round to this slot meanwhile) is dropped.
        atomicMemoryFence(ordering: .acquiring)
        guard stamp() == sequence else { return nil }
        return AudioBlock(hostTime: hostTime, rate: rate, channels: channels, runStart: flags & runStartFlag != 0,
                          samples: samples.map { Int16(littleEndian: $0) })
    }
}

/// Reads a ring as it fills: each call returns the blocks the engine added
/// since the last one. Maps the ring read-only and keeps it mapped (the
/// engine replaces it with a new one, never shrinks it). One queue only.
public final class AudioTapReader: @unchecked Sendable {
    public let location: AudioTapLocation
    private let base: UnsafeMutableRawPointer
    private let length: Int
    private let header: AudioRing.Header
    private var next: UInt64

    /// Maps the ring at `location`; reading starts with what is added from now on.
    public init?(location: AudioTapLocation) {
        let fd = SharedMemory.openForReading(location.path)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= AudioRing.headerSize else { return nil }
        let length = Int(info.st_size)
        guard let map = mmap(nil, length, PROT_READ, MAP_SHARED, fd, 0), map != MAP_FAILED else { return nil }
        guard let header = AudioRing.header(at: map, length: length), header.epoch == location.epoch else {
            munmap(map, length)
            return nil
        }
        self.location = location
        base = map
        self.length = length
        self.header = header
        next = header.newest + 1
    }

    deinit { munmap(base, length) }

    /// The blocks added since the last call, oldest first. `lost`: some
    /// were written over before they were read (the reader fell behind by
    /// the whole ring) or while they were read.
    public func read() -> (blocks: [AudioBlock], lost: Bool) {
        let newest = AudioRing.newest(at: base)
        guard newest >= next else { return ([], false) }
        var lost = false
        // Older ones are gone: the ring holds `slots`.
        if newest - next >= UInt64(header.slots) {
            next = newest - UInt64(header.slots) + 1
            lost = true
        }
        var blocks: [AudioBlock] = []
        while next <= newest {
            if let block = AudioRing.slot(next, at: base, header: header) { blocks.append(block) } else { lost = true }
            next += 1
        }
        return (blocks, lost)
    }
}

/// The audio track's clock: frames at 48 kHz from the movie's start, where
/// each block of Android's sound is written. A block that follows the one
/// before it within `tolerance` goes right after it (the times the Mac
/// played them at jitter by a few milliseconds); one that starts a stream
/// or leaves a larger gap goes at its own time, with silence before it;
/// one that overlaps what is written already (it came too late, after
/// silence was padded there) loses that part. Silence also pads the track
/// up to shortly before now while nothing plays, so the movie's writer never
/// waits for audio that is not coming.
public struct AudioTimeline: Sendable, Equatable {
    public static let rate = 48_000
    /// 30 ms.
    public static let tolerance: Int64 = 1_440

    /// What to write for one block: silence first, then the block's frames
    /// after skipping `skip` of them.
    public struct Placement: Sendable, Equatable {
        public var silence: Int
        public var skip: Int
        public var count: Int
    }

    /// The next frame to write, counted from the movie's start.
    public private(set) var written: Int64 = 0

    public init() {}

    /// Places a block of `frames` frames (at 48 kHz) that starts at
    /// `position` (frames from the movie's start; negative before it).
    public mutating func place(position: Int64, frames: Int, runStart: Bool) -> Placement {
        let frames64 = Int64(frames)
        var placement = Placement(silence: 0, skip: 0, count: frames)
        if !runStart, abs(position - written) <= Self.tolerance {
            // Right after the one before it.
        } else if position > written {
            placement.silence = Int(position - written)
        } else {
            let skip = min(written - position, frames64)
            placement.skip = Int(skip)
            placement.count = Int(frames64 - skip)
        }
        written += Int64(placement.silence + placement.count)
        return placement
    }

    /// Silence that brings the track up to `position`: none when it is there already.
    public mutating func pad(to position: Int64) -> Int {
        guard position > written else { return 0 }
        defer { written = position }
        return Int(position - written)
    }
}

/// Android's sound as the movie's audio track takes it: 48 kHz stereo.
public enum AudioPCM {
    /// Interleaved S16 at `rate` with one or two channels, as interleaved
    /// stereo at `AudioTimeline.rate` (mono doubled; another rate, which
    /// Android's mixer rarely uses, resampled linearly).
    public static func stereo48k(_ samples: [Int16], channels: Int, rate: Int) -> [Int16] {
        guard channels == 1 || channels == 2, rate > 0 else { return [] }
        let frames = samples.count / channels
        let stereo: [Int16] = channels == 2 ? Array(samples.prefix(frames * 2)) : samples.flatMap { [$0, $0] }
        guard rate != AudioTimeline.rate, frames > 0 else { return stereo }
        let count = Int((Double(frames) * Double(AudioTimeline.rate) / Double(rate)).rounded())
        let step = Double(rate) / Double(AudioTimeline.rate)
        var out = [Int16](repeating: 0, count: count * 2)
        for frame in 0..<count {
            let at = Double(frame) * step
            let left = min(Int(at), frames - 1), right = min(left + 1, frames - 1)
            let t = at - Double(left)
            for channel in 0..<2 {
                let a = Double(stereo[left * 2 + channel]), b = Double(stereo[right * 2 + channel])
                out[frame * 2 + channel] = Int16((a + (b - a) * t).rounded())
            }
        }
        return out
    }

    /// The frames `stereo48k` makes of `frames` frames at `rate`.
    public static func framesAt48k(_ frames: Int, rate: Int) -> Int {
        rate == AudioTimeline.rate ? frames : Int((Double(frames) * Double(AudioTimeline.rate) / Double(rate)).rounded())
    }
}

/// Settings › whether screen recordings take Android's sound (on unless the
/// user turned it off), for every app: kept in the Window Host's defaults,
/// which every App Shim reads.
public struct CaptureSettings {
    public static let recordSoundKey = "AvoRecordAndroidSound"

    public let store: UserDefaults

    public init(store: UserDefaults) {
        self.store = store
    }

    public var recordsAndroidSound: Bool {
        get { store.object(forKey: Self.recordSoundKey) as? Bool ?? true }
        nonmutating set {
            if newValue { store.removeObject(forKey: Self.recordSoundKey) } else { store.set(false, forKey: Self.recordSoundKey) }
        }
    }
}
