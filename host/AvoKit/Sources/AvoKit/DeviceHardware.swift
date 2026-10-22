import Foundation

/// The hardware a device profile reports when "Emulate this phone's hardware"
/// is on (VMConfig.emulateHardware): the SoC, CPU and GPU an app reads when it
/// takes a code path for a chipset or a brand. It is for development — testing
/// a build's per-device behaviour without the device — and like the identity
/// it does not pass hardware attestation; Avo still states what it is
/// (`ro.boot.avo.*`, `com.avodroid.feature.MAC`), whichever profile is chosen.
///
/// The parts reach Android three ways: SoC facts as read-only properties
/// (`ro.soc.*`, `ro.board.platform`, `Build.BOARD`, vendor keys), the GPU
/// through Avo's GLES and Vulkan layers (`debug.avo.gl.*` and
/// `debug.avo.vk.*`, installed by `GuestGPUProfile`), and the CPU from the
/// engine (MIDR and the cpufreq tables, so `/proc/cpuinfo` and `/sys` agree).
/// The names and IDs
/// change; abilities (ABI, API level, extensions, limits) stay the real
/// hardware's, because changing them would stop apps loading or break drivers.
public struct DeviceHardware: Codable, Equatable, Sendable {
    public var soc: SoC?
    public var cpu: CPU?
    public var gpu: GPU?

    public init(soc: SoC? = nil, cpu: CPU? = nil, gpu: GPU? = nil) {
        self.soc = soc
        self.cpu = cpu
        self.gpu = gpu
    }

    /// The system-on-chip an app reads from `Build` and `getprop`.
    public struct SoC: Codable, Equatable, Sendable {
        /// `ro.soc.manufacturer` / `Build.SOC_MANUFACTURER` (e.g. "QTI", "Mediatek").
        public var manufacturer: String
        /// `ro.soc.model` / `Build.SOC_MODEL` (e.g. "SM8650", "MT6989").
        public var model: String
        /// `ro.board.platform`: the platform codename many SoC-detect
        /// libraries key on (e.g. "pineapple", "mt6989").
        public var platform: String?
        /// `ro.product.board` / `Build.BOARD` (e.g. "pineapple", "kalama").
        public var board: String?
        /// Extra read-only properties a chipset is known by, for the long tail
        /// of vendor checks: `ro.vendor.*`, `ro.board.*`, `ro.mediatek.*`,
        /// `ro.chipname`, `ro.hardware.chipname` only (validated). Never driver
        /// or security keys.
        public var properties: [String: String]?

        public init(manufacturer: String, model: String, platform: String? = nil,
                    board: String? = nil, properties: [String: String]? = nil) {
            self.manufacturer = manufacturer
            self.model = model
            self.platform = platform
            self.board = board
            self.properties = properties
        }
    }

    /// The CPU: each cluster's core model (an ARM MIDR) and count, and the
    /// per-cluster frequencies. The engine presents these (avo-vmm
    /// `--cpu-clusters`: each vCPU's `MIDR_EL1`, and the guest's
    /// `virtual-cpufreq` with a policy per cluster), so `/proc/cpuinfo` and
    /// `/sys/devices/system/cpu` match the phone for as many cores as Android
    /// has (`fitted(to:)`). The frequencies are names only: every vCPU still
    /// runs as fast as the Mac lets it.
    public struct CPU: Codable, Equatable, Sendable {
        public var clusters: [Cluster]

        public init(clusters: [Cluster]) {
            self.clusters = clusters
        }

        /// A set of identical cores (e.g. "1× Cortex-X4", "3× A720", "4× A520").
        public struct Cluster: Codable, Equatable, Sendable {
            public var cores: Int
            /// MIDR implementer byte: 0x41 ARM, 0x51 Qualcomm, 0x61 Apple.
            public var implementer: Int
            /// MIDR primary part number (e.g. 0xD4D Cortex-X4).
            public var part: Int
            public var variant: Int?
            public var revision: Int?
            /// Top of the cpufreq table, in kHz (e.g. 3300000 for 3.3 GHz).
            public var maxFreqKHz: Int?
            public var minFreqKHz: Int?

            public init(cores: Int, implementer: Int, part: Int, variant: Int? = nil,
                        revision: Int? = nil, maxFreqKHz: Int? = nil, minFreqKHz: Int? = nil) {
                self.cores = cores
                self.implementer = implementer
                self.part = part
                self.variant = variant
                self.revision = revision
                self.maxFreqKHz = maxFreqKHz
                self.minFreqKHz = minFreqKHz
            }

            /// `MIDR_EL1`: implementer, variant, architecture (0xF: see the ID
            /// registers), part and revision.
            public var midr: UInt32 {
                UInt32(implementer & 0xff) << 24 | UInt32((variant ?? 0) & 0xf) << 20 | 0xf << 16
                    | UInt32(part & 0xfff) << 4 | UInt32((revision ?? 0) & 0xf)
            }

            /// The MIDR avo-vmm presents: this one, but a Cortex-A53 before
            /// r0p3 as r0p4, its last revision. For the early ones Linux works
            /// around errata 826319, 827319, 824069 and 819472 by trapping
            /// every app's cache maintenance, which no Mac core needs.
            var presentedMIDR: UInt32 {
                guard implementer == 0x41, part == 0xD03, (variant ?? 0) == 0, (revision ?? 0) < 3 else { return midr }
                return midr & ~0xf | 4
            }

            /// A Cortex-A73: Linux's workaround for its erratum 858921 (every
            /// revision) traps the counter and takes clock_gettime out of the
            /// vDSO on every core, so avo-vmm presents no CPU for it.
            /// Qualcomm's A73-based cores report their own part (Kryo 2xx Gold:
            /// implementer 0x51, part 0x800).
            var trapsTheTimer: Bool { implementer == 0x41 && part == 0xD09 }
        }

        public var totalCores: Int { clusters.reduce(0) { $0 + $1.cores } }

        /// The lowest frequency a cluster without one gets, as most phones'
        /// little cores have.
        static let defaultMinFreqKHz = 300_000

        /// The clusters as Android numbers its CPUs, from the slowest (by top
        /// frequency, in the profile's order where equal), for `vcpus` vCPUs.
        /// With fewer vCPUs than the phone has cores, its slowest give way
        /// (every vCPU is as fast as the Mac's cores); with more, the slowest
        /// cluster grows.
        public func fitted(to vcpus: Int) -> CPU {
            let ordered = clusters.enumerated()
                .sorted { ($0.element.maxFreqKHz ?? 0, $0.offset) < ($1.element.maxFreqKHz ?? 0, $1.offset) }
                .map(\.element)
            guard vcpus > 0, !ordered.isEmpty else { return CPU(clusters: []) }
            var left = vcpus
            var kept: [Cluster] = []
            for var cluster in ordered.reversed() where left > 0 && cluster.cores > 0 {
                cluster.cores = min(cluster.cores, left)
                left -= cluster.cores
                kept.insert(cluster, at: 0)
            }
            if left > 0, !kept.isEmpty { kept[0].cores += left }
            return CPU(clusters: kept)
        }

        /// avo-vmm's `--cpu-clusters` for `vcpus` vCPUs: `CORESxMIDR@MIN-MAX`
        /// per cluster (`fitted(to:)`, frequencies in kHz). Nil when a
        /// cluster has no top frequency, or the CPU has a Cortex-A73
        /// (`trapsTheTimer`) among the cores Android gets.
        public func engineClusters(vcpus: Int) -> String? {
            let fit = fitted(to: vcpus)
            guard !fit.clusters.isEmpty else { return nil }
            var specs: [String] = []
            for cluster in fit.clusters {
                guard let top = cluster.maxFreqKHz, top > 1, !cluster.trapsTheTimer else { return nil }
                let low = cluster.minFreqKHz.flatMap { $0 > 0 && $0 < top ? $0 : nil } ?? min(Self.defaultMinFreqKHz, top / 2)
                specs.append("\(cluster.cores)x\(String(format: "%08x", cluster.presentedMIDR))@\(low)-\(top)")
            }
            return specs.joined(separator: ",")
        }
    }

    /// The GPU an app's own renderer reads. GLES strings and the Vulkan
    /// physical-device properties; Avo's layers answer with these for an
    /// app's own renderer only (the compositor, HWUI, WebView and ANGLE's own
    /// Vulkan instance keep the real GPU, so the screen still draws).
    /// Abilities stay the real GPU's.
    public struct GPU: Codable, Equatable, Sendable {
        /// `GL_VENDOR` (e.g. "Qualcomm").
        public var glVendor: String?
        /// `GL_RENDERER` (e.g. "Adreno (TM) 750").
        public var glRenderer: String?
        /// Appended after "OpenGL ES <major>.<minor> " in `GL_VERSION`.
        public var glVersion: String?
        /// `VkPhysicalDeviceProperties.deviceName`; falls back to `glRenderer`.
        public var vkName: String?
        /// `vendorID` (e.g. 0x5143 Qualcomm), `deviceID`, `driverVersion`.
        public var vkVendorID: Int?
        public var vkDeviceID: Int?
        public var vkDriverVersion: Int?
        /// `VkPhysicalDeviceDriverProperties`: `driverID` (a `VkDriverId`, e.g.
        /// 8 Qualcomm proprietary), `driverName`, `driverInfo`.
        public var vkDriverID: Int?
        public var vkDriverName: String?
        public var vkDriverInfo: String?

        public init(glVendor: String? = nil, glRenderer: String? = nil, glVersion: String? = nil,
                    vkName: String? = nil, vkVendorID: Int? = nil, vkDeviceID: Int? = nil,
                    vkDriverVersion: Int? = nil, vkDriverID: Int? = nil,
                    vkDriverName: String? = nil, vkDriverInfo: String? = nil) {
            self.glVendor = glVendor
            self.glRenderer = glRenderer
            self.glVersion = glVersion
            self.vkName = vkName
            self.vkVendorID = vkVendorID
            self.vkDeviceID = vkDeviceID
            self.vkDriverVersion = vkDriverVersion
            self.vkDriverID = vkDriverID
            self.vkDriverName = vkDriverName
            self.vkDriverInfo = vkDriverInfo
        }

        /// Whether the GPU layers have anything to report.
        public var isEmpty: Bool {
            glVendor == nil && glRenderer == nil && glVersion == nil && vkName == nil
                && vkVendorID == nil && vkDeviceID == nil && vkDriverVersion == nil
                && vkDriverID == nil && vkDriverName == nil && vkDriverInfo == nil
        }
    }

    // MARK: Properties applied at boot

    /// Prefixes an SoC's extra `properties` may use: vendor and board naming
    /// only, never drivers (`ro.hardware.*` beyond chipname) or security.
    static let socPropertyPrefixes = ["ro.vendor.", "ro.board.", "ro.mediatek."]
    static let socPropertyKeys: Set<String> = ["ro.chipname", "ro.hardware.chipname"]
    /// Words that make a key more than a name even under those prefixes:
    /// API levels (`ro.board.api_level`), ABIs, and security state.
    static let socPropertyDeniedWords = ["api_level", "sdk", "abi", "debuggable", "secure", "verified", "selinux"]

    /// Read-only SoC facts for the boot property file: `ro.soc.*`, the board
    /// and platform codenames, and the author's extra vendor keys. The GPU
    /// goes through `debug.avo.*` instead (`gpuProperties`).
    public func socProperties() -> [String: String] {
        guard let soc else { return [:] }
        var out = [
            "ro.soc.manufacturer": soc.manufacturer,
            "ro.soc.model": soc.model,
        ]
        if let platform = soc.platform { out["ro.board.platform"] = platform }
        if let board = soc.board { out["ro.product.board"] = board }
        for (key, value) in soc.properties ?? [:] { out[key] = value }
        return out
    }

    /// The Vulkan layer Avo installs (`GuestGPUProfile`): an app's own Vulkan.
    /// ANGLE's Vulkan instance, which draws GLES, keeps the real GPU.
    public static let vulkanLayer = "VK_LAYER_AVO_profile"

    /// The GLES layer Avo installs (`GuestGPUProfile`): an app's own
    /// `glGetString`, whichever library it calls through (ANGLE draws GLES, so
    /// without it `GL_RENDERER` says "ANGLE (...)").
    public static let glesLayer = "libGLES_avo_profile.so"

    /// The longest value Android keeps in a `debug.*` property (PROP_VALUE_MAX
    /// less the terminator); init drops a longer line from the property file.
    static let propertyValueMax = 91

    /// `debug.avo.gl.*` and `debug.avo.vk.*`: what the layers report.
    /// `vkName` falls back to the GLES renderer name. These are safe to set at
    /// first boot (nothing reads them until a layer loads); `debug.gles.layers`
    /// and `debug.vulkan.layers`, which load the layers, are NOT here — the
    /// daemon sets them only after installing the layer files
    /// (`GuestGPUProfile`), because naming a missing Vulkan layer system-wide
    /// at boot stops graphics services from starting.
    public func gpuProperties() -> [String: String] {
        guard let gpu, !gpu.isEmpty else { return [:] }
        var out: [String: String] = [:]
        func set(_ key: String, _ value: String?) { if let value { out[key] = value } }
        set("debug.avo.gl.vendor", gpu.glVendor)
        set("debug.avo.gl.renderer", gpu.glRenderer)
        set("debug.avo.gl.version", gpu.glVersion)
        set("debug.avo.vk.name", gpu.vkName ?? gpu.glRenderer)
        set("debug.avo.vk.driver_name", gpu.vkDriverName)
        set("debug.avo.vk.driver_info", gpu.vkDriverInfo)
        func setHex(_ key: String, _ value: Int?) { if let value { out[key] = "0x" + String(value, radix: 16) } }
        setHex("debug.avo.vk.vendor", gpu.vkVendorID)
        setHex("debug.avo.vk.device", gpu.vkDeviceID)
        setHex("debug.avo.vk.driver", gpu.vkDriverVersion)
        if let id = gpu.vkDriverID { out["debug.avo.vk.driver_id"] = "\(id)" }
        return out
    }

    /// Every property hardware emulation adds at boot (SoC + GPU). The CPU is
    /// the engine's, not a property. Merged after the identity, so a profile's
    /// own `ro.soc.*` is kept and these do not touch identity or Avo's markers.
    public func bootProperties() -> [String: String] {
        socProperties().merging(gpuProperties()) { first, _ in first }
    }

    // MARK: Validation

    public func validate() -> [String] {
        var problems: [String] = []
        if let soc {
            if soc.manufacturer.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("soc.manufacturer is empty") }
            if soc.model.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("soc.model is empty") }
            for (key, value) in (soc.properties ?? [:]).sorted(by: { $0.key < $1.key }) {
                let allowed = (Self.socPropertyKeys.contains(key) || Self.socPropertyPrefixes.contains(where: key.hasPrefix))
                    && !Self.socPropertyDeniedWords.contains(where: key.contains)
                if !allowed || DeviceProfile.forbiddenProperties.contains(key) {
                    problems.append("soc.properties \(key) is not an allowed hardware property")
                }
                if value.contains(where: \.isNewline) { problems.append("soc.properties \(key) contains a newline") }
            }
        }
        if let cpu {
            if cpu.clusters.isEmpty { problems.append("cpu has no clusters") }
            if cpu.totalCores < 1 || cpu.totalCores > 64 { problems.append("cpu core count out of range") }
            for (index, cluster) in cpu.clusters.enumerated() {
                if cluster.cores < 1 { problems.append("cpu cluster \(index) has no cores") }
                if !(0...0xff).contains(cluster.implementer) { problems.append("cpu cluster \(index) implementer out of range") }
                if !(0...0xfff).contains(cluster.part) { problems.append("cpu cluster \(index) part out of range") }
                if let variant = cluster.variant, !(0...0xf).contains(variant) {
                    problems.append("cpu cluster \(index) variant out of range")
                }
                if let revision = cluster.revision, !(0...0xf).contains(revision) {
                    problems.append("cpu cluster \(index) revision out of range")
                }
                if let max = cluster.maxFreqKHz, let min = cluster.minFreqKHz, min > max {
                    problems.append("cpu cluster \(index) min frequency above max")
                }
            }
        }
        if let gpu {
            for id in [gpu.vkVendorID, gpu.vkDeviceID, gpu.vkDriverVersion] where id != nil && id! < 0 {
                problems.append("gpu Vulkan IDs must not be negative")
            }
            let names: [(String, String?)] = [
                ("glVendor", gpu.glVendor), ("glRenderer", gpu.glRenderer), ("glVersion", gpu.glVersion),
                ("vkName", gpu.vkName), ("vkDriverName", gpu.vkDriverName), ("vkDriverInfo", gpu.vkDriverInfo),
            ]
            for (field, value) in names {
                guard let value else { continue }
                if value.utf8.count > Self.propertyValueMax {
                    problems.append("gpu.\(field) is longer than \(Self.propertyValueMax) bytes")
                }
                if value.contains(where: \.isNewline) { problems.append("gpu.\(field) contains a newline") }
            }
        }
        return problems
    }
}
