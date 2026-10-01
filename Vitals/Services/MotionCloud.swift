import Foundation
import Supabase

/// Both values are public client configuration. Never embed a service-role key here or in Info.plist.
struct MotionCloudConfiguration: Sendable {
    var url: URL
    var publishableKey: String
    static var bundled: MotionCloudConfiguration? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "MotionSupabaseURL") as? String,
              let url = URL(string: text), url.scheme == "https", url.host?.hasSuffix(".supabase.co") == true,
              let key = Bundle.main.object(forInfoDictionaryKey: "MotionSupabasePublishableKey") as? String,
              key.hasPrefix("sb_publishable_") else { return nil }
        return MotionCloudConfiguration(url: url, publishableKey: key)
    }
}

@MainActor final class MotionCloud {
    let configuration: MotionCloudConfiguration
    let client: SupabaseClient
    init(configuration: MotionCloudConfiguration) {
        self.configuration = configuration
        client = SupabaseClient(supabaseURL: configuration.url, supabaseKey: configuration.publishableKey,
            options: SupabaseClientOptions(auth: .init(storage: KeychainLocalStorage(service: "dev.gtfol.vitals.motion-auth"),
                redirectToURL: URL(string: "dev.gtfol.vitals://auth/callback")!, storageKey: "motion-session",
                flowType: .pkce, emitLocalSessionAsInitialSession: true)))
    }
    func signIn() async throws -> UUID {
        let session = try await client.auth.signInWithOAuth(provider: .google) { session in
            session.prefersEphemeralWebBrowserSession = true
        }
        return session.user.id
    }
    func signOut() async { try? await client.auth.signOut(scope: .local) }
    func transport(owner: UUID) -> MotionTransport { MotionTransport(cloud: self, owner: owner) }

    func request(path: String, body: SyncValue, owner: UUID) async throws -> Data {
        let session: Session
        do { session = try await client.auth.session }
        catch is URLError { throw SyncFailure.unavailable }
        catch { throw SyncFailure.unauthorized }
        guard session.user.id == owner else { throw SyncFailure.unauthorized }
        // Capture this owner's token, rather than letting an asynchronous request adopt another login.
        var request = URLRequest(url: configuration.url.appendingPathComponent(path))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try SyncCoding.encoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard client.auth.currentSession?.user.id == owner else { throw SyncFailure.accountChanged }
        guard let http = response as? HTTPURLResponse else { throw SyncFailure.unavailable }
        if http.statusCode == 401 || http.statusCode == 403 { throw SyncFailure.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw SyncFailure.unavailable }
        return data
    }
    func deleteAccount(owner: UUID) async throws {
        _ = try await request(path: "functions/v1/delete-account", body: .object([:]), owner: owner)
    }
}

@MainActor struct MotionTransport: SyncTransport {
    let cloud: MotionCloud
    let owner: UUID
    func pull(after: Int64) async throws -> [CloudRecord] {
        let data = try await cloud.request(path: "rest/v1/rpc/motion_pull", body: .object([
            "after_revision": .number(Double(after)), "page_size": .number(100)]), owner: owner)
        return try SyncCoding.decoder().decode([CloudRecord].self, from: data)
    }
    func get(_ key: SyncKey) async throws -> CloudRecord? {
        let data = try await cloud.request(path: "rest/v1/rpc/motion_get", body: .object([
            "record_kind": .string(key.kind.rawValue), "record_id": .string(key.id.uuidString)]), owner: owner)
        return try SyncCoding.decoder().decode(CloudRecord?.self, from: data)
    }
    func apply(_ mutation: SyncMutation) async throws -> SyncReply {
        let data = try await cloud.request(path: "rest/v1/rpc/motion_apply", body: .object([
            "mutation_id": .string(mutation.mutationID.uuidString), "record_kind": .string(mutation.key.kind.rawValue),
            "record_id": .string(mutation.key.id.uuidString), "expected_revision": .number(Double(mutation.expectedRevision)),
            "document": mutation.body ?? .null]), owner: owner)
        return try SyncCoding.decoder().decode(SyncReply.self, from: data)
    }
}
