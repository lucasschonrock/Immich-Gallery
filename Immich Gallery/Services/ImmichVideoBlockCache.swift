//
//  ImmichVideoBlockCache.swift
//  Immich Gallery
//
//  Reactive sparse 4 MB block cache for the localhost mTLS proxy.
//  Stores bytes that were already downloaded or fetched because AVPlayer
//  requested something inside the block. No playback cursor or prefetch.
//  Coverage is a set of intervals so a waiter can complete as soon as
//  its requested bytes exist, even if the rest of the block is incomplete.
//

import Foundation

struct ImmichVideoByteRun {
    var start: Int64
    var data: Data

    var end: Int64 { start + Int64(data.count) }
}

final class ImmichVideoCacheBlock {
    let start: Int64
    private(set) var runs: [ImmichVideoByteRun] = []
    var pinCount = 0
    var lastAccess: TimeInterval = ProcessInfo.processInfo.systemUptime
    var fetchTask: URLSessionDataTask?
    var fetchStart: Int64 = 0
    var fetchEnd: Int64 = 0
    var fetchReceived: Int64 = 0
    var passThroughIDs: Set<Int> = []

    init(start: Int64) {
        self.start = start
    }

    var storedBytes: Int64 {
        runs.reduce(0) { $0 + Int64($1.data.count) }
    }

    var hasProducer: Bool {
        fetchTask != nil || !passThroughIDs.isEmpty
    }

    var plannedEnd: Int64 {
        start + ImmichVideoProxyPolicy.blockSize
    }

    func contains(_ offset: Int64) -> Bool {
        contiguousEnd(from: offset) != nil
    }

    /// Exclusive end of the contiguous filled region starting at `offset`.
    func contiguousEnd(from offset: Int64) -> Int64? {
        for run in runs where offset >= run.start && offset < run.end {
            return run.end
        }
        return nil
    }

    func hasRange(from start: Int64, to end: Int64) -> Bool {
        missingIntervals(from: start, to: end).isEmpty
    }

    /// Inclusive missing byte ranges inside this block, clipped to the block.
    func missingIntervals(from start: Int64, to end: Int64) -> [(start: Int64, end: Int64)] {
        let lo = max(start, self.start)
        let hi = min(end, plannedEnd - 1)
        guard hi >= lo else { return [] }

        var missing: [(start: Int64, end: Int64)] = []
        var cursor = lo
        for run in runs {
            if run.end <= cursor { continue }
            if run.start > hi { break }
            if run.start > cursor {
                missing.append((cursor, min(run.start - 1, hi)))
            }
            cursor = max(cursor, run.end)
            if cursor > hi { break }
        }
        if cursor <= hi {
            missing.append((cursor, hi))
        }
        return missing
    }

    func coverageDescription() -> String {
        if runs.isEmpty { return "[]" }
        let parts = runs.map { run in
            "\(ImmichVideoProxyPolicy.formatMB(run.start))-\(ImmichVideoProxyPolicy.formatMB(run.end))"
        }
        return "[\(parts.joined(separator: ", "))]"
    }

    func write(at offset: Int64, _ chunk: Data) {
        let blockEnd = start + ImmichVideoProxyPolicy.blockSize
        guard offset >= start, offset < blockEnd, !chunk.isEmpty else { return }

        let take = min(Int64(chunk.count), blockEnd - offset)
        let incoming = ImmichVideoByteRun(start: offset, data: Data(chunk.prefix(Int(take))))
        lastAccess = ProcessInfo.processInfo.systemUptime

        var pieces = runs
        pieces.append(incoming)
        pieces.sort { $0.start < $1.start }

        var merged: [ImmichVideoByteRun] = []
        for piece in pieces {
            guard var last = merged.last else {
                merged.append(piece)
                continue
            }
            if piece.end < last.start || piece.start > last.end {
                merged.append(piece)
                continue
            }

            let combinedStart = min(last.start, piece.start)
            let combinedEnd = max(last.end, piece.end)
            var data = Data(count: Int(combinedEnd - combinedStart))
            let lastDest = Int(last.start - combinedStart)
            data.replaceSubrange(lastDest..<(lastDest + last.data.count), with: last.data)
            let pieceDest = Int(piece.start - combinedStart)
            data.replaceSubrange(pieceDest..<(pieceDest + piece.data.count), with: piece.data)
            last.start = combinedStart
            last.data = data
            merged[merged.count - 1] = last
        }
        runs = merged
    }

    func slice(from offset: Int64, maxLength: Int) -> Data? {
        guard maxLength > 0, let runEnd = contiguousEnd(from: offset) else { return nil }
        guard let run = runs.first(where: { offset >= $0.start && offset < $0.end }) else { return nil }
        let local = Int(offset - run.start)
        let available = min(maxLength, Int(runEnd - offset), run.data.count - local)
        guard available > 0 else { return nil }
        return run.data.subdata(in: local..<(local + available))
    }
}

final class ImmichVideoBlockCache {
    var total: Int64?
    var contentType = "video/mp4"
    private(set) var blocks: [Int64: ImmichVideoCacheBlock] = [:]

    var storedBytes: Int64 {
        blocks.values.reduce(0) { $0 + $1.storedBytes }
    }

    var blockCount: Int {
        blocks.count
    }

    func reset() {
        for block in blocks.values {
            block.fetchTask?.cancel()
            block.fetchTask = nil
            block.passThroughIDs.removeAll()
        }
        blocks.removeAll()
        total = nil
        contentType = "video/mp4"
    }

    func block(at offset: Int64) -> ImmichVideoCacheBlock? {
        blocks[ImmichVideoProxyPolicy.blockStart(for: offset)]
    }

    @discardableResult
    func blockOrCreate(start: Int64) -> ImmichVideoCacheBlock {
        let aligned = ImmichVideoProxyPolicy.blockStart(for: start)
        if let existing = blocks[aligned] {
            return existing
        }
        let block = ImmichVideoCacheBlock(start: aligned)
        blocks[aligned] = block
        return block
    }

    @discardableResult
    func write(at fileOffset: Int64, _ chunk: Data) -> [ImmichVideoCacheBlock] {
        var offset = fileOffset
        var remaining = chunk
        var touched: [ImmichVideoCacheBlock] = []
        while !remaining.isEmpty {
            let block = blockOrCreate(start: ImmichVideoProxyPolicy.blockStart(for: offset))
            let limit = block.start + ImmichVideoProxyPolicy.blockSize
            let take = min(Int64(remaining.count), limit - offset)
            guard take > 0 else { break }
            let part = remaining.prefix(Int(take))
            remaining = remaining.dropFirst(Int(take))
            block.write(at: offset, Data(part))
            offset += take
            if touched.last !== block {
                touched.append(block)
            }
        }
        evictIfNeeded()
        return touched
    }

    func hasRange(from start: Int64, to end: Int64) -> Bool {
        guard end >= start else { return true }
        var offset = start
        while offset <= end {
            guard let block = block(at: offset), let next = block.contiguousEnd(from: offset), next > offset else {
                return false
            }
            offset = next
        }
        return true
    }

    func slice(from offset: Int64, length: Int) -> Data? {
        guard length > 0 else { return nil }
        var result = Data()
        var position = offset
        var remaining = length
        while remaining > 0 {
            let blockStart = ImmichVideoProxyPolicy.blockStart(for: position)
            guard let block = blocks[blockStart], let part = block.slice(from: position, maxLength: remaining) else {
                return result.isEmpty ? nil : result
            }
            result.append(part)
            position += Int64(part.count)
            remaining -= part.count
            if remaining > 0, ImmichVideoProxyPolicy.blockStart(for: position) == blockStart {
                break
            }
        }
        return result.isEmpty ? nil : result
    }

    func pin(starts: [Int64]) {
        for start in starts {
            blockOrCreate(start: start).pinCount += 1
        }
    }

    func unpin(starts: [Int64]) {
        for start in starts {
            guard let block = blocks[start] else { continue }
            block.pinCount = max(0, block.pinCount - 1)
        }
        evictIfNeeded()
    }

    @discardableResult
    func attachPassThrough(_ streamID: Int, at offset: Int64) -> Bool {
        let block = blockOrCreate(start: offset)
        return block.passThroughIDs.insert(streamID).inserted
    }

    func detachPassThrough(_ streamID: Int) -> [ImmichVideoCacheBlock] {
        var detached: [ImmichVideoCacheBlock] = []
        for block in blocks.values where block.passThroughIDs.contains(streamID) {
            block.passThroughIDs.remove(streamID)
            detached.append(block)
        }
        return detached
    }

    func evictIfNeeded(maxBytes: Int64 = ImmichVideoProxyPolicy.maxCacheBytes) {
        for (key, block) in blocks where block.pinCount == 0 && !block.hasProducer && block.runs.isEmpty {
            blocks.removeValue(forKey: key)
        }

        while storedBytes > maxBytes {
            let victim = blocks.values
                .filter { $0.pinCount == 0 && !$0.hasProducer }
                .min { lhs, rhs in
                    if lhs.lastAccess != rhs.lastAccess {
                        return lhs.lastAccess < rhs.lastAccess
                    }
                    return lhs.start < rhs.start
                }
            guard let victim else { break }
            blocks.removeValue(forKey: victim.start)
        }
    }
}

extension ImmichVideoProxyPolicy {
    static func formatMB(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000)
    }

    /// A sequential producer writes from `producerStart` forward. It can satisfy
    /// `[needFrom, needTo]` only if that range still lies on the remaining path.
    static func sequentialProducerCovers(
        producerStart: Int64,
        producerReceived: Int64,
        producerEnd: Int64?,
        needFrom: Int64,
        needTo: Int64
    ) -> Bool {
        guard needTo >= needFrom else { return true }
        let futureFrom = producerStart + max(0, producerReceived)
        let futureTo = producerEnd ?? Int64.max
        guard futureFrom <= futureTo else { return false }
        return futureFrom <= needTo && futureTo >= needFrom
    }
}
