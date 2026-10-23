# Zero-copy frames: what it would take

Today every frame of every display makes its way from the Mac's GPU to the
window like this:

1. **Readback** — gfxstream copies the scanout's color buffer from Metal
   into CPU memory (`read_back` in `engine/hvf/vmm/src/virtio/gpu/render.rs`,
   `transfer_read_iov`; the engine log's `readback avg/max` is this copy,
   1.7–1.9 ms at 1080×2400). The destination is the shared-memory ring
   buffer, packed (`stride = width × 4`, `frames.rs`).
2. **Daemon copy** — `FrameBridge.swift` copies the newest buffer into one
   of three IOSurfaces, row by row under a lock ("over 1 GB/s" at
   1080×2400 and 120 Hz, its own comment says).
3. **Shim draw** — the window's `MetalRenderer` wraps the IOSurface in an
   `MTLTexture` and the GPU samples it into the drawable. No CPU copy.
4. WindowServer composes the window onto the screen, as it does for any app.

Why step 2 exists at all: the readback can only write **linear, packed**
memory (`transfer_read_iov` takes one iovec), while an IOSurface that Metal
can wrap as a texture needs a **64-byte-aligned row stride**. Something has
to turn the one into the other, and today that is the daemon's CPU copy.

## What cannot save it

- **Engine-written IOSurfaces, shared over XPC.** The engine could write the
  readback into an IOSurface directly (packed — IOSurface itself allows any
  row bytes) and hand the surfaces to the daemon once per layout. But an
  unaligned IOSurface cannot become an `MTLTexture` (Metal requires the
  alignment), so the shim could not display it without a copy of its own —
  the same copy, moved. Global `IOSurfaceLookup` across processes is
  disabled on current macOS (verified: a global-ID lookup from a second
  process returns NULL), so sharing would have to go through XPC mach
  ports — a C shim beside the daemon's `NSXPCListener`, a LaunchAgent
  plist change — all for zero net win. Not worth it.
- **Per-row readbacks into an aligned surface.** `transfer_read_iov` takes a
  stride parameter, so one call per row could write strided memory — 2400
  renderer-library calls per frame per display, each a round trip. No.

## The way through: render into the surface (a gfxstream patch)

The renderer Avo builds (`scripts/build-gfxstream.sh`, pinned snapshot
`ec3143b4ac34`, patches in `scripts/gfxstream-patches/`) already contains
most of the machinery:

- `VirtioGpuResource::ExportBlob` has a color-buffer branch that calls
  `FrameBuffer::exportColorBuffer` — but on macOS it dead-ends: the export
  mode is `VK_EXT_external_memory_metal`, which yields an `id<MTLHeap>`
  handle the C ABI (`stream_renderer_handle`) has no type for, and MoltenVK
  gives no IOSurface for it.
- The import side the patch needs **is already implemented** in the pinned
  code: `VkImportMemoryMetalHandleInfoEXT` (import an `id<MTLTexture>` as
  VkImage memory, `vk_common_operations.cpp`).

The patch, then:

1. Add a `STREAM_HANDLE_TYPE_MEM_IOSURFACE` handle type to the renderer's
   C ABI, carried as a mach port (`IOSurfaceCreateMachPort`).
2. For a scanout's color buffer, create an IOSurface host-side (aligned
   stride), import it as a Metal texture, and build the VkImage on that
   memory — the guest renders straight into the surface.
3. Export it over the new handle type; avo-vmm turns the mach port back
   into an `IOSurfaceRef`, passes it to the daemon once per layout (XPC),
   and the daemon to the shim, which it already knows how to receive
   (`engineSetSurfaces`). The readback and the daemon copy both go; the
   first copy in the frame's life is WindowServer's.

The frames ring, its tearing checks and the `frame <scanout> <sequence>`
events stay as they are — only the memory they describe changes. The
LaunchAgent plist needs the daemon's second (C) listener service for the
mach-port handover; the engine falls back to today's shared-memory path
when the listener is not there, so old daemons and new engines mix.

Effort: the gfxstream patch is the bulk (a few hundred lines of C++ in
code Avo already patches and rebuilds); the engine and daemon sides are
small. Until then, the daemon's copy is the tax, and it is already skipped
for windows nobody sees.
