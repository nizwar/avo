//! The FUSE server behind virtio-fs (fs.rs): a folder on the Mac, passed
//! through to the guest (Linux's FUSE protocol 7.31, little endian).
//!
//! - **Nodes** are the host's files by inode number (APFS is usually case
//!   insensitive, so "a.txt" and "A.TXT" are one node), each with the path it
//!   was last looked up by, relative to the folder. Paths, not descriptors:
//!   a removable volume can still be ejected while nothing is open.
//! - **Inside the folder only.** Names with a slash, "." or ".." are refused,
//!   every directory a request names is checked to be one (never a symlink),
//!   and files open with O_NOFOLLOW. Symlinks are shown as symlinks: the guest
//!   resolves them in its own tree, never on the Mac.
//! - **Ownership** is Android's media storage's: every file is media_rw's
//!   (1023), rw for it and its group, so MediaProvider (in that group) and
//!   root reach everything. What Android creates belongs to the Mac user,
//!   0644 and 0755; chmod and chown from Android change nothing.
//! - **Caching**: names and attributes are good for one second (the Mac can
//!   change them underneath), and the page cache is dropped on every open
//!   and whenever the size or modification time changes (AUTO_INVAL_DATA).
//! - macOS's own bookkeeping (.DS_Store, AppleDouble "._" files, .Trashes,
//!   …) is left out of listings.

use std::collections::HashMap;
use std::ffi::{CString, OsStr};
use std::fs::{File, Metadata, OpenOptions};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirEntryExt, FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

// Opcodes (include/uapi/linux/fuse.h).
pub const LOOKUP: u32 = 1;
pub const FORGET: u32 = 2;
pub const GETATTR: u32 = 3;
pub const SETATTR: u32 = 4;
pub const READLINK: u32 = 5;
pub const SYMLINK: u32 = 6;
pub const MKNOD: u32 = 8;
pub const MKDIR: u32 = 9;
pub const UNLINK: u32 = 10;
pub const RMDIR: u32 = 11;
pub const RENAME: u32 = 12;
pub const LINK: u32 = 13;
pub const OPEN: u32 = 14;
pub const READ: u32 = 15;
pub const WRITE: u32 = 16;
pub const STATFS: u32 = 17;
pub const RELEASE: u32 = 18;
pub const FSYNC: u32 = 20;
pub const FLUSH: u32 = 25;
pub const INIT: u32 = 26;
pub const OPENDIR: u32 = 27;
pub const READDIR: u32 = 28;
pub const RELEASEDIR: u32 = 29;
pub const FSYNCDIR: u32 = 30;
pub const CREATE: u32 = 35;
pub const INTERRUPT: u32 = 36;
pub const DESTROY: u32 = 38;
pub const BATCH_FORGET: u32 = 42;
pub const RENAME2: u32 = 45;
pub const SYNCFS: u32 = 50;

pub const ROOT: u64 = 1;
const VERSION: (u32, u32) = (7, 31);

// INIT flags we take when the kernel offers them.
const ASYNC_READ: u32 = 1 << 0;
const BIG_WRITES: u32 = 1 << 5;
const AUTO_INVAL_DATA: u32 = 1 << 12;
const PARALLEL_DIROPS: u32 = 1 << 18;
const MAX_PAGES: u32 = 1 << 22;
const WANTED: u32 = ASYNC_READ | BIG_WRITES | AUTO_INVAL_DATA | PARALLEL_DIROPS | MAX_PAGES;

/// The most one READ or WRITE moves (256 pages).
pub const MAX_TRANSFER: u32 = 1 << 20;

// SETATTR's `valid` bits.
const FATTR_SIZE: u32 = 1 << 3;
const FATTR_ATIME: u32 = 1 << 4;
const FATTR_MTIME: u32 = 1 << 5;
const FATTR_FH: u32 = 1 << 6;
const FATTR_ATIME_NOW: u32 = 1 << 7;
const FATTR_MTIME_NOW: u32 = 1 << 8;
const GETATTR_FH: u32 = 1;

// Linux open(2) flags (arm64).
const L_ACCMODE: u32 = 0o3;
const L_WRONLY: u32 = 0o1;
const L_RDWR: u32 = 0o2;
const L_EXCL: u32 = 0o200;
const L_TRUNC: u32 = 0o1000;
// renameat2 flags.
const RENAME_NOREPLACE: u32 = 1;
const RENAME_EXCHANGE: u32 = 2;

const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;
const S_IFREG: u32 = 0o100000;
const S_IFLNK: u32 = 0o120000;

/// Android's media_rw, which owns its media storage.
const MEDIA_RW: u32 = 1023;
const TIMEOUT: Duration = Duration::from_secs(1);
const NAME_MAX: usize = 255;

/// Left out of listings: what macOS keeps in folders for itself.
fn hidden(name: &[u8]) -> bool {
    name.starts_with(b"._")
        || matches!(name, b".DS_Store" | b".Trashes" | b".Spotlight-V100" | b".fseventsd" | b".TemporaryItems" | b"Icon\r")
}

/// A Linux errno for a host error (macOS numbers differ above 34).
pub fn linux_errno(error: &io::Error) -> i32 {
    let Some(code) = error.raw_os_error() else { return libc_linux::EIO };
    match code {
        1..=34 if code != libc::EDEADLK && code != libc::EAGAIN => code,
        libc::EAGAIN => 11,
        libc::EDEADLK => 35,
        libc::ENAMETOOLONG => 36,
        libc::ENOSYS => 38,
        libc::ENOTEMPTY => 39,
        libc::ELOOP => 40,
        libc::ENOATTR => 61,
        libc::EOVERFLOW => 75,
        libc::EILSEQ => 84,
        libc::ENOTSUP | libc::EOPNOTSUPP => 95,
        libc::ENOTCONN => 107,
        libc::ETIMEDOUT => 110,
        libc::EDQUOT => 122,
        libc::ECANCELED => 125,
        _ => libc_linux::EIO,
    }
}

/// The few Linux errno values used directly.
mod libc_linux {
    pub const EPERM: i32 = 1;
    pub const ENOENT: i32 = 2;
    pub const EIO: i32 = 5;
    pub const EBADF: i32 = 9;
    // The host's EEXIST maps itself (linux_errno); the tests name it.
    #[cfg(test)]
    pub const EEXIST: i32 = 17;
    pub const ENOTDIR: i32 = 20;
    pub const EINVAL: i32 = 22;
    pub const ENAMETOOLONG: i32 = 36;
    pub const ENOSYS: i32 = 38;
}

type Result<T> = std::result::Result<T, i32>;

fn host<T>(result: io::Result<T>) -> Result<T> {
    result.map_err(|e| linux_errno(&e))
}

// MARK: - Wire format

/// Little-endian fields read in order.
pub struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    pub fn new(bytes: &'a [u8]) -> Reader<'a> {
        Reader { bytes, at: 0 }
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        let end = self.at.checked_add(n).filter(|&end| end <= self.bytes.len()).ok_or(libc_linux::EINVAL)?;
        let slice = &self.bytes[self.at..end];
        self.at = end;
        Ok(slice)
    }

    pub fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    pub fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }

    fn skip(&mut self, n: usize) -> Result<()> {
        self.take(n).map(|_| ())
    }

    /// A NUL-terminated name.
    fn name(&mut self) -> Result<&'a [u8]> {
        let rest = &self.bytes[self.at..];
        let end = rest.iter().position(|&b| b == 0).ok_or(libc_linux::EINVAL)?;
        self.at += end + 1;
        Ok(&rest[..end])
    }

    pub fn rest(&self) -> &'a [u8] {
        &self.bytes[self.at..]
    }
}

#[derive(Default)]
struct Writer(Vec<u8>);

impl Writer {
    fn u16(&mut self, v: u16) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    fn u32(&mut self, v: u32) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    fn u64(&mut self, v: u64) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    fn zeros(&mut self, n: usize) -> &mut Self {
        self.0.resize(self.0.len() + n, 0);
        self
    }
}

/// `fuse_in_header`.
pub struct Header {
    pub opcode: u32,
    pub unique: u64,
    pub node: u64,
}

impl Header {
    pub fn parse(reader: &mut Reader) -> Result<Header> {
        let _len = reader.u32()?;
        let opcode = reader.u32()?;
        let unique = reader.u64()?;
        let node = reader.u64()?;
        reader.skip(16)?; // uid, gid, pid, extension length and padding
        Ok(Header { opcode, unique, node })
    }
}

/// A whole reply: `fuse_out_header` and, without an error, the payload.
pub fn reply(unique: u64, result: Result<Vec<u8>>) -> Vec<u8> {
    let (error, payload) = match result {
        Ok(payload) => (0, payload),
        Err(errno) => (-errno, Vec::new()),
    };
    let mut out = Writer::default();
    out.u32((16 + payload.len()) as u32).u32(error as u32).u64(unique);
    out.0.extend_from_slice(&payload);
    out.0
}

// MARK: - The server

struct Node {
    /// Relative to the folder; empty for the folder itself.
    path: PathBuf,
    /// The host's (device, inode).
    key: (u64, u64),
    lookups: u64,
}

enum Handle {
    File(File),
    /// A listing taken at OPENDIR: (inode, type, name).
    Dir(Vec<(u64, u32, Vec<u8>)>),
}

pub struct SharedDir {
    root: PathBuf,
    nodes: HashMap<u64, Node>,
    by_key: HashMap<(u64, u64), u64>,
    next_node: u64,
    handles: HashMap<u64, Handle>,
    next_handle: u64,
}

impl SharedDir {
    pub fn new(root: &Path) -> io::Result<SharedDir> {
        let metadata = std::fs::metadata(root)?;
        if !metadata.is_dir() {
            return Err(io::Error::new(io::ErrorKind::NotADirectory, "not a folder"));
        }
        let root = root.canonicalize()?;
        let key = (metadata.dev() as u64, metadata.ino());
        let mut shared = SharedDir {
            root,
            nodes: HashMap::new(),
            by_key: HashMap::new(),
            next_node: ROOT + 1,
            handles: HashMap::new(),
            next_handle: 1,
        };
        shared.nodes.insert(ROOT, Node { path: PathBuf::new(), key, lookups: 1 });
        shared.by_key.insert(key, ROOT);
        Ok(shared)
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// One request (its header and arguments, write data included); the
    /// reply, or None for the requests that get none (FORGET).
    pub fn handle(&mut self, request: &[u8]) -> Option<Vec<u8>> {
        let mut reader = Reader::new(request);
        let header = Header::parse(&mut reader).ok()?;
        let result = match header.opcode {
            FORGET => {
                let count = reader.u64().unwrap_or(0);
                self.forget(header.node, count);
                return None;
            }
            BATCH_FORGET => {
                let count = reader.u32().unwrap_or(0);
                let _ = reader.u32();
                for _ in 0..count {
                    let (Ok(node), Ok(lookups)) = (reader.u64(), reader.u64()) else { break };
                    self.forget(node, lookups);
                }
                return None;
            }
            INTERRUPT => return None,
            INIT => self.init(&mut reader),
            DESTROY => {
                self.handles.clear();
                Ok(Vec::new())
            }
            LOOKUP => reader.name().and_then(|name| self.lookup(header.node, name)),
            GETATTR => self.getattr(header.node, &mut reader),
            SETATTR => self.setattr(header.node, &mut reader),
            READLINK => self.readlink(header.node),
            SYMLINK => self.symlink(header.node, &mut reader),
            MKNOD => self.mknod(header.node, &mut reader),
            MKDIR => self.mkdir(header.node, &mut reader),
            UNLINK => reader.name().and_then(|name| self.remove(header.node, name, false)),
            RMDIR => reader.name().and_then(|name| self.remove(header.node, name, true)),
            RENAME => self.rename(header.node, &mut reader, false),
            RENAME2 => self.rename(header.node, &mut reader, true),
            LINK => self.link(header.node, &mut reader),
            OPEN => self.open(header.node, &mut reader),
            CREATE => self.create(header.node, &mut reader),
            READ => self.read(&mut reader),
            WRITE => self.write(&mut reader),
            RELEASE | RELEASEDIR => {
                if let Ok(fh) = reader.u64() {
                    self.handles.remove(&fh);
                }
                Ok(Vec::new())
            }
            FLUSH | SYNCFS => Ok(Vec::new()),
            FSYNC | FSYNCDIR => self.fsync(&mut reader),
            OPENDIR => self.opendir(header.node),
            READDIR => self.readdir(&mut reader),
            STATFS => self.statfs(),
            // Extended attributes, access(2), locks, fallocate, lseek,
            // statx, ioctl, Android's FUSE_CANONICAL_PATH: the kernel then
            // stops asking, or does without.
            _ => Err(libc_linux::ENOSYS),
        };
        Some(reply(header.unique, result))
    }

    fn init(&mut self, reader: &mut Reader) -> Result<Vec<u8>> {
        let major = reader.u32()?;
        let minor = reader.u32()?;
        let max_readahead = reader.u32()?;
        let flags = reader.u32()?;
        let mut out = Writer::default();
        if major != VERSION.0 {
            // An older or newer major: say ours, the kernel decides.
            out.u32(VERSION.0).u32(VERSION.1).zeros(56);
            return Ok(out.0);
        }
        out.u32(VERSION.0)
            .u32(minor.min(VERSION.1))
            .u32(max_readahead)
            .u32(flags & WANTED)
            .u16(64) // max_background
            .u16(48) // congestion_threshold
            .u32(MAX_TRANSFER) // max_write
            .u32(1) // time_gran: nanoseconds
            .u16((MAX_TRANSFER / 4096) as u16) // max_pages
            .u16(0) // map_alignment
            .u32(0) // flags2
            .u32(0) // max_stack_depth
            .zeros(24);
        Ok(out.0)
    }

    // MARK: Nodes and paths

    fn node_path(&self, node: u64) -> Result<PathBuf> {
        let node = self.nodes.get(&node).ok_or(libc_linux::ENOENT)?;
        Ok(self.root.join(&node.path))
    }

    /// A directory a request names: a directory on the Mac now, never a symlink.
    fn dir_path(&self, node: u64) -> Result<(PathBuf, PathBuf)> {
        let entry = self.nodes.get(&node).ok_or(libc_linux::ENOENT)?;
        let host_path = self.root.join(&entry.path);
        let metadata = host(std::fs::symlink_metadata(&host_path))?;
        if !metadata.is_dir() {
            return Err(libc_linux::ENOTDIR);
        }
        Ok((host_path, entry.path.clone()))
    }

    fn checked_name(name: &[u8]) -> Result<&OsStr> {
        if name.is_empty() || name == b"." || name == b".." || name.contains(&b'/') {
            return Err(libc_linux::EINVAL);
        }
        if name.len() > NAME_MAX {
            return Err(libc_linux::ENAMETOOLONG);
        }
        Ok(OsStr::from_bytes(name))
    }

    /// A child of a directory node: its host path and its relative path.
    fn child(&self, parent: u64, name: &[u8]) -> Result<(PathBuf, PathBuf)> {
        let name = Self::checked_name(name)?;
        let (host_dir, relative) = self.dir_path(parent)?;
        Ok((host_dir.join(name), relative.join(name)))
    }

    /// A node for a file just looked up (one more lookup for it).
    fn remember(&mut self, relative: PathBuf, metadata: &Metadata) -> u64 {
        let key = (metadata.dev() as u64, metadata.ino());
        if let Some(&node) = self.by_key.get(&key) {
            let entry = self.nodes.get_mut(&node).unwrap();
            entry.lookups += 1;
            if node != ROOT {
                entry.path = relative;
            }
            return node;
        }
        let node = self.next_node;
        self.next_node += 1;
        self.nodes.insert(node, Node { path: relative, key, lookups: 1 });
        self.by_key.insert(key, node);
        node
    }

    fn forget(&mut self, node: u64, count: u64) {
        if node == ROOT {
            return;
        }
        let Some(entry) = self.nodes.get_mut(&node) else { return };
        entry.lookups = entry.lookups.saturating_sub(count);
        if entry.lookups == 0 {
            let key = entry.key;
            self.nodes.remove(&node);
            self.by_key.remove(&key);
        }
    }

    fn entry(&mut self, relative: PathBuf, host_path: &Path) -> Result<Vec<u8>> {
        let metadata = host(std::fs::symlink_metadata(host_path))?;
        let node = self.remember(relative, &metadata);
        let mut out = Writer::default();
        out.u64(node).u64(0).u64(TIMEOUT.as_secs()).u64(TIMEOUT.as_secs()).u32(0).u32(0);
        attributes(&mut out, &metadata);
        Ok(out.0)
    }

    // MARK: Requests

    fn lookup(&mut self, parent: u64, name: &[u8]) -> Result<Vec<u8>> {
        let (host_path, relative) = self.child(parent, name)?;
        self.entry(relative, &host_path)
    }

    fn getattr(&mut self, node: u64, reader: &mut Reader) -> Result<Vec<u8>> {
        let flags = reader.u32().unwrap_or(0);
        let _ = reader.u32();
        let fh = reader.u64().unwrap_or(0);
        let metadata = match self.handles.get(&fh) {
            Some(Handle::File(file)) if flags & GETATTR_FH != 0 => host(file.metadata())?,
            _ => host(std::fs::symlink_metadata(self.node_path(node)?))?,
        };
        Ok(attr_out(&metadata))
    }

    fn setattr(&mut self, node: u64, reader: &mut Reader) -> Result<Vec<u8>> {
        let valid = reader.u32()?;
        let _ = reader.u32()?;
        let fh = reader.u64()?;
        let size = reader.u64()?;
        let _lock_owner = reader.u64()?;
        let atime = reader.u64()?;
        let mtime = reader.u64()?;
        let _ctime = reader.u64()?;
        let atimensec = reader.u32()?;
        let mtimensec = reader.u32()?;
        let path = self.node_path(node)?;
        if valid & FATTR_SIZE != 0 {
            match self.handles.get(&fh) {
                Some(Handle::File(file)) if valid & FATTR_FH != 0 => host(file.set_len(size))?,
                _ => host(open_nofollow(&path, OpenOptions::new().write(true)).and_then(|file| file.set_len(size)))?,
            }
        }
        if valid & (FATTR_ATIME | FATTR_MTIME) != 0 {
            let time = |set: u32, now: u32, seconds: u64, nanos: u32| -> libc::timespec {
                if valid & set == 0 {
                    libc::timespec { tv_sec: 0, tv_nsec: libc::UTIME_OMIT }
                } else if valid & now != 0 {
                    libc::timespec { tv_sec: 0, tv_nsec: libc::UTIME_NOW }
                } else {
                    libc::timespec { tv_sec: seconds as libc::time_t, tv_nsec: nanos as libc::c_long }
                }
            };
            let times = [time(FATTR_ATIME, FATTR_ATIME_NOW, atime, atimensec), time(FATTR_MTIME, FATTR_MTIME_NOW, mtime, mtimensec)];
            let c_path = c_path(&path)?;
            if unsafe { libc::utimensat(libc::AT_FDCWD, c_path.as_ptr(), times.as_ptr(), libc::AT_SYMLINK_NOFOLLOW) } != 0 {
                return Err(linux_errno(&io::Error::last_os_error()));
            }
        }
        // Mode, owner and group are Android's media storage's (see above).
        Ok(attr_out(&host(std::fs::symlink_metadata(&path))?))
    }

    fn readlink(&mut self, node: u64) -> Result<Vec<u8>> {
        let target = host(std::fs::read_link(self.node_path(node)?))?;
        Ok(target.as_os_str().as_bytes().to_vec())
    }

    fn symlink(&mut self, parent: u64, reader: &mut Reader) -> Result<Vec<u8>> {
        let name = reader.name()?.to_vec();
        let target = reader.name()?;
        let (host_path, relative) = self.child(parent, &name)?;
        host(std::os::unix::fs::symlink(OsStr::from_bytes(target), &host_path))?;
        self.entry(relative, &host_path)
    }

    fn mknod(&mut self, parent: u64, reader: &mut Reader) -> Result<Vec<u8>> {
        let mode = reader.u32()?;
        reader.skip(12)?;
        let name = reader.name()?.to_vec();
        if mode & S_IFMT != S_IFREG {
            return Err(libc_linux::EPERM); // no devices, FIFOs or sockets on the Mac's side
        }
        let (host_path, relative) = self.child(parent, &name)?;
        host(open_nofollow(&host_path, OpenOptions::new().write(true).create_new(true).mode(0o644)))?;
        self.entry(relative, &host_path)
    }

    fn mkdir(&mut self, parent: u64, reader: &mut Reader) -> Result<Vec<u8>> {
        reader.skip(8)?;
        let name = reader.name()?.to_vec();
        let (host_path, relative) = self.child(parent, &name)?;
        host(std::fs::create_dir(&host_path))?;
        self.entry(relative, &host_path)
    }

    fn remove(&mut self, parent: u64, name: &[u8], directory: bool) -> Result<Vec<u8>> {
        let (host_path, _) = self.child(parent, name)?;
        host(if directory { std::fs::remove_dir(&host_path) } else { std::fs::remove_file(&host_path) })?;
        Ok(Vec::new())
    }

    fn rename(&mut self, parent: u64, reader: &mut Reader, with_flags: bool) -> Result<Vec<u8>> {
        let new_parent = reader.u64()?;
        let flags = if with_flags {
            let flags = reader.u32()?;
            reader.skip(4)?;
            flags
        } else {
            0
        };
        let old_name = reader.name()?.to_vec();
        let new_name = reader.name()?.to_vec();
        let (old_host, old_relative) = self.child(parent, &old_name)?;
        let (new_host, new_relative) = self.child(new_parent, &new_name)?;
        let host_flags = match flags {
            0 => 0,
            RENAME_NOREPLACE => libc::RENAME_EXCL,
            RENAME_EXCHANGE => libc::RENAME_SWAP,
            _ => return Err(libc_linux::EINVAL), // RENAME_WHITEOUT
        };
        let (from, to) = (c_path(&old_host)?, c_path(&new_host)?);
        if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), host_flags) } != 0 {
            return Err(linux_errno(&io::Error::last_os_error()));
        }
        if flags == RENAME_EXCHANGE {
            self.moved(&old_relative, Path::new("\0swap"));
            self.moved(&new_relative, &old_relative);
            self.moved(Path::new("\0swap"), &new_relative);
        } else {
            self.moved(&old_relative, &new_relative);
        }
        Ok(Vec::new())
    }

    /// Nodes at or under `from` are now at or under `to`.
    fn moved(&mut self, from: &Path, to: &Path) {
        for node in self.nodes.values_mut() {
            if let Ok(rest) = node.path.strip_prefix(from) {
                node.path = if rest.as_os_str().is_empty() { to.to_path_buf() } else { to.join(rest) };
            }
        }
    }

    fn link(&mut self, parent: u64, reader: &mut Reader) -> Result<Vec<u8>> {
        let old = reader.u64()?;
        let name = reader.name()?.to_vec();
        let source = self.node_path(old)?;
        let (host_path, relative) = self.child(parent, &name)?;
        host(std::fs::hard_link(&source, &host_path))?;
        self.entry(relative, &host_path)
    }

    fn keep(&mut self, handle: Handle) -> u64 {
        let fh = self.next_handle;
        self.next_handle += 1;
        self.handles.insert(fh, handle);
        fh
    }

    fn open_out(fh: u64) -> Vec<u8> {
        let mut out = Writer::default();
        out.u64(fh).u32(0).u32(0);
        out.0
    }

    fn open(&mut self, node: u64, reader: &mut Reader) -> Result<Vec<u8>> {
        let flags = reader.u32()?;
        let path = self.node_path(node)?;
        let mut options = access(flags);
        if flags & L_TRUNC != 0 && flags & L_ACCMODE != 0 {
            options.truncate(true);
        }
        let file = host(open_nofollow(&path, &mut options))?;
        let fh = self.keep(Handle::File(file));
        Ok(Self::open_out(fh))
    }

    fn create(&mut self, parent: u64, reader: &mut Reader) -> Result<Vec<u8>> {
        let flags = reader.u32()?;
        reader.skip(12)?; // mode, umask, open flags
        let name = reader.name()?.to_vec();
        let (host_path, relative) = self.child(parent, &name)?;
        // Creating needs write access on the Mac, even for O_RDONLY | O_CREAT.
        let mut options = access(if flags & L_ACCMODE == 0 { L_RDWR } else { flags });
        options.mode(0o644);
        if flags & L_EXCL != 0 {
            options.create_new(true);
        } else {
            options.create(true);
        }
        if flags & L_TRUNC != 0 {
            options.truncate(true);
        }
        let file = host(open_nofollow(&host_path, &mut options))?;
        let mut out = self.entry(relative, &host_path)?;
        let fh = self.keep(Handle::File(file));
        out.extend_from_slice(&Self::open_out(fh));
        Ok(out)
    }

    fn file(&self, fh: u64) -> Result<&File> {
        match self.handles.get(&fh) {
            Some(Handle::File(file)) => Ok(file),
            _ => Err(libc_linux::EBADF),
        }
    }

    fn read(&mut self, reader: &mut Reader) -> Result<Vec<u8>> {
        let fh = reader.u64()?;
        let offset = reader.u64()?;
        let size = reader.u32()?.min(MAX_TRANSFER) as usize;
        let file = self.file(fh)?;
        let mut buffer = vec![0u8; size];
        let mut done = 0;
        while done < size {
            match file.read_at(&mut buffer[done..], offset + done as u64) {
                Ok(0) => break,
                Ok(n) => done += n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(linux_errno(&e)),
            }
        }
        buffer.truncate(done);
        Ok(buffer)
    }

    fn write(&mut self, reader: &mut Reader) -> Result<Vec<u8>> {
        let fh = reader.u64()?;
        let offset = reader.u64()?;
        let size = reader.u32()? as usize;
        reader.skip(20)?; // write flags, lock owner, flags, padding
        let data = reader.rest();
        let data = &data[..size.min(data.len())];
        host(self.file(fh)?.write_all_at(data, offset))?;
        let mut out = Writer::default();
        out.u32(data.len() as u32).u32(0);
        Ok(out.0)
    }

    fn fsync(&mut self, reader: &mut Reader) -> Result<Vec<u8>> {
        let fh = reader.u64()?;
        if let Some(Handle::File(file)) = self.handles.get(&fh) {
            host(file.sync_all())?;
        }
        Ok(Vec::new())
    }

    fn opendir(&mut self, node: u64) -> Result<Vec<u8>> {
        let (host_path, _) = self.dir_path(node)?;
        let directory = host(std::fs::metadata(&host_path))?;
        let mut entries = vec![(directory.ino(), S_IFDIR >> 12, b".".to_vec()), (directory.ino(), S_IFDIR >> 12, b"..".to_vec())];
        for entry in host(std::fs::read_dir(&host_path))? {
            let Ok(entry) = entry else { continue };
            let name = entry.file_name().as_bytes().to_vec();
            if hidden(&name) {
                continue;
            }
            let kind = match entry.file_type() {
                Ok(t) if t.is_dir() => S_IFDIR,
                Ok(t) if t.is_symlink() => S_IFLNK,
                Ok(t) if t.is_file() => S_IFREG,
                _ => 0,
            };
            entries.push((entry.ino(), kind >> 12, name));
        }
        let fh = self.keep(Handle::Dir(entries));
        Ok(Self::open_out(fh))
    }

    fn readdir(&mut self, reader: &mut Reader) -> Result<Vec<u8>> {
        let fh = reader.u64()?;
        let offset = reader.u64()? as usize;
        let size = reader.u32()? as usize;
        let Some(Handle::Dir(entries)) = self.handles.get(&fh) else { return Err(libc_linux::EBADF) };
        let mut out = Writer::default();
        for (index, (ino, kind, name)) in entries.iter().enumerate().skip(offset) {
            let record = (24 + name.len() + 7) & !7;
            if out.0.len() + record > size {
                break;
            }
            out.u64(*ino).u64(index as u64 + 1).u32(name.len() as u32).u32(*kind);
            out.0.extend_from_slice(name);
            let padding = record - 24 - name.len();
            out.zeros(padding);
        }
        Ok(out.0)
    }

    fn statfs(&mut self) -> Result<Vec<u8>> {
        let path = c_path(&self.root)?;
        let mut stat: libc::statvfs = unsafe { std::mem::zeroed() };
        if unsafe { libc::statvfs(path.as_ptr(), &mut stat) } != 0 {
            return Err(linux_errno(&io::Error::last_os_error()));
        }
        let mut out = Writer::default();
        out.u64(stat.f_blocks as u64)
            .u64(stat.f_bfree as u64)
            .u64(stat.f_bavail as u64)
            .u64(stat.f_files as u64)
            .u64(stat.f_ffree as u64)
            .u32(stat.f_bsize as u32)
            .u32(NAME_MAX as u32)
            .u32(stat.f_frsize as u32)
            .u32(0)
            .zeros(24);
        Ok(out.0)
    }
}

fn c_path(path: &Path) -> Result<CString> {
    CString::new(path.as_os_str().as_bytes()).map_err(|_| libc_linux::EINVAL)
}

fn access(flags: u32) -> OpenOptions {
    let mut options = OpenOptions::new();
    match flags & L_ACCMODE {
        L_WRONLY => options.write(true),
        L_RDWR => options.read(true).write(true),
        _ => options.read(true),
    };
    options
}

fn open_nofollow(path: &Path, options: &mut OpenOptions) -> io::Result<File> {
    options.custom_flags(libc::O_NOFOLLOW).open(path)
}

/// `fuse_attr` for a host file, as Android's media storage owns it.
fn attributes(out: &mut Writer, metadata: &Metadata) {
    let kind = metadata.mode() as u32 & S_IFMT;
    let mode = match kind {
        S_IFDIR => S_IFDIR | 0o770,
        S_IFLNK => S_IFLNK | 0o777,
        _ => kind | 0o660,
    };
    out.u64(metadata.ino())
        .u64(metadata.size())
        .u64(metadata.blocks())
        .u64(metadata.atime() as u64)
        .u64(metadata.mtime() as u64)
        .u64(metadata.ctime() as u64)
        .u32(metadata.atime_nsec() as u32)
        .u32(metadata.mtime_nsec() as u32)
        .u32(metadata.ctime_nsec() as u32)
        .u32(mode)
        .u32(metadata.nlink() as u32)
        .u32(MEDIA_RW)
        .u32(MEDIA_RW)
        .u32(0)
        .u32(metadata.blksize() as u32)
        .u32(0);
}

fn attr_out(metadata: &Metadata) -> Vec<u8> {
    let mut out = Writer::default();
    out.u64(TIMEOUT.as_secs()).u32(0).u32(0);
    attributes(&mut out, metadata);
    out.0
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A temporary folder, removed afterwards.
    struct Folder(PathBuf);

    impl Folder {
        fn new(name: &str) -> Folder {
            let path = std::env::temp_dir().join(format!("avo-fs-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Folder(path)
        }
    }

    impl Drop for Folder {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    struct Guest {
        server: SharedDir,
        unique: u64,
    }

    impl Guest {
        fn new(folder: &Folder) -> Guest {
            let mut guest = Guest { server: SharedDir::new(&folder.0).unwrap(), unique: 0 };
            let mut init = Writer::default();
            init.u32(7).u32(41).u32(128 << 10).u32(0xffff_ffff).u32(0).zeros(44);
            let out = guest.call(INIT, ROOT, &init.0).unwrap();
            assert_eq!(u32::from_le_bytes(out[4..8].try_into().unwrap()), 31, "our minor version");
            assert_eq!(u32::from_le_bytes(out[12..16].try_into().unwrap()), WANTED);
            guest
        }

        /// Sends one request; the payload or the (positive) errno.
        fn call(&mut self, opcode: u32, node: u64, args: &[u8]) -> std::result::Result<Vec<u8>, i32> {
            self.unique += 1;
            let mut request = Writer::default();
            request.u32((40 + args.len()) as u32).u32(opcode).u64(self.unique).u64(node).u32(0).u32(0).u32(1).u32(0);
            request.0.extend_from_slice(args);
            let reply = self.server.handle(&request.0).expect("a reply");
            let len = u32::from_le_bytes(reply[0..4].try_into().unwrap()) as usize;
            let error = i32::from_le_bytes(reply[4..8].try_into().unwrap());
            assert_eq!(u64::from_le_bytes(reply[8..16].try_into().unwrap()), self.unique);
            assert_eq!(len, reply.len());
            if error != 0 { Err(-error) } else { Ok(reply[16..].to_vec()) }
        }

        fn name(name: &str) -> Vec<u8> {
            let mut bytes = name.as_bytes().to_vec();
            bytes.push(0);
            bytes
        }

        /// (node, mode, size) from an entry reply.
        fn entry(out: &[u8]) -> (u64, u32, u64) {
            let node = u64::from_le_bytes(out[0..8].try_into().unwrap());
            let attr = &out[40..];
            let size = u64::from_le_bytes(attr[8..16].try_into().unwrap());
            let mode = u32::from_le_bytes(attr[60..64].try_into().unwrap());
            (node, mode, size)
        }

        fn lookup(&mut self, parent: u64, name: &str) -> std::result::Result<(u64, u32, u64), i32> {
            self.call(LOOKUP, parent, &Self::name(name)).map(|out| Self::entry(&out))
        }

        fn create(&mut self, parent: u64, name: &str) -> (u64, u64) {
            let mut args = Writer::default();
            args.u32(L_RDWR | 0o100 | L_EXCL).u32(0o600).u32(0o022).u32(0);
            args.0.extend_from_slice(&Self::name(name));
            let out = self.call(CREATE, parent, &args.0).unwrap();
            let fh = u64::from_le_bytes(out[128..136].try_into().unwrap());
            (Self::entry(&out).0, fh)
        }

        fn write(&mut self, node: u64, fh: u64, offset: u64, data: &[u8]) -> u32 {
            let mut args = Writer::default();
            args.u64(fh).u64(offset).u32(data.len() as u32).u32(0).u64(0).u32(0).u32(0);
            args.0.extend_from_slice(data);
            let out = self.call(WRITE, node, &args.0).unwrap();
            u32::from_le_bytes(out[0..4].try_into().unwrap())
        }

        fn read(&mut self, node: u64, fh: u64, offset: u64, size: u32) -> Vec<u8> {
            let mut args = Writer::default();
            args.u64(fh).u64(offset).u32(size).u32(0).u64(0).u32(0).u32(0);
            self.call(READ, node, &args.0).unwrap()
        }

        fn open(&mut self, node: u64, flags: u32) -> std::result::Result<u64, i32> {
            let mut args = Writer::default();
            args.u32(flags).u32(0);
            self.call(OPEN, node, &args.0).map(|out| u64::from_le_bytes(out[0..8].try_into().unwrap()))
        }

        fn release(&mut self, node: u64, fh: u64) {
            let mut args = Writer::default();
            args.u64(fh).u32(0).u32(0).u64(0);
            self.call(RELEASE, node, &args.0).unwrap();
        }

        fn list(&mut self, node: u64) -> Vec<String> {
            let mut args = Writer::default();
            args.u32(0).u32(0);
            let out = self.call(OPENDIR, node, &args.0).unwrap();
            let fh = u64::from_le_bytes(out[0..8].try_into().unwrap());
            let mut names = Vec::new();
            let mut offset = 0u64;
            loop {
                let mut args = Writer::default();
                args.u64(fh).u64(offset).u32(80).u32(0).u64(0).u32(0).u32(0);
                let out = self.call(READDIR, node, &args.0).unwrap();
                if out.is_empty() {
                    break;
                }
                let mut at = 0;
                while at < out.len() {
                    offset = u64::from_le_bytes(out[at + 8..at + 16].try_into().unwrap());
                    let len = u32::from_le_bytes(out[at + 16..at + 20].try_into().unwrap()) as usize;
                    names.push(String::from_utf8(out[at + 24..at + 24 + len].to_vec()).unwrap());
                    at += (24 + len + 7) & !7;
                }
            }
            let mut args = Writer::default();
            args.u64(fh).u32(0).u32(0).u64(0);
            self.call(RELEASEDIR, node, &args.0).unwrap();
            names.sort();
            names
        }
    }

    #[test]
    fn files_go_both_ways() {
        let folder = Folder::new("both");
        std::fs::write(folder.0.join("from-mac.txt"), b"hello from the Mac").unwrap();
        let mut guest = Guest::new(&folder);
        // The Mac's file, as Android's media storage owns it.
        let (node, mode, size) = guest.lookup(ROOT, "from-mac.txt").unwrap();
        assert_eq!((mode, size), (S_IFREG | 0o660, 18));
        let fh = guest.open(node, 0).unwrap();
        assert_eq!(guest.read(node, fh, 6, 100), b"from the Mac");
        guest.release(node, fh);
        // Android's file, on the Mac.
        let (created, fh) = guest.create(ROOT, "from-android.txt");
        assert_eq!(guest.write(created, fh, 0, b"hello from Android"), 18);
        guest.release(created, fh);
        assert_eq!(std::fs::read(folder.0.join("from-android.txt")).unwrap(), b"hello from Android");
        let mode = std::fs::metadata(folder.0.join("from-android.txt")).unwrap().mode() & 0o777;
        assert_eq!(mode, 0o644);
        assert_eq!(guest.call(GETATTR, created, &[0; 16]).map(|out| u64::from_le_bytes(out[24..32].try_into().unwrap())), Ok(18));
        // A second create of the same name fails as on Linux.
        let mut args = Writer::default();
        args.u32(L_RDWR | 0o100 | L_EXCL).u32(0o600).u32(0).u32(0);
        args.0.extend_from_slice(&Guest::name("from-android.txt"));
        assert_eq!(guest.call(CREATE, ROOT, &args.0).err(), Some(libc_linux::EEXIST));
        assert_eq!(guest.lookup(ROOT, "missing").err(), Some(libc_linux::ENOENT));
    }

    #[test]
    fn directories_renames_and_removal() {
        let folder = Folder::new("dirs");
        let mut guest = Guest::new(&folder);
        let mut args = Writer::default();
        args.u32(0o755).u32(0o022);
        args.0.extend_from_slice(&Guest::name("Photos"));
        let (photos, mode, _) = Guest::entry(&guest.call(MKDIR, ROOT, &args.0).unwrap());
        assert_eq!(mode, S_IFDIR | 0o770);
        let (file, fh) = guest.create(photos, "a.jpg");
        guest.write(file, fh, 0, b"jpeg");
        guest.release(file, fh);
        std::fs::write(folder.0.join(".DS_Store"), b"x").unwrap();
        std::fs::write(folder.0.join("._Photos"), b"x").unwrap();
        assert_eq!(guest.list(ROOT), [".", "..", "Photos"]);
        assert_eq!(guest.list(photos), [".", "..", "a.jpg"]);

        // Moving the folder keeps its nodes working.
        let mut rename = Writer::default();
        rename.u64(ROOT);
        rename.0.extend_from_slice(&Guest::name("Photos"));
        rename.0.extend_from_slice(&Guest::name("Camera"));
        guest.call(RENAME, ROOT, &rename.0).unwrap();
        assert!(folder.0.join("Camera/a.jpg").exists());
        let fh = guest.open(file, 0).unwrap();
        assert_eq!(guest.read(file, fh, 0, 10), b"jpeg");
        guest.release(file, fh);
        // RENAME_NOREPLACE refuses an existing name.
        guest.create(ROOT, "b.jpg");
        let mut rename = Writer::default();
        rename.u64(photos).u32(RENAME_NOREPLACE).u32(0);
        rename.0.extend_from_slice(&Guest::name("b.jpg"));
        rename.0.extend_from_slice(&Guest::name("a.jpg"));
        assert_eq!(guest.call(RENAME2, ROOT, &rename.0).err(), Some(libc_linux::EEXIST));

        assert_eq!(guest.call(RMDIR, ROOT, &Guest::name("Camera")).err(), Some(39), "ENOTEMPTY in Linux's numbering");
        guest.call(UNLINK, photos, &Guest::name("a.jpg")).unwrap();
        guest.call(RMDIR, ROOT, &Guest::name("Camera")).unwrap();
        assert!(!folder.0.join("Camera").exists());
    }

    #[test]
    fn nothing_outside_the_folder() {
        let folder = Folder::new("outside");
        let outside = Folder::new("secret");
        std::fs::write(outside.0.join("secret.txt"), b"secret").unwrap();
        let mut guest = Guest::new(&folder);
        for name in ["..", ".", "a/b", ""] {
            assert_eq!(guest.lookup(ROOT, name).err(), Some(libc_linux::EINVAL), "{name:?}");
        }
        // A symlink Android makes stays a symlink: never followed on the Mac.
        let mut args = Writer::default();
        args.0.extend_from_slice(&Guest::name("link"));
        args.0.extend_from_slice(&Guest::name(outside.0.to_str().unwrap()));
        let (link, mode, _) = Guest::entry(&guest.call(SYMLINK, ROOT, &args.0).unwrap());
        assert_eq!(mode, S_IFLNK | 0o777);
        assert_eq!(guest.call(READLINK, link, &[]).unwrap(), outside.0.as_os_str().as_bytes());
        assert_eq!(guest.lookup(link, "secret.txt").err(), Some(libc_linux::ENOTDIR));
        assert!(guest.open(link, 0).is_err(), "O_NOFOLLOW");
        assert_eq!(guest.call(OPENDIR, link, &[0; 8]).err(), Some(libc_linux::ENOTDIR));
    }

    #[test]
    fn truncation_times_and_forgetting() {
        let folder = Folder::new("attrs");
        std::fs::write(folder.0.join("notes.txt"), b"0123456789").unwrap();
        let mut guest = Guest::new(&folder);
        let (node, _, _) = guest.lookup(ROOT, "notes.txt").unwrap();
        let mut setattr = Writer::default();
        setattr.u32(FATTR_SIZE | FATTR_MTIME).u32(0).u64(0).u64(4).u64(0).u64(0).u64(1_700_000_000).u64(0).u32(0).u32(5).u32(0);
        setattr.u32(0).u32(0).u32(0).u32(0).u32(0);
        let out = guest.call(SETATTR, node, &setattr.0).unwrap();
        assert_eq!(u64::from_le_bytes(out[24..32].try_into().unwrap()), 4);
        let metadata = std::fs::metadata(folder.0.join("notes.txt")).unwrap();
        assert_eq!((metadata.len(), metadata.mtime(), metadata.mtime_nsec()), (4, 1_700_000_000, 5));
        // A second lookup is the same node; it goes once forgotten as often.
        assert_eq!(guest.lookup(ROOT, "notes.txt").unwrap().0, node);
        let mut forget = Writer::default();
        forget.u32(48 + 16).u32(FORGET).u64(99).u64(node).zeros(16).u64(2);
        assert!(guest.server.handle(&forget.0).is_none(), "no reply");
        assert_eq!(guest.call(GETATTR, node, &[0; 16]).err(), Some(libc_linux::ENOENT));
        assert!(guest.call(STATFS, ROOT, &[]).unwrap().len() == 80);
        assert_eq!(guest.call(0x7d0, ROOT, &[]).err(), Some(libc_linux::ENOSYS), "Android's FUSE_CANONICAL_PATH");
    }

    #[test]
    fn errors_use_linux_numbers() {
        assert_eq!(linux_errno(&io::Error::from_raw_os_error(libc::ENOENT)), 2);
        assert_eq!(linux_errno(&io::Error::from_raw_os_error(libc::ENOTEMPTY)), 39);
        assert_eq!(linux_errno(&io::Error::from_raw_os_error(libc::EAGAIN)), 11);
        assert_eq!(linux_errno(&io::Error::from_raw_os_error(libc::EDEADLK)), 35);
        assert_eq!(linux_errno(&io::Error::from_raw_os_error(libc::ENOATTR)), 61);
        assert_eq!(linux_errno(&io::Error::from_raw_os_error(9999)), libc_linux::EIO);
    }
}
