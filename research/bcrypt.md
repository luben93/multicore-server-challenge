# bcrypt (cost 10) for the zero-dependency Kotlin Conduit server

Research notes. The repo was only read. All paths are relative to `/home/user/multicore-server-challenge` unless they
are absolute. The scratch prototypes and harnesses I used to check the claims below are in
`/tmp/claude-0/-home-user-multicore-server-challenge/99796a5c-b120-524c-822d-dc73b94b523b/scratchpad/bc/`
(`c/harness.c`, `c/vec.c`, `gen/gen.py` -> `kt/jvm/BC.kt`, `kt/Main.kt`, `kt6/Warm.kt`, `kt/native/*`).

---------------------------------------------------------------------------------------------------------------------

## 0. Summary

* **Load.** Session starts arrive at `users / 900 s` (mean session 15 min, `WORKLOAD.md:25-33`). 24.5% are logins
  (bcrypt verify) and 0.5% are sign-ups (bcrypt hash). `PUT /api/user` in the workload only changes `bio`
  (`WORKLOAD.md:51`), so it does no bcrypt. At 100k users that is **27.2 verifies/s + 0.56 hashes/s = 27.8
  hashes/s**, which is **0.11% of the ~25k req/s**.
* **CPU per hash** (cost 10 = 1,067,721 Blowfish block encryptions = 68.3 M dependent S-box loads), measured in this
  sandbox (Intel Xeon, 4 vCPU, shared with the parent's load tests, so expect ±10% noise):

  | implementation | 1 lane | 2 lanes | 3 lanes | 4 lanes | 5-6 lanes |
  |---|---|---|---|---|---|
  | Openwall C `BF_crypt` (libxcrypt 4.4.36), gcc -O2 -march=native | 48.6-49.4 ms | - | - | - | - |
  | Openwall + Scooter1337's interleaved `conduit_bcrypt_batch` | - | 39-41 ms/hash | 28.3-28.5 | **22.3-23.8** | - |
  | **Kotlin/JVM prototype, JDK 27 C2, variant C** (state allocated in the hot method) | 48-52 ms | 25-29 | 23-27 | **22.9-24.8** | 22.9-24.6 |
  | Kotlin/JVM prototype, variant A (arrays passed to a separate `rekeyN` method) | 48-52 | 27.7-30.8 | 35.8-40.8 | 33.0-37.2 | n/a |
  | (JVM variant C again, measured as thread CPU time while the parent's load test ran) | 50.6-50.9 | 25.0-25.8 | 23.1-23.2 | 23.1-23.4 | 23.3-24.0 |
  | **Kotlin/Native 2.4.21 `-opt`, `IntArray` state allocated in the hot function** (thread CPU time) | 55.2-55.3 | 30.0-30.1 | 21.8 | **18.5-20.7** | n/a |
  | Kotlin/Native with `CPointer<IntVar>` state from `nativeHeap` (don't) | 94.7 | 118 | 97.3 | 102 | n/a |

  Other reported numbers: tigokraft 23.9 ms/hash at 4 lanes against libxcrypt's 46 ms on an i5-9500
  (`submissions/c-iouring-tigokraft/README.md:94-96`). goose says 5 lanes cost "about 1.3 times one hash", which is
  3.7x the throughput (`submissions/goose-epoll-xeonfx/bcrypt.goose:319-321`, `README.md:52-54`). foovoo says 4 lanes
  give "about 3x" the `bcrypt` crate's speed on an M2 (`submissions/rust-mio-foovoo/README.md:39-45`). kotlin-vertx
  measured Bouncy Castle at 51 ms per verify and jBCrypt/at.favre at 56-61 ms
  (`submissions/kotlin-vertx-canleon/src/main/kotlin/conduit/infrastructure/security/BcryptPasswordHasher.kt:12-13`).
* **The CPU at stake.** At 100k users, 1 lane costs 27.8 x 48 ms = **1.34 cores**. 4 lanes cost 27.8 x 23 ms =
  **0.64 cores**. The saving is about 0.7 core, or ~9% of the 8-core box, and that CPU goes back to Postgres, which is
  the bottleneck at ~70% of the box.
* **Recommendation.** Use 4 lanes (5 at most on the JVM; see the bytecode-size limit in §5). Run **2 dedicated
  platform threads**, with one "gatherer" at a time that waits **150-300 ms** after the oldest queued job for the
  batch to fill. The other thread starts only on a full batch or an old job. Use priority nice 0 to 10 (make it a
  knob). Bound the queue, and drop jobs whose connection has closed. At 100k users a batch of 4 fills in ~108 ms on
  average, so a 150-300 ms window only costs latency at low load, and logins are too rare to move p95 or p99.
* **Test vector from the seed.** Every seeded user has password `password123` and the **same** hash
  `$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq` (`bench/seed/seed.go:21-23`, used by
  `bench/cmd/seedgen/main.go:76`). It is `$2a$`, cost 10, salt `ZSfEoPvlcsj2XfvsSeK25e`, and hash
  `m4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq`. I checked it with the Openwall core here: `password123` matches, `password124`
  gives `...ezBXBo3NUjyvsoY3AVPF8m6f80nPmTAC`. The same string with `$2b$` also matches. The verify path must accept
  `$2a$`.

---------------------------------------------------------------------------------------------------------------------

## 1. Workload math and what latency bcrypt may use

* `WORKLOAD.md:24-33`: think time has mean 7 s and the session has mean 15 min. Users who arrive during the ramp start
  mid-session, so logins run at the steady rate from the first second. Session start is 75% `GET /api/user`, 24.5%
  `POST /api/users/login` (bcrypt verify) and 0.5% `POST /api/users` (bcrypt hash).
* Loadgen: `bench/cmd/loadgen/vu.go:207-231` (login body `{"user":{"email","password":"password123"}}`; sign-up
  body uses the same password). The per-request timeout is **10 s** (`bench/cmd/loadgen/client.go:23`). A timeout is
  an error.
* Rates as a function of users N: session starts are N/900 per second. Hashes are 0.25 x N/900 = **N/3600 per second**
  (27.8/s at 100k, 41.7/s at 150k). Requests are about 0.25 x N per second, so bcrypt requests are **0.11%** of
  requests.
* Consequence (spelled out by cobol-gnucobol-benmandrew, `submissions/cobol-gnucobol-benmandrew/README.md:25-34`): a
  deliberate wait of a few hundred ms for the batch to fill cannot move p95. It uses at most 0.11 of the 1 percentage
  point that p99 may spend above 1 s, and it is far from the 10 s timeout. Their Poisson table, for a 500 ms window
  and 4 lanes:

  | Users | lambda per 500 ms | expected batch size | mean wait of first login |
  |---|---|---|---|
  | 12,000 | 1.67 | 2.54 | 462 ms |
  | 24,000 | 3.33 | 3.46 | 369 ms |
  | 36,000 | 5.00 | 3.83 | 283 ms |
  | 48,000 | 6.67 | 3.95 | 221 ms |

  At 100k users (27.8/s), the 3 companions of a first job arrive in 3/27.8 = **~108 ms** on average. With a 150-300 ms
  window, batches are nearly always full at the user counts we care about.

---------------------------------------------------------------------------------------------------------------------

## 2. The algorithm in enough detail to implement from scratch

The references are the Openwall/libxcrypt core vendored by the #1 entry,
`submissions/rust-tokio-Scooter1337/native/crypt-bcrypt.c` (unmodified libxcrypt 4.4.36, `native/README.md:1-8`),
and the from-the-paper C# version `submissions/csharp-sockets-jh-d/src/BCrypt.cs`.

### 2.1 Hash string format

```
$2b$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq
0123456789...                                               length 60
[0]='$' [1]='2' [2]=variant [3]='$' [4..5]=cost (2 decimal digits) [6]='$'
[7..28]  = 22 chars salt  (16 bytes)
[29..59] = 31 chars hash  (23 bytes)
```

Validation as each implementation does it:

* C# `BCrypt.VerifyJob` (`csharp-sockets-jh-d/src/BCrypt.cs:82-96`): `hash.Length != 60 || hash[0] != '$' ||
  hash[1] != '2' || hash[3] != '$' || hash[6] != '$'` means reject. The variant must be `a`, `b` or `y`.
  `cost = (hash[4]-'0')*10 + (hash[5]-'0')`, and `cost < 4 || cost > 31` means reject. The salt is
  `Decode(hash[7..29), 16 bytes)` and the expected value is `Decode(hash[29..60), 23 bytes)`. A null job means 401.
* Openwall `BF_crypt` (`crypt-bcrypt.c:720-746`): `setting[0] != '$' || setting[1] != '2' || setting[2] < 'a' ||
  setting[2] > 'z' || !flags_by_subtype[setting[2]-'a'] || setting[3] != '$' || setting[4] < '0' || setting[4] > '3'
  || setting[5] < '0' || setting[5] > '9' || (setting[4] == '3' && setting[5] > '1') || setting[6] != '$'` means
  EINVAL. Then `count = 1 << cost`, and `count < min` is rejected (`min` = 16 from `BF_full_crypt`, so cost >= 4).
  Then the salt is decoded (22 chars; any invalid char rejects).
* tigokraft `parse_setting` (`c-iouring-tigokraft/src/bcrypt.c:144-154`), Scooter1337 batch
  (`rust-tokio-Scooter1337/native/bcrypt-batch-impl.h:52-58`), goose `parse_hash` (`goose-epoll-xeonfx/bcrypt.goose:258-269`)
  and foovoo `parse` (`rust-mio-foovoo/src/bcrypt2.rs:383-401`) do the same. foovoo also accepts `2x` but treats it
  as `2b`. Rust #1 `valid_setting` only lets `$2a$10$`, `$2b$10$` and `$2y$10$` with length 60 into the batch path
  (`rust-tokio-Scooter1337/src/password.rs:164-169`).

Cost-parsing edge cases (Openwall, checked in `scratchpad/bc/c/vec.c`): `$2b$03$...` is rejected (count 8 < 16), and
`$2b$32$...` is rejected. Recommendation: accept `$2a$`, `$2b$` and `$2y$`; reject `$2x$` and everything else; cost
04-31; length exactly 60 for stored hashes. Generate `$2b$10$` (C# `FormatHash` `BCrypt.cs:72-79`, tigokraft
`bc_gensalt` `bcrypt.c:169-175`, Rust `salt()` `password.rs:69-81`, foovoo `format_2b` `bcrypt2.rs:362-368` and goose
`answer` `bcrypt.goose:306` all write `$2b$`).

### 2.2 bcrypt's radix-64 (not RFC 4648 base64)

Alphabet (index 0..63): `./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789`
(`crypt-bcrypt.c:372-373`, `BCrypt.cs:14`, `c-iouring-tigokraft/src/bcrypt.c:101`, `bcrypt2.rs:180`). There is no
padding. Bits go MSB first: the standard base64 bit order with a different alphabet.

Decode table (Openwall `BF_atoi64`, indexed by `char - 0x20`, 64 = invalid, `crypt-bcrypt.c:375-383`):

```
64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 0, 1,
54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 64, 64, 64, 64, 64,
64, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 64, 64, 64, 64, 64,
64, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42,
43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 64, 64, 64, 64, 64
```

Encode (C# `BCrypt.Encode`, `BCrypt.cs:432-451`, identical to Openwall `BF_encode` `crypt-bcrypt.c:424-457`):

```
i = 0
while i < len:
    c1 = d[i++];            out(A[c1 >> 2]);  c1 = (c1 & 0x03) << 4
    if i >= len: out(A[c1]); break
    c2 = d[i++]; c1 |= c2 >> 4;  out(A[c1]);  c1 = (c2 & 0x0f) << 2
    if i >= len: out(A[c1]); break
    c2 = d[i++]; c1 |= c2 >> 6;  out(A[c1]);  out(A[c2 & 0x3f])
```

16 bytes become 22 chars and 23 bytes become 31 chars.

Decode (C# `BCrypt.Decode`, `BCrypt.cs:453-471`, Openwall `BF_decode` `crypt-bcrypt.c:395-421`):

```
o = 0; i = 0
while o < outLen:
    c1 = V(s[i++]); c2 = V(s[i++]);           if either < 0: fail
    out[o++] = (c1 << 2) | ((c2 & 0x30) >> 4); if o == outLen: break
    c3 = V(s[i++]);                            if < 0: fail
    out[o++] = ((c2 & 0x0f) << 4) | ((c3 & 0x3c) >> 2); if o == outLen: break
    c4 = V(s[i++]);                            if < 0: fail
    out[o++] = ((c3 & 0x03) << 6) | c4
```

**Non-canonical trailing characters.** The 22nd salt char carries only 2 used bits (`c2 & 0x30`), and the 31st hash
char only 4 (`c3 & 0x3c`). Openwall canonicalises the salt's last char when it writes the output:
`output[28] = BF_itoa64[BF_atoi64[setting[28] - 0x20] & 0x30]` (`crypt-bcrypt.c:837-840`). Verified here:
`$2b$10$abcdefghijklmnopqrstuv` gives output whose salt ends in `...stuu`. Consequences:

* Verify by **constant-time compare of the 23 decoded bytes** (C# `Matches` uses
  `CryptographicOperations.FixedTimeEquals`, `BCrypt.cs:98`; foovoo `ct_eq(&p.hash, &o[k][..23])` `bcrypt2.rs:419`),
  not of the 60-char string. A string compare (Rust #1 `password.rs:179-180`, tigokraft `server.c:57-63`, goose
  compares the 31 hash chars, `bcrypt.goose:297-304`) works for canonical hashes, but the byte compare is more robust
  and cheaper.
* When you format a new hash, encode the 16 salt bytes yourself (`$2b$10$` + `enc(salt,16)` + `enc(raw,23)`), as C#
  does. Do not copy input text.
* foovoo's decoder is strict and rejects non-zero trailing bits (`bcrypt2.rs:339-359`). Openwall and C# are lenient.
  Lenient is fine.

### 2.3 Key bytes: UTF-8, NUL terminator, 72-byte cutoff

The key is the password's bytes (UTF-8 from the JSON string), **followed by one NUL byte**, used **cyclically** to
fill 18 big-endian 32-bit words (72 bytes). If the password is 72 bytes or more, only its first 72 bytes are used and
the NUL never appears.

* Openwall `BF_set_key` (`crypt-bcrypt.c:565-669`): `for i in 0..17: for j in 0..3: tmp = (tmp << 8) | *ptr;
  if (!*ptr) ptr = key; else ptr++;` So after the NUL it restarts at the key's first byte, and the NUL is part of the
  cycle.
* C# `Job` constructor (`BCrypt.cs:37-60`): `n = min(len, 72); key[n] = 0; keyLen = min(n + 1, 72);` and the byte
  index wraps at `keyLen`.
* foovoo `key_words` (`bcrypt2.rs:267-286`) and tigokraft `key_words` (`bcrypt.c:156-167`) do the same.
* Test vectors that pin the cutoff (`scratchpad/bc/c/vec.c` and `harness.c` output):
  * `72 x 'p'` and `73 x 'p'` give the same hash at `$2b$04$abcdefghijklmnopqrstuu`:
    `...uuNt.0ah97gHY3F7JC1Z6EXmQc0bQBhIO`. `71 x 'p'` gives `...uuTYDowBoYf34KLYBHbWu7CBwc/8jbH1q`.
  * `0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789` (72 bytes) and the same with
    `chars after 72 are ignored` appended both give `$2a$05$abcdefghijklmnopqrstuu5s2v8.iXieOjg/.AySBTTZIIVFJeBui`.
* API rule: the conformance suite requires **422 for a 73-byte password at registration**
  (`bench/cmd/conformance/script.go:259`, `users.register.password-over-72-bytes`). C# returns 422 for register and for
  `PUT /api/user` (`Handlers.cs:516, 556`). On login, Rust returns `false` (401) without hashing for passwords over 72
  bytes (`rust-tokio-Scooter1337/src/api.rs:346-349, 370-373`). Copy both behaviours.
* An embedded NUL in a JSON password (`"\u0000"`) is legal JSON. The byte-oriented implementations (C#, foovoo, our
  Kotlin) keep it as an ordinary byte inside the key: the key is all n bytes plus the terminating NUL, cycled over
  n+1 bytes. That matches the Rust `bcrypt` crate. Openwall's C-string API instead stops at the *first* NUL, so
  `abc\0def` would hash as `abc`. That is why Rust #1 sends passwords that contain NUL to the portable crate
  (`password.rs:7-23`, `password_batch.rs:88-90`). Using the byte array consistently, for hash and verify, is correct
  and self-consistent.

### 2.4 `$2a$` / `$2b$` / `$2y$` / `$2x$`

Openwall flags (`crypt-bcrypt.c:603-606, 671-675`): `$2a$` has bug=0 and safety=0x10000. `$2b$` and `$2y$` have bug=0
and safety=0. `$2x$` has bug=1 (emulates the old sign-extension bug: bytes >= 0x80 were sign-extended when ORed in).
The `$2a$` "safety" flips bit 16 of `initial[0]`, the P[0] used for the initial ExpandKey but **not** the per-iteration
expanded key. It does so only when the buggy and correct key schedules are identical (`diff == 0`) and a non-benign
sign extension happened. That requires `0xff` bytes before other high-bit bytes.

**Valid UTF-8 never contains 0xff**, and Kotlin's `String.encodeToByteArray()` replaces lone surrogates with `?`. So
for every password this server can receive, `$2a$ == $2b$ == $2y$`. The C#, tigokraft, goose and foovoo entries all
ignore the safety bit. Recommendation: treat a/b/y identically and reject `x`. If you want a fully faithful
implementation, here is a vector that exercises the safety bit: the key bytes
`ff a3 33 34 ff ff ff a3 33 34 35` at salt `/OK.fbVrR/bpIqNJ5ianF.` cost 05 give
`$2a$05$/OK.fbVrR/bpIqNJ5ianF.ZC1JEJ8Z4gPfpe1JOr/oyPXTWl9EFd.` with `$2a$` but
`$2b$05$/OK.fbVrR/bpIqNJ5ianF.o./n25XVfn6oAPaUvHe.Csk4zRfsYPi` with `$2b$`/`$2y$` (computed here with Openwall). The
other `$2a$`/`$2b$` historical difference (OpenBSD's 8-bit length wrap for passwords over 255 bytes) cannot happen,
because the key never exceeds 72 bytes.

### 2.5 Salt words

The 16 decoded salt bytes become 4 big-endian words, `salt[i] = b[4i]<<24 | b[4i+1]<<16 | b[4i+2]<<8 | b[4i+3]`
(`BCrypt.cs:57-58`). Openwall decodes into a word array and calls `BF_swap` on little-endian hosts. That is the same
thing.

### 2.6 Blowfish state, F and one block encryption

* Initial state: the 18-word P-array, then the four 256-word S-boxes, all from the hex digits of pi. Sources you can
  port: `csharp-sockets-jh-d/src/BlowfishInit.cs:6-144` (P first, then S as one 1024-entry array),
  `c-iouring-tigokraft/src/bf_pi.h` (`BF_P0[18]`, `BF_S0[4][256]`), `rust-mio-foovoo/src/bcrypt2.rs:14-177` and
  `crypt-bcrypt.c:95-370` (`BF_init_state`, S before P). Sanity anchors: `P[0]=0x243f6a88`, `P[17]=0x8979fb1b`,
  `S0[0]=0xd1310ba6`, `S0[255]=0x6e85076a`, `S1[0]=0x4b7a70e9`, `S2[0]=0xe93d5a68`, `S3[0]=0x3a39ce37`,
  `S3[255]=0x3ac372e6`.
* `F(x) = ((S0[x >>> 24] + S1[(x >>> 16) & 0xff]) ^ S2[(x >>> 8) & 0xff]) + S3[x & 0xff]`, with 32-bit wrapping
  adds.
* Encrypt (L, R), Openwall form (`BF_ENCRYPT`, `crypt-bcrypt.c:524-544`), same as C# `Encrypt` (`BCrypt.cs:191-201`):

  ```
  L ^= P[0]
  for i = 1, 3, 5, ..., 15:
      R ^= F(L) ^ P[i]
      L ^= F(R) ^ P[i+1]
  (L, R) = (R ^ P[17], L)
  ```

  On the critical path, XOR `P[i]` into the half before F's result arrives (`R = (R ^ P[i]) ^ F(L)`), as goose does
  (`bcrypt.goose:21-29`) and Openwall's `BF_ROUND` does (`R ^= P[N+1]` before `tmp3 += tmp1`, `crypt-bcrypt.c:483-498`).

### 2.7 EksBlowfishSetup (the expensive key schedule)

Treat the state as one array of 1042 words, `st[0..17] = P` and `st[18..1041] = S0|S1|S2|S3`, as C# does
(`StateWords = 18 + 1024`, `BCrypt.cs:16`). A "re-encrypt pass" walks `i = 0, 2, ..., 1040`, encrypts the running
(L, R) block and writes it to `st[i], st[i+1]`, so it rewrites P and then all of S in place. Later blocks read S
entries that were already rewritten; that is intended.

```
# 1. init + ExpandKey(state, salt, key)          -- C# Setup (BCrypt.cs:154-167), Openwall crypt-bcrypt.c:756-781
st = pi                                   # P then S
for i in 0..17: st[i] ^= key[i]           # key = 18 words from 2.3
L = R = 0; sp = 0
for i in 0, 2, ..., 1040:                 # P (9 blocks) and S (512 blocks), ONE continuous chain
    L ^= salt[sp]; R ^= salt[sp+1]; sp ^= 2  # salt words 0,1 then 2,3 then 0,1 ...: phase continues from P into S
    (L, R) = encrypt(L, R)
    st[i] = L; st[i+1] = R

# 2. 2^cost rounds                                -- C# ComputeBatch (BCrypt.cs:132-138), Openwall crypt-bcrypt.c:783-814
repeat 2^cost times:                      # cost 10: 1024 times
    for i in 0..17: st[i] ^= key[i]       # ExpandKey(state, 0, key)
    rekey(st)                             # L=R=0, then for i in 0,2,..,1040: (L,R)=encrypt(L,R); st[i]=L; st[i+1]=R
    for i in 0..17: st[i] ^= salt[i & 3]  # ExpandKey(state, 0, salt): 16-byte salt cycled as an 18-word key
    rekey(st)

# 3. Output                                       -- C# Finish (BCrypt.cs:180-189), Openwall crypt-bcrypt.c:820-846
ctext = [0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274]   # "OrpheanBeholderScryDoubt" BE
for each block j in 0, 2, 4: repeat 64 times: (ctext[j], ctext[j+1]) = encrypt(ctext[j], ctext[j+1])
raw24 = ctext as 24 big-endian bytes; keep raw24[0..22] (23 bytes)   # "bug-compatible": only 23 of 24 are encoded
```

* The (L, R) chain is **reset to 0 at the start of every rekey pass** and runs continuously through P and S within a
  pass (Openwall `BF_body`, `crypt-bcrypt.c:546-563`).
* The order of the 64 encryptions does not matter, because the three blocks are independent under a fixed state.
  C# runs `k` outer and `j` inner (`BCrypt.cs:184-187`); Openwall runs 64 per block.
* Work: 521 + 2^10 x 2 x 521 + 192 = **1,067,721 encryptions** per cost-10 hash, which is 64 dependent S-box loads
  each. Steps 1 and 3 are 0.07% of it, so only `rekey` needs optimising.
* `count` is a 32-bit `1 << cost`. Use a `Long` or count down an `Int` in Kotlin: `1 shl 31` overflows `Int` to
  negative.

### 2.8 Assembling, hashing and verifying

```
hash(pw):   salt = 16 bytes from /dev/urandom (SecureRandom) ; raw = bcrypt(pw, salt, 10)
            -> "$2b$10$" + enc(salt, 16) + enc(raw, 23)          # 60 chars
verify(pw, stored): parse 2.1 (reject -> 401 without hashing); raw = bcrypt(pw, dec(stored[7..29],16), cost)
            -> constantTimeEquals(raw[0..22], dec(stored[29..60], 23))
```

### 2.9 Test vectors (all re-verified in this sandbox with the Openwall core; `scratchpad/bc/c/harness.c`, `vec.c`)

| password (bytes) | setting / expected full hash |
|---|---|
| `password123` | `$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq` (**seed**) |
| `password123` | `$2b$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq` (same with `$2b$`) |
| `password124` | `$2a$10$ZSfEoPvlcsj2XfvsSeK25ezBXBo3NUjyvsoY3AVPF8m6f80nPmTAC` (mismatch case) |
| `password123` | `$2b$04$abcdefghijklmnopqrstuuK7Sjs7rFYArh/ytIZsOeM/z4RV2Fw2i` (cheap unit test) |
| `password123` | `$2b$10$abcdefghijklmnopqrstuu0SYq8twpcthS10uxQ26rv0s3Obj8Ufu` |
| `U*U` | `$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW` (classic OpenBSD/Openwall vector) |
| `U*U*` | `$2a$05$CCCCCCCCCCCCCCCCCCCCC.VGOzA784oUp/Z0DY336zx7pLYAy0lwK` |
| `U*U*U` | `$2a$05$XXXXXXXXXXXXXXXXXXXXXOAcXxm9kjPGEMsLznoKqmqw7tc8WCx4a` |
| `` (empty) | `$2a$05$CCCCCCCCCCCCCCCCCCCCC.7uG0VCzI2bS7j6ymqJi9CdcdxiRTWNy` |
| 72-char `0123...6789` (with or without more chars after it) | `$2a$05$abcdefghijklmnopqrstuu5s2v8.iXieOjg/.AySBTTZIIVFJeBui` |
| byte `a3` | `$2b$05$/OK.fbVrR/bpIqNJ5ianF.Sa7shbm4.OzKpvFnX1pQLmQW96oUlCq` (also `$2a$`/`$2y$`, same hash part) |
| `72 x 'p'` = `73 x 'p'` | `$2b$04$abcdefghijklmnopqrstuuNt.0ah97gHY3F7JC1Z6EXmQc0bQBhIO` |
| `71 x 'p'` | `$2b$04$abcdefghijklmnopqrstuuTYDowBoYf34KLYBHbWu7CBwc/8jbH1q` |
| `één 🙂` (UTF-8 `c3 a9 c3 a9 6e 20 f0 9f 99 82`) | `$2b$04$......................8s6VUJLJ1DDlV7xNO7sZksS.U52MSbu` |
| `batch self test` | `$2a$04$abcdefghijklmnopqrstuuM5.Jm4ZjoirouZjlg2TjPbXhQEN/8Bm` |
| Openwall self-test key `38 62 20 d0 c1 d2 cf cc d8`, cost **00** (count = 1; allow it only internally) | `$2a$00$abcdefghijklmnopqrstuui1D709vfamulimlGcq0qq3UvuUasvEa` (a/b/y); `$2x$` gives `...VUrPmXD6q/nVSSp7pNDhCR9071IfIRe` (`crypt-bcrypt.c:897-902`) |
| `ff a3 33 34 ff ff ff a3 33 34 35` | `$2a$05$/OK.fbVrR/bpIqNJ5ianF.ZC1JEJ8Z4gPfpe1JOr/oyPXTWl9EFd.` vs `$2b$05$/OK.fbVrR/bpIqNJ5ianF.o./n25XVfn6oAPaUvHe.Csk4zRfsYPi` (only if you implement the `$2a$` safety bit) |
| non-canonical salt `$2b$10$abcdefghijklmnopqrstuv` + `password123` | output `$2b$10$abcdefghijklmnopqrstuu0SYq8twpcthS10uxQ26rv0s3Obj8Ufu` |

Startup self-test inputs used by the entries: Rust #1 (`password.rs:136-157`) uses `("batch self test",
"$2a$04$abcdefghijklmnopqrstuu")`, `("één 🙂", "$2b$04$......................")`, `("", "$2y$04$abcdefghijklmnopqrstuu")`
and the 72-char digit string with `"$2b$04$012345678901234567890u"`, comparing every lane count against the serial
core. COBOL (`crypt_blowfish.c:1107-1121`) uses `"U*U"`, `""`, a 72-char alnum string and `"\xa3"`. tigokraft
`--bcrypt-selftest` (`server.c:151-196`) compares against libxcrypt on random passwords.

---------------------------------------------------------------------------------------------------------------------

## 3. Multi-lane interleaving

### 3.1 Why it works

Each round's four S-box loads depend on the previous round's result. Per round the chain is about 1 L1 load
(4-5 cycles) plus add, xor, add and xor, so a single hash runs at roughly 1 round per ~8-10 cycles and leaves most
issue ports idle. N independent hashes (different passwords and salts, the same cost) interleaved round by round in
one instruction stream let the out-of-order core overlap the N chains. The work per hash is unchanged; there is no
shared state and no shortcut (`c-iouring-tigokraft/src/bcrypt.c:1-7`, `rust-mio-foovoo/src/bcrypt2.rs:1-9`,
`BCrypt.cs:7-11`). Gains flatten at about 4 lanes. Past that, the core is throughput-bound: 4 loads + 4 ALU ops per
round per lane, plus index arithmetic. One state is 4,168 bytes, and 4 states plus the code fit easily in L1d/L2.

### 3.2 C#, #2 (`csharp-sockets-jh-d/src/BCrypt.cs`)

* `ComputeBatch(Job[] jobs, int n)` (`:120-140`) works on 1-4 jobs **of the same cost** (`CanPairWith` compares
  `Cost`, `:62`). All lanes' states sit in one `stackalloc uint[1042*4]` and run `Setup` one by one. Then
  `for r = 1<<cost; r > 0; r--`: `XorKey` on every lane, `Rekey(n,...)`, `XorSalt` on every lane, `Rekey(n,...)`.
  Then `Finish` runs per lane.
* `Rekey1..Rekey4` (`:207-430`) are hand-written. The 16 rounds are fully unrolled. In each half-round, every lane's
  `r` update is followed by every lane's `l` update (`r0, r1, r2, r3`, then `l0, l1, l2, l3`). The block halves stay in
  locals, and each lane is addressed from **one pointer** with constant displacements: P at `+0..17` and the S-boxes at
  `+18, +274, +530, +786`. The index math is `(nuint)` so the JIT folds the offsets, and the methods carry
  `[MethodImpl(AggressiveOptimization)]`. Lane 0 of Rekey4:
  `r0 ^= (((a[(nuint)(l0 >> 24) + 18] + a[(nuint)(byte)(l0 >> 16) + 274]) ^ a[(nuint)(byte)(l0 >> 8) + 530]) + a[(nuint)(byte)l0 + 786]) ^ a[1];`
* It uses raw pointers, so there are no bounds checks. The README gives no speed numbers (`README.md:75-77`).

### 3.3 Rust #1 Scooter1337 (`rust-tokio-Scooter1337/native/`)

* `bcrypt-batch.c:1-38` `#include`s the unmodified Openwall core and defines `batch_f`. It then includes
  `bcrypt-batch-impl.h` three times with `LANES` = 2, 3 and 4 to build `batch_run2/3/4`. `conduit_bcrypt_batch(keys,
  settings, out, n)` dispatches on n.
* `bcrypt-batch-impl.h:1-13` `batch_encrypt<LANES>` is `always_inline` with `for (l < LANES)` loops inside every
  half-round, which the compiler unrolls. `:16-44` `batch_expand` has mode 0 (salted initial expansion), 1 (P ^= key)
  and 2 (P ^= salt[i&3]). `:47-86` `batch_run` validates every setting, requires the same cost across lanes, reuses
  Openwall's `BF_decode`, `BF_swap` and `BF_set_key` (so the flags and safety are preserved), runs
  `for n = 1<<cost; n; --n { expand(1); expand(2); }`, finishes, canonicalises the salt char and wipes the state with
  volatile stores.
* Rust side: `password.rs:83-134` handles 1 lane (Openwall single) or 2-4 lanes (batch). `batch_self_test`
  (`:136-157`) runs at pool creation (`password_batch.rs:22`). Passwords over 72 bytes or containing NUL never enter
  the native path (`password_batch.rs:88-90`).
* My measurement of that exact C (gcc 13 -O2 -march=native, this Xeon): 1 lane (plain Openwall) 48.6-49.4 ms.
  2 lanes 78-82 ms per batch (39-41 ms/hash, only 1.2x). 3 lanes 85 ms (28.3 ms/hash, 1.7x). 4 lanes 89-95 ms
  (22.3-23.8 ms/hash, **2.0-2.2x**). The 2-lane build is weak with gcc; my Kotlin/JVM 2-lane code does better (§5).

### 3.4 tigokraft C (#3) (`c-iouring-tigokraft/src/bcrypt.c`)

* Its own implementation (not Openwall). `enc(int N, ...)` (`:18-29`) and `expand(N, st, kw, sw)` (`:34-56`) are
  `always_inline`. When `sw` is non-null, the salt-stream position for S word `w = 18 + b*256 + i` is `w & 3`. `eks(N)`
  (`:59-89`) builds `ss[l][i] = sw[l][i & 3]` as an 18-word "salt key", runs `expand(N, st, kw, sw)`, then
  `for r < 1<<cost: expand(N, st, kw, NULL); expand(N, st, ss, NULL);`, then 64 x ORPHEAN.
  `EKS_N(1..4)` (`:91-97`) instantiates noinline versions for each N.
* `bc_hash_n` (`:179-197`) copies `setting[0..29)` as given and appends `enc(ct, 23)`.
* Built with `-O2 -march=native` (`build.sh:7`). It reports **23.9 ms CPU/hash at 4 lanes against libxcrypt's 46 ms**
  on an i5-9500 (`README.md:89-99`). Its README attributes "~14% bcrypt" of CPU on the 4-core test slice
  (`README.md:115`).

### 3.5 COBOL (#4) (`cobol-gnucobol-benmandrew/src/crypt_blowfish.c:908-1122`)

* `_crypt_blowfish_lanes` was added to crypt_blowfish 1.3. `BF_LROUND(k, L, R, N)` is the Openwall round for lane k.
  `BF_LENCRYPT` wraps every half-round in `BF_LALL` (a `for k < NL` loop). `BF_DEFINE_LBODY(1..4)` (`:951-971`)
  re-encrypts P, then S, with `((BF_word *)d[k]->ctx.S)[i]` as a flat 1024-word S. `BF_lane_setup` (`:985-1032`) does
  the per-lane salted expansion, and `BF_lane_finish` (`:1035-1058`) does the per-lane output.
* Lanes whose cost differs from the first valid lane run alone afterwards (`:1074-1077, 1099-1100`). State is in
  `static __thread BF_lane lanes[4]` and is memset to zero after use. `_crypt_blowfish_lanes_selftest` (`:1107-1121`)
  runs in every hasher before use, and if it fails the hasher falls back to one hash at a time (`pd-bc.cpy:519-524`).
* Built with `-O2 -funroll-loops` (`build.sh:9`).

### 3.6 foovoo Rust (#6) (`rust-mio-foovoo/src/bcrypt2.rs`)

* `Lanes<const N: usize> { p: [[u32;18];N], s: [[[u32;256];4];N] }`. `f()` (`:187-192`) masks indices to 0..=255, so
  the compiler drops the bounds checks. `enc` (`:202-222`) loops over `k` inside each half-round; it uses a slightly
  different but equivalent ordering (`l ^= p[2i]; r ^= f(l); r ^= p[2i+1]; l ^= f(r)`, final
  `(r ^ p[17], l ^ p[16])`). `expand(key, Option<salt>)` (`:226-264`) alternates salt words with `(t & 1) * 2`.
* `bcrypt_batch` (`:432-451`) packs arbitrary counts into 4/3/2/1-lane runs. The tests check bit-exactness against the
  `bcrypt` crate for lengths 1, 8, 71, 72, 73 and 90, high bytes and NULs (`:462-491`), and they include the seed hash
  vector (`:464-467`). It reports ~3x the crate's throughput on an M2 (`README.md:39-45`).

### 3.7 goose (#9) (`goose-epoll-xeonfx/bcrypt.goose`)

* There are 5 lanes. `encipher5` (`:35-46`) uses `const for` unrolling over lanes. It writes `b ^= p[J]; b ^= f(a)`,
  with P before F, "keeping that XOR off the chain" (`:21-29`). `expand0_5` (`:88-112`) is separate from the one-lane
  salted `expand_state` (`:53-73`).
* When fewer than 5 jobs are present, the idle lanes duplicate lane 0, so the shape stays fixed
  (`:364-366`, `for k in lanes..LANES { keys[k] = keys[0]; salts[k] = salts[0]; }`). That wastes CPU. On the JVM,
  dispatch on lane count instead, as C# and tigokraft do.
* It claims "five hashes interleaved cost about 1.3 times one hash" (`:319-321`), which is 3.7x throughput
  (`README.md:52-54`).

---------------------------------------------------------------------------------------------------------------------

## 4. Scheduling: threads, batch windows and not starving Postgres

| entry (rank) | bcrypt threads on 8 vCPU | lanes | collection window | gather policy | priority | queue / overload | refs |
|---|---|---|---|---|---|---|---|
| rust-tokio-Scooter1337 (#1, 100k) | `BCRYPT_THREADS` default `cores.div_ceil(8)` = **1** | 2-4 | **160 ms** from the first job's enqueue (`BCRYPT_BATCH_MS`) | the dispatcher task **acquires a worker permit before it starts collecting**, so while the worker is busy, jobs pile up and the next batch is drained immediately (its deadline has passed) | default | `mpsc::channel(1024)` | `src/main.rs:77-85`, `src/password_batch.rs:21-58`, `README.md:16` |
| csharp-sockets-jh-d (#2, 95k) | `BCRYPT_THREADS` = **2** | 1-4 | **300 ms** (`BCRYPT_BATCH_WAIT_MS`) from when the collecting thread took the first job | `lock (Collecting)`: **one thread collects at a time**, the others compute. A job with a different cost is re-queued. Jobs whose `Conn.Closed` are dropped | `BCRYPT_NICE` default **0** (setpriority per gettid) | unbounded `BlockingCollection` | `src/CpuWork.cs:6-99`, `src/Program.cs:49`, `README.md:75-77, 93` |
| c-iouring-tigokraft (#3, 84k) | `BCRYPT_THREADS` = ncpu/2 = **4** | 1-4 | **150 ms** (`BCRYPT_WAIT_MS`) | one gatherer at a time (`gathering` flag + `pthread_cond_timedwait`). Other threads start **only on a full batch**. `cond_broadcast` after a take so the leftovers get a new gatherer | default | unbounded list | `src/server.c:37-148, 717-725`, `README.md:89-99, 192-194` |
| cobol-gnucobol-benmandrew (#4, 84k) | **3** hasher *processes* (libcob is not thread-safe) | 1-4 | **500 ms** after the **oldest** queued job arrived | a single collector process (epoll over worker socketpairs) sends a batch to an idle hasher at once if 4 are queued, or else at the deadline. A job that queued behind busy hashers goes out as soon as one is free | **nice 10** | socket framing | `src/pd-bc.cpy:1-7, 227-229, 412-442, 512-524`, `src/pd-main.cpy:141-160`, `README.md:23-34` |
| rust-mio-foovoo (#6, 80k) | `BCRYPT_THREADS` = **2**: worker 0 is the "primary", the rest are overflow | 1-4 | primary holds the oldest job up to **200 ms** (`BCRYPT_PAIR_WAIT_MS`, capped at 400). Overflow workers take only full batches or jobs **older than 500 ms** | cancelled jobs are removed (`retain(!cancelled)`) | **SCHED_BATCH + nice 10** (`BCRYPT_NICE`). "nice 19 / SCHED_IDLE would starve logins into timeouts" | **bounded 256, 503 when full** | `src/pool.rs:1-6, 47-135, 183-194`, `src/main.rs:79-80`, `README.md:39-46` |
| goose-epoll-xeonfx (#9, 62k) | `HASHERS` = **2** | 1 or 5 | **250 ms** from the first job (`BCRYPT_BATCH_MS`). "250 instead of 100 fills more bcrypt lanes" | each hasher blocks on `qget`, then gathers until the deadline or 5 jobs | **nice 10** | queue | `bcrypt.goose:319-370` (nice 10 at `:325`), `README.md:52-54, 94-95` |
| kotlin-vertx-canleon (#12, 46k) | max(1, cores/2) = 4 | 1 (Bouncy Castle) | none | thread pool | default | - | `src/main/kotlin/conduit/Main.kt:27` |

How the good entries avoid starving Postgres:

1. **Few threads.** 1-2 bcrypt threads hold bcrypt to at most 12-25% of the box. At 100k users the demand is ~0.64
   core with 4 lanes, so one thread is ~60% busy and a second is headroom for bursts. tigokraft's 4 threads are only
   safe because they start only on full batches.
2. **Batching itself.** Bigger batches mean half the CPU per hash. The wait window is "group commit for bcrypt".
3. **Lower priority** (nice 10 on 3 of the top 6). The service runs as user `challenge`, not root
   (`box/challenge.service:13-14`), so you may lower your threads' priority but not raise it. #1 and #2 do not use nice.
   Make it a knob (`BCRYPT_NICE`, default 0 or 5) and A/B it.
4. **Drop dead work.** C# drops jobs whose connection closed (`CpuWork.cs:89-95`) and foovoo drops cancelled jobs
   (`pool.rs:111`). Under overload this stops the workers hashing for clients that already timed out.
5. **Bounded queue + 503** (foovoo) keeps overload from turning into unbounded memory and latency.

Suggested policy for our server (a mix of C#, tigokraft and foovoo):

```
BCRYPT_THREADS=2  BCRYPT_LANES=4  BCRYPT_WAIT_MS=200 (A/B 150..300)  BCRYPT_NICE=0 (A/B 10)  BCRYPT_QUEUE=1024
worker loop:
  lock(q)
  wait until q non-empty
  if I am the gatherer (no one else gathering):
      gathering = true
      deadline = q.head.enqueuedAt + WAIT          # from the OLDEST job (COBOL/foovoo), not from "now"
      while q.size < LANES && now < deadline: cond.await(deadline - now)
      gathering = false
  else:
      wait until q.size >= LANES || q.head.age >= 2*WAIT     # overflow thread: full batches / old jobs only
  take up to LANES jobs with the same cost as the head; drop jobs whose connection is closed
  signalAll()                                        # leftovers need a gatherer
  unlock; compute batch (dispatch on n = 1..4); post results to each job's event loop and wake it
```

Hand-off back to the event loop: tigokraft pushes to a per-worker done-list under a mutex and writes an eventfd
(`server.c:65-73`). foovoo pushes into the loop's inbox and calls `mio::Waker` (`pool.rs:125-134`). C# continues the
request directly on the bcrypt thread (`Handlers.AfterBcrypt`, `Handlers.cs:570-597`). It formats the user JSON and the
JWT there for login, or queues the INSERT/UPDATE for register and update. Login order in C#: read the user row first
(`Pg.Read`, `Handlers.cs:525-540`). An unknown email or a stored hash that does not parse gives 401 without bcrypt
(`Handlers.cs:719-721, 801-806`). Otherwise the verify is queued. Register hashes first, then INSERTs (`Handlers.cs:516-521`).

---------------------------------------------------------------------------------------------------------------------

## 5. Recommendations for Kotlin/JVM (measured with a generated prototype on JDK 27 / Kotlin 2.4.21)

Prototype: `scratchpad/bc/gen/gen.py` generates `kt/jvm/BC.kt`, with Pi tables parsed from `BlowfishInit.cs`. All
variants pass every vector in §2.9 for 1-4 lanes (`kt/Main.kt`, "correctness: all vectors match").

1. **State layout:** one `IntArray(1042)` per lane, `P = [0..17]`, `S_b = [18 + 256*b ..]`, the C# layout.
   `F(x) = ((a[(x ushr 24) + 18] + a[((x ushr 16) and 0xff) + 274]) xor a[((x ushr 8) and 0xff) + 530]) + a[(x and 0xff) + 786]`.
   One reference per lane keeps register pressure low: 4 lanes need 4 array refs + 8 halves + temps on 16 GPRs.
2. **Remove bounds checks by allocating the state in the hot method (variant C).** When `val a = IntArray(W)` is
   allocated in the same compiled method as the rekey loop, C2 knows `a.length == 1042`, and every index is
   provably in range: `(x ushr 24) + 18` is in [18, 273], `((x ushr 16) and 0xff) + 274` is in [274, 529], and so on.
   With the arrays passed as parameters to a separate `rekeyN` method (variant A), the checks stay. Measured at
   4 lanes: **A = 33-37 ms/hash, C = 22.9-24.8 ms/hash** wall time, or 23.1-23.4 ms as thread CPU time. For 1 lane
   both are ~48-52 ms. My explanation for the
   gap (fewer range checks, better scheduling) is an inference; I did not have hsdis to read the assembly. Either
   way, variant C is the one to ship. Its structure (`hashC4` in `kt/jvm/BC.kt`):

   ```kotlin
   fun hashC4(k0: IntArray, ..., s0: IntArray, ..., cost: Int, o0: ByteArray, ...) {
       val a = IntArray(W); setup(a, k0, s0); val sk0 = IntArray(18) { s0[it and 3] }   // x4 lanes
       var rounds = 2L shl cost                     // 2^cost x (key pass, salt pass)
       while (rounds > 0) {
           val odd = (rounds and 1L) == 1L
           val x0 = if (odd) sk0 else k0 // ... x1..x3
           for (j in 0 until 18) { a[j] = a[j] xor x0[j]; b[j] = b[j] xor x1[j]; c[j] = ...; d[j] = ... }
           var xl0 = 0; var xr0 = 0; /* ... lanes 1..3 */
           var i = 0
           while (i < W) {
               var l0 = xl0 xor a[0]; var r0 = xr0      // ... lanes 1..3
               r0 = r0 xor a[1] xor ((((a[(l0 ushr 24) + 18] + a[((l0 ushr 16) and 0xff) + 274]) xor a[((l0 ushr 8) and 0xff) + 530]) + a[(l0 and 0xff) + 786]))
               r1 = ...; r2 = ...; r3 = ...
               l0 = l0 xor a[2] xor (( F(a, r0) )); l1 = ...; l2 = ...; l3 = ...
               // ... rounds 3..16 fully unrolled, lanes interleaved per half-round
               xl0 = r0 xor a[17]; xr0 = l0; a[i] = xl0; a[i + 1] = xr0   // ... lanes 1..3
               i += 2
           }
           rounds--
       }
       finish(a, o0) // ... lanes 1..3
   }
   ```

   Write the unrolled body with a code generator (a script in the repo or a Gradle task) rather than by hand. The
   C# file shows what 4 lanes look like (`BCrypt.cs:348-430`).
3. **Stay under HotSpot's huge-method limit (8000 bytecode bytes; `-XX:+DontCompileHugeMethods` is the default).**
   Measured method sizes: `hashC1` 1350 B, `hashC2` 2627 B, `hashC3` 3907 B, **`hashC4` 5187 B**, `hashC5` 6467 B,
   `hashC6` 7747 B, `hashC8` **10308 B**. The 8-lane version is never JIT-compiled unless you pass
   `-XX:-DontCompileHugeMethods`, and with the flag it only reaches 23.1 ms/hash, no better than 4 lanes. 5-6 lanes
   gave 22.9-24.6 ms/hash, also no gain. **Use 4 lanes.** Keep the 1-, 2- and 3-lane methods for partial batches:
   2 lanes = 25-29 ms/hash and 3 lanes = 23-27 ms/hash on the JVM.
4. **The order of operations matters for the JIT.** Write `r xor P[i] xor F(l)`. Kotlin evaluates left to right, so
   `r ^ P` is computed while the loads are in flight. C2 does not reliably reassociate. Use `Int` with `ushr`/`and`;
   `+` wraps. Avoid `UInt` (boxing risk) and `Long` in the hot loop. Use `while` loops in generated code, and keep the
   block halves in locals, not in an `IntArray(2)`.
5. **Warm-up.** Each `hashCn` runs only a few times per second in production. HotSpot needs about 600 invocations
   (`Tier4MinInvocationThreshold`) before a standard C2 compile, so the hot loop first runs in **OSR-compiled** code.
   That measured just as fast here (22.9 ms/hash for 4 lanes after only ~19 calls). One run showed a 1-lane
   OSR/tier-3 glitch at ~100 ms per hash, so warm up at startup anyway: run the self-test vectors (cost 4/5) for every
   lane count, then ~300 calls per lane count at internal cost 0, which took ~1.4 s of one core here. Do this before
   the listener answers the `/api/tags` health check, which has a 60 s budget.
6. **Allocation per batch is fine.** 4 x 4 KB state + small arrays at ~7 batches/s is negligible garbage, and it is
   what gives C2 the array length. Do not keep thread-local reusable states for the hot loop; that loses the length
   information.
7. **Constants:** a 1024-entry `intArrayOf(...)` costs ~7 KB of `<clinit>` bytecode (fine). Alternatively parse a
   hex string at class init, as the prototype does: `IntArray(1024) { h.substring(it*8, it*8+8).toLong(16).toInt() }`.
8. **Threads:** use 2 plain platform threads (`Thread(..., "bcrypt-0").apply { isDaemon = true }`), not a coroutine
   dispatcher. Resume the request's continuation on its event loop through the loop's MPSC queue plus a wake-up
   (eventfd write or `Selector.wakeup()`). Use `ReentrantLock` + `Condition.awaitNanos` for the gather wait.
9. **Priority on the JVM:** Java thread priorities do nothing on Linux for non-root processes
   (`ThreadPriorityPolicy=1` needs root, and we run as `challenge`). To nice the bcrypt threads, call `setpriority(0,
   gettid(), nice)` through the JDK's FFM API (`java.lang.foreign.Linker.nativeLinker().downcallHandle`, final since
   JDK 22, no third-party code) from inside each bcrypt thread. `gettid` exists in glibc >= 2.30; otherwise use
   `syscall(186)` on x86-64. C# does exactly this through P/Invoke (`CpuWork.cs:27-36`).
10. **Salt RNG:** `java.security.SecureRandom()` (NativePRNG on Linux reads `/dev/urandom`) or read 16 bytes from
    `/dev/urandom` directly. That is 0.56 hashes/s, so cost does not matter.
11. **Password bytes:** `password.encodeToByteArray()` (UTF-8). Register or update with more than 72 bytes gives 422
    (conformance). Login with more than 72 bytes gives 401 without hashing.
12. **Verify:** parse the stored hash once from the row (cost, 16-byte salt, 23 expected bytes) and compare in constant
    time (`var d = 0; for (i in 0 until 23) d = d or (x[i] xor y[i]); d == 0`).

---------------------------------------------------------------------------------------------------------------------

## 6. Kotlin/Native

* **Use the same `IntArray` code as on the JVM.** The generated variant C source (`hashC1..4`, one `IntArray(1042)` per
  lane allocated inside the hashing function) compiles unchanged with `kotlinc-native -opt` and is the fastest
  version measured anywhere in this study. Thread CPU time per hash (`scratchpad/bc/kt/native/bcn.kexe C`, two runs):

  | lanes | 1 | 2 | 3 | 4 |
  |---|---|---|---|---|
  | ms CPU per hash | 55.2-55.3 | 30.0-30.1 | 21.8 | **18.5-20.7** |
  | ms per batch | 55 | 60 | 65 | 74-83 |

  On Native, single-lane is ~10% slower than the JVM but 4 lanes scale better (2.7-3.0x against 1 lane). I did not
  check whether LLVM removed the bounds checks.
* **Do not use `CPointer<IntVar>` for the hot state.** I expected `nativeHeap.allocArray<IntVar>(W * n)` plus
  `ptr[idx]` to be check-free and fast. It measured **94.7 ms (1 lane) to 102-118 ms/hash (2-4 lanes)**, 2-5x slower
  (`hashN1..4` in the same file). Each `ptr[i]` goes through `(ptr + i)!!.pointed.value`; my guess is that this is not
  fully lowered to a plain load. Keep cinterop for syscalls only.
* There is no compiler flag to switch off bounds checks: `kotlinc-native -X` lists none in 2.4.21.
* Build with `-opt`. The prototype needs `-e bc.main` because `main` is in a package.
* `setpriority` and `syscall(SYS_gettid)` are available directly from `platform.posix` / `platform.linux`.
  `/dev/urandom` can be read through `platform.posix.open/read`. For threads use pthreads (`platform.posix`) or
  `kotlin.native.concurrent.Worker`. Hand the result back to the event loop with an eventfd write, as tigokraft does
  (`server.c:65-73`).
* Kotlin/Native has no JIT, so it needs no warm-up and has no huge-method limit. 5+ lanes are possible but untested.
  On the JVM, 4 lanes was already flat.

---------------------------------------------------------------------------------------------------------------------

## 7. Aside: the fd / port limits the user flagged

Not bcrypt, but seen while reading:

* On the scoring box the service gets **`LimitNOFILE=200000`** (`SPEC.md:25-26`, `box/challenge.service:19`). The box
  setup also raises the system defaults (`box/setup-box.sh:71-72`: `DefaultLimitNOFILE=200000:1048576`, and
  limits.d `nofile 200000/1048576`). A local test shell may still have a soft limit of 1024 or ~64k, so raise it in
  `start.sh` (`ulimit -n 200000 2>/dev/null || true`), or have the JVM do it (HotSpot raises the soft limit to the
  hard limit by default with `-XX:+MaxFDLimit`; Kotlin/Native must call `setrlimit(RLIMIT_NOFILE)` itself).
* Load generators: "`ip_local_port_range 1024 65535` matters, since each user holds one connection to the same
  target ip:port" (`bench/README.md:73-75`). One loadgen source IP to one ip:port tops out at ~64k connections, so
  local tests above ~64k users need several target addresses or source IPs. goose's GCP runs aimed every loadgen
  process at its own target address for that reason (`goose-epoll-xeonfx/README.md:67-68`).
