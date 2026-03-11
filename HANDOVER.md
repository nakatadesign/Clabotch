# HANDOVER.md — Clabotch セッション引き継ぎ

## 1. セッション概要

- **日時**: 2026-03-11（JST）
- **作業目的**: 計画 003（EventParser/EventDeduplicator）の実装完了 + 計画 004（StateMachine コア）の計画作成・実装完了
- **全体進捗**:
  - 完了: 計画 002, 003, 004（受信パイプライン + StateMachine コア）
  - 未着手: GazeController, BlinkController, BubbleWindow, ClabotchEyeView, AX tracking
  - 総テスト: **108 件**（107 passed, 1 skipped, 0 failures）

---

## 2. 完了した作業

### 2a. 計画 003 実装完了（EventParser + EventDeduplicator + HookServer 結線）

| 作業 | ファイル |
|------|---------|
| ClabotchEvent enum + ClabotchEnvelope struct 作成 | `src/Clabotch/ClabotchEvent.swift` |
| EventParser（pure function パーサー）作成 | `src/Clabotch/EventParser.swift` |
| EventDeduplicator（TTL+maxEntries）作成 | `src/Clabotch/EventDeduplicator.swift` |
| HookServer: onLines → onEvent 結線変更 | `src/Clabotch/HookServer.swift` |
| AppDelegate: deduplicator 所有 + HookServer 注入 | `src/Clabotch/AppDelegate.swift` |
| EventParserTests（18 件）作成 | `src/ClabotchTests/EventParserTests.swift` |
| EventDeduplicatorTests（7 件）作成 | `src/ClabotchTests/EventDeduplicatorTests.swift` |
| HookServerTests: onLines→onEvent 全置換 + 結線テスト 3 件追加 | `src/ClabotchTests/HookServerTests.swift` |
| makeTestNDJSON ヘルパー追加 | `src/ClabotchTests/TestHelpers.swift` |
| patch 文書: unknown(rawJSON: String) | `docs/design/patches/patch_003_unknown_rawjson.md` |
| 計画 003 → completed 移動 | `docs/exec-plans/completed/003-eventparser-eventdeduplicator.md` |
| **Codex 実装レビュー A** | — |

### 2b. 計画 004 作成 + 実装完了（StateMachine コア）

| 作業 | ファイル |
|------|---------|
| 計画 004 作成 + Codex 計画レビュー A | `docs/exec-plans/active/004-statemachine-core.md` |
| MascotPhase enum + SessionState struct 作成 | `src/Clabotch/MascotPhase.swift` |
| StateMachine コア実装（175 行） | `src/Clabotch/StateMachine.swift` |
| AppDelegate: StateMachine 所有 + onEvent→handle 結線 | `src/Clabotch/AppDelegate.swift` |
| StateMachineTests（28 件、6 クラス）作成 | `src/ClabotchTests/StateMachineTests.swift` |
| **Codex 実装レビュー A** | — |

---

## 3. 重要な意思決定と理由

### 3a. `unknown(rawJSON: String)` vs `unknown(raw: [String: Any])`
- **採用**: `rawJSON: String`
- **理由**: `[String: Any]` は Equatable 非適合で手動 == 実装が必要。JSON キー順序が非決定的でテスト脆弱。
- **patch**: `docs/design/patches/patch_003_unknown_rawjson.md`

### 3b. StateMachine のコールバック同期呼び出し
- **v11 設計書**: `DispatchQueue.main.async { self?.onPhaseChanged?(phase) }`
- **採用**: 同期呼び出し `onPhaseChanged?(phase)`
- **理由**: `handle(event:)` 自体が main thread 上。async にすると epoch チェックとコールバック間にギャップが生まれる。テストの deterministic 性が向上。
- 逸脱テーブル #5 に記録済み。

### 3c. cancelSleepTimer の sleeping 復帰ロジック削除
- **v11**: `cancelSleepTimer` 内で `if displayPhase == .sleeping { transition(...) }`
- **採用**: 削除。`handle(event:)` の Step 2 で cancel → Step 3 で適切な phase に遷移するため冗長。
- 逸脱テーブル #4 に記録済み。テスト #21 で検証済み。

### 3d. StateMachine の DI seams
- sleepThreshold, errorAutoTransitionDelay, doneAutoTransitionDelay, now() をパラメータ化
- **理由**: 5分/2.5秒/4秒の実値ではテスト不可能。0.1〜0.2 秒に短縮して高速テスト。

---

## 4. バグ・問題点と解決策

### 4a. Codex B→A: 計画 003

| 指摘 | 原因 | 解決 |
|------|------|------|
| S-1: patch 文書未作成 | unknown の型変更を逸脱テーブルに記載忘れ | `patch_003_unknown_rawjson.md` 作成 + 逸脱テーブル #4 追加 |
| B-1: makeTestNDJSON が tool_name 非対応 | extra パラメータのみだった | toolName, durationMs, isError 等の個別パラメータに拡張 |
| B-2/B-3: テスト欠落 | testParseToolEndWithoutErrorMessage, testInvalidJSON, testJSONArray | 3 テスト追加（合計 18 件） |

### 4b. Codex B→A: 計画 004

| 指摘 | 原因 | 解決 |
|------|------|------|
| S-1/S-2/S-3: 逸脱テーブル記載漏れ 3 件 | cancelSleepTimer 削除、sync 呼び出し、onEphemeralDone | 逸脱テーブルに #4, #5 として追加 |
| B-2: timerFactory が実装と不整合 | 逸脱テーブルに記載したが実装では不使用 | 逸脱テーブルから削除 |
| B-3: handleForeign のログ精度低下 | tool_start/tool_end を1つの case にまとめていた | case を分離して個別ログ |

**教訓**: 逸脱テーブルの管理漏れは Codex で S 扱いになる。設計書と異なるコードを書いたら即座に逸脱テーブルに記録すること。

---

## 5. 学んだ教訓と落とし穴

1. **xcodegen は `src/` ディレクトリで実行する**: `project.yml` が `src/` 直下にある。ルートで実行すると "No project spec found" エラー。
2. **Codex レビューの逸脱管理**: 設計書 v11 と1行でも異なるコードがあれば逸脱テーブルに記録必須。「些細な差異」でも S 扱い。
3. **StateMachine テストの Timer 制御**: `sleepThreshold` を 0.1〜0.2 秒に短縮し、`DispatchQueue.main.asyncAfter` + `XCTestExpectation` で検証。`RunLoop.main.run(until:)` は不要だった。
4. **HookServer テストの onLines→onEvent 移行**: 統合テストが生 JSON を送信していたため、makeTestNDJSON で有効な NDJSON に置換が必要だった。

---

## 6. 次のステップ（優先度順）

### 🟡 中優先度
- **計画 005: GazeController + BlinkController 実装**（設計書 §11.5）
  - StateMachine.onPhaseChanged → GazeController への結線
  - AX tracking（フォーカスされたターミナルウィンドウの位置取得）
  - 推定: 計画作成 + Codex A + 実装 + Codex A
- **計画 006: BubbleWindow + ClabotchEyeView 実装**（設計書 §11）
  - 22×14px フレーム描画
  - 14 フレームアニメーション
  - 吹き出しウィンドウ

### 🟢 低優先度
- Warp AX 属性ダンプ → tentativeBundles 昇格判断
- Stop hook error 対応（別件）

---

## 7. 重要ファイルマップ

### 本セッションで作成

| ファイル | 役割 |
|----------|------|
| `src/Clabotch/ClabotchEvent.swift` | イベント型定義（ClabotchEvent enum + ClabotchEnvelope struct） |
| `src/Clabotch/EventParser.swift` | pure function パーサー（Data → ClabotchEnvelope?） |
| `src/Clabotch/EventDeduplicator.swift` | TTL+maxEntries デデュプリケーター（main thread only） |
| `src/Clabotch/MascotPhase.swift` | MascotPhase enum（6 phase）+ SessionState struct |
| `src/Clabotch/StateMachine.swift` | ステートマシンコア（ownership guard, phase 遷移, レース対策） |
| `src/ClabotchTests/EventParserTests.swift` | EventParser テスト（18 件） |
| `src/ClabotchTests/EventDeduplicatorTests.swift` | EventDeduplicator テスト（7 件） |
| `src/ClabotchTests/StateMachineTests.swift` | StateMachine テスト（28 件、6 クラス） |
| `docs/design/patches/patch_003_unknown_rawjson.md` | unknown(rawJSON) patch 文書 |
| `docs/exec-plans/active/004-statemachine-core.md` | StateMachine 実装計画（逸脱 5 件管理） |

### 本セッションで変更

| ファイル | 変更内容 |
|----------|---------|
| `src/Clabotch/HookServer.swift` | onLines → onEvent + parse + dedup 結線 |
| `src/Clabotch/AppDelegate.swift` | deduplicator + stateMachine 所有、onEvent→handle 結線 |
| `src/ClabotchTests/HookServerTests.swift` | onLines→onEvent 全置換 + 結線テスト 3 件 |
| `src/ClabotchTests/TestHelpers.swift` | makeTestNDJSON ヘルパー追加 |
| `docs/exec-plans/completed/003-eventparser-eventdeduplicator.md` | completed に移動 + 逸脱 #4 追加 |

### 既存（変更なし）

| ファイル | 役割 |
|----------|------|
| `src/Clabotch/SocketOps.swift` | POSIX syscall 抽象化 |
| `src/Clabotch/MockSocketOps.swift` | テスト用モック |
| `src/Clabotch/LineBufferedEventDecoder.swift` | NDJSON 行分割 |
| `docs/design/current/clabotch_design_doc_v11.md` | 最終設計書（変更禁止） |

---

## 8. 環境・依存関係メモ

- **ビルドコマンド**: `cd src && xcodegen generate && xcodebuild test -project Clabotch.xcodeproj -scheme Clabotch -destination 'platform=macOS'`
- **project.yml**: `src/project.yml`（`src/` で xcodegen 実行必須）
- **macOS 13+ / Swift 5.9+**
- **新規パッケージ追加**: なし
- **環境変数**: なし
- **設計書**: 変更禁止。実装中の知見は本ファイルに記録。逸脱は `docs/design/patches/` に patch 文書で管理。

---

## 残留リスク

| リスク | 対応 |
|--------|------|
| Claude Code 2.1.x の hook payload が本当に stdin JSON か | Hook 疎通テスト通過済。実機デプロイで最終確認 |
| `jq` インストール有無 | `/usr/bin/jq` で確認済。未導入時は exit 1 |
| Warp の AX 属性（GazeController tentativeBundles） | AX属性ダンプ後に昇格判断 |
| Stop hook error | 別件のまま触らない |
