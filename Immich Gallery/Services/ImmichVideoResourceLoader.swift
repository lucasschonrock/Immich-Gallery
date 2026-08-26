//
//  ImmichVideoResourceLoader.swift
//  Immich Gallery
//
//  AVPlayer cannot present a client certificate, so mTLS playback URLs are
//  rewritten to a custom scheme and this delegate performs the real requests
//  over an mTLS-capable URLSession. AVPlayer reads a resource-loader asset in
//  small (~64 KB) blocks, so to avoid a round trip per block we fetch the file
//  in large aligned windows, read a few ahead, and serve every block from that
//  cache — throughput then tracks bandwidth instead of latency.
//

import AVFoundation
import Foundation
import UniformTypeIdentifiers

final class ImmichVideoResourceLoader: NSObject, ObservableObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    static let urlScheme = "immich-video"
    private static let originalSchemeQueryItem = "immichOriginalScheme"

    let queue = DispatchQueue(label: "immich.video.resource-loader")

    weak var authenticationService: AuthenticationService?

    // AVPlayer reads a resource-loader asset in ~64 KB blocks. Fetch the file in
    // large aligned windows and read a few ahead so each block is served from
    // memory instead of paying a network round trip.
    private let windowSize: Int64 = 4 * 1024 * 1024
    private let readAheadWindows: Int64 = 8
    private let maxCachedWindows = 32

    private var didCreateSession = false
    private lazy var session: URLSession = {
        didCreateSession = true
        let configuration = URLSessionConfiguration.default
        configuration.networkServiceType = .avStreaming
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = true

        let delegateQueue = OperationQueue()
        delegateQueue.name = "immich.video.session"
        delegateQueue.underlyingQueue = queue

        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    private var origin: URL?
    private var contentInfo: VideoContentInfo?
    private var windows: [Int64: CacheWindow] = [:]
    private var windowForTask: [Int: Int64] = [:]
    private var pending: [AVAssetResourceLoadingRequest] = []

    deinit {
        if didCreateSession { session.invalidateAndCancel() }
    }

    /// Breaks the URLSession -> delegate retain cycle. Call when the owner is torn down.
    func invalidate() {
        if didCreateSession { session.invalidateAndCancel() }
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

        origin = originalURL
        pending.append(loadingRequest)
        servePending()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        pending.removeAll { $0 === loadingRequest }
    }

    private func servePending() {
        guard origin != nil else { return }

        var stillPending: [AVAssetResourceLoadingRequest] = []
        for request in pending where !request.isCancelled && !request.isFinished {
            if let info = contentInfo {
                fillContentInfo(request, info: info)
            }

            guard let dataRequest = request.dataRequest else {
                // Content-information only: done as soon as the headers are known.
                if contentInfo != nil {
                    request.finishLoading()
                } else {
                    ensureWindow(0)
                    stillPending.append(request)
                }
                continue
            }

            if serveData(dataRequest) {
                request.finishLoading()
            } else {
                stillPending.append(request)
            }
        }
        pending = stillPending
        evictBehindConsumers()
    }

    /// Feeds all currently cached bytes to the request. Returns true once satisfied.
    private func serveData(_ dataRequest: AVAssetResourceLoadingDataRequest) -> Bool {
        let end = requestEnd(for: dataRequest)

        while true {
            let offset = dataRequest.currentOffset
            if let end, offset >= end { break }
            if let total = contentInfo?.total, offset >= total { break }

            guard let window = windows[offset / windowSize] else { break }
            let bufferedEnd = window.base + Int64(window.data.count)
            guard offset < bufferedEnd else { break }

            var length = bufferedEnd - offset
            if let end { length = min(length, end - offset) }
            let start = Int(offset - window.base)
            dataRequest.respond(with: window.data.subdata(in: start..<(start + Int(length))))
        }

        ensureReadAhead(from: dataRequest.currentOffset / windowSize)

        if dataRequest.requestsAllDataToEndOfResource {
            if let total = contentInfo?.total { return dataRequest.currentOffset >= total }
            return false
        }
        return dataRequest.currentOffset >= dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
    }

    private func requestEnd(for dataRequest: AVAssetResourceLoadingDataRequest) -> Int64? {
        if dataRequest.requestsAllDataToEndOfResource {
            return contentInfo?.total
        }
        return dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
    }

    private func ensureReadAhead(from index: Int64) {
        var i = max(index, 0)
        let last = index + readAheadWindows
        while i <= last {
            if let total = contentInfo?.total, i * windowSize >= total { break }
            ensureWindow(i)
            i += 1
        }
    }

    private func ensureWindow(_ index: Int64) {
        guard index >= 0, let origin else { return }
        if let total = contentInfo?.total, index * windowSize >= total { return }
        if let existing = windows[index], existing.isComplete || existing.task != nil { return }

        let window: CacheWindow
        if let existing = windows[index] {
            window = existing
        } else {
            window = CacheWindow(base: index * windowSize)
            windows[index] = window
        }

        let start = window.base + Int64(window.data.count)
        var end = window.base + windowSize - 1
        if let total = contentInfo?.total { end = min(end, total - 1) }
        guard end >= start else {
            window.isComplete = true
            return
        }

        var request = URLRequest(url: origin)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        for (header, value) in authenticationService?.getAuthHeaders() ?? [:] {
            request.setValue(value, forHTTPHeaderField: header)
        }

        // TEMP VIDEO-DIAG
        VideoPlaybackLog.message("[VIDEO-DIAG] loader → Range=bytes=\(start)-\(end) window=\(index)")

        let task = session.dataTask(with: request)
        window.task = task
        windowForTask[task.taskIdentifier] = index
        task.resume()
    }

    private func evictBehindConsumers() {
        guard windows.count > maxCachedWindows else { return }
        guard let minOffset = pending.compactMap({ $0.dataRequest?.currentOffset }).min() else { return }

        let behind = windows.values
            .filter { $0.task == nil && ($0.base + windowSize) <= minOffset }
            .sorted { $0.base < $1.base }
        var overflow = windows.count - maxCachedWindows
        for window in behind where overflow > 0 {
            windows.removeValue(forKey: window.base / windowSize)
            overflow -= 1
        }
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
        guard let index = windowForTask[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            failWindow(index, error: Self.urlError)
            return
        }

        let requestedRange = dataTask.originalRequest?.value(forHTTPHeaderField: "Range") ?? "none"
        let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range") ?? "none"
        let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length") ?? "\(httpResponse.expectedContentLength)"
        let acceptRanges = httpResponse.value(forHTTPHeaderField: "Accept-Ranges") ?? "none"
        // TEMP VIDEO-DIAG
        VideoPlaybackLog.message("[VIDEO-DIAG] loader ← \(httpResponse.statusCode) Range=\(requestedRange) Content-Range=\(contentRange) Content-Length=\(contentLength) Accept-Ranges=\(acceptRanges)")

        if requestedRange != "none", httpResponse.statusCode == 200 {
            VideoPlaybackLog.message("[VIDEO-DIAG] loader WARNING: Range was ignored (200 OK)")
            if let requested = ImmichVideoRangePlanner.parseRangeHeader(requestedRange), requested.start != 0 {
                completionHandler(.cancel)
                failWindow(index, error: NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorBadServerResponse,
                    userInfo: [NSLocalizedDescriptionKey: "Server ignored byte range request"]
                ))
                return
            }
        }
        if httpResponse.statusCode == 206,
           let requested = ImmichVideoRangePlanner.parseRangeHeader(requestedRange),
           let received = ImmichVideoRangePlanner.parseContentRange(contentRange),
           requested.start != received.start {
            VideoPlaybackLog.message("[VIDEO-DIAG] loader WARNING: Content-Range start \(received.start) != requested \(requested.start)")
            completionHandler(.cancel)
            failWindow(index, error: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorBadServerResponse,
                userInfo: [NSLocalizedDescriptionKey: "Byte range mismatch"]
            ))
            return
        }

        if httpResponse.statusCode == 416 {
            // Past EOF: this window has no bytes to deliver.
            completionHandler(.cancel)
            windowForTask.removeValue(forKey: dataTask.taskIdentifier)
            if let window = windows[index] {
                window.task = nil
                window.isComplete = true
            }
            servePending()
            return
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            completionHandler(.cancel)
            failWindow(index, error: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorBadServerResponse,
                userInfo: [NSLocalizedDescriptionKey: "Video request failed (\(httpResponse.statusCode))"]
            ))
            return
        }

        if contentInfo == nil {
            contentInfo = Self.parseContentInfo(from: httpResponse)
        }
        servePending()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let index = windowForTask[dataTask.taskIdentifier], let window = windows[index] else { return }
        window.data.append(data)

        // Guard against a server that ignores Range and streams the whole file.
        if Int64(window.data.count) > windowSize {
            window.isComplete = true
            window.task = nil
            windowForTask.removeValue(forKey: dataTask.taskIdentifier)
            dataTask.cancel()
        }

        servePending()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let index = windowForTask.removeValue(forKey: task.taskIdentifier) else { return }
        windows[index]?.task = nil

        if let error, (error as NSError).code != NSURLErrorCancelled {
            failWindow(index, error: error)
            return
        }

        windows[index]?.isComplete = true
        servePending()
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

    private func failWindow(_ index: Int64, error: Error) {
        print("❌ Video loader failed: \(error)")
        if let window = windows[index] {
            if let identifier = window.task?.taskIdentifier {
                windowForTask.removeValue(forKey: identifier)
            }
            window.task?.cancel()
        }
        windows.removeValue(forKey: index)

        // Only fail requests actually blocked on this window; speculative read-ahead
        // failures are dropped so playback can retry them on demand.
        let base = index * windowSize
        let end = base + windowSize
        var stillPending: [AVAssetResourceLoadingRequest] = []
        for request in pending where !request.isFinished {
            let blockedOnData = request.dataRequest.map { $0.currentOffset >= base && $0.currentOffset < end } ?? false
            let blockedOnInfo = request.dataRequest == nil && contentInfo == nil && index == 0
            if blockedOnData || blockedOnInfo {
                request.finishLoading(with: error)
            } else {
                stillPending.append(request)
            }
        }
        pending = stillPending
        servePending()
    }

    private func fillContentInfo(_ request: AVAssetResourceLoadingRequest, info: VideoContentInfo) {
        guard let infoRequest = request.contentInformationRequest else { return }
        infoRequest.contentType = info.contentType
        infoRequest.isByteRangeAccessSupported = info.rangesSupported
        if let total = info.total, total > 0 {
            infoRequest.contentLength = total
        }
    }

    private static func parseContentInfo(from response: HTTPURLResponse) -> VideoContentInfo {
        let mime = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";")
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let contentType = ImmichVideoRangePlanner.contentType(from: mime)
        let rangesSupported = response.statusCode == 206
            || response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true

        var total: Int64?
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let parsed = ImmichVideoRangePlanner.parseContentRange(contentRange) {
            total = parsed.total
        } else if response.statusCode == 200, response.expectedContentLength > 0 {
            total = response.expectedContentLength
        }
        return VideoContentInfo(total: total, contentType: contentType, rangesSupported: rangesSupported)
    }

    private static var urlError: NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)
    }
}

private final class CacheWindow {
    let base: Int64
    var data = Data()
    var isComplete = false
    var task: URLSessionDataTask?

    init(base: Int64) {
        self.base = base
    }
}

private struct VideoContentInfo {
    let total: Int64?
    let contentType: String
    let rangesSupported: Bool
}

enum ImmichVideoRangePlanner {
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

    /// Parses a request `Range` header such as `bytes=123-456` or `bytes=123-`.
    static func parseRangeHeader(_ value: String) -> (start: Int64, end: Int64?)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let specStart = trimmed.lowercased().range(of: "bytes=") else { return nil }
        let spec = trimmed[specStart.upperBound...]
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let start = Int64(parts.first ?? "") else { return nil }
        let end: Int64?
        if parts.count == 2, !parts[1].isEmpty {
            end = Int64(parts[1])
        } else {
            end = nil
        }
        return (start, end)
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
