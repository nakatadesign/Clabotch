# HANDOVER.md — Clabotch セッション引き継ぎ

## 現在のステータス

**フェーズ**: 設計完了 → 開発環境整備完了 → 実装準備中

**最終設計書**: `docs/design/current/clabotch_design_doc_v11.md`（v1〜v11統合、1445行）

---

## 完了済み

- [x] 設計書 v1〜v11 の作成・レビュー（設計上の既知バグゼロ）
- [x] session_id 欠損時 drop-and-log guard（v11）
- [x] 成果物一覧の整合（clabotch_post_tool_failure.sh 追加）
- [x] 開発環境ディレクトリ構造の整備
- [x] CLAUDE.md / AGENTS.md / WORKFLOW.md / ARCHITECTURE.md / REVIEW_RULES.md 作成

---

## 次のアクション（実装順）

| 優先度 | 作業 | 設計書参照 |
|--------|------|-----------|
| **1** | Hook スクリプト疎通テスト（jq確認 + ソケット未起動時のexit 1確認） | §10.4 |
| 2 | Xcodeプロジェクト作成（SwiftUI + AppKit hybrid） | §全体 |
| 3 | HookServer NDJSON line buffer 実装 | §14.1 |
| 4 | EventParser / EventDeduplicator 実装 | §14.2 |
| 5 | StateMachine + GazeController 実装 | §11.5, §12.2 |
| 6 | Warp AX 属性ダンプ → tentativeBundles 昇格判断 | §Residual Risk |

---

## 残留リスク

| リスク | 対応 |
|--------|------|
| Claude Code 2.1.x の hook payload が本当に stdin JSON か | Hook疎通テストで確認 |
| `jq` インストール有無 | `which jq` で確認 / `brew install jq` |
| Warp の AX 属性（GazeController tentativeBundles） | AX属性ダンプ後に昇格判断 |

---

## 技術スタック

- macOS 13+ / Swift 5.9+
- AppKit（NSStatusItem / NSStatusBar）
- SwiftUI（BubbleWindow等）
- Unix domain socket（HookServer）
- jq（Hook スクリプト必須依存）

---

## メモ

- 設計書 v11（`docs/design/current/clabotch_design_doc_v11.md`）は **変更しない**。実装中の知見は本ファイルに記録する。
- 実装計画は `docs/exec-plans/active/` に保存し、Codex レビュー後に着手する。
- Hook スクリプト本体は `hooks/` に作業コピーを置き、完成後 `~/.claude/hooks/` にデプロイする。
