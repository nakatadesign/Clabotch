# 実装計画 009: Warp AX 属性ダンプ + tentativeBundles 昇格判断

## 概要

GazeController の `tentativeBundles` に分類されている Warp（`dev.warp.desktop`）について、AX API で必要な属性（`kAXWindows`, `kAXPosition`, `kAXSize`）が取得可能かを実機調査し、`supportedBundles` への昇格可否を判断する。

## 正典参照

- 設計書: `docs/design/current/clabotch_design_doc_v11.md`
- §11.5 L761-764: `tentativeBundles` — AX 属性ダンプ確認後に `supportedBundles` へ昇格させる候補
- §13.4: Warp の `tentativeBundles` 分離 — MVP の `supportedBundles` に Warp を含めない
- §13.6: MVP の既知制約 — Warp は `.unsupportedTerminal` で固定視線に落とす
- §14 実装ロードマップ順序 1: **Warp AX 属性ダンプ** — 昇格判断が最優先タスク

## 正典からの逸脱

本計画は調査フェーズのため、実装変更は調査結果に依存する。

### 昇格する場合の逸脱

| # | 内容 | v11 正典 | 本計画 | 理由 |
|---|------|---------|--------|------|
| 1 | Warp を supportedBundles に移動 | §13.4: MVP に Warp を含めない | AX 属性が正常取得可能であれば昇格 | §14 順序 1 で AX 属性ダンプ後の昇格判断を明示的に要求している |

### 昇格しない場合

逸脱なし。現状維持（`tentativeBundles` のまま）。fallback 理由を文書化して完了。

## 前提条件

- [x] 計画 002〜008 完了
- [x] GazeController に `tentativeBundles` / `supportedBundles` 実装済み
- [x] `AXProvider` / `RealAXProvider` 実装済み（`findTerminalCenter` で kAXWindows/kAXPosition/kAXSize を取得）
- [ ] Warp がマシンにインストールされていること
- [ ] AX 権限が Clabotch（またはターミナル）に付与されていること

## スコープ

**含む:**
- AX 属性ダンプ用 Swift スクリプト（`tests/ax_dump.swift`）の作成
- Warp の AX 属性実機調査（手動実行）
- 調査結果の文書化（`docs/design/patches/warp_ax_investigation.md`）
- 昇格可能な場合: `GazeController.swift` の `tentativeBundles` → `supportedBundles` 移動
- 昇格可能な場合: `GazeControllerTests.swift` の Warp 関連テスト更新

**含まない:**
- GazeController の広範な改修（量子化ロジック等）
- Warp 固有の AX 属性対応（標準属性のみで判断）
- Warp 以外のターミナルの調査

## 詳細設計

### Step 1: AX ダンプスクリプト作成

`tests/ax_dump.swift` — Warp の PID を引数に取り、以下を出力する Swift スクリプト:

```swift
#!/usr/bin/env swift
// 使い方: swift tests/ax_dump.swift <PID>
// Warp を起動した状態で: swift tests/ax_dump.swift $(pgrep -x Warp)

import AppKit

guard CommandLine.arguments.count > 1,
      let pid = pid_t(CommandLine.arguments[1]) else {
    print("Usage: swift ax_dump.swift <PID>")
    exit(1)
}

// AX 権限チェック
print("AXIsProcessTrusted: \(AXIsProcessTrusted())")

let app = AXUIElementCreateApplication(pid)

// 属性一覧
var attrNames: CFArray?
let attrResult = AXUIElementCopyAttributeNames(app, &attrNames)
print("\n=== Application attributes (result: \(attrResult.rawValue)) ===")
if let names = attrNames as? [String] {
    for name in names.sorted() {
        print("  \(name)")
    }
}

// kAXWindows
var windowsRef: CFTypeRef?
let windowsResult = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
print("\n=== kAXWindows (result: \(windowsResult.rawValue)) ===")

guard windowsResult == .success,
      let windows = windowsRef as? [AXUIElement] else {
    print("ERROR: kAXWindows 取得失敗")
    exit(1)
}
print("Window count: \(windows.count)")

for (i, window) in windows.prefix(3).enumerated() {
    print("\n--- Window[\(i)] ---")

    // Window 属性一覧
    var winAttrNames: CFArray?
    AXUIElementCopyAttributeNames(window, &winAttrNames)
    if let names = winAttrNames as? [String] {
        print("  Attributes: \(names.sorted().joined(separator: ", "))")
    }

    // kAXPosition
    var posRef: CFTypeRef?
    let posResult = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
    if posResult == .success, let val = posRef {
        var pos = CGPoint.zero
        AXValueGetValue(val as! AXValue, .cgPoint, &pos)
        print("  Position: (\(pos.x), \(pos.y))")
    } else {
        print("  Position: FAILED (result: \(posResult.rawValue))")
    }

    // kAXSize
    var sizeRef: CFTypeRef?
    let sizeResult = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
    if sizeResult == .success, let val = sizeRef {
        var size = CGSize.zero
        AXValueGetValue(val as! AXValue, .cgSize, &size)
        print("  Size: \(size.width) x \(size.height)")
    } else {
        print("  Size: FAILED (result: \(sizeResult.rawValue))")
    }

    // kAXTitle
    var titleRef: CFTypeRef?
    let titleResult = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
    if titleResult == .success, let title = titleRef as? String {
        print("  Title: \(title)")
    } else {
        print("  Title: FAILED (result: \(titleResult.rawValue))")
    }

    // kAXFocused
    var focusedRef: CFTypeRef?
    let focusedResult = AXUIElementCopyAttributeValue(window, kAXFocusedAttribute as CFString, &focusedRef)
    if focusedResult == .success, let focused = focusedRef as? Bool {
        print("  Focused: \(focused)")
    } else {
        print("  Focused: N/A (result: \(focusedResult.rawValue))")
    }

    // kAXMinimized
    var minRef: CFTypeRef?
    let minResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef)
    if minResult == .success, let minimized = minRef as? Bool {
        print("  Minimized: \(minimized)")
    } else {
        print("  Minimized: N/A (result: \(minResult.rawValue))")
    }
}

print("\n=== Summary ===")
print("findTerminalCenter compatibility: ", terminator: "")
// Clabotch が必要とする属性: kAXWindows, kAXPosition, kAXSize
var posCheck: CFTypeRef?
var sizeCheck: CFTypeRef?
let posOk = AXUIElementCopyAttributeValue(windows[0], kAXPositionAttribute as CFString, &posCheck) == .success
let sizeOk = AXUIElementCopyAttributeValue(windows[0], kAXSizeAttribute as CFString, &sizeCheck) == .success
if posOk && sizeOk {
    print("COMPATIBLE — supportedBundles 昇格可能")
} else {
    print("INCOMPATIBLE — tentativeBundles 維持")
    if !posOk { print("  - kAXPosition 取得不可") }
    if !sizeOk { print("  - kAXSize 取得不可") }
}
```

### Step 2: 実機調査（手動実行）

```bash
# 1. Warp をインストール・起動する
# 2. AX 権限を付与する（システム設定 → プライバシーとセキュリティ → アクセシビリティ）
# 3. Warp のウィンドウを開いた状態で:
swift tests/ax_dump.swift $(pgrep -x Warp)
```

### Step 3: 結果に基づく判断

#### Case A: COMPATIBLE（昇格可能）

1. `src/Clabotch/GazeController.swift` の `tentativeBundles` から `"dev.warp.desktop"` を削除し `supportedBundles` に追加
2. `tentativeBundles` は空 Set として残す（§11.5 の汎用的な仕組みを維持。将来のターミナル候補追加に備える）
3. `src/ClabotchTests/GazeControllerTests.swift` の Warp 関連テスト（`testUnsupportedTerminalWarp` 等）を更新
4. 調査結果を `docs/design/patches/warp_ax_investigation.md` に記録

#### Case B: INCOMPATIBLE（昇格不可）

1. コード変更なし（`tentativeBundles` 維持）
2. 取得失敗した属性と理由を `docs/design/patches/warp_ax_investigation.md` に記録
3. 将来の Warp 対応方針（AX API の代替手段等）を検討課題として記載

### Step 4: テスト

昇格する場合のテスト変更:

| ファイル | 変更内容 |
|----------|---------|
| `src/ClabotchTests/GazeControllerTests.swift` | Warp の bundleID を `.unsupportedTerminal` → 正常追跡のテストに変更 |

テスト数の変化:
- 昇格する場合: テスト数変更なし（既存テストの期待値変更のみ）
- 昇格しない場合: テスト数変更なし（コード変更なし）

## ファイル構成

### 新規ファイル

| ファイル | 役割 |
|----------|------|
| `tests/ax_dump.swift` | AX 属性ダンプ用スクリプト（調査ツール） |
| `docs/design/patches/warp_ax_investigation.md` | 調査結果の記録 |

### 変更ファイル（昇格する場合のみ）

| ファイル | 変更内容 |
|----------|---------|
| `src/Clabotch/GazeController.swift` | `tentativeBundles` → `supportedBundles` 移動 |
| `src/ClabotchTests/GazeControllerTests.swift` | Warp テストケースの期待値変更 |

## 実装手順

1. `tests/ax_dump.swift` を作成
2. ユーザーが Warp をインストール・起動して `swift tests/ax_dump.swift $(pgrep -x Warp)` を実行
3. 出力結果を確認し、昇格可否を判断
4. 判断結果を `docs/design/patches/warp_ax_investigation.md` に記録
5. 昇格する場合: GazeController + テストを修正 → xcodegen generate + xcodebuild test
6. 計画書を completed に移動

## リスク

| リスク | 対策 |
|--------|------|
| Warp が未インストール | ユーザーにインストールを依頼。Warp は無料で利用可能 |
| AX 権限が未付与 | スクリプト冒頭で `AXIsProcessTrusted()` をチェックし、未付与なら案内を出力 |
| Warp のバージョンで AX 属性が異なる | 調査時のバージョンを記録。将来のバージョンで再検証が必要になる可能性を文書化 |
| 昇格後に Warp 固有の AX 問題が発覚 | supportedBundles から tentativeBundles に戻す revert 手順を用意 |

## テスト数

| 区分 | テスト数 |
|------|---------|
| 既存テスト | 195（194 passed, 1 skipped） |
| 新規テスト | 0 |
| **合計目標** | **195**（194 passed, 1 skipped） |
