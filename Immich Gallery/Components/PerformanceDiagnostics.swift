//
//  PerformanceDiagnostics.swift
//  Immich Gallery
//
//  Lightweight, polling-only field diagnostics. Nothing here publishes, so
//  measuring a render/focus problem cannot itself invalidate the view tree.
//

import Foundation

enum PerformanceDiagnostics {
    struct Snapshot: Equatable {
        var visibleTimelineAssets = 0
        var loadedTimelineAssets = 0
        var loadedTimelineMonths = 0
        var totalTimelineMonths = 0
        var largestLoadedMonth = 0
        var isTimelinePaging = false
        var activeNetworkRequests = 0
        var totalResponseBytes: Int64 = 0
    }

    private static let lock = NSLock()
    private static var value = Snapshot()

    static func updateTimeline(
        visibleAssets: Int,
        loadedAssets: Int,
        loadedMonths: Int,
        totalMonths: Int,
        largestLoadedMonth: Int,
        isPaging: Bool
    ) {
        lock.lock()
        value.visibleTimelineAssets = visibleAssets
        value.loadedTimelineAssets = loadedAssets
        value.loadedTimelineMonths = loadedMonths
        value.totalTimelineMonths = totalMonths
        value.largestLoadedMonth = largestLoadedMonth
        value.isTimelinePaging = isPaging
        lock.unlock()
    }

    static func networkRequestStarted() {
        lock.lock()
        value.activeNetworkRequests += 1
        lock.unlock()
    }

    static func networkRequestFinished(responseBytes: Int) {
        lock.lock()
        value.activeNetworkRequests = max(0, value.activeNetworkRequests - 1)
        value.totalResponseBytes += Int64(max(0, responseBytes))
        lock.unlock()
    }

    static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
