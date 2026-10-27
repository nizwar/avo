import Darwin

/// What avo-vmm hands to the daemon and App Shims, the frames of every
/// scanout and the sound Android played: POSIX shared memory, which the
/// engine's events name `shm:/avo.<pid>.<what>` (engine/hvf/vmm/src/shm.rs).
/// A file, as an older engine used, would have the disk write every frame
/// back; a path still opens as one.
public enum SharedMemory {
    /// The shared memory name in an engine's `location`, or nil for a path.
    public static func name(of location: String) -> String? {
        guard location.hasPrefix("shm:") else { return nil }
        let name = String(location.dropFirst("shm:".count))
        return name.hasPrefix("/") && !name.isEmpty ? name : nil
    }

    /// Opens `location` to read: a descriptor to map, or -1 with `errno` set.
    public static func openForReading(_ location: String) -> Int32 {
        guard location.hasPrefix("shm:") else { return open(location, O_RDONLY) }
        guard let name = name(of: location) else {
            errno = EINVAL
            return -1
        }
        guard let shmOpen else {
            errno = ENOSYS
            return -1
        }
        return name.withCString { shmOpen($0, O_RDONLY) }
    }

    /// Removes the name `name`: nobody can open it any more, and the memory
    /// goes once the last mapping does.
    public static func remove(name: String) {
        _ = shm_unlink(name)
    }

    // shm_open is variadic in C, which Swift cannot call. Opening to read
    // passes no mode, and the fixed arguments go the same way either way.
    private typealias ShmOpen = @convention(c) (UnsafePointer<CChar>, Int32) -> Int32
    private static let shmOpen: ShmOpen? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        return dlsym(defaultHandle, "shm_open").map { unsafeBitCast($0, to: ShmOpen.self) }
    }()
}
