//
//  ContentView.swift
//  Immich Gallery
//
//  Created by mensadi-labs on 2025-06-29.
//
//⁠‌‌​​​​‌​‌​‌​‌​​‌​‌‌​‌‌​‌​‌‌​​‌​‌​‌‌​‌‌‌​​‌‌‌​​‌‌​‌‌​​​​‌​‌‌​​‌​​​‌‌​‌​​‌​‌‌​‌‌​​​‌‌​​​​‌​‌‌​​​‌​​‌‌‌​​‌‌⁠

import SwiftUI

enum TabName: Int, CaseIterable {
    case photos = 0
    case albums = 1
    case people = 2
    case tags = 3
    case folders = 4
    case explore = 5
    case search = 6
    case settings = 7
    
    var title: String {
        switch self {
        case .photos: return "Photos"
        case .albums: return "Albums"
        case .people: return "People"
        case .tags: return "Tags"
        case .folders: return "Folders"
        case .explore: return "Explore"
        case .search: return "Search"
        case .settings: return "Settings"
        }
    }
    
    var iconName: String {
        switch self {
        case .photos: return "photo.on.rectangle"
        case .albums: return "folder"
        case .people: return "person.crop.circle"
        case .tags: return "tag"
        case .folders: return "folder.fill"
        case .explore: return "globe"
        case .search: return "magnifyingglass"
        case .settings: return "gear"
        }
    }
}

extension Notification.Name {
    static let refreshAllTabs = Notification.Name(NotificationNames.refreshAllTabs)
}

struct ContentView: View {
    // Auto slideshow state
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(UserDefaultsKeys.autoSlideshowTimeout) private var autoSlideshowTimeout: Int = 0
    @AppStorage(UserDefaultsKeys.launchIntoSlideshow) private var launchIntoSlideshow: Bool = false
    @State private var inactivityTask: Task<Void, Never>?
    @State private var pendingIdleSlideshowTask: Task<Void, Never>?
    @State private var isInactivityMonitoringPaused = false
    @State private var suppressNextTabActivity = false
    @StateObject private var userManager = UserManager()
    @StateObject private var networkService: NetworkService
    @StateObject private var authService: AuthenticationService
    @StateObject private var assetService: AssetService
    @StateObject private var albumService: AlbumService
    @StateObject private var peopleService: PeopleService
    @StateObject private var tagService: TagService
    @StateObject private var folderService: FolderService
    @StateObject private var exploreService: ExploreService
    @StateObject private var searchService: SearchService
    @State private var selectedTab = 0
    @State private var refreshTrigger = UUID()
    @State private var showWhatsNew = false
    @AppStorage(UserDefaultsKeys.showTagsTab) private var showTagsTab = false
    @AppStorage(UserDefaultsKeys.showFoldersTab) private var showFoldersTab = false
    @AppStorage(UserDefaultsKeys.defaultStartupTab) private var defaultStartupTab = "photos"
    @AppStorage(UserDefaultsKeys.lastSeenVersion) private var lastSeenVersion = ""
    @AppStorage(UserDefaultsKeys.navigationStyle) private var navigationStyle = NavigationStyle.tabs.rawValue
    @AppStorage(UserDefaultsKeys.photosViewMode) private var photosViewMode = "grid"
    @State private var searchTabHighlighted = false
    @State private var deepLinkAssetId: String?
    
    init() {
        let userManager = UserManager()
        let networkService = NetworkService(userManager: userManager)
        _userManager = StateObject(wrappedValue: userManager)
        _networkService = StateObject(wrappedValue: networkService)
        _authService = StateObject(wrappedValue: AuthenticationService(networkService: networkService, userManager: userManager))
        _assetService = StateObject(wrappedValue: AssetService(networkService: networkService))
        _albumService = StateObject(wrappedValue: AlbumService(networkService: networkService))
        _peopleService = StateObject(wrappedValue: PeopleService(networkService: networkService))
        _tagService = StateObject(wrappedValue: TagService(networkService: networkService))
        _folderService = StateObject(wrappedValue: FolderService(networkService: networkService))
        _exploreService = StateObject(wrappedValue: ExploreService(networkService: networkService))
        _searchService = StateObject(wrappedValue: SearchService(networkService: networkService))
    }
    
    private var currentNavigationStyle: NavigationStyle {
        NavigationStyle(rawValue: navigationStyle) ?? .tabs
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                if !authService.isAuthenticated {
                    // Show sign-in view
                    SignInView(authService: authService, userManager: userManager, mode: .signIn)
                        .errorBoundary(context: "Authentication")
                } else {
                    // Main app interface
                    TabView(selection: $selectedTab) {
                        Group {
                            if photosViewMode == "timeline" {
                                TimelineView(
                                    assetService: assetService,
                                    authService: authService
                                )
                            } else {
                                AssetGridView(
                                    assetService: assetService,
                                    authService: authService,
                                    assetProvider: AssetProviderFactory.createProvider(
                                        isAllPhotos: true,
                                        assetService: assetService
                                    ),
                                    albumId: nil, personId: nil, tagId: nil, city: nil, isAllPhotos: true, isFavorite: false,
                                    onAssetsLoaded: nil,
                                    deepLinkAssetId: deepLinkAssetId
                                )
                            }
                        }
                        .errorBoundary(context: "Photos Tab")
                        .tabItem {
                            Image(systemName: TabName.photos.iconName)
                            Text(TabName.photos.title)
                        }
                        .tag(TabName.photos.rawValue)
                        
                        AlbumListView(albumService: albumService, authService: authService, assetService: assetService, userManager: userManager)
                            .errorBoundary(context: "Albums Tab")
                            .tabItem {
                                Image(systemName: TabName.albums.iconName)
                                Text(TabName.albums.title)
                            }
                            .tag(TabName.albums.rawValue)
                        
                        PeopleGridView(peopleService: peopleService, authService: authService, assetService: assetService)
                            .errorBoundary(context: "People Tab")
                            .tabItem {
                                Image(systemName: TabName.people.iconName)
                                Text(TabName.people.title)
                            }
                            .tag(TabName.people.rawValue)
                        
                        if showTagsTab {
                            TagsGridView(tagService: tagService, authService: authService, assetService: assetService)
                                .errorBoundary(context: "Tags Tab")
                                .tabItem {
                                    Image(systemName: TabName.tags.iconName)
                                    Text(TabName.tags.title)
                                }
                                .tag(TabName.tags.rawValue)
                        }

                        if showFoldersTab {
                            FoldersView(folderService: folderService, assetService: assetService, authService: authService)
                                .errorBoundary(context: "Folders Tab")
                                .tabItem {
                                    Image(systemName: TabName.folders.iconName)
                                    Text(TabName.folders.title)
                                }
                                .tag(TabName.folders.rawValue)
                        }
                        
                        ExploreView(exploreService: exploreService, assetService: assetService, authService: authService, userManager: userManager)
                            .errorBoundary(context: "Explore Tab")
                            .tabItem {
                                Image(systemName: TabName.explore.iconName)
                                Text(TabName.explore.title)
                            }
                            .tag(TabName.explore.rawValue)
                        
                        SearchView(searchService: searchService, assetService: assetService, authService: authService)
                            .errorBoundary(context: "Search Tab")
                            .tabItem {
                                Image(systemName: TabName.search.iconName)
                                Text(TabName.search.title)
                            }
                            .tag(TabName.search.rawValue)
                        
                        SettingsView(authService: authService, userManager: userManager)
                            .errorBoundary(context: "Settings Tab")
                            .tabItem {
                                Image(systemName: TabName.settings.iconName)
                                Text(TabName.settings.title)
                            }
                            .tag(TabName.settings.rawValue)
                    }
                    .tabNavigationStyle(currentNavigationStyle)
                    .onAppear {
                        setDefaultTab()
                        checkForAppUpdate()
                        recordUserActivity()
                        startLaunchSlideshowIfNeeded()
                    }
                    .onChange(of: selectedTab) { oldValue, newValue in
                        searchTabHighlighted = false
                        if suppressNextTabActivity {
                            suppressNextTabActivity = false
                        } else {
                            recordUserActivity()
                        }
                    }
                    .onChange(of: autoSlideshowTimeout) { _, _ in
                        recordUserActivity()
                    }
                    .onChange(of: showFoldersTab) { _, enabled in
                        if !enabled && selectedTab == TabName.folders.rawValue {
                            selectedTab = TabName.photos.rawValue
                        } else if enabled && defaultStartupTab == "folders" {
                            selectedTab = TabName.folders.rawValue
                        }
                    }
                    .id(refreshTrigger) // Force refresh when user switches
                    // .accentColor(.blue)
                }
            }
            .navigationTitle("Immich Gallery")
            .navigationBarHidden(true)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onReceive(NotificationCenter.default.publisher(for: .refreshAllTabs)) { _ in
            // Refresh all tabs by generating a new UUID
            refreshTrigger = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name(NotificationNames.openAsset))) { notification in
            if let assetId = notification.userInfo?["assetId"] as? String {
                print("ContentView: Received OpenAsset notification for asset: \(assetId)")
                
                // Switch to Photos tab and set deep link asset ID
                selectedTab = TabName.photos.rawValue
                deepLinkAssetId = assetId
                
                // Clear the deep link after a moment to avoid stale state
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    deepLinkAssetId = nil
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded { recordUserActivity() }
        )
        .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.didUpdateNotification)) { notification in
            guard
                let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext,
                !context.focusHeading.isEmpty
            else { return }

            recordUserActivity()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.movementDidFailNotification)) { _ in
            recordUserActivity()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("stopAutoSlideshowTimer"))) { _ in
            print("ContentView: Stopping auto-slideshow timer")
            isInactivityMonitoringPaused = true
            cancelIdleSlideshowTasks()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("restartAutoSlideshowTimer"))) { _ in
            print("ContentView: Restarting auto-slideshow timer")
            isInactivityMonitoringPaused = false
            recordUserActivity()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                recordUserActivity()
            case .inactive, .background:
                cancelIdleSlideshowTasks()
            @unknown default:
                cancelIdleSlideshowTasks()
            }
        }
        .onDisappear {
            cancelIdleSlideshowTasks()
        }
        .fullScreenCover(isPresented: $showWhatsNew) {
            WhatsNewView(onDismiss: {
                showWhatsNew = false
                lastSeenVersion = getCurrentAppVersion()
            })
        }
    }
    
    // MARK: - Inactivity Timer Logic
    private func recordUserActivity() {
        guard !isInactivityMonitoringPaused else { return }

        pendingIdleSlideshowTask?.cancel()
        pendingIdleSlideshowTask = nil
        scheduleInactivityCountdown()
    }

    private func scheduleInactivityCountdown() {
        inactivityTask?.cancel()
        inactivityTask = nil

        guard
            autoSlideshowTimeout > 0,
            authService.isAuthenticated,
            scenePhase == .active,
            !isInactivityMonitoringPaused
        else { return }

        let timeout = autoSlideshowTimeout
        print("ContentView: Scheduling auto-slideshow after \(timeout) minutes of inactivity")
        inactivityTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(timeout * 60))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            inactivityTask = nil
            handleInactivityTimeout()
        }
    }

    private func handleInactivityTimeout() {
        print("ContentView: Auto-slideshow inactivity timeout reached")

        if selectedTab != TabName.photos.rawValue {
            suppressNextTabActivity = true
            selectedTab = TabName.photos.rawValue
        }

        pendingIdleSlideshowTask?.cancel()
        pendingIdleSlideshowTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }

            guard
                !Task.isCancelled,
                scenePhase == .active,
                authService.isAuthenticated,
                !isInactivityMonitoringPaused
            else { return }

            pendingIdleSlideshowTask = nil
            NotificationCenter.default.post(name: NSNotification.Name(NotificationNames.startAutoSlideshow), object: nil)
        }
    }

    private func cancelIdleSlideshowTasks() {
        inactivityTask?.cancel()
        inactivityTask = nil
        pendingIdleSlideshowTask?.cancel()
        pendingIdleSlideshowTask = nil
    }
    
    /// Kick off the auto-slideshow right after launch when the user has opted in.
    /// Reuses the same `startAutoSlideshow` path as the inactivity timer, so the
    /// All Photos grid resolves the config playlist (or all photos) and presents it.
    private func startLaunchSlideshowIfNeeded() {
        guard launchIntoSlideshow else { return }
        print("ContentView: Launch-into-slideshow enabled, starting slideshow")
        // Make sure the All Photos grid is the active tab so it handles the notification.
        selectedTab = TabName.photos.rawValue
        // Give the tab switch and initial asset load time to settle before presenting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            NotificationCenter.default.post(name: NSNotification.Name(NotificationNames.startAutoSlideshow), object: nil)
        }
    }

    private func setDefaultTab() {
        switch defaultStartupTab {
        case "photos":
            selectedTab = TabName.photos.rawValue
        case "albums":
            selectedTab = TabName.albums.rawValue
        case "people":
            selectedTab = TabName.people.rawValue
        case "tags":
            if showTagsTab {
                selectedTab = TabName.tags.rawValue
            } else {
                selectedTab = TabName.photos.rawValue // Default to photos if tags tab is disabled
            }
        case "folders":
            if showFoldersTab {
                selectedTab = TabName.folders.rawValue
            } else {
                selectedTab = TabName.photos.rawValue
            }
        case "explore":
            selectedTab = TabName.explore.rawValue
        case "search":
            selectedTab = TabName.search.rawValue
        case "settings":
            selectedTab = TabName.settings.rawValue
        default:
            selectedTab = TabName.photos.rawValue
        }
    }
    
    private func checkForAppUpdate() {
        let currentVersion = getCurrentAppVersion()
        
        // Show What's New if this is first launch or version changed
        if lastSeenVersion.isEmpty || lastSeenVersion != currentVersion {
            // Delay showing to ensure app is fully loaded
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                showWhatsNew = true
            }
        }
    }
    
    private func getCurrentAppVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version).\(build)"
    }
}

private struct TabNavigationStyleModifier: ViewModifier {
    let style: NavigationStyle
    
    func body(content: Content) -> some View {
        switch style {
        case .sidebar:
            content.tabViewStyle(.sidebarAdaptable)
        case .tabs:
            content
        }
    }
}

private extension View {
    func tabNavigationStyle(_ style: NavigationStyle) -> some View {
        modifier(TabNavigationStyleModifier(style: style))
    }
}

#Preview {
    ContentView()
}
