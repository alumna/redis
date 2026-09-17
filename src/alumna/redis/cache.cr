# Redis byte cache. Keys use the holder cache prefix.
# Service get/find/fgen names that share a path get a hash-tag (one Cluster slot).
# Logical Cache keys stay alumna:get: / alumna:fgen: / alumna:find:.
# TTL is SET PX (milliseconds). ttl nil means no expiry. ttl must be > 0.
# get copies the slice. incr is Redis INCR (a missing key becomes 1).
class Alumna::RedisCache < Alumna::Cache
  def initialize(@redis : Alumna::Redis)
  end

  def get(key : String) : Bytes?
    full = full_key(key)
    command do
      value = @redis.client.get(full)
      value ? value.to_slice.dup : nil
    end
  end

  def set(key : String, value : Bytes, ttl : Time::Span? = nil) : Nil
    px = milliseconds(ttl)
    full = full_key(key)
    command do
      if px
        @redis.client.set(full, value, px: px)
      else
        @redis.client.set(full, value)
      end
    end
  end

  def set_nx(key : String, value : Bytes, ttl : Time::Span? = nil) : Bool
    px = milliseconds(ttl)
    full = full_key(key)
    command do
      reply = if px
                @redis.client.set(full, value, nx: true, px: px)
              else
                @redis.client.set(full, value, nx: true)
              end
      !reply.nil?
    end
  end

  def delete(key : String) : Nil
    full = full_key(key)
    command { @redis.client.del(full) }
  end

  def incr(key : String) : Int64
    full = full_key(key)
    command { @redis.client.incr(full) }
  end

  private def full_key(key : String) : String
    @redis.cache_redis_key(key)
  end

  # Redis PX is whole milliseconds. A positive ttl below 1 ms becomes 1 ms.
  private def milliseconds(ttl : Time::Span?) : Int64?
    return nil unless ttl
    raise ArgumentError.new("cache ttl must be > 0") if ttl <= Time::Span.zero
    ttl.total_milliseconds.ceil.to_i64
  end

  private def command(&)
    yield
  rescue ex
    raise Alumna::Redis::Errors.wrap(ex)
  end
end

class Alumna::Redis
  def cache : Alumna::RedisCache
    Alumna::RedisCache.new(self)
  end
end
