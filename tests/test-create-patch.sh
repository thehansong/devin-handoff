#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
readonly HANDOFF_SCRIPT="$REPO_ROOT/.agents/skills/devin-handoff/scripts/devin-handoff.sh"
readonly TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/devin-handoff-test.XXXXXX")"
readonly MOCK_DIR="$TEST_TMP/mock"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

# Isolate git from the user's config (signing, hooks, default branch, ...).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# Exported function replaces curl in the child Bash process that runs
# devin-handoff.sh. Uploads (-F file=@PATH) are copied into $MOCK_DIR/uploads;
# the session-create payload (-d JSON) is saved to $MOCK_DIR/create.json.
curl() {
  local url="${*: -1}" data="" upload=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d) data="$2"; shift 2 ;;
      -F) upload="${2#file=@}"; shift 2 ;;
      *)  shift ;;
    esac
  done

  if [[ -n "$upload" ]]; then
    mkdir -p "$MOCK_DIR/uploads"
    cp "$upload" "$MOCK_DIR/uploads/"
    if [[ "${MOCK_UPLOAD_FAIL:-}" == 1 ]]; then
      printf '{"detail":"boom"}\n500\n'
    elif [[ "$url" == */v1/* ]]; then
      printf '"https://files.example/%s"\n200\n' "$(basename "$upload")"
    else
      printf '{"attachment_id":"att-1","name":"%s","url":"https://files.example/%s"}\n200\n' \
        "$(basename "$upload")" "$(basename "$upload")"
    fi
  else
    printf '%s' "$data" >"$MOCK_DIR/create.json"
    printf '{"session_id":"devin-abc","url":"https://app.devin.ai/sessions/abc"}\n200\n'
  fi
}

export -f curl
export MOCK_DIR

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [[ "$actual" == "$expected" ]] || fail "$message (expected=$expected actual=$actual)"
}

assert_contains() {
  local value="$1" expected="$2" message="$3"
  [[ "$value" == *"$expected"* ]] || fail "$message"
}

assert_not_contains() {
  local value="$1" unexpected="$2" message="$3"
  [[ "$value" != *"$unexpected"* ]] || fail "$message"
}

# Tree hash of a working directory as git would commit it, including untracked
# files, computed without touching the real index.
worktree_tree() {
  local dir="$1" idx="$TEST_TMP/tree-index"
  rm -f "$idx"
  (cd "$dir" && GIT_INDEX_FILE="$idx" git add -A && GIT_INDEX_FILE="$idx" git write-tree)
}

# A remote with one pushed commit, and a clone with local work on top of it:
# an unpushed commit, a staged edit, an unstaged edit, an untracked text file,
# an untracked binary file and an ignored file.
setup_repos() {
  rm -rf "$TEST_TMP/remote.git" "$TEST_TMP/seed" "$TEST_TMP/local" "$MOCK_DIR"
  mkdir -p "$MOCK_DIR"
  git init -q --bare -b main "$TEST_TMP/remote.git"
  git init -q -b main "$TEST_TMP/seed"
  (
    cd "$TEST_TMP/seed"
    printf 'one\n' >a.txt
    printf 'two\n' >b.txt
    printf 'secret.env\n' >.gitignore
    git add -A && git commit -qm "pushed"
    git remote add origin "$TEST_TMP/remote.git"
    git push -q origin main
  )
  git clone -q "$TEST_TMP/remote.git" "$TEST_TMP/local"
  (
    cd "$TEST_TMP/local"
    printf 'one\nunpushed\n' >a.txt
    git commit -qam "unpushed"
    printf 'two\nstaged\n' >b.txt
    git add b.txt
    printf 'two\nstaged\nunstaged\n' >b.txt
    printf 'new file\n' >untracked.txt
    printf '\x00\x01\x02binary\xff' >image.bin
    printf 'TOKEN=hunter2\n' >secret.env
  )
}

run_create() {
  local key="$1"; shift
  set +e
  RUN_OUTPUT=$(
    cd "$TEST_TMP/local" &&
    DEVIN_API_KEY="$key" DEVIN_ORG_ID=org-test \
      "$HANDOFF_SCRIPT" create --task "Continue my work" "$@" 2>&1
  )
  RUN_RC=$?
  set -e
  CREATE_JSON=$(cat "$MOCK_DIR/create.json" 2>/dev/null || echo '{}')
  PROMPT=$(echo "$CREATE_JSON" | jq -r '.prompt // empty')
}

test_patch_recreates_local_state() {
  setup_repos
  local base expected_tree index_before status_before
  base=$(git -C "$TEST_TMP/local" rev-parse origin/main)
  expected_tree=$(worktree_tree "$TEST_TMP/local")
  index_before=$(git -C "$TEST_TMP/local" ls-files --stage)
  status_before=$(git -C "$TEST_TMP/local" status --porcelain)

  run_create cog_test

  assert_eq 0 "$RUN_RC" "create should succeed: $RUN_OUTPUT"
  local patch="$MOCK_DIR/uploads/handoff-main.patch"
  [[ -f "$patch" ]] || fail "patch should be uploaded as handoff-main.patch"
  assert_contains "$PROMPT" "git checkout $base" "prompt should name the base commit"
  assert_contains "$PROMPT" "git apply --index handoff-main.patch" "prompt should explain how to apply"
  assert_not_contains "$PROMPT" "ATTACHMENT:" "v3 should not use ATTACHMENT lines"
  assert_eq '["https://files.example/handoff-main.patch"]' \
    "$(echo "$CREATE_JSON" | jq -c '.attachment_urls')" "v3 payload should carry attachment_urls"

  assert_eq "$index_before" "$(git -C "$TEST_TMP/local" ls-files --stage)" "real index should be untouched"
  assert_eq "$status_before" "$(git -C "$TEST_TMP/local" status --porcelain)" "working tree status should be untouched"

  # Apply the patch to a fresh clone at the base commit, as Devin would.
  git clone -q "$TEST_TMP/remote.git" "$TEST_TMP/devin"
  (cd "$TEST_TMP/devin" && git checkout -q "$base" && git apply --index "$patch") \
    || fail "patch should apply cleanly on the base commit"
  assert_eq "$expected_tree" "$(worktree_tree "$TEST_TMP/devin")" "applied patch should reproduce the local tree"
  [[ ! -e "$TEST_TMP/devin/secret.env" ]] || fail "ignored files should not be sent"
  rm -rf "$TEST_TMP/devin"
  printf 'ok - patch reproduces local state (v3)\n'
}

test_v1_uses_attachment_lines() {
  setup_repos
  printf 'log line\n' >"$TEST_TMP/build.log"

  run_create apk_test --attach "$TEST_TMP/build.log"

  assert_eq 0 "$RUN_RC" "create should succeed: $RUN_OUTPUT"
  [[ -f "$MOCK_DIR/uploads/build.log" ]] || fail "--attach file should be uploaded"
  assert_contains "$PROMPT" 'ATTACHMENT:"https://files.example/build.log"' "v1 prompt should reference --attach file"
  assert_contains "$PROMPT" 'ATTACHMENT:"https://files.example/handoff-main.patch"' "v1 prompt should reference the patch"
  assert_eq null "$(echo "$CREATE_JSON" | jq -c '.attachment_urls')" "v1 payload should not carry attachment_urls"
  printf 'ok - v1 references attachments in the prompt\n'
}

test_unpushed_branch_uses_default_branch_base() {
  setup_repos
  (cd "$TEST_TMP/local" && git checkout -qb feature/x)
  local base
  base=$(git -C "$TEST_TMP/local" rev-parse origin/main)

  run_create cog_test

  assert_eq 0 "$RUN_RC" "create should succeed: $RUN_OUTPUT"
  [[ -f "$MOCK_DIR/uploads/handoff-feature-x.patch" ]] || fail "patch name should flatten the branch name"
  assert_contains "$PROMPT" "git checkout $base" "unpushed branch should be based on origin's default branch"
  printf 'ok - unpushed branch is based on the default branch\n'
}

test_upload_failure_falls_back_to_inline() {
  setup_repos

  export MOCK_UPLOAD_FAIL=1
  run_create cog_test
  unset MOCK_UPLOAD_FAIL

  assert_eq 0 "$RUN_RC" "create should still succeed: $RUN_OUTPUT"
  assert_contains "$RUN_OUTPUT" "patch upload failed" "should warn about the failed upload"
  assert_contains "$PROMPT" '```diff' "prompt should fall back to an inline diff"
  assert_not_contains "$PROMPT" "git apply" "prompt should not mention the patch"
  assert_eq null "$(echo "$CREATE_JSON" | jq -c '.attachment_urls')" "no attachment_urls without uploads"
  printf 'ok - upload failure falls back to an inline diff\n'
}

test_no_diff_sends_nothing() {
  setup_repos

  run_create cog_test --no-diff

  assert_eq 0 "$RUN_RC" "create should succeed: $RUN_OUTPUT"
  [[ ! -d "$MOCK_DIR/uploads" ]] || fail "--no-diff should not upload anything"
  assert_not_contains "$PROMPT" '```diff' "--no-diff should not inline a diff"
  assert_not_contains "$PROMPT" "git apply" "--no-diff should not mention a patch"
  printf 'ok - --no-diff sends no local changes\n'
}

test_inline_diff_keeps_old_behaviour() {
  setup_repos

  run_create cog_test --inline-diff

  assert_eq 0 "$RUN_RC" "create should succeed: $RUN_OUTPUT"
  [[ ! -d "$MOCK_DIR/uploads" ]] || fail "--inline-diff should not upload anything"
  assert_contains "$PROMPT" '+unstaged' "--inline-diff should include uncommitted changes"
  printf 'ok - --inline-diff keeps the old behaviour\n'
}

test_patch_recreates_local_state
test_v1_uses_attachment_lines
test_unpushed_branch_uses_default_branch_base
test_upload_failure_falls_back_to_inline
test_no_diff_sends_nothing
test_inline_diff_keeps_old_behaviour

printf 'all create patch tests passed\n'
