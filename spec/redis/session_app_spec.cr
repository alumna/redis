require "../spec_helper"
require "alumna/testing"

describe "Alumna.session(redis.session_store)" do
  it "authenticates on a second app with the cookie from the first" do
    holder = Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:")
    begin
      sessions_a = Alumna::Session.new(holder.session_store(ttl: 1.hour))
      sessions_b = Alumna::Session.new(Alumna::RedisSessionStore.new(holder, 1.hour))

      app_a = Alumna::App.new
      app_a.use "/login", Alumna.memory(Alumna::Schema.new) {
        after on: :create do |ctx|
          sessions_a.start(ctx, Alumna.hash(user_id: "u1"))
          nil
        end
      }

      app_b = Alumna::App.new
      app_b.use "/me", Alumna.memory(Alumna::Schema.new) {
        before sessions_b.rule
        before do |ctx|
          session = ctx.store["session"]?.as?(Hash(String, Alumna::AnyData))
          next Alumna::ServiceError.unauthorized unless session
          ctx.result = session
          nil
        end
      }

      client_a = Alumna::Testing::AppClient.new(app_a)
      client_b = Alumna::Testing::AppClient.new(app_b)
      login = client_a.post("/login")
      login.status.should eq(201)
      set_cookie = login.headers["Set-Cookie"]?
      sid = set_cookie ? Alumna::Http.cookie_value(set_cookie.split(';').first, "alumna.sid") : nil
      if sid
        me = client_b.get("/me", headers: {"Cookie" => "alumna.sid=#{sid}"})
        me.status.should eq(200)
        me.json_hash["user_id"].should eq("u1")
      end
    ensure
      holder.close
    end
  end

  it "rejects an unknown cookie on a second app" do
    holder = Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:")
    begin
      sessions = Alumna::Session.new(holder.session_store)
      app = Alumna::App.new
      app.use "/me", Alumna.memory(Alumna::Schema.new) {
        before sessions.rule
      }
      client = Alumna::Testing::AppClient.new(app)
      res = client.get("/me", headers: {"Cookie" => "alumna.sid=missing"})
      res.status.should eq(401)
    ensure
      holder.close
    end
  end

  it "stops the session so a second app is unauthorized" do
    holder = Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:")
    begin
      store = holder.session_store(ttl: 1.hour)
      sessions_a = Alumna::Session.new(store)
      sessions_b = Alumna::Session.new(store)

      app_a = Alumna::App.new
      app_a.use "/login", Alumna.memory(Alumna::Schema.new) {
        after on: :create do |ctx|
          sessions_a.start(ctx, Alumna.hash(user_id: "u1"))
          nil
        end
      }
      app_a.use "/logout", Alumna.memory(Alumna::Schema.new) {
        before sessions_a.rule
        after on: :create do |ctx|
          sessions_a.stop(ctx)
          nil
        end
      }
      app_b = Alumna::App.new
      app_b.use "/me", Alumna.memory(Alumna::Schema.new) {
        before sessions_b.rule
      }

      client_a = Alumna::Testing::AppClient.new(app_a)
      client_b = Alumna::Testing::AppClient.new(app_b)
      login = client_a.post("/login")
      set_cookie = login.headers["Set-Cookie"]?
      sid = set_cookie ? Alumna::Http.cookie_value(set_cookie.split(';').first, "alumna.sid") : nil
      if sid
        cookie = "alumna.sid=#{sid}"
        client_b.get("/me", headers: {"Cookie" => cookie}).status.should eq(200)
        client_a.post("/logout", headers: {"Cookie" => cookie})
        client_b.get("/me", headers: {"Cookie" => cookie}).status.should eq(401)
      end
    ensure
      holder.close
    end
  end
end
