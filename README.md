geo.lua - helper library for Redis geospatial indices :earth_africa:
===

This is a Lua library containing miscellaneous geospatial helper routines for use with [Redis]. It requires the [Redis GEO API], available from v3.2.

In broad strokes, the library provides:
* [Polygon searches](#GEOMETRYFILTER) on geoset members
* Navigational information such as [bearing](#GEOBEARING) and [path length](#GEOPATHLEN)
* GeoJSON [decoding](#GEOJSONADD) and [encoding](#GEOJSONENCODE)
* A playground for testing experimental geospatial APIs

The library is strictly :straight_ruler: metric, sorry.
![Metric system adoption worldwide](https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Metric_system_adoption_map.svg/2000px-Metric_system_adoption_map.svg.png)

Using geo.lua
---
The library is an ordinary Redis Lua script - use [`EVAL`] or [`EVALSHA`] to call it. The following example demonstrates usage from the prompt:

````Bash
$ redis-cli SCRIPT LOAD "$(cat geo.lua)"
"fd07..."
$ redis-cli EVALSHA fd07... 0 help
 1) "geo.lua (0.1.5): A helper library for Redis geospatial indices"
 ...
````

Library API
---

### GEO API completeness

<a name="GEOBEARING"></a>
#### GEOBEARING KEYS[1] geoset ARGV[2] member1 3] member2
Return the initial and final bearing between two members.
> Time complexity: O(1).

For information about the calculation refer to  http://mathforum.org/library/drmath/view/55417.html.

**Return:** Array reply, specifically the initial and final bearings.

<a name="GEOPATHLEN"></a>
#### GEOPATHLEN KEYS[1] geoset ARGV[2] member [...]
The length of a path between members.
> Time complexity: O(N) where N is the number of members.

**Note:** This is basically a variadic form for [`GEODIST`].

**Return:** String reply, specifically the length in meters.

<a name="GEODEL"></a>
#### GEODEL KEYS[1] geoset ARGV[2] member [...]
Delete members from a geoset.
> Time complexity: O(M*log(N)) with N being the number of elements in the geoset and M the number of elements to be removed.

This command is an alias for [`ZREM`] to disprove the [GEO incompleteness theorem](https://twitter.com/monadic/status/690889597866393600). Technically it should be called `GEOREM` however.

**Return:** Integer reply, specifically the number of members actually deleted.

### 2D geometries and polygon search
Redis' geosets allow [storing](http://redis.io/commands/geoadd) (and [querying](http://redis.io/commands/georadius)) of `Point` (2D, x/y, longitude & latitude) geometries. Other geometries can be stored serialized (using [msgpack](http://msgpack.org/index.html)) in a Redis Hash data structure - the geomash. The geoset and the geomash are used for storing geometries in the following manner:

| Geometry             | Storage | `GEOMETRYADD` | `GEOMETRYGET` | `GEOMETRYFILTER` | `GEOJSONADD`
| :---                 | :---    | :---:         | :---:         | :---:            | :---:
| `Point`              | geoset  | N/A           | N/A           | No               | Yes
| `Polygon`            | geomash | Yes           | Yes           | Yes              | Yes
| `MultiPolygon`       | geomash | TODO          | TODO          | TODO             | RODO
| `MultiPoint`         | TODO    | TODO          | TODO          | No               | TODO
| `LineString`         | TODO    | TODO          | TODO          | TODO             | TODO
| `MultiLineString`    | TODO    | TODO          | TODO          | TODO             | TODO
| `GeometryCollection` | TODO    | TODO          | TODO          | TODO             | TODO

<a name="GEOMETRYADD"></a>
#### GEOMETRYADD KEYS[1] geomash ARGV[2] geometry-type 3] id 4..] <geometry data>
Upsert a single geometry to a geomash.
> Time complexity:

`ARGV[4]` and above describe the geometry. Depending on the geometry's type:
  * `POLYGON` - each pair of ARGVs (e.g., 4 and 5, 6 and 7, ...) represent the coordinates of a vertex (longitude and latitude). A minimum of 4 vertices are required to define a polygon, with the first and last vertices being equal (a LineRing).

**Note:** there is no `GEOMETYREM`, use [`HDEL`](http://redis.io/commands/hdel) instead.

**Return:** Integer reply, specifically 0 if updated and 1 if added.

<a name="GEOMETRYGET"></a>
#### GEOMETRYGET KEYS[1] geomash ARGV[a] [WITHPERIMETER|WITHBOX|WITHCIRCLE] [...] ARGV[2] id  [...]
Returns geometries' coordinates.
> Time complexity:

The reply can be enriched with meta data about the geometry. The following sub-commands are supported, depending on the type of geometry.
  * `WITHPERIMETER`: For `Polygon`, The total length of edges
  * `WITHBOX`: The bounding box of the geometry
  * `WITHCIRCLE`: The bounding circle of the geometry

**Return:** Array reply, specifically:`
  * The geometry's type
  * The geometry's coordinates
  * When called with `WITHPERIMETER`, the total length of edges
  * When called with `WITHBOX`, the minimum and maximum coordinates of the bounding box, as well as it's bounding circle's radius
  * When called with `WITHCIRCLE`, the center coordinates and radius of bounding circle

<a name="GEOMETRYFILTER"></a>
#### GEOMETRYFILTER KEYS[1] geoset 2] geomash a] [target] ARGV[a] [STORE|WITHCOORD] [...] ARGV[2] id
Search for geoset members inside a geometry.
> Time complexity:

This command performs a [`GEORADIUS`] search that contains the geometry's bounding box. The results are then filtered using a Point-In-Polygon (PIP) algorithm ([source](https://www.ecse.rpi.edu/~wrf/Research/Short_Notes/pnpoly.html#The C Code)).

The following sub-commands are supported:
 * `STORE`: Stores the search results in the target geoset
 * `WITHCOORD`: Returns the members' coordinates as well

**Return:** Array reply, specifically the members and their coordinates (if called with `WITHCOORD`). When the `STORE` directive is used, the reply is an Integer that indicates the number of members that were upserted to the target geoset.

### GeoJSON
A minimal implementation of the [spec's v1.0](http://geojson.org/geojson-spec.html) for decoding and encoding geoset and geomash members from/to `FeatureCollection`s and `Feature`s.

<a name="GEOJSONADD"></a>
#### GEOJSONADD KEYS[1] geoset 2] geomash ARGV[1] GeoJSON
> Time complexity: O(log(N)) for each feature in the GeoJSON object, where N is the number of members in the geoset.

Upsert points to the geoset, other geometries to the geomash. A valid input GeoJSON object must be `FeatureCollection`. Each `Feature`'s type must be `Point` or a `Polygon`, and the feature's properties must include a member named `id`.

**Return:** Integer reply, specifically the number of features upserted.

<a name="GEOJSONENCODE"></a>
#### GEOJSONENCODE KEYS[1] geoset ARGV[2] <GEO command> 3] [arg] [...]
> Time complexity: depends on the GEO command and its arguments.

Encodes the reply of GEO commands as a GeoJSON object. Valid GEO commands are:
* [`GEOHASH`]
* [`GEOPOS`]
* [`GEORADIUS`] and [`GEORADIUSBYMEMBER`]
* [`GEOMETRYFILTER`]

**Return:** String, specifically the reply of the GEO command encoded as a GeoJSON object.

### Location updates
Implements a real-time location tracking mechanism. Inspired by [Matt Stancliff @mattsta](https://matt.sh/redis-geo).

<a name="GEOTRACK"></a>
#### GEOTRACK KEYS[1] geoset ARGV[2] longitude 3] latitude 4] member [...]
> Time complexity: O(log(N)+M+P) for each item added, where N is the number of elements in the geoset, M is the number of clients subscribed to the receiving channel and P is the total number of subscribed patterns (by any client).

[`GEOADD`]s a member and [`PUBLISH`]s on channel `__geo:<geoset>:<member>` a message with the format of `<longitude>:<latitude>`.

Clients can track updates made to a specific member by subscribing to that member's channel (i.e. [`SUBSCRIBE`]`__geo:<geoset>:<member>`) or to all members updates (i.e. [`PSUBSCRIBE`]`__geo:<geoset>:*`).

**Return:** Integer reply, specifically the number of members upserted.

### xyzsets
Redis' geospatial indices only encode the longitude and latitude of members with no regard to their altitude. An xyzset uses two sorted sets, one as geoset and the other for storing altitudes.

<a name="GEOZADD"></a>
#### GEOZADD KEYS[1] geoset 2] azset ARGV[2] logitude 3] latitude 4] altitude 5] member [...]
> Time complexity: O(log(N)) for each item added, where N is the number of elements in the geoset.

Upsert members. Altitude is given as meters above (or below) sea level.

**Return:** Integer reply, specifically the number of members upserted.

<a name="GEOZREM"></a>
#### GEOZREM KEYS[1] geoset 2] azset ARGV[2] member [...]
> Time complexity: O(M*log(N)) with N being the number of elements in the geoset and M the number of elements to be removed.

Remove members.

**Return:** Integer reply, specifically the number of members actually deleted.

<a name="GEOZPOS"></a>  
#### GEOZPOS KEYS[1] geoset 2] azset ARGV[2] member [...]
> Time complexity: O(log(N)) for each member requested, where N is the number of elements in the geoset.

The position of members in 3D.

**Return:** Array reply, specifically the members and their positions.

#### TODO: GEOZDIST
Returns the distance between members.

#### TODO: GEOZCYLINDER
Perform cylinder-bound search.

#### TODO: GEOZCYLINDERBYMEMBER
Perform cylinder-bound search by member (a 20 characters command!).

#### TODO: GEOZSPHERE
Useful for directing air traffic and impact research (bombs, comets).

#### TODO: GEOZCONE
Good for comparing :alien: sightings vis a vis :cow: abduction data.

### Motility
Storing each member's vector in an additional hash data structure, where the field is the member's name and the value is the serialized vector (bearing & velocity).

#### TODO: GEOMADD KEYS[1] geoset 2] vector hash ARGV[2] longitude 3] latitude 4] bearing 5] velocity 6] member [...]

Upsert members. Bearing given in degrees, velocity in meters/second.

#### TODO: GEOMREM KEYS[1] geoset 2] vector hash ARGV[2] member [...]
Remove members.

#### TODO: GEOMPOSWHEN KEYS[1] geoset 2] vector hash ARGV[2] seconds 3] member [...]
Project members position in future or past.

#### TODO: GEOMMEETWHENWHERE KEYS[1] geoset 2] vector hash ARGV[2] member1 3] member2
Help solving basic math exercises.

License
---
3-Clause BSD.

Contributing
---

You're encouraged to contribute to the open source geo.lua project. There are two ways you can do so.

### Issues

If you encounter an issue while using the geo.lua library, please report it at the project's issues tracker. Feature suggestions are also welcome.

### Pull request

Code contributions to the geo.lua project can be made using pull requests. To submit a pull request:

1. Fork this project.
2. Make and commit your changes.
3. Submit your changes as a pull request.

[Redis]: http://redis.io
[Redis GEO API]: (http://redis.io/commands#geo)
[`GEOADD`]: (http://redis.io/commands/geoadd)
[`GEODIST`]: (http://redis.io/commands/geodist)
[`GEOHASH`]: (http://redis.io/commands/geohash)
[`GEOPOS`]: (http://redis.io/commands/geopos)
[`GEORADIUS`]: (http://redis.io/commands/georadius)
[`GEORADIUSBYMEMBER`]: (http://redis.io/commands/georadiusbymember)
[`EVAL`]: (http://redis.io/commands/eval)
[`EVALSHA`]: (http://redis.io/commands/evalsha)
[`PUBLISH`]: (http://redis.io/commands/publish)
[`SUBSCRIBE`]: (http://redis.io/commands/subscribe)
[`PSUBSCRIBE`]: (http://redis.io/commands/psubscribe)
[`ZREM`]: (http://redis.io/commands/zrem)
