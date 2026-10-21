//! Raw bindings to Hypervisor.framework on Apple Silicon (arm64).
//!
//! Written by hand from the macOS SDK headers `Hypervisor/hv_vm.h`,
//! `hv_vcpu.h`, `hv_vcpu_types.h` and `hv_gic.h`. Only what Avo uses.
#![allow(non_camel_case_types)]

use std::ffi::c_void;

pub type hv_return_t = i32;
pub type hv_ipa_t = u64;
pub type hv_vcpu_t = u64;
pub type hv_memory_flags_t = u64;
pub type hv_exit_reason_t = u32;
pub type hv_reg_t = u32;
pub type hv_sys_reg_t = u16;
pub type hv_interrupt_type_t = u32;
/// `os_object` handles (`hv_vm_config_t`, `hv_vcpu_config_t`, `hv_gic_config_t`).
pub type os_object_t = *mut c_void;

pub const HV_SUCCESS: hv_return_t = 0;
pub const HV_ERROR: hv_return_t = 0xfae94001_u32 as i32;
pub const HV_BUSY: hv_return_t = 0xfae94002_u32 as i32;
pub const HV_BAD_ARGUMENT: hv_return_t = 0xfae94003_u32 as i32;
pub const HV_ILLEGAL_GUEST_STATE: hv_return_t = 0xfae94004_u32 as i32;
pub const HV_NO_RESOURCES: hv_return_t = 0xfae94005_u32 as i32;
pub const HV_NO_DEVICE: hv_return_t = 0xfae94006_u32 as i32;
pub const HV_DENIED: hv_return_t = 0xfae94007_u32 as i32;
pub const HV_UNSUPPORTED: hv_return_t = 0xfae9400f_u32 as i32;

pub const HV_MEMORY_READ: hv_memory_flags_t = 1 << 0;
pub const HV_MEMORY_WRITE: hv_memory_flags_t = 1 << 1;
pub const HV_MEMORY_EXEC: hv_memory_flags_t = 1 << 2;

pub const HV_EXIT_REASON_CANCELED: hv_exit_reason_t = 0;
pub const HV_EXIT_REASON_EXCEPTION: hv_exit_reason_t = 1;
pub const HV_EXIT_REASON_VTIMER_ACTIVATED: hv_exit_reason_t = 2;
pub const HV_EXIT_REASON_UNKNOWN: hv_exit_reason_t = 3;

pub const HV_INTERRUPT_TYPE_IRQ: hv_interrupt_type_t = 0;
pub const HV_INTERRUPT_TYPE_FIQ: hv_interrupt_type_t = 1;

// General registers: X0..X30, then PC, FPCR, FPSR, CPSR.
pub const HV_REG_X0: hv_reg_t = 0;
pub const HV_REG_PC: hv_reg_t = 31;
pub const HV_REG_FPCR: hv_reg_t = 32;
pub const HV_REG_FPSR: hv_reg_t = 33;
pub const HV_REG_CPSR: hv_reg_t = 34;

/// System register encoding used by `hv_sys_reg_t`.
pub const fn sys_reg(op0: u16, op1: u16, crn: u16, crm: u16, op2: u16) -> hv_sys_reg_t {
    (op0 << 14) | (op1 << 11) | (crn << 7) | (crm << 3) | op2
}

pub const HV_SYS_REG_MIDR_EL1: hv_sys_reg_t = sys_reg(3, 0, 0, 0, 0);
pub const HV_SYS_REG_MPIDR_EL1: hv_sys_reg_t = sys_reg(3, 0, 0, 0, 5);
pub const HV_SYS_REG_SCTLR_EL1: hv_sys_reg_t = sys_reg(3, 0, 1, 0, 0);
pub const HV_SYS_REG_SP_EL1: hv_sys_reg_t = sys_reg(3, 4, 4, 1, 0);
pub const HV_SYS_REG_CNTV_CTL_EL0: hv_sys_reg_t = sys_reg(3, 3, 14, 3, 1);
pub const HV_SYS_REG_CNTV_CVAL_EL0: hv_sys_reg_t = sys_reg(3, 3, 14, 3, 2);

/// GIC interrupts queried with `hv_gic_get_intid` (the values are the
/// architectural PPI numbers).
pub type hv_gic_intid_t = u16;
pub const HV_GIC_INT_PERFORMANCE_MONITOR: hv_gic_intid_t = 23;
pub const HV_GIC_INT_MAINTENANCE: hv_gic_intid_t = 25;
pub const HV_GIC_INT_EL2_PHYSICAL_TIMER: hv_gic_intid_t = 26;
pub const HV_GIC_INT_EL1_VIRTUAL_TIMER: hv_gic_intid_t = 27;
pub const HV_GIC_INT_EL1_PHYSICAL_TIMER: hv_gic_intid_t = 30;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct hv_vcpu_exit_exception_t {
    pub syndrome: u64,
    pub virtual_address: u64,
    pub physical_address: hv_ipa_t,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct hv_vcpu_exit_t {
    pub reason: hv_exit_reason_t,
    pub exception: hv_vcpu_exit_exception_t,
}

#[link(name = "Hypervisor", kind = "framework")]
unsafe extern "C" {
    pub fn hv_vm_config_create() -> os_object_t;
    pub fn hv_vm_config_get_max_ipa_size(ipa_bit_length: *mut u32) -> hv_return_t;
    pub fn hv_vm_config_get_default_ipa_size(ipa_bit_length: *mut u32) -> hv_return_t;
    pub fn hv_vm_config_set_ipa_size(config: os_object_t, ipa_bit_length: u32) -> hv_return_t;
    pub fn hv_vm_create(config: os_object_t) -> hv_return_t;
    pub fn hv_vm_destroy() -> hv_return_t;
    pub fn hv_vm_map(addr: *mut c_void, ipa: hv_ipa_t, size: usize, flags: hv_memory_flags_t) -> hv_return_t;
    pub fn hv_vm_unmap(ipa: hv_ipa_t, size: usize) -> hv_return_t;
    pub fn hv_vm_protect(ipa: hv_ipa_t, size: usize, flags: hv_memory_flags_t) -> hv_return_t;

    pub fn hv_vcpu_create(vcpu: *mut hv_vcpu_t, exit: *mut *mut hv_vcpu_exit_t, config: os_object_t) -> hv_return_t;
    pub fn hv_vcpu_destroy(vcpu: hv_vcpu_t) -> hv_return_t;
    pub fn hv_vcpu_run(vcpu: hv_vcpu_t) -> hv_return_t;
    pub fn hv_vcpus_exit(vcpus: *mut hv_vcpu_t, vcpu_count: u32) -> hv_return_t;
    pub fn hv_vcpu_get_reg(vcpu: hv_vcpu_t, reg: hv_reg_t, value: *mut u64) -> hv_return_t;
    pub fn hv_vcpu_set_reg(vcpu: hv_vcpu_t, reg: hv_reg_t, value: u64) -> hv_return_t;
    pub fn hv_vcpu_get_sys_reg(vcpu: hv_vcpu_t, reg: hv_sys_reg_t, value: *mut u64) -> hv_return_t;
    pub fn hv_vcpu_set_sys_reg(vcpu: hv_vcpu_t, reg: hv_sys_reg_t, value: u64) -> hv_return_t;
    pub fn hv_vcpu_set_pending_interrupt(vcpu: hv_vcpu_t, kind: hv_interrupt_type_t, pending: bool) -> hv_return_t;
    pub fn hv_vcpu_set_vtimer_mask(vcpu: hv_vcpu_t, masked: bool) -> hv_return_t;
    pub fn hv_vcpu_get_vtimer_offset(vcpu: hv_vcpu_t, offset: *mut u64) -> hv_return_t;
    pub fn hv_vcpu_set_vtimer_offset(vcpu: hv_vcpu_t, offset: u64) -> hv_return_t;

    // In-kernel GICv3 (macOS 15+).
    pub fn hv_gic_config_create() -> os_object_t;
    pub fn hv_gic_config_set_distributor_base(config: os_object_t, base: hv_ipa_t) -> hv_return_t;
    pub fn hv_gic_config_set_redistributor_base(config: os_object_t, base: hv_ipa_t) -> hv_return_t;
    pub fn hv_gic_create(config: os_object_t) -> hv_return_t;
    pub fn hv_gic_get_distributor_size(size: *mut usize) -> hv_return_t;
    pub fn hv_gic_get_distributor_base_alignment(alignment: *mut usize) -> hv_return_t;
    pub fn hv_gic_get_redistributor_region_size(size: *mut usize) -> hv_return_t;
    pub fn hv_gic_get_redistributor_size(size: *mut usize) -> hv_return_t;
    pub fn hv_gic_get_redistributor_base_alignment(alignment: *mut usize) -> hv_return_t;
    pub fn hv_gic_get_spi_interrupt_range(base: *mut u32, count: *mut u32) -> hv_return_t;
    pub fn hv_gic_get_intid(interrupt: hv_gic_intid_t, intid: *mut u32) -> hv_return_t;
    pub fn hv_gic_set_spi(intid: u32, level: bool) -> hv_return_t;
}

#[link(name = "System")]
unsafe extern "C" {
    pub fn os_release(object: os_object_t);
}
