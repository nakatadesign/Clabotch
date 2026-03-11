import XCTest
@testable import Clabotch

// MARK: - StateMachineOwnershipTests（Ownership Guard、required 6）

@MainActor
final class StateMachineOwnershipTests: XCTestCase {

    // 1. session == nil で session_start → thinking に遷移
    func testSessionStartAcceptedWhenNoSession() {
        let sm = StateMachine()
        XCTAssertNil(sm.session)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        XCTAssertEqual(sm.displayPhase, .thinking)
        XCTAssertEqual(sm.session?.sessionID, "s1")
    }

    // 2. active session 中に同一 ID の session_start → no-op
    func testDuplicateSessionStartIsNoOp() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "s1"))
        XCTAssertEqual(sm.displayPhase, .thinking)

        // 同一 ID で再度 session_start → phase 変化なし
        sm.handle(event: .sessionStart(sessionID: "s1"))
        XCTAssertEqual(sm.displayPhase, .thinking)
        XCTAssertEqual(sm.session?.sessionID, "s1")
    }

    // 3. active session 中に別 ID の session_start → 無視
    func testForeignSessionStartIgnored() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "s1"))

        sm.handle(event: .sessionStart(sessionID: "s2"))
        XCTAssertEqual(sm.displayPhase, .thinking)
        XCTAssertEqual(sm.session?.sessionID, "s1")
    }

    // 4. active session 中に別 session_id の tool_start → 無視
    func testForeignToolStartIgnored() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "s1"))

        sm.handle(event: .toolStart(sessionID: "s2", toolName: "Read"))
        XCTAssertEqual(sm.displayPhase, .thinking)
    }

    // 5. active session 中に別 session_id の tool_end → 無視
    func testForeignToolEndIgnored() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "s1"))

        sm.handle(event: .toolEnd(sessionID: "s2", toolName: "Bash",
                                   durationMs: 100, isError: false, errorMessage: nil))
        XCTAssertEqual(sm.displayPhase, .thinking)
    }

    // 6. active session 中に別 session_id の session_done(ms==0) → 無視、ephemeral なし
    func testForeignSessionDoneIgnored() {
        let sm = StateMachine()
        var ephemeralCount = 0
        sm.onEphemeralDone = { _ in ephemeralCount += 1 }

        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s2", elapsedMs: 0))

        XCTAssertEqual(sm.displayPhase, .thinking)
        XCTAssertNotNil(sm.session)
        XCTAssertEqual(ephemeralCount, 0)
    }
}

// MARK: - StateMachinePhaseTests（Phase 遷移、required 8）

@MainActor
final class StateMachinePhaseTests: XCTestCase {

    // 7. session_start → thinking + session 設定
    func testSessionStartSetsThinking() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "s1"))
        XCTAssertEqual(sm.displayPhase, .thinking)
        XCTAssertNotNil(sm.session)
        XCTAssertEqual(sm.session?.phase, .thinking)
    }

    // 8. thinking → tool_start → working
    func testToolStartSetsWorking() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Read"))
        XCTAssertEqual(sm.displayPhase, .working(toolName: "Read"))
        XCTAssertEqual(sm.session?.phase, .working(toolName: "Read"))
    }

    // 9. working → tool_end(success) → thinking
    func testToolEndSuccessSetsThinking() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Read"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Read",
                                   durationMs: 50, isError: false, errorMessage: nil))
        XCTAssertEqual(sm.displayPhase, .thinking)
    }

    // 10. working → tool_end(error) → error
    func testToolEndErrorSetsError() {
        let sm = StateMachine(errorAutoTransitionDelay: 10)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Bash"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash",
                                   durationMs: 200, isError: true, errorMessage: "失敗"))
        XCTAssertEqual(sm.displayPhase, .error(toolName: "Bash", message: "失敗"))
    }

    // 11. thinking → session_done → done + session == nil
    func testSessionDoneSetsDone() {
        let sm = StateMachine(doneAutoTransitionDelay: 10)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 3000))
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 3000))
        XCTAssertNil(sm.session)
    }

    // 12. error → errorAutoTransitionDelay 後 → thinking
    func testErrorAutoTransitionToThinking() {
        let sm = StateMachine(errorAutoTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash",
                                   durationMs: 100, isError: true, errorMessage: nil))
        XCTAssertEqual(sm.displayPhase, .error(toolName: "Bash", message: nil))

        let exp = expectation(description: "auto-transition to thinking")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.displayPhase, .thinking)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // 13. done → doneAutoTransitionDelay 後 → idle
    func testDoneAutoTransitionToIdle() {
        let sm = StateMachine(doneAutoTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 1000))
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 1000))

        let exp = expectation(description: "auto-transition to idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.displayPhase, .idle)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // 14. unknown イベント → phase 変化なし
    func testUnknownEventIsNoOp() {
        let sm = StateMachine()
        sm.handle(event: .unknown(rawJSON: "{}"))
        XCTAssertEqual(sm.displayPhase, .idle)
        XCTAssertNil(sm.session)
    }
}

// MARK: - StateMachineRaceTests（Delayed Transition レース対策、required 4）

@MainActor
final class StateMachineRaceTests: XCTestCase {

    // 15. error 中に新しい tool_start → pending auto-transition が発火しない
    func testNewEventCancelsPendingTransition() {
        let sm = StateMachine(errorAutoTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash",
                                   durationMs: 100, isError: true, errorMessage: nil))
        XCTAssertEqual(sm.displayPhase, .error(toolName: "Bash", message: nil))

        // error auto-transition が発火する前に tool_start で working に遷移
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Read"))
        XCTAssertEqual(sm.displayPhase, .working(toolName: "Read"))

        // 0.1秒後: auto-transition は cancel されているので thinking にならない
        let exp = expectation(description: "auto-transition cancelled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.displayPhase, .working(toolName: "Read"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // 16. done 中に新しい session_start → done auto-transition が発火しない
    func testEpochInvalidatesStaleTransition() {
        let sm = StateMachine(doneAutoTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 500))
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 500))

        // done auto-transition が発火する前に新 session_start
        sm.handle(event: .sessionStart(sessionID: "s2"))
        XCTAssertEqual(sm.displayPhase, .thinking)

        // 0.1秒後: auto-transition は epoch 不一致で無効
        let exp = expectation(description: "stale transition invalidated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.displayPhase, .thinking)
            XCTAssertEqual(sm.session?.sessionID, "s2")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // 17. error → session_done → error auto-transition 無効、done auto-transition のみ発火
    func testSessionDoneCancelsPendingErrorTransition() {
        let sm = StateMachine(errorAutoTransitionDelay: 0.15, doneAutoTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash",
                                   durationMs: 100, isError: true, errorMessage: nil))
        XCTAssertEqual(sm.displayPhase, .error(toolName: "Bash", message: nil))

        // session_done で error auto-transition をキャンセルし、done を設定
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 200))
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 200))

        // done auto-transition（0.1秒）のみ発火
        let exp = expectation(description: "done auto-transition only")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertEqual(sm.displayPhase, .idle)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // 18. error auto-transition の expectedSessionID が不一致 → no-op
    func testPendingTransitionSessionIDMismatch() {
        let sm = StateMachine(errorAutoTransitionDelay: 0.1, doneAutoTransitionDelay: 10)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Bash",
                                   durationMs: 100, isError: true, errorMessage: nil))
        // error auto-transition は expectedSessionID="s1"

        // session_done → done → 新 session_start
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 0))
        sm.handle(event: .sessionStart(sessionID: "s2"))
        XCTAssertEqual(sm.displayPhase, .thinking)
        XCTAssertEqual(sm.session?.sessionID, "s2")

        // 旧 error auto-transition: epoch 不一致 + sessionID 不一致 → no-op
        let exp = expectation(description: "sessionID mismatch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.displayPhase, .thinking)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}

// MARK: - StateMachineSleepTests（Sleeping、required 4）

@MainActor
final class StateMachineSleepTests: XCTestCase {

    // 19. idle + session==nil → sleepThreshold 後 → sleeping
    func testSleepingFiresAfterThreshold() {
        let sm = StateMachine(sleepThreshold: 0.15)
        sm.start()
        XCTAssertEqual(sm.displayPhase, .idle)

        let exp = expectation(description: "sleeping")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(sm.displayPhase, .sleeping)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // 20. session 存在時は sleep タイマーが始動しない
    func testSleepingNotFiresWithActiveSession() {
        let sm = StateMachine(sleepThreshold: 0.1, doneAutoTransitionDelay: 10)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        // session 存在で thinking → sleep タイマーは始動しない
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 0))
        // done に遷移（doneAutoTransitionDelay=10 なので idle にはならない）
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 0))

        let exp = expectation(description: "not sleeping")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // done のまま（idle ではないので sleep タイマー未始動）
            XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 0))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    // 21. sleeping 中に session_start → thinking に遷移
    func testSleepingCancelledBySessionStart() {
        let sm = StateMachine(sleepThreshold: 0.1)
        sm.start()

        let sleepExp = expectation(description: "sleeping")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(sm.displayPhase, .sleeping)
            sleepExp.fulfill()
        }
        wait(for: [sleepExp], timeout: 1)

        sm.handle(event: .sessionStart(sessionID: "s1"))
        XCTAssertEqual(sm.displayPhase, .thinking)
    }

    // 22. done → idle auto-transition → sleep タイマー再始動
    func testSleepTimerRestartsOnReturnToIdle() {
        let sm = StateMachine(sleepThreshold: 0.15, doneAutoTransitionDelay: 0.1)
        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 100))
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 100))

        // done → idle (0.1秒) → sleeping (0.15秒)
        let exp = expectation(description: "sleep after idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            XCTAssertEqual(sm.displayPhase, .sleeping)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}

// MARK: - StateMachineEphemeralTests（Ephemeral 通知、required 3）

@MainActor
final class StateMachineEphemeralTests: XCTestCase {

    // 23. foreign session_done(ms > 0) → onEphemeralDone コールバック
    func testForeignSessionDoneEphemeral() {
        let sm = StateMachine()
        var receivedMs: Int?
        sm.onEphemeralDone = { ms in receivedMs = ms }

        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s2", elapsedMs: 5000))

        XCTAssertEqual(receivedMs, 5000)
        // active session は変化なし
        XCTAssertEqual(sm.displayPhase, .thinking)
        XCTAssertEqual(sm.session?.sessionID, "s1")
    }

    // 24. foreign session_done(ms == 0) → silent drop
    func testForeignSessionDoneZeroMsSilentDrop() {
        let sm = StateMachine()
        var ephemeralCount = 0
        sm.onEphemeralDone = { _ in ephemeralCount += 1 }

        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s2", elapsedMs: 0))

        XCTAssertEqual(ephemeralCount, 0)
    }

    // 25. active session_done → onEphemeralDone 呼ばれない
    func testActiveSessionDoneNoEphemeral() {
        let sm = StateMachine(doneAutoTransitionDelay: 10)
        var ephemeralCount = 0
        sm.onEphemeralDone = { _ in ephemeralCount += 1 }

        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .sessionDone(sessionID: "s1", elapsedMs: 3000))

        XCTAssertEqual(ephemeralCount, 0)
        XCTAssertEqual(sm.displayPhase, .done(elapsedMs: 3000))
    }
}

// MARK: - StateMachineCallbackTests（onPhaseChanged コールバック、required 2）

@MainActor
final class StateMachineCallbackTests: XCTestCase {

    // 26. 遷移時に onPhaseChanged が正しい phase で呼ばれる
    func testOnPhaseChangedCalledOnTransition() {
        let sm = StateMachine()
        var phases: [MascotPhase] = []
        sm.onPhaseChanged = { phase in phases.append(phase) }

        sm.handle(event: .sessionStart(sessionID: "s1"))
        sm.handle(event: .toolStart(sessionID: "s1", toolName: "Read"))

        XCTAssertEqual(phases, [.thinking, .working(toolName: "Read")])
    }

    // 27. start() で onPhaseChanged が .idle で呼ばれる
    func testStartEmitsInitialPhase() {
        let sm = StateMachine(sleepThreshold: 10)
        var phases: [MascotPhase] = []
        sm.onPhaseChanged = { phase in phases.append(phase) }
        sm.start()
        XCTAssertEqual(phases, [.idle])
    }

    // 28. 同一 phase への遷移 → onPhaseChanged 呼ばれない
    func testOnPhaseChangedNotCalledForSamePhase() {
        let sm = StateMachine()
        sm.handle(event: .sessionStart(sessionID: "s1"))

        var callCount = 0
        sm.onPhaseChanged = { _ in callCount += 1 }

        // thinking → tool_end(success) → thinking: 同じ phase なので呼ばれない
        sm.handle(event: .toolEnd(sessionID: "s1", toolName: "Read",
                                   durationMs: 50, isError: false, errorMessage: nil))

        XCTAssertEqual(callCount, 0)
    }
}
