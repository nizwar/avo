//! The render thread (GPU mode): owns gfxstream and runs the virtio-gpu
//! queues, 3D, blob and context commands included (virtio 1.2 §5.7.6).
//!
//! gfxstream's frontend has no locks, so this one thread makes every
//! `stream_renderer_*` call. vCPUs only post `Kick`s (2D mode runs commands
//! on the vCPU instead), and gfxstream's fence callback, which may run
//! inside `create_fence` or on gfxstream's threads, only posts `FenceDone`.
//! Commands on resources the renderer does not own (dumb buffers, display
//! info, cursor) go to the 2D device's `State::command`, unchanged.
//!
//! The renderer starts once per process and survives guest reboots: a
//! device reset or the end of a boot purges what that guest made.
//!
//! Frames: on RESOURCE_FLUSH of a renderer resource shown on a scanout, the
//! whole color buffer is read back into the next shared-memory frame buffer
//! (frames.rs), so the window host, upscaler and recorder see the same
//! frames as in 2D mode. With Avo's own renderer that happens on a thread of
//! its own (`FrameReader`), the GPU writing the buffer itself, while this
//! thread goes on with the guest's commands; with another gfxstream,
//! `transfer_read_iov` reads it here.

use super::fence::{FenceQueue, Ring};
use super::gfxstream::{self, Box3, Callbacks, CreateBlob, Library, Readback, ResourceCreateArgs};
use super::hostmem::{self, HostVisible, Hvf, PAGE};
use super::{Format, Hwc, Rect, State, le32, le64, rect, MAX_SCANOUTS};
use super::{
    CMD_GET_DISPLAY_INFO, CMD_GET_EDID, CMD_MOVE_CURSOR, CMD_RESOURCE_ATTACH_BACKING, CMD_RESOURCE_CREATE_2D, CMD_RESOURCE_DETACH_BACKING,
    CMD_RESOURCE_FLUSH, CMD_RESOURCE_UNREF, CMD_SET_SCANOUT, CMD_TRANSFER_TO_HOST_2D, CMD_UPDATE_CURSOR, FLAG_FENCE, RESP_ERR_INVALID_PARAMETER,
    RESP_ERR_INVALID_RESOURCE_ID, RESP_ERR_INVALID_SCANOUT_ID, RESP_ERR_UNSPEC, RESP_OK_NODATA,
};
use crate::frames::FrameHandle;
use crate::virtio::Active;
use crate::virtio::queue::Chain;
use std::collections::{HashMap, HashSet};
use std::ffi::{CStr, c_void};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

pub use super::gfxstream::set_environment;

const CMD_GET_CAPSET_INFO: u32 = 0x0108;
const CMD_GET_CAPSET: u32 = 0x0109;
const CMD_RESOURCE_CREATE_BLOB: u32 = 0x010c;
const CMD_SET_SCANOUT_BLOB: u32 = 0x010d;
const CMD_CTX_CREATE: u32 = 0x0200;
const CMD_CTX_DESTROY: u32 = 0x0201;
const CMD_CTX_ATTACH_RESOURCE: u32 = 0x0202;
const CMD_CTX_DETACH_RESOURCE: u32 = 0x0203;
const CMD_RESOURCE_CREATE_3D: u32 = 0x0204;
const CMD_TRANSFER_TO_HOST_3D: u32 = 0x0205;
const CMD_TRANSFER_FROM_HOST_3D: u32 = 0x0206;
const CMD_SUBMIT_3D: u32 = 0x0207;
const CMD_RESOURCE_MAP_BLOB: u32 = 0x0208;
const CMD_RESOURCE_UNMAP_BLOB: u32 = 0x0209;

const RESP_OK_CAPSET_INFO: u32 = 0x1102;
const RESP_OK_CAPSET: u32 = 0x1103;
const RESP_OK_MAP_INFO: u32 = 0x1106;
const RESP_ERR_INVALID_CONTEXT_ID: u32 = 0x1204;

const FLAG_INFO_RING_IDX: u32 = 1 << 1;
const MAP_CACHE_CACHED: u32 = 1;
const PIPE_BUFFER: u32 = 0;
const PIPE_TEXTURE_2D: u32 = 2;

/// VIRGL (0) | RESOURCE_BLOB (3) | CONTEXT_INIT (4).
pub const FEATURES: u64 = 1 << 0 | 1 << 3 | 1 << 4;
/// gfxstream-vulkan (3, used by ANGLE and Vulkan) and gfxstream-composer (9),
/// in GET_CAPSET_INFO order. Never virgl (1, 2) or cross-domain (5): minigbm
/// would pick another backend.
const CAPSETS: [u32; 2] = [3, 9];
pub const CAPSET_COUNT: u32 = CAPSETS.len() as u32;
/// The shared memory region the guest maps blobs from (BAR 2).
pub const HOST_VISIBLE_SIZE: u64 = 8 << 30;
/// ASG rings are ringSize + bufferSize (about 1 MiB); anything far larger
/// is not a ring.
const RING_BLOB_MAX: u64 = 16 << 20;
const STALL: Duration = Duration::from_secs(10);
const STATS_EVERY: Duration = Duration::from_secs(5);
const INIT_LIMIT: Duration = Duration::from_secs(20);
/// Fence ids handed to gfxstream carry the purge count above these bits, so
/// a fence of a guest that was reset can never complete the next one's.
const EPOCH_SHIFT: u32 = 48;

/// The renderer for the life of the process (cheap to clone).
#[derive(Clone)]
pub struct RenderHost {
    tx: Sender<Msg>,
    /// The GPU gfxstream renders on ("Apple M4 Pro").
    pub device: String,
}

pub(super) enum Msg {
    Activate(Box<Attach>),
    Kick(usize),
    FenceDone { ring: Ring, id: u64 },
    ShmBase(Option<u64>),
    Reset(Sender<()>),
    Detach(Sender<()>),
}

/// One activation of the device by the guest driver.
pub(super) struct Attach {
    pub active: Active,
    pub state: Arc<Mutex<State>>,
    pub events: FrameHandle,
    pub lease: Lease,
}

impl Attach {
    /// Returns a finished request, unless the lease has ended.
    fn complete(&mut self, queue: usize, head: u16, len: u32) {
        if let Some(_held) = self.lease.hold() {
            self.active.complete(queue, head, len);
        }
    }
}

/// Whether the render thread may still use an activation's queues. The
/// device ends it on reset even when this thread, stuck in gfxstream, never
/// answers the Reset message: the guest then sets the queues up again, and
/// answers written into them afterwards would corrupt them.
#[derive(Clone)]
pub(super) struct Lease(Arc<Mutex<bool>>);

impl Lease {
    pub fn new() -> Lease {
        Lease(Arc::new(Mutex::new(true)))
    }

    /// Held while touching the queues, so that `end` waits for it rather
    /// than racing it; never held across a gfxstream call.
    fn hold(&self) -> Option<MutexGuard<'_, bool>> {
        let held = self.0.lock().unwrap();
        if *held { Some(held) } else { None }
    }

    pub fn end(&self) {
        *self.0.lock().unwrap() = false;
    }
}

impl RenderHost {
    pub(super) fn send(&self, message: Msg) {
        let _ = self.tx.send(message);
    }

    /// Sends a message that carries an acknowledgement and waits for it.
    pub(super) fn request(&self, message: impl FnOnce(Sender<()>) -> Msg, limit: Duration) -> bool {
        let (ack, done) = mpsc::channel();
        self.send(message(ack));
        done.recv_timeout(limit).is_ok()
    }
}

/// Loads gfxstream from the emulator directory and starts the render
/// thread; fails if that does not work within 20 s. The environment must
/// be set already (gfxstream::set_environment).
pub fn start(emulator: &Path, display: (u32, u32), hwc: Hwc, verbose: bool) -> Result<RenderHost, String> {
    let (tx, rx) = mpsc::channel();
    let (ready, started) = mpsc::channel();
    let fences = tx.clone();
    let dir = emulator.to_path_buf();
    std::thread::Builder::new()
        .name("gpu-render".into())
        .spawn(move || match Renderer::new(&dir, display, fences, verbose) {
            Ok((renderer, device)) => {
                let _ = ready.send(Ok(device));
                renderer.run(rx);
            }
            Err(e) => {
                let _ = ready.send(Err(e));
            }
        })
        .map_err(|e| e.to_string())?;
    let device = match started.recv_timeout(INIT_LIMIT) {
        Ok(result) => result?,
        Err(_) => return Err(format!("gfxstream did not start within {} s", INIT_LIMIT.as_secs())),
    };
    let hwc = match hwc {
        Hwc::Client => "client",
        Hwc::Host => "host",
    };
    eprintln!(
        "[gpu] gfxstream from {}: {device}, flags {:#x}, capsets 3,9, host-visible {} GiB, hwc {hwc}",
        emulator.display(),
        gfxstream::RENDERER_FLAGS,
        HOST_VISIBLE_SIZE >> 30
    );
    Ok(RenderHost { tx, device })
}

#[derive(Clone, Copy)]
struct Blob {
    host: usize,
    /// The guest's size rounded up to whole host pages.
    len: u64,
    /// `resource_map` gave `host` (MAPPABLE blobs).
    mapped: bool,
}

struct Resource {
    /// RESOURCE_CREATE_3D's arguments; blobs have none.
    args: Option<ResourceCreateArgs>,
    blob: Option<Blob>,
    backing: bool,
}

/// A request answered when its fence signals.
#[derive(Clone, Copy)]
struct Token {
    queue: usize,
    head: u16,
    len: u32,
}

/// Counters for the engine log.
#[derive(Default)]
struct Stats {
    window: Option<Instant>,
    flushes: u64,
    readbacks: u64,
    readback_total: Duration,
    readback_max: Duration,
    unknown: u64,
    errors: u64,
    /// The counters of the last line: contexts, resources, blobs, mapped
    /// bytes, fences, rejected maps, unknown commands, errors.
    printed: Option<(usize, usize, usize, u64, usize, u64, u64, u64)>,
}

struct Renderer {
    lib: Library,
    capsets: Vec<(u32, Vec<u8>)>,
    contexts: HashSet<u32>,
    resources: HashMap<u32, Resource>,
    fences: FenceQueue<Token>,
    /// Counts purges (wrapping); tags the fence ids gfxstream sees.
    epoch: u16,
    hostmem: HostVisible<Hvf>,
    attach: Option<Attach>,
    /// `gpu first-frame` went out this boot (here or from `FrameReader`).
    first_frame: Arc<AtomicBool>,
    /// The guest created its first rendering context this boot (`gpu context`).
    saw_context: bool,
    /// When `gpu stalled` went out, until the fences pending then are done.
    stall_mark: Option<Instant>,
    scratch: Vec<u8>,
    stats: Stats,
    warned: HashSet<String>,
    /// Reads frames back on its own thread (Avo's renderer).
    reader: Option<FrameReader>,
}

/// Reads frames back on a thread of its own (`Readback`, Avo's renderer):
/// the render thread only says which resource a scanout shows and goes on
/// with the guest's commands, gfxstream holds none of its locks while the
/// GPU copies, and the GPU writes the shared frame buffer itself. Per
/// scanout only the newest flush waits; one read at a time.
struct FrameReader {
    shared: Arc<(Mutex<Reads>, Condvar)>,
}

#[derive(Default)]
struct Reads {
    /// The newest flush of each scanout not read yet.
    waiting: [Option<Read>; MAX_SCANOUTS],
    /// Readbacks since the engine log's last line.
    count: u64,
    total: Duration,
    max: Duration,
    /// A read failed for another reason than its resource going away: the
    /// render thread reads frames itself from then on.
    failed: bool,
}

struct Read {
    resource: u32,
    width: u32,
    height: u32,
    format: Format,
    state: Arc<Mutex<State>>,
    events: FrameHandle,
}

impl FrameReader {
    fn start(readback: Readback, first_frame: Arc<AtomicBool>) -> Option<FrameReader> {
        let shared = Arc::new((Mutex::new(Reads::default()), Condvar::new()));
        let worker = shared.clone();
        std::thread::Builder::new()
            .name("gpu-frames".into())
            .spawn(move || Self::run(readback, &worker, &first_frame))
            .ok()?;
        // Before a layout's memory goes, gfxstream lets go of what it imported.
        crate::frames::set_unmap_hook(Box::new(move |buffer| unsafe { (readback.forget)(buffer.cast()) }));
        Some(FrameReader { shared })
    }

    fn usable(&self) -> bool {
        !self.shared.0.lock().unwrap().failed
    }

    /// Reads `read` for `scanout` next, instead of an older flush still waiting.
    fn request(&self, scanout: usize, read: Read) {
        let (reads, ready) = &*self.shared;
        reads.lock().unwrap().waiting[scanout] = Some(read);
        ready.notify_one();
    }

    /// Forgets the flushes still waiting (the guest that made them is gone).
    fn clear(&self) {
        self.shared.0.lock().unwrap().waiting = Default::default();
    }

    /// The readbacks since the last call: how many, their total and longest time.
    fn take_stats(&self) -> (u64, Duration, Duration) {
        let mut reads = self.shared.0.lock().unwrap();
        let stats = (reads.count, reads.total, reads.max);
        (reads.count, reads.total, reads.max) = (0, Duration::ZERO, Duration::ZERO);
        stats
    }

    fn run(readback: Readback, shared: &(Mutex<Reads>, Condvar), first_frame: &AtomicBool) {
        let (reads, ready) = shared;
        // Scanouts take turns.
        let mut start = 0;
        loop {
            let (scanout, read) = {
                let mut waiting = reads.lock().unwrap();
                loop {
                    let next = (0..MAX_SCANOUTS).map(|k| (start + k) % MAX_SCANOUTS).find(|&i| waiting.waiting[i].is_some());
                    if let Some(i) = next {
                        start = i + 1;
                        break (i, waiting.waiting[i].take().unwrap());
                    }
                    waiting = ready.wait(waiting).unwrap();
                }
            };
            // A scanout whose layout cannot be made, or that another read has.
            let Some(target) = read.state.lock().unwrap().sink.reserve_frame(scanout, read.width, read.height, read.format) else {
                continue;
            };
            let started = Instant::now();
            let result = unsafe { (readback.read)(read.resource, target.pixels.cast(), target.len as u64) };
            let took = started.elapsed();
            let shown = read.state.lock().unwrap().sink.finish_frame(target, result == 0);
            // -ENOENT: the guest let go of the resource since its flush.
            let failed = result != 0 && result != -libc::ENOENT;
            {
                let mut stats = reads.lock().unwrap();
                stats.count += 1;
                stats.total += took;
                stats.max = stats.max.max(took);
                stats.failed |= failed;
            }
            if failed {
                eprintln!("[gpu] reading resource {} back on its own thread failed ({result}): frames are read on the render thread from now on", read.resource);
            }
            if shown && !first_frame.swap(true, Ordering::AcqRel) {
                read.events.emit_sticky(format!("gpu first-frame {scanout}"));
            }
        }
    }
}

fn header(code: u32) -> Vec<u8> {
    let mut response = vec![0u8; 24];
    response[0..4].copy_from_slice(&code.to_le_bytes());
    response
}

/// Whether `start..start + len` fits in `0..size`.
pub(super) fn inside(start: u32, len: u32, size: u32) -> bool {
    start.checked_add(len).is_some_and(|end| end <= size)
}

/// Whether a scanout can show a resource made with `args`: one plain 2D
/// image, as gralloc makes them. Flushes read the whole of it back, so a
/// buffer (whose height nothing limits) or an array must never get there.
fn can_scan_out(args: &ResourceCreateArgs) -> bool {
    args.target == PIPE_TEXTURE_2D
        && (1..=16384).contains(&args.width)
        && (1..=16384).contains(&args.height)
        && args.depth <= 1
        && args.array_size <= 1
        && args.nr_samples <= 1
}

/// The Mac's chip, when gfxstream did not name its Vulkan device.
fn chip_name() -> String {
    let mut buffer = [0u8; 128];
    let mut len = buffer.len();
    let found = unsafe {
        libc::sysctlbyname(c"machdep.cpu.brand_string".as_ptr(), buffer.as_mut_ptr().cast(), &mut len, std::ptr::null_mut(), 0)
    } == 0;
    let name = CStr::from_bytes_until_nul(&buffer).map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    if found && !name.is_empty() { name } else { "Apple GPU".into() }
}

/// Reads a whole `width`×`height` color buffer into `buffer` (tight rows:
/// gfxstream ignores the stride argument).
fn read_back(lib: &Library, id: u32, width: u32, height: u32, buffer: &mut [u8]) -> bool {
    let mut area = Box3 { x: 0, y: 0, z: 0, w: width, h: height, d: 1 };
    let mut iov = libc::iovec { iov_base: buffer.as_mut_ptr().cast(), iov_len: buffer.len() };
    unsafe { (lib.transfer_read_iov)(id, 0, 0, width * 4, 0, &mut area, 0, &mut iov, 1) == 0 }
}

impl Renderer {
    fn new(dir: &Path, display: (u32, u32), tx: Sender<Msg>, verbose: bool) -> Result<(Renderer, String), String> {
        let lib = Library::load(dir)?;
        let fence = move |fence: gfxstream::Fence| {
            let ring = if fence.flags & gfxstream::FENCE_RING_IDX != 0 { Ring::Context(fence.ctx_id, fence.ring_idx) } else { Ring::Global };
            let _ = tx.send(Msg::FenceDone { ring, id: fence.fence_id });
        };
        let callbacks: &'static Callbacks = Box::leak(Box::new(Callbacks::new(fence, verbose)));
        lib.init(callbacks, display)?;
        let mut capsets = Vec::new();
        for id in CAPSETS {
            capsets.push((id, lib.capset(id).ok_or(format!("gfxstream has no capset {id}"))?));
        }
        // blobAlignment (word 5): every blob offset must be a host page.
        let alignment = le32(&capsets[0].1, 20);
        if alignment == 0 || alignment as u64 % PAGE != 0 {
            return Err(format!("gfxstream aligns blobs to {alignment} bytes, not {PAGE}"));
        }
        let device = callbacks.device().unwrap_or_else(chip_name);
        let first_frame = Arc::new(AtomicBool::new(false));
        // AVO_FRAMES_ON_RENDER_THREAD=1 keeps the old way, to compare.
        let reader = lib
            .readback
            .filter(|_| std::env::var_os("AVO_FRAMES_ON_RENDER_THREAD").is_none())
            .and_then(|readback| FrameReader::start(readback, first_frame.clone()));
        if verbose || reader.is_some() {
            eprintln!("[gpu] frames are read back {}", if reader.is_some() { "on their own thread" } else { "on the render thread" });
        }
        let renderer = Renderer {
            lib,
            capsets,
            contexts: HashSet::new(),
            resources: HashMap::new(),
            fences: FenceQueue::default(),
            epoch: 1,
            hostmem: HostVisible::new(HOST_VISIBLE_SIZE, Hvf),
            attach: None,
            first_frame,
            saw_context: false,
            stall_mark: None,
            scratch: Vec::new(),
            stats: Stats::default(),
            warned: HashSet::new(),
            reader,
        };
        Ok((renderer, device))
    }

    fn run(mut self, rx: Receiver<Msg>) {
        loop {
            match rx.recv_timeout(Duration::from_secs(1)) {
                Ok(Msg::Activate(attach)) => self.attach = Some(*attach),
                Ok(Msg::Kick(queue)) => self.process(queue),
                Ok(Msg::FenceDone { ring, id }) => self.fence_done(ring, id),
                Ok(Msg::ShmBase(base)) => self.hostmem.rebase(base),
                Ok(Msg::Reset(ack)) => {
                    self.purge();
                    let _ = ack.send(());
                }
                Ok(Msg::Detach(ack)) => {
                    self.purge();
                    // The next boot's guest places the BAR again.
                    self.hostmem.rebase(None);
                    let _ = ack.send(());
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
            self.housekeeping();
        }
    }

    /// Logs `message` once per `key`.
    fn warn_once(&mut self, key: String, message: impl FnOnce() -> String) {
        if self.warned.len() < 1024 && self.warned.insert(key) {
            eprintln!("[gpu] {}", message());
        }
    }

    fn process(&mut self, queue: usize) {
        let Some(mut attach) = self.attach.take() else { return };
        // While this thread drains the queue the guest need not kick for
        // what it adds (a vCPU exit each, a frame's commands come in
        // bursts): kicks go off with the first request and on again once
        // the queue is empty, which it then looks at once more.
        let mut quiet = false;
        loop {
            let chain = {
                let Some(_held) = attach.lease.hold() else { break };
                let active = &mut attach.active;
                let Some(q) = active.queues.get_mut(queue) else { break };
                let chain = q.pop(&active.memory);
                if chain.is_some() != quiet {
                    quiet = chain.is_some();
                    q.set_notifications(&active.memory, !quiet);
                    if !quiet {
                        continue;
                    }
                }
                chain
            };
            let Some(chain) = chain else { break };
            self.request(&mut attach, queue, &chain);
        }
        self.attach = Some(attach);
    }

    fn request(&mut self, attach: &mut Attach, queue: usize, chain: &Chain) {
        let memory = attach.active.memory.clone();
        let request = chain.read_all(&memory).filter(|r| r.len() >= 24);
        let Some(mut request) = request else {
            attach.complete(queue, chain.head, 0);
            return;
        };
        let mut response = self.command(attach, &mut request);
        let flags = le32(&request, 4);
        if flags & FLAG_FENCE != 0 {
            response[4..8].copy_from_slice(&(flags & (FLAG_FENCE | FLAG_INFO_RING_IDX)).to_le_bytes());
            response[8..24].copy_from_slice(&request[8..24]);
        }
        // The command may have taken long enough for a reset to give up on
        // this thread: the guest may own that buffer again.
        let len = match attach.lease.hold() {
            Some(_held) => chain.write_all(&memory, &response) as u32,
            None => return,
        };
        if flags & FLAG_FENCE == 0 {
            attach.complete(queue, chain.head, len);
            return;
        }
        // Answered once gfxstream has done everything before it on its ring.
        let (ctx, ring_idx) = (le32(&request, 16), request[20]);
        let ring = if flags & FLAG_INFO_RING_IDX != 0 { Ring::Context(ctx, ring_idx) } else { Ring::Global };
        let id = (self.epoch as u64) << EPOCH_SHIFT | le64(&request, 8) & ((1 << EPOCH_SHIFT) - 1);
        let fence = gfxstream::Fence {
            flags: gfxstream::FENCE | if let Ring::Context(..) = ring { gfxstream::FENCE_RING_IDX } else { 0 },
            fence_id: id,
            ctx_id: ctx,
            ring_idx,
        };
        let token = Token { queue, head: chain.head, len };
        if unsafe { (self.lib.create_fence)(&fence) } != 0 {
            self.stats.errors += 1;
            // Nothing will signal it: answered with the fence before it.
            if let Some(token) = self.fences.push_after(ring, token, Instant::now()) {
                attach.complete(token.queue, token.head, token.len);
            }
        } else if let Some(token) = self.fences.push(ring, id, token, Instant::now()) {
            attach.complete(token.queue, token.head, token.len);
        }
    }

    fn fence_done(&mut self, ring: Ring, id: u64) {
        if id >> EPOCH_SHIFT != self.epoch as u64 {
            return; // from a guest that was reset since
        }
        let tokens = self.fences.signal(ring, id);
        if let Some(attach) = self.attach.as_mut() {
            for token in tokens {
                attach.complete(token.queue, token.head, token.len);
            }
        }
    }

    fn owns(&self, id: u32) -> bool {
        self.resources.contains_key(&id)
    }

    /// Whether a new resource cannot have `id`: dumb buffers (State) and
    /// renderer resources share one namespace, and commands go by `owns`.
    fn taken(&self, attach: &Attach, id: u32) -> bool {
        id == 0 || self.owns(id) || attach.state.lock().unwrap().resources.contains_key(&id)
    }

    fn command(&mut self, attach: &mut Attach, request: &mut [u8]) -> Vec<u8> {
        let kind = le32(request, 0);
        let ctx = le32(request, 16);
        match kind {
            CMD_GET_CAPSET_INFO => match self.capsets.get(le32(request, 24) as usize) {
                Some((id, data)) => {
                    let mut response = header(RESP_OK_CAPSET_INFO);
                    response.resize(40, 0);
                    response[24..28].copy_from_slice(&id.to_le_bytes());
                    // Version 0 is the only one (max_version stays 0).
                    response[32..36].copy_from_slice(&(data.len() as u32).to_le_bytes());
                    response
                }
                None => header(RESP_ERR_INVALID_PARAMETER),
            },
            CMD_GET_CAPSET => match self.capsets.iter().find(|(id, _)| *id == le32(request, 24)) {
                Some((_, data)) => {
                    let mut response = header(RESP_OK_CAPSET);
                    response.extend_from_slice(data);
                    response
                }
                None => header(RESP_ERR_INVALID_PARAMETER),
            },
            CMD_CTX_CREATE => {
                // Android's graphics have started (gralloc, the composer,
                // SurfaceFlinger): the daemon times the first frame from here.
                if !self.saw_context {
                    self.saw_context = true;
                    attach.events.emit_sticky("gpu context".into());
                }
                self.context_create(ctx, request)
            }
            CMD_CTX_DESTROY => {
                if self.contexts.remove(&ctx) {
                    unsafe { (self.lib.context_destroy)(ctx) };
                }
                // Nothing signals the fences left on its rings now: answered
                // here, or their requests and the guest's dma-fences would hang.
                for token in self.fences.remove_context(ctx) {
                    attach.complete(token.queue, token.head, token.len);
                }
                header(RESP_OK_NODATA)
            }
            CMD_CTX_ATTACH_RESOURCE | CMD_CTX_DETACH_RESOURCE => {
                // Dumb buffers are attached too: nothing to do for them.
                let id = le32(request, 24);
                if self.owns(id) && self.contexts.contains(&ctx) {
                    let call = if kind == CMD_CTX_ATTACH_RESOURCE { self.lib.ctx_attach_resource } else { self.lib.ctx_detach_resource };
                    unsafe { call(ctx as i32, id as i32) };
                }
                header(RESP_OK_NODATA)
            }
            CMD_RESOURCE_CREATE_3D => self.create_3d(attach, request),
            CMD_TRANSFER_TO_HOST_3D | CMD_TRANSFER_FROM_HOST_3D => self.transfer_3d(kind, ctx, request),
            CMD_SUBMIT_3D => {
                let size = le32(request, 24) as usize;
                if size > request.len().saturating_sub(32) {
                    return header(RESP_ERR_INVALID_PARAMETER);
                }
                let mut command = gfxstream::Command {
                    ctx_id: ctx,
                    cmd_size: size as u32,
                    cmd: request[32..].as_mut_ptr(),
                    num_in_fences: 0,
                    fences: std::ptr::null(),
                };
                if unsafe { (self.lib.submit_cmd)(&mut command) } != 0 {
                    self.stats.errors += 1;
                    return header(RESP_ERR_UNSPEC);
                }
                header(RESP_OK_NODATA)
            }
            CMD_RESOURCE_CREATE_BLOB => self.create_blob(attach, ctx, request),
            CMD_RESOURCE_MAP_BLOB => self.map_blob(request),
            CMD_RESOURCE_UNMAP_BLOB => {
                let id = le32(request, 24);
                self.hostmem.unmap(id);
                header(if self.owns(id) { RESP_OK_NODATA } else { RESP_ERR_INVALID_RESOURCE_ID })
            }
            CMD_SET_SCANOUT_BLOB => {
                // This guest's composer scans out 3D resources, never blobs.
                self.stats.unknown += 1;
                header(RESP_ERR_UNSPEC)
            }
            CMD_RESOURCE_UNREF if self.owns(le32(request, 24)) => {
                let id = le32(request, 24);
                let resource = self.resources.remove(&id).unwrap();
                self.release(id, &resource);
                for scanout in &mut attach.state.lock().unwrap().scanouts {
                    if scanout.resource == id {
                        scanout.resource = 0;
                        scanout.rect = None;
                    }
                }
                header(RESP_OK_NODATA)
            }
            CMD_SET_SCANOUT if self.owns(le32(request, 44)) => self.set_scanout(attach, request),
            CMD_RESOURCE_FLUSH if self.owns(le32(request, 40)) => {
                self.flush(attach, le32(request, 40));
                header(RESP_OK_NODATA)
            }
            CMD_RESOURCE_ATTACH_BACKING if self.owns(le32(request, 24)) => self.attach_backing(attach, request),
            CMD_RESOURCE_DETACH_BACKING if self.owns(le32(request, 24)) => {
                let id = le32(request, 24);
                if std::mem::take(&mut self.resources.get_mut(&id).unwrap().backing) {
                    self.detach_iov(id);
                }
                header(RESP_OK_NODATA)
            }
            // State checks its own ids.
            CMD_RESOURCE_CREATE_2D if self.owns(le32(request, 24)) => header(RESP_ERR_INVALID_RESOURCE_ID),
            CMD_GET_DISPLAY_INFO | CMD_GET_EDID | CMD_RESOURCE_CREATE_2D | CMD_RESOURCE_UNREF | CMD_SET_SCANOUT | CMD_RESOURCE_FLUSH
            | CMD_TRANSFER_TO_HOST_2D | CMD_RESOURCE_ATTACH_BACKING | CMD_RESOURCE_DETACH_BACKING | CMD_UPDATE_CURSOR
            | CMD_MOVE_CURSOR => attach.state.lock().unwrap().command(&attach.active.memory, request),
            _ => {
                self.stats.unknown += 1;
                self.warn_once(format!("command {kind:#x}"), || format!("unknown command {kind:#x}"));
                header(RESP_ERR_UNSPEC)
            }
        }
    }

    fn context_create(&mut self, ctx: u32, request: &[u8]) -> Vec<u8> {
        if self.contexts.contains(&ctx) {
            return header(RESP_OK_NODATA);
        }
        let name_len = (le32(request, 24) as usize).min(64).min(request.len().saturating_sub(32));
        let name = request.get(32..32 + name_len).unwrap_or_default();
        // The raw context_init: capset 3 for ANGLE and Vulkan, 0 for contexts
        // the kernel or minigbm create.
        let init = le32(request, 28);
        if unsafe { (self.lib.context_create)(ctx, name_len as u32, name.as_ptr().cast(), init) } != 0 {
            self.stats.errors += 1;
            return header(RESP_ERR_UNSPEC);
        }
        self.contexts.insert(ctx);
        header(RESP_OK_NODATA)
    }

    fn create_3d(&mut self, attach: &Attach, request: &[u8]) -> Vec<u8> {
        let field = |at: usize| le32(request, at);
        let args = ResourceCreateArgs {
            handle: field(24),
            target: field(28),
            format: field(32),
            bind: field(36),
            width: field(40),
            height: field(44),
            depth: field(48),
            array_size: field(52),
            last_level: field(56),
            nr_samples: field(60),
            flags: field(64),
        };
        let id = args.handle;
        if self.taken(attach, id) {
            return header(RESP_ERR_INVALID_RESOURCE_ID);
        }
        // Buffers (the process pipe's) give their size in bytes as the width.
        let fits = if args.target == PIPE_BUFFER { args.width <= 1 << 28 } else { args.width <= 16384 && args.height <= 16384 };
        if args.width == 0 || !fits {
            return header(RESP_ERR_INVALID_PARAMETER);
        }
        let mut create = args;
        if unsafe { (self.lib.resource_create)(&mut create, std::ptr::null_mut(), 0) } != 0 {
            self.stats.errors += 1;
            return header(RESP_ERR_UNSPEC);
        }
        self.resources.insert(id, Resource { args: Some(args), blob: None, backing: false });
        header(RESP_OK_NODATA)
    }

    fn transfer_3d(&mut self, kind: u32, ctx: u32, request: &[u8]) -> Vec<u8> {
        let field = |at: usize| le32(request, at);
        let mut area = Box3 { x: field(24), y: field(28), z: field(32), w: field(36), h: field(40), d: field(44) };
        let (offset, id, level, stride, layer_stride) = (le64(request, 48), field(56), field(60), field(64), field(68));
        let Some(args) = self.resources.get(&id).and_then(|r| r.args) else { return header(RESP_ERR_INVALID_RESOURCE_ID) };
        // gfxstream checks only part of the box, and one outside the
        // resource would reach past its buffers.
        if !inside(area.x, area.w, args.width) || !inside(area.y, area.h, args.height.max(1)) {
            return header(RESP_ERR_INVALID_PARAMETER);
        }
        // In order with everything else on this thread: the process pipe
        // relies on it.
        let result = unsafe {
            if kind == CMD_TRANSFER_TO_HOST_3D {
                (self.lib.transfer_write_iov)(id, ctx, level as i32, stride, layer_stride, &mut area, offset, std::ptr::null_mut(), 0)
            } else {
                (self.lib.transfer_read_iov)(id, ctx, level, stride, layer_stride, &mut area, offset, std::ptr::null_mut(), 0)
            }
        };
        if result != 0 {
            self.stats.errors += 1;
            return header(RESP_ERR_UNSPEC);
        }
        header(RESP_OK_NODATA)
    }

    fn create_blob(&mut self, attach: &Attach, ctx: u32, request: &[u8]) -> Vec<u8> {
        let (id, memory, flags, entries) = (le32(request, 24), le32(request, 28), le32(request, 32), le32(request, 36));
        let (blob_id, size) = (le64(request, 40), le64(request, 48));
        if !self.contexts.contains(&ctx) {
            return header(RESP_ERR_INVALID_CONTEXT_ID);
        }
        if self.taken(attach, id) {
            return header(RESP_ERR_INVALID_RESOURCE_ID);
        }
        if memory != gfxstream::BLOB_MEM_HOST3D || entries != 0 {
            self.stats.unknown += 1;
            self.warn_once(format!("blob memory {memory}"), || format!("blob memory {memory} with {entries} entries is not supported"));
            return header(RESP_ERR_UNSPEC);
        }
        // Blob id 0 is an ASG ring the renderer allocates at the guest's
        // size; other ids are Vulkan memory the guest made with
        // vkGetBlobGOOGLE.
        if size == 0 || size > HOST_VISIBLE_SIZE || (blob_id == 0 && size > RING_BLOB_MAX) {
            return header(RESP_ERR_INVALID_PARAMETER);
        }
        // Rounded so a mapping of whole host pages never exposes the heap
        // next to a ring.
        let len = size.next_multiple_of(PAGE);
        let create = CreateBlob { blob_mem: memory, blob_flags: flags, blob_id, size: len };
        if unsafe { (self.lib.create_blob)(ctx, id, &create, std::ptr::null(), 0, std::ptr::null()) } != 0 {
            self.stats.errors += 1;
            return header(RESP_ERR_UNSPEC);
        }
        let mut blob = Blob { host: 0, len, mapped: false };
        if flags & gfxstream::BLOB_FLAG_USE_MAPPABLE != 0 {
            // create_blob says 0 even when it failed: the map tells.
            let (mut host, mut host_size): (*mut c_void, u64) = (std::ptr::null_mut(), 0);
            let result = unsafe { (self.lib.resource_map)(id, &mut host, &mut host_size) };
            let usable = result == 0
                && !host.is_null()
                && host as u64 % PAGE == 0
                && (host_size == 0 || len <= host_size.next_multiple_of(PAGE))
                && (blob_id == 0 || hostmem::host_range_ok(host as usize, len));
            if !usable {
                if result == 0 {
                    unsafe { (self.lib.resource_unmap)(id) };
                }
                unsafe { (self.lib.resource_unref)(id) };
                self.stats.errors += 1;
                self.warn_once(format!("blob {id}"), || {
                    format!("blob {id} (id {blob_id}, {size} bytes) is not mappable: map {result}, host {host:?} +{host_size:#x}")
                });
                return header(RESP_ERR_INVALID_PARAMETER);
            }
            blob = Blob { host: host as usize, len, mapped: true };
        }
        self.resources.insert(id, Resource { args: None, blob: Some(blob), backing: false });
        header(RESP_OK_NODATA)
    }

    fn map_blob(&mut self, request: &[u8]) -> Vec<u8> {
        let (id, offset) = (le32(request, 24), le64(request, 32));
        let Some(blob) = self.resources.get(&id).and_then(|r| r.blob) else { return header(RESP_ERR_INVALID_RESOURCE_ID) };
        if !blob.mapped {
            return header(RESP_ERR_INVALID_PARAMETER);
        }
        // Mapped before the guest hears back, so it never touches the range
        // unbacked.
        if let Err(e) = self.hostmem.map(id, offset, blob.host, blob.len) {
            let rejected = self.hostmem.rejected;
            if rejected <= 8 {
                eprintln!("[gpu] map of blob {id} at {offset:#x} +{:#x} refused: {e:?}", blob.len);
            }
            return header(RESP_ERR_INVALID_PARAMETER);
        }
        let mut response = header(RESP_OK_MAP_INFO);
        response.resize(32, 0);
        response[24..28].copy_from_slice(&MAP_CACHE_CACHED.to_le_bytes());
        response
    }

    fn set_scanout(&mut self, attach: &Attach, request: &[u8]) -> Vec<u8> {
        let (r, index, id) = (rect(request, 24), le32(request, 40) as usize, le32(request, 44));
        if index >= MAX_SCANOUTS {
            return header(RESP_ERR_INVALID_SCANOUT_ID);
        }
        let Some(args) = self.resources.get(&id).and_then(|r| r.args) else { return header(RESP_ERR_INVALID_RESOURCE_ID) };
        if !can_scan_out(&args) || r.width == 0 || r.height == 0 || !r.within(args.width, args.height) {
            return header(RESP_ERR_INVALID_PARAMETER);
        }
        let mut state = attach.state.lock().unwrap();
        state.scanouts[index].resource = id;
        state.scanouts[index].rect = Some(r);
        header(RESP_OK_NODATA)
    }

    fn attach_backing(&mut self, attach: &Attach, request: &[u8]) -> Vec<u8> {
        let (id, entries) = (le32(request, 24), le32(request, 28) as usize);
        if 32 + entries.saturating_mul(16) > request.len() {
            return header(RESP_ERR_INVALID_PARAMETER);
        }
        let mut iovs: Vec<libc::iovec> = Vec::with_capacity(entries);
        for i in 0..entries {
            let at = 32 + i * 16;
            let (address, len) = (le64(request, at), le32(request, at + 8) as usize);
            let Some(host) = attach.active.memory.host_ptr(address, len) else { return header(RESP_ERR_UNSPEC) };
            // Guest RAM is one host mapping: pages that follow each other
            // make one entry.
            if let Some(last) = iovs.last_mut()
                && last.iov_base as usize + last.iov_len == host as usize
            {
                last.iov_len += len;
                continue;
            }
            iovs.push(libc::iovec { iov_base: host.cast(), iov_len: len });
        }
        if std::mem::take(&mut self.resources.get_mut(&id).unwrap().backing) {
            self.detach_iov(id);
        }
        if unsafe { (self.lib.resource_attach_iov)(id as i32, iovs.as_mut_ptr(), iovs.len() as i32) } != 0 {
            self.stats.errors += 1;
            return header(RESP_ERR_UNSPEC);
        }
        self.resources.get_mut(&id).unwrap().backing = true;
        header(RESP_OK_NODATA)
    }

    fn detach_iov(&self, id: u32) {
        let (mut iov, mut count) = (std::ptr::null_mut(), 0);
        unsafe { (self.lib.resource_detach_iov)(id as i32, &mut iov, &mut count) };
    }

    /// Lets go of a resource in gfxstream: out of the guest's view first.
    fn release(&mut self, id: u32, resource: &Resource) {
        if let Some(blob) = resource.blob {
            self.hostmem.unmap(id);
            if blob.mapped {
                unsafe { (self.lib.resource_unmap)(id) };
            }
        }
        if resource.backing {
            self.detach_iov(id);
        }
        unsafe { (self.lib.resource_unref)(id) };
    }

    /// Reads resource `id` back into the frames of every scanout showing it.
    /// 3D flushes carry no fence, so frames are a mailbox: the newest wins.
    fn flush(&mut self, attach: &Attach, id: u32) {
        self.stats.flushes += 1;
        let Some(args) = self.resources.get(&id).and_then(|r| r.args) else { return };
        // set_scanout lets no other resource onto a scanout; checked here
        // too, as the sizes below come from the guest.
        if !can_scan_out(&args) {
            return;
        }
        let Some(format) = Format::from_virtio(args.format) else {
            let virgl = args.format;
            self.warn_once(format!("format {virgl}"), || format!("scanout format {virgl} cannot be shown"));
            return;
        };
        let (width, height) = (args.width, args.height);
        let mut first = None;
        let mut failed = false;
        let reader = self.reader.as_ref().filter(|reader| reader.usable());
        {
            let mut guard = attach.state.lock().unwrap();
            let state = &mut *guard;
            for index in 0..MAX_SCANOUTS {
                let scanout = state.scanouts[index];
                let r = scanout.rect.unwrap_or(Rect { x: 0, y: 0, width, height });
                // A rect that does not fit would panic the copy below, with
                // the State lock held.
                if !scanout.enabled || scanout.resource != id || !r.within(width, height) {
                    continue;
                }
                let whole = (r.x, r.y, r.width, r.height) == (0, 0, width, height);
                if let Some(reader) = reader.filter(|_| whole) {
                    let read = Read { resource: id, width, height, format, state: attach.state.clone(), events: attach.events.clone() };
                    reader.request(index, read);
                    continue;
                }
                let started = Instant::now();
                let lib = &self.lib;
                let shown = if (r.x, r.y, r.width, r.height) == (0, 0, width, height) {
                    state.sink.fill_frame(index, width, height, format, &mut |buffer| read_back(lib, id, width, height, buffer))
                } else {
                    // gfxstream reads whole color buffers: the shown part
                    // comes from a copy.
                    let scratch = &mut self.scratch;
                    // Up to 1 GiB (can_scan_out): when that cannot be had,
                    // the frame is lost, not the process.
                    let size = width as usize * height as usize * 4;
                    let room = scratch.try_reserve_exact(size.saturating_sub(scratch.len())).is_ok();
                    if room {
                        scratch.resize(size, 0);
                    }
                    room && read_back(lib, id, width, height, scratch)
                        && state.sink.fill_frame(index, r.width, r.height, format, &mut |buffer| {
                            let row = r.width as usize * 4;
                            for y in 0..r.height as usize {
                                let from = ((r.y as usize + y) * width as usize + r.x as usize) * 4;
                                buffer[y * row..(y + 1) * row].copy_from_slice(&scratch[from..from + row]);
                            }
                            true
                        })
                };
                let took = started.elapsed();
                self.stats.readbacks += 1;
                self.stats.readback_total += took;
                self.stats.readback_max = self.stats.readback_max.max(took);
                failed |= !shown;
                if shown && first.is_none() && !self.first_frame.load(Ordering::Acquire) {
                    first = Some(index);
                }
            }
        }
        if failed {
            self.warn_once(format!("readback {id}"), || format!("resource {id} ({width}x{height}) could not be read back"));
        }
        if let Some(index) = first
            && !self.first_frame.swap(true, Ordering::AcqRel)
        {
            attach.events.emit_sticky(format!("gpu first-frame {index}"));
        }
    }

    /// Everything the guest made goes (device reset, or the end of a boot);
    /// the renderer itself stays. The order matters: out of the guest's
    /// view, contexts, then resources, and only then the guest memory.
    fn purge(&mut self) {
        self.hostmem.purge();
        for ctx in std::mem::take(&mut self.contexts) {
            unsafe { (self.lib.context_destroy)(ctx) };
        }
        for (id, resource) in std::mem::take(&mut self.resources) {
            self.release(id, &resource);
        }
        self.fences.clear();
        self.epoch = self.epoch.wrapping_add(1);
        if let Some(reader) = &self.reader {
            reader.clear();
        }
        self.first_frame.store(false, Ordering::Release);
        self.saw_context = false;
        self.stall_mark = None;
        self.attach = None;
        self.scratch = Vec::new();
    }

    /// The stall check and the periodic engine log line.
    fn housekeeping(&mut self) {
        let now = Instant::now();
        match self.stall_mark {
            None => {
                if let Some(age) = self.fences.oldest(now).filter(|age| *age >= STALL) {
                    self.stall_mark = Some(now);
                    eprintln!("[gpu] a guest fence has waited {} ms", age.as_millis());
                    if let Some(attach) = &self.attach {
                        attach.events.emit(format!("gpu stalled {}", age.as_millis()));
                    }
                }
            }
            // Re-armed once every fence that was waiting then is done.
            Some(mark) => {
                if self.fences.oldest_since().is_none_or(|since| since > mark) {
                    self.stall_mark = None;
                }
            }
        }
        let window = *self.stats.window.get_or_insert(now);
        let elapsed = now.duration_since(window);
        if elapsed < STATS_EVERY {
            return;
        }
        if let Some(reader) = &self.reader {
            let (count, total, max) = reader.take_stats();
            self.stats.readbacks += count;
            self.stats.readback_total += total;
            self.stats.readback_max = self.stats.readback_max.max(max);
        }
        let blobs = self.resources.values().filter(|r| r.blob.is_some()).count();
        // A line while frames flow or anything else changed.
        let counters = (
            self.contexts.len(),
            self.resources.len(),
            blobs,
            self.hostmem.mapped_bytes(),
            self.fences.len(),
            self.hostmem.rejected,
            self.stats.unknown,
            self.stats.errors,
        );
        if self.stats.printed != Some(counters) || self.stats.flushes > 0 {
            let average = if self.stats.readbacks > 0 { self.stats.readback_total / self.stats.readbacks as u32 } else { Duration::ZERO };
            let ms = |d: Duration| d.as_secs_f64() * 1000.0;
            eprintln!(
                "[gpu] ctx={} res={} blobs={blobs} mapped={}MiB fences={} oldest={}ms flush/s={:.0} readback avg/max={:.2}/{:.2}ms \
                 rejected-maps={} unknown={} errors={}",
                self.contexts.len(),
                self.resources.len(),
                self.hostmem.mapped_bytes() >> 20,
                self.fences.len(),
                self.fences.oldest(now).unwrap_or_default().as_millis(),
                self.stats.flushes as f64 / elapsed.as_secs_f64(),
                ms(average),
                ms(self.stats.readback_max),
                self.hostmem.rejected,
                self.stats.unknown,
                self.stats.errors
            );
            self.stats.printed = Some(counters);
        }
        self.stats.window = Some(now);
        self.stats.flushes = 0;
        self.stats.readbacks = 0;
        self.stats.readback_total = Duration::ZERO;
        self.stats.readback_max = Duration::ZERO;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_plain_2d_images_can_be_scanned_out() {
        let image = ResourceCreateArgs { target: PIPE_TEXTURE_2D, format: 1, width: 1080, height: 2400, depth: 1, array_size: 1, ..Default::default() };
        assert!(can_scan_out(&image));
        assert!(!can_scan_out(&ResourceCreateArgs { target: PIPE_BUFFER, width: 1 << 28, height: u32::MAX, ..image }), "a buffer");
        assert!(!can_scan_out(&ResourceCreateArgs { height: 16385, ..image }));
        assert!(!can_scan_out(&ResourceCreateArgs { depth: 2, ..image }));
        assert!(!can_scan_out(&ResourceCreateArgs { array_size: 6, ..image }));
        assert!(!can_scan_out(&ResourceCreateArgs { nr_samples: 4, ..image }));
    }

    #[test]
    fn an_ended_lease_is_never_held_again() {
        let lease = Lease::new();
        assert!(lease.hold().is_some());
        lease.clone().end();
        assert!(lease.hold().is_none());
    }
}
