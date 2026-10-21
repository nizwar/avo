//! A phone's CPU for the guest (`--cpu-clusters`, "Emulate this phone's
//! hardware"): each vCPU's MIDR_EL1, so /proc/cpuinfo and
//! /sys/devices/system/cpu/cpu*/regs name the phone's cores, and the
//! virtual-cpufreq device (drivers/cpufreq/virtual-cpufreq.c, a module in
//! the image), so each cluster is one cpufreq policy with the phone's
//! frequencies, as games and benchmarks read them.
//!
//! The frequencies are names only. A vCPU runs as fast as the Mac lets it:
//! what the guest asks for (set_perf) changes nothing, and the current
//! frequency always reads as the top of the table, so the scheduler's
//! frequency invariance sees every vCPU at full speed, as without the
//! device. The device tree gives no capacity-dmips-mhz either: the vCPUs
//! are equals, and the scheduler keeps treating them so.
//!
//! Registers, a page per vCPU (offset = vCPU × 0x1000, 32 bits each):
//!
//! ```text
//! 0x00  cur_perf     the current frequency in kHz (the table's top)
//! 0x04  set_perf     the frequency the guest wants (ignored)
//! 0x08  perftbl_len  entries in the frequency table (1..64)
//! 0x0c  perftbl_sel  the entry perftbl_rd reads
//! 0x10  perftbl_rd   that entry, in kHz
//! 0x14  perf_domain  the vCPU's cluster: vCPUs of one cluster share a policy
//! ```

use crate::bus::MmioHandler;
use std::sync::atomic::{AtomicU32, Ordering};

/// Each vCPU's page of registers.
pub const PAGE: u64 = 0x1000;

const CUR_PERF: u64 = 0x0;
const PERFTBL_LEN: u64 = 0x8;
const PERFTBL_SEL: u64 = 0xc;
const PERFTBL_RD: u64 = 0x10;
const PERF_DOMAIN: u64 = 0x14;

/// The driver takes tables of at most 64 entries.
const MAX_ENTRIES: u32 = 64;
/// About this far apart, as phones' tables are.
const STEP_KHZ: u32 = 200_000;
/// Entries between the ends land on 19.2 MHz steps, like Qualcomm's.
const GRID_KHZ: u32 = 19_200;

/// A set of identical cores: `<cores>x<MIDR in hex>@<min kHz>-<max kHz>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cluster {
    pub cores: usize,
    pub midr: u32,
    pub min_khz: u32,
    pub max_khz: u32,
}

impl Cluster {
    fn parse(text: &str) -> Result<Cluster, String> {
        let bad = || format!("{text}: expected CORESxMIDR@MIN-MAX (e.g. 2x410fd801@300000-2265600)");
        let (cores, rest) = text.split_once('x').ok_or_else(bad)?;
        let (midr, range) = rest.split_once('@').ok_or_else(bad)?;
        let (min, max) = range.split_once('-').ok_or_else(bad)?;
        let cluster = Cluster {
            cores: cores.parse().map_err(|_| bad())?,
            midr: u32::from_str_radix(midr.trim_start_matches("0x"), 16).map_err(|_| bad())?,
            min_khz: min.parse().map_err(|_| bad())?,
            max_khz: max.parse().map_err(|_| bad())?,
        };
        if cluster.cores == 0 {
            return Err(format!("{text}: a cluster has at least one core"));
        }
        if cluster.min_khz == 0 || cluster.min_khz >= cluster.max_khz {
            return Err(format!("{text}: the lowest frequency must be above 0 and below the highest"));
        }
        Ok(cluster)
    }

    /// The cluster's frequencies, lowest first: both ends, and between them
    /// steps of about 200 MHz.
    pub fn table(&self) -> Vec<u32> {
        let span = self.max_khz - self.min_khz;
        let steps = ((span + STEP_KHZ / 2) / STEP_KHZ).clamp(1, MAX_ENTRIES - 1);
        let mut table = vec![self.min_khz];
        for step in 1..steps {
            let khz = self.min_khz + (span as u64 * step as u64 / steps as u64) as u32;
            let khz = (khz + GRID_KHZ / 2) / GRID_KHZ * GRID_KHZ;
            if khz > table[table.len() - 1] && khz < self.max_khz {
                table.push(khz);
            }
        }
        table.push(self.max_khz);
        table
    }
}

/// The clusters, in vCPU order (vCPU 0 is the first cluster's first core).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Clusters(pub Vec<Cluster>);

impl Clusters {
    /// `6x513f0011@384000-3532800,2x514f0011@1017600-4320000`.
    pub fn parse(text: &str) -> Result<Clusters, String> {
        let clusters = text.split(',').map(Cluster::parse).collect::<Result<Vec<_>, _>>()?;
        Ok(Clusters(clusters))
    }

    pub fn cores(&self) -> usize {
        self.0.iter().map(|c| c.cores).sum()
    }

    /// vCPU `index`'s cluster number and cluster.
    fn of(&self, index: usize) -> Option<(usize, &Cluster)> {
        let mut first = 0;
        for (number, cluster) in self.0.iter().enumerate() {
            if index < first + cluster.cores {
                return Some((number, cluster));
            }
            first += cluster.cores;
        }
        None
    }

    pub fn midr(&self, index: usize) -> Option<u32> {
        self.of(index).map(|(_, cluster)| cluster.midr)
    }
}

/// As `--cpu-clusters` takes them.
impl std::fmt::Display for Clusters {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        for (number, c) in self.0.iter().enumerate() {
            let comma = if number > 0 { "," } else { "" };
            write!(f, "{comma}{}x{:08x}@{}-{}", c.cores, c.midr, c.min_khz, c.max_khz)?;
        }
        Ok(())
    }
}

/// The virtual-cpufreq registers of every vCPU.
pub struct VirtualCpufreq {
    /// Per vCPU: its cluster number and frequency table.
    cpus: Vec<(u32, Vec<u32>)>,
    /// Per vCPU: the entry perftbl_rd reads.
    selected: Vec<AtomicU32>,
}

impl VirtualCpufreq {
    pub fn new(clusters: &Clusters) -> VirtualCpufreq {
        let cpus: Vec<_> = (0..clusters.cores())
            .filter_map(|index| clusters.of(index))
            .map(|(number, cluster)| (number as u32, cluster.table()))
            .collect();
        let selected = cpus.iter().map(|_| AtomicU32::new(0)).collect();
        VirtualCpufreq { cpus, selected }
    }

    /// The size of the register range: a page per vCPU.
    pub fn size(&self) -> u64 {
        PAGE * self.cpus.len() as u64
    }
}

impl MmioHandler for VirtualCpufreq {
    fn read(&self, offset: u64, data: &mut [u8]) {
        let index = (offset / PAGE) as usize;
        let value = match (self.cpus.get(index), offset % PAGE) {
            (Some((_, table)), CUR_PERF) => table[table.len() - 1],
            (Some((_, table)), PERFTBL_LEN) => table.len() as u32,
            (Some(_), PERFTBL_SEL) => self.selected[index].load(Ordering::Relaxed),
            (Some((_, table)), PERFTBL_RD) => {
                table.get(self.selected[index].load(Ordering::Relaxed) as usize).copied().unwrap_or(0)
            }
            (Some((domain, _)), PERF_DOMAIN) => *domain,
            _ => 0,
        };
        let bytes = value.to_le_bytes();
        for (i, byte) in data.iter_mut().enumerate() {
            *byte = bytes.get(i).copied().unwrap_or(0);
        }
    }

    fn write(&self, offset: u64, data: &[u8]) {
        let index = (offset / PAGE) as usize;
        if offset % PAGE == PERFTBL_SEL && index < self.selected.len() {
            let mut bytes = [0u8; 4];
            let n = data.len().min(4);
            bytes[..n].copy_from_slice(&data[..n]);
            self.selected[index].store(u32::from_le_bytes(bytes), Ordering::Relaxed);
        }
        // set_perf and anything else: the Mac decides how fast a vCPU runs.
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The OnePlus 13 (SM8750): six Oryon Phoenix M cores and two Phoenix L.
    const ONEPLUS_13: &str = "6x513f0011@384000-3532800,2x514f0011@1017600-4320000";

    fn read(device: &VirtualCpufreq, offset: u64) -> u32 {
        let mut data = [0u8; 4];
        device.read(offset, &mut data);
        u32::from_le_bytes(data)
    }

    fn write(device: &VirtualCpufreq, offset: u64, value: u32) {
        device.write(offset, &value.to_le_bytes());
    }

    #[test]
    fn clusters_name_each_vcpus_core() {
        let clusters = Clusters::parse(ONEPLUS_13).unwrap();
        assert_eq!(clusters.to_string(), ONEPLUS_13);
        assert_eq!(clusters.cores(), 8);
        assert_eq!(clusters.midr(0), Some(0x513f_0011));
        assert_eq!(clusters.midr(5), Some(0x513f_0011));
        assert_eq!(clusters.midr(6), Some(0x514f_0011));
        assert_eq!(clusters.midr(8), None);
        assert_eq!(Clusters::parse("1x0x410fd821@576000-3302400").unwrap().midr(0), Some(0x410f_d821));
        for bad in ["", "8x410fd801", "8x410fd801@300000", "0x410fd801@300000-2000000", "2xzz@300000-2000000",
                    "2x410fd801@2000000-300000", "2x410fd801@0-300000", "2x410fd801@300000-2000000,"] {
            assert!(Clusters::parse(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn a_table_runs_from_the_lowest_frequency_to_the_highest() {
        let clusters = Clusters::parse(ONEPLUS_13).unwrap();
        for cluster in &clusters.0 {
            let table = cluster.table();
            assert_eq!(table[0], cluster.min_khz);
            assert_eq!(table[table.len() - 1], cluster.max_khz);
            assert!(table.windows(2).all(|pair| pair[0] < pair[1]), "{table:?}");
            assert!((14..=20).contains(&table.len()), "about as many as the phone's 16: {table:?}");
            assert!(table[1..table.len() - 1].iter().all(|khz| khz % GRID_KHZ == 0), "{table:?}");
        }
        let narrow = Cluster { cores: 1, midr: 0, min_khz: 1_000_000, max_khz: 1_010_000 };
        assert_eq!(narrow.table(), [1_000_000, 1_010_000]);
        let wide = Cluster { cores: 1, midr: 0, min_khz: 1, max_khz: 100_000_000 };
        assert_eq!(wide.table().len() as u32, MAX_ENTRIES);
    }

    /// What drivers/cpufreq/virtual-cpufreq.c reads and writes.
    #[test]
    fn the_guest_driver_finds_a_policy_per_cluster() {
        let clusters = Clusters::parse(ONEPLUS_13).unwrap();
        let device = VirtualCpufreq::new(&clusters);
        assert_eq!(device.size(), 8 * PAGE);
        let domains: Vec<u32> = (0..8).map(|cpu| read(&device, cpu * PAGE + PERF_DOMAIN)).collect();
        assert_eq!(domains, [0, 0, 0, 0, 0, 0, 1, 1]);
        // virt_cpufreq_get_perftbl_entry: select, then read.
        let prime = 7 * PAGE;
        let entries = read(&device, prime + PERFTBL_LEN);
        let table: Vec<u32> = (0..entries)
            .map(|entry| {
                write(&device, prime + PERFTBL_SEL, entry);
                read(&device, prime + PERFTBL_RD)
            })
            .collect();
        assert_eq!(table, clusters.0[1].table());
        // The guest's requests change nothing: it runs at the top.
        write(&device, prime + 0x4, 1_017_600);
        assert_eq!(read(&device, prime + CUR_PERF), 4_320_000);
        assert_eq!(read(&device, CUR_PERF), 3_532_800);
        // Past the table, past the vCPUs, or between registers: zero.
        write(&device, prime + PERFTBL_SEL, 64);
        assert_eq!(read(&device, prime + PERFTBL_RD), 0);
        assert_eq!(read(&device, 8 * PAGE + PERFTBL_LEN), 0);
        assert_eq!(read(&device, 0x18), 0);
        write(&device, 8 * PAGE + PERFTBL_SEL, 1);
    }
}
