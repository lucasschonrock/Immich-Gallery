//
//  LandscapeOverlayLockupCard.swift
//  Immich Gallery
//

import SwiftUI

enum ThumbnailScrollLoadingPolicy {
    /// Below this speed, thumbnail work is allowed to resume while the user
    /// continues scrolling. Roughly two 300-point cards per second.
    private static let fastScrollVelocityThreshold: CGFloat = 600

    static func shouldPauseLoading(
        during phase: ScrollPhase,
        velocity: CGVector?
    ) -> Bool {
        guard phase.isScrolling else { return false }
        guard let velocity else { return true }

        let speed = max(abs(velocity.dx), abs(velocity.dy))
        return speed >= fastScrollVelocityThreshold
    }
}

private struct AsyncLandscapeImageTaskID<ID: Hashable>: Hashable {
    let imageId: ID
    let shouldLoad: Bool
}

struct AsyncLandscapeOverlayLockupCard<ID: Hashable>: View {
    let taskId: ID
    let title: String
    let subtitle: String?
    let leadingIconName: String?
    let primaryMetadata: String?
    let secondaryMetadata: String?
    let trailingStatusIconNames: [String]
    let fallbackIconName: String
    let fallbackTint: Color
    let cardSize: CGSize
    var topContentLeadingInset: CGFloat = 0
    var shouldLoadImage = true
    let loadImage: () async -> UIImage?

    @State private var image: UIImage?
    @State private var isLoadingImage = false

    var body: some View {
        LandscapeOverlayLockupCard(
            title: title,
            subtitle: subtitle,
            leadingIconName: leadingIconName,
            primaryMetadata: primaryMetadata,
            secondaryMetadata: secondaryMetadata,
            trailingStatusIconNames: trailingStatusIconNames,
            image: image,
            isLoadingImage: isLoadingImage,
            fallbackIconName: fallbackIconName,
            fallbackTint: fallbackTint,
            cardSize: cardSize,
            topContentLeadingInset: topContentLeadingInset
        )
        .task(id: AsyncLandscapeImageTaskID(imageId: taskId, shouldLoad: shouldLoadImage)) {
            guard shouldLoadImage else { return }
            await loadCover()
        }
    }

    private func loadCover() async {
        guard !isLoadingImage else { return }

        await MainActor.run {
            isLoadingImage = true
        }

        let loadedImage = await loadImage()

        await MainActor.run {
            image = loadedImage
            isLoadingImage = false
        }
    }
}

struct LandscapeOverlayLockupCard: View {
    let title: String
    let subtitle: String?
    let leadingIconName: String?
    let primaryMetadata: String?
    let secondaryMetadata: String?
    let trailingStatusIconNames: [String]
    let image: UIImage?
    let isLoadingImage: Bool
    let fallbackIconName: String
    let fallbackTint: Color
    let cardSize: CGSize
    var topContentLeadingInset: CGFloat = 0

    var body: some View {
        ZStack {
            cover

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let leadingIconName {
                            Image(systemName: leadingIconName)
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                        }

                        Text(title)
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)

                        Spacer(minLength: 8)
                    }

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, topContentLeadingInset)
                .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1)

                Spacer(minLength: 0)

                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let primaryMetadata {
                            Text(primaryMetadata)
                        }

                        if let secondaryMetadata {
                            Text(secondaryMetadata)
                        }
                    }
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)

                    Spacer(minLength: 8)

                    HStack(spacing: 8) {
                        ForEach(trailingStatusIconNames, id: \.self) { iconName in
                            Image(systemName: iconName)
                        }
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.75), radius: 2, x: 0, y: 1)
                }
            }
            .padding(18)
            .frame(width: cardSize.width, height: cardSize.height, alignment: .leading)
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
    }

    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.08))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cardSize.width, height: cardSize.height)
                    .clipped()
            } else if isLoadingImage {
                ProgressView()
                    .scaleEffect(1.05)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: fallbackIconName)
                        .font(.system(size: 38, weight: .bold))
                    Text(title)
                        .font(.caption.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundStyle(fallbackTint)
                .padding(.horizontal, 18)
            }

            VStack(spacing: 0) {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.78), location: 0),
                        .init(color: .black.opacity(0.46), location: 0.48),
                        .init(color: .black.opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(maxHeight: .infinity)

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: 0),
                        .init(color: .black.opacity(0.45), location: 0.45),
                        .init(color: .black.opacity(0.82), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(maxHeight: .infinity)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
