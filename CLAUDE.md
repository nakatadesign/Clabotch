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

## totonoe 運用

このリポジトリでは `totonoe` を使って開発ループを回します。Claude Code がコントローラーとなり、シェルスクリプト経由で Codex CLI を呼び出して進行を制御します。ランタイムパスは `.totonoe/` です。

### 実行モードの前提

`totonoe` の長時間ループ運用は、隔離された開発環境で `claude --dangerously-skip-permissions` を使う前提で考えてよい。
`claude --permission-mode acceptEdits` のような控えめなモードでも、`totonoe` のような定型スクリプト連続実行では確認が残りやすく、長いループでは止まりやすい。

ただし、これは安全な隔離環境でのみ推奨する。
本番 credential・個人ファイル・広い権限を持つ環境では、無確認実行を前提にしないこと。

### 起動トリガー

ユーザーが `/loop` を実行するか、貼り付けメッセージが `totonoe start` で始まる場合、そのメッセージ全体を現在の job の loop 開始または再開指示として扱う。
`totonoe start` で始まる場合は、その後に続く `ジョブ名:`, `目的:`, `対象:`, `必須対応:`, `制約:`, `完了条件:`, `現在状態:`, `次の手順:` を優先して読み、現在の状態に応じて次の tick を実行する。
ユーザー入力が `totonoe stop` で始まる場合、現在扱っている job を一時停止したい意図として扱う。job 名が分かっている場合は `.totonoe/bin/pause_job.sh --job-name <current-job> --reason "<user reason or user requested stop>"` を実行し、それ以上のループ処理を進めずに停止理由と再開方法を報告する。現在 job が特定できない場合は、推測で止めず、停止対象の job 名を短く確認する。

### 4つの役割

- **Manager**（`.claude/agents/manager.md`）: ループの最終決定・指揮を担う。実装は行わない
- **Analyst**（`run_judge.sh` + `SUPERVISOR.md`）: Reviewer の結果を集約し、推奨アクションを提示する。最終決定はしない
- **Engineer**（`.claude/agents/swift-engineer.md` / `.claude/agents/hook-engineer.md` を基点に、専門エンジニアへ振り分け）: 実装専任
- **Reviewer**（`run_reviewer.sh` + `AGENTS.md`）: 読み取り専用でレビューを行う

### active job の選び方

1. `.totonoe/runtime/*/state.json` を確認する
2. `smoke-` で始まる job はテスト用途として無視する
3. 非 smoke job が 1 件ならそれを active job とする
4. 非 smoke job が複数ある場合は、ユーザーが会話またはコマンドで job 名を明示指定していなければ、runtime state は更新せずにユーザーにどの job を使うか確認して停止する
5. 非 smoke job が 0 件なら totonoe は未初期化として扱い、通常の対話フローに戻る

### loop 開始後の動作

有効なジョブがある場合、各ステップで以下を行います。

1. `.totonoe/bin/status.sh --job-name <active-job> --json` で現在の状態を確認する
2. `status=done` なら完了を報告して終了する
3. `status=human` なら判断待ちを報告して停止する
4. `status=paused` なら停止理由を報告して停止する
   - 再開が必要なら `.totonoe/bin/resume_job.sh --job-name <active-job>` を案内する
   - resume 後に `.totonoe/bin/render_loop_prompt.sh --job-name <active-job>` を再度実行した内容で続行する
5. `status=init / fix_requested / continue_requested` の場合：
   - 実装または追加確認を行う
   - サマリーの Markdown を runtime 配下に保存する
   - `.totonoe/bin/record_claude_round.sh` を実行する
   - `.totonoe/bin/run_reviewer.sh` を実行する
   - `.totonoe/bin/run_judge.sh` を実行する
   - `manager_review` に遷移したら Manager に委譲する
6. `status=reviewing` なら `run_reviewer.sh` から再開する
7. `status=judging` なら `run_judge.sh` から再開する
8. `status=manager_review` なら Manager に委譲し、最終決定を確定する

### totonoe 実行ルール

- runtime 操作は `.totonoe/bin/*.sh` の shell script だけで行う
- 新規セッションや引き継ぎ時は `render_loop_prompt.sh` の出力を最初に貼ることで、job のコマンド一覧と動作手順を確定させる
- summary markdown は runtime 配下に保存する
- reviewer / judge の JSON を毎回確認し、重大指摘を優先する
- 変更は小さく保つ
- 要求にない大規模リファクタを混ぜない
- 人手判断が必要な場合は勝手に進めない

## Auto Continue（自動継続ポリシー）

- 各フェーズ完了後、停止条件がなければ HANDOVER.md の backlog から最優先タスクを自動選択して継続する
- ユーザー確認は blocker がある場合だけ行う
- 詳細は `docs/WORKFLOW.md` の「Auto Continue」セクションを参照

## プロジェクト概要

Clabotch（クラボッチ）— macOS メニューバー常駐型 Claude Code マスコット。
PNG素材ゼロ・全フレーム Swift コードで描画。22×14px、14フレームアニメーション。

## 設計書

最新設計書: `docs/design/current/clabotch_design_doc_v11.md`（v1〜v11統合、1445行）

実装に入る前に必ず設計書を読み、v11の最終アーキテクチャを把握すること。
