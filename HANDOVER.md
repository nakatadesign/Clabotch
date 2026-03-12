# HANDOVER.md — Clabotch セッション引き継ぎ

## 1. プロジェクト状態

- **全計画 002〜010**: 完了
- **active な計画**: なし
- **CI**: GitHub Actions 全 6 run green（CI #6 `757c55a` 含む）
- **branch protection**: N/A（private repo + GitHub Free では設定不可）
- **総テスト**: 204 件（203 passed, 1 skipped）+ hook E2E 43 件
- **totonoe upstream**: 全修正反映済み（`284af6b` + `da95d78`）
- **最新コミット**: `757c55a`

---

## 2. 前セッションの完了作業（2026-03-12〜13）

### 計画 010 — GitHub Actions CI 整備

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

MVP 実装完成度は約 85-90%。全コア機能は動作済み。以下は設計書 v11 の MVP スコープ（§12.4）で未実装の項目を優先度順に並べたもの。

### 次の優先タスク

**計画 011: フレーム 09〜14 描画 + DONE/ERROR アニメーション + ジャンプ**
- 設計書 v11 §4「フレーム一覧（全14枚）」+ §5「ジャンプ（DONEイベント）」
- 現在 frame 01〜08 まで実装済み、frame 09〜14 が未実装
- 完了アニメ: frame08→09→12→13→14→13→12（§4 定義）+ ジャンプ（§5）
- エラーアニメ: frame07→10→11→10→07 シェイク（§4 定義）
- DONE 吹き出し表示は CoordinatorBinder に実装済み（本計画のスコープ外）
- MVP スコープ: §12.4 に明記

### 後続タスク

| 優先度 | タスク | 設計書参照 |
|--------|--------|-----------|
| 2 | まばたき中間フレーム（half/almost 7 段階化） | §4 blink シーケンス |
| 3 | オンボーディング UI（AX 権限カスタムダイアログ） | §11.7 |

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
