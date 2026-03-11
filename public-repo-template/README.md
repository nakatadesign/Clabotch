# Clabotch

**macOS メニューバーに住む Claude Code マスコット**

Clabotch（クラボッチ）は、Claude Code の作業状態をメニューバーのドット絵キャラクターで表示する macOS アプリです。

- メニューバーに常駐し、作業の邪魔をしない
- Claude Code の状態（待機・思考・実行・完了・エラー）を目の表情で表現
- ターミナルウィンドウの方向に視線を向ける
- タスク完了時にジャンプして吹き出しで報告
- PNG 素材ゼロ — 全フレーム Swift コードで描画（22×14px）

## スクリーンショット

> 準備中

## 動作環境

- macOS 13 (Ventura) 以降
- [Claude Code](https://claude.ai/claude-code) がインストール済みであること
- `jq` コマンド（`brew install jq`）

ソースからビルドする場合は追加で Swift 5.9+ が必要です。

## インストール

> 現在開発中です。リリース後にインストール方法を公開します。

詳細は [docs/install.md](docs/install.md) を参照してください。

## 仕組み

Clabotch は Claude Code の [Hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) 機能を利用して動作します。

```
Claude Code → Hook スクリプト → Unix domain socket → Clabotch
```

1. Claude Code がツールを実行するたびに Hook スクリプトが発火
2. Hook スクリプトがイベント情報を Unix domain socket に送信
3. Clabotch がイベントを受信し、マスコットの表情・視線・アニメーションを更新

> Hook スクリプトは現在開発中です。リリース時に同梱予定です。

詳細は [docs/usage.md](docs/usage.md) を参照してください。

## ドキュメント

- [インストール手順](docs/install.md)
- [使い方・Hook 設定](docs/usage.md)
- [トラブルシューティング](docs/troubleshooting.md)
- [コントリビューション](docs/contributing.md)

## 現在のステータス

**開発中（Pre-release）** — 基本設計は完了しており、実装を進めています。

## ライセンス

[MIT License](LICENSE)
