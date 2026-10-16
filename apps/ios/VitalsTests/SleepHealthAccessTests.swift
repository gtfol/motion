import XCTest
import HealthKit
@testable import Vitals

final class SleepHealthAccessTests: XCTestCase {
    private enum Failure: Error { case unavailable }

    @MainActor func testFirstRequestThenManageAccessWithoutSecondPrompt() async {
        var requests = 0
        let health = SleepHealthStore(authorization: .init(available: { true },
            status: { requests == 0 ? .shouldRequest : .unnecessary }, request: { requests += 1 }))
        let first = await health.connect()
        XCTAssertEqual(first, .requested)
        let second = await health.connect()
        XCTAssertEqual(second, .manageAccess)
        XCTAssertEqual(requests, 1)
        // Neither completion nor an unnecessary request implies that read access was granted.
        XCTAssertTrue(health.records.isEmpty)
    }

    @MainActor func testUnknownRequestStatusStillAttemptsAuthorization() async {
        var requests = 0
        let health = SleepHealthStore(authorization: .init(available: { true },
            status: { .unknown }, request: { requests += 1 }))
        let result = await health.connect()
        XCTAssertEqual(result, .requested)
        XCTAssertEqual(requests, 1)
    }

    @MainActor func testAuthorizationErrorsReturnFailureInsteadOfSilentSuccess() async {
        for statusFails in [true, false] {
            var requests = 0
            let health = SleepHealthStore(authorization: .init(available: { true }, status: {
                if statusFails { throw Failure.unavailable }
                return .shouldRequest
            }, request: { requests += 1; throw Failure.unavailable }))
            let result = await health.connect()
            XCTAssertEqual(result, .failed)
            XCTAssertEqual(requests, statusFails ? 0 : 1)
        }
    }

    @MainActor func testUnavailableHealthDoesNotTryToRequestAccess() async {
        let health = SleepHealthStore(authorization: .init(available: { false },
            status: { XCTFail("must not check unavailable Health"); return .unknown },
            request: { XCTFail("must not request unavailable Health") }))
        let result = await health.connect()
        XCTAssertEqual(result, .unavailable)
    }
}
