#!/usr/bin/env bash
# Metrics and reports stay under "$FM_HOME/data/repo-maintenance".

set -u

# shellcheck disable=SC2034

export LC_ALL=C

RM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RM_SCRIPT_DIR="$(cd "$RM_LIB_DIR/.." && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$RM_SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="$FM_HOME/data"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

RM_DATA="$DATA/repo-maintenance"
export METRICS_DIR="$RM_DATA/metrics" SOFT_CEILING_LINES=500 SUMMARY_MAX_LINES=30 \
  DEPTH_MAX_BELOW_SRC=4 DEFAULT_WINDOW_DAYS=7 \
  DEFAULT_TOP=10

RM_CLEANUP_ROOT=""
rm_cleanup_all() {
  local root=$RM_CLEANUP_ROOT
  RM_CLEANUP_ROOT=""
  [ -n "$root" ] && rm -rf -- "$root"
}
trap rm_cleanup_all EXIT INT TERM HUP

rm_init_tmp_root() {
  [ -n "$RM_CLEANUP_ROOT" ] && return 0
  RM_CLEANUP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-repo-maintenance.XXXXXX") || return 1
  export RM_CLEANUP_ROOT
}

rm_new_tmp() {
  local name=$1 outvar=$2 d
  [ -n "$RM_CLEANUP_ROOT" ] || return 1
  d=$(mktemp -d "$RM_CLEANUP_ROOT/$name.XXXXXX") || return 1
  printf -v "$outvar" '%s' "$d"
}

rm_die_usage() {
  printf 'fm-repo-maintenance: %s\n' "$1" >&2
  rm_usage >&2
  exit 2
}

rm_die_refuse() {
  printf 'fm-repo-maintenance: %s\n' "$1" >&2
  exit 2
}

rm_die_fail() {
  printf 'fm-repo-maintenance: %s\n' "$1" >&2
  exit 1
}

rm_require_jq() {
  command -v jq >/dev/null 2>&1 || rm_die_fail "jq is required"
}

rm_epoch_to_date() {
  date -u -r "$1" +%Y-%m-%d 2>/dev/null || date -u -d "@$1" +%Y-%m-%d
}

rm_iso_to_epoch() {
  local ts=$1 out
  out=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null) \
    || out=$(date -u -d "$ts" +%s 2>/dev/null) \
    || return 1
  printf '%s\n' "$out"
}

# Return the physical path when the path or its parent exists. A missing final
# component is retained after its physical parent is resolved.
rm_physical_path() {
  local input=$1 parent base physical="" suffix=""
  case "$input" in
    /*) ;;
    *) return 1 ;;
  esac
  while [ ! -e "$input" ] && [ ! -L "$input" ]; do
    base=$(basename -- "$input")
    suffix="/$base$suffix"
    parent=$(dirname -- "$input")
    [ "$parent" != "$input" ] || return 1
    input=$parent
  done
  if command -v realpath >/dev/null 2>&1; then
    physical=$(realpath "$input" 2>/dev/null) || physical=""
  fi
  if [ -z "$physical" ]; then
    if [ -d "$input" ]; then
      physical=$(cd -P -- "$input" 2>/dev/null && pwd -P) || return 1
    else
      [ ! -L "$input" ] || return 1
      base=$(basename -- "$input")
      parent=$(cd -P -- "$(dirname -- "$input")" 2>/dev/null && pwd -P) || return 1
      physical="$parent/$base"
    fi
  fi
  printf '%s%s\n' "$physical" "$suffix"
}

rm_physical_dir() {
  local p
  [ -d "$1" ] || return 1
  p=$(cd -P -- "$1" 2>/dev/null && pwd -P) || return 1
  printf '%s\n' "$p"
}

rm_path_under() {
  local path=$1 root=$2
  [ "$path" = "$root" ] || case "$path" in "$root"/*) ;; *) return 1 ;; esac
}

rm_path_in_home() {
  local path=$1
  [ -n "$RM_APPROVED_HOME" ] && [ "$path" != "$RM_APPROVED_HOME" ] \
    && rm_path_under "$path" "$RM_APPROVED_HOME"
}

rm_resolve_source_path() {
  local path=$1
  case "$path" in /*) ;; *) path="$PWD/$path" ;; esac
  rm_physical_path "$path"
}

RM_APPROVED_HOME=""
RM_OPERATOR_HOME=""
RM_CODE_ROOT=""
RM_EXTRA_ROOTS=()

rm_init_roots() {
  local root_list="$FM_HOME:$FM_ROOT:${FM_RM_SESSION_ROOTS:-$HOME/.treehouse}" r canonical
  RM_APPROVED_HOME=$(rm_physical_dir "$FM_HOME" 2>/dev/null || true)
  RM_OPERATOR_HOME=$(rm_physical_dir "$HOME" 2>/dev/null || true)
  RM_CODE_ROOT=$(rm_physical_dir "$FM_ROOT" 2>/dev/null || true)
  RM_EXTRA_ROOTS=()
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    canonical=$(rm_physical_dir "$r" 2>/dev/null || true)
    [ -n "$canonical" ] || continue
    [ "$canonical" = "$RM_APPROVED_HOME" ] && continue
    local seen=0 x
    for x in "${RM_EXTRA_ROOTS[@]+${RM_EXTRA_ROOTS[@]}}"; do
      [ "$x" = "$canonical" ] && seen=1
    done
    [ "$seen" -eq 0 ] && RM_EXTRA_ROOTS+=("$canonical")
  done < <(printf '%s\n' "$root_list" | tr ':' '\n')
}

rm_init_roots

# Emit a stable label for a path. Unknown paths, including relative paths, are
# deliberately reduced to a placeholder so an absolute path cannot escape.
rm_sanitize_path() {
  local input=$1 physical root rel
  physical=$(rm_physical_path "$input" 2>/dev/null || true)
  [ -n "$physical" ] || { printf '<EXTERNAL>\n'; return 0; }
  if [ -n "$RM_CODE_ROOT" ] && [ "$RM_CODE_ROOT" != "$RM_APPROVED_HOME" ] \
    && rm_path_under "$physical" "$RM_CODE_ROOT"; then
    rel=${physical#"$RM_CODE_ROOT"}
    printf '<FIRSTMATE>%s\n' "$rel"
    return 0
  fi
  if [ -n "$RM_APPROVED_HOME" ] && rm_path_under "$physical" "$RM_APPROVED_HOME"; then
    rel=${physical#"$RM_APPROVED_HOME"}
    printf '<HOME>%s\n' "$rel"
    return 0
  fi
  if [ -n "$RM_OPERATOR_HOME" ] && rm_path_under "$physical" "$RM_OPERATOR_HOME"; then
    rel=${physical#"$RM_OPERATOR_HOME"}
    printf '<HOME>%s\n' "$rel"
    return 0
  fi
  for root in "${RM_EXTRA_ROOTS[@]+${RM_EXTRA_ROOTS[@]}}"; do
    if rm_path_under "$physical" "$root"; then
      rel=${physical#"$root"}
      printf '<POOL>%s\n' "$rel"
      return 0
    fi
  done
  printf '<EXTERNAL>\n'
}

# Print scope and root-relative path for a named read. Relative tool
# paths are resolved from the session cwd; symlink escapes are rejected.
rm_classify_file() {
  local raw=$1 cwd=$2 candidate physical rel project root parts
  case "$raw" in
    /*) candidate=$raw ;;
    *) candidate="$cwd/$raw" ;;
  esac
  physical=$(rm_physical_path "$candidate" 2>/dev/null || true)
  [ -n "$physical" ] || return 1
  [ -z "$RM_APPROVED_HOME" ] || [ "$physical" != "$RM_APPROVED_HOME" ] || return 1
  [ -z "$RM_CODE_ROOT" ] || [ "$physical" != "$RM_CODE_ROOT" ] || return 1
  for root in "${RM_EXTRA_ROOTS[@]+${RM_EXTRA_ROOTS[@]}}"; do
    [ "$physical" != "$root" ] || return 1
  done

  if [ -n "$RM_APPROVED_HOME" ] && rm_path_under "$physical" "$RM_APPROVED_HOME"; then
    rel=${physical#"$RM_APPROVED_HOME"/}
    case "$rel" in
      projects/*/*)
        project=${rel#projects/}
        project=${project%%/*}
        [ -n "$project" ] || return 1
        rel=${rel#projects/"$project"/}
        printf 'projects/%s\t%s\n' "$project" "$rel"
        return 0
        ;;
      projects/*) return 1 ;;
    esac
  fi

  if [ -n "$RM_CODE_ROOT" ] && rm_path_under "$physical" "$RM_CODE_ROOT"; then
    rel=${physical#"$RM_CODE_ROOT"/}
    [ -n "$rel" ] || return 1
    printf 'firstmate\t%s\n' "$rel"
    return 0
  fi

  if [ -n "$RM_APPROVED_HOME" ] && rm_path_under "$physical" "$RM_APPROVED_HOME"; then
    rel=${physical#"$RM_APPROVED_HOME"/}
    [ -n "$rel" ] || return 1
    if [[ "$rel" == */* ]]; then
      rel=${rel%%/*}
    elif [ -d "$physical" ]; then
      :
    else
      rel=root
    fi
    printf 'home\t%s\n' "$rel"
    return 0
  fi

  for root in "${RM_EXTRA_ROOTS[@]+${RM_EXTRA_ROOTS[@]}}"; do
    [ "$root" != "$RM_CODE_ROOT" ] || continue
    if rm_path_under "$physical" "$root"; then
      rel=${physical#"$root"/}
      IFS=/ read -r -a parts <<< "$rel"
      [ "${#parts[@]}" -ge 4 ] || return 1
      project=${parts[2]}
      [ -n "$project" ] || return 1
      rel=${rel#"${parts[0]}/${parts[1]}/$project/"}
      [ -n "$rel" ] || return 1
      printf 'projects/%s\t%s\n' "$project" "$rel"
      return 0
    fi
  done
  return 1
}

rm_sanitize_home_area() {
  local input=$1 physical rel area root
  case "$input" in
    '<EXTERNAL>'|'<POOL>'*|'<FIRSTMATE>'*) printf '%s\n' "$input"; return 0 ;;
    '<HOME>'*)
      rel=${input#'<HOME>'}
      rel=${rel#/}
      area=${rel%%/*}
      [ -n "$rel" ] && [ "$rel" != "$area" ] || area=root
      printf '<HOME>/%s\n' "$area"
      return 0
      ;;
  esac
  physical=$(rm_physical_path "$input" 2>/dev/null || true)
  [ -n "$physical" ] || { rm_sanitize_path "$input"; return 0; }
  if [ -n "$RM_CODE_ROOT" ] && [ "$RM_CODE_ROOT" != "$RM_APPROVED_HOME" ] \
    && rm_path_under "$physical" "$RM_CODE_ROOT"; then
    rm_sanitize_path "$physical"
    return 0
  fi
  for root in "$RM_APPROVED_HOME" "$RM_OPERATOR_HOME"; do
    [ -n "$root" ] || continue
    if rm_path_under "$physical" "$root"; then
      rel=${physical#"$root"}
      rel=${rel#/}
      if [ -z "$rel" ]; then
        area=root
      elif [[ "$rel" == */* ]]; then
        area=${rel%%/*}
      elif [ -d "$physical" ]; then
        area=$rel
      else
        area=root
      fi
      printf '<HOME>/%s\n' "$area"
      return 0
    fi
  done
  rm_sanitize_path "$physical"
}

rm_root_matches() {
  local dir=$1 physical root
  physical=$(rm_physical_dir "$dir" 2>/dev/null || true)
  [ -n "$physical" ] || { printf '0\n'; return 0; }
  if [ -n "$RM_APPROVED_HOME" ] && rm_path_under "$physical" "$RM_APPROVED_HOME"; then
    printf '1\n'
    return 0
  fi
  for root in "${RM_EXTRA_ROOTS[@]+${RM_EXTRA_ROOTS[@]}}"; do
    if rm_path_under "$physical" "$root"; then
      printf '1\n'
      return 0
    fi
  done
  printf '0\n'
}

rm_scope_root() {
  local scope=$1 project root canonical
  case "$scope" in
    firstmate)
      rm_physical_dir "$FM_ROOT" 2>/dev/null || return 1
      ;;
    home)
      rm_physical_dir "$FM_HOME" 2>/dev/null || return 1
      ;;
    projects/*)
      project=${scope#projects/}
      case "$project" in ''|*/*|.|..|*..*) return 1 ;; esac
      root="$PROJECTS/$project"
      canonical=$(rm_physical_dir "$root" 2>/dev/null || true)
      [ -n "$canonical" ] || return 1
      [ -n "$RM_APPROVED_HOME" ] && rm_path_under "$canonical" "$RM_APPROVED_HOME" || return 1
      printf '%s\n' "$canonical"
      ;;
    *) return 1 ;;
  esac
}

rm_resolve_scoped_file() {
  local root=$1 rel=$2 candidate physical
  case "$rel" in ''|/*|.|./*|../*|*/../*|*/..|.. ) return 1 ;; esac
  candidate="$root/$rel"
  physical=$(rm_physical_path "$candidate" 2>/dev/null || true)
  [ -n "$physical" ] || return 1
  rm_path_under "$physical" "$root" || return 1
  printf '%s\n' "$physical"
}

rm_is_code_file() {
  case "$1" in
    *.py|*.sh|*.bash|*.zsh|*.js|*.mjs|*.cjs|*.ts|*.tsx|*.jsx|*.rb|*.go|*.rs|*.java|*.kt|*.kts|*.swift|*.c|*.cc|*.cpp|*.h|*.hpp|*.cs|*.php|*.pl|*.lua|*.sql) return 0 ;;
    *) return 1 ;;
  esac
}
