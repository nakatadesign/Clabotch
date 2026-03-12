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
        XCTAssertNil(sut.doneAnimPupilFrame)
        XCTAssertEqual(sut.shakeYOffset, 0)
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

    // MARK: - DONE アニメーション（patch_011）

    func testDoneAnimationStartsWithCenterPupil() {
        // DONE に遷移した直後、アニメーション初期フレームは中央瞳（frame 08）
        sut.setPhaseAppearance(phase: .done(elapsedMs: 5000))
        XCTAssertEqual(sut.doneAnimPupilFrame, .f01_center)
    }

    func testDoneAnimationSequenceProgresses() {
        // アニメーションが進行して全ステップを通過することを確認
        sut.setPhaseAppearance(phase: .done(elapsedMs: 3000))

        let exp = expectation(description: "DONE アニメーション完了")
        let totalDuration = ClabotchEyeView.doneAnimInterval * Double(ClabotchEyeView.doneAnimSequence.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration + 0.1) {
            // 最終フレームは f02_rightDown（frame 12）で停止
            XCTAssertEqual(self.sut.doneAnimPupilFrame, .f02_rightDown)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    func testDoneAnimationSequenceDefinition() {
        // アニメーション順が §4 定義（08→09→12→13→14→13→12）に一致
        let expected: [GazeFrame] = [
            .f01_center, .f05_rightUp, .f02_rightDown,
            .f03_leftDown, .f04_leftUp, .f03_leftDown, .f02_rightDown,
        ]
        XCTAssertEqual(ClabotchEyeView.doneAnimSequence, expected)
    }

    func testDoneAnimationStopsOnPhaseChange() {
        // DONE アニメーション中に idle に遷移するとアニメーションが停止する
        sut.setPhaseAppearance(phase: .done(elapsedMs: 5000))
        XCTAssertNotNil(sut.doneAnimPupilFrame)

        sut.setPhaseAppearance(phase: .idle)
        XCTAssertNil(sut.doneAnimPupilFrame)
        XCTAssertEqual(sut.shakeYOffset, 0)
    }

    // MARK: - ERROR シェイクアニメーション（patch_011）

    func testErrorShakeStartsAtZeroOffset() {
        // ERROR に遷移した直後、Y オフセットは 0（frame 07 通常位置）
        sut.setPhaseAppearance(phase: .error(toolName: "Bash", message: nil))
        XCTAssertEqual(sut.shakeYOffset, 0)
    }

    func testErrorShakeSequenceProgresses() {
        // シェイクアニメーションが進行して元に戻ることを確認
        sut.setPhaseAppearance(phase: .error(toolName: "Bash", message: nil))

        let exp = expectation(description: "ERROR シェイク完了")
        let totalDuration = ClabotchEyeView.errorShakeInterval * Double(ClabotchEyeView.errorShakeSequence.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration + 0.1) {
            // シェイク完了後は Y オフセットが 0 に戻る
            XCTAssertEqual(self.sut.shakeYOffset, 0)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    func testErrorShakeSequenceDefinition() {
        // シェイク順が §4 定義（07→10→11→10→07）に一致
        let expected: [CGFloat] = [0, -1, 1, -1, 0]
        XCTAssertEqual(ClabotchEyeView.errorShakeSequence, expected)
    }

    func testErrorShakeFrame10MovesUpFrame11MovesDown() {
        // frame 10（shakeYOffset=-1）は画面上で上方向、
        // frame 11（shakeYOffset=+1）は画面上で下方向に描画されることを検証。
        // production の shakeOffsetToViewDY() を直接呼び出して変換結果を確認する。
        let dot: CGFloat = 1.0
        let frame10Offset = ClabotchEyeView.errorShakeSequence[1]  // -1
        let frame11Offset = ClabotchEyeView.errorShakeSequence[2]  // +1

        let dy10 = ClabotchEyeView.shakeOffsetToViewDY(logicalOffset: frame10Offset, dot: dot)
        let dy11 = ClabotchEyeView.shakeOffsetToViewDY(logicalOffset: frame11Offset, dot: dot)

        XCTAssertGreaterThan(dy10, 0, "frame 10 は AppKit 座標で上方向（正の dy）であるべき")
        XCTAssertLessThan(dy11, 0, "frame 11 は AppKit 座標で下方向（負の dy）であるべき")
    }

    func testErrorShakeStopsOnPhaseChange() {
        // ERROR シェイク中に thinking に遷移するとシェイクが停止する
        sut.setPhaseAppearance(phase: .error(toolName: "Bash", message: nil))

        sut.setPhaseAppearance(phase: .thinking)
        XCTAssertEqual(sut.shakeYOffset, 0)
        XCTAssertNil(sut.doneAnimPupilFrame)
    }

    // MARK: - アニメーション中の描画がクラッシュしない

    func testDrawDuringDoneAnimationDoesNotCrash() {
        sut.setPhaseAppearance(phase: .done(elapsedMs: 1000))
        // アニメーション各ステップで描画
        for _ in ClabotchEyeView.doneAnimSequence {
            // 内部状態をシミュレートして描画がクラッシュしないことを確認
            sut.display()
        }
    }

    func testDrawDuringErrorShakeDoesNotCrash() {
        sut.setPhaseAppearance(phase: .error(toolName: "Bash", message: nil))
        // シェイク中に描画
        sut.display()
    }

    // MARK: - ジャンプアニメーション（§5）

    func testJumpSequenceDefinition() {
        // §5 定義: ↑6px → ↑12px → ↑4px → 原点
        let expected: [CGFloat] = [6, 12, 4, 0]
        XCTAssertEqual(ClabotchEyeView.jumpSequence, expected)
    }

    func testPerformJumpSetsIsJumping() {
        sut.performJump()
        XCTAssertTrue(sut.isJumping)
    }

    func testJumpAppliesInitialOffset() {
        sut.performJump()
        // 初期位置は ↑6px
        XCTAssertEqual(sut.frame.origin.y, 6)
    }

    func testJumpCompletesAndResetsToOrigin() {
        sut.performJump()

        let exp = expectation(description: "ジャンプ完了")
        let totalDuration = ClabotchEyeView.jumpInterval * Double(ClabotchEyeView.jumpSequence.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration + 0.1) {
            XCTAssertEqual(self.sut.frame.origin.y, 0, "ジャンプ完了後は原点に戻るべき")
            XCTAssertFalse(self.sut.isJumping, "ジャンプ完了後は isJumping=false であるべき")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    func testJumpStopsOnPhaseChange() {
        sut.performJump()
        XCTAssertTrue(sut.isJumping)

        // phase 変更でジャンプが停止する
        sut.setPhaseAppearance(phase: .idle)
        XCTAssertFalse(sut.isJumping)
        XCTAssertEqual(sut.frame.origin.y, 0)
    }

    // MARK: - hitTest 透過

    func testHitTestReturnsNil() {
        // ClabotchEyeView はクリック透過 — NSStatusBarButton にイベントを委譲
        let result = sut.hitTest(NSPoint(x: 11, y: 7))
        XCTAssertNil(result)
    }
}
