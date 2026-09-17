require "alumna"
require "redis"

class Alumna::Redis
  # Driver and connection errors. The message never includes URI userinfo.
  class Error < Exception
  end

  module Errors
    # Strip `//user:pass@` so a password in a connection error does not leave the shard.
    USERINFO = /\/\/[^\/\s]*@/

    def self.safe_message(ex : Exception) : String
      msg = ex.message
      return "Redis error" unless msg && !msg.empty?
      msg.gsub(USERINFO, "//")
    end

    def self.wrap(ex : Exception) : Error
      Error.new(safe_message(ex))
    end
  end
end
