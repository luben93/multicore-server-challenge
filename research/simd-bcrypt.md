# SIMD-lane bcrypt (AVX2 / AVX-512 gathers) vs interleaved scalar: measured

Research notes for the Multicore Server Challenge submission. The repo was only read. Everything was built and
measured in `/tmp/claude-0/-home-user-multicore-server-challenge/99796a5c-b120-524c-822d-dc73b94b523b/scratchpad/simd-bcrypt/`
(abbreviated `SB/` below). This extends `research/bcrypt.md` and corrects its C numbers (see §3.3).

---------------------------------------------------------------------------------------------------------------------

## 0. Verdict

* **SIMD gathers do not pay off on this CPU.** The best SIMD kernel, a hybrid of 2 x 8 AVX2 lanes plus 4 scalar lanes,
  costs **13.9 ms/hash**. The best pure-SIMD kernels cost 14.05-14.15 ms/hash (AVX2 3x8 or 2x8). The **plain Openwall
  core interleaved 8 ways in scalar C costs 12.4-12.7 ms/hash**. That is 3.8-3.9x a single hash and 1.21-1.24x the
  4-lane interleave (15.4 ms). Every SIMD variant loses to the 6- and 8-lane scalar interleave at every batch size.
* **The reason is the hardware.** On this Intel core a `vpgatherdd` costs about one load-port slot per element. The
  measured gather peak is 1.7 elements/cycle for ymm and 1.9 for zmm, and each gather adds about 31-33 cycles of latency
  to the round. Lanes per vector therefore do not multiply memory throughput. bcrypt's work is memory lookups: 4
  dependent S-box loads per round per hash, 68 M per cost-10 hash. A wide scalar interleave already issues about 1.76
  loads/cycle, which is more than the gather kernels achieve (1.1-1.3 elements/cycle). See §3.
* **JVM:** the JDK 27 Vector API version is *slower* than plain scalar Kotlin. It takes 26-40 ms/hash by default, and
  19.3 ms only with the incubator's bounds checks switched off and 16-lane AVX-512. Scalar Kotlin at 4 lanes takes
  23.1 ms. **Recommendation:** use FFM to the C 8-lane *scalar* kernel, built with `gcc -O3` on the box (12.7-13.0 ms
  CPU/hash). Fall back to pure Kotlin 4-lane. The FFM call overhead is negligible (5 ns per downcall, 0.1-0.3 µs per
  batch with marshalling).
* **Kotlin/Native:** embed the same C 8-lane scalar kernel in the cinterop `.def`. K/N's own clang compiles it, and it
  takes **12.43 ms/hash**, against 18.3 ms for pure Kotlin at 4 lanes. No system compiler and no `-mavx*` flags are
  needed.
* **Batching for 8 lanes at 27.8 hashes/s (100k users):** a **0.4 s window from the oldest queued job** fills 93% of
  batches. The cost is 12.7 ms CPU/hash, which is **0.35 core**. Today's single-lane cost is 1.35 cores and the 4-lane
  JVM cost is 0.64 core. SIMD would need 16-24 lanes, which means 0.8-1.0+ s windows, for a CPU cost that is still
  higher.
* **Compiler flags matter more than SIMD.** The Openwall interleave built with `gcc -O2` costs 22.2 ms/hash at 4 lanes
  and 16.6 ms at 8 lanes. With `-O3` it costs 15.4 and 12.5-12.7 ms. Build with `-O3`.

---------------------------------------------------------------------------------------------------------------------

## 1. Setup and method

* **Machine:** Intel Xeon, family 6 model 173 (a Granite Rapids-class P-core, as reported under KVM). It has 4 vCPUs,
  48 KB L1d and 2 MB L2 per core. Flags include avx2, avx512f/bw/vl/vbmi and gfni, and lscpu says "Gather data
  sampling: Not affected". The core clock measured with an `imul` dependency chain was **~3.84 GHz**; the TSC runs at
  2.7 GHz. Software: gcc 13.3, clang 18.1, JDK 27 (Temurin 27+35, `UseAVX=3`, `MaxVectorSize=64`), Kotlin/Native
  2.4.21 (bundled LLVM 21).
* **What was timed:** cost-10 batches, single-threaded, `taskset -c 3`. Each variant was run 3 times, each run lasting
  about 2 s. **ms/hash = time per call / hashes in the call** at full lane occupancy. A kernel costs the same per call
  when its lanes are not all full (idle lanes repeat job 0). JVM runs were warmed up first with 300 calls at cost 4
  (Vector API) or 1000 calls at cost 0 (Kotlin scalar).
* **Lab lock:** the C phases (`c`, `cgen`, `nostore`), the gather microbenchmark and the Vector API and Kotlin JVM phase
  held `/opt/tools/bench.lock`. The lock was released between phases, and I held it for about 9 minutes in total. The
  lock queue reached about a dozen waiters, so on the coordinator's instruction the **FFM, Kotlin/Native and
  compiler-flag phases ran without the lock**. Other agents' load generators were also pinned to CPU 3 during those
  runs, which inflated wall time up to 2x. For those phases I report **thread CPU time**
  (`CLOCK_THREAD_CPUTIME_ID` / `ThreadMXBean`), whose spread stayed at 0-4%. For the locked runs, wall time and CPU time
  agree within 0.5%.
* **Variance:** every row below gives the mean of 3 runs and the min-max spread. Raw logs are in `SB/results/*.txt`, and
  the harness is `SB/measure.sh` (phases `micro c cgen nostore jvm ffm kn cflags`).

---------------------------------------------------------------------------------------------------------------------

## 2. Results (cost 10)

Baselines: **single** = Openwall `BF_crypt`, gcc -O3 -march=native, **48.53 ms/hash**. **4-lane** = Openwall core with
Scooter1337's 4-lane interleave, same build, **15.37 ms/hash**. "AxB" means A independent vectors of B lanes interleaved
in one loop. "+4" means 4 scalar lanes interleaved into the same round loop (hybrid). All variants are correct (§4).

### 2.1 C, gcc 13.3 `-O3 -march=native` (locked, wall time; wall and CPU agree)

| variant | lanes/call | ms/call | **ms/hash** (spread) | vs single | vs 4-lane |
|---|---|---|---|---|---|
| Openwall scalar, 1 | 1 | 48.5 | **48.53** (48.39-48.66) | 1.00x | 0.32x |
| Openwall scalar, 2-lane interleave | 2 | 53.9 | 26.97 (26.95-26.98) | 1.80x | 0.57x |
| Openwall scalar, 3-lane | 3 | 57.4 | 19.15 (19.13-19.16) | 2.53x | 0.80x |
| **Openwall scalar, 4-lane** (baseline) | 4 | 61.5 | **15.37** (15.33-15.40) | 3.16x | 1.00x |
| Openwall scalar, 6-lane | 6 | 76.3 | 12.72 (12.70-12.75) | 3.82x | 1.21x |
| **Openwall scalar, 8-lane** | 8 | 101.2 | **12.65** (12.63-12.67) | **3.84x** | **1.22x** |
| AVX2 gather 1x8 | 8 | 158.2 | 19.77 (19.74-19.82) | 2.45x | 0.78x |
| AVX2 gather 2x8 | 16 | 226.5 | 14.15 (14.12-14.18) | 3.43x | 1.09x |
| AVX2 gather 3x8 | 24 | 337.3 | 14.05 (14.05-14.06) | 3.45x | 1.09x |
| AVX2 gather 4x8 | 32 | 512.8 | 16.02 (16.02-16.03) | 3.03x | 0.96x |
| AVX-512VL (ymm + vpternlogd) 1x8 | 8 | 158.9 | 19.86 (19.80-19.98) | 2.44x | 0.77x |
| AVX-512VL 2x8 | 16 | 226.0 | 14.13 (14.12-14.13) | 3.43x | 1.09x |
| AVX-512VL 3x8 | 24 | 338.0 | 14.08 (14.08-14.09) | 3.45x | 1.09x |
| AVX-512VL 4x8 | 32 | 514.2 | 16.07 (16.05-16.09) | 3.02x | 0.96x |
| AVX-512F zmm 1x16 | 16 | 272.4 | 17.02 (17.01-17.04) | 2.85x | 0.90x |
| AVX-512F 2x16 | 32 | 509.9 | 15.93 (15.91-15.98) | 3.05x | 0.96x |
| AVX-512F 3x16 | 48 | 847.0 | 17.65 (17.64-17.65) | 2.75x | 0.87x |
| AVX-512F 4x16 | 64 | 1221.3 | 19.08 (19.02-19.15) | 2.54x | 0.81x |
| hybrid AVX2 1x8 + 4 scalar | 12 | 174.6 | 14.55 (14.54-14.56) | 3.34x | 1.06x |
| hybrid AVX2 2x8 + 2 scalar | 18 | 252.1 | 14.01 (14.00-14.01) | 3.46x | 1.10x |
| **hybrid AVX2 2x8 + 4 scalar** (best SIMD) | 20 | 278.0 | **13.90** (13.89-13.92) | 3.49x | 1.11x |
| hybrid AVX-512VL 1x8 + 4 | 12 | 175.0 | 14.58 (14.56-14.61) | 3.33x | 1.05x |
| hybrid AVX-512VL 2x8 + 4 | 20 | 278.8 | 13.94 (13.93-13.95) | 3.48x | 1.10x |
| hybrid AVX-512F 1x16 + 4 | 20 | 339.0 | 16.95 (16.90-16.99) | 2.86x | 0.91x |
| hybrid AVX-512F 2x16 + 4 | 36 | 597.4 | 16.59 (16.58-16.61) | 2.93x | 0.93x |

**Pure-ISA build.** With `-march=native`, GCC also lets the `target("avx2")` kernels use AVX-512 `vpternlog`, because
the attribute adds to the global ISA. The real AVX2-only code path therefore comes from `gcc -O3 -mtune=native` without
`-march` (locked, wall time). In that build each kernel uses exactly its own ISA:

| variant (pure ISA build) | lanes | ms/hash (spread) | vs single | vs 4-lane |
|---|---|---|---|---|
| Openwall 1 / 4 / **8** | 1 / 4 / 8 | 48.39 / 15.46 (15.23-15.85) / **12.46** (12.45-12.47) | 1.0 / 3.14 / **3.89x** | 0.32 / 0.99 / **1.23x** |
| AVX2 1x8 / 2x8 / 3x8 / 4x8 | 8-32 | 20.83 / 14.67 / 14.26 / 15.88 | 2.33 / 3.31 / 3.40 / 3.06x | 0.74 / 1.05 / 1.08 / 0.97x |
| hybrid AVX2 1x8+4 / 2x8+2 / 2x8+4 | 12-20 | 15.32 / 14.40 / 14.23 | 3.17 / 3.37 / 3.41x | 1.00 / 1.07 / 1.08x |

### 2.2 Other C compilers and flags (unlocked, thread CPU time)

| build | Openwall 1 | Openwall 4 | Openwall 8 | AVX2 2x8 | AVX-512VL 2x8 | AVX-512 1x16 | hybrid 2x8+4 |
|---|---|---|---|---|---|---|---|
| gcc 13 -O3 -march=native (from 2.1) | 48.53 | 15.37 | 12.65 | 14.15 | 14.13 | 17.02 | 13.90 |
| **gcc 13 -O2** -march=native | 48.27 | **22.18** | **16.57** | - | - | - | - |
| gcc 13 -O2 (generic) | 48.28 | 22.30 | - | - | - | - | - |
| clang 18 -O3 -march=sapphirerapids | 51.79 | 15.81 | 12.68 (locked) | 16.05 | 16.00 | 17.30 | 19.69 |
| **Kotlin/Native cinterop** (K/N's clang, LLVM 21, `-O3`, no -m flags) | 51.25 | 15.63 | **12.43** | 15.03 | 14.24 | 17.43 | 18.80 |

Spreads were 0.0-1.1% in all these rows. Openwall 2-lane at `-O2` costs 39.17 ms/hash, against 26.97 at `-O3`. The
scalar interleave depends on `-O3`, which brings unrolling and scheduling. clang spills more in the hybrid kernels, which
explains 18.8-19.7 ms against gcc's 13.9.

### 2.3 JVM (JDK 27)

| variant | lanes | ms/hash (spread) | vs single | vs 4-lane | notes |
|---|---|---|---|---|---|
| Kotlin scalar, `IntArray` state in the hot method (`bc/kt6/cpu.jar`, `hashC1..6`) | 1 | 49.3 (49.3-49.4) | 0.98x | 0.31x | locked; thread CPU, 3 JVM runs x 6 calls |
| Kotlin scalar | 2 | 25.0 (24.9-25.0) | 1.94x | 0.61x | |
| **Kotlin scalar, 4 lanes** | 4 | **23.1** (23.1-23.2) | 2.10x | 0.67x | best pure-JVM scalar |
| Kotlin scalar | 6 | 23.8 (23.8) | 2.04x | 0.65x | 8 lanes exceeds HotSpot's 8000-byte huge-method limit (bcrypt.md §5) |
| Vector API `SPECIES_256`, 1x8 | 8 | 28.57 (28.36-28.78) | 1.70x | 0.54x | locked, wall time |
| Vector API 256, 2x8 / 3x8 / 4x8 | 16-32 | 31.54 / 38.70 / 39.59 | 1.54 / 1.25 / 1.23x | 0.49 / 0.40 / 0.39x | more vectors make it **slower** |
| Vector API `SPECIES_512`, 1x16 | 16 | 26.29 (25.51-27.40) | 1.85x | 0.58x | |
| Vector API 512, 2x16 / 3x16 / 4x16 | 32-64 | 33.80 / 37.39 / 39.15 | 1.44 / 1.30 / 1.24x | 0.45 / 0.41 / 0.39x | |
| Vector API 256 2x8, `-Djdk.incubator.vector.VECTOR_ACCESS_OOB_CHECK=0` | 16 | 25.40 (25.24-25.57) | 1.91x | 0.61x | bounds checks off |
| **Vector API 512 1x16, OOB checks off** | 16 | **19.30** (19.26-19.39) | 2.51x | 0.80x | best Vector API |
| **FFM → C Openwall 8-lane** (`libsbc.so`, gcc -O3 -march=native) | 8 | **12.98** (12.71-13.15) | 3.74x | 1.18x | unlocked, thread CPU |
| FFM → C Openwall 4 / 1 | 4 / 1 | 15.44 / 49.47 | 3.14 / 0.98x | 1.00 / 0.31x | |
| FFM → C AVX2 2x8 / AVX-512VL 2x8 / hybrid 2x8+4 / AVX-512 1x16 | 16-20 | 14.37 / 14.25 / 14.15 / 17.16 | 3.38 / 3.41 / 3.43 / 2.83x | 1.07 / 1.08 / 1.09 / 0.90x | the same as native C |

**FFM call overhead**, measured: a downcall to `int f(void)` takes **4-6 ns**. A full batch call with a confined arena,
copying 1 key and 1 setting in and the output string back out (n = 0, so no hashing), takes **115-275 ns**. A batch
takes 100-300 ms, so the overhead is about 1e-6 of the work, which is negligible as expected. The FFM `ms/hash` values
match the C harness within the unlocked noise.

**Why the Vector API version is slow** (an inference from the numbers; I did not read C2's assembly):

1. `IntVector.fromArray(species, int[], offset, int[] indexMap, mapOffset)` takes its indices from an `int[]`, not from a
   vector. Every lookup therefore does a vector store of the index, a reload, and a vector add of `offset`.
2. `checkIndex` adds two compares, an OR and a test-and-branch per gather, unless `VECTOR_ACCESS_OOB_CHECK=0`.
3. Interleaving 2-4 vectors makes it slower, not faster. C2 apparently keeps the index-array stores and the gathers that
   read `st` in program order, so the groups do not overlap the way they do in C.

The best Vector API configuration needs an incubator module, a JVM-internal property and AVX-512. Even then, at
19.3 ms/hash, it is still worse than the C scalar kernel.

### 2.4 Kotlin/Native

| variant | lanes | ms/hash CPU (spread) | vs single | vs 4-lane |
|---|---|---|---|---|
| pure Kotlin, `IntArray` state (`bc/kt/native/bcn.kexe`, `-opt`) | 1 / 2 / 3 / **4** | 54.9 / 29.9 / 21.7 / **18.3** (18.3-18.4) | 0.88 / 1.62 / 2.24 / **2.65x** | 0.28 / 0.51 / 0.71 / **0.84x** |
| **cinterop-embedded C, Openwall 8-lane** | 8 | **12.43** (12.43-12.45) | **3.90x** | **1.24x** |
| cinterop C, Openwall 4 / 1 | 4 / 1 | 15.63 / 51.25 | 3.10 / 0.95x | 0.98 / 0.30x |
| cinterop C, AVX-512VL 2x8 / AVX2 2x8 / AVX-512 1x16 | 16 | 14.24 / 15.03 / 17.43 | 3.41 / 3.23 / 2.78x | 1.08 / 1.02 / 0.88x |

### 2.5 CPU at the challenge's load (27.8 hashes/s at 100k users, 41.7/s at 150k)

| implementation | ms/hash | cores at 100k | cores at 150k |
|---|---|---|---|
| single scalar (Openwall or JVM 1 lane) | 48.5-49.4 | 1.35-1.37 | 2.0 |
| JVM Kotlin scalar 4-lane | 23.1 | 0.64 | 0.96 |
| JVM Vector API, best default (512, 1x16) / OOB checks off | 26.3 / 19.3 | 0.73 / 0.54 | 1.10 / 0.80 |
| K/N pure Kotlin 4-lane | 18.3 | 0.51 | 0.76 |
| C Openwall 4-lane -O3 | 15.4 | 0.43 | 0.64 |
| best SIMD (hybrid AVX2 2x8+4, full lanes) | 13.9 | 0.39 | 0.58 |
| **C Openwall 8-lane -O3 (native, FFM or cinterop)** | **12.4-13.0** | **0.35-0.36** | **0.52-0.54** |

These rows assume full batches. §5.3 adds the partial-batch effect of the collection window.

---------------------------------------------------------------------------------------------------------------------

## 3. Why SIMD gathers don't win here

### 3.1 Gather microbenchmark (`SB/misc/gbench.c`, locked, CPU 3)

Each chain is `v = table[v & mask]`, run on independent chains, and the result is elements loaded per ns at 3.84 GHz:

| table | scalar loads, 16 chains | ymm, 1 / 2 / 4 / 8 chains | zmm, 1 / 2 / 4 / 8 chains |
|---|---|---|---|
| 16 KB | 7.70 | 0.99 / 1.97 / 3.84 / 6.44 | 1.72 / 3.67 / 6.55 / 7.16 |
| 48 KB | 7.66 | 0.99 / 1.98 / 3.87 / 6.44 | 1.85 / 3.69 / 6.62 / 7.41 |
| 64 KB | 7.71 | 0.99 / 1.98 / 3.85 / 6.47 | 1.85 / 3.22 / 6.71 / 6.78 |
| 256 KB | 7.60 | 0.98 / 1.96 / 3.72 / 6.43 | 1.85 / 3.67 / 6.61 / 7.30 |

* The latency of one gather plus an AND is about 31 cycles for ymm (8 elements in 8.1 ns) and about 33 cycles for zmm.
  A Blowfish round adds 3-4 ALU ops to that, so one vector group runs at about 1 round per 36-40 cycles.
* Peak throughput is **1.68 elements/cycle for ymm and 1.93 for zmm**. Scalar loads reach at least 2.0 per cycle even
  in this simple loop (3 load ports).
* Table size from 16 KB to 256 KB makes no difference. So the per-lane S-boxes, which total 33 KB per 8 lanes and 67 KB
  per 16 lanes, do not hurt by overflowing L1d.

### 3.2 What the bcrypt kernels reach

| kernel | gather elements per round-step | cycles per step | elements/cycle | share of gather peak |
|---|---|---|---|---|
| AVX2 2x8 | 64 | 50.9 | 1.26 | 75% |
| AVX-512 2x16 | 128 | 114.7 | 1.12 | 58% |
| scalar Openwall 8-lane | 32 S + 8 P loads | 22.8 | **1.76 loads** | - |

The scalar 8-lane interleave issues more lookups per cycle than the gather kernels. By my estimate (about 16
instructions per lane per round; not counted with a profiler, since perf is not available in this VM) it is limited by
the front end and ALUs at about 5-6 instructions per cycle, not by loads. With SIMD, each lane still needs its own 4 lookups per round,
and the gathers cost the same load slots as scalar loads, plus a 30-cycle latency. The only things SIMD saves are the
index and combine ALU ops, and on this core those are not the bottleneck.

### 3.3 Hypotheses I tested

* **Store-to-gather forwarding stalls.** Each encryption writes the S-box rows that later gathers may read. A
  timing-only build (`-DSBC_NOSTORE_EXPERIMENT`) sends S-box writes to a scratch buffer, and its timings were unchanged:
  2x8 14.22, 3x8 14.16, 2x16 15.97, 3x16 17.82 ms/hash. **Rejected.**
* **More vectors to hide latency.** 2-3 vectors are best. AVX2 3x8 already shows 2 spills, and 4x8 is worse, since
  AVX2 has only 16 ymm registers. AVX-512 3x16 and 4x16 also get worse. I did not determine why; the no-store
  experiment rules out store forwarding.
* **Hybrid SIMD plus scalar** (use the integer ALUs while gathers are in flight). It gains 1-2% over pure SIMD with gcc,
  and it is worse with clang. It still loses to scalar 8-lane.
* **Note on `research/bcrypt.md`:** its "Openwall + Scooter1337 4-lane = 22.3-23.8 ms/hash" (§0, §3.3) came from a
  `gcc -O2` build. At `-O3` the same code costs 15.4 ms/hash, and 8 lanes cost 12.5-12.7 ms.

### 3.4 The scoring box is unknown

I only measured this Intel core. Two other cases are documented in public sources:

* Intel cores affected by Gather Data Sampling ("Downfall": Skylake through Ice Lake/Tiger Lake) received microcode that
  makes `vpgatherdd` much slower.
* AMD Zen 3/4 gathers are microcoded and are generally reported to be slower per element than Intel P-core gathers.

Neither case makes SIMD more attractive. The scalar interleave needs no CPU features, so it is the robust choice.

---------------------------------------------------------------------------------------------------------------------

## 4. Correctness (all variants)

Every lane of every kernel is checked against Openwall's scalar `BF_crypt` and against the known vectors:

* **C** (`SB/c/bench.c test`): 8,225 checks, 0 failures. That covers:
  * all 25 kernels (Openwall 1-8, AVX2/AVX-512VL 1-4 x 8, AVX-512 1-4 x 16, 7 hybrids);
  * known vectors cycled through every lane in 3 rotations: the seed `password123` against
    `$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq`, the same with `$2b$` and `$2y$`, `password124`, and
    a non-canonical salt; `U*U`, `U*U*`, `U*U*U` and the empty password; the 72-character string with and without a
    tail; `\xa3` under a/b/y; the `$2a$` safety-bit key `ff a3 ...` under a/b/y; the 71/72/73 x `p` cutoff; `één 🙂`;
    and `batch self test`;
  * partial batches (L-1 and L/2+1 lanes);
  * 5 batches of random jobs per kernel at cost 4: lengths 0-90 bytes, bytes 1-255, `$2a/$2b/$2y/$2x` mixed in one batch,
    and random salts including non-canonical last characters;
  * a full-lane cost-10 batch of the seed vectors;
  * AUTO dispatch for n = 1..40.

  The same suite passes with `SBC_MAX_LEVEL=1` (AVX2 only, 3,177 checks) and `SBC_MAX_LEVEL=0` (scalar only, 1,183
  checks).
* **Java Vector API** (`Bench test`): 4,720 checks (512-bit) and 3,560 (256-bit), 0 failures. The checks use the known
  vectors plus 300 Openwall-generated random vectors (`SB/java/ref-cost4.txt`, from `bench refgen`), for V = 1..4.
* **FFM** (`Bench ffm libsbc.so all 0 0 ref-cost4.txt`): all 25 kernels match the known vectors and the 300 random
  vectors.
* **Kotlin/Native cinterop:** all 25 kernels match the seed and `$2a/$2y` cost-10 vectors and the cost-5 vectors.

The C and FFM path takes passwords as C strings, as Openwall does, so an embedded NUL ends the key. As
`research/bcrypt.md` §2.3 says, route passwords that contain NUL (and >72-byte logins, which get a 401 anyway) to the
byte-array Kotlin implementation. Rust #1 does the same.

---------------------------------------------------------------------------------------------------------------------

## 5. Recommendations

### 5.1 JVM build: FFM to a C **scalar 8-lane** kernel, not the Vector API

* **Use** the Openwall core (public domain, already vendored by the #1 entry) plus an 8-lane interleave. That is
  Scooter1337's `bcrypt-batch-impl.h` with `LANES 8`, or `SB/c/sbc.c` without the SIMD kernels.
  * `install.sh`: `apt-get install -y gcc` (Ubuntu 24.04 ships gcc 13).
  * `build.sh`: `gcc -O3 -fPIC -shared -o libbcrypt.so bcrypt.c`. This builds from source on the box, which rule 11
    allows. Plain `-O3` measured 12.46 ms and `-march=native` 12.65 ms, so `-march=native` is optional. **`-O3` is not
    optional:** `-O2` costs 16.6 ms.
  * Bind it with `Linker.nativeLinker().downcallHandle(...)`, one call per batch, using
    `int bcrypt_batch(keys, key_stride, settings, set_stride, out, n)` (see `sbc_batch_flat`). Start the JVM with
    `--enable-native-access=ALL-UNNAMED` to avoid the restricted-method warning.
  * At startup, run the self-test vectors for every lane count against the pure-Kotlin implementation. If `dlopen` or
    the self-test fails, fall back to the pure-Kotlin 4-lane version (23.1 ms).
  * Measured: **12.7-13.0 ms CPU/hash, or 0.35-0.36 core at 100k users**, against 0.64 core for pure Kotlin 4-lane. That
    saves about 0.29 core (about 3.6% of the 8-core box) at 100k and about 0.43 core at 150k.
* **Don't use** the Vector API, for three reasons:
  * It is slower than plain Kotlin scalar by default (26-40 ms/hash).
  * Its best case (19.3 ms) needs AVX-512 plus `VECTOR_ACCESS_OOB_CHECK=0`, and it is an incubator module.
  * The int[] index map and the bounds checks are API costs that C does not pay.
* **Don't use** the C SIMD kernels either. They are 9-12% slower than the C scalar 8-lane kernel here, and probably
  slower still on AMD or on Intel CPUs with the Downfall microcode.
* If the extra toolchain step is unwanted, pure Kotlin 4-lane (23.1 ms) is the fallback. It is still 2.1x better than 1
  lane. More lanes do not help on the JVM, and 8 lanes exceed the huge-method limit.

### 5.2 Kotlin/Native build: cinterop C kernel, not pure Kotlin

* Put the C (Openwall core plus 8-lane interleave) after the `---` in the `.def`, or `#include` it from the source tree.
  For example `SB/kn/sbc.def`:

  ```
  headers = sbc.h
  headerFilter = sbc.h
  compilerOpts = -O3 -I<dir>
  ---
  #include "sbc.c"
  ```

  K/N's bundled clang compiles it in about 3 s, with no system compiler. Measured: **12.43 ms/hash, against 18.3 ms for
  pure Kotlin 4-lane**. That saves 0.16 core at 100k and 0.25 core at 150k.
* Do **not** put `-mavx2` or `-mavx512f` in `compilerOpts`. Those flags let clang emit AVX-512 in any function of the
  file, and the binary would then crash with SIGILL on a box without it. If you ever ship SIMD kernels, mark each one
  `__attribute__((target("avx2")))` or `target("avx512f,avx512vl")` and dispatch at runtime, as `sbc.c` does. That
  needed no global flags with gcc, clang or K/N's clang.
* Keep the pure-Kotlin path for NUL-containing passwords and as the self-test reference.

### 5.3 Batch size and collection window (Poisson model, `SB/misc/window.py`, using the measured per-call times)

Policy: the oldest queued job opens a window of w seconds, and the batch closes when it is full or the window ends.
Partial batches go to the cheapest kernel for their n (Openwall 1/2/3/4/6/8; `sbc_auto_kernel`). Rate: 27.8 hashes/s
(100k users).

| kernel | window | mean batch | batches full | CPU/hash | cores |
|---|---|---|---|---|---|
| **scalar 8-lane** | 0.15 s | 5.1 | 13% | 14.8 ms | 0.41 |
| scalar 8-lane | 0.25 s | 6.9 | 54% | 13.3 ms | 0.37 |
| **scalar 8-lane** | **0.40 s** | **7.9** | **93%** | **12.7 ms** | **0.35** |
| scalar 8-lane | 0.60 s | 8.0 | 99.7% | 12.7 ms | 0.35 |
| AVX2 2x8 (16 lanes, fixed shape) | 0.6 / 0.8 / 1.0 s | 15.1 / 15.9 / 16.0 | 69 / 96 / 99.7% | 15.0 / 14.2 / 14.2 ms | 0.42 / 0.40 / 0.39 |
| hybrid AVX2 2x8+4 (20 lanes) | 0.6 / 0.8 / 1.0 s | 16.9 / 19.4 / 19.9 | 32 / 78 / 97% | 16.4 / 14.4 / 14.0 ms | 0.46 / 0.40 / 0.39 |
| AVX2 3x8 (24 lanes) | 1.0 s | 23.5 | 84% | 14.3 ms | 0.40 |

* **Recommendation: 8 lanes and a 0.4 s window from the oldest job.** Make the window a knob (`BCRYPT_WAIT_MS`, 250-400).
  At 150k users (41.7/s), 0.25 s already fills 89% of batches. Jobs that queue while a batch computes (about 0.1 s for
  8 lanes) make batches fill faster than this model shows.
* Worst-case login latency is about the window plus one batch (0.4 + 0.1 s). Logins are 0.11% of requests, so this
  cannot move p95, it uses at most 0.11 of p99's 1% budget, and it stays far below the loadgen's 10 s timeout.
* SIMD lanes would only be full with 16-24 jobs, which means 0.8-1.0 s windows. Even then they cost more CPU than 8-lane
  scalar on this CPU.
* Thread policy as in `research/bcrypt.md` §4: 1-2 bcrypt threads, one gatherer at a time, a bounded queue, and drop
  jobs whose connection has closed.

### 5.4 Runtime CPU detection, if you keep any SIMD kernel

The recommended scalar kernel needs no CPU detection. If you keep a SIMD kernel:

* **C (serves both FFM and cinterop):** `sbc_detect()` in `SB/c/sbc.c`. It checks:
  * CPUID.1:ECX bit 27 (OSXSAVE) and bit 28 (AVX), and `XGETBV(0) & 0x6 == 0x6`, meaning the OS saves YMM state;
  * then CPUID.7.0:EBX bit 5 for **AVX2**;
  * for **AVX-512**, CPUID.7.0:EBX bit 16 (F) and bit 31 (VL), and `XGETBV(0) & 0xE0 == 0xE0` (opmask and ZMM state).

  The `SBC_MAX_LEVEL=0|1` environment variable forces the scalar or AVX2 path, for testing. `__builtin_cpu_supports("avx2")`
  and `("avx512f")` in gcc or clang do the same check. Hand-written CPUID avoids depending on the libgcc or compiler-rt
  version that K/N links against. Compile the file without `-march`/`-m` flags, and give each kernel its own
  `target(...)` attribute.
* **JVM, pure Java:** `IntVector.SPECIES_PREFERRED.vectorBitSize()` gives 512 when HotSpot uses AVX-512 (`UseAVX=3`), 256
  on AVX2 and 128 on SSE-only CPUs. HotSpot has already checked OS support, and `-XX:UseAVX=2` caps it. **With FFM:** call
  the C library's `sbc_cpu_level()`.
* **Kotlin/Native:** there is no runtime CPU API, so call the cinterop'd `sbc_cpu_level()`. In pure Kotlin, a fallback
  is to read the `flags` line of `/proc/cpuinfo` (`avx2`, `avx512f`, `avx512vl`). Linux clears those flags when the OS
  does not enable the matching register state.

---------------------------------------------------------------------------------------------------------------------

## 6. Sources

`SB/` is
`/tmp/claude-0/-home-user-multicore-server-challenge/99796a5c-b120-524c-822d-dc73b94b523b/scratchpad/simd-bcrypt`.

| path | what |
|---|---|
| `SB/c/sbc.h`, `SB/c/sbc.c` | API, CPU detection, kernel table, AUTO dispatch, lane packing and unpacking, scalar paths, 6/8-lane Openwall interleave |
| `SB/c/sbc-kern.h` | the SIMD kernel template (AVX2 / AVX-512VL ymm / AVX-512F zmm x 1-4 vectors); interleaved `[word][lane]` state; `vpgatherdd` at index byte*W+lane |
| `SB/c/sbc-hyb.h` | hybrid kernel: vector groups plus 2-4 scalar lanes in the same round loop |
| `SB/c/crypt-bcrypt.c`, `crypt-port.h`, `byteorder.h`, `bcrypt-batch.c`, `bcrypt-batch-impl.h` | unmodified copies from `submissions/rust-tokio-Scooter1337/native/` (Openwall core from libxcrypt 4.4.36, plus the 2-4 lane interleave) |
| `SB/c/bench.c` | `bench test` (correctness), `bench time <kernel|all> reps secs`, `bench refgen N` (Openwall reference vectors) |
| `SB/c/libsbc.so` | the FFM library (`gcc -O3 -march=native -shared -fPIC sbc.c`) |
| `SB/java/gen_vb.py` → `SB/java/VB.java` | Vector API bcrypt (V = 1..4 vectors, `SPECIES_256/512/PREFERRED` via `-Dvb.bits`) |
| `SB/java/Bench.java` | Vector API and FFM correctness and timing (`ffm <lib> all 0 0 <ref>` checks only), plus the FFM call-overhead probe (`ffmcall`) |
| `SB/kn/sbc.def`, `SB/kn/Main.kt` | Kotlin/Native cinterop of `sbc.c` with test and timing driver (`main.kexe test`, `main.kexe time <kernel>`) |
| `SB/misc/gbench.c` | gather and scalar-load throughput microbenchmark, plus the clock estimate |
| `SB/misc/window.py` | collection-window and CPU model (§5.3) |
| `SB/misc/*.s` | disassembly of the hot loops (no spills in AVX2 2x8 or AVX-512 1x16/2x16; 2 spills in AVX2 3x8; many in the gcc hybrid) |
| `SB/measure.sh`, `SB/results/*.txt` | measurement phases and raw logs |
| `scratchpad/bc/kt6/cpu.jar`, `scratchpad/bc/kt/native/bcn.kexe` | the earlier Kotlin JVM and K/N scalar prototypes (research/bcrypt.md), re-measured here |
