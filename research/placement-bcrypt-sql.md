# Placement study: can bcrypt run inside Postgres, and would it be cheaper? (key: bcrypt-sql)

**Question.** Could the bcrypt work (login verify, sign-up hash) run inside Postgres instead of the app, and would
that cost less **total CPU** (Postgres plus app)? The box is CPU-bound, so only total CPU per hash matters. Which
side does the work is otherwise irrelevant.

**Answer: no on both counts.**

- **Not allowed.** The only Postgres bcrypt is `pgcrypto`'s `crypt()`, and that needs `CREATE EXTENSION`. Rule 3
  forbids creating extensions or functions. The app's role (`conduit`) also lacks the privilege: in a copy of the seed,
  `CREATE EXTENSION pgcrypto` fails with *permission denied*. Core Postgres has no bcrypt or Blowfish function.
- **Not cheaper even if it were allowed.** pgcrypto costs **51.25 ms of backend CPU per cost-10 hash** (spread
  51.22-51.35). It runs one hash at a time, and the build uses gcc 12 at `-O2`. The app's 8-lane C kernel (already
  integrated) costs **12.66 ms/hash** on the same CPU, so pgcrypto costs **4.0x** as much. It also costs 6% more
  than the plain single-hash Openwall C (48.4-48.5 ms). At 100k users (27.8 hashes/s), moving bcrypt into Postgres
  would add **+1.07 cores**, about 13% of the 8-vCPU box. At 150k users it would add +1.61 cores.
- **Without an extension, SQL is hopeless.** A Blowfish inner loop in plpgsql (a `DO` block, which creates no catalog
  object and runs as `conduit`) extrapolates to **~2.8 s per hash**. A pure-SQL recursive CTE extrapolates to
  **~16.5 s per hash**. That is 220x and 1,300x the C kernel, or about 77 and 460 cores at 100k users.

Keep bcrypt in the app: the 8-lane C core through FFM or cinterop, built with `-O3`, as planned
(`research/simd-bcrypt.md`).

---------------------------------------------------------------------------------------------------------------------

## 1. Facts checked (Postgres 18.4 lab, PG built with Debian gcc 12.2 `-O2`, `--with-openssl`)

| Fact | How checked | Result |
|---|---|---|
| Rule 3 forbids extensions | README.md rule 3: "Don't create, alter or drop anything in the database: no tables, columns, indexes, views, functions, triggers or extensions." | **Confirmed** |
| pgcrypto exists in this build | `pg_available_extensions` | `pgcrypto 1.4` available, `trusted = true` in its control file. `plpython3u` is also available but untrusted. |
| pgcrypto is not installed in the templates | `pg_extension` in `conduit_seed` and `conduit_dev` | **Only `plpgsql`** in both, and 0 functions outside `pg_catalog`/`information_schema`. Re-checked after the study: unchanged. |
| No core (non-extension) bcrypt | `pg_proc` search for crypt, blowfish, bf_, bcrypt, hmac, sha, md5, digest, pbkdf, encrypt, gen_salt | **None.** Core has only `md5(text/bytea)` and `sha224/256/384/512(bytea)`. SCRAM's PBKDF2 is internal and not callable from SQL. |
| The app role can't install it anyway | As `conduit` in a `conduit_dev` copy (dropped afterwards). `conduit` is a non-superuser with only DML grants (seed/make-seed.sh). | `has_database_privilege(CREATE)` = f, so `CREATE EXTENSION pgcrypto` fails: "permission denied to create extension". `CREATE FUNCTION public.f` fails: "permission denied for schema public". `LOAD 'pgcrypto'` fails: "access to library is not allowed". **`DO $$ … $$` works**, and `set_config`/`current_setting` work as an output channel. |
| pgcrypto handles the seed hash | `crypt('password123', seed $2a$10$ hash)` | Matches. A wrong password gives f. `U*U` matches the Openwall vector. 72/73-byte truncation behaves the same. |
| pgcrypto **does not understand `$2b$`/`$2y$`** | `crypt('password123', '$2b$10$…')` | Silently returns a **DES-crypt** string (`$2SXu7evaw9i.`), so the check fails. `$2x$` and `$2a$` work, and `gen_salt('bf')` only emits `$2a$`. Our server writes `$2b$` hashes (Auth.kt), so any SQL verify would need `'$2a$' \|\| substr(hash, 5)`. |

**Is pure SQL with no `CREATE FUNCTION` viable?** It is possible in principle and useless in practice. bcrypt cost 10 is
`(1 + 2·2^10)·521 + 3·64 = 1,067,721` Blowfish encryptions, each 16 Feistel rounds of 4 S-box lookups, over a state
that changes after every encryption. I did not build full bcrypt. I measured the inner unit instead: one encryption
(16 rounds plus 2 state writes over an `int8[1042]` holding S0-S3 and P), in two forms (§2.2). Key setup, salt
decoding and base64 add well under 1% to that count. Two more obstacles apply to the `DO` route even if it were fast:
it cannot take bind parameters, so the password would have to be spliced into the SQL text, and it cannot return rows,
only `RAISE NOTICE` or `set_config`. A data-modifying CTE cannot carry the mutable S-boxes through a table either, and
`COPY … TO/FROM PROGRAM` needs superuser plus a table, and would be an external process anyway.

---------------------------------------------------------------------------------------------------------------------

## 2. Measurements

**Method.**

- Scratch database `scratch_pgcrypto` with `CREATE EXTENSION pgcrypto`, dropped afterwards.
- The measuring backend was pinned to **CPU 1** with `taskset -pc 1 <backend pid>`. Postgres itself is pinned to
  0-1.
- Backend CPU was read from `/proc/<pid>/stat` (utime + stime). CPU 1 busy time came from `/proc/stat`. CPU 1's
  busy share equalled the backend's own (0.99-1.00) in every crypt run, so nothing else ran on that CPU.
- I held `/opt/tools/bench.lock` for each of 3 repetitions (about 90 s each), released it in between, and ran
  everything in each repetition. The C reference ran on the same CPU 1, also under the lock.
- I used pgbench with **bind parameters** (`-D pw=… -D h=…`, `-M prepared`) because `crypt()` is `IMMUTABLE`. With
  literal arguments, a cached generic plan would fold it to a constant once. The psql runs use literals in simple
  query mode, so they are re-planned and evaluated every call.

### 2.1 pgcrypto vs C on the same CPU (cost 10, mean of 3 runs, min-max)

| What | Wall ms/call | **CPU ms/hash** | vs C 8-lane |
|---|---|---|---|
| pgcrypto `crypt(:pw, :h) = :h` (verify), `pgbench -n -M prepared -c 1 -T 30`, 580-583 tx/run | 51.58 (51.48-51.78) | **51.25** (51.22-51.27) | **4.05x** |
| pgcrypto `crypt(:pw, gen_salt('bf',10))` (sign-up), same | 51.57 (51.47-51.72) | **51.29** (51.24-51.35) | 4.05x |
| psql `\timing`, verify, 20 calls/run (median) | 51.43 (51.41-51.46) | 51.0 (10 ms tick resolution) | - |
| psql `\timing`, gen_salt + crypt, 20 calls/run (median) | 51.45 (51.38-51.55) | 51.0-52.0 | - |
| statement overhead `select :pw::text = :h::text` | 0.013-0.039 | 0.007-0.020 | - |
| `select gen_salt('bf',10)` alone | 0.010-0.043 | 0.006-0.023 | - |
| C Openwall single hash, gcc 13 `-O3` (SB `bench-gcc openwall-1`) | 48.54 (48.44-48.68) | 48.42 (48.35-48.54) | 3.82x |
| C Openwall single hash, gcc 13 `-O2` | 48.69 (48.56-48.79) | 48.53 (48.41-48.60) | 3.83x |
| **C Openwall 8-lane interleave, gcc 13 `-O3`** (our integrated kernel's design) | 12.67 (12.64-12.69) | **12.66** (12.63-12.68) | **1.00x** |
| C Openwall 8-lane, gcc 13 `-O2` | 17.02 (16.66-17.39) | 16.98 (16.65-17.28) | 1.34x |

The two statement-overhead rows (overhead and `gen_salt` alone) varied 3x between runs. In run 3 the pgbench client was
faster, and something else shared CPU 1. Both rows stay under 0.05% of a hash either way. The C rows on CPU 1 agree
with `simd-bcrypt.md`'s CPU 3 numbers (48.53 and 12.65 ms) within 0.3%.

**Why pgcrypto is slower than even single-hash C.** pgcrypto's `crypt-blowfish.c` is an older Openwall derivative. It
computes one hash per call and is compiled with the server's `-O2`. A SQL function has no way to interleave several
hashes. A batched statement such as `crypt(pw, h) FROM unnest(…)` evaluates them one after another in one backend, so
the 4x gain the app gets from interleaving 8 independent hashes is unavailable in Postgres. Parallel workers would only
spread the same CPU over more cores.

### 2.2 bcrypt without an extension (estimates from measured inner-loop probes, backend pinned to CPU 1)

| Probe | Measured | Per encryption | **Extrapolated cost-10 hash** (1,067,721 encryptions) |
|---|---|---|---|
| plpgsql `DO` block, 16 rounds unrolled, `int8[]` state, in-place element writes, 200,000 encryptions | 515-522 ms | 2.60 µs (2.58-2.61) | **2.77 s** (2.75-2.78) |
| Pure SQL `WITH RECURSIVE`, one encryption per step via a 17-deep `LATERAL … OFFSET 0` chain, state rebuilt by array slicing, 10,000 steps | 150-157 ms | 15.4 µs (15.0-15.7) | **16.5 s** (16.0-16.7) |

Both are lower bounds: they omit key and salt setup, base64 and the per-ExpandKey key XORs. The CTE also needs the
whole run's rows in its tuplestore, about 8.4 KB per step, which comes to about 9 GB per hash. The probe set
`work_mem` to 512 MB for its 10,000 steps.

---------------------------------------------------------------------------------------------------------------------

## 3. Where bcrypt is cheapest: SQL vs app code vs C

Load: 25% of session starts are bcrypt logins or sign-ups (WORKLOAD.md). That is users / 900 s x 0.25, so
**27.8 hashes/s at 100k users** and 41.7/s at 150k.

| Where / how | CPU ms per hash | Cores at 100k | Cores at 150k | Source |
|---|---|---|---|---|
| Pure SQL recursive CTE (no extension) | ~16,500 | ~460 | ~690 | §2.2 (estimate) |
| plpgsql `DO` block (no extension) | ~2,770 | ~77 | ~116 | §2.2 (estimate) |
| **Postgres + pgcrypto `crypt()`** (forbidden) | **51.25** | **1.42** | **2.14** | §2.1 |
| App, C Openwall single hash | 48.4 | 1.35 | 2.02 | §2.1 |
| App, Kotlin JVM scalar, 4 lanes | 23.1 | 0.64 | 0.96 | simd-bcrypt.md §2.3 |
| App, Kotlin/Native pure Kotlin, 4 lanes | 18.3 | 0.51 | 0.76 | simd-bcrypt.md §2.4 |
| App, C SIMD (AVX2 gathers, best hybrid 2x8+4; asm-level intrinsics) | 13.9 | 0.39 | 0.58 | simd-bcrypt.md §2.1 |
| **App, C Openwall 8-lane `-O3` (FFM / cinterop), current plan** | **12.4-13.0** (12.66 here) | **0.35** | **0.53** | §2.1, simd-bcrypt.md |

- **pgcrypto vs the current plan:** +38.6 ms per hash, which is +1.07 cores at 100k (about 13% of the box) and
  +1.61 cores at 150k (20%). That CPU would land on Postgres, which is already the bottleneck at about 70% of the box.
- **Nothing on the Postgres side offsets it.** Login is one statement either way: the app either fetches
  `password_hash` with the user row, or SQL does `WHERE email = $1 AND password_hash = crypt($2, password_hash)`.
  Sign-up is one `INSERT` either way. Moving the hash into SQL saves sending 60 bytes and nothing else, with no saved
  round trip or parse.
- **It also hurts latency and batching.** Each crypt holds a backend for 51 ms. Inside one of our batched statements
  (many requests per statement, LATERAL over `unnest`), every login in the batch would delay all the other requests
  by 51 ms, serially. So logins would need their own connections. The app's bcrypt pool has no such coupling.
- **Lower level than C: asm.** No assembly bcrypt was measured. Hand-written SIMD, which is intrinsics and effectively
  asm, already loses to the scalar 8-lane C on this CPU (13.9 vs 12.4-12.7 ms; gathers cost about one load slot per
  element; simd-bcrypt.md §3). The vendored libxcrypt Openwall core has no asm path for x86-64 (only `BF_SCALE`).
  The compiler flag matters more. I reproduced that `-O2` costs 34% more than `-O3` for the 8-lane kernel (16.98 vs
  12.66 ms), while the flag makes no difference for a single hash. So `build.sh` must keep `-O3`.

---------------------------------------------------------------------------------------------------------------------

## 4. Caveats

- One CPU model (the lab's Granite Rapids-class Xeon vCPU). pgcrypto and the C kernels share the same
  memory-latency-bound inner loop, so the ratio between them should carry over. The absolute numbers will not.
- pgcrypto's source is not on the box, so the "older Openwall derivative, -O2, single lane" explanation rests on the
  build flags (`pg_config --cflags`: `-O2`) and the 6% gap to libxcrypt's Openwall core. I did not read its assembly.
- The SQL-only numbers are extrapolations from the inner loop, not a full bcrypt implementation. Even a 10x error
  would leave them 20-130x worse than C.
- psql backend CPU comes from 100 Hz ticks, so it has 10 ms resolution over about 1 s. The pgbench rows (about 30 s
  each) are the precise ones.

## 5. Files

Work dir: `/tmp/claude-0/-home-user-multicore-server-challenge/99796a5c-b120-524c-822d-dc73b94b523b/scratchpad/placement/bcrypt-sql/`

| File | What |
|---|---|
| `measure.sh`, `rep.sh` | The 3 locked repetitions (one lock per repetition) |
| `pgb.sh` + `verify.sql`, `gensalt.sql`, `baseline.sql`, `saltonly.sql` | pgbench `-c 1 -M prepared`, backend pinned to CPU 1, backend CPU and CPU 1 busy share |
| `psqltiming.sh`, `timing.psql` | psql `\timing`, 20 + 20 calls, backend pinned |
| `gen_sqlbf.py` → `plpgsql_bf.sql`, `cte_bf.sql`; `probes.sh` | The plpgsql `DO` and recursive-CTE Blowfish probes |
| `measure.log`, `out.*`, `summarize.py` | Raw output and the mean/min/max summary |
| C reference binaries | `scratchpad/simd-bcrypt/c/bench-gcc`, `bench-gcc-O2` (Openwall core from `submissions/rust-tokio-Scooter1337/native`) |

Databases created and dropped: `scratch_pgcrypto` (pgcrypto installed) and `bcsql_rolecheck` (a copy of
`conduit_dev`, for the `conduit` role checks). `conduit_seed` and `conduit_dev` were never modified. Both still have
only `plpgsql`.
