//
//  DiagnosticsOverlay.swift
//  Immich Gallery
//
//  Created by mensadi-labs on 2026-08-12.
//

import Combine
import Darwin
import SwiftUI

// TEMP DEBUG (remove with RenderStormStats): an on-screen version of the
// render-storm log. Attach with `.diagnosticsOverlay()` anywhere; it is off
// unless the user turns on "Diagnostics Overlay" in Settings, which lets a
// field reporter without a Mac photograph the numbers for us.
struct DiagnosticsOverlay: View {
    // Polling instead of observing: RenderStormStats is deliberately not an
    // ObservableObject, because a publisher that fired on every tick would
    // re-render this overlay thousands of times a second and become the very
    // render storm it is measuring.
    private static let sampleInterval: TimeInterval = 1.0

    @State private var snapshot = RenderStormStats.Snapshot()
    @State private var performance = PerformanceDiagnostics.Snapshot()
    @State private var cpuPercent = 0.0
    @State private var residentMemoryMB = 0.0
    @State private var peakResidentMemoryMB = 0.0
    @State private var networkBytesPerSecond = 0.0
    @State private var currentMainThreadStall = 0.0
    @State private var peakMainThreadStall = 0.0
    @State private var lastSampleUptime: TimeInterval?
    @State private var lastCPUTime: TimeInterval?
    @State private var lastResponseBytes: Int64?
    private let ticker = Timer.publish(every: DiagnosticsOverlay.sampleInterval, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("DIAGNOSTICS")
            Text("body   \(snapshot.bodyEvalsPerSecond)/s  peak \(snapshot.peakBodyEvalsPerSecond)")
            Text("cache  \(snapshot.publishesPerSecond)/s  peak \(snapshot.peakPublishesPerSecond)")
            Text("timeline visible \(performance.visibleTimelineAssets)  loaded \(performance.loadedTimelineAssets)")
            Text("months \(performance.loadedTimelineMonths)/\(performance.totalTimelineMonths)  largest \(performance.largestLoadedMonth)")
            Text("paging \(performance.isTimelinePaging ? "loading" : "idle")")
            Text("network \(performance.activeNetworkRequests) active  \(Self.byteRate(networkBytesPerSecond))")
            Text("cpu \(cpuPercent, specifier: "%.0f")%  UI stall \(currentMainThreadStall, specifier: "%.1f")s peak \(peakMainThreadStall, specifier: "%.1f")s")
            Text("memory \(residentMemoryMB, specifier: "%.0f") MB  peak \(peakResidentMemoryMB, specifier: "%.0f") MB")
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundColor(.white)
        .padding(10)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .padding(40)
        .onAppear {
            establishPerformanceBaseline()
        }
        .onReceive(ticker) { _ in
            samplePerformance()
        }
    }

    private func establishPerformanceBaseline() {
        let now = ProcessInfo.processInfo.systemUptime
        let diagnostics = PerformanceDiagnostics.snapshot()
        lastSampleUptime = now
        lastCPUTime = Self.processCPUTime()
        lastResponseBytes = diagnostics.totalResponseBytes
        updateMemorySample()
        performance = diagnostics
        snapshot = RenderStormStats.snapshot()
    }

    private func samplePerformance() {
        let now = ProcessInfo.processInfo.systemUptime
        let cpuTime = Self.processCPUTime()
        let diagnostics = PerformanceDiagnostics.snapshot()

        if let previousUptime = lastSampleUptime {
            let elapsed = max(0.001, now - previousUptime)
            currentMainThreadStall = max(0, elapsed - Self.sampleInterval)
            peakMainThreadStall = max(peakMainThreadStall, currentMainThreadStall)

            if let previousCPUTime = lastCPUTime {
                cpuPercent = max(0, (cpuTime - previousCPUTime) / elapsed * 100)
            }
            if let previousResponseBytes = lastResponseBytes {
                networkBytesPerSecond = Double(max(0, diagnostics.totalResponseBytes - previousResponseBytes)) / elapsed
            }
        }

        lastSampleUptime = now
        lastCPUTime = cpuTime
        lastResponseBytes = diagnostics.totalResponseBytes
        updateMemorySample()
        performance = diagnostics
        snapshot = RenderStormStats.snapshot()
    }

    private static func processCPUTime() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return timevalSeconds(usage.ru_utime) + timevalSeconds(usage.ru_stime)
    }

    private static func timevalSeconds(_ value: timeval) -> TimeInterval {
        TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000
    }

    private func updateMemorySample() {
        let megabytes = Double(Self.processResidentMemoryBytes()) / 1_048_576
        residentMemoryMB = megabytes
        peakResidentMemoryMB = max(peakResidentMemoryMB, megabytes)
    }

    private static func processResidentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
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
    }
}

extension View {
    func diagnosticsOverlay() -> some View {
        modifier(DiagnosticsOverlayModifier())
    }
}
