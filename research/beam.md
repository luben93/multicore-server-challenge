# Would the BEAM (Erlang/Elixir) beat our Kotlin design? Evaluation of elixir-raw-foovoo

Date: 2026-10-24. Everything below was measured on this lab machine unless it says "box" (the leaderboard's
8-vCPU machine). Lab setup: the server and Postgres 18.4 share CPUs 0-1, the load generator runs on CPUs 2-3,
full seed, and every run starts from a fresh database copy. Other agents share the machine (compiles and their
own load tests), so a single run carries roughly ±10% noise. The orchestrator stopped the experiment queue after
the runs listed here, because the shared bench lock had about a dozen waiters.

Scratch files are in `/tmp/claude-0/-home-user-multicore-server-challenge/99796a5c-b120-524c-822d-dc73b94b523b/scratchpad/beam/`:
- `bench.sh` / `capacity.sh`: copies of `/opt/tools/*` with one fix, described in section 2.
- `micro/`, `micro.sh`: a per-endpoint CPU microbenchmark.
- `drv/drv.exs`: the batching experiment.
- `msacc-base.txt`: the BEAM microstate accounting dump.
- `elixir_sql.txt.plan_*`: SQL plan tests.
- `variants/`: patched copies of the entry, built outside the repo.

## TL;DR

- **No. On this benchmark the BEAM is the wrong runtime.** The score depends on CPU per request, and the BEAM
  costs 4-5x our Kotlin server in app CPU.
  - On the same harness, elixir-raw-foovoo spends **238-313 µs of app CPU per request**. Our zero-dependency
    Kotlin JVM server spends **51-61 µs**.
  - Even a perfectly batched BEAM Postgres driver costs 30-86 µs per request (measured below). That is about as
    much as our *whole* request.
- **Where elixir-raw-foovoo loses (box: 850 µs CPU per request, against 274 for rust #1 and 590 for kotlin-vertx):**
  - **App CPU, 370 µs per request on the box.** About 43% of the normal scheduler time goes to port (socket
    driver) work and about 39% to the emulator. Postgrex/DBConnection costs 62-80 µs per query.
  - **Postgres CPU, 480 µs per request on the box.** This is self-inflicted and runtime-independent:
    - The planner keeps **custom plans** for `list_all`/`list_tag`, which costs about 0.4 ms of planning on
      each call. `plan_cache_mode=force_generic_plan` is not set.
    - There is no pipelining and no cross-request batching.
  - **A connection pool that is too small for a client-side lease.** Postgrex holds the connection while the
    BEAM decodes the rows. At 1.5 connections per core the server is pool-bound (latency) before it is CPU-bound.
- **Cheap fixes measured locally (2 cores):**
  - `POOL=6`: 3,082 → 3,493 req/s at the last pass, and p95 283 → 203 ms at 3,000 users.
  - Generic plans: Postgres 284 → 223-229 µs per request (−20%).
  - Both together at 4,000 users: **3,945 req/s, p95 339 / p99 365 ms, PASS**, at 490 µs per request (257 app + 233 Postgres). The baseline failed this point (2,795 req/s, p95 879 ms).
  - Even so, the best lab capacity is about 3.5-4k req/s. Our Kotlin server passes **13,865 req/s**, and rust #1
    passes 11.5k.
- **Where the BEAM wins:** connection handling comes almost for free (one cheap process per socket; +P/+Q is all
  100k connections need), preemptive scheduling and per-process GC give fair latency, and it is robust. None of
  that moves this score. The latency limits (p95 500 ms, p99 1 s) are far above any GC pause, and every entry
  holds 100k sockets.
- **An ideal BEAM entry** would have:
  - owner processes that batch reads and group commits;
  - raw binary rows passed straight into the iodata;
  - rust #1's SQL with generic plans;
  - an interleaved bcrypt NIF.

  I estimate it at about 230-290 µs per request in the lab (against 143 for ours and for rust), which is
  **about 50-70k users on the box (best guess about 60k, 50-70% of rust #1)**. That beats both Kotlin framework
  entries (44-46k) but is well short of what our hand-written Kotlin already shows in the lab.

---

## 1. Why elixir-raw-foovoo stopped at 32k

### 1.1 Leaderboard arithmetic (box, 8 vCPU)

| entry | users | req/s | app µs/req | PG µs/req | total µs/req |
|---|--:|--:|--:|--:|--:|
| rust-tokio #1 | 100,000 | 26,279 | 61 | 213 | 274 |
| csharp-sockets #2 | 95,000 | 24,696 | 68 | 243 | 311 |
| kotlin-vertx #12 | 46,000 | 11,923 | 248 | 342 | 590 |
| kotlin-ktor #15 | 44,000 | 10,948 | 329 | 358 | 687 |
| **elixir-raw-foovoo #17** | 32,000 | 7,999 | **370** | **480** | **850** |

(Per-request CPU = CPU share x 8 cores / req/s.)

- The box was 85% busy.
- The score is about 100k x 274 / (total µs per request) for every row: 274/850 gives 32k and 274/590 gives 46k.
- The BEAM entry is therefore 3.1x off rust #1: **6x on app CPU and 2.25x on Postgres CPU**.

### 1.2 What the code does (read in full: README, install/build/start, lib/conduit/*.ex)

- **Toolchain.** Erlang/OTP 28.5.0.8 from hex.pm's Ubuntu build and Elixir 1.19.6. It is a `mix release`
  started with `bin/conduit start`.
  - Verified locally: `emu_flavor = jit`, `kernel_poll = true`, async thread pool = 1.
  - The JIT is on by default. `+K true` is already the default. `+A` is unused by `inet_drv`/gen_tcp, so both
    are no-ops here.
- **HTTP (`http.ex`).** Its own server on `:gen_tcp`:
  - 16 acceptor processes; each one that accepts *becomes* the connection process, so there is one process per
    keep-alive connection.
  - `active: true`, `:erlang.decode_packet(:http_bin/:httph_bin)` (a C BIF), and the handler runs inline.
  - Responses are hand-built iodata, sent with one `:gen_tcp.send`.
  - The process hibernates between requests when its heap is above `HIB_WORDS` (2,048 words).
- **Postgres (`db.ex`, `application.ex`, `sql.ex`).** Postgrex 0.22.4 over a DBConnection pool of
  `POOL = max(2, 1.5 x cores)` connections: 12 on the box and **3 on our 2-core slice**.
  - `prepare: :named` plus `cache_statement`, so each request is one Bind/Execute/Sync round trip with binary rows.
  - It uses one statement per request (lists fold their count into the same statement).
  - **There is no pipelining and no cross-request batching, and Postgrex/DBConnection cannot do either.** Every
    query is:
    1. a checkout (a message to the pool process, a monitor, an ETS `give_away`, a timer),
    2. a `gen_tcp.send`,
    3. a passive `gen_tcp.recv`,
    4. a decode of every row in the *caller* process while the connection is still leased,
    5. a checkin (an ETS `give_away` back to the pool).
  - Session settings are `jit=off` and `max_parallel_workers_per_gather=0`. **`plan_cache_mode` is not set.**
- **JSON.** Request bodies use OTP's `:json` decoder. Responses are iodata written by hand, with a
  `:binary.match` fast path for escaping. Timestamps come from a custom Postgrex extension as raw microseconds.
- **JWT.** HS256 through `:crypto.mac`, with a flat-claims fast path: 4.5 µs per verify in a tight loop.
- **bcrypt.** `bcrypt_elixir` 3.3.2 is a C NIF (built `-O3 -flto`) that runs on dirty CPU schedulers
  (`+SDcpu max(2, cores/4)`).
  - Measured: **48.6-50.0 ms per verify**, the same as Bouncy Castle's 51 ms. There is no 4-lane interleaving.
  - Since think-scale also scales session length, every entry pays about 53 µs per request for bcrypt at this
    speed.
- **VM flags (`start.sh`).** `+S` on about 5/8 of the cores (2:2 on 2 cores, 5:5 on 8), `+SDio 2`,
  `+sbwt none +sbwtdcpu none +sbwtdio none` (no busy-waiting), and `+P 2000000 +Q 1000000`, because the default
  limit of 65,536 ports would cap the number of connections.

### 1.3 Causes, ranked, with the measurements behind them

1. **BEAM CPU per request: about 270 µs in the lab, 370 on the box.** This is the runtime itself.
   - Microstate accounting (msacc) over 40 s of the real mix, 2,000 users@0.2, about 2,570 req/s:

     | thread type | busy wall-time | breakdown |
     |---|--:|---|
     | 2 normal schedulers | 41.7 s | **port 42.6%**, **emulator 39.3%**, gc 6.4%, check_io 4.7%, other 4.3%, aux 2.7% |
     | dirty CPU (bcrypt) | 8.0 s | emulator 100% |
     | poll thread | 3.9 s | check_io 100% |

     Busy wall-time includes time the OS preempted the thread for Postgres. Scaled to the 27.6 CPU-seconds
     actually used, the split is roughly:
     - port/socket driver work: about 90 µs per request;
     - Erlang code: about 80 µs;
     - GC: about 13 µs;
     - check_io plus the poll thread: about 30 µs;
     - bcrypt: about 40 µs.
   - Per-endpoint microbenchmark: 1,000 keep-alive connections at 3,000 req/s, one endpoint at a time
     (`micro.sh`):

     | request | app µs/req | PG µs/req | what it adds |
     |---|--:|--:|---|
     | `GET /api/nothing` (404, no DB) | 36 | 0 | BEAM HTTP floor: socket message, decode_packet, route, iodata, send |
     | `GET /api/articles/feed?limit=abc` + token (422, no DB) | 58 | 0 | + JWT, query parsing, error JSON |
     | `GET /api/user` + token (1 PK query) | **138** | 50 | **+80 µs for one Postgrex round trip** |
     | `GET /api/tags` | 164 | 76 | one row with 200 names |
     | `GET /api/articles/:slug` | 166 | 151 | |
     | `GET /api/articles?limit=10` | 305 | 765 | saturated Postgres at 1,776 req/s (custom plans, see 2) |

     For comparison, rust #1's *entire* app cost is 46-63 µs per request, and ours is 51-61 µs. The BEAM's
     HTTP-only floor (36 µs) plus one Postgrex query (about 80 µs) already exceeds it twice over.
   - `drv.exs` measured Postgrex/DBConnection in isolation, with no HTTP: **73 µs of BEAM CPU per PK query** and
     **146 µs per 10-article page**, decoding included.
2. **Postgres CPU per request: about 285-313 µs in the lab against 175-195 for rust/vertx/ktor at the same
   3k req/s; 480 on the box.**
   - **Custom plans.** Named prepared statements without `plan_cache_mode=force_generic_plan` leave Postgres in
     "auto" mode.
     - A `pg_prepared_statements` check after 13 executions showed `list_all` and `list_tag` at
       **0 generic / 13 custom**. Every other statement switched to a generic plan after 5.
     - EXPLAIN ANALYZE: list_all plans for **0.39-0.48 ms** and executes in 0.33-0.42 ms; list_tag plans for
       0.38-1.1 ms.
     - With forced generic plans, planning drops to 0.02 ms and execution rises to 0.41-0.59 ms.
     - list_all and list_tag are about 16% of requests (22% of page views x 1 call, plus 8%), so this is about
       60 µs of Postgres per request on average.
     - In a load test with generic plans (variant `generic`, a one-line session parameter), Postgres went from
       284-313 to **223-229 µs per request**.
   - **No batching or pipelining.** Every request pays its own backend wake-up, Bind/Execute/Sync, snapshot and
     executor start-up.
     - A PK lookup costs Postgres 36-50 µs when sent alone and 8 µs inside a 32-request `unnest` batch
       (section 4).
   - **SQL details.** Favorites count and the favorited flag are two subplans per row, not rust's single LATERAL
     aggregate, and the global count is not an index-only walk. These are minor next to the two points above.
3. **The pool is too small, so the server is latency-bound before it is CPU-bound.** The lease covers
   client-side decoding, so throughput is capped at about `POOL / lease time`.
   - With 3 connections on 2 cores, the failing 4,000-user run used only 167% of the 200% CPU, and throughput
     *fell* past the knee: 3,082 req/s at 3,000 users, 2,795 req/s at 4,000.
   - `POOL=6` moved the last pass from 3,082 to 3,493 req/s and used 184-194% of the CPU.
   - The author found the same on 4 cores (6 → 8 connections, README).
   - On the box, 12 connections at 85% CPU is consistent with a little of each.
4. **Not the cause:**
   - Connection limits: +P/+Q are set, and 6,000 connections took 244 MB RSS, about 13 KB per connection by the
     RSS slope.
   - Scheduler busy-waiting: already disabled; "other" plus "aux" are only 7% of scheduler time.
   - JSON: already hand-written iodata.
   - bcrypt: an ordinary C NIF, about as costly as everyone's non-interleaved bcrypt.
   - Hibernation: measured as free; see section 3.

## 2. Local measurements (2-core harness)

**Install and build.** `install.sh` ran unchanged as root: OTP 28.5.0.8 and Elixir 1.19.6, sha256s OK.
`build.sh` built the release in 22 s, and conformance passed **197/197** on the dev seed.

**Measurement fix.** `/opt/tools/bench.sh` cannot measure a BEAM server. It descends to the *deepest* child of
`start.sh`, and beam.smp has children (`erl_child_setup` → `inet_gethost`), so it would report the app CPU of
`inet_gethost`, about 0.
- I ran an otherwise identical copy, `scratchpad/beam/bench.sh`. Its only change: when start.sh has exec'd into
  `beam.smp`, it measures beam.smp.
- The same copy fixes `capacity.sh`. It uses the same lock, results directory and ALL.txt.
- **Anyone re-running the Elixir entry with the stock bench.sh will see app CPU of about 0.**

### Baseline (the entry as submitted: start.sh defaults on 2 CPUs = `+S 2:2`, `POOL=3`, `+SDcpu 2`)

| run | users@think-scale | req/s | p50 / p95 / p99 ms | app µs | PG µs | total µs | CPU app+PG | verdict |
|---|---|--:|---|--:|--:|--:|--:|---|
| requested probe | 6000@0.25 | 3,006 | 1067 / 1182 / 1221 | 313 | 286 | 600 | 180% | FAIL |
| capacity | 2000@0.2 | 2,648 | 2 / 17 / 31 | 279 | 313 | 592 | 157% | pass |
| capacity | 3000@0.2 | 3,082 | 220 / 283 / 310 | 271 | 284 | 555 | 170% | **last pass** |
| capacity | 4000@0.2 | 2,795 | 661 / 879 / 1208 | 309 | 289 | 598 | 167% | FAIL |
| repeat + msacc | 2000@0.2 | 2,571 | 7 / 89 / 167 | 269 | 300 | 568 | 146% | pass |

**About the requested `capacity.sh ... 6000 8000 10000 12000 14000`.** I started the list lower (2000 3000 4000
5000 6000), because 6000@0.25 had already failed at 3k req/s, and 6000@0.2 offers 7.5k req/s.

**Baseline capacity in the lab: about 3.1k req/s** (pass at 3,000 users@0.2, fail at 4,000).

### Reference points on the same harness

| server | passes at | total µs/req (app + PG) |
|---|--:|---|
| **our kotlin-raw (JVM)** | **13,865 req/s** (13,000@0.2; fails at 15,000: 13.4k req/s, p95 702) | **142.8 (56 + 87)** |
| rust-tokio #1 | 11.5k req/s (fails at 13.4k) | 153 (46 + 107) |
| kotlin-vertx | 7.8k req/s | 250 (121 + 129) |
| kotlin-ktor | 3k req/s (load point, not a capacity) | 431 (245 + 186) |
| elixir-raw-foovoo | 3.1k req/s | 555-600 (270-313 + 284-313) |

## 3. Tunings tried (process-level settings only, plus one session parameter)

| variant | users@scale | req/s | p95 / p99 ms | app µs | PG µs | total | RSS | verdict / note |
|---|---|--:|---|--:|--:|--:|--:|---|
| baseline | 3000@0.2 | 3,082 | 283 / 310 | 271 | 284 | 555 | 203 MB | pass |
| baseline | 4000@0.2 | 2,795 | 879 / 1208 | 309 | 289 | 598 | 218 MB | FAIL |
| `HIBERNATE=0` | 2000@0.2 | 2,636 | 18 / 31 | 278 | 304 | 582 | **549 MB** | pass; no CPU gain (same as base 2000@0.2: 268-279 µs). Keep hibernation: it saves 2.8x memory for free |
| `POOL=6` | 3000@0.2 | **3,493** | **203 / 309** | 238 | 290 | 528 | 203 MB | pass: +13% req/s, p95 −28% |
| `POOL=6` | 4000@0.2 | 3,418 | 522 / 625 | 272 | 295 | 567 | 217 MB | FAIL by 22 ms; now CPU-bound (194%) |
| generic plans | 3000@0.2 | 2,923 | 468 / 762 | 268 | **229** | 498 | 219 MB | pass; still pool-bound (145% CPU) |
| generic plans | 4000@0.2 | 3,196 | 712 / 795 | 288 | **223** | 511 | 225 MB | FAIL; pool-bound (163% CPU) |
| **generic + `POOL=6` (best)** | 4000@0.2 | **3,945** | **339 / 365** | 257 | **233** | **490** | 225 MB | **PASS**; CPU-bound (193%). Last pass moves from 3,000 to 4,000 users (+33%) |

"Generic plans" means `parameters: [..., plan_cache_mode: "force_generic_plan"]` in `application.ex`. It is a
session-level SET, which the rules allow. I built it in a scratch copy (`scratchpad/beam/variants/generic`), and
the repo folder was not edited.

**Flags already at their best value, or no-ops (not re-measured, with evidence):**
- `+sbwt none +sbwtdcpu none +sbwtdio none`: already in start.sh. msacc shows "other" at 4.3% and "aux" at
  2.7% of scheduler time, so sleep/wake overhead is small.
- JIT: on (`emu_flavor=jit`; OTP 28 has no way to switch back to the interpreter at run time).
- `+K true`: already true.
- `+A`: inet_drv does not use the async pool.
- `+IOs`: the author's screen showed no consistent gain.

**Queued but stopped by the orchestrator (lock contention):** `+S 1:1`, default busy-wait (to quantify
`+sbwt none`), and `inet_backend: :socket` for the HTTP listener.
- The socket backend runs an extra gen_statem process per gen_tcp socket, so I expect it to be slower.
- `+S 1:1` caps the app at one core. At about 240-270 µs per request, that is about 3.7-4k req/s, no better than
  `+S 2:2`.

**Net effect of the cheap fixes:** +28% req/s and +33% users in the lab (last pass 3,082 → 3,945 req/s). Total
CPU goes from 555-600 to 490 µs per request, so the CPU-bound ceiling is about 4k req/s. On the box that would
move 32k to roughly 38-42k users. It does not change the verdict: the result is still 3.5x short of our Kotlin
server's 13.9k req/s on the same harness.

## 4. Batching: what it would gain on the BEAM vs on Kotlin

`drv.exs` runs inside the release with Postgrex as the transport.
- BEAM is pinned to CPUs 2-3 and Postgres to CPUs 0-1.
- 3 connections, 96 closed-loop requester processes, generic plans, 15 s per arm.
- Only the experiment's own backends are counted (`application_name`).

The two designs:
- **A:** what elixir-raw-foovoo does: `Postgrex.query` through the DBConnection pool, one statement per request.
- **B:** one owner process per connection.
  1. It drains up to 32 queued `{:q, from, args}` messages from its mailbox.
  2. It runs ONE `unnest(...) WITH ORDINALITY ... CROSS JOIN LATERAL (original)` statement, the same shape rust #1
     uses.
  3. It groups the rows by ordinal and sends each requester its rows.

| shape | design | req/s | BEAM µs/req | PG µs/req |
|---|---|--:|--:|--:|
| user_by_id (PK, 5 cols) | A pool | 13,056 | 73.0 | 36.0 |
| user_by_id | **B batched** | 35,499 | **30.0** | **8.1** |
| list_all, 10 articles (rust #1 SQL) | A pool | 5,851 | 145.6 | 207.2 |
| list_all | **B batched** | 10,494 | **85.8** | **147.2** |

What this means:

- **The Postgres side is runtime-independent.** Batching cuts PG CPU by 78% for point reads and 29% for list
  pages, in BEAM or in Kotlin alike. With rust #1's SQL, generic plans and batching, a BEAM entry's Postgres cost
  would fall from 284-313 to about 90-110 µs per request in the lab, the same as ours (87-91) and rust's
  (94-107). **This is the biggest lever for a BEAM entry: about −190 µs per request.** It is not a BEAM
  advantage, though; we already have it.
- **On the app side the BEAM gains more in absolute terms, but from a much higher base.**
  - Driver CPU per request drops by 43-60 µs (73 → 30 and 146 → 86). Fewer port operations per request, no
    checkout/checkin, one send and recv per batch.
  - In our Kotlin server the whole request, driver included, is 51-61 µs. Batching moves its app cost by a few
    µs at most, since continuations resume on the PG thread with no copies.
  - Even batched, the BEAM pays 30 µs (PK row) to 86 µs (10-article page) just to drive Postgres and decode the
    rows. That is about our whole request.
- **The BEAM adds costs of its own to batching.**
  - Rows are copied into each requester's heap. Sub-binaries over 64 bytes are shared, but the list/tuple
    skeleton is copied.
  - The owner process serializes the decoding for its connection.
  - Mailbox draining is natural ("drain until empty, max 32"), but selective receive must be avoided.
  - In B the BEAM was the bottleneck: 90-107% CPU for 10.5k-35k req/s.
- **Estimated whole-workload effect.**
  - BEAM app: −45 to −55 µs per request. The driver accounts for about 80 µs of the 238-279 average today.
  - Postgres: −130 to −200 µs per request (generic plans plus batching plus rust's SQL).
  - Elixir total: about 555 → about 300-330 µs per request, which is about 6k req/s in the lab.
  - Kotlin: our design already has both. The same changes are worth roughly −60 µs PG and −5 µs app against a
    non-batching Kotlin baseline (kotlin-vertx 250 → our 143 total).

## 5. Verdict: BEAM vs a hand-written Kotlin JVM/Native server with batching

| | BEAM (best realistic) | our Kotlin (measured) |
|---|---|---|
| App CPU per request (lab) | today 238-313; ideal about 140-180 | **51-61** |
| PG CPU per request (lab) | today 223-313; ideal about 90-110 (same SQL/batching as ours) | **87-118** |
| Lab capacity (2 cores) | today 3.1k (3.9k with best tuning); ideal about 6.5-8k req/s | **13.9k req/s pass** |
| 100k keep-alive connections | trivial (process per conn, ~13 KB/conn incl. buffers → ~1.3 GB) | done (NIO/epoll, buffers released when idle; 1.1 GB RSS mostly heap) |
| Latency fairness | excellent (reduction-based preemption, per-process GC, no global pause) | good enough (short non-blocking continuations; bcrypt on its own thread; G1 pauses are ms, limit is 500 ms) |
| Overload behaviour | DBConnection queue: throughput *drops* past the knee (3,082 → 2,795 req/s); at 64k the author saw 12.5% 503s | batch sizes grow with load, so the cost per request *falls* with load (179 → 143 µs from 8.4k to 13.9k req/s) |

**Where the BEAM wins:**
- Connection count and the effort it takes to handle connections: a process per socket, `+P/+Q`, done.
- Latency isolation and fault isolation.

These are real strengths, but this benchmark does not reward them:
- Every top entry already holds 100k sockets.
- The latency limits are measured in hundreds of milliseconds, where queueing dominates and GC pauses do not
  matter.
- Crash isolation is irrelevant, because crashes are not restarted and are not expected.

**Where the BEAM loses:**
- **Raw CPU per request.**
  - Immutable terms and per-process heaps mean every response is fresh garbage, plus copies between processes.
  - Socket I/O goes through the port layer, about 43% of scheduler time.
  - Every Postgres round trip pays process messaging and the DBConnection ownership protocol.
  - With 70% of the box's CPU going to Postgres at the top, every app µs matters: at 100k users the whole app
    budget is about 61 µs per request.
- **The ecosystem's Postgres drivers do not pipeline or batch.** You would have to write your own, which is
  feasible but it is the same work as in Kotlin, on a slower runtime.

**Answer: Kotlin with batching is the better player, by a wide margin.** Our zero-dependency JVM server already
measures 56 + 87 = 143 µs per request (13.9k req/s pass) on the harness where elixir-raw-foovoo measures 555-600
µs (3.1k req/s), and where its best cheap tuning still costs 490 (3,945 req/s).

## 6. What an ideal BEAM submission would look like, and what it would score

- **HTTP.** Keep foovoo's design. It is already close to the BEAM floor (36 µs for a no-DB request).
  - One process per socket, `active: true`, `decode_packet`, iodata, hibernate only above a heap threshold.
  - `+S` about cores/4 to cores/3 (2-3 on 8), `+sbwt none` x3, `+SDcpu 1`, `+SDio 1`, `+P/+Q`.
- **Postgres.** Drop Postgrex/DBConnection and write about 800 lines of Elixir:
  - 6 read and 2 write *owner* processes, each owning a `gen_tcp` socket.
  - SCRAM auth; statements prepared at connect with explicit OIDs; `plan_cache_mode=force_generic_plan`,
    `jit=off`.
  - Requesters `send` `{kind, params, self()}`. The owner drains its mailbox (≤ 32-64, no timer) and groups by
    kind into `unnest ... WITH ORDINALITY ... CROSS JOIN LATERAL` statements, with one Sync per drained batch.
  - Writes use group commit (BEGIN; …; COMMIT, answered after COMMIT).
  - Same-kind affinity routing, as in rust #1.
- **Zero-decode rows.** The owner splits DataRows by ordinal and sends each requester the raw row binaries.
  These are sub-binaries of one refc buffer, so they cross processes without copying. The requester writes text
  columns straight into the response iodata (escaping only when `:binary.match` finds something) and decodes
  only the int, bool and timestamp columns.
- **SQL.** Port rust #1's statements as they are (tags as one ARRAY row, a combined favorites LATERAL,
  index-only capped counts, a per-request followee set for comments).
- **bcrypt.** A C NIF with libxcrypt's 4-lane interleaved core on 1 dirty CPU scheduler, plus a collection window
  of about 150 ms. This saves about 20-25 µs per request against the current NIF.
- **Expected cost (lab):**
  - app about 140-180 µs: HTTP 36 + JWT 5 + driver 25-60 + JSON 30-60 + bcrypt about 30;
  - Postgres about 90-110 µs;
  - total **about 230-290 µs per request**, or about 6.5-8k req/s on the 2-core harness.

  That is about 1.6-2x ours (143) and rust's (143-153), roughly kotlin-vertx's 250.
- **Expected box score:**
  - Converting component by component with box/lab factors of about 1.37 for BEAM app CPU (370/270 measured for
    this entry) and about 2.0 for Postgres (rust: 213/107) gives 372-535 µs per request on the box.
  - Then 100k x 274 / that gives **about 50-75k users, best guess about 60k: 50-70% of rust #1's 100k**.
  - That is in go-epoll (61k) and rust-hyper (58k) territory, above kotlin-vertx (46k) and well above this entry
    (32k), but it cannot reach rust #1 or our Kotlin. The BEAM app floor alone (about 140-180 µs, or about
    190-250 µs on the box) is 3-4x rust's 61 µs app budget at 100k users.
