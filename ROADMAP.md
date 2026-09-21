# Alumna Redis — roadmap

Official Redis stores for Alumna Backend. Not a Service adapter. No `AdapterSuite`.

Driver: `jgaskins/redis`. Default topology: single-node `Redis::Client`. Redis Cluster: `cluster: true` (any node URI). No Sentinel. No `MULTI` on Cluster.

## Delivered - 0.1.0

* `Alumna::Redis` connection holder: `new` / `from_uri` / `from_env`, `ping`, `close`. Default `Redis::Client`. `cluster: true` opens `Redis::Cluster`.
* Key prefixes: optional global prefix plus `alumna:cache:`, `alumna:sid:`, `alumna:rl:`.
* Error helper strips URI userinfo.
* Holder operations return `T | Alumna::Redis::Error` (struct). Port methods return backend `StoreError`. Config mistakes raise `ArgumentError`.
* `Alumna::RedisCache < Alumna::Cache`. `get` / `set` / `set_nx` / `delete` / `incr`. TTL via Redis `SET` `PX`. Factory `redis.cache`.
* Service cache: `Alumna.cache(redis.cache)`. Two processes share write-through get.
* `Alumna::RedisSessionStore < Alumna::SessionStore`. JSON via `JsonHelper`. Absolute TTL. Shallow copy on get. Factory `redis.session_store`.
* `Alumna::RedisRateLimitStore < Alumna::RateLimitStore`. Lua `INCR` + `PEXPIRE`. `reset_at` from `PTTL`. One key per limiter key. Factory `redis.rate_limit_store`.
* Cache, session, and rate limit on Redis Cluster (`cluster: true`). One key per command. No `CROSSSLOT`.
* Hash-tags on Redis cache keys that share a service path (`get` / `find` / `fgen` → `{/posts}`). Session and rate limit stay one key.
* GitHub CI: Redis service, format, spec, `preview_mt`, kcov 100% on `src/` (standalone 6379). Extra job for Redis Cluster.

## Next

* Sentinel is not available in the driver.

Queue and pub/sub not worked yet.
