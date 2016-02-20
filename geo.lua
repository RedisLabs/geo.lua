local _NAME = 'geo.lua'
local _VERSION = '0.1.5'
local _DESCRIPTION = 'A helper library for Redis geospatial indices'
local _COPYRIGHT = '2016 Itamar Haber, Redis Labs'
local _USAGE = [[

Call with ARGV[1] being one of the following commands:
  
  - GEO API completeness -
  GEODEL        - delete a member
  GEOBEARING    - initial and final bearing between members
  GEOPATHLEN    - length of a path between members
  GEOPOLYGON    - search inside a polygon
    
  - GeoJSON -
  GEOJSONADD    - add members to geoset from GeoJSON object
  GEOJSONENCODE - return GeoJSON object for these GEO commands:
                  GEOHASH, GEOPOS, GEORADIUS[BYMEMBER] and
                  GEOPOLYGON

  - xyzsets (longitude, latitude & altitude) -
  GEOZADD       - add member with altitude
  GEOZREM       - remove member
  GEOZPOS       - the 3d position of members
  
  - location updates (credit @mattsta) -
  GEOTRACK      - positional updates notifications

  help          - this text

]]

local Geo = {}

-- private
Geo._TYPE_GEO = 1 -- regular geoset
Geo._TYPE_XYZ = 2 -- xyzset

--- Keys validation
-- Extract and validate types of keys for command
-- @param geotype The type of command
-- @return geoset Key name
-- @return azset  Key name
Geo._getcommandkeys = function (geotype)
  
  local function asserttype(k, t)
    local r = redis.call('TYPE', k)
    assert(r == t or r == 'none', 'WRONGTYPE Operation against a key holding the wrong kind of value')
  end
  
  local geokey = assert(table.remove(KEYS, 1), 'No geoset key name provided')
  asserttype(geokey, 'zset')
  
  if geotype == Geo._TYPE_XYZ then
    local zsetkey = assert(table.remove(KEYS, 1), 'No altitude sorted set key name provided')
    asserttype(zsetkey, 'zset')
    return geokey, zsetkey
  end
  
  return geokey
end

--- Calculates distance between two coordinates.
-- Just like calling GEODIST, but slower and of slightly different
-- accuracy.
-- @param lon1 The longitude of the 1st coordinate
-- @param lat1 The latitude of the 1st coordinate
-- @param lon2 The longitude of the 2nd coordinate
-- @param lat2 The latitude of the 2nd coordinate
-- @return distance The distance in meters
Geo._distance = function (lon1, lat1, lon2, lat2)
  local R = 6372797.560856 -- Earth's, in meters
  local lon1r, lat1r, lon2r, lat2r = 
    math.rad(lon1), math.rad(lat1), math.rad(lon2), math.rad(lat2)
  local u = math.sin((lat2r - lat1r) / 2)
  local v = math.sin((lon2r - lon1r) / 2)
  return 2.0 * R * math.asin(math.sqrt(u * u + math.cos(lat1r) * math.cos(lat2r) * v * v))
end

-- public API

--- Delete a member.
-- @return deleted Number of deleted members
Geo.GEODEL = function()
  local geokey = Geo._getcommandkeys(Geo._TYPE_GEO)
  return redis.call('ZREM', geokey, unpack(ARGV))
end

--- Returns bearing between two members.
-- @return bearings Table containing the initial and final bearings
Geo.GEOBEARING = function()
  local geokey = Geo._getcommandkeys(Geo._TYPE_GEO)
  
  assert(#ARGV == 2, 'Two members must be provided')
  local member1, member2 = table.remove(ARGV, 1), table.remove(ARGV, 1)
  
  local coords = redis.call('GEOPOS', geokey, member1, member2)
  assert(coords[1] and coords[2], 'Two existing members must be provided')
  
  local function initialbearing(lon1, lat1, lon2, lat2)
    local p1, p2 = math.rad(lat1), math.rad(lat2)
    local dl = math.rad(lon2 - lon1)
    local y = math.sin(dl)*math.cos(p2)
    local x = math.cos(p1)*math.sin(p2) - math.sin(p1)*math.cos(p2)*math.cos(dl)
    local b = (math.deg(math.atan2(y, x)) + 360) % 360
    return b
  end
  
  local ib = initialbearing(coords[1][1], coords[1][2], coords[2][1], coords[2][2])
  local fb = (initialbearing(coords[2][1], coords[2][2], coords[1][1], coords[1][2]) + 180) % 360

  return { tostring(ib), tostring(fb) }
end

--- Calculates the length of a path given by members.
-- @return length Path's length in meters
Geo.GEOPATHLEN = function()
  local geokey = Geo._getcommandkeys(Geo._TYPE_GEO)
  assert(#ARGV > 1, 'Need at least two members to make a path')
  
  local total = 0
  local prev = table.remove(ARGV, 1)
  while #ARGV > 0 do
    local curr = table.remove(ARGV, 1)
    local dist = redis.call('GEODIST', geokey, prev, curr, 'm')
    if dist then
      total = total + dist    
      prev = curr
    else
      return
    end
  end
  
  return total
end

--- Calculates the bounding circle for a set of coordinates.
-- @param v The coordinates table
-- @return clon The longitude of the circle's center
-- @return clat The latitude of the circle's center
-- @return radius The circle's radius 
Geo._verticesboundingcircle = function(v)
  local clon, clat = 0, 0 -- centroid longitude and latitude
  local radius = 0.0
  
  -- the center is the average
  local n = #v / 2
  for i = 1, n do
    clon = clon + v[2*i-1]
    clat = clat + v[2*i]
  end
  clon, clat = clon / n, clat / n
  
  -- farthest point is the radius
  for i = 1, n do
    local d = Geo._distance(clon, clat, v[2*i-1], v[2*i])
    if radius < d then
      radius = d
    end
  end
  radius = math.ceil(radius)
  
  return clon, clat, radius
end

--- Performs a search for members inside a simple polygon.
-- @return members Table with the members
Geo.GEOPOLYGON = function ()
  local geokey = Geo._getcommandkeys(Geo._TYPE_GEO)
  local wc = false
  if ARGV[1]:upper() == "WITHCOORD" then
    wc = true
    table.remove(ARGV, 1)
  end
  
  for i, v in ipairs(ARGV) do
    ARGV[i] = assert(tonumber(v), 'Expecting numbers as coordinates')
  end
  assert(#ARGV > 5, 'Expecting at least 3 coordinates')
  assert(#ARGV % 2 == 0, 'Expecting an even number of arguments')
  
  -- get the bounding circle and perform a radius search
  local clon, clat, radius = Geo._verticesboundingcircle(ARGV)
  local reply = redis.call('GEORADIUS', geokey, clon, clat, radius, 'm', 'WITHCOORD')
  
  -- filter members that are outside
  local n = #ARGV / 2
  for i, r in ipairs(reply) do
    local j = n
    local o = false
    local x, y = tonumber(r[2][1]), tonumber(r[2][2])
    
    for k = 1, n do
      if (ARGV[2*k]<y and ARGV[2*j]>=y
        or ARGV[2*j]<y and ARGV[2*k]>=y)
        and (ARGV[2*k-1]<=x or ARGV[2*j-1]<=x) then
        if ARGV[2*k-1]+(y-ARGV[2*k])/(ARGV[2*j]-ARGV[2*k])*(ARGV[2*j-1]-ARGV[2*k-1])<x then
          o = not o
        end
      end
      j = k
    end
    
    if o then -- in the polygon
      if not wc then -- remove coordinates
        reply[i] = reply[i][1]
      end
    else
      reply[i] = nil
    end
  end        
  
  return reply
end

--- Adds members in a GeoJSON object to a geoset.
-- @return added The number of members added
Geo.GEOJSONADD = function()
  local geokey = Geo._getcommandkeys(Geo._TYPE_GEO)
  assert(#ARGV == 1, 'Expecting a single argument')
  local geojson = assert(cjson.decode(table.remove(ARGV, 1)), 'Expecting a valid JSON object')
  assert(geojson['type'], 'Expecting a valid GeoJSON object but got no type')
  assert(geojson['type'] == 'FeatureCollection', 'Expecting a FeatureCollection, got ' .. geojson['type'])
  assert(type(geojson['features']) == 'table', 'No features found in FeatureCollection')
  
  local geoadd = {}
  for i, v in ipairs(geojson['features']) do
    assert(v['type'], 'Expecting a valid GeoJSON object but got no type for feature')
    assert(v['type'] == 'Feature', 'Expecting Feature as type, got ' .. v['type'])
    assert(v['geometry'], 'No feature geometry')
    assert(v['geometry']['type'] == 'Point', 'Feature geometry must be a Point')
    local coords = assert(v['geometry']['coordinates'], 'No feature geometry coordinates provided')
    assert(type(coords) == 'table' and #coords == 2, 'Feature geometry coordinates must consist of only 2 values: longitude and latitude')
    geoadd[#geoadd+1] = assert(tonumber(coords[1], 'Longitude is NaN'))
    geoadd[#geoadd+1] = assert(tonumber(coords[2], 'Latitude is NaN'))
    local id = assert(v['properties']['id'], 'No id provided for member')
    table.insert(geoadd, id)
  end
  
  return redis.call('GEOADD', geokey, unpack(geoadd))
end

--- Encodes the output of GEO commands as GeoJSON object.
-- @return json The serialized GeoJSON object
Geo.GEOJSONENCODE = function()
  local geokey = Geo._getcommandkeys(Geo._TYPE_GEO)
  assert(#ARGV > 1, 'Expecting at least two arguments')
  local geocmd = table.remove(ARGV, 1):upper()
  local subcmds = {}
  for _, v in ipairs(ARGV) do
    local s = v:upper()
    if s == 'WITHCOORD' or s == 'WITHHASH' or s == 'WITHDIST' then
      subcmds[s] = true
    end
  end
  local geojson = {type = 'FeatureCollection', features = {}}
  
  local r = {}
  if geocmd == 'GEOPOS' or 'GEOHASH' then
    r = redis.call('GEOPOS', geokey, unpack(ARGV))
    for i, v in pairs(r) do
      if v then
        r[i] = { ARGV[i], v }
      else -- (nil)
        r[i] = nil
      end
    end
    if geocmd == 'GEOHASH' then
      local h = redis.call(geocmd, geokey, unpack(ARGV))
      for i, v in pairs(h) do
        if v then
          r[i] = { r[i][1], v, r[i][2] }
        end
      end      
    end
  elseif geocmd == 'GEORADIUS' or geocmd == 'GEORADIUSBYMEMBER' then
    assert(subcmds['WITHCOORD'], geocmd .. ' must be called with WITHCOORD')
    r = redis.call(geocmd, geokey, unpack(ARGV))
  elseif geocmd == 'GEOPOLYGON' then
    assert(subcmds['WITHCOORD'], geocmd .. ' must be called with WITHCOORD')
    -- return the geokey
    KEYS[#KEYS+1] = geokey
    local r = Geo.GEOPOLYGON()  
  else
    error('Unsupported command for GeoJSON encoding: ' .. geocmd)
  end
  
  for _, feature in pairs(r) do
    local jf =  { type = 'Feature',
                  geometry = {
                    type = 'Point',
                    coordinates = {}
                  },
                  properties = {}
                }
    jf['properties']['id'] = table.remove(feature, 1)
    if geocmd == 'GEOHASH' then
      jf['properties']['geohash'] = table.remove(feature, 1)
    end
    if subcmds['WITHDIST'] then
      jf['properties']['distance'] = table.remove(feature, 1)
    end
    if subcmds['WITHHASH'] then
      jf['properties']['rawhash'] = table.remove(feature, 1)
    end
    local coords = table.remove(feature, 1)
    jf['geometry']['coordinates'] = {tonumber(coords[1]), tonumber(coords[2])}
    table.insert(geojson['features'], jf)
  end
  
  return cjson.encode(geojson)
end

--- Adds members to an xyzset.
-- @return added The number of members added
Geo.GEOZADD = function()
  local geokey, zsetkey = Geo._getcommandkeys(Geo._TYPE_XYZ)
  -- ARGV's should be made of tuples (longitude, latitude, altitude, member)
  assert(#ARGV > 0 and #ARGV % 4 == 0, 'Expecting a positive multiple of four arguements')
  
  local geoadd, zadd = {}, {}
  while #ARGV > 0 do
    geoadd[#geoadd+1] = table.remove(ARGV, 1)
    geoadd[#geoadd+1] = table.remove(ARGV, 1)
    zadd[#zadd+1] = table.remove(ARGV, 1)
    zadd[#zadd+1] = table.remove(ARGV, 1)
    geoadd[#geoadd+1] = zadd[#zadd]
  end
  
  redis.call('ZADD', zsetkey, unpack(zadd))
  return redis.call('GEOADD', geokey, unpack(geoadd))
end

--- Delete a member.
-- @return deleted Number of deleted members
Geo.GEOZREM = function()
  local geokey, zsetkey = Geo._getcommandkeys(Geo._TYPE_XYZ)
  assert(#ARGV > 0, 'No members to remove provided')
  
  redis.call('ZREM', zsetkey, unpack(ARGV))
  return redis.call('ZREM', geokey, unpack(ARGV))
end

--- The positions of members.
-- @return members Table with members' positions
Geo.GEOZPOS = function()
  local geokey, zsetkey = Geo._getcommandkeys(Geo._TYPE_XYZ)
  assert(#ARGV > 0, 'No members to remove provided')
  
  local r = redis.call('GEOPOS', geokey, unpack(ARGV))
  for i, v in ipairs(r) do
    if v then -- not (nil)
      v[#v+1] = redis.call('ZSCORE', zsetkey, ARGV[i])
    end
  end
  
  return r
end

--- Upserts a member's position and publishes a notification.
-- @return upserted Number of upserted members
Geo.GEOTRACK = function()
  local geokey = Geo._getcommandkeys(Geo._TYPE_GEO)
  
    -- ARGV's should be made of tuples (longitude, latitude, member)
  assert(#ARGV > 0 and #ARGV % 3 == 0, 'Expecting a positive multiple of three arguements')
  
  local reply = 0
  while #ARGV > 0 do
    local lon, lat, member = table.remove(ARGV, 1), table.remove(ARGV, 1),table.remove(ARGV, 1)
    reply = reply + redis.call('GEOADD', geokey, lon, lat, member)
    redis.call('PUBLISH', '__geo:' .. geokey .. ':' .. member, lon .. ':' .. lat)
    end
  
  return reply
end

--- Provides comfort.
-- @return help The help
Geo.HELP = function()
  local reply = { }
  table.insert(reply, _NAME .. " (" .. _VERSION .. "): " .. _DESCRIPTION)
  local curr = 1
  local from, to = string.find(_USAGE, '\n', curr)
  while from do
    table.insert(reply, string.sub(_USAGE, curr, from-1))
    curr = to + 1
    from, to = string.find(_USAGE, '\n', curr)
  end
  table.insert(reply, string.sub(_USAGE, curr))
  return reply
end

-- "main"
assert(redis.call('COMMAND', 'INFO', 'GEOADD'), 'Redis GEO API is missing (are you using v3.2 or above?)')

local command_name = assert(table.remove(ARGV, 1), 'No command provided - try `help`')
command_name = command_name:upper()

local command = assert(Geo[command_name], 'Unknown command ' .. command_name)
return command()