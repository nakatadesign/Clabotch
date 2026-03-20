# Patch 020: Phase 表情割り当ての再調整

## 概要

thinking / responding / working / done の表情割り当てを再調整する。
thinking は一時的な遷移状態のため専用アニメを外し、responding に引き継ぐ。

## 他パッチ・正典との関係

### patch_019 の thinking 表情を supersede
patch_019 で thinking に追加した青瞳 + 上下揺れアニメは responding へ移す。
thinking は静止表情に戻る。patch_019 の thinkingDot 定義自体は残すが、
thinking では使わず responding で使用する。

### v11 §6 の working 吹き出し文言を supersede
v11 §6 では working の吹き出しを「{tool} 実行中...」と定義しているが、
本パッチでは「実行中...(toolName)」に変更する。

### session_start 直後の thinking 視認性
session_start 直後の thinking は、次の tool_start まで継続する場合がある（Claude Code が thinking hook を持たないため）。
この間 thinking は通常色の静止表情だが、吹き出し「考えてます...」で状態を伝える。
視覚的に idle と同一でも、吹き出しの有無で区別可能。

## v11 / 既存 patch からの逸脱

| # | 内容 | 旧仕様 | 本パッチ | 理由 |
|---|------|--------|---------|------|
| 1 | thinking の表情 | 青瞳 + 右上⇔左上 + 上下揺れ (patch_019) | 通常色の静止表情 | thinking は tool_end(success) 後 0.8秒で responding へ遷移するケースがあり（patch_015）、短時間しか表示されない場面が多いため専用アニメは過剰 |
| 2 | responding の表情 | 通常瞳 + 中央⇔左下 (2秒間隔) | 青瞳 + 右上⇔左上 + 上下揺れ (0.8秒間隔) | responding こそ「考えている」印象を出すべき状態。旧 thinking 表情を引き継ぐ |
| 3 | working の顔色 | Palette.faceDone（暖かいゴールド） | Palette.faceNormal（通常色） | working はゴールドではなく通常色が自然 |
| 4 | working の吹き出し | 「作業中... (toolName)」 | 「実行中...(toolName)」 | 表現の変更 |
| 5 | done の顔色 | Palette.faceDone（金色固定） | グラデーション（startRainbowAnimation）が主表現 | faceDone は rainbow 前の初期色。正の表現はグラデーション |

## Phase 表情対応表（本パッチ適用後）

| Phase | 顔色 | 瞳色 | アニメーション | 吹き出し |
|-------|------|------|-------------|---------|
| idle | faceNormal | pupil（黒） | なし | — |
| thinking | faceNormal | pupil（黒） | なし（静止表情） | 考えてます... |
| responding | faceNormal | thinkingDot（青） | 右上⇔左上 + yOffset[-1,0]（0.8秒） | 返答中... |
| working | **faceNormal** | pupil（黒） | なし | **実行中...(toolName)** |
| done | faceDone→rainbow | pupil（黒） | スピン + ジャンプ + グラデーション | 完了！(time) |
| error | faceError | pupil（黒） | シェイク | エラーが出ました… |
| sleeping | faceSleep | pupil（黒） | なし | — |
