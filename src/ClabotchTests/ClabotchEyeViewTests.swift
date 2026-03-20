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
        XCTAssertEqual(sut.gazeFrame, .f03_leftDown)
        XCTAssertEqual(sut.blinkStage, .open)
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
        // 初期値は .f03_leftDown
        sut.needsDisplay = false
        sut.setGazeFrame(.f03_leftDown)
        // 同一 frame → needsDisplay は変わらない
        XCTAssertFalse(sut.needsDisplay)
    }

    // MARK: - triggerBlink

    func testTriggerBlinkSetsClosedStage() {
        sut.triggerBlink()
        XCTAssertEqual(sut.blinkStage, .closed)
        XCTAssertTrue(sut.isBlinkClosed)
    }

    func testBlinkAutoOpens() {
        // patch_012: 全シーケンス 330ms（half60+almost60+closed90+almost60+half60）
        sut.triggerBlink()
        XCTAssertTrue(sut.isBlinkClosed)

        let exp = expectation(description: "まばたき自動復帰")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(self.sut.blinkStage, .open)
            XCTAssertFalse(self.sut.isBlinkClosed)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.5)
    }

    // MARK: - まばたきシーケンス（patch_012）

    func testBlinkSequenceDefinition() {
        // 白目維持 + 黒目横線で瞬き: closed(120ms) のみ
        let seq = ClabotchEyeView.blinkSequence
        XCTAssertEqual(seq.count, 1)
        XCTAssertEqual(seq[0].stage, .closed)
        XCTAssertEqual(seq[0].duration, 0.12, accuracy: 0.001)
    }

    func testBlinkTotalDuration120ms() {
        let total = ClabotchEyeView.blinkSequence.reduce(0.0) { $0 + $1.duration }
        XCTAssertEqual(total, 0.12, accuracy: 0.001)
    }

    func testBlinkIgnoredWhileAlreadyBlinking() {
        sut.triggerBlink()
        XCTAssertEqual(sut.blinkStage, .closed)

        // closed 中に再発火 → 無視されるべき
        sut.triggerBlink()
        XCTAssertEqual(sut.blinkStage, .closed, "まばたき中の再発火は無視されるべき")

        // 120ms + α で open に戻る
        let exp = expectation(description: "再発火が無視されて元のタイミングで open に戻る")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(self.sut.blinkStage, .open)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testBlinkStageAllCases() {
        // BlinkStage の全ケースが定義されている
        let cases = ClabotchEyeView.BlinkStage.allCases
        XCTAssertEqual(cases.count, 4)
        XCTAssertTrue(cases.contains(.open))
        XCTAssertTrue(cases.contains(.half))
        XCTAssertTrue(cases.contains(.almost))
        XCTAssertTrue(cases.contains(.closed))
    }

    // MARK: - setPhaseAppearance

    func testSetPhaseAppearanceNormal() {
        sut.setPhaseAppearance(phase: .idle)
        XCTAssertEqual(sut.faceColor, ClabotchEyeView.Palette.faceNormal)
        XCTAssertFalse(sut.showErrorX)
        XCTAssertFalse(sut.showSurprise)
        XCTAssertFalse(sut.isBlinkClosed)
    }

    func testSetPhaseAppearanceWorking() {
        sut.setPhaseAppearance(phase: .working(toolName: "Bash"))
        XCTAssertEqual(sut.faceColor, ClabotchEyeView.Palette.faceNormal, "working は通常色（patch_020）")
        XCTAssertFalse(sut.showErrorX)
        XCTAssertFalse(sut.showSurprise)
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
        XCTAssertTrue(sut.showSleepingEyes)  // ^_^ 逆V字閉じ目
        XCTAssertEqual(sut.blinkStage, .open)  // blinkStage は open（sleeping 専用描画を使用）
    }

    func testSleepingToIdleResetsSleepingEyes() {
        sut.setPhaseAppearance(phase: .sleeping)
        XCTAssertTrue(sut.showSleepingEyes)

        sut.setPhaseAppearance(phase: .idle)
        XCTAssertFalse(sut.showSleepingEyes)
        XCTAssertEqual(sut.blinkStage, .open)
    }

    // MARK: - sleeping が blink reopen タイマーを無効化する

    func testSleepingCancelsBlinkReopenTimer() {
        // blink を発火（330ms のシーケンスが走る）
        sut.triggerBlink()
        XCTAssertTrue(sut.isBlinkClosed)

        // 即座に sleeping に遷移 → blinkTimer が無効化、showSleepingEyes で描画
        sut.setPhaseAppearance(phase: .sleeping)
        XCTAssertTrue(sut.showSleepingEyes)

        // 500ms 後も sleeping 目のままであること
        let exp = expectation(description: "sleeping 中は sleeping 目維持")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertTrue(self.sut.showSleepingEyes, "sleeping 中に blink reopen が発火してはいけない")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.5)
    }

    // MARK: - 描画テスト（draw() がクラッシュしないこと + 状態整合性）

    func testDrawDoesNotCrashForAllFrames() {
        // 全 GazeFrame で draw() がクラッシュしないことを確認
        let frames: [GazeFrame] = [.f01_center, .f02_rightDown, .f03_leftDown, .f04_leftUp, .f05_rightUp, .f06_right, .f07_left]
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

    func testDrawAllBlinkStagesDoesNotCrash() {
        // 全 BlinkStage で描画がクラッシュしないことを確認
        // closed（triggerBlink 直後）
        sut.triggerBlink()
        XCTAssertEqual(sut.blinkStage, .closed)
        sut.display()

        // sleeping → showSleepingEyes（専用描画）
        sut.setPhaseAppearance(phase: .sleeping)
        XCTAssertTrue(sut.showSleepingEyes)
        sut.display()

        // idle → open
        sut.setPhaseAppearance(phase: .idle)
        XCTAssertEqual(sut.blinkStage, .open)
        sut.display()
    }

    // MARK: - frame 06/07/08 描画状態マッピング

    func testFrame06SleepingDrawsSleepingEyes() {
        // sleeping → showSleepingEyes=true, ^_^ 逆V字閉じ目
        sut.setPhaseAppearance(phase: .sleeping)
        XCTAssertTrue(sut.showSleepingEyes)
        XCTAssertFalse(sut.showErrorX)
        XCTAssertFalse(sut.showSurprise)
        sut.display()
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

    func testDoneAnimationStartsWithLeftDown() {
        // DONE に遷移した直後、アニメーション初期フレームは左下
        sut.setPhaseAppearance(phase: .done(elapsedMs: 5000))
        XCTAssertEqual(sut.doneAnimPupilFrame, .f03_leftDown)
    }

    func testDoneAnimationSequenceProgresses() {
        // アニメーションが進行して完了後にハッピー目に切り替わることを確認
        sut.doneAnimInterval = 0.02
        sut.setPhaseAppearance(phase: .done(elapsedMs: 3000))

        let exp = expectation(description: "DONE アニメーション完了 → ハッピー目")
        let totalDuration = sut.doneAnimInterval * Double(ClabotchEyeView.doneAnimSequence.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration + 0.1) {
            // スピン完了後は doneAnimPupilFrame=nil, showHappyEyes=true
            XCTAssertNil(self.sut.doneAnimPupilFrame)
            XCTAssertTrue(self.sut.showHappyEyes)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3.0)
    }

    func testDoneAnimationSequenceDefinition() {
        // 左下起点 → 時計回り2周 → 左下停止
        let seq = ClabotchEyeView.doneAnimSequence
        XCTAssertEqual(seq.count, 9)
        XCTAssertEqual(seq.first, .f03_leftDown)
        XCTAssertEqual(seq.last, .f03_leftDown)
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
        sut.errorShakeInterval = 0.02
        sut.setPhaseAppearance(phase: .error(toolName: "Bash", message: nil))

        let exp = expectation(description: "ERROR シェイク完了")
        let totalDuration = sut.errorShakeInterval * Double(ClabotchEyeView.errorShakeSequence.count)
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
        // ERROR シェイク中に idle に遷移するとシェイクが停止する
        sut.setPhaseAppearance(phase: .error(toolName: "Bash", message: nil))

        sut.setPhaseAppearance(phase: .idle)
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
        // 2回ジャンプ: 1回目 ↑6→↑12→↑4→原点、2回目 ↑4→↑8→↑2→原点
        let expected: [CGFloat] = [6, 12, 4, 0, 4, 8, 2, 0]
        XCTAssertEqual(ClabotchEyeView.jumpSequence, expected)
    }

    func testPerformJumpSetsIsJumping() {
        sut.performJump()
        XCTAssertTrue(sut.isJumping)
    }

    func testJumpAppliesInitialOffset() {
        sut.performJump()
        // 初期位置は ↑6px（image ベースでは jumpYOffset で管理）
        XCTAssertEqual(sut.jumpYOffset, 6)
    }

    func testJumpCompletesAndResetsToOrigin() {
        sut.jumpInterval = 0.02
        sut.performJump()

        let exp = expectation(description: "ジャンプ完了")
        let totalDuration = sut.jumpInterval * Double(ClabotchEyeView.jumpSequence.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration + 0.1) {
            XCTAssertEqual(self.sut.jumpYOffset, 0, "ジャンプ完了後は原点に戻るべき")
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
        XCTAssertEqual(sut.jumpYOffset, 0)
    }

    // MARK: - 虹色アニメーション（DONE）

    func testDoneStartsRainbowGradient() {
        sut.setPhaseAppearance(phase: .done(elapsedMs: 5000))
        XCTAssertTrue(sut.isRainbowActive, "done で虹グラデーションが有効になるべき")
    }

    func testRainbowStopsOnPhaseChange() {
        sut.setPhaseAppearance(phase: .done(elapsedMs: 5000))
        XCTAssertTrue(sut.isRainbowActive)

        sut.setPhaseAppearance(phase: .idle)
        XCTAssertFalse(sut.isRainbowActive, "idle に戻ると虹が停止するべき")
    }

    func testRainbowHueAdvances() {
        sut.setPhaseAppearance(phase: .done(elapsedMs: 5000))

        let exp = expectation(description: "rainbowHue が進行する")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertGreaterThan(self.sut.rainbowHue, 0, "色相が進行しているべき")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testNonDonePhasesDoNotHaveRainbow() {
        let phases: [MascotPhase] = [
            .idle, .thinking, .working(toolName: "Bash"),
            .error(toolName: "Bash", message: nil), .sleeping
        ]
        for phase in phases {
            sut.setPhaseAppearance(phase: phase)
            XCTAssertFalse(sut.isRainbowActive,
                "\(phase.debugName) では虹グラデーションが発動しないべき")
        }
    }

    func testDrawDuringRainbowDoesNotCrash() {
        // 虹アニメーション中の描画がクラッシュしない
        sut.setPhaseAppearance(phase: .done(elapsedMs: 5000))
        let exp = expectation(description: "虹色描画")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.sut.display()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - THINKING 表情（patch_020: 静止表情）

    func testThinkingIsStaticNoAnimation() {
        // patch_020: thinking は静止表情（専用アニメなし）
        sut.setPhaseAppearance(phase: .thinking)
        XCTAssertNil(sut.thinkingAnimFrame, "thinking はアニメーションなし（静止表情）")
    }

    func testThinkingIsStaticExpression() {
        // thinking は静止表情（patch_020: 専用アニメを responding へ移管）
        sut.setPhaseAppearance(phase: .thinking)
        XCTAssertNil(sut.thinkingAnimFrame, "thinking はアニメーションなし")
        XCTAssertEqual(sut.pupilColor, ClabotchEyeView.Palette.pupil,
                       "thinking は通常色の瞳")
        XCTAssertEqual(sut.faceColor, ClabotchEyeView.Palette.faceNormal,
                       "thinking は通常顔色")
    }

    func testRespondingHasBluePupilAndAnimation() {
        // responding は青瞳 + 右上⇔左上 + 上下揺れ（patch_020: 旧 thinking 表情を引き継ぎ）
        sut.respondingAnimInterval = 0.05  // テスト高速化
        sut.setPhaseAppearance(phase: .responding)

        // 初期ステップ: 右上 + yOffset=-1（1dot 上）
        XCTAssertEqual(sut.respondingAnimFrame, .f05_rightUp)
        XCTAssertEqual(sut.shakeYOffset, -1, accuracy: 0.01,
                       "初期ステップは 1dot 上")
        XCTAssertEqual(sut.pupilColor, ClabotchEyeView.Palette.thinkingDot,
                       "responding は青系瞳")

        // 2番目のステップを待つ: 左上 + yOffset=0
        let exp = expectation(description: "2番目のステップ")
        let checkTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            if self.sut.respondingAnimFrame == .f04_leftUp {
                XCTAssertEqual(self.sut.shakeYOffset, 0, accuracy: 0.01,
                               "2番目のステップは原点")
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
        checkTimer.invalidate()
    }

    func testThinkingToIdleKeepsStaticExpression() {
        // patch_020: thinking は静止表情なのでアニメーション停止の概念がない
        sut.setPhaseAppearance(phase: .thinking)
        XCTAssertNil(sut.thinkingAnimFrame, "thinking は静止表情")

        sut.setPhaseAppearance(phase: .idle)
        XCTAssertNil(sut.thinkingAnimFrame, "idle でも thinking アニメーションなし")
    }

    func testThinkingAnimationSequenceDefinition() {
        let seq = ClabotchEyeView.thinkingAnimSequence
        XCTAssertEqual(seq.count, 2)
        XCTAssertEqual(seq[0].frame, .f05_rightUp)
        XCTAssertEqual(seq[1].frame, .f04_leftUp)
    }

    func testNonThinkingPhasesDoNotHaveThinkingAnim() {
        let phases: [MascotPhase] = [
            .idle, .responding, .working(toolName: "Bash"),
            .done(elapsedMs: 1000), .error(toolName: "Bash", message: nil), .sleeping
        ]
        for phase in phases {
            sut.setPhaseAppearance(phase: phase)
            XCTAssertNil(sut.thinkingAnimFrame,
                         "\(phase.debugName) では thinking アニメーションが発動しないべき")
        }
    }

    func testDrawDuringThinkingAnimDoesNotCrash() {
        sut.thinkingAnimInterval = 0.1
        sut.setPhaseAppearance(phase: .thinking)
        sut.display()
        let exp = expectation(description: "thinking アニメ中の描画")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.sut.display()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - hitTest 透過

    // MARK: - RESPONDING フェーズ

    func testRespondingStartsAnimation() {
        // patch_020: responding は右上⇔左上 + 上下揺れ（旧 thinking 表情）
        sut.setPhaseAppearance(phase: .responding)
        XCTAssertNotNil(sut.respondingAnimFrame, "responding ではアニメーションが開始されるべき")
        XCTAssertEqual(sut.respondingAnimFrame, .f05_rightUp, "初期フレームは右上")
    }

    func testRespondingAnimationAlternatesGaze() {
        sut.respondingAnimInterval = 0.05
        sut.setPhaseAppearance(phase: .responding)
        XCTAssertEqual(sut.respondingAnimFrame, .f05_rightUp, "初期は右上")

        let exp = expectation(description: "responding 視線が左上に遷移")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            if self.sut.respondingAnimFrame == .f04_leftUp {
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
        timer.invalidate()
    }

    func testRespondingAnimationStopsOnPhaseChange() {
        sut.setPhaseAppearance(phase: .responding)
        XCTAssertNotNil(sut.respondingAnimFrame)

        sut.setPhaseAppearance(phase: .idle)
        XCTAssertNil(sut.respondingAnimFrame, "idle に遷移すると responding アニメーションが停止するべき")
    }

    func testRespondingSetsNormalFaceAndNoFlags() {
        sut.setPhaseAppearance(phase: .responding)
        XCTAssertEqual(sut.faceColor, ClabotchEyeView.Palette.faceNormal)
        XCTAssertFalse(sut.showErrorX)
        XCTAssertFalse(sut.showSurprise)
        XCTAssertFalse(sut.showSleepingEyes)
        XCTAssertFalse(sut.showHappyEyes)
    }

    func testRespondingSequenceDefinition() {
        // patch_020: 旧 thinking 表情を引き継ぎ（右上⇔左上 + yOffset）
        let seq = ClabotchEyeView.respondingAnimSequence
        XCTAssertEqual(seq.count, 2)
        XCTAssertEqual(seq[0].frame, .f05_rightUp)
        XCTAssertEqual(seq[0].yOffset, -1, accuracy: 0.01)
        XCTAssertEqual(seq[1].frame, .f04_leftUp)
        XCTAssertEqual(seq[1].yOffset, 0, accuracy: 0.01)
    }

    func testRespondingIntervalMatchesThinking() {
        // patch_020: responding は旧 thinking と同じ間隔（0.8秒）
        XCTAssertEqual(sut.respondingAnimInterval, sut.thinkingAnimInterval,
                       "responding は thinking と同じ間隔であるべき")
    }

    func testNonRespondingPhasesDoNotHaveRespondingAnim() {
        let phases: [MascotPhase] = [
            .idle, .thinking, .working(toolName: "Bash"),
            .done(elapsedMs: 1000), .error(toolName: "Bash", message: nil), .sleeping
        ]
        for phase in phases {
            sut.setPhaseAppearance(phase: phase)
            XCTAssertNil(sut.respondingAnimFrame,
                         "\(phase.debugName) では responding アニメーションが発動しないべき")
        }
    }

    func testDrawDuringRespondingDoesNotCrash() {
        sut.setPhaseAppearance(phase: .responding)
        sut.display()
    }

    // MARK: - アニメーション速度変更即時反映

    func testRespondingReapplyUsesNewInterval() {
        // responding を開始（デフォルト 0.8秒）
        sut.setPhaseAppearance(phase: .responding)
        XCTAssertNotNil(sut.respondingAnimFrame)

        // interval を変更して再適用
        sut.respondingAnimInterval = 0.1
        sut.setPhaseAppearance(phase: .responding)

        // 新 interval でアニメーション再起動 → 短い待機で遷移確認
        let exp = expectation(description: "responding re-applied with new interval")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if self.sut.respondingAnimFrame == .f04_leftUp {
                timer.invalidate()
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
        timer.invalidate()
    }

    // 旧 responding reapply テスト（patch_020 で統合済み）は上のメソッドに統合

    func testReapplyNonAnimatingPhaseIsNoOp() {
        // idle に設定 → setPhaseAppearance を2回呼んでもクラッシュしない
        sut.setPhaseAppearance(phase: .idle)
        sut.setPhaseAppearance(phase: .idle)
        XCTAssertNil(sut.thinkingAnimFrame)
        XCTAssertNil(sut.respondingAnimFrame)
    }

    // MARK: - hitTest 透過

    func testHitTestReturnsNil() {
        // ClabotchEyeView はクリック透過 — NSStatusBarButton にイベントを委譲
        let result = sut.hitTest(NSPoint(x: 11, y: 7))
        XCTAssertNil(result)
    }

    // MARK: - button.image 生成経路（patch_018）

    func testUpdateStatusImageWithoutButton() {
        // statusBarButton が nil のとき updateStatusImage は何もしない（クラッシュしない）
        XCTAssertNil(sut.statusBarButton)
        sut.updateStatusImage()
    }

    func testUpdateStatusImageGeneratesImage() throws {
        let statusItem = NSStatusBar.system.statusItem(withLength: 22)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let button = try XCTUnwrap(statusItem.button, "NSStatusItem.button が取得できない")

        sut.statusBarButton = button
        sut.updateStatusImage()

        XCTAssertNotNil(button.image, "updateStatusImage 後に button.image が設定されるべき")
    }

    func testScheduleUpdateSetsImage() throws {
        let statusItem = NSStatusBar.system.statusItem(withLength: 22)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let button = try XCTUnwrap(statusItem.button)

        sut.statusBarButton = button
        sut.scheduleUpdate()

        XCTAssertNotNil(button.image, "scheduleUpdate 後に button.image が設定されるべき")
    }

    func testSetPhaseAppearanceUpdatesImage() throws {
        let statusItem = NSStatusBar.system.statusItem(withLength: 22)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let button = try XCTUnwrap(statusItem.button)

        sut.statusBarButton = button
        sut.setPhaseAppearance(phase: .thinking)

        XCTAssertNotNil(button.image, "phase 変更後に button.image が更新されるべき")
    }

    func testPerformJumpUpdatesImage() throws {
        let statusItem = NSStatusBar.system.statusItem(withLength: 22)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let button = try XCTUnwrap(statusItem.button)

        sut.statusBarButton = button
        sut.performJump()

        XCTAssertEqual(sut.jumpYOffset, 6, "初期ジャンプオフセットが設定されるべき")
        XCTAssertNotNil(button.image, "jump 開始後に button.image が更新されるべき")
    }

    func testViewDidMoveToWindowTriggersImageUpdate() throws {
        let statusItem = NSStatusBar.system.statusItem(withLength: 22)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let button = try XCTUnwrap(statusItem.button)

        sut.statusBarButton = button
        button.addSubview(sut)

        // viewDidMoveToWindow → scheduleUpdate → updateStatusImage
        XCTAssertNotNil(button.image, "window 接続時に button.image が生成されるべき")

        sut.removeFromSuperview()
    }

    /// AppDelegate.setupEyeView(on:) を直接呼び、本番初期化順で button.image が生成されることを検証。
    /// 初期化順の変更や scheduleUpdate() 脱落を検知する。
    func testSetupEyeViewGeneratesImage() throws {
        let statusItem = NSStatusBar.system.statusItem(withLength: 22)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let button = try XCTUnwrap(statusItem.button)

        XCTAssertNil(button.image, "setupEyeView 前は image が nil")

        let view = AppDelegate.setupEyeView(on: button)

        XCTAssertNotNil(button.image, "setupEyeView 後に button.image が生成されるべき")
        XCTAssertNotNil(view.statusBarButton, "statusBarButton が設定されるべき")
        XCTAssertTrue(view.isHidden, "subview は isHidden=true であるべき")

        view.removeFromSuperview()
    }

    /// 旧初期化順（addSubview → statusBarButton）では viewDidMoveToWindow が空振りして
    /// image が生成されないことを検証。setupEyeView の scheduleUpdate() が脱落すると
    /// この状態に退行する。
    func testOldInitOrderDoesNotGenerateImage() throws {
        let statusItem = NSStatusBar.system.statusItem(withLength: 22)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let button = try XCTUnwrap(statusItem.button)

        let view = ClabotchEyeView(frame: button.bounds)
        // 旧順序: addSubview → statusBarButton（scheduleUpdate なし）
        button.addSubview(view)          // viewDidMoveToWindow 発火 → statusBarButton==nil → 空振り
        view.statusBarButton = button    // ここでは scheduleUpdate は呼ばれない
        view.isHidden = true

        // 旧順序では image が生成されない（初回空白の回帰パターン）
        XCTAssertNil(button.image, "旧初期化順では image が生成されない")

        view.removeFromSuperview()
    }

    /// statusBarButton 未設定で updateStatusImage が空振りし、
    /// 設定 + scheduleUpdate で image が生成されることを検証する回帰テスト。
    func testImageNotGeneratedWithoutStatusBarButton() throws {
        let statusItem = NSStatusBar.system.statusItem(withLength: 22)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let button = try XCTUnwrap(statusItem.button)

        let view = ClabotchEyeView(frame: button.bounds)

        // statusBarButton 未設定で updateStatusImage → 空振り
        view.updateStatusImage()
        XCTAssertNil(button.image, "statusBarButton 未設定なら image は生成されない")

        // statusBarButton 設定 + scheduleUpdate → image 生成
        view.statusBarButton = button
        view.scheduleUpdate()
        XCTAssertNotNil(button.image, "statusBarButton 設定 + scheduleUpdate で image が生成されるべき")
    }
}
