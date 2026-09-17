require "spec"
require "uuid"
require "../src/alumna-redis"

# Specs need a Redis server. REDIS_URL or local 6379 database 0.
REDIS_URL = ENV["REDIS_URL"]? || "redis://127.0.0.1:6379/0"

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

def probe_redis : Nil
  holder = Alumna::Redis.new(REDIS_URL)
  holder.ping
  holder.close
rescue ex
  safe = Alumna::Redis::Errors.safe_message(ex)
  abort "Redis is not available at #{display_redis_url(REDIS_URL)}. Set REDIS_URL or start Redis on port 6379. #{safe}"
end

probe_redis

SHARED = Alumna::Redis.new(REDIS_URL, prefix: SPEC_PREFIX)

def dead_url(*, lazy : Bool = false) : String
  params = lazy ? "initial_pool_size=0&connect_timeout=0.2" : "connect_timeout=0.2"
  "redis://user:secret@#{DEAD_HOST}:#{DEAD_PORT}/?#{params}"
end
