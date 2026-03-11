# Patch 002: socket path 変更

> 正典: `docs/design/current/clabotch_design_doc_v11.md`
> 対象箇所: §10.3, §10.4, §14.1
> 承認: 実装計画 002 Codex レビュー A 取得時

## 変更内容

| 項目 | v11 正典 | 本 patch |
|------|---------|---------|
| socket path | `$TMPDIR/clabotch.sock` | `$TMPDIR/clabotch/hook.sock` |
| socket ディレクトリ | なし（TMPDIR 直下） | `$TMPDIR/clabotch/`（0700、専用ディレクトリ） |

## 理由

- 専用ディレクトリ（0700）により socket ファイルのパーミッション管理を強化
- 将来の追加ファイル（PID ファイル等）を同一名前空間に配置可能

## 影響範囲

- `hooks/clabotch_lib.sh` の `SOCK` 変数
- `tests/test_hooks.sh` の `MOCK_SOCK`
- HookServer の `socketDir` / `socketPath`

## 追加の承認済み例外

| # | 内容 | v11 正典との差分 |
|---|------|----------------|
| 1 | `send_json` 3値戻り値（0/1/2） | 設計書には未定義 |
| 2 | session_start + tool_start 連結送信 | §10.4 は別送信 |
| 3 | lossy 順序保証（tool_end/session_done 逆転許容） | 設計書は順序前提 |
| 4 | session_id バリデーション | 設計書には未定義 |

## 実装上の差分

| # | 内容 | 計画書 | 実装 | 理由 |
|---|------|--------|------|------|
| 5 | sun_path 長検証 | `fileSystemRepresentation` | `utf8CString` | macOS では NFD/NFC 正規化差異を除き同等。`fileSystemRepresentation` は `UnsafePointer<Int8>` を返すため即 `.count` が取れず、`strlen` 経由になる。`utf8CString` の方が Swift API として自然で NUL 終端を含む `.count` を直接比較可能。実害のある差分ではないため `utf8CString` を採用。 |

## SESSION_REGISTRY について

`SESSION_REGISTRY`（`$TMPDIR/clabotch_sessions`）は本 patch の対象外。
将来 `$TMPDIR/clabotch/` 名前空間に統合する場合は別 patch で対応する。
