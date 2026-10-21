//! virtio-gpu (virtio 1.2 §5.7). In 2D mode the guest renders with
//! SwiftShader into dumb buffers, the device keeps a host copy of each
//! resource and hands finished frames of every scanout to a [`FrameSink`].
//! In GPU mode (`Gpu::with_renderer`) the device also offers 3D, blobs and
//! context init, and gfxstream renders on the Mac's GPU (render.rs).
//!
//! Each scanout is one Android display. Scanouts can be enabled, resized
//! and disabled at run time (VIRTIO_GPU_EVENT_DISPLAY), which Cuttlefish's
//! hwcomposer treats as display hotplug: Avo maps one scanout to one Mac
//! window. Each scanout also has a refresh rate, which the guest reads from
//! its EDID (edid.rs).

mod astc;
mod cache;
pub mod edid;
mod fence;
mod gfxstream;
pub mod guest;
pub mod hostmem;
pub mod render;

use super::queue::{Chain, Queue};
use super::{Active, Interrupt, VirtioDevice};
use crate::frames::FrameHandle;
use crate::memory::GuestMemory;
use render::{Attach, Lease, Msg, RenderHost, inside};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// How Android renders.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GpuMode {
    /// SwiftShader in the guest, frames from dumb buffers (Software).
    TwoD,
    /// gfxstream from the Android Emulator in `dir`: the guest's GLES (on
    /// ANGLE) and Vulkan run on the Mac's GPU.
    Gfxstream { dir: PathBuf, hwc: Hwc },
}

/// Who composes Android's layers in GPU mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Hwc {
    /// SurfaceFlinger, on the GPU; the composer only flips the result.
    Client,
    /// The composer through gfxstream's host composition (bring-up A/B).
    Host,
}

pub const TYPE_GPU: u16 = 16;
pub const MAX_SCANOUTS: usize = 16;

const CMD_GET_DISPLAY_INFO: u32 = 0x0100;
const CMD_RESOURCE_CREATE_2D: u32 = 0x0101;
const CMD_RESOURCE_UNREF: u32 = 0x0102;
const CMD_SET_SCANOUT: u32 = 0x0103;
const CMD_RESOURCE_FLUSH: u32 = 0x0104;
const CMD_TRANSFER_TO_HOST_2D: u32 = 0x0105;
const CMD_RESOURCE_ATTACH_BACKING: u32 = 0x0106;
const CMD_RESOURCE_DETACH_BACKING: u32 = 0x0107;
const CMD_GET_EDID: u32 = 0x010a;
const CMD_UPDATE_CURSOR: u32 = 0x0300;
const CMD_MOVE_CURSOR: u32 = 0x0301;

const RESP_OK_NODATA: u32 = 0x1100;
const RESP_OK_DISPLAY_INFO: u32 = 0x1101;
const RESP_OK_EDID: u32 = 0x1104;
const RESP_ERR_UNSPEC: u32 = 0x1200;
const RESP_ERR_OUT_OF_MEMORY: u32 = 0x1201;
const RESP_ERR_INVALID_SCANOUT_ID: u32 = 0x1202;
const RESP_ERR_INVALID_RESOURCE_ID: u32 = 0x1203;
const RESP_ERR_INVALID_PARAMETER: u32 = 0x1205;

const FLAG_FENCE: u32 = 1;
const EVENT_DISPLAY: u32 = 1;
/// VIRTIO_GPU_F_EDID, in both modes.
const FEATURE_EDID: u64 = 1 << 1;

/// Pixel layouts the guest may ask for (all 32 bits per pixel).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Bgra,
    Bgrx,
    Argb,
    Xrgb,
    Rgba,
    Xbgr,
    Abgr,
    Rgbx,
}

impl Format {
    fn from_virtio(value: u32) -> Option<Format> {
        Some(match value {
            1 => Format::Bgra,
            2 => Format::Bgrx,
            3 => Format::Argb,
            4 => Format::Xrgb,
            67 => Format::Rgba,
            68 => Format::Xbgr,
            121 => Format::Abgr,
            134 => Format::Rgbx,
            _ => return None,
        })
    }

    /// Byte positions of blue, green, red and alpha within a pixel.
    /// The same layout with red and blue exchanged.
    pub fn swapping_red_blue(self) -> Format {
        match self {
            Format::Bgra => Format::Rgba,
            Format::Bgrx => Format::Rgbx,
            Format::Rgba => Format::Bgra,
            Format::Rgbx => Format::Bgrx,
            Format::Argb => Format::Abgr,
            Format::Xrgb => Format::Xbgr,
            Format::Abgr => Format::Argb,
            Format::Xbgr => Format::Xrgb,
        }
    }

    pub fn bgra_positions(self) -> [usize; 4] {
        match self {
            Format::Bgra | Format::Bgrx => [0, 1, 2, 3],
            Format::Argb | Format::Xrgb => [3, 2, 1, 0],
            Format::Rgba | Format::Rgbx => [2, 1, 0, 3],
            Format::Abgr | Format::Xbgr => [1, 2, 3, 0],
        }
    }
}

/// A finished frame of one scanout: `height` rows of `width` pixels (4 bytes
/// each), `stride` bytes apart, starting at the first byte of `pixels`.
pub struct Frame<'a> {
    pub scanout: usize,
    pub width: u32,
    pub height: u32,
    pub stride: usize,
    pub format: Format,
    pub pixels: &'a [u8],
}

/// Receives frames as the guest flushes them.
pub trait FrameSink: Send {
    fn frame(&mut self, frame: Frame);
    /// The scanout was unplugged: its frames are no longer needed.
    fn scanout_removed(&mut self, _scanout: usize) {}
    /// Hands `fill` a buffer for a `width`×`height` frame (rows of
    /// `width * 4` bytes) and publishes it if `fill` returns true: GPU
    /// readback writes frames in place instead of into a copy.
    fn fill_frame(&mut self, scanout: usize, width: u32, height: u32, format: Format, fill: &mut dyn FnMut(&mut [u8]) -> bool) -> bool {
        let mut pixels = vec![0u8; width as usize * height as usize * 4];
        if !fill(&mut pixels) {
            return false;
        }
        self.frame(Frame { scanout, width, height, stride: width as usize * 4, format, pixels: &pixels });
        true
    }
}

#[derive(Clone, Copy, Default)]
struct Scanout {
    width: u32,
    height: u32,
    enabled: bool,
    resource: u32,
    /// The part of the resource shown (SET_SCANOUT), usually smaller than an
    /// aligned framebuffer.
    rect: Option<Rect>,
    /// Refresh rate in Hz, which its EDID gives the guest.
    refresh: u32,
}

struct Resource {
    width: u32,
    height: u32,
    format: Format,
    host: Vec<u8>,
    backing: Vec<(u64, usize)>,
}

struct State {
    scanouts: [Scanout; MAX_SCANOUTS],
    resources: HashMap<u32, Resource>,
    events: u32,
    active: Option<Active>,
    sink: Box<dyn FrameSink>,
    /// GPU mode: the render thread holds `Active`; display changes still
    /// need the interrupt.
    config_interrupt: Option<Interrupt>,
}

/// Lets other threads add, resize or remove displays while the guest runs.
#[derive(Clone)]
pub struct DisplayControl(Arc<Mutex<State>>);

impl DisplayControl {
    /// Enables (or resizes) scanout `index` at `width`, `height` and
    /// refresh rate `hz`; `None` unplugs it.
    pub fn set_display(&self, index: usize, mode: Option<(u32, u32, u32)>) {
        let mut state = self.0.lock().unwrap();
        if index >= MAX_SCANOUTS {
            return;
        }
        let scanout = &mut state.scanouts[index];
        match mode {
            Some((width, height, hz)) => {
                scanout.width = width;
                scanout.height = height;
                scanout.refresh = hz;
                scanout.enabled = true;
            }
            None => {
                scanout.enabled = false;
                state.sink.scanout_removed(index);
            }
        }
        state.events |= EVENT_DISPLAY;
        if let Some(active) = &state.active {
            active.interrupt.signal_config();
        } else if let Some(interrupt) = &state.config_interrupt {
            interrupt.signal_config();
        }
    }
}

pub struct Gpu {
    state: Arc<Mutex<State>>,
    /// GPU mode: the process's renderer and where its events go.
    renderer: Option<(RenderHost, FrameHandle)>,
    /// GPU mode: the render thread's use of the current activation.
    lease: Option<Lease>,
}

impl Gpu {
    /// `displays`: initial sizes of scanouts 0, 1, ... (at 60 Hz)
    pub fn new(displays: &[(u32, u32)], sink: Box<dyn FrameSink>) -> Gpu {
        let mut scanouts = [Scanout { refresh: edid::DEFAULT_RATE, ..Scanout::default() }; MAX_SCANOUTS];
        for (i, &(width, height)) in displays.iter().enumerate().take(MAX_SCANOUTS) {
            scanouts[i] = Scanout { width, height, enabled: true, resource: 0, rect: None, refresh: edid::DEFAULT_RATE };
        }
        let state = State { scanouts, resources: HashMap::new(), events: 0, active: None, sink, config_interrupt: None };
        Gpu { state: Arc::new(Mutex::new(state)), renderer: None, lease: None }
    }

    /// GPU mode: commands run on `host`'s render thread, which reads frames
    /// back into `sink` and sends `gpu` events through `events`.
    pub fn with_renderer(displays: &[(u32, u32)], sink: Box<dyn FrameSink>, host: RenderHost, events: FrameHandle) -> Gpu {
        let mut gpu = Gpu::new(displays, sink);
        gpu.renderer = Some((host, events));
        gpu
    }

    /// The initial displays at `hz` instead of 60 (the rate of the others
    /// comes with their `set_display`).
    pub fn at_refresh_rate(self, hz: u32) -> Gpu {
        for scanout in &mut self.state.lock().unwrap().scanouts {
            scanout.refresh = hz;
        }
        self
    }

    pub fn control(&self) -> DisplayControl {
        DisplayControl(self.state.clone())
    }
}

fn le32(data: &[u8], at: usize) -> u32 {
    data.get(at..at + 4).map(|b| u32::from_le_bytes(b.try_into().unwrap())).unwrap_or(0)
}

fn le64(data: &[u8], at: usize) -> u64 {
    data.get(at..at + 8).map(|b| u64::from_le_bytes(b.try_into().unwrap())).unwrap_or(0)
}

#[derive(Clone, Copy, Default)]
struct Rect {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
}

fn rect(data: &[u8], at: usize) -> Rect {
    Rect { x: le32(data, at), y: le32(data, at + 4), width: le32(data, at + 8), height: le32(data, at + 12) }
}

impl Rect {
    /// Whether the rect lies within a `width`×`height` resource (without
    /// the wrap-around a plain `x + width` of guest values allows).
    fn within(&self, width: u32, height: u32) -> bool {
        inside(self.x, self.width, width) && inside(self.y, self.height, height)
    }
}

/// Copies `out.len()` bytes starting at `offset` of a scatter-gather backing.
fn read_backing(memory: &GuestMemory, backing: &[(u64, usize)], mut offset: usize, out: &mut [u8]) -> bool {
    let mut filled = 0;
    for &(address, len) in backing {
        if offset >= len {
            offset -= len;
            continue;
        }
        let take = (len - offset).min(out.len() - filled);
        let Some(start) = address.checked_add(offset as u64) else { return false };
        if !memory.read(start, &mut out[filled..filled + take]) {
            return false;
        }
        filled += take;
        offset = 0;
        if filled == out.len() {
            return true;
        }
    }
    filled == out.len()
}

impl State {
    fn display_info(&self) -> Vec<u8> {
        let mut response = vec![0u8; 24 + MAX_SCANOUTS * 24];
        response[0..4].copy_from_slice(&RESP_OK_DISPLAY_INFO.to_le_bytes());
        for (i, s) in self.scanouts.iter().enumerate() {
            let at = 24 + i * 24;
            response[at + 8..at + 12].copy_from_slice(&s.width.to_le_bytes());
            response[at + 12..at + 16].copy_from_slice(&s.height.to_le_bytes());
            response[at + 16..at + 20].copy_from_slice(&(s.enabled as u32).to_le_bytes());
        }
        response
    }

    /// VIRTIO_GPU_RESP_OK_EDID: an unplugged scanout's has no bytes, as
    /// a monitor that is not there has none.
    fn edid(&self, index: usize) -> Vec<u8> {
        let s = &self.scanouts[index];
        let bytes = if s.enabled { edid::edid(index, s.width, s.height, s.refresh) } else { Vec::new() };
        let mut response = vec![0u8; 32 + 1024];
        response[0..4].copy_from_slice(&RESP_OK_EDID.to_le_bytes());
        response[24..28].copy_from_slice(&(bytes.len() as u32).to_le_bytes());
        response[32..32 + bytes.len()].copy_from_slice(&bytes);
        response
    }

    fn command(&mut self, memory: &GuestMemory, request: &[u8]) -> Vec<u8> {
        let kind = le32(request, 0);
        let ok = || RESP_OK_NODATA;
        let code = match kind {
            CMD_GET_DISPLAY_INFO => return self.display_info(),
            CMD_GET_EDID => match le32(request, 24) as usize {
                index if index < MAX_SCANOUTS => return self.edid(index),
                _ => RESP_ERR_INVALID_SCANOUT_ID,
            },
            CMD_RESOURCE_CREATE_2D => {
                let (id, format, width, height) = (le32(request, 24), le32(request, 28), le32(request, 32), le32(request, 36));
                match Format::from_virtio(format) {
                    None => RESP_ERR_INVALID_PARAMETER,
                    Some(_) if id == 0 || width == 0 || height == 0 || width > 16384 || height > 16384 => RESP_ERR_INVALID_PARAMETER,
                    // Never over a live id: scanouts showing it keep their
                    // rect. (GPU mode: the renderer refuses its own ids first.)
                    Some(_) if self.resources.contains_key(&id) => RESP_ERR_INVALID_RESOURCE_ID,
                    Some(format) => {
                        let size = width as usize * height as usize * 4;
                        let mut host = Vec::new();
                        if host.try_reserve_exact(size).is_err() {
                            RESP_ERR_OUT_OF_MEMORY
                        } else {
                            host.resize(size, 0);
                            self.resources.insert(id, Resource { width, height, format, host, backing: Vec::new() });
                            ok()
                        }
                    }
                }
            }
            CMD_RESOURCE_UNREF => {
                let id = le32(request, 24);
                if self.resources.remove(&id).is_some() {
                    for s in &mut self.scanouts {
                        if s.resource == id {
                            s.resource = 0;
                        }
                    }
                    ok()
                } else {
                    RESP_ERR_INVALID_RESOURCE_ID
                }
            }
            CMD_RESOURCE_ATTACH_BACKING => {
                let (id, entries) = (le32(request, 24), le32(request, 28) as usize);
                // The count is the guest's: checked against the request
                // before anything is reserved for it.
                if 32 + entries.saturating_mul(16) > request.len() {
                    RESP_ERR_INVALID_PARAMETER
                } else {
                    let backing = (0..entries).map(|i| (le64(request, 32 + i * 16), le32(request, 40 + i * 16) as usize)).collect();
                    match self.resources.get_mut(&id) {
                        Some(resource) => {
                            resource.backing = backing;
                            ok()
                        }
                        None => RESP_ERR_INVALID_RESOURCE_ID,
                    }
                }
            }
            CMD_RESOURCE_DETACH_BACKING => match self.resources.get_mut(&le32(request, 24)) {
                Some(resource) => {
                    resource.backing.clear();
                    ok()
                }
                None => RESP_ERR_INVALID_RESOURCE_ID,
            },
            CMD_TRANSFER_TO_HOST_2D => {
                let r = rect(request, 24);
                let offset = le64(request, 40) as usize;
                let id = le32(request, 48);
                match self.resources.get_mut(&id) {
                    None => RESP_ERR_INVALID_RESOURCE_ID,
                    Some(res) if !r.within(res.width, res.height) => RESP_ERR_INVALID_PARAMETER,
                    Some(res) => {
                        let stride = res.width as usize * 4;
                        let row_bytes = r.width as usize * 4;
                        for row in 0..r.height as usize {
                            // An offset past every backing entry reads nothing.
                            let source = offset.saturating_add(row * stride);
                            let target = (r.y as usize + row) * stride + r.x as usize * 4;
                            read_backing(memory, &res.backing, source, &mut res.host[target..target + row_bytes]);
                        }
                        ok()
                    }
                }
            }
            CMD_SET_SCANOUT => {
                let (r, index, id) = (rect(request, 24), le32(request, 40) as usize, le32(request, 44));
                if index >= MAX_SCANOUTS {
                    RESP_ERR_INVALID_SCANOUT_ID
                } else if id == 0 {
                    self.scanouts[index].resource = 0;
                    self.scanouts[index].rect = None;
                    ok()
                } else {
                    match self.resources.get(&id) {
                        None => RESP_ERR_INVALID_RESOURCE_ID,
                        Some(res) if r.width == 0 || r.height == 0 || !r.within(res.width, res.height) => RESP_ERR_INVALID_PARAMETER,
                        Some(_) => {
                            self.scanouts[index].resource = id;
                            self.scanouts[index].rect = Some(r);
                            ok()
                        }
                    }
                }
            }
            CMD_RESOURCE_FLUSH => {
                let id = le32(request, 40);
                match self.resources.get(&id) {
                    None => RESP_ERR_INVALID_RESOURCE_ID,
                    Some(res) => {
                        let stride = res.width as usize * 4;
                        for (index, s) in self.scanouts.iter().enumerate() {
                            let r = s.rect.unwrap_or(Rect { x: 0, y: 0, width: res.width, height: res.height });
                            // Checked again: a rect set for another resource
                            // of this id would read past this one.
                            if s.enabled && s.resource == id && r.within(res.width, res.height) {
                                let start = r.y as usize * stride + r.x as usize * 4;
                                self.sink.frame(Frame {
                                    scanout: index,
                                    width: r.width,
                                    height: r.height,
                                    stride,
                                    format: res.format,
                                    pixels: &res.host[start..],
                                });
                            }
                        }
                        ok()
                    }
                }
            }
            CMD_UPDATE_CURSOR | CMD_MOVE_CURSOR => ok(),
            _ => RESP_ERR_UNSPEC,
        };
        let mut response = vec![0u8; 24];
        response[0..4].copy_from_slice(&code.to_le_bytes());
        response
    }

    fn process(&mut self, queue: usize) {
        let Some(mut active) = self.active.take() else { return };
        while let Some(chain) = active.queues[queue].pop(&active.memory) {
            let len = self.handle(&active.memory, &chain);
            active.complete(queue, chain.head, len);
        }
        self.active = Some(active);
    }

    fn handle(&mut self, memory: &GuestMemory, chain: &Chain) -> u32 {
        let Some(request) = chain.read_all(memory) else { return 0 };
        if request.len() < 24 {
            return 0;
        }
        let mut response = self.command(memory, &request);
        // Requests run to completion, so fences are already signalled.
        let flags = le32(&request, 4);
        if flags & FLAG_FENCE != 0 {
            response[4..8].copy_from_slice(&FLAG_FENCE.to_le_bytes());
            response[8..24].copy_from_slice(&request[8..24]);
        }
        chain.write_all(memory, &response) as u32
    }
}

impl VirtioDevice for Gpu {
    fn device_type(&self) -> u16 {
        TYPE_GPU
    }

    fn features(&self) -> u64 {
        FEATURE_EDID | if self.renderer.is_some() { render::FEATURES } else { 0 }
    }

    fn queue_sizes(&self) -> Vec<u16> {
        vec![256, 16]
    }

    fn config(&self) -> Vec<u8> {
        let state = self.state.lock().unwrap();
        let mut config = vec![0u8; 16];
        config[0..4].copy_from_slice(&state.events.to_le_bytes());
        config[8..12].copy_from_slice(&(MAX_SCANOUTS as u32).to_le_bytes());
        if self.renderer.is_some() {
            config[12..16].copy_from_slice(&render::CAPSET_COUNT.to_le_bytes());
        }
        config
    }

    fn write_config(&mut self, offset: usize, data: &[u8]) {
        // events_clear
        if offset == 4 && data.len() >= 4 {
            let clear = u32::from_le_bytes(data[..4].try_into().unwrap());
            self.state.lock().unwrap().events &= !clear;
        }
    }

    fn activate(&mut self, memory: Arc<GuestMemory>, queues: Vec<Queue>, interrupt: Interrupt, _features: u64) {
        if let Some((host, events)) = &self.renderer {
            self.state.lock().unwrap().config_interrupt = Some(interrupt.clone());
            let active = Active { memory, queues, interrupt };
            let lease = Lease::new();
            self.lease = Some(lease.clone());
            host.send(Msg::Activate(Box::new(Attach { active, state: self.state.clone(), events: events.clone(), lease })));
            return;
        }
        self.state.lock().unwrap().active = Some(Active { memory, queues, interrupt });
    }

    fn notify(&mut self, queue: usize) {
        // GPU mode: the render thread runs the queue, not this vCPU.
        if let Some((host, _)) = &self.renderer {
            host.send(Msg::Kick(queue));
            return;
        }
        self.state.lock().unwrap().process(queue);
    }

    fn reset(&mut self) {
        // The queues are the transport's again once this returns, whether
        // or not the renderer gets to the reset in time.
        if let Some(lease) = self.lease.take() {
            lease.end();
        }
        if let Some((host, _)) = &self.renderer
            && !host.request(Msg::Reset, Duration::from_secs(5))
        {
            eprintln!("[gpu] the renderer did not finish a reset within 5 s");
        }
        let mut state = self.state.lock().unwrap();
        state.active = None;
        state.config_interrupt = None;
        state.resources.clear();
        for s in &mut state.scanouts {
            s.resource = 0;
        }
    }

    fn pci_class(&self) -> u32 {
        0x03_8000 // display controller, other
    }

    fn shared_memory_size(&self) -> Option<u64> {
        self.renderer.as_ref().map(|_| render::HOST_VISIBLE_SIZE)
    }

    fn set_shared_memory_base(&mut self, base: Option<u64>) {
        if let Some((host, _)) = &self.renderer {
            host.send(Msg::ShmBase(base));
        }
    }
}

impl Drop for Gpu {
    /// The end of a boot: the renderer lets go of this guest before its
    /// memory and VM go away.
    fn drop(&mut self) {
        if let Some(lease) = self.lease.take() {
            lease.end();
        }
        if let Some((host, _)) = &self.renderer
            && !host.request(Msg::Detach, Duration::from_secs(5))
        {
            eprintln!("[gpu] the renderer did not let go of the guest within 5 s");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hvf::GuestRegion;

    const BGRA: u32 = 1;

    /// Reads every row of each frame, as frames.rs does, and keeps its size.
    struct Rows(Arc<Mutex<Vec<(usize, u32, u32)>>>);

    impl FrameSink for Rows {
        fn frame(&mut self, frame: Frame) {
            for y in 0..frame.height as usize {
                let _ = &frame.pixels[y * frame.stride..y * frame.stride + frame.width as usize * 4];
            }
            self.0.lock().unwrap().push((frame.scanout, frame.width, frame.height));
        }
    }

    fn device() -> (Gpu, GuestMemory, Arc<Mutex<Vec<(usize, u32, u32)>>>) {
        let shown = Arc::new(Mutex::new(Vec::new()));
        let gpu = Gpu::new(&[(64, 64)], Box::new(Rows(shown.clone())));
        (gpu, GuestMemory::new(GuestRegion::new(0x8000_0000, 1 << 16).unwrap()), shown)
    }

    /// The response code of a 2D command with `words` after its header.
    fn run(gpu: &Gpu, memory: &GuestMemory, kind: u32, words: &[u32]) -> u32 {
        let mut request = vec![0u8; 24];
        request[0..4].copy_from_slice(&kind.to_le_bytes());
        for word in words {
            request.extend_from_slice(&word.to_le_bytes());
        }
        le32(&gpu.state.lock().unwrap().command(memory, &request), 0)
    }

    #[test]
    fn rects_whose_end_does_not_fit_in_32_bits_are_refused() {
        let (gpu, memory, _) = device();
        assert_eq!(run(&gpu, &memory, CMD_RESOURCE_CREATE_2D, &[1, BGRA, 64, 64]), RESP_OK_NODATA);
        // x + width wraps around to 9.
        let transfer = [u32::MAX - 10, 0, 20, 1, 0, 0, 1, 0];
        assert_eq!(run(&gpu, &memory, CMD_TRANSFER_TO_HOST_2D, &transfer), RESP_ERR_INVALID_PARAMETER);
        assert_eq!(run(&gpu, &memory, CMD_SET_SCANOUT, &[0, u32::MAX, 8, 2, 0, 1]), RESP_ERR_INVALID_PARAMETER);
        assert_eq!(run(&gpu, &memory, CMD_SET_SCANOUT, &[0, 0, 8, 0, 0, 1]), RESP_ERR_INVALID_PARAMETER, "no rows");
        assert_eq!(run(&gpu, &memory, CMD_SET_SCANOUT, &[0, 0, 64, 64, 0, 1]), RESP_OK_NODATA);
        // An offset whose rows lie past the end of memory reads nothing.
        let far = [0, 0, 64, 2, u32::MAX, u32::MAX, 1, 0];
        assert_eq!(run(&gpu, &memory, CMD_TRANSFER_TO_HOST_2D, &far), RESP_OK_NODATA);
    }

    #[test]
    fn a_live_id_is_not_created_again_and_flush_checks_the_rect() {
        let (gpu, memory, shown) = device();
        assert_eq!(run(&gpu, &memory, CMD_RESOURCE_CREATE_2D, &[1, BGRA, 256, 256]), RESP_OK_NODATA);
        assert_eq!(run(&gpu, &memory, CMD_SET_SCANOUT, &[0, 0, 256, 256, 0, 1]), RESP_OK_NODATA);
        assert_eq!(run(&gpu, &memory, CMD_RESOURCE_CREATE_2D, &[1, BGRA, 16, 16]), RESP_ERR_INVALID_RESOURCE_ID);
        assert_eq!(run(&gpu, &memory, CMD_RESOURCE_FLUSH, &[0, 0, 256, 256, 1, 0]), RESP_OK_NODATA);
        assert_eq!(*shown.lock().unwrap(), [(0, 256, 256)]);

        // However a scanout came to keep the old rect, the smaller resource
        // that has the id now is not read past its end.
        assert_eq!(run(&gpu, &memory, CMD_RESOURCE_UNREF, &[1]), RESP_OK_NODATA);
        assert_eq!(run(&gpu, &memory, CMD_RESOURCE_CREATE_2D, &[1, BGRA, 16, 16]), RESP_OK_NODATA);
        gpu.state.lock().unwrap().scanouts[0].resource = 1;
        assert_eq!(run(&gpu, &memory, CMD_RESOURCE_FLUSH, &[0, 0, 16, 16, 1, 0]), RESP_OK_NODATA);
        assert_eq!(shown.lock().unwrap().len(), 1);
    }

    #[test]
    fn attach_backing_takes_only_entries_the_request_holds() {
        let (gpu, memory, _) = device();
        assert_eq!(run(&gpu, &memory, CMD_RESOURCE_CREATE_2D, &[1, BGRA, 64, 64]), RESP_OK_NODATA);
        assert_eq!(run(&gpu, &memory, CMD_RESOURCE_ATTACH_BACKING, &[1, u32::MAX]), RESP_ERR_INVALID_PARAMETER);
        let one_of_two = [1, 2, 0x8000_0000, 0, 4096, 0];
        assert_eq!(run(&gpu, &memory, CMD_RESOURCE_ATTACH_BACKING, &one_of_two), RESP_ERR_INVALID_PARAMETER);
        assert_eq!(run(&gpu, &memory, CMD_RESOURCE_ATTACH_BACKING, &[1, 1, 0x8000_0000, 0, 4096, 0]), RESP_OK_NODATA);
        assert_eq!(gpu.state.lock().unwrap().resources[&1].backing, [(0x8000_0000, 4096)]);
    }

    #[test]
    fn each_scanout_has_an_edid_at_its_rate() {
        let (gpu, memory, _) = device();
        assert_ne!(gpu.features() & FEATURE_EDID, 0);
        let edid_of = |index: u32| {
            let mut request = vec![0u8; 32];
            request[0..4].copy_from_slice(&CMD_GET_EDID.to_le_bytes());
            request[24..28].copy_from_slice(&index.to_le_bytes());
            let response = gpu.state.lock().unwrap().command(&memory, &request);
            assert_eq!(le32(&response, 0), RESP_OK_EDID);
            assert_eq!(response.len(), 32 + 1024, "virtio_gpu_resp_edid");
            response[32..32 + le32(&response, 24) as usize].to_vec()
        };
        assert_eq!(edid_of(0), edid::edid(0, 64, 64, 60), "60 Hz unless plugged with another rate");
        gpu.control().set_display(1, Some((720, 1280, 120)));
        assert_eq!(edid_of(1), edid::edid(1, 720, 1280, 120));
        gpu.control().set_display(1, None);
        assert!(edid_of(1).is_empty(), "unplugged");
        // `--refresh-rate`: display 0 from the start.
        let faster = device().0.at_refresh_rate(90);
        let response = faster.state.lock().unwrap().edid(0);
        assert_eq!(response[32..32 + le32(&response, 24) as usize], edid::edid(0, 64, 64, 90));
        assert!(edid_of(2).is_empty(), "never plugged");
        assert_eq!(run(&gpu, &memory, CMD_GET_EDID, &[MAX_SCANOUTS as u32, 0]), RESP_ERR_INVALID_SCANOUT_ID);
    }

    #[test]
    fn a_backing_entry_at_the_top_of_the_address_space_reads_nothing() {
        let (_, memory, _) = device();
        assert!(!read_backing(&memory, &[(u64::MAX - 4, 64)], 16, &mut [0u8; 8]));
    }
}
