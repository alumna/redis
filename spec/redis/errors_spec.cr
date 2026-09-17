require "../spec_helper"

describe Alumna::Redis::Errors do
  it "returns a generic message when the exception has no text" do
    Alumna::Redis::Errors.safe_message(Exception.new).should eq("Redis error")
    Alumna::Redis::Errors.safe_message(Exception.new("")).should eq("Redis error")
  end

  it "strips URI userinfo from a message" do
    raw = Exception.new("failed redis://user:secret@127.0.0.1:6379/0 extra")
    safe = Alumna::Redis::Errors.safe_message(raw)
    safe.includes?("secret").should be_false
    safe.includes?("user:").should be_false
    safe.should eq("failed redis://127.0.0.1:6379/0 extra")

    rediss = Exception.new("tls rediss://:hunter2@redis.example.com:6380/1")
    Alumna::Redis::Errors.safe_message(rediss).should eq("tls rediss://redis.example.com:6380/1")
  end

  it "wraps a driver exception as Alumna::Redis::Error" do
    wrapped = Alumna::Redis::Errors.wrap(Exception.new("boom redis://u:secret@host/db"))
    wrapped.should be_a(Alumna::Redis::Error)
    msg = wrapped.message || ""
    msg.includes?("secret").should be_false
    msg.should eq("boom redis://host/db")
  end
end

describe "spec Redis URL display" do
  it "strips userinfo from a spec abort URL" do
    display_redis_url("redis://user:secret@127.0.0.1:6379/0").includes?("secret").should be_false
    display_redis_url("not a uri ://").should_not be_nil
  end
end
