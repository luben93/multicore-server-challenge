# Other top entries: c-iouring (84k), COBOL (84k), rust-mio (80k), go-epoll (61k), goose-epoll (62k)

Read-only research for the zero-dependency Kotlin (JVM + Kotlin/Native) submission. Paths are relative to
`/home/user/multicore-server-challenge/` unless absolute. "README:n" means that submission's `README.md`, line n.

## 0. How the SQL below was obtained (it is verbatim)

Every statement in this file is the exact text the server sends in its Parse message:

| Submission | How the text was produced | Full dump (scratchpad) |
|---|---|---|
| c-iouring-tigokraft | `src/api.c:8-128` copied into a scratch C file and compiled with gcc, macros expanded by the preprocessor, printed | `research/cdump/c_sql.txt` |
| cobol-gnucobol-benmandrew | `src/pd-sql.cpy` (the start-up STRING builder) transcribed into a Python emulator that reproduces each `STRING ... X"0A" ...` (newlines kept), `SQ-SWAP-4` ($4 -> $1) and the fact that `SQ-A1/SQ-A2` carry over between statements (s3 reuses s2's fragments; s5 inherits `SQ-A2-LEN = 0` from s4) | `research/cdump/cobol_sql.txt`, emulator `research/tools/cobol_sql.py` |
| rust-mio-foovoo | `src/sql.rs` compiled unchanged with rustc in scratch and `STATEMENTS` printed | `research/rdump/rust_sql.txt` |
| go-epoll-o7livetype | `src/sql.go` compiled unchanged with go in scratch and `stmts` printed | `research/godump/go_sql.txt` |
| goose-epoll-xeonfx | `sql.goose` transcribed into a Python emulator (`format`/`append` concatenation, `lateral()` = every `$` -> `r.p`) | `research/cdump/goose_sql.txt`, emulator `research/tools/goose_sql.py` |

(Scratchpad root: `/tmp/claude-0/-home-user-multicore-server-challenge/99796a5c-b120-524c-822d-dc73b94b523b/scratchpad/`.)
All five dumps are also appended at the end of this file (Appendix A-E).

Schema facts the tricks depend on (`schema.sql`): `favorites PRIMARY KEY (user_id, article_id)` (l.55) +
`favorites_article_idx ON favorites (article_id)` (l.57); `follows PRIMARY KEY (follower_id, followee_id)` (l.22);
`articles_author_idx ON articles (author_id, id DESC)` (l.37); `article_tags PRIMARY KEY (article_id, tag_id)` (l.47) +
`article_tags_tag_idx (tag_id, article_id)` (l.49); `comments_article_idx (article_id, created_at DESC, id DESC)` (l.67).

---

## 1. Side-by-side

| | c-iouring (84k) | COBOL (84k) | rust-mio (80k) | go-epoll (61k) | goose-epoll (62k) |
|---|---|---|---|---|---|
| Leaderboard p95/p99, CPU app/PG | 339/421 ms, 18%/80% | 361/461, 20%/75% | 474/752, 18%/75% | 351/484, 20%/73% | 30/842, 17%/71% |
| I/O model | io_uring, multishot accept + multishot POLLIN, `recv()` into per-loop scratch | 6 forked processes, epoll level-triggered | mio epoll edge-triggered | epoll (x/sys/unix), LT on listener | epoll edge-triggered |
| Event loops | `THREADS = ncpu/4` = **2** (server.c:715) | `WORKERS = nproc*3/4` = **6 processes** (start.sh:6-7) | `LOOPS = cpus/4` = **2** (main.rs:70-74) | `EPOLL_LOOPS = min(4, cores/4)` = **2** (reactor_linux.go:97) | `WORKERS` = **4** (main.goose:83) |
| PG connections | `4 x CPUs` = **32**, split over loops (server.c:716) | 6 x `PG_CONNS 2` = **12** (start.sh:8) | 2 x (1 heavy + 2 read + 1 write) = **8** (main.rs:76-79) | **22** = 20 read + 2 write (db.go:79-80) | 4 x (3 readers + 1 writer) = **16** (main.goose:84, server.goose:628) |
| Pipelining | Bind/Execute per stmt + 1 Sync per request; up to `PG_DEPTH 16` batches in flight per conn, rest in one FIFO per loop (pg.c:287-372) | reads queued between two writes share one Sync; a write gets its own Sync; flush held while `PG_MAX_SYNCS 2` Syncs unanswered (pd-pg.cpy:1-5, 284-300; pd-main.cpy:123-129) | reads: up to `READ_BATCH 8` requests per Sync; writes: one Sync in flight, the rest held and sent together up to `WRITE_BATCH 32` = group commit (README:66-76) | read batch <= 32 per Sync, write batch <= 128 per Sync, write linger 1 ms, `PIPELINE_DEPTH 4` (db.go:79-83, 100-101) | everything appended to a PG conn in one loop turn shares one Sync, `GROUP_MAX 64` (server.goose:1-4, 112); list reads batched into one `unnest(...)` statement |
| Formats | text params, text results (pg.c:319, 329) | text params (binary only for text[]), text results | binary params + results | binary params + results (db.go:477-478) | binary params + results (pg.goose:2, 55, 132) |
| Session settings | StartupMessage params: `plan_cache_mode=force_generic_plan,jit=off,max_parallel_workers_per_gather=0` + `DateStyle=ISO, MDY`, `TimeZone=UTC` (server.c:729-730, pg.c:220-233) | simple Query: `SET jit = off; SET plan_cache_mode = force_generic_plan; SET enable_memoize = off` (pd-main.cpy:134) | simple Query: `SET jit = off; SET max_parallel_workers_per_gather = 0; SET statement_timeout = 9000; SET lock_timeout = 5000; SET plan_cache_mode = force_generic_plan` (main.rs:102-112) | StartupMessage (pgx RuntimeParams): `statement_timeout=5000, lock_timeout=2000, idle_in_transaction_session_timeout=6000, TimeZone=UTC, plan_cache_mode=force_generic_plan, jit=off, max_parallel_workers_per_gather=0` (main.go:151-163) | StartupMessage: `jit off, plan_cache_mode force_generic_plan, max_parallel_workers_per_gather 0, statement_timeout 30s` (+ `lock_timeout 2s` on the writer) (server.goose:627-629) |
| bcrypt | 4-lane interleaved, `ncpu/2` threads, batch wait 150 ms | separate process, 3 threads, 4-lane lockstep, wait 500 ms, nice 10 | 4-lane, 2 threads, SCHED_BATCH + nice 10, pair wait 200 ms, queue 256 -> 503 | 4-lane pure Go, `cores/4` workers, wait 150 ms, stretch after 1 s | 5-lane, 2 hasher threads, gather 250 ms |
| Idle conn memory | ~200 B user memory; 80k conns = 17 MB RSS, 150k = 28 MB (README:25-27, 106-110) | 1 fixed record per fd (~60 B, `CN OCCURS 65536`, ws-loop.cpy:34) | ~100 B (README:52-54) | fd-indexed table + preallocated 24,576 request slots x 4 KB; 1.3 GB RSS at 135k (README:29) | slot in array, buffers only while busy; 130k conns ~60 MB (README:56-58) |

All five agree on: prepared once per connection, `force_generic_plan`, `jit = off`, one round trip per request,
page ids picked before per-row subqueries, tag names looked up by `tags_pkey`, `TCP_NODELAY` on every socket,
`SO_REUSEPORT` listener per loop, nothing shared between loops on the request path.

---

## 2. Cross-cutting SQL techniques (verbatim)

### 2.1 Tag names by primary key (all five)
The SPEC join `ARRAY(SELECT t.name FROM article_tags at JOIN tags t ...)` gets a generic plan that hashes all 200
tags per article (c-iouring README:54-56: "This alone is 1.33x on list throughput"; rust-mio README:82-85). Used by all:

```sql
ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = p.id ORDER BY 1)
```
Goose returns it already JSON-encoded (bytea, copied straight into the response; sql.goose:47):
```sql
convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8')
```

### 2.2 Pick the page's ids first, then decorate only those rows (all five)
SPEC's list computes tags / count / EXISTS for rows `OFFSET` discards. Four variants of "ids first":

- c-iouring (global list, api.c:62-67): **constant inner `LIMIT 100`, `LIMIT $2` outside**. A bare `LIMIT $2` makes the
  generic plan assume 10% of the table, which picks a Memoize node on the users join that memsets a huge hash table
  every execution (12% of a backend's CPU; README:63-69, +14.7% pgbench):
  ```sql
  FROM (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a ORDER BY a.id DESC OFFSET $3 LIMIT 100) a LIMIT $2
  ```
- goose (sql.goose:110-120) uses the same idea for every list: `SELECT id FROM (<ids> LIMIT 100 OFFSET $3) b ORDER BY id DESC LIMIT $2`
- go-epoll (sql.go:39-47): `WHERE a.id IN (SELECT * FROM (SELECT p.id FROM articles p ORDER BY p.id DESC LIMIT $2 OFFSET $3) page LIMIT 100)`
  ("Literal page caps make the API's <=100 bound visible to PostgreSQL's generic plan estimator", sql.go:54-55)
- rust-mio / c-iouring (filtered lists): `WHERE a.id IN (SELECT ... ORDER BY ... DESC LIMIT $2 OFFSET $3)`
- COBOL avoids the Memoize problem differently: `SET enable_memoize = off` for the session (pd-main.cpy:134).
  NB: c-iouring measured `enable_memoize = off` as **-55%** for *its* SQL ("the plan turns into a hash join of all
  users", README:83). COBOL's shapes differ (`WITH x AS MATERIALIZED (...)`), so do not combine blindly.

### 2.3 favorites_count + favorited
Two forms are in use, both on top-3 entries:

(a) **One scan of the article's favorites for both** (COBOL s1-s3, go all lists + article, goose global/tag lists):
```sql
CROSS JOIN LATERAL (SELECT count(*) AS fc, bool_or(f.user_id = $1) AS fav FROM favorites f WHERE f.article_id = x.id) fv
```
go-epoll (sql.go:25-26):
```sql
  CROSS JOIN LATERAL (SELECT count(*) AS n, COALESCE(bool_or(f.user_id=$1),false) AS favorited
                     FROM favorites f WHERE f.article_id=a.id) fav
```
goose (sql.goose:68): `LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = $1), false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true`

(b) **Separate count + PK probe** (c-iouring everywhere, rust-mio everywhere, COBOL favorited/feed/article):
```sql
(SELECT count(*) FROM favorites f WHERE f.article_id = p.id), EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = p.id AND f.user_id = $1)
```
Note (my inference from the schema): `favorites_article_idx` is on `(article_id)` only, so (a)'s `bool_or(f.user_id = $1)`
must read `user_id` from the heap for every favorite row (mean ~10, viral up to 2,000), while (b)'s count can be an
index-only scan and the EXISTS is a single `favorites_pkey` probe. c-iouring says the counts "mostly cost heap fetches,
because writes clear visibility-map bits on the hot articles' pages" (README:84-85), which narrows the difference.
c-iouring tried "whole-page set-based subqueries with `= ANY(ids)`" and dropped them (-9% to +7%, README:80-82).

(c) **Anonymous short-circuit** (goose only, sql.goose:49, 53): `($1 <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1))`
and `($1 <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id))`.

(d) **Viewer's set read once per statement** (goose favorited list, sql.goose:79-81; comments sql.goose:232):
```sql
a.id = ANY(ARRAY(SELECT vf.article_id FROM favorites vf WHERE vf.user_id = $1))
a.author_id = ANY(ARRAY(SELECT vo.followee_id FROM follows vo WHERE vo.follower_id = $1))
($1 <> 0 AND c.author_id IN (SELECT vo.followee_id FROM follows vo WHERE vo.follower_id = $1))
```

### 2.4 Capped `articlesCount` (min(1000, n)) folded into the same statement
Wrapper used by c-iouring / rust-mio / go / goose: count row LEFT JOIN LATERAL page, so an empty page still returns
one row with NULL page columns (c-iouring api.c:38-41):
```sql
SELECT cnt.n, p.slug, ... FROM (SELECT count(*) AS n FROM (<count source> LIMIT 1000) s) cnt LEFT JOIN LATERAL (<page>) p ON true LEFT JOIN users u ON u.id = p.author_id ORDER BY p.id DESC
```
rust-mio / goose: `WITH c AS (<n>) SELECT c.n, p.* FROM c LEFT JOIN LATERAL (...) p ON true ORDER BY p.id DESC`;
go: `WITH total AS (<count>) SELECT total.count,page.* FROM total LEFT JOIN LATERAL (...) page ON true ORDER BY page.id DESC`.

Count forms:
- plain (c-iouring all, go all, rust author/favorited/feed, goose author/favorited/feed):
  `SELECT count(*) AS n FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s`
- "1000th row exists" (rust-mio global + tag, goose global + tag, COBOL global + tag; sql.rs:56-66):
  ```sql
  SELECT CASE WHEN EXISTS (SELECT 1 FROM articles a ORDER BY a.id OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM articles a) END AS n
  ```
  c-iouring measured this as +3% on global/tag, -5% on author/favorited/feed (README:79-80) and kept the plain count.
- **COBOL: infer the total from the page, count only when it can't** (pd-sql.cpy:347-360). The page is
  `WITH x AS MATERIALIZED (<page>), n AS (SELECT count(*)::int AS n FROM x)` and:
  ```sql
         (CASE WHEN n.n > 0 AND n.n < $2 THEN least($3 + n.n, 1000)
               WHEN n.n = $2 AND $3 + $2 >= 1000 THEN 1000
               ELSE (<count query>) END)::bigint AS total
  ```
  i.e. a short non-empty page means total = offset + rows; a full page reaching offset 1000 means 1000; only otherwise is
  the count subquery evaluated. An empty page returns no rows at all, so COBOL then runs a second round trip with
  s6-s10 (count only; pd-app.cpy:875-892, `CN-COUNT-ST`). Unique to COBOL.

### 2.5 Feed
All: per-followee LATERAL with `LIMIT (limit+offset)`, then the global top-N, and `following` = constant `true`
(membership proves it in the same snapshot; go: -3% feed CPU, sql.go:117-128; rust: 2-4%, README:88-90).
c-iouring (api.c:83-86):
```sql
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3)
```
(note c-iouring keeps the EXISTS for `following` in the feed; rust/go/goose/COBOL use `true`). rust-mio/goose pass
limit+offset as a separate `$4` computed (saturated) in the app; go uses
`LIMIT (LEAST($2::bigint::numeric + $3::bigint::numeric, 9223372036854775807)::bigint)`. Feed count everywhere:
```sql
SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s
```
rust-mio: "The feed statement alone is ~40% of Postgres time" (README:103-104).

### 2.6 Comments: one statement, 404 vs empty thread distinguished (all five)
c-iouring (api.c:112-118): "No row: no such article. One row with a NULL id: an article without comments."
```sql
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) FROM articles a LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true LEFT JOIN users u ON u.id = c.author_id WHERE a.slug = $2 ORDER BY c.created_at DESC, c.id DESC
```
(c-iouring joins `users` and does the follows probe outside the LATERAL; rust/go/COBOL do it inside; goose reads the
viewer's followees once with `IN (SELECT ...)`. Check SPEC for the comment limit; all use `LIMIT 100`.)

### 2.7 Favorite / unfavorite: write + full article in ONE statement, snapshot-corrected count
A data-modifying CTE's effect is invisible to the rest of the same statement, so the count is corrected.
rust-mio (sql.rs:212-240) and go (sql.go:222-232) add the CTE's RETURNING row count:
```sql
WITH t AS (SELECT id FROM articles WHERE slug = $2), w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, t.id FROM t ON CONFLICT DO NOTHING RETURNING 1) SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT (SELECT tg.name FROM tags tg WHERE tg.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1), (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) + (SELECT count(*) FROM w), true, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM t JOIN articles a ON a.id = t.id JOIN users u ON u.id = a.author_id
```
```sql
WITH t AS (SELECT id FROM articles WHERE slug = $2), w AS (DELETE FROM favorites f USING t WHERE f.user_id = $1 AND f.article_id = t.id RETURNING 1) SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT (SELECT tg.name FROM tags tg WHERE tg.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1), (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) - (SELECT count(*) FROM w), false, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM t JOIN articles a ON a.id = t.id JOIN users u ON u.id = a.author_id
```
goose corrects from the snapshot instead (sql.goose:219-228): count `((SELECT count(*) FROM favorites f WHERE f.article_id = a.id) + (NOT EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1))::int)` / `- (EXISTS (...))::int`.
c-iouring and COBOL instead send two statements under one Sync (`S_FAVORITE` then `S_ARTICLE_BY_SLUG`; api.c:746-751,
pd-app.cpy:161-170): in one implicit READ COMMITTED transaction each statement takes a new snapshot, so the second
sees the first's insert.

### 2.8 Follow / unfollow, ownership-checked writes, comment create (one statement each)
```sql
WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, t.id FROM t ON CONFLICT DO NOTHING) SELECT t.username, t.bio, t.image FROM t
WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), w AS (DELETE FROM follows fo USING t WHERE fo.follower_id = $1 AND fo.followee_id = t.id) SELECT t.username, t.bio, t.image FROM t
```
(rust-mio s9/s10; COBOL s30/s31 and go/goose are equivalent; `following` in the response is the constant true/false).
Ownership in one statement, returns author_id so the app maps 404/403 (go sql.go:219-221, goose s18/s23, COBOL s24):
```sql
WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2))
SELECT author_id FROM t
```
rust-mio alternative: `DELETE FROM articles WHERE slug = $2 AND author_id = $1 RETURNING id`, and only on 0 rows a probe
`SELECT author_id FROM articles WHERE slug = $1` (sql.rs s16/s17; comments s14/s15). Update article in one statement:
see go `stArticleUpdate` / goose s17 / rust s18 / c-iouring `S_UPDATE_ARTICLE` in the appendices (UPDATE ... RETURNING
inside a CTE, then the full article columns computed from the RETURNING row; tags/favorites/follows are untouched by the
UPDATE so the snapshot is current for them).

### 2.9 Create article
- c-iouring / COBOL / rust-mio / goose: 3-4 statements under **one Sync** (one implicit transaction), tied by `currval`:
  ```sql
  INSERT INTO articles (id, slug, author_id, title, description, body) SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4 FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id
  INSERT INTO tags (name) SELECT DISTINCT n FROM unnest($1::text[]) AS n ORDER BY n ON CONFLICT (name) DO NOTHING
  INSERT INTO article_tags (article_id, tag_id) SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])
  SELECT ... FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')))
  ```
  rust-mio sorts tag inserts so concurrent creates can't deadlock (sql.rs:287-291) and notes `currval` must be wrapped in
  a scalar subquery or it disqualifies the PK index ("a 500k-row seq scan per create", sql.rs:298-300). goose only inserts
  missing tags: `INSERT INTO tags (name) SELECT x.name FROM (SELECT DISTINCT unnest($1::text[]) AS name) x WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = x.name) ORDER BY 1 ON CONFLICT (name) DO NOTHING`.
- go-epoll: **one statement** (sql.go:186-204), no currval, returns the new article itself (favoritesCount `0::bigint`,
  favorited `false`); `ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id, name` makes a tag committed by a
  concurrent transaction return its id:
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
- go also makes register safe for group commit: `INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
  ON CONFLICT DO NOTHING RETURNING id, username, email, bio, image` (no row = 422; a unique violation would abort every
  request sharing the Sync).

### 2.10 Tags
COBOL builds the whole response body in Postgres (s32):
```sql
SELECT '{"tags":' || coalesce(json_agg(name)::text, '[]') || '}' FROM (SELECT name FROM tags ORDER BY name) s
```
goose: `SELECT convert_to(array_to_json(array_agg(name ORDER BY name))::text, 'UTF8') FROM tags` ("array_to_json, since
json_agg puts a space after every comma"; NULL when no tags). rust/go: `SELECT ARRAY(SELECT name FROM tags ORDER BY name)`.
c-iouring: `SELECT name FROM tags ORDER BY name`. goose additionally lets all `GET /api/tags` waiting in one loop turn share
one execution (README:38, server.goose:351-358).

---

## 3. Per submission

### 3.1 c-iouring-tigokraft (84,000; C + liburing)
Distinctive:
- io_uring, `IORING_SETUP_SINGLE_ISSUER | DEFER_TASKRUN | COOP_TASKRUN | CQSIZE`, SQ 4096, CQ 32768 (server.c:572-582);
  multishot accept (server.c:557-560, 591); one multishot `POLLIN|POLLRDHUP` per connection then `recv()` into the loop's
  64 KiB scratch (`RBUF_SIZE 65536`, server.c:24, 521-534): an idle conn owns no buffer, ~200 B (README:23-28).
  Provided-buffer rings rejected by the Ubuntu 24.04 6.8 kernel (EINVAL; server.c:4-5).
- `listen(fd, 65535)`, `SO_REUSEADDR` + `SO_REUSEPORT` per loop (server.c:681-693); `TCP_NODELAY` on accept (server.c:547)
  and on PG sockets (pg.c:202). No setrlimit (relies on the unit's 200000), no idle timeout.
- One PG round trip per request; statements of a request = one batch (Bind/Execute each, one Sync); batches pipelined;
  **at most `PG_DEPTH 16` batches in flight per connection, the rest wait in one FIFO per loop** (pg.c:287-372): p95/p50
  28% -> 18%, same req/s; depth 2-4 starves backends (-4..-7%), 8-64 equivalent (README:162-167).
- `THREADS=ncpu/4` (2 on the box), `DB_CONNS=4*ncpu` (32): "24 connections beat 16 (idle CPU) and 48/90 (lower throughput,
  higher p99, bcrypt starved)" (README:73-75); 12-32 equal with the FIFO, 48+ worse p99 (README:178).
- Tried and dropped: **shared Sync for several read-only requests** ("saved no CPU in the full system and serialized reads
  on one backend, raising p99", README:85-87); `enable_memoize = off` (-55%); `OFFSET 999 LIMIT 1` count; `= ANY(ids)`
  set-based decoration; hash join for tag names (README:78-87).
- Startup message carries the session GUCs (pg.c:220-233): `user, database, client_encoding=UTF8, DateStyle=ISO, MDY,
  TimeZone=UTC, application_name` + `PG_SESSION` default `plan_cache_mode=force_generic_plan,jit=off,max_parallel_workers_per_gather=0`.
  Statements named `s<n>`, text params/results; timestamps reformatted from `2025-04-01 12:00:00.123456+00` (api.c:320).
- Measured: Postgres +server CPU-bound, "85% of its CPU in the executor" (README:77); the limit is CPU, "the hard cap is
  the unit's `LimitNOFILE=200000`" (README:115-118). Drift: capacity -8% in first 5 min on a fresh DB copy (README:156-161).
- Endpoint -> batch: follow = `S_FOLLOW`+`S_USER_BY_NAME`; favorite = `S_FAVORITE`+`S_ARTICLE_BY_SLUG`; update =
  `S_ARTICLE_AUTHOR`+`S_UPDATE_ARTICLE`; delete article = `S_ARTICLE_AUTHOR`+`S_DELETE_ARTICLE`; delete comment =
  `S_COMMENT_AUTHOR`+`S_DELETE_COMMENT`; create = INSERT_ARTICLE [+INSERT_TAGS +INSERT_ARTICLE_TAGS] + ARTICLE_LAST
  (api.c:593-823). Everything else is one statement.

### 3.2 cobol-gnucobol-benmandrew (84,000)
Distinctive:
- **Multi-process**: `WORKERS = nproc*3/4` (6) forked worker processes, each its own `SO_REUSEPORT` listener, epoll
  (level-triggered, `K-EV-IN = 1`), 2 PG connections (12 total!) (start.sh:6-8, pd-main.cpy:14-39, pd-loop.cpy:3-16).
  `listen` backlog **4096** (ws-main.cpy:22); `accept4` up to 64 per readiness event (pd-loop.cpy:77-102); per-process
  fd table `CN OCCURS 65536` and `MAX-FD 65536`: an fd >= 65536 is closed immediately (ws-main.cpy:2, ws-loop.cpy:34,
  pd-loop.cpy:83-85) - fine only because the connections are spread over 6 processes (~14k each at 84k users).
  epoll_wait batch 512 (`K-EV-MAX`), 1 MiB shared input buffer (ws-loop.cpy:57), 8 MiB PG read/write buffers (ws-pg.cpy:2-8).
- **Shared Sync for reads**: "Read-only requests queued on a connection between two writes share one Sync (a group) and
  are answered at their last CommandComplete; a request that writes takes its own Sync and is answered at its
  ReadyForQuery" (pd-pg.cpy:1-5, 187-191). Read-only = statement text has no word INSERT/UPDATE/DELETE (pd-sql.cpy:387-404).
  On error the rest of the group is re-sent each with its own Sync. `PG_MAX_SYNCS 2`: a connection's buffered requests
  are not flushed while 2 Syncs are unanswered (pd-pg.cpy:284-300) - natural batching under load.
- Session: simple Query `SET jit = off; SET plan_cache_mode = force_generic_plan; SET enable_memoize = off`, followed by
  Parse of all 32 statements and one Sync, in one write (pd-pgconn.cpy:137-154, pd-main.cpy:130-135).
- SQL: fv lateral for global/tag/author lists; the **page-size-inferred total** (section 2.4); MATERIALIZED page CTE;
  empty page -> second round trip for the count. Tag list JSON built by Postgres.
- bcrypt: separate forked process with 3 threads, 4-lane lockstep crypt_blowfish, waits up to 500 ms after the oldest
  queued password for the batch to fill (README:23-34; Poisson table README:27-32).
- Limit at score: not stated in README.

### 3.3 rust-mio-foovoo (80,000)
Distinctive:
- `LOOPS = cpus/4` (2), each with own `SO_REUSEPORT` listener (socket2, `listen(65_535)`, `set_tcp_nodelay`) (server.rs:171-181),
  mio edge-triggered; accept loop until WouldBlock; on EMFILE/ENFILE/ENOBUFS: pause accepting and retry on a 100 ms
  timer because an edge-triggered listener won't signal again (server.rs:339-385, 229-246). `raise_fd_limit()`: soft ->
  hard (main.rs:49-59). Reads into one 16 KiB buffer per loop (server.rs:34), conn keeps a buffer only while a request is
  incomplete; ~100 B per idle conn (README:52-54). Limits: 16 KiB headers (431), 256 KiB body (413). No idle timeouts
  (README:137-138).
- **Only 8 PG backends** (2 loops x (1 heavy + 2 read + 1 write)): "with 16 backends on 4 cores each statement took twice
  as long and a request cost ~19% more CPU, ceiling 72k -> 68k" (README:30-34, 106-108).
- **Least-work routing**: each statement has a cost weight `COST_US` (feed 440, list 185-235, article 76, comments 85,
  profile 14, ...; sql.rs:336-364); reads go to the read conn with the least queued estimated work (README:35-38).
- Shared Syncs for reads (up to `READ_BATCH 8`, avg 2.6 per Sync) and **group commit** for writes (one Sync in flight;
  writes that arrive meanwhile go together, up to `WRITE_BATCH 32`; `synchronous_commit` stays on). No explicit BEGIN.
  Sign-ups, user updates and creates with tags never share a Sync; deadlock/serialization retried once (README:66-76;
  pg.rs:155-169, 291-305, 341-360).
- Binary params/results; timestamps from binary microseconds; JWT header fast path (README:91-94).
- bcrypt threads `SCHED_BATCH` + nice 10 (pool.rs:183-192).
- Limit: "Postgres is the real bottleneck" (README:46); at 76-80k: PG ~70%, process ~22% (bcrypt ~9%), softirq ~6%,
  idle ~6% (README:101-104).
- Tried and dropped: batching concurrent point reads into one `unnest` statement ("same capacity ... serializes many
  requests on one backend", README:95-97).

### 3.4 go-epoll-o7livetype (61,000)
Distinctive:
- Own epoll reactor, `EPOLL_LOOPS=min(4, cores/4)` (2); listener per loop with SO_REUSEPORT, `listen(fd, 65535)`
  (reactor_linux.go:97, 340-375); accept up to 256 per event; EMFILE/ENFILE -> pause listener 1 s
  (reactor_linux.go:615-668). Per accepted fd: `TCP_NODELAY`, `SO_KEEPALIVE`, `TCP_KEEPIDLE 60`, `TCP_KEEPINTVL 30`,
  `TCP_KEEPCNT 3` (646-650 - 5 syscalls/accept). **Idle timeout 75 s** (> the 70 s think-time cap), read/write timeouts
  15 s (reactor_linux.go:84-90). Table indexed by fd, sized `min(nofile, sockets+reserve)` (main.go:113-122).
  Request slots preallocated: `MAX_INFLIGHT 4096 + MAX_QUEUED 20480`, 4 KB inline each; when all are busy the conn is
  *parked* (request left in the kernel socket buffer) -> overload = latency, not 503 (reactor_linux.go:32-41, 671-677).
  GC: `SetMemoryLimit(3 GiB)`, `GOGC=400` (main.go:128-134).
- DB: 22 connections (20 read, 2 write), one goroutine each, `PIPELINE_DEPTH 4`; read batch <= 32 requests per Sync;
  **write group commit** <= 128 per Sync with 1 ms linger, flush interval 200 ms (db.go:1-33, 79-101, 381-418). A failing
  statement: whole batch re-sent one request per Sync.
- "22 connections ... 95 raised p99 17x" (README:39). One prepared statement per endpoint (CTEs) - see Appendix D.
- Limit: leaderboard 61k at p95 351 / p99 484 with CPU 20%/73% (CPU-bound). README: "The 135k epoll result did not repeat:
  old/new builds both missed latency with zero errors" (README:31) - local 8-core screens overstated the official box ~2x.

### 3.5 goose-epoll-xeonfx (62,000)
Distinctive:
- 4 loops (`WORKERS`), each with SO_REUSEPORT listener (`listen(fd, 65535)`, sys.goose:99-107), epoll; clients registered
  `EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET` once (no epoll_ctl MOD per response; server.goose:142-155); accept loop until
  EAGAIN, `TCP_NODELAY`. `raise_nofile()` soft -> hard (sys.goose:130-135, main.goose:89). 64 KiB receive scratch per loop
  (server.goose:113, 618). epoll_wait batch 256. ~60 MB at 130k conns (README:56-58).
- 3 readers + 1 writer per loop = 16 PG conns. One Sync per PG connection per loop turn, up to 64 requests (`GROUP_MAX`),
  so a turn's writes commit together (server.goose:1-4, 481-492). Reads to least-busy reader.
- **Batched list reads** (idea credited to rust-tokio-Scooter1337): list/tags reads wait in a pool while a batched
  execution from this loop is in flight (`READ_HOLD 1`); at flush, each list kind goes out as one statement with the
  members' params as arrays through `unnest(...) WITH ORDINALITY` + LATERAL; when at most half the members ask for a
  unique page, the "share" variant reads each distinct article once (server.goose:320-372; README:33-39). Statements
  s25-s32 in Appendix E. Measured on GCP c4-highcpu-8: 34k -> 41k req/s at PG saturation, 130k -> 160k users (README:66-87).
- Anonymous viewer short-circuits (`$1 <> 0 AND ...`).
- Limit at score: official 62k with **p95 30 ms but p99 842 ms** and CPU 17%/71% - tail-limited, not CPU-saturated; the
  README's 120k-160k GCP results did not carry over. The repo gives no cause. (goose-native-tbsvttr, the other Goose entry,
  shows the same shape: 65k, p95 27 / p99 721.)

---

## 4. OS / kernel limits at 50k-120k connections

### 4.1 What the benchmark box sets (verbatim)
`box/sysctl.conf` (installed on the box AND the load generators, bench/README.md:73-75):
```
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 2097152
fs.nr_open = 1048576
```
`box/setup-box.sh:66-73`: `net.netfilter.nf_conntrack_max = 1048576` (if conntrack is loaded);
`DefaultLimitNOFILE=200000:1048576` for systemd; limits.d `* soft nofile 200000`, `* hard nofile 1048576`.
`box/challenge.service:26`: **`LimitNOFILE=200000`** (systemd sets soft = hard = 200000 for the server),
`User=challenge`, `AmbientCapabilities=CAP_NET_BIND_SERVICE`, `Restart=no`, no CPU/memory limits.
SPEC.md:26: "expect tens of thousands of open connections. Your service gets `LimitNOFILE=200000`".
Not set anywhere in the repo: `vm.max_map_count` (kernel default 65530), `net.core.netdev_max_backlog`, `tcp_mem`,
`fs.epoll.max_user_watches`. No README or code in the repo mentions `vm.max_map_count` at all.

### 4.2 File descriptors
- On the box: 200000 per server process (soft = hard). Every entry treats this as the hard cap: c-iouring "the hard cap
  is the unit's `LimitNOFILE=200000`" (README:117-118); rust-mio and goose still raise soft -> hard at start
  (main.rs:49-59, sys.goose:130-135) for non-systemd runs; Go's runtime does it implicitly and go-epoll sizes its
  socket cap as `nofile - (db conns + 256)` (main.go:113-122).
- EMFILE handling matters with edge-triggered listeners: rust-mio pauses and retries accept on a 100 ms timer
  (server.rs:379-382), go-epoll disables the listener for 1 s (reactor_linux.go:634-638), elixir-raw-foovoo backs off
  (`lib/conduit/http.ex:63`), rust-urus-markk116 "answers EMFILE by backing off" (`src/main.rs:98`). COBOL's per-process
  table is fixed at 65,536 fds and closes anything above (pd-loop.cpy:83-85).
- Runtime-internal caps: elixir-raw-foovoo needed `+P 2000000 +Q 1000000` "because the default port limit (65536) would
  cap connections" (its README:64-67) - the classic ~64k ceiling coming from a runtime default, not the kernel.
- **This sandbox (local lab), checked now**: `ulimit -n` soft = hard = **20000** (`/proc/self/limits`), and root cannot raise
  it (`ulimit -n 200000` -> "Operation not permitted"; CapEff `000001fffeffffff` lacks CAP_SYS_RESOURCE). So locally a
  single server process and a single loadgen process each hold < 20,000 sockets. Local tests above ~19k users need
  several loadgen processes AND either a multi-process server or `-think-scale` (testing only; c-iouring used x0.1 to
  emulate 10x users, README:101-110). Local `tcp_max_syn_backlog = 1024` (box: 65535), `somaxconn = 65535`,
  `ip_local_port_range = 1024 65535`, `nf_conntrack_max = 262144` (module loaded), `vm.max_map_count = 262144`,
  4 vCPU / 15 GB.

### 4.3 64k ephemeral ports per load box per target address
- Each virtual user = one keep-alive TCP connection for the whole run (bench/cmd/loadgen/client.go:18-21, vu.go:137);
  with `ip_local_port_range 1024 65535` a load box has 64,512 source ports per destination ip:port. loadgen accepts
  several comma-separated target URLs (same server, more IPs) and VU g dials `addrs[g mod len]` "(several IPs of one
  target: >64k users per load box)" (run.go:275-295, client.go:32, vu.go:93). The scorer adds load boxes; an LG-limited run
  is never counted (WORKLOAD.md:71-72).
- goose: "every process aimed at its own target address so none opens more than 64k connections to one address"
  (README:67-68); rust-urus: "loadgen split over six loopback addresses to get past the ephemeral-port range" (its README:131).
- Stock kernel default `ip_local_port_range` is `32768 60999` (28,232 ports) - a local lab without `box/sysctl.conf`
  caps a single loadgen->target pair at ~28k connections (general Linux knowledge, not in the repo). The server binding
  `0.0.0.0` lets local tests target 127.0.0.1, 127.0.0.2, ... (all of 127/8 is loopback on Linux).
- bench/README.md:157-158: macOS has ~16k ephemeral ports and TIME_WAIT lingers; "wait ~30 s between big runs".

### 4.4 Listen backlog, SYN backlog and the 60 s ramp
- Backlogs: c-iouring 65535, rust-mio 65535, go 65535, goose 65535, COBOL 4096 (x6 listeners). The kernel caps at
  `somaxconn` (65535 on the box). With SO_REUSEPORT each loop has its own accept queue.
- Ramp: users arrive over 60 s (search: 60 s ramp + 60 s probe, 60 s ramp + 300 s hold; bench/README.md:105-110), i.e.
  120k users = ~2,000 connects/s, plus the first request of each. Logins during the ramp are kept at the steady rate
  (users arrive mid-session; WORKLOAD.md:26-29) - the pilot's 15x login storm "failed probes the steady state passed".
  None of the five READMEs reports an accept-storm problem; all drain accept in a loop (64 / 256 / until EAGAIN per event).
- Probe ladder (search.go:86-88, 369-395): start 500, doubling: 500, 1k, 2k, 4k, 8k, 16k, 32k, **64k**, then 120k (the
  `-max 120000` cap), then bisect to 5%. An entry that fails the 64k probe is bisected inside 32k-64k (consistent with
  go-epoll 61k and goose 62k); one that passes 64k is bisected inside 64k-120k. 120k is the highest score possible.

### 4.5 Memory per idle connection (as reported)
c-iouring ~200 B user space, 80k conns -> 16-17 MB RSS, ~149k -> 28 MB (README:25-27, 106-110). rust-mio ~100 B (README:52-54).
goose ~60 MB at 130k (README:56-58). go-epoll 1.3 GB RSS at 135k (preallocated slots; README:29). rust-tokio-Scooter1337
83-124 MiB peak at 76-80k (its README:26-32). kotlin-vertx-canleon: "40,000 of them added about 190 MB" (~4.7 KB/conn,
its README:54) with `-Xms2g -Xmx2g -XX:+AlwaysPreTouch`. rust-urus-markk116: 1.9 GB RSS at 100k (its README:131-135).
Kernel memory per socket is not measured in any README.

### 4.6 TIME_WAIT, idle timeouts, keepalive
- Connections are never closed by the load generator during a run; if the server closes an idle connection, the client
  retries the request once on a fresh connection (client.go:51-55, 85-91). Think time is capped at 70 s (WORKLOAD.md:24),
  so an idle timeout must exceed 70 s (go-epoll uses 75 s); c-iouring, rust-mio, goose have none.
- Server-initiated closes would leave the server's sockets in TIME_WAIT; nobody closes, so no README reports TIME_WAIT
  on the box. `tcp_tw_reuse = 1` only affects outgoing connects (load boxes).
- loadgen disables TCP keepalive probes (`net.Dialer{KeepAlive: -1}`, client.go:49); only go-epoll enables keepalive
  server-side.

### 4.7 vm.max_map_count, conntrack (not in any README; risks for a JVM / Kotlin/Native server)
- `vm.max_map_count` default 65530 is not raised by setup-box.sh. It caps the number of memory mappings per process:
  every thread stack (+guard), every glibc malloc allocation above the mmap threshold (128 KiB by default), every
  direct buffer allocated that large. A design that gives each connection its own >=128 KiB buffer, or a thread per
  connection, hits ENOMEM / "map failed" near ~65k connections. All five entries avoid per-connection buffers (shared
  per-loop scratch). This is my inference; nothing in the repo measured it.
- conntrack: the box raises `nf_conntrack_max` to 1048576 (setup-box.sh:66-68). If conntrack is loaded with a small
  table, new SYNs are dropped once it is full; locally it is 262144.

### 4.8 What limited each at its score
| Entry | Score | Stated / evident limit |
|---|---|---|
| c-iouring | 84k | CPU: Postgres saturated (80% of box); "the limit is CPU, not the connection count; the hard cap is the unit's LimitNOFILE=200000" (README:115-118) |
| COBOL | 84k | not stated; leaderboard p95 361 / p99 461 with 20%/75% CPU -> CPU |
| rust-mio | 80k | "Postgres is the real bottleneck" (README:46, 99-108); leaderboard p95 474 |
| go-epoll | 61k | CPU (p95 351, 20%/73%); local 135k "did not repeat" (README:31) |
| goose-epoll | 62k | p99 tail (842 ms) at p95 30 ms, CPU 88% total; cause not stated |

---

## 5. Actionable for the Kotlin submission
1. Port the c-iouring / rust-mio SQL (Appendix A / C) as the base: tags by PK, ids-first pages with a constant inner
   `LIMIT 100`, capped count in the same statement via `LEFT JOIN LATERAL`, `following = true` in the feed, favorite
   and follow toggles as one CTE statement with the snapshot-corrected count, comments with `LEFT JOIN LATERAL` from
   articles. A/B the fv-lateral favorites form vs count+EXISTS on our box rather than trusting either.
2. Session settings in the StartupMessage (no extra round trip): `plan_cache_mode=force_generic_plan`, `jit=off`,
   `max_parallel_workers_per_gather=0`, `TimeZone=UTC` (+ `DateStyle=ISO, MDY` if parsing text timestamps).
   Do not add `enable_memoize=off` unless the SQL is COBOL's.
3. Few PG connections (8-32), pipeline depth capped (~16) with a per-loop FIFO; consider shared Sync for reads (COBOL,
   rust, go, goose use it; c-iouring measured no gain) and group commit for writes (rust/go); never let a unique-violation-
   prone statement (register, user update, create with tags) share a Sync.
4. 2 event loops on 8 vCPU, each with its own SO_REUSEPORT listener, `listen(65535)`, TCP_NODELAY, accept until EAGAIN,
   EMFILE -> pause + timer retry. No per-connection buffers while idle; no thread or >=128 KiB allocation per connection
   (vm.max_map_count 65530). No idle timeout, or > 75 s.
5. Raise RLIMIT_NOFILE soft -> hard at startup in the Kotlin/Native build (JVM does it by default via -XX:+MaxFDLimit).
   Locally the hard cap is 20,000 per process and cannot be raised: load-test with several loadgen processes and
   multiple 127.0.0.x targets, and use `-think-scale` (testing only) for user counts above ~19k.
6. bcrypt off the loops, multi-lane (4-5 lanes) with a 150-500 ms batch-fill wait, low priority (nice 10 / SCHED_BATCH).

---

## Appendix A. c-iouring-tigokraft: every statement (src/api.c:44-128, macros expanded; prepared as s<index>)

```sql
-- S_TAGS (0 params)
SELECT name FROM tags ORDER BY name;

-- S_USER_BY_ID (1 params)
SELECT username, email, bio, image FROM users WHERE id = $1;

-- S_LOGIN (1 params)
SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1;

-- S_REGISTER (3 params)
INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image;

-- S_UPDATE_USER (6 params)
UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) WHERE id = $1 RETURNING id, username, email, bio, image;

-- S_PROFILE (2 params)
SELECT u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) FROM users u WHERE u.username = $2;

-- S_FOLLOW (2 params)
INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM users u WHERE u.username = $2 ON CONFLICT DO NOTHING;

-- S_UNFOLLOW (2 params)
DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT u.id FROM users u WHERE u.username = $2);

-- S_USER_BY_NAME (1 params)
SELECT username, bio, image FROM users WHERE username = $1;

-- S_LIST_ALL (3 params)
SELECT cnt.n, p.slug, p.title, p.description, p.created_at, p.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = p.id ORDER BY 1), (SELECT count(*) FROM favorites f WHERE f.article_id = p.id), EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = p.id AND f.user_id = $1), u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = p.author_id) FROM (SELECT count(*) AS n FROM (SELECT 1 FROM articles a LIMIT 1000) s) cnt LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a ORDER BY a.id DESC OFFSET $3 LIMIT 100) a LIMIT $2) p ON true LEFT JOIN users u ON u.id = p.author_id ORDER BY p.id DESC;

-- S_LIST_TAG (4 params)
SELECT cnt.n, p.slug, p.title, p.description, p.created_at, p.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = p.id ORDER BY 1), (SELECT count(*) FROM favorites f WHERE f.article_id = p.id), EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = p.id AND f.user_id = $1), u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = p.author_id) FROM (SELECT count(*) AS n FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s) cnt LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3)) p ON true LEFT JOIN users u ON u.id = p.author_id ORDER BY p.id DESC;

-- S_LIST_AUTHOR (4 params)
SELECT cnt.n, p.slug, p.title, p.description, p.created_at, p.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = p.id ORDER BY 1), (SELECT count(*) FROM favorites f WHERE f.article_id = p.id), EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = p.id AND f.user_id = $1), u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = p.author_id) FROM (SELECT count(*) AS n FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s) cnt LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3) p ON true LEFT JOIN users u ON u.id = p.author_id ORDER BY p.id DESC;

-- S_LIST_FAV (4 params)
SELECT cnt.n, p.slug, p.title, p.description, p.created_at, p.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = p.id ORDER BY 1), (SELECT count(*) FROM favorites f WHERE f.article_id = p.id), EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = p.id AND f.user_id = $1), u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = p.author_id) FROM (SELECT count(*) AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s) cnt LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3)) p ON true LEFT JOIN users u ON u.id = p.author_id ORDER BY p.id DESC;

-- S_FEED (3 params)
SELECT cnt.n, p.slug, p.title, p.description, p.created_at, p.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = p.id ORDER BY 1), (SELECT count(*) FROM favorites f WHERE f.article_id = p.id), EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = p.id AND f.user_id = $1), u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = p.author_id) FROM (SELECT count(*) AS n FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s) cnt LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3)) p ON true LEFT JOIN users u ON u.id = p.author_id ORDER BY p.id DESC;

-- S_ARTICLE_BY_SLUG (2 params)
SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1), (SELECT count(*) FROM favorites f WHERE f.article_id = a.id), EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1), u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2;

-- S_ARTICLE_LAST (1 params)
SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1), (SELECT count(*) FROM favorites f WHERE f.article_id = a.id), EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1), u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')));

-- S_INSERT_ARTICLE (4 params)
INSERT INTO articles (id, slug, author_id, title, description, body) SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4 FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id;

-- S_INSERT_TAGS (1 params)
INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING;

-- S_INSERT_ARTICLE_TAGS (1 params)
INSERT INTO article_tags (article_id, tag_id) SELECT (SELECT currval(pg_get_serial_sequence('articles', 'id'))), t.id FROM tags t WHERE t.name = ANY($1::text[]);

-- S_ARTICLE_AUTHOR (1 params)
SELECT author_id FROM articles WHERE slug = $1;

-- S_UPDATE_ARTICLE (5 params)
WITH upd AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), body = COALESCE($5, body), slug = CASE WHEN $3::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($3, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END, updated_at = now() WHERE slug = $2 AND author_id = $1 RETURNING id, slug, title, description, body, created_at, updated_at, author_id) SELECT upd.slug, upd.title, upd.description, upd.body, upd.created_at, upd.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = upd.id ORDER BY 1), (SELECT count(*) FROM favorites f WHERE f.article_id = upd.id), EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = upd.id AND f.user_id = $1), u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = upd.author_id) FROM upd JOIN users u ON u.id = upd.author_id;

-- S_DELETE_ARTICLE (2 params)
DELETE FROM articles WHERE slug = $1 AND author_id = $2;

-- S_FAVORITE (2 params)
INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 ON CONFLICT DO NOTHING;

-- S_UNFAVORITE (2 params)
DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2);

-- S_COMMENTS (2 params)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) FROM articles a LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true LEFT JOIN users u ON u.id = c.author_id WHERE a.slug = $2 ORDER BY c.created_at DESC, c.id DESC;

-- S_CREATE_COMMENT (3 params)
WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $1, $3 FROM articles a WHERE a.slug = $2 RETURNING id, body, created_at, updated_at, author_id) SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id;

-- S_COMMENT_AUTHOR (2 params)
SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2;

-- S_DELETE_COMMENT (3 params)
DELETE FROM comments c USING articles a WHERE c.id = $1 AND a.id = c.article_id AND a.slug = $2 AND c.author_id = $3;

```

## Appendix B. cobol-gnucobol-benmandrew: every statement (src/pd-sql.cpy, reconstructed; newlines are the X"0A" in the source; prepared as s1..s32)

```sql
-- s1 list_all
SELECT x.id, x.slug, x.title, x.description, x.created_at, x.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
               FROM article_tags at WHERE at.article_id = x.id ORDER BY 1) AS tag_list,
       fv.fc AS favorites_count, coalesce(fv.fav, false) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = x.author_id) AS following,
       (SELECT CASE WHEN EXISTS (SELECT 1 FROM articles a ORDER BY a.id OFFSET 999) THEN 1000
                    ELSE (SELECT count(*) FROM articles a) END) AS total
  FROM (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a ORDER BY a.id DESC LIMIT $2 OFFSET $3) x
  JOIN users u ON u.id = x.author_id
  CROSS JOIN LATERAL (SELECT count(*) AS fc, bool_or(f.user_id = $1) AS fav FROM favorites f WHERE f.article_id = x.id) fv
 ORDER BY x.id DESC;

-- s2 list_tag
WITH x AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) p JOIN articles a ON a.id = p.article_id), n AS (SELECT count(*)::int AS n FROM x)
SELECT x.id, x.slug, x.title, x.description, x.created_at, x.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
               FROM article_tags at WHERE at.article_id = x.id ORDER BY 1) AS tag_list,
       fv.fc AS favorites_count, coalesce(fv.fav, false) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = x.author_id) AS following,
       (CASE WHEN n.n > 0 AND n.n < $2 THEN least($3 + n.n, 1000)
             WHEN n.n = $2 AND $3 + $2 >= 1000 THEN 1000
             ELSE (SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) OFFSET 999) THEN 1000 ELSE (SELECT count(*) FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)) END) END)::bigint AS total
  FROM x JOIN users u ON u.id = x.author_id CROSS JOIN n
  CROSS JOIN LATERAL (SELECT count(*) AS fc, bool_or(f.user_id = $1) AS fav FROM favorites f WHERE f.article_id = x.id) fv
 ORDER BY x.id DESC;

-- s3 list_author
WITH x AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3), n AS (SELECT count(*)::int AS n FROM x)
SELECT x.id, x.slug, x.title, x.description, x.created_at, x.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
               FROM article_tags at WHERE at.article_id = x.id ORDER BY 1) AS tag_list,
       fv.fc AS favorites_count, coalesce(fv.fav, false) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = x.author_id) AS following,
       (CASE WHEN n.n > 0 AND n.n < $2 THEN least($3 + n.n, 1000)
             WHEN n.n = $2 AND $3 + $2 >= 1000 THEN 1000
             ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s) END)::bigint AS total
  FROM x JOIN users u ON u.id = x.author_id CROSS JOIN n
  CROSS JOIN LATERAL (SELECT count(*) AS fc, bool_or(f.user_id = $1) AS fav FROM favorites f WHERE f.article_id = x.id) fv
 ORDER BY x.id DESC;

-- s4 list_favorited
WITH x AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) p JOIN articles a ON a.id = p.article_id), n AS (SELECT count(*)::int AS n FROM x)
SELECT x.id, x.slug, x.title, x.description, x.created_at, x.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
               FROM article_tags at WHERE at.article_id = x.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = x.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = x.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = x.author_id) AS following,
       (CASE WHEN n.n > 0 AND n.n < $2 THEN least($3 + n.n, 1000)
             WHEN n.n = $2 AND $3 + $2 >= 1000 THEN 1000
             ELSE (SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s) END)::bigint AS total
  FROM x JOIN users u ON u.id = x.author_id CROSS JOIN n
 ORDER BY x.id DESC;

-- s5 list_feed
WITH x AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) p JOIN articles a ON a.id = p.id), n AS (SELECT count(*)::int AS n FROM x)
SELECT x.id, x.slug, x.title, x.description, x.created_at, x.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
               FROM article_tags at WHERE at.article_id = x.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = x.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = x.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       true AS following,
       (CASE WHEN n.n > 0 AND n.n < $2 THEN least($3 + n.n, 1000)
             WHEN n.n = $2 AND $3 + $2 >= 1000 THEN 1000
             ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s) END)::bigint AS total
  FROM x JOIN users u ON u.id = x.author_id CROSS JOIN n
 ORDER BY x.id DESC;

-- s6 count_all
SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s;

-- s7 count_tag (filter $1)
SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) OFFSET 999) THEN 1000 ELSE (SELECT count(*) FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1)) END;

-- s8 count_author (filter $1)
SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s;

-- s9 count_favorited (filter $1)
SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s;

-- s10 count_feed
SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s;

-- s11 article_by_slug
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
               FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id WHERE a.slug = $2;

-- s12 article_by_id
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
               FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id WHERE a.id = $2;

-- s13 article_just_created
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
               FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')));

-- s14 insert_article
INSERT INTO articles (id, slug, author_id, title, description, body)
SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4
  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
RETURNING id;

-- s15 insert_tags
INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING;

-- s16 insert_article_tags
INSERT INTO article_tags (article_id, tag_id) SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[]);

-- s17 article_owner
SELECT id, author_id FROM articles WHERE slug = $1;

-- s18 update_article
UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
       updated_at = now()
 WHERE id = $1;

-- s19 delete_article
DELETE FROM articles WHERE id = $1;

-- s20 favorite
INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 ON CONFLICT DO NOTHING;

-- s21 unfavorite
DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2);

-- s22 comments
SELECT a.id AS article_id, c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image, c.following
  FROM articles a
  LEFT JOIN LATERAL (
       SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
              EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
         FROM comments c JOIN users u ON u.id = c.author_id
        WHERE c.article_id = a.id
        ORDER BY c.created_at DESC, c.id DESC
        LIMIT 100) c ON true
 WHERE a.slug = $2;

-- s23 insert_comment
WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $2, $3 FROM articles a WHERE a.slug = $1
           RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
  FROM c JOIN users u ON u.id = c.author_id;

-- s24 delete_comment
WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2),
     d AS (DELETE FROM comments c USING t WHERE c.id = t.id AND t.author_id = $3)
SELECT author_id FROM t;

-- s25 insert_user
INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image;

-- s26 user_by_email
SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1;

-- s27 user_by_id
SELECT id, username, email, bio, image FROM users WHERE id = $1;

-- s28 update_user
UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
 WHERE id = $1
RETURNING id, username, email, bio, image;

-- s29 profile
SELECT u.id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
  FROM users u WHERE u.username = $2;

-- s30 follow
WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
     ins AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM u ON CONFLICT DO NOTHING)
SELECT username, bio, image FROM u;

-- s31 unfollow
WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
     del AS (DELETE FROM follows fo USING u WHERE fo.follower_id = $1 AND fo.followee_id = u.id)
SELECT username, bio, image FROM u;

-- s32 tags
SELECT '{"tags":' || coalesce(json_agg(name)::text, '[]') || '}' FROM (SELECT name FROM tags ORDER BY name) s;

```

## Appendix C. rust-mio-foovoo: every statement (src/sql.rs, compiled; prepared as s0..s26; params are OIDs 20=int8 25=text 1009=text[])

```sql
-- s0 LIST_ALL params=[20, 20, 20]
WITH c AS (SELECT CASE WHEN EXISTS (SELECT 1 FROM articles a ORDER BY a.id OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM articles a) END AS n) SELECT c.n, p.* FROM c LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id IN (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC) p ON true ORDER BY p.id DESC;

-- s1 LIST_TAG params=[20, 20, 20, 25]
WITH c AS (SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)) END AS n) SELECT c.n, p.* FROM c LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC) p ON true ORDER BY p.id DESC;

-- s2 LIST_AUTHOR params=[20, 20, 20, 25]
WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s) SELECT c.n, p.* FROM c LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id IN (SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a2.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC) p ON true ORDER BY p.id DESC;

-- s3 LIST_FAVORITED params=[20, 20, 20, 25]
WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s) SELECT c.n, p.* FROM c LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC) p ON true ORDER BY p.id DESC;

-- s4 FEED params=[20, 20, 20, 20]
WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s) SELECT c.n, p.* FROM c LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, u.username, u.bio, u.image, true AS following FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT $4) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC) p ON true ORDER BY p.id DESC;

-- s5 ARTICLE_BY_SLUG params=[20, 25]
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2;

-- s6 COMMENTS params=[20, 25]
SELECT a.id, x.id, x.body, x.created_at, x.updated_at, x.username, x.bio, x.image, x.following FROM articles a LEFT JOIN LATERAL ( SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) x ON true WHERE a.slug = $2 ORDER BY x.created_at DESC, x.id DESC;

-- s7 TAGS params=[]
SELECT ARRAY(SELECT name FROM tags ORDER BY name);

-- s8 PROFILE params=[20, 25]
SELECT u.id, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following FROM users u WHERE u.username = $2;

-- s9 FOLLOW params=[20, 25]
WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, t.id FROM t ON CONFLICT DO NOTHING) SELECT t.username, t.bio, t.image FROM t;

-- s10 UNFOLLOW params=[20, 25]
WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), w AS (DELETE FROM follows fo USING t WHERE fo.follower_id = $1 AND fo.followee_id = t.id) SELECT t.username, t.bio, t.image FROM t;

-- s11 FAVORITE params=[20, 25]
WITH t AS (SELECT id FROM articles WHERE slug = $2), w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, t.id FROM t ON CONFLICT DO NOTHING RETURNING 1) SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT (SELECT tg.name FROM tags tg WHERE tg.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1), (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) + (SELECT count(*) FROM w), true, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM t JOIN articles a ON a.id = t.id JOIN users u ON u.id = a.author_id;

-- s12 UNFAVORITE params=[20, 25]
WITH t AS (SELECT id FROM articles WHERE slug = $2), w AS (DELETE FROM favorites f USING t WHERE f.user_id = $1 AND f.article_id = t.id RETURNING 1) SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT (SELECT tg.name FROM tags tg WHERE tg.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1), (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) - (SELECT count(*) FROM w), false, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM t JOIN articles a ON a.id = t.id JOIN users u ON u.id = a.author_id;

-- s13 COMMENT_CREATE params=[20, 25, 25]
WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $1, $3 FROM articles a WHERE a.slug = $2 RETURNING id, body, created_at, updated_at, author_id) SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id;

-- s14 COMMENT_DELETE params=[20, 20, 25]
DELETE FROM comments c USING articles a WHERE c.id = $2 AND a.id = c.article_id AND a.slug = $3 AND c.author_id = $1 RETURNING c.id;

-- s15 COMMENT_PROBE params=[20, 25]
SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2;

-- s16 ARTICLE_DELETE params=[20, 25]
DELETE FROM articles WHERE slug = $2 AND author_id = $1 RETURNING id;

-- s17 ARTICLE_PROBE params=[25]
SELECT author_id FROM articles WHERE slug = $1;

-- s18 ARTICLE_UPDATE params=[20, 25, 25, 25, 25]
WITH a AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), body = COALESCE($5, body), slug = CASE WHEN $3::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($3, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END, updated_at = now() WHERE slug = $2 AND author_id = $1 RETURNING id, slug, title, description, body, created_at, updated_at, author_id) SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following FROM a JOIN users u ON u.id = a.author_id;

-- s19 ARTICLE_INSERT params=[20, 25, 25, 25]
INSERT INTO articles (id, slug, author_id, title, description, body) SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4 FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id;

-- s20 TAGS_INSERT params=[1009]
INSERT INTO tags (name) SELECT DISTINCT n FROM unnest($1::text[]) AS n ORDER BY n ON CONFLICT (name) DO NOTHING;

-- s21 ARTICLE_TAGS_INSERT params=[1009]
INSERT INTO article_tags (article_id, tag_id) SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[]);

-- s22 ARTICLE_BY_CURRVAL params=[20]
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')));

-- s23 USER_INSERT params=[25, 25, 25]
INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image;

-- s24 USER_BY_EMAIL params=[25]
SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1;

-- s25 USER_BY_ID params=[20]
SELECT id, username, email, bio, image FROM users WHERE id = $1;

-- s26 USER_UPDATE params=[20, 25, 25, 25, 25, 25]
UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) WHERE id = $1 RETURNING id, username, email, bio, image;

```

## Appendix D. go-epoll-o7livetype: every statement (src/sql.go, compiled; params i=int8 t=text a=text[]; read stmts on read conns, write stmts on write conns)

```sql
-- stTags params=""
SELECT ARRAY(SELECT name FROM tags ORDER BY name);

-- stUserByID params="i"
SELECT username, email, bio, image FROM users WHERE id = $1;

-- stUserByEmail params="t"
SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1;

-- stProfile params="it"
SELECT u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id)
FROM users u WHERE u.username = $2;

-- stListAll params="iii"
WITH total AS (SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s) SELECT total.count,page.* FROM total LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id=at.tag_id) AS name
              FROM article_tags at WHERE at.article_id=a.id ORDER BY name) AS tag_list,
       fav.n AS favorites_count, fav.favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
  CROSS JOIN LATERAL (SELECT count(*) AS n, COALESCE(bool_or(f.user_id=$1),false) AS favorited
                     FROM favorites f WHERE f.article_id=a.id) fav WHERE a.id IN (SELECT * FROM (SELECT p.id FROM articles p ORDER BY p.id DESC LIMIT $2 OFFSET $3) page LIMIT 100) ORDER BY a.id DESC) page ON true ORDER BY page.id DESC;

-- stListTag params="iiit"
WITH total AS (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s) SELECT total.count,page.* FROM total LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id=at.tag_id) AS name
              FROM article_tags at WHERE at.article_id=a.id ORDER BY name) AS tag_list,
       fav.n AS favorites_count, fav.favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
  CROSS JOIN LATERAL (SELECT count(*) AS n, COALESCE(bool_or(f.user_id=$1),false) AS favorited
                     FROM favorites f WHERE f.article_id=a.id) fav WHERE a.id IN (SELECT * FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) page LIMIT 100) ORDER BY a.id DESC) page ON true ORDER BY page.id DESC;

-- stListAuthor params="iiit"
WITH total AS (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s) SELECT total.count,page.* FROM total LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id=at.tag_id) AS name
              FROM article_tags at WHERE at.article_id=a.id ORDER BY name) AS tag_list,
       fav.n AS favorites_count, fav.favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
  CROSS JOIN LATERAL (SELECT count(*) AS n, COALESCE(bool_or(f.user_id=$1),false) AS favorited
                     FROM favorites f WHERE f.article_id=a.id) fav WHERE a.id IN (SELECT * FROM (SELECT p.id FROM articles p WHERE p.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY p.id DESC LIMIT $2 OFFSET $3) page LIMIT 100) ORDER BY a.id DESC) page ON true ORDER BY page.id DESC;

-- stListFavorite params="iiit"
WITH total AS (SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s) SELECT total.count,page.* FROM total LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id=at.tag_id) AS name
              FROM article_tags at WHERE at.article_id=a.id ORDER BY name) AS tag_list,
       fav.n AS favorites_count, fav.favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
  CROSS JOIN LATERAL (SELECT count(*) AS n, COALESCE(bool_or(f.user_id=$1),false) AS favorited
                     FROM favorites f WHERE f.article_id=a.id) fav WHERE a.id IN (SELECT * FROM (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) page LIMIT 100) ORDER BY a.id DESC) page ON true ORDER BY page.id DESC;

-- stListFeed params="iii"
WITH total AS (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s) SELECT total.count,page.* FROM total LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id=at.tag_id) AS name
              FROM article_tags at WHERE at.article_id=a.id ORDER BY name) AS tag_list,
       fav.n AS favorites_count, fav.favorited,
       u.username, u.bio, u.image,
       true AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
  CROSS JOIN LATERAL (SELECT count(*) AS n, COALESCE(bool_or(f.user_id=$1),false) AS favorited
                     FROM favorites f WHERE f.article_id=a.id) fav WHERE a.id IN (SELECT * FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (LEAST($2::bigint::numeric + $3::bigint::numeric, 9223372036854775807)::bigint)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) page LIMIT 100) ORDER BY a.id DESC) page ON true ORDER BY page.id DESC;

-- stArticleBySlug params="it"
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id=at.tag_id) AS name
              FROM article_tags at WHERE at.article_id=a.id ORDER BY name) AS tag_list,
       fav.n AS favorites_count, fav.favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
  CROSS JOIN LATERAL (SELECT count(*) AS n, COALESCE(bool_or(f.user_id=$1),false) AS favorited
                     FROM favorites f WHERE f.article_id=a.id) fav WHERE a.slug = $2;

-- stComments params="it"
SELECT c.id,c.body,c.created_at,c.updated_at,c.username,c.bio,c.image,COALESCE(c.following,false)
 FROM articles a LEFT JOIN LATERAL (
  SELECT c.id,c.body,c.created_at,c.updated_at,u.username,u.bio,u.image,
   EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id=$1 AND fo.followee_id=c.author_id) AS following
  FROM comments c JOIN users u ON u.id=c.author_id WHERE c.article_id=a.id
  ORDER BY c.created_at DESC,c.id DESC LIMIT 100
 ) c ON true WHERE a.slug=$2 ORDER BY c.created_at DESC,c.id DESC;

-- stRegister params="ttt"
INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
ON CONFLICT DO NOTHING RETURNING id, username, email, bio, image;

-- stUserUpdate params="ittttt"
WITH clash AS (SELECT EXISTS (SELECT 1 FROM users WHERE id <> $1 AND (email = $2 OR username = $3)) AS c),
 w AS (UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
       password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
       WHERE id = $1 AND NOT (SELECT c FROM clash) RETURNING username, email, bio, image)
SELECT clash.c, w.username, w.email, w.bio, w.image FROM clash LEFT JOIN w ON true;

-- stFollow params="it"
WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
 w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING)
SELECT username, bio, image FROM t;

-- stUnfollow params="it"
WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
 w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t))
SELECT username, bio, image FROM t;

-- stArticleCreate params="ittta"
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
FROM a JOIN users u ON u.id = a.author_id;

-- stArticleUpdate params="tttti"
WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
       updated_at = now()
       WHERE id = (SELECT id FROM t WHERE author_id = $5)
       RETURNING id, slug, title, description, body, created_at, updated_at, author_id)
SELECT t.author_id, w.id, w.slug, w.title, w.description, w.body, w.created_at, w.updated_at,
 ARRAY(SELECT (SELECT tg.name FROM tags tg WHERE tg.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = w.id ORDER BY name),
 (SELECT count(*) FROM favorites f WHERE f.article_id = w.id), EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = w.id AND f.user_id = $5),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $5 AND fo.followee_id = w.author_id)
FROM t LEFT JOIN w ON true LEFT JOIN users u ON u.id = w.author_id;

-- stArticleDelete params="ti"
WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2))
SELECT author_id FROM t;

-- stFavorite params="it"
WITH t AS (SELECT id, slug, title, description, body, created_at, updated_at, author_id FROM articles WHERE slug = $2),
 w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING RETURNING 1)
SELECT t.id, t.slug, t.title, t.description, t.body, t.created_at, t.updated_at,
 ARRAY(SELECT (SELECT tg.name FROM tags tg WHERE tg.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = t.id ORDER BY name),
 (SELECT count(*) FROM favorites f WHERE f.article_id = t.id) + (SELECT count(*) FROM w), true,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = t.author_id)
FROM t JOIN users u ON u.id = t.author_id;

-- stUnfavorite params="it"
WITH t AS (SELECT id, slug, title, description, body, created_at, updated_at, author_id FROM articles WHERE slug = $2),
 w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t) RETURNING 1)
SELECT t.id, t.slug, t.title, t.description, t.body, t.created_at, t.updated_at,
 ARRAY(SELECT (SELECT tg.name FROM tags tg WHERE tg.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = t.id ORDER BY name),
 (SELECT count(*) FROM favorites f WHERE f.article_id = t.id) - (SELECT count(*) FROM w), false,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = t.author_id)
FROM t JOIN users u ON u.id = t.author_id;

-- stCommentCreate params="tit"
WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM articles WHERE slug = $1
           RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
  FROM c JOIN users u ON u.id = c.author_id;

-- stCommentDelete params="iti"
WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
                WHERE c.id = $1 AND a.slug = $2),
 w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3))
SELECT author_id FROM t;

-- countAll (fallback)
SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s;
-- countByTag
SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s;
-- countByAuthor
SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s;
-- countByFavorite
SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s;
-- countFeed
SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s;
```

## Appendix E. goose-epoll-xeonfx: every statement (sql.goose, reconstructed; prepared as s0..s32)

```sql
-- s0 ST_REGISTER types=ttt (i int8, t text, I int8[], a text[])
INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image;

-- s1 ST_LOGIN types=t (i int8, t text, I int8[], a text[])
SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1;

-- s2 ST_CURRENT_USER types=i (i int8, t text, I int8[], a text[])
SELECT username, email, bio, image FROM users WHERE id = $1;

-- s3 ST_UPDATE_USER types=ittttt (i int8, t text, I int8[], a text[])
UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) WHERE id = $1 RETURNING username, email, bio, image;

-- s4 ST_PROFILE types=it (i int8, t text, I int8[], a text[])
SELECT u.username, u.bio, u.image, ($1 <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id)) FROM users u WHERE u.username = $2;

-- s5 ST_FOLLOW types=it (i int8, t text, I int8[], a text[])
WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) SELECT username, bio, image FROM t;

-- s6 ST_UNFOLLOW types=it (i int8, t text, I int8[], a text[])
WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t)) SELECT username, bio, image FROM t;

-- s7 ST_LIST_ALL types=iii (i int8, t text, I int8[], a text[])
WITH c AS (SELECT CASE WHEN EXISTS (SELECT 1 FROM articles a ORDER BY a.id OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM articles a) END AS n) SELECT p.*, c.n FROM c LEFT JOIN LATERAL (SELECT a.slug, a.title, a.description, a.created_at, a.updated_at, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8'), fv.fc, fv.fav, u.username, u.bio, u.image, ($1 <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)), a.id FROM (SELECT id FROM (SELECT id FROM articles ORDER BY id DESC LIMIT 100 OFFSET $3) b ORDER BY id DESC LIMIT $2) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = $1), false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC) p ON true ORDER BY p.id DESC;

-- s8 ST_LIST_TAG types=iiit (i int8, t text, I int8[], a text[])
WITH c AS (SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)) END AS n) SELECT p.*, c.n FROM c LEFT JOIN LATERAL (SELECT a.slug, a.title, a.description, a.created_at, a.updated_at, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8'), fv.fc, fv.fav, u.username, u.bio, u.image, ($1 <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)), a.id FROM (SELECT id FROM (SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT 100 OFFSET $3) b ORDER BY id DESC LIMIT $2) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = $1), false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC) p ON true ORDER BY p.id DESC;

-- s9 ST_LIST_AUTHOR types=iiit (i int8, t text, I int8[], a text[])
WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s) SELECT p.*, c.n FROM c LEFT JOIN LATERAL (SELECT a.slug, a.title, a.description, a.created_at, a.updated_at, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8'), (SELECT count(*) FROM favorites f WHERE f.article_id = a.id), ($1 <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1)), u.username, u.bio, u.image, ($1 <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)), a.id FROM (SELECT id FROM (SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a2.id DESC LIMIT 100 OFFSET $3) b ORDER BY id DESC LIMIT $2) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) p ON true ORDER BY p.id DESC;

-- s10 ST_LIST_FAVORITED types=iiit (i int8, t text, I int8[], a text[])
WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s) SELECT p.*, c.n FROM c LEFT JOIN LATERAL (SELECT a.slug, a.title, a.description, a.created_at, a.updated_at, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8'), (SELECT count(*) FROM favorites f WHERE f.article_id = a.id), a.id = ANY(ARRAY(SELECT vf.article_id FROM favorites vf WHERE vf.user_id = $1)), u.username, u.bio, u.image, a.author_id = ANY(ARRAY(SELECT vo.followee_id FROM follows vo WHERE vo.follower_id = $1)), a.id FROM (SELECT id FROM (SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT 100 OFFSET $3) b ORDER BY id DESC LIMIT $2) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) p ON true ORDER BY p.id DESC;

-- s11 ST_FEED types=iiii (i int8, t text, I int8[], a text[])
WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s) SELECT p.*, c.n FROM c LEFT JOIN LATERAL (SELECT a.slug, a.title, a.description, a.created_at, a.updated_at, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8'), (SELECT count(*) FROM favorites f WHERE f.article_id = a.id), ($1 <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1)), u.username, u.bio, u.image, true, a.id FROM (SELECT id FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT $4) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT 100 OFFSET $3) b ORDER BY id DESC LIMIT $2) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) p ON true ORDER BY p.id DESC;

-- s12 ST_ARTICLE types=it (i int8, t text, I int8[], a text[])
SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8'), (SELECT count(*) FROM favorites f WHERE f.article_id = a.id), ($1 <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1)), u.username, u.bio, u.image, ($1 <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)) FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2;

-- s13 ST_INSERT_ARTICLE types=ittt (i int8, t text, I int8[], a text[])
INSERT INTO articles (id, slug, author_id, title, description, body) SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4 FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n;

-- s14 ST_INSERT_TAGS types=a (i int8, t text, I int8[], a text[])
INSERT INTO tags (name) SELECT x.name FROM (SELECT DISTINCT unnest($1::text[]) AS name) x WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = x.name) ORDER BY 1 ON CONFLICT (name) DO NOTHING;

-- s15 ST_INSERT_ARTICLE_TAGS types=a (i int8, t text, I int8[], a text[])
INSERT INTO article_tags (article_id, tag_id) SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[]);

-- s16 ST_INSERTED_ARTICLE types=i (i int8, t text, I int8[], a text[])
SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8'), (SELECT count(*) FROM favorites f WHERE f.article_id = a.id), ($1 <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1)), u.username, u.bio, u.image, ($1 <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)) FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')));

-- s17 ST_UPDATE_ARTICLE types=itttt (i int8, t text, I int8[], a text[])
WITH t AS (SELECT id, author_id FROM articles WHERE slug = $2), a AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), body = COALESCE($5, body), slug = CASE WHEN $3::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($3, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END, updated_at = now() WHERE id = (SELECT id FROM t WHERE author_id = $1) RETURNING id, slug, title, description, body, created_at, updated_at, author_id) SELECT t.author_id, x.* FROM t LEFT JOIN LATERAL (SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8'), (SELECT count(*) FROM favorites f WHERE f.article_id = a.id), ($1 <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1)), u.username, u.bio, u.image, ($1 <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)) FROM a JOIN users u ON u.id = a.author_id) x ON true;

-- s18 ST_DELETE_ARTICLE types=it (i int8, t text, I int8[], a text[])
WITH t AS (SELECT id, author_id FROM articles WHERE slug = $2), d AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $1)) SELECT author_id FROM t;

-- s19 ST_FAVORITE types=it (i int8, t text, I int8[], a text[])
WITH t AS (SELECT id FROM articles WHERE slug = $2), w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8'), ((SELECT count(*) FROM favorites f WHERE f.article_id = a.id) + (NOT EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1))::int), true, u.username, u.bio, u.image, ($1 <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)) FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT id FROM t);

-- s20 ST_UNFAVORITE types=it (i int8, t text, I int8[], a text[])
WITH t AS (SELECT id FROM articles WHERE slug = $2), w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t)) SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8'), ((SELECT count(*) FROM favorites f WHERE f.article_id = a.id) - (EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1))::int), false, u.username, u.bio, u.image, ($1 <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)) FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT id FROM t);

-- s21 ST_COMMENTS types=it (i int8, t text, I int8[], a text[])
SELECT x.id, x.created_at, x.updated_at, x.body, x.username, x.bio, x.image, x.following FROM articles a LEFT JOIN LATERAL (SELECT c.id, c.created_at, c.updated_at, c.body, u.username, u.bio, u.image, ($1 <> 0 AND c.author_id IN (SELECT vo.followee_id FROM follows vo WHERE vo.follower_id = $1)) AS following FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) x ON true WHERE a.slug = $2 ORDER BY x.created_at DESC, x.id DESC;

-- s22 ST_CREATE_COMMENT types=itt (i int8, t text, I int8[], a text[])
WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $1, $2 FROM articles a WHERE a.slug = $3 RETURNING id, created_at, updated_at, body) SELECT c.id, c.created_at, c.updated_at, c.body, u.username, u.bio, u.image FROM c, users u WHERE u.id = $1;

-- s23 ST_DELETE_COMMENT types=iit (i int8, t text, I int8[], a text[])
WITH c AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $2 AND a.slug = $3), d AS (DELETE FROM comments WHERE id = (SELECT id FROM c WHERE author_id = $1)) SELECT author_id FROM c;

-- s24 ST_TAGS types= (i int8, t text, I int8[], a text[])
SELECT convert_to(array_to_json(array_agg(name ORDER BY name))::text, 'UTF8') FROM tags;

-- s25 ST_BATCH_ALL types=III (i int8, t text, I int8[], a text[])
SELECT q.*, r.ord FROM unnest($1::bigint[],$2::bigint[],$3::bigint[]) WITH ORDINALITY AS r(p1,p2,p3,ord) CROSS JOIN LATERAL (WITH c AS (SELECT CASE WHEN EXISTS (SELECT 1 FROM articles a ORDER BY a.id OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM articles a) END AS n) SELECT p.*, c.n FROM c LEFT JOIN LATERAL (SELECT a.slug, a.title, a.description, a.created_at, a.updated_at, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8'), fv.fc, fv.fav, u.username, u.bio, u.image, (r.p1 <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id)), a.id FROM (SELECT id FROM (SELECT id FROM articles ORDER BY id DESC LIMIT 100 OFFSET r.p3) b ORDER BY id DESC LIMIT r.p2) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = r.p1), false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC) p ON true ORDER BY p.id DESC) q ORDER BY r.ord, q.id DESC;

-- s26 ST_BATCH_TAG types=IIIa (i int8, t text, I int8[], a text[])
SELECT q.*, r.ord FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord) CROSS JOIN LATERAL (WITH c AS (SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) ORDER BY at.article_id OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4)) END AS n) SELECT p.*, c.n FROM c LEFT JOIN LATERAL (SELECT a.slug, a.title, a.description, a.created_at, a.updated_at, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8'), fv.fc, fv.fav, u.username, u.bio, u.image, (r.p1 <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id)), a.id FROM (SELECT id FROM (SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) ORDER BY at.article_id DESC LIMIT 100 OFFSET r.p3) b ORDER BY id DESC LIMIT r.p2) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = r.p1), false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC) p ON true ORDER BY p.id DESC) q ORDER BY r.ord, q.id DESC;

-- s27 ST_BATCH_AUTHOR types=IIIa (i int8, t text, I int8[], a text[])
SELECT q.*, r.ord FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord) CROSS JOIN LATERAL (WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = r.p4) LIMIT 1000) s) SELECT p.*, c.n FROM c LEFT JOIN LATERAL (SELECT a.slug, a.title, a.description, a.created_at, a.updated_at, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8'), (SELECT count(*) FROM favorites f WHERE f.article_id = a.id), (r.p1 <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = r.p1)), u.username, u.bio, u.image, (r.p1 <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id)), a.id FROM (SELECT id FROM (SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = r.p4) ORDER BY a2.id DESC LIMIT 100 OFFSET r.p3) b ORDER BY id DESC LIMIT r.p2) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) p ON true ORDER BY p.id DESC) q ORDER BY r.ord, q.id DESC;

-- s28 ST_BATCH_FAVORITED types=IIIa (i int8, t text, I int8[], a text[])
SELECT q.*, r.ord FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord) CROSS JOIN LATERAL (WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.p4) LIMIT 1000) s) SELECT p.*, c.n FROM c LEFT JOIN LATERAL (SELECT a.slug, a.title, a.description, a.created_at, a.updated_at, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8'), (SELECT count(*) FROM favorites f WHERE f.article_id = a.id), a.id = ANY(ARRAY(SELECT vf.article_id FROM favorites vf WHERE vf.user_id = r.p1)), u.username, u.bio, u.image, a.author_id = ANY(ARRAY(SELECT vo.followee_id FROM follows vo WHERE vo.follower_id = r.p1)), a.id FROM (SELECT id FROM (SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.p4) ORDER BY f.article_id DESC LIMIT 100 OFFSET r.p3) b ORDER BY id DESC LIMIT r.p2) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) p ON true ORDER BY p.id DESC) q ORDER BY r.ord, q.id DESC;

-- s29 ST_SHARE_ALL types=III (i int8, t text, I int8[], a text[])
WITH r AS MATERIALIZED (SELECT * FROM unnest($1::bigint[],$2::bigint[],$3::bigint[]) WITH ORDINALITY AS r(p1,p2,p3,ord)), counted AS MATERIALIZED (SELECT r.*, c.n FROM r CROSS JOIN LATERAL (SELECT CASE WHEN EXISTS (SELECT 1 FROM articles a ORDER BY a.id OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM articles a) END AS n) c), pages AS MATERIALIZED (SELECT r.ord, r.p1 AS viewer, r.n, p.id FROM counted r LEFT JOIN LATERAL (SELECT id FROM (SELECT id FROM articles ORDER BY id DESC LIMIT 100 OFFSET r.p3) b ORDER BY id DESC LIMIT r.p2) p ON true), ids AS (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL), e AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8') AS tags, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc, u.username, u.bio, u.image FROM ids JOIN articles a ON a.id = ids.id JOIN users u ON u.id = a.author_id) SELECT e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc, (p.viewer <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = p.viewer)), e.username, e.bio, e.image, (p.viewer <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = p.viewer AND fo.followee_id = e.author_id)), e.id, p.n, p.ord FROM pages p LEFT JOIN e ON e.id = p.id ORDER BY p.ord, e.id DESC;

-- s30 ST_SHARE_TAG types=IIIa (i int8, t text, I int8[], a text[])
WITH r AS MATERIALIZED (SELECT * FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord)), counted AS MATERIALIZED (SELECT r.*, c.n FROM r CROSS JOIN LATERAL (SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) ORDER BY at.article_id OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4)) END AS n) c), pages AS MATERIALIZED (SELECT r.ord, r.p1 AS viewer, r.n, p.id FROM counted r LEFT JOIN LATERAL (SELECT id FROM (SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) ORDER BY at.article_id DESC LIMIT 100 OFFSET r.p3) b ORDER BY id DESC LIMIT r.p2) p ON true), ids AS (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL), e AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8') AS tags, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc, u.username, u.bio, u.image FROM ids JOIN articles a ON a.id = ids.id JOIN users u ON u.id = a.author_id) SELECT e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc, (p.viewer <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = p.viewer)), e.username, e.bio, e.image, (p.viewer <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = p.viewer AND fo.followee_id = e.author_id)), e.id, p.n, p.ord FROM pages p LEFT JOIN e ON e.id = p.id ORDER BY p.ord, e.id DESC;

-- s31 ST_SHARE_AUTHOR types=IIIa (i int8, t text, I int8[], a text[])
WITH r AS MATERIALIZED (SELECT * FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord)), counted AS MATERIALIZED (SELECT r.*, c.n FROM r CROSS JOIN LATERAL (SELECT count(*) AS n FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = r.p4) LIMIT 1000) s) c), pages AS MATERIALIZED (SELECT r.ord, r.p1 AS viewer, r.n, p.id FROM counted r LEFT JOIN LATERAL (SELECT id FROM (SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = r.p4) ORDER BY a2.id DESC LIMIT 100 OFFSET r.p3) b ORDER BY id DESC LIMIT r.p2) p ON true), ids AS (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL), e AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8') AS tags, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc, u.username, u.bio, u.image FROM ids JOIN articles a ON a.id = ids.id JOIN users u ON u.id = a.author_id) SELECT e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc, (p.viewer <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = p.viewer)), e.username, e.bio, e.image, (p.viewer <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = p.viewer AND fo.followee_id = e.author_id)), e.id, p.n, p.ord FROM pages p LEFT JOIN e ON e.id = p.id ORDER BY p.ord, e.id DESC;

-- s32 ST_SHARE_FAVORITED types=IIIa (i int8, t text, I int8[], a text[])
WITH r AS MATERIALIZED (SELECT * FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord)), counted AS MATERIALIZED (SELECT r.*, c.n FROM r CROSS JOIN LATERAL (SELECT count(*) AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.p4) LIMIT 1000) s) c), pages AS MATERIALIZED (SELECT r.ord, r.p1 AS viewer, r.n, p.id FROM counted r LEFT JOIN LATERAL (SELECT id FROM (SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.p4) ORDER BY f.article_id DESC LIMIT 100 OFFSET r.p3) b ORDER BY id DESC LIMIT r.p2) p ON true), ids AS (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL), e AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8') AS tags, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc, u.username, u.bio, u.image FROM ids JOIN articles a ON a.id = ids.id JOIN users u ON u.id = a.author_id) SELECT e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc, (p.viewer <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = p.viewer)), e.username, e.bio, e.image, (p.viewer <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = p.viewer AND fo.followee_id = e.author_id)), e.id, p.n, p.ord FROM pages p LEFT JOIN e ON e.id = p.id ORDER BY p.ord, e.id DESC;

```
