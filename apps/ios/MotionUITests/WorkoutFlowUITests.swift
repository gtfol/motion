import XCTest

/// Drives the real interface through a strength workout on a fresh store, without a strap and with Apple Health
/// unavailable, and keeps screenshots of each screen in the test results.
final class WorkoutFlowUITests: XCTestCase {
    @MainActor func testSleepWaitsForCombinedTotalAndKeepsItWhenReopeningTab() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sleep", "-ui-testing-strap", "-ui-testing-sleep-loading"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-sleep"].waitForExistence(timeout: 15))
        app.buttons["tab-sleep"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sleep-initial-loading").firstMatch.waitForExistence(timeout: 3))
        let total = app.staticTexts["sleep-duration"]
        XCTAssertFalse(total.exists, "do not show the cached six-hour strap record while the nap is loading")
        app.buttons["complete-test-sleep-read"].tap()
        XCTAssertTrue(total.waitForExistence(timeout: 8))
        XCTAssertEqual(total.label, "8h 0m")
        capture(app, "complete sleep and nap total")
        app.buttons["tab-train"].tap()
        app.buttons["tab-sleep"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sleep-refreshing").firstMatch.waitForExistence(timeout: 2))
        XCTAssertEqual(total.label, "8h 0m", "reopening must keep the full total during the delayed refresh")
        capture(app, "stable total while refreshing")
        app.buttons["complete-test-sleep-read"].tap()
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
            object: app.descendants(matching: .any).matching(identifier: "sleep-refreshing").firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 8), .completed)
        XCTAssertEqual(total.label, "8h 0m")
        app.buttons["sleep-previous"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sleep-initial-loading").firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(total.exists, "the previous date must not borrow the last date's total")
        app.buttons["complete-test-sleep-read"].tap()
        XCTAssertTrue(total.waitForExistence(timeout: 8))
        XCTAssertEqual(total.label, "8h 0m")
    }

    @MainActor func testSleepAccessRefreshesThenShowsManagementOnRepeatTap() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sleep-access"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-settings"].waitForExistence(timeout: 15))
        app.buttons["tab-settings"].tap()
        app.swipeUp()
        let access = app.buttons["sleep-health-connect"]
        XCTAssertTrue(access.waitForExistence(timeout: 5))
        XCTAssertEqual(access.label, "connect sleep data")
        access.tap()
        XCTAssertTrue(app.staticTexts["sleep data refreshed"].waitForExistence(timeout: 5))
        XCTAssertEqual(access.label, "manage sleep access")
        access.tap()
        XCTAssertTrue(app.staticTexts["sleep-health-instructions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sleep-health-open"].isHittable)
        capture(app, "manage Apple Health sleep access")
        app.buttons["sleep-health-open"].tap()
        let healthApp = XCUIApplication(bundleIdentifier: "com.apple.Health")
        XCTAssertTrue(healthApp.wait(for: .runningForeground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.staticTexts["sleep data refreshed"].waitForExistence(timeout: 5))
        access.tap()
        XCTAssertTrue(app.staticTexts["sleep-health-instructions"].waitForExistence(timeout: 5))
        app.buttons["close"].tap()
        app.buttons["tab-sleep"].tap()
        XCTAssertTrue(app.staticTexts["sleep-duration"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["sleep-duration"].label, "7h 42m")
    }

    @MainActor func testAllSleepPeriodsShareOneTimelineAndDailyTotal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sleep", "-ui-testing-naps"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-sleep"].waitForExistence(timeout: 15))
        app.buttons["tab-sleep"].tap()
        XCTAssertTrue(app.staticTexts["sleep-duration"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["sleep-duration"].label, "3h 47m")
        XCTAssertFalse(app.buttons["sleep-nap"].exists)
        XCTAssertFalse(app.staticTexts["naps"].exists)
        capture(app, "combined sleep total")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(app.otherElements["sleep-stages-chart"].firstMatch.exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "sleep stages")).count, 1)
        capture(app, "combined sleep timeline with gap")
        app.segmentedControls["sleep-period"].buttons["weekly"].tap()
        let chart = app.otherElements["sleep-weekly-duration-chart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        XCTAssertTrue((chart.value as? String)?.contains("3h 47m") == true)
        XCTAssertFalse(app.staticTexts["sleep-weekly-naps"].exists)
        XCTAssertFalse(app.staticTexts["naps"].exists)
        capture(app, "weekly combined sleep totals")
        app.swipeUp()
        capture(app, "weekly schedule keeps gaps between periods")
    }

    @MainActor func testSleepSyncIssueIsCompactAndKeepsChartsVisible() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sleep", "-ui-testing-strap", "-ui-testing-sleep-sync-error"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-sleep"].waitForExistence(timeout: 15))
        app.buttons["tab-sleep"].tap()
        let issue = app.buttons["sleep-sync-issue"]
        XCTAssertTrue(issue.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["sleep-duration"].label, "7h 42m")
        XCTAssertLessThan(issue.frame.maxY, app.staticTexts["sleep-duration"].frame.minY)
        let explanation = "Motion couldn’t read some sleep data from your strap. try syncing again."
        XCTAssertFalse(app.staticTexts[explanation].isHittable, "the hidden settings page must not expose details on Sleep")
        issue.tap()
        let alert = app.alerts["sync incomplete"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts[explanation].exists)
        XCTAssertTrue(alert.buttons["try again"].exists)
        capture(app, "plain sync explanation")
        alert.buttons["close"].tap()
        app.swipeUp()
        XCTAssertFalse(app.staticTexts[explanation].isHittable)
        XCTAssertFalse(app.staticTexts["the strap returned stages outside its recorded sleep period."].exists)
        XCTAssertFalse(app.buttons["copy sync details"].exists)
        capture(app, "sleep charts without error footer")
        app.segmentedControls["sleep-period"].buttons["weekly"].tap()
        XCTAssertTrue(issue.isHittable)
        XCTAssertTrue(app.otherElements["sleep-weekly-duration-chart"].firstMatch.exists)
        capture(app, "weekly sleep with compact sync status")
    }

    @MainActor func testEmptySleepStillExplainsSyncFailureAndOffersRetry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sleep", "-ui-testing-sleep-empty", "-ui-testing-sleep-sync-error"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-sleep"].waitForExistence(timeout: 15))
        app.buttons["tab-sleep"].tap()
        XCTAssertTrue(app.staticTexts["no sleep measurements for this date"].waitForExistence(timeout: 5))
        app.buttons["sleep-sync-issue"].tap()
        XCTAssertTrue(app.alerts["sync incomplete"].waitForExistence(timeout: 5))
        app.alerts["sync incomplete"].buttons["try again"].tap()
        XCTAssertTrue(app.buttons["sleep-sync-issue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["no sleep measurements for this date"].exists)
        XCTAssertFalse(app.staticTexts["sleep-duration"].exists)
        capture(app, "empty sleep keeps actionable sync status")
    }

    @MainActor func testStrapSyncIsBesideSettingsAndSetupOnlyManagesKey() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-strap"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-settings"].waitForExistence(timeout: 15))
        app.buttons["tab-settings"].tap()
        let setup = app.buttons["helio-setup"], sync = app.buttons["helio-sync"]
        for _ in 0..<3 where !setup.isHittable { app.swipeUp() }
        XCTAssertTrue(setup.isHittable)
        XCTAssertTrue(sync.isHittable)
        XCTAssertTrue(sync.isEnabled)
        XCTAssertEqual(setup.frame.midY, sync.frame.midY, accuracy: 2)
        capture(app, "strap settings with sync beside it")
        setup.tap()
        XCTAssertTrue(app.secureTextFields["helio-key"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["helio-save"].label, "save key")
        XCTAssertFalse(app.buttons["sync now"].isHittable, "the sync action belongs to the screen behind the key sheet")
        XCTAssertFalse(app.buttons["save & sync"].exists)
        XCTAssertFalse(app.staticTexts["ready to sync"].exists)
        capture(app, "strap key settings")
        app.buttons["close"].tap()
        sync.tap()
        XCTAssertEqual(sync.label, "syncing…")
        XCTAssertFalse(sync.isEnabled)
        XCTAssertTrue(app.staticTexts["connecting to strap…"].exists)
    }

    @MainActor func testSleepConnectionsLiveInSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-sleep"].waitForExistence(timeout: 15))
        app.buttons["tab-sleep"].tap()
        XCTAssertTrue(app.staticTexts["no sleep measurements for this date"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["helio-setup"].isHittable)
        XCTAssertFalse(app.buttons["sleep-health-connect"].isHittable)
        XCTAssertFalse(app.segmentedControls["sleep-source"].exists)
        XCTAssertFalse(app.buttons["refresh measurements"].exists)
        XCTAssertFalse(app.staticTexts["from Helio Strap · stays on this iPhone"].exists)
        capture(app, "simple sleep page")

        app.buttons["tab-settings"].tap()
        app.swipeUp()
        let setup = app.buttons["helio-setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sleep-health-connect"].exists)
        capture(app, "sleep connections in settings")
        setup.tap()
        XCTAssertTrue(app.secureTextFields["helio-key"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["helio-save"].isEnabled)
        XCTAssertTrue(app.buttons["choose"].exists)
        capture(app, "Helio setup from settings")
        app.buttons["close"].tap()
        app.buttons["tab-sleep"].tap()
        XCTAssertTrue(app.staticTexts["no sleep measurements for this date"].waitForExistence(timeout: 5))
    }

    @MainActor func testSleepSeparatesDailyMeasurementsFromWeeklyTrends() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sleep"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-sleep"].waitForExistence(timeout: 15))
        app.buttons["tab-sleep"].tap()
        XCTAssertTrue(app.staticTexts["sleep-duration"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["sleep-duration"].label, "7h 42m", "Health fills a missing Helio night automatically")
        XCTAssertFalse(app.segmentedControls["sleep-source"].exists)
        let period = app.segmentedControls["sleep-period"]
        XCTAssertTrue(period.buttons["daily"].isSelected)
        XCTAssertFalse(app.staticTexts["sleep-week-range"].exists)
        XCTAssertFalse(app.staticTexts["sleep schedule"].exists)
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["sleep-duration"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["sleep-duration"].label, "7h 42m", "pull to refresh keeps one copy of the night")
        capture(app, "daily sleep stages")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["breathing rate"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "daily sleep heart and breathing measurements")
        XCTAssertTrue(period.buttons["weekly"].isHittable, "period tabs stay accessible when the page scrolls")
        period.buttons["weekly"].tap()
        let range = app.staticTexts["sleep-week-range"]
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        XCTAssertTrue(range.isHittable, "switching periods starts at the top")
        XCTAssertFalse(app.staticTexts["sleep-duration"].exists)
        XCTAssertFalse(app.otherElements["sleep-stages-chart"].exists)
        XCTAssertTrue(app.staticTexts["sleep schedule"].exists)
        XCTAssertFalse(app.buttons["sleep-next"].isEnabled)
        let currentRange = range.label
        capture(app, "weekly sleep duration and schedule")
        app.swipeUp()
        capture(app, "sleep weekly trends")
        app.swipeDown()
        app.swipeDown()
        app.buttons["sleep-previous"].tap()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let priorStart = calendar.date(byAdding: .day, value: -13, to: today)!
        let priorEnd = calendar.date(byAdding: .day, value: -7, to: today)!
        let priorRange = "\(priorStart.formatted(.dateTime.month(.abbreviated).day())) – \(priorEnd.formatted(.dateTime.month(.abbreviated).day()))"
        XCTAssertTrue(app.staticTexts[priorRange].waitForExistence(timeout: 5), "weekly arrows move by seven days")
        app.buttons["sleep-next"].tap()
        XCTAssertTrue(app.staticTexts[currentRange].waitForExistence(timeout: 5))

        period.buttons["daily"].tap()
        XCTAssertTrue(app.staticTexts["sleep-duration"].waitForExistence(timeout: 5))
        XCTAssertFalse(range.exists)
        app.buttons["sleep-previous"].tap()
        period.buttons["weekly"].tap()
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        XCTAssertNotEqual(range.label, currentRange, "the selected date is kept across periods")
        app.buttons["sleep-next"].tap()
        XCTAssertTrue(app.staticTexts[currentRange].waitForExistence(timeout: 5), "forward navigation stops at today")
        XCTAssertFalse(app.buttons["sleep-next"].isEnabled)
    }

    @MainActor func testSleepWithoutReadableDataExplainsConnection() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-sleep", "-ui-testing-sleep-empty"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-sleep"].waitForExistence(timeout: 15))
        app.buttons["tab-sleep"].tap()
        XCTAssertTrue(app.staticTexts["no sleep measurements for this date"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["sleep-duration"].exists)
        XCTAssertFalse(app.buttons["refresh measurements"].exists)
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["no sleep measurements for this date"].waitForExistence(timeout: 5))
        capture(app, "sleep without readable measurements")
        app.segmentedControls["sleep-period"].buttons["weekly"].tap()
        XCTAssertTrue(app.staticTexts["no sleep measurements for this week"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["sleep-duration"].exists)
        XCTAssertFalse(app.staticTexts["sleep-week-range"].exists)
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["no sleep measurements for this week"].waitForExistence(timeout: 5))
        capture(app, "weekly sleep without readable measurements")
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
    /// taking one while Motion was idle, so a failed capture is recorded as an expected failure and the flow
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
