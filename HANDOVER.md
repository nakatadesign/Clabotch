# HANDOVER.md — Clabotch セッション引き継ぎ

## 1. セッション概要

- **日時**: 2026-03-12（JST）夜〜深夜
- **作業目的**: 計画 010（GitHub Actions CI 整備）の完了
- **全体進捗**:
  - 完了: 計画 002〜010（全計画完了）
  - active な計画: なし
  - 総テスト: **204 件**（203 passed, 1 skipped）+ hook E2E **43 件**
  - origin main と同期済み（`6352fda`）

---

## 2. 完了した作業

### 2a. 計画 010 — GitHub Actions CI 整備（完了）

| コミット | 内容 |
|----------|------|
| `102fd3a` | CI ワークフロー初版（`.xcodegen.lock` + `.github/workflows/ci.yml`） |
| `6352fda` | CI 修正（xcodegen パス + actions Node.js 24 対応） |

#### CI 初回実行で発生した問題と修正

| 問題 | 原因 | 修正 |
|------|------|------|
| `Install xcodegen` ステップで exit code 1 | xcodegen.zip 展開後のパスに `xcodegen/` プレフィックスがあり、`xcodegen-bin/bin/xcodegen` が存在しなかった | `xcodegen-bin/xcodegen/bin` に修正 |
| Node.js 20 deprecation 警告 | actions/checkout v4, upload-artifact v4 が Node.js 20 使用 | v6.0.2, v7.0.0 に更新（SHA pin 維持） |

#### totonoe ループ結果

| Round | Reviewer | Judge | Manager |
|-------|----------|-------|---------|
| 1 | B（SHA pin 退行指摘） | fix | continue |
| 2 | A（指摘 0） | done | done |

### 2b. 計画 010 クローズ処理

- `docs/exec-plans/active/010-ci-setup.md` → `docs/exec-plans/completed/` に移動

---

## 3. 重要な意思決定と理由

### 3a. B 許容で実装に移行（前セッション）

- **決定**: Codex 計画レビュー B×9 round で膠着。A を追求せず B で実装に進む
- **理由**: S 指摘 0 件。B 指摘は毎回新観点で収束しにくい

### 3b. PAT の workflow スコープ問題（前セッション）

- Fine-grained PAT に `workflow` スコープがなく push が拒否された → ユーザーが権限更新で解決
- gh CLI は `yukinakata` アカウント、リポジトリは `nakatadesign` 所有 → gh API での CI 確認不可

---

## 4. バグ・問題点と解決策

### 4a. totonoe バグ（loop 中に発見・修正済み）

| ファイル | 問題 | 修正 |
|----------|------|------|
| `.claude/totonoe/bin/run_judge.sh` | `printf '- ...'` が `-` をオプションと誤認 | `printf -- '- ...'` に修正 |
| `.claude/totonoe/schemas/judge.schema.json` | Codex API が `additionalProperties: false` 時に全プロパティを `required` に要求 | `engineer_type`, `spot_check_required` を `required` に追加 |

**注意**: これらは upstream `/Users/nakata/Claude/totonoe` にも反映が必要。今回は未実施。

### 4b. hook E2E テスト flaky（未解決・低優先）

- テスト [10]（socket 復帰シナリオ）に flaky 傾向
- CI で再現した場合に対応予定

---

## 5. 次のステップ（優先度順）

### 🔴 高優先度

1. **CI 実行結果の確認**（`6352fda` の push 分）
   - URL: `https://github.com/nakatadesign/clabotch/actions`
   - ブラウザで確認（gh CLI はアカウント不一致で使用不可）
   - PAT に `actions:read` 権限を追加すれば API で確認可能になる

2. **branch protection 設定**（GitHub Settings で手動）
   - Settings → Branches → main:
     - Require a pull request before merging
     - Require status checks: `Build & Test (Swift)` + `Hook E2E Tests`
     - Do not allow bypassing
   - 計画書 Step 3 参照

### 🟡 中優先度

3. **totonoe upstream 反映**
   - `run_judge.sh` の printf 修正
   - `judge.schema.json` の required 修正
   - 対象: `/Users/nakata/Claude/totonoe`

### 🟢 低優先度

4. **Stop hook error 調査** — 再現したら着手
5. **BubbleWindow 実環境テスト** — DI seam でロジックはカバー済み
6. **hook E2E テスト [10] の flaky 対策** — CI で再現した場合に対応
7. **`artifacts/` の `.gitignore` 追加** — 手動検証時の残骸防止
8. **`HANDOVER.md.bak` 削除** — 不要なバックアップ

---

## 6. 環境・依存関係メモ

- **ビルドコマンド**: `cd src && xcodegen generate && xcodebuild test -project Clabotch.xcodeproj -scheme Clabotch -destination 'platform=macOS'`
- **project.yml**: `src/project.yml`（`src/` で xcodegen 実行必須）
- **macOS 13+ / Swift 5.9+**
- **設計書**: 変更禁止。逸脱は `docs/design/patches/` に patch 文書で管理
- **Git**: main ブランチ、origin と同期済み（`6352fda`）
- **PAT**: Fine-grained PAT（リモート URL 埋め込み）。`workflow` スコープ追加済み、`actions:read` は未追加
- **gh CLI**: `yukinakata` アカウントで認証。`nakatadesign` リポジトリへの API アクセス不可

---

## 残留リスク

| リスク | 対応 |
|--------|------|
| CI 修正版（`6352fda`）の実行結果未確認 | ブラウザで要確認 |
| branch protection 未設定 | GitHub Settings で手動設定 |
| totonoe バグ修正が upstream 未反映 | 中優先度で対応 |
| hook E2E テスト [10] の flaky | CI で再現したら対応 |

---

## ユーザーフィードバック（次セッション必読）

- **次フェーズ自動選択**: 候補をユーザーに列挙せず、優先度ルールに従い自動で着手する
