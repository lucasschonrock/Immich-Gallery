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
    
    @State private var folders: [ImmichFolder] = []
    @State private var visibleFolders: [ImmichFolder] = []
    @State private var selectedFolder: ImmichFolder?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoadedFolders = false
    @State private var isAppendingFolders = false

    private let folderBatchSize = 300
    
    private let thumbnailProvider: FolderThumbnailProvider

    init(folderService: FolderService, assetService: AssetService, authService: AuthenticationService) {
        self._folderService = ObservedObject(wrappedValue: folderService)
        self._assetService = ObservedObject(wrappedValue: assetService)
        self._authService = ObservedObject(wrappedValue: authService)
        self.thumbnailProvider = FolderThumbnailProvider(assetService: assetService)
    }
    
    var body: some View {
        FolderLockupGridView(
            folders: visibleFolders,
            thumbnailProvider: thumbnailProvider,
            isLoading: isLoading,
            errorMessage: errorMessage,
            onFolderSelected: { folder in
                selectedFolder = folder
            },
            onFolderAppear: { folder in
                loadNextFolderBatchIfNeeded(currentItem: folder)
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
            if folders.isEmpty && !isLoading && !hasLoadedFolders {
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
            let processedFolders = await Task.detached(priority: .userInitiated) { () -> [ImmichFolder] in
                // Deduplicate by path and use a lightweight case-insensitive sort.
                // Keep this work off the main actor to avoid UI stalls on large libraries.
                var seen = Set<String>()
                var unique: [ImmichFolder] = []
                unique.reserveCapacity(fetchedFolders.count)

                for folder in fetchedFolders {
                    if seen.insert(folder.path).inserted {
                        unique.append(folder)
                    }
                }

                unique.sort { $0.path.localizedLowercase < $1.path.localizedLowercase }
                return unique
            }.value

            await MainActor.run {
                self.folders = processedFolders
                self.visibleFolders = Array(processedFolders.prefix(folderBatchSize))
                self.isLoading = false
                self.hasLoadedFolders = true
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to load folders: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    private func loadNextFolderBatchIfNeeded(currentItem: ImmichFolder) {
        guard !isAppendingFolders else { return }
        guard currentItem.id == visibleFolders.last?.id else { return }
        guard visibleFolders.count < folders.count else { return }

        isAppendingFolders = true

        let nextEndIndex = min(visibleFolders.count + folderBatchSize, folders.count)
        visibleFolders = Array(folders.prefix(nextEndIndex))

        // Release append lock after this render pass.
        DispatchQueue.main.async {
            isAppendingFolders = false
        }
    }
}

private struct FolderLockupGridView: View {
    let folders: [ImmichFolder]
    let thumbnailProvider: FolderThumbnailProvider
    let isLoading: Bool
    let errorMessage: String?
    let onFolderSelected: (ImmichFolder) -> Void
    let onFolderAppear: (ImmichFolder) -> Void
    let onRetry: () -> Void

    private let cardWidth: CGFloat = 500
    private let cardHeight: CGFloat = 300

    private let columns = [
        GridItem(.fixed(500), spacing: 30),
        GridItem(.fixed(500), spacing: 30),
        GridItem(.fixed(500), spacing: 30)
    ]

    var body: some View {
        ZStack {
            SharedGradientBackground()

            if isLoading {
                ProgressView("Loading folders...")
                    .foregroundColor(.white)
                    .scaleEffect(1.5)
            } else if let errorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 60))
                        .foregroundColor(.orange)
                    Text("Error")
                        .font(.title)
                        .foregroundColor(.white)
                    Text(errorMessage)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 80)
                    Button("Retry", action: onRetry)
                        .buttonStyle(.borderedProminent)
                }
            } else if folders.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("No Folders")
                        .font(.title)
                        .foregroundColor(.white)
                    Text("Folders with indexed assets will appear here.")
                        .foregroundColor(.gray)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .center, spacing: 30) {
                        ForEach(folders) { folder in
                            Button {
                                onFolderSelected(folder)
                            } label: {
                                FolderLockupCard(
                                    folder: folder,
                                    thumbnailProvider: thumbnailProvider,
                                    cardSize: CGSize(width: cardWidth, height: cardHeight)
                                )
                            }
                            .frame(width: cardWidth, height: cardHeight)
                            .buttonStyle(CardButtonStyle())
                            .accessibilityLabel(accessibilityLabel(for: folder))
                            .onAppear {
                                onFolderAppear(folder)
                            }
                        }
                    }
                    .padding(.horizontal, 72)
                    .padding(.vertical, 48)
                }
            }
        }
    }

    private func accessibilityLabel(for folder: ImmichFolder) -> String {
        let title = FolderMetadataFormatter.displayName(for: folder)
        if let subtitle = FolderMetadataFormatter.subtitle(for: folder) {
            return "\(title), \(subtitle)"
        }
        return title
    }
}

private struct FolderLockupCard: View {
    let folder: ImmichFolder
    let thumbnailProvider: FolderThumbnailProvider
    let cardSize: CGSize
    @AppStorage(UserDefaultsKeys.lockupThumbnailMode) private var lockupThumbnailMode = LockupThumbnailMode.current.rawValue

    var body: some View {
        AsyncLandscapeOverlayLockupCard(
            taskId: "\(folder.path)-\(lockupThumbnailMode)",
            title: FolderMetadataFormatter.displayName(for: folder),
            subtitle: nil,
            leadingIconName: folder.iconName,
            primaryMetadata: FolderMetadataFormatter.pathMetadata(for: folder),
            secondaryMetadata: nil,
            trailingStatusIconNames: [],
            fallbackIconName: folder.iconName,
            fallbackTint: folder.gridColor ?? .secondary,
            cardSize: cardSize
        ) {
            await thumbnailProvider.loadCoverThumbnail(for: folder)
        }
    }
}

private enum FolderMetadataFormatter {
    static func displayName(for folder: ImmichFolder) -> String {
        folder.primaryTitle.isEmpty ? folder.path : folder.primaryTitle
    }

    static func subtitle(for folder: ImmichFolder) -> String? {
        folder.path == displayName(for: folder) ? nil : folder.path
    }

    static func pathMetadata(for folder: ImmichFolder) -> String? {
        folder.path == displayName(for: folder) ? nil : folder.path
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
