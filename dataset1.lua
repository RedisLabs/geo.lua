local data = {
  '15.0074779', '37.4908267', 'RL@Catania',
  '34.84076', '32.10942', 'RL@TLV',
  '-122.0678325', '37.3775256', 'RL@MV',
  '34.8380433', '32.1098095', 'Hudson'
}

local alt = {
  '97', 'RL@Catania',
  '18', 'RL@TLV',
  '38', 'RL@MV',
  '18', 'Hudson'
}  

redis.call('DEL', unpack(KEYS))
redis.call('GEOADD', KEYS[1], unpack(data))
redis.call('ZADD', KEYS[2], unpack(data))