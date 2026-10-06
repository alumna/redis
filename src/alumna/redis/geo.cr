# Geospatial index on the holder client. One index is one Redis key.
# The key is the global prefix plus the name. No alumna:geo: prefix.
# On Cluster, store destination and source must share a hash tag.
# An empty store deletes the destination key.
# A missing member is nil. An empty search is an empty array.
# Driver failures return Alumna::Redis::Error.
# nx with xx, count <= 0, and a negative radius or box size raise ArgumentError.
# Redis checks longitude and latitude. Radius 0 and box 0 are valid.
# GEODIST nil uses client.run. The driver cast raises on nil.
class Alumna::Redis
  class Geo
    record Member, longitude : String, latitude : String, member : String do
      def self.new(longitude : Number, latitude : Number, member : String)
        new(longitude.to_s, latitude.to_s, member)
      end
    end

    record Radius, magnitude : String, unit : Unit do
      def self.new(magnitude : Number, unit : Unit)
        new(magnitude.to_s, unit)
      end
    end

    record Box, width : String, height : String, unit : Unit do
      def self.new(width : Number, height : Number, unit : Unit)
        new(width.to_s, height.to_s, unit)
      end
    end

    # distance and coordinates are Redis decimal strings.
    # hash is the 52-bit WITHHASH score, not the GEOHASH string.
    struct Hit
      getter member : String
      getter distance : String?
      getter hash : Int64?
      getter longitude : String?
      getter latitude : String?

      def initialize(@member : String, @distance : String? = nil, @hash : Int64? = nil, @longitude : String? = nil, @latitude : String? = nil)
      end
    end

    # Wire token is m, km, ft, or mi.
    enum Unit
      M
      KM
      FT
      MI

      # Literals, so a search does not allocate the unit token.
      def to_s : String
        case self
        when M  then "m"
        when KM then "km"
        when FT then "ft"
        when MI then "mi"
        else         super
        end
      end
    end

    enum Sort
      ASC
      DESC
    end

    def initialize(@redis : Alumna::Redis)
    end

    def add(name : String, *, nx : Bool = false, xx : Bool = false, ch : Bool = false) : Int64 | Error
      command do
        check_nx_xx(nx, xx)
        0_i64
      end
    end

    def add(name : String, *entries : String, nx : Bool = false, xx : Bool = false, ch : Bool = false) : Int64 | Error
      command do
        check_nx_xx(nx, xx)
        run_add(name, nx, xx, ch, 4 + entries.size) do |cmd|
          entries.each { |entry| cmd << entry }
        end
      end
    end

    def add(name : String, entries : Enumerable(Member), *, nx : Bool = false, xx : Bool = false, ch : Bool = false) : Int64 | Error
      command do
        check_nx_xx(nx, xx)
        if entries.empty?
          0_i64
        else
          run_add(name, nx, xx, ch, 4 + entries.size * 3) do |cmd|
            entries.each do |entry|
              cmd << entry.longitude << entry.latitude << entry.member
            end
          end
        end
      end
    end

    def pos(name : String, *members : String) : Array({String, String}?) | Error
      positions(name, members)
    end

    def pos(name : String, members : Enumerable(String)) : Array({String, String}?) | Error
      positions(name, members)
    end

    # Nil when either member is missing. Default unit is meters.
    def dist(name : String, member1 : String, member2 : String, unit : Unit? = nil) : String? | Error
      command do
        cmd = Array(String).new(5)
        cmd << "geodist" << full_key(name) << member1 << member2
        cmd << unit.to_s if unit
        @redis.client.run(cmd).as?(String)
      end
    end

    def hash(name : String, *members : String) : Array(String?) | Error
      hashes(name, members)
    end

    def hash(name : String, members : Enumerable(String)) : Array(String?) | Error
      hashes(name, members)
    end

    def search(
      name : String,
      *,
      fromlonlat : {String, String}? = nil,
      frommember : String? = nil,
      byradius : Radius? = nil,
      bybox : Box? = nil,
      sort : Sort? = nil,
      count : Int? = nil,
      any : Bool = false,
      withcoord : Bool = false,
      withdist : Bool = false,
      withhash : Bool = false,
    ) : Array(Hit) | Error
      command do
        prepare_query(fromlonlat, frommember, byradius, bybox, count, any)
        cmd = Array(String).new(16)
        cmd << "geosearch" << full_key(name)
        append_query(cmd, fromlonlat, frommember, byradius, bybox, sort, count, any, withcoord, withdist, withhash, false)
        parse_hits(@redis.client.run(cmd), withdist, withhash, withcoord)
      end
    end

    # Empty result deletes the destination key.
    def store(
      destination : String,
      source : String,
      *,
      fromlonlat : {String, String}? = nil,
      frommember : String? = nil,
      byradius : Radius? = nil,
      bybox : Box? = nil,
      sort : Sort? = nil,
      count : Int? = nil,
      any : Bool = false,
      storedist : Bool = false,
    ) : Int64 | Error
      command do
        prepare_query(fromlonlat, frommember, byradius, bybox, count, any)
        cmd = Array(String).new(16)
        cmd << "geosearchstore" << full_key(destination) << full_key(source)
        append_query(cmd, fromlonlat, frommember, byradius, bybox, sort, count, any, false, false, false, storedist)
        @redis.client.run(cmd).as(Int64)
      end
    end

    def remove(name : String, *members : String) : Int64 | Error
      delete(name, members)
    end

    def remove(name : String, members : Enumerable(String)) : Int64 | Error
      delete(name, members)
    end

    private def positions(name : String, members : Enumerable(String)) : Array({String, String}?) | Error
      command do
        if members.empty?
          [] of {String, String}?
        else
          cmd = Array(String).new(2 + members.size)
          cmd << "geopos" << full_key(name)
          members.each { |member| cmd << member }
          rows = @redis.client.run(cmd).as(Array)
          Array({String, String}?).new(rows.size) { |index| parse_coord(rows[index]) }
        end
      end
    end

    private def hashes(name : String, members : Enumerable(String)) : Array(String?) | Error
      command do
        if members.empty?
          [] of String?
        else
          cmd = Array(String).new(2 + members.size)
          cmd << "geohash" << full_key(name)
          members.each { |member| cmd << member }
          rows = @redis.client.run(cmd).as(Array)
          Array(String?).new(rows.size) { |index| rows[index].as?(String) }
        end
      end
    end

    private def delete(name : String, members : Enumerable(String)) : Int64 | Error
      command do
        if members.empty?
          0_i64
        else
          @redis.client.zrem(full_key(name), members)
        end
      end
    end

    private def run_add(name : String, nx : Bool, xx : Bool, ch : Bool, capacity : Int, &) : Int64
      cmd = Array(String).new(capacity)
      cmd << "geoadd" << full_key(name)
      cmd << "nx" if nx
      cmd << "xx" if xx
      cmd << "ch" if ch
      yield cmd
      @redis.client.run(cmd).as(Int64)
    end

    private def prepare_query(fromlonlat : {String, String}?, frommember : String?, byradius : Radius?, bybox : Box?, count : Int?, any : Bool) : Nil
      origins = 0
      origins += 1 if fromlonlat
      origins += 1 if frommember
      raise ArgumentError.new("geo search needs one origin") unless origins == 1

      areas = 0
      areas += 1 if byradius
      areas += 1 if bybox
      raise ArgumentError.new("geo search needs one area") unless areas == 1

      if radius = byradius
        check_non_negative(radius.magnitude, "radius")
      end
      if box = bybox
        check_non_negative(box.width, "box width")
        check_non_negative(box.height, "box height")
      end
      if count.nil?
        raise ArgumentError.new("geo count must be > 0") if any
      elsif count <= 0
        raise ArgumentError.new("geo count must be > 0")
      end
    end

    private def append_query(cmd : Array(String), fromlonlat : {String, String}?, frommember : String?, byradius : Radius?, bybox : Box?, sort : Sort?, count : Int?, any : Bool, withcoord : Bool, withdist : Bool, withhash : Bool, storedist : Bool) : Nil
      if lonlat = fromlonlat
        cmd << "fromlonlat" << lonlat[0] << lonlat[1]
      elsif member = frommember
        cmd << "frommember" << member
      end
      if radius = byradius
        cmd << "byradius" << radius.magnitude << radius.unit.to_s
      elsif box = bybox
        cmd << "bybox" << box.width << box.height << box.unit.to_s
      end
      cmd << sort.to_s if sort
      if count
        cmd << "count" << count.to_s
        cmd << "any" if any
      end
      cmd << "withcoord" if withcoord
      cmd << "withdist" if withdist
      cmd << "withhash" if withhash
      cmd << "storedist" if storedist
    end

    private def parse_hits(value : ::Redis::Value, withdist : Bool, withhash : Bool, withcoord : Bool) : Array(Hit)
      rows = value.as(Array)
      if withdist || withhash || withcoord
        Array(Hit).new(rows.size) do |index|
          parse_hit(rows[index].as(Array), withdist, withhash, withcoord)
        end
      else
        Array(Hit).new(rows.size) { |index| Hit.new(rows[index].as(String)) }
      end
    end

    private def parse_hit(fields : Array(::Redis::Value), withdist : Bool, withhash : Bool, withcoord : Bool) : Hit
      index = 0
      member = fields[index].as(String)
      index += 1
      distance : String? = nil
      if withdist
        distance = fields[index].as(String)
        index += 1
      end
      score : Int64? = nil
      if withhash
        score = fields[index].as(Int64)
        index += 1
      end
      longitude : String? = nil
      latitude : String? = nil
      if withcoord
        coord = fields[index].as(Array)
        longitude = coord[0].as(String)
        latitude = coord[1].as(String)
      end
      Hit.new(member, distance, score, longitude, latitude)
    end

    private def parse_coord(value : ::Redis::Value) : {String, String}?
      coord = value.as?(Array)
      return nil unless coord
      {coord[0].as(String), coord[1].as(String)}
    end

    private def check_nx_xx(nx : Bool, xx : Bool) : Nil
      raise ArgumentError.new("geo nx and xx are mutually exclusive") if nx && xx
    end

    private def check_non_negative(text : String, label : String) : Nil
      value = text.to_f64?
      return unless value
      raise ArgumentError.new("geo #{label} must be >= 0") if value < 0
    end

    private def full_key(name : String) : String
      @redis.key("", name)
    end

    private def command(& : -> T) : T | Error forall T
      yield
    rescue ex : ArgumentError
      raise ex
    rescue ex
      Errors.wrap(ex)
    end
  end

  @geo : Geo?

  # One geo object per holder. The object holds no request state.
  def geo : Geo
    geo = @geo
    if geo
      geo
    else
      @geo = Geo.new(self)
    end
  end
end
