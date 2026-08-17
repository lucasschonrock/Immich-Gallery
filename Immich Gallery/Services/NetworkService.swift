//
//  NetworkService.swift
//  Immich Gallery
//
//  Created by mensadi-labs on 2025-06-29.
//

import Foundation

/// Base networking service that handles HTTP requests and authentication
class NetworkService: ObservableObject {
    // MARK: - Configuration
    @Published var baseURL: String = ""
    @Published var accessToken: String?
    @Published var currentAuthType: SavedUser.AuthType = .jwt
    
    /// `URLSession.shared` only enforces a 60s *idle* timeout that resets on every
    /// byte received, so a trickling server can keep a request alive indefinitely.
    /// Bound both the idle gap and the total transfer time instead.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()
    private weak var userManager: UserManager?
    
    init(userManager: UserManager) {
        self.userManager = userManager
        loadCurrentUserCredentials()
    }
    
    // MARK: - Current User Credential Loading
    private func loadCurrentUserCredentials() {
        guard let userManager = userManager else {
            print("NetworkService: No UserManager available")
            return
        }
        
        if let serverURL = userManager.currentUserServerURL,
           let token = userManager.currentUserToken,
           let authType = userManager.currentUserAuthType {
            
            DispatchQueue.main.async {
                self.baseURL = serverURL
                self.accessToken = token
                self.currentAuthType = authType
            }
            
            print("NetworkService: Loaded current user credentials - baseURL: \(serverURL), authType: \(authType)")
        } else {
            print("NetworkService: No current user credentials found")
            DispatchQueue.main.async {
                self.baseURL = ""
                self.accessToken = nil
                self.currentAuthType = .jwt
            }
        }
    }
    
    /// Updates the network service with the current user's credentials
    func updateCredentialsFromCurrentUser() {
        loadCurrentUserCredentials()
    }
    
    /// Clears all credentials when user logs out
    func clearCredentials() {
        DispatchQueue.main.async {
            self.baseURL = ""
            self.accessToken = nil
            self.currentAuthType = .jwt
        }
        print("NetworkService: Cleared all credentials")
    }
    
    // MARK: - Network Requests
    
    /// Builds an authenticated URLRequest with proper headers based on current auth type
    private func buildAuthenticatedRequest(endpoint: String, method: HTTPMethod = .GET, body: [String: Any]? = nil) throws -> URLRequest {
        guard let accessToken = accessToken, !baseURL.isEmpty else {
            print("NetworkService: No access token or server URL available")
            throw ImmichError.notAuthenticated
        }
        
        let urlString = "\(baseURL)\(endpoint)"
        guard let url = URL(string: urlString) else {
            print("NetworkService: Invalid URL: \(urlString)")
            throw ImmichError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        
        // Set authentication header based on auth type
        if currentAuthType == .apiKey {
            request.setValue(accessToken, forHTTPHeaderField: "x-api-key")
        } else {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        
        // Set body if provided
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        
        return request
    }
    
    /// Processes the HTTP response and handles status codes consistently
    private func processResponse(_ response: URLResponse, data: Data, context: String = "") throws -> Data {
        guard let httpResponse = response as? HTTPURLResponse else {
            print("NetworkService: Invalid HTTP response\(context.isEmpty ? "" : " in \(context)")")
            throw ImmichError.networkError
        }
        
        print("NetworkService: Response status code: \(httpResponse.statusCode)\(context.isEmpty ? "" : " (\(context))")")
        
        guard (200...299).contains(httpResponse.statusCode) else {
            print("NetworkService: HTTP error\(context.isEmpty ? "" : " in \(context)") with status \(httpResponse.statusCode)")
            let responseMessage = makeResponseMessage(from: data)
            if let responseString = String(data: data, encoding: .utf8) {
                print("NetworkService: Response body: \(responseString)")
            }
            
            // Classify HTTP status codes into appropriate ImmichError types
            switch httpResponse.statusCode {
            case 401:
                throw ImmichError.notAuthenticated
            case 403:
                throw ImmichError.forbidden
            case 500...599:
                throw ImmichError.httpError(statusCode: httpResponse.statusCode, message: responseMessage)
            case 400...499:
                throw ImmichError.httpError(statusCode: httpResponse.statusCode, message: responseMessage)
            default:
                // For any other status codes, treat as server error
                throw ImmichError.httpError(statusCode: httpResponse.statusCode, message: responseMessage)
            }
        }
        
        return data
    }

    private func makeResponseMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = json["message"] as? String, !message.isEmpty {
                return message
            }
            if let error = json["error"] as? String, !error.isEmpty {
                return error
            }
        }

        let responseString = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return responseString?.isEmpty == false ? responseString : nil
    }

    func makeRequest<T: Codable>(
        endpoint: String,
        method: HTTPMethod = .GET,
        body: [String: Any]? = nil,
        responseType: T.Type
    ) async throws -> T {
        let request = try buildAuthenticatedRequest(endpoint: endpoint, method: method, body: body)
        print("NetworkService: Making request to \(request.url?.absoluteString ?? endpoint)")
        let diagnosticsTracked = PerformanceDiagnostics.networkRequestStarted()
        var responseByteCount = 0
        defer { PerformanceDiagnostics.networkRequestFinished(responseBytes: responseByteCount, wasTracked: diagnosticsTracked) }
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
            responseByteCount = data.count
        } catch {
            print("NetworkService: Network error occurred: \(error)")
            // Handle network connectivity issues (timeouts, connection refused, DNS failures, etc.)
            throw ImmichError.networkError
        }
        
        let validatedData = try processResponse(response, data: data, context: "makeRequest")
        
        do {
            let result = try JSONDecoder().decode(responseType, from: validatedData)
            print("NetworkService: Successfully decoded response")
            return result
        } catch {
            print("NetworkService: Failed to decode response: \(error)")
            if let responseString = String(data: validatedData, encoding: .utf8) {
                print("NetworkService: Raw response: \(responseString)")
            }
            throw error
        }
    }
    
    func makeDataRequest(endpoint: String) async throws -> Data {
        var request = try buildAuthenticatedRequest(endpoint: endpoint, method: .GET, body: nil)
        
        // Remove Content-Type header for data requests (we don't want application/json for binary data)
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
        let diagnosticsTracked = PerformanceDiagnostics.networkRequestStarted()
        var responseByteCount = 0
        defer { PerformanceDiagnostics.networkRequestFinished(responseBytes: responseByteCount, wasTracked: diagnosticsTracked) }
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
            responseByteCount = data.count
        } catch {
            print("NetworkService: Network error occurred in makeDataRequest: \(error)")
            // Handle network connectivity issues (timeouts, connection refused, DNS failures, etc.)
            throw ImmichError.networkError
        }
        
        return try processResponse(response, data: data, context: "makeDataRequest")
    }

    func makeVoidRequest(
        endpoint: String,
        method: HTTPMethod = .POST,
        body: [String: Any]? = nil
    ) async throws {
        let request = try buildAuthenticatedRequest(endpoint: endpoint, method: method, body: body)
        print("NetworkService: Making void request to \(request.url?.absoluteString ?? endpoint)")
        let diagnosticsTracked = PerformanceDiagnostics.networkRequestStarted()
        var responseByteCount = 0
        defer { PerformanceDiagnostics.networkRequestFinished(responseBytes: responseByteCount, wasTracked: diagnosticsTracked) }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
            responseByteCount = data.count
        } catch {
            print("NetworkService: Network error occurred in makeVoidRequest: \(error)")
            throw ImmichError.networkError
        }

        _ = try processResponse(response, data: data, context: "makeVoidRequest")
    }
}

// MARK: - Supporting Types
enum HTTPMethod: String {
    case GET = "GET"
    case POST = "POST"
    case PUT = "PUT"
    case DELETE = "DELETE"
    case HEAD = "HEAD"
}

enum ImmichError: Error, LocalizedError {
    case notAuthenticated           // 401 - Invalid/expired token
    case forbidden                  // 403 - Access denied
    case invalidURL                 // Malformed URL
    case serverError(Int)          // 5xx - Server issues
    case networkError              // Network connectivity issues
    case clientError(Int)          // 4xx (except 401/403)
    case httpError(statusCode: Int, message: String?)
    case invalidUnlockCredentials  // No password or PIN code provided
    
    var shouldLogout: Bool {
        switch self {
        case .notAuthenticated, .forbidden:
            return true
        case .serverError, .networkError, .invalidURL, .clientError, .httpError, .invalidUnlockCredentials:
            return false
        }
    }
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated. Please log in."
        case .forbidden:
            return "Access forbidden. Please check your permissions."
        case .invalidURL:
            return "Invalid URL"
        case .serverError(let statusCode):
            return "Server error occurred (HTTP \(statusCode))"
        case .networkError:
            return "Network error occurred"
        case .clientError(let statusCode):
            return "Client error occurred (HTTP \(statusCode))"
        case .httpError(let statusCode, let message):
            if let message, !message.isEmpty {
                return message
            }
            if (400...499).contains(statusCode) {
                return "Client error occurred (HTTP \(statusCode))"
            }
            return "Server error occurred (HTTP \(statusCode))"
        case .invalidUnlockCredentials:
            return "Enter your password or PIN code to unlock locked assets."
        }
    }
} 
