//! Bluetooth: Cuttlefish's HCI HAL (`bt_hci`, android.hardware.bluetooth-
//! service.cuttlefish) speaks H4 on /dev/hvc5, where Cuttlefish's host runs
//! Root Canal, a virtual controller. avo-vmm starts one (`--bluetooth`):
//! Avo's own Root Canal, built from source and shipped in Avo.app
//! (scripts/build-bluetooth.sh), or the Android Emulator's netsimd (Root
//! Canal inside), told apart by their names. It passes the bytes both ways
//! between hvc5 and the controller's HCI port (H4 over TCP), unread:
//! Android's Bluetooth turns on and scans, advertises and connects inside
//! the controller's virtual air. Nothing reaches the Mac's own Bluetooth.
//!
//! The controller runs once per avo-vmm, through guest reboots (the HAL
//! resets the controller as it starts), with its files under the runtime
//! directory and its log in the instance's bluetooth.log. It is killed when
//! avo-vmm ends (`stop`). Guest bytes that come before the connection wait
//! for it, so a packet is never cut in two.
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

/// Guest bytes kept while the controller is not connected yet (a reset and
/// the first commands are a few dozen).
const PENDING_LIMIT: usize = 64 * 1024;
/// How long the controller has to open its HCI port.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Default)]
struct State {
    /// The controller's HCI port, once connected.
    stream: Option<TcpStream>,
    /// Guest bytes from before the connection.
    pending: Vec<u8>,
    /// Bytes dropped over `PENDING_LIMIT` (reported once).
    dropped: usize,
}

#[derive(Default)]
pub struct Bluetooth {
    /// The controller's HCI port.
    port: u16,
    state: Mutex<State>,
    /// hvc5's input: where the controller's events go. Each boot connects its own.
    input: Mutex<Option<ConsoleInput>>,
    child: Mutex<Option<Child>>,
}

impl Bluetooth {
    /// Starts the controller (`rootcanal`, else netsimd) and connects to its
    /// HCI port in the background.
    pub fn start(controller: &Path, runtime: &Path, instance: &Path) -> Result<Arc<Bluetooth>, String> {
        // The HCI port, and Root Canal's three unused ones: all different.
        let ports = free_ports(4)?;
        let port = ports[0];
        let files = runtime.join("bluetooth");
        std::fs::create_dir_all(&files).map_err(|e| format!("{}: {e}", files.display()))?;
        let log = std::fs::File::create(instance.join("bluetooth.log")).map_err(|e| format!("bluetooth.log: {e}"))?;
        let mut command = Command::new(controller);
        if controller.file_name().is_some_and(|name| name == "rootcanal") {
            command.arg(format!("--hci_port={port}"));
            // Its test channel and links go unused: free ports, so nothing clashes.
            for (flag, other) in ["--test_port", "--link_port", "--link_ble_port"].into_iter().zip(&ports[1..]) {
                command.arg(format!("{flag}={other}"));
            }
            command.current_dir(&files);
        } else {
            command
                .args(["--no-cli-ui", "--no-web-ui", "--logtostderr", "--instance", "1", "--hci-port", &port.to_string()])
                // Bluetooth only: Avo's Wi-Fi has its own NAT (net.rs).
                .args(["--debug-no-network", "--debug-no-guest-to-host-mdns"])
                .env("TMPDIR", &files);
        }
        let child = command
            .stdin(Stdio::null())
            .stdout(log.try_clone().map_err(|e| e.to_string())?)
            .stderr(log)
            .spawn()
            .map_err(|e| format!("{}: {e}", controller.display()))?;
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

    /// Ends the controller (avo-vmm is leaving).
    pub fn stop(&self) {
        if let Some(stream) = self.state.lock().unwrap().stream.take() {
            let _ = stream.shutdown(Shutdown::Both);
        }
        if let Some(mut child) = self.child.lock().unwrap().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    /// Connects, then passes the controller's packets to the guest until the connection ends.
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
            eprintln!("[vmm] bluetooth: the controller closed its HCI port; Android's Bluetooth stops answering");
        }
    }

    /// Waits for the controller's port, then sends what the guest wrote meanwhile.
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
                        eprintln!("[vmm] bluetooth: the controller's HCI port closed at once");
                        return None;
                    }
                    state.stream = Some(writer);
                    return Some(reader);
                }
                Err(e) if Instant::now() >= deadline => {
                    eprintln!("[vmm] bluetooth: no HCI port on {port}: {e}; Android's Bluetooth stays off");
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
                eprintln!("[vmm] bluetooth: the controller is not connected; dropping guest packets");
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

/// TCP ports nothing listens on now (the controller binds them a moment
/// later), all different: each stays bound until all are chosen.
fn free_ports(count: usize) -> Result<Vec<u16>, String> {
    let listeners = (0..count)
        .map(|_| TcpListener::bind((Ipv4Addr::LOCALHOST, 0)))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("bluetooth port: {e}"))?;
    listeners.iter().map(|l| l.local_addr().map(|a| a.port()).map_err(|e| e.to_string())).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A stand-in for the controller's HCI port: answers HCI Reset like one.
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
        // The HAL's reset comes before the controller's port is reached.
        bluetooth.sink().write_all(&[0x01, 0x03, 0x0c, 0x00]).unwrap();
        let mut reader = bluetooth.connect_to(port).unwrap();
        assert_eq!(controller.join().unwrap(), vec![0x01, 0x03, 0x0c, 0x00]);
        let mut event = [0u8; 7];
        reader.read_exact(&mut event).unwrap();
        assert_eq!(event, [0x04, 0x0e, 0x04, 0x01, 0x03, 0x0c, 0x00], "HCI Reset's Command Complete, as the HAL waits for it");
        assert!(bluetooth.state.lock().unwrap().pending.is_empty());
    }

    /// With a real controller, Avo's Root Canal (build/bluetooth/rootcanal)
    /// or the Android Emulator's netsimd:
    /// `AVO_BLUETOOTH_CONTROLLER=build/bluetooth/rootcanal cargo test -p avo-vmm -- --ignored controller`.
    #[test]
    #[ignore]
    fn controller_starts_resets_and_stops() {
        let controller = std::env::var("AVO_BLUETOOTH_CONTROLLER").expect("AVO_BLUETOOTH_CONTROLLER");
        let root = std::env::temp_dir().join(format!("avo-bluetooth-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let bluetooth = Bluetooth::start(Path::new(&controller), &root, &root).unwrap();
        let deadline = Instant::now() + CONNECT_TIMEOUT;
        while bluetooth.state.lock().unwrap().stream.is_none() {
            assert!(Instant::now() < deadline, "no HCI port; see {}", root.join("bluetooth.log").display());
            std::thread::sleep(Duration::from_millis(50));
        }
        // Another chip on the same port, as the daemon's proxies are: it
        // answers HCI Reset as the HAL waits for.
        let mut chip = TcpStream::connect((Ipv4Addr::LOCALHOST, bluetooth.port())).unwrap();
        chip.set_read_timeout(Some(CONNECT_TIMEOUT)).unwrap();
        chip.write_all(&[0x01, 0x03, 0x0c, 0x00]).unwrap();
        let mut event = [0u8; 7];
        chip.read_exact(&mut event).unwrap();
        assert_eq!(event, [0x04, 0x0e, 0x04, 0x01, 0x03, 0x0c, 0x00], "HCI Reset's Command Complete");
        let pid = bluetooth.child.lock().unwrap().as_ref().unwrap().id();
        bluetooth.stop();
        assert_ne!(unsafe { libc::kill(pid as i32, 0) }, 0, "the controller ends with avo-vmm");
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
