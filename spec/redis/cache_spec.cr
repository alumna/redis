require "../spec_helper"

private def uniq : String
  UUID.random.to_s
end

describe Alumna::RedisCache do
  it "is a Cache from Alumna::Redis#cache" do
    cache = SHARED.cache
    cache.should be_a(Alumna::Cache)
    cache.should be_a(Alumna::RedisCache)
  end

  it "round-trips bytes" do
    cache = SHARED.cache
    key = uniq
    cache.set(key, "hello".to_slice)
    cache.get(key).should eq("hello".to_slice)
  end

  it "returns nil for an unknown key" do
    SHARED.cache.get(uniq).should be_nil
  end

  it "returns nil after delete" do
    cache = SHARED.cache
    key = uniq
    cache.set(key, "v".to_slice)
    cache.delete(key)
    cache.get(key).should be_nil
  end

  it "deletes a missing key" do
    SHARED.cache.delete(uniq)
  end

  it "overwrites a key" do
    cache = SHARED.cache
    key = uniq
    cache.set(key, "a".to_slice)
    cache.set(key, "b".to_slice)
    cache.get(key).should eq("b".to_slice)
  end

  it "does not alias the stored slice with the caller slice" do
    cache = SHARED.cache
    key = uniq
    buf = Bytes.new(1, 1_u8)
    cache.set(key, buf)
    buf[0] = 2_u8
    cache.get(key).should eq(Bytes.new(1, 1_u8))
  end

  it "does not alias the stored slice with the returned slice" do
    cache = SHARED.cache
    key = uniq
    cache.set(key, Bytes.new(1, 1_u8))
    got = cache.get(key)
    if got
      got[0] = 9_u8
    end
    cache.get(key).should eq(Bytes.new(1, 1_u8))
  end

  it "keeps an entry with no ttl" do
    cache = SHARED.cache
    key = uniq
    cache.set(key, "v".to_slice)
    sleep 5.milliseconds
    cache.get(key).should eq("v".to_slice)
  end

  it "expires on get after the ttl" do
    cache = SHARED.cache
    key = uniq
    cache.set(key, "v".to_slice, 50.milliseconds)
    sleep 80.milliseconds
    cache.get(key).should be_nil
  end

  it "rejects a non-positive ttl on set" do
    cache = SHARED.cache
    expect_raises(ArgumentError, "cache ttl must be > 0") do
      cache.set(uniq, "v".to_slice, Time::Span.zero)
    end
    expect_raises(ArgumentError, "cache ttl must be > 0") do
      cache.set(uniq, "v".to_slice, -1.seconds)
    end
  end

  it "set_nx writes when the key is missing" do
    cache = SHARED.cache
    key = uniq
    cache.set_nx(key, "a".to_slice).should be_true
    cache.get(key).should eq("a".to_slice)
  end

  it "set_nx does not overwrite an existing key" do
    cache = SHARED.cache
    key = uniq
    cache.set(key, "a".to_slice)
    cache.set_nx(key, "b".to_slice).should be_false
    cache.get(key).should eq("a".to_slice)
  end

  it "set_nx writes after the existing key expires" do
    cache = SHARED.cache
    key = uniq
    cache.set(key, "a".to_slice, 50.milliseconds)
    sleep 80.milliseconds
    cache.set_nx(key, "b".to_slice, 1.hour).should be_true
    cache.get(key).should eq("b".to_slice)
  end

  it "rejects a non-positive ttl on set_nx" do
    expect_raises(ArgumentError, "cache ttl must be > 0") do
      SHARED.cache.set_nx(uniq, "v".to_slice, Time::Span.zero)
    end
  end

  it "increments a missing key to 1" do
    cache = SHARED.cache
    key = uniq
    cache.incr(key).should eq(1)
    cache.incr(key).should eq(2)
    cache.get(key).should eq("2".to_slice)
  end

  it "stores get find and fgen under a path hash-tag" do
    cache = SHARED.cache
    path = "/p-#{uniq}"
    get_logical = "alumna:get:#{path}:12"
    fgen_logical = "alumna:fgen:#{path}"
    find_logical = "alumna:find:1:#{path}:abc"
    cache.set(get_logical, "v".to_slice)
    SHARED.client.get(SHARED.cache_redis_key(get_logical)).should eq("v")
    cache.get(get_logical).should eq("v".to_slice)
    cache.incr(fgen_logical).should eq(1)
    SHARED.client.get(SHARED.cache_redis_key(fgen_logical)).should eq("1")
    cache.set(find_logical, "[]".to_slice)
    SHARED.client.get(SHARED.cache_redis_key(find_logical)).should eq("[]")
  end

  it "uses the cache prefix so two holders do not collide" do
    a = Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:")
    b = Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:")
    begin
      key = "same"
      a.cache.set(key, "A".to_slice)
      b.cache.set(key, "B".to_slice)
      a.cache.get(key).should eq("A".to_slice)
      b.cache.get(key).should eq("B".to_slice)
    ensure
      a.close
      b.close
    end
  end

  it "wraps a driver error without URI userinfo" do
    holder = Alumna::Redis.new(dead_url(lazy: true))
    begin
      ex = expect_raises(Alumna::Redis::Error) do
        holder.cache.get("x")
      end
      (ex.message || "").includes?("secret").should be_false
    ensure
      holder.close
    end
  end
end
