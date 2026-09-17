# Alumna Redis — roadmap

Official Redis stores for Alumna Backend. Not a Service adapter. No `AdapterSuite`.

Driver: `jgaskins/redis`. Topology: single-node `Redis::Client`. No Cluster. No Sentinel.

## Delivered (Unreleased)

* `Alumna::Redis` connection holder: `new` / `from_uri` / `from_env`, `ping`, `close`.
* Key prefixes: optional global prefix plus `alumna:cache:`, `alumna:sid:`, `alumna:rl:`.
* Error helper strips URI userinfo.
* `Alumna::RedisCache < Alumna::Cache`. `get` / `set` / `set_nx` / `delete` / `incr`. TTL via Redis `SET` `PX`. Factory `redis.cache`.
* Service cache: `Alumna.cache(redis.cache)`. Two processes share write-through get.
* `Alumna::RedisSessionStore < Alumna::SessionStore`. JSON via `JsonHelper`. Absolute TTL. Shallow copy on get. Factory `redis.session_store`.
* `Alumna::RedisRateLimitStore < Alumna::RateLimitStore`. Lua `INCR` + `PEXPIRE`. `reset_at` from `PTTL`. One key per limiter key. Factory `redis.rate_limit_store`.
* GitHub CI: Redis service, format, spec, `preview_mt`, kcov 100% on `src/`.

## Next

* Redis Cluster (hash tags if a script uses more than one key).
* Sentinel is not available in the driver.

No queue. No pub/sub. NATS is the intended bus for those.
