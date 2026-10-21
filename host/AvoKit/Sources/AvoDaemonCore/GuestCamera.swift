import Foundation

/// Cameras that face back and front (HostAgent, "Cameras").
///
/// With cameras fed from the Mac (CameraSource, avo-vmm `--cameras`),
/// Android has two virtio-media capture devices: /dev/video1 is the back
/// camera and /dev/video2 the front one (/dev/video0 is the kernel's
/// v4l2loopback). The `.v4l2` variant of the image's camera APEX opens them
/// with AOSP's external camera HAL (hardware/interfaces/camera/device/default),
/// which as built has two things against it:
///
/// - every camera it finds faces "external" (`initDefaultCharsKeys`:
///   `ANDROID_LENS_FACING_EXTERNAL`), so apps that ask for the back or the
///   front camera (CameraX's DEFAULT_BACK_CAMERA, most scanners and video
///   calls) find none;
/// - without /vendor/etc/external_camera_config.xml it numbers cameras from
///   100 and allows 1280×720 at 7.5 frames a second, 1920×1080 at 5.
///
/// A copy of the known build of camera.device-external-impl.so changes the
/// facing's `mov w8, #2` into a call to code in the zero padding after
/// `.plt` (the R+X segment is extended over it). That code takes the facing
/// from the device's node, the last character of `mDevicePath`: video1
/// faces back, video2 front, anything else stays external. The copy also
/// reads its configuration from Avo's folder instead of /vendor/etc:
/// cameras 0 (back) and 1 (front) as on a phone, every size at 30 frames a
/// second, v4l2loopback left out.
///
/// Every boot with those cameras, when the nodes are the engine's devices
/// in that order, the copy is bind-mounted over the APEX's file (the image
/// stays as it is) and the camera HAL and cameraserver start again, as
/// GuestAudioHal does for the audio HAL.
///
/// Android lists its camera features (`android.hardware.camera`, `.front`,
/// `.any`, `.autofocus`, which Play and apps check) from files it reads
/// when it starts. The emulated camera APEX brings its own, the `.v4l2` one
/// none: on a VM with `remount` overlays (Google apps), a file declaring
/// them goes on the vendor overlay, so they are there from the next start
/// on, whichever cameras Android has. Without overlays, apps that check
/// them first see no camera.
enum GuestCamera {
    /// Which camera APEX Android started with (cuttlefish.rs).
    static let apexProperty = "ro.boot.vendor.apex.com.google.emulated.camera.provider.hal"
    static let fedAPEX = "com.google.emulated.camera.provider.hal.v4l2"
    static let library = "/apex/com.google.emulated.camera.provider.hal/lib64/camera.device-external-impl.so"
    /// The camera HAL's service (the APEX's init file).
    static let provider = "vendor.camera.provider-ext"
    static let staging = "/data/local/tmp/avo-camera"
    static let staged = staging + "/camera.device-external-impl.so"
    /// Where the copy reads its configuration (its own path, in place of
    /// /vendor/etc/external_camera_config.xml).
    static let configFile = staging + "/config.xml"
    static let featuresFile = "/vendor/etc/permissions/avo-cameras.xml"

    /// The device nodes in the engine's order: back, front.
    static let nodes = ["/sys/class/video4linux/video1/name", "/sys/class/video4linux/video2/name"]
    /// What the guest's virtio-media driver names its video devices.
    static let driverName = "virtio-media"

    struct Patch: Equatable {
        /// File offset.
        let offset: Int
        let bytes: [UInt8]

        init(offset: Int, hex: String) {
            self.offset = offset
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                bytes.append(UInt8(hex[index..<next], radix: 16)!)
                index = next
            }
            self.bytes = bytes
        }

        init(offset: Int, text: String, length: Int) {
            self.offset = offset
            bytes = Array(text.utf8) + Array(repeating: 0, count: length - text.utf8.count)
        }
    }

    /// One known build of the library and what changes in it.
    struct Build: Equatable {
        let sha256: String
        let patchedSHA256: String
        let patches: [Patch]
    }

    static let builds = [
        // AOSP Cuttlefish 16644040 (aosp_cf_arm64_only_phone-userdebug, Android 17).
        Build(sha256: "3d76aec205f9103cff796896114af0666ab183b54d091fe5d4a35f5d2a214dd8",
              patchedSHA256: "2b81a1a1cee8407dbb521271ca9847bc8039ea8abb2fd888e049f6410dd6bd04",
              patches: [
                  // R+X LOAD: p_filesz and p_memsz 0x3c060 → 0x3d000 (to 0x65000; the next segment is at 0x68000).
                  Patch(offset: 0xd0, hex: "00d0030000000000"),
                  Patch(offset: 0xd8, hex: "00d0030000000000"),
                  // 0x64080 (x20 is `this`, mDevicePath a libc++ string at +0x98):
                  //   ldrb w8, [x20, #0x98]; tbnz w8, #0, 1f   (a long path: not ours)
                  //   lsr w8, w8, #1; add x8, x20, x8; ldrb w8, [x8, #0x98]   (its last character)
                  //   sub w8, w8, #'1'; cmp w8, #1; b.hi 1f; eor w8, w8, #1; ret   ('1' back, '2' front)
                  //   1: mov w8, #2; ret   (external, as before)
                  Patch(offset: 0x64080, hex: """
                      8862423928010037087d01538802088b0861423908c500511f0500716800005408010052c0035fd648008052c0035fd6
                      """),
                  // initDefaultCharsKeys: `mov w8, #2` (ANDROID_LENS_FACING_EXTERNAL) → `bl 0x64080`.
                  Patch(offset: 0x2dfa4, hex: "37d80094"),
                  // ExternalCameraConfig::kDefaultCfgPath's string.
                  Patch(offset: 0x1a0bb, text: configFile, length: 39),
              ]),
    ]

    enum State: Equatable {
        /// A known build, still as the image has it.
        case stock(Build)
        /// The patched copy runs (the daemon came back to a running Android).
        case patched
        /// Another build: left as it is.
        case unknown
    }

    /// From `sha256sum <library>`.
    static func state(sumOutput: String) -> State {
        let sum = sumOutput.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if let build = builds.first(where: { $0.sha256 == sum }) { return .stock(build) }
        if builds.contains(where: { $0.patchedSHA256 == sum }) { return .patched }
        return .unknown
    }

    /// The HAL's configuration (ExternalCameraUtils.cpp `loadFromCfg`; it
    /// stops reading at a Provider without `ignore`).
    static let config = """
        <?xml version="1.0" encoding="utf-8"?>
        <!-- Avo (GuestCamera): the cameras the Mac feeds, through virtio-media. -->
        <ExternalCamera>
            <Provider>
                <!-- /dev/video1 is camera 0 (back), /dev/video2 camera 1 (front). -->
                <CameraIdOffset>-1</CameraIdOffset>
                <ignore>
                    <!-- v4l2loopback -->
                    <id>0</id>
                </ignore>
            </Provider>
            <Device>
                <NumVideoBuffers count="4"/>
                <NumStillBuffers count="2"/>
                <FpsList>
                    <Limit width="640" height="480" fpsBound="30.0"/>
                    <Limit width="1280" height="720" fpsBound="30.0"/>
                    <Limit width="1920" height="1080" fpsBound="30.0"/>
                </FpsList>
            </Device>
        </ExternalCamera>

        """

    /// The camera features Android lists (frameworks/native/data/etc).
    static let features = """
        <?xml version="1.0" encoding="utf-8"?>
        <!-- Avo (GuestCamera): the cameras the Mac feeds have no APEX features of their own. -->
        <permissions>
            <feature name="android.hardware.camera" />
            <feature name="android.hardware.camera.any" />
            <feature name="android.hardware.camera.autofocus" />
            <feature name="android.hardware.camera.front" />
        </permissions>

        """

    /// `printf` octal escapes for `bytes`.
    static func escapes(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "\\%03o", $0) }.joined()
    }

    /// Run as root: the patched copy, checked against its hash, and its
    /// configuration, mounted over the APEX's file; then the HAL and
    /// cameraserver start again. Fails (and leaves the HAL as it was) when
    /// any step does, or when the nodes are not the engine's cameras.
    static func installScript(_ build: Build) -> String {
        var lines = ["set -e"]
        for node in nodes {
            lines.append("[ \"$(cat \(node) 2>/dev/null)\" = \(driverName) ]")
        }
        lines += [
            "rm -rf \(staging)",
            "mkdir -p \(staging)",
            "cp \(library) \(staged)",
        ]
        for patch in build.patches {
            lines.append("printf '\(escapes(patch.bytes))' | dd of=\(staged) bs=1 seek=\(patch.offset) conv=notrunc 2>/dev/null")
        }
        lines += [
            "[ \"$(sha256sum \(staged) | cut -d ' ' -f 1)\" = \(build.patchedSHA256) ]",
            "printf '%s' '\(config)' > \(configFile)",
            "chown root:root \(staged) \(configFile)",
            "chmod 755 \(staging)",
            "chmod 644 \(staged) \(configFile)",
            "chcon \"$(ls -Z \(library) | cut -d ' ' -f 1)\" \(staged)",
            "mount -o bind \(staged) \(library)",
            "setprop ctl.restart \(provider)",
            "setprop ctl.restart cameraserver",
        ]
        return lines.joined(separator: "\n")
    }

    /// The features file is on the vendor overlay already.
    static var featuresCheck: String {
        "[ \"$(cat \(featuresFile) 2>/dev/null)\" = '\(features.trimmingCharacters(in: .newlines))' ]"
    }

    /// Run as root: the features file on the vendor overlay, for the next
    /// boot on. Fails when there are no overlays.
    static var featuresScript: String {
        [
            "set -e",
            "grep -q '^overlay /vendor overlay' /proc/mounts",
            "remount >/dev/null 2>&1",
            "printf '%s' '\(features)' > \(featuresFile)",
            "chmod 644 \(featuresFile)",
            "chcon u:object_r:vendor_configs_file:s0 \(featuresFile)",
            "sync",
        ].joined(separator: "\n")
    }
}
