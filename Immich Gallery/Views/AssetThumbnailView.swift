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
    @ObservedObject private var thumbnailCache = ThumbnailCache.shared
    @State private var image: UIImage?
    @State private var placeholder: UIImage?   // instant blur from thumbhash
    @State private var isLoading = true
    @State private var loadingTask: Task<Void, Never>?
    let isFocused: Bool
    
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
        
             RoundedRectangle(cornerRadius: 12)
                 .fill(Color.gray.opacity(0.3))
                 .frame(width: 320, height: 320)

             // Instant placeholder decoded from the asset's thumbhash. Shows
             // immediately (no network) and sits behind the real thumbnail,
             // which crossfades in on top once loaded.
             if let placeholder = placeholder {
                 Image(uiImage: placeholder)
                     .resizable()
                     .aspectRatio(contentMode: .fill)
                     .frame(width: 320, height: 320)
                     .clipped()
                     .cornerRadius(12)
             }

             if let image = image {
                 Image(uiImage: image)
                     .resizable()
                     .aspectRatio(contentMode: .fill)
                     .frame(width: 320, height: 320)
                     .clipped()
                     .cornerRadius(12)
                     .transition(.opacity)
             } else if placeholder == nil && isLoading {
                 ProgressView()
                     .scaleEffect(1.2)
             } else if placeholder == nil {
                 Image(systemName: "photo")
                     .font(.system(size: 40))
                     .foregroundColor(.gray)
             }
            
            // Video indicator
            if asset.type == .video {
                // Play button at top right
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.white)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.5), radius: 5, x: 0, y: 2)
                            .padding(8)
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
                            .padding(8)
                        Spacer()
                    }
                }
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(DateFormatter.formatSpecificISO8601(asset.exifInfo?.dateTimeOriginal ?? asset.fileCreatedAt, includeTime: false))
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.4))
            )
            
        }
        .frame(width: 320, height: 320)
        .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 15, y: 10)
        .onAppear {
            if placeholder == nil {
                placeholder = ThumbHash.image(fromBase64: asset.thumbhash)
            }
            loadThumbnail()
        }
        .onDisappear {
            // Re-enabled: cancelling loads for tiles scrolled off-screen is what
            // keeps fast scroll from piling up hundreds of in-flight loads. Paired
            // with the debounce below and the thumbhash placeholder, the tile still
            // shows content instantly, so cancellation no longer leaves blanks.
            cancelLoading()
        }
    }

    private func loadThumbnail() {
        // Cancel any existing loading task
        loadingTask?.cancel()

        loadingTask = Task {
            // Debounce: a tile that scroll/focus blows past is cancelled in
            // onDisappear before this fires, so we never load tiles the user
            // is racing past. The thumbhash placeholder covers this window.
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms settle
            if Task.isCancelled { return }

            // Hard concurrency cap: even if SwiftUI's nested lazy grids
            // instantiate far more tiles than are visible, at most a handful
            // of loads/decodes run at once, so memory can't spike into a crash.
            await ThumbnailLoadGate.shared.acquire()
            do {
                try Task.checkCancellation()

                let thumbnail = try await thumbnailCache.getThumbnail(for: asset.id, size: "thumbnail") {
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
                    self.isLoading = false
                }
            } catch is CancellationError {
                // Task was cancelled - don't update UI or log error
            } catch {
                print("Failed to load thumbnail for asset \(asset.id): \(error)")
                await MainActor.run {
                    self.isLoading = false
                }
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
        duration: nil,
        hasMetadata: false,
        livePhotoVideoId: nil,
        people: [],
        visibility: "public",
        duplicateId: nil,
        exifInfo: nil
    )
    
    AssetThumbnailView(asset: mockAsset, assetService: assetService, isFocused: false)
} 
