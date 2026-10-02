import XCTest
@testable import Vitals

final class MotionAuthenticationTests: XCTestCase {
    func testPKCEStandardVectorAndPublicRequest() throws {
        let attempt = MotionSignInAttempt(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "state")
        XCTAssertEqual(attempt.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let url = attempt.url(base: URL(string: "https://motion.gtfol.dev")!)
        XCTAssertEqual(url.path, "/connect")
        XCTAssertFalse(url.absoluteString.contains(attempt.verifier))
    }
    func testCallbackRejectsConfusedOrReplayedState() throws {
        let attempt = MotionSignInAttempt(verifier: "verifier", state: "correct")
        let code = String(repeating: "a", count: 43)
        XCTAssertEqual(try attempt.code(from: URL(string: "dev.gtfol.vitals://auth/callback?state=correct&code=\(code)")!), code)
        for url in [
            "https://auth/callback?state=correct&code=\(code)",
            "dev.gtfol.vitals://evil/callback?state=correct&code=\(code)",
            "dev.gtfol.vitals://auth/callback?state=wrong&code=\(code)",
            "dev.gtfol.vitals://auth/callback?state=correct&state=correct&code=\(code)",
            "dev.gtfol.vitals://auth/callback?state=correct&code=\(code)#token",
            "dev.gtfol.vitals://user@auth/callback?state=correct&code=\(code)",
            "dev.gtfol.vitals://auth:123/callback?state=correct&code=\(code)",
            "dev.gtfol.vitals://auth/callback?state=correct&code=short"
        ] { XCTAssertThrowsError(try attempt.code(from: URL(string: url)!)) }
    }
    func testRandomAttemptsNeverReuseSecrets() throws {
        let first = try MotionSignInAttempt(), second = try MotionSignInAttempt()
        XCTAssertEqual(first.state.count, 43); XCTAssertEqual(first.verifier.count, 43)
        XCTAssertNotEqual(first.state, second.state); XCTAssertNotEqual(first.verifier, second.verifier)
        XCTAssertNotEqual(first.state, first.verifier)
    }
}
