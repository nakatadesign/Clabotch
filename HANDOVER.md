# Handover: Clabotch セッション状況

**ステータス**: v1.0 公開準備中

---

## 完了済み

- [x] patch_015〜017 + attention gaze 整合: responding フェーズ明文化、idle/done softFixed 化
- [x] image ベース status item 移行 (patch_018): macOS メニューバー dim に自動追従
- [x] thinking 視認性改善 → patch_019 → patch_020 で responding に移管
- [x] phase 表情再調整 (patch_020): thinking 静止表情化、working ツール別吹き出し
- [x] アプリアイコン 80% 縮小
- [x] 吹き出し文言最終調整: thinking=なし、responding=「作業中...」、working=ツール別
- [x] 仕様ドリフト解消: テスト文言整合、GazeController nil fallback、ドキュメント整合

### フェーズ表情マトリクス（patch_020 適用後）

| Phase | 顔色 | 瞳色 | アニメーション | 吹き出し |
|-------|------|------|----------------|---------|
| idle | faceNormal | 黒 | なし | — |
| thinking | faceNormal | 黒 | なし（頷きのみ） | — |
| responding | faceNormal | 黒 | 右上⇔左上 + 上下揺れ(0.8秒) | 作業中... |
| working | faceNormal | 黒 | なし | ツール別（Bash→実行します... 等） |
| done | faceDone→rainbow | 黒 | スピン + ジャンプ + グラデーション | 完了！(time) |
| error | faceError | 黒 | シェイク | エラーが出ました… |
| sleeping | faceSleep | 黒 | なし | — |

---

## 未完了

- [ ] **表情の実機目視確認**: `scripts/visual_test.sh` で各フェーズの表情切り替わりを確認
- [ ] **LaunchAgent**: ログイン時自動起動
- [ ] **Notarization**: Developer ID 署名・公証（配布用）
- [ ] **BlinkController flaky テスト修正**: `testDeterministicRandomSource` が稀に失敗（既知）

---

## 失敗したアプローチ（繰り返さないこと）

- `window.isMainWindow` で非アクティブモニターを per-display 判定 → `isMainWindow` は OS レベル状態であり per-display 判定には使えない。button.image + macOS 自動 dim 方式を採用
- ジャンプ中だけ custom subview に戻す hybrid 方式 → dim が途切れ不自然。image 内 `ctx.translateBy` で Y オフセット表現に統一
- patch_019 で thinking に青瞳 + 上下揺れ → 表示時間が短く過剰。patch_020 で responding に移管
- `replace_all` で `needsDisplay = true` を一括置換 → メソッド本体内も変換され無限再帰。手動修正に切替
- `NSImage(size:flipped:drawingHandler:)` の遅延描画 → 状態変化後の値を参照。`NSBitmapImageRep` で即時描画に統一
- `addSubview()` → `statusBarButton` の順で初期化 → `viewDidMoveToWindow()` 時に nil。順序を逆にして `setupEyeView(on:)` に切り出し

---

## 重要なファイル

- `src/Clabotch/ClabotchEyeView.swift` — 顔描画のコア
- `src/Clabotch/AppDelegate.swift` — アプリ起動・初期化
- `src/Clabotch/GazeController.swift` — 視線追跡
- `src/Clabotch/CoordinatorBinder.swift` — StateMachine → 下流の結線、ツール別吹き出し分岐
- `src/ClabotchTests/AppDelegateCoordinatorTests.swift` — 吹き出し文言の期待値テスト
- `src/ClabotchTests/CoordinatorIntegrationTests.swift` — responding 統合テスト
- `scripts/visual_test.sh` — フェーズ別目視確認スクリプト
- `docs/design/patches/` — patch_015〜020 を含む設計パッチ群
- `docs/design/current/clabotch_design_doc_v11.md` — 最新設計書（変更禁止）

---

## セッション開始手順

1. `git log --oneline -10` で最新コミットを確認
2. `cd src && pkill -9 -f Clabotch; sleep 2` でプロセスをクリア
3. `xcodebuild test -project Clabotch.xcodeproj -scheme Clabotch -destination 'platform=macOS' 2>&1 | tail -30` でテスト結果確認（361件、360 passed / 1 skipped が期待値）
4. 実機確認する場合は `scripts/visual_test.sh` を実行

---

## 注意事項

- **テスト前に必ず `pkill -9 -f Clabotch`**: HookServer が競合するとテストが失敗する
- **設計書 v11 は変更禁止**: 設計逸脱は `docs/design/patches/` に patch 文書として追記
- **jumpYOffset の単位**: ポイント値であり `dot` を再乗算しないこと（二重スケールになる）
- **hooks 設定**: `~/.claude/settings.json` に PreToolUse / PostToolUse / PostToolUseFailure / Stop の 4 hooks 登録が必要。未登録だと StateMachine が idle 固定になる
