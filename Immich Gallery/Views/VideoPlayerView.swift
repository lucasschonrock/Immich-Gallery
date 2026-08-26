//
//  VideoPlayerView.swift
//  Immich Gallery
//
//  Created by mensadi-labs on 2025-06-29.
//

import SwiftUI
import AVKit
import Combine


class PlayerManager: NSObject, ObservableObject {
    @Published var player = AVPlayer()
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var isReadyToPlay = false
    @Published var isPlaybackBufferEmpty = false
    @Published var playbackRate: Float = 0.0
    
    private var playerItem: AVPlayerItem?
    private var cancellables = Set<AnyCancellable>()
    private let videoLoader = ImmichVideoResourceLoader()
    private let playbackProxy = ImmichVideoPlaybackProxy()
    private let diagnostics = VideoPlaybackDiagnostics()
    
    let asset: ImmichAsset
    let assetService: AssetService
    let authenticationService: AuthenticationService
    
    init(asset: ImmichAsset, assetService: AssetService, authenticationService: AuthenticationService) {
        self.asset = asset
        self.assetService = assetService
        self.authenticationService = authenticationService
        super.init()
        videoLoader.authenticationService = authenticationService
    }
    
    func initializePlayer() {
        isLoading = true
        errorMessage = nil
        isReadyToPlay = false
        
        print("🎬 Loading video for asset: \(asset.id)")
        
        Task {
            do {
                let videoURL = try await assetService.loadVideoURL(asset: asset)
                print("🎥 Video URL created: \(videoURL)")
                await self.setupPlayer(with: videoURL)
            } catch {
                print("❌ Failed to load video: \(error)")
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    @MainActor
    private func setupPlayer(with url: URL) async {
        let asset = await playbackProxy.makePlaybackAsset(
            origin: url,
            authenticationService: authenticationService,
            loader: videoLoader
        )
        
        // Create player item with the asset
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 30
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        self.playerItem = playerItem
        diagnostics.attach(player: player, item: playerItem) { [weak self] in
            self?.playbackProxy.notifyExplicitSeek()
        }
        
        // Watch for buffer issues (from Medium article)
        playerItem.publisher(for: \.isPlaybackBufferEmpty)
            .sink { [weak self] bufferEmpty in
                DispatchQueue.main.async {
                    self?.isPlaybackBufferEmpty = bufferEmpty
                    if bufferEmpty {
                        print("⚠️ Buffer is empty. Expect a hiccup on screen.")
                    }
                }
            }
            .store(in: &cancellables)
        
        // Keep an eye on playback rate (from Medium article)
        player.publisher(for: \.rate)
            .sink { [weak self] rate in
                DispatchQueue.main.async {
                    self?.playbackRate = rate
                    print("▶️ Playback rate: \(rate)")
                }
            }
            .store(in: &cancellables)
        
        // Observe overall status (from Medium article)
        playerItem.publisher(for: \.status, options: [.initial, .new])
            .sink { [weak self] status in
                DispatchQueue.main.async {
                    self?.handlePlayerItemStatusChange(status)
                }
            }
            .store(in: &cancellables)
        
        // Optionally track if playback stalls (from Medium article)
        NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled, object: playerItem)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    print("⚠️ Playback stalled. Possibly a slow connection.")
                    self?.errorMessage = "Playback stalled - check your connection"
                }
            }
            .store(in: &cancellables)
        
        // Add error observer
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .sink { [weak self] notification in
                DispatchQueue.main.async {
                    self?.handlePlaybackFailure(notification)
                }
            }
            .store(in: &cancellables)
        
        // Replace current item
        player.replaceCurrentItem(with: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        
        print("▶️ Video player setup completed")
    }
    
    private func handlePlayerItemStatusChange(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            print("✅ Ready to play!")
            isReadyToPlay = true
            isLoading = false
            player.play()
        case .failed:
            print("❌ Something went wrong with playback.")
            isLoading = false
            errorMessage = "Video failed to load"
        case .unknown:
            print("⏳ Status changed: \(status.rawValue)")
        @unknown default:
            break
        }
    }
    
    private func handlePlaybackFailure(_ notification: Notification) {
        if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
            print("❌ Player item failed to play to end: \(error)")
            errorMessage = "Video playback failed: \(error.localizedDescription)"
            isLoading = false
        }
    }
    
    func cleanup() {
        cancellables.removeAll()
        diagnostics.stop()
        NotificationCenter.default.removeObserver(self)
        
        player.pause()
        player = AVPlayer()
        playerItem = nil
        playbackProxy.stop()
        
        print("🧹 Video player cleaned up")
    }
}

// MARK: - Main Video Player View
struct VideoPlayerView: View {
    let asset: ImmichAsset
    @ObservedObject var assetService: AssetService
    @ObservedObject var authenticationService: AuthenticationService
    @StateObject private var playerManager: PlayerManager
    
    init(asset: ImmichAsset, assetService: AssetService, authenticationService: AuthenticationService) {
        self.asset = asset
        self.assetService = assetService
        self.authenticationService = authenticationService
        self._playerManager = StateObject(wrappedValue: PlayerManager(asset: asset, assetService: assetService, authenticationService: authenticationService))
    }
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            if playerManager.isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text("Loading video...")
                        .foregroundColor(.white)
                        .font(.title2)
                }
            } else if let errorMessage = playerManager.errorMessage {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 60))
                        .foregroundColor(.orange)
                    Text("Error Loading Video")
                        .font(.title)
                        .foregroundColor(.white)
                    Text(errorMessage)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Retry") {
                        playerManager.initializePlayer()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if playerManager.isReadyToPlay {
                ImprovedVideoPlayerView(player: playerManager.player)
                    .ignoresSafeArea()
                
                // Optional: Show buffer status overlay
                if playerManager.isPlaybackBufferEmpty {
                    let _ = print(playerManager.isPlaybackBufferEmpty)
                    VStack {
                        Spacer()
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            Text("Buffering...")
                                .foregroundColor(.white)
                                .font(.caption)
                        }
                        .padding()
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(8)
                        .padding(.bottom, 50)
                    }
                }
            }
        }
        .onAppear {
            playerManager.initializePlayer()
        }
        .onDisappear {
            playerManager.cleanup()
        }
    }
}

// MARK: - Improved Video Player for tvOS
struct ImprovedVideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        
        // Configure for better tvOS experience
        controller.allowsPictureInPicturePlayback = true
        
        // Set up custom styling to avoid layout conflicts
        controller.view.backgroundColor = UIColor.black
        
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Only update player if it's different to avoid unnecessary reloads
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}
