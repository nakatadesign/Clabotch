# HANDOVER.md — Clabotch セッション引き継ぎ

## 1. セッション概要

- **日時**: 2026-03-15 (JST)
- **作業目的**: AX 権限フロー全面改善 + 表情デザイン追加 + バグ修正 + UX 改善
- **全体進捗**:
  - 完了: AX 権限フロー改善、ポーリング最適化、設定画面拡張、表情デザイン3種追加、sleep 復帰改善、吹き出し文言変更、stop hook 修正、メニュークリック演出
  - 進行中: なし
  - 未着手: v1.0 残タスク（LaunchAgent、Notarization、Warp 完全対応）

---

## 2. 完了した作業

### 2a. AX 権限フロー全面改善

| コミット | 内容 |
|----------|------|
| `8c991a1` | `didRequestAccessibility` 廃止、`GazePermissionStatus` を granted/notGranted の2値化 |
| `682b562` | 権限が granted に変化したとき吹き出し「視線追跡が有効になりました」表示 |
| `08210f9` | AX 権限案内の文言改善（追加+チェック / 外して再チェック） |
| `d18c0d3` | 起動時に AX 権限がない場合アラート表示 + システム設定を開く |
| `6ea0968` | AX 権限復旧アラートのテスト3件追加 |

**変更ファイル**: `GazeTypes.swift`, `GazeController.swift`, `AppDelegate.swift`, `OnboardingWindowController.swift`, `CoordinatorBinder.swift`

### 2b. AX 権限ポーリング最適化

| コミット | 内容 |
|----------|------|
| `7220fc0` | granted 時 0.5秒、notGranted 時 2.0秒に切替 |
| `24a54f5` | 初回 poll で間隔調整が即座に発動するよう修正 |
| `d0c4598` | テスト追加（間隔切替、設定画面 UI） |

**変更ファイル**: `GazeController.swift`

### 2c. 設定画面にAX権限ボタン追加 (`53c62ed`)

- ステータスラベル「✓ 有効」/「未許可」
- 「アクセシビリティ設定を確認...」ボタン → システム設定を開く
- 権限変化時にステータスラベル自動更新
- ウィンドウ高さ 200→260px

**変更ファイル**: `SettingsWindowController.swift`, `CoordinatorBinder.swift`, `AppDelegate.swift`

### 2d. 表情デザイン追加

| コミット | 内容 |
|----------|------|
| `b5965b2` | sleeping 目を ^_^ 逆V字に変更（row 7 両端 + row 8 中央） |
| `7751d71` | done アニメ完了後にハッピー目表示（初版） |
| `e4c9ea5` | ハッピー目を ⌒ 上向きアーチに修正（row 6 中央 + row 7 両端） |
| `097aa15` | テスト更新（sleeping/done 目デザイン変更対応） |

**変更ファイル**: `ClabotchEyeView.swift`

**目のデザイン一覧（現在）**:
- **通常**: 3×8 矩形瞳（各方向でカスタム形状あり）
- **sleeping** (`showSleepingEyes`): ^_^ 下向き（row 7 両端 + row 8 中央3dot）
- **happy/done完了** (`showHappyEyes`): ⌒ 上向き（row 6 中央3dot + row 7 両端）
- **error** (`showErrorX`): × マーク
- **瞬き** (`blinkStage`): 横棒線

### 2e. ターミナルクリックで sleep 復帰

| コミット | 内容 |
|----------|------|
| `06be2a7` | `StateMachine.wakeFromSleep()` + `GazeController.onTerminalClicked` + CoordinatorBinder 結線 |
| `c90c3d1` | テスト5件追加 |

### 2f. 吹き出しテキスト変更 (`0d2ab38`)

- working: 「Bash 実行中...」→「作業中... (Bash)」
- thinking: 「考えてます...」（変更なし）

### 2g. stop hook バグ修正 (`51c3d27`)

- `clabotch_stop.sh` の `$()` NDJSON 連結バグ修正
- `{ printf ... } | send_json` パイプ直接送信に変更

### 2h. メニュークリック演出

| コミット | 内容 |
|----------|------|
| `2d0a003` | メニュー表示中にエラー目(×)を表示 |
| `c4ec41c` | 120ms で自動復帰（一瞬だけ×目） |

---

## 3. 重要な意思決定と理由

### didRequestAccessibility 廃止 → AXIsProcessTrusted() 一元化
- **採用**: `GazePermissionStatus` を granted/notGranted の2値に簡素化
- **理由**: UserDefaults のフラグが TCC リセット後に不整合を起こし、永久 denied になるバグがあった
- **却下**: 3値維持（notDetermined/granted/denied）→ didRequestAccessibility への依存が残る

### ポーリング間隔の2段階切替
- **採用**: granted=0.5s, notGranted=2.0s
- **理由**: 未許可時に AX API を呼ばないため低頻度で十分。CPU 負荷を 4 分の 1 に削減
- **却下**: 3段階以上 → 過度な複雑化、現時点では不要

### sleeping/happy 目のデザイン分離
- **採用**: `showSleepingEyes`（^_^ 下向き）と `showHappyEyes`（⌒ 上向き）を別フラグで管理
- **理由**: done 完了後の happy と sleeping は意味が異なるためデザインも分ける
- **却下**: blinkStage=closed の流用 → sleeping 専用デザインが表現できない

---

## 4. バグ・問題点と解決策

### Bug 1: /Applications/Clabotch.app が古いビルドのまま
- **原因**: 起動中のアプリを `cp -R` で上書きしても反映されない
- **解決**: `pkill → rm -rf → cp -R → tccutil reset → open`
- **注意**: 開発中は毎回この手順が必要

### Bug 2: ポーリング間隔が notGranted 時に切り替わらない
- **原因**: `adjustPollInterval()` が「変化時のみ」呼ばれていた。初回 poll で notGranted→notGranted=変化なし
- **解決**: `checkPermission()` の毎回呼び出しで `adjustPollInterval()` を実行

### Bug 3: テストで pollIntervalNotGranted 未指定
- **原因**: デフォルト 2.0s のため、pollInterval=0.05s のテストでタイムアウト
- **解決**: テストに `pollIntervalNotGranted: 0.05` を明示指定

---

## 5. 学んだ教訓と落とし穴

1. **ad-hoc 署名とTCC**: リビルドのたびに署名が変わり、AX 権限がリセットされる。`tccutil reset` + システム設定再チェックが必要。配布ビルド（Developer ID）では軽減される
2. **/Applications へのコピー**: アプリ起動中は `cp -R` が効かない。必ず先に `pkill` + `rm -rf`
3. **NSAlert のアイコン**: LSUIElement アプリでは `alert.icon = NSApp.applicationIconImage` を明示指定しないとアイコンが表示されない
4. **Timer 再作成**: `pollTimer?.invalidate()` → 新しい Timer 作成 → `pollTimer = timer` の順序が重要

---

## 6. 次のステップ（優先度順）

### 🟡 中優先度

| タスク | 状態 | 備考 |
|--------|------|------|
| 表情追加の検討 | 未着手 | waiting（ユーザー入力待ち）等の候補あり |
| Codex レビュー | Codex 復旧待ち（Mar 19） | 全変更をレビュー予定 |

### 🟢 低優先度

| タスク | 状態 | 備考 |
|--------|------|------|
| v1.0: LaunchAgent | 未着手 | ログイン時自動起動のシステム化 |
| v1.0: Notarization | 未着手 | 配布用署名・公証 |
| v1.0: Warp 完全対応 | 未着手 | |

---

## 7. 重要ファイルマップ

| ファイル | 役割 | 今セッションの変更 |
|----------|------|----------|
| `src/Clabotch/GazeTypes.swift` | 視線関連型定義 | GazePermissionStatus 2値化、FixedGazeReason 統合 |
| `src/Clabotch/GazeController.swift` | 視線追跡 | didRequestAccessibility 廃止、ポーリング間隔切替、onTerminalClicked 追加 |
| `src/Clabotch/StateMachine.swift` | 状態管理 | wakeFromSleep() 追加 |
| `src/Clabotch/CoordinatorBinder.swift` | SM→下流結線 | 権限変化フィードバック、sleep 復帰結線、onAccessibilityStatusChanged |
| `src/Clabotch/AppDelegate.swift` | アプリ起動・結線 | AX アラート、設定画面更新結線、NSMenuDelegate |
| `src/Clabotch/ClabotchEyeView.swift` | 顔描画 | sleeping 目、happy 目、メニュー×目 |
| `src/Clabotch/SettingsWindowController.swift` | 設定画面 | AX 権限ステータス+ボタン追加 |
| `src/Clabotch/OnboardingWindowController.swift` | オンボーディング | コメント修正、アイコン設定 |
| `hooks/clabotch_stop.sh` | Stop hook | $() NDJSON 連結バグ修正 |
| `src/ClabotchTests/GazeControllerTests.swift` | 視線テスト | 2値化対応、ポーリング間隔テスト |
| `src/ClabotchTests/ClabotchEyeViewTests.swift` | 描画テスト | sleeping/done 目デザイン対応 |
| `src/ClabotchTests/CoordinatorIntegrationTests.swift` | 統合テスト | sleeping 判定更新 |
| `src/ClabotchTests/SettingsWindowControllerTests.swift` | 設定テスト | AX UI テスト、wakeFromSleep テスト |

---

## 8. 環境・依存関係メモ

- **ビルド**: `cd src && xcodegen generate && xcodebuild test -project Clabotch.xcodeproj -scheme Clabotch -destination 'platform=macOS'`
- **project.yml**: `src/` 直下
- **macOS 13+ / Swift 5.9+**
- **設計書**: `docs/design/current/clabotch_design_doc_v11.md`（変更禁止、逸脱は patches/）
- **総テスト**: 321 件（320 passed, 1 skipped）+ hook E2E 43 件
- **GEMINI_API_KEY**: `.env` に設定済み（totonoe Gemini フォールバック有効）
- **コミット**: `097aa15` test: sleeping/done 目デザイン変更に合わせてテスト更新（最新）

### /Applications への更新手順

```bash
pkill -f "Clabotch.app"
sleep 1
rm -rf /Applications/Clabotch.app
cp -R ~/Library/Developer/Xcode/DerivedData/Clabotch-*/Build/Products/Debug/Clabotch.app /Applications/Clabotch.app
tccutil reset Accessibility com.clabotch.app
open /Applications/Clabotch.app
# → アラート「システム設定を開く」→ Clabotch にチェック
```

### hooks 設定

`~/.claude/settings.json` に以下の4 hooks が登録済み:
- PreToolUse / PostToolUse / PostToolUseFailure / Stop

---

## ユーザーフィードバック（次セッション必読）

- **次フェーズ自動選択**: 候補をユーザーに列挙せず、優先度ルールに従い自動で着手する
- **AX 権限**: リビルド後は必ず `/Applications` 更新 + tccutil reset + チェック
- **hooks 確認**: セッション開始時に hooks ファイルが `.bak` にリネームされていないか確認
- **update() 実行順序**: アプリ切替検出は override チェック前に配置する（GazeController）
- **totonoe の apply_manager_decision.sh**: critical_count > 0 で done が human に自動降格される（false positive 対策未了）
