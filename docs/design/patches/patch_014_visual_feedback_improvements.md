# patch_014: 視覚フィードバック改善

## 概要

メニューバーの小さなサイズでフェーズ変化が視覚的に判別しにくい問題を修正する。

## 変更 1: idle/done でも視線追跡を有効化

### 旧仕様（v11 §6, §11.5）
- idle: `fixed(.f02_rightDown, .mascotStateOverride)` — 右下固定
- done: `fixed(.f02_rightDown, .mascotStateOverride)` — 右下固定

### 新仕様
- idle: `.none` — カーソル追跡
- done: `.none` — カーソル追跡

### 理由
- 右下固定は「動いていない」印象が強く、idle 時もマスコットが生きている感じを出すべき
- AX 権限がない場合は GazeController が自動的に `permissionNotDetermined` で固定するため、安全性は維持される
- error/sleeping は引き続き固定（正面固定で異常状態を明示）

### 影響範囲
- `CoordinatorBinder.gazeOverride(for:)` — idle/done のケース
- テスト: `AppDelegateCoordinatorTests`, `CoordinatorIntegrationTests`

## 変更 2: 顔色パレットの差を拡大

### 旧仕様（v11 §3）
| フェーズ | 色 | 特徴 |
|---------|-----|------|
| Normal | #B07878 | ピンクブラウン |
| Done | #C08888 | わずかに明るい（R+16,G+16,B+16）|
| Error | #C06868 | わずかに赤い（G-16,B-16）|
| Sleep | #906060 | わずかに暗い（R-32,G-24,B-24）|

### 新仕様
| フェーズ | 色 | 特徴 |
|---------|-----|------|
| Normal | #B07878 | ピンクブラウン（変更なし）|
| Done | #D0A870 | 暖かいゴールド（達成感）|
| Error | #D04848 | 明確な赤（エラー警告）|
| Sleep | #786888 | 青紫（眠りのイメージ）|

### 理由
- 旧パレットは 16×12 ピクセルのメニューバーアイコンでは差がほぼ判別不能
- 新パレットは色相が明確に異なるため、22px 幅でも一目で状態を識別可能

### 影響範囲
- `ClabotchEyeView.Palette` — faceDone, faceError, faceSleep の色定義
