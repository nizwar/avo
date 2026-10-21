//! virtio-snd (virtio 1.2 §5.14): one PCM device (hda_fn_nid 0) with a
//! playback and a capture stream, S16 at 8–48 kHz, mono or stereo, which
//! Android's audio HAL opens as ALSA card 0, device 0.
//!
//! Playback goes to the Mac's default output and capture comes from its
//! default input, both through Core Audio's AudioQueue, which converts rates
//! and follows the default devices. Like a sound card's DMA, the device takes
//! the guest's periods in real time, on a clock of its own: one playback
//! period is done per period, whatever Core Audio does. Its audio goes to the
//! Mac's queue, which holds at most MAX_QUEUED; a period that finds the queue
//! that full is dropped there, so a late or bursty Core Audio costs a little
//! sound on the Mac but never holds the guest up. (When the guest's periods
//! were done only once the Mac had played them, every Core Audio hiccup
//! filled the guest's ring, and its audio HAL then dropped whole 85 ms
//! chunks: "incomplete data sent, dropping 4096 frames", heard as robotic,
//! broken sound.) Each start begins with LEAD_IN of silence on the Mac, the
//! slack against the clock and Core Audio drifting apart; capture keeps as
//! much recorded ahead of its clock (`record_period`). A queue that ran dry (a late tick, a slow start) starts
//! its next period LEAD_IN after its playhead (`enqueue`): AudioQueue's
//! timeline goes on while it is empty, and a period enqueued plainly would
//! be due in the past, dropped unheard; with 20 ms periods every period
//! after one hiccup was, and Android played on in silence.
//!
//! The guest never waits for Core Audio: a start is answered at once, the
//! Mac's queue opens on a thread of its own (the first one in a process can
//! take seconds, which held a vCPU and stalled Android's audio for as long)
//! and the stream runs on a clock until it is up.
//! The guest's last period in flight is handed back only once it has sent
//! another (`hand_back`), and a watchdog replaces a queue that stops playing.
//! The microphone is opened only while Android records (macOS asks for
//! permission then), and never while the user keeps it from Android
//! (`MICROPHONE`); without one the guest records silence, and without an
//! output device its audio is consumed in real time and dropped. What was
//! played also goes to screen recordings (`tap`).

pub mod tap;

use super::queue::{Chain, Queue};
use super::{Active, Interrupt, VirtioDevice};
use crate::memory::GuestMemory;
use std::collections::VecDeque;
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

pub const TYPE_SOUND: u16 = 25;

const CONTROL: usize = 0;
const EVENT: usize = 1;
const TX: usize = 2;
const RX: usize = 3;

const R_JACK_INFO: u32 = 0x0001;
const R_PCM_INFO: u32 = 0x0100;
const R_PCM_SET_PARAMS: u32 = 0x0101;
const R_PCM_PREPARE: u32 = 0x0102;
const R_PCM_RELEASE: u32 = 0x0103;
const R_PCM_START: u32 = 0x0104;
const R_PCM_STOP: u32 = 0x0105;
const R_CHMAP_INFO: u32 = 0x0200;

const S_OK: u32 = 0x8000;
const S_BAD_MSG: u32 = 0x8001;
const S_NOT_SUPP: u32 = 0x8002;

const D_OUTPUT: u8 = 0;
const D_INPUT: u8 = 1;
const FORMAT_S16: u8 = 5;
/// VIRTIO_SND_PCM_RATE_* and the rate each stands for.
const RATES: [(u8, u32); 7] = [(1, 8000), (2, 11025), (3, 16000), (4, 22050), (5, 32000), (6, 44100), (7, 48000)];

/// Stream 0 plays, stream 1 records.
const PLAYBACK: usize = 0;
const CAPTURE: usize = 1;
const DIRECTIONS: [u8; 2] = [D_OUTPUT, D_INPUT];

/// AudioQueue buffers for recording, one period each.
const CAPTURE_BUFFERS: usize = 3;
/// At most this many periods are in flight (the driver's PCM_PERIODS_MAX).
const MAX_PERIODS: u32 = 16;
/// Silence at the start of a stream (see the module comment): a period, and
/// at least this.
const LEAD_IN: Duration = Duration::from_millis(30);
/// The most audio the Mac's queue may hold (whole periods, at least one):
/// beyond it a period is dropped on the Mac rather than added as delay.
const MAX_QUEUED: Duration = Duration::from_millis(120);
/// How far playback's clock runs behind the guest's first period.
const OPEN_GRACE: Duration = Duration::from_millis(100);
/// Marks the lead-in's AudioQueue buffers, which stand for no message.
const LEAD_IN_BUFFER: *mut c_void = 1 as *mut c_void;
/// `struct virtio_snd_pcm_status`.
const STATUS_LEN: usize = 8;
/// The longest a held period (`hand_back`) waits for the guest's next one:
/// then the guest may see its ring run dry (as it does at a drain).
const HOLD_LIMIT: Duration = Duration::from_secs(1);
/// How often the watchdog looks at a playing queue, and how long a queue
/// with periods in it may go without playing one before it is replaced.
const WATCH_INTERVAL: Duration = Duration::from_millis(100);
const STALL_LIMIT: Duration = Duration::from_millis(500);
/// A Core Audio start that takes longer than this goes into the log.
const SLOW_START: Duration = Duration::from_millis(250);

#[derive(Clone, Copy)]
struct Params {
    buffer_bytes: u32,
    period_bytes: u32,
    channels: u8,
    rate: u32,
}

impl Params {
    fn frame_bytes(&self) -> u32 {
        self.channels as u32 * 2
    }

    fn period(&self) -> Duration {
        Duration::from_secs_f64(self.period_bytes as f64 / (self.rate as f64 * self.frame_bytes() as f64))
    }

    /// MAX_QUEUED in whole periods.
    fn max_queued_periods(&self) -> usize {
        ((MAX_QUEUED.as_secs_f64() / self.period().as_secs_f64()).ceil() as usize).clamp(2, 8)
    }

    /// The lead-in in whole periods.
    fn lead_in_periods(&self) -> usize {
        ((LEAD_IN.as_secs_f64() / self.period().as_secs_f64()).ceil() as usize).clamp(1, 8)
    }

    /// The recording the capture clock waits for before it hands any over:
    /// the lead-in.
    fn capture_slack_bytes(&self) -> usize {
        self.lead_in_periods() * self.period_bytes as usize
    }

    /// The most recording kept for the guest: MAX_QUEUED, and at least two
    /// periods beyond the slack.
    fn max_captured_bytes(&self) -> usize {
        let periods = (MAX_QUEUED.as_secs_f64() / self.period().as_secs_f64()).ceil() as usize;
        periods.max(self.lead_in_periods() + 2) * self.period_bytes as usize
    }
}

/// A message whose reply is written and whose return to the guest waits
/// (`hand_back`).
struct Held {
    head: u16,
    len: u32,
    since: Instant,
}

/// What `AVO_VMM_SOUND_DEBUG=1` reports.
#[derive(Default)]
struct Stats {
    received: u64,
    played: u64,
    /// Played periods the clock took without a queue (dropped).
    dropped: u64,
    held: u64,
    restarts: u64,
    /// Capture: periods of silence handed over because the microphone fell
    /// behind the clock (not those before it was up).
    underruns: u64,
    /// Capture: times the microphone got so far ahead that its oldest
    /// recording went.
    trimmed: u64,
    /// The longest the queue went without handing a buffer back since the
    /// last report.
    longest: Duration,
    reported: Option<Instant>,
}

#[derive(Default)]
struct Stream {
    params: Option<Params>,
    started: bool,
    /// The guest's I/O messages, oldest first.
    pending: VecDeque<Chain>,
    /// The last message the guest had in flight, done but not handed back.
    held: Option<Held>,
    /// Recorded bytes the guest has not taken yet.
    captured: VecDeque<u8>,
    /// Capture hands over silence until the slack is recorded again.
    priming: bool,
    audio: Option<Audio>,
    stats: Stats,
}

/// A running stream: an AudioQueue (once it is open), or a clock when Core
/// Audio has no device.
struct Audio {
    id: u64,
    queue: Option<QueueRef>,
    idle: Vec<BufferRef>,
    /// Every buffer of the queue; those not idle are queued.
    total: usize,
    /// When the queue last handed a buffer back, started or resumed.
    heard: Instant,
    /// The callbacks' user data; lives as long as the queue.
    _tag: Option<Arc<Tag>>,
}

impl Audio {
    /// Buffers queued on the Mac (lead-in included).
    fn queued(&self) -> usize {
        self.total.saturating_sub(self.idle.len())
    }

    fn new(id: u64, tag: Option<Arc<Tag>>) -> Audio {
        Audio { id, queue: None, idle: Vec::new(), total: 0, heard: Instant::now(), _tag: tag }
    }
}

#[derive(Default)]
struct State {
    active: Option<Active>,
    streams: [Stream; 2],
    /// Event buffers: there are no jacks or events to report, so they wait.
    events: Vec<Chain>,
}

/// Which stream and which run of it a callback is for.
struct Tag {
    state: Weak<Mutex<State>>,
    stream: usize,
    id: u64,
}

static NEXT_RUN: AtomicU64 = AtomicU64::new(1);

/// Whether Android may use the Mac's microphone (Settings › Devices ›
/// Microphone: `microphone on|off` on the control socket, `--no-microphone`
/// from the start). Off, Android records silence and the microphone is never
/// opened, so macOS never asks for it; turning it off closes one that is
/// open. The process's: it lasts through guest reboots.
pub static MICROPHONE: Microphone = Microphone { allowed: AtomicBool::new(true), devices: Mutex::new(Vec::new()) };

pub struct Microphone {
    allowed: AtomicBool,
    /// Every machine's sound device, to close its microphone.
    devices: Mutex<Vec<Weak<Mutex<State>>>>,
}

impl Microphone {
    pub fn allowed(&self) -> bool {
        self.allowed.load(Ordering::Acquire)
    }

    pub fn set(&self, allowed: bool) {
        self.allowed.store(allowed, Ordering::Release);
        if allowed {
            return;
        }
        let queues: Vec<QueueRef> = {
            let mut devices = self.devices.lock().unwrap();
            devices.retain(|device| device.strong_count() > 0);
            devices
                .iter()
                .filter_map(Weak::upgrade)
                .filter_map(|state| state.lock().unwrap().streams[CAPTURE].audio.as_mut().and_then(|audio| audio.queue.take()))
                .collect()
        };
        if !queues.is_empty() {
            eprintln!("[vmm] sound: the Mac's microphone is closed; Android records silence");
        }
        for queue in queues {
            // Never under a lock: callbacks in flight take the device's.
            unsafe {
                AudioQueueStop(queue.0, 1);
                AudioQueueDispose(queue.0, 1);
            }
        }
    }

    fn register(&self, state: &Arc<Mutex<State>>) {
        self.devices.lock().unwrap().push(Arc::downgrade(state));
    }
}

pub struct Sound {
    state: Arc<Mutex<State>>,
    recording: Option<Box<dyn Fn() + Send>>,
    streams: Option<Box<dyn Fn(&'static str, bool) + Send>>,
    /// What `streams` last heard of each stream.
    reported: [bool; 2],
}

impl Sound {
    pub fn new() -> Sound {
        let state = Arc::new(Mutex::new(State::default()));
        // While Android is paused (pause.rs) the Mac's queues pause too.
        let paused = Arc::downgrade(&state);
        crate::pause::GATE.observe(Box::new(move |pause| {
            let Some(state) = paused.upgrade() else { return false };
            let queues: Vec<QueueRef> = {
                let mut state = state.lock().unwrap();
                let audios = state.streams.iter_mut().filter_map(|s| s.audio.as_mut());
                // The watchdog counts from now: a paused queue plays nothing.
                audios.filter_map(|audio| {
                    audio.heard = Instant::now();
                    audio.queue
                })
                .collect()
            };
            // No vCPU runs now (one stopping a stream would dispose its queue).
            for queue in queues {
                unsafe {
                    if pause {
                        AudioQueuePause(queue.0);
                    } else {
                        AudioQueueStart(queue.0, std::ptr::null());
                    }
                }
            }
            true
        }));
        MICROPHONE.register(&state);
        Sound { state, recording: None, streams: None, reported: [false; 2] }
    }

    /// Called whenever Android starts recording.
    pub fn on_recording(&mut self, hook: impl Fn() + Send + 'static) {
        self.recording = Some(Box::new(hook));
    }

    /// Called with `playback` or `capture` when that stream starts or stops.
    pub fn on_stream(&mut self, hook: impl Fn(&'static str, bool) + Send + 'static) {
        self.streams = Some(Box::new(hook));
    }

    fn report(&mut self) {
        let started = {
            let state = self.state.lock().unwrap();
            [state.streams[PLAYBACK].started, state.streams[CAPTURE].started]
        };
        for (stream, kind) in [(PLAYBACK, "playback"), (CAPTURE, "capture")] {
            if started[stream] != self.reported[stream] {
                self.reported[stream] = started[stream];
                if let Some(hook) = &self.streams {
                    hook(kind, started[stream]);
                }
            }
        }
    }

    fn control(&mut self) {
        loop {
            let (chain, request) = {
                let mut state = self.state.lock().unwrap();
                let Some(active) = state.active.as_mut() else { return };
                let Some(chain) = active.queues[CONTROL].pop(&active.memory) else { return };
                let request = chain.read_all(&active.memory).unwrap_or_default();
                (chain, request)
            };
            // Requests run without the lock: stopping waits on Core Audio.
            let began = Instant::now();
            let response = self.request(&request);
            if debug() {
                let word = |at: usize| request.get(at..at + 4).map_or(0, |b| u32::from_le_bytes(b.try_into().unwrap()));
                let status = response.get(..4).map_or(0, |b| u32::from_le_bytes(b.try_into().unwrap()));
                eprintln!(
                    "[vmm] sound: request {:#x} stream {} ({} {}) -> {status:#x} in {:.1} ms",
                    word(0),
                    word(4),
                    word(8),
                    word(12),
                    began.elapsed().as_secs_f64() * 1000.0
                );
            }
            let mut state = self.state.lock().unwrap();
            if let Some(active) = state.active.as_mut() {
                let written = chain.write_all(&active.memory, &response);
                active.complete(CONTROL, chain.head, written as u32);
            }
        }
    }

    fn request(&mut self, request: &[u8]) -> Vec<u8> {
        let word = |at: usize| request.get(at..at + 4).map(|b| u32::from_le_bytes(b.try_into().unwrap()));
        let status = |code: u32| code.to_le_bytes().to_vec();
        let Some(code) = word(0) else { return status(S_BAD_MSG) };
        match code {
            R_PCM_INFO | R_JACK_INFO | R_CHMAP_INFO => {
                let (Some(start), Some(count), Some(size)) = (word(4), word(8), word(12)) else { return status(S_BAD_MSG) };
                if code != R_PCM_INFO || start as usize + count as usize > DIRECTIONS.len() {
                    return status(S_BAD_MSG); // no jacks, no channel maps
                }
                let mut response = status(S_OK);
                for stream in start..start + count {
                    let mut info = pcm_info(stream as usize).to_vec();
                    info.resize(size as usize, 0);
                    response.extend_from_slice(&info);
                }
                response
            }
            R_PCM_SET_PARAMS => {
                let (Some(stream), Some(buffer_bytes), Some(period_bytes)) = (word(4), word(8), word(12)) else {
                    return status(S_BAD_MSG);
                };
                let (Some(&channels), Some(&format), Some(&rate)) = (request.get(20), request.get(21), request.get(22)) else {
                    return status(S_BAD_MSG);
                };
                let stream = stream as usize;
                let rate = RATES.iter().find(|(code, _)| *code == rate).map(|(_, hz)| *hz);
                let (Some(rate), true, true) = (rate, format == FORMAT_S16, (1..=2).contains(&channels)) else {
                    return status(S_NOT_SUPP);
                };
                let params = Params { buffer_bytes, period_bytes, channels, rate };
                if stream >= DIRECTIONS.len() || period_bytes == 0 || buffer_bytes < period_bytes || period_bytes % params.frame_bytes() != 0 {
                    return status(S_BAD_MSG);
                }
                let mut state = self.state.lock().unwrap();
                if state.streams[stream].started {
                    return status(S_BAD_MSG);
                }
                state.streams[stream].params = Some(params);
                status(S_OK)
            }
            R_PCM_PREPARE | R_PCM_RELEASE | R_PCM_START | R_PCM_STOP => {
                let Some(stream) = word(4).map(|s| s as usize).filter(|s| *s < DIRECTIONS.len()) else { return status(S_BAD_MSG) };
                let code = match code {
                    R_PCM_PREPARE => {
                        if self.state.lock().unwrap().streams[stream].params.is_some() { S_OK } else { S_BAD_MSG }
                    }
                    R_PCM_START => self.start(stream),
                    R_PCM_STOP => {
                        self.stop(stream);
                        S_OK
                    }
                    _ => {
                        self.stop(stream);
                        self.release(stream);
                        S_OK
                    }
                };
                self.report();
                status(code)
            }
            _ => status(S_NOT_SUPP),
        }
    }

    /// Starts a run at once; the Mac's side joins in from a thread of its
    /// own (`open_speaker`, `open_microphone`).
    fn start(&mut self, stream: usize) -> u32 {
        let Some(params) = self.state.lock().unwrap().streams[stream].params else { return S_BAD_MSG };
        self.stop(stream);
        let id = NEXT_RUN.fetch_add(1, Ordering::Relaxed);
        let tag = Arc::new(Tag { state: Arc::downgrade(&self.state), stream, id });
        if stream == CAPTURE {
            // Only with the microphone allowed does the daemon ask macOS for it.
            if let Some(hook) = self.recording.as_ref().filter(|_| MICROPHONE.allowed()) {
                hook();
            }
            // Recording runs on a clock from the first moment; the microphone
            // joins in when it is up. Opening it can wait on macOS's permission
            // prompt, which must not hold up this vCPU.
            self.install(stream, Audio::new(id, Some(tag.clone())));
            spawn_clock(&self.state, stream, id, params);
            if !muted() && MICROPHONE.allowed() {
                open_microphone(self.state.clone(), id, params, tag);
            }
        } else {
            self.install(stream, Audio::new(id, Some(tag.clone())));
            start_speaker(&self.state, id, params, tag);
        }
        S_OK
    }

    /// Makes `audio` the stream's running audio.
    fn install(&mut self, stream: usize, audio: Audio) {
        let mut state = self.state.lock().unwrap();
        let entry = &mut state.streams[stream];
        if entry.params.is_none() {
            return;
        }
        entry.started = true;
        entry.audio = Some(audio);
        if stream == CAPTURE {
            entry.captured.clear();
            entry.priming = true;
        }
    }

    /// Stops the stream's audio; its messages stay pending for a restart
    /// (and a held one stays held).
    fn stop(&mut self, stream: usize) {
        let audio = {
            let mut state = self.state.lock().unwrap();
            let entry = &mut state.streams[stream];
            entry.started = false;
            entry.audio.take()
        };
        if let Some(Audio { queue: Some(queue), .. }) = audio {
            // Never under the lock: callbacks in flight take it.
            unsafe {
                AudioQueueStop(queue.0, 1);
                AudioQueueDispose(queue.0, 1);
            }
        }
    }

    /// Hands every pending message back (virtio 1.2 §5.14.6.6.5.2).
    fn release(&mut self, stream: usize) {
        let mut state = self.state.lock().unwrap();
        let State { active, streams, .. } = &mut *state;
        let entry = &mut streams[stream];
        entry.captured.clear();
        let held = entry.held.take();
        let pending: Vec<Chain> = entry.pending.drain(..).collect();
        if let Some(active) = active.as_mut() {
            let queue = if stream == PLAYBACK { TX } else { RX };
            if let Some(held) = held {
                active.complete(queue, held.head, held.len);
            }
            for chain in pending {
                finish(active, queue, chain, &[]);
            }
        }
    }

    /// New I/O messages on the transmit or receive queue.
    fn transfer(&mut self, queue: usize) {
        let mut state = self.state.lock().unwrap();
        let State { active, streams, .. } = &mut *state;
        let Some(active_ref) = active.as_mut() else { return };
        let expected = if queue == TX { PLAYBACK } else { CAPTURE };
        let mut arrived = false;
        while let Some(chain) = active_ref.queues[queue].pop(&active_ref.memory) {
            let mut header = [0u8; 4];
            let readable = chain.readable().next().copied();
            let stream = readable
                .filter(|d| d.len >= 4 && active_ref.memory.read(d.address, &mut header))
                .map(|_| u32::from_le_bytes(header) as usize);
            if stream != Some(expected) {
                respond(active_ref, queue, chain, &[], S_BAD_MSG);
                continue;
            }
            streams[expected].stats.received += 1;
            streams[expected].pending.push_back(chain);
            arrived = true;
        }
        if arrived {
            release_held(active_ref, queue, &mut streams[expected]);
        }
        // Both wait for their clock (`play_period`, `record_period`).
    }
}

fn pcm_info(stream: usize) -> [u8; 32] {
    let mut info = [0u8; 32];
    // hda_fn_nid 0 and features 0; then formats, rates, direction, channels.
    info[8..16].copy_from_slice(&(1u64 << FORMAT_S16).to_le_bytes());
    let rates = RATES.iter().fold(0u64, |bits, (code, _)| bits | 1 << code);
    info[16..24].copy_from_slice(&rates.to_le_bytes());
    info[24] = DIRECTIONS[stream];
    info[25] = 1;
    info[26] = 2;
    info
}

/// Writes `data` and a status into the message; returns the bytes written.
fn reply(active: &Active, chain: &Chain, data: &[u8], status: u32) -> u32 {
    let mut bytes = data.to_vec();
    bytes.extend_from_slice(&status.to_le_bytes());
    bytes.extend_from_slice(&0u32.to_le_bytes()); // latency_bytes
    chain.write_all(&active.memory, &bytes) as u32
}

/// Writes `data` and a status into the message and hands it back.
fn respond(active: &mut Active, queue: usize, chain: Chain, data: &[u8], status: u32) {
    let written = reply(active, &chain, data, status);
    active.complete(queue, chain.head, written);
}

fn finish(active: &mut Active, queue: usize, chain: Chain, data: &[u8]) {
    respond(active, queue, chain, data, S_OK);
}

/// Hands a played (or recorded) period back to the guest, unless it is the
/// last one the guest has in flight: that one waits for the guest's next
/// message (`release_held`), or HOLD_LIMIT.
///
/// The guest's driver (virtio_snd, through ALSA's pcm-indirect helper) follows
/// the device by its position in the ring. When every period in flight comes
/// back before the driver next looks (Core Audio handing several buffers back
/// at once, or Android's worker thread running late under load), the
/// position has gone exactly once round and reads as no progress: the driver
/// then counts its ring as full for good and sends nothing more, the device
/// has nothing left to finish, and Android's writes time out ("Error writing
/// into ALSA: -1") while its mixer runs on in silence until the stream is
/// closed. With one period always out the position cannot go all the way.
fn hand_back(active: &mut Active, queue: usize, stream: &mut Stream, chain: Chain, data: &[u8]) {
    let last = stream.pending.is_empty();
    if hold(active, queue, last, &mut stream.held, chain, data) {
        stream.stats.held += 1;
    }
}

/// `hand_back` for a stream whose audio is borrowed: `last` says whether
/// nothing else is in flight. True when the message is held.
fn hold(active: &mut Active, queue: usize, last: bool, held: &mut Option<Held>, chain: Chain, data: &[u8]) -> bool {
    let len = reply(active, &chain, data, S_OK);
    if !last {
        active.complete(queue, chain.head, len);
        return false;
    }
    // Only the newest is ever held (a new message releases the one before).
    if let Some(older) = held.take() {
        active.complete(queue, older.head, older.len);
    }
    *held = Some(Held { head: chain.head, len, since: Instant::now() });
    true
}

/// The guest sent another message: the held one can go back.
fn release_held(active: &mut Active, queue: usize, stream: &mut Stream) {
    if let Some(held) = stream.held.take() {
        active.complete(queue, held.head, held.len);
    }
}

/// A period held for HOLD_LIMIT goes back: the guest has stopped sending
/// (it underruns, or drains).
fn release_stale(active: &mut Active, queue: usize, stream: &mut Stream) {
    if stream.held.as_ref().is_some_and(|held| held.since.elapsed() >= HOLD_LIMIT) {
        release_held(active, queue, stream);
    }
}

/// One tick of the playback clock: the oldest waiting period is done, and
/// its audio goes to the Mac's queue if that has room (MAX_QUEUED); otherwise,
/// or with no queue yet, it is dropped (and, with no output device at all,
/// still goes to recordings).
fn play_period(active: &mut Active, stream: &mut Stream, id: u64, params: Params) {
    release_stale(active, TX, stream);
    let Some(chain) = stream.pending.pop_front() else { return };
    let data = chain.read_all(&active.memory).unwrap_or_default();
    let pcm = data.get(4..).unwrap_or(&[]);
    let mut queued = false;
    if let Some(audio) = stream.audio.as_mut().filter(|audio| audio.id == id) {
        if let (Some(queue), false) = (audio.queue, pcm.is_empty()) {
            if audio.queued() < params.max_queued_periods() {
                let dry = audio.queued() == 0;
                if let Some(buffer) = audio.idle.pop() {
                    queued = unsafe {
                        let len = pcm.len().min((*buffer.0).capacity as usize);
                        std::ptr::copy_nonoverlapping(pcm.as_ptr(), (*buffer.0).data as *mut u8, len);
                        (*buffer.0).size = len as u32;
                        enqueue(queue, buffer.0, dry, params.rate) == 0
                    };
                    if !queued {
                        audio.idle.push(buffer);
                    }
                }
            }
        } else if audio.queue.is_none() {
            tap::played(id, params.rate, params.channels, pcm);
        }
    }
    if !queued {
        stream.stats.dropped += 1;
    }
    hand_back(active, TX, stream, chain, &[]);
}

/// Hands a period to the Mac's queue. One for a queue that ran dry starts
/// LEAD_IN after the queue's playhead: enqueued plainly it would start where
/// the last one ended, which the queue's timeline has passed, and AudioQueue
/// drops the frames due in the past (all of a short period) yet hands the
/// buffer back as played.
unsafe fn enqueue(queue: QueueRef, buffer: *mut AudioQueueBuffer, dry: bool, rate: u32) -> i32 {
    if dry {
        let mut now = AudioTimeStamp::default();
        if unsafe { AudioQueueGetCurrentTime(queue.0, std::ptr::null_mut(), &mut now, std::ptr::null_mut()) } == 0
            && now.flags & SAMPLE_TIME_VALID != 0
        {
            let start = AudioTimeStamp {
                sample_time: now.sample_time + LEAD_IN.as_secs_f64() * rate as f64,
                flags: SAMPLE_TIME_VALID,
                ..Default::default()
            };
            let null = std::ptr::null();
            return unsafe { AudioQueueEnqueueBufferWithParameters(queue.0, buffer, 0, null, 0, 0, 0, null, &start, std::ptr::null_mut()) };
        }
    }
    unsafe { AudioQueueEnqueueBuffer(queue.0, buffer, 0, std::ptr::null()) }
}

/// One tick of the capture clock: the oldest waiting message gets a whole
/// period of what the microphone recorded, or a whole period of silence,
/// never part of each. Only the clock hands recordings over, so the slack
/// ahead of it lasts. (When the guest was also handed a period whenever it
/// sent a message and one was there, nothing ever stayed ahead of the clock:
/// each time the microphone came in a little late the clock found nothing,
/// and Android heard a period of silence cut into speech.) Silence goes over
/// until the slack is recorded: at the start, before the microphone is up,
/// and again whenever it fell behind.
fn record_period(active: &mut Active, stream: &mut Stream, params: Params) {
    release_stale(active, RX, stream);
    let Some(chain) = stream.pending.pop_front() else { return };
    let room = chain.writable_len().saturating_sub(STATUS_LEN);
    let needed = if stream.priming { room.max(params.capture_slack_bytes()) } else { room };
    let data: Vec<u8> = if stream.captured.len() >= needed {
        stream.priming = false;
        stream.stats.played += 1;
        stream.captured.drain(..room).collect()
    } else {
        if !stream.priming {
            stream.priming = true;
            stream.stats.underruns += 1;
        }
        vec![0; room]
    };
    hand_back(active, RX, stream, chain, &data);
}

/// Keeps what the microphone recorded for the clock. Beyond
/// `max_captured_bytes` (the microphone's clock runs fast against the
/// guest's, or the clock woke late) the oldest goes, down to the slack.
fn keep_recorded(stream: &mut Stream, bytes: &[u8]) {
    stream.captured.extend(bytes);
    let Some(params) = stream.params else { return };
    if stream.captured.len() > params.max_captured_bytes() {
        let excess = stream.captured.len() - params.capture_slack_bytes();
        stream.captured.drain(..excess - excess % params.frame_bytes() as usize);
        stream.stats.trimmed += 1;
    }
}

/// A stream's clock: one period per period. Playback always runs on it
/// (`play_period`); capture hands over what the microphone recorded, or
/// silence without one.
fn spawn_clock(state: &Arc<Mutex<State>>, stream: usize, id: u64, params: Params) {
    let state = Arc::downgrade(state);
    let _ = std::thread::Builder::new().name("avo-sound-clock".into()).spawn(move || {
        unsafe { libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0) };
        // Playback starts OPEN_GRACE late, then keeps that distance: the
        // guest's next period is then always there when the clock wants it
        // (starting at once left the clock waiting on the guest instead).
        let mut tick = std::time::Instant::now() + if stream == PLAYBACK { OPEN_GRACE } else { Duration::ZERO };
        loop {
            tick += params.period();
            std::thread::sleep(tick.saturating_duration_since(std::time::Instant::now()));
            // Android paused (pause.rs): its time stands still, so does this.
            if crate::pause::is_paused() {
                std::thread::sleep(Duration::from_millis(100));
                tick = std::time::Instant::now();
                continue;
            }
            // Woken late: carry on from now rather than hand the guest a burst
            // of periods, which would overrun its ring buffer.
            let now = std::time::Instant::now();
            if now > tick + params.period() * 2 {
                tick = now;
            }
            let Some(state) = state.upgrade() else { return };
            let mut state = state.lock().unwrap();
            let State { active, streams, .. } = &mut *state;
            let entry = &mut streams[stream];
            if entry.audio.as_ref().filter(|audio| audio.id == id).is_none() {
                return;
            }
            let Some(active) = active.as_mut() else { continue };
            if stream == PLAYBACK {
                play_period(active, entry, id, params);
            } else {
                record_period(active, entry, params);
                report_stats(entry, CAPTURE);
            }
        }
    });
}

/// Starts one playback run: its clock, and the Mac's queue, which joins in
/// when it is up (the first queue of a process can take seconds; until then
/// the clock drops the periods' sound, and the guest never backs up).
fn start_speaker(state: &Arc<Mutex<State>>, id: u64, params: Params, tag: Arc<Tag>) {
    spawn_clock(state, PLAYBACK, id, params);
    open_speaker(state.clone(), id, params, tag);
}

/// Opens and starts the Mac's output for one playback run, off the vCPU
/// thread: the lead-in first, then the periods that waited.
fn open_speaker(state: Arc<Mutex<State>>, id: u64, params: Params, tag: Arc<Tag>) {
    let _ = std::thread::Builder::new().name("avo-speaker".into()).spawn(move || {
        let began = Instant::now();
        let opened = open_queue(PLAYBACK, &params, &tag).and_then(|(queue, mut buffers)| {
            if muted() {
                unsafe { AudioQueueSetParameter(queue.0, QUEUE_VOLUME, 0.0) };
            }
            for _ in 0..params.lead_in_periods() {
                let Some(buffer) = buffers.pop() else { break };
                unsafe {
                    std::ptr::write_bytes((*buffer.0).data as *mut u8, 0, params.period_bytes as usize);
                    (*buffer.0).size = params.period_bytes;
                    (*buffer.0).user_data = LEAD_IN_BUFFER;
                    if AudioQueueEnqueueBuffer(queue.0, buffer.0, 0, std::ptr::null()) != 0 {
                        (*buffer.0).user_data = std::ptr::null_mut();
                        buffers.push(buffer);
                    }
                }
            }
            // The lead-in's buffers come back through `played` before the
            // queue is installed; they wait in the run's idle list.
            match unsafe { AudioQueueStart(queue.0, std::ptr::null()) } {
                0 => Ok((queue, buffers)),
                status => {
                    unsafe { AudioQueueDispose(queue.0, 1) };
                    Err(status)
                }
            }
        });
        if began.elapsed() > SLOW_START {
            eprintln!("[vmm] sound: the Mac's audio output took {} ms to start", began.elapsed().as_millis());
        } else if debug() {
            eprintln!("[vmm] sound: output queue up in {:.1} ms", began.elapsed().as_secs_f64() * 1000.0);
        }
        let mut guard = state.lock().unwrap();
        let State { active, streams, .. } = &mut *guard;
        let entry = &mut streams[PLAYBACK];
        let current = entry.started && entry.audio.as_ref().is_some_and(|audio| audio.id == id);
        match opened {
            Ok((queue, buffers)) if current => {
                let audio = entry.audio.as_mut().unwrap();
                audio.queue = Some(queue);
                audio.total = buffers.len() + params.lead_in_periods();
                audio.idle.extend(buffers);
                audio.heard = Instant::now();
                let _ = active;
                drop(guard);
                // Paused while it opened: the gate's resume starts it again
                // (and should the two cross, the watchdog does).
                if crate::pause::is_paused() {
                    unsafe { AudioQueuePause(queue.0) };
                }
                spawn_watchdog(&state, id);
            }
            Ok((queue, _)) => {
                drop(guard);
                unsafe {
                    AudioQueueStop(queue.0, 1);
                    AudioQueueDispose(queue.0, 1);
                }
            }
            Err(status) if current => {
                drop(guard);
                eprintln!("[vmm] sound: no audio output on the Mac (OSStatus {status}); running on a clock");
            }
            Err(_) => {}
        }
        drop(tag);
    });
}

/// Watches one playback run on a queue: a queue that stops handing buffers
/// back while it has some to play (Core Audio lost its device, or its
/// callbacks stalled) is replaced by a new one. The guest never waits for it
/// (the clock runs on); this brings the sound back.
fn spawn_watchdog(state: &Arc<Mutex<State>>, id: u64) {
    let weak = Arc::downgrade(state);
    let _ = std::thread::Builder::new().name("avo-sound-watch".into()).spawn(move || loop {
        std::thread::sleep(WATCH_INTERVAL);
        let Some(state) = weak.upgrade() else { return };
        let mut guard = state.lock().unwrap();
        let State { active, streams, .. } = &mut *guard;
        let entry = &mut streams[PLAYBACK];
        let Some(audio) = entry.audio.as_mut().filter(|audio| audio.id == id) else { return };
        if crate::pause::is_paused() {
            audio.heard = Instant::now();
            continue;
        }
        let silent = audio.heard.elapsed();
        let queued = audio.queued();
        if let Some(active) = active.as_mut() {
            release_stale(active, TX, entry);
        }
        report_stats(entry, PLAYBACK);
        if queued == 0 || silent < STALL_LIMIT {
            continue;
        }
        let Some(params) = entry.params else { return };
        eprintln!("[vmm] sound: the Mac's audio output played nothing for {} ms; opening it again", silent.as_millis());
        let next = NEXT_RUN.fetch_add(1, Ordering::Relaxed);
        let tag = Arc::new(Tag { state: weak.clone(), stream: PLAYBACK, id: next });
        let old = entry.audio.replace(Audio::new(next, Some(tag.clone())));
        entry.stats.restarts += 1;
        drop(guard);
        start_speaker(&state, next, params, tag);
        if let Some(Audio { queue: Some(queue), .. }) = &old {
            unsafe {
                AudioQueueStop(queue.0, 1);
                AudioQueueDispose(queue.0, 1);
            }
        }
        drop(old);
        return;
    });
}

/// `AVO_VMM_SOUND_DEBUG=1`: the control requests and, every 2 s, what
/// each running stream has done.
fn debug() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("AVO_VMM_SOUND_DEBUG").is_some_and(|value| value == "1"))
}

fn report_stats(stream: &mut Stream, kind: usize) {
    if !debug() {
        return;
    }
    let now = Instant::now();
    if stream.stats.reported.is_some_and(|at| now - at < Duration::from_secs(2)) {
        return;
    }
    stream.stats.reported = Some(now);
    if kind == CAPTURE {
        let buffered = stream.params.map_or(0.0, |params| {
            stream.captured.len() as f64 / (params.rate as f64 * params.frame_bytes() as f64) * 1000.0
        });
        let microphone = stream.audio.as_ref().is_some_and(|audio| audio.queue.is_some()) as u8;
        let stats = &stream.stats;
        eprintln!(
            "[vmm] sound: capture received {} recorded {} underruns {} trimmed {}; buffered {buffered:.1} ms priming {} microphone {microphone}",
            stats.received,
            stats.played,
            stats.underruns,
            stats.trimmed,
            stream.priming as u8,
        );
        return;
    }
    let (idle, queued) = stream.audio.as_ref().map_or((0, 0), |audio| (audio.idle.len(), audio.queue.is_some() as u8));
    let stats = &mut stream.stats;
    eprintln!(
        "[vmm] sound: playback received {} played {} dropped {} held {} restarts {} longest-wait {:.1} ms; pending {} queued {} held-now {} idle {idle} queue {queued}",
        stats.received,
        stats.played,
        stats.dropped,
        stats.held,
        stats.restarts,
        stats.longest.as_secs_f64() * 1000.0,
        stream.pending.len(),
        stream.audio.as_ref().map_or(0, |audio| audio.queued()),
        stream.held.is_some() as u8,
    );
    stats.longest = Duration::ZERO;
}

/// Opens the Mac's microphone for one capture run, off the vCPU thread.
fn open_microphone(state: Arc<Mutex<State>>, id: u64, params: Params, tag: Arc<Tag>) {
    let _ = std::thread::Builder::new().name("avo-microphone".into()).spawn(move || {
        let (queue, buffers) = match open_queue(CAPTURE, &params, &tag) {
            Ok(opened) => opened,
            Err(status) => {
                eprintln!("[vmm] sound: no microphone on the Mac (OSStatus {status}); recording silence");
                return;
            }
        };
        for buffer in buffers {
            unsafe { AudioQueueEnqueueBuffer(queue.0, buffer.0, 0, std::ptr::null()) };
        }
        // macOS asks for permission here the first time.
        let status = unsafe { AudioQueueStart(queue.0, std::ptr::null()) };
        // Kept from Android meanwhile: closed again (checked under the lock
        // `MICROPHONE.set` takes too, so one of the two closes it).
        let current = status == 0 && {
            let mut state = state.lock().unwrap();
            let entry = &mut state.streams[CAPTURE];
            match entry.audio.as_mut().filter(|audio| audio.id == id && entry.started && MICROPHONE.allowed()) {
                Some(audio) => {
                    audio.queue = Some(queue);
                    true
                }
                None => false,
            }
        };
        if !current {
            if status != 0 {
                eprintln!("[vmm] sound: cannot record from the Mac's microphone (OSStatus {status}); recording silence");
            }
            unsafe {
                AudioQueueStop(queue.0, 1);
                AudioQueueDispose(queue.0, 1);
            }
        }
    });
}

/// Core Audio's first queue in a process takes seconds to set up (it loads
/// its components and connects to its daemons): do that once in the
/// background, so that Android's first sound does not wait for it. The queue
/// never starts and plays nothing.
fn prewarm() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let _ = std::thread::Builder::new().name("avo-sound-warm".into()).spawn(|| {
            let params = Params { buffer_bytes: 3840, period_bytes: 3840, channels: 2, rate: 48000 };
            let tag = Arc::new(Tag { state: Weak::new(), stream: PLAYBACK, id: 0 });
            if let Ok((queue, _)) = open_queue(PLAYBACK, &params, &tag) {
                unsafe { AudioQueueDispose(queue.0, 1) };
            }
        });
    });
}

impl VirtioDevice for Sound {
    fn device_type(&self) -> u16 {
        TYPE_SOUND
    }

    fn features(&self) -> u64 {
        0
    }

    fn queue_sizes(&self) -> Vec<u16> {
        vec![64, 64, 64, 64]
    }

    fn config(&self) -> Vec<u8> {
        // jacks, streams, chmaps
        [0u32, DIRECTIONS.len() as u32, 0].iter().flat_map(|v| v.to_le_bytes()).collect()
    }

    fn activate(&mut self, memory: Arc<GuestMemory>, queues: Vec<Queue>, interrupt: Interrupt, _features: u64) {
        self.state.lock().unwrap().active = Some(Active { memory, queues, interrupt });
        prewarm();
    }

    fn notify(&mut self, queue: usize) {
        match queue {
            CONTROL => self.control(),
            EVENT => {
                let mut state = self.state.lock().unwrap();
                let State { active, events, .. } = &mut *state;
                if let Some(active) = active.as_mut() {
                    while let Some(chain) = active.queues[EVENT].pop(&active.memory) {
                        events.push(chain);
                    }
                }
            }
            TX | RX => self.transfer(queue),
            _ => {}
        }
    }

    fn reset(&mut self) {
        for stream in [PLAYBACK, CAPTURE] {
            self.stop(stream);
        }
        *self.state.lock().unwrap() = State::default();
        self.report();
    }

    fn pci_class(&self) -> u32 {
        0x04_0100 // multimedia controller, audio
    }
}

// MARK: Core Audio

#[repr(C)]
struct AudioStreamBasicDescription {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32,
}

#[repr(C)]
struct AudioQueueBuffer {
    capacity: u32,
    data: *mut c_void,
    size: u32,
    user_data: *mut c_void,
    packet_description_capacity: u32,
    packet_descriptions: *mut c_void,
    packet_description_count: u32,
}

type AudioQueueRef = *mut c_void;

/// `AudioTimeStamp`; its SMPTE time is not used.
#[repr(C)]
#[derive(Default)]
struct AudioTimeStamp {
    sample_time: f64,
    host_time: u64,
    rate_scalar: f64,
    word_clock_time: u64,
    smpte_time: [u32; 6],
    flags: u32,
    reserved: u32,
}

/// kAudioTimeStampSampleTimeValid.
const SAMPLE_TIME_VALID: u32 = 1;

#[derive(Clone, Copy)]
struct QueueRef(AudioQueueRef);
#[derive(Clone, Copy)]
struct BufferRef(*mut AudioQueueBuffer);
// AudioQueue objects may be used from any thread.
unsafe impl Send for QueueRef {}
unsafe impl Send for BufferRef {}

type OutputCallback = extern "C" fn(*mut c_void, AudioQueueRef, *mut AudioQueueBuffer);
type InputCallback = extern "C" fn(*mut c_void, AudioQueueRef, *mut AudioQueueBuffer, *const c_void, u32, *const c_void);

#[link(name = "AudioToolbox", kind = "framework")]
unsafe extern "C" {
    fn AudioQueueNewOutput(
        format: *const AudioStreamBasicDescription,
        callback: OutputCallback,
        user_data: *mut c_void,
        run_loop: *const c_void,
        run_loop_mode: *const c_void,
        flags: u32,
        queue: *mut AudioQueueRef,
    ) -> i32;
    fn AudioQueueNewInput(
        format: *const AudioStreamBasicDescription,
        callback: InputCallback,
        user_data: *mut c_void,
        run_loop: *const c_void,
        run_loop_mode: *const c_void,
        flags: u32,
        queue: *mut AudioQueueRef,
    ) -> i32;
    fn AudioQueueAllocateBuffer(queue: AudioQueueRef, size: u32, buffer: *mut *mut AudioQueueBuffer) -> i32;
    fn AudioQueueEnqueueBuffer(queue: AudioQueueRef, buffer: *mut AudioQueueBuffer, packets: u32, descriptions: *const c_void) -> i32;
    fn AudioQueueEnqueueBufferWithParameters(
        queue: AudioQueueRef,
        buffer: *mut AudioQueueBuffer,
        packets: u32,
        descriptions: *const c_void,
        trim_start: u32,
        trim_end: u32,
        parameters: u32,
        values: *const c_void,
        start_time: *const AudioTimeStamp,
        actual_start_time: *mut AudioTimeStamp,
    ) -> i32;
    fn AudioQueueGetCurrentTime(queue: AudioQueueRef, timeline: *mut c_void, time: *mut AudioTimeStamp, discontinuity: *mut u8) -> i32;
    fn AudioQueueStart(queue: AudioQueueRef, start_time: *const c_void) -> i32;
    fn AudioQueuePause(queue: AudioQueueRef) -> i32;
    fn AudioQueueStop(queue: AudioQueueRef, immediate: u8) -> i32;
    fn AudioQueueDispose(queue: AudioQueueRef, immediate: u8) -> i32;
    fn AudioQueueSetParameter(queue: AudioQueueRef, id: u32, value: f32) -> i32;
}

/// kAudioQueueParam_Volume.
const QUEUE_VOLUME: u32 = 1;

/// `AVO_VMM_MUTE=1` (tests on a Mac someone uses): the Mac plays nothing
/// (recordings still get the sound) and its microphone stays closed (Android
/// records silence).
fn muted() -> bool {
    std::env::var_os("AVO_VMM_MUTE").is_some_and(|value| value == "1")
}

const LINEAR_PCM: u32 = u32::from_be_bytes(*b"lpcm");
const SIGNED_PACKED: u32 = (1 << 2) | (1 << 3);

fn open_queue(stream: usize, params: &Params, tag: &Arc<Tag>) -> Result<(QueueRef, Vec<BufferRef>), i32> {
    let format = AudioStreamBasicDescription {
        sample_rate: params.rate as f64,
        format_id: LINEAR_PCM,
        format_flags: SIGNED_PACKED,
        bytes_per_packet: params.frame_bytes(),
        frames_per_packet: 1,
        bytes_per_frame: params.frame_bytes(),
        channels_per_frame: params.channels as u32,
        bits_per_channel: 16,
        reserved: 0,
    };
    let user = Arc::as_ptr(tag) as *mut c_void;
    let mut queue: AudioQueueRef = std::ptr::null_mut();
    let status = unsafe {
        if stream == PLAYBACK {
            AudioQueueNewOutput(&format, played, user, std::ptr::null(), std::ptr::null(), 0, &mut queue)
        } else {
            AudioQueueNewInput(&format, recorded, user, std::ptr::null(), std::ptr::null(), 0, &mut queue)
        }
    };
    if status != 0 {
        return Err(status);
    }
    // Enough buffers for every period the guest can have in flight.
    let count = if stream == PLAYBACK {
        (params.buffer_bytes / params.period_bytes).clamp(2, MAX_PERIODS) as usize + params.lead_in_periods()
    } else {
        CAPTURE_BUFFERS
    };
    let mut buffers = Vec::new();
    for _ in 0..count {
        let mut buffer = std::ptr::null_mut();
        let status = unsafe { AudioQueueAllocateBuffer(queue, params.period_bytes, &mut buffer) };
        if status != 0 {
            unsafe { AudioQueueDispose(queue, 1) };
            return Err(status);
        }
        buffers.push(BufferRef(buffer));
    }
    Ok((QueueRef(queue), buffers))
}

/// An AudioQueue played a buffer: refill it with the next period.
extern "C" fn played(user: *mut c_void, _queue: AudioQueueRef, buffer: *mut AudioQueueBuffer) {
    let tag = unsafe { &*(user as *const Tag) };
    let Some(state) = tag.state.upgrade() else { return };
    let mut state = state.lock().unwrap();
    let State { active, streams, .. } = &mut *state;
    let stream = &mut streams[tag.stream];
    let Some(audio) = stream.audio.as_mut().filter(|audio| audio.id == tag.id) else { return };
    audio.idle.push(BufferRef(buffer));
    let now = Instant::now();
    stream.stats.longest = stream.stats.longest.max(now - audio.heard);
    audio.heard = now;
    let lead_in = unsafe { std::mem::replace(&mut (*buffer).user_data, std::ptr::null_mut()) } == LEAD_IN_BUFFER;
    // The clock handed its period back already; this is for recordings.
    if !lead_in {
        if let Some(params) = stream.params {
            let pcm = unsafe { std::slice::from_raw_parts((*buffer).data as *const u8, (*buffer).size as usize) };
            tap::played(tag.id, params.rate, params.channels, pcm);
        }
        stream.stats.played += 1;
    }
    let _ = active;
}

/// An AudioQueue recorded a buffer: pass it to the guest and record on.
extern "C" fn recorded(user: *mut c_void, queue: AudioQueueRef, buffer: *mut AudioQueueBuffer, _: *const c_void, _: u32, _: *const c_void) {
    let tag = unsafe { &*(user as *const Tag) };
    let Some(state) = tag.state.upgrade() else { return };
    let mut state = state.lock().unwrap();
    let stream = &mut state.streams[tag.stream];
    if stream.audio.as_ref().map(|audio| audio.id) != Some(tag.id) || !stream.started {
        return;
    }
    // The clock hands it to the guest.
    let bytes = unsafe { std::slice::from_raw_parts((*buffer).data as *const u8, (*buffer).size as usize) };
    keep_recorded(stream, bytes);
    unsafe { AudioQueueEnqueueBuffer(queue, buffer, 0, std::ptr::null()) };
}

#[cfg(test)]
mod tests {
    use super::*;
    use hvf::GuestRegion;

    #[test]
    fn describes_one_playback_and_one_capture_stream() {
        let mut sound = Sound::new();
        assert_eq!(sound.config(), [0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0]);
        let mut query = R_PCM_INFO.to_le_bytes().to_vec();
        for value in [0u32, 2, 32] {
            query.extend_from_slice(&value.to_le_bytes());
        }
        let response = sound.request(&query);
        assert_eq!(response.len(), 4 + 2 * 32);
        assert_eq!(&response[..4], &S_OK.to_le_bytes());
        let (playback, capture) = (&response[4..36], &response[36..68]);
        assert_eq!(u64::from_le_bytes(playback[8..16].try_into().unwrap()), 1 << FORMAT_S16);
        assert_eq!((playback[24], playback[25], playback[26]), (D_OUTPUT, 1, 2));
        assert_eq!(capture[24], D_INPUT);
        // 48 kHz is rate code 7.
        assert_ne!(u64::from_le_bytes(playback[16..24].try_into().unwrap()) & 1 << 7, 0);
    }

    #[test]
    fn parameters_are_checked() {
        let mut sound = Sound::new();
        let params = |stream: u32, buffer: u32, period: u32, channels: u8, format: u8, rate: u8| {
            let mut request = R_PCM_SET_PARAMS.to_le_bytes().to_vec();
            for value in [stream, buffer, period, 0] {
                request.extend_from_slice(&value.to_le_bytes());
            }
            request.extend_from_slice(&[channels, format, rate, 0]);
            request
        };
        let status = |response: Vec<u8>| u32::from_le_bytes(response[..4].try_into().unwrap());
        assert_eq!(status(sound.request(&params(0, 15360, 3840, 2, FORMAT_S16, 7))), S_OK);
        assert_eq!(status(sound.request(&params(0, 15360, 3840, 2, 17, 7))), S_NOT_SUPP);
        assert_eq!(status(sound.request(&params(0, 15360, 3841, 2, FORMAT_S16, 7))), S_BAD_MSG);
        assert_eq!(status(sound.request(&params(5, 15360, 3840, 2, FORMAT_S16, 7))), S_BAD_MSG);
        let mut prepare = R_PCM_PREPARE.to_le_bytes().to_vec();
        prepare.extend_from_slice(&1u32.to_le_bytes());
        assert_eq!(status(sound.request(&prepare)), S_BAD_MSG); // capture has no parameters yet
    }

    const RAM: u64 = 0x8000_0000;
    const USED: u64 = RAM + 0x1000;

    /// A transmit queue whose used ring the test reads, and its messages:
    /// a header and 16 bytes of PCM to read, a status to write.
    fn transmit() -> (Active, Vec<Chain>) {
        let memory = Arc::new(GuestMemory::new(GuestRegion::new(RAM, 1 << 16).unwrap()));
        let mut queues: Vec<Queue> = (0..4).map(|_| Queue::new(64)).collect();
        queues[TX].ready = true;
        queues[TX].used_ring = USED;
        let chains = (0..8u16)
            .map(|head| {
                let at = RAM + 0x2000 + head as u64 * 0x100;
                let descriptors = vec![
                    super::super::queue::Descriptor { address: at, len: 4 + 16, write: false },
                    super::super::queue::Descriptor { address: at + 0x80, len: STATUS_LEN as u32, write: true },
                ];
                Chain { head, descriptors }
            })
            .collect();
        (Active { memory, queues, interrupt: Interrupt::new(|_| {}) }, chains)
    }

    /// The messages handed back so far, in order.
    fn returned(active: &Active) -> Vec<u16> {
        let count = active.memory.read_u16(USED + 2).unwrap();
        (0..count).map(|i| active.memory.read_u32(USED + 4 + i as u64 * 8).unwrap() as u16).collect()
    }

    #[test]
    fn the_last_period_in_flight_waits_for_the_next_one() {
        let (mut active, chains) = transmit();
        let mut stream = Stream::default();
        let mut chains = chains.into_iter();
        // Four periods waiting, all done at once (a burst).
        stream.pending.extend(chains.by_ref().take(4));
        while let Some(chain) = stream.pending.pop_front() {
            hand_back(&mut active, TX, &mut stream, chain, &[]);
        }
        assert_eq!(returned(&active), [0, 1, 2], "the guest's position must not go all the way round");
        assert!(stream.held.is_some());
        // Its status is written already.
        let status = active.memory.read_u32(RAM + 0x2000 + 3 * 0x100 + 0x80).unwrap();
        assert_eq!(status, S_OK);

        // The guest sends the next period: the held one goes back first.
        stream.pending.push_back(chains.next().unwrap());
        release_held(&mut active, TX, &mut stream);
        assert_eq!(returned(&active), [0, 1, 2, 3]);
        assert!(stream.held.is_none());

        // With more waiting a period goes back at once.
        stream.pending.push_back(chains.next().unwrap());
        let chain = stream.pending.pop_front().unwrap();
        hand_back(&mut active, TX, &mut stream, chain, &[]);
        assert_eq!(returned(&active), [0, 1, 2, 3, 4]);

        // Held too long (the guest stopped sending): it goes back after all.
        let chain = stream.pending.pop_front().unwrap();
        hand_back(&mut active, TX, &mut stream, chain, &[]);
        assert_eq!(returned(&active).len(), 5);
        release_stale(&mut active, TX, &mut stream);
        assert_eq!(returned(&active).len(), 5, "not yet");
        stream.held.as_mut().unwrap().since -= HOLD_LIMIT;
        release_stale(&mut active, TX, &mut stream);
        assert_eq!(returned(&active), [0, 1, 2, 3, 4, 5]);
        assert_eq!(stream.stats.held, 2);
    }

    /// The clock does one period per tick whatever the Mac's queue does:
    /// with no queue the sound is dropped, and the last one waits for the
    /// guest's next.
    #[test]
    fn the_clock_does_one_period_per_tick() {
        let (mut active, chains) = transmit();
        let mut stream = Stream::default();
        let params = Params { buffer_bytes: 64, period_bytes: 16, channels: 2, rate: 48000 };
        stream.audio = Some(Audio::new(7, None));
        stream.pending.extend(chains.into_iter().take(3));
        play_period(&mut active, &mut stream, 7, params);
        assert_eq!(returned(&active), [0]);
        play_period(&mut active, &mut stream, 7, params);
        assert_eq!(returned(&active), [0, 1]);
        // The last one waits for the guest's next period.
        play_period(&mut active, &mut stream, 7, params);
        assert_eq!(returned(&active), [0, 1]);
        assert!(stream.held.is_some());
        // A tick with nothing waiting does nothing.
        play_period(&mut active, &mut stream, 7, params);
        assert_eq!(returned(&active), [0, 1]);
        assert_eq!(stream.stats.dropped, 3);
    }

    #[test]
    fn the_macs_queue_holds_whole_periods_up_to_its_limit() {
        let stock = Params { buffer_bytes: 4 * 16384, period_bytes: 16384, channels: 2, rate: 48000 };
        assert_eq!(stock.max_queued_periods(), 2, "85 ms periods: two");
        assert_eq!(stock.lead_in_periods(), 1);
        let short = Params { buffer_bytes: 4 * 3840, period_bytes: 3840, channels: 2, rate: 48000 };
        assert_eq!(short.max_queued_periods(), 6, "20 ms periods: 120 ms");
        assert_eq!(short.lead_in_periods(), 2);
    }

    #[test]
    fn audio_time_stamps_are_laid_out_as_in_core_audio() {
        assert_eq!(std::mem::size_of::<AudioTimeStamp>(), 64);
        assert_eq!(std::mem::offset_of!(AudioTimeStamp, flags), 56);
    }

    #[link(name = "AudioToolbox", kind = "framework")]
    unsafe extern "C" {
        fn AudioQueueSetProperty(queue: AudioQueueRef, id: u32, data: *const c_void, size: u32) -> i32;
        fn AudioQueueGetProperty(queue: AudioQueueRef, id: u32, data: *mut c_void, size: *mut u32) -> i32;
    }

    /// Core Audio itself, on the Mac's output at volume 0 (its level meter
    /// measures before the volume; `cargo test -- --ignored`): periods that
    /// follow a queue that ran dry are played, not dropped as past due.
    #[test]
    #[ignore = "needs the Mac's audio output"]
    fn periods_after_the_queue_ran_dry_are_played() {
        const ENABLE_METERING: u32 = u32::from_be_bytes(*b"aqme");
        const LEVEL_METER: u32 = u32::from_be_bytes(*b"aqmv");
        let params = Params { buffer_bytes: 4 * 3840, period_bytes: 3840, channels: 2, rate: 48000 };
        let tag = Arc::new(Tag { state: Weak::new(), stream: PLAYBACK, id: 0 });
        let (queue, mut buffers) = open_queue(PLAYBACK, &params, &tag).expect("an output device");
        let level = || {
            let mut meter = [0f32; 4];
            let mut size = std::mem::size_of_val(&meter) as u32;
            unsafe { AudioQueueGetProperty(queue.0, LEVEL_METER, meter.as_mut_ptr().cast(), &mut size) };
            meter[0]
        };
        unsafe {
            AudioQueueSetParameter(queue.0, QUEUE_VOLUME, 0.0);
            let on = 1u32;
            AudioQueueSetProperty(queue.0, ENABLE_METERING, (&on as *const u32).cast(), 4);
            // A lead-in, then nothing for longer than it lasts: the queue runs dry.
            let lead = buffers.pop().unwrap();
            std::ptr::write_bytes((*lead.0).data as *mut u8, 0, params.period_bytes as usize);
            (*lead.0).size = params.period_bytes;
            AudioQueueEnqueueBuffer(queue.0, lead.0, 0, std::ptr::null());
            assert_eq!(AudioQueueStart(queue.0, std::ptr::null()), 0);
        }
        std::thread::sleep(Duration::from_millis(150));
        // A tone, one period per period, as the clock hands it over.
        let mut phase = 0f64;
        let mut heard = 0f32;
        for (index, buffer) in buffers.into_iter().enumerate() {
            unsafe {
                let samples = std::slice::from_raw_parts_mut((*buffer.0).data as *mut i16, params.period_bytes as usize / 2);
                for frame in samples.chunks_mut(2) {
                    let value = (phase.sin() * 12000.0) as i16;
                    frame.fill(value);
                    phase += 2.0 * std::f64::consts::PI * 440.0 / 48000.0;
                }
                (*buffer.0).size = params.period_bytes;
                assert_eq!(enqueue(queue, buffer.0, index == 0, params.rate), 0);
            }
            std::thread::sleep(params.period());
            heard = heard.max(level());
        }
        unsafe {
            AudioQueueStop(queue.0, 1);
            AudioQueueDispose(queue.0, 1);
        }
        assert!(heard > 0.1, "the queue played silence (level {heard})");
    }

    /// A receive queue and its messages: a header to read, 16 bytes of PCM
    /// and a status to write.
    fn receive() -> (Active, Vec<Chain>) {
        let memory = Arc::new(GuestMemory::new(GuestRegion::new(RAM, 1 << 16).unwrap()));
        let mut queues: Vec<Queue> = (0..4).map(|_| Queue::new(64)).collect();
        queues[RX].ready = true;
        queues[RX].used_ring = USED;
        let chains = (0..16u16)
            .map(|head| {
                let at = RAM + 0x2000 + head as u64 * 0x100;
                let descriptors = vec![
                    super::super::queue::Descriptor { address: at, len: 4, write: false },
                    super::super::queue::Descriptor { address: at + 0x80, len: 16 + STATUS_LEN as u32, write: true },
                ];
                Chain { head, descriptors }
            })
            .collect();
        (Active { memory, queues, interrupt: Interrupt::new(|_| {}) }, chains)
    }

    /// The PCM the guest got in message `head`.
    fn received(active: &Active, head: u16) -> Vec<u8> {
        let mut pcm = vec![0u8; 16];
        assert!(active.memory.read(RAM + 0x2000 + head as u64 * 0x100 + 0x80, &mut pcm));
        pcm
    }

    /// 16-byte, 10 ms periods (mono at a made-up 800 Hz): a slack of three.
    const RECORDING: Params = Params { buffer_bytes: 64, period_bytes: 16, channels: 1, rate: 800 };

    #[test]
    fn the_capture_clock_waits_for_its_slack_and_never_splits_a_period() {
        let (mut active, chains) = receive();
        let mut stream = Stream { params: Some(RECORDING), priming: true, ..Default::default() };
        stream.pending.extend(chains);
        assert_eq!(RECORDING.capture_slack_bytes(), 48);

        // Before the microphone is up: silence, and that is no underrun.
        record_period(&mut active, &mut stream, RECORDING);
        assert_eq!(received(&active, 0), [0; 16]);
        // Two periods recorded are less than the slack: still silence.
        keep_recorded(&mut stream, &[1; 32]);
        record_period(&mut active, &mut stream, RECORDING);
        assert_eq!(received(&active, 1), [0; 16]);
        assert_eq!(stream.captured.len(), 32);
        // The third: recording from now on, oldest first, with two to spare.
        keep_recorded(&mut stream, &[2; 16]);
        record_period(&mut active, &mut stream, RECORDING);
        assert_eq!(received(&active, 2), [1; 16]);
        assert!(!stream.priming);
        assert_eq!(stream.captured.len(), 32);
        // The microphone a little late, twice: the slack covers it.
        record_period(&mut active, &mut stream, RECORDING);
        record_period(&mut active, &mut stream, RECORDING);
        assert_eq!((received(&active, 3), received(&active, 4)), ([1; 16].to_vec(), [2; 16].to_vec()));
        assert_eq!(stream.stats.underruns, 0);

        // Half a period recorded when the clock wants a whole one: silence,
        // not half of each, and the clock waits for the slack again.
        keep_recorded(&mut stream, &[3; 8]);
        record_period(&mut active, &mut stream, RECORDING);
        assert_eq!(received(&active, 5), [0; 16]);
        assert_eq!(stream.stats.underruns, 1);
        assert!(stream.priming);
        keep_recorded(&mut stream, &[4; 40]);
        record_period(&mut active, &mut stream, RECORDING);
        let pcm = received(&active, 6);
        assert_eq!((&pcm[..8], &pcm[8..]), (&[3; 8][..], &[4; 8][..]), "nothing recorded is lost");
        assert_eq!(stream.stats.played, 4);
        assert_eq!(stream.stats.underruns, 1);
    }

    #[test]
    fn a_microphone_far_ahead_loses_its_oldest_recording_down_to_the_slack() {
        let mut stream = Stream { params: Some(RECORDING), ..Default::default() };
        assert_eq!(RECORDING.max_captured_bytes(), 12 * 16, "120 ms of 10 ms periods");
        keep_recorded(&mut stream, &[1; 12 * 16]);
        assert_eq!((stream.captured.len(), stream.stats.trimmed), (12 * 16, 0));
        keep_recorded(&mut stream, &[2; 16]);
        assert_eq!(stream.stats.trimmed, 1);
        assert_eq!(stream.captured.len(), 48);
        assert_eq!(stream.captured.iter().filter(|&&byte| byte == 2).count(), 16, "the newest stays");
        // Long periods: the cap still leaves two beyond the slack.
        let long = Params { buffer_bytes: 4 * 16384, period_bytes: 16384, channels: 2, rate: 48000 };
        assert_eq!(long.max_captured_bytes(), 3 * 16384);
    }

    #[test]
    fn a_release_hands_back_the_held_period_first() {
        let (active, chains) = transmit();
        let mut sound = Sound::new();
        {
            let mut state = sound.state.lock().unwrap();
            state.active = Some(active);
            let State { active, streams, .. } = &mut *state;
            let (active, stream) = (active.as_mut().unwrap(), &mut streams[PLAYBACK]);
            let mut chains = chains.into_iter();
            hand_back(active, TX, stream, chains.next().unwrap(), &[]);
            stream.pending.extend(chains.take(2));
        }
        sound.release(PLAYBACK);
        let state = sound.state.lock().unwrap();
        assert_eq!(returned(state.active.as_ref().unwrap()), [0, 1, 2]);
        assert!(state.streams[PLAYBACK].held.is_none() && state.streams[PLAYBACK].pending.is_empty());
    }
}
