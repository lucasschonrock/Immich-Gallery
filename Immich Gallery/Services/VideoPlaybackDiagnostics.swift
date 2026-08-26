//
//  VideoPlaybackDiagnostics.swift
//  Immich Gallery
//
//  Optional AVPlayer buffer / access-log traces. Off by default.
//

import AVFoundation
import Combine
import Foundation

enum VideoPlaybackLog {
    static let isEnabled = false

    static func message(_ line: String) {
        guard isEnabled else { return }
        print(line)
    }
}

final class VideoPlaybackDiagnostics {
    private var observers = Set<AnyCancellable>()
    private var timer: AnyCancellable?
    private var lastAccessLogEventCount = 0
    private var lastErrorLogEventCount = 0
    private var stallCount = 0
    private weak var player: AVPlayer?
    private weak var item: AVPlayerItem?

    private var lastMediaTime: Double = 0
    private var lastWallTime: TimeInterval = 0
    private var onExplicitSeek: (() -> Void)?
    private var seekObserver: Any?

    func attach(player: AVPlayer, item: AVPlayerItem, onExplicitSeek: (() -> Void)? = nil) {
        stop()
        guard VideoPlaybackLog.isEnabled else { return }
        self.player = player
        self.item = item
        self.onExplicitSeek = onExplicitSeek

        item.publisher(for: \.isPlaybackBufferEmpty, options: [.new])
            .sink { [weak self] empty in
                if empty {
                    self?.stallCount += 1
                    self?.log(reason: "buffer-empty")
                }
            }
            .store(in: &observers)

        item.publisher(for: \.isPlaybackLikelyToKeepUp, options: [.new])
            .sink { [weak self] keepUp in
                if !keepUp {
                    self?.log(reason: "not-likely-to-keep-up")
                }
            }
            .store(in: &observers)

        player.publisher(for: \.timeControlStatus, options: [.new])
            .sink { [weak self] status in
                if status == .waitingToPlayAtSpecifiedRate {
                    self?.log(reason: "waiting")
                }
            }
            .store(in: &observers)

        NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled, object: item)
            .sink { [weak self] _ in
                self?.stallCount += 1
                self?.log(reason: "stalled-notification")
            }
            .store(in: &observers)

        timer = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.log(reason: "tick")
            }

        lastMediaTime = CMTimeGetSeconds(item.currentTime())
        lastWallTime = ProcessInfo.processInfo.systemUptime
        seekObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.detectExplicitSeek(time)
        }
    }

    func stop() {
        observers.removeAll()
        timer?.cancel()
        timer = nil
        if let seekObserver, let player {
            player.removeTimeObserver(seekObserver)
        }
        seekObserver = nil
        onExplicitSeek = nil
        player = nil
        item = nil
        lastAccessLogEventCount = 0
        lastErrorLogEventCount = 0
        stallCount = 0
        lastMediaTime = 0
        lastWallTime = 0
    }

    private func detectExplicitSeek(_ time: CMTime) {
        let media = CMTimeGetSeconds(time)
        let wall = ProcessInfo.processInfo.systemUptime
        let previousMedia = lastMediaTime
        let previousWall = lastWallTime
        lastMediaTime = media
        lastWallTime = wall
        guard previousWall > 0, media.isFinite, previousMedia.isFinite else { return }
        let mediaDelta = media - previousMedia
        let wallDelta = wall - previousWall
        guard abs(mediaDelta) > 2, abs(mediaDelta) > wallDelta + 1.5 else { return }
        VideoPlaybackLog.message(String(format: "[VIDEO-DIAG] SEEK source=explicitPlayerSeek mediaDelta=%.2fs", mediaDelta))
        onExplicitSeek?()
    }

    private func log(reason: String) {
        guard let player, let item else { return }

        let current = CMTimeGetSeconds(item.currentTime())
        let duration = CMTimeGetSeconds(item.duration)
        let ahead = Self.bufferedSecondsAhead(of: item.currentTime(), loaded: item.loadedTimeRanges)
        let loadedDescription = item.loadedTimeRanges.map { value in
            let range = value.timeRangeValue
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(range.start + range.duration)
            return String(format: "%.1f-%.1f", start, end)
        }.joined(separator: ",")

        let waiting = player.reasonForWaitingToPlay?.rawValue ?? "none"
        VideoPlaybackLog.message(String(
            format: "[VIDEO-DIAG] [%@] t=%.1fs dur=%@ ahead=%.1fs empty=%@ full=%@ keepUp=%@ rate=%.2f control=%@ waiting=%@ stalls=%d loaded=[%@]",
            reason,
            current.isFinite ? current : -1,
            duration.isFinite ? String(format: "%.1f", duration) : "?",
            ahead,
            item.isPlaybackBufferEmpty ? "Y" : "n",
            item.isPlaybackBufferFull ? "Y" : "n",
            item.isPlaybackLikelyToKeepUp ? "Y" : "n",
            player.rate,
            Self.timeControlName(player.timeControlStatus),
            waiting,
            stallCount,
            loadedDescription.isEmpty ? "none" : loadedDescription
        ))

        logAccessLogIfNeeded(item)
        logErrorLogIfNeeded(item)
    }

    private func logAccessLogIfNeeded(_ item: AVPlayerItem) {
        guard let events = item.accessLog()?.events, events.count != lastAccessLogEventCount || events.last != nil else { return }
        lastAccessLogEventCount = events.count
        guard let event = events.last else { return }

        let observedMbps = event.observedBitrate / 1_000_000
        let indicatedMbps = event.indicatedBitrate / 1_000_000
        let indicatedAvgMbps = event.indicatedAverageBitrate / 1_000_000
        let observedMaxMbps = event.observedMaxBitrate / 1_000_000
        let mb = Double(event.numberOfBytesTransferred) / 1_000_000
        VideoPlaybackLog.message(String(
            format: "[VIDEO-DIAG] accessLog observed=%.1fMbps indicated=%.1fMbps indicatedAvg=%.1fMbps observedMax=%.1fMbps stalls=%ld mediaReqs=%ld bytes=%.1fMB transfer=%.2fs droppedFrames=%ld type=%@ uri=%@",
            observedMbps,
            indicatedMbps,
            indicatedAvgMbps,
            observedMaxMbps,
            event.numberOfStalls,
            event.numberOfMediaRequests,
            mb,
            event.transferDuration,
            event.numberOfDroppedVideoFrames,
            event.playbackType ?? "?",
            event.uri ?? "?"
        ))
    }

    private func logErrorLogIfNeeded(_ item: AVPlayerItem) {
        guard let events = item.errorLog()?.events, events.count > lastErrorLogEventCount else { return }
        let newEvents = events.suffix(from: lastErrorLogEventCount)
        lastErrorLogEventCount = events.count
        for event in newEvents {
            VideoPlaybackLog.message("[VIDEO-DIAG] errorLog status=\(event.errorStatusCode) domain=\(event.errorDomain) comment=\(event.errorComment ?? "") uri=\(event.uri ?? "")")
        }
    }

    static func bufferedSecondsAhead(of current: CMTime, loaded: [NSValue]) -> Double {
        let currentSeconds = CMTimeGetSeconds(current)
        guard currentSeconds.isFinite else { return 0 }

        var ahead = 0.0
        for value in loaded {
            let range = value.timeRangeValue
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(range.start + range.duration)
            guard start.isFinite, end.isFinite else { continue }
            if currentSeconds >= start && currentSeconds <= end {
                ahead = max(ahead, end - currentSeconds)
            } else if start > currentSeconds {
                ahead = max(ahead, end - currentSeconds)
            }
        }
        return ahead
    }

    private static func timeControlName(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: return "paused"
        case .waitingToPlayAtSpecifiedRate: return "waiting"
        case .playing: return "playing"
        @unknown default: return "unknown"
        }
    }
}
