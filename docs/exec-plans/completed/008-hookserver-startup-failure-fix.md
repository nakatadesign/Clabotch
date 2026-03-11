# 実装計画 008: HookServer 起動失敗時の半初期化修正

## 概要

AppDelegate.applicationDidFinishLaunching において、`stateMachine.start()` と `gazeController.startPolling()` が HookServer.start() の成功パス内にのみ配置されているため、HookServer 起動失敗時に UI 系の初期化が行われず半初期化状態で常駐するバグを修正する。

## 正典参照

- 設計書: `docs/design/current/clabotch_design_doc_v11.md`
- §12.2 L990-993: `stateMachine.start()` は起動時に 1 回必須。初期 `.idle` emit + sleep タイマー始動
- §12.2 L984-987: `startPolling()` は `start()` の後に呼ぶ（起動順保証）
- §10.3: 受信パイプライン — HookServer → StateMachine は独立した上流。StateMachine 以降の fan-out は HookServer に依存しない

## 正典からの逸脱

| # | 内容 | v11 正典 | 本計画 | 理由 |
|---|------|---------|--------|------|
| 1 | HookServer 起動失敗時にアプリを終了しない | v11 は HookServer の起動失敗時の振る舞いを明示していない | `.alreadyRunning` のみ terminate。その他のエラーは HookServer なし（フック未受信）でマスコットとして常駐し続ける | マスコットとしての表示は HookServer に依存しない。idle → sleeping の最低限の動作は保証すべき。将来的にリトライやユーザー通知を追加可能 |

## 前提条件

- [x] 計画 002〜007 完了
- [x] 全 195 テスト合格（194 passed, 1 skipped）
- [x] AppDelegate.swift に CoordinatorBinder 委譲済み（計画 007）

## スコープ

**含む:**
- `stateMachine.start()` / `gazeController.startPolling()` の実行位置を HookServer 成否に依存しないよう移動
- HookServer 起動失敗時のログ出力改善（fault レベルへ昇格）

**含まない:**
- HookServer のリトライ機構
- ユーザーへのエラー通知 UI（BubbleWindow 等）
- HookServer 以外のコンポーネントの変更
- テスト追加（AppDelegate のインスタンス化は headless 環境で不可。修正は do-catch ブロックの構造変更のみであり、ロジック追加なし。既存テスト 195 件の回帰確認で十分）

## 詳細設計

### 変更前（AppDelegate.swift L73-83）

```swift
do {
    try hookServer?.start()
    os_log(.info, "HookServer started")
    stateMachine.start()          // ① HookServer 成功時のみ
    gazeController.startPolling() // ② HookServer 成功時のみ
} catch let error as HookServerError where error == .alreadyRunning {
    os_log(.error, "既に別インスタンスが起動中")
    NSApplication.shared.terminate(nil)
} catch {
    os_log(.error, "HookServer failed to start: %{public}@", error.localizedDescription)
    // ← ここで stateMachine.start() / gazeController.startPolling() が呼ばれない
}
```

### 変更後

```swift
// HookServer 初期化・起動（UI 初期化とは独立）
do {
    try hookServer?.start()
    os_log(.info, "HookServer started")
} catch let error as HookServerError where error == .alreadyRunning {
    os_log(.error, "既に別インスタンスが起動中")
    NSApplication.shared.terminate(nil)
    return  // terminate 後の処理を明示的に停止
} catch {
    os_log(.fault, "HookServer failed to start: %{public}@", error.localizedDescription)
    // HookServer なしで続行（フック未受信だがマスコットとして最低限動作）
}

// UI 初期化（HookServer の成否に依存しない）
stateMachine.start()          // ① 初期フェーズ emit → setOverride / setBlinking
gazeController.startPolling() // ② polling 開始
```

### 変更点の詳細

1. **`stateMachine.start()` / `gazeController.startPolling()` を do-catch の外に移動**: HookServer の成否に関わらず常に実行される
2. **`.alreadyRunning` の catch に `return` を追加**: `NSApplication.shared.terminate(nil)` は非同期のため、return なしだと後続の `stateMachine.start()` が実行されてしまう。terminate 後の処理を明示的に停止する
3. **汎用 catch のログレベルを `.error` → `.fault` に昇格**: HookServer 起動失敗はフック未受信を意味する重大な問題。`.fault` で unified log に permanent 記録する

## ファイル構成

### 変更ファイル

| ファイル | 変更内容 |
|----------|---------|
| `src/Clabotch/AppDelegate.swift` | do-catch 構造変更（start/startPolling の移動、return 追加、ログレベル変更） |

### 変更なしのファイル

テスト追加なし（理由: AppDelegate のインスタンス化は headless 環境で不可。修正はコード配置の変更のみであり新規ロジックなし）

## テスト数

| 区分 | テスト数 |
|------|---------|
| 既存テスト | 195（194 passed, 1 skipped） |
| 新規テスト | 0 |
| **合計目標** | **195**（194 passed, 1 skipped） |

## 実装手順

1. `src/Clabotch/AppDelegate.swift` の do-catch 構造を変更
2. xcodegen generate + xcodebuild test で全テスト通過を確認
3. 計画書を completed に移動

## リスク

| リスク | 対策 |
|--------|------|
| terminate 後に start/startPolling が実行される | `.alreadyRunning` catch に `return` を追加して明示的に停止 |
| HookServer なしでの常駐がユーザーを混乱させる | `.fault` レベルのログで記録。将来的にユーザー通知 UI を追加可能 |
| 既存テストの回帰 | 修正はコード配置の変更のみ。195 件の既存テストで回帰確認 |
