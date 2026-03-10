# Clabotch 設計仕様書 — v6パッチ（受信スレッド境界 / nc timeout表現 / elapsed_ms=0方針）

> `clabotch_design_doc_v5_patch.md` への差分パッチ。  
> 本章は **§10.3 / §10.4 / §12.2 / §14.3** の補強を目的とする。  
> v5 と矛盾する場合は本章の内容を優先する。

---

## 修正一覧

| # | 優先度 | 対象 | v5 の残課題 | v6 の修正 |
|---|--------|------|-------------|-----------|
| 1 | P1 | §10.3 受信パイプライン | `EventDeduplicator` をメインスレッド専用と書きつつ、コード例ではバックグラウンド callback で呼んでいた | コンポーネントごとのスレッド所有権を定義し、`deduplicator` / `stateMachine` は必ず main に寄せる |
| 2 | P2 | §10.4 send_json | `nc -w 1` を「connect timeout + I/O timeout」と断定していた | BSD `nc` の実際の説明に合わせて「idle timeout」として記述を修正 |
| 3 | P2 | §12.2 / §14.3 | `foreign session_done(elapsed_ms == 0)` の扱いが曖昧 | active / foreign ごとに `elapsed_ms == 0` の表示方針を明文化 |

---

## 16. v6 修正詳細

### 16.1 受信パイプラインのスレッド境界を明示する

#### 問題

v5 では以下のような実装例になっていた。

```swift
connection.onData = { chunk in
    for line in decoder.append(chunk) {
        guard let envelope = EventParser.parse(line) else { continue }
        guard deduplicator.shouldAccept(envelope.eventID) else { continue }
        DispatchQueue.main.async {
            stateMachine.handle(event: envelope.event)
        }
    }
}
```

しかしこの形だと、`deduplicator.shouldAccept(...)` が  
**connection callback thread** 上で実行される。  
`EventDeduplicator` は「メインスレッド専用」と定義しているため、仕様とコード例が矛盾する。

#### v6 のスレッド所有権ルール

| コンポーネント | スレッド所有権 |
|---------------|----------------|
| `LineBufferedEventDecoder` | 接続ごとの serial queue 専用 |
| `EventParser` | pure function。任意スレッドで実行可 |
| `EventDeduplicator` | **メインスレッド専用** |
| `StateMachine` | **メインスレッド専用** |
| UI callback (`onPhaseChanged`, `onEphemeralDone`) | **メインスレッド専用** |

#### 修正方針

1. accepted connection ごとに **専用 serial queue** を持つ  
2. `decoder.append` と `EventParser.parse` はその接続 queue 上で実行  
3. `EventDeduplicator.shouldAccept` と `StateMachine.handle` は **まとめて main queue** へ渡す

#### 修正後のコード

```swift
// MARK: - §10.3 / §15.1 / §16.1 修正版 受信パイプライン

// グローバル共有（main thread only）
let deduplicator = EventDeduplicator()
// let stateMachine は AppDelegate / Coordinator から注入

func handleNewConnection(connection: UnixSocketConnection) {
    let decoder = LineBufferedEventDecoder()  // 接続ごと
    let connectionQueue = DispatchQueue(
        label: "com.clabotch.socket.\(UUID().uuidString)"
    )

    connection.onData = { chunk in
        connectionQueue.async {
            let lines = decoder.append(chunk)
            let envelopes = lines.compactMap(EventParser.parse)  // pure なのでここでOK

            DispatchQueue.main.async {
                for envelope in envelopes {
                    guard deduplicator.shouldAccept(envelope.eventID) else { continue }
                    stateMachine.handle(event: envelope.event)
                }
            }
        }
    }
}
```

#### 重要ルール

- `LineBufferedEventDecoder` を複数接続で共有しない
- 同一接続の `onData` は必ず同じ serial queue に流す
- `EventDeduplicator` と `StateMachine` は main thread 以外から触らない

> これで「接続単位の framing」と「main-thread only な状態管理」が両立する。

---

### 16.2 `send_json` の timeout 記述を BSD `nc` に合わせる

#### v5 の問題

v5 では `-w 1` を次のように説明していた。

```bash
# -w 1: connect タイムアウト + I/O アイドルタイムアウトを 1 秒に設定
```

しかし macOS 標準の BSD `nc` の `man nc` では、`-w timeout` は  
**「connection と stdin が idle なら閉じる」** という説明であり、  
厳密な connect-timeout を保証する表現ではない。

#### v6 の表現

`send_json` の仕様は次のように書き換える。

```bash
# best-effort 送信:
# - ソケットがなければ何もしない
# - `-w 1` は BSD nc の idle timeout を 1 秒に設定する
# - peer 不調時のぶら下がり時間を減らすための軽減策であり、
#   「厳密な connect timeout の保証」までは主張しない
send_json() {
  [[ -S "$SOCK" ]] || return 0
  nc -w 1 -U "$SOCK" >/dev/null 2>&1 || true
}
```

#### 仕様上の扱い

- MVP では `nc -w 1` を **best-effort の stall 軽減策** として使う
- 「絶対に 1 秒以内で返ること」を仕様保証しない
- strict な hard timeout が必要になった場合は、将来 `nc` をやめて小さな専用 sender に置き換える

> 設計書上の表現を弱めることで、実装より強い約束を書いてしまう問題を防ぐ。

---

### 16.3 `elapsed_ms == 0` の完了表示ポリシーを確定する

#### 背景

`elapsed_ms == 0` は主に次の2ケースで起こる。

1. ツール未使用セッションで `session_start` が観測できなかった
2. foreign session の `session_done` を軽量通知だけで扱う

v5 では foreign `session_done` に対して `elapsedMs > 0` のときだけ  
`onEphemeralDone` を出す実装例が入っていたが、  
active session 側との対比が文書上では明確ではなかった。

#### v6 の最終ポリシー

| ケース | 振る舞い |
|--------|----------|
| active session の `session_done(elapsed_ms > 0)` | 通常の done アニメ + 吹き出し `完了！(3分42秒)` |
| active session の `session_done(elapsed_ms == 0)` | 通常の done アニメ + 吹き出し `完了！` |
| foreign session の `session_done(elapsed_ms > 0)` | `onEphemeralDone` のみ。小さい吹き出し `別セッション完了 (1分12秒)` |
| foreign session の `session_done(elapsed_ms == 0)` | **無通知で破棄** |

#### 理由

- active session はユーザーが今見ている主体なので、`elapsed_ms == 0` でも完了演出を失わない
- foreign session はノイズ抑制を優先し、時間情報がない場合は黙って無視する

#### §12.2 への注記追加

`handleForeign(.sessionDone)` のコード例には以下のコメントを加える。

```swift
case .sessionDone(let id, let elapsedMs):
    // foreign completion は時間情報がある場合のみ軽量通知する
    // elapsedMs == 0 は silent drop（active session の表示を優先）
    debugLog("Foreign session_done -> ephemeral only: \(id)")
    guard elapsedMs > 0 else { return }
    DispatchQueue.main.async { [weak self] in
        self?.onEphemeralDone?(elapsedMs)
    }
```

#### 吹き出し文言規約

- active done
  - `elapsed_ms > 0` → `完了！(3分42秒)`
  - `elapsed_ms == 0` → `完了！`
- ephemeral done
  - `elapsed_ms > 0` → `別セッション完了 (1分12秒)`
  - `elapsed_ms == 0` → 表示しない

---

## v6 適用後の読み替え

| 章 | v6 での読み替え |
|----|-----------------|
| §10.3 | `EventParser` までは接続 queue、`EventDeduplicator` 以降は main thread |
| §10.4 | `nc -w 1` は idle timeout の best-effort 軽減策 |
| §12.2 | ownership-first guard は有効のまま、foreign `elapsed_ms == 0` は silent drop |
| §14.3 | `onEphemeralDone` は `elapsed_ms > 0` の foreign completion のみ対象 |

---

## 実装可否の判断

この v6 を反映すれば、設計書レベルで残っていた矛盾はほぼ解消される。  
次に確認すべきは引き続き **hook 環境変数の実機確認** で、  
そこが確定すれば PoC 実装に入ってよい。

---

*v6 patch — 2026-03-10*  
*Clabotch — MIT License*
