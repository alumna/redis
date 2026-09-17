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
    holder.cluster?.should be_false
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

  it "hash-tags service cache names that share a path" do
    Alumna::Redis.tagged_cache_name("alumna:get:/posts:12").should eq("{/posts}:get:12")
    Alumna::Redis.tagged_cache_name("alumna:fgen:/posts").should eq("{/posts}:fgen")
    Alumna::Redis.tagged_cache_name("alumna:find:3:/posts:abc").should eq("{/posts}:find:3:abc")
    Alumna::Redis.tagged_cache_name("plain").should eq("plain")
    Alumna::Redis.tagged_cache_name("alumna:get:/posts").should eq("alumna:get:/posts")
    Alumna::Redis.tagged_cache_name("alumna:get::12").should eq("alumna:get::12")
    Alumna::Redis.tagged_cache_name("alumna:get:/posts:").should eq("alumna:get:/posts:")
    Alumna::Redis.tagged_cache_name("alumna:fgen:").should eq("alumna:fgen:")
    Alumna::Redis.tagged_cache_name("alumna:find:3").should eq("alumna:find:3")
    Alumna::Redis.tagged_cache_name("alumna:find::/posts:abc").should eq("alumna:find::/posts:abc")
    Alumna::Redis.tagged_cache_name("alumna:find:3:/posts").should eq("alumna:find:3:/posts")
    Alumna::Redis.tagged_cache_name("alumna:find:3:/posts:").should eq("alumna:find:3:/posts:")
    Alumna::Redis.tagged_cache_name("alumna:find:3::abc").should eq("alumna:find:3::abc")
    SHARED.cache_redis_key("alumna:get:/posts:12").should eq("#{SPEC_PREFIX}alumna:cache:{/posts}:get:12")
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

  it "raises Error without URI userinfo when Cluster is down" do
    ex = expect_raises(Alumna::Redis::Error) do
      Alumna::Redis.new(dead_url, cluster: true)
    end
    msg = ex.message || ""
    msg.includes?("secret").should be_false
    msg.includes?("user:").should be_false
  end
end

describe "Alumna::Redis cluster" do
  it "pings a live Cluster from a String URI" do
    url = require_cluster_url
    holder = Alumna::Redis.new(url, cluster: true)
    holder.ping.should eq("PONG")
    holder.client.should be_a(::Redis::Cluster)
    holder.cluster?.should be_true
    holder.close.should be_nil
  end

  it "pings a live Cluster from a URI object" do
    url = require_cluster_url
    holder = Alumna::Redis.new(URI.parse(url), cluster: true)
    holder.ping.should eq("PONG")
    holder.close
  end

  it "builds from_uri and from_env with cluster: true" do
    url = require_cluster_url
    from_obj = Alumna::Redis.from_uri(URI.parse(url), prefix: "from-uri-c:", cluster: true)
    from_obj.ping.should eq("PONG")
    from_obj.prefix.should eq("from-uri-c:")
    from_obj.cluster?.should be_true
    from_obj.close

    ENV["ALUMNA_REDIS_CLUSTER_SPEC"] = url
    begin
      holder = Alumna::Redis.from_env("ALUMNA_REDIS_CLUSTER_SPEC", prefix: "env-c:", cluster: true)
      holder.ping.should eq("PONG")
      holder.prefix.should eq("env-c:")
      holder.close
    ensure
      ENV.delete("ALUMNA_REDIS_CLUSTER_SPEC")
    end
  end
end
