# HANDOVER.md — Clabotch セッション引き継ぎ

## 1. プロジェクト状態

- **MVP**: **完了**（v0.1 相当、設計書 §9 PoC + v0.1 + v0.2 スコープ全達成）
- **v0.3**: **完了**（計画 014 + BubbleWindow 可視化 + 経過時間精度）
- **v1.0**: **設定画面の土台 + LaunchAgent 登録 + Notarization/DMG 基盤 完了**
- **全計画 002〜014**: 完了
- **active な計画**: なし
- **CI**: green 確認済み（`8792c5b`）。PAT に actions:read 権限なし（API 確認不可、ブラウザで確認）
- **branch protection**: N/A（private repo + GitHub Free では設定不可）
- **総テスト**: 280 件（279 passed, 1 skipped）+ hook E2E 43 件
- **totonoe upstream**: 全修正反映済み（`284af6b` + `da95d78`）
- **Codex**: 使用上限到達（Mar 19 まで利用不可）。GEMINI_API_KEY 未設定のため Gemini フォールバックも不可

---

## 2. 計画 014 完了サマリー（MultiSessionStateMachine）

StateMachine を single-session ownership モデルから multi-session 並列追跡モデルに改修:

| 変更 | 内容 |
|------|------|
| MascotPhase.displayPriority | error(0) > working(1) > thinking(2) > done(3) > idle(4) > sleeping(5) |
| sessions 辞書化 | `session: SessionState?` → `sessions: [String: SessionState]` |
| ownership guard 廃止 | 全セッションのイベントを受理 |
| per-session epoch | セッション間のレース対策を独立化 |
| 後方互換 session | `.done` 除外 + displayPriority + startedAt ソート |
| done 遅延削除 | session_done 後もフェーズ表示のためセッション保持 |
| done セッション保護 | done セッションへの late tool イベントを拒否 |
| ephemeral 通知 | 非プライマリセッション完了時に onEphemeralDone 発火 |

Reviewer 指摘 2 件（high: done 復活バグ、medium: 非決定的選択）は Round 2 で修正済み。

---

## 2b. BubbleWindow 複数セッション可視化サマリー

複数セッション時にバブルテキストへ `[+N]` サフィックスを付加:

| 変更 | 内容 |
|------|------|
| CoordinatorBinder.bubbleText | static → instance メソッド化、sessions.count で [+N] 付加 |
| StateMachine.onSessionCountChanged | セッション数変化コールバック追加 |
| scheduleSessionRemoval | 防御チェック追加（sessions 存在確認） |
| テスト +5件 | I1〜I5: single/multi session バブルテキスト検証 |

表示例: `考えてます... [+1]`、`Bash 実行中... [+2]`

Reviewer Grade A、Manager done。totonoe job: bubblewindow-multisession-visibility

---

## 2c. 経過時間表示精度改善サマリー

ツール未使用セッションの elapsed_ms=0 問題を2層で改善:

| 変更 | 内容 |
|------|------|
| clabotch_stop.sh | SESSION_START_FILE 不在時に session_start + session_done を1接続送信 |
| StateMachine.sessionDone | hookElapsedMs==0 + 追跡済み → startedAt フォールバック計算 |
| テスト +5件 | EF-1〜EF-5: フォールバック計算・優先順位・ephemeral 通知検証 |

Reviewer Grade A、Judge done、Manager done。totonoe job: elapsed-time-accuracy-improvement

---

## 2d. 設定画面の土台サマリー

v1.0 最初の着手。メニューバーから設定画面を開けるようにし、拡張可能な構成を整備:

| 変更 | 内容 |
|------|------|
| SettingsStore | UserDefaults ラッパー。sleepTimeoutMinutes/Seconds + onChange |
| SettingsWindowController | NSWindow + NSStackView。スリープタイムアウト選択 |
| AppDelegate | メニューに「設定...」追加。SettingsStore → StateMachine 接続 |
| StateMachine.updateSleepThreshold | sleepThreshold 動的変更 + タイマー再スケジュール |
| テスト +14件 | SettingsStore 8件 + SettingsWindowController 3件 + updateSleepThreshold 3件 |

Reviewer Grade A、Manager done（override）。totonoe job: settings-panel-foundation

---

## 2e. LaunchAgent 登録サマリー

ログイン時自動起動を設定画面に追加。SMAppService (macOS 13+) ベース:

| 変更 | 内容 |
|------|------|
| LaunchAtLoginManager | LaunchAtLoginProviding プロトコル + SMAppService ラッパー |
| SettingsWindowController | NSObject 継承追加、チェックボックス UI、エラー時リバート |
| AppDelegate | LaunchAtLoginManager インスタンス生成・注入 |
| テスト +9件 | モック 5件 + 設定画面連携 4件 |

NSObject 継承は `@objc` target-action のランタイム動作に必須。
ヘッドレステスト: `perform(selector, with:)` で windowFactory=nil 環境でもアクション発火。

Reviewer Grade A、Manager done。totonoe job: launchagent-registration

---

## 2f. Notarization / DMG パッケージング基盤サマリー

v1.0 配布準備の土台。Notarization に必要な設定とビルドスクリプトを整備:

| 変更 | 内容 |
|------|------|
| Clabotch.entitlements | Hardened Runtime 用 entitlements（Apple Events） |
| project.yml | MARKETING_VERSION 1.0.0、ENABLE_HARDENED_RUNTIME、Debug/Release 署名分離 |
| build_release.sh | Release ビルド + DMG + Notarization スクリプト（--unsigned / --notarize） |
| DISTRIBUTION.md | 配布手順（人間の作業 / 自動化の分離を明記） |

人間の残作業: Apple Developer Program 加入 → Developer ID 証明書 → DEVELOPMENT_TEAM 記入 → 署名付きビルド

Reviewer Grade A、Manager done（force）。totonoe job: notarization-packaging-foundation

---

## 3. 次の優先タスク

| 優先度 | タスク | 種別 | 備考 |
|--------|--------|------|------|
| 1 | Stop hook error 調査 | バグ修正 | 再現したら着手 |
| 2 | hook E2E テスト [10] flaky 対策 | 回帰防止テスト | CI で再現した場合 |
| 3 | BubbleWindow 実環境テスト | テスト容易化 | GUI 環境で手動確認 |
| 4 | PAT 権限追加 | 外部依存 | 人間の作業。任意 |
| 5 | GEMINI_API_KEY 設定 | 外部依存 | totonoe Gemini フォールバック有効化 |

### v0.3 残タスク

- ~~foreign session の本格的な状態可視化（BubbleWindow 改修）~~ → **完了**（`[+N]` サフィックス + `onSessionCountChanged`）
- ~~作業時間表示の改善（ツール未使用セッションの経過時間精度）~~ → **完了**（startedAt フォールバック + stop hook 改善）

### v1.0 スコープ（配布・設定画面）

- ~~設定画面（UI パネル）~~ → **土台完了**（SettingsStore + SettingsWindowController）
- ~~LaunchAgent 登録（自動起動）~~ → **完了**（SMAppService + 設定画面チェックボックス）
- ~~Apple Notarization + DMG パッケージング~~ → **基盤完了**（スクリプト + 手順整備済み、Developer 証明書待ち）
- ~~Warp 完全対応~~ → **完了**（計画 009 で AX 検証済み、`dev.warp.Warp-Stable` を supportedBundles に昇格済み）

---

## 4. 環境・依存関係メモ

- **ビルド**: `cd src && xcodegen generate && xcodebuild test -project Clabotch.xcodeproj -scheme Clabotch -destination 'platform=macOS'`
- **project.yml**: `src/project.yml`（`src/` で xcodegen 実行必須）
- **macOS 13+ / Swift 5.9+**
- **設計書**: `docs/design/current/clabotch_design_doc_v11.md`（変更禁止、逸脱は patches/）
- **PAT**: Fine-grained PAT（リモート URL 埋め込み）。`workflow` スコープ追加済み
- **gh CLI**: `yukinakata` アカウント。`nakatadesign` リポジトリへの API アクセス不可

---

## ユーザーフィードバック（次セッション必読）

- **次フェーズ自動選択**: 候補をユーザーに列挙せず、優先度ルールに従い自動で着手する
