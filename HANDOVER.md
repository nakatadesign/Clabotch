# HANDOVER.md — Clabotch セッション引き継ぎ

## 1. セッション概要

- **日時**: 2026-03-15 (JST)
- **作業目的**: 表情デザイン全面改修 + アプリアイコン追加 + 表情変化が動作しない問題の根本修正
- **全体進捗**:
  - 完了: 表情デザイン改修、アプリアイコン、hooks 復旧、バグ3件修正、SESSION_REGISTRY クリア
  - 進行中: なし
  - 未着手: v1.0 残タスク（設定画面拡張、LaunchAgent、Notarization、Warp対応）

---

## 2. 完了した作業

### 2a. 表情デザイン全面改修 (`536b41d`)

- **顔サイズ変更**: 22x14 → 20x14（左右余白2pxで天地と統一）
  - `src/Clabotch/ClabotchEyeView.swift` — canvasWidth=20、眼窩・瞳位置シフト
- **瞳カスタム形状**: 左下/右下/左上/右上で row7 に1px欠け
  - 左下: 右端欠け、右下: 左端欠け、左上: 左下と同じ、右上: 右下と同じ
- **瞬き簡素化**: 単一120ms closed ステージ（白目残し+横棒線）
- **考え中アニメ**: 右上↔左上の視線交互、間隔 0.4s → 0.8s
- **完了表情**: ultrathink風淡パステルグラデーション + 瞳2回転スピン
  - グラデ色: 淡オレンジ/淡ピンク/淡パープル/淡ブルー
  - 流れ方向: 左→右、hueStep=0.10（高速）
- **エラー表情**: 閉じ目ピクセルアート（黒色）+ シェイク
- **ジャンプ**: 1回→2回バウンド `[6, 12, 4, 0, 4, 8, 2, 0]`
- **視線追跡**: 左下/右下の2方向のみ（水平方向廃止）、左右閾値60%
  - `src/Clabotch/GazeController.swift` — quantize() 簡素化

### 2b. アプリアイコン追加 (`536b41d`)

- `src/generate_icon.swift` — コード生成スクリプト（NSBitmapImageRep使用）
- `src/Clabotch/Assets.xcassets/AppIcon.appiconset/` — 全サイズPNG + Contents.json
- `src/project.yml` — `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` 追加
- PNG素材ゼロ方針を維持（コードから生成）

### 2c. テスト更新 (`536b41d`)

- `src/ClabotchTests/ClabotchEyeViewTests.swift` — ジャンプ8要素、thinking 0.8s対応
- `src/ClabotchTests/GazeControllerTests.swift` — 水平視線テストを左下/右下に更新
- 全312テスト合格

### 2d. 表情変化が動作しない問題の根本修正

3つのバグを発見・修正（未コミット）:

| ファイル | バグ | 修正 |
|---------|------|------|
| `hooks/clabotch_lib.sh` | ソケットパス不一致（`$TMPDIR/clabotch.sock` → `$TMPDIR/clabotch/hook.sock`） | 実際のHookServerパスに合わせた |
| `hooks/clabotch_pre_tool.sh` | `$()` が末尾改行除去 → session_start + tool_start 連結 → パース失敗 | `{ printf ... } | send_json` パイプ直接送信 |
| `src/Clabotch/BubbleWindow.swift` | `isReleasedWhenClosed` デフォルトtrue → close()+ARCで二重解放 → SIGSEGV | `w.isReleasedWhenClosed = false` 追加 |

### 2e. SESSION_REGISTRY クリア

- `src/Clabotch/AppDelegate.swift` — HookServer起動成功後に `$TMPDIR/clabotch_sessions` を削除
- hooks側の「session_start送信済み」誤認を防止

### 2f. hooks 復旧

- 前セッションで `.bak` にリネームされていた hooks を復元
- `hooks/clabotch_pre_tool.sh`, `hooks/clabotch_post_tool.sh`, `hooks/clabotch_post_tool_failure.sh`

---

## 3. 重要な意思決定と理由

### 顔サイズ 20x14
- **採用**: 左右余白2pxで天地と統一、対称性を重視
- **理由**: ユーザーが天地の2px余白に左右も合わせたいと要望

### 瞳カスタム形状（row7 1px欠け）
- **採用**: ユーザーがピクセルアートグリッドで直接指定
- **右目は左目と同じ形状**（反転ではない）: ユーザー指示「右目は反転させず左目と同じにして」
- 右下/右上のみ左右反転形状

### 視線2方向のみ
- **採用**: 左下/右下のみ（水平方向 f06_right, f07_left を廃止）
- **理由**: ユーザーが「視線の誘導を左右だけはやめて左下と右下に固定」と指示

### アイコン生成方式
- **採用**: `generate_icon.swift` でコード生成 → Asset Catalog
- **却下**: NSApplication.shared.applicationIconImage（Dockにしか効かない）
- **却下**: NSImage.lockFocus（Retinaで2xサイズになる）
- **採用**: NSBitmapImageRep 直接描画（正確なピクセルサイズ）

---

## 4. バグ・問題点と解決策

### Bug 1: ソケットパス不一致
- **原因**: `clabotch_lib.sh` が `$TMPDIR/clabotch.sock` を参照、HookServer は `$TMPDIR/clabotch/hook.sock` に作成
- **解決**: lib のパスを実際のパスに修正

### Bug 2: NDJSON パース失敗
- **原因**: `$()` コマンド置換が末尾改行を除去 → session_start と tool_start の JSON が連結
- **解決**: `{ printf ... } | send_json` でパイプ直接送信

### Bug 3: BubbleWindow 二重解放
- **原因**: `isReleasedWhenClosed` デフォルト true + ARC の解放が競合
- **解決**: `w.isReleasedWhenClosed = false`

### Bug 4: SESSION_REGISTRY 陳腐化
- **原因**: アプリ再起動で StateMachine リセットされるが、hooks 側のセッション登録ファイルが残存
- **解決**: HookServer 起動成功後に `$TMPDIR/clabotch_sessions` を削除

### Bug 5: デモイベントの duration フィールド名
- **原因**: `tool_end` で `elapsed_ms` を送信していたが EventParser は `duration_ms` を期待
- **解決**: 正しいフィールド名 `duration_ms` を使用

### Bug 6: sleeping が即座に発動
- **原因**: UserDefaults の `sleepTimeoutMinutes=0` が無限大を意味せず、AppDelegate の `updateSleepThreshold` がデフォルト値を上書き
- **解決**: UserDefaults の値を適切に設定

### 注意: システム設定のアイコンキャッシュ
- macOS はアイコンを強力にキャッシュ。`lsregister` 再登録やキャッシュクリアでも反映されない場合あり
- **システム再起動で反映される**（ユーザー了承済み）

---

## 5. 学んだ教訓と落とし穴

1. **`$()` コマンド置換と改行**: シェルの `$()` は末尾改行を除去する。NDJSON で複数行を送信する場合は `{ printf ...; printf ...; } | send_json` のようにパイプで直接送信する
2. **`isReleasedWhenClosed`**: NSWindow のデフォルトは true。ARC 環境では二重解放になるため、プログラムで管理する NSWindow は必ず false に設定する
3. **NSImage.lockFocus vs NSBitmapImageRep**: Retina ディスプレイでは lockFocus が 2x サイズの画像を作成する。正確なピクセルサイズが必要な場合は NSBitmapImageRep を直接使用する
4. **EventParser のフィールド名**: `tool_end` は `duration_ms`（`elapsed_ms` ではない）。間違えるとイベントがサイレントにドロップされる
5. **hooks の `.bak` リネーム**: セッション間で hooks が無効化されている可能性がある。セッション開始時に hooks ファイルの存在を確認する
6. **AX 権限リセット**: ad-hoc 署名の再ビルドで TCC 権限がリセットされる。開発時のみの問題で配布ビルドでは発生しない

---

## 6. 次のステップ（優先度順）

### 🔴 高優先度（ブロッカー）

| タスク | 状態 | 備考 |
|--------|------|------|
| バグ修正3件のコミット | 未コミット | clabotch_lib.sh, clabotch_pre_tool.sh, BubbleWindow.swift |
| ClabotchEyeView.swift デバッグログ削除 | 未実施 | `os_log` + `import os.log` をコミット前に削除 |

### 🟡 中優先度

| タスク | 状態 | 備考 |
|--------|------|------|
| Codex レビュー | Codex 復旧待ち（Mar 19） | 全変更を Codex でレビュー予定 |
| 表情追加の検討 | 未着手 | happy、waiting 等の候補あり（ユーザーと議論済み、未決定） |
| GEMINI_API_KEY 設定 | 外部依存 | totonoe Gemini フォールバック有効化 |

### 🟢 低優先度

| タスク | 状態 | 備考 |
|--------|------|------|
| v1.0: 設定画面拡張 | 未着手 | |
| v1.0: LaunchAgent | 未着手 | |
| v1.0: Notarization | 未着手 | |
| v1.0: Warp 完全対応 | 未着手 | |

---

## 7. 重要ファイルマップ

| ファイル | 役割 | 変更内容 |
|----------|------|----------|
| `src/Clabotch/ClabotchEyeView.swift` | 顔描画・アニメーション | 全面改修: サイズ、瞳形状、グラデ、ジャンプ、各表情 |
| `src/Clabotch/GazeController.swift` | 視線追跡 | quantize() を2方向に簡素化 |
| `src/Clabotch/BubbleWindow.swift` | 吹き出しウィンドウ | isReleasedWhenClosed=false 修正 |
| `src/Clabotch/AppDelegate.swift` | アプリ起動・結線 | SESSION_REGISTRY クリア追加 |
| `hooks/clabotch_lib.sh` | hooks共通ライブラリ | ソケットパス修正 |
| `hooks/clabotch_pre_tool.sh` | ツール実行前フック | NDJSON送信方式修正 |
| `src/generate_icon.swift` | アイコン生成スクリプト | 新規作成 |
| `src/Clabotch/Assets.xcassets/` | Asset Catalog | AppIcon 追加 |
| `src/project.yml` | Xcodegen設定 | ASSETCATALOG_COMPILER_APPICON_NAME 追加 |
| `src/ClabotchTests/ClabotchEyeViewTests.swift` | 描画テスト | ジャンプ・thinking タイミング更新 |
| `src/ClabotchTests/GazeControllerTests.swift` | 視線テスト | 水平視線テスト→左下/右下に更新 |

---

## 8. 環境・依存関係メモ

- **ビルド**: `cd src && xcodegen generate && xcodebuild test -project Clabotch.xcodeproj -scheme Clabotch -destination 'platform=macOS'`
- **project.yml**: `src/` 直下
- **macOS 13+ / Swift 5.9+**
- **設計書**: `docs/design/current/clabotch_design_doc_v11.md`（変更禁止、逸脱は patches/）
- **総テスト**: 312 件全パス + hook E2E 43 件
- **Codex**: 使用上限到達（Mar 19 リセット）→ 復旧後に全変更をレビュー予定
- **GEMINI_API_KEY**: 未設定
- **コミット**: `536b41d` feat: 表情デザイン全面改修 + アプリアイコン追加

### hooks 設定

`~/.claude/settings.json` に以下の4 hooks が登録済み:
- PreToolUse / PostToolUse / PostToolUseFailure / Stop

### AX 権限

リビルド後は以下を実行:
```bash
tccutil reset Accessibility com.clabotch.app
defaults write com.clabotch.app didRequestAccessibility -bool false
defaults write com.clabotch.app didShowOnboarding -bool false
```
その後、システム設定 → プライバシーとセキュリティ → アクセシビリティで Clabotch を許可。

---

## ユーザーフィードバック（次セッション必読）

- **次フェーズ自動選択**: 候補をユーザーに列挙せず、優先度ルールに従い自動で着手する
- **AX 権限案内**: リビルド後は必ずアクセシビリティ再許可を案内する
- **hooks 確認**: セッション開始時に hooks ファイルが `.bak` にリネームされていないか確認する
- **update() 実行順序**: アプリ切替検出は override チェック前に配置する（GazeController）
