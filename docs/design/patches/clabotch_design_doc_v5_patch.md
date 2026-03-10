# Clabotch 設計仕様書 — v5パッチ（3点バグ修正）

> `clabotch_design_doc_v4.md` への差分パッチ。  
> 本章は **§10.3 / §10.4 / §12.2** の修正を目的とする。  
> v4 と矛盾する場合は本章の内容を優先する。

---

## 修正一覧

| # | 優先度 | 対象 | 問題 | 修正 |
|---|--------|------|------|------|
| 1 | P1 | §10.3 受信パイプライン | `LineBufferedEventDecoder` をグローバル1個で使うと別接続の bytes を連結して壊す | 接続ごとに decoder を生成する |
| 2 | P1 | §12.2 StateMachine | foreign event が来ると ownership guard より先に `pendingTransition.cancel()` / `transitionEpoch &+= 1` が走り、active session の遅延遷移を壊す | ownership 判定を先頭に移動し、受理したイベントにのみ副作用を適用する |
| 3 | P2 | §10.4 send_json | `nc -U` にタイムアウトなし。Clabotch 不調時に Claude Code の hook を無限待ちさせる余地がある | `nc -w 1` で 1 秒打ち切りを明記する |

---

## 15. v5 修正詳細

### 15.1 LineBufferedEventDecoder のスコープ（§10.3 修正）

#### 問題

`nc` は 1 イベントを送って即 EOF する（`printf ... | nc -U sock`）。  
これは「1 接続 = 1 メッセージ」を意味するが、  
**グローバル 1 個の decoder を複数接続で共有すると**、  
接続 A の断片読み中に接続 B の bytes が来たとき両者が連結されて壊れる。

#### 修正方針

`nc` の実際の動作（1接続 = EOFまで = 1イベント）に合わせた設計：

- **接続ごとに `LineBufferedEventDecoder` を生成する**
- `EventDeduplicator` と `StateMachine` は引き続きグローバル 1 個（複数接続をまたいだ用途のため）

#### 修正後の受信パイプライン

```
HookServer.accept() ループ
    ├─ 接続 A
    │    └─ LineBufferedEventDecoder (接続Aのみ) ← 接続ごとに新規生成
    │         └─ EventParser
    │              └─ EventDeduplicator (グローバル) ← 共有OK
    │                   └─ StateMachine (グローバル) ← 共有OK
    └─ 接続 B
         └─ LineBufferedEventDecoder (接続Bのみ) ← 接続ごとに新規生成
              └─ EventParser → EventDeduplicator → StateMachine（同上）
```

#### 修正後のコード

```swift
// MARK: - §10.3 修正版 受信パイプライン
//
// ⚠️ スレッドセーフ注意:
//   - LineBufferedEventDecoder : 接続ごとに生成（共有しない）
//   - EventDeduplicator        : グローバル1個（メインスレッド専用）
//   - StateMachine             : グローバル1個（メインスレッド専用）
//   HookServer がバックグラウンドスレッドで accept する場合、
//   EventParser 以降は DispatchQueue.main.async で wrap する

// ✅ グローバルに持つもの（接続をまたぐ状態を管理するため）
let deduplicator = EventDeduplicator()   // グローバル: OK
// let stateMachine は AppDelegate 等から渡す

// ✅ accept ループの実装イメージ
func handleNewConnection(connection: UnixSocketConnection) {
    // ← 接続ごとに新規生成（他の接続と共有しない）
    let decoder = LineBufferedEventDecoder()

    connection.onData = { chunk in
        // nc は 1 イベント送って EOF するため、
        // 実質 1 接続 = 1 行 = 1 イベントになることがほとんど。
        // ただし将来的な拡張（複数イベントを 1 接続で送る）にも対応できる。
        for line in decoder.append(chunk) {
            guard let envelope = EventParser.parse(line) else { continue }
            guard deduplicator.shouldAccept(envelope.eventID) else { continue }
            DispatchQueue.main.async {
                stateMachine.handle(event: envelope.event)
            }
        }
    }
}
```

> **廃止**: §10.3 にあった `let decoder = LineBufferedEventDecoder()` のグローバル宣言は削除する。

---

### 15.2 StateMachine — ownership を先頭で判定（§12.2 修正）

#### 問題の再現シナリオ

```
① active session A で error 発生
   → scheduleAutoTransition(to: .thinking, after: 2.5, sessionID: A)
   → pendingTransition に error→thinking 遷移を予約

② 2.0 秒後：foreign session B の tool_start が来る

③ handle(event: .toolStart(B, "Write")) が呼ばれる
   ↓
   transitionEpoch &+= 1      ← ❌ A のエポックを書き換える
   pendingTransition?.cancel() ← ❌ A の error→thinking 遷移をキャンセル
   resetSleepTimer()
   ↓
   guard isActiveSession(B) → false → return

④ 結果: セッション A は error フェーズのまま永久に復帰しない
```

#### 修正方針

**ownership 判定（副作用ゼロ）を必ず先頭で行い、**  
**受理確定したイベントにのみ `transitionEpoch &+= 1` / `pendingTransition?.cancel()` / `resetSleepTimer()` を適用する。**

#### 修正後の StateMachine 全文

```swift
// MARK: - StateMachine.swift  (v5: ownership-first guard)
// 変更点: handle() の先頭で isOwned() を判定し、
//         副作用（epoch/cancel/sleepReset）は受理イベントにのみ適用する

final class StateMachine {

    private(set) var session: SessionState?
    private(set) var displayPhase: MascotPhase = .idle

    private var sleepTimer: Timer?
    private var pendingTransition: DispatchWorkItem?
    private var transitionEpoch: UInt = 0
    private let sleepThreshold: TimeInterval = 300

    var onPhaseChanged: ((MascotPhase) -> Void)?
    var onEphemeralDone: ((Int) -> Void)?

    // MARK: - Public

    func handle(event: ClabotchEvent) {

        // ── Step 1: ownership 判定（副作用ゼロ）──────────────────────────
        // foreign event は handleForeign に転送して即 return する。
        // ここより下の副作用（epoch/cancel/sleep）には一切触れない。
        guard isOwned(event) else {
            handleForeign(event)
            return
        }

        // ── Step 2: 受理確定後にのみ副作用を適用 ────────────────────────
        transitionEpoch &+= 1
        pendingTransition?.cancel()
        pendingTransition = nil
        resetSleepTimer()

        // ── Step 3: 状態遷移（ownership 確定済み）───────────────────────
        switch event {

        case .sessionStart(let sessionID):
            if session == nil {
                session = SessionState(
                    sessionID: sessionID,
                    phase: .thinking,
                    startedAt: Date(),
                    lastEventAt: Date()
                )
            }
            transition(to: .thinking)

        case .toolStart(let sessionID, let toolName):
            session?.lastEventAt = Date()
            session?.phase = .working(toolName: toolName)
            transition(to: .working(toolName: toolName))

        case .toolEnd(let sessionID, let toolName, _, let isError, let errorMessage):
            session?.lastEventAt = Date()
            if isError {
                let p = MascotPhase.error(toolName: toolName, message: errorMessage)
                session?.phase = p
                transition(to: p)
                scheduleAutoTransition(to: .thinking, after: 2.5, expectedSessionID: sessionID)
            } else {
                session?.phase = .thinking
                transition(to: .thinking)
            }

        case .sessionDone(_, let elapsedMs):
            session = nil
            transition(to: .done(elapsedMs: elapsedMs))
            scheduleAutoTransition(to: .idle, after: 4.0, expectedSessionID: nil)

        case .unknown:
            break
        }
    }

    // MARK: - Ownership

    /// イベントがこの StateMachine の active session に属するか判定する（副作用ゼロ）
    private func isOwned(_ event: ClabotchEvent) -> Bool {
        switch event {
        case .sessionStart(let id):
            // session が nil（idle）か、同じ session ID のみ受理
            return session == nil || session?.sessionID == id
        case .toolStart(let id, _):
            return isActiveSession(id)
        case .toolEnd(let id, _, _, _, _):
            return isActiveSession(id)
        case .sessionDone(let id, _):
            return isActiveSession(id)
        case .unknown:
            return false
        }
    }

    /// foreign イベントの処理（フェーズ遷移しない）
    private func handleForeign(_ event: ClabotchEvent) {
        switch event {
        case .sessionDone(let id, let elapsedMs):
            // foreign の完了だけは ephemeral 通知を出す（elapsed_ms > 0 のみ）
            debugLog("Foreign session_done -> ephemeral only: \(id)")
            guard elapsedMs > 0 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onEphemeralDone?(elapsedMs)
            }
        case .sessionStart(let id):
            debugLog("Ignoring foreign session_start: \(id)")
        case .toolStart(let id, _):
            debugLog("Ignoring foreign tool_start: \(id)")
        case .toolEnd(let id, _, _, _, _):
            debugLog("Ignoring foreign tool_end: \(id)")
        case .unknown:
            break  // unknown は元々無視
        }
    }

    // MARK: - Private helpers

    private func isActiveSession(_ id: String) -> Bool {
        session?.sessionID == id
    }

    private func transition(to phase: MascotPhase) {
        guard displayPhase != phase else { return }
        displayPhase = phase
        DispatchQueue.main.async { [weak self] in self?.onPhaseChanged?(phase) }
    }

    private func scheduleAutoTransition(
        to phase: MascotPhase,
        after delay: TimeInterval,
        expectedSessionID: String?
    ) {
        let epoch = transitionEpoch
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.transitionEpoch == epoch else { return }
            guard expectedSessionID == nil
               || self.session?.sessionID == expectedSessionID
            else { return }
            self.transition(to: phase)
        }
        pendingTransition = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func resetSleepTimer() {
        sleepTimer?.invalidate()
        if displayPhase == .sleeping {
            transition(to: session != nil ? .thinking : .idle)
        }
        guard session == nil else { return }
        sleepTimer = Timer.scheduledTimer(withTimeInterval: sleepThreshold, repeats: false) { [weak self] _ in
            guard self?.session == nil else { return }
            self?.transition(to: .sleeping)
        }
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[Clabotch StateMachine] \(message)")
        #endif
    }
}
```

#### 修正の核心点まとめ

```
修正前:
  handle() {
    transitionEpoch &+= 1   ← 先に副作用
    cancel()                ← 先に副作用
    resetSleepTimer()       ← 先に副作用
    switch event {
      guard isActiveSession() else { return }  ← あとで無視
    }
  }

修正後:
  handle() {
    guard isOwned() else { handleForeign(); return }  ← 先に判定（副作用ゼロ）
    transitionEpoch &+= 1   ← 受理確定後のみ副作用
    cancel()                ← 受理確定後のみ副作用
    resetSleepTimer()       ← 受理確定後のみ副作用
    switch event { ... }    ← 状態遷移
  }
```

---

### 15.3 send_json のタイムアウト（§10.4 修正）

#### 問題

```bash
send_json() {
  [[ -S "$SOCK" ]] || return 0
  nc -U "$SOCK" >/dev/null 2>&1 || true   # ← タイムアウトなし
}
```

Clabotch が落ちている / ソケットを accept しないでいる場合、  
`nc` が接続待ちで無限に止まる。  
Claude Code の hook 実行スレッドを止めるため、操作感に直接影響する。

#### 修正後

```bash
send_json() {
  [[ -S "$SOCK" ]] || return 0
  # -w 1: connect タイムアウト + I/O アイドルタイムアウトを 1 秒に設定
  # Clabotch が不調でも hook を 1 秒以上止めない
  nc -w 1 -U "$SOCK" >/dev/null 2>&1 || true
}
```

> macOS 標準 nc（BSD nc）の `-w timeout` は  
> 「接続確立タイムアウト」と「I/O アイドルタイムアウト」の両方に適用される。

#### 修正後の共通 helper 全文（clabotch_lib.sh）

```bash
#!/usr/bin/env bash
# ~/.claude/hooks/clabotch_lib.sh
# v5: send_json に -w 1 タイムアウト追加

SOCK="${TMPDIR}clabotch.sock"
SESSION_REGISTRY="${TMPDIR}clabotch_sessions"

generate_uuid() {
  uuidgen | tr '[:upper:]' '[:lower:]'
}

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# best-effort 送信: ソケットなし or タイムアウト(1秒) or エラーは全て黙って無視
send_json() {
  [[ -S "$SOCK" ]] || return 0
  nc -w 1 -U "$SOCK" >/dev/null 2>&1 || true
}
```

---

## v5 全修正適用後の仕様ステータス

| 章 | 状態 | v5での変更 |
|----|------|-----------|
| §10.3 受信パイプライン | ✅ 修正済み | decoder を接続ごとに生成することを明記 |
| §10.4 send_json | ✅ 修正済み | `-w 1` タイムアウト追加 |
| §12.2 StateMachine | ✅ 修正済み | ownership-first guard に変更。`isOwned()` / `handleForeign()` を分離 |
| 上記以外 | ✅ v4 のまま有効 | 変更なし |

---

## 実装可否の判断

この v5 パッチを適用した時点で、設計書レベルの既知バグはゼロになる。  
次のステップは **hook 環境変数の実機確認**（§13.7 / §14.5 の順序 1）であり、  
その結果次第で hook スクリプトの変数名のみ調整が必要になる可能性がある。

---

*v5 patch — 2026-03-10*  
*Clabotch — MIT License*
