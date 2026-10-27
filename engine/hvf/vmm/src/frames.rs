//! Frames of every scanout in shared memory, for the Runtime Daemon to hand
//! to App Shim windows (as IOSurfaces) without copying through a socket.
//!
//! One shared memory object per scanout and layout ("generation"), named
//! `/avo.<pid>.<index>.<generation>` (shm.rs), holding a 16 KiB header and three
//! frame buffers (triple buffering: the reader copies the newest buffer while
//! the guest fills another). Buffers start on host pages, so the GPU can
//! write a readback straight into one (render.rs). Header, little endian:
//!
//! ```text
//!  0  magic "AVOF"          24  format (0 = BGRA, 1 = RGBA)
//!  4  version (1)           28  buffer count (3)
//!  8  generation            32  offset of buffer 0 (16384)
//! 12  width                 36  bytes per buffer (multiple of 16384)
//! 16  height                40  index of the newest complete buffer
//! 20  bytes per row         48  frames published (u64; 0 = none yet)
//! ```
//!
//! Subscribers on the control socket hear `frames <index> <generation>
//! <width> <height> <stride> <format> shm:<name>` when a layout appears,
//! `frame <index> <sequence>` for every frame (a subscriber that reads too
//! slowly gets only the newest, control.rs) and `frames-off <index>` when
//! the scanout is unplugged and its memory's name removed.

use crate::virtio::gpu::{Format, Frame, FrameSink, FrameTarget, MAX_SCANOUTS};
use std::path::{Path, PathBuf};
use std::sync::atomic::{Ordering, fence};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

const MAGIC: &[u8; 4] = b"AVOF";
/// Apple silicon's page: what memory the GPU imports must start and end on.
const PAGE: usize = 16384;
const HEADER: usize = PAGE;
const BUFFERS: usize = 3;

unsafe extern "C" {
    fn munmap(addr: *mut u8, len: usize) -> i32;
}

/// Where events go (the control server's subscribers).
pub type EventSink = Arc<dyn Fn(String) + Send + Sync>;

/// What the renderer calls for each buffer of a mapping before it goes, to
/// let go of what it set up for writing into it (`set_unmap_hook`).
type UnmapHook = Box<dyn Fn(*mut u8) + Send + Sync>;
static UNMAP_HOOK: OnceLock<UnmapHook> = OnceLock::new();

/// Called with each frame buffer of a layout before its memory is unmapped
/// (the renderer imports buffers it reads frames back into).
pub fn set_unmap_hook(hook: UnmapHook) {
    let _ = UNMAP_HOOK.set(hook);
}

/// A layout's shared memory. A readback on another thread holds it too
/// (`FrameTarget`), so it stays mapped until that read is done even when
/// the layout is replaced meanwhile.
struct Mapping {
    map: *mut u8,
    len: usize,
    buffer_size: usize,
}

// Writers coordinate through `Surface` (one fill of a buffer at a time).
unsafe impl Send for Mapping {}
unsafe impl Sync for Mapping {}

impl Mapping {
    fn buffer(&self, index: usize) -> *mut u8 {
        unsafe { self.map.add(HEADER + index * self.buffer_size) }
    }
}

impl Drop for Mapping {
    fn drop(&mut self) {
        if let Some(hook) = UNMAP_HOOK.get() {
            for index in 0..BUFFERS {
                hook(self.buffer(index));
            }
        }
        unsafe { munmap(self.map, self.len) };
    }
}

struct Surface {
    /// Its shared memory's name (shm.rs).
    name: String,
    mapping: Arc<Mapping>,
    width: u32,
    height: u32,
    format: Format,
    buffer_size: usize,
    sequence: u64,
    generation: u32,
    /// Its `frames` event went out (just before its first frame).
    announced: bool,
    /// A readback on another thread is filling the next buffer
    /// (`reserve_frame`); nothing else may until it finishes.
    reserved: bool,
}

impl Surface {
    fn create(name: String, generation: u32, width: u32, height: u32, format: Format) -> std::io::Result<Surface> {
        let stride = width as usize * 4;
        let buffer_size = (stride * height as usize).next_multiple_of(PAGE);
        let len = HEADER + BUFFERS * buffer_size;
        // Shared memory, not a file: the disk would get every frame (shm.rs).
        let map = crate::shm::create(&name, len)?;
        let header = unsafe { std::slice::from_raw_parts_mut(map, HEADER) };
        header[0..4].copy_from_slice(MAGIC);
        let mut put = |at: usize, value: u32| header[at..at + 4].copy_from_slice(&value.to_le_bytes());
        put(4, 1);
        put(8, generation);
        put(12, width);
        put(16, height);
        put(20, stride as u32);
        put(24, if format.bgra_positions() == [0, 1, 2, 3] { 0 } else { 1 });
        put(28, BUFFERS as u32);
        put(32, HEADER as u32);
        put(36, buffer_size as u32);
        let mapping = Arc::new(Mapping { map, len, buffer_size });
        Ok(Surface { name, mapping, width, height, format, buffer_size, sequence: 0, generation, announced: false, reserved: false })
    }

    /// Where the next frame goes: never the newest buffer, which readers may
    /// be copying.
    fn next_pointer(&self) -> *mut u8 {
        // The last frame's counter before any write into this buffer. The
        // daemon reads the counter before and after copying the newest
        // buffer and drops the copy if it rose by more than one: this
        // buffer was the newest two frames ago, and the counter must show
        // that before a reader can see it being refilled.
        fence(Ordering::Release);
        self.mapping.buffer(((self.sequence + 1) % BUFFERS as u64) as usize)
    }

    fn next_buffer(&mut self) -> &mut [u8] {
        unsafe { std::slice::from_raw_parts_mut(self.next_pointer(), self.buffer_size) }
    }

    /// The newest published buffer.
    fn newest(&self) -> &[u8] {
        let index = (self.sequence % BUFFERS as u64) as usize;
        unsafe { std::slice::from_raw_parts(self.mapping.buffer(index), self.buffer_size) }
    }

    /// Copies a frame into the next buffer and publishes it, `rotate`d as
    /// `stored` says.
    fn publish(&mut self, frame: &Frame, rotate: bool) -> u64 {
        let row = self.width as usize * 4;
        let height = self.height as usize;
        let target = self.next_buffer();
        for y in 0..height {
            target[y * row..(y + 1) * row].copy_from_slice(&frame.pixels[y * frame.stride..y * frame.stride + row]);
        }
        if rotate {
            alpha_last(&mut target[..row * height]);
        }
        self.publish_next()
    }

    /// Publishes what was written into `next_buffer`.
    fn publish_next(&mut self) -> u64 {
        let next = ((self.sequence + 1) % BUFFERS as u64) as usize;
        self.sequence += 1;
        let header = unsafe { std::slice::from_raw_parts_mut(self.mapping.map, HEADER) };
        // Buffer contents before the index, the index before the sequence.
        fence(Ordering::Release);
        header[40..44].copy_from_slice(&(next as u32).to_le_bytes());
        fence(Ordering::Release);
        header[48..56].copy_from_slice(&self.sequence.to_le_bytes());
        self.sequence
    }
}

impl Drop for Surface {
    fn drop(&mut self) {
        // The memory goes with the last holder of `mapping`; readers keep
        // their own mapping; the name goes away with the layout.
        crate::shm::unlink(&self.name);
    }
}

/// The layout the buffers hold for frames in `format`, and whether pixels
/// are rotated on the way in. The header knows only BGRA and RGBA, so the
/// rare layouts that start with alpha (A8R8G8B8, A8B8G8R8 and their X
/// forms) move it to the end: ARGB becomes RGBA, ABGR becomes BGRA.
fn stored(format: Format) -> (Format, bool) {
    match format {
        Format::Argb => (Format::Rgba, true),
        Format::Xrgb => (Format::Rgbx, true),
        Format::Abgr => (Format::Bgra, true),
        Format::Xbgr => (Format::Bgrx, true),
        other => (other, false),
    }
}

/// Moves the first byte of every pixel to its end.
fn alpha_last(pixels: &mut [u8]) {
    for pixel in pixels.chunks_exact_mut(4) {
        pixel.rotate_left(1);
    }
}

pub struct SharedFrames {
    /// The guest fills buffers declared as B8G8R8A8 with R8G8B8A8 bytes (and
    /// the other way round): report what the bytes really are.
    swap_red_blue: bool,
    surfaces: Vec<Option<Surface>>,
    /// When making a scanout's shared memory last failed: tried again a
    /// second later, not on every frame, and logged once until it works.
    failed: Vec<Option<Instant>>,
    generation: u32,
    events: Arc<Mutex<Option<EventSink>>>,
    /// The `frames` event of each live layout, for late subscribers.
    layouts: Arc<Mutex<Vec<Option<String>>>>,
    /// Latest frame per scanout as BMP on request (bring-up aid).
    snapshot_requests: Arc<Mutex<Vec<(usize, PathBuf)>>>,
    sticky: Arc<Mutex<Vec<String>>>,
}

/// Lets the control server subscribe to events and ask for snapshots.
#[derive(Clone)]
pub struct FrameHandle {
    events: Arc<Mutex<Option<EventSink>>>,
    layouts: Arc<Mutex<Vec<Option<String>>>>,
    snapshot_requests: Arc<Mutex<Vec<(usize, PathBuf)>>>,
    /// State events (`gpu active …`, `gpu first-frame …`) that every new
    /// subscriber hears again after the layouts, one per kind.
    sticky: Arc<Mutex<Vec<String>>>,
}

impl FrameHandle {
    pub fn set_events(&self, sink: EventSink) {
        *self.events.lock().unwrap() = Some(sink);
    }

    /// `frames` events describing every layout that exists now, then the
    /// sticky events.
    pub fn current_layouts(&self) -> Vec<String> {
        let mut events: Vec<String> = self.layouts.lock().unwrap().iter().flatten().cloned().collect();
        events.extend(self.sticky.lock().unwrap().iter().cloned());
        events
    }

    /// Sends an event and keeps it for later subscribers, replacing the
    /// one of the same kind (its first two words).
    pub fn emit_sticky(&self, event: String) {
        let kind = |line: &str| line.split(' ').take(2).collect::<Vec<_>>().join(" ");
        {
            let mut sticky = self.sticky.lock().unwrap();
            sticky.retain(|line| kind(line) != kind(&event));
            sticky.push(event.clone());
        }
        self.emit(event);
    }

    /// Writes the next frame of `scanout` to `path` as a BMP.
    pub fn snapshot(&self, scanout: usize, path: PathBuf) {
        self.snapshot_requests.lock().unwrap().push((scanout, path));
    }

    /// Sends an event that is not about frames to the subscribers.
    pub fn emit(&self, event: String) {
        if let Some(sink) = self.events.lock().unwrap().as_ref() {
            sink(event);
        }
    }
}

impl SharedFrames {
    pub fn new(directory: &Path, swap_red_blue: bool) -> std::io::Result<SharedFrames> {
        std::fs::create_dir_all(directory)?;
        // Layout files from an earlier version, before shared memory, are stale.
        for entry in std::fs::read_dir(directory)?.flatten() {
            if entry.path().extension().is_some_and(|e| e == "frames") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
        Ok(SharedFrames {
            swap_red_blue,
            surfaces: (0..MAX_SCANOUTS).map(|_| None).collect(),
            failed: vec![None; MAX_SCANOUTS],
            generation: 0,
            events: Arc::new(Mutex::new(None)),
            layouts: Arc::new(Mutex::new(vec![None; MAX_SCANOUTS])),
            snapshot_requests: Arc::new(Mutex::new(Vec::new())),
            sticky: Arc::new(Mutex::new(Vec::new())),
        })
    }

    pub fn handle(&self) -> FrameHandle {
        FrameHandle {
            events: self.events.clone(),
            layouts: self.layouts.clone(),
            snapshot_requests: self.snapshot_requests.clone(),
            sticky: self.sticky.clone(),
        }
    }

    fn emit(&self, event: String) {
        if let Some(sink) = self.events.lock().unwrap().as_ref() {
            sink(event);
        }
    }

    /// Makes sure `index` has a surface of this layout: a new generation
    /// when it changed (announced with its first frame). False if the
    /// shared memory could not be made.
    fn ensure_surface(&mut self, index: usize, width: u32, height: u32, format: Format) -> bool {
        let stale = match &self.surfaces[index] {
            Some(s) => s.width != width || s.height != height || s.format != format,
            None => true,
        };
        if stale {
            if self.failed[index].is_some_and(|at| at.elapsed() < Duration::from_secs(1)) {
                return false;
            }
            self.generation += 1;
            let name = crate::shm::name(&format!("{index}.{}", self.generation));
            match Surface::create(name, self.generation, width, height, format) {
                Ok(surface) => {
                    self.surfaces[index] = Some(surface);
                    self.failed[index] = None;
                }
                Err(e) => {
                    if self.failed[index].replace(Instant::now()).is_none() {
                        eprintln!("[vmm] frames for scanout {index}: {e}");
                    }
                    return false;
                }
            }
        }
        true
    }

    /// Sends the `frames` event of a new layout before its first frame.
    fn announce(&mut self, index: usize) {
        let surface = self.surfaces[index].as_mut().unwrap();
        if surface.announced {
            return;
        }
        surface.announced = true;
        let format = if surface.format.bgra_positions() == [0, 1, 2, 3] { 0 } else { 1 };
        let event = format!(
            "frames {index} {} {} {} {} {format} {}",
            surface.generation,
            surface.width,
            surface.height,
            surface.width * 4,
            crate::shm::location(&surface.name)
        );
        self.layouts.lock().unwrap()[index] = Some(event.clone());
        self.emit(event);
    }

    /// Snapshot paths waiting for the next frame of `index`.
    fn take_snapshots(&self, index: usize) -> Vec<PathBuf> {
        let mut pending = self.snapshot_requests.lock().unwrap();
        let (now, later): (Vec<_>, Vec<_>) = pending.drain(..).partition(|(scanout, _)| *scanout == index);
        *pending = later;
        now.into_iter().map(|(_, path)| path).collect()
    }
}

impl FrameSink for SharedFrames {
    fn scanout_removed(&mut self, scanout: usize) {
        // Dropping the surface unmaps it and deletes its file; readers keep
        // their own mapping until they let go.
        if self.surfaces.get_mut(scanout).and_then(Option::take).is_some() {
            self.layouts.lock().unwrap()[scanout] = None;
            self.emit(format!("frames-off {scanout}"));
        }
    }

    fn frame(&mut self, frame: Frame) {
        let frame = if self.swap_red_blue { Frame { format: frame.format.swapping_red_blue(), ..frame } } else { frame };
        let index = frame.scanout;
        let (format, rotate) = stored(frame.format);
        if !self.ensure_surface(index, frame.width, frame.height, format) || self.surfaces[index].as_ref().unwrap().reserved {
            return;
        }
        self.announce(index);
        let sequence = self.surfaces[index].as_mut().unwrap().publish(&frame, rotate);
        self.emit(format!("frame {index} {sequence}"));
        for path in self.take_snapshots(index) {
            let _ = std::fs::write(&path, bmp(&frame));
        }
    }

    /// Fills the next shared buffer in place (GPU readback): no copy.
    fn fill_frame(&mut self, scanout: usize, width: u32, height: u32, format: Format, fill: &mut dyn FnMut(&mut [u8]) -> bool) -> bool {
        let format = if self.swap_red_blue { format.swapping_red_blue() } else { format };
        let (format, rotate) = stored(format);
        // A readback on another thread fills the next buffer: this frame is
        // older than the one it brings.
        if scanout >= MAX_SCANOUTS || !self.ensure_surface(scanout, width, height, format) || self.surfaces[scanout].as_ref().unwrap().reserved {
            return false;
        }
        let len = width as usize * height as usize * 4;
        let buffer = &mut self.surfaces[scanout].as_mut().unwrap().next_buffer()[..len];
        if !fill(buffer) {
            return false;
        }
        if rotate {
            alpha_last(buffer);
        }
        self.publish_filled(scanout);
        true
    }

    fn reserve_frame(&mut self, scanout: usize, width: u32, height: u32, format: Format) -> Option<FrameTarget> {
        let format = if self.swap_red_blue { format.swapping_red_blue() } else { format };
        let (format, rotate) = stored(format);
        if scanout >= MAX_SCANOUTS || !self.ensure_surface(scanout, width, height, format) {
            return None;
        }
        let surface = self.surfaces[scanout].as_mut().unwrap();
        if surface.reserved {
            return None;
        }
        surface.reserved = true;
        Some(FrameTarget {
            scanout,
            pixels: surface.next_pointer(),
            len: surface.buffer_size,
            rotate,
            generation: surface.generation,
            keep: surface.mapping.clone(),
        })
    }

    fn finish_frame(&mut self, target: FrameTarget, filled: bool) -> bool {
        let scanout = target.scanout;
        // The layout changed meanwhile: the frame went into memory nobody
        // reads any more.
        let Some(surface) = self.surfaces.get_mut(scanout).and_then(Option::as_mut).filter(|s| s.generation == target.generation) else {
            return false;
        };
        surface.reserved = false;
        if !filled {
            return false;
        }
        if target.rotate {
            let len = surface.width as usize * surface.height as usize * 4;
            alpha_last(unsafe { std::slice::from_raw_parts_mut(target.pixels, len) });
        }
        self.publish_filled(scanout);
        true
    }
}

impl SharedFrames {
    /// Publishes what was written into the next buffer of `scanout`, after
    /// its layout's `frames` event when that has not gone out yet.
    fn publish_filled(&mut self, scanout: usize) {
        self.announce(scanout);
        let sequence = self.surfaces[scanout].as_mut().unwrap().publish_next();
        self.emit(format!("frame {scanout} {sequence}"));
        let snapshots = self.take_snapshots(scanout);
        if !snapshots.is_empty() {
            let surface = self.surfaces[scanout].as_ref().unwrap();
            let frame = Frame { scanout, width: surface.width, height: surface.height, stride: surface.width as usize * 4, format: surface.format, pixels: surface.newest() };
            let image = bmp(&frame);
            for path in snapshots {
                let _ = std::fs::write(&path, &image);
            }
        }
    }
}

/// A top-down 32-bit BMP of a frame (macOS Preview and `sips` read it).
pub fn bmp(frame: &Frame) -> Vec<u8> {
    let (w, h) = (frame.width as usize, frame.height as usize);
    let size = (w * h * 4) as u32;
    let mut out = Vec::with_capacity(54 + w * h * 4);
    out.extend_from_slice(b"BM");
    out.extend_from_slice(&(54 + size).to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&54u32.to_le_bytes());
    out.extend_from_slice(&40u32.to_le_bytes());
    out.extend_from_slice(&(w as i32).to_le_bytes());
    out.extend_from_slice(&(-(h as i32)).to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&32u16.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&size.to_le_bytes());
    out.extend_from_slice(&[0u8; 16]);
    let [b, g, r, _] = frame.format.bgra_positions();
    for y in 0..h {
        for px in frame.pixels[y * frame.stride..y * frame.stride + w * 4].chunks_exact(4) {
            out.extend_from_slice(&[px[b], px[g], px[r], 0xff]);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_are_published_in_shared_memory() {
        let dir = std::env::temp_dir().join(format!("avo-frames-test-{}", std::process::id()));
        let mut frames = SharedFrames::new(&dir, false).unwrap();
        let events = Arc::new(Mutex::new(Vec::new()));
        let collected = events.clone();
        frames.handle().set_events(Arc::new(move |e| collected.lock().unwrap().push(e)));

        // A 2×2 frame inside a wider (stride 16) resource.
        let pixels: Vec<u8> = (0..32).collect();
        frames.frame(Frame { scanout: 1, width: 2, height: 2, stride: 16, format: Format::Bgra, pixels: &pixels });
        let events = events.lock().unwrap().clone();
        assert_eq!(events.len(), 2);
        let parts: Vec<&str> = events[0].splitn(8, ' ').collect();
        assert_eq!(&parts[..2], &["frames", "1"]);
        assert_eq!(&parts[3..6], &["2", "2", "8"]);
        assert_eq!(events[1], "frame 1 1");

        let data = layout_bytes(parts[7]);
        assert_eq!(&data[0..4], b"AVOF");
        let u32_at = |at: usize| u32::from_le_bytes(data[at..at + 4].try_into().unwrap());
        assert_eq!((u32_at(12), u32_at(16), u32_at(20)), (2, 2, 8));
        let latest = u32_at(40) as usize;
        assert_eq!(u64::from_le_bytes(data[48..56].try_into().unwrap()), 1);
        let buffer = &data[HEADER + latest * u32_at(36) as usize..];
        assert_eq!(&buffer[0..8], &pixels[0..8]);
        assert_eq!(&buffer[8..16], &pixels[16..24], "rows are packed without the resource padding");
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A layout's memory, read as the daemon does: by the name in its event.
    fn layout_bytes(location: &str) -> Vec<u8> {
        crate::shm::read(location.strip_prefix("shm:").expect("a shared memory layout")).unwrap()
    }

    fn collecting(name: &str) -> (SharedFrames, Arc<Mutex<Vec<String>>>, PathBuf) {
        let dir = std::env::temp_dir().join(format!("avo-frames-{name}-{}", std::process::id()));
        let frames = SharedFrames::new(&dir, false).unwrap();
        let events = Arc::new(Mutex::new(Vec::new()));
        let collected = events.clone();
        frames.handle().set_events(Arc::new(move |e| collected.lock().unwrap().push(e)));
        (frames, events, dir)
    }

    #[test]
    fn filled_frames_are_published_in_place() {
        let (mut frames, events, dir) = collecting("fill");
        // A failed fill publishes nothing, not even the layout.
        assert!(!frames.fill_frame(0, 2, 2, Format::Rgba, &mut |_| false));
        assert!(events.lock().unwrap().is_empty());

        let filled = frames.fill_frame(0, 2, 2, Format::Rgba, &mut |buffer| {
            assert_eq!(buffer.len(), 16, "tight rows");
            buffer.copy_from_slice(&[7; 16]);
            true
        });
        assert!(filled);
        let events = events.lock().unwrap().clone();
        assert_eq!(events.len(), 2);
        assert!(events[0].starts_with("frames 0 "), "layout first: {}", events[0]);
        assert_eq!(events[0].split(' ').nth(6), Some("1"), "RGBA, the resource's own order");
        assert_eq!(events[1], "frame 0 1");
        let data = layout_bytes(events[0].splitn(8, ' ').nth(7).unwrap());
        let latest = u32::from_le_bytes(data[40..44].try_into().unwrap()) as usize;
        let size = u32::from_le_bytes(data[36..40].try_into().unwrap()) as usize;
        assert_eq!(&data[HEADER + latest * size..][..16], &[7; 16]);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn layouts_that_start_with_alpha_are_stored_as_bgra_or_rgba() {
        let (mut frames, events, dir) = collecting("alpha-first");
        // A8R8G8B8 bytes: alpha, red, green, blue.
        let argb = [0xff, 0x10, 0x20, 0x30];
        frames.frame(Frame { scanout: 0, width: 1, height: 1, stride: 4, format: Format::Argb, pixels: &argb });
        // X8B8G8R8 read back in place: unused, blue, green, red.
        assert!(frames.fill_frame(1, 1, 1, Format::Xbgr, &mut |buffer| {
            buffer.copy_from_slice(&[0, 0x30, 0x20, 0x10]);
            true
        }));
        let contents = |layout: &str| {
            let data = layout_bytes(layout.splitn(8, ' ').nth(7).unwrap());
            let u32_at = |at: usize| u32::from_le_bytes(data[at..at + 4].try_into().unwrap());
            let newest = HEADER + u32_at(40) as usize * u32_at(36) as usize;
            (u32_at(24), data[newest..newest + 4].to_vec())
        };
        let events = events.lock().unwrap().clone();
        let layouts: Vec<&String> = events.iter().filter(|e| e.starts_with("frames ")).collect();
        assert_eq!(layouts[0].split(' ').nth(6), Some("1"));
        assert_eq!(contents(layouts[0]), (1, vec![0x10, 0x20, 0x30, 0xff]), "RGBA");
        assert_eq!(layouts[1].split(' ').nth(6), Some("0"));
        assert_eq!(contents(layouts[1]), (0, vec![0x30, 0x20, 0x10, 0]), "BGRX");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn frames_read_back_elsewhere_are_published_when_finished() {
        let (mut frames, events, dir) = collecting("reserve");
        let target = frames.reserve_frame(0, 3, 2, Format::Bgra).expect("a buffer");
        assert_eq!(target.pixels as usize % PAGE, 0, "buffers start on a page");
        assert_eq!(target.len % PAGE, 0, "and end on one");
        assert!(target.len >= 3 * 2 * 4);
        // The scanout is the readback's until it finishes.
        assert!(frames.reserve_frame(0, 3, 2, Format::Bgra).is_none());
        assert!(!frames.fill_frame(0, 3, 2, Format::Bgra, &mut |_| true));
        assert!(events.lock().unwrap().is_empty(), "nothing yet");

        unsafe { std::slice::from_raw_parts_mut(target.pixels, 24) }.copy_from_slice(&[9; 24]);
        assert!(frames.finish_frame(target, true));
        let events = events.lock().unwrap().clone();
        assert_eq!(events.len(), 2);
        assert_eq!(events[1], "frame 0 1");
        let data = layout_bytes(events[0].splitn(8, ' ').nth(7).unwrap());
        let latest = u32::from_le_bytes(data[40..44].try_into().unwrap()) as usize;
        let size = u32::from_le_bytes(data[36..40].try_into().unwrap()) as usize;
        assert_eq!(u32::from_le_bytes(data[32..36].try_into().unwrap()) as usize, HEADER);
        assert_eq!(&data[HEADER + latest * size..][..24], &[9; 24]);

        // A readback that failed publishes nothing and frees the scanout.
        let target = frames.reserve_frame(0, 3, 2, Format::Bgra).unwrap();
        assert!(!frames.finish_frame(target, false));
        assert!(frames.reserve_frame(0, 3, 2, Format::Bgra).is_some());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_readback_into_a_replaced_layout_is_dropped_and_its_memory_kept_until_then() {
        let (mut frames, events, dir) = collecting("replaced");
        let target = frames.reserve_frame(0, 2, 2, Format::Bgra).unwrap();
        // The display was resized while the GPU copied.
        assert!(frames.fill_frame(0, 4, 4, Format::Bgra, &mut |_| true));
        // Still mapped: the target holds the old layout's memory.
        unsafe { std::slice::from_raw_parts_mut(target.pixels, 16) }.fill(1);
        assert!(!frames.finish_frame(target, true), "the old layout gets no frame");
        let frames_events: Vec<String> = events.lock().unwrap().iter().filter(|e| e.starts_with("frame ")).cloned().collect();
        assert_eq!(frames_events, ["frame 0 1"], "only the new layout's");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn sticky_events_reach_late_subscribers() {
        let (frames, events, dir) = collecting("sticky");
        let handle = frames.handle();
        handle.emit_sticky("gpu active Apple M4 Pro".into());
        handle.emit_sticky("gpu first-frame 0".into());
        handle.emit_sticky("gpu first-frame 1".into());
        assert_eq!(events.lock().unwrap().len(), 3, "each one is sent");
        assert_eq!(handle.current_layouts(), ["gpu active Apple M4 Pro", "gpu first-frame 1"], "one per kind");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_layout_that_cannot_be_made_leaves_no_file_and_waits_before_another_try() {
        let (mut frames, events, dir) = collecting("refused");
        // Far past any address space: the file is made, its mapping never.
        let huge = 1 << 28;
        assert!(!frames.fill_frame(0, huge, huge, Format::Rgba, &mut |_| true));
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0, "no file left behind");
        let generation = frames.generation;
        assert!(!frames.fill_frame(0, huge, huge, Format::Rgba, &mut |_| true));
        assert_eq!(frames.generation, generation, "not tried again on the next frame");
        assert!(events.lock().unwrap().is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
