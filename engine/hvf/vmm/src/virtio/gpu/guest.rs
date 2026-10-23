//! The graphics part of the bootconfig: the guest image carries every
//! driver, and these keys pick them (init_graphics.vendor.rc copies them
//! into `ro.hardware.*`, `ro.vendor.hwcomposer.*` and `debug.angle.*`).

use super::{GpuMode, Hwc};

pub fn graphics_bootconfig(mode: &GpuMode) -> Vec<(&'static str, &'static str)> {
    match mode {
        // Guest SwiftShader on a virtio-gpu (KMS) display.
        GpuMode::TwoD => vec![
            ("androidboot.cpuvulkan.version", "4206592"),
            ("androidboot.hardware.gralloc", "minigbm"),
            ("androidboot.hardware.hwcomposer", "ranchu"),
            ("androidboot.hardware.hwcomposer.display_finder_mode", "drm"),
            ("androidboot.hardware.hwcomposer.display_framebuffer_format", "bgra"),
            ("androidboot.hardware.egl", "angle"),
            ("androidboot.hardware.vulkan", "pastel"),
            ("androidboot.opengles.version", "196609"),
        ],
        // Cuttlefish's gfxstream_guest_angle: apps' GLES goes through guest
        // ANGLE to gfxstream Vulkan (vulkan.ranchu), Vulkan straight there,
        // both over the virtio-gpu ASG ring to the Mac's GPU. With client
        // composition SurfaceFlinger composes on the GPU too and the composer
        // only flips its target through KMS. GLES stays at 3.1 (196609):
        // whether a start's ANGLE can expose 3.2 (exposeES32ForTesting) is
        // the daemon's to say in the identity file with
        // ro.opengles.version (VMMEngine.exposesES32) — and the layer
        // checks the image's ANGLE for itself before honouring it.
        GpuMode::Gfxstream { hwc, .. } => {
            let mut keys = vec![
                ("androidboot.cpuvulkan.version", "0"),
                ("androidboot.hardware.gralloc", "minigbm"),
                ("androidboot.hardware.hwcomposer", "ranchu"),
                ("androidboot.hardware.hwcomposer.display_finder_mode", "drm"),
                ("androidboot.hardware.hwcomposer.display_framebuffer_format", "bgra"),
            ];
            if *hwc == Hwc::Client {
                keys.push(("androidboot.hardware.hwcomposer.mode", "client"));
            }
            keys.extend([
                ("androidboot.hardware.egl", "angle"),
                ("androidboot.hardware.vulkan", "ranchu"),
                ("androidboot.hardware.gltransport", "virtio-gpu-asg"),
                ("androidboot.opengles.version", "196609"),
                ("androidboot.hardware.angle_feature_overrides_enabled", ANGLE_FEATURES_ENABLED),
            ]);
            keys
        }
    }
}

/// Properties GPU mode adds to the image's (`/adb_debug.prop`, before the
/// device profile's, which win): Android's multifile EGL blob cache, at the
/// size ANGLE recommends (it logs "GL performance: HIGH: EGL blobcache
/// multifile is not enabled" otherwise). Each app keeps the GLSL it
/// translated and MoltenVK's MSL (its Vulkan pipeline cache) there, in
/// `/data/user_de/<user>/<package>/cache/com.android.opengl.shaders_cache.multifile`;
/// the stock single file holds 2 MiB in all and 64 KiB an entry, so a game's
/// shaders pushed each other out (400 programs: 3.9 ms each on a warm start,
/// 2.3 ms with this). Software keeps the image's settings.
pub fn graphics_properties(mode: &GpuMode) -> &'static str {
    match mode {
        GpuMode::TwoD => "",
        GpuMode::Gfxstream { .. } => "ro.egl.blobcache.multifile=true\nro.egl.blobcache.multifile_limit=134217728\n",
    }
}

/// ANGLE features every guest process turns on (`debug.angle.feature_overrides_enabled`,
/// at most 91 bytes like any writable property):
/// - mapUnspecifiedColorSpaceToPassThrough, as Cuttlefish sets it for gfxstream.
/// - preferDrawClearOverVkCmdClearAttachments: a glClear in the middle of a render pass
///   becomes a draw instead of vkCmdClearAttachments. The emulator's MoltenVK (1.4.0)
///   clears with a helper draw that binds its clear colours at Metal buffer 0 of the
///   vertex and fragment stages, where it put ANGLE's push constants, and does not bind
///   the push constants again; every later draw of that pass then reads the clear colour
///   as ANGLE's driver uniforms. White
///   (alpha 1.0f = 0x3f800000) unpacks to a vertex flip of (-1, 63/127): the rest of the
///   frame comes out mirrored left-right and squeezed into the middle half (Microsoft
///   Launcher, Skia/HWUI). MoltenVK 1.4.1 rewrote that state tracking.
///
/// This list is full, so exposeES32ForTesting (OpenGL ES 3.2, above) goes in
/// through `ANGLE_FEATURE_OVERRIDES_ENABLED` instead, which has no length
/// limit; the gfxstream sync layer writes that variable with this list's
/// names in it (guest/gfxsync/src/vk_layer.c).
const ANGLE_FEATURES_ENABLED: &str = "mapUnspecifiedColorSpaceToPassThrough:preferDrawClearOverVkCmdClearAttachments";

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn value<'a>(keys: &'a [(&str, &str)], key: &str) -> Option<&'a str> {
        keys.iter().find(|(k, _)| *k == key).map(|(_, v)| *v)
    }

    #[test]
    fn software_keeps_swiftshader() {
        let keys = graphics_bootconfig(&GpuMode::TwoD);
        assert_eq!(keys.len(), 8);
        assert_eq!(keys[0], ("androidboot.cpuvulkan.version", "4206592"));
        assert_eq!(value(&keys, "androidboot.hardware.vulkan"), Some("pastel"));
        assert_eq!(value(&keys, "androidboot.opengles.version"), Some("196609"));
        assert_eq!(value(&keys, "androidboot.hardware.hwcomposer.mode"), None);
        assert_eq!(value(&keys, "androidboot.hardware.gltransport"), None);
    }

    #[test]
    fn gfxstream_picks_the_gpu_drivers() {
        let client = graphics_bootconfig(&GpuMode::Gfxstream { dir: PathBuf::from("/e"), hwc: Hwc::Client });
        assert_eq!(value(&client, "androidboot.hardware.vulkan"), Some("ranchu"));
        assert_eq!(value(&client, "androidboot.hardware.egl"), Some("angle"));
        assert_eq!(value(&client, "androidboot.cpuvulkan.version"), Some("0"));
        assert_eq!(value(&client, "androidboot.hardware.gltransport"), Some("virtio-gpu-asg"));
        assert_eq!(value(&client, "androidboot.hardware.hwcomposer.mode"), Some("client"));
        assert_eq!(value(&client, "androidboot.opengles.version"), Some("196609"));
        let host = graphics_bootconfig(&GpuMode::Gfxstream { dir: PathBuf::from("/e"), hwc: Hwc::Host });
        assert_eq!(value(&host, "androidboot.hardware.hwcomposer.mode"), None);
        assert_eq!(host.len() + 1, client.len());
    }

    #[test]
    fn gpu_mode_turns_on_the_multifile_blob_cache() {
        assert_eq!(graphics_properties(&GpuMode::TwoD), "");
        let text = graphics_properties(&GpuMode::Gfxstream { dir: PathBuf::from("/e"), hwc: Hwc::Client });
        let lines: Vec<_> = text.lines().collect();
        assert_eq!(lines, ["ro.egl.blobcache.multifile=true", "ro.egl.blobcache.multifile_limit=134217728"]);
        assert!(text.ends_with('\n'), "the device profile's lines follow");
    }

    #[test]
    fn gfxstream_overrides_angle_features() {
        let keys = graphics_bootconfig(&GpuMode::Gfxstream { dir: PathBuf::from("/e"), hwc: Hwc::Client });
        let enabled = value(&keys, "androidboot.hardware.angle_feature_overrides_enabled").unwrap();
        // ANGLE splits the list at ':'; init copies it into a writable property (PROP_VALUE_MAX 92).
        assert_eq!(
            enabled.split(':').collect::<Vec<_>>(),
            ["mapUnspecifiedColorSpaceToPassThrough", "preferDrawClearOverVkCmdClearAttachments"]
        );
        assert!(enabled.len() < 92, "{} bytes", enabled.len());
        assert_eq!(value(&keys, "androidboot.hardware.angle_feature_overrides_disabled"), None);
        // Software (guest SwiftShader) keeps ANGLE's defaults.
        let software = graphics_bootconfig(&GpuMode::TwoD);
        assert!(software.iter().all(|(k, _)| !k.contains("angle_feature")));
    }
}
