# HANDOVER.md — Clabotch セッション引き継ぎ

## 1. セッション概要

- **日時**: 2026-03-11（JST）
- **作業目的**: 計画 006 実装 + review-loop 完走
- **全体進捗**:
  - 完了: 計画 002, 003, 004, 005, 006（受信パイプライン + StateMachine + GazeController/BlinkController + ClabotchEyeView/BubbleWindow）
  - 未着手: AX tracking（Warp）
  - 総テスト: **170 件**（169 passed, 1 skipped）

---

## 2. 完了した作業

### 2a. 計画 006 実装 — ClabotchEyeView + BubbleWindow

review-loop job `plan006-impl` で 3 ラウンド実施し Grade A / done 達成。

| ラウンド | Grade | 主な修正 |
|---------|-------|---------|
| Round 1 | C | 初期実装。sleeping blink race, ephemeral bubble 干渉, error 文言, テスト不足 |
| Round 2 | B | 上記4件修正。クリック透過, 入力透過, frame06-08テスト不足 |
| Round 3 | **A** | hitTest透過, ignoresMouseEvents, frame06-08描画テスト → **done** |

#### 新規ファイル

| ファイル | 役割 |
|----------|------|
| `src/Clabotch/ClabotchEyeView.swift` | 22×14px NSView。全14フレーム Core Graphics 描画。hitTest 透過 |
| `src/Clabotch/BubbleWindow.swift` | borderless NSWindow。3秒自動消去。入力透過 |
| `src/ClabotchTests/ClabotchEyeViewTests.swift` | 17 件（状態遷移 + sleeping blink race + frame06-08描画 + hitTest） |
| `src/ClabotchTests/BubbleWindowTests.swift` | 5 件（dismiss安全性 + 独立インスタンス） |

#### 変更ファイル

| ファイル | 変更内容 |
|----------|---------|
| `src/Clabotch/AppDelegate.swift` | Coordinator 結線: EyeView埋め込み, BubbleWindow show/dismiss, ephemeral分離, error固定文言 |
| `src/ClabotchTests/AppDelegateCoordinatorTests.swift` | +6 件（bubbleText, formatElapsedTime, error固定文言） |

---

## 3. 重要な意思決定と理由

### 3a. ClabotchEyeView 設計判断

- **hitTest 透過**: `hitTest(_:) → nil` で NSStatusBarButton にクリック委譲。描画専用ビューとして機能
- **sleeping blink race 対策**: `setPhaseAppearance(.sleeping)` で `blinkTimer?.invalidate()` → blink reopen タイマーが sleeping 中の閉じ目を開けない
- **private(set) 状態公開**: テスト用に gazeFrame, isBlinkClosed, faceColor, showErrorX, showSurprise を private(set) で公開

### 3b. BubbleWindow 設計判断

- **ephemeral/active 分離**: AppDelegate が `bubbleWindow`（active phase）と `ephemeralBubbleWindow`（foreign session_done）の2インスタンスを保持。干渉なし
- **入力透過**: `ignoresMouseEvents = true` で通知専用
- **error 文言固定**: v11 §6 の `"エラーが出ました…"` に統一。詳細 error_message は v1.0+ (§13.6)

### 3c. ヘッドレステスト制約

- BubbleWindow の `show()` は NSWindow 生成時に headless 環境で Signal 11 クラッシュ
- テストは dismiss 安全性のみ。show/auto-dismiss のテスト seam は次計画にバックログ化

---

## 4. 次のステップ（優先度順）

### 🔴 高優先度
- **BubbleWindow テスト seam**: Timer/NSWindow 生成の DI 注入点追加（can_defer バックログ）
- **22×14 canvas 中央配置**: ClabotchEyeView の button 内での垂直中央揃え（can_defer バックログ）

### 🟡 中優先度
- Warp AX 属性ダンプ → tentativeBundles 昇格判断
- main ブランチの origin への push

### 🟢 低優先度
- Stop hook error 対応（tasks/todo.md）

---

## 5. 環境・依存関係メモ

- **ビルドコマンド**: `cd src && xcodegen generate && xcodebuild test -project Clabotch.xcodeproj -scheme Clabotch -destination 'platform=macOS'`
- **project.yml**: `src/project.yml`（`src/` で xcodegen 実行必須）
- **macOS 13+ / Swift 5.9+**
- **設計書**: 変更禁止。逸脱は `docs/design/patches/` に patch 文書で管理

---

## 残留リスク

| リスク | 対応 |
|--------|------|
| HANDOVER.md.bak がリポジトリルートに残存 | バックアップファイル。コミット不要。必要なら削除 |
| main ブランチが origin より先行 | push していない。次セッションで push 判断 |
| Warp の AX 属性（GazeController tentativeBundles） | AX 属性ダンプ後に昇格判断 |
| BubbleWindow show() headless テスト不可 | テスト seam 導入で対応予定 |
