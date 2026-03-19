# Patch 016: Multi-Session 正式対応

## 概要

v11 §12.2 の単一セッション StateMachine を、v11 §12.3 のスケルトンに基づく
複数セッション並列追跡に正式昇格する。

## v11 からの逸脱

| # | 内容 | v11 正典 | 本パッチ | 理由 |
|---|------|---------|----------|------|
| 1 | StateMachine のセッション管理 | 単一セッション（§12.2） | sessions: [String: SessionState] | Claude Code を複数ターミナルで同時使用するケースに対応 |
| 2 | foreign session の扱い | ephemeral done 通知のみ（§14.3） | 全セッションを等価に追跡 | ownership guard は不要（全セッションの状態を保持する方が自然） |

## 仕様

### StateMachine.sessions

- `sessions: [String: SessionState]` で全セッションを保持する
- 各セッションは独立した `SessionState`（phase, startedAt, lastEventAt）を持つ
- セッション単位で epoch / pendingTransition を管理し、レース条件を防ぐ

### displayPhase の決定

```
displayPhase = sessions.values
    .min { a, b in
        if a.phase.displayPriority != b.phase.displayPriority {
            return a.phase.displayPriority < b.phase.displayPriority
        }
        return a.startedAt < b.startedAt
    }
    ?.phase ?? .idle
```

同一 displayPriority の場合は `startedAt` が早い方を選択する（決定的な順序を保証）。

### displayPriority 一覧（値が小さいほど優先）

| フェーズ | displayPriority |
|---------|----------------|
| error | 0 |
| working | 1 |
| responding | 2 |
| thinking | 3 |
| done | 4 |
| idle | 5 |
| sleeping | 6 |

### 吹き出しの [+N] サフィックス

- sessions.count が 2 以上の場合、吹き出し文言に ` [+N]` を付加する
- N = sessions.count - 1（表示中のセッション以外の数、done 保持中を含む）
- 例: "考えてます... [+2]"
- セッション数が変化するたびに吹き出しテキストを再評価する（onSessionCountChanged）
- idle/sleeping では吹き出しなし（[+N] も表示しない）

### foreign session_done の ephemeral 通知

- 追跡中のセッションが session_done を受信したとき、displayPhase が .done にならない場合
  （より高優先のセッションが表示中）、ephemeral bubble で通知する
- ephemeral 通知は elapsedMs > 0 のときのみ（§14.3 と同一）
- 表示: "別セッション完了 (3分42秒)"、duration: 2.0 秒
- activeBubble 表示中は下にオフセットして重なりを回避

### 未追跡セッションの session_done

- sessions に存在しないセッション ID の session_done は ephemeral 通知のみ（ms > 0 の場合）
- sessions への追加はしない

### session_done 後のセッション削除

- session_done 受信後、doneAutoTransitionDelay（4.0 秒）後にセッションを削除する
- 削除後 sessions が空になれば displayPhase は .idle に遷移する

### sleeping / wake の条件

| 条件 | 動作 |
|------|------|
| sessions.isEmpty + displayPhase == .idle + sleepThreshold 経過 | sleeping に遷移 |
| sleeping 中に session_start | sleeping → idle → 新セッション追加 → recalculate |
| ターミナルクリック等の外部トリガー | wakeFromSleep() → idle、sleep タイマー再スケジュール |

### コールバック

| コールバック | 発火条件 |
|-------------|---------|
| onPhaseChanged | displayPhase が変化したとき |
| onSessionCountChanged | sessions.count が変化したとき |
| onEphemeralDone | 非プライマリセッション完了 + elapsedMs > 0 |

## 実装コミット

- `d978474`: 計画 014 MultiSessionStateMachine 実装
