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
    var onNearbyBirthdayCountChange: (Int) -> Void = { _ in }
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

    private var nearbyBirthdays: [Person] {
        people.filter { BirthdayProximity.details(for: $0) != nil }
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
        .onChange(of: nearbyBirthdays.count) { _, count in
            onNearbyBirthdayCountChange(count)
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
    @State private var isScrolling = false

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
                ReloadableEmptyStateView(
                    icon: "person.crop.circle",
                    title: "No People",
                    message: "People recognized by Immich will appear here.",
                    onReload: onRetry
                )
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
                                    cardSize: CGSize(width: cardWidth, height: cardHeight),
                                    shouldLoadImage: !isScrolling
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
                .onScrollPhaseChange { _, newPhase, context in
                    isScrolling = ThumbnailScrollLoadingPolicy.shouldPauseLoading(
                        during: newPhase,
                        velocity: context.velocity
                    )
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

        if let birthday = BirthdayProximity.details(for: person) {
            parts.append(birthday.label)
        }

        return parts.joined(separator: ", ")
    }
}

private struct PersonLockupCard: View {
    let person: Person
    let peopleService: PeopleService
    let thumbnailProvider: PeopleThumbnailProvider
    let cardSize: CGSize
    let shouldLoadImage: Bool
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
                topContentLeadingInset: 68,
                shouldLoadImage: shouldLoadImage
            ) {
                await thumbnailProvider.loadCoverThumbnail(for: person)
            }

            PersonThumbnailBadge(
                person: person,
                peopleService: peopleService,
                shouldLoadImage: shouldLoadImage
            )
                .padding(16)

            if let birthday = BirthdayProximity.details(for: person) {
                BirthdayCardBadge(birthday: birthday)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(16)
            }
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

private struct BirthdayCardBadge: View {
    let birthday: BirthdayProximity.Details

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "party.popper.fill")
                .foregroundStyle(.cyan)
            Text(birthday.shortLabel)
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1)
    }
}

private struct PersonThumbnailBadge: View {
    let person: Person
    let peopleService: PeopleService
    let shouldLoadImage: Bool

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
        .task(id: "\(person.id)-\(shouldLoadImage)") {
            guard shouldLoadImage else { return }
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

enum BirthdayProximity {
    struct Details: Equatable {
        let dayOffset: Int

        var label: String {
            switch dayOffset {
            case 0: return "Birthday today"
            case 1: return "Birthday tomorrow"
            case 2: return "Birthday in 2 days"
            case -1: return "Birthday yesterday"
            default: return "Birthday 2 days ago"
            }
        }

        var shortLabel: String {
            switch dayOffset {
            case 0: return "Today"
            case 1: return "Tomorrow"
            case 2: return "In 2 days"
            case -1: return "Yesterday"
            default: return "2 days ago"
            }
        }
    }

    static func details(
        for person: Person,
        on date: Date = Date(),
        calendar: Calendar = .current
    ) -> Details? {
        guard let birthDate = person.birthDate else { return nil }
        let components = birthDate.prefix(10).split(separator: "-")
        guard components.count == 3,
              let month = Int(components[1]),
              let day = Int(components[2]) else { return nil }

        let today = calendar.startOfDay(for: date)
        let currentYear = calendar.component(.year, from: today)
        let offsets = (-1...1).compactMap { yearOffset -> Int? in
            guard let birthday = calendar.date(from: DateComponents(
                calendar: calendar,
                year: currentYear + yearOffset,
                month: month,
                day: day
            )) else { return nil }
            return calendar.dateComponents([.day], from: today, to: birthday).day
        }

        guard let nearest = offsets.min(by: { abs($0) < abs($1) }), abs(nearest) <= 2 else {
            return nil
        }
        return Details(dayOffset: nearest)
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
        NotificationCenter.default.post(name: NSNotification.Name(NotificationNames.pauseInactivityMonitoring), object: nil)
        slideshowTrigger = true
    }
}

#Preview {
    let (_, _, authService, assetService, _, peopleService, _, _) =
         MockServiceFactory.createMockServices()
    PeopleGridView(peopleService: peopleService, authService: authService, assetService: assetService)
}
