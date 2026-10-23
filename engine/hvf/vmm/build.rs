//! Builds the host Vulkan layer that keeps gfxstream from emulating ASTC
//! (layer/native_astc.c), for astc.rs to embed and write out at start. It
//! compiles in the guest layer's fragment output split
//! (guest/gfxsync/src/frag_outputs.c), which it now does on the Mac too.
//!
//! The Mac's own clang and codesign, by absolute path: Xcode's avo-vmm build
//! phase runs cargo with Xcode's environment, not the user's PATH. The layer
//! is signed ad hoc like the rest of a development build; avo-vmm loads it
//! with library validation off, as it does gfxstream.

use std::path::PathBuf;
use std::process::Command;

fn main() {
    let source = "layer/native_astc.c";
    let split = "../../../guest/gfxsync/src/frag_outputs.c";
    println!("cargo:rerun-if-changed={source}");
    println!("cargo:rerun-if-changed={split}");
    println!("cargo:rerun-if-changed=../../../guest/gfxsync/src/frag_outputs.h");
    let out = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR")).join("libVkLayer_avo_native_astc.dylib");
    let arch = match std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        Ok("aarch64") => "arm64".to_string(),
        Ok(other) => other.to_string(),
        Err(_) => "arm64".to_string(),
    };
    let status = Command::new("/usr/bin/clang")
        .args(["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-fvisibility=hidden", "-dynamiclib", "-arch", &arch])
        .args(["-install_name", "@rpath/libVkLayer_avo_native_astc.dylib", "-o"])
        .arg(&out)
        .args([source, split])
        .status()
        .expect("run /usr/bin/clang");
    assert!(status.success(), "building {source} failed");
    let status = Command::new("/usr/bin/codesign")
        .args(["--force", "--sign", "-"])
        .arg(&out)
        .status()
        .expect("run /usr/bin/codesign");
    assert!(status.success(), "signing the native ASTC layer failed");
}
