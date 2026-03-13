# Clabotch 配布手順

## 前提条件

### 人間が行う作業（1回のみ）

1. **Apple Developer Program に登録**（年額 $99）
   - https://developer.apple.com/programs/

2. **Developer ID Application 証明書の作成**
   - Xcode → Settings → Accounts → Manage Certificates
   - 「+」→「Developer ID Application」を選択
   - キーチェーンに自動インストールされる

3. **App-specific password の生成**（Notarization 用）
   - https://appleid.apple.com/ → Sign-In and Security → App-Specific Passwords
   - 生成したパスワードを安全に保管

4. **project.yml の DEVELOPMENT_TEAM を設定**
   - `src/project.yml` の Release 設定にある `DEVELOPMENT_TEAM: ""` に Team ID を記入
   - Team ID は Apple Developer Portal の Membership ページで確認

### ツール

- `xcodegen`（`brew install xcodegen` またはピン留めバージョン）
- Xcode（Command Line Tools 含む）
- `hdiutil`（macOS 標準）

## ビルド＆配布フロー

### 1. Release ビルド + DMG 作成（署名なし / テスト用）

```bash
./scripts/build_release.sh
```

`dist/Clabotch-1.0.0.dmg` が生成される。
Developer ID 証明書がない場合、署名なしの DMG が作られる。

### 2. Release ビルド + DMG + Notarization

```bash
export NOTARIZE_APPLE_ID="your@email.com"
export NOTARIZE_TEAM_ID="XXXXXXXXXX"
export NOTARIZE_PASSWORD="xxxx-xxxx-xxxx-xxxx"

./scripts/build_release.sh --notarize
```

Notarization 完了後、staple 済みの DMG が `dist/` に出力される。

### 3. 配布

Notarize + staple 済みの DMG をユーザーに渡す。
ユーザーは DMG を開き、Clabotch.app を /Applications にドラッグするだけ。

## バージョン管理

バージョンは `src/project.yml` の `MARKETING_VERSION` で一元管理:

```yaml
MARKETING_VERSION: "1.0.0"
CURRENT_PROJECT_VERSION: "1"
```

リリース時は `MARKETING_VERSION` を更新し、`CURRENT_PROJECT_VERSION` をインクリメントする。

## プロジェクト設定のポイント

| 設定 | 値 | 理由 |
|------|-----|------|
| `ENABLE_HARDENED_RUNTIME` | `YES` | Notarization 必須 |
| `ENABLE_APP_SANDBOX` | `NO` | AX API + Unix domain socket に必要 |
| `CODE_SIGN_ENTITLEMENTS` | `Clabotch.entitlements` | Apple Events entitlement |
| `LSUIElement` | `YES` | メニューバー常駐（Dock 非表示） |

### Entitlements

`src/Clabotch/Clabotch.entitlements`:
- `com.apple.security.automation.apple-events`: Accessibility API 利用に必要

### App Sandbox を有効にしない理由

Clabotch は以下の機能のために Sandbox 外で動作する必要がある:
- `/tmp/clabotch/` への Unix domain socket 作成
- Accessibility API（`AXIsProcessTrusted`）によるウィンドウ情報取得
- `SMAppService` によるログイン時自動起動

## CI との関係

CI（`.github/workflows/ci.yml`）では `CODE_SIGNING_ALLOWED=NO` でビルドする。
Release ビルドはローカルマシンで実行し、証明書付きで署名する。

## トラブルシューティング

### 「Developer ID Application 証明書が見つかりません」

```bash
security find-identity -v -p codesigning
```

で証明書一覧を確認。Developer ID Application が表示されない場合:
- Xcode → Settings → Accounts で証明書を再ダウンロード
- Apple Developer Portal で証明書を確認

### Notarization が失敗する

```bash
xcrun notarytool log <submission-id> \
  --apple-id "$NOTARIZE_APPLE_ID" \
  --team-id "$NOTARIZE_TEAM_ID" \
  --password "$NOTARIZE_PASSWORD"
```

でログを確認。よくある原因:
- Hardened Runtime が無効
- 未署名のバイナリが含まれている
- Entitlements の不整合
