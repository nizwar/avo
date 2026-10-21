//! Pausing Android (`pause` / `resume` on the control socket): the vCPUs stop
//! running guest code and wait at a gate before their next `hv_vcpu_run`,
//! then go on where they were. Devices keep their state; what the guest
//! gets meanwhile (a network packet, a finished disk read) waits in its
//! queues and raises its interrupt once the vCPUs run again.
//!
//! The guest's clock stands still while it is paused, as with QEMU's
//! `kvm-adjvtime`: each vCPU's virtual counter offset grows by the pause's
//! length before it runs again, so CNTVCT goes on from where the guest last
//! saw it. A counter that jumped would make the kernel report soft lockups
//! and RCU stalls, and Android's watchdog and ANR timers fire. The wall
//! clock is the daemon's to put right afterwards (it knows the Mac's time).
//!
//! The gate is one per process: a guest reboot builds a new machine (and
//! new vCPUs), and a pause asked for between two machines holds the next
//! one's vCPUs before they run.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

pub static GATE: Gate = Gate::new();

/// Whether a pause is asked for or holds (device threads that keep time,
/// such as the sensors and the sound clock, skip their ticks meanwhile).
pub fn is_paused() -> bool {
    GATE.requested.load(Ordering::SeqCst)
}

pub struct Gate {
    requested: AtomicBool,
    state: Mutex<State>,
    changed: Condvar,
}

type Kick = Box<dyn Fn() + Send>;
/// Called with true once paused, false before the vCPUs run again; false
/// from the observer unregisters it.
type Observer = Box<dyn FnMut(bool) -> bool + Send>;

struct State {
    /// vCPUs that run guest code: past the gate, not parked, not powered off.
    running: usize,
    /// The pause holds: every vCPU stopped.
    paused: bool,
    /// When the last vCPU stopped: host counter ticks and the instant.
    stopped_at: Option<(u64, Instant)>,
    /// Counter ticks the guests of this process did not see (every pause).
    frozen_ticks: u64,
    /// Makes the current machine's vCPUs leave `hv_vcpu_run`.
    kick: Option<Kick>,
    machine: u64,
    observers: Vec<Observer>,
}

impl Gate {
    pub const fn new() -> Gate {
        Gate {
            requested: AtomicBool::new(false),
            state: Mutex::new(State {
                running: 0,
                paused: false,
                stopped_at: None,
                frozen_ticks: 0,
                kick: None,
                machine: 0,
                observers: Vec::new(),
            }),
            changed: Condvar::new(),
        }
    }

    /// A machine about to start its vCPUs; `kick` makes them leave `run`.
    pub fn attach(&self, kick: Kick) -> Attachment<'_> {
        let mut state = self.state.lock().unwrap();
        state.machine += 1;
        state.kick = Some(kick);
        Attachment { gate: self, machine: state.machine, start_ticks: state.frozen_ticks }
    }

    /// Stops every vCPU, waiting until none runs guest code; false when it
    /// was paused already. A vCPU that does not stop within `timeout` (stuck
    /// in a device) fails the pause, and the others go on.
    pub fn pause(&self, timeout: Duration) -> Result<bool, String> {
        let mut state = self.state.lock().unwrap();
        if state.paused {
            return Ok(false);
        }
        if !self.requested.swap(true, Ordering::SeqCst) {
            state.stopped_at = None;
        }
        if let Some(kick) = &state.kick {
            kick();
        }
        let deadline = Instant::now() + timeout;
        while state.running > 0 {
            if !self.requested.load(Ordering::SeqCst) {
                return Err("resumed before every vCPU stopped".into());
            }
            let Some(left) = deadline.checked_duration_since(Instant::now()) else {
                self.requested.store(false, Ordering::SeqCst);
                state.stopped_at = None;
                self.changed.notify_all();
                return Err(format!("{} vCPU(s) did not stop", state.running));
            };
            state = self.changed.wait_timeout(state, left).unwrap().0;
        }
        if state.paused {
            return Ok(false); // another connection's pause got there first
        }
        if state.stopped_at.is_none() {
            state.stopped_at = Some((host_ticks(), Instant::now()));
        }
        state.paused = true;
        Self::notify(&mut state, true);
        Ok(true)
    }

    /// Lets the vCPUs run again; how long the guest stood still, None when
    /// it was not paused. Asked during a pause that still waits for its
    /// vCPUs, that pause fails.
    pub fn resume(&self) -> Option<Duration> {
        let mut state = self.state.lock().unwrap();
        if !self.requested.load(Ordering::SeqCst) {
            return None;
        }
        let stood = state.stopped_at.take().map(|(ticks, at)| {
            state.frozen_ticks += host_ticks().saturating_sub(ticks);
            at.elapsed()
        });
        // Devices first, while no vCPU can touch them yet.
        if state.paused {
            Self::notify(&mut state, false);
        }
        state.paused = false;
        self.requested.store(false, Ordering::SeqCst);
        self.changed.notify_all();
        Some(stood.unwrap_or_default())
    }

    /// Hears every pause and resume from now on (see `Observer`).
    pub fn observe(&self, observer: Observer) {
        self.state.lock().unwrap().observers.push(observer);
    }

    fn notify(state: &mut State, paused: bool) {
        state.observers.retain_mut(|observer| observer(paused));
    }

    /// Wakes parked vCPUs to look at their machine again (it stops).
    pub fn wake(&self) {
        let _state = self.state.lock().unwrap();
        self.changed.notify_all();
    }
}

/// A machine's tie to the gate, for its life.
pub struct Attachment<'a> {
    gate: &'a Gate,
    machine: u64,
    /// The frozen ticks before this machine: its counter starts from there.
    start_ticks: u64,
}

impl<'a> Attachment<'a> {
    /// One vCPU's place at the gate.
    pub fn seat(&self) -> Seat<'a> {
        Seat { gate: self.gate, start_ticks: self.start_ticks, applied: self.start_ticks, in_guest: false }
    }
}

impl Drop for Attachment<'_> {
    fn drop(&mut self) {
        let mut state = self.gate.state.lock().unwrap();
        if state.machine == self.machine {
            state.kick = None;
        }
    }
}

/// What a vCPU does at the gate.
#[derive(Debug, PartialEq, Eq)]
pub enum Pass {
    Run,
    /// Run, with the counter offset grown by this many ticks since the
    /// machine started (the pauses it stood still for).
    Shift(u64),
    /// The machine stops.
    Stop,
}

pub struct Seat<'a> {
    gate: &'a Gate,
    start_ticks: u64,
    applied: u64,
    in_guest: bool,
}

impl Seat<'_> {
    /// Before each `hv_vcpu_run`: parks while a pause is asked for, until
    /// it ends or `stopping` (the machine's own stop) is set. A stop is
    /// looked for on every run: the kick that comes with it is lost on a vCPU
    /// that is handling an exit at the time (an MMIO or WFI loop).
    pub fn before_run(&mut self, stopping: &AtomicBool) -> Pass {
        if self.in_guest && !self.gate.requested.load(Ordering::SeqCst) && !stopping.load(Ordering::SeqCst) {
            return Pass::Run;
        }
        let gate = self.gate;
        let mut state = gate.state.lock().unwrap();
        if self.in_guest {
            self.in_guest = false;
            state.running -= 1;
            if state.running == 0 && gate.requested.load(Ordering::SeqCst) {
                state.stopped_at = Some((host_ticks(), Instant::now()));
                gate.changed.notify_all();
            }
        }
        while gate.requested.load(Ordering::SeqCst) && !stopping.load(Ordering::SeqCst) {
            state = gate.changed.wait(state).unwrap();
        }
        if stopping.load(Ordering::SeqCst) {
            return Pass::Stop;
        }
        state.running += 1;
        self.in_guest = true;
        let frozen = state.frozen_ticks;
        drop(state);
        if frozen == self.applied {
            return Pass::Run;
        }
        self.applied = frozen;
        Pass::Shift(frozen - self.start_ticks)
    }

    /// The vCPU stops running guest code for a while (PSCI CPU_OFF).
    pub fn off(&mut self) {
        if !self.in_guest {
            return;
        }
        self.in_guest = false;
        let mut state = self.gate.state.lock().unwrap();
        state.running -= 1;
        if state.running == 0 {
            self.gate.changed.notify_all();
        }
    }
}

impl Drop for Seat<'_> {
    fn drop(&mut self) {
        self.off();
    }
}

unsafe extern "C" {
    fn mach_absolute_time() -> u64;
}

/// The host counter, which CNTVCT follows (minus the vCPU's offset).
fn host_ticks() -> u64 {
    unsafe { mach_absolute_time() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::AtomicU64;

    /// vCPU threads without a VM: each counts its passes through the gate.
    fn spin(attachment: &'static Attachment<'static>, count: Arc<AtomicU64>, stopping: Arc<AtomicBool>,
            shifts: Arc<Mutex<Vec<u64>>>) -> std::thread::JoinHandle<()> {
        std::thread::spawn(move || {
            let mut seat = attachment.seat();
            loop {
                match seat.before_run(&stopping) {
                    Pass::Stop => return,
                    Pass::Shift(ticks) => shifts.lock().unwrap().push(ticks),
                    Pass::Run => {}
                }
                count.fetch_add(1, Ordering::Relaxed);
                std::thread::sleep(Duration::from_micros(200));
            }
        })
    }

    #[test]
    fn a_pause_holds_every_vcpu_and_stands_the_clock_still() {
        static TEST_GATE: Gate = Gate::new();
        let attachment: &'static Attachment<'static> = Box::leak(Box::new(TEST_GATE.attach(Box::new(|| {}))));
        let stopping = Arc::new(AtomicBool::new(false));
        let shifts = Arc::new(Mutex::new(Vec::new()));
        let counts: Vec<Arc<AtomicU64>> = (0..3).map(|_| Arc::new(AtomicU64::new(0))).collect();
        let threads: Vec<_> =
            counts.iter().map(|c| spin(attachment, c.clone(), stopping.clone(), shifts.clone())).collect();
        std::thread::sleep(Duration::from_millis(20));

        let paused = Arc::new(AtomicU64::new(0));
        let seen = paused.clone();
        TEST_GATE.observe(Box::new(move |p| {
            seen.fetch_add(if p { 1 } else { 100 }, Ordering::SeqCst);
            true
        }));
        assert_eq!(TEST_GATE.pause(Duration::from_secs(2)), Ok(true));
        assert!(TEST_GATE.requested.load(Ordering::SeqCst));
        assert_eq!(TEST_GATE.pause(Duration::from_secs(2)), Ok(false), "already paused");
        let before: Vec<u64> = counts.iter().map(|c| c.load(Ordering::SeqCst)).collect();
        std::thread::sleep(Duration::from_millis(60));
        let after: Vec<u64> = counts.iter().map(|c| c.load(Ordering::SeqCst)).collect();
        assert_eq!(before, after, "no vCPU passes the gate while paused");
        assert_eq!(paused.load(Ordering::SeqCst), 1, "observers hear the pause once");

        let stood = TEST_GATE.resume().expect("was paused");
        assert!(stood >= Duration::from_millis(60), "{stood:?}");
        assert_eq!(TEST_GATE.resume(), None, "resuming twice is harmless");
        std::thread::sleep(Duration::from_millis(20));
        let resumed: Vec<u64> = counts.iter().map(|c| c.load(Ordering::SeqCst)).collect();
        assert!(resumed.iter().zip(&after).all(|(r, a)| r > a), "every vCPU runs again");
        assert_eq!(paused.load(Ordering::SeqCst), 101);
        // Each vCPU shifts its counter once, by the same amount (~60 ms of 24 MHz ticks).
        let shifts_now = shifts.lock().unwrap().clone();
        assert_eq!(shifts_now.len(), 3, "{shifts_now:?}");
        assert!(shifts_now.windows(2).all(|w| w[0] == w[1]));
        assert!(shifts_now[0] >= 24_000 * 60, "{shifts_now:?}");

        // A machine that stops while paused lets its vCPUs go.
        assert_eq!(TEST_GATE.pause(Duration::from_secs(2)), Ok(true));
        stopping.store(true, Ordering::SeqCst);
        TEST_GATE.wake();
        for thread in threads {
            thread.join().unwrap();
        }
        assert!(TEST_GATE.resume().is_some());
    }

    #[test]
    fn a_pause_without_vcpus_holds_at_once_and_one_that_cannot_stop_fails() {
        static TEST_GATE: Gate = Gate::new();
        assert_eq!(TEST_GATE.pause(Duration::from_millis(10)), Ok(true), "between two machines");
        assert!(TEST_GATE.resume().is_some());

        // A vCPU busy in a device (past the gate, never back) blocks the pause.
        let attachment = TEST_GATE.attach(Box::new(|| {}));
        let mut seat = attachment.seat();
        let stopping = AtomicBool::new(false);
        assert_eq!(seat.before_run(&stopping), Pass::Run);
        let started = Instant::now();
        assert!(TEST_GATE.pause(Duration::from_millis(50)).is_err());
        assert!(started.elapsed() >= Duration::from_millis(50));
        assert!(!is_paused_in(&TEST_GATE), "a failed pause is undone");
        assert_eq!(seat.before_run(&stopping), Pass::Run, "and the vCPU goes on");
        seat.off();
        assert_eq!(TEST_GATE.pause(Duration::from_millis(50)), Ok(true), "a powered-off vCPU does not hold it up");
        TEST_GATE.resume();
    }

    fn is_paused_in(gate: &Gate) -> bool {
        gate.requested.load(Ordering::SeqCst)
    }
}
