#!/bin/zsh
# cocaine remote — control Cocaine and AI coding agents from anywhere you can run a command: SSH from a phone
# (Apple Shortcuts' "Run Script Over SSH", or any SSH app), or right here in Terminal.
#
#   cocaine remote status [--json]      Cocaine, battery, running agents
#   cocaine remote on [--for 2h]        keep the Mac awake (optionally for a while)
#   cocaine remote off
#   cocaine remote projects             the projects you can start work in
#   cocaine remote agents               which AI agents are installed
#   cocaine remote start <agent> <project> [--resume] [prompt…]
#   cocaine remote runs                 running (and finished) work
#   cocaine remote log <run> [lines]    what the agent shows on screen now
#   cocaine remote send <run> <text…>   type into the agent (and press Return)
#   cocaine remote key <run> <key>      enter esc up down tab ctrl-c y n 1 2 3
#   cocaine remote attach <run>         take over the terminal (detach with Ctrl-A D)
#   cocaine remote stop <run>
#   cocaine remote wake-info            what a Wake-on-LAN app needs
#   cocaine remote notify shortcut "Name" | ntfy https://ntfy.sh/topic | off | test
#
# No network port is opened: this only runs commands for the user who runs it. Agents run inside `screen`
# sessions (built into macOS), so they survive the SSH connection closing. Cocaine is turned on when work starts
# and back to how it was when the last piece of work ends.

HERE=${0:A:h}
ENGINE=${COCAINE_ENGINE:-$HERE/cocaine}
[[ -x $ENGINE ]] || ENGINE=$HERE/cocaine.zsh      # running from the source folder
SUPPORT=${COCAINE_SUPPORT:-"$HOME/Library/Application Support/Cocaine"}
RUNS=$SUPPORT/runs
BOARD=$SUPPORT/state.json
DOMAIN=${COCAINE_DOMAIN:-local.cocaine.toggle}
export SCREENDIR=${COCAINE_SCREENDIR:-$HOME/.cocaine-screen}      # short: the socket path has a ~100 byte limit
mkdir -p -m 700 "$SUPPORT" "$RUNS" "$SCREENDIR" 2>/dev/null
chmod 700 "$SUPPORT" "$RUNS" "$SCREENDIR" 2>/dev/null
[[ -f $SUPPORT/screenrc ]] || print -r -- $'startup_message off\ndefscrollback 5000\nterm screen-256color\nvbell off' > "$SUPPORT/screenrc"
SCREEN=(/usr/bin/screen -U -c "$SUPPORT/screenrc")

die() { print -ru2 -- "cocaine remote: $*"; exit 1; }

# 90m, 2h, 1h30m or a bare number of minutes → minutes (1…2880)
dur_minutes() {
  local s=${1:l}
  if [[ $s == <-> ]]; then :
  elif [[ $s =~ '^(([0-9]+)h)?(([0-9]+)m?)?$' && -n $s ]]; then s=$(( ${match[2]:-0} * 60 + ${match[4]:-0} ))
  else return 1; fi
  (( s >= 1 && s <= 2880 )) || return 1
  print -r -- $s
}

safe_name() { print -r -- "${1//[^A-Za-z0-9._-]/-}"; }

cocaine_on() { "$ENGINE" status 2>/dev/null | /usr/bin/head -1 | /usr/bin/grep -q '^ON'; }

battery_line() {
  local b; b=$(/usr/bin/pmset -g batt 2>/dev/null) || return
  local pct=$(print -r -- "$b" | /usr/bin/grep -o '[0-9]*%' | /usr/bin/head -1)
  [[ -z $pct ]] && { print "no battery"; return; }
  if print -r -- "$b" | /usr/bin/grep -q "AC Power"; then print "$pct, on power"; else print "$pct, on battery"; fi
}

jesc() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; print -rn -- "$s"; }

meta_get() { /usr/bin/sed -n "s/^$2=//p" "$RUNS/$1/meta" 2>/dev/null | /usr/bin/head -1; }
run_ids() { local d; for d in "$RUNS"/*(N/); do print -r -- ${d:t}; done; }
# screen matches -S names by prefix (claude-beta would also match claude-beta-2), so name the session as pid.name
session_full() { "${SCREEN[@]}" -ls 2>/dev/null | /usr/bin/awk -v n="cocaine-$1" '{ split($1, p, "."); if (p[2] == n) { print $1; exit } }'; }
sx() { local s; s=$(session_full $1); [[ -n $s ]] || return 1; "${SCREEN[@]}" -S "$s" -p 0 -X "${@:2}"; }   # -p 0: a detached session needs its window named
session_alive() { [[ -n $(session_full $1) ]]; }
run_done() { [[ -f $RUNS/$1/done ]]; }
need_run() { [[ ${1:-} =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' && -d $RUNS/$1 ]] || die "no such run: ${1:-} (see: cocaine remote runs)"; }

# The board the app writes from the agents' hooks: state<TAB>agent<TAB>project<TAB>since
board_lines() {
  [[ -f $BOARD ]] || return 0
  /usr/bin/perl -MJSON::PP -e 'local $/; open(F, "<", shift) or exit; my $j = eval { decode_json(<F>) } || {}; for my $a (@{$j->{agents} || []}) { my @f = map { my $x = $_ // ""; $x =~ s/[\x00-\x1f\x7f]/ /g; $x } @$a{qw(state from project)}; my $since = $a->{since} // 0; $since = 0 unless $since =~ /^[0-9.]+$/; print join("\t", @f, int($since)), "\n" }' "$BOARD" 2>/dev/null
}

agent_state() {  # $1 agent name $2 project → the newest state the hooks reported, or empty
  local st from proj since best=0 out=""
  while IFS=$'\t' read -r st from proj since; do
    [[ $since == <-> ]] || continue                     # a number, or ignore the line
    [[ ${from:l} == *"${1:l}"* && ${proj} == "$2" ]] || continue
    (( since >= best )) && { best=$since; out=$st; }
  done < <(board_lines)
  print -r -- $out
}

ago() { local s=$(( $(date +%s) - ${1%.*} )); (( s < 90 )) && print "${s}s" || { (( s < 5400 )) && print "$(( s / 60 ))m" || print "$(( s / 3600 ))h"; }; }

# Runs whose screen session is gone without having finished (reboot, kill): close them properly.
reconcile() {
  local id
  for id in $(run_ids); do
    run_done $id && continue
    session_alive $id || finish_run $id lost
  done
}

# Marks a run finished; when it was the last one, gives the Mac back its normal behaviour.
finish_run() {
  local id=$1 why=${2:-exit} dir=$RUNS/$1
  [[ -d $dir && ! -f $dir/done ]] || return 0
  print -r -- "$why $(date +%s)" > "$dir/done"
  local other left=0
  for other in $(run_ids); do run_done $other && continue; session_alive $other && (( left++ )); done
  if (( left == 0 )) && [[ -f $SUPPORT/restore ]]; then
    rm -f "$SUPPORT/restore"
    "$ENGINE" off >/dev/null 2>&1
    /usr/bin/defaults delete "$DOMAIN" onUntil 2>/dev/null
  fi
}

find_bin() {  # a login shell finds the same programs the user's Terminal does, not SSH's bare PATH
  local b
  [[ -n ${COCAINE_EXTRA_PATH:-} ]] && b=$(PATH="$COCAINE_EXTRA_PATH:$PATH" command -v -- $1) && [[ -n $b ]] && { print -r -- $b; return; }
  /bin/zsh -lc "command -v -- $1" 2>/dev/null | /usr/bin/tail -1
}

# The agents: name, program, and how to resume the latest conversation (empty = not known to work).
typeset -A PROGRAM RESUME
PROGRAM=(claude claude codex codex gemini gemini cursor cursor-agent copilot copilot opencode opencode qwen qwen aider aider)
RESUME=(claude "--continue" codex "resume --last" opencode "--continue" copilot "--continue" cursor "resume")
# Agents that accept the first prompt on their command line; for the others it's typed in once they've started.
PROMPT_ARG=(claude codex)

# ---------------------------------------------------------------- commands

cmd_status() {
  local json=0; [[ ${1:-} == --json ]] && json=1
  reconcile
  local on=OFF until="" ; cocaine_on && on=ON
  local u; u=$(/usr/bin/defaults read "$DOMAIN" onUntil 2>/dev/null); [[ -n $u ]] && u=$(printf '%.0f' "$u")   # defaults prints 1.79e+09
  [[ -n $u && $u == <-> && $u -gt $(date +%s) && $on == ON ]] && until=$u
  if (( json )); then
    local first=1 id
    print -rn -- "{\"cocaine\":\"$on\",\"until\":${until:-null},\"battery\":\"$(jesc "$(battery_line)")\",\"runs\":["
    for id in $(run_ids); do
      run_done $id && continue
      (( first )) || print -rn ","; first=0
      print -rn -- "{\"id\":\"$(jesc $id)\",\"agent\":\"$(jesc "$(meta_get $id agent)")\",\"project\":\"$(jesc "$(meta_get $id project)")\",\"state\":\"$(jesc "$(agent_state "$(meta_get $id agent)" "$(meta_get $id project)")")\",\"started\":$(meta_get $id started)}"
    done
    print "]}"
    return
  fi
  print -r -- "Cocaine: $on${until:+ (until $(date -r $until +%H:%M))}"
  print -r -- "Battery: $(battery_line)"
  local any=0 id st
  for id in $(run_ids); do
    run_done $id && continue
    (( any )) || print "Work in progress:"; any=1
    st=$(agent_state "$(meta_get $id agent)" "$(meta_get $id project)")
    print -r -- "  $id — $(meta_get $id agent) in $(meta_get $id project), running $(ago $(meta_get $id started))${st:+, $st}"
  done
  (( any )) || print "No work in progress."
  local line n=0 s f p t
  while IFS=$'\t' read -r s f p t; do
    (( n++ == 0 )) && print "Agents (from their hooks):"
    [[ $t == <-> ]] || continue
    print -r -- "  $f${p:+ in $p}: $s, $(ago $t) ago"
  done < <(board_lines)
}

cmd_on() {
  local mins=
  while (( $# )); do
    case $1 in
      --for) mins=$(dur_minutes "${2:-}") || die "bad duration '${2:-}' (try 90m, 2h, 1h30m)"; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  "$ENGINE" on || die "could not turn Cocaine on (is it set up? open Cocaine.app once)"
  if [[ -n $mins ]]; then /usr/bin/defaults write "$DOMAIN" onUntil -float $(( $(date +%s) + mins * 60 ))
  else /usr/bin/defaults delete "$DOMAIN" onUntil 2>/dev/null; fi
  print "Cocaine ON${mins:+ for $mins min}"
}

cmd_off() {
  "$ENGINE" off || die "could not turn Cocaine off"
  /usr/bin/defaults delete "$DOMAIN" onUntil 2>/dev/null
  rm -f "$SUPPORT/restore"
  print "Cocaine OFF"
}

project_roots() {
  if [[ -f $SUPPORT/projects.conf ]]; then /usr/bin/sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$SUPPORT/projects.conf"
  else print -rl -- ~/Developer ~/Projects ~/Documents ~/Desktop; fi
}

# name<TAB>ppath for every folder with a .git, two levels under each root
list_projects() {
  local root d
  while IFS= read -r root; do
    root=${~root}
    [[ -d $root ]] || continue
    /usr/bin/find "$root" -maxdepth 3 \( -name node_modules -o -name .claude -o -name Library \) -prune -o -name .git -print 2>/dev/null | while IFS= read -r d; do
      print -r -- "${${d:h}:t}"$'\t'"${d:h}"
    done
  done < <(project_roots) | /usr/bin/sort -u
}

cmd_projects() {
  local n=0 name ppath
  while IFS=$'\t' read -r name ppath; do print -r -- "$name  ($ppath)"; (( n++ )); done < <(list_projects)
  (( n )) || print "No projects found. List folders in: $SUPPORT/projects.conf (one per line)"
}

cmd_agents() {
  local a bin
  for a in ${(k)PROGRAM}; do
    bin=$(find_bin ${PROGRAM[$a]})
    print -r -- "$a  ${bin:-(not installed)}${RESUME[$a]:+  [resume]}"
  done | /usr/bin/sort
}

resolve_project() {  # name or existing folder → ppath (fails if the name is missing or ambiguous)
  local want=$1 name ppath found=()
  [[ $want == "~/"* ]] && want="$HOME/${want#\~/}"
  if [[ $want == /* ]]; then [[ -d $want ]] && { print -r -- $want; return 0; }; return 1; fi
  while IFS=$'\t' read -r name ppath; do [[ $name == "$want" ]] && found+=($ppath); done < <(list_projects)
  (( $#found == 1 )) || { (( $#found > 1 )) && print -ru2 -- "cocaine remote: '$want' matches more than one folder: ${(j:, :)found}"; return 1; }
  print -r -- $found[1]
}

cmd_start() {
  local resume=0 agent=${1:-} proj=${2:-} prompt=
  [[ -n $agent && -n $proj ]] || die "usage: start <agent> <project> [--resume] [prompt…]"
  shift 2
  [[ ${1:-} == --resume ]] && { resume=1; shift; }
  [[ ${1:-} == -- ]] && shift
  prompt=${*//$'\n'/ }
  [[ $prompt == -* ]] && die "the prompt can't start with '-' (the agent would read it as an option)"
  agent=${agent:l}; [[ $agent == cursor-agent ]] && agent=cursor
  [[ -n ${PROGRAM[$agent]:-} ]] || die "unknown agent '$agent' (known: ${(kj:, :)PROGRAM})"
  local ppath; ppath=$(resolve_project "$proj") || die "project '$proj' not found (see: cocaine remote projects)"
  local bin; bin=$(find_bin ${PROGRAM[$agent]})
  [[ -n $bin ]] || die "$agent is not installed for this user"
  reconcile

  local argv=($bin)
  if (( resume )); then
    [[ -n ${RESUME[$agent]:-} ]] || die "resuming isn't supported for $agent (start it without --resume)"
    argv+=(${=RESUME[$agent]})
  fi
  local typed=
  if [[ -n $prompt ]]; then
    if (( ${PROMPT_ARG[(Ie)$agent]} )) && (( ! resume )); then argv+=("$prompt"); else typed=$prompt; fi
  fi

  local base=$(safe_name "$agent-${ppath:t}"); base=${base[1,40]}; local id
  id=$base; local n=1
  while [[ -d $RUNS/$id ]]; do id=$base-$(( ++n )); done

  if ! cocaine_on; then
    "$ENGINE" on || die "could not turn Cocaine on"
    [[ -f $SUPPORT/restore ]] || : > "$SUPPORT/restore"      # it was off: put it back when the work ends
  fi

  mkdir -m 700 "$RUNS/$id"
  { print -r -- "agent=$agent"; print -r -- "project=${ppath:t}"; print -r -- "ppath=$ppath"; print -r -- "started=$(date +%s)"; } > "$RUNS/$id/meta"
  print -rl -- "${argv[@]}" > "$RUNS/$id/argv"
  "${SCREEN[@]}" -dmS "cocaine-$id" /bin/zsh -l "$HERE/remote.zsh" _run "$id"
  local i; for i in {1..30}; do session_alive $id && break; /bin/sleep 0.1; done
  session_alive $id || { finish_run $id failed; die "could not start the screen session"; }
  [[ -n $typed ]] && ( /bin/sleep 7; cmd_send "$id" "$typed" >/dev/null 2>&1 ) &!
  print -r -- "started $id: $agent in ${ppath:t}$( (( resume )) && print ' (resuming)' )"
  print -r -- "follow it with: cocaine remote log $id"
}

# Runs inside the screen session
cmd__run() {
  local id=$1 dir=$RUNS/$1
  local ppath=$(meta_get $id ppath)
  cd "$ppath" 2>/dev/null || cd ~
  export COCAINE_RUN=$id
  local argv=("${(@f)$(<$dir/argv)}")
  "${argv[@]}"
  local rc=$?
  print -r -- "$rc" > "$dir/exit"
  print -r -- $'\n[cocaine] '"${argv[1]:t} ended (exit $rc)"
  /bin/sleep 0.4
  "${SCREEN[@]}" -S "$STY" -p 0 -X hardcopy -h "$dir/final.log" 2>/dev/null
  /bin/sleep 0.6
  finish_run $id exit
}

cmd_runs() {
  reconcile
  local any=0 id state
  for id in $(run_ids); do
    any=1
    if run_done $id; then state="finished $(ago $(cut -d' ' -f2 $RUNS/$id/done))"; else state="running $(ago $(meta_get $id started))"; fi
    print -r -- "$id  $(meta_get $id agent)  $(meta_get $id project)  $state"
  done
  (( any )) || print "No runs."
}

cmd_log() {
  need_run ${1:-}
  local id=$1 lines=${2:-40} tmp=$(mktemp -t cocaine-log)
  if session_alive $id; then
    sx $id hardcopy -h "$tmp"; /bin/sleep 0.4
  elif [[ -f $RUNS/$id/final.log ]]; then cp "$RUNS/$id/final.log" "$tmp"
  else rm -f "$tmp"; die "no output kept for $id"; fi
  /usr/bin/sed -e 's/[[:space:]]*$//' "$tmp" | /usr/bin/awk 'NF {if (!first) first=NR; last=NR} {l[NR]=$0} END {for (i=first;i<=last;i++) print l[i]}' | /usr/bin/tail -n $lines
  rm -f "$tmp"
}

cmd_send() {
  need_run ${1:-}
  local id=$1; shift
  session_alive $id || die "$id is not running"
  local tmp=$(mktemp -t cocaine-send); print -rn -- "$*" > "$tmp"
  sx $id readbuf "$tmp"
  sx $id paste .
  /bin/sleep 0.5
  sx $id stuff $'\r'
  rm -f "$tmp"
  print "sent to $id"
}

cmd_key() {
  need_run ${1:-}
  local id=$1 k=${2:l} s
  session_alive $id || die "$id is not running"
  case $k in
    enter|return) s=$'\r' ;; esc|escape) s=$'\e' ;; tab) s=$'\t' ;; ctrl-c) s=$'\003' ;; ctrl-d) s=$'\004' ;;
    up) s=$'\e[A' ;; down) s=$'\e[B' ;; right) s=$'\e[C' ;; left) s=$'\e[D' ;; space) s=' ' ;;
    [a-z0-9]) s=$k ;;
    *) die "unknown key '$2' (enter esc tab space up down left right ctrl-c ctrl-d or one letter/digit)" ;;
  esac
  sx $id stuff "$s"
  print "sent $k to $id"
}

cmd_attach() { need_run ${1:-}; session_alive $1 || die "$1 is not running"; exec "${SCREEN[@]}" -r "$(session_full $1)"; }

cmd_stop() {
  need_run ${1:-}
  local id=$1
  if session_alive $id; then
    sx $id hardcopy -h "$RUNS/$id/final.log"; /bin/sleep 0.3
    sx $id quit
  fi
  finish_run $id stopped
  print "stopped $id"
}

cmd_wake_info() {
  local host if mac ip
  host=$(/usr/sbin/scutil --get LocalHostName 2>/dev/null)
  if=$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/ {print $2}')
  mac=$(/sbin/ifconfig "$if" 2>/dev/null | /usr/bin/awk '/ether / {print $2}')
  ip=$(/usr/sbin/ipconfig getifaddr "$if" 2>/dev/null)
  print -r -- "Host:        ${host:-?}.local"
  print -r -- "Interface:   ${if:-?}   MAC: ${mac:-?}   IP: ${ip:-?}"
  print -r -- "Wake for network access (womp): $(/usr/bin/pmset -g | /usr/bin/awk '/womp/ {print $2}')"
  print -r -- "Remote Login (SSH): $(/usr/bin/nc -z 127.0.0.1 22 2>/dev/null && print on || print off — turn on in System Settings → General → Sharing)"
  print ""
  print "Keeping Cocaine on is the reliable way to stay reachable (the lid can stay closed). A Mac that has gone to"
  print "sleep can be woken only from the same network: with a Wake-on-LAN app (use the MAC above), or by opening"
  print "its shared services if a Sleep Proxy (Apple TV, HomePod, some routers) is on the network. Over the internet,"
  print "use a VPN such as Tailscale to your home network first."
}

cmd_notify() {
  case ${1:-} in
    shortcut) [[ -n ${2:-} ]] || die "usage: notify shortcut \"Shortcut name\""
              /usr/bin/defaults write "$DOMAIN" phoneShortcut -string "$2"; print "Alerts will run the Shortcut \"$2\" (it gets the alert text as input)." ;;
    ntfy)     [[ ${2:-} == https://* ]] || die "usage: notify ntfy https://ntfy.sh/your-secret-topic"
              /usr/bin/defaults write "$DOMAIN" phoneNtfy -string "$2"; print "Alerts will be posted to $2 (the text leaves this Mac)." ;;
    off)      /usr/bin/defaults delete "$DOMAIN" phoneShortcut 2>/dev/null; /usr/bin/defaults delete "$DOMAIN" phoneNtfy 2>/dev/null; print "Phone alerts off." ;;
    test)     pgrep -qx Cocaine || die "open Cocaine first (a closed Cocaine can't send it)"
              /usr/bin/open -g "cocaine://alert?from=Cocaine&message=Test&test=phone&token=$(/usr/bin/defaults read "$DOMAIN" testToken 2>/dev/null)"; print "Test sent." ;;
    *)        die "usage: notify shortcut \"Name\" | ntfy https://… | off | test" ;;
  esac
}

sub=${1:-help}; (( $# )) && shift
case $sub in
  status) cmd_status "$@" ;;
  on) cmd_on "$@" ;;
  off) cmd_off ;;
  projects) cmd_projects ;;
  agents) cmd_agents ;;
  start) cmd_start "$@" ;;
  resume) cmd_start "${1:-}" "${2:-}" --resume "${@:3}" ;;
  _run) cmd__run "$@" ;;
  runs) cmd_runs ;;
  log) cmd_log "$@" ;;
  send) cmd_send "$@" ;;
  key) cmd_key "$@" ;;
  attach) cmd_attach "$@" ;;
  stop) cmd_stop "$@" ;;
  wake-info) cmd_wake_info ;;
  notify) cmd_notify "$@" ;;
  help|-h|--help) /usr/bin/sed -n '2,25p' "${0:A}" | /usr/bin/sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$sub' (try: cocaine remote help)" ;;
esac
