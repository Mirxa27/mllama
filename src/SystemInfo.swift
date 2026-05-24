import Foundation
import Darwin
import Darwin.Mach
import Metal
import SwiftUI

// MARK: - Hardware snapshot (immutable, captured once at startup)

struct HardwareInfo: Hashable, Codable {
    var chipName: String              // e.g. "Apple M3 Max"
    var chipVariant: ChipVariant      // parsed family + tier
    var totalRamGB: Double            // e.g. 64.0
    var performanceCores: Int
    var efficiencyCores: Int
    var totalCores: Int
    var gpuName: String               // Metal-reported, e.g. "Apple M3 Max"
    var gpuCores: Int                 // best-effort from chip variant
    var hasMetal: Bool
    var diskFreeGB: Double            // free space on /

    var ramTier: RamTier { RamTier.forGB(totalRamGB) }
    var summary: String {
        "\(chipName) · \(Int(totalRamGB)) GB RAM · \(gpuCores)c GPU"
    }
    var shortSummary: String {
        "\(chipVariant.shortName) · \(Int(totalRamGB)) GB"
    }
}

enum ChipVariant: String, Codable, Hashable {
    case m1, m1Pro, m1Max, m1Ultra
    case m2, m2Pro, m2Max, m2Ultra
    case m3, m3Pro, m3Max, m3Ultra
    case m4, m4Pro, m4Max
    case unknown

    var shortName: String {
        switch self {
        case .m1:      return "M1"
        case .m1Pro:   return "M1 Pro"
        case .m1Max:   return "M1 Max"
        case .m1Ultra: return "M1 Ultra"
        case .m2:      return "M2"
        case .m2Pro:   return "M2 Pro"
        case .m2Max:   return "M2 Max"
        case .m2Ultra: return "M2 Ultra"
        case .m3:      return "M3"
        case .m3Pro:   return "M3 Pro"
        case .m3Max:   return "M3 Max"
        case .m3Ultra: return "M3 Ultra"
        case .m4:      return "M4"
        case .m4Pro:   return "M4 Pro"
        case .m4Max:   return "M4 Max"
        case .unknown: return "Unknown"
        }
    }

    /// Approximate Apple-published GPU core counts. Some SKUs have binned
    /// variants (e.g. M3 Max ships with 30 or 40 cores); we pick the max as a
    /// best-effort estimate. Unknown chips return -1 (UI should hide the count).
    var approxGPUCores: Int {
        switch self {
        case .m1:      return 8
        case .m1Pro:   return 16
        case .m1Max:   return 32
        case .m1Ultra: return 64
        case .m2:      return 10
        case .m2Pro:   return 19
        case .m2Max:   return 38
        case .m2Ultra: return 76
        case .m3:      return 10
        case .m3Pro:   return 18
        case .m3Max:   return 40
        case .m3Ultra: return 80
        case .m4:      return 10
        case .m4Pro:   return 20
        case .m4Max:   return 40
        case .unknown: return -1
        }
    }

    static func parse(_ brand: String) -> ChipVariant {
        let s = brand.lowercased()
        // Order matters: longer matches first
        if s.contains("m4 max")   { return .m4Max }
        if s.contains("m4 pro")   { return .m4Pro }
        if s.contains("m4")       { return .m4 }
        if s.contains("m3 ultra") { return .m3Ultra }
        if s.contains("m3 max")   { return .m3Max }
        if s.contains("m3 pro")   { return .m3Pro }
        if s.contains("m3")       { return .m3 }
        if s.contains("m2 ultra") { return .m2Ultra }
        if s.contains("m2 max")   { return .m2Max }
        if s.contains("m2 pro")   { return .m2Pro }
        if s.contains("m2")       { return .m2 }
        if s.contains("m1 ultra") { return .m1Ultra }
        if s.contains("m1 max")   { return .m1Max }
        if s.contains("m1 pro")   { return .m1Pro }
        if s.contains("m1")       { return .m1 }
        return .unknown
    }
}

/// Buckets used by the model recommender. Anything ≤8GB is "small", 9-16 is
/// "mid", 17-36 is "large", 37+ is "xl".
enum RamTier: String, Codable, Hashable, CaseIterable, Identifiable {
    case small, mid, large, xl
    var id: String { rawValue }

    static func forGB(_ g: Double) -> RamTier {
        switch g {
        case ..<9:    return .small
        case ..<17:   return .mid
        case ..<37:   return .large
        default:      return .xl
        }
    }
    var label: String {
        switch self {
        case .small: return "8 GB · light workloads"
        case .mid:   return "16 GB · everyday"
        case .large: return "32 GB · prosumer"
        case .xl:    return "64 GB+ · workstation"
        }
    }
}

// MARK: - Live resource sample

struct ResourceSample: Hashable {
    var ramUsedGB: Double
    var ramAvailableGB: Double
    var cpuPercent: Double            // 0...100, averaged across cores
    var swapUsedGB: Double
    var diskFreeGB: Double
    var sampledAt: Date

    static let zero = ResourceSample(ramUsedGB: 0, ramAvailableGB: 0, cpuPercent: 0,
                                     swapUsedGB: 0, diskFreeGB: 0, sampledAt: Date())
}

// MARK: - SystemInfo (one-shot hardware probe)

enum SystemInfo {
    static func detect() -> HardwareInfo {
        let chipBrand = readCPUBrand() ?? "Apple Silicon"
        let variant = ChipVariant.parse(chipBrand)
        let totalRam = readSysctl_int64("hw.memsize") ?? 0
        let totalRamGB = Double(totalRam) / 1_073_741_824.0
        let perfCores = readSysctl_int("hw.perflevel0.physicalcpu") ?? 0
        let effCores  = readSysctl_int("hw.perflevel1.physicalcpu") ?? 0
        let totalCores = readSysctl_int("hw.physicalcpu") ?? (perfCores + effCores)
        let device = MTLCreateSystemDefaultDevice()
        let gpuName = device?.name ?? chipBrand
        let diskFree = diskFreeGB(at: "/")

        return HardwareInfo(
            chipName: chipBrand,
            chipVariant: variant,
            totalRamGB: totalRamGB,
            performanceCores: perfCores,
            efficiencyCores: effCores,
            totalCores: totalCores,
            gpuName: gpuName,
            gpuCores: variant.approxGPUCores,
            hasMetal: device != nil,
            diskFreeGB: diskFree
        )
    }

    // MARK: sysctl helpers

    static func readCPUBrand() -> String? {
        var size: size_t = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static func readSysctl_int64(_ name: String) -> Int64? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        let rc = sysctlbyname(name, &v, &size, nil, 0)
        return rc == 0 ? v : nil
    }

    static func readSysctl_int(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rc = sysctlbyname(name, &v, &size, nil, 0)
        return rc == 0 ? Int(v) : nil
    }

    static func diskFreeGB(at path: String) -> Double {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let vals = try? url.resourceValues(forKeys: keys) else { return 0 }
        if let i = vals.volumeAvailableCapacityForImportantUsage {
            return Double(i) / 1_073_741_824.0
        }
        if let i = vals.volumeAvailableCapacity {
            return Double(i) / 1_073_741_824.0
        }
        return 0
    }
}

// MARK: - Resource monitor (live polling)

@MainActor
final class ResourceMonitor: ObservableObject {
    @Published private(set) var sample: ResourceSample = .zero
    @Published private(set) var hardware: HardwareInfo
    @Published var running: Bool = false

    private var pollTask: Task<Void, Never>?
    private var lastCPUTicks: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)?
    private let pollInterval: TimeInterval = 2.0

    init() {
        self.hardware = SystemInfo.detect()
    }

    func start() {
        if running { return }
        running = true
        pollTask = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        running = false
        pollTask?.cancel()
        pollTask = nil
    }

    private func loop() async {
        while running, !Task.isCancelled {
            // sampleNow is a couple of sysctl/host_statistics syscalls — fast
            // enough to run on the main actor every 2s without dispatching off.
            var s = Self.sampleNow()
            s.cpuPercent = Self.cpuSinceLast(&self.lastCPUTicks)
            s.diskFreeGB = SystemInfo.diskFreeGB(at: "/")
            self.sample = s
            self.hardware = HardwareInfo(
                chipName: self.hardware.chipName,
                chipVariant: self.hardware.chipVariant,
                totalRamGB: self.hardware.totalRamGB,
                performanceCores: self.hardware.performanceCores,
                efficiencyCores: self.hardware.efficiencyCores,
                totalCores: self.hardware.totalCores,
                gpuName: self.hardware.gpuName,
                gpuCores: self.hardware.gpuCores,
                hasMetal: self.hardware.hasMetal,
                diskFreeGB: s.diskFreeGB
            )
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    // MARK: Sampling

    /// Read VM stats and produce a ResourceSample. CPU% is filled in by the
    /// caller (it requires a prior sample to diff against).
    static func sampleNow() -> ResourceSample {
        let pageSize = Int(vm_kernel_page_size)
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                host_statistics64(host, HOST_VM_INFO64, p, &count)
            }
        }
        if rc != KERN_SUCCESS {
            return ResourceSample(ramUsedGB: 0, ramAvailableGB: 0, cpuPercent: 0,
                                  swapUsedGB: 0, diskFreeGB: 0, sampledAt: Date())
        }
        let active     = UInt64(info.active_count) * UInt64(pageSize)
        let wired      = UInt64(info.wire_count) * UInt64(pageSize)
        let compressed = UInt64(info.compressor_page_count) * UInt64(pageSize)
        let free       = UInt64(info.free_count) * UInt64(pageSize)
        // macOS "Used" memory ~ active + wired + compressed (ignore inactive/purgeable
        // for simplicity).
        let used = active + wired + compressed
        let avail = free + UInt64(info.inactive_count) * UInt64(pageSize)
        // Swap
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        let swapUsed = swap.xsu_used
        return ResourceSample(
            ramUsedGB: Double(used) / 1_073_741_824.0,
            ramAvailableGB: Double(avail) / 1_073_741_824.0,
            cpuPercent: 0,  // filled in by caller
            swapUsedGB: Double(swapUsed) / 1_073_741_824.0,
            diskFreeGB: 0,  // filled in by caller
            sampledAt: Date()
        )
    }

    /// Compute average CPU usage% across all cores since the last call.
    static func cpuSinceLast(_ prev: inout (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)?) -> Double {
        var cpuLoad = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        let rc = withUnsafeMutablePointer(to: &cpuLoad) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                host_statistics(host, HOST_CPU_LOAD_INFO, p, &count)
            }
        }
        guard rc == KERN_SUCCESS else { return 0 }
        let user = UInt64(cpuLoad.cpu_ticks.0)
        let sys  = UInt64(cpuLoad.cpu_ticks.1)
        let idle = UInt64(cpuLoad.cpu_ticks.2)
        let nice = UInt64(cpuLoad.cpu_ticks.3)
        defer { prev = (user, sys, idle, nice) }
        guard let p = prev else { return 0 }
        let dUser = user &- p.user
        let dSys  = sys  &- p.sys
        let dIdle = idle &- p.idle
        let dNice = nice &- p.nice
        let total = Double(dUser + dSys + dIdle + dNice)
        guard total > 0 else { return 0 }
        let busy = Double(dUser + dSys + dNice)
        return (busy / total) * 100.0
    }
}
