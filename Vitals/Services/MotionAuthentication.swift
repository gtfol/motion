import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

struct MotionUser: Codable, Equatable, Sendable { var id: UUID; var email: String; var name: String }
struct MotionLogin: Codable, Equatable, Sendable { var token: String; var user: MotionUser }
struct MotionSignInAttempt: Sendable {
    static let scheme = "dev.gtfol.vitals"
    let verifier: String
    let state: String
    init() throws { verifier = try Self.random(); state = try Self.random() }
    init(verifier: String, state: String) { self.verifier = verifier; self.state = state }
    var challenge: String { Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    func url(base: URL) -> URL {
        var components = URLComponents(url: base.appendingPathComponent("connect"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "state", value: state)]
        return components.url!
    }
    func code(from callback: URL) throws -> String {
        guard let url = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              url.scheme == Self.scheme, url.host == "auth", url.path == "/callback",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let items = url.queryItems, items.count == 2,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value,
              code.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else { throw SyncFailure.unauthorized }
        return code
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SyncFailure.unavailable }
        return base64url(Data(bytes))
    }
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// This-device-only keychain storage; never synced through iCloud or written to preferences.
enum MotionCredentials {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.gtfol.vitals.motion-web-auth", kSecAttrAccount as String: "session"] }
    static func read() throws -> MotionLogin? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SyncFailure.unavailable }
        return try JSONDecoder().decode(MotionLogin.self, from: data)
    }
    static func write(_ login: MotionLogin?) throws {
        guard let login else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SyncFailure.unavailable }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(login),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw SyncFailure.unavailable }
        } else if status != errSecSuccess { throw SyncFailure.unavailable }
    }
}

@MainActor final class MotionBrowserSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var pending: CheckedContinuation<URL, Error>?
    func authenticate(url: URL) async throws -> URL {
        guard session == nil else { throw SyncFailure.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: MotionSignInAttempt.scheme) { [weak self] callback, _ in
                Task { @MainActor in
                    if let callback { self?.finish(.success(callback)) }
                    else { self?.finish(.failure(SyncFailure.unauthorized)) }
                }
            }
            self.session = session
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            if !session.start() { finish(.failure(SyncFailure.unavailable)) }
        }
    }
    private func finish(_ result: Result<URL, Error>) {
        guard let pending else { return }
        self.pending = nil; session = nil
        pending.resume(with: result)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
