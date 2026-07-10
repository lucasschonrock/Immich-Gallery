//
//  TagsGridView.swift
//  Immich Gallery
//

import SwiftUI

struct TagsGridView: View {
    @ObservedObject var tagService: TagService
    @ObservedObject var authService: AuthenticationService
    @ObservedObject var assetService: AssetService
    @State private var tags: [Tag] = []
    @State private var selectedTag: Tag?
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    private var thumbnailProvider: TagThumbnailProvider {
        TagThumbnailProvider(assetService: assetService)
    }
    
    var body: some View {
        TagLockupGridView(
            tags: tags,
            thumbnailProvider: thumbnailProvider,
            isLoading: isLoading,
            errorMessage: errorMessage,
            onTagSelected: { tag in
                selectedTag = tag
            },
            onRetry: {
                Task {
                    await loadTags()
                }
            }
        )
        .fullScreenCover(item: $selectedTag) { tag in
            TagDetailView(tag: tag, assetService: assetService, authService: authService)
        }
        .onAppear {
            if tags.isEmpty {
                Task {
                    await loadTags()
                }
            }
        }
    }
    
    private func loadTags() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let fetchedTags = try await tagService.fetchTags()
            await MainActor.run {
                self.tags = fetchedTags
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to load tags: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
}

private struct TagLockupGridView: View {
    let tags: [Tag]
    let thumbnailProvider: TagThumbnailProvider
    let isLoading: Bool
    let errorMessage: String?
    let onTagSelected: (Tag) -> Void
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
                ProgressView("Loading tags...")
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
            } else if tags.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tag")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("No Tags")
                        .font(.title)
                        .foregroundColor(.white)
                    Text("Your tags will appear here.")
                        .foregroundColor(.gray)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .center, spacing: 30) {
                        ForEach(tags) { tag in
                            Button {
                                onTagSelected(tag)
                            } label: {
                                TagLockupCard(
                                    tag: tag,
                                    thumbnailProvider: thumbnailProvider,
                                    cardSize: CGSize(width: cardWidth, height: cardHeight)
                                )
                            }
                            .frame(width: cardWidth, height: cardHeight)
                            .buttonStyle(CardButtonStyle())
                            .accessibilityLabel(accessibilityLabel(for: tag))
                        }
                    }
                    .padding(.horizontal, 72)
                    .padding(.vertical, 48)
                }
            }
        }
    }

    private func accessibilityLabel(for tag: Tag) -> String {
        let title = TagMetadataFormatter.displayName(for: tag)
        if let subtitle = TagMetadataFormatter.subtitle(for: tag) {
            return "\(title), \(subtitle)"
        }
        return title
    }
}

private struct TagLockupCard: View {
    let tag: Tag
    let thumbnailProvider: TagThumbnailProvider
    let cardSize: CGSize
    @AppStorage(UserDefaultsKeys.lockupThumbnailMode) private var lockupThumbnailMode = LockupThumbnailMode.current.rawValue

    var body: some View {
        AsyncLandscapeOverlayLockupCard(
            taskId: "\(tag.id)-\(lockupThumbnailMode)",
            title: TagMetadataFormatter.displayName(for: tag),
            subtitle: nil,
            leadingIconName: tag.iconName,
            primaryMetadata: TagMetadataFormatter.valueMetadata(for: tag),
            secondaryMetadata: nil,
            trailingStatusIconNames: [],
            fallbackIconName: tag.iconName,
            fallbackTint: tag.gridColor ?? .secondary,
            cardSize: cardSize
        ) {
            await thumbnailProvider.loadCoverThumbnail(for: tag)
        }
    }
}

private enum TagMetadataFormatter {
    static func displayName(for tag: Tag) -> String {
        tag.name
    }

    static func subtitle(for tag: Tag) -> String? {
        guard !tag.value.isEmpty, tag.value != tag.name else {
            return nil
        }
        return tag.value
    }

    static func valueMetadata(for tag: Tag) -> String? {
        guard !tag.value.isEmpty, tag.value != tag.name else {
            return nil
        }
        return tag.value
    }
}


struct TagDetailView: View {
    let tag: Tag
    @ObservedObject var assetService: AssetService
    @ObservedObject var authService: AuthenticationService
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black
                    .ignoresSafeArea()
                
                AssetGridView(assetService: assetService,
                              authService: authService,
                              assetProvider: AssetProviderFactory.createProvider(
                                tagId: tag.id,
                                assetService: assetService
                              ),
                              albumId: nil, personId: nil,
                              tagId: tag.id,
                              city: nil,
                              isAllPhotos: false,
                              isFavorite: false,
                              onAssetsLoaded: nil,
                              deepLinkAssetId: nil)
            }
            .navigationTitle(tag.name)
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
    let (_, _, authService, assetService, _, _, tagService, _) =
    MockServiceFactory.createMockServices()
    TagsGridView(tagService: tagService, authService: authService, assetService: assetService)
}
