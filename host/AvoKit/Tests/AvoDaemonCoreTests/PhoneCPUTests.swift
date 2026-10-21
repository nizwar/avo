import AvoKit
import Foundation
import Testing
@testable import AvoDaemonCore

/// The CPU avo-vmm presents (`--cpu-clusters`, cpu.rs) when "Emulate this
/// phone's hardware" is on.
@Suite struct PhoneCPUTests {
    /// On, avo-vmm gets the profile's CPU for Android's cores; off, or for a
    /// profile without one, the Mac's.
    @Test func emulationPresentsThePhonesCPU() {
        let paths = AvoPaths(home: URL(filePath: "/Users/u"), temporaryDirectory: URL(filePath: "/tmp/T"))
        let image = CuttlefishImage.androidImage(at: URL(filePath: "/img"))
        let cpu = DeviceHardware.CPU(clusters: [
            .init(cores: 6, implementer: 0x51, part: 0x001, variant: 3, revision: 1, maxFreqKHz: 3_532_800, minFreqKHz: 384_000),
            .init(cores: 2, implementer: 0x51, part: 0x001, variant: 4, revision: 1, maxFreqKHz: 4_320_000, minFreqKHz: 1_017_600),
        ])
        let phone = DeviceProfile(id: "p", name: "P", properties: [:], hardware: DeviceHardware(cpu: cpu))
        var config = VMConfig()
        config.cpuCount = 8
        func arguments() -> [String] {
            VMMEngine.arguments(images: URL(filePath: "/img"),
                                launch: EngineLaunch(config: config, paths: paths, image: image, bootConfigDisk: URL(filePath: "/c"), profile: phone))
        }
        let plain = arguments()
        #expect(!plain.contains("--cpu-clusters"))
        config.emulateHardware = true
        #expect(arguments() == plain + ["--cpu-clusters", "6x513f0011@384000-3532800,2x514f0011@1017600-4320000"])
        config.cpuCount = 4
        #expect(arguments().suffix(2) == ["--cpu-clusters", "2x513f0011@384000-3532800,2x514f0011@1017600-4320000"])
    }
}
