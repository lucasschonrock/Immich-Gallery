//
//  Immich_GalleryTests.swift
//  Immich GalleryTests
//
//  Created by mensadi-labs on 2025-06-29.
//

import Testing
import Foundation
import AVFoundation
import CoreMedia
@testable import Immich_Gallery

struct Immich_GalleryTests {

    @Test func birthdayProximityIncludesTwoDaysAcrossYearBoundary() throws {
        let calendar = birthdayTestCalendar
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 31)))

        #expect(BirthdayProximity.details(for: makePerson(id: "today", birthDate: "1990-12-31"), on: today, calendar: calendar)?.dayOffset == 0)
        #expect(BirthdayProximity.details(for: makePerson(id: "tomorrow", birthDate: "1990-01-01"), on: today, calendar: calendar)?.dayOffset == 1)
        #expect(BirthdayProximity.details(for: makePerson(id: "two-days", birthDate: "1990-01-02"), on: today, calendar: calendar)?.dayOffset == 2)
        #expect(BirthdayProximity.details(for: makePerson(id: "outside", birthDate: "1990-01-03"), on: today, calendar: calendar) == nil)
    }

    @Test func invalidBirthdayIsIgnored() throws {
        let calendar = birthdayTestCalendar
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 20)))

        #expect(BirthdayProximity.details(for: makePerson(id: "invalid", birthDate: "not-a-date"), on: today, calendar: calendar) == nil)
    }

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
          "duration": 12000,
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
        #expect(asset.displayedVideoDuration == "0:12")
        #expect(asset.people.isEmpty)
    }

    @Test func assetResponseDecodesV2StringDurationAndNullDuration() async throws {
        let stringDuration = try decodeAsset(durationJSON: "\"00:00:12.000\"")
        let nullDuration = try decodeAsset(durationJSON: "null")

        #expect(stringDuration.duration == "00:00:12.000")
        #expect(nullDuration.duration == nil)
    }

    @Test func assetResponseDecodesStackSummary() async throws {
        let json = """
        {
          "id": "asset-1",
          "ownerId": "user-1",
          "type": "IMAGE",
          "originalPath": "/library/photo.jpg",
          "originalFileName": "photo.jpg",
          "fileModifiedAt": "2026-07-02T10:00:00.000Z",
          "fileCreatedAt": "2026-07-02T10:00:00.000Z",
          "localDateTime": "2026-07-02T10:00:00.000Z",
          "updatedAt": "2026-07-02T10:00:00.000Z",
          "isFavorite": false,
          "isArchived": false,
          "isOffline": false,
          "isTrashed": false,
          "checksum": "abc",
          "hasMetadata": true,
          "visibility": "timeline",
          "stack": {
            "id": "stack-1",
            "primaryAssetId": "asset-1",
            "assetCount": 3
          }
        }
        """.data(using: .utf8)!

        let asset = try JSONDecoder().decode(ImmichAsset.self, from: json)

        #expect(asset.stack?.id == "stack-1")
        #expect(asset.stack?.primaryAssetId == "asset-1")
        #expect(asset.stack?.assetCount == 3)
    }

    @Test func timelineResponseMapsStackTupleToAssetSummary() throws {
        let json = """
        {
          "id": ["asset-1", "asset-2"],
          "isImage": [true, true],
          "stack": [["stack-1", "3"], null]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(TimeBucketAssetResponse.self, from: json)
        let assets = response.toAssets()

        #expect(assets[0].stack?.id == "stack-1")
        #expect(assets[0].stack?.primaryAssetId == "asset-1")
        #expect(assets[0].stack?.assetCount == 3)
        #expect(assets[1].stack == nil)
    }

    @Test func timelineResponseMapsMillisecondDurationToDisplayString() throws {
        let json = """
        {
          "id": ["photo-1", "video-1"],
          "isImage": [true, false],
          "duration": [null, 125000]
        }
        """.data(using: .utf8)!

        let assets = try JSONDecoder().decode(TimeBucketAssetResponse.self, from: json).toAssets()

        #expect(assets[0].displayedVideoDuration == nil)
        #expect(assets[1].type == .video)
        #expect(assets[1].duration == "125")
        #expect(assets[1].displayedVideoDuration == "2:05")
    }

    @Test func videoDurationFormatterHandlesAssetSearchFormats() {
        #expect(VideoDurationFormatter.displayString(from: "00:00:12.000") == "0:12")
        #expect(VideoDurationFormatter.displayString(from: "0:00:31.320") == "0:31")
        #expect(VideoDurationFormatter.displayString(from: "12") == "0:12")
        #expect(VideoDurationFormatter.displayString(from: "1:02:03") == "1:02:03")
        #expect(VideoDurationFormatter.displayString(from: nil) == nil)
        #expect(VideoDurationFormatter.displayString(from: "0") == nil)
        #expect(VideoDurationFormatter.displayString(from: VideoDurationFormatter.normalizedStorage("31320")) == "0:31")
        #expect(VideoDurationFormatter.secondsString(fromMilliseconds: 31320) == "31.32")
        #expect(VideoDurationFormatter.displayString(from: "31.32") == "0:31")
    }

    @Test func assetResponseDecodesV3MillisecondDurationForAlbumSearch() throws {
        let asset = try decodeAsset(durationJSON: "31320")
        #expect(asset.duration == "31.32")
        #expect(asset.displayedVideoDuration == "0:31")
    }

    @Test func videoRangePlannerParsesContentRangeAndMp4Type() {
        let parsed = ImmichVideoRangePlanner.parseContentRange("bytes 0-524287/10485760")
        #expect(parsed?.start == 0)
        #expect(parsed?.end == 524_287)
        #expect(parsed?.total == 10_485_760)
        #expect(ImmichVideoRangePlanner.contentType(from: "video/mp4") == AVFileType.mp4.rawValue)
    }

    @Test func videoRangePlannerParsesOpenEndedAndClosedRangeHeaders() {
        let open = ImmichVideoRangePlanner.parseRangeHeader("bytes=123456-")
        #expect(open?.start == 123_456)
        #expect(open?.end == nil)

        let closed = ImmichVideoRangePlanner.parseRangeHeader("Bytes=1000-2000")
        #expect(closed?.start == 1_000)
        #expect(closed?.end == 2_000)
    }

    @Test func videoProxyParsesRangeRequestAndBuildsPartialContentHeaders() throws {
        let raw = "GET /video.mp4 HTTP/1.1\r\nHost: 127.0.0.1:8123\r\nRange: bytes=1048576-\r\nAccept: */*\r\n\r\n"
        let request = try #require(ImmichVideoProxyHTTP.parseRequest(raw))
        #expect(request.method == "GET")
        #expect(request.path == "/video.mp4")
        #expect(request.range == "bytes=1048576-")

        let response = HTTPURLResponse(
            url: URL(string: "https://immich.example/api/assets/1/video/playback")!,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "video/mp4",
                "Content-Range": "bytes 1048576-2097151/3800000000",
                "Content-Length": "1048576",
                "Accept-Ranges": "bytes"
            ]
        )!
        let header = String(data: ImmichVideoProxyHTTP.makeResponseHeader(from: response), encoding: .utf8) ?? ""
        #expect(header.hasPrefix("HTTP/1.1 206 Partial Content"))
        #expect(header.contains("Content-Range: bytes 1048576-2097151/3800000000"))
        #expect(header.contains("Accept-Ranges: bytes"))
        #expect(header.contains("Connection: keep-alive"))
    }

    @Test func videoProxyKeepAliveDefaultsForHTTP11() throws {
        let keepAlive = try #require(ImmichVideoProxyHTTP.parseRequest(
            "GET /video.mp4 HTTP/1.1\r\nRange: bytes=0-65535\r\n\r\n"
        ))
        #expect(keepAlive.keepAlive)

        let close = try #require(ImmichVideoProxyHTTP.parseRequest(
            "GET /video.mp4 HTTP/1.1\r\nRange: bytes=0-65535\r\nConnection: close\r\n\r\n"
        ))
        #expect(!close.keepAlive)
    }

    @Test func videoProxyTreatsOpenEndedAndHugeRangesAsStreamingPassThrough() {
        #expect(ImmichVideoProxyPolicy.isStreamingRange(start: 0, end: 4_002_977_081))
        #expect(ImmichVideoProxyPolicy.isStreamingRange(start: 11_203, end: nil))
        #expect(ImmichVideoProxyPolicy.isStreamingRange(start: 0, end: nil))
        #expect(!ImmichVideoProxyPolicy.isStreamingRange(start: 1_988_755_456, end: 1_988_820_991))
        #expect(!ImmichVideoProxyPolicy.isStreamingRange(start: 144_769_024, end: 154_140_671))
        #expect(!ImmichVideoProxyPolicy.isStreamingRange(start: 4_002_283_520, end: 4_002_977_081))
    }

    @Test func videoProxyTransportBufferPausesUpstreamBeforeUnboundedReadAhead() {
        #expect(ImmichVideoProxyPolicy.transportHighWaterBytes == 4 * 1024 * 1024)
        #expect(ImmichVideoProxyPolicy.transportLowWaterBytes == 1 * 1024 * 1024)
        #expect(ImmichVideoProxyPolicy.transportLowWaterBytes < ImmichVideoProxyPolicy.transportHighWaterBytes)
    }

    @Test func videoProxyBlockCacheUsesFourMegabyteAlignedBlocks() {
        #expect(ImmichVideoProxyPolicy.blockSize == 4 * 1024 * 1024)
        #expect(ImmichVideoProxyPolicy.maxCacheBytes == 128 * 1024 * 1024)
        #expect(ImmichVideoProxyPolicy.blockStart(for: 56_885_248) == 54_525_952)
        #expect(ImmichVideoProxyPolicy.blockEnd(start: 54_525_952, total: 4_002_977_082) == 58_720_255)
        #expect(ImmichVideoProxyPolicy.coveringBlocks(start: 56_885_248, end: 56_950_783) == [54_525_952])
        #expect(
            ImmichVideoProxyPolicy.coveringBlocks(start: 144_769_024, end: 154_140_671)
            == [142_606_336, 146_800_640, 150_994_944]
        )
    }

    @Test func videoBlockCacheSatisfiesSmallRangeFromContainingBlock() {
        let cache = ImmichVideoBlockCache()
        cache.total = 4_002_977_082
        let blockStart: Int64 = 54_525_952
        var payload = Data(count: Int(ImmichVideoProxyPolicy.blockSize))
        payload[Int(56_885_248 - blockStart)] = 0xAB
        cache.write(at: blockStart, payload)

        let slice = cache.slice(from: 56_885_248, length: 65_536)
        #expect(slice?.count == 65_536)
        #expect(slice?.first == 0xAB)
        #expect(cache.hasRange(from: 56_885_248, to: 56_950_783))
    }

    @Test func videoBlockCacheTeeThenRereadIsLocalHit() {
        let cache = ImmichVideoBlockCache()
        cache.total = 4_002_977_082
        let passThroughStart: Int64 = 4_096
        let length = 34_700_000
        cache.write(at: passThroughStart, Data(count: length))

        let reread: Int64 = 31_400_000
        #expect(cache.hasRange(from: reread, to: reread + 65_535))
        #expect(cache.slice(from: reread, length: 65_536)?.count == 65_536)
    }

    @Test func videoBlockCachePinsInFlightBlocksAgainstLRUEviction() {
        let cache = ImmichVideoBlockCache()
        let pinnedStart: Int64 = 54_525_952
        cache.pin(starts: [pinnedStart])
        cache.write(at: pinnedStart, Data(repeating: 1, count: Int(ImmichVideoProxyPolicy.blockSize)))

        for index in 0..<40 {
            let start = Int64(index) * ImmichVideoProxyPolicy.blockSize
            if start == pinnedStart { continue }
            cache.write(at: start, Data(repeating: UInt8(index % 250), count: Int(ImmichVideoProxyPolicy.blockSize)))
        }

        #expect(cache.hasRange(from: pinnedStart, to: pinnedStart + 1024))
        #expect(cache.storedBytes <= ImmichVideoProxyPolicy.maxCacheBytes + ImmichVideoProxyPolicy.blockSize)
        cache.unpin(starts: [pinnedStart])
    }

    @Test func videoBlockCacheKeepsDisjointRunsInsideABlock() throws {
        let cache = ImmichVideoBlockCache()
        let blockStart: Int64 = 750_780_416
        let passThrough: Int64 = 750_911_488
        cache.write(at: passThrough, Data(repeating: 1, count: 2_000_000))
        cache.write(at: blockStart, Data(repeating: 2, count: 100_000))

        let block = try #require(cache.block(at: blockStart))
        #expect(block.hasRange(from: blockStart, to: blockStart + 99_999))
        #expect(block.hasRange(from: passThrough, to: passThrough + 1_999_999))
        #expect(!block.hasRange(from: blockStart, to: passThrough))
        #expect(block.missingIntervals(from: blockStart, to: blockStart + 99_999).isEmpty)
        #expect(!block.missingIntervals(from: blockStart + 100_000, to: passThrough - 1).isEmpty)
    }

    @Test func videoBlockCacheSatisfiesWaiterBeforeBlockIsComplete() throws {
        let cache = ImmichVideoBlockCache()
        let blockStart: Int64 = 750_780_416
        let receivedEnd: Int64 = 753_800_000
        cache.write(at: blockStart, Data(count: Int(receivedEnd - blockStart)))

        #expect(cache.hasRange(from: blockStart, to: 753_400_000))
        #expect(!cache.hasRange(from: blockStart, to: 754_974_719))
        let missing = try #require(cache.block(at: blockStart)?.missingIntervals(from: blockStart, to: 754_974_719).first)
        #expect(missing.start == receivedEnd)
    }

    @Test func videoBlockCacheMergesAdjacentPassThroughAndHoleFill() {
        let cache = ImmichVideoBlockCache()
        let blockStart: Int64 = 750_780_416
        let passThrough: Int64 = 750_911_488
        cache.write(at: passThrough, Data(repeating: 1, count: 4_096))
        cache.write(at: blockStart, Data(repeating: 2, count: Int(passThrough - blockStart)))

        #expect(cache.hasRange(from: blockStart, to: passThrough + 4_095))
        #expect(cache.block(at: blockStart)?.runs.count == 1)
    }

    @Test func videoProxySequentialProducerDoesNotCoverBytesItAlreadyPassed() {
        #expect(
            ImmichVideoProxyPolicy.sequentialProducerCovers(
                producerStart: 750_911_488,
                producerReceived: 0,
                producerEnd: nil,
                needFrom: 751_108_096,
                needTo: 751_173_631
            )
        )
        #expect(
            !ImmichVideoProxyPolicy.sequentialProducerCovers(
                producerStart: 750_911_488,
                producerReceived: 0,
                producerEnd: nil,
                needFrom: 750_780_416,
                needTo: 750_911_487
            )
        )
        #expect(
            !ImmichVideoProxyPolicy.sequentialProducerCovers(
                producerStart: 750_911_488,
                producerReceived: 3_000_000,
                producerEnd: nil,
                needFrom: 750_911_488,
                needTo: 750_911_488 + 100
            )
        )
    }

    @Test func videoProxySynthesizesKeepAlivePartialContentForTinyClientRanges() {
        let header = String(
            data: ImmichVideoProxyHTTP.makePartialContentHeader(
                start: 140_705_792,
                end: 140_771_327,
                total: 4_002_977_082,
                contentType: "video/mp4",
                keepAlive: true
            ),
            encoding: .utf8
        ) ?? ""
        #expect(header.hasPrefix("HTTP/1.1 206 Partial Content"))
        #expect(header.contains("Content-Range: bytes 140705792-140771327/4002977082"))
        #expect(header.contains("Content-Length: 65536"))
        #expect(header.contains("Connection: keep-alive"))
        #expect(header.contains("Accept-Ranges: bytes"))
    }

    @Test func videoDiagnosticsComputesBufferedSecondsAheadFromLoadedRanges() {
        let current = CMTime(seconds: 10, preferredTimescale: 600)
        let loaded = NSValue(timeRange: CMTimeRange(
            start: CMTime(seconds: 8, preferredTimescale: 600),
            duration: CMTime(seconds: 22, preferredTimescale: 600)
        ))
        let ahead = VideoPlaybackDiagnostics.bufferedSecondsAhead(of: current, loaded: [loaded])
        #expect(abs(ahead - 20) < 0.01)
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

    @Test func collectionAssetSortOrderDefaultsToNewestFirst() throws {
        let suiteName = "CollectionAssetSortOrderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removePersistentDomain(forName: suiteName)
        #expect(defaults.assetSortOrder == "desc")

        defaults.assetSortOrder = "asc"
        #expect(defaults.assetSortOrder == "asc")
    }

    @Test func albumAssetProviderUsesBackendMetadataPaginationForRequestedPages() async throws {
        let assetService = PaginatedAlbumAssetService()
        let provider = AlbumAssetProvider(assetService: assetService, albumId: "album-1")

        let firstPage = try await provider.fetchAssets(page: 1, limit: 200)
        let thirdPage = try await provider.fetchAssets(page: 3, limit: 200)

        #expect(assetService.requestedPages == [1, 3])
        #expect(assetService.requestedAssetTypes.allSatisfy { $0 == nil })
        #expect(firstPage.assets.count == 200)
        #expect(firstPage.total == 500)
        #expect(firstPage.nextPage == "2")
        #expect(thirdPage.assets.count == 100)
        #expect(thirdPage.total == 500)
        #expect(thirdPage.nextPage == nil)
    }

    @Test func albumAssetProviderPassesVideoFilterToMetadataSearch() async throws {
        let assetService = PaginatedAlbumAssetService()
        let provider = AlbumAssetProvider(assetService: assetService, albumId: "album-1")

        _ = try await provider.fetchAssets(page: 1, limit: 200, assetType: .video)

        #expect(assetService.requestedAssetTypes.count == 1)
        #expect(assetService.requestedAssetTypes[0] == .video)
    }

    @Test func albumAssetProviderLoadsAllMetadataPagesForAggregateAlbumOperations() async throws {
        let assetService = PaginatedAlbumAssetService()
        let provider = AlbumAssetProvider(assetService: assetService, albumId: "album-1")

        let years = try await provider.fetchAllYears()

        #expect(assetService.requestedPages == [1, 2, 3])
        #expect(years == [2026])
    }

    @Test func timelineBucketsApplyYearAndDateOrderLocally() {
        let buckets = [
            TimelineBucket(timeBucket: "2025-12-01T00:00:00.000Z", count: 1),
            TimelineBucket(timeBucket: "2026-01-01T00:00:00.000Z", count: 1),
            TimelineBucket(timeBucket: "2026-07-01T00:00:00.000Z", count: 1)
        ]

        let ascending = TimelineView.filteredAndSortedBuckets(buckets, order: "asc", year: 2026)
        let descending = TimelineView.filteredAndSortedBuckets(buckets, order: "desc", year: 2026)

        #expect(ascending.map(\.timeBucket) == ["2026-01-01T00:00:00.000Z", "2026-07-01T00:00:00.000Z"])
        #expect(descending.map(\.timeBucket) == ["2026-07-01T00:00:00.000Z", "2026-01-01T00:00:00.000Z"])
    }

    @Test func timelineAssetPagesCapActualCellsAcrossUnevenMonths() {
        let monthCounts = [100, 200, 3_000, 15_000]

        #expect(TimelineView.visibleCounts(availableCounts: monthCounts, limit: 120) == [100, 20])
        #expect(TimelineView.visibleCounts(availableCounts: monthCounts, limit: 240) == [100, 140])
        #expect(TimelineView.visibleCounts(availableCounts: monthCounts, limit: 360) == [100, 200, 60])
        #expect(TimelineView.visibleCounts(availableCounts: monthCounts, limit: 3_301) == [100, 200, 3_000, 1])
    }

    @Test func timelineAssetPagesNeverExceedTheirCellLimit() {
        let monthCounts = [0, 100, 200, 3_000, 15_000]

        for limit in stride(from: 120, through: 18_360, by: 120) {
            let visibleCounts = TimelineView.visibleCounts(availableCounts: monthCounts, limit: limit)
            #expect(visibleCounts.reduce(0, +) <= limit)
            #expect(zip(visibleCounts, monthCounts).allSatisfy { visible, available in
                visible >= 0 && visible <= available
            })
        }
    }

    @Test func timelineBucketRequestsIncludePartnerAssets() {
        let bucketsEndpoint = AssetService.timelineBucketsEndpoint(order: "desc", withStacked: true)
        let assetsEndpoint = AssetService.timelineBucketEndpoint(
            timeBucket: "2026-07-01T00:00:00.000Z",
            order: "desc"
        )
        let favoritesEndpoint = AssetService.timelineBucketsEndpoint(
            order: "desc",
            withStacked: true,
            isFavorite: true
        )
        let favoriteAssetsEndpoint = AssetService.timelineBucketEndpoint(
            timeBucket: "2026-07-01T00:00:00.000Z",
            order: "desc",
            isFavorite: true
        )
        let yearsEndpoint = AssetService.timelineBucketsEndpoint()

        #expect(bucketsEndpoint == "/api/timeline/buckets?visibility=timeline&withPartners=true&order=desc&withStacked=true")
        #expect(assetsEndpoint == "/api/timeline/bucket?timeBucket=2026-07-01T00:00:00.000Z&visibility=timeline&withPartners=true&order=desc&withStacked=true")
        #expect(favoritesEndpoint == "/api/timeline/buckets?order=desc&withStacked=true&isFavorite=true")
        #expect(favoriteAssetsEndpoint == "/api/timeline/bucket?timeBucket=2026-07-01T00:00:00.000Z&order=desc&withStacked=true&isFavorite=true")
        #expect(yearsEndpoint == "/api/timeline/buckets?visibility=timeline&withPartners=true")
    }

    @Test func timelineMetadataFilterUsesServerSideDateAndLocationFields() {
        let request = AssetService.timelineSearchRequest(
            page: 1,
            size: 120,
            order: "desc",
            city: "Wavre",
            state: "Wallonia",
            country: "Belgium",
            cameraMake: "Apple",
            cameraModel: "iPhone 17 Pro",
            lensModel: "iPhone 17 Pro back triple camera",
            year: 2026,
            assetType: .video
        )

        #expect(request["page"] as? Int == 1)
        #expect(request["visibility"] as? String == "timeline")
        #expect(request["withExif"] as? Bool == true)
        #expect(request["city"] as? String == "Wavre")
        #expect(request["state"] as? String == "Wallonia")
        #expect(request["country"] as? String == "Belgium")
        #expect(request["make"] as? String == "Apple")
        #expect(request["model"] as? String == "iPhone 17 Pro")
        #expect(request["lensModel"] as? String == "iPhone 17 Pro back triple camera")
        #expect(request["type"] as? String == AssetType.video.rawValue)
        #expect(request["takenAfter"] as? String == "2026-01-01T00:00:00.000Z")
        #expect(request["takenBefore"] as? String == "2026-12-31T23:59:59.999Z")
    }

    @Test func timelineAllMediaFilterOmitsAssetType() {
        let request = AssetService.timelineSearchRequest(
            page: 1,
            size: 120,
            order: "desc",
            city: nil,
            year: nil
        )

        #expect(request["type"] == nil)
    }

    @Test func timelineMetadataFilterPreservesUnknownSuggestionsAsNull() {
        let request = AssetService.timelineSearchRequest(
            page: 1,
            size: 120,
            order: "desc",
            city: SearchSuggestionType.nullValue,
            year: nil
        )

        #expect(request["city"] is NSNull)
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

    private var birthdayTestCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makePerson(id: String, birthDate: String?) -> Person {
        Person(
            id: id,
            name: id,
            birthDate: birthDate,
            thumbnailPath: "thumbnail.jpg",
            isHidden: false,
            isFavorite: false,
            updatedAt: nil,
            color: nil
        )
    }

}

private final class PaginatedAlbumAssetService: AssetService {
    private(set) var requestedPages: [Int] = []
    private(set) var requestedAssetTypes: [AssetType?] = []

    init() {
        super.init(networkService: NetworkService(userManager: UserManager()))
    }

    override func fetchAssets(
        page: Int = 1,
        limit: Int? = nil,
        albumId: String? = nil,
        personId: String? = nil,
        tagId: String? = nil,
        city: String? = nil,
        isAllPhotos: Bool = false,
        isFavorite: Bool = false,
        folderPath: String? = nil,
        assetType: AssetType? = nil
    ) async throws -> SearchResult {
        requestedPages.append(page)
        requestedAssetTypes.append(assetType)
        #expect(limit == 200)
        #expect(albumId == "album-1")

        let start = (page - 1) * 200
        let count = page < 3 ? 200 : 100
        let assets = (start..<(start + count)).map { makeAsset(index: $0) }
        let nextPage = page < 3 ? String(page + 1) : nil

        return SearchResult(assets: assets, total: 500, nextPage: nextPage)
    }

    private func makeAsset(index: Int) -> ImmichAsset {
        ImmichAsset(
            id: "asset-\(index)",
            deviceAssetId: nil,
            deviceId: nil,
            ownerId: "user-1",
            libraryId: nil,
            type: .image,
            originalPath: "/library/asset-\(index).jpg",
            originalFileName: "asset-\(index).jpg",
            originalMimeType: "image/jpeg",
            resized: true,
            thumbhash: nil,
            fileModifiedAt: "2026-07-02T10:00:00.000Z",
            fileCreatedAt: "2026-07-02T10:00:00.000Z",
            localDateTime: "2026-07-02T10:00:00.000Z",
            updatedAt: "2026-07-02T10:00:00.000Z",
            isFavorite: false,
            isArchived: false,
            isOffline: false,
            isTrashed: false,
            checksum: "checksum-\(index)",
            duration: nil,
            hasMetadata: true,
            livePhotoVideoId: nil,
            people: [],
            visibility: "timeline",
            duplicateId: nil,
            exifInfo: nil
        )
    }
}
