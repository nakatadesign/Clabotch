#!/usr/bin/env bash
# scripts/build_release.sh — Release ビルド + DMG 作成 + Notarization
#
# 使い方:
#   ./scripts/build_release.sh                    # ビルド + DMG（署名付き）
#   ./scripts/build_release.sh --unsigned         # ビルド + DMG（署名なし、テスト用）
#   ./scripts/build_release.sh --notarize         # ビルド + DMG + Notarization
#   ./scripts/build_release.sh --skip-build       # DMG のみ（ビルド済み前提）
#
# 前提条件:
#   - xcodegen がインストール済み
#   - Developer ID Application 証明書がキーチェーンにインストール済み
#   - Notarization 時: NOTARIZE_APPLE_ID, NOTARIZE_TEAM_ID, NOTARIZE_PASSWORD 環境変数
#     (NOTARIZE_PASSWORD は app-specific password または keychain profile)
#
# 出力:
#   dist/Clabotch-<version>.dmg
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="${REPO_ROOT}/src"
DIST_DIR="${REPO_ROOT}/dist"
BUILD_DIR="${REPO_ROOT}/build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"

# オプション解析
NOTARIZE=false
SKIP_BUILD=false
UNSIGNED=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notarize) NOTARIZE=true; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --unsigned) UNSIGNED=true; shift ;;
    --help|-h)
      sed -n '2,/^set /{ /^#/s/^# \?//p }' "$0"
      exit 0
      ;;
    *) echo "ERROR: 不明なオプション: $1" >&2; exit 1 ;;
  esac
done

if [[ "${UNSIGNED}" == "true" && "${NOTARIZE}" == "true" ]]; then
  echo "ERROR: --unsigned と --notarize は同時に指定できません" >&2
  exit 1
fi

# バージョン取得
VERSION="$(grep 'MARKETING_VERSION:' "${SRC_DIR}/project.yml" | head -1 | awk -F'"' '{print $2}')"
if [[ -z "${VERSION}" ]]; then
  echo "ERROR: MARKETING_VERSION を project.yml から取得できません" >&2
  exit 1
fi
echo "==> Clabotch v${VERSION}"

# Notarization の環境変数チェック
if [[ "${NOTARIZE}" == "true" ]]; then
  for var in NOTARIZE_APPLE_ID NOTARIZE_TEAM_ID NOTARIZE_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
      echo "ERROR: ${var} が設定されていません" >&2
      exit 1
    fi
  done
fi

# ビルド
if [[ "${SKIP_BUILD}" == "false" ]]; then
  echo "==> xcodegen generate"
  (cd "${SRC_DIR}" && xcodegen generate)

  # 署名オプション
  SIGN_ARGS=()
  if [[ "${UNSIGNED}" == "true" ]]; then
    SIGN_ARGS+=(CODE_SIGNING_ALLOWED=NO)
    echo "==> Release ビルド（署名なし）"
  else
    echo "==> Release ビルド（署名付き）"
  fi

  xcodebuild archive \
    -project "${SRC_DIR}/Clabotch.xcodeproj" \
    -scheme Clabotch \
    -configuration Release \
    -archivePath "${BUILD_DIR}/Clabotch.xcarchive" \
    -derivedDataPath "${DERIVED_DATA}" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=NO \
    "${SIGN_ARGS[@]}" \
    | tail -5

  echo "==> .app をエクスポート"
  mkdir -p "${BUILD_DIR}/app"
  cp -R "${BUILD_DIR}/Clabotch.xcarchive/Products/Applications/Clabotch.app" \
        "${BUILD_DIR}/app/Clabotch.app"
else
  echo "==> ビルドスキップ（既存の .app を使用）"
  if [[ ! -d "${BUILD_DIR}/app/Clabotch.app" ]]; then
    echo "ERROR: ${BUILD_DIR}/app/Clabotch.app が見つかりません" >&2
    exit 1
  fi
fi

APP_PATH="${BUILD_DIR}/app/Clabotch.app"

# コード署名の検証
echo "==> コード署名を検証"
if codesign --verify --deep --strict "${APP_PATH}" 2>/dev/null; then
  echo "    署名: OK"
  codesign -dvv "${APP_PATH}" 2>&1 | grep -E "^(Authority|TeamIdentifier|Signature)" || true
else
  echo "    警告: コード署名なし、または無効（Developer ID 証明書をインストールしてください）"
fi

# DMG 作成
mkdir -p "${DIST_DIR}"
DMG_NAME="Clabotch-${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
DMG_STAGING="${BUILD_DIR}/dmg-staging"

echo "==> DMG 作成: ${DMG_NAME}"
rm -rf "${DMG_STAGING}" "${DMG_PATH}"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_PATH}" "${DMG_STAGING}/"

# Applications シンボリックリンク（ドラッグ&ドロップインストール用）
ln -s /Applications "${DMG_STAGING}/Applications"

hdiutil create \
  -volname "Clabotch ${VERSION}" \
  -srcfolder "${DMG_STAGING}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

rm -rf "${DMG_STAGING}"
echo "    DMG: ${DMG_PATH}"
echo "    サイズ: $(du -h "${DMG_PATH}" | awk '{print $1}')"

# Notarization
if [[ "${NOTARIZE}" == "true" ]]; then
  echo "==> Notarization 投入"
  xcrun notarytool submit "${DMG_PATH}" \
    --apple-id "${NOTARIZE_APPLE_ID}" \
    --team-id "${NOTARIZE_TEAM_ID}" \
    --password "${NOTARIZE_PASSWORD}" \
    --wait

  echo "==> Staple"
  xcrun stapler staple "${DMG_PATH}"

  echo "==> Notarization 完了"
fi

echo ""
echo "=== 完了 ==="
echo "DMG: ${DMG_PATH}"
if [[ "${NOTARIZE}" == "true" ]]; then
  echo "Notarization: stapled"
fi
