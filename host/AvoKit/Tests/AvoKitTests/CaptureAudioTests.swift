import Foundation
import Testing
@testable import AvoKit

/// Android's sound in screen recordings: the engine's ring (as tap.rs
/// writes it), where its blocks go in the movie, and their format.
@Suite struct CaptureAudioTests {
    /// A ring file laid out as engine/hvf/vmm/src/virtio/sound/tap.rs writes it.
    private final class Ring {
        let url: URL
        let slots: Int
        let slotSize: Int
        let epoch: UInt64
        private(set) var newest: UInt64 = 0
        private var data: Data

        init(slots: Int = 4, slotSize: Int = 128, epoch: UInt64 = 77) throws {
            url = FileManager.default.temporaryDirectory.appending(path: "avo-ring-\(UUID().uuidString).ring")
            self.slots = slots
            self.slotSize = slotSize
            self.epoch = epoch
            data = Data(count: AudioRing.headerSize + slots * slotSize)
            data.replaceSubrange(0..<4, with: Array("AVOA".utf8))
            put(UInt32(1), at: 4)
            put(UInt32(slots), at: 8)
            put(UInt32(slotSize), at: 12)
            put(UInt32(slotSize - 32), at: 16)
            put(epoch, at: 24)
            try save()
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        var location: AudioTapLocation { AudioTapLocation(path: url.path, epoch: epoch) }

        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: $0) }
        }

        /// Writes slot `newest + 1`; `torn` leaves its sequence 0, as while the engine writes it.
        func add(hostTime: UInt64, rate: UInt32 = 48_000, channels: UInt16 = 2, flags: UInt32 = 0, samples: [Int16],
                 torn: Bool = false) throws {
            newest += 1
            let slot = AudioRing.headerSize + Int(newest % UInt64(slots)) * slotSize
            put(torn ? 0 : newest, at: slot)
            put(hostTime, at: slot + 8)
            put(rate, at: slot + 16)
            put(channels, at: slot + 20)
            put(UInt16(1), at: slot + 22)
            put(UInt32(samples.count / Int(channels)), at: slot + 24)
            put(flags, at: slot + 28)
            for (index, sample) in samples.enumerated() { put(sample, at: slot + 32 + index * 2) }
            put(newest, at: 32)
            try save()
        }

        /// In place, as the engine's shared mapping changes it: a reader's mapping sees it.
        private func save() throws {
            let handle = try? FileHandle(forWritingTo: url)
            if let handle {
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url)
            }
        }
    }

    @Test func theEventSaysWhereTheRingIs() {
        let location = AudioTapLocation(event: "audio playback 123 /Users/me/Library/Application Support/Avo/vm/cuttlefish/audio/playback.ring")
        #expect(location == AudioTapLocation(path: "/Users/me/Library/Application Support/Avo/vm/cuttlefish/audio/playback.ring", epoch: 123))
        #expect(AudioTapLocation(event: "audio playback x /a") == nil)
        #expect(AudioTapLocation(event: "audio playback 1") == nil)
        #expect(AudioTapLocation(event: "sound playback on") == nil)
    }

    @Test func aReaderTakesWhatIsAddedFromThenOn() throws {
        let ring = try Ring()
        try ring.add(hostTime: 10, samples: [1, 2])
        let reader = try #require(AudioTapReader(location: ring.location))
        #expect(reader.read().blocks.isEmpty, "audio from before it is not its")

        try ring.add(hostTime: 20, flags: 1, samples: [3, 4, 5, 6])
        try ring.add(hostTime: 30, rate: 44_100, channels: 1, samples: [-7, 8, 9])
        let (blocks, lost) = reader.read()
        #expect(!lost)
        #expect(blocks == [AudioBlock(hostTime: 20, rate: 48_000, channels: 2, runStart: true, samples: [3, 4, 5, 6]),
                           AudioBlock(hostTime: 30, rate: 44_100, channels: 1, samples: [-7, 8, 9])])
        #expect(blocks[1].frames == 3)
        #expect(reader.read().blocks.isEmpty)
    }

    @Test func aReaderThatFellBehindSaysWhatItLost() throws {
        let ring = try Ring(slots: 4)
        let reader = try #require(AudioTapReader(location: ring.location))
        for time in 1...6 { try ring.add(hostTime: UInt64(time), samples: [Int16(time), 0]) }
        let behind = reader.read()
        #expect(behind.lost)
        #expect(behind.blocks.map(\.hostTime) == [3, 4, 5, 6], "the ring holds four")

        // A slot the engine is writing is skipped, never half read.
        try ring.add(hostTime: 7, samples: [7, 0], torn: true)
        try ring.add(hostTime: 8, samples: [8, 0])
        let torn = reader.read()
        #expect(torn.lost)
        #expect(torn.blocks.map(\.hostTime) == [8])
    }

    @Test func aRingOfAnotherEngineIsNotRead() throws {
        let ring = try Ring(epoch: 5)
        #expect(AudioTapReader(location: AudioTapLocation(path: ring.url.path, epoch: 6)) == nil)
        #expect(AudioTapReader(location: AudioTapLocation(path: ring.url.path + ".missing", epoch: 5)) == nil)
        let garbage = FileManager.default.temporaryDirectory.appending(path: "avo-ring-\(UUID().uuidString)")
        try Data(count: 8192).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }
        #expect(AudioTapReader(location: AudioTapLocation(path: garbage.path, epoch: 0)) == nil)
    }

    @Test func blocksThatFollowEachOtherPlayOnWithoutGaps() {
        var timeline = AudioTimeline()
        // Sound starts a quarter second into the movie: silence first.
        #expect(timeline.place(position: 12_000, frames: 960, runStart: true) == .init(silence: 12_000, skip: 0, count: 960))
        // The next ones played 5 ms late and 4 ms early: right after it all the same.
        #expect(timeline.place(position: 12_960 + 240, frames: 960, runStart: false) == .init(silence: 0, skip: 0, count: 960))
        #expect(timeline.place(position: 13_920 - 192, frames: 960, runStart: false) == .init(silence: 0, skip: 0, count: 960))
        #expect(timeline.written == 14_880)
        // A pause of 100 ms in the sound stays a pause.
        #expect(timeline.place(position: 14_880 + 4_800, frames: 960, runStart: false) == .init(silence: 4_800, skip: 0, count: 960))
        // A new stream goes at its own time even when it is close.
        #expect(timeline.place(position: 20_640 + 500, frames: 960, runStart: true) == .init(silence: 500, skip: 0, count: 960))
    }

    @Test func lateAudioLosesWhatSilenceTookAlready() {
        var timeline = AudioTimeline()
        // Nothing played: silence up to shortly before now.
        #expect(timeline.pad(to: 48_000) == 48_000)
        #expect(timeline.pad(to: 40_000) == 0)
        // A block that played from 0.95 s came late: its first 50 ms are gone.
        #expect(timeline.place(position: 45_600, frames: 4_800, runStart: true) == .init(silence: 0, skip: 2_400, count: 2_400))
        #expect(timeline.written == 50_400)
        // One wholly in the past is dropped.
        #expect(timeline.place(position: 1_000, frames: 960, runStart: false) == .init(silence: 0, skip: 960, count: 0))
        #expect(timeline.written == 50_400)
    }

    @Test func soundFromBeforeTheMovieIsCutOff() {
        var timeline = AudioTimeline()
        #expect(timeline.place(position: -480, frames: 960, runStart: true) == .init(silence: 0, skip: 480, count: 480))
        var other = AudioTimeline()
        #expect(other.place(position: -9_600, frames: 960, runStart: false) == .init(silence: 0, skip: 960, count: 0))
        #expect(other.written == 0)
    }

    @Test func soundBecomesStereoAt48kHz() {
        #expect(AudioPCM.stereo48k([1, 2, 3, 4], channels: 2, rate: 48_000) == [1, 2, 3, 4])
        #expect(AudioPCM.stereo48k([5, -6], channels: 1, rate: 48_000) == [5, 5, -6, -6])
        // 24 kHz: every frame twice as long, with the steps between.
        #expect(AudioPCM.stereo48k([0, 100, 200, 300], channels: 1, rate: 24_000)
            == [0, 0, 50, 50, 100, 100, 150, 150, 200, 200, 250, 250, 300, 300, 300, 300])
        let second = [Int16](repeating: 7, count: 44_100 * 2)
        #expect(AudioPCM.stereo48k(second, channels: 2, rate: 44_100).count == 96_000)
        #expect(AudioPCM.framesAt48k(44_100, rate: 44_100) == 48_000)
        #expect(AudioPCM.framesAt48k(960, rate: 48_000) == 960)
        #expect(AudioPCM.stereo48k([1, 2], channels: 3, rate: 48_000).isEmpty)
    }

    @Test func recordingsTakeAndroidsSoundUnlessTurnedOff() throws {
        let suite = "com.avodroid.tests.capture.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = CaptureSettings(store: store)
        #expect(settings.recordsAndroidSound)
        settings.recordsAndroidSound = false
        #expect(!CaptureSettings(store: store).recordsAndroidSound)
        settings.recordsAndroidSound = true
        #expect(store.object(forKey: CaptureSettings.recordSoundKey) == nil, "on is the default: nothing kept")
    }
}
