import Foundation
import Observation

/// Live system-RAM gauge for the header: samples mach host statistics every 2s.
/// "Used" is computed the way Activity Monitor reads it - active + wired +
/// compressed pages - so the percentage matches what the user expects.
@MainActor @Observable
final class RAMMonitor {
    private(set) var usedFraction: Double = 0
    private(set) var usedGB: Double = 0
    /// Rolling usage history (0…1) for the RAM panel's sparkline.
    private(set) var history: [Double] = []
    let totalGB: Double = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    private var timer: Timer?

    init() {
        sample()
        let t = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let page = Double(getpagesize())   // fn, not the mutable global (Swift 6 concurrency)
        let used = (Double(stats.active_count) + Double(stats.wire_count)
                    + Double(stats.compressor_page_count)) * page
        usedGB = used / 1_073_741_824
        usedFraction = totalGB > 0 ? min(1, usedGB / totalGB) : 0
        history.append(usedFraction)
        if history.count > 40 { history.removeFirst(history.count - 40) }
    }
}
