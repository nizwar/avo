//! POSIX shared memory for what avo-vmm hands to the Runtime Daemon and App
//! Shims: the frames of every scanout (frames.rs) and the sound Android
//! played (virtio/sound/tap.rs).
//!
//! Not a file: macOS writes a mapped file's changed pages back to the disk,
//! and frames and sound change all the time. As files they were gigabytes a
//! day (macOS's disk-writes reports on avo-vmm, 2026-10-23); shared memory
//! never touches the disk.
//!
//! Each object is named `/avo.<pid>.<what>`, announced on the control socket
//! as `shm:<name>`, and opened by name to read. Its owner removes the name
//! when it lets go of the memory; mappings stay valid until unmapped. The
//! daemon removes every name it was told of when avo-vmm exits, so one left
//! by a crash does not hold memory until the Mac restarts.

use std::ffi::CString;
use std::io;

/// Longest name macOS takes, the slash included (PSHMNAMLEN).
const NAME_MAX: usize = 31;

/// The name of this process's object `what` ("0.3" for scanout 0's third
/// layout, "audio").
pub fn name(what: &str) -> String {
    format!("/avo.{}.{what}", std::process::id())
}

/// How a reader is told where to find the object `name`.
pub fn location(name: &str) -> String {
    format!("shm:{name}")
}

/// Makes the object `name`, `len` bytes of zeros, and maps it for reading and
/// writing. One of the same name left behind (by an earlier process with
/// this pid) is replaced. The caller unmaps it and calls `unlink`.
pub fn create(name: &str, len: usize) -> io::Result<*mut u8> {
    let name = c_name(name)?;
    unsafe {
        libc::shm_unlink(name.as_ptr());
        let fd = libc::shm_open(name.as_ptr(), libc::O_CREAT | libc::O_EXCL | libc::O_RDWR, 0o600 as libc::c_uint);
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let mapped = if libc::ftruncate(fd, len as libc::off_t) != 0 {
            Err(io::Error::last_os_error())
        } else {
            let map = libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, fd, 0);
            if map == libc::MAP_FAILED { Err(io::Error::last_os_error()) } else { Ok(map.cast::<u8>()) }
        };
        libc::close(fd);
        // An object that could not be made leaves no name behind.
        if mapped.is_err() {
            libc::shm_unlink(name.as_ptr());
        }
        mapped
    }
}

/// Removes the name `name`: no new reader can open it, and the memory goes
/// once the last mapping does.
pub fn unlink(name: &str) {
    if let Ok(name) = c_name(name) {
        unsafe { libc::shm_unlink(name.as_ptr()) };
    }
}

fn c_name(name: &str) -> io::Result<CString> {
    if !name.starts_with('/') || name.len() > NAME_MAX {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, format!("not a shared memory name: {name}")));
    }
    CString::new(name).map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "a shared memory name with a NUL"))
}

/// Maps the object `name` read-only, as a reader would: its bytes, for tests.
#[cfg(test)]
pub fn read(name: &str) -> io::Result<Vec<u8>> {
    let name = c_name(name)?;
    unsafe {
        let fd = libc::shm_open(name.as_ptr(), libc::O_RDONLY);
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let mut info: libc::stat = std::mem::zeroed();
        let size = if libc::fstat(fd, &mut info) == 0 { info.st_size as usize } else { 0 };
        let map = libc::mmap(std::ptr::null_mut(), size, libc::PROT_READ, libc::MAP_SHARED, fd, 0);
        libc::close(fd);
        if size == 0 || map == libc::MAP_FAILED {
            return Err(io::Error::last_os_error());
        }
        let bytes = std::slice::from_raw_parts(map.cast::<u8>(), size).to_vec();
        libc::munmap(map, size);
        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reader_sees_what_the_owner_wrote_and_the_name_goes() {
        let name = name("test.shm");
        let map = create(&name, 16384).unwrap();
        unsafe { std::ptr::copy_nonoverlapping(b"AVOF".as_ptr(), map, 4) };
        let bytes = read(&name).unwrap();
        assert!(bytes.len() >= 16384);
        assert_eq!(&bytes[0..4], b"AVOF");
        assert_eq!(location(&name), format!("shm:{name}"));
        unlink(&name);
        assert!(read(&name).is_err());
        // The owner's mapping outlives the name.
        assert_eq!(unsafe { *map }, b'A');
        unsafe { libc::munmap(map.cast(), 16384) };
    }

    #[test]
    fn a_name_left_behind_is_replaced() {
        let name = name("test.stale");
        let first = create(&name, 16384).unwrap();
        unsafe { *first = 7 };
        let second = create(&name, 16384).unwrap();
        assert_eq!(read(&name).unwrap()[0], 0);
        unlink(&name);
        unsafe {
            libc::munmap(first.cast(), 16384);
            libc::munmap(second.cast(), 16384);
        }
    }

    #[test]
    fn names_fit_macos() {
        assert!(name("0.4294967295").len() <= NAME_MAX);
        assert!(create("no-slash", 16384).is_err());
        assert!(create(&format!("/{}", "x".repeat(40)), 16384).is_err());
    }
}
