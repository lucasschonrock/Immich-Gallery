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
        SharedGridView(
            items: people,
            config: .peopleStyle,
            thumbnailProvider: thumbnailProvider,
            isLoading: isLoading,
            errorMessage: errorMessage,
            onItemSelected: { person in
                print("Person selected: \(person.id)")
                selectedPerson = person
            },
            onItemAppear: loadMorePeopleIfNeeded,
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
