# 使い方

## 基本的な動作

Clabotch はメニューバーに常駐し、Claude Code の作業状態を自動的に表示します。

| マスコットの状態 | 意味 |
|----------------|------|
| 右下を向いている | 待機中（idle） |
| ターミナルを見ている | 思考中 / 作業中 |
| 目がくるくる＋ジャンプ | タスク完了 |
| × マーク＋上下シェイク | エラー発生 |
| 目を閉じている | スリープ（5分間操作なし） |

完了時には吹き出しで経過時間が表示されます。

## Claude Code Hooks の設定

Clabotch は Claude Code の [Hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) を通じてイベントを受信します。

### 自動設定

アプリ初回起動時に Hook の設定を案内します。

### 手動設定

`~/.claude/settings.json` に以下を追加してください：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": ".*",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/clabotch_pre_tool.sh" }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": ".*",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/clabotch_post_tool.sh" }]
      }
    ],
    "PostToolUseFailure": [
      {
        "matcher": ".*",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/clabotch_post_tool_failure.sh" }]
      }
    ],
    "Stop": [
      {
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/clabotch_stop.sh" }]
      }
    ]
  }
}
```

リリース時には以下の Hook スクリプトが同梱される予定です：

| スクリプト | 役割 |
|-----------|------|
| `clabotch_lib.sh` | 共通ヘルパー |
| `clabotch_pre_tool.sh` | ツール実行前イベント送信 |
| `clabotch_post_tool.sh` | ツール成功イベント送信 |
| `clabotch_post_tool_failure.sh` | ツール失敗イベント送信 |
| `clabotch_stop.sh` | セッション終了イベント送信 |

> 現在これらのスクリプトは開発中のため、まだ同梱されていません。

## 視線追跡

アクセシビリティ権限を許可すると、マスコットが最前面のターミナルウィンドウの方向を見るようになります。

対応ターミナル：
- Terminal.app
- iTerm2
- WezTerm

Warp は現在実験的サポートです。
