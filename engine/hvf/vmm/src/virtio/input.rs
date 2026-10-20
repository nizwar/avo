//! virtio-input (virtio 1.2 §5.8): evdev devices the guest kernel exposes
//! as /dev/input/eventN — a multi-touch screen per display, a keyboard and
//! a gamepad.

use super::queue::Queue;
use super::{Active, Interrupt, VirtioDevice};
use crate::memory::GuestMemory;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

pub const TYPE_INPUT: u16 = 18;

const CFG_ID_NAME: u8 = 0x01;
const CFG_ID_SERIAL: u8 = 0x02;
const CFG_ID_DEVIDS: u8 = 0x03;
const CFG_PROP_BITS: u8 = 0x10;
const CFG_EV_BITS: u8 = 0x11;
const CFG_ABS_INFO: u8 = 0x12;

pub const EV_SYN: u16 = 0x00;
pub const EV_KEY: u16 = 0x01;
pub const EV_ABS: u16 = 0x03;
pub const SYN_REPORT: u16 = 0;
pub const BTN_TOUCH: u16 = 0x14a;
pub const ABS_X: u16 = 0x00;
pub const ABS_Y: u16 = 0x01;
pub const ABS_MT_SLOT: u16 = 0x2f;
pub const ABS_MT_POSITION_X: u16 = 0x35;
pub const ABS_MT_POSITION_Y: u16 = 0x36;
pub const ABS_MT_TRACKING_ID: u16 = 0x39;
const INPUT_PROP_DIRECT: u16 = 0x01;
pub const MAX_TOUCHES: i32 = 10;
const BUS_USB: u16 = 0x03;
const BUS_VIRTUAL: u16 = 0x06;
const VENDOR_VIRTIO: u16 = 0x1af4;

// Gamepad buttons and axes (linux/input-event-codes.h). Linux also names
// the face buttons BTN_SOUTH/EAST/NORTH/WEST, but xpad, and with it
// Android's Xbox key layout, puts the Xbox X (the west button) on BTN_X =
// BTN_NORTH and Y (the north one) on BTN_Y = BTN_WEST.
pub const BTN_A: u16 = 0x130;
pub const BTN_B: u16 = 0x131;
pub const BTN_X: u16 = 0x133;
pub const BTN_Y: u16 = 0x134;
pub const BTN_TL: u16 = 0x136;
pub const BTN_TR: u16 = 0x137;
pub const BTN_SELECT: u16 = 0x13a;
pub const BTN_START: u16 = 0x13b;
pub const BTN_MODE: u16 = 0x13c;
pub const BTN_THUMBL: u16 = 0x13d;
pub const BTN_THUMBR: u16 = 0x13e;
pub const ABS_Z: u16 = 0x02;
pub const ABS_RX: u16 = 0x03;
pub const ABS_RY: u16 = 0x04;
pub const ABS_RZ: u16 = 0x05;
pub const ABS_HAT0X: u16 = 0x10;
pub const ABS_HAT0Y: u16 = 0x11;

#[derive(Clone, Copy, Debug)]
pub struct Event {
    pub kind: u16,
    pub code: u16,
    pub value: i32,
}

/// One absolute axis as the guest sees it (`struct virtio_input_absinfo`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AbsInfo {
    pub code: u16,
    pub min: i32,
    pub max: i32,
    /// Changes smaller than this are noise (the kernel filters them).
    pub fuzz: i32,
    /// Values this close to the center count as at rest.
    pub flat: i32,
}

impl AbsInfo {
    pub const fn new(code: u16, min: i32, max: i32) -> AbsInfo {
        AbsInfo { code, min, max, fuzz: 0, flat: 0 }
    }
}

/// What the device advertises to the guest's evdev layer.
pub struct Description {
    pub name: String,
    pub serial: String,
    /// Bus type and USB-style ids; Android looks up its configuration files
    /// by them (`Vendor_<vendor>_Product_<product>.idc` / `.kl`).
    pub bus: u16,
    pub vendor: u16,
    pub product: u16,
    pub properties: Vec<u16>,
    /// (event type, codes)
    pub events: Vec<(u16, Vec<u16>)>,
    pub axes: Vec<AbsInfo>,
}

impl Description {
    /// A multi-touch screen whose axes run 0..=`range` across whatever
    /// display Android associates it with.
    pub fn touchscreen(name: &str, product: u16, range: i32) -> Description {
        let (w, h) = (range, range);
        Description {
            name: name.into(),
            serial: name.replace(' ', "_").to_lowercase(),
            bus: BUS_VIRTUAL,
            vendor: VENDOR_VIRTIO,
            product,
            properties: vec![INPUT_PROP_DIRECT],
            events: vec![
                (EV_KEY, vec![BTN_TOUCH]),
                (EV_ABS, vec![ABS_X, ABS_Y, ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID]),
            ],
            axes: vec![
                AbsInfo::new(ABS_X, 0, w),
                AbsInfo::new(ABS_Y, 0, h),
                AbsInfo::new(ABS_MT_SLOT, 0, MAX_TOUCHES - 1),
                AbsInfo::new(ABS_MT_POSITION_X, 0, w),
                AbsInfo::new(ABS_MT_POSITION_Y, 0, h),
                AbsInfo::new(ABS_MT_TRACKING_ID, 0, 65535),
            ],
        }
    }

    pub fn keyboard(name: &str) -> Description {
        Description {
            name: name.into(),
            serial: name.replace(' ', "_").to_lowercase(),
            bus: BUS_VIRTUAL,
            vendor: VENDOR_VIRTIO,
            product: 0x0001,
            properties: vec![],
            events: vec![(EV_KEY, (1..=248).collect())],
            axes: vec![],
        }
    }

    /// An Xbox One S controller on USB as Linux's xpad driver presents it:
    /// Android maps it with its stock Vendor_045e_Product_02ea.kl (sticks to
    /// AXIS_X/Y and AXIS_Z/RZ, triggers to AXIS_LTRIGGER/RTRIGGER, the hat
    /// to AXIS_HAT_X/Y), and games that know controllers by their ids show
    /// Xbox buttons. On USB it counts as an external device, like a plugged
    /// in controller.
    pub fn gamepad(name: &str) -> Description {
        Description {
            name: name.into(),
            serial: name.replace(' ', "_").to_lowercase(),
            bus: BUS_USB,
            vendor: 0x045e,
            product: 0x02ea,
            properties: vec![],
            events: vec![
                (EV_KEY, GAMEPAD_BUTTONS.iter().map(|&(_, code)| code).collect()),
                (EV_ABS, GAMEPAD_AXES.iter().map(|axis| axis.code).collect()),
            ],
            axes: GAMEPAD_AXES.to_vec(),
        }
    }
}

/// Bits of a gamepad report's button mask (the order of AvoKit's
/// `GamepadButton`, which the Input channel's GAMEPAD record carries) and
/// the keys they press. Bits 6 to 11, the triggers and the d-pad, travel as
/// axes: an Xbox pad has no trigger or d-pad keys, and its key layout maps
/// none.
pub const GAMEPAD_BUTTONS: [(u32, u16); 11] = [
    (0, BTN_A),
    (1, BTN_B),
    (2, BTN_X),
    (3, BTN_Y),
    (4, BTN_TL),
    (5, BTN_TR),
    (12, BTN_THUMBL),
    (13, BTN_THUMBR),
    (14, BTN_START),
    (15, BTN_SELECT),
    (16, BTN_MODE),
];

pub const STICK_MIN: i32 = -32768;
pub const STICK_MAX: i32 = 32767;
pub const TRIGGER_MAX: i32 = 1023;

/// A gamepad report's axes in order, with xpad's ranges for an Xbox One
/// pad: left stick, right stick (ABS_RX/RY), triggers (ABS_Z/RZ), hat.
pub const GAMEPAD_AXES: [AbsInfo; 8] = [
    AbsInfo { code: ABS_X, min: STICK_MIN, max: STICK_MAX, fuzz: 16, flat: 128 },
    AbsInfo { code: ABS_Y, min: STICK_MIN, max: STICK_MAX, fuzz: 16, flat: 128 },
    AbsInfo { code: ABS_RX, min: STICK_MIN, max: STICK_MAX, fuzz: 16, flat: 128 },
    AbsInfo { code: ABS_RY, min: STICK_MIN, max: STICK_MAX, fuzz: 16, flat: 128 },
    AbsInfo::new(ABS_Z, 0, TRIGGER_MAX),
    AbsInfo::new(ABS_RZ, 0, TRIGGER_MAX),
    AbsInfo::new(ABS_HAT0X, -1, 1),
    AbsInfo::new(ABS_HAT0Y, -1, 1),
];

/// One state of the gamepad in evdev units: a button mask (GAMEPAD_BUTTONS)
/// and the GAMEPAD_AXES in order. Stick y and hat y point down.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct GamepadReport {
    pub buttons: u32,
    pub axes: [i32; 8],
}

impl GamepadReport {
    /// A report with every axis held to its range.
    pub fn new(buttons: u32, axes: [i32; 8]) -> GamepadReport {
        let mut clamped = axes;
        for (value, info) in clamped.iter_mut().zip(GAMEPAD_AXES.iter()) {
            *value = (*value).clamp(info.min, info.max);
        }
        GamepadReport { buttons, axes: clamped }
    }

    /// Events that take the device from `previous` to this report, ending in
    /// SYN_REPORT, or none when nothing changed. Without a previous report
    /// (a device the guest just started) every key and axis is sent.
    pub fn events_since(&self, previous: Option<&GamepadReport>) -> Vec<Event> {
        let mut events = Vec::new();
        for &(bit, code) in &GAMEPAD_BUTTONS {
            let down = self.buttons >> bit & 1;
            if previous.is_none_or(|p| p.buttons >> bit & 1 != down) {
                events.push(Event { kind: EV_KEY, code, value: down as i32 });
            }
        }
        for (i, info) in GAMEPAD_AXES.iter().enumerate() {
            if previous.is_none_or(|p| p.axes[i] != self.axes[i]) {
                events.push(Event { kind: EV_ABS, code: info.code, value: self.axes[i] });
            }
        }
        if !events.is_empty() {
            events.push(Event { kind: EV_SYN, code: SYN_REPORT, value: 0 });
        }
        events
    }
}

struct State {
    active: Option<Active>,
    pending: VecDeque<Event>,
    /// How many times the guest has started the device (a driver rebind
    /// starts it again, with every key up and every axis at zero).
    starts: u64,
}

/// Cloneable handle to send events to the guest.
#[derive(Clone)]
pub struct InputSender(Arc<Mutex<State>>);

impl InputSender {
    /// Changes whenever the guest starts the device again: the evdev state
    /// a sender assumed is gone then.
    pub fn starts(&self) -> u64 {
        self.0.lock().unwrap().starts
    }

    /// Queues events; the caller ends each report with SYN_REPORT.
    pub fn send(&self, events: &[Event]) {
        let mut state = self.0.lock().unwrap();
        state.pending.extend(events.iter().copied());
        // Bound the backlog if the guest stopped reading.
        while state.pending.len() > 4096 {
            state.pending.pop_front();
        }
        deliver(&mut state);
    }
}

fn deliver(state: &mut State) {
    let State { active, pending, .. } = state;
    let Some(active) = active.as_mut() else { return };
    let mut delivered = false;
    while let Some(event) = pending.front().copied() {
        let Some(chain) = active.queues[0].pop(&active.memory) else { break };
        let mut bytes = [0u8; 8];
        bytes[0..2].copy_from_slice(&event.kind.to_le_bytes());
        bytes[2..4].copy_from_slice(&event.code.to_le_bytes());
        bytes[4..8].copy_from_slice(&event.value.to_le_bytes());
        let written = chain.write_all(&active.memory, &bytes);
        active.queues[0].add_used(&active.memory, chain.head, written as u32);
        pending.pop_front();
        delivered = true;
    }
    if delivered {
        active.interrupt.signal_queue();
    }
}

pub struct Input {
    description: Description,
    select: u8,
    subsel: u8,
    state: Arc<Mutex<State>>,
}

impl Input {
    pub fn new(description: Description) -> Input {
        let state = State { active: None, pending: VecDeque::new(), starts: 0 };
        Input { description, select: 0, subsel: 0, state: Arc::new(Mutex::new(state)) }
    }

    pub fn sender(&self) -> InputSender {
        InputSender(self.state.clone())
    }

    fn bitmap(codes: &[u16]) -> Vec<u8> {
        let mut bits = vec![0u8; 128];
        for &code in codes {
            if (code as usize) < 1024 {
                bits[code as usize / 8] |= 1 << (code % 8);
            }
        }
        while bits.last() == Some(&0) {
            bits.pop();
        }
        bits
    }

    /// The payload for the current (select, subsel).
    fn payload(&self) -> Vec<u8> {
        let d = &self.description;
        match self.select {
            CFG_ID_NAME => d.name.as_bytes().iter().copied().take(128).collect(),
            CFG_ID_SERIAL => d.serial.as_bytes().iter().copied().take(128).collect(),
            CFG_ID_DEVIDS => {
                let mut ids = Vec::new();
                for v in [d.bus, d.vendor, d.product, 0x0001] {
                    ids.extend_from_slice(&v.to_le_bytes()); // bustype, vendor, product, version
                }
                ids
            }
            CFG_PROP_BITS => Input::bitmap(&d.properties),
            CFG_EV_BITS => match d.events.iter().find(|(kind, _)| *kind == self.subsel as u16) {
                Some((_, codes)) => Input::bitmap(codes),
                None => Vec::new(),
            },
            CFG_ABS_INFO => match d.axes.iter().find(|axis| axis.code == self.subsel as u16) {
                Some(axis) => {
                    let mut info = Vec::new();
                    for v in [axis.min, axis.max, axis.fuzz, axis.flat, 0] {
                        info.extend_from_slice(&v.to_le_bytes()); // min, max, fuzz, flat, res
                    }
                    info
                }
                None => Vec::new(),
            },
            _ => Vec::new(),
        }
    }
}

impl VirtioDevice for Input {
    fn device_type(&self) -> u16 {
        TYPE_INPUT
    }

    fn features(&self) -> u64 {
        0
    }

    fn queue_sizes(&self) -> Vec<u16> {
        vec![64, 64]
    }

    fn config(&self) -> Vec<u8> {
        let payload = self.payload();
        let mut config = vec![0u8; 136];
        config[0] = self.select;
        config[1] = self.subsel;
        config[2] = payload.len() as u8;
        config[8..8 + payload.len()].copy_from_slice(&payload);
        config
    }

    fn write_config(&mut self, offset: usize, data: &[u8]) {
        for (i, &byte) in data.iter().enumerate() {
            match offset + i {
                0 => self.select = byte,
                1 => self.subsel = byte,
                _ => {}
            }
        }
    }

    fn activate(&mut self, memory: Arc<GuestMemory>, queues: Vec<Queue>, interrupt: Interrupt, _features: u64) {
        let mut state = self.state.lock().unwrap();
        state.active = Some(Active { memory, queues, interrupt });
        state.starts += 1;
        deliver(&mut state);
    }

    fn notify(&mut self, queue: usize) {
        let mut state = self.state.lock().unwrap();
        match queue {
            0 => deliver(&mut state),
            _ => {
                // Status queue (LEDs): consume and ignore.
                if let Some(active) = state.active.as_mut() {
                    while let Some(chain) = active.queues[1].pop(&active.memory) {
                        active.complete(1, chain.head, 0);
                    }
                }
            }
        }
    }

    fn reset(&mut self) {
        let mut state = self.state.lock().unwrap();
        state.active = None;
        // Events the old driver never read describe a state its evdev device
        // took with it: a rebound gamepad would get a stale press first.
        state.pending.clear();
    }

    fn pci_class(&self) -> u32 {
        0x09_8000 // input device, other
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn summary(events: &[Event]) -> Vec<(u16, u16, i32)> {
        events.iter().map(|e| (e.kind, e.code, e.value)).collect()
    }

    /// The config payload for (select, subsel), as the guest driver reads it.
    fn read(input: &mut Input, select: u8, subsel: u8) -> Vec<u8> {
        input.write_config(0, &[select, subsel]);
        let config = input.config();
        config[8..8 + config[2] as usize].to_vec()
    }

    #[test]
    fn gamepad_is_an_xbox_pad_on_usb() {
        let mut pad = Input::new(Description::gamepad("Xbox Wireless Controller"));
        let ids: Vec<u16> = read(&mut pad, CFG_ID_DEVIDS, 0).chunks(2).map(|b| u16::from_le_bytes([b[0], b[1]])).collect();
        assert_eq!(ids, [BUS_USB, 0x045e, 0x02ea, 0x0001]);
        assert_eq!(read(&mut pad, CFG_ID_NAME, 0), b"Xbox Wireless Controller");

        let keys = read(&mut pad, CFG_EV_BITS, EV_KEY as u8);
        let has = |bits: &[u8], code: u16| bits.get(code as usize / 8).is_some_and(|b| b >> (code % 8) & 1 == 1);
        for code in [BTN_A, BTN_B, BTN_X, BTN_Y, BTN_TL, BTN_TR, BTN_SELECT, BTN_START, BTN_MODE, BTN_THUMBL, BTN_THUMBR] {
            assert!(has(&keys, code), "key {code:#x}");
        }
        assert!(!has(&keys, 0x138) && !has(&keys, 0x139), "no trigger keys: the Xbox layout maps none");
        let axes = read(&mut pad, CFG_EV_BITS, EV_ABS as u8);
        for code in [ABS_X, ABS_Y, ABS_Z, ABS_RX, ABS_RY, ABS_RZ, ABS_HAT0X, ABS_HAT0Y] {
            assert!(has(&axes, code), "axis {code:#x}");
        }

        let info: Vec<i32> = read(&mut pad, CFG_ABS_INFO, ABS_X as u8).chunks(4).map(|b| i32::from_le_bytes(b.try_into().unwrap())).collect();
        assert_eq!(info, [STICK_MIN, STICK_MAX, 16, 128, 0], "min, max, fuzz, flat, res");
        let trigger: Vec<i32> = read(&mut pad, CFG_ABS_INFO, ABS_RZ as u8).chunks(4).map(|b| i32::from_le_bytes(b.try_into().unwrap())).collect();
        assert_eq!(trigger, [0, TRIGGER_MAX, 0, 0, 0]);
    }

    #[test]
    fn touchscreens_and_keyboard_keep_their_virtio_ids() {
        let mut screen = Input::new(Description::touchscreen("Avo Touch Screen 1", 0x0101, 32767));
        assert_eq!(read(&mut screen, CFG_ID_DEVIDS, 0), [0x06, 0, 0xf4, 0x1a, 0x01, 0x01, 0x01, 0x00]);
        let info = read(&mut screen, CFG_ABS_INFO, ABS_MT_POSITION_X as u8);
        assert_eq!(&info[4..8], &32767i32.to_le_bytes());
    }

    #[test]
    fn a_fresh_device_gets_the_whole_report() {
        let report = GamepadReport::new(1 << 0 | 1 << 14, [100, -200, 0, 0, 1023, 0, -1, 0]);
        let events = report.events_since(None);
        assert_eq!(events.len(), GAMEPAD_BUTTONS.len() + GAMEPAD_AXES.len() + 1);
        let s = summary(&events);
        assert!(s.contains(&(EV_KEY, BTN_A, 1)));
        assert!(s.contains(&(EV_KEY, BTN_START, 1)));
        assert!(s.contains(&(EV_KEY, BTN_B, 0)));
        assert!(s.contains(&(EV_ABS, ABS_Y, -200)));
        assert!(s.contains(&(EV_ABS, ABS_Z, 1023)), "left trigger");
        assert!(s.contains(&(EV_ABS, ABS_HAT0X, -1)));
        assert_eq!(s.last(), Some(&(EV_SYN, SYN_REPORT, 0)));
    }

    #[test]
    fn later_reports_send_only_what_changed() {
        let first = GamepadReport::new(1 << 2, [0, 0, 5000, 0, 0, 0, 0, 0]);
        let second = GamepadReport::new(1 << 2 | 1 << 3, [0, 0, 6000, 0, 0, 0, 0, 1]);
        assert_eq!(
            summary(&second.events_since(Some(&first))),
            [(EV_KEY, BTN_Y, 1), (EV_ABS, ABS_RX, 6000), (EV_ABS, ABS_HAT0Y, 1), (EV_SYN, SYN_REPORT, 0)]
        );
        assert!(second.events_since(Some(&second)).is_empty(), "no change, no report");
    }

    #[test]
    fn trigger_and_dpad_bits_are_not_keys_and_axes_are_clamped() {
        let report = GamepadReport::new(0b1111_1100_0000, [40000, -40000, 0, 0, 2000, -5, 3, -3]);
        assert_eq!(report.axes, [STICK_MAX, STICK_MIN, 0, 0, TRIGGER_MAX, 0, 1, -1]);
        let s = summary(&report.events_since(Some(&GamepadReport::default())));
        assert!(s.iter().all(|&(kind, _, _)| kind != EV_KEY), "bits 6-11 press nothing: {s:?}");
    }

    #[test]
    fn an_unbound_driver_takes_its_unread_events_along() {
        let mut pad = Input::new(Description::gamepad("Xbox Wireless Controller"));
        pad.sender().send(&GamepadReport::new(1, [0; 8]).events_since(None));
        assert!(!pad.state.lock().unwrap().pending.is_empty());
        pad.reset();
        assert!(pad.state.lock().unwrap().pending.is_empty(), "no stale press for the next driver");
    }
}
