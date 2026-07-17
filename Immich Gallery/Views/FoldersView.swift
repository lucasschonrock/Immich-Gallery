//
//  FoldersView.swift
//  Immich Gallery
//
//  Created by Codex on 2025-09-12.
//

import SwiftUI

struct FoldersView: View {
    @ObservedObject var folderService: FolderService
    @ObservedObject var assetService: AssetService
    @ObservedObject var authService: AuthenticationService

    @State private var hierarchyRoot: FolderHierarchyNode?
    @State private var selectedFolder: ImmichFolder?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoadedFolders = false

    private let thumbnailProvider: FolderThumbnailProvider

    init(folderService: FolderService, assetService: AssetService, authService: AuthenticationService) {
        self._folderService = ObservedObject(wrappedValue: folderService)
        self._assetService = ObservedObject(wrappedValue: assetService)
        self._authService = ObservedObject(wrappedValue: authService)
        self.thumbnailProvider = FolderThumbnailProvider(assetService: assetService)
    }

    var body: some View {
        FolderHierarchyView(
            root: hierarchyRoot,
            thumbnailProvider: thumbnailProvider,
            isLoading: isLoading,
            errorMessage: errorMessage,
            onOpenFolder: { folder in
                selectedFolder = folder
            },
            onRetry: {
                Task {
                    await loadFolders(forceRefresh: true)
                }
            }
        )
        .fullScreenCover(item: $selectedFolder) { folder in
            FolderDetailView(folder: folder, assetService: assetService, authService: authService)
        }
        .onAppear {
            if hierarchyRoot == nil && !isLoading && !hasLoadedFolders {
                Task {
                    await loadFolders()
                }
            }
        }
    }

    private func loadFolders(forceRefresh: Bool = false) async {
        guard !isLoading else { return }

        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }

        do {
            let fetchedFolders = try await folderService.fetchUniquePaths(forceRefresh: forceRefresh)
            let root = await Task.detached(priority: .userInitiated) {
                FolderHierarchyBuilder.build(from: fetchedFolders)
            }.value

            await MainActor.run {
                hierarchyRoot = root
                isLoading = false
                hasLoadedFolders = true
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to load folders: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
}

// MARK: - Hierarchy

struct FolderHierarchyNode: Identifiable, Hashable {
    let name: String
    let path: String
    let indexedFolder: ImmichFolder?
    let children: [FolderHierarchyNode]
    let indexedFolderCount: Int

    var id: String { path.isEmpty ? "folder-root" : path }

    var thumbnailFolder: ImmichFolder {
        indexedFolder ?? ImmichFolder(path: path)
    }
}

enum FolderHierarchyBuilder {
    static func build(from folders: [ImmichFolder]) -> FolderHierarchyNode? {
        let uniqueFolders = Dictionary(folders.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            .values
        guard !uniqueFolders.isEmpty else { return nil }

        let mutableRoot = MutableFolderNode(name: "Folders", path: "")

        for folder in uniqueFolders {
            let normalizedPath = folder.path.replacingOccurrences(of: "\\", with: "/")
            let components = normalizedPath.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            let isAbsolute = normalizedPath.hasPrefix("/")
            var current = mutableRoot
            var cumulativePath = ""

            for component in components {
                if cumulativePath.isEmpty {
                    cumulativePath = isAbsolute ? "/\(component)" : component
                } else {
                    cumulativePath += "/\(component)"
                }

                if let existing = current.children[component] {
                    current = existing
                } else {
                    let child = MutableFolderNode(name: component, path: cumulativePath)
                    current.children[component] = child
                    current = child
                }
            }

            current.indexedFolder = folder
        }

        var root = freeze(mutableRoot)

        // Shared storage prefixes add several meaningless one-item screens. Start at
        // the first useful branch while retaining the full path for Immich queries.
        while root.indexedFolder == nil, root.children.count == 1, let child = root.children.first {
            root = child
        }

        return root
    }

    private static func freeze(_ node: MutableFolderNode) -> FolderHierarchyNode {
        let children = node.children.values
            .map(freeze)
            .map(collapsingSingleChildChain)
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        let count = (node.indexedFolder == nil ? 0 : 1) + children.reduce(0) { $0 + $1.indexedFolderCount }

        return FolderHierarchyNode(
            name: node.name,
            path: node.path,
            indexedFolder: node.indexedFolder,
            children: children,
            indexedFolderCount: count
        )
    }

    private static func collapsingSingleChildChain(_ initialNode: FolderHierarchyNode) -> FolderHierarchyNode {
        var node = initialNode
        while node.indexedFolder == nil, node.children.count == 1, let child = node.children.first {
            node = child
        }
        return node
    }
}

private final class MutableFolderNode {
    let name: String
    let path: String
    var indexedFolder: ImmichFolder?
    var children: [String: MutableFolderNode] = [:]

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

private enum FolderBrowserItem: Identifiable, Hashable {
    case allPhotos(FolderHierarchyNode)
    case folder(FolderHierarchyNode)

    var id: String {
        switch self {
        case .allPhotos(let node): return "all-photos:\(node.id)"
        case .folder(let node): return "folder:\(node.id)"
        }
    }
}

enum FolderNameSortOrder: String {
    case ascending
    case descending

    var shortLabel: String {
        switch self {
        case .ascending: "A–Z"
        case .descending: "Z–A"
        }
    }

    var accessibilityValue: String {
        switch self {
        case .ascending: "Ascending, A to Z"
        case .descending: "Descending, Z to A"
        }
    }

    var toggled: FolderNameSortOrder {
        self == .ascending ? .descending : .ascending
    }

    func sorted(_ folders: [FolderHierarchyNode]) -> [FolderHierarchyNode] {
        folders.sorted { first, second in
            let comparison = first.name.localizedStandardCompare(second.name)
            return self == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
}

private struct FolderHierarchyView: View {
    let root: FolderHierarchyNode?
    let thumbnailProvider: FolderThumbnailProvider
    let isLoading: Bool
    let errorMessage: String?
    let onOpenFolder: (ImmichFolder) -> Void
    let onRetry: () -> Void

    @State private var navigationPath: [FolderHierarchyNode] = []
    @FocusState private var focusedItemID: String?
    @AppStorage(UserDefaultsKeys.folderNameSortOrder) private var folderNameSortOrderValue = FolderNameSortOrder.ascending.rawValue

    private let cardWidth: CGFloat = 500
    private let cardHeight: CGFloat = 300
    private let columns = [
        GridItem(.fixed(500), spacing: 30),
        GridItem(.fixed(500), spacing: 30),
        GridItem(.fixed(500), spacing: 30)
    ]

    private var currentNode: FolderHierarchyNode? {
        navigationPath.last ?? root
    }

    private var items: [FolderBrowserItem] {
        guard let currentNode else { return [] }
        var result = folderNameSortOrder.sorted(currentNode.children).map(FolderBrowserItem.folder)
        if !navigationPath.isEmpty || currentNode.indexedFolder != nil {
            result.insert(.allPhotos(currentNode), at: 0)
        }
        return result
    }

    private var folderNameSortOrder: FolderNameSortOrder {
        FolderNameSortOrder(rawValue: folderNameSortOrderValue) ?? .ascending
    }

    var body: some View {
        ZStack {
            SharedGradientBackground()

            if isLoading {
                loadingState
            } else if let errorMessage {
                errorState(errorMessage)
            } else if root == nil {
                emptyState
            } else {
                hierarchyContent
            }
        }
        .onChange(of: root?.id) { _, _ in
            navigationPath = []
        }
    }

    @ViewBuilder
    private var hierarchyContent: some View {
        if navigationPath.isEmpty {
            folderGrid
        } else {
            folderGrid
                .onExitCommand(perform: navigateUp)
        }
    }

    private var folderGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                header

                LazyVGrid(columns: columns, alignment: .center, spacing: 30) {
                    ForEach(items) { item in
                        Button {
                            select(item)
                        } label: {
                            FolderBrowserCard(
                                item: item,
                                thumbnailProvider: thumbnailProvider,
                                cardSize: CGSize(width: cardWidth, height: cardHeight)
                            )
                        }
                        .frame(width: cardWidth, height: cardHeight)
                        .buttonStyle(CardButtonStyle())
                        .focused($focusedItemID, equals: item.id)
                        .accessibilityLabel(accessibilityLabel(for: item))
                        .accessibilityHint(accessibilityHint(for: item))
                    }
                }
                // The sort control sits on the far right while a one-item grid
                // starts on the far left. Treat the grid as one focus region so
                // the focus engine can bridge that empty horizontal space.
                .focusSection()
            }
            .padding(.horizontal, 72)
            .padding(.top, 38)
            .padding(.bottom, 58)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: navigationPath.isEmpty ? "externaldrive.fill" : "folder.fill")
                .foregroundStyle(.white.opacity(0.68))
            Text(currentNode?.path ?? "")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.68))

            Spacer(minLength: 30)

            Text(folderCountLabel)
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.68))

            Spacer()
                .frame(width: 28)

            Button {
                folderNameSortOrderValue = folderNameSortOrder.toggled.rawValue
            } label: {
                Label(folderNameSortOrder.shortLabel, systemImage: "arrow.up.arrow.down")
                    .frame(width: 132)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: 180, alignment: .trailing)
            .accessibilityLabel("Sort folders by name")
            .accessibilityValue(folderNameSortOrder.accessibilityValue)
            .accessibilityHint("Toggles the folder name sort direction")
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 10)
        // Pair with the grid's focus section so navigation across the wide
        // header/content gap works in both directions with only one folder.
        .focusSection()
    }

    private var folderCountLabel: String {
        let count = currentNode?.indexedFolderCount ?? 0
        return "\(count) \(count == 1 ? "folder" : "folders")"
    }

    private var loadingState: some View {
        VStack(spacing: 26) {
            ProgressView()
                .scaleEffect(1.4)
            Text("Building your folder library")
                .font(.title2.weight(.semibold))
            Text("Organizing indexed paths into a hierarchy…")
                .font(.body)
                .foregroundStyle(.white.opacity(0.68))
        }
        .foregroundStyle(.white)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 22) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
            Text("Folders couldn’t be loaded")
                .font(.title2.weight(.bold))
            Text(message)
                .font(.body)
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 80)
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 68, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
            Text("No folders yet")
                .font(.title2.weight(.bold))
            Text("Folders with indexed assets will appear here.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.68))
        }
        .foregroundStyle(.white)
    }

    private func select(_ item: FolderBrowserItem) {
        switch item {
        case .allPhotos(let node):
            onOpenFolder(node.thumbnailFolder)
        case .folder(let node):
            if node.children.isEmpty {
                onOpenFolder(node.thumbnailFolder)
            } else {
                navigationPath.append(node)
                focusFirstItem()
            }
        }
    }

    private func navigateUp() {
        guard let previousNode = navigationPath.popLast() else { return }
        DispatchQueue.main.async {
            focusedItemID = FolderBrowserItem.folder(previousNode).id
        }
    }

    private func focusFirstItem() {
        DispatchQueue.main.async {
            focusedItemID = items.first?.id
        }
    }

    private func accessibilityLabel(for item: FolderBrowserItem) -> String {
        switch item {
        case .allPhotos(let node):
            return "All photos in \(node.name)"
        case .folder(let node):
            return "\(node.name), \(node.indexedFolderCount) indexed \(node.indexedFolderCount == 1 ? "folder" : "folders")"
        }
    }

    private func accessibilityHint(for item: FolderBrowserItem) -> String {
        switch item {
        case .allPhotos:
            return "Opens all photos below this folder"
        case .folder(let node):
            return node.children.isEmpty ? "Opens this folder's photos" : "Opens this folder"
        }
    }
}

private struct FolderBrowserCard: View {
    let item: FolderBrowserItem
    let thumbnailProvider: FolderThumbnailProvider
    let cardSize: CGSize
    @AppStorage(UserDefaultsKeys.lockupThumbnailMode) private var lockupThumbnailMode = LockupThumbnailMode.current.rawValue

    private var node: FolderHierarchyNode {
        switch item {
        case .allPhotos(let node), .folder(let node): return node
        }
    }

    private var isAllPhotos: Bool {
        if case .allPhotos = item { return true }
        return false
    }

    var body: some View {
        AsyncLandscapeOverlayLockupCard(
            taskId: "\(item.id)-\(lockupThumbnailMode)",
            title: isAllPhotos ? "All Photos" : node.name,
            subtitle: nil,
            leadingIconName: isAllPhotos ? "photo.stack.fill" : "folder.fill",
            primaryMetadata: metadata,
            secondaryMetadata: nil,
            trailingStatusIconNames: !isAllPhotos && !node.children.isEmpty ? ["chevron.right"] : [],
            fallbackIconName: isAllPhotos ? "photo.stack.fill" : "folder.fill",
            fallbackTint: isAllPhotos ? .purple.opacity(0.75) : .blue.opacity(0.7),
            cardSize: cardSize
        ) {
            await thumbnailProvider.loadCoverThumbnail(for: node.thumbnailFolder)
        }
    }

    private var metadata: String {
        if isAllPhotos {
            return "This folder and its subfolders"
        }

        if node.children.isEmpty {
            return "Open photos"
        }

        let count = node.indexedFolderCount
        return "\(count) \(count == 1 ? "folder" : "folders")"
    }
}

struct FolderDetailView: View {
    let folder: ImmichFolder
    @ObservedObject var assetService: AssetService
    @ObservedObject var authService: AuthenticationService
    @Environment(\.dismiss) private var dismiss

    private var folderTitle: String {
        folder.primaryTitle.isEmpty ? folder.path : folder.primaryTitle
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                AssetGridView(assetService: assetService,
                              authService: authService,
                              assetProvider: AssetProviderFactory.createProvider(
                                folderPath: folder.path,
                                assetService: assetService
                              ),
                              albumId: nil,
                              personId: nil,
                              tagId: nil,
                              city: nil,
                              isAllPhotos: false,
                              isFavorite: false,
                              onAssetsLoaded: nil,
                              deepLinkAssetId: nil)
            }
            .navigationTitle(folderTitle)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    let (_, _, authService, assetService, _, _, _, folderService) =
    MockServiceFactory.createMockServices()
    return FoldersView(folderService: folderService, assetService: assetService, authService: authService)
}
