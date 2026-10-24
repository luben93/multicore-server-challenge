# Placement study: should Postgres render the JSON? (key: json-sql)

**Question.** Should Postgres return each request's finished JSON body (or per-article JSON fragments) as one
text column, instead of the binary rows (int8/bool/timestamptz/text/text[]) the Kotlin server renders today? The
box is CPU-bound and Postgres uses about 70% of it, so what matters is the **total CPU** (Postgres plus app) per
request, not which side is faster in isolation.

**Answer: no, keep binary rows for everything that contains articles, comments, profiles or users. The one
exception is `GET /api/tags`, where rendering in SQL is free.**

- Rendering JSON in SQL raised **Postgres CPU per request by 16-28%** for every kind that carries articles or comments:

  | Kind | Extra Postgres CPU per request (N = 8 / 32) |
  |---|--:|
  | Global list | +31 / +30 µs |
  | Tag list | +35 / +32 µs |
  | Article by slug | +7 / +6 µs |
  | Comments | +10 / +9 µs |
  | Profile, GET /api/user | +1 µs each |

  All 3 paired repetitions went the same way for all 18 (kind, N) cells. It also sent **10-36% more bytes** from
  Postgres to the app (lists: 4.5 KB to 5.5 KB per request).
- The app-side work it removes is small. Rendering the same responses from binary rows in C costs 2.5 µs per list
  request, 3.1 per tag list, 0.7 per article, 1.2 per comment list and 0.1 per profile or user. Copying the
  finished SQL text costs 0.1-0.3 µs. Weighted by the WORKLOAD.md mix, Postgres would spend **+12 µs per average
  request** (N = 8, including an extrapolation for feed, author and favorited lists). The app would save
  **about 1.2 µs** in C, or perhaps 2.5-5 µs in Kotlin/JVM (estimated, not measured here). **Total CPU gets
  worse by about 7-11 µs per request.** On the read kinds measured, that is +18% Postgres CPU.
- **Exception, `GET /api/tags` (20% of requests).** `array_to_json(ARRAY(SELECT name … ORDER BY name))` costs the
  same Postgres CPU as returning the `text[]`: −0.4 / −0.2 / +0.9 µs at N = 8 / 32 / 1, which is −1.4% / −0.7% /
  +1.7%. It sends 9% fewer bytes (2,037 vs 2,247). The app then skips writing 200 escaped strings, which costs
  2.6 µs in C. **Render the tags body in SQL**, with that exact form. Do not use
  `string_agg(to_json(name)::text, ',')`, which costs +67%.
- Why Postgres is slower at this: each article fragment costs **2.6 µs** of expression evaluation, even with the
  cheapest design. That includes `to_char` at 0.29 µs per timestamp and `to_json(text)` at 0.16-0.26 µs per
  string, because each call re-categorizes the type through syscache and goes through `OidOutputFunctionCall`.
  Every `||` also allocates a new string. On top of that, SQL has to sort each article's tags (+5% on lists),
  because the app cannot re-sort inside a finished JSON string. And at N = 1 the bigger expression tree costs
  about 15 µs more to set up per statement.

## Results (Postgres CPU per request, microseconds)

All runs used a copy of `conduit_seed`, generic plans, 2 connections with Postgres on CPUs 0-1 and the driver on
CPUs 2-3, a 10-12 s window after a 2 s warm-up, and 3 repetitions. Binary and JSON ran back to back inside one
hold of the lab lock, with their order alternating between repetitions. Each cell shows the median and the
min-max over the 3 repetitions. "Paired" is JSON ÷ binary within each repetition. Wire bytes are everything
Postgres sends per request: DataRows plus a 1/N share of BindComplete, CommandComplete and ReadyForQuery.

| Kind | N | Binary PG µs/req | JSON PG µs/req | JSON ÷ binary (median) | Paired ratio, reps 1/2/3 | Δ µs/req | Wire B/req binary | Wire B/req JSON |
|---|--:|--:|--:|--:|---|--:|--:|--:|
| Global list (limit 10, offsets 0-40) | 1 | 191.6 (190.5-196.2) | 237.0 (232.7-241.5) | 1.24 | 1.26 / 1.22 / 1.21 | +45.4 | 4,498 | 5,519 |
| | 8 | 157.1 (155.2-160.1) | 188.6 (187.5-190.7) | 1.20 | 1.18 / 1.23 / 1.19 | +31.4 | 4,476 | 5,498 |
| | 32 | 148.5 (144.6-154.7) | 178.9 (176.9-183.1) | 1.20 | 1.16 / 1.23 / 1.22 | +30.4 | 4,473 | 5,496 |
| Tag list | 1 | 249.5 (244.1-251.1) | 294.1 (289.4-302.7) | 1.18 | 1.19 / 1.21 / 1.17 | +44.6 | 4,549 | 5,563 |
| | 8 | 209.6 (209.6-215.5) | 244.5 (241.8-250.8) | 1.17 | 1.12 / 1.20 / 1.17 | +34.9 | 4,527 | 5,541 |
| | 32 | 195.2 (193.5-196.4) | 226.8 (224.6-232.3) | 1.16 | 1.16 / 1.16 / 1.19 | +31.7 | 4,525 | 5,540 |
| Article by slug (body ~1 KB) | 1 | 70.8 (69.5-74.9) | 84.4 (81.8-85.3) | 1.19 | 1.13 / 1.18 / 1.21 | +13.6 | 1,430 | 1,579 |
| | 8 | 28.1 (28.1-35.0) | 35.5 (34.2-39.1) | 1.26 | 1.12 / 1.26 / 1.22 | +7.4 | 1,406 | 1,555 |
| | 32 | 23.5 (23.3-24.3) | 29.7 (29.2-30.8) | 1.26 | 1.27 / 1.27 / 1.25 | +6.2 | 1,404 | 1,552 |
| Comments | 1 | 72.1 (71.2-72.4) | 84.0 (81.8-84.7) | 1.17 | 1.16 / 1.18 / 1.15 | +11.9 | 2,188 | 2,679 |
| | 8 | 36.2 (35.9-37.9) | 46.0 (44.6-46.0) | 1.27 | 1.27 / 1.22 / 1.24 | +9.8 | 2,172 | 2,665 |
| | 32 | 32.3 (31.7-33.3) | 41.2 (39.8-41.3) | 1.28 | 1.24 / 1.30 / 1.23 | +8.9 | 2,171 | 2,662 |
| Profile | 1 | 39.9 (39.6-42.3) | 43.6 (42.5-45.7) | 1.09 | 1.07 / 1.08 / 1.09 | +3.7 | 174 | 228 |
| | 8 | 9.8 (9.5-10.0) | 10.5 (10.5-11.0) | 1.07 | 1.07 / 1.10 / 1.11 | +0.7 | 152 | 206 |
| | 32 | 6.0 (5.7-6.6) | 7.0 (6.8-7.2) | 1.16 | 1.18 / 1.10 / 1.16 | +1.0 | 150 | 204 |
| GET /api/user | 1 | 33.7 (32.9-33.9) | 36.5 (36.0-37.3) | 1.08 | 1.09 / 1.10 / 1.08 | +2.8 | 223 | 247 |
| | 8 | 6.6 (6.5-6.8) | 7.7 (7.6-7.9) | 1.17 | 1.16 / 1.17 / 1.17 | +1.1 | 202 | 225 |
| | 32 | 3.3 (3.2-3.4) | 4.0 (4.0-4.2) | 1.20 | 1.19 / 1.24 / 1.24 | +0.7 | 200 | 223 |
| GET /api/tags | 1 | 56.0 (55.3-56.4) | 57.0 (56.4-57.2) | 1.02 | 1.01 / 1.02 / 1.02 | +0.9 | 2,269 | 2,059 |
| | 8 | 29.4 (29.3-29.7) | 29.0 (29.0-29.2) | 0.99 | 1.00 / 0.98 / 0.99 | −0.4 | 2,247 | 2,037 |
| | 32 | 27.2 (27.2-27.3) | 27.0 (27.0-27.0) | 0.99 | 0.99 / 0.99 / 0.99 | −0.2 | 2,245 | 2,035 |

The user JSON is the fragment after the token. The app writes `{"user":{"token":"<jwt>",` and then appends the SQL
text. So the JSON byte count excludes the token. The binary byte count excludes it too, since the app supplies it.

### Which JSON design is cheapest (N = 8, same lock hold, 3 reps, median and min-max)

| Kind | Variant | PG µs/req | vs binary | Wire B/req |
|---|---|--:|--:|--:|
| Global list | `b`: binary rows, bounded page (the baseline in the table above) | 157.1 (155.2-160.1) | 1.000 | 4,476 |
| | `b0`: binary rows, exact catalog C# s6 text | 157.6 (156.4-159.4) | 1.003 | 4,476 |
| | `bs`: binary rows plus the per-article tag sort in SQL | 165.6 (164.1-166.1) | 1.054 | 4,476 |
| | `j`: concat plus `to_json(text)` plus `to_char`, `string_agg(… ORDER BY id)`, one body per request | 188.6 (187.5-190.7) | 1.200 | 5,498 |
| | `jn`: as `j`, aggregate relying on subquery order | 186.2 (185.2-191.7) | 1.185 | 5,498 |
| | `jz`: as `j`, `AT TIME ZONE 'UTC'` instead of session `TimeZone=UTC` | 186.9 (183.3-190.5) | 1.190 | 5,498 |
| | `f`: per-article fragment rows (r.i, n, frag); the app writes the envelope | 190.0 (188.4-190.0) | 1.209 | 5,744 |
| | `jr`: `row_to_json` / `json_agg` of records | 194.4 (193.4-196.4) | 1.237 | 5,525 |
| | `jo`: `json_build_object` / `json_agg` | 201.4 (198.8-211.2) | 1.282 | 5,882 |
| Tag list | `b` / `b0` / `bs` | 209.6 / 205.4 / 219.5 | 1.000 / 0.980 / 1.047 | 4,527 |
| | `j` / `jn` / `f` / `jr` / `jo` | 244.5 / 237.2 / 240.0 / 246.2 / 254.2 | 1.166 / 1.132 / 1.145 / 1.174 / 1.213 | 5,541 / 5,542 / 5,788 / 5,568 / 5,925 |
| Article | `b` / `j` / `jr` / `jo` | 28.1 / 35.5 / 34.3 / 34.8 | 1.000 / 1.264 / 1.221 / 1.236 | 1,406 / 1,555 / 1,555 / 1,597 |
| Comments | `b` (catalog C# s3) / `b2` (ordered subquery, no top-level Sort) / `j` / `jo` | 36.2 / 33.6 / 46.0 / 53.5 | 1.000 / 0.930 / 1.270 / 1.479 | 2,172 / 2,172 / 2,665 / 2,805 |
| Profile | `b` / `j` / `jo` | 9.8 / 10.5 / 11.0 | 1.000 / 1.073 / 1.126 | 152 / 206 / 219 |
| User | `b` / `j` / `jo` | 6.6 / 7.7 / 7.8 | 1.000 / 1.173 / 1.185 | 202 / 225 / 236 |
| Tags | `b` (`text[]`) / `j` (`array_to_json`) / `ja` (`json_agg`) / `js` (`string_agg(to_json(name)::text)`) | 29.4 / 29.0 / 29.4 / 49.0 | 1.000 / 0.986 / 1.000 / 1.666 | 2,247 / 2,037 / 2,236 / 2,037 |

- **Hand-written concatenation is the cheapest JSON design.** It uses `||`, `to_json(x)::text` for escaping,
  `to_char` for timestamps and `CASE` for booleans. `row_to_json` is 3-4% dearer, `json_build_object` 7-17%.
  `json_build_object` also writes `"k" : v, ` with extra spaces, and `json_agg` writes `", \n "` between elements,
  so both send more bytes.
- **Per-article fragments are no cheaper than one body per request.** The `string_agg` they avoid costs about as
  much as the extra DataRows they add.
- **No variant comes within 13% of binary** on any article-bearing kind.
- An incidental binary-side finding: the ordered-subquery shape `b2` is **7% cheaper than C# s3** for comments.
  C# s3's top-level `ORDER BY c.created_at DESC, c.id DESC` sits above the users join and adds a Sort per request.
  In `b2`, `(SELECT … FROM (… LIMIT 100) c JOIN users u … ORDER BY …) q` keeps the index order, and EXPLAIN shows
  no Sort. Both forms give byte-identical results.

### Where the Postgres time goes: per-expression micro-costs

Each figure is `SELECT sum(length(<expr>)) FROM` a 100k-row temporary copy of article rows, minus the
`length(title)` baseline. Each was run 6 times and the minimum taken, on one backend on CPU 0-1, under the lab lock.

| Expression | µs per call |
|---|--:|
| One list Article fragment, concat form (12 pieces; tags pre-materialized) | **2.63** |
| Same, `format()` | 2.80 |
| Same, `row_to_json` of a sub-select | 3.35 |
| Same, `json_build_object` | 3.98 |
| `to_char(ts, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')` (session TimeZone=UTC) | 0.29 |
| `to_char(ts AT TIME ZONE 'UTC', …)` | 0.30 |
| `to_json(ts)::text` (wrong format: microseconds, `+00:00`) | 0.19 |
| `to_json(title)::text` / `to_json(description)::text` / `coalesce(to_json(bio)::text,'null')` | 0.16 / 0.23 / 0.26 |
| `to_json(body)::text`, ~1 KB (on top of 1.15 µs to detoast it) | 0.63 |
| `array_to_json(tags)::text` | 0.33 |
| `json_build_object('t', title)::text` | 0.34 |
| `fc::text`, `CASE WHEN b THEN 'true' ELSE 'false' END` | ≈0.1 (at noise level) |

A list page has 10 articles, so about 26 µs of fragment rendering plus about 8 µs of tag sorting (`bs` − `b`).
Postgres then skips about 4 µs of `array_send`/`timestamptz_send`/`int8send` work, which nets to the roughly
+30 µs measured per list request. At N = 1 the JSON statements pay about 15 µs more per *statement*: the executor
builds the state for every function call and `||` in the target list on each execution (+45 µs at N = 1 vs
+30 µs at N = 32 for lists).

### App-side cost that SQL rendering would remove (C, measured)

`jdrv -R 256`: 256 captured responses (N = 8), rendered repeatedly for 2 s on CPU 2. The binary path decodes
DataRows, escapes strings, formats timestamps and sorts tags by bytes. The JSON path copies the finished text
(plus the token prefix for user). Kotlin/JVM was not measured here; a JIT-compiled byte writer is typically
1.5-3× this.

| Kind | Binary rows → JSON in C (ns/req) | SQL text → response copy (ns/req) | Saved by SQL rendering (ns/req) | Extra PG at N = 8 (ns/req) |
|---|--:|--:|--:|--:|
| Global list | 2,464 | 279 | 2,185 | 31,400 |
| Tag list | 3,107 | 265 | 2,842 | 34,900 |
| Article | 715 | 77 | 638 | 7,400 |
| Comments | 1,195 | 134 | 1,061 | 9,800 |
| Profile | 81 | 5 | 76 | 700 |
| User | 112 | 8 | 104 | 1,100 |
| Tags (200 names) | 2,669 | 108 | **2,561** | **−400** |

### Total CPU, weighted by the WORKLOAD.md mix

Request shares come from the page weights: tags 20.1%, global list 11.9%, feed 8.1%, tag list 4.3%, article 19.7%,
comments 19.6%, profile 5.4%, author 4.3%, favorited 1.1%, writes 5.3%, GET /api/user 0.6%. The seven kinds
measured cover 82% of requests.

| | N = 1 | N = 8 | N = 32 |
|---|--:|--:|--:|
| PG µs per average request, measured kinds, binary → JSON | 75.3 → 88.1 (+12.8, +17%) | 46.9 → 55.5 (+8.6, +18%) | 42.9 → 50.9 (+8.0, +19%) |
| Feed / author / favorited lists, extrapolated (+3.1 µs per article, 10/5/5 per page) | +4.9 | +3.4 | +3.3 |
| App rendering saved (C) | −1.2 | −1.2 | −1.2 |
| **Net total CPU per average request** | **+16.5 µs** | **+10.8 µs** | **+10.1 µs** |

With the 2-4× JVM factor the app saving would be 2.5-5 µs, so the net would still be about +7 to +9 µs per
request.

Rendering only `/api/tags` in SQL instead: Postgres changes by −0.1 to +0.2 µs per average request, the app saves
about 0.5 µs per average request (C), or 1-2 µs on the JVM, and the tags response is 9% smaller.

## Recommendation

1. **Keep binary rows** for the list kinds (global, tag, author, favorited, feed), article, comments, profile and
   user, as DESIGN.md plans. Moving JSON rendering into SQL moves work from the cheap side, a hand-written byte
   writer, to the expensive side: fmgr calls, syscache lookups, palloc'd intermediate texts and `to_char`. It also
   forces the per-article tag sort into SQL and grows the Postgres → app traffic by 10-36%.
2. **Render `GET /api/tags` in SQL** with the per-request-tied form below. It costs Postgres nothing extra, sends
   9% fewer bytes, and the app just copies about 2 KB. The `r.i >= 0` tie must stay, so the array is built once per
   request (rule 5):
   ```sql
   SELECT r.i, '{"tags":' || array_to_json(ARRAY(SELECT t.name FROM tags t WHERE r.i >= 0 ORDER BY t.name))::text || '}'
     FROM unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[]) AS r(i, v, l, o, k)
   ```
   The tag order is SQL's `ORDER BY name` in both forms, so the collation caveat in sql-catalog.md §1 applies
   equally.
3. Two side findings, independent of where JSON is rendered:
   - Comments: the ordered-subquery `b2` shape is 7% cheaper than C# s3.
   - If any statement aggregates over a page whose size is a parameter, bound it with R's inner
     `LIMIT 100 OFFSET o` (see the gotchas below).

## SQL design notes and gotchas (verified with EXPLAIN on the seed copy)

- **The generic plan flips to a Hash Join over all 100k users.** I first wrote the JSON list as
  `string_agg(...) FROM (page LIMIT r.l OFFSET r.o) a JOIN users u`. The generic plan estimates 50,000 page rows
  for a parameter LIMIT, and once the target list got expensive it chose `Hash Join` over a `Seq Scan on users`
  (100k rows) plus a Sort. With rescans, the hash table was also built once and reused across requests. Wrapping
  the page in an ordered subquery was not enough. The fix is R's bounded page,
  `(SELECT * FROM (… ORDER BY a.id DESC LIMIT 100 OFFSET r.o) b ORDER BY b.id DESC LIMIT r.l)`. It is now used by
  every JSON variant and by the binary baseline `b`. The binary `b0`, the exact catalog text, still gets the
  nested-loop plan and costs the same as `b`.
- **`ORDER BY s.tn COLLATE "C"` evaluates the tag-name subquery twice.** It produced SubPlan 3 and SubPlan 4,
  both probing `tags_pkey`. Putting the collation inside, `(SELECT t.name …) COLLATE "C" AS tn … ORDER BY s.tn`,
  gives one probe per tag. `COLLATE "C"` makes the order byte order on any box collation, which conformance
  requires.
- **`string_agg(q.frag, ',' ORDER BY q.id DESC)` over an ordered subquery adds no Sort.** Postgres 16+ uses the
  presorted input, so the explicit ORDER BY is free and keeps the order guaranteed.
- **Comments 404 vs empty list.** Aggregate inside a scalar subquery over `articles a WHERE a.slug = r.k`: no row
  means 404, and `coalesce(..., '')` gives `{"comments":[]}`. An aggregate at the top level would always return
  one row.
- **Timestamps.** `to_char` truncates to milliseconds, as SPEC.md requires: `.999999` gives `.999`, `.0005` gives
  `.000`, and 1999-12-31 is correct. Session `TimeZone=UTC` costs the same as `AT TIME ZONE 'UTC'`, and the binary
  path doesn't care. `to_json(timestamptz)` is cheaper but prints microseconds and `+00:00`, and trims trailing
  zeros, so it is unusable.
- **Slugs are concatenated unescaped.** That is safe because `SLUGIFY(x) || '-' || id` only yields `[a-z0-9-]`;
  the seed has 0 exceptions. Usernames, titles, bodies, bios, images and tag names must be escaped. In the seed,
  436k articles contain `"`, `\` or control characters (mostly newlines in the body).

## Verification

The JSON produced by SQL was compared with jq against the same requests rendered from binary rows by the
independent C renderer in `jdrv` (`jq -cS` per request, then a byte compare):

- **Random batches:** 3 seeds × N = 32 for every kind and every JSON variant (list j/jn/jz/f/jo/jr, tag j/f/jo/jr,
  article j/jo/jr, comments j/jo, profile j/jo, user j, tags j/ja/js). Also compared: b0 and bs, and comments b
  against b2. **All identical.**
- **Edge cases**, on a separate throwaway copy with crafted rows: a username and bio with `"`, `\`, `\n`, `\t`,
  `\x01`, `é`, `日本` and `😀`; NULL bio, NULL image and `""` image; an article with no tags; tags `Zeta`, `alpha`,
  `Ärger`, `q"t\b` and `zz日本`, which must come out in byte order; timestamps at `.000000`, `.48`, `.999999`
  (1999-12-31), `.000999`, `.0005` and `.9999`; a comment tie on `created_at`; an article with no comments; an
  unknown slug, username or user id (404); an unknown tag (`[]`, count 0); and pages past the end (`[]`, count
  1000). **All identical.**
- **Format checks:** all 39,142 `createdAt`/`updatedAt` values in the dumps match
  `^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$`, `favoritesCount` is always a JSON integer, and every `tagList` is
  in byte order.

## Method

- **Database:** `CREATE DATABASE jsonsql_place TEMPLATE conduit_seed STRATEGY FILE_COPY`. Edge cases ran on a
  second copy, `jsonsql_edge`, with crafted rows. Both copies are dropped. The template databases were not touched,
  and nothing in the repo was modified.
- **Driver:** `jdrv.c` in C. I did not use pgbench, for two reasons. pgbench cannot generate a random array
  parameter per transaction without an extra query. And libpq's `PQexecPrepared` always sends a Describe, so every
  execution would get a RowDescription that the Kotlin server never asks for; that costs more for the 15-column
  binary layout than for the 2-column JSON one. `jdrv` speaks protocol v3 directly, as the app does:
  - Startup `options` are `-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0 -c enable_memoize=off -c TimeZone=UTC`.
  - Each statement is Parsed once with explicit OIDs: int4[], int8[], int4[], int8[], text[].
  - Each execution is Bind (binary parameters, binary results) + Execute + Sync, with no Describe.
  - Parameters use the uniform 5-array layout of `conduit/db/Db.kt`, with N requests per statement and fresh random
    values each time.
- **Parameters** follow WORKLOAD.md:
  - Viewer: uniform over 1..100,000.
  - Lists: limit 10; offset 0 70% of the time, otherwise 10/20/30/40.
  - Tag: Zipf(1.0) over tags ranked by article count.
  - Slugs (article, comments) come from an 8,192-entry pool: 50% from the newest 50 articles, 30% from the newest
    20,000, and 20% Zipf(0.9) by recency over all 500k.
  - Profile: the author of a pool article.
  - User: a random id.
- **CPU:** `/proc/<backend pid>/schedstat` (on-CPU nanoseconds, user plus sys) for both backends, read after the
  warm-up and at the end of the window, divided by the requests served in that window. Bytes are counted from the
  actual wire messages. The binary layouts are the sql-catalog.md batched statements (C# s1-s8, tag count from R),
  re-wired to the 5-array unnest.
- **Lock and order:**
  - 2 clients, each with its own backend; Postgres on CPUs 0-1, the driver pinned to CPUs 2-3.
  - One lab-lock hold per repetition, covering all kinds. Inside a hold, each kind first does an unrecorded 4 s
    warm run. Then all its variants run back to back at N = 8, followed by the binary/JSON pairs at N = 1 and
    N = 32.
  - The order is reversed in every other repetition. 3 repetitions in total.
  - The driver renders only 1 in 32 responses (to count JSON bytes), so binary and JSON runs give Postgres the same
    think time.

## Caveats

- **Other agents.** They were running Gradle/JVM builds and bcrypt benchmarks *outside* the lock during my holds;
  load average was about 8 on 4 vCPUs. schedstat counts only on-CPU time, so this shows up as cache and
  context-switch noise rather than bias. The spreads above include it, and every paired repetition agrees in
  direction. The widest is article at N = 8, with binary at 28.1-35.0 µs, but paired ratios of 1.12-1.26.
- **Postgres was not saturated in every run.** For the cheap kinds (profile, user, tags, N = 1 everywhere) it ran at
  1.2-1.8 of its 2 CPUs, because 2 synchronous clients cannot keep it busy. Per-request CPU then includes the
  per-statement wakeup cost. That cost is the same in both variants, so it shrinks the ratios toward 1 and leaves Δ
  unchanged.
- **The lab is not the box.** This is a 4-vCPU VM, not the 8-vCPU box. Absolute µs will differ there; the
  JSON ÷ binary ratios should carry over, because they reflect per-expression costs inside Postgres.
- **No Kotlin measurement here.** The app side was measured in C only. The JVM figure (2-4× C) is an estimate. Even
  at 10× C the app saving (12 µs) would only match the Postgres increase.
- **Rule 5.** It is unaffected: the JSON variants keep every subquery tied to the request row (`r.i >= 0` for the
  global count and tags).
- **Run history.** A first pass of rep 1 rendered every response inside the driver. That made binary runs leave
  Postgres idle longer between statements. It is kept separately in `results_v1_render_every_exec.txt` and agrees
  within a few percent. The tables use only the second pass.

## Files

Working directory: `/tmp/claude-0/-home-user-multicore-server-challenge/99796a5c-b120-524c-822d-dc73b94b523b/scratchpad/placement/json-sql/`

- `gen.py`: generates every statement into `sql/`. The `*_b*` files are binary, `*_j*`/`*_f` are JSON, and the
  variant letters are as in the tables. The verbatim texts are in `sql/*.sql`.
- `jdrv.c` (binary `jdrv`): wire-protocol driver, CPU accounting, dump mode (`-x`), params file (`-P`) and
  C render benchmark (`-R`).
- `cmp.sh`, `cmpe.sh`, `edge/*.tsv`, `cmp/`: the jq equivalence checks.
- `sweep2.sh`, `results.txt`, `analyze.py`, `render.txt`, `micro.sh`, `micro.txt`, `sweep.log`.
