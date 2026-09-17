require "../spec_helper"

private def uniq : String
  UUID.random.to_s
end

# Live Cluster for the three ports. Key shape is unchanged.
describe "Alumna::Redis ports on Cluster" do
  it "round-trips cache GET SET DEL INCR" do
    holder = new_cluster_holder
    begin
      cache = holder.cache
      key = uniq
      cache.set(key, "hello".to_slice)
      cache.get(key).should eq("hello".to_slice)
      cache.set_nx(key, "nope".to_slice).should be_false
      cache.set_nx(uniq, "a".to_slice, 1.hour).should be_true
      cache.incr("gen-#{key}").should eq(1)
      cache.incr("gen-#{key}").should eq(2)
      cache.delete(key)
      cache.get(key).should be_nil
    ensure
      holder.close
    end
  end

  it "round-trips a session blob" do
    holder = new_cluster_holder
    begin
      store = holder.session_store(ttl: 1.hour)
      id = store.new_id
      store.set(id, Alumna.hash(user_id: "1"))
      store.get(id).should eq(Alumna.hash(user_id: "1"))
      store.delete(id)
      store.get(id).should be_nil
    ensure
      holder.close
    end
  end

  it "puts get find and fgen for one path on one slot" do
    holder = new_cluster_holder
    begin
      client = holder.client
      unless client.is_a?(::Redis::Cluster)
        fail "expected Redis::Cluster"
      end
      get_key = holder.cache_redis_key("alumna:get:/posts:12")
      fgen_key = holder.cache_redis_key("alumna:fgen:/posts")
      find_key = holder.cache_redis_key("alumna:find:3:/posts:abc")
      slot = client.slot_for(get_key)
      client.slot_for(fgen_key).should eq(slot)
      client.slot_for(find_key).should eq(slot)
      client.set(get_key, "v")
      client.set(fgen_key, "1")
      client.del(get_key, fgen_key).should eq(2)
    ensure
      holder.close
    end
  end

  it "raises CROSSSLOT for untagged keys on different slots" do
    holder = new_cluster_holder
    begin
      client = holder.client
      unless client.is_a?(::Redis::Cluster)
        fail "expected Redis::Cluster"
      end
      left = "#{SPEC_PREFIX}cross-a"
      right = "#{SPEC_PREFIX}cross-b"
      if client.slot_for(left) == client.slot_for(right)
        right = "#{SPEC_PREFIX}cross-c"
      end
      client.slot_for(left).should_not eq(client.slot_for(right))
      expect_raises(::Redis::Cluster::CrossSlot) do
        client.del(left, right)
      end
    ensure
      holder.close
    end
  end

  it "increments a rate-limit Lua key twice" do
    holder = new_cluster_holder
    begin
      store = holder.rate_limit_store(1.hour)
      key = uniq
      c1, t1 = store.hit(key)
      c2, t2 = store.hit(key)
      c1.should eq(1)
      c2.should eq(2)
      t1.to_unix.should eq(t2.to_unix)
      t1.should be > Time.utc
    ensure
      holder.close
    end
  end
end
