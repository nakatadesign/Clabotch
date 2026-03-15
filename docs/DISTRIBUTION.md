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

4. **Team ID の確認**
   - Apple Developer Portal の [Membership](https://developer.apple.com/account#MembershipDetailsCard) で確認
   - 例: `ABCD1234EF`

5. **Notarization 認証情報の保存**（推奨: keychain profile 方式）
   ```bash
   xcrun notarytool store-credentials "clabotch-notary" \
     --apple-id "your@email.com" \
     --team-id "YOUR_TEAM_ID" \
     --password "app-specific-password"
   ```

### ツール

- `xcodegen`（`brew install xcodegen`）
- Xcode（Command Line Tools 含む）
- `hdiutil`（macOS 標準）

---

## ビルド＆配布フロー

### 1. 署名付きビルド + DMG

```bash
export DEVELOPMENT_TEAM="YOUR_TEAM_ID"
./scripts/build_release.sh
```

出力: `dist/Clabotch-<version>.dmg`

### 2. ビルド + DMG + Notarization

#### Keychain Profile 方式（推奨）

```bash
export DEVELOPMENT_TEAM="YOUR_TEAM_ID"
./scripts/build_release.sh --notarize --keychain-profile clabotch-notary
```

#### 環境変数方式

```bash
export DEVELOPMENT_TEAM="YOUR_TEAM_ID"
export NOTARIZE_APPLE_ID="your@email.com"
export NOTARIZE_TEAM_ID="YOUR_TEAM_ID"
export NOTARIZE_PASSWORD="xxxx-xxxx-xxxx-xxxx"
./scripts/build_release.sh --notarize
```

### 3. 署名なしビルド（テスト用）

```bash
./scripts/build_release.sh --unsigned
```

### 4. 配布

Notarize + staple 済みの DMG をユーザーに渡す。
ユーザーは DMG を開き、Clabotch.app を /Applications にドラッグするだけ。

---

## 検証

### 自動検証

```bash
./scripts/build_release.sh --verify-only
```

### 手動検証

```bash
APP="build/app/Clabotch.app"
DMG="dist/Clabotch-1.0.0.dmg"

# コード署名
codesign --verify --deep --strict "${APP}"
codesign -dvv "${APP}" 2>&1 | grep -E "Authority|TeamIdentifier"

# Hardened Runtime + Entitlements
codesign -d --entitlements - "${APP}"

# Gatekeeper（notarization 後のみ通過）
spctl --assess --type execute "${APP}"
spctl --assess --type open --context context:primary-signature "${DMG}"

# Staple 確認
xcrun stapler validate "${DMG}"

# Notarization ログ（失敗時）
xcrun notarytool log <SUBMISSION_ID> --keychain-profile clabotch-notary
```

---

## 開発ビルド vs 配布ビルド

| 項目 | Debug（開発） | Release（配布） |
|------|-------------|----------------|
| 署名 | ad-hoc (`-`) | Developer ID Application |
| Hardened Runtime | 無効化 | 有効 |
| Team ID | 不要 | `DEVELOPMENT_TEAM` 必須 |
| AX 権限 | リビルドで TCC リセット | 署名固定で安定 |
| SMAppService | 不安定な場合あり | 正常動作 |
| Gatekeeper | 警告表示 | 通過（notarization 後） |
| Notarization | 不可 | 可能 |

### 注意点

- **AX 権限**: ad-hoc 署名はリビルドのたびに署名が変わり、TCC がリセットされる。Developer ID 署名では安定する。
- **SMAppService**: ad-hoc 署名では `SMAppService.mainApp.status` が不正確になる場合がある。配布ビルドでは正常動作。
- **Hardened Runtime**: Debug ビルドでは `Disabling hardened runtime with ad-hoc codesigning` が出るが正常。

---

## バージョン管理

`src/project.yml` の `MARKETING_VERSION` で一元管理:

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

### App Sandbox を有効にしない理由

Clabotch は以下の機能のために Sandbox 外で動作する:
- `/tmp/clabotch/` への Unix domain socket 作成
- Accessibility API（`AXIsProcessTrusted`）によるウィンドウ情報取得
- `SMAppService` によるログイン時自動起動

---

## スクリプトオプション一覧

```
./scripts/build_release.sh [OPTIONS]

  (なし)                 署名付きビルド + DMG
  --unsigned             署名なしビルド + DMG（テスト用）
  --notarize             ビルド + DMG + Notarization
  --keychain-profile P   Notarization に keychain profile を使用
  --skip-build           DMG のみ作成（ビルド済み前提）
  --verify-only          既存成果物の署名 / Gatekeeper 検証
  --help                 ヘルプ表示
```

## CI との関係

CI では `CODE_SIGNING_ALLOWED=NO` でビルドする。
Release ビルドはローカルマシンで実行し、証明書付きで署名する。

---

## トラブルシューティング

### 「Developer ID Application 証明書が見つかりません」

```bash
security find-identity -v -p codesigning | grep "Developer ID"
```

証明書がない場合は Xcode → Settings → Accounts で再ダウンロード。

### DEVELOPMENT_TEAM が未設定

```bash
export DEVELOPMENT_TEAM="YOUR_TEAM_ID"
```

Apple Developer の Membership ページで Team ID を確認。

### Notarization が失敗する

```bash
# ログ確認
xcrun notarytool log <SUBMISSION_ID> --keychain-profile clabotch-notary
```

よくある原因:
- Hardened Runtime が無効
- 未署名のバイナリが含まれている
- Entitlements の不整合

### Gatekeeper で拒否される

notarization 前は `spctl --assess` が失敗するのは正常。
notarization + staple 後に再検証。
