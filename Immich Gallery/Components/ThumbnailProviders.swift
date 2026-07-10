//
//  ThumbnailProviders.swift
//  Immich Gallery
//
//  Created by mensadi-labs on 2025-09-04.
//

import SwiftUI

private let animatedThumbnailLimit = 3

private func loadSingleThumbnail(
    assetService: AssetService,
    thumbnailCache: ThumbnailCache,
    personId: String? = nil,
    tagId: String? = nil,
    folderPath: String? = nil
) async -> UIImage? {
    do {
        let searchResult = try await assetService.fetchAssets(
            page: 1,
            limit: 1,
            personId: personId,
            tagId: tagId,
            folderPath: folderPath
        )
        guard let asset = searchResult.assets.first(where: { $0.type == .image }) else {
            return nil
        }

        return try await thumbnailCache.getThumbnail(for: asset.id, size: "thumbnail") {
            try await assetService.loadImage(assetId: asset.id, size: "thumbnail")
        }
    } catch {
        return nil
    }
}

// MARK: - Album Thumbnail Provider
class AlbumThumbnailProvider: ThumbnailProvider {
    private let albumService: AlbumService
    private let assetService: AssetService
    private let thumbnailCache = ThumbnailCache.shared
    
    init(albumService: AlbumService, assetService: AssetService) {
        self.albumService = albumService
        self.assetService = assetService
    }
    
    func loadThumbnails(for item: GridDisplayable) async -> [UIImage] {
        guard let album = item as? ImmichAlbum else { return [] }
        guard album.id != "smart_locked" else { return [] }
        
        if shouldUseStaticThumbnail(),
           let staticThumbnail = await loadStaticThumbnail(for: album) {
            return [staticThumbnail]
        }
        
        return await loadAnimatedThumbnails(for: album)
    }
    
    private func shouldUseStaticThumbnail() -> Bool {
        return !UserDefaults.standard.enableThumbnailAnimation
    }
    
    private func loadStaticThumbnail(for album: ImmichAlbum) async -> UIImage? {
        guard let thumbnailId = album.albumThumbnailAssetId, !thumbnailId.isEmpty else {
            return nil
        }
        
        do {
            return try await thumbnailCache.getThumbnail(for: thumbnailId, size: "thumbnail") {
                try await self.assetService.loadImage(assetId: thumbnailId, size: "thumbnail")
            }
        } catch {
            print("Failed to load static thumbnail for album \(album.id): \(error)")
            return nil
        }
    }
    
    private func loadAnimatedThumbnails(for album: ImmichAlbum) async -> [UIImage] {
        do {
            let albumProvider = AlbumAssetProvider(assetService: assetService, albumId: album.id)
            let searchResult = try await albumProvider.fetchAssets(page: 1, limit: animatedThumbnailLimit)
            let imageAssets = searchResult.assets.filter { $0.type == .image }
            
            var loadedThumbnails: [UIImage] = []
            
            for asset in imageAssets.prefix(animatedThumbnailLimit) {
                do {
                    let thumbnail = try await thumbnailCache.getThumbnail(for: asset.id, size: "thumbnail") {
                        try await self.assetService.loadImage(assetId: asset.id, size: "thumbnail")
                    }
                    if let thumbnail = thumbnail {
                        loadedThumbnails.append(thumbnail)
                    }
                } catch {
                    print("Failed to load thumbnail for asset \(asset.id): \(error)")
                }
            }
            
            return loadedThumbnails
        } catch {
            print("Failed to fetch assets for album \(album.id): \(error)")
            return []
        }
    }

    func loadCoverThumbnail(for album: ImmichAlbum) async -> UIImage? {
        guard album.id != "smart_locked" else { return nil }

        if let staticThumbnail = await loadStaticThumbnail(for: album) {
            return staticThumbnail
        }

        do {
            let albumProvider = AlbumAssetProvider(assetService: assetService, albumId: album.id)
            let searchResult = try await albumProvider.fetchAssets(page: 1, limit: 1)
            guard let asset = searchResult.assets.first(where: { $0.type == .image }) else {
                return nil
            }

            return try await thumbnailCache.getThumbnail(for: asset.id, size: "thumbnail") {
                try await self.assetService.loadImage(assetId: asset.id, size: "thumbnail")
            }
        } catch {
            print("Failed to load cover thumbnail for album \(album.id): \(error)")
            return nil
        }
    }
}

// MARK: - People Thumbnail Provider
class PeopleThumbnailProvider: ThumbnailProvider {
    private let assetService: AssetService
    private let thumbnailCache = ThumbnailCache.shared
    
    init(assetService: AssetService) {
        self.assetService = assetService
    }
    
    func loadThumbnails(for item: GridDisplayable) async -> [UIImage] {
        guard let person = item as? Person else { return [] }

        if shouldUseStaticThumbnail() {
            if let thumbnail = await loadStaticThumbnail(for: person) {
                return [thumbnail]
            }
            return []
        }
        
        do {
            let searchResult = try await assetService.fetchAssets(page: 1, limit: animatedThumbnailLimit, personId: person.id)
            let imageAssets = searchResult.assets.filter { $0.type == .image }
            
            var loadedThumbnails: [UIImage] = []
            
            for asset in imageAssets.prefix(animatedThumbnailLimit) {
                do {
                    let thumbnail = try await thumbnailCache.getThumbnail(for: asset.id, size: "thumbnail") {
                        try await self.assetService.loadImage(assetId: asset.id, size: "thumbnail")
                    }
                    if let thumbnail = thumbnail {
                        loadedThumbnails.append(thumbnail)
                    }
                } catch {
                    print("Failed to load thumbnail for asset \(asset.id): \(error)")
                }
            }
            
            return loadedThumbnails
        } catch {
            print("Failed to fetch assets for person \(person.id): \(error)")
            return []
        }
    }

    func loadCoverThumbnail(for person: Person) async -> UIImage? {
        await loadStaticThumbnail(for: person)
    }

    private func shouldUseStaticThumbnail() -> Bool {
        return !UserDefaults.standard.enableThumbnailAnimation
    }

    private func loadStaticThumbnail(for person: Person) async -> UIImage? {
        let thumbnail = await loadSingleThumbnail(
            assetService: assetService,
            thumbnailCache: thumbnailCache,
            personId: person.id
        )
        if thumbnail == nil {
            print("Failed to load static thumbnail for person \(person.id)")
        }
        return thumbnail
    }
}

// MARK: - Tag Thumbnail Provider
class TagThumbnailProvider: ThumbnailProvider {
    private let assetService: AssetService
    private let thumbnailCache = ThumbnailCache.shared
    
    init(assetService: AssetService) {
        self.assetService = assetService
    }
    
    func loadThumbnails(for item: GridDisplayable) async -> [UIImage] {
        guard let tag = item as? Tag else { return [] }

        if shouldUseStaticThumbnail() {
            if let thumbnail = await loadStaticThumbnail(for: tag) {
                return [thumbnail]
            }
            return []
        }
        
        do {
            let searchResult = try await assetService.fetchAssets(page: 1, limit: animatedThumbnailLimit, tagId: tag.id)
            let imageAssets = searchResult.assets.filter { $0.type == .image }
            
            var loadedThumbnails: [UIImage] = []
            
            for asset in imageAssets.prefix(animatedThumbnailLimit) {
                do {
                    let thumbnail = try await thumbnailCache.getThumbnail(for: asset.id, size: "thumbnail") {
                        try await self.assetService.loadImage(assetId: asset.id, size: "thumbnail")
                    }
                    if let thumbnail = thumbnail {
                        loadedThumbnails.append(thumbnail)
                    }
                } catch {
                    print("Failed to load thumbnail for asset \(asset.id): \(error)")
                }
            }
            
            return loadedThumbnails
        } catch {
            print("Failed to fetch assets for tag \(tag.id): \(error)")
            return []
        }
    }

    func loadCoverThumbnail(for tag: Tag) async -> UIImage? {
        await loadStaticThumbnail(for: tag)
    }

    private func shouldUseStaticThumbnail() -> Bool {
        return !UserDefaults.standard.enableThumbnailAnimation
    }

    private func loadStaticThumbnail(for tag: Tag) async -> UIImage? {
        let thumbnail = await loadSingleThumbnail(
            assetService: assetService,
            thumbnailCache: thumbnailCache,
            tagId: tag.id
        )
        if thumbnail == nil {
            print("Failed to load static thumbnail for tag \(tag.id)")
        }
        return thumbnail
    }
}

// MARK: - Folder Thumbnail Provider
class FolderThumbnailProvider: ThumbnailProvider {
    private let assetService: AssetService
    private let thumbnailCache = ThumbnailCache.shared
    private let coordinator = FolderThumbnailCoordinator(maxConcurrentLoads: 4)

    init(assetService: AssetService) {
        self.assetService = assetService
    }

    func loadThumbnails(for item: GridDisplayable) async -> [UIImage] {
        guard let folder = item as? ImmichFolder else { return [] }

        if let thumbnail = await loadCoverThumbnail(for: folder) {
            return [thumbnail]
        }

        return []
    }

    func loadCoverThumbnail(for folder: ImmichFolder) async -> UIImage? {
        return await loadCoverThumbnail(for: folder.path)
    }

    private func loadCoverThumbnail(for path: String) async -> UIImage? {
        if let inFlight = await coordinator.inFlightTask(for: path) {
            if let thumbnail = await inFlight.value {
                return thumbnail
            }
            return nil
        }

        let task = Task<UIImage?, Never> {
            await coordinator.acquireSlot()
            let thumbnail = await loadSingleThumbnail(
                assetService: assetService,
                thumbnailCache: thumbnailCache,
                folderPath: path
            )
            await coordinator.releaseSlot()
            return thumbnail
        }

        await coordinator.setInFlightTask(task, for: path)
        let thumbnail = await task.value
        await coordinator.clearInFlightTask(for: path)

        return thumbnail
    }
}

private actor FolderThumbnailCoordinator {
    private let maxConcurrentLoads: Int
    private var activeLoads = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlightByPath: [String: Task<UIImage?, Never>] = [:]

    init(maxConcurrentLoads: Int) {
        self.maxConcurrentLoads = maxConcurrentLoads
    }

    func inFlightTask(for path: String) -> Task<UIImage?, Never>? {
        inFlightByPath[path]
    }

    func setInFlightTask(_ task: Task<UIImage?, Never>, for path: String) {
        inFlightByPath[path] = task
    }

    func clearInFlightTask(for path: String) {
        inFlightByPath[path] = nil
    }

    func acquireSlot() async {
        if activeLoads < maxConcurrentLoads {
            activeLoads += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        activeLoads += 1
    }

    func releaseSlot() {
        activeLoads = max(0, activeLoads - 1)
        if !waiters.isEmpty, activeLoads < maxConcurrentLoads {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }
}
