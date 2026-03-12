# HANDOVER.md — Clabotch セッション引き継ぎ

## 1. セッション概要

- **日時**: 2026-03-12（JST）
- **作業目的**: 計画 007〜009 実装 + 回帰テスト追加 + テスト seam 導入
- **全体進捗**:
  - 完了: 計画 002, 003, 004, 005, 006, 007, 008, 009
  - 保留: Stop hook error 調査
  - 総テスト: **203 件**（202 passed, 1 skipped）
  - origin main と同期済み（`e442495`）

---

## 2. 完了した作業

### 2a. 計画 007 — CoordinatorBinder 抽出 + 下流連携テスト（`95b15fe`）

review-loop job `plan007-impl` で 2 ラウンド実施し done 達成。

| ファイル | 変更内容 |
|----------|---------|
| `src/Clabotch/BubblePresenting.swift` | 吹き出し表示プロトコル（新規） |
| `src/Clabotch/CoordinatorBinder.swift` | AppDelegate から抽出した結線ロジック（新規） |
| `src/Clabotch/BubbleWindow.swift` | BubblePresenting 準拠宣言追加 |
| `src/Clabotch/AppDelegate.swift` | CoordinatorBinder 委譲 |
| `src/ClabotchTests/BubbleSpy.swift` | BubblePresenting 準拠の test double（新規） |
| `src/ClabotchTests/CoordinatorIntegrationTests.swift` | 統合テスト 21 件（新規） |
| `src/ClabotchTests/AppDelegateCoordinatorTests.swift` | 参照更新 + マッピングテスト追加 |

### 2b. 計画 008 — HookServer 起動失敗時の半初期化修正（`2f7790c`）

| ファイル | 変更内容 |
|----------|---------|
| `src/Clabotch/AppDelegate.swift` | `stateMachine.start()` / `gazeController.startPolling()` を do-catch 外に移動。`.alreadyRunning` catch に `return` 追加。ログレベル `.fault` に昇格 |

### 2c. 計画 009 — Warp AX 属性ダンプ + 昇格判断（`19d102c`）

AX 属性ダンプの結果 **COMPATIBLE** と判定。Warp を `supportedBundles` に昇格。

| ファイル | 変更内容 |
|----------|---------|
| `tests/ax_dump.swift` | AX 属性ダンプスクリプト（新規） |
| `src/Clabotch/GazeController.swift` | `tentativeBundles` を空にし `supportedBundles` に `dev.warp.Warp-Stable` 追加 |
| `src/ClabotchTests/GazeControllerTests.swift` | Warp テストを `.unsupportedTerminal` → `.tracking` に変更 |
| `docs/design/patches/patch_009_warp_ax_investigation.md` | 調査結果の記録（新規） |

### 2d. phaseName 回帰テスト追加（`727881a`）

| ファイル | 変更内容 |
|----------|---------|
| `src/ClabotchTests/AppDelegateCoordinatorTests.swift` | `testPhaseNameReturnsOnlyCaseName` + `testPhaseNameDoesNotLeakErrorMessage` 追加（+2 テスト） |

### 2e. BubbleWindow テスト seam 導入（`e442495`）

| ファイル | 変更内容 |
|----------|---------|
| `src/Clabotch/BubbleWindow.swift` | `windowFactory` / `timerScheduler` DI クロージャ追加、`isShowing` を stored property に変更 |
| `src/ClabotchTests/BubbleWindowTests.swift` | show/dismiss/auto-dismiss ライフサイクルテスト +6 件 |

---

## 3. 重要な意思決定と理由

### 3a. Warp BundleIdentifier の不一致

- 設計書 v11 §11.5 では `dev.warp.desktop` だが、実機は `dev.warp.Warp-Stable`
- Homebrew Cask でインストールした Warp Stable の正式 ID
- 逸脱を `docs/design/patches/patch_009_warp_ax_investigation.md` に記録済み

### 3b. BubbleWindow isShowing の stored property 化

- 初回実装では `isShowing` を `window != nil` で導出していたが、ヘッドレスで windowFactory が nil を返す場合にテスト不能
- `isShowing` を stored property にして show()/dismiss() で明示的に更新する方式に変更
- windowFactory が nil を返してもライフサイクルのテストが可能に

### 3c. ヘッドレス環境での NSWindow 生成回避

- 当初 off-screen の NSWindow スタブを返す方式 → テストがハングしてタイムアウト
- windowFactory が nil を返すアプローチに切り替えて解決

---

## 4. バグ・問題点と解決策

### 4a. BubbleWindow テスト初回ハング

- **問題**: off-screen NSWindow (`defer: true`, 座標 -9999) を返す windowFactory でもテストがタイムアウト
- **原因**: ヘッドレステスト環境で NSWindow 生成自体がウィンドウサーバーと干渉
- **解決**: windowFactory で nil を返し、isShowing を stored property に変更
- **再発防止**: BubbleWindow テストでは NSWindow を一切生成しない

### 4b. Warp プロセス名の不一致

- **問題**: `pgrep -x Warp` で Warp のプロセスが見つからない
- **原因**: Warp の実行ファイル名は `stable`（`/Applications/Warp.app/Contents/MacOS/stable`）
- **解決**: `ps aux | grep -i warp` で PID を特定
- **再発防止**: AX ダンプスクリプトのドキュメントに注記

---

## 5. 学んだ教訓と落とし穴

- **Warp のプロセス名**: `Warp` ではなく `stable`。`pgrep -x Warp` は使えない
- **ヘッドレス NSWindow**: `defer: true` や off-screen 配置でも安全ではない。テストでは NSWindow 生成自体を回避すべき
- **BundleIdentifier の調査**: 設計書の情報が古い場合がある。実機の `Info.plist` を `defaults read` で確認すること

---

## 6. 次の優先タスク

1. **最優先**: CI 整備 — GitHub Actions で build/test を自動化し回帰防止を強化。優先度: 保守性改善（3）
2. **保留**: Stop hook error 調査 — 前セッションで報告あり、再現せず。再現したら着手。優先度: 調査（5）
3. **保留**: BubbleWindow 実環境テスト — GUI 環境限定の結合テスト。CI 不要。優先度: 調査（5）

---

## 7. 重要ファイルマップ

| ファイル | 役割 | 本セッションの変更 |
|----------|------|-------------------|
| `src/Clabotch/AppDelegate.swift` | Coordinator 役。HookServer + UI 初期化 | 計画 007: CoordinatorBinder 委譲、計画 008: do-catch 分離 |
| `src/Clabotch/CoordinatorBinder.swift` | StateMachine → 下流の結線 | 新規（計画 007） |
| `src/Clabotch/BubblePresenting.swift` | 吹き出し抽象プロトコル | 新規（計画 007） |
| `src/Clabotch/BubbleWindow.swift` | 吹き出しウィンドウ実装 | DI seam 追加（windowFactory, timerScheduler） |
| `src/Clabotch/GazeController.swift` | 視線追跡コントローラ | Warp を supportedBundles に昇格 |
| `tests/ax_dump.swift` | AX 属性ダンプ調査ツール | 新規（計画 009） |
| `docs/design/patches/patch_009_warp_ax_investigation.md` | Warp AX 調査結果 | 新規 |
| `src/ClabotchTests/CoordinatorIntegrationTests.swift` | CoordinatorBinder 統合テスト 21 件 | 新規 |
| `src/ClabotchTests/BubbleSpy.swift` | BubblePresenting test double | 新規 |
| `src/ClabotchTests/AppDelegateCoordinatorTests.swift` | static 変換メソッド + phaseName テスト | phaseName 回帰テスト +2 |
| `src/ClabotchTests/BubbleWindowTests.swift` | BubbleWindow ライフサイクルテスト | DI seam 対応で全面書き直し +6 |

---

## 8. 環境・依存関係メモ

- **ビルドコマンド**: `cd src && xcodegen generate && xcodebuild test -project Clabotch.xcodeproj -scheme Clabotch -destination 'platform=macOS'`
- **project.yml**: `src/project.yml`（`src/` で xcodegen 実行必須）
- **macOS 13+ / Swift 5.9+**
- **設計書**: 変更禁止。逸脱は `docs/design/patches/` に patch 文書で管理
- **インストール済み**: Warp（`brew install --cask warp`、BundleID: `dev.warp.Warp-Stable`）
- **Git**: main ブランチ、origin と同期済み（`e442495`）

---

## 残留リスク

| リスク | 対応 |
|--------|------|
| HANDOVER.md.bak がリポジトリルートに残存 | バックアップファイル。コミット不要。必要なら削除 |
| BubbleWindow show() の実環境テスト未実施 | DI seam でロジックはカバー済み。GUI テストは任意 |
| activeBubble/ephemeralBubble 同一型リスク | init パラメータ名で軽減。型安全ではなく手動レビュー依存 |
| Warp の BundleIdentifier 変更リスク | 将来のバージョンで `dev.warp.Warp-Stable` が変わる可能性 |

---

## Pause Handover（2026-03-12 セッション中断）

### 1. active job
review-loop の active job なし。全 job は `done` または `smoke-*`（無視対象）。今回のタスクは review-loop 外の自動継続ポリシーによる計画 010 CI 整備。

### 2. 現在の作業状態
**計画 010（GitHub Actions CI 整備）の Codex 計画レビュー round 9 実行中に停止指示を受領。**

- Round 1〜8: すべて B 評価（前セッションで実行済み）
- Round 9: Codex レビューコマンドを実行し、応答受信中に停止。結果は未評価。

### 3. 中断したコマンド
`codex exec --full-auto` による計画レビュー（round 9）。バックグラウンドで完了済みの可能性あるが、結果は未評価・未反映。

### 4. 未コミット変更ファイル一覧

| ファイル | 状態 | 変更内容 |
|----------|------|----------|
| `docs/exec-plans/active/010-ci-setup.md` | untracked (新規) | CI 計画書。Round 8 の B 指摘を反映済み（round 9 投入版） |
| `CLAUDE.md` | modified | セッション開始前から存在する変更（本セッションでは未変更） |
| `HANDOVER.md` | modified | 本 Pause Handover 追記 |
| `docs/WORKFLOW.md` | modified | セッション開始前から存在する変更（本セッションでは未変更） |
| `HANDOVER.md.bak` | untracked | 前セッションのバックアップ |

### 5. 010 計画の Round 9 変更点（Round 8 B 指摘への対応）

- `.xcodegen-version` + `XCODEGEN_SHA256` env → `.xcodegen.lock` ファイルに version + sha256 を一元管理
- `set -euo pipefail` を複数行 run ステップに追加
- `curl --retry 3` を xcodegen ダウンロードに追加
- ローカル検証コマンドを CI と同じ `arch=arm64` に統一
- hook-tests に `bash --version` / `uuidgen` の prerequisite 検証を追加
- hook-tests に失敗時 artifact upload を追加
- timeout-minutes の根拠をリスクテーブルに明記
- deploymentTarget の CI 保証範囲を「macOS 15 arm64 のみ。13/14/Intel は未検証・未保証」に明確化
- 設計判断 17〜20 を追加

### 6. 最新 reviewer / judge 結果
Codex 計画レビューのみ（review-loop は使用していない）。Round 8 は B 評価。Round 9 結果は未評価。

### 7. 未解決課題
- Codex 計画レビューで A 評価を取得できていない（8 ラウンド連続 B）
- 計画レビューの B 評価が収束しない可能性がある。B で実装に進む判断も選択肢

### 8. 再開時の最初の 1-3 ステップ

1. Round 9 の Codex レビュー結果を確認する（バックグラウンドタスク ID: `bfc7a8jm2`、出力: `/private/tmp/claude-501/-Users-nakata-Claude-clabotch/tasks/bfc7a8jm2.output`）。tmp ファイルが消えている場合は `codex exec` を再実行
2. A なら実装へ。B なら指摘を確認し、修正して round 10 に進むか、B で実装に進むか判断
3. 実装: `.xcodegen.lock` と `.github/workflows/ci.yml` を作成 → ローカル検証 → コミット → push

### 9. 再開コマンド
```bash
# Round 9 結果確認（tmp ファイルが残っている場合）
cat /private/tmp/claude-501/-Users-nakata-Claude-clabotch/tasks/bfc7a8jm2.output | tail -100

# tmp が消えている場合は Codex レビューを再実行
codex exec --full-auto "..."  # 計画内容を docs/exec-plans/active/010-ci-setup.md から読み込み
```

### 10. 人間判断が必要な点
- Codex 計画レビューで 8 ラウンド連続 B。A を目指して改善を続けるか、B で実装に進むかはユーザー判断

### 11. 触ってはいけないもの
- review-loop の state.json（全 job done、変更不要）
- `CLAUDE.md` / `docs/WORKFLOW.md`（セッション開始前からの変更、本セッションでは未変更）

---

## ユーザーフィードバック（次セッション必読）

- **次フェーズ自動選択**: 候補をユーザーに列挙せず、優先度ルールに従い自動で着手する。詳細は `.claude/projects/-Users-nakata-Claude-clabotch/memory/feedback_auto_select_next.md` を参照
