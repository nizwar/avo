//! Split virtqueues (virtio 1.2 §2.7), with indirect descriptors.

use crate::memory::GuestMemory;
use std::sync::atomic::{Ordering, fence};

const DESC_F_NEXT: u16 = 1;
const DESC_F_WRITE: u16 = 2;
const DESC_F_INDIRECT: u16 = 4;
const AVAIL_F_NO_INTERRUPT: u16 = 1;
const USED_F_NO_NOTIFY: u16 = 1;

/// The most `Chain::read_all` copies. The lengths are the guest's, and a
/// chain may name the same RAM over and over, so without a limit it could
/// make the host reserve gigabytes. The largest real request is a GPU
/// ATTACH_BACKING list: 4 MiB for a 16384×16384 resource in unmerged 4 KiB
/// pages. Network, vsock and console packets stay within 64 KiB, and sound
/// periods are a few KiB. Block requests do not go through read_all.
const MAX_REQUEST: usize = 16 << 20;

#[derive(Debug, Clone, Copy)]
pub struct Descriptor {
    pub address: u64,
    pub len: u32,
    /// Device-writable (the driver reads it back).
    pub write: bool,
}

/// One request: the head index to return in the used ring and its buffers.
#[derive(Debug)]
pub struct Chain {
    pub head: u16,
    pub descriptors: Vec<Descriptor>,
}

impl Chain {
    pub fn readable(&self) -> impl Iterator<Item = &Descriptor> {
        self.descriptors.iter().filter(|d| !d.write)
    }

    pub fn writable(&self) -> impl Iterator<Item = &Descriptor> {
        self.descriptors.iter().filter(|d| d.write)
    }

    pub fn readable_len(&self) -> usize {
        self.readable().map(|d| d.len as usize).sum()
    }

    pub fn writable_len(&self) -> usize {
        self.writable().map(|d| d.len as usize).sum()
    }

    /// Copies all device-readable bytes, in order; None if they are not
    /// all RAM or there are more than MAX_REQUEST of them.
    pub fn read_all(&self, memory: &GuestMemory) -> Option<Vec<u8>> {
        let total = self.readable_len();
        if total > MAX_REQUEST {
            return None;
        }
        let mut out = vec![0u8; total];
        let mut offset = 0;
        for descriptor in self.readable() {
            let len = descriptor.len as usize;
            if !memory.read(descriptor.address, &mut out[offset..offset + len]) {
                return None;
            }
            offset += len;
        }
        Some(out)
    }

    /// Fills device-writable buffers from `data`; returns the bytes written.
    pub fn write_all(&self, memory: &GuestMemory, data: &[u8]) -> usize {
        let mut written = 0;
        for descriptor in self.writable() {
            if written == data.len() {
                break;
            }
            let len = (descriptor.len as usize).min(data.len() - written);
            if !memory.write(descriptor.address, &data[written..written + len]) {
                break;
            }
            written += len;
        }
        written
    }
}

#[derive(Debug, Clone)]
pub struct Queue {
    pub max_size: u16,
    pub size: u16,
    pub ready: bool,
    pub desc_table: u64,
    pub avail_ring: u64,
    pub used_ring: u64,
    next_avail: u16,
    next_used: u16,
}

impl Queue {
    pub fn new(max_size: u16) -> Queue {
        Queue { max_size, size: max_size, ready: false, desc_table: 0, avail_ring: 0, used_ring: 0, next_avail: 0, next_used: 0 }
    }

    pub fn reset(&mut self) {
        *self = Queue::new(self.max_size);
    }

    pub fn is_valid(&self) -> bool {
        self.ready && self.size > 0 && self.size <= self.max_size && self.size.is_power_of_two()
    }

    /// Takes the next available request, if any.
    pub fn pop(&mut self, memory: &GuestMemory) -> Option<Chain> {
        if !self.is_valid() {
            return None;
        }
        // Ring addresses are the guest's: one that would wrap past 2^64 is no RAM.
        let avail_idx = memory.read_u16(self.avail_ring.checked_add(2)?)?;
        if avail_idx == self.next_avail {
            return None;
        }
        // Read the ring entry only after seeing the index that published it.
        fence(Ordering::Acquire);
        let slot = (self.next_avail % self.size) as u64;
        let head = memory.read_u16(self.avail_ring.checked_add(4 + slot * 2)?)?;
        self.next_avail = self.next_avail.wrapping_add(1);
        let descriptors = self.walk(memory, head)?;
        Some(Chain { head, descriptors })
    }

    fn read_descriptor(memory: &GuestMemory, table: u64, index: u16) -> Option<(u64, u32, u16, u16)> {
        // The other fields are read only once `base` was RAM, so their
        // offsets cannot wrap.
        let base = table.checked_add(index as u64 * 16)?;
        Some((memory.read_u64(base)?, memory.read_u32(base + 8)?, memory.read_u16(base + 12)?, memory.read_u16(base + 14)?))
    }

    fn walk(&self, memory: &GuestMemory, head: u16) -> Option<Vec<Descriptor>> {
        let mut out = Vec::new();
        let mut index = head;
        let mut table = self.desc_table;
        let mut table_size = self.size as u32;
        let mut in_indirect = false;
        for _ in 0..(self.size as u32 * 2 + 64) {
            if index as u32 >= table_size {
                return None;
            }
            let (address, len, flags, next) = Self::read_descriptor(memory, table, index)?;
            if flags & DESC_F_INDIRECT != 0 {
                if in_indirect || len % 16 != 0 || len == 0 {
                    return None;
                }
                table = address;
                table_size = len / 16;
                index = 0;
                in_indirect = true;
                continue;
            }
            out.push(Descriptor { address, len, write: flags & DESC_F_WRITE != 0 });
            if flags & DESC_F_NEXT == 0 {
                return Some(out);
            }
            index = next;
        }
        None // a loop in the descriptor chain
    }

    /// Hands a request back to the driver with `len` bytes written.
    pub fn add_used(&mut self, memory: &GuestMemory, head: u16, len: u32) {
        let slot = (self.next_used % self.size) as u64;
        // An address that would wrap past 2^64 saturates to one the bounds
        // checks refuse, as they refuse any other outside RAM.
        let entry = self.used_ring.saturating_add(4 + slot * 8);
        memory.write_u32(entry, head as u32);
        memory.write_u32(entry.saturating_add(4), len);
        self.next_used = self.next_used.wrapping_add(1);
        // The entry must be visible before the index that publishes it.
        fence(Ordering::Release);
        memory.write_u16(self.used_ring.saturating_add(2), self.next_used);
        fence(Ordering::SeqCst);
    }

    /// False when the driver asked not to be interrupted (VRING_AVAIL_F_NO_INTERRUPT).
    pub fn wants_interrupt(&self, memory: &GuestMemory) -> bool {
        memory.read_u16(self.avail_ring).map(|flags| flags & AVAIL_F_NO_INTERRUPT == 0).unwrap_or(true)
    }

    /// Asks the driver to kick for new requests (`on`), or not to while the
    /// device drains the queue anyway (VRING_USED_F_NO_NOTIFY): each kick is
    /// a vCPU exit. A device that turns kicks on again must look at the queue
    /// once more, for a request that came before the driver saw the flag.
    pub fn set_notifications(&mut self, memory: &GuestMemory, on: bool) {
        if !self.is_valid() {
            return;
        }
        memory.write_u16(self.used_ring, if on { 0 } else { USED_F_NO_NOTIFY });
        // The flag before the next look at the available ring.
        fence(Ordering::SeqCst);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hvf::GuestRegion;

    const RAM: u64 = 0x8000_0000;

    fn memory() -> GuestMemory {
        GuestMemory::new(GuestRegion::new(RAM, 1 << 16).unwrap())
    }

    fn readable(address: u64, len: u32) -> Descriptor {
        Descriptor { address, len, write: false }
    }

    #[test]
    fn read_all_copies_in_order_up_to_max_request() {
        let memory = memory();
        memory.write(RAM, b"head");
        memory.write(RAM + 0x1000, b"tail");
        let written = Descriptor { address: RAM + 0x2000, len: 8, write: true };
        let chain = Chain { head: 0, descriptors: vec![readable(RAM, 4), written, readable(RAM + 0x1000, 4)] };
        assert_eq!(chain.read_all(&memory).as_deref(), Some(&b"headtail"[..]));

        // All of it RAM, the same 64 KiB named again and again.
        let chain = Chain { head: 0, descriptors: vec![readable(RAM, 1 << 16); 256] };
        assert_eq!(chain.read_all(&memory).map(|bytes| bytes.len()), Some(MAX_REQUEST));
        let chain = Chain { head: 0, descriptors: vec![readable(RAM, 1 << 16); 257] };
        assert_eq!(chain.read_all(&memory), None, "one more is refused before anything is reserved");
        let chain = Chain { head: 0, descriptors: vec![readable(RAM, u32::MAX); 2] };
        assert_eq!(chain.read_all(&memory), None);
    }

    #[test]
    fn rings_that_would_wrap_past_the_top_are_not_ram() {
        let memory = memory();
        let mut queue = Queue::new(16);
        queue.ready = true;
        queue.avail_ring = u64::MAX - 1;
        assert!(queue.pop(&memory).is_none());
        // A request published in RAM, in a descriptor table that would wrap.
        queue.avail_ring = RAM;
        memory.write_u16(RAM + 2, 1);
        memory.write_u16(RAM + 4, 1);
        queue.desc_table = u64::MAX - 8;
        assert!(queue.pop(&memory).is_none());
        queue.used_ring = u64::MAX - 3;
        queue.add_used(&memory, 1, 0);
    }
}
