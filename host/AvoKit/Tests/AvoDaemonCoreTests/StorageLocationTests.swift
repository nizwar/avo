import AvoKit
import AvoPackages
import AvoTestSupport
import CryptoKit
import Foundation
import Testing
@testable import AvoDaemonCore

/// Settings › Storage › Location: Android's data in a folder of its own
/// (an external drive), carried between Macs.
@Suite struct StorageLocationTests {
    struct Scratch {
        let root: URL
        let paths: AvoPaths

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "avo-storage-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
            paths = AvoPaths(home: root.appending(path: "home"), temporaryDirectory: root.appending(path: "tmp"))
            try paths.createDirectories()
        }

        func folder(_ name: String) throws -> URL {
            let url = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    static let seventeen = AndroidRelease(version: "17", sdk: 37, sdkFull: "37.0", securityPatch: "2026-06-05")
    static let eighteen = AndroidRelease(version: "18", sdk: 38, sdkFull: "38.0", securityPatch: "2027-06-05")

    static func image(_ release: AndroidRelease, build: String, at root: URL) -> AndroidImageSummary {
        AndroidImageSummary(directory: root.appending(path: "images/android-\(release.version)-\(build)", directoryHint: .isDirectory),
                            release: release, build: build, origin: .imported(name: "test"), installedAt: nil, size: 1)
    }

    /// Android's data as avo-vmm and Android leave it: a sparse data disk
    /// with a few written stretches, the disks bound to it and the records.
    static func makeData(in folder: URL, release: AndroidRelease = seventeen, build: String = "16373615",
                         diskBytes: Int64 = 1 << 30) throws {
        let disks = folder.appending(path: "cuttlefish", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: disks, withIntermediateDirectories: true)
        let disk = folder.appending(path: "userdata.img")
        FileManager.default.createFile(atPath: disk.path, contents: nil)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: UInt64(diskBytes))
        for (offset, byte) in [(UInt64(1024), UInt8(0xF2)), (UInt64(300 << 20) + 17, 0x5A), (UInt64(diskBytes) - 4096, 0xA5)] {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data(repeating: byte, count: 3000))
        }
        try handle.close()
        for (name, size) in [("metadata.img", 64 << 20), ("misc.img", 1 << 20), ("frp.img", 1 << 20)] {
            let url = disks.appending(path: name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let disk = try FileHandle(forWritingTo: url)
            try disk.truncate(atOffset: UInt64(size))
            try disk.seek(toOffset: 4096)
            try disk.write(contentsOf: Data("key material for \(name)".utf8))
            try disk.close()
        }
        try Data("vbmeta".utf8).write(to: disks.appending(path: "vbmeta.img"))
        let record = AndroidDataRecord(release: release, build: build, date: Date(timeIntervalSince1970: 1_800_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: folder.appending(path: "android-data.json"))
        try Data(#"{"fingers":[{"id":1,"name":"Right thumb","enrolled":true}]}"#.utf8).write(to: folder.appending(path: "fingerprints.json"))
    }

    static func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func real(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    static func allocated(_ url: URL) -> Int64 {
        var info = stat()
        return stat(url.path, &info) == 0 ? Int64(info.st_blocks) * 512 : -1
    }

    // MARK: The manifest

    @Test func theManifestDescribesTheFolderAndRefusesAFormatItDoesNotRead() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let folder = try scratch.folder("Avo Android Data")
        let manifest = AndroidDataManifest(createdAt: Date(timeIntervalSince1970: 1_800_000_000.7), lastUsedAt: Date(timeIntervalSince1970: 1_800_100_000),
                                           lastMac: "Test Mac", android: Self.seventeen, build: "16373615", diskBytes: 62 << 30,
                                           storageCreated: true, googleApps: true, avoVersion: "1.0")
        try manifest.write(to: folder)
        #expect(try AndroidDataManifest.load(from: folder) == manifest)
        #expect(manifest.createdAt == Date(timeIntervalSince1970: 1_800_000_000))
        let text = try String(contentsOf: folder.appending(path: "avo-data.json"), encoding: .utf8)
        #expect(text.contains(#""format" : "avo-android-data""#))
        #expect(text.contains(#""formatVersion" : 1"#))

        // A newer Avo's folder, and something that is not Avo's at all.
        try Data(#"{"format":"avo-android-data","formatVersion":2,"id":"\#(UUID())"}"#.utf8).write(to: folder.appending(path: "avo-data.json"))
        #expect(throws: AndroidDataManifest.ReadError.unknownFormat(version: 2)) { try AndroidDataManifest.load(from: folder) }
        #expect(AndroidDataFolder(folder).problem(images: []) == .unknownFormat(path: folder.path, version: 2))
        try Data(#"{"format":"something-else","formatVersion":1}"#.utf8).write(to: folder.appending(path: "avo-data.json"))
        #expect(throws: AndroidDataManifest.ReadError.unknownFormat(version: 1)) { try AndroidDataManifest.load(from: folder) }
        try FileManager.default.removeItem(at: folder.appending(path: "avo-data.json"))
        #expect(throws: AndroidDataManifest.ReadError.missing) { try AndroidDataManifest.load(from: folder) }
    }

    // MARK: Validation

    @Test func dataFromANewerAndroidIsRefusedWithWhatToDo() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let folder = try scratch.folder("carried")
        try Self.makeData(in: folder, release: Self.eighteen, build: "17000000")
        let data = AndroidDataFolder(folder)
        let seventeen = Self.image(Self.seventeen, build: "16373615", at: scratch.root)
        let eighteen = Self.image(Self.eighteen, build: "17000000", at: scratch.root)

        // Only Android 17 here: download 18 first.
        let refused = data.problem(images: [seventeen])
        #expect(refused == .newerAndroid(data: "Android 18", build: "17000000", newestHere: "Android 17", installed: false))
        #expect(refused?.message.contains("Download Android 18") == true)
        // Android 18 is here: the data can be used ...
        #expect(data.problem(images: [eighteen, seventeen]) == nil)
        // ... but not started with 17: choose 18 first.
        let starting = AndroidDataFolder.newerAndroidProblem(data: Self.eighteen, build: "17000000", images: [eighteen, seventeen],
                                                            starting: seventeen)
        #expect(starting == .newerAndroid(data: "Android 18", build: "17000000", newestHere: "Android 18", installed: true))
        #expect(starting?.message.contains("Choose Android 18") == true)
        #expect(AndroidDataFolder.newerAndroidProblem(data: Self.seventeen, build: nil, images: [eighteen], starting: eighteen) == nil)
        // An older security patch of the same version cannot use it either (Keystore).
        let olderPatch = AndroidRelease(version: "17", sdk: 37, sdkFull: "37.0", securityPatch: "2026-01-05")
        #expect(AndroidDataFolder.newerAndroidProblem(data: Self.seventeen, build: nil, images: [], starting:
            Self.image(olderPatch, build: "1", at: scratch.root)) != nil)
    }

    /// The Setup Assistant on a new Mac: data from a newer Android than any
    /// image here is used where it is (it downloads that Android next), but
    /// Android never starts it with an older image.
    @Test func setupUsesDataFromANewerAndroidButNeverStartsItOlder() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let paths = scratch.paths
        let drive = try scratch.folder("Drive/Avo Android Data")
        try Self.makeData(in: drive, release: Self.eighteen, build: "17000000")
        try AndroidDataManifest(lastMac: "Old Mac", android: Self.eighteen, build: "17000000", diskBytes: 1 << 30, storageCreated: true)
            .write(to: drive)
        let seventeen = Self.image(Self.seventeen, build: "16373615", at: scratch.root)
        let locations = StorageLocations(paths: paths) { [seventeen] }

        let candidate = await locations.inspect(drive.path)
        #expect(candidate.existing?.android == "Android 18" && candidate.existing?.lastMac == "Old Mac")
        #expect(!candidate.allows(.existing))
        #expect(candidate.existingNeedsNewerAndroid)
        // Settings refuses it; the Setup Assistant may (it downloads Android 18 next).
        await #expect(throws: (any Error).self) {
            _ = try await locations.perform(StorageChangeRequest(destination: drive.path, action: .useExisting)) { _ in }
        }
        #expect(paths.isDataInternal)
        let request = StorageChangeRequest(destination: drive.path, action: .useExisting, allowNewerAndroid: true)
        guard case .adopted? = try? await locations.perform(request, report: { _ in }) else {
            Issue.record("the Setup Assistant could not use the data")
            return
        }
        #expect(Self.real(paths.data) == Self.real(drive))
        // Nothing was made in Avo's own storage, and the data is whole.
        #expect(!FileManager.default.fileExists(atPath: paths.vm.appending(path: "userdata.img").path))
        try await locations.prepareForStart()
        // Android 17 never starts it; Android 18 does.
        let store = AndroidImageStore(paths: paths)
        #expect(store.newerDataProblem(starting: seventeen, override: nil) != nil)
        #expect(store.newerDataProblem(starting: Self.image(Self.eighteen, build: "17000000", at: scratch.root), override: nil) == nil)
        // Data a format or a missing key makes unusable is never allowed, flag or not.
        let broken = try scratch.folder("Broken/Avo Android Data")
        try Self.makeData(in: broken, release: Self.eighteen, build: "17000000")
        try FileManager.default.removeItem(at: broken.appending(path: "cuttlefish/metadata.img"))
        let refused = await locations.inspect(broken.path)
        #expect(!refused.existingNeedsNewerAndroid)
        await #expect(throws: (any Error).self) {
            _ = try await locations.perform(StorageChangeRequest(destination: broken.path, action: .useExisting, allowNewerAndroid: true)) { _ in }
        }
    }

    /// A request from before `allowNewerAndroid` still reads.
    @Test func olderRequestsStillDecode() throws {
        let json = #"{"id":"\#(UUID().uuidString)","destination":"/Volumes/SSD","action":{"useExisting":{}},"stopAndroid":true,"replaceExisting":false}"#
        let request = try JSONDecoder().decode(StorageChangeRequest.self, from: Data(json.utf8))
        #expect(request.action == .useExisting && request.stopAndroid && !request.allowNewerAndroid)
        let round = try JSONDecoder().decode(StorageChangeRequest.self, from: JSONEncoder().encode(
            StorageChangeRequest(destination: nil, action: .startFresh(gb: 32), allowNewerAndroid: true)))
        #expect(round.allowNewerAndroid && round.action == .startFresh(gb: 32) && round.destination == nil)
    }

    @Test func dataWithoutItsKeyIsIncomplete() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let folder = try scratch.folder("carried")
        try Self.makeData(in: folder)
        #expect(AndroidDataFolder(folder).problem(images: []) == nil)
        // Android's data disk is encrypted with a key on the metadata disk.
        try FileManager.default.removeItem(at: folder.appending(path: "cuttlefish/metadata.img"))
        #expect(AndroidDataFolder(folder).problem(images: []) == .incomplete(path: folder.path, missing: ["cuttlefish/metadata.img"]))
        // A disk Android never wrote to has no key yet: nothing is missing.
        let fresh = try scratch.folder("fresh")
        FileManager.default.createFile(atPath: fresh.appending(path: "userdata.img").path, contents: nil)
        #expect(AndroidDataFolder(fresh).problem(images: []) == nil)
    }

    @Test func aStartWithAnOlderAndroidThanTheDataIsRefused() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try Self.makeData(in: scratch.paths.vm, release: Self.eighteen, build: "17000000")
        let store = AndroidImageStore(paths: scratch.paths)
        let older = Self.image(Self.seventeen, build: "16373615", at: scratch.root)
        #expect(store.newerDataProblem(starting: older, override: nil)
                == .newerAndroid(data: "Android 18", build: "17000000", newestHere: nil, installed: false))
        // Reset Android takes the data disk: anything starts again.
        try FileManager.default.removeItem(at: scratch.paths.dataDisk)
        #expect(store.newerDataProblem(starting: older, override: nil) == nil)
    }

    // MARK: Path resolution

    @Test func pathsFollowTheLocationRecord() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let paths = scratch.paths
        #expect(paths.data == paths.vm)
        #expect(paths.isDataInternal)
        #expect(paths.dataDisks.path == paths.instance.path)
        let elsewhere = try scratch.folder("SSD/Avo Android Data")
        try StorageLocationRecord(path: elsewhere.path, dataID: UUID()).save(paths)
        #expect(paths.data.path == elsewhere.path)
        #expect(!paths.isDataInternal)
        #expect(paths.dataDisk.path == elsewhere.appending(path: "userdata.img").path)
        #expect(paths.dataDisks.path == elsewhere.appending(path: "cuttlefish").path)
        // This Mac's side of the VM stays in Avo's own storage.
        #expect(paths.instance.path == paths.vm.appending(path: "cuttlefish").path)
        // Every copy of the paths sees a change at once (the daemon's components keep copies).
        let other = try scratch.folder("Other/Avo Android Data")
        try StorageLocationRecord(path: other.path, dataID: UUID()).save(paths)
        #expect(paths.data.path == other.path)
        try StorageLocationRecord.remove(paths)
        #expect(paths.data == paths.vm)

        // What depends on the data folder follows it: the disks bound to the
        // data disk, its storage figures, Avo's fingers and the image record.
        try StorageLocationRecord(path: elsewhere.path, dataID: UUID()).save(paths)
        let store = DataDiskStore(paths: paths)
        #expect(store.disk.path == elsewhere.appending(path: "userdata.img").path)
        #expect(store.dataBoundDisks.map(\.path) == ["metadata.img", "misc.img", "frp.img"].map { elsewhere.appending(path: "cuttlefish/\($0)").path })
        #expect(store.record.path == elsewhere.appending(path: "data-disk.json").path)
        #expect(FingerprintStore.url(paths).path == elsewhere.appending(path: "fingerprints.json").path)
        #expect(GoogleAppsJournal.url(paths).path == elsewhere.appending(path: "google-apps-commit.json").path)
        #expect(AndroidImageStore(paths: paths).instance.path == elsewhere.appending(path: "cuttlefish").path)
    }

    /// The location travels with its folder; a missing drive is said by name.
    @Test func findsTheFolderAgainOrSaysWhyNot() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let paths = scratch.paths
        let folder = try scratch.folder("Drive/Avo Android Data")
        let manifest = AndroidDataManifest()
        try manifest.write(to: folder)
        try StorageLocations.record(for: folder, id: manifest.id).save(paths)
        let locations = StorageLocations(paths: paths) { [] }
        #expect(await locations.resolve().problem == nil)

        // Renamed in Finder: the bookmark finds it, and the record follows.
        let renamed = scratch.root.appending(path: "Drive/Android (moved)", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: folder, to: renamed)
        let found = await locations.resolve()
        #expect(found.problem == nil)
        #expect(Self.real(found.folder) == Self.real(renamed))
        #expect(Self.real(paths.data) == Self.real(renamed))

        // Another folder of Android data where it was: not taken for it.
        try FileManager.default.removeItem(at: renamed)
        try FileManager.default.createDirectory(at: renamed, withIntermediateDirectories: true)
        try AndroidDataManifest().write(to: renamed)
        guard case .otherData? = await locations.resolve().problem else {
            Issue.record("another folder of Android data was taken for it")
            return
        }

        // A drive that is not connected, by its name.
        try StorageLocationRecord(path: "/Volumes/AvoNoSuchDrive-\(UUID().uuidString.prefix(6))/Avo Android Data", volumeName: "Travel SSD",
                                  volumeUUID: UUID().uuidString, dataID: UUID()).save(paths)
        let missing = await locations.resolve()
        guard case .volumeMissing(let volume, _)? = missing.problem else {
            Issue.record("expected a missing volume, got \(String(describing: missing.problem))")
            return
        }
        #expect(volume == "Travel SSD")
        #expect(missing.problem?.message.contains("“Travel SSD”, which isn’t connected") == true)
        // No start meanwhile, and nothing is created where the drive was.
        await #expect(throws: AvoError.storage(missing.problem!)) { try await locations.prepareForStart() }
        #expect(!FileManager.default.fileExists(atPath: missing.folder.path))
        #expect(throws: (any Error).self) { try paths.ensureDataFolder() }
        let status = await locations.status()
        #expect(status.problem == missing.problem)
        #expect(status.volumeName == "Travel SSD")
        #expect(!status.isInternal)
    }

    // MARK: Moving

    @Test func copiesKeepDisksSparseAndTheCheckFindsADifference() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let source = try scratch.folder("source")
        let destination = try scratch.folder("destination")
        try Self.makeData(in: source)
        var copier = try DataCopier(source: source, destination: destination, relative: AvoPaths.portableDataItems)
        copier.cloning = false
        // The written stretches only (whole 1 MiB blocks), not the 1 GiB disk.
        #expect(copier.totalBytes < 200 << 20)
        try copier.run()
        for item in AndroidDataFolder(source).presentItems() {
            #expect(try Self.sha(destination.appending(path: item)) == Self.sha(source.appending(path: item)), "\(item)")
        }
        let disk = destination.appending(path: "userdata.img")
        #expect(DataCopierSize.logical(disk) == 1 << 30)
        #expect(Self.allocated(disk) < 16 << 20, "the copy stays sparse")
        #expect(DataDiskStore.isWritten(disk))

        // The check reads the copy back: one changed byte fails it.
        let item = try #require(copier.items.first { $0.relative == "userdata.img" })
        let before = try DataCopier.digest(of: disk, ranges: item.ranges)
        #expect(before == (try DataCopier.digest(of: source.appending(path: "userdata.img"), ranges: item.ranges)))
        let handle = try FileHandle(forWritingTo: disk)
        try handle.seek(toOffset: (300 << 20) + 20)
        try handle.write(contentsOf: Data([0x00]))
        try handle.close()
        #expect(try DataCopier.digest(of: disk, ranges: item.ranges) != before)
    }

    @Test func movingAndBack() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let paths = scratch.paths
        try Self.makeData(in: paths.vm)
        let sums = try Dictionary(uniqueKeysWithValues: AndroidDataFolder(paths.vm).presentItems().map { ($0, try Self.sha(paths.vm.appending(path: $0))) })
        // A checkpoint of the data, and one cut short (no record), which is none.
        let checkpoint = Checkpoint(reason: .manual, detail: "Before moving", settings: CheckpointSettings(VMConfig()))
        try CheckpointStore(paths: paths).create(checkpoint)
        let checkpoints = paths.vm.appending(path: CheckpointStore.folderName)
        let partial = UUID().uuidString
        try FileManager.default.createDirectory(at: checkpoints.appending(path: partial), withIntermediateDirectories: true)
        let locations = StorageLocations(paths: paths, cloning: false) { [] }
        let drive = try scratch.folder("Drive")

        // The user picks the drive: Avo makes "Avo Android Data" on it.
        let candidate = await locations.inspect(drive.path)
        #expect(candidate.folder == drive.appending(path: "Avo Android Data").standardizedFileURL.path)
        #expect(candidate.existing == nil)
        #expect(candidate.allows(.move))
        #expect(candidate.allows(.fresh))
        #expect(!candidate.allows(.existing))
        #expect(candidate.moveBytes < 200 << 20)
        // The checkpoint comes along, as a copy of its own on another drive.
        #expect(candidate.checkpoints?.count == 1 && candidate.checkpoints?.comeAlong == true)
        #expect((candidate.checkpoints?.bytes ?? 0) > 0)

        let progress = StorageProgressLog()
        let request = StorageChangeRequest(destination: drive.path, action: .move(keepOldCopy: false))
        #expect(try await locations.perform(request) { progress.add($0) } == .moved)
        let moved = drive.appending(path: "Avo Android Data")
        #expect(Self.real(paths.data) == Self.real(moved))
        for (item, sum) in sums { #expect(try Self.sha(moved.appending(path: item)) == sum, "\(item)") }
        // Its checkpoint is there with it, whole, and can be restored there.
        #expect(CheckpointStore(paths: paths).list() == [checkpoint])
        let kept = moved.appending(path: "\(CheckpointStore.folderName)/\(checkpoint.id.uuidString)")
        for item in ["userdata.img", "cuttlefish/metadata.img"] {
            #expect(try Self.sha(kept.appending(path: item)) == sums[item], "\(item)")
        }
        #expect(!FileManager.default.fileExists(atPath: moved.appending(path: "\(CheckpointStore.folderName)/\(partial)").path))
        // The old copy is gone; this Mac's side of the VM stays.
        #expect(AndroidDataFolder(paths.vm).presentItems().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: checkpoints.path), "the old copy's checkpoints went with it")
        #expect(FileManager.default.fileExists(atPath: paths.instance.path))
        let phases = progress.phases
        #expect(phases.first == .checking && phases.last == .finished)
        #expect(phases.contains(.copying) && phases.contains(.verifying) && phases.contains(.removingOld))
        let manifest = try AndroidDataManifest.load(from: moved)
        #expect(StorageLocationRecord.load(paths)?.dataID == manifest.id)

        // Avo stamps who used it (at Android's start).
        var config = VMConfig()
        config.gms = .bringYourOwn
        try config.save(to: paths.config)
        await locations.stamp(avoVersion: "test")
        let stamped = try AndroidDataManifest.load(from: moved)
        #expect(stamped.id == manifest.id)
        #expect(stamped.android == Self.seventeen && stamped.build == "16373615")
        #expect(stamped.storageCreated && stamped.diskBytes == 1 << 30 && stamped.googleApps == true)
        #expect(stamped.lastUsedAt != nil)

        // Back to Avo's own storage, keeping the drive's copy: both have the checkpoint.
        let back = StorageChangeRequest(destination: nil, action: .move(keepOldCopy: true))
        #expect(try await locations.perform(back) { _ in } == .moved)
        #expect(paths.isDataInternal)
        #expect(StorageLocationRecord.load(paths) == nil)
        for (item, sum) in sums { #expect(try Self.sha(paths.vm.appending(path: item)) == sum, "\(item)") }
        #expect(AndroidDataFolder(moved).holdsData)
        #expect(CheckpointStore(paths: paths).list() == [checkpoint])
        #expect(CheckpointStore.count(in: moved) == 1)

        // The drive's copy is Android data Avo can use again ("carried to another Mac").
        let again = await locations.inspect(drive.path)
        #expect(again.folder == moved.standardizedFileURL.path)
        #expect(again.existing?.android == "Android 17")
        #expect(again.allows(.existing))
        #expect(!again.allows(.move), "never over other data")
        #expect(try await locations.perform(StorageChangeRequest(destination: drive.path, action: .useExisting)) { _ in } == .adopted(stamped))
        #expect(Self.real(paths.data) == Self.real(moved))
        // Avo's own storage keeps its copy, which Settings › Storage shows
        // with the checkpoint that Remove Copy… would take with it.
        let status = await locations.status()
        #expect(status.internalCopy?.android == "Android 17")
        #expect(status.internalCopy?.checkpoints == 1)
        #expect(status.data?.created == true)
        #expect(status.data?.checkpoints == 1)
    }

    /// Off APFS, or without room for them beside the data, checkpoints
    /// can't come along: they stay with the old copy, and a move that keeps
    /// none deletes them only when the user was told (the sheet says how many).
    @Test func checkpointsThatCannotComeAlongGoOnlyWhenTheUserLetsThem() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let paths = scratch.paths
        try Self.makeData(in: paths.vm)
        let checkpoint = Checkpoint(reason: .manual, settings: CheckpointSettings(VMConfig()))
        try CheckpointStore(paths: paths).create(checkpoint)
        let exFAT = VolumeSummary(name: "Travel", mountPoint: "/Volumes/Travel", format: "exfat", freeBytes: 500_000_000_000,
                                  capacityBytes: 1_000_000_000_000, isInternal: false, isRemovable: true, isReadOnly: false, isNetwork: false)
        let locations = StorageLocations(paths: paths, cloning: false, destinationVolume: { _ in exFAT }) { [] }
        let drive = try scratch.folder("Travel")
        let moved = drive.appending(path: "Avo Android Data")

        let candidate = await locations.inspect(drive.path)
        #expect(candidate.allows(.move))
        #expect(candidate.checkpoints?.count == 1 && candidate.checkpoints?.obstacle == .format("ExFAT"))
        // Not told: refused, and nothing changed.
        await #expect(throws: (any Error).self) {
            _ = try await locations.perform(StorageChangeRequest(destination: drive.path, action: .move(keepOldCopy: false))) { _ in }
        }
        #expect(paths.isDataInternal)
        #expect(CheckpointStore(paths: paths).list() == [checkpoint])
        #expect(!FileManager.default.fileExists(atPath: moved.path))

        // The old copy kept: the checkpoint stays with it, and none is on the drive.
        #expect(try await locations.perform(StorageChangeRequest(destination: drive.path, action: .move(keepOldCopy: true))) { _ in } == .moved)
        #expect(Self.real(paths.data) == Self.real(moved))
        #expect(CheckpointStore.count(in: moved) == 0)
        #expect(CheckpointStore.count(in: paths.vm) == 1)

        // Back over the copy kept in Avo's own storage: replacing it erases
        // its checkpoint with it (the sheet's question says so).
        let replace = await locations.inspect(nil)
        #expect(replace.existing?.checkpoints == 1)
        #expect(try await locations.perform(StorageChangeRequest(destination: nil, action: .move(keepOldCopy: false),
                                                                  replaceExisting: true)) { _ in } == .moved)
        #expect(paths.isDataInternal)
        #expect(CheckpointStore.count(in: paths.vm) == 0)

        // Out again keeping no copy, told: the checkpoint goes with the old copy.
        try CheckpointStore(paths: paths).create(checkpoint)
        let told = StorageChangeRequest(destination: drive.path, action: .move(keepOldCopy: false), leavesCheckpoints: true)
        #expect(try await locations.perform(told) { _ in } == .moved)
        #expect(Self.real(paths.data) == Self.real(moved))
        #expect(CheckpointStore.count(in: moved) == 0)
        #expect(!FileManager.default.fileExists(atPath: paths.vm.appending(path: CheckpointStore.folderName).path))
    }

    @Test func checkpointsComeAlongWhereTheyCanBeRestored() {
        let ssd = VolumeSummary(name: "SSD", mountPoint: "/Volumes/SSD", format: "apfs", freeBytes: 30_000_000_000,
                                capacityBytes: 1_000_000_000_000, isInternal: false, isRemovable: true, isReadOnly: false, isNetwork: false)
        let move = { (volume: VolumeSummary?, sameVolume: Bool) in
            StorageLocations.checkpointsMove(count: 3, bytes: 12_000_000_000, to: volume, sameVolume: sameVolume, dataBytes: 10_000_000_000)
        }
        #expect(StorageLocations.checkpointsMove(count: 0, bytes: 0, to: ssd, sameVolume: false, dataBytes: 1) == nil)
        // Copies on another APFS drive with room beside the data; clones, taking nothing, on the same one.
        #expect(move(ssd, false) == CheckpointsMove(count: 3, bytes: 12_000_000_000))
        #expect(move(ssd, true) == CheckpointsMove(count: 3, bytes: 0))
        var full = ssd
        full.freeBytes = 20_000_000_000
        #expect(move(full, false)?.obstacle == .room)
        #expect(move(full, true)?.comeAlong == true, "clones need no room")
        var exFAT = ssd
        exFAT.format = "exfat"
        #expect(move(exFAT, false)?.obstacle == .format("ExFAT"))
        // A volume that can't be described: the copy itself finds out.
        #expect(move(nil, false)?.comeAlong == true)
    }

    @Test func aFailedMoveLeavesTheDataWhereItWas() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let paths = scratch.paths
        try Self.makeData(in: paths.vm)
        let locations = StorageLocations(paths: paths, cloning: false) { [] }
        let drive = try scratch.folder("Drive")
        let moved = drive.appending(path: "Avo Android Data", directoryHint: .isDirectory)
        // A disk that cannot be read: nothing changes, nothing is left on the drive.
        let key = paths.vm.appending(path: "cuttlefish/metadata.img")
        chmod(key.path, 0)
        await #expect(throws: (any Error).self) {
            _ = try await locations.perform(StorageChangeRequest(destination: drive.path, action: .move(keepOldCopy: false))) { _ in }
        }
        chmod(key.path, 0o600)
        #expect(paths.isDataInternal)
        #expect(AndroidDataFolder(paths.vm).presentItems().contains("userdata.img"))
        #expect(!FileManager.default.fileExists(atPath: moved.path))
        #expect(await locations.change?.phase == .failed)

        // What a move the daemon did not see to its end left (a half copy in
        // the staging folder, a disk moved in) is no Android data: a new move replaces it.
        let staging = moved.appending(path: StorageLocations.stagingName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: staging.appending(path: "userdata.img"))
        try FileManager.default.createDirectory(at: moved.appending(path: "cuttlefish"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: moved.appending(path: "cuttlefish/misc.img"))
        let candidate = await locations.inspect(drive.path)
        #expect(candidate.existing == nil && candidate.allows(.move))
        let sum = try Self.sha(paths.vm.appending(path: "cuttlefish/misc.img"))
        #expect(try await locations.perform(StorageChangeRequest(destination: drive.path, action: .move(keepOldCopy: true))) { _ in } == .moved)
        #expect(try Self.sha(moved.appending(path: "cuttlefish/misc.img")) == sum)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(AndroidDataFolder(moved).problem(images: []) == nil)
    }

    @Test func startingFreshElsewhereKeepsTheDataHere() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let paths = scratch.paths
        try Self.makeData(in: paths.vm)
        let locations = StorageLocations(paths: paths) { [] }
        let drive = try scratch.folder("Drive")
        #expect(try await locations.perform(StorageChangeRequest(destination: drive.path, action: .startFresh(gb: 32))) { _ in } == .fresh(gb: 32))
        let fresh = drive.appending(path: "Avo Android Data")
        #expect(Self.real(paths.data) == Self.real(fresh))
        // A new data folder has no disks: avo-vmm makes blank metadata, misc and frp.
        #expect(AndroidDataFolder(fresh).presentItems() == ["avo-data.json"])
        #expect(try AndroidDataManifest.load(from: fresh).diskBytes == VMConfig.dataDiskBytes(gb: 32))
        // A first start creates the disk there.
        try DataDiskStore(paths: paths).ensure(gb: 32)
        #expect(DataCopierSize.logical(fresh.appending(path: "userdata.img")) == VMConfig.dataDiskBytes(gb: 32))
        // The data before stays in Avo's own storage; going back to it needs no copy.
        #expect(AndroidDataFolder(paths.vm).presentItems().contains("cuttlefish/metadata.img"))
        let own = await locations.inspect(nil)
        #expect(own.isInternal && own.allows(.existing))
        // Starting fresh there instead erases it only when asked to.
        await #expect(throws: (any Error).self) {
            _ = try await locations.perform(StorageChangeRequest(destination: nil, action: .startFresh(gb: 64))) { _ in }
        }
        #expect(try await locations.perform(StorageChangeRequest(destination: nil, action: .useExisting)) { _ in } == .adopted(nil))
        #expect(paths.isDataInternal)
        #expect(AndroidDataFolder(paths.vm).presentItems().contains("userdata.img"))
    }

    // MARK: The engine and ejects

    @Test func avoVMMKeepsTheDataDisksWithTheData() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let paths = scratch.paths
        let image = scratch.root.appending(path: "image", directoryHint: .isDirectory)
        let launch = EngineLaunch(config: VMConfig(), paths: paths,
                                  image: AndroidImage(schema: 1, version: "v", sdk: 37, kernel: "boot.img", initrd: nil, partitions: [],
                                                      overlayStock: "", overlayRooted: "", files: [], directory: image),
                                  bootConfigDisk: paths.vm.appending(path: "avo_config.img"), profile: nil)
        #expect(!VMMEngine.arguments(images: image, launch: launch).contains("--disks"))
        let drive = try scratch.folder("SSD/Avo Android Data")
        try StorageLocationRecord(path: drive.path, dataID: UUID()).save(paths)
        let arguments = VMMEngine.arguments(images: image, launch: launch)
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).map { arguments[$0 + 1] } }
        #expect(value("--disks") == drive.appending(path: "cuttlefish").path)
        #expect(value("--userdata") == drive.appending(path: "userdata.img").path)
        #expect(value("--instance") == paths.vm.appending(path: "cuttlefish").path)
        #expect(value("--properties") == paths.vm.appending(path: "identity.prop").path)
    }

    /// avo-vmm refused the drive (Removable Volumes turned off in System
    /// Settings): the start says so instead of pointing at the log.
    @Test func anEngineRefusedByMacOSSaysWhatToAllow() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let paths = scratch.paths
        let log = scratch.root.appending(path: "avo-vmm.log")
        let drive = "/Volumes/SSD/Avo Android Data"
        try "[vmm] preparing\nerror: \(drive)/userdata.img: Operation not permitted (os error 1)\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(VMMEngine.storageRefusal(inLog: log, paths: paths) == nil, "Avo's own storage: another cause")
        try StorageLocationRecord(path: drive, dataID: UUID()).save(paths)
        #expect(VMMEngine.storageRefusal(inLog: log, paths: paths) == .storage(.notPermitted(path: drive)))
        try "error: gfxstream did not start\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(VMMEngine.storageRefusal(inLog: log, paths: paths) == nil)
    }

    @Test func anEjectWaitsWhileAndroidUsesTheDrive() {
        let guarded = VolumeGuard()
        guarded.setDataVolume(mountPoint: "/Volumes/SSD", name: "SSD")
        #expect(guarded.refusal(for: "/Volumes/SSD") == nil)
        guarded.setAndroidActive(true)
        #expect(guarded.reason(for: "/Volumes/SSD/") == .android)
        #expect(guarded.refusal(for: "/Volumes/SSD")?.contains("eject the disk again") == true)
        #expect(guarded.reason(for: "/Volumes/Other") == nil)
        guarded.setAndroidActive(false)
        guarded.setMoving(["/Volumes/Other"])
        #expect(guarded.reason(for: "/Volumes/Other") == .moving)
        #expect(guarded.reason(for: "/Volumes/SSD") == nil)
    }

    /// A disk that goes stops Android only when the data's volume is no
    /// longer mounted: a disk image ejected under a name the drive once had
    /// is not the drive.
    @Test func onlyAVolumeThatIsNoLongerMountedIsGone() throws {
        #expect(DiskArbitrationWatcher.isMounted("/"))
        let folder = FileManager.default.temporaryDirectory.appending(path: "avo-mount-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!DiskArbitrationWatcher.isMounted(folder.path), "a folder of the Mac's disk")
        #expect(!DiskArbitrationWatcher.isMounted("/Volumes/Avo No Such Drive"))
    }

    @Test func candidatesAllowOnlyWhatIsSafe() {
        let volume = VolumeSummary(name: "SSD", mountPoint: "/Volumes/SSD", format: "exfat", freeBytes: 20_000_000_000,
                                   capacityBytes: 500_000_000_000, isInternal: false, isRemovable: true, isReadOnly: false, isNetwork: false)
        var candidate = StorageCandidate(chosen: "/Volumes/SSD", folder: "/Volumes/SSD/Avo Android Data", isInternal: false, isCurrent: false,
                                         volume: volume, existing: nil, problem: nil, issues: [], moveBytes: 1, currentAvailable: true)
        #expect(candidate.allows(.move) && candidate.allows(.fresh) && !candidate.allows(.existing))
        // No sparse files on ExFAT: a disk bigger than the free space does not fit at all.
        #expect(candidate.freshIssue(gb: 64)?.severity == .error)
        #expect(candidate.freshIssue(gb: 16) == nil)
        candidate.volume?.format = "apfs"
        #expect(candidate.freshIssue(gb: 64)?.severity == .warning)
        candidate.issues = [StorageIssue(.error, .move, "no room")]
        #expect(!candidate.allows(.move) && candidate.allows(.fresh))
        candidate.currentAvailable = false
        candidate.issues = []
        #expect(!candidate.allows(.move), "a missing drive's data cannot be moved")
        candidate.existing = AndroidDataSummary(android: "Android 17")
        #expect(candidate.allows(.existing) && !candidate.allows(.fresh))
        candidate.problem = .newerAndroid(data: "Android 18", build: nil, newestHere: "Android 17", installed: false)
        #expect(!candidate.allows(.existing))
        candidate.problem = nil
        candidate.isCurrent = true
        #expect(!candidate.allows(.existing))
    }
}

/// The daemon's side: Android stops for a change, Avo follows the data in
/// use, and a start without its data is refused with the reason.
@Suite(.serialized, .timeLimit(.minutes(1))) struct DaemonStorageLocationTests {
    @Test func changingWhereAndroidsDataIsStopsAndroidAndFollowsTheData() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app("org.fdroid.fdroid", label: "F-Droid")])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, events) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        #expect(await harness.waitForShims(1))
        let drive = harness.root.appending(path: "Drive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)

        // Android runs: only a request that may stop it goes ahead.
        let fresh = StorageChangeRequest(destination: drive.path, action: .startFresh(gb: 32))
        await #expect(throws: AvoError.self) { try await harness.core.changeStorageLocation(fresh, client: panel) }
        #expect(await harness.core.status().state == .running)
        var stopping = fresh
        stopping.stopAndroid = true
        try await harness.core.changeStorageLocation(stopping, client: panel)
        #expect(await harness.core.status().state == .stopped)
        let folder = drive.appending(path: "Avo Android Data")
        #expect(StorageLocationTests.real(harness.paths.data) == StorageLocationTests.real(folder))
        // A new Android: none of the apps, and the size chosen for it.
        #expect(await harness.core.apps().isEmpty)
        #expect(await harness.core.configurationSnapshot().config.dataDiskGiB == 32)
        let location = await harness.core.configurationSnapshot().storageLocation
        #expect(location?.isInternal == false && location?.problem == nil)
        #expect(location?.internalCopy != nil, "the data before stays in Avo's own storage")
        #expect(await events.wait { if case .storageProgress(let p) = $0 { p.id == stopping.id && p.phase == .finished } else { false } } != nil)
        #expect(await events.wait { if case .storageLocation(let l) = $0 { !l.isInternal } else { false } } != nil)

        // Android starts with its data there, and the folder says who used it.
        try await harness.core.startVM(client: panel)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "userdata.img").path))
        #expect(try AndroidDataManifest.load(from: folder).lastUsedAt != nil)
        try await harness.core.stopVM(client: panel)

        // The folder is gone: no start, and the reason is the status.
        try FileManager.default.removeItem(at: drive)
        await #expect(throws: AvoError.self) { try await harness.core.startVM(client: panel) }
        let failed = await harness.core.status()
        #expect(failed.state == .failed)
        #expect(failed.detail?.contains("missing") == true)
        #expect(!FileManager.default.fileExists(atPath: drive.path), "nothing is made where the data was")
        #expect(await harness.core.configurationSnapshot().storageLocation?.problem?.isMissing == true)

        // Use Avo's own storage: the data from before is still there.
        try await harness.core.changeStorageLocation(StorageChangeRequest(destination: nil, action: .useExisting), client: panel)
        #expect(harness.paths.isDataInternal)
        try await harness.core.startVM(client: panel)
        #expect(await harness.core.status().state == .running)
    }
}

final class StorageProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [StorageChangeProgress] = []
    func add(_ progress: StorageChangeProgress) { lock.withLock { list.append(progress) } }
    var phases: [StorageChangeProgress.Phase] {
        lock.withLock { list.map(\.phase) }.reduce(into: []) { if $0.last != $1 { $0.append($1) } }
    }
}

enum DataCopierSize {
    static func logical(_ url: URL) -> Int64 { DataDiskStore.size(url) }
}
