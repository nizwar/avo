# Engine: avo-vmm on Hypervisor.framework

Avo runs Android in a virtual machine of its own, `avo-vmm`
([engine/hvf/vmm](../engine/hvf/vmm)), a Rust VMM built directly on Apple's
Hypervisor.framework (HVF). It boots an unmodified AOSP Cuttlefish image and
provides the virtio devices Cuttlefish expects, with Mac implementations
behind them (Core Audio, Metal through gfxstream and MoltenVK, user-mode
networking, FSEvents-backed virtio-fs). This document describes the engine,
its devices and its contract with the Runtime Daemon.

## avo-vmm and the Cuttlefish image

The engine boots a prebuilt AOSP Cuttlefish image (`aosp_cf_arm64_only_phone-userdebug`
from ci.android.com, which the Setup Assistant or `scripts/fetch-cuttlefish.sh`
downloads; see architecture.md, "Android images (Cuttlefish)"). The daemon
picks it when `Avo.app/Contents/MacOS/avo-vmm` exists (`VMMEngine`) and looks
up the image at every start (`CuttlefishImage.prepareStart`); without avo-vmm
it falls back to the legacy crosvm contract at the end of this document,
which no shipping build uses.

**The engine.** HVF with the in-kernel GICv3, SMP vCPUs and PSCI; virtio-pci
devices in Cuttlefish's layout: block (composite GPT disk), 20 consoles,
rng, vsock (hybrid `CONNECT <port>` socket), a virtio-gpu (2D, or gfxstream
3D, see "GPU" below) with 16 hot-pluggable scanouts, one touchscreen per scanout, a keyboard, three NICs,
a sound card and a gamepad (an Xbox One S pad, 045e:02ea, which
Android maps with its stock key layout); with `--shared-dir`, a virtio-fs
device comes last (see "Shared folder" below). Frames go to shared memory
(`frames/scanout-<i>-<generation>.frames`, triple buffered).

- **Network** (`net.rs`, virtio-net): eth2 is the one with a carrier;
  Cuttlefish's `setup_wifi` turns it into wlan0, so Android is on Wi-Fi
  ("VirtWifi"). User-mode NAT like the Android Emulator's: DHCP gives
  10.0.2.15, 10.0.2.2 is the gateway and the Mac's own 127.0.0.1, 10.0.2.3
  the DNS server (the Mac's resolver from /etc/resolv.conf). Guest TCP ends
  in smoltcp and goes on over ordinary Mac sockets (SYN-ACK only once the
  Mac's connection is up), UDP per guest port, ping through the Mac's
  unprivileged ICMP socket. No privileges, no vmnet entitlement, no ports
  opened on the Mac. eth0 (mobile data, `buried_eth0`) has a network of
  its own with the same addresses, for the modem's data calls (below);
  eth1 (Ethernet) has no carrier.
- **Sound** (`virtio/sound.rs`, virtio-snd): one playback and one capture
  stream, S16 8–48 kHz, through Core Audio's AudioQueue on the Mac's default
  output and input. Playback runs on the device's own clock, one period
  per period starting 100 ms behind the guest's first (`play_period`): each
  period is done on time whatever Core Audio does, and its audio goes to the
  Mac's queue, which holds at most 120 ms (whole periods, at least two) after
  a 30 ms lead-in of silence; a period that finds it full is dropped on the
  Mac. A period that finds it empty (a late tick, the gap after the
  lead-in) starts 30 ms after the queue's playhead
  (`AudioQueueEnqueueBufferWithParameters`): the queue's timeline runs on
  while it is empty, a period enqueued plainly is due in the past, and
  AudioQueue drops its past frames yet hands it back as played. With 20 ms
  periods that was all of every period after a single hiccup: the guest,
  the tap and recordings had the sound, the Mac played silence (coreaudiod's
  IO reports showed no non-zero cycles). When periods were done only once the Mac had played them, every Core
  Audio hiccup filled the guest's ring and its HAL dropped whole 85 ms
  chunks ("incomplete data sent, dropping 4096 frames"): robotic, broken
  sound. Measured on the test VM (60 s, two AAudio streams, OpenSL and four
  busy threads, host load about 7): 0 HAL drops mid-stream, 0 skips, 0
  xruns with 20 ms HAL periods, at default and Oboe-sized (two-burst)
  buffers. Capture runs
  on a clock, the microphone joins when macOS allows it (the daemon asks in
  Avo's name when Android first records, `microphone` event), and never
  while Settings › Devices keeps it from Android (`microphone off` on the
  control socket, `--no-microphone` from the start: Android records
  silence, and turning it off closes a microphone that is open). A start is
  answered at once and the AudioQueue opens on a thread of its own (the
  first one in a process took 2 s on a vCPU, and Android's audio stalled for
  as long); Core Audio is warmed up in the background when the device
  activates. The guest's last period in flight is handed back only when it
  sends the next one (or after 1 s): Linux's virtio_snd follows the device
  by its position in the ring, and when every period came back before it
  looked (a burst of AudioQueue callbacks, or its worker late under load)
  the position read as no progress, the driver sent nothing more and
  Android stayed silent ("Error writing into ALSA: -1") until the stream
  closed. A watchdog replaces a queue that has buffers but plays none for
  500 ms. `AVO_VMM_SOUND_DEBUG=1` logs the control requests and, every 2 s,
  the playback counters (received, played, held, restarts, queue depth). What the Mac
  has played (or, without an output device, the clock has used up) also goes
  into a ring in shared memory for screen recordings (`virtio/sound/tap.rs`:
  `<instance>/audio/playback.ring`, a 4 KiB header and 512 seqlocked slots of
  S16 PCM, each with the host time its first frame played at), one per
  process, announced by the sticky `audio playback <epoch> <path>` event.
  `AVO_VMM_MUTE=1` sets the Mac's playback volume to 0 and leaves the
  microphone closed (tests on a Mac someone is using); the ring still gets
  the sound. Only the
  HAL's ordinary streams reach ALSA: its MMAP streams (AAudio's low-latency
  path, which games take through Oboe, Wwise or Unreal) and its compressed
  offload are stubs (output dropped on a simulated clock, MMAP input random
  noise). Every boot `HostAgent` bind-mounts the primary module's
  configuration without those mix ports and restarts audioserver
  (`GuestAudioPolicy`): the HAL then reports MMAP as never supported, so
  AAudio uses AudioTrack and AudioRecord like OpenSL ES and Java apps do,
  nothing is offloaded, and every stream goes through the mixer. The HAL
  also refuses buffers under 85 ms (`ModulePrimary`'s `kStandardLatencyMs`,
  a constant no property changes), so the mixer took 4096 frames from every
  track per cycle and a game that sizes its buffer from the 20 ms burst it is
  given (two bursts with Oboe) underran every cycle: over half its sound was
  silence. On the known HAL build (by SHA-256) the same boot step bind-mounts
  a copy with that one instruction set to 20 ms, and sets
  `ro.hardware.audio.tinyalsa.period_size_multiplier=2`, so ALSA gets four
  512-frame periods instead of 256-frame ones (`GuestAudioHal`): the mixer
  runs in 21 ms periods. Measured on the test VM: a two-burst AAudio stream
  went from 11 underruns a second to none, and a game's write to the Mac
  playing it from about 255 ms (AAudio's default buffer) to about 82 ms.
  The same copy asks for input pipes twice as large: the HAL's input thread
  writes each buffer it reads from ALSA into a blocking MonoPipe of one
  buffer, whose pacing slept 1.15 buffers per write, so recording took
  23 ms of the device's time for every 20 ms of sound and lost about 13% of
  it as 20 ms holes (voice chat in Call of Duty: Mobile came across choppy
  or not at all). A two-instruction stub in the HAL's alignment padding
  doubles the size of pipes whose writer blocks (only input ones).
- **Cameras** (`virtio/media.rs`, `camera.rs`; with `--cameras`):
  two V4L2 capture devices in ChromeOS's virtio-media protocol (device
  48), back then front as two functions of one PCI device, so the guest's
  `virtio_media` module (loaded after v4l2loopback's /dev/video0) makes
  them /dev/video1 and /dev/video2. Each streams Motion-JPEG at 640×480,
  1280×720 or 1920×1080, 30 or 15 frames a second, from MMAP buffers in
  its shared memory region (shmid 0, 64 MiB of Mac memory mapped into
  BAR 2 whole). The bootconfig then picks the `.v4l2` variant of the
  image's camera APEX, AOSP's external camera HAL, instead of the emulated
  cameras. Frames come from the daemon (below); a camera Android does not
  have lists no format, and the HAL passes it over.
- **Modem** (`modem.rs`): Cuttlefish's radio HAL needs a modem simulator
  (AT commands over vsock 9600), or the phone process fails to start
  forever. This one has no SIM ("No SIM", a Wi-Fi-only phone) until the
  control socket's `cellular` or `--cellular` puts in a test SIM: PLMN
  001/01 named Avo (the image's APN list has APNs for it), IMSI
  001010123456789, ICCID 89001010000000000018, number +1 555 555 0100,
  registered at home on GPRS, EDGE, UMTS, HSPA, LTE or NR (standalone)
  with 0–4 signal bars by Android's default thresholds. A data call gets
  10.0.2.15/24, gateway 10.0.2.2 and DNS 10.0.2.3 on `buried_eth0`, whose
  network is NAT like the Wi-Fi's, under the same `network` limits. The
  answers are what Cuttlefish's reference RIL (reference-ril.c) reads,
  mostly as its modem simulator gives them; a change reaches a running
  Android as unsolicited lines: `+CREG` and `+CSQ` for another network
  type, `+CSQ` for other bars, `+CFUN: 0` for the SIM going in or out (the
  RIL reads the SIM only when the radio's state changes; Android turns the
  radio on again at once, or, in airplane mode, when it turns it on). The
  IMEI is the radio HAL's own (867400022047199). Calls and SMS fail.
  Android's status bar shows the bars, and the network type (G, E, 3G, 3G,
  LTE or 4G as the carrier config says, 5G) only while mobile data is its
  default network, not beside Wi-Fi.
- **Shared folder** (`virtio/fs.rs`, `virtio/fs/server.rs`; `--shared-dir
  <folder>`): virtio-fs (device 26, tag `avo_shared`, one request queue of
  1024, no DAX window) with a FUSE 7.31 server over the Mac folder: nodes
  are the Mac's inodes, found by path, so nothing stays open on a drive but
  the files Android has open; names with a slash, "." or "..", directories
  that are symlinks and symlinked files (O_NOFOLLOW) are refused, so nothing
  outside the folder is reachable; every file is media_rw's (1023, 0770 and
  0660); errno values are translated to Linux's; names and attributes are
  good for a second, and the page cache follows size and time changes
  (AUTO_INVAL_DATA). Extended attributes, locks, fallocate and Android's
  FUSE_CANONICAL_PATH answer ENOSYS. A folder that is not there at the start
  (an unplugged drive) leaves the device out with a line in the log. The
  daemon mounts it in Android (architecture.md, "The shared folder").
  Cuttlefish's own fstab tries a virtiofs tag `shared` at /mnt/vendor/shared
  (nofail), which is why Avo's tag differs.
- **Reboots** (`cuttlefish.rs` `run`): a guest reboot (PSCI SYSTEM_RESET)
  builds a new machine in the same process, unless `--exit-on-reboot`
  (the daemon always passes it): then avo-vmm exits 77 (EXIT_GUEST_REBOOT)
  and the daemon starts Android again. A reboot that leaves recovery's
  `--wipe_data` on misc (Android's factory reset) exits 76
  (EXIT_FACTORY_RESET) either way; a recovery request left on misc from
  before is dropped before each boot.
- The engine raises its threads to user-initiated QoS (the sound clock to
  user-interactive): the daemon it inherits from runs at utility.

**GPU (gfxstream).** Graphics › Renderer: Automatic (the default), GPU
(Metal) or Software. With the GPU, Android's GLES (guest ANGLE) and Vulkan
(`vulkan.ranchu`) go through gfxstream to MoltenVK and Metal; apps get
GLES 3.2 and Vulkan 1.3.

- **The renderer** ships in Avo.app (`Contents/Resources/gfxstream`, built
  from source by `scripts/build-gfxstream.sh`, `make gfxstream`): gfxstream's
  host backend at the snapshot the Android Emulator 37.1 has (emu-main-dev
  `ec3143b`, built standalone, so it needs only the system's libraries), the
  Khronos Vulkan loader 1.4.365 and MoltenVK 1.4.0 (the release binary), in
  the emulator's layout (`lib64/`, `lib64/vulkan/`), its `source.properties`
  saying `Pkg.Desc=Avo GPU renderer…` and `Pkg.Revision=avo.N`, which keys
  the shader cache. Avo's build carries two patches
  (`scripts/gfxstream-patches`, tested by their `tests/run.sh`): a sequence
  gate that keeps a guest process's commands in order, and can let go of
  numbers guest threads took but never sent (`AVO_GFXSTREAM_SEQNO_SKIP_MS`,
  0 by default, which never skips: Avo's guest layer keeps that deadlock
  away, and a host too busy to take a sent number in time would run commands
  out of order); and one that hides the linear ASTC sampling avo-vmm's layer
  reports (below) from the guest. The daemon passes it unless
  `defaults write com.avodroid.daemon AvoAndroidEmulator <dir>` names another; an
  Android Emulator 37 or later (`~/Library/Android/sdk/emulator`) is the
  fallback. avo-vmm loads `lib64/libgfxstream_backend.dylib` at run time by
  absolute path, an emulator's after the ten libraries it needs (Avo never
  ships those: Android SDK licence). The emulator's dylibs carry Google's Team
  ID, so avo-vmm is signed with `com.apple.security.cs.disable-library-validation`
  (`engine/hvf/hypervisor.entitlements`).
- **Flags**: `--gpu gfxstream --gfxstream-dir <renderer dir>` (the daemon adds
  them after `--properties`); none, or `--gpu 2d`, is the software engine bit
  for bit. `--hwc client|host` is a bring-up knob the daemon never passes.
- **Exit 75**: the renderer could not load or initialise (within 20 s), before
  any guest code ran; stderr has `error: gpu: <reason>`.
- **Device**: features VIRGL, RESOURCE_BLOB and CONTEXT_INIT, capsets
  gfxstream-vulkan (3) and gfxstream-composer (9), and an 8 GiB 64-bit
  host-visible BAR2 in a MEM64 window at 0x8_0000_0000. Bootconfig switches
  the unchanged guest to `gfxstream_guest_angle` with client composition
  (`hwcomposer.mode=client`), and turns on two ANGLE features in every guest
  process (`debug.angle.feature_overrides_enabled`):
  `mapUnspecifiedColorSpaceToPassThrough`, as Cuttlefish does, and
  `preferDrawClearOverVkCmdClearAttachments`. The emulator's MoltenVK (1.4.0)
  runs `vkCmdClearAttachments` as a helper draw that leaves its clear colours
  bound where ANGLE keeps its push constants, so whatever an app drew after a
  `glClear` in the middle of a frame came out mirrored left-right and squeezed
  into the middle half (Microsoft Launcher); ANGLE now clears with its own draw.
  A third, `exposeES32ForTesting` (OpenGL ES 3.2), goes in through
  `ANGLE_FEATURE_OVERRIDES_ENABLED`, which the gfxstream sync layer writes in
  every process as it loads, with the property's names: the property is full
  at 91 bytes. Settings › Graphics' "OpenGL ES" below 3.2 leaves it out and
  takes the requirements ANGLE checks away (the sync layer again), so a
  start caps contexts at 2.0, 3.0 or 3.1 (`VMConfig.glesVersion`).
- **Guest Vulkan layer** (`guest/gfxsync`, `GuestGfxstreamSync`): HostAgent
  installs `VK_LAYER_AVO_gfxstream_sync` in `/data/local/debug/vulkan` and
  names it in `debug.vulkan.layer.9` (from the boot after the first install),
  so every Vulkan instance, ANGLE's included, goes through it. It keeps the
  guest driver from deadlocking (presents wait outside the driver's lock), and
  splits each fragment output array into one output per element: the
  emulator's MoltenVK cannot make a pipeline from a shader such as ANGLE's
  `gl_FragData[8]` when the subpass has fewer colour attachments ("'color'
  attribute must be made explicit"; Need for Speed No Limits hit it).
  `guest/gfxsync/test/run.sh` checks the split against that MoltenVK on the Mac.
  It also gives ANGLE's own instance `VK_EXT_provoking_vertex`
  (`provokingVertexLast`), which neither the driver nor MoltenVK has: the
  image's ANGLE (`8d8796935e4f`) offers no GLES above 2.0 without it ("required
  for flat shading"; ANGLE up to mid-2025 offered 3.1 regardless), so before
  this apps got ES 2.0 contexts only. The layer takes the extension, its
  feature structure and the pipelines' provoking-vertex state out again
  before the driver sees them, so `flat` varyings come from a primitive's
  first vertex instead of its last. Apps' own Vulkan instances see it too:
  avo-vmm's layer (below) offers it to every instance. The layer also turns
  on ANGLE's `exposeES32ForTesting` as it loads (the constructor in its
  source): OpenGL ES 3.2, which ANGLE otherwise caps at 3.1, for ANGLE asks
  after twenty-four extensions and one is missing — geometry shaders, and
  that one twice over: Metal has no stage to run one on, and ANGLE offers
  the extension only over native `VK_EXT_transform_feedback` (its own
  emulation of GLES transform feedback, which is what runs here — MoltenVK
  has none of the transform-feedback or generated-primitives extensions
  among its 136 — cannot stand behind a geometry stage). Pretending the
  extension exists instead would send every app's core ES 3.0 transform
  feedback down a native path whose functions are not there. The way in,
  one day, is upstream: ANGLE emulating geometry shaders, or MoltenVK
  building them on Metal's mesh shaders. Border-colour samplers, the second the driver lacks, the layer
  stands in for: it offers `VK_EXT_custom_border_color` to ANGLE alone and
  answers its features, and takes each sampler's custom border colour to
  the nearest of Metal's six fixed ones (GLES's default (0,0,0,1) and the
  black and white corners are exact) before the driver sees it. Advanced
  blend equations, which x86 emulators miss too, ANGLE emulates itself on
  Android through framebuffer fetch, which Apple GPUs do; tessellation,
  cube map arrays, sample shading and GPUShader5 are the hardware's. Apps
  get 3.2 contexts; one that asks for geometry shaders finds their limits
  at zero. The feature rides in the daemon's identity file only when the
  image's ANGLE has it — both images Avo offers do (the Android 16's
  ab6a82e0ed and the 17's 8d8796935e4f; an ANGLE without it would ignore
  the name while Android promised 3.2 contexts it cannot make —
  `VMMEngine.exposesES32`). The bootconfig's floor is 3.1, and on an image
  without the Vulkan driver wrapper the processes that start before the
  daemon names the layer (SurfaceFlinger, system_server, SystemUI) keep
  the cap of their own ANGLE for that boot; apps started after get 3.2. Settings › Graphics' "OpenGL ES" picks a
  lower cap (`debug.avo.gl.max`): 3.1 leaves the feature out; 3.0 also
  answers ANGLE's storage-buffer count question with a number under ES
  3.1's requirement; 2.0 also offers no `VK_EXT_provoking_vertex`.
  `ro.opengles.version` says the same choice. Processes that start before HostAgent names the layer, every boot
  (SurfaceFlinger, system_server, SystemUI), stay at ES 2.0; they work with
  either. A software start removes the file: unnamed, libvulkan still
  opens every `libVkLayer*.so` in that folder in every app (userdebug), and
  apps whose packer refuses libraries from `/data/local` kill themselves when
  one turns up (FLUJO, ijiami). A Renderer change or "Try GPU Again" puts it
  back before the restart, so the GPU start names it at once.
- **Vulkan driver wrapper** (`guest/vkwrap`, `GuestVulkanWrapper`): where
  Android has the overlays of a `remount` (Google apps) and the known vendor
  build, the sync layer and the GPU profile layer run inside the Vulkan
  driver instead, so a GPU start puts nothing of Avo's in
  `/data/local/debug` and FLUJO runs — and the profile spoof works on a
  build that is not debuggable, where Android ignores that folder. HostAgent
  puts a wrapping `vulkan.ranchu.so` on the vendor overlay, with a copy of
  the real driver beside it (once Android is ready), and an init file
  bind-mounts that folder over the APEX's `hw` folder at `post-fs-data` on a
  GPU start whose identity.prop has `ro.boot.avo.vkwrap=1`. Inside, the app
  faces the profile layer, which passes what it does not wrap to the sync
  layer, which calls the real driver; the wrapper builds the chain's links
  itself, for a HAL driver gets none, and the profile layer's loader entry
  points are renamed in the one library (`avo_profile_*`). Below libvulkan
  the sync layer sees presents as `QueueSignalReleaseImageANDROID`, one per
  image, and new handles before libvulkan writes its dispatch pointer into
  them; it handles both. Every process uses the wrapper from the start, so
  SurfaceFlinger and SystemUI get ES 3.1 too. A GPU start that fails while
  the wrapper runs turns it off for that build of it (`vkwrap-failed.json`),
  and the GPU gets one more start without it before Avo falls back to
  software.
- **Native ASTC** (`engine/hvf/vmm/layer/native_astc.c`, `virtio/gpu/astc.rs`):
  gfxstream decompresses ASTC into RGBA8 itself unless the driver samples
  *linear-tiled* ASTC, which Metal never does, and an emulated ASTC texture
  asks for 5x (4x4), 10x (6x6) or 17x (8x8) its memory: UE4 games sized their
  texture streaming by that and dropped mip levels within a second (Delta
  Force: sharp, then blurry). avo-vmm writes a Vulkan layer (built by
  build.rs, signed ad hoc) to the temporary folder and names it to the loader
  (`VK_ADD_LAYER_PATH`, `VK_INSTANCE_LAYERS`); it reports sampled, linear
  filtered linear tiling for ASTC, so gfxstream passes ASTC to Metal, and the
  guest layer hides those two bits from apps again. `avo-vmm.log` says
  `[gpu] ASTC goes to Metal natively`; `AVO_NATIVE_ASTC=0` brings the
  emulation back. Measured in a test VM: 1.0x memory, the ASTC probes all
  correct through Vulkan and ANGLE. Metal still refuses
  `BLOCK_TEXEL_VIEW_COMPATIBLE` ASTC images, which MoltenVK reports as
  unsupported. With the emulation on (`AVO_NATIVE_ASTC=0`), gfxstream
  decompresses only on a `vkCmdPipelineBarrier`: after a
  `vkCmdPipelineBarrier2` or `vkCmdWaitEvents` into a sampled layout the
  guest layer adds one, and it turns `vkCmdCopyBufferToImage2` into
  `vkCmdCopyBufferToImage`, whose data gfxstream keeps (otherwise such
  textures read back black, stale or magenta). The same layer traces what
  the guest's renderers ask of MoltenVK when `AVO_VK_TRACE=1` is set or
  `~/Library/Logs/Avo/vk-trace.on` exists as the engine starts: each kind of
  image, view and sampler, every layout past Metal's 16 samplers a stage, the
  device's memory types and each memory type and size class allocated (0x10
  is lazily allocated, Metal's memoryless), and every failed pipeline, image,
  image-format query, allocation or image binding, once each, with the time,
  as `[vk-trace]` lines in `avo-vmm.log`. Off, it hooks nothing.
- **No memoryless memory** (the same layer, always on; `AVO_NATIVE_ASTC=0`
  turns off only the ASTC part): MoltenVK's last memory type is lazily
  allocated (Metal's memoryless storage, 0x11), and MoltenVK gives it only to
  transient attachments that are not input attachments. ANGLE makes every
  implicit multisampled image (GL's multisampled render to texture: WebGL's
  antialiased canvases, games' MSAA) a transient attachment needing lazily
  allocated memory whenever such a type exists, and a color one is an input
  attachment too, so no type fit and ANGLE's allocator failed with
  `VK_ERROR_FEATURE_NOT_PRESENT` (`initMemoryAndNonZeroFillIfNeeded` in
  logcat): the image had no memory and the game drew garbage there (PUBG's
  WebView pages, its end screen). The layer drops that type from the memory
  properties gfxstream reads, and its bit from image memory requirements and
  Metal handle properties, so ANGLE gives those images ordinary device
  memory. Checked against MoltenVK 1.4.0 directly: without the layer a 4x
  color image with ANGLE's usage finds no type; with it, type 0 allocates and
  binds.
- **The guest layer's jobs on the Mac** (the same layer), for a guest that
  runs without Avo's guest layer: it splits fragment output arrays, and it
  offers `VK_EXT_provoking_vertex` (taken out again before MoltenVK) to every
  instance, not only ANGLE's. The guest driver keeps the first extension list
  it gets in a process, so when an app's own instance (or HWUI's) asked
  first, ANGLE got that list and the app's GL stayed at OpenGL ES 2.0. An
  app's own Vulkan that turns `provokingVertexLast` on gets flat varyings from
  the first vertex, as ANGLE does; few apps do (console emulators, mostly).
- **Frames**: on each flush the engine reads the composed buffer back into the
  same shared-memory frames as software (0.6–1.2 ms a frame measured at
  720×1280 and 1080×1920), so the daemon, MetalFX and recording are
  unchanged. Zero-copy IOSurfaces come with our own gfxstream build.
- **Engine** (`virtio/gpu/render.rs`): one `gpu-render` thread makes every
  gfxstream call (vCPUs only post work; gfxstream's fence callback only posts
  the fence); fenced requests are answered when gfxstream signals them, and a
  guest reboot or device reset purges the guest's contexts, resources and
  maps while the renderer stays. Blobs are mapped into BAR2 with `hv_vm_map`
  before the guest hears back, in whole 16 KiB pages only. While frames flow
  `avo-vmm.log` gets `[gpu] ctx=… res=… blobs=… mapped=… fences=… flush/s=…
  readback avg/max=… rejected-maps=… unknown=… errors=…` every 5 s, and
  gfxstream's errors and warnings as `[gfxstream] …`.
- **Shader cache** (`virtio/gpu/cache.rs`, `GPUCache.swift`): a shader's
  first use is almost all Metal compiling MoltenVK's MSL (about 100 ms a
  program measured). ANGLE's GLSL→SPIR-V in the guest and MoltenVK's
  SPIR-V→MSL take about 2 ms together. Metal keeps what it compiled. Before
  gfxstream starts, avo-vmm points Metal's cache (`MTLSetShaderCachePath`) at
  `~/Library/Caches/Avo/gpu-cache/<key>/metal`; otherwise it would sit in
  Avo.app's folder of `DARWIN_USER_CACHE_DIR`, shared with the Control Panel,
  with no limit of Avo's and nothing Avo could clear. The key names the
  emulator revision, Vulkan driver, chip and macOS build
  (`emulator-37.1.11_moltenvk_apple-m4-pro_macos-26a434`, described in its
  `last-used` file). Each Metal cache file is capped at 512 MiB
  (`MTL_SHADER_CACHE_SIZE`; Metal's default is 1 GiB). Every start removes
  other keys unused for 30 days, then, oldest first, whatever keeps the
  folder over 2 GiB. `AVO_GPU_CACHE_DIR` names another folder; `off` leaves
  Metal's default.
  - **Guest**: GPU mode turns on Android's multifile EGL blob cache
    (`ro.egl.blobcache.multifile`, 128 MiB per app, as ANGLE recommends in its
    "GL performance: HIGH" log), where each app keeps ANGLE's programs and
    MoltenVK's pipeline cache (`/data/user_de/<user>/<package>/cache/`). The
    stock single file holds 2 MiB and lost a game's shaders.
  - **Clearing**: Graphics › Clear GPU cache (`clearGPUCache`; `gpuCacheStatus`
    gives the size; `avoctl gpu-cache [clear]`) empties the Mac's folder. A
    running engine keeps what it has loaded.
  - **Measured** (test VM, 150 GLES 2.0 programs, each compiled, linked and
    drawn once, 3 a frame):

    | Run | Time per program | Total | Worst frame |
    |---|---|---|---|
    | Cold | 100 ms | 15.1 s | 344 ms (every frame over 100 ms) |
    | From both caches | 2.3 ms | 0.8 s | 21 ms |
    | After an engine restart (400 programs) | 2.5 ms | 1.0 s | 91 ms |
    | Android's caches cleared | 4.5 ms | 0.9 s | 47 ms |
    | Metal's cache cleared | 93 ms | 14.0 s | 512 ms |

    With 400 programs and a warm start, the single-file blob cache gave
    3.9 ms per program; the multifile cache gives 2.3 ms.
- **Fallback** (`VMMEngine`, `GPURenderer.swift`): exit 75 or a crash while
  starting, `gpu stalled`, or no `gpu first-frame` within 60 s of `gpu context`
  (Android's first rendering context; Android has 10 minutes to get there, as
  a first boot spends minutes on ART and the new data before any graphics)
  restarts Android in software. So do two crashes within 10 minutes
  after Android was ready, from the next start. The choice is kept in
  `vm/gpu-fallback.json` until Try GPU Again, a Renderer change, or a new
  avo-vmm, emulator or macOS; the Graphics pane and a banner say why, and the
  failed log is kept as `avo-vmm-gpu-failed.log`.
- **Limits**: one refresh rate for all of Android's displays per boot (60
  to 120 Hz; below), ES 3.2 without geometry shaders alone — of its
  twenty-four, the one Metal has no stage for (above; a 3.2 context, their
  limits at zero; border colours are the nearest fixed one, the blends are
  ANGLE's own emulation) — first-vertex
  `flat` varyings, no zero-copy
  yet, no quick boot (below, after "Pause").
- **Refresh rate** (`virtio/gpu/edid.rs`, both modes): the virtio-gpu offers
  EDIDs (`VIRTIO_GPU_F_EDID`). A scanout's preferred timing is its size at
  its rate, 60 Hz unless `display <i> <w> <h> <hz>` or, for display 0,
  `--refresh-rate` gives another (any whole rate from 24 to 240); the other
  rates of 60, 90 and 120 follow. Timings have little blanking and a pixel
  clock that makes the rate exact; sizes over 4095 pixels, clocks over
  655 MHz (4K at 120 Hz) and a fourth timing (a rate besides 60, 90 and 120,
  such as 75) go into a DisplayID extension, which the guest's kernel and
  composer take (75 Hz at 1080×2400 and 3840×2160: `supportedRefreshRates
  [75, 37.5, 25]`). The identity is that of the composer's fallback
  EDIDs (GGL, `EMU_display_<n>`, size 0), so display ids (`local:…`) and
  densities stay what they were in both modes.
  - **Android**: Cuttlefish's composer (ranchu, `display_finder_mode=drm`)
    hands SurfaceFlinger one mode per display, the connector's first (the
    preferred timing), and its vsync thread ticks at it. Like a new size, a
    new rate takes a re-plug. SurfaceFlinger can render at the rate or a
    divisor of it (`peak_refresh_rate`); `dumpsys display` then lists e.g.
    `supportedRefreshRates [120, 60, 40, 30, 24, 20]`.
  - **One rate**: Android paces displays of different rates unevenly (an app
    on a 120 Hz display next to the 60 Hz display 0 got 96 fps; on a 60 Hz
    display under a 120 Hz one its frames came in bunches), and unplugging
    display 0 restarts SurfaceFlinger. So the daemon picks one rate per boot
    (`FrameRates.androidRate`: the frame rate cap above 60, else 60; 60 by
    default), passes it as `--refresh-rate` and plugs every window's display
    at it. The caps are 30, 60, 90 and 120 whatever the Mac's screens show,
    and the own rate of each screen between 60 and 120 (a 75 or 100 Hz
    monitor), so Android can run in step with it. Under a cap that no screen
    shows evenly, the cap's controls say what the screens make of it
    (`FrameRates.screenNote`): a slower screen shows the newest frame at each
    of its refreshes (the window's display link draws it,
    `FrameRates.presentPacing`), a faster one out of step judders.
  - **The cap**: a lower one is a render rate for every display
    (`peak_refresh_rate`, which Android rounds down to a divisor), at once; a
    cap that needs another display rate waits for a restart (the Restart
    Android banner; Quick Settings says so). Above 60 Hz, HostAgent turns off
    Android's game default frame rate (`ro.surface_flinger.game_default_frame_rate_override`
    is 60 here; `debug.graphics.game_default_frame_rate.disabled`): it holds
    games that ask for no rate of their own at 60, and with mixed rates it
    stalled them to about a frame a second.
  - **Measured** (GPU unless noted; the test VM's own app as below, n = 16,
    categorized as a game; frames as the host receives them):

    | Display rate, size | Frames/s | Interval median / p99 | avo-vmm CPU |
    |---|---|---|---|
    | 120 Hz, 720×1280 | 120.0 | 8.35 / 10.4 ms | about 85% |
    | 120 Hz, 720×1280, n = 128 | 120.1 | 8.34 / 9.5 ms | about 95% |
    | 120 Hz, 1080×2400 | 120.1 | 8.32 / 9.6 ms | about 85% |
    | 120 Hz, cap 60 / cap 30 | 60.2 / 30.2 | 16.5 / 33.6 ms | |
    | 90 Hz, 1080×2400 | 90.0 | 11.13 / 13.3 ms | |
    | 60 Hz (default), 1080×2400 | 60.2 | 16.50 / 22.0 ms | |
    | Software, 120 Hz, 720×1280, n = 0 | 119.8 | 8.33 / 9.5 ms | |

    Read back from gfxstream, a 1080×2400 frame takes 0.65 ms on average.
    The composer flushes display 0 with every frame too, so the engine
    reads back 240 frames a second at 120 Hz.

    On a Mac with a fixed 75 Hz monitor (1080×2400, n = 16 and n = 0, two
    to three runs each; the user's own Android busy alongside at 65–80%):

    | Display rate | Frames/s | Interval median / p99 | avo-vmm CPU |
    |---|---|---|---|
    | 60 Hz | 60.1 | 16.8 / 23–27 ms | 75–86% |
    | 75 Hz (the monitor's own) | 75.1 | 13.4 / 19–22 ms | 77–85% |
    | 120 Hz | 120.0 | 8.3 / 14–17 ms | 91–107% |

    At 75 Hz SurfaceFlinger presented 75.1 fps on a 13.33 ms vsync (the
    app counted 75.0), and Settings scrolled at 75 (13.7 ms median while
    moving). 120 Hz under the 75 Hz screen costs avo-vmm 15–20 points of a
    core more than 75 (about a fifth), and the daemon copies all 120 frames
    into the window's surfaces; the window draws the newest 75.
- **Measured** (M4 Pro; test VM with 4 vCPUs and 4 GiB; a GLES app drawing a
  full-screen fractal shader with *n* iterations per pixel, vsync-paced;
  fps, then avo-vmm host CPU with 100% = one core):

  | Load | Software | GPU |
  |---|---|---|
  | n = 16, 720×1280 | 59.8 fps, 219% | 58.5 fps, 75% |
  | n = 48, 720×1280 | 46.5 fps, 396% | 58.5 fps, 75% |
  | n = 128, 720×1280 | 18.6 fps, 396% | 59.6 fps, 60% |
  | n = 128, 1080×1920 (second display) | 8.3 fps, 396% | 59.7 fps, 196% |
  | Settings scrolling | 54.9 fps, 136% | 55.7 fps, 78% |

  Sixteen such n = 128 passes a frame still run at about 40 fps on the GPU.
  Boot to `sys.boot_completed` takes 6.5 s (software 5.7–6.3 s); starting
  the renderer adds about 0.3 s.

The control socket (`control.sock`, one text command per line):

| Command | |
|---|---|
| `display <i> <w> <h> [<hz>]` / `display <i> off` | plug (at *hz*, 60 unless given), resize or unplug scanout *i* |
| `touch <i> [id:x:y …]` / `key <code> <0\|1>` | input |
| `gamepad <buttons> <lx> <ly> <rx> <ry> <lt> <rt> <hatx> <haty>` | the gamepad's whole state in evdev units; only changes reach the guest |
| `location <lat> <lng> [alt] [accuracy] [speed] [bearing]` / `location off` | the GPS fix Android's GNSS HAL reads from /dev/gnss1 (about once a second, timestamped when read, and carried on along its bearing at its speed for up to a second since it was set); a playing route sends it four times a second (architecture.md, "Android's location") |
| `network <down kbps> <up kbps> <latency ms>` / `network off` | limits Android's network link to a mobile network type's speed and delay (Settings › Devices › Network speed; 0 is no limit, the latency is the round trip's); each direction queues at most 1 MiB, beyond which frames drop (link.rs). The daemon sends it after every start and when the setting changes |
| `cellular <gprs\|edge\|umts\|hspa\|lte\|nr> <bars 0-4>` / `cellular off` | the modem's test SIM, registered at home on that network type with that signal, or no SIM (the default; `--cellular TYPE:BARS` sets it from the start). Live: Android hears of another type or signal at once, and of a SIM going in or out once it has turned the radio back on (modem.rs) |
| `shake` | shakes the phone: Android's accelerometer swings ±15 m/s² sideways five times a second for one second, as a hand shaking it would, then reads still again (sensors.rs); an error until Android has turned its sensors on |
| `microphone on\|off` | whether Android may use the Mac's microphone (Settings › Devices › Microphone); off, it records silence and the microphone is never opened (virtio/sound.rs) |
| `camera feed` | turns the connection into the cameras' frames: each a 16-byte header (camera, width, height, length; u32 little endian) and that many bytes of JPEG (camera.rs) |
| `snapshot <i> <path>` | next frame as a BMP |
| `pause` / `resume` | stop the vCPUs / let them run again (both idempotent); `pause` answers once no vCPU runs guest code, or with an error when one does not stop within 5 s (the others go on) |
| `subscribe` | events: `frames …` (new layout), `frame <i> <seq>`, `frames-off <i>`, `microphone` (Android started recording), `sound playback on\|off` and `sound capture on\|off` (sticky: Android's sound streams), `paused` and `resumed <ms>` (how long the guest stood still), `audio playback <epoch> <path>` (sticky: the ring of what Android played), `camera <i> on <w> <h> <fps>` and `camera <i> off` (sticky: Android streams camera *i*, 0 back and 1 front, with `--cameras`); with the GPU also `gpu active <device>`, `gpu context` (Android's first rendering context this boot), `gpu first-frame <i>` and `gpu stalled <ms>` |

**Pause** (`pause.rs`). The vCPUs stop at a gate before their next
`hv_vcpu_run` (a kick takes them out of the guest; one in WFI comes back
within a millisecond) and wait there; CPU_OFF vCPUs count as stopped, and a
pause asked for between two machines (a guest reboot) holds the next one's
vCPUs before they run. Devices keep their state: what arrives meanwhile (a
packet, a host vsock connection, an input event) waits in its queue and
raises its interrupt when the vCPUs run again. The guest's counter stands
still with them, as with QEMU's `kvm-adjvtime`: before a vCPU runs again its
vtimer offset grows by the time from the last vCPU stopping to the resume
(on its own thread, `hv_vcpu_set_vtimer_offset`), so CNTVCT goes on where the
guest last saw it, the same on every vCPU and never backwards. A counter that
jumped would make the kernel report soft lockups and RCU stalls and fire
Android's watchdog and ANR timers. Android's wall clock is therefore behind by
the pause afterwards: the daemon sets it (`HostAgent.clockResumed`: the Mac's
time with network time on, else the guest's time plus the pause, through
`cmd alarm set-time`, then `cmd network_time_update_service force_refresh`).
While paused, the sensors stop streaming (the console would queue every
reading), the sound clock stands still and the Mac's AudioQueues pause; the
GPU renderer and the network keep their own bounded timers. Measured on the
test VM: about 8% of one core idle and running, 0% paused (0.2% in GPU mode),
a pause takes well under a second, adbd answers a command sent during the
pause right after `resume`, and frames come again at once. When the daemon
goes away during a pause, the engine resumes before it powers Android off.

A pause is also how a checkpoint holds Android still (architecture.md,
"Checkpoints"): virtio-blk handles each request on the vCPU that notified it
(`Block::notify`), so once every vCPU waits at the gate no disk write is half
done, and the daemon clones Android's disks before it resumes.

**Quick boot** (not there). Starting from a snapshot of a running Android
needs everything the guest can see saved and put back: guest RAM (anonymous
memory today, `hvf/src/memory.rs`), every vCPU's registers and system registers
(`hv_vcpu_get_reg`/`get_sys_reg`), the vtimer offsets, the in-kernel GIC
(`hv_gic_state_*`, not bound yet in `hvf-sys`), and each device's state:
virtio-pci transports and queues, block, the 20 consoles, rng, vsock
(connections to Mac sockets that would not exist after a restore), the three
NICs with the NAT's TCP and UDP flows, sound, input, the gamepad, virtio-fs
(open guest file handles), media (cameras), the modem, Bluetooth, the
sensors and GNSS. None of them serializes its state yet. The blocker is the
GPU: gfxstream holds the guest's GL and Vulkan objects on the Mac's GPU, and
the Android Emulator's `libgfxstream_backend.dylib` (37.1) has
`stream_renderer_snapshot` and `stream_renderer_restore` only as stubs that
log "Snapshot save requested without support." and return -EINVAL, so a
GPU-mode Android cannot be snapshotted with the renderer Avo uses. A
software-rendered Android could be, once every device above saves its state.
The control socket's `snapshot` command still writes a frame (above), and
`VMMEngine.snapshot(to:)` refuses.

`--properties FILE` replaces image properties before anything reads them
(the device profile, by default Avo's honest identity, plus Avo's
`ro.boot.avo.*` markers, which `VMMEngine` writes for every launch; see
[for-game-developers.md](for-game-developers.md)): a small cpio placed
*before* the LZ4 ramdisks holds `/force_debuggable` and `/adb_debug.prop`,
which init loads on unlocked devices. Android derives `ro.build.fingerprint`
from the profile's brand, name and device when the profile does not set one
(`Avo/avo_droid/avo_droid:17/<build id>/<incremental>:userdebug/test-keys`). When the daemon that started it goes away, the
engine powers Android off through its shell console instead of running on.

This file loads at first-stage init, so it may carry only properties Cuttlefish
tolerates that early: the identity (`ro.product.*`, `ro.build.fingerprint`) and,
when "Emulate this phone's hardware" is on, the profile's SoC naming
(`ro.soc.*`, `ro.board.platform`, `ro.product.board`, vendor keys,
`ro.hardware.chipname`) and the GPU layers' values (`debug.avo.gl.*`,
`debug.avo.vk.*`). Loading the layers is applied later, by `HostAgent` after
Android is up, because doing it at first boot would break it: naming a Vulkan
layer system-wide before its file exists stops the graphics services. On a
boot the Vulkan driver wrapper runs, the Vulkan layer rides inside it (see
the wrapper above): the daemon installs only `libGLES_avo_profile.so` into
`/data/local/debug/gles`, leaves `debug.vulkan.layers` unset, and takes the
Vulkan layer file out of `/data/local/debug` — unnamed, libvulkan would
still open it in every app. Any other boot (software rendering, another
vendor build, a wrapper that failed a GPU start) installs
`libVkLayer_avo_profile.so` into `/data/local/debug/vulkan` as well, a path
Android honours only on a debuggable build, and sets `debug.gles.layers`
and `debug.vulkan.layers` only on a boot that began with the files in
place: a process that started before the install would fail to create a
Vulkan instance (`GuestGPUProfile`). A boot that emulates no GPU removes
the files, since libvulkan opens the Vulkan one in every app even unnamed
(see the gfxstream sync layer above for the apps that refuse it), and
turning emulation on, or picking a profile with a GPU, installs them before
the restart that setting needs. The GLES
layer answers an app's own `glGetString` with the profile's vendor, renderer
and driver version instead of ANGLE's; the Vulkan layer reports the profile's
GPU to an app's own Vulkan. Both leave SurfaceFlinger, HWUI, WebView and
ANGLE's shared Vulkan instance untouched, so the on-screen picture is
unchanged. Android hands a GLES layer only libEGL's own entries, and
`libGLESv1_CM`'s `glGetString` (which Java's `GLES20` binds to) reads the
driver straight from libEGL's dispatch tables, so the GLES layer swaps
`glGetString` in those two tables on the app's first `eglMakeCurrent`
(`guest/gpuprofile/src/gles_layer.c`).

The profile's CPU (`hardware.cpu`: each cluster's MIDR and frequencies) is
the engine's (`--cpu-clusters`, `vmm/src/cpu.rs`). Each vCPU's `MIDR_EL1` is
its cluster's, so `/proc/cpuinfo` and `/sys/devices/system/cpu/*/regs` name
the phone's cores, and the guest gets `virtual-cpufreq` (the image's
`virtual-cpufreq.ko`, a page of registers per vCPU at 0x0904_0000): every
cluster is one cpufreq policy with the phone's range, as on the phone
(the OnePlus 13: policy0 is cpu0–5 at 384 MHz–3.53 GHz, policy6 cpu6–7 at
1.02–4.32 GHz). The frequencies are names only: the guest's requests are
ignored and the current frequency reads as the top, so the scheduler's
frequency invariance sees every vCPU at full speed, and without
`capacity-dmips-mhz` it keeps treating the vCPUs as the equals they are.
The daemon fits the phone to Android's cores
(`DeviceHardware.CPU.fitted(to:)`): fewer vCPUs keep the phone's fastest
clusters, more grow its slowest, and Android numbers them from the slowest,
as phones do.

The phone's hardware name (`hardware.soc.hardware`, else `qcom` for a
Snapdragon and the platform otherwise) is the engine's too (`--hardware`):
avo-vmm puts it in the bootconfig as `androidboot.hardware`, which init keeps
as `ro.boot.hardware` and `ro.hardware` (`Build.HARDWARE`). Nothing of
Cuttlefish's goes by that name: its vendor script is loaded from
`/vendor/etc/init` whatever it is called, its drivers are named by their own
keys (`androidboot.hardware.egl`, `.gralloc`, `.vulkan`, `.hwcomposer`) and
the image has no HAL module named after the hardware; init only notes that
`/init.qcom.rc` and `/vendor/etc/init/hw/init.qcom.rc` do not exist, as it
did for `cutf_cvm`. A boot with `qcom` starts the same services as one
without. The phone's memory (`hardware.memoryGB`) is `--mem`
(`VMConfig.androidMemoryMiB`).

A faked MIDR also selects the guest kernel's errata workarounds, which are
pure cost on a Mac core. Most are for KVM, AArch32 or tracing, or cheap (the
TLB invalidation on every return to user space for the Cortex-A510 and A520).
Two would slow every app and are kept out: a Cortex-A73 (erratum 858921:
the counter is trapped and `clock_gettime` leaves the vDSO) is never
presented, and an early Cortex-A53 (errata 826319 and others: apps' cache
maintenance is trapped) is presented as r0p4. Qualcomm's A73- and A53-based
Kryo cores report their own parts (0x51/0x800, 0x801), as their phones do.

**The host agent.** Cuttlefish has no Bridge Agent, so `HostAgent` in the
daemon plays it over ADB (vsock 6520, root through `su` on userdebug):

- a window is a scanout plugged at the window's size and Android's display
  rate this boot (above); a task already on
  Android's own screen moves there (`am display move-stack`), else the app
  starts there like a launcher would;
- resizing gives the plugged scanout its new size when Avo's composer runs
  (`GuestComposer`: a patched copy of the image's RanchuHwc that reports a
  connected display's new mode, so SurfaceFlinger reconnects it and the
  Android display keeps its id; installed on the `remount` overlays and
  bind-mounted by an init file from the next boot). Otherwise it re-plugs
  the display at the new size (the image's composer ignores mode changes
  of a connected display; Android 17 moves the tasks back, under a new
  display id, which breaks apps that keep per-display objects: Flutter's
  text fields stop taking keys). A scanout is plugged again, by a re-plug or a new window, only once
  SurfaceFlinger and DisplayManager have dropped its old display, not when
  its EDID went: SurfaceFlinger crashed on a plug in between
  (architecture.md, "Resolution and scaling");
- touches go to the scanout's touchscreen, tied to its display by an IDC file
  (`touch.displayId`); keys go to the engine's keyboard, or through
  `input -d` when another display has Android's focus;
- Android focuses one display at a time, so the window that becomes the
  Mac's key window takes it (`FocusDisplay`), as a tap there would: games
  pause their sound while their window is not focused. The Mac state helper
  (guest/macstate, `focus-display`, run as the shell user) focuses the
  display's top visible task (`IActivityTaskManager.setFocusedRootTask`);
- the key window's game controller goes to the engine's gamepad, unless its
  key mapping uses the gamepad in Game Mode; the gamepad's virtio driver
  stays unbound (no gamepad in Android) while no controller drives it;
- `am stack list` closes windows whose app ended (TaskClosed) and opens
  windows for apps started by adb or other apps on Android's own screen
  (TaskStarted);
- clipboard both ways through `avo-clipboard.jar` (guest/clipboard, run with
  `app_process` as the shell user), notifications from `cmd notification`
  with their buttons from the same helper (`actions`, for those whose record
  says `actions=N`; `act` presses one, filling a Reply's RemoteInput with the
  text typed on the Mac), what Android plays from its `media watch` (one
  long-running `exec:` stream: Now Playing lines out, play/pause/seek
  commands in, for the session it shows),
  the Mac's location (CoreLocation), or a place or route from an app
  window's Location panel, as GNSS fixes (`LocationCenter`);
- links apps open go to the Mac through Avo Links (guest/links, installed
  when Android's copy differs, made the browser once per data disk): it logs
  each link, the daemon follows its uid's lines (`logcat --uid`) and opens
  http, https, mailto and tel links, and geo links as Apple Maps links, with
  the Mac's default apps (`GuestLinkPolicy`; nothing else leaves Android);
- ADB support (Settings › System) splices 127.0.0.1:5555 to adbd, so adb and
  Android Studio see it as `emulator-5554` / `AVO_Droid`;
- once per data disk: Wi-Fi on and joined to VirtWifi, media volume at full
  (the Mac's volume sets how loud), Thread off (no radio to simulate it),
  Bluetooth off only without a controller (below); every boot: UWB off (otherwise Android files a full bug
  report for the missing radio), the audio HAL without the MMAP and offload
  streams it only simulates and with 20 ms mixer periods ("Sound" above),
  multi audio focus on (every app keeps audio focus when another asks for it,
  as every window plays at once on a Mac; `HostAgent.shareAudioFocus`, kept
  by Android across boots), and a bug report the A+B key
  chord starts (init.cutf_cvm.rc) is stopped;
- once Google apps are installed (their overlay makes /product keep
  changes): Avo's system feature, `/product/etc/permissions/com.avodroid.feature.mac.xml`
  (`IdentityFeature`), written when it is missing or from another schema and
  read by Android from the next start. The stock image's /product is
  read-only under verified boot, so without Google apps only the
  `ro.boot.avo.*` properties identify Avo.

**Google apps** (Settings › Google Apps, "Bring your own GApps" in the spec). The
user's own MindTheGapps package (a .zip or unzipped folder, which the Control
Panel copies into `~/Library/Caches/Avo/gapps` since the daemon never reads
Downloads or Documents, or a GitHub release the daemon downloads there and
checks against the asset's SHA-256 `digest` or its `.sha256sum`) is installed
as privileged system apps by `GoogleAppsInstaller`, with `HostAgent` doing the
guest steps as root. The package's `build.prop` must match the guest
(`arch` = `ro.bionic.arch`, `version` = SDK); its recovery installer never
runs, but its rules apply (no VelvetTitan except on tangorpro, no Google
SetupWizard so AOSP's Provision stays, no addon.d). Then:
`avbctl disable-verity` and an engine restart when verity is on (the instance
keeps a writable vbmeta copy, whose flags the engine reads at start);
`remount`, with one more restart when it has just created the overlayfs
scratch partition; `/mnt/scratch` remounted `async` (it is mounted `sync`,
which turns a 700 MB copy into 20 minutes); the files pushed to
`/data/local/tmp/avo-gapps` and copied into `/product` and `/system_ext` as
root (root:root, 0755/0644, `restorecon`) by a script `GoogleAppsCommit`
writes; a last restart, after which `pm list packages` must list Play
services and the Play Store. Only then does Settings › Google services
switch to "Bring your own GApps".

The commit is safe to interrupt. It first lists every path it may add in
`/product/etc/avo-gapps.files` (relative paths, synced before anything
changes), then copies in the safest order: `etc` (privapp allowlists,
sysconfig; extra allowlist entries are harmless, while a privileged app
without one stops system_server under `ro.control_privapp_permissions=enforce`),
then libraries, frameworks and other files, then the app folders. Each file
and each new app folder is copied under `<partition>/.avo-new` and renamed
into place (a new, upper-only folder renames fine with
`redirect_dir=nofollow`); `#complete` ends the list. When the commit fails,
the boot after it never gets ready, or Android does not list Google Play,
the installer takes out every listed path again: through HostAgent when
Android runs, else over a fresh adbd connection (`VMManager.rescueShell`;
adbd is up while system_server loops, long before `sys.boot_completed`),
using the overlay's upper folders if the partitions stay read-only; then
Android restarts as it was and the pane says "Google apps were not
installed; Android was restored". Every guest step has a time limit
(`GoogleAppsInstaller.Limits`). While the install changes Android, Stop,
Restart, Reset and Save Snapshot are refused (`GoogleAppsGuard`; Reset
first stops an install that is still downloading); the menu bar's Stop and
Quit offer "Stop Anyway"/"Quit Anyway". A commit the daemon does not see
to its end (it quit, or Android was stopped anyway) is noted in
`vm/google-apps-commit.json`; the next start keeps it when it is complete
and Android lists Google Play, and takes it out otherwise.

The overlay's scratch partition is an image on the data disk
(`/data/gsi/remount`), so Reset Android takes Google apps away again
(verity stays off) and sets Google services back to None.

Settings › Google Apps › Remove takes them out without Reset Android and
keeps every other app and its data (`GoogleAppsInstaller.remove`). It notes
Android's system packages in `google-apps-commit.json` (`systemPackages`),
takes out every path on the manifest with the rollback script above,
restarts Android, which drops those system apps with their data, and then
uninstalls what Google Play's updates left of them: a system app Google
Play updated outlives its system files as an ordinary app that keeps the old
data and can't sign in. Those are the packages that were system apps before
and are ordinary ones now, plus Play services, the Play Store, GSF and the
Google app in any case (`GoogleApps.corePackages`). When the files are gone
already and only those updates are left (`GoogleAppsStatus.systemApps` is
false, and the pane says so), only the updates go, without a restart.
Afterwards Android must list no Google Play: Google apps Avo has no manifest
for stay, and Reset Android removes them. Then Google services goes back to
None, `google-apps.json` goes, and Google apps can be installed again (with
a new GSF Android ID to register). A forced stop mid-Remove is finished at
the next start; a finish that fails there lets Android start anyway, since
the rollback's order leaves it bootable, and Remove can be chosen again.
Google apps of another Android version are refused (`leftOver`): that
Android does not mount their overlay.

Android grants Play services location (it is the fused and network
location provider) only when it first sets up or after a system update, so
Google apps added later never get it, and no app that asks Play services
for a location gets one. Every boot, HostAgent grants Play services fine,
coarse and background location while it lacks them and the user has not
decided (`grantPlayServicesLocation`: no USER_SET or USER_FIXED flag).

Which package fits is the Android version's: MindTheGapps keeps one GitHub
repository per version and architecture (`MindTheGapps/17.0.0-arm64`, its
`version_nice` and `arch`), so `GoogleAppsLine` maps Android's major version
(or API level − 20) to it. Settings › Google Apps lists that line's releases
for the Android that runs, or the one that starts next while Android is
stopped (`GoogleAppsCatalog`: drafts, pre-releases and packages without a
SHA-256 left out, newest first); the newest is the one to install, older
ones and a package from a file are there too, and a link of one's own only
under Advanced. The last listing of each line is kept in
`~/Library/Caches/Avo/gapps-releases`: younger than 30 minutes it is used as
it is, older it is asked for again with its ETag (a 304 does not count
against GitHub's 60 requests an hour), and while GitHub can't be reached or
refuses (403/429 with no requests left, or `Retry-After`) the pane shows it
with the reason. A 404 means no package for that Android yet.

Google apps fit only the Android version they were installed on: another
version starts with verified boot on again, so their overlay stays unused.
Once Android lists Google Play after an install the daemon notes the
Android in `google-apps.json` beside the data disk (it travels with the
data; Reset Android removes it; an install from before the record is noted
when Android next lists them, or by the Control Panel when another version
is chosen). With that record (`GoogleAppsSituation`) the pane says they
stop working at the next restart, or that they are left over and Reset
Android comes first, and the daemon refuses an install over them; while
another version is chosen but not started yet, it asks for the restart
first, since the install's own restarts would switch versions halfway. Progress reaches
every Control Panel as `DaemonEvent.googleAppsProgress`; the pane also
shows the GSF Android ID (gservices provider, else Play services'
gservices.db, polled until Play services has checked in) to register at
google.com/android/uncertified, which AOSP test-keys builds need before
Google lets them sign in. A new data disk gets a new ID. The Play Store and
the Google app are system apps, so Apps offers no Uninstall for them.

**Bluetooth.** Cuttlefish's HCI HAL (`bt_hci`) speaks H4 on /dev/hvc5,
where Cuttlefish's host runs Root Canal, a virtual controller. Avo brings
its own: `scripts/build-bluetooth.sh` builds Root Canal from source
(github.com/google/rootcanal, which follows AOSP's, at a pinned commit; with
Bazel, Apple's C++ toolchain and unstripped Rust, for macOS 15 and later)
into `build/bluetooth`, and Avo.app carries it in
Contents/Resources/bluetooth (`AndroidEmulator.bluetoothController`; the
Android Emulator's netsimd, Root Canal inside, only for a build without
it). The daemon passes `--bluetooth <controller>` and avo-vmm starts it
(`--hci_port` on a free local port, its other ports on free ones too; for
netsimd its own flags; its files in `run/bluetooth`, its log in the
instance's `bluetooth.log`) and passes the bytes both ways between hvc5 and
the port (`bluetooth.rs`). Android's Bluetooth turns on and scans,
advertises and pairs inside the controller's virtual air. Without a
controller Android's Bluetooth has none, so the host agent turns it off
once per data disk as before.

The Mac's Bluetooth LE devices join that air (`MacBluetoothBridge`).
macOS gives no app the HCI of its controller, so they come through
CoreBluetooth: avo-vmm announces the port (`bluetooth hci <port>`, sticky)
and, while Android's Bluetooth is on (`settings get global bluetooth_on`,
every 3 s), the daemon scans and gives each device worth showing a chip of
its own on the port (`BLEProxyChip`, driven as its host by `HCIChip`; at
most 12, not Apple's Continuity chatter, gone 30 s after the Mac last heard
it). The chip advertises what the device advertises (rebuilt from
CoreBluetooth's dictionary, `BLEAdvertisement`) from a random static
address derived from the device's CoreBluetooth identifier. When Android
connects, the Mac connects to the device and the chip serves its GATT
database (`GATTServer`: GAP and GATT of its own, then the device's
services; reads, writes, long writes, notifications and indications go to
the device through `MacBluetoothLink`). Pairing is refused (SMP "pairing
not supported"; CoreBluetooth pairs with the device itself) and L2CAP
channels on a PSM are not offered. Classic Bluetooth (headsets, older
controllers) has no way through. macOS asks for Bluetooth access the first
time Android's Bluetooth is on (`NSBluetoothAlwaysUsageDescription`, in
Avo.app and the daemon). `ProxyChipInNetsim` tests the chip against a real
controller (`AVO_BLUETOOTH_CONTROLLER=build/bluetooth/rootcanal swift test`),
and avo-vmm's `controller_starts_resets_and_stops` its bridge.

**Cameras.** Settings › Devices › Cameras gives each of Android's cameras
a source (`backCamera`, `frontCamera`; `CameraSource`): Emulated, None or
one of this Mac's cameras. While both are Emulated, Android keeps the
image's emulated cameras, and avo-vmm runs as before. Any other choice
starts Android with `--cameras` (the cameras it has: `back,front`, `back`,
`front` or `none`), and the daemon feeds them (`CameraFeed`): when
Android streams one (`camera <i> on …`), its source starts, the Mac's
camera through AVFoundation (its picture cropped to fill Android's size;
its light is on only while Android uses it) or, for an emulated one, a
scene drawn on the Mac (sky, a moving sun, the camera's name and the
time), and its frames go to the engine as JPEG on a `camera feed`
connection. The engine hands each new frame of the stream's size to the
oldest queued buffer; while none comes it repeats the last one for 2 s,
then sends a plain gray JPEG of its own at the stream's rate, so the HAL
never waits on the Mac (it reads three frames before a stream counts as
started). macOS asks for camera access in Avo's name the first time
(`NSCameraUsageDescription` and `com.apple.security.device.camera` in the
daemon); until then, or when the chosen camera and every other is gone,
Android sees a picture that says why. Which cameras Android has applies at
its next start; another source for a camera it has applies at once.

The external camera HAL, as built, gives every camera the facing
"external" (apps that ask for the back or front camera find none) and,
without /vendor/etc/external_camera_config.xml, allows 720p at 7.5 frames
a second. Every boot with `--cameras` the host agent bind-mounts a copy of
camera.device-external-impl.so over the APEX's (`GuestCamera`, only the
known build, only when /dev/video1 and /dev/video2 are virtio-media):
its `ANDROID_LENS_FACING_EXTERNAL` becomes a call to code in the padding
after `.plt` that faces video1 back and video2 front, and it reads its
configuration from /data/local/tmp/avo-camera/config.xml (cameras 0 and 1
as on a phone, 30 frames a second at every size, v4l2loopback ignored);
then the HAL and cameraserver start again. With `remount` overlays, a
file on the vendor overlay declares the camera features the emulated
APEX would (`android.hardware.camera`, `.front`, `.any`, `.autofocus`),
from the next start on.

**Settings › Devices.** Wi-Fi (`wifiEnabled`: the host agent sets Android's switch at every start and on a change; off, Android is offline), Network speed (`networkSpeed`, the `network` command above) and the Mac's Bluetooth devices (`shareMacBluetooth`, MacBluetoothBridge) apply at once (`DeviceSettingsEngine`). Location moved here from Privacy & Security. Mobile data with a SIM, signal bars and the network type in Android's status bar go to the engine as the `cellular` command above (modem.rs).

Each of the Mac's devices Android may use has a switch there; off, Android has no such hardware and Avo never asks macOS for it. Bluetooth (`bluetoothEnabled`) and Cameras (`camerasEnabled`) are plugged in at the start: off, avo-vmm runs without a Bluetooth controller (the host agent turns Android's Bluetooth off at every start without one) or with `--cameras none`. The Microphone (`microphoneEnabled`, the `microphone` command above) and the Clipboard (`shareClipboard`: the daemon stops watching the Mac's pasteboard and passes nothing either way) follow at once; Location is the switch to share the Mac's location.

**Root.** With `rooted` on (Settings › System › Developer), avo-vmm boots
a Magisk-patched copy of the image's init_boot (`--init-boot`,
`vm/magisk/init_boot.img`, kept with the SHA-256 of the init_boot it came
from). `MagiskRoot` makes it once per image while Android runs: the daemon
downloads Magisk v30.7 from its GitHub release (checked against its
SHA-256; Magisk is GPL and never ships with Avo), pushes it and the
image's init_boot to `/data/local/tmp/avo-magisk`, runs Magisk's own
`boot_patch.sh` there as root (the userdebug `su`), reads `new-boot.img`
back and installs Magisk's app; then Android starts again with it
(DaemonCore's `rootIfAsked`, also at a start of an image not patched yet).
The generic ramdisk is last in the initrd, so Magisk's init is `/init`;
Avo's property overrides before it still apply. If the patch fails, root
turns off again and a Mac notification says why. Off, the image's own
init_boot boots at the next start; nothing in the image or the data disk
changes either way.

Not there yet: camera (Cuttlefish's vsock camera protocol), classic
Bluetooth, zero-copy GPU frames, microG.

## Legacy: the crosvm contract

Avo's original plan was a port of crosvm to macOS. avo-vmm replaced it, but
the daemon still carries the contract it was written against, as a fallback
when a bundle has no avo-vmm, and `EngineContractTests` keep it honest. The
daemon (`CrosvmEngine` in AvoDaemonCore) spawns
`Avo.app/Contents/MacOS/crosvm` and expects the following. The argument list is
built by `CrosvmEngine.arguments(for:)` and covered by `EngineContractTests`.

```
crosvm run --name avo
  --cpus num-cores=<cpuCount>
  --mem size=<memoryMiB>
  --balloon-page-reporting | --no-balloon          # Performa: return memory when idle
  --block path=<image>/system.img,ro=true,id=system
  --block path=<image>/vendor.img,ro=true,id=vendor
  --block path=<image>/overlay_{stock,rooted}.img,ro=true,id=avo_overlay   # root checkbox
  --block path=<data disk>,id=userdata
  --block path=<runtime>/avo_config.img,ro=true,id=avo_config              # BootConfig
  --gpu backend=gfxstream,gles=true,vulkan=<bool>,context-types=gfxstream-gles:gfxstream-vulkan:gfxstream-composer
  --vsock cid=3,uds-path=<runtime>/vsock.sock       # new: hybrid vsock (below)
  --virtio-snd backend=coreaudio,...                # new backend
  --socket <runtime>/crosvm.sock                    # control socket
  --serial type=file,path=<logs>/android-console.log,hardware=virtio-console,console=true
  --initrd <image>/initrd.img
  [--restore <snapshot>]                            # quick boot
  --params "androidboot.hardware=avo androidboot.avo.config=/dev/block/by-name/avo_config"
  <image>/kernel
```

**Readiness.** The engine is up when `vsock.sock` accepts connections; the
daemon then retries the Control port until the Bridge Agent answers.

**Hybrid vsock.** macOS has no `AF_VSOCK`, so the engine implements virtio-vsock
in user space and exposes guest ports through one Unix socket, with
Firecracker's convention: the host connects, writes `CONNECT <port>\n`, reads
`OK <host-port>\n`, and the stream is raw from there (`VsockBridge` in AvoIO).
The runtime directory is mode 0700; only the daemon connects (spec: no TCP
ports, ADB never on the network).

**Control socket.** `crosvm powerbtn` (clean Android shutdown),
`crosvm stop`, `crosvm snapshot take --compress <path>`; `--restore` for quick
boot. Balloon statistics drive "return memory when idle".

**Frames.** The guest's Bridge Agent creates one gfxstream display per host
display id (`rcCreateDisplayById`), sizes it (`rcSetDisplayPose`) and posts
each VirtualDisplay buffer with `rcSetDisplayColorBuffer`. On the host, the
engine keeps a swapchain of three BGRA `IOSurface`s per display, copies (GPU
blit) the posted color buffer into the next one, and tells the daemon over XPC
(role `engine` on the `com.avodroid.daemon` Mach service):

- `engineSetSurfaces(displayID, [IOSurface])` when a display is created or resized;
- `enginePresent(displayID, surfaceIndex, sequence)` for every frame.

The daemon forwards both to the App Shim that owns the display, which draws the
IOSurface with Metal. Frames are never encoded.

**Entitlements.** `com.apple.security.hypervisor`, hardened runtime,
Developer ID signature, notarized with the app.

## History

The specification ([spec.md](spec.md)) chose crosvm with a new
Hypervisor.framework backend. The first milestones were built that way: the
HVF crate in [`engine/hvf`](../engine/hvf/README.md) (VM, memory, vCPUs,
in-kernel GICv3, PSCI) and a kernel boot to first-stage `init`. Instead of
porting crosvm's device model and main loop, Avo grew those crates into
avo-vmm, which implements the virtio devices Cuttlefish needs directly and
boots the stock AOSP image. The HVF crate is unchanged in spirit and is still
what avo-vmm runs on.
