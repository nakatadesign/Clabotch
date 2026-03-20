# Patch 018: NSStatusItem の image ベース描画

## 概要

NSStatusItem の描画方式を custom subview (addSubview) から button.image ベースに変更する。
macOS が非アクティブモニターのメニューバーで button.image を自動的に dim（半透明化）するため、
この方式に寄せることで 3 モニター環境での減光問題を解消する。

## v11 からの逸脱

| # | 内容 | v11 正典 | 本パッチ | 理由 |
|---|------|---------|----------|------|
| 1 | NSStatusItem の描画方式 | custom subview (button.addSubview) | button.image に NSImage を設定 | macOS のメニューバー dim が custom subview に適用されない |
| 2 | DONE ジャンプ | NSStatusItem の Y オフセットでメニューバーから飛び出す | image 内の Y オフセットで近似（button bounds 内で表現） | button.image の位置は macOS が管理するため直接制御不可 |

## 設計判断

### A案を採用した理由（dim 一貫性優先）
- ジャンプは image 内の ctx.translateBy で Y オフセットを適用する
- button bounds の上端を超える部分は軽微にクリップされるが、「ぴょん」感は維持される
- inactive menu bar での dim は常時有効（ジャンプ中も途切れない）

### B案を不採用とした理由（ジャンプ中 subview 復帰）
- ジャンプ中（1-2秒）だけ subview を可視化する hybrid 方式
- ジャンプ中に dim が途切れるため、dim 対応の一貫性が損なわれる

### C案を不採用とした理由（ジャンプ高さ半減）
- ジャンプ高さを半分にしてクリップを軽減する案
- 視覚的なインパクトが薄れるため不採用

## 実装詳細

### ClabotchEyeView
- `renderContent(ctx:bounds:)`: draw() の描画ロジックを private メソッドに分離
- `updateStatusImage()`: NSBitmapImageRep に描画し、NSImage として button.image に設定
- `scheduleUpdate()`: needsDisplay + updateStatusImage を統合する単一更新メソッド
- `viewDidMoveToWindow()`: window 接続時に初回 image を生成（空白表示防止）
- ジャンプ/シェイク: ctx.translateBy で Y オフセット適用

### AppDelegate
- subview として追加するが `isHidden = true` に設定（テスト互換性維持）
- `statusBarButton` プロパティで image 更新先を設定
