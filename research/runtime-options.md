# Runtime, compiler, kernel-call and Postgres-session options for kotlin-raw-luben93

Date: 2026-10-24. Scope: peak throughput on the scoring box (Ubuntu 24.04 x86_64, 8 vCPU / 16 GB, PG 18 per
`box/pg-conf.sh`, `challenge.service` with `LimitNOFILE=200000` and only `CAP_NET_BIND_SERVICE`).

Legend: **[M]** = measured or verified (source given: local check in this sandbox, a primary doc, or a number
from the repo); **[E]** = my expectation (not measured). "Local" means this sandbox: Temurin 27+35 at
`/opt/jdk`, Kotlin/Native 2.4.21 at `/opt/kotlin-native`, Postgres 18 at 127.0.0.1, an Intel Xeon (clang
detects `graniterapids`), kernel 6.18 (not the box's kernel).

I did not run any Postgres or HTTP load: other agents were running load tests on the shared lab (DESIGN.md:
one load test at a time). Section 5 gives an A/B recipe for the one Postgres question that needs a measurement.

---

## 0. How much any runtime option can move the score

Per-request CPU on the box, from LEADERBOARD.md (box = 8 cores, so x% of the box = 0.08 x% cores) **[M, derived]**:

| Entry | req/s | app share | PG share | app CPU per request | PG CPU per request |
|---|--:|--:|--:|--:|--:|
| rust-tokio (#1, epoll) | 26,279 | 20% | 70% | 61 µs | 213 µs |
| csharp-sockets (#2) | 24,696 | 21% | 75% | 68 µs | 243 µs |
| c-iouring (#3, io_uring) | 21,262 | 18% | 80% | 68 µs | 301 µs |
| rust-mio (#6, epoll ET) | 20,710 | 18% | 75% | 70 µs | 290 µs |

- The app share includes bcrypt. c-iouring's README says bcrypt is about a third of the non-Postgres CPU, and
  that the server's own code is "a few percent" next to kernel TCP. So HTTP + JSON + JWT + kernel networking is
  roughly 40 µs per request out of ~275 µs.
- **[E] Rule of thumb:** cutting app CPU by 10% (about 6 µs) gives about +2% throughput. Cutting Postgres CPU by
  10% (about 21 µs) gives about +8%. Every runtime, JIT, GC or I/O choice below is a second-order lever next to
  per-request Postgres cost, cross-request batching and bcrypt lanes. I rank the options with that in mind.
- **[M, derived]** io_uring did not make the app side cheaper on this box: c-iouring spends 68 µs per request in
  the app, against 61 µs for tokio/epoll. That comparison is confounded (text vs binary results, different
  JSON code), but it gives no evidence that io_uring saves CPU here.

---

## 1. JVM choice and HotSpot flags

### 1.1 Ranked JVM options

| Rank | Option | Peak impact for this workload | Risk | Verdict |
|--:|---|---|---|---|
| 1 | **HotSpot C2, Temurin JDK 27+35** (current) | baseline | low | **keep** |
| 2 | Oracle GraalVM 25.0.4 native-image, `-O3` or PGO, `--gc=G1` or Serial, `-march=native` | [E] -5% to +5% app CPU with PGO; -10% to -30% without a real profile on branchy code | high: PGO training must run on the box during build.sh, needs DB and load | not worth it: Kotlin/Native already gives us an AOT binary |
| 3 | GraalVM CE 25 (Graal JIT on JDK 25; native-image Serial GC only, no PGO) | [E] JIT within ±5% of C2 on low-abstraction byte code, and we lose the JDK 26/27 improvements | medium | no |
| 4 | IBM Semeru / OpenJ9 | [E] lower peak than C2 for this kind of code; OpenJ9's strengths are footprint and startup | medium | no |
| — | Azul Platform Prime (Falcon JIT, ReadyNow) | vendor-only claims of +20-50% | licence and installation fail rule 11 | **excluded** |

**Facts behind the table**

- **JVMCI was removed in JDK 27, so no Graal JIT on a stock JDK 27.** [M] JDK-8382582 "Remove the experimental
  JVMCI feature" has fixVersion 27, Resolved/Fixed (bugs.openjdk.org REST). Locally,
  `java -XX:+UnlockExperimentalVMOptions -XX:+EnableJVMCI` gives "Unrecognized VM option 'EnableJVMCI'". Graal
  JIT therefore means running on a GraalVM 25 distribution (JDK 25).
- **Oracle moved GraalVM off the Java SE train.** [M] Per ADTmag/InfoWorld (Sept 2025), the Graal JIT is
  discontinued in Oracle JDK and users are pointed to C2; Native Image is no longer part of Java SE products.
  GraalVM 25 is LTS (Oracle support roadmap). The latest Oracle GraalVM build is **25.0.4+7.1** [M: the
  tarball's top-level directory is `graalvm-jdk-25.0.4+7.1`]. There is no JDK 26 or 27 build at
  `download.oracle.com/graalvm/{26,27}/latest` (404).
- **What each native-image edition has.** [M] GraalVM's "Optimizations and Performance" docs: PGO
  (`--pgo-instrument`, then `--pgo`) and the ML profile inference used at `-O3` are **not in Community Edition**,
  where `-O3` is the same as `-O2`. G1 is Oracle-only (CE has Serial and Epsilon). The default `-march` is
  x86-64-v3, and `-march=native` is available in both editions.
- **Azul Prime is not freely usable here.** [M] Azul's blog and docs say Stream Builds are free for evaluation
  and development, and that production use needs a licence. The download implies accepting an "Evaluation
  Agreement". Anonymous metadata lookup is refused: `api.azul.com/metadata/v1/zing/packages/...` returns 403
  "token with package_zing_read permissions required". A pinned, checksummed install.sh on a clean box
  (rule 11) is therefore not possible, and the licence does not clearly cover a benchmark run by a third party.
- **There are no usable published TechEmpower comparisons.** TechEmpower's raw results
  (tfb-status.techempower.com) reset the connection from this sandbox, and no search turned up a head-to-head
  of native-image vs JVM, Graal vs C2, or OpenJ9 vs HotSpot on TFB. The non-TFB sources are vendor material
  (Oracle: "PGO gives same or better throughput than JIT"; Azul: "+20-50%") or anecdotes (Quarkus 2018: JVM
  mode had higher throughput than native). **[E]** The consensus across those sources: C2 at peak ≥ Graal CE
  native-image without PGO, and Oracle native-image with PGO ≈ C2.

**Install snippets (official tarballs, pinned, checksummed)**

- Temurin 27+35 [M: Adoptium API]:
  `https://github.com/adoptium/temurin27-binaries/releases/download/jdk-27%2B35/OpenJDK27U-jdk_x64_linux_hotspot_27_35.tar.gz`,
  sha256 `1cf69a4848ffb728b3b260dfd45206a51566ab571a02a30092271d4c580bccbc`.
  The current install.sh trusts the checksum that the same API returns. Hard-coding this value is a stricter
  pin.
- Oracle GraalVM 25.0.4 [M: Oracle's `.sha256` sidecar]:
  `https://download.oracle.com/graalvm/25/archive/graalvm-jdk-25.0.4_linux-x64_bin.tar.gz`,
  sha256 `76007c309f821aaf435bce63162ea0395587fc77350801c81643fe7feea37276`. 25.0.3 is
  `1b5296613c3d12521d594e1c99302df88d8e1f07d74ab7983dbf572000b92c7c`. Native Image also needs
  `apt-get install build-essential zlib1g-dev`.
  - **Licence: GFTC** [M: LICENSE.txt in the tarball]. It allows internal use "for developing, testing,
    prototyping and demonstrating your applications" and for internal business operations, plus free
    redistribution of the unmodified program. Native-image output counts as an unmodified Program. There is no
    benchmark-publication clause.
- GraalVM CE: GitHub `graalvm/graalvm-ce-builds`, tag `jdk-25.0.x` or `graal-25.2.4` (25.2.4 is "Innovation 2",
  OpenJDK 25.0.4+7, released 2026-07-28 per graalvm.org). Each tarball has a `.sha256` next to it. GitHub was
  blocked from this sandbox, so I could not copy the hash or the exact asset name.
- Semeru: GitHub `ibmruntimes/semeru25-binaries` (`ibm-semeru-open-jdk_x64_linux_25.0.x_*_openj9-0.5x.tar.gz`
  plus `.sha256.txt`). Not verified here.

### 1.2 Project Leyden in JDK 25-27: warm-up only

[M] From the openjdk.org JEP index and bugs.openjdk.org:

| JEP | Feature | Release |
|---|---|---|
| 483 | AOT class loading and linking | 24 |
| 514 | AOT command-line ergonomics (`-XX:AOTCacheOutput=app.aot` in one training run) | 25 |
| 515 | AOT method profiling | 25 |
| 516 | AOT object caching with any GC | 26 |
| **544** | **AOT code compilation** | **Integrated for JDK 28, not in 27** (JDK-8335368, fixVersion 28) |

JEP 515 states its goal as warm-up. C2 still compiles hot code from live profiles.

**[E]** Zero effect on peak throughput after the 3-minute warm-up. It could help only the 60-second health check,
which we already meet. Skip it.

If ever wanted: run `java -XX:AOTCacheOutput=build/app.aot ...` once during build.sh, then
`java -XX:AOTCache=build/app.aot ...`. The cache is a build output created on the box, so it is not a
prebuilt binary under rule 11.

### 1.3 HotSpot flags worth an A/B

Defaults below are [M] from `-XX:+PrintFlagsFinal` on Temurin 27+35. The current start.sh uses
`-Xms1g -Xmx1g -XX:+AlwaysPreTouch -XX:+UseCompactObjectHeaders` with G1.

| Flag(s) | Default in 27 | Expected peak effect | Risk / notes |
|---|---|---|---|
| **GC: `-XX:+UseParallelGC -XX:ParallelGCThreads=2`** (or `-XX:+UseSerialGC`) vs G1 | G1 (JEP 523: G1 is now the default in every environment) | [E] 0-2% less app CPU for an allocation-light server; at ~50 MB/s allocation and a 1 GB young gen that is one young GC every ~10-20 s of a few ms | low. [M] JEP 522 (JDK 26) already cut G1's x64 write barrier "from around 50 instructions to just 12" (up to +5% throughput, +5-15% for heavy reference writes) and says Parallel is still "slightly faster" on pure throughput |
| ZGC / Shenandoah | off | [E] -3% to -10% (load barriers, concurrent GC threads on a CPU-bound box) | **don't** |
| `-Xms2g -Xmx2g -Xmn1g` (Parallel) or fixed `-Xms = -Xmx` (G1) | ergonomic | [M] a prior Kotlin entry measured -2.5% app CPU from a fixed heap (research/kotlin-prior.md:196) | none; 16 GB box |
| `-XX:+AlwaysPreTouch` | false | startup only | fine (already on) |
| `-XX:+UseCompactObjectHeaders` | **true** (JEP 534, default in 27) | already on; the flag in start.sh is now a no-op | none. JDK-8385590 (19% MessageDigest regression) is macOS/aarch64, "<1%" on x64, closed Won't Fix |
| `-XX:+UseTransparentHugePages` | false | [E] 0-3% (TLB) | process-local `madvise`, allowed by rule 12. Ubuntu's default THP mode is `madvise` (sandbox shows `always [madvise] never`). Don't touch sysfs |
| `-XX:+UseLargePages` (hugetlbfs) | false | — | needs `vm.nr_hugepages` = kernel tuning: **not allowed** |
| Tiered (`-XX:-TieredCompilation`, `TieredStopAtLevel`) | tiered on | [E] 0% at peak | keep the default |
| Inlining: A/B `-XX:InlineSmallCode=4000 -XX:MaxInlineSize=70` (`FreqInlineSize=325`, `MaxInlineLevel=15` stay) | 2500 / 35 / 325 / 15 | [E] 0-2% app CPU for Kotlin code with many small calls | code-cache growth; measure with `-XX:+PrintCompilation` |
| `-XX:+UseSystemMemoryBarrier` | false (product) | [E] small gain: drops the fence from every JNI/NIO/non-critical FFM thread-state transition (needs membarrier, Linux 4.14+) | low; safepoints get slightly slower |
| `-XX:+UnlockExperimentalVMOptions -XX:+TrustFinalNonStaticFields` | false | [E] 0-1% (folds `final` fields of objects held in `static final`/Kotlin `object`s) | low; breaks only reflective writes to finals |
| `-XX:-UsePerfData` | true | [E] tiny | none |
| `-XX:-UseBiasedLocking` | **gone** (removed in JDK 18; [M] absent from the flag list) | — | `UseObjectMonitorTable` is true in 27; avoid contended `synchronized` on hot paths anyway |
| Vector API | [M] JEP 537, **twelfth incubator** in 27 | [E] negligible: SIMD would only speed up header and JSON scanning, a few % of app CPU | `--add-modules jdk.incubator.vector` at run time, `-Xadd-modules=jdk.incubator.vector` for kotlinc; prints an incubator warning. C2 intrinsics (`Arrays.mismatch`, `String.indexOf`, SHA/HMAC with `UseSHA=true`) cover most of it |

Suggested A/B set, one change at a time against the current start.sh:

```
A: -Xms2g -Xmx2g -XX:+AlwaysPreTouch                                     (G1, current)
B: A + -XX:+UseParallelGC -XX:ParallelGCThreads=2 -Xmn1g
C: B + -XX:+UseTransparentHugePages -XX:-UsePerfData
D: C + -XX:+UseSystemMemoryBarrier
E: C + -XX:InlineSmallCode=4000 -XX:MaxInlineSize=70
```

---

## 2. Kotlin/Native 2.4.21

### 2.1 What the local distribution contains [M]

- LLVM 21 (`llvm-21-x86_64-linux-essentials-116`). Sysroot `x86_64-unknown-linux-gnu-gcc-8.3.0-glibc-2.19-kernel-4.9-2`.
- `konan.properties`, linux_x64:
  - `targetCpu.linux_x64 = x86-64`
  - `targetCpuFeatures.linux_x64 = +cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87`
  - `clangOptFlags.linux_x64 = -O3`
  - `llvmInlineThreshold = 100` (LLVM's own -O3 default is 250)
  - `clangFlags.linux_x64 = -cc1 -emit-obj -disable-llvm-optzns -x ir ...`: clang only does codegen, and the
    optimisation pipeline runs inside the compiler.
- Runtime modules in `konan/targets/linux_x64/native/`: `pmcs_gc.bc`, `concurrent_ms_gc.bc`,
  `same_thread_ms_gc.bc`, `noop_gc.bc`, `custom_alloc.bc`, `std_alloc.bc`, `legacy_alloc.bc`, and the
  `{adaptive,aggressive,manual}_gcScheduler.bc`. There is **no mimalloc**: the compiler says "Usage of mimalloc
  in Kotlin/Native compiler is deprecated", and the std allocator is deprecated in favour of
  `pagedAllocator=false`.

**All `-Xbinary` option names in this compiler** [M: string constants in
`org.jetbrains.kotlin.config.nativeBinaryOptions.BinaryOptions`]:
`gc, gcSchedulerType, gcMarkSingleThreaded, gcMutatorsCooperate, auxGCThreads, concurrentWeakSweep,
concurrentMarkMaxIterations, fixedBlockPageSize, pagedAllocator, disableMmap, mmapTag, latin1Strings,
preCodegenInlineThreshold, cCallMode, genericSafeCasts, smallBinary, stackProtector, sourceInfoType,
runtimeAssertionsMode, checkStateAtExternalCalls, forceNativeThreadStateForFunctions,
escapeAnalysisPropagateExiledToHeapObjects, runLLVMPassesInCompiler, enableReleaseBinaryCache,
globalDataLazyInit, packFields, linkRuntime, freezing, memoryModel, sanitizer, appStateTracking, ...`
(plus Objective-C/Swift/bundle options).

### 2.2 Speed-relevant options

Defaults are [M], read from `NativeSecondStageCompilationConfig` bytecode and the binary-options docs page
(updated 2026-08-31).

| Option (Gradle: `kotlin.native.binary.<name>=...` or `-Xbinary=<name>=<v>`) | Default in 2.4.21 | Notes / expectation |
|---|---|---|
| **`gc`** = `cms` / `pmcs` / `stwms` / `noop` | **`cms`** (default since 2.4.0, per the 2.4.0 release notes) | Our gradle.properties pins `pmcs`. [E] For throughput, pmcs (stop-the-world parallel mark, no concurrent-mark barriers) vs cms is within ±2%. cms trades a little mutator cost for short pauses. A/B both. `noop` never frees memory: **OOM over a 25+ minute run, don't** |
| `gcSchedulerType` = `adaptive` / `aggressive` / `manual` | `adaptive` (`manual` only when gc=noop) | Keep adaptive; tune the heap targets at run time instead (2.3) |
| `gcMarkSingleThreaded` | false | Keep false |
| `gcMutatorsCooperate` | true for pmcs; forced false under cms ("not yet supported in CMS GC") | — |
| `auxGCThreads` | 0 | [E] 0-1 on a CPU-bound box |
| `pagedAllocator` | true (unless a sanitizer is on) | Keep. `false` is per-object malloc-like allocation, for memory limits/sanitizers only |
| `latin1Strings` | false (experimental) | [E] helps only if hot paths build `String`s; ours write bytes directly |
| **`preCodegenInlineThreshold`** | **0 = off** (experimental since 2.1.20) | [M] JetBrains: "setting the threshold to 40 ... overall performance improvement of 9.5%" on their benchmarks (What's new 2.1.20). **Try `=40`** |
| `sourceInfoType` | `noop` in release | Keep |
| `runtimeAssertionsMode` | `ignore` | Keep |
| `genericSafeCasts` | false in release (`= !optimizationsEnabled`) | Keep |
| `stackProtector` | `no` | Keep |
| `smallBinary` | false | Keep (true trades speed for size) |
| `enableReleaseBinaryCache` | false | Keep (true trades optimisation for build speed) |
| `cCallMode` (cinterop `-Xccall-mode direct`, experimental 2.3.20) | `indirectOrDirect` | [E] ~0: whole-program LTO already inlines the stubs |
| `freezing`, `memoryModel` | deprecated, no effect | — |

### 2.3 Run-time GC tuning (API, not a flag) [M: stdlib source `kotlin/native/runtime/GC.kt`]

`kotlin.native.runtime.GC` (opt-in `@OptIn(kotlin.native.runtime.NativeRuntimeApi::class)`) defaults:

| Property | Default |
|---|---|
| `autotune` | true |
| `targetHeapBytes` | 10 MiB |
| `minHeapBytes` | 5 MiB |
| `maxHeapBytes` | Long.MAX_VALUE |
| `targetHeapUtilization` | 0.5 |
| `heapTriggerCoefficient` | 0.9 |
| `regularGCInterval` | 10 s |
| `pauseOnTargetHeapOverflow` | true |

**[E]** With the defaults, a server allocating tens of MB/s collects several times per second. Setting
`GC.minHeapBytes = 1L shl 30` (and `targetHeapBytes` likewise) at startup cuts that to one collection every
~10+ s. This is probably the largest single K/N runtime win for steady state.

Check the effect with `-Xruntime-logs=gc=info` on a dev build.

### 2.4 LLVM CPU targeting: verified to work

[M] I compiled a small test both ways and disassembled it.

- **Baseline:** the Kotlin functions contained no ymm/zmm or BMI2 instructions. Only the runtime's
  `AVX2Traits::polyHash*` uses AVX2, behind runtime dispatch.
- **With the override below:** `kfun:#main` contained 13-22 ymm/zmm instructions and `shrx/shlx` appeared
  throughout.

```bash
# build.sh: detect the build machine (= the scoring box), using the clang that ships with K/N
CLANG=~/.konan/dependencies/llvm-21-x86_64-linux-essentials-116/bin/clang   # appears after the first K/N build
OUT=$("$CLANG" -march=native -### -c -x c /dev/null -o /dev/null 2>&1)
CPU=$(printf '%s' "$OUT" | grep -o '"-target-cpu" "[^"]*"' | cut -d'"' -f4)
FEAT=$(printf '%s' "$OUT" | grep -o '"-target-feature" "[^"]*"' | cut -d'"' -f4 | paste -sd, -)
# kotlinc-native / Gradle freeCompilerArgs (one arg; ';' separates properties):
"-Xoverride-konan-properties=targetCpu.linux_x64=$CPU;targetCpuFeatures.linux_x64=$FEAT"
```

- **Pass the full ±feature list, not just the CPU name.** Hypervisors mask CPUID features. Here clang
  reports `graniterapids` with 118 features, many of them `-` (for example `-avx10.1-512`, `-amx-avx512`).
  With only `targetCpu=graniterapids`, LLVM may emit instructions the VM lacks and the binary dies with SIGILL.
  The leaderboard's d-vibe-cyrusmsk entry crashed with SIGILL.
- Fallback when clang is not there yet: `gcc -march=native -Q --help=target | awk '/^ +-march=/{print $2}'`
  (build-essential is on the box). Or the portable `targetCpu.linux_x64=x86-64-v3` (AVX2/BMI2/FMA). I did not
  test the x86-64-v3 value here; it is a standard LLVM CPU name.
- [E] Expect a few % on loop-heavy code (SHA-256, JSON escaping, header scanning). Memory-bound code will not
  change much.
- `llvmInlineThreshold=250` (LLVM's -O3 default) is another `-Xoverride-konan-properties` key worth one A/B.
  [E] ±2%.
- Verified working combination: `-Xoverride-konan-properties=...` with `-Xbinary=preCodegenInlineThreshold=40`
  compiles and runs.

### 2.5 LTO, PGO and bounds checks

- **LTO:** release builds link the program, the klibs and the runtime bitcode into one LLVM module and run the
  LTO pipeline. That is whole-program optimisation, including the compiler's closed-world devirtualisation and
  escape analysis. There is nothing to enable.
- **PGO:** there is no supported PGO for Kotlin/Native. The distribution does ship `llvm-profdata` and
  `libclang_rt.profile.a`, and `-Xllvm-module-passes` takes a custom pass pipeline, so an unofficial IR-PGO
  hack is conceivable. **[E]** Not worth it: unsupported, fragile, and training would have to run on the box.
- **Bounds checks:** always on; no flag in 2.4.21's `-X` help. Simple `for (i in a.indices)` loops get the
  check removed. For really hot byte loops (SHA-256 rounds, JSON escape scanning), C code embedded in a
  cinterop `.def` file (after the `---` line) is a legitimate escape hatch. It is also the route to SHA-NI
  intrinsics via `__attribute__((target("sha")))`. [E] JWT HMAC is about 1-2 µs per request in pure Kotlin.

### 2.6 Kotlin/Native pitfalls for a multithreaded server

[M] from stdlib sources unless marked [E].

1. **Variadic C calls are expensive.** `platform.posix.syscall(__sysno: Long, vararg variadicArguments: Any?)`
   boxes every argument into an `Array<Any?>`. For io_uring_enter, or any per-request raw syscall, declare a
   non-variadic `static inline` wrapper in a `.def` file.
2. **Every C call switches thread state** (Runnable to Native and back, with a safepoint check on return).
   [E] A few ns per call. Fine per syscall, bad per byte.
3. **Pinning is cheap in 2.4.** `Pinned` is a class that holds the reference (`Pinning.kt`); there is no
   StableRef. Prefer one `usePinned` per buffer per I/O call, or per-loop `nativeHeap` scratch buffers.
4. **`AtomicReference` operations are seq-cst intrinsics on `@Volatile` fields** (`compareAndSetField`, etc.);
   reference stores go through GC barriers under cms. [E] Use `AtomicInt`/`AtomicLong` for counters and keep
   queues to one CAS per enqueue.
5. **[E] Allocation is slower than a HotSpot TLAB bump** (size-class pages per thread, heavier headers) and
   escape analysis only stack-allocates provably local objects. Avoid boxing (generic collections of
   primitives), captured lambdas on hot paths, `String` round-trips (UTF-16 conversion) and exceptions (C++
   unwinding).
6. **[E] GC pauses:** pmcs stops every Kotlin thread for the whole mark. With a ~100 MB live heap that is
   milliseconds, not a p99 problem, once the heap target is raised (2.3).
7. **glibc 2.19 sysroot:** only symbols present in glibc 2.19 can be linked; anything newer needs `syscall()`.
   Constants missing from the klibs are hard-coded (section 3).

---

## 3. Kernel-call options for the HTTP side

**Box kernel** [M]: Ubuntu 24.04's GA kernel is 6.8 (c-iouring's VM: 6.8.0-142). The HWE kernel is 6.17
(24.04.4, February 2026), and the next HWE (August 2026) comes from 26.04. So the box may run 6.8 or 6.17+,
depending on the image: probe features at run time.

**io_uring:** works on the box [M: c-iouring scored 84k there]. The upstream default of
`kernel.io_uring_disabled` is 0. c-iouring says provided-buffer rings were rejected on 6.8.0-142; that is
unverified, since `IORING_REGISTER_PBUF_RING` exists since 5.19.

| Mechanism | Kernel | JVM NIO | JVM via FFM | K/N (2.4 klibs) | Expected value here |
|---|---|---|---|---|---|
| epoll, edge-triggered, `EPOLLIN\|EPOLLOUT\|EPOLLRDHUP\|EPOLLET` registered **once** | any | NIO is level-triggered via Selector; no ET | yes | `EPOLLET`/`EPOLLRDHUP` in `platform.linux` [M] | [E] small but real: no `epoll_ctl(MOD)` when a write blocks. man epoll(7): a short read on a stream socket means the socket is drained, so no extra EAGAIN read is needed |
| `EPOLLEXCLUSIVE` | 4.5 | — | yes | **missing** [M]; use `1u shl 28` | none: only for one listener shared by several epoll sets; we use one listener per loop |
| `SO_REUSEPORT` listener per loop | 3.9 | `StandardSocketOptions.SO_REUSEPORT` | yes | `SO_REUSEPORT=15` [M] | keep (all top-5 entries do) |
| `SO_INCOMING_CPU` / `SO_ATTACH_REUSEPORT_CBPF` steering | reuseport selection fixed in 6.1 (commit b261eda84ec1, Oct 2022); CBPF is unprivileged; EBPF needs CAP_BPF | no | yes (setsockopt) | `SO_INCOMING_CPU=49`, `SO_ATTACH_REUSEPORT_CBPF=51` [M] | [E] ~0: with 2 loops on 8 vCPUs and virtio-net queues there is little locality to gain |
| `accept4(SOCK_NONBLOCK\|SOCK_CLOEXEC)` | 2.6.28 | NIO does accept + fcntl | yes | **no `accept4()`**, only `SYS_accept4=288` [M]; use `syscall` or a `.def` prototype | none: ~100-150 new connections/s (users / 900 s sessions) |
| `TCP_DEFER_ACCEPT` | old | no | yes | `TCP_DEFER_ACCEPT=9` [M] | none (same reason) |
| `TCP_NODELAY` | — | yes | yes | yes | **on for HTTP and for our Postgres client sockets** (pipelined small messages) |
| `TCP_QUICKACK` | — | `jdk.net.ExtendedSocketOptions.TCP_QUICKACK` [M] | yes | `TCP_QUICKACK=12` | none: not sticky, and the response carries the ACK |
| `SO_BUSY_POLL` | 3.11 | no | yes | `SO_BUSY_POLL=46` | **unusable:** raising it needs CAP_NET_ADMIN (we only have CAP_NET_BIND_SERVICE) and it burns CPU |
| `MSG_ZEROCOPY` | 4.14 | no | yes | missing (4.9 headers): `MSG_ZEROCOPY=0x4000000`, `SO_ZEROCOPY=60` | **negative:** the kernel docs put the break-even around 10 KB writes; our responses are 0.3-5 KB |
| `writev`/`sendmsg` vs one `write` | — | gathering write | yes | `writev`, `sendmsg` [M] | ~0; one contiguous buffer and one `write` per response is simplest |
| io_uring: multishot accept (5.19), multishot recv + PBUF ring (6.0/5.19), `SINGLE_ISSUER\|DEFER_TASKRUN` (6.1), registered files | 6.8 OK | no | possible with FFM (mmap rings, VarHandle acquire/release, `syscall` 425/426/427) | no header and no numbers (kernel 4.9): raw `syscall` 425/426/427 behind a non-variadic `.def` wrapper | [E] ≤1-2% of the box at best (fewer syscalls; the TCP stack cost stays). [M, derived] c-iouring's app CPU per request was not lower than tokio/epoll's. High effort |
| io_uring `SQPOLL` | 5.11 unprivileged | — | — | — | **negative** on a CPU-bound box: a kernel thread spins per ring |

**JVM note.** NIO adds Selector bookkeeping (selectedKeys set, synchronised key updates) and JNI transitions to
every read and write. The FFM alternative is `Linker.nativeLinker()` downcalls:

- `Linker.Option.critical(true)` [M: present in JDK 27] for the **non-blocking** `read`/`write`/`accept4`/
  `epoll_ctl`. It also allows heap `byte[]` segments, so there is no copy.
- A normal (non-critical) downcall for the **blocking** `epoll_wait`, or the GC cannot reach a safepoint.
- `Linker.Option.captureCallState("errno")` to read errno.

[E] This saves some app CPU, perhaps 0.5-1% of the box. Do it only if a profile shows NIO above ~10% of app
CPU.

**K/N note.** The current code already uses raw epoll (`NativeHttp.kt`). Switching it to ET with one-time
registration is the cheap improvement.

---

## 4. Several server processes on one port (`SO_REUSEPORT`, allowed by rule 1)

| | Pros | Cons |
|---|---|---|
| JVM | GC pauses isolated per process; smaller heaps | C2 compile and code cache duplicated (warm-up only); ~300-500 MB RSS each (fine on 16 GB) |
| K/N | each process has its own GC (pmcs stop-the-world hits only that process); no shared allocator state | GC work does not shrink, it is just split |
| **Both** | — | **Cross-request batching gets 1/N as many requests per batch.** That is our main lever on Postgres CPU per request (section 0: 10% of PG CPU ≈ 8% throughput). The budget of 95 PG connections is not the limit (N × 8 connections fits up to N = 11), but more backends mean more context switches, more lock and buffer contention, and smaller batches |

Data points [M]:

- cobol-gnucobol runs 6 forked processes with 12 PG connections and scored 84k. That equals single-process
  c-iouring, and is below single-process rust-tokio (100k, 2 workers, 8 connections).
- c-iouring found 1 event loop better than 2 on 4 cores (+5% req/s, fewer context switches).

**[E]** Single process. Multi-process is net negative for a batching design. If tested anyway, use N = 2, each
with 1 HTTP loop and half the PG connections, and compare Postgres µs per request, not just req/s.

---

## 5. Postgres side, within the rules

### 5.1 What role `conduit` can SET

[M] `pg_settings.context` on local PG 18 (the same major version as the box):

- **context `user`, settable per session or in the startup packet `options`:**
  `plan_cache_mode, jit, jit_above_cost, max_parallel_workers_per_gather, parallel_setup_cost, enable_*`
  (memoize, nestloop, hashjoin, mergejoin, seqscan, bitmapscan, indexonlyscan, sort, incremental_sort,
  hashagg, material, async_append, presorted_aggregate, self_join_elimination, group_by_reordering,
  distinct_reordering, partitionwise_join), `cpu_tuple_cost, cpu_index_tuple_cost, cpu_operator_cost,
  random_page_cost, seq_page_cost, effective_cache_size, work_mem, temp_buffers, geqo,
  from/join_collapse_limit, cursor_tuple_fraction, constraint_exclusion, default_transaction_isolation,
  default_transaction_read_only, statement_timeout, lock_timeout, idle_in_transaction_session_timeout,
  transaction_timeout, TimeZone, DateStyle, extra_float_digits, bytea_output, client_min_messages,
  effective_io_concurrency, io_combine_limit`.
- **context `superuser`, NOT settable by conduit:** `track_activities, track_counts, track_io_timing,
  track_wal_io_timing, track_functions, track_cost_delay_timing, compute_query_id, update_process_title,
  commit_delay, log_statement, log_min_duration_statement, wal_compression`.
  So the per-statement `pgstat_report_activity` and process-title updates stay.
- **context `postmaster`:** `huge_pages` (`try` in pg-conf) and `io_method` (`worker`).
- `synchronous_commit` is user-settable but forbidden by rule 6.

### 5.2 What actually cuts Postgres CPU for small indexed lookups

| Setting | Effect | Status |
|---|---|---|
| `plan_cache_mode=force_generic_plan` | [M, c-iouring] +41% list, +12% article throughput | all top-5 entries use it; keep |
| `jit=off` | protects against JIT on generic plans whose estimates exceed `jit_above_cost` | keep |
| `max_parallel_workers_per_gather=0` | no Gather planning or worker startup | keep |
| **`enable_memoize=off`** | **statement-dependent:** [M] c-iouring measured **-55%** on its list statement (the plan became a hash join over all users); cobol uses it and scored 84k | **We set it globally (DESIGN.md startup options). Audit:** `EXPLAIN (GENERIC_PLAN)` each prepared statement with exactly our session settings, then A/B with and without. The bounded inner `LIMIT 100` page trick removes the Memoize case that motivated it |
| `cpu_*_cost`, `random_page_cost`, `effective_cache_size`, other `enable_*` | change plan choice only, not per-row cost | useful only to steer a specific generic plan, and fragile (see the warning below) |
| `work_mem` | sorts and hashes only | irrelevant for LIMIT-10 pages over indexes |
| `TimeZone=UTC`, `DateStyle=ISO` | affect text output only | with binary results, timestamptz is sent as int8 µs: no cost |
| `client_encoding` | UTF8 to UTF8 means no conversion | — |

Two warnings:

- **Generic plans are rebuilt with the session's *current* GUCs whenever a relcache invalidation hits them**
  (autovacuum ANALYZE on favorites/follows/article_tags runs 10-30 times per 20 minutes, per c-iouring). Never
  change planner GUCs mid-session or per statement. Keep one fixed set in the startup packet.
- Statement-level tricks that do not need GUCs are worth more: named prepared statements (parse once), binary
  results, no Describe, one Sync per batch, few backends, long-lived connections. With `huge_pages=try` and
  no hugepages reserved, each new backend first-touch-faults the 4 GB of `shared_buffers` in 4 KB pages, so
  never reconnect.

### 5.3 Unix-domain socket instead of TCP loopback: not possible on the box

[M]

- setup-box.sh only **appends** `host all all 127.0.0.1/32 scram-sha-256`. The PGDG/Debian default
  `pg_hba.conf` already has `local all all peer`.
- Peer auth requires the OS user (`challenge`) to equal the requested role (`conduit`) unless a `pg_ident` map
  says otherwise. pg_hba/pg_ident are server config (rule 2), and `DATABASE_URL` points at 127.0.0.1 anyway.
- A socket connection would fail with "Peer authentication failed for user conduit".
- [E] It would have saved little anyway: with batches of many requests per packet, loopback TCP cost per
  request is well under 1% of the box.

### 5.4 Postgres-side JSON (json_build_object/json_agg, one text column per request)

**[E] Likely worse in total CPU**, because the work moves onto the bottleneck resource:

- Each value goes through its fmgr output function: `int8out`, `textout` plus `escape_json` per character,
  and `timestamptz_out` (timezone conversion and formatting, the most expensive part). The pieces are
  palloc'd into a StringInfo.
- Binary results instead cost Postgres almost nothing per field: `int8send`/`textsend`/`timestamptz_send` are
  memcpy-like.
- The response is larger on the wire (repeated keys, escaped text), so there are more loopback bytes on both
  sides.
- App-side JSON from binary rows is the cheapest place to do that work.
- [M] No top entry renders whole responses in Postgres. goose (62k) builds only the tags array in Postgres
  (`convert_to(array_to_json(...))`); d-arsd (23k) uses `json_agg` for tags and Postgres-formatted dates.
  Neither is an A/B.
- A/B recipe for when the lab is free. pgbench uses text results, which makes this comparison *favourable* to
  JSON: if JSON loses against text columns, it loses more against binary.

  ```
  pgbench -n -M prepared -c 4 -j 4 -T 30 -f cols.sql conduit_seed   # SELECT a.slug,a.title,...,u.username,u.bio,u.image ... (the article statement)
  pgbench -n -M prepared -c 4 -j 4 -T 30 -f json.sql conduit_seed   # SELECT json_build_object('slug',a.slug,...)::text ... (same FROM/WHERE)
  ```

  Pin both runs to the same CPUs and compare TPS per Postgres core.

---

## 6. Ranked summary (peak-throughput impact, this design)

| # | Option | Expected | Risk | Do |
|--:|---|---|---|---|
| 1 | Audit the global `enable_memoize=off` with `EXPLAIN (GENERIC_PLAN)` per statement under the real session settings; keep `force_generic_plan`, `jit=off`, `max_parallel_workers_per_gather=0`, a fixed GUC set, few long-lived backends | 0% to large (c-iouring measured -55% on one statement with memoize off) | low | **now** |
| 2 | K/N: `-Xbinary=preCodegenInlineThreshold=40` + host CPU via `-Xoverride-konan-properties=targetCpu.linux_x64=$CPU;targetCpuFeatures.linux_x64=$FEAT` (full ± list) | [E] +3-10% app CPU, so +1-2% throughput; JetBrains: +9.5% from the inliner alone | low-medium (SIGILL if only the CPU name is passed) | yes |
| 3 | K/N: `GC.minHeapBytes`/`targetHeapBytes` ≈ 1 GiB at startup; A/B `gc=pmcs` (pinned now) vs `cms` (2.4 default) | [E] fewer GCs; ±2% | low | yes |
| 4 | JVM: fixed heap + `-XX:+UseParallelGC -XX:ParallelGCThreads=2 -Xmn1g`, `+UseTransparentHugePages`, `-UsePerfData`; then A/B `+UseSystemMemoryBarrier` and inlining flags | [E] 0-3% app CPU each | low | yes |
| 5 | epoll ET, registered once, short-read = drained, one write per response, TCP_NODELAY on HTTP and PG sockets | [E] small | low | yes |
| 6 | JVM: FFM raw epoll (critical downcalls) instead of NIO | [E] ≤1% of the box | medium | only if a profile says so |
| 7 | io_uring (either binary) | [E] ≤1-2% of the box; [M, derived] no app-CPU advantage on the leaderboard | high | no |
| 8 | Multi-process with SO_REUSEPORT | [E] negative (smaller batches) | medium | no |
| 9 | Graal JIT / native-image / OpenJ9 | [E] ≤ C2, and stuck on JDK 25 | medium-high | no |
| — | Azul Prime | licence: evaluation only; anonymous download refused | — | excluded |
| — | Unix socket to PG | peer auth (challenge ≠ conduit) | — | impossible |
| — | PG-side JSON rendering | [E] more PG CPU | — | no |
| — | Leyden AOT cache | warm-up only; AOT code is JDK 28 (JEP 544) | — | skip |

## Sources

- Local: `/opt/kotlin-native/konan/konan.properties`, `kotlinc-native -X`, `javap` on
  `kotlin-native-compiler-embeddable.jar` (BinaryOptions, NativeSecondStageCompilationConfig,
  OptimizationPipelineKt), stdlib sources `/opt/kotlin-native/sources/kotlin-stdlib-native-sources.zip`
  (Pinning.kt, GC.kt, Atomics.native.kt), `klib dump-metadata` on platform.posix/linux; Temurin 27
  `-XX:+PrintFlagsFinal`; PG 18 `pg_settings`; a disassembly test of `-Xoverride-konan-properties`.
- JDK 27 JEP list: https://openjdk.org/projects/jdk/27/ ; JEP 522: https://openjdk.org/jeps/522 ; JEP index
  https://openjdk.org/jeps/0 ; JVMCI removal JDK-8382582 and JEP 544 JDK-8335368 on https://bugs.openjdk.org
- GraalVM: [ADTmag: Oracle shifts GraalVM focus away from Java](https://adtmag.com/Articles/2025/09/30/Oracle-shifts-GraalVM-focus-away-from-Java.aspx),
  [Native Image optimizations](https://www.graalvm.org/latest/reference-manual/native-image/optimizations-and-performance/),
  [GraalVM 25.2 release notes](https://www.graalvm.org/release-notes/25.2/), Oracle download `.sha256` files,
  GFTC LICENSE.txt in the tarball.
- Azul: [Prime Stream Builds free for evaluation](https://www.azul.com/blog/azul-platform-prime-stream-builds-are-now-free-for-evaluation-development-and-testing/),
  [tar.gz quick start](https://docs.azul.com/prime/prime-quick-start-tar), api.azul.com 403 response.
- Kotlin: [What's new 2.4.0](https://kotlinlang.org/docs/whatsnew24.html) (CMS default),
  [2.1.20](https://kotlinlang.org/docs/whatsnew2120.html) (preCodegenInlineThreshold, 9.5%),
  [2.2.0](https://kotlinlang.org/docs/whatsnew22.html) (pagedAllocator, latin1Strings),
  [binary options](https://kotlinlang.org/docs/native-binary-options.html),
  [memory manager](https://kotlinlang.org/docs/native-memory-manager.html).
- Kernel and Ubuntu: [Phoronix: 24.04.4 with 6.17 HWE](https://phoronix.com/news/ubuntu-24.04.4-lts),
  [io_uring_disabled sysctl (LWN)](https://lwn.net/Articles/937013),
  [SO_INCOMING_CPU reuseport fix](https://lkml.iu.edu/hypermail/linux/kernel/2210.1/02147.html),
  [io_uring multishot](https://man7.org/linux/man-pages/man7/io_uring_multishot.7.html).
- Repo: LEADERBOARD.md, submissions/c-iouring-tigokraft/README.md, research/others.md and kotlin-prior.md
  (earlier notes in this scratchpad), box/setup-box.sh.
