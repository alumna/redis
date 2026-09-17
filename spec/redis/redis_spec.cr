require "../spec_helper"

describe Alumna::Redis do
  it "pings a live server from a String URI" do
    holder = Alumna::Redis.new(REDIS_URL)
    holder.ping.should eq("PONG")
    holder.close
  end

  it "pings a live server from a URI object" do
    holder = Alumna::Redis.new(URI.parse(REDIS_URL))
    holder.ping.should eq("PONG")
    holder.client.should be_a(::Redis::Client)
    holder.close
  end

  it "builds from_uri with a URI and with a String" do
    from_obj = Alumna::Redis.from_uri(URI.parse(REDIS_URL), prefix: "from-uri:")
    from_obj.ping.should eq("PONG")
    from_obj.prefix.should eq("from-uri:")
    from_obj.close

    from_str = Alumna::Redis.from_uri(REDIS_URL)
    from_str.ping.should eq("PONG")
    from_str.close
  end

  it "builds from_env with REDIS_URL and with a custom name" do
    old = ENV["REDIS_URL"]?
    ENV["REDIS_URL"] = REDIS_URL
    begin
      holder = Alumna::Redis.from_env
      holder.ping.should eq("PONG")
      holder.close
    ensure
      if old
        ENV["REDIS_URL"] = old
      else
        ENV.delete("REDIS_URL")
      end
    end

    ENV["ALUMNA_REDIS_SPEC"] = REDIS_URL
    begin
      holder = Alumna::Redis.from_env("ALUMNA_REDIS_SPEC", prefix: "env:")
      holder.ping.should eq("PONG")
      holder.prefix.should eq("env:")
      holder.close
    ensure
      ENV.delete("ALUMNA_REDIS_SPEC")
    end
  end

  it "raises Error when from_env is missing or empty" do
    ENV.delete("ALUMNA_REDIS_MISSING")
    expect_raises(Alumna::Redis::Error, "Missing environment variable ALUMNA_REDIS_MISSING") do
      Alumna::Redis.from_env("ALUMNA_REDIS_MISSING")
    end

    ENV["ALUMNA_REDIS_EMPTY"] = ""
    begin
      expect_raises(Alumna::Redis::Error, "Missing environment variable ALUMNA_REDIS_EMPTY") do
        Alumna::Redis.from_env("ALUMNA_REDIS_EMPTY")
      end
    ensure
      ENV.delete("ALUMNA_REDIS_EMPTY")
    end
  end

  it "uses default port prefixes and joins a global prefix" do
    SHARED.cache_prefix.should eq(Alumna::Redis::CACHE_PREFIX)
    SHARED.session_prefix.should eq(Alumna::Redis::SESSION_PREFIX)
    SHARED.rate_limit_prefix.should eq(Alumna::Redis::RATE_LIMIT_PREFIX)
    SHARED.key(SHARED.cache_prefix, "posts:1").should eq("#{SPEC_PREFIX}alumna:cache:posts:1")

    holder = Alumna::Redis.new(
      REDIS_URL,
      prefix: "shop:",
      cache_prefix: "c:",
      session_prefix: "s:",
      rate_limit_prefix: "r:",
    )
    holder.key(holder.cache_prefix, "k").should eq("shop:c:k")
    holder.key(holder.session_prefix, "k").should eq("shop:s:k")
    holder.key(holder.rate_limit_prefix, "k").should eq("shop:r:k")
    holder.close
  end

  it "raises Error without URI userinfo when the server is down" do
    ex = expect_raises(Alumna::Redis::Error) do
      Alumna::Redis.new(dead_url)
    end
    msg = ex.message || ""
    msg.includes?("secret").should be_false
    msg.includes?("user:").should be_false
    msg.includes?("Connection refused").should be_true
  end

  it "raises Error on ping when the pool did not connect at new" do
    holder = Alumna::Redis.new(dead_url(lazy: true))
    ex = expect_raises(Alumna::Redis::Error) do
      holder.ping
    end
    (ex.message || "").includes?("secret").should be_false
    holder.close
  end

  it "closes the client" do
    holder = Alumna::Redis.new(REDIS_URL)
    holder.close.should be_nil
  end
end
