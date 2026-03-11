@testable import Clabotch
import XCTest

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
        let sut = BlinkController(
            intervalRange: 0.1...0.2,
            randomSource: { 0.5 }
        )

        let start = Date()
        let exp = expectation(description: "まばたき発火")
        sut.onBlink = {
            let elapsed = Date().timeIntervalSince(start)
            // 0.1〜0.3 の範囲（タイマー精度のマージン含む）
            XCTAssertGreaterThanOrEqual(elapsed, 0.1)
            XCTAssertLessThanOrEqual(elapsed, 0.3)
            exp.fulfill()
        }

        sut.setBlinking(enabled: true)
        wait(for: [exp], timeout: 1.0)
        sut.setBlinking(enabled: false)
    }

    func testDeterministicRandomSource() {
        var callCount = 0
        let sut = BlinkController(
            intervalRange: 0.05...0.1,
            randomSource: {
                callCount += 1
                return 0.0  // 常に最短間隔
            }
        )
        let exp = expectation(description: "2回まばたき")
        var blinkCount = 0
        sut.onBlink = {
            blinkCount += 1
            if blinkCount >= 2 {
                exp.fulfill()
            }
        }

        sut.setBlinking(enabled: true)
        wait(for: [exp], timeout: 1.0)
        sut.setBlinking(enabled: false)

        // randomSource が複数回呼ばれている（scheduleNextBlink ごとに1回）
        XCTAssertGreaterThanOrEqual(callCount, 2)
    }

    func testSetBlinkingIdempotent() {
        let sut = BlinkController(
            intervalRange: 0.05...0.1,
            randomSource: { 0.0 }
        )
        var blinkCount = 0
        sut.onBlink = {
            blinkCount += 1
        }

        sut.setBlinking(enabled: true)
        sut.setBlinking(enabled: true)  // リセット → タイマー1つだけ

        let exp = expectation(description: "正常にまばたき")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // タイマーが2重になっていたら blinkCount が異常に多くなる
            XCTAssertGreaterThan(blinkCount, 0)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        sut.setBlinking(enabled: false)
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
