# Hook スクリプト

このディレクトリには Claude Code 連携用の Hook スクリプトを配置する予定です。

> 現在開発中のため、スクリプト本体はまだ同梱されていません。

## 配置予定のファイル

| ファイル | 役割 |
|---------|------|
| `clabotch_lib.sh` | 共通ヘルパー（jq チェック、UUID 生成、ソケット送信） |
| `clabotch_pre_tool.sh` | ツール実行前（session_start + tool_start を送信） |
| `clabotch_post_tool.sh` | ツール成功時（tool_end を送信） |
| `clabotch_post_tool_failure.sh` | ツール失敗時（tool_end + is_error を送信） |
| `clabotch_stop.sh` | セッション終了時（session_done を送信） |

## 前提条件

- `jq` コマンドが必要です: `brew install jq`
