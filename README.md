# Clabotch

Clabotch（クラボッチ）は、macOS メニューバーに常駐して Claude Code の作業状態を表示するマスコットアプリです。

- PNG 素材ゼロ
- 全フレームを Swift コードで描画
- 22x14px のドット絵アニメーション
- Claude Code hooks を Unix domain socket で受信

現在は設計完了に加え、Claude Code controller + Codex reviewer + Codex supervisor(judge) で回す review-loop 基盤を同梱しています。

## Source of Truth

実装判断の正典は以下です。

- `docs/design/current/clabotch_design_doc_v11.md`

実装前に最低限読むファイル:

- `CLAUDE.md`
- `docs/WORKFLOW.md`
- `docs/ARCHITECTURE.md`
- `HANDOVER.md`

Codex レビュー観点は以下です。

- `AGENTS.md`
- `docs/REVIEW_RULES.md`

## Repository Layout

```text
clabotch/
├── README.md
├── CLAUDE.md
├── AGENTS.md
├── HANDOVER.md
├── .claude/
│   ├── settings.json
│   ├── agents/
│   └── review-loop/
├── docs/
│   ├── ARCHITECTURE.md
│   ├── REVIEW_RULES.md
│   ├── WORKFLOW.md
│   ├── design/
│   │   ├── current/
│   │   ├── archive/
│   │   └── patches/
│   └── exec-plans/
│       ├── active/
│       └── completed/
├── hooks/
├── src/
├── tests/
└── artifacts/
```

## Key Directories

- `docs/design/current/`: 現在の正本設計書
- `docs/design/archive/`: 過去バージョンの統合設計書
- `docs/design/patches/`: 設計追補・差分パッチ
- `docs/exec-plans/`: 実装計画
- `.claude/agents/`: Claude Code 用の役割別エージェント定義
- `.claude/review-loop/`: Claude controller / Codex reviewer / Codex supervisor の運用一式
- `hooks/`: `~/.claude/hooks/` に配置する hook の作業コピー
- `src/`: アプリ本体
- `tests/`: 疎通確認・テスト
- `artifacts/`: ビルド成果物、ログ、スクリーンショット

## AI Working Conventions

- Claude Code の入口: `CLAUDE.md`
- Codex の入口: `AGENTS.md`
- review-loop controller/supervisor 手順: `.claude/review-loop/README.md`, `.claude/review-loop/RUNBOOK.md`
- `.claude/settings.json` で team/permission 設定を管理
- `.claude/agents/` で `swift-engineer` `hook-engineer` `reviewer` `spec-keeper` を定義

## Review Loop

review-loop は Claude Code を controller、Codex を reviewer と supervisor に分離して shell script で進行させる仕組みです。

- ランタイム操作は `.claude/review-loop/bin/*.sh` のみ
- reviewer は read-only review のみ
- judge は `.claude/review-loop/SUPERVISOR.md` に従って `fix / continue / done / human` を返す
- 成果物は `.claude/review-loop/runtime/<job>/` に保存される

開始手順は [.claude/review-loop/README.md](/Users/nakata/Claude/clabotch/.claude/review-loop/README.md) と [.claude/review-loop/RUNBOOK.md](/Users/nakata/Claude/clabotch/.claude/review-loop/RUNBOOK.md) を参照してください。

## Planned Architecture

```text
Claude Code hooks (stdin JSON)
  -> Unix domain socket ($TMPDIR/clabotch.sock)
  -> HookServer
  -> LineBufferedEventDecoder
  -> EventParser
  -> EventDeduplicator
  -> StateMachine
  -> Menu bar mascot UI
```

詳細は `docs/ARCHITECTURE.md` と設計書 v11 を参照してください。

## Setup Notes

- 想定環境: macOS 13+, Swift 5.9+
- hook スクリプトは `jq` 前提
- `hooks/` は作業用。実運用時は `~/.claude/hooks/` へ配置
- 実装前に hook payload とソケット疎通を確認する

## Current Status

- 設計書 v11 まで統合済み
- ディレクトリ構成整理済み
- Claude/Codex 用ドキュメント整備済み
- 次の着手は hook 疎通テストと Xcode プロジェクト作成
