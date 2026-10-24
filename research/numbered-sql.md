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

