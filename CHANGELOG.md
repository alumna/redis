# Changelog

## 0.1.0 - 2026-09-17

### Added
* Requires Alumna Backend `~> 0.8.0`.
* `Alumna::Redis` connection holder. `new(uri)`, `from_uri`, and `from_env`. `ping` and `close`.
* Optional global key prefix. Default port prefixes: `alumna:cache:`, `alumna:sid:`, `alumna:rl:`.
* `Alumna::Redis::Error` and `Errors.safe_message` / `Errors.wrap`. Messages never include URI userinfo.
* Default topology is single-node `Redis::Client`. Pass `cluster: true` to open `Redis::Cluster` (any node URI; the driver discovers the rest). Cluster uses db 0. No Sentinel.
* Cache, session, and rate limit run on Redis Cluster. Each command uses one key (rate-limit Lua uses `KEYS[1]`).
* Redis cache keys for service get / find / fgen include a path hash-tag (`{/posts}`). Logical `Cache` keys are unchanged. This changes keys already stored in Redis. Session and rate-limit keys are unchanged.
* `Alumna::RedisCache < Alumna::Cache`. `get` / `set` / `set_nx` / `delete` / `incr`. TTL via `SET` `PX`. Factory `Alumna::Redis#cache`.
* `Alumna::RedisSessionStore < Alumna::SessionStore`. JSON via `JsonHelper`. Absolute TTL via `SET` `PX`. Shallow copy on get. Factory `Alumna::Redis#session_store`.
* `Alumna::RedisRateLimitStore < Alumna::RateLimitStore`. Lua `INCR` + `PEXPIRE`. `reset_at` from `PTTL`. One key per limiter key. Factory `Alumna::Redis#rate_limit_store`.
* GitHub CI: Redis 8.0 service, `format --check`, `crystal spec`, `preview_mt` + `execution_context`, kcov 100% on `src/` (standalone 6379). Extra job for Redis Cluster.
