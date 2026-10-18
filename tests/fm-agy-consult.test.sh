#!/usr/bin/env bash
# Behavior tests for bin/fm-agy-consult.sh (the Antigravity CLI tmux consultation helper).
#
# Pins the consultation lane mechanics:
#   1. Starts a named tmux session in the target directory when absent, reuses
#      it when present, and kills+restarts it when --fresh is passed.
#   2. Collapses multi-line prompts (from --prompt, --prompt-file, or positional
#      args) into a single line before `tmux send-keys -l` + `Enter`.
#   3. Applies the default `read-only` permission policy (prepending the
#      read-only directive and never passing --dangerously-skip-permissions),
#      allows `--policy prompt-as-is` without the prefix, and refuses
#      unsupported auto-approval policies.
#   4. Accepts the initial folder-trust dialog ("Do you trust the contents of
#      this project?") with a single Enter, but never auto-approves per-command
#      permission prompts and fails closed if a turn parks on one.
#   5. Passes verified --model and --effort values through to `agy` at session
#      launch and refuses unverified or bare model IDs before touching tmux.
#   6. Waits for `esc to cancel` to settle to `? for shortcuts` (or
#      --settle-polls consecutive identical post-send idle captures), strips
#      braille spinner lines, deduplicates redraw noise, and writes the result
#      to <data>/agy-reviews/<YYYY-MM-DD>-<topic>.txt.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONSULT="$ROOT/bin/fm-agy-consult.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-consult)

make_consult_stubs() {  # <case-dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb" "$dir/work" "$dir/home/data"
  : > "$dir/tmux.log"
  : > "$dir/sleep.log"

  cat > "$fb/agy" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/agy"

  cat > "$fb/sleep" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${1:-}" >> "$dir/sleep.log"
exit 0
SH
  chmod +x "$fb/sleep"

  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
log="$dir/tmux.log"
cnt_file="$dir/capture.count"
sess_file="$dir/session.alive"
printf '%s\n' "\$*" >> "\$log"

cmd=\${1:-}
shift || true
case "\$cmd" in
  has-session)
    [ -f "\$sess_file" ] && exit 0
    exit 1
    ;;
  new-session)
    : > "\$sess_file"
    exit 0
    ;;
  kill-session)
    rm -f "\$sess_file"
    exit 0
    ;;
  send-keys)
    exit 0
    ;;
  capture-pane)
    n=\$(( \$(cat "\$cnt_file" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "\$n" > "\$cnt_file"
    if [ -f "$dir/capture.\$n" ]; then
      cat "$dir/capture.\$n"
    elif [ -f "$dir/capture.default" ]; then
      cat "$dir/capture.default"
    else
      printf '>\n? for shortcuts\n'
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

run_consult() {  # <case-dir> <args...>
  local dir=$1 fb="$1/fakebin"
  shift
  HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" \
    FM_DATA_OVERRIDE="$dir/home/data" PATH="$fb:$PATH" \
    "$CONSULT" "$@"
}

test_help_documents_usage_policies_caveats_and_models() {
  local out
  out=$("$CONSULT" --help) || fail "--help must exit 0"
  assert_contains "$out" "Usage:" "--help must include Usage section"
  assert_contains "$out" "read-only" "--help must document the read-only default policy"
  assert_contains "$out" "Folder-trust caveat" "--help must document the folder-trust caveat"
  assert_contains "$out" "Per-command approval caveat" "--help must document the per-command approval caveat"
  assert_contains "$out" "gemini-3.8-flash-high" "--help must list verified Flash High model id"
  assert_contains "$out" "gemini-4-argon-high" "--help must list verified Argon High model id"
  pass "fm-agy-consult.sh: --help documents usage, permission policy, caveats, and verified models"
}

test_fresh_session_launch_single_line_readonly_and_dedupe() {
  local dir fb out log_file content
  dir="$TMP_ROOT/case-launch"
  fb=$(make_consult_stubs "$dir")
  [ -d "$fb" ] || fail "fakebin was not created"

  cat > "$dir/capture.1" <<'EOF'
>
? for shortcuts                                          Gemini 3.8 Flash · high
EOF
  cat > "$dir/capture.2" <<'EOF'
> Read-only consultation
⣯  Generating...
⡿  Focusing on plan
⡿  Focusing on plan
esc to cancel                                            Gemini 3.8 Flash · high
EOF
  cat > "$dir/capture.3" <<'EOF'
> Read-only consultation
⣯  Generating...
⡿  Focusing on plan
● Explored 2 files (plan.md, backlog.md)
● Explored 2 files (plan.md, backlog.md)
  ### Critique Summary
  1. Tighten the holdout gate.
  1. Tighten the holdout gate.
  2. Collapse duplicate slice.
>
? for shortcuts                                          Gemini 3.8 Flash · high
EOF

  out=$(run_consult "$dir" --dir "$dir/work" --date 2026-10-18 --topic pilot-critique \
    --prompt $'Review this plan.\nSecond line\twith tabs.') || fail "consult run failed"

  log_file="$dir/home/data/agy-reviews/2026-10-18-pilot-critique.txt"
  [ -f "$log_file" ] || fail "expected review log at $log_file"
  assert_contains "$out" "saved: $log_file" "stdout must report the saved log path"

  assert_grep "new-session -d -s agy -c $dir/work agy" "$dir/tmux.log" \
    "expected tmux new-session in target dir with bare agy"
  assert_grep "send-keys -t agy -l Read-only consultation (do not modify, create, or delete any file, and do not run state-changing commands): Review this plan. Second line with tabs." \
    "$dir/tmux.log" "prompt must be prefixed with read-only policy and collapsed to one line"
  assert_grep "send-keys -t agy Enter" "$dir/tmux.log" \
    "expected Enter send after literal prompt"

  content=$(cat "$log_file")
  assert_contains "$content" "### Critique Summary" "deduped log must keep the answer heading"
  assert_contains "$content" "1. Tighten the holdout gate." "deduped log must keep bullet 1"
  assert_contains "$content" "2. Collapse duplicate slice." "deduped log must keep bullet 2"
  assert_not_contains "$content" "Generating..." "deduped log must strip braille spinner lines"
  assert_not_contains "$content" "Focusing on plan" "deduped log must strip braille thinking ticker lines"
  [ "$(grep -c '1\. Tighten the holdout gate\.' "$log_file")" -eq 1 ] \
    || fail "duplicate redraw line was not deduplicated"
  [ "$(grep -c 'Explored 2 files' "$log_file")" -eq 1 ] \
    || fail "duplicate tool summary line was not deduplicated"
  pass "fm-agy-consult.sh: launches session, normalizes single-line read-only prompt, waits for settle, and deduplicates output"
}

test_session_reuse_and_fresh_restart() {
  local dir out
  dir="$TMP_ROOT/case-reuse"
  make_consult_stubs "$dir" >/dev/null
  : > "$dir/session.alive"

  cat > "$dir/capture.1" <<'EOF'
>
? for shortcuts
EOF
  cat > "$dir/capture.2" <<'EOF'
esc to cancel
EOF
  cat > "$dir/capture.3" <<'EOF'
  Reused session answer.
>
? for shortcuts
EOF

  out=$(run_consult "$dir" --dir "$dir/work" --date 2026-10-18 --topic reuse-check --quiet "Quick question") \
    || fail "reuse consult failed"
  [ "$out" = "$dir/home/data/agy-reviews/2026-10-18-reuse-check.txt" ] \
    || fail "--quiet must print only the output path, got '$out'"
  grep -q '^new-session ' "$dir/tmux.log" && fail "reused session must not call new-session"
  grep -q '^kill-session ' "$dir/tmux.log" && fail "reused session without --fresh must not call kill-session"

  : > "$dir/tmux.log"
  rm -f "$dir/capture.count"
  out=$(run_consult "$dir" --dir "$dir/work" --fresh --model gemini-4-argon-high --effort high \
    --date 2026-10-18 --topic fresh-check --quiet "Fresh question") \
    || fail "--fresh consult failed"
  assert_grep "kill-session -t agy" "$dir/tmux.log" "--fresh must kill the existing session"
  assert_grep "new-session -d -s agy -c $dir/work agy --model gemini-4-argon-high --effort high" \
    "$dir/tmux.log" "--fresh must relaunch with --model and --effort"
  pass "fm-agy-consult.sh: reuses existing session by default and restarts cleanly with --fresh"
}

test_folder_trust_dialog_is_accepted_once() {
  local dir enters
  dir="$TMP_ROOT/case-trust"
  make_consult_stubs "$dir" >/dev/null

  cat > "$dir/capture.1" <<'EOF'
Accessing workspace:
Do you trust the contents of this project?
> Yes, I trust this folder
  No, exit
EOF
  cat > "$dir/capture.2" <<'EOF'
>
? for shortcuts
EOF
  cat > "$dir/capture.3" <<'EOF'
esc to cancel
EOF
  cat > "$dir/capture.4" <<'EOF'
  Trusted folder answer.
>
? for shortcuts
EOF

  run_consult "$dir" --dir "$dir/work" --date 2026-10-18 --topic trust-check --quiet "Inspect files" >/dev/null \
    || fail "consult with folder-trust dialog failed"
  enters=$(grep -c '^send-keys -t agy Enter$' "$dir/tmux.log" || true)
  [ "$enters" -eq 2 ] \
    || fail "expected 1 Enter for folder trust + 1 Enter for prompt submit, got $enters"
  pass "fm-agy-consult.sh: accepts the initial folder-trust dialog with one Enter before sending the prompt"
}

test_model_and_policy_validation_and_passthrough() {
  local dir rc out
  dir="$TMP_ROOT/case-validate"
  make_consult_stubs "$dir" >/dev/null

  rc=0
  out=$(run_consult "$dir" --topic bad-model --model gemini-3.8-flash "Question" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "bare unverified model id must be refused"
  assert_contains "$out" "unverified agy model 'gemini-3.8-flash'" \
    "refusal must name the unverified model id"
  [ ! -s "$dir/tmux.log" ] || fail "unverified model must fail before touching tmux"

  rc=0
  out=$(run_consult "$dir" --topic bad-policy --policy bypass "Question" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unsupported bypass policy must be refused"
  assert_contains "$out" "unsupported permission policy 'bypass'" \
    "refusal must name the unsupported policy"

  cat > "$dir/capture.1" <<'EOF'
>
? for shortcuts
EOF
  cat > "$dir/capture.2" <<'EOF'
esc to cancel
EOF
  cat > "$dir/capture.3" <<'EOF'
  Raw prompt answer.
>
? for shortcuts
EOF

  printf 'Multi-line\nprompt from file\n' > "$dir/prompt.txt"
  run_consult "$dir" --dir "$dir/work" --date 2026-10-18 --topic 2026-10-18-raw-policy.txt \
    --policy prompt-as-is --model gemini-3.8-flash-high \
    --prompt-file "$dir/prompt.txt" --quiet >/dev/null \
    || fail "consult with --policy prompt-as-is and --prompt-file failed"

  [ -f "$dir/home/data/agy-reviews/2026-10-18-raw-policy.txt" ] \
    || fail "topic normalization must not double the date prefix or .txt suffix"
  assert_grep "new-session -d -s agy -c $dir/work agy --model gemini-3.8-flash-high" "$dir/tmux.log" \
    "verified model id must be passed through to agy launch"
  assert_grep "send-keys -t agy -l Multi-line prompt from file" "$dir/tmux.log" \
    "--policy prompt-as-is must send the single-line prompt without the read-only prefix"
  grep -q -- '--dangerously-skip-permissions' "$dir/tmux.log" \
    && fail "helper must never pass --dangerously-skip-permissions"
  pass "fm-agy-consult.sh: validates --model and --policy, supports --prompt-file, and never skips permissions"
}

test_per_command_approval_and_busy_session_fail_closed() {
  local dir rc out enters
  dir="$TMP_ROOT/case-approval"
  make_consult_stubs "$dir" >/dev/null

  cat > "$dir/capture.1" <<'EOF'
>
? for shortcuts
EOF
  cat > "$dir/capture.default" <<'EOF'
Allow Antigravity CLI to run shell command `rm -rf build`?
  Yes
  No
EOF

  rc=0
  out=$(run_consult "$dir" --date 2026-10-18 --topic approval-park \
    --timeout 4 --poll-interval 2 "Check build" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a turn parked on per-command approval must fail closed"
  assert_contains "$out" "per-command approval prompt" \
    "failure must explain that the consultation parked on a per-command approval prompt"
  enters=$(grep -c '^send-keys -t agy Enter$' "$dir/tmux.log" || true)
  [ "$enters" -eq 1 ] \
    || fail "helper must never send extra Enter keys into a per-command approval prompt (got $enters)"
  [ ! -e "$dir/home/data/agy-reviews/2026-10-18-approval-park.txt" ] \
    || fail "failed consultation must not write an incomplete review file"

  # Busy session refusal when reusing an already-running turn without --fresh.
  : > "$dir/tmux.log"
  rm -f "$dir/capture.count"
  cat > "$dir/capture.1" <<'EOF'
⣯  Generating...
esc to cancel
EOF
  rc=0
  out=$(run_consult "$dir" --date 2026-10-18 --topic busy-refuse "Another question" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "reusing a session that is already busy must be refused"
  assert_contains "$out" "already busy (esc to cancel)" \
    "busy session refusal must name the active turn"
  grep -q 'send-keys' "$dir/tmux.log" \
    && fail "busy session refusal must not inject keys into the active turn"
  pass "fm-agy-consult.sh: fails closed on per-command approval prompts and refuses busy session collision"
}

test_settle_without_observed_busy_frame() {
  local dir
  dir="$TMP_ROOT/case-fast-settle"
  make_consult_stubs "$dir" >/dev/null

  cat > "$dir/capture.1" <<'EOF'
>
? for shortcuts
EOF
  cat > "$dir/capture.2" <<'EOF'
> Read-only consultation
  Fast answer settled between polls.
>
? for shortcuts
EOF
  cat > "$dir/capture.3" <<'EOF'
> Read-only consultation
  Fast answer settled between polls.
>
? for shortcuts
EOF

  run_consult "$dir" --date 2026-10-18 --topic fast-settle --settle-polls 2 --quiet "Fast question" >/dev/null \
    || fail "fast-settling consultation should succeed after --settle-polls identical idle reads"
  assert_contains "$(cat "$dir/home/data/agy-reviews/2026-10-18-fast-settle.txt")" \
    "Fast answer settled between polls." "fast-settled answer must be written to the review log"
  pass "fm-agy-consult.sh: settles cleanly when a fast turn completes between polls"
}

test_late_busy_and_reused_model_mismatch() {
  local dir rc out
  dir="$TMP_ROOT/case-late-busy"
  make_consult_stubs "$dir" >/dev/null

  # Polls 1 and 2 after send-keys show the submitted prompt in the composer
  # with ? for shortcuts and no empty '>' composer row yet (the 4s late-busy
  # window); poll 3 shows esc to cancel; poll 4 shows the completed answer.
  cat > "$dir/capture.1" <<'EOF'
>
? for shortcuts                                          Gemini 3.8 Flash · high
EOF
  cat > "$dir/capture.2" <<'EOF'
> Read-only consultation: Long brief
? for shortcuts                                          Gemini 3.8 Flash · high
EOF
  cat > "$dir/capture.3" <<'EOF'
> Read-only consultation: Long brief
? for shortcuts                                          Gemini 3.8 Flash · high
EOF
  cat > "$dir/capture.4" <<'EOF'
> Read-only consultation: Long brief
esc to cancel                                            Gemini 3.8 Flash · high
EOF
  cat > "$dir/capture.5" <<'EOF'
> Read-only consultation: Long brief
  Completed answer after late busy render.
>
? for shortcuts                                          Gemini 3.8 Flash · high
EOF

  run_consult "$dir" --date 2026-10-18 --topic late-busy --settle-polls 2 --quiet "Long brief" >/dev/null \
    || fail "late-busy consultation should wait for the real turn completion"
  assert_contains "$(cat "$dir/home/data/agy-reviews/2026-10-18-late-busy.txt")" \
    "Completed answer after late busy render." \
    "late-busy consultation settled prematurely before the answer rendered"

  # Reusing an existing Flash session with --model gemini-4-argon-high without --fresh must refuse.
  rm -f "$dir/capture.count"
  cat > "$dir/capture.1" <<'EOF'
>
? for shortcuts                                          Gemini 3.8 Flash · high
EOF
  rc=0
  out=$(run_consult "$dir" --date 2026-10-18 --topic model-conflict \
    --model gemini-4-argon-high "Argon question" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "reusing a Flash session with --model gemini-4-argon-high without --fresh must refuse"
  assert_contains "$out" "running a different model than requested 'gemini-4-argon-high'; pass --fresh" \
    "model-mismatch refusal must instruct the caller to pass --fresh"

  # Path-traversal topic slug must be refused.
  rc=0
  out=$(run_consult "$dir" --topic "../escape" "Question" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "path-traversal --topic must be refused"
  assert_contains "$out" "invalid --topic" "unsafe topic refusal must name --topic"
  pass "fm-agy-consult.sh: waits through late-busy delay, refuses reused model mismatch without --fresh, and rejects unsafe topics"
}

test_help_documents_usage_policies_caveats_and_models
test_fresh_session_launch_single_line_readonly_and_dedupe
test_session_reuse_and_fresh_restart
test_folder_trust_dialog_is_accepted_once
test_model_and_policy_validation_and_passthrough
test_per_command_approval_and_busy_session_fail_closed
test_settle_without_observed_busy_frame
test_late_busy_and_reused_model_mismatch

