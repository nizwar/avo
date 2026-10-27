//! virtio-blk (virtio 1.2 §5.2) over a [`Disk`].
//!
//! A write the Mac's disk has no room for (ENOSPC, or EDQUOT past a quota)
//! is not failed to the guest: f2fs takes a failed write for a broken disk,
//! and loses writes, stops its checkpoints or makes /data read-only, and
//! apps crash. The request waits instead, every request after it waits
//! behind it in order, and a thread of its own tries again with a pause
//! that grows between tries (as QEMU's `werror=enospc` stops the guest and
//! retries): Android's I/O waits until there is room, then goes on.
//! Subscribers hear `disk full on` when the first request starts waiting
//! and `disk full off` once all went through or the driver let them go
//! (sticky, control.rs). Other failures still reach the guest as S_IOERR,
//! and the log says so (the first, then at most one a minute).

use super::queue::{Chain, Queue};
use super::{Active, Interrupt, TYPE_BLOCK, VirtioDevice};
use crate::disk::{Disk, SECTOR};
use crate::memory::GuestMemory;
use crate::pause::Gate;
use std::collections::VecDeque;
use std::io;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

const F_SEG_MAX: u64 = 1 << 2;
const F_RO: u64 = 1 << 5;
const F_BLK_SIZE: u64 = 1 << 6;
const F_FLUSH: u64 = 1 << 9;

const T_IN: u32 = 0;
const T_OUT: u32 = 1;
const T_FLUSH: u32 = 4;
const T_GET_ID: u32 = 8;

const S_OK: u8 = 0;
const S_IOERR: u8 = 1;
const S_UNSUPP: u8 = 2;

const SEG_MAX: u32 = 126;

/// Reads and writes go between guest memory and the disk through a buffer
/// of at most this many bytes: their lengths are the guest's. Real requests
/// are far smaller (Linux sends at most 1280 KiB by default) and still take
/// one disk call.
const CHUNK: usize = 16 << 20;

/// The first try again of a request that found no room, and the longest
/// pause between tries (a full disk's write fails at once, so trying costs
/// nothing; room comes back when the user frees some).
const FIRST_RETRY: Duration = Duration::from_millis(100);
const LONGEST_RETRY: Duration = Duration::from_secs(2);

pub struct Block {
    shared: Arc<Shared>,
}

/// The device, as the vCPU that notifies it and the retrier both use it.
struct Shared {
    disk: Box<dyn Disk>,
    id: String,
    state: Mutex<State>,
    /// Ends the retrier's pause early: the driver reset the device.
    wake: Condvar,
    /// Hears true when requests start waiting for room, false once none waits.
    full: Option<Box<dyn Fn(bool) + Send + Sync>>,
    failures: Mutex<Failures>,
    /// The pause gate a checkpoint waits at (the process's; a test's own).
    gate: &'static Gate,
}

#[derive(Default)]
struct State {
    active: Option<Active>,
    /// Requests that wait for room on the Mac's disk, oldest first.
    waiting: VecDeque<Chain>,
    /// A retrier runs for this start of the device.
    retrying: bool,
    /// The device's resets: a retrier of an earlier start ends.
    starts: u64,
    /// The pause-gate observer is registered (once for the device's life).
    observing: bool,
}

/// I/O errors the guest got, for the log.
#[derive(Default)]
struct Failures {
    logged: Option<Instant>,
    since: u64,
}

/// What became of a request.
enum Outcome {
    /// Handed back: the bytes the device wrote into it, the status byte too.
    Done(u32),
    /// The Mac's disk has no room for it yet: it waits, and is tried again.
    NoRoom(io::Error),
}

/// A write that only needs room on the Mac's disk.
fn no_room(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(libc::ENOSPC) | Some(libc::EDQUOT))
}

impl Block {
    pub fn new(disk: Box<dyn Disk>, id: &str) -> Block {
        Block { shared: Arc::new(Shared { disk, id: id.to_string(), state: Mutex::default(), wake: Condvar::new(), full: None,
                                          failures: Mutex::default(), gate: &crate::pause::GATE }) }
    }

    /// `report(true)` once requests wait for room, `report(false)` once none does.
    pub fn on_full(mut self, report: Box<dyn Fn(bool) + Send + Sync>) -> Block {
        Arc::get_mut(&mut self.shared).expect("set before the device runs").full = Some(report);
        self
    }

    /// A gate of the test's own in place of the process's, which other
    /// tests pause.
    #[cfg(test)]
    fn on_gate(mut self, gate: &'static Gate) -> Block {
        Arc::get_mut(&mut self.shared).expect("set before the device runs").gate = gate;
        self
    }
}

impl Shared {
    /// The byte offset of `len` bytes at `sector`, if all of them are on
    /// the disk. Both come from the guest, so nothing here may wrap.
    fn extent(&self, sector: u64, len: usize) -> Option<u64> {
        let offset = sector.checked_mul(SECTOR)?;
        let end = offset.checked_add(len as u64)?;
        (end <= self.disk.size()).then_some(offset)
    }

    /// Says whether requests wait for room. Called with the state lock held,
    /// as the state changes, so the reports keep the changes' order: an "off"
    /// sent after the lock went could land after the next episode's "on" and
    /// leave the sticky event saying no write waits while one does.
    fn report(&self, _state: &State, full: bool) {
        if let Some(report) = &self.full {
            report(full);
        }
    }

    /// An I/O error the guest gets: the first is logged, then at most one a
    /// minute, with how many came between (a failing drive fails them all).
    fn failed(&self, what: &str, offset: u64, error: &io::Error) {
        let mut failures = self.failures.lock().unwrap();
        if failures.logged.is_some_and(|at| at.elapsed() < Duration::from_secs(60)) {
            failures.since += 1;
            return;
        }
        let more = std::mem::take(&mut failures.since);
        failures.logged = Some(Instant::now());
        let between = if more > 0 { format!(" ({more} more since the last one logged)") } else { String::new() };
        eprintln!("[vmm] disk: {what} at {offset} failed: {error}{between}");
    }

    /// The driver's new requests, each in turn; once one waits for room,
    /// every later one waits behind it. True when any waits.
    fn serve(&self, state: &mut State, active: &mut Active) -> bool {
        while let Some(chain) = active.queues[0].pop(&active.memory) {
            if !state.waiting.is_empty() {
                state.waiting.push_back(chain);
                continue;
            }
            match self.handle(&active.memory, &chain) {
                Outcome::Done(len) => active.complete(0, chain.head, len),
                Outcome::NoRoom(error) => {
                    eprintln!("[vmm] disk: no room for a write ({error}); Android's I/O waits until there is");
                    state.waiting.push_back(chain);
                }
            }
        }
        !state.waiting.is_empty()
    }

    /// The retrier: tries the waiting requests again, oldest first, with a
    /// pause that grows between tries, until none waits or the driver reset
    /// the device. Nothing reaches the disk while Android is paused (a
    /// checkpoint clones its disks then): every write looks at the gate
    /// under the state lock it is made under, and a pause sets the gate
    /// before its observer takes that lock (`spawn_retrier`), so once the
    /// pause is done no later write gets past the look.
    fn retry(self: Arc<Self>, start: u64) {
        /// One pass's handling of the front request.
        enum Step {
            Did,
            Empty,
            NoRoom,
        }
        let began = Instant::now();
        let mut pause = FIRST_RETRY;
        let mut state = self.state.lock().unwrap();
        loop {
            state = self.wake.wait_timeout(state, pause).unwrap().0;
            if state.starts != start {
                return;
            }
            if self.gate.is_paused() {
                continue;
            }
            let Some(mut active) = state.active.take() else {
                state.retrying = false;
                return;
            };
            // Try the waiting requests oldest first. Each disk write runs under
            // the state lock (so a pause's observer, which takes the lock,
            // cannot finish mid-write and leave a checkpoint an inconsistent
            // disk), but the lock is released between requests so a vCPU kicked
            // to the pause gate — its notify() is a no-op while `active` is
            // taken out — and a pause itself can take it, instead of stalling
            // behind a long pass.
            loop {
                let step = if let Some(chain) = state.waiting.front() {
                    match self.handle(&active.memory, chain) {
                        Outcome::Done(len) => {
                            let chain = state.waiting.pop_front().unwrap();
                            active.complete(0, chain.head, len);
                            Step::Did
                        }
                        Outcome::NoRoom(_) => Step::NoRoom,
                    }
                } else {
                    Step::Empty
                };
                match step {
                    Step::Did => {
                        drop(state);
                        std::thread::yield_now();
                        state = self.state.lock().unwrap();
                        if state.starts != start {
                            return;
                        }
                        // A pause came meanwhile (its observer may have had
                        // the lock already): the rest waits until it ends.
                        if self.gate.is_paused() {
                            break;
                        }
                    }
                    Step::Empty | Step::NoRoom => break,
                }
            }
            // And what the driver queued meanwhile without a kick, unless a
            // pause holds the writes.
            let waiting = !state.waiting.is_empty() || self.gate.is_paused() || self.serve(&mut state, &mut active);
            state.active = Some(active);
            if !waiting {
                state.retrying = false;
                self.report(&state, false);
                drop(state);
                eprintln!("[vmm] disk: there is room again; Android's I/O waited {:.1?}", began.elapsed());
                return;
            }
            pause = (pause * 2).min(LONGEST_RETRY);
        }
    }

    /// Starts the retrier for this start of the device. The first start also
    /// registers one pause-gate observer for the device's life: while the
    /// device exists a pause's notify takes the state lock here, so a pause
    /// cannot finish while a retry holds it mid-write. The observer removes
    /// itself when the device is dropped (its Weak stops upgrading); a fresh
    /// observer per disk-full episode would leak. If the thread cannot be
    /// spawned, the held requests are failed rather than left waiting forever.
    fn spawn_retrier(self: &Arc<Self>, start: u64, register_observer: bool) {
        if register_observer {
            let barrier = Arc::downgrade(self);
            self.gate.observe(Box::new(move |_| {
                let Some(shared) = barrier.upgrade() else { return false };
                // Take and release the lock: it blocks here until a retry pass
                // is between requests, so a pause does not finish mid-write.
                drop(shared.state.lock().unwrap());
                true
            }));
        }
        let shared = self.clone();
        if let Err(error) = std::thread::Builder::new().name("disk retry".into()).spawn(move || shared.retry(start)) {
            eprintln!("[vmm] disk: no thread to try the waiting requests again: {error}; failing the held writes");
            self.fail_all_waiting(start);
        }
    }

    /// Hands every waiting request back with an I/O error (a retrier could not
    /// be started), so Android's I/O does not wait forever.
    fn fail_all_waiting(&self, start: u64) {
        let mut state = self.state.lock().unwrap();
        if state.starts != start {
            return;
        }
        state.retrying = false;
        let Some(mut active) = state.active.take() else {
            state.waiting.clear();
            return;
        };
        while let Some(chain) = state.waiting.pop_front() {
            let len = match chain.descriptors.last() {
                Some(status) if status.write && status.len >= 1 => {
                    let at = status.address.saturating_add(status.len as u64 - 1);
                    active.memory.write(at, &[S_IOERR]);
                    1
                }
                _ => 0,
            };
            active.complete(0, chain.head, len);
        }
        state.active = Some(active);
        self.report(&state, false);
    }

    fn handle(&self, memory: &GuestMemory, chain: &Chain) -> Outcome {
        // Layout: 16-byte header (readable), data, 1-byte status (writable, last).
        let Some(status) = chain.descriptors.last().filter(|d| d.write && d.len >= 1).copied() else {
            return Outcome::Done(0);
        };
        // Saturates where it would wrap, to an address no write accepts.
        let status_address = status.address.saturating_add(status.len as u64 - 1);
        let mut header = [0u8; 16];
        let readable: Vec<_> = chain.readable().copied().collect();
        if !read_bytes(memory, &readable, 0, &mut header) {
            memory.write(status_address, &[S_IOERR]);
            return Outcome::Done(1);
        }
        let kind = u32::from_le_bytes(header[0..4].try_into().unwrap());
        let sector = u64::from_le_bytes(header[8..16].try_into().unwrap());

        // Data buffers: writable ones before the status byte, or readable ones after the header.
        let mut data_in: Vec<(u64, usize)> = Vec::new();
        for (i, d) in chain.descriptors.iter().enumerate() {
            if d.write {
                let last = i == chain.descriptors.len() - 1;
                let len = if last { d.len as usize - 1 } else { d.len as usize };
                if len > 0 {
                    data_in.push((d.address, len));
                }
            }
        }

        let (code, written) = match kind {
            T_IN => {
                let total: usize = data_in.iter().map(|(_, l)| l).sum();
                match self.extent(sector, total) {
                    None => (S_IOERR, 0),
                    Some(offset) => {
                        let mut buffer = vec![0u8; total.min(CHUNK)];
                        let mut done = 0;
                        loop {
                            let n = (total - done).min(CHUNK);
                            if let Err(error) = self.disk.read_at(&mut buffer[..n], offset + done as u64) {
                                self.failed("a read", offset + done as u64, &error);
                                break (S_IOERR, 0);
                            }
                            write_bytes(memory, &data_in, done, &buffer[..n]);
                            done += n;
                            if done == total {
                                break (S_OK, total as u32);
                            }
                        }
                    }
                }
            }
            T_OUT => {
                let total = chain.readable_len().saturating_sub(16);
                // All of it must be RAM before the first chunk reaches the
                // disk: a bad request fails whole, as when it was one piece.
                let in_ram = readable.iter().all(|d| memory.host_ptr(d.address, d.len as usize).is_some());
                match self.extent(sector, total) {
                    Some(offset) if in_ram && !self.disk.read_only() => {
                        let mut buffer = vec![0u8; total.min(CHUNK)];
                        let mut done = 0;
                        loop {
                            let n = (total - done).min(CHUNK);
                            if !read_bytes(memory, &readable, 16 + done, &mut buffer[..n]) {
                                break (S_IOERR, 0);
                            }
                            // Tried again whole later: what went before is the same bytes again.
                            if let Err(error) = self.disk.write_at(&buffer[..n], offset + done as u64) {
                                if no_room(&error) {
                                    return Outcome::NoRoom(error);
                                }
                                self.failed("a write", offset + done as u64, &error);
                                break (S_IOERR, 0);
                            }
                            done += n;
                            if done == total {
                                break (S_OK, 0);
                            }
                        }
                    }
                    _ => (S_IOERR, 0),
                }
            }
            T_FLUSH => match self.disk.flush() {
                Ok(()) => (S_OK, 0),
                Err(error) if no_room(&error) => return Outcome::NoRoom(error),
                Err(error) => {
                    self.failed("a flush", 0, &error);
                    (S_IOERR, 0)
                }
            },
            T_GET_ID => {
                let mut id = [0u8; 20];
                let bytes = self.id.as_bytes();
                id[..bytes.len().min(20)].copy_from_slice(&bytes[..bytes.len().min(20)]);
                let mut at = 0;
                for (address, len) in &data_in {
                    let n = (*len).min(20 - at);
                    memory.write(*address, &id[at..at + n]);
                    at += n;
                    if at == 20 {
                        break;
                    }
                }
                (S_OK, at as u32)
            }
            _ => (S_UNSUPP, 0),
        };
        memory.write(status_address, &[code]);
        Outcome::Done(written + 1)
    }
}

/// Copies bytes starting `skip` bytes into the readable buffers.
fn read_bytes(memory: &GuestMemory, buffers: &[super::queue::Descriptor], skip: usize, out: &mut [u8]) -> bool {
    let mut position = 0usize;
    let mut filled = 0usize;
    for d in buffers {
        let len = d.len as usize;
        if position + len <= skip {
            position += len;
            continue;
        }
        let start = skip.saturating_sub(position);
        let take = (len - start).min(out.len() - filled);
        let Some(address) = d.address.checked_add(start as u64) else { return false };
        if !memory.read(address, &mut out[filled..filled + take]) {
            return false;
        }
        filled += take;
        position += len;
        if filled == out.len() {
            return true;
        }
    }
    filled == out.len()
}

/// Copies `data` into the writable buffers, starting `skip` bytes into them.
fn write_bytes(memory: &GuestMemory, buffers: &[(u64, usize)], skip: usize, data: &[u8]) {
    let mut position = 0usize;
    let mut written = 0usize;
    for &(address, len) in buffers {
        if written == data.len() {
            return;
        }
        if position + len <= skip {
            position += len;
            continue;
        }
        let start = skip.saturating_sub(position);
        let take = (len - start).min(data.len() - written);
        memory.write(address.saturating_add(start as u64), &data[written..written + take]);
        written += take;
        position += len;
    }
}

impl VirtioDevice for Block {
    fn device_type(&self) -> u16 {
        TYPE_BLOCK
    }

    fn features(&self) -> u64 {
        F_SEG_MAX | F_BLK_SIZE | F_FLUSH | if self.shared.disk.read_only() { F_RO } else { 0 }
    }

    fn queue_sizes(&self) -> Vec<u16> {
        vec![256]
    }

    fn config(&self) -> Vec<u8> {
        let mut config = vec![0u8; 60];
        config[0..8].copy_from_slice(&(self.shared.disk.size() / SECTOR).to_le_bytes());
        config[12..16].copy_from_slice(&SEG_MAX.to_le_bytes());
        config[20..24].copy_from_slice(&(SECTOR as u32).to_le_bytes());
        config
    }

    fn activate(&mut self, memory: Arc<GuestMemory>, queues: Vec<Queue>, interrupt: Interrupt, _features: u64) {
        self.shared.state.lock().unwrap().active = Some(Active { memory, queues, interrupt });
    }

    /// On the vCPU that notified: no write is half done once every vCPU
    /// stands at the pause gate (the retrier's tries wait for it to open).
    fn notify(&mut self, _queue: usize) {
        let shared = &self.shared;
        let mut state = shared.state.lock().unwrap();
        let Some(mut active) = state.active.take() else { return };
        let waiting = shared.serve(&mut state, &mut active);
        state.active = Some(active);
        if waiting && !state.retrying {
            state.retrying = true;
            let start = state.starts;
            let first_observer = !state.observing;
            state.observing = true;
            shared.report(&state, true);
            // The retrier starts after the lock goes: it may register the
            // gate's observer (the gate's lock), and a pause runs observers,
            // which take this lock, with the gate's lock held.
            drop(state);
            shared.spawn_retrier(start, first_observer);
        }
    }

    /// The driver lets go of every request, the waiting ones too.
    fn reset(&mut self) {
        let mut state = self.shared.state.lock().unwrap();
        state.active = None;
        let waited = !state.waiting.is_empty();
        state.waiting.clear();
        state.retrying = false;
        state.starts += 1;
        if waited {
            self.shared.report(&state, false);
        }
        drop(state);
        self.shared.wake.notify_all();
    }

    fn pci_class(&self) -> u32 {
        0x01_8000 // mass storage, other
    }
}

impl Drop for Block {
    /// The machine goes: a retrier still waiting for room ends with it
    /// (what it held was never handed back, as on a power cut).
    fn drop(&mut self) {
        self.shared.state.lock().unwrap().starts += 1;
        self.shared.wake.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::virtio::queue::Descriptor;
    use hvf::GuestRegion;

    const RAM: u64 = 0x8000_0000;

    /// A disk of `size` bytes, the first of them in `bytes` (the rest read
    /// as zeros), that keeps every read and write reaching it.
    #[derive(Clone, Default)]
    struct Recorder(Arc<Mutex<Recorded>>);

    #[derive(Default)]
    struct Recorded {
        size: u64,
        bytes: Vec<u8>,
        /// (write, offset, length)
        calls: Vec<(bool, u64, usize)>,
        /// Writes fail with ENOSPC, as on a full Mac disk.
        full: bool,
    }

    impl Disk for Recorder {
        fn size(&self) -> u64 {
            self.0.lock().unwrap().size
        }
        fn read_only(&self) -> bool {
            false
        }
        fn read_at(&self, buf: &mut [u8], offset: u64) -> std::io::Result<()> {
            let mut disk = self.0.lock().unwrap();
            disk.calls.push((false, offset, buf.len()));
            buf.fill(0);
            let start = (offset as usize).min(disk.bytes.len());
            let end = (start + buf.len()).min(disk.bytes.len());
            buf[..end - start].copy_from_slice(&disk.bytes[start..end]);
            Ok(())
        }
        fn write_at(&self, buf: &[u8], offset: u64) -> std::io::Result<()> {
            let mut disk = self.0.lock().unwrap();
            disk.calls.push((true, offset, buf.len()));
            if disk.full {
                return Err(io::Error::from_raw_os_error(libc::ENOSPC));
            }
            let start = (offset as usize).min(disk.bytes.len());
            let end = (start + buf.len()).min(disk.bytes.len());
            disk.bytes[start..end].copy_from_slice(&buf[..end - start]);
            Ok(())
        }
        fn flush(&self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn device(size: u64, bytes: Vec<u8>) -> (Block, Recorder, GuestMemory) {
        let disk = Recorder::default();
        *disk.0.lock().unwrap() = Recorded { size, bytes, calls: Vec::new(), full: false };
        let memory = GuestMemory::new(GuestRegion::new(RAM, 1 << 20).unwrap());
        (Block::new(Box::new(disk.clone()), "test"), disk, memory)
    }

    fn readable(address: u64, len: u32) -> Descriptor {
        Descriptor { address, len, write: false }
    }

    fn writable(address: u64, len: u32) -> Descriptor {
        Descriptor { address, len, write: true }
    }

    /// Runs one request (header at RAM, status at RAM + 16); its status and
    /// the length the device reports.
    fn run(block: &Block, memory: &GuestMemory, kind: u32, sector: u64, data: Vec<Descriptor>) -> (u8, u32) {
        let mut header = [0u8; 16];
        header[0..4].copy_from_slice(&kind.to_le_bytes());
        header[8..16].copy_from_slice(&sector.to_le_bytes());
        memory.write(RAM, &header);
        let mut descriptors = vec![readable(RAM, 16)];
        descriptors.extend(data);
        descriptors.push(writable(RAM + 16, 1));
        let Outcome::Done(len) = block.shared.handle(memory, &Chain { head: 0, descriptors }) else {
            panic!("the request waits for room");
        };
        let mut status = [0xff];
        memory.read(RAM + 16, &mut status);
        (status[0], len)
    }

    #[test]
    fn reads_and_writes_on_the_disk_take_one_call_each() {
        let (block, disk, memory) = device(64 << 10, (0..64 << 10).map(|i| (i / 512) as u8).collect());
        assert_eq!(run(&block, &memory, T_IN, 2, vec![writable(RAM + 0x1000, 1000), writable(RAM + 0x2000, 24)]), (S_OK, 1025));
        let mut data = [0u8; 1024];
        memory.read(RAM + 0x1000, &mut data[..1000]);
        memory.read(RAM + 0x2000, &mut data[1000..]);
        assert_eq!(data[..], disk.0.lock().unwrap().bytes[1024..2048]);

        memory.write(RAM + 0x3000, &[0xab; 512]);
        assert_eq!(run(&block, &memory, T_OUT, 4, vec![readable(RAM + 0x3000, 512)]), (S_OK, 1));
        let disk = disk.0.lock().unwrap();
        assert_eq!(disk.bytes[2048..2560], [0xab; 512]);
        assert_eq!(disk.calls, [(false, 1024, 1024), (true, 2048, 512)]);
    }

    #[test]
    fn requests_that_do_not_fit_the_disk_fail_without_reaching_it() {
        let (block, disk, memory) = device(64 << 10, vec![0; 64 << 10]);
        let huge = || vec![writable(RAM, u32::MAX), writable(RAM, u32::MAX)];
        let cases = [
            (T_IN, 0, huge(), "a huge length"),
            (T_OUT, 0, vec![readable(RAM + 0x1000, u32::MAX)], "a huge length"),
            (T_IN, u64::MAX / SECTOR + 1, vec![writable(RAM + 0x1000, 512)], "the sector's offset overflows"),
            (T_OUT, u64::MAX / SECTOR, vec![readable(RAM + 0x1000, 1024)], "the end overflows"),
            (T_IN, 127, vec![writable(RAM + 0x1000, 1024)], "past the end"),
            (T_OUT, 128, vec![readable(RAM + 0x1000, 512)], "past the end"),
        ];
        for (kind, sector, data, why) in cases {
            assert_eq!(run(&block, &memory, kind, sector, data), (S_IOERR, 1), "{why}");
        }
        assert!(disk.0.lock().unwrap().calls.is_empty());
        // The last sector is still on the disk.
        assert_eq!(run(&block, &memory, T_IN, 127, vec![writable(RAM + 0x1000, 512)]), (S_OK, 513));
    }

    #[test]
    fn a_request_larger_than_a_chunk_goes_through_in_chunks() {
        // 40 MiB on a large disk, from 1 MiB of RAM named again and again.
        let (block, disk, memory) = device(1 << 40, Vec::new());
        let total = 40 << 20;
        assert_eq!(run(&block, &memory, T_IN, 8, vec![writable(RAM, 1 << 20); 40]), (S_OK, total as u32 + 1));
        assert_eq!(run(&block, &memory, T_OUT, 8, vec![readable(RAM, 1 << 20); 40]), (S_OK, 1));
        for write in [false, true] {
            let calls: Vec<_> = disk.0.lock().unwrap().calls.iter().filter(|c| c.0 == write).copied().collect();
            assert_eq!(calls.len(), 3);
            assert!(calls.iter().all(|&(_, _, len)| len <= CHUNK));
            assert_eq!(calls.iter().map(|c| c.2).sum::<usize>(), total);
            assert_eq!(calls[0].1, 8 * SECTOR);
            assert!(calls.windows(2).all(|w| w[0].1 + w[0].2 as u64 == w[1].1), "in order, end to end");
        }
    }

    /// A split virtqueue in guest RAM, laid out as a driver does.
    struct Ring {
        next_descriptor: u16,
        next_available: u16,
    }

    const DESCRIPTORS: u64 = RAM + 0x10000;
    const AVAILABLE: u64 = RAM + 0x11000;
    const USED: u64 = RAM + 0x12000;
    const RING_SIZE: u16 = 16;

    impl Ring {
        fn queue() -> Queue {
            let mut queue = Queue::new(RING_SIZE);
            queue.ready = true;
            (queue.desc_table, queue.avail_ring, queue.used_ring) = (DESCRIPTORS, AVAILABLE, USED);
            queue
        }

        /// Makes a request available, at `at`: its header, `data` and its
        /// status byte (0xff until the device sets it). Its head.
        fn publish(&mut self, memory: &GuestMemory, at: u64, kind: u32, sector: u64, data: Descriptor) -> u16 {
            let mut header = [0u8; 16];
            header[0..4].copy_from_slice(&kind.to_le_bytes());
            header[8..16].copy_from_slice(&sector.to_le_bytes());
            memory.write(at, &header);
            memory.write(at + 0x800, &[0xff]);
            let head = self.next_descriptor;
            let chain = [readable(at, 16), data, writable(at + 0x800, 1)];
            for (i, d) in chain.iter().enumerate() {
                let index = self.next_descriptor;
                self.next_descriptor += 1;
                let flags: u16 = if d.write { 2 } else { 0 } | if i + 1 < chain.len() { 1 } else { 0 };
                let mut raw = [0u8; 16];
                raw[0..8].copy_from_slice(&d.address.to_le_bytes());
                raw[8..12].copy_from_slice(&d.len.to_le_bytes());
                raw[12..14].copy_from_slice(&flags.to_le_bytes());
                raw[14..16].copy_from_slice(&(index + 1).to_le_bytes());
                memory.write(DESCRIPTORS + index as u64 * 16, &raw);
            }
            memory.write_u16(AVAILABLE + 4 + (self.next_available % RING_SIZE) as u64 * 2, head);
            self.next_available += 1;
            memory.write_u16(AVAILABLE + 2, self.next_available);
            head
        }

        /// The heads handed back, in order.
        fn used(memory: &GuestMemory) -> Vec<u16> {
            let count = memory.read_u16(USED + 2).unwrap();
            (0..count).map(|i| memory.read_u32(USED + 4 + (i % RING_SIZE) as u64 * 8).unwrap() as u16).collect()
        }

        fn status(memory: &GuestMemory, at: u64) -> u8 {
            let mut status = [0];
            memory.read(at + 0x800, &mut status);
            status[0]
        }
    }

    /// A device on its queue, and what it said about room.
    fn started(size: u64) -> (Block, Recorder, Arc<GuestMemory>, Arc<Mutex<Vec<bool>>>) {
        let (block, disk, memory) = device(size, vec![0; size as usize]);
        let heard = Arc::new(Mutex::new(Vec::new()));
        let reports = heard.clone();
        let mut block = block.on_full(Box::new(move |full| reports.lock().unwrap().push(full)));
        let memory = Arc::new(memory);
        block.activate(memory.clone(), vec![Ring::queue()], Interrupt::new(|_| {}), 0);
        (block, disk, memory, heard)
    }

    fn eventually(condition: impl Fn() -> bool) -> bool {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !condition() {
            if Instant::now() > deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        true
    }

    #[test]
    fn a_write_with_no_room_waits_and_goes_through_once_there_is_room() {
        let (mut block, disk, memory, heard) = started(64 << 10);
        disk.0.lock().unwrap().full = true;
        // A write, then a read of what it writes: the read waits behind it.
        let mut ring = Ring { next_descriptor: 0, next_available: 0 };
        memory.write(RAM + 0x3000, &[0xab; 512]);
        let write = ring.publish(&memory, RAM + 0x20000, T_OUT, 4, readable(RAM + 0x3000, 512));
        let read = ring.publish(&memory, RAM + 0x21000, T_IN, 4, writable(RAM + 0x4000, 512));
        block.notify(0);
        assert!(Ring::used(&memory).is_empty(), "neither is handed back");
        assert_eq!(Ring::status(&memory, RAM + 0x20000), 0xff, "nor failed");
        assert_eq!(*heard.lock().unwrap(), [true]);
        // Tried again meanwhile, and still no room.
        assert!(eventually(|| disk.0.lock().unwrap().calls.iter().filter(|c| c.0).count() >= 2));
        assert!(Ring::used(&memory).is_empty());

        // Room again: both go through, in order, and the read has the write's bytes.
        disk.0.lock().unwrap().full = false;
        assert!(eventually(|| Ring::used(&memory).len() == 2));
        assert_eq!(Ring::used(&memory), [write, read]);
        assert_eq!((Ring::status(&memory, RAM + 0x20000), Ring::status(&memory, RAM + 0x21000)), (S_OK, S_OK));
        let mut data = [0u8; 512];
        memory.read(RAM + 0x4000, &mut data);
        assert_eq!(data, [0xab; 512]);
        assert!(eventually(|| *heard.lock().unwrap() == [true, false]));
        assert!(eventually(|| !block.shared.state.lock().unwrap().retrying), "the retrier is done");

        // Later requests go straight through again.
        let again = ring.publish(&memory, RAM + 0x22000, T_OUT, 8, readable(RAM + 0x3000, 512));
        block.notify(0);
        assert_eq!(Ring::used(&memory).last(), Some(&again));
        assert_eq!(*heard.lock().unwrap(), [true, false]);
    }

    #[test]
    fn a_reset_lets_go_of_the_waiting_requests() {
        let (mut block, disk, memory, heard) = started(64 << 10);
        disk.0.lock().unwrap().full = true;
        let mut ring = Ring { next_descriptor: 0, next_available: 0 };
        ring.publish(&memory, RAM + 0x20000, T_OUT, 0, readable(RAM + 0x3000, 512));
        block.notify(0);
        assert_eq!(*heard.lock().unwrap(), [true]);
        block.reset();
        assert_eq!(*heard.lock().unwrap(), [true, false], "nothing waits any more");
        let tries = disk.0.lock().unwrap().calls.len();
        std::thread::sleep(FIRST_RETRY * 3);
        assert_eq!(disk.0.lock().unwrap().calls.len(), tries, "the retrier ended with the driver's start");
        assert!(Ring::used(&memory).is_empty());
        assert!(block.shared.state.lock().unwrap().waiting.is_empty());
    }

    #[test]
    fn other_failures_still_reach_the_guest() {
        struct Broken;
        impl Disk for Broken {
            fn size(&self) -> u64 {
                64 << 10
            }
            fn read_only(&self) -> bool {
                false
            }
            fn read_at(&self, _: &mut [u8], _: u64) -> io::Result<()> {
                Err(io::Error::from_raw_os_error(libc::EIO))
            }
            fn write_at(&self, _: &[u8], _: u64) -> io::Result<()> {
                Err(io::Error::from_raw_os_error(libc::EIO))
            }
            fn flush(&self) -> io::Result<()> {
                Err(io::Error::from_raw_os_error(libc::EIO))
            }
        }
        let memory = GuestMemory::new(GuestRegion::new(RAM, 1 << 20).unwrap());
        let block = Block::new(Box::new(Broken), "test");
        assert_eq!(run(&block, &memory, T_OUT, 0, vec![readable(RAM + 0x1000, 512)]), (S_IOERR, 1));
        assert_eq!(run(&block, &memory, T_IN, 0, vec![writable(RAM + 0x1000, 512)]), (S_IOERR, 1));
        assert_eq!(run(&block, &memory, T_FLUSH, 0, vec![]), (S_IOERR, 1));
        assert!(no_room(&io::Error::from_raw_os_error(libc::EDQUOT)), "a quota is no room either");
    }

    /// A pause (a checkpoint) taken while the retrier drains its held writes.
    #[test]
    fn no_held_write_reaches_the_disk_once_a_pause_is_done() {
        use std::sync::atomic::{AtomicBool, Ordering};
        // The test's own gate: the process's is paused by other tests.
        static GATE: Gate = Gate::new();
        /// Full until `room`; the first write once there is room asks for a
        /// pause on another thread (as the daemon's checkpoint does); every
        /// write records whether that pause had already returned.
        struct Pausing {
            room: AtomicBool,
            asked: AtomicBool,
            paused: Arc<AtomicBool>,
            writes: Mutex<Vec<(u64, bool)>>,
        }
        impl Disk for Arc<Pausing> {
            fn size(&self) -> u64 {
                64 << 10
            }
            fn read_only(&self) -> bool {
                false
            }
            fn read_at(&self, buf: &mut [u8], _: u64) -> io::Result<()> {
                buf.fill(0);
                Ok(())
            }
            fn write_at(&self, _: &[u8], offset: u64) -> io::Result<()> {
                if !self.room.load(Ordering::SeqCst) {
                    return Err(io::Error::from_raw_os_error(libc::ENOSPC));
                }
                if !self.asked.swap(true, Ordering::SeqCst) {
                    let paused = self.paused.clone();
                    std::thread::spawn(move || {
                        assert_eq!(GATE.pause(Duration::from_secs(5)), Ok(true));
                        paused.store(true, Ordering::SeqCst);
                    });
                } else {
                    // Give the pause its chance to finish before this write.
                    let deadline = Instant::now() + Duration::from_millis(200);
                    while !self.paused.load(Ordering::SeqCst) && Instant::now() < deadline {
                        std::thread::sleep(Duration::from_millis(5));
                    }
                }
                self.writes.lock().unwrap().push((offset, self.paused.load(Ordering::SeqCst)));
                Ok(())
            }
            fn flush(&self) -> io::Result<()> {
                Ok(())
            }
        }
        let disk = Arc::new(Pausing { room: AtomicBool::new(false), asked: AtomicBool::new(false),
                                      paused: Arc::new(AtomicBool::new(false)), writes: Mutex::new(Vec::new()) });
        let memory = Arc::new(GuestMemory::new(GuestRegion::new(RAM, 1 << 20).unwrap()));
        let mut block = Block::new(Box::new(disk.clone()), "test").on_gate(&GATE);
        block.activate(memory.clone(), vec![Ring::queue()], Interrupt::new(|_| {}), 0);
        let mut ring = Ring { next_descriptor: 0, next_available: 0 };
        for i in 0..4u64 {
            ring.publish(&memory, RAM + 0x20000 + i * 0x1000, T_OUT, i, readable(RAM + 0x3000, 512));
        }
        block.notify(0);
        assert!(Ring::used(&memory).is_empty(), "all four wait for room");
        disk.room.store(true, Ordering::SeqCst);
        // The pause is done (the daemon would now clone the disks) ...
        assert!(eventually(|| disk.paused.load(Ordering::SeqCst)));
        std::thread::sleep(Duration::from_millis(500));
        let writes = disk.writes.lock().unwrap().clone();
        GATE.resume();
        // ... and every held write still goes through once Android resumes.
        assert!(eventually(|| disk.writes.lock().unwrap().len() == 4));
        assert!(eventually(|| Ring::used(&memory).len() == 4));
        let after_pause: Vec<u64> = writes.iter().filter(|w| w.1).map(|w| w.0).collect();
        assert!(after_pause.is_empty(), "held writes reached the disk while paused (byte offsets {after_pause:?}; all: {writes:?})");
    }

    #[test]
    fn the_last_disk_full_report_is_on_while_a_write_waits() {
        let (block, disk, memory) = device(64 << 10, vec![0; 64 << 10]);
        let heard = Arc::new(Mutex::new(Vec::new()));
        let reports = heard.clone();
        // The retrier's thread is slow to say "off" (an eprintln! and the
        // daemon's event queue stand there in the real code).
        let mut block = block.on_full(Box::new(move |full| {
            if !full {
                std::thread::sleep(Duration::from_millis(100));
            }
            reports.lock().unwrap().push(full);
        }));
        let memory = Arc::new(memory);
        block.activate(memory.clone(), vec![Ring::queue()], Interrupt::new(|_| {}), 0);
        let mut ring = Ring { next_descriptor: 0, next_available: 0 };
        disk.0.lock().unwrap().full = true;
        ring.publish(&memory, RAM + 0x20000, T_OUT, 0, readable(RAM + 0x3000, 512));
        block.notify(0);
        disk.0.lock().unwrap().full = false;
        assert!(eventually(|| !block.shared.state.lock().unwrap().retrying), "the first episode ends");
        // The Mac's disk fills again at once (it was at the edge of full).
        disk.0.lock().unwrap().full = true;
        ring.publish(&memory, RAM + 0x21000, T_OUT, 8, readable(RAM + 0x3000, 512));
        block.notify(0);
        std::thread::sleep(Duration::from_millis(300));
        let waiting = block.shared.state.lock().unwrap().waiting.len();
        let heard = heard.lock().unwrap().clone();
        assert_eq!(waiting, 1, "the second write waits for room");
        assert_eq!(heard, [true, false, true], "the last word must be 'disk full on' while a write waits");
        disk.0.lock().unwrap().full = false;
        assert!(eventually(|| !block.shared.state.lock().unwrap().retrying), "the second episode ends");
    }
}
