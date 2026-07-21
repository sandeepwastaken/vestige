import Darwin
import Foundation
import Observation

/// This process's Mach task port.
///
/// The usual spelling, `mach_task_self_`, is a mutable global that Swift 6
/// rejects reading as shared mutable state. `task_self_trap()` is the syscall
/// that populates it, and being a function carries no such restriction — same
/// value, no concurrency violation.
private var currentTask: mach_port_t { task_self_trap() }

/// Vestige's own resource usage, sampled for the menu bar panel.
///
/// A replay buffer runs all session, so "what is this costing me?" is a fair
/// question to ask before trusting a capture tool while gaming. Everything here
/// measures *this process only*, not the system.
///
/// GPU usage is deliberately absent: macOS exposes no public per-process GPU
/// API, and the private IOKit statistics are undocumented and unreliable across
/// vendors. The panel reports whether the hardware encoder is in use instead,
/// which is what the GPU figure was really standing in for.
@MainActor
@Observable
final class ResourceMonitor {
    struct Sample: Equatable, Sendable {
        var cpuPercent: Double = 0
        var memoryBytes: UInt64 = 0
        var diskBytesPerSecond: Double = 0
    }

    private(set) var sample = Sample()

    private var pollTask: Task<Void, Never>?
    private var lastCPUTime: Double?
    private var lastDiskBytes: UInt64?
    private var lastSampledAt: Date?

    /// Begins sampling. Driven by the panel's lifecycle, so nothing runs while
    /// the UI is closed — a monitor that costs measurable resources to display
    /// resource usage would be self-defeating.
    func start(interval: Duration = .seconds(1)) {
        guard pollTask == nil else { return }

        // Prime the counters so the first visible reading is a real interval
        // rather than an average since process launch.
        lastCPUTime = Self.processCPUTime()
        lastDiskBytes = Self.processDiskBytes()
        lastSampledAt = .now

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func refresh() {
        let now = Date()
        let elapsed = lastSampledAt.map { now.timeIntervalSince($0) } ?? 1
        lastSampledAt = now
        guard elapsed > 0 else { return }

        var next = Sample()

        if let cpuTime = Self.processCPUTime() {
            if let previous = lastCPUTime {
                next.cpuPercent = max(0, (cpuTime - previous) / elapsed * 100)
            }
            lastCPUTime = cpuTime
        }

        next.memoryBytes = Self.processMemoryFootprint() ?? sample.memoryBytes

        if let diskBytes = Self.processDiskBytes() {
            if let previous = lastDiskBytes, diskBytes >= previous {
                next.diskBytesPerSecond = Double(diskBytes - previous) / elapsed
            }
            lastDiskBytes = diskBytes
        }

        sample = next
    }

    // MARK: - Measurement

    /// Total CPU seconds consumed by every thread in this process.
    private static func processCPUTime() -> Double? {
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size)

        let userAndSystem = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(currentTask, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard userAndSystem == KERN_SUCCESS else { return nil }

        let live = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000

        // Threads that have already exited are accounted separately; without
        // them the figure drops every time a worker finishes.
        var basic = task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size / MemoryLayout<natural_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(currentTask, task_flavor_t(TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        guard basicResult == KERN_SUCCESS else { return live }

        let terminated = Double(basic.user_time.seconds) + Double(basic.user_time.microseconds) / 1_000_000
            + Double(basic.system_time.seconds) + Double(basic.system_time.microseconds) / 1_000_000

        return live + terminated
    }

    /// Physical footprint — the same figure Activity Monitor shows as "Memory".
    private static func processMemoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(currentTask, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// Bytes this process has read and written, for the throughput figure.
    private static func processDiskBytes() -> UInt64? {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return nil }
        return usage.ri_diskio_bytesread + usage.ri_diskio_byteswritten
    }
}
