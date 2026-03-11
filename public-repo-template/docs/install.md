# インストール

## 前提条件

- macOS 13 (Ventura) 以降
- [Claude Code](https://claude.ai/claude-code) がインストール済み
- `jq` コマンド

```bash
brew install jq
```

## アプリのインストール

### DMG からインストール（推奨）

> リリース後に GitHub Releases からダウンロードできるようになります。

1. [Releases](https://github.com/nakatadesign/clabotch/releases) から最新の `.dmg` をダウンロード
2. DMG を開き、Clabotch.app を Applications フォルダにドラッグ
3. Clabotch.app を起動

### ソースからビルド

```bash
git clone https://github.com/nakatadesign/clabotch.git
cd clabotch
# ビルド手順は開発の進行に合わせて更新します
```

## Hook スクリプトの設置

Clabotch は Claude Code の Hook 機能と連携して動作します。
Hook スクリプトはリリース時にアプリに同梱予定です。

現時点での Hook 連携の仕組みについては [使い方・Hook 設定](usage.md) を参照してください。

## アクセシビリティ権限（任意）

視線追跡機能（マスコットがターミナルの方向を見る）を使うには、アクセシビリティ権限が必要です。

1. 初回起動時にダイアログが表示されます
2. システム設定 → プライバシーとセキュリティ → アクセシビリティ で Clabotch を許可

**権限を許可しなくても機能の 95% は動作します。** 視線が固定位置になるだけです。
