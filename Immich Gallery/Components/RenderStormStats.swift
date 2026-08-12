//
//  RenderStormStats.swift
//  Immich Gallery
//
//  Created by mensadi-labs on 2026-08-12.
//

import Foundation

// TEMP DEBUG (remove before release): aggregated counters to diagnose the
// timeline focus-lag report. Counts how often tile bodies re-evaluate and how
// often ThumbnailCache's @Published stats fire, logging at most once per
// second. A cold load on a slow server should show body evals exploding in
// lockstep with cache publishes if the ObservedObject fan-out is the cause.
// Main-thread only: body evals and the cache's stat mutations both run on main.
//
// The completed window is also kept around so DiagnosticsOverlay can show the
// same numbers on screen — the field reporter has no Mac, so the console log
// alone can't reach us.
enum RenderStormStats {
    static var bodyEvals = 0
    static var cachePublishes = 0
    private static var windowStart = Date()

    // Rates from the last window that rolled over, plus running peaks. Read by
    // the overlay on its own poll; nothing here publishes.
    static var lastWindowBodyEvals = 0
    static var lastWindowPublishes = 0
    static var lastWindowDuration: TimeInterval = 0
    static var peakBodyEvalsPerSecond = 0
    static var peakPublishesPerSecond = 0
    private static var windowEnd = Date.distantPast

    static func tickBody() { bodyEvals += 1; logIfDue() }
    static func tickPublish() { cachePublishes += 1; logIfDue() }

    private static func logIfDue() {
        let elapsed = Date().timeIntervalSince(windowStart)
        guard elapsed >= 1.0 else { return }
        print("🔬 RENDER-STORM: \(bodyEvals) tile body evals, \(cachePublishes) cache publishes in last \(String(format: "%.1f", elapsed))s")
        rollWindow(elapsed: elapsed)
    }

    private static func rollWindow(elapsed: TimeInterval) {
        lastWindowBodyEvals = bodyEvals
        lastWindowPublishes = cachePublishes
        lastWindowDuration = elapsed
        peakBodyEvalsPerSecond = max(peakBodyEvalsPerSecond, perSecond(bodyEvals, over: elapsed))
        peakPublishesPerSecond = max(peakPublishesPerSecond, perSecond(cachePublishes, over: elapsed))

        bodyEvals = 0
        cachePublishes = 0
        windowStart = Date()
        windowEnd = windowStart
    }

    private static func perSecond(_ count: Int, over duration: TimeInterval) -> Int {
        guard duration > 0 else { return 0 }
        return Int((Double(count) / duration).rounded())
    }

    /// What the overlay renders. A value type so the overlay holds a still frame
    /// rather than reading mutating statics mid-layout.
    struct Snapshot: Equatable {
        var bodyEvalsPerSecond = 0
        var publishesPerSecond = 0
        var peakBodyEvalsPerSecond = 0
        var peakPublishesPerSecond = 0
    }

    /// Current rates, or zeroed rates when nothing has ticked for a while.
    /// Windows only roll over on activity, so an idle app would otherwise keep
    /// displaying its last busy second forever. Peaks are kept regardless.
    static func snapshot(staleAfter: TimeInterval = 2.5) -> Snapshot {
        let isStale = Date().timeIntervalSince(windowEnd) > staleAfter
        return Snapshot(
            bodyEvalsPerSecond: isStale ? 0 : perSecond(lastWindowBodyEvals, over: lastWindowDuration),
            publishesPerSecond: isStale ? 0 : perSecond(lastWindowPublishes, over: lastWindowDuration),
            peakBodyEvalsPerSecond: peakBodyEvalsPerSecond,
            peakPublishesPerSecond: peakPublishesPerSecond
        )
    }
}
