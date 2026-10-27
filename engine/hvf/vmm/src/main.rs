//! avo-vmm: Avo's VM engine. Boots an AOSP Cuttlefish arm64 build
//! (scripts/fetch-cuttlefish.sh) on Hypervisor.framework with crosvm-style
//! virtio-pci devices.
//!
//!   avo-vmm cuttlefish <image dir> [--instance DIR] [--runtime DIR] [--userdata FILE]
//!                       [--disks DIR] [--cpus N] [--mem MiB] [--display WxH] [--density DPI]
//!                       [--timeout SECONDS] [--properties FILE] [--verbose]
//!                       [--gpu 2d|gfxstream] [--gfxstream-dir DIR] [--hwc client|host]
//!                       [--shared-dir DIR] [--refresh-rate HZ] [--bluetooth CONTROLLER]
//!                       [--init-boot FILE] [--cellular TYPE:BARS] [--cameras LIST]
//!                       [--no-microphone] [--cpu-clusters LIST] [--hardware NAME]
//!
//! --properties names a file of key=value lines that replace the image's
//! properties (the device profile's identity, e.g. ro.product.model).
//!
//! --gpu gfxstream renders Android on the Mac's GPU with the gfxstream in
//! --gfxstream-dir (the directory with lib64/: Avo.app's own build, or an
//! Android Emulator); --hwc
//! host lets the composer use gfxstream's host composition (bring-up A/B).
//! Without --gpu (or with 2d) Android renders in software. Exit code 75:
//! the GPU renderer could not start, before any guest code ran.
//!
//! --refresh-rate is display 0's refresh rate (60 unless given; its EDID,
//! virtio/gpu/edid.rs). The daemon plugs every app display in at the same
//! rate: Android paces displays of different rates unevenly.
//!
//! --shared-dir gives Android a folder on the Mac (virtio-fs, tag
//! avo_shared; virtio/fs.rs), which the daemon mounts at /sdcard/Avo Shared.
//!
//! --init-boot boots another init_boot.img than the image's: the daemon's
//! Magisk-patched copy when root is on (MagiskRoot.swift).
//!
//! --bluetooth starts that controller as Android's Bluetooth controller
//! (bluetooth.rs): Avo's own `rootcanal` (scripts/build-bluetooth.sh), or the
//! Android Emulator's netsimd (Root Canal inside); without it Android's
//! Bluetooth has no controller and stays off.
//!
//! --cellular gives the modem a SIM from the start, registered on a network
//! type (gprs, edge, umts, hspa, lte, nr) with 0..4 signal bars, e.g.
//! `lte:4` (modem.rs); without it there is no SIM until the control socket's
//! `cellular` puts one in.
//!
//! --cpu-clusters presents a phone's CPU ("Emulate this phone's hardware";
//! cpu.rs): `CORESxMIDR@MIN-MAX` per cluster, in kHz, as many cores as
//! --cpus, e.g. `6x513f0011@384000-3532800,2x514f0011@1017600-4320000`.
//! Each vCPU reports its cluster's MIDR, and each cluster is a cpufreq
//! policy with frequencies from MIN to MAX. Without it the vCPUs report the
//! Mac's cores and Android has no cpufreq.
//!
//! --hardware is the phone's hardware name ("Emulate this phone's hardware"):
//! `androidboot.hardware`, which Android keeps as `ro.hardware` and apps read
//! as `Build.HARDWARE` (`qcom` on a Snapdragon phone). Without it Android says
//! the image's `cutf_cvm`. Cuttlefish's own parts are named by their own keys
//! (`androidboot.hardware.egl`, `.gralloc`, `.vulkan`, ...) and its vendor
//! init script is loaded from /vendor/etc/init whatever the name.
//!
//! --no-microphone keeps the Mac's microphone from Android from the start:
//! it records silence, and macOS never asks for the microphone, until the
//! control socket's `microphone on` (virtio/sound.rs).
//!
//! --cameras gives Android cameras the daemon feeds (`back,front`, `back`,
//! `front` or `none`; camera.rs) in place of the image's emulated ones:
//! two virtio-media devices and the external camera HAL. Without it Android
//! has Cuttlefish's emulated back and front cameras.
//!
//! The instance directory keeps the writable disks (super, userdata,
//! metadata, misc, frp; --disks puts all but userdata elsewhere, next to
//! the data they belong with), shared-memory frames (frames/) and the logs:
//! kernel.log (earlycon, then hvc0), console.log (hvc1, the Android shell)
//! and logcat.log (hvc2). The runtime directory holds the sockets:
//! vsock.sock (guest vsock ports, docs/engine.md), control.sock (displays,
//! input, frame events; control.rs) and console.sock (the serial console).
//!
//! The guest's Wi-Fi and mobile data reach the Mac's network through
//! user-mode NAT (net.rs).

mod android;
mod bluetooth;
mod bus;
mod camera;
mod control;
mod cpu;
mod cuttlefish;
mod disk;
mod fdt;
mod frames;
mod gnss;
mod link;
mod machine;
mod memory;
mod modem;
mod net;
mod pause;
mod pci;
mod sensors;
mod serial;
mod shm;
mod sparse;
mod virtio;

use cuttlefish::Options;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;
use virtio::gpu::{GpuMode, Hwc};

const USAGE: &str = "usage: avo-vmm cuttlefish <image dir> [--instance DIR] [--runtime DIR] [--userdata FILE] [--disks DIR] [--cpus N] [--mem MiB] \
[--display WxH] [--density DPI] [--timeout S] [--properties FILE] [--verbose] [--gpu 2d|gfxstream] [--gfxstream-dir DIR] [--bluetooth CONTROLLER] [--init-boot FILE] \
[--hwc client|host] [--shared-dir DIR] [--refresh-rate HZ] [--cellular TYPE:BARS] [--cameras LIST] [--no-microphone] [--cpu-clusters LIST] \
[--hardware NAME] [--exit-on-reboot]";

/// `--gpu`, `--gfxstream-dir` and `--hwc` together.
fn gpu_mode(gpu: Option<&str>, dir: Option<PathBuf>, hwc: Option<&str>) -> Result<GpuMode, String> {
    match gpu {
        None | Some("2d") if dir.is_some() || hwc.is_some() => Err("--gfxstream-dir and --hwc need --gpu gfxstream".into()),
        None | Some("2d") => Ok(GpuMode::TwoD),
        Some("gfxstream") => Ok(GpuMode::Gfxstream {
            dir: dir.ok_or("--gpu gfxstream needs --gfxstream-dir")?,
            hwc: match hwc {
                None | Some("client") => Hwc::Client,
                Some("host") => Hwc::Host,
                Some(other) => return Err(format!("bad --hwc {other} (client or host)")),
            },
        }),
        Some(other) => Err(format!("bad --gpu {other} (2d or gfxstream)")),
    }
}

fn parse(args: &[String]) -> Result<Options, String> {
    let mut images = None;
    let mut instance = None;
    let mut runtime = None;
    let mut userdata = None;
    let mut disks = None;
    let mut cpus = 4;
    let mut memory_mib = 4096;
    let mut display = (720, 1280);
    let mut density = 320;
    let mut timeout = None;
    let mut verbose = false;
    let mut properties = None;
    let mut shared_dir = None;
    let mut bluetooth = None;
    let mut init_boot = None;
    let mut cellular = None;
    let mut cameras = None;
    let mut cpu = None;
    let mut hardware = None;
    let mut microphone = true;
    let mut exit_on_reboot = false;
    let mut refresh_rate = virtio::gpu::edid::DEFAULT_RATE;
    let (mut gpu, mut gfxstream_dir, mut hwc) = (None, None, None);
    let mut i = 0;
    while i < args.len() {
        let value = |i: usize| args.get(i + 1).cloned().ok_or(format!("{} needs a value", args[i]));
        match args[i].as_str() {
            "--instance" => instance = Some(PathBuf::from(value(i)?)),
            "--runtime" => runtime = Some(PathBuf::from(value(i)?)),
            "--userdata" => userdata = Some(PathBuf::from(value(i)?)),
            "--disks" => disks = Some(PathBuf::from(value(i)?)),
            "--cpus" => cpus = value(i)?.parse().map_err(|_| "bad --cpus")?,
            "--mem" => memory_mib = value(i)?.parse().map_err(|_| "bad --mem")?,
            "--density" => density = value(i)?.parse().map_err(|_| "bad --density")?,
            "--display" => {
                let text = value(i)?;
                let (w, h) = text.split_once('x').ok_or("bad --display (WxH)")?;
                display = (w.parse().map_err(|_| "bad --display")?, h.parse().map_err(|_| "bad --display")?);
            }
            "--timeout" => timeout = Some(Duration::from_secs(value(i)?.parse().map_err(|_| "bad --timeout")?)),
            "--properties" => properties = Some(PathBuf::from(value(i)?)),
            "--gpu" => gpu = Some(value(i)?),
            "--gfxstream-dir" => gfxstream_dir = Some(PathBuf::from(value(i)?)),
            "--hwc" => hwc = Some(value(i)?),
            "--shared-dir" => shared_dir = Some(PathBuf::from(value(i)?)),
            "--bluetooth" => bluetooth = Some(PathBuf::from(value(i)?)),
            "--init-boot" => init_boot = Some(PathBuf::from(value(i)?)),
            "--cellular" => {
                let text = value(i)?;
                cellular = modem::Service::parse(&text.split(':').collect::<Vec<_>>()).map_err(|e| format!("bad --cellular: {e}"))?;
            }
            "--cameras" => cameras = Some(camera::Present::parse(&value(i)?).map_err(|e| format!("bad --cameras: {e}"))?),
            "--cpu-clusters" => cpu = Some(cpu::Clusters::parse(&value(i)?).map_err(|e| format!("bad --cpu-clusters: {e}"))?),
            "--hardware" => {
                let name = value(i)?;
                if !is_hardware_name(&name) {
                    return Err(format!("bad --hardware {name} (1-32 of a-z, 0-9, _ and -)"));
                }
                hardware = Some(name);
            }
            "--refresh-rate" => {
                refresh_rate = value(i)?.parse().map_err(|_| "bad --refresh-rate")?;
                if !virtio::gpu::edid::RATE_RANGE.contains(&refresh_rate) {
                    return Err("--refresh-rate out of range".into());
                }
            }
            "--verbose" => {
                verbose = true;
                i += 1;
                continue;
            }
            "--exit-on-reboot" => {
                exit_on_reboot = true;
                i += 1;
                continue;
            }
            "--no-microphone" => {
                microphone = false;
                i += 1;
                continue;
            }
            other if images.is_none() && !other.starts_with("--") => {
                images = Some(PathBuf::from(other));
                i += 1;
                continue;
            }
            other => return Err(format!("unknown argument {other}")),
        }
        i += 2;
    }
    let images = images.ok_or(USAGE)?;
    let gpu = gpu_mode(gpu.as_deref(), gfxstream_dir, hwc.as_deref())?;
    if let Some(clusters) = &cpu {
        if clusters.cores() != cpus {
            return Err(format!("--cpu-clusters has {} cores for --cpus {cpus}", clusters.cores()));
        }
    }
    let instance = instance.unwrap_or_else(|| images.with_file_name("instance"));
    let runtime = runtime.unwrap_or_else(|| instance.clone());
    let disks = disks.unwrap_or_else(|| instance.clone());
    std::fs::create_dir_all(&runtime).map_err(|e| format!("{}: {e}", runtime.display()))?;
    Ok(Options {
        images, instance, disks, runtime, userdata, cpus, memory_mib, display, density, timeout, verbose, properties, gpu, shared_dir,
        bluetooth, init_boot, cellular, cameras, cpu, hardware, microphone, exit_on_reboot, refresh_rate,
    })
}

/// A name `ro.hardware` can hold that is also safe in a bootconfig value and
/// a file name (init imports `init.${ro.hardware}.rc`): what phones use, like
/// `qcom`, `mt6789`, `s5e8835` or `husky`.
fn is_hardware_name(name: &str) -> bool {
    (1..=32).contains(&name.len()) && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
}

/// Raises the soft open-file limit toward the hard one (bounded by
/// kern.maxfilesperproc). launchd starts the daemon with a soft limit near
/// 256, while the guest alone can open thousands of flows (up to 2048 TCP and
/// 1024 UDP), a few descriptors per vsock connection and many virtio-fs
/// handles; at EMFILE `shm_open` fails (a display freezes on resize) and the
/// accept loops would spin. Best effort: a VM that cannot raise it still runs.
fn raise_file_limit() {
    unsafe {
        let mut limit: libc::rlimit = std::mem::zeroed();
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) != 0 {
            return;
        }
        let mut max: libc::c_int = 0;
        let mut size = std::mem::size_of::<libc::c_int>();
        let name = c"kern.maxfilesperproc";
        let ceiling = if libc::sysctlbyname(name.as_ptr(), &mut max as *mut _ as *mut libc::c_void, &mut size, std::ptr::null_mut(), 0) == 0
            && max > 0
        {
            max as libc::rlim_t
        } else {
            10240
        };
        let target = if limit.rlim_max == libc::RLIM_INFINITY { ceiling } else { limit.rlim_max.min(ceiling) };
        if limit.rlim_cur < target {
            limit.rlim_cur = target;
            let _ = libc::setrlimit(libc::RLIMIT_NOFILE, &limit);
        }
    }
}

fn main() -> ExitCode {
    raise_file_limit();
    // The daemon that starts the engine runs at utility QoS, where macOS
    // coalesces timers by tens of milliseconds and schedules behind apps;
    // the engine is the device the user is using. Threads started from here
    // on inherit the class.
    unsafe { libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INITIATED, 0) };
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("cuttlefish") => parse(&args[1..]).and_then(cuttlefish::run),
        Some("vbmeta") if args.len() > 1 => android::vbmeta_chain(Path::new(&args[1])).map(|chain| println!("chained: {chain:?}")),
        _ => Err(USAGE.into()),
    };
    match result {
        // In GPU mode this leaves without static destructors (cuttlefish::exit).
        Ok(()) => cuttlefish::exit(0),
        Err(message) => {
            eprintln!("error: {message}");
            cuttlefish::exit(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disks_follow_the_instance_unless_given() {
        let root = std::env::temp_dir().join(format!("avo-vmm-args-{}", std::process::id()));
        let args = |extra: &[&str]| -> Vec<String> {
            let mut list = vec!["/images".to_string(), "--instance".into(), root.join("instance").display().to_string(),
                                "--runtime".into(), root.join("run").display().to_string()];
            list.extend(extra.iter().map(|s| s.to_string()));
            list
        };
        let options = parse(&args(&[])).unwrap();
        assert_eq!(options.disks, root.join("instance"));
        let options = parse(&args(&["--disks", "/Volumes/SSD/Avo Android Data/cuttlefish"])).unwrap();
        assert_eq!(options.disks, PathBuf::from("/Volumes/SSD/Avo Android Data/cuttlefish"));
        assert_eq!(options.instance, root.join("instance"));
        assert!(parse(&args(&["--disks"])).is_err(), "needs a value");
        assert_eq!(options.shared_dir, None);
        assert_eq!(options.init_boot, None, "the image's own init_boot unless given");
        let rooted = parse(&args(&["--init-boot", "/vm/magisk/init_boot.img"])).unwrap();
        assert_eq!(rooted.init_boot, Some(PathBuf::from("/vm/magisk/init_boot.img")));
        let shared = parse(&args(&["--shared-dir", "/Users/me/Avo Shared"])).unwrap();
        assert_eq!(shared.shared_dir, Some(PathBuf::from("/Users/me/Avo Shared")));
        // Reboots stay in the process unless the daemon asks otherwise.
        assert!(!options.exit_on_reboot);
        assert!(parse(&args(&["--exit-on-reboot"])).unwrap().exit_on_reboot);
        // Display 0 at 60 Hz unless the daemon picks another rate.
        assert_eq!(options.refresh_rate, 60);
        assert_eq!(parse(&args(&["--refresh-rate", "120"])).unwrap().refresh_rate, 120);
        assert!(parse(&args(&["--refresh-rate", "1000"])).is_err(), "out of range");
        assert!(parse(&args(&["--refresh-rate", "fast"])).is_err());
        // No SIM unless asked for one.
        assert_eq!(options.cellular, None);
        let lte = parse(&args(&["--cellular", "lte:4"])).unwrap().cellular;
        assert_eq!(lte, Some(modem::Service { rat: modem::Rat::Lte, bars: 4 }));
        assert!(parse(&args(&["--cellular", "lte"])).is_err());
        assert!(parse(&args(&["--cellular", "lte:9"])).is_err());
        // The Mac's microphone and cameras only when asked for.
        assert!(options.microphone);
        assert!(!parse(&args(&["--no-microphone"])).unwrap().microphone);
        assert_eq!(options.cameras, None);
        let fed = parse(&args(&["--cameras", "back"])).unwrap().cameras;
        assert_eq!(fed, Some(camera::Present([true, false])));
        // The Mac's cores unless a phone's are asked for, as many as --cpus.
        assert_eq!(options.cpu, None);
        let phone = parse(&args(&["--cpus", "8", "--cpu-clusters", "6x513f0011@384000-3532800,2x514f0011@1017600-4320000"])).unwrap();
        assert_eq!(phone.cpu.map(|clusters| clusters.cores()), Some(8));
        assert!(parse(&args(&["--cpu-clusters", "6x513f0011@384000-3532800,2x514f0011@1017600-4320000"])).is_err(), "8 cores, 4 vCPUs");
        assert!(parse(&args(&["--cpu-clusters", "4x513f0011"])).is_err());
        // The image's hardware name unless a phone's is asked for.
        assert_eq!(options.hardware, None);
        assert_eq!(parse(&args(&["--hardware", "qcom"])).unwrap().hardware.as_deref(), Some("qcom"));
        assert!(parse(&args(&["--hardware", "Qcom"])).is_err());
        assert!(parse(&args(&["--hardware", "qcom\"x"])).is_err());
        assert!(parse(&args(&["--hardware", "../qcom"])).is_err());
        assert!(parse(&args(&["--hardware", ""])).is_err());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn gpu_flags_go_together() {
        assert_eq!(gpu_mode(None, None, None), Ok(GpuMode::TwoD));
        assert_eq!(gpu_mode(Some("2d"), None, None), Ok(GpuMode::TwoD));
        let dir = PathBuf::from("/sdk/emulator");
        assert_eq!(
            gpu_mode(Some("gfxstream"), Some(dir.clone()), None),
            Ok(GpuMode::Gfxstream { dir: dir.clone(), hwc: Hwc::Client })
        );
        assert_eq!(gpu_mode(Some("gfxstream"), Some(dir.clone()), Some("host")), Ok(GpuMode::Gfxstream { dir: dir.clone(), hwc: Hwc::Host }));
        assert!(gpu_mode(Some("gfxstream"), None, None).is_err(), "needs the emulator");
        assert!(gpu_mode(None, Some(dir.clone()), None).is_err(), "a directory without GPU mode");
        assert!(gpu_mode(None, None, Some("host")).is_err());
        assert!(gpu_mode(Some("gfxstream"), Some(dir), Some("guest")).is_err());
        assert!(gpu_mode(Some("3d"), None, None).is_err());
    }
}
