//! virtio-media (device 48): one of Android's cameras (camera.rs) as a
//! V4L2 capture device, in ChromeOS's virtio-media protocol
//! (github.com/chromeos/virtio-media, driver/protocol.h). The guest driver
//! turns every open, ioctl and mmap of /dev/videoN into a command on the
//! commandq; finished buffers go back as events on the eventq, which the
//! driver answers VIDIOC_DQBUF with. Payloads are the 64-bit layouts of
//! videodev2.h's structures.
//!
//! The device has what Android's external camera HAL uses: one format,
//! Motion-JPEG, in three sizes at 30 or 15 frames a second (ENUM_FMT,
//! ENUM_FRAMESIZES, ENUM_FRAMEINTERVALS), G/S/TRY_FMT, G/S_PARM, MMAP
//! buffers (REQBUFS, QUERYBUF, QBUF), STREAMON and STREAMOFF, and one
//! camera input; no controls. Buffers live in its shared memory region
//! (shmid 0): host memory mapped into the BAR whole, so
//! VIRTIO_MEDIA_CMD_MMAP only says where a buffer is. A camera Android does
//! not have (`--cameras`) lists no format, and the HAL passes it over.
//!
//! Several sessions may be open, each with its own format and buffers; one
//! streams at a time (EBUSY for another). Its stream thread fills its
//! queued buffers from the camera hub, as camera.rs describes.

use super::gpu::hostmem::Mapper;
use super::queue::Queue;
use super::{Active, Interrupt, VirtioDevice};
use crate::camera::{self, Format, Hub};
use crate::memory::GuestMemory;
use std::collections::{BTreeMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const TYPE_MEDIA: u16 = 48;

/// The shared memory region: room for two sessions' buffers at 1080p.
const REGION_SIZE: u64 = 64 << 20;
/// Buffers start on 64 KiB boundaries (whole guest pages of any size).
const ALIGN: u64 = 64 << 10;
const MAX_BUFFERS: usize = 8;
const SIZES: [(u32, u32); 3] = [(640, 480), (1280, 720), (1920, 1080)];
const RATES: [u32; 2] = [30, 15];

const CMD_OPEN: u32 = 1;
const CMD_CLOSE: u32 = 2;
const CMD_IOCTL: u32 = 3;
const CMD_MMAP: u32 = 4;
const CMD_MUNMAP: u32 = 5;
const EVT_DQBUF: u32 = 1;
/// `struct virtio_media_event_dqbuf`: header, v4l2_buffer, 8 planes.
const EVENT_SIZE: usize = 8 + BUFFER_SIZE + 8 * 64;
/// Events kept while the driver has no event buffer (it queues 16).
const MAX_EVENTS: usize = 64;

// videodev2.h: ioctl numbers, and the 64-bit sizes of their payloads.
const VIDIOC_ENUM_FMT: u32 = 2;
const VIDIOC_G_FMT: u32 = 4;
const VIDIOC_S_FMT: u32 = 5;
const VIDIOC_REQBUFS: u32 = 8;
const VIDIOC_QUERYBUF: u32 = 9;
const VIDIOC_QBUF: u32 = 15;
const VIDIOC_STREAMON: u32 = 18;
const VIDIOC_STREAMOFF: u32 = 19;
const VIDIOC_G_PARM: u32 = 21;
const VIDIOC_S_PARM: u32 = 22;
const VIDIOC_ENUMINPUT: u32 = 26;
const VIDIOC_G_CTRL: u32 = 27;
const VIDIOC_S_CTRL: u32 = 28;
const VIDIOC_QUERYCTRL: u32 = 36;
const VIDIOC_QUERYMENU: u32 = 37;
const VIDIOC_G_INPUT: u32 = 38;
const VIDIOC_S_INPUT: u32 = 39;
const VIDIOC_TRY_FMT: u32 = 64;
const VIDIOC_G_EXT_CTRLS: u32 = 71;
const VIDIOC_TRY_EXT_CTRLS: u32 = 73;
const VIDIOC_ENUM_FRAMESIZES: u32 = 74;
const VIDIOC_ENUM_FRAMEINTERVALS: u32 = 75;
const VIDIOC_SUBSCRIBE_EVENT: u32 = 90;
const VIDIOC_UNSUBSCRIBE_EVENT: u32 = 91;
const VIDIOC_G_SELECTION: u32 = 94;
const VIDIOC_S_SELECTION: u32 = 95;
const VIDIOC_QUERY_EXT_CTRL: u32 = 103;
const BUFFER_SIZE: usize = 88;

const BUF_TYPE_VIDEO_CAPTURE: u32 = 1;
const MEMORY_MMAP: u32 = 1;
const FIELD_NONE: u32 = 1;
const PIX_FMT_MJPEG: u32 = u32::from_le_bytes(*b"MJPG");
const COLORSPACE_SRGB: u32 = 8;
const CAP_VIDEO_CAPTURE: u32 = 0x1;
const CAP_STREAMING: u32 = 0x0400_0000;
const CAP_TIMEPERFRAME: u32 = 0x1000;
const FMT_FLAG_COMPRESSED: u32 = 0x1;
const FRMSIZE_TYPE_DISCRETE: u32 = 1;
const FRMIVAL_TYPE_DISCRETE: u32 = 1;
const BUF_FLAG_MAPPED: u32 = 0x1;
const BUF_FLAG_QUEUED: u32 = 0x2;
const BUF_CAP_SUPPORTS_MMAP: u32 = 0x1;
const INPUT_TYPE_CAMERA: u32 = 2;

const ENOMEM: u32 = 12;
const EBUSY: u32 = 16;
const EINVAL: u32 = 22;
const ENOTTY: u32 = 25;

fn get(bytes: &[u8], at: usize) -> u32 {
    bytes.get(at..at + 4).map_or(0, |b| u32::from_le_bytes(b.try_into().unwrap()))
}

fn put(bytes: &mut [u8], at: usize, value: u32) {
    bytes[at..at + 4].copy_from_slice(&value.to_le_bytes());
}

fn put_name(bytes: &mut [u8], at: usize, len: usize, name: &str) {
    let field = &mut bytes[at..at + len];
    field.fill(0);
    let n = name.len().min(len - 1);
    field[..n].copy_from_slice(&name.as_bytes()[..n]);
}

/// A response header with `status` (0 or an errno), then `payload`.
fn response(status: u32, payload: &[u8]) -> Vec<u8> {
    let mut out = vec![0u8; 8];
    put(&mut out, 0, status);
    out.extend_from_slice(payload);
    out
}

/// A payload of exactly `len` bytes from what the driver sent.
fn payload(bytes: &[u8], len: usize) -> Vec<u8> {
    let mut out = bytes[..bytes.len().min(len)].to_vec();
    out.resize(len, 0);
    out
}

fn image_size(width: u32, height: u32) -> u32 {
    width * height * 3 / 2
}

/// The supported size for a request: the same, else the smallest that
/// holds it, else the largest.
fn nearest_size(width: u32, height: u32) -> (u32, u32) {
    SIZES.iter().copied().find(|&(w, h)| w >= width && h >= height).unwrap_or(SIZES[SIZES.len() - 1])
}

/// The device's buffer memory: host pages mapped at the BAR.
struct Region {
    host: *mut u8,
    len: u64,
    base: Option<u64>,
    mapper: Box<dyn Mapper>,
}

// SAFETY: the pointer is the region's own anonymous mapping; State's lock
// serializes every access.
unsafe impl Send for Region {}

impl Region {
    fn new(len: u64, mapper: Box<dyn Mapper>) -> Region {
        let host = unsafe {
            libc::mmap(std::ptr::null_mut(), len as usize, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_PRIVATE | libc::MAP_ANON, -1, 0)
        };
        assert!(host != libc::MAP_FAILED, "camera buffer memory");
        Region { host: host.cast(), len, base: None, mapper }
    }

    /// Maps the region where the guest put the BAR (or nowhere).
    fn place(&mut self, base: Option<u64>) {
        if self.base == base {
            return;
        }
        if let Some(old) = self.base.take() {
            let _ = self.mapper.unmap(old, self.len);
        }
        if let Some(new) = base {
            match self.mapper.map(self.host as usize, new, self.len) {
                Ok(()) => self.base = Some(new),
                Err(e) => eprintln!("[vmm] camera buffers at {new:#x}: {e}"),
            }
        }
    }

    fn write(&mut self, offset: u64, data: &[u8]) {
        assert!(offset + data.len() as u64 <= self.len);
        unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), self.host.add(offset as usize), data.len()) };
    }

    #[cfg(test)]
    fn read(&self, offset: u64, len: usize) -> Vec<u8> {
        unsafe { std::slice::from_raw_parts(self.host.add(offset as usize), len) }.to_vec()
    }
}

impl Drop for Region {
    fn drop(&mut self) {
        self.place(None);
        unsafe { libc::munmap(self.host.cast(), self.len as usize) };
    }
}

struct Buffer {
    offset: u64,
    length: u32,
    queued: bool,
    bytesused: u32,
}

struct Session {
    format: Format,
    buffers: Vec<Buffer>,
    /// Queued buffers, oldest first.
    queue: VecDeque<usize>,
    streaming: bool,
    sequence: u32,
}

impl Session {
    fn new() -> Session {
        Session { format: Format { width: 1280, height: 720, fps: 30 }, buffers: Vec::new(), queue: VecDeque::new(), streaming: false, sequence: 0 }
    }

    /// `struct v4l2_buffer` for buffer `index`.
    fn describe(&self, index: usize) -> [u8; BUFFER_SIZE] {
        let buffer = &self.buffers[index];
        let mut out = [0u8; BUFFER_SIZE];
        put(&mut out, 0, index as u32);
        put(&mut out, 4, BUF_TYPE_VIDEO_CAPTURE);
        put(&mut out, 8, buffer.bytesused);
        put(&mut out, 12, BUF_FLAG_MAPPED | if buffer.queued { BUF_FLAG_QUEUED } else { 0 });
        put(&mut out, 16, FIELD_NONE);
        put(&mut out, 60, MEMORY_MMAP);
        out[64..72].copy_from_slice(&buffer.offset.to_le_bytes());
        put(&mut out, 72, buffer.length);
        out
    }
}

struct State {
    index: usize,
    present: bool,
    hub: &'static Hub,
    active: Option<Active>,
    sessions: BTreeMap<u32, Session>,
    next_session: u32,
    /// DQBUF events waiting for an event buffer, with their session.
    events: VecDeque<(u32, Vec<u8>)>,
    /// The streaming session and its thread's stop flag.
    stream: Option<(u32, Arc<AtomicBool>)>,
    /// A stream thread to start once the command that asked is answered.
    start: Option<(u32, Format, Arc<AtomicBool>)>,
    region: Region,
}

impl State {
    fn command(&mut self, request: &[u8]) -> Vec<u8> {
        match get(request, 0) {
            CMD_OPEN => {
                self.next_session += 1;
                self.sessions.insert(self.next_session, Session::new());
                let mut out = response(0, &[0; 8]);
                put(&mut out, 8, self.next_session);
                out
            }
            CMD_CLOSE => {
                let id = get(request, 8);
                self.stop(id);
                self.sessions.remove(&id);
                Vec::new()
            }
            CMD_IOCTL => match self.ioctl(get(request, 8), get(request, 12), request.get(16..).unwrap_or(&[])) {
                Ok(payload) => response(0, &payload),
                Err(errno) => response(errno, &[]),
            },
            CMD_MMAP => {
                let (id, offset) = (get(request, 8), get(request, 16) as u64);
                let found = self.sessions.get(&id).and_then(|s| s.buffers.iter().find(|b| b.offset == offset));
                match found {
                    Some(buffer) => {
                        let mut out = response(0, &[0; 16]);
                        out[8..16].copy_from_slice(&buffer.offset.to_le_bytes());
                        out[16..24].copy_from_slice(&(buffer.length as u64).to_le_bytes());
                        out
                    }
                    None => response(EINVAL, &[]),
                }
            }
            CMD_MUNMAP => response(0, &[]),
            _ => response(ENOTTY, &[]),
        }
    }

    fn ioctl(&mut self, id: u32, code: u32, data: &[u8]) -> Result<Vec<u8>, u32> {
        if !self.sessions.contains_key(&id) {
            return Err(EINVAL);
        }
        let capture = |at: usize| if get(data, at) == BUF_TYPE_VIDEO_CAPTURE { Ok(()) } else { Err(EINVAL) };
        match code {
            VIDIOC_ENUM_FMT => {
                let mut out = payload(data, 64);
                capture(4)?;
                if !self.present || get(&out, 0) != 0 {
                    return Err(EINVAL);
                }
                put(&mut out, 8, FMT_FLAG_COMPRESSED);
                put_name(&mut out, 12, 32, "Motion-JPEG");
                put(&mut out, 44, PIX_FMT_MJPEG);
                Ok(out)
            }
            VIDIOC_G_FMT | VIDIOC_S_FMT | VIDIOC_TRY_FMT => {
                let mut out = payload(data, 208);
                capture(0)?;
                if !self.present {
                    return Err(EINVAL);
                }
                let session = self.sessions.get_mut(&id).unwrap();
                let mut format = session.format;
                if code != VIDIOC_G_FMT {
                    (format.width, format.height) = nearest_size(get(&out, 8), get(&out, 12));
                }
                if code == VIDIOC_S_FMT {
                    if session.streaming || !session.buffers.is_empty() {
                        return Err(EBUSY);
                    }
                    session.format = format;
                }
                out[8..56].fill(0);
                put(&mut out, 8, format.width);
                put(&mut out, 12, format.height);
                put(&mut out, 16, PIX_FMT_MJPEG);
                put(&mut out, 20, FIELD_NONE);
                put(&mut out, 28, image_size(format.width, format.height));
                put(&mut out, 32, COLORSPACE_SRGB);
                Ok(out)
            }
            VIDIOC_G_PARM | VIDIOC_S_PARM => {
                let mut out = payload(data, 204);
                capture(0)?;
                let session = self.sessions.get_mut(&id).unwrap();
                let (numerator, denominator) = (get(&out, 12), get(&out, 16));
                if code == VIDIOC_S_PARM && numerator != 0 {
                    let asked = denominator as f64 / numerator as f64;
                    let nearest = RATES.iter().copied().min_by(|a, b| (*a as f64 - asked).abs().total_cmp(&(*b as f64 - asked).abs()));
                    session.format.fps = nearest.unwrap();
                }
                out[4..204].fill(0);
                put(&mut out, 4, CAP_TIMEPERFRAME);
                put(&mut out, 12, 1);
                put(&mut out, 16, session.format.fps);
                Ok(out)
            }
            VIDIOC_ENUM_FRAMESIZES => {
                let mut out = payload(data, 44);
                let index = get(&out, 0) as usize;
                if !self.present || get(&out, 4) != PIX_FMT_MJPEG || index >= SIZES.len() {
                    return Err(EINVAL);
                }
                put(&mut out, 8, FRMSIZE_TYPE_DISCRETE);
                out[12..44].fill(0);
                put(&mut out, 12, SIZES[index].0);
                put(&mut out, 16, SIZES[index].1);
                Ok(out)
            }
            VIDIOC_ENUM_FRAMEINTERVALS => {
                let mut out = payload(data, 52);
                let index = get(&out, 0) as usize;
                let size = (get(&out, 8), get(&out, 12));
                if !self.present || get(&out, 4) != PIX_FMT_MJPEG || !SIZES.contains(&size) || index >= RATES.len() {
                    return Err(EINVAL);
                }
                put(&mut out, 16, FRMIVAL_TYPE_DISCRETE);
                out[20..52].fill(0);
                put(&mut out, 20, 1);
                put(&mut out, 24, RATES[index]);
                Ok(out)
            }
            VIDIOC_REQBUFS => {
                let mut out = payload(data, 20);
                capture(4)?;
                if !self.present || get(&out, 8) != MEMORY_MMAP {
                    return Err(EINVAL);
                }
                let count = (get(&out, 0) as usize).min(MAX_BUFFERS);
                if count > 0 && self.sessions[&id].streaming {
                    return Err(EBUSY);
                }
                self.stop(id);
                self.sessions.get_mut(&id).unwrap().buffers.clear();
                let format = self.sessions[&id].format;
                let length = (image_size(format.width, format.height) as u64).next_multiple_of(ALIGN);
                let mut buffers = Vec::new();
                for _ in 0..count {
                    let Some(offset) = self.free_offset(length, &buffers) else { break };
                    buffers.push(Buffer { offset, length: length as u32, queued: false, bytesused: 0 });
                }
                if buffers.len() < count {
                    return Err(ENOMEM);
                }
                self.sessions.get_mut(&id).unwrap().buffers = buffers;
                put(&mut out, 0, count as u32);
                put(&mut out, 12, BUF_CAP_SUPPORTS_MMAP);
                out[16] = 0;
                Ok(out)
            }
            VIDIOC_QUERYBUF | VIDIOC_QBUF => {
                let mut out = payload(data, BUFFER_SIZE);
                capture(4)?;
                let session = self.sessions.get_mut(&id).unwrap();
                let index = get(&out, 0) as usize;
                if index >= session.buffers.len() {
                    return Err(EINVAL);
                }
                if code == VIDIOC_QBUF {
                    if get(&out, 60) != MEMORY_MMAP || session.buffers[index].queued {
                        return Err(EINVAL);
                    }
                    session.buffers[index].queued = true;
                    session.buffers[index].bytesused = 0;
                    session.queue.push_back(index);
                }
                out.copy_from_slice(&session.describe(index));
                Ok(out)
            }
            VIDIOC_STREAMON => {
                capture(0)?;
                if !self.present || self.sessions[&id].buffers.is_empty() {
                    return Err(EINVAL);
                }
                match self.stream {
                    Some((streaming, _)) if streaming == id => return Ok(Vec::new()),
                    Some(_) => return Err(EBUSY),
                    None => {}
                }
                let session = self.sessions.get_mut(&id).unwrap();
                session.streaming = true;
                session.sequence = 0;
                let format = session.format;
                let stop = Arc::new(AtomicBool::new(false));
                self.stream = Some((id, stop.clone()));
                self.start = Some((id, format, stop));
                eprintln!("[vmm] camera {}: {}x{} at {} fps", self.index, format.width, format.height, format.fps);
                self.hub.streaming(self.index, Some(format));
                Ok(Vec::new())
            }
            VIDIOC_STREAMOFF => {
                capture(0)?;
                self.stop(id);
                Ok(Vec::new())
            }
            VIDIOC_ENUMINPUT => {
                let mut out = payload(data, 80);
                if get(&out, 0) != 0 {
                    return Err(EINVAL);
                }
                out[4..80].fill(0);
                put_name(&mut out, 4, 32, "Camera");
                put(&mut out, 36, INPUT_TYPE_CAMERA);
                Ok(out)
            }
            VIDIOC_G_INPUT => Ok(vec![0; 4]),
            VIDIOC_S_INPUT => if get(data, 0) == 0 { Ok(vec![0; 4]) } else { Err(EINVAL) },
            VIDIOC_QUERYCTRL | VIDIOC_QUERY_EXT_CTRL | VIDIOC_QUERYMENU | VIDIOC_G_CTRL | VIDIOC_S_CTRL
            | VIDIOC_G_EXT_CTRLS..=VIDIOC_TRY_EXT_CTRLS | VIDIOC_SUBSCRIBE_EVENT | VIDIOC_UNSUBSCRIBE_EVENT
            | VIDIOC_G_SELECTION | VIDIOC_S_SELECTION => Err(EINVAL),
            _ => Err(ENOTTY),
        }
    }

    /// Where a buffer of `length` fits, besides every session's buffers and `taken`.
    fn free_offset(&self, length: u64, taken: &[Buffer]) -> Option<u64> {
        let mut used: Vec<(u64, u64)> = self.sessions.values().flat_map(|s| s.buffers.iter()).chain(taken)
            .map(|b| (b.offset, b.offset + (b.length as u64).next_multiple_of(ALIGN)))
            .collect();
        used.sort();
        let mut at = 0;
        for (start, end) in used {
            if start >= at + length {
                break;
            }
            at = at.max(end);
        }
        (at + length <= self.region.len).then_some(at)
    }

    /// Session `id` stops streaming: its buffers are no longer queued, and
    /// events not yet sent for them are dropped.
    fn stop(&mut self, id: u32) {
        if let Some(session) = self.sessions.get_mut(&id) {
            session.streaming = false;
            session.queue.clear();
            for buffer in &mut session.buffers {
                buffer.queued = false;
            }
        }
        self.events.retain(|(session, _)| *session != id);
        if let Some((streaming, stop)) = &self.stream
            && *streaming == id
        {
            stop.store(true, Ordering::Release);
            self.stream = None;
            self.start = None;
            self.hub.streaming(self.index, None);
            self.hub.wake();
        }
    }

    /// Puts `jpeg` in the oldest queued buffer of streaming session `id`
    /// and returns it to the driver; no buffer queued, no frame.
    fn deliver(&mut self, id: u32, jpeg: &[u8]) {
        let Some(session) = self.sessions.get_mut(&id).filter(|s| s.streaming) else { return };
        let Some(&index) = session.queue.front() else { return };
        let buffer = &mut session.buffers[index];
        if jpeg.len() > buffer.length as usize {
            return;
        }
        session.queue.pop_front();
        self.region.write(buffer.offset, jpeg);
        buffer.queued = false;
        buffer.bytesused = jpeg.len() as u32;
        session.sequence = session.sequence.wrapping_add(1);
        let mut event = vec![0u8; EVENT_SIZE];
        put(&mut event, 0, EVT_DQBUF);
        put(&mut event, 4, id);
        event[8..8 + BUFFER_SIZE].copy_from_slice(&session.describe(index));
        put(&mut event, 8 + 56, session.sequence);
        self.events.push_back((id, event));
        while self.events.len() > MAX_EVENTS {
            self.events.pop_front();
        }
        self.flush_events();
    }

    fn flush_events(&mut self) {
        let Some(active) = self.active.as_mut() else { return };
        while let Some((_, event)) = self.events.front() {
            let Some(chain) = active.queues[1].pop(&active.memory) else { break };
            let written = chain.write_all(&active.memory, event);
            active.complete(1, chain.head, written as u32);
            self.events.pop_front();
        }
    }

    fn commands(&mut self) {
        loop {
            let Some(active) = self.active.as_mut() else { return };
            let Some(chain) = active.queues[0].pop(&active.memory) else { return };
            let memory = active.memory.clone();
            let request = chain.read_all(&memory).unwrap_or_default();
            let reply = self.command(&request);
            let written = chain.write_all(&memory, &reply);
            if let Some(active) = self.active.as_mut() {
                active.complete(0, chain.head, written as u32);
            }
        }
    }
}

/// Feeds streaming session `id` until `stop`: each new frame of its size as
/// it comes; without one for two frame times the last again (for STALE),
/// or gray.
fn stream(shared: Arc<Mutex<State>>, hub: &'static Hub, camera: usize, id: u32, format: Format, stop: Arc<AtomicBool>) {
    let interval = Duration::from_secs(1) / format.fps.max(1);
    let gray = Arc::new(camera::gray_jpeg(format.width, format.height, 128));
    let (mut seen, mut last, mut due) = (0, None::<(Arc<Vec<u8>>, Instant)>, Instant::now());
    while !stop.load(Ordering::Acquire) {
        let fresh = hub.wait(camera, seen, due);
        let now = Instant::now();
        let jpeg = match fresh {
            Some((sequence, frame)) => {
                seen = sequence;
                if (frame.width, frame.height) != (format.width, format.height) {
                    continue;
                }
                last = Some((frame.jpeg.clone(), now));
                due = now + interval * 2;
                frame.jpeg
            }
            None => {
                due = now + interval;
                match &last {
                    Some((jpeg, at)) if now - *at < camera::STALE => jpeg.clone(),
                    _ => gray.clone(),
                }
            }
        };
        let mut state = shared.lock().unwrap();
        if stop.load(Ordering::Acquire) {
            return;
        }
        state.deliver(id, &jpeg);
    }
}

pub struct Media {
    state: Arc<Mutex<State>>,
}

impl Media {
    /// Camera `index` (camera.rs: BACK or FRONT); one Android does not
    /// have when not `present`.
    pub fn new(index: usize, present: bool, hub: &'static Hub, mapper: Box<dyn Mapper>) -> Media {
        let state = State {
            index,
            present,
            hub,
            active: None,
            sessions: BTreeMap::new(),
            next_session: 0,
            events: VecDeque::new(),
            stream: None,
            start: None,
            region: Region::new(REGION_SIZE, mapper),
        };
        Media { state: Arc::new(Mutex::new(state)) }
    }

    fn card(&self) -> &'static str {
        let state = self.state.lock().unwrap();
        match (state.present, state.index) {
            (false, _) => "Avo Camera (off)",
            (true, camera::BACK) => "Avo Back Camera",
            (true, _) => "Avo Front Camera",
        }
    }
}

impl VirtioDevice for Media {
    fn device_type(&self) -> u16 {
        TYPE_MEDIA
    }

    fn features(&self) -> u64 {
        0
    }

    fn queue_sizes(&self) -> Vec<u16> {
        vec![128, 64]
    }

    /// `struct virtio_v4l2_config`: device_caps, device_type (VFL_TYPE_VIDEO), card.
    fn config(&self) -> Vec<u8> {
        let mut config = vec![0u8; 40];
        put(&mut config, 0, CAP_VIDEO_CAPTURE | CAP_STREAMING);
        put_name(&mut config, 8, 32, self.card());
        config
    }

    fn activate(&mut self, memory: Arc<GuestMemory>, queues: Vec<Queue>, interrupt: Interrupt, _features: u64) {
        self.state.lock().unwrap().active = Some(Active { memory, queues, interrupt });
    }

    fn notify(&mut self, queue: usize) {
        let mut state = self.state.lock().unwrap();
        if queue == 0 {
            state.commands();
        }
        state.flush_events();
        if let Some((id, format, stop)) = state.start.take() {
            let (shared, hub, camera) = (self.state.clone(), state.hub, state.index);
            let spawned = std::thread::Builder::new()
                .name(format!("camera {camera}"))
                .spawn(move || stream(shared, hub, camera, id, format, stop));
            if let Err(e) = spawned {
                eprintln!("[vmm] camera {camera}: {e}");
            }
        }
    }

    fn reset(&mut self) {
        let mut state = self.state.lock().unwrap();
        let ids: Vec<u32> = state.sessions.keys().copied().collect();
        for id in ids {
            state.stop(id);
        }
        state.sessions.clear();
        state.events.clear();
        state.active = None;
    }

    fn pci_class(&self) -> u32 {
        0x04_0000 // multimedia video controller
    }

    fn shared_memory_size(&self) -> Option<u64> {
        Some(REGION_SIZE)
    }

    fn shared_memory_id(&self) -> u8 {
        0
    }

    fn set_shared_memory_base(&mut self, base: Option<u64>) {
        self.state.lock().unwrap().region.place(base);
    }
}

impl Drop for Media {
    /// The machine goes: the stream stops, and the buffers leave the VM now
    /// (the next machine's BAR may sit at the same address), even if the
    /// stream thread still holds the state for a moment.
    fn drop(&mut self) {
        self.reset();
        self.state.lock().unwrap().region.place(None);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hvf::GuestRegion;

    #[derive(Clone, Default)]
    struct Recorder(Arc<Mutex<Vec<String>>>);

    impl Mapper for Recorder {
        fn map(&mut self, host: usize, guest: u64, len: u64) -> Result<(), String> {
            assert_ne!(host, 0);
            self.0.lock().unwrap().push(format!("map {guest:#x} +{len:#x}"));
            Ok(())
        }

        fn unmap(&mut self, guest: u64, len: u64) -> Result<(), String> {
            self.0.lock().unwrap().push(format!("unmap {guest:#x} +{len:#x}"));
            Ok(())
        }
    }

    fn hub() -> &'static Hub {
        Box::leak(Box::new(Hub::new()))
    }

    fn state(present: bool) -> State {
        State {
            index: camera::BACK,
            present,
            hub: hub(),
            active: None,
            sessions: BTreeMap::new(),
            next_session: 0,
            events: VecDeque::new(),
            stream: None,
            start: None,
            region: Region::new(REGION_SIZE, Box::new(Recorder::default())),
        }
    }

    fn cmd(words: &[u32]) -> Vec<u8> {
        words.iter().flat_map(|w| w.to_le_bytes()).collect()
    }

    /// An ioctl's status and payload.
    fn ioctl(state: &mut State, id: u32, code: u32, payload: &[u8]) -> (u32, Vec<u8>) {
        let mut request = cmd(&[CMD_IOCTL, 0, id, code]);
        request.extend_from_slice(payload);
        let reply = state.command(&request);
        (get(&reply, 0), reply[8..].to_vec())
    }

    fn open(state: &mut State) -> u32 {
        let reply = state.command(&cmd(&[CMD_OPEN, 0]));
        assert_eq!((reply.len(), get(&reply, 0)), (16, 0));
        get(&reply, 8)
    }

    fn sized(words: &[u32], len: usize) -> Vec<u8> {
        let mut out = cmd(words);
        out.resize(len, 0);
        out
    }

    #[test]
    fn a_session_negotiates_motion_jpeg_like_the_hal() {
        let mut state = state(true);
        let id = open(&mut state);
        let (status, fmt) = ioctl(&mut state, id, VIDIOC_ENUM_FMT, &sized(&[0, BUF_TYPE_VIDEO_CAPTURE], 64));
        assert_eq!((status, get(&fmt, 44), get(&fmt, 8)), (0, PIX_FMT_MJPEG, FMT_FLAG_COMPRESSED));
        assert_eq!(&fmt[12..23], b"Motion-JPEG");
        assert_eq!(ioctl(&mut state, id, VIDIOC_ENUM_FMT, &sized(&[1, BUF_TYPE_VIDEO_CAPTURE], 64)).0, EINVAL);

        let sizes: Vec<(u32, u32)> = (0..)
            .map(|i| ioctl(&mut state, id, VIDIOC_ENUM_FRAMESIZES, &sized(&[i, PIX_FMT_MJPEG], 44)))
            .take_while(|(status, _)| *status == 0)
            .map(|(_, out)| {
                assert_eq!(get(&out, 8), FRMSIZE_TYPE_DISCRETE);
                (get(&out, 12), get(&out, 16))
            })
            .collect();
        assert_eq!(sizes, SIZES);
        let rates: Vec<(u32, u32)> = (0..)
            .map(|i| ioctl(&mut state, id, VIDIOC_ENUM_FRAMEINTERVALS, &sized(&[i, PIX_FMT_MJPEG, 1280, 720], 52)))
            .take_while(|(status, _)| *status == 0)
            .map(|(_, out)| (get(&out, 20), get(&out, 24)))
            .collect();
        assert_eq!(rates, [(1, 30), (1, 15)]);
        assert_eq!(ioctl(&mut state, id, VIDIOC_ENUM_FRAMEINTERVALS, &sized(&[0, PIX_FMT_MJPEG, 800, 600], 52)).0, EINVAL);

        // S_FMT takes the nearest size and says how big a frame may be.
        let (status, fmt) = ioctl(&mut state, id, VIDIOC_S_FMT, &sized(&[BUF_TYPE_VIDEO_CAPTURE, 0, 1000, 700, PIX_FMT_MJPEG], 208));
        assert_eq!((status, get(&fmt, 8), get(&fmt, 12), get(&fmt, 16)), (0, 1280, 720, PIX_FMT_MJPEG));
        assert_eq!(get(&fmt, 28), 1280 * 720 * 3 / 2);
        let (_, fmt) = ioctl(&mut state, id, VIDIOC_G_FMT, &sized(&[BUF_TYPE_VIDEO_CAPTURE], 208));
        assert_eq!((get(&fmt, 8), get(&fmt, 12)), (1280, 720));

        // The HAL's setV4l2FpsLocked: G_PARM needs TIMEPERFRAME, S_PARM 10000/300000.
        let (_, parm) = ioctl(&mut state, id, VIDIOC_G_PARM, &sized(&[BUF_TYPE_VIDEO_CAPTURE], 204));
        assert_eq!(get(&parm, 4) & CAP_TIMEPERFRAME, CAP_TIMEPERFRAME);
        let (status, parm) = ioctl(&mut state, id, VIDIOC_S_PARM, &sized(&[BUF_TYPE_VIDEO_CAPTURE, CAP_TIMEPERFRAME, 0, 10000, 160000], 204));
        assert_eq!((status, get(&parm, 12), get(&parm, 16)), (0, 1, 15));
        ioctl(&mut state, id, VIDIOC_S_PARM, &sized(&[BUF_TYPE_VIDEO_CAPTURE, 0, 0, 10000, 300000], 204));

        let (_, input) = ioctl(&mut state, id, VIDIOC_ENUMINPUT, &sized(&[0], 80));
        assert_eq!((&input[4..10], get(&input, 36)), (&b"Camera"[..], INPUT_TYPE_CAMERA));
        assert_eq!(ioctl(&mut state, id, VIDIOC_QUERYCTRL, &[0; 68]).0, EINVAL);
        assert_eq!(ioctl(&mut state, id, 0, &[]).0, ENOTTY, "QUERYCAP is the driver's");
    }

    /// REQBUFS, QUERYBUF and QBUF as configureV4l2StreamLocked does them.
    fn queue_buffers(state: &mut State, id: u32, count: u32) -> Vec<(u64, u32)> {
        let (status, req) = ioctl(state, id, VIDIOC_REQBUFS, &sized(&[count, BUF_TYPE_VIDEO_CAPTURE, MEMORY_MMAP], 20));
        assert_eq!((status, get(&req, 0)), (0, count));
        (0..count)
            .map(|i| {
                let query = sized(&[i, BUF_TYPE_VIDEO_CAPTURE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, MEMORY_MMAP], BUFFER_SIZE);
                let (status, buffer) = ioctl(state, id, VIDIOC_QUERYBUF, &query);
                assert_eq!(status, 0);
                let offset = u64::from_le_bytes(buffer[64..72].try_into().unwrap());
                let (status, queued) = ioctl(state, id, VIDIOC_QBUF, &buffer);
                assert_eq!((status, get(&queued, 12) & BUF_FLAG_QUEUED), (0, BUF_FLAG_QUEUED));
                (offset, get(&buffer, 72))
            })
            .collect()
    }

    #[test]
    fn buffers_are_mapped_where_they_are_and_frames_come_back_as_events() {
        let mut state = state(true);
        let heard = Arc::new(Mutex::new(Vec::new()));
        let sink = heard.clone();
        state.hub.set_events(Arc::new(move |event| sink.lock().unwrap().push(event)));
        let id = open(&mut state);
        let buffers = queue_buffers(&mut state, id, 4);
        let length = (1280 * 720 * 3 / 2u64).next_multiple_of(ALIGN);
        assert_eq!(buffers, (0..4).map(|i| (i * length, length as u32)).collect::<Vec<_>>());
        assert_eq!(ioctl(&mut state, id, VIDIOC_QBUF, &sized(&[0, BUF_TYPE_VIDEO_CAPTURE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, MEMORY_MMAP], BUFFER_SIZE)).0, EINVAL, "already queued");

        let reply = state.command(&cmd(&[CMD_MMAP, 0, id, 1, buffers[2].0 as u32]));
        assert_eq!(get(&reply, 0), 0);
        assert_eq!(u64::from_le_bytes(reply[8..16].try_into().unwrap()), buffers[2].0);
        assert_eq!(u64::from_le_bytes(reply[16..24].try_into().unwrap()), length);
        assert_eq!(get(&state.command(&cmd(&[CMD_MMAP, 0, id, 1, 4096])), 0), EINVAL);

        assert_eq!(ioctl(&mut state, id, VIDIOC_STREAMON, &cmd(&[BUF_TYPE_VIDEO_CAPTURE])).0, 0);
        assert!(state.start.take().is_some(), "a stream thread is asked for");
        assert_eq!(*heard.lock().unwrap(), ["camera 0 on 1280 720 30"]);
        // S_FMT may not change a streaming session.
        assert_eq!(ioctl(&mut state, id, VIDIOC_S_FMT, &sized(&[BUF_TYPE_VIDEO_CAPTURE, 0, 640, 480], 208)).0, EBUSY);

        state.deliver(id, b"\xff\xd8first");
        state.deliver(id, b"\xff\xd8second");
        assert_eq!(state.region.read(buffers[0].0, 7), b"\xff\xd8first");
        assert_eq!(state.region.read(buffers[1].0, 8), b"\xff\xd8second");
        let (session, event) = &state.events[1];
        assert_eq!((*session, event.len()), (id, EVENT_SIZE));
        assert_eq!((get(event, 0), get(event, 4)), (EVT_DQBUF, id));
        // The v4l2_buffer: index, bytesused, sequence, memory, offset.
        assert_eq!((get(event, 8), get(event, 16), get(event, 8 + 56), get(event, 8 + 60)), (1, 8, 2, MEMORY_MMAP));
        assert_eq!(u64::from_le_bytes(event[8 + 64..8 + 72].try_into().unwrap()), buffers[1].0);

        // Too big for a buffer: left out, the buffer stays queued.
        state.deliver(id, &vec![0; length as usize + 1]);
        assert_eq!(state.events.len(), 2);
        assert_eq!(state.sessions[&id].queue, [2, 3]);

        assert_eq!(ioctl(&mut state, id, VIDIOC_STREAMOFF, &cmd(&[BUF_TYPE_VIDEO_CAPTURE])).0, 0);
        assert!(state.events.is_empty(), "events of a stopped stream are dropped");
        assert!(state.sessions[&id].queue.is_empty());
        state.deliver(id, b"late");
        assert!(state.events.is_empty());
        assert_eq!(heard.lock().unwrap().last().unwrap(), "camera 0 off");
        // REQBUFS(0) frees them, CLOSE ends the session.
        assert_eq!(ioctl(&mut state, id, VIDIOC_REQBUFS, &sized(&[0, BUF_TYPE_VIDEO_CAPTURE, MEMORY_MMAP], 20)).0, 0);
        assert!(state.command(&cmd(&[CMD_CLOSE, 0, id, 0])).is_empty());
        assert!(state.sessions.is_empty());
    }

    #[test]
    fn one_session_streams_at_a_time_and_buffers_do_not_overlap() {
        let mut state = state(true);
        let (first, second) = (open(&mut state), open(&mut state));
        let mine = queue_buffers(&mut state, first, 4);
        let theirs = queue_buffers(&mut state, second, 4);
        let end = |&(offset, length): &(u64, u32)| offset + length as u64;
        assert!(theirs.iter().all(|b| b.0 >= mine.iter().map(end).max().unwrap()));
        assert_eq!(ioctl(&mut state, first, VIDIOC_STREAMON, &cmd(&[BUF_TYPE_VIDEO_CAPTURE])).0, 0);
        assert_eq!(ioctl(&mut state, second, VIDIOC_STREAMON, &cmd(&[BUF_TYPE_VIDEO_CAPTURE])).0, EBUSY);
        // Closing the streaming session lets the other stream.
        state.command(&cmd(&[CMD_CLOSE, 0, first, 0]));
        assert_eq!(ioctl(&mut state, second, VIDIOC_STREAMON, &cmd(&[BUF_TYPE_VIDEO_CAPTURE])).0, 0);
        // Eight 1080p buffers (24 MiB) fit twice more, not three times.
        for expected in [0, 0, ENOMEM] {
            let more = open(&mut state);
            ioctl(&mut state, more, VIDIOC_S_FMT, &sized(&[BUF_TYPE_VIDEO_CAPTURE, 0, 1920, 1080], 208));
            assert_eq!(ioctl(&mut state, more, VIDIOC_REQBUFS, &sized(&[8, BUF_TYPE_VIDEO_CAPTURE, MEMORY_MMAP], 20)).0, expected);
        }
    }

    #[test]
    fn a_camera_android_does_not_have_lists_no_format() {
        let mut state = state(false);
        let id = open(&mut state);
        assert_eq!(ioctl(&mut state, id, VIDIOC_ENUM_FMT, &sized(&[0, BUF_TYPE_VIDEO_CAPTURE], 64)).0, EINVAL);
        assert_eq!(ioctl(&mut state, id, VIDIOC_ENUM_FRAMESIZES, &sized(&[0, PIX_FMT_MJPEG], 44)).0, EINVAL);
        assert_eq!(ioctl(&mut state, id, VIDIOC_REQBUFS, &sized(&[4, BUF_TYPE_VIDEO_CAPTURE, MEMORY_MMAP], 20)).0, EINVAL);
        assert_eq!(ioctl(&mut state, 99, VIDIOC_ENUM_FMT, &[]).0, EINVAL, "no such session");
    }

    // A driver's side of the two virtqueues, in guest memory.
    const RAM: u64 = 0x8000_0000;

    struct Ring {
        desc: u64,
        avail: u64,
        used: u64,
        size: u16,
        next: u16,
    }

    impl Ring {
        fn queue(&self) -> Queue {
            let mut queue = Queue::new(self.size);
            (queue.ready, queue.desc_table, queue.avail_ring, queue.used_ring) = (true, self.desc, self.avail, self.used);
            queue
        }

        /// Publishes a chain of (address, length, device-writable) buffers.
        fn offer(&mut self, memory: &GuestMemory, buffers: &[(u64, u32, bool)]) {
            let first = self.next * 4 % self.size;
            for (i, &(address, len, write)) in buffers.iter().enumerate() {
                let at = self.desc + (first as u64 + i as u64) * 16;
                let more = i + 1 < buffers.len();
                memory.write(at, &address.to_le_bytes());
                memory.write_u32(at + 8, len);
                memory.write_u16(at + 12, if more { 1 } else { 0 } | if write { 2 } else { 0 });
                memory.write_u16(at + 14, first + i as u16 + 1);
            }
            memory.write_u16(self.avail + 4 + (self.next % self.size) as u64 * 2, first);
            self.next += 1;
            memory.write_u16(self.avail + 2, self.next);
        }

        fn used(&self, memory: &GuestMemory) -> u16 {
            memory.read_u16(self.used + 2).unwrap()
        }
    }

    #[test]
    fn the_driver_gets_gray_frames_before_the_mac_sends_any() {
        let memory = Arc::new(GuestMemory::new(GuestRegion::new(RAM, 1 << 20).unwrap()));
        let hub = hub();
        let mapper = Recorder::default();
        let mut device = Media::new(camera::FRONT, true, hub, Box::new(mapper.clone()));
        assert_eq!(&device.config()[8..24], b"Avo Front Camera");
        device.set_shared_memory_base(Some(0x8_0400_0000));
        assert_eq!(*mapper.0.lock().unwrap(), ["map 0x804000000 +0x4000000"]);
        let mut commands = Ring { desc: RAM, avail: RAM + 0x1000, used: RAM + 0x2000, size: 128, next: 0 };
        let mut events = Ring { desc: RAM + 0x3000, avail: RAM + 0x4000, used: RAM + 0x5000, size: 64, next: 0 };
        device.activate(memory.clone(), vec![commands.queue(), events.queue()], Interrupt::new(|_| {}), 0);
        for i in 0..16 {
            events.offer(&memory, &[(RAM + 0x10000 + i * 0x400, EVENT_SIZE as u32, true)]);
        }

        // OPEN, then each ioctl as the driver lays it out: command, payload | response, payload.
        let (request, reply) = (RAM + 0x20000, RAM + 0x30000);
        let mut call = |device: &mut Media, words: &[u32], payload: &[u8], answer: u32| -> Vec<u8> {
            let mut bytes = cmd(words);
            bytes.extend_from_slice(payload);
            memory.write(request, &bytes);
            let mut chain = vec![(request, bytes.len() as u32, false), (reply, 8, true)];
            if answer > 0 {
                chain.push((reply + 8, answer, true));
            }
            commands.offer(&memory, &chain);
            let before = commands.used(&memory);
            device.notify(0);
            assert_eq!(commands.used(&memory), before.wrapping_add(1));
            let mut out = vec![0u8; 8 + answer as usize];
            memory.read(reply, &mut out);
            out
        };
        let opened = call(&mut device, &[CMD_OPEN, 0], &[], 8);
        let id = get(&opened, 8);
        let ioctl = |device: &mut Media, call: &mut dyn FnMut(&mut Media, &[u32], &[u8], u32) -> Vec<u8>, code: u32, payload: &[u8]| {
            let out = call(device, &[CMD_IOCTL, 0, id, code], payload, payload.len() as u32);
            assert_eq!(get(&out, 0), 0, "ioctl {code}");
            out[8..].to_vec()
        };
        ioctl(&mut device, &mut call, VIDIOC_S_FMT, &sized(&[BUF_TYPE_VIDEO_CAPTURE, 0, 640, 480, PIX_FMT_MJPEG], 208));
        ioctl(&mut device, &mut call, VIDIOC_REQBUFS, &sized(&[2, BUF_TYPE_VIDEO_CAPTURE, MEMORY_MMAP], 20));
        for i in 0..2 {
            let buffer = ioctl(&mut device, &mut call, VIDIOC_QUERYBUF, &sized(&[i, BUF_TYPE_VIDEO_CAPTURE], BUFFER_SIZE));
            ioctl(&mut device, &mut call, VIDIOC_QBUF, &buffer);
        }
        let streamon = call(&mut device, &[CMD_IOCTL, 0, id, VIDIOC_STREAMON, BUF_TYPE_VIDEO_CAPTURE], &[], 0);
        assert_eq!(get(&streamon, 0), 0);

        // Nobody feeds the camera: a gray frame comes at once.
        let deadline = Instant::now() + Duration::from_secs(5);
        while events.used(&memory) < 1 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        let event = |i: u64| {
            let mut event = vec![0u8; EVENT_SIZE];
            memory.read(RAM + 0x10000 + i * 0x400, &mut event);
            event
        };
        let gray = camera::gray_jpeg(640, 480, 128);
        assert_eq!((get(&event(0), 0), get(&event(0), 8), get(&event(0), 16)), (EVT_DQBUF, 0, gray.len() as u32));
        assert_eq!(device.state.lock().unwrap().region.read(0, gray.len()), gray);

        // The Mac's frame of the stream's size comes next (in the buffer
        // left, or in the first once the HAL queues it again).
        hub.push(camera::FRONT, camera::Frame { width: 1280, height: 720, jpeg: Arc::new(b"other size".to_vec()) });
        hub.push(camera::FRONT, camera::Frame { width: 640, height: 480, jpeg: Arc::new(b"\xff\xd8mac".to_vec()) });
        let first = ioctl(&mut device, &mut call, VIDIOC_QUERYBUF, &sized(&[0, BUF_TYPE_VIDEO_CAPTURE], BUFFER_SIZE));
        ioctl(&mut device, &mut call, VIDIOC_QBUF, &first);
        let mac = loop {
            let found = (0..16).map(event).find(|e| get(e, 0) == EVT_DQBUF && get(e, 16) == 5);
            if let Some(found) = found {
                break found;
            }
            assert!(Instant::now() < deadline, "no frame from the Mac");
            std::thread::sleep(Duration::from_millis(5));
        };
        let offset = u64::from_le_bytes(mac[8 + 64..8 + 72].try_into().unwrap());
        assert_eq!(device.state.lock().unwrap().region.read(offset, 5), b"\xff\xd8mac");

        drop(device);
        assert_eq!(mapper.0.lock().unwrap().last().unwrap(), "unmap 0x804000000 +0x4000000");
    }
}
