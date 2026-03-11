# コントリビューション

Clabotch への貢献に興味をお持ちいただきありがとうございます。

## Issue

バグ報告や機能提案は [Issues](https://github.com/nakatadesign/clabotch/issues) からお願いします。

- バグ報告の場合: macOS バージョン、再現手順、期待される動作を記載してください
- 機能提案の場合: ユースケースを具体的に記載してください

## Pull Request

1. このリポジトリを Fork する
2. フィーチャーブランチを作成する (`git checkout -b feature/your-feature`)
3. 変更をコミットする
4. Pull Request を作成する

### コーディング規約

- Swift コードは Swift 標準のスタイルに従う
- キャンバスサイズ 22×14px の制約を守る
- PNG 素材は使わない（全フレーム Swift コードで描画）
- UI 更新は必ずメインスレッドで行う

### ビルド・テスト

```bash
# ビルド手順は開発の進行に合わせて更新します
```

## ライセンス

貢献いただいたコードは [MIT License](../LICENSE) の下でライセンスされます。
