# shellcheck shell=bash
# Step-by-step demo runner for the EKS course.
#
# Sourced from ~/.bashrc on the class workstation. Usage:
#   demo list              list topics
#   demo 3                 run Topic 3 step by step (Enter = run, s = skip, q = quit)
#   demo 3 2               start Topic 3 at step 2
#   demo 3 --yes           run every step without pausing (for rehearsals / Kiro)
#   demo show 3            print Topic 3 steps without running anything
#   start                  run Topic 0 (starter) - use it every time you come back
#
# Topic files are plain bash scripts. A line starting with "##> " begins a new
# step and gives it a title. Steps run in YOUR shell, so exports and cd persist.
# The runner's own variables start with _d_ so a step can use any name (i, file, ...).

DEMO_DIR="${DEMO_DIR:-$HOME/eks-course/demos}"

_demo_file() {
  local n
  if [[ "$1" =~ ^[0-9]+$ ]]; then n=$(printf '%02d' "$((10#$1))"); else n="$1"; fi
  compgen -G "$DEMO_DIR/topic-${n}-*.sh" | head -n 1
}

# Split a topic file into step titles and bodies (global arrays).
_demo_parse() {
  _DEMO_TITLES=(); _DEMO_BODIES=()
  local line title="" body="" started=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "##> "* ]]; then
      if (( started )); then _DEMO_TITLES+=("$title"); _DEMO_BODIES+=("$body"); fi
      title="${line#\#\#> }"; body=""; started=1
    elif (( started )); then
      body+="$line"$'\n'
    fi
  done < "$1"
  if (( started )); then _DEMO_TITLES+=("$title"); _DEMO_BODIES+=("$body"); fi
}

# Run a command for at most N seconds (for --watch / -f commands). Ctrl+C also continues.
watch_for() {
  local secs="$1"; shift
  echo "(showing for up to ${secs}s - press Ctrl+C to continue)"
  timeout --foreground "$secs" "$@" || true
}

demo() {
  local c_title=$'\e[1;33m' c_code=$'\e[36m' c_dim=$'\e[2m' c_ok=$'\e[32m' c_bad=$'\e[31m' c_off=$'\e[0m'

  case "${1:-}" in
    ""|-h|--help|help)
      sed -n '3,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
    list)
      local f
      for f in "$DEMO_DIR"/topic-*.sh; do
        printf '  %s  %s\n' "$(basename "$f" .sh | cut -d- -f2)" "$(sed -n '2s/^# //p' "$f")"
      done
      return 0 ;;
    show)
      local sf; sf="$(_demo_file "${2:-}")" || true
      [[ -f "$sf" ]] || { echo "No topic '${2:-}'. Try: demo list"; return 1; }
      _demo_parse "$sf"
      local j
      for j in "${!_DEMO_TITLES[@]}"; do
        printf '\n%sStep %d: %s%s\n%s%s%s' "$c_title" "$((j + 1))" "${_DEMO_TITLES[$j]}" "$c_off" "$c_code" "${_DEMO_BODIES[$j]}" "$c_off"
      done
      return 0 ;;
  esac

  local _d_file; _d_file="$(_demo_file "$1")" || true
  [[ -f "$_d_file" ]] || { echo "No topic '$1'. Try: demo list"; return 1; }
  shift
  local _d_start=1 _d_auto=0 _d_arg
  for _d_arg in "$@"; do
    case "$_d_arg" in
      --yes|-y) _d_auto=1 ;;
      [0-9]*) _d_start="$_d_arg" ;;
    esac
  done

  _demo_parse "$_d_file"
  local _d_total=${#_DEMO_TITLES[@]} _d_i _d_ans _d_rc
  local _d_modnum; _d_modnum="$(basename "$_d_file" .sh | cut -d- -f2)"
  printf '\n%s== %s ==%s  (%d steps)\n' "$c_title" "$(sed -n '2s/^# //p' "$_d_file")" "$c_off" "$_d_total"

  for (( _d_i = _d_start - 1; _d_i < _d_total; _d_i++ )); do
    printf '\n%s[Step %d/%d] %s%s\n' "$c_title" "$((_d_i + 1))" "$_d_total" "${_DEMO_TITLES[$_d_i]}" "$c_off"
    printf '%s%s%s' "$c_code" "${_DEMO_BODIES[$_d_i]}" "$c_off"
    if (( ! _d_auto )); then
      read -r -p "${c_dim}Enter = run, s = skip, q = quit > ${c_off}" _d_ans </dev/tty
      case "$_d_ans" in
        q|Q) echo "Stopped. Resume with: demo $_d_modnum $((_d_i + 1))"; return 0 ;;
        s|S) echo "(skipped)"; continue ;;
      esac
    fi
    # Ctrl+C stops the current command only, not the whole demo.
    trap 'printf "\n(interrupted)\n"' INT
    eval "${_DEMO_BODIES[$_d_i]}"
    _d_rc=$?
    trap - INT
    if (( _d_rc == 0 )); then
      printf '%s-- step %d done --%s\n' "$c_ok" "$((_d_i + 1))" "$c_off"
    else
      printf '%s-- step %d finished with exit code %d --%s\n' "$c_bad" "$((_d_i + 1))" "$_d_rc" "$c_off"
      if (( _d_auto )); then echo "Stopping (auto mode). Resume with: demo $_d_modnum $((_d_i + 1))"; return "$_d_rc"; fi
    fi
  done
  printf '\n%sTopic complete.%s\n' "$c_ok" "$c_off"
}

# Short command for coming back to the workstation: checks, cluster, shared tmux session.
start() { demo 0 --yes; }
