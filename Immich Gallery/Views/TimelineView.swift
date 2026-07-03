//
//  TimelineView.swift
//  Immich Gallery
//
//  A sectioned-by-month alternative to the All Photos grid. Built on the
//  Immich timeline buckets API: one cheap call fetches every month + count,
//  then each month's assets load lazily as its section scrolls into view.
//  Because the columnar bucket payload is small and month lookups skip the
//  offset-walk that /search/metadata pays on deep scroll, this is well suited
//  to large libraries.
//

import SwiftUI

struct TimelineView: View {
    @ObservedObject var assetService: AssetService
    @ObservedObject var authService: AuthenticationService

    @State private var buckets: [TimelineBucket] = []
    @State private var bucketAssets: [String: [ImmichAsset]] = [:]
    @State private var loadingBuckets: Set<String> = []
    // Number of buckets (from the top) currently committed to the view. We only
    // ever render `buckets.prefix(frontier)` — never the whole library — and
    // grow it as the user scrolls, exactly like All Photos paginates. Declaring
    // every bucket's cells up front is what made the tvOS focus engine's
    // candidate/occlusion search run for 10+ seconds on a single button press.
    @State private var frontier = 0
    @State private var isLoading = false
    @State private var isScrolling = false
    @State private var visibleAssetIds: Set<String> = []
    @State private var errorMessage: String?

    /// Grow the frontier by roughly a screenful of assets at a time so each
    /// extension pushes the load-more sentinel off screen (and thus lets its
    /// onAppear fire again on the next scroll).
    private let growByAssetCount = 120
    private let thumbnailLoadBuffer = 5

    @State private var selectedAsset: ImmichAsset?
    @State private var showingFullScreen = false
    @State private var currentAssetIndex: Int = 0
    @FocusState private var focusedAssetId: String?

    private let columnCount = 5
    private let tileWidth: CGFloat = 300
    private let tileHeight: CGFloat = 360
    private let gridSpacing: CGFloat = 50

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(tileWidth), spacing: gridSpacing), count: columnCount)
    }

    // Flat, ordered list of every asset loaded so far — passed to the
    // fullscreen viewer so left/right paging works across loaded months.
    private var loadedAssetsInOrder: [ImmichAsset] {
        buckets.flatMap { bucketAssets[$0.timeBucket] ?? [] }
    }

    private var thumbnailLoadAssetIds: Set<String> {
        let assets = loadedAssetsInOrder
        guard !assets.isEmpty else { return [] }

        var idsToLoad = Set<String>()
        let anchorIds = visibleAssetIds.union(focusedAssetId.map { [$0] } ?? [])

        for anchorId in anchorIds {
            guard let index = assets.firstIndex(where: { $0.id == anchorId }) else { continue }
            let lowerBound = max(assets.startIndex, index - thumbnailLoadBuffer)
            let upperBound = min(assets.index(before: assets.endIndex), index + thumbnailLoadBuffer)

            for assetIndex in lowerBound...upperBound {
                idsToLoad.insert(assets[assetIndex].id)
            }
        }

        return idsToLoad
    }

    var body: some View {
        ZStack {
            SharedGradientBackground()

            if isLoading {
                ProgressView("Loading timeline...")
                    .foregroundColor(.white)
                    .scaleEffect(1.5)
            } else if let errorMessage = errorMessage {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 60))
                        .foregroundColor(.orange)
                    Text("Error")
                        .font(.title)
                        .foregroundColor(.white)
                    Text(errorMessage)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Retry") { loadBuckets() }
                        .buttonStyle(.borderedProminent)
                }
            } else if buckets.isEmpty {
                VStack {
                    Image(systemName: "calendar")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("No Photos Found")
                        .font(.title)
                        .foregroundColor(.white)
                    Text("Your photos will appear here")
                        .foregroundColor(.gray)
                }
            } else {
                timelineContent(loadableThumbnailIds: thumbnailLoadAssetIds)
            }
        }
        .fullScreenCover(isPresented: $showingFullScreen) {
            if let selectedAsset = selectedAsset {
                let assets = loadedAssetsInOrder
                FullScreenImageView(
                    asset: selectedAsset,
                    assets: assets,
                    currentIndex: assets.firstIndex(of: selectedAsset) ?? 0,
                    assetService: assetService,
                    authenticationService: authService,
                    currentAssetIndex: $currentAssetIndex
                )
            }
        }
        .onAppear {
            print("🟢🟢🟢 TIMELINE-BUILD-CHECK v3: frontier-paginated TimelineView (renders only loaded buckets, no whole-library placeholders) IS RUNNING")
            if buckets.isEmpty {
                loadBuckets()
            }
        }
    }

    // MARK: - Month section

    private func timelineContent(loadableThumbnailIds: Set<String>) -> some View {
        ScrollView {
            // A SINGLE lazy grid, and we only ever declare the buckets
            // committed so far (`prefix(frontier)`) — not the whole
            // library. Both matter for the tvOS focus engine: declaring
            // every bucket's cells up front makes focus movement search
            // an enormous candidate/occluder set and hang for seconds.
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(Array(buckets.prefix(frontier))) { bucket in
                    Section {
                        sectionContent(for: bucket, loadableThumbnailIds: loadableThumbnailIds)
                    } header: {
                        sectionHeader(for: bucket)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 20)

            // Load-more sentinel: when the bottom of the committed
            // content scrolls into view, commit the next screenful of
            // buckets. Mirrors All Photos' paginated load-more.
            Color.clear
                .frame(height: 1)
                .onAppear { growFrontier() }
                .padding(.bottom, 40)
        }
        .onScrollPhaseChange { _, newPhase in
            isScrolling = newPhase.isScrolling
        }
    }

    /// Full-width month label (a Section header spans all columns).
    private func sectionHeader(for bucket: TimelineBucket) -> some View {
        Text(Self.monthLabel(for: bucket.timeBucket))
            .font(.title2)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .padding(.top, 20)
    }

    /// Section body: the month's tiles once loaded, nothing before then. We
    /// never emit per-photo placeholder cells — an unloaded committed bucket
    /// just shows its header briefly until its assets arrive. This keeps the
    /// number of declared/focusable views bounded to what's actually loaded.
    @ViewBuilder
    private func sectionContent(for bucket: TimelineBucket, loadableThumbnailIds: Set<String>) -> some View {
        if let assets = bucketAssets[bucket.timeBucket] {
            ForEach(assets) { asset in
                assetTile(asset, shouldLoadThumbnail: loadableThumbnailIds.contains(asset.id))
            }
        }
    }

    private func assetTile(_ asset: ImmichAsset, shouldLoadThumbnail: Bool) -> some View {
        Button(action: {
            selectedAsset = asset
            if let index = loadedAssetsInOrder.firstIndex(of: asset) {
                currentAssetIndex = index
            }
            showingFullScreen = true
        }) {
            AssetThumbnailView(
                asset: asset,
                assetService: assetService,
                isFocused: focusedAssetId == asset.id,
                shouldLoadThumbnail: !isScrolling && shouldLoadThumbnail,
                allowsThumbhashPlaceholder: false
            )
        }
        .frame(width: tileWidth, height: tileHeight)
        .id(asset.id)
        .focused($focusedAssetId, equals: asset.id)
        .animation(.easeInOut(duration: 0.2), value: focusedAssetId)
        .onScrollVisibilityChange { isVisible in
            if isVisible {
                visibleAssetIds.insert(asset.id)
            } else {
                visibleAssetIds.remove(asset.id)
            }
        }
        .buttonStyle(CardButtonStyle())
    }

    // MARK: - Loading

    private func loadBuckets() {
        guard authService.isAuthenticated else {
            errorMessage = "Not authenticated. Please check your credentials."
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let fetched = try await assetService.fetchTimelineBuckets()
                await MainActor.run {
                    self.buckets = fetched
                    self.isLoading = false
                    // Commit and load the first screenful of buckets.
                    self.growFrontier()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    /// Commit the next batch of buckets to the view and start loading them.
    /// Advances `frontier` through enough buckets to add ~a screenful of assets
    /// so the load-more sentinel gets pushed off screen and can fire again.
    private func growFrontier() {
        guard frontier < buckets.count else { return }
        var added = 0
        var i = frontier
        while i < buckets.count && added < growByAssetCount {
            added += max(1, buckets[i].count)
            i += 1
        }
        let newFrontier = i
        for j in frontier..<newFrontier {
            loadBucket(buckets[j])
        }
        frontier = newFrontier
    }

    private func loadBucket(_ bucket: TimelineBucket) {
        let key = bucket.timeBucket
        guard bucketAssets[key] == nil, !loadingBuckets.contains(key) else { return }
        loadingBuckets.insert(key)

        Task {
            do {
                let assets = try await assetService.fetchBucketAssets(timeBucket: key)
                await MainActor.run {
                    self.bucketAssets[key] = assets
                    self.loadingBuckets.remove(key)
                }
            } catch {
                await MainActor.run {
                    // Leave unloaded so it retries when the section reappears.
                    self.loadingBuckets.remove(key)
                }
            }
        }
    }

    // MARK: - Formatting

    private static let bucketParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM"
        return f
    }()

    private static let monthDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    /// "2024-03-01T00:00:00.000Z" -> "March 2024".
    static func monthLabel(for timeBucket: String) -> String {
        let prefix = String(timeBucket.prefix(7)) // "yyyy-MM"
        if let date = bucketParser.date(from: prefix) {
            return monthDisplay.string(from: date)
        }
        return prefix
    }
}
