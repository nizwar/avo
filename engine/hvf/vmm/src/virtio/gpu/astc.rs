//! Avo's Vulkan layer between gfxstream and MoltenVK on the Mac
//! (layer/native_astc.c, built by build.rs).
//!
//! Native ASTC: gfxstream emulates ASTC unless the driver samples linear-tiled
//! ASTC, which Metal never does, so on the Mac it always emulated it: an ASTC
//! texture then took 5x (4x4) to 17x (8x8) its memory, and games sized their
//! texture streaming by that and dropped mip levels. The layer reports linear
//! ASTC sampling wherever optimal tiling has it; Avo's guest layer
//! (guest/gfxsync) hides it from apps again. `AVO_NATIVE_ASTC=0` leaves
//! gfxstream's emulation on, to compare.
//!
//! Memoryless memory: the layer hides MoltenVK's lazily allocated memory type,
//! which ANGLE's multisampled render-to-texture images asked for and MoltenVK
//! refuses them (the images got no memory and drew garbage).
//!
//! The engine writes the layer and its manifest into a folder of its own in
//! the temporary folder, named after the layer's bytes so builds never share
//! one, and names it to the Vulkan loader (`VK_ADD_LAYER_PATH`,
//! `VK_INSTANCE_LAYERS`) before gfxstream starts.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

pub const LAYER: &str = "VK_LAYER_AVO_native_astc";
const LIBRARY: &str = "libVkLayer_avo_native_astc.dylib";
const MANIFEST: &str = "VkLayer_avo_native_astc.json";
static DYLIB: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/libVkLayer_avo_native_astc.dylib"));

fn manifest() -> String {
    format!(
        r#"{{"file_format_version": "1.1.2", "layer": {{"name": "{LAYER}", "type": "GLOBAL", "library_path": "./{LIBRARY}", "api_version": "1.4.0", "implementation_version": "1", "description": "Avo: native ASTC and no memoryless memory for gfxstream"}}}}"#
    )
}

/// FNV-1a of `bytes`.
fn fingerprint(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf29ce484222325, |hash, &byte| (hash ^ byte as u64).wrapping_mul(0x100000001b3))
}

/// Replaced in one step: another engine starting at the same time never loads half a file.
fn write_whole(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let partial = path.with_extension(format!("partial-{}", std::process::id()));
    std::fs::write(&partial, bytes)?;
    std::fs::rename(&partial, path)
}

/// Writes the layer and its manifest under `parent`, unless they are there
/// already; the folder they are in.
pub fn install(parent: &Path) -> std::io::Result<PathBuf> {
    let dir = parent.join(format!("avo-vulkan-layer-{:016x}", fingerprint(DYLIB)));
    std::fs::create_dir_all(&dir)?;
    if std::fs::read(dir.join(LIBRARY)).ok().as_deref() != Some(DYLIB) {
        write_whole(&dir.join(LIBRARY), DYLIB)?;
    }
    if std::fs::read_to_string(dir.join(MANIFEST)).ok() != Some(manifest()) {
        write_whole(&dir.join(MANIFEST), manifest().as_bytes())?;
    }
    Ok(dir)
}

/// A loader list (`:`-separated) with `item` in it, once.
fn with_item(list: Option<&OsStr>, item: &str) -> String {
    let list = list.and_then(OsStr::to_str).unwrap_or("");
    if list.split(':').any(|existing| existing == item) {
        list.to_string()
    } else if list.is_empty() {
        item.to_string()
    } else {
        format!("{list}:{item}")
    }
}

/// Puts the layer where the Vulkan loader finds it for gfxstream.
///
/// # Safety
/// Changes the process environment: call it before any thread starts.
pub unsafe fn enable() {
    let dir = match install(&std::env::temp_dir()) {
        Ok(dir) => dir,
        Err(e) => {
            eprintln!("[gpu] Avo's Vulkan layer not written ({e}): gfxstream decompresses ASTC, and multisampled render to texture fails");
            return;
        }
    };
    let Some(dir) = dir.to_str() else { return };
    unsafe {
        std::env::set_var("VK_ADD_LAYER_PATH", with_item(std::env::var_os("VK_ADD_LAYER_PATH").as_deref(), dir));
        std::env::set_var("VK_INSTANCE_LAYERS", with_item(std::env::var_os("VK_INSTANCE_LAYERS").as_deref(), LAYER));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_layer_is_a_mach_o_library_with_the_loaders_entry_point() {
        assert_eq!(&DYLIB[..4], &0xfeedfacfu32.to_le_bytes(), "a 64-bit Mach-O image");
        let name = b"_vkNegotiateLoaderLayerInterfaceVersion";
        assert!(DYLIB.windows(name.len()).any(|w| w == name));
    }

    #[test]
    fn install_writes_the_layer_once_and_repairs_a_changed_copy() {
        let parent = std::env::temp_dir().join(format!("avo-astc-test-{}", std::process::id()));
        let dir = install(&parent).unwrap();
        assert_eq!(std::fs::read(dir.join(LIBRARY)).unwrap(), DYLIB);
        let manifest_text = std::fs::read_to_string(dir.join(MANIFEST)).unwrap();
        assert!(manifest_text.contains(LAYER) && manifest_text.contains(&format!("./{LIBRARY}")));
        std::fs::write(dir.join(LIBRARY), b"not the layer").unwrap();
        assert_eq!(install(&parent).unwrap(), dir);
        assert_eq!(std::fs::read(dir.join(LIBRARY)).unwrap(), DYLIB);
        std::fs::remove_dir_all(&parent).unwrap();
    }

    #[test]
    fn the_loader_lists_keep_what_was_there() {
        assert_eq!(with_item(None, LAYER), LAYER);
        assert_eq!(with_item(Some(OsStr::new("VK_LAYER_KHRONOS_validation")), LAYER), format!("VK_LAYER_KHRONOS_validation:{LAYER}"));
        assert_eq!(with_item(Some(OsStr::new(LAYER)), LAYER), LAYER);
    }
}
