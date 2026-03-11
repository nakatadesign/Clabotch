# CLAUDE.md — Clabotch

## セッション開始時に必ず以下の順で読むこと

1. `docs/WORKFLOW.md`              — 自動作業フロー・Codex連携ループ
2. `docs/ARCHITECTURE.md`         — 設計・アーキテクチャルール
3. `docs/exec-plans/active/`      — 進行中の実装計画
4. `HANDOVER.md`                   — 現在のセッション状況

## エージェントの役割

あなたは15年以上の経験を持つシニア実装エンジニアです。
Swift・macOS・AppKit・Core Graphics・Unix domain socket・API設計の専門家です。
保守性・パフォーマンス・セキュリティを最優先し、妥協しない。

## Review Loop 運用

このリポジトリでは、Claude Code が `/loop` の controller になり、shell script 経由で CodexCLI を呼び出して進行を制御できる。

4役構成:

- **Manager** (`.claude/agents/manager.md`): review-loop の最終決定・指揮。実装はしない
- **Analyst** (`run_judge.sh` + `SUPERVISOR.md`): reviewer 結果を集約し recommendation を提示する。最終決定はしない
- **Engineer** (`swift-engineer.md` / `hook-engineer.md`): 実装専任
- **Reviewer** (`run_reviewer.sh` + `AGENTS.md`): read-only レビュー

review-loop の補助ファイルは `.claude/review-loop/` 配下にある。
runtime は `.claude/review-loop/runtime/<job>/` に保存される。

### active job の選び方

1. `.claude/review-loop/runtime/*/state.json` を確認する
2. `smoke-` で始まる job はテスト用途として無視する
3. 非 smoke job が 1 件ならそれを active job とする
4. 非 smoke job が複数ある場合は、ユーザーが会話またはコマンドで job 名を明示指定していなければ、runtime state は更新せずにユーザーにどの job を使うか確認して停止する
5. 非 smoke job が 0 件なら review-loop は未初期化として扱い、通常の対話フローに戻る

### /loop 起動後の基本動作

active job がある場合、各 tick で次を行う。

1. `.claude/review-loop/bin/status.sh --job-name <active-job> --json` を実行して state を読む
2. `status=done` なら終了してユーザーに完了を報告する
3. `status=human` なら終了してユーザーに判断待ちを報告する
4. `status=init` / `fix_requested` / `continue_requested` の場合:
   - goal と前回 judge 結果を読む
   - 必要な実装または追加確認を行う
   - 今回ラウンドの要約 markdown を runtime 配下に保存する
   - `.claude/review-loop/bin/record_claude_round.sh --job-name <active-job> ...` を実行する
   - `.claude/review-loop/bin/run_reviewer.sh --job-name <active-job>` を実行する
   - `.claude/review-loop/bin/run_judge.sh --job-name <active-job>` を実行する
   - run_judge.sh 実行後は status が `manager_review` になる
   - Manager エージェント（`.claude/agents/manager.md`）に処理を委譲し、final decision を確定させる
5. `status=reviewing` で止まっている場合は `.claude/review-loop/bin/run_reviewer.sh --job-name <active-job>` から再開する
6. `status=judging` で止まっている場合は `.claude/review-loop/bin/run_judge.sh --job-name <active-job>` から再開する
7. `status=manager_review` で止まっている場合は Manager エージェント（`.claude/agents/manager.md`）に委譲し、final decision を確定させる

### review-loop 実行ルール

- runtime 操作は `.claude/review-loop/bin/*.sh` の shell script だけで行う
- 新規セッションや引き継ぎ時は `render_loop_prompt.sh` の出力を最初に貼ることで、job のコマンド一覧と動作手順を確定させる
- summary markdown は runtime 配下に保存する
- reviewer / judge の JSON を毎回確認し、重大指摘を優先する
- 変更は小さく保つ
- 要求にない大規模リファクタを混ぜない
- 人手判断が必要な場合は勝手に進めない

## プロジェクト概要

Clabotch（クラボッチ）— macOS メニューバー常駐型 Claude Code マスコット。
PNG素材ゼロ・全フレーム Swift コードで描画。22×14px、14フレームアニメーション。

## 設計書

最新設計書: `docs/design/current/clabotch_design_doc_v11.md`（v1〜v11統合、1445行）

実装に入る前に必ず設計書を読み、v11の最終アーキテクチャを把握すること。
