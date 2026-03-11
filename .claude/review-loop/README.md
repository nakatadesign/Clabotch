# Claude Review Loop

`/loop` を司令塔にして、Claude Code が実装し、shell script 経由で 2 本の CodexCLI を呼び出すための最小構成です。

全体像と開始手順の要約は [RUNBOOK.md](/Users/nakata/Claude/clabotch/.claude/review-loop/RUNBOOK.md) を参照してください。

- reviewer 用 CodexCLI
- judge 用 CodexCLI
- supervisor spec

Python は使いません。runtime 操作は shell script だけで回します。

## 構成

- `.claude/review-loop/bin/init_job.sh`
- `.claude/review-loop/bin/status.sh`
- `.claude/review-loop/bin/record_claude_round.sh`
- `.claude/review-loop/bin/run_reviewer.sh`
- `.claude/review-loop/bin/run_judge.sh`
- `.claude/review-loop/bin/apply_manager_decision.sh`
- `.claude/review-loop/bin/render_loop_prompt.sh`
- `.claude/review-loop/bin/templates.sh`
- `.claude/review-loop/SUPERVISOR.md`
- `.claude/review-loop/goals/*.md`
- `.claude/review-loop/schemas/*.json`
- `.claude/review-loop/runtime/<job>/`

`SUPERVISOR.md` は judge が従う進行判断ルールです。

`runtime/` は Git 管理対象外です。

## 前提

```bash
cd /Users/nakata/Claude/clabotch
claude --version
codex --version
jq --version
realpath . >/dev/null
```

## 1. goal テンプレートを確認

```bash
.claude/review-loop/bin/templates.sh
.claude/review-loop/bin/templates.sh --show feature_loop
```

## 2. job を作る

```bash
.claude/review-loop/bin/init_job.sh \
  --job-name demo \
  --goal-template feature_loop
```

## 3. Claude `/loop` 用 prompt を生成

```bash
.claude/review-loop/bin/render_loop_prompt.sh \
  --job-name demo
```

この出力を Claude Code セッションに渡し、そのセッションで `/loop` を開始します。

## 4. Claude が各ラウンドで使うコマンド

Claude は実装後に summary markdown を保存し、次を順に実行します。

```bash
.claude/review-loop/bin/record_claude_round.sh \
  --job-name demo \
  --summary-file /absolute/path/to/summary.md \
  --changed-file src/Clabotch/HookServer.swift \
  --changed-file src/Clabotch/LineBufferedEventDecoder.swift \
  --quality-analyze "not run (review-only repository mode)" \
  --quality-test "not run (manual verification pending)"

.claude/review-loop/bin/run_reviewer.sh \
  --job-name demo

.claude/review-loop/bin/run_judge.sh \
  --job-name demo
```

`run_judge.sh` は `SUPERVISOR.md` を前提に recommendation を生成します。
最終決定は `apply_manager_decision.sh` で Manager が確定します。

```bash
.claude/review-loop/bin/apply_manager_decision.sh \
  --job-name demo \
  --decision fix
```

## 5. 状態確認

```bash
.claude/review-loop/bin/status.sh --job-name demo
.claude/review-loop/bin/status.sh --job-name demo --json
```

## 状態の意味

- `init`
  - まだ Claude のラウンド未記録
- `reviewing`
  - reviewer 実行待ち
- `judging`
  - judge 実行待ち
- `manager_review`
  - judge の recommendation が出た。Manager の最終決定待ち
- `fix_requested`
  - 修正して次ラウンドへ進む
- `continue_requested`
  - 追加確認や追加レビューを優先
- `done`
  - 完了
- `human`
  - 人手判断待ち

## 最初の実運用フロー

1. `init_job.sh` で job を作る
2. `render_loop_prompt.sh` の出力を Claude に貼る
3. Claude Code セッションで `/loop` を開始する
4. Claude は各 tick で `status.sh` を見て、必要なら `record_claude_round.sh` → `run_reviewer.sh` → `run_judge.sh` → `apply_manager_decision.sh` を実行する
5. 必要ならあなたが `status.sh` で様子を見る
