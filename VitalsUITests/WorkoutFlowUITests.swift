import XCTest

/// Drives the real interface through a strength workout on a fresh store, without a strap and with Apple Health
/// unavailable, and keeps screenshots of each screen in the test results.
final class WorkoutFlowUITests: XCTestCase {
    @MainActor func testSleepShowsRecordedStagesAndTrends() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sleep"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-sleep"].waitForExistence(timeout: 15))
        app.buttons["tab-sleep"].tap()
        XCTAssertTrue(app.staticTexts["sleep-duration"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["sleep-duration"].label, "7h 42m")
        capture(app, "sleep stages sample measurements")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["breathing rate"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "sleep heart and breathing measurements")
        app.swipeUp()
        capture(app, "sleep duration and schedule")
        app.swipeUp()
        capture(app, "sleep weekly trends")
    }

    @MainActor func testSleepWithoutReadableDataExplainsConnection() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sleep", "-ui-testing-sleep-empty"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-sleep"].waitForExistence(timeout: 15))
        app.buttons["tab-sleep"].tap()
        XCTAssertTrue(app.staticTexts["no sleep measurements for this date"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["sleep-duration"].exists)
        XCTAssertTrue(app.buttons["refresh measurements"].exists)
        capture(app, "sleep without readable measurements")
    }

    @MainActor func testWorkoutKeyboardHidesNavigationAndKeepsRestFlush() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["start-strength"].waitForExistence(timeout: 15))
        app.buttons["start-strength"].tap()
        add("bench press", in: app)
        enter("135", into: app.textFields["bench press-1-load"], in: app)
        enter("5", into: app.textFields["bench press-1-reps"], in: app)
        app.buttons["bench press-1-done"].tap()
        app.buttons["add-set-bench press"].tap()

        let field = app.textFields["bench press-2-load"]
        field.tap()
        field.typeText("145")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tab-train"].exists)
        XCTAssertFalse(app.buttons["tab-history"].exists)
        XCTAssertFalse(app.buttons["tab-sleep"].exists)
        XCTAssertFalse(app.buttons["tab-settings"].exists)
        let rest = app.otherElements["rest-bar"]
        XCTAssertTrue(rest.exists)
        // iOS 26's keyboard accessibility frame starts 17 pt below its rounded background.
        // The attached screenshot verifies the backgrounds touch; reject an extra toolbar/nav row.
        let keyboardInset = app.keyboards.firstMatch.frame.minY - rest.frame.maxY
        XCTAssertGreaterThanOrEqual(keyboardInset, -2, "the rest bar must not overlap the keyboard")
        XCTAssertLessThanOrEqual(keyboardInset, 20, "no navigation or toolbar gap above the keyboard")
        XCTAssertTrue(rest.buttons["keyboard-done"].exists, "dismiss typing inside the rest bar")
        capture(app, "rest directly above keyboard")
        app.buttons["keyboard-done"].tap()
        XCTAssertTrue(app.buttons["tab-train"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(field.value as? String, "145", "dismissing the keyboard saves the entered load")
        XCTAssertTrue(app.buttons["rest-skip"].exists, "dismissing typing keeps the rest timer running")
    }

    @MainActor func testRoutineTargetControlsDoNotOverlap() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["new routine"].waitForExistence(timeout: 15))
        app.buttons["new routine"].tap()
        let alert = app.alerts["new routine"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.tap()
        alert.textFields.firstMatch.typeText("chest")
        alert.buttons["create"].tap()
        XCTAssertTrue(app.buttons["add exercise"].waitForExistence(timeout: 5))
        app.buttons["add exercise"].tap()
        XCTAssertTrue(app.buttons["pick-bench press"].waitForExistence(timeout: 5))
        app.buttons["pick-bench press"].tap()

        let sets = app.steppers["routine-target-sets"]
        let reps = app.steppers["routine-target-reps"]
        XCTAssertTrue(sets.waitForExistence(timeout: 5))
        XCTAssertTrue(reps.exists)
        XCTAssertGreaterThanOrEqual(reps.frame.minY - sets.frame.maxY, 8,
                                    "set and rep controls must have separate touch areas")
        let originalReps = reps.label
        sets.buttons["routine-target-sets-Increment"].tap()
        XCTAssertTrue(sets.label.contains("4 sets"))
        XCTAssertEqual(reps.label, originalReps, "changing sets must not change reps")
        reps.buttons["routine-target-reps-Increment"].tap()
        XCTAssertTrue(reps.label.contains("1 reps"))
        XCTAssertTrue(sets.label.contains("4 sets"))
        capture(app, "routine target controls")
    }

    @MainActor func testFirstSignInCanImportLocalLog() {
        finishFirstSignIn(using: "add my local log")
    }

    @MainActor func testFirstSignInCanChooseCloudLog() {
        finishFirstSignIn(using: "use my cloud log")
    }

    @MainActor private func finishFirstSignIn(using choice: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Exercises the actual root presentation after the Google handoff,
        // using an isolated store and no production credentials or network.
        app.launchArguments = ["-ui-testing", "-ui-testing-import-choice"]
        app.launch()
        XCTAssertTrue(app.staticTexts["bring your local log?"].waitForExistence(timeout: 15))
        app.buttons[choice].tap()
        XCTAssertTrue(app.buttons["start-strength"].waitForExistence(timeout: 10))
        app.buttons["tab-settings"].tap()
        XCTAssertTrue(app.buttons["sign out"].waitForExistence(timeout: 5), "the selected account becomes active without losing the presentation environment")
        capture(app, "account settings")
    }

    @MainActor func testStrengthWorkoutFromStartToHistory() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        let start = app.buttons["start-strength"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        capture(app, "1 train")
        start.tap()

        add("bench press", in: app)
        enter("135", into: app.textFields["bench press-1-load"], in: app)
        enter("5", into: app.textFields["bench press-1-reps"], in: app)
        app.buttons["bench press-1-done"].tap()
        XCTAssertTrue(app.buttons["rest-skip"].waitForExistence(timeout: 5), "completing a set starts rest")
        XCTAssertLessThanOrEqual(app.buttons["rest-skip"].frame.maxY, app.buttons["tab-train"].frame.minY,
                                 "the rest clock sits above the tab bar, not under it")
        app.buttons["add-set-bench press"].tap()
        XCTAssertEqual(app.textFields["bench press-2-load"].value as? String, "135", "a new set copies the one before it")
        app.buttons["bench press-2-done"].tap()

        add("squat", in: app)
        enter("225", into: app.textFields["squat-1-load"], in: app)
        enter("5", into: app.textFields["squat-1-reps"], in: app)
        app.buttons["squat-1-done"].tap()
        capture(app, "2 workout")

        app.buttons["finish-workout"].tap()
        let save = app.buttons["save-workout"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        capture(app, "3 finish")
        save.tap()
        let done = app.buttons["finish-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        capture(app, "4 saved")
        done.tap()

        app.buttons["tab-history"].tap()
        let row = app.buttons["session-row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        capture(app, "5 history")
        row.tap()
        XCTAssertTrue(app.textFields["bench press-1-load"].waitForExistence(timeout: 5))
        capture(app, "6 workout detail")
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["tab-settings"].tap()
        let kilograms = app.segmentedControls.buttons["kg"]
        XCTAssertTrue(kilograms.waitForExistence(timeout: 5))
        kilograms.tap()
        capture(app, "7 settings")

        app.buttons["tab-history"].tap()
        app.buttons["history-exercises"].tap()
        let bench = app.buttons["exercise-bench press"]
        XCTAssertTrue(bench.waitForExistence(timeout: 5))
        bench.tap()
        let converted = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "61.23 × 5")).firstMatch
        XCTAssertTrue(converted.waitForExistence(timeout: 5), "switching to kg shows the same set converted")
        capture(app, "8 exercise history")
    }

    @MainActor private func add(_ exercise: String, in app: XCUIApplication) {
        app.buttons["add-exercise"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(exercise)
        let row = app.buttons["pick-\(exercise)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
    }

    /// Types into a set field, then closes the keyboard so the next field isn't covered. Closing it commits the value.
    @MainActor private func enter(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
        let done = app.buttons["keyboard-done"].firstMatch
        if done.waitForExistence(timeout: 2) { done.tap() }
    }

    /// Screenshots document the run; the assertions are what the test checks. The simulator on CI has timed out
    /// taking one while vitals was idle, so a failed capture is recorded as an expected failure and the flow
    /// carries on. Every other failure still stops the test.
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let continues = continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = continues }
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("the simulator didn't return a screenshot of \(name)", options: options) {
            let screenshot = app.screenshot()
            guard !screenshot.pngRepresentation.isEmpty else { return }
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
