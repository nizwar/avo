//! Virtio devices over the modern PCI transport (virtio 1.2 §4.1), with
//! legacy INTx interrupts routed to GIC SPIs.

pub mod block;
pub mod console;
pub mod fs;
pub mod gpu;
pub mod input;
pub mod media;
pub mod net;
pub mod queue;
pub mod rng;
pub mod sound;
pub mod vsock;

use crate::memory::GuestMemory;
use crate::pci::{Bar, ConfigSpace, PciFunction};
use queue::Queue;
use std::sync::{Arc, Mutex};

pub const VIRTIO_F_VERSION_1: u64 = 1 << 32;
pub const VIRTIO_RING_F_INDIRECT_DESC: u64 = 1 << 28;

pub const TYPE_BLOCK: u16 = 2;
pub const TYPE_CONSOLE: u16 = 3;
pub const TYPE_RNG: u16 = 4;

const STATUS_DRIVER_OK: u8 = 4;
const STATUS_FEATURES_OK: u8 = 8;

/// A virtio device model, independent of the transport.
pub trait VirtioDevice: Send {
    fn device_type(&self) -> u16;
    /// Device feature bits (the transport adds VERSION_1 and INDIRECT_DESC).
    fn features(&self) -> u64;
    fn queue_sizes(&self) -> Vec<u16>;
    /// The device configuration structure.
    fn config(&self) -> Vec<u8>;
    fn write_config(&mut self, _offset: usize, _data: &[u8]) {}
    /// The driver set DRIVER_OK: start serving `queues`.
    fn activate(&mut self, memory: Arc<GuestMemory>, queues: Vec<Queue>, interrupt: Interrupt, features: u64);
    /// The driver added buffers to `queue`.
    fn notify(&mut self, queue: usize);
    /// The driver reset the device; stop using the queues.
    fn reset(&mut self) {}
    /// PCI class code (base, sub, interface).
    fn pci_class(&self) -> u32 {
        0xff_0000
    }
    /// Size of the device's shared memory region (virtio 1.2 §4.1.4.7), if
    /// it has one: the transport puts it in 64-bit BAR 2.
    fn shared_memory_size(&self) -> Option<u64> {
        None
    }
    /// The region's shmid: 1 is what virtio-gpu calls its host-visible
    /// memory, 0 virtio-media's MMAP buffers.
    fn shared_memory_id(&self) -> u8 {
        1
    }
    /// Where the guest placed that region (`None`: not usable right now).
    fn set_shared_memory_base(&mut self, _base: Option<u64>) {}
}

/// The device's interrupt line and ISR status (virtio §4.1.4.5).
#[derive(Clone)]
pub struct Interrupt(Arc<InterruptState>);

struct InterruptState {
    isr: Mutex<u8>,
    line: Box<dyn Fn(bool) + Send + Sync>,
}

impl Interrupt {
    pub fn new(line: impl Fn(bool) + Send + Sync + 'static) -> Interrupt {
        Interrupt(Arc::new(InterruptState { isr: Mutex::new(0), line: Box::new(line) }))
    }

    /// Used buffers are ready.
    pub fn signal_queue(&self) {
        let mut isr = self.0.isr.lock().unwrap();
        *isr |= 1;
        (self.0.line)(true);
    }

    pub fn signal_config(&self) {
        let mut isr = self.0.isr.lock().unwrap();
        *isr |= 2;
        (self.0.line)(true);
    }

    /// Reading the ISR clears it and lowers the line.
    fn take(&self) -> u8 {
        let mut isr = self.0.isr.lock().unwrap();
        let value = *isr;
        *isr = 0;
        (self.0.line)(false);
        value
    }
}

const COMMON: u64 = 0x0000;
const ISR: u64 = 0x1000;
const DEVICE: u64 = 0x2000;
const NOTIFY: u64 = 0x3000;
const BAR_SIZE: u64 = 0x4000;
const NOTIFY_MULTIPLIER: u32 = 4;
const NO_VECTOR: u16 = 0xffff;
/// The BAR of a device's shared memory region.
const SHM_BAR: usize = 2;

/// `virtio_pci_cap64` for shared memory region `id` filling BAR 2.
fn shared_memory_cap(id: u8, length: u64) -> Vec<u8> {
    let mut raw = vec![0x09, 0, 24, 8, SHM_BAR as u8, id, 0, 0];
    raw.extend_from_slice(&0u32.to_le_bytes()); // offset
    raw.extend_from_slice(&(length as u32).to_le_bytes());
    raw.extend_from_slice(&0u32.to_le_bytes()); // offset, high half
    raw.extend_from_slice(&((length >> 32) as u32).to_le_bytes());
    raw
}

/// One virtio device as a PCI function.
pub struct VirtioPci {
    device: Box<dyn VirtioDevice>,
    memory: Arc<GuestMemory>,
    interrupt: Interrupt,
    queues: Vec<Queue>,
    device_feature_select: u32,
    driver_feature_select: u32,
    driver_features: u64,
    status: u8,
    config_generation: u8,
    queue_select: u16,
    active: bool,
}

impl VirtioPci {
    pub fn new(device: Box<dyn VirtioDevice>, memory: Arc<GuestMemory>, interrupt: Interrupt) -> VirtioPci {
        let queues = device.queue_sizes().into_iter().map(Queue::new).collect();
        VirtioPci {
            device,
            memory,
            interrupt,
            queues,
            device_feature_select: 0,
            driver_feature_select: 0,
            driver_features: 0,
            status: 0,
            config_generation: 0,
            queue_select: 0,
            active: false,
        }
    }

    /// PCI configuration space for this device: IDs, BAR 0 and the virtio
    /// capabilities that describe the layout of BAR 0.
    pub fn config_space(&self) -> ConfigSpace {
        let kind = self.device.device_type();
        let mut config = ConfigSpace::new(0x1af4, 0x1040 + kind, self.device.pci_class(), 1, (0x1af4, 0x40));
        config.add_bar(0, Bar { size: BAR_SIZE, prefetchable: false });
        let cap = |cfg_type: u8, offset: u64, length: u64, extra: Option<u32>| {
            let mut raw = vec![0x09, 0, if extra.is_some() { 20 } else { 16 }, cfg_type, 0, 0, 0, 0];
            raw.extend_from_slice(&(offset as u32).to_le_bytes());
            raw.extend_from_slice(&(length as u32).to_le_bytes());
            if let Some(value) = extra {
                raw.extend_from_slice(&value.to_le_bytes());
            }
            raw
        };
        let device_config_len = self.device.config().len().max(4) as u64;
        let mut capabilities = vec![
            cap(1, COMMON, 0x40, None),
            cap(3, ISR, 1, None),
            cap(4, DEVICE, device_config_len, None),
            cap(2, NOTIFY, self.queues.len() as u64 * NOTIFY_MULTIPLIER as u64, Some(NOTIFY_MULTIPLIER)),
        ];
        if let Some(size) = self.device.shared_memory_size() {
            config.add_bar64(SHM_BAR, Bar { size, prefetchable: true });
            capabilities.push(shared_memory_cap(self.device.shared_memory_id(), size));
        }
        config.set_capabilities(&capabilities);
        config
    }

    fn offered_features(&self) -> u64 {
        self.device.features() | VIRTIO_F_VERSION_1 | VIRTIO_RING_F_INDIRECT_DESC
    }

    fn common_snapshot(&self) -> [u8; 0x40] {
        let mut b = [0u8; 0x40];
        let put = |b: &mut [u8; 0x40], at: usize, bytes: &[u8]| b[at..at + bytes.len()].copy_from_slice(bytes);
        let features = self.offered_features();
        let selected = match self.device_feature_select {
            0 => features as u32,
            1 => (features >> 32) as u32,
            _ => 0,
        };
        put(&mut b, 0x00, &self.device_feature_select.to_le_bytes());
        put(&mut b, 0x04, &selected.to_le_bytes());
        put(&mut b, 0x08, &self.driver_feature_select.to_le_bytes());
        let driver = match self.driver_feature_select {
            0 => self.driver_features as u32,
            1 => (self.driver_features >> 32) as u32,
            _ => 0,
        };
        put(&mut b, 0x0c, &driver.to_le_bytes());
        put(&mut b, 0x10, &NO_VECTOR.to_le_bytes());
        put(&mut b, 0x12, &(self.queues.len() as u16).to_le_bytes());
        b[0x14] = self.status;
        b[0x15] = self.config_generation;
        put(&mut b, 0x16, &self.queue_select.to_le_bytes());
        if let Some(queue) = self.queues.get(self.queue_select as usize) {
            put(&mut b, 0x18, &queue.size.to_le_bytes());
            put(&mut b, 0x1a, &NO_VECTOR.to_le_bytes());
            put(&mut b, 0x1c, &(queue.ready as u16).to_le_bytes());
            put(&mut b, 0x1e, &self.queue_select.to_le_bytes());
            put(&mut b, 0x20, &queue.desc_table.to_le_bytes());
            put(&mut b, 0x28, &queue.avail_ring.to_le_bytes());
            put(&mut b, 0x30, &queue.used_ring.to_le_bytes());
        }
        b
    }

    fn write_common(&mut self, offset: u64, data: &[u8]) {
        let mut snapshot = self.common_snapshot();
        let at = offset as usize;
        if at + data.len() > snapshot.len() {
            return;
        }
        snapshot[at..at + data.len()].copy_from_slice(data);
        let u16_at = |i: usize| u16::from_le_bytes([snapshot[i], snapshot[i + 1]]);
        let u32_at = |i: usize| u32::from_le_bytes(snapshot[i..i + 4].try_into().unwrap());
        let u64_at = |i: usize| u64::from_le_bytes(snapshot[i..i + 8].try_into().unwrap());
        match at {
            0x00..=0x03 => self.device_feature_select = u32_at(0x00),
            0x08..=0x0b => self.driver_feature_select = u32_at(0x08),
            0x0c..=0x0f => {
                let value = u32_at(0x0c) as u64;
                match self.driver_feature_select {
                    0 => self.driver_features = (self.driver_features & !0xffff_ffff) | value,
                    1 => self.driver_features = (self.driver_features & 0xffff_ffff) | value << 32,
                    _ => {}
                }
            }
            0x14 => self.write_status(snapshot[0x14]),
            0x16..=0x17 => self.queue_select = u16_at(0x16),
            _ if self.status & STATUS_DRIVER_OK == 0 => {
                let Some(queue) = self.queues.get_mut(self.queue_select as usize) else { return };
                match at {
                    0x18..=0x19 => queue.size = u16_at(0x18),
                    0x1c..=0x1d => queue.ready = u16_at(0x1c) == 1,
                    0x20..=0x27 => queue.desc_table = u64_at(0x20),
                    0x28..=0x2f => queue.avail_ring = u64_at(0x28),
                    0x30..=0x37 => queue.used_ring = u64_at(0x30),
                    _ => {}
                }
            }
            _ => {}
        }
    }

    fn write_status(&mut self, status: u8) {
        if status == 0 {
            self.reset();
            return;
        }
        let mut status = status;
        if status & STATUS_FEATURES_OK != 0 && self.driver_features & !self.offered_features() != 0 {
            status &= !STATUS_FEATURES_OK; // the driver asked for something we never offered
        }
        self.status = status;
        if status & STATUS_DRIVER_OK != 0 && !self.active {
            self.active = true;
            let queues = self.queues.clone();
            self.device.activate(self.memory.clone(), queues, self.interrupt.clone(), self.driver_features);
        }
    }

    fn reset(&mut self) {
        if self.active {
            self.device.reset();
        }
        self.active = false;
        self.status = 0;
        self.driver_features = 0;
        self.device_feature_select = 0;
        self.driver_feature_select = 0;
        self.queue_select = 0;
        for queue in &mut self.queues {
            queue.reset();
        }
        self.interrupt.take();
    }
}

impl Drop for VirtioPci {
    /// The machine goes (a guest reboot, or power off): the device lets go
    /// of the guest as on a reset. Its state outlives it in host-side
    /// threads (control connections, vsock, the network), and with its
    /// queues it would keep the old guest's RAM, connections and audio.
    fn drop(&mut self) {
        if self.active {
            self.device.reset();
        }
    }
}

impl PciFunction for VirtioPci {
    fn bar_read(&mut self, bar: usize, offset: u64, data: &mut [u8]) {
        if bar != 0 {
            // Shared memory with nothing mapped at `offset`.
            data.fill(0);
            return;
        }
        match offset {
            COMMON..0x40 => {
                let snapshot = self.common_snapshot();
                let at = offset as usize;
                let len = data.len().min(snapshot.len() - at);
                data[..len].copy_from_slice(&snapshot[at..at + len]);
            }
            ISR => {
                data.fill(0);
                data[0] = self.interrupt.take();
            }
            DEVICE..NOTIFY => {
                let config = self.device.config();
                let at = (offset - DEVICE) as usize;
                for (i, byte) in data.iter_mut().enumerate() {
                    *byte = config.get(at + i).copied().unwrap_or(0);
                }
            }
            _ => data.fill(0),
        }
    }

    fn bar_write(&mut self, bar: usize, offset: u64, data: &[u8]) {
        if bar != 0 {
            return;
        }
        match offset {
            COMMON..0x40 => self.write_common(offset, data),
            DEVICE..NOTIFY => self.device.write_config((offset - DEVICE) as usize, data),
            NOTIFY..BAR_SIZE => {
                let queue = ((offset - NOTIFY) / NOTIFY_MULTIPLIER as u64) as usize;
                if self.active && queue < self.queues.len() {
                    self.device.notify(queue);
                }
            }
            _ => {}
        }
    }

    fn bar_moved(&mut self, bar: usize, base: Option<u64>) {
        if bar == SHM_BAR {
            self.device.set_shared_memory_base(base);
        }
    }
}

/// State a device keeps once activated: memory, queues and interrupt.
pub struct Active {
    pub memory: Arc<GuestMemory>,
    pub queues: Vec<Queue>,
    pub interrupt: Interrupt,
}

impl Active {
    /// Returns a finished request and interrupts the driver if it wants one.
    pub fn complete(&mut self, queue: usize, head: u16, len: u32) {
        let q = &mut self.queues[queue];
        q.add_used(&self.memory, head, len);
        if q.wants_interrupt(&self.memory) {
            self.interrupt.signal_queue();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Device(Option<u64>);

    impl VirtioDevice for Device {
        fn device_type(&self) -> u16 {
            16
        }
        fn features(&self) -> u64 {
            0
        }
        fn queue_sizes(&self) -> Vec<u16> {
            vec![256, 16]
        }
        fn config(&self) -> Vec<u8> {
            vec![0; 16]
        }
        fn activate(&mut self, _memory: Arc<GuestMemory>, _queues: Vec<Queue>, _interrupt: Interrupt, _features: u64) {}
        fn notify(&mut self, _queue: usize) {}
        fn shared_memory_size(&self) -> Option<u64> {
            self.0
        }
    }

    fn transport(shared_memory: Option<u64>) -> VirtioPci {
        let memory = Arc::new(GuestMemory::new(hvf::GuestRegion::new(0x8000_0000, 1 << 16).unwrap()));
        VirtioPci::new(Box::new(Device(shared_memory)), memory, Interrupt::new(|_| {}))
    }

    /// The capability list, each one's raw bytes.
    fn capabilities(config: &ConfigSpace) -> Vec<Vec<u8>> {
        let bytes: Vec<u8> = (0..64).flat_map(|reg| config.read(reg).to_le_bytes()).collect();
        let mut caps = Vec::new();
        let mut at = bytes[0x34] as usize;
        while at != 0 {
            caps.push(bytes[at..at + bytes[at + 2] as usize].to_vec());
            at = bytes[at + 1] as usize;
        }
        caps
    }

    #[test]
    fn shared_memory_is_bar_2_with_a_64_bit_capability() {
        let config = transport(Some(8 << 30)).config_space();
        let caps = capabilities(&config);
        assert_eq!(caps.len(), 5);
        assert_eq!(caps[4], [0x09, 0, 24, 8, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0]);
        assert_eq!((config.read(6), config.read(7)), (0xc, 0), "64-bit prefetchable BAR 2");
    }

    #[test]
    fn without_shared_memory_the_config_space_is_as_before() {
        let config = transport(None).config_space();
        let caps = capabilities(&config);
        let shape: Vec<(u8, u8)> = caps.iter().map(|c| (c[3], c[2])).collect();
        assert_eq!(shape, [(1, 16), (3, 16), (4, 16), (2, 20)]);
        assert_eq!((4..10).map(|reg| config.read(reg)).collect::<Vec<_>>(), [0, 0, 0, 0, 0, 0]);
    }

    #[test]
    fn shared_memory_without_a_mapping_reads_zeros() {
        let mut pci = transport(Some(8 << 30));
        let mut data = [0xffu8; 16];
        pci.bar_read(2, 0x1000, &mut data);
        assert_eq!(data, [0; 16]);
        pci.bar_write(2, 0, &[1, 2, 3, 4]);
        pci.bar_read(2, 0, &mut data[..4]);
        assert_eq!(data[..4], [0; 4], "writes to it are ignored");
    }

    /// Keeps its queues where a host thread can reach them (an input sender,
    /// a vsock connection), as most devices do.
    struct Shared(Arc<Mutex<Option<Active>>>);

    impl VirtioDevice for Shared {
        fn device_type(&self) -> u16 {
            18
        }
        fn features(&self) -> u64 {
            0
        }
        fn queue_sizes(&self) -> Vec<u16> {
            vec![64]
        }
        fn config(&self) -> Vec<u8> {
            Vec::new()
        }
        fn activate(&mut self, memory: Arc<GuestMemory>, queues: Vec<Queue>, interrupt: Interrupt, _features: u64) {
            *self.0.lock().unwrap() = Some(Active { memory, queues, interrupt });
        }
        fn notify(&mut self, _queue: usize) {}
        fn reset(&mut self) {
            *self.0.lock().unwrap() = None;
        }
    }

    #[test]
    fn a_machine_that_goes_lets_go_of_the_guest_memory() {
        let memory = Arc::new(GuestMemory::new(hvf::GuestRegion::new(0x8000_0000, 1 << 16).unwrap()));
        let held = Arc::new(Mutex::new(None));
        let mut pci = VirtioPci::new(Box::new(Shared(held.clone())), memory.clone(), Interrupt::new(|_| {}));
        pci.bar_write(0, 0x14, &[STATUS_DRIVER_OK]);
        assert!(held.lock().unwrap().is_some());
        drop(pci);
        assert!(held.lock().unwrap().is_none(), "reset as the machine went");
        assert_eq!(Arc::strong_count(&memory), 1, "only the machine's own reference is left");
    }
}
