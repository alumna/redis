# Changelog

## Unreleased

### Added
* `Alumna::Redis` connection holder. `new(uri)`, `from_uri`, and `from_env`. `ping` and `close`.
* Optional global key prefix. Default port prefixes: `alumna:cache:`, `alumna:sid:`, `alumna:rl:`.
* `Alumna::Redis::Error` and `Errors.safe_message` / `Errors.wrap`. Messages never include URI userinfo.
* Single-node `Redis::Client` only. No Cluster. No Sentinel.
* `Alumna::RedisCache < Alumna::Cache`. `get` / `set` / `set_nx` / `delete` / `incr`. TTL via `SET` `PX`. Factory `Alumna::Redis#cache`.
* `Alumna::RedisSessionStore < Alumna::SessionStore`. JSON via `JsonHelper`. Absolute TTL via `SET` `PX`. Shallow copy on get. Factory `Alumna::Redis#session_store`.
* `Alumna::RedisRateLimitStore < Alumna::RateLimitStore`. Lua `INCR` + `PEXPIRE`. `reset_at` from `PTTL`. One key per limiter key. Factory `Alumna::Redis#rate_limit_store`.
* GitHub CI: Redis 8.0 service, `format --check`, `crystal spec`, `preview_mt` + `execution_context`, kcov 100% on `src/`.
