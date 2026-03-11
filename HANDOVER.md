# HANDOVER.md — Clabotch セッション引き継ぎ

## 1. セッション概要

- **日時**: 2026-03-12（JST）
- **作業目的**: 計画 007〜009 実装
- **全体進捗**:
  - 完了: 計画 002, 003, 004, 005, 006, 007, 008, 009
  - 総テスト: **195 件**（194 passed, 1 skipped）

---

## 2. 完了した作業

### 2a. 計画 007 — CoordinatorBinder 抽出 + 下流連携テスト

review-loop job `plan007-impl` で 2 ラウンド実施し done 達成。

| ラウンド | Grade | 主な修正 |
|---------|-------|---------|
| Round 1 | B | 初期実装。os_log に error message 漏洩、BubbleSpy.lastText dismiss 後残存 |
| Round 2 | B | os_log 秘匿（phaseName）、BubbleSpy dismiss クリア、単体テスト +4 件 → **done** |

### 2b. 計画 008 — HookServer 起動失敗時の半初期化修正

Codex 計画レビュー A + 実装レビュー A を取得。

### 2c. 計画 009 — Warp AX 属性ダンプ + 昇格判断

AX 属性ダンプの結果 **COMPATIBLE** と判定。Warp を `supportedBundles` に昇格。

| 項目 | 結果 |
|------|------|
| BundleIdentifier | `dev.warp.Warp-Stable`（設計書の `dev.warp.desktop` と異なる） |
| Warp バージョン | 0.2026.03.04.08.20.02 |
| kAXWindows | 成功 |
| kAXPosition | 成功（1408.0, 367.0） |
| kAXSize | 成功（1024.0 x 768.0） |
| 判定 | COMPATIBLE — supportedBundles 昇格 |

#### 変更ファイル

| ファイル | 変更内容 |
|----------|---------|
| `src/Clabotch/GazeController.swift` | `tentativeBundles` を空にし、`supportedBundles` に `dev.warp.Warp-Stable` を追加 |
| `src/ClabotchTests/GazeControllerTests.swift` | Warp テストを `.unsupportedTerminal` → `.tracking` に変更 |
| `docs/design/patches/patch_009_warp_ax_investigation.md` | 調査結果の記録 |
| `tests/ax_dump.swift` | AX 属性ダンプスクリプト（調査ツール） |

---

## 3. 重要な意思決定と理由

### 3a. CoordinatorBinder 抽出（計画 007）

- AppDelegate の結線ロジックを CoordinatorBinder に移設し、自動テストで検証可能にした
- os_log は `phaseName()` で case 名のみ出力（error message 漏洩防止）
- BubblePresenting プロトコルで BubbleWindow を抽象化（テストでは BubbleSpy を注入）

### 3b. HookServer 起動失敗修正（計画 008）

- UI 初期化（StateMachine/GazeController）を HookServer の成否から独立させた
- `.alreadyRunning` のみ terminate。その他のエラーではマスコットとして最低限動作を継続

### 3c. Warp BundleIdentifier の不一致（計画 009）

- 設計書 v11 §11.5 では `dev.warp.desktop` だが、実機の Warp Stable は `dev.warp.Warp-Stable`
- 旧バージョンまたは別リリースチャンネルの可能性。Homebrew Cask の Stable のみ対応
- 逸脱を `docs/design/patches/patch_009_warp_ax_investigation.md` に記録済み

---

## 4. 次のステップ（優先度順）

### 高優先度
- main ブランチの origin への push

### 中優先度
- phaseName 回帰テスト追加（reviewer 指摘 can_defer）
- BubbleWindow テスト seam（Timer/NSWindow DI 注入）

### 低優先度
- 22×14 canvas 中央配置
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
| BubbleWindow show() headless テスト不可 | テスト seam 導入で対応予定 |
| activeBubble/ephemeralBubble 同一型リスク | init パラメータ名で軽減。型安全ではなく手動レビュー依存 |
| Warp の BundleIdentifier 変更リスク | 将来のバージョンで `dev.warp.Warp-Stable` が変わる可能性 |
