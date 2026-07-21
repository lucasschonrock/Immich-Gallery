import SwiftUI

/// Shared in-memory bucket cache used by month cards and their detail grid.
/// The timeline endpoint returns compact metadata, so caching the decoded
/// month avoids requesting it again when its cover is selected.
final class TimelineMonthAssetCache {
    private let lock = NSLock()
    private var storage: [String: [ImmichAsset]] = [:]

    func assets(
        timeBucket: String,
        order: String,
        assetService: AssetService
    ) async throws -> [ImmichAsset] {
        let key = "\(order):\(timeBucket)"

        let cached = lock.withLock { storage[key] }
        if let cached { return cached }

        let loaded = try await assetService.fetchBucketAssets(
            timeBucket: timeBucket,
            order: order
        )

        lock.withLock { storage[key] = loaded }
        return loaded
    }
}

struct CalendarMonthGridView: View {
    let assetService: AssetService
    let authService: AuthenticationService
    let order: String

    @Environment(\.dismiss) private var dismiss
    @State private var buckets: [TimelineBucket] = []
    @State private var selectedBucket: TimelineBucket?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var assetCache = TimelineMonthAssetCache()
    @State private var isScrolling = false
    @State private var visibleBucketIds: Set<String> = []

    private let cardSize = CGSize(width: 500, height: 300)
    private let columns = Array(
        repeating: GridItem(.fixed(500), spacing: 30),
        count: 3
    )

    private var thumbnailLoadBucketIds: Set<String> {
        var ids = Set<String>()

        for visibleId in visibleBucketIds {
            guard let index = buckets.firstIndex(where: { $0.id == visibleId }) else { continue }
            let lowerBound = max(buckets.startIndex, index - 3)
            let upperBound = min(buckets.index(before: buckets.endIndex), index + 3)

            for bucketIndex in lowerBound...upperBound {
                ids.insert(buckets[bucketIndex].id)
            }
        }

        return ids
    }

    var body: some View {
        NavigationView {
            ZStack {
                SharedGradientBackground()

                if isLoading {
                    ProgressView("Loading months...")
                        .foregroundColor(.white)
                        .scaleEffect(1.5)
                } else if let errorMessage {
                    errorView(message: errorMessage)
                } else {
                    monthGrid
                }
            }
            .navigationTitle("Months")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.white)
                    }
                    .accessibilityLabel("Close months")
                }
            }
        }
        .fullScreenCover(item: $selectedBucket) { bucket in
            CalendarMonthDetailView(
                bucket: bucket,
                assetService: assetService,
                authService: authService,
                order: order,
                assetCache: assetCache
            )
        }
        .task(id: order) {
            await loadBuckets()
        }
    }

    private var monthGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .center, spacing: 30) {
                ForEach(buckets) { bucket in
                    Button {
                        selectedBucket = bucket
                    } label: {
                        CalendarMonthCard(
                            bucket: bucket,
                            assetService: assetService,
                            order: order,
                            assetCache: assetCache,
                            cardSize: cardSize,
                            shouldLoadThumbnail: !isScrolling && thumbnailLoadBucketIds.contains(bucket.id)
                        )
                    }
                    .frame(width: cardSize.width, height: cardSize.height)
                    .buttonStyle(CardButtonStyle())
                    .onScrollVisibilityChange { isVisible in
                        if isVisible {
                            visibleBucketIds.insert(bucket.id)
                        } else {
                            visibleBucketIds.remove(bucket.id)
                        }
                    }
                    .accessibilityLabel(
                        "\(TimelineView.monthLabel(for: bucket.timeBucket)), \(photoCount(bucket.count))"
                    )
                }
            }
            .focusSection()
            .padding(.horizontal, 72)
            .padding(.vertical, 48)
        }
        .onScrollPhaseChange { _, newPhase in
            isScrolling = newPhase.isScrolling
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            Text("Couldn’t Load Months")
                .font(.title)
                .foregroundColor(.white)
            Text(message)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 80)
            Button("Retry") {
                Task { await loadBuckets() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @MainActor
    private func loadBuckets() async {
        guard authService.isAuthenticated else {
            errorMessage = "Not authenticated. Please check your credentials."
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await assetService.fetchTimelineBuckets(order: order)
            buckets = TimelineView.filteredAndSortedBuckets(fetched, order: order, year: nil)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func photoCount(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count.formatted(.number)) photos"
    }
}

private struct CalendarMonthCard: View {
    let bucket: TimelineBucket
    let assetService: AssetService
    let order: String
    let assetCache: TimelineMonthAssetCache
    let cardSize: CGSize
    let shouldLoadThumbnail: Bool

    var body: some View {
        AsyncLandscapeOverlayLockupCard(
            taskId: "\(order):\(bucket.timeBucket)",
            title: TimelineView.monthLabel(for: bucket.timeBucket),
            subtitle: nil,
            leadingIconName: nil,
            primaryMetadata: photoCount,
            secondaryMetadata: nil,
            trailingStatusIconNames: [],
            fallbackIconName: "calendar",
            fallbackTint: .secondary,
            cardSize: cardSize,
            shouldLoadImage: shouldLoadThumbnail
        ) {
            await loadCover()
        }
    }

    private var photoCount: String {
        bucket.count == 1 ? "1 photo" : "\(bucket.count.formatted(.number)) photos"
    }

    private func loadCover() async -> UIImage? {
        do {
            let assets = try await assetCache.assets(
                timeBucket: bucket.timeBucket,
                order: order,
                assetService: assetService
            )
            guard let asset = assets.first else { return nil }

            return try await ThumbnailCache.shared.getThumbnail(for: asset.id, size: "preview") {
                try await assetService.loadImage(assetId: asset.id, size: "preview")
            }
        } catch {
            print("Failed to load cover for month \(bucket.timeBucket): \(error)")
            return nil
        }
    }
}

private struct CalendarMonthDetailView: View {
    let bucket: TimelineBucket
    let assetService: AssetService
    let authService: AuthenticationService
    let order: String
    let assetCache: TimelineMonthAssetCache

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            AssetGridView(
                assetService: assetService,
                authService: authService,
                assetProvider: TimelineMonthAssetProvider(
                    assetService: assetService,
                    timeBucket: bucket.timeBucket,
                    order: order,
                    cache: assetCache
                ),
                albumId: nil,
                personId: nil,
                tagId: nil,
                city: nil,
                isAllPhotos: false,
                isFavorite: false,
                onAssetsLoaded: nil,
                deepLinkAssetId: nil,
                allowsSlideshow: false
            )
            .navigationTitle(TimelineView.monthLabel(for: bucket.timeBucket))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.white)
                    }
                    .accessibilityLabel("Close month")
                }
            }
        }
    }
}
