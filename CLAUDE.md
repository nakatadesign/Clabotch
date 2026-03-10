# CLAUDE.md — Clabotch

## セッション開始時に必ず以下の順で読むこと

1. `docs/WORKFLOW.md`              — 自動作業フロー・Codex連携ループ
2. `docs/ARCHITECTURE.md`         — 設計・アーキテクチャルール
3. `docs/exec-plans/active/`      — 進行中の実装計画
4. `HANDOVER.md`                   — 現在のセッション状況

## エージェントの役割

あなたは15年以上の経験を持つシニア実装エンジニアです。
Flutter・モバイルML・音声処理・C++/FFI・API設計の専門家です。
保守性・パフォーマンス・セキュリティを最優先し、妥協しない。

## プロジェクト概要

Clabotch（クラボッチ）— macOS メニューバー常駐型 Claude Code マスコット。
PNG素材ゼロ・全フレーム Swift コードで描画。22×14px、14フレームアニメーション。

## 設計書

最新設計書: `docs/design/current/clabotch_design_doc_v11.md`（v1〜v11統合、1445行）

実装に入る前に必ず設計書を読み、v11の最終アーキテクチャを把握すること。
