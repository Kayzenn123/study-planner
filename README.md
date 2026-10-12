# study-planner

> Generate a weighted daily study schedule from your course list and exam dates. Daily Tools #6.

## Why

Students usually keep exam dates in a spreadsheet and then guess how much to
study each day. Existing study planners (MyStudyLife, Notion templates) need
accounts, apps, or manual drag-and-drop scheduling, and the only other repo
named `study-planner` on GitHub (terriblepol/study-planner) is just a README
plus a history-generator script — not a planner at all. `study-planner` is
different: a zero-dependency bash CLI that works fully offline, reads your
courses from a CSV or stdin, auto-allocates your daily minutes across courses
by urgency (difficulty ÷ days left), subtracts what you already logged, and
prints a concrete day-by-day schedule. A session log of any size is processed
streaming (single awk pass, constant memory), so even a 100k-line log is fine.

## Install

```bash
git clone https://github.com/Kayzenn123/study-planner.git
cd study-planner
chmod +x study-planner.sh
# optional: make it available everywhere
ln -s "$PWD/study-planner.sh" ~/.local/bin/study-planner
```

Requires: Bash 4+, GNU date, awk. No dependencies.
(Linux and Termux are fine out of the box; on macOS: `brew install coreutils`.)

## Usage

```bash
study-planner.sh [OPTIONS] [COURSES.csv]
```

`COURSES.csv` format (header row optional):

```csv
name,exam_date,difficulty
Kalkulus,2026-12-15,4
Fisika Dasar,2026-12-10,5
```

If no file is given, courses are read from stdin.

| Flag | Function | Default |
| --- | --- | --- |
| `--from DATE` | plan start date (YYYY-MM-DD) | today |
| `--daily-minutes N` | study minutes available per day | 120 |
| `--log FILE` | session log CSV `date,course,minutes`; streamed, any size | none |
| `--json` | machine-readable JSON output | human table |
| `--help` | show help | — |
| `--version` | show version | — |

Exit codes: `0` success, `1` runtime/data error, `2` bad arguments.
Honors `NO_COLOR`; colors only when stdout is a TTY.

## Example output

Command:

```bash
./study-planner.sh examples/courses.csv --from 2026-11-20 --daily-minutes 90
```

Output (real, copied from an actual run):

```text
study-planner: note: first line treated as header and skipped
STUDY PLAN  (from 2026-11-20, 90 min/day, 4 courses)

COURSES
course               exam          days  logged  planned   remain per-day
-------------------- ------------ ----- ------- -------- -------- -------
Kalkulus             2026-12-15      25       0      580      580      23
Fisika Dasar         2026-12-10      20       0      725      725      36
Algoritma            2026-12-20      30       0      435      435      14
Bahasa Inggris       2026-12-08      18       0      290      290      16

DAILY SCHEDULE
2026-11-20  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-11-21  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-11-22  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-11-23  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-11-24  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-11-25  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-11-26  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-11-27  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-11-28  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-11-29  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-11-30  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-12-01  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-12-02  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-12-03  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-12-04  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-12-05  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-12-06  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-12-07  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m, Bahasa Inggris 16m
2026-12-08  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m
2026-12-09  Kalkulus 23m, Fisika Dasar 36m, Algoritma 14m
2026-12-10  Kalkulus 23m, Algoritma 14m
2026-12-11  Kalkulus 23m, Algoritma 14m
2026-12-12  Kalkulus 23m, Algoritma 14m
2026-12-13  Kalkulus 23m, Algoritma 14m
2026-12-14  Kalkulus 23m, Algoritma 14m
2026-12-15  Algoritma 14m
```

With a session log, logged minutes reduce the remaining workload:

```bash
./study-planner.sh examples/courses.csv --from 2026-11-20 --daily-minutes 90 --log examples/sessions.csv
```

```text
Kalkulus             2026-12-15      25      75      580      505      20
Fisika Dasar         2026-12-10      20      85      725      640      32
```

And `--json` gives the same plan machine-readable (courses + full schedule
array), suitable for piping into other tools.

## How it works

1. Courses are validated and normalized in bash (dates via GNU date); the
   session log is aggregated in one streaming awk pass — only per-course
   totals are kept, never the raw lines.
2. Each course gets an urgency score `difficulty / days_left`; its weight is
   urgency ÷ total urgency. `planned = weight × daily_minutes × days_left`;
   `remaining = max(planned − logged, 0)`; `per_day = remaining / days_left`.
3. The daily schedule lists every active course (exam not yet reached and
   remaining ≥ 0.5 min) with its rounded per-day minutes, until the last exam.
4. Courses whose exam is today or past are skipped with a warning; malformed
   log lines are skipped with a warning count.

## Limitations

- Requires GNU date (Linux and Termux work; macOS needs `brew install coreutils`).
- No quoted-CSV support: course names must not contain commas.
- The allocation is a simple urgency heuristic, not a pedagogical model; it
  does not know topic dependencies or your actual learning speed.
- Per-day minutes are rounded, so a day's total may differ from
  `--daily-minutes` by a few minutes.
- Log entries for courses not in the course list are ignored.
- Duplicate course names are rejected; names are matched exactly (case-sensitive).

## Development

```bash
bash test.sh   # 16 tests: unit, edge cases, e2e, and a 100k-line streaming log test
```

## License

MIT

---
Ringkasan (Bahasa Indonesia): study-planner adalah CLI bash tanpa dependensi yang membuat jadwal belajar harian dari daftar mata kuliah dan tanggal ujian — menit harian dibagi otomatis berdasarkan urgensi (kesulitan ÷ sisa hari), dikurangi menit yang sudah tercatat di log sesi. Log sebesar apa pun diproses secara streaming (satu pass awk, memori konstan). Cara pakai: `./study-planner.sh courses.csv --daily-minutes 90 --log sessions.csv`, dengan output tabel manusia atau `--json` untuk mesin. Batasan utama: butuh GNU date, nama MK tidak boleh mengandung koma, dan alokasinya heuristik sederhana bukan model pedagogis.
