# Clabotch（クラボッチ）設計仕様書

> Claude + bot + っち（たまごっちリスペクト）  
> macOSメニューバー常駐型 Claude Code マスコット

---

## 目次

1. [コンセプト](#コンセプト)
2. [既存調査](#既存調査)
3. [キャラクター仕様](#キャラクター仕様)
4. [フレーム一覧（全14枚）](#フレーム一覧全14枚)
5. [アニメーション定義](#アニメーション定義)
6. [マスコット状態一覧](#マスコット状態一覧)
7. [技術アーキテクチャ](#技術アーキテクチャ)
8. [実装方針](#実装方針)
9. [開発ロードマップ](#開発ロードマップ)

---

## コンセプト

**「Claude Code が働いているのをそっと見守るメニューバーの住人」**

- macOS メニューバーに常駐し、邪魔にならないサイズで存在する
- Claude Code の動作状態（待機・実行・思考・完了・エラー）を目の表情だけで表現
- ターミナルウィンドウの方向に視線を向けて「作業している感」を伝える
- タスク完了時にジャンプして吹き出しで報告する

---

## 既存調査

| アプリ | 配置 | Mac mini対応 | 特徴 |
|--------|------|-------------|------|
| **Notchi** | ノッチ固定 | ❌ | Claude Code hooks連携、感情分析あり |
| **Clawdachi** | 画面上浮遊 | ✅ | ピクセルアート、Spotify連動ダンス |
| **Clabotch** | メニューバー | ✅ | 視線追跡、ジャンプ通知、完全ドット描画 |

Clabotchの差別化：**メニューバー固定 × 視線が動く × 作業の邪魔ゼロ**

---

## キャラクター仕様

### キャンバスサイズ

```
outer（NSStatusItem枠）: 22 × 14 px（論理ピクセル）
face（顔）            : 16 × 12 px  at (3, 1)
左目ソケット（白目）   :  4 ×  8 px  at (5, 3)
右目ソケット（白目）   :  4 ×  8 px  at (13, 3)
瞳（左右各）          :  2 ×  6 px  ← フレームにより座標が変わる
```

### カラーパレット

| パーツ | カラーコード | 用途 |
|--------|-------------|------|
| `#B07878` | 顔（通常） | ベース顔色 |
| `#C08888` | 顔（完了） | 少し明るめ |
| `#C06868` | 顔（エラー） | 赤みを強調 |
| `#906060` | 顔（スリープ） | 暗め |
| `#F0F0F0` | 白目 | アイソケット |
| `#1A1A1A` | 瞳 | ほぼ黒 |
| `#E94560` | エラーX | 赤 |
| `#5577AA` | 思考ドット | 青系 |

### 重要な設計方針

> **PNG素材ゼロ — 全フレームをSwiftコードで描画**  
> Retina（@2x/@3x）対応も `dot = bounds.width / 22.0` 一発で完結

> **瞳移動は座標計算禁止 — フレーム丸ごと切り替え**  
> 連続オフセットだと中間値（1.5dotなど）が発生してドットが崩れるため、
> 4枚の瞳座標セットを定義して切り替えるだけにする

---

## フレーム一覧（全14枚）

実測値：`charactor--01.png` 〜 `charactor--14.png` を Pillow でピクセル読み取り

### 視線フレーム（02〜05）

瞳サイズ 2×6px。座標は左ソケット `(sx=5, sy=3)` を基準に記載。

| フレーム | 画像 | 瞳位置 | Swift座標 | 用途 |
|----------|------|--------|-----------|------|
| `01` | charactor-01 | 中央 | `(sx+1, sy+1)` | IDLE基本 |
| `02` | charactor-02 | **右下** | `pupil(sx+2, sy+2, 2, 6)` | 通常待機 |
| `03` | charactor-03 | **左下** | `pupil(sx, sy+2, 2, 6)` | 左方向 |
| `04` | charactor-04 | **左上** | `pupil(sx, sy, 2, 6)` | 左上方向 |
| `05` | charactor-05 | **右上** | `pupil(sx+2, sy, 2, 6)` | 思考・右上 |

```
frame02:      frame03:      frame04:      frame05:
y3: WWWW      y3: WWWW      y3: PPWW      y3: WWPP
y4: WWWW      y4: WWWW      y4: PPWW      y4: WWPP
y5: WWPP  →   y5: PPWW  →   y5: PPWW  →   y5: WWPP
y6: WWPP      y6: PPWW      y6: PPWW      y6: WWPP
y7: WWPP      y7: PPWW      y7: PPWW      y7: WWPP
y8: WWPP      y8: PPWW      y8: PPWW      y8: WWPP
y9: WWPP      y9: PPWW      y9: WWWW      y9: WWWW
y10: WWPP     y10: PPWW     y10: WWWW     y10: WWWW
```

### まばたきフレーム（06）

| フレーム | 画像 | 内容 |
|----------|------|------|
| `06` | charactor-06 | 白目はそのまま。中央 y7 に **横線1dot（瞳色）** のみ |

```
frame06（まばたき閉じ）:
y3-6: WWWW  ← 白目
y7:   PPPP  ← 横線（ここだけ瞳色）
y8-10: WWWW ← 白目
```

> まばたきは `open → half(まぶた2dot) → almost(まぶた5dot) → closed(06) → almost → half → open` の6ステップ

### エラー・表情フレーム（07〜14）

| フレーム | 画像 | パターン | 用途 |
|----------|------|---------|------|
| `07` | charactor-07 | 中央2×2に小さい× | ERROR（控えめ） |
| `08` | charactor-08 | y7に `WPPW`（中央に2dot） | DONE・驚き |
| `09` | charactor-09 | 左目：ジグザグ縦線 / 右目：PP列 | アニメフレームA |
| `10` | charactor-10 | 上半分に× (`WPPW/PWWP`) | ERROR（上） |
| `11` | charactor-11 | 下半分に× (`PWWP/WPPW`) | ERROR（下） |
| `12` | charactor-12 | 両目に渦巻き状ドット | くるくるアニメB |
| `13` | charactor-13 | 斜め右下がりパターン | くるくるアニメC |
| `14` | charactor-14 | 斜め左下がりパターン（13の逆） | くるくるアニメD |

**エラーアニメ**：`07 → 10 → 11 → 10 → 07`（上下シェイク）

**完了アニメ**：`08 → 09 → 12 → 13 → 14 → 13 → 12`（くるくる）

---

## アニメーション定義

### まばたき（BlinkController）

```
open ─(60ms)→ half ─(60ms)→ almost ─(90ms)→ closed
     ←(60ms)─ half ←(60ms)─ almost ←────────
```
- 次のまばたきまで 2.8〜5.5秒 ランダム待機
- 視線変更と**完全独立**して動作

### 視線追跡（GazeController）

```swift
// ターミナルとアイコンの相対位置を4フレームに量子化
(右下) → frame02
(左下) → frame03
(左上) → frame04
(右上) → frame05
```

- `atan2(dy, dx)` で方向計算 → 4択 enum に変換
- **ClabotchEyeView 内に座標計算は一切なし**

### ジャンプ（DONEイベント）

- NSStatusItem の Y オフセットに バウンスイージングを適用
- ↑ 6px → ↑ 12px → ↑ 4px → 原点 の4ステップ
- 完了後に吹き出し（NSWindow, borderless）が 3秒表示

---

## マスコット状態一覧

| 状態 | トリガー | 視線 | まばたき | 表情フレーム | 吹き出し例 |
|------|---------|------|---------|------------|-----------|
| `idle` | 待機中 | frame02（右下） | 通常 | 01 | — |
| `thinking` | LLM応答待ち | frame05（右上） | 通常 | 01 | 「考えてます...」 |
| `working` | tool_use実行中 | ターミナル方向 | 通常 | 02〜05 | 「ファイル書き込み中...」 |
| `done` | Stopイベント | frame02 | 通常 | 08→09→12→13→14 | 「Window-2 完了！(3分42秒)」 |
| `error` | エラー検知 | center | 停止 | 07→10→11シェイク | 「あれ…エラーが出ました」 |
| `sleeping` | 長時間無操作 | — | 停止 | 横線細め | — |

---

## 技術アーキテクチャ

### データフロー

```
Claude Code
  └─ hooks (shell script)
       └─ Unix Socket (/tmp/clabotch.sock)
            └─ HookServer (Swift)
                 └─ EventParser
                      └─ StateMachine
                           ├─ ClabotchEyeView（描画）
                           ├─ BlinkController（まばたき）
                           ├─ GazeController（視線）
                           └─ BubbleWindow（吹き出し）
```

### 主要コンポーネント

| コンポーネント | 役割 |
|----------------|------|
| `NSStatusItem` | メニューバー常駐 |
| `ClabotchEyeView: NSView` | ドット描画本体 |
| `BlinkController` | まばたきタイマー管理 |
| `GazeController` | 方向計算→4択量子化 |
| `HookServer` | Unix Socket受信 |
| `BubbleWindow: NSWindow` | 吹き出し表示（borderless/transparent） |

### 視線追跡の仕組み

```swift
// Accessibility API でターミナルウィンドウ座標を取得
let terminalCenter = AXUIElement.terminalWindowCenter()
let iconCenter     = statusItem.button?.window?.frame.center

// 方向を4択に量子化（これだけに数学がある）
let frame = GazeController.frame(from: iconCenter, to: terminalCenter)
eyeView.gazeFrame = frame  // .f02 / .f03 / .f04 / .f05 のどれか
```

### 対応ターミナル

- Terminal.app
- iTerm2
- Warp
- WezTerm

---

## 実装方針

### ドット描画の核心原則

```swift
// ✅ 正しい：フレーム丸ごと切り替え
case .f02_center:   px(sx+2, sy+2, 2, 6)  // 実測値そのまま
case .f03_downLeft: px(sx,   sy+2, 2, 6)
case .f04_upLeft:   px(sx,   sy,   2, 6)
case .f05_upRight:  px(sx+2, sy,   2, 6)

// ❌ 禁止：連続オフセット計算
// pupil.x += delta  // 中間値が発生してドットが崩れる
```

### Retina対応

```swift
// 1論理ドット = 何物理ピクセルかを動的に計算
let dot = min(bounds.width / 22.0, bounds.height / 14.0)
// @2x で自動的に dot=2.0 になる
```

### Claude Code Hooks 設定

```json
{
  "hooks": {
    "PreToolUse":  [{"command": "echo '{\"event\":\"tool_start\",\"tool\":\"$TOOL_NAME\"}' | nc -U /tmp/clabotch.sock"}],
    "PostToolUse": [{"command": "echo '{\"event\":\"tool_end\"}' | nc -U /tmp/clabotch.sock"}],
    "Stop":        [{"command": "echo '{\"event\":\"done\",\"session\":\"$SESSION_ID\"}' | nc -U /tmp/clabotch.sock"}]
  }
}
```

---

## 開発ロードマップ

| Phase | 期間 | 内容 | 成果物 |
|-------|------|------|--------|
| **PoC** | 1日 | NSStatusItemにフレーム01を表示 + まばたき | 動くマスコット |
| **v0.1** | 2日 | 視線追跡（frame02〜05）+ Hook受信 | 目が動く |
| **v0.2** | 2日 | DONE/ERROR アニメ + ジャンプ + 吹き出し | フル状態表現 |
| **v0.3** | 2日 | 複数セッション並列 + 作業時間表示 | 実用レベル |
| **v1.0** | 2日 | 設定画面 + LaunchAgent + DMG配布 | リリース |

### 完了済み

- [x] Notchi / Clawdachi 調査
- [x] 名前「Clabotch」決定
- [x] メニューバー常駐コンセプト確定
- [x] キャラクターデザイン 14フレーム作成
- [x] 全フレームのピクセルマップ実測（Pillow）
- [x] SwiftコードによるフレームSwap方式の設計
- [x] `ClabotchEyeView.swift` v3（フレーム切り替え実装）
- [x] スプライトシートSVG v3

### NEXT

- [ ] Xcode プロジェクト作成 → PoC を実際にビルド
- [ ] フレーム07〜14のアニメーション実装
- [ ] Accessibility API でのターミナル座標取得
- [ ] Hook受信 → StateMachine → 描画の結合テスト

---

## 成果物ファイル

| ファイル | 内容 |
|----------|------|
| `clabotch_sprites_v3.svg` | スプライトシート設計図（実測値ベース） |
| `ClabotchEyeView_v3.swift` | 描画エンジン本体（フレームSwap方式） |
| `clabotch_sprites_v2.svg` | 旧バージョン設計図（参考） |

---

*Clabotch — MIT License — 2026 Nakata*
