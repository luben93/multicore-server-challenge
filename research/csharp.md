# csharp-sockets-jh-d (leaderboard #2, 95,000 users): research notes

Source: `/home/user/multicore-server-challenge/submissions/csharp-sockets-jh-d` (all paths below are relative to its `src/` unless stated).
Leaderboard row (LEADERBOARD.md:8): 95,000 users, 24,696 req/s, p95 493 ms, p99 737 ms, CPU app 21% / Postgres 75%, direct (no nginx).
Read for this note: README.md, Batch.cs, Ctx.cs, Handlers.cs, Http.cs, Json.cs, Jwt.cs, Pg.cs, Program.cs, Sql.cs, Conduit.csproj, start.sh, build.sh.
Not covered (another agent): BCrypt.cs, BlowfishInit.cs, CpuWork.cs.

Zero dependencies: own HTTP/1.1 on `System.Net.Sockets`, own PG wire protocol 3.0 client (SCRAM-SHA-256, extended protocol, binary
results), `Utf8JsonWriter` fed straight from binary rows, own bcrypt, HS256 via a per-thread keyed `HMACSHA256`.

---------------------------------------------------------------------------------------------------------------------

## 0. Configuration at a glance

| Setting | Default | Where |
|---|---|---|
| Read connections `DB_CONNS` | 12 | Program.cs:41 |
| Write connections `DB_WRITE_CONNS` | 16 | Program.cs:41 |
| Total PG connections | 28 (+1 short-lived boot connection, closed before the pools open) | Program.cs:18-21, 44 |
| Dispatch mode `DISPATCH` | `conn` (connection-driven); `kind` = legacy | Program.cs:45 |
| `DISPATCH_DEPTH` (statements in PG per read conn) | 1 | Program.cs:46 |
| `BATCH_MAX` (max requests per batched statement) | 64 (class default 32 is overridden) | Program.cs:29, Batch.cs:62 |
| `BATCH_INFLIGHT` (max connections one kind can hold) | 6 | Program.cs:30, Batch.cs:62 |
| Per kind `BATCH_<KIND>=<max>:<inflight>` | none | Program.cs:32-33, Batch.cs:83-88 |
| bcrypt threads / batch wait | 2 / 300 ms | Program.cs:49 |
| HOST / PORT | 127.0.0.1 / 3000 | Program.cs:51-53 |
| Session options `DB_OPTIONS` | see 1.1 | Program.cs:13-14 |
| GC | workstation, concurrent; TieredPGO; InvariantGlobalization | Conduit.csproj |
| Runtime env | `DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS=1`, `DOTNET_EnableWriteXorExecute=0`, `DOTNET_TieredPGO=1`, `DOTNET_ThreadPool_UnfairSemaphoreSpinLimit=0` | start.sh |

Kind list order (`Kind.All`, which breaks ties in the dispatcher): tags, article, comments, profile, user, list, author, tag,
favorited, feed (the definition order in Sql.cs:120-142).

---------------------------------------------------------------------------------------------------------------------

## 1. SQL

### 1.1 Session settings (sent in the StartupMessage `options` parameter, not as SET statements)

Program.cs:13-14, verbatim:

```csharp
string options = Env("DB_OPTIONS",
    "-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0 -c enable_memoize=off");
```

The StartupMessage also carries `client_encoding=UTF8` and `application_name=conduit` (Pg.cs:199-200). No TLS.
Why (Program.cs:9-12): generic plans skip planning per execution (each generic plan is as good as its custom one), no JIT,
no parallel workers. `enable_memoize=off` is a **correctness/rules** setting for batching: Memoize could hand one request a row
that another request's lookup fetched inside the same batched statement.

### 1.2 Startup collation probe (decides who sorts tag lists)

Sql.cs:19-20 (statement `s0`, defined first because `Sql`'s static initializer runs at Program.cs:17):

```sql
SELECT datlocprovider::text, datcollate, coalesce(datlocale, '') FROM pg_database WHERE datname = current_database()
```

Program.cs:17-28: opened on a boot connection (same options), result read as text (binary text == UTF-8 bytes), boot connection
closed. `Sql.AppSortsTags` =
- provider `"c"` (libc): `datcollate` is `C` or `POSIX` or starts with `C.` (case-insensitive) -> true
- provider `"b"` (builtin): same test on `datlocale` (`C`, `C.UTF-8`) -> true
- anything else (ICU `"i"`) -> false.

When true, every `ARRAY(... tag names ...)` has **no** `ORDER BY` and the app sorts names by UTF-8 bytes (insertion sort, NULLs
last), which equals `ORDER BY name` under C collation (Sql.cs:15-17, 24; Json.cs:73-76). When false, ` ORDER BY 1` is appended
inside the ARRAY subquery (Sql.cs:24). Only `Sql.Define()` (Program.cs:31) builds the other statements, after this is known.
The /api/tags statement always uses `ORDER BY t.name` in SQL (Sql.cs:121).

### 1.3 Building blocks (Sql.cs, verbatim)

```csharp
    static string TagOrder => AppSortsTags ? "" : " ORDER BY 1";                                                         // :24
    const string Following = "(SELECT true FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) IS NOT NULL"; // :25
    static string Tail(string following) =>                                                                             // :26-32
        "a.created_at, a.updated_at, " +
        "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id" +
        TagOrder + ") AS tag_list, " +
        "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, " +
        "(SELECT true FROM favorites f WHERE f.user_id = $1 AND f.article_id = a.id) IS NOT NULL AS favorited, " +
        "u.username, u.bio, u.image, " + following + " AS following";
    static string ArticleTail => Tail(Following);                                                                       // :33
    static string FeedTail => Tail("true"); // the viewer follows every feed author (same snapshot)                      // :34

    const string ListCols = "a.id, a.slug, a.title, a.description, ";                                                    // :36
    static string FullSelect => "SELECT a.id, a.slug, a.title, a.description, a.body, " + ArticleTail +                 // :37-38
                                " FROM articles a JOIN users u ON u.id = a.author_id";
    // the page is cut in a subquery before anything is joined or computed: OFFSET rows cost an index step only
    const string PageCols = "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a"; // :40

    // a page of article ids (a subquery producing column "id", newest first) -> article rows
    static string ListOf(string ids, string tail) =>                                                                    // :43-44
        "SELECT " + ListCols + tail + " FROM (" + ids + ") p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY p.id DESC";
```

Article row column order (positions within the per-request query, i.e. after `r.i` / `r.i, c.n`):
`id, slug, title, description, [body], created_at, updated_at, tag_list, favorites_count, favorited, username, bio, image, following`.

### 1.4 The batching wrappers (Sql.cs:48-88, verbatim)

```csharp
    static string Unnest(Layout l) => l switch
    {
        Layout.None => "unnest($1::int4[]) AS r(i)",
        Layout.Viewer => "unnest($1::int4[], $2::int8[]) AS r(i, v)",
        Layout.ViewerKey => "unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, k)",
        Layout.List => "unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[]) AS r(i, v, l, o)",
        _ => "unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[]) AS r(i, v, l, o, k)",
    };

    static uint[] Oids(Layout l) => l switch
    {
        Layout.None => [Oid.Int4Array],
        Layout.Viewer => [Oid.Int4Array, Oid.Int8Array],
        Layout.ViewerKey => [Oid.Int4Array, Oid.Int8Array, Oid.TextArray],
        Layout.List => [Oid.Int4Array, Oid.Int8Array, Oid.Int4Array, Oid.Int8Array],
        _ => [Oid.Int4Array, Oid.Int8Array, Oid.Int4Array, Oid.Int8Array, Oid.TextArray],
    };

    [GeneratedRegex(@"\$(\d+)")]
    private static partial Regex ParamRef();

    // per-request parameters -> request row columns
    static string Bind(string sql, Layout l) => ParamRef().Replace(sql, m =>
    {
        int n = int.Parse(m.Groups[1].Value);
        return l switch
        {
            Layout.Viewer => n == 1 ? "r.v" : throw new ArgumentException(sql),
            Layout.ViewerKey => n == 1 ? "r.v" : n == 2 ? "r.k" : throw new ArgumentException(sql),
            _ => n switch { 1 => "r.v", 2 => "r.l", 3 => "r.o", 4 => "r.k", _ => throw new ArgumentException(sql) },
        };
    });

    static Kind Batched(string name, string perRequest, Layout l, int maxInflight = 0) => new(name, Stmt.Define(
        "SELECT r.i, x.* FROM " + Unnest(l) + " CROSS JOIN LATERAL (" + Bind(perRequest, l) + ") x", Oids(l)), l, 0, maxInflight);

    // lists: (i, count, article columns...), and one row with NULL article columns when the page is empty.
    // OFFSET 0 keeps the count a subquery evaluated once per request: pulled up, it would run once per article row.
    static Kind BatchedList(string name, string page, string count, Layout l, int maxInflight = 0) => new(name, Stmt.Define(
        "SELECT r.i, c.n, x.* FROM " + Unnest(l) + " CROSS JOIN LATERAL (SELECT " + Bind(count, l) + " AS n OFFSET 0) c " +
        "LEFT JOIN LATERAL (" + Bind(page, l) + ") x ON true", Oids(l)), l, 0, maxInflight);
```

Per-request parameter -> request-row column mapping (the per-request SQL is written with `$n`, then textually rewritten):

| Layout | Batched-statement params (Parse OIDs) | per-request `$1` | `$2` | `$3` | `$4` |
|---|---|---|---|---|---|
| None (tags) | `$1 int4[]` (1007) = request index | - | - | - | - |
| Viewer (user) | `$1 int4[]`, `$2 int8[]` (1016) | r.v | - | - | - |
| ViewerKey (article, comments, profile) | `$1 int4[]`, `$2 int8[]`, `$3 text[]` (1009) | r.v | r.k | - | - |
| List (list-all, feed) | `$1 int4[]`, `$2 int8[]`, `$3 int4[]`, `$4 int8[]` | r.v | r.l | r.o | - |
| ListKey (author, tag, favorited) | `$1 int4[]`, `$2 int8[]`, `$3 int4[]`, `$4 int8[]`, `$5 text[]` | r.v | r.l | r.o | r.k |

`r.i` = 0..N-1 (index of the request in the batch), `r.v` = viewer user id (0 = anonymous), `r.l` = limit (int4),
`r.o` = offset (int8), `r.k` = key (slug / username / tag name, URL-decoded UTF-8).
Array parameter order written by BatchQuery.Write (Batch.cs:152-184): i[], then v[] (unless None), then l[], o[] (List/ListKey),
then k[] (ViewerKey/ListKey). Arrays are 1-D, lower bound 1, no NULLs.

### 1.5 Counts (Sql.cs:90-104, verbatim)

```csharp
    // "at least 1000?" is answered by whether a 1000th row exists (OFFSET 999), cheaper than counting 1000 rows;
    // the exact count is only taken below that
    const string CountAll =
        "CASE WHEN EXISTS (SELECT 1 FROM articles c WHERE r.i >= 0 ORDER BY c.id OFFSET 999) THEN 1000 " +
        "ELSE (SELECT count(*) FROM articles c WHERE r.i >= 0) END";
    // one pass over at most 1000 index entries; EXISTS (... OFFSET 999) then count(*) scanned twice below 1000
    const string CountTag =
        "(SELECT count(*) FROM (SELECT 1 FROM article_tags c WHERE c.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s)";
    const string CountAuthor =
        "(SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s)";
    const string CountFavorited =
        "(SELECT count(*) FROM (SELECT 1 FROM favorites c WHERE c.user_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s)";
    // followees as an array: one index scan over articles_author_idx for all of them
    const string FeedAuthors = "c.author_id = ANY (ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1))";
    const string CountFeed = "(SELECT count(*) FROM (SELECT 1 FROM articles c WHERE " + FeedAuthors + " LIMIT 1000) s)";
```

`c.n` comes back as int8 (CASE unifies `1000` int4 with `count(*)` bigint). articlesCount is capped at 1000 (SPEC.md:267).

### 1.6 The tricks (why the SQL looks like this)

1. **Batching by LATERAL over unnest.** One statement serves N waiting requests of the same kind; rows are tagged with `r.i`.
   Per-statement overhead (protocol, executor start/stop, snapshot, xact) is paid once per batch (README "Batched reads").
2. **`WHERE r.i >= 0`** (CountAll Sql.cs:93-94, Tags Sql.cs:121): a subquery that references no request parameter would be
   planned as an uncorrelated InitPlan and run **once per statement**, sharing its result across requests (forbidden "caching").
   Referencing `r.i` makes it correlated, so it runs once per request row. `r.i >= 0` is always true.
3. **`OFFSET 0`** in `(SELECT <count> AS n OFFSET 0) c` (Sql.cs:87): prevents subquery pull-up; otherwise the count expression
   would be evaluated per output (article) row of the following LEFT JOIN LATERAL.
4. **`LEFT JOIN LATERAL (...) x ON true`** for lists: an empty page still yields one row `(i, n, NULL...)`, so the request
   gets its count; for comments, `LEFT JOIN LATERAL ... c ON true` yields one row with NULL comment columns when the article
   has no comments (no row at all = no article -> 404).
5. **Page cut first:** `FROM (SELECT ... FROM articles a ORDER BY a.id DESC LIMIT $2 OFFSET $3) a JOIN users u ...` so the
   per-row subqueries (tags, favorites count, favorited, following) run only for the page rows (Sql.cs:39-40, 128-132).
   Tag/favorited lists cut an id page from `article_tags` / `favorites` first (`ListOf`, Sql.cs:43-44, 133-138).
6. **Tag names by PK per tag:** `ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id)`
   instead of a join (the planner otherwise hash-joins a scan of all tags per article) (Sql.cs:22, 28).
7. **Bounded probes:** `(SELECT true FROM favorites f WHERE f.user_id = $1 AND f.article_id = a.id) IS NOT NULL` and the same
   for follows (PK index probes) instead of hashed subplans / EXISTS over all of the viewer's rows (Sql.cs:23, 25, 31).
8. **Feed:** `following` is the constant `true` (FeedTail, Sql.cs:34). Page = per-followee top-(limit+offset) via
   `CROSS JOIN LATERAL (... ORDER BY a2.id DESC LIMIT ($2::bigint + $3::bigint))` merged and cut (Sql.cs:139-142); count uses
   `author_id = ANY (ARRAY(followees))` = one scan on `articles_author_idx` (Sql.cs:102-104).
9. **Comments:** viewer's followees read once per request into an array and `c.author_id = ANY (f.ids)` per comment, instead
   of a follows probe per comment (Sql.cs:216-229). Capped at newest 100.
10. **Global count:** `EXISTS (... ORDER BY c.id OFFSET 999)` then exact count only below 1000 (Sql.cs:90-94).
11. **Writes:** follow/unfollow = one data-modifying CTE statement (write + read back); favorite = write, then `ArticleBySlug` as
    a 2nd statement in the same Sync group (sees conflicting concurrent writes the insert waited for) (Sql.cs:176-181);
    create article = one Sync group (implicit transaction) with `nextval` + `currval` (Sql.cs:146-163).
12. **Tag insert:** only missing tags, sorted by name (no sequence burn, no deadlock between concurrent creates),
    `ON CONFLICT (name) DO NOTHING` for races (Sql.cs:151-158).
13. **Generic plans** for everything (`plan_cache_mode=force_generic_plan`): with named prepared statements PG would otherwise
    custom-plan the first 5 executions and then compare costs.

### 1.7 Statement ids (prepared as `"s<id>"` on every connection, in this order)

| id | Name | Kind / pool | Parse param OIDs |
|---|---|---|---|
| s0 | Collation | boot only (also prepared on all conns) | none |
| s1 | Tags | batched `tags` (Layout.None) | int4[] |
| s2 | Article | batched `article` (ViewerKey) | int4[], int8[], text[] |
| s3 | Comments | batched `comments` (ViewerKey) | int4[], int8[], text[] |
| s4 | Profile | batched `profile` (ViewerKey) | int4[], int8[], text[] |
| s5 | User | batched `user` (Viewer) | int4[], int8[] |
| s6 | ListAll | batched `list` (List) | int4[], int8[], int4[], int8[] |
| s7 | ListAuthor | batched `author` (ListKey) | int4[], int8[], int4[], int8[], text[] |
| s8 | ListTag | batched `tag` (ListKey) | same as s7 |
| s9 | ListFavorited | batched `favorited` (ListKey) | same as s7 |
| s10 | ListFeed | batched `feed` (List) | int4[], int8[], int4[], int8[] |
| s11 | ArticleBySlug | write pool (favorite read-back) | int8, text |
| s12 | ArticleInsert | write | int8, text, text, text, text |
| s13 | TagsInsert | write | text[] |
| s14 | ArticleTagsInsert | write | text[] |
| s15 | ArticleByCurrval | write | int8 |
| s16 | ArticleUpdate | write | int8, text, text, text, text, text |
| s17 | ArticleAuthorBySlug | write (403/404 disambiguation) | text |
| s18 | ArticleDelete | write | text, int8 |
| s19 | FavoriteInsert | write | int8, text |
| s20 | FavoriteDelete | write | int8, text |
| s21 | CommentInsert | write | int8, text, text |
| s22 | CommentDelete | write | int8, text, int8 |
| s23 | CommentAuthor | write | int8, text |
| s24 | UserInsert | write | text, text, text |
| s25 | UserByEmail | **read pool**, unbatched (login) | text |
| s26 | UserUpdate | write | int8, text, text, text, text, text |
| s27 | Follow | write | int8, text |
| s28 | Unfollow | write | int8, text |

OIDs: bool 16, int8 20, int4 23, text 25, int4[] 1007, text[] 1009, int8[] 1016 (Pg.cs:15-18).
The fully expanded text of every statement, exactly as sent in Parse, is in **Appendix A** (generated by re-running the string
concatenation from Sql.cs; the binary itself supports `conduit --print-sql`, Program.cs:35-39).

### 1.8 SQL grouped by endpoint (source verbatim, with binding and row mapping)

#### GET /api/tags -> kind `tags`, s1 (Sql.cs:120-122)

```csharp
        Tags = new Kind("tags", Stmt.Define(
            "SELECT r.i, ARRAY(SELECT t.name FROM tags t WHERE r.i >= 0 ORDER BY t.name) " +
            "FROM " + Unnest(Layout.None), Oids(Layout.None)), Layout.None);
```
Row: `(i int4, names text[])` -> `{"tags":[...]}` in array order (Handlers.cs:331-336, Json.cs:94-111). No row -> 500
"no tags row" (Handlers.cs:400-402). Auth header is not checked at all for this route (Handlers.cs:102-107).

#### GET /api/articles/:slug -> kind `article`, s2 (Sql.cs:123)

```csharp
        Article = Batched("article", FullSelect + " WHERE a.slug = $2", Layout.ViewerKey);
```
Row: `(i, id, slug, title, description, body, created_at, updated_at, tag_list, favorites_count, favorited, username, bio, image, following)`
-> `{"article": Article(o=1, full)}` (Handlers.cs:337-343); first row only (`c.Found`). No row -> 404 "article not found".

#### GET /api/articles/:slug/comments -> kind `comments`, s3 (Sql.cs:124, 216-229)

```csharp
    // $1 viewer, $2 slug. One row with NULL comment columns when the article has no comments; no row = no article.
    // The viewer's followees are read once for the request (an index range of ~20 rows) and each comment's author is
    // checked against that array, instead of one follows-index probe per comment (up to 100 per request).
    const string CommentsSql = """
        SELECT a.id, c.id AS comment_id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
               c.author_id = ANY (f.ids) AS following
          FROM articles a
          CROSS JOIN LATERAL (SELECT ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) AS ids) f
          LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c
                              WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
          LEFT JOIN users u ON u.id = c.author_id
         WHERE a.slug = $2
         ORDER BY c.created_at DESC, c.id DESC
        """;
```
Row: `(i, a.id, comment_id int8, body, created_at, updated_at, username, bio, image, following bool)`.
First row opens `{"comments":[`; each row with non-NULL col 2 writes `{"id", "createdAt"(col4), "updatedAt"(col5), "body"(col3), "author": Profile(col6..9)}`
(Handlers.cs:344-362); Done closes `]}` or 404 "article not found" if no row (Handlers.cs:406-413).

#### GET /api/profiles/:username -> kind `profile`, s4 (Sql.cs:125, 231-236)

```csharp
    // $1 viewer, $2 username
    const string ProfileSql = """
        SELECT u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
          FROM users u WHERE u.username = $2
        """;
```
Row `(i, username, bio, image, following)` -> `{"profile":{...}}`; none -> 404 "profile not found".

#### GET /api/user -> kind `user`, s5 (Sql.cs:126, 238)

```csharp
    const string UserById = "SELECT id, username, email, bio, image FROM users WHERE id = $1";
```
Row `(i, id, username, email, bio, image)` -> `{"user":{"email","token"(echo of request token),"username","bio","image"}}`
(Json.cs:159-171). None -> 401 "unauthorized".

#### GET /api/articles (no filter) -> kind `list`, s6 (Sql.cs:128-129)

```csharp
        ListAll = BatchedList("list", "SELECT " + ListCols + ArticleTail + " FROM (" + PageCols +
            " ORDER BY a.id DESC LIMIT $2 OFFSET $3) a JOIN users u ON u.id = a.author_id ORDER BY a.id DESC", CountAll, Layout.List);
```

#### GET /api/articles?author= -> kind `author`, s7 (Sql.cs:130-132)

```csharp
        ListAuthor = BatchedList("author", "SELECT " + ListCols + ArticleTail + " FROM (" + PageCols +
            " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3) a" +
            " JOIN users u ON u.id = a.author_id ORDER BY a.id DESC", CountAuthor, Layout.ListKey);
```

#### GET /api/articles?tag= -> kind `tag`, s8 (Sql.cs:133-135)

```csharp
        ListTag = BatchedList("tag", ListOf(
            "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) " +
            "ORDER BY at.article_id DESC LIMIT $2 OFFSET $3", ArticleTail), CountTag, Layout.ListKey);
```

#### GET /api/articles?favorited= -> kind `favorited`, s9 (Sql.cs:136-138)

```csharp
        ListFavorited = BatchedList("favorited", ListOf(
            "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) " +
            "ORDER BY f.article_id DESC LIMIT $2 OFFSET $3", ArticleTail), CountFavorited, Layout.ListKey);
```

#### GET /api/articles/feed -> kind `feed`, s10 (Sql.cs:139-142)

```csharp
        ListFeed = BatchedList("feed", ListOf(
            "SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id " +
            "ORDER BY a2.id DESC LIMIT ($2::bigint + $3::bigint)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3",
            FeedTail), CountFeed, Layout.List);
```

List rows: `(i, n int8, id, slug, title, description, created_at, updated_at, tag_list, favorites_count, favorited, username, bio, image, following)`.
First row: `c.Count = n`, open `{"articles":[`; each row with non-NULL col 2 -> Article(o=2, no body) (Handlers.cs:374-383).
Done: close `]`, `"articlesCount": Count`, `}` (Handlers.cs:420-430). Unknown tag/author -> empty list, count 0.

#### POST /api/articles (create) -> write pool, one Sync group: s12, [s13, s14], s15 (Handlers.cs:605-615)

```csharp
        // $1 viewer, $2 slug prefix ("<slugified title>-"), $3 title, $4 description, $5 body
        ArticleInsert = Stmt.Define("""
            INSERT INTO articles (id, slug, author_id, title, description, body)
            SELECT n.id, $2 || n.id, $1, $3, $4, $5
              FROM (SELECT nextval('articles_id_seq'::regclass) AS id) n
            """, I8, T, T, T, T);
        // only tags that don't exist yet (no sequence burn), in name order (no deadlock between concurrent creates)
        TagsInsert = Stmt.Define("""
            INSERT INTO tags (name)
            SELECT n FROM (SELECT DISTINCT unnest($1::text[]) AS n) x
             WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = x.n)
             ORDER BY n
            ON CONFLICT (name) DO NOTHING
            """, Oid.TextArray);
        ArticleTagsInsert = Stmt.Define("""
            INSERT INTO article_tags (article_id, tag_id)
            SELECT (SELECT currval('articles_id_seq'::regclass)), t.id FROM tags t WHERE t.name = ANY($1::text[])
            """, Oid.TextArray);
        ArticleByCurrval = Stmt.Define(FullSelect + " WHERE a.id = (SELECT currval('articles_id_seq'::regclass))", I8);
```
Binding (Handlers.cs:606-614): `ArticleInsert(viewer, S4=slugPrefix, S1=title, S2=description, S3=body)`; if tags non-empty:
`TagsInsert(tags[])`, `ArticleTagsInsert(tags[])`; `ArticleByCurrval(viewer)`; then one Sync. Row read from result index 3 (with tags)
or 1 (without) -> 201 `{"article":...}` (Handlers.cs:669-673). `slugPrefix = Slug.Make(title) + "-"` so slug = `<slug>-<id>`.

#### PUT /api/articles/:slug -> s16, fallback s17 (Handlers.cs:616-624, 762-784)

```csharp
        // $1 viewer, $2 slug, $3 title, $4 description, $5 body, $6 new slug prefix (NULL when the title is unchanged)
        ArticleUpdate = Stmt.Define("""
            WITH a AS (
              UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), body = COALESCE($5, body),
                     slug = CASE WHEN $6::text IS NULL THEN slug ELSE $6 || id END,
                     updated_at = now()
               WHERE slug = $2 AND author_id = $1
              RETURNING id, slug, title, description, body, created_at, updated_at, author_id)
            SELECT a.id, a.slug, a.title, a.description, a.body,
            """ + ArticleTail + " FROM a JOIN users u ON u.id = a.author_id", I8, T, T, T, T, T);
        ArticleAuthorBySlug = Stmt.Define("SELECT author_id FROM articles WHERE slug = $1", T);
```
Note: the raw string ends without a newline, so the sent text is `... a.body,a.created_at, ...` (valid). tagList in the body is ignored.
Step 0: row -> 200 `{"article":...}`. No row -> Step 1 `ArticleAuthorBySlug(slug)` on the write pool: row -> 403 "not the author",
none -> 404 "article not found".

#### DELETE /api/articles/:slug -> s18, fallback s17

```csharp
        ArticleDelete = Stmt.Define("DELETE FROM articles WHERE slug = $1 AND author_id = $2", T, I8);
```
CommandComplete tag `DELETE n` parsed (Handlers.cs:736-741); n>0 -> 204; n==0 -> step 1 -> 403 / 404.

#### POST|DELETE /api/articles/:slug/favorite -> s19|s20 then s11 in one Sync group (Handlers.cs:629-635)

```csharp
        // the write, then the read-back as its own statement in the same Sync group (one round trip): its snapshot
        // then includes a conflicting write that the insert waited for
        FavoriteInsert = Stmt.Define(
            "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 ON CONFLICT DO NOTHING", I8, T);
        FavoriteDelete = Stmt.Define(
            "DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2)", I8, T);
        ArticleBySlug = Stmt.Define(FullSelect + " WHERE a.slug = $2", I8, T);
```
Row from result 1 -> 200 `{"article":...}`; none -> 404 "article not found".

#### POST /api/articles/:slug/comments -> s21 (Handlers.cs:636-638)

```csharp
        // $1 viewer, $2 slug, $3 body
        CommentInsert = Stmt.Define("""
            WITH c AS (INSERT INTO comments (article_id, author_id, body)
                       SELECT a.id, $1, $3 FROM articles a WHERE a.slug = $2
                       RETURNING id, body, created_at, updated_at, author_id)
            SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
              FROM c JOIN users u ON u.id = c.author_id
            """, I8, T, T);
```
Row -> 201 `{"comment":{"id","createdAt"(2),"updatedAt"(3),"body"(1),"author":{username,bio,image,following:false}}}` (Handlers.cs:682-696).
None -> 404 "article not found".

#### DELETE /api/articles/:slug/comments/:id -> s22, fallback s23

```csharp
        // $1 comment id, $2 slug, $3 viewer
        CommentDelete = Stmt.Define(
            "DELETE FROM comments c USING articles a WHERE c.id = $1 AND a.id = c.article_id AND a.slug = $2 AND c.author_id = $3", I8, T, I8);
        CommentAuthor = Stmt.Define(
            "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2", I8, T);
```
Non-digit id -> 404 "comment not found" without SQL (Handlers.cs:87). n>0 -> 204; else step 1: row -> 403, none -> 404.

#### POST /api/users (register) -> bcrypt first, then s24 on write pool

```csharp
        UserInsert = Stmt.Define(
            "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image", T, T, T);
```
Row -> 201 `{"user":{... token = Jwt.Issue(id)}}` (Handlers.cs:705-709). SQLSTATE 23505 -> 422 "already taken".

#### POST /api/users/login -> s25 on the **read** pool (not batched, Handlers.cs:539), then bcrypt verify

```csharp
        UserByEmail = Stmt.Define("SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1", T);
```
Row decoded into strings + `BCrypt.VerifyJob` (Handlers.cs:714-722); Done -> `CpuWork.Run` -> AfterBcrypt writes 200 or 401
"invalid email or password" (Handlers.cs:580-597). No row -> 401.

#### PUT /api/user -> s26 (bcrypt first if password present)

```csharp
        UserUpdate = Stmt.Define("""
            UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                             password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
             WHERE id = $1
            RETURNING id, username, email, bio, image
            """, I8, T, T, T, T, T);
```
Binding: `(viewer, S1=email, S2=username, S3=hash or NULL, S4=bio, S5=image)`; NULL = unchanged (so bio/image can't be set to
null, only to ""). Row -> 200 user JSON with the request's token echoed; none -> 401; 23505 -> 422.

#### POST|DELETE /api/profiles/:username/follow -> s27|s28

```csharp
        Follow = Stmt.Define("""
            WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
                 i AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM u ON CONFLICT DO NOTHING)
            SELECT username, bio, image FROM u
            """, I8, T);
        Unfollow = Stmt.Define("""
            WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
                 d AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id IN (SELECT id FROM u))
            SELECT username, bio, image FROM u
            """, I8, T);
```
Row `(username, bio, image)` -> `{"profile":{..., "following": true|false}}` (constant per route, Handlers.cs:697-704);
none -> 404 "profile not found".

Error mapping for all single (write/login) queries (Handlers.cs:743-756): 23505 -> 422 "already taken", 23503 -> 404 "not found",
other -> 500. Batched-read errors -> 500 for every request in the batch (Handlers.cs:388-396).

---------------------------------------------------------------------------------------------------------------------

## 2. Batch.cs: queueing and dispatch (exact algorithm)

Data (Batch.cs:59-136):
- `Kind`: `Name`, `Stmt`, `Layout`, `MaxBatch` (64), `MaxInflight` (6), `Queue<Ctx> _pending`, `Stack<BatchQuery> _free`
  (recycled batch objects), `int _inflight` (batches of this kind currently in PG). All mutated under the single global
  `Dispatch.Lock` (Batch.cs:28).
- `Ctx.Queued` = `Stopwatch.GetTimestamp()` set at enqueue (Batch.cs:96).
- `PgConn.Inflight` = queries submitted to that connection and not yet completed (ReadyForQuery seen), Pg.cs:240.

**Enqueue(c)** (Batch.cs:94-105): set `c.Queued = now`; under `Dispatch.Lock` append to `_pending`; then `Dispatch.Pump()`.

**Ready** (Batch.cs:91): `_pending.Count > 0 && _inflight < MaxInflight`.

**Dispatch.Pump()** (Batch.cs:31-56), connection-driven, **no timers**:
```
loop:
  lock(Dispatch.Lock):
    best = the Ready kind with the smallest HeadQueued (timestamp of its oldest queued request);
           iteration order Kind.All, strict '<' so earlier kinds win ties
    if best == null: return
    conn = Pg.Reads.PickBelow(Depth)     // Depth = 1
    if conn == null: return              // no free read connection: requests stay queued
    conn.Reserve()                       // conn.Inflight++ (under conn lock)
    b = best.TakeLocked()                // dequeue min(pending, MaxBatch) Ctx into b.Items, best._inflight++
  conn.Submit(b, reserved: true)         // outside Dispatch.Lock: write Bind/Execute/Sync into conn's buffer, flush
```

**PickBelow(depth)** (Pg.cs:663-677): start at a round-robin index (`Interlocked.Increment(_rr) % n`), scan all connections,
skip `Broken`, pick the one with the smallest `Inflight` that is `< depth`, stop early at 0. With Depth=1 this means
"an idle read connection" (one statement in PG per read connection).

**When Pump runs:**
1. on every Enqueue (Batch.cs:103) - on the HTTP (epoll) thread that parsed the request;
2. on `Kind.Release()` (Batch.cs:108-118), called from `BatchQuery.Done` **before** the batch's responses are written (Batch.cs:198),
   so the next batch of this kind goes out first;
3. on `PgConn.Freed` after every ReadyForQuery of a read connection (Pg.cs:478; wired at Program.cs:47).
Note: the connection's `Inflight--` happens in the 'Z' handler before `q.Done` (Pg.cs:467-471), so the Pump inside `Done` already
sees the connection as free.

Effect: at low load each batch has one request, zero waiting. Under load, requests accumulate while all 12 read connections are
busy; the moment one frees, the kind with the oldest waiter ships **everything** it has queued (up to 64) as one statement.
Batches grow automatically with load; nothing queues behind a long statement on a connection. `MaxInflight=6` caps how many of the
12 read connections one kind can occupy.

**BatchQuery.Write** (Batch.cs:152-184): `Bind(stmt)`; int4[] `0..n-1`; int8[] viewers (unless None); int4[] limits + int8[] offsets
(List/ListKey); text[] keys (ViewerKey/ListKey); `EndBind` (adds Execute); `Sync`. One Sync group per batch.

**BatchQuery.Row** (Batch.cs:186-190): `i = row.Int4(0)`; if `0 <= i < N` -> `Handlers.BatchRow(Items[i], row)` which writes JSON
directly into that request's own writer. Rows need not be contiguous per request (each Ctx has its own buffer), but order within a
request is preserved (nested loop over unnest).

**BatchQuery.Done(error)** (Batch.cs:192-212): copy Items to `_done`, clear, `_k.Release()` (pump the next batch), then for every
request `Handlers.BatchDone(c, error)` -> `c.Finish()` (send response from this PG reader thread), then recycle the BatchQuery.

Legacy mode `DISPATCH=kind` (Batch.cs:25-26, 101, 114): each kind sends immediately while `_inflight < MaxInflight`, via `Pg.Read`
(`Pick()` = least-loaded, unbounded pipelining). Not the default.

Non-batched queries: writes `Pg.Write(c.Single)` -> `Writes.Pick()` (least `Inflight`, ties round-robin, pipelined without limit,
Pg.cs:680-694, 724). Login `Pg.Read(c.Single)` -> `Reads.Pick()` (Pg.cs:723); it increments that read conn's Inflight so batches
avoid it until it completes.

---------------------------------------------------------------------------------------------------------------------

## 3. Pg.cs: wire-protocol client (byte level)

All integers big-endian. "cstr" = bytes + 0x00.

### 3.1 Connection open (Pg.cs:257-268, 714-721)
- Parse `DATABASE_URL` with `Uri`: host, port (default 5432), user/password (URL-unescaped), database = path without `/`.
- TCP socket, `NoDelay = true`, blocking `Connect`. Handshake, then PrepareAll, then start two threads per connection:
  `pg-read-N` (ReadLoop) and `pg-flush-N` (FlushLoop). Connections open sequentially: reads 0..11, writes 12..27.

### 3.2 StartupMessage (Pg.cs:194-208)
```
Int32 length (including itself)
Int32 196608                      // 0x00030000, protocol 3.0
cstr "user"            cstr <user>
cstr "database"        cstr <db>
cstr "options"         cstr "-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0 -c enable_memoize=off"
cstr "client_encoding" cstr "UTF8"
cstr "application_name" cstr "conduit"
0x00
```
(empty values are skipped). No SSLRequest.

### 3.3 Authentication loop (Pg.cs:547-631)
Read messages `type(1) Int32 len body(len-4)`. `'E'` -> throw; `'Z'` -> handshake done; anything except `'R'` (ParameterStatus 'S',
BackendKeyData 'K', notices) is ignored. For `'R'`, `code = Int32 body[0..4]`:
- 0 AuthenticationOk: continue.
- 3 cleartext: send `'p' Int32(4+len) cstr(password)`.
- 5 MD5: salt = body[4..8]; send `'p'` + cstr("md5" + hex(md5(hex(md5(password + user)) + salt))).
- 10 AuthenticationSASL (mechanism list not inspected): nonce = base64(18 random bytes) (24 chars);
  `clientFirstBare = "n=*,r=" + nonce`; send SASLInitialResponse:
  ```
  'p' Int32 len  cstr "SCRAM-SHA-256"  Int32 len(clientFirst)  "n,,n=*,r=<nonce>"
  ```
- 11 SASLContinue: `serverFirst` = ASCII body[4..]; parse comma parts `r=`, `s=`, `i=`; require `r` startsWith client nonce,
  salt present, iter > 0. Then
  ```
  withoutProof   = "c=biws,r=" + r                     // biws = base64("n,,")
  SaltedPassword = PBKDF2-HMAC-SHA256(UTF8(password), base64dec(s), i, 32)
  ClientKey      = HMAC-SHA256(SaltedPassword, "Client Key")
  StoredKey      = SHA256(ClientKey)
  AuthMessage    = clientFirstBare + "," + serverFirst + "," + withoutProof
  ClientSig      = HMAC-SHA256(StoredKey, AuthMessage)
  Proof          = ClientKey XOR ClientSig
  ServerKey      = HMAC-SHA256(SaltedPassword, "Server Key")
  ServerSig      = HMAC-SHA256(ServerKey, AuthMessage)
  ```
  send SASLResponse: `'p' Int32 len  withoutProof + ",p=" + base64(Proof)` (no inner length prefix, no NUL).
- 12 SASLFinal: body[4..] must be `"v=" + base64(ServerSig)` (constant-time compare) else throw.
- other -> throw. (No SASLprep of the password.)

### 3.4 Preparing statements once per connection (Pg.cs:217-227, 633-647)
For every defined statement, in id order, one Parse; then a single Sync; send all at once (blocking); read until `'Z'`, remembering
the first `'E'` (throws if any). **No Describe** is sent - the app knows every result layout statically and asks for all results in
binary at Bind time.
```
Parse:  'P' Int32 len  cstr "s<id>"  cstr <sql UTF-8>  Int16 nParams  Int32 oid * nParams
Sync:   'S' 00 00 00 04
```

### 3.5 Per query: Bind / Execute / Sync (Pg.cs:126-161)
```
Bind:    'B' Int32 len                // patched after params
         0x00                         // unnamed portal ""
         cstr "s<id>"
         Int16 1  Int16 1             // one param-format code: binary for all
         Int16 nParams                // = ParamOids.Length
         per param: Int32 byteLen (-1 = NULL) + bytes
         Int16 1  Int16 1             // one result-format code: binary for all columns
Execute: 'E' 00 00 00 09  00  00 00 00 00   // portal "", maxRows 0 (all)
Sync:    'S' 00 00 00 04
```
Multi-statement requests (create article, favorite) write several Bind+Execute pairs then one Sync: one implicit transaction, and
on error PG skips to the Sync. There is no Close, no Flush ('H') message.

Parameter encodings (binary):
- int8: `Int32 8` + 8 bytes BE (Pg.cs:148); int4: `Int32 4` + 4 bytes (Pg.cs:149); bool: `Int32 1` + 0/1 (Pg.cs:150).
- text: `Int32 len` + UTF-8 bytes; null string -> `Int32 -1` (Pg.cs:151-161).
- 1-D array, no NULLs (Pg.cs:171-188):
  ```
  Int32 paramLen           // patched = bytes after this field
  Int32 1                  // ndim
  Int32 0                  // has-null flag
  Int32 elementOid         // 23 int4, 20 int8, 25 text
  Int32 count              // patched (dimension size)
  Int32 1                  // lower bound
  elements: Int32 len + bytes   (int4 -> 00000004 xxxxxxxx; int8 -> 00000008 + 8 bytes; text -> len + UTF-8)
  ```

### 3.6 Receiving (Pg.cs:389-483)
- Dedicated blocking reader thread per connection; receive buffer starts at 256 KB, compacted (memmove remaining to 0) when full,
  doubled if a single message doesn't fit. Messages parsed in place: `type = buf[rs]`, `len = Int32 buf[rs+1..]`, body = `buf[rs+5 .. rs+1+len)`.
- `'D'` DataRow: `PgRow` parses `Int16 ncols`, then per column `Int32 len` (-1 = NULL) + bytes, filling preallocated
  `off[1664]`/`len[1664]` arrays (Pg.cs:68-90); callback `Current().Row(resultIndex, row)` unless an error was already seen.
- `'C'` CommandComplete: tag without trailing NUL -> `Complete(resultIndex, tag)`; `resultIndex++` (statement index inside the Sync group).
- `'E'` ErrorResponse: keep the first one: fields `byte code + cstr` until a 0 byte; `'C'` -> SQLSTATE, `'M'` -> message (Pg.cs:485-499).
- `'Z'` ReadyForQuery: dequeue the head query (FIFO, under lock), `Inflight--`, reset `_cur/_error/_result`, call `q.Done(firstError)`,
  then `Freed?.Invoke()` (dispatcher pump).
- Everything else (ParseComplete '1', BindComplete '2', NoData 'n', EmptyQuery 'I', PortalSuspended 's', NoticeResponse 'N',
  ParameterStatus 'S', NotificationResponse 'A') is ignored.
- Query identity: `_inflight` FIFO queue; the current query is `Peek()`ed once per Sync group (`Current()`, Pg.cs:439-445).

### 3.7 Result decoding (binary)
| PG type | Bytes | Accessor |
|---|---|---|
| int4 (`r.i`) | 4 BE | `Int4` Pg.cs:95 |
| int8 (ids, counts, `c.n`) | 8 BE | `Int8` Pg.cs:94 |
| bool | 1 byte, nonzero = true | `Bool` Pg.cs:96 |
| timestamptz | int64 BE microseconds since 2000-01-01T00:00:00Z | `Micros` Pg.cs:97-98 |
| text | raw UTF-8, copied straight into JSON | `Bytes` Pg.cs:93 |
| text[] | `Int32 ndim, Int32 hasNull, Int32 elemOid, [Int32 dimSize, Int32 lbound] * ndim, then per element Int32 len (-1 NULL) + bytes` | Json.cs:56-111 |

text[] decoder (Json.cs:61-72, 97-108): if `len >= 12 && ndim == 1`: `count = Int32 at offset 12`, elements start at offset 20.
An empty array is `ndim = 0` (12-byte header only) -> `[]`.

### 3.8 Sending without blocking (Pg.cs:274-385)
- Two `PgWriter` buffers per connection (`_pending`, `_sending`, 64 KB each, growable). `Submit`: under the connection lock, if
  `Broken` reject (query Done with 08006), else `q.Write(_pending)` + enqueue in `_inflight` FIFO (+`Inflight++` unless reserved);
  the first submitter that finds `_flushing == false` sets it and calls `Flush()` outside the lock (Pg.cs:278-304).
- `Flush()`: loop { under lock: if `_pending` empty -> `_flushing=false`, return; else swap `_pending`/`_sending` } then
  `send(fd, buf, len, MSG_DONTWAIT | MSG_NOSIGNAL)` via libc P/Invoke (retry EINTR; EAGAIN -> partial). If partial: store the offset,
  signal the flusher thread (`_flushing` stays true) and return. Error -> `Fail`.
- `FlushLoop` thread: waits on an AutoResetEvent, does **blocking** sends of the rest of `_sending`, resets it, calls `Flush()` again.
- Why: sends may happen on a PG reader thread (a response handler enqueues/pumps the next batch); a blocking send there can deadlock
  with Postgres blocked writing its output to us (README "Own Postgres client"; Pg.cs:312-314).
- Natural pipelining/coalescing: everything submitted while a send is in progress is appended to `_pending` and goes in the next send.

### 3.9 Failure (Pg.cs:501-516)
`Fail`: mark `Broken`, close the socket, complete every in-flight query with `08006`. **No reconnect**; broken connections are skipped
by `PickBelow`/`Pick`.

---------------------------------------------------------------------------------------------------------------------

## 4. HTTP (Http.cs, Ctx.cs, Program.cs)

### 4.1 Threads
- Socket I/O via `SocketAsyncEventArgs` on .NET's epoll engine; `DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS=1` (start.sh) makes
  completions run inline on the epoll threads (runtime default with inline completions: one epoll thread per core). The request is
  parsed, JWT-verified, routed and queued (Pump may Submit to PG) **on the receiving epoll thread**.
- 28 PG reader threads + 28 PG flusher threads (mostly idle); the response is built and sent (`SendAsync`) **on the PG reader thread**
  that completed the query; after a synchronous send completion, that same thread may parse the next pipelined request and re-arm the
  receive (Http.cs:230-257).
- 2 bcrypt threads (login/register/password change); login responses are sent from the bcrypt thread.
- 1 timer refreshing the cached `Date:` header line once per second (Http.cs:269-277).
- Thread pool otherwise idle (`ThreadPool_UnfairSemaphoreSpinLimit=0` so idle workers sleep).

### 4.2 Listener / socket options
- `Socket(ip.AddressFamily, Stream, Tcp)`, `DualMode` if IPv6, `SO_REUSEADDR`, `Bind`, **`Listen(65535)`** (Http.cs:18-26).
  Host: parse IP; `"localhost"` -> loopback; else IPv6Any (Program.cs:53).
- Single `AcceptAsync` loop with one SAEA, processing synchronously-completed accepts in a loop (Http.cs:30-41).
- Accepted socket: `NoDelay = true` (Http.cs:47). No SO_REUSEPORT, no keepalive options, no buffer-size options.
- Process never calls setrlimit; relies on systemd `LimitNOFILE=200000` (box/challenge.service:19, SPEC.md:26).

### 4.3 Per connection state
- `HttpConn`: one receive buffer of **2048 bytes** (Http.cs:59) growing by doubling up to `MaxRequest = 1 MB + 64 KB` (Http.cs:56),
  shrunk back to 2048 after a large request (Http.cs:254); two reusable SAEAs (`_rx`, `_tx`).
- One request at a time per connection: after a full request is parsed, receiving stops until the response is fully sent; leftover
  pipelined bytes are shifted to the buffer start and parsed next (Http.cs:250-256).
- **No idle timeout and no keep-alive timer**: connections stay open until the client closes or an error occurs.

### 4.4 Request parsing (TryServe, Http.cs:108-176)
1. Find `"\r\n\r\n"`; if absent and `_len >= 64 KB` -> 431, else wait for more bytes.
2. Request line: split on the first two spaces -> method, target, version; malformed -> 400. `HTTP/1.0` detected.
3. Headers: each line split at the first `:`; name compared case-insensitively against `content-length`, `authorization`,
   `connection`, `transfer-encoding`; value trimmed of spaces then tabs.
   - Content-Length: strict decimal (`Utf8Parser`, must consume the whole value, >= 0) else 400.
   - Connection: contains `close` -> close; contains `keep-alive` -> keepAlive.
   - Any Transfer-Encoding -> 411. Content-Length > 1 MB -> 413.
4. Wait until `headEnd + 4 + contentLength` bytes are buffered (resize buffer to exactly that).
5. `closeAfter = (http10 || Connection: close) && !(http10 && keep-alive)`.
6. Split target at `?` into path/query; rent a pooled `Ctx`; `Handlers.Start(c, method, path, query, hasAuth, auth, bodySpan)`.
   The body is a span of the connection buffer (valid until the response is sent; write handlers copy it with `ToArray()`).
- Reject (Http.cs:197-205): JSON error (`"body too large"` for 413, `"bad request"` otherwise) + `Connection: close`.

### 4.5 Response building (Ctx.cs:143-227)
- `Buf`: 8 KB array, first **192 bytes reserved**; JSON body written from offset 192 by `Utf8JsonWriter` (it implements
  `IBufferWriter`). On `Finish` the header is built on the stack and copied right-aligned to end exactly at offset 192, so header + body
  is one contiguous slice -> one `SendAsync` (Ctx.cs:181-213, 221-226).
- Header bytes:
  ```
  HTTP/1.1 <code> <reason>\r\n
  Content-Type: application/json\r\n          (omitted for 204)
  Content-Length: <body bytes>\r\n            (omitted for 204; 204 also drops any body)
  Connection: close\r\n                       (only when closing)
  Date: <RFC1123, cached per second>\r\n
  \r\n
  ```
  Reasons: 200 OK, 201 Created, 204 No Content, 400 Bad Request, 401 Unauthorized, 403 Forbidden, 404 Not Found,
  411 Length Required, 413 Content Too Large, 422 Unprocessable Entity, 431 Request Header Fields Too Large, else 500 Internal Server Error.
  Always `HTTP/1.1` in the status line, never a `Connection: keep-alive` header.
- Partial sends continue with the rest before the request is considered done (Http.cs:232-240).
- `Ctx` pool: `ConcurrentQueue`, Ctx returned after send; dropped if buffer > 256 KB, P > 4 KB, or pool > 8192 (Ctx.cs:72-93).
- Error body: `{"errors":{"body":["<message>"]}}` (Ctx.cs:109-123).

---------------------------------------------------------------------------------------------------------------------

## 5. JSON, JWT, handlers

### 5.1 Routing and auth (Handlers.cs:29-173)
- Method: exact `GET`/`POST`/`PUT`/`DELETE`. Path must start with `/api/`; one trailing `/` stripped; split on `/` into up to 4
  segments (5+ -> 404). Path segments used as keys are %-decoded (no `+`) (Handlers.cs:176-188).
- Auth (Handlers.cs:42-58): if an Authorization header exists, it must start with exactly `"Token "` and `Jwt.Verify` must return
  id > 0; then `viewer = id` and the raw token is stored in `Ctx.P` (for echo in /api/user responses). Present but invalid -> state -1.
  `Optional` endpoints: -1 -> 401; `Required`: anything but valid -> 401 "unauthorized". Register/login/tags ignore the header.

### 5.2 Query string (ParseList, Handlers.cs:233-282)
`&`-separated, `=` split; key and value %-decoded with `+` -> space. `limit`: digits only, 1..100, default 20; `offset`: digits only
(no sign), default 0, clamped to `long.MaxValue/2`; violation -> 422 "limit must be 1-100 and offset >= 0". First occurrence of each
parameter wins; empty filter values ignored; precedence tag > author > favorited. Feed parses limit/offset the same way.

### 5.3 Request bodies (Json.cs:174-246, Handlers.cs:437-568)
`JsonDocument.Parse` (allocating; writes are ~5% of traffic). Root must be an object with the wrapper (`article`/`comment`/`user`)
as an object, else 422. Field kinds: Absent / Null / String / Bad (any other JSON type).
- Create article: `title`, `description`, `body` required non-empty strings; `tagList` absent/null -> [] else array of non-empty
  strings (else 422 "title, description and body are required; tagList must be strings").
- Update article: title/description/body optional; absent/null -> unchanged; string must be non-empty; wrong type -> 422 "invalid article".
- Create comment: `body` required non-empty -> else 422 "body is required".
- Register: username/email/password required non-empty; password > 72 UTF-8 bytes -> 422. No email format check.
- Login: email/password required non-empty -> else 422.
- Update user: email/username/password optional non-empty; bio/image optional, empty allowed; null = unchanged; password > 72 bytes -> 422.
- Slug (Handlers.cs:813-834): ASCII letters lowercased, digits kept, any run of other chars -> one `-`, no leading/trailing `-`;
  then `"-" + id` appended in SQL.

### 5.4 JWT (Jwt.cs)
- Issue (Jwt.cs:25-48): header base64url precomputed from `{"alg":"HS256","typ":"JWT"}`; payload
  `{"sub":"<id>","iat":<now>,"exp":<now+2592000>}`; base64url without padding; HMAC-SHA256 over `header.payload`.
- Verify fast path (Jwt.cs:57-83): length 5..2048 and all bytes in `'!'..'~'`; first dot >= 1, last dot > first+1, no dot in the
  payload; signature base64url-decodes to exactly 32 bytes; recompute HMAC over `token[..lastDot]` with a **per-thread keyed HMAC**
  (key setup reused, Jwt.cs:19-23) and constant-time compare. Only then decode header and payload (stack scratch 1536 bytes) and
  scan top-level members with `Utf8JsonReader` (Jwt.cs:102-141): header needs `"alg":"HS256"`; payload needs `sub` = unescaped string of
  1..18 decimal digits, non-zero, and `exp` = number; other members skipped; `exp > now` (seconds). `iat`/`typ` not checked.
- Kotlin equivalent of the per-thread keyed HMAC: precompute SHA-256 midstates of `(key XOR ipad)` and `(key XOR opad)` once; per token
  hash only the message (+ one outer block).

### 5.5 Response JSON (Json.cs)
- Property names pre-encoded once (`JsonEncodedText`, Json.cs:10-38). Writer: `UnsafeRelaxedJsonEscaping` (escapes only `"`, `\`,
  control chars; non-ASCII passes through as UTF-8), `SkipValidation` (Ctx.cs:21-25). Text columns are copied as UTF-8 bytes (escaped as
  needed), never decoded to strings on read paths.
- Timestamp (Json.cs:113-125): `ticks = Ticks(2000-01-01Z) + micros * 10`; format round-trip `"O"` (`yyyy-MM-ddTHH:mm:ss.fffffffZ`),
  keep first 23 chars and put `'Z'` at index 23 -> `yyyy-MM-ddTHH:mm:ss.fffZ` (truncated to ms). Unix ms = `floorDiv(micros, 1000) + 946684800000`.
- Profile (Json.cs:128-136): `{"username","bio"(null ok),"image"(null ok),"following"}`.
- Article (Json.cs:140-156), key order: `slug, title, description, [body], createdAt, updatedAt, tagList, favoritesCount, favorited, author`
  (row `id` is not emitted).
- User (Json.cs:159-171), key order: `email, token, username, bio, image`.
- Comment (Handlers.cs:353-360): `id, createdAt, updatedAt, body, author`.
- Status codes: 201 create article / comment / register; 204 delete article / comment (no body); 200 everything else;
  401/403/404/422/500 as listed in 1.8.

---------------------------------------------------------------------------------------------------------------------

## 6. Porting notes for a zero-dependency Kotlin server

1. Port the SQL in Appendix A verbatim and prepare it once per connection with explicit param OIDs; Bind with one binary format code
   for params and results; never Describe. Startup `options` = the 4 `-c` settings.
2. Batched reads: per-kind FIFO + global lock + "free read connection pulls the kind with the oldest head" (Depth 1, 12 read conns,
   batch <= 64, <= 6 conns per kind). Separate 16-connection write pool (pipelined, least-inflight). Login on the read pool.
3. Never block a PG reader thread on send (non-blocking send + per-connection flusher); responses written from the reader thread.
4. Per-connection memory: 2 KB receive buffer, response buffers only per in-flight request (pooled). At 95-100k connections this is
   the difference between ~200 MB and many GB.
5. Limits relevant to the "~64k" concern: the box gives the service `LimitNOFILE=200000` (box/challenge.service:19, SPEC.md:26) and
   sysctl `somaxconn=65535`, `tcp_max_syn_backlog=65535`, `ip_local_port_range=1024 65535`, `fs.nr_open=1048576` (box/sysctl.conf).
   The C# server uses `listen(65535)` and does not touch rlimits; ip_local_port_range limits each load box to ~64.5k connections per
   target ip:port, so the loadgen spreads users over several boxes (bench/README.md:73-75). For Kotlin/Native, call
   `setrlimit(RLIMIT_NOFILE)` to the hard limit at startup and use `listen(fd, 65535)`; on the JVM, HotSpot raises the soft limit to the
   hard one by default (`-XX:+MaxFDLimit`), and `ServerSocketChannel.bind(addr, 65535)` must be given the backlog explicitly (default 50).
   Keep connections open forever (no idle reaping is needed or done here).

---------------------------------------------------------------------------------------------------------------------

## Appendix A: every statement exactly as sent in Parse (AppSortsTags = true, i.e. C / C.UTF-8 database collation)

Generated by replaying the Sql.cs string building (raw-string blocks read from Sql.cs with C# raw-literal indentation rules).
When the collation is NOT code-point order, s2, s6, s7, s8, s9, s10, s11, s15 and s16 differ in one place only: inside
`ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id)` the text
` ORDER BY 1` is inserted before the closing `)`, giving `... WHERE at.article_id = a.id ORDER BY 1) AS tag_list`.

### s0  Collation
Parse param OIDs: (none)
```sql
SELECT datlocprovider::text, datcollate, coalesce(datlocale, '') FROM pg_database WHERE datname = current_database()
```

### s1  Tags [batched kind 'tags']
Parse param OIDs: int4[](1007)
```sql
SELECT r.i, ARRAY(SELECT t.name FROM tags t WHERE r.i >= 0 ORDER BY t.name) FROM unnest($1::int4[]) AS r(i)
```

### s2  Article [batched kind 'article']
Parse param OIDs: int4[](1007), int8[](1016), text[](1009)
```sql
SELECT r.i, x.* FROM unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, k) CROSS JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, (SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = a.author_id) IS NOT NULL AS following FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = r.k) x
```

### s3  Comments [batched kind 'comments']
Parse param OIDs: int4[](1007), int8[](1016), text[](1009)
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

### s4  Profile [batched kind 'profile']
Parse param OIDs: int4[](1007), int8[](1016), text[](1009)
```sql
SELECT r.i, x.* FROM unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, k) CROSS JOIN LATERAL (SELECT u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = u.id) AS following
  FROM users u WHERE u.username = r.k) x
```

### s5  User [batched kind 'user']
Parse param OIDs: int4[](1007), int8[](1016)
```sql
SELECT r.i, x.* FROM unnest($1::int4[], $2::int8[]) AS r(i, v) CROSS JOIN LATERAL (SELECT id, username, email, bio, image FROM users WHERE id = r.v) x
```

### s6  ListAll [batched kind 'list']
Parse param OIDs: int4[](1007), int8[](1016), int4[](1007), int8[](1016)
```sql
SELECT r.i, c.n, x.* FROM unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[]) AS r(i, v, l, o) CROSS JOIN LATERAL (SELECT CASE WHEN EXISTS (SELECT 1 FROM articles c WHERE r.i >= 0 ORDER BY c.id OFFSET 999) THEN 1000 ELSE (SELECT count(*) FROM articles c WHERE r.i >= 0) END AS n OFFSET 0) c LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, (SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = a.author_id) IS NOT NULL AS following FROM (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a ORDER BY a.id DESC LIMIT r.l OFFSET r.o) a JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) x ON true
```

### s7  ListAuthor [batched kind 'author']
Parse param OIDs: int4[](1007), int8[](1016), int4[](1007), int8[](1016), text[](1009)
```sql
SELECT r.i, c.n, x.* FROM unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[]) AS r(i, v, l, o, k) CROSS JOIN LATERAL (SELECT (SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id = (SELECT u.id FROM users u WHERE u.username = r.k) LIMIT 1000) s) AS n OFFSET 0) c LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, (SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = a.author_id) IS NOT NULL AS following FROM (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = r.k) ORDER BY a.id DESC LIMIT r.l OFFSET r.o) a JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) x ON true
```

### s8  ListTag [batched kind 'tag']
Parse param OIDs: int4[](1007), int8[](1016), int4[](1007), int8[](1016), text[](1009)
```sql
SELECT r.i, c.n, x.* FROM unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[]) AS r(i, v, l, o, k) CROSS JOIN LATERAL (SELECT (SELECT count(*) FROM (SELECT 1 FROM article_tags c WHERE c.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.k) LIMIT 1000) s) AS n OFFSET 0) c LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, (SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = a.author_id) IS NOT NULL AS following FROM (SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.k) ORDER BY at.article_id DESC LIMIT r.l OFFSET r.o) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY p.id DESC) x ON true
```

### s9  ListFavorited [batched kind 'favorited']
Parse param OIDs: int4[](1007), int8[](1016), int4[](1007), int8[](1016), text[](1009)
```sql
SELECT r.i, c.n, x.* FROM unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[]) AS r(i, v, l, o, k) CROSS JOIN LATERAL (SELECT (SELECT count(*) FROM (SELECT 1 FROM favorites c WHERE c.user_id = (SELECT u.id FROM users u WHERE u.username = r.k) LIMIT 1000) s) AS n OFFSET 0) c LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, (SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = a.author_id) IS NOT NULL AS following FROM (SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.k) ORDER BY f.article_id DESC LIMIT r.l OFFSET r.o) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY p.id DESC) x ON true
```

### s10  ListFeed [batched kind 'feed']
Parse param OIDs: int4[](1007), int8[](1016), int4[](1007), int8[](1016)
```sql
SELECT r.i, c.n, x.* FROM unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[]) AS r(i, v, l, o) CROSS JOIN LATERAL (SELECT (SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id = ANY (ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v)) LIMIT 1000) s) AS n OFFSET 0) c LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, true AS following FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (r.l::bigint + r.o::bigint)) x WHERE fo.follower_id = r.v ORDER BY x.id DESC LIMIT r.l OFFSET r.o) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY p.id DESC) x ON true
```

### s11  ArticleBySlug
Parse param OIDs: int8(20), text(25)
```sql
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = $1 AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, (SELECT true FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) IS NOT NULL AS following FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2
```

### s12  ArticleInsert
Parse param OIDs: int8(20), text(25), text(25), text(25), text(25)
```sql
INSERT INTO articles (id, slug, author_id, title, description, body)
SELECT n.id, $2 || n.id, $1, $3, $4, $5
  FROM (SELECT nextval('articles_id_seq'::regclass) AS id) n
```

### s13  TagsInsert
Parse param OIDs: text[](1009)
```sql
INSERT INTO tags (name)
SELECT n FROM (SELECT DISTINCT unnest($1::text[]) AS n) x
 WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = x.n)
 ORDER BY n
ON CONFLICT (name) DO NOTHING
```

### s14  ArticleTagsInsert
Parse param OIDs: text[](1009)
```sql
INSERT INTO article_tags (article_id, tag_id)
SELECT (SELECT currval('articles_id_seq'::regclass)), t.id FROM tags t WHERE t.name = ANY($1::text[])
```

### s15  ArticleByCurrval
Parse param OIDs: int8(20)
```sql
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = $1 AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, (SELECT true FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) IS NOT NULL AS following FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT currval('articles_id_seq'::regclass))
```

### s16  ArticleUpdate
Parse param OIDs: int8(20), text(25), text(25), text(25), text(25), text(25)
```sql
WITH a AS (
  UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), body = COALESCE($5, body),
         slug = CASE WHEN $6::text IS NULL THEN slug ELSE $6 || id END,
         updated_at = now()
   WHERE slug = $2 AND author_id = $1
  RETURNING id, slug, title, description, body, created_at, updated_at, author_id)
SELECT a.id, a.slug, a.title, a.description, a.body,a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = $1 AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, (SELECT true FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) IS NOT NULL AS following FROM a JOIN users u ON u.id = a.author_id
```

### s17  ArticleAuthorBySlug
Parse param OIDs: text(25)
```sql
SELECT author_id FROM articles WHERE slug = $1
```

### s18  ArticleDelete
Parse param OIDs: text(25), int8(20)
```sql
DELETE FROM articles WHERE slug = $1 AND author_id = $2
```

### s19  FavoriteInsert
Parse param OIDs: int8(20), text(25)
```sql
INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 ON CONFLICT DO NOTHING
```

### s20  FavoriteDelete
Parse param OIDs: int8(20), text(25)
```sql
DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2)
```

### s21  CommentInsert
Parse param OIDs: int8(20), text(25), text(25)
```sql
WITH c AS (INSERT INTO comments (article_id, author_id, body)
           SELECT a.id, $1, $3 FROM articles a WHERE a.slug = $2
           RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
  FROM c JOIN users u ON u.id = c.author_id
```

### s22  CommentDelete
Parse param OIDs: int8(20), text(25), int8(20)
```sql
DELETE FROM comments c USING articles a WHERE c.id = $1 AND a.id = c.article_id AND a.slug = $2 AND c.author_id = $3
```

### s23  CommentAuthor
Parse param OIDs: int8(20), text(25)
```sql
SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2
```

### s24  UserInsert
Parse param OIDs: text(25), text(25), text(25)
```sql
INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image
```

### s25  UserByEmail
Parse param OIDs: text(25)
```sql
SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1
```

### s26  UserUpdate
Parse param OIDs: int8(20), text(25), text(25), text(25), text(25), text(25)
```sql
UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
 WHERE id = $1
RETURNING id, username, email, bio, image
```

### s27  Follow
Parse param OIDs: int8(20), text(25)
```sql
WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
     i AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM u ON CONFLICT DO NOTHING)
SELECT username, bio, image FROM u
```

### s28  Unfollow
Parse param OIDs: int8(20), text(25)
```sql
WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
     d AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id IN (SELECT id FROM u))
SELECT username, bio, image FROM u
```


## Appendix B: the article-read statement in the Postgres-sorts variant (for reference)

```sql
SELECT r.i, x.* FROM unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, k) CROSS JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, (SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = a.id) IS NOT NULL AS favorited, u.username, u.bio, u.image, (SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = a.author_id) IS NOT NULL AS following FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = r.k) x
```
