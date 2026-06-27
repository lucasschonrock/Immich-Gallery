//
//  WhatsNewView.swift
//  Immich Gallery
//
//  Created by mensadi-labs on 2025-07-26.
//

import SwiftUI

// MARK: - Data Models

enum ChangelogSectionType: String, Codable {
    case version
    case newFeature = "new_feature"
    case improvement
    case bugFix = "bug_fix"
    case experimental
    case other
}

struct ChangelogSection: Identifiable, Codable {
    let id = UUID()
    let title: String
    let type: ChangelogSectionType
    var items: [String]

    enum CodingKeys: String, CodingKey {
        case title
        case type
        case items
    }
}

/// A version and the change sections that belong to it.
struct ChangelogVersion: Identifiable, Codable {
    let id = UUID()
    let version: String
    var changes: [ChangelogSection]

    enum CodingKeys: String, CodingKey {
        case version
        case changes
    }
}

private enum ChangelogRepository {
    static func load() -> [ChangelogVersion] {
        guard
            let url = Bundle.main.url(forResource: "releases", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let versions = try? JSONDecoder().decode([ChangelogVersion].self, from: data)
        else {
            return []
        }

        return versions
    }
}

// MARK: - View

struct WhatsNewView: View {
    let onDismiss: () -> Void
    @State private var opacity: Double = 0
    @State private var showPreviousVersions = false
    private let versions = ChangelogRepository.load()

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
        let latest = versions.first
        let previous = Array(versions.dropFirst())

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if let latest {
                    versionGroup(latest, isPrimary: true)
                } else {
                    missingChangelogCard
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

    var missingChangelogCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Release notes unavailable")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.white)

            Text("The app could not load its bundled release notes file.")
                .font(.system(size: 20))
                .foregroundColor(.gray)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
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
