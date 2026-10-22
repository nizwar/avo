import Foundation
import Testing
@testable import AvoDaemonCore

@Suite struct MacStateTests {
    // MARK: Appearance

    @Test func appearanceIsAndroidsNightMode() {
        #expect(MacState.appearanceCommand(dark: true) == "cmd uimode night yes")
        #expect(MacState.appearanceCommand(dark: false) == "cmd uimode night no")
    }

    @Test func readsAndroidsNightMode() {
        #expect(MacState.isDark(uimode: "Night mode: yes\n") == true)
        #expect(MacState.isDark(uimode: "Night mode: no\n") == false)
        // Auto and custom schedules are neither: Avo sets the Mac's.
        #expect(MacState.isDark(uimode: "Night mode: auto\n") == nil)
        #expect(MacState.isDark(uimode: "Night mode: custom\n") == nil)
        #expect(MacState.isDark(uimode: "") == nil)
    }

    // MARK: Time zone

    @Test func acceptsIANATimeZones() {
        for id in ["Asia/Jakarta", "America/Argentina/Buenos_Aires", "America/Port-au-Prince", "Etc/GMT+7", "UTC", "GMT"] {
            #expect(MacState.isValidTimeZoneID(id), "\(id)")
        }
    }

    @Test func rejectsWhatIsNotATimeZone() {
        for id in ["", "Asia/", "/Jakarta", "Asia//Jakarta", "Asia/Jakarta; reboot", "Asia/Jakarta'", "../etc", "Asia/Jakarta Time",
                   "Asia/Jákarta", "1Asia/Jakarta", "A/B/C/D", String(repeating: "A", count: 65)] {
            #expect(!MacState.isValidTimeZoneID(id), "\(id)")
        }
    }

    @Test func timeZoneIsAManualChoiceInTheDetector() {
        #expect(MacState.timeZoneCommand("Asia/Jakarta") == "cmd time_zone_detector suggest_manual_time_zone --zone_id Asia/Jakarta")
        #expect(MacState.autoTimeZoneOffCommand == "cmd time_zone_detector set_auto_detection_enabled false")
    }

    // MARK: Clock

    @Test func clockSettingAndItsBroadcast() {
        #expect(MacState.clockCommand(uses24HourClock: true)
                == "settings put system time_12_24 24 && am broadcast -a android.intent.action.TIME_SET -f 0x01000000"
                + " --ei android.intent.extra.TIME_PREF_24_HOUR_FORMAT 1")
        #expect(MacState.clockCommand(uses24HourClock: false)
                == "settings put system time_12_24 12 && am broadcast -a android.intent.action.TIME_SET -f 0x01000000"
                + " --ei android.intent.extra.TIME_PREF_24_HOUR_FORMAT 0")
    }

    @Test func theMacsClockSettingBeatsTheRegion() {
        #expect(MacState.uses24HourClock(force24Hour: nil, force12Hour: nil, regionDefault: .zeroToTwentyThree))
        #expect(!MacState.uses24HourClock(force24Hour: nil, force12Hour: nil, regionDefault: .oneToTwelve))
        #expect(!MacState.uses24HourClock(force24Hour: nil, force12Hour: nil, regionDefault: .zeroToEleven))
        #expect(MacState.uses24HourClock(force24Hour: true, force12Hour: nil, regionDefault: .oneToTwelve))
        #expect(!MacState.uses24HourClock(force24Hour: nil, force12Hour: true, regionDefault: .zeroToTwentyThree))
        #expect(MacState.uses24HourClock(force24Hour: false, force12Hour: false, regionDefault: .zeroToTwentyThree))
    }

    // MARK: Battery

    @Test func readsTheInternalBattery() {
        let charging: [String: Any] = ["Type": "InternalBattery", "Is Present": true, "Current Capacity": 57, "Max Capacity": 100,
                                       "Power Source State": "AC Power", "Is Charging": true, "Is Charged": false]
        #expect(MacBattery(powerSource: charging) == MacBattery(level: 57, pluggedIn: true, charging: true, charged: false))
        let onBattery: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 1234, "Max Capacity": 4321,
                                        "Power Source State": "Battery Power", "Is Charging": false]
        #expect(MacBattery(powerSource: onBattery) == MacBattery(level: 29, pluggedIn: false, charging: false, charged: false))
    }

    @Test func ignoresOtherPowerSources() {
        #expect(MacBattery(powerSource: ["Type": "UPS", "Current Capacity": 90, "Max Capacity": 100]) == nil)
        #expect(MacBattery(powerSource: ["Type": "InternalBattery", "Is Present": false, "Current Capacity": 90, "Max Capacity": 100]) == nil)
        #expect(MacBattery(powerSource: ["Type": "InternalBattery", "Current Capacity": 90, "Max Capacity": 0]) == nil)
        #expect(MacBattery(powerSource: ["Type": "InternalBattery"]) == nil)
    }

    @Test func batteryStatusAsAndroidSaysIt() {
        #expect(MacBattery(level: 100, pluggedIn: true, charging: false, charged: true).androidStatus == 5)
        #expect(MacBattery(level: 40, pluggedIn: true, charging: true, charged: false).androidStatus == 2)
        // Optimized Battery Charging holds at 80% on the adapter.
        #expect(MacBattery(level: 80, pluggedIn: true, charging: false, charged: false).androidStatus == 4)
        #expect(MacBattery(level: 40, pluggedIn: false, charging: false, charged: false).androidStatus == 3)
        #expect(MacBattery(level: 140, pluggedIn: false, charging: false, charged: false).level == 100)
    }

    @Test func firstBatteryReplacesWhatTheHALReports() {
        let battery = MacBattery(level: 57, pluggedIn: false, charging: false, charged: false)
        // Unplugged, "stay on while plugged in" no longer holds: no timeout instead.
        #expect(MacState.batteryCommand(battery, over: nil)
                == "settings put system screen_off_timeout 2147483647"
                + " && dumpsys battery set ac 0 && dumpsys battery set usb 0 && dumpsys battery set wireless 0"
                + " && dumpsys battery set status 3 && dumpsys battery set level 57")
    }

    @Test func anEmptyMacBatteryDoesNotPowerAndroidOff() {
        let before = MacBattery(level: 2, pluggedIn: false, charging: false, charged: false)
        #expect(MacState.batteryCommand(MacBattery(level: 0, pluggedIn: false, charging: false, charged: false), over: before)
                == "dumpsys battery set level 1")
    }

    @Test func laterOnlyWhatChanged() {
        let before = MacBattery(level: 57, pluggedIn: false, charging: false, charged: false)
        #expect(MacState.batteryCommand(MacBattery(level: 56, pluggedIn: false, charging: false, charged: false), over: before)
                == "dumpsys battery set level 56")
        #expect(MacState.batteryCommand(MacBattery(level: 57, pluggedIn: true, charging: true, charged: false), over: before)
                == "dumpsys battery set ac 1 && dumpsys battery set status 2")
        #expect(MacState.batteryCommand(before, over: before) == nil)
    }

    @Test func aMacWithoutABatteryLeavesAndroidsOwn() {
        #expect(MacState.batteryCommand(nil, over: nil) == "dumpsys battery reset")
        #expect(MacState.batteryCommand(nil, over: MacBattery(level: 5, pluggedIn: false, charging: false, charged: false))
                == "dumpsys battery reset")
    }

    // MARK: Languages

    @Test func theMacsLanguagesAsAndroidTags() {
        #expect(MacState.androidLanguages(["en-ID", "id-ID"]) == "en-ID,id-ID")
        #expect(MacState.androidLanguages(["zh-Hans-CN", "en_GB", "EN-gb"]) == "zh-Hans-CN,en-GB")
        #expect(MacState.androidLanguages(["en-US; reboot", "'", "", "e", "id"]) == "id")
        #expect(MacState.androidLanguages([]) == nil)
        #expect(MacState.androidLanguages((1...12).map { "x\(Character(UnicodeScalar(96 + $0)!))" })?.split(separator: ",").count == 8)
    }

    @Test func audioFocusRunsTheHelperAsAndroidsSystemUser() {
        #expect(MacState.audioFocusCommand
                == "su 1000 sh -c 'CLASSPATH=/data/local/tmp/avo-macstate.jar app_process / com.avodroid.macstate.Main audiofocus'")
        #expect(MacState.audioFocusQuery == "settings get system multi_audio_focus_enabled")
    }

    @Test func focusDisplayRunsTheHelperAsTheShellUser() {
        #expect(MacState.focusDisplayCommand(3)
                == "CLASSPATH=/data/local/tmp/avo-macstate.jar app_process / com.avodroid.macstate.Main focus-display 3")
    }

    @Test func languagesCommandRunsTheHelper() {
        #expect(MacState.languagesCommand(nil)
                == "CLASSPATH=/data/local/tmp/avo-macstate.jar app_process / com.avodroid.macstate.Main locales")
        #expect(MacState.languagesCommand("en-ID,id-ID")
                == "CLASSPATH=/data/local/tmp/avo-macstate.jar app_process / com.avodroid.macstate.Main locales en-ID,id-ID")
        #expect(MacState.parseLanguages("locales en-ID,id-ID\n") == "en-ID,id-ID")
        #expect(MacState.parseLanguages("WARNING: linker: something\nlocales en-US\n") == "en-US")
        #expect(MacState.parseLanguages("Exception in thread main\n") == nil)
    }

    @Test func languageSyncSetting() {
        let sync = MacState.LanguageSync(mac: "en-ID,id-ID", android: "en-ID,id-ID")
        #expect(MacState.LanguageSync(setting: sync.settingValue + "\n") == sync)
        #expect(MacState.LanguageSync(setting: "id-ID|") == MacState.LanguageSync(mac: "id-ID", android: ""))
        #expect(MacState.LanguageSync(setting: "null\n") == nil)
        #expect(MacState.LanguageSync(setting: "") == nil)
    }

    @Test func aFreshAndroidTakesTheMacsLanguages() {
        let plan = MacState.languagePlan(mac: "id-ID", android: "en-US", chosenInAndroid: false, last: nil)
        #expect(plan == MacState.LanguagePlan(apply: true, remember: nil))
    }

    @Test func languagesSomeoneChoseInAndroidStay() {
        let plan = MacState.languagePlan(mac: "id-ID", android: "ja-JP", chosenInAndroid: true, last: nil)
        #expect(plan == MacState.LanguagePlan(apply: false, remember: MacState.LanguageSync(mac: "id-ID", android: "")))
        // Decided once: the same Mac languages are not reconsidered.
        let again = MacState.languagePlan(mac: "id-ID", android: "ja-JP", chosenInAndroid: true, last: plan.remember)
        #expect(again == MacState.LanguagePlan(apply: false, remember: nil))
    }

    @Test func androidFollowsTheMacWhileItHasWhatAvoSet() {
        let last = MacState.LanguageSync(mac: "en-ID,id-ID", android: "en-ID,id-ID")
        #expect(MacState.languagePlan(mac: "id-ID", android: "en-ID,id-ID", chosenInAndroid: true, last: last)
                == MacState.LanguagePlan(apply: true, remember: nil))
    }

    @Test func androidLanguagesChangedSinceAvoSetThemStay() {
        let last = MacState.LanguageSync(mac: "en-ID,id-ID", android: "en-ID,id-ID")
        #expect(MacState.languagePlan(mac: "id-ID", android: "ja-JP", chosenInAndroid: true, last: last)
                == MacState.LanguagePlan(apply: false, remember: MacState.LanguageSync(mac: "id-ID", android: "en-ID,id-ID")))
        // Every boot with the same Mac languages: nothing to do.
        let unchanged = MacState.LanguageSync(mac: "id-ID", android: "id-ID")
        #expect(MacState.languagePlan(mac: "id-ID", android: "ja-JP", chosenInAndroid: true, last: unchanged)
                == MacState.LanguagePlan(apply: false, remember: nil))
    }

    @Test func languagesAlreadyInStepAreRemembered() {
        #expect(MacState.languagePlan(mac: "id-ID", android: "id-ID", chosenInAndroid: true, last: nil)
                == MacState.LanguagePlan(apply: false, remember: MacState.LanguageSync(mac: "id-ID", android: "id-ID")))
        let last = MacState.LanguageSync(mac: "id-ID", android: "id-ID")
        #expect(MacState.languagePlan(mac: "id-ID", android: "id-ID", chosenInAndroid: true, last: last)
                == MacState.LanguagePlan(apply: false, remember: nil))
    }

    @Test func theImagesDefaultLanguageIsNobodysChoice() {
        #expect(!MacState.languagesChosen(android: "en-US", persisted: "\n", productDefault: "en-US\n"))
        #expect(!MacState.languagesChosen(android: "en-US", persisted: "en-US\n", productDefault: "en-US\n"))
        #expect(MacState.languagesChosen(android: "ja-JP", persisted: "ja-JP\n", productDefault: "en-US\n"))
        #expect(MacState.languagesChosen(android: "ja-JP", persisted: "ja-JP\n", productDefault: ""))
    }

    // MARK: Helper

    @Test func helperJarIsADexJar() throws {
        let jar = try #require(Data(base64Encoded: MacStateHelper.jar))
        #expect(jar.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        #expect(String(decoding: jar, as: UTF8.self).contains("classes.dex"))
    }
}
