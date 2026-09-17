require "../spec_helper"

private def uniq : String
  UUID.random.to_s
end

describe Alumna::RedisSessionStore do
  it "is a SessionStore from Alumna::Redis#session_store" do
    store = SHARED.session_store
    store.should be_a(Alumna::SessionStore)
    store.should be_a(Alumna::RedisSessionStore)
    store.default_ttl.should eq(24.hours)
  end

  it "round-trips data" do
    store = SHARED.session_store(ttl: 1.hour)
    id = store.new_id
    store.set(id, Alumna.hash(user_id: "1"))
    store.get(id).should eq(Alumna.hash(user_id: "1"))
  end

  it "returns nil for an unknown id" do
    SHARED.session_store.get(uniq).should be_nil
  end

  it "returns nil after delete" do
    store = SHARED.session_store
    id = store.new_id
    store.set(id, Alumna.hash(k: "v"))
    store.delete(id)
    store.get(id).should be_nil
  end

  it "deletes a missing id" do
    SHARED.session_store.delete(uniq)
  end

  it "expires on get after the ttl" do
    store = SHARED.session_store(ttl: 50.milliseconds)
    id = store.new_id
    store.set(id, Alumna.hash(k: "v"))
    sleep 80.milliseconds
    store.get(id).should be_nil
  end

  it "honors a per-set ttl" do
    store = SHARED.session_store(ttl: 1.hour)
    id = store.new_id
    store.set(id, Alumna.hash(k: "v"), 50.milliseconds)
    sleep 80.milliseconds
    store.get(id).should be_nil
  end

  it "does not alias the stored hash with the caller hash" do
    store = SHARED.session_store
    id = store.new_id
    data = Alumna.hash(k: "v")
    store.set(id, data)
    data["k"] = "mutated"
    got = store.get(id)
    if got
      got["k"].should eq("v")
    end
  end

  it "does not alias the stored hash with the returned hash" do
    store = SHARED.session_store
    id = store.new_id
    store.set(id, Alumna.hash(k: "v"))
    got = store.get(id)
    if got
      got["k"] = "mutated"
    end
    again = store.get(id)
    if again
      again["k"].should eq("v")
    end
  end

  it "rejects a non-positive ttl at boot" do
    expect_raises(ArgumentError, "session ttl must be > 0") do
      Alumna::RedisSessionStore.new(SHARED, Time::Span.zero)
    end
  end

  it "rejects a non-positive ttl on set" do
    store = SHARED.session_store
    expect_raises(ArgumentError, "session ttl must be > 0") do
      store.set(uniq, Alumna.hash(k: "v"), Time::Span.zero)
    end
    expect_raises(ArgumentError, "session ttl must be > 0") do
      store.set(uniq, Alumna.hash(k: "v"), -1.seconds)
    end
  end

  it "creates unique ids" do
    store = SHARED.session_store
    store.new_id.should_not eq(store.new_id)
    store.new_id.size.should be > 0
  end

  it "returns nil for corrupt or non-hash JSON" do
    store = SHARED.session_store
    id = uniq
    raw = SHARED.key(SHARED.session_prefix, id)
    SHARED.client.set(raw, "{")
    store.get(id).should be_nil
    SHARED.client.set(raw, "[1]")
    store.get(id).should be_nil
  end

  it "uses the session prefix so two holders do not collide" do
    a = Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:")
    b = Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:")
    begin
      id = "same"
      a.session_store.set(id, Alumna.hash(who: "A"))
      b.session_store.set(id, Alumna.hash(who: "B"))
      a_got = a.session_store.get(id)
      b_got = b.session_store.get(id)
      if a_got
        a_got["who"].should eq("A")
      end
      if b_got
        b_got["who"].should eq("B")
      end
    ensure
      a.close
      b.close
    end
  end

  it "wraps a driver error without URI userinfo" do
    holder = Alumna::Redis.new(dead_url(lazy: true))
    begin
      ex = expect_raises(Alumna::Redis::Error) do
        holder.session_store.get("x")
      end
      (ex.message || "").includes?("secret").should be_false
    ensure
      holder.close
    end
  end
end
