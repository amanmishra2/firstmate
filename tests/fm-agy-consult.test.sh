#!/usr/bin/env bash
# Behavior tests for bin/fm-agy-consult.sh (the Antigravity CLI tmux consultation helper).
#
# Pins the consultation lane mechanics:
#   1. Starts a named tmux session in the target directory when absent, reuses
#      it when present, and never kills or restarts an existing session.
#   2. Collapses multi-line prompts (from --prompt or --prompt-file) into a
#      single line before `tmux send-keys -l` + `Enter`.
#   3. Applies the default `read-only` permission policy (prepending the
#      read-only directive and never passing --dangerously-skip-permissions),
#      allows `--policy prompt-as-is` without the prefix, and refuses
#      undocumented policy values.
#   4. Refuses untrusted workspaces and folder-trust dialogs without sending
#      Enter, and never auto-approves per-command permission prompts.
#   5. Passes verified --model and --effort values through to `agy` at session
#      launch and refuses unverified or bare model IDs before touching tmux.
#   6. Waits for `esc to cancel` to settle to `? for shortcuts` (or
#      --settle-polls consecutive identical post-send idle captures), requires
#      visible prompt delivery, strips TUI redraw noise, and writes the result
#      to <data>/agy-reviews/<YYYY-MM-DD>-<topic>.txt.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONSULT="$ROOT/bin/fm-agy-consult.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-consult)

make_consult_stubs() {  # <case-dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb" "$dir/work" "$dir/home/data"
  mkdir -p "$dir/home/.gemini/antigravity-cli"
  printf '{"trustedWorkspaces":["%s/work"]}\n' "$dir" \
    > "$dir/home/.gemini/antigravity-cli/settings.json"
  : > "$dir/tmux.log"
  : > "$dir/sleep.log"
  printf '%s\n' "$dir/work" > "$dir/session.path"

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
    while [ "\$#" -gt 0 ]; do
      if [ "\$1" = "-c" ]; then
        shift
        printf '%s\n' "\$1" > "$dir/session.path"
        break
      fi
      shift
    done
    exit 0
    ;;
  kill-session)
    rm -f "\$sess_file"
    exit 0
    ;;
  send-keys)
    exit 0
    ;;
  display-message)
    cat "$dir/session.path"
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
    FM_AGY_REVIEWS_DIR="$dir/redirected" "$CONSULT" --dir "$dir/work" "$@"
}

test_help_documents_usage_policies_caveats_and_models() {
  local out
  out=$("$CONSULT" --help) || fail "--help must exit 0"
  assert_contains "$out" "Usage:" "--help must include Usage section"
  assert_contains "$out" "--prompt <text>" "--help must document the canonical prompt option"
  assert_not_contains "$out" "-t, --topic" "--help must not document a short topic alias"
  assert_not_contains "$out" "--permission-policy" "--help must not document a duplicate policy option"
  assert_contains "$out" "read-only" "--help must document the read-only default policy"
  assert_contains "$out" "trustedWorkspaces" "--help must document trust-store preflight"
  assert_contains "$out" "refused without" "--help must document refusal of trust dialogs"
  assert_not_contains "$out" "--fresh" "--help must not offer a destructive restart option"
  assert_not_contains "$out" "--output-dir" "--help must keep the output directory fixed"
  assert_contains "$out" "Per-command approval caveat" "--help must document the per-command approval caveat"
  assert_contains "$out" "gemini-3.8-flash-high" "--help must list verified Flash High model id"
  assert_contains "$out" "gemini-4-argon-high" "--help must list verified Argon High model id"
  pass "fm-agy-consult.sh: --help documents usage, permission policy, caveats, and verified models"
}

test_fresh_launch_waits_for_ready_composer_and_preserves_answer_lines() {
  local dir fb out log_file content stdout_file ready_capture_line prompt_send_line
  dir="$TMP_ROOT/case-launch"
  fb=$(make_consult_stubs "$dir")
  [ -d "$fb" ] || fail "fakebin was not created"

  cat > "$dir/capture.1" <<'EOF'
Starting Antigravity CLI...
EOF
  cat > "$dir/capture.2" <<'EOF'
>
? for shortcuts                                          Gemini 3.8 Flash · high
EOF
  cat > "$dir/capture.3" <<'EOF'
> Read-only consultation (do not modify, create, or delete any file, and do not run state-changing commands): Review this plan. Second line with tabs.
⣯  Generating...
⡿  Focusing on plan
⡿  Focusing on plan
esc to cancel                                            Gemini 3.8 Flash · high
EOF
  cat > "$dir/capture.4" <<'EOF'
> Read-only consultation (do not modify, create, or delete any file, and do not run state-changing commands): Review this plan. Second line with tabs.
⣯  Generating...
⡿  Focusing on plan
● Explored 2 files (plan.md, backlog.md)
● Explored 2 files (plan.md, backlog.md)
  ### Critique Summary
  1. Tighten the holdout gate.
  1. Tighten the holdout gate.
  2. Collapse duplicate slice.
  ? for shortcuts
  ? for shortcuts indicates help.
  esc to cancel indicates the active-turn footer.
  > marks the composer row.
>
  ⡿ This braille line is answer content.
  ● Explored 2 files (plan.md, backlog.md)
  ● Explored 2 files (plan.md, backlog.md)

  Preserve this separation.


>
? for shortcuts                                          Gemini 3.8 Flash · high
EOF

  stdout_file="$dir/stdout.txt"
  run_consult "$dir" --dir "$dir/work" --date 2026-10-18 --topic pilot-critique \
    --prompt $'Review this plan.\nSecond line\twith tabs.' > "$stdout_file" \
    || fail "consult run failed"
  out=$(cat "$stdout_file")

  log_file="$dir/home/data/agy-reviews/2026-10-18-pilot-critique.txt"
  [ -f "$log_file" ] || fail "expected review log at $log_file"
  assert_contains "$out" "saved: $log_file" "stdout must report the saved log path"

  assert_grep "new-session -d -s agy -c $dir/work agy" "$dir/tmux.log" \
    "expected tmux new-session in target dir with bare agy"
  assert_grep "send-keys -t agy -l Read-only consultation (do not modify, create, or delete any file, and do not run state-changing commands): Review this plan. Second line with tabs." \
    "$dir/tmux.log" "prompt must be prefixed with read-only policy and collapsed to one line"
  assert_grep "send-keys -t agy Enter" "$dir/tmux.log" \
    "expected Enter send after literal prompt"
  ready_capture_line=$(grep -n '^capture-pane ' "$dir/tmux.log" | sed -n '2s/:.*//p')
  prompt_send_line=$(grep -n '^send-keys ' "$dir/tmux.log" | sed -n '1s/:.*//p')
  [ -n "$ready_capture_line" ] && [ -n "$prompt_send_line" ] \
    || fail "expected startup and prompt-send events in tmux log"
  [ "$prompt_send_line" -gt "$ready_capture_line" ] \
    || fail "prompt must not be sent before the ready idle composer capture"

  content=$(cat "$log_file")
  assert_contains "$content" "### Critique Summary" "deduped log must keep the answer heading"
  assert_contains "$content" "1. Tighten the holdout gate." "deduped log must keep bullet 1"
  assert_contains "$content" "2. Collapse duplicate slice." "deduped log must keep bullet 2"
  assert_not_contains "$content" "Generating..." "deduped log must strip the recognized spinner status row"
  assert_not_contains "$content" "Focusing on plan" "deduped log must strip the recognized thinking status row"
  assert_contains "$content" "? for shortcuts indicates help." "answer text resembling the idle footer must be preserved"
  assert_contains "$content" "? for shortcuts" "an exact footer label inside the answer must be preserved"
  assert_contains "$content" "esc to cancel indicates the active-turn footer." "answer text resembling the busy footer must be preserved"
  assert_contains "$content" "> marks the composer row." "answer text resembling the composer must be preserved"
  assert_contains "$content" "⡿ This braille line is answer content." "answer text beginning with a braille glyph must be preserved"
  [ "$(grep -c '^>$' "$log_file")" -eq 1 ] || fail "only the active bottom composer row must be removed"
  [ "$(grep -c '1\. Tighten the holdout gate\.' "$log_file")" -eq 2 ] \
    || fail "repeated answer content must be preserved"
  [ "$(grep -c 'Explored 2 files' "$log_file")" -eq 4 ] \
    || fail "repeated tool-shaped answer content must be preserved"
  assert_contains "$(cat "$log_file")" "Preserve this separation." "answer content after a blank line must be kept"
  [ "$(grep -c '^$' "$log_file")" -eq 3 ] || fail "internal and trailing answer blank lines must be preserved"
  [ "$(grep -c '^$' "$stdout_file")" -eq 3 ] || fail "stdout must preserve answer blank-line structure"
  pass "fm-agy-consult.sh: waits for readiness, verifies prompt delivery, and preserves repeated answer content"
}

test_session_reuse_and_restart_options_are_removed() {
  local dir out rc
  dir="$TMP_ROOT/case-reuse"
  make_consult_stubs "$dir" >/dev/null
  : > "$dir/session.alive"

  cat > "$dir/capture.1" <<'EOF'
Do you trust the contents of this project?
> Yes, I trust this folder
  No, exit
Old transcript after a resolved trust dialog.
Old transcript line 1.
>
? for shortcuts
EOF
  cat > "$dir/capture.2" <<'EOF'
> Quick question
esc to cancel
EOF
  cat > "$dir/capture.3" <<'EOF'
> Quick question
  Reused session answer.
  Reused session answer.
>
? for shortcuts
EOF

  out=$(run_consult "$dir" --date 2026-10-18 --topic reuse-check --policy prompt-as-is --quiet --prompt "Quick question") \
    || fail "reuse consult failed"
  [ "$out" = "$dir/home/data/agy-reviews/2026-10-18-reuse-check.txt" ] \
    || fail "--quiet must print only the output path, got '$out'"
  grep -q '^new-session ' "$dir/tmux.log" && fail "reused session must not call new-session"
  grep -q '^kill-session ' "$dir/tmux.log" && fail "helper must never call kill-session"
  content=$(cat "$dir/home/data/agy-reviews/2026-10-18-reuse-check.txt")
  assert_not_contains "$content" "Old transcript" "reused-session output must exclude earlier scrollback"
  [ "$(grep -c 'Reused session answer\.' "$dir/home/data/agy-reviews/2026-10-18-reuse-check.txt")" -eq 2 ] \
    || fail "repeated answer lines from a reused session must be preserved"

  : > "$dir/tmux.log"
  rm -f "$dir/capture.count"
  rc=0
  out=$(run_consult "$dir" --fresh --date 2026-10-18 --topic fresh-check --quiet --prompt "Fresh question" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "removed --fresh option must be refused"
  assert_contains "$out" "unknown option: --fresh" "removed --fresh must be reported as unknown"
  grep -q 'send-keys\|new-session\|kill-session' "$dir/tmux.log" \
    && fail "removed --fresh must not touch the tmux session"
  rc=0
  out=$(run_consult "$dir" --restart --date 2026-10-18 --topic restart-check --quiet --prompt "Fresh question" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "removed --restart option must be refused"
  assert_contains "$out" "unknown option: --restart" "removed --restart must be reported as unknown"
  grep -q 'send-keys\|new-session\|kill-session' "$dir/tmux.log" \
    && fail "removed --restart must not touch the tmux session"
  rc=0
  out=$(run_consult "$dir" --output-dir "$dir/custom-output" --date 2026-10-18 \
    --topic output-dir-removed --quiet --prompt "Fresh question" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "removed --output-dir option must be refused"
  assert_contains "$out" "unknown option: --output-dir" "removed --output-dir must be reported as unknown"
  grep -q 'send-keys\|new-session\|kill-session' "$dir/tmux.log" \
    && fail "removed --output-dir must be refused before touching tmux"
  pass "fm-agy-consult.sh: reuses trusted sessions, saves only the current turn, and has no restart path"
}

test_trust_dialog_is_refused_without_enter() {
  local dir rc out enters
  dir="$TMP_ROOT/case-trust"
  make_consult_stubs "$dir" >/dev/null

  cat > "$dir/capture.1" <<'EOF'
Accessing workspace:
Earlier status: >
? for shortcuts
Earlier idle footer remains in scrollback.
Do you trust the contents of this project?
> Yes, I trust this folder
  No, exit
EOF
  cat > "$dir/capture.2" <<'EOF'
>
? for shortcuts
EOF

  rc=0
  out=$(run_consult "$dir" --date 2026-10-18 --topic trust-check --quiet --prompt "Inspect files" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "folder-trust dialog must be refused"
  assert_contains "$out" "$dir/work" "folder-trust refusal must name the workspace"
  assert_contains "$out" "bin/fm-agy-trust.sh" "folder-trust refusal must describe the deliberate remedy"
  enters=$(grep -c '^send-keys -t agy Enter$' "$dir/tmux.log" || true)
  [ "$enters" -eq 0 ] || fail "folder-trust refusal must not send Enter (got $enters)"
  grep -q 'send-keys -t agy -l ' "$dir/tmux.log" && fail "prompt must not be sent after a trust dialog"
  [ ! -e "$dir/home/data/agy-reviews/2026-10-18-trust-check.txt" ] \
    || fail "refused trust dialog must not write a review file"
  pass "fm-agy-consult.sh: refuses the folder-trust dialog without sending Enter"
}

test_untrusted_target_and_live_reuse_directory_are_refused() {
  local dir rc out
  dir="$TMP_ROOT/case-untrusted"
  make_consult_stubs "$dir" >/dev/null
  mkdir -p "$dir/untrusted"

  rc=0
  out=$(run_consult "$dir" --dir "$dir/untrusted" --date 2026-10-18 \
    --topic untrusted-target --quiet --prompt "Inspect files" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "untrusted target directory must be refused before launch"
  assert_contains "$out" "$dir/untrusted" "untrusted target refusal must name the directory"
  assert_contains "$out" "trustedWorkspaces" "untrusted target refusal must identify the missing trust entry"
  [ ! -s "$dir/tmux.log" ] || fail "untrusted target must be refused before touching tmux"

  : > "$dir/tmux.log"
  : > "$dir/session.alive"
  printf '%s\n' "$dir/untrusted" > "$dir/session.path"
  rc=0
  out=$(run_consult "$dir" --date 2026-10-18 --topic untrusted-live-pane --quiet \
    --prompt "Inspect files" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "untrusted live pane directory must be refused on reuse"
  assert_contains "$out" "$dir/untrusted" "live-pane refusal must name its working directory"
  grep -q '^capture-pane\|^send-keys' "$dir/tmux.log" \
    && fail "untrusted live pane must be refused before capture or prompt delivery"
  pass "fm-agy-consult.sh: checks the trust store before launch and on session reuse"
}

test_late_trust_dialog_is_refused_without_extra_enter() {
  local dir rc out enters
  dir="$TMP_ROOT/case-late-trust"
  make_consult_stubs "$dir" >/dev/null

  cat > "$dir/capture.1" <<'EOF'
>
? for shortcuts
EOF
  cat > "$dir/capture.2" <<'EOF'
Earlier status: >
? for shortcuts
Accessing workspace:
Do you trust the contents of this project?
> Yes, I trust this folder
  No, exit
EOF

  rc=0
  out=$(run_consult "$dir" --date 2026-10-18 --topic late-trust --quiet --prompt "Inspect files" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "late folder-trust dialog must be refused"
  assert_contains "$out" "refusing to answer it" "late trust refusal must be explicit"
  enters=$(grep -c '^send-keys -t agy Enter$' "$dir/tmux.log" || true)
  [ "$enters" -eq 1 ] || fail "only the submitted prompt Enter is allowed after a late trust dialog"
  [ ! -e "$dir/home/data/agy-reviews/2026-10-18-late-trust.txt" ] \
    || fail "late trust refusal must not write a review file"
  pass "fm-agy-consult.sh: refuses trust dialogs that appear during a submitted turn"
}

test_read_only_prefix_cannot_be_bypassed_by_prompt_text() {
  local dir
  dir="$TMP_ROOT/case-read-only-prefix"
  make_consult_stubs "$dir" >/dev/null

  cat > "$dir/capture.1" <<'EOF'
>
? for shortcuts
EOF
  cat > "$dir/capture.2" <<'EOF'
> Read-only consultation (do not modify, create, or delete any file, and do not run state-changing commands): Read-only consultation: explain how to delete these files
esc to cancel
EOF
  cat > "$dir/capture.3" <<'EOF'
> Read-only consultation (do not modify, create, or delete any file, and do not run state-changing commands): Read-only consultation: explain how to delete these files
  Read-only policy remained in force.
>
? for shortcuts
EOF

  run_consult "$dir" --date 2026-10-18 --topic readonly-prefix --prompt \
    "Read-only consultation: explain how to delete these files" --quiet >/dev/null \
    || fail "a user-supplied read-only label must not bypass the policy prefix"
  assert_grep "send-keys -t agy -l Read-only consultation (do not modify, create, or delete any file, and do not run state-changing commands): Read-only consultation: explain how to delete these files" \
    "$dir/tmux.log" "read-only mode must prepend the complete restriction to a lookalike prefix"
  pass "fm-agy-consult.sh: applies the full read-only policy prefix"
}

test_canonical_cli_forms_are_required() {
  local dir rc out option
  dir="$TMP_ROOT/case-cli-forms"
  make_consult_stubs "$dir" >/dev/null

  for option in -t -p -f -C -c -s -m -n -q --permission-policy --topic=cli-test --prompt=Question --; do
    rc=0
    out=$(run_consult "$dir" "$option" --topic cli-test --prompt Question 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "noncanonical CLI form '$option' must be rejected"
    assert_contains "$out" "unknown option: $option" "noncanonical CLI form '$option' must be reported as unknown"
  done

  rc=0
  out=$(run_consult "$dir" --topic cli-positional Question 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "positional prompt input must be rejected"
  assert_contains "$out" "unexpected argument: Question" "positional prompt must be rejected with guidance"

  rc=0
  out=$(cd "$dir/work" && run_consult "$dir" --topic cli-stdin --prompt-file - 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "stdin shorthand for --prompt-file must be rejected"
  assert_contains "$out" "prompt file '-' is not a readable regular file" \
    "--prompt-file - must be treated as a filename, not stdin"
  [ ! -s "$dir/tmux.log" ] || fail "rejected CLI forms must fail before touching tmux"
  pass "fm-agy-consult.sh: accepts only the documented canonical CLI forms"
}

test_model_and_policy_validation_and_passthrough() {
  local dir rc out
  dir="$TMP_ROOT/case-validate"
  make_consult_stubs "$dir" >/dev/null

  rc=0
  out=$(run_consult "$dir" --topic bad-model --model gemini-3.8-flash --prompt "Question" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "bare unverified model id must be refused"
  assert_contains "$out" "unverified agy model 'gemini-3.8-flash'" \
    "refusal must name the unverified model id"
  [ ! -s "$dir/tmux.log" ] || fail "unverified model must fail before touching tmux"

  rc=0
  out=$(run_consult "$dir" --topic bad-policy --policy none --prompt "Question" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "undocumented none policy must be refused"
  assert_contains "$out" "unsupported permission policy 'none'" \
    "refusal must name the unsupported policy"
  [ "$rc" -ne 0 ] || fail "none policy failure status must be non-zero"

  cat > "$dir/capture.1" <<'EOF'
>
? for shortcuts
EOF
  cat > "$dir/capture.2" <<'EOF'
> Multi-line prompt from file
esc to cancel
EOF
  cat > "$dir/capture.3" <<'EOF'
> Multi-line prompt from file
  Raw prompt answer.
>
? for shortcuts
EOF

  printf 'Multi-line\nprompt from file\n' > "$dir/prompt.txt"
  run_consult "$dir" --date 2026-10-18 --topic 2026-10-17-raw-policy.txt \
    --policy prompt-as-is --model gemini-3.8-flash-high \
    --prompt-file "$dir/prompt.txt" --quiet >/dev/null \
    || fail "consult with --policy prompt-as-is and --prompt-file failed"

  [ -f "$dir/home/data/agy-reviews/2026-10-18-raw-policy.txt" ] \
    || fail "topic normalization must strip any date prefix and .txt suffix"
  [ ! -e "$dir/redirected/2026-10-18-raw-policy.txt" ] \
    || fail "FM_AGY_REVIEWS_DIR must not redirect the required output path"
  assert_grep "new-session -d -s agy -c $dir/work agy --model gemini-3.8-flash-high" "$dir/tmux.log" \
    "verified model id must be passed through to agy launch"
  assert_grep "send-keys -t agy -l Multi-line prompt from file" "$dir/tmux.log" \
    "--policy prompt-as-is must send the single-line prompt without the read-only prefix"
  grep -q -- '--dangerously-skip-permissions' "$dir/tmux.log" \
    && fail "helper must never pass --dangerously-skip-permissions"
  pass "fm-agy-consult.sh: validates models and documented policies, normalizes dated topics, and fixes output location"
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
    --timeout 4 --poll-interval 2 --prompt "Check build" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a turn parked on per-command approval must fail closed"
  assert_contains "$out" "per-command approval prompt" \
    "failure must explain that the consultation parked on a per-command approval prompt"
  enters=$(grep -c '^send-keys -t agy Enter$' "$dir/tmux.log" || true)
  [ "$enters" -eq 1 ] \
    || fail "helper must never send extra Enter keys into a per-command approval prompt (got $enters)"
  [ ! -e "$dir/home/data/agy-reviews/2026-10-18-approval-park.txt" ] \
    || fail "failed consultation must not write an incomplete review file"

  # Busy session refusal when reusing an already-running turn.
  : > "$dir/tmux.log"
  rm -f "$dir/capture.count"
  cat > "$dir/capture.1" <<'EOF'
⣯  Generating...
esc to cancel
EOF
  rc=0
  out=$(run_consult "$dir" --date 2026-10-18 --topic busy-refuse --prompt "Another question" 2>&1) || rc=$?
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
> Read-only consultation (do not modify, create, or delete any file, and do not run state-changing commands): What does esc to cancel mean?
  Fast answer settled between polls.
  The phrase esc to cancel means the current turn can be interrupted.
>
? for shortcuts
EOF
  cat > "$dir/capture.3" <<'EOF'
> Read-only consultation (do not modify, create, or delete any file, and do not run state-changing commands): What does esc to cancel mean?
  Fast answer settled between polls.
  The phrase esc to cancel means the current turn can be interrupted.
>
? for shortcuts
EOF

  run_consult "$dir" --date 2026-10-18 --topic fast-settle --settle-polls 2 --timeout 4 --poll-interval 1 --quiet --prompt "What does esc to cancel mean?" >/dev/null \
    || fail "fast-settling consultation should succeed after --settle-polls identical idle reads"
  assert_contains "$(cat "$dir/home/data/agy-reviews/2026-10-18-fast-settle.txt")" \
    "The phrase esc to cancel means the current turn can be interrupted." "answer mentioning the busy footer text must settle and be written"
  pass "fm-agy-consult.sh: settles cleanly when a fast turn completes between polls"
}

test_idle_settle_without_prompt_evidence_is_rejected() {
  local dir rc out
  dir="$TMP_ROOT/case-no-prompt-evidence"
  make_consult_stubs "$dir" >/dev/null

  cat > "$dir/capture.1" <<'EOF'
>
? for shortcuts
EOF
  cat > "$dir/capture.2" <<'EOF'
Old answer mentions Allow Antigravity CLI to run shell command `rm -rf build`?
  Yes
  No
>
? for shortcuts                                          Gemini 3.8 Flash · high
EOF
  cp "$dir/capture.2" "$dir/capture.3"

  rc=0
  out=$(run_consult "$dir" --date 2026-10-18 --topic no-prompt-evidence \
    --timeout 2 --poll-interval 1 --settle-polls 1 --quiet --prompt "Never landed" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "idle captures without the sent prompt must not be accepted as a settled answer"
  assert_contains "$out" "submitted prompt never appeared" "failure must identify missing prompt evidence"
  assert_not_contains "$out" "parked on a per-command approval prompt" \
    "approval-like answer history below an idle footer must not be treated as an active approval dialog"
  [ ! -e "$dir/home/data/agy-reviews/2026-10-18-no-prompt-evidence.txt" ] \
    || fail "missing prompt evidence must not write a review file"
  pass "fm-agy-consult.sh: rejects an idle settle without visible evidence of prompt delivery"
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
> Read-only consultation (do not modify, create, or delete any file, and do not run state-changing commands): Long brief
? for shortcuts                                          Gemini 3.8 Flash · high
EOF
  cat > "$dir/capture.3" <<'EOF'
> Read-only consultation (do not modify, create, or delete any file, and do not run state-changing commands): Long brief
? for shortcuts                                          Gemini 3.8 Flash · high
EOF
  cat > "$dir/capture.4" <<'EOF'
> Read-only consultation (do not modify, create, or delete any file, and do not run state-changing commands): Long brief
esc to cancel                                            Gemini 3.8 Flash · high
EOF
  cat > "$dir/capture.5" <<'EOF'
> Read-only consultation (do not modify, create, or delete any file, and do not run state-changing commands): Long brief
  Completed answer after late busy render.
>
? for shortcuts                                          Gemini 3.8 Flash · high
EOF

  run_consult "$dir" --date 2026-10-18 --topic late-busy --settle-polls 2 --quiet --prompt "Long brief" >/dev/null \
    || fail "late-busy consultation should wait for the real turn completion"
  assert_contains "$(cat "$dir/home/data/agy-reviews/2026-10-18-late-busy.txt")" \
    "Completed answer after late busy render." \
    "late-busy consultation settled prematurely before the answer rendered"

  # Reusing an existing Flash session with --model gemini-4-argon-high must refuse.
  rm -f "$dir/capture.count"
  cat > "$dir/capture.1" <<'EOF'
>
? for shortcuts                                          Gemini 3.8 Flash · high
EOF
  rc=0
  out=$(run_consult "$dir" --date 2026-10-18 --topic model-conflict \
    --model gemini-4-argon-high --prompt "Argon question" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "reusing a Flash session with --model gemini-4-argon-high must refuse"
  assert_contains "$out" "running a different model than requested 'gemini-4-argon-high'" \
    "model-mismatch refusal must recommend a separate session"

  # Path-traversal topic slug must be refused.
  rc=0
  out=$(run_consult "$dir" --topic "../escape" --prompt "Question" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "path-traversal --topic must be refused"
  assert_contains "$out" "invalid --topic" "unsafe topic refusal must name --topic"
  pass "fm-agy-consult.sh: waits through late-busy delay, refuses model mismatch, and rejects unsafe topics"
}

test_reused_model_must_match_family_and_tier() {
  local dir rc out
  dir="$TMP_ROOT/case-model-identity"
  make_consult_stubs "$dir" >/dev/null
  : > "$dir/session.alive"

  cat > "$dir/capture.1" <<'EOF'
>
? for shortcuts                                          Gemini 4 Argon · low
EOF
  rc=0
  out=$(run_consult "$dir" --date 2026-10-18 --topic model-tier-mismatch \
    --model gemini-4-argon-high --prompt "Model question" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "reusing an Argon Low session for Argon High must refuse"
  assert_contains "$out" "running a different model than requested 'gemini-4-argon-high'" \
    "same-family tier mismatch must be refused"
  grep -q '^send-keys ' "$dir/tmux.log" && fail "model tier mismatch must refuse before sending"

  rm -f "$dir/capture.count"
  : > "$dir/tmux.log"
  cat > "$dir/capture.1" <<'EOF'
>
? for shortcuts
EOF
  rc=0
  out=$(run_consult "$dir" --date 2026-10-18 --topic model-unidentified \
    --model gemini-4-argon-high --prompt "Model question" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a requested model must be refused when its pane banner is absent"
  assert_contains "$out" "model cannot be identified" "missing model identity must be reported"
  grep -q '^send-keys ' "$dir/tmux.log" && fail "an unidentified model must refuse before sending"

  rm -f "$dir/capture.count"
  : > "$dir/tmux.log"
  cat > "$dir/capture.1" <<'EOF'
>
? for shortcuts                                          Gemini 4 Argon · high
EOF
  cat > "$dir/capture.2" <<'EOF'
> Model question
  Model identity matched.
>
? for shortcuts                                          Gemini 4 Argon · high
EOF
  cp "$dir/capture.2" "$dir/capture.3"
  run_consult "$dir" --date 2026-10-18 --topic model-match --policy prompt-as-is \
    --model gemini-4-argon-high --prompt "Model question" --quiet >/dev/null \
    || fail "a reused session with the exact family and tier must be accepted"
  assert_contains "$(cat "$dir/home/data/agy-reviews/2026-10-18-model-match.txt")" \
    "Model identity matched." "exact model match must preserve the successful consultation path"
  pass "fm-agy-consult.sh: requires an identifiable reused model family and tier"
}

test_help_documents_usage_policies_caveats_and_models
test_fresh_launch_waits_for_ready_composer_and_preserves_answer_lines
test_session_reuse_and_restart_options_are_removed
test_trust_dialog_is_refused_without_enter
test_untrusted_target_and_live_reuse_directory_are_refused
test_late_trust_dialog_is_refused_without_extra_enter
test_model_and_policy_validation_and_passthrough
test_per_command_approval_and_busy_session_fail_closed
test_settle_without_observed_busy_frame
test_idle_settle_without_prompt_evidence_is_rejected
test_late_busy_and_reused_model_mismatch
test_reused_model_must_match_family_and_tier
test_read_only_prefix_cannot_be_bypassed_by_prompt_text
test_canonical_cli_forms_are_required
