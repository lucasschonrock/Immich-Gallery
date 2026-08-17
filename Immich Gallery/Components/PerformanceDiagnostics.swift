//
//  PerformanceDiagnostics.swift
//  Immich Gallery
//
//  Lightweight, polling-only field diagnostics. Nothing here publishes, so
//  measuring a render/focus problem cannot itself invalidate the view tree.
//

import Foundation

enum PerformanceDiagnostics {
    struct TimelineSnapshot: Equatable {
        var visibleAssets = 0
        var loadedAssets = 0
        var loadedMonths = 0
        var totalMonths = 0
        var largestLoadedMonth = 0
        var isPaging = false
    }

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
    private static var collectionEnabled = false

    static func setCollectionEnabled(_ enabled: Bool) {
        lock.lock()
        if enabled && !collectionEnabled {
            value = Snapshot()
        }
        collectionEnabled = enabled
        if !enabled {
            value = Snapshot()
        }
        lock.unlock()
    }

    /// The snapshot builder stays lazy so Timeline's aggregate counts are not
    /// calculated during normal rendering while diagnostics are disabled.
    static func updateTimeline(_ makeSnapshot: () -> TimelineSnapshot) {
        lock.lock()
        let shouldCollect = collectionEnabled
        lock.unlock()
        guard shouldCollect else { return }

        let timeline = makeSnapshot()

        lock.lock()
        guard collectionEnabled else {
            lock.unlock()
            return
        }
        value.visibleTimelineAssets = timeline.visibleAssets
        value.loadedTimelineAssets = timeline.loadedAssets
        value.loadedTimelineMonths = timeline.loadedMonths
        value.totalTimelineMonths = timeline.totalMonths
        value.largestLoadedMonth = timeline.largestLoadedMonth
        value.isTimelinePaging = timeline.isPaging
        lock.unlock()
    }

    /// Returns whether this request was admitted to diagnostics, allowing its
    /// completion to remain balanced if the setting changes mid-request.
    static func networkRequestStarted() -> Bool {
        lock.lock()
        guard collectionEnabled else {
            lock.unlock()
            return false
        }
        value.activeNetworkRequests += 1
        lock.unlock()
        return true
    }

    static func networkRequestFinished(responseBytes: Int, wasTracked: Bool) {
        guard wasTracked else { return }
        lock.lock()
        guard collectionEnabled else {
            lock.unlock()
            return
        }
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
