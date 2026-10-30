#!/usr/bin/env bash
# Usage: ./compare_results.sh [oltp_db] [dw_db]
# Runs every OLTP query and its star-schema twin, sorts both outputs, and diffs them.
# Defaults: healthtech_oltp_big vs healthtech_dw.  Output files go to results/.
set -uo pipefail
OLTP=${1:-healthtech_oltp_big}; DW=${2:-healthtech_dw}
MYSQL=${MYSQL_CMD:-mysql}
mkdir -p results
check () {   # $1 = oltp query file, $2 = star query file
  $MYSQL "$OLTP" -N < "queries/$1" | sort > "results/${1%.sql}.txt"
  $MYSQL "$DW"   -N < "queries/$2" | sort > "results/${2%.sql}.txt"
  if diff -q "results/${1%.sql}.txt" "results/${2%.sql}.txt" > /dev/null; then
    echo "PASS  $2 matches $1 ($(wc -l < "results/${2%.sql}.txt") rows)"
  else
    echo "FAIL  $2 differs from $1 -- see: diff results/${1%.sql}.txt results/${2%.sql}.txt"
  fi
}
check oltp_q1.sql star_q1.sql
check oltp_q2.sql star_q2.sql
check oltp_q2.sql star_q2_agg.sql
check oltp_q3.sql star_q3.sql
check oltp_q4.sql star_q4.sql
