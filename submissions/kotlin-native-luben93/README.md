# Kotlin/Native, no framework: own HTTP/1.1 server on epoll, own Postgres client, batched reads

Front: direct

| | |
|---|---|
| Language / runtime | Kotlin 2.4.21, Kotlin/Native (LLVM) for linuxX64: a native executable, no JVM at run time |
| HTTP | own HTTP/1.1 engine on raw epoll (`platform.linux`), one SO_REUSEPORT listener per event-loop thread |
| Postgres | own wire-protocol 3.0 client (SCRAM-SHA-256, extended protocol, binary results), batched reads, group commit |
| JSON, JWT | own: streaming JSON writer straight from binary rows, HS256 |
| bcrypt | cost 10, up to 8 logins per batch with their rounds interleaved (13 ms CPU per hash; 18.7 ms in pure Kotlin): the public-domain Openwall C core, vendored as source in `native/`, compiled into the binary by cinterop with Kotlin/Native's clang `-O3`. Pure-Kotlin lanes are the fallback |
| Coroutines | Kotlin `suspend` with stdlib intrinsics only; continuations resume on the thread that did the I/O |
| Build | Gradle 9.8.2 (wrapper, checksummed) on Temurin JDK 27 (`install.sh`), used at build time only |
| Dependencies | none besides the Kotlin stdlib (and the vendored bcrypt C source, compiled on the box) |

This is the Kotlin/Native build of the same Kotlin Multiplatform code as `kotlin-raw-luben93` (the JVM build);
DESIGN.md describes the architecture and the rules it keeps (no caching, bcrypt cost 10 on every login, HS256 + exp
checked on every request, writes committed before responding).

```bash
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

Optional process settings (defaults sized from the CPU count): `HTTP_THREADS`, `DB_READ_CONNS`, `DB_WRITE_CONNS`,
`BCRYPT_THREADS`, `BCRYPT_BATCH_MS`, `DB_OPTIONS`. `BCRYPT_IMPL=kotlin` forces the pure-Kotlin bcrypt.
