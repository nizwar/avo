//! Bluetooth: Cuttlefish's HCI HAL (`bt_hci`, android.hardware.bluetooth-
//! service.cuttlefish) speaks H4 on /dev/hvc5, where Cuttlefish's host runs
//! Root Canal, a virtual controller. avo-vmm starts netsimd from the Android
//! Emulator (`--bluetooth`; Root Canal inside) and passes the bytes both ways
//! between hvc5 and netsimd's HCI port (H4 over TCP, `--hci-port`), unread:
//! Android's Bluetooth turns on and scans, advertises and connects inside
//! netsim's virtual air. Nothing reaches the Mac's own Bluetooth.
//!
//! netsimd runs once per avo-vmm, through guest reboots (the HAL resets the
//! controller as it starts), with its files under the runtime directory and
//! its log in the instance's netsimd.log. It is killed when avo-vmm ends
//! (`stop`); after a crash it shuts itself down once its device is gone.
//! Guest bytes that come before the connection wait for it, so a packet is
//! never cut in two.
//!
//! The port goes to the daemon (`bluetooth hci <port>`, sticky): each
//! connection to it is another chip in the same air, and the daemon drives
//! one per Bluetooth device the Mac sees, so Android finds and uses those
//! too (MacBluetoothBridge.swift).

use crate::virtio::console::ConsoleInput;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, Shutdown, TcpListener, TcpStream};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Guest bytes kept while netsimd is not connected yet (a reset and the
/// first commands are a few dozen).
const PENDING_LIMIT: usize = 64 * 1024;
/// How long netsimd has to open its HCI port.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Default)]
struct State {
    /// netsimd's HCI port, once connected.
    stream: Option<TcpStream>,
    /// Guest bytes from before the connection.
    pending: Vec<u8>,
    /// Bytes dropped over `PENDING_LIMIT` (reported once).
    dropped: usize,
}

#[derive(Default)]
pub struct Bluetooth {
    /// netsimd's HCI port.
    port: u16,
    state: Mutex<State>,
    /// hvc5's input: where the controller's events go. Each boot connects its own.
    input: Mutex<Option<ConsoleInput>>,
    child: Mutex<Option<Child>>,
}

impl Bluetooth {
    /// Starts `netsimd` and connects to its HCI port in the background.
    pub fn start(netsimd: &Path, runtime: &Path, instance: &Path) -> Result<Arc<Bluetooth>, String> {
        let port = free_port()?;
        let files = runtime.join("netsim");
        std::fs::create_dir_all(&files).map_err(|e| format!("{}: {e}", files.display()))?;
        let log = std::fs::File::create(instance.join("netsimd.log")).map_err(|e| format!("netsimd.log: {e}"))?;
        let child = Command::new(netsimd)
            .args(["--no-cli-ui", "--no-web-ui", "--logtostderr", "--instance", "1", "--hci-port", &port.to_string()])
            // Bluetooth only: Avo's Wi-Fi has its own NAT (net.rs).
            .args(["--debug-no-network", "--debug-no-guest-to-host-mdns"])
            .env("TMPDIR", &files)
            .stdin(Stdio::null())
            .stdout(log.try_clone().map_err(|e| e.to_string())?)
            .stderr(log)
            .spawn()
            .map_err(|e| format!("{}: {e}", netsimd.display()))?;
        let bluetooth = Arc::new(Bluetooth { port, child: Mutex::new(Some(child)), ..Default::default() });
        let connecting = bluetooth.clone();
        std::thread::Builder::new()
            .name("bluetooth".into())
            .spawn(move || connecting.run(port))
            .map_err(|e| e.to_string())?;
        Ok(bluetooth)
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// The console the controller's packets go to (hvc5's input).
    pub fn connect(&self, input: ConsoleInput) {
        *self.input.lock().unwrap() = Some(input);
    }

    /// Guest output on /dev/hvc5.
    pub fn sink(self: &Arc<Self>) -> Box<dyn Write + Send> {
        Box::new(Packets(self.clone()))
    }

    /// Ends netsimd (avo-vmm is leaving).
    pub fn stop(&self) {
        if let Some(stream) = self.state.lock().unwrap().stream.take() {
            let _ = stream.shutdown(Shutdown::Both);
        }
        if let Some(mut child) = self.child.lock().unwrap().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    /// Connects, then passes netsimd's packets to the guest until the connection ends.
    fn run(&self, port: u16) {
        let Some(mut reader) = self.connect_to(port) else { return };
        let mut buffer = [0u8; 4096];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if let Some(input) = self.input.lock().unwrap().as_ref() {
                        input.send(&buffer[..n]);
                    }
                }
            }
        }
        if self.state.lock().unwrap().stream.take().is_some() {
            eprintln!("[vmm] bluetooth: netsimd closed its HCI port; Android's Bluetooth stops answering");
        }
    }

    /// Waits for netsimd's port, then sends what the guest wrote meanwhile.
    fn connect_to(&self, port: u16) -> Option<TcpStream> {
        let deadline = Instant::now() + CONNECT_TIMEOUT;
        loop {
            match TcpStream::connect((Ipv4Addr::LOCALHOST, port)) {
                Ok(stream) => {
                    let _ = stream.set_nodelay(true);
                    let reader = stream.try_clone().ok()?;
                    let mut state = self.state.lock().unwrap();
                    let pending = std::mem::take(&mut state.pending);
                    let mut writer = stream;
                    if writer.write_all(&pending).is_err() {
                        eprintln!("[vmm] bluetooth: netsimd's HCI port closed at once");
                        return None;
                    }
                    state.stream = Some(writer);
                    return Some(reader);
                }
                Err(e) if Instant::now() >= deadline => {
                    eprintln!("[vmm] bluetooth: no netsimd HCI port on {port}: {e}; Android's Bluetooth stays off");
                    return None;
                }
                Err(_) => std::thread::sleep(Duration::from_millis(100)),
            }
        }
    }

    fn guest_wrote(&self, bytes: &[u8]) {
        let mut state = self.state.lock().unwrap();
        if let Some(stream) = state.stream.as_mut() {
            if stream.write_all(bytes).is_err() {
                state.stream = None;
            }
            return;
        }
        let room = PENDING_LIMIT.saturating_sub(state.pending.len());
        state.pending.extend_from_slice(&bytes[..bytes.len().min(room)]);
        if bytes.len() > room {
            if state.dropped == 0 {
                eprintln!("[vmm] bluetooth: netsimd is not connected; dropping guest packets");
            }
            state.dropped += bytes.len() - room;
        }
    }
}

struct Packets(Arc<Bluetooth>);

impl Write for Packets {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.guest_wrote(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// A TCP port nothing listens on now (netsimd binds it a moment later).
fn free_port() -> Result<u16, String> {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).map_err(|e| format!("bluetooth port: {e}"))?;
    listener.local_addr().map(|a| a.port()).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A stand-in for netsimd's HCI port: answers HCI Reset like a controller.
    fn fake_controller() -> (u16, std::thread::JoinHandle<Vec<u8>>) {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut command = [0u8; 4];
            stream.read_exact(&mut command).unwrap();
            stream.write_all(&[0x04, 0x0e, 0x04, 0x01, 0x03, 0x0c, 0x00]).unwrap();
            command.to_vec()
        });
        (port, handle)
    }

    #[test]
    fn guest_bytes_before_the_connection_are_sent_once_it_is_up() {
        let (port, controller) = fake_controller();
        let bluetooth = Arc::new(Bluetooth::default());
        // The HAL's reset comes before netsimd's port is reached.
        bluetooth.sink().write_all(&[0x01, 0x03, 0x0c, 0x00]).unwrap();
        let mut reader = bluetooth.connect_to(port).unwrap();
        assert_eq!(controller.join().unwrap(), vec![0x01, 0x03, 0x0c, 0x00]);
        let mut event = [0u8; 7];
        reader.read_exact(&mut event).unwrap();
        assert_eq!(event, [0x04, 0x0e, 0x04, 0x01, 0x03, 0x0c, 0x00], "HCI Reset's Command Complete, as the HAL waits for it");
        assert!(bluetooth.state.lock().unwrap().pending.is_empty());
    }

    /// With the Android Emulator's netsimd:
    /// `AVO_NETSIMD=~/Library/Android/sdk/emulator/netsimd cargo test -p avo-vmm -- --ignored netsimd`.
    #[test]
    #[ignore]
    fn netsimd_starts_connects_and_stops() {
        let netsimd = std::env::var("AVO_NETSIMD").expect("AVO_NETSIMD");
        let root = std::env::temp_dir().join(format!("avo-netsimd-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let bluetooth = Bluetooth::start(Path::new(&netsimd), &root, &root).unwrap();
        let deadline = Instant::now() + CONNECT_TIMEOUT;
        while bluetooth.state.lock().unwrap().stream.is_none() {
            assert!(Instant::now() < deadline, "no HCI port; see {}", root.join("netsimd.log").display());
            std::thread::sleep(Duration::from_millis(50));
        }
        bluetooth.sink().write_all(&[0x01, 0x03, 0x0c, 0x00]).unwrap();
        let pid = bluetooth.child.lock().unwrap().as_ref().unwrap().id();
        bluetooth.stop();
        assert_ne!(unsafe { libc::kill(pid as i32, 0) }, 0, "netsimd ends with avo-vmm");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn waiting_bytes_are_bounded() {
        let bluetooth = Bluetooth::default();
        bluetooth.guest_wrote(&vec![0u8; PENDING_LIMIT + 10]);
        let state = bluetooth.state.lock().unwrap();
        assert_eq!(state.pending.len(), PENDING_LIMIT);
        assert_eq!(state.dropped, 10);
    }
}
