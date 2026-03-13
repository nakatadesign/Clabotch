# 計画 014 — MultiSessionStateMachine（v0.3）

## 目的

設計書 v11 §12.3 に基づき、StateMachine を単一セッション所有権モデルから複数セッション並列追跡モデルに拡張する。

## 設計書参照

- §12.3: MultiSessionStateMachine スケルトン + displayPriority
- §9 v0.3: 複数セッション並列 + 作業時間表示（工数 3 日）
- §14.3: イベント処理ルール（ownership guard）

## 現行アーキテクチャ（変更前）

```
StateMachine (single-session)
├── session: SessionState?          ← 1 セッションのみ
├── displayPhase: MascotPhase
├── isOwned() → Bool               ← foreign を拒否
├── handleForeign()                 ← ephemeral done のみ
└── onPhaseChanged / onEphemeralDone
```

## 変更後アーキテクチャ

```
StateMachine (multi-session)
├── sessions: [String: SessionState]  ← 全セッション追跡
├── displayPhase: MascotPhase         ← min(displayPriority) で決定
├── handle(event:)                    ← 全セッションのイベントを受理
├── removeSession()                   ← done 後の auto-cleanup
└── onPhaseChanged / onEphemeralDone  ← 維持（ephemeral は廃止候補）
```

## displayPriority（§12.3 準拠）

| MascotPhase | priority | 説明 |
|-------------|----------|------|
| .error      | 0        | 最優先 |
| .working    | 1        | |
| .thinking   | 2        | |
| .done       | 3        | |
| .idle       | 4        | |
| .sleeping   | 5        | 最低 |

`displayPhase = sessions.values.map(\.phase).min { $0.displayPriority < $1.displayPriority } ?? .idle`

## 不変条件

1. **main thread only**: 全ての状態変更は main thread で実行（変更なし）
2. **displayPhase は常に最優先フェーズ**: sessions が空なら .idle
3. **session_start は常に受理**: 既存セッションの上書きではなく追加
4. **重複 session_start（同一 ID）は no-op**: 既存ルール維持
5. **session_done で該当セッションを削除**: displayPhase を再計算
6. **sleep タイマーは sessions が空 + displayPhase == .idle の場合のみ**

## 変更対象ファイル

| ファイル | 変更内容 |
|---------|---------|
| `StateMachine.swift` | sessions 辞書化、isOwned 廃止、displayPhase 再計算 |
| `StateMachineTests.swift` | 複数セッションシナリオのテスト追加 |
| `CoordinatorBinder.swift` | onEphemeralDone の扱い見直し（後方互換維持） |

## 実装ステップ

### Step 1: displayPriority 拡張（テスト先行）
- `MascotPhase` に `displayPriority: Int` computed property を追加
- 全 6 フェーズの優先度テスト

### Step 2: sessions 辞書化
- `session: SessionState?` → `sessions: [String: SessionState]`
- `session` computed property を追加（後方互換: 最優先セッションを返す）
- `isOwned()` を廃止、全セッションのイベントを受理
- `handleForeign()` を廃止（全セッションが "owned"）

### Step 3: displayPhase 再計算
- `displayPhase` を sessions から毎回計算
- `recalculateDisplayPhase()` メソッド抽出
- phase 変化時のみ `onPhaseChanged` を発火

### Step 4: auto-transition 改修
- error → thinking: 該当セッションのフェーズのみ変更、displayPhase を再計算
- done → idle: セッション削除、displayPhase を再計算
- epoch ガードをセッション単位に変更

### Step 5: sleep タイマー改修
- sessions が空 + displayPhase == .idle の場合のみタイマー開始
- 新セッション開始でタイマーキャンセル

### Step 6: onEphemeralDone の後方互換
- 全セッション追跡により "foreign" の概念がなくなる
- onEphemeralDone は session_done 時に常に発火（active session の done も含む）
- → 実質的に既存動作と同じ（BubbleWindow の通知は変わらない）

## リスク

| リスク | 対策 |
|--------|------|
| 既存 single-session テストが壊れる | session computed property で後方互換維持 |
| epoch ガードが複雑化 | セッション単位の epoch 管理に移行 |
| displayPhase が頻繁に切り替わる | 同一 priority なら先着を維持 |
| sleep タイマーの条件が複雑化 | sessions.isEmpty + displayPhase == .idle の 2 条件 |

## テスト計画

| テストケース | 期待動作 |
|-------------|---------|
| 単一セッション（既存全テスト） | 回帰なし |
| 2 セッション: A=thinking, B=working | displayPhase = .working |
| 2 セッション: A=error, B=working | displayPhase = .error |
| セッション A done → B のフェーズが displayPhase に | displayPhase = B.phase |
| 全セッション done → idle | displayPhase = .idle |
| 全セッション done → idle → sleep | sleep タイマー発火 |
| 重複 session_start（同一 ID） | no-op |
