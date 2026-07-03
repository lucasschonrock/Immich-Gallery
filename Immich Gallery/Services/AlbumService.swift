//
//  AlbumService.swift
//  Immich Gallery
//

import Foundation
import UIKit

/// Service responsible for album operations
class AlbumService: ObservableObject {
    private let networkService: NetworkService

    init(networkService: NetworkService) {
        self.networkService = networkService
    }

    func fetchAlbums() async throws -> [ImmichAlbum] {
        print("AlbumService: Fetching albums from /api/albums")
        let albums = try await networkService.makeRequest(
            endpoint: "/api/albums",
            responseType: [ImmichAlbum].self
        )

        var seenAlbumIds = Set<String>()
        let dedupedAlbums = albums.filter { album in
            seenAlbumIds.insert(album.id).inserted
        }
        print("AlbumService: Received \(dedupedAlbums.count) albums")
        return dedupedAlbums
    }

    func getAlbumInfo(albumId: String, withoutAssets: Bool = false) async throws -> ImmichAlbum {
        var endpoint = "/api/albums/\(albumId)"
        if withoutAssets {
            endpoint += "?withoutAssets=true"
        }
        return try await networkService.makeRequest(
            endpoint: endpoint,
            responseType: ImmichAlbum.self
        )
    }

    func loadAlbumThumbnail(albumId: String, thumbnailAssetId: String, size: String = "thumbnail") async throws -> UIImage? {
        let endpoint = "/api/assets/\(thumbnailAssetId)/thumbnail?format=webp&size=\(size)"
        let data = try await networkService.makeDataRequest(endpoint: endpoint)
        return UIImage(data: data)
    }
} 
