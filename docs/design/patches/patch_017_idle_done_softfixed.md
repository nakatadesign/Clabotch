# Patch 017: Idle/Done の SoftFixed 化

## 概要

patch_014 の変更 1（idle/done の gazeOverride を `.none` にして常時カーソル追跡）を
supersede し、idle/done を softFixed に変更する。

## patch_014 変更 1 との関係

**patch_014 の変更 1 を本パッチで supersede する。**

patch_014 の変更 1 は idle/done の gazeOverride を `.none`（常時カーソル追跡）としたが、
これは attention モデル（patch_013）との整合性に問題がある:
- `.none` だと attention 切れでも追跡が続き、idle で常に目が動く不自然さが残る
- AX API の無駄な呼び出しが増える

本パッチでは idle/done を softFixed とし、attention 中のみ追跡を許可する。
patch_014 の変更 2（顔色パレット拡大）は影響を受けない。

## v11 からの逸脱

| # | 内容 | v11 正典 | 本パッチ | 理由 |
|---|------|---------|----------|------|
| 1 | idle の gazeOverride | `.fixed(.f02, .mascotStateOverride)` | softFixed（allowsAttentionOverride=true） | attention 中はターミナル追跡を許可する |
| 2 | done の gazeOverride | `.fixed(.f02, .mascotStateOverride)` | softFixed（allowsAttentionOverride=true） | 同上 |

## 仕様

### CoordinatorBinder.gazeOverride(for:) の対応表

| MascotPhase | gazeOverride | 種別 |
|-------------|-------------|------|
| idle | `.fixed(frame: .f02_rightDown, reason: .mascotStateOverride, allowsAttentionOverride: true)` | softFixed |
| thinking | `.none` | — |
| responding | `.none` | — |
| working | `.none` | — |
| done | `.fixed(frame: .f02_rightDown, reason: .mascotStateOverride, allowsAttentionOverride: true)` | softFixed |
| error | `.fixed(frame: .f01_center, reason: .mascotStateOverride, allowsAttentionOverride: false)` | hardFixed |
| sleeping | `.fixed(frame: .f01_center, reason: .mascotStateOverride, allowsAttentionOverride: false)` | hardFixed |

### GazeController.update() の優先順位

```
1. アプリ切替検出（対応ターミナルへの切替で attention 開始）
2. hardFixed チェック（error/sleeping）→ 即適用して return
3. attention 有効性チェック:
   a. attention 無効 + softFixed → softFixed を適用して return
   b. attention 無効 + override なし → .fixed(.f01_center, .attentionNeutral) で return
   c. attention 有効 → 追跡を試みる（下へ進む）
4. 権限チェック（notGranted → 固定で return）
5. supportedBundles チェック:
   - フロントアプリが supportedBundles 外 → .fixed(.f01_center, .attentionNeutral) で return
6. AX 追跡（supportedBundles 内のターミナルウィンドウ位置を取得）
```

### 挙動の変化

| シナリオ | patch_014 の動作 | 本パッチの動作 |
|---------|----------------|---------------|
| idle + attention 無効 | 常時追跡 | f02_rightDown 固定（softFixed 適用） |
| idle + attention 有効 | 常時追跡 | ターミナル追跡（softFixed バイパス） |
| done + attention 無効 | 常時追跡 | f02_rightDown 固定（softFixed 適用） |
| done + attention 有効 | 常時追跡 | ターミナル追跡（softFixed バイパス） |
| error | f01_center 固定 | f01_center 固定（変更なし） |
| sleeping | f01_center 固定 | f01_center 固定（変更なし） |
