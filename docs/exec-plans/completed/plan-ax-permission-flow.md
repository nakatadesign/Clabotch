# 計画: AX権限フローの改善

## 概要

Clabotch（macOS メニューバー常駐型 Claude Code マスコット）の視線追跡機能は、macOS のアクセシビリティ（AX）権限に依存している。現在の実装では、ユーザーがAX権限を正しく設定できないケースが複数あり、配布時にトラブルになるリスクが高い。

## 現状のアーキテクチャ

### 関連コンポーネント

- **AppDelegate** — 起動時のAX権限チェックとアラート表示
- **OnboardingWindowController** — 初回起動時のウェルカムダイアログ
- **GazeController** — 0.5秒ポーリングで `AXIsProcessTrusted()` を確認し、視線追跡を制御
- **AXProvider** — `AXIsProcessTrusted()` / `AXIsProcessTrustedWithOptions()` の抽象化

### 状態管理に使用している UserDefaults キー

| キー | 型 | 用途 |
|------|------|------|
| `didShowOnboarding` | Bool | オンボーディングダイアログを表示済みか |
| `didRequestAccessibility` | Bool | AX権限を一度でもリクエストしたか |

### GazeController の permissionStatus 判定ロジック（現状）

```swift
private func checkPermission() {
    let trusted = axProvider.isProcessTrusted()  // AXIsProcessTrusted()
    let didRequest = UserDefaults.standard.bool(forKey: "didRequestAccessibility")

    if trusted { permissionStatus = .granted }
    else if didRequest { permissionStatus = .denied }
    else { permissionStatus = .notDetermined }
}
```

### 起動フロー（現状）

```
applicationDidFinishLaunching
├── UI 初期化（メニューバー、HookServer 等）
├── gazeController.startPolling()  ← 0.5秒ごとに checkPermission() + update()
└── AX 権限分岐:
    ├── didShowOnboarding=false（初回）
    │   → OnboardingWindowController.show()
    │   ├── 「許可する」→ requestPermissionIfNeeded()
    │   │   → didRequestAccessibility=true
    │   │   → AXIsProcessTrustedWithOptions(prompt:true) ← macOSダイアログ
    │   └── 「後で」→ 何もしない
    └── didShowOnboarding=true && !AXIsProcessTrusted()
        → showAccessibilityAlert()
        ├── 「システム設定を開く」→ アクセシビリティ設定画面を開く
        └── 「後で」→ 何もしない
```

## 問題点

### 問題1: 🔴 macOS ダイアログで「拒否」→ 永久 denied

**フロー:**
1. 初回起動 → 「許可する」
2. `requestPermissionIfNeeded()` → `didRequestAccessibility=true` に設定
3. macOS ダイアログで「拒否」を押す
4. `AXIsProcessTrusted()=false`, `didRequestAccessibility=true`
5. `checkPermission()` → `denied`
6. 次回起動: `didShowOnboarding=true`, `AXIsProcessTrusted()=false`
7. `showAccessibilityAlert()` が表示されるが、ユーザーがシステム設定で許可しても...
8. **一度 `requestTrust(prompt:true)` を呼んだ後は macOS が再度ダイアログを出さない**

**根本原因:** `didRequestAccessibility` が true のまま残り、`checkPermission()` が `denied` と判定し続ける。実際には macOS 側で許可状態が変わる可能性があるのに、アプリ側のフラグが邪魔をしている。

### 問題2: 🔴 署名変更後にチェックが効かない

**フロー:**
1. ユーザーが Clabotch v1.0 を使用中（AX許可済み）
2. v1.1 にアップデート（署名が変わる）
3. macOS TCC が新しい署名を別アプリとして扱い、AX権限をリセット
4. `showAccessibilityAlert()` → 「システム設定を開く」
5. システム設定にはv1.0のClabotchエントリが残っている
6. ユーザーはチェックが入っているのを見て「あれ？」となる
7. または新しいエントリにチェックを入れるが、**古いエントリのチェックを外す必要がある場合もある**

**根本原因:** macOS の TCC は署名単位で管理。開発中の ad-hoc 署名では毎回変わるため頻発する。配布ビルド（Developer ID）ではアップデート時のみ発生。

### 問題3: 🟡 状態管理の複雑さ

2つの UserDefaults キー（`didShowOnboarding`, `didRequestAccessibility`）と `AXIsProcessTrusted()` の3要素の組み合わせで8パターンが存在するが、テストされているのは一部のみ。

### 問題4: 🟡 権限回復時のフィードバック不足

ユーザーがシステム設定でチェックを入れた後、Clabotch 側で何が起きたか分からない。ポーリングで自動的に `granted` になるが、視覚的なフィードバックがない。

## 改善方針

### 方針1: `didRequestAccessibility` フラグの廃止

**Before:**
```swift
if trusted { .granted }
else if didRequest { .denied }
else { .notDetermined }
```

**After:**
```swift
if trusted { .granted }
else { .notGranted }  // denied/notDetermined の区別を廃止
```

- `notDetermined` と `denied` を区別する必要がない
- `AXIsProcessTrusted()` が唯一の真実の源泉
- GazePermissionStatus を `.granted` / `.notGranted` の2値に簡素化

### 方針2: 起動フローの簡素化

```
applicationDidFinishLaunching
├── UI 初期化
├── gazeController.startPolling()
└── AX 権限分岐:
    ├── AXIsProcessTrusted()=true → 何もしない ✅
    └── AXIsProcessTrusted()=false
        ├── didShowOnboarding=false（初回）
        │   → OnboardingWindowController.show()
        │   ├── 「許可する」→ requestTrust(prompt:true)
        │   └── 「後で」→ 何もしない
        └── didShowOnboarding=true（2回目以降）
            → showAccessibilityAlert()
```

変更点:
- `didRequestAccessibility` を使わない
- `requestPermissionIfNeeded()` の 1秒待ちを廃止（ポーリングに任せる）

### 方針3: 権限変化時のフィードバック

GazeController のポーリングで `permissionStatus` が変化したとき、callback で通知する。

```swift
// GazeController に追加
var onPermissionChanged: ((GazePermissionStatus) -> Void)?

private func checkPermission() {
    let oldStatus = permissionStatus
    permissionStatus = axProvider.isProcessTrusted() ? .granted : .notGranted
    if permissionStatus != oldStatus {
        onPermissionChanged?(permissionStatus)
    }
}
```

AppDelegate/CoordinatorBinder で購読し、`granted` に変化したら吹き出しで「視線追跡が有効になりました」等を一時表示。

### 方針4: アラート文言の改善

現在の文言:
> 「Clabotch のチェックを一度外してから再度チェックを入れてください」

改善案:
> 「システム設定のアクセシビリティ一覧に Clabotch を追加してチェックを入れてください。
> 既にチェックが入っている場合は、一度外してから再度入れ直してください。」

## 影響範囲

| ファイル | 変更内容 |
|----------|----------|
| `GazeController.swift` | permissionStatus を2値化、onPermissionChanged 追加、requestPermissionIfNeeded 簡素化 |
| `GazeTypes.swift` | GazePermissionStatus の case 変更 |
| `AppDelegate.swift` | 起動フロー簡素化、権限変化時フィードバック |
| `OnboardingWindowController.swift` | 変更なし or 文言微調整 |
| `CoordinatorBinder.swift` | 権限変化通知の結線（オプション） |
| `AXProvider.swift` | 変更なし |
| `ClabotchTests/GazeControllerTests.swift` | permissionStatus テスト更新 |
| `ClabotchTests/OnboardingWindowControllerTests.swift` | 変更なし or 微調整 |

## テスト方針

1. `GazePermissionStatus` が `.granted` / `.notGranted` の2値で正しく判定されること
2. `onPermissionChanged` が状態変化時のみ呼ばれること
3. 起動フローの各分岐が正しく動作すること
4. `didRequestAccessibility` への依存が完全に排除されていること

## リスク

- `GazePermissionStatus` の case 変更は breaking change → テスト全修正が必要
- `notDetermined` を使っていた箇所（fixed gaze の reason 等）の修正漏れに注意
- 配布ビルド（Developer ID 署名）では署名変更問題は軽減されるが、完全には解消しない

## 質問事項（レビュー時に議論したい）

1. `GazePermissionStatus` を2値化するか、3値のまま `didRequestAccessibility` だけ廃止するか
2. 権限回復フィードバックの表現方法（吹き出し？ジャンプ？音？）
3. オンボーディングの「後で」を選んだユーザーへの再案内タイミング
