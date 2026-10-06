require "./redis/errors"
require "redis/cluster"

# One Redis client for the process. Cache, session, rate limit, and geo.
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
    # Heads are prefix + port prefix, built once per process.
    @cache_head = @prefix + @cache_prefix
    @session_head = @prefix + @session_prefix
    @rate_limit_head = @prefix + @rate_limit_prefix
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
  # Both prefixes empty returns `name` with no copy.
  def key(port_prefix : String, name : String) : String
    concat3(@prefix, port_prefix, name)
  end

  def session_key(name : String) : String
    concat_head(@session_head, name)
  end

  def rate_limit_key(name : String) : String
    concat_head(@rate_limit_head, name)
  end

  # Redis cache key for a logical Cache name. Service get/find/fgen keys that
  # share a path get a hash-tag so they hash to one Cluster slot.
  # The head and the tagged name are written in one string.
  def cache_redis_key(logical : String) : String
    head = @cache_head
    if head.empty?
      self.class.tagged_cache_name(logical)
    elsif self.class.service_cache_key?(logical)
      String.build(head.bytesize + logical.bytesize + 8) do |io|
        io << head
        io << logical unless self.class.write_tagged(io, logical)
      end
    else
      concat_head(head, logical)
    end
  end

  # Map logical Cache keys to Redis names. Other keys are unchanged.
  # alumna:get:/posts:12          → {/posts}:get:12
  # alumna:fgen:/posts            → {/posts}:fgen
  # alumna:find:{gen}:/posts:{fp} → {/posts}:find:{gen}:{fp}
  # Unchanged names are the same string (no copy).
  def self.tagged_cache_name(key : String) : String
    unless service_cache_key?(key)
      return key
    end
    written = false
    built = String.build(key.bytesize + 8) do |io|
      written = write_tagged(io, key)
    end
    written ? built : key
  end

  # :nodoc:
  def self.service_cache_key?(key : String) : Bool
    key.starts_with?(GET_LOGICAL) || key.starts_with?(FGEN_LOGICAL) || key.starts_with?(FIND_LOGICAL)
  end

  # Writes the tagged name. Returns false when the name stays as given.
  # :nodoc:
  def self.write_tagged(io : IO, key : String) : Bool
    if key.starts_with?(GET_LOGICAL)
      write_get(io, key)
    elsif key.starts_with?(FGEN_LOGICAL)
      write_fgen(io, key)
    else
      write_find(io, key)
    end
  end

  private def self.write_get(io : IO, key : String) : Bool
    start = GET_LOGICAL.size
    colon = key.rindex(':')
    return false unless colon
    rel = colon - start
    rest = key.size - start
    return false if rel <= 0 || rel >= rest - 1
    io << '{'
    write_chars(io, key, start, rel)
    io << "}:get:"
    write_chars(io, key, colon + 1, key.size - colon - 1)
    true
  end

  private def self.write_fgen(io : IO, key : String) : Bool
    start = FGEN_LOGICAL.size
    return false if start >= key.size
    io << '{'
    write_chars(io, key, start, key.size - start)
    io << "}:fgen"
    true
  end

  private def self.write_find(io : IO, key : String) : Bool
    start = FIND_LOGICAL.size
    first = key.index(':', start)
    return false unless first
    return false if first == start
    last = key.rindex(':')
    return false if !last || last <= first + 1 || last >= key.size - 1
    io << '{'
    write_chars(io, key, first + 1, last - first - 1)
    io << "}:find:"
    write_chars(io, key, start, first - start)
    io << ':'
    write_chars(io, key, last + 1, key.size - last - 1)
    true
  end

  # Char indexes. The byte copy does not allocate a substring.
  private def self.write_chars(io : IO, str : String, start : Int, count : Int) : Nil
    b0 = str.char_index_to_byte_index(start)
    b1 = str.char_index_to_byte_index(start + count)
    if b0 && b1
      io.write(str.to_slice[b0, b1 - b0])
    end
  end

  private def concat_head(head : String, name : String) : String
    return name if head.empty?
    String.build(head.bytesize + name.bytesize) do |io|
      io << head
      io << name
    end
  end

  private def concat3(prefix : String, port_prefix : String, name : String) : String
    if prefix.empty? && port_prefix.empty?
      name
    else
      String.build(prefix.bytesize + port_prefix.bytesize + name.bytesize) do |io|
        io << prefix
        io << port_prefix
        io << name
      end
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
require "./redis/geo"
