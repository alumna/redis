require "./redis/errors"
require "redis/cluster"

# One Redis client for the process. Cache, session, and rate limit ports.
# Default is single-node Redis::Client. Pass cluster: true for Redis::Cluster.
# Cluster URI may be any node; the driver discovers the rest. Cluster uses db 0.
# No Sentinel.
class Alumna::Redis
  CACHE_PREFIX      = "alumna:cache:"
  SESSION_PREFIX    = "alumna:sid:"
  RATE_LIMIT_PREFIX = "alumna:rl:"

  # Logical Cache keys from Alumna.cache. Do not change the backend rule.
  GET_LOGICAL  = "alumna:get:"
  FGEN_LOGICAL = "alumna:fgen:"
  FIND_LOGICAL = "alumna:find:"

  getter client : ::Redis::Client | ::Redis::Cluster
  getter prefix : String
  getter cache_prefix : String
  getter session_prefix : String
  getter rate_limit_prefix : String
  getter? cluster : Bool

  # Open a client. Returns Error when the driver fails.
  # Empty URL and a URI that does not parse raise ArgumentError.
  def self.new(
    uri : URI | String,
    prefix : String = "",
    cache_prefix : String = CACHE_PREFIX,
    session_prefix : String = SESSION_PREFIX,
    rate_limit_prefix : String = RATE_LIMIT_PREFIX,
    cluster : Bool = false,
  ) : self | Error
    raise ArgumentError.new("Redis URL must not be empty") if uri.is_a?(String) && uri.empty?

    parsed = begin
      uri.is_a?(String) ? URI.parse(uri) : uri
    rescue ex : URI::Error
      raise ArgumentError.new(Errors.safe_message(ex))
    end

    client = if cluster
               ::Redis::Cluster.new(parsed)
             else
               ::Redis::Client.new(parsed)
             end
    holder = allocate
    holder.initialize(client, prefix, cache_prefix, session_prefix, rate_limit_prefix, cluster)
    holder
  rescue ex : ArgumentError
    raise ex
  rescue ex
    Errors.wrap(ex)
  end

  def self.from_uri(
    uri : URI | String,
    prefix : String = "",
    cache_prefix : String = CACHE_PREFIX,
    session_prefix : String = SESSION_PREFIX,
    rate_limit_prefix : String = RATE_LIMIT_PREFIX,
    cluster : Bool = false,
  ) : self | Error
    new(uri, prefix: prefix, cache_prefix: cache_prefix, session_prefix: session_prefix, rate_limit_prefix: rate_limit_prefix, cluster: cluster)
  end

  def self.from_env(
    name : String = "REDIS_URL",
    prefix : String = "",
    cache_prefix : String = CACHE_PREFIX,
    session_prefix : String = SESSION_PREFIX,
    rate_limit_prefix : String = RATE_LIMIT_PREFIX,
    cluster : Bool = false,
  ) : self | Error
    value = ENV[name]?
    if value.nil? || value.empty?
      raise ArgumentError.new("Missing environment variable #{name}")
    end
    new(value, prefix: prefix, cache_prefix: cache_prefix, session_prefix: session_prefix, rate_limit_prefix: rate_limit_prefix, cluster: cluster)
  end

  protected def initialize(
    @client : ::Redis::Client | ::Redis::Cluster,
    @prefix : String,
    @cache_prefix : String,
    @session_prefix : String,
    @rate_limit_prefix : String,
    @cluster : Bool,
  )
  end

  # PING. Returns "PONG" or Error. Cluster run() needs a key, so we send PING
  # with a dummy argument (valid on Client and Cluster). The message never
  # includes URI userinfo.
  def ping : String | Error
    run { @client.ping("PONG").as?(String) || "PONG" }
  end

  def close : Nil | Error
    run { close_client }
  end

  # Full key: global prefix + port prefix + name.
  def key(port_prefix : String, name : String) : String
    String.build { |io|
      io << @prefix
      io << port_prefix
      io << name
    }
  end

  # Redis cache key for a logical Cache name. Service get/find/fgen keys that
  # share a path get a hash-tag so they hash to one Cluster slot.
  def cache_redis_key(logical : String) : String
    key(@cache_prefix, self.class.tagged_cache_name(logical))
  end

  # Map logical Cache keys to Redis names. Other keys are unchanged.
  # alumna:get:/posts:12          → {/posts}:get:12
  # alumna:fgen:/posts            → {/posts}:fgen
  # alumna:find:{gen}:/posts:{fp} → {/posts}:find:{gen}:{fp}
  def self.tagged_cache_name(key : String) : String
    if key.starts_with?(GET_LOGICAL)
      rest = key[GET_LOGICAL.size..]
      colon = rest.rindex(':')
      return key unless colon
      return key if colon == 0 || colon >= rest.size - 1
      path = rest[0, colon]
      id = rest[colon + 1..]
      String.build { |io|
        io << '{' << path << "}:get:" << id
      }
    elsif key.starts_with?(FGEN_LOGICAL)
      path = key[FGEN_LOGICAL.size..]
      return key if path.empty?
      String.build { |io|
        io << '{' << path << "}:fgen"
      }
    elsif key.starts_with?(FIND_LOGICAL)
      rest = key[FIND_LOGICAL.size..]
      first = rest.index(':')
      return key unless first
      return key if first == 0
      gen = rest[0, first]
      tail = rest[first + 1..]
      last = tail.rindex(':')
      return key unless last
      return key if last == 0 || last >= tail.size - 1
      path = tail[0, last]
      fingerprint = tail[last + 1..]
      String.build { |io|
        io << '{' << path << "}:find:" << gen << ':' << fingerprint
      }
    else
      key
    end
  end

  private def close_client : Nil
    @client.close
  end

  # Programmer mistakes (`ArgumentError`) leave the method. Driver failures become `Error`.
  private def run(& : -> T) : T | Error forall T
    yield
  rescue ex : ArgumentError
    raise ex
  rescue ex
    Errors.wrap(ex)
  end
end

require "./redis/cache"
require "./redis/session_store"
require "./redis/rate_limit_store"
