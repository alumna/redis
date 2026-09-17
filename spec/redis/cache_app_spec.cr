require "../spec_helper"
require "alumna/testing"

private def cache_schema
  Alumna::Schema.new.str("title", required_on: [:create, :update], min_length: 1)
end

private class CacheGetCounter < Alumna::MemoryAdapter
  getter get_count : Int32 = 0
  getter find_count : Int32 = 0

  def get(ctx)
    @get_count += 1
    super
  end

  def find(ctx)
    @find_count += 1
    super
  end
end

private def get_cache_key(id : String) : String
  "alumna:get:/posts:" + id
end

describe "Alumna.cache(redis.cache)" do
  it "hits get on a second app after create on the first" do
    holder = Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:")
    begin
      rule = Alumna.cache(holder.cache, ttl: 1.hour)
      posts_a = Alumna::MemoryAdapter.new(cache_schema)
      posts_a.before(rule, on: :read)
      posts_a.after(rule)
      app_a = Alumna::App.new
      app_a.use "/posts", posts_a

      posts_b = CacheGetCounter.new(cache_schema)
      posts_b.before(rule, on: :read)
      posts_b.after(rule)
      app_b = Alumna::App.new
      app_b.use "/posts", posts_b

      client_a = Alumna::Testing::AppClient.new(app_a)
      client_b = Alumna::Testing::AppClient.new(app_b)
      created = client_a.post("/posts", body: %({"title":"A"})).json_hash
      id = created["id"].as(String)
      client_b.get("/posts/#{id}").json_hash["title"].should eq("A")
      posts_b.get_count.should eq(0)
    ensure
      holder.close
    end
  end

  it "misses get when the id is unknown" do
    holder = Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:")
    begin
      rule = Alumna.cache(holder.cache, ttl: 1.hour)
      posts = CacheGetCounter.new(cache_schema)
      posts.before(rule, on: :read)
      posts.after(rule)
      app = Alumna::App.new
      app.use "/posts", posts
      client = Alumna::Testing::AppClient.new(app)
      client.get("/posts/1").status.should eq(404)
      posts.get_count.should eq(1)
    ensure
      holder.close
    end
  end

  it "fills a get miss with set_nx then hits" do
    holder = Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:")
    begin
      cache = holder.cache
      rule = Alumna.cache(cache, ttl: 1.hour)
      posts = CacheGetCounter.new(cache_schema)
      posts.before(rule, on: :read)
      posts.after(rule)
      app = Alumna::App.new
      app.use "/posts", posts
      client = Alumna::Testing::AppClient.new(app)
      id = client.post("/posts", body: %({"title":"A"})).json_hash["id"].as(String)
      cache.delete(get_cache_key(id))
      client.get("/posts/#{id}").json_hash["title"].should eq("A")
      posts.get_count.should eq(1)
      client.get("/posts/#{id}").json_hash["title"].should eq("A")
      posts.get_count.should eq(1)
    ensure
      holder.close
    end
  end

  it "writes through patch so the second app sees the new title" do
    holder = Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:")
    begin
      rule = Alumna.cache(holder.cache, ttl: 1.hour)
      posts_a = Alumna::MemoryAdapter.new(cache_schema)
      posts_a.before(rule, on: :read)
      posts_a.after(rule)
      app_a = Alumna::App.new
      app_a.use "/posts", posts_a

      posts_b = CacheGetCounter.new(cache_schema)
      posts_b.before(rule, on: :read)
      posts_b.after(rule)
      app_b = Alumna::App.new
      app_b.use "/posts", posts_b

      client_a = Alumna::Testing::AppClient.new(app_a)
      client_b = Alumna::Testing::AppClient.new(app_b)
      id = client_a.post("/posts", body: %({"title":"A"})).json_hash["id"].as(String)
      client_a.patch("/posts/#{id}", body: %({"title":"B"}))
      client_b.get("/posts/#{id}").json_hash["title"].should eq("B")
      posts_b.get_count.should eq(0)
    ensure
      holder.close
    end
  end

  it "deletes the get key on remove" do
    holder = Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:")
    begin
      cache = holder.cache
      rule = Alumna.cache(cache, ttl: 1.hour)
      posts = Alumna::MemoryAdapter.new(cache_schema)
      posts.before(rule, on: :read)
      posts.after(rule)
      app = Alumna::App.new
      app.use "/posts", posts
      client = Alumna::Testing::AppClient.new(app)
      id = client.post("/posts", body: %({"title":"A"})).json_hash["id"].as(String)
      client.delete("/posts/#{id}")
      client.get("/posts/#{id}").status.should eq(404)
      cache.get(get_cache_key(id)).should be_nil
    ensure
      holder.close
    end
  end

  it "caches find on the same app" do
    holder = Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:")
    begin
      rule = Alumna.cache(holder.cache, ttl: 1.hour)
      posts = CacheGetCounter.new(cache_schema)
      posts.before(rule, on: :read)
      posts.after(rule)
      app = Alumna::App.new
      app.use "/posts", posts
      client = Alumna::Testing::AppClient.new(app)
      client.post("/posts", body: %({"title":"A"}))
      client.get("/posts").json_array.size.should eq(1)
      posts.find_count.should eq(1)
      client.get("/posts").json_array.size.should eq(1)
      posts.find_count.should eq(1)
    ensure
      holder.close
    end
  end
end
