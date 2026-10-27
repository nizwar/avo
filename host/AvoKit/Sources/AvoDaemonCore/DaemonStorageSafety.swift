import AvoKit
import Foundation
import os

// MARK: - Android's data, whole whatever was cut short (DaemonCore.start)

/// What keeps Android's data whole across work Avo did not see to its end:
/// a checkpoint restore cut short is finished or undone when the daemon
/// starts, before anything can start Android on disks from two sides
/// (every start tries again first, and `prepareForStart` refuses while it
/// is not done).
extension DaemonCore {
    func startStorageSafety() {
        Task { [weak self] in await self?.recoverInterruptedWork() }
    }

    func recoverInterruptedWork() async {
        await finishInterruptedRestore()
    }
}
