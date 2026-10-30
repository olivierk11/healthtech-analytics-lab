# Reflection: From OLTP to Star Schema

All numbers below were measured on the same 1-million-encounter dataset. The primary numbers come from MySQL 8 with MySQL Workbench on my Windows laptop (warm cache, median of repeated runs); a reference run on MariaDB 10.11 is shown alongside for comparison. Every star-schema query returned results identical to its OLTP version.

## 1. Why is the star schema faster?

**Joins.** Counting JOIN keywords understates the difference. The OLTP queries use 2–3 joins each, and the star queries use 1–3. What matters is what is being joined. In the OLTP, every query walks encounters → providers → specialties through secondary indexes before it can group anything. That is one million random lookups, and Q4 adds a fourth table (billing) to the chain. In the star schema, `specialty_key` and the billing totals sit on the fact row, so the big table is never joined to anything. The fact table is grouped on its own integer keys, and the small dimensions (4 to 5,852 rows) are joined only to the few hundred aggregated rows to get labels.

**Pre-computation.** The star schema computes work once, at load time, in four places:

- **The fact row** stores diagnosis, procedure and claim counts, billed and allowed totals, length of stay, age at encounter, and the readmission flags.
- **`dim_date`** stores months, quarters and weekends, so no query calls `DATE_FORMAT` on a million rows.
- **The denormalized `specialty_key`** removes the provider hop.
- **`agg_diagnosis_procedure_pairs`** stores the Q2 answer itself.

**Why denormalization helps analytics.** Analytical queries read most of the table and group it by a few descriptive attributes. Normalization optimizes the opposite workload: writing one row at a time without anomalies. When the grouping attributes live on (or one small hop from) the rows being aggregated, the engine can answer from a narrow covering index on integers. Every final star plan shows "Using index", meaning the 400 MB table data is never read. Denormalization works by putting the data in the shape of the question.

## 2. Trade-offs: what did I gain, and what did I lose?

**What I gave up:**

- **Storage.** The warehouse is about 850 MB against about 540 MB for the OLTP, roughly 1.6×. Most of the extra is the covering indexes on the fact table. Specialty names, for example, are now copied onto provider rows and specialty keys onto a million fact rows.
- **Freshness.** The warehouse is as current as the last nightly load, not real time.
- **ETL complexity.** About 300 lines of load logic: SCD Type 2 handling, point-in-time key lookups, incremental batches with a lookback window, late-arriving claims and readmission flags that change after the fact, unknown members, and reconciliation checks.
- **New ways to be wrong.** I hit three real bugs, each silent:
  - The lab's sample data inserts billing before encounters, which violates the foreign key.
  - MariaDB stopped my recursive date generator at 1,000 rows without an error.
  - A `CREATE TABLE … AS SELECT` matched columns by name and loaded every billing total as zero.

  Only reconciling counts and dollar totals against the source caught them. A warehouse is a second copy of the truth that has to be kept honest.

**What I gained:**

- **Speed.** 3.7× to 63× on the four questions on MySQL (7× to 107× on the MariaDB reference run), and over 100,000× for Q2 with the aggregate table.
- **Simpler and more consistent queries.** The readmission query is now `SUM(readmitted_within_30d) / COUNT(*)` instead of a carefully de-duplicated non-equi self-join. Every analyst gets the same definition.
- **History.** SCD2 credits an encounter to the specialty the provider had at the time. The OLTP cannot do this, because it overwrites a provider's specialty in place.
- **Isolation.** Heavy reporting no longer competes with clinical transactions.

**Was it worth it?** Yes, for a reporting workload that runs these questions repeatedly. The full load (about 20 minutes on my laptop) is paid once a night. The 136-second Q2 or the 14-second readmission query would be paid every time someone opens a dashboard. For a one-off question on a small database, it would not be worth it.

## 3. Bridge tables: worth it?

**Why keep diagnoses and procedures in bridges instead of the fact:** they are genuinely many-to-many, with 1–4 diagnoses and 1–3 procedures per encounter. Folding them into the fact has two bad options:

- **Change the grain** to one row per diagnosis or procedure. Revenue and encounter counts then double-count unless every query uses `COUNT(DISTINCT)` or allocates dollars.
- **Add fixed columns** (`dx1…dx10`). These are mostly NULL, awkward to search ("any encounter with I50.9"), and break at the eleventh code.

Bridges keep the fact clean, so three of the four questions never touch them, while still supporting code-level analysis.

**The trade-off:** a bridge is still a many-to-many join at query time. For Q2 the bridges improved 136 s to 37 s on MySQL (50.4 s to 7.4 s on the reference run), a real gain but the smallest of all four questions. Clustering both bridges on `encounter_key` with integer keys turned random lookups into an ordered match. But the bridges cannot remove the row explosion: pairing every diagnosis with every procedure still produces 5.0 million intermediate rows. The bridge is also a place where analysts can go wrong. Joining the fact to a bridge and then summing dollars repeats each encounter's revenue once per diagnosis.

**What I would do in production:**

- Keep the bridges as the flexible detail layer.
- Add aggregate tables for heavy queries that run often, as I did with `agg_diagnosis_procedure_pairs`, which turns Q2 into an index read of under a millisecond.
- Add `primary_diagnosis_key` to the fact, as I did, since most clinical reporting only needs the primary diagnosis and then avoids the bridge entirely.
- Consider a weighting factor (1/number of diagnoses) on the bridge if the business wants revenue allocated across diagnoses.
- Expose the bridge to BI users only through views that prevent the double-counting mistake.

## 4. Performance quantification

| Query | Original (OLTP, MySQL) | Optimized (star, MySQL) | Improvement | Main reason for the speedup |
|---|---|---|---|---|
| Q1 Monthly encounters | 11.22 s | 2.52 s | **4.5×** (ref. 7.0×) | Specialty on the fact removes the 2-join chain; month from the smart date key; covering integer index |
| Q2 Dx–Px pairs (bridges) | 136.38 s | 36.55 s | **3.7×** (ref. 6.8×) | Bridges clustered on encounter_key; grouping on INT keys instead of VARCHAR descriptions |
| Q2 Dx–Px pairs (aggregate) | 136.38 s | < 1 ms | **> 100,000×** (ref. ~120,000×) | Answer pre-computed in ETL; top 10 read from an index |
| Q3 Readmission rate | 13.64 s | 0.218 s | **63×** (ref. 107×) | Self-join replaced by a flag pre-computed in ETL; selective covering index |
| Q4 Revenue by specialty | 27.66 s | 3.48 s | **7.9×** (ref. 13.8×) | Billing pre-aggregated per encounter; 3 joins of the chain removed; measures inside the index |

Times are from MySQL 8 on my laptop; "ref." is the MariaDB reference run. The speedups differ in size between the two engines, but the ranking is the same. Rows read per query (reference run) dropped as well: Q3 from 2.81 M to 0.30 M, and Q4 from 4.60 M to 1.96 M.

**The most important lesson** came from my first attempt. My first star queries, written the textbook way (fact joined to every dimension, then GROUP BY on labels), were only 2–3× faster. The optimizer started from the small dimensions and cross-joined them into about 491,000 combinations before probing the fact table. Rewriting them to aggregate the fact on its keys first, and adding covering indexes, is what produced the numbers above. The star schema made the speed possible, and the query pattern and indexes delivered it. The largest single gain (Q3, 63× on MySQL and 107× on the reference run) came from neither joins nor indexes, but from moving business logic out of the query and into the load. The fastest query is the one whose answer was computed before anyone asked.

*Caveat: the data is synthetic, so the speedups are meaningful but the clinical results are not. The readmission rate is about 4% for every specialty because the generator assigns patients randomly.*
