# Redis session store. Keys use the holder session prefix.
# Values are JSON via Alumna::JsonHelper. TTL is SET PX (milliseconds).
# TTL is absolute from set. get does not extend it. get returns a shallow copy.
class Alumna::RedisSessionStore < Alumna::SessionStore
  def initialize(@redis : Alumna::Redis, ttl : Time::Span = 24.hours)
    super(ttl)
  end

  def get(id : String) : Hash(String, Alumna::AnyData)?
    value = command { @redis.client.get(full_key(id)) }
    return nil unless value
    hash = Alumna::JsonHelper.from_string(value).as?(Hash(String, Alumna::AnyData))
    return nil unless hash
    hash.dup
  rescue JSON::ParseException
    nil
  end

  def set(id : String, data : Hash(String, Alumna::AnyData), ttl : Time::Span = default_ttl) : Nil
    px = milliseconds(ttl)
    json = Alumna::JsonHelper.to_string(data)
    full = full_key(id)
    command { @redis.client.set(full, json, px: px) }
  end

  def delete(id : String) : Nil
    command { @redis.client.del(full_key(id)) }
  end

  private def full_key(id : String) : String
    @redis.key(@redis.session_prefix, id)
  end

  # Redis PX is whole milliseconds. A positive ttl below 1 ms becomes 1 ms.
  private def milliseconds(ttl : Time::Span) : Int64
    raise ArgumentError.new("session ttl must be > 0") if ttl <= Time::Span.zero
    ttl.total_milliseconds.ceil.to_i64
  end

  private def command(&)
    yield
  rescue ex
    raise Alumna::Redis::Errors.wrap(ex)
  end
end

class Alumna::Redis
  def session_store(ttl : Time::Span = 24.hours) : Alumna::RedisSessionStore
    Alumna::RedisSessionStore.new(self, ttl)
  end
end
