require "../spec_helper"

private def uniq : String
  UUID.random.to_s
end

private def geo_ok(result : T | Alumna::Redis::Error) : T forall T
  if result.is_a?(Alumna::Redis::Error)
    fail result.message
  end
  result
end

private def km_radius(magnitude : Number) : Alumna::Redis::Geo::Radius
  Alumna::Redis::Geo::Radius.new(magnitude, Alumna::Redis::Geo::Unit::KM)
end

private def m_box(width : Number, height : Number) : Alumna::Redis::Geo::Box
  Alumna::Redis::Geo::Box.new(width, height, Alumna::Redis::Geo::Unit::M)
end

describe Alumna::Redis::Geo do
  it "is the object from Alumna::Redis#geo" do
    SHARED.geo.should be_a(Alumna::Redis::Geo)
  end

  it "adds nothing when the member list is empty" do
    name = uniq
    geo_ok(SHARED.geo.add(name)).should eq(0)
    geo_ok(SHARED.geo.add(name, [] of Alumna::Redis::Geo::Member)).should eq(0)
    geo_ok(SHARED.geo.add(name, nx: true, ch: true)).should eq(0)
  end

  it "adds variadic members and member records" do
    name = uniq
    geo = SHARED.geo
    geo_ok(geo.add(name, "0", "0", "a", "0.1", "0", "b")).should eq(2)
    geo_ok(geo.add(name, "0", "0", "a")).should eq(0)
    added = geo_ok(geo.add(name, [
      Alumna::Redis::Geo::Member.new(longitude: 1, latitude: 0, member: "c"),
      Alumna::Redis::Geo::Member.new("2", "0", "d"),
    ]))
    added.should eq(2)
    places = geo_ok(geo.pos(name, "a", "c"))
    west = places[0]
    fail "missing a" unless west
    west[0].to_f.should be_close(0.0, 0.001)
    west[1].to_f.should be_close(0.0, 0.001)
    east = places[1]
    fail "missing c" unless east
    east[0].to_f.should be_close(1.0, 0.001)
  end

  it "writes the key under the global prefix only" do
    name = uniq
    geo_ok(SHARED.geo.add(name, "0", "0", "a")).should eq(1)
    SHARED.client.exists(SHARED.prefix + name).should eq(1)
    SHARED.client.exists(name).should eq(0)
  end

  it "keeps two prefixes apart" do
    left = must_redis(Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:"))
    right = must_redis(Alumna::Redis.new(REDIS_URL, prefix: "alumna-spec:#{UUID.random}:"))
    begin
      name = "same"
      geo_ok(left.geo.add(name, "0", "0", "a")).should eq(1)
      right_place = geo_ok(right.geo.pos(name, "a"))
      right_place[0].should be_nil
      left_place = geo_ok(left.geo.pos(name, "a"))
      left_place[0].should_not be_nil
    ensure
      left.close
      right.close
    end
  end

  it "honors nx, xx, and ch" do
    name = uniq
    geo = SHARED.geo
    geo_ok(geo.add(name, "0", "0", "a", xx: true)).should eq(0)
    missing = geo_ok(geo.pos(name, "a"))
    missing[0].should be_nil
    geo_ok(geo.add(name, "0", "0", "a", nx: true)).should eq(1)
    geo_ok(geo.add(name, "1", "0", "a", nx: true)).should eq(0)
    places = geo_ok(geo.pos(name, "a"))
    place = places[0]
    fail "missing a" unless place
    place[0].to_f.should be_close(0.0, 0.001)
    geo_ok(geo.add(name, "1", "0", "a", xx: true)).should eq(0)
    geo_ok(geo.add(name, "2", "0", "a", xx: true, ch: true)).should eq(1)
    moved_places = geo_ok(geo.pos(name, "a"))
    moved = moved_places[0]
    fail "missing moved a" unless moved
    moved[0].to_f.should be_close(2.0, 0.001)
  end

  it "rejects nx together with xx" do
    expect_raises(ArgumentError, "geo nx and xx are mutually exclusive") do
      SHARED.geo.add(uniq, "0", "0", "a", nx: true, xx: true)
    end
    expect_raises(ArgumentError, "geo nx and xx are mutually exclusive") do
      SHARED.geo.add(uniq, [] of Alumna::Redis::Geo::Member, nx: true, xx: true)
    end
  end

  it "returns positions and nil for a missing member" do
    name = uniq
    geo = SHARED.geo
    geo_ok(geo.add(name, "0", "0", "a"))
    geo_ok(geo.pos(name, [] of String)).should be_empty
    listed = geo_ok(geo.pos(name, ["a", "missing"]))
    listed.size.should eq(2)
    listed[0].should_not be_nil
    listed[1].should be_nil
  end

  it "returns nil distance when a member is missing" do
    name = uniq
    geo = SHARED.geo
    geo_ok(geo.add(name, "0", "0", "a", "0", "0.1", "b"))
    geo_ok(geo.dist(name, "a", "missing")).should be_nil
    meters = geo_ok(geo.dist(name, "a", "b"))
    fail "missing distance" unless meters
    meters.to_f.should be_close(11122.6, 1.0)
    km = geo_ok(geo.dist(name, "a", "b", Alumna::Redis::Geo::Unit::KM))
    fail "missing km" unless km
    km.to_f.should be_close(11.122, 0.01)
    mi = geo_ok(geo.dist(name, "a", "b", Alumna::Redis::Geo::Unit::MI))
    fail "missing mi" unless mi
    mi.to_f.should be_close(6.91, 0.05)
    ft = geo_ok(geo.dist(name, "a", "b", Alumna::Redis::Geo::Unit::FT))
    fail "missing ft" unless ft
    ft.to_f.should be_close(36491.0, 20.0)
  end

  it "sends unit tokens in lower case" do
    Alumna::Redis::Geo::Unit::M.to_s.should eq("m")
    Alumna::Redis::Geo::Unit::KM.to_s.should eq("km")
    Alumna::Redis::Geo::Unit::FT.to_s.should eq("ft")
    Alumna::Redis::Geo::Unit::MI.to_s.should eq("mi")
  end

  it "returns geohash strings" do
    name = uniq
    geo = SHARED.geo
    geo_ok(geo.add(name, "0", "0", "a"))
    geo_ok(geo.hash(name, [] of String)).should be_empty
    hashes = geo_ok(geo.hash(name, ["a", "missing"]))
    hashes[0].should eq("s0000000000")
    hashes[1].should be_nil
    geo_ok(geo.hash(name, "a")).should eq(["s0000000000"])
  end

  it "searches by radius and by box" do
    name = uniq
    geo = SHARED.geo
    geo_ok(geo.add(name, "0", "0", "a", "0", "0.1", "b", "0.1", "0", "c"))
    from_radius = geo_ok(geo.search(name, fromlonlat: {"0", "0"}, byradius: km_radius(20), sort: Alumna::Redis::Geo::Sort::ASC))
    from_radius.map(&.member).first?.should eq("a")
    from_radius.map(&.member).sort.should eq(["a", "b", "c"])
    from_member = geo_ok(geo.search(name, frommember: "a", byradius: km_radius(1), sort: Alumna::Redis::Geo::Sort::ASC))
    from_member.map(&.member).should eq(["a"])
    wide = geo_ok(geo.search(name, fromlonlat: {"0", "0"}, bybox: Alumna::Redis::Geo::Box.new(30, 1, Alumna::Redis::Geo::Unit::KM), sort: Alumna::Redis::Geo::Sort::ASC))
    wide.map(&.member).should eq(["a", "c"])
    tall = geo_ok(geo.search(name, frommember: "a", bybox: Alumna::Redis::Geo::Box.new("1", "30", Alumna::Redis::Geo::Unit::KM), sort: Alumna::Redis::Geo::Sort::DESC))
    tall.map(&.member).should eq(["b", "a"])
  end

  it "returns distance, score, and coordinates on a hit" do
    name = uniq
    geo = SHARED.geo
    geo_ok(geo.add(name, "0", "0", "a", "0", "0.1", "b"))
    hits = geo_ok(geo.search(
      name,
      frommember: "a",
      byradius: km_radius(20),
      sort: Alumna::Redis::Geo::Sort::ASC,
      count: 2,
      withcoord: true,
      withdist: true,
      withhash: true,
    ))
    hits.size.should eq(2)
    origin = hits[0]
    origin.member.should eq("a")
    origin.distance.should eq("0.0000")
    origin.hash.should be_a(Int64)
    longitude = origin.longitude
    fail "missing longitude" unless longitude
    longitude.to_f.should be_close(0.0, 0.001)
    latitude = origin.latitude
    fail "missing latitude" unless latitude
    latitude.to_f.should be_close(0.0, 0.001)
  end

  it "limits a search with count and any" do
    name = uniq
    geo = SHARED.geo
    geo_ok(geo.add(name, "0", "0", "a", "0", "0.1", "b", "0.1", "0", "c"))
    one = geo_ok(geo.search(name, fromlonlat: {"0", "0"}, byradius: km_radius(20), sort: Alumna::Redis::Geo::Sort::ASC, count: 1))
    one.map(&.member).should eq(["a"])
    any = geo_ok(geo.search(name, fromlonlat: {"0", "0"}, byradius: km_radius(20), count: 1, any: true))
    any.size.should eq(1)
    ["a", "b", "c"].should contain(any[0].member)
  end

  it "accepts a zero radius and a zero box" do
    name = uniq
    geo = SHARED.geo
    geo_ok(geo.add(name, "0", "0", "a"))
    geo_ok(geo.search(name, fromlonlat: {"0", "0"}, byradius: Alumna::Redis::Geo::Radius.new("0", Alumna::Redis::Geo::Unit::M))).should be_empty
    geo_ok(geo.search(name, fromlonlat: {"0", "0"}, bybox: Alumna::Redis::Geo::Box.new(0, 0, Alumna::Redis::Geo::Unit::M))).should be_empty
  end

  it "returns an empty search far from the index" do
    name = uniq
    geo_ok(SHARED.geo.add(name, "0", "0", "a"))
    geo_ok(SHARED.geo.search(name, fromlonlat: {"10", "10"}, byradius: km_radius(1))).should be_empty
  end

  it "rejects a search that has no single origin or area" do
    name = uniq
    radius = km_radius(1)
    expect_raises(ArgumentError, "geo search needs one origin") do
      SHARED.geo.search(name, byradius: radius)
    end
    expect_raises(ArgumentError, "geo search needs one origin") do
      SHARED.geo.search(name, fromlonlat: {"0", "0"}, frommember: "a", byradius: radius)
    end
    expect_raises(ArgumentError, "geo search needs one area") do
      SHARED.geo.search(name, fromlonlat: {"0", "0"})
    end
    expect_raises(ArgumentError, "geo search needs one area") do
      SHARED.geo.search(name, frommember: "a", byradius: radius, bybox: m_box(1, 1))
    end
  end

  it "rejects a bad count, any without count, and a negative size" do
    name = uniq
    expect_raises(ArgumentError, "geo count must be > 0") do
      SHARED.geo.search(name, fromlonlat: {"0", "0"}, byradius: km_radius(1), count: 0)
    end
    expect_raises(ArgumentError, "geo count must be > 0") do
      SHARED.geo.search(name, fromlonlat: {"0", "0"}, byradius: km_radius(1), count: -1)
    end
    expect_raises(ArgumentError, "geo count must be > 0") do
      SHARED.geo.search(name, fromlonlat: {"0", "0"}, byradius: km_radius(1), any: true)
    end
    expect_raises(ArgumentError, "geo radius must be >= 0") do
      SHARED.geo.search(name, fromlonlat: {"0", "0"}, byradius: Alumna::Redis::Geo::Radius.new("-1", Alumna::Redis::Geo::Unit::M))
    end
    expect_raises(ArgumentError, "geo box width must be >= 0") do
      SHARED.geo.search(name, fromlonlat: {"0", "0"}, bybox: Alumna::Redis::Geo::Box.new("-1", "1", Alumna::Redis::Geo::Unit::M))
    end
    expect_raises(ArgumentError, "geo box height must be >= 0") do
      SHARED.geo.search(name, frommember: "a", bybox: Alumna::Redis::Geo::Box.new("1", "-1", Alumna::Redis::Geo::Unit::M))
    end
    result = SHARED.geo.search(name, fromlonlat: {"0", "0"}, byradius: Alumna::Redis::Geo::Radius.new("nope", Alumna::Redis::Geo::Unit::M))
    result.should be_a(Alumna::Redis::Error)
  end

  it "stores a search and deletes the destination when nothing matches" do
    source = uniq
    destination = uniq
    geo = SHARED.geo
    geo_ok(geo.add(source, "0", "0", "a", "0", "0.1", "b"))
    SHARED.client.set(SHARED.prefix + destination, "keep")
    stored = geo_ok(geo.store(destination, source, fromlonlat: {"10", "10"}, byradius: km_radius(1)))
    stored.should eq(0)
    SHARED.client.exists(SHARED.prefix + destination).should eq(0)

    count = geo_ok(geo.store(
      destination,
      source,
      frommember: "a",
      byradius: km_radius(20),
      sort: Alumna::Redis::Geo::Sort::ASC,
      count: 1,
      storedist: true,
    ))
    count.should eq(1)
    score = SHARED.client.zscore(SHARED.prefix + destination, "a")
    fail "missing score" unless score
    score.to_f.should be_close(0.0, 0.01)

    plain = uniq
    geo_ok(geo.store(plain, source, fromlonlat: {"0", "0"}, bybox: Alumna::Redis::Geo::Box.new(30, 30, Alumna::Redis::Geo::Unit::KM)))
    plain_score = SHARED.client.zscore(SHARED.prefix + plain, "a")
    fail "missing plain score" unless plain_score
    plain_score.to_f.should be > 1000
  end

  it "removes members" do
    name = uniq
    geo = SHARED.geo
    geo_ok(geo.add(name, "0", "0", "a", "1", "0", "b", "2", "0", "c"))
    geo_ok(geo.remove(name, [] of String)).should eq(0)
    geo_ok(geo.remove(name, "a")).should eq(1)
    geo_ok(geo.remove(name, ["b", "missing"])).should eq(1)
    left = geo_ok(geo.pos(name, "a", "b", "c"))
    left.map { |place| place.nil? }.should eq([true, true, false])
  end

  it "returns Error for an invalid coordinate and for a down server" do
    result = SHARED.geo.add(uniq, "181", "0", "bad")
    result.should be_a(Alumna::Redis::Error)
    holder = must_redis(Alumna::Redis.new(dead_url(lazy: true)))
    begin
      down = holder.geo.add("x", "0", "0", "a")
      down.should be_a(Alumna::Redis::Error)
      if down.is_a?(Alumna::Redis::Error)
        down.message.includes?("secret").should be_false
        down.to_s.includes?("secret").should be_false
      end
    ensure
      holder.close
    end
  end
end

describe "Alumna::Redis geo on Cluster" do
  it "round-trips one key" do
    holder = new_cluster_holder
    begin
      name = uniq
      geo = holder.geo
      geo_ok(geo.add(name, "0", "0", "a", "0", "0.1", "b")).should eq(2)
      geo_ok(geo.pos(name, "a")).first?.should_not be_nil
      meters = geo_ok(geo.dist(name, "a", "b", Alumna::Redis::Geo::Unit::M))
      fail "missing distance" unless meters
      meters.to_f.should be_close(11122.6, 1.0)
      geo_ok(geo.hash(name, "a")).should eq(["s0000000000"])
      hits = geo_ok(geo.search(name, fromlonlat: {"0", "0"}, byradius: km_radius(20), sort: Alumna::Redis::Geo::Sort::ASC, withdist: true))
      hits.map(&.member).should eq(["a", "b"])
      geo_ok(geo.remove(name, "b")).should eq(1)
    ensure
      holder.close
    end
  end

  it "stores when both names share a hash tag" do
    holder = new_cluster_holder
    begin
      geo = holder.geo
      source = "{drivers}:src"
      destination = "{drivers}:out"
      geo_ok(geo.add(source, "0", "0", "a")).should eq(1)
      geo_ok(geo.store(destination, source, fromlonlat: {"0", "0"}, byradius: km_radius(1), storedist: true)).should eq(1)
      holder.client.zscore(holder.key("", destination), "a").should_not be_nil
    ensure
      holder.close
    end
  end

  it "returns Error when store keys use different slots" do
    holder = new_cluster_holder
    begin
      client = holder.client
      unless client.is_a?(::Redis::Cluster)
        fail "expected Redis::Cluster"
      end
      source = "slot-a"
      destination = "slot-b"
      if client.slot_for(holder.key("", source)) == client.slot_for(holder.key("", destination))
        destination = "slot-c"
      end
      client.slot_for(holder.key("", source)).should_not eq(client.slot_for(holder.key("", destination)))
      geo_ok(holder.geo.add(source, "0", "0", "a"))
      result = holder.geo.store(destination, source, fromlonlat: {"0", "0"}, byradius: km_radius(1))
      result.should be_a(Alumna::Redis::Error)
      if result.is_a?(Alumna::Redis::Error)
        result.message.includes?("CROSSSLOT").should be_true
      end
    ensure
      holder.close
    end
  end
end
