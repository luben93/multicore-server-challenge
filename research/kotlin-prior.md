# Prior Kotlin entries: kotlin-vertx-canleon (46k) and kotlin-ktor-canleon (44k)

Read-only research for the zero-dependency Kotlin (JVM + Kotlin/Native) submission.

Path abbreviations used below:

- `V/` = `submissions/kotlin-vertx-canleon/src/main/kotlin/conduit/`
- `K/` = `submissions/kotlin-ktor-canleon/src/main/kotlin/conduit/`
- `VR/` = `submissions/kotlin-vertx-canleon/` (scripts, README, pom), `KR/` = `submissions/kotlin-ktor-canleon/`

**The two entries share everything except the web layer.** `diff -r` shows that `infrastructure/postgres/*`,
`infrastructure/security/*`, `domain/*`, `application/*`, `web/Serializers.kt` and `web/Messages.kt` are
byte-identical. Only `Main.kt`, `ServerVerticle.kt` (Vert.x only), `web/Http.kt`, `web/Authentication.kt` and
`web/*Routes.kt` differ. So the SQL, session settings, bcrypt, JWT and JSON encoding are the same in both. The
46k-vs-44k gap is caused only by the web framework (Vert.x Web vs Ktor).

---

## 0. Headline numbers (leaderboard and what they imply)

From `LEADERBOARD.md:7-21`, CPU is the share of the whole 8-core box. The per-request columns are my
arithmetic: `share x 8 cores / req/s`. bcrypt/s is an estimate: users / 900 s session length x (24.5% logins +
0.5% sign-ups), per `WORKLOAD.md:24-33`.

| entry | users | req/s | p95/p99 ms | app/PG CPU | box CPU | app ms CPU/req | PG ms CPU/req | total ms CPU/req | bcrypt/s |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| rust-tokio #1 | 100,000 | 26,279 | 119/185 | 20/70 | 90% | 0.061 | 0.213 | 0.274 | 27.8 |
| csharp-sockets #2 | 95,000 | 24,696 | 493/737 | 21/75 | 96% | 0.068 | 0.243 | 0.311 | 26.4 |
| c-iouring #3 | 84,000 | 21,262 | 339/421 | 18/80 | 98% | 0.068 | 0.301 | 0.369 | 23.3 |
| rust-mio #6 | 80,000 | 20,710 | 474/752 | 18/75 | 93% | 0.070 | 0.290 | 0.359 | 22.2 |
| go-epoll #10 | 61,000 | 15,865 | 351/484 | 20/73 | 93% | 0.101 | 0.368 | 0.469 | 16.9 |
| rust-hyper #11 | 58,000 | 15,075 | 223/367 | 29/69 | 98% | 0.154 | 0.366 | 0.520 | 16.1 |
| **kotlin-vertx #12** | 46,000 | 11,923 | 352/440 | 37/51 | **88%** | **0.248** | **0.342** | **0.590** | 12.8 |
| **kotlin-ktor #15** | 44,000 | 10,948 | 496/664 | 45/49 | **94%** | **0.329** | **0.358** | **0.687** | 12.2 |

What the table shows:

- **"Postgres was only ~50% CPU" does not mean Postgres had room to spare.** The box was 88% (Vert.x) and 94% (Ktor)
  busy at the passing load, because the app used the CPU Postgres didn't. The Kotlin entries plateaued on the
  box's CPU: about 0.59 ms of CPU per request, against 0.27 ms for #1. At 95% of 8 cores, 0.59 ms per request
  allows about 12.9k req/s, which is about 49.6k users. The next probe above 46k failed.
- **To hold 100k users (about 26.3k req/s) at about 90% CPU, total CPU must be at most 0.27-0.28 ms per request.**
- **The app costs 4-5 times as much CPU per request as #1/#2** (0.25-0.33 ms against 0.06-0.07 ms).
- **Postgres costs 40-60% more per request than #1/#2** (0.34-0.36 ms against 0.21-0.24 ms). The Kotlin SQL
  is in the same range as the other entries that don't batch (0.29-0.37 ms). The gap to #1/#2 comes mostly
  from batching reads across requests (section 5).
- **bcrypt alone uses most of the app budget at 100k users.** About 27.8 hashes/s x 51 ms (Bouncy Castle) is
  1.42 cores, which is 0.054 ms per request, almost the whole of #1's app CPU (0.061 ms). A zero-dependency
  build needs a faster bcrypt (an interleaved implementation, section 5) or bcrypt alone fills the app budget.
- The workload generates about 0.25-0.26 req/s per active user (`WORKLOAD.md:63`). Every entry in the table runs
  at 0.249-0.263, so users = req/s / 0.26 is a good conversion.

---

## 1. All SQL, endpoint mapping and session settings

### 1.1 Session settings (both entries, identical): `V/infrastructure/postgres/PostgresClient.kt:26-39`

Sent as StartupMessage parameters (Vert.x `addProperty` puts GUC name/value pairs straight into the startup
packet). Prepared statements are cached per connection:

```kotlin
fun connectOptions(databaseUrl: String): PgConnectOptions {
    val uri = URI.create(databaseUrl)
    val credentials = (uri.rawUserInfo ?: "").split(":", limit = 2).map { part -> URLDecoder.decode(part, Charsets.UTF_8) }
    return PgConnectOptions()
        .setHost(uri.host ?: "localhost")
        .setPort(if (uri.port == -1) 5432 else uri.port)
        .setDatabase(uri.rawPath.removePrefix("/"))
        .setUser(credentials.getOrNull(0))
        .setPassword(credentials.getOrNull(1))
        .setCachePreparedStatements(true)
        .addProperty("plan_cache_mode", "force_generic_plan")
        .addProperty("jit", "off")
        .addProperty("max_parallel_workers_per_gather", "0")
}
```

So the effective session settings are:

| GUC | value | measured effect (README) |
|---|---|---|
| `plan_cache_mode` | `force_generic_plan` | "17% less Postgres CPU" (`VR/README.md:70-71`) |
| `jit` | `off` | not measured separately |
| `max_parallel_workers_per_gather` | `0` | not measured separately (pgtune sets 4 on the box: `box/pg-conf.sh:20,43`) |
| TLS | none (client default) | "No TLS ... it only costs CPU" (`VR/README.md:72`) |

For comparison, other entries set these:

- C# #2 (`submissions/csharp-sockets-jh-d/src/Program.cs:13-14`), as the startup `options` parameter:
  `"-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0 -c enable_memoize=off"`.
  It is the only entry that also sets `enable_memoize=off`, so that no request gets a row that another request's
  lookup fetched in a batched statement.
- Rust #1 (`submissions/rust-tokio-Scooter1337/src/db.rs:316`), after connecting:
  `.batch_execute("SET plan_cache_mode = force_generic_plan; SET jit = off")`.

Other client details:

- **Placeholders.** The SQL in `Queries.kt` uses `?`, and `numberPlaceholders` (`PostgresClient.kt:59-70`)
  replaces every `?` with `$1..$n` in order. The result is memoized in a `ConcurrentHashMap`
  (`PostgresClient.kt:57,74`). Because every `?` gets its own number, the viewer id is bound twice (`$1`, `$2`),
  and the title three times in ARTICLE_UPDATE. That costs only a few bytes of Bind per request.
- **Parameter types.** Statements are prepared without declared types, so Postgres infers them. Offset and limit
  are bound with `addInteger` (int4) (`PostgresArticleRepository.kt:33`). Rust #1 declares every parameter as
  INT8/TEXT with `prepare_typed` (`rust.../src/db.rs:319-321`).
- **Statement cache.** Vert.x caches prepared statements only for SQL of at most 2048 chars
  (`DEFAULT_PREPARED_STATEMENT_CACHE_SQL_LIMIT = 2048`, max 256 statements; confirmed with javap on
  vertx-sql-client 5.2.1). The longest Kotlin statement is 1,109 chars (PAGE_FAVORITED_BY), so all 26 are
  cached. Nothing is re-parsed.
- **Unique violations.** SQLSTATE `23505` is mapped to 422 "username or email has already been taken"
  (`PostgresClient.kt:78-85`).

### 1.2 Endpoint to statement mapping (identical in both entries)

The bind order is the tuple order in the repository. RT is the number of round trips to Postgres. Each statement
is its own Bind/Execute/Sync, so each one is its own implicit transaction.

| Endpoint | Statements in order | Bind order (Kotlin source) | RT | Code |
|---|---|---|--:|---|
| POST /api/users | bcrypt hash (pool), then USER_INSERT | username, email, hash | 1 | `V/application/UserService.kt:17-20`, `V/infrastructure/postgres/PostgresUserRepository.kt:11-15` |
| POST /api/users/login | USER_BY_EMAIL, then bcrypt verify, then sign a JWT | email | 1 | `UserService.kt:22-25`, `PostgresUserRepository.kt:17-20`, `V/domain/user/User.kt:37-42` |
| GET /api/user | USER_BY_ID (no row: 401) | id | 1 | `UserService.kt:27-29`, `PostgresUserRepository.kt:22-24` |
| PUT /api/user | [bcrypt hash if a password is given], then USER_UPDATE (no row: 401; 23505: 422) | email, username, hash, bio, image, id | 1 | `UserService.kt:31-35`, `PostgresUserRepository.kt:26-37` |
| GET /api/profiles/:u | PROFILE (no row: 404) | viewer, username | 1 | `PostgresProfileRepository.kt:10-12` |
| POST /api/profiles/:u/follow | FOLLOW_BY_USERNAME (no row: 404) | username, follower | 1 | `PostgresProfileRepository.kt:14-16` |
| DELETE /api/profiles/:u/follow | UNFOLLOW_BY_USERNAME (no row: 404) | username, follower | 1 | `PostgresProfileRepository.kt:18-20` |
| GET /api/articles (no filter) | PAGE_ALL | viewer, viewer, offset, limit | 1 | `PostgresArticleRepository.kt:17-35` |
| GET /api/articles?tag= | PAGE_BY_TAG | tag, viewer, viewer, tag, offset, limit | 1 | same |
| GET /api/articles?author= | PAGE_BY_AUTHOR | author, viewer, viewer, author, offset, limit | 1 | same |
| GET /api/articles?favorited= | PAGE_FAVORITED_BY | user, viewer, viewer, user, offset, limit | 1 | same |
| GET /api/articles/feed | PAGE_FEED | user, user, limit (Long), offset (Long), user, offset, limit | 1 | `PostgresArticleRepository.kt:37-40` |
| GET /api/articles/:slug | ARTICLE_BY_SLUG (no row: 404) | viewer, viewer, slug | 1 | `PostgresArticleRepository.kt:42-44` |
| POST /api/articles | [TAGS_INSERT if tagList is non-empty], then ARTICLE_INSERT, then ARTICLE_BY_ID | tags[]; title, author, title, desc, body, tags[]; author, author, id | 2-3 | `ArticleService.kt:28-31`, `PostgresArticleRepository.kt:55-63` |
| PUT /api/articles/:slug | ARTICLE_OWNER (404/403), then ARTICLE_UPDATE, then ARTICLE_BY_ID | slug; title, desc, body, title, title, id; user, user, id | 3 | `ArticleService.kt:33-38`, `PostgresArticleRepository.kt:65-74` |
| DELETE /api/articles/:slug | ARTICLE_OWNER (404/403), then ARTICLE_DELETE | slug; id | 2 | `ArticleService.kt:40-44` |
| POST /api/articles/:slug/favorite | FAVORITE_BY_SLUG (no row: 404) | slug, user, user | 1 | `PostgresArticleRepository.kt:80-91` |
| DELETE /api/articles/:slug/favorite | UNFAVORITE_BY_SLUG (no row: 404) | slug, user, user | 1 | same |
| GET /api/articles/:slug/comments | COMMENTS_BY_ARTICLE_SLUG (0 rows: 404; 1 row with NULL id: empty list) | slug, viewer | 1 | `PostgresCommentRepository.kt:12-25` |
| POST /api/articles/:slug/comments | COMMENT_INSERT_BY_SLUG (no row: 404) | slug, author, body | 1 | `PostgresCommentRepository.kt:27-29` |
| DELETE /api/articles/:slug/comments/:id | non-digit id: 404; COMMENT_OWNER (404/403), then COMMENT_DELETE | comment id, slug; id | 2 | `CommentService.kt:18-22`, `V/infrastructure/web/CommentRoutes.kt:24-31` |
| GET /api/tags | TAGS (200 rows) | none | 1 | `PostgresTagRepository.kt:9-16` |

Row decoding (`PostgresArticleRepository.kt:94-104`, `PostgresCommentRepository.kt:12-25`):

- Every list row carries `articles_count`. A row with a NULL `id` stands for an empty page (offset past the end),
  so the count is never lost.
- Comments use one row per comment. No row at all means 404; a single row with a NULL comment id means the
  article has no comments.

### 1.3 How the SQL differs from SPEC's reference SQL (`V/infrastructure/postgres/Queries.kt:3-8, 99-103`)

1. **Tag names by primary key.** The tag list is
   `ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1)`.
   This does 2-3 primary-key lookups per article, instead of the generic plan's hash join over all 200 tags.
2. **Page ids first.** Each list picks its page of ids first (index-only), then runs the per-row subqueries only
   for those 10 rows. The comment in Queries.kt says page 5 went from 4.1 ms to 0.3 ms.
3. **Double bound.** `OFFSET ? LIMIT 100` inside, then `LIMIT ?` outside. A generic plan then knows the page has at
   most 100 rows, instead of assuming a parameter LIMIT returns 10% of the table.
4. **Count in the same statement.** The count and the page are one statement (`total LEFT JOIN page ON true`).
5. **Feed shortcuts.** In the feed, `following` is the constant `true`. The per-followee LATERAL uses
   `LIMIT (?::bigint + ?::bigint)` (limit + offset), so a huge offset can't overflow int.
6. **Writes in one statement.** Follow, unfollow, favorite, unfavorite and add-comment each find the target and
   write in one statement, using data-modifying CTEs. Favorite/unfavorite fix up the count for the snapshot rule:
   `(SELECT count(*) FROM favorites ...) + (SELECT count(*) FROM added)`, minus the removed rows for unfavorite.
7. **Article creation is two statements, not one transaction** (README "Behaviour notes"). TAGS_INSERT runs
   first in its own statement, then ARTICLE_INSERT inserts the article and links its tags.
8. **Comments in one statement.** The article lookup and the comments are one statement:
   `FROM (SELECT id FROM articles WHERE slug = ?) target LEFT JOIN LATERAL (... LIMIT 100) comment ON true`.

### 1.4 Verbatim SQL

- **Appendix A** holds every statement exactly as sent to Postgres (fully expanded, `$n`-numbered). I generated it
  by loading `QueriesKt` from the compiled `KR/target/classes` and applying the same `?` to `$n` numbering as
  `PostgresClient.kt:59-70`.
- **Appendix B** holds `Queries.kt` verbatim (source form with `?` placeholders and the composition comments).

---

## 2. Runtime: JVM flags, GC, heap, threads, pools and their measurements

### 2.1 Scripts (identical in both entries)

- `VR/install.sh`: installs Temurin JDK 27+35 (checksum-verified) into `/opt/jdk`. Maven comes from `./mvnw`.
- `VR/build.sh`: `./mvnw -q -B -DskipTests package` builds `target/conduit.jar` plus `target/lib/*` (no fat jar).
- `VR/start.sh:12-13` (verbatim):

```bash
exec "$JAVA" -Xms2g -Xmx2g -XX:+AlwaysPreTouch --enable-native-access=ALL-UNNAMED \
    -cp "target/conduit.jar:target/lib/*" conduit.MainKt
```

Flag by flag:

- The GC is the default G1. No GC flags are set, so G1 runs its default 8 parallel and 2 concurrent GC threads
  on 8 CPUs.
- `-Xms2g -Xmx2g -XX:+AlwaysPreTouch`: "no heap resizing under load (measured 2.5% less app CPU than the default,
  which starts at 8 MB)" (`VR/start.sh:9-10`), and "Fixed 2 GB heap: far fewer garbage collections (21 instead
  of 73 per minute)" (`VR/README.md:83`).
- `--enable-native-access=ALL-UNNAMED` lets Netty load its native epoll transport (JNI is restricted since JDK 24).
- "Tried and dropped: other garbage collectors (Parallel, ZGC)" gave no measurable gain (`VR/README.md:87`).
- Kotlin 2.4.21 targets JVM 21 and runs on JDK 27 (`VR/pom.xml:14-15`).
- No other flags: no `-XX:ParallelGCThreads`, no `-XX:ActiveProcessorCount`, no large pages, no `-Xss`.

Rough allocation estimate (mine, not measured): 21 young GCs per minute at 16.9k req/s locally, with an eden of
about 1 GB, is about 0.35 GB/s, or **about 20 KB allocated per request**. This is typical of a framework stack.

### 2.2 Thread model and pool sizes

**Vert.x entry** (`V/Main.kt:17-41`, `V/ServerVerticle.kt:43-64`):

- `cores = Runtime.availableProcessors()` (8 on the box).
- One Vert.x instance runs `setEventLoopPoolSize(cores)` (8 event loops) with `setPreferNativeTransport(true)`
  (Netty epoll) (`V/Main.kt:33`).
- 8 `ServerVerticle` instances (`DeploymentOptions().setInstances(servers)`, with `servers = min(cores, totalConnections)`)
  share one listening port. Vert.x hands accepted connections to the verticles' event loops round robin
  (no SO_REUSEPORT; the default `reusePort=false`).
- Each verticle builds **its own** pipelined `SqlClient` with `connectionsPerServer = totalConnections / servers`,
  which is 2 on the box (`V/Main.kt:22-25`, `V/ServerVerticle.kt:45`). A request is parsed, routed, sent to
  Postgres and answered on one event loop, with no thread hop. The coroutine runs on the verticle context
  (`coHandler`).
- Total Postgres connections: `DB_POOL_SIZE` or `2*cores` (16), clamped to 1..90 (`V/Main.kt:13,22-23`).
- bcrypt runs on `Executors.newFixedThreadPool(max(1, cores/2))`, which is **4 threads** of daemon threads named
  "bcrypt". It is entered with `withContext(dispatcher)` (`V/Main.kt:27`,
  `V/infrastructure/security/BcryptPasswordHasher.kt:18-42`).
- HTTP server options are all defaults (`V/ServerVerticle.kt:60`): `HttpServerOptions().setHost(host).setPort(port)`.
  I checked the Vert.x 5.2.1 constants with javap:
  - `DEFAULT_ACCEPT_BACKLOG = -1`, so Netty uses `NetUtil.SOMAXCONN`, read from `/proc/sys/net/core/somaxconn`
    (65535 on the box).
  - `DEFAULT_IDLE_TIMEOUT = 0`, so idle keep-alive connections are never closed.
  - `DEFAULT_TCP_NO_DELAY = true`, `DEFAULT_COMPRESSION_SUPPORTED = false`, `DEFAULT_REUSE_PORT = false`.
  - `DEFAULT_MAX_HEADER_SIZE = 8192`, `DEFAULT_MAX_INITIAL_LINE_LENGTH = 4096`.

**Ktor entry** (`K/Main.kt:39-78`):

- One Vert.x instance with 8 event loops, used **only for the Postgres connections** (`K/Main.kt:46`).
- One shared pipelined `SqlClient` with 16 connections (`K/Main.kt:48`).
- Ktor `embeddedServer(Netty)` with default thread groups. Javap on Ktor 3.6.0 `ApplicationEngine$Configuration`
  gives `connectionGroupSize = cores/2+1 = 5`, `workerGroupSize = cores/2+1 = 5`, `callGroupSize = cores = 8`.
  The README says: "Nothing blocks a request thread ... so Ktor's default thread counts are enough" (`K/Main.kt:64-65`).
- **So every Ktor request crosses threads.** It goes from the Netty I/O loop to a Ktor call thread, then to a
  Vert.x event loop (where Postgres is written and read), then back to the Ktor dispatcher, then to the Netty
  channel's event loop for the write.
- Up to **5 + 5 + 8 + 8 + 4 = 30 app threads** can be runnable, alongside 16 Postgres backends, on 8 cores.
- README: "Tried and dropped: running each request on its connection's own event loop (Ktor's `shareWorkGroup`)"
  gave no measurable gain (`KR/README.md:83`).
- Plugins: `StatusPages`, `RequestBodyLimit` (1 MB), and `Authentication` with a custom provider (`K/Main.kt:68-70`).

### 2.3 Postgres client: Vert.x pipelined pool

`V/infrastructure/postgres/PostgresClient.kt:47-53` builds it with `PgBuilder.client().with(PoolOptions().setMaxSize(n))`.

- **Pipelining.** With a pipelined pool, each connection's concurrency equals `pipeliningLimit`, which is
  `PgConnectOptions.DEFAULT_PIPELINING_LIMIT = 256`. I confirmed this with javap on `SqlConnectionPool$2`, which
  reads `Connection.pipeliningLimit()` when the pool is pipelined.
- **Which connection a statement goes to.** The vertx-core 5.2.1 `SimpleConnectionPool` (javap of
  `lambda$static$0/1` and `Acquire.execute`) decides in this order:
  1. the **first** connection in the list that is on the caller's event loop and has `available() > 0`;
  2. otherwise, if the pool is below max size, a **new** connection;
  3. otherwise the **first** connection with `available() > 0`.

  This is neither least-loaded nor round-robin. Statements pile onto the first connection until it has 256 in
  flight.
- **Local evidence.** A Vert.x baseline ran in this lab while I was researching: 2 app cores, so 2 verticles x 2
  connections. In 25 samples of `pg_stat_activity`, the first two backends were `active` in 25 of 25 samples.
  The two connections that were created lazily about a minute later were active in about 52-80% of samples.
- **Consequence.** Postgres executes one connection's pipeline strictly in order. A request waits behind every
  statement queued before it on that backend (head-of-line blocking), including slow list or feed pages and
  write commits waiting for their WAL flush.

What the README measured about the database side (`VR/README.md:57-72`, `VR/start.sh:2-5`):

- Vert.x PG client vs JDBC + HikariCP with 32 connections: "about 25% less Postgres CPU, 12% less CPU per request
  in total, and about 13% more users before the limit."
- "8 connections were too few, 24 and 32 no better than 16."
- jasync-sql (measured with Ktor): "about 30% more CPU per request and about 30% fewer requests per second at full
  load. It doesn't pipeline, and it parses results from text."
- "Before Vert.x: virtual threads, or more threads than connections for JDBC" showed no gain.

### 2.4 Other measured numbers to keep

From `VR/README.md` (Vert.x) unless marked `KR/` (Ktor):

- **No Nginx** "(biggest single effect)": Nginx cost "about 0.17 ms of CPU per request". Without it the same box
  handled "about 29% more requests per second". "40,000 [connections] added about 190 MB" (about 4.75 KB per
  connection in Netty/Vert.x).
- **Vert.x vs Ktor on the same code:** "35% less app CPU and 19% less CPU per request in total at moderate load,
  lower latency, and about 5% more users before the limit".
- **App cost per request** (HTTP, routing, token check, database round trip): about 0.1 ms in Vert.x and about
  0.16 ms in Ktor (`VR/README.md:119-120`, `KR/README.md:115-117`).
- **bcrypt:** about 50 ms of CPU per check. Bouncy Castle `OpenBSDBCrypt` takes 51 ms per verify against 56-61 ms
  for jBCrypt and at.favre (`VR/pom.xml:81`).
- **"No measurable gain":** writing JSON as raw bytes, Parallel or ZGC, and a custom bcrypt or JWT
  (`VR/README.md:86-88`). These were measured inside a framework-heavy stack, so the small savings may have been
  lost in the noise.

Local results (their machine, not the box):

| | Vert.x | Ktor | Java example |
|---|--:|--:|--:|
| Most users that passed | 19,000 | 18,000 (19,000 failed) | 4,500 |
| req/s at that load | 16,900 | 15,700 | 5,900 |
| CPU per request | 0.46 ms | 0.49 ms | 1.06 ms |
| p95 at 6,000 users | 4 ms | 17 ms | 542 ms |

Note that 16,900 req/s at 19,000 users is about 0.9 req/s per user. Their local load generator ran a faster mix
than the box's 0.26 req/s per user (the lab's own runs use `-think-scale 0.25`).

CPU share by endpoint (`VR/README.md:111-117` / `KR/README.md:107-113`):

| | Vert.x | Ktor |
|---|--:|--:|
| Article lists and the feed | ~38% | ~37% |
| Article page and its comments | ~26% | ~27% |
| Login (bcrypt) | ~18% | ~16% |
| Tag list | ~10% | ~11% |
| Profiles, writes, the rest | ~8% | ~9% |

---

## 3. Why they plateaued at 44-46k

Ordered by likely weight. "Confirmed" means verified in code or bytecode; "likely" means inferred.

1. **CPU saturation of the whole box (confirmed by the leaderboard numbers).** The box was 88% and 94% busy. Every
   other cause below is about using CPU less efficiently per request. The leaderboard's "~50% PG" left no headroom,
   because the app used the rest.

2. **App CPU per request is 4x that of #1/#2 (confirmed: 0.248 / 0.329 ms against 0.061-0.068 ms).**
   - bcrypt is about 0.054 ms of that per request (12.8 hashes/s x 51 ms is about 0.65 cores, or 8% of the box,
     at 46k users).
   - The other ~0.19 ms per request is framework and object work:
     - Netty HTTP codec plus Vert.x Web `Router`: routes are tried in declaration order, `:param` routes use
       regexes, and each request gets a `RoutingContext` with a HashMap of data. `BodyHandler` runs on POST/PUT.
     - The JWT is verified with java-jwt on **every** request. Javap confirms that `CryptoHelper.createSignatureFor`
       calls `Mac.getInstance(...)`, `new SecretKeySpec`, `Mac.init` per call. `JWTParser` decodes the header
       and payload with Jackson `ObjectReader`s.
     - Postgres rows are decoded into boxed Java objects (`String`, `OffsetDateTime`, `Long`, `String[]`), then
       copied into domain objects (`Article`, `Profile`) (`V/infrastructure/postgres/Mapping.kt`).
     - Timestamps go `OffsetDateTime`, then `Instant`, then `DateTimeFormatter.appendInstant(3)`, then a `String`
       (`V/infrastructure/web/Serializers.kt:26,148-150`).
     - kotlinx.serialization writes a `String`, which Vert.x copies again into a UTF-8 Buffer
       (`V/infrastructure/web/Http.kt:38-43`).
     - About 20 KB is allocated per request (estimate in section 2.1).

3. **Postgres CPU per request is 1.4-1.6 times that of #1/#2 (confirmed: 0.342 ms against 0.213/0.243 ms).**
   - **No batching across requests.** Each request is its own Bind/Execute/Sync, so each pays for its own
     transaction start and commit, snapshot, executor startup and shutdown, and lock acquisition on 6 tables plus
     their indexes. #1/#2 run N compatible queued reads as one statement (section 5).
   - **Tags are 200 DataRows.** `SELECT name FROM tags ORDER BY name` returns 200 rows and builds 200 String
     objects. GET /api/tags is about 10% of all CPU (README). #1 uses
     `SELECT ARRAY(SELECT name FROM tags ORDER BY name)`, one row. #1 also shares one execution among tag
     requests already queued; #2 batches them.
   - **Global count.** `SELECT count(*) AS articles_count FROM (SELECT 1 FROM articles a LIMIT 1000) s` lets the
     planner pick a heap scan. #1 uses `... (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s`, which walks the
     frozen, all-visible oldest end of the primary key as an index-only scan with no heap fetches. #2 uses
     `EXISTS (... ORDER BY c.id OFFSET 999)`, then 1000.
   - **Tag count.** The tag count always counts up to 1000 rows. #1 first checks whether a 1000th row exists
     (`EXISTS (... OFFSET 999 LIMIT 1)`).
   - **Favorites, two probes.** `favorites_count` and `favorited` are separate subqueries over favorites. #1's
     global and tag lists do one `LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = $1),false) AS fav ...)`.
   - **Comments.** Comments use a per-row `EXISTS` on follows. #1 and #2 read the viewer's followee set once per
     request (`c.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)`).

4. **Too many runnable threads for 8 cores (confirmed configuration; latency effect likely).**
   - Vert.x: 8 event loops + 4 bcrypt + 8 G1 GC workers + up to 16 Postgres backends.
   - Ktor: up to about 30 app threads + 16 backends.
   - #1 runs **2** Tokio workers (`cores.div_ceil(4)`) + 1 bcrypt worker + **8** Postgres connections
     (`rust.../src/main.rs:61,75-84`).
   - With fewer threads, each `epoll_wait` returns more events, so there are fewer wakeups and context switches,
     and the scheduler doesn't preempt latency-critical Postgres backends. At 88-94% box CPU the run queue is
     long, which shows up as p95 352/496 ms. #1 holds p95 119 ms at 90% CPU.

5. **Head-of-line blocking in the Vert.x pipelined pool (confirmed policy; effect likely).**
   - Statements go to the first connection with spare capacity, and that connection's pipeline can be up to 256
     deep (section 2.3). The first backends are always active, so a cheap `USER_BY_ID` can wait behind several
     list or feed pages.
   - The "16 connections" are not 16 equally loaded queues.
   - #1 routes to the least-loaded connection, with an affinity slack of 8.
   - #2 sends one statement per connection at a time (`DISPATCH_DEPTH 1`) and lets the batches grow instead.

6. **Writes share pipelines with reads (confirmed; effect likely).**
   - Every write commits synchronously and waits for its WAL flush, and every read pipelined behind it on that
     connection waits too. Writes are about 5% of requests, about 600/s.
   - #2 says this explicitly: "On a pipelined connection every read queued behind it would wait too, so writes go
     to connections of their own" (`submissions/csharp-sockets-jh-d/README.md:41-43`).
   - #1 runs dedicated write actors with group commit (1 ms window, at most 128 requests).

7. **bcrypt pool sizing (confirmed configuration).**
   - Four threads (cores/2) of 51 ms each can take 4 of 8 cores from Postgres during login bursts. That is a
     latency risk for everything else, while the logins themselves are only about 0.1% of requests. Login latency
     barely matters for p95/p99, but logins must keep up with about 28/s at 100k users, or they queue until the
     10 s timeout.
   - #1: 1 worker, 4 hashes interleaved, 160 ms collection window (`rust.../README.md:16`).
   - #2: 2 threads, up to 4 hashes interleaved, 300 ms wait (`csharp.../README.md:75-77,91-93`).

8. **Ktor-specific overhead (confirmed by their own measurement).** The Ktor entry pays for the extra thread hops
   per request and for Ktor's pipeline, phases and plugins. Their measurement: 35% more app CPU than Vert.x, and
   p95 496 against 352 on the box.

9. **Extra round trips on write endpoints (minor).**
   - Create article: 2-3 round trips. Update article: 3. Delete article: 2. Delete comment: 2.
   - #1 does update, delete and comment-delete in **one** statement with an author check in a CTE. #1 also
     creates an article in one statement that returns the full article.
   - Writes are only about 5% of requests, so this costs little. It does add pipeline occupancy.

What was not a problem:

- Per-connection memory (40k connections took about 190 MB).
- The prepared-statement cache (all statements are under the 2048-char limit).
- The accept backlog (Netty's default is SOMAXCONN).
- Idle-connection closing (Vert.x's idle timeout is 0).

---

## 4. Conformance handling worth copying (all of it passes the 197-step suite)

Request bodies (`V/infrastructure/web/Http.kt:22,27,30-36`; `K/infrastructure/web/Http.kt:30-38`):

- The body is read as JSON **whatever the Content-Type**.
- `Json { ignoreUnknownKeys = true }`. Conformance sends extra top-level and inner fields, including `"admin": true`
  (`bench/cmd/conformance/script.go:260`).
- Any parse failure gives 422 "malformed JSON body". This covers malformed JSON, an empty body, a missing wrapper,
  a wrapper that isn't an object, and a number where a string belongs. kotlinx is strict by default, so `123` for
  a String field fails (`script.go:253-258,807-816`).
- Every request field is `String? = null` (`V/infrastructure/web/Messages.kt:37-82`). The domain then validates:
  - Required fields go through `requireNotEmpty` (null or "" gives 422) (`V/domain/shared/Errors.kt:19-22`).
  - Optional changes go through `requireNotEmptyIfGiven` (null means unchanged; "" gives 422)
    (`V/domain/shared/Errors.kt:25-28`).
  - `bio` and `image` are not checked for emptiness. In PUT /api/user, null means unchanged
    (`V/domain/user/User.kt:52-65`; conformance "nulls-unchanged" at `script.go:363`).
- `tagList`: absent or null gives an empty list. An empty-string item gives 422 (`V/domain/article/Article.kt:57-67`).
  A null item or a number fails JSON decoding of `List<String>?`, which gives 422. Duplicates are fine: TAGS_INSERT
  uses `DISTINCT`, and the links use `= ANY(...)`.
- Passwords longer than **72 UTF-8 bytes** give 422 (`V/domain/user/User.kt:17-23`; `script.go:259`
  "password-over-72-bytes").
- Body limit 1 MB gives 413. Vert.x: `BodyHandler.create(false).setBodyLimit(1024L * 1024L)` (`Http.kt:27`).
  Ktor: `RequestBodyLimit` plus `PayloadTooLargeException` mapped to 413 (`K/Http.kt:90`).
- Order of checks: on auth-required routes, a missing or invalid token gives 401 **before** the body is parsed.
  Conformance `articles.create.no-auth` sends a valid body without a token and expects 401 (`script.go:802`).
  In Vert.x the body handler runs before auth only to read the bytes; parsing happens later.

Authentication (`V/infrastructure/web/Authentication.kt:23-67`, `V/infrastructure/security/JwtTokens.kt:10-25`):

- Header: `Authorization`. An absent **or empty** header means anonymous on optional routes and 401 on required
  routes.
- The header must start with exactly `"Token "`. Anything else, including `Bearer`, gives 401 **even on optional
  routes** (conformance `profile.get.invalid-token` at `script.go:411`).
- Verifier: `JWT.require(HMAC256(secret)).withClaimPresence("exp").ignoreIssuedAt().build()`:
  - The signature must be HS256; `alg` must be HS256, so `none` is rejected.
  - `exp` must be present and not past.
  - `iat` is ignored.
- `sub` must be a **JSON string** of ASCII digits that is greater than 0. A numeric `sub` is rejected, because
  java-jwt's `asString()` returns null for a number (`Authentication.kt:47-54`).
- Conformance's bad-token cases (`script.go:328-348`): no-header, bearer-scheme, no-scheme, garbage, wrong-secret,
  expired, no-exp, numeric-sub, non-numeric-sub, alg-none, and unknown-user. Unknown-user gives 401 because
  GET /api/user finds no row (`V/domain/user/User.kt:68-70`).
- Tokens issued: `{"sub": "<id>", "iat": now, "exp": now + 30 days}` (`JwtTokens.kt:17-24`).
- The presented token string is echoed back by GET and PUT /api/user (`UserPrincipal.token`).

Query parameters and paths (`V/infrastructure/web/Http.kt:126-157`; `K/infrastructure/web/Http.kt:106-122`):

- `parseUnsignedLong`: ASCII digits only after percent-decoding (no sign, no spaces, not empty), and the value must
  fit in a Long. Otherwise the result is -1.
- `intQueryParameter`: an absent parameter takes the default (limit 20, offset 0). If present, the value must be
  in `0..Int.MAX_VALUE`, otherwise 422 through `Pagination.assertRange`: limit 1-100, offset at least 0
  (`V/domain/shared/Pagination.kt:4-14`).
  - Conformance covers `limit=05&offset=005` (OK), `limit=%2B5`, `limit=%205`, `limit=`, `limit=1.5`,
    `offset=99999999999999999999` and `limit=0`/`101`/`-1` (`script.go:544-562`).
  - `offset=100000000` must give an empty page **with** the count (`script.go:548`). The `total LEFT JOIN page`
    shape does that.
- Filter parameters: an empty value counts as absent (`queryParameter`; conformance `empty-tag-ignored` at
  `script.go:593`). Priority is tag, then author, then favorited (`V/domain/article/Article.kt:46-54`;
  `script.go:588,606`).
- Malformed percent-encoding in the query string gives 400 (Vert.x catches `IllegalArgumentException` from
  `queryParams()`, `Http.kt:147-153`; Ktor maps `BadRequestException`, `K/Http.kt:92`). In Vert.x, a malformed
  path encoding also gives 400 (`errorHandler(400)`, `Http.kt:117`).
- Unknown paths **and wrong methods** give a JSON 404 (not 405) (`Http.kt:119-120`; Ktor `K/Http.kt:98-100`). Vert.x
  ignores a trailing slash (`/api/tags/` works).
- `/api/articles/feed` is declared before `/api/articles/:slug` (`V/web/ArticleRoutes.kt:42-43`).
- The comment `:id` must be digits, otherwise 404 (`V/web/CommentRoutes.kt:27-29`).

Responses (`V/infrastructure/web/Serializers.kt`, `Http.kt:24,73-79`):

- `Content-Type: application/json; charset=UTF-8`. 204 responses have an empty body.
- Errors use `{"errors":{"body":["<message>"]}}` for every status. The status mapping is NotFound 404, Forbidden
  403, Validation 422, Unauthorized 401 (`Http.kt:85-92`). Domain exceptions carry no stack trace
  (`RuntimeException(message, null, false, false)`, `V/domain/shared/Errors.kt:4`), which is cheap to throw.
- Timestamps: `DateTimeFormatterBuilder().appendInstant(3)` gives exactly 3 fractional digits, **truncated**
  (Postgres stores microseconds) (`Serializers.kt:25-26`).
- List articles omit `body`; single articles include it (`Serializers.kt:56-88`). `bio` and `image` are written as
  JSON null when NULL.
- New comments are written with `author.following = false` (SPEC), straight from SQL (`false AS following`).
- The feed's `following` is constant `true`.

Weak points not to copy:

- Article creation isn't one transaction. If the article insert fails, new tags stay behind.
- `TAGS_INSERT` inserts in DISTINCT (hash) order with `ON CONFLICT DO NOTHING`. It can deadlock in theory when two
  concurrent creates insert overlapping new tags in different orders, and it burns tag-id sequence values.
- #2 handles both: "Tags are only inserted when missing, in name order (no sequence burn, no deadlock between
  concurrent creates)".
- #1 uses a single statement with `existing AS MATERIALIZED` and `INSERT ... ORDER BY name ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id, name`
  (`rust.../src/sql.rs:102-117`).

---

## 5. Concrete differences from #1 (rust-tokio-Scooter1337) and #2 (csharp-sockets-jh-d)

| Aspect | Kotlin Vert.x / Ktor | #1 rust-tokio (100k) | #2 csharp-sockets (95k) |
|---|---|---|---|
| HTTP | Netty + Vert.x Web / Ktor | own HTTP/1.1 on httparse. Free-list buffers, 1 KiB request buffers, stack response headers, vectored writes, **buffers released while a socket is idle** | own HTTP on raw sockets. `SocketAsyncEventArgs`, pooled context per request, headers written last into space reserved in front of the body (one buffer, one send). Completions run inline on the epoll threads |
| App threads | 8 event loops (+ Ktor's 18) | **2** Tokio workers (`cores.div_ceil(4)`) | epoll threads plus one reader thread per Postgres connection, plus a flusher |
| Listen backlog | Netty SOMAXCONN (65535) | `socket.listen(16384)`, plus `set_nodelay(true)` per accepted socket (`main.rs:123,145`) | `_listen.Listen(65535)` (`Http.cs:24`) |
| PG client | Vert.x, pipelined, first-available routing, depth up to 256 | vendored tokio-postgres, pipelined. Reads go to the least-loaded connection with an affinity slack of 8 | own wire protocol 3.0 client: SCRAM, extended protocol, **binary results**, rows parsed in place in the receive buffer |
| PG connections | 16 (read and write mixed) | **6 read + 2 write = 8** | **12 read + 16 write = 28**, one statement in Postgres per read connection (`DISPATCH_DEPTH 1`) |
| Read batching | **none** | read actors combine compatible queued reads into one `unnest(...) WITH ORDINALITY ... CROSS JOIN LATERAL` statement (at most 32, no delay). List pages share article enrichment | same idea: requests of one kind wait until a read connection is free, then up to 64 go as one statement. No timer. At most 6 connections per kind |
| Writes | same pipelines as reads | **group commit**: actors collect writes (1 ms, at most 128), commit, then answer. Failed batches roll back and retry one by one | separate write connections, relying on Postgres's own group commit |
| Session settings | plan_cache_mode=force_generic_plan, jit=off, max_parallel_workers_per_gather=0 | plan_cache_mode=force_generic_plan, jit=off | the same three plus `enable_memoize=off` |
| JSON | Row, then domain object, then kotlinx String, then UTF-8 | direct serialization, SSE2 string escaping, borrowed PG text arrays | `Utf8JsonWriter` fed straight from binary rows. Property names pre-encoded. No strings on read paths |
| JWT | java-jwt: Jackson + `Mac.getInstance` per verify | hmac + sha2 crates | per-thread keyed `HMACSHA256` |
| bcrypt | Bouncy Castle, 51 ms, 4 threads, no batching | Openwall/libxcrypt C core, **1 worker, 4 hashes interleaved**, 160 ms collection window | own C# bcrypt, **2 threads x 4 interleaved**, 300 ms wait, a queued hash whose client has gone is dropped |
| Tags SQL | 200 rows | `SELECT ARRAY(SELECT name FROM tags ORDER BY name)`, one row. One execution is shared by tag requests already waiting | batched. Count and tag subqueries are tied to the request row (`WHERE r.i >= 0`) so they run once per request |
| Allocator / GC | G1, 2 GB | mimalloc, about 83-124 MB RSS | workstation concurrent GC, tiered PGO |

### 5.1 SQL from #1/#2 worth porting (verbatim)

#### Rust #1 global list (`submissions/rust-tokio-Scooter1337/src/sql.rs:43-48`)

The count walks the oldest end of the primary key, and one LATERAL computes both the favorites count and the
viewer's favorite. Parameters: `$1` viewer, `$2` limit, `$3` offset, all INT8.

```sql
WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 fv.fc,
 fv.fav,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT * FROM (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET $3) bounded ORDER BY bounded.id DESC LIMIT $2) a ON true LEFT JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = $1),false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC
```

#### Rust #1 tag list (`sql.rs:50-55`)

The count uses a shortcut: if a 1000th row exists, the count is 1000. `$4` is the tag name.

```sql
WITH c AS (SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s) END AS n) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 fv.fc,
 fv.fav,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.article_id) a ON true LEFT JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = $1),false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC
```

#### Rust #1 favorited-by list (`sql.rs:62-67`)

The viewer's favorites and follows are read once, as arrays.

```sql
WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 COALESCE(a.id = ANY(ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = $1)), false),
 u.username, u.bio, u.image,
 COALESCE(a.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)), false) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.article_id) a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC
```

#### Rust #1 author list and feed (`sql.rs:10-39,57-60,69-72`)

These two are built with macros. Here they are verbatim, as the macros and their arguments. The feed binds
`[viewer, limit, offset, limit+offset]` (`api.rs:541-542`).

```rust
macro_rules! article_cols {
    ($body:literal) => {
        concat!(
            "a.id, a.slug, a.title, a.description, ",
            $body,
            "a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)"
        )
    };
}
macro_rules! list_stmt {
    ($count:expr, $page:expr) => {
        concat!(
            "WITH c AS (SELECT count(*) AS n FROM (",
            $count,
            " LIMIT 1000) s) SELECT c.n, ",
            article_cols!(""),
            " FROM c LEFT JOIN (",
            $page,
            ") a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC"
        )
    };
}
pub const LIST_AUTHOR: &str = list_stmt!(
    "SELECT 1 FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = $4)",
    "SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a2.id DESC LIMIT $2 OFFSET $3"
);
pub const LIST_FEED: &str = list_stmt!(
    "SELECT 1 FROM articles a3 WHERE a3.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)) ORDER BY a3.author_id, a3.id DESC",
    "SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id ORDER BY a3.id DESC LIMIT $4) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.id"
);
```

#### Rust #1 tags, comments and writes in one statement (`sql.rs:120-163,179`)

```sql
SELECT ARRAY(SELECT name FROM tags ORDER BY name)
```

```sql
SELECT a.id, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
 COALESCE(c.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1), false)
FROM articles a
LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id
                   ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
LEFT JOIN users u ON u.id = c.author_id
WHERE a.slug = $2
ORDER BY c.created_at DESC, c.id DESC
```

```sql
WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
       updated_at = now()
       WHERE id = (SELECT id FROM t WHERE author_id = $5) RETURNING 1)
SELECT t.id, t.author_id, (SELECT count(*) FROM w) FROM t
```

```sql
WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2))
SELECT author_id FROM t
```

```sql
WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
                WHERE c.id = $1 AND a.slug = $2),
 w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3))
SELECT author_id FROM t
```

#### Rust #1 article creation in one statement (`sql.rs:102-117`)

`$1` author, `$2` title, `$3` description, `$4` body, `$5` tags (text[]).

```sql
WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id),
 a AS (INSERT INTO articles (id, slug, author_id, title, description, body)
       SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4 FROM n
       RETURNING id, slug, title, description, body, created_at, updated_at, author_id),
 existing AS MATERIALIZED (SELECT id, name FROM tags WHERE name = ANY($5::text[])),
 t AS (INSERT INTO tags (name)
       SELECT name FROM (SELECT DISTINCT unnest($5::text[]) AS name) names
       WHERE NOT EXISTS (SELECT 1 FROM existing e WHERE e.name = names.name)
       ORDER BY name ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id, name),
 all_tags AS (SELECT id, name FROM existing UNION ALL SELECT id, name FROM t),
 x AS (INSERT INTO article_tags (article_id, tag_id) SELECT a.id, all_tags.id FROM a, all_tags)
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
 ARRAY(SELECT name FROM all_tags ORDER BY name), 0::bigint, false,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)
FROM a JOIN users u ON u.id = a.author_id
```

#### Rust #1 read-batch wrapper (`submissions/rust-tokio-Scooter1337/src/read_batch.rs:60-68`)

The query is built at startup from each single-request statement:

1. Every `$n` is replaced by `r.pn`.
2. Each parameter type becomes an array: INT8 becomes `bigint[]`, TEXT becomes `text[]`.
3. The statement is wrapped like this:

```rust
let mut query = format!(
    "SELECT q.*, r.ord::bigint AS __request_id FROM unnest({}) WITH ORDINALITY AS r({},ord) CROSS JOIN LATERAL ({replaced}) q",
    args.join(","),
    names.join(","),
);
// Explicitly preserve each original list's order after result demultiplexing.
if ordered {
    query.push_str(" ORDER BY r.ord, q.id DESC");
}
```

Here `args` holds `$1::bigint[]`, `$2::bigint[]`, ... and `names` holds `p1`, `p2`, .... Statements batched this way
(`read_batch.rs:19-30`): LIST_ALL, LIST_TAG, LIST_AUTHOR, LIST_FAVORITED, LIST_FEED, ARTICLE_BY_SLUG,
ARTICLE_BY_ID, PROFILE, USER_BY_ID and USER_BY_EMAIL. Tags are broadcast to the requests already waiting.

The "shared enrichment" variant (`read_batch.rs:175-199`, used when at least half the batched requests have the
same non-viewer arguments) is:

```sql
WITH requests AS MATERIALIZED (
         SELECT * FROM unnest({args}) WITH ORDINALITY AS r({names},ord)),
         counted AS MATERIALIZED (
         SELECT r.*, c.n FROM requests r CROSS JOIN LATERAL ({count}) c),
         pages AS MATERIALIZED (
         SELECT r.ord, r.p1 AS viewer, r.n, p.id FROM counted r
         LEFT JOIN LATERAL ({page}) p ON true),
         article_ids AS (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL),
         enriched AS MATERIALIZED (
         SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id,
         ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
               FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tags,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc,
         u.username, u.bio, u.image
         FROM article_ids i JOIN articles a ON a.id = i.id JOIN users u ON u.id = a.author_id)
         SELECT p.n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at,
         COALESCE(e.tags, ARRAY[]::text[]), COALESCE(e.fc, 0::bigint),
         EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = p.viewer),
         e.username, e.bio, e.image,
         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = p.viewer AND fo.followee_id = e.author_id),
         p.ord::bigint AS __request_id
         FROM pages p LEFT JOIN enriched e ON e.id = p.id ORDER BY p.ord, e.id DESC
```

The `{count}` and `{page}` parts for LIST_ALL are
`SELECT count(*) AS n FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s` and
`SELECT id FROM (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET r.p3) bounded ORDER BY id DESC LIMIT r.p2`.
The other kinds are at `read_batch.rs:147-174`. Feed pages never use the shared variant.

#### C# #2 batching pattern (`submissions/csharp-sockets-jh-d/README.md:24-27`)

```sql
SELECT r.i, x.* FROM unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, k)
CROSS JOIN LATERAL (<the per-request query, with r.v as the viewer and r.k as the slug>) x
```

Its rules:

- Subqueries that don't use a request parameter are tied to the request row with `WHERE r.i >= 0`, so they run
  once per request, not once per statement.
- The count sits in an `OFFSET 0` subquery.
- Memoize is off for the session.

Its global count (`submissions/csharp-sockets-jh-d/src/Sql.cs:92-94`):

```sql
CASE WHEN EXISTS (SELECT 1 FROM articles c WHERE r.i >= 0 ORDER BY c.id OFFSET 999) THEN 1000 ELSE (SELECT count(*) FROM articles c WHERE r.i >= 0) END
```

How the batched list is assembled (`Sql.cs:86-87`):

```
"SELECT r.i, c.n, x.* FROM " + Unnest(l) + " CROSS JOIN LATERAL (SELECT " + Bind(count, l) + " AS n OFFSET 0) c " + ...
```

#### Favorites write path

- #2 runs the favorite or unfavorite write, then the read-back as a second statement in the **same Sync group**,
  so the read sees concurrent writes the insert waited for.
- #1 reads back after the group commit, in a fresh snapshot.
- Kotlin computes `count + inserted` in one statement (section 1.3).

---

## 6. OS and file-descriptor limits (the "64k" concern)

What the box provides:

- **`box/challenge.service:19`: `LimitNOFILE=200000`** for the service, plus `AmbientCapabilities=CAP_NET_BIND_SERVICE`
  for port 80.
- `box/setup-box.sh:71-72` adds systemd `DefaultLimitNOFILE=200000:1048576` and `limits.d` nofile 200000 soft,
  1048576 hard.
- `box/sysctl.conf` (`/etc/sysctl.d/90-challenge.conf`):
  - `net.core.somaxconn = 65535`
  - `net.ipv4.tcp_max_syn_backlog = 65535`
  - `net.ipv4.ip_local_port_range = 1024 65535`
  - `net.ipv4.tcp_tw_reuse = 1`
  - `fs.file-max = 2097152`
  - `fs.nr_open = 1048576`
  - plus `nf_conntrack_max = 1048576` if conntrack is loaded (`setup-box.sh:66-68`).

Traps:

- **The roughly 64k source ports per (load-box IP, target IP:port) pair** are why the load generator can dial
  several IPs of the same server: "several IPs of one target: >64k users per load box"
  (`bench/cmd/loadgen/client.go:31-34`, `run.go:275-276`). **The server must listen on `0.0.0.0`** (HOST on the box),
  not on one address. The server itself uses no ephemeral ports for accepted connections. The only outbound
  connections are to Postgres on loopback (fewer than 100).
- **What the prior Kotlin entries did.** They did nothing explicit and were safe:
  - The JVM raises the soft NOFILE limit to the hard limit at startup (`-XX:+MaxFDLimit`, on by default on Linux).
  - Netty's default backlog is `NetUtil.SOMAXCONN`, and Vert.x's `acceptBacklog` is -1.
  - The Vert.x idle timeout is 0, so idle connections are never closed.
  - About 4.75 KB per connection (190 MB for 40k).
- **JDK NIO default backlog.** `ServerSocketChannel.bind(addr)` uses a **backlog of 50**: backlog 0 means "default",
  which is 50 in OpenJDK. Always call `bind(addr, 65535)`; the kernel caps it at somaxconn (65535). The ramp opens
  about 100k connections in 60 s, about 1.7k/s, all with a 10 s timeout. A small backlog causes SYN drops and
  retransmits, which cost 1 s, 3 s, ... of latency per dropped connection. #1 uses 16384; #2 uses 65535.
- **Kotlin/Native: raise the fd limit yourself.** Call `getrlimit`/`setrlimit(RLIMIT_NOFILE)` (soft = hard) at
  startup. On the box systemd already sets 200000/200000, but a local shell or Docker may give 1024 or 65536. At
  100k connections plus Postgres plus the epoll fd, you need more than 100k.
- **Accept loop.** Use `accept4(..., SOCK_NONBLOCK|SOCK_CLOEXEC)`, and set `TCP_NODELAY` on each accepted socket.
  On `EMFILE`/`ENFILE`, back off briefly instead of spinning (#1 sleeps 10 ms: `main.rs:126-130`).
- **Never close idle keep-alive connections.** Think time is up to 70 s (`WORKLOAD.md:24`). The load generator
  retries once on a fresh connection if a reused one fails before any response byte arrives (`client.go:50-53`), so
  closing idle sockets costs reconnects (a SYN and an accept) but not errors.
- **Per-connection memory at 100k connections.** At 16 KB of buffers per connection, 100k connections would take
  1.6 GB. Keep idle connections to just the fd and a small state object, and borrow buffers only while a request
  is in flight. #1: "Buffers are released while sockets are idle"; it peaked at 83-124 MB RSS.
- **Request headers.** The load generator sends `Accept-Encoding: gzip`, but compression is optional (SPEC). It sends
  `Content-Length` (including `0` on bodiless POST and DELETE) and never chunked encoding (`client.go:56-78`).

---

## 7. Actionable takeaways for the zero-dependency Kotlin build

1. **Budget.** 100k users means about 26.3k req/s at 90% or less of 8 cores, so **at most 0.27 ms of total CPU per
   request**. Postgres needs about 0.21-0.24 ms of that (only reachable with read batching), which leaves the app
   **about 0.04-0.06 ms per request including bcrypt**.
2. **Port Kotlin's statements (Appendix A) as the per-request baseline, with #1's improvements** (section 5.1):
   - the global count walking the oldest end of the primary key;
   - the tag count's OFFSET 999 shortcut;
   - the fv LATERAL (count plus `bool_or`) for the global and tag lists;
   - favorited and following as `= ANY(ARRAY(...))` for the favorited-by list;
   - comments checking authors against the viewer's followee set;
   - tags as one ARRAY row;
   - update, delete and comment-delete as one statement each;
   - article creation as one statement.
3. **Session settings:** `plan_cache_mode=force_generic_plan`, `jit=off`, `max_parallel_workers_per_gather=0`,
   plus `enable_memoize=off` if batching. Send them as StartupMessage parameters (the way Vert.x does) or as
   `options=-c ...` (the way #2 does). Auth on the box is **SCRAM-SHA-256** for 127.0.0.1 (`box/setup-box.sh:40-41`).
   The Kotlin entries needed the `com.ongres.scram` library for it; we must implement it ourselves:
   PBKDF2-HMAC-SHA-256, HMAC and SHA-256. Kotlin/Native also needs its own SHA-256.
4. **Batch reads across requests** with `unnest(...) WITH ORDINALITY ... CROSS JOIN LATERAL` (#1's template,
   section 5.1). Dispatch when a read connection frees up, with no timer (#2's rule). Limit a batch to 32-64
   requests.
5. **Write connections.** Give writes their own connections (2 with group commit like #1, or several like #2).
   Never put a commit on a read pipeline.
6. **Route each statement to the least-loaded connection, with a bounded depth.** Don't copy Vert.x's
   first-available routing. About 6-12 read connections plus 2-16 write connections in total.
7. **App threads: 2-3 event loops, not 8.** For the JVM, consider one `ServerSocketChannel` per loop with
   `SO_REUSEPORT` (supported by NIO on Linux), or one acceptor. Use direct `ByteBuffer`s. The JDK's FFM API
   (`java.lang.foreign`, final since JDK 22) is part of the JDK, not a third-party library. It allows direct
   `epoll`/`accept4`/`writev` and `setpriority(gettid)` calls if NIO turns out to be the cost.
8. **bcrypt.**
   - Write our own Blowfish with 4 hashes interleaved per thread. Use 1-2 threads at low priority (Kotlin/Native:
     `setpriority`; JVM: Thread priorities are ignored on Linux without native calls).
   - Collect jobs for a short window. Drop jobs whose client has gone.
   - At Bouncy Castle speed (51 ms), 100k users need about 1.42 cores. The target is 35 ms or less of effective
     time per hash.
9. **JWT.**
   - Precompute the HMAC-SHA-256 inner and outer key states once, so a verify is about two SHA-256 compressions
     plus finalization.
   - Parse the header and payload by hand. `alg` must be exactly HS256; `sub` must be a JSON string of digits
     greater than 0; `exp` must be present and in the future. Ignore `iat`.
   - No Jackson, no `Mac.getInstance` per call.
10. **JSON straight from Postgres binary rows into the output buffer.**
    - Timestamps: binary int64 microseconds since 2000-01-01, formatted by hand to `YYYY-MM-DDTHH:MM:SS.mmmZ` (truncate).
    - text[] in binary format for the tags.
    - No intermediate domain objects or Strings. Response headers go into reserved space in front of the body,
      for one `write`.
11. **Network setup.** Listen backlog 65535, TCP_NODELAY, no idle timeout. Raise NOFILE in Kotlin/Native. Keep
    per-connection state small while idle.
12. **JVM flags baseline.** `-Xms2g -Xmx2g -XX:+AlwaysPreTouch` (measured: 2.5% less app CPU). With a low-allocation
    design, also try `-XX:ParallelGCThreads=2`/`-XX:ConcGCThreads=1`, `-XX:+UseParallelGC` or Serial, and
    `-XX:ActiveProcessorCount`. Their README didn't measure these, and the prior entries found no gain from the GC
    switch on an allocation-heavy stack.
13. **Copy the conformance handling in section 4:** auth before body parsing, digits-only paging, empty filters
    treated as absent, 404 for any unknown route or method, 400 for malformed percent-encoding, the 72-byte password
    limit, and 23505 mapped to 422.

---

## Appendix A: every Kotlin statement exactly as sent to Postgres (expanded, `$n`-numbered)

Generated from the compiled `submissions/kotlin-ktor-canleon/target/classes/conduit/infrastructure/postgres/QueriesKt.class`.
These constants are byte-identical to the Vert.x entry's. The same `?` to `$n` numbering as `PostgresClient.kt:59-70`
is applied, and surrounding whitespace is stripped. Bind order is in section 1.2.

#### USER_INSERT (113 chars, 3 params)

```sql
INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
RETURNING id, username, email, bio, image
```

#### USER_BY_EMAIL (81 chars, 1 params)

```sql
SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1
```

#### USER_BY_ID (63 chars, 1 params)

```sql
SELECT id, username, email, bio, image FROM users WHERE id = $1
```

#### USER_UPDATE (253 chars, 6 params)

```sql
UPDATE users SET email = COALESCE($1, email), username = COALESCE($2, username),
                 password_hash = COALESCE($3, password_hash), bio = COALESCE($4, bio), image = COALESCE($5, image)
 WHERE id = $6
RETURNING id, username, email, bio, image
```

#### PROFILE (184 chars, 2 params)

```sql
SELECT u.id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
  FROM users u WHERE u.username = $2
```

#### FOLLOW_BY_USERNAME (252 chars, 2 params)

```sql
WITH target AS (SELECT id, username, bio, image FROM users WHERE username = $1),
     added AS (INSERT INTO follows (follower_id, followee_id) SELECT $2, id FROM target ON CONFLICT DO NOTHING)
SELECT username, bio, image, true AS following FROM target
```

#### UNFOLLOW_BY_USERNAME (245 chars, 2 params)

```sql
WITH target AS (SELECT id, username, bio, image FROM users WHERE username = $1),
     removed AS (DELETE FROM follows WHERE follower_id = $2 AND followee_id IN (SELECT id FROM target))
SELECT username, bio, image, false AS following FROM target
```

#### PAGE_ALL (935 chars, 4 params)

```sql
SELECT total.articles_count, page.* FROM (SELECT count(*) AS articles_count FROM (SELECT 1 FROM articles a LIMIT 1000) s) total LEFT JOIN (
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $2 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
WHERE a.id IN (SELECT b.id FROM (SELECT p.id FROM articles p ORDER BY p.id DESC OFFSET $3 LIMIT 100) b ORDER BY b.id DESC LIMIT $4) ORDER BY a.id DESC) page ON true ORDER BY page.id DESC
```

#### PAGE_BY_TAG (1103 chars, 6 params)

```sql
SELECT total.articles_count, page.* FROM (SELECT count(*) AS articles_count FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s) total LEFT JOIN (
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $2) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $3 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
WHERE a.id IN (SELECT b.article_id FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC OFFSET $5 LIMIT 100) b ORDER BY b.article_id DESC LIMIT $6) ORDER BY a.id DESC) page ON true ORDER BY page.id DESC
```

#### PAGE_BY_AUTHOR (1076 chars, 6 params)

```sql
SELECT total.articles_count, page.* FROM (SELECT count(*) AS articles_count FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s) total LEFT JOIN (
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $2) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $3 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
WHERE a.id IN (SELECT b.id FROM (SELECT p.id FROM articles p WHERE p.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY p.id DESC OFFSET $5 LIMIT 100) b ORDER BY b.id DESC LIMIT $6) ORDER BY a.id DESC) page ON true ORDER BY page.id DESC
```

#### PAGE_FAVORITED_BY (1109 chars, 6 params)

```sql
SELECT total.articles_count, page.* FROM (SELECT count(*) AS articles_count FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s) total LEFT JOIN (
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $2) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $3 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
WHERE a.id IN (SELECT b.article_id FROM (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC OFFSET $5 LIMIT 100) b ORDER BY b.article_id DESC LIMIT $6) ORDER BY a.id DESC) page ON true ORDER BY page.id DESC
```

#### PAGE_FEED (1101 chars, 7 params)

```sql
SELECT total.articles_count, page.* FROM (SELECT count(*) AS articles_count FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s) total LEFT JOIN (
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $2) AS favorited,
       u.username, u.bio, u.image,
       true AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
WHERE a.id IN (SELECT b.id FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($3::bigint + $4::bigint)) x WHERE fo.follower_id = $5 ORDER BY x.id DESC OFFSET $6 LIMIT 100) b ORDER BY b.id DESC LIMIT $7) ORDER BY a.id DESC) page ON true ORDER BY page.id DESC
```

#### ARTICLE_BY_SLUG (635 chars, 3 params)

```sql
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $2 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
WHERE a.slug = $3
```

#### ARTICLE_BY_ID (633 chars, 3 params)

```sql
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $2 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
WHERE a.id = $3
```

#### TAGS_INSERT (88 chars, 1 params)

```sql
INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING
```

#### ARTICLE_INSERT (468 chars, 6 params)

```sql
WITH created AS (
  INSERT INTO articles (id, slug, author_id, title, description, body)
  SELECT n.id, trim(both '-' from lower(regexp_replace($1, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $2, $3, $4, $5
    FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
  RETURNING id),
     linked AS (
  INSERT INTO article_tags (article_id, tag_id)
  SELECT created.id, t.id FROM created, tags t WHERE t.name = ANY($6::text[]))
SELECT id FROM created
```

#### ARTICLE_OWNER (50 chars, 1 params)

```sql
SELECT id, author_id FROM articles WHERE slug = $1
```

#### ARTICLE_UPDATE (305 chars, 6 params)

```sql
UPDATE articles SET title = COALESCE($1, title), description = COALESCE($2, description), body = COALESCE($3, body),
       slug = CASE WHEN $4::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($5, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
       updated_at = now()
 WHERE id = $6
```

#### ARTICLE_DELETE (34 chars, 1 params)

```sql
DELETE FROM articles WHERE id = $1
```

#### FAVORITE_BY_SLUG (782 chars, 3 params)

```sql
WITH target AS (SELECT id FROM articles WHERE slug = $1),
     added AS (INSERT INTO favorites (user_id, article_id) SELECT $2, id FROM target ON CONFLICT DO NOTHING RETURNING 1)
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) + (SELECT count(*) FROM added) AS favorites_count,
       true AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $3 AND fo.followee_id = a.author_id) AS following
  FROM target JOIN articles a ON a.id = target.id JOIN users u ON u.id = a.author_id
```

#### UNFAVORITE_BY_SLUG (777 chars, 3 params)

```sql
WITH target AS (SELECT id FROM articles WHERE slug = $1),
     removed AS (DELETE FROM favorites WHERE user_id = $2 AND article_id IN (SELECT id FROM target) RETURNING 1)
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) - (SELECT count(*) FROM removed) AS favorites_count,
       false AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $3 AND fo.followee_id = a.author_id) AS following
  FROM target JOIN articles a ON a.id = target.id JOIN users u ON u.id = a.author_id
```

#### COMMENTS_BY_ARTICLE_SLUG (555 chars, 2 params)

```sql
SELECT target.id AS article_id, comment.*
  FROM (SELECT id FROM articles WHERE slug = $1) target
  LEFT JOIN LATERAL (
       SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
              EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $2 AND fo.followee_id = c.author_id) AS following
         FROM comments c JOIN users u ON u.id = c.author_id
        WHERE c.article_id = target.id
        ORDER BY c.created_at DESC, c.id DESC
        LIMIT 100) comment ON true
 ORDER BY comment.created_at DESC, comment.id DESC
```

#### COMMENT_INSERT_BY_SLUG (356 chars, 3 params)

```sql
WITH target AS (SELECT id FROM articles WHERE slug = $1),
     c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM target
           RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, false AS following
  FROM c JOIN users u ON u.id = c.author_id
```

#### COMMENT_OWNER (107 chars, 2 params)

```sql
SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
 WHERE c.id = $1 AND a.slug = $2
```

#### COMMENT_DELETE (34 chars, 1 params)

```sql
DELETE FROM comments WHERE id = $1
```

#### TAGS (35 chars, 0 params)

```sql
SELECT name FROM tags ORDER BY name
```


---

## Appendix B: `V/infrastructure/postgres/Queries.kt` verbatim (identical in both entries)

```kotlin
package conduit.infrastructure.postgres

// SQL for the Postgres repositories, with `?` placeholders (numbered $1, $2, ... when executed, see PostgresClient.kt).
// The parameters of each statement are listed above it in binding order. Based on SPEC.md's reference SQL, with two
// plan fixes measured with EXPLAIN ANALYZE on the full seed (same results, same indexes, less work):
// - tag names are looked up per tag through tags_pkey instead of hash-joining all 200 tags for every article row;
// - every paged list picks its page of ids first (index-only), so the per-row subqueries run only for the rows
//   returned, not for the rows OFFSET skips (page 5: 4.1 ms -> 0.3 ms).

/** An article's tag names, sorted: 2-3 primary-key lookups. */
private const val TAG_LIST =
    "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1)"

/** Parameters: viewer id, viewer id. */
private const val ARTICLE_LIST_SELECT = """
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       $TAG_LIST AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = ?) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
"""

/**
 * Like ARTICLE_LIST_SELECT, for the feed: every feed article is by an author the viewer follows (the same snapshot
 * selected it through follows), so `following` is true without checking. Parameters: viewer id.
 */
private const val FEED_SELECT = """
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       $TAG_LIST AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = ?) AS favorited,
       u.username, u.bio, u.image,
       true AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
"""

/** Parameters: viewer id, viewer id. */
private const val ARTICLE_FULL_SELECT = """
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       $TAG_LIST AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = ?) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
"""

/** SPEC's SLUGIFY of one parameter. */
private const val SLUGIFY = "trim(both '-' from lower(regexp_replace(?, '[^A-Za-z0-9]+', '-', 'g')))"

// ---- users ----

/** username, email, password hash */
internal const val USER_INSERT = """
INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?)
RETURNING id, username, email, bio, image"""

/** email */
internal const val USER_BY_EMAIL = "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = ?"

/** id */
internal const val USER_BY_ID = "SELECT id, username, email, bio, image FROM users WHERE id = ?"

/** email, username, password hash, bio, image (null: unchanged), id */
internal const val USER_UPDATE = """
UPDATE users SET email = COALESCE(?, email), username = COALESCE(?, username),
                 password_hash = COALESCE(?, password_hash), bio = COALESCE(?, bio), image = COALESCE(?, image)
 WHERE id = ?
RETURNING id, username, email, bio, image"""

// ---- profiles ----

/** viewer id, username */
internal const val PROFILE = """
SELECT u.id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = u.id) AS following
  FROM users u WHERE u.username = ?"""

/**
 * username, follower id. Finds the user and follows them in one statement (idempotent); no row: no such user.
 * The profile comes from the lookup, so the snapshot rule (see FAVORITE_BY_SLUG) doesn't matter here.
 */
internal const val FOLLOW_BY_USERNAME = """
WITH target AS (SELECT id, username, bio, image FROM users WHERE username = ?),
     added AS (INSERT INTO follows (follower_id, followee_id) SELECT ?, id FROM target ON CONFLICT DO NOTHING)
SELECT username, bio, image, true AS following FROM target"""

/** username, follower id. Finds the user and unfollows them in one statement; no row: no such user. */
internal const val UNFOLLOW_BY_USERNAME = """
WITH target AS (SELECT id, username, bio, image FROM users WHERE username = ?),
     removed AS (DELETE FROM follows WHERE follower_id = ? AND followee_id IN (SELECT id FROM target))
SELECT username, bio, image, false AS following FROM target"""

// ---- article lists: one page and the count capped at 1,000 ----
// The page and its count are parts, combined into one statement below (one round trip instead of two).
// Every page of ids is bounded twice: "OFFSET ? LIMIT 100" inside, then "LIMIT ?" (the real limit, 1-100) outside.
// Same rows as "LIMIT ? OFFSET ?", but a generic plan (prepared statement) then knows the page has at most 100 rows,
// instead of assuming a parameter LIMIT returns 10% of the table.

/** viewer id, viewer id, offset, limit */
private const val LIST_ALL = ARTICLE_LIST_SELECT +
    "WHERE a.id IN (SELECT b.id FROM (SELECT p.id FROM articles p ORDER BY p.id DESC OFFSET ? LIMIT 100) b " +
    "ORDER BY b.id DESC LIMIT ?) ORDER BY a.id DESC"

private const val COUNT_ALL = "SELECT count(*) AS articles_count FROM (SELECT 1 FROM articles a LIMIT 1000) s"

/** viewer id, viewer id, tag name, offset, limit */
private const val LIST_BY_TAG = ARTICLE_LIST_SELECT +
    "WHERE a.id IN (SELECT b.article_id FROM (SELECT at.article_id FROM article_tags at " +
    "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ?) ORDER BY at.article_id DESC OFFSET ? LIMIT 100) b " +
    "ORDER BY b.article_id DESC LIMIT ?) ORDER BY a.id DESC"

/** tag name */
private const val COUNT_BY_TAG =
    "SELECT count(*) AS articles_count FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ?) LIMIT 1000) s"

/** viewer id, viewer id, author username, offset, limit */
private const val LIST_BY_AUTHOR = ARTICLE_LIST_SELECT +
    "WHERE a.id IN (SELECT b.id FROM (SELECT p.id FROM articles p " +
    "WHERE p.author_id = (SELECT au.id FROM users au WHERE au.username = ?) ORDER BY p.id DESC OFFSET ? LIMIT 100) b " +
    "ORDER BY b.id DESC LIMIT ?) ORDER BY a.id DESC"

/** author username */
private const val COUNT_BY_AUTHOR =
    "SELECT count(*) AS articles_count FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = ?) LIMIT 1000) s"

/** viewer id, viewer id, username of the user who favorited, offset, limit */
private const val LIST_FAVORITED_BY = ARTICLE_LIST_SELECT +
    "WHERE a.id IN (SELECT b.article_id FROM (SELECT f.article_id FROM favorites f " +
    "WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = ?) ORDER BY f.article_id DESC OFFSET ? LIMIT 100) b " +
    "ORDER BY b.article_id DESC LIMIT ?) ORDER BY a.id DESC"

/** username of the user who favorited */
private const val COUNT_FAVORITED_BY =
    "SELECT count(*) AS articles_count FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = ?) LIMIT 1000) s"

/** user id, limit, offset (per followed author; added as bigint so a huge offset can't overflow), user id, offset, limit */
private const val FEED = FEED_SELECT +
    "WHERE a.id IN (SELECT b.id FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL " +
    "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (?::bigint + ?::bigint)) x " +
    "WHERE fo.follower_id = ? ORDER BY x.id DESC OFFSET ? LIMIT 100) b ORDER BY b.id DESC LIMIT ?) ORDER BY a.id DESC"

/** user id */
private const val COUNT_FEED = "SELECT count(*) AS articles_count FROM (SELECT 1 FROM articles a WHERE a.author_id IN " +
    "(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = ?) LIMIT 1000) s"

/**
 * The count (one row) with the page left-joined onto it: one row per article, each carrying articles_count. An empty
 * page (offset past the end) still gives one row, with a NULL id, so the count is never lost.
 * Parameters: the count's, then the page's.
 */
private const val PAGE_WITH_COUNT_START = "SELECT total.articles_count, page.* FROM ("
private const val PAGE_WITH_COUNT_MIDDLE = ") total LEFT JOIN ("
private const val PAGE_WITH_COUNT_END = ") page ON true ORDER BY page.id DESC"

/** viewer id, viewer id, offset, limit */
internal const val PAGE_ALL = PAGE_WITH_COUNT_START + COUNT_ALL + PAGE_WITH_COUNT_MIDDLE + LIST_ALL + PAGE_WITH_COUNT_END

/** tag name; viewer id, viewer id, tag name, offset, limit */
internal const val PAGE_BY_TAG = PAGE_WITH_COUNT_START + COUNT_BY_TAG + PAGE_WITH_COUNT_MIDDLE + LIST_BY_TAG + PAGE_WITH_COUNT_END

/** author username; viewer id, viewer id, author username, offset, limit */
internal const val PAGE_BY_AUTHOR = PAGE_WITH_COUNT_START + COUNT_BY_AUTHOR + PAGE_WITH_COUNT_MIDDLE + LIST_BY_AUTHOR + PAGE_WITH_COUNT_END

/** username; viewer id, viewer id, username, offset, limit */
internal const val PAGE_FAVORITED_BY =
    PAGE_WITH_COUNT_START + COUNT_FAVORITED_BY + PAGE_WITH_COUNT_MIDDLE + LIST_FAVORITED_BY + PAGE_WITH_COUNT_END

/** user id; user id, limit, offset, user id, offset, limit */
internal const val PAGE_FEED = PAGE_WITH_COUNT_START + COUNT_FEED + PAGE_WITH_COUNT_MIDDLE + FEED + PAGE_WITH_COUNT_END

// ---- single articles ----

/** viewer id, viewer id, slug */
internal const val ARTICLE_BY_SLUG = ARTICLE_FULL_SELECT + "WHERE a.slug = ?"

/** viewer id, viewer id, article id */
internal const val ARTICLE_BY_ID = ARTICLE_FULL_SELECT + "WHERE a.id = ?"

/** tag names (text[]). Runs before ARTICLE_INSERT, so the tags exist when the article links them. */
internal const val TAGS_INSERT = "INSERT INTO tags (name) SELECT DISTINCT unnest(?::text[]) ON CONFLICT (name) DO NOTHING"

/**
 * title (for the slug), author id, title, description, body, tag names (text[]).
 * Inserts the article and links its tags in one statement, so both happen or neither does.
 */
internal const val ARTICLE_INSERT = """
WITH created AS (
  INSERT INTO articles (id, slug, author_id, title, description, body)
  SELECT n.id, $SLUGIFY || '-' || n.id, ?, ?, ?, ?
    FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
  RETURNING id),
     linked AS (
  INSERT INTO article_tags (article_id, tag_id)
  SELECT created.id, t.id FROM created, tags t WHERE t.name = ANY(?::text[]))
SELECT id FROM created"""

/** slug */
internal const val ARTICLE_OWNER = "SELECT id, author_id FROM articles WHERE slug = ?"

/** title, description, body (null: unchanged), title, title (for the slug), article id */
internal const val ARTICLE_UPDATE = """
UPDATE articles SET title = COALESCE(?, title), description = COALESCE(?, description), body = COALESCE(?, body),
       slug = CASE WHEN ?::text IS NULL THEN slug ELSE $SLUGIFY || '-' || id END,
       updated_at = now()
 WHERE id = ?"""

/** article id */
internal const val ARTICLE_DELETE = "DELETE FROM articles WHERE id = ?"

/**
 * slug, user id, user id. Finds the article, favorites it (idempotent) and returns it as the user now sees it, in one
 * statement; no row: no such article.
 * Snapshot rule: every part of one statement sees the data as it was before the statement, so the count doesn't see
 * the row the CTE just inserted; adding the inserted rows (0 or 1) gives the count after the change.
 */
internal const val FAVORITE_BY_SLUG = """
WITH target AS (SELECT id FROM articles WHERE slug = ?),
     added AS (INSERT INTO favorites (user_id, article_id) SELECT ?, id FROM target ON CONFLICT DO NOTHING RETURNING 1)
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       $TAG_LIST AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) + (SELECT count(*) FROM added) AS favorites_count,
       true AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = a.author_id) AS following
  FROM target JOIN articles a ON a.id = target.id JOIN users u ON u.id = a.author_id"""

/** slug, user id, user id. Like FAVORITE_BY_SLUG, but removes the favorite: the count subtracts the deleted rows. */
internal const val UNFAVORITE_BY_SLUG = """
WITH target AS (SELECT id FROM articles WHERE slug = ?),
     removed AS (DELETE FROM favorites WHERE user_id = ? AND article_id IN (SELECT id FROM target) RETURNING 1)
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       $TAG_LIST AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) - (SELECT count(*) FROM removed) AS favorites_count,
       false AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = a.author_id) AS following
  FROM target JOIN articles a ON a.id = target.id JOIN users u ON u.id = a.author_id"""

// ---- comments ----

/**
 * article slug, viewer id. The article looked up by slug, with its newest 100 comments left-joined: no row means no
 * such article (404); one row with a NULL comment id means an article without comments.
 */
internal const val COMMENTS_BY_ARTICLE_SLUG = """
SELECT target.id AS article_id, comment.*
  FROM (SELECT id FROM articles WHERE slug = ?) target
  LEFT JOIN LATERAL (
       SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
              EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = c.author_id) AS following
         FROM comments c JOIN users u ON u.id = c.author_id
        WHERE c.article_id = target.id
        ORDER BY c.created_at DESC, c.id DESC
        LIMIT 100) comment ON true
 ORDER BY comment.created_at DESC, comment.id DESC"""

/**
 * article slug, author id, body. Finds the article and adds the comment in one statement; no row: no such article.
 * SPEC: a new comment has author.following = false.
 */
internal const val COMMENT_INSERT_BY_SLUG = """
WITH target AS (SELECT id FROM articles WHERE slug = ?),
     c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, ?, ? FROM target
           RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, false AS following
  FROM c JOIN users u ON u.id = c.author_id"""

/** comment id, article slug */
internal const val COMMENT_OWNER = """
SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
 WHERE c.id = ? AND a.slug = ?"""

/** comment id */
internal const val COMMENT_DELETE = "DELETE FROM comments WHERE id = ?"

// ---- tags ----

internal const val TAGS = "SELECT name FROM tags ORDER BY name"

```

## Appendix C: `V/infrastructure/postgres/PostgresClient.kt` verbatim (identical in both entries)

```kotlin
package conduit.infrastructure.postgres

import conduit.domain.shared.ValidationException
import io.vertx.core.Vertx
import io.vertx.kotlin.coroutines.coAwait
import io.vertx.pgclient.PgBuilder
import io.vertx.pgclient.PgConnectOptions
import io.vertx.pgclient.PgException
import io.vertx.sqlclient.PoolOptions
import io.vertx.sqlclient.Row
import io.vertx.sqlclient.RowSet
import io.vertx.sqlclient.SqlClient
import io.vertx.sqlclient.Tuple
import java.net.URI
import java.net.URLDecoder
import java.util.concurrent.ConcurrentHashMap

/**
 * Connection settings from a libpq-style DATABASE_URL (postgres://user:password@host:port/database).
 *
 * Settings for every connection (sent when it opens):
 * - plan_cache_mode=force_generic_plan: a statement is planned once per connection, not on every execution;
 * - jit=off, max_parallel_workers_per_gather=0: no JIT and no parallel workers for these short queries.
 * Prepared statements are cached per connection. No TLS (the client's default): the database runs on the same machine.
 */
fun connectOptions(databaseUrl: String): PgConnectOptions {
    val uri = URI.create(databaseUrl)
    val credentials = (uri.rawUserInfo ?: "").split(":", limit = 2).map { part -> URLDecoder.decode(part, Charsets.UTF_8) }
    return PgConnectOptions()
        .setHost(uri.host ?: "localhost")
        .setPort(if (uri.port == -1) 5432 else uri.port)
        .setDatabase(uri.rawPath.removePrefix("/"))
        .setUser(credentials.getOrNull(0))
        .setPassword(credentials.getOrNull(1))
        .setCachePreparedStatements(true)
        .addProperty("plan_cache_mode", "force_generic_plan")
        .addProperty("jit", "off")
        .addProperty("max_parallel_workers_per_gather", "0")
}

/**
 * The client for single statements. It doesn't block a thread while Postgres works, and it pipelines: it sends the
 * next statement over a connection without waiting for the previous result, spreading statements over [connections]
 * connections. So a few connections serve all requests, which means fewer Postgres processes competing for the cores.
 * Every write is a single statement (Postgres runs each one atomically), so no request needs a connection to itself.
 */
fun createPipelinedClient(vertx: Vertx, options: PgConnectOptions, connections: Int): SqlClient {
    return PgBuilder.client()
        .with(PoolOptions().setMaxSize(connections))
        .connectingTo(options)
        .using(vertx)
        .build()
}

// Our SQL is written with `?` placeholders (see Queries.kt); the Postgres protocol numbers them ($1, $2, ...).
// Each statement text is converted once and then reused.
private val numberedStatements = ConcurrentHashMap<String, String>()

private fun numberPlaceholders(sql: String): String {
    val numbered = StringBuilder(sql.length + 16)
    var next = 1
    for (character in sql) {
        if (character == '?') {
            numbered.append('$').append(next++)
        } else {
            numbered.append(character)
        }
    }
    return numbered.toString()
}

/** Runs one statement; suspends (doesn't block) until Postgres answers. */
suspend fun SqlClient.execute(sql: String, arguments: Tuple): RowSet<Row> {
    return preparedQuery(numberedStatements.computeIfAbsent(sql, ::numberPlaceholders)).execute(arguments).coAwait()
}

/** A unique violation (SQLSTATE 23505) is the domain's "already taken"; anything else is rethrown. */
suspend fun <T> translateUniqueViolation(block: suspend () -> T): T {
    try {
        return block()
    } catch (exception: PgException) {
        if (exception.sqlState == "23505") throw ValidationException("username or email has already been taken")
        throw exception
    }
}

```
