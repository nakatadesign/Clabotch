# 計画 015 — totonoe runtime の `.claude` 外移設

## 概要

Clabotch では `totonoe` の runtime を `.claude/totonoe/` に同梱してきたが、この配置は Claude Code の permission model と相性が悪い。`bypassPermissions` / `--dangerously-skip-permissions` を使っても、`.claude/**` は保護ディレクトリのため編集確認が残る。その結果、長時間ループや小刻みな runtime 更新で毎回停止しやすく、運用コストが高い。

対策として、runtime 本体を `.claude/` 配下から切り離し、repo ルート直下の `.totonoe/` へ移設する。これは単なる rename ではなく、実行パス・許可設定・運用文書・テンプレート・runtime データの参照先をまとめて切り替える「運用パスの移行」である。

## 発生した経緯

### 1. 当初の配置判断

- `totonoe` は Claude Code の運用補助であり、`.claude/` 配下に置くのが自然だと判断した
- upstream のテンプレートも `.claude/totonoe/` を採用していた
- `CLAUDE.md` / `AGENTS.md` / `.claude/settings.json` からの参照もまとめやすかった

初期段階ではこの判断で大きな問題は出なかった。読み取り主体の参照が多く、runtime 自体を頻繁に更新する局面が少なかったためである。

### 2. 問題が顕在化したタイミング

- `totonoe` の shell script や schema を継続的に更新する運用になった
- reviewer / judge / manager の改善で `.claude/totonoe/**` への編集頻度が上がった
- Claude Code を `--dangerously-skip-permissions` で起動しても、`.claude/**` 配下の編集では確認ダイアログが残った

ここで初めて、「dangerous mode を使っているのに止まる」のではなく、「`.claude/**` が保護対象なので仕様どおり止まっている」ことが問題の本質だと分かった。

### 3. 根本原因

根本原因は 2 つある。

1. `totonoe` runtime を `.claude/` 配下に置いたこと
2. `.claude/totonoe/` を単なる設定ではなく、継続的に編集される runtime として使っていたこと

つまり問題は CLI オプション不足ではなく、配置設計である。

## 何が問題か

### permission model との衝突

- `.claude/**` は Claude Code にとって保護対象のローカル設定領域
- そのため `bypassPermissions` でも `.claude/**` への書き込み確認は残る
- `totonoe` のように runtime script を頻繁に更新する運用では、毎回ここに引っかかる

### 運用上の悪影響

- Claude Code の長時間ループが確認ダイアログで止まる
- 小さな shell script 修正でも人手介入が必要になる
- `totonoe` の改善速度が落ちる
- 「dangerous mode を使っているのに効かない」という誤解を生みやすい

### 単純な rename で終わらない理由

`.claude/totonoe/` は単なるディレクトリ名ではなく、以下の複数経路から参照されている。

- `CLAUDE.md`
- `AGENTS.md`
- `CLAUDE.totonoe.template.md`
- `AGENTS.totonoe.template.md`
- `.claude/settings.json` の allow ルール
- `README.md` / `RUNBOOK.md` / `HANDOVER.md` などの運用文書
- runtime 内の `BIN_DIR/..` 前提の shell script
- `runtime/` の job state / rounds / events

したがって、物理移動だけ行うと運用が壊れる。参照更新まで含めて初めて完了する。

## 採用する対策

### 方針

runtime 本体を `.claude/totonoe/` から `.totonoe/` へ移す。

### 採用理由

- `.claude/` から外れるため、runtime script 更新時の permission prompt を減らせる
- repo ルート直下の隠しディレクトリなので、運用資産としての位置付けを保てる
- `tools/totonoe/` より既存の hidden runtime という性格を保ちやすい
- `.claude/agents` や `.claude/settings.json` はそのまま残せる

### 新しい責務分離

```
.claude/
├── settings.json        ← Claude Code の設定・permission ルール
├── settings.local.json  ← 個人ローカル設定
└── agents/              ← Claude/Codex 向け agent 定義

.totonoe/
├── bin/                 ← runtime shell scripts
├── schemas/             ← reviewer/judge/knowledge schema
├── migrations/          ← knowledge DB migration
├── runtime/             ← job state / rounds / events
├── README.md
├── RUNBOOK.md
└── config.json
```

この分離により、`.claude/` は「Claude Code の設定」、`.totonoe/` は「継続的に更新される runtime」と役割を切り分ける。

## 実施内容

### 必須作業

1. `.claude/totonoe/` を `.totonoe/` へ物理移設
2. repo 内の `.claude/totonoe` 文字列参照を `.totonoe` に更新
3. `.claude/settings.json` の allow ルールを `.totonoe/bin/*.sh` に更新
4. `CLAUDE.md` / `AGENTS.md` の runtime path 記述を更新
5. templates の記述を必要に応じて更新
6. `.totonoe/runtime/**` が保持されることを確認
7. 旧 `.claude/totonoe/` を削除

### 変更対象の目安

- `CLAUDE.md`
- `AGENTS.md`
- `CLAUDE.totonoe.template.md`
- `AGENTS.totonoe.template.md`
- `.claude/settings.json`
- `.env.example`
- `HANDOVER.md`
- `.totonoe/**` 配下の README / RUNBOOK / script / schema

## 非採用案

### 案1: 現状のまま運用で我慢する

不採用。問題の原因が配置にある以上、毎回の確認コストを受け入れても根本解決にならない。

### 案2: `permissions.allow` を増やして回避する

不採用。`.claude/**` は保護ディレクトリであり、通常の allow ルール追加では完全回避できない。

### 案3: symlink だけ張る

不採用。見かけ上のパスが残るだけで、どこが正本か曖昧になる。ドキュメント・運用・調査すべてが不安定になる。

### 案4: `tools/totonoe/` へ移す

今回は不採用。悪くはないが、runtime・state・job data を持つ hidden operational directory としては `.totonoe/` の方が意図が明確。

## リスク

### リスク1: 参照更新漏れ

最も現実的なリスク。shell script より文書や allow ルールの更新漏れの方が起こりやすい。

対策:

- `rg -n "\.claude/totonoe" -S` で全件確認
- 移行後に `.claude/totonoe` が意図せず残っていないか再確認

### リスク2: runtime データ消失

`.claude/totonoe/runtime/**` は作業履歴そのものなので、誤削除すると復旧コストが高い。

対策:

- 物理移設前後で `runtime/` の存在確認
- `state.json` / `rounds/` / `events.jsonl` の継承確認

### リスク3: permission ルール不整合

`.claude/settings.json` が旧パスのままだと runtime script 実行許可がズレる。

対策:

- `.claude/settings.json` の `.totonoe/bin/*.sh` 参照を確認
- `jq empty .claude/settings.json` で構文確認

## 完了条件

1. runtime 本体が `.totonoe/` に移っている
2. `CLAUDE.md` / `AGENTS.md` / `.claude/settings.json` が新パスを参照している
3. `.claude/totonoe` 参照が意図した例外を除いて残っていない
4. `.totonoe/runtime/**` が保持されている
5. `.totonoe/bin/*.sh` の `bash -n` が通る

## 検証項目

```bash
rg -n "\.claude/totonoe" -S .
find .totonoe/bin -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
jq empty .claude/settings.json
jq empty .totonoe/config.json
find .totonoe/schemas -type f -name '*.json' -print0 | xargs -0 -n1 jq empty
test -d .totonoe/runtime
git diff --stat
```

## メモ

この対応の本質は「dangerous mode をもっと強くする」ことではない。Claude Code の保護境界に、更新頻度の高い runtime を置かないことである。

つまり、今回直すのは設定ではなく配置設計である。
