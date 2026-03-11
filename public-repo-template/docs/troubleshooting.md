# トラブルシューティング

## jq が見つからない

**症状**: Hook が動作せず、Claude Code のログに `[clabotch] ERROR: jq is required` と表示される。

**解決策**:

```bash
brew install jq
```

`jq` は Hook スクリプトが JSON を処理するために必須です。

## アクセシビリティ権限

**症状**: マスコットの視線が動かず、常に固定位置を向いている。

**解決策**:

1. システム設定 → プライバシーとセキュリティ → アクセシビリティ
2. Clabotch にチェックを入れる
3. アプリを再起動

権限を許可しなくても、視線追跡以外の機能はすべて動作します。

## ソケット接続エラー

**症状**: Claude Code で作業しても、マスコットの状態が変わらない。

**確認手順**:

1. Clabotch が起動しているか確認（メニューバーにアイコンがあるか）
2. ソケットファイルの存在を確認:
   ```bash
   ls $TMPDIR/clabotch.sock
   ```
3. ソケットが存在しない場合、Clabotch を再起動してください

## Hook が発火しない

**症状**: Claude Code で作業しても、Hook スクリプトが実行されない。

**確認手順**:

1. Hook スクリプトが正しい場所にあるか確認:
   ```bash
   ls ~/.claude/hooks/clabotch_*.sh
   ```

2. 実行権限があるか確認:
   ```bash
   chmod +x ~/.claude/hooks/clabotch_*.sh
   ```

3. `~/.claude/settings.json` に hooks 設定が含まれているか確認（[使い方](usage.md) 参照）

## マスコットが表示されない

**確認手順**:

1. macOS のメニューバーが混雑していないか確認（メニューバーの幅が足りないとアイコンが隠れることがあります）
2. アプリを終了して再起動
3. それでも表示されない場合は [Issue](https://github.com/nakatadesign/clabotch/issues) で報告してください
