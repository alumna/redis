# Alumna Redis

[![Crystal CI](https://github.com/alumna/redis/actions/workflows/ci.yml/badge.svg)](https://github.com/alumna/redis/actions/workflows/ci.yml) ![Dynamic YAML Badge](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Falumna%2Fredis%2Frefs%2Fheads%2Fmaster%2Fshard.yml&query=version&prefix=v&label=version) ![GitHub License](https://img.shields.io/github/license/alumna/redis)

Redis stores for the [Alumna Backend Framework](https://github.com/alumna/backend).

`Alumna::Redis` holds one Redis client for the process:

- `redis.cache` — `Alumna::RedisCache` (`Alumna::Cache`)
- `redis.session_store` — `Alumna::RedisSessionStore` (`Alumna::SessionStore`)
- `redis.rate_limit_store` — `Alumna::RedisRateLimitStore` (`Alumna::RateLimitStore`)
- `redis.geo` — `Alumna::Redis::Geo` (geospatial index)

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
8. [Geo](#8-geo)
9. [Errors](#9-errors)
10. [Security](#10-security)
11. [Testing](#11-testing)
12. [License](#12-license)

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

Needs Alumna Backend with `StoreError` on `Cache`, `SessionStore`, and `RateLimitStore`. Default is a single Redis server on port **6379**. Pass `cluster: true` to use Redis Cluster (any node URI). Sentinel is not supported.

Until that backend is published, use gitignored `shard.override.yml`:

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
if redis.is_a?(Alumna::Redis::Error)
  # Handle the connect failure. The message has no URI userinfo.
else
  redis.ping # => "PONG" or Error
end
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

From the environment (default `REDIS_URL`). Missing or empty env raises `ArgumentError`:

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
| Geo | global prefix only |

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

A geo index name is application data. `redis.geo` prepends the global prefix and no other prefix.

---

## 4. Cache

`redis.cache` is an `Alumna::Cache`. Values are `Bytes`. TTL uses Redis `SET` `PX` (milliseconds). `ttl` nil means no expiry. `ttl` must be greater than 0.

```crystal
cache = redis.cache
got = cache.get("k")
if got.is_a?(Alumna::StoreError)
  # Store down. Not a miss.
elsif got
  # hit
end
cache.set("k", "hello".to_slice, 30.seconds)
cache.set_nx("k", "nope".to_slice) # => false or StoreError
cache.delete("k")
cache.incr("gen") # => 1 or StoreError
```

`get` copies the byte slice. Mutation of a returned slice does not change Redis.

`incr` is Redis `INCR`. A missing key becomes 1. A non-integer value returns `Alumna::StoreError`. Collection generation keys from `Alumna.cache` have no TTL. Do not pass a TTL on `incr`.

---

## 5. Service cache

Pass `redis.cache` to the backend rule. Attach `before` on `:read` and `after` on all methods except `options`.

```crystal
require "alumna"
require "alumna-redis"

redis = Alumna::Redis.new(URI.parse(ENV["REDIS_URL"]))
if redis.is_a?(Alumna::Redis::Error)
  # Handle the connect failure.
else
  rule = Alumna.cache(redis.cache, ttl: 30.seconds)

  app.use "/posts", Alumna.memory(PostSchema) {
    before rule, on: :read
    after rule
  }
end
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
started = sessions.start(ctx, Alumna.hash(user_id: id))
next Alumna::ServiceError.internal(started.message) if started.is_a?(Alumna::StoreError)
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

## 8. Geo

`redis.geo` is an `Alumna::Redis::Geo`. One index is one Redis key. The key is the global prefix plus the name. There is no `alumna:geo:` prefix.

Add members with `add`. Read positions with `pos`. Read the distance with `dist`. Read geohash strings with `hash`. Search with `search`. Copy a search into another key with `store`. Remove members with `remove`.

A missing member is nil. An empty search is an empty array. A driver failure returns `Alumna::Redis::Error`. These calls raise `ArgumentError`:

- `nx` and `xx` together
- `count` less than or equal to 0
- a negative radius, box width, or box height

Radius `0` and box `0` are valid. Redis checks longitude and latitude.

`dist` uses meters when you omit the unit. `Hit#distance` and the coordinates are the decimal strings Redis returns. They are not bit-exact. `Hit#hash` is the 52-bit score from `WITHHASH`. `hash` returns geohash strings. Those two values are different.

`store` on Cluster needs the same hash tag in the destination name and the source name. An empty result deletes the destination key.

```crystal
geo = redis.geo
added = geo.add("drivers",
  Alumna::Redis::Geo::Member.new("-81.68", "41.50", "driver-1"),
)
if added.is_a?(Alumna::Redis::Error)
  # Handle the failure. The message has no URI userinfo.
else
  hits = geo.search("drivers",
    fromlonlat: {"-81.68", "41.47"},
    byradius: Alumna::Redis::Geo::Radius.new(5, Alumna::Redis::Geo::Unit::MI),
    sort: Alumna::Redis::Geo::Sort::ASC,
    withdist: true,
    withcoord: true,
  )
end
```

Units are `M`, `KM`, `FT`, and `MI`. Use `search`. The old radius commands are not part of this API.

---

## 9. Errors

`Alumna::Redis::Error` is a **struct**, not an Exception. Holder `new` / `from_uri` / `from_env` / `ping` / `close` return `T | Error`. Cache, session, and rate-limit port methods return backend `Alumna::StoreError` on driver failure. The message never includes URI userinfo (user and password).

In the table, `Error` is `Alumna::Redis::Error`.

| Method | Type |
|---|---|
| `new`, `from_uri`, `from_env` | `Alumna::Redis \| Error` |
| `ping` | `String \| Error` |
| `close` | `Nil \| Error` |
| `RedisCache#get` | `Bytes? \| StoreError` |
| `RedisCache#set` / `delete` | `Nil \| StoreError` |
| `RedisCache#set_nx` | `Bool \| StoreError` |
| `RedisCache#incr` | `Int64 \| StoreError` |
| `RedisSessionStore#get` | `Hash? \| StoreError` |
| `RedisSessionStore#set` / `delete` | `Nil \| StoreError` |
| `RedisRateLimitStore#hit` | `{Int32, Time} \| StoreError` |
| `Redis::Geo#add` / `remove` / `store` | `Int64 \| Error` |
| `Redis::Geo#pos` | `Array({String, String}?) \| Error` |
| `Redis::Geo#dist` | `String? \| Error` |
| `Redis::Geo#hash` | `Array(String?) \| Error` |
| `Redis::Geo#search` | `Array(Redis::Geo::Hit) \| Error` |

`Cache#get` `nil` is a miss. `SessionStore#get` `nil` is no session. `StoreError` is store down. `Alumna.cache` / `Alumna.session` / `Alumna.rate_limit` map `StoreError` to `ServiceError.internal` (HTTP 500).

These calls raise `ArgumentError`. They do not return `Error`.

| Mistake | Methods |
|---|---|
| Empty URL | `new`, `from_uri` |
| URI that does not parse | `new`, `from_uri`, `from_env` |
| Missing or empty environment variable | `from_env` |
| `ttl <= 0` | cache `set` / `set_nx`, session `set` / boot |
| `window <= 0` | rate-limit store boot |
| `nx` and `xx` together | geo `add` |
| `count <= 0`, or `any` without `count` | geo `search` / `store` |
| negative radius or box size | geo `search` / `store` |

---

## 10. Security

- Do not log the Redis URI. It may contain a password.
- `Alumna::Redis::Error` strips `//user:pass@` from messages.
- Put the URI in `REDIS_URL` or `REDIS_CLUSTER_URL`. Do not commit a password.
- Use `rediss://` when the link is not trusted.
- Use one client per process.

---

## 11. Testing

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

## 12. License

MIT
