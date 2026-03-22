# Patch 015: Responding フェーズの追加

## 概要

v11 §6 の 6 フェーズ（idle/thinking/working/done/error/sleeping）に `.responding` を追加する。
Claude Code がツール実行を完了しユーザーへの返答を生成している間を視覚的に区別する。

## v11 からの逸脱

| # | 内容 | v11 正典 | 本パッチ | 理由 |
|---|------|---------|----------|------|
| 1 | MascotPhase の種類 | 6 種 | 7 種（+responding） | tool_end 後に thinking のままだと「まだ考えている」と誤解される |
| 2 | tool_end(success) 後の遷移先 | thinking（即時） | thinking → 0.8 秒後に responding | ツール未使用の思考と返答生成を区別する |

## 仕様

### MascotPhase.responding

| 項目 | 値 |
|------|-----|
| case | `.responding` |
| displayPriority | 2（error=0 > working=1 > **responding=2** > thinking=3 > done=4 > idle=5 > sleeping=6） |

### 遷移ルール

| トリガー | 遷移 | 遅延 |
|---------|------|------|
| tool_end(is_error=false) | thinking → 0.8 秒後に responding | respondingTransitionDelay=0.8s |
| session_start 単独 | thinking のまま（responding にしない） | — |
| tool_start（pending あり） | pending responding をキャンセル → working | 即時 |
| tool_end(is_error=true)（pending あり） | pending responding をキャンセル → error | 即時 |
| session_done（pending あり） | pending responding をキャンセル → done | 即時 |
| responding 中の tool_start | responding → working | 即時 |

### 表示仕様

| 項目 | 値 |
|------|-----|
| gazeOverride | `.none`（attention に委ねる） |
| まばたき | 有効（true） |
| 吹き出し文言 | "作業中..."（patch_020 + コミット 33d65f9 で変更） |
| 視線アニメーション | 中央⇔左下を 2.0 秒間隔で交互（respondingAnimSequence） |
| 顔色 | 通常色（#B07878） |

### CoordinatorBinder の対応

thinking/working と同様に `lookAtTerminal()` を呼ぶ。

## 実装コミット

- `2733500`: responding フェーズのアニメーション追加
- `8a5fb4c`: tool_end 後の responding 自動遷移
- `4abce35`: respondingTransitionDelay を 400ms → 800ms に変更
