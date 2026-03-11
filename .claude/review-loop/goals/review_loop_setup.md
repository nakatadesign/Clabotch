目的:
Claude Code controller と Codex reviewer / supervisor を shell script でつなぐ review-loop 基盤自体を改善する。

対象:
.claude/review-loop/ 配下、`CLAUDE.md`、`AGENTS.md`、必要最小限の `README.md` 更新に限定する。
アプリ本体コードには触れない。

やること:
job 管理、reviewer 実行、judge 実行、状態確認、loop prompt 生成の流れを整える。
必要なら goal template や schema を更新する。
README と RUNBOOK の手順だけで再実行できる状態を保つ。

禁止事項:
デスクトップ UI 自動操作には依存しない。
不要な外部依存を追加しない。
runtime の管理を shell script 以外に逃がさない。

完了条件:
`init_job.sh` / `status.sh` / `record_claude_round.sh` / `run_reviewer.sh` / `run_judge.sh` / `render_loop_prompt.sh` が使える。
reviewer は read-only review のみを行う。
judge は `SUPERVISOR.md` に従って `done` を返せる状態になる。
