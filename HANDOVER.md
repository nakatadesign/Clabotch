# HANDOVER.md — Clabotch セッション引き継ぎ

## 1. セッション概要

- **日時**: 2026-03-13 (JST)
- **作業目的**: 視線制御の attention モデル実装 + クリック検出 + バグ修正
- **全体進捗**:
  - 完了: 6 タスク（attention モデル、クリック検出、override 優先順位修正、スリープ修正、hooks 登録、アプリ切替検出修正）
  - 進行中: 1 タスク（視線がまだ実環境で動作しない → AX 権限 + hooks 登録の環境設定待ち）
  - 未着手: 残 backlog タスク

---

## 2. 完了した作業

### 2a. attention ベース視線制御 (`a7b2af5`)
常時 AX 追尾をやめ、イベント駆動の attention モデルに移行。フェーズ変更/アプリ切替時のみ 2 秒間一時注視。
- `src/Clabotch/GazeController.swift` — attentionExpiry, lookAtTerminal(), now: DI
- `src/Clabotch/GazeTypes.swift` — FixedGazeReason.attentionNeutral 追加
- `src/Clabotch/CoordinatorBinder.swift` — thinking/working 遷移時に lookAtTerminal() 呼び出し
- `src/ClabotchTests/GazeControllerTests.swift` — attention テスト 9 件追加

### 2b. グローバルクリック検出 (`d46d011`)
ターミナルウィンドウへのクリックで注視を再開する機能。
- `src/Clabotch/GazeTypes.swift` — GlobalEventMonitorProviding プロトコル追加
- `src/Clabotch/AXProvider.swift` — RealGlobalEventMonitor 本番実装 + deinit
- `src/Clabotch/GazeController.swift` — eventMonitor DI, handleGlobalClick()
- `src/ClabotchTests/MockProviders.swift` — MockGlobalEventMonitor
- `src/ClabotchTests/GazeControllerTests.swift` — クリック検出テスト 5 件
- `docs/design/patches/patch_013_attention_gaze_model.md` — 設計書逸脱記録

### 2c. attention vs override 優先順位修正 (`1f10164`)
idle/done の stateOverride が attention を常にブロックしていたバグを修正。
- `src/Clabotch/GazeTypes.swift` — GazeOverride.fixed に `allowsAttentionOverride` パラメータ追加
- `src/Clabotch/CoordinatorBinder.swift` — idle/done: true, error/sleeping: false
- `src/Clabotch/GazeController.swift` — フラグベース優先順位判定
- テスト 4 件追加（idle override バイパス / error 不変 / sleeping 不変 / 期限切れ復帰）

### 2d. アプリ切替検出の位置修正（未コミット）
update() 内のアプリ切替検出が stateOverride の early return 後にあり、idle 時に到達しなかったバグを修正。
- `src/Clabotch/GazeController.swift` — アプリ切替検出を override チェックの前に移動

### 2e. スリープ無効化バグ修正 (`e4e88b7`)
設定でスリープを無効にしても `.sleeping` から戻らなかった問題。
- `src/Clabotch/StateMachine.swift` — updateSleepThreshold() で sleeping 中の閾値変更を考慮
- `src/ClabotchTests/SettingsWindowControllerTests.swift` — テスト 2 件追加

### 2f. Claude Code hooks 登録
`~/.claude/settings.json` に Clabotch の hooks を登録（未登録だった）。
- `~/.claude/settings.json` — PreToolUse / PostToolUse / PostToolUseFailure / Stop の 4 hooks

---

## 3. 重要な意思決定と理由

### attention モデルの採用
- **採用**: イベント駆動の一時注視（attentionExpiry + トリガー方式）
- **理由**: 常時 AX ポーリングは CPU 効率が悪く、ユーザーが意識していない間もマスコットが追跡し続ける不自然さがあった
- **却下**: カーソル追跡（設計書の「マウスカーソル追跡」は AX ベースのターミナルウィンドウ追跡として実装）

### allowsAttentionOverride フラグ
- **採用**: GazeOverride.fixed に Bool フラグを追加
- **理由**: frame の値（f02_rightDown）で idle/done を判定する方法は脆弱。型安全に CoordinatorBinder 側で意図を明示できる
- **却下**: frame 値による判定（偶然の一致に依存、将来の変更で壊れるリスク）

### GlobalEventMonitorProviding プロトコル
- **採用**: NSEvent.addGlobalMonitorForEvents の DI 抽象化
- **理由**: テストで実際の NSEvent モニターを使えないため、MockGlobalEventMonitor で simulateClick() を手動発火

---

## 4. バグ・問題点と解決策

### Bug 1: 視線が動かない（stateOverride が attention をブロック）
- **原因**: idle/done 状態の stateOverride(.f02_rightDown) が update() の先頭で常に early return
- **特定方法**: コードトレースで update() の制御フローを追跡
- **解決**: `allowsAttentionOverride` フラグで idle/done は attention 中にバイパス可能に

### Bug 2: アプリ切替検出が idle 時に到達しない
- **原因**: アプリ切替検出コード（lastFrontmostBundle 比較）が stateOverride の early return の**後**に配置
- **特定方法**: ログ追加で polling 中のフロー確認
- **解決**: アプリ切替検出を override チェックの前に移動

### Bug 3: handleGlobalClick のタイミング問題
- **原因**: クリックイベント発火時、前のアプリがまだ frontmost → supportedBundles に合致しない
- **対応**: アプリ切替検出（polling ベース）で ≤500ms 以内にカバー。クリックハンドラは既に frontmost なターミナルの再クリック用

### Bug 4: AX 権限が無効
- **原因**: ad-hoc 署名の再ビルドで TCC が権限をリセット
- **対応**: `tccutil reset Accessibility com.clabotch.app` + システム設定で再許可を案内

### Bug 5: hooks 未登録
- **原因**: `~/.claude/settings.json` に Clabotch の hooks が設定されていなかった
- **対応**: 4 つの hook エントリを settings.json に追加。セッション再起動が必要。

---

## 5. 学んだ教訓と落とし穴

1. **update() 内の実行順序**: early return する箇所より前に、常に実行すべきロジックを配置する。override チェックの後にアプリ切替検出を置くと idle 時に到達しない
2. **NSEvent.addGlobalMonitorForEvents のタイミング**: クリックイベント発火時、フロントアプリの切り替えはまだ完了していない。frontmostBundleIdentifier() は前のアプリを返す
3. **TCC と ad-hoc 署名**: Debug ビルド（ad-hoc 署名）を再ビルドするたびに AX 権限がリセットされる。ユーザーに再許可を案内する必要がある
4. **hooks は settings.json に明示登録が必要**: hook スクリプトが存在しても、Claude Code の settings.json に登録しないとイベントが送信されない。hooks はセッション起動時に読み込まれる
5. **Gemini API / Codex**: 両方とも利用不可（使用上限 / API キー未設定）。totonoe の reviewer/judge は `--force` フラグで Manager 直接レビューに切り替える

---

## 6. 次のステップ（優先度順）

### 🔴 高優先度（ブロッカー）

| タスク | 状態 | 備考 |
|--------|------|------|
| AX 権限の再許可 | 人間の作業 | システム設定 → プライバシーとセキュリティ → アクセシビリティで Clabotch を許可 |
| セッション再起動で hooks 有効化 | 人間の作業 | hooks は起動時に読み込まれるため、現セッション終了→新セッション開始が必要 |
| アプリ切替検出修正のコミット | 未コミット | `GazeController.swift` のアプリ切替検出位置修正 + デバッグログ |

### 🟡 中優先度

| タスク | 状態 | 備考 |
|--------|------|------|
| 実環境での視覚効果確認 | hooks 有効化後 | done スピン / error × マーク / sleeping 閉じ目 が実際に動作するか |
| デバッグログの削除 | 確認後 | GazeController の `os_log(.info, "[Gaze]...")` を確認後に削除 |
| GEMINI_API_KEY 設定 | 外部依存 | totonoe Gemini フォールバック有効化 |

### 🟢 低優先度

| タスク | 状態 | 備考 |
|--------|------|------|
| Stop hook error 調査 | 再現待ち | 再現したら着手 |
| hook E2E テスト [10] flaky 対策 | CI 再現待ち | CI で再現した場合 |
| PAT 権限追加 | 人間の作業 | GitHub API アクセス用。任意 |

---

## 7. 重要ファイルマップ

| ファイル | 役割 | 変更内容 |
|----------|------|----------|
| `src/Clabotch/GazeController.swift` | 視線追跡コントローラー | attention モデル、クリック検出、アプリ切替検出位置修正、デバッグログ |
| `src/Clabotch/GazeTypes.swift` | 視線関連型定義 | attentionNeutral, GlobalEventMonitorProviding, allowsAttentionOverride |
| `src/Clabotch/CoordinatorBinder.swift` | SM→下流結線 | lookAtTerminal() 呼び出し、allowsAttentionOverride 設定 |
| `src/Clabotch/AXProvider.swift` | AX/Workspace 抽象化 | RealGlobalEventMonitor 追加 |
| `src/Clabotch/StateMachine.swift` | 状態管理 | updateSleepThreshold() sleeping→idle 修正 |
| `src/ClabotchTests/GazeControllerTests.swift` | 視線テスト | attention 9件 + click 5件 + override 4件 = +18件 |
| `src/ClabotchTests/MockProviders.swift` | テストモック | MockGlobalEventMonitor 追加 |
| `docs/design/patches/patch_013_attention_gaze_model.md` | 設計書パッチ | attention モデル + allowsAttentionOverride の仕様記録 |
| `~/.claude/settings.json` | Claude Code 設定 | hooks 4件登録（PreToolUse/PostToolUse/PostToolUseFailure/Stop） |

---

## 8. 環境・依存関係メモ

- **ビルド**: `cd src && xcodegen generate && xcodebuild test -project Clabotch.xcodeproj -scheme Clabotch -destination 'platform=macOS'`
- **project.yml**: `src/project.yml`（`src/` で xcodegen 実行必須）
- **macOS 13+ / Swift 5.9+**
- **設計書**: `docs/design/current/clabotch_design_doc_v11.md`（変更禁止、逸脱は patches/）
- **総テスト**: 300 件（299 passed, 1 skipped）+ hook E2E 43 件
- **PAT**: Fine-grained PAT（リモート URL 埋め込み）。`workflow` スコープ追加済み
- **gh CLI**: `yukinakata` アカウント。`nakatadesign` リポジトリへの API アクセス不可
- **Codex**: 使用上限到達（Mar 19 まで利用不可）
- **GEMINI_API_KEY**: 未設定（totonoe Gemini フォールバック不可）

### 設定変更

| 変更 | ファイル | 内容 |
|------|----------|------|
| hooks 登録 | `~/.claude/settings.json` | Clabotch の 4 hooks を追加 |
| TCC リセット | システム | `tccutil reset Accessibility com.clabotch.app` 実行済み |

---

## ユーザーフィードバック（次セッション必読）

- **次フェーズ自動選択**: 候補をユーザーに列挙せず、優先度ルールに従い自動で着手する
- **AX 権限案内**: リビルド後は必ずアクセシビリティ再許可を案内する
- **hooks 確認**: セッション開始時に `~/.claude/settings.json` の hooks セクションが存在するか確認する
