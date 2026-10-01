#!/usr/bin/env bash
#
# devin-handoff.sh — Hand off a task to a cloud Devin session.
#
# Usage:
#   devin-handoff.sh create --task TASK [--context CONTEXT] [--tag TAG] [--attach FILE] [--api-url URL]
#   devin-handoff.sh poll SESSION_ID [--interval SECS] [--api-url URL]
#   devin-handoff.sh archive SESSION_ID [--api-url URL] [--org-id ORG]
#   devin-handoff.sh --help
#   devin-handoff.sh --version
#
# Requires: curl, jq, git (optional, for auto-context)
# Environment: DEVIN_API_KEY must be set.

set -euo pipefail

readonly VERSION="1.4.0"
readonly MAX_DIFF_BYTES=102400      # 100KB, inline diff fallback
readonly MAX_PATCH_BYTES=10485760   # 10MB, uploaded patch
readonly DEFAULT_POLL_INTERVAL=30

PATCH_DIR=""  # temp dir for the uploaded patch; removed on exit

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { echo "error: $*" >&2; exit 1; }

cleanup() { [[ -z "$PATCH_DIR" ]] || rm -rf "$PATCH_DIR"; }

usage() {
  cat <<EOF
Usage:
  devin-handoff.sh create --task TASK [OPTIONS]
  devin-handoff.sh poll SESSION_ID [OPTIONS]
  devin-handoff.sh archive SESSION_ID [OPTIONS]

Commands:
  create    Create a Devin session and print the session URL
  poll      Poll a session until it finishes or is waiting on a message from you
  archive   Archive a completed session

create options:
  --task      Task description for Devin (required)
  --context   Additional context (files examined, findings, partial fixes)
  --tag       Extra tag (in addition to the default "handoff" tag)
  --attach    Upload a file (image, PDF, log, ...) for Devin; repeatable
  --no-diff   Don't send any local changes
  --inline-diff
              Send uncommitted changes inline in the prompt (git diff HEAD,
              100KB max) instead of uploading a patch
  --api-url   Devin API base URL (default: https://api.devin.ai)
  --org-id    Organization ID (required for service keys)
  --user-id   Create session as this user (service keys only)

  By default, local work (unpushed commits, uncommitted changes and untracked,
  non-ignored files) is uploaded as a .patch attachment Devin can git apply.

poll options:
  --interval  Polling interval in seconds (default: 30)
  --archive   Archive the session when it finishes
  --api-url   Devin API base URL (default: https://api.devin.ai)
  --org-id    Organization ID (required for service keys)

archive options:
  --api-url   Devin API base URL (default: https://api.devin.ai)
  --org-id    Organization ID (required for service keys)

Global:
  --help      Show this help message
  --version   Show version

Environment:
  DEVIN_API_KEY   Required. Personal (apk_*) or service (cog_*) key.
  DEVIN_ORG_ID    Optional. Organization ID for service keys.
  DEVIN_USER_ID   Optional. User ID for service keys.

Examples:
  devin-handoff.sh create --task "Fix the auth timeout bug"

  devin-handoff.sh create \\
    --task "Add rate limiting to /api/users" \\
    --context "Investigated src/api/users.py. No rate limiting exists."

  devin-handoff.sh create --task "Match this mockup" --attach mockup.png

  devin-handoff.sh poll devin-abc123 --interval 15

  devin-handoff.sh archive devin-abc123
EOF
  exit 0
}

check_deps() {
  for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not found."
  done
}

# Resolve the API endpoint base for the current key type.
# Sets $endpoint_base to either v1 or v3 prefix.
resolve_api_base() {
  local api_url="$1" org_id="$2"
  if [[ "$DEVIN_API_KEY" == cog_* ]]; then
    [[ -z "$org_id" ]] && die "--org-id (or DEVIN_ORG_ID) is required for service keys (cog_*)"
    echo "$api_url/v3/organizations/$org_id"
  else
    echo "$api_url/v1"
  fi
}

# Make an API request; prints body, returns non-zero on HTTP error.
api_request() {
  local method="$1" url="$2" data="${3:-}"
  local response http_code body curl_args=(-s -w $'\n%{http_code}' -X "$method"
    -H "Authorization: Bearer $DEVIN_API_KEY"
    -H "Content-Type: application/json")
  [[ -n "$data" ]] && curl_args+=(-d "$data")

  response=$(curl "${curl_args[@]}" "$url")
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    local err_msg
    err_msg=$(echo "$body" | jq -r '.detail // .message // .error // "Unknown error"' 2>/dev/null || echo "$body")
    die "API returned HTTP $http_code: $err_msg"
  fi
  echo "$body"
}

# ---------------------------------------------------------------------------
# Git context gathering
# ---------------------------------------------------------------------------

get_repo_slug() {
  local remote
  remote=$(git remote get-url origin 2>/dev/null) || return 1
  echo "$remote" \
    | sed -E 's#^(ssh://)?git@[^:/]+[:/]##' \
    | sed -E 's#^https?://[^/]+/##' \
    | sed -E 's/\.git$//'
}

get_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""
}

get_diff() {
  local diff
  diff=$(git diff HEAD 2>/dev/null | head -c "$((MAX_DIFF_BYTES + 1))") || true
  if (( $(printf '%s' "$diff" | wc -c) > MAX_DIFF_BYTES )); then
    diff=$(printf '%s' "$diff" | head -c "$MAX_DIFF_BYTES")
    diff+=$'\n'"[diff truncated at $((MAX_DIFF_BYTES / 1024))KB]"
  fi
  printf '%s' "$diff"
}

# The newest commit Devin can see: where HEAD meets its upstream, or the
# remote's default branch when the branch was never pushed. Falls back to HEAD.
get_base_commit() {
  local upstream default_ref
  if upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
    git merge-base HEAD "$upstream" 2>/dev/null && return 0
  fi
  if default_ref=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null); then
    git merge-base HEAD "$default_ref" 2>/dev/null && return 0
  fi
  git rev-parse HEAD 2>/dev/null
}

# Write a binary-safe patch from BASE to the working tree, including untracked
# (non-ignored) files. Stages into a temporary index so the user's index is
# left untouched. Returns non-zero if there are no changes.
build_patch() {
  local base="$1" out="$2" real_index tmp_index
  real_index=$(git rev-parse --git-path index)
  tmp_index="$out.index"
  [[ -f "$real_index" ]] && cp "$real_index" "$tmp_index"
  GIT_INDEX_FILE="$tmp_index" git add -A >/dev/null 2>&1 || return 1
  GIT_INDEX_FILE="$tmp_index" git diff --cached --binary "$base" >"$out" || return 1
  rm -f "$tmp_index"
  [[ -s "$out" ]]
}

# Upload a file as a Devin attachment; prints its URL. Uses curl directly
# because api_request only speaks JSON and dies on failure.
upload_attachment() {
  local base="$1" file="$2" response http_code body url
  response=$(curl -s -w $'\n%{http_code}' -X POST \
    -H "Authorization: Bearer $DEVIN_API_KEY" \
    -F "file=@$file" "$base/attachments") || { echo "upload of $file failed: curl error" >&2; return 1; }
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')
  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "upload of $file failed: HTTP $http_code" >&2
    return 1
  fi
  # v3 returns {attachment_id, name, url}; v1 returns the URL as a string
  url=$(echo "$body" | jq -r 'if type == "object" then .url // empty else . end' 2>/dev/null) || url="$body"
  [[ "$url" == http* ]] || { echo "upload of $file failed: no URL in response" >&2; return 1; }
  echo "$url"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_create() {
  local task="" context="" extra_tag="" api_url="${DEVIN_API_URL:-https://api.devin.ai}" org_id="${DEVIN_ORG_ID:-}" user_id="${DEVIN_USER_ID:-}"
  local diff_mode="patch" attach_files=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task)    task="$2"; shift 2 ;;
      --context) context="$2"; shift 2 ;;
      --tag)     extra_tag="$2"; shift 2 ;;
      --attach)  [[ -f "$2" ]] || die "--attach: file not found: $2"
                 attach_files+="$2"$'\n'; shift 2 ;;
      --no-diff) diff_mode="none"; shift ;;
      --inline-diff) diff_mode="inline"; shift ;;
      --api-url) api_url="$2"; shift 2 ;;
      --org-id)  org_id="$2"; shift 2 ;;
      --user-id) user_id="$2"; shift 2 ;;
      *)         die "Unknown option: $1 (see --help)" ;;
    esac
  done

  [[ -z "$task" ]] && die "--task is required"
  [[ -z "${DEVIN_API_KEY:-}" ]] && die "DEVIN_API_KEY is not set. Get a key at https://app.devin.ai/settings/api-keys"
  check_deps

  local base
  base=$(resolve_api_base "$api_url" "$org_id")

  # Gather git context (best-effort)
  local repo="" branch="" diff="" base_sha="" patch_file=""
  if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    repo=$(get_repo_slug || echo "")
    branch=$(get_branch)
    if [[ "$diff_mode" == "patch" ]] && base_sha=$(get_base_commit); then
      PATCH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/devin-handoff.XXXXXX")
      trap cleanup EXIT
      patch_file="$PATCH_DIR/handoff-$(echo "${branch:-local}" | tr '/' '-').patch"
      build_patch "$base_sha" "$patch_file" || patch_file=""
    elif [[ "$diff_mode" == "inline" ]]; then
      diff=$(get_diff)
    fi
  fi

  # Upload attachments. URLs are newline-separated (bash 3.2 has no safe empty arrays).
  local attachment_urls="" url f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    url=$(upload_attachment "$base" "$f") || die "could not upload $f"
    attachment_urls+="$url"$'\n'
  done <<<"$attach_files"

  local patch_name="" patch_stat=""
  if [[ -n "$patch_file" ]]; then
    if (( $(wc -c <"$patch_file") > MAX_PATCH_BYTES )); then
      echo "Warning: patch is over $((MAX_PATCH_BYTES / 1048576))MB; sending an inline diff instead." >&2
      diff=$(get_diff)
    elif url=$(upload_attachment "$base" "$patch_file"); then
      attachment_urls+="$url"$'\n'
      patch_name=$(basename "$patch_file")
      patch_stat=$(git apply --stat "$patch_file" 2>/dev/null || true)
      echo "Attached local changes as $patch_name" >&2
    else
      echo "Warning: patch upload failed; sending an inline diff instead." >&2
      diff=$(get_diff)
    fi
  fi

  # Build prompt
  local prompt="$task"
  local details=""
  [[ -n "$repo" ]]    && details+="Repo: $repo"$'\n'
  [[ -n "$branch" ]]  && details+="Branch: $branch"$'\n'
  [[ -n "$context" ]] && details+=$'\n'"$context"$'\n'

  if [[ -n "$details" ]]; then
    prompt+=$'\n\n'"<details>"$'\n'"<summary>Context from local environment</summary>"$'\n\n'
    prompt+="$details"
    prompt+=$'\n'"</details>"
  fi

  if [[ -n "$patch_name" ]]; then
    prompt+=$'\n\n'"<details>"$'\n'"<summary>Local changes (attached patch)</summary>"$'\n\n'
    prompt+="My local work is attached as \`$patch_name\`: every unpushed commit, uncommitted change and untracked file since commit \`$base_sha\`. Recreate my local state before starting:"$'\n\n'
    prompt+='```bash'$'\n'"git checkout $base_sha"$'\n'"git apply --index $patch_name"$'\n''```'$'\n\n'
    prompt+="Then create a new branch from there for your work."$'\n'
    [[ -n "$patch_stat" ]] && prompt+=$'\n''```'$'\n'"$patch_stat"$'\n''```'$'\n'
    prompt+=$'\n'"</details>"
  fi

  if [[ -n "$diff" ]]; then
    prompt+=$'\n\n'"<details>"$'\n'"<summary>Uncommitted local changes (diff)</summary>"$'\n\n'
    prompt+='```diff'$'\n'"$diff"$'\n''```'$'\n\n'
    prompt+="</details>"
  fi

  # v1 only recognizes attachments as standalone ATTACHMENT:"url" lines in the
  # prompt; v3 takes them in the attachment_urls field below.
  if [[ -n "$attachment_urls" && "$DEVIN_API_KEY" != cog_* ]]; then
    prompt+=$'\n'
    while IFS= read -r url; do
      [[ -n "$url" ]] && prompt+=$'\n'"ATTACHMENT:\"$url\""
    done <<<"$attachment_urls"
  fi

  # Build tags array: always include "handoff", plus optional extra tag
  local tags_expr='["handoff"]'
  if [[ -n "$extra_tag" && "$extra_tag" != "handoff" ]]; then
    # shellcheck disable=SC2016
    tags_expr='["handoff", $extra_tag]'
  fi

  # Build JSON payload
  local json
  local jq_args=(--arg title "${task:0:100}")
  [[ -n "$extra_tag" && "$extra_tag" != "handoff" ]] && jq_args+=(--arg extra_tag "$extra_tag")
  if [[ -n "$user_id" && "$DEVIN_API_KEY" == cog_* ]]; then
    jq_args+=(--arg uid "$user_id")
    json=$(printf '%s' "$prompt" | jq -Rs "${jq_args[@]}" \
      '{prompt: ., title: $title, tags: '"$tags_expr"', create_as_user_id: $uid}')
  else
    json=$(printf '%s' "$prompt" | jq -Rs "${jq_args[@]}" \
      '{prompt: ., title: $title, tags: '"$tags_expr"'}')
  fi

  if [[ -n "$attachment_urls" && "$DEVIN_API_KEY" == cog_* ]]; then
    json=$(printf '%s' "$attachment_urls" | jq -R . | jq -s --argjson payload "$json" \
      '$payload + {attachment_urls: map(select(. != ""))}')
  fi

  local body
  body=$(api_request POST "$base/sessions" "$json")

  local session_url session_id
  session_url=$(echo "$body" | jq -r '.url // empty')
  session_id=$(echo "$body" | jq -r '.session_id // empty')

  if [[ -z "$session_url" ]]; then
    if [[ -n "$session_id" ]]; then
      session_url="https://app.devin.ai/sessions/${session_id#devin-}"
    else
      die "No session URL or ID in response: $body"
    fi
  fi

  echo "$session_url"
  echo ""
  echo "To poll until completion:"
  echo "  devin-handoff.sh poll $session_id --api-url $api_url${org_id:+ --org-id $org_id}"
}

cmd_poll() {
  local session_id="${1:-}"; shift || true
  local interval="$DEFAULT_POLL_INTERVAL" api_url="${DEVIN_API_URL:-https://api.devin.ai}" org_id="${DEVIN_ORG_ID:-}" do_archive=false

  [[ -z "$session_id" ]] && die "poll requires a SESSION_ID argument"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --interval) interval="$2"; shift 2 ;;
      --archive)  do_archive=true; shift ;;
      --api-url)  api_url="$2"; shift 2 ;;
      --org-id)   org_id="$2"; shift 2 ;;
      *)          die "Unknown option: $1 (see --help)" ;;
    esac
  done

  if [[ "$do_archive" == true && -z "$org_id" ]]; then
    die "--org-id (or DEVIN_ORG_ID) is required when using --archive"
  fi

  [[ -z "${DEVIN_API_KEY:-}" ]] && die "DEVIN_API_KEY is not set."
  check_deps

  # Normalize session_id
  [[ "$session_id" != devin-* ]] && session_id="devin-$session_id"

  local base
  base=$(resolve_api_base "$api_url" "$org_id")

  echo "Polling $session_id every ${interval}s..." >&2

  while true; do
    local body status status_detail
    body=$(api_request GET "$base/sessions/$session_id")
    status=$(echo "$body" | jq -r '.status // "unknown"')

    # v3 returns status_detail, v1 returns just status
    status_detail=$(echo "$body" | jq -r '.status_detail // empty')

    echo "[$(date +%H:%M:%S)] status=$status${status_detail:+ detail=$status_detail}" >&2

    # Terminal conditions. Top-level failure states take precedence over status
    # details. waiting_for_user and finished both mean Devin has stopped working;
    # for a handoff they count as done, so stop polling instead of waiting for the
    # VM to exit or suspend.
    local terminal_rc=""
    if [[ "$status" == "error" || "$status" == "suspended" ]]; then
      terminal_rc=1
    elif [[ "$status" == "exit" || "$status_detail" == "waiting_for_user" \
            || "$status_detail" == "finished" ]]; then
      terminal_rc=0
    fi

    if [[ -n "$terminal_rc" ]]; then
      local pr_url title
      title=$(echo "$body" | jq -r '.title // empty')
      # v1 nests PR under pull_request.url; v3 under pull_requests[0].url
      pr_url=$(echo "$body" | jq -r '(.pull_request.url // .pull_requests[0].url) // empty' 2>/dev/null)

      echo ""
      echo "Session finished: status=$status${status_detail:+ ($status_detail)}"
      [[ -n "$title" ]] && echo "Title: $title"
      [[ -n "$pr_url" ]] && echo "PR: $pr_url"
      echo "$body" | jq -r '.url // empty' | grep -q . && echo "URL: $(echo "$body" | jq -r '.url')"

      # Archive if requested
      if [[ "$do_archive" == true ]]; then
        echo "Archiving session..." >&2
        api_request POST "$api_url/v3/organizations/$org_id/sessions/$session_id/archive" >/dev/null 2>&1 \
          && echo "Archived." >&2 \
          || echo "Warning: archive failed." >&2
      fi

      exit "$terminal_rc"
    fi

    sleep "$interval"
  done
}

cmd_archive() {
  local session_id="${1:-}"; shift || true
  local api_url="${DEVIN_API_URL:-https://api.devin.ai}" org_id="${DEVIN_ORG_ID:-}"

  [[ -z "$session_id" ]] && die "archive requires a SESSION_ID argument"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api-url) api_url="$2"; shift 2 ;;
      --org-id)  org_id="$2"; shift 2 ;;
      *)         die "Unknown option: $1 (see --help)" ;;
    esac
  done

  [[ -z "${DEVIN_API_KEY:-}" ]] && die "DEVIN_API_KEY is not set."
  check_deps

  # Normalize session_id
  [[ "$session_id" != devin-* ]] && session_id="devin-$session_id"

  # Archive is v3-only; require org_id for all key types
  [[ -z "$org_id" ]] && die "--org-id (or DEVIN_ORG_ID) is required for archive"

  local base="$api_url/v3/organizations/$org_id"
  local body
  body=$(api_request POST "$base/sessions/$session_id/archive")

  local title status
  title=$(echo "$body" | jq -r '.title // empty')
  status=$(echo "$body" | jq -r '.status // empty')

  echo "Archived: $session_id"
  [[ -n "$title" ]] && echo "Title: $title"
  [[ -n "$status" ]] && echo "Status: $status"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "${1:-}" in
  --help|-h)    usage ;;
  --version|-v) echo "devin-handoff $VERSION"; exit 0 ;;
  create)       shift; cmd_create "$@" ;;
  poll)         shift; cmd_poll "$@" ;;
  archive)      shift; cmd_archive "$@" ;;
  "")           usage ;;
  *)            die "Unknown command: $1 (see --help)" ;;
esac
