# Agent Team Layout

Recommended default team for Clabotch:

1. `swift-engineer`   — AppKit / SwiftUI / StateMachine / GazeController
2. `hook-engineer`    — bash hook scripts / Unix domain socket 疎通
3. `reviewer`         — read-only レビュー（設計書 v11 との整合確認）

Optional:

4. `spec-keeper`      — 設計書 v11 との仕様ドリフト検出

## チームモードを使う場面

Good candidates:
- 新コンポーネント追加（SwiftUI + StateMachine の両方にまたがる変更）
- Hook スクリプトの疎通テスト
- PR レビュー / 実装計画レビュー
- テスト追加

## チームモードを避ける場面

- 同じファイルに複数エージェントが触る横断的な変更
- 設計書の大幅改訂（Claude Code 単独で対応）
