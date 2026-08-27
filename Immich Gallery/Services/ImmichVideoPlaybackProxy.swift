//
//  ImmichVideoPlaybackProxy.swift
//  Immich Gallery
//
//  AVPlayer cannot present a client certificate, so mTLS playback is bridged
//  through a loopback HTTP proxy. Large/open-ended ranges stream 1:1 from
//  Immich. Small ranges read through a reactive 4 MB block cache so AVPlayer's
//  64 KB probes do not each become a WAN request.
//

import AVFoundation
import Foundation
import Network

enum ImmichVideoProxyPolicy {
    static let transportHighWaterBytes: Int64 = 4 * 1024 * 1024
    static let transportLowWaterBytes: Int64 = 1 * 1024 * 1024
    static let largeRangeBytes: Int64 = 32 * 1024 * 1024
    static let blockSize: Int64 = 4 * 1024 * 1024
    static let maxCacheBytes: Int64 = 128 * 1024 * 1024
    static let cachedSendHighWaterBytes = 1 * 1024 * 1024

    static func requestLength(start: Int64, end: Int64?) -> Int64 {
        guard let end, end >= start else { return Int64.max }
        return end - start + 1
    }

    static func isStreamingRange(start: Int64, end: Int64?) -> Bool {
        requestLength(start: start, end: end) > largeRangeBytes
    }

    static func blockStart(for offset: Int64) -> Int64 {
        guard offset > 0 else { return 0 }
        return (offset / blockSize) * blockSize
    }

    static func blockEnd(start: Int64, total: Int64?) -> Int64 {
        let raw = start + blockSize - 1
        if let total, total > 0 {
            return min(raw, total - 1)
        }
        return raw
    }

    static func coveringBlocks(start: Int64, end: Int64) -> [Int64] {
        guard end >= start else { return [blockStart(for: start)] }
        var starts: [Int64] = []
        var offset = blockStart(for: start)
        let last = blockStart(for: end)
        while offset <= last {
            starts.append(offset)
            offset += blockSize
        }
        return starts
    }
}

final class ImmichVideoPlaybackProxy: NSObject, URLSessionDataDelegate {
    private let queue = DispatchQueue(label: "immich.video.playback-proxy")
    private let queueKey = DispatchSpecificKey<Bool>()

    private var listener: NWListener?
    private var session: URLSession?
    private var origin: URL?
    private var authenticationService: AuthenticationService?
    private var connections: [ObjectIdentifier: ClientLink] = [:]
    private var streamsByTask: [Int: ProxyStream] = [:]
    private var streamsByConnection: [ObjectIdentifier: ProxyStream] = [:]
    private var blocksByTask: [Int: ImmichVideoCacheBlock] = [:]
    private var cachedGetsByConnection: [ObjectIdentifier: CachedGet] = [:]
    private var cachedGets: [CachedGet] = []
    private var blockCache = ImmichVideoBlockCache()
    private var port: UInt16?
    private var isStopped = false
    private var nextStreamID = 1

    private var originBytes: Int64 = 0
    private var originByteLog: [(t: TimeInterval, bytes: Int64)] = []
    private var lastOriginLogUptime: TimeInterval = 0
    private var avplayerRequests = 0
    private var upstreamRequests = 0
    private var cacheHits = 0
    private var cacheMisses = 0
    private var cacheWaits = 0

    override init() {
        super.init()
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        // URLSession releases this delegate on `queue`; syncing to it from
        // deinit deadlocks and libdispatch traps with EXC_BREAKPOINT.
        stop()
    }

    /// AVPlayer cannot present a client certificate. mTLS playback is proxied on
    /// loopback so AVPlayer can use its native HTTP range/buffering stack.
    /// Without mTLS, AVPlayer talks to Immich directly with auth headers.
    func makePlaybackAsset(
        origin: URL,
        authenticationService: AuthenticationService,
        loader: ImmichVideoResourceLoader
    ) async -> AVURLAsset {
        if ImmichHTTPClient.shared.certificateStatus == .ready {
            do {
                let localURL = try await start(origin: origin, authenticationService: authenticationService)
                VideoPlaybackLog.message("[VIDEO-DIAG] mTLS path: AVPlayer → http://127.0.0.1 → pass-through + 4MB block cache + mTLS → \(origin.absoluteString)")
                return AVURLAsset(url: localURL)
            } catch {
                VideoPlaybackLog.message("[VIDEO-DIAG] local proxy failed (\(error.localizedDescription)); falling back to resource loader")
                let proxyURL = ImmichVideoResourceLoader.proxyURL(for: origin)
                let asset = AVURLAsset(url: proxyURL)
                asset.resourceLoader.setDelegate(loader, queue: loader.queue)
                return asset
            }
        }

        let headers = authenticationService.getAuthHeaders()
        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        VideoPlaybackLog.message("[VIDEO-DIAG] native AVPlayer HTTP path (no mTLS): \(origin.absoluteString)")
        return AVURLAsset(url: origin, options: options)
    }

    func start(origin: URL, authenticationService: AuthenticationService) async throws -> URL {
        nonisolated(unsafe) let auth = authenticationService
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let port = self.port, self.listener != nil, self.origin == origin {
                    continuation.resume(returning: Self.localURL(port: port))
                    return
                }

                self.stopLocked()
                self.isStopped = false
                self.origin = origin
                self.authenticationService = auth

                let configuration = URLSessionConfiguration.default
                configuration.networkServiceType = .avStreaming
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 3600
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.urlCache = nil
                configuration.httpMaximumConnectionsPerHost = 4
                configuration.httpShouldUsePipelining = false
                configuration.waitsForConnectivity = true

                let delegateQueue = OperationQueue()
                delegateQueue.name = "immich.video.playback-proxy.session"
                delegateQueue.maxConcurrentOperationCount = 1
                delegateQueue.underlyingQueue = self.queue
                self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)

                do {
                    let parameters = NWParameters.tcp
                    parameters.acceptLocalOnly = true
                    let listener = try NWListener(using: parameters, on: .any)
                    self.listener = listener
                    var didResume = false

                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        self.queue.async {
                            switch state {
                            case .ready:
                                guard !didResume else { return }
                                guard let port = listener.port?.rawValue else {
                                    didResume = true
                                    continuation.resume(throwing: ImmichVideoProxyError.listenerFailed("No local port"))
                                    self.stopLocked()
                                    return
                                }
                                didResume = true
                                self.port = port
                                VideoPlaybackLog.message("[VIDEO-DIAG] local mTLS proxy listening on 127.0.0.1:\(port) → \(origin.host ?? "")")
                                continuation.resume(returning: Self.localURL(port: port))
                            case .failed(let error):
                                guard !didResume else { return }
                                didResume = true
                                continuation.resume(throwing: ImmichVideoProxyError.listenerFailed(error.localizedDescription))
                                self.stopLocked()
                            case .cancelled:
                                break
                            default:
                                break
                            }
                        }
                    }

                    listener.newConnectionHandler = { [weak self] connection in
                        self?.queue.async {
                            self?.accept(connection)
                        }
                    }

                    listener.start(queue: self.queue)
                } catch {
                    continuation.resume(throwing: ImmichVideoProxyError.listenerFailed(error.localizedDescription))
                }
            }
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopLocked()
        } else {
            queue.sync { stopLocked() }
        }
    }

    /// AVPlayer closes the old localhost ranges on a real seek. The matching
    /// upstream tasks are cancelled when those connections drop.
    func notifyExplicitSeek() {
        queue.async {
            VideoPlaybackLog.message("[VIDEO-DIAG] SEEK source=explicitPlayerSeek")
        }
    }

    private func stopLocked() {
        guard !isStopped else { return }
        isStopped = true
        listener?.cancel()
        listener = nil
        port = nil
        origin = nil
        authenticationService = nil

        for stream in streamsByTask.values {
            stream.task?.cancel()
            stream.task = nil
        }
        streamsByTask.removeAll()
        streamsByConnection.removeAll()
        blocksByTask.removeAll()
        cachedGetsByConnection.removeAll()
        cachedGets.removeAll()
        blockCache.reset()
        originBytes = 0
        originByteLog.removeAll()
        avplayerRequests = 0
        upstreamRequests = 0
        cacheHits = 0
        cacheMisses = 0
        cacheWaits = 0

        for link in connections.values {
            link.cancel()
        }
        connections.removeAll()

        session?.invalidateAndCancel()
        session = nil
    }

    private static func localURL(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)/video.mp4")!
    }

    private func accept(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }

        let link = ClientLink(connection: connection, queue: queue)
        connections[ObjectIdentifier(connection)] = link
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.queue.async {
                switch state {
                case .failed, .cancelled:
                    self.close(connection)
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: link, accumulated: Data())
    }

    private func receiveRequest(on link: ClientLink, accumulated: Data) {
        link.connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.close(link.connection)
                    _ = error
                    return
                }

                var buffer = accumulated
                if let data { buffer.append(data) }

                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.upperBound)
                    let leftover = buffer.subdata(in: headerEnd.upperBound..<buffer.endIndex)
                    guard
                        let headerText = String(data: headerData, encoding: .isoLatin1),
                        let request = ImmichVideoProxyHTTP.parseRequest(headerText)
                    else {
                        self.fail(link: link, status: 400, message: "Invalid request")
                        return
                    }
                    link.pipelinedLeftover = leftover
                    self.handleClientRequest(request, link: link)
                    return
                }

                if buffer.count > 64 * 1024 {
                    self.fail(link: link, status: 413, message: "Request too large")
                    return
                }

                if isComplete {
                    self.close(link.connection)
                    return
                }

                self.receiveRequest(on: link, accumulated: buffer)
            }
        }
    }

    private func handleClientRequest(_ request: ImmichVideoProxyHTTP.Request, link: ClientLink) {
        let method = request.method.uppercased()
        guard method == "GET" || method == "HEAD" else {
            fail(link: link, status: 405, message: "Method not allowed")
            return
        }
        guard origin != nil, session != nil else {
            fail(link: link, status: 502, message: "Proxy is not ready")
            return
        }

        avplayerRequests += 1
        let parsed = request.range.flatMap(ImmichVideoRangePlanner.parseRangeHeader)
        let start = parsed?.start ?? 0
        let end = parsed?.end
        let id = nextStreamID
        nextStreamID += 1
        let streaming = ImmichVideoProxyPolicy.isStreamingRange(start: start, end: end)

        if streaming {
            let stream = ProxyStream(
                id: id,
                link: link,
                start: start,
                end: end,
                isHead: method == "HEAD",
                keepAlive: request.keepAlive,
                requestedRange: request.range ?? "none",
                isStreaming: true
            )
            streamsByConnection[ObjectIdentifier(link.connection)] = stream
            link.onDrain = { [weak self, weak stream] in
                guard let self, let stream else { return }
                self.applyBackpressure(stream)
            }
            VideoPlaybackLog.message("[VIDEO-DIAG] stream #\(id) START pass-through Range=\(stream.requestedRange)")
            attachPassThroughProducer(stream, at: stream.start)
            startOrigin(for: stream)
            return
        }

        let boundedEnd = end ?? start
        let cached = CachedGet(
            id: id,
            link: link,
            start: start,
            end: boundedEnd,
            isHead: method == "HEAD",
            keepAlive: request.keepAlive,
            requestedRange: request.range ?? "none"
        )
        cachedGets.append(cached)
        cachedGetsByConnection[ObjectIdentifier(link.connection)] = cached
        link.onDrain = { [weak self, weak cached] in
            guard let self, let cached else { return }
            self.pumpCachedGet(cached)
        }
        VideoPlaybackLog.message("[VIDEO-DIAG] stream #\(id) START cache Range=\(cached.requestedRange)")
        beginCachedGet(cached)
    }

    private func startOrigin(for stream: ProxyStream) {
        guard let origin, let session else { return }

        var request = URLRequest(url: origin)
        request.httpMethod = stream.isHead ? "HEAD" : "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if stream.requestedRange != "none" {
            request.setValue(stream.requestedRange, forHTTPHeaderField: "Range")
        }
        for (header, value) in authenticationService?.getAuthHeaders() ?? [:] {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let task = session.dataTask(with: request)
        stream.task = task
        streamsByTask[task.taskIdentifier] = stream
        upstreamRequests += 1
        task.resume()
    }

    private func beginCachedGet(_ get: CachedGet) {
        if get.isHead, blockCache.total != nil {
            cacheHits += 1
            VideoPlaybackLog.message("[VIDEO-DIAG] BLOCK HIT req=\(Self.mb(get.start))MB")
            pumpCachedGet(get)
            return
        }

        let covering = ImmichVideoProxyPolicy.coveringBlocks(start: get.start, end: get.end)
        get.pinned = covering
        blockCache.pin(starts: covering)

        let fullyCached = blockCache.hasRange(from: get.start, to: get.end)
        if fullyCached {
            cacheHits += 1
            VideoPlaybackLog.message("[VIDEO-DIAG] BLOCK HIT req=\(Self.mb(get.start))MB")
        } else if producerWillCover(from: get.start, to: get.end) {
            cacheWaits += 1
            VideoPlaybackLog.message("[VIDEO-DIAG] BLOCK WAIT req=\(Self.mb(get.start))MB producer=\(producerDescription(from: get.start, to: get.end))")
        } else {
            cacheMisses += 1
            let firstBlock = ImmichVideoProxyPolicy.blockStart(for: get.current)
            let blockEnd = ImmichVideoProxyPolicy.blockEnd(start: firstBlock, total: blockCache.total)
            VideoPlaybackLog.message("[VIDEO-DIAG] BLOCK MISS req=\(Self.mb(get.start))MB block=\(Self.mb(firstBlock))-\(Self.mb(blockEnd))MB")
        }

        ensureProducers(for: get)
        pumpCachedGet(get)
        diagnoseStrandedWaiters()
    }

    private func ensureProducers(for get: CachedGet) {
        let remainingEnd = get.end
        guard get.current <= remainingEnd else { return }
        for blockStart in ImmichVideoProxyPolicy.coveringBlocks(start: get.current, end: remainingEnd) {
            let block = blockCache.blockOrCreate(start: blockStart)
            let blockEnd = ImmichVideoProxyPolicy.blockEnd(start: blockStart, total: blockCache.total)
            let needFrom = max(get.current, blockStart)
            let needTo = min(remainingEnd, blockEnd)
            if block.hasRange(from: needFrom, to: needTo) { continue }
            if producerWillCover(block, needFrom: needFrom, needTo: needTo) { continue }
            startFetchForMissing(block, needFrom: needFrom, needTo: needTo)
        }
    }

    private func startFetchForMissing(_ block: ImmichVideoCacheBlock, needFrom: Int64, needTo: Int64) {
        if block.fetchTask != nil { return }

        let blockEnd = ImmichVideoProxyPolicy.blockEnd(start: block.start, total: blockCache.total)
        let uncovered = block.missingIntervals(from: needFrom, to: needTo).filter { gap in
            !gapCoveredByProducer(block, needFrom: gap.start, needTo: gap.end)
        }
        guard let gap = uncovered.first else { return }

        let fetchFrom: Int64
        let fetchTo: Int64
        if block.hasProducer {
            fetchFrom = gap.start
            fetchTo = gap.end
        } else {
            fetchFrom = block.missingIntervals(from: block.start, to: blockEnd).first?.start ?? block.start
            fetchTo = blockEnd
        }
        guard fetchFrom <= fetchTo else { return }
        startBlockFetch(block, from: fetchFrom, to: fetchTo)
    }

    private func startBlockFetch(_ block: ImmichVideoCacheBlock, from fetchStart: Int64, to fetchEnd: Int64) {
        guard block.fetchTask == nil else { return }
        guard let origin, let session else { return }

        var request = URLRequest(url: origin)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("bytes=\(fetchStart)-\(fetchEnd)", forHTTPHeaderField: "Range")
        for (header, value) in authenticationService?.getAuthHeaders() ?? [:] {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let task = session.dataTask(with: request)
        block.fetchTask = task
        block.fetchStart = fetchStart
        block.fetchEnd = fetchEnd
        block.fetchReceived = 0
        blocksByTask[task.taskIdentifier] = block
        upstreamRequests += 1
        VideoPlaybackLog.message("[VIDEO-DIAG] BLOCK FETCH START \(Self.mb(fetchStart))-\(Self.mb(fetchEnd))MB")
        task.resume()
    }

    private func producerWillCover(from start: Int64, to end: Int64) -> Bool {
        for blockStart in ImmichVideoProxyPolicy.coveringBlocks(start: start, end: end) {
            let block = blockCache.blockOrCreate(start: blockStart)
            let needFrom = max(start, blockStart)
            let needTo = min(end, ImmichVideoProxyPolicy.blockEnd(start: blockStart, total: blockCache.total))
            if block.hasRange(from: needFrom, to: needTo) { continue }
            if !producerWillCover(block, needFrom: needFrom, needTo: needTo) {
                return false
            }
        }
        return true
    }

    private func producerWillCover(_ block: ImmichVideoCacheBlock, needFrom: Int64, needTo: Int64) -> Bool {
        let missing = block.missingIntervals(from: needFrom, to: needTo)
        if missing.isEmpty { return true }
        return missing.allSatisfy { gap in
            gapCoveredByProducer(block, needFrom: gap.start, needTo: gap.end)
        }
    }

    private func gapCoveredByProducer(_ block: ImmichVideoCacheBlock, needFrom: Int64, needTo: Int64) -> Bool {
        if block.fetchTask != nil,
           ImmichVideoProxyPolicy.sequentialProducerCovers(
            producerStart: block.fetchStart,
            producerReceived: block.fetchReceived,
            producerEnd: block.fetchEnd,
            needFrom: needFrom,
            needTo: needTo
           ) {
            return true
        }

        for streamID in block.passThroughIDs {
            guard let stream = stream(id: streamID) else { continue }
            if ImmichVideoProxyPolicy.sequentialProducerCovers(
                producerStart: stream.start,
                producerReceived: stream.received,
                producerEnd: stream.end,
                needFrom: needFrom,
                needTo: needTo
            ) {
                return true
            }
        }
        return false
    }

    private func producerDescription(from start: Int64, to end: Int64) -> String {
        let block = blockCache.block(at: start)
        if let id = block?.passThroughIDs.sorted().first {
            return "pass-through#\(id)"
        }
        if block?.fetchTask != nil {
            return "fetch"
        }
        for blockStart in ImmichVideoProxyPolicy.coveringBlocks(start: start, end: end) {
            if let id = blockCache.blocks[blockStart]?.passThroughIDs.sorted().first {
                return "pass-through#\(id)"
            }
        }
        return "none"
    }

    private func stream(id: Int) -> ProxyStream? {
        if let match = streamsByTask.values.first(where: { $0.id == id }) {
            return match
        }
        return streamsByConnection.values.first(where: { $0.id == id })
    }

    private func attachPassThroughProducer(_ stream: ProxyStream, at offset: Int64) {
        if blockCache.attachPassThrough(stream.id, at: offset) {
            let block = blockCache.blockOrCreate(start: offset)
            let blockEnd = ImmichVideoProxyPolicy.blockEnd(start: block.start, total: blockCache.total)
            VideoPlaybackLog.message("[VIDEO-DIAG] BLOCK PRODUCER attach source=passThrough#\(stream.id) block=\(Self.mb(block.start))-\(Self.mb(blockEnd))MB")
        }
    }

    private func detachPassThroughProducer(_ stream: ProxyStream) {
        let blocks = blockCache.detachPassThrough(stream.id)
        guard !blocks.isEmpty else { return }
        pumpCachedGets()
        for block in blocks {
            resumeUnsatisfiedWaiters(for: block)
        }
        diagnoseStrandedWaiters()
    }

    private func resumeUnsatisfiedWaiters(for block: ImmichVideoCacheBlock) {
        let blockEnd = ImmichVideoProxyPolicy.blockEnd(start: block.start, total: blockCache.total)
        var didResume = false
        for get in cachedGets {
            let needFrom = max(get.current, block.start)
            let needTo = min(get.end, blockEnd)
            guard needFrom <= needTo, !block.hasRange(from: needFrom, to: needTo) else { continue }
            if producerWillCover(block, needFrom: needFrom, needTo: needTo) { continue }
            guard let gap = block.missingIntervals(from: needFrom, to: needTo).first else { continue }
            VideoPlaybackLog.message("[VIDEO-DIAG] BLOCK RESUME missing=\(Self.mb(gap.start))-\(Self.mb(gap.end))MB")
            startFetchForMissing(block, needFrom: needFrom, needTo: needTo)
            didResume = true
            break
        }
        _ = didResume
    }

    private func diagnoseStrandedWaiters() {
        for get in cachedGets {
            if get.isHead, blockCache.total != nil { continue }
            if blockCache.hasRange(from: get.current, to: get.end) { continue }
            for blockStart in ImmichVideoProxyPolicy.coveringBlocks(start: get.current, end: get.end) {
                let block = blockCache.blockOrCreate(start: blockStart)
                let needFrom = max(get.current, blockStart)
                let needTo = min(get.end, ImmichVideoProxyPolicy.blockEnd(start: blockStart, total: blockCache.total))
                if block.hasRange(from: needFrom, to: needTo) { continue }
                if producerWillCover(block, needFrom: needFrom, needTo: needTo) { continue }
                VideoPlaybackLog.message("[VIDEO-DIAG] BUG STRANDED WAITER block=\(Self.mb(block.start))-\(Self.mb(ImmichVideoProxyPolicy.blockEnd(start: block.start, total: blockCache.total)))MB requested=\(Self.mb(get.start))-\(Self.mb(get.end))MB coverage=\(block.coverageDescription()) producer=nil")
                startFetchForMissing(block, needFrom: needFrom, needTo: needTo)
            }
        }
    }

    private func pumpCachedGets() {
        let snapshot = cachedGets
        for get in snapshot {
            pumpCachedGet(get)
        }
    }

    private func pumpCachedGet(_ get: CachedGet) {
        guard cachedGets.contains(where: { $0.id == get.id }) else { return }
        guard !get.link.isCancelled else {
            finishCachedGet(get, closeConnection: true)
            return
        }

        if blockCache.total == nil {
            ensureProducers(for: get)
            return
        }

        let total = blockCache.total!
        guard total > 0 else {
            fail(link: get.link, status: 502, message: "Unknown content length")
            return
        }

        let clampedEnd = min(get.end, total - 1)
        if get.start >= total {
            fail(link: get.link, status: 416, message: "Range not satisfiable")
            return
        }

        if !get.headersSent {
            let header = ImmichVideoProxyHTTP.makePartialContentHeader(
                start: get.start,
                end: clampedEnd,
                total: total,
                contentType: blockCache.contentType,
                keepAlive: get.keepAlive
            )
            get.link.send(header)
            get.headersSent = true
            if get.isHead {
                finishCachedGet(get, closeConnection: false)
                return
            }
        }

        while get.current <= clampedEnd {
            if get.link.bufferedBytes >= ImmichVideoProxyPolicy.cachedSendHighWaterBytes {
                return
            }
            let remaining = Int(clampedEnd - get.current + 1)
            guard let slice = blockCache.slice(from: get.current, length: remaining), !slice.isEmpty else {
                ensureProducers(for: get)
                diagnoseStrandedWaiters()
                return
            }
            if get.satisfiedFrom == nil {
                get.satisfiedFrom = producerDescription(from: get.current, to: get.current)
            }
            get.link.send(slice)
            get.current += Int64(slice.count)
        }

        finishCachedGet(get, closeConnection: false)
    }

    private func finishCachedGet(_ get: CachedGet, closeConnection: Bool) {
        if get.headersSent, !get.isHead {
            VideoPlaybackLog.message("[VIDEO-DIAG] BLOCK WAITER SATISFIED req=\(Self.mb(get.start))-\(Self.mb(get.end))MB source=\(get.satisfiedFrom ?? "cache")")
        }
        cachedGets.removeAll { $0.id == get.id }
        if cachedGetsByConnection[ObjectIdentifier(get.link.connection)]?.id == get.id {
            cachedGetsByConnection.removeValue(forKey: ObjectIdentifier(get.link.connection))
        }
        blockCache.unpin(starts: get.pinned)
        get.pinned.removeAll()
        get.link.onDrain = nil

        get.link.flush { [weak self] in
            guard let self else { return }
            self.queue.async {
                if closeConnection || !get.keepAlive {
                    self.close(get.link.connection)
                    return
                }
                let leftover = get.link.pipelinedLeftover
                get.link.pipelinedLeftover = Data()
                self.receiveRequest(on: get.link, accumulated: leftover)
            }
        }
    }

    private func applyBackpressure(_ stream: ProxyStream) {
        guard let task = stream.task, !stream.isHead else { return }
        let buffered = Int64(stream.link.bufferedBytes)
        if !stream.upstreamPaused, buffered >= ImmichVideoProxyPolicy.transportHighWaterBytes {
            task.suspend()
            stream.upstreamPaused = true
            VideoPlaybackLog.message("[VIDEO-DIAG] stream #\(stream.id) BACKPRESSURE pause buffered=\(Self.mb(buffered))MB Range=\(stream.requestedRange)")
        } else if stream.upstreamPaused, buffered <= ImmichVideoProxyPolicy.transportLowWaterBytes {
            task.resume()
            stream.upstreamPaused = false
            VideoPlaybackLog.message("[VIDEO-DIAG] stream #\(stream.id) BACKPRESSURE resume buffered=\(Self.mb(buffered))MB Range=\(stream.requestedRange)")
        }
    }

    private func finishStream(_ stream: ProxyStream, closeConnection: Bool) {
        if let identifier = stream.task?.taskIdentifier {
            streamsByTask.removeValue(forKey: identifier)
        }
        if streamsByConnection[ObjectIdentifier(stream.link.connection)]?.id == stream.id {
            streamsByConnection.removeValue(forKey: ObjectIdentifier(stream.link.connection))
        }
        stream.link.onDrain = nil
        stream.task = nil
        detachPassThroughProducer(stream)

        stream.link.flush { [weak self] in
            guard let self else { return }
            self.queue.async {
                if closeConnection || !stream.keepAlive {
                    self.close(stream.link.connection)
                    return
                }
                let leftover = stream.link.pipelinedLeftover
                stream.link.pipelinedLeftover = Data()
                self.receiveRequest(on: stream.link, accumulated: leftover)
            }
        }
    }

    private func fail(link: ClientLink, status: Int, message: String) {
        let body = Data(message.utf8)
        let header = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        link.send(Data(header.utf8) + body)
        link.flush { [weak self] in
            self?.queue.async {
                self?.close(link.connection)
            }
        }
    }

    private func close(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        if let stream = streamsByConnection.removeValue(forKey: key) {
            if stream.upstreamPaused {
                stream.task?.resume()
                stream.upstreamPaused = false
            }
            if let identifier = stream.task?.taskIdentifier {
                streamsByTask.removeValue(forKey: identifier)
            }
            stream.task?.cancel()
            stream.task = nil
            stream.link.onDrain = nil
            detachPassThroughProducer(stream)
        }
        if let get = cachedGetsByConnection.removeValue(forKey: key) {
            cachedGets.removeAll { $0.id == get.id }
            blockCache.unpin(starts: get.pinned)
            get.pinned.removeAll()
            get.link.onDrain = nil
        }
        if let link = connections.removeValue(forKey: key) {
            link.cancel()
        } else {
            connection.cancel()
        }
    }

    private func noteOriginBytes(_ count: Int) {
        originBytes += Int64(count)
        let now = ProcessInfo.processInfo.systemUptime
        originByteLog.append((now, originBytes))
        let cutoff = now - 12
        originByteLog.removeAll { $0.t < cutoff }
    }

    private func rollingMbps(_ seconds: TimeInterval) -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        let windowStart = now - seconds
        guard let sample = originByteLog.last(where: { $0.t <= windowStart }) ?? originByteLog.first else { return 0 }
        let dt = now - sample.t
        guard dt > 0 else { return 0 }
        return Double(originBytes - sample.bytes) * 8 / dt / 1_000_000
    }

    private func logOriginThroughputIfNeeded(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastOriginLogUptime >= 1 else { return }
        lastOriginLogUptime = now
        if VideoPlaybackLog.isEnabled {
            let streaming = streamsByTask.values.filter(\.isStreaming)
            let blockFetches = blocksByTask.count
            let cachePath = cacheHits + cacheMisses + cacheWaits
            let hitRate = cachePath == 0 ? 0.0 : (Double(cacheHits) / Double(cachePath) * 100)
            VideoPlaybackLog.message(String(
                format: "[VIDEO-DIAG] origin 1s=%.1fMbps 5s=%.1fMbps 10s=%.1fMbps streams=%d blocks=%d cachedGets=%d buffered=%.1fMB cacheHitRate=%.0f%% upstreamRequests=%d avplayerRequests=%d cached=%.1fMB",
                rollingMbps(1),
                rollingMbps(5),
                rollingMbps(10),
                streaming.count,
                blockFetches,
                cachedGets.count,
                Double(streaming.first?.link.bufferedBytes ?? 0) / 1_000_000,
                hitRate,
                upstreamRequests,
                avplayerRequests,
                Double(blockCache.storedBytes) / 1_000_000
            ))
            for stream in streamsByTask.values.sorted(by: { $0.id < $1.id }) {
                VideoPlaybackLog.message("[VIDEO-DIAG] stream #\(stream.id) pass-through Range=\(stream.requestedRange) received=\(Self.mb(stream.received))MB paused=\(stream.upstreamPaused ? "y" : "n")")
            }
        }
        diagnoseStrandedWaiters()
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        ImmichHTTPClient.shared.handleChallenge(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            if let stream = streamsByTask[dataTask.taskIdentifier] {
                fail(link: stream.link, status: 502, message: "Invalid upstream response")
            } else if let block = blocksByTask.removeValue(forKey: dataTask.taskIdentifier) {
                failBlockFetch(block, message: "Invalid upstream response")
            }
            return
        }

        if let block = blocksByTask[dataTask.taskIdentifier] {
            handleBlockResponse(httpResponse, block: block, task: dataTask, completionHandler: completionHandler)
            return
        }

        guard let stream = streamsByTask[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }

        let requestedRange = dataTask.originalRequest?.value(forHTTPHeaderField: "Range") ?? "none"
        let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range") ?? "none"
        let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length") ?? "\(httpResponse.expectedContentLength)"
        VideoPlaybackLog.message("[VIDEO-DIAG] stream #\(stream.id) HEADERS \(httpResponse.statusCode) Range=\(requestedRange) Content-Range=\(contentRange) Content-Length=\(contentLength)")

        guard (200...299).contains(httpResponse.statusCode) else {
            completionHandler(.cancel)
            fail(link: stream.link, status: httpResponse.statusCode, message: "Upstream \(httpResponse.statusCode)")
            return
        }

        if httpResponse.statusCode == 200, let parsed = ImmichVideoRangePlanner.parseRangeHeader(requestedRange), parsed.start > 0 {
            VideoPlaybackLog.message("[VIDEO-DIAG] WARNING: mid-file Range ignored (200 OK)")
            completionHandler(.cancel)
            fail(link: stream.link, status: 502, message: "Origin ignored Range")
            return
        }

        if httpResponse.statusCode == 206, let received = ImmichVideoRangePlanner.parseContentRange(contentRange) {
            if let requested = ImmichVideoRangePlanner.parseRangeHeader(requestedRange), requested.start != received.start {
                VideoPlaybackLog.message("[VIDEO-DIAG] WARNING: Content-Range start \(received.start) != requested \(requested.start)")
                completionHandler(.cancel)
                fail(link: stream.link, status: 502, message: "Byte range mismatch")
                return
            }
            if let total = received.total, total > 0 {
                blockCache.total = total
            }
        } else if httpResponse.statusCode == 200, httpResponse.expectedContentLength > 0 {
            blockCache.total = httpResponse.expectedContentLength
        }

        if let type = httpResponse.value(forHTTPHeaderField: "Content-Type"), !type.isEmpty {
            blockCache.contentType = type
        }

        let header = ImmichVideoProxyHTTP.makeResponseHeader(from: httpResponse, keepAlive: stream.keepAlive)
        if stream.isHead || httpResponse.statusCode == 204 || httpResponse.statusCode == 416 {
            stream.link.send(header)
            stream.headersSent = true
            completionHandler(.cancel)
            finishStream(stream, closeConnection: httpResponse.statusCode >= 400)
            pumpCachedGets()
            return
        }

        stream.link.send(header)
        stream.headersSent = true
        completionHandler(.allow)
        pumpCachedGets()
    }

    private func handleBlockResponse(
        _ httpResponse: HTTPURLResponse,
        block: ImmichVideoCacheBlock,
        task: URLSessionDataTask,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let requestedRange = task.originalRequest?.value(forHTTPHeaderField: "Range") ?? "none"
        let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range") ?? "none"

        guard (200...299).contains(httpResponse.statusCode) else {
            completionHandler(.cancel)
            failBlockFetch(block, message: "Upstream \(httpResponse.statusCode)")
            return
        }

        if httpResponse.statusCode == 200, let parsed = ImmichVideoRangePlanner.parseRangeHeader(requestedRange), parsed.start > 0 {
            VideoPlaybackLog.message("[VIDEO-DIAG] WARNING: block fetch Range ignored (200 OK)")
            completionHandler(.cancel)
            failBlockFetch(block, message: "Origin ignored Range")
            return
        }

        if httpResponse.statusCode == 206, let received = ImmichVideoRangePlanner.parseContentRange(contentRange) {
            if let requested = ImmichVideoRangePlanner.parseRangeHeader(requestedRange), requested.start != received.start {
                VideoPlaybackLog.message("[VIDEO-DIAG] WARNING: block Content-Range start \(received.start) != requested \(requested.start)")
                completionHandler(.cancel)
                failBlockFetch(block, message: "Byte range mismatch")
                return
            }
            if let total = received.total, total > 0 {
                blockCache.total = total
            }
        } else if httpResponse.statusCode == 200, httpResponse.expectedContentLength > 0 {
            blockCache.total = httpResponse.expectedContentLength
        }

        if let type = httpResponse.value(forHTTPHeaderField: "Content-Type"), !type.isEmpty {
            blockCache.contentType = type
        }

        completionHandler(.allow)
        pumpCachedGets()
    }

    private func failBlockFetch(_ block: ImmichVideoCacheBlock, message: String) {
        let planned = max(Int64(0), block.fetchEnd - block.fetchStart + 1)
        let received = block.fetchReceived
        if let identifier = block.fetchTask?.taskIdentifier {
            blocksByTask.removeValue(forKey: identifier)
        }
        block.fetchTask?.cancel()
        block.fetchTask = nil
        VideoPlaybackLog.message("[VIDEO-DIAG] BLOCK FETCH ERROR \(Self.mb(block.start))MB \(message)")
        VideoPlaybackLog.message("[VIDEO-DIAG] BLOCK FETCH INCOMPLETE received=\(Self.mb(received))/\(Self.mb(planned))MB")
        VideoPlaybackLog.message("[VIDEO-DIAG] BLOCK COVERAGE block=\(Self.mb(block.start))-\(Self.mb(ImmichVideoProxyPolicy.blockEnd(start: block.start, total: blockCache.total)))MB available=\(block.coverageDescription())")
        pumpCachedGets()
        if received == 0, !block.hasProducer {
            failWaiters(for: block, message: message)
        } else {
            resumeUnsatisfiedWaiters(for: block)
        }
        diagnoseStrandedWaiters()
    }

    private func failWaiters(for block: ImmichVideoCacheBlock, message: String) {
        let waiting = cachedGets.filter { get in
            ImmichVideoProxyPolicy.coveringBlocks(start: get.current, end: get.end).contains(block.start)
        }
        for get in waiting {
            if block.hasRange(from: max(get.current, block.start), to: min(get.end, ImmichVideoProxyPolicy.blockEnd(start: block.start, total: blockCache.total))) {
                continue
            }
            if !get.headersSent {
                fail(link: get.link, status: 502, message: message)
            } else {
                close(get.link.connection)
            }
        }
    }

    private func onBlockFetchFinished(_ block: ImmichVideoCacheBlock, error: Error?) {
        let planned = max(Int64(0), block.fetchEnd - block.fetchStart + 1)
        let received = block.fetchReceived
        let cancelled = (error as NSError?)?.code == NSURLErrorCancelled
        block.fetchTask = nil

        pumpCachedGets()

        let blockEnd = ImmichVideoProxyPolicy.blockEnd(start: block.start, total: blockCache.total)
        let stillNeeded = cachedGets.contains { get in
            let needFrom = max(get.current, block.start)
            let needTo = min(get.end, blockEnd)
            return needFrom <= needTo && !block.hasRange(from: needFrom, to: needTo)
        }

        if stillNeeded, received < planned || error != nil {
            VideoPlaybackLog.message("[VIDEO-DIAG] BLOCK FETCH INCOMPLETE received=\(Self.mb(received))/\(Self.mb(planned))MB")
            VideoPlaybackLog.message("[VIDEO-DIAG] BLOCK COVERAGE block=\(Self.mb(block.start))-\(Self.mb(blockEnd))MB available=\(block.coverageDescription())")
        }

        if let error, !cancelled, received == 0, !block.hasProducer {
            failWaiters(for: block, message: error.localizedDescription)
        } else if stillNeeded, received == 0, !block.hasProducer {
            failWaiters(for: block, message: "Block fetch returned no data")
        } else {
            resumeUnsatisfiedWaiters(for: block)
        }
        diagnoseStrandedWaiters()
        blockCache.evictIfNeeded()
        logOriginThroughputIfNeeded(force: true)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        noteOriginBytes(data.count)
        if let stream = streamsByTask[dataTask.taskIdentifier] {
            let fileOffset = stream.start + stream.received
            attachPassThroughProducer(stream, at: fileOffset)
            let blockStart = ImmichVideoProxyPolicy.blockStart(for: fileOffset)
            let wasEmpty = (blockCache.block(at: fileOffset)?.storedBytes ?? 0) == 0
            blockCache.write(at: fileOffset, data)
            if wasEmpty {
                let blockEnd = ImmichVideoProxyPolicy.blockEnd(start: blockStart, total: blockCache.total)
                let block = blockCache.block(at: fileOffset)
                VideoPlaybackLog.message("[VIDEO-DIAG] PASS-THROUGH CACHE WRITE block=\(Self.mb(blockStart))-\(Self.mb(blockEnd))MB")
                if let block {
                    VideoPlaybackLog.message("[VIDEO-DIAG] BLOCK COVERAGE block=\(Self.mb(blockStart))-\(Self.mb(blockEnd))MB available=\(block.coverageDescription())")
                }
            }
            stream.received += Int64(data.count)
            stream.link.send(data)
            applyBackpressure(stream)
            pumpCachedGets()
            logOriginThroughputIfNeeded(force: false)
            return
        }

        if let block = blocksByTask[dataTask.taskIdentifier] {
            let offset = block.fetchStart + block.fetchReceived
            block.fetchReceived += Int64(data.count)
            blockCache.write(at: offset, data)
            pumpCachedGets()
            logOriginThroughputIfNeeded(force: false)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let block = blocksByTask.removeValue(forKey: task.taskIdentifier) {
            if let error, (error as NSError).code != NSURLErrorCancelled {
                VideoPlaybackLog.message("[VIDEO-DIAG] BLOCK FETCH ERROR \(Self.mb(block.start))MB \(error.localizedDescription)")
            }
            onBlockFetchFinished(block, error: error)
            return
        }

        guard let stream = streamsByTask.removeValue(forKey: task.taskIdentifier) else { return }
        stream.task = nil
        let cancelled = (error as NSError?)?.code == NSURLErrorCancelled
        if let error, !cancelled {
            VideoPlaybackLog.message("[VIDEO-DIAG] stream #\(stream.id) ERROR received=\(stream.received) \(error.localizedDescription)")
            if !stream.headersSent {
                fail(link: stream.link, status: 502, message: error.localizedDescription)
                return
            }
            close(stream.link.connection)
            return
        }
        if cancelled {
            VideoPlaybackLog.message("[VIDEO-DIAG] stream #\(stream.id) CANCEL received=\(stream.received) Range=\(stream.requestedRange)")
            close(stream.link.connection)
            return
        }
        VideoPlaybackLog.message("[VIDEO-DIAG] stream #\(stream.id) COMPLETE received=\(stream.received) Range=\(stream.requestedRange)")
        finishStream(stream, closeConnection: false)
        logOriginThroughputIfNeeded(force: true)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        VideoPlaybackLog.message("[VIDEO-DIAG] redirect \(response.statusCode) → \(request.url?.absoluteString ?? "?")")
        var forwarded = request
        for (header, value) in authenticationService?.getAuthHeaders() ?? [:] {
            forwarded.setValue(value, forHTTPHeaderField: header)
        }
        forwarded.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(forwarded)
    }
}

private final class CachedGet {
    let id: Int
    let link: ClientLink
    let start: Int64
    let end: Int64
    let isHead: Bool
    let keepAlive: Bool
    let requestedRange: String
    var headersSent = false
    var current: Int64
    var pinned: [Int64] = []
    var satisfiedFrom: String?

    init(
        id: Int,
        link: ClientLink,
        start: Int64,
        end: Int64,
        isHead: Bool,
        keepAlive: Bool,
        requestedRange: String
    ) {
        self.id = id
        self.link = link
        self.start = start
        self.end = end
        self.isHead = isHead
        self.keepAlive = keepAlive
        self.requestedRange = requestedRange
        self.current = start
    }
}

private final class ProxyStream {
    let id: Int
    let link: ClientLink
    let start: Int64
    let end: Int64?
    let isHead: Bool
    let keepAlive: Bool
    let requestedRange: String
    let isStreaming: Bool
    var headersSent = false
    var received: Int64 = 0
    var upstreamPaused = false
    var task: URLSessionDataTask?

    init(
        id: Int,
        link: ClientLink,
        start: Int64,
        end: Int64?,
        isHead: Bool,
        keepAlive: Bool,
        requestedRange: String,
        isStreaming: Bool
    ) {
        self.id = id
        self.link = link
        self.start = start
        self.end = end
        self.isHead = isHead
        self.keepAlive = keepAlive
        self.requestedRange = requestedRange
        self.isStreaming = isStreaming
    }
}

private final class ClientLink {
    let connection: NWConnection
    private let queue: DispatchQueue
    private var pending = Data()
    private var isSending = false
    private var sendingBytes = 0
    private var flushWaiters: [() -> Void] = []
    private(set) var isCancelled = false
    var pipelinedLeftover = Data()
    var onDrain: (() -> Void)?

    var bufferedBytes: Int { pending.count + sendingBytes }

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func send(_ data: Data) {
        guard !isCancelled, !data.isEmpty else { return }
        pending.append(data)
        pump()
    }

    func flush(_ completion: @escaping () -> Void) {
        guard !isCancelled else {
            completion()
            return
        }
        if pending.isEmpty && !isSending {
            completion()
            return
        }
        flushWaiters.append(completion)
        pump()
    }

    func cancel() {
        isCancelled = true
        onDrain = nil
        flushWaiters.removeAll()
        pending = Data()
        sendingBytes = 0
        connection.cancel()
    }

    private func pump() {
        guard !isCancelled, !isSending, !pending.isEmpty else {
            if !isSending, pending.isEmpty {
                let waiters = flushWaiters
                flushWaiters.removeAll()
                waiters.forEach { $0() }
            }
            return
        }

        let chunk = pending
        pending = Data()
        isSending = true
        sendingBytes = chunk.count
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.isSending = false
                self.sendingBytes = 0
                if error != nil {
                    self.cancel()
                    return
                }
                self.onDrain?()
                self.pump()
            }
        })
    }
}

enum ImmichVideoProxyHTTP {
    struct Request {
        let method: String
        let path: String
        let httpVersion: String
        let range: String?
        let ifRange: String?
        let connection: String?

        var keepAlive: Bool {
            if let connection, connection.lowercased().contains("close") {
                return false
            }
            if httpVersion.contains("1.0") {
                return connection?.lowercased().contains("keep-alive") == true
            }
            return true
        }
    }

    static func parseRequest(_ raw: String) -> Request? {
        let lines = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        return Request(
            method: String(parts[0]),
            path: String(parts[1]),
            httpVersion: parts.count >= 3 ? String(parts[2]) : "HTTP/1.1",
            range: headers["range"],
            ifRange: headers["if-range"],
            connection: headers["connection"]
        )
    }

    static func makePartialContentHeader(
        start: Int64,
        end: Int64,
        total: Int64,
        contentType: String,
        keepAlive: Bool
    ) -> Data {
        let length = end - start + 1
        let lines = [
            "HTTP/1.1 206 Partial Content",
            "Content-Type: \(contentType)",
            "Accept-Ranges: bytes",
            "Content-Range: bytes \(start)-\(end)/\(total)",
            "Content-Length: \(length)",
            "Connection: \(keepAlive ? "keep-alive" : "close")",
            "",
            ""
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    static func makeResponseHeader(from response: HTTPURLResponse, keepAlive: Bool = true) -> Data {
        var lines = ["HTTP/1.1 \(response.statusCode) \(Self.statusText(response.statusCode))"]
        let forwarded = ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"]
        for name in forwarded {
            if let value = response.value(forHTTPHeaderField: name), !value.isEmpty {
                lines.append("\(name): \(value)")
            }
        }
        if response.value(forHTTPHeaderField: "Content-Length") == nil, response.expectedContentLength > 0 {
            lines.append("Content-Length: \(response.expectedContentLength)")
        }
        if response.value(forHTTPHeaderField: "Accept-Ranges") == nil {
            lines.append("Accept-Ranges: bytes")
        }
        lines.append("Connection: \(keepAlive ? "keep-alive" : "close")")
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private static func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 416: return "Range Not Satisfiable"
        default: return HTTPURLResponse.localizedString(forStatusCode: code).capitalized
        }
    }
}

enum ImmichVideoProxyError: LocalizedError {
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .listenerFailed(let message):
            return "Video proxy failed to start: \(message)"
        }
    }
}
