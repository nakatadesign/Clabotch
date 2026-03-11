# patch_004: onPhaseChanged の同期呼び出し

## 対象

v11 §12.2 `StateMachine.transition(to:)` 内の `onPhaseChanged` 配信方法

## 正典（v11）

```swift
// L1111
DispatchQueue.main.async { [weak self] in self?.onPhaseChanged?(phase) }
```

## 変更後

```swift
// StateMachine.swift L168
onPhaseChanged?(phase)
```

`transition(to:)` 内で `onPhaseChanged` を**同期呼び出し**する。`DispatchQueue.main.async` を介さない。
`start()` も同様（L54: `onPhaseChanged?(displayPhase)`）。

## 理由

`StateMachine` は main thread 専用（`dispatchPrecondition(condition: .onQueue(.main))`）であり、`onPhaseChanged` の購読者（AppDelegate の Coordinator callback）も main thread 上で動作する。同一 thread 上での `main.async` は不要な 1-tick 遅延を導入するだけで、安全性に寄与しない。

同期呼び出しにより:
- `handle(event:)` の呼び出し元が、戻り時点で下流コンポーネントの更新完了を保証できる
- テストで `handle(event:)` 直後の状態検証が決定的になる
- auto-transition の `asyncAfter` callback 内でも `transition(to:)` → `onPhaseChanged` は同期的に完了する

## 影響範囲

- `StateMachine.swift`: `transition(to:)`, `start()`
- テスト: `handle(event:)` 直後に下流状態を検証可能（ただし auto-transition / onEphemeralDone は別途非同期待機が必要）

## 承認

計画 004（StateMachine コア実装）で Codex Grade A 取得済み。実装は v11 疑似コードと異なるが動作は同等。
