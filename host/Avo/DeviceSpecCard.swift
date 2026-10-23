import AvoKit
import SwiftUI

/// The hardware a phone profile reports when "Emulate this phone's hardware"
/// is on: SoC, CPU, GPU, memory and screen, as form rows under the checkbox.
/// It only shows what the profile actually sets, so a profile with just a SoC
/// shows one row. The CPU is the phone's for Android's `vcpus` cores
/// (`DeviceHardware.CPU.fitted(to:)`), and the memory what Android gets
/// (`androidMemoryMiB`, the phone's as far as the Mac allows), as apps read them.
struct DeviceSpecCard: View {
    let hardware: DeviceHardware
    let display: DeviceProfile.Display?
    let vcpus: Int
    let androidMemoryMiB: Int

    var body: some View {
        Group {
            if let soc = hardware.soc {
                LabeledContent("Chipset") {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(verbatim: "\(soc.manufacturer) \(soc.model)")
                        if let name = soc.buildHardware {
                            Text("Hardware “\(name)”").foregroundStyle(Haze.textTertiary).font(.mona(11.5))
                        }
                    }
                }
            }
            if let cpu = hardware.cpu?.fitted(to: vcpus), !cpu.clusters.isEmpty {
                LabeledContent("CPU") {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(cpu.totalCores) cores")
                        Text(Self.cpuSummary(cpu)).foregroundStyle(Haze.textTertiary).font(.mona(11.5))
                    }
                }
            }
            if let gpu = hardware.gpu, let name = gpu.glRenderer ?? gpu.vkName {
                LabeledContent("GPU", value: name)
            }
            if let phoneGB = hardware.memoryGB {
                LabeledContent("Memory") {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(phoneGB) GB")
                        if androidMemoryMiB != phoneGB * 1024 {
                            Text("This Mac gives Android \(Self.gigabytes(androidMemoryMiB)) GB")
                                .foregroundStyle(Haze.textTertiary).font(.mona(11.5))
                        }
                    }
                }
            }
            if let display {
                LabeledContent("Screen", value: "\(display.width) × \(display.height), \(display.dpi) dpi")
            }
        }
        .monospacedDigit()
    }

    /// "12" or "7.5": whole gigabytes without a fraction.
    static func gigabytes(_ mebibytes: Int) -> String {
        (Double(mebibytes) / 1024).formatted(.number.precision(.fractionLength(0...1)))
    }

    /// "1× Cortex-X4 + 5× Cortex-A720 + 2× Cortex-A520 · up to 3.3 GHz".
    static func cpuSummary(_ cpu: DeviceHardware.CPU) -> String {
        let parts = cpu.clusters.map { "\($0.cores)× \(coreName($0.implementer, $0.part))" }
        let topKHz = cpu.clusters.compactMap(\.maxFreqKHz).max()
        let clock = topKHz.map { String(format: " · up to %.1f GHz", Double($0) / 1_000_000) } ?? ""
        return parts.joined(separator: " + ") + clock
    }

    /// The marketing name for an ARM (implementer 0x41) or Qualcomm (0x51)
    /// core from its MIDR part number; otherwise the raw ids, so an unknown
    /// core still reads.
    static func coreName(_ implementer: Int, _ part: Int) -> String {
        if implementer == 0x41, let name = Self.armCores[part] { return name }
        if implementer == 0x51, let name = Self.qualcommCores[part] { return name }
        return String(format: "0x%02X:0x%03X", implementer, part)
    }

    static let armCores: [Int: String] = [
        0xD03: "Cortex-A53", 0xD05: "Cortex-A55", 0xD09: "Cortex-A73", 0xD0A: "Cortex-A75",
        0xD0B: "Cortex-A76", 0xD0D: "Cortex-A77", 0xD41: "Cortex-A78",
        0xD44: "Cortex-X1", 0xD46: "Cortex-A510", 0xD47: "Cortex-A710", 0xD48: "Cortex-X2",
        0xD4D: "Cortex-A715", 0xD4E: "Cortex-X3", 0xD80: "Cortex-A520", 0xD81: "Cortex-A720",
        0xD82: "Cortex-X4", 0xD84: "Cortex-A725", 0xD85: "Cortex-X925",
    ]

    static let qualcommCores: [Int: String] = [
        0x001: "Oryon", 0x002: "Oryon",
        0x800: "Kryo Gold", 0x801: "Kryo Silver", 0x802: "Kryo Gold", 0x803: "Kryo Silver",
        0x804: "Kryo Gold", 0x805: "Kryo Silver",
    ]
}
