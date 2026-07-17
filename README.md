![Platform](https://img.shields.io/badge/platform-TvOS-blue) ![Language](https://img.shields.io/github/languages/top/mensadilabs/Immich-Gallery) [![Unit Tests](https://github.com/mensadilabs/Immich-Gallery/actions/workflows/unit-tests.yml/badge.svg?branch=dev)](https://github.com/mensadilabs/Immich-Gallery/actions/workflows/unit-tests.yml)


[Download from Apple TV App Store](https://apps.apple.com/ca/app/immich-gallery/id6748482378)

<a href="https://www.buymeacoffee.com/zzpr69dnqtr" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-blue.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a> Help cover app store fee.

# Immich Gallery for Apple TV

A native Apple TV app for browsing your self-hosted Immich photo library with a TV-optimized interface.

## Screenshots

<table>
  <tr>
    <td><img src="screenshots/TopShelf.png" alt="Top Shelf"></td>
    <td><img src="screenshots/login.png" alt="Login"></td>
  </tr>
  <tr>
    <td><img src="screenshots/Timeline.png" alt="All Photos"></td>
    <td><img src="screenshots/Filter.png" alt="Filter"></td>
  </tr>
  <tr>
    <td><img src="screenshots/albums.png" alt="Albums"></td>
    <td><img src="screenshots/FoldersTab.png" alt="FoldersTab"></td>
  </tr>
  <tr>
    <td><img src="screenshots/Search.png" alt="Search"></td>
    <td><img src="screenshots/Settings.png" alt="Settings"></td>
  </tr>
  <tr>
    <td><img src="screenshots/Slideshow.png" alt="Slideshow"></td>
    <td><img src="screenshots/Stats.png" alt="Stats"></td>
  </tr>
</table>

## Features

- 🖼️ **Photo Grid View**: Browse your library in a fast, infinite-scrolling grid
- 👥 **People Recognition**: Jump straight to people Immich detects in your photos
- 📁 **Album Support**: Navigate personal and shared Immich albums
- 🏷️ **Tag Support with animated thumbnails**: Optional tag tab with looping previews
- 🗂️ **Folders Tab** : View external libray folders.
- 🔍 **Explore Tab**: Discover stats, locations, and highlights from your library
- 📺 **Top Shelf Customization**: Pick featured or random photos for the Apple TV top shelf
- 🎬 **Slideshow Mode**: Full-screen slideshow with optional clock overlay
- 👤 **Multi-User Support**: Store multiple accounts and switch instantly
- 📊 **EXIF Data**: Inspect camera details and location metadata
- 🔒 **Privacy First**: Pure client, keeps credentials local


## Requirements

- Apple TV (4th generation or later)
- tvOS 15.0+
- Immich server running and accessible
- Network connectivity between Apple TV and Immich server

## Quick Start

1. **Launch the app** - You'll be prompted to sign in to your Immich server
2. **Enter credentials** - Provide the server URL (e.g., `https://your-immich-server.com`) plus either email & password or an Immich API key
3. **Browse your photos** - Navigate using the Apple TV remote or Siri Remote

> [!NOTE]
>
> - Stuck on "Data couldn't read because its missing"? Update Immich and retry: https://github.com/mensadilabs/Immich-Gallery/issues/67
> - OAuth / OIDC sign-in needs server-side changes (tracked in https://github.com/mensadilabs/Immich-Gallery/issues/77). Use an Immich API key instead.
> - FaceID / PIN locking is currently out of scope. https://github.com/mensadilabs/Immich-Gallery/issues/64

### Building from Source

1. Clone the repository
2. Open `Immich Gallery.xcodeproj` in Xcode
3. Select Apple TV target device
4. Build and run

## Stats

![Alt](https://repobeats.axiom.co/api/embed/3fea253de89fc88824c16adb77a456f7e7d657b7.svg "Repobeats analytics image")

[![Star History Chart](https://api.star-history.com/svg?repos=mensadilabs/Immich-Gallery&type=Timeline)](https://www.star-history.com/#mensadilabs/Immich-Gallery&Timeline)
