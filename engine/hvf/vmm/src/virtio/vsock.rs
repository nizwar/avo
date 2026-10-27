//! virtio-vsock (virtio 1.2 §5.10) with Firecracker-style "hybrid" host
//! sockets, the contract in docs/engine.md:
//!
//! - Host to guest: connect to the Unix socket `<path>`, write
//!   `CONNECT <port>\n`, read `OK <host port>\n`; the stream is raw after that.
//! - Guest to host port N: the device connects to the Unix socket `<path>_N`.
//!
//! macOS has no AF_VSOCK, so this is the whole transport.

use super::queue::Queue;
use super::{Active, Interrupt, VirtioDevice};
use crate::memory::GuestMemory;
use std::collections::{HashMap, VecDeque};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

pub const TYPE_VSOCK: u16 = 19;
pub const HOST_CID: u64 = 2;

const RX: usize = 0;
const TX: usize = 1;
const HEADER: usize = 44;

const OP_REQUEST: u16 = 1;
const OP_RESPONSE: u16 = 2;
const OP_RST: u16 = 3;
const OP_SHUTDOWN: u16 = 4;
const OP_RW: u16 = 5;
const OP_CREDIT_UPDATE: u16 = 6;
const OP_CREDIT_REQUEST: u16 = 7;
const TYPE_STREAM: u16 = 1;

/// Receive buffer each host-side connection offers the guest.
const HOST_BUFFER: u32 = 256 * 1024;

/// Most connections the guest may have open to the Mac's services at once.
/// Each costs a thread and descriptors here, and as much in the service
/// (the modem, the daemon's), and any app can open them (AF_VSOCK to CID 2;
/// SELinux is permissive): past the cap the guest is refused (RST) instead
/// of the engine running out of threads. Android itself keeps a few.
const MAX_GUEST_CONNECTIONS: usize = 256;

#[derive(Clone, Copy, Default)]
struct Header {
    src_cid: u64,
    dst_cid: u64,
    src_port: u32,
    dst_port: u32,
    len: u32,
    kind: u16,
    op: u16,
    flags: u32,
    buf_alloc: u32,
    fwd_cnt: u32,
}

impl Header {
    fn parse(b: &[u8]) -> Header {
        let u64_at = |i: usize| u64::from_le_bytes(b[i..i + 8].try_into().unwrap());
        let u32_at = |i: usize| u32::from_le_bytes(b[i..i + 4].try_into().unwrap());
        let u16_at = |i: usize| u16::from_le_bytes(b[i..i + 2].try_into().unwrap());
        Header {
            src_cid: u64_at(0),
            dst_cid: u64_at(8),
            src_port: u32_at(16),
            dst_port: u32_at(20),
            len: u32_at(24),
            kind: u16_at(28),
            op: u16_at(30),
            flags: u32_at(32),
            buf_alloc: u32_at(36),
            fwd_cnt: u32_at(40),
        }
    }

    fn bytes(&self) -> [u8; HEADER] {
        let mut b = [0u8; HEADER];
        b[0..8].copy_from_slice(&self.src_cid.to_le_bytes());
        b[8..16].copy_from_slice(&self.dst_cid.to_le_bytes());
        b[16..20].copy_from_slice(&self.src_port.to_le_bytes());
        b[20..24].copy_from_slice(&self.dst_port.to_le_bytes());
        b[24..28].copy_from_slice(&self.len.to_le_bytes());
        b[28..30].copy_from_slice(&self.kind.to_le_bytes());
        b[30..32].copy_from_slice(&self.op.to_le_bytes());
        b[32..36].copy_from_slice(&self.flags.to_le_bytes());
        b[36..40].copy_from_slice(&self.buf_alloc.to_le_bytes());
        b[40..44].copy_from_slice(&self.fwd_cnt.to_le_bytes());
        b
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
struct Key {
    host_port: u32,
    guest_port: u32,
}

#[derive(PartialEq, Eq)]
enum Phase {
    /// Host asked the guest to connect; waiting for RESPONSE.
    Connecting,
    Connected,
}

struct Connection {
    phase: Phase,
    stream: UnixStream,
    /// Bytes delivered to the host stream (our fwd_cnt).
    forwarded: u32,
    /// fwd_cnt we last told the guest about.
    reported: u32,
    /// Bytes sent to the guest (our tx_cnt) and the guest's credit.
    sent: u32,
    peer_buffer: u32,
    peer_forwarded: u32,
    /// What the guest sent that the host stream has not taken yet (its
    /// reader is slow): at most HOST_BUFFER, the credit the guest has.
    backlog: VecDeque<u8>,
    /// A `drain` thread is writing the backlog out.
    draining: bool,
    /// SHUTDOWN flags the guest sent meanwhile, carried out after it.
    ending: u32,
    /// Tells this connection from a later one on the same ports.
    serial: u64,
    /// The guest opened it (OP_REQUEST): it counts toward the guest's cap.
    from_guest: bool,
}

impl Connection {
    fn new(phase: Phase, stream: UnixStream) -> Connection {
        static SERIAL: AtomicU64 = AtomicU64::new(1);
        // Writes come from vCPUs, which must never wait for the host's
        // reader; the pump and drain threads poll instead (`wait_for`).
        // macOS ignores MSG_DONTWAIT on these sockets.
        let _ = stream.set_nonblocking(true);
        Connection {
            phase,
            stream,
            forwarded: 0,
            reported: 0,
            sent: 0,
            peer_buffer: 0,
            peer_forwarded: 0,
            backlog: VecDeque::new(),
            draining: false,
            ending: 0,
            serial: SERIAL.fetch_add(1, Ordering::Relaxed),
            from_guest: false,
        }
    }

    fn credit(&self) -> u32 {
        self.peer_buffer.saturating_sub(self.sent.wrapping_sub(self.peer_forwarded))
    }
}

struct State {
    guest_cid: u64,
    socket_path: PathBuf,
    active: Option<Active>,
    connections: HashMap<Key, Connection>,
    /// Packets waiting for receive buffers.
    pending: VecDeque<(Header, Vec<u8>)>,
    next_port: u32,
    /// Most connections the guest may open at once (MAX_GUEST_CONNECTIONS).
    guest_limit: usize,
    /// The log said the guest reached its cap.
    refused: bool,
}

struct Shared {
    state: Mutex<State>,
    /// Signalled when the guest returns credit or a connection changes.
    changed: Condvar,
}

pub struct Vsock {
    shared: Arc<Shared>,
}

/// The device of the machine that runs now. The socket is the process's: a
/// guest reboot hands it the new machine's device instead of leaving a
/// thread that waits for clients on the old one's socket, which none reach.
static CURRENT: Mutex<Option<Arc<Shared>>> = Mutex::new(None);

impl Vsock {
    /// Serves host connections on `socket_path` (created the first time,
    /// replacing any old one; a guest reboot keeps it).
    pub fn new(guest_cid: u64, socket_path: &Path) -> std::io::Result<Vsock> {
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                guest_cid,
                socket_path: socket_path.to_path_buf(),
                active: None,
                connections: HashMap::new(),
                pending: VecDeque::new(),
                next_port: 1024,
                guest_limit: MAX_GUEST_CONNECTIONS,
                refused: false,
            }),
            changed: Condvar::new(),
        });
        let mut current = CURRENT.lock().unwrap();
        if current.is_none() {
            let _ = std::fs::remove_file(socket_path);
            let listener = UnixListener::bind(socket_path)?;
            std::thread::Builder::new()
                .name("vsock-accept".into())
                .spawn(move || {
                    for stream in listener.incoming() {
                        let stream = match stream {
                            Ok(stream) => stream,
                            // Back off instead of spinning when the fd table is full.
                            Err(_) => {
                                std::thread::sleep(Duration::from_millis(100));
                                continue;
                            }
                        };
                        let Some(shared) = CURRENT.lock().unwrap().clone() else { continue };
                        // No thread to be had: the client's stream closes.
                        let _ = spawn("vsock-connect", move || host_connect(shared, stream));
                    }
                })?;
        }
        *current = Some(shared.clone());
        Ok(Vsock { shared })
    }
}

/// Starts one of a connection's threads. When the process has no thread to
/// give (at its limit), the caller answers that (RST, a closed stream)
/// instead of the engine panicking.
fn spawn(name: &str, body: impl FnOnce() + Send + 'static) -> std::io::Result<()> {
    std::thread::Builder::new().name(name.into()).spawn(body).map(|_| ())
}

/// A host client asked for a guest port.
fn host_connect(shared: Arc<Shared>, stream: UnixStream) {
    // The CONNECT line is short; bound the wait and the length so a client
    // that never sends a newline cannot hold the thread or grow the buffer
    // (the stream becomes non-blocking once connected, so this timeout is
    // only for the handshake).
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let clone = match stream.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    };
    let mut reader = BufReader::new(clone.take(256));
    let mut line = String::new();
    if reader.read_line(&mut line).is_err() {
        return;
    }
    let Some(port) = line.trim().strip_prefix("CONNECT ").and_then(|p| p.trim().parse::<u32>().ok()) else {
        let _ = (&stream).write_all(b"ERROR bad request\n");
        return;
    };
    let mut state = shared.state.lock().unwrap();
    let host_port = state.next_port;
    state.next_port = state.next_port.wrapping_add(1).max(1024);
    let key = Key { host_port, guest_port: port };
    state.connections.insert(key, Connection::new(Phase::Connecting, stream));
    let header = control(&state, key, OP_REQUEST);
    state.pending.push_back((header, Vec::new()));
    flush(&mut state);
}

fn control(state: &State, key: Key, op: u16) -> Header {
    let forwarded = state.connections.get(&key).map(|c| c.forwarded).unwrap_or(0);
    Header {
        src_cid: HOST_CID,
        dst_cid: state.guest_cid,
        src_port: key.host_port,
        dst_port: key.guest_port,
        kind: TYPE_STREAM,
        op,
        buf_alloc: HOST_BUFFER,
        fwd_cnt: forwarded,
        ..Header::default()
    }
}

/// `n` more of the guest's bytes reached the host stream: the guest hears
/// of it once a quarter of its credit has come back.
fn forwarded(state: &mut State, key: Key, n: usize) {
    let Some(connection) = state.connections.get_mut(&key) else { return };
    connection.forwarded = connection.forwarded.wrapping_add(n as u32);
    if connection.forwarded.wrapping_sub(connection.reported) >= HOST_BUFFER / 4 {
        connection.reported = connection.forwarded;
        let update = control(state, key, OP_CREDIT_UPDATE);
        state.pending.push_back((update, Vec::new()));
    }
}

/// Carries out the guest's SHUTDOWN `flags` on the host stream.
fn end(state: &mut State, key: Key, flags: u32) {
    let Some(connection) = state.connections.get(&key) else { return };
    if flags & 2 != 0 {
        let _ = connection.stream.shutdown(Shutdown::Write);
    }
    if flags & 3 == 3 {
        let _ = connection.stream.shutdown(Shutdown::Both);
        state.connections.remove(&key);
        let rst = control(state, key, OP_RST);
        state.pending.push_back((rst, Vec::new()));
    }
}

/// Writes as much of `data` as the (non-blocking) host stream takes now.
fn send_now(mut stream: &UnixStream, data: &[u8]) -> std::io::Result<usize> {
    let mut sent = 0;
    while sent < data.len() {
        match stream.write(&data[sent..]) {
            Ok(0) => break,
            Ok(n) => sent += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            // Full, or macOS short of socket buffers (ENOBUFS): later.
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.raw_os_error() == Some(libc::ENOBUFS) => break,
            Err(e) => return Err(e),
        }
    }
    Ok(sent)
}

/// Waits until the stream can be read (POLLIN) or written (POLLOUT), or
/// has hung up, for at most `ms` (-1: no limit).
fn wait_for(stream: &UnixStream, events: i16, ms: i32) {
    let mut fd = libc::pollfd { fd: stream.as_raw_fd(), events, revents: 0 };
    unsafe { libc::poll(&mut fd, 1, ms) };
}

/// The connection `serial` names, if it is still there.
fn live(state: &mut State, key: Key, serial: u64) -> Option<&mut Connection> {
    state.connections.get_mut(&key).filter(|c| c.serial == serial)
}

/// The guest's connections to the Mac's services open now.
fn guest_connections(state: &State) -> usize {
    state.connections.values().filter(|c| c.from_guest).count()
}

/// Writes a connection's backlog to its host stream on a thread of its own,
/// so a host that reads slowly holds up only this connection, and returns
/// the guest's credit as the bytes go out. Ends with the backlog, then
/// carries out a SHUTDOWN that came meanwhile.
fn drain(shared: Arc<Shared>, key: Key, serial: u64, mut stream: UnixStream) {
    let mut chunk = Vec::new();
    loop {
        {
            let mut state = shared.state.lock().unwrap();
            let Some(connection) = live(&mut state, key, serial) else { return };
            if connection.backlog.is_empty() {
                connection.draining = false;
                let ending = connection.ending;
                end(&mut state, key, ending);
                flush(&mut state);
                return;
            }
            let take = connection.backlog.len().min(64 * 1024);
            chunk.clear();
            chunk.extend(connection.backlog.range(..take));
        }
        let mut sent = 0;
        let mut failed = false;
        while sent < chunk.len() && !failed {
            match stream.write(&chunk[sent..]) {
                Ok(0) => failed = true,
                Ok(n) => sent += n,
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                // A connection that goes is shut down, which ends the wait.
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => wait_for(&stream, libc::POLLOUT, 1000),
                // A shortage of socket buffers passes; the connection may not.
                Err(e) if e.raw_os_error() == Some(libc::ENOBUFS) => {
                    if live(&mut shared.state.lock().unwrap(), key, serial).is_none() {
                        return;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
                Err(_) => failed = true,
            }
        }
        let mut state = shared.state.lock().unwrap();
        let Some(connection) = live(&mut state, key, serial) else { return };
        if failed {
            let _ = connection.stream.shutdown(Shutdown::Both);
            state.connections.remove(&key);
            let rst = control(&state, key, OP_RST);
            state.pending.push_back((rst, Vec::new()));
        } else {
            connection.backlog.drain(..sent);
            forwarded(&mut state, key, sent);
        }
        flush(&mut state);
        if failed {
            return;
        }
    }
}

/// Moves pending packets into guest receive buffers.
fn flush(state: &mut State) {
    let Some(active) = state.active.as_mut() else { return };
    let mut delivered = false;
    while let Some((header, payload)) = state.pending.front() {
        let Some(chain) = active.queues[RX].pop(&active.memory) else { break };
        let room = chain.writable_len();
        if room < HEADER {
            active.queues[RX].add_used(&active.memory, chain.head, 0);
            continue;
        }
        let mut header = *header;
        let take = payload.len().min(room - HEADER);
        header.len = take as u32;
        let mut packet = header.bytes().to_vec();
        packet.extend_from_slice(&payload[..take]);
        let written = chain.write_all(&active.memory, &packet);
        active.queues[RX].add_used(&active.memory, chain.head, written as u32);
        delivered = true;
        if take == payload.len() {
            state.pending.pop_front();
        } else {
            let rest = payload[take..].to_vec();
            state.pending.front_mut().unwrap().1 = rest;
        }
    }
    if delivered {
        active.interrupt.signal_queue();
    }
}

/// Copies host stream data to the guest within the guest's credit, for the
/// connection `serial` names: it ends with that connection, even when a later
/// one takes the same ports.
fn pump(shared: Arc<Shared>, key: Key, serial: u64, mut stream: UnixStream) {
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        // Wait for credit before reading, so the host side sees backpressure.
        let credit = {
            let mut state = shared.state.lock().unwrap();
            loop {
                match state.connections.get(&key).filter(|c| c.serial == serial) {
                    None => return,
                    Some(c) if c.credit() > 0 => break c.credit() as usize,
                    Some(_) => state = shared.changed.wait(state).unwrap(),
                }
            }
        };
        let limit = credit.min(buffer.len());
        // The stream is non-blocking (Connection::new): wait for data, or
        // for the hang-up that a connection's end brings.
        let read = loop {
            match stream.read(&mut buffer[..limit]) {
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => wait_for(&stream, libc::POLLIN, -1),
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                other => break other,
            }
        };
        let n = match read {
            Ok(0) | Err(_) => {
                let mut state = shared.state.lock().unwrap();
                if live(&mut state, key, serial).is_some() {
                    let mut header = control(&state, key, OP_SHUTDOWN);
                    header.flags = 3; // no more sending or receiving from the host side
                    state.pending.push_back((header, Vec::new()));
                    flush(&mut state);
                }
                return;
            }
            Ok(n) => n,
        };
        let mut state = shared.state.lock().unwrap();
        let Some(connection) = live(&mut state, key, serial) else { return };
        connection.sent = connection.sent.wrapping_add(n as u32);
        let header = control(&state, key, OP_RW);
        state.pending.push_back((header, buffer[..n].to_vec()));
        flush(&mut state);
    }
}

impl Shared {
    fn transmit(self: &Arc<Self>) {
        let mut state = self.state.lock().unwrap();
        let Some(mut active) = state.active.take() else { return };
        let mut packets = Vec::new();
        while let Some(chain) = active.queues[TX].pop(&active.memory) {
            if let Some(bytes) = chain.read_all(&active.memory) {
                if bytes.len() >= HEADER {
                    packets.push((Header::parse(&bytes[..HEADER]), bytes[HEADER..].to_vec()));
                }
            }
            active.queues[TX].add_used(&active.memory, chain.head, 0);
        }
        active.interrupt.signal_queue();
        state.active = Some(active);
        for (header, payload) in packets {
            self.packet(&mut state, header, payload);
        }
        flush(&mut state);
        self.changed.notify_all();
    }

    fn packet(self: &Arc<Self>, state: &mut State, header: Header, payload: Vec<u8>) {
        if header.dst_cid != HOST_CID || header.kind != TYPE_STREAM {
            return;
        }
        let key = Key { host_port: header.dst_port, guest_port: header.src_port };
        let reset = |state: &mut State| {
            let rst = control(state, key, OP_RST);
            state.pending.push_back((rst, Vec::new()));
        };
        if let Some(connection) = state.connections.get_mut(&key) {
            connection.peer_buffer = header.buf_alloc;
            connection.peer_forwarded = header.fwd_cnt;
        }
        match header.op {
            OP_REQUEST => {
                // The guest opens its ports again: the connection it had on
                // them is over (its pump ends with the shutdown).
                if let Some(old) = state.connections.remove(&key) {
                    let _ = old.stream.shutdown(Shutdown::Both);
                }
                if guest_connections(state) >= state.guest_limit {
                    if !std::mem::replace(&mut state.refused, true) {
                        eprintln!("[vmm] vsock: the guest has {} connections to the Mac open; refusing more", state.guest_limit);
                    }
                    return reset(state);
                }
                // The guest connects to a host service: <socket>_<port>.
                let path = PathBuf::from(format!("{}_{}", state.socket_path.display(), header.dst_port));
                let Ok(stream) = UnixStream::connect(&path) else { return reset(state) };
                let Ok(reader) = stream.try_clone() else { return reset(state) };
                let connection = Connection {
                    peer_buffer: header.buf_alloc,
                    peer_forwarded: header.fwd_cnt,
                    from_guest: true,
                    ..Connection::new(Phase::Connected, stream)
                };
                // The pump waits for this lock: it finds the connection in place.
                let (shared, serial) = (self.clone(), connection.serial);
                if spawn("vsock-pump", move || pump(shared, key, serial, reader)).is_err() {
                    return reset(state); // the connection's stream closes with it
                }
                state.connections.insert(key, connection);
                let response = control(state, key, OP_RESPONSE);
                state.pending.push_back((response, Vec::new()));
            }
            OP_RESPONSE => {
                let Some(connection) = state.connections.get_mut(&key) else { return reset(state) };
                if connection.phase == Phase::Connecting {
                    let (shared, serial) = (self.clone(), connection.serial);
                    let pumping =
                        connection.stream.try_clone().and_then(|reader| spawn("vsock-pump", move || pump(shared, key, serial, reader)));
                    if pumping.is_err() {
                        let _ = (&connection.stream).write_all(b"ERROR no thread for the connection\n");
                        let _ = connection.stream.shutdown(Shutdown::Both);
                        state.connections.remove(&key);
                        return reset(state);
                    }
                    connection.phase = Phase::Connected;
                    let _ = connection.stream.write_all(format!("OK {}\n", key.host_port).as_bytes());
                }
            }
            OP_RW => {
                let Some(connection) = state.connections.get_mut(&key) else { return reset(state) };
                // Never waits for the host's reader (this is a vCPU, and it
                // holds every connection's lock): what the stream does not
                // take now waits in the backlog. The guest sends only within
                // its credit; one that sends more is broken.
                let written = if connection.backlog.len() + payload.len() > HOST_BUFFER as usize {
                    Err(std::io::ErrorKind::InvalidData.into())
                } else if connection.backlog.is_empty() {
                    send_now(&connection.stream, &payload)
                } else {
                    Ok(0)
                };
                let queued = written.and_then(|n| {
                    if n < payload.len() && !connection.draining {
                        let stream = connection.stream.try_clone()?;
                        let (shared, serial) = (self.clone(), connection.serial);
                        spawn("vsock-drain", move || drain(shared, key, serial, stream))?;
                        connection.draining = true;
                    }
                    Ok(n)
                });
                let Ok(written) = queued else {
                    let _ = connection.stream.shutdown(Shutdown::Both);
                    state.connections.remove(&key);
                    return reset(state);
                };
                connection.backlog.extend(&payload[written..]);
                forwarded(state, key, written);
            }
            OP_CREDIT_REQUEST => {
                if state.connections.contains_key(&key) {
                    let update = control(state, key, OP_CREDIT_UPDATE);
                    state.pending.push_back((update, Vec::new()));
                }
            }
            OP_CREDIT_UPDATE => {}
            OP_SHUTDOWN => {
                let Some(connection) = state.connections.get_mut(&key) else { return };
                // What the guest sent before reaches the host first.
                if connection.draining {
                    connection.ending |= header.flags & 3;
                } else {
                    end(state, key, header.flags);
                }
            }
            OP_RST => {
                if let Some(connection) = state.connections.remove(&key) {
                    if connection.phase == Phase::Connecting {
                        let _ = (&connection.stream).write_all(b"ERROR connection refused\n");
                    }
                    let _ = connection.stream.shutdown(Shutdown::Both);
                }
            }
            _ => {}
        }
    }
}

impl VirtioDevice for Vsock {
    fn device_type(&self) -> u16 {
        TYPE_VSOCK
    }

    fn features(&self) -> u64 {
        0
    }

    fn queue_sizes(&self) -> Vec<u16> {
        vec![256, 256, 16]
    }

    fn config(&self) -> Vec<u8> {
        self.shared.state.lock().unwrap().guest_cid.to_le_bytes().to_vec()
    }

    fn activate(&mut self, memory: Arc<GuestMemory>, queues: Vec<Queue>, interrupt: Interrupt, _features: u64) {
        let mut state = self.shared.state.lock().unwrap();
        state.active = Some(Active { memory, queues, interrupt });
        flush(&mut state);
    }

    fn notify(&mut self, queue: usize) {
        match queue {
            TX => self.shared.transmit(),
            RX => flush(&mut self.shared.state.lock().unwrap()),
            _ => {}
        }
    }

    fn reset(&mut self) {
        let mut state = self.shared.state.lock().unwrap();
        state.active = None;
        for (_, connection) in state.connections.drain() {
            let _ = connection.stream.shutdown(Shutdown::Both);
        }
        state.pending.clear();
        self.shared.changed.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn until(done: impl Fn() -> bool) -> bool {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !done() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        done()
    }

    #[test]
    fn a_reboot_keeps_the_socket_and_lets_go_of_the_old_device() {
        let path = std::env::temp_dir().join(format!("avo-vsock-{}.sock", std::process::id()));
        let connections = |vsock: &Vsock| vsock.shared.state.lock().unwrap().connections.len();
        let ask = || {
            let mut stream = UnixStream::connect(&path).unwrap();
            stream.write_all(b"CONNECT 5555\n").unwrap();
            stream
        };
        let first = Vsock::new(3, &path).unwrap();
        let _early = ask();
        assert!(until(|| connections(&first) == 1));
        let second = Vsock::new(3, &path).unwrap();
        assert!(until(|| Arc::strong_count(&first.shared) == 1), "nothing but the old device keeps its state");
        let _late = ask();
        assert!(until(|| connections(&second) == 1), "the next machine's device gets new clients");
        assert_eq!(connections(&first), 1);
        let _ = std::fs::remove_file(&path);
    }

    /// A device with one connected host client, and the client's end.
    fn connected() -> (Arc<Shared>, Key, UnixStream) {
        let state = State {
            guest_cid: 3,
            socket_path: PathBuf::new(),
            active: None,
            connections: HashMap::new(),
            pending: VecDeque::new(),
            next_port: 1024,
            guest_limit: MAX_GUEST_CONNECTIONS,
            refused: false,
        };
        let shared = Arc::new(Shared { state: Mutex::new(state), changed: Condvar::new() });
        let (ours, theirs) = UnixStream::pair().unwrap();
        let key = Key { host_port: 1024, guest_port: 5555 };
        shared.state.lock().unwrap().connections.insert(key, Connection::new(Phase::Connected, ours));
        theirs.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        (shared, key, theirs)
    }

    /// The guest sends a packet on `key`, as the TX queue hands it over.
    fn from_guest(shared: &Arc<Shared>, key: Key, op: u16, flags: u32, payload: &[u8]) {
        let header = Header {
            src_cid: 3,
            dst_cid: HOST_CID,
            src_port: key.guest_port,
            dst_port: key.host_port,
            kind: TYPE_STREAM,
            op,
            flags,
            buf_alloc: HOST_BUFFER,
            ..Header::default()
        };
        shared.packet(&mut shared.state.lock().unwrap(), header, payload.to_vec());
    }

    #[test]
    fn a_host_that_reads_slowly_holds_up_only_its_own_connection() {
        let (shared, key, mut theirs) = connected();
        let data: Vec<u8> = (0..HOST_BUFFER as usize).map(|i| (i % 251) as u8).collect();
        // All of its credit, far more than the socket holds, while nobody reads.
        let (sender, packets) = (shared.clone(), data.clone());
        let (done, sent) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for packet in packets.chunks(4096) {
                from_guest(&sender, key, OP_RW, 0, packet);
            }
            done.send(()).unwrap();
        });
        sent.recv_timeout(Duration::from_secs(5)).expect("a packet waited for the host's reader");
        {
            let state = shared.state.lock().unwrap();
            let connection = &state.connections[&key];
            assert!(!connection.backlog.is_empty(), "the rest waits for the reader");
            assert_eq!(connection.backlog.len() + connection.forwarded as usize, data.len(), "credit comes back as bytes go out");
        }
        let mut received = vec![0u8; data.len()];
        theirs.read_exact(&mut received).unwrap();
        assert!(received == data, "everything, in order");
        assert!(until(|| shared.state.lock().unwrap().connections[&key].forwarded as usize == data.len()));
        let state = shared.state.lock().unwrap();
        assert!(state.connections[&key].backlog.is_empty() && !state.connections[&key].draining);
        assert!(state.pending.iter().any(|(header, _)| header.op == OP_CREDIT_UPDATE), "the guest hears of its credit");
    }

    #[test]
    fn a_guest_that_sends_past_its_credit_is_reset() {
        let (shared, key, _theirs) = connected();
        for _ in 0..64 {
            from_guest(&shared, key, OP_RW, 0, &[0; 64 * 1024]);
            let state = shared.state.lock().unwrap();
            match state.connections.get(&key) {
                Some(connection) => assert!(connection.backlog.len() <= HOST_BUFFER as usize),
                None => {
                    assert!(state.pending.iter().any(|(header, _)| header.op == OP_RST));
                    return;
                }
            }
        }
        panic!("the guest went on sending past its credit");
    }

    #[test]
    fn the_guests_shutdown_waits_for_what_it_sent_before() {
        let (shared, key, mut theirs) = connected();
        let data = vec![7u8; 200 * 1024];
        from_guest(&shared, key, OP_RW, 0, &data);
        let waited = shared.state.lock().unwrap().connections[&key].draining;
        from_guest(&shared, key, OP_SHUTDOWN, 3, &[]);
        if waited {
            assert!(shared.state.lock().unwrap().connections.contains_key(&key), "kept until its data is out");
        }
        let mut received = Vec::new();
        theirs.read_to_end(&mut received).unwrap();
        assert_eq!(received.len(), data.len(), "everything, then the end");
        assert!(until(|| !shared.state.lock().unwrap().connections.contains_key(&key)));
        assert!(shared.state.lock().unwrap().pending.iter().any(|(header, _)| header.op == OP_RST));
    }

    #[test]
    fn the_pump_waits_for_host_data_and_ends_with_the_host() {
        let (shared, key, mut theirs) = connected();
        let (reader, serial) = {
            let mut state = shared.state.lock().unwrap();
            let connection = state.connections.get_mut(&key).unwrap();
            connection.peer_buffer = HOST_BUFFER;
            (connection.stream.try_clone().unwrap(), connection.serial)
        };
        let pumping = {
            let shared = shared.clone();
            std::thread::spawn(move || pump(shared, key, serial, reader))
        };
        let sent = |op: u16, payload: &[u8]| {
            shared.state.lock().unwrap().pending.iter().any(|(header, data)| header.op == op && data == payload)
        };
        std::thread::sleep(Duration::from_millis(100));
        assert!(!pumping.is_finished(), "waits on a host that has sent nothing");
        theirs.write_all(b"hello").unwrap();
        assert!(until(|| sent(OP_RW, b"hello")));
        drop(theirs);
        assert!(until(|| pumping.is_finished()), "ends when the host hangs up");
        assert!(sent(OP_SHUTDOWN, b""));
    }

    /// A device whose guest connects to the Mac's services beside `socket`,
    /// with at most `limit` connections at once.
    fn device(socket: &Path, limit: usize) -> Arc<Shared> {
        let state = State {
            guest_cid: 3,
            socket_path: socket.to_path_buf(),
            active: None,
            connections: HashMap::new(),
            pending: VecDeque::new(),
            next_port: 1024,
            guest_limit: limit,
            refused: false,
        };
        Arc::new(Shared { state: Mutex::new(state), changed: Condvar::new() })
    }

    /// What the guest was told on `key`, in order.
    fn told(shared: &Arc<Shared>, key: Key) -> Vec<u16> {
        let state = shared.state.lock().unwrap();
        state.pending.iter().filter(|(h, _)| (h.src_port, h.dst_port) == (key.host_port, key.guest_port)).map(|(h, _)| h.op).collect()
    }

    /// Ends every connection, so their pumps end with the test.
    fn close_all(shared: &Arc<Shared>) {
        for (_, connection) in shared.state.lock().unwrap().connections.drain() {
            let _ = connection.stream.shutdown(Shutdown::Both);
        }
    }

    /// A host service beside `socket` on `port` (the modem's, say).
    fn service(socket: &Path, port: u32) -> (UnixListener, PathBuf) {
        let path = PathBuf::from(format!("{}_{port}", socket.display()));
        let _ = std::fs::remove_file(&path);
        (UnixListener::bind(&path).unwrap(), path)
    }

    #[test]
    fn a_guest_past_its_connection_cap_is_refused() {
        let socket = std::env::temp_dir().join(format!("avo-vsock-cap-{}.sock", std::process::id()));
        // A service that takes connections and never answers: each stays open.
        let (_listener, path) = service(&socket, 9600);
        let shared = device(&socket, 4);
        let key = |port: u32| Key { host_port: 9600, guest_port: 40000 + port };
        for port in 0..5 {
            from_guest(&shared, key(port), OP_REQUEST, 0, &[]);
        }
        assert_eq!(guest_connections(&shared.state.lock().unwrap()), 4);
        for port in 0..4 {
            assert_eq!(told(&shared, key(port)), [OP_RESPONSE], "connection {port} is made");
        }
        assert_eq!(told(&shared, key(4)), [OP_RST], "the fifth is refused, with no connection to the service");
        // One ends: there is room for the next.
        from_guest(&shared, key(0), OP_RST, 0, &[]);
        from_guest(&shared, key(5), OP_REQUEST, 0, &[]);
        assert_eq!(told(&shared, key(5)), [OP_RESPONSE]);
        close_all(&shared);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_guest_connection_made_again_on_its_ports_ends_the_old_one() {
        let socket = std::env::temp_dir().join(format!("avo-vsock-again-{}.sock", std::process::id()));
        let (listener, path) = service(&socket, 9601);
        let shared = device(&socket, 4);
        let key = Key { host_port: 9601, guest_port: 40000 };
        from_guest(&shared, key, OP_REQUEST, 0, &[]);
        let (mut first, _) = listener.accept().unwrap();
        first.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        // Its pump now waits for the service to send.
        std::thread::sleep(Duration::from_millis(100));
        from_guest(&shared, key, OP_REQUEST, 0, &[]);
        let (_second, _) = listener.accept().unwrap();
        // The service hears the old connection end, and its pump ends with it
        // (a thread for each time would be left waiting otherwise) ...
        let mut rest = Vec::new();
        assert!(first.read_to_end(&mut rest).is_ok(), "the old connection is shut down, not left open");
        // ... without ending the new one.
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(guest_connections(&shared.state.lock().unwrap()), 1);
        assert_eq!(told(&shared, key), [OP_RESPONSE, OP_RESPONSE], "no SHUTDOWN for the new connection");
        close_all(&shared);
        let _ = std::fs::remove_file(&path);
    }
}
