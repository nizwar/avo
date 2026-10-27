//! The virtual machine: memory map, device tree, interrupt routing, and one
//! thread per vCPU with PSCI for bring-up and power off.
//!
//! Memory map (close to crosvm's aarch64 layout):
//!
//! ```text
//! 0x0001_0000  PCI configuration space (CAM, bus 0)
//! 0x0200_0000  PCI memory window (BARs)
//! 0x0800_0000  GICv3 distributor (Hypervisor.framework)
//! 0x0900_0000  PL011 UART (kernel console)
//! 0x0901_0000  PL031 RTC
//! 0x0904_0000  virtual-cpufreq, a page per vCPU (a phone's CPU only; cpu.rs)
//! 0x0A00_0000  GICv3 redistributors (32 MiB: room for 256 vCPUs)
//! 0x8000_0000  RAM
//! ```

use crate::bus::Bus;
use crate::cpu::{Clusters, VirtualCpufreq};
use crate::fdt::{Fdt, Value};
use crate::memory::GuestMemory;
use crate::pause::{self, Pass, Seat};
use crate::pci::{self, DevFn, PciConfigWindow, PciMemory64Window, PciMemoryWindow, PciRoot, Slot};
use crate::serial::{Pl011, Pl031};
use crate::virtio::{Interrupt, VirtioDevice, VirtioPci};
use hvf::{ExceptionClass, Exit, GicLayout, GuestRegion, Protection, Vcpu, VcpuHandle, Vm, decode_exception};
use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

const RAM_BASE: u64 = 0x8000_0000;
const GIC_DIST: u64 = 0x0800_0000;
const GIC_REDIST: u64 = 0x0A00_0000;
const UART_BASE: u64 = 0x0900_0000;
const RTC_BASE: u64 = 0x0901_0000;
const CPUFREQ_BASE: u64 = 0x0904_0000;
const UART_SPI: u32 = 1;
const RTC_SPI: u32 = 2;
/// PCI device N interrupts on SPI PCI_SPI_BASE + N.
const PCI_SPI_BASE: u32 = 4;
const INITRD_OFFSET: u64 = 0x0800_0000;

const GIC_PHANDLE: u32 = 1;
const CLOCK_PHANDLE: u32 = 2;

pub struct Machine {
    vm: Arc<Vm>,
    gic: GicLayout,
    memory: Arc<GuestMemory>,
    bus: Bus,
    pci: PciRoot,
    pci_spis: Vec<(DevFn, u32)>,
    cpus: usize,
    /// A phone's cores and frequencies for the vCPUs (`present_cpu`).
    clusters: Option<Clusters>,
    waker: Arc<Waker>,
}

/// Wakes vCPUs sleeping on WFI when a device raises an interrupt.
#[derive(Default)]
pub struct Waker {
    generation: Mutex<u64>,
    condvar: Condvar,
}

impl Waker {
    pub fn wake(&self) {
        *self.generation.lock().unwrap() += 1;
        self.condvar.notify_all();
    }

    fn sleep(&self, timeout: Duration) {
        let generation = self.generation.lock().unwrap();
        let start = *generation;
        let _ = self.condvar.wait_timeout_while(generation, timeout, |g| *g == start);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stop {
    PowerOff,
    Reset,
    Timeout,
    /// A vCPU could not go on (an `hv_vcpu_run` error, an unhandled exit, or a
    /// register it could not set): the whole machine stops so the process
    /// exits (cuttlefish.rs `EXIT_VCPU_FAULT`) and the daemon can restart it.
    Failed,
}

impl Machine {
    pub fn new(cpus: usize, memory_mib: usize, serial: Box<dyn Write + Send>) -> Result<Machine, String> {
        let vm = Vm::new(None).map_err(|e| e.to_string())?;
        let (dist_align, redist_align) = Vm::gic_alignment().map_err(|e| e.to_string())?;
        if GIC_DIST % dist_align != 0 || GIC_REDIST % redist_align != 0 {
            return Err(format!("GIC bases misaligned (need {dist_align:#x} / {redist_align:#x})"));
        }
        let gic = vm.create_gic(GIC_DIST, GIC_REDIST).map_err(|e| e.to_string())?;
        if GIC_REDIST + gic.redistributor_region_size > 0x1000_0000 {
            return Err(format!("unexpected GIC redistributor region size {:#x}", gic.redistributor_region_size));
        }
        let ram = GuestRegion::new(RAM_BASE, memory_mib * 1024 * 1024).map_err(|e| e.to_string())?;
        vm.map(&ram, Protection::RWX).map_err(|e| e.to_string())?;
        let memory = Arc::new(GuestMemory::new(ram));

        let mut bus = Bus::default();
        bus.insert(UART_BASE, 0x1000, Arc::new(Pl011::new(serial)));
        bus.insert(RTC_BASE, 0x1000, Arc::new(Pl031::default()));
        Ok(Machine {
            vm: Arc::new(vm),
            gic,
            memory,
            bus,
            pci: PciRoot::new(),
            pci_spis: Vec::new(),
            cpus,
            clusters: None,
            waker: Arc::new(Waker::default()),
        })
    }

    /// Presents a phone's CPU (cpu.rs): each vCPU gets its cluster's MIDR,
    /// and the guest the virtual-cpufreq device with the clusters' tables.
    pub fn present_cpu(&mut self, clusters: Clusters) -> Result<(), String> {
        if clusters.cores() != self.cpus {
            return Err(format!("the CPU clusters have {} cores for {} vCPUs", clusters.cores(), self.cpus));
        }
        let device = VirtualCpufreq::new(&clusters);
        self.bus.insert(CPUFREQ_BASE, device.size(), Arc::new(device));
        self.clusters = Some(clusters);
        Ok(())
    }

    /// Plugs a virtio device into the next PCI slot.
    pub fn add_virtio(&mut self, device: Box<dyn VirtioDevice>) {
        self.add_virtio_functions(vec![device]);
    }

    /// Plugs up to eight virtio devices in as the functions of one PCI
    /// device (bus 0 has only 31 slots). Each function gets its own SPI.
    pub fn add_virtio_functions(&mut self, devices: Vec<Box<dyn VirtioDevice>>) {
        let device = self.pci.next_device().expect("PCI bus full");
        let mut slots = Vec::new();
        for (function, virtio) in devices.into_iter().enumerate() {
            let spi = PCI_SPI_BASE + (device * 8 + function) as u32;
            assert!(spi < self.gic.spi_count, "out of SPIs");
            let intid = self.gic.spi_base + spi;
            let waker = self.waker.clone();
            let interrupt = Interrupt::new(move |level| {
                let _ = hvf::set_spi(intid, level);
                if level {
                    waker.wake();
                }
            });
            let transport = VirtioPci::new(virtio, self.memory.clone(), interrupt);
            let config = transport.config_space();
            slots.push((Slot { config, function: Box::new(transport) }, spi));
        }
        let spis: Vec<u32> = slots.iter().map(|(_, spi)| *spi).collect();
        let placed = self.pci.add_device(slots.into_iter().map(|(slot, _)| slot).collect());
        for (at, spi) in placed.into_iter().zip(spis) {
            assert_eq!(at.device, device);
            self.pci_spis.push((at, spi));
        }
    }

    fn device_tree(&self, cmdline: &str, initrd: (u64, u64)) -> Vec<u8> {
        let split = |v: u64| [(v >> 32) as u32, v as u32];
        let mut seed = [0u8; 64];
        unsafe extern "C" {
            fn arc4random_buf(buf: *mut u8, nbytes: usize);
        }
        unsafe { arc4random_buf(seed.as_mut_ptr(), seed.len()) };
        let seed_cells: Vec<u32> = seed.chunks(4).map(|c| u32::from_be_bytes(c.try_into().unwrap())).collect();

        let mut fdt = Fdt::new();
        fdt.begin("");
        fdt.prop("compatible", Value::Str("linux,dummy-virt"));
        fdt.prop("#address-cells", Value::U32(2));
        fdt.prop("#size-cells", Value::U32(2));
        fdt.prop("interrupt-parent", Value::U32(GIC_PHANDLE));

        fdt.begin("chosen");
        fdt.prop("bootargs", Value::Str(cmdline));
        fdt.prop("stdout-path", Value::Str("/pl011@9000000"));
        fdt.prop("linux,initrd-start", Value::Cells(&split(initrd.0)));
        fdt.prop("linux,initrd-end", Value::Cells(&split(initrd.1)));
        fdt.prop("rng-seed", Value::Cells(&seed_cells[..8]));
        fdt.prop("kaslr-seed", Value::Cells(&seed_cells[8..10]));
        fdt.end();

        fdt.begin("memory@80000000");
        fdt.prop("device_type", Value::Str("memory"));
        fdt.prop("reg", Value::Cells(&[split(RAM_BASE), split(self.memory.size())].concat()));
        fdt.end();

        fdt.begin("cpus");
        fdt.prop("#address-cells", Value::U32(1));
        fdt.prop("#size-cells", Value::U32(0));
        for cpu in 0..self.cpus {
            fdt.begin(&format!("cpu@{cpu}"));
            fdt.prop("device_type", Value::Str("cpu"));
            fdt.prop("compatible", Value::Str("arm,arm-v8"));
            fdt.prop("reg", Value::U32(cpu as u32));
            fdt.prop("enable-method", Value::Str("psci"));
            fdt.end();
        }
        fdt.end();

        if self.clusters.is_some() {
            fdt.begin(&format!("cpufreq@{CPUFREQ_BASE:x}"));
            fdt.prop("compatible", Value::Str("qemu,virtual-cpufreq"));
            fdt.prop("reg", Value::Cells(&[split(CPUFREQ_BASE), split(crate::cpu::PAGE * self.cpus as u64)].concat()));
            fdt.end();
        }

        fdt.begin("psci");
        fdt.prop("compatible", Value::Strs(&["arm,psci-1.0", "arm,psci-0.2"]));
        fdt.prop("method", Value::Str("hvc"));
        fdt.end();

        fdt.begin("intc@8000000");
        fdt.prop("compatible", Value::Str("arm,gic-v3"));
        fdt.prop("#interrupt-cells", Value::U32(3));
        fdt.prop("interrupt-controller", Value::Empty);
        fdt.prop("#redistributor-regions", Value::U32(1));
        fdt.prop("reg", Value::Cells(&[
            split(self.gic.distributor_base), split(self.gic.distributor_size),
            split(self.gic.redistributor_base), split(self.gic.redistributor_region_size),
        ].concat()));
        fdt.prop("phandle", Value::U32(GIC_PHANDLE));
        fdt.end();

        // PPIs: secure phys 13, non-secure phys 14, virtual 11, hypervisor 10.
        fdt.begin("timer");
        fdt.prop("compatible", Value::Str("arm,armv8-timer"));
        fdt.prop("interrupts", Value::Cells(&[1, 13, 0xf08, 1, 14, 0xf08, 1, 11, 0xf08, 1, 10, 0xf08]));
        fdt.prop("always-on", Value::Empty);
        fdt.end();

        fdt.begin("apb-pclk");
        fdt.prop("compatible", Value::Str("fixed-clock"));
        fdt.prop("#clock-cells", Value::U32(0));
        fdt.prop("clock-frequency", Value::U32(24_000_000));
        fdt.prop("clock-output-names", Value::Str("clk24mhz"));
        fdt.prop("phandle", Value::U32(CLOCK_PHANDLE));
        fdt.end();

        fdt.begin("pl011@9000000");
        fdt.prop("compatible", Value::Strs(&["arm,pl011", "arm,primecell"]));
        fdt.prop("reg", Value::Cells(&[split(UART_BASE), split(0x1000)].concat()));
        fdt.prop("interrupts", Value::Cells(&[0, UART_SPI, 4]));
        fdt.prop("clocks", Value::Cells(&[CLOCK_PHANDLE, CLOCK_PHANDLE]));
        fdt.prop("clock-names", Value::Strs(&["uartclk", "apb_pclk"]));
        fdt.end();

        fdt.begin("pl031@9010000");
        fdt.prop("compatible", Value::Strs(&["arm,pl031", "arm,primecell"]));
        fdt.prop("reg", Value::Cells(&[split(RTC_BASE), split(0x1000)].concat()));
        fdt.prop("interrupts", Value::Cells(&[0, RTC_SPI, 4]));
        fdt.prop("clocks", Value::Cells(&[CLOCK_PHANDLE]));
        fdt.prop("clock-names", Value::Str("apb_pclk"));
        fdt.end();

        // Bus 0 behind a CAM host bridge; each device's INTA has its own SPI.
        fdt.begin("pci@10000");
        fdt.prop("compatible", Value::Str("pci-host-cam-generic"));
        fdt.prop("device_type", Value::Str("pci"));
        fdt.prop("#address-cells", Value::U32(3));
        fdt.prop("#size-cells", Value::U32(2));
        fdt.prop("#interrupt-cells", Value::U32(1));
        fdt.prop("bus-range", Value::Cells(&[0, 0]));
        fdt.prop("reg", Value::Cells(&[split(pci::CAM_BASE), split(pci::CAM_SIZE)].concat()));
        let mut ranges = [&[0x0200_0000u32][..], &split(pci::MEM_BASE), &split(pci::MEM_BASE), &split(pci::MEM_SIZE)].concat();
        // MARK: GPU — the 64-bit prefetchable window, only for a 64-bit BAR
        // (the GPU's host-visible memory): Software mode keeps today's tree.
        if self.pci.has_mem64() {
            ranges.extend([&[0x4300_0000u32][..], &split(pci::MEM64_BASE), &split(pci::MEM64_BASE), &split(pci::MEM64_SIZE)].concat());
        }
        fdt.prop("ranges", Value::Cells(&ranges));
        // Keyed by devfn and pin: every function's INTA has its own SPI.
        let mut map = Vec::new();
        for &(at, spi) in &self.pci_spis {
            map.extend_from_slice(&[at.number() << 8, 0, 0, 1, GIC_PHANDLE, 0, spi, 4]);
        }
        fdt.prop("interrupt-map-mask", Value::Cells(&[0xff00, 0, 0, 7]));
        fdt.prop("interrupt-map", Value::Cells(&map));
        fdt.prop("dma-coherent", Value::Empty);
        fdt.end();

        fdt.end();
        fdt.finish()
    }

    /// Boots `kernel` and runs until the guest powers off, resets or `timeout` passes.
    pub fn run(self, kernel: &[u8], initrd: &[u8], cmdline: &str, timeout: Option<Duration>) -> Result<Stop, String> {
        if kernel.len() < 64 || &kernel[56..60] != b"ARM\x64" {
            return Err("not an arm64 kernel Image".into());
        }
        let text_offset = u64::from_le_bytes(kernel[8..16].try_into().unwrap());
        let image_size = u64::from_le_bytes(kernel[16..24].try_into().unwrap()).max(kernel.len() as u64);
        let kernel_address = RAM_BASE + text_offset;
        let initrd_start = RAM_BASE + INITRD_OFFSET.max((text_offset + image_size).next_multiple_of(0x20_0000));
        let initrd_end = initrd_start + initrd.len() as u64;
        let dtb_address = RAM_BASE + self.memory.size() - 2 * 1024 * 1024;
        if initrd_end > dtb_address {
            return Err("not enough RAM for the kernel and initrd".into());
        }
        self.memory.write(kernel_address, kernel);
        self.memory.write(initrd_start, initrd);
        let dtb = self.device_tree(cmdline, (initrd_start, initrd_end));
        self.memory.write(dtb_address, &dtb);
        eprintln!(
            "[vmm] {} vCPUs, {} MiB RAM, kernel {:.1} MiB, initrd {:.1} MiB, {} PCI devices, GIC SPIs {}..{}",
            self.cpus,
            self.memory.size() >> 20,
            kernel.len() as f64 / 1048576.0,
            initrd.len() as f64 / 1048576.0,
            self.pci_spis.len(),
            self.gic.spi_base,
            self.gic.spi_base + self.gic.spi_count
        );

        let pci = Arc::new(self.pci);
        let mut bus = self.bus;
        bus.insert(pci::CAM_BASE, pci::CAM_SIZE, Arc::new(PciConfigWindow(pci.clone())));
        // MARK: GPU — the 64-bit window must fit the VM's guest physical
        // space and stay clear of RAM.
        if pci.has_mem64() {
            let bits = Vm::default_ipa_bits().map_err(|e| e.to_string())?;
            if pci::MEM64_BASE + pci::MEM64_SIZE > 1u64 << bits {
                return Err(format!("the 64-bit PCI window needs more than this Mac's {bits}-bit guest address space"));
            }
            if RAM_BASE + self.memory.size() > pci::MEM64_BASE {
                return Err(format!("at most {} MiB of RAM fit below the 64-bit PCI window", (pci::MEM64_BASE - RAM_BASE) >> 20));
            }
            bus.insert(pci::MEM64_BASE, pci::MEM64_SIZE, Arc::new(PciMemory64Window(pci.clone())));
        }
        bus.insert(pci::MEM_BASE, pci::MEM_SIZE, Arc::new(PciMemoryWindow(pci)));
        if let Some(clusters) = &self.clusters {
            eprintln!("[vmm] CPU clusters {clusters}");
        }
        let machine = Arc::new(Running {
            vm: self.vm.clone(),
            bus,
            cpus: self.cpus,
            midr: (0..self.cpus).filter_map(|index| self.clusters.as_ref()?.midr(index)).collect(),
            power: Mutex::new(Power { ready: 0, on: vec![false; self.cpus], start: vec![None; self.cpus], stop: None }),
            power_changed: Condvar::new(),
            handles: Mutex::new(Vec::new()),
            waker: self.waker.clone(),
            stopped: AtomicBool::new(false),
            exits: AtomicU64::new(0),
            stats: ExitStats::default(),
        });
        {
            let mut power = machine.power.lock().unwrap();
            power.start[0] = Some((kernel_address, dtb_address));
        }
        // Pausing (pause.rs) kicks this machine's vCPUs to the gate.
        let kicker = machine.clone();
        let attachment = pause::GATE.attach(Box::new(move || {
            let handles = kicker.handles.lock().unwrap().clone();
            let _ = VcpuHandle::kick_all(&handles);
            kicker.waker.wake();
        }));
        let started = Instant::now();
        let threads: Vec<_> = (0..self.cpus)
            .map(|index| {
                let machine = machine.clone();
                let seat = attachment.seat();
                std::thread::Builder::new()
                    .name(format!("vcpu{index}"))
                    .spawn(move || machine.vcpu_thread(index, seat))
                    .unwrap()
            })
            .collect();

        // Wait for power off/reset or the timeout.
        let stop = {
            let mut power = machine.power.lock().unwrap();
            loop {
                if let Some(stop) = power.stop.take() {
                    break stop;
                }
                let wait = match timeout {
                    Some(t) => match t.checked_sub(started.elapsed()) {
                        Some(left) => left.min(Duration::from_secs(1)),
                        None => break Stop::Timeout,
                    },
                    None => Duration::from_secs(1),
                };
                power = machine.power_changed.wait_timeout(power, wait).unwrap().0;
            }
        };
        machine.stop_all(stop);
        for thread in threads {
            if let Ok(Err(e)) = thread.join() {
                eprintln!("[vmm] vCPU error: {e}");
            }
        }
        drop(attachment);
        eprintln!(
            "[vmm] stopped ({stop:?}) after {:.1?}, {} exits ({})",
            started.elapsed(),
            machine.exits.load(Ordering::Relaxed),
            machine.stats.summary()
        );
        Ok(stop)
    }
}

struct Power {
    ready: usize,
    on: Vec<bool>,
    /// Pending CPU_ON: (entry point, context id).
    start: Vec<Option<(u64, u64)>>,
    stop: Option<Stop>,
}

struct Running {
    vm: Arc<Vm>,
    bus: Bus,
    cpus: usize,
    /// Each vCPU's MIDR_EL1 (a phone's CPU); empty: the Mac's.
    midr: Vec<u32>,
    power: Mutex<Power>,
    power_changed: Condvar,
    handles: Mutex<Vec<VcpuHandle>>,
    waker: Arc<Waker>,
    /// Set by `stop_all`: also lets go of vCPUs parked by a pause.
    stopped: AtomicBool,
    exits: AtomicU64,
    stats: ExitStats,
}

#[derive(Default)]
struct ExitStats {
    mmio: AtomicU64,
    hvc: AtomicU64,
    wfi: AtomicU64,
    vtimer: AtomicU64,
    sysreg: AtomicU64,
    canceled: AtomicU64,
    /// Accesses without syndrome skipped in the 64-bit window (GPU mode).
    skipped: AtomicU64,
}

impl ExitStats {
    fn summary(&self) -> String {
        let l = |c: &AtomicU64| c.load(Ordering::Relaxed);
        let skipped = match l(&self.skipped) {
            0 => String::new(),
            n => format!(", skipped {n}"),
        };
        format!(
            "mmio {}, hvc {}, wfi {}, vtimer {}, sysreg {}, canceled {}{skipped}",
            l(&self.mmio), l(&self.hvc), l(&self.wfi), l(&self.vtimer), l(&self.sysreg), l(&self.canceled)
        )
    }
}

const PSCI_VERSION: u32 = 0x8400_0000;
const PSCI_CPU_OFF: u32 = 0x8400_0002;
const PSCI_CPU_ON: u32 = 0xc400_0003;
const PSCI_CPU_ON_32: u32 = 0x8400_0003;
const PSCI_AFFINITY_INFO: u32 = 0xc400_0004;
const PSCI_AFFINITY_INFO_32: u32 = 0x8400_0004;
const PSCI_MIGRATE_INFO_TYPE: u32 = 0x8400_0006;
const PSCI_SYSTEM_OFF: u32 = 0x8400_0008;
const PSCI_SYSTEM_RESET: u32 = 0x8400_0009;
const PSCI_FEATURES: u32 = 0x8400_000a;

enum Psci {
    Return(i64),
    Off,
    Stop(Stop),
}

impl Running {
    fn stop_all(&self, reason: Stop) {
        {
            let mut power = self.power.lock().unwrap();
            if power.stop.is_none() {
                power.stop = Some(reason);
            }
        }
        // Before the kick, which reaches only vCPUs in the guest: the others
        // see this before they run again (Seat::before_run).
        self.stopped.store(true, Ordering::SeqCst);
        self.power_changed.notify_all();
        self.waker.wake();
        let handles = self.handles.lock().unwrap().clone();
        let _ = VcpuHandle::kick_all(&handles);
        pause::GATE.wake();
    }

    fn stopping(&self) -> bool {
        self.power.lock().unwrap().stop.is_some()
    }

    fn vcpu_thread(self: Arc<Self>, index: usize, mut seat: Seat<'static>) -> Result<(), String> {
        let result = self.run_vcpu_thread(index, &mut seat);
        // A vCPU that failed (rather than powered off or hit a machine-wide
        // stop) ends the whole machine, so the run loop breaks and the process
        // exits instead of waiting forever with one vCPU thread gone.
        if result.is_err() {
            self.stop_all(Stop::Failed);
        }
        result
    }

    fn run_vcpu_thread(&self, index: usize, seat: &mut Seat<'static>) -> Result<(), String> {
        let vcpu = Vcpu::new(&self.vm).map_err(|e| e.to_string())?;
        // CNTVCT = host counter - offset; a pause adds what the guest did not see.
        let offset = vcpu.vtimer_offset().map_err(|e| e.to_string())?;
        // Affinity must be final before any vCPU runs (Hypervisor.framework GIC).
        vcpu.set_sys_reg(hvf::HV_SYS_REG_MPIDR_EL1, 1 << 31 | index as u64).map_err(|e| e.to_string())?;
        if let Some(&midr) = self.midr.get(index) {
            // Not worth a machine that never starts: the vCPU stays the Mac's core.
            if let Err(e) = vcpu.set_sys_reg(hvf::HV_SYS_REG_MIDR_EL1, midr as u64) {
                eprintln!("[vmm] vCPU {index}: MIDR {midr:#010x} not set ({e}), it reports the Mac's core");
            }
        }
        self.handles.lock().unwrap().push(vcpu.handle());
        {
            let mut power = self.power.lock().unwrap();
            power.ready += 1;
            self.power_changed.notify_all();
            while power.ready < self.cpus && power.stop.is_none() {
                power = self.power_changed.wait(power).unwrap();
            }
        }
        let mut vcpu = vcpu;
        loop {
            // Wait for CPU_ON (the boot vCPU starts right away).
            let (entry, context) = {
                let mut power = self.power.lock().unwrap();
                loop {
                    if power.stop.is_some() {
                        return Ok(());
                    }
                    if let Some(start) = power.start[index].take() {
                        power.on[index] = true;
                        break start;
                    }
                    power = self.power_changed.wait(power).unwrap();
                }
            };
            let e = |r: hvf::Result<()>| r.map_err(|e| e.to_string());
            e(vcpu.set_pc(entry))?;
            e(vcpu.set_x(0, context))?;
            for register in 1..4 {
                e(vcpu.set_x(register, 0))?;
            }
            e(vcpu.set_cpsr(0x3c5))?; // EL1h, DAIF masked
            match self.run_vcpu(&mut vcpu, index, seat, offset)? {
                Some(stop) => {
                    self.stop_all(stop);
                    return Ok(());
                }
                None => {
                    // CPU_OFF: wait for the next CPU_ON.
                    seat.off();
                    self.power.lock().unwrap().on[index] = false;
                    self.power_changed.notify_all();
                }
            }
        }
    }

    /// Runs until CPU_OFF (None) or a machine-wide stop.
    fn run_vcpu(&self, vcpu: &mut Vcpu, index: usize, seat: &mut Seat, offset: u64) -> Result<Option<Stop>, String> {
        let e = |r: hvf::Result<()>| r.map_err(|e| e.to_string());
        loop {
            match seat.before_run(&self.stopped) {
                Pass::Run => {}
                Pass::Shift(frozen) => e(vcpu.set_vtimer_offset(offset.wrapping_add(frozen)))?,
                Pass::Stop => return Ok(Some(Stop::PowerOff)),
            }
            let exit = vcpu.run().map_err(|e| e.to_string())?;
            self.exits.fetch_add(1, Ordering::Relaxed);
            match exit {
                Exit::Exception { syndrome, physical_address, .. } => match decode_exception(syndrome, physical_address) {
                    ExceptionClass::Mmio(access) => {
                        self.stats.mmio.fetch_add(1, Ordering::Relaxed);
                        let size = access.size as usize;
                        if access.write {
                            let value = vcpu.x(access.register).map_err(|e| e.to_string())?;
                            self.bus.write(access.address, &value.to_le_bytes()[..size]);
                        } else {
                            let mut data = [0u8; 8];
                            self.bus.read(access.address, &mut data[..size]);
                            let mut value = u64::from_le_bytes(data);
                            if access.sign_extend && size < 8 {
                                let shift = 64 - size * 8;
                                value = (((value << shift) as i64) >> shift) as u64;
                                if !access.sixty_four {
                                    value &= 0xffff_ffff;
                                }
                            }
                            e(vcpu.set_x(access.register, value))?;
                        }
                        e(vcpu.advance_pc())?;
                    }
                    ExceptionClass::Hvc(_) => match self.psci(vcpu, index)? {
                        Psci::Return(value) => e(vcpu.set_x(0, value as u64))?,
                        Psci::Off => return Ok(None),
                        Psci::Stop(stop) => return Ok(Some(stop)),
                    },
                    ExceptionClass::Smc(_) => {
                        e(vcpu.set_x(0, u64::MAX))?; // SMCCC: NOT_SUPPORTED
                        e(vcpu.advance_pc())?;
                    }
                    ExceptionClass::WaitForInterrupt { .. } => {
                        self.stats.wfi.fetch_add(1, Ordering::Relaxed);
                        self.wait_for_interrupt(vcpu)?;
                        e(vcpu.advance_pc())?;
                    }
                    ExceptionClass::SystemRegister { read, register, .. } => {
                        self.stats.sysreg.fetch_add(1, Ordering::Relaxed);
                        if read {
                            e(vcpu.set_x(register, 0))?;
                        }
                        e(vcpu.advance_pc())?;
                    }
                    // MARK: GPU — a load/store pair or vector access to a part
                    // of the GPU's host-visible BAR with no memory behind it
                    // (a blob the guest still touches after unmapping it)
                    // cannot be emulated; skip it rather than stop Android.
                    ExceptionClass::DataAbortWithoutSyndrome { address }
                        if (pci::MEM64_BASE..pci::MEM64_BASE + pci::MEM64_SIZE).contains(&address) =>
                    {
                        if self.stats.skipped.fetch_add(1, Ordering::Relaxed) == 0 {
                            eprintln!("[vmm] vCPU {index}: skipped an access without syndrome at {address:#x} (unmapped GPU memory)");
                        }
                        e(vcpu.advance_pc())?;
                    }
                    other => {
                        return Err(format!("vCPU {index}: unhandled {other:?} at pc {:#x}", vcpu.pc().unwrap_or(0)));
                    }
                },
                Exit::VtimerActivated => {
                    self.stats.vtimer.fetch_add(1, Ordering::Relaxed);
                    e(vcpu.set_vtimer_mask(false))?;
                }
                Exit::Canceled => {
                    self.stats.canceled.fetch_add(1, Ordering::Relaxed);
                    if self.stopping() {
                        return Ok(Some(Stop::PowerOff));
                    }
                }
                Exit::Unknown(reason) => return Err(format!("vCPU {index}: unknown exit reason {reason}")),
            }
        }
    }

    /// WFI that reached user space: sleep until the virtual timer is due, a
    /// device interrupt arrives, or 1 ms passes (IPIs are delivered in-kernel).
    fn wait_for_interrupt(&self, vcpu: &Vcpu) -> Result<(), String> {
        let control = vcpu.sys_reg(hvf::HV_SYS_REG_CNTV_CTL_EL0).map_err(|e| e.to_string())?;
        let mut timeout = Duration::from_millis(1);
        if control & 1 != 0 && control & 2 == 0 {
            let compare = vcpu.sys_reg(hvf::HV_SYS_REG_CNTV_CVAL_EL0).map_err(|e| e.to_string())?;
            let offset = vcpu.vtimer_offset().map_err(|e| e.to_string())?;
            let now = mach_time().wrapping_sub(offset);
            if compare <= now {
                return Ok(());
            }
            timeout = timeout.min(ticks_to_duration(compare - now));
        }
        self.waker.sleep(timeout);
        Ok(())
    }

    fn psci(&self, vcpu: &Vcpu, index: usize) -> Result<Psci, String> {
        self.stats.hvc.fetch_add(1, Ordering::Relaxed);
        let x = |i| vcpu.x(i).map_err(|e| e.to_string());
        let function = x(0)? as u32;
        Ok(match function {
            PSCI_VERSION => Psci::Return(0x0001_0000),
            PSCI_SYSTEM_OFF => Psci::Stop(Stop::PowerOff),
            PSCI_SYSTEM_RESET => Psci::Stop(Stop::Reset),
            PSCI_MIGRATE_INFO_TYPE => Psci::Return(2),
            PSCI_CPU_OFF => Psci::Off,
            PSCI_CPU_ON | PSCI_CPU_ON_32 => {
                let target = (x(1)? & 0xff) as usize;
                let (entry, context) = (x(2)?, x(3)?);
                let mut power = self.power.lock().unwrap();
                if target >= self.cpus {
                    Psci::Return(-2) // INVALID_PARAMETERS
                } else if power.on[target] || power.start[target].is_some() {
                    Psci::Return(-4) // ALREADY_ON
                } else {
                    power.start[target] = Some((entry, context));
                    self.power_changed.notify_all();
                    Psci::Return(0)
                }
            }
            PSCI_AFFINITY_INFO | PSCI_AFFINITY_INFO_32 => {
                let target = (x(1)? & 0xff) as usize;
                let power = self.power.lock().unwrap();
                match power.on.get(target) {
                    Some(true) => Psci::Return(0),
                    Some(false) => Psci::Return(1),
                    None => Psci::Return(-2),
                }
            }
            PSCI_FEATURES => {
                let queried = x(1)? as u32;
                Psci::Return(match queried {
                    PSCI_VERSION | PSCI_CPU_OFF | PSCI_CPU_ON | PSCI_CPU_ON_32 | PSCI_AFFINITY_INFO | PSCI_AFFINITY_INFO_32
                    | PSCI_MIGRATE_INFO_TYPE | PSCI_SYSTEM_OFF | PSCI_SYSTEM_RESET | PSCI_FEATURES => 0,
                    _ => -1,
                })
            }
            _ => {
                let _ = index;
                Psci::Return(-1)
            }
        })
    }
}

unsafe extern "C" {
    fn mach_absolute_time() -> u64;
}

fn mach_time() -> u64 {
    unsafe { mach_absolute_time() }
}

/// The counter runs at 24 MHz on Apple Silicon.
fn ticks_to_duration(ticks: u64) -> Duration {
    Duration::from_nanos(ticks.saturating_mul(125) / 3)
}

#[cfg(test)]
mod pause_tests {
    use super::*;
    use crate::bus::MmioHandler;

    const PROBE: u64 = 0x0903_0000;
    /// vCPU 0 starts vCPU 1 (PSCI CPU_ON), then each stores CNTVCT_EL0 to
    /// its word at PROBE, over and over:
    ///
    /// ```text
    ///     movz x24, #0x0903, lsl #16; movz x0, #3; movk x0, #0xc400, lsl #16
    ///     mov x1, #1; adr x2, secondary; mov x3, #0; hvc #0; b loop
    /// secondary:
    ///     movz x24, #0x0903, lsl #16; add x24, x24, #8
    /// loop:
    ///     mrs x23, cntvct_el0; str x23, [x24]; b loop
    /// ```
    const GUEST: [u32; 13] = [
        0xd2a1_2078, 0xd280_0060, 0xf2b8_8000, 0xd280_0021, 0x1000_0082, 0xd280_0003, 0xd400_0002, 0x1400_0003,
        0xd2a1_2078, 0x9100_2318, 0xd53b_e057, 0xf900_0317, 0x17ff_fffe,
    ];

    /// Per vCPU: stores seen, the last counter value, and host minus guest counter.
    #[derive(Default)]
    struct Probe {
        seen: Mutex<[(u64, u64, u64); 2]>,
        backwards: AtomicBool,
    }

    impl MmioHandler for Probe {
        fn read(&self, _: u64, _: &mut [u8]) {}

        fn write(&self, offset: u64, data: &[u8]) {
            let cpu = (offset / 8) as usize;
            let mut bytes = [0u8; 8];
            bytes[..data.len().min(8)].copy_from_slice(&data[..data.len().min(8)]);
            let value = u64::from_le_bytes(bytes);
            let host = mach_time();
            let mut seen = self.seen.lock().unwrap();
            if let Some(entry) = seen.get_mut(cpu) {
                if value < entry.1 {
                    self.backwards.store(true, Ordering::SeqCst);
                }
                *entry = (entry.0 + 1, value, host.wrapping_sub(value));
            }
        }
    }

    fn ms(ticks: u64) -> f64 {
        ticks as f64 / 24_000.0
    }

    /// One VM at a time: Hypervisor.framework allows one per process, and a
    /// pause stops every machine's vCPUs.
    static ONE_VM: Mutex<()> = Mutex::new(());

    /// Runs `guest` (after an arm64 Image header) on `machine` with PROBE.
    fn start(mut machine: Machine, guest: &[u32], timeout: Duration) -> (Arc<Probe>, std::thread::JoinHandle<Result<Stop, String>>) {
        let probe = Arc::new(Probe::default());
        machine.bus.insert(PROBE, 0x1000, probe.clone());
        let mut kernel = vec![0u8; 64];
        kernel[..4].copy_from_slice(&0x1400_0010u32.to_le_bytes()); // b +64
        kernel[16..24].copy_from_slice(&(64 + 4 * guest.len() as u64).to_le_bytes());
        kernel[56..60].copy_from_slice(b"ARM\x64");
        kernel.extend(guest.iter().flat_map(|word| word.to_le_bytes()));
        (probe, std::thread::spawn(move || machine.run(&kernel, &[], "", Some(timeout))))
    }

    #[test]
    fn a_pause_stops_the_vcpus_and_their_counter() {
        let _vm = ONE_VM.lock().unwrap_or_else(|e| e.into_inner());
        let machine = Machine::new(2, 256, Box::new(std::io::sink())).unwrap();
        let (probe, runner) = start(machine, &GUEST, Duration::from_secs(3));

        std::thread::sleep(Duration::from_millis(300));
        if runner.is_finished() {
            panic!("the guest stopped: {:?}", runner.join().unwrap());
        }
        let before = *probe.seen.lock().unwrap();
        assert!(before.iter().all(|cpu| cpu.0 > 100), "both vCPUs run: {before:?}");
        // Both vCPUs start with the same counter (HVF's offset at creation).
        assert!(ms(before[0].2.abs_diff(before[1].2)) < 1.0, "{before:?}");
        eprintln!("HVF's default vtimer offset: host - guest = {:.1} ms", ms(before[0].2));

        assert_eq!(pause::GATE.pause(Duration::from_secs(2)), Ok(true));
        let paused = *probe.seen.lock().unwrap();
        std::thread::sleep(Duration::from_millis(400));
        assert_eq!(*probe.seen.lock().unwrap(), paused, "nothing runs while paused");
        let stood = pause::GATE.resume().unwrap();
        assert!(stood >= Duration::from_millis(400));

        std::thread::sleep(Duration::from_millis(200));
        let after = *probe.seen.lock().unwrap();
        assert!(after.iter().zip(&paused).all(|(a, p)| a.0 > p.0), "both run again: {after:?}");
        // The counter stood still for exactly the pause: the guest is that
        // much further behind the host, on both vCPUs, and never went back.
        let shifted = ms(after[0].2 - before[0].2);
        assert!((shifted - stood.as_secs_f64() * 1000.0).abs() < 5.0, "shifted {shifted:.1} ms for a {stood:?} pause");
        assert!(ms(after[0].2.abs_diff(after[1].2)) < 1.0, "{after:?}");
        assert!(!probe.backwards.load(Ordering::SeqCst));

        // The machine stops (its timeout) while paused: the vCPUs let go.
        assert_eq!(pause::GATE.pause(Duration::from_secs(2)), Ok(true));
        assert_eq!(runner.join().unwrap(), Ok(Stop::Timeout));
        pause::GATE.resume();
    }

    /// A phone's CPU: each vCPU reads its cluster's MIDR_EL1 (what the
    /// guest's /proc/cpuinfo shows), the same loop storing it.
    #[test]
    fn each_vcpu_reports_its_clusters_core() {
        let _vm = ONE_VM.lock().unwrap_or_else(|e| e.into_inner());
        let mut machine = Machine::new(2, 256, Box::new(std::io::sink())).unwrap();
        let clusters = Clusters::parse("1x410fd801@300000-2265600,1x410fd821@576000-3302400").unwrap();
        machine.present_cpu(clusters).unwrap();
        let mut guest = GUEST;
        guest[10] = 0xd538_0017; // mrs x23, midr_el1
        let (probe, runner) = start(machine, &guest, Duration::from_millis(500));
        assert_eq!(runner.join().unwrap(), Ok(Stop::Timeout));
        let seen = *probe.seen.lock().unwrap();
        assert!(seen.iter().all(|cpu| cpu.0 > 0), "both vCPUs ran: {seen:?}");
        assert_eq!([seen[0].1, seen[1].1], [0x410f_d801, 0x410f_d821]);
        // As many cores as vCPUs, or none.
        let mut two = Machine::new(2, 256, Box::new(std::io::sink())).unwrap();
        assert!(two.present_cpu(Clusters::parse("8x410fd801@300000-2265600").unwrap()).is_err());
    }
}
