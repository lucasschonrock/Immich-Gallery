//
//  Immich_GalleryTests.swift
//  Immich GalleryTests
//
//  Created by mensadi-labs on 2025-06-29.
//

import Testing
import Foundation
@testable import Immich_Gallery

struct Immich_GalleryTests {

    @Test func assetResponseDecodesV3PayloadWithMissingDeviceFieldsAndPeople() async throws {
        let json = """
        {
          "id": "asset-1",
          "ownerId": "user-1",
          "libraryId": null,
          "type": "VIDEO",
          "originalPath": "/library/video.mov",
          "originalFileName": "video.mov",
          "originalMimeType": "video/quicktime",
          "resized": true,
          "thumbhash": null,
          "fileModifiedAt": "2026-07-02T10:00:00.000Z",
          "fileCreatedAt": "2026-07-02T10:00:00.000Z",
          "localDateTime": "2026-07-02T10:00:00.000Z",
          "updatedAt": "2026-07-02T10:00:00.000Z",
          "isFavorite": false,
          "isArchived": false,
          "isOffline": false,
          "isTrashed": false,
          "checksum": "abc",
          "duration": 12,
          "hasMetadata": true,
          "livePhotoVideoId": null,
          "visibility": "timeline",
          "duplicateId": null,
          "exifInfo": null
        }
        """.data(using: .utf8)!

        let asset = try JSONDecoder().decode(ImmichAsset.self, from: json)

        #expect(asset.deviceAssetId == nil)
        #expect(asset.deviceId == nil)
        #expect(asset.duration == "12")
        #expect(asset.people.isEmpty)
    }

    @Test func assetResponseDecodesV2StringDurationAndNullDuration() async throws {
        let stringDuration = try decodeAsset(durationJSON: "\"00:00:12.000\"")
        let nullDuration = try decodeAsset(durationJSON: "null")

        #expect(stringDuration.duration == "00:00:12.000")
        #expect(nullDuration.duration == nil)
    }

    @Test func albumResponseDecodesV3PayloadWithoutOwnerOrAssets() async throws {
        let json = """
        {
          "id": "album-1",
          "albumName": "Summer",
          "description": null,
          "albumThumbnailAssetId": "asset-1",
          "createdAt": "2026-07-02T10:00:00.000Z",
          "updatedAt": "2026-07-02T10:00:00.000Z",
          "albumUsers": [
            {
              "role": "editor",
              "user": {
                "id": "user-1",
                "email": "user@example.com",
                "name": "Demo User",
                "profileImagePath": "",
                "profileChangedAt": "2026-07-02T10:00:00.000Z",
                "avatarColor": "primary"
              }
            }
          ],
          "assetCount": 3,
          "shared": true,
          "hasSharedLink": false,
          "isActivityEnabled": true,
          "lastModifiedAssetTimestamp": null,
          "order": null,
          "startDate": null,
          "endDate": null
        }
        """.data(using: .utf8)!

        let album = try JSONDecoder().decode(ImmichAlbum.self, from: json)

        #expect(album.assets.isEmpty)
        #expect(album.ownerId == "user-1")
        #expect(album.owner?.name == "Demo User")
    }

    @Test func searchResponseDecodesRequiredTotal() async throws {
        let json = """
        {
          "albums": { "total": 0, "count": 0, "items": [], "facets": [] },
          "assets": { "total": 25, "count": 0, "items": [], "facets": [], "nextPage": "2" }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SearchResponse.self, from: json)

        #expect(response.assets.total == 25)
        #expect(response.assets.nextPage == "2")
    }

    private func decodeAsset(durationJSON: String) throws -> ImmichAsset {
        let json = """
        {
          "id": "asset-1",
          "deviceAssetId": "device-asset-1",
          "deviceId": "device-1",
          "ownerId": "user-1",
          "libraryId": null,
          "type": "VIDEO",
          "originalPath": "/library/video.mov",
          "originalFileName": "video.mov",
          "originalMimeType": "video/quicktime",
          "resized": true,
          "thumbhash": null,
          "fileModifiedAt": "2026-07-02T10:00:00.000Z",
          "fileCreatedAt": "2026-07-02T10:00:00.000Z",
          "localDateTime": "2026-07-02T10:00:00.000Z",
          "updatedAt": "2026-07-02T10:00:00.000Z",
          "isFavorite": false,
          "isArchived": false,
          "isOffline": false,
          "isTrashed": false,
          "checksum": "abc",
          "duration": \(durationJSON),
          "hasMetadata": true,
          "livePhotoVideoId": null,
          "people": [],
          "visibility": "timeline",
          "duplicateId": null,
          "exifInfo": null
        }
        """.data(using: .utf8)!

        return try JSONDecoder().decode(ImmichAsset.self, from: json)
    }

}
