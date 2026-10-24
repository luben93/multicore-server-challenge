# SQL catalog for the zero-dependency Kotlin Conduit server

Read-only research. Nothing in the repo was changed. Paths:

- `R/` = `/home/user/multicore-server-challenge/submissions/rust-tokio-Scooter1337/` (#1, 100k users)
- `C/` = `/home/user/multicore-server-challenge/submissions/csharp-sockets-jh-d/` (#2, 95k users)
- `G/` = `/home/user/multicore-server-challenge/submissions/go-epoll-o7livetype/` (#10, the source of three write statements)
- `SPEC.md`, `schema.sql`, `WORKLOAD.md`, `box/*` are at the repo root.

**How the SQL text was obtained.** Every SQL block below was pasted mechanically from generator output, not
retyped. The C# texts are the `Sql.cs` string concatenation replayed (scratchpad `research/csharp.md` Appendix A,
built for `AppSortsTags = true`). The Rust texts come from compiling `R/src/sql.rs` and `R/src/read_batch.rs`
(`research/rust-tokio.md`). The Go texts come from compiling `G/src/sql.go` (`research/others.md` Appendix D). I
then checked them against the sources (`C/src/Sql.cs:1-239`, `R/src/sql.rs:1-195`, `R/src/read_batch.rs:14-201`,
`G/src/sql.go:109-250`). Every recommended statement was `PREPARE`d with the stated parameter types on a local
PostgreSQL 18.4 copy of the full seed (`bench_db`). The result types listed below come from `pg_prepared_statements`
(script: `scratchpad/sqlcheck/final.sql`, `p2.sql`). Newlines inside the SQL are part of the original literals.
Postgres ignores them.

**Measurements.** Everything marked *measured* was run in this lab: 4 vCPU, PG 18.4, `bench_db` (full seed plus
about 2.5k articles left over from a load test), single-client `pgbench -M prepared`, generic plans. These numbers
are only good for comparing variants against each other (section 7; scripts in `scratchpad/sqlcheck/`).

---

## 0. Decisions at a glance

| Endpoint (share of requests, from WORKLOAD.md:37-51) | Use | Batched form | Why |
|---|---|---|---|
| GET /api/tags (~20%) | R TAGS (`sql.rs:179`) | C s1 (`r.i >= 0`) | 1 DataRow, index-only on `tags_name_key`; C form is per-request, so it is rules-safe |
| GET /api/articles/:slug (~20%) | C s11 (`Sql.cs:144`) | C s2 | bounded PK probes; no tag sort when the app sorts (C collation); measured 5% faster than R batched |
| GET …/comments (~20%) | C per-request CommentsSql (`Sql.cs:219-229`) | C s3 | followee set read once per request; measured 25% faster than R's hashed `IN` |
| GET /api/articles (~12%) | R LIST_ALL (`sql.rs:43-48`) | C s6 | C batched is 10-15% cheaper than R batched (count 48 vs 60 µs) |
| GET /api/articles/feed (~8%) | R LIST_FEED (`sql.rs:69-72`) | C s10 | C feed per-request 8% faster (`true AS following`, probes) |
| GET /api/articles?tag= (~4%) | R LIST_TAG (`sql.rs:50-55`) | C s8 with R's tag count swapped in (4.1) | every seed tag has ≥1000 articles, so the `OFFSET 999` proof always hits |
| GET /api/articles?author= (~4%) | R LIST_AUTHOR (`sql.rs:57-60`) | C s7 | |
| GET /api/articles?favorited= (~1%) | R LIST_FAVORITED (`sql.rs:62-67`) | C s9 | |
| GET /api/profiles/:u (~5%) | R PROFILE (`sql.rs:165-167`) | C s4 | |
| GET /api/user (~0.3%) | SPEC/R USER_BY_ID | C s5 | |
| POST /api/users/login (~0.1%) | SPEC/R USER_BY_EMAIL | R USER_BY_EMAIL batched or single | |
| POST /api/users | G stRegister `ON CONFLICT DO NOTHING RETURNING` | n/a (write) | cannot abort a group commit |
| PUT /api/user | G stUserUpdate (clash CTE) | n/a | group-safe in the common case; 23505 race goes through rollback and retry |
| POST/DELETE follow (~0.8%) | R FOLLOW/UNFOLLOW CTE | n/a | 1 statement, no read-back |
| POST/DELETE favorite (~2.2%) | R FAVORITE/UNFAVORITE CTE, then ARTICLE_BY_ID batched read after commit | R ARTICLE_BY_ID batched | the cheap write keeps group transactions short, and the read-back is batched (G's one-statement form is the alternative) |
| POST /api/articles (~0.4%) | R ARTICLE_CREATE single CTE | n/a | article, tags and links in 1 statement that returns the full row |
| PUT /api/articles/:slug | R ARTICLE_UPDATE plus ARTICLE_BY_ID, or G stArticleUpdate single statement | n/a | |
| DELETE /api/articles/:slug | R ARTICLE_DELETE CTE | n/a | 404/403 from the returned author_id |
| POST comment (~1.4%) | R COMMENT_CREATE CTE | n/a | |
| DELETE comment | R COMMENT_DELETE CTE | n/a | |

Run every read as its **batched** statement, even when the batch holds 1 request (C# does this: `C/src/Batch.cs:31-56`).
The non-batched statements are kept as a reference and fallback, and for writes and read-backs.

---

## 1. Session settings at connect (c)

Send them in the StartupMessage, so connecting costs no extra round trip. C#'s exact value is
`C/src/Program.cs:13-14`:

```
options = -c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0 -c enable_memoize=off
client_encoding = UTF8
application_name = conduit
```

(C# also sends `client_encoding`/`application_name`, `csharp.md` §3.2. Each GUC can instead be sent as its own
startup parameter name/value pair, which is what Vert.x did (`kotlin-prior.md` §1.1).) Rust sends a simple query
after connecting, `R/src/db.rs:316`:

```sql
SET plan_cache_mode = force_generic_plan; SET jit = off
```

Why each setting:

- `plan_cache_mode=force_generic_plan`: no custom planning in the first 5 executions, and no cost comparison after
  that. Kotlin-prior measured "17% less Postgres CPU" (`kotlin-prior.md` §1.1). It must be in effect before a
  statement's first execution, which a startup parameter guarantees. **Plan-time GUCs are read when the generic plan
  is built.** An autovacuum `ANALYZE` sends a relcache invalidation, and the plan is then rebuilt with the settings
  current at that moment. So never toggle planner GUCs per statement. Keep them constant per connection.
- `jit=off`: every query takes milliseconds.
- `max_parallel_workers_per_gather=0`: the box's pgtune sets it to 4 (`box/pg-conf.sh:20,43`).
- `enable_memoize=off` (read connections): a rules choice in C# (`C/src/Program.cs:9-12`: Memoize "could hand one
  request a row another request's lookup fetched"). *Measured*: no Memoize node shows up in the C# s3/s6 or R
  batched LIST_ALL plans with Memoize on or off, and C# s6 timing is unchanged (2.01-2.03 ms off, 2.02-2.28 ms on).
  So turning it off costs nothing for these shapes. Caveat: c-iouring measured `enable_memoize=off` as **-55%** for
  *its* `WHERE a.id IN (...)` shapes (`others.md` §2.2). Only use it with the C#/R shapes below, which cut the page
  in a subquery.
- Not needed with binary results: `DateStyle`, `TimeZone`. Optional on write connections: `lock_timeout` (goose 2 s,
  go 2000 ms) and `statement_timeout` (go 5000 ms). Not allowed: `synchronous_commit=off` (README rule 6).
  `commit_delay` is superuser-only.

All Bind messages: one parameter-format code = 1 (binary), one result-format code = 1 (binary)
(`C/src/Pg.cs:126-161`, `csharp.md` §3.5). Prepare once per connection with explicit OIDs: int4 23, int8 20,
text 25, bool 16, int4[] 1007, int8[] 1016, text[] 1009 (`C/src/Pg.cs:15-18`). Never Describe; the layouts are
fixed (below).

**Tag order.** SPEC.md:43 requires "sorted by name", and conformance requires tags "strictly ascending by bytes"
(`conformance.md` §B.9). The local cluster is `datlocprovider=c, datcollate=C.UTF-8`, so ORDER BY name is byte
order. On the box the collation depends on the OS locale when PGDG created the cluster (`box/setup-box.sh:34`
doesn't set it). Copy C#'s probe, `C/src/Sql.cs:19-20` and `C/src/Program.cs:17-28`:

```sql
SELECT datlocprovider::text, datcollate, coalesce(datlocale, '') FROM pg_database WHERE datname = current_database()
```

The app may sort tags itself (by UTF-8 bytes, and drop ` ORDER BY 1` inside the per-article `ARRAY(...)`) only
when provider `c` with datcollate `C`, `POSIX` or `C.*`, or provider `b` with datlocale `C`/`C.UTF-8`. In every other
case keep ` ORDER BY 1`. *Measured*: dropping the per-article sort saves about 6% on a batch of 16 article reads (3252-3276 vs
3066-3076 tps). `GET /api/tags` keeps `ORDER BY name` in SQL, because the `tags_name_key` index order makes it free.

---

## 2. Row layouts (both implementations)

Article columns from C# and from R (non-batched): `id int8, slug, title, description, [body], created_at timestamptz,
updated_at timestamptz, tag_list text[], favorites_count int8, favorited bool, username, bio, image, following bool`.
`bio`/`image` may be NULL. An empty `text[]` arrives as ndim=0 (12-byte header) (`csharp.md` §3.7).

- C# batched rows put `r.i int4` (0-based request index) **first**. Lists add `c.n int8` (capped count) second, so
  article columns start at column 2 (`C/src/Handlers.cs:374-383`).
- R batched rows put `__request_id int8` (1-based `WITH ORDINALITY` ordinal) **last** (`R/src/writer.rs:401-409`).
- R list rows (non-batched) are `n, id, …` (the count first), with one all-NULL article row when the page is empty
  (`R/src/api.rs:293-313`).
- Timestamps are binary int64 µs since 2000-01-01. Convert with `floorDiv(µs, 1000) + 946684800000` ms and truncate
  to `.mmmZ` (SPEC.md:40).

---

## 3. Per-endpoint catalog (a) + (b) + (d)

### 3.1 GET /api/tags (no auth)

**(a)** R `TAGS`, `R/src/sql.rs:179`. No params. Result: `[text[]]` (1 row).
```sql
SELECT ARRAY(SELECT name FROM tags ORDER BY name)
```
This returns 1 DataRow instead of SPEC's 200 rows (`SPEC.md:261`) and is an index-only scan on `tags_name_key`
(*measured* 13.4k tps single).

**(b)** C s1, `C/src/Sql.cs:120-122`. Params `$1 int4[]` (request indexes 0..N-1). Result: `r.i int4, text[]`.
```sql
SELECT r.i, ARRAY(SELECT t.name FROM tags t WHERE r.i >= 0 ORDER BY t.name) FROM unnest($1::int4[]) AS r(i)
```
- **`WHERE r.i >= 0` is mandatory.** Without it the ARRAY subquery is an uncorrelated InitPlan, evaluated once per
  statement and shared by every request (*verified with EXPLAIN*, see 4.2). *Measured*: 16 requests take 0.47 ms,
  about 30 µs each.
- The alternative from R is a broadcast: it runs the plain TAGS once and clones the rows to every request already
  queued (`R/src/read_batch.rs:85-94`, `R/src/writer.rs:388-396`). That is cheaper (1 execution), but it shares one
  result between requests, which is a gray area under README rule 5. R was scored #1 with it, and C# explicitly
  avoided it (`C/README.md:29-33`). At 30 µs per request in the batched form, tags are about 20% × 30 µs ≈ 6 µs of
  the roughly 210 µs of PG per average request, so the rules-safe C# form costs about 3% at most.

### 3.2 GET /api/user (auth required)

**(a)** `R/src/sql.rs:182` = `C/src/Sql.cs:238` = SPEC.md:114. `$1 int8` user id. Result:
`id int8, username, email, bio, image`. No row → 401. `token` echoes the presented token.
```sql
SELECT id, username, email, bio, image FROM users WHERE id = $1
```
**(b)** C s5 (`C/src/Sql.cs:126`). Params `$1 int4[]` index, `$2 int8[]` user ids. Result: `r.i, id, username, email, bio, image`.
```sql
SELECT r.i, x.* FROM unnest($1::int4[], $2::int8[]) AS r(i, v) CROSS JOIN LATERAL (SELECT id, username, email, bio, image FROM users WHERE id = r.v) x
```
R form (`read_batch.rs:60-64`, params `$1 int8[]`; the ordinal is last):
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[]) WITH ORDINALITY AS r(p1,ord) CROSS JOIN LATERAL (SELECT id, username, email, bio, image FROM users WHERE id = r.p1) q
```

### 3.3 POST /api/users/login (no auth)

**(a)** SPEC.md:108 = `R/src/sql.rs:184-185` = `C/src/Sql.cs:197`. `$1 text` email. Result:
`id, username, email, bio, image, password_hash`. No row → 401, bcrypt mismatch → 401. C# and R release the DB
connection **before** bcrypt verify (`R/src/api.rs:410-427`).
```sql
SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1
```
**(b)** Optional (about 28 per second at 100k users). R batched, `$1 text[]`:
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::text[]) WITH ORDINALITY AS r(p1,ord) CROSS JOIN LATERAL (SELECT id, username, email, bio, image, password_hash FROM users WHERE email = r.p1) q
```

### 3.4 POST /api/users (register): write

**(a)** G `stRegister`, `G/src/sql.go:167-168`. `$1 text` username, `$2 text` email, `$3 text` bcrypt hash.
Result: `id int8, username, email, bio, image`. **No row → 422** (duplicate username or email).
```sql
INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
ON CONFLICT DO NOTHING RETURNING id, username, email, bio, image
```
- Why: SPEC's plain INSERT (`SPEC.md:101-104`, `R/src/sql.rs:187-189`) raises 23505, which **aborts every other
  write sharing its group transaction**. Rust handles that with ROLLBACK and an individual retry
  (`R/src/writer.rs:246-287`). Without a conflict target, `ON CONFLICT DO NOTHING` covers both unique constraints
  (and the PK). A concurrent insert of the same name waits for the other transaction, then does nothing, which gives
  422. That is correct.
- Hash with bcrypt **before** queuing the write (all top entries do).

### 3.5 PUT /api/user: write

**(a)** G `stUserUpdate`, `G/src/sql.go:174-178`. `$1 int8` id, `$2 text?` email, `$3 text?` username,
`$4 text?` new hash, `$5 text?` bio, `$6 text?` image (NULL = unchanged). Result: `clash bool, username, email, bio, image`.
`clash` true → 422. Row with NULL username and clash false → 401. Otherwise 200, echoing the token.
```sql
WITH clash AS (SELECT EXISTS (SELECT 1 FROM users WHERE id <> $1 AND (email = $2 OR username = $3)) AS c),
 w AS (UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
       password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
       WHERE id = $1 AND NOT (SELECT c FROM clash) RETURNING username, email, bio, image)
SELECT clash.c, w.username, w.email, w.bio, w.image FROM clash LEFT JOIN w ON true
```
- A *concurrent* clash can still raise 23505 (two users taking the same new email at the same moment). Then the group
  rolls back, the requests are retried one at a time, and 23505 maps to 422 (`G/src/sql.go:169-171`).
- The plain alternative is SPEC.md:121-124 = `R/src/sql.rs:191-195`, with 23505 → 422 and no row → 401. Run it
  alone (autocommit) or rely on rollback and retry.
- Rules from SPEC.md:118-126 and conformance: absent or null means unchanged. bio/image may be set to `""`. With
  COALESCE they cannot be set back to NULL, which matches the reference.

### 3.6 GET /api/profiles/:username (auth optional)

**(a)** R `PROFILE`, `R/src/sql.rs:165-167`. `$1 int8` viewer (0 = anonymous), `$2 text` username. Result:
`username, bio, image, following bool`. No row → 404.
```sql
SELECT u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id)
FROM users u WHERE u.username = $2
```
**(b)** C s4 (`C/src/Sql.cs:125, 232-236`). Params `$1 int4[]`, `$2 int8[]` viewers, `$3 text[]` usernames.
Result: `r.i, username, bio, image, following`.
```sql
SELECT r.i, x.* FROM unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, k) CROSS JOIN LATERAL (SELECT u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = u.id) AS following
  FROM users u WHERE u.username = r.k) x
```
The R batched form is in 4.5.

### 3.7 / 3.8 POST and DELETE /api/profiles/:username/follow: write

**(a)** R `FOLLOW` / `UNFOLLOW`, `R/src/sql.rs:169-177` (identical to `G/src/sql.go:180-185`, `stFollow`/`stUnfollow`). `$1 int8` viewer,
`$2 text` username. Result: `username, bio, image`. No row → 404. JSON `following` is the constant true (POST) or
false (DELETE), per SPEC.md:146. There is no read-back.
```sql
WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
 w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING)
SELECT username, bio, image FROM t
```
```sql
WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
 w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t))
SELECT username, bio, image FROM t
```
(C#'s version uses `followee_id IN (SELECT id FROM u)`, `C/src/Sql.cs:204-213`, and is equivalent.)

### 3.9 GET /api/articles (auth optional)

Shared rules (SPEC.md:150-160, 87-88, 267):
- Only one filter applies, with precedence **tag > author > favorited**. An empty filter value counts as absent.
- limit and offset: digits only, limit 1..100 (default 20), offset ≥ 0 (default 0). Anything else → 422.
- Lists are newest first by id. `articlesCount` = min(count, 1000). An unknown tag or user gives `[]` with count 0.
- An empty page (offset past the end) must still return the count. Every statement below returns one row with NULL
  article columns in that case, and the app skips rows whose id is NULL.

#### 3.9.1 No filter

**(a)** R `LIST_ALL`, `R/src/sql.rs:43-48`. `$1 int8` viewer, `$2 int8` limit, `$3 int8` offset. Result:
`n int8, id, slug, title, description, created_at, updated_at, tags text[], fc int8, fav bool, username, bio, image, following bool`.
```sql
WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 fv.fc,
 fv.fav,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT * FROM (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET $3) bounded ORDER BY bounded.id DESC LIMIT $2) a ON true LEFT JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = $1),false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC
```
- The inner `LIMIT 100 OFFSET $3` bound lets the generic plan know a page holds at most 100 rows. The count walks the
  oldest, all-visible end of the PK (`sql.rs:41-42`). `fv` computes count and membership in one scan of
  `favorites_article_idx`.
- *Measured* single: 0.204 ms, against 0.208 ms for the C# shape and 0.259 ms for kotlin-prior's PAGE_ALL. At deep
  offsets (3000+) both R and C# fetch the heap for every row OFFSET skips (2.2 ms against 0.58 ms for
  kotlin-prior's id-only page). The workload's offsets are 0-40 (WORKLOAD.md:54), so this doesn't matter in practice.

**(b)** C s6, `C/src/Sql.cs:86-88, 92-94, 128-129`. Params `$1 int4[]` index, `$2 int8[]` viewer, `$3 int4[]` limit,
`$4 int8[]` offset. Result: `r.i int4, c.n int8, id, slug, title, description, created_at, updated_at, tag_list, favorites_count, favorited, username, bio, image, following`.
```sql
SELECT r.i, c.n, x.* FROM unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[]) AS r(i, v, l, o) CROSS JOIN LATERAL (SELECT CASE WHEN EXISTS (SELECT 1 FROM articles c WHERE r.i >= 0 ORDER BY c.id OFFSET 999) THEN 1000 ELSE (SELECT count(*) FROM articles c WHERE r.i >= 0) END AS n OFFSET 0) c LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, (SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = a.author_id) IS NOT NULL AS following FROM (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a ORDER BY a.id DESC LIMIT r.l OFFSET r.o) a JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) x ON true
```
(If the collation is not code-point order, replace
`WHERE at.article_id = a.id) AS tag_list` with `WHERE at.article_id = a.id ORDER BY 1) AS tag_list`. The same applies
to every C# article statement: `csharp.md` Appendix A header.)

*Measured*, 16 requests per statement: C s6 2.01-2.03 ms, R batched 2.24-2.40 ms, R shared 1.30-1.40 ms.

R batched form (`R/src/read_batch.rs:60-68`). Params `$1..$3 int8[]` (viewer, limit, offset). Result: list layout,
plus `__request_id int8` last.
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::bigint[],$3::bigint[]) WITH ORDINALITY AS r(p1,p2,p3,ord) CROSS JOIN LATERAL (WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 fv.fc,
 fv.fav,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT * FROM (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET r.p3) bounded ORDER BY bounded.id DESC LIMIT r.p2) a ON true LEFT JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = r.p1),false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC) q ORDER BY r.ord, q.id DESC
```
The R "shared enrichment" form (`R/src/read_batch.rs:146-201`) is used only when the distinct
(limit, offset, filter) keys number at most half the group (`read_batch.rs:107-121`):
```sql
WITH requests AS MATERIALIZED (
         SELECT * FROM unnest($1::bigint[],$2::bigint[],$3::bigint[]) WITH ORDINALITY AS r(p1,p2,p3,ord)),
         counted AS MATERIALIZED (
         SELECT r.*, c.n FROM requests r CROSS JOIN LATERAL (SELECT count(*) AS n FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s) c),
         pages AS MATERIALIZED (
         SELECT r.ord, r.p1 AS viewer, r.n, p.id FROM counted r
         LEFT JOIN LATERAL (SELECT id FROM (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET r.p3) bounded ORDER BY id DESC LIMIT r.p2) p ON true),
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
**Rules warning (verified with EXPLAIN):** in this shared form the global count runs **once for all requests**
(`Aggregate … loops=1` for 16 requests). The planner puts the uncorrelated count on the outer side. Tags, fc and the
author are also computed once per distinct article across requests, by design. It is about 40% cheaper per request,
but it shares results between requests inside one statement. R did that at #1, and C# treats it as forbidden. If you
use it, at least tie the count to the request row the way C# does, for example
`(SELECT 1 FROM articles WHERE r.ord >= 0 ORDER BY id LIMIT 1000)`.

#### 3.9.2 ?tag=

**(a)** R `LIST_TAG`, `R/src/sql.rs:50-55`. `$1 int8` viewer, `$2 int8` limit, `$3 int8` offset, `$4 text` tag.
Result: the list layout.
```sql
WITH c AS (SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s) END AS n) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 fv.fc,
 fv.fav,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.article_id) a ON true LEFT JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = $1),false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC
```
- The count is **"a 1000th row exists, so 1000"**. Seed tags follow Zipf(1.0) over 200 tags with about 1.25M links
  (WORKLOAD.md:11), so even the 200th tag has about 1,060 articles, and the shortcut always fires. *Measured* per
  execution for `stun`: 49 µs, against 58 µs for the plain `LIMIT 1000` count.

**(b)** C s8 (`C/src/Sql.cs:96-97, 133-135`). Params `$1 int4[]`, `$2 int8[]` viewer, `$3 int4[]` limit,
`$4 int8[]` offset, `$5 text[]` tag. Result: the C# list layout.
```sql
SELECT r.i, c.n, x.* FROM unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[]) AS r(i, v, l, o, k) CROSS JOIN LATERAL (SELECT (SELECT count(*) FROM (SELECT 1 FROM article_tags c WHERE c.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.k) LIMIT 1000) s) AS n OFFSET 0) c LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, (SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = a.author_id) IS NOT NULL AS following FROM (SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.k) ORDER BY at.article_id DESC LIMIT r.l OFFSET r.o) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY p.id DESC) x ON true
```
**Recommended variant:** C s8 with C#'s `CountTag` replaced by R's tag count. I composed this myself; it passes
`PREPARE` and *measured* 396-402 tps against 381-382 for C s8 (16 requests).
```sql
SELECT r.i, c.n, x.* FROM unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[]) AS r(i, v, l, o, k) CROSS JOIN LATERAL (SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.k) OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.k) LIMIT 1000) s) END AS n OFFSET 0) c LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, (SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = a.author_id) IS NOT NULL AS following FROM (SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.k) ORDER BY at.article_id DESC LIMIT r.l OFFSET r.o) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY p.id DESC) x ON true
```
R batched (the shared form is `rust-tokio.md` §1.17):
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord) CROSS JOIN LATERAL (WITH c AS (SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) LIMIT 1000) s) END AS n) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 fv.fc,
 fv.fav,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) ORDER BY at.article_id DESC LIMIT r.p2 OFFSET r.p3) p JOIN articles a2 ON a2.id = p.article_id) a ON true LEFT JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = r.p1),false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC) q ORDER BY r.ord, q.id DESC
```
*Measured*, 16 requests: R batched 393-403 tps, R shared 452-456 tps.

#### 3.9.3 ?author=

**(a)** R `LIST_AUTHOR` (the `list_stmt!` macro, `R/src/sql.rs:10-39, 57-60`). `$1 int8` viewer, `$2 int8` limit,
`$3 int8` offset, `$4 text` username. Result: the list layout.
```sql
WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = $4) LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a2.id DESC LIMIT $2 OFFSET $3) a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC
```
Authors follow Zipf(0.8) (WORKLOAD.md:10), so most have fewer than 1000 articles. A plain capped count is right here,
because `EXISTS … OFFSET 999` would scan twice below 1000.

**(b)** C s7 (`C/src/Sql.cs:98-99, 130-132`). Params as for s8 (`$5 text[]` = usernames).
```sql
SELECT r.i, c.n, x.* FROM unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[]) AS r(i, v, l, o, k) CROSS JOIN LATERAL (SELECT (SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id = (SELECT u.id FROM users u WHERE u.username = r.k) LIMIT 1000) s) AS n OFFSET 0) c LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, (SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = a.author_id) IS NOT NULL AS following FROM (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = r.k) ORDER BY a.id DESC LIMIT r.l OFFSET r.o) a JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) x ON true
```
R batched:
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord) CROSS JOIN LATERAL (WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = r.p4) LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = r.p1),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = r.p4) ORDER BY a2.id DESC LIMIT r.p2 OFFSET r.p3) a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) q ORDER BY r.ord, q.id DESC
```

#### 3.9.4 ?favorited=

**(a)** R `LIST_FAVORITED`, `R/src/sql.rs:62-67`. `$1 int8` viewer, `$2 int8` limit, `$3 int8` offset,
`$4 text` username. Result: the list layout.
```sql
WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 COALESCE(a.id = ANY(ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = $1)), false),
 u.username, u.bio, u.image,
 COALESCE(a.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)), false) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.article_id) a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC
```
The viewer flags are `= ANY(ARRAY(…))`. *Verified*: in the batched R form these become InitPlans that run **once
per request** (loops = N), not once per row. They read the viewer's whole favorites list (82 rows for a heavy user)
for a 5-row page. C#'s per-row probes stay bounded.

**(b)** C s9 (`C/src/Sql.cs:100-101, 136-138`). Params as for s8.
```sql
SELECT r.i, c.n, x.* FROM unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[]) AS r(i, v, l, o, k) CROSS JOIN LATERAL (SELECT (SELECT count(*) FROM (SELECT 1 FROM favorites c WHERE c.user_id = (SELECT u.id FROM users u WHERE u.username = r.k) LIMIT 1000) s) AS n OFFSET 0) c LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, (SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = a.author_id) IS NOT NULL AS following FROM (SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.k) ORDER BY f.article_id DESC LIMIT r.l OFFSET r.o) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY p.id DESC) x ON true
```

### 3.10 The two list counts

Each count is folded into its list statement above. Standalone and comparison forms, with *measured* cost per
execution from a 2000-row LATERAL loop (`sqlcheck/cnt.sql`, `fcnt.sql`):

| Count | Best text | µs | Alternatives (µs) |
|---|---|---|---|
| global (SPEC.md:155) | C `CountAll`, `C/src/Sql.cs:92-94` (needs `r.i >= 0` when batched) | **48** | R `count(*) … ORDER BY id LIMIT 1000` 60; SPEC (no ORDER BY) 57 |
| tag | R `CASE WHEN EXISTS (… OFFSET 999 LIMIT 1)`, `R/src/sql.rs:50` | **49** (popular tag) | C/SPEC plain `LIMIT 1000` 58 |
| author / favorited | plain `LIMIT 1000` (`C/src/Sql.cs:98-101`, `R/src/sql.rs:57-58, 62`) | (≪1000 rows) | |
| feed | C `CountFeed`, `C/src/Sql.cs:102-104` | **68** | R with `ORDER BY a3.author_id, a3.id DESC` 68; SPEC `IN` 68 (all equal) |

Global, C# (inside the batch):
```sql
CASE WHEN EXISTS (SELECT 1 FROM articles c WHERE r.i >= 0 ORDER BY c.id OFFSET 999) THEN 1000 ELSE (SELECT count(*) FROM articles c WHERE r.i >= 0) END
```
Feed, C#:
```sql
(SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id = ANY (ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)) LIMIT 1000) s)
```
The global and tag counts cost about 50 µs per list request. Inside a list request that is the largest single part:
*EXPLAIN ANALYZE* shows the 1000-entry index-only scan plus aggregate at 0.152 of the 0.232 ms per request in the R
batch. No correct O(1) proof exists without caching. COBOL's "infer the total from a short page" trick
(`others.md` §2.4) is the only further saving: a page with `0 < rows < limit` has total = offset + rows, capped at
1000. It helps author/favorited pages, not the global or tag list.

### 3.11 GET /api/articles/feed (auth required)

**(a)** R `LIST_FEED`, `R/src/sql.rs:69-72`. `$1 int8` viewer, `$2 int8` limit, `$3 int8` offset, `$4 int8` =
limit + offset, computed saturating in the app (`R/src/api.rs:541-542`). Result: the list layout.
```sql
WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles a3 WHERE a3.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)) ORDER BY a3.author_id, a3.id DESC LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id ORDER BY a3.id DESC LIMIT $4) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.id) a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC
```
**(b)** C s10 (`C/src/Sql.cs:102-104, 139-142`). Params `$1 int4[]`, `$2 int8[]` viewer, `$3 int4[]` limit,
`$4 int8[]` offset. Result: the C# list layout.
```sql
SELECT r.i, c.n, x.* FROM unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[]) AS r(i, v, l, o) CROSS JOIN LATERAL (SELECT (SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id = ANY (ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v)) LIMIT 1000) s) AS n OFFSET 0) c LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, true AS following FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (r.l::bigint + r.o::bigint)) x WHERE fo.follower_id = r.v ORDER BY x.id DESC LIMIT r.l OFFSET r.o) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY p.id DESC) x ON true
```
- `true AS following` (`C/src/Sql.cs:34`) is correct because every page row was selected through
  `follows fo WHERE fo.follower_id = viewer` **in the same statement snapshot**. Go measured it as 3% of feed PG
  CPU (`G/src/sql.go:117-120`). *Measured*: the C# feed shape runs 2402-2455 tps against 2231-2277 for R.
- C# clamps offset to `long.MaxValue/2`, so `r.l::bigint + r.o::bigint` can't overflow (`csharp.md` §5.2).
- R never uses the shared form for the feed, since pages depend on the viewer (`R/src/read_batch.rs:69-72`).

R batched:
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::bigint[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord) CROSS JOIN LATERAL (WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles a3 WHERE a3.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.p1)) ORDER BY a3.author_id, a3.id DESC LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = r.p1),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id ORDER BY a3.id DESC LIMIT r.p4) x WHERE fo.follower_id = r.p1 ORDER BY x.id DESC LIMIT r.p2 OFFSET r.p3) p JOIN articles a2 ON a2.id = p.id) a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) q ORDER BY r.ord, q.id DESC
```

### 3.12 GET /api/articles/:slug (auth optional)

**(a)** C s11 `ArticleBySlug`, `C/src/Sql.cs:37-38, 144`. `$1 int8` viewer, `$2 text` slug. Result: the full
article layout. No row → 404.
```sql
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = $1 AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, (SELECT true FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) IS NOT NULL AS following FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2
```
`(SELECT true …) IS NOT NULL` probes can't become a hashed subplan over all of the viewer's rows (`C/src/Sql.cs:22-23`).
R's `ARTICLE_BY_SLUG` (`R/src/sql.rs:76-80`) uses EXISTS and is equally fast for one row.

**(b)** C s2 (`C/src/Sql.cs:123`). Params `$1 int4[]`, `$2 int8[]` viewer, `$3 text[]` slug. Result:
`r.i, <full article>`. *Measured*: 16 requests take 0.31 ms, about 20 µs each.
```sql
SELECT r.i, x.* FROM unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, k) CROSS JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, (SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = a.author_id) IS NOT NULL AS following FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = r.k) x
```
R batched:
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::text[]) WITH ORDINALITY AS r(p1,p2,ord) CROSS JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = r.p1),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id) FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = r.p2) q
```

### 3.13 POST /api/articles: write

**(a)** R `ARTICLE_CREATE`, `R/src/sql.rs:102-117` (identical to `G/src/sql.go:189-204`). `$1 int8` author,
`$2 text` title, `$3 text` description, `$4 text` body, `$5 text[]` tagList (deduplicated in SQL; `'{}'` when
absent or null). Result: the full article layout (`0::bigint`, `false`). Returns 201.
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
- One statement is one atomic transaction (SPEC.md:179 requires one transaction). The slug is SPEC's SLUGIFY in SQL,
  so it is byte-identical to the reference (SPEC.md:84).
- Only missing tags are inserted, in name order, so no sequence values are burned and concurrent creates inside one
  statement can't deadlock. `ON CONFLICT … DO UPDATE … RETURNING` returns a tag that another transaction committed
  after this snapshot (`sql.rs:98-101`).
- In a group transaction, a later statement's snapshot sees tags an earlier member inserted (same transaction), so
  `existing` finds them.
- **Deadlock risk across groups:** groups A and B on the two write connections can insert new tags x and y in
  opposite order, giving 40P01. Treat it like any failed group: roll back and retry each request alone
  (`R/src/writer.rs:246-287`).
- `following` is computed with EXISTS (a user may follow themselves).

### 3.14 PUT /api/articles/:slug: write

**Option 1** (the R pattern, consistent with favorites): R `ARTICLE_UPDATE`, `R/src/sql.rs:120-125`. `$1 text` slug,
`$2 text?` title, `$3 text?` description, `$4 text?` body, `$5 int8` viewer. Result: `id int8, author_id int8, updated int8`.
No row → 404. author_id ≠ viewer → 403. Otherwise, after commit, read back with ARTICLE_BY_ID batched (3.16).
```sql
WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
       updated_at = now()
       WHERE id = (SELECT id FROM t WHERE author_id = $5) RETURNING 1)
SELECT t.id, t.author_id, (SELECT count(*) FROM w) FROM t
```
**Option 2** (one statement, no read-back): G `stArticleUpdate`, `G/src/sql.go:205-217`, with the same params.
Result: `author_id, then the full article layout (NULL unless updated)`.
```sql
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
FROM t LEFT JOIN w ON true LEFT JOIN users u ON u.id = w.author_id
```
- A title change regenerates the slug as `SLUGIFY(title)-id`. The title is stored verbatim, untrimmed, with
  null meaning unchanged (conformance §J.61-62). `tagList` in the body is ignored.
- Option 2's tags, fc and flags come from the statement snapshot, which the UPDATE doesn't change
  (`G/src/sql.go:205-208`).
- C# instead uses `UPDATE … WHERE slug = $2 AND author_id = $1 RETURNING` and makes a second round trip
  `SELECT author_id FROM articles WHERE slug = $1` only when 0 rows come back (`C/src/Sql.cs:165-174`). That costs an
  extra round trip on 403/404.

### 3.15 DELETE /api/articles/:slug: write

**(a)** R `ARTICLE_DELETE`, `R/src/sql.rs:128-130` (identical to `G/src/sql.go:219-222`). `$1 text` slug,
`$2 int8` viewer. Result: `author_id int8`. No row → 404. author_id ≠ viewer → 403. Otherwise 204 with an empty body.
Cascades come from the schema (`schema.sql:45,53,61`).
```sql
WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2))
SELECT author_id FROM t
```

### 3.16 / 3.17 POST and DELETE /api/articles/:slug/favorite: write

**Recommended** (R, `R/src/api.rs:640-659`): on the write connection, R `FAVORITE` / `UNFAVORITE`
(`R/src/sql.rs:90-96`). `$1 int8` viewer, `$2 text` slug. Result: `id int8`. No row → 404.
```sql
WITH t AS (SELECT id FROM articles WHERE slug = $2),
 w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING)
SELECT id FROM t
```
```sql
WITH t AS (SELECT id FROM articles WHERE slug = $2),
 w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t))
SELECT id FROM t
```
Then, **after the group's commit (ReadyForQuery)**, R `ARTICLE_BY_ID` on the read path, batched. Params `$1 int8[]`
viewer, `$2 int8[]` id. Result: the full article layout plus `__request_id`.
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::bigint[]) WITH ORDINALITY AS r(p1,p2,ord) CROSS JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = r.p1),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id) FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = r.p2) q
```
(Non-batched `ARTICLE_BY_ID`, `R/src/sql.rs:82-86`: `$1 int8` viewer, `$2 int8` id.) Read back by **id**, not by
slug, so a concurrent title edit can't produce a false 404.

**Alternative, one statement** (G `stFavorite` / `stUnfavorite`, `G/src/sql.go:225-232`): the write plus the full
article, with the count corrected for the statement snapshot (`+/- (SELECT count(*) FROM w)`) and favorited as the
constant true/false.
```sql
WITH t AS (SELECT id, slug, title, description, body, created_at, updated_at, author_id FROM articles WHERE slug = $2),
 w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING RETURNING 1)
SELECT t.id, t.slug, t.title, t.description, t.body, t.created_at, t.updated_at,
 ARRAY(SELECT (SELECT tg.name FROM tags tg WHERE tg.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = t.id ORDER BY name),
 (SELECT count(*) FROM favorites f WHERE f.article_id = t.id) + (SELECT count(*) FROM w), true,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = t.author_id)
FROM t JOIN users u ON u.id = t.author_id
```
```sql
WITH t AS (SELECT id, slug, title, description, body, created_at, updated_at, author_id FROM articles WHERE slug = $2),
 w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t) RETURNING 1)
SELECT t.id, t.slug, t.title, t.description, t.body, t.created_at, t.updated_at,
 ARRAY(SELECT (SELECT tg.name FROM tags tg WHERE tg.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = t.id ORDER BY name),
 (SELECT count(*) FROM favorites f WHERE f.article_id = t.id) - (SELECT count(*) FROM w), false,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = t.author_id)
FROM t JOIN users u ON u.id = t.author_id
```
Trade-off: G saves a round trip but runs the full article read (about 70-100 µs, not batched) inside the write group
transaction. R's write is about 30 µs plus a batched read of about 20 µs, so less PG CPU. G's count is off by one only
when *the same user* sends a concurrent duplicate. That can't happen with one keep-alive connection per VU, which
sends requests sequentially.

C#'s third option: `FavoriteInsert`/`FavoriteDelete` plus s11 in **one Sync group** (`C/src/Sql.cs:178-181`). The
second statement takes a new READ COMMITTED snapshot and sees the insert.

### 3.18 GET /api/articles/:slug/comments (auth optional)

**(a)** C `CommentsSql` per-request text (`C/src/Sql.cs:219-229`, valid as is with `$1 int8` viewer, `$2 text` slug).
Result: `a.id int8, comment_id int8, body, created_at, updated_at, username, bio, image, following bool`.
**0 rows → 404.** One row with NULL `comment_id` → `{"comments":[]}`.
```sql
SELECT a.id, c.id AS comment_id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
       c.author_id = ANY (f.ids) AS following
  FROM articles a
  CROSS JOIN LATERAL (SELECT ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) AS ids) f
  LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c
                      WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
  LEFT JOIN users u ON u.id = c.author_id
 WHERE a.slug = $2
 ORDER BY c.created_at DESC, c.id DESC
```
- The viewer's followee ids are read once per request, and `= ANY (f.ids)` is checked per comment. When the viewer is
  0 the array is empty, which gives false.
- *Measured* single (uniform random article): C 9638-9791 tps; per-row EXISTS 8876-9416; R `COMMENTS_LIST_SET`
  (hashed `IN`, `R/src/sql.rs:143-150`, R's default via `R/start.sh:9`) 7388-7836.
- Cap: the newest 100 by `created_at DESC, id DESC` (SPEC.md:234-237, 271).

**(b)** C s3 (`C/src/Sql.cs:124`). Params `$1 int4[]`, `$2 int8[]` viewer, `$3 text[]` slug. Result: `r.i, <the above>`.
*Measured*: 16 requests take 0.53 ms, about 33 µs each. R does not batch comments at all; it only pipelines them in
the same Sync (`rust-tokio.md` §2.5).
```sql
SELECT r.i, x.* FROM unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, k) CROSS JOIN LATERAL (SELECT a.id, c.id AS comment_id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
       c.author_id = ANY (f.ids) AS following
  FROM articles a
  CROSS JOIN LATERAL (SELECT ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS ids) f
  LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c
                      WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
  LEFT JOIN users u ON u.id = c.author_id
 WHERE a.slug = r.k
 ORDER BY c.created_at DESC, c.id DESC) x
```
*Verified*: the followee ARRAY runs as an InitPlan once per request that has an article (loops=2 of 3 when one slug
is unknown), with no Memoize. A viewer who follows a lot (922 followees) reads all of them even for 6 comments. That
is rare (lognormal mean 20).

### 3.19 POST /api/articles/:slug/comments: write

**(a)** R `COMMENT_CREATE`, `R/src/sql.rs:153-156` (identical to `G/src/sql.go:235-239`). `$1 text` slug,
`$2 int8` viewer, `$3 text` body. Result: `id int8, body, created_at, updated_at, username, bio, image`. No row → 404.
Returns 201 with `author.following = false` (SPEC.md:247). Validate the body (422) **before** the lookup
(conformance §I.52).
```sql
WITH t AS (SELECT id FROM articles WHERE slug = $1),
 c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM t
       RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id
```
`createdAt == updatedAt` holds because both columns default to the same `now()`. Inside a group transaction `now()`
is the transaction start, the same for every member. That is harmless, because comments sort by `created_at DESC, id DESC`.

### 3.20 DELETE /api/articles/:slug/comments/:id: write

**(a)** R `COMMENT_DELETE`, `R/src/sql.rs:159-163` (identical to `G/src/sql.go:240-244`). `$1 int8` comment id,
`$2 text` slug, `$3 int8` viewer. Result: `author_id int8`. A non-digit or overflowing `:id` → 404 without SQL.
No row → 404, which also covers a comment that exists on another article. author_id ≠ viewer → 403. Otherwise 204.
```sql
WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
                WHERE c.id = $1 AND a.slug = $2),
 w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3))
SELECT author_id FROM t
```

---

## 4. Batched LATERAL/unnest: wrapper rules and verified subtleties (b)

### 4.1 Wrappers (verbatim)
- C#, point reads (`C/src/Sql.cs:81-82`): `"SELECT r.i, x.* FROM " + Unnest(l) + " CROSS JOIN LATERAL (" + Bind(perRequest, l) + ") x"`.
- C#, lists (`C/src/Sql.cs:86-88`): `"SELECT r.i, c.n, x.* FROM " + Unnest(l) + " CROSS JOIN LATERAL (SELECT " + Bind(count, l) + " AS n OFFSET 0) c " + "LEFT JOIN LATERAL (" + Bind(page, l) + ") x ON true"`.
- C# `Unnest`/OIDs (`C/src/Sql.cs:48-64`):

| Layout | unnest | per-request `$1,$2,$3,$4` become |
|---|---|---|
| None (tags) | `unnest($1::int4[]) AS r(i)` | none |
| Viewer (user) | `unnest($1::int4[], $2::int8[]) AS r(i, v)` | r.v |
| ViewerKey (article, comments, profile) | `unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, k)` | r.v, r.k |
| List (all, feed) | `unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[]) AS r(i, v, l, o)` | r.v, r.l, r.o |
| ListKey (author, tag, favorited) | `unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[]) AS r(i, v, l, o, k)` | r.v, r.l, r.o, r.k |

  Arrays are written as `i[]` = 0..N-1, then v[], l[], o[], k[] (`C/src/Batch.cs:152-184`): 1-D, lower bound 1,
  has-null flag 0, no NULL elements. A binary array is `Int32 ndim=1, Int32 hasnull=0, Int32 elemOid, Int32 n, Int32 lbound=1`
  followed by `Int32 len + bytes` per element (`C/src/Pg.cs:171-188`). Routing: `i = row.Int4(0)`, bounds-checked
  (`C/src/Batch.cs:186-190`).
- R (`R/src/read_batch.rs:60-68`): `SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],…) WITH ORDINALITY AS r(p1,…,pn,ord) CROSS JOIN LATERAL (<original with $N→r.pN>) q`,
  plus ` ORDER BY r.ord, q.id DESC` for lists. The rewrite replaces whole `$N` tokens only, so `$1` never matches
  inside `$10` (`read_batch.rs:44-59`). Types: INT8→`bigint[]`/1016, TEXT→`text[]`/1009 (`read_batch.rs:34-43`).
  Array header: has-null flag **1**, lbound 1 (`read_batch.rs:209-266`). Routing uses the last column, 1-based.
- Max batch size: C# 64 (`C/src/Program.cs:29`), R 32 (`R/src/writer.rs:192-199`). One generic plan serves every N,
  because the arrays are parameters.

### 4.2 Subtleties (all checked with EXPLAIN ANALYZE on the full seed)

1. **`r.i >= 0` tie.** Any subquery in the per-request text that references **no** request column becomes an
   uncorrelated InitPlan, run once per statement and shared by every request. C s6 with the tie shows
   `InitPlan 1 … loops=3` for 3 requests. With `WHERE r.i >= 0` removed it shows `loops=1`
   (`sqlcheck/q1.sql`, `q1b.sql`). Two places need it: `CountAll` and Tags (`C/src/Sql.cs:11-12, 92-94, 121`).
   R's LIST_ALL count needs no tie in the *plain* batched form, because the count is a FROM-subquery inside the
   LATERAL and is rescanned per request (`Aggregate loops=16` for 16). It is shared in R's *shared* form
   (`Aggregate loops=1`, 3.9.1).
2. **`OFFSET 0` fence** (`C/src/Sql.cs:85`). Without it the count subquery is pulled up into the target list and runs
   **once per output article row** (`SubPlan 1 … loops=30` for 3×10 rows instead of 3; `sqlcheck/q1c.sql`), and
   execution time goes from 1.06 to 2.75 ms.
3. **Memoize off** (`C/src/Program.cs:9-14`). It is a rules safeguard: with Memoize, a parameterized inner lookup
   such as `users u ON u.id = a.author_id` could be served from a cache filled by another request in the same
   execution. None of the tested plans use Memoize anyway (§1).
4. **Probes, not EXISTS, inside batches.** In R's batched LIST_ALL the planner turned
   `EXISTS (SELECT 1 FROM follows … fo.followee_id = a.author_id)` into a hashed subplan rebuilt per request from
   **all** of the viewer's follows (`Index Only Scan using follows_pkey … Index Cond: (follower_id = r.p1) rows=90 loops=16`).
   C#'s `(SELECT true FROM … ) IS NOT NULL` form is always one PK probe per row (`C/src/Sql.cs:22-25, 31`).
5. **Per-request snapshot semantics.** One batched statement has one READ COMMITTED snapshot for all N requests.
   Several executions inside one Sync each take their own snapshot (R: `R/README.md:9`,
   `R/src/bin/group-check.rs:146-180`). A request is batched only after it has arrived, and write responses are sent
   only after COMMIT, so every request reads data at least as fresh as its arrival (read-your-writes holds). R's
   read actor never sends a new batch on a connection until the previous round trip completes (`R/src/writer.rs:201-245`).
   C# keeps one statement per read connection (`DISPATCH_DEPTH 1`, `C/src/Program.cs:46`).
6. **Empty results.** Lists: a `LEFT JOIN LATERAL … ON true` row `(i, n, NULL…)` carries the count of an empty page.
   Comments: a row `(i, a.id, NULL…)` means an existing article with no comments. No row for a given `i` means 404.
   R's batched lists keep this, because the `c LEFT JOIN` is inside the LATERAL (`rust-tokio.md` §1.16).
7. **Order within a request.** C# relies on nested-loop order: the Function Scan outer, then the inner subquery's own
   `ORDER BY`, with no outer sort. R adds `ORDER BY r.ord, q.id DESC`, which costs an Incremental Sort. If you follow
   C#, a defensive check in the app is cheap (lists by id DESC; comments by created_at DESC, id DESC).
8. **One bad parameter fails the whole batch.** C# answers 500 to every request in a failed batch
   (`C/src/Handlers.cs:388-396`, `BatchDone`). R retries each job alone (`R/src/writer.rs:224-244`). PostgreSQL `text` rejects
   NUL bytes and invalid UTF-8. So **before batching**, answer 404 for any slug or username containing `%00` or
   invalid UTF-8 (no such row can exist), or retry individually as R does.
9. **Per-request InitPlans are fine.** `ARRAY(SELECT … WHERE … = r.v)` inside the LATERAL becomes an InitPlan
   re-evaluated when r.v changes, so once per request (`loops = N`), not per row (R LIST_FAVORITED, C s3 comments).
10. **Rows are routed back by request.** Within one statement, rows of different requests never interleave in C#'s
    nested loop, but route by `r.i`/ordinal anyway, never by position.

### 4.3 Sharing a Sync between kinds (R)
R puts all executions of a drained actor batch into **one** write followed by one Sync, for example
`10 ArticleSlug + 8 Comments + 6 ListAll + 5 Tags + 3 Profile → 12 executions`. It demultiplexes them by counting
CommandComplete. If one fails, it retries each job alone (`R/src/writer.rs:291-419`, `rust-tokio.md` §2.2). C# sends
one kind per connection per round trip and picks the kind whose oldest request has waited longest
(`C/src/Batch.cs:31-56`).

### 4.4 Batched profile (R form, for completeness)
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::text[]) WITH ORDINALITY AS r(p1,p2,ord) CROSS JOIN LATERAL (SELECT u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = u.id)
FROM users u WHERE u.username = r.p2) q
```

---

## 5. Write path: group commit (d)

- **Separate write connections**, so no read ever waits behind a WAL flush (`C/README.md:41-43`, `G/src/db.go:5-6`).
- **Group commit, one round trip (G and rust-mio):** send N × (Bind/Execute) and **one Sync**, with no BEGIN. The
  extended protocol runs them as one implicit transaction that commits at Sync. On any error, the backend skips to
  Sync and rolls everything back. Then resend each request alone, each with its own Sync, so only the bad one fails
  (`G/src/db.go:8-31, 538-552`). R does the same with explicit `BEGIN` … pipelined statements … `COMMIT`, which takes
  3 round trips (`R/src/writer.rs:246-287`), and replies only after COMMIT's ReadyForQuery.
- **Never replay a write whose commit is uncertain** (the connection was lost after it was sent): answer 500
  (`G/src/db.go:620-640`; R: "uncertain commits are never retried", `R/README.md:10`).
- **Window:** when no write is in flight, wait up to 1 ms for company, then drain up to 128 (`R/src/writer.rs:184-214`;
  G `WRITE_LINGER` 1 ms, `WRITE_BATCH` 128, `G/src/db.go:82,100`). Under load the queue is never empty, so there is
  no wait.
- **Every write endpoint is one statement**, so none needs a connection to itself. 403/404 are decided from the
  returned `author_id`/row, and the mutation is guarded in SQL (`WHERE … author_id = viewer`).
- **Statements that can fail in normal operation** are made error-free: register (`ON CONFLICT DO NOTHING`) and user
  update (clash CTE). The rest fail only rarely: create article (40P01 deadlock across groups), favorite or comment on
  an article deleted concurrently (23503; C# maps that to 404, `csharp.md` §1.8), and a concurrent user-update clash
  (23505). All of them go through rollback, then individual retry.
- `now()` is the transaction start, the same for all members of a group (`rust-tokio.md` §3.1). That is harmless.
- A write's read-back (favorite, update option 1) goes to the **read** path after the commit reply (`R/src/api.rs:640-659`).
- Volume at 100k users: about 5% of 26.3k req/s ≈ 1.3k writes/s (WORKLOAD.md:63-64). With 2 write connections each
  group holds a few requests.

---

## 6. Connection layout for the 8-core box (e)

| Entry | Read | Write | Total | Notes |
|---|--:|--:|--:|---|
| R #1 | 6 | 2 | 8 | `R/src/main.rs:75-76` (`ceil(3·cores/4)`, `ceil(cores/4)`); 2 Tokio workers (`main.rs:61`); one batch in flight per read actor |
| C #2 | 12 | 16 | 28 | `C/src/Program.cs:41`; one statement in PG per read connection (`DISPATCH_DEPTH 1`); at most 6 connections per kind (`Program.cs:30`) |
| rust-mio #6 | 6 | 2 | 8 | "with 16 backends … a request cost ~19% more CPU" (`others.md` §3.3) |
| c-iouring #3 | 32 total | | 32 | FIFO, depth 16 per conn; "24 beat 16; 48/90 worse" (`others.md` §3.1) |
| go #10 | 20 | 2 | 22 | "95 raised p99 17x" (`others.md` §3.4) |

**Recommendation:** start with **6 read + 2 write = 8 backends** (R's layout), configurable by env (`DB_CONNS`,
`DB_WRITE_CONNS`), and A/B 8+2 and 12+2. Postgres should get about 5.6 of the 8 cores (70% PG / 20% app at #1,
`LEADERBOARD.md:7`). More backends than PG's cores add context switches without adding throughput. Reads use
connection-driven dispatch with no timer: when a read connection's ReadyForQuery arrives, ship the oldest-waiting
kind's whole queue (up to 64) as one batched statement (C#). Optionally also pack the other queued kinds into the same
Sync (R, 4.3). Cap each kind at about 4 of the 6 connections, so one slow kind can't starve the rest. Login and
GET /api/user go on the read path. Total connections must stay ≤ 95 (SPEC.md:20-21).

**Limits that sit near 64k (the user's concern), with the box values:**
- **fds:** the service gets `LimitNOFILE=200000`, soft = hard (`box/challenge.service:19`, SPEC.md:26). Outside
  systemd the soft limit is often 1024 or 65536. In this sandbox it is 20000 hard and can't be raised (`ulimit -n`
  shows 20000/20000). On the JVM, `-XX:+MaxFDLimit` (the default) raises soft to hard; check
  `/proc/<pid>/limits`. Kotlin/Native must call `setrlimit(RLIMIT_NOFILE, {hard, hard})` itself.
- **Ephemeral ports:** `ip_local_port_range = 1024 65535` (`box/sysctl.conf:4`) gives about 64.5k connections per
  (load-box IP → server ip:port). The loadgen gets past that by dialing several target IPs (`bench/README.md:73-75`,
  `others.md` §4.3). **Bind `0.0.0.0`** (SPEC.md:15) so every address works.
- **Backlog:** `somaxconn = tcp_max_syn_backlog = 65535` (`box/sysctl.conf:2-3`). Java `ServerSocketChannel.bind(addr)`
  defaults to a backlog of 50, so pass 65535. Dropped SYNs cost 1 s and 3 s retransmits, which ruins p99.
- **Runtime or table caps at 65536:** COBOL closes any fd ≥ 65536 (`others.md` §3.2), and Erlang's default port
  limit is 65536 (`others.md` §4.2). Never size an fd-indexed table at 65536.
- **`vm.max_map_count = 65530`** (kernel default, not raised by `box/setup-box.sh`; 65530 here too). There must be no
  thread per connection and no ≥128 KiB malloc per connection.
- Score ladder: probes go 500 → … → 64k → 120k (`-max 120000`, `bench/README.md:99`). An entry that fails 64k is
  bisected inside 32k-64k, so anything that caps near 64k lands the score below 64k.
- None of this touches Postgres: the server holds only 8 PG sockets.

---

## 7. Measurements (local lab; compare variants only)

| What | Variant: result |
|---|---|
| LIST_ALL single (offset 0-40) | R 0.204 ms · C# shape 0.208 · kotlin-prior 0.259 |
| LIST_ALL batch of 16 | C s6 2.01-2.03 ms · R batched 2.24-2.40 · R shared 1.30-1.40 |
| Tag list batch of 16 | C s8 381-382 tps · C s8 + R count 396-402 · R batched 393-403 · R shared 452-456 |
| Article batch of 16 | C s2 (app sorts tags) 3252-3276 tps · C s2 with ORDER BY 1 3066-3076 · R 3110 |
| Comments single | C array 9638-9791 tps · IS NOT NULL probe 9102-9785 · EXISTS 8876-9416 · R hashed IN 7388-7836 |
| Comments batch of 16 | C s3 1846-1902 tps (≈33 µs/request) |
| Feed single | C# shape 2402-2455 tps · R 2231-2277 · kotlin-prior 2214-2245 |
| Tags | ARRAY 13.4k tps · rows 14.8k · json 14.5k · C s1 batch of 16 2118 (≈30 µs/request) |
| Count per execution | global: C EXISTS-OFFSET-999 48 µs, R ORDER BY id 60, SPEC 57; tag `stun`: R shortcut 49, plain 58; feed: all 68 |

Scripts: `/tmp/claude-0/-home-user-multicore-server-challenge/99796a5c-b120-524c-822d-dc73b94b523b/scratchpad/sqlcheck/`
(`la_*.sql`, `lab_*.sql`, `lt_*.sql`, `ab_*.sql`, `cmb_cs.sql`, `cm_*.sql`, `fd_*.sql`, `tg_*.sql`, `cnt.sql`,
`fcnt.sql`, EXPLAIN scripts `q1*.sql`, `q2.sql`, `lf.sql`, `c3.sql`, `lab_*_explain.sql`). The verbatim statement
files are in `sqlcheck/ex/`.
