//
//  ImmichVideoResourceLoader.swift
//  Immich Gallery
//
//  AVPlayer cannot present a client certificate. Requests are rewritten to a
//  custom scheme so this loader can stream ranges through an mTLS session.
//  Byte ranges are cached and fetched in small windows so playback can start
//  from the first chunk instead of waiting on the rest of the file.
//

import AVFoundation
import Foundation
import UniformTypeIdentifiers

final class ImmichVideoResourceLoader: NSObject, ObservableObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    static let urlScheme = "immich-video"
    private static let originalSchemeQueryItem = "immichOriginalScheme"

    let queue = DispatchQueue(label: "immich.video.resource-loader")

    weak var authenticationService: AuthenticationService?

    private let sessionQueue = DispatchQueue(label: "immich.video.session")
    private lazy var streamSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.networkServiceType = .avStreaming
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldUsePipelining = true
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = true

        let delegateQueue = OperationQueue()
        delegateQueue.name = "immich.video.session"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = sessionQueue

        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    private var assets: [URL: VideoAssetBuffer] = [:]
    private var downloads: [Int: VideoDownload] = [:]

    deinit {
        streamSession.invalidateAndCancel()
    }

    static func proxyURL(for originalURL: URL) -> URL {
        var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == originalSchemeQueryItem }
        queryItems.append(URLQueryItem(name: originalSchemeQueryItem, value: originalURL.scheme ?? "https"))
        components.queryItems = queryItems
        components.scheme = urlScheme
        return components.url ?? originalURL
    }

    func prefetch(_ originalURL: URL) {
        queue.async { [weak self] in
            guard let self else { return }
            let buffer = self.buffer(for: originalURL)
            self.startDownloadIfNeeded(for: buffer, from: 0, preferFirstChunk: true)
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard
            let proxyURL = loadingRequest.request.url,
            let originalURL = Self.originalURL(from: proxyURL)
        else {
            loadingRequest.finishLoading(with: Self.urlError)
            return false
        }

        let buffer = buffer(for: originalURL)
        buffer.requests.append(loadingRequest)
        applyContentInfo(to: loadingRequest, from: buffer)
        fulfill(buffer)
        startDownloadIfNeeded(for: buffer, from: loadingRequest.dataRequest?.currentOffset ?? 0, preferFirstChunk: true)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        cancel(loadingRequest)
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
            queue.async { [weak self] in
                guard let self, let url = self.downloads[dataTask.taskIdentifier]?.originalURL else { return }
                self.fail(url, with: Self.urlError)
            }
            return
        }

        print("📡 Video loader status \(httpResponse.statusCode) \(dataTask.originalRequest?.value(forHTTPHeaderField: "Range") ?? "")")

        guard (200...299).contains(httpResponse.statusCode) else {
            completionHandler(.cancel)
            queue.async { [weak self] in
                guard let self, let url = self.downloads[dataTask.taskIdentifier]?.originalURL else { return }
                self.fail(
                    url,
                    with: NSError(
                        domain: NSURLErrorDomain,
                        code: NSURLErrorBadServerResponse,
                        userInfo: [NSLocalizedDescriptionKey: "Video request failed (\(httpResponse.statusCode))"]
                    )
                )
            }
            return
        }

        completionHandler(.allow)
        queue.async { [weak self] in
            guard let self, var download = self.downloads[dataTask.taskIdentifier] else { return }
            let parsed = ImmichVideoRangePlanner.parseResponse(httpResponse, requestedStart: download.requestedStart)
            download.nextWriteOffset = parsed.bodyOffset
            download.isFullFile = parsed.isFullFile
            self.downloads[dataTask.taskIdentifier] = download

            let buffer = self.buffer(for: download.originalURL)
            let contentLength = parsed.contentLength ?? buffer.info?.contentLength ?? 0
            buffer.info = VideoContentInfo(
                contentLength: contentLength,
                contentType: parsed.contentType,
                byteRangeAccessSupported: parsed.byteRangeAccessSupported || buffer.info?.byteRangeAccessSupported == true
            )
            self.applyContentInfo(to: buffer)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async { [weak self] in
            guard let self, var download = self.downloads[dataTask.taskIdentifier] else { return }
            let buffer = self.buffer(for: download.originalURL)
            buffer.cache.write(offset: download.nextWriteOffset, data: data)
            download.nextWriteOffset += Int64(data.count)
            self.downloads[dataTask.taskIdentifier] = download
            self.fulfill(buffer)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let download = self.downloads.removeValue(forKey: task.taskIdentifier) else { return }
            let buffer = self.buffer(for: download.originalURL)

            if let error, (error as NSError).code != NSURLErrorCancelled {
                print("❌ Video loader failed: \(error)")
                if buffer.requests.contains(where: { !$0.isCancelled }) {
                    self.fail(download.originalURL, with: error)
                }
                return
            }

            self.fulfill(buffer)
            var stillOpen: [AVAssetResourceLoadingRequest] = []
            for request in buffer.requests where !request.isCancelled {
                let offset = request.dataRequest?.currentOffset ?? 0
                let fetchOffset = offset + Int64(buffer.cache.availableCount(from: offset))
                if ImmichVideoRangePlanner.fetchRange(
                    currentOffset: fetchOffset,
                    contentLength: buffer.info?.contentLength,
                    preferFirstChunk: false
                ) == nil {
                    request.finishLoading()
                } else {
                    stillOpen.append(request)
                    self.startDownloadIfNeeded(for: buffer, from: offset, preferFirstChunk: false)
                }
            }
            buffer.requests = stillOpen
        }
    }

    private static func originalURL(from proxyURL: URL) -> URL? {
        var components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let originalScheme = queryItems.first(where: { $0.name == originalSchemeQueryItem })?.value ?? "https"
        let remainingQueryItems = queryItems.filter { $0.name != originalSchemeQueryItem }
        components?.queryItems = remainingQueryItems.isEmpty ? nil : remainingQueryItems
        components?.scheme = originalScheme
        return components?.url
    }

    private func buffer(for url: URL) -> VideoAssetBuffer {
        if let existing = assets[url] {
            return existing
        }
        let created = VideoAssetBuffer(url: url)
        assets[url] = created
        return created
    }

    private func applyContentInfo(to buffer: VideoAssetBuffer) {
        for request in buffer.requests {
            applyContentInfo(to: request, from: buffer)
        }
        fulfill(buffer)
    }

    private func applyContentInfo(to request: AVAssetResourceLoadingRequest, from buffer: VideoAssetBuffer) {
        guard let infoRequest = request.contentInformationRequest, let info = buffer.info else { return }
        infoRequest.contentType = info.contentType
        infoRequest.isByteRangeAccessSupported = info.byteRangeAccessSupported
        if info.contentLength > 0 {
            infoRequest.contentLength = info.contentLength
        }
    }

    private func fulfill(_ buffer: VideoAssetBuffer) {
        var remaining: [AVAssetResourceLoadingRequest] = []
        remaining.reserveCapacity(buffer.requests.count)

        for request in buffer.requests {
            if request.isCancelled {
                continue
            }

            applyContentInfo(to: request, from: buffer)

            guard let dataRequest = request.dataRequest else {
                if buffer.info != nil {
                    request.finishLoading()
                } else {
                    remaining.append(request)
                }
                continue
            }

            let needed = min(
                ImmichVideoRangePlanner.responseLength(for: dataRequest, contentLength: buffer.info?.contentLength),
                Int(ImmichVideoRangePlanner.nextChunkBytes)
            )
            if needed > 0 {
                let data = buffer.cache.read(from: dataRequest.currentOffset, maxLength: needed)
                if !data.isEmpty {
                    dataRequest.respond(with: data)
                }
            }

            if ImmichVideoRangePlanner.isSatisfied(dataRequest, contentLength: buffer.info?.contentLength) {
                request.finishLoading()
            } else {
                remaining.append(request)
            }
        }

        buffer.requests = remaining
    }

    private func startDownloadIfNeeded(for buffer: VideoAssetBuffer, from offset: Int64, preferFirstChunk: Bool) {
        let fetchOffset = offset + Int64(buffer.cache.availableCount(from: offset))
        if fetchOffset != offset {
            fulfill(buffer)
        }
        if ImmichVideoRangePlanner.isFullyCached(from: offset, cache: buffer.cache, contentLength: buffer.info?.contentLength) {
            return
        }

        if downloads.values.contains(where: { $0.originalURL == buffer.url && $0.covers(fetchOffset) }) {
            return
        }

        guard
            let range = ImmichVideoRangePlanner.fetchRange(
                currentOffset: fetchOffset,
                contentLength: buffer.info?.contentLength,
                preferFirstChunk: preferFirstChunk && fetchOffset == 0
            )
        else {
            return
        }

        var request = URLRequest(url: buffer.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 120
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")

        for (header, value) in authenticationService?.getAuthHeaders() ?? [:] {
            request.setValue(value, forHTTPHeaderField: header)
        }

        print("🎬 Video loader bytes=\(range.start)-\(range.end) \(buffer.url.absoluteString)")

        let task = streamSession.dataTask(with: request)
        downloads[task.taskIdentifier] = VideoDownload(
            originalURL: buffer.url,
            task: task,
            requestedStart: range.start,
            requestedEnd: range.end,
            nextWriteOffset: range.start,
            isFullFile: false
        )
        task.resume()
    }

    private func fail(_ url: URL, with error: Error) {
        let matching = downloads.filter { $0.value.originalURL == url }
        for (identifier, download) in matching {
            downloads.removeValue(forKey: identifier)
            download.task.cancel()
        }
        guard let buffer = assets[url] else { return }
        for request in buffer.requests where !request.isCancelled {
            request.finishLoading(with: error)
        }
        buffer.requests.removeAll()
    }

    private func cancel(_ request: AVAssetResourceLoadingRequest) {
        for buffer in assets.values {
            buffer.requests.removeAll { $0 === request }
        }
    }

    private static var urlError: NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)
    }
}

final class ByteRangeCache {
    private var regions: [(offset: Int64, data: Data)] = []
    private var totalBytes = 0
    private let memoryLimit = 24 * 1024 * 1024

    func write(offset: Int64, data: Data) {
        guard !data.isEmpty else { return }
        regions.append((offset, data))
        totalBytes += data.count
        coalesce()
        trimIfNeeded()
    }

    func read(from offset: Int64, maxLength: Int) -> Data {
        guard maxLength > 0 else { return Data() }
        for region in regions {
            let end = region.offset + Int64(region.data.count)
            guard offset >= region.offset, offset < end else { continue }
            let inner = Int(offset - region.offset)
            let length = min(maxLength, region.data.count - inner)
            return region.data.subdata(in: inner..<(inner + length))
        }
        return Data()
    }

    func contains(offset: Int64) -> Bool {
        !read(from: offset, maxLength: 1).isEmpty
    }

    func availableCount(from offset: Int64) -> Int {
        for region in regions {
            let end = region.offset + Int64(region.data.count)
            guard offset >= region.offset, offset < end else { continue }
            return region.data.count - Int(offset - region.offset)
        }
        return 0
    }

    private func coalesce() {
        regions.sort { $0.offset < $1.offset }
        var merged: [(offset: Int64, data: Data)] = []
        for region in regions {
            guard let last = merged.last else {
                merged.append(region)
                continue
            }
            let lastEnd = last.offset + Int64(last.data.count)
            if lastEnd >= region.offset {
                let newEnd = max(lastEnd, region.offset + Int64(region.data.count))
                var combined = Data(count: Int(newEnd - last.offset))
                combined.replaceSubrange(0..<last.data.count, with: last.data)
                let inner = Int(region.offset - last.offset)
                combined.replaceSubrange(inner..<(inner + region.data.count), with: region.data)
                merged[merged.count - 1] = (last.offset, combined)
            } else {
                merged.append(region)
            }
        }
        regions = merged
        totalBytes = regions.reduce(0) { $0 + $1.data.count }
    }

    private func trimIfNeeded() {
        guard totalBytes > memoryLimit else { return }
        regions.removeAll { region in
            region.offset > 0 && totalBytes > memoryLimit
        }
        totalBytes = regions.reduce(0) { $0 + $1.data.count }
    }
}

enum ImmichVideoRangePlanner {
    static let firstChunkBytes: Int64 = 512 * 1024
    static let nextChunkBytes: Int64 = 2 * 1024 * 1024

    struct FetchRange: Equatable {
        let start: Int64
        let end: Int64
    }

    struct ParsedResponse {
        let bodyOffset: Int64
        let contentLength: Int64?
        let contentType: String
        let byteRangeAccessSupported: Bool
        let isFullFile: Bool
    }

    static func fetchRange(
        currentOffset: Int64,
        contentLength: Int64?,
        preferFirstChunk: Bool
    ) -> FetchRange? {
        if let contentLength, contentLength > 0, currentOffset >= contentLength {
            return nil
        }

        let chunk = preferFirstChunk && currentOffset == 0 ? firstChunkBytes : nextChunkBytes
        let start = max(currentOffset, 0)
        var end = start + chunk - 1
        if let contentLength, contentLength > 0 {
            end = min(end, contentLength - 1)
        }
        guard end >= start else { return nil }
        return FetchRange(start: start, end: end)
    }

    static func responseLength(for dataRequest: AVAssetResourceLoadingDataRequest, contentLength: Int64?) -> Int {
        if dataRequest.requestsAllDataToEndOfResource {
            if let contentLength, contentLength > 0 {
                return Int(max(contentLength - dataRequest.currentOffset, 0))
            }
            return 1_048_576
        }

        let requestedEnd = dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
        return Int(max(requestedEnd - dataRequest.currentOffset, 0))
    }

    static func isSatisfied(_ dataRequest: AVAssetResourceLoadingDataRequest, contentLength: Int64?) -> Bool {
        if dataRequest.requestsAllDataToEndOfResource {
            guard let contentLength, contentLength > 0 else { return false }
            return dataRequest.currentOffset >= contentLength
        }
        return dataRequest.currentOffset >= dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
    }

    static func isFullyCached(from offset: Int64, cache: ByteRangeCache, contentLength: Int64?) -> Bool {
        guard let contentLength, contentLength > 0 else {
            return false
        }
        return Int64(cache.availableCount(from: offset)) >= contentLength - offset
    }

    static func parseResponse(_ response: HTTPURLResponse, requestedStart: Int64) -> ParsedResponse {
        let mime = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";")
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let contentType = contentType(from: mime)
        let acceptRanges = response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true

        if response.statusCode == 206,
           let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let parsed = parseContentRange(contentRange) {
            return ParsedResponse(
                bodyOffset: parsed.start,
                contentLength: parsed.total,
                contentType: contentType,
                byteRangeAccessSupported: true,
                isFullFile: parsed.start == 0 && parsed.total != nil && parsed.end + 1 == parsed.total
            )
        }

        let length = max(response.expectedContentLength, 0)
        return ParsedResponse(
            bodyOffset: response.statusCode == 200 ? 0 : requestedStart,
            contentLength: length > 0 ? length : nil,
            contentType: contentType,
            byteRangeAccessSupported: acceptRanges,
            isFullFile: response.statusCode == 200
        )
    }

    static func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64?)? {
        let trimmed = value.replacingOccurrences(of: "bytes", with: "").trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "/")
        guard let rangePart = parts.first else { return nil }
        let bounds = rangePart.split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]) else { return nil }
        let total: Int64?
        if parts.count == 2, parts[1] != "*" {
            total = Int64(parts[1])
        } else {
            total = nil
        }
        return (start, end, total)
    }

    static func contentType(from mime: String?) -> String {
        switch mime?.lowercased() {
        case "video/mp4", "video/m4v":
            return AVFileType.mp4.rawValue
        case "video/quicktime":
            return AVFileType.mov.rawValue
        case "video/x-m4v":
            return AVFileType.m4v.rawValue
        default:
            if let mime, let type = UTType(mimeType: mime) {
                return type.identifier
            }
            return AVFileType.mp4.rawValue
        }
    }
}

private final class VideoAssetBuffer {
    let url: URL
    var info: VideoContentInfo?
    let cache = ByteRangeCache()
    var requests: [AVAssetResourceLoadingRequest] = []

    init(url: URL) {
        self.url = url
    }
}

private struct VideoContentInfo {
    var contentLength: Int64
    var contentType: String
    var byteRangeAccessSupported: Bool
}

private struct VideoDownload {
    let originalURL: URL
    let task: URLSessionDataTask
    let requestedStart: Int64
    let requestedEnd: Int64
    var nextWriteOffset: Int64
    var isFullFile: Bool

    func covers(_ offset: Int64) -> Bool {
        if isFullFile {
            return offset >= requestedStart
        }
        return offset >= requestedStart && offset <= requestedEnd
    }
}
