//! The engine control socket: one text command per line, `ok` or
//! `error <message>` per command. A connection that sends `subscribe`
//! becomes an event stream (see frames.rs) and accepts no more commands.
//!
//! ```text
//! display <index> <width> <height> [<hz>]   enable or resize scanout <index>,
//!                                     at <hz> (60 unless given; virtio/gpu/edid.rs)
//! display <index> off                unplug it
//! touch <index> [<id>:<x>:<y> ...]   every pointer currently down on the
//!                                     touchscreen of scanout <index>;
//!                                     x and y run 0..=32767 across the display
//! key <linux keycode> <0|1>          keyboard
//! gamepad <buttons> <lx> <ly> <rx> <ry> <lt> <rt> <hatx> <haty>
//!                                    the gamepad's whole state in evdev
//!                                    units (virtio/input.rs GamepadReport):
//!                                    buttons in GAMEPAD_BUTTONS' bits,
//!                                    sticks -32768..=32767 with y down,
//!                                    triggers 0..=1023, hat -1..=1 (y down)
//! snapshot <index> <path>            next frame of a scanout as a BMP
//! location <lat> <lng> [alt] [accuracy] [speed] [bearing]   GPS fix for Android (gnss.rs)
//! location off                       no fix
//! network <down kbps> <up kbps> <latency ms>   limit Android's network link (0: no limit; link.rs)
//! network off                        no limits
//! cellular <gprs|edge|umts|hspa|lte|nr> <bars 0-4>   a SIM registered on that
//!                                     network with that signal (modem.rs)
//! cellular off                       no SIM
//! microphone on|off                  whether Android may use the Mac's
//!                                     microphone (virtio/sound.rs; off, it
//!                                     records silence)
//! tap <x> <y> / swipe <x1> <y1> <x2> <y2> [ms]   pixels of scanout 0 (debugging)
//! pause                              stop the vCPUs (pause.rs); `ok` once none
//!                                     runs guest code, an error when one does
//!                                     not stop within 5 s (the others go on)
//! resume                             let them run again (both idempotent)
//! subscribe                          turn this connection into an event stream
//! camera feed                        turn this connection into the cameras'
//!                                     frames (camera.rs)
//! ```
//!
//! Besides the frame events (frames.rs), subscribers get `microphone` when
//! Android starts recording (virtio/sound.rs): the daemon asks the user for
//! microphone access in its own name then. `sound playback on|off` and
//! `sound capture on|off` (sticky) follow Android's sound streams, and
//! `paused` / `resumed <ms>` (how long the guest stood still) follow pauses.
//! `audio playback <epoch> <path>` (sticky) names the shared memory with
//! what Android played, for screen recordings (virtio/sound/tap.rs).
//! `bluetooth hci <port>` (sticky) is netsimd's HCI port, with `--bluetooth`
//! (bluetooth.rs). `camera <index> on <width> <height> <fps>` and
//! `camera <index> off` (sticky) say when Android streams a camera of
//! `--cameras` (camera.rs).
//!
//! In GPU mode (virtio/gpu/render.rs) they also get `gpu active <device>`
//! (the renderer runs, on that GPU), `gpu context` (the guest created its
//! first rendering context this boot), `gpu first-frame <index>` (the boot's
//! first frame read back from the GPU) and `gpu stalled <ms>` (a guest
//! fence has waited that long; once per stall). The first three are sticky:
//! a new subscriber hears them again after the layouts.

use crate::gnss::{Fix, Gnss};
use crate::frames::FrameHandle;
use crate::virtio::gpu::{DisplayControl, edid};
use crate::virtio::input::{self, Event, GamepadReport, InputSender};
use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, LazyLock, Mutex};
use std::time::Duration;

pub const TOUCH_RANGE: i32 = 32767;

/// Multi-touch protocol B state of one touchscreen: host pointer ids to slots.
#[derive(Default)]
struct TouchState {
    slots: HashMap<u32, (i32, i32)>,
    next_tracking: i32,
}

impl TouchState {
    /// Events that move the screen from its current pointers to `pointers`.
    fn update(&mut self, pointers: &[(u32, i32, i32)]) -> Vec<Event> {
        let e = |kind, code, value| Event { kind, code, value };
        let mut events = Vec::new();
        let lifted: Vec<u32> = self.slots.keys().filter(|id| !pointers.iter().any(|p| p.0 == **id)).copied().collect();
        for id in lifted {
            let (slot, _) = self.slots.remove(&id).unwrap();
            events.push(e(input::EV_ABS, input::ABS_MT_SLOT, slot));
            events.push(e(input::EV_ABS, input::ABS_MT_TRACKING_ID, -1));
        }
        for &(id, x, y) in pointers {
            let slot = match self.slots.get(&id) {
                Some(&(slot, _)) => slot,
                None => {
                    let Some(free) = (0..input::MAX_TOUCHES).find(|s| !self.slots.values().any(|v| v.0 == *s)) else {
                        continue;
                    };
                    self.next_tracking = (self.next_tracking + 1) & 0xffff;
                    self.slots.insert(id, (free, self.next_tracking));
                    events.push(e(input::EV_ABS, input::ABS_MT_SLOT, free));
                    events.push(e(input::EV_ABS, input::ABS_MT_TRACKING_ID, self.next_tracking));
                    free
                }
            };
            events.push(e(input::EV_ABS, input::ABS_MT_SLOT, slot));
            events.push(e(input::EV_ABS, input::ABS_MT_POSITION_X, x.clamp(0, TOUCH_RANGE)));
            events.push(e(input::EV_ABS, input::ABS_MT_POSITION_Y, y.clamp(0, TOUCH_RANGE)));
        }
        if let Some(&(_, x, y)) = pointers.first() {
            events.push(e(input::EV_ABS, input::ABS_X, x.clamp(0, TOUCH_RANGE)));
            events.push(e(input::EV_ABS, input::ABS_Y, y.clamp(0, TOUCH_RANGE)));
        }
        events.push(e(input::EV_KEY, input::BTN_TOUCH, (!pointers.is_empty()) as i32));
        events.push(e(input::EV_SYN, input::SYN_REPORT, 0));
        events
    }
}

/// What the gamepad last reported, and to which start of the device: the
/// daemon sends whole states (at a controller's report rate), the guest gets
/// only what changed.
#[derive(Default)]
struct PadState {
    starts: u64,
    last: Option<GamepadReport>,
}

impl PadState {
    /// Events for `report` on the device's `starts`-th start; a device
    /// started again (its driver rebound) gets the whole report.
    fn update(&mut self, starts: u64, report: GamepadReport) -> Vec<Event> {
        if starts != self.starts {
            *self = PadState { starts, last: None };
        }
        let events = report.events_since(self.last.as_ref());
        self.last = Some(report);
        events
    }
}

/// `gamepad <buttons> <lx> <ly> <rx> <ry> <lt> <rt> <hatx> <haty>` after the word itself.
fn parse_gamepad(words: &[&str]) -> Result<GamepadReport, String> {
    if words.len() != 9 {
        return Err("gamepad needs a button mask and 8 axes".into());
    }
    let int = |w: &str| w.parse::<i64>().map_err(|_| format!("bad gamepad value {w}"));
    let buttons = int(words[0])?.clamp(0, u32::MAX as i64) as u32;
    let mut axes = [0i32; 8];
    for (axis, word) in axes.iter_mut().zip(&words[1..]) {
        *axis = int(word)?.clamp(i32::MIN as i64, i32::MAX as i64) as i32;
    }
    Ok(GamepadReport::new(buttons, axes))
}

/// Lines a subscriber may leave waiting before it counts as gone (`frame`
/// lines replace each other, so nearly all are other lines): far more than
/// ever go out at once (a new subscriber's layouts and sticky events, a few
/// per display change).
const SUBSCRIBER_BACKLOG: usize = 1024;

/// The scanout of a `frame <index> <sequence>` line.
fn frame_scanout(line: &str) -> Option<&str> {
    line.strip_prefix("frame ")?.split(' ').next()
}

/// The lines waiting for one subscriber.
#[derive(Default)]
struct Outbox {
    lines: VecDeque<String>,
    /// Its connection failed, or it fell hopelessly behind.
    closed: bool,
}

impl Outbox {
    /// Queues `line`; false once the subscriber is gone. Frames are a
    /// mailbox, so a `frame` line takes the place of the one of its scanout
    /// still waiting (at the end: after any layout it belongs to). Every
    /// other line is kept, in order: a subscriber that has
    /// SUBSCRIBER_BACKLOG lines waiting when one comes is closed rather
    /// than let miss it.
    fn push(&mut self, line: String) -> bool {
        if self.closed {
            return false;
        }
        if let Some(scanout) = frame_scanout(&line) {
            if let Some(at) = self.lines.iter().position(|l| frame_scanout(l) == Some(scanout)) {
                self.lines.remove(at);
            }
        } else if self.lines.len() >= SUBSCRIBER_BACKLOG {
            self.closed = true;
            return false;
        }
        self.lines.push_back(line);
        true
    }
}

/// Writes all of `bytes`; false once the connection failed or `closed()`.
/// A failure that passes (macOS gives ENOBUFS when its socket buffers run
/// low) is waited out where it happened: dropping the daemon's only
/// subscription for it would freeze its windows, and starting the line
/// again would send part of it twice.
fn write_line(writer: &mut impl Write, bytes: &[u8], closed: impl Fn() -> bool) -> bool {
    let mut sent = 0;
    while sent < bytes.len() {
        match writer.write(&bytes[sent..]) {
            Ok(0) => return false,
            Ok(n) => sent += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.raw_os_error() == Some(libc::ENOBUFS) => {
                if closed() {
                    return false;
                }
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            Err(_) => return false,
        }
    }
    true
}

/// An event stream. Lines go out on the subscriber's own thread, so one
/// that stops reading holds up only itself.
struct Subscriber {
    outbox: Arc<(Mutex<Outbox>, Condvar)>,
    /// Shut down when the subscriber is dropped, which ends a write that
    /// is stuck.
    stream: UnixStream,
}

impl Subscriber {
    fn start(stream: UnixStream) -> std::io::Result<Subscriber> {
        let outbox: Arc<(Mutex<Outbox>, Condvar)> = Arc::default();
        let (mut writer, waiting) = (stream.try_clone()?, outbox.clone());
        std::thread::Builder::new().name("subscriber".into()).spawn(move || {
            let (lock, ready) = &*waiting;
            loop {
                let line = {
                    let mut outbox = lock.lock().unwrap();
                    while outbox.lines.is_empty() && !outbox.closed {
                        outbox = ready.wait(outbox).unwrap();
                    }
                    if outbox.closed {
                        return;
                    }
                    outbox.lines.pop_front().unwrap()
                };
                if !write_line(&mut writer, format!("{line}\n").as_bytes(), || lock.lock().unwrap().closed) {
                    lock.lock().unwrap().closed = true;
                    return;
                }
            }
        })?;
        Ok(Subscriber { outbox, stream })
    }

    /// Queues `line` without waiting; false once the subscriber is gone.
    fn send(&self, line: String) -> bool {
        let (lock, ready) = &*self.outbox;
        let queued = lock.lock().unwrap().push(line);
        ready.notify_one();
        queued
    }
}

impl Drop for Subscriber {
    fn drop(&mut self) {
        let (lock, ready) = &*self.outbox;
        lock.lock().unwrap().closed = true;
        ready.notify_one();
        let _ = self.stream.shutdown(Shutdown::Both);
    }
}

pub struct Controls {
    pub touchscreens: Vec<InputSender>,
    pub keyboard: InputSender,
    pub gamepad: InputSender,
    pub displays: DisplayControl,
    pub frames: FrameHandle,
    /// Size of scanout 0, for the pixel-based debugging commands.
    pub primary: (u32, u32),
    pub gnss: Arc<Gnss>,
    touch: Mutex<Vec<TouchState>>,
    pad: Mutex<PadState>,
    subscribers: Arc<Mutex<Vec<Subscriber>>>,
}

impl Controls {
    pub fn new(touchscreens: Vec<InputSender>, keyboard: InputSender, gamepad: InputSender, displays: DisplayControl,
               frames: FrameHandle, primary: (u32, u32), gnss: Arc<Gnss>) -> Arc<Controls> {
        let touch = Mutex::new((0..touchscreens.len()).map(|_| TouchState::default()).collect());
        // The process's streams: a subscription goes on across guest reboots.
        let subscribers = SUBSCRIBERS.clone();
        let fanout = subscribers.clone();
        // Only queues: events come from the render thread and vCPUs, often
        // with a device lock held.
        frames.set_events(Arc::new(move |event: String| {
            fanout.lock().unwrap().retain(|s| s.send(event.clone()));
        }));
        let pad = Mutex::new(PadState::default());
        Arc::new(Controls { touchscreens, keyboard, gamepad, displays, frames, primary, gnss, touch, pad, subscribers })
    }

    fn gamepad(&self, report: GamepadReport) {
        // Held while sending: reports from two connections stay in order.
        let mut pad = self.pad.lock().unwrap();
        let events = pad.update(self.gamepad.starts(), report);
        if !events.is_empty() {
            self.gamepad.send(&events);
        }
    }

    fn touch(&self, index: usize, pointers: &[(u32, i32, i32)]) -> Result<(), String> {
        let screen = self.touchscreens.get(index).ok_or("no such touchscreen")?;
        let events = self.touch.lock().unwrap()[index].update(pointers);
        screen.send(&events);
        Ok(())
    }

    /// Pixels of scanout 0 to touchscreen units.
    fn scale(&self, x: i32, y: i32) -> (i32, i32) {
        let (w, h) = (self.primary.0.max(1) as i64, self.primary.1.max(1) as i64);
        ((x as i64 * TOUCH_RANGE as i64 / (w - 1).max(1)) as i32, (y as i64 * TOUCH_RANGE as i64 / (h - 1).max(1)) as i32)
    }

    pub fn run(&self, line: &str) -> Result<(), String> {
        let words: Vec<&str> = line.split_whitespace().collect();
        let int = |i: usize| -> Result<i64, String> {
            words.get(i).and_then(|w| w.parse().ok()).ok_or(format!("bad argument {i}"))
        };
        match words.first().copied() {
            Some("display") => {
                let index = int(1)? as usize;
                if words.get(2) == Some(&"off") {
                    self.displays.set_display(index, None);
                } else {
                    let (w, h) = (int(2)? as u32, int(3)? as u32);
                    if !(64..=8192).contains(&w) || !(64..=8192).contains(&h) {
                        return Err("display size out of range".into());
                    }
                    let hz = if words.len() > 4 { int(4)? as u32 } else { edid::DEFAULT_RATE };
                    if !edid::RATE_RANGE.contains(&hz) {
                        return Err("refresh rate out of range".into());
                    }
                    self.displays.set_display(index, Some((w, h, hz)));
                }
            }
            Some("touch") => {
                let index = int(1)? as usize;
                let mut pointers = Vec::new();
                for word in &words[2..] {
                    let parts: Vec<&str> = word.split(':').collect();
                    let parse = |s: &str| s.parse::<i64>().map_err(|_| format!("bad pointer {word}"));
                    if parts.len() != 3 {
                        return Err(format!("bad pointer {word}"));
                    }
                    pointers.push((parse(parts[0])? as u32, parse(parts[1])? as i32, parse(parts[2])? as i32));
                }
                self.touch(index, &pointers)?;
            }
            Some("key") => {
                let code = int(1)? as u16;
                let down = int(2)? != 0;
                self.keyboard.send(&[
                    Event { kind: input::EV_KEY, code, value: down as i32 },
                    Event { kind: input::EV_SYN, code: input::SYN_REPORT, value: 0 },
                ]);
            }
            Some("gamepad") => self.gamepad(parse_gamepad(&words[1..])?),
            Some("network") => crate::link::LINK.set(crate::link::Conditions::parse(&words[1..])?),
            Some("cellular") => crate::modem::CELLULAR.set(crate::modem::Service::parse(&words[1..])?),
            Some("microphone") => crate::virtio::sound::MICROPHONE.set(match words.get(1).copied() {
                Some("on") => true,
                Some("off") => false,
                _ => return Err("microphone on|off".into()),
            }),
            Some("location") => {
                if words.get(1) == Some(&"off") {
                    self.gnss.set(None);
                } else {
                    self.gnss.set(Some(Fix::parse(&words[1..])?));
                }
            }
            Some("snapshot") => {
                let index = int(1)? as usize;
                let path = words.get(2).ok_or("snapshot needs a path")?;
                self.frames.snapshot(index, PathBuf::from(path));
            }
            Some("tap") => {
                let (x, y) = self.scale(int(1)? as i32, int(2)? as i32);
                self.touch(0, &[(1, x, y)])?;
                std::thread::sleep(Duration::from_millis(60));
                self.touch(0, &[])?;
            }
            Some("pause") => {
                if crate::pause::GATE.pause(Duration::from_secs(5))? {
                    eprintln!("[vmm] paused");
                    self.frames.emit("paused".into());
                }
            }
            Some("resume") => {
                if let Some(stood) = crate::pause::GATE.resume() {
                    eprintln!("[vmm] resumed after {:.1?}", stood);
                    self.frames.emit(format!("resumed {}", stood.as_millis()));
                }
            }
            Some("swipe") => {
                let (x1, y1) = self.scale(int(1)? as i32, int(2)? as i32);
                let (x2, y2) = self.scale(int(3)? as i32, int(4)? as i32);
                let ms = int(5).unwrap_or(300).max(16) as i32;
                let steps = (ms / 16).max(2);
                for step in 0..=steps {
                    self.touch(0, &[(1, x1 + (x2 - x1) * step / steps, y1 + (y2 - y1) * step / steps)])?;
                    std::thread::sleep(Duration::from_millis(16));
                }
                self.touch(0, &[])?;
            }
            _ => return Err(format!("unknown command: {line}")),
        }
        Ok(())
    }
}

/// Every event stream of the process.
static SUBSCRIBERS: LazyLock<Arc<Mutex<Vec<Subscriber>>>> = LazyLock::new(Arc::default);

/// The controls of the machine that runs now. The socket is the process's:
/// a guest reboot hands it the new machine's, and connections already open
/// (the daemon's commands and subscription) go on with those, instead of
/// keeping the old machine's devices and frames alive and reaching only them.
static CURRENT: Mutex<Option<Arc<Controls>>> = Mutex::new(None);

pub fn serve(path: &Path, controls: Arc<Controls>) -> Result<(), String> {
    // The old machine's controls (and with them its frames) go after the
    // lock is released.
    let previous = CURRENT.lock().unwrap().replace(controls);
    if previous.is_some() {
        return Ok(());
    }
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path).map_err(|e| format!("{}: {e}", path.display()))?;
    std::thread::Builder::new()
        .name("control".into())
        .spawn(move || {
            for stream in listener.incoming().flatten() {
                std::thread::spawn(move || {
                    let Ok(mut writer) = stream.try_clone() else { return };
                    let mut reader = BufReader::new(stream);
                    let mut line = String::new();
                    loop {
                        line.clear();
                        match reader.read_line(&mut line) {
                            Ok(0) | Err(_) => return,
                            Ok(_) => {}
                        }
                        let line = line.trim_end_matches(['\n', '\r']);
                        if line.trim() == "camera feed" {
                            if writer.write_all(b"ok\n").is_ok()
                                && let Err(e) = crate::camera::read_feed(&crate::camera::HUB, &mut reader)
                            {
                                eprintln!("[vmm] camera feed: {e}");
                            }
                            return;
                        }
                        let Some(controls) = CURRENT.lock().unwrap().clone() else { return };
                        if line.trim() == "subscribe" {
                            // The layouts that already exist are queued and the subscriber
                            // registered under one lock, so no event falls between the two.
                            if writer.write_all(b"ok\n").is_ok()
                                && let Ok(subscriber) = Subscriber::start(writer)
                            {
                                let mut subscribers = controls.subscribers.lock().unwrap();
                                for layout in controls.frames.current_layouts() {
                                    subscriber.send(layout);
                                }
                                subscribers.push(subscriber);
                            }
                            return;
                        }
                        let reply = match controls.run(line) {
                            Ok(()) => "ok\n".to_string(),
                            Err(e) => format!("error {e}\n"),
                        };
                        if writer.write_all(reply.as_bytes()).is_err() {
                            return;
                        }
                    }
                });
            }
        })
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn summary(events: &[Event]) -> Vec<(u16, i32)> {
        events.iter().map(|e| (e.code, e.value)).collect()
    }

    #[test]
    fn pointers_get_slots_and_are_lifted() {
        let mut touch = TouchState::default();
        let down = touch.update(&[(7, 100, 200)]);
        assert_eq!(&summary(&down)[..2], &[(input::ABS_MT_SLOT, 0), (input::ABS_MT_TRACKING_ID, 1)]);
        assert!(summary(&down).contains(&(input::BTN_TOUCH, 1)));

        let two = touch.update(&[(7, 110, 200), (9, 300, 400)]);
        assert!(summary(&two).contains(&(input::ABS_MT_TRACKING_ID, 2)), "second finger gets a new tracking id");
        assert!(summary(&two).contains(&(input::ABS_MT_SLOT, 1)));

        let up = touch.update(&[(9, 300, 400)]);
        assert_eq!(&summary(&up)[..2], &[(input::ABS_MT_SLOT, 0), (input::ABS_MT_TRACKING_ID, -1)]);
        let none = touch.update(&[]);
        assert!(summary(&none).contains(&(input::BTN_TOUCH, 0)));
        assert!(touch.slots.is_empty());
    }

    #[test]
    fn gamepad_command_parses_and_clamps() {
        let words: Vec<&str> = "16385 32767 -32768 0 99999 1023 0 1 -1".split(' ').collect();
        let report = parse_gamepad(&words).unwrap();
        assert_eq!(report.buttons, 1 << 14 | 1);
        assert_eq!(report.axes, [32767, -32768, 0, 32767, 1023, 0, 1, -1]);
        assert!(parse_gamepad(&words[..8]).is_err(), "every axis is needed");
        assert!(parse_gamepad(&["1", "0", "0", "0", "0", "0", "0", "0", "x"]).is_err());
    }

    #[test]
    fn gamepad_sends_changes_and_everything_after_a_restart() {
        let mut pad = PadState::default();
        let held = GamepadReport::new(1, [0, 0, 0, 0, 0, 0, 0, 0]);
        // First start of the device: the whole report.
        assert_eq!(pad.update(1, held).len(), input::GAMEPAD_BUTTONS.len() + input::GAMEPAD_AXES.len() + 1);
        assert!(pad.update(1, held).is_empty());
        let moved = GamepadReport::new(1, [500, 0, 0, 0, 0, 0, 0, 0]);
        assert_eq!(summary(&pad.update(1, moved)), [(input::ABS_X, 500), (input::SYN_REPORT, 0)]);
        // The guest rebound the driver: its evdev state is gone, A is still held.
        let again = pad.update(2, moved);
        assert!(summary(&again).contains(&(input::BTN_A, 1)));
        assert!(summary(&again).contains(&(input::ABS_X, 500)));
    }

    #[test]
    fn a_slow_subscriber_gets_every_other_line_and_the_newest_frame_of_each_scanout() {
        let mut outbox = Outbox::default();
        for line in ["frame 0 1", "frame 1 1", "frames 0 2 64 64 256 0 /tmp/a b", "frame 0 2", "gpu context", "frame 0 3"] {
            assert!(outbox.push(line.into()));
        }
        // Scanout 0's newest frame stays after the layout it belongs to.
        assert_eq!(outbox.lines, ["frame 1 1", "frames 0 2 64 64 256 0 /tmp/a b", "gpu context", "frame 0 3"]);
    }

    #[test]
    fn a_subscriber_that_leaves_other_lines_unread_is_closed() {
        let mut outbox = Outbox::default();
        for i in 0..SUBSCRIBER_BACKLOG {
            assert!(outbox.push(format!("sound playback {i}")));
        }
        assert!(outbox.push("frame 0 1".into()), "a frame only replaces");
        assert!(!outbox.push("paused".into()));
        assert!(!outbox.push("frame 0 2".into()), "closed for good");
    }

    #[test]
    fn a_subscriber_that_stops_reading_holds_up_no_sender() {
        let (ours, theirs) = UnixStream::pair().unwrap();
        let subscriber = Subscriber::start(ours).unwrap();
        // Far more than the socket buffers hold, while nobody reads.
        let (done, sent) = std::sync::mpsc::channel();
        let sender = std::thread::spawn(move || {
            for sequence in 1..=100_000 {
                assert!(subscriber.send(format!("frame 0 {sequence}")));
            }
            assert!(subscriber.send("gpu context".into()));
            done.send(()).unwrap();
            subscriber
        });
        sent.recv_timeout(Duration::from_secs(10)).expect("a send waited for the reader");
        theirs.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let lines: Vec<String> = BufReader::new(theirs).lines().map_while(Result::ok).take_while(|l| l != "gpu context").collect();
        assert_eq!(lines.last().map(String::as_str), Some("frame 0 100000"));
        assert!(lines.len() < 100_000, "frames the reader was too slow for are left out");
        let sequences: Vec<u32> = lines.iter().map(|l| l["frame 0 ".len()..].parse().unwrap()).collect();
        assert!(sequences.windows(2).all(|w| w[0] < w[1]), "in order");
        drop(sender.join().unwrap());
    }

    /// Takes `chunk` bytes a write, failing with ENOBUFS every other time.
    struct Flaky {
        written: Vec<u8>,
        chunk: usize,
        fail: bool,
    }

    impl Write for Flaky {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.fail = !self.fail;
            if self.fail {
                return Err(std::io::Error::from_raw_os_error(libc::ENOBUFS));
            }
            let n = bytes.len().min(self.chunk);
            self.written.extend_from_slice(&bytes[..n]);
            Ok(n)
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn a_passing_write_failure_resumes_the_line_where_it_stopped() {
        let mut writer = Flaky { written: Vec::new(), chunk: 3, fail: false };
        assert!(write_line(&mut writer, b"frame 0 42\n", || false));
        assert_eq!(writer.written, b"frame 0 42\n");
        // A subscriber dropped meanwhile stops waiting.
        let mut writer = Flaky { written: Vec::new(), chunk: 3, fail: false };
        assert!(!write_line(&mut writer, b"frame 0 42\n", || true));
    }

    #[test]
    fn dropping_a_subscriber_ends_a_write_that_is_stuck() {
        use std::io::Read;
        let (ours, mut theirs) = UnixStream::pair().unwrap();
        let subscriber = Subscriber::start(ours).unwrap();
        // Long lines, so the writer soon waits for a reader that never comes.
        for i in 0..SUBSCRIBER_BACKLOG / 2 {
            assert!(subscriber.send(format!("sound playback {i:0>200}")));
        }
        drop(subscriber);
        theirs.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut rest = Vec::new();
        assert!(theirs.read_to_end(&mut rest).is_ok(), "the reader hears the end instead of waiting");
    }

    /// One machine's controls, as cuttlefish.rs makes them, and its frames folder.
    fn machine(name: &str) -> (Arc<Controls>, PathBuf) {
        let dir = std::env::temp_dir().join(format!("avo-control-{name}-{}", std::process::id()));
        let frames = crate::frames::SharedFrames::new(&dir, false).unwrap();
        let handle = frames.handle();
        let displays = crate::virtio::gpu::Gpu::new(&[(64, 64)], Box::new(frames)).control();
        let sender = || input::Input::new(input::Description::keyboard("Test Keyboard")).sender();
        (Controls::new(vec![sender()], sender(), sender(), displays, handle, (64, 64), Gnss::new()), dir)
    }

    #[test]
    fn connections_go_on_with_the_next_machine_and_let_go_of_the_last() {
        let path = std::env::temp_dir().join(format!("avo-control-{}.sock", std::process::id()));
        let connect = || {
            let stream = UnixStream::connect(&path).unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
            (BufReader::new(stream.try_clone().unwrap()), stream)
        };
        let line = |reader: &mut BufReader<UnixStream>| {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            line
        };
        let (first, first_dir) = machine("first");
        serve(&path, first).unwrap();
        let (mut events, mut subscription) = connect();
        subscription.write_all(b"subscribe\n").unwrap();
        assert_eq!(line(&mut events), "ok\n");
        let (mut answers, mut commands) = connect();
        commands.write_all(b"key 30 1\n").unwrap();
        assert_eq!(line(&mut answers), "ok\n");

        // A guest reboot.
        let gone = Arc::downgrade(&CURRENT.lock().unwrap().clone().unwrap());
        let (second, second_dir) = machine("second");
        serve(&path, second.clone()).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while gone.strong_count() > 0 && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(gone.strong_count(), 0, "nothing keeps the old machine's controls");
        commands.write_all(b"key 30 0\n").unwrap();
        assert_eq!(line(&mut answers), "ok\n", "the open connection is served on");
        second.frames.emit("resumed 5".into());
        assert_eq!(line(&mut events), "resumed 5\n", "the subscription hears the new machine");
        for dir in [first_dir, second_dir] {
            std::fs::remove_dir_all(dir).unwrap();
        }
        let _ = std::fs::remove_file(&path);
    }
}
