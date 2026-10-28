#!/usr/bin/env bash
# Usage: ./time_query.sh <database> <query.sql> [runs]
# Runs the query once to warm the cache, then <runs> timed runs (default 3).
# Prints each run in ms, the median, and rows read (sum of Handler_read_* counters).
# Connection: set MYSQL_CMD if you need a user/password, e.g.
#   export MYSQL_CMD="mysql -u root -pYourPassword"      (or use ~/.my.cnf)
set -euo pipefail
DB=$1; FILE=$2; RUNS=${3:-3}
MYSQL=${MYSQL_CMD:-mysql}
SQL=$(sed -e 's/;[[:space:]]*$//' "$FILE")          # strip trailing semicolon

$MYSQL "$DB" -e "$SQL" > /dev/null                  # warm-up run (not timed)

TIMES=()
for i in $(seq 1 "$RUNS"); do
  T=$($MYSQL "$DB" -N -e "SET @t := NOW(6); $SQL; SELECT TIMESTAMPDIFF(MICROSECOND, @t, NOW(6)) / 1000;" | tail -1)
  TIMES+=("$T")
done
ROWS=$($MYSQL "$DB" -N -e "FLUSH STATUS; $SQL; SHOW SESSION STATUS LIKE 'Handler_read%';" \
       | awk -F'\t' '$1 ~ /^Handler_read/ {s += $2} END {print s}')
MEDIAN=$(printf '%s\n' "${TIMES[@]}" | sort -n | awk '{a[NR]=$1} END {print (NR%2 ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2)}')
printf '%-22s runs_ms=[%s]  median_ms=%s  rows_read=%s\n' "$(basename "$FILE")" "${TIMES[*]}" "$MEDIAN" "$ROWS" | tee -a timings.txt
