//
//  AssetThumbnailView.swift
//  Immich Gallery
//
//  Created by mensadi-labs on 2025-06-29.
//

import SwiftUI

struct AssetThumbnailView: View {
    let asset: ImmichAsset
    @ObservedObject var assetService: AssetService
    @State private var image: UIImage?
    @State private var placeholder: UIImage?   // instant blur from thumbhash
    @State private var loadingTask: Task<Void, Never>?
    let isFocused: Bool
    var shouldLoadThumbnail = true
    var allowsThumbhashPlaceholder = true
    var showsDateOverlay = true
    var showsStackIndicator = true
    var thumbnailSize: CGFloat = 320
    var thumbnailLoadDelayNanoseconds: UInt64 = 150_000_000
    
    var body: some View {
        ZStack(alignment: .bottom) {
        
             RoundedRectangle(cornerRadius: 12)
                 .fill(Color.gray.opacity(0.3))
                 .frame(width: thumbnailSize, height: thumbnailSize)

             // Instant placeholder decoded from the asset's thumbhash. Shows
             // immediately (no network) and sits behind the real thumbnail,
             // which crossfades in on top once loaded.
             if let placeholder = placeholder {
                 Image(uiImage: placeholder)
                     .resizable()
                     .aspectRatio(contentMode: .fill)
                     .frame(width: thumbnailSize, height: thumbnailSize)
                     .clipped()
                     .cornerRadius(12)
             }

             if let image = image {
                 Image(uiImage: image)
                     .resizable()
                     .aspectRatio(contentMode: .fill)
                     .frame(width: thumbnailSize, height: thumbnailSize)
                     .clipped()
                     .cornerRadius(12)
                     .transition(.opacity)
             } else if placeholder == nil {
                 Image(systemName: "icloud")
                     .font(.system(size: 32))
                     .foregroundColor(.white.opacity(0.35))
                     .frame(width: thumbnailSize, height: thumbnailSize, alignment: .center)
             }
            
            // Video indicator
            if asset.type == .video {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                            .padding(10)
                    }
                    Spacer()
                }
            }


            // Stack indicator. The primary asset represents the hidden members
            // in grids, so keep the count visible without obscuring the photo.
            if showsStackIndicator, let stack = asset.stack, stack.assetCount > 1 {
                VStack {
                    HStack {
                        Label("\(stack.assetCount)", systemImage: "square.stack.3d.up.fill")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.65), in: Capsule())
                            .padding(10)
                        Spacer()
                    }
                    Spacer()
                }
            }
            
            // Favorite heart indicator at bottom left
            if asset.isFavorite {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundColor(.red)
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                            .padding(.leading, 10)
                            .padding(.bottom, showsFocusedDate ? 48 : 10)
                        Spacer()
                    }
                }
            }
            thumbnailFooter
            
        }
        .frame(width: thumbnailSize, height: thumbnailSize)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 15, y: 10)
        .onAppear {
            if allowsThumbhashPlaceholder && placeholder == nil {
                placeholder = ThumbHash.image(fromBase64: asset.thumbhash)
            }
            if shouldLoadThumbnail {
                loadThumbnail()
            }
        }
        .onDisappear {
            // Re-enabled: cancelling loads for tiles scrolled off-screen is what
            // keeps fast scroll from piling up hundreds of in-flight loads.
            cancelLoading()
        }
        .onChange(of: shouldLoadThumbnail) { _, canLoad in
            if canLoad {
                if image == nil {
                    loadThumbnail()
                }
            } else {
                cancelLoading()
            }
        }
    }

    private var showsFocusedDate: Bool {
        showsDateOverlay && isFocused
    }

    @ViewBuilder
    private var thumbnailFooter: some View {
        let duration = asset.displayedVideoDuration
        if duration != nil || showsFocusedDate {
            VStack {
                Spacer()
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    if showsFocusedDate {
                        Text(DateFormatter.formatThumbnailDate(asset.exifInfo?.dateTimeOriginal ?? asset.fileCreatedAt))
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                        Spacer(minLength: 6)
                    } else {
                        Spacer()
                    }

                    if let duration {
                        Text(duration)
                            .font(.system(size: 21, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, showsFocusedDate ? 0 : 7)
                            .padding(.vertical, showsFocusedDate ? 0 : 3)
                            .background {
                                if !showsFocusedDate {
                                    Capsule()
                                        .fill(.black.opacity(0.48))
                                }
                            }
                            .shadow(color: .black.opacity(showsFocusedDate ? 0.55 : 0), radius: 3, y: 1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .padding(.top, showsFocusedDate ? 28 : 8)
                .frame(maxWidth: .infinity)
                .background {
                    if showsFocusedDate {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.62)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
            }
            .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }

    private func loadThumbnail() {
        // Cancel any existing loading task
        loadingTask?.cancel()

        loadingTask = Task {
            // Debounce: a tile that scroll/focus blows past is cancelled in
            // onDisappear before this fires, so we never load tiles the user
            // is racing past.
            if thumbnailLoadDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: thumbnailLoadDelayNanoseconds)
            }
            if Task.isCancelled { return }

            // Hard concurrency cap: even if SwiftUI's nested lazy grids
            // instantiate far more tiles than are visible, at most a handful
            // of loads/decodes run at once, so memory can't spike into a crash.
            await ThumbnailLoadGate.shared.acquire()
            do {
                try Task.checkCancellation()

                let thumbnail = try await ThumbnailCache.shared.getThumbnail(for: asset.id, size: "thumbnail") {
                    // Check cancellation before network request
                    try Task.checkCancellation()
                    // Load from server if not in cache
                    return try await assetService.loadImage(assetId: asset.id, size: "thumbnail")
                }

                // Check cancellation before UI update
                try Task.checkCancellation()

                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.image = thumbnail
                    }
                }
            } catch is CancellationError {
                // Task was cancelled - don't update UI or log error
            } catch {
                print("Failed to load thumbnail for asset \(asset.id): \(error)")
            }
            // Always release the slot, including on cancellation/error paths.
            await ThumbnailLoadGate.shared.release()
        }
    }
    
    private func cancelLoading() {
        loadingTask?.cancel()
        loadingTask = nil
    }
    
    
}

#Preview {
    let userManager = UserManager()
    let networkService = NetworkService(userManager: userManager)
    let assetService = AssetService(networkService: networkService)
    
    // Create a mock asset for preview
    let mockAsset = ImmichAsset(
        id: "mock-id",
        deviceAssetId: "mock-device-id",
        deviceId: "mock-device",
        ownerId: "mock-owner",
        libraryId: nil,
        type: .video,
        originalPath: "/mock/path",
        originalFileName: "mock.jpg",
        originalMimeType: "image/jpeg",
        resized: false,
        thumbhash: nil,
        fileModifiedAt: "2023-01-01 00:00:00",
        fileCreatedAt: "2023-12-25T14:30:00Z",
        localDateTime: "2023-01-01",
        updatedAt: "2023-01-01",
        isFavorite: true,
        isArchived: false,
        isOffline: false,
        isTrashed: false,
        checksum: "mock-checksum",
        duration: "00:01:23.000",
        hasMetadata: false,
        livePhotoVideoId: nil,
        people: [],
        visibility: "public",
        duplicateId: nil,
        exifInfo: nil
    )
    
    AssetThumbnailView(asset: mockAsset, assetService: assetService, isFocused: false)
} 
