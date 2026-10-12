#!/usr/bin/env bash
# Tests for study-planner. Run: bash test.sh
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)/study-planner.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf 'FAIL %s\n%s\n' "$1" "${2:-}"; }

# deterministic fixture: --from 2026-11-20
# Kalkulus  2026-12-15 d=4 -> 25 days, urgency .16
# Fisika    2026-12-10 d=5 -> 20 days, urgency .25
# Algoritma 2026-12-20 d=3 -> 30 days, urgency .10
# weights: K .3137 F .4902 A .1961 ; daily=120
# per-day: K 38, F 59, A 24
cat > "$TMP/courses.csv" <<'EOF'
name,exam_date,difficulty
Kalkulus,2026-12-15,4
Fisika Dasar,2026-12-10,5
Algoritma,2026-12-20,3
EOF

# 1. basic run
out="$("$BIN" "$TMP/courses.csv" --from 2026-11-20 2>"$TMP/e1")"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q "STUDY PLAN" \
   && printf '%s' "$out" | grep -q "Fisika Dasar" \
   && printf '%s' "$out" | grep -q "DAILY SCHEDULE"; then ok "basic run"; else no "basic run" "rc=$rc out=$out"; fi

# 2. per-day math (Fisika Dasar -> 59)
perday="$(printf '%s' "$out" | grep '^Fisika Dasar' | awk '{print $NF}')"
if [ "$perday" = "59" ]; then ok "per-day math"; else no "per-day math" "got perday=$perday"; fi

# 3. --json valid + keys
jout="$("$BIN" "$TMP/courses.csv" --from 2026-11-20 --json 2>/dev/null)"; rc=$?
jcheck="$(printf '%s' "$jout" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert d['from']=='2026-11-20' and d['daily_minutes']==120
c={x['name']:x for x in d['courses']}
assert c['Fisika Dasar']['per_day_minutes']==59, c['Fisika Dasar']
assert c['Kalkulus']['days_left']==25
assert len(d['schedule'])==30 and d['schedule'][0]['date']=='2026-11-20'
assert len(d['schedule'][0]['items'])>0
print('JSON-OK')")"
if [ $rc -eq 0 ] && [ "$jcheck" = "JSON-OK" ]; then ok "--json"; else no "--json" "rc=$rc check=$jcheck"; fi

# 4. stdin input
sout="$(cat "$TMP/courses.csv" | "$BIN" --from 2026-11-20 2>/dev/null)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$sout" | grep -q "Algoritma"; then ok "stdin"; else no "stdin" "rc=$rc"; fi

# 5. --log subtracts logged minutes
cat > "$TMP/log.csv" <<'EOF'
date,course,minutes
2026-11-20,Kalkulus,45
2026-11-21,Kalkulus,30
2026-11-21,Fisika Dasar,60
EOF
lout="$("$BIN" "$TMP/courses.csv" --from 2026-11-20 --log "$TMP/log.csv" 2>/dev/null)"; rc=$?
klogged="$(printf '%s' "$lout" | grep '^Kalkulus' | awk '{print $4}')"
kremain="$(printf '%s' "$lout" | grep '^Kalkulus' | awk '{print $6}')"
# planned Kalkulus = round(.3137*120*25)=941 ; remain = 941-75=866
if [ $rc -eq 0 ] && [ "$klogged" = "75" ] && [ "$kremain" = "866" ]; then ok "--log"; else no "--log" "rc=$rc logged=$klogged remain=$kremain"; fi

# 6. empty input -> exit 1
"$BIN" --from 2026-11-20 < /dev/null >/dev/null 2>"$TMP/e6"; rc=$?
if [ $rc -eq 1 ] && grep -q "no usable courses" "$TMP/e6"; then ok "empty input"; else no "empty input" "rc=$rc"; fi

# 7. bad date -> exit 1
printf 'name,exam_date,difficulty\nKalkulus,2026-12-15,4\nX,not-a-date,3\n' > "$TMP/baddate.csv"
"$BIN" "$TMP/baddate.csv" --from 2026-11-20 >/dev/null 2>"$TMP/e7"; rc=$?
if [ $rc -eq 1 ] && grep -q "invalid date" "$TMP/e7"; then ok "bad date"; else no "bad date" "rc=$rc"; fi

# 8. bad difficulty -> exit 1
printf 'name,exam_date,difficulty\nX,2026-12-15,9\n' > "$TMP/baddiff.csv"
"$BIN" "$TMP/baddiff.csv" --from 2026-11-20 >/dev/null 2>"$TMP/e8"; rc=$?
if [ $rc -eq 1 ] && grep -q "difficulty" "$TMP/e8"; then ok "bad difficulty"; else no "bad difficulty" "rc=$rc"; fi

# 9. missing file -> exit 1
"$BIN" "$TMP/does-not-exist.csv" >/dev/null 2>"$TMP/e9"; rc=$?
if [ $rc -eq 1 ] && grep -q "not found" "$TMP/e9"; then ok "missing file"; else no "missing file" "rc=$rc"; fi

# 10. unknown flag -> exit 2
"$BIN" --frobnicate >/dev/null 2>&1; rc=$?
if [ $rc -eq 2 ]; then ok "unknown flag exit 2"; else no "unknown flag exit 2" "rc=$rc"; fi

# 11. --help
"$BIN" --help >"$TMP/h" 2>&1; rc=$?
if [ $rc -eq 0 ] && grep -q "Usage" "$TMP/h"; then ok "--help"; else no "--help" "rc=$rc"; fi

# 12. --version
vout="$("$BIN" --version 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [ "$vout" = "study-planner 1.0.0" ]; then ok "--version"; else no "--version" "got=$vout rc=$rc"; fi

# 13. NO_COLOR strips ANSI
NO_COLOR=1 "$BIN" "$TMP/courses.csv" --from 2026-11-20 >"$TMP/nc" 2>/dev/null
if grep -q $'\033' "$TMP/nc"; then no "NO_COLOR" "found ANSI escapes"; else ok "NO_COLOR"; fi

# 14. streaming: 100k-line log processes fast with correct totals
python3 - "$TMP/biglog.csv" <<'EOF'
import sys
courses = ["Kalkulus", "Fisika Dasar", "Algoritma"]
with open(sys.argv[1], "w") as f:
    f.write("date,course,minutes\n")
    for i in range(100000):
        f.write(f"2026-11-{(i % 28) + 1:02d},{courses[i % 3]},10\n")
EOF
start=$(date +%s)
bout="$("$BIN" "$TMP/courses.csv" --from 2026-11-20 --log "$TMP/biglog.csv" 2>/dev/null)"; rc=$?
dur=$(( $(date +%s) - start ))
# i%3==0 -> 33334 lines -> 333340 minutes for Kalkulus
kbig="$(printf '%s' "$bout" | grep '^Kalkulus' | awk '{print $4}')"
if [ $rc -eq 0 ] && [ "$kbig" = "333340" ] && [ "$dur" -lt 30 ]; then ok "streaming 100k log"; else no "streaming 100k log" "rc=$rc logged=$kbig dur=${dur}s"; fi

# 15. past exam skipped with warning, exit 0
printf 'name,exam_date,difficulty\nLama,2026-11-01,3\nKalkulus,2026-12-15,4\n' > "$TMP/past.csv"
pout="$("$BIN" "$TMP/past.csv" --from 2026-11-20 2>"$TMP/e15")"; rc=$?
if [ $rc -eq 0 ] && ! printf '%s' "$pout" | grep -q "^Lama" && grep -q "today or past" "$TMP/e15"; then ok "past exam skipped"; else no "past exam skipped" "rc=$rc"; fi

# 16. e2e full pipeline: courses + log + json, schedule sane
eout="$("$BIN" "$TMP/courses.csv" --from 2026-11-20 --log "$TMP/log.csv" --json 2>/dev/null)"
echeck="$(printf '%s' "$eout" | python3 -c "
import json,sys
d=json.load(sys.stdin)
last=d['schedule'][-1]
assert last['date']=='2026-12-19', last['date']
assert len(last['items'])==1 and last['items'][0]['course']=='Algoritma', last
print('E2E-OK')")"
if [ "$echeck" = "E2E-OK" ]; then ok "e2e full pipeline"; else no "e2e full pipeline" "$echeck"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
