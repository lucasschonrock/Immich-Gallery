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
    private enum ToolbarButton: Hashable {
        case filter
        case resetFilters
        case sort
    }

    private enum ScrollAnchor: Hashable {
        case top
    }

    @ObservedObject var assetService: AssetService
    @ObservedObject var authService: AuthenticationService
    @AppStorage(UserDefaultsKeys.allPhotosSortOrder) private var allPhotosSortOrder = "desc"

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
    @State private var showingFilterModal = false
    @State private var filters = PhotoFilterSelection.saved
    @State private var loadGeneration = UUID()
    @State private var filteredNextPage: Int?
    @State private var isLoadingFilteredPage = false

    /// Grow the frontier by roughly a screenful of assets at a time so each
    /// extension pushes the load-more sentinel off screen (and thus lets its
    /// onAppear fire again on the next scroll).
    private let growByAssetCount = 120
    private let filteredPageSize = 120
    private let thumbnailLoadBuffer = 5

    @State private var selectedAsset: ImmichAsset?
    @State private var showingFullScreen = false
    @State private var currentAssetIndex: Int = 0
    @FocusState private var focusedAssetId: String?
    @FocusState private var focusedToolbarButton: ToolbarButton?

    private let columnCount = 5
    private let tileWidth: CGFloat = 300
    private let tileHeight: CGFloat = 360
    private let gridSpacing: CGFloat = 50

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(tileWidth), spacing: gridSpacing), count: columnCount)
    }

    private var hasActiveFilter: Bool {
        filters.activeCount > 0
    }

    private var activeFilterCount: Int {
        filters.activeCount
    }

    private var visibleBuckets: [TimelineBucket] {
        Array(buckets.prefix(frontier))
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

            VStack(spacing: 18) {
                if isLoading {
                    filterAndSortToolbar
                        .padding(.horizontal, 72)
                    Spacer()
                    ProgressView("Loading timeline...")
                        .foregroundColor(.white)
                        .scaleEffect(1.5)
                    Spacer()
                } else if let errorMessage {
                    filterAndSortToolbar
                        .padding(.horizontal, 72)
                    Spacer()
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
                        Button("Retry") { reloadTimeline() }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                } else if buckets.isEmpty {
                    filterAndSortToolbar
                        .padding(.horizontal, 72)
                    Spacer()
                    VStack {
                        Image(systemName: "calendar")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text("No Photos Found")
                            .font(.title)
                            .foregroundColor(.white)
                        Text(activeFilterCount > 0 ? "Try changing the active filters" : "Your photos will appear here")
                            .foregroundColor(.gray)
                    }
                    Spacer()
                } else {
                    timelineContent(loadableThumbnailIds: thumbnailLoadAssetIds)
                }
            }
            .padding(.top, 20)
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
        .sheet(isPresented: $showingFilterModal) {
            FilterSettingsView(
                assetService: assetService,
                selection: $filters
            ) {
                applyFilters()
            }
        }
        .onAppear {
            print("🟢🟢🟢 TIMELINE-BUILD-CHECK v3: frontier-paginated TimelineView (renders only loaded buckets, no whole-library placeholders) IS RUNNING")
            if buckets.isEmpty && !isLoading {
                reloadTimeline()
            }
        }
    }

    private var filterAndSortToolbar: some View {
        HStack {
            Spacer()
            filterAndSortButtons
        }
    }

    private var filterAndSortButtons: some View {
        HStack(spacing: 30) {
            Button(action: { showingFilterModal = true }) {
                Label {
                    Text("Filter \(activeFilterCount > 0 ? "(\(activeFilterCount))" : "")")
                } icon: {
                    Image(systemName: activeFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
            .buttonStyle(.bordered)
            .focused($focusedToolbarButton, equals: .filter)

            Button(action: resetFilters) {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .focused($focusedToolbarButton, equals: .resetFilters)
            .disabled(!hasActiveFilter)
            .accessibilityLabel("Reset timeline filters")
            .accessibilityHint("Clears all active photo filters")

            AllPhotosSortButton(
                sortOrder: allPhotosSortOrder,
                action: toggleSortOrder,
                accessibilityLabel: "Sort timeline by date taken"
            )
            .focused($focusedToolbarButton, equals: .sort)
        }
    }

    private func toggleSortOrder() {
        allPhotosSortOrder = allPhotosSortOrder == "asc" ? "desc" : "asc"
        reloadTimeline()
    }

    private func resetFilters() {
        guard hasActiveFilter else { return }
        filters.reset()
        filters.save()
        reloadTimeline()
    }

    // MARK: - Month section

    private func timelineContent(loadableThumbnailIds: Set<String>) -> some View {
        let renderedBuckets = visibleBuckets

        return ScrollViewReader { proxy in
            ScrollView {
                if let firstBucket = renderedBuckets.first {
                    timelineHeader(for: firstBucket)
                        .padding(.horizontal, 72)
                        .padding(.top, 16)
                        .id(ScrollAnchor.top)
                }

                // A SINGLE lazy grid, and we only ever declare the buckets
                // committed so far (`prefix(frontier)`) — not the whole
                // library. Both matter for the tvOS focus engine: declaring
                // every bucket's cells up front makes focus movement search
                // an enormous candidate/occluder set and hang for seconds.
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    if let firstBucket = renderedBuckets.first {
                        Section {
                            sectionContent(for: firstBucket, loadableThumbnailIds: loadableThumbnailIds)
                        }
                    }

                    ForEach(renderedBuckets.dropFirst()) { bucket in
                        Section {
                            sectionContent(for: bucket, loadableThumbnailIds: loadableThumbnailIds)
                        } header: {
                            sectionHeader(for: bucket)
                        }
                    }
                }
                // The controls sit on the right while a one-result grid starts
                // on the far left. Expand both regions to bridge that gap.
                .focusSection()
                .padding(.horizontal)
                .padding(.top, 20)
                .onExitCommand {
                    guard focusedAssetId != nil else { return }

                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(ScrollAnchor.top, anchor: .top)
                    }
                    focusedAssetId = nil

                    Task { @MainActor in
                        await Task.yield()
                        focusedToolbarButton = .filter
                    }
                }

                // Load-more sentinel: when the bottom of the committed
                // content scrolls into view, commit the next screenful of
                // buckets. Mirrors All Photos' paginated load-more.
                Color.clear
                    .frame(height: 1)
                    .onAppear { growFrontier() }
                    .padding(.bottom, 40)

                if isLoadingFilteredPage {
                    ProgressView("Loading more...")
                        .foregroundColor(.white)
                        .padding(.bottom, 40)
                }
            }
            .onScrollPhaseChange { _, newPhase in
                isScrolling = newPhase.isScrolling
            }
        }
    }

    private func timelineHeader(for bucket: TimelineBucket) -> some View {
        HStack(spacing: 30) {
            Text(Self.monthLabel(for: bucket.timeBucket))
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            Spacer(minLength: 30)

            filterAndSortButtons
        }
        // Pair with the grid's focus section so navigation across the wide
        // title/control gap works in both directions for a one-item result.
        .focusSection()
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
                allowsThumbhashPlaceholder: false,
                showsDateOverlay: false
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

    private func reloadTimeline() {
        guard authService.isAuthenticated else {
            errorMessage = "Not authenticated. Please check your credentials."
            isLoading = false
            return
        }

        let generation = UUID()
        loadGeneration = generation
        buckets = []
        bucketAssets = [:]
        loadingBuckets = []
        frontier = 0
        visibleAssetIds = []
        focusedAssetId = nil
        filteredNextPage = nil
        isLoadingFilteredPage = false
        isLoading = true
        errorMessage = nil

        if hasActiveFilter {
            loadFilteredTimelinePage(1, generation: generation, isInitialPage: true)
        } else {
            loadBuckets(generation: generation)
        }
    }

    private func loadBuckets(generation: UUID) {
        let order = allPhotosSortOrder

        Task {
            do {
                let fetched = try await assetService.fetchTimelineBuckets(order: order)
                let sorted = Self.filteredAndSortedBuckets(fetched, order: order, year: nil)

                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.buckets = sorted
                    self.isLoading = false
                    // Commit and load the first screenful of buckets.
                    self.growFrontier()
                }
            } catch {
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
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
        if hasActiveFilter {
            if let nextPage = filteredNextPage, !isLoadingFilteredPage {
                loadFilteredTimelinePage(nextPage, generation: loadGeneration, isInitialPage: false)
            }
            return
        }

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
        let generation = loadGeneration
        let order = allPhotosSortOrder

        Task {
            do {
                let assets = try await assetService.fetchBucketAssets(timeBucket: key, order: order)
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.bucketAssets[key] = assets
                    self.loadingBuckets.remove(key)
                }
            } catch {
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    // Leave unloaded so it retries when the section reappears.
                    self.loadingBuckets.remove(key)
                }
            }
        }
    }

    private func loadFilteredTimelinePage(_ page: Int, generation: UUID, isInitialPage: Bool) {
        guard !isLoadingFilteredPage else { return }
        isLoadingFilteredPage = true
        let order = allPhotosSortOrder
        let filters = filters

        Task {
            do {
                let result = try await assetService.fetchFilteredTimelineAssets(
                    page: page,
                    size: filteredPageSize,
                    order: order,
                    city: filters.city,
                    state: filters.state,
                    country: filters.country,
                    cameraMake: filters.cameraMake,
                    cameraModel: filters.cameraModel,
                    lensModel: filters.lensModel,
                    year: filters.year
                )
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.mergeFilteredAssets(result.assets, order: order, replacing: isInitialPage)
                    self.filteredNextPage = Self.nextPageNumber(from: result.nextPage, after: page)
                    self.isLoadingFilteredPage = false
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    guard self.loadGeneration == generation else { return }
                    self.isLoadingFilteredPage = false
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func mergeFilteredAssets(_ newAssets: [ImmichAsset], order: String, replacing: Bool) {
        var merged = replacing ? [] : loadedAssetsInOrder
        var seen = Set(merged.map(\.id))
        merged.append(contentsOf: newAssets.filter { seen.insert($0.id).inserted })

        let grouped = Dictionary(grouping: merged, by: Self.monthBucketKey(for:))
        let keys = grouped.keys.sorted { order == "asc" ? $0 < $1 : $0 > $1 }
        buckets = keys.map { TimelineBucket(timeBucket: $0, count: grouped[$0]?.count ?? 0) }
        bucketAssets = Dictionary(uniqueKeysWithValues: keys.map { ($0, grouped[$0] ?? []) })
        frontier = buckets.count
    }

    private func applyFilters() {
        filters.save()
        showingFilterModal = false
        reloadTimeline()
    }

    // MARK: - Formatting

    static func monthBucketKey(for asset: ImmichAsset) -> String {
        let captureDate = asset.localDateTime.isEmpty ? asset.fileCreatedAt : asset.localDateTime
        let month = String(captureDate.prefix(7))
        return "\(month)-01T00:00:00.000Z"
    }

    static func nextPageNumber(from nextPage: String?, after currentPage: Int) -> Int? {
        guard let nextPage, !nextPage.isEmpty else { return nil }
        if let page = Int(nextPage) { return page }
        if let components = URLComponents(string: nextPage),
           let value = components.queryItems?.first(where: { $0.name == "page" })?.value,
           let page = Int(value) {
            return page
        }
        return currentPage + 1
    }

    static func filteredAndSortedBuckets(_ buckets: [TimelineBucket], order: String, year: Int?) -> [TimelineBucket] {
        let yearFiltered = year.map { selectedYear in
            buckets.filter { $0.timeBucket.hasPrefix(String(selectedYear)) }
        } ?? buckets

        return yearFiltered.sorted { first, second in
            order == "asc" ? first.timeBucket < second.timeBucket : first.timeBucket > second.timeBucket
        }
    }

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
