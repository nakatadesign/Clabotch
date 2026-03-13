# HANDOVER.md — Clabotch セッション引き継ぎ

## 1. プロジェクト状態

- **MVP**: **完了**（v0.1 相当、設計書 §9 PoC + v0.1 + v0.2 スコープ全達成）
- **v0.3**: **計画 014 実装完了**（MultiSessionStateMachine）
- **全計画 002〜014**: 完了
- **active な計画**: なし
- **CI**: green 確認済み（`8792c5b`）。PAT に actions:read 権限なし（API 確認不可、ブラウザで確認）
- **branch protection**: N/A（private repo + GitHub Free では設定不可）
- **総テスト**: 247 件（246 passed, 1 skipped）+ hook E2E 43 件
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

## 3. 次の優先タスク

| 優先度 | タスク | 種別 | 備考 |
|--------|--------|------|------|
| 1 | Stop hook error 調査 | バグ修正 | 再現したら着手 |
| 2 | hook E2E テスト [10] flaky 対策 | 回帰防止テスト | CI で再現した場合 |
| 3 | BubbleWindow 実環境テスト | テスト容易化 | GUI 環境で手動確認 |
| 4 | PAT 権限追加 | 外部依存 | 人間の作業。任意 |
| 5 | GEMINI_API_KEY 設定 | 外部依存 | totonoe Gemini フォールバック有効化 |

### v0.3 残タスク

- foreign session の本格的な状態可視化（BubbleWindow 改修）
- 作業時間表示の改善（ツール未使用セッションの経過時間精度）

### v1.0 スコープ（配布・設定画面）

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
