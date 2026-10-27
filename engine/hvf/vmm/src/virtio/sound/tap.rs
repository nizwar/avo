//! Android's played sound for screen recordings: every period the Mac has
//! played (or, without an output device, the clock has used up) is copied
//! into a ring in shared memory with the host time it played at, so an App
//! Shim recording a window puts the sound next to the frames shown then.
//!
//! One ring per process, the shared memory `/avo.<pid>.audio` (shm.rs; a
//! file would have the disk write the sound out all the time), announced
//! with the sticky event `audio playback <epoch> shm:<name>`. A new ring
//! is a new object: readers keep their mapping of the old one and map again
//! when the epoch changes.
//! Little endian:
//!
//! ```text
//! header (4096 bytes)
//!  0  magic "AVOA"            24  epoch (u64, new for every ring)
//!  4  version (1)             32  sequence of the newest complete slot (u64; 0 = none)
//!  8  slot count              40  mach timebase numerator
//! 12  bytes per slot          44  mach timebase denominator
//! 16  PCM bytes per slot
//!
//! slot of sequence n, at 4096 + (n % count) * bytes per slot (8192)
//!  0  sequence (u64; 0 while it is written)   22  format (u16; 1 = S16LE, interleaved)
//!  8  host time of its first frame (mach)     24  frames (u32)
//! 16  rate (u32)                              28  flags (bit 0: a stream's first audio)
//! 20  channels (u16)                          32  PCM
//! ```
//!
//! A slot is a seqlock: a reader copies it, then checks that its sequence
//! is still the one it expected. A slot holds 2040 stereo frames, more than
//! the audio HAL's periods (1024); a larger period takes several, each with
//! the time of its own first frame. 512 slots of about 20 ms keep some ten
//! seconds, far more than a reader polling a few times a second needs.

use std::path::Path;
use std::sync::atomic::{Ordering, fence};
use std::sync::{Mutex, OnceLock};

const MAGIC: &[u8; 4] = b"AVOA";
const HEADER: usize = 4096;
const SLOTS: usize = 512;
const SLOT_SIZE: usize = 8192;
const SLOT_HEADER: usize = 32;
const FORMAT_S16LE: u16 = 1;
const FLAG_RUN_START: u32 = 1;

unsafe extern "C" {
    fn munmap(addr: *mut u8, len: usize) -> i32;
    fn mach_absolute_time() -> u64;
    fn mach_timebase_info(info: *mut [u32; 2]) -> i32;
}

pub struct Ring {
    /// Its shared memory's name (shm.rs).
    name: String,
    map: *mut u8,
    len: usize,
    slots: usize,
    slot_size: usize,
    epoch: u64,
    /// The newest complete slot.
    sequence: u64,
    /// mach ticks = nanoseconds × denominator / numerator.
    timebase: (u32, u32),
    /// The stream run (sound.rs `Audio::id`) of the last audio written.
    run: u64,
}

// The mapping is only touched under the ring's mutex.
unsafe impl Send for Ring {}

impl Ring {
    /// Makes the ring named `name`, in place of an older one.
    pub fn create(name: &str, slots: usize, slot_size: usize) -> std::io::Result<Ring> {
        let len = HEADER + slots * slot_size;
        // A new object, never the old one rewritten: a reader that still
        // maps it must not see it shrink under it.
        let map = crate::shm::create(name, len)?;
        let mut info = [0u32; 2];
        unsafe { mach_timebase_info(&mut info) };
        let timebase = if info[0] == 0 || info[1] == 0 { (1, 1) } else { (info[0], info[1]) };
        let epoch = unsafe { mach_absolute_time() }.max(1);
        let header = unsafe { std::slice::from_raw_parts_mut(map, HEADER) };
        let mut put = |at: usize, value: u32| header[at..at + 4].copy_from_slice(&value.to_le_bytes());
        put(4, 1);
        put(8, slots as u32);
        put(12, slot_size as u32);
        put(16, (slot_size - SLOT_HEADER) as u32);
        put(40, timebase.0);
        put(44, timebase.1);
        header[24..32].copy_from_slice(&epoch.to_le_bytes());
        // The magic last: a reader never takes a half-made header.
        fence(Ordering::Release);
        header[0..4].copy_from_slice(MAGIC);
        Ok(Ring { name: name.to_string(), map, len, slots, slot_size, epoch, sequence: 0, timebase, run: 0 })
    }

    /// `audio playback <epoch> shm:<name>`.
    pub fn event(&self) -> String {
        format!("audio playback {} {}", self.epoch, crate::shm::location(&self.name))
    }

    /// Adds audio whose last frame ended at host time `end` (mach ticks).
    pub fn write(&mut self, run: u64, rate: u32, channels: u8, pcm: &[u8], end: u64) {
        let frame_bytes = channels as usize * 2;
        if rate == 0 || frame_bytes == 0 {
            return;
        }
        let frames = pcm.len() / frame_bytes;
        let per_slot = (self.slot_size - SLOT_HEADER) / frame_bytes;
        let mut first_flag = if run != self.run { FLAG_RUN_START } else { 0 };
        self.run = run;
        let mut done = 0;
        while done < frames {
            let count = per_slot.min(frames - done);
            let start = end.saturating_sub(self.ticks(frames - done, rate));
            let bytes = &pcm[done * frame_bytes..(done + count) * frame_bytes];
            self.publish(start, rate, channels, count as u32, first_flag, bytes);
            first_flag = 0;
            done += count;
        }
    }

    /// Host ticks that `frames` take at `rate`.
    fn ticks(&self, frames: usize, rate: u32) -> u64 {
        let nanos = frames as u128 * 1_000_000_000 / rate as u128;
        (nanos * self.timebase.1 as u128 / self.timebase.0 as u128) as u64
    }

    fn publish(&mut self, start: u64, rate: u32, channels: u8, frames: u32, flags: u32, pcm: &[u8]) {
        let sequence = self.sequence + 1;
        let index = (sequence % self.slots as u64) as usize;
        let slot = unsafe { std::slice::from_raw_parts_mut(self.map.add(HEADER + index * self.slot_size), self.slot_size) };
        slot[0..8].copy_from_slice(&0u64.to_le_bytes());
        fence(Ordering::Release);
        slot[8..16].copy_from_slice(&start.to_le_bytes());
        slot[16..20].copy_from_slice(&rate.to_le_bytes());
        slot[20..22].copy_from_slice(&(channels as u16).to_le_bytes());
        slot[22..24].copy_from_slice(&FORMAT_S16LE.to_le_bytes());
        slot[24..28].copy_from_slice(&frames.to_le_bytes());
        slot[28..32].copy_from_slice(&flags.to_le_bytes());
        slot[SLOT_HEADER..SLOT_HEADER + pcm.len()].copy_from_slice(pcm);
        // The slot before its sequence, the sequence before the header's.
        fence(Ordering::Release);
        slot[0..8].copy_from_slice(&sequence.to_le_bytes());
        fence(Ordering::Release);
        let header = unsafe { std::slice::from_raw_parts_mut(self.map, HEADER) };
        header[32..40].copy_from_slice(&sequence.to_le_bytes());
        self.sequence = sequence;
    }
}

impl Drop for Ring {
    fn drop(&mut self) {
        unsafe { munmap(self.map, self.len) };
        crate::shm::unlink(&self.name);
    }
}

static RING: OnceLock<Option<Mutex<Ring>>> = OnceLock::new();

/// Makes the process's ring (the first call; a guest reboot keeps it) and
/// returns the event that announces it, nil when the shared memory could
/// not be made. `directory` held the ring as a file before: one left there
/// by an earlier version goes.
pub fn open(directory: &Path) -> Option<String> {
    let ring = RING.get_or_init(|| {
        let _ = std::fs::remove_file(directory.join("playback.ring"));
        match Ring::create(&crate::shm::name("audio"), SLOTS, SLOT_SIZE) {
            Ok(ring) => Some(Mutex::new(ring)),
            Err(e) => {
                eprintln!("[vmm] sound: no playback tap for recordings: {e}");
                None
            }
        }
    });
    ring.as_ref().map(|ring| ring.lock().unwrap().event())
}

/// Audio of stream run `run` (S16, interleaved) that has just been played:
/// its last frame ended now.
pub fn played(run: u64, rate: u32, channels: u8, pcm: &[u8]) {
    if let Some(Some(ring)) = RING.get() {
        let now = unsafe { mach_absolute_time() };
        ring.lock().unwrap().write(run, rate, channels, pcm, now);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(name: &str) -> Vec<u8> {
        crate::shm::read(name).unwrap()
    }

    fn u32_at(data: &[u8], at: usize) -> u32 {
        u32::from_le_bytes(data[at..at + 4].try_into().unwrap())
    }

    fn u64_at(data: &[u8], at: usize) -> u64 {
        u64::from_le_bytes(data[at..at + 8].try_into().unwrap())
    }

    #[test]
    fn periods_are_published_with_the_time_they_played() {
        let name = crate::shm::name("test.tap");
        let mut ring = Ring::create(&name, 4, 128).unwrap();
        let data = read(&name);
        assert_eq!(&data[0..4], b"AVOA");
        assert_eq!((u32_at(&data, 4), u32_at(&data, 8), u32_at(&data, 12), u32_at(&data, 16)), (1, 4, 128, 96));
        assert_eq!(u64_at(&data, 32), 0, "nothing yet");
        assert_eq!(ring.event(), format!("audio playback {} shm:{name}", u64_at(&data, 24)));

        // 1000 frames of stereo at 48 kHz that ended at tick 10 s: 96 bytes
        // hold 24 frames, so 42 slots go round the ring of 4.
        let end = ring.ticks(48_000 * 10, 48_000);
        let pcm: Vec<u8> = (0..4000).map(|i| i as u8).collect();
        ring.write(7, 48_000, 2, &pcm, end);
        let data = read(&name);
        assert_eq!(u64_at(&data, 32), 42);
        // The newest slot: the last 16 frames (1000 = 41 × 24 + 16).
        let slot = &data[HEADER + (42 % 4) * 128..][..128];
        assert_eq!(u64_at(slot, 0), 42);
        assert_eq!(u64_at(slot, 8), end - ring.ticks(16, 48_000));
        assert_eq!((u32_at(slot, 16), u32_at(slot, 20) & 0xffff, u32_at(slot, 20) >> 16), (48_000, 2, 1));
        assert_eq!(u32_at(slot, 24), 16);
        assert_eq!(u32_at(slot, 28), 0, "not the run's first audio");
        assert_eq!(&slot[32..32 + 64], &pcm[4000 - 64..]);
        // The one before it, 24 frames earlier.
        let previous = &data[HEADER + (41 % 4) * 128..][..128];
        assert_eq!(u64_at(previous, 0), 41);
        assert_eq!(u64_at(previous, 8), end - ring.ticks(40, 48_000));

        // A new run is flagged in its first slot only.
        ring.write(8, 44_100, 1, &[1, 0, 2, 0], end);
        let data = read(&name);
        let slot = &data[HEADER + (43 % 4) * 128..][..128];
        assert_eq!((u64_at(slot, 0), u32_at(slot, 16), u32_at(slot, 20) & 0xffff), (43, 44_100, 1));
        assert_eq!((u32_at(slot, 24), u32_at(slot, 28)), (2, FLAG_RUN_START));
        drop(ring);
        assert!(crate::shm::read(&name).is_err(), "the name goes with the ring");
    }

    #[test]
    fn a_new_ring_replaces_the_old_one_but_not_its_mapping() {
        let name = crate::shm::name("test.tapnew");
        let old = Ring::create(&name, 2, 64).unwrap();
        let old_epoch = u64_at(&read(&name), 24);
        let old_map = old.map;
        std::mem::forget(old); // as a crashed process leaves it
        let new = Ring::create(&name, 2, 64).unwrap();
        assert_ne!(u64_at(&read(&name), 24), old_epoch);
        // The old mapping still reads its own ring.
        assert_eq!(unsafe { std::slice::from_raw_parts(old_map, 4) }, b"AVOA");
        drop(new);
    }
}
