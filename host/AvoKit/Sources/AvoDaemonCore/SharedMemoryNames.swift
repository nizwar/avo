import AvoKit
import Foundation

/// The shared memory an engine announced (its frames and its played sound),
/// removed once the engine exits. An engine removes its own names as it lets
/// go of them; one that crashes cannot, and the memory would stay until the
/// Mac restarts.
final class SharedMemoryNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []

    /// Remembers the shared memory at an engine's `location` (a path is not).
    func note(_ location: String) {
        guard let name = SharedMemory.name(of: location) else { return }
        lock.withLock { _ = names.insert(name) }
    }

    /// The names noted so far.
    var noted: Set<String> {
        lock.withLock { names }
    }

    /// Removes every name noted; the engine is gone.
    func removeAll() {
        let gone = lock.withLock { () -> Set<String> in
            defer { names = [] }
            return names
        }
        for name in gone { SharedMemory.remove(name: name) }
    }
}
