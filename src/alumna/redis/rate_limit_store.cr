# Redis fixed-window rate-limit store. One key per limiter key (one Cluster slot).
# Lua INCR + PEXPIRE on first hit (or when the key has no TTL). reset_at from PTTL.
class Alumna::RedisRateLimitStore < Alumna::RateLimitStore
  # INCR, set PX if this is the first hit or the key has no TTL, return {count, pttl}.
  SCRIPT = <<-LUA
    local n = redis.call('INCR', KEYS[1])
    if n == 1 then
      redis.call('PEXPIRE', KEYS[1], ARGV[1])
      return {n, tonumber(ARGV[1])}
    end
    local ttl = redis.call('PTTL', KEYS[1])
    if ttl < 0 then
      redis.call('PEXPIRE', KEYS[1], ARGV[1])
      ttl = tonumber(ARGV[1])
    end
    return {n, ttl}
    LUA

  getter window : Time::Span
  @px : Int64

  def initialize(@redis : Alumna::Redis, @window : Time::Span = 60.seconds)
    @px = milliseconds(@window)
  end

  def hit(key : String) : Tuple(Int32, Time)
    full = full_key(key)
    px = @px
    reply = command do
      @redis.client.eval(SCRIPT, keys: [full], args: [px.to_s])
    end
    n = 1_i64
    pttl = px
    if arr = reply.as?(Array)
      if v = arr[0]?.as?(Int64)
        n = v
      end
      if v = arr[1]?.as?(Int64)
        pttl = v
      end
    end
    count = n > Int32::MAX ? Int32::MAX : n.to_i32
    reset_at = Time.utc + (pttl > 0 ? pttl.milliseconds : @window)
    {count, reset_at}
  end

  private def full_key(key : String) : String
    @redis.key(@redis.rate_limit_prefix, key)
  end

  # Redis PX is whole milliseconds. A positive window below 1 ms becomes 1 ms.
  private def milliseconds(window : Time::Span) : Int64
    raise ArgumentError.new("rate limit window must be > 0") if window <= Time::Span.zero
    window.total_milliseconds.ceil.to_i64
  end

  private def command(&)
    yield
  rescue ex
    raise Alumna::Redis::Errors.wrap(ex)
  end
end

class Alumna::Redis
  def rate_limit_store(window : Time::Span = 60.seconds) : Alumna::RedisRateLimitStore
    Alumna::RedisRateLimitStore.new(self, window)
  end
end
