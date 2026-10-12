#!/usr/bin/env bash
# study-planner - generate a weighted daily study schedule from a course list.
# Reads courses (name,exam_date,difficulty) and an optional session log,
# allocates daily minutes per course by urgency, prints a per-day schedule.
set -euo pipefail

VERSION="1.0.0"
PROG="study-planner"

err()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
note() { printf '%s: note: %s\n' "$PROG" "$*" >&2; }

usage() {
  cat <<EOF
Usage: $PROG [OPTIONS] [COURSES.csv]

Generate a daily study schedule from a list of courses and exam dates.

COURSES.csv format (header optional):
  name,exam_date,difficulty
  Kalkulus,2026-12-15,4

Options:
  --from DATE         plan start date (YYYY-MM-DD, default: today)
  --daily-minutes N   study minutes available per day (default: 120)
  --log FILE          session log CSV: date,course,minutes (may be huge;
                      processed streaming, one pass, low memory)
  --json              machine-readable JSON output
  --help              show this help and exit
  --version           show version and exit

Exit codes: 0 success, 1 runtime/data error, 2 bad arguments.

Examples:
  $PROG courses.csv --daily-minutes 90
  cat courses.csv | $PROG --from 2026-11-20 --log sessions.csv --json
EOF
}

# ---- argument parsing -------------------------------------------------------
FROM="$(date +%F)"
DAILY_MIN=120
LOG=""
JSON=0
COURSES=""

while [ $# -gt 0 ]; do
  case "$1" in
    --from)          FROM="${2:?}"; shift 2 ;;
    --from=*)        FROM="${1#--from=}"; shift ;;
    --daily-minutes) DAILY_MIN="${2:?}"; shift 2 ;;
    --daily-minutes=*) DAILY_MIN="${1#--daily-minutes=}"; shift ;;
    --log)           LOG="${2:?}"; shift 2 ;;
    --log=*)         LOG="${1#--log=}"; shift ;;
    --json)          JSON=1; shift ;;
    --help)          usage; exit 0 ;;
    --version)       printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
    --*)             err "unknown option: $1"; usage >&2; exit 2 ;;
    *)               if [ -n "$COURSES" ]; then err "only one courses file allowed"; exit 2; fi
                     COURSES="$1"; shift ;;
  esac
done

# ---- basic validation -------------------------------------------------------
if ! printf '%s' "$FROM" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
  err "--from must be YYYY-MM-DD, got: $FROM"; exit 2
fi
if ! printf '%s' "$DAILY_MIN" | grep -Eq '^[1-9][0-9]*$'; then
  err "--daily-minutes must be a positive integer, got: $DAILY_MIN"; exit 2
fi
if ! date -d "2000-01-01" +%s >/dev/null 2>&1; then
  err "GNU date is required (Linux and Termux are fine; on macOS: brew install coreutils)"; exit 1
fi
FROM_EPOCH="$(date -d "$FROM" +%s)" || { err "invalid --from date: $FROM"; exit 2; }
if [ -n "$COURSES" ] && [ ! -f "$COURSES" ]; then err "courses file not found: $COURSES"; exit 1; fi
if [ -n "$LOG" ] && [ ! -f "$LOG" ]; then err "log file not found: $LOG"; exit 1; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
NORM="$TMP/courses.tsv"   # name \t exam_date \t exam_epoch \t difficulty
TOTALS="$TMP/totals.tsv"  # name \t logged_minutes
: > "$NORM"; : > "$TOTALS"

# ---- normalize courses (file or stdin) --------------------------------------
INPUT="$COURSES"
[ -z "$INPUT" ] && INPUT="/dev/stdin"

lineno=0
skipped_header=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$line" ] && continue
  case "$line" in \#*) continue ;; esac
  name="$(printf '%s' "$line" | cut -d, -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  exam="$(printf '%s' "$line" | cut -d, -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  diff="$(printf '%s' "$line" | cut -d, -f3 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  # header detection: first line whose 2nd column is not a date
  if [ "$lineno" -eq 1 ] && [ "$skipped_header" -eq 0 ] \
     && ! printf '%s' "$exam" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    note "first line treated as header and skipped"
    skipped_header=1
    continue
  fi
  if [ -z "$name" ]; then err "line $lineno: empty course name"; exit 1; fi
  epoch="$(date -d "$exam" +%s 2>/dev/null)" || { err "line $lineno: invalid date '$exam' (use YYYY-MM-DD)"; exit 1; }
  [ -z "$diff" ] && diff=3
  if ! printf '%s' "$diff" | grep -Eq '^[1-5]$'; then
    err "line $lineno: difficulty must be 1-5, got '$diff'"; exit 1
  fi
  days_left=$(( (epoch - FROM_EPOCH) / 86400 ))
  if [ "$days_left" -le 0 ]; then
    warn "line $lineno: '$name' exam is today or past ($exam), skipped"
    continue
  fi
  if grep -qF "$(printf '%s\t' "$name")" "$NORM" 2>/dev/null; then
    err "line $lineno: duplicate course name '$name'"; exit 1
  fi
  printf '%s\t%s\t%s\t%s\n' "$name" "$exam" "$epoch" "$diff" >> "$NORM"
done < "$INPUT"

if [ ! -s "$NORM" ]; then
  err "no usable courses (empty input or all exams are today/past)"; exit 1
fi

# ---- stream the session log (one pass, constant memory) ----------------------
if [ -n "$LOG" ]; then
  awk -F',' '
    {
      gsub(/^[ \t]+|[ \t]+$/, "", $0)
      if ($0 == "" || substr($0, 1, 1) == "#") next
      nlines++
      c = $2; m = $3
      gsub(/^[ \t]+|[ \t]+$/, "", c); gsub(/^[ \t]+|[ \t]+$/, "", m)
      if (c == "" || m !~ /^[0-9]+$/) { bad++; next }
      tot[c] += m
    }
    END {
      for (c in tot) printf "%s\t%d\n", c, tot[c]
      if (bad > 0) printf "BAD\t%d\n", bad > "/dev/stderr"
    }
  ' "$LOG" > "$TOTALS" 2> "$TMP/logwarn"
  if grep -q '^BAD' "$TMP/logwarn" 2>/dev/null; then
    warn "$(sed 's/^BAD\t//' "$TMP/logwarn") malformed log line(s) skipped"
  fi
fi

# ---- color (only on TTY, honors NO_COLOR) -----------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then BOLD=$'\e[1m'; RESET=$'\e[0m'; else BOLD=""; RESET=""; fi

# ---- horizon + per-day date list (bash, so awk stays portable) ---------------
HORIZON=0
while IFS="$(printf '\t')" read -r _nm _ed epoch _df; do
  d=$(( (epoch - FROM_EPOCH) / 86400 ))
  [ "$d" -gt "$HORIZON" ] && HORIZON="$d"
done < "$NORM"
DATES="$TMP/dates.tsv"
: > "$DATES"
for ((d = 0; d < HORIZON; d++)); do
  printf '%d\t%s\n' "$d" "$(date -d "$FROM +$d days" +%F)" >> "$DATES"
done

# ---- main computation -------------------------------------------------------
awk -v from="$FROM" -v from_epoch="$FROM_EPOCH" -v daily="$DAILY_MIN" \
    -v json="$JSON" -v bold="$BOLD" -v reset="$RESET" -F'\t' '
  function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
  FILENAME == totals_file { logged[$1] = $2 + 0; next }
  FILENAME == norm_file {
    n++
    name[n] = $1; examd[n] = $2; epoch[n] = $3 + 0; diff[n] = $4 + 0
    next
  }
  FILENAME == dates_file { ddate[$1] = $2; ndays++; next }
  END {
    # urgency weights
    sum = 0
    for (i = 1; i <= n; i++) {
      days[i] = int((epoch[i] - from_epoch) / 86400)
      urg[i] = diff[i] / days[i]
      sum += urg[i]
    }
    for (i = 1; i <= n; i++) {
      w = urg[i] / sum
      target = w * daily * days[i]
      lg = (name[i] in logged) ? logged[name[i]] : 0
      rem = target - lg; if (rem < 0) rem = 0
      remaining[i] = rem
      perday[i] = rem / days[i]
    }

    if (json == 1) {
      printf "{\n  \"from\": \"%s\",\n  \"daily_minutes\": %d,\n  \"horizon_days\": %d,\n", from, daily, ndays
      printf "  \"courses\": [\n"
      for (i = 1; i <= n; i++) {
        lg = (name[i] in logged) ? logged[name[i]] : 0
        printf "    {\"name\": \"%s\", \"exam_date\": \"%s\", \"days_left\": %d, \"difficulty\": %d, \"logged_minutes\": %d, \"planned_minutes\": %.0f, \"per_day_minutes\": %.0f}%s\n", \
          jesc(name[i]), examd[i], days[i], diff[i], lg, remaining[i] + lg, perday[i], (i < n ? "," : "")
      }
      printf "  ],\n  \"schedule\": [\n"
      for (d = 0; d < ndays; d++) {
        printf "    {\"date\": \"%s\", \"items\": [", ddate[d]
        sep = ""
        for (i = 1; i <= n; i++) {
          if (days[i] > d && perday[i] >= 0.5) {
            printf "%s{\"course\": \"%s\", \"minutes\": %.0f}", sep, jesc(name[i]), perday[i]
            sep = ", "
          }
        }
        printf "]}%s\n", (d < ndays - 1 ? "," : "")
      }
      printf "  ]\n}\n"
      exit
    }

    printf "%sSTUDY PLAN%s  (from %s, %d min/day, %d courses)\n\n", bold, reset, from, daily, n
    printf "%sCOURSES%s\n", bold, reset
    printf "%-20s %-12s %5s %7s %8s %8s %7s\n", "course", "exam", "days", "logged", "planned", "remain", "per-day"
    printf "%-20s %-12s %5s %7s %8s %8s %7s\n", "--------------------", "------------", "-----", "-------", "--------", "--------", "-------"
    for (i = 1; i <= n; i++) {
      lg = (name[i] in logged) ? logged[name[i]] : 0
      printf "%-20.20s %-12s %5d %7d %8.0f %8.0f %7.0f\n", \
        name[i], examd[i], days[i], lg, remaining[i] + lg, remaining[i], perday[i]
    }
    printf "\n%sDAILY SCHEDULE%s\n", bold, reset
    for (d = 0; d < ndays; d++) {
      line = ddate[d] "  "
      sep = ""
      for (i = 1; i <= n; i++) {
        if (days[i] > d && perday[i] >= 0.5) {
          line = line sep name[i] " " sprintf("%.0f", perday[i]) "m"
          sep = ", "
        }
      }
      if (sep != "") print line
    }
  }
' totals_file="$TOTALS" norm_file="$NORM" dates_file="$DATES" \
  "$TOTALS" "$NORM" "$DATES"
