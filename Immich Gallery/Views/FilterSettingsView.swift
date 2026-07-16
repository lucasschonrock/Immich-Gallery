//
//  FilterSettingsView.swift
//  Immich Gallery
//

import SwiftUI

struct PhotoFilterSelection: Equatable {
    var year: Int?
    var country: String?
    var state: String?
    var city: String?
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?

    static var saved: PhotoFilterSelection {
        let defaults = UserDefaults.standard
        return PhotoFilterSelection(
            year: defaults.allPhotosFilterYear,
            country: defaults.allPhotosFilterCountry,
            state: defaults.allPhotosFilterState,
            city: defaults.allPhotosFilterCity,
            cameraMake: defaults.allPhotosFilterCameraMake,
            cameraModel: defaults.allPhotosFilterCameraModel,
            lensModel: defaults.allPhotosFilterLensModel
        )
    }

    var activeCount: Int {
        [country, state, city, cameraMake, cameraModel, lensModel].compactMap { $0 }.count
            + (year == nil ? 0 : 1)
    }

    mutating func reset() {
        self = PhotoFilterSelection()
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.allPhotosFilterYear = year
        defaults.allPhotosFilterCountry = country
        defaults.allPhotosFilterState = state
        defaults.allPhotosFilterCity = city
        defaults.allPhotosFilterCameraMake = cameraMake
        defaults.allPhotosFilterCameraModel = cameraModel
        defaults.allPhotosFilterLensModel = lensModel
    }
}

struct FilterSettingsView: View {
    private enum FilterCategory: String, CaseIterable, Hashable {
        case year
        case country
        case state
        case city
        case cameraMake
        case cameraModel
        case lensModel

        var title: String {
            switch self {
            case .year: "Year"
            case .country: "Country"
            case .state: "State / Province"
            case .city: "City"
            case .cameraMake: "Camera Make"
            case .cameraModel: "Camera Model"
            case .lensModel: "Lens Model"
            }
        }
    }

    let assetService: AssetService
    @Binding var selection: PhotoFilterSelection
    var onApply: () -> Void

    @State private var localSelection: PhotoFilterSelection
    @State private var selectedCategory: FilterCategory = .year
    @State private var availableValues: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var focusedCategory: FilterCategory?

    init(
        assetService: AssetService,
        selection: Binding<PhotoFilterSelection>,
        onApply: @escaping () -> Void
    ) {
        self.assetService = assetService
        self._selection = selection
        self.onApply = onApply
        _localSelection = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        ZStack {
            /*
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            */

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 70)
                    .padding(.top, 42)
                    .padding(.bottom, 28)

                HStack(alignment: .top, spacing: 38) {
                    categorySidebar
                        .frame(width: 590)

                    Divider()
                        .overlay(.white.opacity(0.15))

                    valuesPanel
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 610, alignment: .top)
                .padding(.horizontal, 70)
                .padding(.bottom, 45)
            }
        }
        .frame(width: 1760, height: 700)
        .presentationSizing(.fitted)
        .task(id: suggestionLoadKey) {
            await loadValues()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 30) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Filter Photos")
                    .font(.system(size: 54, weight: .bold))
                    .foregroundColor(.white)

                Text(localSelection.activeCount == 0
                     ? "Choose a category, then select a value"
                     : "\(localSelection.activeCount) filter\(localSelection.activeCount == 1 ? "" : "s") selected")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Reset All") {
                localSelection.reset()
            }
            .buttonStyle(.bordered)
            .disabled(localSelection.activeCount == 0)

            Button {
                selection = localSelection
                onApply()
            } label: {
                Text("Apply Filters")
                    .padding(.horizontal, 24)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FILTER BY")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.leading, 18)
                .padding(.bottom, 2)

            ForEach(FilterCategory.allCases, id: \.self) { category in
                Button {
                    selectedCategory = category
                    focusedCategory = category
                } label: {
                    HStack(spacing: 16) {
                        Text(category.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .layoutPriority(1)

                        Spacer(minLength: 12)

                        Text(summary(for: category))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Image(systemName: "chevron.right")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.secondary)
                            .opacity(selectedCategory == category ? 1 : 0)
                    }
                    .padding(.horizontal, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 74)
                }
                .buttonStyle(.card)
                .focused($focusedCategory, equals: category)
            }
        }
        .focusSection()
    }

    private var valuesPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(selectedCategory.title)
                    .font(.title2.bold())
                    .foregroundColor(.white)

                if let contextDescription {
                    Text(contextDescription)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.leading, 12)

            ZStack {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        valueButton(label: "All", value: nil)

                        ForEach(availableValues, id: \.self) { value in
                            valueButton(label: displayName(for: value), value: value)
                        }

                        if availableValues.isEmpty {
                            Text("No suggestions found")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .padding(.top, 40)
                        }
                    }
                    .padding(.horizontal, 44)
                    .padding(.vertical, 16)
                }
                .scrollClipDisabled()
                .focusSection()
                .opacity(isLoading || errorMessage != nil ? 0 : 1)
                .allowsHitTesting(!isLoading && errorMessage == nil)

                if isLoading {
                    ProgressView("Loading suggestions…")
                        .scaleEffect(1.25)
                }

                if let errorMessage {
                    VStack(spacing: 16) {
                        Text("Couldn’t load suggestions")
                            .font(.headline)
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            Task { await loadValues() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func valueButton(label: String, value: String?) -> some View {
        let isSelected = selectedValue == value
        return Button {
            select(value)
        } label: {
            HStack {
                Text(label)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "checkmark")
                    .font(.headline.weight(.bold))
                    .foregroundColor(.accentColor)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .frame(height: 76)
        }
        .buttonStyle(.card)
    }

    private var selectedValue: String? {
        switch selectedCategory {
        case .year: localSelection.year.map(String.init)
        case .country: localSelection.country
        case .state: localSelection.state
        case .city: localSelection.city
        case .cameraMake: localSelection.cameraMake
        case .cameraModel: localSelection.cameraModel
        case .lensModel: localSelection.lensModel
        }
    }

    private func select(_ value: String?) {
        switch selectedCategory {
        case .year:
            localSelection.year = value.flatMap(Int.init)
        case .country:
            guard localSelection.country != value else { return }
            localSelection.country = value
            localSelection.state = nil
            localSelection.city = nil
        case .state:
            guard localSelection.state != value else { return }
            localSelection.state = value
            localSelection.city = nil
        case .city:
            localSelection.city = value
        case .cameraMake:
            guard localSelection.cameraMake != value else { return }
            localSelection.cameraMake = value
            localSelection.cameraModel = nil
            localSelection.lensModel = nil
        case .cameraModel:
            guard localSelection.cameraModel != value else { return }
            localSelection.cameraModel = value
            localSelection.lensModel = nil
        case .lensModel:
            localSelection.lensModel = value
        }
    }

    private func summary(for category: FilterCategory) -> String {
        switch category {
        case .year: localSelection.year.map(String.init) ?? "All years"
        case .country: localSelection.country.map { displayName(for: $0) } ?? "All countries"
        case .state: localSelection.state.map { displayName(for: $0) } ?? "All states"
        case .city: localSelection.city.map { displayName(for: $0) } ?? "All cities"
        case .cameraMake: localSelection.cameraMake.map { displayName(for: $0) } ?? "All makes"
        case .cameraModel: localSelection.cameraModel.map { displayName(for: $0) } ?? "All models"
        case .lensModel: localSelection.lensModel.map { displayName(for: $0) } ?? "All lenses"
        }
    }

    private var contextDescription: String? {
        switch selectedCategory {
        case .state:
            contextValue(localSelection.country).map { "Showing suggestions in \($0)" }
        case .city:
            [localSelection.state, localSelection.country].compactMap(contextValue).isEmpty
                ? nil
                : "Showing suggestions in \([localSelection.state, localSelection.country].compactMap(contextValue).joined(separator: ", "))"
        case .cameraModel:
            contextValue(localSelection.cameraMake).map { "Showing \($0) models" }
        case .lensModel:
            [localSelection.cameraMake, localSelection.cameraModel].compactMap(contextValue).isEmpty
                ? nil
                : "Matching \([localSelection.cameraMake, localSelection.cameraModel].compactMap(contextValue).joined(separator: " "))"
        default:
            nil
        }
    }

    private var suggestionLoadKey: String {
        let dependencies: [String?]
        switch selectedCategory {
        case .state:
            dependencies = [localSelection.country]
        case .city:
            dependencies = [localSelection.country, localSelection.state]
        case .cameraModel:
            dependencies = [localSelection.cameraMake]
        case .lensModel:
            dependencies = [localSelection.cameraMake, localSelection.cameraModel]
        default:
            dependencies = []
        }
        return ([selectedCategory.rawValue] + dependencies.compactMap { $0 }).joined(separator: "|")
    }

    private func displayName(for value: String) -> String {
        value == SearchSuggestionType.nullValue ? "Unknown" : value
    }

    private func contextValue(_ value: String?) -> String? {
        guard let value, value != SearchSuggestionType.nullValue else { return nil }
        return value
    }

    @MainActor
    private func loadValues() async {
        let categoryBeingLoaded = selectedCategory
        isLoading = true
        errorMessage = nil
        do {
            let values: [String]
            switch selectedCategory {
            case .year:
                values = try await assetService.fetchAllYears().map(String.init)
            case .country:
                values = try await assetService.fetchSearchSuggestions(type: .country)
            case .state:
                values = try await assetService.fetchSearchSuggestions(
                    type: .state,
                    country: localSelection.country
                )
            case .city:
                values = try await assetService.fetchSearchSuggestions(
                    type: .city,
                    country: localSelection.country,
                    state: localSelection.state
                )
            case .cameraMake:
                values = try await assetService.fetchSearchSuggestions(type: .cameraMake)
            case .cameraModel:
                values = try await assetService.fetchSearchSuggestions(
                    type: .cameraModel,
                    cameraMake: localSelection.cameraMake
                )
            case .lensModel:
                values = try await assetService.fetchSearchSuggestions(
                    type: .cameraLensModel,
                    cameraMake: localSelection.cameraMake,
                    cameraModel: localSelection.cameraModel
                )
            }
            guard !Task.isCancelled else { return }
            availableValues = values
            isLoading = false
            restoreSidebarFocusIfNeeded(to: categoryBeingLoaded)
        } catch is CancellationError {
            // A new category or parent selection superseded this request.
        } catch {
            guard !Task.isCancelled else { return }
            availableValues = []
            errorMessage = error.localizedDescription
            isLoading = false
            restoreSidebarFocusIfNeeded(to: categoryBeingLoaded)
        }
    }

    @MainActor
    private func restoreSidebarFocusIfNeeded(to category: FilterCategory) {
        guard selectedCategory == category, focusedCategory != nil else { return }
        Task { @MainActor in
            await Task.yield()
            focusedCategory = category
        }
    }
}
