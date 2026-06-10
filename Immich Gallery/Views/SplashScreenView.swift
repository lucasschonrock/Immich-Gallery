//
//  WhatsNewView.swift
//  Immich Gallery
//
//  Created by mensadi-labs on 2025-07-26.
//

import SwiftUI

// MARK: - Data Models

enum ChangelogSectionType {
    case version
    case newFeature
    case improvement
    case bugFix
    case experimental
    case other
}

struct ChangelogSection: Identifiable {
    let id = UUID()
    let title: String
    let type: ChangelogSectionType
    var items: [String]
}

/// A version and the change sections that belong to it.
struct ChangelogVersion: Identifiable {
    let id = UUID()
    let version: String
    var changes: [ChangelogSection]
}

// MARK: - View

struct WhatsNewView: View {
    let onDismiss: () -> Void
    @State private var opacity: Double = 0
    @State private var showPreviousVersions = false

    private let changelogContent = """

    VERSION|1.2.4

    NEW_FEATURE| Launch straight into a slideshow
    - New Settings → Interface → "Launch Into Slideshow" option starts the slideshow automatically when the app opens, using your slideshow config album if set (otherwise all photos). Off by default.
    - The slideshow trigger settings now live alongside Default Startup Tab in Interface, grouping the app's startup behavior together.

    VERSION|1.2.3

    BUGFIX| Auto-slideshow stopped using your config
    - After the 1.2.2 fix, auto-slideshow could play whatever album/person you were viewing instead of your configured slideshow. It now reliably plays your slideshow config (or all photos when none is set).

    VERSION|1.2.2

    BUGFIX| Slideshow played the wrong album
    - Pressing play on a specific album now plays that album, instead of always falling back to the auto-slideshow album.

    VERSION|1.2.1

    NEW_FEATURE| Granular Slideshow Overlay Controls
    - New Settings → Slideshow toggles to independently show or hide the current time widget, the photo's taken date, and the location.
    - Photo Date now has three modes: Date and Time, Date Only, or None.
    - Existing behavior preserved by default — turn things off only if you want to.

    VERSION|1.1.9

    NEW_FEATURE| Background & Library Controls
    - Added an app-wide background style picker in Settings → Interface, including a true black Midnight theme.
    - Added a new Settings → Sorting option to hide Filter and Sort buttons in the main library view.
    - When Filter and Sort buttons are hidden, the All Photos grid now reclaims that space to show more images.

    BUGFIX| Folders UI hangs on large libraries
    - Fixed a bug where folders view may hang on large libraries.
    - Made some additional performance improvements to people and tags tab.

    VERSION|1.1.8

    NEW_FEATURE| All Photos Sort & Filter
    - Added sort and filter controls to the main library (All Photos) view.

    VERSION|1.1.7

    NEW_FEATURE| Tabs vs Sidebar
    - Pick your style in Settings → Interface. Tabs for the classics, Sidebar for the minimal.

    BUGFIX| Sort Order & album cover
    - Fixed the sort order again.
    - If thumbnail animation is disabled, we now show album cover of the album.

    VERSION|1.1.6

    NEW_FEATURE| ✨✨New Icon✨✨
    - The Icon has been a placeholder for too long.

    BUGFIX| Fix shared album content. Discussion#81
    - Thank you for reporting @madasus. Issue has been fixed.

    BUGFIX| The overlay windows were broken on TvOS 26. Add user/whats new etc.Part of issue #75
    - Thanks for reporting @rmayergfx. This should fix that issue.

    VERSION|1.1.5

    NEW_FEATURE| Folders Tab
    - New opt-in Folders tab allows you to view folders from your external library.

    BUGFIX| Sorting order
    - We are once again respecting the sorting order selected in settings.

    IMPROVEMENT| Performance Optimizations
    - Hopefully better video player.

    VERSION|1.1.4

    IMPROVEMENT| Performance Optimizations
    - Various performance improvements throughout the app for smoother navigation.
    - Enhanced loading times and reduced memory usage.
    - More improvements coming next for people with large libraries, for now, but if you're experiencing crashes when scrolling, please report.

    NEW_FEATURE| Explore Tab
    - New explore tab to discover your photos through statistics or by cities visited.

    IMPROVEMENT| Top Shelf Enhancement
    - Top shelf now shows only landscape orientation images for better visual presentation on Apple TV.


    VERSION|1.1.3

    NEW_FEATURE| Apple TV Top Shelf Customization
    - Be brave, embrace choas: Now you can choose to display random photos on top shelf.


    IMPROVEMENT| Raw Image Support
    - Raw images now work kinda maybe. TV cannot display RAW images natively so I now load a fullsize version provided by immich.


    IMPROVEMENT| Album & UI Enhancements
    - Albums now show all favorite photos as a new album. Do not worry, the album does not exist in reality, like me.
    - Performance improvements to the all photos tab.
    - Changes to settings page as usual.

    EXPERIMENTAL| Auto Slideshow Configuration (experimental only)
    - This may go away if I can't convince myself this is good.
    - Create empty album named "immich-gallery-config" with specific description format. Check settings for more info on setup.
    - Support for both album and person-based slideshow configuration

     EXPERIMENTAL| Dimmed Slideshow
    - Add support for dimmed slideshow in settings.
    - Time based dim level
    - How good does it work is a matter of personal opinion/s. Try it out and let me know. Yes, I'm talking to you specifically.


    VERSION|1.1.2

    NEW_FEATURE| Sign In With API key
    - All of the SSO users can now use API keys to sign in. Not sure what will break if the API does not have needed scopes. Eventually maybe I'll list them out but for now, take a guess based on the available features.

    IMPROVEMENT| Cleanups
    - Bug fixes and performance improvements.
    - Album view now shows "shared by you" for the albums shared by you.
    - Cleaner settings view.


    VERSION|1.0.14

    IMPROVEMENT| Slideshow optimizations
    - Rewrite SlideshowView for loading assets dynamically

    BUGFIX| Albums tab
    - Fix shared albums are duplicated
    - Fix slideshow does not work for shared-in albums


    VERSION|1.0.12

    BUGFIX| Fix more bugs
    - Make slideshow truly random, just like life. Outsourced this to the server. - #43
    - Fix inactivity timer - Browse fast or the automatic slideshow will catch up to you - #43
    - Remove date of birth from people tab - WAF+10 - #44

    VERSION|1.0.11
    BUGFIX| Fix bugs
    - Top shef portraits no longer do unexpected headstands or cartwheels. I Hope.
    - Hopefully it also won't crash. But you may see reduced image quality in top shelf.
    - Better error handling.
    - Changed color gradient, this is much better on the eyes, I think.
    """

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                HStack(alignment: .top, spacing: 0) {
                    brandPanel
                        .frame(width: geo.size.width * 0.34)

                    changesPanel
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .opacity(opacity)
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { opacity = 1.0 } }
        .onExitCommand { onDismiss() }
    }
}

// MARK: - Brand Panel

private extension WhatsNewView {
    var brandPanel: some View {
        let versions = parseVersions()
        let latest = versions.first?.version

        return VStack(alignment: .leading, spacing: 24) {
            Image("icon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 28))

            VStack(alignment: .leading, spacing: 8) {
                Text("What's New")
                    .font(.system(size: 52, weight: .bold))
                    .foregroundColor(.white)

                Text("Immich Gallery")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(.gray)
            }

            if let latest {
                Text("Version \(latest)")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(Color.white.opacity(0.12))
                    )
            }

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("Be a star - leave a star, or five.")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.gray)

                Text("Press the Back button to close")
                    .font(.system(size: 18))
                    .foregroundColor(.gray.opacity(0.7))
            }
        }
        .padding(.leading, 80)
        .padding(.trailing, 50)
        .padding(.vertical, 80)
    }
}

// MARK: - Changes Panel

private extension WhatsNewView {
    var changesPanel: some View {
        let versions = parseVersions()
        let latest = versions.first
        let previous = Array(versions.dropFirst())

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if let latest {
                    versionGroup(latest, isPrimary: true)
                }

                if !previous.isEmpty {
                    if showPreviousVersions {
                        ForEach(previous) { versionGroup($0, isPrimary: false) }
                    } else {
                        showPreviousButton
                    }
                }
            }
            .padding(.trailing, 80)
            .padding(.top, 80)
            .padding(.bottom, 100)
        }
    }

    func versionGroup(_ version: ChangelogVersion, isPrimary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            versionHeader(version.version, isPrimary: isPrimary)
            ForEach(version.changes) { ChangelogCard(section: $0) }
        }
        .padding(.bottom, 12)
    }

    func versionHeader(_ version: String, isPrimary: Bool) -> some View {
        HStack(spacing: 14) {
            Text("Version \(version)")
                .font(.system(size: isPrimary ? 30 : 24, weight: .bold))
                .foregroundColor(isPrimary ? .white : .gray)
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 1)
        }
    }

    var showPreviousButton: some View {
        Button(action: { withAnimation { showPreviousVersions = true } }) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.down")
                Text("Show previous versions")
            }
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .buttonStyle(CardButtonStyle())
    }
}

// MARK: - Parsing Logic

private extension WhatsNewView {
    /// Parses the changelog into versions, each carrying its change sections.
    func parseVersions() -> [ChangelogVersion] {
        var versions: [ChangelogVersion] = []

        for section in parseChangelog() {
            if section.type == .version {
                versions.append(ChangelogVersion(version: section.title, changes: []))
            } else {
                versions.indices.last.map { versions[$0].changes.append(section) }
            }
        }

        return versions
    }

    func parseChangelog() -> [ChangelogSection] {
        var sections: [ChangelogSection] = []
        var currentSection: ChangelogSection?

        for line in changelogContent.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.contains("|") {
                if let section = currentSection {
                    sections.append(section)
                }
                let (type, title) = parseHeader(trimmed)
                currentSection = ChangelogSection(title: title, type: type, items: [])
            } else if trimmed.hasPrefix("-") {
                currentSection?.items.append(String(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))
            }
        }

        if let section = currentSection {
            sections.append(section)
        }

        return sections
    }

    func parseHeader(_ line: String) -> (ChangelogSectionType, String) {
        let components = line.components(separatedBy: "|")
        guard components.count == 2 else { return (.other, line) }

        let type: ChangelogSectionType
        switch components[0].trimmingCharacters(in: .whitespaces) {
        case "VERSION": type = .version
        case "NEW_FEATURE": type = .newFeature
        case "IMPROVEMENT": type = .improvement
        case "BUGFIX": type = .bugFix
        case "EXPERIMENTAL": type = .experimental
        default: type = .other
        }
        return (type, components[1].trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Card View

struct ChangelogCard: View {
    let section: ChangelogSection
    @Environment(\.isFocused) var isFocused

    private func getTypeInfo() -> (icon: String, color: Color, badge: String) {
        switch section.type {
        case .version: return ("app.badge.fill", .blue, "VERSION")
        case .newFeature: return ("sparkles", .green, "NEW")
        case .improvement: return ("arrow.up.circle.fill", .orange, "IMPROVED")
        case .bugFix: return ("ladybug.slash", .red, "FIXED")
        case .experimental: return ("flask", .purple, "EXPERIMENTAL")
        case .other: return ("info.circle.fill", .gray, "INFO")
        }
    }

    var body: some View {
        let typeInfo = getTypeInfo()

        return Button(action: {}) {
            VStack(alignment: .leading, spacing: 16) {
                header(typeInfo)
                if !section.items.isEmpty { itemsList(typeInfo) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isFocused ? Color.white.opacity(0.1) : Color.black.opacity(0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isFocused ? typeInfo.color : Color.gray.opacity(0.3), lineWidth: isFocused ? 3 : 1)
                    )
            )
        }
        .buttonStyle(CardButtonStyle())
        .focusable()
    }

    private func header(
        _ typeInfo: (icon: String, color: Color, badge: String)
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(typeInfo.badge)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(typeInfo.color)
                    )
                Spacer()
                Image(systemName: typeInfo.icon)
                    .font(.title2)
                    .foregroundColor(typeInfo.color)
            }
            .padding(.bottom, 8)

            Text(section.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
        }
    }

    private func itemsList(_ typeInfo: (icon: String, color: Color, badge: String)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(section.items, id: \.self) { item in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(typeInfo.color)
                        .frame(width: 6, height: 6)
                        .padding(.top, 8)
                    Text(item)
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }
}

#Preview {
    WhatsNewView(onDismiss: {})
}
