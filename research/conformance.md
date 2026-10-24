# Conformance suite + loadgen client: what a hand-written Kotlin server must get right

Scope: `bench/cmd/conformance/{main.go,script.go,check.go,golden-dev.jsonl}` and
`bench/cmd/loadgen/{client.go,vu.go,jwt.go,run.go,metrics.go}`, cross-checked against `SPEC.md`,
`examples/go/*` (the reference semantics), `box/*` and `score/switch.sh`. All paths are relative to
`/home/user/multicore-server-challenge`. Read-only research; nothing in the repo was changed.

---

## 0. TL;DR (the things most likely to break a from-scratch server)

1. **Always frame responses with `Content-Length`** (or chunked). The loadgen uses `net/http.ReadResponse`; a
   200 without length is read until EOF -> 10 s timeout -> error (`bench/cmd/loadgen/client.go:126-136`).
2. **Never write extra bytes after a response.** If any byte is left in the client's buffer after the body, the
   loadgen closes the connection (`client.go:141-143`); a 204 with a body corrupts the next response.
3. **Always consume the full request body** (Content-Length bytes) even when answering early with 401/422, or the
   leftover body is parsed as the next request on the keep-alive connection (conformance sends bodies on 401 steps:
   `script.go:377,731,802,899`).
4. **Non-204 responses need `Content-Type` starting with `application/json`**, *including every 4xx*
   (`main.go:167-182`). Error body is exactly `{"errors":{"body":["..."]}}` (exact key sets, `check.go:122-138`).
5. **Exact key sets** for every object (`check.go:66-84`): extra or missing keys fail. List items must NOT contain
   `body`; single article MUST.
6. **Timestamps**: `^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$`, truncated (not rounded) to ms (`check.go:63`,
   `script.go:649`). Use binary timestamptz (int64 µs since 2000-01-01) and floor-divide by 1000; text format drops
   trailing zeros and depends on session TimeZone.
7. **Integers must be printed without `.`/`e`** (`check.go:49-56`): favoritesCount, articlesCount, comment id.
8. **JWT**: verify HS256 signature + `exp` (required, `exp` must be in the future); `sub` must be a JSON *string*
   of decimal digits; reject `alg` != HS256 (incl. `none`); **do not check `iat`/`nbf`** (load boxes' clocks may be
   ahead). Issued tokens: header `{"alg":"HS256","typ":"JWT"}`, claims exactly `{sub, iat, exp}`, `exp-iat=2592000`,
   base64url **without padding** (`script.go:38-71`).
9. **Query parsing**: `limit` 1..100, `offset` >= 0, digits only (leading zeros OK, `+`, space, `-`, `.`, empty,
   overflow -> 422); **empty `tag=` is ignored** (treated as absent) but **empty `limit=` is 422**; a query string may
   start with `&` (`/api/articles/feed?&limit=10&offset=0`, `script.go:587` + `script.go:178-185`).
10. **Order of checks**: auth (401) -> body validation (422) -> lookup (404) -> ownership (403). Tested combo:
    POST comment to unknown article with empty body = **422**, not 404 (`script.go:736`).
11. **Kotlin/Native: ignore SIGPIPE / use MSG_NOSIGNAL.** The loadgen closes a connection on its 10 s timeout while
    the server is still working; the later write must not kill the process (Restart=no, `box/challenge.service:5,18`).
12. **JVM: pass an explicit listen backlog** (`ServerSocketChannel.bind(addr, 65535)`); Java's default is 50.
    Box `somaxconn=65535` (`box/sysctl.conf:2`).
13. **No idle timeout** (or >= ~120 s). Think time is capped at 70 s (`vu.go:107`); each VU keeps one connection for
    the whole run. Behind Nginx keep idle >= 65 s (`SPEC.md:22-24`).
14. **FD budget**: one fd per VU on the server. Service `LimitNOFILE=200000` (soft=hard) on the box
    (`box/challenge.service:19`). **Locally in this sandbox `ulimit -n` is 20000 soft AND hard and root cannot raise
    it** (checked: `ulimit -n 200000` -> "Operation not permitted"), so a single local server process caps at ~19.9k
    connections; use `-think-scale` to emulate more users. Loadgen side: ~64,512 ephemeral ports per
    (load-box IP -> target IP:port) with `ip_local_port_range 1024 65535` (`bench/README.md:73-75`).
    Don't size any fd-indexed table at 65536 (fds go above 65535 past ~65k connections).

---

## 1. How the conformance suite works (mechanics that matter)

- Invocation: `conformance -base http://127.0.0.1:3000 -secret $JWT_SECRET [-transcript out.jsonl] [-q]`
  (`main.go:5,47-52`). CI (`test/run.sh:25,49`) runs it with `JWT_SECRET=multicore-server-challenge`,
  `HOST=127.0.0.1 PORT=3000`, on a fresh DB created from `conduit_dev` (`test/run.sh:13,31`), **after** polling
  `curl -sf $BASE/api/tags` once per second for up to 60 s (`test/run.sh:45-46`). CI does **not** diff against
  `golden-dev.jsonl`; only the in-script checks decide pass/fail (exit code, `main.go:103-107`).
- On the scoring box, `score/switch.sh:78-86` runs the same binary **on the full seed through port 80** (direct
  front: `HOST=0.0.0.0 PORT=80`, `switch.sh:27-28`), then resets the DB. A conformance failure there means no
  benchmark. Fixtures only use article ids <= 10000 and user ids <= 2000 so they work on both seeds
  (`script.go:17-18,88-137`).
- HTTP client: Go `net/http.Client{Timeout: 30 * time.Second}` with the default Transport (`main.go:66`):
  - keep-alive, one connection reused, **no pipelining**, sends `Accept-Encoding: gzip` automatically and
    transparently gunzips (so gzip responses are OK but optional);
  - request bodies: `nil` -> no body; `string`/`[]byte` sent verbatim; otherwise `json.Marshal` (`main.go:120-130`).
    `json.Marshal` of `map[string]any` **sorts keys** and **HTML-escapes `<`, `>`, `&` as `\u003c` `\u003e`
    `\u0026`**; non-ASCII (ü, ï) is sent as raw UTF-8; `\n` as `\n`, `"` as `\"`. Your JSON parser must decode
    `\uXXXX` (step `comments.create`, `script.go:737`, body `Conformance comment <b>&</b> "quoted" ünïcode`).
  - `Content-Type: application/json` is set whenever a body reader exists, **including the empty body `""`**
    (`main.go:137-139`, step `users.register.empty-body`, `script.go:258`).
  - `Content-Length`: always sent for POST/PUT (also `Content-Length: 0` for a bodyless POST like
    `/favorite`, `/follow`); **not sent for bodyless DELETE/GET**. Never chunked (all bodies have known length).
    No `Expect: 100-continue`.
  - `Authorization`: token `""` -> no header; `"raw:X"` -> header value `X` verbatim; else `Token <tok>`
    (`main.go:140-146`).
  - Go's header order: `Host`, `User-Agent: Go-http-client/1.1`, `Content-Length`, then the rest sorted
    (`Authorization`, `Content-Type`), `Accept-Encoding: gzip` last. Parse headers case-insensitively and in any
    order; don't validate `Host`.
- Response handling (`main.go:147-183`): reads the whole body; if non-empty, decodes the **first** JSON value with
  `UseNumber` (trailing garbage is not detected, but don't rely on that); then generic rules:
  - `status == 204`: body must be empty (`main.go:169-172`). Content-Type not checked.
  - `400 <= status < 500`: `Content-Type` must have prefix `application/json`, and `checkErrors` (below).
  - everything else (2xx, 3xx, 5xx): `Content-Type` must have prefix `application/json` (`main.go:178-181`).
  - `application/json; charset=utf-8` is fine (prefix match).
- Abort points (later steps are skipped, transcript ends, run FAILS): register (`script.go:245-247`), login
  (`277-279`), seeded login (`300-302`), comment create (`751-753`), article create (`842-844`), article rename
  (`925-927`).
- Fixture values on the dev seed (from `golden-dev.jsonl`, handy for local debugging): article X slug
  `headru-tut-thaistex-rer-dai-jaikun-wostailiot-wan-5000` (id 5000), author A `bruxrazaston37996`, viewer V
  `chetojairlanor100` (id 100), favoriter F `testelhustistit9170`, tag `nain` (X's tags
  `["nain","nean","nothiodreal","titear"]`), first non-own seeded comment id 25093, `X-1` slug
  `nareagiox-dougroudru-seadushi-trevaipi-shustevou-pleanen-droubean-4999`.

### What `golden-dev.jsonl` is and how it is compared
- One JSON line per step: `{"step","method","path","status","body"}` (`main.go:222-231`), re-encoded by Go
  (`SetEscapeHTML(false)`, **map keys sorted**, so your field order and escape style don't matter).
- Normalization (`main.go:236-277`):
  - any `"token"` string -> `"<token>"`;
  - `createdAt`/`updatedAt` strings that parse as RFC3339Nano and are **after `seed.End` = 2026-09-01T00:00:00Z**
    (`bench/seed/seed.go:30`) -> `"<now>"`; seeded timestamps are compared **exactly**;
  - in objects that have `author`, `body` and `id` (comments), an `id` created during the run -> `"<id>"`;
    created-comment ids in request paths -> `<id>` (`main.go:207-211`);
  - any top-level error object whose `errors.body` is an array -> `{"errors":{"body":["<msg>"]}}` (so message text
    and the number of messages are free).
  - Numbers are kept as their literal text (`UseNumber`): `23` vs `23.0` would differ.
- Everything else is exact: status, path, every field value, **array order**, created article slugs
  (`conformance-hello-world-2026-10001`, `conformance-no-tags-1-10002` .. `-3-10004`,
  `conformance-renamed-title-10001`). To be byte-identical you must not burn `articles` sequence values before
  those inserts (validate before `nextval`; no retries that consume ids) and run on a fresh `conduit_dev` copy with
  nothing else written. Recommended dev loop: `conformance ... -transcript run.jsonl && diff golden-dev.jsonl run.jsonl`.
- Statuses that occur in the golden: 200, 201, 204, 401, 403, 404, 422 only (no 400/405/500).

---

## 2. Numbered checklist of everything the suite checks

### A. Generic / transport
1. Every non-204 response: `Content-Type` prefix `application/json` (2xx, 4xx and 5xx) (`main.go:167-182`).
2. 204 responses: **zero-length body** (`main.go:169-172`). Use `Content-Length: 0` or omit it; never a body.
3. Body of every non-204 response must be valid JSON (`main.go:157-166`).
4. Error responses (all 4xx): exactly `{"errors": {"body": [<non-empty array of strings>]}}` - top-level keys
   exactly `errors`, `errors` keys exactly `body` (`check.go:122-138`). 5xx is not shape-checked but must be JSON.
5. Keep-alive across all 197 steps (Go reuses the connection); you must consume each request body fully, including
   on early 401/422 returns.
6. GET requests carry no body / no Content-Length; DELETE without body carries no Content-Length; POST/PUT always
   carry Content-Length (possibly 0). Treat a missing Content-Length as an empty body.

### B. Object shapes (exact key sets, `check.go:66-84`)
7. User (`check.go:140-150`): keys exactly `email, token, username, bio, image`; email/token/username non-empty
   strings; bio/image string or `null` (SQL NULL -> JSON `null`, **empty string stays `""`**, `script.go:378-381`).
8. Profile (`check.go:152-161`): exactly `username, bio, image, following`; following is a boolean.
9. Article (`check.go:163-204`): exactly `slug, title, description, tagList, createdAt, updatedAt, favorited,
   favoritesCount, author` **plus `body` only for single-article responses** (GET/POST/PUT/favorite/unfavorite);
   list items must **not** have `body` (`check.go:217`). slug/title/description/body non-empty strings.
   `tagList` is an array of non-empty strings, **strictly ascending by bytes** (sorted + unique)
   (`check.go:178-192`); `[]` when no tags (never `null`, `script.go:857`). `createdAt`/`updatedAt` match the
   timestamp regex and `updatedAt >= createdAt` (string compare, `check.go:196-198`). `favorited` boolean.
   `favoritesCount` non-negative JSON integer (`check.go:200-202`). `author` is a Profile.
10. List (`check.go:207-228`): top-level keys exactly `articles, articlesCount`; `articles` is an array
    (`[]` when empty, never null); items in **createdAt DESC** order (non-strict string compare);
    `articlesCount` integer in 0..1000.
11. Comment (`check.go:235-247`): exactly `id, createdAt, updatedAt, body, author`; `id` positive JSON integer;
    timestamps per regex; body non-empty string; author a Profile.
12. Comment list (`check.go:249-267`): top-level keys exactly `comments`; array; **createdAt DESC**.
13. Single-object wrappers are checked with exact top-level keys: `{"profile":...}` (`script.go:402`),
    `{"article":...}` (`script.go:646,824`), `{"comment":...}` (`script.go:740`), `{"tags":...}` (`script.go:208`).
    `{"user":...}` is checked via `checkUser(x.at("user"))` only, but emit exactly one key anyway (golden diff).
14. Timestamps: exactly 3 fractional digits + `Z`, UTC, **truncated** (`seed.ArticleCreated(id).UTC()
    .Truncate(time.Millisecond)`, `script.go:649,970`). Seed timestamps have sub-ms digits, so rounding fails.

### C. Tokens and auth
15. Issued tokens (register + login) (`script.go:38-71`): parse with golang-jwt v5,
    `WithValidMethods(["HS256"])`, `WithExpirationRequired()`; payload decoded with **`base64.RawURLEncoding`**
    (no `=` padding, URL alphabet); claims exactly 3 keys; `sub` a string that parses as int64; `iat`/`exp` JSON
    integers; `exp - iat == 30*24*3600 = 2592000`.
16. Login token `sub` == register token `sub` for the same user (`script.go:273-275`); seeded login `sub` = the
    seed id (`script.go:296-298`).
17. Tokens minted by the suite itself must be accepted (stateless): `{"sub":"<id>","iat":now,"exp":now+30d}`
    signed with the secret (`script.go:31-34`). golang-jwt serializes claims with **sorted keys**
    (`{"exp":..,"iat":..,"sub":".."}`) while the loadgen uses `sub,iat,exp` order: parse generically.
18. `GET /api/user` -> 401 for each of (`script.go:328-349`):
    - `no-header` (no Authorization),
    - `bearer-scheme` (`Bearer <valid jwt>`), `no-scheme` (`<valid jwt>` alone) - only the exact prefix `Token `
      is accepted (Go ref: `strings.CutPrefix(h, "Token ")`, `examples/go/util.go:218`),
    - `garbage` (`Token not.a.jwt`: 3 parts, invalid base64/JSON),
    - `wrong-secret`, `expired` (`exp` = now-10 d), `no-exp` (only sub+iat),
    - `numeric-sub` (`"sub": 100` as a JSON number), `non-numeric-sub` (`"sub":"abc"`),
    - `alg-none` (header `{"alg":"none","typ":"JWT"}`, empty signature, token ends with `.`),
    - `unknown-user` (valid token, `sub` = 999999999: `SELECT ... WHERE id=$1` returns no row -> 401).
19. Auth-optional endpoints with an *invalid* `Token garbage` header -> **401** (not anonymous):
    profile (`script.go:411`), list (`566`), single article (`667`), comments list (`730`).
20. **`GET /api/tags` ignores Authorization entirely** (`Token not-a-jwt` -> 200, `script.go:222-223`).
21. Auth-required endpoints without header -> 401: PUT user (`377`), follow/unfollow (`425,488`), feed (`475`,
    invalid token `476`), favorite/unfavorite (`670,707`), comment create/delete (`731,776`), article
    create/update/delete (`802,899,946`).
22. `GET /api/user` and `PUT /api/user` return the **presented token byte-for-byte** as `user.token`
    (`script.go:309-316,359-361`), not a fresh one.
23. Expiry semantics (golang-jwt v5): valid iff `now < exp` (no leeway). `iat`/`nbf` are not validated by the
    reference (`examples/go/util.go:223-224`); keep it that way (loadgen clocks can be ahead of the server).

### D. Users
24. `POST /api/users` success -> **201** `{"user":User}` with `bio:null,image:null` (`script.go:234-244`).
25. Register -> 422 for: duplicate username, duplicate email, duplicate seeded username (unique violation 23505)
    (`248-250`); missing password (`251`); empty username `""` (`252`); `"email": null` (`253`); `"username": 123`
    (`254`); no `user` wrapper (`255`); `"user": "string"` (`256`); malformed JSON `{"user": {"username": "u_x",`
    (`257`); empty body `""` (`258`); **password of 73 bytes** (`259`; bcrypt's 72-byte limit: reject > 72 bytes
    in UTF-8, do not truncate silently).
26. Register ignores unknown fields at both levels, incl. `bio`/`admin` inside `user` -> 201, `bio: null`
    (`script.go:260-264`).
27. Login success -> 200 (`267-276`); wrong password -> **401**; unknown email -> **401** (`280-281`); missing
    password -> 422; empty email -> 422; no wrapper -> 422 (`282-284`). Seeded users log in with `password123`
    against `$2a$10$...` hashes (`bench/seed/seed.go:20-22`); fields must equal the seed's username/email/bio/image
    (`script.go:286-299`).
28. `PUT /api/user` (`script.go:352-397`):
    - bio+image set -> 200, other fields unchanged, token = presented token;
    - **all five fields `null` -> 200, nothing changes** (`363-367`); `{"user":{}}` -> 200 unchanged (`368-371`);
    - taken username -> 422; taken email -> 422 (`372-373`);
    - `"email": ""` -> 422 (`374`); `"bio": 5` -> 422 (`375`); no wrapper -> 422 (`376`); no auth -> 401 (`377`);
    - **`"bio": ""` -> 200 with `bio: ""`** (`378-381`) - bio/image may be empty, email/username/password may not
      (Go ref `examples/go/util.go`/`users.go:250-254`);
    - username+email+password+bio at once -> 200 (`382-387`); afterwards old password and old email -> 401,
      new credentials -> 200 (`388-393`); GET /api/user shows the new username (`394-397`).

### E. Profiles and follows
29. `GET /api/profiles/:u` anonymous -> 200, `following:false`, bio/image from seed (`script.go:400-409`);
    unknown -> 404 (`410`); invalid token -> 401 (`411`); renamed user found under new name, old name -> 404
    (`412-416`). Usernames contain `_` (e.g. `no_such_user_zz`, `conformance_user2`), no percent-encoding.
30. Follow: no auth -> 401; unknown -> 404; follow -> 200 `following:true`; **follow again -> 200 true
    (idempotent)**; GET shows true; other viewer gets a valid profile (`425-445`).
31. Unfollow -> 200 false; again -> 200 false; unknown -> 404; no auth -> 401; GET shows false (`478-492`).

### F. Feed
32. New user's feed: 200, `articles: []`, `articlesCount: 0` (`script.go:419-424`).
33. After following A: feed slugs (limit 10) == `?author=A&limit=10` slugs, same `articlesCount`, every
    `author.following == true` (`462-470`); `?limit=1&offset=1` == 2nd item (`471-474`).
34. Feed: no auth -> 401; invalid token -> 401; **`limit=0` -> 422** (`475-477`).
35. After unfollow: empty again (`493-498`); seeded V's feed non-empty, all `following:true` (`499-508`).
36. Page check on the feed with base `/api/articles/feed?` -> paths `/api/articles/feed?&limit=10&offset=0` and
    `...?&limit=5&offset=5` (leading `&`); page 5-5 must equal items 5..9 of page 0-10 (`script.go:178-196,587`).

### G. Article list
37. Default (`GET /api/articles`): 20 items, `articlesCount == 1000` (capped), anonymous -> all
    `favorited:false`, `author.following:false` (`script.go:511-529`).
38. `limit=1` == first item; `limit=100` -> 100 items; `limit=5&offset=5` == items 5..9; **`limit=05&offset=005`**
    accepted and equal; `offset=100000000` -> 200, empty page, `articlesCount 1000` (`530-556`).
39. 422 for each (`script.go:557-565`): `limit=0`, `limit=101`, `limit=-1`, `limit=abc`, `limit=` (empty),
    `limit=1.5`, `limit=%2B5` (`+5`), `limit=%205` (` 5`), `offset=-1`, `offset=abc`, `offset=` (empty),
    `offset=99999999999999999999` (int64 overflow). Rule (Go ref `examples/go/util.go:103-137`): a present param
    (even empty) must be all ASCII digits, fit in int64, limit in 1..100. Percent-decoding doesn't change any
    outcome here (`%2B5`/`%205` are invalid decoded or not).
40. Filters: `tag` (5 items, each tagList contains the tag, `568-583`); page checks for tag, author, favorited
    (as F), feed (`584-587`).
41. **Precedence tag > author > favorited**: `author=V&tag=T` == tag-only result and count (`588-592`);
    `favorited=F&author=A` == author result (`606-609`).
42. **Empty `tag=` is ignored**: `tag=&author=A&limit=10` == author result (`593-596`) (Go ref: first *non-empty*
    filter, `examples/go/articles.go:165-175`).
43. Author list anonymous: `following:false`; as a follower: `following:true` (`447-461,597-605`).
44. Favorited list as F: all `favorited:true`; anonymous: all false; as V: shape only (`610-630`).
45. Unknown tag/author/favorited -> 200, `[]`, count 0, **not 404** (`631-640`).
46. After favoriting X, `?favorited=conformance_user2` -> exactly `[X]`, count 1, `favorited:true` (`688-695`).
47. After creating 4 articles, `?limit=4` returns those 4, oldest of them last (`880-886`); `?tag=zzconformancetag`
    -> exactly the new slug, count 1 (`887-891`); `?author=conformance_user2` -> 4 items, count 4 (`892-897`).
48. After deleting the article: `?tag=zzconformancetag` -> empty, count 0 (`953-958`).

### H. Single article, favorites
49. Seeded GET: every field equals the seed (title, description, body, sorted tagList, createdAt == updatedAt ==
    seed created truncated to ms, favoritesCount == number of seeded favoriters, favorited false, author)
    (`script.go:643-661`); as F -> `favorited:true` (`662-665`); unknown -> 404; invalid token -> 401 (`666-667`).
50. Favorite: no auth 401, unknown 404, POST -> `favorited:true`, count+1; **again -> still count+1**; GET as the
    user shows it (`670-687`). Unfavorite -> false, original count; again -> unchanged; unknown 404; no auth 401
    (`696-707`). Responses are full articles (with `body`).

### I. Comments
51. List seeded: exactly `nComments` items (all, since < 100), createdAt DESC; as viewer OK; unknown article 404;
    invalid token 401 (`script.go:710-730`). Golden order is `created_at DESC, id DESC` (ids 25093, 25095,
    25094 - **not** id order).
52. Create: no auth 401; `{"comment":{"body":""}}` 422; `{"comment":{}}` 422; no wrapper 422; unknown article
    with valid body -> **404**; unknown article with **empty body -> 422** (validation before lookup)
    (`731-736`).
53. Create success -> **201** `{"comment":...}`, body round-trips exactly (HTML chars, quotes, ü/ï),
    author = the new user with current bio, `author.following:false`, **`updatedAt == createdAt`** (same
    `now()`) (`737-750`).
54. After create: count+1 and the new comment is first (`754-765`); after V follows the commenter,
    `comments[0].author.following == true` (`767-773`).
55. Delete (`776-796`): no auth 401; not author 403; **comment exists but slug is another article -> 404**;
    unknown article 404; **non-integer id `abc` -> 404** (not 400/422); unknown id 999999999 -> 404; seeded
    comment by someone else -> 403; own -> **204 empty body**; list no longer has it; delete again -> 404.

### J. Create / update / delete article
56. Create: no auth 401 (`script.go:802`); 422 for (`803-819`): missing title; `description: ""`;
    `body: null`; `title: 7`; `tagList: "x"`; `tagList: ["ok",""]`; `tagList: [1]`; `tagList: [null]`; no wrapper;
    malformed JSON `{"article": `.
57. Create success -> **201**, slug matches `^conformance-hello-world-2026-(\d+)$` from title
    `Conformance: Hello, World! 2026` (slug = SLUGIFY(title) + "-" + id), tagList `[tag, newTag, newTag]` ->
    deduped + sorted `["nain","zzconformancetag"]`, favoritesCount 0, favorited false, updatedAt == createdAt,
    author.following false (`820-841`).
58. `tagList: []`, `tagList: null`, `tagList` absent -> 201 with `tagList: []` (`846-859`).
59. `GET /api/tags` afterwards: exactly one more tag, includes `zzconformancetag`, still sorted/unique
    (`860-874`); the new article GETs (`875-879`).
60. Update: no auth 401; **not author 403**; unknown 404; `title: ""` 422; `body: 1` 422; no wrapper 422
    (`899-904`).
61. Update `{"body":"Updated body","title":null}` -> 200, slug unchanged, title unchanged (null = unchanged)
    (`905-912`).
62. Update title `"  Conformance -- Renamed Title!  "` -> slug **`conformance-renamed-title-<same id>`**, title
    stored verbatim **with the spaces** (no trim), description updated, body kept (`913-923`); old slug -> 404,
    new slug -> 200 (`924-932`).
63. Favorite by V -> 200; comment by V -> 201 with author = V; GET as V -> favorited true, count 1 (`933-945`).
64. Delete: no auth 401; not author 403; unknown 404; own -> **204**; GET -> 404; comments of it -> 404; delete
    again -> 404 (`946-952`). Tags are **never deleted** (`959-962`). (Cascades come from the schema,
    `schema.sql:44-66`.)
65. Seeded author edits a seeded article's description -> slug unchanged, **createdAt unchanged**, `updatedAt >
    createdAt` (strictly, string compare), favoritesCount back to the original (`965-975`).

### K. Tags
66. `GET /api/tags` -> 200 `{"tags":[...]}`, >= 200 tags (seed), non-empty strings, strictly ascending
    (`script.go:205-221`). SQL `ORDER BY name` order; seed tags are lowercase ASCII so collation == byte order.

### L. Ordering invariants used everywhere
67. Lists: newest first by id (`ORDER BY a.id DESC`, `SPEC.md:87-88`); conformance only checks createdAt DESC
    (non-strict), but golden/slug equality requires the id order.
68. Comments: `ORDER BY c.created_at DESC, c.id DESC LIMIT 100` (`SPEC.md:234-235`).

---

## 3. Check-order matrix (what precedes what)

| Endpoint | Order (tested combos in **bold**) | Source |
|---|---|---|
| POST /api/users, /login | wrapper/shape 422 -> required strings 422 -> (register) password >72 B 422 -> SQL (23505 -> 422; login: no row/mismatch -> 401) | `examples/go/users.go:158-224` |
| GET /api/user | auth 401 -> row missing 401 | `users.go:227-241` |
| PUT /api/user | auth **401** -> body 422 -> bcrypt -> UPDATE (23505 -> 422, no row -> 401) | `users.go:244-287` |
| GET /api/profiles/:u | invalid header **401** -> 404 | `users.go:290-305` |
| POST/DELETE follow | auth **401** -> 404 | `users.go:308-334` |
| GET /api/articles, feed | auth (invalid 401 / feed missing 401) -> limit/offset 422 | `articles.go:158-186` |
| POST /api/articles | auth **401** -> body 422 -> insert | `articles.go:194-251` |
| PUT /api/articles/:slug | auth **401** -> body 422 -> 404 -> 403 | `articles.go:273-295` |
| DELETE /api/articles/:slug | auth 401 -> 404 -> 403 | `articles.go:298-308` |
| favorite / unfavorite | auth 401 -> 404 | `articles.go:326-344` |
| GET comments | invalid header 401 -> 404 | `comments.go:20-47` |
| POST comment | auth 401 -> **body 422 -> 404** | `comments.go:50-79` |
| DELETE comment | auth 401 -> non-integer id 404 -> (id, slug) lookup 404 -> 403 | `comments.go:82-108` |

(`users.go`, `articles.go`, `comments.go` are in `examples/go/`.)

---

## 4. Not tested by the suite (recommended behaviour = Go reference parity)

- **Unknown routes / wrong method on a known path**: Go ref returns JSON **404** `{"errors":{"body":["not
  found"]}}` with `Content-Type: application/json` (`examples/go/routes.go:30-33`). No 405.
- **Trailing slash** (`/api/tags/`): no route -> 404 in the ref. Don't redirect.
- **Percent-encoding in path segments** (slugs/usernames): never exercised (slugs are `[a-z0-9-]`, usernames
  `[a-z0-9_]`, tags `[a-z]`, loadgen sign-up names `lg<alnum>b<n>n<n>` and run tags are alnum: `vu.go:35-44,223`).
  The Go ref decodes `%XX` in path values; decoding is cheap insurance.
- **Query values**: Go's `url.Query()` decodes `%XX` and `+`->space and takes the first value of a repeated key.
  A key without `=` (e.g. `?limit`) counts as present-and-empty -> 422 in the ref.
- **Offset > int4 in the feed**: reference feed SQL casts `($2::int + $3::int)`; offset >= 2^31 makes Postgres
  error (`integer out of range`) -> 500 in the ref. Untested; clamp or 422 is fine.
- **`offset=100000000` on the full seed** (`script.go:548`) runs in `switch.sh` on 500k articles; make sure an
  absurd offset does not make Postgres compute per-row subqueries for 500k skipped rows (paginate ids first, enrich
  after). Client timeout there is 30 s.
- **HEAD, `Expect: 100-continue`, chunked request bodies, HTTP/1.0**: never sent by either client. Never emit 1xx.
- **Self-follow**: allowed in the ref (no check); the loadgen avoids it (`vu.go:314-316`).
- **Auth-optional endpoints with a valid token for a deleted/unknown user**: ref treats it as viewer=id (no DB
  check; only GET/PUT /api/user check the row). No user lookup per request is needed.
- **Login password > 72 bytes**: ref's bcrypt compare fails -> 401.
- Error message text: free (`SPEC.md:44-45`).

---

## 5. Loadgen HTTP client behaviour (server-design relevant)

### 5.1 Exact request bytes (`bench/cmd/loadgen/client.go:57-79`)
```
<METHOD> <path?query> HTTP/1.1\r\n
Host: <host of the FIRST -target URL, e.g. 10.0.0.2 or 127.0.0.1:3000>\r\n
User-Agent: conduit-loadgen/1\r\n
Accept: application/json\r\n
Accept-Encoding: gzip\r\n
Authorization: Token <jwt>\r\n                     <- every request in practice (see below)
Content-Type: application/json\r\n                 <- only when there is a body
Content-Length: <n>\r\n                            <- when body != nil OR method != GET (so 0 for bodyless POST/DELETE)
\r\n
<body>
```
- Header names exactly as above (canonical case), this order, no `Connection` header (HTTP/1.1 default
  keep-alive), never chunked, never `Expect`. The whole request (headers + body) is written with **one `Write`**
  (`client.go:117`); large bodies (POST /api/articles, ~1-3 KB) may still arrive in several segments -> buffer until
  `Content-Length` bytes are in.
- **Every request carries `Authorization: Token <jwt>`**: `v.token` is minted before the first request
  (`vu.go:144`) and only ever replaced (`vu.go:204,217,229`). That includes `GET /api/tags`,
  `POST /api/users` and `POST /api/users/login` -> ignore auth on those three; every other read runs one HS256
  verification and a non-zero viewer.
- Loadgen-minted JWT (`jwt.go:9-20`): header literal `{"alg":"HS256","typ":"JWT"}` =
  `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9`, payload literal `{"sub":"<id>","iat":<unix>,"exp":<unix+2592000>}`,
  RawURL base64 everywhere. iat is the **load box's clock**.
- Request bodies are `json.Marshal` of maps -> keys sorted (`vu.go:213,225,361,398,407,455-457`):
  - login `{"user":{"email":"<u>@example.com","password":"password123"}}`
  - sign-up `{"user":{"email":"lg<run>b<box>n<k>@loadgen.test","password":"password123","username":"lg<run>b<box>n<k>"}}`
  - comment `{"comment":{"body":"<sentence>"}}`
  - article `{"article":{"body":"<p>\n\n<p>...","description":"<sentence>","tagList":["t1",..],"title":"Word Word ..."}}`
    (1-3 distinct seed tags, `vu.go:439-459`)
  - PUT article `{"article":{"body":"..."}}` (body only -> slug never changes), PUT user `{"user":{"bio":"<sentence>"}}`.
- Paths/queries actually sent (`vu.go:325-409`): `/api/tags`; `/api/articles?limit=10&offset=K`;
  `/api/articles/feed?limit=10&offset=K`; `/api/articles?tag=T&limit=10&offset=K`; `/api/articles?author=U&limit=5`;
  `/api/articles?favorited=U&limit=5`; `/api/articles/:slug`; `/api/articles/:slug/comments`; `/api/profiles/:u`;
  POST/DELETE `/api/articles/:slug/favorite`; POST `/api/articles/:slug/comments`; DELETE
  `/api/articles/:slug/comments/:id`; POST/DELETE `/api/profiles/:u/follow`; POST `/api/articles`;
  PUT `/api/articles/:slug`; GET/PUT `/api/user`; POST `/api/users`, `/api/users/login`.
  K is `0` 70% of the time else 10/20/30/40 (`vu.go:283-288`). No percent-encoding ever appears.

### 5.2 Response parsing (`client.go:101-176`)
- `br.Peek(1)` then `http.ReadResponse(br, nil)` with a pooled 4 KiB `bufio.Reader` (`client.go:26,120-126`).
  Framing rules of Go's reader: `Transfer-Encoding: chunked` OK; `Content-Length` OK; 1xx/204/304 have no body;
  **anything else without a length is read until EOF** (and marks the connection closed) -> with keep-alive that
  is a 10 s timeout. Status line `HTTP/1.1 NNN Reason` (3-digit code required; reason may be anything).
  Don't send both Content-Length and Transfer-Encoding.
- Body: if a callback wants it **and status is 2xx**, it is read (gunzipped if `Content-Encoding: gzip`,
  `client.go:147-176`); otherwise drained unread (`client.go:131-136`). Gzip is optional; identity is simplest.
- After the body: `c.reused = true`; **connection is closed if the response had `Connection: close` (or was
  HTTP/1.0 without keep-alive) or if ANY extra byte is buffered** (`client.go:140-143`).
- Success/failure accounting (`metrics.go:225-253`): failed = transport error OR `status < 200` OR
  `status >= 400`. So every 4xx/5xx is an error against the 1% budget; 3xx would count as success (never send).
  Under a correct server the workload produces **no** 4xx (unique sign-up names, own articles/comments only,
  self-follow avoided, deep links `id = N - rank` in 1..N, `vu.go:413-419`). Locally pass `-articles 10000` for the
  dev DB or deep links 404 (`run.go:34`, `bench/README.md:55`).

### 5.3 Fields the loadgen parses (must be correct or the user model degrades silently)
- login/sign-up: `user.token` (string; used for all later requests of that VU, so it must verify and carry the
  right `sub`) (`vu.go:189-194,214-231`).
- lists: `articles[].slug`, `.tagList` (mapped to seed tags), `.favorited`, `.author.username`,
  `.author.following` (`vu.go:237-271`). An empty list keeps the previous list.
- single article: `article.slug`, `tagList`, `favorited`, `author.username`, `author.following`
  (`vu.go:273-281`). The favorite/follow toggles pick POST vs DELETE from these flags.
- comment create: `comment.id` as a **JSON integer** (int64) -> later `DELETE .../comments/<id>` (`vu.go:362-371`).
- article create: `article.slug` -> later article page + PUT (`vu.go:383-394`).
- Go's `encoding/json` matches keys case-insensitively and ignores extra fields; types must match (id must be a
  number, flags booleans).

### 5.4 Pipelining, keep-alive, retry, timeout
- **No pipelining**: strictly write request -> read full response -> next request on the same connection.
- **One TCP connection per VU** (`client.go:18-21,36-40`), dialed lazily at the VU's first request
  (`client.go:102-114`), `TCP_NODELAY` on (`client.go:110-112`), **no TCP keepalive probes** (`KeepAlive: -1`,
  `client.go:49`). It is reused for the whole run unless an error or `Connection: close` happens.
- **Timeout**: one 10 s deadline per request covering dial + write + read + the retry
  (`client.go:23,56,105,116`). On any error the client closes the connection (`client.go:87`) and redials on the
  next request; the server will see EOF/RST while possibly still processing -> writes may hit EPIPE/ECONNRESET.
- **Retry once** (`client.go:82-98,117-125,178-181`): only if the connection was *reused* (had served >= 1
  response) and the failure is on the write, or before the first response byte, with EOF / unexpected EOF /
  ECONNRESET / EPIPE. The retry dials a fresh connection; its latency includes both attempts. Not retried: fresh
  connections, timeouts, dial errors, malformed responses, errors after the first byte. So a server that closes
  idle connections costs extra dials and latency but no errors; a server that closes *fresh* connections or
  half-writes responses produces errors.
- **Idle gaps**: think time exp(mean 7 s) capped at **70 s** (`vu.go:99-107`), session length exp(15 min) cap 60
  min (`vu.go:155`), next session starts immediately on the same connection (`vu.go:154-171`). Max idle gap per
  connection ~70 s (+ request time). Go ref uses IdleTimeout 75 s (`examples/go/main.go:61`); the top Rust entry
  keeps idle keep-alive unlimited (`submissions/rust-tokio-Scooter1337/README.md:7`). Recommendation: no idle
  timeout (or >= 120 s); never `Connection: close`; no max-requests-per-connection.
- **Phase end**: at `stopAt = t0 + ramp + measure + tail` (`run.go:87-88,102`) every VU returns and closes its
  socket (`vu.go:137`): a burst of N FINs within ~1 s. Close on read()==0 promptly; leaked CLOSE_WAIT fds would
  accumulate across the ~10+ probes of a search on the same server process (DB and server are not reset between
  phases, `bench/README.md:113`).
- **Arrival**: VUs arrive evenly over the 60 s ramp (`run.go:106-111`), then think before the first request
  (`vu.go:145`): ~users/60 new connections per second (100k users -> ~1.7k accepts/s). Accept queue must not
  overflow (SYN retransmit = 1 s -> p99 > 1 s): explicit backlog 65535 (kernel caps at `somaxconn` 65535).
- VU g uses seeded user `g mod 100000 + 1` (`vu.go:91`) -> above 100k users two VUs share a user (harmless).
- Between phases the search waits >= 5 s and until target CPU < 15% (max 90 s) (`bench/README.md:113`): don't
  busy-spin when idle.

### 5.5 Sizes (for buffer design)
- GET request ~250-330 bytes (JWT ~150 chars). Largest request: POST /api/articles ~1-3 KB.
- Responses: tags (200 names) ~2 KB; list of 10 (no body, with author bio) ~5-6 KB; article with ~1 KB body
  ~2 KB; comments mean 5 (cap 100 returned) ~1.5 KB typical, tens of KB worst case. Write path must handle partial
  writes (EAGAIN) for the occasional large response; idle connections should hold no buffers (100k connections).

### 5.6 FDs and ports per box
- **Load box**: 1 fd + 1 ephemeral port per VU per target address. `ip_local_port_range = 1024 65535`
  (`box/sysctl.conf:4`) -> at most **64,512 concurrent connections per (load-box source IP, target IP:port)**;
  the default kernel range (32768-60999) would give only 28,232. More users per box need several target IPs
  (`-target http://ip1,http://ip2`, VU g dials `addrs[g mod n]`, `client.go:31-34`, `run.go:277-294`) or more boxes.
  Port exhaustion shows up as error class `no_local_port` (EADDRNOTAVAIL, `metrics.go:159-160`) and counts as
  errors. Search runs `ulimit -n 1048576` before `loadgen run` (`search.go:690`); search max is 120,000 users
  (`search.go:87`). This "~64k per address" ceiling is the classic limit; the GCP numbers in
  `submissions/goose-epoll-xeonfx/README.md:66-69` used 4 loadgen processes each aimed at its own target address.
- **Server (direct front)**: N client sockets + <= 95 Postgres sockets + listen/epoll/eventfd + runtime files.
  `LimitNOFILE=200000` (soft = hard) in `box/challenge.service:19`; system-wide `fs.file-max 2097152`,
  `fs.nr_open 1048576` (`box/sysctl.conf:6-7`); `nf_conntrack_max 1048576` (`box/setup-box.sh:91-93`). The
  best results so far are 100k users (`LEADERBOARD.md:7`) and 150k in a contestant's own GCP test, so 200k fds is
  the real hard cap. Bind `0.0.0.0` (HOST from env) so several target IPs work.
- Other ~64k traps to avoid in our own code: fd-indexed arrays sized 65536 (fds exceed 65535 past ~65k
  connections; size from `getrlimit(RLIMIT_NOFILE)`), `select()`/FD_SETSIZE, one thread per connection
  (threads-max / `vm.max_map_count` 65530 on stock kernels; Ubuntu 24.04 ships 1048576, this sandbox 262144),
  one mmap per connection buffer (counts against `max_map_count`). Kotlin/Native: raise soft NOFILE to hard at
  startup (as `submissions/rust-mio-foovoo/src/main.rs:54-57` does); JVM does this itself (`-XX:+MaxFDLimit`
  default).
- **This sandbox (local lab)**: `ulimit -n` = 20000 soft and hard, root without CAP_SYS_RESOURCE (cannot raise);
  `somaxconn 65535`, `tcp_max_syn_backlog 1024` (box: 65535), port range 1024-65535, `tcp_tw_reuse 2`,
  `pid_max 32768`, `max_map_count 262144`, `epoll max_user_watches 3663070`, 4 CPUs. So: one loadgen process <=
  ~19.9k VUs, one server process <= ~19.9k connections. Emulate higher load with `-think-scale` (0.2 x 15k VUs ~
  75k users' request rate, but note it also shortens sessions, so more bcrypt logins), or run several loadgen
  processes (`-box-index/-id-offset`) and several server processes (SO_REUSEPORT) if connection count itself must
  be tested.

---

## 6. Other runtime-contract facts touched by these tools

- Health check: `curl -sf [-m 2] http://.../api/tags` must return 200 within 60 s of start
  (`test/run.sh:45-46`, `score/switch.sh:38-46`). Postgres is restarted and the page cache dropped right before
  the start (`switch.sh:89-95`): first requests are cold.
- Direct front: `HOST=0.0.0.0 PORT=80`, `CAP_NET_BIND_SERVICE` ambient (`box/challenge.service:20-21`).
  Nginx front: `127.0.0.1:3000`, Nginx keeps 256 idle upstream conns/worker, upstream keepalive 60 s, gzips JSON
  >= 1 KB, HTTP/1.1 with `Connection` header stripped (`box/site.conf:4-35`).
- Postgres auth on 127.0.0.1 is **scram-sha-256** (`box/setup-box.sh:65-66`): the hand-written wire client needs
  SASL SCRAM-SHA-256 (role `conduit` / password `conduit`, `DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit`,
  `SPEC.md:13`). Session-level `SET` is allowed, server-wide changes are not (`README.md:41-43`).
- Rules relevant to auth code: no caching of JWT verifications or bcrypt results (`README.md:52-55`); HS256 +
  `exp` checked on every request; bcrypt cost 10 for every new hash (`README.md:60-61`). Seeded users all share
  one hash `$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq` (`bench/seed/seed.go:20-22`), but
  caching its result is forbidden.

---

## 7. Reference SQL that defines the conformance answers (verbatim from SPEC.md / examples/go)

`ARTICLE_LIST_SELECT` (`SPEC.md:70-80`, `$1` = viewer):
```sql
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
```
`ARTICLE_FULL_SELECT` = same with `a.body` after `a.description` (`SPEC.md:82`). `ORDER_PAGE` =
`ORDER BY a.id DESC LIMIT $2 OFFSET $3` (`SPEC.md:87`). `SLUGIFY(x)` =
`trim(both '-' from lower(regexp_replace(x, '[^A-Za-z0-9]+', '-', 'g')))` (`SPEC.md:84`); app-side equivalent is
`seed.Slugify` (`bench/seed/seed.go:186-199`: lowercase ASCII, every run of non-`[a-z0-9]` -> one `-`, trim `-`).

List/count pairs (`SPEC.md:155-158`):
```sql
-- none
ARTICLE_LIST_SELECT ORDER_PAGE
SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s
-- tag = $4
ARTICLE_LIST_SELECT WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC
SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s
-- author = $4
ARTICLE_LIST_SELECT WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER_PAGE
SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s
-- favorited = $4
ARTICLE_LIST_SELECT WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC
SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s
```
Feed (`SPEC.md:164-167`):
```sql
ARTICLE_LIST_SELECT WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
    (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x
  WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC
SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s
```
Article create (`SPEC.md:181-189`, one transaction):
```sql
BEGIN
INSERT INTO articles (id, slug, author_id, title, description, body)
SELECT n.id, SLUGIFY($2) || '-' || n.id, $1, $2, $3, $4
  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
RETURNING id
-- only if tagList is non-empty ($1 = tagList as text[]):
INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING
INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])
COMMIT
```
Article update (`SPEC.md:196-201`):
```sql
SELECT id, author_id FROM articles WHERE slug = $1                                     → 404; author_id ≠ viewer → 403
UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE SLUGIFY($2) || '-' || id END,
       updated_at = now()
 WHERE id = $1
ARTICLE_FULL_SELECT WHERE a.id = $2
```
Comments (`SPEC.md:229-246,251-253`):
```sql
SELECT id FROM articles WHERE slug = $1                                                → 404
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
  FROM comments c JOIN users u ON u.id = c.author_id
 WHERE c.article_id = $2
 ORDER BY c.created_at DESC, c.id DESC
 LIMIT 100

WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3)
           RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
  FROM c JOIN users u ON u.id = c.author_id

SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
 WHERE c.id = $1 AND a.slug = $2                                                       → 404; author_id ≠ viewer → 403
DELETE FROM comments WHERE id = $1
```
Users/profiles/favorites/tags (`SPEC.md:101-102,108,114,121-124,132-134,140-144,216-221,261`):
```sql
INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
RETURNING id, username, email, bio, image
SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1
SELECT id, username, email, bio, image FROM users WHERE id = $1
UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
 WHERE id = $1
RETURNING id, username, email, bio, image
SELECT u.id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
  FROM users u WHERE u.username = $2                                                   → 404
SELECT id, username, bio, image FROM users WHERE username = $1                         → 404
INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING
DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2
SELECT id FROM articles WHERE slug = $1                                                → 404
INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING
DELETE FROM favorites WHERE user_id = $1 AND article_id = $2
ARTICLE_FULL_SELECT WHERE a.id = $2
SELECT name FROM tags ORDER BY name
```
Session settings: the Go reference sets none (pgxpool defaults, `examples/go/main.go:41-54`). For a hand-written
client, request binary result format for `timestamptz`/`int8`/`bool`/`text[]`, or set `TimeZone=UTC` in the
startup packet if using text (text format omits trailing fractional zeros, e.g. `2024-09-15 14:22:32+00`).
Comment/article inserts must produce `created_at == updated_at` (both `DEFAULT now()` in the same statement,
`schema.sql:33-34,64-65`); unique violation is SQLSTATE `23505`.
