# HANDOVER.md — Clabotch セッション引き継ぎ

## 1. プロジェクト状態

- **MVP**: **完了**（v0.1 相当、設計書 §9 PoC + v0.1 + v0.2 スコープ全達成）
- **全計画 002〜013**: 完了
- **active な計画**: なし
- **CI**: 最後に green 確認: CI #6 `757c55a`。以降のコミットは未 push / 未 CI 検証
- **branch protection**: N/A（private repo + GitHub Free では設定不可）
- **総テスト**: 232 件（231 passed, 1 skipped）+ hook E2E 43 件
- **totonoe upstream**: 全修正反映済み（`284af6b` + `da95d78`）
- **最新コミット**: `1824104`

---

## 2. MVP 完了サマリー

全 12 計画（002〜013）で以下のコア機能を実装済み:

| カテゴリ | 実装内容 | 計画 |
|----------|----------|------|
| 通信基盤 | HookServer + Unix domain socket + NDJSON | 002 |
| イベント処理 | EventParser + EventDeduplicator | 003 |
| 状態管理 | StateMachine（6 フェーズ、所有権ガード、レース対策） | 004 |
| 視線追跡 | GazeController（AX API + 権限 3 値管理 + フォールバック） | 005 |
| まばたき | BlinkController + 7 段階シーケンス（330ms） | 005, 012 |
| 描画 | ClabotchEyeView 14 フレーム（全 Core Graphics） | 006, 011 |
| アニメーション | DONE スピン + ERROR シェイク + ジャンプ | 011 |
| 吹き出し | BubbleWindow（ツール名 + 作業時間表示） | 006 |
| 結線 | CoordinatorBinder（StateMachine ↔ 各コンポーネント） | 007 |
| 堅牢性 | HookServer 起動失敗時の半初期化修正 | 008 |
| 調査 | Warp AX 属性ダンプ（unsupportedTerminal で固定視線） | 009 |
| CI | GitHub Actions（build + hook E2E テスト） | 010 |
| UX | オンボーディング UI（AX 権限ダイアログ §11.7） | 013 |

---

## 3. 次の優先タスク

MVP コア機能は全て実装済み。以下は WORKFLOW.md の優先度ルール（§ Auto Continue）に準拠した順序。

| 優先度 | タスク | 種別 | 備考 |
|--------|--------|------|------|
| 1 | Stop hook error 調査 | バグ修正 | 再現したら着手 |
| 2 | hook E2E テスト [10] flaky 対策 | 回帰防止テスト | CI で再現した場合 |
| 3 | BubbleWindow 実環境テスト | テスト容易化 | GUI 環境で手動確認 |
| 4 | CI push + green 確認 | 小規模ポリッシュ | 計画 011〜013 のコミットを push して CI 通過確認 |
| 5 | apply_manager_decision.sh done バグ修正 | バグ修正 | totonoe upstream で対応 |
| 6 | PAT 権限追加 | 外部依存 | 人間の作業。任意 |

### post-MVP ロードマップ（参考: 設計書 §9）

上記の条件付き / 衛生タスク完了後に着手。

**v0.3 スコープ（複数セッション対応）**
- MultiSessionStateMachine 実装（displayPriority に基づくフェーズ統合表示）
- foreign session の本格的な状態可視化（現在は onEphemeralDone 通知のみ）
- 作業時間表示の改善（ツール未使用セッションの経過時間精度）

**v1.0 スコープ（配布・設定画面）**
- 設定画面（UI パネル）
- LaunchAgent 登録（自動起動）
- Apple Notarization + DMG パッケージング（Developer 証明書が必要）
- Warp 完全対応（AX 属性確認後に supportedBundles へ昇格）

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
