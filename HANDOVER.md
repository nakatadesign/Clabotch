# HANDOVER.md — Clabotch セッション引き継ぎ

## 1. セッション概要

- **日時**: 2026-03-11（JST）
- **作業目的**: コミット前整理 + 未コミット変更の論理単位コミット + 計画 005 作成
- **全体進捗**:
  - 完了: 計画 002, 003, 004（受信パイプライン + StateMachine コア）
  - 計画 005: Codex 計画レビュー A 取得済み・実装待ち
  - 未着手: GazeController/BlinkController 実装、BubbleWindow, ClabotchEyeView, AX tracking
  - 総テスト: **108 件**（107 passed, 1 skipped）

---

## 2. 完了した作業

### 2a. コミット整理（5 コミット）

| コミット | 内容 |
|---------|------|
| `c9053e3` | 計画 002/004 を `docs/exec-plans/completed/` に移動 + HANDOVER.md 整合 |
| `68290a1` | review-loop Manager 最終決定モデル導入（17 ファイル、.claude/agents/ 全体含む） |
| `ff274b2` | 計画 002-004 実装一式（src/ 23 ファイル + design patches + 計画 003） |
| `cf313d8` | hook スクリプト + E2E テスト（6 ファイル） |
| `a7d8eb5` | プロジェクト基盤（tasks/, public-repo-template/） |

### 2b. 計画 005 作成 + Codex 計画レビュー A

- `docs/exec-plans/active/005-gazecontroller-blinkcontroller.md` 新規作成
- Codex 初回レビュー: B（S:1, B:5）
  - S-2: 逸脱テーブル記録漏れ（onGazeFrameChanged / applyGaze）
  - B-2: DI 化副作用未記載、B-4: テスト不足、B-5: 仕様未明記
- 修正後レビュー: **A**（S:0, B:1）
  - B-1: applicationWillTerminate での BlinkController 未停止 → 修正済み

---

## 3. 重要な意思決定と理由

### 3a. GazeController / BlinkController の DI 設計（逸脱 #1-#7）

- **AXProvider / WorkspaceProvider protocol**: AX API と NSWorkspace を protocol で抽象化し DI 注入。CI/テスト環境で AX 権限なしにテスト可能
- **applyGaze() ヘルパー**: v11 では mode/gazeFrame を直接代入しているが、変更検知 + onGazeFrameChanged 通知を一元化するヘルパーを追加
- **BlinkController.setBlinking(enabled:)**: AppDelegate が phase に応じて制御。BlinkController は MascotPhase を知らない（責務分離）
- **タイマーリセット仕様**: setBlinking(enabled: true) は既存タイマーをリセットする。phase 切り替え直後にまばたきせず一拍おく意図

### 3b. .claude/settings.json hooks 整理

- hooks セクションはコミット `68290a1` で削除済み
- Stop hook は `.claude/settings.local.json`（git 管理外）に移行済み
- 追加整理は不要と判断

---

## 4. 次のステップ（優先度順）

### 🔴 高優先度
- **計画 005 実装**: GazeController + BlinkController（Codex 計画 A 取得済み）
  - 計画書: `docs/exec-plans/active/005-gazecontroller-blinkcontroller.md`
  - 計画書自体が未コミット（実装コミットと一緒にコミットするか、先にコミットするか）
  - 目標テスト: 141 件（140 passed, 1 skipped）

### 🟡 中優先度
- **計画 006: BubbleWindow + ClabotchEyeView 実装**（設計書 §11）
  - 22×14px フレーム描画
  - 14 フレームアニメーション
  - 吹き出しウィンドウ

### 🟢 低優先度
- Warp AX 属性ダンプ → tentativeBundles 昇格判断
- Stop hook error 対応（別件、tasks/todo.md で管理）

---

## 5. 重要ファイルマップ

### 本セッションで作成

| ファイル | 役割 |
|----------|------|
| `docs/exec-plans/active/005-gazecontroller-blinkcontroller.md` | 計画 005（未コミット） |

### 本セッションで変更（コミット済み）

| ファイル | 変更内容 |
|----------|---------|
| `docs/exec-plans/completed/002-*` | active → completed 移動 |
| `docs/exec-plans/completed/004-*` | active → completed 移動 |
| `.claude/agents/*` | 全エージェント定義（manager.md 含む）新規コミット |
| `.claude/review-loop/bin/apply_manager_decision.sh` | Manager decision 適用スクリプト新規 |
| `.claude/review-loop/bin/run_judge.sh` 等 | Manager モデル追従 |
| `.claude/settings.json` | hooks 削除 + apply_manager_decision.sh 許可追加 |
| `CLAUDE.md` | 4役構成 + manager_review ステータス追記 |
| `src/` 全体 | 計画 002-004 実装コード一式 |
| `hooks/` | hook スクリプト一式 |

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
| main ブランチが origin より 8 コミット先行 | push していない。次セッションで push 判断 |
| Warp の AX 属性（GazeController tentativeBundles） | AX 属性ダンプ後に昇格判断 |
| Stop hook error | 別件。tasks/todo.md で管理 |
