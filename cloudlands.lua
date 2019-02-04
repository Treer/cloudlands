local DEBUG                  = false -- dev logging
local DEBUG_GEOMETRIC        = false -- turn off noise from island shapes
local LOWLAND_BIOMES         = false -- If true then determine an island's biome using the biome at altitude "LOWLAND_BIOME_ALTITUDE"
local LOWLAND_BIOME_ALTITUDE = 10    -- Higher than beaches, lower than mountains (See LOWLAND_BIOMES)
local ALTITUDE               = 200   -- average altitude of islands
local ALTITUDE_AMPLITUDE     = 40    -- rough island altitude variance (plus or minus)
local EDDYFIELD_SIZE         = 1     -- size of the "eddy field-lines" that smaller islands follow
local GENERATE_ORES          = false -- set to true for island core stone to contain patches of dirt and sand etc.
local VINE_COVERAGE          = 0.3   -- set to 0 to turn off vines
local REEF_RARITY            = 0.015 -- Chance of a viable island having a reef or atoll
local ISLANDS_SEED           = 1000  -- You only need to change this if you want to try different island layouts without changing the map seed

-- Some lists of known node aliases (any nodes which can't be found won't be used).
local NODENAMES_STONE  = {"mapgen_stone",        "mcl_core:stone",        "default:stone"}
local NODENAMES_WATER  = {"mapgen_water_source", "mcl_core:water_source", "default:water_source"}
local NODENAMES_ICE    = {"mapgen_ice",          "mcl_core:ice",          "pedology:ice_white", "default:ice"}
local NODENAMES_GRAVEL = {"mapgen_gravel",       "mcl_core:gravel",       "default:gravel"}
local NODENAMES_SILT   = {"mapgen_silt", "default:silt", "aotearoa:silt", "darkage:silt", "mapgen_sand", "mcl_core:sand", "default:sand"} -- silt isn't a thing yet, but perhaps one day it will be. Use sand for the bottom of ponds in the meantime.
local NODENAMES_VINES  = {"mcl_core:vine", "vines:side_end"}
local MODNAME          = minetest.get_current_modname()
local VINES_REQUIRED_HUMIDITY    = 45
local VINES_REQUIRED_TEMPERATURE = 40
local ICE_REQUIRED_TEMPERATURE   =  5

local coreTypes = {
  {
    territorySize     = 200,
    coresPerTerritory = 3,
    radiusMax         = 96,
    depthMax          = 50,
    thicknessMax      = 8,
    frequency         = 0.1,
    pondWallBuffer    = 0.03,
    requiresNexus     = true,
    exclusive         = false
  },
  {
    territorySize     = 60,
    coresPerTerritory = 1,
    radiusMax         = 40,
    depthMax          = 40,
    thicknessMax      = 4,
    frequency         = 0.1,
    pondWallBuffer    = 0.06,
    requiresNexus     = false,
    exclusive         = true
  },
  {
    territorySize     = 30,
    coresPerTerritory = 3,
    radiusMax         = 16,
    depthMax          = 16,
    thicknessMax      = 2,
    frequency         = 0.1,
    pondWallBuffer    = 0.11, -- larger values will make ponds smaller and further from island edges, so it should be as low as you can get it without the ponds leaking over the edge. A small leak-prone island is at (3160, -2360) on seed 1
    requiresNexus     = false,
    exclusive         = true
  }
}

if minetest.get_biome_data == nil then error(MODNAME .. " requires Minetest v5.0 or greater", 0) end

local function fromSettings(settings_name, default_value)
  local result
  if type(default_value) == "number" then 
    result = tonumber(minetest.settings:get(settings_name) or default_value)
  elseif type(default_value) == "boolean" then 
    result = minetest.settings:get_bool(settings_name, default_value)
  end
  return result
end
-- override any settings with user-specified values before these values are needed
ALTITUDE             = fromSettings(MODNAME .. "_altitude",           ALTITUDE)
ALTITUDE_AMPLITUDE   = fromSettings(MODNAME .. "_altitude_amplitude", ALTITUDE_AMPLITUDE)
GENERATE_ORES        = fromSettings(MODNAME .. "_generate_ores",      GENERATE_ORES)
VINE_COVERAGE        = fromSettings(MODNAME .. "_vine_coverage",      VINE_COVERAGE * 100) / 100
LOWLAND_BIOMES       = fromSettings(MODNAME .. "_use_lowland_biomes", LOWLAND_BIOMES)

local noiseparams_eddyField = {
	offset      = -1,
	scale       = 2,
	spread      = {x = 350 * EDDYFIELD_SIZE, y = 350 * EDDYFIELD_SIZE, z= 350 * EDDYFIELD_SIZE},
	seed        = ISLANDS_SEED, --WARNING! minetest.get_perlin() will add the server map's seed to this value
	octaves     = 2,
	persistence = 0.7,
	lacunarity  = 2.0,
}
local noiseparams_heightMap = {
	offset      = 0,
	scale       = ALTITUDE_AMPLITUDE,
	spread      = {x = 160, y = 160, z= 160},
	seed        = ISLANDS_SEED, --WARNING! minetest.get_perlin() will add the server map's seed to this value
	octaves     = 3,
	persistence = 0.5,
	lacunarity  = 2.0,
}
local DENSITY_OFFSET = 0.7
local noiseparams_density = {
	offset      = DENSITY_OFFSET,
	scale       = .3,
	spread      = {x = 25, y = 25, z= 25},
	seed        = 1000, --WARNING! minetest.get_perlin() will add the server map's seed to this value
	octaves     = 4,
	persistence = 0.5,
	lacunarity  = 2.0,
}
local SURFACEMAP_OFFSET = 0.5
local noiseparams_surfaceMap = {
	offset      = SURFACEMAP_OFFSET,
	scale       = .5,
	spread      = {x = 40, y = 40, z= 40},
	seed        = ISLANDS_SEED, --WARNING! minetest.get_perlin() will add the server map's seed to this value
	octaves     = 4,
	persistence = 0.5,
	lacunarity  = 2.0,
}
local noiseparams_skyReef = {
	offset      = .3,
	scale       = .9,
	spread      = {x = 3, y = 3, z= 3},
	seed        = 1000,
	octaves     = 2,
	persistence = 0.5,
	lacunarity  = 2.0,
}

local noiseAngle = -15 --degrees to rotate eddyField noise, so that the vertical and horizontal tendencies are off-axis
local ROTATE_COS = math.cos(math.rad(noiseAngle))
local ROTATE_SIN = math.sin(math.rad(noiseAngle))

local noise_eddyField
local noise_heightMap
local noise_density
local noise_surfaceMap
local noise_skyReef

local worldSeed
local nodeId_ignore   = minetest.CONTENT_IGNORE
local nodeId_air
local nodeId_stone
local nodeId_water
local nodeId_ice
local nodeId_silt
local nodeId_gravel
local nodeId_vine
local nodeName_vine

local REQUIRED_DENSITY = 0.4

local randomNumbers = {} -- array of 0-255 random numbers with values between 0 and 1 (inclusive)
local data          = {} -- reuse the massive VoxelManip memory buffers instead of creating on every on_generate()
local surfaceData   = {} -- reuse the massive VoxelManip memory buffers instead of creating on every on_generate()
local biomes        = {}

-- optional region specified in settings to restrict islands too
local region_restrictions = false
local region_min_x, region_min_z, region_max_x, region_max_z = -32000, -32000, 32000, 32000

-- optional biomes specified in settings to restrict islands too
local limit_to_biomes = nil
local limit_to_biomes_altitude = nil

--[[==============================
           Math functions
    ==============================]]--

-- avoid having to perform table lookups each time a common math function is invoked
local math_min, math_max, math_floor, math_sqrt, math_cos, math_abs, math_pow, PI = math.min, math.max, math.floor, math.sqrt, math.cos, math.abs, math.pow, math.pi

local function clip(value, minValue, maxValue)
  if value <= minValue then
    return minValue
  elseif value >= maxValue then
    return maxValue
  else
    return value
  end
end

local function round(value)
  return math_floor(0.5 + value)
end

--[[==============================
           Interop functions
    ==============================]]--

local interop = {}
-- returns the id of the first name in the list that resolves to a node id, or nodeId_ignore if not found
interop.find_node_id = function (node_aliases)
  local result
  for _,alias in ipairs(node_aliases) do
    result = minetest.get_content_id(alias)
    --if DEBUG then minetest.log("info", alias .. " returned " .. result) end

    if result == nodeId_ignore then
      -- registered_aliases isn't documented - not sure I'm using it right
      local altAlias = minetest.registered_aliases[alias]
      if altAlias ~= nil then result = minetest.get_content_id(altAlias) end
    end
    if result ~= nodeId_ignore then return result end
  end
  return result  
end

interop.register_clone = function(node_name)
  local node = minetest.registered_nodes[node_name]
  if node == nil then
    minetest.log("error", "cannot clone " .. node_name)
    return nil
  else 
    local cloneName = MODNAME .. ":" .. string.gsub(node.name, ":", "_")
    if minetest.registered_nodes[cloneName] == nil then
      minetest.log("info", "attempting to register: " .. cloneName)
      local clone = {}
      for key, value in pairs(node) do clone.key = value end
      clone.name = cloneName
      minetest.register_node(cloneName, clone)
      --minetest.log("info", cloneName .. " id: " .. minetest.get_content_id(cloneName))
      --minetest.log("info", cloneName .. ": " .. dump(minetest.registered_nodes[cloneName]))
    end
    return cloneName
  end
end


--[[==============================
       Initialization and Mapgen
    ==============================]]--

local function init_mapgen()
  -- invoke get_perlin() here, since it can't be invoked before the environment
  -- is created because it uses the world's seed value.
  noise_eddyField  = minetest.get_perlin(noiseparams_eddyField)
  noise_heightMap  = minetest.get_perlin(noiseparams_heightMap)
  noise_density    = minetest.get_perlin(noiseparams_density)
  noise_surfaceMap = minetest.get_perlin(noiseparams_surfaceMap)
  noise_skyReef    = minetest.get_perlin(noiseparams_skyReef)

  local prng = PcgRandom(122456 + ISLANDS_SEED)
  for i = 0,255 do randomNumbers[i] = prng:next(0, 0x10000) / 0x10000 end

  for k,v in pairs(minetest.registered_biomes) do
    biomes[minetest.get_biome_id(k)] = v;
  end
  if DEBUG then minetest.log("info", "registered biomes: " .. dump(biomes)) end

  nodeId_air      = minetest.get_content_id("air")

  nodeId_stone    = interop.find_node_id(NODENAMES_STONE)
  nodeId_water    = interop.find_node_id(NODENAMES_WATER)
  nodeId_ice      = interop.find_node_id(NODENAMES_ICE)
  nodeId_silt     = interop.find_node_id(NODENAMES_SILT)
  nodeId_gravel   = interop.find_node_id(NODENAMES_GRAVEL)
  nodeId_vine     = interop.find_node_id(NODENAMES_VINES)
  nodeName_vine   = minetest.get_name_from_content_id(nodeId_vine)

  local regionRectStr = minetest.settings:get(MODNAME .. "_limit_rect")
  if type(regionRectStr) == "string" then 
    local minXStr, minZStr, maxXStr, maxZStr = string.match(regionRectStr, '(-?[%d%.]+)[,%s]+(-?[%d%.]+)[,%s]+(-?[%d%.]+)[,%s]+(-?[%d%.]+)')
    if minXStr ~= nil then 
      local minX, minZ, maxX, maxZ = tonumber(minXStr), tonumber(minZStr), tonumber(maxXStr), tonumber(maxZStr)
      if minX ~= nil and maxX ~= nil and minX < maxX then
        region_min_x, region_max_x = minX, maxX
      end
      if minZ ~= nil and maxZ ~= nil and minZ < maxZ then
        region_min_z, region_max_z = minZ, maxZ
      end
    end
  end

  local limitToBiomesStr = minetest.settings:get(MODNAME .. "_limit_biome")
  if type(limitToBiomesStr) == "string" and string.len(limitToBiomesStr) > 0 then
    limit_to_biomes = limitToBiomesStr:lower()
  end
  limit_to_biomes_altitude = tonumber(minetest.settings:get(MODNAME .. "_limit_biome_altitude"))

  region_restrictions =
    region_min_x > -32000 or region_min_z > -32000 
    or region_max_x < 32000 or region_max_z < 32000
    or limit_to_biomes ~= nil
end

-- Updates coreList to include all cores of type coreType within the given bounds
local function addCores(coreList, coreType, x1, z1, x2, z2)

  for z = math_floor(z1 / coreType.territorySize), math_floor(z2 / coreType.territorySize) do
    for x = math_floor(x1 / coreType.territorySize), math_floor(x2 / coreType.territorySize) do

      -- Use a known PRNG implementation, to make life easier for Amidstest
      local prng = PcgRandom(
        x * 8973896 +
        z * 7467838 +
        worldSeed + 8438 + ISLANDS_SEED
      )

      local coresInTerritory = {}

      for i = 1, coreType.coresPerTerritory do
        local coreX = x * coreType.territorySize + prng:next(0, coreType.territorySize - 1)
        local coreZ = z * coreType.territorySize + prng:next(0, coreType.territorySize - 1)

        -- there's strong vertical and horizontal tendency in 2-octave noise,
        -- so rotate it a little to avoid it lining up with the world axis.
        local noiseX = ROTATE_COS * coreX - ROTATE_SIN * coreZ
        local noiseZ = ROTATE_SIN * coreX + ROTATE_COS * coreZ
        local eddyField = noise_eddyField:get2d({x = noiseX, y = noiseZ})

        if (math_abs(eddyField) < coreType.frequency) then

          local nexusConditionMet = not coreType.requiresNexus
          if not nexusConditionMet then
            -- A 'nexus' is a made up name for a place where the eddyField is flat.
            -- There are often many 'field lines' leading out from a nexus.
            -- Like a saddle in the perlin noise the height "coreType.frequency"
            local eddyField_orthA = noise_eddyField:get2d({x = noiseX + 2, y = noiseZ})
            local eddyField_orthB = noise_eddyField:get2d({x = noiseX, y = noiseZ + 2})
            if math_abs(eddyField - eddyField_orthA) + math_abs(eddyField - eddyField_orthB) < 0.02 then
              nexusConditionMet = true
            end
          end

          if nexusConditionMet then
            local radius     = (coreType.radiusMax + prng:next(0, coreType.radiusMax) * 2) / 3 -- give a 33%/66% weighting split between max-radius and random
            local depth      = (coreType.depthMax + prng:next(0, coreType.depthMax) * 2) / 2
            local thickness  = prng:next(0, coreType.thicknessMax)


            if coreX >= x1 and coreX < x2 and coreZ >= z1 and coreZ < z2 then

              local spaceConditionMet = not coreType.exclusive
              if not spaceConditionMet then
                -- see if any other cores occupy this space, and if so then
                -- either deny the core, or raise it
                spaceConditionMet = true
                local minDistSquared = radius * radius * .7

                for _,core in ipairs(coreList) do
                  if core.type.radiusMax == coreType.radiusMax then
                    -- We've reached the cores of the current type. We can't exclude based on all
                    -- cores of the same type as we can't be sure neighboring territories will have been generated.
                    break
                  end
                  if (core.x - coreX)*(core.x - coreX) + (core.z - coreZ)*(core.z - coreZ) <= minDistSquared + core.radius * core.radius then
                    spaceConditionMet = false
                    break
                  end
                end
                if spaceConditionMet then
                  for _,core in ipairs(coresInTerritory) do
                    -- We can assume all cores of the current type are being generated in this territory,
                    -- so we can exclude the core if it overlaps one already in this territory.
                    if (core.x - coreX)*(core.x - coreX) + (core.z - coreZ)*(core.z - coreZ) <= minDistSquared + core.radius * core.radius then
                      spaceConditionMet = false
                      break
                    end
                  end
                end;
              end

              if spaceConditionMet then
                -- all conditions met, we've located a new island core
                --minetest.log("Adding core "..x..","..y..","..z..","..radius);
                local y = round(noise_heightMap:get2d({x = coreX, y = coreZ}))
                local newCore = {
                  x         = coreX,
                  y         = y,
                  z         = coreZ,
                  radius    = radius,
                  thickness = thickness,
                  depth     = depth,
                  type      = coreType,
                }
                coreList[#coreList + 1] = newCore
                coresInTerritory[#coreList + 1] = newCore
              end

            else
              -- We didn't test coreX,coreZ against x1,z1,x2,z2 immediately and save all
              -- that extra work, as that would break the determinism of the prng calls.
              -- i.e. if the area was approached from a different direction then a
              -- territory might end up with a different list of cores.
              -- TODO: filter earlier but advance prng?
            end
          end
        end
      end
    end
  end
end


-- removes any islands that fall outside region restrictions specified in the options
local function removeUnwantedIslands(coreList)

  local testBiome = limit_to_biomes ~= nil
  local get_biome_name = nil
  if testBiome then
    -- minetest.get_biome_name() was added in March 2018, we'll ignore the 
    -- limit_to_biomes option on versions of Minetest that predate this
    get_biome_name = minetest.get_biome_name
    testBiome = get_biome_name ~= nil
    if get_biome_name == nil then
      minetest.log("warning", MODNAME .. " ignoring " .. MODNAME .. "_limit_biome option as Minetest API version too early to support get_biome_name()") 
      limit_to_biomes = nil
    end
  end

  for i = #coreList, 1, -1 do
    local core = coreList[i]
    local coreX = core.x
    local coreZ = core.z

    if coreX < region_min_x or coreX > region_max_x or coreZ < region_min_z or coreZ > region_max_z then
      table.remove(coreList, i)

    elseif testBiome then
      local biomeAltitude
      if (limit_to_biomes_altitude == nil) then biomeAltitude = ALTITUDE + core.y else biomeAltitude = limit_to_biomes_altitude end

      local biomeName = get_biome_name(minetest.get_biome_data({x = coreX, y = biomeAltitude, z = coreZ}).biome)
      if not string.match(limit_to_biomes, biomeName:lower()) then
        table.remove(coreList, i)
      end
    end
  end
end


-- gets an array of all cores which may intersect the draw distance
local function getCores(minp, maxp)
  local result = {}

  for _,coreType in pairs(coreTypes) do
    addCores(
      result,
      coreType,
      minp.x - coreType.radiusMax,
      minp.z - coreType.radiusMax,
      maxp.x + coreType.radiusMax,
      maxp.z + coreType.radiusMax
    )
  end

  -- remove islands only after cores have all generated to avoid the restriction 
  -- settings from rearranging islands.
  if region_restrictions then removeUnwantedIslands(result) end

  return result;
end

local function setCoreBiomeData(core)
  local pos = {x = core.x, y = ALTITUDE + core.y, z = core.z}
  if LOWLAND_BIOMES then pos.y = LOWLAND_BIOME_ALTITUDE end
  core.biomeId     = minetest.get_biome_data(pos).biome
  core.biome       = biomes[core.biomeId]
  core.temperature = minetest.get_heat(pos)
  core.humidity    = minetest.get_humidity(pos)

  if core.temperature == nil then core.temperature = 50 end
  if core.humidity    == nil then core.humidity    = 50 end
end

local function addDetail_vines(decoration_list, core, data, area, minp, maxp)

  if VINE_COVERAGE > 0 and nodeId_vine ~= nodeId_ignore then

    local y = ALTITUDE + core.y
    if y >= minp.y and y <= maxp.y then
      -- if core.biome is nil then renderCores() never rendered it, which means it
      -- doesn't instersect this draw region.
      if core.biome ~= nil and core.humidity >= VINES_REQUIRED_HUMIDITY and core.temperature >= VINES_REQUIRED_TEMPERATURE then

        local nodeId_top
        local nodeId_filler
        local nodeId_stoneBase
        local nodeId_dust
        if core.biome.node_top    == nil then nodeId_top       = nodeId_stone  else nodeId_top       = minetest.get_content_id(core.biome.node_top)    end
        if core.biome.node_filler == nil then nodeId_filler    = nodeId_stone  else nodeId_filler    = minetest.get_content_id(core.biome.node_filler) end
        if core.biome.node_stone  == nil then nodeId_stoneBase = nodeId_stone  else nodeId_stoneBase = minetest.get_content_id(core.biome.node_stone)  end
        if core.biome.node_dust   == nil then nodeId_dust      = nodeId_stone  else nodeId_dust      = minetest.get_content_id(core.biome.node_dust)   end

        local function isIsland(nodeId)
          return (nodeId == nodeId_filler    or nodeId == nodeId_top 
               or nodeId == nodeId_stoneBase or nodeId == nodeId_dust
               or nodeId == nodeId_silt)
        end

        local function findHighestNodeFace(y, solidIndex, emptyIndex)
          -- return the highest y value (or maxp.y) where solidIndex is part of an island
          -- and emptyIndex is not
          local yOffset = 1
          while y + yOffset <= maxp.y and isIsland(data[solidIndex + yOffset * area.ystride]) and not isIsland(data[emptyIndex + yOffset * area.ystride]) do
            yOffset = yOffset + 1
          end
          return y + yOffset - 1
        end

        local radius = round(core.radius)
        local xCropped = math_min(maxp.x, math_max(minp.x, core.x))
        local zStart = math_max(minp.z, core.z - radius)
        local vi = area:index(xCropped, y, zStart)

        for z = 0, math_min(maxp.z, core.z + radius) - zStart do
          local searchIndex = vi + z * area.zstride
          if isIsland(data[searchIndex]) then

            -- add vines to east face
            if randomNumbers[(zStart + z + y) % 256] <= VINE_COVERAGE then
              for x = xCropped + 1, maxp.x do 
                if not isIsland(data[searchIndex + 1]) then
                  local yhighest = findHighestNodeFace(y, searchIndex, searchIndex + 1)
                  decoration_list[#decoration_list + 1] = {pos={x=x, y=yhighest, z= zStart + z}, node={name = nodeName_vine, param2 = 3}}
                  break 
                end
                searchIndex = searchIndex + 1
              end
            end
            -- add vines to west face
            if randomNumbers[(zStart + z + y + 128) % 256] <= VINE_COVERAGE then
              searchIndex = vi + z * area.zstride
              for x = xCropped - 1, minp.x, -1 do 
                if not isIsland(data[searchIndex - 1]) then
                  local yhighest = findHighestNodeFace(y, searchIndex, searchIndex - 1)
                  decoration_list[#decoration_list + 1] = {pos={x=x, y=yhighest, z= zStart + z}, node={name = nodeName_vine, param2 = 2}}
                  break 
                end
                searchIndex = searchIndex - 1
              end
            end
          end
        end

        local zCropped = math_min(maxp.z, math_max(minp.z, core.z))
        local xStart = math_max(minp.x, core.x - radius)
        local vi = area:index(xStart, y, zCropped)
        local zstride = area.zstride

        for x = 0, math_min(maxp.x, core.x + radius) - xStart do
          local searchIndex = vi + x
          if isIsland(data[searchIndex]) then

            -- add vines to north face (make it like moss - grows better on the north side)
            if randomNumbers[(xStart + x + y) % 256] <= (VINE_COVERAGE * 1.2) then
              for z = zCropped + 1, maxp.z do 
                if not isIsland(data[searchIndex + zstride]) then
                  local yhighest = findHighestNodeFace(y, searchIndex, searchIndex + zstride)
                  decoration_list[#decoration_list + 1] = {pos={x=xStart + x, y=yhighest, z=z}, node={name = nodeName_vine, param2 = 5}}
                  break 
                end
                searchIndex = searchIndex + zstride
              end
            end
            -- add vines to south face (make it like moss - grows better on the north side)
            if randomNumbers[(xStart + x + y + 128) % 256] <= (VINE_COVERAGE * 0.8) then
              searchIndex = vi + x
              for z = zCropped - 1, minp.z, -1 do 
                if not isIsland(data[searchIndex - zstride]) then
                  local yhighest = findHighestNodeFace(y, searchIndex, searchIndex - zstride)
                  decoration_list[#decoration_list + 1] = {pos={x=xStart + x, y=yhighest, z=z}, node={name = nodeName_vine, param2 = 4}}
                  break 
                end
                searchIndex = searchIndex - zstride
              end
            end
          end
        end        

      end
    end
  end
end


-- A rare formation of rocks circling or crowning an island
-- returns true if voxels were changed
local function addDetail_skyReef(decoration_list, core, data, area, minp, maxp)

  local coreTop          = ALTITUDE + core.y
  local reefAltitude     = math_floor(coreTop - 1 - core.thickness / 2)
  local reefMaxHeight    = 12
  local reefMaxUnderhang = 4

  if (maxp.y < reefAltitude - reefMaxUnderhang) or (minp.y > reefAltitude + reefMaxHeight) then
    --no reef here
    return false
  end

  local isReef  = core.radius < core.type.radiusMax * 0.4 -- a reef can't extend beyond radiusMax, so needs a small island
  local isAtoll = core.radius > core.type.radiusMax * 0.8
  if not (isReef or isAtoll) then return false end

  local fastHash = 3
  fastHash = (37 * fastHash) + core.x
  fastHash = (37 * fastHash) + core.z
  fastHash = (37 * fastHash) + math_floor(core.radius)
  fastHash = (37 * fastHash) + math_floor(core.depth)
  if ISLANDS_SEED ~= 1000 then fastHash = (37 * fastHash) + ISLANDS_SEED end
  local rarityAdj = 1
  if core.type.requiresNexus and isAtoll then rarityAdj = 4 end -- humongous islands are very rare, and look good as a atoll
  if (REEF_RARITY * rarityAdj * 1000) < math_floor((math_abs(fastHash)) % 1000) then return false end

  local coreX = core.x --save doing a table lookup in the loop
  local coreZ = core.z --save doing a table lookup in the loop
  
  -- Use a known PRNG implementation
  local prng = PcgRandom(
    coreX * 8973896 +
    coreZ * 7467838 +
    worldSeed + 32564
  )

  local reefUnderhang
  local reefOuterRadius = math_floor(core.type.radiusMax)
  local reefInnerRadius = prng:next(core.type.radiusMax * 0.5, core.type.radiusMax * 0.7)
  local reefWidth       = reefOuterRadius - reefInnerRadius
  local noiseOffset     = 0  

  if isReef then
    reefMaxHeight   = round((core.thickness + 4) / 2)
    reefUnderhang   = round(reefMaxHeight / 2)
    noiseOffset     = -0.1
  end
  if isAtoll then
    -- a crown attached to the island
    reefOuterRadius = math_floor(core.radius * 0.8)
    reefWidth       = math_max(4, math_floor(core.radius * 0.15))
    reefInnerRadius = reefOuterRadius - reefWidth
    reefUnderhang   = 0
    if maxp.y < reefAltitude - reefUnderhang then return end -- no atoll here
  end

  local reefHalfWidth           = reefWidth / 2
  local reefMiddleRadius        = (reefInnerRadius + reefOuterRadius) / 2
  local reefOuterRadiusSquared  = reefOuterRadius  * reefOuterRadius
  local reefInnerRadiusSquared  = reefInnerRadius  * reefInnerRadius
  local reefMiddleRadiusSquared = reefMiddleRadius * reefMiddleRadius
  local reefHalfWidthSquared    = reefHalfWidth    * reefHalfWidth

  -- get the biome details for this core
  local nodeId_first
  local nodeId_second  
  local nodeId_top
  local nodeId_filler
  if core.biome == nil then setCoreBiomeData(core) end -- We can't assume the core biome has already been resolved, core might not have been big enough to enter the draw region
  if core.biome.node_top    == nil then nodeId_top    = nodeId_stone  else nodeId_top       = minetest.get_content_id(core.biome.node_top)    end
  if core.biome.node_filler == nil then nodeId_filler = nodeId_stone  else nodeId_filler    = minetest.get_content_id(core.biome.node_filler) end
  if core.biome.node_dust   ~= nil then 
    nodeId_first  = minetest.get_content_id(core.biome.node_dust)
    nodeId_second = nodeId_top
  else
    nodeId_first  = nodeId_top
    nodeId_second = nodeId_filler
  end

  local zStart  = round(math_max(core.z - reefOuterRadius, minp.z))
  local zStop   = round(math_min(core.z + reefOuterRadius, maxp.z))
  local xStart  = round(math_max(core.x - reefOuterRadius, minp.x))
  local xStop   = round(math_min(core.x + reefOuterRadius, maxp.x))
  local yCenter = math_min(math_max(reefAltitude, minp.y), maxp.y)
  local pos = {}

  local dataBufferIndex = area:index(xStart, yCenter, zStart)
  local vi = -1
  for z = zStart, zStop do
    local zDistSquared = (z - coreZ) * (z - coreZ)
    pos.y = z
    for x = xStart, xStop do
      local distanceSquared = (x - coreX) * (x - coreX) + zDistSquared
      if distanceSquared < reefOuterRadiusSquared and distanceSquared > reefInnerRadiusSquared then
        pos.x = x
        local offsetEase = math_abs(distanceSquared - reefMiddleRadiusSquared) / reefHalfWidthSquared
        local fineNoise = noise_skyReef:get2d(pos)
        local reefNoise = (noiseOffset* offsetEase) + fineNoise + 0.2 * noise_surfaceMap:get2d(pos)

        if (reefNoise > 0) then 
          local distance = math_sqrt(distanceSquared)
          local ease = 1 - math_abs(distance - reefMiddleRadius) / reefHalfWidth
          local yStart = math_max(math_floor(reefAltitude - ease * fineNoise * reefUnderhang), minp.y)
          local yStop  = math_min(math_floor(reefAltitude + ease * reefNoise * reefMaxHeight), maxp.y)

          for y = yStart, yStop do
            vi = dataBufferIndex + (y - yCenter) * area.ystride
            if data[vi] == nodeId_air then 
              if y == yStop then 
                data[vi] = nodeId_first
              elseif y == yStop - 1 then 
                data[vi] = nodeId_second
              else 
                data[vi] = nodeId_filler
              end
            end
            surfaceData[vi] = nodeId_air --prevent plants growing inside atolls
          end
        end
      end
      dataBufferIndex = dataBufferIndex + 1
    end
    dataBufferIndex = dataBufferIndex + area.zstride - (xStop - xStart + 1)
  end

  return vi >= 0
end


------------------------------------------------------------------------------
--  Functions needed for secrets (hiding in the middle of mapgen code)
------------------------------------------------------------------------------

-- will be minified with https://mothereff.in/lua-minifier

local function rot19(s)
  -- use rot13.com set to rot 7 to encode

  if type(s) == "table" then
    for k,v in ipairs(s) do s[k] = rot19(v) end
    return s
  else
    --return (s:gsub("%a", function(c) c=c:byte() return string.char(c+(c%32<14 and 13 or -13)) end))
    return (s:gsub("%a", function(c) c=c:byte() return string.char(c + (c % 32 < 8 and 19 or -7)) end))
  end
end

if minetest.get_modpath("default") then
  -- the crack texture is probably available
  local nodeName_standinCobweb = MODNAME .. rot19(":jvidli") -- ":cobweb" 
  minetest.register_node(
    nodeName_standinCobweb, 
    {
      tiles = {
        -- [Ab]Use the crack texture to avoid needing to include a cobweb texture and exposing that the mod contains secrets
        "crack_anylength.png^[verticalframe:5:4^[brighten"
      },
      description=rot19("Jvidli"),
      groups = {snappy = 3, liquid = 3, flammable = 3, not_in_creative_inventory = 1},
      drawtype = "plantlike",
      walkable = false,
      liquid_viscosity = 8,
      liquidtype = "source",
      liquid_alternative_flowing = nodeName_standinCobweb,
      liquid_alternative_source  = nodeName_standinCobweb,
      liquid_renewable = false,
      liquid_range = 0,
      sunlight_propagates = true,
      paramtype = "light"
    }
  )
end
local nodeName_egg = rot19("zljyla:mvzzpspglk_lnn") -- ":secret:fossilized_egg"
local eggTextureName = rot19("klmhbsa_qbunslslhclz.wun") -- called "default_jungleleaves.png" in default/Voxelgarden/MineClone2
if minetest.get_modpath("ethereal") ~= nil then eggTextureName = rot19("laolylhs_myvza_slhclz.wun") end -- called "ethereal_frost_leaves.png" in ethereal
minetest.register_node(
  ":"..nodeName_egg, 
  {
    tiles = {
      -- [Ab]Use a leaf texture to avoid needing to include an egg texture and exposing that the mod contains secrets      
      eggTextureName.."^[colorize:#280040E0^[noalpha"
    },
    description=rot19("Mvzzpspglk Lnn"), --"Fossilized Egg"
    --drop = "secret:fossilized_egg",
    groups = {oddly_breakable_by_hand = 3, not_in_creative_inventory = 1},
    drawtype = "nodebox",
    paramtype = "light",
    node_box = {
      type = "fixed",
      fixed = {
        {-0.066666, -0.5,      -0.066666, 0.066666, 0.5,     0.066666}, -- column1
        {-0.133333, -0.476667, -0.133333, 0.133333, 0.42,    0.133333}, -- column2
        {-0.2,      -0.435,    -0.2,      0.2,      0.31,    0.2     }, -- column3
        {-0.2,      -0.36,     -0.28,     0.2,      0.16667, 0.28    }, -- side1
        {-0.28,     -0.36,     -0.2,      0.28,     0.16667, 0.2     }  -- side2          
      }
    }
  }
)
local nodeId_egg        = minetest.get_content_id(nodeName_egg)
local nodeId_airStandIn = minetest.get_content_id(interop.register_clone("air"))

-- defer assigning the following until all mods are loaded
local nodeId_bed_top
local nodeId_bed_bottom
local nodeId_torch
local nodeId_chest
local nodeId_bookshelf
local nodeId_junk
local nodeId_anvil
local nodeId_workbench
local nodeId_cobweb
local nodeName_bookshelf
local isMineCloneBookshelf

local function addDetail_secrets__shhh_dont_tell_people(decoration_list, core, data, area, minp, maxp)

  -- if core.biome is nil then renderCores() never rendered it, which means it
  -- doesn't instersect this draw region.
  if core.biome ~= nil and core.radius > 18 and core.depth > 20  and core.radius + core.depth > 60 then 

    local territoryX = math_floor(core.x / core.type.territorySize)
    local territoryZ = math_floor(core.z / core.type.territorySize)
    local isPolarOutpost = (core.temperature <= 5) and (core.x % 3 == 0) and noise_surfaceMap:get2d({x = core.x, y = core.z - 8}) >= 0 --make sure steps aren't under a pond
    local isAncientBurrow = core.humidity >= 60 and core.temperature >= 50

    -- only allow a checkerboard pattern of territories to help keep the secrets
    -- spread out, rather than bunching up too much with climate
    if ((territoryX + territoryZ) % 2 == 0) and (isPolarOutpost or isAncientBurrow) then 

      local burrowRadius = 7
      local burrowHeight = 5
      local burrowDepth = 12
      local burrowFloor = ALTITUDE + core.y - burrowDepth
      local radiusSquared = burrowRadius * burrowRadius

      local function carve(originp, destp, pattern, height, floorId, floorDistance)      

        local direction = vector.direction(originp, destp)
        local vineSearchDirection = {}
        if direction.x > 0 then vineSearchDirection.x = -1 else vineSearchDirection.x = 1 end
        if direction.z > 0 then vineSearchDirection.z = -1 else vineSearchDirection.z = 1 end

        local vinePlacements = {}      
        local function placeVine(vi, pos, only_place_on_nodeId)
          if data[vi] == nodeId_air then
            local faces = {}
            local facing

            local function vineCanGrowOnIt(node_id) 
              return node_id ~= nodeId_air and node_id ~= nodeId_airStandIn and (node_id == only_place_on_nodeId or only_place_on_nodeId == nil)
            end
            if vineCanGrowOnIt(data[vi + vineSearchDirection.x]) and pos.x + vineSearchDirection.x >= minp.x and pos.x + vineSearchDirection.x <= maxp.x then
              if vineSearchDirection.x > 0 then facing = 2 else facing = 3 end
              faces[#faces + 1] = {solid_vi = vi + vineSearchDirection.x, facing = facing}
            end
            if vineCanGrowOnIt(data[vi + vineSearchDirection.z * area.zstride]) and pos.z + vineSearchDirection.z >= minp.z and pos.z + vineSearchDirection.z <= maxp.z then
              if vineSearchDirection.z > 0 then facing = 4 else facing = 5 end
              faces[#faces + 1] = {solid_vi = vi + vineSearchDirection.z * area.zstride, facing = facing}
            end

            local faceInfo = nil
            if #faces == 1 then
              faceInfo = faces[1]
            elseif #faces == 2 then
              local ratio = math.abs(direction.x) / (math.abs(direction.x) + math.abs(direction.z))
              if randomNumbers[(pos.x + pos.y + pos.z) % 256] <= ratio then faceInfo = faces[1] else faceInfo = faces[2] end
            end
            if faceInfo ~= nil 
              and (only_place_on_nodeId == nil or only_place_on_nodeId == data[faceInfo.solid_vi]) 
              and (data[faceInfo.solid_vi] ~= nodeId_airStandIn) then
              -- find the highest y value (or maxp.y) where solid_vi is solid
              -- and vi is not
              local solid_vi = faceInfo.solid_vi
              local yOffset = 1
              while (pos.y + yOffset <= maxp.y + 1)
                    and (data[solid_vi + yOffset * area.ystride] ~= nodeId_air)
                    and (data[vi + yOffset * area.ystride] == nodeId_air)
                    and (only_place_on_nodeId == nil or only_place_on_nodeId == data[solid_vi + yOffset * area.ystride]) do
                yOffset = yOffset + 1
              end

              -- defer final vine placement until all nodes have been carved
              vinePlacements[#vinePlacements + 1] = function(decoration_list)
                -- retest that the vine is still going in air and still attached to a solid node
                local solidNode = data[solid_vi + (yOffset - 1) * area.ystride]
                if solidNode ~= nodeId_airStandIn and solidNode ~= nodeId_air and data[vi] == nodeId_air then 
                  decoration_list[#decoration_list + 1] = {pos={x=pos.x, y=pos.y + yOffset - 1, z=pos.z}, node={name = nodeName_vine, param2 = faceInfo.facing}}
                end
              end
            end
          end
        end

        local stampedIndexes = {}
        local function stamp(pos, pattern, height, node_id, isAir_callback)
          local callbackClosures = {}
          local index = -1
          for y = pos.y, pos.y + height - 1 do
            if y >= minp.y and y <= maxp.y then
              if index == -1 then index = area:index(pos.x, y, pos.z) else index = index + area.ystride end
              for _,voxel in ipairs(pattern) do
                local x = pos.x + voxel.x
                local z = pos.z + voxel.z
                if x >= minp.x and x <= maxp.x and z >= minp.z and z <= maxp.z then
                  local vi = index + voxel.x + voxel.z * area.zstride
                  if data[vi] == nodeId_air then
                    if isAir_callback ~= nil then 
                      callbackClosures[#callbackClosures + 1] = function() isAir_callback(pos, vi, x, y, z) end
                    end
                  else 
                    data[vi] = node_id
                    stampedIndexes[#stampedIndexes + 1] = vi
                  end                
                end
              end            
            end
          end
          for _,callback in ipairs(callbackClosures) do callback() end
        end
      
        local function excavate(pos, add_floor, add_vines, add_cobwebs)

          local function onAirNode(stampPos, node_vi, node_x, node_y, node_z)              
            if node_y > stampPos.y and node_y + 1 <= maxp.y then
              -- place vines above the entrance, for concealment
              placeVine(node_vi + area.ystride, {x=node_x, y=node_y + 1, z=node_z})
            else
              -- place vines on the floor, to allow explorers to climb to the burrow
              placeVine(node_vi, {x=node_x, y=node_y, z=node_z}, floorId)
            end
          end

          local onAirNodeCallback = onAirNode
          local fill = nodeId_airStandIn
          if not add_vines or nodeId_vine == nodeId_ignore then onAirNodeCallback = nil end
          if add_cobwebs and nodeId_cobweb ~= nodeId_ignore then fill = nodeId_cobweb end

          stamp(pos, pattern, height, fill, onAirNodeCallback)
          if add_floor and floorId ~= nil then
            stamp({x=pos.x, y=pos.y - 1, z=pos.z}, pattern, 1, floorId, onAirNodeCallback)
          end
        end

        local addVines = core.humidity >= VINES_REQUIRED_HUMIDITY and core.temperature >= VINES_REQUIRED_TEMPERATURE
        if floorDistance == nil then floorDistance = 0 end
        local distance = round(vector.distance(originp, destp))
        local step = vector.divide(vector.subtract(destp, originp), distance)

        local pos    = vector.new(originp)
        local newPos = vector.new(originp)

        excavate(originp, 0 >= floorDistance, false)
        for i = 1, distance do
          newPos.x = newPos.x + step.x 
          if round(newPos.x) ~= pos.x then
            pos.x = round(newPos.x)
            excavate(pos, i >= floorDistance, addVines, i <= floorDistance - 1 and i >= floorDistance - 2)
          end
          newPos.y = newPos.y + step.y
          if round(newPos.y) ~= pos.y then
            pos.y = round(newPos.y)
            excavate(pos, i >= floorDistance, addVines, i <= floorDistance - 1 and i >= floorDistance - 2)
          end
          newPos.z = newPos.z + step.z
          if round(newPos.z) ~= pos.z then
            pos.z = round(newPos.z)
            excavate(pos, i >= floorDistance, addVines, i <= floorDistance - 1 and i >= floorDistance - 2)
          end
        end

        -- We only place vines after entire burrow entrance has been carved, to avoid placing
        -- vines on blocks which will later be removed.
        for _,vineFunction in ipairs(vinePlacements) do vineFunction(decoration_list) end

        -- Replace airStandIn with real air.
        -- This two-pass process was neccessary because the vine placing algorithm used
        -- the presense of air to determine if a rock was facing outside and should have a vine.
        -- Single-pass solutions result in vines inside the tunnel (where I'd rather overgrowth spawned)
        for _,stampedIndex in ipairs(stampedIndexes) do 
          if data[stampedIndex] == nodeId_airStandIn then 
            data[stampedIndex] = nodeId_air
            surfaceData[stampedIndex] = nodeId_air
          end
        end

      end

      local function placeNode(x, y, z, node_id)
        if (x >= minp.x and x <= maxp.x and z >= minp.z and z <= maxp.z and y >= minp.y and y <= maxp.y) then
          data[area:index(x, y, z)] = node_id
        end
      end

      local function posInBounds(pos) 
        return pos.x >= minp.x and pos.x <= maxp.x and pos.z >= minp.z and pos.z <= maxp.z and pos.y >= minp.y and pos.y <= maxp.y
      end
        
      local zStart = math_max(core.z - burrowRadius, minp.z)
      local xStart = math_max(core.x - burrowRadius, minp.x)
      local xStop  = math_min(core.x + burrowRadius, maxp.x)
      local yStart = math_max(burrowFloor, minp.y)

      -- dig burrow
      local dataBufferIndex = area:index(xStart, yStart, zStart)
      for z = zStart, math_min(core.z + burrowRadius, maxp.z) do
        for x = xStart, xStop do
          local distanceSquared = (x - core.x)*(x - core.x) + (z - core.z)*(z - core.z)
          if distanceSquared < radiusSquared then
            local horz_easing = 1 - distanceSquared / radiusSquared          
            for y = math_max(minp.y, burrowFloor + math_floor(1.4 - horz_easing)), math_min(maxp.y, burrowFloor + 1 + math_min(burrowHeight - 1, math_floor(0.8 + burrowHeight * horz_easing))) do
              data[dataBufferIndex + (y - yStart) * area.ystride] = nodeId_air
            end                
          end
          dataBufferIndex = dataBufferIndex + 1      
        end
        dataBufferIndex = dataBufferIndex + area.zstride - (xStop - xStart + 1)
      end

      local floorId
      if core.biome.node_top == nil then floorId = nil else floorId = minetest.get_content_id(core.biome.node_top) end
    
      if isAncientBurrow then 
        -- island overlaps can only happen at territory edges when a coreType has exclusive=true, so
        -- angle the burrow entrance toward the center of the terrority to avoid any overlapping islands.
        local territoryCenter = vector.new(
          core.type.territorySize * math.floor(core.x / core.type.territorySize) + math.floor(0.5 + core.type.territorySize / 2),
          burrowFloor,
          core.type.territorySize * math.floor(core.z / core.type.territorySize) + math.floor(0.5 + core.type.territorySize / 2)
        )
        local burrowStart = vector.new(core.x, burrowFloor, core.z)
        local direction = vector.direction(burrowStart, territoryCenter)
        local directionOffsetZ = 4
        if direction.z < 0 then directionOffsetZ = -directionOffsetZ end
        burrowStart.z = burrowStart.z + directionOffsetZ  -- start the burrow enterance off-center
        burrowStart.x = burrowStart.x + 2 -- start the burrow enterance off-center
        direction = vector.direction(burrowStart, territoryCenter)
        if vector.length(direction) == 0 then direction = vector.direction({x=0, y=0, z=0}, {x=2, y=0, z=1}) end

        local path = vector.add(vector.multiply(direction, core.radius), {x=0, y=-4,z=0})
        local floorStartingFrom = 4 + math.floor(0.5 + core.radius * 0.3)

        -- carve burrow entrance
        local pattern = {{x=0,z=0}, {x=-1,z=0}, {x=1,z=0}, {x=0,z=-1}, {x=0,z=1}}
        carve(burrowStart, vector.add(burrowStart, path), pattern, 2, floorId, floorStartingFrom)    

        -- place egg in burrow
        local eggX = core.x
        local eggZ = core.z - directionOffsetZ * 0.75 -- move the egg away from where the burrow entrance is carved
        placeNode(eggX, burrowFloor, eggZ, nodeId_egg)
        if nodeId_gravel ~= nodeId_ignore then placeNode(eggX, burrowFloor - 1, eggZ, nodeId_gravel) end
        if nodeId_cobweb ~= nodeId_ignore then 
          placeNode(core.x - 6, burrowFloor + 3, core.z - 1, nodeId_cobweb)
          placeNode(core.x + 4, burrowFloor + 4, core.z + 3, nodeId_cobweb)
          placeNode(core.x + 6, burrowFloor + 1, core.z - 3, nodeId_cobweb)
        end
      
      else
        -- Only attempt this if it can contain beds and a place to store the diary.
        if (nodeId_bookshelf ~= nodeId_ignore or nodeId_chest ~= nodeId_ignore) and nodeId_bed_top ~= nodeId_ignore and nodeId_bed_bottom ~= nodeId_ignore then

          -- carve stairs to the surface
          local stairsStart   = vector.new(core.x - 3, burrowFloor, core.z - 7)
          local stairsbottom  = vector.add(stairsStart, {x=0,y=0,z=1})
          local stairsMiddle1 = vector.add(stairsStart, {x=8,y=8,z=0})
          local stairsMiddle2 = vector.add(stairsMiddle1, {x=0,y=0,z=-1})
          local stairsEnd     = vector.add(stairsMiddle2, {x=-16,y=16,z=0})
          
          carve(stairsEnd, stairsMiddle2, {{x=0,z=0}}, 3, floorId, 0)    
          carve(stairsMiddle1, stairsStart, {{x=0,z=0}}, 2, floorId, 0)    
          local pattern = {{x=0,z=0}, {x=1,z=0}, {x=0,z=2}, {x=0,z=1}, {x=1,z=1}}
          carve(stairsbottom, stairsbottom, pattern, 2, floorId, 0)    
          
          -- fill the outpost    
          placeNode(core.x + 2, burrowFloor, core.z + 5, nodeId_bed_top)
          placeNode(core.x + 2, burrowFloor, core.z + 4, nodeId_bed_bottom)

          placeNode(core.x + 2, burrowFloor, core.z + 2, nodeId_bed_top)
          placeNode(core.x + 2, burrowFloor, core.z + 1, nodeId_bed_bottom)

          placeNode(core.x + 4, burrowFloor, core.z + 2, nodeId_bed_top)
          placeNode(core.x + 4, burrowFloor, core.z + 1, nodeId_bed_bottom)
          
          if (nodeId_torch ~= nodeId_ignore) then
            decoration_list[#decoration_list + 1] = {
              pos={x=core.x, y=burrowFloor + 2, z=core.z + 6}, 
              node={name = minetest.get_name_from_content_id(nodeId_torch), param2 = 4}
            }
          end
          if nodeId_junk      ~= nodeId_ignore then placeNode(core.x - 4, burrowFloor + 1, core.z + 5, nodeId_junk)      end
          if nodeId_anvil     ~= nodeId_ignore then placeNode(core.x - 6, burrowFloor + 1, core.z,     nodeId_anvil)     end
          if nodeId_workbench ~= nodeId_ignore then placeNode(core.x - 5, burrowFloor,     core.z + 2, nodeId_workbench) end
          if nodeId_cobweb    ~= nodeId_ignore then placeNode(core.x + 4, burrowFloor + 4, core.z - 3, nodeId_cobweb)    end
    
          local bookshelf_pos
          local invBookshelf = nil
          local invChest     = nil
          if nodeId_chest ~= nodeId_ignore then
            local pos = {x = core.x - 3, y = burrowFloor + 1, z = core.z + 6}

            local nodeName_chest = minetest.get_name_from_content_id(nodeId_chest)
            local nodeNameAtPos = minetest.get_node(pos).name
            -- falls back on the nodeNameAtPos:find("chest") check to avoid a race-condition where if the
            -- chest is opened while nearby areas are being generated, the opened chest may be replaced with 
            -- a new empty closed one.
            if nodeNameAtPos ~= nodeName_chest and not nodeNameAtPos:find("chest") then minetest.set_node(pos, {name = nodeName_chest}) end
            
            if posInBounds(pos) then 
              data[area:index(pos.x, pos.y, pos.z)] = nodeId_chest
              invChest = minetest.get_inventory({type = "node", pos = pos})
            end
          end
          if nodeId_bookshelf ~= nodeId_ignore then
            local pos = {x = core.x - 2, y = burrowFloor + 1, z = core.z + 6}
            bookshelf_pos = pos
  
            if minetest.get_node(pos).name ~= nodeName_bookshelf then minetest.set_node(pos, {name = nodeName_bookshelf}) end

            if posInBounds(pos) then 
              data[area:index(pos.x, pos.y, pos.z)] = nodeId_bookshelf
              if not isMineCloneBookshelf then -- mineclone bookshelves are decorational (like Minecraft) and don't contain anything              
                invBookshelf = minetest.get_inventory({type = "node", pos = pos})
              end
            end                            
          end

          if invBookshelf ~= nil or invChest ~= nil then
            -- create diary
            local groundDesc = "yvjr" --"rock"
            if core.biome.node_filler ~= nil then 
              local earthNames = string.lower(core.biome.node_filler) .. string.lower(core.biome.node_top)
              if string.match(earthNames, "ice") or string.match(earthNames, "snow") or string.match(earthNames, "frozen") then
                groundDesc = "pjl" --"ice"
              end
            end

            local stackName_writtenBook = rot19("klmhbsa:ivvr_dypaalu") --"default:book_written"
            if isMineCloneBookshelf then stackName_writtenBook = rot19("tjs_ivvrz:dypaalu_ivvr") end --"mcl_books:written_book"
            
            local book_itemstack = ItemStack(stackName_writtenBook)
            local book_data = {}
            book_data.title = rot19("Dlkklss Vbawvza") -- "Weddell Outpost"
            book_data.text = rot19(
            "Aol hlyvzaha pz svza.\n\n"..
            "Vby zhschnl haaltwaz aoyvbnovba aol upnoa zhclk tvza vm aol\n"..
            "wyvcpzpvuz.\n"..
            "                                    ---====---\n\n"..
            "Aopz pzshuk pz opnosf lewvzlk huk aol dlhaoly kpk uva aylha\n"..
            "aol aluaz dlss. Dl ohcl lushynlk h zolsalylk jyhn pu aol " .. groundDesc .. ",\n"..
            "iba pa pz shivyvbz dvyr huk aol jvukpapvu vm zvtl vm aol whyaf\n"..
            "pz iljvtpun jhbzl mvy jvujlyu.\n\n"..
            "Xbpal h qvbyulf pz ylxbpylk. Uvivkf dpss svvr mvy bz olyl.\n\n"..
            "TjUpzo pz haaltwapun av zaylunaolu aol nspklyz.\n\n"..
            "                                    ---====---")            
            --[[The aerostat is lost.
            
            Our salvage attempts throughout the night saved most of the
            provisions.
                                                ---====---

            This island is highly exposed and the weather did not treat
            the tents well. We have enlarged a sheltered crag in the ice, 
            but it is laborous work and the condition of some of the party 
            is becoming cause for concern.

            Quite a journey is required. Nobody will look for us here.

            McNish is attempting to strengthen the gliders.

                                                ---====---]]          
            local second_chapter =
            "Zvtl vm aol mbu vm Tpuljyhma dhz wpjrpun hwhya ovd pa "..
            "dvyrlk huk alhzpun vba hss paz zljylaz. P ovwl fvb luqvflk :)"..
            "\n\n"..
            "'uvivkf mvbuk pa! P dhz zv ohwwf hivba aoha, P mpuhssf ruld ".. 
            "zvtlaopun hivba aol nhtl aol wshflyz kpku'a ruvd.' -- Uvajo 2012 "..
            "(ylkkpa.jvt/y/Tpuljyhma/jvttluaz/xxlux/tpujlyhma_h_wvza_tvyalt/)"..
            "\n\n"..
            "Mlls myll av pucvscl aol lnn, vy Ilya, pu vaoly tvkz."
          --[[Some of the fun of Minecraft was picking apart how it
            worked and teasing out all its secrets. I hope you enjoyed :)

            "nobody found it! I was so happy about that, I finally knew 
            something about the game the players didn't know." -- Notch 2012
            (reddit.com/r/Minecraft/comments/qqenq/minceraft_a_post_mortem/)

            Feel free to involve the egg, or Bert, in other mods.
            ]]
            if isMineCloneBookshelf then book_data.text = book_data.title .. "\n\n" .. book_data.text end -- MineClone2 doesn't show the title
            book_data.owner = rot19("Ilya Zohjrslavu") --"Bert Shackleton"
            book_data.author = book_data.owner
            book_data.description = rot19("Kphyf vm Ilya Zohrslavu") --"Diary of Bert Shakleton"
            book_data.page = 1
            book_data.page_max = 1
            book_data.generation = 0
            book_itemstack:get_meta():from_table({fields = book_data})

            if invBookshelf == nil then
              -- mineclone bookshelves are decorational like Minecraft, put the book in the chest instead
              -- (also testing for nil invBookshelf because it can happen. Weird race condition??)
              if invChest ~= nil then invChest:add_item("main", book_itemstack) end
            else
              -- add the book to the bookshelf and manually trigger update_bookshelf() so its 
              -- name will reflect the new contents.
              invBookshelf:add_item("books", book_itemstack)
              local dummyPlayer = {}
              dummyPlayer.get_player_name = function() return "server" end           
              minetest.registered_nodes[nodeName_bookshelf].on_metadata_inventory_put(bookshelf_pos, "books", 1, book_itemstack, dummyPlayer)
            end
          end

          if invChest ~= nil then
            -- leave some junk from the expedition in the chest     
            local stack
            local function addIfFound(item_aliases, amount)
              for _,name in ipairs(item_aliases) do
                if minetest.registered_items[name] ~= nil then
                  stack = ItemStack(name .. " " .. amount)
                  invChest:add_item("main", stack)
                  break
                end
              end
            end
            addIfFound({"mcl_tools:pick_iron", "default:pick_steel"}, 1)
            addIfFound({"binoculars:binoculars"}, 1)
            addIfFound({"mcl_core:wood", "default:wood"}, 10)
            addIfFound({"mcl_torches:torch",   "default:torch"}, 3)          
          end

        end
      end
    end
  end
end

local function init_secrets__shhh_dont_tell_people()
  nodeId_bed_top    = interop.find_node_id(rot19({"ilkz:ilk_avw"})) --{"beds:bed_top"}
  nodeId_bed_bottom = interop.find_node_id(rot19({"ilkz:ilk_ivaavt"})) --{"beds:bed_bottom"}
  nodeId_torch      = interop.find_node_id(rot19({"tjs_avyjolz:avyjo_dhss", "klmhbsa:avyjo_dhss"})) --{"mcl_torches:torch_wall", "default:torch_wall"}
  nodeId_chest      = interop.find_node_id(rot19({"jolza", "tjs_jolzaz:jolza", "klmhbsa:jolza"})) --"chest", "mcl_chests:chest", "default:chest"
  nodeId_junk       = interop.find_node_id(rot19({"ekljvy:ihyyls", "jvaahnlz:ihyyls", "ovtlkljvy:jvwwly_whuz", "clzzlsz:zalls_ivaasl", "tjs_msvdlywvaz:msvdly_wva"})) --{"xdecor:barrel", "cottages:barrel", "homedecor:copper_pans", "vessels:steel_bottle", "mcl_flowerpots:flower_pot"}
  nodeId_anvil      = interop.find_node_id(rot19({"jhzasl:hucps", "jvaahnlz:hucps", "tjs_hucpsz:hucps", "klmhbsa:hucps" })) -- "default:anvil" isn't a thing, but perhaps one day. --{"castle:anvil", "cottages:anvil", "mcl_anvils:anvil", "default:anvil" }
  nodeId_workbench  = interop.find_node_id(rot19({"ovtlkljvy:ahisl", "ekljvy:dvyrilujo", "tjs_jyhmapun_ahisl:jyhmapun_ahisl", "klmhbsa:ahisl", "yhukvt_ibpskpunz:ilujo"})) -- "default:table" isn't a thing, but perhaps one day. -- {"homedecor:table", "xdecor:workbench", "mcl_crafting_table:crafting_table", "default:table", "random_buildings:bench"}
  nodeId_cobweb     = interop.find_node_id(rot19({"tjs_jvyl:jvidli", "ekljvy:jvidli", "ovtlkljvy:jvidli_wshuasprl", "klmhbsa:jvidli"})) --{"mcl_core:cobweb", "xdecor:cobweb", "homedecor:cobweb_plantlike", "default:cobweb"}

  local mineCloneBookshelfName = rot19("tjs_ivvrz:ivvrzolsm") --"mcl_books:bookshelf"
  nodeId_bookshelf  = interop.find_node_id({mineCloneBookshelfName, rot19("klmhbsa:ivvrzolsm")}) --"default:bookshelf"
  nodeName_bookshelf = minetest.get_name_from_content_id(nodeId_bookshelf)
  isMineCloneBookshelf = nodeName_bookshelf == mineCloneBookshelfName
  
  local nodeName_standinCobweb = MODNAME .. rot19(":jvidli") -- ":cobweb"   
  if nodeId_cobweb ~= nodeId_ignore then
    -- This game has proper cobwebs, replace any cobwebs this mod may have generated 
    -- previously (when a cobweb mod wasn't included) with the proper cobwebs.
    minetest.register_alias(nodeName_standinCobweb, minetest.get_name_from_content_id(nodeId_cobweb))
  else
    -- use a stand-in cobweb created by this mod
    nodeId_cobweb = minetest.get_content_id(nodeName_standinCobweb)
  end
end
------------------------------------------------------------------------------
-- End of secrets section
------------------------------------------------------------------------------


local function renderCores(cores, minp, maxp, blockseed)

  local voxelsWereManipulated = false

  -- "Surface" nodes are written to a seperate buffer so that minetest.generate_decorations() can
  -- be called on just the ground surface, otherwise jungle trees will grow on top of chunk boundaries
  -- where the bottom of an island has been emerged but not the top.
  -- The two buffers are combined after minetest.generate_decorations() has run.
  local vm, emerge_min, emerge_max = minetest.get_mapgen_object("voxelmanip")
  vm:get_data(data)        -- put all nodes except the ground surface in this array
  vm:get_data(surfaceData) -- put only the ground surface nodes in this array
  local area = VoxelArea:new{MinEdge=emerge_min, MaxEdge=emerge_max}

  local currentBiomeId = -1
  local nodeId_dust
  local nodeId_top
  local nodeId_filler
  local nodeId_stoneBase
  local depth_top
  local depth_filler
  local fillerFallsWithGravity
  local floodableDepth
  
  for z = minp.z, maxp.z do

    local dataBufferIndex = area:index(minp.x, minp.y, z)
    for x = minp.x, maxp.x do
      for _,core in pairs(cores) do
        local coreTop = ALTITUDE + core.y

        local distanceSquared = (x - core.x)*(x - core.x) + (z - core.z)*(z - core.z)
        local radius        = core.radius
        local radiusSquared = radius * radius

        if distanceSquared <= radiusSquared then

          -- get the biome details for this core
          if core.biome == nil then setCoreBiomeData(core) end          
          if currentBiomeId ~= core.biomeId then
            if core.biome.node_top    == nil then nodeId_top       = nodeId_stone  else nodeId_top       = minetest.get_content_id(core.biome.node_top)    end
            if core.biome.node_filler == nil then nodeId_filler    = nodeId_stone  else nodeId_filler    = minetest.get_content_id(core.biome.node_filler) end
            if core.biome.node_stone  == nil then nodeId_stoneBase = nodeId_stone  else nodeId_stoneBase = minetest.get_content_id(core.biome.node_stone)  end
            if core.biome.node_dust   == nil then nodeId_dust      = nodeId_ignore else nodeId_dust      = minetest.get_content_id(core.biome.node_dust)   end

            if core.biome.depth_top    == nil then depth_top    = 1 else depth_top    = core.biome.depth_top    end
            if core.biome.depth_filler == nil then depth_filler = 3 else depth_filler = core.biome.depth_filler end
            fillerFallsWithGravity = core.biome.node_filler ~= nil and minetest.registered_items[core.biome.node_filler].groups.falling_node == 1

            --[[Commented out as unnecessary, as a supporting node will be added, but uncommenting 
                this will make the strata transition less noisey.
            if fillerFallsWithGravity then
              -- the filler node is affected by gravity and can fall if unsupported, so keep that layer thinner than
              -- core.thickness when possible.
              --depth_filler = math_min(depth_filler, math_max(1, core.thickness - 1))
            end--]]

            floodableDepth = 0
            if nodeId_top ~= nodeId_stone and minetest.registered_items[core.biome.node_top].floodable then 
              -- nodeId_top is a node that water floods through, so we can't have ponds appearing at this depth
              floodableDepth = depth_top
            end
						
            currentBiomeId = core.biomeId
          end

          -- decide on a shape
          local horz_easing
          local noise_weighting = 1
          local shapeType = math_floor(core.depth + radius + core.x) % 5
          if shapeType < 2 then
            -- convex
            -- squared easing function, e = 1 - x²
              horz_easing = 1 - distanceSquared / radiusSquared
          elseif shapeType == 2 then
            -- conical
            -- linear easing function, e = 1 - x
            horz_easing = 1 - math_sqrt(distanceSquared) / radius
          else 
            -- concave
            -- root easing function blended/scaled with square easing function,
            -- x = normalised distance from center of core
            -- a = 1 - x²
            -- b = 1 - √x
            -- e = 0.8*a*x + 1.2*b*(1 - x)

            local radiusRoot = core.radiusRoot
            if radiusRoot == nil then
              radiusRoot = math_sqrt(radius)
              core.radiusRoot = radiusRoot
            end			

            local squared  = 1 - distanceSquared / radiusSquared
            local distance = math_sqrt(distanceSquared)
            local distance_normalized = distance / radius
            local root = 1 - math_sqrt(distance) / radiusRoot
            horz_easing = math_min(1, 0.8*distance_normalized*squared + 1.2*(1-distance_normalized)*root)

            -- this seems to be a more delicate shape that gets wiped out by the
            -- density noise, so lower that
            noise_weighting = 0.63 
          end
          if radius + core.depth > 80 then
            -- larger islands shapes have a slower easing transition, which leaves large areas 
            -- dominated by the density noise, so reduce the density noise when the island is large.
            -- (the numbers here are arbitrary)            
            if radius + core.depth > 120 then 
              noise_weighting = 0.35
            else
              noise_weighting = math_min(0.6, noise_weighting)
            end
          end

          local surfaceNoise = noise_surfaceMap:get2d({x = x, y = z})
          if DEBUG_GEOMETRIC then surfaceNoise = SURFACEMAP_OFFSET end
          local surface = round(surfaceNoise * 3 * (core.thickness + 1) * horz_easing)
          local coreBottom = math_floor(coreTop - (core.thickness + core.depth))
          local noisyDepthOfFiller = depth_filler;
          if noisyDepthOfFiller >= 3 then noisyDepthOfFiller = noisyDepthOfFiller + math_floor(randomNumbers[(x + z) % 256] * 3) - 1 end

          local yBottom       = math_max(minp.y, coreBottom - 4) -- the -4 is for rare instances when density noise pushes the bottom of the island deeper
          local yBottomIndex  = dataBufferIndex + area.ystride * (yBottom - minp.y) -- equivalent to yBottomIndex = area:index(x, yBottom, z)
          local topBlockIndex = -1
          local bottomBlockIndex = -1
          local vi = yBottomIndex
          local densityNoise  = nil

          for y = yBottom, math_min(maxp.y, coreTop + surface) do
            local vert_easing = math_min(1, (y - coreBottom) / core.depth)

            -- If you change the densityNoise calculation, remember to similarly update the copy of this calculation in the pond code
            densityNoise = noise_density:get3d({x = x, y = y - coreTop, z = z}) -- TODO: Optimize this!!
            densityNoise = noise_weighting * densityNoise + (1 - noise_weighting) * DENSITY_OFFSET

            if DEBUG_GEOMETRIC then densityNoise = DENSITY_OFFSET end

            if densityNoise * ((horz_easing + vert_easing) / 2) >= REQUIRED_DENSITY then
              if vi > topBlockIndex then topBlockIndex = vi end
              if bottomBlockIndex < 0 and y > minp.y then bottomBlockIndex = vi end -- if y==minp.y then we don't know for sure this is the lowest block

              if y > coreTop + surface - depth_top and data[vi] == nodeId_air then
                surfaceData[vi] = nodeId_top
                data[vi] = nodeId_top -- will be overwritten by surfaceData[] later, but means we can decorate based on data[]
              elseif y >= coreTop + surface - (depth_top + noisyDepthOfFiller) then
                data[vi] = nodeId_filler
                surfaceData[vi] = nodeId_air -- incase we have intersected another island
              else
                data[vi] = nodeId_stoneBase
                surfaceData[vi] = nodeId_air -- incase we have intersected another island
              end
            end
            vi = vi + area.ystride
          end

          -- ensure nodeId_top blocks also cover the rounded sides of islands (which may be lower
          -- than the flat top), then dust the top surface.
          if topBlockIndex >= 0 then
            voxelsWereManipulated = true;

            -- we either have the highest block, or maxp.y - but we don't want to set maxp.y nodes to nodeId_top
            -- (we will err on the side of caution when we can't distinguish the top of a island's side from maxp.y)
            if maxp.y >= coreTop + surface or vi > topBlockIndex + area.ystride then
              if topBlockIndex > yBottomIndex and data[topBlockIndex - area.ystride] ~= nodeId_air and data[topBlockIndex + area.ystride] == nodeId_air then
                -- We only set a block to nodeId_top if there's a block under it "holding it up" as
                -- it's better to leave 1-deep noise as stone/whatever.
                --data[topBlockIndex] = nodeId_top
                surfaceData[topBlockIndex] = nodeId_top
              end
              if nodeId_dust ~= nodeId_ignore and data[topBlockIndex + area.ystride] == nodeId_air then
                -- writing the dust to the data buffer instead of surfaceData means a snow layer
                -- won't prevent tree growth
                data[topBlockIndex + area.ystride] = nodeId_dust
              end
            end

            if fillerFallsWithGravity and bottomBlockIndex >= 0 and data[bottomBlockIndex] == nodeId_filler then
              -- the bottom node is affected by gravity and can fall if unsupported, put some support in
              data[bottomBlockIndex] = nodeId_stoneBase
            end
          end

          -- add ponds of water, trying to make sure they're not on an edge.
          -- (the only time a pond needs to be rendered when densityNoise is nil (i.e. when there was no land at this x, z),
          -- is when the pond is at minp.y - i.e. the reason no land was rendered is it was below minp.y)
          if surfaceNoise < 0 and (densityNoise ~= nil or (coreTop + surface < minp.y and coreTop >= minp.y)) and nodeId_water ~= nodeId_ignore then            
            local pondWallBuffer = core.type.pondWallBuffer
            local pondBottom = nodeId_filler
            local pondWater  = nodeId_water
            if radius > 18 and core.depth > 15 and nodeId_silt ~= nodeId_ignore then 
              -- only give ponds a sandbed when islands are large enough for it not to stick out the side or bottom
              pondBottom = nodeId_silt 
            end
            if core.temperature <= ICE_REQUIRED_TEMPERATURE and nodeId_ice ~= nodeId_ignore then pondWater = nodeId_ice end

            if densityNoise == nil then
              -- Rare edge case. If the pond is at minp.y, then no land has been rendered, so 
              -- densityNoise hasn't been calculated. Calculate it now.
              densityNoise = noise_density:get3d({x = x, y = minp.y, z = z})
              densityNoise = noise_weighting * densityNoise + (1 - noise_weighting) * DENSITY_OFFSET
              if DEBUG_GEOMETRIC then densityNoise = DENSITY_OFFSET end
            end

            local surfaceDensity = densityNoise * ((horz_easing + 1) / 2)
            local onTheEdge = math_sqrt(distanceSquared) + 1 >= radius
            for y = math_max(minp.y, coreTop + surface), math_min(maxp.y, coreTop - floodableDepth) do
              if surfaceDensity > REQUIRED_DENSITY then
                local vi  = dataBufferIndex + area.ystride * (y - minp.y) -- this is the same as vi = area:index(x, y, z)

                if surfaceDensity > (REQUIRED_DENSITY + pondWallBuffer) and not onTheEdge then
                  surfaceData[vi] = pondWater
                  --data[vi] = nodeId_air -- commented out because it causes vines to think this is the edge, if you uncomment this you MUST update isIsland()
                  if y > minp.y then data[vi - area.ystride] = pondBottom end
                  --remove any dust above ponds
                  if y < maxp.y and data[vi + area.ystride] == nodeId_dust then data[vi + area.ystride] = nodeId_air end
                else
                  -- make sure there are some walls to keep the water in
                  if y == coreTop then 
                    surfaceData[vi] = nodeId_top
                  else
                    surfaceData[vi] = nodeId_air
                    data[vi] = nodeId_filler
                  end
                end;
              end
            end            
          end;

        end
      end
      dataBufferIndex = dataBufferIndex + 1
    end
  end

  local decorations = {}
  for _,core in ipairs(cores) do
    addDetail_vines(decorations, core, data, area, minp, maxp)
    voxelsWereManipulated = addDetail_skyReef(decorations, core, data, area, minp, maxp) or voxelsWereManipulated
    addDetail_secrets__shhh_dont_tell_people(decorations, core, data, area, minp, maxp)
  end

  if voxelsWereManipulated then
    -- Generate decorations on surfaceData only, then combine surfaceData and decorations
    -- with the main data buffer. This avoids trees growing off dirt exposed by maxp.y
    -- (A faster way would be nice, overgeneration perhaps?)
    vm:set_data(surfaceData)
    minetest.generate_decorations(vm)
    vm:get_data(surfaceData)
    for i, value in ipairs(surfaceData) do 
      if value ~= nodeId_air then data[i] = value end
    end

    vm:set_data(data)    
    if GENERATE_ORES then minetest.generate_ores(vm) end

    for _,decoration in ipairs(decorations) do
      local nodeAtPos = minetest.get_node(decoration.pos)
      if nodeAtPos.name == "air" or nodeAtPos.name == "ignore" then minetest.set_node(decoration.pos, decoration.node) end
    end

    vm:set_lighting({day=0, night=0}) -- Can't do the flags="nolight" trick here as mod is designed to run with other mapgens
    --vm:calc_lighting()
    vm:calc_lighting(nil, nil, false) -- I can't see any effect from turning off propegation of shadows, but perhaps when islands cut the voxel area just right it might avoid shadows on the land?
    vm:write_to_map() -- seems to be unnecessary when other mods that use vm are running
  end
end


local function on_generated(minp, maxp, blockseed)

  local memUsageT0
  local osClockT0 = os.clock()
  if DEBUG then memUsageT0 = collectgarbage("count") end

  local maxCoreThickness = coreTypes[1].thicknessMax
  local maxCoreDepth     = coreTypes[1].radiusMax * 3 / 2

  if minp.y > ALTITUDE + (ALTITUDE_AMPLITUDE + maxCoreThickness + 5) or
     maxp.y < ALTITUDE - (ALTITUDE_AMPLITUDE + maxCoreThickness + maxCoreDepth + 1) then
    -- Hallelujah Mountains don't generate here
    return
  end

  if noise_eddyField == nil then 
    init_mapgen() 
    init_secrets__shhh_dont_tell_people()
  end
  local cores = getCores(minp, maxp)

  if DEBUG then
    minetest.log("info", "Cores for on_generated(): " .. #cores)
    for _,core in pairs(cores) do
      minetest.log("core ("..core.x..","..core.y..","..core.z..") r"..core.radius);
    end
  end

  if #cores > 0 then
    -- voxelmanip has mem-leaking issues, avoid creating one if we're not going to need it
    renderCores(cores, minp, maxp, blockseed)

    if DEBUG then 
      minetest.log(
        "info", 
        MODNAME .. " took " 
        .. round((os.clock() - osClockT0) * 1000)
        .. "ms for " .. #cores .. " cores. Uncollected memory delta: " 
        .. round(collectgarbage("count") - memUsageT0) .. " KB"
      ) 
    end
  end
end


minetest.register_on_generated(on_generated)

minetest.register_on_mapgen_init(
  -- invoked after mods initially run but before the environment is created, while the mapgen is being initialized
  function(mgparams)
    worldSeed = mgparams.seed
    --if DEBUG then minetest.set_mapgen_params({mgname = "singlenode"--[[, flags = "nolight"]]}) end
  end
)
