//! The Mac's side of Android's cameras: which one streams, at what size,
//! and the JPEG frames the daemon sends for it.
//!
//! With `--cameras`, Android gets two V4L2 capture devices (virtio/media.rs)
//! instead of Cuttlefish's emulated cameras: the image's external camera HAL
//! (the `.v4l2` variant of its camera APEX) opens them as /dev/video1 (the
//! back camera) and /dev/video2 (the front one; /dev/video0 is the kernel's
//! v4l2loopback). They stream Motion-JPEG, which is what that HAL reads.
//!
//! When Android starts one (VIDIOC_STREAMON), subscribers hear
//! `camera <index> on <width> <height> <fps>` (sticky; 0 is the back
//! camera, 1 the front one), and `camera <index> off` when it stops: the
//! daemon runs the source chosen for it (one of the Mac's cameras, or a
//! scene it draws) only then. Frames come back on a control connection that
//! sent `camera feed`: from then on it carries only frames, each a 16-byte
//! header (index, width, height, length; u32 little endian) and that many
//! bytes of JPEG.
//!
//! A device sends each new frame of its size as it comes. While none comes
//! (the Mac's camera is still starting, or nobody feeds it) it repeats the
//! last one for a while, and otherwise sends a plain gray picture at the
//! stream's rate: Android's camera never waits on the Mac, and the HAL,
//! which reads three frames before a stream counts as started, starts at
//! once. Everything here is the process's: a guest reboot keeps the
//! daemon's feed.

use std::io::Read;
use std::sync::{Arc, Condvar, LazyLock, Mutex};
use std::time::{Duration, Instant};

pub const CAMERAS: usize = 2;
pub const BACK: usize = 0;
pub const FRONT: usize = 1;

/// The largest frame a feed may send.
const MAX_FRAME: usize = 16 << 20;

/// Which cameras Android has (`--cameras`): each one present is fed by the
/// daemon; one that is not stays a device the HAL passes over, so the other
/// keeps its node and its facing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Present(pub [bool; CAMERAS]);

impl Present {
    /// `back,front`, `back`, `front` or `none`.
    pub fn parse(spec: &str) -> Result<Present, String> {
        let mut present = [false; CAMERAS];
        for word in spec.split(',') {
            match word {
                "back" => present[BACK] = true,
                "front" => present[FRONT] = true,
                "none" => {}
                _ => return Err(format!("unknown camera {word} (back, front or none)")),
            }
        }
        Ok(Present(present))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Format {
    pub width: u32,
    pub height: u32,
    pub fps: u32,
}

#[derive(Clone, Debug)]
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub jpeg: Arc<Vec<u8>>,
}

#[derive(Default)]
struct Slot {
    latest: Option<Frame>,
    /// Counts the frames fed so far.
    sequence: u64,
    streaming: Option<Format>,
}

type Events = Arc<dyn Fn(String) + Send + Sync>;

pub struct Hub {
    slots: Mutex<[Slot; CAMERAS]>,
    fed: Condvar,
    events: Mutex<Option<Events>>,
}

pub static HUB: LazyLock<Hub> = LazyLock::new(Hub::new);

impl Hub {
    pub fn new() -> Hub {
        Hub { slots: Mutex::default(), fed: Condvar::new(), events: Mutex::new(None) }
    }

    /// Where `camera … on|off` go (sticky events of the machine that runs).
    pub fn set_events(&self, events: Events) {
        *self.events.lock().unwrap() = Some(events);
    }

    /// Camera `index` streams in `format` now, or stopped (`None`).
    pub fn streaming(&self, index: usize, format: Option<Format>) {
        {
            let mut slots = self.slots.lock().unwrap();
            if slots[index].streaming == format {
                return;
            }
            slots[index].streaming = format;
            // A frame of the last stream is not one of this.
            slots[index].latest = None;
        }
        self.fed.notify_all();
        let event = match format {
            Some(f) => format!("camera {index} on {} {} {}", f.width, f.height, f.fps),
            None => format!("camera {index} off"),
        };
        if let Some(events) = self.events.lock().unwrap().as_ref() {
            events(event);
        }
    }

    pub fn push(&self, index: usize, frame: Frame) {
        let mut slots = self.slots.lock().unwrap();
        let slot = &mut slots[index];
        slot.latest = Some(frame);
        slot.sequence += 1;
        drop(slots);
        self.fed.notify_all();
    }

    /// The newest frame of camera `index` after the `after`-th, with its
    /// number, once there is one; `None` at `until`.
    pub fn wait(&self, index: usize, after: u64, until: Instant) -> Option<(u64, Frame)> {
        let mut slots = self.slots.lock().unwrap();
        loop {
            let slot = &slots[index];
            if slot.sequence > after
                && let Some(frame) = &slot.latest
            {
                return Some((slot.sequence, frame.clone()));
            }
            let now = Instant::now();
            if now >= until {
                return None;
            }
            slots = self.fed.wait_timeout(slots, until - now).unwrap().0;
        }
    }

    /// Wakes the devices' stream threads (one is stopping).
    pub fn wake(&self) {
        self.fed.notify_all();
    }
}

/// Reads frames off a `camera feed` connection until it closes.
pub fn read_feed(hub: &Hub, reader: &mut impl Read) -> Result<(), String> {
    let mut header = [0u8; 16];
    loop {
        match reader.read_exact(&mut header) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(e) => return Err(e.to_string()),
        }
        let word = |i: usize| u32::from_le_bytes(header[i * 4..i * 4 + 4].try_into().unwrap());
        let (index, width, height, length) = (word(0) as usize, word(1), word(2), word(3) as usize);
        if index >= CAMERAS || length > MAX_FRAME {
            return Err(format!("bad camera frame: camera {index}, {length} bytes"));
        }
        let mut jpeg = vec![0u8; length];
        reader.read_exact(&mut jpeg).map_err(|e| e.to_string())?;
        hub.push(index, Frame { width, height, jpeg: Arc::new(jpeg) });
    }
}

/// How long a device repeats the last frame before it sends gray.
pub const STALE: Duration = Duration::from_secs(2);

/// A baseline JPEG of `width`×`height` in one shade of gray (`luma`): what
/// a camera shows while it has no picture. Grayscale, with a quantization
/// table of ones and Huffman tables of the only codes it needs: the first
/// block's DC difference and then, for every block, "no difference" and
/// "end of block".
pub fn gray_jpeg(width: u32, height: u32, luma: u8) -> Vec<u8> {
    let mut out = vec![0xff, 0xd8];
    let mut segment = |marker: u8, body: &[u8]| {
        out.extend_from_slice(&[0xff, marker]);
        out.extend_from_slice(&((body.len() + 2) as u16).to_be_bytes());
        out.extend_from_slice(body);
    };
    let mut dqt = vec![0u8];
    dqt.extend_from_slice(&[1u8; 64]);
    segment(0xdb, &dqt);
    let (w, h) = (width.clamp(1, 0xffff) as u16, height.clamp(1, 0xffff) as u16);
    let mut sof = vec![8];
    sof.extend_from_slice(&h.to_be_bytes());
    sof.extend_from_slice(&w.to_be_bytes());
    sof.extend_from_slice(&[1, 1, 0x11, 0]);
    segment(0xc0, &sof);
    // The DC of a flat block is 8 × its level-shifted value (FDCT scaling).
    let dc = (luma as i32 - 128) * 8;
    let category = 32 - dc.unsigned_abs().leading_zeros();
    // DC: "0" is category 0, "10" the first block's.
    let mut dht = vec![0x00];
    let mut counts = [0u8; 16];
    counts[0] = 1;
    let mut symbols = vec![0u8];
    if category > 0 {
        counts[1] = 1;
        symbols.push(category as u8);
    }
    dht.extend_from_slice(&counts);
    dht.extend_from_slice(&symbols);
    // AC: "0" is end of block.
    dht.push(0x10);
    let mut ac = [0u8; 16];
    ac[0] = 1;
    dht.extend_from_slice(&ac);
    dht.push(0x00);
    segment(0xc4, &dht);
    segment(0xda, &[1, 1, 0x00, 0, 63, 0]);

    let mut bits = BitWriter::default();
    if category > 0 {
        bits.put(0b10, 2);
        // Negative values go as their one's complement.
        let signed = if dc < 0 { dc - 1 } else { dc };
        bits.put(signed as u32 & ((1 << category) - 1), category);
    } else {
        bits.put(0, 1);
    }
    bits.put(0, 1);
    let blocks = (width as u64).div_ceil(8) * (height as u64).div_ceil(8);
    for _ in 1..blocks {
        bits.put(0, 2);
    }
    out.extend_from_slice(&bits.finish());
    out.extend_from_slice(&[0xff, 0xd9]);
    out
}

/// Entropy-coded bits, MSB first, with 0xFF bytes stuffed.
#[derive(Default)]
struct BitWriter {
    bytes: Vec<u8>,
    current: u32,
    used: u32,
}

impl BitWriter {
    fn put(&mut self, value: u32, count: u32) {
        for i in (0..count).rev() {
            self.current = self.current << 1 | (value >> i & 1);
            self.used += 1;
            if self.used == 8 {
                self.byte();
            }
        }
    }

    fn byte(&mut self) {
        let byte = self.current as u8;
        self.bytes.push(byte);
        if byte == 0xff {
            self.bytes.push(0);
        }
        self.current = 0;
        self.used = 0;
    }

    /// The bits so far, the last byte padded with ones.
    fn finish(mut self) -> Vec<u8> {
        if self.used > 0 {
            let pad = 8 - self.used;
            self.current = self.current << pad | ((1 << pad) - 1);
            self.byte();
        }
        self.bytes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cameras_parse() {
        assert_eq!(Present::parse("back,front"), Ok(Present([true, true])));
        assert_eq!(Present::parse("front"), Ok(Present([false, true])));
        assert_eq!(Present::parse("none"), Ok(Present([false, false])));
        assert!(Present::parse("side").is_err());
    }

    #[test]
    fn gray_frames_are_small_baseline_jpegs() {
        let jpeg = gray_jpeg(1920, 1080, 128);
        assert_eq!(&jpeg[..2], [0xff, 0xd8]);
        assert_eq!(&jpeg[jpeg.len() - 2..], [0xff, 0xd9]);
        // SOF0 with the size, after SOI and the 69-byte DQT.
        assert_eq!(&jpeg[2 + 69..2 + 69 + 9], [0xff, 0xc0, 0, 11, 8, 0x04, 0x38, 0x07, 0x80]);
        // Mid gray: two bits a block, 240×135 blocks.
        assert!(jpeg.len() < 8300, "{}", jpeg.len());
        let dark = gray_jpeg(640, 480, 16);
        assert!(dark.windows(2).filter(|w| *w == [0xff, 0xd9]).count() == 1);
    }

    #[test]
    fn negative_dc_differences_go_as_ones_complement() {
        let mut bits = BitWriter::default();
        // -896 (luma 16) in 10 bits: -897 & 0x3ff = 0b0001111111.
        let dc: i32 = -896;
        bits.put((dc - 1) as u32 & 0x3ff, 10);
        assert_eq!(bits.finish(), [0b0001_1111, 0b1111_1111, 0]);
    }

    #[test]
    fn a_feed_hands_frames_to_their_camera() {
        let (hub, index, before) = (Hub::new(), FRONT, 0);
        let mut wire = Vec::new();
        for (i, jpeg) in [b"one".as_slice(), b"two"].iter().enumerate() {
            for word in [index as u32, 64 + i as u32, 48, jpeg.len() as u32] {
                wire.extend_from_slice(&word.to_le_bytes());
            }
            wire.extend_from_slice(jpeg);
        }
        read_feed(&hub, &mut wire.as_slice()).unwrap();
        let (sequence, frame) = hub.wait(index, before, Instant::now()).unwrap();
        assert_eq!(sequence, before + 2);
        assert_eq!((frame.width, frame.height, frame.jpeg.as_slice()), (65, 48, b"two".as_slice()));
        assert!(hub.wait(index, sequence, Instant::now() + Duration::from_millis(20)).is_none());
        assert!(hub.wait(BACK, 0, Instant::now()).is_none(), "the other camera has none");
        let bad = [9u8; 16];
        assert!(read_feed(&hub, &mut bad.as_slice()).is_err());
    }

    #[test]
    fn a_new_stream_forgets_the_last_frame_and_is_announced() {
        let hub = Hub::new();
        let heard = Arc::new(Mutex::new(Vec::new()));
        let sink = heard.clone();
        hub.set_events(Arc::new(move |event| sink.lock().unwrap().push(event)));
        hub.push(BACK, Frame { width: 640, height: 480, jpeg: Arc::new(vec![1]) });
        let format = Format { width: 1280, height: 720, fps: 30 };
        hub.streaming(BACK, Some(format));
        hub.streaming(BACK, Some(format));
        assert!(hub.wait(BACK, 0, Instant::now()).is_none());
        hub.streaming(BACK, None);
        assert_eq!(*heard.lock().unwrap(), ["camera 0 on 1280 720 30", "camera 0 off"]);
    }
}
