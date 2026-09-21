require "spec"
require "uuid"
require "../src/alumna-redis"

# Specs need a Redis server. REDIS_URL or local 6379 database 0.
REDIS_URL = ENV["REDIS_URL"]? || "redis://127.0.0.1:6379/0"

# Cluster examples only. Unset: skip those examples. Do not abort single-node specs.
REDIS_CLUSTER_URL = ENV["REDIS_CLUSTER_URL"]?

# Unique global prefix for this process so leftover keys do not collide.
SPEC_PREFIX = "alumna-spec:#{UUID.random}:"

DEAD_HOST = "127.0.0.1"
DEAD_PORT = 63790

def display_redis_url(url : String) : String
  uri = URI.parse(url)
  uri.user = nil
  uri.password = nil
  uri.to_s
rescue
  url.gsub(/\/\/[^\/\s]*@/, "//")
end

def connect_redis(uri : URI | String = REDIS_URL, **opts) : Alumna::Redis
  result = Alumna::Redis.new(uri, **opts)
  if result.is_a?(Alumna::Redis::Error)
    abort "Redis connect failed at #{display_redis_url(uri.to_s)}. #{result.message}"
  end
  result
end

def must_redis(result : Alumna::Redis | Alumna::Redis::Error) : Alumna::Redis
  if result.is_a?(Alumna::Redis::Error)
    fail result.message
  end
  result
end

def must_ok(result : T | Alumna::StoreError) : T forall T
  if result.is_a?(Alumna::StoreError)
    fail result.message
  end
  result
end

def probe_redis : Nil
  holder = Alumna::Redis.new(REDIS_URL)
  if holder.is_a?(Alumna::Redis::Error)
    abort "Redis is not available at #{display_redis_url(REDIS_URL)}. Set REDIS_URL or start Redis on port 6379. #{holder.message}"
  end
  ping = holder.ping
  if ping.is_a?(Alumna::Redis::Error)
    abort "Redis is not available at #{display_redis_url(REDIS_URL)}. Set REDIS_URL or start Redis on port 6379. #{ping.message}"
  end
  holder.close
rescue ex
  safe = Alumna::Redis::Errors.safe_message(ex)
  abort "Redis is not available at #{display_redis_url(REDIS_URL)}. Set REDIS_URL or start Redis on port 6379. #{safe}"
end

probe_redis

SHARED = connect_redis(REDIS_URL, prefix: SPEC_PREFIX)

def dead_url(*, lazy : Bool = false) : String
  params = lazy ? "initial_pool_size=0&connect_timeout=0.2" : "connect_timeout=0.2"
  "redis://user:secret@#{DEAD_HOST}:#{DEAD_PORT}/?#{params}"
end

# Live Cluster URI, or pending when REDIS_CLUSTER_URL is unset.
# Fails this example with a clear message when the variable is set and Cluster is down.
def require_cluster_url : String
  url = REDIS_CLUSTER_URL
  if url.nil? || url.empty?
    pending! "set REDIS_CLUSTER_URL to run Cluster examples"
  end
  holder = Alumna::Redis.new(url, cluster: true)
  if holder.is_a?(Alumna::Redis::Error)
    fail "Redis Cluster is not available at #{display_redis_url(url)}. Set REDIS_CLUSTER_URL to a live Cluster node. #{holder.message}"
  end
  ping = holder.ping
  if ping.is_a?(Alumna::Redis::Error)
    fail "Redis Cluster is not available at #{display_redis_url(url)}. Set REDIS_CLUSTER_URL to a live Cluster node. #{ping.message}"
  end
  holder.close
  url
end

# Unique prefix so Cluster examples do not collide with each other or with Client specs.
def new_cluster_holder : Alumna::Redis
  connect_redis(require_cluster_url, prefix: "#{SPEC_PREFIX}c:#{UUID.random}:", cluster: true)
end
