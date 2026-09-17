require "../spec_helper"
require "alumna/testing"

private def uniq : String
  UUID.random.to_s
end

describe Alumna::RedisRateLimitStore do
  it "is a RateLimitStore from Alumna::Redis#rate_limit_store" do
    store = SHARED.rate_limit_store
    store.should be_a(Alumna::RateLimitStore)
    store.should be_a(Alumna::RedisRateLimitStore)
    store.window.should eq(60.seconds)
  end

  it "increments the same key and keeps one reset_at" do
    store = SHARED.rate_limit_store(1.hour)
    key = uniq
    c1, t1 = store.hit(key)
    c2, t2 = store.hit(key)
    c1.should eq(1)
    c2.should eq(2)
    t1.to_unix.should eq(t2.to_unix)
    t1.should be > Time.utc
  end

  it "isolates counts per key" do
    store = SHARED.rate_limit_store(1.hour)
    a = uniq
    b = uniq
    store.hit(a)[0].should eq(1)
    store.hit(b)[0].should eq(1)
    store.hit(a)[0].should eq(2)
  end

  it "starts a new window after expiry" do
    store = SHARED.rate_limit_store(50.milliseconds)
    key = uniq
    store.hit(key)[0].should eq(1)
    store.hit(key)[0].should eq(2)
    sleep 80.milliseconds
    store.hit(key)[0].should eq(1)
  end

  it "sets PEXPIRE when the key has a count but no TTL" do
    store = SHARED.rate_limit_store(1.hour)
    key = uniq
    SHARED.client.set(SHARED.key(SHARED.rate_limit_prefix, key), "4")
    count, reset_at = store.hit(key)
    count.should eq(5)
    reset_at.should be > Time.utc
  end

  it "rejects a non-positive window" do
    expect_raises(ArgumentError, "rate limit window must be > 0") do
      Alumna::RedisRateLimitStore.new(SHARED, Time::Span.zero)
    end
    expect_raises(ArgumentError, "rate limit window must be > 0") do
      Alumna::RedisRateLimitStore.new(SHARED, -1.seconds)
    end
  end

  it "uses the rate-limit prefix so two holders do not collide" do
    a = Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:")
    b = Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:")
    begin
      key = "same"
      a.rate_limit_store(1.hour).hit(key)[0].should eq(1)
      b.rate_limit_store(1.hour).hit(key)[0].should eq(1)
      a.rate_limit_store(1.hour).hit(key)[0].should eq(2)
    ensure
      a.close
      b.close
    end
  end

  it "wraps a driver error without URI userinfo" do
    holder = Alumna::Redis.new(dead_url(lazy: true))
    begin
      ex = expect_raises(Alumna::Redis::Error) do
        holder.rate_limit_store.hit("x")
      end
      (ex.message || "").includes?("secret").should be_false
    ensure
      holder.close
    end
  end
end

describe "Alumna.rate_limit(store: redis.rate_limit_store)" do
  it "counts across two rules that share the store" do
    store = SHARED.rate_limit_store(1.hour)
    rule_a = Alumna.rate_limit(limit: 1, store: store)
    rule_b = Alumna.rate_limit(limit: 1, store: store)
    ip = uniq
    Alumna::Testing.run_rule(rule_a, remote_ip: ip).error.should be_nil
    res = Alumna::Testing.run_rule(rule_b, remote_ip: ip)
    res.error.should_not be_nil
    if err = res.error
      err.status.should eq(429)
    end
    res.ctx.http.headers["X-RateLimit-Remaining"].should eq("0")
  end

  it "sets rate-limit headers on an allowed hit" do
    store = SHARED.rate_limit_store(1.hour)
    rule = Alumna.rate_limit(limit: 5, store: store)
    res = Alumna::Testing.run_rule(rule, remote_ip: uniq)
    res.error.should be_nil
    res.ctx.http.headers["X-RateLimit-Limit"].should eq("5")
    res.ctx.http.headers["X-RateLimit-Remaining"].should eq("4")
    res.ctx.http.headers["X-RateLimit-Reset"].should_not be_nil
  end
end
