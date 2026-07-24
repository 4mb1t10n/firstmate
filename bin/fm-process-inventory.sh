#!/usr/bin/env bash
# Read-only ownership inventory for heavy crew child processes.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
OLD_SECS=${FM_PROCESS_OLD_SECS:-21600}
MAX_ROWS=${FM_PROCESS_MAX_ROWS:-200}

case "$OLD_SECS" in ''|*[!0-9]*|0) printf 'fm-process-inventory: FM_PROCESS_OLD_SECS must be positive\n' >&2; exit 2 ;; esac
case "$MAX_ROWS" in ''|*[!0-9]*|0) printf 'fm-process-inventory: FM_PROCESS_MAX_ROWS must be positive\n' >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { printf 'fm-process-inventory: jq not found\n' >&2; exit 1; }

tasks='[]'
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  worktree=$(awk -F= '$1=="worktree" {sub(/^[^=]*=/,""); print; exit}' "$meta")
  [ -n "$worktree" ] || continue
  tasks=$(printf '%s' "$tasks" | jq --arg id "$id" --arg worktree "$worktree" \
    '. + [{id:$id,worktree:$worktree}]')
done

rows='[]'
if [ "$(uname)" = Linux ]; then
  process_table=$(ps -eo pid=,ppid=,etimes=,comm=,args= 2>/dev/null \
    | awk -v OFS='\t' '{
        pid=$1; ppid=$2; age=$3; command=$4;
        $1=$2=$3=$4="";
        sub(/^[[:space:]]+/, "", $0);
        print pid,ppid,age,command,$0
      }')
else
  # BSD ps has no numeric elapsed-seconds field.
  # Keep ownership and class visibility, but conservatively avoid declaring a
  # process old when its age cannot be proven from this portable read.
  process_table=$(ps -eo pid=,ppid=,comm=,args= 2>/dev/null \
    | awk -v OFS='\t' '{
        pid=$1; ppid=$2; command=$3;
        $1=$2=$3="";
        sub(/^[[:space:]]+/, "", $0);
        print pid,ppid,0,command,$0
      }')
fi
while IFS=$(printf '\t') read -r pid ppid age command args; do
  case "$pid:$ppid:$age" in
    *[!0-9:]*|::*|:*:) continue ;;
  esac
  class=
  case "$command $args" in
    *chrome-devtools-mcp*) class=devtools ;;
    *"/opt/google/chrome/chrome"*|*" google-chrome "*) class=chrome ;;
    *cypress*) class=cypress ;;
    *next-server*|*"next dev"*|*"next start"*) class=next ;;
    *) continue ;;
  esac
  owner=$(printf '%s' "$tasks" | jq -r --arg args "$args" '
    [.[] | select(($args | contains(.worktree)))] | if length == 1 then .[0].id else "" end
  ')
  owned=false
  [ -n "$owner" ] && owned=true
  old=false
  [ "$age" -ge "$OLD_SECS" ] && old=true
  rows=$(printf '%s' "$rows" | jq \
    --argjson pid "$pid" \
    --argjson ppid "$ppid" \
    --argjson age "$age" \
    --arg class "$class" \
    --arg owner "$owner" \
    --argjson owned "$owned" \
    --argjson old "$old" \
    '. + [{pid:$pid,ppid:$ppid,age_seconds:$age,class:$class,owner:$owner,owned:$owned,old:$old}]')
done <<EOF
$process_table
EOF

printf '%s' "$rows" | jq --argjson tasks "$tasks" --argjson max "$MAX_ROWS" '
  {
    tasks:$tasks,
    counts:{
      total:length,
      owned:([.[] | select(.owned)] | length),
      unowned:([.[] | select(.owned | not)] | length),
      old_unowned:([.[] | select((.owned | not) and .old)] | length),
      chrome:([.[] | select(.class == "chrome")] | length),
      cypress:([.[] | select(.class == "cypress")] | length),
      devtools:([.[] | select(.class == "devtools")] | length),
      next:([.[] | select(.class == "next")] | length)
    },
    old_unowned:([.[] | select((.owned | not) and .old)][0:$max]),
    truncated:(([.[] | select((.owned | not) and .old)] | length) > $max)
  }
'
