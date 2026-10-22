import AvoKit
import Foundation

// avoctl: command-line control of the Avo Runtime Daemon, shipped inside
// Avo.app/Contents/MacOS so scripts and CI can drive Avo.
//
//   avoctl status
//   avoctl start | stop | restart | snapshot
//   avoctl retry-gpu
//   avoctl gpu-cache [clear]
//   avoctl apps
//   avoctl install <file.apk|.xapk|.apkm|.apks>
//   avoctl uninstall <package>
//   avoctl shortcuts [package]
//   avoctl config [key=value ...]
//   avoctl app-graphics <package> [profile=apps|games|auto] [field=value ...] | reset
//   avoctl fingerprints [add <name> | rename <id> <name> | remove <id> | touch <id>|unregistered]
//   avoctl storage [status | location [<folder>|internal [move [--keep-old] | use | fresh <GB>]] | cancel | remove-internal-copy]
//   avoctl checkpoints [create [name] | restore <id> | delete <id>]

let usage = """
usage: avoctl <command> [arguments]

commands:
  status                 Android state and version
  start | stop | restart Control the Android VM
  retry-gpu              Forget a failed GPU start and restart Android on the GPU
  gpu-cache [clear]      Show (or empty) the GPU shader cache in ~/Library/Caches/Avo/gpu-cache
  apps                   List installed apps
  install <file>         Install an .apk, .xapk, .apkm or .apks
  uninstall <package>    Remove an app
  shortcuts [package]    Recreate app shortcuts and icons (all apps, or one)
  config [key=value ...] Show or change settings (memoryMiB, cpuCount, fpsLimit=30 or 60…120, rendererMode=auto|gpu|software, …).
                         Dotted keys reach into objects (appGraphics.renderScale=67,
                         gameGraphics.aspectRatio=16:10, phoneGraphics.renderScale=75); a value starting with { or [ is JSON.
                         Graphics: mode=followWindow|fixed|deviceProfile, shortSide=360…2160,
                         aspectRatio (fixed) and followAspectRatio (follow) = matchWindow|16:9|16:10|20:9|4:3,
                         orientation=portrait|landscape.
                         Devices: wifiEnabled, networkSpeed=full|nr|lte|hspa|umts|edge|gprs, shareMacBluetooth,
                         cellularEnabled, mobileNetworkType=gprs|edge|umts|hspa|lte|nr, cellularSignal=0…4,
                         bluetoothEnabled, camerasEnabled, backCamera and frontCamera = emulated|none|mac:<id>,
                         microphoneEnabled, shareLocation, shareClipboard.
                         Translate Screen: translationAtStartup.
                         graphicsOverrides is ignored here: use app-graphics.
  app-graphics <package> [profile=apps|games|auto] [field=value ...]
                         Show or change one app's graphics (fields as in appGraphics;
                         field=null follows the profile again)
  app-graphics <package> reset
                         Remove the app's graphics settings
  fingerprints           List Avo's fingers and which ones Android has (Settings › Fingerprints)
  fingerprints add <name> | rename <id> <name> | remove <id>
                         Add, rename or remove a finger (Android follows renames and removals)
  fingerprints touch <id>|unregistered
                         Touch Android's fingerprint sensor with a finger; while Android's
                         Settings adds a fingerprint, this adds the finger
  storage [status]       Where Android's data is, its volume and what it holds (Settings › Storage)
  storage location       The folder Android's data is in
  storage location <folder>|internal
                         What Avo finds there and which choices it allows (changes nothing)
  storage location <folder>|internal move [--keep-old] | use | fresh <GB> [--stop-android] [--replace]
                         Move Android's data there (copied and checked; the old copy goes unless
                         --keep-old), use the Android data already there, or start fresh there.
                         Android must be stopped (--stop-android stops it); --replace erases
                         a copy kept in Avo's own storage. "internal" is Avo's own storage.
  storage cancel         Stop a move that is still copying
  storage remove-internal-copy
                         Erase the copy of Android's data kept in Avo's own storage
  checkpoints            List the checkpoints of Android's apps and data (Settings › Android)
  checkpoints create [name]
                         Make a checkpoint now (Android holds still for a moment while it runs)
  checkpoints restore <id> | delete <id>
                         Put a checkpoint back (Android's data now is kept as a checkpoint
                         first; Android restarts when it runs), or delete one
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("avoctl: \(message)\n".utf8))
    exit(1)
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
}

/// A command-line value as JSON: an object or array when it starts with
/// `{` or `[`, else a number, boolean, null or plain string.
func jsonValue(_ value: String, in assignment: String) -> Any {
    if value.hasPrefix("{") || value.hasPrefix("[") {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(value.utf8)) else { fail("invalid JSON in \(assignment)") }
        return parsed
    }
    if let int = Int(value) { return int }
    if value == "true" || value == "false" { return value == "true" }
    if value == "null" { return NSNull() }
    return value
}

/// Sets `value` at a dotted path; every key on the way must already exist,
/// so a typo is an error instead of a setting that is silently dropped.
func assign(_ value: Any, at path: ArraySlice<String>, in object: [String: Any], for assignment: String) -> [String: Any] {
    var object = object
    guard let key = path.first, object.keys.contains(key) else { fail("unknown setting \(assignment)") }
    if path.count == 1 {
        object[key] = value
    } else {
        guard let child = object[key] as? [String: Any] else { fail("\(key) has no fields: \(assignment)") }
        object[key] = assign(value, at: path.dropFirst(), in: child, for: assignment)
    }
    return object
}

func split(_ assignment: String) -> (key: String, value: String) {
    let parts = assignment.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { fail("expected key=value: \(assignment)") }
    return (parts[0], parts[1])
}

/// Applies `key=value` (or `a.b=value`) to a configuration through its JSON form.
func apply(_ assignments: [String], to config: VMConfig) throws -> VMConfig {
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
    var given: [(path: [String], value: Any, assignment: String)] = []
    for assignment in assignments {
        let (key, value) = split(assignment)
        let path = key.split(separator: ".").map(String.init)
        let parsed = jsonValue(value, in: assignment)
        object = assign(parsed, at: path[...], in: object, for: assignment)
        given.append((path, parsed, assignment))
    }
    let result = try JSONDecoder().decode(VMConfig.self, from: JSONSerialization.data(withJSONObject: object))
    // The configuration keeps a value it cannot read at its default (so a
    // file from another Avo still loads): say so instead of saving that.
    let kept = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
    for (path, value, assignment) in given where !jsonMatches(path.reduce(kept as Any?) { ($0 as? [String: Any])?[$1] }, value) {
        fail("invalid value in \(assignment)")
    }
    return result
}

/// Whether `kept` holds `given` (every field of a given object; null removes).
func jsonMatches(_ kept: Any?, _ given: Any) -> Bool {
    if given is NSNull { return true }
    if let object = given as? [String: Any] {
        guard let keptObject = kept as? [String: Any] else { return false }
        return object.allSatisfy { key, value in jsonMatches(keptObject[key], value) }
    }
    guard let kept else { return false }
    let encode = { (value: Any) in try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]) }
    return encode(kept) == encode(given)
}

/// Applies `profile=…` and `field=value` to one app's graphics override.
/// The fields are those of `GraphicsSettings`; `null` removes a change.
func apply(_ assignments: [String], to override: AppGraphicsOverride) throws -> AppGraphicsOverride {
    var override = override
    let fields = Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(GraphicsSettings.appsDefault)) as! [String: Any]).keys)
    var changes = try JSONSerialization.jsonObject(with: JSONEncoder().encode(override.changes)) as! [String: Any]
    for assignment in assignments {
        let (key, value) = split(assignment)
        if key == "profile" {
            switch value {
            case "auto": override.profile = nil
            default:
                guard let profile = GraphicsProfile(rawValue: value) else { fail("profile is apps, games or auto: \(assignment)") }
                override.profile = profile
            }
            continue
        }
        // The field before modes: true follows the window, false is fixed.
        if key == "followsWindow" {
            guard let follows = jsonValue(value, in: assignment) as? Bool else { fail("followsWindow is true or false: \(assignment)") }
            changes["mode"] = follows ? GraphicsSettings.Mode.followWindow.rawValue : GraphicsSettings.Mode.fixed.rawValue
            continue
        }
        guard fields.contains(key) else { fail("unknown setting \(assignment)") }
        let parsed = jsonValue(value, in: assignment)
        changes[key] = parsed is NSNull ? nil : parsed
    }
    override.changes = try JSONDecoder().decode(GraphicsSettingsPatch.self, from: JSONSerialization.data(withJSONObject: changes))
    // The patch drops values it cannot read; say so instead.
    let kept = try JSONSerialization.jsonObject(with: JSONEncoder().encode(override.changes)) as! [String: Any]
    if let dropped = changes.keys.sorted().first(where: { kept[$0] == nil }) { fail("invalid value for \(dropped)") }
    return override
}

/// `avoctl storage …` (Settings › Storage › Location).
func storage(_ rest: [String], client: DaemonClient) async throws {
    let usage = "usage: avoctl storage [status | location [<folder>|internal [move [--keep-old] | use | fresh <GB>] [--stop-android] [--replace]] | cancel | remove-internal-copy]"
    switch rest.first {
    case nil, "status":
        printJSON(try await client.storageLocation())
    case "cancel":
        try await client.cancelStorageChange()
    case "remove-internal-copy":
        try await client.removeInternalStorageCopy()
    case "location":
        var words = Array(rest.dropFirst())
        let flags = Set(words.filter { $0.hasPrefix("--") })
        words.removeAll { $0.hasPrefix("--") }
        guard let place = words.first else {
            let status = try await client.storageLocation()
            print(status.path)
            if let problem = status.problem { print("problem: \(problem.message)") }
            return
        }
        let destination: String? = place == "internal" ? nil : URL(filePath: place).standardizedFileURL.path
        let action: StorageChangeAction
        switch (words.dropFirst().first, words.count) {
        case (nil, _):
            printJSON(try await client.inspectStorageLocation(destination))
            return
        case ("move"?, 2): action = .move(keepOldCopy: flags.contains("--keep-old"))
        case ("use"?, 2): action = .useExisting
        case ("fresh"?, 3):
            guard let gb = Int(words[2]), VMConfig.dataDiskRangeGB.contains(gb) else { fail("fresh needs a size in GB (\(VMConfig.dataDiskRangeGB))") }
            action = .startFresh(gb: gb)
        default:
            fail(usage)
        }
        let known: Set<String> = ["--keep-old", "--stop-android", "--replace"]
        if let unknown = flags.subtracting(known).first { fail("unknown option \(unknown)") }
        let request = StorageChangeRequest(destination: destination, action: action, stopAndroid: flags.contains("--stop-android"),
                                           replaceExisting: flags.contains("--replace"))
        let progress = Task {
            var shown = ""
            for await event in client.events {
                guard case .storageProgress(let p) = event, p.id == request.id else { continue }
                let percent = p.fraction.map { " \(Int($0 * 100))%" } ?? ""
                let line = "\(p.phase.rawValue)\(percent)\(p.message.map { ": \($0)" } ?? "")"
                if line != shown { print(line) }
                shown = line
            }
        }
        try await client.changeStorageLocation(request)
        try? await Task.sleep(for: .milliseconds(200))
        progress.cancel()
        printJSON(try await client.storageLocation())
    default:
        fail(usage)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(0)
}

let client = DaemonClient(role: .controlPanel, version: "avoctl")
do {
    _ = try await client.hello()
} catch {
    fail("cannot reach the Avo daemon: \(error.localizedDescription)")
}

do {
    switch command {
    case "status":
        printJSON(try await client.status())
    case "start":
        try await client.startVM()
        printJSON(try await client.status())
    case "stop":
        try await client.stopVM()
    case "restart":
        try await client.restartVM()
    case "snapshot":
        try await client.takeSnapshot()
    case "retry-gpu":
        try await client.retryGPU()
        printJSON(try await client.status())
    case "gpu-cache":
        switch arguments.dropFirst().first {
        case nil: printJSON(try await client.gpuCacheStatus())
        case "clear": printJSON(try await client.clearGPUCache())
        default: fail("usage: avoctl gpu-cache [clear]")
        }
    case "apps":
        for app in try await client.apps() {
            print("\(app.package)\t\(app.displayName)\t\(app.versionName)")
        }
    case "install":
        guard arguments.count == 2 else { fail("usage: avoctl install <file>") }
        let url = URL(filePath: arguments[1]).standardizedFileURL
        let request = InstallRequest(path: url.path)
        let progress = Task {
            for await event in client.events {
                if case .installProgress(let p) = event, p.id == request.id {
                    let percent = p.fraction.map { " \(Int($0 * 100))%" } ?? ""
                    print("\(p.phase.rawValue)\(percent)\(p.message.map { ": \($0)" } ?? "")")
                }
            }
        }
        try await client.install(request)
        progress.cancel()
    case "uninstall":
        guard arguments.count == 2 else { fail("usage: avoctl uninstall <package>") }
        try await client.uninstall(arguments[1])
    case "shortcuts":
        guard arguments.count <= 2 else { fail("usage: avoctl shortcuts [package]") }
        try await client.recreateShortcuts(for: arguments.count == 2 ? arguments[1] : nil)
    case "config":
        let snapshot = try await client.configuration()
        if arguments.count == 1 {
            printJSON(snapshot.config)
        } else {
            let result = try await client.updateConfiguration(try apply(Array(arguments.dropFirst()), to: snapshot.config))
            for issue in result.issues { print("\(issue.severity.rawValue): \(issue)") }
            print("effect: \(result.effect.rawValue)")
        }
    case "app-graphics":
        guard arguments.count >= 2 else { fail("usage: avoctl app-graphics <package> [profile=apps|games|auto] [field=value ...] | reset") }
        let package = arguments[1]
        let changes = Array(arguments.dropFirst(2))
        let current = try await client.configuration().config.graphicsOverrides[package] ?? AppGraphicsOverride()
        if changes.isEmpty {
            printJSON(current)
        } else {
            let override = changes == ["reset"] ? nil : try apply(changes, to: current)
            let result = try await client.setAppGraphics(override, for: package)
            for issue in result.issues { print("\(issue.severity.rawValue): \(issue)") }
            print("effect: \(result.effect.rawValue)")
        }
    case "checkpoints":
        let usage = "usage: avoctl checkpoints [create [name] | restore <id> | delete <id>]"
        let rest = Array(arguments.dropFirst())
        func checkpoint(_ text: String) -> UUID {
            guard let id = UUID(uuidString: text) else { fail(usage) }
            return id
        }
        switch rest.first {
        case nil:
            printJSON(try await client.checkpoints())
        case "create" where rest.count <= 2:
            printJSON(try await client.createCheckpoint(named: rest.count == 2 ? rest[1] : nil))
        case "restore" where rest.count == 2:
            try await client.restoreCheckpoint(checkpoint(rest[1]))
        case "delete" where rest.count == 2:
            try await client.deleteCheckpoint(checkpoint(rest[1]))
        default:
            fail(usage)
        }
    case "fingerprints":
        let usage = "usage: avoctl fingerprints [add <name> | rename <id> <name> | remove <id> | touch <id>|unregistered]"
        let rest = Array(arguments.dropFirst())
        func finger(_ text: String) -> Int {
            guard let id = Int(text), id > 0 else { fail(usage) }
            return id
        }
        switch rest.first {
        case nil:
            printJSON(try await client.fingerprints(refresh: true))
        case "add" where rest.count == 2:
            printJSON(try await client.addFingerprint(named: rest[1]))
        case "rename" where rest.count == 3:
            try await client.renameFingerprint(finger(rest[1]), to: rest[2])
        case "remove" where rest.count == 2:
            try await client.removeFingerprint(finger(rest[1]))
        case "touch" where rest.count == 2:
            print(try await client.touchFingerprint(rest[1] == "unregistered" ? nil : finger(rest[1])).rawValue)
        default:
            fail(usage)
        }
    case "storage":
        try await storage(Array(arguments.dropFirst()), client: client)
    default:
        print(usage)
        exit(2)
    }
} catch {
    fail((error as? LocalizedError)?.errorDescription ?? "\(error)")
}
