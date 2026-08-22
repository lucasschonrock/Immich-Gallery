//
//  SimpleVideoPlayerView.swift
//  Immich Gallery
//
//  Created by Codex on 2024-09-19.
//

import SwiftUI
import AVKit
import Combine

/// Lightweight video player that relies on AVPlayer without custom observers.
struct SimpleVideoPlayerView: View {
    let asset: ImmichAsset
    @ObservedObject var assetService: AssetService
    @ObservedObject var authenticationService: AuthenticationService

    @StateObject private var playback = SimpleVideoPlaybackModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = playback.player {
                ImprovedVideoPlayerView(player: player)
                    .ignoresSafeArea()
            }

            if playback.isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.3)
                    Text("Loading video…")
                        .foregroundColor(.white.opacity(0.8))
                        .font(.title3)
                }
                .allowsHitTesting(false)
            }

            if let message = playback.errorMessage {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 60))
                        .foregroundColor(.orange)
                    Text("Unable to play video")
                        .font(.title2)
                        .foregroundColor(.white)
                    Text(message)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Try Again") {
                        Task {
                            await playback.start(
                                asset: asset,
                                assetService: assetService,
                                authenticationService: authenticationService,
                                force: true
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .task {
            await playback.start(
                asset: asset,
                assetService: assetService,
                authenticationService: authenticationService
            )
        }
        .onDisappear {
            playback.stop()
        }
    }
}

@MainActor
final class SimpleVideoPlaybackModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?

    let videoLoader = ImmichVideoResourceLoader()
    private var observers = Set<AnyCancellable>()
    private var hasAttemptedLoad = false
    private var loadGeneration = 0

    func start(
        asset: ImmichAsset,
        assetService: AssetService,
        authenticationService: AuthenticationService,
        force: Bool = false
    ) async {
        guard !hasAttemptedLoad || force else { return }

        hasAttemptedLoad = true
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        videoLoader.authenticationService = authenticationService

        do {
            let videoURL = try await assetService.loadVideoURL(asset: asset)
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            videoLoader.prefetch(videoURL)

            let proxyURL = ImmichVideoResourceLoader.proxyURL(for: videoURL)
            let urlAsset = AVURLAsset(url: proxyURL)
            urlAsset.resourceLoader.setDelegate(videoLoader, queue: videoLoader.queue)

            let playerItem = AVPlayerItem(asset: urlAsset)
            playerItem.preferredForwardBufferDuration = 1
            playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true

            let player = AVPlayer(playerItem: playerItem)
            player.automaticallyWaitsToMinimizeStalling = false
            guard generation == loadGeneration else { return }
            observe(player: player, item: playerItem)

            self.player = player
            player.play()
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func stop() {
        loadGeneration += 1
        observers.removeAll()
        player?.pause()
        player = nil
        hasAttemptedLoad = false
        isLoading = true
        errorMessage = nil
    }

    private func observe(player: AVPlayer, item: AVPlayerItem) {
        observers.removeAll()

        item.publisher(for: \.status, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    self.isLoading = false
                    player.play()
                case .failed:
                    self.errorMessage = item?.error?.localizedDescription ?? "This video is not playable."
                    self.isLoading = false
                default:
                    break
                }
            }
            .store(in: &observers)

        player.publisher(for: \.timeControlStatus, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                if status == .playing {
                    self?.isLoading = false
                }
            }
            .store(in: &observers)
    }
}
