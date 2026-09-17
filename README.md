# Alumna Redis

[![Crystal CI](https://github.com/alumna/redis/actions/workflows/ci.yml/badge.svg)](https://github.com/alumna/redis/actions/workflows/ci.yml) ![Dynamic YAML Badge](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Falumna%2Fredis%2Frefs%2Fheads%2Fmaster%2Fshard.yml&query=version&prefix=v&label=version) ![GitHub License](https://img.shields.io/github/license/alumna/redis)

Redis stores for the [Alumna Backend Framework](https://github.com/alumna/backend).

`Alumna::Redis` holds one Redis client for the process:

- `redis.cache` — `Alumna::RedisCache` (`Alumna::Cache`)
- `redis.session_store` — `Alumna::RedisSessionStore` (`Alumna::SessionStore`)
- `redis.rate_limit_store` — `Alumna::RedisRateLimitStore` (`Alumna::RateLimitStore`)

See [ROADMAP.md](ROADMAP.md).

---

## Table of Contents
1. [Installation](#1-installation)
2. [Connect](#2-connect)
3. [Key prefixes](#3-key-prefixes)
4. [Cache](#4-cache)
5. [Service cache](#5-service-cache)
6. [Session](#6-session)
7. [Rate limit](#7-rate-limit)
8. [Errors](#8-errors)
9. [Security](#9-security)
10. [Testing](#10-testing)
11. [License](#11-license)

---

## 1. Installation

Add it to your `shard.yml`:

```yaml
dependencies:
  alumna:
    github: alumna/backend
    version: ~> 0.8.0
  alumna-redis:
    github: alumna/redis
```

Then run `shards install`.

Needs Alumna Backend **0.8** or later (`Cache`, `SessionStore`, and `RateLimitStore`). Default is a single Redis server on port **6379**. Pass `cluster: true` to use Redis Cluster (any node URI). Sentinel is not supported.

For a local unpublished backend clone, use gitignored `shard.override.yml`:

```yaml
dependencies:
  alumna:
    path: ../backend
```

---

## 2. Connect

```crystal
require "alumna-redis"

redis = Alumna::Redis.new(URI.parse(ENV["REDIS_URL"]))
redis.ping # => "PONG"
```

`Alumna::Redis.new` accepts a `URI` or a `String`. Default topology is single-node `Redis::Client`. Logical database comes from the URI path (`/0`).

Redis Cluster is explicit. Pass `cluster: true`. The URI may be **any** node. The driver discovers the rest. Cluster uses db **0**. A URI path `/N` does not select a logical database on Cluster.

```crystal
redis = Alumna::Redis.new(URI.parse(ENV["REDIS_CLUSTER_URL"]), cluster: true)
```

| Scheme | Transport |
|---|---|
| `redis://` | TCP |
| `rediss://` | TLS |

User and password in the URI are Redis AUTH. There is no Unix socket. Sentinel is not supported. Redis Cluster in this driver has no `MULTI`. The cache, session, and rate-limit ports do not use `MULTI`.

From the environment (default `REDIS_URL`):

```crystal
redis = Alumna::Redis.from_env
# or:
redis = Alumna::Redis.from_env("REDIS_URL")
# Cluster:
# redis = Alumna::Redis.from_env("REDIS_CLUSTER_URL", cluster: true)
```

Close the client when the process stops:

```crystal
redis.close
```

Use one `Alumna::Redis` per process. Do not open a client per request.

---

## 3. Key prefixes

Redis is often shared. Every port adds a prefix:

| Port | Default prefix |
|---|---|
| Cache | `alumna:cache:` |
| Session | `alumna:sid:` |
| Rate limit | `alumna:rl:` |

You can set a global prefix and override a port prefix:

```crystal
redis = Alumna::Redis.new(
  "redis://127.0.0.1:6379/0",
  prefix: "shop:",
  cache_prefix: "alumna:cache:",
)
```

A cache key `posts:1` then becomes `shop:alumna:cache:posts:1`.

Service cache keys from `Alumna.cache` get a hash-tag around the service path. Then get, find, and collection generation hash to one Cluster slot:

| Logical `Cache` key | Redis key |
|---|---|
| `alumna:get:/posts:12` | `…alumna:cache:{/posts}:get:12` |
| `alumna:fgen:/posts` | `…alumna:cache:{/posts}:fgen` |
| `alumna:find:{gen}:/posts:{hash}` | `…alumna:cache:{/posts}:find:{gen}:{hash}` |

This changes keys already stored in Redis under the untagged shape. Session and rate-limit keys stay one key with no hash-tag.

---

## 4. Cache

`redis.cache` is an `Alumna::Cache`. Values are `Bytes`. TTL uses Redis `SET` `PX` (milliseconds). `ttl` nil means no expiry. `ttl` must be greater than 0.

```crystal
cache = redis.cache
cache.set("k", "hello".to_slice, 30.seconds)
cache.get("k") # => Bytes of "hello"
cache.set_nx("k", "nope".to_slice) # => false
cache.delete("k")
cache.incr("gen") # => 1
```

`get` copies the byte slice. Mutation of a returned slice does not change Redis.

`incr` is Redis `INCR`. A missing key becomes 1. A non-integer value raises `Alumna::Redis::Error`. Collection generation keys from `Alumna.cache` have no TTL. Do not pass a TTL on `incr`.

---

## 5. Service cache

Pass `redis.cache` to the backend rule. Attach `before` on `:read` and `after` on all methods except `options`.

```crystal
require "alumna"
require "alumna-redis"

redis = Alumna::Redis.new(URI.parse(ENV["REDIS_URL"]))
rule = Alumna.cache(redis.cache, ttl: 30.seconds)

app.use "/posts", Alumna.memory(PostSchema) {
  before rule, on: :read
  after rule
}
```

Two processes that share this Redis share **get** results (write-through on create/update/patch). **Find** cache is the list that one process loaded. Share find across processes only when those processes also share the document store.

---

## 6. Session

`redis.session_store` is an `Alumna::SessionStore`. Data is JSON via `Alumna::JsonHelper`. TTL uses Redis `SET` `PX`. TTL is absolute from `set`. `get` does not extend it. `get` returns a shallow copy of the top-level hash.

```crystal
store = redis.session_store(ttl: 24.hours)
sessions = Alumna::Session.new(store, secure: true)
app.before sessions.rule

# In login:
sessions.start(ctx, Alumna.hash(user_id: id))
```

Two processes that share this Redis share the session. Login on instance A. A request on instance B with the same cookie is authenticated.

JSON encode does not keep `Time` as `Time` or `Bytes` as `Bytes` on read. Typical session fields are strings and integers.

---

## 7. Rate limit

`redis.rate_limit_store` is an `Alumna::RateLimitStore`. One Redis key per limiter key. Lua `INCR` + `PEXPIRE` on the first hit in a window. `reset_at` comes from `PTTL`.

The window lives on the store. `Alumna.rate_limit(window_seconds:)` sets the memory store only when `store:` is omitted.

```crystal
store = redis.rate_limit_store(60.seconds)
app.before Alumna.rate_limit(limit: 100, store: store)
```

Two processes that share this Redis share the counters. One Redis key per limiter key, so the Lua script stays on one Cluster slot.

---

## 8. Errors

Connection and driver errors raise `Alumna::Redis::Error`. The message never includes URI userinfo (user and password).

---

## 9. Security

- Do not log the Redis URI. It may contain a password.
- `Alumna::Redis::Error` strips `//user:pass@` from messages.
- Put the URI in `REDIS_URL` or `REDIS_CLUSTER_URL`. Do not commit a password.
- Use `rediss://` when the link is not trusted.
- Use one client per process.

---

## 10. Testing

Specs need Redis. Set `REDIS_URL` or use `redis://127.0.0.1:6379/0`. If Redis is down, the spec process stops with a clear message.

Cluster examples need `REDIS_CLUSTER_URL`. They are pending when that variable is unset. They fail with a clear message when it is set and Cluster is down.

Start a local Cluster on `127.0.0.1:6380`–`6385` (3 masters, 1 replica each):

```bash
bash script/dev_cluster.sh
REDIS_CLUSTER_URL=redis://127.0.0.1:6380 crystal spec
```

GitHub Actions:

- Format check
- Specs against one Redis 8.0 on port **6379**
- Specs against Redis Cluster (`REDIS_CLUSTER_URL=redis://127.0.0.1:6380`) plus standalone 6379
- kcov on `src/` (line-rate 1.000) against one Redis on port **6379** only

`preview_mt` + `execution_context` runs on the spec jobs.

---

## 11. License

MIT
