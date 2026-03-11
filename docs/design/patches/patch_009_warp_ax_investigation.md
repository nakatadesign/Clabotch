# Patch 009: Warp AX 属性調査結果

## 設計書 v11 からの逸脱

| # | 内容 | v11 正典 | 本パッチ | 理由 |
|---|------|---------|----------|------|
| 1 | Warp を supportedBundles に昇格 | §13.4: MVP に Warp を含めない | supportedBundles に追加 | §14 順序 1 の AX 属性ダンプで COMPATIBLE 判定 |
| 2 | BundleIdentifier が異なる | §11.5: `dev.warp.desktop` | `dev.warp.Warp-Stable` | 実機調査で判明。Warp Stable チャンネルの正式 ID |

## 調査環境

- **Warp バージョン**: 0.2026.03.04.08.20.02
- **BundleIdentifier**: `dev.warp.Warp-Stable`
- **macOS**: Darwin 24.6.0
- **AXIsProcessTrusted**: true

## AX 属性ダンプ結果

### Application レベル

取得成功（result: 0）。以下の属性が利用可能:

```
AXChildren, AXChildrenInNavigationOrder, AXEnhancedUserInterface,
AXExtrasMenuBar, AXFocusedUIElement, AXFocusedWindow, AXFrame,
AXFrontmost, AXFunctionRowTopLevelElements, AXHidden, AXMainWindow,
AXMenuBar, AXPosition, AXPreferredLanguage, AXRole, AXRoleDescription,
AXSize, AXTitle, AXWindows
```

### Window レベル（Window[0]）

| 属性 | 結果 | 値 |
|------|------|-----|
| kAXRole | 成功 | AXWindow |
| kAXSubrole | 成功 | AXStandardWindow |
| kAXPosition | 成功 | (1408.0, 367.0) |
| kAXSize | 成功 | 1024.0 x 768.0 |
| kAXTitle | 成功 | （空文字列） |
| kAXFocused | 成功 | true |
| kAXMinimized | 成功 | false |

全属性リスト:

```
AXActivationPoint, AXCancelButton, AXChildren, AXChildrenInNavigationOrder,
AXCloseButton, AXDefaultButton, AXDescription, AXDocument, AXFocused,
AXFrame, AXFullScreen, AXFullScreenButton, AXGrowArea, AXMain,
AXMinimizeButton, AXMinimized, AXModal, AXParent, AXPosition, AXProxy,
AXRole, AXRoleDescription, AXSections, AXSize, AXSubrole, AXTitle,
AXTitleUIElement, AXToolbarButton, AXValue, AXValueDescription, AXZoomButton
```

## 判定

**COMPATIBLE** — `findTerminalCenter` が必要とする `kAXWindows`、`kAXPosition`、`kAXSize` がすべて正常に取得可能。

## 実施した変更

- `GazeController.swift`: `tentativeBundles` を空にし、`supportedBundles` に `dev.warp.Warp-Stable` を追加
- `GazeControllerTests.swift`: Warp テストを `.unsupportedTerminal` → `.tracking` に変更

## 備考

- `dev.warp.desktop` は Warp の旧バージョンまたは別リリースチャンネルの BundleIdentifier の可能性がある。現時点では Homebrew Cask でインストールされる Stable チャンネルの `dev.warp.Warp-Stable` のみ対応
- 将来 Warp が BundleIdentifier を変更した場合、`supportedBundles` の更新が必要
