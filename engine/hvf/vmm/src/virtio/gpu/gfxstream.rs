//! gfxstream's renderer (`libgfxstream_backend.dylib`): loading it, its C
//! ABI (matching the 37.1.11 `virtio-gpu-gfxstream-renderer.h`, API 0.1.2)
//! and its callbacks.
//!
//! The library is loaded at run time from a renderer directory with the
//! Android Emulator's layout (`lib64/`, `lib64/vulkan/`): Avo's own build in
//! Avo.app (gfxstream, the Vulkan loader and MoltenVK built from source,
//! scripts/build-gfxstream.sh), or an Android Emulator 37 the user installed.
//! It runs inside avo-vmm, Vulkan only (USE_VK |
//! USE_SURFACELESS): its external-blob mode, which would let it live in a
//! separate process, does not work on macOS, and host pointers reach the
//! guest through hv_vm_map (hostmem.rs). Never call its post callback,
//! `stream_renderer_flush` or `stream_renderer_teardown`: the first two
//! crash in Vulkan-only mode, and the process leaves with `_exit` instead.

use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub const PARAM_USER_DATA: u64 = 1;
pub const PARAM_RENDERER_FLAGS: u64 = 2;
pub const PARAM_FENCE_CALLBACK: u64 = 3;
pub const PARAM_WIN0_WIDTH: u64 = 4;
pub const PARAM_WIN0_HEIGHT: u64 = 5;
pub const PARAM_DEBUG_CALLBACK: u64 = 6;
pub const PARAM_RENDERER_FEATURES: u64 = 11;

/// USE_SURFACELESS (1 << 3) | USE_VK (1 << 5): guest ANGLE and Vulkan both
/// end in host Vulkan (MoltenVK); no host GLES.
pub const RENDERER_FLAGS: u64 = 0x28;

pub const FENCE: u32 = 1 << 0;
pub const FENCE_RING_IDX: u32 = 1 << 1;

pub const BLOB_MEM_HOST3D: u32 = 2;
pub const BLOB_FLAG_USE_MAPPABLE: u32 = 1;

const DEBUG_ERROR: u32 = 1;
const DEBUG_WARN: u32 = 2;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Param {
    pub key: u64,
    pub value: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Fence {
    pub flags: u32,
    pub fence_id: u64,
    pub ctx_id: u32,
    pub ring_idx: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Box3 {
    pub x: u32,
    pub y: u32,
    pub z: u32,
    pub w: u32,
    pub h: u32,
    pub d: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct ResourceCreateArgs {
    pub handle: u32,
    pub target: u32,
    pub format: u32,
    pub bind: u32,
    pub width: u32,
    pub height: u32,
    pub depth: u32,
    pub array_size: u32,
    pub last_level: u32,
    pub nr_samples: u32,
    pub flags: u32,
}

#[repr(C)]
pub struct CreateBlob {
    pub blob_mem: u32,
    pub blob_flags: u32,
    pub blob_id: u64,
    pub size: u64,
}

#[repr(C)]
pub struct Handle {
    pub os_handle: i64,
    pub handle_type: u32,
}

#[repr(C)]
pub struct Command {
    pub ctx_id: u32,
    pub cmd_size: u32,
    pub cmd: *mut u8,
    pub num_in_fences: u32,
    pub fences: *const Handle,
}

#[repr(C)]
pub struct Debug {
    pub debug_type: u32,
    pub message: *const c_char,
}

/// The `stream_renderer_*` entry points avo-vmm uses.
pub struct Library {
    init: unsafe extern "C" fn(*mut Param, u64) -> c_int,
    get_cap_set: unsafe extern "C" fn(u32, *mut u32, *mut u32),
    fill_caps: unsafe extern "C" fn(u32, u32, *mut c_void),
    pub context_create: unsafe extern "C" fn(u32, u32, *const c_char, u32) -> c_int,
    pub context_destroy: unsafe extern "C" fn(u32),
    pub ctx_attach_resource: unsafe extern "C" fn(c_int, c_int),
    pub ctx_detach_resource: unsafe extern "C" fn(c_int, c_int),
    pub resource_create: unsafe extern "C" fn(*mut ResourceCreateArgs, *mut libc::iovec, u32) -> c_int,
    pub resource_unref: unsafe extern "C" fn(u32),
    pub resource_attach_iov: unsafe extern "C" fn(c_int, *mut libc::iovec, c_int) -> c_int,
    pub resource_detach_iov: unsafe extern "C" fn(c_int, *mut *mut libc::iovec, *mut c_int),
    pub transfer_read_iov: unsafe extern "C" fn(u32, u32, u32, u32, u32, *mut Box3, u64, *mut libc::iovec, c_int) -> c_int,
    pub transfer_write_iov: unsafe extern "C" fn(u32, u32, c_int, u32, u32, *mut Box3, u64, *mut libc::iovec, u32) -> c_int,
    pub submit_cmd: unsafe extern "C" fn(*mut Command) -> c_int,
    pub create_fence: unsafe extern "C" fn(*const Fence) -> c_int,
    pub create_blob: unsafe extern "C" fn(u32, u32, *const CreateBlob, *const libc::iovec, u32, *const Handle) -> c_int,
    pub resource_map: unsafe extern "C" fn(u32, *mut *mut c_void, *mut u64) -> c_int,
    pub resource_unmap: unsafe extern "C" fn(u32) -> c_int,
}

/// The Android Emulator's backend's `@rpath` dependencies in `lib64`.
/// avo-vmm has no rpath into the user's SDK (one into a home folder could
/// not ship anyway): loading each by absolute path first makes the backend's
/// references resolve to the images already loaded. Avo's own build needs
/// only the system's libraries.
const DEPENDENCIES: [&str; 10] = [
    "libabseil_dll",
    "libprotobuf.28.4.0",
    "libglib2_darwin-aarch64",
    "libandroid-emu-base-logging",
    "libandroid-emu-tracing",
    "libandroid-emu-curl",
    "libandroid-emu-protos",
    "libandroid-emu-agents",
    "libandroid-emu-metrics",
    "libemugl_common",
];

fn dlerror() -> String {
    let message = unsafe { libc::dlerror() };
    if message.is_null() { "unknown error".into() } else { unsafe { CStr::from_ptr(message) }.to_string_lossy().into_owned() }
}

fn dlopen(path: &Path, flags: c_int) -> Result<*mut c_void, String> {
    let name = CString::new(path.as_os_str().as_encoded_bytes()).map_err(|e| e.to_string())?;
    let handle = unsafe { libc::dlopen(name.as_ptr(), flags) };
    if handle.is_null() { Err(dlerror()) } else { Ok(handle) }
}

macro_rules! symbol {
    ($handle:expr, $name:literal) => {{
        let name = concat!("stream_renderer_", $name, "\0");
        let pointer = unsafe { libc::dlsym($handle, name.as_ptr().cast()) };
        if pointer.is_null() {
            return Err(format!("libgfxstream_backend.dylib has no {}", name.trim_end_matches('\0')));
        }
        // SAFETY: the field's type is the symbol's prototype in the header.
        unsafe { std::mem::transmute::<*mut c_void, _>(pointer) }
    }};
}

impl Library {
    /// Loads the backend from `<dir>/lib64`, an Android Emulator's after its
    /// dependencies.
    pub fn load(dir: &Path) -> Result<Library, String> {
        let lib64 = dir.join("lib64");
        let backend = lib64.join("libgfxstream_backend.dylib");
        if !backend.exists() {
            return Err(format!("{} is missing", backend.display()));
        }
        let emulator = lib64.join("libemugl_common.dylib").exists();
        let mut left: Vec<&str> = if emulator { DEPENDENCIES.to_vec() } else { Vec::new() };
        for name in &left {
            let path = lib64.join(format!("{name}.dylib"));
            if !path.exists() {
                return Err(format!("{} is missing", path.display()));
            }
        }
        // In passes: which of them need which is not known here.
        let mut error = String::new();
        loop {
            let before = left.len();
            left.retain(|name| match dlopen(&lib64.join(format!("{name}.dylib")), libc::RTLD_NOW | libc::RTLD_GLOBAL) {
                Ok(_) => false,
                Err(e) => {
                    error = e;
                    true
                }
            });
            if left.is_empty() || left.len() == before {
                break;
            }
        }
        if let Some(name) = left.first() {
            return Err(format!("cannot load {name}.dylib: {error}"));
        }
        let backend = dlopen(&backend, libc::RTLD_NOW | libc::RTLD_LOCAL)?;
        Ok(Library {
            init: symbol!(backend, "init"),
            get_cap_set: symbol!(backend, "get_cap_set"),
            fill_caps: symbol!(backend, "fill_caps"),
            context_create: symbol!(backend, "context_create"),
            context_destroy: symbol!(backend, "context_destroy"),
            ctx_attach_resource: symbol!(backend, "ctx_attach_resource"),
            ctx_detach_resource: symbol!(backend, "ctx_detach_resource"),
            resource_create: symbol!(backend, "resource_create"),
            resource_unref: symbol!(backend, "resource_unref"),
            resource_attach_iov: symbol!(backend, "resource_attach_iov"),
            resource_detach_iov: symbol!(backend, "resource_detach_iov"),
            transfer_read_iov: symbol!(backend, "transfer_read_iov"),
            transfer_write_iov: symbol!(backend, "transfer_write_iov"),
            submit_cmd: symbol!(backend, "submit_cmd"),
            create_fence: symbol!(backend, "create_fence"),
            create_blob: symbol!(backend, "create_blob"),
            resource_map: symbol!(backend, "resource_map"),
            resource_unmap: symbol!(backend, "resource_unmap"),
        })
    }

    /// Starts the renderer. `callbacks` must live as long as the process.
    pub fn init(&self, callbacks: &'static Callbacks, display: (u32, u32)) -> Result<(), String> {
        // Pins today's default: async composition would reorder host
        // composition against the guest's fences.
        static FEATURES: &CStr = c"AsyncComposeSupport:disabled";
        let fence: extern "C" fn(*mut c_void, *mut Fence) = fence_callback;
        let debug: extern "C" fn(*mut c_void, *mut Debug) = debug_callback;
        let mut params = [
            Param { key: PARAM_USER_DATA, value: callbacks as *const Callbacks as u64 },
            Param { key: PARAM_RENDERER_FLAGS, value: RENDERER_FLAGS },
            Param { key: PARAM_FENCE_CALLBACK, value: fence as usize as u64 },
            Param { key: PARAM_DEBUG_CALLBACK, value: debug as usize as u64 },
            Param { key: PARAM_WIN0_WIDTH, value: display.0 as u64 },
            Param { key: PARAM_WIN0_HEIGHT, value: display.1 as u64 },
            Param { key: PARAM_RENDERER_FEATURES, value: FEATURES.as_ptr() as u64 },
        ];
        match unsafe { (self.init)(params.as_mut_ptr(), params.len() as u64) } {
            0 => Ok(()),
            code => Err(format!("stream_renderer_init failed ({code})")),
        }
    }

    /// A capability set's bytes (version 0), if the renderer has it.
    pub fn capset(&self, id: u32) -> Option<Vec<u8>> {
        // get_cap_set never writes the version.
        let (mut version, mut size) = (0u32, 0u32);
        unsafe { (self.get_cap_set)(id, &mut version, &mut size) };
        if size == 0 || size > 1 << 16 {
            return None;
        }
        let mut data = vec![0u8; size as usize];
        unsafe { (self.fill_caps)(id, 0, data.as_mut_ptr().cast()) };
        Some(data)
    }
}

/// The environment gfxstream reads at init: the renderer directory (it finds
/// MoltenVK's ICD there), MoltenVK as the Vulkan driver (a developer can
/// export ANDROID_EMU_VK_ICD=kosmickrisp), the Vulkan loader and Avo's layer
/// for it (astc.rs), no window; and Metal's shader cache in Avo's GPU cache
/// folder (cache.rs).
///
/// # Safety
/// Changes the process environment: call it before any thread starts.
pub unsafe fn set_environment(emulator: &Path) {
    let defaults = [("ANDROID_EMU_VK_ICD", "moltenvk"), ("ANDROID_EMU_HEADLESS", "1")];
    unsafe {
        std::env::set_var("ANDROID_EMULATOR_LAUNCHER_DIR", emulator);
        std::env::set_var("ANDROID_EMU_VK_LOADER_PATH", emulator.join("lib64/vulkan/libvulkan.dylib"));
        super::astc::enable();
        for (key, value) in defaults {
            if std::env::var_os(key).is_none() {
                std::env::set_var(key, value);
            }
        }
        super::cache::prepare(emulator);
    }
}

/// What gfxstream's callbacks reach through USER_DATA. Leaked: the renderer
/// keeps the pointer for the life of the process.
pub struct Callbacks {
    fence: Box<dyn Fn(Fence) + Send + Sync>,
    verbose: bool,
    /// When each message was last logged (repeats are rate-limited).
    logged: Mutex<HashMap<String, Instant>>,
    /// The Vulkan device gfxstream picked ("Apple M4 Pro").
    device: Mutex<Option<String>>,
}

impl Callbacks {
    pub fn new(fence: impl Fn(Fence) + Send + Sync + 'static, verbose: bool) -> Callbacks {
        Callbacks { fence: Box::new(fence), verbose, logged: Mutex::new(HashMap::new()), device: Mutex::new(None) }
    }

    pub fn device(&self) -> Option<String> {
        self.device.lock().unwrap().clone()
    }

    /// Errors and warnings go to the engine log (each identical message at
    /// most once a second: some repeat every frame); the rest with --verbose.
    fn log(&self, kind: u32, message: &str) {
        let message = message.trim_end();
        if let Some(rest) = message.split("Selecting Vulkan device: ").nth(1) {
            *self.device.lock().unwrap() = Some(rest.split(", Version").next().unwrap_or(rest).trim().to_string());
        }
        let level = match kind {
            DEBUG_ERROR => "ERROR",
            DEBUG_WARN => "WARN",
            _ if self.verbose => "INFO",
            _ => return,
        };
        {
            let now = Instant::now();
            let mut logged = self.logged.lock().unwrap();
            if logged.get(message).is_some_and(|at| now.duration_since(*at) < Duration::from_secs(1)) {
                return;
            }
            if logged.len() > 512 {
                logged.retain(|_, at| now.duration_since(*at) < Duration::from_secs(1));
            }
            logged.insert(message.to_string(), now);
        }
        eprintln!("[gfxstream] {level} {message}");
    }
}

/// May run inside `create_fence` or on gfxstream's own threads: it only
/// hands the fence on (render.rs posts it to the render thread).
extern "C" fn fence_callback(user: *mut c_void, fence: *mut Fence) {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let callbacks = unsafe { &*(user as *const Callbacks) };
        if let Some(fence) = unsafe { fence.as_ref() } {
            (callbacks.fence)(*fence);
        }
    }));
}

extern "C" fn debug_callback(user: *mut c_void, debug: *mut Debug) {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let callbacks = unsafe { &*(user as *const Callbacks) };
        let Some(debug) = (unsafe { debug.as_ref() }) else { return };
        if !debug.message.is_null() {
            callbacks.log(debug.debug_type, &unsafe { CStr::from_ptr(debug.message) }.to_string_lossy());
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{offset_of, size_of};

    #[test]
    fn structures_match_the_c_header() {
        assert_eq!((size_of::<Param>(), size_of::<Box3>(), size_of::<ResourceCreateArgs>()), (16, 24, 44));
        assert_eq!(size_of::<Fence>(), 24);
        assert_eq!((offset_of!(Fence, fence_id), offset_of!(Fence, ctx_id), offset_of!(Fence, ring_idx)), (8, 16, 20));
        assert_eq!((size_of::<CreateBlob>(), offset_of!(CreateBlob, blob_id), offset_of!(CreateBlob, size)), (24, 8, 16));
        assert_eq!((size_of::<Command>(), offset_of!(Command, cmd), offset_of!(Command, num_in_fences), offset_of!(Command, fences)), (32, 8, 16, 24));
        assert_eq!((size_of::<Handle>(), size_of::<Debug>(), offset_of!(Debug, message)), (16, 16, 8));
    }

    #[test]
    fn the_vulkan_device_is_picked_up_from_the_log() {
        let callbacks = Callbacks::new(|_| {}, false);
        callbacks.log(3, "[vk_common_operations.cpp(1343)] Selecting Vulkan device: Apple M4 Pro, Version: 1.1.323\n");
        assert_eq!(callbacks.device().as_deref(), Some("Apple M4 Pro"));
    }

    #[test]
    fn a_missing_library_is_named() {
        let error = Library::load(Path::new("/nonexistent/renderer")).err().unwrap();
        assert!(error.contains("libgfxstream_backend.dylib is missing"), "{error}");
        // An Android Emulator's backend without the libraries it needs.
        let dir = std::env::temp_dir().join(format!("avo-gfxstream-test-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("lib64")).unwrap();
        for name in ["libgfxstream_backend.dylib", "libemugl_common.dylib"] {
            std::fs::write(dir.join("lib64").join(name), b"").unwrap();
        }
        let error = Library::load(&dir).err().unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(error.contains("libabseil_dll.dylib is missing"), "{error}");
    }

    /// With AVO_GFXSTREAM_DIR set to an Android Emulator directory: the
    /// library loads, initialises and reports the capsets avo-vmm needs.
    #[test]
    fn the_installed_renderer_starts() {
        let Some(dir) = std::env::var_os("AVO_GFXSTREAM_DIR") else { return };
        let dir = Path::new(&dir);
        // SAFETY: only this test reads these variables.
        unsafe { set_environment(dir) };
        let library = Library::load(dir).unwrap();
        let callbacks: &'static Callbacks = Box::leak(Box::new(Callbacks::new(|_| {}, false)));
        library.init(callbacks, (720, 1280)).unwrap();
        let vulkan = library.capset(3).unwrap();
        assert_eq!(vulkan.len(), 112);
        assert_eq!(u32::from_le_bytes(vulkan[20..24].try_into().unwrap()) % 16384, 0, "blobAlignment");
        assert!(library.capset(9).is_some());
        assert!(callbacks.device().is_some());
    }
}
