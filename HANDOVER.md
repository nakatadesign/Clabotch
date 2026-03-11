# HANDOVER.md — Clabotch セッション引き継ぎ

## 1. セッション概要

- **日時**: 2026-03-11（JST）
- **作業目的**: 未コミット変更整理 + 計画 005 実装
- **全体進捗**:
  - 完了: 計画 002, 003, 004, 005（受信パイプライン + StateMachine + GazeController/BlinkController）
  - 未着手: BubbleWindow, ClabotchEyeView, AX tracking（Warp）
  - 総テスト: **141 件**（140 passed, 1 skipped）

---

## 2. 完了した作業

### 2a. 未コミット変更の整理（3 コミット）

| コミット | 内容 |
|---------|------|
| `2839947` | review-loop Manager spot-check 事前記録フロー導入 |
| `6c96a6f` | 計画 005 計画書（Codex 計画 A） |
| `1e1fb17` | HANDOVER.md 更新 |

### 2b. 計画 005 実装 + Codex 実装レビュー A

| コミット | 内容 |
|---------|------|
| `5d4940f` | GazeController, BlinkController, AppDelegate 結線, テスト 33 件追加 |

- Codex 実装レビュー: **A**（S:0, B:1）
  - B-1: `requestPermissionIfNeeded` に `dispatchPrecondition` がない → 修正済み

---

## 3. 重要な意思決定と理由

### 3a. GazeController / BlinkController の DI 設計（逸脱 #1-#7）

- **AXProvider / WorkspaceProvider protocol**: AX API と NSWorkspace を protocol で抽象化し DI 注入。CI/テスト環境で AX 権限なしにテスト可能
- **applyGaze() ヘルパー**: v11 では mode/gazeFrame を直接代入しているが、変更検知 + onGazeFrameChanged 通知を一元化するヘルパーを追加
- **BlinkController.setBlinking(enabled:)**: AppDelegate が phase に応じて制御。BlinkController は MascotPhase を知らない（責務分離）
- **タイマーリセット仕様**: setBlinking(enabled: true) は既存タイマーをリセットする。phase 切り替え直後にまばたきせず一拍おく意図

---

## 4. 次のステップ（優先度順）

### 🔴 高優先度
- **計画 006: BubbleWindow + ClabotchEyeView 実装**（設計書 §11）
  - 22×14px フレーム描画
  - 14 フレームアニメーション
  - 吹き出しウィンドウ

### 🟢 低優先度
- Warp AX 属性ダンプ → tentativeBundles 昇格判断
- Stop hook error 対応（別件、tasks/todo.md で管理）
- main ブランチの origin への push

---

## 5. 重要ファイルマップ

### 計画 005 で追加

| ファイル | 役割 |
|----------|------|
| `src/Clabotch/GazeTypes.swift` | GazeFrame, GazePermissionStatus, GazeMode, FixedGazeReason, GazeOverride |
| `src/Clabotch/AXProvider.swift` | AXProvider/WorkspaceProvider protocol + Real 実装 |
| `src/Clabotch/GazeController.swift` | 視線追跡コントローラー（DI 注入、0.5秒ポーリング） |
| `src/Clabotch/BlinkController.swift` | まばたき制御（2.8〜5.5秒ランダム間隔） |
| `src/ClabotchTests/MockProviders.swift` | MockAXProvider / MockWorkspaceProvider |
| `src/ClabotchTests/GazeControllerTests.swift` | 23 件 |
| `src/ClabotchTests/BlinkControllerTests.swift` | 6 件 |
| `src/ClabotchTests/AppDelegateCoordinatorTests.swift` | 4 件 |

### 計画 005 で変更

| ファイル | 変更内容 |
|----------|---------|
| `src/Clabotch/AppDelegate.swift` | GazeController/BlinkController 所有 + onPhaseChanged 結線 |

---

## 6. 環境・依存関係メモ

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
| Stop hook error | 別件。tasks/todo.md で管理 |
