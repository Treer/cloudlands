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
local NODENAMES_ICE    = {"mapgen_ice",          "mcl_core:ice",          "default:ice", "pedology:ice_white"}
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

-- minified with https://mothereff.in/lua-minifier
local function a(b)if type(b)=="table"then for c,d in ipairs(b)do b[c]=a(d)end;return b else return b:gsub("%a",function(e)e=e:byte()return string.char(e+(e%32<8 and 19 or-7))end)end end;if minetest.get_modpath("default")then local f=MODNAME..a(":jvidli")minetest.register_node(f,{tiles={"crack_anylength.png^[verticalframe:5:4^[brighten"},description=a("Jvidli"),groups={snappy=3,liquid=3,flammable=3,not_in_creative_inventory=1},drawtype="plantlike",walkable=false,liquid_viscosity=8,liquidtype="source",liquid_alternative_flowing=f,liquid_alternative_source=f,liquid_renewable=false,liquid_range=0,sunlight_propagates=true,paramtype="light"})end;local g=a("zljyla:mvzzpspglk_lnn")local h=a("klmhbsa_qbunslslhclz.wun")if minetest.get_modpath("ethereal")~=nil then h=a("laolylhs_myvza_slhclz.wun")end;minetest.register_node(":"..g,{tiles={h.."^[colorize:#280040E0^[noalpha"},description=a("Mvzzpspglk Lnn"),groups={oddly_breakable_by_hand=3,not_in_creative_inventory=1},drawtype="nodebox",paramtype="light",node_box={type="fixed",fixed={{-0.066666,-0.5,-0.066666,0.066666,0.5,0.066666},{-0.133333,-0.476667,-0.133333,0.133333,0.42,0.133333},{-0.2,-0.435,-0.2,0.2,0.31,0.2},{-0.2,-0.36,-0.28,0.2,0.16667,0.28},{-0.28,-0.36,-0.2,0.28,0.16667,0.2}}}})local i=minetest.get_content_id(g)local j=minetest.get_content_id(interop.register_clone("air"))local k;local l;local m;local n;local o;local p;local q;local r;local s;local t;local u;

local function addDetail_secrets__shhh_dont_tell_people(w,x,y,z,A,B)if x.biome~=nil and x.radius>18 and x.depth>20 and x.radius+x.depth>60 then local C=math_floor(x.x/x.type.territorySize)local D=math_floor(x.z/x.type.territorySize)local E=x.temperature<=5 and x.x%3==0 and noise_surfaceMap:get2d({x=x.x,y=x.z-8})>=0;local F=x.humidity>=60 and x.temperature>=50;if(C+D)%2==0 and(E or F)then local G=7;local H=5;local I=12;local J=ALTITUDE+x.y-I;local K=G*G;local function L(M,N,O,P,Q,R)local S=vector.direction(M,N)local T={}if S.x>0 then T.x=-1 else T.x=1 end;if S.z>0 then T.z=-1 else T.z=1 end;local U={}local function V(W,X,Y)if y[W]==nodeId_air then local Z={}local _;local function a0(a1)return a1~=nodeId_air and a1~=j and(a1==Y or Y==nil)end;if a0(y[W+T.x])and X.x+T.x>=A.x and X.x+T.x<=B.x then if T.x>0 then _=2 else _=3 end;Z[#Z+1]={solid_vi=W+T.x,facing=_}end;if a0(y[W+T.z*z.zstride])and X.z+T.z>=A.z and X.z+T.z<=B.z then if T.z>0 then _=4 else _=5 end;Z[#Z+1]={solid_vi=W+T.z*z.zstride,facing=_}end;local a2=nil;if#Z==1 then a2=Z[1]elseif#Z==2 then local a3=math.abs(S.x)/(math.abs(S.x)+math.abs(S.z))if randomNumbers[(X.x+X.y+X.z)%256]<=a3 then a2=Z[1]else a2=Z[2]end end;if a2~=nil and(Y==nil or Y==y[a2.solid_vi])and y[a2.solid_vi]~=j then local a4=a2.solid_vi;local a5=1;while X.y+a5<=B.y+1 and y[a4+a5*z.ystride]~=nodeId_air and y[W+a5*z.ystride]==nodeId_air and(Y==nil or Y==y[a4+a5*z.ystride])do a5=a5+1 end;U[#U+1]=function(w)local a6=y[a4+(a5-1)*z.ystride]if a6~=j and a6~=nodeId_air and y[W]==nodeId_air then w[#w+1]={pos={x=X.x,y=X.y+a5-1,z=X.z},node={name=nodeName_vine,param2=a2.facing}}end end end end end;local a7={}local function a8(X,O,P,a1,a9)local aa={}local ab=-1;for ac=X.y,X.y+P-1 do if ac>=A.y and ac<=B.y then if ab==-1 then ab=z:index(X.x,ac,X.z)else ab=ab+z.ystride end;for ad,ae in ipairs(O)do local af=X.x+ae.x;local ag=X.z+ae.z;if af>=A.x and af<=B.x and ag>=A.z and ag<=B.z then local W=ab+ae.x+ae.z*z.zstride;if y[W]==nodeId_air then if a9~=nil then aa[#aa+1]=function()a9(X,W,af,ac,ag)end end else y[W]=a1;a7[#a7+1]=W end end end end end;for ad,ah in ipairs(aa)do ah()end end;local function ai(X,aj,ak,al)local function am(an,ao,ap,aq,ar)if aq>an.y and aq+1<=B.y then V(ao+z.ystride,{x=ap,y=aq+1,z=ar})else V(ao,{x=ap,y=aq,z=ar},Q)end end;local as=am;local at=j;if not ak then as=nil end;if al and s~=nodeId_ignore then at=s end;a8(X,O,P,at,as)if aj and Q~=nil then a8({x=X.x,y=X.y-1,z=X.z},O,1,Q,as)end end;local au=x.humidity>=VINES_REQUIRED_HUMIDITY and x.temperature>=VINES_REQUIRED_TEMPERATURE;if R==nil then R=0 end;local av=round(vector.distance(M,N))local aw=vector.divide(vector.subtract(N,M),av)local X=vector.new(M)local ax=vector.new(M)ai(M,0>=R,false)for ay=1,av do ax.x=ax.x+aw.x;if round(ax.x)~=X.x then X.x=round(ax.x)ai(X,ay>=R,au,ay<=R-1 and ay>=R-2)end;ax.y=ax.y+aw.y;if round(ax.y)~=X.y then X.y=round(ax.y)ai(X,ay>=R,au,ay<=R-1 and ay>=R-2)end;ax.z=ax.z+aw.z;if round(ax.z)~=X.z then X.z=round(ax.z)ai(X,ay>=R,au,ay<=R-1 and ay>=R-2)end end;for ad,az in ipairs(U)do az(w)end;for ad,aA in ipairs(a7)do if y[aA]==j then y[aA]=nodeId_air;surfaceData[aA]=nodeId_air end end end;local function aB(af,ac,ag,a1)if af>=A.x and af<=B.x and ag>=A.z and ag<=B.z and ac>=A.y and ac<=B.y then y[z:index(af,ac,ag)]=a1 end end;local function aC(X)return X.x>=A.x and X.x<=B.x and X.z>=A.z and X.z<=B.z and X.y>=A.y and X.y<=B.y end;local aD=math_max(x.z-G,A.z)local aE=math_max(x.x-G,A.x)local aF=math_min(x.x+G,B.x)local aG=math_max(J,A.y)local aH=z:index(aE,aG,aD)for ag=aD,math_min(x.z+G,B.z)do for af=aE,aF do local aI=(af-x.x)*(af-x.x)+(ag-x.z)*(ag-x.z)if aI<K then local aJ=1-aI/K;for ac=math_max(A.y,J+math_floor(1.4-aJ)),math_min(B.y,J+1+math_min(H-1,math_floor(0.8+H*aJ)))do y[aH+(ac-aG)*z.ystride]=nodeId_air end end;aH=aH+1 end;aH=aH+z.zstride-(aF-aE+1)end;local Q;if x.biome.node_top==nil then Q=nil else Q=minetest.get_content_id(x.biome.node_top)end;if F then local aK=vector.new(x.type.territorySize*math.floor(x.x/x.type.territorySize)+math.floor(0.5+x.type.territorySize/2),J,x.type.territorySize*math.floor(x.z/x.type.territorySize)+math.floor(0.5+x.type.territorySize/2))local aL=vector.new(x.x,J,x.z)local S=vector.direction(aL,aK)local aM=4;if S.z<0 then aM=-aM end;aL.z=aL.z+aM;aL.x=aL.x+2;S=vector.direction(aL,aK)if vector.length(S)==0 then S=vector.direction({x=0,y=0,z=0},{x=2,y=0,z=1})end;local aN=vector.add(vector.multiply(S,x.radius),{x=0,y=-4,z=0})local aO=4+math.floor(0.5+x.radius*0.3)local O={{x=0,z=0},{x=-1,z=0},{x=1,z=0},{x=0,z=-1},{x=0,z=1}}L(aL,vector.add(aL,aN),O,2,Q,aO)local aP=x.x;local aQ=x.z-aM*0.75;aB(aP,J,aQ,i)if nodeId_gravel~=nodeId_ignore then aB(aP,J-1,aQ,nodeId_gravel)end;if s~=nodeId_ignore then aB(x.x-6,J+3,x.z-1,s)aB(x.x+4,J+4,x.z+3,s)aB(x.x+6,J+1,x.z-3,s)end else if(o~=nodeId_ignore or n~=nodeId_ignore)and k~=nodeId_ignore and l~=nodeId_ignore then local aR=vector.new(x.x-3,J,x.z-7)local aS=vector.add(aR,{x=0,y=0,z=1})local aT=vector.add(aR,{x=8,y=8,z=0})local aU=vector.add(aT,{x=0,y=0,z=-1})local aV=vector.add(aU,{x=-16,y=16,z=0})L(aV,aU,{{x=0,z=0}},3,Q,0)L(aT,aR,{{x=0,z=0}},2,Q,0)local O={{x=0,z=0},{x=1,z=0},{x=0,z=2},{x=0,z=1},{x=1,z=1}}L(aS,aS,O,2,Q,0)aB(x.x+2,J,x.z+5,k)aB(x.x+2,J,x.z+4,l)aB(x.x+2,J,x.z+2,k)aB(x.x+2,J,x.z+1,l)aB(x.x+4,J,x.z+2,k)aB(x.x+4,J,x.z+1,l)if m~=nodeId_ignore then w[#w+1]={pos={x=x.x,y=J+2,z=x.z+6},node={name=minetest.get_name_from_content_id(m),param2=4}}end;if p~=nodeId_ignore then aB(x.x-4,J+1,x.z+5,p)end;if q~=nodeId_ignore then aB(x.x-6,J+1,x.z,q)end;if r~=nodeId_ignore then aB(x.x-5,J,x.z+2,r)end;if s~=nodeId_ignore then aB(x.x+4,J+4,x.z-3,s)end;local aW;local aX=nil;local aY=nil;if n~=nodeId_ignore then local X={x=x.x-3,y=J+1,z=x.z+6}local aZ=minetest.get_name_from_content_id(n)local a_=minetest.get_node(X).name;if a_~=aZ and not a_:find("chest")then minetest.set_node(X,{name=aZ})end;if aC(X)then y[z:index(X.x,X.y,X.z)]=n;aY=minetest.get_inventory({type="node",pos=X})end end;if o~=nodeId_ignore then local X={x=x.x-2,y=J+1,z=x.z+6}aW=X;if minetest.get_node(X).name~=t then minetest.set_node(X,{name=t})end;if aC(X)then y[z:index(X.x,X.y,X.z)]=o;if not u then aX=minetest.get_inventory({type="node",pos=X})end end end;if aX~=nil or aY~=nil then local b0="yvjr"if x.biome.node_filler~=nil then local b1=string.lower(x.biome.node_filler)..string.lower(x.biome.node_top)if string.match(b1,"ice")or string.match(b1,"snow")or string.match(b1,"frozen")then b0="pjl"end end;local b2=a("klmhbsa:ivvr_dypaalu")if u then b2=a("tjs_ivvrz:dypaalu_ivvr")end;local b3=ItemStack(b2)local b4={}b4.title=a("Dlkklss Vbawvza")b4.text=a("Aol hlyvzaha pz svza.\n\n".."Vby zhschnl haaltwaz aoyvbnovba aol upnoa zhclk tvza vm aol\n".."wyvcpzpvuz.\n".."                                    ---====---\n\n".."Aopz pzshuk pz opnosf lewvzlk huk aol dlhaoly kpk uva aylha\n".."aol aluaz dlss. Dl ohcl lushynlk h zolsalylk jyhn pu aol "..b0 ..",\n".."iba pa pz shivyvbz dvyr huk aol jvukpapvu vm zvtl vm aol whyaf\n".."pz iljvtpun jhbzl mvy jvujlyu.\n\n".."Xbpal h qvbyulf pz ylxbpylk. Uvivkf dpss svvr mvy bz olyl.\n\n".."TjUpzo pz haaltwapun av zaylunaolu aol nspklyz.\n\n".."                                    ---====---")local b5="Zvtl vm aol mbu vm Tpuljyhma dhz wpjrpun hwhya ovd pa ".."dvyrlk huk alhzpun vba hss paz zljylaz. P ovwl fvb luqvflk :)".."\n\n".."'uvivkf mvbuk pa! P dhz zv ohwwf hivba aoha, P mpuhssf ruld ".."zvtlaopun hivba aol nhtl aol wshflyz kpku'a ruvd.' -- Uvajo 2012 ".."(ylkkpa.jvt/y/Tpuljyhma/jvttluaz/xxlux/tpujlyhma_h_wvza_tvyalt/)".."\n\n".."Mlls myll av pucvscl aol lnn, vy Ilya, pu vaoly tvkz."if u then b4.text=b4.title.."\n\n"..b4.text end;b4.owner=a("Ilya Zohjrslavu")b4.author=b4.owner;b4.description=a("Kphyf vm Ilya Zohrslavu")b4.page=1;b4.page_max=1;b4.generation=0;b3:get_meta():from_table({fields=b4})if aX==nil then if aY~=nil then aY:add_item("main",b3)end else aX:add_item("books",b3)local dummyPlayer={}dummyPlayer.get_player_name=function()return"server"end;minetest.registered_nodes[t].on_metadata_inventory_put(aW,"books",1,b3,dummyPlayer)end end;if aY~=nil then local b6;local function addIfFound(b7,b8)for ad,b9 in ipairs(b7)do if minetest.registered_items[b9]~=nil then b6=ItemStack(b9 .." "..b8)aY:add_item("main",b6)break end end end;addIfFound({"mcl_tools:pick_iron","default:pick_steel"},1)addIfFound({"binoculars:binoculars"},1)addIfFound({"mcl_core:wood","default:wood"},10)addIfFound({"mcl_torches:torch","default:torch"},3)end end end end end end;

local function init_secrets__shhh_dont_tell_people()k=interop.find_node_id(a({"ilkz:ilk_avw"}))l=interop.find_node_id(a({"ilkz:ilk_ivaavt"}))m=interop.find_node_id(a({"tjs_avyjolz:avyjo_dhss","klmhbsa:avyjo_dhss"}))n=interop.find_node_id(a({"jolza","tjs_jolzaz:jolza","klmhbsa:jolza"}))p=interop.find_node_id(a({"ekljvy:ihyyls","jvaahnlz:ihyyls","ovtlkljvy:jvwwly_whuz","clzzlsz:zalls_ivaasl","tjs_msvdlywvaz:msvdly_wva"}))q=interop.find_node_id(a({"jhzasl:hucps","jvaahnlz:hucps","tjs_hucpsz:hucps","klmhbsa:hucps"}))r=interop.find_node_id(a({"ovtlkljvy:ahisl","ekljvy:dvyrilujo","tjs_jyhmapun_ahisl:jyhmapun_ahisl","klmhbsa:ahisl","yhukvt_ibpskpunz:ilujo"}))s=interop.find_node_id(a({"tjs_jvyl:jvidli","ekljvy:jvidli","ovtlkljvy:jvidli_wshuasprl","klmhbsa:jvidli"}))local bb=a("tjs_ivvrz:ivvrzolsm")o=interop.find_node_id({bb,a("klmhbsa:ivvrzolsm")})t=minetest.get_name_from_content_id(o)u=t==bb;local f=MODNAME..a(":jvidli")if s~=nodeId_ignore then minetest.register_alias(f,minetest.get_name_from_content_id(s))else s=minetest.get_content_id(f)end end


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
        local radiusRoot    = core.radiusRoot
        if radiusRoot == nil then
          radiusRoot = math_sqrt(radius)
          core.radiusRoot = radiusRoot
        end

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
