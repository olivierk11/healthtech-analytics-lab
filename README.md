# Healthcare Analytics Lab: OLTP to Star Schema

A normalized (3NF) clinical database is redesigned as a star schema for analytics. The lab has four parts:

1. Four business questions are written and timed against the OLTP schema.
2. Their bottlenecks are diagnosed.
3. A dimensional model is designed, built and loaded with a tested ETL.
4. The same questions are re-run against the warehouse.

Every star-schema query returns exactly the same rows as its OLTP version, and runs **3.7x to 63x faster** on MySQL 8 (7x to 107x on a MariaDB reference server). The question with a pre-aggregated table runs **over 100,000x faster**.

| Question | OLTP | Star schema | Speedup | Reference (MariaDB) | Main reason |
|---|---|---|---|---|---|
| Q1 Monthly encounters by specialty | 11.22 s | 2.52 s | 4.5x | 4.52 → 0.64 s (7.0x) | Specialty stored on the fact; covering index |
| Q2 Top diagnosis–procedure pairs (bridges) | 136.38 s | 36.55 s | 3.7x | 50.4 → 7.43 s (6.8x) | Bridges clustered on encounter_key, integer keys |
| Q2 (pre-aggregated table) | 136.38 s | < 1 ms | > 100,000x | 50.4 s → 0.42 ms | Answer computed once by the ETL |
| Q3 30-day readmission rate | 13.64 s | 0.218 s | 63x | 6.34 → 0.059 s (107x) | Self-join replaced by an ETL-computed flag |
| Q4 Revenue by specialty and month | 27.66 s | 3.48 s | 7.9x | 8.58 → 0.62 s (13.8x) | Billing pre-aggregated per encounter; join chain removed |

*Measured on 1,000,000 synthetic encounters with MySQL 8 + MySQL Workbench on a Windows laptop (2 GB buffer pool, median of runs 2–4 after a warm-up run). The reference column is a MariaDB 10.11 Linux server. Raw output: [`benchmark/mysql_workbench_timings.txt`](benchmark/mysql_workbench_timings.txt) and [`benchmark/reference_timings_raw.txt`](benchmark/reference_timings_raw.txt).*

## Deliverables

| Lab part | File |
|---|---|
| Part 2: OLTP queries and performance analysis | [`query_analysis.txt`](query_analysis.txt) |
| Part 3.1: Design decisions | [`design_decisions.txt`](design_decisions.txt) |
| Part 3.2: Star schema DDL | [`star_schema.sql`](star_schema.sql) |
| Part 3.3: Optimized queries and comparison | [`star_schema_queries.txt`](star_schema_queries.txt) |
| Part 3.4: ETL design | [`etl_design.txt`](etl_design.txt) |
| Part 4: Analysis and reflection | [`reflection.md`](reflection.md) |

## Repository structure

```
healthtech-analytics-lab/
├── README.md
├── query_analysis.txt            ┐
├── design_decisions.txt          │
├── star_schema.sql               │  the six lab deliverables
├── star_schema_queries.txt       │
├── etl_design.txt                │
├── reflection.md                 ┘
├── sql/
│   ├── 01_oltp_schema.sql            lab's OLTP schema → database healthtech_oltp
│   ├── 02_sample_data_fixed.sql      lab's sample rows, reordered so foreign keys pass
│   ├── 03_generate_big_data.sql      healthtech_oltp_big: 1M encounters (2–10 min)
│   ├── 04_etl_load_full.sql          full load healthtech_oltp_big → healthtech_dw
│   ├── 05_etl_load_incremental.sql   incremental load (late-arriving data)
│   ├── etl_load_template.sql         same ETL with a __SRC__ placeholder for any source
│   ├── etl_load_sample.sql           full load from the small sample database
│   ├── verify_warehouse.sql          11 reconciliation checks (all must PASS)
│   └── compare_results.sql           proves star results = OLTP results (all must PASS)
├── queries/                          oltp_q1–q4, star_q1–q4, star_q2_agg
├── tests/
│   ├── readmission_logic_test.sql    Q3 logic test on the sample (rolled back)
│   ├── scd2_incremental_setup.sql    changes a provider's specialty + adds a late claim
│   ├── scd2_incremental_check.sql    shows the result after an incremental load
│   └── scd2_incremental_undo.sql     restores the source
├── scripts/                          optional bash helpers
│   ├── time_query.sh                 median time + rows read for one query
│   └── compare_results.sh            diff-based version of compare_results.sql
└── benchmark/reference_timings_raw.txt
```

## How to run (MySQL Workbench)

**Requirements:** MySQL Server 8.0+ (or MariaDB 10.6+) and MySQL Workbench. The whole pipeline has been run end to end on both MySQL 8 (Workbench, Windows) and MariaDB 10.11. MySQL 8 shows harmless deprecation warnings (1681 integer display width, 1287 `VALUES()`), and `DROP ... IF EXISTS` shows note 1051 the first time.

**One-time setup**

1. In **Edit → Preferences → SQL Editor**, set **DBMS connection read timeout** to `1800` seconds. On a laptop the data load, OLTP Q2 and the ETL's largest statement run for several minutes, far beyond the default 30 s.
2. In the same panel, set the result row limit to **Don't Limit**, so Q1's 2,160 rows are all shown.
3. Reconnect. Then give InnoDB enough memory (needs root; use `1073741824` = 1 GB with under 8 GB RAM):
   ```sql
   SET GLOBAL innodb_buffer_pool_size = 2147483648;
   ```

You don't need to turn off Workbench's Safe Updates; the scripts switch it off for their own session. To run a whole script, use **File → Open SQL Script**, then click the plain lightning bolt (Execute).

**Steps**

| # | Run | Default schema | Time | Expected result |
|---|---|---|---|---|
| 1 | `sql/01_oltp_schema.sql` then `sql/02_sample_data_fixed.sql` | — | < 1 s | `healthtech_oltp` with 4 encounters, 2 claims |
| 2 | `queries/oltp_q1.sql` … `oltp_q4.sql` | `healthtech_oltp` | < 1 s | Q2: I10+99213 = 2, E11.9+99213 = 2. Q4: 280.00 and 10000.00 for Cardiology |
| 3 | `tests/readmission_logic_test.sql` | — | < 1 s | `Cardiology 2 1 50.00` |
| 4 | `sql/03_generate_big_data.sql` | — | 2–10 min | `healthtech_oltp_big`: 1,000,000 encounters, 2,500,000 diagnosis links, 950,000 claims |
| 5 | `queries/oltp_q1.sql` … `oltp_q4.sql`, each 4 times | `healthtech_oltp_big` | Q2 ≈ 1–2.5 min | Record the median Duration (ignore the 1st run) |
| 6 | `star_schema.sql` then `sql/04_etl_load_full.sql` | — | 3–20 min | No errors |
| 7 | `sql/verify_warehouse.sql` | — | seconds | All 11 rows `PASS` |
| 8 | `sql/compare_results.sql` | — | 2–10 min | All 5 rows `PASS` |
| 9 | `queries/star_q1.sql` … `star_q4.sql`, `star_q2_agg.sql`, each 4 times | `healthtech_dw` | 0.2–4 s each (Q2 bridge ≈ 7–40 s) | Record the median Duration |

To set the default schema, double-click the database in the Navigator so it turns bold. "Duration" is in the Action Output panel; ignore "Fetch", which is only Workbench drawing the grid.

**Rows read** (the figure used in `query_analysis.txt`): run `FLUSH STATUS;`, then the query, then `SHOW SESSION STATUS LIKE 'Handler_read%';`, and add up the `Value` column.

**Optional: SCD Type 2 and late-arriving data test**

1. Run `tests/scd2_incremental_setup.sql`, then `sql/05_etl_load_incremental.sql`, then `tests/scd2_incremental_check.sql`. Expected:
   - provider 1 has two versions (Internal Medicine closed yesterday, Neurology current from today);
   - encounter 20 now shows 1 claim and $700 allowed;
   - the fact table still has 1,000,000 rows;
   - provider 1's past encounters stay under Internal Medicine.
2. Restore: run `tests/scd2_incremental_undo.sql`, `star_schema.sql`, `sql/04_etl_load_full.sql`, then `sql/verify_warehouse.sql` (all `PASS`).

## How to run (command line, alternative)

From the repository root, with `MYSQL_CMD` set if you need credentials (e.g. `export MYSQL_CMD="mysql -u root -p<password>"`):

```bash
mysql < sql/01_oltp_schema.sql && mysql < sql/02_sample_data_fixed.sql
mysql < sql/03_generate_big_data.sql
bash scripts/time_query.sh healthtech_oltp_big queries/oltp_q1.sql 3     # repeat for q2 (2 runs), q3, q4
mysql < star_schema.sql && mysql < sql/04_etl_load_full.sql
mysql < sql/verify_warehouse.sql
mysql < sql/compare_results.sql           # or: bash scripts/compare_results.sh
bash scripts/time_query.sh healthtech_dw queries/star_q1.sql 3           # repeat for each star query
```

`time_query.sh` prints each run, the median, and rows read, and appends them to `timings.txt`.

## Design summary

- **Grain:** one row per encounter (`fact_encounters`). Encounter counts and revenue are then never double-counted.
- **Dimensions:**
  - date (YYYYMMDD smart key, 2015–2030);
  - patient and provider (SCD Type 2; the provider row also carries its specialty and department);
  - specialty, department, encounter type, diagnosis and procedure.
  - Key `0` is an "Unknown" member in every dimension, so fact keys are never NULL.
- **Pre-computed on the fact:** diagnosis, procedure and claim counts; claimed and allowed totals; length of stay; age at encounter; and the 30-day readmission flags. `specialty_key` is also stored on the fact.
- **Bridges:** `bridge_encounter_diagnoses` and `bridge_encounter_procedures`, clustered on `encounter_key`, plus the aggregate table `agg_diagnosis_procedure_pairs` for Q2.
- **Covering indexes:** one per report pattern. Combined with an "aggregate the fact first, then join dimensions" query pattern, every star plan reads only the index. Without that pattern the star queries were only 2–3x faster.
- **ETL:** idempotent. It upserts facts by `encounter_id`, replaces bridge rows per encounter, uses point-in-time lookups into the SCD2 dimensions, and has an incremental mode with a 45-day lookback for late claims and readmissions.

## Notes and assumptions

- **Data:** the provided sample data (4 encounters) is used to check correctness. The performance numbers come from `03_generate_big_data.sql`, which produces random synthetic data. Row counts are fixed, but amounts, dates and rankings change on every run, so your timings and totals will differ from the reference run. Clinical results from it, such as readmission rates of about 4% for every specialty, have no real-world meaning.
- **Sample data fix:** the lab's sample script inserts `billing` before `encounters`, which fails the foreign key (`ERROR 1452`). `02_sample_data_fixed.sql` loads the tables in dependency order.
- **Readmission definition:** an inpatient stay is readmitted if the same patient has another *inpatient* admission that starts after discharge and within 30 days. It is attributed to the specialty of the original stay.
- **Revenue month:** revenue is grouped by month of service (`encounter_date`), so it lines up with encounter volumes. Grouping by `claim_date` would give cash-basis reporting instead.
