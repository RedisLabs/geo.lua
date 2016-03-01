[0.1.6] - 2016-
===
Adds spatial geometries, increases similarity to LOLCODE.

**IMPORTANT:** This release breaks the API.

 * New commands: `GEOMETRYADD`, `GEOMETRYGET`
 * `GEOPOLYGON` is now `GEOMETRYFILTER`. It:
  * Accepts a geometry as a filter (right now, only polygons)
  * Supports the `STORE` subcommand
 * Polygon search optimization

[0.1.5] - 2016-02-20 
===
Initial release.

[0.1.6]: https://github.com/RedisLabs/geo.lua/releases/tag/0.1.6
[0.1.5]: https://github.com/RedisLabs/geo.lua/releases/tag/0.1.5