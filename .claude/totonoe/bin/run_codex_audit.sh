#!/usr/bin/env bash

set -euo pipefail

BIN_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${BIN_DIR}/common.sh"

usage() {
  cat <<'EOF'
Usage:
  .claude/totonoe/bin/run_codex_audit.sh --job-name <name> [--round <n>] [--dry-run]

Codex が復活した後に、過去の Gemini 実行結果を添削する。
--round を省略すると全ラウンドを走査する。
--dry-run を指定すると対象一覧を表示するのみで実行しない。
EOF
}

build_audit_prompt() {
  local role="$1"
  local original_prompt_file="$2"
  local gemini_result_file="$3"
  local meta_file="$4"
  local audit_prompt_file="$5"

  local gemini_result meta_json original_prompt
  gemini_result="$(safe_read "${gemini_result_file}")"
  meta_json="$(safe_read "${meta_file}")"
  original_prompt="$(safe_read "${original_prompt_file}")"

  {
    printf '# Codex Audit Task\n\n'
    printf 'あなたは Codex（上位モデル）として、Gemini（下位モデル）が行った %s の判断を添削します。\n\n' "${role}"
    printf '## 添削の観点\n\n'
    printf -- '1. Gemini の判断は妥当か（agree / partial / disagree）\n'
    printf -- '2. 見落とした問題はないか（missed_issues）\n'
    printf -- '3. 過剰な指摘はないか（spurious_issues）\n'
    printf -- '4. グレードや recommendation の調整が必要か（grade_adjustment）\n\n'
    printf '## 実行メタデータ\n\n'
    printf '```json\n%s\n```\n\n' "${meta_json}"
    printf '## Gemini に渡された元のプロンプト\n\n'
    printf '%s\n\n' "${original_prompt}"
    printf '## Gemini の出力結果\n\n'
    printf '```json\n%s\n```\n\n' "${gemini_result}"
    printf '## 出力ルール\n\n'
    printf -- '- JSON のみを返すこと（スキーマに従う）\n'
    printf -- '- `agreement`: agree（妥当）/ partial（一部問題あり）/ disagree（判断ミス）\n'
    printf -- '- `grade_adjustment`: 変更不要なら "none"\n'
    printf -- '- `missed_issues`: Gemini が見落とした問題のリスト\n'
    printf -- '- `spurious_issues`: Gemini が過剰に指摘した問題のリスト\n'
    printf -- '- `assessment`: 添削の総合所見（日本語で）\n'
  } | safe_write "${audit_prompt_file}"
}

find_audit_targets() {
  local job_name="$1"
  local target_round="$2"
  local job_path
  job_path="$(job_dir "${job_name}")"

  local rounds_dir="${job_path}/rounds"
  [ -d "${rounds_dir}" ] || return 0

  local round_dirs=()
  if [ -n "${target_round}" ]; then
    local rd
    rd="$(printf '%s/%03d' "${rounds_dir}" "${target_round}")"
    [ -d "${rd}" ] && round_dirs+=("${rd}")
  else
    local d
    while IFS= read -r d; do
      round_dirs+=("${d}")
    done < <(find "${rounds_dir}" -mindepth 1 -maxdepth 1 -type d | sort)
  fi

  local rd meta_file
  for rd in "${round_dirs[@]}"; do
    while IFS= read -r meta_file; do
      # provider=gemini かつ audited=false のものだけ対象
      if jq -e '.provider == "gemini" and .audited == false' "${meta_file}" >/dev/null 2>&1; then
        printf '%s\n' "${meta_file}"
      fi
    done < <(find "${rd}" -maxdepth 1 -name '*.meta.json' -type f 2>/dev/null | sort)
  done
}

derive_paths_from_meta() {
  local meta_file="$1"
  local meta_dir meta_basename base_name

  meta_dir="$(dirname -- "${meta_file}")"
  meta_basename="$(basename -- "${meta_file}" .meta.json)"

  # 元の結果ファイル
  DERIVED_RESULT="${meta_dir}/${meta_basename}.json"
  # 元のプロンプトファイル
  DERIVED_PROMPT="${meta_dir}/${meta_basename}.prompt.md"
  # Gemini 生レスポンス
  DERIVED_RAW="${meta_dir}/${meta_basename}.gemini_raw.json"
  # 添削出力先
  DERIVED_AUDIT="${meta_dir}/${meta_basename}.codex_audit.json"
  # 添削プロンプト
  DERIVED_AUDIT_PROMPT="${meta_dir}/${meta_basename}.codex_audit.prompt.md"
}

main() {
  require_cmd jq
  require_cmd codex

  local job_name="" target_round="" dry_run="0"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --job-name)
        job_name="${2:-}"
        shift 2
        ;;
      --round)
        target_round="${2:-}"
        shift 2
        ;;
      --dry-run)
        dry_run="1"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  validate_job_name "${job_name}"
  ensure_job_exists "${job_name}"

  local targets=()
  mapfile -t targets < <(find_audit_targets "${job_name}" "${target_round}")

  if [ "${#targets[@]}" -eq 0 ]; then
    printf '添削対象なし（Gemini 実行で未添削のものがありません）\n'
    exit 0
  fi

  printf '添削対象: %d 件\n' "${#targets[@]}"

  local meta_file role
  for meta_file in "${targets[@]}"; do
    role="$(jq -r '.role' "${meta_file}")"
    derive_paths_from_meta "${meta_file}"
    printf '  [%s] %s\n' "${role}" "${meta_file}"
  done

  if [ "${dry_run}" = "1" ]; then
    printf '\n--dry-run: 実行せずに終了します\n'
    exit 0
  fi

  local success_count=0
  local fail_count=0

  for meta_file in "${targets[@]}"; do
    role="$(jq -r '.role' "${meta_file}")"
    derive_paths_from_meta "${meta_file}"

    # プロンプトまたは結果ファイルが欠落していたらスキップ
    if [ ! -f "${DERIVED_RESULT}" ]; then
      warn "結果ファイルが見つかりません: ${DERIVED_RESULT}"
      fail_count=$((fail_count + 1))
      continue
    fi
    if [ ! -f "${DERIVED_PROMPT}" ]; then
      warn "プロンプトファイルが見つかりません: ${DERIVED_PROMPT}"
      fail_count=$((fail_count + 1))
      continue
    fi

    printf '\n添削実行: [%s] %s\n' "${role}" "$(basename -- "${meta_file}")"

    # 添削プロンプトを生成
    build_audit_prompt "${role}" "${DERIVED_PROMPT}" "${DERIVED_RESULT}" "${meta_file}" "${DERIVED_AUDIT_PROMPT}"

    # Codex で添削実行
    local codex_stdout codex_stderr
    codex_stdout="$(mktemp)"
    codex_stderr="$(mktemp)"

    if codex exec --sandbox read-only \
      --output-schema "${SCHEMAS_DIR}/codex_audit.schema.json" \
      < "${DERIVED_AUDIT_PROMPT}" \
      > "${codex_stdout}" 2> "${codex_stderr}"; then

      # 出力検証
      if jq -e '
        (.agreement == "agree" or .agreement == "partial" or .agreement == "disagree")
        and (.assessment | type == "string")
      ' "${codex_stdout}" >/dev/null 2>&1; then

        safe_write "${DERIVED_AUDIT}" < "${codex_stdout}"

        # meta.json の audited フラグを更新
        local updated_meta
        updated_meta="$(jq --arg ts "$(now_utc)" '.audited = true | .audited_at = $ts' "${meta_file}")"
        printf '%s\n' "${updated_meta}" | safe_write "${meta_file}"

        local agreement
        agreement="$(jq -r '.agreement' "${DERIVED_AUDIT}")"
        printf '  → 添削完了: agreement=%s\n' "${agreement}"

        append_event_log_safe \
          "$(events_path "${job_name}")" \
          "$(jq -nc \
            --arg ts "$(now_utc)" \
            --arg job "${job_name}" \
            --arg role "${role}" \
            --arg agreement "${agreement}" \
            --arg meta "$(basename -- "${meta_file}")" \
            '{
              ts: $ts,
              type: "codex_audit_completed",
              job: $job,
              role: $role,
              agreement: $agreement,
              meta_file: $meta
            }')"

        success_count=$((success_count + 1))
      else
        warn "Codex 出力がスキーマに合致しません"
        fail_count=$((fail_count + 1))
      fi
    else
      warn "Codex 添削実行失敗"
      [ -s "${codex_stderr}" ] && cat "${codex_stderr}" >&2
      fail_count=$((fail_count + 1))
    fi

    rm -f "${codex_stdout}" "${codex_stderr}"
  done

  printf '\n添削完了: 成功 %d 件, 失敗 %d 件\n' "${success_count}" "${fail_count}"
}

main "$@"
