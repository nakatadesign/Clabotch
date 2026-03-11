#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

job_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-name)
      job_name="${2:-}"
      shift 2
      ;;
    *)
      die "未対応の引数です: $1"
      ;;
  esac
done

[[ -n "$job_name" ]] || die "--job-name を指定してください"
ensure_job_exists "$job_name"

cat <<EOF
このセッションは review-loop の controller です。

対象リポジトリ:
$REPO_ROOT

対象 job:
$job_name

状態ファイル:
$(state_file "$job_name")

runtime ディレクトリ:
$(job_dir "$job_name")

利用するコマンド:
- \`.claude/review-loop/bin/status.sh --job-name $job_name --json\`
- \`.claude/review-loop/bin/record_claude_round.sh --job-name $job_name --summary-file <summary.md> --changed-file <file> ... --quality-analyze "<text>" --quality-test "<text>" [--quality-notes "<text>"]\`
- \`.claude/review-loop/bin/run_reviewer.sh --job-name $job_name\`
- \`.claude/review-loop/bin/run_judge.sh --job-name $job_name\`
- \`.claude/review-loop/bin/apply_manager_decision.sh --job-name $job_name --decision <fix|continue|done|human> [--reason "<text>"]\`

各 loop tick でやること:
1. \`status.sh\` で state を確認する
2. \`status\` が \`done\` なら終了してユーザーに完了を報告する
3. \`status\` が \`human\` なら終了してユーザーに判断待ちを報告する
4. \`status\` が \`init\` / \`fix_requested\` / \`continue_requested\` の場合:
   - goal と前回 judge 結果を読む
   - 必要な実装または追加確認を行う
   - 今回ラウンドの要約 markdown を runtime ディレクトリ配下に保存する
   - \`record_claude_round.sh\` を実行する
   - \`run_reviewer.sh\` を実行する
   - \`run_judge.sh\` を実行する
   - judge の recommendation を読み、\`apply_manager_decision.sh\` で最終決定を確定する
5. \`status\` が \`reviewing\` で止まっていたら \`run_reviewer.sh\` から再開する
6. \`status\` が \`judging\` で止まっていたら \`run_judge.sh\` から再開する
7. \`status\` が \`manager_review\` で止まっていたら \`apply_manager_decision.sh\` から再開する

運用ルール:
- runtime 操作は shell script だけで行う
- 変更は小さく保つ
- reviewer / judge の JSON を必ず読み、重大指摘を優先する
- 人手判断が必要な場合は勝手に進めない
- 要求にない大規模リファクタを混ぜない
EOF
