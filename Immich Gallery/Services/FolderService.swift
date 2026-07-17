//
//  FolderService.swift
//  Immich Gallery
//
//  Created by Codex on 2025-09-12.
//

import Foundation

class FolderService: ObservableObject {
    private let networkService: NetworkService
    private let stateLock = NSLock()
    private var cachedFolders: [ImmichFolder] = []
    private var inFlightFetchTask: Task<[ImmichFolder], Error>?
    private var inFlightToken: UUID?
    
    init(networkService: NetworkService) {
        self.networkService = networkService
    }

    func invalidateCache() {
        stateLock.lock()
        cachedFolders = []
        let taskToCancel = inFlightFetchTask
        inFlightFetchTask = nil
        inFlightToken = nil
        stateLock.unlock()

        taskToCancel?.cancel()
    }
    
    func fetchUniquePaths(forceRefresh: Bool = false) async throws -> [ImmichFolder] {
        stateLock.lock()
        if !forceRefresh && !cachedFolders.isEmpty {
            let cached = cachedFolders
            stateLock.unlock()
            return cached
        }

        if let inFlightFetchTask {
            stateLock.unlock()
            return try await inFlightFetchTask.value
        }

        let requestToken = UUID()

        let task = Task<[ImmichFolder], Error> {
            let paths: [String] = try await networkService.makeRequest(
                endpoint: "/api/view/folder/unique-paths",
                method: .GET,
                responseType: [String].self
            )
            return paths.map { ImmichFolder(path: $0) }
        }

        inFlightFetchTask = task
        inFlightToken = requestToken
        stateLock.unlock()

        do {
            let folders = try await task.value

            stateLock.lock()
            if inFlightToken == requestToken {
                cachedFolders = folders
                inFlightFetchTask = nil
                inFlightToken = nil
            }
            stateLock.unlock()

            return folders
        } catch {
            stateLock.lock()
            if inFlightToken == requestToken {
                inFlightFetchTask = nil
                inFlightToken = nil
            }
            stateLock.unlock()

            throw error
        }
    }
}
