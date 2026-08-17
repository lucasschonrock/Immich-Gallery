//
//  DiagnosticsOverlay.swift
//  Immich Gallery
//
//  Created by mensadi-labs on 2026-08-12.
//

import Combine
import Darwin
import SwiftUI

/// A single app-wide sampler keeps session peaks stable when a full-screen
/// presentation needs its own overlay. It runs only while diagnostics are on.
@MainActor
final class DiagnosticsMonitor: ObservableObject {
    static let shared = DiagnosticsMonitor()

    private static let sampleInterval: TimeInterval = 1.0

    struct Sample: Equatable {
        var performance = PerformanceDiagnostics.Snapshot()
        var cpuPercent = 0.0
        var footprintMB = 0.0
        var peakFootprintMB = 0.0
        var networkBytesPerSecond = 0.0
        var currentMainTimerDelay = 0.0
        var peakMainTimerDelay = 0.0
    }

    @Published private(set) var sample = Sample()

    private var ticker: AnyCancellable?
    private var lastSampleUptime: TimeInterval?
    private var lastCPUTime: TimeInterval?
    private var lastResponseBytes: Int64?

    private init() {
        setEnabled(UserDefaults.standard.bool(forKey: UserDefaultsKeys.showDiagnosticsOverlay))
    }

    func setEnabled(_ enabled: Bool) {
        PerformanceDiagnostics.setCollectionEnabled(enabled)

        if enabled {
            guard ticker == nil else { return }
            establishPerformanceBaseline()
            ticker = Timer.publish(every: Self.sampleInterval, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    self?.samplePerformance()
                }
        } else {
            ticker?.cancel()
            ticker = nil
            lastSampleUptime = nil
            lastCPUTime = nil
            lastResponseBytes = nil
        }
    }

    private func establishPerformanceBaseline() {
        let diagnostics = PerformanceDiagnostics.snapshot()
        lastSampleUptime = ProcessInfo.processInfo.systemUptime
        lastCPUTime = Self.processCPUTime()
        lastResponseBytes = diagnostics.totalResponseBytes
        updateFootprintSample()
        sample.performance = diagnostics
    }

    private func samplePerformance() {
        let now = ProcessInfo.processInfo.systemUptime
        let cpuTime = Self.processCPUTime()
        let diagnostics = PerformanceDiagnostics.snapshot()

        if let previousUptime = lastSampleUptime {
            let elapsed = max(0.001, now - previousUptime)

            // A long gap means the app or run loop was suspended, not that the UI
            // stalled for that entire duration. Re-baseline instead of recording
            // a misleading peak after returning to the foreground.
            if elapsed <= Self.sampleInterval * 3 {
                sample.currentMainTimerDelay = max(0, elapsed - Self.sampleInterval)
                sample.peakMainTimerDelay = max(sample.peakMainTimerDelay, sample.currentMainTimerDelay)

                if let previousCPUTime = lastCPUTime {
                    sample.cpuPercent = max(0, (cpuTime - previousCPUTime) / elapsed * 100)
                }
                if let previousResponseBytes = lastResponseBytes {
                    sample.networkBytesPerSecond = Double(max(0, diagnostics.totalResponseBytes - previousResponseBytes)) / elapsed
                }
            } else {
                sample.currentMainTimerDelay = 0
                sample.cpuPercent = 0
                sample.networkBytesPerSecond = 0
            }
        }

        lastSampleUptime = now
        lastCPUTime = cpuTime
        lastResponseBytes = diagnostics.totalResponseBytes
        updateFootprintSample()
        sample.performance = diagnostics
    }

    private func updateFootprintSample() {
        let megabytes = Double(Self.processPhysicalFootprintBytes()) / 1_048_576
        sample.footprintMB = megabytes
        sample.peakFootprintMB = max(sample.peakFootprintMB, megabytes)
    }

    /// Physical footprint is the closest available process metric to Xcode's
    /// Memory Gauge and is more representative of memory pressure than RSS.
    private static func processPhysicalFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private static func processCPUTime() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return timevalSeconds(usage.ru_utime) + timevalSeconds(usage.ru_stime)
    }

    private static func timevalSeconds(_ value: timeval) -> TimeInterval {
        TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000
    }
}

/// Optional field diagnostics for performance reports from devices that are not
/// attached to Xcode. The shared monitor publishes at most once per second.
struct DiagnosticsOverlay: View {
    @ObservedObject private var monitor = DiagnosticsMonitor.shared

    var body: some View {
        let sample = monitor.sample
        let performance = sample.performance

        VStack(alignment: .leading, spacing: 2) {
            Text("DIAGNOSTICS")
            Text("timeline visible \(performance.visibleTimelineAssets)  loaded \(performance.loadedTimelineAssets)")
            Text("months \(performance.loadedTimelineMonths)/\(performance.totalTimelineMonths)  largest \(performance.largestLoadedMonth)")
            Text("paging \(performance.isTimelinePaging ? "loading" : "idle")")
            Text("network \(performance.activeNetworkRequests) active  \(Self.byteRate(sample.networkBytesPerSecond))")
            Text("cpu \(sample.cpuPercent, specifier: "%.0f")%  UI delay \(sample.currentMainTimerDelay, specifier: "%.1f")s peak \(sample.peakMainTimerDelay, specifier: "%.1f")s")
            Text("footprint \(sample.footprintMB, specifier: "%.0f") MB  peak \(sample.peakFootprintMB, specifier: "%.0f") MB")
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundColor(.white)
        .padding(10)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .padding(40)
    }

    private static func byteRate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        if bytesPerSecond >= 1_000 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}

/// Shows the overlay only when the setting is on. The condition lives INSIDE the
/// always-applied overlay (an empty overlay builder costs nothing) rather than
/// branching around `content`: an if/else here would give the two branches
/// different view identities, so flipping the toggle would reset all state in
/// the subtree it wraps — for ContentView, the entire main interface.
private struct DiagnosticsOverlayModifier: ViewModifier {
    @AppStorage(UserDefaultsKeys.showDiagnosticsOverlay) private var showDiagnosticsOverlay = false
    @ObservedObject private var monitor = DiagnosticsMonitor.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if showDiagnosticsOverlay {
                DiagnosticsOverlay()
                    // Must stay invisible to the focus engine it is measuring.
                    .allowsHitTesting(false)
                    .focusable(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: showDiagnosticsOverlay) { _, isEnabled in
            monitor.setEnabled(isEnabled)
        }
    }
}

extension View {
    func diagnosticsOverlay() -> some View {
        modifier(DiagnosticsOverlayModifier())
    }
}
