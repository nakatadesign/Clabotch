# 実装計画 002: Xcode プロジェクト作成 + HookServer + LineBufferedEventDecoder

## 概要

設計書 v11 §7, §10.3, §14.1 に基づき、macOS アプリの最小骨格と HookServer の受信パイプライン（LineBufferedEventDecoder まで）を実装する。MVP の一部完了として位置づける。

## 前提条件（設計書との差分）

`clabotch_pre_tool.sh` は設計書 v11 §10.4 のコードから以下を変更済み（hook 実装フェーズで Codex レビュー A 取得済み）:
- session_start + tool_start を **1つの nc 接続で NDJSON 連結送信** に変更（順序保証）
- session_id バリデーション（`validate_session_id`）追加
- send_json の3値戻り値（0=成功/1=socket不在/2=nc失敗）で marker 作成を制御

**socket パスの変更:** 設計書 v11 では `$TMPDIR/clabotch.sock` だが、本計画では `$TMPDIR/clabotch/hook.sock`（専用ディレクトリ方式）に変更する。hook スクリプト側の `SOCK` 変数も本フェーズで同時に更新し、HookServer と hook スクリプトのパスを一致させる（原子的移行）。これにより E2E 経路の検証が可能になる。

設計書 v11 は変更しない方針のため、実装上の差分はこの計画と HANDOVER.md で管理する。
差分の追補は `docs/design/patches/` にも記録し、将来のレビューで見落としを防ぐ。

**差分管理:**
- 正典は `docs/design/current/clabotch_design_doc_v11.md` のみ。
- 実装上の逸脱（socket path 変更等）は `docs/design/patches/` に patch 文書として記録する。patch 文書は正典の特定項目に対する **承認済み例外** であり、正典自体の優先順位を変えるものではない。
- `docs/exec-plans/active/` の実装計画は正典 + patch を具体化した実装詳細であり、仕様決定権を持たない。
- patch が蓄積した場合は v12 として正典に統合する。

**記録すべき patch 項目（設計書 v11 との差分）:**
1. socket path 変更: `$TMPDIR/clabotch.sock` → `$TMPDIR/clabotch/hook.sock`
2. `send_json` の3値戻り値（0/1/2）による marker 作成制御（設計書には未定義）
3. `clabotch_pre_tool.sh` の session_start + tool_start 連結送信（設計書 §10.4 は別送信）
4. lossy 順序保証方針（tool_end/session_done の順序逆転を許容、StateMachine で吸収）
5. session_id バリデーション（`validate_session_id` による `.`/`..`/スラッシュ/改行/クォート拒否）

**実装開始前のゲート（前提条件）:**
- [ ] socket path 変更の patch 文書を `docs/design/patches/` に作成済み
- [ ] `ARCHITECTURE.md` に patch 文書の参照方法を追記済み
- 上記2点を完了してから Step 1 に着手する。

## スコープ

**含む:**
- Xcode プロジェクト（SwiftUI + AppKit hybrid、メニューバー常駐）
- Unix domain socket の accept ループ（HookServer）
- 接続ごとの serial queue 生成
- LineBufferedEventDecoder（NDJSON framing、oversize line 完全破棄）
- ビルド確認 + 単体テスト + 統合テスト

**含む（追加）:**
- Hook スクリプトの SOCK パス更新（`hooks/clabotch_lib.sh` の `SOCK` 変数を `$TMPDIR/clabotch/hook.sock` に変更）
- **注記:** `SESSION_REGISTRY` は `$TMPDIR/clabotch_sessions` のまま変更しない。理由: SESSION_REGISTRY は HookServer と直接関係しない hook 側の内部状態管理であり、socket path 変更と同時に移行する必要はない。将来 `$TMPDIR/clabotch/` 名前空間に統合する場合は別 patch で対応する。
- Hook E2E テスト（repo 内 `hooks/` の作業コピーを使用。テスト対象: happy path 送受信 + socket 不在時 no-op + nc 失敗時 marker 抑止。実デプロイ済み `~/.claude/hooks/` は対象外）

**socket path 変更の影響範囲（本フェーズで更新するファイル）:**
1. `hooks/clabotch_lib.sh` — `SOCK` 変数を `$TMPDIR/clabotch/hook.sock` に変更
2. `tests/test_hooks.sh` — `MOCK_SOCK` を新パスに変更 + `$TMPDIR/clabotch/` ディレクトリの事前作成を追加
3. `README.md` — Planned Architecture セクションの socket path を更新
4. `public-repo-template/docs/troubleshooting.md` — ソケットパスの確認手順を更新
5. `docs/ARCHITECTURE.md` — データフロー図の socket path を更新（正典は v11 のまま。ARCHITECTURE.md は要約なので計画に合わせる）

**含まない:**
- EventParser / EventDeduplicator / StateMachine（次フェーズ）
- ClabotchEyeView 描画
- GazeController / BubbleWindow
- Hook スクリプトの `~/.claude/hooks/` へのデプロイ（手順は既知。本フェーズでは `hooks/` 内の作業コピーのみ更新）

## ディレクトリ構成

```
src/
├── Clabotch.xcodeproj/
├── Clabotch/
│   ├── ClabotchApp.swift              # @main、NSApplicationDelegateAdaptor
│   ├── AppDelegate.swift              # NSStatusItem 生成、HookServer 起動
│   ├── HookServer.swift               # Unix domain socket accept ループ
│   ├── SocketOps.swift                # POSIX syscall ラッパー protocol + RealSocketOps
│   └── LineBufferedEventDecoder.swift
└── ClabotchTests/
    ├── LineBufferedEventDecoderTests.swift
    └── HookServerTests.swift
```

## 実装ステップ

### Step 1: Xcode プロジェクト作成

- Swift Package Manager ベース（`Package.swift`）ではなく Xcode プロジェクトを使用
- macOS 13+ ターゲット
- App Sandbox: OFF（Unix domain socket アクセスのため）
- LSUIElement = YES（Dock に表示しない）
- `ClabotchApp.swift`: `@main` + `NSApplicationDelegateAdaptor` で `AppDelegate` を接続
- `AppDelegate.swift`:
  - `NSStatusItem` を作成してメニューバーに「C」を表示（最小動作確認用）
  - メニューに「Quit Clabotch」項目を追加（`applicationWillTerminate` の検証用）
  - `applicationDidFinishLaunching` で HookServer を初期化:
    - `onLines` に `os_log(.info, "受信: %d 行, %d bytes", lines.count, totalBytes)` のみを出力するクロージャを渡す（件数と byte 数のみ。**raw preview は出力しない** — transport 層で session_id やイベント内容をログに流出させるリスクを排除。完了条件「Xcode コンソールにログが出る」は件数ログで確認可能）
    - `onListenerFailure` に `os_log(.fault, "HookServer listener が停止: %@")` を渡す（init パラメータとして注入）
    - `HookServer.start()` を `do/catch` で呼び出し:
      - 成功時: `os_log(.info, "HookServer started")`
      - 失敗時: エラー種別で分岐:
        - `HookServerError.alreadyRunning` → `os_log(.error, "既に別インスタンスが起動中")` + `NSApplication.shared.terminate(nil)` で即終了（受信不能なゴーストインスタンスの起動を防止）
        - その他 → `os_log(.error, "HookServer failed to start: %@", error.localizedDescription)` でログ出力し、**アプリは継続する**（メニューバーアイコンは表示するが、hook イベントは受信できない状態）。PoC 段階では socket 以外のエラーでアプリ終了しない方針。
  - `applicationWillTerminate` で `HookServer.terminateSync()`（socket 残骸防止）。`terminateSync()` は listen socket の `shutdown` + `close` + `unlink` を **main thread で同期的に即座実行** する。controlQueue の drain や completion は待たない（プロセス終了で OS が fd を回収するため不要）。これにより socket ファイルの残骸を確実に防止する。

### Step 2: HookServer 実装

設計書 §10.3 の疑似コードに準拠 + generation token + stateQueue による排他制御。

#### POSIX ラッパー（テスト注入点）

syscall の異常系テストを可能にするため、薄い protocol を導入する:

```swift
protocol SocketOps {
    func socket(_ domain: Int32, _ type: Int32, _ proto: Int32) -> Int32
    func bind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32
    func listen(_ fd: Int32, _ backlog: Int32) -> Int32
    func accept(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: UnsafeMutablePointer<socklen_t>?) -> Int32
    func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ nbyte: Int) -> Int
    func close(_ fd: Int32) -> Int32
    func connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32
    func shutdown(_ fd: Int32, _ how: Int32) -> Int32
}
```

- **`RealSocketOps`**: 本番用。POSIX syscall を直接呼ぶ。`struct` で zero-cost。`shutdown` も含む。
- **`MockSocketOps`**: テスト用。errno や戻り値を注入可能。`bind(EADDRINUSE)`、`accept(EMFILE)`、`read(EBADF)`、`shutdown` 等の異常系テストに使用。
- HookServer の `init` に `socketOps: SocketOps = RealSocketOps()` としてデフォルト注入。テスト時のみ mock を渡す。
- **HookServer 内の全 POSIX 呼び出し（Connection.closeOnce() 含む）は `socketOps` 経由で行う。** 直接 `Darwin.close()` や `Darwin.shutdown()` を呼ぶことは禁止。Connection は init で `socketOps` 参照を受け取り、closeOnce() 内で使用する。
- protocol は薄く保ち、`chmod`/`fcntl`/`lstat`/`unlink` はファイルシステム操作のため対象外（テストではファイルシステムを直接操作する）。ただし `fcntl(FD_CLOEXEC)` 失敗時は `os_log(.error)` で記録し、**処理は続行する**（FD_CLOEXEC の設定失敗は fork しない限り影響なく、致命的ではないため）。
- **backoff テスト用 seam:** `accept(EMFILE)` 時の `usleep` を `sleeper: (useconds_t) -> Void = { usleep($0) }` として init 注入する。テスト時は no-op sleeper を渡して deterministic に検証する。

#### ソケットパスとディレクトリ

socket ファイルは専用ディレクトリ `$TMPDIR/clabotch/` 内に配置する:

```
$TMPDIR/clabotch/          ← mkdir 0700 or 既存検証
  └── hook.sock            ← chmod 0600
```

**socketDir の検証手順:**
1. `lstat(socketDir)` で存在確認
2. 既存の場合:
   - `S_ISDIR` でディレクトリであることを確認（symlink / 通常ファイルなら throw）
   - `st_uid == getuid()` で owner 確認（自分以外が所有なら throw）
   - `(st_mode & 0o777) == 0o700` でパーミッション確認（`0700` でなければ throw）
3. 存在しない場合（`ENOENT`）:
   - `mkdir(socketDir, 0o700)` で作成
   - `mkdir` が `EEXIST` で失敗 → 同時起動による race。ステップ 1 に戻り `lstat` で再検証（既に別インスタンスが作成した可能性）
   - `mkdir` がその他の errno で失敗 → `throw HookServerError.mkdirFailed(errno)`

**stale socket の live 判定:**
- `lstat` 失敗時: `ENOENT` → socket なしとして続行（bind で新規作成）。その他 → `throw HookServerError.statFailed(path: socketPath, errno:)`
- `lstat` 成功 → socket 型確認 + `st_uid == getuid()` で owner 確認（他ユーザー所有なら throw）後、`connect()` probe で live 判定:
  - probe 用 fd は `socket(AF_UNIX, SOCK_STREAM, 0)` で作成。**socket() 失敗時は `throw HookServerError.probeSocketCreationFailed(errno:)`**。成功後は **`defer { socketOps.close(probeFd) }` で確実に close** する（分岐内で個別に close しない。defer が唯一の close パス）。
  - `connect()` 成功 → live socket → `throw HookServerError.alreadyRunning`（defer で close。同一ユーザー多重起動防止）
  - `connect()` 失敗（`ECONNREFUSED`） → stale socket → `unlink` して続行（defer で close）。`unlink` 失敗時は `ENOENT`（別プロセスが先に削除）なら続行、その他は `throw HookServerError.unlinkFailed(path: socketPath, errno:)`
  - `connect()` 失敗（`ENOENT`） → socket ファイルが消えた（別プロセスが unlink した可能性）→ stale 判定不要、そのまま続行（defer で close。bind で socket を新規作成）
  - `connect()` 失敗（その他の errno） → 原因不明のため `throw HookServerError.socketProbeError(errno)`（defer で close。安全側に倒す）

#### 同期モデル

`HookServer` の可変状態は複数スレッドからアクセスされるため、以下の同期方針を採用する:

| 状態 | アクセス元 | 保護方法 |
|------|-----------|---------|
| `generation` | main thread（書き込み）、acceptQueue（読み取り）、connectionQueue（読み取り） | `stateQueue.sync {}` で読み書き |
| `listenSocket` | main thread のみ（acceptQueue では closure capture list でキャプチャした値を使用。acceptQueue 上で `self.listenSocket` を読むことは禁止） | `dispatchPrecondition(.onQueue(.main))` + closure capture list |
| `activeConnections` | main thread + connectionQueue | `connectionsLock`（NSLock） |
| `isShuttingDown` | main thread（performTeardown 内）+ acceptQueue（handleNewConnection 内） | `connectionsLock`（NSLock） |
| `onLines` | init 時に設定、connectionQueue から呼び出し | init 注入（let）で不変。nonblocking 契約 |
| `lifecycleState` | main thread のみ | main thread serialization（stopped/running/stopping/faulted） |
| `pendingStopCompletions` | main thread のみ | main thread serialization |
| `onListenerFailure` | init 時に設定、main thread で呼ばれる | init 注入（let）で不変 |
| `acceptGroup` | main thread（enter: start 内, wait: stop 内）、acceptQueue（leave） | DispatchGroup のスレッドセーフ API |

`stateQueue` は `generation` の読み書き専用の serial queue。`acceptQueue` や `connectionQueue` から `stateQueue.sync { generation }` で安全に読む。`stop()` は main thread から `stateQueue.sync { generation &+= 1 }` で書き込む。

**`onLines` の実行境界（正典 §10.3 準拠）:**
- `onLines` は **connectionQueue 上で直接呼ぶ**（正典のデータフローと一致）
- `onLines` の API 契約:
  - **nonblocking であること**（長時間ブロック禁止）
  - **`DispatchQueue.main.sync {}` 禁止**（`stop()` の `controlQueue` 上の `connectionGroup.wait()` とは直接 deadlock しないが、main thread の応答性を損なうため禁止）
  - この契約は init の doc comment + `onLines` パラメータの naming convention で強制する
- 次フェーズで EventParser を組み込む際は、parse まで connectionQueue で完結させ、`DispatchQueue.main.async {}` 経由で main thread に渡す（設計書 §10.3 準拠。接続ごとの serial queue を維持し、head-of-line blocking を防止）

```swift
/// HookServer のエラー型。switch で網羅的に処理可能。Equatable 準拠。
enum HookServerError: Error, Equatable {
    // ライフサイクル
    case alreadyRunning                     // live socket 検出（同一ユーザー多重起動）
    case faulted                            // timeout 後の faulted state
    case stopping                           // stop() 処理中に start() が呼ばれた
    // socket 作成
    case socketCreationFailed(errno: Int32) // socket() syscall 失敗
    case bindFailed(errno: Int32)           // bind 失敗（EADDRINUSE 含む）
    case listenFailed(errno: Int32)         // listen() 失敗
    case chmodFailed(errno: Int32)          // chmod() 失敗
    // socket ディレクトリ
    case mkdirFailed(errno: Int32)          // socketDir の mkdir 失敗
    case socketDirInvalid(reason: SocketDirInvalidReason)  // socketDir が不正
    // ファイルシステム操作
    case statFailed(path: String, errno: Int32)   // lstat() 失敗
    case unlinkFailed(path: String, errno: Int32) // unlink() 失敗
    // probe
    case socketProbeError(errno: Int32)     // connect() probe で予期しない errno
    case probeSocketCreationFailed(errno: Int32) // probe 用 socket() 失敗
    // パス
    case pathTooLong                        // sun_path 104 byte 超過
}

/// socketDir が不正な理由（stringly typed を排除）。Equatable 準拠。
enum SocketDirInvalidReason: Equatable {
    case notDirectory              // symlink / 通常ファイル
    case wrongOwner(uid: uid_t)    // 他ユーザー所有
    case wrongPermissions(mode: mode_t)  // 0700 でない
}

/// teardown の理由（2ケースのみ。timeout は performTeardown 内部で判定）
enum TeardownReason {
    case normalStop
    case listenerFailure(Error)
}

/// HookServer のエラー型に Equatable 準拠（テストで XCTAssertEqual 可能）
/// associated value が Equatable な型のみなので自動合成可能

final class HookServer {
    private let socketPath: String
    private let socketDir: String               // 専用ディレクトリ（0700）
    private let onLines: ([Data]) -> Void       // init 注入。不変。connectionQueue 上で呼ばれる。nonblocking 必須。
    private let onListenerFailure: (Error) -> Void  // init 注入。不変。main thread で呼ばれる。
    private var listenSocket: Int32 = -1         // main thread 専用
    /// ライフサイクル状態（main thread 専用）
    private enum LifecycleState { case stopped, running, stopping, faulted }
    private var lifecycleState: LifecycleState = .stopped
    private let stateQueue = DispatchQueue(label: "com.clabotch.hookserver.state")
    private var generation: UInt64 = 0           // stateQueue で保護
    private let acceptQueue = DispatchQueue(label: "com.clabotch.accept")
    private let controlQueue = DispatchQueue(label: "com.clabotch.hookserver.control")  // stop() の wait を main thread から逃がす
    private let acceptGroup = DispatchGroup()       // accept ループの drain 待ち（stop 用）
    private let connectionGroup = DispatchGroup()  // 全接続 queue の drain 待ち
    private let connectionsLock = NSLock()

    // fd の二重 close を防ぐラッパー。socketOps 経由で POSIX を呼ぶ。
    private final class Connection {
        let fd: Int32
        private let ops: SocketOps
        private var isClosed = false
        private let lock = NSLock()

        init(fd: Int32, ops: SocketOps) { self.fd = fd; self.ops = ops }

        /// close を1回だけ実行する。2回目以降は no-op。
        /// socketOps 経由で shutdown/close を呼ぶ（直接 Darwin.shutdown/close 禁止）。
        func closeOnce() {
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return }
            isClosed = true
            _ = ops.shutdown(fd, SHUT_RDWR)
            _ = ops.close(fd)
        }
    }
    private var activeConnections: [Connection] = []
    private var isShuttingDown = false  // connectionsLock で保護。stop 時に true。

    init(socketDir: String, socketName: String = "hook.sock",
         socketOps: SocketOps = RealSocketOps(),
         sleeper: @escaping (useconds_t) -> Void = { usleep($0) },
         onLines: @escaping ([Data]) -> Void,
         onListenerFailure: @escaping (Error) -> Void = { _ in },
         testHook_afterGenerationCheckBeforeRegister: ((Int32) -> Void)? = nil)  // テスト専用 seam。handleNewConnection 内の generation check 通過後、connectionsLock 取得前に呼ばれる。本番では nil。
    func start() throws   // main thread 限定。.stopped 以外なら no-op(.running) / throw(.stopping/.faulted)。
    /// stop 完了時の結果
    enum StopOutcome { case stopped, timedOut }
    func stop(completion: @escaping (StopOutcome) -> Void = { _ in })  // main thread で発火。非同期。completion は main thread で呼ばれる。
    /// applicationWillTerminate 専用。listen socket close + unlink を同期実行。
    /// controlQueue の drain は待たない（プロセス終了で解放される）。
    func terminateSync()  // main thread 限定。
    private func beginTeardown(reason: TeardownReason) -> Bool  // .running→.stopping を1回だけ取る（ownership 取得のみ）。main thread 限定。
    private func performTeardown(reason: TeardownReason, completion: ((StopOutcome) -> Void)?, skipDrain: Bool = false)  // 実 cleanup。beginTeardown 成功後に呼ぶ。skipDrain=true は terminateSync 用。
}
```

#### accept ループの流れ

1. socketDir の検証（上記手順）
2. stale socket の live 判定 + `unlink`（上記手順）
3. `socket(AF_UNIX, SOCK_STREAM, 0)` で listen socket 作成
4. **`FD_CLOEXEC`** を listen socket に設定（`fcntl(fd, F_SETFD, FD_CLOEXEC)`）。子プロセス fork 時の fd リークを防止。
5. `sun_path` 長を `fileSystemRepresentation` バイト数 + NUL で検証（104バイト上限）。`sockaddr_un` の構築手順:
   - `var addr = sockaddr_un()` で zero-fill 初期化
   - `addr.sun_family = sa_family_t(AF_UNIX)`
   - `addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)`
   - `withUnsafeMutableBytes(of: &addr.sun_path) { buf in socketPath.withCString { src in _ = memcpy(buf.baseAddress!, src, min(strlen(src) + 1, buf.count)) } }` で NUL 終端付きコピー（tuple ポインタ問題を回避）
   - `socklen_t` は `socklen_t(MemoryLayout<sockaddr_un>.size)` で算出（Darwin では固定長構造体）
6. `bind` → `chmod(socketPath, 0o600)` → `listen(fd, 16)`（backlog = 16: 短命接続が主だが、複数 hook が burst で同時接続する場合のキュー落ちを防ぐ余裕を持たせる）
   - **`bind` 失敗時の分岐:**
     - `EADDRINUSE` → 同時起動による race（probe と bind の間に別インスタンスが bind した）。`close(fd)` → `connect()` で再 probe:
       - 成功 → live socket 確認 → `throw HookServerError.alreadyRunning`
       - 失敗 → `throw HookServerError.bindFailed(EADDRINUSE)`（原因不明）
     - その他 → `close(fd)` + `throw HookServerError.bindFailed(errno)`
   - **`bind` 成功後の途中失敗:** `chmod` / `listen` が失敗した場合、`close(fd)` + `unlink(socketPath)` + `listenSocket = -1` で確実にクリーンアップ。
7. `stateQueue.sync { generation &+= 1 }` で世代をインクリメントし、現在値をキャプチャ
8. `acceptGroup.enter()` → `acceptQueue.async { [fd = self.listenSocket, capturedGeneration] in defer { self.acceptGroup.leave() }; ... }` で fd を **closure capture list** でキャプチャ（main thread 上でクロージャ生成時に値をコピー。acceptQueue 上で `self.listenSocket` を一切読まない。stop→start 後の fd 再利用による ABA 問題を防止）。`acceptGroup` は stop() の `acceptGroup.wait()` で accept ループの終了を待つ:
   - 無限ループ: `accept(fd, ...)` でブロック
   - accept 成功後: `fcntl(clientFd, F_SETFD, FD_CLOEXEC)` を設定
   - `stateQueue.sync { generation == capturedGeneration }` を再チェック
   - 世代不一致なら `close(clientFd)` してループ離脱
   - 世代一致なら `handleNewConnection(fd:, generation:)`
9. `handleNewConnection`:
   - **登録と停止の線形化（lock 順序: `stateQueue → connectionsLock` を厳守）:**
     1. **lock 外で** `stateQueue.sync { generation == capturedGeneration }` を確認（lock 順序違反防止）
     2. generation 不一致なら `close(clientFd)` → return（未登録のまま破棄）
     2b. `testHook_afterGenerationCheckBeforeRegister?(clientFd)` を呼ぶ（nil なら no-op）。**テスト seam: この位置で stop() を割り込ませることで、generation check は通過したが isShuttingDown で拒否されるシナリオを検証可能**
     3. `connectionsLock` を取得:
        a. **lock 内で `isShuttingDown` フラグを確認**（`stateQueue.sync` は一切使わない。`isShuttingDown` は `performTeardown` の step 2 で `connectionsLock` 下で `true` にセットされる）
        b. `isShuttingDown == true` なら `connectionsLock.unlock()` → `close(clientFd)` → return
        c. `Connection` オブジェクトを生成し `activeConnections` に追加
        d. `connectionGroup.enter()`
     4. `connectionsLock.unlock()`
   - **lock 順序の証明:** step 1 は `stateQueue` のみ。step 3 は `connectionsLock` のみ（`stateQueue.sync` を含まない）。`isShuttingDown` は `connectionsLock` で保護されるため、`stateQueue` との入れ子にならない。
   - この順序により、stop() の `connectionsLock` 下の `isShuttingDown = true` + snapshot と handleNewConnection の登録が直列化され、「snapshot に入らず group にも乗らない」接続が生存する問題を防止。
   - 接続ごとに `LineBufferedEventDecoder` を生成（共有禁止）
   - 接続ごとに serial queue を生成（`com.clabotch.socket.<UUID>`）
   - `connectionQueue.async` で read ループ開始 → 終了時に `connectionGroup.leave()`
   - read ループ内: 固定サイズバッファ（`let readBuf = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 1)`、4KB）で `read()` → `decoder.append()` → **emit 前に `stateQueue.sync { generation == capturedGeneration }` 再チェック** → 世代一致なら `onLines(lines)` を connectionQueue 上で直接呼び出し（正典 §10.3 準拠）、不一致なら破棄してループ離脱。4KB は NDJSON イベント1行（通常 200-500 bytes）を1回の read で処理でき、ピークメモリを抑制する。
   - **readBuf は `defer { readBuf.deallocate() }` で確実に解放する**（ループ終了パスに関係なくリーク防止）。
   - EOF（read == 0）または read エラーで `connection.closeOnce()` を **先に呼び**、その後 `connectionsLock` 下で `activeConnections` から除去（**fd 値ではなく Connection オブジェクトの同一性（`===`）で特定**。restart 後の fd 再利用による ABA を防止）。lock 順序: `Connection.lock`（closeOnce 内）→ `connectionsLock`（除去）。stop 側は `connectionsLock`（snapshot）→ unlock → `Connection.lock`（closeOnce）なので AB-BA deadlock にならない。
   - **self の参照方針:** HookServer はアプリライフタイムオブジェクト（AppDelegate が保持）のため、connectionQueue / acceptQueue のクロージャでは **`[weak self]` ではなく strong capture** を使用する。理由:
     - AppDelegate が HookServer を strong 保持し、`applicationWillTerminate` で `terminateSync()` を呼ぶため、HookServer が先に解放されることはない
     - `stop()` は `controlQueue.async` 経由で非同期 drain するが、HookServer の dealloc は AppDelegate の dealloc 後（プロセス終了時）にしか起きないため、drain 中の self アクセスは安全
     - `[weak self]` + `guard let self` パターンは cleanup コードの到達性を複雑にし、`activeConnections` からの除去が確実に走る保証が弱まる
     - `connectionGroup.leave()` と `connection.closeOnce()` は `defer` で確実に実行される
   - **ARCHITECTURE.md との整合:** `ARCHITECTURE.md` の `[weak self]` 指針は一般ルール。HookServer は AppDelegate 直接保持 + ライフタイム保証があるため、承認済み例外として本計画に記録する。ライフタイム保証の前提条件: (1) AppDelegate が HookServer を strong 保持、(2) `applicationWillTerminate` で `terminateSync()` 呼び出し（listen close + unlink を同期実行）、(3) HookServer の dealloc は AppDelegate の dealloc 後（プロセス終了時）にしか起きない

#### ライフサイクル

- `start()`: main thread 限定（`dispatchPrecondition` で強制）。ライフサイクル状態で分岐:
  - `.stopped` → 起動処理を実行し `.running` に遷移
  - `.running` → no-op
  - `.stopping` → `throw HookServerError.stopping`（**stopping 中の start() を明示的に禁止**）
  - `.faulted` → `throw HookServerError.faulted`
- `stop(completion:)`: main thread で発火。**main thread をブロックしない**。ライフサイクル状態で分岐:
  - `.stopped` → 即 `completion(.stopped)` return
  - `.faulted` → 即 `completion(.timedOut)` return
  - `.stopping` → completion を内部キュー `pendingStopCompletions` に積む（多重 stop 対応。完了時にまとめて呼ぶ）
  - `.running` → `beginTeardown(.normalStop)` で `.stopping` に遷移し、内部の wait 処理は `controlQueue` で実行
- `terminateSync()`: main thread 限定。`applicationWillTerminate` 専用。`beginTeardown(.normalStop)` → listen socket shutdown/close + unlink のみ実行。controlQueue drain は待たない（プロセス終了で回収）。

**ライフサイクル状態遷移:**
```
stopped → running → stopping → stopped
                  → stopping → faulted（timeout 時）
```
- 全遷移は main thread 上でのみ発生（`dispatchPrecondition` で強制）
- `.stopping` 中は `start()` を拒否することで、旧 stop の後始末が新世代を壊す問題を防止

**`stop(completion:)` の詳細（`performTeardown` に委譲）:**
  - `beginTeardown(.normalStop)` で ownership を取得 → `performTeardown(.normalStop, completion:)` を呼ぶ

**`performTeardown(reason:, completion:, skipDrain: Bool = false)` — 唯一の cleanup パス:**
  1. main thread で `stateQueue.sync { generation &+= 1 }` で世代をインクリメント
  2. main thread で `connectionsLock` 下で `isShuttingDown = true` に設定（handleNewConnection の登録を拒否）
  3. main thread で listen socket: `shutdown(SHUT_RDWR)` + `close`（accept() がエラーを返して離脱）
  4. main thread で `listenSocket = -1` に設定
  5. main thread で socket ファイルを `unlink`
  6. **`skipDrain == true` の場合（terminateSync 用）:** ここで return。controlQueue の drain は行わない。
  7. **`controlQueue.async`** で以下の wait 処理を実行（main thread 解放）:
     7a. `acceptGroup.wait(timeout: .now() + 3.0)` — accept ループの終了を待つ
     7b. `connectionsLock` 下で `activeConnections` を **snapshot のみ取得**（`let snapshot = activeConnections`）→ **lock 解放後に** 各 `connection.closeOnce()`（read ブロック解除）。**lock 下で closeOnce() を呼ばない**（AB-BA deadlock 防止）
     7c. `connectionGroup.wait(timeout: .now() + 3.0)` — 全 connectionQueue の read ループ完了を待つ。**closeOnce() により read は即座にエラー/EOF を返すため、通常は数ミリ秒で完了**。
     7d. `DispatchQueue.main.async` で最終処理:
        - timeout 判定: いずれかの wait が timeout した場合 → `lifecycleState = .faulted` + `os_log(.fault)` + outcome = `.timedOut`
        - timeout なし → `lifecycleState = .stopped` + outcome = `.stopped`
        - `connectionsLock` 下で `activeConnections.removeAll()` + `isShuttingDown = false`（**常に lock 下で操作**。isShuttingDown のリセットにより再起動時に登録が再開可能）
        - `completion?(outcome)` + `pendingStopCompletions` を全て `outcome` で呼び出し + クリア
        - listener failure の場合のみ: `self.onListenerFailure(error)`（**ownership を取れた経路でのみ発火**）
  - **main thread は step 5 で即座に解放される**（UI stall ゼロ）。controlQueue 上の wait は最大 6 秒だが、main thread には影響しない。
  - completion 内で outcome を判定:
    - `.stopped` → `start()` を呼べば安全に再起動可能
    - `.timedOut` → `.faulted` 状態のため `start()` は throw。アプリ再起動のみ（PoC 方針）
  - **completion の保証範囲:** transport 層の quiesce（accept ループ停止 + 全 read ループ完了）まで。`onLines` の下流副作用（現フェーズはログのみ）の完了は保証しない。次フェーズで StateMachine を組み込む際に、`onLines` → `DispatchQueue.main.async` → StateMachine の完了保証を追加する（設計書 §10.3 の main thread handoff に対応）。

**`terminateSync()` — applicationWillTerminate 専用:**
  - `beginTeardown(.normalStop)` → `performTeardown(.normalStop, completion: nil, skipDrain: true)` を呼ぶ
  - `performTeardown` の step 1-5 を実行し、step 6 の `skipDrain` 判定で return
  - **cleanup ロジックは `performTeardown` と完全に共有**（step 1-5 が唯一の listen close + unlink パス。terminateSync 固有の別実装は持たない）
  - controlQueue の drain は待たない（プロセス終了で OS が fd を回収）

**`beginTeardown(reason:) -> Bool` — ownership 取得のみ:**
- `.running → .stopping` の遷移を試みる。既に `.stopping` / `.stopped` / `.faulted` なら `false` を返す。
- `true` を返した1回だけが teardown を所有する。**cleanup ロジックは含まない**（`performTeardown` に委譲）。
- stop() と listenerFailure が同時に発火しても、先に `.stopping` を取った方だけが `performTeardown` を呼び、もう一方は no-op。
- **`onListenerFailure` は ownership を取れた経路でのみ発火する**（正常 stop との競合で偽障害通知を防止）。

**lock 順序の固定:**
```
stateQueue → connectionsLock → Connection.lock
```
- `connectionsLock` 下で `Connection.lock` を取る操作（closeOnce 等）は禁止。snapshot 取得と配列更新のみ。
- `closeOnce()` は常に `connectionsLock` 解放後に呼ぶ。
- read ループ終了時: `closeOnce()` → `connectionsLock` 下で除去（`Connection.lock → connectionsLock` の順。AB-BA にならない）。
- stop() の controlQueue: `connectionsLock` で snapshot → unlock → `closeOnce()`（`connectionsLock → Connection.lock` にならない）。

**listener failure の経路:**
- accept ループ内の連続5回失敗時: `DispatchQueue.main.async { if self.beginTeardown(reason: .listenerFailure(error)) { self.performTeardown(reason: .listenerFailure(error), completion: nil) } }`
- ownership を取れなかった場合（正常 stop が先行）: 何もしない。偽障害通知は発生しない。

#### accept() のエラー処理

```
accept() の戻り値に応じた分岐:
  正値          → stale generation check → handleNewConnection
  -1 + EINTR    → リトライ（continue）
  -1 + EBADF    → generation 変化を確認（`stateQueue.sync { generation != capturedGeneration }`）。
                   変化あり → stop() による正常終了。ループ離脱。
                   変化なし → 予期しない fd 破壊。os_log(.fault) + cleanup + onListenerFailure。ループ離脱。
  -1 + EINVAL   → EBADF と同じ処理。
  -1 + ECONNABORTED → transient エラー。os_log(.debug) + continue（接続側がすぐ切断した場合の正常挙動）
  -1 + EMFILE / ENFILE → os_log(.error) + usleep(100_000) で backoff して continue
  -1 + その他   → os_log(.error)。連続エラーカウンタをインクリメントし、
                   5回連続で非復旧エラーなら:
                   1. os_log(.fault) でログ出力
                   2. DispatchQueue.main.async で stop() 相当の cleanup を実行
                   3. onListenerFailure を main thread で呼び出し（AppDelegate に障害通知）
                   4. ループ離脱
                   正常 accept が成功したらカウンタリセット。
```

#### read() のエラー処理

```
read() の戻り値に応じた分岐:
  正値          → decoder.append() → generation check → onLines
  0             → EOF（正常切断）。connection.closeOnce() + activeConnections から除去。ループ終了。
  -1 + EINTR    → リトライ（continue）
  -1 + ECONNRESET → 正常切断扱い。connection.closeOnce() + ループ終了。
  -1 + EBADF    → stop() による fd close が原因の可能性。generation 変化を確認:
                   変化あり → 正常終了扱い（log なし）。ループ終了。
                   変化なし → os_log(.error) + ループ終了。
  -1 + ENOTCONN → EBADF と同じ処理。
  -1 + その他   → os_log(.error) + connection.closeOnce() + ループ終了。
```

#### セキュリティ

- 専用ディレクトリ `$TMPDIR/clabotch/` を `0700` で作成 **または** 既存の `0700` ディレクトリを検証（非 `0700` なら throw）
- `bind` 後に `chmod(socketPath, 0o600)` で socket ファイルも owner only
- socketDir / socket の `st_uid == getuid()` で owner 検証（他ユーザー所有なら throw）
- `unlink` 前に `lstat` で socket タイプ確認 + owner 検証 + `connect()` probe で live 判定（ECONNREFUSED のみ stale、それ以外は throw）
- `sun_path` 長は `fileSystemRepresentation` のバイト数（NUL 含む）で検証

#### スレッド境界

| 処理 | スレッド | 排他制御 |
|------|---------|---------|
| start() / stop() | main thread（`dispatchPrecondition` で強制） | main thread serialization |
| generation 読み書き | 複数スレッド | `stateQueue.sync {}` |
| accept ループ | `acceptQueue`（専用 serial） | generation token で世代管理 |
| read + decode | `connectionQueue`（接続ごと serial） | Connection ごと独立 |
| emit 前 generation check | `connectionQueue` 上 | `stateQueue.sync {}` で読み取り |
| onLines コールバック | `connectionQueue` 上で呼ばれる（正典 §10.3 準拠） | init 注入 let + nonblocking 契約 |
| activeConnections 追加/除去 | 複数スレッド | `connectionsLock`（NSLock） |
| Connection.closeOnce() | 複数スレッド | Connection 内部の lock |
| acceptGroup wait | controlQueue（stop 内） | DispatchGroup + timeout（3秒上限） |
| connectionGroup wait | controlQueue（stop 内） | DispatchGroup + timeout（3秒上限） |
| stop() completion | main thread（controlQueue から async） | DispatchQueue.main.async |
| onListenerFailure | main thread（async、ownership 取得経路のみ） | init 注入 let + main thread serialization |

**lock 順序（固定）:** `stateQueue → connectionsLock → Connection.lock`
- **connectionsLock 下で stateQueue.sync を呼ばない**（順序違反防止。handleNewConnection では lock 外で generation check し、lock 内は `isShuttingDown` フラグで判定）
- **connectionsLock 下で Connection.lock を取る操作は禁止**（closeOnce は lock 解放後に呼ぶ）
- **全 lock 取得経路の証明:**
  - `handleNewConnection`: stateQueue.sync（lock外）→ connectionsLock（登録のみ、stateQueue/Connection.lock なし）
  - `performTeardown` controlQueue: connectionsLock（snapshot のみ）→ unlock → closeOnce（Connection.lock）
  - read ループ終了: closeOnce（Connection.lock）→ connectionsLock（除去のみ）
  - いずれも `stateQueue → connectionsLock → Connection.lock` の部分順序を満たす

### Step 3: LineBufferedEventDecoder 実装

設計書 §14.1 ベース + oversize line 完全破棄の修正。

```swift
import os.log

final class LineBufferedEventDecoder {
    private var buffer = Data()
    private var droppingOversizeLine = false  // 8KB超過行の残り部分を破棄するフラグ
    private let maxLineBytes = 8 * 1024
    private(set) var droppedLineCount: UInt64 = 0  // 破棄行カウンタ（デバッグ・監視用）

    /// テスト用: 現在のバッファ要素数（論理サイズ）
    var currentBufferCount: Int { buffer.count }

    func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []

        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: nl)
            buffer.removeSubrange(...nl)

            if droppingOversizeLine {
                droppingOversizeLine = false
                droppedLineCount += 1
                os_log(.debug, "LineBufferedEventDecoder: oversize 行の後半を破棄")
                continue
            }
            guard !line.isEmpty else { continue }
            if line.count > maxLineBytes {
                droppedLineCount += 1
                os_log(.debug, "LineBufferedEventDecoder: %d バイトの oversize 行を破棄", line.count)
                continue
            }
            lines.append(Data(line))
        }

        // 改行なしで 8KB 超 → バッファ破棄（容量も解放）+ 次の改行まで破棄フラグ ON
        if buffer.count > maxLineBytes {
            buffer = Data()  // keepingCapacity しない（メモリ解放）
            droppingOversizeLine = true
        }

        return lines
    }
}
```

- `\n` で行分割
- 空行は無視
- maxLineBytes 超過行は **完全に** 破棄（後半部分が復活しない）
- バッファ自体が maxLineBytes を超えたら `Data()` で容量ごと解放 + dropping フラグ ON
- `droppedLineCount` で破棄行数を追跡（デバッグ・監視用。silent drop による問題切り分けに使用）
- `currentBufferCount` は内部デバッグ用。テストでは振る舞い（正常復帰可否）で検証し、内部バッファサイズの断定は避ける

### Step 4: テスト

**テスト隔離ルール:** 全テストケースで短い prefix の専用一時ディレクトリ（`/tmp/cbt-<short_id>/`）と一意な socket name を使用する。`NSTemporaryDirectory() + UUID` は `sun_path` 104 byte 制限に抵触するリスクがあるため使わない。

**HookServer テストの main thread 制約:** `start()` / `stop()` は `dispatchPrecondition(.onQueue(.main))` を使うため、テストは `@MainActor` で実行する。`DispatchQueue.main.sync {}` は deadlock するため **使用禁止**。

**SIGPIPE 対策:** テスト内でクライアント socket に書き込む場合は `SO_NOSIGPIPE` をセットし、write 失敗を `EPIPE` エラーとして安全にハンドリングする。

#### LineBufferedEventDecoderTests（11ケース）

| テストケース | 内容 |
|-------------|------|
| 1行完結 | `{"event":"test"}\n` → 1行返る |
| 複数行 | `line1\nline2\n` → 2行返る |
| 途中切れ | `{"event":"te` → 0行、次に `st"}\n` → 1行返る |
| 空行スキップ | `\n\n{"event":"x"}\n` → 1行返る |
| ちょうど 8KB | 8192バイトの行 → 正常に返る |
| 8KB+1 超過行 | 8193バイトの行が破棄され、`droppedLineCount` が増加すること |
| oversize 後半復活防止 | 8KB超を改行なしで送信 → 次の改行で後半が行として復活しないこと |
| バッファ溢れ→復帰 | oversize 後に正常な行を送ると正しく処理されること |
| 複数行 + 末尾途中切れ | `line1\nline2\npartial` → 2行返り、partial は保持 |
| oversize 後に正常復帰 | 1MB chunk → 続けて正常行を送信 → 正常行が返ること（内部バッファ状態ではなく振る舞いで検証） |
| droppedLineCount 検証 | 8KB 超の行を送信 → droppedLineCount が増加し、後続の正常行は受信されること |

#### テスト suite 構成

**3 suite に分離:**

1. **HookServerUnitTests**（MockSocketOps / 状態検証、OS 非依存）— **required 19 ケース**
2. **HookServerIntegrationTests**（実 socket 使用、OS 依存）— **required 17 ケース + conditional 1 ケース**
3. **HookServerAppDelegateTests**（AppDelegate レベルの統合）— **required 3 ケース**

**完了条件: required 39 ケース全パス。conditional 1 ケースは SKIP 許容。**

**テスト分類:**
- **HookServerUnitTests（required 19）:**
  bind(EADDRINUSE)→alreadyRunning、bind(EADDRINUSE)→bindFailed、accept(EMFILE)→backoff、accept連続5回失敗→onListenerFailure、start()途中失敗ロールバック、stop()でonListenerFailure不発、faulted→start()拒否、stop() timeout検出、EMFILE backoff deterministic、stop(completion:)非同期完了、performTeardown統一、stopping中のstart()拒否、start()2回呼び出し、sun_path長超過、mkdir EEXIST race、accept直後のstop race、listenerFailureとstopの競合（ownership排他）、stop completion結果種別、terminateSync同期実行
- **HookServerIntegrationTests（required 17 + conditional 1）:**
  単一クライアント接続、複数クライアント並行、1行複数write分割、EOFクリーンアップ、stop()でaccept離脱、stop()→start()再起動、接続保持中のstop()、stop()後stale emitなし、stop()冪等性、lstat通常ファイル保護、chmod0600検証、live socket検出、socketDir不正検証、stale socket unlink成功、socketDir 0755拒否、NDJSONバッチ順序保証、connect(ENOENT)probe、**[conditional]** socketDir owner不一致（root でのみ検証可。CI 環境依存のため SKIP 許容）
- **HookServerAppDelegateTests（required 3）:**
  alreadyRunning→terminate（start() が alreadyRunning throw → AppDelegate が terminate 呼び出し）、terminateSync+stopping競合（stop() 発火中に terminateSync() → beginTeardown が false を返し terminateSync は no-op、unlink は stop 経路で保証）、terminateSync後のunlink保証（terminateSync() 後に socket ファイルが確実に削除されていること）

**注:** `droppedLineCount 検証` は LineBufferedEventDecoderTests に移動（decoder の責務）。

**観測方法:**
- `onLines` コールバック（init 注入）: 受信行の内容と順序を `XCTestExpectation` で検証
- socket への `connect()` 失敗: accept ループが停止したことの外部観測
- `stop()` → `start()` 成功: ライフサイクルの正常動作を外部挙動で確認

| テストケース | 内容 |
|-------------|------|
| 単一クライアント接続 | NDJSON 送信 → onLines で受信確認 |
| 複数クライアント並行 | 2クライアント同時接続 → 各 decoder が独立 |
| 1行を複数 write 分割 | 1行の JSON を2回の write に分けて送信 → 正しく1行として受信 |
| EOF クリーンアップ | クライアント切断後に新規接続が正常に処理されること |
| stop() で accept 離脱 | stop() 後に `connect()` が失敗すること |
| stop() → start() 再起動 | stop() → start() で再度 `connect()` + 受信可能なこと |
| start() 2回呼び出し | 2回目は no-op で例外なし |
| 接続保持中の stop() | stop() 後にクライアントの `read()` が EOF を返すこと（`SO_NOSIGPIPE` 設定下） |
| stop() 後に stale emit なし | stop() 前に送信した行が stop() 後に onLines で通知されないこと |
| stop() 冪等性 | stop() を2回連続呼び出し → panic やエラーなし |
| sun_path 長超過 | 104バイト超のパスで `start()` → エラー throw |
| lstat 通常ファイル保護 | socket path に通常ファイルが存在 → `start()` が unlink **しない**こと |
| chmod 0600 検証 | `start()` 後に socket ファイルのパーミッションが 0600 であること |
| live socket 検出 | 別プロセスが listen 中の socket path → `start()` が `alreadyRunning` throw |
| socketDir 不正検証 | socketDir が通常ファイル / symlink → `start()` が throw |
| stale socket の unlink 成功 | stale socket ファイルが存在（listen プロセスなし） → `start()` が unlink して正常起動 |
| socketDir 0755 拒否 | socketDir が存在するが `0755` → `start()` が throw |
| socketDir owner 不一致 | **[conditional]** socketDir の owner が別ユーザー → `start()` が throw（root で実行する場合のみ検証可。CI 環境依存のため SKIP 許容） |
| bind(EADDRINUSE) → alreadyRunning | MockSocketOps で `bind` が `EADDRINUSE` → 再 probe → `alreadyRunning` throw |
| bind(EADDRINUSE) → bindFailed | MockSocketOps で `bind` が `EADDRINUSE` → 再 probe 失敗 → `bindFailed` throw |
| accept(EMFILE) → backoff | MockSocketOps で `accept` が連続 `EMFILE` → backoff 後に正常復帰 |
| accept 連続5回失敗 → onListenerFailure | MockSocketOps で 5回連続失敗 → onListenerFailure が呼ばれること |
| start() 途中失敗のロールバック | MockSocketOps で `listen` を失敗させる → fd が close され、socket ファイルが unlink されること |
| stop() で onListenerFailure が呼ばれない | 正常 stop() 後に onListenerFailure が呼ばれていないこと |
| NDJSON バッチ順序保証 | session_start + tool_start を1回の write で送信 → onLines で同じ順序で受信されること |
| mkdir EEXIST race | socketDir 不在 → mkdir と同時に別スレッドが mkdir → EEXIST → lstat で再検証成功 |
| connect(ENOENT) probe | socket ファイルが probe 直前に消えた場合 → ENOENT → stale 不要として続行し bind 成功 |
| faulted state → start() 拒否 | stop() で timeout 発生 → lifecycleState = .faulted → 次の start() が `faulted` throw |
| stop() timeout 検出 | MockSocketOps で read を永久ブロック → connectionGroup.wait が timeout → os_log(.fault) + lifecycleState = .faulted |
| EMFILE backoff (deterministic) | no-op sleeper 注入 + MockSocketOps で EMFILE → backoff 動作を高速検証 |
| stop(completion:) の非同期完了 | stop() 呼び出し直後に main thread が解放され、completion が main thread で呼ばれること |
| teardown 統一 | listener failure 経由の teardown と正常 stop の teardown が同じ最終状態（listenSocket == -1, socket 削除）になること |
| stopping 中の start() 拒否 | stop() 発火直後（completion 前）に start() → `stopping` throw |
| accept 直後の stop race | `testHook_afterGenerationCheckBeforeRegister` を使用。テスト手順: (1) hook で DispatchSemaphore.wait() によりブロック（generation check は通過済み、connectionsLock 取得前） (2) main thread で stop() を呼び `isShuttingDown = true` にする (3) semaphore.signal() でブロック解放 (4) handleNewConnection が step 3a で `isShuttingDown == true` を検出し clientFd を close → group に漏れないこと。generation check を通過した接続が isShuttingDown で正しく拒否されることを検証。deterministic（main thread の stop() は同期的に isShuttingDown を設定） |
| listenerFailure ownership 排他 | MockSocketOps で accept を連続5回失敗させ onListenerFailure 発火 → beginTeardown(.listenerFailure) が ownership を取る。その直後に stop() → beginTeardown(.normalStop) が false を返し no-op。main-thread-only なので deterministic |
| stop completion の結果種別 | 正常 stop → `.stopped`、timeout → `.timedOut` が正しく返ること |
| terminateSync 同期実行 | `terminateSync()` 後に listen socket が close され、socket ファイルが unlink されること |
| listenerFailure ownership 排他 | stop() が先に ownership を取った場合、listener failure 経路で `onListenerFailure` が呼ばれないこと |
| alreadyRunning → terminate | **[HookServerAppDelegateTests]** `alreadyRunning` throw 時に AppDelegate が terminate を呼ぶこと |
| terminateSync + stopping 競合 | **[HookServerAppDelegateTests]** `.stopping` 状態（stop() 発火後 completion 前）で terminateSync() → beginTeardown が false → no-op。unlink は stop 経路で保証。**テスト手順:** stop() を呼んだ直後（main thread 上で同期的に `.stopping` になった時点で）terminateSync() を呼ぶ。main-thread-only API 同士のため race は発生せず deterministic。 |
| terminateSync 後の unlink 保証 | **[HookServerAppDelegateTests]** terminateSync() 後に socket ファイルが確実に削除されていること |

#### 手動テスト手順

```bash
# アプリ起動後:

# 1行送信（socket パスが $TMPDIR/clabotch/hook.sock に変更されている点に注意）
printf '%s\n' '{"schema_version":"1","event":"session_start","session_id":"test","event_id":"550e8400-e29b-41d4-a716-446655440000","timestamp":"2026-03-10T00:00:00Z"}' | nc -w 1 -U $TMPDIR/clabotch/hook.sock

# 2行連結送信（順序保証テスト）
printf '%s\n%s\n' \
  '{"schema_version":"1","event":"session_start","session_id":"test2","event_id":"a1b2c3d4-e5f6-7890-abcd-ef1234567890","timestamp":"2026-03-10T00:00:00Z"}' \
  '{"schema_version":"1","event":"tool_start","session_id":"test2","event_id":"b2c3d4e5-f6a7-8901-bcde-f12345678901","timestamp":"2026-03-10T00:00:00Z","tool_name":"Bash"}' \
  | nc -w 1 -U $TMPDIR/clabotch/hook.sock

# Quit: メニューバーの「C」→「Quit Clabotch」で applicationWillTerminate を検証
```

## イベント順序保証

**問題:** hook スクリプトは各イベントを個別の `nc -U` 呼び出しで送信する。受信側は接続ごとの serial queue なので、別接続のイベントは順序が保証されない。

**対応（実装済み）:** `clabotch_pre_tool.sh` を修正し、session_start + tool_start を1つの `nc` 接続で NDJSON 連結送信するようにした。これにより:
- session_start → tool_start の順序は 1接続内の serial queue で保証される

**順序保証の限界と lossy 許容方針:** `tool_end` / `session_done` は依然として別接続で送信される。同一セッション内で `session_done` が `tool_end` より先に到着する可能性は理論上ある（実用上は hook の呼び出し順序で発生しにくい）。

**明確な方針:** 本フェーズでは **lossy（tool_end の欠落・遅着）を許容** する。理由:
- HookServer は raw line transport 層であり、イベントの意味解釈は行わない
- 次フェーズの StateMachine で session_done 後の遅着 tool_end を安全に無視する設計（設計書 §12.2 の状態遷移で対応）
- 設計書 §14.3 の ownership-first guard は foreign session / duplicate の防御であり、同一 session の再順序化を保証するものではない
- 送信側での追加の順序保証（例: tool_end + session_done の連結送信）は、StateMachine 実装後に実測データで判断する
- **観測:** 次フェーズの StateMachine で遅着 tool_end を検出した場合、`os_log(.info, "遅着 tool_end を検出: session=%@")` + debug counter でカウントし、発生率を実測する。この計測結果に基づいて追加の順序保証が必要か判断する

**注意:** この変更は設計書 v11 §10.4 のコードとは異なる。設計書は変更しない方針のため、この差分は本計画と HANDOVER.md で管理する。

## リスク

| リスク | 対策 |
|--------|------|
| App Sandbox OFF で審査不可 | PoC 段階では不要。v1.0 で Developer ID 署名 + Notarization |
| socketDir の不正状態 | lstat + 型確認 + 権限確認。0700 でなければ throw。symlink / 通常ファイルも throw |
| 同一ユーザー多重起動 | connect() probe で live 判定。live なら alreadyRunning で throw。ECONNREFUSED のみ stale、その他 errno は throw |
| 同時起動 race（TOCTOU） | bind(EADDRINUSE) を connect() 再 probe で alreadyRunning に再マップ。再 probe 失敗なら bindFailed throw |
| 異常系のテスト可能性 | SocketOps protocol で POSIX syscall を注入可能にし、MockSocketOps でテスト |
| socket の unlink 競合 | lstat + connect probe → stale のみ unlink。chmod 0600 で owner only |
| accept ループのリーク | generation token + shutdown(SHUT_RDWR) + close + `acceptGroup.wait(timeout: 3秒)` で quiesce |
| accept 後の stale 接続 | `accept()` 成功後に `stateQueue.sync { generation }` を再チェック |
| accept の非復旧エラー | 連続5回で cleanup + main thread に onListenerFailure 通知 |
| connectionQueue の stale emit | emit 前に generation 再チェック + `connectionGroup.wait()` で全 queue drain 待ち |
| read ループの解除漏れ | stop() で全 Connection に closeOnce() → read が即座に 0/エラーを返す |
| read() の errno | EINTR→retry、ECONNRESET→正常切断、その他→log + close |
| fd の二重 close | Connection.closeOnce() で lock + isClosed フラグにより1回だけ close |
| start() 多重呼び出し | lifecycleState == .running なら no-op（lifecycleState が唯一の状態源） |
| start() 途中失敗 | bind 後の chmod/listen 失敗時に close(fd) + unlink + listenSocket = -1 で巻き戻し |
| start() 失敗時のアプリ | os_log(.error) でログ出力、アプリは継続（PoC 方針） |
| data race (generation) | stateQueue.sync {} で全スレッドから安全に読み書き |
| data race (listenSocket) | main thread 専用（dispatchPrecondition で強制）。acceptQueue への受け渡しは closure capture list で値コピー |
| data race (onLines) | init 注入 let + connectionQueue 上で呼び出し（正典準拠） |
| data race (onListenerFailure) | init 注入 let で不変 |
| FD_CLOEXEC | listen/accepted socket に fcntl(F_SETFD, FD_CLOEXEC) を設定 |
| data race (activeConnections) | connectionsLock（NSLock）で保護 |
| EINTR | accept/read でリトライ |
| sun_path 長超過 | fileSystemRepresentation バイト数 + NUL で検証 → エラー throw |
| retain cycle | connectionQueue / acceptQueue クロージャは strong capture（AppDelegate がライフタイム保証 + dealloc はプロセス終了時のみ）。 |
| ピークメモリ（read 側） | read バッファ固定 4KB。decoder の oversize 検出と合わせて制御 |
| oversize chunk のメモリ残留 | buffer = Data() で容量ごと解放 |
| oversize drop の問題切り分け | droppedLineCount + os_log(.debug) で追跡可能 |
| SIGPIPE（テスト） | テスト内で SO_NOSIGPIPE を設定 |
| sun_path テスト衝突 | `/tmp/cbt-<short_id>/` で短い prefix を使用 |
| socket パス変更 | 本フェーズで hook スクリプトの SOCK 変数も同時更新（原子的移行）。E2E テストで疎通確認 |
| onLines deadlock | connectionQueue 上で直接呼び出し（正典準拠）。stop() の wait は controlQueue で実行するため main thread deadlock なし。onLines 内の main.sync は契約違反だが、controlQueue 上の wait とは独立 |
| stop() の main thread ブロック | wait 処理は controlQueue で実行。main thread は即座に解放（UI stall ゼロ）。completion で完了通知 |
| applicationWillTerminate での stop 不完全 | terminateSync() で listen close + unlink を同期実行。controlQueue の drain はプロセス終了で回収 |
| AB-BA deadlock | lock 順序を `stateQueue → connectionsLock → Connection.lock` に固定。connectionsLock 下で closeOnce() 禁止（snapshot のみ取得、lock 解放後に close） |
| probe fd リーク | connect() probe 用 fd は `defer { socketOps.close(probeFd) }` で確実に解放（defer が唯一の close パス） |
| probe 用 socket() 失敗 | probeSocketCreationFailed(errno) で throw |
| lstat 失敗 | ENOENT は socket なしとして続行。その他は statFailed(path, errno) で throw |
| unlink 失敗 | ENOENT は続行。その他は unlinkFailed(path, errno) で throw |
| onListenerFailure 偽障害通知 | ownership を取れた経路（beginTeardown が true を返した場合）でのみ発火。正常 stop との競合で偽通知を防止 |
| mkdir race | mkdir(EEXIST) → lstat 再検証で同時起動に対応 |
| connect(ENOENT) | probe 時に socket が消えた場合は stale 判定不要として続行 |
| readBuf メモリリーク | defer { readBuf.deallocate() } で確実に解放 |
| stop() timeout 後の再起動 | faulted state に遷移し start() を拒否。旧 queue 残存による不定動作を防止 |
| stopping 中の start() | lifecycleState == .stopping なら throw HookServerError.stopping。controlQueue の後始末が新世代を壊す問題を防止 |
| activeConnections の data race | 全操作（追加・除去・removeAll）を connectionsLock 下で統一。main thread の removeAll も lock 経由 |
| SocketOps 境界外の fcntl 失敗 | os_log(.error) で記録し処理続行（FD_CLOEXEC は fork しない限り影響なし） |
| owner 不一致の socketDir/socket | st_uid == getuid() で検証。他ユーザー所有なら throw |
| alreadyRunning ゴーストインスタンス | alreadyRunning 検出時は即 terminate（PoC 方針の例外） |
| tool_end / session_done の順序逆転 | lossy 許容方針。次フェーズの StateMachine で遅着を安全に無視 |

## 完了条件

- [ ] `xcodebuild build` がエラーゼロ
- [ ] LineBufferedEventDecoder の単体テスト全パス（11ケース）
- [ ] HookServer テスト: required 39 ケース全パス（Unit 19 + Integration 17 + AppDelegate 3）。conditional 1 ケース（socketDir owner 不一致）は SKIP 許容
- [ ] アプリ起動でメニューバーに「C」が表示される
- [ ] メニューから「Quit Clabotch」で正常終了し、socket ファイルが削除される
- [ ] `printf ... | nc -w 1 -U` で NDJSON を送り、Xcode コンソールにログが出る
- [ ] hook スクリプト（`hooks/clabotch_lib.sh`）の SOCK パスが新パスに更新済み
- [ ] hook E2E テスト: 実際の hook スクリプトから HookServer への送受信が成功する（`tests/test_hooks.sh` の socket 復帰テストを新パスで実行）
- [ ] 設計書との差分を `docs/design/patches/` に記録済み
- [ ] Codex レビューで A 評価
