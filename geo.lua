local _NAME = 'geo.lua'
local _VERSION = '0.1.6'
local _DESCRIPTION = 'A helper library for Redis geospatial indices'
local _COPYRIGHT = '2016 Itamar Haber, Redis Labs'
local _USAGE = [[

Call with ARGV[1] being one of the following commands:
  
  - GEO API completeness -
  GEODEL        - delete a member
  GEOBEARING    - initial and final bearing between members
  GEOPATHLEN    - length of a path between members
  
  - 2D geometries and polygon search -
  GEOMETRYADD   - upsert a geometry to a polyhash
  GEOMETRYGET   - returns coordinates and other stuff for polygons
  GEOMETRYFILER - search geoset inside a geometry
    
  - GeoJSON -
  GEOJSONADD    - upsert members to geoset from GeoJSON object
  GEOJSONENCODE - return GeoJSON object for these GEO commands:
                  GEOHASH, GEOPOS, GEORADIUS[BYMEMBER] and
                  GEOMETRYFILTER

  - xyzsets (longitude, latitude & altitude) -
  GEOZADD       - upsert member with altitude
  GEOZREM       - remove member
  GEOZPOS       - the 3d position of members
  
  - location updates (credit @mattsta) -
  GEOTRACK      - positional updates notifications

  help          - this text, for more information see the README file

]]

local Geo = {}      -- GEO library

-- private

-- Geospatial 2D Geometry
local Geometry = {}
Geometry.__index = Geometry

setmetatable(Geometry, {
              __call = function(cls, ...)
                return cls.new(...)
                end })

Geometry._TYPES = { 'Point',           -- TODO
                    'MultiPoint',      -- TODO
                    'LineString',      -- TODO 
                    'MultiLineString', -- TODO
                    'Polygon',
                    'MultiPolygon' }   -- TODO
Geometry._TENUM = {}
for i = 1, #Geometry._TYPES do
  Geometry._TENUM[Geometry._TYPES[i]:upper()] = i
  Geometry['_T' .. Geometry._TYPES[i]:upper()] = i
end

--- Calculates distance between two coordinates.
-- Just like calling GEODIST, but slower and of slightly different
-- accuracy.
-- @param lon1 The longitude of the 1st coordinate
-- @param lat1 The latitude of the 1st coordinate
-- @param lon2 The longitude of the 2nd coordinate
-- @param lat2 The latitude of the 2nd coordinate
-- @return distance The distance in meters
Geometry._distance = function (lon1, lat1, lon2, lat2)
  local R = 6372797.560856 -- Earth's, in meters
  local lon1r, lat1r, lon2r, lat2r = 
    math.rad(lon1), math.rad(lat1), math.rad(lon2), math.rad(lat2)
  local u = math.sin((lat2r - lat1r) / 2)
  local v = math.sin((lon2r - lon1r) / 2)
  return 2.0 * R * math.asin(math.sqrt(u * u + math.cos(lat1r) * math.cos(lat2r) * v * v))
end

--- Geometry constructor.
-- Creates a geometry object.
-- @param geomtype The geometry's type, optional
-- @param ... The geometry's geometries
-- @return self New Geometry object
Geometry.new = function(geomtype, ...)
  local self = setmetatable({}, Geometry)
  self.geomtype = geomtype
  self.coordn, self.coordx, self.coordy = {}, {}, {}
  self.meta = {}
  
  if #arg > 0 then
    if self.geomtype == Geometry._TPOLYGON then 
      -- A polygon's coordinates are given by one or more LineRings
      -- A LineRing is a LineString where the first and last vertices are identical
      -- The first and mandatory ring is the polygon's outer ring
      -- Any subsequent rings are considered holes, islands, and repeating...
            
      -- Polygon vertices are stored as two coordinate lists
      -- When there's more than one ring, O means the (0,0) and the two lists:
      --   begins with O
      --   rings are delimeted with O
      --   end with O
      self.coordx[#self.coordx+1], self.coordy[#self.coordy+1] = 0, 0
      for _, ring in ipairs(arg[1]) do
        local n = #ring / 2
        self.coordn[#self.coordn+1] = n
        for i = 1, n do  
          self.coordx[#self.coordx+1], self.coordy[#self.coordy+1] = ring[2*i-1], ring[2*i]
        end
        self.coordx[#self.coordx+1], self.coordy[#self.coordy+1] = 0, 0
      end
      
      -- the outer ring
      local op = 0                    -- outer perimeter
      local ov = self.coordn[1]       -- number of vertices
      local bbx1 = self.coordx[2]     -- bounding box
      local bby1 = self.coordy[2]
      local bbx2 = self.coordx[2]  
      local bby2 = self.coordy[2]
      local bbr = 0
      local bcx, bcy, bcr = 0, 0, 0   -- bounding circle
      -- traverse outer vertices
      for i = 2, 1 + ov do
        local ix, iy = self.coordx[i], self.coordy[i]
        local jx, jy = self.coordx[i+1], self.coordy[i+1]
        -- grow the outer perimeter
        op = op + Geometry._distance(ix, iy, jx, jy)
        -- add up for the averages
        bcx = bcx + ix
        bcy = bcy + iy
        -- adjust bounding box if needed
        if bbx1 > ix then
          bbx1 = ix
        elseif bbx2 < ix then
          bbx2 = ix
        end
        if bby1 > iy then
          bby1 = iy
        elseif bby2 < iy then
          bby2 = iy
        end            
      end
      bcx = bcx / (ov - 1)
      bcy = bcy / (ov - 1)
      bbr = Geometry._distance(bbx1, bby1, bbx2, bby2) / 2
  
      -- farthest point from the centroid is the radius
      for i = 2, 1 + ov do
        local d = Geometry._distance(bcx, bcy, self.coordx[i], self.coordy[i])
        if bcr < d then
          bcr = d
        end
      end
  
      -- lets not be too accurate
      bcr = math.ceil(bcr)
      bbr = math.ceil(bbr)
 
      self.meta = { op, ov, bcx, bcy, bcr, bbx1, bby1, bbx2, bby2, bbr }
    else
      error('Unknown argument(s) to for type')
    end
  end
  
  return self
end

--- Checks if a point is inside a polygon.
-- https://www.ecse.rpi.edu/~wrf/Research/Short_Notes/pnpoly.html
-- @param pt Point
-- @param po Polygon
-- @return boolean True if PIP
function Geometry:PNPOLY(x, y)
  local c = false
  -- don't think outside the box
  if self.meta[6]<=x and self.meta[8]>=x and self.meta[7]<=y and self.meta[9]>=y then
    
    local nvert = #self.coordy
    local vertx = self.coordx
    local verty = self.coordy
    local testx = x
    local testy = y
    local j = nvert
    
    for i = 1, nvert do
      if  ((verty[i]>testy) ~= (verty[j]>testy)) and
          testx < (vertx[j]-vertx[i]) * (testy-verty[i]) / (verty[j]-verty[i]) + vertx[i] then
        c = not c
      end
      j = i
    end
  end

  return c
end

--- Returns the bounding circle for a geometry.
-- @return Table three elements: x, y and radius
function Geometry:getBoundingCircle()
  -- TODO: error on `Point`
  return { self.meta[3], self.meta[4], self.meta[5] }
end

--- Returns the bounding box for a geometry.
-- return Table five elements: min x and y, max x and y, radius
function Geometry:getBoundingBox()
  -- TODO: error on `Point`
  return { self.meta[6], self.meta[7], self.meta[8], self.meta[9], self.meta[10] }
end

--- Returns the geometry's type name.
-- @return name The geometry's name
function Geometry:typeAsString()
  return Geometry._TYPES[self.geomtype]
end

--- Returns a table of geometry's coordinates.
-- Every geometry is a table, and in it every element is a vertex table.
-- @return coord The coordinates as a table for a RESP reply
function Geometry:coordAsRESP()
  local reply = {}

  local verti = 2
  for geomi, geomn in ipairs(self.coordn) do
    local r = {}
    local vertn = verti + geomn - 1
    for i = verti, vertn do
      r[#r+1] = { tostring(self.coordx[i]), tostring(self.coordy[i]) }
    end
    verti = vertn + 2
    reply[#reply+1] = r
  end
  
  return reply
end

--- Returns a table of the geometry's meta information.
-- @return meta The meta information
function Geometry:metaAsRESP(subcmds)
  local reply = {}
  
  if not subcmds or not subcmds['ANY'] then
    return
  end
  if self.geomtype == Geometry._TPOLYGON then  
    if subcmds['WITHPERIMETER'] then
      reply[#reply+1] = tostring(self.meta[1])
    end
    if subcmds['WITHBOX'] then
      local bbox = self:getBoundingBox()
      reply[#reply+1] = { { tostring(bbox[1]), tostring(bbox[2]) },
                          { tostring(bbox[3]), tostring(bbox[4]) },
                          bbox[5]}
    end
    if subcmds['WITHCIRCLE'] then
      local bcircle = self:getBoundingCircle()
      reply[#reply+1] = { { tostring(bcircle[1]), tostring(bcircle[2]) },
                          bcircle[3] }
    end
  end           
  
  if #reply > 0 then
    return reply
  else
    return
  end
end

--- Returns the msgpack-serialized geometry object.
-- @return string The serialized object
function Geometry:dump()
  local payload = {}
  payload[#payload+1] = self.geomtype
  payload[#payload+1] = self.coordn
  payload[#payload+1] = self.coordx
  payload[#payload+1] = self.coordy
  payload[#payload+1] = self.meta
  return cmsgpack.pack(payload)
end

--- Loads the geometry from its serialized form.
-- @param msgpack The serialized geometry
-- @return null
function Geometry:load(msgpack)
  local payload = cmsgpack.unpack(msgpack)
  self.geomtype = table.remove(payload, 1)
  self.coordn = table.remove(payload, 1)
  self.coordx = table.remove(payload, 1)
  self.coordy = table.remove(payload, 1)
  self.meta = table.remove(payload, 1)
end

-- Data structure type
Geo._TYPE_GEO = 1     -- regular geoset
Geo._TYPE_XYZ = 2     -- xyzset
Geo._TYPE_GEOM = 3    -- geomash

--- Keys validation.
-- Extract and validate types of keys for command
-- @param geotype The type of command
-- @return geoset|polyhash Key name
-- @return [azset]  Key name
Geo._getcommandkeys = function (geotype)
  
  local function asserttype(k, t)
    local r = redis.call('TYPE', k)
    assert(r['ok'] == t or r['ok'] == 'none', 'WRONGTYPE Operation against a key holding the wrong kind of value')
  end
  
  if geotype == Geo._TYPE_GEO then
    local geokey = assert(table.remove(KEYS, 1), 'No geoset key name provided')
    asserttype(geokey, 'zset')
    return geokey
  elseif geotype == Geo._TYPE_XYZ then
    local geokey = assert(table.remove(KEYS, 1), 'No geoset key name provided')
    asserttype(geokey, 'zset')
    local zsetkey = assert(table.remove(KEYS, 1), 'No altitude sorted set key name provided')
    asserttype(zsetkey, 'zset')
    return geokey, zsetkey
  elseif geotype == Geo._TYPE_GEOM then
    local geomkey = assert(table.remove(KEYS, 1), 'No geomash key name provided')
    asserttype(geomkey, 'hash')
    return geomkey
  end
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

--- Upserts a single geometry into a geomash.
-- TODO: support more geometries besides an unholey `Polygon`
-- TODO: support upsert of multiple geometries
-- @return upserted Number 0 if updated, 1 if added
Geo.GEOMETRYADD = function()
  local geomkey = Geo._getcommandkeys(Geo._TYPE_GEOM)
  local geomtype = assert(table.remove(ARGV, 1), 'Expecting a geometry type')
  geomtype = geomtype:upper()
  geomtype = assert(Geometry._TENUM[geomtype], 'Invalid geometry type')
  local id = assert(table.remove(ARGV, 1), 'Expecting a geometry id')
  
  assert(geomtype == Geometry._TPOLYGON, 'Sorry, atm only `POLYGON` geometry type is supported')
  assert(#ARGV > 7, 'Expecting at least 4 coordinates')
  assert(#ARGV % 2 == 0, 'Expecting an even number of arguments as coordinates')  
  assert(ARGV[1] == ARGV[#ARGV-1] and ARGV[2] == ARGV[#ARGV], 'The first and last vertices must be the identical')
  
  local coord = {}
  for i, v in ipairs(ARGV) do
    coord[#coord+1] = assert(tonumber(v), 'Expecting numbers as coordinates')
  end
  
  local geom = Geometry.new(Geometry._TPOLYGON, { coord })
  return redis.call('HSET', geomkey, id, geom:dump())
end

--- Returns geometries from a geomash.
-- @return vertices Table of vertices
Geo.GEOMETRYGET = function()
  local geomkey = Geo._getcommandkeys(Geo._TYPE_GEOM)
  local subcmds = { WITHPERIMETER = false,
                    WITHBOX = false,
                    WITHCIRCLE = false }
  assert(#ARGV > 0, 'Expecting at least one argument')
  for i = 1, math.min(3, #ARGV) do
    local s = ARGV[1]:upper()
    -- there are edge cases this will not cover but good enough
    if subcmds[s] ~= nil and not subcmds[s] then
      subcmds['ANY'] = true
      subcmds[s] = true
      table.remove(ARGV, 1)
    end
  end  
  
  assert(#ARGV > 0, 'Expecting at least one geometry id')
  
  local r = redis.call('HMGET', geomkey, unpack(ARGV))
  -- cast each geometry in the reply to RESP 
  for ri, rv in ipairs(r) do
    if rv then -- i.e. not (nil), meaning v is a geometry
      local geom = Geometry.new()
      geom:load(rv)
      local rep = {} 
      rep[#rep+1] = geom:typeAsString()
      rep[#rep+1] = geom:coordAsRESP()
      local meta = geom:metaAsRESP(subcmds)
      if meta then rep[#rep+1]= meta end
      r[ri] = rep
    end
  end
  
  return r
end

--- Performs a search for members inside a geometry.
-- @return members Table with the members
Geo.GEOMETRYFILTER = function()
  local geokey = Geo._getcommandkeys(Geo._TYPE_GEO)
  local geomkey = Geo._getcommandkeys(Geo._TYPE_GEOM)
  
  assert(#ARGV > 0, 'Expecting at least one argument')
  local subcmds = { WITHCOORD = false,
                    STORE = false }
  for i = 1, math.min(2, #ARGV) do
    local s = ARGV[1]:upper()
    -- there are edge cases this will not cover but good enough
    if subcmds[s] ~= nil and not subcmds[s] then
      subcmds[s] = true
      table.remove(ARGV, 1)
    end
  end

  local targetkey
  if subcmds['STORE'] then
    -- TODO: this currently triggers an ambiguous error 
    targetkey = Geo._getcommandkeys(Geo._TYPE_GEO)
  end
  
  assert(#ARGV == 1, 'Expecting a single geometry id')
  local r = assert(redis.call('HGET', geomkey, ARGV[1]), 'Geometry id not found: ' .. ARGV[1])
  local geom = Geometry:new()
  geom:load(r)
  assert(geom.geomtype == Geometry._TPOLYGON, 'Unsupported (TODO) filter geometry: ' .. geom:typeAsString())
  
  local bbox = geom:getBoundingBox()
  local members = redis.call('GEORADIUS', geokey, (bbox[1] + bbox[3]) / 2, (bbox[2] + bbox[4]) / 2, bbox[5], 'm', 'WITHCOORD')
  local reply, geoadd = {}
  for i, v in ipairs(members) do
    if geom:PNPOLY(tonumber(v[2][1]), tonumber(v[2][2])) then
      if subcmds['WITHCOORD'] then
        reply[#reply+1] = v
      else
        reply[#reply+1] = v[1]
      end
      if subcmds['STORE'] then
        geoadd[#geoadd+1] = v[2][1]
        geoadd[#geoadd+1] = v[2][2]
        geoadd[#geoadd+1] = v[1]
      end  
    end
  end
  
  if subcmds['STORE'] then
    return redis.call('GEOADD', targetkey, unpack(geoadd))
  else
    return reply
  end
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
    local coord = assert(v['geometry']['coordinates'], 'No feature geometry coordinates provided')
    assert(type(coord) == 'table' and #coord > 1, 'Feature geometry coordinates must consist at least 2 values: longitude and latitude')
    geoadd[#geoadd+1] = coord[1]
    geoadd[#geoadd+1] = coord[2]
    local id = assert(v['properties']['id'], 'No id provided for member')
    table.insert(geoadd, id)
  end
  
  return redis.call('GEOADD', geokey, unpack(geoadd))
end

--- Adds polygons in a GeoJSON object to a polyhash.
-- Note: only the LineRing of the polygon.
-- @return added The number of members added
Geo.GEOJSONPOLYADD = function()
  local polykey = Geo._getcommandkeys(Geo._TYPE_GEOM)
  assert(#ARGV == 1, 'Expecting a single argument')
  local geojson = assert(cjson.decode(table.remove(ARGV, 1)), 'Expecting a valid JSON object')
  assert(geojson['type'], 'Expecting a valid GeoJSON object but got no type')
  assert(geojson['type'] == 'FeatureCollection', 'Expecting a FeatureCollection, got ' .. geojson['type'])
  assert(type(geojson['features']) == 'table', 'No features found in FeatureCollection')
  
  local polyadd = {}
  for i, v in ipairs(geojson['features']) do
    assert(v['type'], 'Expecting a valid GeoJSON object but got no type for feature')
    assert(v['type'] == 'Feature', 'Expecting Feature as type, got ' .. v['type'])
    local id = assert(v['properties']['id'], 'No id provided for member')    
    assert(v['geometry'], 'No feature geometry')
    assert(v['geometry']['type'] == 'Polygon', 'Feature geometry must be a Polygon, got ' .. v['geometry']['type'])
    local coord = assert(v['geometry']['coordinates'][1], 'No feature geometry coordinates provided')
    assert(type(coord) == 'table' and #coord > 2, 'Feature geometry coordinates must have at least 3 coordinates ' .. id)
    local enc = Geo._polygonencode(coord)
    polyadd[#polyadd+1] = { id, enc }
  end
  
  return redis.call('HMSET', polykey, unpack(polyadd))
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
  if geocmd == 'GEOPOS' or geocmd == 'GEOHASH' then
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
  elseif geocmd == 'GEOMETRYFILTER' then
    assert(subcmds['WITHCOORD'], geocmd .. ' must be called with WITHCOORD')
    -- return the geokey
    KEYS[#KEYS+1] = geokey
    -- return the geomash
    KEYS[#KEYS+1] = table.remove(ARGV, 1)
    r = Geo.GEOMETRYFILTER()
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
