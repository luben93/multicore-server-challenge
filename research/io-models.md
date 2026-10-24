# Network I/O model for our server: epoll vs io_uring, measured

Question: does epoll cap our server in the Multicore Server Challenge, and should the Kotlin/Native and JVM builds
move to io_uring (or something more exotic)? Benchmark-only thinking: anything the rules and the box allow.

## Answer

**epoll is not the cap, and io_uring would not move the score.** This workload has tens of thousands of mostly idle
keep-alive connections, about one request per wakeup, and ~2 KB responses. Here a best-practice io_uring server
costs the same CPU per request as a plain epoll server, within ±5%. The best-practice server uses multishot accept,
multishot recv from a provided-buffer ring, SINGLE_ISSUER + DEFER_TASKRUN, and batched send SQEs.

- In concurrent paired runs at the box's per-loop load, io_uring cost **2% more than level-triggered epoll** and
  **6% more than edge-triggered epoll** at 10k req/s per loop. It was **equal (+0.4%) at 20k**.
- Every model tops out at the same **~150k req/s on one core**.
- The whole network path costs **~7-10 µs of server CPU per request**.
- On the box a request costs **~274 µs of CPU in total, ~213 µs of it in Postgres** (the #1 entry's numbers).
- The largest io_uring saving in any single run was ~1.7 µs per request. That is **≤0.6% of box CPU**, which is
  below the score's 5% search resolution. The paired runs say the realistic saving is 0.

**The leaderboard gap the user cites is Postgres, not epoll.** Per request, from the leaderboard's req/s and CPU
shares (share × 8 cores ÷ req/s):

| Entry | I/O | req/s | app µs/req | Postgres µs/req | users |
|---|---|--:|--:|--:|--:|
| rust-tokio-Scooter1337 | epoll (Tokio) | 26,279 | **61** | **213** | 100,000 |
| csharp-sockets-jh-d | epoll (.NET sockets) | 24,696 | 68 | 243 | 95,000 |
| c-iouring-tigokraft | io_uring | 21,262 | 68 | **301** | 84,000 |
| rust-mio-foovoo | epoll (mio) | 20,710 | 70 | 290 | 80,000 |

The io_uring entry's *app* cost (68 µs, which includes bcrypt, JSON and the Postgres protocol) is no lower than the
epoll entries'. It loses ~90 µs per request in Postgres. rust-tokio wins with read coalescing, group commit and
cheaper SQL.

tigokraft also does not use the io_uring receive path its README hoped for. It uses a multishot *poll* plus a
`recv()` syscall, because buffer-ring registration returned EINVAL on 6.8.0-142. The liburing man page requires
page-aligned ring memory and a power-of-2 entry count of at most 32768. A malloc'd ring or 65536 entries gives
exactly that EINVAL, so the cause is most likely their code. Provided-buffer rings exist since 5.19.

The earlier $12 contest is no clean signal either. Its io_uring entries (30-57 µs/req) and epoll entries
(51-69 µs/req) overlap, and each pair has a different codebase. The Rust entry's 37% gain came together with
storage and batching changes. That was a 1-vCPU box with in-process SQLite, where the TCP path is a much larger
share of each request than here.

### Recommendations

- **Kotlin/Native build: keep epoll** (`NativeHttp.kt`).
  - A raw-syscall io_uring loop in K/N works. The prototype is `iomodels/kn/knsrv.kt`; the sketch is below.
  - It measured **13% more CPU than the K/N epoll loop** in paired runs. The kernel side is a wash, and K/N
    pointer handling in the ring loop costs more than the syscalls it saves.
  - Optional micro-step: switch to edge-triggered epoll and read until a short read. It is cheap and low-risk, and
    worth 0-1 µs/request, i.e. ≤0.4% of box CPU.
- **JVM build: java.nio Selector is fine.**
  - Per request it costs ~0.3 µs (~3%) more than C epoll.
  - An FFM io_uring loop works (prototype `iomodels/jvm/FfmUring.java`). It was **6.6% cheaper than NIO in paired
    runs** (~1 µs/request) and 7-18% cheaper in sequential runs. That is ≤0.4% of box CPU.
  - FFM itself is not the cost. A normal downcall adds ~6-10 ns and a critical one ~0-3 ns, on top of a ~90 ns
    syscall.
  - Worth it only after everything on the Postgres side is done.
- **Cross-thread response writes** (Postgres threads call `send()`): they do not "kill" an io_uring benefit, because
  there is none to kill.
  - With loop-side io_uring and worker-side `send()`, the cost equals epoll (+1.3%).
  - The architectures that recover io_uring batching measured only 1-3% better than direct `send()` (2 rounds each,
    single-CPU setup):
    - a per-worker submission ring: each Postgres thread submits its whole batch of responses with one
      `io_uring_enter`;
    - handing the response back to the owning ring through an MPSC queue plus eventfd.
  - Keep the direct `send()` from the Postgres thread. The loop-to-worker hop itself costs ~1 µs/request (+12%), but
    the hop is inherent to the design.
- **Several server processes (SO_REUSEPORT)** do not change the I/O picture. Kernel-side it is the same mechanism
  as per-thread listeners. What does matter is the number of loops. Fewer, busier loops collect more events per
  wakeup and cost less per request. tigokraft measured the same: 1 loop beat 2 on 4 CPUs (3.1 vs 2.2 completions per
  wake). Keep `HTTP_THREADS` at 1-2 on the 8-vCPU box. One loop can move ~150k req/s of pure network I/O per core.
- **Exotic options are out.**
  - Kernel bypass (AF_XDP/DPDK/F-Stack) is impossible for the unprivileged unit. `socket(AF_XDP)` returns EPERM
    without CAP_NET_RAW (verified). DPDK needs root, hugepages and the NIC itself.
  - SQPOLL burns a whole core: measured 90% of a core at 10k req/s, i.e. 91 µs/request instead of ~9.
  - Busy polling burns cores that Postgres needs.
  - A front proxy doubles the TCP path. Nginx costs 11-19% of the box on the leaderboard.

### Expected end-to-end gain of switching to io_uring

The network path is ~8-10 µs out of ~274 µs CPU per request, i.e. ~3-4% of box CPU. That is about a fifth of the
app's ~20% share; the rest is bcrypt, JSON, JWT and the Postgres protocol.

| Case | Saving per request | Share of box CPU |
|---|---|--:|
| Best case seen (any single run) | ~1.7 µs | ≤0.6% |
| Measured paired result | -0.5 to +0.2 µs | ~0% |
| JVM via FFM | ~1 µs | ~0.4% |

The box's syscall cost could be higher than here; for example, AMD SRSO or Intel BHI mitigations add ~100-300 ns per
syscall. io_uring removes ~2.2 syscalls per request, which shifts at most ~0.5 µs/request in its favour, ~0.2%.
**Expected score change: 0 within noise. The score's own search resolution is 5%.**

### What does matter (measured)

1. **Connections per loop (kernel cache footprint).** At the same 20k req/s: 1,000 connections cost 6.2-6.7 µs/req,
   18,000 cost 7.7-10.3 µs/req (+25-55%). The box holds 120k, so expect the network path to cost somewhat more there
   than here. That is unavoidable when serving direct, and still small next to Postgres.
2. **Events per wakeup.**
   - At 20k req/s total, 1 loop saw 2.6-3.7 events per wake and cost 7.2-7.6 µs/req.
   - 2 loops saw 1.7-2.2 events per wake and cost 8.4-10.8 µs/req (sequential runs, noisy).
   - Waking up is the dominant per-request cost at this load, for epoll and io_uring alike.
3. **Postgres µs per request.** The 213 vs 301 µs gap between #1 and #3 is 10-50x larger than any I/O-model
   difference.

## Research: what the kernel offers (Ubuntu 24.04 = 6.8 GA kernel)

Ubuntu 24.04 kernels: GA 6.8; HWE 6.11 (24.04.2), 6.14 (24.04.3), 6.17 (24.04.4, Feb 2026). A cloud "Ubuntu 24.04"
server runs 6.8 unless the provider ships its own kernel flavour. tigokraft's VM was 6.8.0-142 and the $12 batch-2
box was 6.8.0-117. **Design for 6.8.** This lab VM runs 6.18; every io_uring feature the benchmarks used exists in
≤6.1.

| io_uring feature | Since | On 6.8 | What it buys here |
|---|---|---|---|
| Multishot accept; accept into a sparse fixed-file table | 5.19 | yes | One SQE accepts forever. Sessions last ~15 min, so the per-request effect is nil. Direct descriptors bypass the fd table: the table size is capped by RLIMIT_NOFILE *per ring*, which is how $12 entries held more than 65,535 users. Not needed with LimitNOFILE=200000. |
| Provided-buffer ring (`IORING_REGISTER_PBUF_RING`) | 5.19 | yes | The kernel picks the buffer when data arrives, so idle connections own no buffer. epoll with one shared scratch buffer gets the same result. Ring memory must be page aligned, power-of-2, ≤32768 entries. |
| Multishot recv | 6.0 | yes | Removes epoll_wait + recv per request. Measured: no CPU win at ~1 request per wake. |
| COOP_TASKRUN 5.19, SINGLE_ISSUER 6.0, DEFER_TASKRUN 6.1 | | yes | Completion work runs only when the loop waits, which gives real batching. All io_uring rows below use them. A ring without DEFER_TASKRUN (`ur -n`) was built but not measured: the queue was cut. |
| Registered ring fd (`IORING_REGISTER_RING_FDS`), fixed files | 5.18 / 5.1 | yes | Saves the fdget/fget per op. Fixed files measured the same as plain fds at max rate (150k req/s/core either way). They also rule out `send()` from other threads. |
| `IOSQE_CQE_SKIP_SUCCESS` | 5.17 | yes | No CQE for successful sends. But a send that went async (EAGAIN, then poll) gives no signal that its buffer is free. A real server must keep send CQEs or use static buffers. |
| `IORING_RECVSEND_POLL_FIRST` | 5.19 | yes | Moot with multishot recv. For 0.3-10 KB sends on keep-alive sockets the buffer has room, so it does not apply. |
| Send zero-copy (`SEND_ZC`) | 6.0; coalescing in 6.10 | yes, without coalescing | The liburing wiki puts the crossover at ~3 KB *with* 6.10's coalescing, higher on 6.8. It needs a second notification CQE per send. Not for 0.3-10 KB responses. |
| SQPOLL | 5.11 unprivileged | yes | Measured: 90-98% of a core at 10-20k req/s. |
| Recv/send bundles | 6.10 | **no** | With one request in flight per connection there is nothing to bundle. |
| Incremental buffer consumption | 6.12 | **no** | Irrelevant at 0.3-0.5 KB requests. |
| NAPI busy poll (`IORING_REGISTER_NAPI`) | 6.9 | **no** | Spins CPU. |
| Min-wait batching | 6.13 | **no** | |
| `kernel.io_uring_disabled` | 6.6 | yes | 0 lets anyone create rings, 1 restricts to CAP_SYS_ADMIN or `io_uring_group`, 2 disables. Ubuntu keeps 0. tigokraft ran io_uring on the box as the unprivileged `challenge` user. Verified here: an unprivileged, capability-free process can create DEFER_TASKRUN and SQPOLL rings and a buffer ring (`tools/capcheck.c`). Docker's default seccomp profile blocks io_uring; systemd does not, and `challenge.service` has no SystemCallFilter. |

**epoll side**

- **EPOLLEXCLUSIVE (4.5)** only matters for one listener shared by several epoll sets. Per-loop SO_REUSEPORT
  listeners have no thundering herd.
- **Edge vs level triggered.** Level-triggered re-polls every returned item on the next epoll_wait. Edge-triggered
  skips that, but must read until EAGAIN or a short read. Measured below: edge-triggered is a little cheaper,
  0-1 µs per request.
- **epoll busy-poll ioctl (EPIOCSPARAMS)** needs 6.9, so it is not on 6.8.
- **SO_BUSY_POLL** is settable unprivileged; verified as uid 65534 with no capabilities.
  SO_PREFER_BUSY_POLL and a larger budget need CAP_NET_ADMIN. It only spins in *blocking* receives. Epoll busy
  polling needs the `net.core.busy_poll` sysctl, which is box tuning (rule 12). It is useless with non-blocking
  sockets and steals CPU in any case.
- **TCP_DEFER_ACCEPT** saves one wakeup per new connection. Connections live ~15 min, so it does nothing measurable.
- **SO_INCOMING_CPU / reuseport cBPF (`SO_ATTACH_REUSEPORT_CBPF`)** are unprivileged (verified). They steer a flow
  to the loop on the CPU that runs its RX softirq. They help when loops equal CPUs; with 1-2 loops on 8 vCPUs shared
  with Postgres the effect is small. Not measurable on loopback.
- **writev vs send.** Header and body in one buffer make a single `send()`; 2 iovecs cost the same. Only io_uring can
  batch sends across sockets into one syscall, and that is worth ~90 ns per avoided syscall on this CPU.

**Kernel bypass**

- **AF_XDP:** `socket(AF_XDP)` returns EPERM without CAP_NET_RAW (verified). Attaching the XDP program needs
  CAP_NET_ADMIN plus CAP_BPF or CAP_SYS_ADMIN. The unit has only CAP_NET_BIND_SERVICE. You would also need a
  user-space TCP stack for 120k connections.
- **DPDK / F-Stack / Seastar's native stack:** need root for vfio/uio and hugepages (box tuning, rule 12). They take
  the NIC away from the kernel, which removes SSH and the load generator's control path. Impossible here.

**Proxies (Nginx, HAProxy, Envoy, Kong)** add a second TCP path per request (client to proxy, then proxy to app) plus
the proxy's HTTP parsing. On the leaderboard Nginx costs 11-19% of the box. Direct is strictly cheaper.
`nginx` is not installed in this lab, so it was not re-measured.

## Method

**Lab.**

- VM: 4 vCPU Intel Granite Rapids under KVM/Firecracker, kernel 6.18.44, Ubuntu 24.04.5 userland.
- Mitigations: eIBRS, not affected by retbleed/SRSO. A raw syscall costs 88-97 ns from C.
- Fd hard limit: 20,000 per process, so each process stays under 19k sockets.
- **The VM was shared and noisy.** Other agents' builds and Postgres ran unlocked on all CPUs, with load average up
  to 9 on 4 CPUs.
- Every data point ran under `/opt/tools/bench.lock`, with server and client at `nice -10`. Each record logs the
  foreign load on the server CPUs.

**Servers.** Minimal HTTP/1.1 keep-alive servers. Each reads the request, frames on `\r\n\r\n` (split reads handled)
and answers with a canned 2,097-byte JSON response (2,000-byte body). Sources:

| Path (under `.../scratchpad/iomodels/`) | What |
|---|---|
| `servers/common.h` | Shared code: response, framing, listener bound to 127.0.0.200 (avoids clashing with ephemeral ports in TIME_WAIT), and the "Postgres worker" pool for cross-thread modes. |
| `servers/ep.c` | epoll: level-triggered (default) or edge-triggered (`-e`); `-t N` loops with per-loop SO_REUSEPORT listeners; `-x N` workers call `send()`; `-X N` workers hand back to the owning loop (MPSC + eventfd). |
| `servers/ur.c` | io_uring via liburing 2.12 (built from the GitHub tag). Default: SINGLE_ISSUER + DEFER_TASKRUN + COOP_TASKRUN, registered ring fd, multishot accept, multishot recv with a 4096 × 2 KB provided-buffer ring, send SQEs (MSG_WAITALL, CQE_SKIP_SUCCESS), one `io_uring_submit_and_wait` per loop. Options: `-f` fixed files; `-P` multishot poll + `recv()` (tigokraft's design); `-I` `send()` syscall; `-n` no DEFER_TASKRUN; `-s MS` SQPOLL; `-x`/`-X` as in ep.c; `-R N` per-worker submission rings. |
| `jvm/NioSrv.java` | java.nio Selector with the `select(Consumer)` API, per-loop SO_REUSEPORT listener, direct buffers. |
| `jvm/FfmEpoll.java` | Raw epoll through FFM; recv/send/accept/epoll_ctl as critical downcalls. |
| `jvm/FfmUring.java` | Raw io_uring through FFM: `syscall(2)` downcalls, mmap'd rings, VarHandle acquire/release, the same design as ur.c. |
| `jvm/FfmBench.java`, `tools/cbench.c` | Downcall-cost microbenchmark and its C syscall baseline. |
| `kn/knsrv.kt` (`knsrv.kexe`) | Kotlin/Native 2.4.21, zero dependencies: `epoll` mode mirrors NativeHttp.kt; `uring` mode is raw-syscall io_uring like FfmUring. |
| `tools/offsets.c` → `tools/offsets.txt` | io_uring ABI offsets and constants hard-coded by the FFM and K/N ports. |
| `tools/capcheck.c` | What an unprivileged process may do (busy poll, cBPF, rings, SQPOLL, AF_XDP). |

**Load client** (`client/main.go`, Go 1.27):

- Opens N keep-alive connections from source IPs 127.0.0.2 upward.
- Sends ~410-byte GET requests with a JWT header, one in flight per connection.
- Think times are exponential, scheduled so the *total* offered rate is fixed.
- Latency runs from write to the last response byte. "lag" is the delay against the schedule, a check on client
  saturation.
- Over the measure window it samples the server's CPU: the sum of `/proc/<pid>/task/*/schedstat` for all threads
  (and child processes), plus the utime/stime split, plus per-CPU busy time from `/proc/stat`.
- **Metric: server CPU µs per completed request.**
  - On loopback, the server's `send()` also runs the client-side TCP receive, while the client's `send()` runs the
    server-side receive. The two roughly cancel and are identical across I/O models.
  - Absolute µs are a loopback proxy. The *differences* are what the models change: syscalls, wakeups, task-work.

**Designs.**

1. **Sequential matrix:** server on CPUs 0-1, client on 2-3, 15,000 connections, 10k/20k/40k req/s, 6 s warm-up
   (20 s for the JVM), 15 s measure. Noisy: ±10-15% between runs depending on foreign load.
2. **Concurrent paired A/B (the robust result):** servers A and B run *at the same time*, one per CPU (0/1, swapped
   every round). Each has its own client with 7,500 connections at the same rate, so host noise hits both. The table
   reports B/A per round.
3. **Max rate:** a 1-loop server alone on CPU 0, the client on CPUs 1-3, offered rate stepped up to 150k.
4. **Connection count:** 20k req/s over 1,000 vs 18,000 connections.

The coordinator stopped the queue to free the shared lock, so not every planned point got two runs. Each table shows
every run it has. Sequential points with one run are marked by a single value.

## Results

### Concurrent paired A/B (server CPU µs/request; B/A < 1 means B is cheaper)

| A vs B | req/s per server | rounds | A µs/req | B µs/req | B/A per round (CPU A/B) | median B/A |
|---|--:|--:|--:|--:|---|--:|
| ep-lt-1t vs **ur-1t** | 10,000 | 4 | 8.79 | 8.96 | 0.987(0/1) 1.018(1/0) 1.029(0/1) 1.046(1/0) | **1.023** |
| ep-et-1t vs **ur-1t** | 10,000 | 4 | 9.11 | 9.62 | 1.099(0/1) 1.030(1/0) 1.018(0/1) 1.078(1/0) | **1.054** |
| ep-lt-1t vs **ur-1t** | 20,000 | 2 | 9.27 | 9.31 | 0.974(0/1) 1.036(1/0) | **1.005** |
| ur-1t vs ur-poll-1t (tigokraft style) | 10,000 | 2 | 12.48 | 12.43 | 0.991 1.000 | 0.996 |
| kn-epoll-1t vs **kn-uring-1t** (Kotlin/Native) | 10,000 | 2 | 8.17 | 9.27 | 1.125 1.144 | **1.134** |
| jvm-nio-1t vs **jvm-ffm-uring-1t** | 10,000 | 2 | 15.55 | 14.53 | 0.925 0.943 | **0.934** |
| ep-lt-1t vs ep-lt-1t-xdirect (cost of the worker hop) | 10,000 | 2 | 8.11 | 9.12 | 1.153 1.094 | 1.124 |
| ep-lt-1t-xdirect vs ur-1t-xdirect | 10,000 | 2 | 9.97 | 10.12 | 0.993 1.034 | 1.013 |
| ur-1t-xdirect vs ur-1t-xring (per-worker ring) | 10,000 | 2 | 12.49 | 12.36 | 0.993 0.986 | 0.989 |
| ur-1t-xdirect vs ur-1t-xhandback (MPSC + eventfd) | 10,000 | 2 | 12.07 | 11.75 | 0.975 0.970 | 0.972 |

The absolute level varies with the machine's load at the time, e.g. 8-9 vs 12-15 µs. That variation is why the
paired ratio is the result. The cross-thread pairs ran each server (loop + 2 workers) on *one* CPU. Wakeups there are
same-CPU context switches with no IPIs, which flatters the hand-back design. On the box, cross-CPU wakeups make
hand-back costlier.

### Sequential matrix (15,000 connections, server on CPUs 0-1; raw: `results/matrix*.jsonl`)

Server CPU µs/request, one value per run. "foreign" is other processes' CPU time on CPUs 0-1 per request (other
agents); values above ~20 inflate the server's number too.

| variant | 10k req/s | 20k req/s | 40k req/s | foreign (10k/20k/40k) |
|---|--:|--:|--:|---|
| ep-lt-1t (epoll LT, 1 loop) | 10.74 | 9.31 | 8.64 | 67 / 46 / 3 |
| ep-et-1t (epoll ET) | 9.56 | 7.23 | 6.85 | 53 / 1 / 1 |
| ep-lt-2t | 10.03 | 8.69 | 8.28 | 5 / 2 / 5 |
| ep-et-2t | 9.07 | 8.43 | 8.67 | 102 / 39 / 1 |
| ur-1t (io_uring, multishot recv + buffer ring) | 9.07 | 7.60 | 6.80 | 8 / 2 / 1 |
| ur-2t | 12.49 | 10.75 | 9.00 | 114 / 36 / 0 |
| ur-sqpoll-1t (idle 10 ms) | **90.57** (90% of a core) | **49.26** (98%) | – | 106 / 50 |
| jvm-nio-1t | 10.60 / 11.45 | 9.24 / 9.94 | 9.09 / 8.51 | 9 / 2 / 1 |
| jvm-nio-2t | 11.90 | 10.09 | 9.12 | 29 / 0 / 1 |
| jvm-ffm-epoll-1t | 11.19 | 9.95 | 8.34 | 10 / 7 / 2 |
| jvm-ffm-uring-1t | 9.06 | 8.48 | 8.18 | 8 / 3 / 2 |

Other observations from the matrix:

- **User-space share of the server's CPU:** C 3-8%, FFM 9-13%, NIO 16-19%. Everything else is kernel: TCP, wakeups,
  syscalls.
- **Latency:** p50 0.06-0.17 ms everywhere. p99 was 0.3-0.8 ms except when foreign load spiked (3-5 ms) and for
  SQPOLL (20-295 ms).
- **Events per wakeup** (from the servers' counters):
  - 1 loop: ep-lt 2.1/2.6/4.0, ep-et 2.5/3.6/3.7, ur 3.0/3.7/4.2 at 10k/20k/40k.
  - 2 loops: 1.6-2.3 per loop.

### Max rate (1 loop alone on CPU 0, client on CPUs 1-3, 15,000 connections; `results/max.jsonl`)

| variant | 60k | 90k | 120k | 150k offered |
|---|---|---|---|---|
| ep-lt-1t | 50% CPU, 8.3 µs | 63%, 7.0 µs | 83%, 6.9 µs | 94%, 6.3 µs; p50 28 ms (saturated) |
| ep-et-1t | 41%, 6.8 µs | 58%, 6.4 µs | 73%, 6.1 µs | 97%, 6.4 µs; p50 80 ms (saturated) |
| ur-1t | 45%, 7.5 µs | 62%, 6.8 µs | 86%, 7.2 µs | 92%, 6.2 µs; p50 1.9 ms, 148.4k achieved |
| ur-fixed-1t | 44%, 7.3 µs | 63%, 7.0 µs | 79%, 6.6 µs | 94%, 6.2 µs; p50 26 ms (saturated) |
| ur-poll-1t | 51%, 8.4 µs | 82%, 9.1 µs | 82%, 6.9 µs | 96%, 6.4 µs; p50 70 ms (saturated) |

**Every model saturates at ~150k req/s per core.** At this load io_uring batches 13-15 completions per enter and
epoll 13 events per wait. One run each: the max-rate queue was stopped.

### Connection count (20k req/s, 1 loop; `results/conns.jsonl`)

| variant | 1,000 connections | 18,000 connections |
|---|--:|--:|
| ep-lt-1t | 6.44 / 6.03 | 8.15 / 7.15 |
| ur-1t | 5.93 / 7.37 | 9.39 / 11.18 (2nd run under 42 µs/req foreign load) |

### FFM downcall cost (JDK 27, pinned to CPU 0)

| call | ns/call |
|---|--:|
| `labs` (no syscall), normal downcall | 8.7-10.2 |
| `labs`, critical downcall | 3.4-4.2 |
| `getppid` via FFM, normal | 105-112 |
| `getppid` via FFM, critical | 94-98 |
| variadic `syscall(110)` via FFM | 106-110 |
| `syscall(SYS_getppid)` from C | 88-97 |

So FFM adds ~6-15 ns per call. An epoll loop through FFM makes ~2.4 calls per request (~30 ns). An io_uring loop
makes ~0.3 per request (~3 ns). Both are negligible against 8,000+ ns of kernel work per request. NIO's extra
~0.3-1 µs is Java-side bookkeeping, not the native transition.

## Why io_uring does not help here

At ~13k req/s per loop spread over tens of thousands of connections, almost every request needs its own wakeup:
2-4 events per wake. Per request, the kernel does the same expensive work in both models:

- scheduler wakeup and context switch;
- `tcp_recvmsg` copy;
- `tcp_sendmsg`, plus loopback/NIC transmit.

io_uring saves ~2.2 syscall entries per request (~0.2 µs at ~90 ns each). It spends about as much on its own
machinery: task_work queueing, multishot poll re-arm, io_kiocb handling and CQE posting. The liburing wiki itself
promises only "potentially a reduction of system calls compared to epoll". At 80k+ req/s per core both models batch
heavily (13-15 per wake) and converge again. There is no epoll wall in this regime. The ceiling per core is the TCP
stack, at ~6.2 µs/request.

## Kotlin/Native io_uring sketch (as prototyped in `kn/knsrv.kt`)

**1. Setup.**

- Call `platform.posix.syscall(425, entries, params)`. The K/N sysroot ships Linux **4.9** headers: no
  `linux/io_uring.h`, and `accept4` is missing from the posix klib (use `syscall(288, …)`). So hard-code the ABI from
  `tools/offsets.txt`, or put copies of the structs in a cinterop `.def`.
- `mmap` the SQ/CQ ring (`IORING_FEAT_SINGLE_MMAP`) and the SQE array (offset `0x10000000`). Fill `sq_array[i] = i`
  once.
- Register the ring fd (`IORING_REGISTER_RING_FDS` = 20; then pass `IORING_ENTER_REGISTERED_RING`).
- Register a provided-buffer ring (`IORING_REGISTER_PBUF_RING` = 22) on page-aligned mmap'd memory, power-of-2 entries
  ≤32768. Its tail is the u16 at byte 14.

**2. Loop.**

- One `syscall(426, ringFd, toSubmit, 1, GETEVENTS)` per iteration, then walk the CQEs.
- Multishot accept: opcode 13, `ioprio=1`, *not* direct, so Postgres threads can still `send()` on the fd.
- Multishot recv: opcode 27, `ioprio=2`, `flags=BUFFER_SELECT`.
- Give each consumed buffer back (16-byte entry), then publish the tail once per batch.

**3. Memory ordering.** With SINGLE_ISSUER + DEFER_TASKRUN the kernel only touches the rings inside the issuing
thread's own `io_uring_enter`. The syscall is an opaque call (a compiler barrier), and x86-64 is TSO. So plain
CPointer loads and stores suffice. With SQPOLL, or without DEFER_TASKRUN, use acquire/release helpers from a
three-line cinterop `.def`.

**4. Wiring into the existing engine.**

- `HttpEngine.onData` takes a ByteArray: `memcpy` the 300-500 bytes from the provided buffer into the loop's pinned
  scratch (~20 ns), or add a pointer-based overload. Recycle the buffer right after.
- `execute()` wakeups: an eventfd read SQE, as tigokraft does.
- `close` keeps the existing in-flight-writer counter.
- On `-ENOBUFS`, re-arm the recv.
- Response writes keep `send()` from the Postgres thread. Optionally give each Postgres thread its own SINGLE_ISSUER
  ring and submit a batch's sends with one enter. Then drop `CQE_SKIP_SUCCESS` and free each response buffer on its
  CQE, because an async send holds the buffer.

**5. Measured.** The K/N io_uring loop cost 13% *more* than the K/N epoll loop. The K/N epoll loop was about equal to
C epoll (8.1-8.3 vs 8.0-8.2 µs).

The JVM port (`FfmUring.java`, ~250 lines) is the same design, using `Linker.Option.firstVariadicArg(1)` for
`syscall`, `MemorySegment.reinterpret` and `JAVA_INT.varHandle()` `getAcquire`/`setRelease`.

## Caveats

- Loopback rather than a NIC: RX/TX softirq costs land differently, but identically for every model.
- The CPU differs from the box's: syscalls are cheap here (no SRSO/BHI cost).
- Kernel 6.18 rather than 6.8: only ≤6.1 features were used, but 6.8's internals are older and somewhat slower,
  for both models.
- 15k connections rather than 120k.
- A noisy shared VM: handled with foreign-load logging and concurrent paired runs.
- Several planned points got one run instead of two (lock budget):
  - the sequential matrix after ur-2t was cut: fixed files, poll mode, no-DEFER, send-syscall and the cross-thread
    variants on 2 CPUs;
  - the matrix2 K/N rows;
  - the multi-process (2× SO_REUSEPORT processes) rows;
  - the second max-rate repetition.

  The paired A/B rows cover the key comparisons. Multi-process was not measured; the conclusion above is from how
  the kernel works.

## Raw data and scripts

Everything is under `/tmp/claude-0/-home-user-multicore-server-challenge/99796a5c-b120-524c-822d-dc73b94b523b/scratchpad/iomodels/`:

- `results/matrix.jsonl`, `results/matrix2.jsonl`, `results/max.jsonl`, `results/conns.jsonl`,
  `results/ab.jsonl`, `results/ab_x.jsonl`, `results/calib.jsonl`: one JSON per run (all client and CPU fields,
  server loop stats, command line).
- Rendered tables: `results/table_*.md`.
- Per-run server and client logs: `logs/`. The final batch's console output (A/B, SQPOLL, microbenchmarks):
  `logs/final.out`.
- Runners: `run_point.sh`, `run_matrix.sh`, `run_ab.sh`, `run_final.sh`.
- Summarizers: `tools/table.py`, `tools/abtable.py`, `tools/show.py`.
- liburing 2.12 source: `dl/liburing`; installed into `uring-inst/`.
- Research notes draft:
  `/tmp/claude-0/-home-user-multicore-server-challenge/99796a5c-b120-524c-822d-dc73b94b523b/scratchpad/research/io-models-research-notes.md`.

Sources:

- liburing man pages (`io_uring_setup.2`, `io_uring_register_buf_ring.3`, `io_uring_prep_recv_multishot.3`,
  `io_uring_prep_send_bundle.3`).
- liburing wiki: "io_uring and networking in 2023" and "What's new with io_uring in 6.10".
- [Ubuntu kernel lifecycle](https://ubuntu.com/kernel/lifecycle);
  [24.04.3 with 6.14](https://www.phoronix.com/news/Ubuntu-24.04.3-LTS-Released);
  [24.04.4 with 6.17](https://ubuntuhandbook.org/index.php/2026/02/ubuntu-24-04-linux-6-17-kernel-backported/).
- [ioctl_eventpoll(2) (EPIOCSPARAMS, 6.9)](https://man7.org/linux/man-pages/man2/ioctl_eventpoll.2.html).
- [Ubuntu SRU of the io_uring_disabled sysctl](https://lists.ubuntu.com/archives/kernel-team/2023-October/145924.html).
- AF_XDP capability notes: [dnsdist](https://www.dnsdist.org/advanced/xsk.html),
  [QEMU AF_XDP backend](https://qemu.googlesource.com/qemu/+/cb039ef3d9e3112da01e1ecd9b136ac9809ef733%5E%21).
- Netty io_uring third-party results: a few percent
  ([1](https://martin-grigorov.medium.com/jvm-network-servers-backed-by-io-uring-244fea58bb19),
  [2](https://www.besthub.dev/articles/does-netty-s-io-uring-make-the-2-cpu-thread-rule-obsolete-3358ba3ca620)).
- [Panama downcall transition cost discussion](https://mail.openjdk.org/pipermail/panama-dev/2023-July/019499.html).
- [monoio benchmark notes: io_uring loses at few connections per core](https://github.com/ukernel/monoio/blob/master/docs/en/benchmark.md).
