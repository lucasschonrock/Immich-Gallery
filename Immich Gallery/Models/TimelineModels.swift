//
//  TimelineModels.swift
//  Immich Gallery
//
//  Models for the Immich timeline buckets API (/api/timeline/buckets and
//  /api/timeline/bucket). The bucket endpoint returns assets *columnar* —
//  parallel arrays rather than an array of objects — which keeps the payload
//  small. We decode only the fields the grid needs and map them into the
//  app's existing ImmichAsset so the thumbnail, fullscreen, and slideshow
//  views can be reused unchanged.
//

import Foundation

/// One month in the timeline, as returned by GET /api/timeline/buckets.
struct TimelineBucket: Codable, Identifiable, Equatable {
    let timeBucket: String  // e.g. "2024-03-01T00:00:00.000Z"
    let count: Int

    var id: String { timeBucket }
}

/// Columnar response from GET /api/timeline/bucket. Immich returns parallel
/// arrays keyed by field; index `i` across all arrays describes one asset.
/// Only the fields used by the grid are decoded; unused/volatile fields
/// (projectionType, EXIF, …) are omitted so the decoder is resilient to
/// server-version differences.
struct TimeBucketAssetResponse: Decodable {
    let id: [String]
    let isImage: [Bool]
    let isFavorite: [Bool]?
    let isTrashed: [Bool]?
    let ratio: [Double]?
    let thumbhash: [String?]?
    let fileCreatedAt: [String]?
    let localDateTime: [String]?
    let ownerId: [String]?
    let livePhotoVideoId: [String?]?
    let visibility: [String]?
    let stack: [[String]?]?
    let duration: TimeBucketDurationColumn?

    /// Map the columnar arrays into ImmichAsset values, one per index.
    /// EXIF/people are left empty — the grid only needs id, type, thumbhash,
    /// favorite state, and a capture date for the tile label.
    func toAssets() -> [ImmichAsset] {
        let n = id.count
        var result: [ImmichAsset] = []
        result.reserveCapacity(n)

        // Defensive accessors in case the server returns mismatched lengths.
        func str(_ array: [String]?, _ i: Int) -> String {
            guard let array = array, i < array.count else { return "" }
            return array[i]
        }
        func optStr(_ array: [String?]?, _ i: Int) -> String? {
            guard let array = array, i < array.count else { return nil }
            return array[i]
        }
        func optDuration(_ i: Int) -> String? {
            guard let values = duration?.secondsStrings, i < values.count else { return nil }
            return values[i]
        }
        func flag(_ array: [Bool]?, _ i: Int) -> Bool {
            guard let array = array, i < array.count else { return false }
            return array[i]
        }
        func stackInfo(_ i: Int) -> Stack? {
            guard let stack, i < stack.count, let tuple = stack[i], tuple.count == 2,
                  let count = Int(tuple[1]) else { return nil }
            return Stack(id: tuple[0], primaryAssetId: id[i], assetCount: count)
        }

        for i in 0..<n {
            let created = str(fileCreatedAt, i)
            let captured = str(localDateTime, i).isEmpty ? created : str(localDateTime, i)
            let isImg = i < isImage.count ? isImage[i] : true

            result.append(ImmichAsset(
                id: id[i],
                deviceAssetId: "",
                deviceId: "",
                ownerId: str(ownerId, i),
                libraryId: nil,
                type: isImg ? .image : .video,
                originalPath: "",
                originalFileName: "",
                originalMimeType: nil,
                resized: nil,
                thumbhash: optStr(thumbhash, i),
                fileModifiedAt: created,
                fileCreatedAt: captured,
                localDateTime: captured,
                updatedAt: created,
                isFavorite: flag(isFavorite, i),
                isArchived: false,
                isOffline: false,
                isTrashed: flag(isTrashed, i),
                checksum: "",
                duration: optDuration(i),
                hasMetadata: false,
                livePhotoVideoId: optStr(livePhotoVideoId, i),
                people: [],
                visibility: str(visibility, i),
                duplicateId: nil,
                exifInfo: nil,
                stack: stackInfo(i)
            ))
        }
        return result
    }
}

/// Timeline buckets send duration as milliseconds (nullable ints). Older
/// servers may omit the column or send `HH:MM:SS` strings instead.
struct TimeBucketDurationColumn: Decodable {
    let secondsStrings: [String?]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [String?] = []
        while !container.isAtEnd {
            if try container.decodeNil() {
                values.append(nil)
                continue
            }
            if let milliseconds = try? container.decode(Int.self) {
                values.append(Self.secondsString(fromMilliseconds: milliseconds))
                continue
            }
            if let milliseconds = try? container.decode(Double.self) {
                values.append(Self.secondsString(fromMilliseconds: Int(milliseconds)))
                continue
            }
            if let raw = try? container.decode(String.self) {
                values.append(raw.isEmpty ? nil : raw)
                continue
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported timeline duration value"
            )
        }
        secondsStrings = values
    }

    private static func secondsString(fromMilliseconds milliseconds: Int) -> String? {
        guard milliseconds > 0 else { return nil }
        let seconds = Double(milliseconds) / 1000.0
        if seconds == seconds.rounded() {
            return String(Int(seconds))
        }
        return String(seconds)
    }
}
