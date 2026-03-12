# 実装計画 010: GitHub Actions CI 整備

## 概要

GitHub Actions で build/test を自動化し、main push / main 向け PR 時の回帰を検知する。

## 正典参照

- 設計書: `docs/design/current/clabotch_design_doc_v11.md`
- 本計画は設計書の対象外（CI/CD インフラ）。逸脱なし。

## 正典からの逸脱

なし。CI 整備は設計書のスコープ外。

## 前提条件

- [x] 計画 002〜009 完了
- [x] xcodegen + xcodebuild によるビルド・テスト環境が確立済み
- [x] hook スクリプトの E2E テスト（`tests/test_hooks.sh`）が存在
- [x] `project.yml` で `CODE_SIGN_ENTITLEMENTS: ""` / `ENABLE_APP_SANDBOX: NO` 設定済み（未署名ビルド可能）

## スコープ

**含む:**
- GitHub Actions ワークフロー定義（`.github/workflows/ci.yml`）
- Swift ビルド＋テスト（`build-for-testing` → `test-without-building`、`-derivedDataPath` 明示で再現性確保）
- xcodegen 後の `.xcodeproj` drift 検知（`git diff --exit-code` + untracked ファイル検出）
- xcodegen バージョン固定（`.xcodegen.lock` ファイルにバージョン + SHA256 を一元管理、GitHub Releases バイナリ取得）
- hook スクリプト E2E テスト（`tests/test_hooks.sh`、socat を CI で必須化）
- main push / main 向け PR トリガー + `workflow_dispatch`（手動実行による CI 検証・障害切り分け）
- xcresult artifact upload（失敗時のみ、`retention-days: 7`）
- 最小権限（`permissions: contents: read`、`persist-credentials: false`）と concurrency 制御
- ランナーデフォルトの Xcode を使用（壊れた時の退避手順を明記）
- ツールチェーン・ランナー情報のログ出力
- actions を commit SHA で pin（サプライチェーン保護）
- `HOMEBREW_NO_AUTO_UPDATE=1` で brew の非決定性を軽減（残余リスクあり）
- プリインストール依存の明示的検証（`jq --version`）
- branch protection / required checks の手動設定手順の文書化

**含まない:**
- Xcode Cloud / TestFlight 連携
- コード署名・notarization
- カバレッジ計測・レポート（将来拡張）
- リリースワークフロー
- Intel (x86_64) 対応（下記「既知の制約」参照）

### 既知の制約

- **CI 保証範囲は macOS 15 arm64 のみ**: `macos-15` ランナーは arm64。`project.yml` の `deploymentTarget` は macOS 13 だが、macOS 13 / 14 / Intel での動作は CI では未検証・未保証。macOS 13 ランナーは GitHub Actions で retired 済み（2025-12-04）。個人利用アプリのため macOS 15 arm64 の CI 保証で十分とし、`deploymentTarget` の引き上げは本計画のスコープ外
- **Intel (x86_64) 非対応**: Clabotch は個人利用の macOS アプリであり、Intel 対応は不要。将来必要になれば `macos-15-intel` を追加する

## 詳細設計

### Step 1: xcodegen ロックファイル

`.xcodegen.lock`:

```
version: 2.45.3
sha256: 0c90f4d28ca57335f9fa78cf5bf6dabfe20a232036dabe36de2eef79cb7c0878
```

バージョンと SHA256 checksum を単一ファイルで管理する。CI とローカルの両方がこのファイルを参照し、同一バージョンの xcodegen を使用する。更新時はこのファイルのみ変更すれば良い。

### Step 2: ワークフロー定義

`.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: ci-${{ github.workflow }}-${{ github.event_name }}-${{ github.ref }}
  cancel-in-progress: true

env:
  HOMEBREW_NO_AUTO_UPDATE: 1

jobs:
  build-and-test:
    name: Build & Test (Swift)
    runs-on: macos-15
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          persist-credentials: false

      - name: Show environment info
        run: |
          sw_vers
          uname -m
          xcode-select -p
          xcodebuild -version
          swift --version

      - name: Install xcodegen (pinned)
        run: |
          set -euo pipefail
          XCODEGEN_VERSION="$(grep '^version:' .xcodegen.lock | awk '{print $2}')"
          XCODEGEN_SHA256="$(grep '^sha256:' .xcodegen.lock | awk '{print $2}')"
          curl -fsSL --retry 3 -o "$RUNNER_TEMP/xcodegen.zip" \
            "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
          echo "${XCODEGEN_SHA256}  $RUNNER_TEMP/xcodegen.zip" | shasum -a 256 -c -
          mkdir -p "$RUNNER_TEMP/xcodegen-bin"
          unzip -o -q "$RUNNER_TEMP/xcodegen.zip" -d "$RUNNER_TEMP/xcodegen-bin"
          echo "$RUNNER_TEMP/xcodegen-bin/bin" >> "$GITHUB_PATH"
          "$RUNNER_TEMP/xcodegen-bin/bin/xcodegen" version

      - name: Create artifacts directory
        run: mkdir -p artifacts

      - name: Generate Xcode project
        run: cd src && xcodegen generate

      - name: Check xcodeproj drift
        run: |
          set -euo pipefail
          cd src
          if ! git diff --exit-code -- Clabotch.xcodeproj; then
            echo "::error::xcodegen generate produced a different .xcodeproj than what is committed. Run 'cd src && xcodegen generate' locally and commit the result."
            exit 1
          fi
          UNTRACKED="$(git ls-files --others --exclude-standard -- Clabotch.xcodeproj)"
          if [ -n "$UNTRACKED" ]; then
            echo "::error::xcodegen generated untracked files in Clabotch.xcodeproj: $UNTRACKED"
            exit 1
          fi

      - name: Build for testing
        run: |
          cd src
          xcodebuild build-for-testing \
            -project Clabotch.xcodeproj \
            -scheme Clabotch \
            -destination 'platform=macOS,arch=arm64' \
            -derivedDataPath ../artifacts/DerivedData \
            -resultBundlePath ../artifacts/build.xcresult \
            CODE_SIGNING_ALLOWED=NO

      - name: Test without rebuilding
        run: |
          cd src
          xcodebuild test-without-building \
            -project Clabotch.xcodeproj \
            -scheme Clabotch \
            -destination 'platform=macOS,arch=arm64' \
            -derivedDataPath ../artifacts/DerivedData \
            -resultBundlePath ../artifacts/test.xcresult

      - name: Upload xcresult artifacts
        if: ${{ failure() }}
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with:
          name: xcresult-${{ github.run_id }}
          path: artifacts/*.xcresult
          retention-days: 7

  hook-tests:
    name: Hook E2E Tests
    runs-on: macos-15
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
        with:
          persist-credentials: false

      - name: Verify prerequisites
        run: |
          set -euo pipefail
          jq --version
          bash --version | head -1
          uuidgen >/dev/null && echo "uuidgen: ok"

      - name: Install dependencies
        run: brew install socat

      - name: Run hook E2E tests
        run: bash tests/test_hooks.sh

      - name: Upload test logs on failure
        if: ${{ failure() }}
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with:
          name: hook-test-logs-${{ github.run_id }}
          path: /tmp/clabotch-test-*
          retention-days: 7
          if-no-files-found: ignore
```

### 設計判断

1. **ランナーデフォルト Xcode を使用**: `DEVELOPER_DIR` による固定はしない。ランナーイメージ更新に自動追随し、メンテナンスコストを最小化する。壊れた場合は「Xcode 壊れた時の退避手順」に従う。`xcode-select -p` / `xcodebuild -version` / `sw_vers` でバージョンをログに残し、問題発生時の切り分けに使う
2. **xcodegen を `.xcodegen.lock` + GitHub Releases から pin**: バージョンと SHA256 checksum を `.xcodegen.lock` ファイル 1 つで管理し、CI とローカルの single source of truth とする。CI では GitHub Releases のバイナリを取得し checksum 検証。`sudo` 不要で `RUNNER_TEMP` に展開。更新時は `.xcodegen.lock` のみ変更する
3. **actions の commit SHA pin**: `actions/checkout` / `actions/upload-artifact` を tag ではなく commit SHA で固定。サプライチェーン攻撃（tag の書き換え）を防止。コメントでバージョンを明記し可読性を維持。更新は手動で SHA を差し替え（Dependabot / Renovate の導入は将来検討）
4. **macos-15 ランナー (arm64)**: GitHub Actions の最新安定ランナー。Intel / macOS 13 は CI の保証対象外。`-destination 'platform=macOS,arch=arm64'` で arm64 を明示
5. **2 ジョブ分離**: Swift ビルド/テストと hook テストは独立。並列実行で高速化＋失敗原因の切り分け。明示的な job `name:` で required checks の設定を安定化
6. **build-for-testing + test-without-building + derivedDataPath**: 二重ビルド回避。`-derivedDataPath` で DerivedData の場所を明示し、build と test の受け渡しを確実にする
7. **xcodeproj drift 検知（diff + untracked）**: `xcodegen generate` 後に `git diff --exit-code` で変更を、`git ls-files --others` で未追跡ファイルを検出。`project.yml` を正典とし、コミット済み `.xcodeproj` との不整合を CI で可視化する
8. **CODE_SIGNING_ALLOWED=NO**: CI 環境で署名不要を明示的に保証
9. **プリインストール依存の明示的検証**: `jq --version` を CI で実行し、プリインストール前提が崩れた場合に即座に検出。設計書 §10.4 では `jq` が必須依存
10. **socat のみ brew install**: `jq` は `macos-15` ランナーにプリインストール済み。hook-tests で `socat` のみ追加。`HOMEBREW_NO_AUTO_UPDATE=1` で自動更新を抑制するが、runner image 側の formula 変動までは止められない（残余リスク）
11. **xcresult artifact（failure() のみ）**: 失敗時のみ診断情報を保存。`cancelled()` 時は job 自体が中断される可能性があり保証できないため除外。`retention-days: 7` でストレージを節約
12. **permissions: contents: read + persist-credentials: false**: 最小権限の原則。read-only token 露出を最小化
13. **concurrency（event_name 含む）**: `github.event_name` を concurrency group に含め、`workflow_dispatch` と push/PR の CI が相互に cancel しないようにする
14. **ランナー情報のログ出力**: `sw_vers`、`uname -m`、`xcode-select -p`、`xcodebuild -version`、`swift --version` でランナーイメージ起因の障害切り分けを容易にする
15. **workflow_dispatch**: CI 自体の検証・障害切り分けに手動トリガーを提供
16. **main push / main PR のみ**: feature branch は PR 経由で CI を実行する運用
17. **`set -euo pipefail`**: 複数行の `run` ステップで未定義変数やパイプ失敗を即座に検出。GitHub Actions のデフォルト `set -e` だけではパイプ失敗を捕捉できない
18. **`curl --retry 3`**: GitHub Releases からの xcodegen ダウンロードで一時的なネットワーク障害に対応
19. **hook-tests の暗黙依存検証**: `bash --version` と `uuidgen` を Verify prerequisites で明示的に確認。`socat` は Install dependencies で追加。`nc -U` は `test_hooks.sh` 内部で使用され、失敗時はテスト自体がエラーとなるため個別検証は不要
20. **hook-tests の artifact**: 失敗時に `/tmp/clabotch-test-*`（テストが生成する一時ファイル）をアップロード。`if-no-files-found: ignore` でファイルが存在しない場合もエラーにしない

### Xcode 壊れた時の退避手順

ランナーイメージの Xcode 更新でビルドが壊れた場合:

1. CI ログの `xcode-select -p` / `xcodebuild -version` / `sw_vers` でランナーの Xcode バージョンを確認
2. 以下のいずれかで対応:
   a. **コード修正**: 新しい Xcode で必要な修正を行い、テストを通す（推奨）
   b. **Xcode 固定**: workflow の `build-and-test` job に `env: DEVELOPER_DIR: /Applications/Xcode_<version>.app/Contents/Developer` を追加し、ランナーにプリインストールされているバージョンを指定
   c. **setup-xcode action**: `maxim-lobanov/setup-xcode` action で特定バージョンを選択（SHA pin で使用すること）
3. 修正を PR で main にマージ

### Step 3: branch protection 設定（手動）

push 後に以下を手動で設定する:

1. GitHub リポジトリ Settings → Branches → Branch protection rules
2. `main` ブランチに対して:
   - [x] Require a pull request before merging（PR 必須化）
   - [x] Require status checks to pass before merging
   - [x] `Build & Test (Swift)` と `Hook E2E Tests` を required checks に追加
   - [x] Require branches to be up to date before merging
   - [x] Do not allow bypassing the above settings（admin bypass 禁止）
3. 運用方針:
   - **PR 必須 + admin bypass 禁止**を推奨。直接 push でも `push: main` トリガーにより CI は実行されるが、required checks は main への直接 push を事前にブロックできない。回帰を main に入れる前に止めるため、PR 経由必須とする
   - approval 件数は個人開発のため 0（self-merge 許可）。チーム開発に移行する場合は 1 以上に引き上げる
   - 緊急時は branch protection を一時的に無効化し、修正後に即座に再有効化する
   - branch protection は CI が安定してから設定する（初回 green 確認後）

**注意**: branch protection は GitHub API / UI での手動設定が必要。ワークフローファイルだけでは回帰防止が不完全。

## ファイル構成

### 新規ファイル

| ファイル | 役割 |
|----------|------|
| `.xcodegen.lock` | xcodegen バージョン + SHA256 の single source of truth |
| `.github/workflows/ci.yml` | CI ワークフロー定義 |

### 変更ファイル

なし。

## テスト

### ローカル検証

1. `XCODEGEN_VERSION=$(grep '^version:' .xcodegen.lock | awk '{print $2}') && xcodegen version | grep -q "$XCODEGEN_VERSION"` でバージョンが一致すること
2. `cd src && xcodegen generate && git diff --exit-code -- Clabotch.xcodeproj` で drift がないこと
3. `cd src && xcodebuild build-for-testing -project Clabotch.xcodeproj -scheme Clabotch -destination 'platform=macOS,arch=arm64' -derivedDataPath ../artifacts/DerivedData CODE_SIGNING_ALLOWED=NO` が成功すること
4. `cd src && xcodebuild test-without-building -project Clabotch.xcodeproj -scheme Clabotch -destination 'platform=macOS,arch=arm64' -derivedDataPath ../artifacts/DerivedData` が全テスト成功すること
5. `bash tests/test_hooks.sh` が全パスすること

**注意**: ローカル検証コマンドは CI と同じ `-destination 'platform=macOS,arch=arm64'` を使用する。Intel Mac の場合は `arch=arm64` を除外すること。

### CI 検証（push 後）

- GitHub Actions の `Build & Test (Swift)` ジョブが成功すること
- GitHub Actions の `Hook E2E Tests` ジョブが成功すること
- 失敗時に xcresult artifact がアップロードされること（`failure()` で保証）
- `sw_vers` / `xcode-select -p` / `xcodebuild -version` / `xcodegen version` がログに出力されること
- xcodeproj drift 検知ステップが成功すること
- xcodegen SHA256 検証が成功すること

### 成功条件

- CI ワークフローが green になること
- 全 Swift テストが成功すること（現時点: 203 passed, 1 skipped）
- hook E2E テスト（約 35 件）が全パスすること
- 設計書の不変条件（`schema_version` / `event_id` 検証、`session_id` 欠損時 drop-and-log、single-session guard）は既存のユニットテストでカバー済み。CI はこれらのテストを毎回実行することで不変条件の回帰を防止する

## リスク

| リスク | 対策 |
|--------|------|
| ランナーイメージの Xcode 更新でビルドが壊れる | ランナーデフォルトに追随する方針。壊れた場合は「Xcode 壊れた時の退避手順」に従い、コード修正 or DEVELOPER_DIR 固定 or setup-xcode で対応 |
| xcodegen のバージョン変動 | `.xcodegen.lock` で version + SHA256 を一元管理。GitHub Releases バイナリを checksum 検証で完全 pin |
| CI とローカルの xcodegen バージョン不一致 | `.xcodegen.lock` を single source of truth として共有。drift 検知で不一致を検出 |
| actions の tag 書き換え（サプライチェーン攻撃） | commit SHA で pin。更新は手動で SHA を差し替え |
| runner image 側の socat formula 変動 | `HOMEBREW_NO_AUTO_UPDATE=1` で軽減するが、image 更新時の変動は残余リスク。壊れた場合は version pin を検討 |
| jq プリインストール前提が崩れる | `jq --version` を CI で明示的に検証。失敗時は `brew install jq` をステップに追加 |
| project.yml と .xcodeproj の乖離 | `xcodegen generate` 後に `git diff --exit-code` + `git ls-files --others` で検知 |
| xcodebuild test がヘッドレスでクラッシュ | BubbleWindow の DI seam で NSWindow 生成を回避済み。xcresult artifact で診断情報を保存 |
| macOS ランナーが遅い | 2 ジョブ並列 + build-for-testing/test-without-building で最適化。timeout-minutes: 20（build-and-test: xcodegen + build + 203 テスト実行の合計）/ 10（hook-tests: socat install + E2E 35 件）で暴走防止 |
| cancelled 時の xcresult 保存 | best-effort。`failure()` のみ保証し、cancelled は job 中断の可能性があるため保証対象外 |
| DerivedData の不整合 | `-derivedDataPath` で明示指定。build と test で同一パスを使用 |
| deploymentTarget (macOS 13) と CI 検証範囲の乖離 | CI 保証範囲は macOS 15 arm64 のみ。macOS 13/14/Intel は未検証・未保証。個人利用アプリのため許容。`deploymentTarget` 引き上げは将来の計画で検討 |

## テスト数

| 区分 | テスト数 |
|------|---------|
| 既存 Swift テスト | 204（203 passed, 1 skipped） |
| hook E2E テスト | 約 35 件（test_hooks.sh） |
| 新規テスト | 0 |
| **合計目標** | 全テスト成功 + hook テスト全パス |
