# The $12 Server Challenge: what the top entries did, and what carries over to the multicore Postgres challenge

Read-only research for `submissions/kotlin-raw-luben93` (zero-dependency Kotlin, JVM + Kotlin/Native).

Paths: `T/` = `/home/user/arjaythedev/twelve-dollar-server-challenge/`, `S/` = `T/submissions/`,
`M/` = `/home/user/multicore-server-challenge/`, `K/` = `M/submissions/kotlin-raw-luben93/`.
"file:N" is a line number. Everything quoted below is verbatim from those files.

---

## 0. TL;DR

* The $12 contest (1 vCPU, 2 GB, SQLite **in-process**) was decided by two things, in this order:
  (1) getting past the **65,535 file-descriptor limit** (`LimitNOFILE=65535` per process), which capped 4 entries
  at exactly 71,000 users, and (2) **CPU per request** once past it (`T/benchmarks/batch-2.md:29-58`).
  #1 Rust/io_uring held 264,000 users at **30 µs/request**. The JVM entries were 61 µs (Java + FFM epoll),
  79 µs (Kotlin + NIO, 2 JVMs) and 92 µs (Scala + Netty), and those µs **include SQLite execution**.
  The Kotlin entry's own JFR profile says: **~59% of busy time in SQLite `step`, ~17% in socket read/write syscalls,
  "the Kotlin code is a few percent"** (`S/kotlin-nio-3x3xX3N0N/README.md:62`).
* **Most of the headline tricks don't apply to the multicore box.** The fd limit there is 200,000
  (`M/box/challenge.service: LimitNOFILE=200000`) against at most 120k users. So io_uring direct descriptors,
  2 JVMs, idle-connection eviction and `Connection: close` shedding solve a problem we don't have. The SQLite tricks
  (JSON built in SQL, pcache/mmap, checkpoint scheduling, PGO of SQLite) don't apply either. And building JSON in
  the database would move CPU onto Postgres, which is the bottleneck there.
* **What does carry over** is the shape of the event loop: one thread per loop, no per-connection buffers,
  one parse pass over raw bytes, pre-built header templates, one write per response, group commit, and
  **batching wake-ups**. The last one is the cheapest real gain we are not doing yet. Measured: java-nio parks 2 ms
  when a wake-up had < 32 events (~10% CPU), Zig waits for 32 completions or 0.5 ms (23.3% to 19.0% CPU),
  and Rust/C wait for 32/128 completions within 250 µs/4 ms. The same applies to JVM syscall overhead
  (FFM instead of NIO channels cut CPU from 64% to 56% in java-nio), GC configuration, and JWT fast paths.
* The scorer behaves differently in the two contests. The $12 batch 2 restarted the app on a fresh DB for **every probe**.
  The multicore scorer starts the app **once**, warms it up once, then runs all probes and holds **back to back on the
  same process and an evolving database** (`M/bench/cmd/loadgen/search.go:26-31`). So JIT warm-up is irrelevant,
  but heap and RSS must stay stable for 30-60+ minutes, and SQL must stay fast as rows accumulate.

---

## 1. Results, what separated the top, and the limits entries hit

### 1.1 Batch 2 leaderboard (`T/benchmarks/batch-2.md:29-58`; Synteq 1 vCPU Xeon Platinum 8260 @ 2.4 GHz, AVX-512, kernel 6.8)

The README links only this batch (`T/README.md: "Batch 2 ... top score 264,000 users (Rust io_uring, #82)"`). The
CPU% and µs/req columns are for the app's own cgroup over the scored hold, and that includes SQLite.

| # | Submission | Users | req/s | p95/p99 ms | err % | CPU % | µs/req | RAM MB | How it got past 65,535 fds |
|--:|---|--:|--:|--:|--:|--:|--:|--:|---|
| 1 | rust-epoll-scooter1337 (io_uring) | **264,000** | 25,147 | 259/499 | 0.00 | 84 | **30** | 630 | io_uring direct descriptors, 8 rings × 65,535 slots |
| 2 | asm-nasm-melroy89 (io_uring) | 171,000 | 16,777 | 87/142 | 0.00 | 78 | 43 | 358 | io_uring sparse tables, up to 8 |
| 3 | go-epoll-MegaPanchamZ | 165,000 | 16,165 | 194/241 | 0.00 | 89 | 51 | 187 | soft limit: `Connection: close`; hard limit: evict idle (LRU) |
| 4 | asm-epoll-umitaltintas | 155,000 | 15,182 | 208/294 | 0.00 | 89 | 55 | 211 | keep-alive budget (60k total, 20k per client IP); `Connection: close` past it |
| 5 | c-iouring-ssmurfgg04-gif | 150,000 | 14,611 | 385/524 | 0.00 | 78 | 50 | 413 | io_uring direct descriptors, up to 8 workers |
| 6 | go-epoll-champ3oy (io_uring) | 128,000 | 12,604 | 3/23 | 0.00 | 77 | 57 | 385 | 2 rings × 65,535 direct slots on one thread |
| 7 | **kotlin-nio-3x3xX3N0N** | 120,000 | 11,759 | 246/524 | 0.00 | **100** | **79** | 1,380 | **2 JVM processes + SO_REUSEPORT** |
| 8 | c-epoll-TheFirstIstari | 107,000 | 10,493 | 212/409 | 0.94 | 78 | 69 | 169 | token-bucket-paced idle shedding |
| 9 | **java-nio-stohirov (FFM epoll)** | 102,000 | 10,023 | 86/128 | 0.85 | 66 | **61** | 555 | LRU eviction with SO_LINGER=0 (RST) |
| 10 | v-epoll-i098 | 100,000 | 9,848 | 1.5/2.9 | 0.51 | 76 | 72 | 384 | LRU close of the longest-idle connection |
| 11 | node-uwebsockets-zahidcakici | 97,000 | 9,471 | 264/484 | 0.00 | 92 | 90 | 336 | `Connection: close` above limit − 1024 |
| 12 | **scala-netty-jacksonhoran** | 90,000 | 8,801 | 484/757 | 0.00 | 87 | **92** | 825 | reap idle (> 1 s) above fdLimit − 1024 |
| 16 | zig-iouring-marler8997 | 71,000 ᶠ | 6,559 | 1.0/1.5 | 0.93 | **31** | 44 | 199 | none (fd-capped) |
| 16 | cpp-epoll / deno / dart | 71,000 ᶠ | ~6,555 | | 0.93 | | | | none (fd-capped) |
| 21 | csharp-epoll (Native AOT) | 64,000 ᵉ | 6,300 | 23/48 | 0.00 | 31 | 46 | 163 | none; **crashed at EMFILE** |
| 26 | **java-quarkus-wolches** | 29,000 ᵈ | 2,838 | 306/451 | 0.00 | 50 | 164 | 542 | (disk-bound: fsync per commit) |

Notes from the same file:
* ᶠ "**The 65,535 file-descriptor limit, not speed.** These four serve 65,535 keep-alive users and the rest wait in the
  listen queue until mload's 60 s timeout. Each scored run shows exactly ~21,900 timeouts = 0.93 % of requests"
  (`batch-2.md:65-70`).
* "Entries above 71,000 get there by closing idle keep-alive connections ... c-epoll, Java NIO and V show this as EOF/reset
  errors under 1 %; the io_uring entries manage up to ~524k fixed-file slots/rings" (`batch-2.md:72-74`).
* ˣ Rust "**ran out of load generators first.** One target IP × 4 load generators caps at ~240,000 connections (source
  ports)". It was re-searched with 3 extra IPv4 addresses on the box. "360k/480k probes got the app OOM-killed (2 GB box)"
  (`batch-2.md:60-63`).
* ᵈ Quarkus: "**Disk-bound, not CPU-bound.** Quarkus never sets `synchronous`, so SQLite defaults to FULL: an fsync per
  commit, one commit per request — 26–39 % iowait" (`batch-2.md:76-77`).
* ᵉ C#: "When `accept` returns EMFILE, its error path writes to `Console.Error`, whose first use opens a new stderr
  handle — which also fails with 'Too many open files', unhandled, and the process aborts" (`batch-2.md:85-87`).
* ᵍ F#: "the .NET runtime aborts (`PAL_SEHException`, core dump) about a minute into the ramp, as connections pass the
  65,535 fd limit" (`batch-2.md:79-80`).
* Rule flags. "**Tokens without `exp` accepted** (SPEC requires rejecting them): asm-epoll #117, java-nio #88, quarkus #67
  (SmallRye grace), kotlin #83, scala #107, node-uws #102, ..." (`batch-2.md:110-111`). The Kotlin code does exactly this:
  `if (exp != null && (exp !is Double || exp <= nowSec.toDouble())) return INVALID` (`S/kotlin-nio-3x3xX3N0N/src/main/kotlin/nio/Jwt.kt:82`).
  "start.sh restart loops" were also flagged (Deno, c-epoll). The multicore rules forbid both.

### 1.2 What separated the top from the rest

1. **Getting past the fd wall at all.** Everyone at or below 71k is fd-capped, whether at 31% or 94% CPU. Above it the
   order is roughly **inverse µs/request**: Rust 30, asm 43, C 50, Go 51, asm 55, Go 57, Java 61, C 69, V 72, Kotlin 79,
   Node 90, Scala 92. The only exceptions are entries that hit a different wall: rust hit the load generator,
   asm-nasm hit ENOBUFS/latency, and Kotlin hit 2-process SQLite WAL contention.
2. **Where per-request CPU goes at the top**: SQLite and the **kernel TCP stack**, not application code.
   * Rust at 365,500 users: "Period-weighted inclusive cycle stacks place 33.26% under `sqlite3_step`, **34.49% under
     `tcp_sendmsg`**, 14.71% under SQLite B-tree work and 4.21% under JSON escaping" (`S/rust-epoll-scooter1337/IO_URING.md`,
     "Profile-guided experiments").
   * PyPy: "What remains is SQLite (~43%) and the kernel's TCP stack (~38%)" (`S/python-pypy-epoll-pranavds-codes/README.md:72`).
   * asm-epoll: "A request costs about 4 µs of server CPU on `/health`, so the per-request overhead is in the kernel's
     TCP stack and in SQLite, not in this code" (`S/asm-epoll-umitaltintas/README.md:38-39`).
   * Kotlin (JFR): "about 59 % of the busy time is inside SQLite `step` ..., about 17 % is socket read/write syscalls,
     and the Kotlin code is a few percent" (`S/kotlin-nio-3x3xX3N0N/README.md:62`).
   So the winners (a) cut database work per request (live 3-range-scan feed, one shared read snapshot per batch,
   SQLite PGO, no `RETURNING`), (b) cut syscalls and wake-ups (io_uring batched submit, waiting for N completions,
   multishot, adaptive park), and (c) did almost nothing per request in user code (no allocations, no per-connection buffers).
3. **CPU per request falls as load rises** because each wake-up carries more events: "32k users cost 32% of the core and
   64k only 36%" (`S/asm-epoll-umitaltintas/README.md:105-107`). The top entries made this happen on purpose by coalescing
   wake-ups (section 2.2).

### 1.3 Limits entries hit, and how they got around them

| Limit | Who hit it | Workaround (verbatim where it matters) |
|---|---|---|
| `RLIMIT_NOFILE` 65,535 per process | everyone in direct mode | (a) **io_uring direct descriptors**: "Accepted sockets go into each ring's registered file table, rather than the process file table ... With the repository's soft/hard limit of 65,535, Rust creates eight rings of 65,535 slots" (`S/rust-epoll-scooter1337/IO_URING.md`), via `register_files_sparse(slots)` + `AcceptMulti::new(..).allocate_file_index(true)` (`src/uring.rs:277,363-366`). (b) **N processes + SO_REUSEPORT**: "`RLIMIT_NOFILE` applies per process ... `start.sh` starts `WORKERS` (default 2) identical processes" (`S/kotlin-nio-3x3xX3N0N/README.md:23`). (c) per-thread fd tables via `unshare(CLONE_FILES)`, tried and dropped: "It was no faster" (`S/asm-epoll-umitaltintas/README.md:154-161`). (d) **Shedding idle keep-alives**: LRU + `SO_LINGER=0` RST (java-nio `Server.java:147-159`); two tiers, soft `Connection: close` and hard evict (`S/go-epoll-MegaPanchamZ/server_linux.go:114-115,394`); a per-connection keep-alive budget with `MSG_MORE` so the FIN rides the last segment and TIME_WAIT stays on the server (asm-epoll README:61-78); a token bucket (c-epoll, below) |
| Shedding bursts → listen backlog overflow | c-epoll | "a token bucket paces closes to a smooth, sustainable rate (default 2500 per 250ms window = 10k/s). Bursty mass-closes would synchronize thousands of reconnects and overflow the listen backlog, whose retransmit backoff then avalanches (measured at 100k users)" (`S/c-epoll-TheFirstIstari/src/server.c:297-301`) |
| Accept queue (somaxconn **4096** stock on that box) | asm-epoll | "Taking new connections every 128 events within a batch (not just once per `epoll_wait`) mattered near the limit. In one 96k run it cut the kernel's accept-queue overflows from 49,442 to 2,840, and SYN retransmissions from 565 to 0. Each dropped SYN costs the client at least 1 s." (README:150-152; `server.asm:499-500`) |
| EMFILE handling | C# crashed, F# crashed, uSockets spins | Kotlin stops polling OP_ACCEPT until a close (`Server.kt:118-127,145`); asm-epoll takes the listen fd out of epoll (`server.asm:601-630`); Zig: "re-arms after a 100 ms pause if the kernel stops it"; c-epoll: `EMFILE` backoff; node-uws: answers `Connection: close` above `limit − 1024` because "uSockets doesn't back off when `accept()` fails with `EMFILE`" (README:10) |
| Load-generator source ports | Rust at ~240k | organizer added 3 IPs + a 5th LG. Submissions: asm-epoll's 20k-per-client-IP budget |
| 2 GB RAM: **kernel socket memory** | Rust (OOM at 360k/480k), asm-nasm (OOM at 200k/240k), go-nethttp (57k), Haskell (58k) | Rust: "socket-buffer accounting grows from 17 MiB at 131 seconds to approximately 1,352 MiB at 152 seconds" under overload; at 300k connected "Kernel memory is approximately 466–468 MiB" (`IO_URING.md`, Capacity). c-iouring: "Usable memory ... is checked four times a second: below 192 MB new connections are not accepted; below 96 MB idle keep-alives are shed" (README:50-52) |
| io_uring provided-buffer exhaustion (ENOBUFS storms) | asm-nasm at 250k | "7,753,700 ENOBUFS completions, 184,941 input-budget failures ... CQ depth reaching 8,192. Immediate rearming was amplifying exhausted provided-buffer work". Fix: "**send-first**: handle up to 64 send/close completions from a frozen CQ boundary before FIFO receives" + "**enobuf=defer**: park generation-tagged retry IDs in a bounded per-ring FIFO" (`S/asm-nasm-melroy89/PERFORMANCE.md`). Rust: "Depleted receives wait in a bounded retry queue; retries run after buffers are returned and responses are flushed" (README:21) |
| fsync per commit | Quarkus (29k) | (not fixed) group commit and `synchronous=NORMAL` elsewhere |
| conntrack table 65,536 (batch 1, DO + UFW) | cpp anchor 63k, C# local | not fixable from inside the app (no kernel tuning) |
| Runtime caps | uWS, V, Go, Zig | uWS hard-codes a **10 s** idle timeout; patched to 75 s: "most users lost their connection every iteration and had to reconnect" (`S/node-uwebsockets-zahidcakici/README.md`, opt. 2). V: "The `epoll_data` union is declared with its `fd` member only. With a pointer member, V's Boehm GC ... scans the 1,024-entry event array in every loop pass". Go: raw `SYS_EPOLL_PWAIT` with timeout 0 "bypassing Go's `runtime.entersyscall` / `runtime.exitsyscall`" (go-Mega README:29). Zig: AVX-512 zmm clobber bug in the fiber context switch |

### 1.4 The two boxes side by side (why most of 1.3 doesn't apply to us)

| | $12 batch 2 | Multicore |
|---|---|---|
| CPU / RAM | 1 vCPU / 2 GB, app alone (+ in-process SQLite) | 8 vCPU / 16 GB, shared with Postgres (~70% of CPU at the top) |
| fd limit | `LimitNOFILE=65535` | `LimitNOFILE=200000` (`M/box/challenge.service`), users ≤ 120k |
| Kernel | stock: somaxconn 4096, no conntrack | `somaxconn = 65535`, `tcp_max_syn_backlog = 65535`, port range 1024-65535, `tcp_tw_reuse = 1`, `nf_conntrack_max = 1048576` (`M/box/sysctl.conf`, `setup-box.sh`); `vm.max_map_count` default 65530 |
| Load per user | ~0.095 req/s (25,147 / 264,000) | ~0.25-0.26 req/s |
| Client on a server-closed idle connection | k6: EOF/reset counts as an error | loadgen "is retried once on a fresh connection, as browsers do" (`M/bench/cmd/loadgen/client.go:52-55`) |
| Run protocol | "Every probe restarts the app on a fresh database" (`batch-2.md:15`) | `switch.sh` once (fresh DB, app started), one warm-up, then all probes + holds on the **same process and evolving DB** (`M/bench/cmd/loadgen/search.go:26-31`) |

---

## 2. Techniques, per entry

### 2.1 Cross-entry summary

| Entry | Threads / loop | I/O syscalls | Wake-up batching | Per-idle-conn memory | Response build | JWT | Runtime/GC/build |
|---|---|---|---|---|---|---|---|
| rust #1 | up to 8 io_uring issuers, **one global `Mutex<App>`** for the whole SQLite batch | `setup_coop_taskrun().setup_single_issuer().setup_defer_taskrun()`, SQ 4096 / CQ 16384, `register_files_sparse`, buf ring 4096×2 KiB, `AcceptMulti` direct, `RecvMulti` (fixed fd), `Send` + `MSG_NOSIGNAL` | `submit_with_args(min(32, 2·open), timespec 250 µs)` when the last wake-up had ≥ 4 CQEs, else wait for 1 / 2 s | **64-byte** record, no buffers | fixed status-line literals + `itoa` + body, one `Send` | `hmac`/`sha2` crates, reused buffers; one-pass JSON cursor | fat LTO, `codegen-units=1`, `target-cpu=native`, PGO of SQLite on a synthetic DB |
| asm-nasm #2 | 1 owner thread, up to 8 rings | raw io_uring, `0x1100 ; SINGLE_ISSUER \| COOP_TASKRUN (no DEFER)`, **one-shot** provided-buffer recv (multishot failed p99 at 275k), **TCP_NODELAY off** | 32 completions / 250 µs; send-first; deferred ENOBUFS rearm | no buffers, lazy slabs | NASM JSON from column text | assembly HMAC | gcc `-O3 -march=native -flto` + SQLite PGO |
| go-Mega #3 | 1 locked OS thread | raw epoll (LT), `RawSyscall6(SYS_EPOLL_PWAIT, …, 0)` poll before blocking `EpollWait`, raw `accept4`/`read`/`write` | non-blocking poll first when the last wait was non-empty | fd-indexed `conn` slice | **body at `pos+128`, header prepended in place** | single-pass validating walker, zero-copy strings | `debug.SetGCPercent(-1)` + `SetMemoryLimit(512<<20)`; **one cgo call per epoll batch** (`db_exec_batch`); SQLite + engine in one PGO unity TU |
| asm-epoll #4 | 1 thread | epoll LT, raw syscalls, `accept4` | accept every 128 events | 64-byte record by fd | scratch → batch arena, sent after COMMIT | **HMAC inner/outer states precomputed: "each token costs 3–4 SHA-256 compressions"** | NASM; SQLite `-O2` |
| c-iouring #5 | ≤ 8 worker threads, one DB mutex | liburing: `SUBMIT_ALL \| COOP_TASKRUN \| SINGLE_ISSUER \| DEFER_TASKRUN \| CQSIZE`, multishot accept direct, recv multishot, buf ring 2048×2 KiB; listener `TCP_NODELAY` "inherited by accepted sockets on Linux" + SO_KEEPALIVE | `submit_and_wait_timeout(WAIT_NR=128, WAIT_US=4000)` when last_n ≥ 4 | **88-byte** record | 1-page chunks, header written in front of body, one `send` | "HMAC pads are hashed once at startup, so a verification costs two short hash continuations" | `-O3 -march=native -flto` + PGO (server + SQLite) |
| go-champ3oy #6 | 1 thread, 2 rings | liburing `CQSIZE \| SINGLE_ISSUER \| COOP_TASKRUN`, multishot accept direct, recv multishot, eventfd from ring 1 polled by ring 0, cancel+close hard-linked | everything queued in one loop turn goes out in one `io_uring_enter` | small struct | **one cgo call per request**; C writes JSON into the output buffer | `crypto/hmac` | `debug.SetGCPercent(400)` |
| **kotlin-nio #7** | **1 thread per JVM, 2 JVMs** | `java.nio` Selector (epoll), `select(Consumer)` | `select()` / `selectNow()` with pending writes / `select(1)` when the lock is busy | `Conn` object only; one shared 64 KB read buffer + 1 MB direct out buffer | pre-built `head(code)` byte arrays + digits + body; flush per connection | reused `Mac`, generic JSON parse of header/payload into HashMap | `-XX:+UseSerialGC -Xms128m -Xmx320m -Xss512k -XX:+UseCompactObjectHeaders -XX:-UsePerfData`; kotlinc `-Xno-param-assertions -Xno-call-assertions -Xno-receiver-assertions` |
| c-epoll #8 | 1 thread | epoll **ET** + `EPOLLRDHUP`, `accept4(SOCK_NONBLOCK\|SOCK_CLOEXEC)`, `send(MSG_NOSIGNAL)` | `epoll_wait(…, 512, 100)` | 64 B + kernel socket; timing wheel | serialized once, one send | hand-rolled SHA/HMAC | PGO + LTO, no `-march=native` |
| **java-nio #9** | 1 thread | **FFM downcalls** to `accept4`, `epoll_wait`/`epoll_ctl`, `read`, `write`, `close`; `Linker.Option.critical(false)` on all but `epoll_wait` | **"if a wake-up brought fewer than 32 events, the loop parks for 2 ms"** | "256,000 open connections leave about 10 MB of live heap" | `Out` with pre-built status lines, `copyNative` from SQLite text pointer | reused `Mac`, **base64url-encodes the digest and compares to the token text** | `-XX:+UseSerialGC -Xms256m -Xmx256m -Xmn128m -XX:+AlwaysPreTouch -XX:+UseCompactObjectHeaders -XX:MaxDirectMemorySize=64m -XX:ReservedCodeCacheSize=64m -XX:MaxMetaspaceSize=64m` |
| **scala-netty #12** | 1 Netty epoll loop | Netty `EpollIoHandler`, backlog 65535 | Netty flush on `channelReadComplete` | Netty channel + small handler | pooled `ioBuffer`, status line + **Date header** + CL + body, `ctx.write`, flush at read complete | `Mac` + `Base64` | `-XX:+UseSerialGC -Xms512m -Xmx512m -Xmn192m -XX:MaxTenuringThreshold=2 -XX:+AlwaysPreTouch -XX:MaxDirectMemorySize=256m -XX:-UsePerfData -Dio.netty.leakDetection.level=disabled` |
| **quarkus #26** | Vert.x event loop + 2 single-thread worker executors (reader/writer) | Vert.x | — | framework objects | Jackson + RESTEasy Reactive | SmallRye JWT (accepts no-exp tokens via grace) | `-Xms512m -Xmx1g -XX:+UseSerialGC` |

Nobody in the contest used **CDS / AOT cache / Leyden, SQPOLL, SO_BUSY_POLL, TCP_CORK/QUICKACK, writev/sendmsg or
SO_RCVBUF/SNDBUF tuning**. A grep over all 29 submissions finds `TCP_DEFER_ACCEPT` only in PyPy and `MSG_MORE` only in asm-epoll.
Rust tried spinning: "Earlier busy-poll tests showed no reliable gain" (README:99).

### 2.2 Wake-up / completion batching (all the winners do some form of it)

* **Rust** (`S/rust-epoll-scooter1337/src/uring.rs:776-795`):
  ```rust
  let timeout = if last_count >= 4 || !self.rearm.is_empty() {
      types::Timespec::new().nsec(self.tuning.wait_us * 1000)          // wait_us = 250
  } else { types::Timespec::new().sec(2) };
  let wait = if !self.ready.is_empty() { 0 }
      else if last_count >= 4 { self.tuning.batch.min(self.open.saturating_mul(2).max(1)) }   // batch = 32
      else { 1 };
  ... .submit_with_args(wait, &types::SubmitArgs::new().timespec(&timeout));
  ```
  Tuning results (`RESEARCH.md`, "Candidate decisions"): "**Batch target 64 instead of 32** | Rejected ... Keep 32";
  "**Completion wait 1,000 μs instead of 250 μs** | Rejected ... Keep 250 μs"; "One issuer with automatic kernel task
  handling | Rejected. Feed −7.11%, mixed −8.59%"; "One issuer owning App directly, without the mutex | Rejected. Feed −8.13%".
* **c-iouring**: `WAIT_NR 128` / `WAIT_US 4000`, used only when `last_n >= 4` (`src/server.c:45-49,591-597`). Rust notes
  that C's 128/4 ms setting "can otherwise be constrained by that wait" at 64 connections.
* **Zig**: "When the last wait returned completions, it waits for 32 completions or 0.5 ms, whichever comes first,
  instead of one: at 64k users that cut CPU from 23.3% to 19.0% for about 0.4 ms of latency" (README).
* **java-nio** (`Server.java:83-100`), the JVM version of the same idea, on epoll:
  ```java
  long batchNanos = Long.getLong("batch.micros", 2000) * 1000;
  int batchMin = Integer.getInteger("batch.min", 32);
  while (true) {
      int n = Sys.epollWait(ep, events, MAX_EVENTS, 1000);
      ...
      for (int i = 0; i < n; i++) onEvent(Sys.eventFd(events, i), Sys.eventFlags(events, i));
      commitPhase();
      ...
      if (n > 0 && n < batchMin && batchNanos > 0) LockSupport.parkNanos(batchNanos);
  }
  ```
  README: "With ~0.1 req/s per user, most wake-ups would otherwise carry a single request. This saves about 10% of
  CPU for about 2 ms of latency. Busy wake-ups don't park, so the pause never caps throughput."
* **Go-Mega**: after a non-empty wait, it polls first with a raw `SYS_EPOLL_PWAIT` (timeout 0) and only blocks when that
  returns nothing (`server_linux.go:153-160,587-600`).
* Counter-evidence for **timer-based commit windows**. Node-uws: "I also tried a 5–20 ms commit window to collect bigger
  batches. At k6 rates it saved no measurable CPU and only added latency, so a batch is simply whatever arrived in one
  event-loop turn" (README, opt. 6). PyPy skipped group commit entirely: "Writes are ~8% of requests; savings estimated
  at under 1% of CPU". So batching wake-ups is worth it. A timer that delays commits is not.

### 2.3 Top 8, entry by entry

**#1 rust-epoll-scooter1337 (264k, 30 µs/req).** Despite the name it is io_uring (`src/uring.rs`), with an epoll path
kept for comparison. Key points:
* Ring: `IoUring::builder().setup_cqsize(16384).setup_coop_taskrun().setup_single_issuer().setup_defer_taskrun().build(4096)`,
  then `register_files_sparse(slots)` and `register_buf_ring_with_flags(.., NBUFS=4096, GROUP, 0)` with `BUFSIZE = 2048`
  (`uring.rs:20-24,270-292`). Falls back to `ProvideBuffers` if buf rings aren't available.
* Accept: `opcode::AcceptMulti::new(types::Fd(self.listener)).allocate_file_index(true)` (direct descriptors).
  Recv: `opcode::RecvMulti::new(types::Fixed(fd), GROUP)`. Send: `opcode::Send::new(types::Fixed(fd), ptr, len).flags(libc::MSG_NOSIGNAL)`
  (`uring.rs:362-399`).
* Listener: `listen(fd, 4096)` and **`TCP_NODELAY` set on the listening socket** so accepted sockets inherit it
  (`uring.rs:951-964`; c-iouring says the same thing explicitly: `/* inherited by accepted sockets on Linux */`, `src/server.c:881`).
  It raises only the soft `RLIMIT_NOFILE` to the hard limit.
* Per connection: "One 64-byte connection record. Partial inputs allocate on demand. Output allocations remain fixed
  until the last send completion, then return to a bounded pool. Idle connections retain no response buffers.
  Generations reject stale completions after slot reuse; backpressure pauses reads until output drains" (README:23).
* Ordering: all SQLite work of one completion batch runs under one mutex, then `app.db.commit()`, then
  `self.flush(committed)` (sends), then the checkpoint (`uring.rs:812-838`).
* Responses: status-line literals + `"Content-Type: application/json\r\nContent-Length: "` + `itoa` + body
  (`uring.rs:899-916`).
* DB-side wins (the analog of our SQL work): the "dense-range feed" (top-20 ids, then two range scans if span < 256) and a
  shared deferred read transaction per batch ("Feed | 32,558 | 40,097 | +23.2%", README:47-52). It also rejected a lot,
  with paired, balanced A/B trials (RESEARCH.md table): SQL `GROUP BY` for like counts −16%, a thread checkpointer
  +20-22% CPU/request, handwritten AVX2 JSON escape not faster.
* Build: Rust `opt-level=3, lto="fat", codegen-units=1, panic="abort"`, `-C target-cpu=native`; SQLite built with
  `-fprofile-generate`, trained on `bench/train_sqlite.c` (synthetic DB), then `-fprofile-use -fprofile-correction` (`build.rs`).
* Allocation discipline: "seven allocation/reallocation calls per ordinary create and four per like before the changes,
  and zero afterward" (BENCHMARKS.md:116).

**#2 asm-nasm-melroy89 (171k, 43 µs/req, best p99 among the top: 142 ms).**
* `mov dword [r12+264],0x1100 ; SINGLE_ISSUER | COOP_TASKRUN (no DEFER)` (`src/uring.inc:130`); sparse file
  registration sized by `RLIMIT_NOFILE` (`uring.inc:142-152`); no SQPOLL ("No SQPOLL, no liburing", `uring.inc:72`).
* Defaults: "shared frozen-batch transactions, reference SQL, NASM JSON, **one-shot provided receives,
  32-completion/250-us bounded coalescing**, eight available rings, **TCP_NODELAY off**, send-first completion processing
  and deferred ENOBUFS recovery" (README:104-107). "Multishot receive improved one saturation screen but failed a
  275k short population screen (p99 1,187.6 ms). The one-shot control passed at 275k with p99 90.9 ms" (PERFORMANCE.md).
* The NASM JSON writer beat SQL-generated JSON: "requests per server CPU second averaged 50,875 versus 54,365 (about 6.9%
  improvement)". The shared transaction at "128 completions / 6 ms" collapsed to 4,107 req/s at 64 clients: the wait
  dominates when the target exceeds the active population.
* Bodies > 16 KiB rejected; 32 KiB input / 64 KiB response slabs, lazily touched; "idle sockets own no buffers".

**#3 go-epoll-MegaPanchamZ (165k, 51 µs/req).**
* One OS thread (`runtime.LockOSThread()`), raw epoll, raw `accept4`/`read`/`write` via `syscall.RawSyscall`
  (`server_linux.go:87,319,602-612`). `syscall.Listen(fd, 65535)`. `TCP_NODELAY` per accepted socket.
* **One cgo crossing per epoll batch.** All parsed requests of a wake-up go into an op array, and
  `C.db_exec_batch(ctx, n_ops, now_ms, uptime_s)` runs them and serializes responses into a C arena (`shim.h:23-67`).
  "eliminating ~250 wrapper function calls per `GET /feed`" by reading `((Vdbe *)stmt)->pResultRow[i]` directly in a
  unity build with sqlite3.c (README:17).
* "**Zero-Copy HTTP Header Prepending**: Each operation writes its JSON payload into the C output arena starting at
  `pos + 128`, computes the exact `Content-Length`, and prepends the HTTP/1.1 response headers directly in front of
  `body_start` (`body_start - hdr_len`), eliminating intermediate body buffers and `memcpy` passes" (README:35).
* SSE2/NEON 16-byte JSON escape check; "2-Digit Lookup `u64toa`" with a 200-byte `digits2` table (README:34).
* Timestamps formatted once per millisecond in C and bound statically, which removes `strftime()` and `RETURNING`'s
  ephemeral table (README:18).
* GC: `debug.SetGCPercent(-1); debug.SetMemoryLimit(512 << 20)` with the comment "Steady state allocates nothing"
  (`main.go:10-12`).
* Shedding: `softMax := max(nofile-4096, nofile*7/8)`, `hardMax := max(nofile-256, nofile*15/16)`; above soft,
  `closeAfter := req.close || (s.openConns >= s.softMaxFDs && pos == len(data))` (`server_linux.go:114-115,394`).

**#4 asm-epoll-umitaltintas (155k, 55 µs/req).** One thread, LT epoll, raw syscalls. The batch is read, parsed and
handled. The first write opens the transaction, and the batch is "**committed first**, and only then are all responses sent"
(README:22-34). JWT: "The HMAC inner and outer states are computed once from the secret at startup, so each token costs
3–4 SHA-256 compressions" (README:46-49). The checkpoint lesson: the WAL grew to 247 MB and "`/feed` slowed from 37 µs to
123 µs" until the loop finished the checkpoint itself at 4096 frames. "Taking new connections every 128 events within a
batch" (above). A 64-byte record per fd; "RSS stays around 25 MB with 64k open connections". It tried a one-range-scan feed
variant: "about 30% slower, so the simple query stayed".

**#5 c-iouring-ssmurfgg04-gif (150k, 50 µs/req).** `IORING_SETUP_SUBMIT_ALL | IORING_SETUP_COOP_TASKRUN |
IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_CQSIZE` (`src/server.c:517-518`, with a fallback to
`CQSIZE` only); `io_uring_prep_multishot_accept_direct`, `io_uring_prep_recv_multishot`, `io_uring_setup_buf_ring`
(2048 × 2 KiB per worker); `io_uring_prep_send(.., MSG_NOSIGNAL)`. Listener: `SO_REUSEADDR`, `TCP_NODELAY` ("inherited by
accepted sockets on Linux"), `SO_KEEPALIVE` with `TCP_KEEPIDLE 120 / KEEPINTVL 10 / KEEPCNT 3`, `listen(fd, 1024)`
(`server.c:880-889`). "No allocation on the request path. Requests are parsed in place in the receive buffers; responses are
built into one-page chunks from a per-worker arena, with the header written in front of the body and sent with one `send`.
Freed chunks are reused cache-hot first." "A connection with more than 64 KiB of unsent responses stops being read until half
is out" (README:46-55). The epoll fallback uses `EPOLLIN | EPOLLEXCLUSIVE` on a shared listener (`server.c:756`).

**#6 go-epoll-champ3oy (128k, 57 µs/req, best latency: p95 3 ms).** Two rings on one thread (2 × 65,535 direct slots).
"A ring other than the first signals an eventfd that the first ring polls, so the loop only ever blocks in one place."
"Everything one loop iteration queues (sends, re-armed receives, closes) goes to the kernel in a single `io_uring_enter`.
Closing a connection is a hard-linked cancel-then-close, because a pending multishot receive keeps its own reference to the
socket" (README:27-38). Ring flags `CQSIZE | SINGLE_ISSUER | COOP_TASKRUN` (`uring.c:47`); send uses
`MSG_NOSIGNAL | MSG_WAITALL` (`uring.c:125`). SQLite runs in C with one cgo call per request. `debug.SetGCPercent(400)`.

**#7 kotlin-nio-3x3xX3N0N (120k, 79 µs/req at 100% CPU, the closest relative of our JVM build).**
* Loop (`Server.kt:85-103`):
  ```kotlin
  ss.setOption(StandardSocketOptions.SO_REUSEPORT, true)
  ss.bind(InetSocketAddress(host, port), 65535)
  ...
  when {
      writes.isEmpty() -> sel.select(onKey)
      lockBusy -> sel.select(onKey, 1) // another worker holds the write lock: keep serving, retry in ~1 ms
      else -> sel.selectNow(onKey)
  }
  if (writes.isNotEmpty()) runBatch()
  ```
  `Selector.select(Consumer<SelectionKey>)` (JDK 11+) avoids the selected-key `HashSet`.
* Buffers: one shared `ByteArray(64 * 1024)` read buffer and one shared `ByteBuffer.allocateDirect(1 shl 20)` output
  buffer. A connection holds `pending` input or `out` only when needed (`Server.kt:13-21,38-40`).
* Parse: finds `\r\n\r\n` by checking `b[i + 3] == '\n'` first. It switches on header-name **length** (14 → content-length,
  13 → authorization, 10 → connection, 17 → transfer-encoding) before an ASCII case-fold compare (`Server.kt:188-252`).
* Response: `private fun head(code: String) = a("HTTP/1.1 $code\r\nContent-Type: application/json\r\nContent-Length: ")`
  plus reversed digits plus `\r\n\r\n` or `\r\nConnection: close\r\n\r\n` plus body, into the shared direct buffer, then one
  `ch.write(obuf)` per connection per pass (`Server.kt:55-64,408-441`).
* EMFILE: `acceptKey.interestOps(0)` until any close (`Server.kt:120-127,145`).
* Group commit once per loop pass; a connection with a write in flight doesn't parse its next pipelined request
  (`Server.kt:329-394`).
* JWT: one `Mac`, HMAC over the header bytes in place, constant-time compare, then **a generic JSON parse of header and
  payload into `HashMap`s (numbers as `Double`)**, which allocates (`Jwt.kt:49-95`). It also accepts tokens without `exp` (flagged).
* JVM: `-XX:+UseSerialGC -Xms128m -Xmx320m -Xss512k -XX:+UseCompactObjectHeaders -XX:-UsePerfData --enable-native-access=ALL-UNNAMED`
  (start.sh:15-17). Kotlin: `freeCompilerArgs.add("-Xno-param-assertions")`, `"-Xno-call-assertions"`,
  `"-Xno-receiver-assertions"`, `jvmTarget = JVM_21` (build.gradle.kts:14-19). JDK Temurin 25.0.4.1.
* Limiter: "Above ~100k the limit is two processes sharing one SQLite file, not CPU: the WAL rarely gets a moment with no
  reader in either process" (README:60). Two JVMs cost 1,380 MB.

**#8 c-epoll-TheFirstIstari (107k, 69 µs/req).** ET epoll with `EPOLLRDHUP`, `accept4(..., SOCK_NONBLOCK | SOCK_CLOEXEC)`,
`listen(fd, 4096)`, `epoll_wait(Gep_fd, evts, 512, 100)` (`src/server.c:171,469,487,505`). It removed SO_REUSEPORT so that a
"second instance must fail loudly, never split traffic" (`dev/RESULTS.md`). It rejected the 3-range-scan feed ("13.4µs vs
reference 8.9µs at SQLite level"). The token-bucket shedding is quoted above. It never sheds a connection that has unread
bytes (`ioctl(c->fd, FIONREAD, &pending)`).

### 2.4 The other JVM entries

**java-nio-stohirov (#9, 102k, 61 µs/req, 66% CPU: fd/eviction-limited, not CPU-limited).** This is the most relevant JVM evidence.
* **No `java.nio` channels: Linux syscalls via FFM.** "`SocketChannel` and `Selector` added work on every connection: `fcntl`
  calls to make it non-blocking, two `getsockname` calls on accept, deferred deregistration and close in the selector, and
  several objects and locks per connection. A connection is now an `int` fd in a small object ... At 256k simulated users this
  **cut server CPU from 64% to 56%** and moved the local ceiling from about 330k to about 390k users" (README:28-33).
  Caveat: that regime had heavy reconnect churn from evictions, so the per-accept savings are overweighted relative to
  our long-lived connections.
* Handles (`Sys.java:40-72`):
  ```java
  private static final Linker.Option CRITICAL = Linker.Option.critical(false);
  private static final Linker.Option ERRNO = Linker.Option.captureCallState("errno");
  ACCEPT4  = fn("accept4", FunctionDescriptor.of(JAVA_INT, JAVA_INT, ADDRESS, ADDRESS, JAVA_INT), CRITICAL, ERRNO);
  EPOLL_CTL = fn("epoll_ctl", ..., CRITICAL);
  // Blocks, so not critical: a GC must be able to run while the loop waits.
  EPOLL_WAIT = fn("epoll_wait", ..., ERRNO);
  READ  = fn("read",  FunctionDescriptor.of(JAVA_LONG, JAVA_INT, ADDRESS, JAVA_LONG), CRITICAL, ERRNO);
  WRITE = fn("write", FunctionDescriptor.of(JAVA_LONG, JAVA_INT, ADDRESS, JAVA_LONG), CRITICAL, ERRNO);
  ```
  `accept4(fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC)` + `setsockopt(TCP_NODELAY)` per connection. `epoll_event` is
  12 bytes packed on x86_64 (`EVENT_SIZE = X86 ? 12 : 16`); `epoll_data` carries the fd itself. `close(fd)` "also removes it
  from the epoll set". `listen(..., 4096)`.
  Note: it uses `critical(false)` and **copies** between heap arrays and native segments (`MemorySegment.copy(in, ..., rb, ...)`,
  `Server.java:208`). `critical(true)` would let it pass heap arrays straight to `read`/`write`.
* Adaptive park, quoted in 2.2.
* Out: `ByteBuffer.allocateDirect` + `MemorySegment.ofBuffer`, pre-built `"HTTP/1.1 " + s + "\r\nContent-Type: application/json\r\n"`
  plus `Content-Length` plus `\r\n\r\n` (`Out.java:7-40`).
* JWT: checks `alg` first, then HMAC, then **encodes the 32-byte digest to 43 base64url chars and compares them against the
  token text in constant time** (`Jwt.java:77-100`). The header and payload are still decoded with `Base64.getUrlDecoder()`
  plus a generic parse.
* JVM flags (start.sh:7-11): `-XX:+UseSerialGC -Xms256m -Xmx256m -Xmn128m -XX:+AlwaysPreTouch -XX:+UseCompactObjectHeaders
  -XX:MaxDirectMemorySize=64m -XX:ReservedCodeCacheSize=64m -XX:MaxMetaspaceSize=64m --enable-native-access=ALL-UNNAMED`.
  "Steady state allocates about 1 MB/s, so a young GC happens every couple of minutes" (README:86-88).
  Build: `javac --release 25 -Xlint:all,-restricted,-serial -Werror` plus a manifest `Enable-Native-Access: ALL-UNNAMED`.

**scala-netty-jacksonhoran (#12, 90k, 92 µs/req).** One Netty epoll event loop
(`MultiThreadIoEventLoopGroup(1, EpollIoHandler.newFactory())`), `SO_BACKLOG 65535`, `TCP_NODELAY`. It uses a hand-written
HTTP layer on raw `ByteBuf`s, with parse scratch shared on the one thread ("an idle connection costs just its Netty channel and
a tiny handler object"). It writes into `ctx.alloc().ioBuffer(...)` and flushes once in `channelReadComplete`. It adds a
`Date` header refreshed by a 1 s scheduled task (`Http.scala:31-35,189-199`). JVM: `-XX:+UseSerialGC -Xms512m -Xmx512m
-Xmn192m -XX:MaxTenuringThreshold=2 -XX:+AlwaysPreTouch -XX:MaxDirectMemorySize=256m -XX:-UsePerfData
-Dio.netty.leakDetection.level=disabled`. "Objects are promoted after 2 young GCs, so long-lived connection objects stop being
copied between survivor spaces" (README:57-59). It was 1.5× java-nio's µs/request.

**java-quarkus-wolches (#26, 29k).** Quarkus REST + Jackson + SmallRye JWT + Agroal + sqlite-jdbc, two single-thread
Vert.x worker executors. It lost to fsync-per-commit (`synchronous` FULL by default), and the framework is 164 µs/req even
before that. Only negative lessons: framework layers and per-request object graphs; `quarkus.http.auth.proactive=false`
as the only tuning.

### 2.5 Other notable single techniques

* **AOT vs JIT (C#)**: "the fastest C# entry ... would get a lot faster with Native AOT. It didn't. On the same box,
  **AOT alone scored 7.6% lower than the JIT**. The time was going into the framework and the thread pool, not into the
  compiler" (`S/csharp-epoll-gichamba/README.md:6-9`). "PR #27's code (built with AOT) caused about 50,000 context switches a
  second at 52,000 users; this one causes about 4,300 at 64,000 users" (README:37-39). Its .csproj:
  `<ServerGarbageCollection>false</ServerGarbageCollection><ConcurrentGarbageCollection>false</ConcurrentGarbageCollection>`,
  `<IlcInstructionSet>x86-64-v3</IlcInstructionSet>`.
* **Node-uws**: "JWT verification with a `KeyObject`. `createHmac('sha256', buffer)` re-imports the raw key on every call ...
  about +5% on the mixed load" (README, opt. 8); `--max-semi-space-size=64`: "fewer young-generation GCs, +3%" (opt. 9).
* **PyPy**: "A fast path for the standard `{"alg":"HS256","typ":"JWT"}` header skips decoding that header (a pure function of
  its bytes), never the signature check": `HS256_HEADERS = {b"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"}` (`server.py:64,163`).
  "HMAC via OpenSSL's one-shot `HMAC()` ... 1.7 µs instead of PyPy's `hmac.digest` at 11.4 µs". It also judged that
  "**Coalescing concurrent identical reads** (one feed query answering every `/feed` request in the same event-loop batch)
  ... shares one query result between requests, which reads as a query-result cache under rule 5, so it is left out".
  That is consistent with our "share a statement, never a result" rule.
* **Query rewrites need an evolving dataset.** PyPy's range-scan feed was "17% faster on the fresh seed (98 → 82 µs) but **4.7×
  slower (331 → 1,543 µs) once recent posts collect likes**, from SQLite's temp B-tree for the `GROUP BY`". Rust, Go-Mega,
  c-iouring, V and Zig kept a guarded variant (span < 256 / < 64 ids, else the reference query). c-epoll and asm-epoll rejected it.
* **Zig**: fibers with idle stacks packed to ~160 bytes and `madvise(DONTNEED)`; `IORING_RECVSEND_POLL_FIRST` on a recv that
  waits for the next request ("skipping a recv that would find nothing"); `SINGLE_ISSUER | DEFER_TASKRUN | COOP_TASKRUN | SUBMIT_ALL`.

---

## 3. What transfers to the multicore Postgres challenge

### 3.1 The budget we are optimizing

Multicore #1 (rust-tokio): 26,279 req/s at 20% app / 70% Postgres of 8 cores = **61 µs app + 213 µs PG per request**
(see `research/kotlin-prior.md` §0). Capacity ≈ (0.9-0.95 × 8 cores) / (app µs + PG µs). Saving 10 µs of app CPU per request
is worth about +3.5% users. So is saving 10 µs of PG CPU, but the PG levers are bigger (that is our SQL and batching work,
not this document). The $12 results bound what the HTTP/JSON/JWT layer has to cost. Kotlin-nio's JFR says that "the Kotlin
code is a few percent" of 79 µs, socket syscalls are ~17% (~13 µs), and SQLite is the rest. So **a JVM HTTP layer can cost
~15-20 µs per request, and most of that is kernel TCP + syscalls.** Our app budget then goes mainly to the PG wire client,
JSON from binary rows, JWT and bcrypt (~0.054 ms/request at 100k users, per kotlin-prior.md).

### 3.2 Does NOT transfer (or contradicts our design): don't do these

| $12 technique | Why not here |
|---|---|
| io_uring direct descriptors, multiple rings, 2+ processes, `unshare(CLONE_FILES)` | They solve `RLIMIT_NOFILE` 65,535; we have 200,000 for ≤ 120k users. **Multiple JVMs would also split the PG batching queues** (smaller batches, more backends against the ≤ 95-connection cap), which works against our core lever |
| Idle eviction / `Connection: close` shedding / token buckets / keep-alive budgets / `MSG_MORE`+FIN tricks / TCP_DEFER_ACCEPT | No fd pressure, connections are long-lived, ~2k accepts/s only during the ramp. DESIGN's "no idle timeout" is right (uWS's 10 s timeout caused churn and errors) |
| JSON built by the database (`json_object`/`group_concat`; kotlin-nio, java-nio, node-uws, pypy) | It was a win only because SQLite ran in-process on the same core. On the multicore box it moves CPU onto Postgres, the 70% bottleneck. **Our DESIGN (JSON written from binary rows in the app) is right; keep it** |
| SQLite pragmas, checkpoint scheduling, pcache/mmap, SQLite PGO, unity TU with sqlite3.c, `-march=native` on the DB | Postgres is a fixed box install (`M/box/pg-conf.sh`); only session `SET`s are allowed |
| Busy polling / spin (`--spin-us`), SQPOLL | "no reliable gain" even on 1 core; on 8 shared cores a spinning thread steals CPU from Postgres |
| Timer-based commit/read windows (5-20 ms) | node-uws: no CPU saved, only latency. Let batches form naturally while the previous batch is in flight, as DESIGN already does ("send next batch first") |
| `TCP_NODELAY` off (asm-nasm) | Its own docs don't establish a gain. The multicore loadgen sets `NoDelay` client-side, and multi-segment list responses on a real NIC can stall on Nagle + delayed ACK. Keep NODELAY on |
| Date header (scala-netty) | Not required by the spec or conformance; only cost |
| Tolerating missing `exp` (kotlin, java-nio, scala, quarkus) | Flagged in the $12 contest; the multicore rule 7 requires `exp` checks. **Our `Jwt.verify` must reject a token with no numeric `exp`** |
| start.sh restart loops (c-epoll, Deno) | Multicore rule 9 / `Restart=no`. Our `exec java` is right |

### 3.3 Transferable, ranked by expected impact

The impact estimates are mine. They scale the $12 measurements to our ~26k req/s over 2 HTTP loops, where each loop sees
~13k req/s, i.e. one event every ~75 µs unless events are coalesced. **JVM** = HotSpot build; **K/N** = Kotlin/Native build.

| # | Technique (source) | JVM | K/N | Expected impact and notes |
|--:|---|:-:|:-:|---|
| 1 | **Coalesce wake-ups on the HTTP loops**: if a wake-up returned < 32 events, sleep ~250-1000 µs before the next `epoll_wait`/`select` (java-nio `parkNanos(2ms)` if `n < 32`: ~10% CPU; Zig 32 CQEs or 0.5 ms: 23.3% → 19.0%; Rust/asm 32 or 250 µs, and 64 or 1 ms measured no better) | ✔ | ✔ | **High and cheap.** It saves the futex/epoll wake-up + scheduler + cache-refill cost per event on the loop threads, and fewer wake-ups also disturb Postgres' cores less. It adds ≤ 1 ms of latency against a 500 ms p95 budget. Apply the same idea to anything else that wakes per item: cross-thread `execute()` eventfd writes (our Native `post` writes the eventfd on every post while the loop sleeps), bcrypt workers, PG writer wake-ups. Expect −3 to −8 µs/req of app CPU. Implement as "after processing, if n < 32 && n > 0: park(250 µs)", not by delaying responses: PG threads write responses directly, so they are not held |
| 2 | **JVM: FFM syscalls instead of NIO channels** (java-nio: CPU 64% → 56% at 256k users; removes `fcntl` + 2×`getsockname` per accept, selector deregistration/close machinery, per-connection objects and locks). Use `Linker.Option.critical(true)` (allowHeapAccess, JDK 22+) for `recv`/`send`/`epoll_ctl`/`accept4`, so heap `ByteArray`s go to the kernel **without the copy** that both NIO (temporary direct buffer per heap write) and java-nio (`MemorySegment.copy`) make; **not** for `epoll_wait` ("Blocks, so not critical: a GC must be able to run") | ✔ | n/a | **Medium-high for JVM** (expect −3 to −8 µs/req). `K/jvmMain/.../PlatformJvm.kt:95` is still `TODO("jvm: NIO event loops")`, so this is the moment to choose. The Native `EpollLoop`/`NativeConn` (`K/linuxX64Main/.../NativeHttp.kt`) is already the FFM-shaped design (fd table, CLOSING bit + writer count for cross-thread `send`, eventfd + MPSC task stack), so a JVM port of it is mostly mechanical. With NIO, use `Selector.select(Consumer)` (kotlin-nio) and remember that `SocketChannel.write(heapBuf)` copies |
| 3 | **Zero allocations per request on the hot path**: idle connections hold nothing, one shared read scratch per loop, per-thread output buffers, a pending-input stash only for partial requests (every top entry; Rust counted 0 allocations per request; go-Mega runs with GC off) | ✔ | ✔✔ | **High for K/N**, medium for JVM. K/N's GC (`gradle.properties: kotlin.native.binary.gc=pmcs`) is non-generational and much more expensive per allocated byte than HotSpot's TLAB + young GC. The C# data point shows that AOT without a good allocator/GC lost 7.6% to the JIT |
| 4 | **GC configuration** (all JVM entries: SerialGC, fixed heap, AlwaysPreTouch, `-XX:-UsePerfData`, compact headers; Go: `SetGCPercent(-1)`/`(400)`; Node: bigger semi-space) | ✔ | ✔ | **Medium.** JVM: `K/start.sh` sets no collector, so it gets **G1 by default** (barriers + concurrent refinement threads + 8 parallel GC workers that compete with PG during pauses). Try `-XX:+UseParallelGC -XX:ParallelGCThreads=2 -Xmn512m` or `-XX:+UseSerialGC -Xmn512m`, plus `-XX:-UsePerfData` (missing). Keep `-Xms=-Xmx`, `-XX:+AlwaysPreTouch`, `-XX:+UseCompactObjectHeaders`. Measure µs/req and pause p99. K/N: `kotlin.native.runtime.GC.targetHeapBytes` **defaults to 10 MiB** and `minHeapBytes` to 5 MiB (`kotlin/native/runtime/GC.kt`), so set e.g. `GC.minHeapBytes = 256L shl 20` (with `autotune`) or `GC.autotune = false; GC.targetHeapBytes = 512L shl 20` at startup (`@NativeRuntimeApi`). Binary options available: `gc`, `gcSchedulerType`, `gcMarkSingleThreaded`, `auxGCThreads`, `pagedAllocator` |
| 5 | **Single-pass, length-switched header parse over raw bytes; only the needed headers** (`Authorization`, `Content-Length`, `Connection`, `Transfer-Encoding`; kotlin-nio `when (colon - p) {14 -> … 13 -> …}`; c/asm; go-Mega `IndexByte('\n')` + word compare) | ✔ | ✔ | Medium-low. Our Exchange API exposes `path`, `query`, `authorization` as **`String`**s (`K/commonMain/.../http/Http.kt:43-49`), i.e. 2-3 String allocations + UTF-16 decode per request. Consider offsets into the request bytes (or lazy Strings) for routing and JWT, which is what every top entry does. The multicore loadgen sends `Host`, `User-Agent`, `Accept`, `Accept-Encoding: gzip`, `Authorization: Token …` (`M/bench/cmd/loadgen/client.go:63-71`), so skip unknown headers by length first |
| 6 | **JWT fast paths**: (a) compare the header segment against the known base64url bytes of our own header before any decoding (PyPy); (b) precompute HMAC inner/outer midstates from the secret (asm-epoll, c-iouring: "two short hash continuations"), which cuts 5 SHA-256 compressions to 3 for our ~100-byte token; (c) encode the digest to base64url and compare it to the token's 43 signature chars (java-nio); (d) scan the decoded payload for `"sub"`/`"exp"` without building a map | ✔ (a,c,d) | ✔✔ (a-d) | Low-medium. JVM: keep `javax.crypto.Mac` (HotSpot SHA-256 intrinsics: SHA-NI or AVX2), whose `HmacCore` re-hashes the ipad block every call, but intrinsic compressions are cheap. Do (a), (c), (d): kotlin-nio's HashMap/Double parse is the allocation to avoid. K/N: our pure-Kotlin SHA-256 makes (b) worth ~40% of the JWT cost (≈ 0.5-1 µs/req). Also reject a missing `exp` (3.2) |
| 7 | **One write per response, header in front of the body without a copy**: write the JSON body at a reserved offset (go-Mega `pos + 128`), then fill the status line + `Content-Length` right-aligned in front of it and `send(buf, start, len)` once. c-iouring does the same ("header written in front of the body") | ✔ | ✔ | Low (saves a memcpy of 1-10 KB per response, ~0.2-0.5 µs). DESIGN already says "header+body, one non-blocking write"; make sure that isn't implemented as "copy body into a new header+body array". With cross-thread writes, a partial write must copy the tail into a per-connection buffer (Rust/c-iouring keep a bounded pool of such buffers) |
| 8 | **Kotlin compiler flags** `-Xno-param-assertions -Xno-call-assertions -Xno-receiver-assertions` (kotlin-nio build.gradle.kts:16-18) | ✔ | — | Low (~0-2%): smaller bytecode, so more inlining under C2's size budgets. Free: add them to `compilerOptions.freeCompilerArgs` for the jvm target (`K/build.gradle.kts` has only `-Xexpect-actual-classes`) |
| 9 | **Fast JSON escaping/integers**: scan 8 bytes at a time when nothing needs escaping (V; go-Mega SSE2), a 2-digit lookup itoa (go-Mega), pre-encoded keys (ours: `JsonName`) | ✔ | ✔ | Low-medium for article pages (`body` ≈ 1 KB). Rust profile: JSON escaping ~4% of cycles; handwritten AVX2 "not faster". JVM: read 8 bytes via a `VarHandle` (`MethodHandles.byteArrayViewVarHandle(LongArray::class.java, LITTLE_ENDIAN)`) and use a SWAR test for `"`, `\`, `< 0x20`. K/N: the same with `Long` assembled from bytes, or just a tight byte loop; measure first |
| 10 | **accept path**: `accept4(SOCK_NONBLOCK\|SOCK_CLOEXEC)` instead of `accept` + `fcntl(F_GETFL)` + `fcntl(F_SETFL)` (java-nio, c-epoll, asm, go-Mega); set `TCP_NODELAY` once on the **listener**, since accepted sockets inherit it on Linux (c-iouring `server.c:881`, Rust `uring.rs:952-962`); drain the accept queue in a loop and also between event batches when busy (asm-epoll: every 128 events) | — | ✔ | Low (≈ 120k accepts per run). Our Native `acceptAll` does `accept` + 2 `fcntl` + `setsockopt` + `epoll_ctl` per connection (`NativeHttp.kt:201-224`). It also uses `memScoped { alloc<…> }` for `ctl()` and `setsockopt`, a native malloc/free per call; `handle()` calls `ctl(EPOLL_CTL_MOD)` on every EPOLLOUT. Preallocate one `epoll_event` per loop for loop-thread calls |
| 11 | **Backpressure and send-first under overload**: stop reading a connection with > 64 KiB unsent (c-iouring, Rust); finish sends before taking new work (asm-nasm "send-first" fixed its 250k collapse) | ✔ | ✔ | Low at the target load (the loadgen is closed-loop, one request in flight per user), but it is cheap insurance against tail collapse near the limit. In our design PG threads answer directly, so responses never queue behind new reads on the loop. Keep it that way |
| 12 | **io_uring on Native** (multishot accept/recv, buf ring, `SINGLE_ISSUER\|DEFER_TASKRUN\|COOP_TASKRUN`, `submit_and_wait_timeout(32, 250 µs)`, `Send` + `MSG_NOSIGNAL`, cancel+close linked) | — | ✔ | Low-medium, later. It wins on 1 core by batching syscalls, but the per-request kernel TCP cost (`tcp_sendmsg` ~34% at 365k) stays, and on the multicore leaderboard io_uring didn't decide anything (c-iouring #3 at 84k vs rust-tokio/epoll #1 at 100k, both ~0.068 ms app/request). Known traps: ENOBUFS rearm storms, multishot recv p99 regressions (asm-nasm), Docker's default seccomp blocking io_uring in local tests, a stale listener reference after SIGKILL (Rust retries `EADDRINUSE` up to 200 × 50 ms). Not for the JVM (no zero-dependency route) |

### 3.4 Things in our DESIGN that the $12 evidence confirms

* **No per-connection buffers / threads, a shared read scratch**: every top entry; also needed for `vm.max_map_count = 65530`
  (DESIGN, item 4).
* **Group commit with responses only after COMMIT** (`Db.write` resumes after ReadyForQuery): every top entry; the Quarkus
  disaster shows the alternative.
* **Few runnable threads**: the C# data point (50,000 vs 4,300 context switches/s) and Rust's rejection of "one issuer owning
  App directly" variants. Our "2 HTTP loops, 6+2 PG, 1 bcrypt thread at nice 10" fits.
* **EMFILE backs off instead of spinning, and error paths must not need new fds or heavy logging** (C# and F# crashes, uSockets spin).
  With 200k fds and ≤ 120k users this should never trigger, but the JVM itself needs fds for lazy class loading from jars, so
  warm every code path first. The single warm-up phase does that.
* **listen backlog 65535** is effective on the multicore box (`somaxconn = 65535`); on the $12 box it was clamped to 4096.
* **SO_REUSEPORT per loop**. One caveat from c-epoll: with SO_REUSEPORT a stray second instance (same uid) silently splits
  traffic. On the multicore box `KillMode=mixed`/`TimeoutStopSec=20` makes this unlikely, but logging "bound N listeners"
  at startup costs nothing.

### 3.5 Concrete action list (in order)

1. HTTP loops (both builds): add "park 250-500 µs after a wake-up with 0 < n < 32 events". Measure µs/req at 50-100% of the
   lab's max req/s. The knobs that measured best on the $12 box were batch=32 and wait=250 µs.
2. JVM loop (`PlatformJvm.kt:95` TODO): implement it as an FFM port of `NativeHttp.kt` (epoll + eventfd + fd table +
   CLOSING/writer-count), with `critical(true)` downcalls for `recv`/`send`/`epoll_ctl`/`accept4`/`setsockopt`/`close` on heap
   arrays and a non-critical `epoll_wait`. Fall back to NIO with `select(Consumer)` only if FFM is blocked.
3. `start.sh`: add `-XX:-UsePerfData` and an explicit collector (A/B `-XX:+UseParallelGC -XX:ParallelGCThreads=2` vs
   `-XX:+UseSerialGC`, with `-Xmn512m`), and keep the rest. Add the three `-Xno-*-assertions` flags to the JVM compilation.
4. K/N: set `GC.minHeapBytes`/`targetHeapBytes` at startup (the 10 MiB default target means frequent collections); keep the
   request path allocation-free; precompute HMAC midstates in `HmacSha256Impl`.
5. JWT (common): header-bytes fast path, digest → base64url compare, a targeted `sub`/`exp` scan, **reject missing `exp`**.
6. Exchange: avoid `String` for path/query/authorization on the hot path; reserve header space in front of the body.
7. Native accept: `accept4(SOCK_NONBLOCK|SOCK_CLOEXEC)`, `TCP_NODELAY` on the listener, no `memScoped` malloc per `ctl`.
8. Test SQL changes on an **evolved** database (after minutes of writes), not only the fresh seed: the multicore scorer never
   resets the DB between probes, and PyPy's "17% faster on the fresh seed, 4.7× slower once posts collect likes" is the cautionary tale.
