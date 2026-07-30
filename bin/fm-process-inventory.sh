#!/usr/bin/env bash
# Read-only ownership inventory for heavy crew child processes.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
OLD_SECS=${FM_PROCESS_OLD_SECS:-21600}
MAX_ROWS=${FM_PROCESS_MAX_ROWS:-200}
CAPTAIN_PID=

case "$OLD_SECS" in ''|*[!0-9]*|0) printf 'fm-process-inventory: FM_PROCESS_OLD_SECS must be positive\n' >&2; exit 2 ;; esac
case "$MAX_ROWS" in ''|*[!0-9]*|0) printf 'fm-process-inventory: FM_PROCESS_MAX_ROWS must be positive\n' >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { printf 'fm-process-inventory: jq not found\n' >&2; exit 1; }
if [ -s "$STATE/.lock" ]; then
  CAPTAIN_PID=$(tr -d '[:space:]' < "$STATE/.lock")
  case "$CAPTAIN_PID" in ''|*[!0-9]*) CAPTAIN_PID= ;; esac
fi

tasks='[]'
task_ids=()
task_worktrees=()
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  worktree=$(awk -F= '$1=="worktree" {sub(/^[^=]*=/,""); print; exit}' "$meta")
  [ -n "$worktree" ] || continue
  tasks=$(printf '%s' "$tasks" | jq --arg id "$id" --arg worktree "$worktree" \
    '. + [{id:$id,worktree:$worktree}]')
  task_ids+=("$id")
  task_worktrees+=("$worktree")
done
task_count=${#task_ids[@]}

# The whole table is read once and resolved in one awk pass. Rebuilding the args
# column by clearing fields would re-join argv with OFS, so the args string is
# taken verbatim from the tail of the line: `next dev` must stay `next dev`.
# A jq fork per matching process would also re-serialize the whole array each
# time, and Chrome alone routinely contributes dozens of rows per tick.
if [ "$(uname)" = Linux ]; then
  process_table=$(ps -eo pid=,ppid=,etimes=,comm=,args= 2>/dev/null \
    | awk -v OFS='\t' '{
        pid=$1; ppid=$2; age=$3; command=$4;
        args=$0;
        sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]*/, "", args);
        print "R",pid,ppid,age,command,args
      }')
else
  # BSD ps has no numeric elapsed-seconds field.
  # Keep ownership and class visibility, but conservatively avoid declaring a
  # process old when its age cannot be proven from this portable read.
  process_table=$(ps -eo pid=,ppid=,comm=,args= 2>/dev/null \
    | awk -v OFS='\t' '{
        pid=$1; ppid=$2; command=$3;
        args=$0;
        sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]*/, "", args);
        print "R",pid,ppid,0,command,args
      }')
fi

# Ownership resolution walks the parent chain, so the task rows are fed into the
# same awk pass as the process table rather than matched row by row in shell.
emit_task_rows() {
  local i=0
  while [ "$i" -lt "$task_count" ]; do
    printf 'T\t%s\t%s\n' "${task_ids[$i]}" "${task_worktrees[$i]}"
    i=$((i + 1))
  done
}

rows=$({ emit_task_rows; printf '%s\n' "$process_table"; } | awk -F'\t' -v OFS='\t' \
  -v old_secs="$OLD_SECS" -v selfpid="$$" -v captain_pid="$CAPTAIN_PID" -v fm_bin="$FM_HOME/bin/" '
  function classify(s) {
    if (index(s, "chrome-devtools-mcp") > 0) return "devtools"
    if (index(s, "/opt/google/chrome/chrome") > 0 || s ~ /(^|\/| )google-chrome( |$)/) return "chrome"
    if (index(s, "cypress") > 0) return "cypress"
    if (index(s, "next-server") > 0 || index(s, "next dev") > 0 || index(s, "next start") > 0) return "next"
    return ""
  }
  # Sets MATCHES as a side effect: awk has no tuple return and the caller needs
  # to tell "one owner" from "several plausible owners".
  function owner_of(p,   i, s, o) {
    MATCHES = 0; o = ""
    s = comm_of[p] " " args_of[p]
    for (i = 0; i < nt; i++) {
      if (worktree[i] != "" && index(s, worktree[i]) > 0) { MATCHES++; o = task[i] }
    }
    return o
  }
  # A crew child usually carries the worktree path only on the crew leader, so
  # ownership is inherited from the nearest resolvable ancestor. An unresolved
  # or multiply-matched chain is ambiguous, never unowned: only a chain proven
  # to belong to nobody may be offered for cleanup.
  function resolve(p,   hops, cur, o) {
    cur = p
    for (hops = 0; hops < 64; hops++) {
      o = owner_of(cur)
      if (MATCHES > 1) { KIND = "ambiguous"; return "" }
      if (MATCHES == 1) { KIND = "owned"; return o }
      if (!(cur in parent)) break
      cur = parent[cur]
      if (cur == "" || cur == "0" || cur == "1" || !(cur in parent)) break
    }
    KIND = "unowned"
    return ""
  }
  # The captain pane, this reconciliation own ancestry, and the supervision
  # plane are never cleanup candidates regardless of worktree ownership.
  # Only this home command surface is protected, not the whole home: crew
  # worktrees live under it, and protecting those would silently retire the
  # cleanup surface entirely.
  function protected(p,   hops, cur, s) {
    cur = p
    for (hops = 0; hops < 64; hops++) {
      if (captain_valid && cur == captain_pid) return 1
      if (cur in supervision) return 1
      s = comm_of[cur] " " args_of[cur]
      if (s ~ /fm-supervise-daemon|fm-afk-|fm-watch|\/bin\/fm-[A-Za-z0-9_-]+\.sh/) return 1
      if (fm_bin != "" && index(s, fm_bin) > 0) return 1
      if (!(cur in parent)) break
      cur = parent[cur]
      if (cur == "" || cur == "0" || cur == "1") break
    }
    return 0
  }
  # An uninitialized awk counter subscripts an array as "" rather than 0, which
  # would silently drop the first task and the first process row.
  BEGIN { nt = 0; n = 0 }
  $1 == "T" { task[nt] = $2; worktree[nt] = $3; nt++; next }
  $1 == "R" {
    if ($2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/) next
    parent[$2] = $3
    age_of[$2] = $4
    comm_of[$2] = $5
    args_of[$2] = $6
    order[n++] = $2
    next
  }
  END {
    captain_valid = 0
    if (captain_pid ~ /^[0-9]+$/ && captain_pid in parent) {
      s = comm_of[captain_pid] " " args_of[captain_pid]
      if (s ~ /(^|[^A-Za-z0-9])(claude|codex|opencode|grok|pi)([^A-Za-z0-9]|$)/) captain_valid = 1
    }
    for (cur = selfpid; cur != "" && cur != "0" && cur != "1"; ) {
      supervision[cur] = 1
      if (!(cur in parent)) break
      cur = parent[cur]
    }
    for (i = 0; i < n; i++) {
      p = order[i]
      class = classify(comm_of[p] " " args_of[p])
      if (class == "") continue
      if (protected(p)) { kind = "protected"; owner = "" }
      else { owner = resolve(p); kind = KIND }
      print p, parent[p], age_of[p] + 0, class, owner, kind, (age_of[p] + 0 >= old_secs ? "true" : "false")
    }
  }
')

printf '%s\n' "$rows" | jq -R -s --argjson tasks "$tasks" --argjson max "$MAX_ROWS" '
  [
    split("\n")[]
    | select(length > 0)
    | split("\t")
    | {
        pid:(.[0] | tonumber),
        ppid:(.[1] | tonumber),
        age_seconds:(.[2] | tonumber),
        class:.[3],
        owner:.[4],
        ownership:.[5],
        owned:(.[5] == "owned"),
        old:(.[6] == "true")
      }
  ]
  | ([.[] | select(.ownership == "unowned" and .old)]) as $candidates
  | {
    tasks:$tasks,
    counts:{
      total:length,
      owned:([.[] | select(.ownership == "owned")] | length),
      unowned:([.[] | select(.ownership == "unowned")] | length),
      ambiguous:([.[] | select(.ownership == "ambiguous")] | length),
      protected:([.[] | select(.ownership == "protected")] | length),
      old_unowned:($candidates | length),
      chrome:([.[] | select(.class == "chrome")] | length),
      cypress:([.[] | select(.class == "cypress")] | length),
      devtools:([.[] | select(.class == "devtools")] | length),
      next:([.[] | select(.class == "next")] | length)
    },
    old_unowned:($candidates[0:$max]),
    truncated:(($candidates | length) > $max)
  }
'
