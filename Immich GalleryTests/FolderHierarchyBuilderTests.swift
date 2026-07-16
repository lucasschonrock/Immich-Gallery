import Testing
@testable import Immich_Gallery

struct FolderHierarchyBuilderTests {
    @Test func collapsesSharedPrefixAndKeepsFirstUsefulBranch() {
        let folders = [
            ImmichFolder(path: "/library/Photos/2024/Trips"),
            ImmichFolder(path: "/library/Photos/2024/Family"),
            ImmichFolder(path: "/library/Photos/2023")
        ]

        let root = FolderHierarchyBuilder.build(from: folders)

        #expect(root?.name == "Photos")
        #expect(root?.path == "/library/Photos")
        #expect(root?.indexedFolderCount == 3)
        #expect(root?.children.map(\.name) == ["2023", "2024"])
        #expect(root?.children.last?.children.map(\.name) == ["Family", "Trips"])
    }

    @Test func preservesFolderThatContainsPhotosAndSubfolders() {
        let folders = [
            ImmichFolder(path: "/photos/2024"),
            ImmichFolder(path: "/photos/2024/Trips")
        ]

        let root = FolderHierarchyBuilder.build(from: folders)

        #expect(root?.path == "/photos/2024")
        #expect(root?.indexedFolder?.path == "/photos/2024")
        #expect(root?.indexedFolderCount == 2)
        #expect(root?.children.first?.name == "Trips")
    }

    @Test func normalizesWindowsSeparatorsForHierarchyQueries() {
        let folders = [
            ImmichFolder(path: "C:\\Photos\\2024\\Family"),
            ImmichFolder(path: "C:\\Photos\\2024\\Trips")
        ]

        let root = FolderHierarchyBuilder.build(from: folders)

        #expect(root?.name == "2024")
        #expect(root?.path == "C:/Photos/2024")
        #expect(root?.children.map(\.name) == ["Family", "Trips"])
        #expect(root?.children.first?.indexedFolder?.path == "C:\\Photos\\2024\\Family")
    }

    @Test func ignoresDuplicateIndexedPaths() {
        let path = "/library/Photos/Trips"

        let root = FolderHierarchyBuilder.build(from: [
            ImmichFolder(path: path),
            ImmichFolder(path: path)
        ])

        #expect(root?.indexedFolderCount == 1)
        #expect(root?.indexedFolder?.path == path)
    }

    @Test func returnsNilForEmptyLibrary() {
        #expect(FolderHierarchyBuilder.build(from: []) == nil)
    }

    @Test func sortsVisibleFoldersByNameInEitherDirection() {
        let root = FolderHierarchyBuilder.build(from: [
            ImmichFolder(path: "/photos/Folder 10"),
            ImmichFolder(path: "/photos/Folder 2"),
            ImmichFolder(path: "/photos/Archive")
        ])
        let children = root?.children ?? []

        #expect(FolderNameSortOrder.ascending.sorted(children).map(\.name) == ["Archive", "Folder 2", "Folder 10"])
        #expect(FolderNameSortOrder.descending.sorted(children).map(\.name) == ["Folder 10", "Folder 2", "Archive"])
    }
}
