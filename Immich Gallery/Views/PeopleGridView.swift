//
//  PeopleGridView.swift
//  Immich Gallery
//
//  Created by mensadi-labs on 2025-06-29.
//

import SwiftUI

struct PeopleGridView: View {
    @ObservedObject var peopleService: PeopleService
    @ObservedObject var authService: AuthenticationService
    @ObservedObject var assetService: AssetService
    @State private var people: [Person] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var currentPage = 1
    @State private var hasNextPage = false
    @State private var errorMessage: String?
    @State private var selectedPerson: Person?

    private let pageSize = 100

    private var thumbnailProvider: PeopleThumbnailProvider {
        PeopleThumbnailProvider(assetService: assetService)
    }

    var body: some View {
        PeopleLockupGridView(
            people: people,
            peopleService: peopleService,
            thumbnailProvider: thumbnailProvider,
            isLoading: isLoading,
            errorMessage: errorMessage,
            onPersonSelected: { person in
                print("Person selected: \(person.id)")
                selectedPerson = person
            },
            onPersonAppear: loadMorePeopleIfNeeded,
            onRetry: loadPeople
        )
        .fullScreenCover(item: $selectedPerson) { person in
            PersonPhotosView(person: person, peopleService: peopleService, authService: authService, assetService: assetService)
        }
        .onAppear {
            print("PeopleGridView: View appeared, people count: \(people.count), isLoading: \(isLoading), errorMessage: \(errorMessage ?? "nil")")
            if people.isEmpty {
                loadPeople()
            }
        }
    }

    private func loadPeople() {
        print("PeopleGridView: loadPeople called - isAuthenticated: \(authService.isAuthenticated)")
        guard authService.isAuthenticated else {
            errorMessage = "Not authenticated. Please check your credentials."
            return
        }

        print("Loading people - isAuthenticated: \(authService.isAuthenticated), baseURL: \(authService.baseURL)")

        isLoading = true
        isLoadingMore = false
        currentPage = 1
        hasNextPage = false
        errorMessage = nil
        print("PeopleGridView: Set loading state to true")

        Task {
            do {
                let response = try await peopleService.getPeoplePage(page: 1, size: pageSize)
                print("Successfully fetched \(response.people.count) people")
                await MainActor.run {
                    self.people = response.people
                    self.hasNextPage = response.hasNextPage ?? (response.people.count == pageSize)
                    self.isLoading = false
                    print("PeopleGridView: Updated UI with \(self.people.count) people, isLoading: \(self.isLoading)")
                }
            } catch {
                print("Error fetching people: \(error)")
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    print("PeopleGridView: Set error state, isLoading: \(self.isLoading)")
                }
            }
        }
    }

    private func loadMorePeopleIfNeeded(currentPerson: Person) {
        guard hasNextPage, !isLoading, !isLoadingMore else { return }
        guard let index = people.firstIndex(where: { $0.id == currentPerson.id }) else { return }

        let threshold = max(people.count - 20, 0)
        guard index >= threshold else { return }

        isLoadingMore = true
        let nextPage = currentPage + 1

        Task {
            do {
                let response = try await peopleService.getPeoplePage(page: nextPage, size: pageSize)
                await MainActor.run {
                    let existingIds = Set(self.people.map(\.id))
                    let newPeople = response.people.filter { !existingIds.contains($0.id) }
                    self.people.append(contentsOf: newPeople)
                    self.currentPage = nextPage
                    self.hasNextPage = response.hasNextPage ?? (response.people.count == pageSize)
                    self.isLoadingMore = false
                    print("PeopleGridView: Loaded page \(nextPage), total people: \(self.people.count), hasNextPage: \(self.hasNextPage)")
                }
            } catch {
                print("Error fetching more people: \(error)")
                await MainActor.run {
                    self.isLoadingMore = false
                }
            }
        }
    }
}

private struct PeopleLockupGridView: View {
    let people: [Person]
    let peopleService: PeopleService
    let thumbnailProvider: PeopleThumbnailProvider
    let isLoading: Bool
    let errorMessage: String?
    let onPersonSelected: (Person) -> Void
    let onPersonAppear: (Person) -> Void
    let onRetry: () -> Void

    private let cardWidth: CGFloat = 380
    private let cardHeight: CGFloat = 380

    private let columns = [
        GridItem(.fixed(380), spacing: 30),
        GridItem(.fixed(380), spacing: 30),
        GridItem(.fixed(380), spacing: 30),
        GridItem(.fixed(380), spacing: 30)
    ]

    var body: some View {
        ZStack {
            SharedGradientBackground()

            if isLoading {
                ProgressView("Loading people...")
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
            } else if people.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("No People")
                        .font(.title)
                        .foregroundColor(.white)
                    Text("People recognized by Immich will appear here.")
                        .foregroundColor(.gray)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .center, spacing: 30) {
                        ForEach(people) { person in
                            Button {
                                onPersonSelected(person)
                            } label: {
                                PersonLockupCard(
                                    person: person,
                                    peopleService: peopleService,
                                    thumbnailProvider: thumbnailProvider,
                                    cardSize: CGSize(width: cardWidth, height: cardHeight)
                                )
                            }
                            .frame(width: cardWidth, height: cardHeight)
                            .buttonStyle(CardButtonStyle())
                            .accessibilityLabel(accessibilityLabel(for: person))
                            .onAppear {
                                onPersonAppear(person)
                            }
                        }
                    }
                    .padding(.horizontal, 72)
                    .padding(.vertical, 48)
                }
            }
        }
    }

    private func accessibilityLabel(for person: Person) -> String {
        var parts = [PeopleMetadataFormatter.accessibilityName(for: person)]

        if person.isFavorite == true {
            parts.append("Favorite")
        }

        if person.isHidden {
            parts.append("Hidden")
        }

        return parts.joined(separator: ", ")
    }
}

private struct PersonLockupCard: View {
    let person: Person
    let peopleService: PeopleService
    let thumbnailProvider: PeopleThumbnailProvider
    let cardSize: CGSize
    @AppStorage(UserDefaultsKeys.lockupThumbnailMode) private var lockupThumbnailMode = LockupThumbnailMode.current.rawValue

    var body: some View {
        ZStack(alignment: .topLeading) {
            AsyncLandscapeOverlayLockupCard(
                taskId: coverTaskId,
                title: PeopleMetadataFormatter.displayName(for: person),
                subtitle: nil,
                leadingIconName: nil,
                primaryMetadata: nil,
                secondaryMetadata: nil,
                trailingStatusIconNames: trailingStatusIconNames,
                fallbackIconName: "person.crop.rectangle",
                fallbackTint: person.gridColor ?? .secondary,
                cardSize: cardSize,
                topContentLeadingInset: 68
            ) {
                await thumbnailProvider.loadCoverThumbnail(for: person)
            }

            PersonThumbnailBadge(person: person, peopleService: peopleService)
                .padding(16)
        }
    }

    private var coverTaskId: String {
        "\(person.id)-\(person.thumbnailPath)-\(lockupThumbnailMode)"
    }

    private var trailingStatusIconNames: [String] {
        var icons: [String] = []

        if person.isFavorite == true {
            icons.append("heart.fill")
        }

        if person.isHidden {
            icons.append("eye.slash.fill")
        }

        return icons
    }
}

private struct PersonThumbnailBadge: View {
    let person: Person
    let peopleService: PeopleService

    @State private var thumbnail: UIImage?
    private let thumbnailCache = ThumbnailCache.shared

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.16))
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color.white.opacity(0.72), lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.7), radius: 4, x: 0, y: 2)
        .task(id: person.id) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        do {
            let loadedThumbnail = try await thumbnailCache.getThumbnail(for: "person-\(person.id)-\(person.thumbnailPath)", size: "face") {
                try await peopleService.loadPersonThumbnail(personId: person.id)
            }
            await MainActor.run {
                thumbnail = loadedThumbnail
            }
        } catch {
            print("Failed to load person thumbnail for \(person.id): \(error)")
        }
    }
}

private enum PeopleMetadataFormatter {
    static func displayName(for person: Person) -> String {
        person.name
    }

    static func accessibilityName(for person: Person) -> String {
        person.name.isEmpty ? "Unnamed person" : person.name
    }

}


struct PersonPhotosView: View {
    let person: Person
    @ObservedObject var peopleService: PeopleService
    @ObservedObject var authService: AuthenticationService
    @ObservedObject var assetService: AssetService
    @Environment(\.dismiss) private var dismiss
    @State private var personAssets: [ImmichAsset] = []
    @State private var slideshowTrigger: Bool = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                AssetGridView(
                    assetService: assetService,
                    authService: authService,
                                        assetProvider: AssetProviderFactory.createProvider(
                        personId: person.id,
                        assetService: assetService
                    ),
                     albumId: nil,
                     personId: person.id,
                    tagId: nil,
                    city: nil,
                    isAllPhotos: false,
                    isFavorite: false,
                    onAssetsLoaded: { loadedAssets in
                        self.personAssets = loadedAssets
                    },
                    deepLinkAssetId: nil
                )
            }
            .navigationTitle(person.name.isEmpty ? "Unknown Person" : person.name)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: startSlideshow) {
                        Image(systemName: "play.rectangle")
                            .foregroundColor(.white)
                    }
                    .disabled(personAssets.isEmpty)
                }

                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
        }
        .fullScreenCover(isPresented: $slideshowTrigger) {
            SlideshowView(albumId: nil, personId: person.id, tagId: nil, city: nil, startingIndex: 0, isFavorite: false)
        }
    }

    private func startSlideshow() {
        // Stop auto-slideshow timer before starting slideshow
        NotificationCenter.default.post(name: NSNotification.Name("stopAutoSlideshowTimer"), object: nil)
        slideshowTrigger = true
    }
}

#Preview {
    let (_, _, authService, assetService, _, peopleService, _, _) =
         MockServiceFactory.createMockServices()
    PeopleGridView(peopleService: peopleService, authService: authService, assetService: assetService)
}
