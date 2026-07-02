//
//  ThumbnailLoadGate.swift
//  Immich Gallery
//
//  A hard cap on how many thumbnail loads (network fetch + image decode) run
//  at once. SwiftUI's nested lazy containers (LazyVGrid inside LazyVStack in
//  TimelineView) can instantiate far more tiles than are actually visible
//  during fast scroll; without a ceiling, each fires a concurrent load+decode
//  and memory spikes until the OS terminates the app. This gate bounds that
//  concurrency so the working set stays small no matter how many tiles appear.
//

import Foundation

actor ThumbnailLoadGate {
    static let shared = ThumbnailLoadGate()

    /// Tuned for tvOS memory limits: enough parallelism to keep visible tiles
    /// filling quickly, low enough that a fast-scroll instantiation burst can't
    /// run hundreds of decodes simultaneously.
    private let maxConcurrent = 6
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Wait until a slot is free. Always pair with exactly one `release()`.
    func acquire() async {
        if active < maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // Resumed by release(), which hands off its slot — `active` already counts us.
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            // Transfer the slot directly to the next waiter (active stays the same).
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}
