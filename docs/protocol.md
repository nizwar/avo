# Host ↔ guest protocol

All traffic between macOS and Android goes over virtio-vsock. Nothing listens
on a TCP port on the Mac. The Bridge Agent listens inside the guest; the
Runtime Daemon (`avod`) is the only host process that connects.

| Channel | vsock port | Encoding | Owner in guest |
| --- | --- | --- | --- |
| ADB | 5555 | ADB wire protocol (adbd `service.adb.listen_addrs=vsock:5555`) | adbd |
| Control | 6000 | Length-delimited protobuf `avo.v1.Envelope` ([control.proto](../proto/avo/v1/control.proto)) | Bridge Agent |
| Input | 6001 | Fixed-layout little-endian binary records (below) | Bridge Agent |
| Graphics | virtio-gpu | gfxstream (host renderer from the Android Emulator, through MoltenVK) | gfxstream guest drivers |

On macOS there is no `AF_VSOCK`. The engine exposes the guest's vsock ports to
the daemon through a Unix domain socket using the same convention as
Firecracker's hybrid vsock: the daemon connects to `<runtime>/vsock.sock`,
writes `CONNECT <port>\n`, reads `OK <assigned-host-port>\n`, and the stream is
then raw. The runtime directory is created with mode `0700`, so only processes
of the same user can reach it, and only `avod` ever does. See
[engine.md](engine.md).

## Control channel (port 6000)

### Framing

Each frame is a varint byte length followed by a serialized `Envelope`
(protobuf delimited encoding). Frames larger than 8 MiB are a protocol error.

### Session start

```
host                                   guest (Bridge Agent)
 |-- Envelope{v=1, Hello{v=1,min=1}} -->|
 |<-- Envelope{v=1, Hello{v=1,min=1,    |
 |      android_sdk, device_profile_id, |
 |      rooted}} -----------------------|
 |-- Envelope{ListApps{icons=?}} ------>|   (request_id = n)
 |<-- Envelope{AppList{...}} -----------|   (request_id = n)
```

The negotiated version is `min(host.v, guest.v)`. If it is lower than either
side's `min_protocol_version`, that side sends `Goodbye{INCOMPATIBLE_VERSION}`
and closes the connection. The Control Panel then asks the user to update
whichever side is older.

`Ping`/`Pong` run every 5 s while idle; three missed pongs mark the guest as
unresponsive.

### Requests and replies

`request_id` is non-zero for requests. The guest answers with either a typed
response (`AppList`, `PermissionList`) or a `Reply` carrying the same id.
Events (`AppInstalled`, `Notification`, `NowPlaying`, …) always have `request_id = 0`.

| Request (host → guest) | Response |
| --- | --- |
| `ListApps` | `AppList` |
| `GetPermissions` | `PermissionList` |
| `Launch` | `Reply`, then `DisplayReady` once the first frame is posted |
| `Resize`, `Close`, `SetDisplayVisibility`, `SetRefreshRate`, `FocusDisplay` | `Reply` |
| `Install`, `Uninstall`, `ForceStop`, `DeleteAppData`, `SetPermission` | `Reply` |
| `ShareFiles`, `OpenNotification`, `DismissNotification`, `SetClipboard` | `Reply` |
| `PerformNotificationAction`, `MediaCommand` | `Reply` |

### Opening an app (one window per app)

1. The user opens `~/Applications/Android Apps/Foo.app` (Dock, Launchpad,
   Spotlight). The shim process loads `AvoWindowHost.framework` from
   `Avo.app` and connects to `avod` over XPC.
2. The shim asks the daemon for a display for `com.foo`. `avod` boots the VM
   if needed, allocates a display id, sizes it from the window's content size
   × backing scale, and sends `Launch{package, display_id, width, height, dpi}`.
3. The Bridge Agent creates a `VirtualDisplay` for that id, starts the launcher
   activity with `ActivityOptions.setLaunchDisplayId`, and posts each frame of
   the display's surface to the host through gfxstream. When the first frame
   lands it sends `DisplayReady`.
4. Window resizes send `Resize` (debounced to the end of a live resize).
   Minimising sends `SetDisplayVisibility{visible=false}`. The window becoming
   the Mac's key window sends `FocusDisplay`, so its app has Android's input
   focus (the GPU engine; the Bridge Agent's displays each have their own
   focus, and it answers `STATUS_UNSUPPORTED`).
5. When the task finishes inside Android, the agent sends `TaskClosed` and the
   window closes. Closing the window sends `Close`.

### Installing a package

Single APKs and split sets are both installed over ADB with the session
commands, so the guest's `PackageManager` does all verification:

```
pm install-create -S <total-bytes>          -> "Success: created install session [ID]"
pm install-write -S <bytes> <ID> <name> -   (one per split, streamed over stdin)
pm install-commit <ID>                      -> "Success"
```

XAPK OBB files are pushed with ADB `sync` to
`/sdcard/Android/obb/<package>/`. The resulting `AppInstalled` event (sent by
the agent on `PACKAGE_ADDED`) is what creates the App Shim, so apps installed
from inside Android (F-Droid, Aurora Store) get shims the same way.

## Input channel (port 6001)

Input is separated from Control so that a large `AppList` or icon transfer can
never delay a touch. Records have a fixed layout so the guest decodes them
into a reused `ByteBuffer` without allocating.

### Preamble

Both sides first send 8 bytes: ASCII `AVOI`, `u16` version (currently `1`),
`u16` reserved (`0`). The lower of the two versions is used.

### Record header (8 bytes)

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | `type` |
| 1 | 1 | `flags` (reserved, 0) |
| 2 | 2 | `length` — total record length including this header |
| 4 | 4 | `display_id` — target display (0 = focused display) |

All integers are little-endian; floats are IEEE-754 `f32`. Coordinates are in
display pixels with the origin at the top-left corner. Unknown types are
skipped using `length`. The maximum record length is 1024 bytes.

### Record types

**`0x01` TOUCH** — a complete `MotionEvent` with every active pointer. The host
keeps pointer state (keymap engine, trackpad gestures), so the guest only
translates.

| Offset | Size | Field |
| --- | --- | --- |
| 8 | 1 | `action`: 0 DOWN, 1 UP, 2 MOVE, 3 CANCEL, 5 POINTER_DOWN, 6 POINTER_UP |
| 9 | 1 | `action_index` — pointer index for POINTER_DOWN/UP |
| 10 | 1 | `pointer_count` (1…16) |
| 11 | 1 | reserved |
| 12 | 4 | reserved |
| 16 | 16 × n | pointers: `u32 id`, `f32 x`, `f32 y`, `f32 pressure` |

**`0x02` KEY** — Android `KeyEvent`.

| Offset | Size | Field |
| --- | --- | --- |
| 8 | 1 | `action`: 0 DOWN, 1 UP |
| 9 | 3 | reserved |
| 12 | 4 | `keycode` (Android `KEYCODE_*`) |
| 16 | 4 | `meta_state` (Android `META_*` bits) |
| 20 | 4 | `repeat` |
| 24 | 4 | `scancode` (0 when unknown) |

**`0x03` SCROLL** — mouse wheel / two-finger scroll at a position.

| Offset | Size | Field |
| --- | --- | --- |
| 8 | 4 | `x` |
| 12 | 4 | `y` |
| 16 | 4 | `h_scroll` (`AXIS_HSCROLL`, 1.0 = one notch) |
| 20 | 4 | `v_scroll` (`AXIS_VSCROLL`, positive = up) |
| 24 | 4 | `buttons` |

**`0x04` TEXT** — committed text (dead keys, emoji picker, paste-as-typing).

| Offset | Size | Field |
| --- | --- | --- |
| 8 | 2 | `byte_length` |
| 10 | n | UTF-8 text |

**`0x05` MOUSE** — pointer events with `SOURCE_MOUSE` for apps that handle a
real mouse (hover, right click). By default the host sends mouse clicks as
touches; this type is used when an app's keymap profile opts in.

| Offset | Size | Field |
| --- | --- | --- |
| 8 | 1 | `action`: `MotionEvent` action (7 HOVER_MOVE, 11 BUTTON_PRESS, …) |
| 9 | 3 | reserved |
| 12 | 4 | `x` |
| 16 | 4 | `y` |
| 20 | 4 | `buttons` (`BUTTON_PRIMARY` = 1, `SECONDARY` = 2, `TERTIARY` = 4, …) |
| 24 | 4 | `action_button` |

**`0x06` GAMEPAD** — full controller state for games with native controller
support (forwarded to a virtual gamepad in the guest).

| Offset | Size | Field |
| --- | --- | --- |
| 8 | 1 | `pad` index (0…3) |
| 9 | 1 | `connected` (0/1) |
| 10 | 2 | reserved |
| 12 | 4 | `buttons` bitmask (see `GamepadButton` in AvoKit; bit 16 is Home) |
| 16 | 32 | `f32` axes: LX, LY, RX, RY, LT, RT, HAT_X, HAT_Y |

Axes use GameController's conventions: sticks and hat -1…1 with y up,
triggers 0…1. `connected` 0 unplugs the guest's gamepad: App Shims send it
when no controller is there or the window's key mapping uses the gamepad.
`display_id` is the display of the key window that drives the gamepad; the
host only forwards it for a display the sender owns, and the guest unplugs
the gamepad when that display closes.

**`0x7F` PING** — `u64` token at offset 8. The guest echoes the record back on
the same stream; the host uses it to measure input round-trip latency.
