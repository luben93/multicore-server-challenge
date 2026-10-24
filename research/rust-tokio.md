# rust-tokio-Scooter1337 (rank #1, 100,000 users): research notes

Target: `/home/user/multicore-server-challenge/submissions/rust-tokio-Scooter1337`. All `file:line` references are relative to that directory unless they start with `box/`, `SPEC.md` or `WORKLOAD.md` (repo root).

Leaderboard row (`LEADERBOARD.md:7`): 100,000 users, 26,279 req/s, p95 119 ms, p99 185 ms, CPU app 20% / Postgres 70%, direct (no Nginx).

## How the SQL text in this file was produced

The SQL below is not hand-copied. I compiled a small Rust program in the scratchpad that `#[path]`-includes the submission's own `src/sql.rs`, and the generator copies `read_batch.rs:146-201` (`shared_list`) and `read_batch.rs:31-68` (the `$N` -> `r.pN` rewrite plus the `unnest ... WITH ORDINALITY` wrapper). It printed the exact strings the server sends to `Parse`. The generator's sources are in `/tmp/claude-0/-home-user-multicore-server-challenge/99796a5c-b120-524c-822d-dc73b94b523b/scratchpad/sqlgen/` (`gen.rs`, outputs `base.sql`, `batched.sql`, `shared.sql`). Newlines and leading spaces inside the SQL are part of the Rust literals; Postgres ignores them, but they are reproduced exactly.

---

## 0. Architecture in one paragraph

Tokio multi-thread runtime with only **2 worker threads** on 8 cores (`main.rs:60-61`). One accept loop on a single listener, one task per TCP connection. HTTP/1.1 is parsed with `httparse`, and the response JSON is written straight into pooled byte buffers. Postgres runs over a vendored `tokio-postgres` with **6 read and 2 write connections** (`main.rs:75-76`). Each connection is owned by an **actor task** (`writer.rs:83-90, 178-289`) that drains a queue of encoded requests. A read actor turns all queued requests (at most 32) into **one pipelined message with one Sync**. Requests with the same prepared statement are folded into one array-parameterized `unnest ... WITH ORDINALITY ... CROSS JOIN LATERAL` execution, and their rows are routed back by a trailing ordinal column. A write actor wraps all queued writes (at most 128, after waiting up to 1 ms when the queue is empty) in `BEGIN` ... `COMMIT` (group commit). bcrypt runs on 1 blocking thread that interleaves up to 4 hashes. Every query is prepared with `plan_cache_mode = force_generic_plan` and `jit = off`. There are no caches of any kind (`README.md:16`).

---

## 1. SQL, verbatim, grouped by endpoint

### 1.0 Session settings sent on every new connection (read and write)

`db.rs:315-317`, sent with `batch_execute` (simple-query protocol, one `Q` message with two statements):

```sql
SET plan_cache_mode = force_generic_plan; SET jit = off
```

Then every statement is prepared once per connection with `prepare_typed` and explicit parameter types (`db.rs:319-393`). Statement names are `s0`, `s1`, ... (process-wide counter, `vendor/tokio-postgres/src/prepare.rs:59-66`). Every Bind asks for **binary results for all columns** (one result-format code = 1, `vendor/tokio-postgres/src/query.rs:324`) and sends binary parameters (int8 = 8 bytes big-endian, text = raw UTF-8, text[] = binary array).

On **read** connections only, 10 array-batched statements and 4 "shared enrichment" statements are prepared as well (`db.rs:394-402`, `read_batch.rs:14-96`). Every connection, read and write, prepares all 23 base statements.

Conventions (`sql.rs:4`): `$1` is always the viewer (0 = anonymous) in statements that compute `favorited`/`following`. Timestamps are decoded from binary `timestamptz` (int64 microseconds since 2000-01-01, `json.rs:7-19`).

### 1.1 Parameter types per statement (`db.rs:321-392`)

| Const (sql.rs line) | Param types | Used by |
|---|---|---|
| LIST_ALL (43) | INT8 viewer, INT8 limit, INT8 offset | GET /api/articles (no filter) |
| LIST_TAG (50) | INT8 viewer, INT8 limit, INT8 offset, TEXT tag | GET /api/articles?tag= |
| LIST_AUTHOR (57-60) | INT8 viewer, INT8 limit, INT8 offset, TEXT username | GET /api/articles?author= |
| LIST_FAVORITED (62) | INT8 viewer, INT8 limit, INT8 offset, TEXT username | GET /api/articles?favorited= |
| LIST_FEED (69-72) | INT8 viewer, INT8 limit, INT8 offset, INT8 (limit+offset) | GET /api/articles/feed |
| ARTICLE_BY_SLUG (76-80) | INT8 viewer, TEXT slug | GET /api/articles/:slug |
| ARTICLE_BY_ID (82-86) | INT8 viewer, INT8 id | read-back after favorite/unfavorite/update |
| FAVORITE (90-92) | INT8 viewer, TEXT slug | POST favorite |
| UNFAVORITE (94-96) | INT8 viewer, TEXT slug | DELETE favorite |
| ARTICLE_CREATE (102-117) | INT8 viewer, TEXT title, TEXT description, TEXT body, TEXT_ARRAY tags | POST /api/articles |
| ARTICLE_UPDATE (120-125) | TEXT slug, TEXT title?, TEXT description?, TEXT body?, INT8 viewer | PUT /api/articles/:slug |
| ARTICLE_DELETE (128-130) | TEXT slug, INT8 viewer | DELETE /api/articles/:slug |
| COMMENTS_LIST / COMMENTS_LIST_SET (133-150) | INT8 viewer, TEXT slug | GET comments |
| COMMENT_CREATE (153-156) | TEXT slug, INT8 viewer, TEXT body | POST comments |
| COMMENT_DELETE (159-163) | INT8 comment id, TEXT slug, INT8 viewer | DELETE comment |
| PROFILE (165-167) | INT8 viewer, TEXT username | GET profile |
| FOLLOW / UNFOLLOW (169-177) | INT8 viewer, TEXT username | POST/DELETE follow |
| TAGS (179) | (none) | GET /api/tags |
| USER_BY_ID (182) | INT8 id | GET /api/user |
| USER_BY_EMAIL (184-185) | TEXT email | POST /api/users/login |
| USER_INSERT (187-189) | TEXT username, TEXT email, TEXT password_hash | POST /api/users |
| USER_UPDATE (191-195) | INT8 id, TEXT email?, TEXT username?, TEXT hash?, TEXT bio?, TEXT image? | PUT /api/user |

`?` = may be bound as SQL NULL (Rust `Option<String>`).

Column-layout conventions (`sql.rs:74-75, 181`, `api.rs:258-282, 292-313`):
- **Full article row** (ARTICLE_BY_SLUG/ID/CREATE): `id, slug, title, description, body, created_at, updated_at, tags text[], favorites_count int8, favorited bool, username, bio, image, following bool`.
- **List row**: `n (capped count), id, slug, title, description, created_at, updated_at, tags, count, favorited, username, bio, image, following`. With an empty page there is exactly one row: `n` and all other columns NULL. `article_list` (`api.rs:293-313`) reads `n` from column 0 of every row and skips rows whose column 1 (id) is NULL.
- **User row**: `id, username, email, bio, image` (+ `password_hash` for login).

### 1.2 GET /api/articles (list): `api.rs:500-532`

Query parsing (`api.rs:101-150`): the first value of each of `limit, offset, tag, author, favorited` is used. `limit` defaults to 20 and must be ASCII digits in 1..=100, otherwise 422. `offset` defaults to 0 and must be digits only, otherwise 422. Empty filter values count as absent. **Only one filter applies, with precedence tag > author > favorited** (`api.rs:505-513`). Binds are `[viewer, limit, offset]` or `[viewer, limit, offset, filter]`.

#### LIST_ALL (`sql.rs:43-48`)
Uses an API-bounded inner `LIMIT 100 OFFSET $3` for generic-plan cardinality. The count walks the PK from the oldest end (all-visible pages, index-only). Favorite count and viewer membership come from one LATERAL aggregate over `favorites_article_idx`.
```sql
WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 fv.fc,
 fv.fav,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT * FROM (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET $3) bounded ORDER BY bounded.id DESC LIMIT $2) a ON true LEFT JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = $1),false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC
```

#### LIST_TAG (`sql.rs:50-55`)
The capped count skips aggregation when `EXISTS(... OFFSET 999 LIMIT 1)` proves there are at least 1000 rows. The page comes from `article_tags_tag_idx (tag_id, article_id)` before joining `articles`.
```sql
WITH c AS (SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s) END AS n) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 fv.fc,
 fv.fav,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.article_id) a ON true LEFT JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = $1),false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC
```

#### LIST_AUTHOR (`sql.rs:57-60`, built by the `list_stmt!` macro at `sql.rs:27-39` and `article_cols!` at `sql.rs:10-23`)
```sql
WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = $4) LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a2.id DESC LIMIT $2 OFFSET $3) a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC
```

#### LIST_FAVORITED (`sql.rs:62-67`)
The viewer flags are computed **once per request** as `= ANY(ARRAY(subquery))` (an InitPlan), not with a per-row EXISTS.
```sql
WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 COALESCE(a.id = ANY(ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = $1)), false),
 u.username, u.bio, u.image,
 COALESCE(a.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)), false) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.article_id) a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC
```

### 1.3 GET /api/articles/feed: `api.rs:534-547`

Auth required. Binds are `[viewer, limit, offset, limit.saturating_add(offset)]`: `$4` caps how many articles are pulled per followee.

#### LIST_FEED (`sql.rs:69-72`)
```sql
WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles a3 WHERE a3.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)) ORDER BY a3.author_id, a3.id DESC LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id ORDER BY a3.id DESC LIMIT $4) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.id) a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC
```

### 1.4 GET /api/articles/:slug: `api.rs:549-559`

Binds `[viewer, slug]`. No row gives 404.

#### ARTICLE_BY_SLUG (`sql.rs:76-80`)
```sql
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2
```

#### ARTICLE_BY_ID (`sql.rs:82-86`): read-back after favorite/unfavorite/update
```sql
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = $2
```

### 1.5 POST/DELETE /api/articles/:slug/favorite: `api.rs:640-659`

Write connection, binds `[viewer, slug]`. No row gives 404. Otherwise `id = row[0]`; the write lease is dropped, then **ARTICLE_BY_ID `[viewer, id]` runs on a read connection** (ReadKind::ArticleId, so it can batch with other ArticleId reads). Because the write actor answers only after COMMIT's ReadyForQuery, the READ COMMITTED read-back sees the change.

#### FAVORITE (`sql.rs:90-92`)
```sql
WITH t AS (SELECT id FROM articles WHERE slug = $2),
 w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING)
SELECT id FROM t
```

#### UNFAVORITE (`sql.rs:94-96`)
```sql
WITH t AS (SELECT id FROM articles WHERE slug = $2),
 w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t))
SELECT id FROM t
```

### 1.6 POST /api/articles: `api.rs:561-594`

Auth, then body validation: title, description and body must be non-empty strings. `tagList` may be absent or null (empty list), otherwise it must be an array of non-empty strings, else 422. Binds `[viewer, title, description, body, tags::text[]]`. Returns 201 with the row; there is **no read-back**, because the statement returns the full article layout itself (0 favorites, `favorited=false`).

#### ARTICLE_CREATE (`sql.rs:102-117`)
The id comes from `nextval` so the slug `slugify(title)-id` is computed in the same statement. Existing tags are read without locking (`existing AS MATERIALIZED`). Only missing tags are inserted, with `ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING`, which also returns a tag that another transaction created concurrently.
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

### 1.7 PUT /api/articles/:slug: `api.rs:596-624`

Body fields title, description and body are optional; when present they must be non-empty strings, else 422. Binds `[slug, title?, description?, body?, viewer]`. No row gives 404. If `row.author_id != viewer` the result is 403 (the UPDATE only fires when the viewer is the author). Then the write lease is dropped and **ARTICLE_BY_ID `[viewer, id]` runs on a read connection**.

#### ARTICLE_UPDATE (`sql.rs:120-125`)
```sql
WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
       updated_at = now()
       WHERE id = (SELECT id FROM t WHERE author_id = $5) RETURNING 1)
SELECT t.id, t.author_id, (SELECT count(*) FROM w) FROM t
```

### 1.8 DELETE /api/articles/:slug: `api.rs:626-638`

Binds `[slug, viewer]`. No row gives 404, `author_id != viewer` gives 403, otherwise 204.

#### ARTICLE_DELETE (`sql.rs:128-130`)
```sql
WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2))
SELECT author_id FROM t
```

### 1.9 GET /api/articles/:slug/comments: `api.rs:663-689`

Binds `[viewer, slug]`. **Zero rows gives 404.** With an article but no comments there is one row with column 1 NULL, which is skipped. `start.sh:9` sets `READ_COMMENT_SET=1`, so the **_SET** variant is the default (`db.rs:363-370`): the viewer's followee set is computed once per execution (hashed subplan) instead of a per-row EXISTS. Comment layout from column 1: `id, body, created_at, updated_at, username, bio, image`, plus `following` at column 8.

#### COMMENTS_LIST_SET (`sql.rs:143-150`), the default
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

#### COMMENTS_LIST (`sql.rs:133-140`), used when READ_COMMENT_SET != 1
```sql
SELECT a.id, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id)
FROM articles a
LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id
                   ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
LEFT JOIN users u ON u.id = c.author_id
WHERE a.slug = $2
ORDER BY c.created_at DESC, c.id DESC
```

### 1.10 POST /api/articles/:slug/comments: `api.rs:691-706`

Binds `[slug, viewer, body]`. No row gives 404. Returns 201 with `following=false` hard-coded (`api.rs:703`).

#### COMMENT_CREATE (`sql.rs:153-156`)
```sql
WITH t AS (SELECT id FROM articles WHERE slug = $1),
 c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM t
       RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id
```

### 1.11 DELETE /api/articles/:slug/comments/:id: `api.rs:708-721`

`id` must be ASCII digits (else 404). Binds `[id, slug, viewer]`. No row gives 404, `author_id != viewer` gives 403, otherwise 204.

#### COMMENT_DELETE (`sql.rs:159-163`)
```sql
WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
                WHERE c.id = $1 AND a.slug = $2),
 w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3))
SELECT author_id FROM t
```

### 1.12 GET /api/profiles/:username: `api.rs:467-480`

Binds `[viewer, username]`. No row gives 404.

#### PROFILE (`sql.rs:165-167`)
```sql
SELECT u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id)
FROM users u WHERE u.username = $2
```

### 1.13 POST/DELETE /api/profiles/:username/follow: `api.rs:482-496`

Write connection, binds `[viewer, username]`. No row gives 404. **There is no read-back.** The profile comes from the CTE and `following` is the constant `on` (true for POST, false for DELETE), `api.rs:493`.

#### FOLLOW (`sql.rs:169-172`)
```sql
WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
 w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING)
SELECT username, bio, image FROM t
```

#### UNFOLLOW (`sql.rs:174-177`)
```sql
WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
 w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t))
SELECT username, bio, image FROM t
```

### 1.14 GET /api/tags: `api.rs:725-734`

One row with one `text[]` column. The binary array is serialized straight to JSON without allocating (`json.rs:162-198`).

#### TAGS (`sql.rs:179`)
```sql
SELECT ARRAY(SELECT name FROM tags ORDER BY name)
```

### 1.15 Users

GET /api/user (`api.rs:429-438`): USER_BY_ID `[id]`; no row gives 401; the presented token is echoed back.
```sql
SELECT id, username, email, bio, image FROM users WHERE id = $1
```

POST /api/users/login (`api.rs:410-427`): USER_BY_EMAIL `[email]` on a read connection; the lease is dropped (block scope) **before** bcrypt verify; no row or a bad password gives 401.
```sql
SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1
```

POST /api/users (`api.rs:394-408`): bcrypt hash (password over 72 bytes gives 422), then USER_INSERT on a **write** connection; SQLSTATE 23505 gives 422 (`api.rs:34-40`); returns 201.
```sql
INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
RETURNING id, username, email, bio, image
```

PUT /api/user (`api.rs:440-463`): optional fields. email, username and password must be non-empty when present; bio and image may be empty strings. Null or absent means unchanged. A password is bcrypt-hashed first. USER_UPDATE `[id, email?, username?, hash?, bio?, image?]` on a write connection; 23505 gives 422; no row gives 401.
```sql
UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
WHERE id = $1
RETURNING id, username, email, bio, image
```

### 1.16 Array-batched read variants (prepared on every read connection)

Generated by `read_batch.rs:19-84` for these 10 statements: LIST_ALL, LIST_TAG, LIST_AUTHOR, LIST_FAVORITED, LIST_FEED (`ordered = true`), and ARTICLE_BY_SLUG, ARTICLE_BY_ID, PROFILE, USER_BY_ID, USER_BY_EMAIL (`ordered = false`). The recipe:
1. Each scalar parameter `$i` of type INT8 or TEXT becomes an array parameter `$i::bigint[]` / `$i::text[]` with type INT8_ARRAY / TEXT_ARRAY (`read_batch.rs:34-43`).
2. Every `$N` token in the original text is replaced by `r.pN`, matching whole tokens so `$1` never matches inside `$10` (`read_batch.rs:44-59`).
3. Wrapper: `SELECT q.*, r.ord::bigint AS __request_id FROM unnest(<args>) WITH ORDINALITY AS r(p1,..,pn,ord) CROSS JOIN LATERAL (<rewritten original>) q` (`read_batch.rs:60-64`).
4. List statements append ` ORDER BY r.ord, q.id DESC` so each request's rows stay in order after demultiplexing (`read_batch.rs:65-68`).

**Row routing** (`writer.rs:401-409`): the **last column** (`__request_id`, int8, 1-based ordinal into the array) is read with `row.try_get(row.len() - 1)`. Then `pos = id - 1` is bounds-checked and the row is appended to `out[group[pos]]`. The API code reads columns by index and never looks at the extra trailing column. A request that matches nothing gets zero rows. List requests still get their count row, because the original LEFT JOIN from `c` is inside the LATERAL.

**Array parameter construction** (`read_batch.rs:209-266`): the app does not re-encode. It walks each request's already-encoded binary Bind frame and copies the raw `len + bytes` of value *i* into array column *i*. Array header: `ndim=1, has_nulls_flag=1, elem_oid, n=frames.len(), lbound=1`. A NULL element keeps length -1. Kotlin can simply build the arrays directly.

#### LIST_ALL batched
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::bigint[],$3::bigint[]) WITH ORDINALITY AS r(p1,p2,p3,ord) CROSS JOIN LATERAL (WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 fv.fc,
 fv.fav,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT * FROM (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET r.p3) bounded ORDER BY bounded.id DESC LIMIT r.p2) a ON true LEFT JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = r.p1),false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC) q ORDER BY r.ord, q.id DESC
```

#### LIST_TAG batched
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord) CROSS JOIN LATERAL (WITH c AS (SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) LIMIT 1000) s) END AS n) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 fv.fc,
 fv.fav,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) ORDER BY at.article_id DESC LIMIT r.p2 OFFSET r.p3) p JOIN articles a2 ON a2.id = p.article_id) a ON true LEFT JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = r.p1),false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC) q ORDER BY r.ord, q.id DESC
```

#### LIST_AUTHOR batched
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord) CROSS JOIN LATERAL (WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = r.p4) LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = r.p1),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = r.p4) ORDER BY a2.id DESC LIMIT r.p2 OFFSET r.p3) a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) q ORDER BY r.ord, q.id DESC
```

#### LIST_FAVORITED batched
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord) CROSS JOIN LATERAL (WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.p4) LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 COALESCE(a.id = ANY(ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = r.p1)), false),
 u.username, u.bio, u.image,
 COALESCE(a.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.p1)), false) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.p4) ORDER BY f.article_id DESC LIMIT r.p2 OFFSET r.p3) p JOIN articles a2 ON a2.id = p.article_id) a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) q ORDER BY r.ord, q.id DESC
```

#### LIST_FEED batched (feed never uses the shared-enrichment form, `read_batch.rs:69-72`)
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::bigint[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord) CROSS JOIN LATERAL (WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles a3 WHERE a3.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.p1)) ORDER BY a3.author_id, a3.id DESC LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = r.p1),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id ORDER BY a3.id DESC LIMIT r.p4) x WHERE fo.follower_id = r.p1 ORDER BY x.id DESC LIMIT r.p2 OFFSET r.p3) p JOIN articles a2 ON a2.id = p.id) a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) q ORDER BY r.ord, q.id DESC
```

#### ARTICLE_BY_SLUG batched
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::text[]) WITH ORDINALITY AS r(p1,p2,ord) CROSS JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = r.p1),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id) FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = r.p2) q
```

#### ARTICLE_BY_ID batched
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::bigint[]) WITH ORDINALITY AS r(p1,p2,ord) CROSS JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = r.p1),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = a.author_id) FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = r.p2) q
```

#### PROFILE batched
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[],$2::text[]) WITH ORDINALITY AS r(p1,p2,ord) CROSS JOIN LATERAL (SELECT u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = u.id)
FROM users u WHERE u.username = r.p2) q
```

#### USER_BY_ID batched
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::bigint[]) WITH ORDINALITY AS r(p1,ord) CROSS JOIN LATERAL (SELECT id, username, email, bio, image FROM users WHERE id = r.p1) q
```

#### USER_BY_EMAIL batched
```sql
SELECT q.*, r.ord::bigint AS __request_id FROM unnest($1::text[]) WITH ORDINALITY AS r(p1,ord) CROSS JOIN LATERAL (SELECT id, username, email, bio, image, password_hash FROM users WHERE email = r.p1) q
```

### 1.17 Shared-enrichment list variants (`read_batch.rs:146-201`)

These are prepared for LIST_ALL, LIST_TAG, LIST_AUTHOR and LIST_FAVORITED, with the same array parameter types as 1.16. Structure: `requests` (unnest) -> `counted` (per-request capped count) -> `pages` (per-request page ids; `LEFT JOIN LATERAL` keeps empty pages) -> `article_ids` (DISTINCT) -> `enriched` (tags, favorites count and author profile computed **once per distinct article**) -> the final select adds **per-request** viewer flags (`favorited` EXISTS on the `(user_id, article_id)` PK, `following` EXISTS) and `__request_id`. Output columns match the list layout plus the trailing `__request_id`. On an empty page `e.*` is NULL, so `COALESCE(e.tags, ARRAY[]::text[])` / `COALESCE(e.fc, 0::bigint)` produce non-NULL values. `id` stays NULL, so the row is skipped by `article_list`.

**When the shared form is used instead of the plain batch** (`read_batch.rs:100-121`): the group has at least 2 requests and the number of distinct *non-viewer keys* is at most `len/2`. The key is the raw bytes of every Bind value after the first (viewer) one: limit, offset and filter if present (`read_batch.rs:125-142`). If any frame fails to parse, or the first param is not an 8-byte value, sharing is off. Typical trigger: many anonymous or different-viewer requests for `?limit=10&offset=0` on the global feed or the same popular tag.

#### LIST_ALL shared
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

#### LIST_TAG shared
```sql
WITH requests AS MATERIALIZED (
         SELECT * FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord)),
         counted AS MATERIALIZED (
         SELECT r.*, c.n FROM requests r CROSS JOIN LATERAL (SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) LIMIT 1000) s) END AS n) c),
         pages AS MATERIALIZED (
         SELECT r.ord, r.p1 AS viewer, r.n, p.id FROM counted r
         LEFT JOIN LATERAL (SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) ORDER BY at.article_id DESC LIMIT r.p2 OFFSET r.p3) p ON true),
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

#### LIST_AUTHOR shared
```sql
WITH requests AS MATERIALIZED (
         SELECT * FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord)),
         counted AS MATERIALIZED (
         SELECT r.*, c.n FROM requests r CROSS JOIN LATERAL (SELECT count(*) AS n FROM (SELECT 1 FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = r.p4) LIMIT 1000) s) c),
         pages AS MATERIALIZED (
         SELECT r.ord, r.p1 AS viewer, r.n, p.id FROM counted r
         LEFT JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = r.p4) ORDER BY a2.id DESC LIMIT r.p2 OFFSET r.p3) p ON true),
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

#### LIST_FAVORITED shared
```sql
WITH requests AS MATERIALIZED (
         SELECT * FROM unnest($1::bigint[],$2::bigint[],$3::bigint[],$4::text[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord)),
         counted AS MATERIALIZED (
         SELECT r.*, c.n FROM requests r CROSS JOIN LATERAL (SELECT count(*) AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.p4) LIMIT 1000) s) c),
         pages AS MATERIALIZED (
         SELECT r.ord, r.p1 AS viewer, r.n, p.id FROM counted r
         LEFT JOIN LATERAL (SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.p4) ORDER BY f.article_id DESC LIMIT r.p2 OFFSET r.p3) p ON true),
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

### 1.18 Group-commit control statements (write connections)

Sent with `batch_execute` (simple query) by the write actor (`writer.rs:246, 260, 274`):
```sql
BEGIN
```
```sql
ROLLBACK
```
```sql
COMMIT
```

---

## 2. Read batching protocol

### 2.1 Actor per read connection (`writer.rs:83-90, 178-245`)
- `Client::new` creates `mpsc::channel(1024)` and spawns `actor(client, rx, write=false, batches)`, so each read connection is owned by one task. If `READ_BATCH_SIZE=0`, the client is `Mode::Direct`: plain tokio-postgres pipelining with no actor (`writer.rs:84-86`).
- Request submission (`writer.rs:91-135`): the caller encodes `Bind(unnamed portal, stmt sN, binary params, result format binary) + Execute(portal "", max_rows 0)` **once** into a `Bytes` frame (`Client::encode_group_query`, `vendor/tokio-postgres/src/query.rs:426-431`). It sends a `Job{statement, encoded, oneshot reply}` to the channel and awaits the oneshot.
- Actor loop (`writer.rs:201-245`):
  1. `first = rx.recv().await`.
  2. Read delay `READ_BATCH_US` defaults to **0**, so there is **no collection delay**. (The sleep runs only if `delay > 0 && rx.is_empty()`.)
  3. Drain with `try_recv` until `jobs.len() == READ_BATCH_SIZE` (default **32**) or the queue is empty.
  4. A single job is executed alone: one encoded frame + Sync (`writer.rs:218-223`, `162-169`).
  5. Several jobs go to `grouped_reads`. On error, **each job is retried individually and sequentially** (safe because they are read-only; the implicit transaction ended at Sync), `writer.rs:224-244`.
  6. The actor **awaits the whole round trip before draining again**. A connection therefore has at most one batch in flight, and new requests pile up in the channel while it runs. That queue is the batching window ("natural batching", no timer).

### 2.2 Forming executions inside a drained batch (`writer.rs:291-419`)
- If no batch templates exist (`READ_SQL_BATCH=0`), all frames are concatenated and sent with **one Sync** (`writer.rs:297-311`).
- Otherwise, jobs are grouped in arrival order by **prepared statement identity** (`read_batch::same` = pointer equality of the statement's column metadata, `read_batch.rs:203-205`; Kotlin can use the statement id). Only statements that have a `Batch` template are grouped (`writer.rs:319-329`). "Compatible" therefore means **exactly the same prepared statement on the same connection**. LIST_ALL never groups with LIST_TAG; each family is its own execution.
- For each group:
  - **broadcast** (only TAGS when `READ_TAG_BATCH != 0`, which is the default, `read_batch.rs:85-94`): one execution of the plain TAGS statement, whose rows are cloned to every waiting requester (`writer.rs:388-396`). This is safe only because all recipients were already queued before execution; nothing is retained afterward.
  - **coalesced** (group size above 1 with a template): build the arrays, pick `shared` or the plain batched statement (`read_batch::statement`, `read_batch.rs:100-105`), and produce one Bind/Execute (`writer.rs:349-370`).
  - Otherwise (a single job, or COMMENTS, which has no template): the original frame unchanged.
- **All executions of the drained batch are concatenated into one buffer followed by one Sync** (`query_group_encoded`, `vendor/tokio-postgres/src/query.rs:432-461`): a single write and a single round trip. Results are demultiplexed by counting `CommandComplete` messages. On `ReadyForQuery`, the call returns, or reports the first error if any. Errors are drained up to ReadyForQuery before the connection is reused. All executions share one implicit transaction, and under READ COMMITTED each statement takes its own snapshot (`README.md:10`, `src/bin/group-check.rs:146-180`).
- Example: a drained batch of 32 = 10 ArticleSlug + 8 Comments + 6 ListAll + 5 Tags + 3 Profile becomes 1 + 8 + 1 + 1 + 1 = **12 executions in one message**.
- Maximum batch size is **32** (READ_BATCH_SIZE). The write limit is a hard-coded 128 (`writer.rs:192-199`).

### 2.3 Routing requests across read connections (`db.rs:190-300`)
Each `Conn` has an atomic `load` (in-flight leases: queued plus executing) and `families[12]` (in-flight leases per `ReadKind`). A `Lease` increments both counters and decrements them on drop (`db.rs:94-114`). Handlers hold the lease until rows are collected and then `drop(c)` before JSON serialization in most handlers.

ReadKinds (`db.rs:69-82`): All, Tag, Author, Favorited, Feed, ArticleSlug, ArticleId, Profile, UserId, UserEmail, Comments, Tags.

`Db::read(family)`:
- **Comments always use `least_loaded`** (no array form). Tags use `least_loaded` unless `READ_TAG_ROUTE=1`, which `start.sh:8` sets, so Tags use family routing by default.
- Otherwise `compatible(pool, family, slack)` with `slack = READ_ROUTE_SLACK` (default **8**, capped at 64; `off` means plain least-loaded). Family routing is disabled when READ_BATCH_SIZE=0 or READ_SQL_BATCH=0 (`db.rs:131-142`).

`least_loaded` (`db.rs:212-241`): scan from a rotating start index (global `AtomicUsize` that increments per call), skip closed connections, pick the minimum `load`, and stop early at load 0.

`compatible` (`db.rs:245-287`):
1. First pass: find `minimum` load and the `least` index (rotating start).
2. Second pass: `selected = least, best_load = minimum, best_matches = 0`. For each healthy connection, call `prefer(load, matches=families[family], minimum, slack, best_load, best_matches)`:
   ```rust
   load <= minimum.saturating_add(slack)
       && (matches > best_matches || matches == best_matches && load < best_load)
   ```
   (`db.rs:289-300`). The pick is the connection with the **most in-flight requests of the same family**, among connections whose load is within `slack` of the least-loaded one. Ties go to lower load, then to rotation order.
3. Increment `load` and `families[family]`.

This tends to put same-family requests on the same connection, so a drained batch contains larger same-statement groups and therefore fewer executions. The README reports gains of +4.38% and +1.71% at 100k users (`README.md:29`).

### 2.4 How list pages share enrichment
- Sharing happens **only within one execution of one family** (for example 12 LIST_ALL requests in a batch). It uses the `*_SHARED` SQL from 1.17, and only when the distinct (limit, offset, filter) keys are at most half the group size.
- Per distinct article id, the tags array, the favorites count and the author username/bio/image are computed once (`enriched AS MATERIALIZED`). Per request row, only `favorited` and `following` EXISTS checks run, using `p.viewer`.
- Counts are materialized per request (`counted AS MATERIALIZED`) before joining pages (`README.md:10`: "Counts are materialized before joining pages").
- Feed is excluded because pages depend on the viewer (`read_batch.rs:69-72`). It still gets the plain array batch.
- README measurements: shared enrichment +1.41% and +3.19% at 100k (`README.md:25`).

### 2.5 Which endpoints can share a read execution
| ReadKind | Statement | Array batch | Shared enrichment | Routing |
|---|---|---|---|---|
| All | LIST_ALL | yes | yes | family |
| Tag | LIST_TAG | yes | yes | family |
| Author | LIST_AUTHOR | yes | yes | family |
| Favorited | LIST_FAVORITED | yes | yes | family |
| Feed | LIST_FEED | yes | no | family |
| ArticleSlug | ARTICLE_BY_SLUG | yes | n/a | family |
| ArticleId | ARTICLE_BY_ID | yes | n/a | family |
| Profile | PROFILE | yes | n/a | family |
| UserId | USER_BY_ID | yes | n/a | family |
| UserEmail | USER_BY_EMAIL | yes | n/a | family |
| Comments | COMMENTS_LIST_SET | no (but pipelined in the same Sync group) | n/a | least-loaded |
| Tags | TAGS | broadcast (1 execution, rows cloned) | n/a | family (READ_TAG_ROUTE=1) |

---

## 3. Write path (group commit)

### 3.1 Actor per write connection (`writer.rs:178-289`)
- 2 write connections by default (`main.rs:76`). Each is owned by an actor with `mpsc::channel(1024)` (`writer.rs:87-89`). `Db::write()` is plain `least_loaded` over write connections (`db.rs:205-207`).
- Writes are encoded eagerly by the caller into owned binary `Param`s (`writer.rs:103-121`). The actor runs them through `client.query_raw`, which produces **Bind/Execute/Sync per statement** (standard tokio-postgres, `vendor/tokio-postgres/src/query.rs:256-268`).
- Batch window: after `first = rx.recv()`, if `WRITE_BATCH_US > 0` (default **1000 µs**) **and the queue is empty**, sleep 1 ms. Then drain with `try_recv` up to **128** (hard-coded). Under load the queue is already non-empty, so there is no sleep (`writer.rs:184-214`).
- **One job**: executed directly as an implicit, autocommit transaction (`writer.rs:218-223`). There is no BEGIN/COMMIT.
- **Several jobs** (`writer.rs:246-287`):
  1. `BEGIN` (simple query, awaited). If it fails, every job gets the error.
  2. `join_all(execute(job))` pipelines all statements on the connection; each carries its own Sync, and inside the explicit transaction a Sync does not commit.
  3. If **any** statement errored (later ones fail with 25P02 once the transaction is aborted): `ROLLBACK`. If ROLLBACK fails, every job gets the error. Otherwise **retry each job individually and sequentially**, autocommit. This way one duplicate registration (23505) cannot reject the other writes, and deadlocks or serialization errors in the group also recover.
  4. If all succeeded: `COMMIT`. On success each job gets its rows **only after COMMIT's ReadyForQuery** (durable). If COMMIT fails, every job gets the error and **nothing is retried** (an uncertain commit is never replayed).
- That is 3 round trips per group (BEGIN, pipelined statements, COMMIT). Every write is one statement (CTEs), so no handler needs to hold a connection exclusively.
- Note: `now()` inside one group transaction is the same for every row in the group (created_at/updated_at defaults). That is harmless because ordering is by id, and comments order by `created_at DESC, id DESC`.

### 3.2 Which writes are single statements
All of them: USER_INSERT, USER_UPDATE, FOLLOW, UNFOLLOW, FAVORITE, UNFAVORITE, ARTICLE_CREATE (article, tags and article_tags in one CTE), ARTICLE_UPDATE, ARTICLE_DELETE, COMMENT_CREATE and COMMENT_DELETE. Authorization (403) is decided from the returned `author_id`, and the mutation is guarded in SQL by `WHERE ... author_id = viewer`, so no separate SELECT is needed.

### 3.3 Read-back after commit
- **favorite/unfavorite**: the CTE returns the article id; after the write job is answered (post-COMMIT), ARTICLE_BY_ID `[viewer, id]` runs on a **read** connection (`api.rs:649-658`).
- **update article**: the same pattern, ARTICLE_BY_ID after commit (`api.rs:611-623`).
- **follow/unfollow**: no read-back; the profile columns come from the CTE and `following` is the request's constant (`api.rs:482-496`).
- **create article / create comment / user insert / user update**: no read-back; RETURNING / CTE rows give the full response.

### 3.4 Failure and reconnection (`db.rs:151-179`)
A background task runs every 250 ms. For any connection whose driver task ended (`closed` flag set by the spawned connection future, `db.rs:302-312`), it reconnects (5 s timeout), re-runs the SETs and prepares, and swaps the `Arc<Conn>` into the slot. Existing leases finish on the old connection, and nothing is replayed. Routing skips closed connections. During a full outage requests fail fast instead of waiting (`db.rs:236-237`). Startup retries the database connection for up to 50 s every 500 ms (`main.rs:87-98`).

---

## 4. Connection layout, threads, every env knob

Defaults are computed from `available_parallelism()` = cores (`main.rs:60`). Values for 8 cores are in brackets.

| Knob | Default | Where | Meaning |
|---|---|---|---|
| `APP_THREADS` | `min(ceil(cores/4), 8)` [**2**] | `main.rs:61` | Tokio worker threads |
| `DB_CONNS` | `min(ceil(3*cores/4), 16)` [**6**] | `main.rs:75` | read connections |
| `DB_WRITE_CONNS` | `min(ceil(cores/4), 8)` [**2**] | `main.rs:76` | write connections; asserts reads+writes <= 95 (`db.rs:122-125`) |
| `BCRYPT_THREADS` | batch-bcrypt on Linux: `ceil(cores/8)` [**1**]; else `ceil(cores/4)` | `main.rs:77-85` | concurrent bcrypt jobs (semaphore over `spawn_blocking`) |
| `BCRYPT_BATCH_MS` | **160** | `password_batch.rs:21-26` | bcrypt collection window measured from the first job's enqueue time; up to 4 jobs |
| `WRITE_BATCH_US` | **1000** | `writer.rs:184-191` | write group wait, only when the queue is empty |
| `READ_BATCH_US` | **0** | `writer.rs:184-191` | read collection delay (none) |
| `READ_BATCH_SIZE` | **32**; `0` disables read actors (Direct mode) and family routing | `writer.rs:192-199`, `writer.rs:84`, `db.rs:132` | maximum drained read jobs per round trip |
| `READ_SQL_BATCH` | **1**; `0` keeps packed Bind/Execute with one Sync but no array statements | `db.rs:133, 396` | array coalescing on or off |
| `READ_ROUTE_SLACK` | **8** (capped at 64); `off` means least-loaded | `db.rs:135-139` | family-affinity load slack |
| `READ_TAG_ROUTE` | code default off unless `"1"`; **start.sh sets 1** | `db.rs:145`, `start.sh:8` | family routing for GET /api/tags |
| `READ_COMMENT_SET` | code default off unless `"1"`; **start.sh sets 1** | `db.rs:364`, `start.sh:9` | use COMMENTS_LIST_SET |
| `READ_TAG_BATCH` | on unless `"0"`; **start.sh sets 1** | `read_batch.rs:87`, `start.sh:10` | broadcast TAGS to every queued requester |
| `BATCH_TRACE` | unset | `writer.rs:200` | stderr tracing |
| `HOST` / `PORT` | `127.0.0.1` / `3000` (box: `0.0.0.0` / `80` when direct) | `main.rs:73-74` | |
| `DATABASE_URL`, `JWT_SECRET` | required | `main.rs:71-72` | |

Totals on the 8-core box: **8 Postgres connections** (6 read + 2 write), **2 event-loop threads**, **1 bcrypt thread** (Tokio's blocking pool, gated by a semaphore), plus Postgres's 8 backends. Few connections, kept full by pipelining, mean fewer Postgres backend wake-ups (`db.rs:1-11`).

Compile-time features (`Cargo.toml`): `batch-bcrypt`, `group-commit`, `simd-json` and `boxed-requests` are all on by default. Release profile: `lto="fat"`, `codegen-units=1`, `opt-level=3`, mimalloc as the global allocator (`main.rs:25-26`).

### bcrypt details (CPU budget matters)
- Cost 10 (`main.rs:28`). Fresh 16-byte random salt per hash, `$2b$10$` prefix (`password.rs:69-81`). Passwords over 72 bytes give 422 on register/update and `false` on login (`api.rs:347-349, 372-374`).
- Batching dispatcher (`password_batch.rs:19-58`): one task receives jobs, **acquires a permit first** (1 slot), then collects up to 4 jobs until `first.enqueued + 160ms`, then `spawn_blocking(compute)`. compute interleaves 2-4 independent Blowfish states round by round (`native/bcrypt-batch-impl.h`) to hide S-box load latency, falling back to single hashing. Verification uses a constant-time compare.
- Load: 100k users / 900 s mean session = 111 session starts/s; 25% of starts do bcrypt (24.5% login + 0.5% sign-up, `WORKLOAD.md`), so **about 28 bcrypt/s** at 100k users. One core with 4-lane interleaving handles it. A lone login waits up to 160 ms for batch-mates, which is acceptable because logins are about 0.5% of requests.

---

## 5. HTTP server details (`http.rs`, `main.rs`)

### 5.1 Connection lifecycle and idle memory
- One task per accepted connection: `tokio::spawn(http::serve(stream))`, with `TCP_NODELAY` set at accept (`main.rs:120-125`).
- **No buffer while idle** (`http.rs:113-145`): when the input buffer is empty, the code releases it to the pool, awaits `stream.readable()` (readiness only, no buffer), then takes a **1 KiB** input buffer from the pool and calls `try_read_buf`. A spurious WouldBlock loops back and releases the buffer again. EOF or error closes the connection.
- `boxed-requests` feature: `Box::pin(handle_one(...))` (`http.rs:136-139`). The large request state machine is heap-allocated only while a request is active, so the idle per-connection future stays tiny. `parse_head` keeps the `httparse` header scratch (64 headers) off the idle future (`http.rs:308-310`).
- README numbers: **83-124 MiB peak app RSS at 76k-80k users** (`README.md:23-29`), about 1.0-1.6 KB of app RSS per connection (userspace only; kernel socket buffers are not counted).

### 5.2 Buffer pool (`http.rs:14-72`)
- Thread-local (one per Tokio worker), 4 size classes **[1024, 4096, 16384, 65536]**, a **64-slot fixed free stack per class**, and no bookkeeping allocation.
- `take_input()` takes class 0 (1 KiB). `take()` for responses prefers an available 16 KiB, then a 64 KiB, and otherwise takes or allocates **4 KiB**. `release` files a buffer by capacity, drops anything over 64 KiB or any buffer when the class stack is full, and clears it before pooling.
- The response body `Vec` is returned to the pool right after the write (`http.rs:279`). The input buffer grows by `reserve(1024)` per read when needed (`http.rs:76-85`).

### 5.3 Parsing, keep-alive, pipelining, deadline
- Limits: head at most **64 KiB** (`MAX_HEAD`), body at most **16 MiB**, 64 headers (`http.rs:11-12, 310`).
- `Content-Length` must be digits only; a duplicate is rejected. `Transfer-Encoding` must be exactly `chunked` and cannot be combined with CL (`http.rs:328-364`). Chunked bodies with trailers are decoded, and consumed framing is compacted every 64 KiB (`http.rs:169-218`). `Expect: 100-continue` gets an immediate `HTTP/1.1 100 Continue` (`http.rs:164-166`); any other Expect value is rejected.
- Only `Authorization` (one allowed), `Content-Length`, `Transfer-Encoding`, `Connection` and `Expect` are inspected. Header values are kept as byte ranges into the input buffer, so the buffer can grow (`http.rs:318-321, 347-348`).
- Keep-alive: HTTP/1.1 defaults to keep-alive, HTTP/1.0 defaults to close unless `Connection: keep-alive`, and a `close` token closes (`http.rs:326, 349-354`). **The idle keep-alive timeout is unlimited.**
- **Request deadline**: `READ_TIMEOUT = 30 s` covers reading one complete request (head + body) once its first byte is present. It does not cover the DB/CPU work, so it can never cancel a mutation (`http.rs:13, 227-231`).
- **Pipelining**: requests are handled sequentially per connection. After a response, `input.drain(..end)` keeps any pipelined bytes and the loop handles the next request without awaiting readiness (`http.rs:281`, `117`). Responses are written one per request, not coalesced.
- Path routing: `/api/` prefix, at most 4 percent-decoded segments, matched against `(Method, [&str])` (`api.rs:182-242`).

### 5.4 Response writing
- The header is built in a **128-byte stack buffer** (`http.rs:255-272, 285-296`): `HTTP/1.1 <code> OK\r\nContent-Type: application/json\r\n` + `Content-Length: N\r\n` (omitted for 204) + `Connection: close\r\n\r\n` or `\r\n`. **The reason phrase is always `OK`, whatever the status**, and there are no Date or Server headers. HEAD and 204 send no body.
- The write is a single vectored `try_write_vectored([header, body])` loop on `writable()` (`http.rs:377-392`).

### 5.5 JSON
- Output is written straight into the byte buffer; there are no intermediate structs (`json.rs`, `api.rs:246-342`).
- **String escaping** (`json.rs:72-144`): with SSE2 on x86-64, 16 bytes at a time, the mask is `(subs_epu8(v,31)==0) | v=='"' | v=='\\'`; the scalar tail uses the same predicate. Escapes: `\"`, `\\`, `\n`, `\r`, `\t`; other bytes below 0x20 become `\u00XX` (lowercase hex). **Non-ASCII UTF-8 passes through raw**, and neither `/` nor 0x7F is escaped. Runs of clean bytes are copied with one `extend_from_slice`.
- Timestamps (`json.rs:21-68`): binary timestamptz microseconds go through `div_euclid(1000) + 946_684_800_000` ms, then Hinnant's `civil_from_days`, giving `"YYYY-MM-DDTHH:MM:SS.mmmZ"`, truncated to milliseconds. `times()` copies the formatted createdAt bytes for updatedAt when the two values are equal (`json.rs:200-213`).
- Tags: the binary `text[]` is parsed in place (ndim at offset 0, element count at 12, data starting at 20 as len+bytes) and written as a JSON array (`json.rs:162-198`).
- Integers use `itoa`. Request bodies are parsed with `serde_json::Value` (`api.rs:153-178`).
- Errors look like `{"errors":{"body":["<msg>"]}}` (`api.rs:56-72`). Check order: auth (401), then body (422), then database (404/403/422).

### 5.6 JWT (`auth.rs`)
- Issue: header constant `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9`, payload `{"sub":"<id>","iat":now,"exp":now+2592000}`, then HS256 (`auth.rs:13-47`).
- Verify (every request, no cache): split at the last `.`, then the first `.`, rejecting any extra dot. Decode the signature (must be 32 bytes) and **check the HMAC first**. If the header equals the constant, skip parsing it; otherwise JSON-parse it and require `alg == "HS256"`. Parse the payload (stack buffer, 2 KiB): `sub` must be a string of digits with a value above 0; reject if `exp <= now` or `now < nbf` (`auth.rs:49-104`).
- `Authorization` must start with `Token `. On auth-optional endpoints a present but invalid header (including an empty one) gives 401 (`api.rs:77-98`).

---

## 6. OS limits (fds, backlog, ports)

What the submission does:
- Listener via `socket2` (`main.rs:135-147`): **`SO_REUSEADDR`**, non-blocking, **backlog 16384**. There is **no `SO_REUSEPORT`**, one listener, and one accept loop task. The kernel caps the backlog at `net.core.somaxconn = 65535` (`box/sysctl.conf:2`).
- Accept errors such as EMFILE/ENFILE are logged, then the loop **sleeps 10 ms** instead of spinning (`main.rs:126-130`).
- **No `setrlimit`.** The process relies on the systemd unit: `LimitNOFILE=200000` (`box/challenge.service:19`, `SPEC.md:26`). It sets no TCP keepalive and no idle timeout (idle keep-alive is unlimited), so every virtual user holds 1 fd for the whole run.
- Box sysctls (`box/sysctl.conf`): `somaxconn 65535`, `tcp_max_syn_backlog 65535`, `ip_local_port_range 1024 65535`, `tcp_tw_reuse 1`, `fs.file-max 2097152`, `fs.nr_open 1048576`. `box/setup-box.sh:71-72` sets `DefaultLimitNOFILE=200000:1048576` and `* soft nofile 200000`.

Implications for a Kotlin port (these are my notes, not something the submission does):
- **fd ceiling**: at 100k users the server holds about 100k sockets plus 8 PG plus internals, well under 200k under systemd. Outside systemd (local tests, or a shell where the soft limit is the 1024/65536 default), the soft limit caps concurrent users near 64k. **Kotlin/JVM**: HotSpot on Linux raises the soft `RLIMIT_NOFILE` to the hard limit at startup (`-XX:+MaxFDLimit`, on by default; verify with `cat /proc/<pid>/limits`), so only the hard limit matters. **Kotlin/Native** must call `setrlimit(RLIMIT_NOFILE, {hard, hard})` itself via the `platform.posix` interop, at least when `getrlimit` shows soft < hard.
- **Backlog**: Java's `ServerSocketChannel.bind(addr)` defaults to backlog **50**. Pass an explicit backlog (16384-65535) or the 100k-user ramp will see SYN drops and retransmits (1 s, then 3 s), which ruin p99 (handshake retries back off from 1 s).
- **Ephemeral ports** (`ip_local_port_range 1024 65535`, so 64,511 ports) limit each **load-generator source IP** to about 64.5k connections to one `ip:port` (`bench/README.md:73-75`). The server side uses a single local port and is not affected. Above about 64k users from one load box, connection errors come from the generator, not the server.
- The leaderboard's scoring search defaults to `-max 120000` (`bench/README.md:99`), so 100k is not the cap.

---

## 7. Porting checklist (distilled)

1. On connect: `SET plan_cache_mode = force_generic_plan; SET jit = off`. Prepare all statements with explicit OIDs (int8=20, text=25, int8[]=1016, text[]=1009). Request binary results.
2. 6 read and 2 write connections, each owned by an actor or coroutine with a bounded channel (1024).
3. Read actor: receive one job, drain up to 32 without waiting, group by statement, and make one execution per group (unnest/ordinality array form, the shared-enrichment form when at least half are duplicate pages, a broadcast for TAGS, the plain frame for comments or single jobs). Send everything plus **one Sync** in one write, demultiplex by CommandComplete, then route rows by the last int8 column (1-based). On error, rerun each job alone.
4. Route reads by family affinity: the most same-family in-flight requests within `minLoad + 8`; comments go least-loaded.
5. Write actor: receive one job; if the queue is empty, wait 1 ms; drain up to 128. One job runs autocommit. More than one: BEGIN, pipeline everything, then COMMIT, or on any error ROLLBACK and retry individually. Never retry after a failed COMMIT. Reply only after COMMIT's ReadyForQuery.
6. Favorite/unfavorite/update read back with ARTICLE_BY_ID on a read connection after the commit reply.
7. HTTP: no per-connection buffer while idle (wait for readiness, then borrow a 1 KiB buffer); thread-local size-class pools; status line `HTTP/1.1 NNN OK`; only Content-Type and Content-Length; unlimited idle keep-alive; a 30 s deadline only for reading a started request; sequential pipelining.
8. bcrypt: about 28 ops/s at 100k users; bound it to 1 thread and interleave up to 4 hashes; a 160 ms collection window.
9. Listener backlog of at least 16384 and TCP_NODELAY; raise RLIMIT_NOFILE in Kotlin/Native; back off 10 ms on accept errors.
