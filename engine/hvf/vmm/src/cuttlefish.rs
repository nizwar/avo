//! Booting an AOSP Cuttlefish build: instance disks, the bootconfig its
//! bootloader and launcher would pass, and the device set crosvm gives it.

use crate::bluetooth::Bluetooth;
use crate::camera;
use crate::cpu;
use crate::gnss::Gnss;
use crate::android;
use crate::control::{self, Controls, TOUCH_RANGE};
use crate::disk::{CompositeDisk, PartitionSpec};
use crate::frames::SharedFrames;
use crate::machine::{self, Machine};
use crate::modem;
use crate::net::Network;
use crate::sensors::Sensors;
use crate::sparse;
use crate::virtio::block::Block;
use crate::virtio::console::{Console, ConsoleInput, Sink};
use crate::virtio::gpu::render::{self, RenderHost};
use crate::virtio::gpu::{Gpu, GpuMode, MAX_SCANOUTS};
use crate::virtio::gpu::hostmem::Hvf;
use crate::virtio::input::{Description, Input};
use crate::virtio::media::Media;
use crate::virtio::net::Net;
use crate::virtio::rng::Rng;
use crate::virtio::sound::Sound;
use crate::virtio::vsock::Vsock;
use crate::virtio::VirtioDevice;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub struct Options {
    pub images: PathBuf,
    /// This Mac's side of a VM: shared-memory frames, logs, bootconfig.txt.
    pub instance: PathBuf,
    /// The writable disks that belong with Android's data (super, vbmeta,
    /// misc, metadata, frp): the instance directory, unless the data lives
    /// elsewhere (an external drive, next to `userdata`).
    pub disks: PathBuf,
    /// Where the sockets go (vsock.sock, control.sock, console.sock); the
    /// instance directory unless the path would be too long for a socket.
    pub runtime: PathBuf,
    /// User data disk; blank disks are formatted by Android on first boot.
    /// Default: a copy of the build's userdata.img in the instance directory.
    pub userdata: Option<PathBuf>,
    pub cpus: usize,
    pub memory_mib: usize,
    /// Size and density of display 0 (Android's default display).
    pub display: (u32, u32),
    /// Display 0's refresh rate in Hz (`--refresh-rate`).
    pub refresh_rate: u32,
    pub density: u32,
    pub timeout: Option<Duration>,
    pub verbose: bool,
    /// key=value lines that replace the image's properties (device identity).
    pub properties: Option<PathBuf>,
    /// Software (2D) or gfxstream on the Mac's GPU.
    pub gpu: GpuMode,
    /// A folder on the Mac for Android (virtio-fs, tag `avo_shared`); the
    /// daemon mounts it at /sdcard/Avo Shared.
    pub shared_dir: Option<PathBuf>,
    /// netsimd, started as Android's Bluetooth controller (bluetooth.rs).
    pub bluetooth: Option<PathBuf>,
    /// An init_boot.img to boot instead of the image's (root: Magisk's).
    pub init_boot: Option<PathBuf>,
    /// The modem's SIM and network at the start (`--cellular`; none: no SIM),
    /// until the control socket's `cellular` changes them (modem.rs).
    pub cellular: Option<modem::Service>,
    /// Cameras the daemon feeds (virtio/media.rs) instead of the image's
    /// emulated ones; `None`: the emulated ones.
    pub cameras: Option<camera::Present>,
    /// A phone's CPU for the vCPUs (`--cpu-clusters`; cpu.rs); `None`: the Mac's.
    pub cpu: Option<cpu::Clusters>,
    /// Android may use the Mac's microphone (`--no-microphone`: not until
    /// the control socket allows it; virtio/sound.rs).
    pub microphone: bool,
    /// A guest reboot ends the process (EXIT_GUEST_REBOOT) instead of
    /// building a new machine: the daemon starts Android again its own way.
    pub exit_on_reboot: bool,
}

/// Holds an exclusive lock on the instance directory for the life of the VM:
/// two VMs writing the same disks would corrupt them. Disks kept elsewhere
/// are locked too; a file system without locks (some external drives)
/// fails only when another VM holds the lock.
fn lock_instance(instance: &Path) -> Result<std::fs::File, String> {
    lock_directory(instance, true)?.ok_or_else(|| format!("{}: cannot lock", instance.display()))
}

fn lock_directory(directory: &Path, required: bool) -> Result<Option<std::fs::File>, String> {
    use std::os::fd::AsRawFd;
    unsafe extern "C" {
        fn flock(fd: i32, operation: i32) -> i32;
    }
    const LOCK_EX: i32 = 2;
    const LOCK_NB: i32 = 4;
    const EWOULDBLOCK: i32 = 35;
    std::fs::create_dir_all(directory).map_err(|e| e.to_string())?;
    let file = std::fs::File::create(directory.join("vm.lock")).map_err(|e| e.to_string())?;
    if unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) } != 0 {
        let error = std::io::Error::last_os_error();
        if required || error.raw_os_error() == Some(EWOULDBLOCK) {
            return Err(format!("{} is in use by another VM", directory.display()));
        }
        return Ok(None);
    }
    Ok(Some(file))
}

/// Writable copies of the images the guest changes, made once per instance:
/// super and userdata, and vbmeta, whose flags `avbctl disable-verity`
/// changes when the user adds Google apps to the system partitions.
fn prepare_instance(options: &Options) -> Result<(), String> {
    std::fs::create_dir_all(&options.instance).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&options.disks).map_err(|e| e.to_string())?;
    for name in ["super", "userdata", "vbmeta"] {
        if name == "userdata" && options.userdata.is_some() {
            continue;
        }
        let target = options.disks.join(format!("{name}.img"));
        if target.exists() {
            continue;
        }
        let source = options.images.join(format!("{name}.img"));
        eprintln!("[vmm] preparing {name}.img");
        if sparse::is_sparse(&source).map_err(|e| e.to_string())? {
            sparse::unsparse(&source, &target).map_err(|e| format!("{name}: {e}"))?;
        } else {
            clone_file(&source, &target)?;
        }
    }
    // frp: factory reset protection (PersistentDataBlockService), on
    // Cuttlefish's persistent disk; blank images are formatted by Android.
    for (name, size) in [("misc", 1u64 << 20), ("metadata", 64 << 20), ("frp", 1 << 20)] {
        let target = options.disks.join(format!("{name}.img"));
        if !target.exists() {
            let file = std::fs::File::create(&target).map_err(|e| e.to_string())?;
            file.set_len(size).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

/// APFS copy-on-write clone (falls back to a copy).
fn clone_file(source: &Path, target: &Path) -> Result<(), String> {
    use std::ffi::CString;
    unsafe extern "C" {
        fn clonefile(src: *const i8, dst: *const i8, flags: u32) -> i32;
    }
    let s = CString::new(source.as_os_str().as_encoded_bytes()).unwrap();
    let t = CString::new(target.as_os_str().as_encoded_bytes()).unwrap();
    if unsafe { clonefile(s.as_ptr(), t.as_ptr(), 0) } == 0 {
        return Ok(());
    }
    std::fs::copy(source, target).map(|_| ()).map_err(|e| format!("{}: {e}", source.display()))
}

/// Cuttlefish's os_composite disk: A/B boot partitions, vbmeta, super and data.
fn composite_disk(options: &Options) -> Result<CompositeDisk, String> {
    let image = |name: &str| options.images.join(format!("{name}.img"));
    let local = |name: &str| options.disks.join(format!("{name}.img"));
    let mut specs = Vec::new();
    let ab = |name: &str, path: PathBuf, specs: &mut Vec<PartitionSpec>| {
        for slot in ["_a", "_b"] {
            specs.push(PartitionSpec { name: format!("{name}{slot}"), path: path.clone(), read_only: true });
        }
    };
    ab("boot", image("boot"), &mut specs);
    ab("init_boot", image("init_boot"), &mut specs);
    specs.push(PartitionSpec { name: "frp".into(), path: local("frp"), read_only: false });
    specs.push(PartitionSpec { name: "metadata".into(), path: local("metadata"), read_only: false });
    specs.push(PartitionSpec { name: "misc".into(), path: local("misc"), read_only: false });
    specs.push(PartitionSpec { name: "super".into(), path: local("super"), read_only: false });
    let userdata = options.userdata.clone().unwrap_or_else(|| local("userdata"));
    specs.push(PartitionSpec { name: "userdata".into(), path: userdata, read_only: false });
    for slot in ["_a", "_b"] {
        specs.push(PartitionSpec { name: format!("vbmeta{slot}"), path: local("vbmeta"), read_only: false });
    }
    for name in ["vbmeta_system", "vbmeta_system_dlkm", "vbmeta_vendor_dlkm", "vendor_boot"] {
        if image(name).exists() {
            ab(name, image(name), &mut specs);
        }
    }
    CompositeDisk::new(&specs, "avo-os-composite").map_err(|e| e.to_string())
}

fn bootconfig(options: &Options, vendor: &str) -> Result<String, String> {
    let (vbmeta_size, vbmeta_digest) = android::vbmeta_digest(&options.disks.join("vbmeta.img"), |name| {
        let path = options.images.join(format!("{name}.img"));
        path.exists().then_some(path)
    })?;
    let mut entries = android::parse_bootconfig(vendor);
    let mut set = |k: &str, v: &str| entries.push((k.to_string(), v.to_string()));
    // What Cuttlefish's bootloader and launcher pass (bootconfig_args.cpp).
    set("androidboot.boot_devices", "10000.pci");
    set("androidboot.slot_suffix", "_a");
    set("androidboot.force_normal_boot", "1");
    set("androidboot.serialno", "AVO00001");
    set("androidboot.verifiedbootstate", "orange");
    set("androidboot.vbmeta.device_state", "unlocked");
    set("androidboot.vbmeta.avb_version", "1.3");
    set("androidboot.vbmeta.hash_alg", "sha256");
    set("androidboot.vbmeta.size", &vbmeta_size.to_string());
    set("androidboot.vbmeta.digest", &vbmeta_digest);
    set("androidboot.vbmeta.invalidate_on_error", "yes");
    set("androidboot.selinux", "permissive");
    set("androidboot.console", "hvc1");
    set("androidboot.serialconsole", "1");
    set("androidboot.fstab_suffix", "cf.f2fs.hctr2");
    set("androidboot.ddr_size", &format!("{}MB", options.memory_mib));
    set("androidboot.lcd_density", &options.density.to_string());
    set("androidboot.setupwizard_mode", "DISABLED");
    set("androidboot.enable_bootanimation", "1");
    set("androidboot.enable_confirmationui", "0");
    set("androidboot.hw_timeout_multiplier", "3");
    set("androidboot.hypervisor.vm.supported", "0");
    set("androidboot.hypervisor.protected_vm.supported", "0");
    set("androidboot.wifi_impl", "virt_wifi");
    set("androidboot.wifi_mac_prefix", "5554");
    // HALs that serve the host over vsock need their ports (or abort).
    set("androidboot.vsock_lights_port", "6900");
    set("androidboot.vsock_lights_cid", "3");
    set("androidboot.vsock_camera_port", "7000");
    set("androidboot.vsock_camera_cid", "3");
    // The radio HAL's modem (modem.rs): no SIM, no network.
    set("androidboot.modem_simulator_ports", &modem::PORT.to_string());
    set("androidboot.openthread_node_id", "1");
    // The audio HAL plays and records through ALSA card 0, the virtio-snd device.
    set("androidboot.audio.tinyalsa.ignore_output", "false");
    set("androidboot.audio.tinyalsa.simulate_input", "false");
    // Graphics: guest SwiftShader, or gfxstream on the Mac's GPU (virtio/gpu/guest.rs).
    for (key, value) in crate::virtio::gpu::guest::graphics_bootconfig(&options.gpu) {
        set(key, value);
    }
    // Security HALs run in the guest: no host secure_env on macOS yet.
    set("androidboot.vendor.apex.com.android.hardware.keymint", "com.android.hardware.keymint.rust_nonsecure");
    set("androidboot.vendor.apex.com.android.hardware.gatekeeper", "com.android.hardware.gatekeeper.nonsecure");
    set("androidboot.vendor.apex.com.android.hardware.secure_element", "com.android.hardware.secure_element");
    set("androidboot.vendor.apex.com.android.hardware.strongbox", "none");
    set("androidboot.vendor.apex.com.android.hardware.weaver", "none");
    set("androidboot.vendor.apex.com.android.hardware.graphics.composer", "com.android.hardware.graphics.composer.ranchu");
    // The emulated cameras, or the external camera HAL that opens the
    // virtio-media cameras the daemon feeds (`--cameras`, camera.rs).
    let cameras = match options.cameras {
        None => "com.google.emulated.camera.provider.hal",
        Some(_) => "com.google.emulated.camera.provider.hal.v4l2",
    };
    set("androidboot.vendor.apex.com.google.emulated.camera.provider.hal", cameras);
    Ok(android::bootconfig_text(&entries))
}

/// Writes guest output to a log file and to whoever is attached to the socket.
struct Tee {
    file: std::fs::File,
    clients: Arc<Mutex<Vec<UnixStream>>>,
    echo: bool,
}

impl Write for Tee {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        self.file.write_all(data)?;
        if self.echo {
            let _ = std::io::stdout().write_all(data);
        }
        self.clients.lock().unwrap().retain_mut(|c| c.write_all(data).is_ok());
        Ok(data.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        if self.echo {
            let _ = std::io::stdout().flush();
        }
        self.file.flush()
    }
}

/// The shell console of the machine that runs now (a reboot builds a new one).
static SHELL: Mutex<Option<ConsoleInput>> = Mutex::new(None);
static WATCH: std::sync::Once = std::sync::Once::new();

/// When the process that started avo-vmm (the Runtime Daemon) goes away,
/// Android powers off cleanly through its shell console instead of running
/// on as an orphan that holds the disks and the instance lock.
fn watch_parent(shell: ConsoleInput) {
    unsafe extern "C" {
        fn getppid() -> i32;
    }
    *SHELL.lock().unwrap() = Some(shell);
    WATCH.call_once(|| {
        let parent = unsafe { getppid() };
        if parent <= 1 {
            return; // started by launchd itself: nobody to outlive
        }
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_secs(1));
            if unsafe { getppid() } == parent {
                continue;
            }
            eprintln!("[vmm] the process that started the engine went away; powering Android off");
            // A paused Android would never read it.
            crate::pause::GATE.resume();
            if let Some(shell) = SHELL.lock().unwrap().as_ref() {
                shell.send(b"\nsu 0 reboot -p\n");
            }
            // Power off ends the machine loop and the process; leave anyway if it does not come.
            std::thread::sleep(Duration::from_secs(30));
            eprintln!("[vmm] Android did not power off; exiting");
            exit(1);
        });
    });
}

/// The shell console of the machine that runs now, and the clients that
/// hear its output. The socket is the process's: a guest reboot hands it the
/// new machine's console and attached clients go on with that one, instead
/// of a listener per boot left waiting on a socket nobody reaches.
static CONSOLE: Mutex<Option<(ConsoleInput, Arc<Mutex<Vec<UnixStream>>>)>> = Mutex::new(None);

fn serve_console(path: &Path, input: ConsoleInput, clients: Arc<Mutex<Vec<UnixStream>>>) -> Result<(), String> {
    let previous = CONSOLE.lock().unwrap().replace((input, clients.clone()));
    if let Some((_, attached)) = previous {
        let attached = std::mem::take(&mut *attached.lock().unwrap());
        clients.lock().unwrap().extend(attached);
        return Ok(());
    }
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path).map_err(|e| format!("{}: {e}", path.display()))?;
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let Ok(writer) = stream.try_clone() else { continue };
            let Some((_, clients)) = CONSOLE.lock().unwrap().clone() else { continue };
            clients.lock().unwrap().push(writer);
            std::thread::spawn(move || {
                let mut stream = stream;
                let mut buffer = [0u8; 4096];
                while let Ok(n) = stream.read(&mut buffer) {
                    if n == 0 {
                        break;
                    }
                    let input = CONSOLE.lock().unwrap().as_ref().map(|(input, _)| input.clone());
                    if let Some(input) = input {
                        input.send(&buffer[..n]);
                    }
                }
            });
        }
    });
    Ok(())
}

/// Exit code when GPU mode cannot start (no guest code has run yet): the
/// daemon starts Android again in software.
pub const EXIT_GPU_UNAVAILABLE: i32 = 75;

/// Exit code when Android asked for a factory reset (Settings › System ›
/// Reset options, a device admin): it writes recovery's `--wipe_data` to
/// misc and reboots, and there is no recovery here, so the daemon erases
/// Android's data as Reset Android does and starts it again.
pub const EXIT_FACTORY_RESET: i32 = 76;

/// Exit code for a guest reboot (Restart, `adb reboot`) with
/// `--exit-on-reboot`: the daemon starts Android again through its usual
/// start, which prepares the new boot (displays, location, the shared
/// folder, audio) as it does every boot.
pub const EXIT_GUEST_REBOOT: i32 = 77;

/// misc's bootloader_message (bootable/recovery/bootloader_message.h):
/// command[32], status[32], recovery[768], stage[32], reserved[1184].
const BCB_SIZE: usize = 2048;
const BCB_RECOVERY: std::ops::Range<usize> = 64..832;

fn bcb_field(bcb: &[u8]) -> &[u8] {
    &bcb[..bcb.iter().position(|&b| b == 0).unwrap_or(bcb.len())]
}

/// Whether a bootloader_message asks recovery to wipe the data. RescueParty's
/// `--prompt_and_wipe_data` asks the user first in recovery: not a request.
fn bcb_wipes_data(bcb: &[u8]) -> bool {
    bcb.len() >= BCB_RECOVERY.end
        && bcb_field(&bcb[..32]) == b"boot-recovery"
        && bcb_field(&bcb[BCB_RECOVERY]).split(|&b| b == b'\n').any(|line| line == b"--wipe_data")
}

fn read_bcb(misc: &Path) -> Option<Vec<u8>> {
    use std::os::unix::fs::FileExt;
    let file = std::fs::File::open(misc).ok()?;
    let mut bcb = vec![0u8; BCB_SIZE];
    file.read_exact_at(&mut bcb, 0).ok()?;
    Some(bcb)
}

/// Drops a recovery request left on misc before a boot: no recovery runs
/// here, and one an older avo-vmm ignored must not wipe the data at some
/// later reboot. Only a request made during a boot counts (`run`).
fn clear_recovery_request(misc: &Path) -> Result<(), String> {
    use std::os::unix::fs::FileExt;
    let Some(bcb) = read_bcb(misc) else { return Ok(()) };
    if !bcb_field(&bcb[..32]).starts_with(b"boot-recovery") {
        return Ok(());
    }
    eprintln!("[vmm] dropping a recovery request left on misc");
    let file = std::fs::OpenOptions::new().write(true).open(misc).map_err(|e| format!("misc: {e}"))?;
    file.write_all_at(&[0u8; BCB_SIZE], 0).map_err(|e| format!("misc: {e}"))
}

/// Set once gfxstream is loaded: its C++ static destructors may crash after
/// a clean power-off, so the process then leaves without running them.
static GPU_LOADED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// netsimd, when it runs: it ends with the process.
static BLUETOOTH: Mutex<Option<Arc<Bluetooth>>> = Mutex::new(None);

/// Ends the process (with `_exit` once gfxstream is loaded).
pub fn exit(code: i32) -> ! {
    if let Some(bluetooth) = BLUETOOTH.lock().unwrap().take() {
        bluetooth.stop();
    }
    if GPU_LOADED.load(std::sync::atomic::Ordering::SeqCst) {
        let _ = std::io::stdout().flush();
        unsafe { libc::_exit(code) }
    }
    std::process::exit(code)
}

pub fn run(options: Options) -> Result<(), String> {
    let _lock = lock_instance(&options.instance)?;
    let _disks_lock = if options.disks != options.instance { lock_directory(&options.disks, false)? } else { None };
    prepare_instance(&options)?;
    modem::CELLULAR.set(options.cellular);
    crate::virtio::sound::MICROPHONE.set(options.microphone);
    // MARK: GPU — the renderer starts once, before the first boot, and
    // lives through guest reboots.
    let renderer = match &options.gpu {
        GpuMode::TwoD => None,
        GpuMode::Gfxstream { dir, hwc } => {
            // SAFETY: no thread has started yet (they all come after this).
            unsafe { render::set_environment(dir) };
            GPU_LOADED.store(true, std::sync::atomic::Ordering::SeqCst);
            match render::start(dir, options.display, *hwc, options.verbose) {
                Ok(host) => Some(host),
                Err(e) => {
                    eprintln!("error: gpu: {e}");
                    exit(EXIT_GPU_UNAVAILABLE);
                }
            }
        }
    };
    // Bluetooth's controller, like the renderer, lives through guest reboots.
    let bluetooth = match &options.bluetooth {
        Some(netsimd) => match Bluetooth::start(netsimd, &options.runtime, &options.instance) {
            Ok(bluetooth) => {
                *BLUETOOTH.lock().unwrap() = Some(bluetooth.clone());
                Some(bluetooth)
            }
            Err(e) => {
                eprintln!("[vmm] bluetooth: {e}; Android's Bluetooth stays off");
                None
            }
        },
        None => None,
    };
    // A guest reboot (PSCI SYSTEM_RESET) builds a fresh machine.
    let misc = options.disks.join("misc.img");
    loop {
        clear_recovery_request(&misc)?;
        let stop = boot(&options, renderer.as_ref(), bluetooth.as_ref())?;
        if read_bcb(&misc).is_some_and(|bcb| bcb_wipes_data(&bcb)) {
            eprintln!("[vmm] Android asked for a factory reset");
            exit(EXIT_FACTORY_RESET);
        }
        match stop {
            machine::Stop::Reset if options.exit_on_reboot => {
                eprintln!("[vmm] guest rebooted: the daemon starts it again");
                exit(EXIT_GUEST_REBOOT);
            }
            machine::Stop::Reset => eprintln!("[vmm] guest rebooted"),
            _ => return Ok(()),
        }
    }
}

fn boot(options: &Options, renderer: Option<&RenderHost>, bluetooth: Option<&Arc<Bluetooth>>) -> Result<machine::Stop, String> {
    let image_init_boot = options.images.join("init_boot.img");
    let init_boot = options.init_boot.as_deref().or(Some(image_init_boot.as_path()).filter(|p| p.exists()));
    let images = android::load(&options.images.join("boot.img"), init_boot, &options.images.join("vendor_boot.img"))?;
    let bootconfig = bootconfig(options, &images.vendor_bootconfig)?;
    std::fs::write(options.instance.join("bootconfig.txt"), &bootconfig).map_err(|e| e.to_string())?;
    let mut initrd = images.ramdisk;
    // GPU mode's properties first: the device profile's replace them.
    let mut properties = crate::virtio::gpu::guest::graphics_properties(&options.gpu).to_string();
    if let Some(path) = &options.properties {
        let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        properties.push_str(&text);
    }
    android::prepend_property_overrides(&mut initrd, &properties);
    android::append_bootconfig(&mut initrd, &bootconfig);
    // earlycon on the PL011 until virtio_console loads, then hvc0: the PL011
    // traps once per character, hvc0 once per buffer.
    let cmdline = format!("{} earlycon=pl011,mmio32,0x9000000 console=hvc0", images.vendor_cmdline.trim());

    let log = |name: &str| std::fs::File::create(options.instance.join(name)).map_err(|e| e.to_string());
    let kernel_file = log("kernel.log")?;
    let kernel_log = |file: &std::fs::File| -> Result<Box<dyn Write + Send>, String> {
        Ok(Box::new(Tee {
            file: file.try_clone().map_err(|e| e.to_string())?,
            clients: Arc::new(Mutex::new(Vec::new())),
            echo: options.verbose,
        }))
    };
    let mut machine = Machine::new(options.cpus, options.memory_mib, kernel_log(&kernel_file)?)?;
    if let Some(clusters) = &options.cpu {
        machine.present_cpu(clusters.clone())?;
    }

    let disk = composite_disk(options)?;
    if options.verbose {
        for (name, start, size) in disk.layout() {
            eprintln!("[vmm] partition {name:20} at {:>8} MiB, {:>8} KiB", start >> 20, size >> 10);
        }
    }
    machine.add_virtio(Box::new(Block::new(Box::new(disk), "avo-os")));

    // hvc0..hvc19 in Cuttlefish order (crosvm_manager.cpp), eight per PCI device.
    let console_clients = Arc::new(Mutex::new(Vec::new()));
    let sensors = Sensors::new();
    let mut sensor_ports = Vec::new();
    // /dev/gnss1 (hvc7): the GNSS HAL asks for the Mac's location here.
    let gnss = Gnss::new();
    let mut consoles: Vec<Box<dyn VirtioDevice>> = Vec::new();
    for index in 0..20 {
        let sink: Option<Sink> = match index {
            0 => Some(kernel_log(&kernel_file)?),
            1 => Some(Box::new(Tee { file: log("console.log")?, clients: console_clients.clone(), echo: false })),
            2 => Some(Box::new(log("logcat.log")?)),
            // /dev/hvc5: the Bluetooth HAL's H4 (bluetooth.rs).
            5 => bluetooth.map(|bluetooth| bluetooth.sink()),
            7 => Some(gnss.sink()),
            18 => Some(sensors.control_sink()),
            _ => None,
        };
        let console = Console::new(sink);
        match index {
            1 => {
                serve_console(&options.runtime.join("console.sock"), console.input(), console_clients.clone())?;
                watch_parent(console.input());
            }
            5 => {
                if let Some(bluetooth) = bluetooth { bluetooth.connect(console.input()) }
            }
            7 => gnss.connect(console.input()),
            18 | 19 => sensor_ports.push(console.input()),
            _ => {}
        }
        consoles.push(Box::new(console));
    }
    while !consoles.is_empty() {
        let group: Vec<_> = consoles.drain(..consoles.len().min(8)).collect();
        machine.add_virtio_functions(group);
    }
    sensors.connect(sensor_ports[0].clone(), sensor_ports[1].clone());
    machine.add_virtio(Box::new(Rng::default()));
    // Guest CID 3 like Cuttlefish's first instance.
    let vsock = Vsock::new(3, &options.runtime.join("vsock.sock")).map_err(|e| format!("vsock: {e}"))?;
    modem::serve(&options.runtime.join(format!("vsock.sock_{}", modem::PORT)))?;
    machine.add_virtio(Box::new(vsock));

    // Display 0 is Android's default display; Avo plugs in one more per app window.
    // The composer (display_framebuffer_format=bgra, the only family the
    // guest's virtio-gpu driver scans out) fills those buffers with RGBA bytes.
    // On the GPU each resource's own format says what its bytes are.
    let frames =
        SharedFrames::new(&options.instance.join("frames"), renderer.is_none()).map_err(|e| format!("frames: {e}"))?;
    let frame_handle = frames.handle();
    if let Some(bluetooth) = bluetooth {
        // The daemon adds its own chips (the Mac's Bluetooth devices) on the same port.
        frame_handle.emit_sticky(format!("bluetooth hci {}", bluetooth.port()));
    }
    let microphone_events = frame_handle.clone();
    let sound_events = frame_handle.clone();
    let camera_events = frame_handle.clone();
    let gpu = match renderer {
        None => Gpu::new(&[options.display], Box::new(frames)),
        Some(host) => {
            frame_handle.emit_sticky(format!("gpu active {}", host.device));
            Gpu::with_renderer(&[options.display], Box::new(frames), host.clone(), frame_handle.clone())
        }
    }
    .at_refresh_rate(options.refresh_rate);
    let displays = gpu.control();
    machine.add_virtio(Box::new(gpu));
    // One touchscreen per scanout; Android ties screen N to display N
    // through /data/system/devices/idc/Vendor_1af4_Product_01NN.idc.
    let mut touchscreens = Vec::new();
    let mut screens: Vec<Box<dyn VirtioDevice>> = Vec::new();
    for index in 0..MAX_SCANOUTS {
        let input = Input::new(Description::touchscreen(&format!("Avo Touch Screen {index}"), 0x0100 + index as u16, TOUCH_RANGE));
        touchscreens.push(input.sender());
        screens.push(Box::new(input));
    }
    while !screens.is_empty() {
        let group: Vec<_> = screens.drain(..screens.len().min(8)).collect();
        machine.add_virtio_functions(group);
    }
    let keyboard = Input::new(Description::keyboard("Avo Keyboard"));
    // Plugged in last (below), so the devices before it keep their PCI slots.
    // Named like an Xbox controller on Android: games such as Call of Duty:
    // Mobile accept only controllers whose name they know.
    let gamepad = Input::new(Description::gamepad("Xbox Wireless Controller"));
    let controls = Controls::new(touchscreens, keyboard.sender(), gamepad.sender(), displays, frame_handle,
                                 options.display, gnss);
    machine.add_virtio(Box::new(keyboard));
    control::serve(&options.runtime.join("control.sock"), controls)?;

    // Cuttlefish's three NICs: eth0 (mobile data, renamed buried_eth0),
    // eth1 (Ethernet) and eth2, which setup_wifi wraps in virt_wifi as wlan0
    // (ro.vendor.virtwifi.port). Wi-Fi and mobile data have a network each,
    // with the same addresses (Android routes each network by its own
    // table): the radio HAL brings buried_eth0 up with a data call's address
    // (modem.rs) once the modem has a SIM, and leaves it down until then.
    // Ethernet has no carrier, so Android shows a phone on Wi-Fi.
    let mut nics: Vec<Box<dyn VirtioDevice>> = Vec::new();
    for index in 0..3u8 {
        let mut nic = Net::new([0x02, 0x61, 0x76, 0x6f, 0x00, index]);
        if index == 0 || index == 2 {
            let network = Network::start(nic.downlink())?;
            nic.connect(network.uplink());
        }
        nics.push(Box::new(nic));
    }
    machine.add_virtio_functions(nics);
    // Speaker and microphone: the Mac's default output and input. What
    // Android plays also goes to screen recordings (virtio/sound/tap.rs).
    let audio = options.instance.join("audio");
    if let Some(event) = crate::virtio::sound::tap::open(&std::path::absolute(&audio).unwrap_or(audio)) {
        sound_events.emit_sticky(event);
    }
    let mut sound = Sound::new();
    sound.on_recording(move || microphone_events.emit("microphone".into()));
    // Whether Android plays or records: the daemon does not pause it then.
    sound.on_stream(move |kind, on| sound_events.emit_sticky(format!("sound {kind} {}", if on { "on" } else { "off" })));
    machine.add_virtio(Box::new(sound));
    // The Mac's game controller as an Xbox pad (virtio/input.rs). The daemon
    // keeps its driver unbound while no controller drives it, so Android
    // only sees a gamepad when there is one.
    machine.add_virtio(Box::new(gamepad));
    // The shared folder (virtio/fs.rs), after everything else so no other
    // device moves. A folder that is not there (an unplugged drive) leaves
    // it out; Android starts without it.
    if let Some(folder) = &options.shared_dir {
        match crate::virtio::fs::server::SharedDir::new(folder) {
            Ok(server) => machine.add_virtio(Box::new(crate::virtio::fs::Fs::new(server))),
            Err(e) => eprintln!("[vmm] shared folder {}: {e}; starting without it", folder.display()),
        }
    }
    // The cameras the daemon feeds: back, then front, as the two functions
    // of one device, so the guest's virtio-media driver (loaded after
    // v4l2loopback's /dev/video0) makes them /dev/video1 and /dev/video2
    // whichever of them Android has (camera.rs).
    if let Some(present) = options.cameras {
        camera::HUB.set_events(Arc::new(move |event| camera_events.emit_sticky(event)));
        let cameras: Vec<Box<dyn VirtioDevice>> = (0..camera::CAMERAS)
            .map(|index| Box::new(Media::new(index, present.0[index], &camera::HUB, Box::new(Hvf))) as Box<dyn VirtioDevice>)
            .collect();
        machine.add_virtio_functions(cameras);
    }

    let stop = machine.run(&images.kernel, &initrd, &cmdline, options.timeout)?;
    eprintln!("[vmm] {stop:?}");
    Ok(stop)
}

#[cfg(test)]
mod recovery_request_tests {
    use super::*;

    fn bcb(command: &str, recovery: &str) -> Vec<u8> {
        let mut bcb = vec![0u8; BCB_SIZE];
        bcb[..command.len()].copy_from_slice(command.as_bytes());
        bcb[64..64 + recovery.len()].copy_from_slice(recovery.as_bytes());
        bcb
    }

    #[test]
    fn only_a_wipe_request_counts() {
        // RecoverySystem.rebootWipeUserData, as Android 17 wrote it.
        assert!(bcb_wipes_data(&bcb("boot-recovery", "recovery\n--wipe_data\n--reason=avo-test,2026-10-18T06:43:14Z\n--locale=en-US\n")));
        assert!(!bcb_wipes_data(&bcb("boot-recovery", "recovery\n--prompt_and_wipe_data\n--reason=RescueParty\n")));
        assert!(!bcb_wipes_data(&bcb("boot-recovery", "recovery\n")));
        assert!(!bcb_wipes_data(&bcb("", "")));
        assert!(!bcb_wipes_data(&bcb("bootonce-bootloader", "recovery\n--wipe_data\n")));
    }

    #[test]
    fn a_left_request_is_dropped_before_a_boot() {
        let dir = std::env::temp_dir().join(format!("avo-misc-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let misc = dir.join("misc.img");
        let mut disk = bcb("boot-recovery", "recovery\n--wipe_data\n");
        disk.resize(1 << 20, 0);
        disk[40_000] = 7; // misc's other messages (virtual A/B) stay
        std::fs::write(&misc, &disk).unwrap();
        clear_recovery_request(&misc).unwrap();
        let after = std::fs::read(&misc).unwrap();
        assert!(after[..BCB_SIZE].iter().all(|&b| b == 0));
        assert_eq!(after[40_000], 7);
        assert_eq!(after.len(), 1 << 20);
        // Nothing to drop: untouched, and a missing misc is fine.
        clear_recovery_request(&misc).unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
        clear_recovery_request(&misc).unwrap();
    }
}

#[cfg(test)]
mod console_tests {
    use super::*;

    #[test]
    fn attached_clients_go_on_with_the_next_machines_console() {
        let path = std::env::temp_dir().join(format!("avo-console-{}.sock", std::process::id()));
        let boot = || (Console::new(None), Arc::new(Mutex::new(Vec::<UnixStream>::new())));
        let (first, first_clients) = boot();
        serve_console(&path, first.input(), first_clients.clone()).unwrap();
        let mut client = UnixStream::connect(&path).unwrap();
        client.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while first_clients.lock().unwrap().is_empty() && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        // A guest reboot.
        let (second, second_clients) = boot();
        serve_console(&path, second.input(), second_clients.clone()).unwrap();
        assert!(first_clients.lock().unwrap().is_empty());
        for writer in second_clients.lock().unwrap().iter_mut() {
            writer.write_all(b"login: ").unwrap();
        }
        let mut heard = [0u8; 7];
        client.read_exact(&mut heard).unwrap();
        assert_eq!(&heard, b"login: ", "the attached client hears the new machine");
        assert!(UnixStream::connect(&path).is_ok(), "the same socket takes new clients");
        let _ = std::fs::remove_file(&path);
    }
}
