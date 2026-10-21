//! Safe wrapper over Hypervisor.framework for Apple Silicon, shaped after
//! crosvm's `hypervisor` traits (VM, guest memory, vCPU, exits) so it can
//! move into crosvm as its `hvf` backend (docs/engine.md).

mod exit;
mod memory;

pub use exit::{ExceptionClass, Exit, MmioAccess, decode_exception};
pub use memory::GuestRegion;

use hvf_sys as sys;
use std::fmt;
use std::marker::PhantomData;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Error {
    pub call: &'static str,
    pub code: sys::hv_return_t,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let name = match self.code {
            sys::HV_ERROR => "HV_ERROR",
            sys::HV_BUSY => "HV_BUSY",
            sys::HV_BAD_ARGUMENT => "HV_BAD_ARGUMENT",
            sys::HV_ILLEGAL_GUEST_STATE => "HV_ILLEGAL_GUEST_STATE",
            sys::HV_NO_RESOURCES => "HV_NO_RESOURCES",
            sys::HV_NO_DEVICE => "HV_NO_DEVICE",
            sys::HV_DENIED => "HV_DENIED (missing com.apple.security.hypervisor entitlement?)",
            sys::HV_UNSUPPORTED => "HV_UNSUPPORTED",
            _ => "unknown",
        };
        write!(f, "{} failed: {} ({:#x})", self.call, name, self.code as u32)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

pub(crate) fn check(call: &'static str, code: sys::hv_return_t) -> Result<()> {
    if code == sys::HV_SUCCESS { Ok(()) } else { Err(Error { call, code }) }
}

/// Guest memory permissions.
#[derive(Debug, Clone, Copy)]
pub struct Protection {
    pub read: bool,
    pub write: bool,
    pub exec: bool,
}

impl Protection {
    pub const RWX: Protection = Protection { read: true, write: true, exec: true };
    pub const RW: Protection = Protection { read: true, write: true, exec: false };
    pub const RO: Protection = Protection { read: true, write: false, exec: false };

    fn flags(self) -> sys::hv_memory_flags_t {
        (if self.read { sys::HV_MEMORY_READ } else { 0 })
            | (if self.write { sys::HV_MEMORY_WRITE } else { 0 })
            | (if self.exec { sys::HV_MEMORY_EXEC } else { 0 })
    }
}

/// Where the in-kernel GICv3 lives in guest physical memory.
#[derive(Debug, Clone, Copy)]
pub struct GicLayout {
    pub distributor_base: u64,
    pub distributor_size: u64,
    pub redistributor_base: u64,
    /// Size of the whole redistributor region (all vCPUs).
    pub redistributor_region_size: u64,
    /// Size of one vCPU's redistributor frames.
    pub redistributor_size: u64,
    pub spi_base: u32,
    pub spi_count: u32,
    pub virtual_timer_intid: u32,
}

/// The process's VM. Hypervisor.framework allows one per process.
pub struct Vm {
    _private: (),
}

impl Vm {
    /// Creates the VM with `ipa_bits` of guest physical address space (None: default).
    pub fn new(ipa_bits: Option<u32>) -> Result<Vm> {
        unsafe {
            let config = sys::hv_vm_config_create();
            if let Some(bits) = ipa_bits {
                check("hv_vm_config_set_ipa_size", sys::hv_vm_config_set_ipa_size(config, bits))?;
            }
            let result = sys::hv_vm_create(config);
            sys::os_release(config);
            check("hv_vm_create", result)?;
        }
        Ok(Vm { _private: () })
    }

    pub fn max_ipa_bits() -> Result<u32> {
        let mut bits = 0;
        check("hv_vm_config_get_max_ipa_size", unsafe { sys::hv_vm_config_get_max_ipa_size(&mut bits) })?;
        Ok(bits)
    }

    /// The guest physical address bits `new(None)` gives.
    pub fn default_ipa_bits() -> Result<u32> {
        let mut bits = 0;
        check("hv_vm_config_get_default_ipa_size", unsafe { sys::hv_vm_config_get_default_ipa_size(&mut bits) })?;
        Ok(bits)
    }

    /// Maps host memory into the guest. `region` must outlive the mapping.
    pub fn map(&self, region: &GuestRegion, protection: Protection) -> Result<()> {
        check("hv_vm_map", unsafe {
            sys::hv_vm_map(region.as_ptr().cast(), region.guest_address(), region.len(), protection.flags())
        })
    }

    pub fn unmap(&self, guest_address: u64, len: usize) -> Result<()> {
        check("hv_vm_unmap", unsafe { sys::hv_vm_unmap(guest_address, len) })
    }

    pub fn protect(&self, guest_address: u64, len: usize, protection: Protection) -> Result<()> {
        check("hv_vm_protect", unsafe { sys::hv_vm_protect(guest_address, len, protection.flags()) })
    }

    /// Creates the in-kernel GICv3 (macOS 15+). Must run before any vCPU exists.
    pub fn create_gic(&self, distributor_base: u64, redistributor_base: u64) -> Result<GicLayout> {
        unsafe {
            let config = sys::hv_gic_config_create();
            check("hv_gic_config_set_distributor_base", sys::hv_gic_config_set_distributor_base(config, distributor_base))?;
            check("hv_gic_config_set_redistributor_base", sys::hv_gic_config_set_redistributor_base(config, redistributor_base))?;
            let result = sys::hv_gic_create(config);
            sys::os_release(config);
            check("hv_gic_create", result)?;

            let mut distributor_size = 0;
            let mut region_size = 0;
            let mut redistributor_size = 0;
            let mut spi_base = 0;
            let mut spi_count = 0;
            let mut timer = 0;
            check("hv_gic_get_distributor_size", sys::hv_gic_get_distributor_size(&mut distributor_size))?;
            check("hv_gic_get_redistributor_region_size", sys::hv_gic_get_redistributor_region_size(&mut region_size))?;
            check("hv_gic_get_redistributor_size", sys::hv_gic_get_redistributor_size(&mut redistributor_size))?;
            check("hv_gic_get_spi_interrupt_range", sys::hv_gic_get_spi_interrupt_range(&mut spi_base, &mut spi_count))?;
            check("hv_gic_get_intid", sys::hv_gic_get_intid(sys::HV_GIC_INT_EL1_VIRTUAL_TIMER, &mut timer))?;
            Ok(GicLayout {
                distributor_base,
                distributor_size: distributor_size as u64,
                redistributor_base,
                redistributor_region_size: region_size as u64,
                redistributor_size: redistributor_size as u64,
                spi_base,
                spi_count,
                virtual_timer_intid: timer,
            })
        }
    }

    /// Alignment requirements for the GIC frames.
    pub fn gic_alignment() -> Result<(u64, u64)> {
        let mut distributor = 0;
        let mut redistributor = 0;
        unsafe {
            check("hv_gic_get_distributor_base_alignment", sys::hv_gic_get_distributor_base_alignment(&mut distributor))?;
            check("hv_gic_get_redistributor_base_alignment", sys::hv_gic_get_redistributor_base_alignment(&mut redistributor))?;
        }
        Ok((distributor as u64, redistributor as u64))
    }

    /// Raises or lowers a shared peripheral interrupt (device interrupt line).
    pub fn set_spi(&self, intid: u32, level: bool) -> Result<()> {
        set_spi(intid, level)
    }
}

/// Raises or lowers a shared peripheral interrupt of the process's VM. Safe
/// to call from any thread once the GIC exists.
pub fn set_spi(intid: u32, level: bool) -> Result<()> {
    check("hv_gic_set_spi", unsafe { sys::hv_gic_set_spi(intid, level) })
}

/// Maps `len` bytes of host memory at `host` into the process's VM at
/// `guest_address`, from any thread while the vCPUs run: device memory the
/// guest reaches directly, such as GPU buffers. A free function because the
/// process has one VM, so device threads need no `Vm` (and no lifetime tie
/// to its `Drop`). Host address, guest address and length must be multiples
/// of the host page size (16 KiB).
///
/// # Safety
/// The memory must stay allocated, with at least `protection`, until `unmap`
/// removes the range (or the VM is destroyed): the guest reads and writes it.
pub unsafe fn map_host(host: *mut u8, guest_address: u64, len: usize, protection: Protection) -> Result<()> {
    check("hv_vm_map", unsafe { sys::hv_vm_map(host.cast(), guest_address, len, protection.flags()) })
}

/// Removes a guest range of the process's VM mapped with `map_host`.
pub fn unmap(guest_address: u64, len: usize) -> Result<()> {
    check("hv_vm_unmap", unsafe { sys::hv_vm_unmap(guest_address, len) })
}

impl Drop for Vm {
    fn drop(&mut self) {
        unsafe {
            sys::hv_vm_destroy();
        }
    }
}

/// A virtual CPU. Hypervisor.framework binds it to the thread that created
/// it, so it is neither `Send` nor `Sync`: create it on its vCPU thread.
pub struct Vcpu {
    handle: sys::hv_vcpu_t,
    exit: *const sys::hv_vcpu_exit_t,
    _thread_bound: PhantomData<*const ()>,
}

/// A vCPU id that other threads may use to kick the vCPU out of `run`.
#[derive(Debug, Clone, Copy)]
pub struct VcpuHandle(sys::hv_vcpu_t);

impl VcpuHandle {
    pub fn kick(self) -> Result<()> {
        let mut id = self.0;
        check("hv_vcpus_exit", unsafe { sys::hv_vcpus_exit(&mut id, 1) })
    }

    /// Makes every listed vCPU in `run` return from it. A vCPU outside
    /// `run` at the time (handling an exit) does not see it.
    pub fn kick_all(handles: &[VcpuHandle]) -> Result<()> {
        let mut ids: Vec<sys::hv_vcpu_t> = handles.iter().map(|h| h.0).collect();
        check("hv_vcpus_exit", unsafe { sys::hv_vcpus_exit(ids.as_mut_ptr(), ids.len() as u32) })
    }
}

impl Vcpu {
    pub fn new(_vm: &Vm) -> Result<Vcpu> {
        let mut handle = 0;
        let mut exit = std::ptr::null_mut();
        check("hv_vcpu_create", unsafe { sys::hv_vcpu_create(&mut handle, &mut exit, std::ptr::null_mut()) })?;
        Ok(Vcpu { handle, exit, _thread_bound: PhantomData })
    }

    pub fn handle(&self) -> VcpuHandle {
        VcpuHandle(self.handle)
    }

    /// Runs the guest until it exits.
    pub fn run(&mut self) -> Result<Exit> {
        check("hv_vcpu_run", unsafe { sys::hv_vcpu_run(self.handle) })?;
        let exit = unsafe { *self.exit };
        Ok(match exit.reason {
            sys::HV_EXIT_REASON_CANCELED => Exit::Canceled,
            sys::HV_EXIT_REASON_VTIMER_ACTIVATED => Exit::VtimerActivated,
            sys::HV_EXIT_REASON_EXCEPTION => Exit::Exception {
                syndrome: exit.exception.syndrome,
                virtual_address: exit.exception.virtual_address,
                physical_address: exit.exception.physical_address,
            },
            other => Exit::Unknown(other),
        })
    }

    /// X0..X30 (`index` 0–30); 31 reads XZR as zero.
    pub fn x(&self, index: u32) -> Result<u64> {
        if index >= 31 {
            return Ok(0);
        }
        self.reg(sys::HV_REG_X0 + index)
    }

    pub fn set_x(&self, index: u32, value: u64) -> Result<()> {
        if index >= 31 {
            return Ok(());
        }
        self.set_reg(sys::HV_REG_X0 + index, value)
    }

    pub fn pc(&self) -> Result<u64> {
        self.reg(sys::HV_REG_PC)
    }

    pub fn set_pc(&self, value: u64) -> Result<()> {
        self.set_reg(sys::HV_REG_PC, value)
    }

    pub fn set_cpsr(&self, value: u64) -> Result<()> {
        self.set_reg(sys::HV_REG_CPSR, value)
    }

    pub fn reg(&self, reg: sys::hv_reg_t) -> Result<u64> {
        let mut value = 0;
        check("hv_vcpu_get_reg", unsafe { sys::hv_vcpu_get_reg(self.handle, reg, &mut value) })?;
        Ok(value)
    }

    pub fn set_reg(&self, reg: sys::hv_reg_t, value: u64) -> Result<()> {
        check("hv_vcpu_set_reg", unsafe { sys::hv_vcpu_set_reg(self.handle, reg, value) })
    }

    pub fn sys_reg(&self, reg: sys::hv_sys_reg_t) -> Result<u64> {
        let mut value = 0;
        check("hv_vcpu_get_sys_reg", unsafe { sys::hv_vcpu_get_sys_reg(self.handle, reg, &mut value) })?;
        Ok(value)
    }

    pub fn set_sys_reg(&self, reg: sys::hv_sys_reg_t, value: u64) -> Result<()> {
        check("hv_vcpu_set_sys_reg", unsafe { sys::hv_vcpu_set_sys_reg(self.handle, reg, value) })
    }

    /// CNTVCT_EL0 = mach_absolute_time() - offset.
    pub fn vtimer_offset(&self) -> Result<u64> {
        let mut offset = 0;
        check("hv_vcpu_get_vtimer_offset", unsafe { sys::hv_vcpu_get_vtimer_offset(self.handle, &mut offset) })?;
        Ok(offset)
    }

    /// Sets the offset (on the vCPU's own thread): a larger one sets the
    /// guest's counter back, as while it was paused.
    pub fn set_vtimer_offset(&self, offset: u64) -> Result<()> {
        check("hv_vcpu_set_vtimer_offset", unsafe { sys::hv_vcpu_set_vtimer_offset(self.handle, offset) })
    }

    pub fn set_vtimer_mask(&self, masked: bool) -> Result<()> {
        check("hv_vcpu_set_vtimer_mask", unsafe { sys::hv_vcpu_set_vtimer_mask(self.handle, masked) })
    }

    pub fn set_pending_irq(&self, pending: bool) -> Result<()> {
        check("hv_vcpu_set_pending_interrupt", unsafe {
            sys::hv_vcpu_set_pending_interrupt(self.handle, sys::HV_INTERRUPT_TYPE_IRQ, pending)
        })
    }

    /// Moves past the instruction that trapped (MMIO, system register access).
    pub fn advance_pc(&self) -> Result<()> {
        self.set_pc(self.pc()? + 4)
    }
}

impl Drop for Vcpu {
    fn drop(&mut self) {
        unsafe {
            sys::hv_vcpu_destroy(self.handle);
        }
    }
}

pub use sys::{
    HV_SYS_REG_CNTV_CTL_EL0, HV_SYS_REG_CNTV_CVAL_EL0, HV_SYS_REG_MIDR_EL1, HV_SYS_REG_MPIDR_EL1, HV_SYS_REG_SCTLR_EL1, HV_SYS_REG_SP_EL1,
};
