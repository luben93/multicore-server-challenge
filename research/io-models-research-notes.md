# Research notes (draft, merged into io-models.md)

## io_uring features for many idle keep-alive TCP connections (what exists on Ubuntu 24.04's 6.8 GA kernel)

| Feature | Since | On 6.8 | What it buys here |
|---|---|---|---|
| Multishot accept (`IORING_ACCEPT_MULTISHOT`), direct accept into a sparse fixed-file table | 5.19 | yes | One SQE accepts forever. Connections live ~15 min, so per-request effect is nil. Direct descriptors live in the ring's table, not the fd table (table size is capped by RLIMIT_NOFILE *per ring*), which is how twelve-dollar entries passed 65,535 users with a 65,535 fd limit. Not needed with LimitNOFILE=200000. |
| Provided-buffer ring (`IORING_REGISTER_PBUF_RING`) | 5.19 | yes | Buffer chosen at receive time, so an idle connection owns no buffer (epoll + one shared scratch buffer gets the same). Ring memory must be page aligned, entries a power of 2, max 32768 (liburing man page) - the likely cause of tigokraft's EINVAL, not the kernel. |
| Multishot recv | 6.0 | yes | Removes the per-request recv() and the epoll_wait readiness round trip. |
| `COOP_TASKRUN` 5.19, `SINGLE_ISSUER` 6.0, `DEFER_TASKRUN` 6.1 | | yes | Completion work runs only when the loop asks for it -> real batching, no IPIs. DEFER_TASKRUN requires SINGLE_ISSUER. Incompatible with SQPOLL. |
| Registered ring fd (`IORING_REGISTER_RING_FDS`) | 5.18 | yes | Skips fdget on the ring per io_uring_enter. |
| Fixed files for recv/send (`IOSQE_FIXED_FILE`) | 5.1/5.19 | yes | Skips fget/fput (atomic refcount in a multithreaded process). Rules out plain send() from other threads (no real fd). |
| `IOSQE_CQE_SKIP_SUCCESS` | 5.17 | yes | No CQE for successful sends. But then you cannot tell when an async (EAGAIN -> poll) send released its buffer; a real server must keep send CQEs or only use static buffers. |
| `IORING_RECVSEND_POLL_FIRST` | 5.19 | yes | Skip the speculative attempt when the socket is known empty/full. With multishot recv it is moot; for sends of 0.3-10 KB on a keep-alive socket the buffer has room, so don't set it. |
| Send zero-copy (`IORING_OP_SEND_ZC`) | 6.0 (coalescing 6.10) | yes, without coalescing | Crossover vs copying send is ~3 KB on 6.10+ per the liburing wiki and higher on 6.8; needs a second notification CQE per send and pinned buffers. Responses are 0.3-10 KB: not worth it. |
| SQPOLL | 5.1 (unprivileged 5.11) | yes | A kernel thread spins for sq_thread_idle ms after the last SQE: at 10k+ req/s it never sleeps = one core gone. Measured below. |
| Recv/send bundles (`IORING_RECVSEND_BUNDLE`) | 6.10 | **no** | Several buffers per op; with one request in flight per connection there is nothing to bundle. |
| Incremental buffer consumption (`IOU_PBUF_RING_INC`) | 6.12 | **no** | Memory efficiency for large buffers; irrelevant at 0.3-0.5 KB requests. |
| NAPI busy poll (`IORING_REGISTER_NAPI`) | 6.9 | **no** | Busy polling burns CPU that Postgres needs. |
| Min-wait / `IORING_ENTER_EXT_ARG_REG` | 6.13 | **no** | Batching knob. |
| `kernel.io_uring_disabled` sysctl | 6.6 | yes | 0 = anyone may create rings (upstream default), 1 = only CAP_SYS_ADMIN or io_uring_group, 2 = nobody. Ubuntu 24.04 keeps 0; c-iouring-tigokraft ran io_uring on the benchmark box as the unprivileged `challenge` user (84k score), which settles it empirically. Docker's default seccomp profile blocks io_uring, systemd does not (challenge.service has no SystemCallFilter). |

Ubuntu 24.04: GA kernel 6.8; HWE 6.11 (24.04.2), 6.14 (24.04.3), 6.17 (24.04.4, Feb 2026). A cloud "Ubuntu 24.04" server image runs the 6.8 GA kernel unless the provider rolls its own (linux-aws etc.); tigokraft's VM was 6.8.0-142, the twelve-dollar batch-2 box 6.8.0-117. Design for 6.8.

## epoll-side options

- EPOLLEXCLUSIVE (4.5): only matters with one listener shared by several epoll sets. Per-thread SO_REUSEPORT listeners have no thundering herd to begin with.
- Edge vs level triggered: measured. LT re-polls each returned item on the next epoll_wait (one extra tcp_poll per event); ET does not, but must read until EAGAIN or a short read.
- epoll busy-poll ioctl (EPIOCSPARAMS, 6.9): not on 6.8, and spinning costs a core.
- SO_BUSY_POLL: settable by an unprivileged user (verified here as uid 65534 with no capabilities, tools/capcheck.c; SO_PREFER_BUSY_POLL and a larger busy-poll budget do need CAP_NET_ADMIN). But it only spins in *blocking* receives/poll; with non-blocking sockets under epoll/io_uring it does nothing useful, and epoll-level busy polling needs the net.core.busy_poll sysctl (box tuning, rule 12) or the 6.9 ioctl. Any spinning steals CPU from Postgres. Rejected.
- TCP_DEFER_ACCEPT: saves a wakeup per new connection; connections are reused for ~15-minute sessions, so nil.
- SO_REUSEPORT + SO_INCOMING_CPU / SO_ATTACH_REUSEPORT_CBPF (unprivileged): steer each new connection to the listener of the CPU that runs its RX softirq. Helps cache locality when loops == CPUs; with 2 loops on 8 vCPUs that also host Postgres it is a small locality win at best. Not measurable on loopback.
- writev vs send: header+body in one contiguous buffer is one send(); writev of 2 iovecs costs the same. No pipelining, so nothing to coalesce per socket.
- Batching writes per loop iteration: epoll has no multi-socket write syscall (sendmmsg is per-socket, UDP-oriented). Only io_uring batches sends across sockets into one syscall.

## Kernel bypass

- AF_XDP: socket(AF_XDP) itself fails with EPERM for an unprivileged user (verified, tools/capcheck.c); it needs CAP_NET_ADMIN (+CAP_BPF/CAP_SYS_ADMIN) to attach the XDP program and CAP_NET_RAW for the socket; the unit grants only CAP_NET_BIND_SERVICE. It also yields raw frames: you would need a user-space TCP stack for 120k connections.
- DPDK / F-Stack / Seastar native stack: needs root to bind the NIC to vfio/uio and hugepages (box tuning, rule 12), takes the NIC away from the kernel (SSH, the load generator's control plane), and replaces kernel TCP with a user-space one. Not possible as an unprivileged systemd service, and against rule 12.

## Front proxies

Nginx/HAProxy/Envoy/Kong in front adds a second full TCP path per request (client<->proxy plus proxy<->app on loopback) plus the proxy's HTTP parsing. On the leaderboard Nginx costs 11-19% of the 8-core box. It can only be a baseline; direct is strictly cheaper.
