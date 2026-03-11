@testable import Clabotch
import XCTest

final class ClabotchEyeViewTests: XCTestCase {

    private var sut: ClabotchEyeView!

    override func setUp() {
        super.setUp()
        sut = ClabotchEyeView(frame: NSRect(x: 0, y: 0, width: 22, height: 14))
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - 初期状態

    func testInitialState() {
        XCTAssertEqual(sut.gazeFrame, .f02_rightDown)
        XCTAssertFalse(sut.isBlinkClosed)
        XCTAssertFalse(sut.showErrorX)
        XCTAssertFalse(sut.showSurprise)
    }

    // MARK: - setGazeFrame

    func testSetGazeFrameUpdatesState() {
        sut.setGazeFrame(.f01_center)
        XCTAssertEqual(sut.gazeFrame, .f01_center)
    }

    func testSetGazeFrameSameFrameNoOp() {
        // 初期値は .f02_rightDown
        sut.needsDisplay = false
        sut.setGazeFrame(.f02_rightDown)
        // 同一 frame → needsDisplay は変わらない
        XCTAssertFalse(sut.needsDisplay)
    }

    // MARK: - triggerBlink

    func testTriggerBlinkSetsClosedState() {
        sut.triggerBlink()
        XCTAssertTrue(sut.isBlinkClosed)
    }

    func testBlinkAutoOpens() {
        sut.triggerBlink()
        XCTAssertTrue(sut.isBlinkClosed)

        let exp = expectation(description: "まばたき自動復帰")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertFalse(self.sut.isBlinkClosed)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - setPhaseAppearance

    func testSetPhaseAppearanceNormal() {
        sut.setPhaseAppearance(phase: .idle)
        XCTAssertEqual(sut.faceColor, ClabotchEyeView.Palette.faceNormal)
        XCTAssertFalse(sut.showErrorX)
        XCTAssertFalse(sut.showSurprise)
        XCTAssertFalse(sut.isBlinkClosed)
    }

    func testSetPhaseAppearanceError() {
        sut.setPhaseAppearance(phase: .error(toolName: "Bash", message: "failed"))
        XCTAssertEqual(sut.faceColor, ClabotchEyeView.Palette.faceError)
        XCTAssertTrue(sut.showErrorX)
        XCTAssertFalse(sut.showSurprise)
        XCTAssertFalse(sut.isBlinkClosed)
    }

    func testSetPhaseAppearanceDone() {
        sut.setPhaseAppearance(phase: .done(elapsedMs: 5000))
        XCTAssertEqual(sut.faceColor, ClabotchEyeView.Palette.faceDone)
        XCTAssertFalse(sut.showErrorX)
        XCTAssertTrue(sut.showSurprise)
        XCTAssertFalse(sut.isBlinkClosed)
    }

    func testSetPhaseAppearanceSleeping() {
        sut.setPhaseAppearance(phase: .sleeping)
        XCTAssertEqual(sut.faceColor, ClabotchEyeView.Palette.faceSleep)
        XCTAssertFalse(sut.showErrorX)
        XCTAssertFalse(sut.showSurprise)
        XCTAssertTrue(sut.isBlinkClosed)  // v11 §6: sleeping は frame06（常時閉じ目）
    }

    func testSleepingToIdleResetsBlinkClosed() {
        sut.setPhaseAppearance(phase: .sleeping)
        XCTAssertTrue(sut.isBlinkClosed)

        sut.setPhaseAppearance(phase: .idle)
        XCTAssertFalse(sut.isBlinkClosed)
    }

    // MARK: - sleeping が blink reopen タイマーを無効化する

    func testSleepingCancelsBlinkReopenTimer() {
        // blink を発火（150ms 後に reopen するタイマーが走る）
        sut.triggerBlink()
        XCTAssertTrue(sut.isBlinkClosed)

        // 即座に sleeping に遷移 → blinkTimer が無効化される
        sut.setPhaseAppearance(phase: .sleeping)
        XCTAssertTrue(sut.isBlinkClosed)

        // 150ms + α 後もまだ閉じたままであること（タイマーが無効化されていれば reopen しない）
        let exp = expectation(description: "sleeping 中は閉じ目維持")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertTrue(self.sut.isBlinkClosed, "sleeping 中に blink reopen が発火してはいけない")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - 描画テスト（draw() がクラッシュしないこと + 状態整合性）

    func testDrawDoesNotCrashForAllFrames() {
        // 全 GazeFrame で draw() がクラッシュしないことを確認
        let frames: [GazeFrame] = [.f01_center, .f02_rightDown, .f03_leftDown, .f04_leftUp, .f05_rightUp]
        for frame in frames {
            sut.setGazeFrame(frame)
            sut.display()  // NSView.display() → draw(_:) を強制呼び出し
        }
    }

    func testDrawDoesNotCrashForAllPhases() {
        // 全 phase の外見で draw() がクラッシュしないことを確認
        let phases: [MascotPhase] = [
            .idle, .thinking, .working(toolName: "Bash"),
            .done(elapsedMs: 1000), .error(toolName: "Bash", message: nil), .sleeping
        ]
        for phase in phases {
            sut.setPhaseAppearance(phase: phase)
            sut.display()
        }
    }

    func testDrawBlinkClosedDoesNotCrash() {
        sut.triggerBlink()
        XCTAssertTrue(sut.isBlinkClosed)
        sut.display()
    }

    // MARK: - frame 06/07/08 描画状態マッピング

    func testFrame06SleepingDrawsClosedEyes() {
        // frame06: sleeping → isBlinkClosed=true, 目ソケットなし、閉じ目横線
        sut.setPhaseAppearance(phase: .sleeping)
        XCTAssertTrue(sut.isBlinkClosed)
        XCTAssertFalse(sut.showErrorX)
        XCTAssertFalse(sut.showSurprise)
        sut.display()  // draw() が状態に基づいて正しい分岐に入ることを確認
    }

    func testFrame07ErrorDrawsXMarks() {
        // frame07: error → showErrorX=true, 目ソケット + × マーク
        sut.setPhaseAppearance(phase: .error(toolName: "Bash", message: nil))
        XCTAssertTrue(sut.showErrorX)
        XCTAssertFalse(sut.isBlinkClosed)
        XCTAssertFalse(sut.showSurprise)
        sut.display()
    }

    func testFrame08DoneDrawsSurprise() {
        // frame08: done → showSurprise=true, 目ソケット + 中央瞳
        sut.setPhaseAppearance(phase: .done(elapsedMs: 5000))
        XCTAssertTrue(sut.showSurprise)
        XCTAssertFalse(sut.isBlinkClosed)
        XCTAssertFalse(sut.showErrorX)
        sut.display()
    }

    // MARK: - hitTest 透過

    func testHitTestReturnsNil() {
        // ClabotchEyeView はクリック透過 — NSStatusBarButton にイベントを委譲
        let result = sut.hitTest(NSPoint(x: 11, y: 7))
        XCTAssertNil(result)
    }
}
