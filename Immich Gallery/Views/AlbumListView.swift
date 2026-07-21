//
//  AlbumListView.swift
//  Immich Gallery
//
//  Created by mensadi-labs on 2025-06-29.
//

import SwiftUI

struct AlbumListView: View {
    @ObservedObject var albumService: AlbumService
    @ObservedObject var authService: AuthenticationService
    @ObservedObject var assetService: AssetService
    @ObservedObject var userManager: UserManager
    @State private var albums: [ImmichAlbum] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var favoritesCount: Int = 0
    @State private var firstFavoriteAssetId: String?
    @State private var lockedAssetsCount: Int = 0
    @State private var selectedAlbum: ImmichAlbum?
    @State private var pendingLockedAlbum: ImmichAlbum?
    @State private var showingLockedPinPrompt = false
    @State private var lockedPinCode = ""
    @State private var lockedPinError: String?
    @State private var isUnlockingLockedAlbum = false
    @State private var isLockedFolderDetailOpen = false

    private var thumbnailProvider: AlbumThumbnailProvider {
        AlbumThumbnailProvider(albumService: albumService, assetService: assetService)
    }

    private var allAlbums: [ImmichAlbum] {
        var result = albums
        if let lockedAlbum = createLockedAlbum() {
            result.insert(lockedAlbum, at: 0)
        }
        if let favAlbums = createFavoritesAlbum() {
            result.insert(favAlbums, at: 0)
        }
        return result
    }

    var body: some View {
        AlbumLockupGridView(
            albums: allAlbums,
            thumbnailProvider: thumbnailProvider,
            isLoading: isLoading,
            errorMessage: errorMessage,
            currentUserEmail: userManager.currentUser?.email,
            onAlbumSelected: { album in
                handleAlbumSelection(album)
            },
            onRetry: loadAlbums
        )
        .fullScreenCover(item: $selectedAlbum, onDismiss: lockLockedFolderSessionIfNeeded) { album in
            AlbumDetailView(album: album, albumService: albumService, authService: authService, assetService: assetService)
        }
        .onAppear {
            if albums.isEmpty {
                loadAlbums()
                loadFavoritesCount()
                loadLockedAssetsSummary()
            }
        }
        .sheet(
            isPresented: $showingLockedPinPrompt,
            onDismiss: resetLockedPinPrompt
        ) {
            LockedPinEntryPanel(
                pinCode: $lockedPinCode,
                errorMessage: lockedPinError,
                isUnlocking: isUnlockingLockedAlbum,
                onUnlock: unlockLockedAlbum
            )
        }
    }

    private func createFavoritesAlbum() -> ImmichAlbum?  {

        if let user = userManager.currentUser {
            let owner = Owner(
                id: user.id,
                email: user.email,
                name: user.name,
                profileImagePath: "",
                profileChangedAt: "",
                avatarColor: "primary"
            )

            return ImmichAlbum(
                id: "smart_favorites",
                albumName: "Favorites",
                description: "Collection",
                albumThumbnailAssetId: firstFavoriteAssetId,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                albumUsers: [],
                assets: [],
                assetCount: favoritesCount,
                ownerId: user.id,
                owner: owner,
                shared: false,
                hasSharedLink: false,
                isActivityEnabled: false,
                lastModifiedAssetTimestamp: nil,
                order: nil,
                startDate: nil,
                endDate: nil
            )
        }
        return nil
    }

    private func createLockedAlbum() -> ImmichAlbum? {
        guard let user = userManager.currentUser else {
            return nil
        }

        let owner = Owner(
            id: user.id,
            email: user.email,
            name: user.name,
            profileImagePath: "",
            profileChangedAt: "",
            avatarColor: "primary"
        )

        return ImmichAlbum(
            id: "smart_locked",
            albumName: "Locked Folder",
            description: "Protected",
            albumThumbnailAssetId: nil,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            albumUsers: [],
            assets: [],
            assetCount: lockedAssetsCount,
            ownerId: user.id,
            owner: owner,
            shared: false,
            hasSharedLink: false,
            isActivityEnabled: false,
            lastModifiedAssetTimestamp: nil,
            order: nil,
            startDate: nil,
            endDate: nil
        )
    }

    private func loadFavoritesCount() {
        guard authService.isAuthenticated else { return }

        Task {
            do {
                let result = try await assetService.fetchAssets(page: 1, limit: nil, isFavorite: true)
                await MainActor.run {
                    self.favoritesCount = result.total
                    self.firstFavoriteAssetId = result.assets.first?.id
                }
            } catch {
                print("Failed to fetch favorites count: \(error)")
            }
        }
    }

    private func loadLockedAssetsSummary() {
        guard authService.isAuthenticated else { return }

        Task {
            do {
                let result = try await assetService.fetchLockedAssets(page: 1, limit: nil)
                await MainActor.run {
                    lockedAssetsCount = result.total
                }
            } catch {
                print("Failed to fetch locked assets summary: \(error)")
            }
        }
    }

    private func loadAlbums() {
        guard authService.isAuthenticated else {
            errorMessage = "Not authenticated. Please check your credentials."
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let fetchedAlbums = try await albumService.fetchAlbums()
                await MainActor.run {
                    // Filter out the config album from the display
                    let configAlbumName = AppConstants.configAlbumName
                    self.albums = fetchedAlbums.filter { $0.albumName !=  configAlbumName }
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func handleAlbumSelection(_ album: ImmichAlbum) {
        guard album.id == "smart_locked" else {
            selectedAlbum = album
            return
        }

        pendingLockedAlbum = album
        lockedPinCode = ""
        lockedPinError = nil
        showingLockedPinPrompt = true
    }

    private func resetLockedPinPrompt() {
        pendingLockedAlbum = nil
        lockedPinCode = ""
        lockedPinError = nil
        isUnlockingLockedAlbum = false
    }

    private func unlockLockedAlbum() {
        let trimmedPin = lockedPinCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPin.isEmpty else { return }

        lockedPinError = nil
        isUnlockingLockedAlbum = true

        Task {
            do {
                try await authService.unlockAuthSession(pinCode: trimmedPin)
                await MainActor.run {
                    isUnlockingLockedAlbum = false
                    isLockedFolderDetailOpen = true
                    showingLockedPinPrompt = false
                    lockedPinCode = ""
                    selectedAlbum = pendingLockedAlbum
                }
            } catch {
                await MainActor.run {
                    lockedPinError = error.localizedDescription
                    isUnlockingLockedAlbum = false
                }
            }
        }
    }

    private func lockLockedFolderSessionIfNeeded() {
        guard isLockedFolderDetailOpen else { return }
        isLockedFolderDetailOpen = false

        Task {
            do {
                try await authService.lockAuthSession()
            } catch {
                print("Failed to lock auth session after leaving locked folder: \(error)")
            }
        }
    }
}

private struct AlbumLockupGridView: View {
    let albums: [ImmichAlbum]
    let thumbnailProvider: AlbumThumbnailProvider
    let isLoading: Bool
    let errorMessage: String?
    let currentUserEmail: String?
    let onAlbumSelected: (ImmichAlbum) -> Void
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
                ProgressView("Loading albums...")
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
            } else if albums.isEmpty {
                ReloadableEmptyStateView(
                    icon: "folder",
                    title: "No Albums",
                    message: "Create albums in Immich to see them here.",
                    onReload: onRetry
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .center, spacing: 30) {
                        ForEach(albums) { album in
                            Button {
                                onAlbumSelected(album)
                            } label: {
                                AlbumLockupCard(
                                    album: album,
                                    thumbnailProvider: thumbnailProvider,
                                    currentUserEmail: currentUserEmail,
                                    cardSize: CGSize(width: cardWidth, height: cardHeight)
                                )
                            }
                            .frame(width: cardWidth, height: cardHeight)
                            .buttonStyle(CardButtonStyle())
                            .accessibilityLabel(accessibilityLabel(for: album))
                        }
                    }
                    .padding(.horizontal, 72)
                    .padding(.vertical, 48)
                }
            }
        }
    }

    private func accessibilityLabel(for album: ImmichAlbum) -> String {
        var parts = [album.albumName, AlbumMetadataFormatter.photoCount(album.assetCount)]

        if album.shared {
            switch album.sharingDirection(currentUserEmail: currentUserEmail) {
            case .outgoing:
                parts.append("Shared by you")
            case .incoming:
                parts.append("Shared with you")
            case .unknown:
                parts.append("Shared")
            }
        }

        return parts.joined(separator: ", ")
    }
}

private struct AlbumLockupCard: View {
    let album: ImmichAlbum
    let thumbnailProvider: AlbumThumbnailProvider
    let currentUserEmail: String?
    let cardSize: CGSize
    @AppStorage(UserDefaultsKeys.lockupThumbnailMode) private var lockupThumbnailMode = LockupThumbnailMode.current.rawValue

    private var isSmartAlbum: Bool {
        album.id.hasPrefix("smart_")
    }

    var body: some View {
        AsyncLandscapeOverlayLockupCard(
            taskId: coverTaskId,
            title: album.albumName,
            subtitle: nil,
            leadingIconName: isSmartAlbum ? album.iconName : nil,
            primaryMetadata: AlbumMetadataFormatter.photoCount(album.assetCount),
            secondaryMetadata: nil,
            trailingStatusIconNames: trailingStatusIconNames,
            fallbackIconName: album.iconName,
            fallbackTint: album.gridColor ?? .secondary,
            cardSize: cardSize
        ) {
            await thumbnailProvider.loadCoverThumbnail(for: album)
        }
    }

    private var coverTaskId: String {
        "\(album.id)-\(album.albumThumbnailAssetId ?? "none")-\(lockupThumbnailMode)"
    }

    private var trailingStatusIconNames: [String] {
        var icons: [String] = []

        if album.shared {
            switch album.sharingDirection(currentUserEmail: currentUserEmail) {
            case .outgoing:
                icons.append("arrow.up.right.circle.fill")
            case .incoming:
                icons.append("arrow.down.left.circle.fill")
            case .unknown:
                icons.append("person.2.fill")
            }
        }

        if album.hasSharedLink {
            icons.append("link")
        }

        return icons
    }
}

private enum AlbumMetadataFormatter {
    static func photoCount(_ count: Int) -> String {
        let formatted = count.formatted(.number)
        return count == 1 ? "\(formatted) photo" : "\(formatted) photos"
    }

}

private enum AlbumSharingDirection {
    case outgoing
    case incoming
    case unknown
}

private extension ImmichAlbum {
    func sharingDirection(currentUserEmail: String?) -> AlbumSharingDirection {
        guard let ownerEmail = owner?.email.trimmingCharacters(in: .whitespacesAndNewlines),
              let currentUserEmail = currentUserEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ownerEmail.isEmpty,
              !currentUserEmail.isEmpty else {
            return .unknown
        }

        return ownerEmail.caseInsensitiveCompare(currentUserEmail) == .orderedSame
            ? .outgoing
            : .incoming
    }
}

private struct LockedPinEntryPanel: View {
    @Binding var pinCode: String
    let errorMessage: String?
    let isUnlocking: Bool
    let onUnlock: () -> Void

    private var isUnlockDisabled: Bool {
        isUnlocking || pinCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Unlock Locked Folder")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Text("PIN")
                    .font(.headline)

                SecureField("Locked folder PIN", text: $pinCode)
                    .keyboardType(.numberPad)
                    .submitLabel(.done)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
                    .onSubmit {
                        onUnlock()
                    }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button(isUnlocking ? "Unlocking..." : "Unlock", action: onUnlock)
                    .buttonStyle(.borderedProminent)
                    .disabled(isUnlockDisabled)
                Spacer()
            }
        }
        .padding(24)
    }
}

private struct LockedPinEntryPanelPreview: View {
    @State private var pinCode = "1234"

    var body: some View {
        LockedPinEntryPanel(
            pinCode: $pinCode,
            errorMessage: "Incorrect PIN. Please try again.",
            isUnlocking: false,
            onUnlock: {}
        )
    }
}


struct AlbumDetailView: View {
    let album: ImmichAlbum
    @ObservedObject var albumService: AlbumService
    @ObservedObject var authService: AuthenticationService
    @ObservedObject var assetService: AssetService
    @Environment(\.dismiss) private var dismiss
    @State private var albumAssets: [ImmichAsset] = []
    @State private var slideshowTrigger: Bool = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                AssetGridView(
                    assetService: assetService,
                    authService: authService,
                    assetProvider: createAssetProvider(for: album),
                    albumId: album.id.hasPrefix("smart_") ? nil : album.id,
                    personId: nil,
                    tagId: nil,
                    city: nil,
                    isAllPhotos: false,
                    isFavorite: album.id == "smart_favorites",
                    isLocked: album.id == "smart_locked",
                    onAssetsLoaded: { loadedAssets in
                        self.albumAssets = loadedAssets
                    },
                    deepLinkAssetId: nil
                )
            }
            .navigationTitle(album.albumName)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: startSlideshow) {
                        Image(systemName: "play.rectangle")
                            .foregroundColor(.white)
                    }
                    .disabled(albumAssets.isEmpty)
                }

                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $slideshowTrigger) {
            SlideshowView(
                albumId: album.id.hasPrefix("smart_") ? nil : album.id,
                personId: nil,
                tagId: nil,
                city: nil,
                startingIndex: 0,
                isFavorite: album.id == "smart_favorites",
                isLocked: album.id == "smart_locked"
            )
        }
        .onAppear(){
            print("Album defaul view")
        }
    }

    private func createAssetProvider(for album: ImmichAlbum) -> AssetProvider {
        if album.id == "smart_favorites" {
            return AssetProviderFactory.createProvider(
                isFavorite: true,
                assetService: assetService
            )
        } else if album.id == "smart_locked" {
            return AssetProviderFactory.createProvider(
                isLocked: true,
                assetService: assetService
            )
        } else {
            return AssetProviderFactory.createProvider(
                albumId: album.id,
                assetService: assetService,
                albumService: albumService
            )
        }
    }

    private func startSlideshow() {
        NotificationCenter.default.post(name: NSNotification.Name(NotificationNames.pauseInactivityMonitoring), object: nil)
        slideshowTrigger = true
    }
}

#Preview {
    let (_, userManager, authService, assetService, albumService, peopleService, _, _) =
         MockServiceFactory.createMockServices()
    AlbumListView(albumService: albumService, authService: authService, assetService: assetService, userManager: userManager)
}

#Preview("Locked PIN Entry") {
    LockedPinEntryPanelPreview()
}
