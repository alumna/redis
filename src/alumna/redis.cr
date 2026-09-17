require "./redis/errors"

# One Redis::Client for the process. Cache, session, and rate limit ports.
# v1 is single-node Client only. No Cluster. No Sentinel.
class Alumna::Redis
  CACHE_PREFIX      = "alumna:cache:"
  SESSION_PREFIX    = "alumna:sid:"
  RATE_LIMIT_PREFIX = "alumna:rl:"

  getter client : ::Redis::Client
  getter prefix : String
  getter cache_prefix : String
  getter session_prefix : String
  getter rate_limit_prefix : String

  def initialize(
    uri : URI | String,
    prefix : String = "",
    cache_prefix : String = CACHE_PREFIX,
    session_prefix : String = SESSION_PREFIX,
    rate_limit_prefix : String = RATE_LIMIT_PREFIX,
  )
    @prefix = prefix
    @cache_prefix = cache_prefix
    @session_prefix = session_prefix
    @rate_limit_prefix = rate_limit_prefix
    @client = begin
      parsed = uri.is_a?(String) ? URI.parse(uri) : uri
      ::Redis::Client.new(parsed)
    rescue ex
      raise Errors.wrap(ex)
    end
  end

  def self.from_uri(
    uri : URI | String,
    prefix : String = "",
    cache_prefix : String = CACHE_PREFIX,
    session_prefix : String = SESSION_PREFIX,
    rate_limit_prefix : String = RATE_LIMIT_PREFIX,
  )
    new(uri, prefix: prefix, cache_prefix: cache_prefix, session_prefix: session_prefix, rate_limit_prefix: rate_limit_prefix)
  end

  def self.from_env(
    name : String = "REDIS_URL",
    prefix : String = "",
    cache_prefix : String = CACHE_PREFIX,
    session_prefix : String = SESSION_PREFIX,
    rate_limit_prefix : String = RATE_LIMIT_PREFIX,
  )
    value = ENV[name]?
    if value.nil? || value.empty?
      raise Error.new("Missing environment variable #{name}")
    end
    new(value, prefix: prefix, cache_prefix: cache_prefix, session_prefix: session_prefix, rate_limit_prefix: rate_limit_prefix)
  end

  # PING. Returns "PONG". Raises Error with userinfo stripped on failure.
  def ping : String
    @client.ping.as?(String) || "PONG"
  rescue ex
    raise Errors.wrap(ex)
  end

  def close : Nil
    @client.close
  end

  # Full key: global prefix + port prefix + name.
  def key(port_prefix : String, name : String) : String
    String.build { |io|
      io << @prefix
      io << port_prefix
      io << name
    }
  end
end

require "./redis/cache"
require "./redis/session_store"
require "./redis/rate_limit_store"
