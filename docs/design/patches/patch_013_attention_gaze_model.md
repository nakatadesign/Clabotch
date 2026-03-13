# Patch 013: Attention ベース視線制御モデル

## 概要

v11 §11.5 の常時 AX ポーリング追跡モデルを、イベント駆動の「注意（attention）」モデルに置き換える。

## 動機

常時 AX ポーリングは以下の問題がある:
- ターミナル以外がフロントの時も無駄な AX API 呼び出しが発生
- ユーザーが意識していない間もマスコットが常に追跡し続ける不自然さ
- CPU/エネルギー効率の観点で不利

attention モデルでは、特定のトリガーイベント時のみ一時的に視線追跡を行う。

## v11 §11.5 からの変更点

### 置き換える仕様
- **常時 AX 追跡**: フロントアプリが対応ターミナルの間、継続的に AX API でウィンドウ位置を取得
- → **一時注視**: トリガーイベント発生時のみ `attentionDuration`（デフォルト 2 秒）間追跡

### 追加する概念

#### attentionExpiry: Date?
- 一時注視の有効期限
- 期限内: AX API でターミナルウィンドウ位置を追跡（従来の tracking と同じ）
- 期限切れ: `.f01_center`（attentionNeutral）に戻る

#### トリガー
1. **フェーズ変更**: thinking/working 遷移時に `lookAtTerminal()` → 2 秒間注視
2. **アプリ切替**: 対応ターミナルがフロントに来た時に自動で注意開始
3. **グローバルクリック**: `NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown)` で検出、フロントが対応ターミナルなら注意開始
4. **明示的呼び出し**: `lookAtTerminal(duration:)` で任意の期間を指定可能

#### 優先順位
1. `stateOverride`（idle/done/error/sleeping）— 最高優先、attention を無視
2. 注意中 — AX 追跡
3. 注意切れ — neutral position (f01_center)

### 追加する型・プロトコル

#### FixedGazeReason.attentionNeutral
注意切れ時の neutral position を表す reason。

#### GlobalEventMonitorProviding プロトコル
```swift
protocol GlobalEventMonitorProviding: AnyObject {
    func startMonitoring(handler: @escaping () -> Void)
    func stopMonitoring()
}
```
- `AnyObject` 制約: 内部で mutable state（monitor ハンドル）を保持するため
- 本番実装: `RealGlobalEventMonitor`（`NSEvent.addGlobalMonitorForEvents` ラッパー）
- テストモック: `MockGlobalEventMonitor`（`simulateClick()` で手動発火）

## 実装コミット

- `a7b2af5`: attention ベース視線制御の初期実装（フェーズ変更 + アプリ切替トリガー）
- 本 patch: グローバルクリック検出トリガーの追加
