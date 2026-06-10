@testable import Clabotch
import XCTest

/// 実時間に依存せずタイマー発火を手動制御するための fake。
private final class FakeBlinkTimer: BlinkTimer {
    private(set) var invalidated = false
    func invalidate() { invalidated = true }
}

final class BlinkControllerTests: XCTestCase {

    func testSetBlinkingEnabledStartsTimer() {
        let sut = BlinkController(
            intervalRange: 0.05...0.1,
            randomSource: { 0.0 }  // 最短間隔
        )
        let exp = expectation(description: "onBlink が呼ばれる")
        sut.onBlink = {
            exp.fulfill()
        }

        sut.setBlinking(enabled: true)
        wait(for: [exp], timeout: 1.0)
        sut.setBlinking(enabled: false)
    }

    func testSetBlinkingDisabledStopsTimer() {
        let sut = BlinkController(
            intervalRange: 0.05...0.1,
            randomSource: { 0.0 }
        )
        var blinkCount = 0
        sut.onBlink = {
            blinkCount += 1
        }

        sut.setBlinking(enabled: true)
        // まばたきが1回発火するのを待つ
        let exp1 = expectation(description: "最初のまばたき")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 1.0)

        let countBeforeDisable = blinkCount
        sut.setBlinking(enabled: false)

        // 停止後は追加のまばたきが発生しないことを確認
        let exp2 = expectation(description: "追加まばたきなし")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(blinkCount, countBeforeDisable)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.0)
    }

    func testBlinkIntervalInRange() {
        // randomSource が 0.5 を返す → 間隔 = 0.1 + 0.5 * (0.2 - 0.1) = 0.15
        var scheduledIntervals: [TimeInterval] = []
        let sut = BlinkController(
            intervalRange: 0.1...0.2,
            randomSource: { 0.5 },
            scheduleTimer: { interval, _ in
                scheduledIntervals.append(interval)
                return FakeBlinkTimer()
            }
        )

        sut.setBlinking(enabled: true)
        sut.setBlinking(enabled: false)

        XCTAssertEqual(scheduledIntervals.count, 1)
        XCTAssertEqual(scheduledIntervals[0], 0.15, accuracy: 1e-9)
    }

    func testDeterministicRandomSource() {
        var callCount = 0
        var pendingHandlers: [() -> Void] = []
        let sut = BlinkController(
            intervalRange: 0.05...0.1,
            randomSource: {
                callCount += 1
                return 0.0  // 常に最短間隔
            },
            scheduleTimer: { _, handler in
                pendingHandlers.append(handler)
                return FakeBlinkTimer()
            }
        )
        var blinkCount = 0
        sut.onBlink = {
            blinkCount += 1
        }

        sut.setBlinking(enabled: true)
        // タイマー発火を手動で2回シミュレート（実時間に依存しない）
        pendingHandlers.removeFirst()()
        pendingHandlers.removeFirst()()
        sut.setBlinking(enabled: false)

        XCTAssertEqual(blinkCount, 2)
        // randomSource が scheduleNextBlink ごとに1回呼ばれている
        XCTAssertGreaterThanOrEqual(callCount, 2)
    }

    func testSetBlinkingIdempotent() {
        var timers: [FakeBlinkTimer] = []
        let sut = BlinkController(
            intervalRange: 0.05...0.1,
            randomSource: { 0.0 },
            scheduleTimer: { _, _ in
                let timer = FakeBlinkTimer()
                timers.append(timer)
                return timer
            }
        )

        sut.setBlinking(enabled: true)
        sut.setBlinking(enabled: true)  // リセット → 古いタイマーは破棄され、生きているのは1つだけ

        XCTAssertEqual(timers.count, 2)
        XCTAssertTrue(timers[0].invalidated)
        XCTAssertFalse(timers[1].invalidated)

        sut.setBlinking(enabled: false)
        XCTAssertTrue(timers[1].invalidated)
    }

    func testSetBlinkingDisabledIsBlinkingFalse() {
        let sut = BlinkController(
            intervalRange: 0.05...0.1,
            randomSource: { 0.0 }
        )
        sut.setBlinking(enabled: true)
        XCTAssertTrue(sut.isBlinking)

        sut.setBlinking(enabled: false)
        XCTAssertFalse(sut.isBlinking)
    }
}
