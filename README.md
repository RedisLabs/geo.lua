geo.lua - helper library for Redis geospatial indices
===

This is a Lua library containing miscellaneous geospatial helper routines for use with [Redis](http://redis.io). It requires the [GEO API](http://redis.io/commands#geo), available from v3.2.

In broad strokes, the library provides:
* [Polygon search](#GEOPOLYGON) on geoset members
* Navigational information such as [bearing](#GEOBEARING) and [path length](#GEOPATHLEN)
* GeoJSON [decoding](#GEOJSONADD) and [encoding](#GEOJSONENCODE)
* A playground for testing experimental geospatial APIs

The library is strictly metric, sorry.
![Metric system adoption worldwide](https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Metric_system_adoption_map.svg/2000px-Metric_system_adoption_map.svg.png)

Using geo.lua
---
The library is an ordinary Redis Lua script -  use[`EVAL`](http://redis.io/commands/eval) or [`EVALSHA`](http://redis.io/commands/evalsha) to call it. The following example demonstrates usage from the prompt:

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

**Return:** String reply, specifically the length in meters.

<a name="GEOPOLYGON"></a>
#### GEOPOLYGON KEYS[1] geoset ARGV[a] [WITHCOORD] ARGV[2] longitude1 3] latitude1 4] longitude2 5] latitude2 6] longitude3 7] latitude3 [...]
> Time complexity: O(V+N+log(M)+N*V) where V is the number of vertices in the polygon, N is the number of elements inside the bounding box of the circular area delimited by center and radius of the polygon's bounding circle and M is the number of items inside the index.

Search for members inside a simple polygon described by 3 or more coordinates. This command determines the polygon's center and farthest vertex from it to perform a [`GEORADIUS`](http://redis.io/commands/georadius). The results are then filtered using a Point-In-Polygon (PIP) algorithm ([source](http://alienryderflex.com/polygon/)) that provides indeterminate results for members on the edges.

**Return:** Array reply, specifically the members in the polygon.

<a name="GEODEL"></a>
#### GEODEL KEYS[1] geoset ARGV[2] member [...]
Delete members from a geoset.
> Time complexity: O(M*log(N)) with N being the number of elements in the geoset and M the number of elements to be removed.

This command is an alias for [`ZREM`](http://redis.io/commands/zrem) to disprove the [GEO incompleteness theorem](https://twitter.com/monadic/status/690889597866393600).  Technically it should be called `GEOREM` however.

**Return:** Integer reply, specifically the number of members actually deleted.

### GeoJSON
A minimal implementation of the [spec's v1.0](http://geojson.org/geojson-spec.html) for decoding and encoding geoset members from/to `FeatureCollection`s and `Feature`s.

<a name="GEOJSONADD"></a>
#### GEOJSONADD KEYS[1] geoset ARGV[1] GeoJSON
> Time complexity: O(log(N)) for each feature in the GeoJSON object, where N is the number of members in the geoset.

Add members to geoset. A valid input GeoJSON object must be `FeatureCollection`. Each Feature must be a Point and its properties must include an member named `id`.

**Return:** Integer reply, specifically the number of features upserted.

<a name="GEOJSONENCODE"></a>
#### GEOJSONENCODE KEYS[1] geoset ARGV[2] <GEO command> 3] [arg] [...]
> Time complexity: depends on the GEO command and its arguments.

Encodes the reply of GEO commands as a GeoJSON object. Valid GEO commands are:
* [GEOHASH](http://redis.io/commands/geohash)
* [GEOPOS](http://redis.io/commands/geopos)
* [GEORADIUS](http://redis.io/commands/georadius) and [GEORADIUSBYMEMBER](http://redis.io/commands/georadiusbymember)
* [GEOPOLYGON](#GEOPOLYGON)

**Return:** String, specifically the reply of the GEO command encoded as a GeoJSON object.

### Location updates
Implements a real-time location tracking mechanism. Inspired by [Matt Stancliff @mattsta](https://matt.sh/redis-geo).

<a name="GEOTRACK"></a>
#### GEOTRACK KEYS[1] geoset ARGV[2] longitude 3] latitude 4] member [...]
> Time complexity: O(log(N)+M+P) for each item added, where N is the number of elements in the geoset, M is the number of clients subscribed to the receiving channel and P is the total number of subscribed patterns (by any client).

[`GEOADD`](http://redis.io/commands/geoadd)s a member and [`PUBLISH`](http://redis.io/commands/publish)s on channel `__geo:<geoset>:<member>` a message with the format of `<longitude>:<latitude>`.

Clients can track updates made to a specific member by subscribing to that member's channel (i.e. [`SUBSCRIBE __geo:<geoset>:<member>`](http://redis.io/commands/subscribe)) or to all members updates (i.e. [`PSUBSCRIBE __geo:<geoset>:*`](http://redis.io/commands/psubscribe)).

**Return:** Integer reply, specifically the number of members upserted.

### xyzsets
Redis' geospatial indices only encode the longitude and latitude of members with no regard to their altitude. An xyzset uses two sorted sets, one as geoset and the other for storing altitudes.

<a name="GEOZADD"></a>
#### GEOZADD KEYS[1] geoset 2] azset ARGV[2] logitude 3] latitude 4] altitude 5] member [...]
> Time complexity: O(log(N)) for each item added, where N is the number of elements in the geoset.

Add members. Altitude is given as meters above (or below) sea level.

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

#### [TBD] GEOZDIST
Returns the distance between members.

#### [TBD] GEOZCYLINDER
Perform cylinder-bound search.

#### [TBD] GEOZCYLINDERBYMEMBER
Perform cylinder-bound search by member (20-characters command!).

#### [TBD] GEOZSPHERE
Useful for directing air traffic and impact research (bombs, comets).

#### [TBD] GEOZCONE
Good for comparing UFO sightings vis a vis cow abduction data.

### Motility
Storing each member's vector in an additional hash data structure, where the field is the member's name and the value is the serialized vector (bearing & velocity).

#### [TBD] GEOMADD KEYS[1] geoset 2] vector hash ARGV[2] longitude 3] latitude 4] bearing 5] velocity 6] member [...]

Add members. Bearing given in degrees, velocity in meters/second.

#### [TBD] GEOMREM KEYS[1] geoset 2] vector hash ARGV[2] member [...]
Remove members.

#### [TBD] GEOMPOSWHEN KEYS[1] geoset 2] vector hash ARGV[2] seconds 3] member [...]
Project members position in future or past.

#### [TBD] GEOMMEETWHENWHERE KEYS[1] geoset 2] vector hash ARGV[2] member1 3] member2
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
