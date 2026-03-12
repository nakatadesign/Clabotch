# HANDOVER.md — Clabotch セッション引き継ぎ

## 1. プロジェクト状態

- **全計画 002〜012**: 完了
- **active な計画**: なし
- **CI**: GitHub Actions 全 6 run green（CI #6 `757c55a` 含む）
- **branch protection**: N/A（private repo + GitHub Free では設定不可）
- **総テスト**: 226 件（225 passed, 1 skipped）+ hook E2E 43 件
- **totonoe upstream**: 全修正反映済み（`284af6b` + `da95d78`）
- **最新コミット**: `a9752c8`

---

## 2. 前セッションの完了作業

### 計画 012 — まばたき中間フレーム half/almost 7 段階化（2026-03-13）

- patch_012 設計文書策定（`docs/design/patches/patch_012_blink_midframes.md`）
- BlinkStage enum 導入: open / half / almost / closed
- `isBlinkClosed: Bool` → `blinkStage: BlinkStage` に置換（computed property で後方互換維持）
- 7 段階シーケンス: open→half(60ms)→almost(60ms)→closed(90ms)→almost(60ms)→half(60ms)→open（合計 330ms）
- drawBlinkHalf() / drawBlinkAlmost() 新規描画メソッド追加
- コミット: `a9752c8`

### 計画 011 — フレーム 09〜14 描画 + DONE/ERROR アニメーション + ジャンプ（2026-03-13）

- frame 09〜14 のピクセル定義を patch 文書で策定（`docs/design/patches/patch_011_frames_09_14.md`）
- DONE 瞳スピン: 08→09→12→13→14→13→12（時計回り、120ms/step）
- ERROR シェイク: 07→10→11→10→07（Y ±1dot、80ms/step）
- ジャンプ: ↑6px→↑12px→↑4px→原点（§5 定義、80ms/step）
- shakeOffsetToViewDY() ヘルパー切り出し（AppKit Y 座標変換）
- コミット: `d6bb87e`（フレーム + アニメーション）、`55dc5f1`（ジャンプ）

### 計画 010 — GitHub Actions CI 整備（2026-03-12〜13）

- CI ワークフロー作成・修正・全 run green 確認まで完了
- xcodegen パス修正 + actions/checkout v6, upload-artifact v7（SHA pin）
- 計画書を `docs/exec-plans/completed/010-ci-setup.md` に移動済み

### リポジトリ衛生整備

- `.gitignore` に `artifacts/` 追加
- `run_ai_exec.sh` の `${var:-}` 安全化
- Co-Authored-By 履歴書き換え（バックアップ: tag `backup/before-coauthor-cleanup-20260312`）

### totonoe バグ修正（upstream 反映済み）

- `run_judge.sh`: `printf -- '- ...'`（`284af6b`）
- `judge.schema.json`: required フィールド追加（`284af6b`）
- `run_ai_exec.sh`: `${var:-}` 安全化（`da95d78`）

---

## 3. 次フェーズ backlog（優先度順）

MVP 実装完成度は約 98%。全コア機能 + アニメーション + まばたき 7 段階化動作済み。

### 次の優先タスク

| 優先度 | タスク | 設計書参照 |
|--------|--------|-----------|
| 1 | オンボーディング UI（AX 権限カスタムダイアログ） | §11.7 |

### 条件付きタスク

| タスク | 着手条件 |
|--------|---------|
| Stop hook error 調査 | 再現したら |
| BubbleWindow 実環境テスト | GUI 環境で手動確認 |
| hook E2E テスト [10] flaky 対策 | CI で再現した場合 |
| PAT 権限追加（人間の作業） | 任意。API で CI 確認したい場合 |

---

## 4. 環境・依存関係メモ

- **ビルド**: `cd src && xcodegen generate && xcodebuild test -project Clabotch.xcodeproj -scheme Clabotch -destination 'platform=macOS'`
- **project.yml**: `src/project.yml`（`src/` で xcodegen 実行必須）
- **macOS 13+ / Swift 5.9+**
- **設計書**: `docs/design/current/clabotch_design_doc_v11.md`（変更禁止、逸脱は patches/）
- **PAT**: Fine-grained PAT（リモート URL 埋め込み）。`workflow` スコープ追加済み
- **gh CLI**: `yukinakata` アカウント。`nakatadesign` リポジトリへの API アクセス不可

---

## ユーザーフィードバック（次セッション必読）

- **次フェーズ自動選択**: 候補をユーザーに列挙せず、優先度ルールに従い自動で着手する
