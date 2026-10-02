import Foundation
import Observation

/// The iPhone only knows the public Motion URL. Database and Google secrets stay on Vercel.
struct MotionCloudConfiguration: Sendable {
    var url: URL
    static var bundled: MotionCloudConfiguration? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "MotionServerURL") as? String,
              let url = URL(string: text), url.scheme == "https", url.host == "motion.gtfol.dev",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return MotionCloudConfiguration(url: url)
    }
}

@MainActor @Observable final class MotionCloud {
    let configuration: MotionCloudConfiguration
    private(set) var login: MotionLogin?
    @ObservationIgnored private let browser = MotionBrowserSignIn()
    init(configuration: MotionCloudConfiguration) {
        self.configuration = configuration
        login = try? MotionCredentials.read()
    }
    func signIn() async throws -> UUID {
        let attempt = try MotionSignInAttempt()
        let callback = try await browser.authenticate(url: attempt.url(base: configuration.url))
        let code = try attempt.code(from: callback)
        var request = URLRequest(url: configuration.url.appendingPathComponent("api/native/exchange"))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code, "code_verifier": attempt.verifier])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SyncFailure.unauthorized }
        let next = try JSONDecoder().decode(MotionLogin.self, from: data)
        guard next.token.range(of: "^motion_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              next.user.email.count <= 1000 else { throw SyncFailure.invalidDocument }
        do { try MotionCredentials.write(next) }
        catch { await revoke(next); throw error }
        let previous = login
        login = next
        if let previous { await revoke(previous) }
        return next.user.id
    }
    func signOut() async throws {
        let previous = login
        try MotionCredentials.write(nil)
        login = nil
        if let previous { await revoke(previous) }
    }
    private func revoke(_ session: MotionLogin) async {
        var request = URLRequest(url: configuration.url.appendingPathComponent("api/native/session"))
        request.httpMethod = "DELETE"; request.timeoutInterval = 10
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }
    func transport(owner: UUID) -> MotionTransport { MotionTransport(cloud: self, owner: owner) }
    func request(path: String, body: SyncValue, owner: UUID) async throws -> Data {
        guard let session = login, session.user.id == owner else { throw SyncFailure.unauthorized }
        var request = URLRequest(url: configuration.url.appendingPathComponent(path))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try SyncCoding.encoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        // Ignore responses from a previous login, including signing back into the same account.
        guard login?.token == session.token else { throw SyncFailure.accountChanged }
        guard let http = response as? HTTPURLResponse else { throw SyncFailure.unavailable }
        if http.statusCode == 401 || http.statusCode == 403 { throw SyncFailure.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw SyncFailure.unavailable }
        return data
    }
    func deleteAccount(owner: UUID) async throws {
        _ = try await request(path: "api/native/delete-account", body: .object(["confirm": .string("delete")]), owner: owner)
    }
}

@MainActor struct MotionTransport: SyncTransport {
    let cloud: MotionCloud
    let owner: UUID
    func pull(after: Int64) async throws -> [CloudRecord] {
        let data = try await cloud.request(path: "api/sync/pull", body: .object([
            "after_revision": .number(Double(after)), "page_size": .number(100)]), owner: owner)
        return try SyncCoding.decoder().decode([CloudRecord].self, from: data)
    }
    func get(_ key: SyncKey) async throws -> CloudRecord? {
        let data = try await cloud.request(path: "api/sync/get", body: .object([
            "record_kind": .string(key.kind.rawValue), "record_id": .string(key.id.uuidString)]), owner: owner)
        return try SyncCoding.decoder().decode(CloudRecord?.self, from: data)
    }
    func apply(_ mutation: SyncMutation) async throws -> SyncReply {
        let data = try await cloud.request(path: "api/sync/apply", body: .object([
            "mutation_id": .string(mutation.mutationID.uuidString), "record_kind": .string(mutation.key.kind.rawValue),
            "record_id": .string(mutation.key.id.uuidString), "expected_revision": .number(Double(mutation.expectedRevision)),
            "document": mutation.body ?? .null]), owner: owner)
        return try SyncCoding.decoder().decode(SyncReply.self, from: data)
    }
}
