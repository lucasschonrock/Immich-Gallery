//
//  ImmichHTTPClient.swift
//  Immich Gallery
//
//  Shared URLSession that presents a bundled PKCS#12 client certificate
//  when the Immich server (or a reverse proxy) requests mTLS.
//

import Combine
import Foundation
import Security

final class ImmichHTTPClient: NSObject, URLSessionDelegate, ObservableObject {
    static let shared = ImmichHTTPClient()

    enum CertificateStatus: Equatable {
        case notConfigured
        case ready
        case needsPassword
        case failed(String)

        var settingsTitle: String {
            switch self {
            case .notConfigured: return "Not bundled"
            case .ready: return "Ready"
            case .needsPassword: return "Password required"
            case .failed: return "Failed"
            }
        }

        var settingsSubtitle: String {
            switch self {
            case .notConfigured:
                return "Drop client.p12 into Shared/mTLS and rebuild. Optional: mtls-password.txt or set a password here."
            case .ready:
                return "Client certificate loaded. HTTPS requests will present it when the server asks."
            case .needsPassword:
                return "Found client.p12 but the password is missing or wrong. Set it below, or add Shared/mTLS/mtls-password.txt and rebuild."
            case .failed(let message):
                return message
            }
        }
    }

    @Published private(set) var certificateStatus: CertificateStatus = .notConfigured

    private static let passwordDefaultsKey = "mtls_p12_password"
    private static let certificateResourceName = "client"
    private static let certificateExtension = "p12"
    private static let passwordResourceName = "mtls-password"

    private let identityLock = NSLock()
    private var identity: SecIdentity?
    private var certificateChain: [Any] = []

    private(set) lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    var storedPassword: String {
        get {
            sharedDefaults.string(forKey: Self.passwordDefaultsKey) ?? ""
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                sharedDefaults.removeObject(forKey: Self.passwordDefaultsKey)
            } else {
                sharedDefaults.set(trimmed, forKey: Self.passwordDefaultsKey)
            }
            reloadCertificate()
        }
    }

    private var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: AppConstants.appGroupIdentifier) ?? .standard
    }

    private override init() {
        super.init()
        reloadCertificate()
    }

    func reloadCertificate() {
        identityLock.lock()
        defer { identityLock.unlock() }

        identity = nil
        certificateChain = []

        guard let certificateURL = certificateFileURL() else {
            publishStatus(.notConfigured)
            print("ImmichHTTPClient: No client.p12 in the app bundle; mTLS disabled")
            return
        }

        do {
            let data = try Data(contentsOf: certificateURL)
            let imported = try importIdentity(from: data, password: resolvedPassword())
            identity = imported.identity
            certificateChain = imported.chain
            publishStatus(.ready)
            print("ImmichHTTPClient: Loaded client certificate from \(certificateURL.lastPathComponent)")
        } catch CertificateImportError.authFailed {
            publishStatus(.needsPassword)
            print("ImmichHTTPClient: client.p12 password is missing or incorrect")
        } catch {
            publishStatus(.failed(error.localizedDescription))
            print("ImmichHTTPClient: Failed to import client.p12: \(error)")
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            identityLock.lock()
            let currentIdentity = identity
            let chain = certificateChain
            identityLock.unlock()

            guard let currentIdentity else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            let credential = URLCredential(
                identity: currentIdentity,
                certificates: chain,
                persistence: .forSession
            )
            completionHandler(.useCredential, credential)

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func resolvedPassword() -> String {
        let stored = storedPassword
        if !stored.isEmpty {
            return stored
        }
        if let url = passwordFileURL(),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            return contents.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private func certificateFileURL() -> URL? {
        let bundle = Bundle.main
        let name = Self.certificateResourceName
        let ext = Self.certificateExtension
        if let url = bundle.url(forResource: name, withExtension: ext) {
            return url
        }
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "mTLS") {
            return url
        }
        return bundle.urls(forResourcesWithExtension: ext, subdirectory: nil)?.first { $0.lastPathComponent == "\(name).\(ext)" }
            ?? bundle.urls(forResourcesWithExtension: ext, subdirectory: nil)?.first
    }

    private func passwordFileURL() -> URL? {
        let bundle = Bundle.main
        let name = Self.passwordResourceName
        if let url = bundle.url(forResource: name, withExtension: "txt") {
            return url
        }
        return bundle.url(forResource: name, withExtension: "txt", subdirectory: "mTLS")
    }

    private func importIdentity(from data: Data, password: String) throws -> (identity: SecIdentity, chain: [Any]) {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)

        if status == errSecAuthFailed || status == errSecPkcs12VerifyFailure {
            throw CertificateImportError.authFailed
        }
        guard status == errSecSuccess else {
            throw CertificateImportError.osStatus(status)
        }
        guard
            let dictionaries = items as? [[String: Any]],
            let first = dictionaries.first,
            let identityValue = first[kSecImportItemIdentity as String]
        else {
            throw CertificateImportError.missingIdentity
        }
        let identity = identityValue as! SecIdentity

        let chain = first[kSecImportItemCertChain as String] as? [Any] ?? []
        return (identity, chain)
    }

    private func publishStatus(_ status: CertificateStatus) {
        if Thread.isMainThread {
            certificateStatus = status
        } else {
            DispatchQueue.main.async {
                self.certificateStatus = status
            }
        }
    }
}

private enum CertificateImportError: LocalizedError {
    case authFailed
    case missingIdentity
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .authFailed:
            return "The PKCS#12 password is missing or incorrect."
        case .missingIdentity:
            return "client.p12 did not contain a client identity."
        case .osStatus(let status):
            return "Failed to import client.p12 (OSStatus \(status))."
        }
    }
}
