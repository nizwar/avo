import Foundation

/// What Android follows from the Mac, like a phone paired to it: dark or
/// light appearance, time zone, 12- or 24-hour clock, languages and battery.
/// The daemon reads it on the Mac (AvoDaemon/MacSystemState.swift) and
/// HostAgent applies whatever changed (its Mac state section); the guest
/// commands are built here, from pure values, so they can be tested.
public struct MacState: Sendable, Equatable {
    public var dark: Bool
    /// An IANA identifier (`TimeZone.identifier`), such as Asia/Jakarta.
    public var timeZone: String
    public var uses24HourClock: Bool
    /// BCP 47 tags, most preferred first (`Locale.preferredLanguages`).
    public var languages: [String]
    /// Nil on a Mac without a battery (a desktop Mac).
    public var battery: MacBattery?

    public init(dark: Bool, timeZone: String, uses24HourClock: Bool, languages: [String], battery: MacBattery?) {
        self.dark = dark
        self.timeZone = timeZone
        self.uses24HourClock = uses24HourClock
        self.languages = languages
        self.battery = battery
    }

    /// The Mac's clock: System Settings › General › Date & Time › 24-hour
    /// time where the user set it (the AppleICUForce24HourTime or
    /// AppleICUForce12HourTime preference, as Foundation reads them), else
    /// what the region uses.
    public static func uses24HourClock(force24Hour: Bool?, force12Hour: Bool?, regionDefault: Locale.HourCycle) -> Bool {
        if force24Hour == true { return true }
        if force12Hour == true { return false }
        return regionDefault == .zeroToTwentyThree || regionDefault == .oneToTwentyFour
    }
}

/// The Mac's internal battery, as IOKit's power sources describe it.
public struct MacBattery: Sendable, Equatable {
    /// Percent, 0...100.
    public var level: Int
    /// On the power adapter (it may be holding the charge, not charging).
    public var pluggedIn: Bool
    public var charging: Bool
    /// Full, which macOS says only while plugged in.
    public var charged: Bool

    public init(level: Int, pluggedIn: Bool, charging: Bool, charged: Bool) {
        self.level = min(max(level, 0), 100)
        self.pluggedIn = pluggedIn
        self.charging = charging
        self.charged = charged
    }

    /// From an `IOPSGetPowerSourceDescription` dictionary (keys and values
    /// as in IOKit's IOPSKeys.h); nil for anything but a present internal
    /// battery, such as a UPS or an external battery pack.
    public init?(powerSource: [String: Any]) {
        guard powerSource["Type"] as? String == "InternalBattery",
              powerSource["Is Present"] as? Bool ?? true,
              let current = powerSource["Current Capacity"] as? Int,
              let maximum = powerSource["Max Capacity"] as? Int, maximum > 0 else { return nil }
        self.init(level: Int((Double(current) / Double(maximum) * 100).rounded()),
                  pluggedIn: powerSource["Power Source State"] as? String == "AC Power",
                  charging: powerSource["Is Charging"] as? Bool ?? false,
                  charged: powerSource["Is Charged"] as? Bool ?? false)
    }

    /// Android's `BatteryManager.BATTERY_STATUS_*` for it.
    var androidStatus: Int {
        if charged, pluggedIn { return 5 } // FULL
        if charging { return 2 } // CHARGING
        if pluggedIn { return 4 } // NOT_CHARGING: macOS is holding the charge (Optimized Battery Charging)
        return 3 // DISCHARGING
    }
}

// MARK: Guest commands

extension MacState {
    /// UiModeManager's night mode, which apps see as the dark theme.
    static func appearanceCommand(dark: Bool) -> String {
        "cmd uimode night " + (dark ? "yes" : "no")
    }

    /// `cmd uimode night` prints `Night mode: yes` (or `no`, `auto`,
    /// `custom`); nil unless Android is plainly dark or light.
    static func isDark(uimode output: String) -> Bool? {
        guard let line = output.split(separator: "\n").first(where: { $0.contains("Night mode:") }) else { return nil }
        switch line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) {
        case "yes": return true
        case "no": return false
        default: return nil
        }
    }

    /// Whether `id` looks like an IANA time zone identifier (Area/Location,
    /// or a bare name like UTC), so it can be put on a shell command line
    /// unquoted. Android itself rejects identifiers its tzdata lacks.
    static func isValidTimeZoneID(_ id: String) -> Bool {
        guard (1...64).contains(id.count) else { return false }
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count <= 3 && parts.allSatisfy { part in
            guard let first = part.first, first.isASCII, first.isLetter else { return false }
            return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_+-".contains($0)) }
        }
    }

    /// Android's time zone detector takes the zone as the user's manual
    /// choice, the way Settings › Date & time sets it; it ignores manual
    /// choices while automatic detection is on (`autoTimeZoneOffCommand`).
    static func timeZoneCommand(_ id: String) -> String {
        "cmd time_zone_detector suggest_manual_time_zone --zone_id " + id
    }

    static let autoTimeZoneQuery = "cmd time_zone_detector is_auto_detection_enabled"
    /// Android would otherwise guess the zone from the emulated cell network,
    /// which says nothing about where the Mac is.
    static let autoTimeZoneOffCommand = "cmd time_zone_detector set_auto_detection_enabled false"

    /// The setting Settings › Date & time writes, then the broadcast it
    /// sends so running apps (the status bar clock among them) redraw:
    /// ACTION_TIME_CHANGED with EXTRA_TIME_PREF_24_HOUR_FORMAT and
    /// FLAG_RECEIVER_INCLUDE_BACKGROUND, a protected broadcast only system
    /// and root may send.
    static func clockCommand(uses24HourClock: Bool) -> String {
        "settings put system time_12_24 \(uses24HourClock ? 24 : 12) && am broadcast -a android.intent.action.TIME_SET"
            + " -f 0x01000000 --ei android.intent.extra.TIME_PREF_24_HOUR_FORMAT \(uses24HourClock ? 1 : 0)"
    }

    static let clockQuery = "settings get system time_12_24"

    /// `dumpsys battery set` replaces what the battery HAL reports (Cuttlefish
    /// reports a fixed 85%, charging, on AC and USB) until `reset`, which a
    /// Mac without a battery gets: there is nothing of the Mac's to show.
    /// After the first time only what changed is set again, since each `set`
    /// sends apps ACTION_BATTERY_CHANGED.
    ///
    /// The first time also turns the screen timeout off: provisioning keeps
    /// Android awake only "while plugged in", which a Mac on battery no longer
    /// is, and a sleeping Android blanks every window (touches don't wake it).
    /// Level 0 is sent as 1, since BatteryService powers Android off at 0%
    /// when nothing is plugged in; the Mac sleeps on its own by then.
    static func batteryCommand(_ battery: MacBattery?, over previous: MacBattery?) -> String? {
        guard let battery else { return "dumpsys battery reset" }
        var settings: [(String, Int)] = []
        if previous?.pluggedIn != battery.pluggedIn { settings.append(("ac", battery.pluggedIn ? 1 : 0)) }
        if previous == nil { settings += [("usb", 0), ("wireless", 0)] }
        if previous?.androidStatus != battery.androidStatus { settings.append(("status", battery.androidStatus)) }
        if previous?.level != battery.level { settings.append(("level", max(battery.level, 1))) }
        guard !settings.isEmpty else { return nil }
        let commands = settings.map { "dumpsys battery set \($0.0) \($0.1)" }
        return ((previous == nil ? [neverSleep] : []) + commands).joined(separator: " && ")
    }

    /// The longest screen timeout Android takes (Int32.max ms): never, in effect.
    static let neverSleep = "settings put system screen_off_timeout 2147483647"

    // MARK: Languages

    /// The Mac's languages as Android takes them: valid BCP 47 tags,
    /// comma-separated, each once, at most eight; nil if none is usable.
    static func androidLanguages(_ languages: [String]) -> String? {
        var tags: [String] = []
        for language in languages {
            let tag = language.replacingOccurrences(of: "_", with: "-")
            let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
            guard let first = parts.first, (2...8).contains(first.count), first.allSatisfy({ $0.isASCII && $0.isLetter }),
                  parts.dropFirst().allSatisfy({ (1...8).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }),
                  !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { continue }
            tags.append(tag)
            if tags.count == 8 { break }
        }
        return tags.isEmpty ? nil : tags.joined(separator: ",")
    }

    /// The helper's `locales` line: Android's languages, comma-separated.
    static func parseLanguages(_ output: String) -> String? {
        output.split(separator: "\n").last(where: { $0.hasPrefix("locales ") })
            .map { String($0.dropFirst("locales ".count)).trimmingCharacters(in: .whitespaces) }
    }

    /// The Mac's languages Avo last acted on, and Android's languages after
    /// it did (both as comma-separated tags), kept in Android's global
    /// settings (`avo_mac_languages`) so the decision outlives a reboot.
    struct LanguageSync: Equatable {
        var mac: String
        var android: String

        static let setting = "avo_mac_languages"

        var settingValue: String { mac + "|" + android }

        /// `settings get` prints `null` for a setting never written.
        init?(setting value: String) {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value != "null", let bar = value.firstIndex(of: "|") else { return nil }
            mac = String(value[..<bar])
            android = String(value[value.index(after: bar)...])
        }

        init(mac: String, android: String) {
            self.mac = mac
            self.android = android
        }
    }

    struct LanguagePlan: Equatable {
        /// Make the Mac's languages Android's.
        var apply: Bool
        /// What to keep as `LanguageSync` when not applying (after applying,
        /// it is what Android reports).
        var remember: LanguageSync?
    }

    /// Android's languages follow the Mac's only while they are what Avo
    /// last made them (from the Mac's previous languages), or Android's
    /// factory default nobody chose: a user who picked other languages in
    /// Android keeps them, and is asked nothing.
    static func languagePlan(mac: String, android: String, chosenInAndroid: Bool, last: LanguageSync?) -> LanguagePlan {
        if android.caseInsensitiveCompare(mac) == .orderedSame {
            // In step already; from here on Android follows the Mac.
            let now = LanguageSync(mac: mac, android: android)
            return LanguagePlan(apply: false, remember: last == now ? nil : now)
        }
        if let last {
            // The Mac's languages have not changed since: Android's stand.
            if last.mac == mac { return LanguagePlan(apply: false, remember: nil) }
            if android == last.android { return LanguagePlan(apply: true, remember: nil) }
        } else if !chosenInAndroid {
            return LanguagePlan(apply: true, remember: nil)
        }
        // The user's own choice: decided once for these Mac languages.
        return LanguagePlan(apply: false, remember: LanguageSync(mac: mac, android: last?.android ?? ""))
    }

    /// Whether Android's languages are someone's choice rather than the
    /// image's default: `persist.sys.locale` is written only when languages
    /// are chosen (in Settings, or by Avo), and choosing the image's own
    /// default (`ro.product.locale`) changes nothing worth keeping.
    static func languagesChosen(android: String, persisted: String, productDefault: String) -> Bool {
        let persisted = persisted.trimmingCharacters(in: .whitespacesAndNewlines)
        let productDefault = productDefault.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !persisted.isEmpty else { return false }
        return productDefault.isEmpty || android.caseInsensitiveCompare(productDefault) != .orderedSame
    }

    /// avo-macstate.jar (guest/macstate) on Android.
    static let helperJar = "/data/local/tmp/avo-macstate.jar"

    /// The helper prints Android's languages, after making them `tags` if given.
    static func languagesCommand(_ tags: String?) -> String {
        "CLASSPATH=\(helperJar) app_process / com.avodroid.macstate.Main locales" + (tags.map { " " + $0 } ?? "")
    }

    /// Every app keeps audio focus, as every window plays at once on a Mac
    /// (Android's multi audio focus): "1" once it is on, which Android keeps
    /// across boots.
    static let audioFocusQuery = "settings get system multi_audio_focus_enabled"

    /// As Android's system user: AudioService stores the setting with its
    /// caller's identity, which the settings provider refuses for any other.
    static let audioFocusCommand =
        "su 1000 sh -c 'CLASSPATH=\(helperJar) app_process / com.avodroid.macstate.Main audiofocus'"

    /// The helper gives Android display `androidID`'s top task the input
    /// focus, as a touch there would; it prints "focused task …" when it did.
    /// The shell user may (MANAGE_ACTIVITY_TASKS, which `am` needs too).
    static func focusDisplayCommand(_ androidID: Int) -> String {
        "CLASSPATH=\(helperJar) app_process / com.avodroid.macstate.Main focus-display \(androidID)"
    }
}
