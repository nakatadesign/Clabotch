# ARCHITECTURE.md — Clabotch アーキテクチャルール

## 設計の正典

全ての実装判断は `docs/design/current/clabotch_design_doc_v11.md` に従う。
本ファイルはその要約・チェックリストとして機能する。

**承認済み例外:** `docs/design/patches/` に patch 文書として記録。
正典の特定項目に対する例外であり、正典の優先順位は変えない。

---

## ディレクトリ構成

```
clabotch/
├── CLAUDE.md                    # Claude Code エントリポイント
├── AGENTS.md                    # Codex エントリポイント
├── HANDOVER.md                  # セッション引き継ぎ
├── docs/
│   ├── WORKFLOW.md              # 作業フロー・Codex連携ループ
│   ├── ARCHITECTURE.md          # 本ファイル
│   ├── REVIEW_RULES.md          # Codexレビュールール
│   ├── design/
│   │   ├── current/
│   │   │   └── clabotch_design_doc_v11.md  # v11最終設計書（変更禁止）
│   │   ├── archive/             # 過去バージョンの設計書
│   │   └── patches/             # 設計追補・差分パッチ
│   └── exec-plans/
│       ├── active/              # 進行中の実装計画
│       └── completed/           # 完了した実装計画
├── src/                         # Xcodeプロジェクト（実装フェーズで作成）
├── hooks/                       # ~/.claude/hooks/ の作業コピー
├── tests/                       # テスト・疎通確認スクリプト
└── artifacts/                   # ビルド成果物・スクリーンショット
```

---

## アーキテクチャの核心（v11確定版）

```
Claude Code hooks（stdin JSON）
  └─ Unix domain socket ($TMPDIR/clabotch.sock)
       └─ HookServer.accept() ループ
            └─ [接続ごと] connectionQueue (serial)
                 ├─ LineBufferedEventDecoder（接続ごとに生成）
                 └─ EventParser（pure function）
                      └─ DispatchQueue.main
                           ├─ EventDeduplicator（main only、グローバル1個）
                           └─ StateMachine（main only、グローバル1個）
                                ├─ ClabotchEyeView
                                ├─ BlinkController
                                ├─ GazeController
                                └─ BubbleWindow
```

---

## スレッド境界ルール（厳守）

| コンポーネント | スレッド | 共有 |
|---|---|---|
| LineBufferedEventDecoder | 接続ごとのserial queue専用 | ❌ |
| EventParser | pure function（任意スレッド） | ✅ |
| EventDeduplicator | メインスレッド専用 | ✅ グローバル1個 |
| StateMachine | メインスレッド専用 | ✅ グローバル1個 |

**DispatchQueue.main を経由しない UI 操作は禁止。**

---

## コーディング規約

- キャンバスサイズ: 22×14px 固定
- Retina対応: `let dot = min(bounds.width / 22.0, bounds.height / 14.0)`
- 瞳移動: 座標計算禁止 → フレーム丸ごと切り替え
- PNG素材禁止: 全フレーム Swift コードで描画
- `DispatchQueue.main.async` でUI更新を囲む
- `[weak self]` でメモリリークを防ぐ

---

## 実装優先順位（v11確定）

| 順序 | 作業 | 参照 |
|------|------|------|
| 1 | Hook スクリプト疎通テスト | §10.4 |
| 2 | HookServer NDJSON line buffer | §14.1 |
| 3 | EventParser / EventDeduplicator | §14.2 |
| 4 | StateMachine + GazeController | §11.5, §12.2 |
| 5 | Warp AX 属性ダンプ | §Residual Risk |
