//
//  SlideshowSourceResolutionTests.swift
//  Immich GalleryTests
//
//  Covers the bug where launching a slideshow for a specific album played the
//  auto-slideshow config album (immich-gallery-config) instead of the selected one.
//

import Testing
@testable import Immich_Gallery

struct SlideshowSourceResolutionTests {

    /// Bug repro: the user opens a specific album ("Kids" is the auto-slideshow
    /// config album, but here they opened a *different* album) and presses play.
    /// The slideshow must play the album they selected, not the config album.
    @Test func explicitAlbumSelectionIsNotOverriddenByAutoSlideshowConfig() {
        let selection = SlideshowView.SlideshowSelection(
            albumId: "vacation-album-id",   // explicitly opened album
            personId: nil,
            tagId: nil,
            city: nil,
            isFavorite: false
        )
        // Auto-slideshow config points at a DIFFERENT album (the "Kids" album).
        let config = SlideshowConfig(albumIds: ["kids-auto-config-album-id"], personIds: [])

        let source = SlideshowView.resolveSlideshowSource(selection: selection, config: config)

        #expect(source == .selection(selection))
    }

    /// The auto-slideshow / all-photos entry point (no explicit target) should
    /// still use the config when one is configured.
    @Test func noExplicitSelectionUsesAutoSlideshowConfig() {
        let selection = SlideshowView.SlideshowSelection(
            albumId: nil,
            personId: nil,
            tagId: nil,
            city: nil,
            isFavorite: false
        )
        let config = SlideshowConfig(albumIds: ["kids-auto-config-album-id"], personIds: [])

        let source = SlideshowView.resolveSlideshowSource(selection: selection, config: config)

        #expect(source == .config(config))
    }

    /// An explicit selection is honored when no auto-slideshow config is set.
    @Test func explicitSelectionUsedWhenConfigEmpty() {
        let selection = SlideshowView.SlideshowSelection(
            albumId: "vacation-album-id",
            personId: nil,
            tagId: nil,
            city: nil,
            isFavorite: false
        )

        let source = SlideshowView.resolveSlideshowSource(selection: selection, config: .empty)

        #expect(source == .selection(selection))
    }

    /// Favorites is also an explicit target and must not be overridden by config.
    @Test func favoritesSelectionIsNotOverriddenByConfig() {
        let selection = SlideshowView.SlideshowSelection(
            albumId: nil,
            personId: nil,
            tagId: nil,
            city: nil,
            isFavorite: true
        )
        let config = SlideshowConfig(albumIds: ["kids-auto-config-album-id"], personIds: [])

        let source = SlideshowView.resolveSlideshowSource(selection: selection, config: config)

        #expect(source == .selection(selection))
    }

    /// Auto-slideshow is broadcast to every mounted grid; only the All Photos grid
    /// (the single, non-explicit responder) should act on it. Explicit-target grids
    /// must ignore it so they can't hijack or race the auto-slideshow presentation.
    @Test func onlyAllPhotosGridHandlesAutoSlideshow() {
        #expect(AssetGridView.shouldHandleAutoSlideshow(isAllPhotos: true))
        #expect(!AssetGridView.shouldHandleAutoSlideshow(isAllPhotos: false))
    }
}
