-- ProfitCrafter: travel
--   Learns more of the world as you play (trainers, innkeepers, repair vendors, portals, boats,
--   zeppelins and trams, where your hearthstone and teleports land) and shares it with other
--   ProfitCrafter users on your faction. Then, for every "go somewhere" step, it works out the
--   quickest way: walking, a flight, your hearthstone (when it's ready), your own mage teleports,
--   a city portal or a boat, or a mix of them, and says it step by step.

local ADDON, ns = ...
local PC = ns.PC
local Places = PC.Places

local Travel = {}
PC.Travel = Travel

Travel.HEARTH_ITEM = 6948
Travel.HEARTH_SPELL = 8690
Travel.CAST = 10            -- seconds to cast a hearthstone or teleport
Travel.FLY_SPEED = 30       -- yards a second on a flight path (straight line; routes bend)
Travel.BEND = 1.3           -- paths and flight routes aren't straight lines
Travel.BOAT_WAIT = 60       -- average wait for a boat or zeppelin
Travel.FP_STOP = 15         -- talking to the flight master, getting on and off

-- Mage teleports: spell id = city it lands in
Travel.TELEPORTS = {
    [3561] = "Stormwind", [3562] = "Ironforge", [3565] = "Darnassus", [32271] = "Exodar",
    [3563] = "Undercity", [3566] = "Thunder Bluff", [3567] = "Orgrimmar", [32272] = "Silvermoon",
    [33690] = "Shattrath", [35715] = "Shattrath", [49359] = "Theramore", [49358] = "Stonard",
    [53140] = "Dalaran", [88342] = "Tol Barad", [88344] = "Tol Barad", [120145] = "Dalaran",
    [132621] = "Vale of Eternal Blossoms", [132627] = "Vale of Eternal Blossoms",
    [176248] = "Stormshield", [176242] = "Warspear", [224869] = "Dalaran", [281403] = "Boralus",
    [281404] = "Dazar'alor", [344587] = "Oribos", [395277] = "Valdrakken", [446540] = "Dornogal",
}

---------------------------------------------------------------------------
-- Where things are in the world (yards, per continent), so distances work across zones
---------------------------------------------------------------------------
function Travel:World(map, x, y)
    if not map or not x or not y then return nil end
    if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
    if not ok or not cont or not pos then return nil end
    local wx, wy = pos.x, pos.y
    if (wx == nil or wy == nil) and pos.GetXY then wx, wy = pos:GetXY() end
    wx, wy = PC.Num(wx), PC.Num(wy)
    if not wx or not wy then return nil end
    return cont, wx, wy
end

local NONE = {}

-- a point: { map, x, y } (a place or a spot); world position cached on it
local function W(pt)
    if not pt then return nil end
    if pt.wc == nil then
        local c, x, y = Travel:World(pt.map, pt.x, pt.y)
        pt.wc, pt.wx, pt.wy = c or false, x, y
    end
    if pt.wc == false then return nil end
    return pt.wc, pt.wx, pt.wy
end

-- yards between two points (nil when it can't tell: different continents, or no map data)
function Travel:Yards(a, b)
    if not a or not b then return nil end
    local ca, ax, ay = W(a)
    local cb, bx, by = W(b)
    if ca and cb then
        if ca ~= cb then return nil end
        return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
    end
    if a.map and a.map == b.map then -- no world data: same map, about 10 yards a map unit
        local w, h = 1000, 1000
        if C_Map and C_Map.GetMapWorldSize then
            local ok, mw, mh = pcall(C_Map.GetMapWorldSize, a.map)
            if ok and mw and mw > 0 then w, h = mw, mh end
        end
        return math.sqrt(((a.x - b.x) * w) ^ 2 + ((a.y - b.y) * h) ^ 2)
    end
    return nil
end

-- how fast you get about on your own (yards a second): the fastest you've been seen going, off a flight
function Travel:Speed()
    local s = PC.cdb and PC.cdb.runSpeed or 7
    return math.max(s, 7) * 0.85 -- not full speed the whole way
end

-- How high up you are, when the game says (UnitPosition's third answer). Thunder Bluff's lifts are
-- the one place where the map can't tell top from bottom, and height can.
function Travel:HeightHere()
    if not UnitPosition then return nil end
    local ok, _, _, z = pcall(UnitPosition, "player")
    z = ok and tonumber(z) or nil
    if not z or z == 0 then return nil end
    return z
end

function Travel:Here()
    local map, x, y, zone = Places:Here()
    if not map then return nil end
    return { map = map, x = x, y = y, zone = zone, name = "you", z = self:HeightHere() }
end

---------------------------------------------------------------------------
-- What's ready to use
---------------------------------------------------------------------------
local function ItemCooldownLeft(itemID)
    local fn = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
    if not fn then return 0 end
    local ok, start, dur = pcall(fn, itemID)
    if not ok or not start or start == 0 then return 0 end
    return math.max(start + (dur or 0) - GetTime(), 0)
end

local function SpellReady(id)
    local known = (IsPlayerSpell and IsPlayerSpell(id)) or (IsSpellKnown and IsSpellKnown(id))
    if not known then return false end
    local start, dur
    if C_Spell and C_Spell.GetSpellCooldown then
        local ok, info = pcall(C_Spell.GetSpellCooldown, id)
        if ok and type(info) == "table" then start, dur = info.startTime, info.duration end
    elseif GetSpellCooldown then
        local ok, s, d = pcall(GetSpellCooldown, id)
        if ok then start, dur = s, d end
    end
    if start and start > 0 and (start + (dur or 0) - GetTime()) > 1.5 then return false end
    -- the rune it needs (classic): the game says if it can be cast
    local usable = true
    if C_Spell and C_Spell.IsSpellUsable then
        local ok, u = pcall(C_Spell.IsSpellUsable, id); if ok and u ~= nil then usable = u end
    elseif IsUsableSpell then
        local ok, u = pcall(IsUsableSpell, id); if ok and u ~= nil then usable = u and true or false end
    end
    return usable
end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then local ok, n = pcall(C_Spell.GetSpellName, id); if ok and n then return n end end
    if GetSpellInfo then local ok, n = pcall(GetSpellInfo, id); if ok and n then return n end end
    return "Teleport: " .. (Travel.TELEPORTS[id] or "?")
end

-- Hearthstone: in your bags and off cooldown?
function Travel:HearthReady()
    local count = PC.BagCount and PC:BagCount(self.HEARTH_ITEM) or 0
    if count <= 0 and GetItemCount then count = GetItemCount(self.HEARTH_ITEM) or 0 end
    if count <= 0 then return false end
    return ItemCooldownLeft(self.HEARTH_ITEM) <= 0
end

-- Where the hearthstone lands: learned the last time you used it (same inn), else the innkeeper you
-- bound at, else nil
function Travel:HearthSpot()
    local bind = GetBindLocation and GetBindLocation() or nil
    local a = PC.cdb and PC.cdb.hearthArrive
    if a and (not bind or a.bind == bind) then return a, bind end
    if bind then
        for _, p in ipairs(Places:OfKind("inn")) do
            if p.sub == bind or p.zone == bind then return p, bind end
        end
    end
    return nil, bind
end

-- Where a teleport lands: learned when you used it, else any place you know in that city
function Travel:TeleportSpot(id)
    local learned = PC.cdb and PC.cdb.teleArrive and PC.cdb.teleArrive[id]
    if learned then return learned end
    local city = self.TELEPORTS[id]
    if not city then return nil end
    for _, kind in ipairs({ "ah", "bank", "mail", "inn", "flight" }) do
        for _, p in ipairs(Places:OfKind(kind)) do
            if p.zone == city or (p.zone or ""):find(city, 1, true) then return p end
        end
    end
    -- nothing known there yet: the middle of the city (learned for real the first time you use it)
    local map = PC.ToLearn and PC.ToLearn.ZoneMap and PC.ToLearn:ZoneMap(city)
    if map then return { map = map, x = 0.5, y = 0.5, zone = city, name = city, kind = "spot" } end
    return nil
end

---------------------------------------------------------------------------
-- The quickest way there: a small shortest-path search over walking, flights, hearthstone,
-- teleports and the portals/boats you (or other users) have taken
---------------------------------------------------------------------------
-- returns { secs, steps = { {how, text, to} ... }, first = point to head for } or nil
---------------------------------------------------------------------------
-- Flight paths you know (this character): only those can be flown TO. You can always walk to a
-- flight master you haven't met (talking to it learns it) and fly on from there.
---------------------------------------------------------------------------
function Travel:KnownTaxi()
    PC.cdb.knownTaxi = PC.cdb.knownTaxi or {}
    return PC.cdb.knownTaxi
end

function Travel:IsKnownFP(p)
    if not p then return false end
    local k = self:KnownTaxi()
    if p.taxiName and k[p.taxiName] then return true end
    -- a flight master you've opened the flight map at yourself: you learned it right there
    if p.kind == "flight" and p.mine then return true end
    return false
end

-- Every flight master on your side of the war, from the game's own map data (names as the flight
-- map shows them), plus the ones you've visited. Worked out once a session.
function Travel:FlightNodes()
    if self.fpCache and self.fpCache.n > 0 and GetTime() - self.fpCache.t < 600 then return self.fpCache.list end
    local list, n = {}, 0
    local mine = UnitFactionGroup and UnitFactionGroup("player") or nil
    local myFac = (mine == "Horde" and 1) or (mine == "Alliance" and 2) or nil
    for _, p in pairs(Places:All()) do
        if p.kind == "flight" and p.map then list[#list + 1] = p; n = n + 1 end
    end
    local T = C_TaxiMap
    if T and T.GetTaxiNodesForMap and C_Map and C_Map.GetMapInfo and C_Map.GetMapChildrenInfo and C_Map.GetBestMapForUnit then
        -- the continents: up from where you are to the world, then its continents
        local top, guard = C_Map.GetBestMapForUnit("player"), 0
        while top and guard < 10 do
            guard = guard + 1
            local info = C_Map.GetMapInfo(top)
            if not info or not info.parentMapID or info.parentMapID == 0 then break end
            top = info.parentMapID
        end
        local conts = {}
        if top then
            local ok, kids = pcall(C_Map.GetMapChildrenInfo, top, nil, true)
            for _, k in ipairs(ok and kids or {}) do if k.mapType == 2 then conts[#conts + 1] = k.mapID end end
            if #conts == 0 then conts[1] = top end
        end
        for _, cm in ipairs(conts) do
            local ok, nodes = pcall(T.GetTaxiNodesForMap, cm)
            for _, node in ipairs(ok and type(nodes) == "table" and nodes or {}) do
                local fac = node.faction
                if node.position and node.name and (not myFac or not fac or fac == 0 or fac == myFac) then
                    local x, y = node.position.x, node.position.y
                    if (x == nil or y == nil) and node.position.GetXY then x, y = node.position:GetXY() end
                    if x and y then
                        local pt = { kind = "flight", api = true, map = cm, x = x, y = y, name = node.name, taxiName = node.name,
                            zone = (node.name:match(",%s*(.+)$")) or node.name, mine = false }
                        -- the same one you've visited: keep yours, and teach it the flight map's name
                        local dup
                        for _, p in ipairs(list) do
                            if not p.api then
                                local yd = self:Yards(p, pt)
                                if yd and yd < 80 then dup = p break end
                            end
                        end
                        if dup then dup.taxiName = dup.taxiName or node.name
                        else list[#list + 1] = pt; n = n + 1 end
                    end
                end
            end
        end
    end
    self.fpCache = { list = list, n = n, t = GetTime() }
    return list
end

---------------------------------------------------------------------------
-- Boats, zeppelins and the tram the world has always had (classic): dock to dock, both ways.
-- Ones you've taken yourself are learned and shared too, and win when they're quicker.
---------------------------------------------------------------------------
Travel.TRANSPORTS = {
    -- Horde zeppelins
    { "Durotar", 50.8, 13.6, "Tirisfal Glades", 60.8, 58.8, 120, "zeppelin", "H" },
    { "Durotar", 50.6, 12.6, "Stranglethorn Vale", 31.4, 30.2, 120, "zeppelin", "H" },
    { "Tirisfal Glades", 61.9, 59.1, "Stranglethorn Vale", 31.6, 29.2, 120, "zeppelin", "H" },
    -- the goblin boat (both sides)
    { "Stranglethorn Vale", 25.8, 73.2, "The Barrens", 63.6, 38.6, 110, "boat", "AH" },
    -- Alliance boats and the tram
    { "Wetlands", 4.7, 57.2, "Darkshore", 32.3, 43.6, 110, "boat", "A" },
    { "Wetlands", 5.0, 63.4, "Dustwallow Marsh", 71.6, 56.4, 110, "boat", "A" },
    { "Darkshore", 33.3, 40.2, "Teldrassil", 55.6, 92.0, 90, "boat", "A" },
    { "Stormwind City", 63.8, 8.0, "Ironforge", 76.6, 51.0, 70, "tram", "A" },
}

function Travel:TransportLinks()
    if self.tlCache then return self.tlCache end
    local out = {}
    -- Retail: these docks moved long ago (Orgrimmar's zeppelins are inside the city now); only the
    -- ones you've really taken (learned, and shared) are used there
    if not PC.FOREVER then self.tlCache = out; return out end
    local mine = UnitFactionGroup and UnitFactionGroup("player") or ""
    local letter = (mine == "Horde" and "H") or (mine == "Alliance" and "A") or nil
    local zm = PC.ToLearn and PC.ToLearn.ZoneMap
    if not zm then return out end
    local ok = true
    for _, t in ipairs(self.TRANSPORTS) do
        if not letter or t[9]:find(letter, 1, true) then
            local m1, m2 = zm(PC.ToLearn, t[1]), zm(PC.ToLearn, t[4])
            if m1 and m2 then
                local a = { map = m1, x = t[2] / 100, y = t[3] / 100, zone = t[1], name = "the " .. t[8] .. " to " .. t[4], kind = "dock", how = t[8] }
                local b = { map = m2, x = t[5] / 100, y = t[6] / 100, zone = t[4], name = "the " .. t[8] .. " to " .. t[1], kind = "dock", how = t[8] }
                out[#out + 1] = { from = a, to = b, secs = t[7], how = t[8], name = "the " .. t[8] .. " to " .. t[4] }
                out[#out + 1] = { from = b, to = a, secs = t[7], how = t[8], name = "the " .. t[8] .. " to " .. t[1] }
            else
                ok = false
            end
        end
    end
    if ok and #out > 0 then self.tlCache = out end -- (the map list isn't there yet early on: try again later)
    return out
end

---------------------------------------------------------------------------
-- Undercity, the Ruins of Lordaeron and Thunder Bluff (the same as SnuggleUp Forever):
--   three areas round Undercity: outside (Tirisfal Glades), the Ruins of Lordaeron (on top of the city:
--   the game says Undercity's map up there, but the subzone says Ruins of Lordaeron) and inside.
--   Walking only goes between spots in the same area. The Ruins entrance joins outside and the Ruins;
--   the elevators join the Ruins and inside (top and bottom are the same spot on the map). Thunder
--   Bluff: the elevators join Mulgore (outside, at the bottom) and the city up on the mesas.
--   No zone crossings between a city and the zone round it: the elevator (and the Ruins entrance) only.
---------------------------------------------------------------------------
Travel.CITY_MAPS = { [1458] = "Undercity", [1456] = "Thunder Bluff" }
Travel.CITY_OUTER = { [1458] = 1420, [1456] = 1412 }          -- Undercity -> Tirisfal Glades, Thunder Bluff -> Mulgore
Travel.OUTER_NAME = { ["Undercity"] = "Tirisfal Glades", ["Thunder Bluff"] = "Mulgore" }
Travel.RUINS = "Ruins of Lordaeron"
Travel.LIFT_SECS = 25        -- an elevator ride, waiting included
Travel.SKIP_WALK = 20        -- yards: a walk this short (to the flight master, the dock) isn't a step
Travel.CROSS_PENALTY = 2.5   -- walking straight from one zone into another (off the roads): the roads win
-- Cities: leaving one on foot reads "Leave Orgrimmar for Durotar"
Travel.CITIES = { [1454] = true, [1453] = true, [1455] = true, [1456] = true, [1458] = true, [1457] = true }

-- Zone levels (classic): walking through a zone well above your level costs a lot more, so the route
-- goes round it (or flies) whenever it can. { lowest level, highest }
Travel.ZONE_LEVELS = {
    [1411] = { 1, 10 }, [1412] = { 1, 10 }, [1438] = { 1, 10 }, [1439] = { 10, 20 }, [1413] = { 10, 25 },
    [1442] = { 15, 27 }, [1440] = { 18, 30 }, [1441] = { 25, 35 }, [1443] = { 30, 40 }, [1445] = { 35, 45 },
    [1444] = { 40, 50 }, [1446] = { 40, 50 }, [1447] = { 45, 55 }, [1448] = { 48, 55 }, [1449] = { 48, 55 },
    [1451] = { 55, 60 }, [1452] = { 55, 60 },
    [1429] = { 1, 10 }, [1426] = { 1, 10 }, [1420] = { 1, 10 }, [1436] = { 10, 20 }, [1432] = { 10, 20 },
    [1421] = { 10, 20 }, [1433] = { 15, 25 }, [1431] = { 18, 30 }, [1437] = { 20, 30 }, [1424] = { 20, 30 },
    [1416] = { 30, 40 }, [1417] = { 30, 40 }, [1434] = { 30, 45 }, [1418] = { 35, 45 }, [1435] = { 35, 45 },
    [1425] = { 40, 50 }, [1427] = { 43, 50 }, [1419] = { 45, 55 }, [1428] = { 50, 58 }, [1422] = { 51, 58 },
    [1423] = { 53, 60 },
}
Travel.DANGER_LEVELS = 3     -- a zone whose lowest level is more than this above yours is dangerous
Travel.DANGER_PENALTY = 4    -- and walking in it costs this many times more

function Travel:Dangerous(zm, safe)
    local lv = self.ZONE_LEVELS[zm]
    if not lv or (safe and safe[zm]) then return false end
    local me = UnitLevel and UnitLevel("player") or 60
    return lv[1] > me + self.DANGER_LEVELS
end

-- a city pair (Tirisfal/Undercity, Mulgore/Thunder Bluff): never a zone crossing
function Travel:CityPair(a, b)
    return (self.CITY_OUTER[a] ~= nil and self.CITY_OUTER[a] == b) or (self.CITY_OUTER[b] ~= nil and self.CITY_OUTER[b] == a)
end

-- for zone comparisons: Undercity counts as Tirisfal Glades, Thunder Bluff as Mulgore
function Travel:OuterZone(name)
    return name and (self.OUTER_NAME[name] or name) or nil
end

local function SubZone() return GetSubZoneText and GetSubZoneText() or "" end
local function MinimapZone() return GetMinimapZoneText and GetMinimapZoneText() or "" end

-- up in the Ruins of Lordaeron (on top of Undercity: still outside)
function Travel:InRuins()
    return SubZone() == self.RUINS or MinimapZone() == self.RUINS
end

-- The Ruins entrance: { tx, ty (Tirisfal), ux, uy (Undercity's map) }, learned (yours, a crossing you
-- walked, or other users'), else nil (not known yet: the Ruins then count as plain outside)
-- (the gate from Tirisfal Glades into the courtyard: used until yours, or anyone's, is known)
Travel.RUINS_GATE = { tx = 0.6189, ty = 0.6482, ux = 0.6639, uy = 0.0014, from = "built in" }
function Travel:RuinsEntrance()
    local r = PC.db and PC.db.ruinsEntrance
    -- one "learned" at the top of an elevator isn't the entrance (riding up also turns the minimap
    -- name to Ruins of Lordaeron): thrown away
    if r and r.ux then
        for _, e in ipairs(self:Elevators(1458)) do
            if math.abs(e.x - r.ux) < 0.03 and math.abs(e.y - r.uy) < 0.03 then
                PC.db.ruinsEntrance = nil
                r = nil
                self.wayCache = nil
                break
            end
        end
    end
    if r and r.tx and r.ux then return r end
    local ex = Places.Exits and Places:Exits() or {}
    for _, e in ipairs(ex[1420] or {}) do
        if e.to == 1458 and e.x and e.tx then return { tx = e.x, ty = e.y, ux = e.tx, uy = e.ty, from = "crossing" } end
    end
    for _, e in ipairs(ex[1458] or {}) do
        if e.to == 1420 and e.x and e.tx then return { tx = e.tx, ty = e.ty, ux = e.x, uy = e.y, from = "crossing" } end
    end
    local found
    if Places.MNBEach then
        -- (thousands of shared places: looked through again only when they change, not for every route)
        local c = self.ruinsShared
        if c and Places.mnbListening and c.rev == Places.mnbRev then
            found = c.found
        else
            Places:MNBEach("cross", function(_, p)
                if found or type(p) ~= "table" then return end
                local m, to = tonumber(p.m), tonumber(p.to)
                local x, y, x2, y2 = tonumber(p.x), tonumber(p.y), tonumber(p.x2), tonumber(p.y2)
                if not (x and y and x2 and y2) then return end
                if m == 1420 and to == 1458 then found = { tx = x, ty = y, ux = x2, uy = y2, from = "shared" }
                elseif m == 1458 and to == 1420 then found = { tx = x2, ty = y2, ux = x, uy = y, from = "shared" } end
            end)
            self.ruinsShared = { rev = Places.mnbRev, found = found }
        end
    end
    return found or self.RUINS_GATE
end

-- Learning the Ruins entrance: once a second, the minimap name turning to "Ruins of Lordaeron" from
-- something else = you just walked in: where you stood a second ago is the entrance
function Travel:WatchRuins()
    local mm = MinimapZone()
    local map, x, y = Places:Here()
    local last = self.ruinsLast
    self.ruinsLast = { mm = mm, map = map, x = x, y = y }
    if not last or not last.map or not last.x or mm ~= self.RUINS or last.mm == self.RUINS or last.mm == "" then return end
    -- only when you walked in from Tirisfal Glades: coming up the elevator from inside the city also
    -- changes the name, and that spot is an elevator, not the entrance
    if last.map ~= 1420 then return end
    local c, wx, wy = self:World(last.map, last.x, last.y)
    if not c or not C_Map or not C_Map.GetMapPosFromWorldPos or not CreateVector2D then return end
    local function on(m)
        local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, c, CreateVector2D(wx, wy), m)
        if not ok or not pos then return nil end
        local px, py = pos.x, pos.y
        if (px == nil or py == nil) and pos.GetXY then px, py = pos:GetXY() end
        return px, py
    end
    local tx, ty = on(1420)
    local ux, uy = on(1458)
    if not tx or not ux then return end
    PC.db.ruinsEntrance = { tx = tx, ty = ty, ux = ux, uy = uy, t = time() }
    self.wayCache = nil
end

-- which area a spot is in: "out", "uctop" (the Ruins), "ucin" (inside Undercity) or "tbin" (Thunder Bluff)
function Travel:SideHere(map)
    local zt = GetRealZoneText and GetRealZoneText() or ""
    if map == 1458 then
        if self:InRuins() then return self:RuinsEntrance() and "uctop" or "out" end
        if zt ~= "" and zt ~= "Undercity" then return "out" end
        return "ucin"
    elseif map == 1456 then
        if zt ~= "" and zt ~= "Thunder Bluff" then return "out" end
        -- the bottom of Thunder Bluff's lifts is the same map, the same zone name and the same spot
        -- on the map as the top. Height tells them apart where the game gives it; failing that, the
        -- lift you were last seen riding.
        local cdb = PC.cdb
        local t = cdb and cdb.tbZ
        local z = self:HeightHere()
        if z and t and t.hi and t.lo and (t.hi - t.lo) > 40 then
            return (z > (t.hi + t.lo) / 2) and "tbin" or "out"
        end
        if cdb and cdb.liftSide and cdb.liftAt and (time() - cdb.liftAt) < 3600 then return cdb.liftSide end
        return "tbin"
    end
    return "out"
end
function Travel:SideOf(nd)
    if not nd then return "out" end
    if nd.side then return nd.side end
    if nd.map == 1458 then return "ucin" end
    if nd.map == 1456 then return "tbin" end
    local nm = nd.taxiName or (nd.kind == "flight" and nd.name) or ""
    if nm:find("^Undercity") then return "ucin" end
    if nm:find("^Thunder Bluff") then return "tbin" end
    return "out"
end

---------------------------------------------------------------------------
-- The travel graph: you, your stops, flight masters, docks and portals, the roads between zones,
-- the elevators and the Ruins entrance. Edges are worked out as they're needed: walking (in the same
-- area), flying (to a flight path you know), boats and portals, and from where you stand only, your
-- hearthstone and teleports.
---------------------------------------------------------------------------
-- The part of the graph that doesn't depend on where you are or where you're going (flight masters, docks
-- and boats, the roads between zones, the Ruins entrance) is made once and kept until any of it changes.
-- Making it was half of every route, and its spots were new each time, so where each one is in the world
-- was asked of the game again for every route. The same spots, in the same order as before.
function Travel:StaticGraph()
    local fpList = self:FlightNodes()
    local all = Places:All()
    local exits = Places.AllExits and Places:AllExits() or {}
    local tl = self:TransportLinks()
    local ruins = self:RuinsEntrance()
    local rx, ry, ux, uy = ruins and ruins.tx, ruins and ruins.ty, ruins and ruins.ux, ruins and ruins.uy
    local c = self.staticGraph
    if c and c.fpList == fpList and c.all == all and c.placesRev == Places.rev and c.exits == exits
        and c.exitsRev == Places.exitsRev and c.tl == tl and c.rx == rx and c.ry == ry and c.ux == ux and c.uy == uy then
        return c
    end
    local g = { nodes = {}, fp = {}, links = {} }
    local function add(pt) g.nodes[#g.nodes + 1] = pt; return #g.nodes end
    for _, p in ipairs(fpList) do
        local i = add(p)
        g.fp[i] = self:IsKnownFP(p) and "known" or "new"
    end
    for _, p in pairs(all) do
        if p.kind == "link" and p.tomap and not self:CityPair(p.map, p.tomap) then
            p.toPt = p.toPt or { map = p.tomap, x = p.tox, y = p.toy, zone = p.tozone, name = p.tozone or "the other side" }
            local secs = p.secs or 10
            local how = secs > 30 and "boat" or "portal"
            -- a crossing someone took that starts at a known zeppelin or boat dock and lands on the
            -- same continent as it: that IS the zeppelin (or boat), so it's called that and timed like
            -- it - not "the portal" (a loading screen made the trip look instant)
            local bestD, dockTo
            for _, l in ipairs(self:TransportLinks()) do
                local d = self:Yards(p, l.from)
                if d and d <= 150 and self:Yards(p.toPt, l.to) and (not bestD or d < bestD) then
                    bestD, how, secs, dockTo = d, l.how, l.secs, l.to.zone
                end
            end
            -- only a real ride counts: one that starts at a known dock, or a long crossing that you
            -- took yourself or that has been confirmed. A sudden short hop is a hearthstone, a
            -- summon or a trip to the graveyard, not something you can walk up to and take.
            if bestD or ((p.secs or 0) > 30 and (p.mine or p.confirmed)) then
                local toName = dockTo or ((p.tozone and p.tozone ~= "") and p.tozone) or "the other side"
                local a = { kind = "dock", how = how, map = p.map, x = p.x, y = p.y, zone = p.zone, name = "the " .. how }
                g.links[#g.links + 1] = { from = add(a), to = add(p.toPt), secs = secs + (secs > 30 and self.BOAT_WAIT or 0), how = how,
                    text = ("Take the %s to %s"):format(how, toName) }
            end
        end
    end
    for _, l in ipairs(tl) do
        g.links[#g.links + 1] = { from = add(l.from), to = add(l.to), secs = l.secs + self.BOAT_WAIT, how = l.how,
            text = ("Take the %s to %s"):format(l.how, l.to.zone or "the other side") }
    end
    -- zone crossings (the roads and gates between zones): one per pair of zones (your own first, then
    -- the most recent). Walking from one zone into another goes through these.
    g.roads, g.roadZones = {}, {}
    local pairSeen = {}
    local zm = PC.ToLearn and PC.ToLearn.ZoneMap
    for m, list in pairs(exits) do
        local best = {}
        for _, e in ipairs(list) do
            if not self:CityPair(m, e.to) then
                local b = best[e.to]
                if not b or (b.starter and not e.starter) or (not e.starter and (e.seen or 0) > (b.seen or 0)) then best[e.to] = e end
            end
        end
        for to, e in pairs(best) do
            if not pairSeen[m .. ":" .. to] and e.tx then
                pairSeen[m .. ":" .. to] = true
                g.roads[m .. ":" .. to] = true
                g.roadZones[m], g.roadZones[to] = true, true
                local toInfo = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(to)
                local fromInfo = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(m)
                local toName = (e.zone and e.zone ~= "") and e.zone or (toInfo and toInfo.name) or "the next zone"
                local a = { map = m, x = e.x, y = e.y, kind = "cross", zone = toName, name = "the way into " .. toName,
                    toName = toName, fromName = fromInfo and fromInfo.name, fromCity = self.CITIES[m] }
                local b = { map = to, x = e.tx, y = e.ty, kind = "cross2", zone = toName }
                g.links[#g.links + 1] = { from = add(a), to = add(b), secs = 3, how = "cross" }
            end
        end
    end
    -- the Ruins entrance: outside (Tirisfal) and the Ruins (on top of Undercity), both ways
    if ruins then
        local o = add({ kind = "ruins", ruins = "in", map = 1420, x = ruins.tx, y = ruins.ty, side = "out", name = "the Ruins of Lordaeron" })
        local t = add({ kind = "ruins", ruins = "out", map = 1458, x = ruins.ux, y = ruins.uy, side = "uctop", name = "the Ruins of Lordaeron" })
        g.links[#g.links + 1] = { from = o, to = t, secs = 3, how = "ruins" }
        g.links[#g.links + 1] = { from = t, to = o, secs = 3, how = "ruins" }
    end
    g.side = {}
    for i, nd in ipairs(g.nodes) do g.side[i] = self:SideOf(nd) end
    g.ruins = ruins and true or false
    g.fpList, g.all, g.placesRev, g.exits, g.exitsRev, g.tl = fpList, all, Places.rev, exits, Places.exitsRev, tl
    g.rx, g.ry, g.ux, g.uy = rx, ry, ux, uy
    self.staticGraph = g
    return g
end

function Travel:Graph(start, stops)
    local g = { nodes = { start }, fp = {}, links = {}, start = 1, stops = {}, side = {} }
    local function add(pt) g.nodes[#g.nodes + 1] = pt; return #g.nodes end
    start.side = start.side or self:SideHere(start.map)
    for k, st in ipairs(stops or {}) do g.stops[k] = add(st) end
    -- the fixed part (see StaticGraph), after you and your stops
    local sg = self:StaticGraph()
    local base, ns = #g.nodes, #sg.nodes
    for i = 1, ns do g.nodes[base + i] = sg.nodes[i] end
    for i, kind in pairs(sg.fp) do g.fp[base + i] = kind end
    for _, l in ipairs(sg.links) do
        g.links[#g.links + 1] = { from = base + l.from, to = base + l.to, secs = l.secs, how = l.how, text = l.text }
    end
    g.roads, g.roadZones = sg.roads, sg.roadZones
    local ruins = sg.ruins
    -- the elevators, both ways: the inside end and the outside end are the same spot on the map
    for _, ec in ipairs({ 1458, 1456 }) do
        local spots = {}
        local function have(m, x, y)
            for _, s in ipairs(spots) do if math.abs(s.x - x) < 0.015 and math.abs(s.y - y) < 0.015 and s.map == m then return true end end
        end
        local maps = ec == 1458 and { 1458 } or { 1456, 1412 }
        for _, m in ipairs(maps) do
            for _, e in ipairs(self:Elevators(m)) do
                if e.x and e.y and not have(m, e.x, e.y) then spots[#spots + 1] = { map = m, x = e.x, y = e.y, mine = e.mine } end
            end
        end
        -- elevators you marked or rode yourself are the city's elevators: nothing else is considered,
        -- on either map (the ones other players sent in are often a bridge or an innkeeper)
        local mine = {}
        for _, p in ipairs(spots) do if p.mine then mine[#mine + 1] = p end end
        if #mine > 0 then spots = mine end
        -- a city has several elevators: when you're standing on its map, the one closest to you is the
        -- one to take (not one across the city that happens to shave the walk on the other side)
        local near, nearD
        for _, p in ipairs(spots) do
            if p.map == start.map and start.x and start.y then
                local d = (p.x - start.x) ^ 2 + (p.y - start.y) ^ 2
                if not nearD or d < nearD then near, nearD = p, d end
            end
        end
        if near then spots = { near } end
        local cname = self.CITY_MAPS[ec]
        local inSide = ec == 1458 and "ucin" or "tbin"
        local outSide = ec == 1458 and (ruins and "uctop" or "out") or "out"
        local outWay, inWay = ec == 1458 and "up" or "down", ec == 1458 and "down" or "up"
        for _, p in ipairs(spots) do
            local ii = add({ kind = "lift", map = p.map, x = p.x, y = p.y, side = inSide, name = "the elevator" })
            local io = add({ kind = "lift", map = p.map, x = p.x, y = p.y, side = outSide, name = "the elevator" })
            g.links[#g.links + 1] = { from = ii, to = io, secs = self.LIFT_SECS, how = "lift", text = "Take the elevator " .. outWay }
            g.links[#g.links + 1] = { from = io, to = ii, secs = self.LIFT_SECS, how = "lift", text = ("Take the elevator %s into %s"):format(inWay, cname) }
        end
    end
    g.out = {}
    for _, l in ipairs(g.links) do g.out[l.from] = g.out[l.from] or {}; table.insert(g.out[l.from], l) end
    -- hearthstone and your own teleports: where they land (used only from where you stand right now)
    -- (never to the zone you're in: across it you walk, however far, and the cooldown is kept)
    g.jumps = {}
    local function away(spot)
        if not spot then return false end
        if spot.map and start.map and spot.map == start.map then return false end
        if spot.zone and spot.zone ~= "" and start.zone and spot.zone == start.zone then return false end
        return true
    end
    -- a stop in the zone you're in: walked to, never reached by jumping out and walking back
    local home = false
    for _, st in ipairs(stops or {}) do if st and not away(st) then home = true break end end
    if PC:RouteOn() and not home then
        if self:HearthReady() then
            local spot, bind = self:HearthSpot()
            if away(spot) then g.jumps[#g.jumps + 1] = { j = add(spot), secs = self.CAST + 5, how = "hearth", text = bind } end
        end
        for id in pairs(self.TELEPORTS) do
            if SpellReady(id) then
                local spot = self:TeleportSpot(id)
                if away(spot) then g.jumps[#g.jumps + 1] = { j = add(spot), secs = self.CAST + 5, how = "teleport", text = SpellName(id) } end
            end
        end
    end
    for i, nd in ipairs(g.nodes) do
        if i == 1 then g.side[i] = start.side
        elseif i > base and i <= base + ns then g.side[i] = sg.side[i - base]
        else g.side[i] = self:SideOf(nd) end
    end
    -- the stops' zones are never "too dangerous" (you're going there)
    g.safe = {}
    return g
end

-- the zone a node is in (a city counts as the zone round it); flight paths are on the whole-continent
-- map: the game says which zone that spot falls in
function Travel:ZoneOfNode(nd)
    if not nd then return nil end
    if nd.zm ~= nil then return nd.zm or nil end
    local cache = self.zoneTypeCache or {}
    self.zoneTypeCache = cache
    local function isZone(m)
        if not m then return false end
        local z = cache[m]
        if z == nil then
            local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(m)
            z = info and info.mapType and info.mapType >= 3 or false
            cache[m] = z
        end
        return z
    end
    local zm = false
    if isZone(nd.map) then zm = nd.map
    elseif nd.map and C_Map and C_Map.GetMapInfoAtPosition then
        local ok, info = pcall(C_Map.GetMapInfoAtPosition, nd.map, nd.x, nd.y)
        if ok and info and info.mapID and isZone(info.mapID) then zm = info.mapID end
    end
    if zm and self.CITY_OUTER[zm] then zm = self.CITY_OUTER[zm] end
    nd.zm = zm
    return zm or nil
end

-- quickest times from node src to every node: dist[i], prev[i] = { from, how, text }
-- (fromHere: your hearthstone and teleports can be used for this leg; g.strict: zones that both have
-- known roads are only crossed by road)
-- (`want`: the one stop that matters; the search ends as soon as the way to it is settled.
-- Everything that doesn't change during a search - where each spot is in the world, its zone, which
-- zones are joined by road, which are dangerous - is worked out once, not for every pair of spots:
-- this search was most of the freeze each time the route was worked out.)
function Travel:Dijkstra(g, src, fromHere, want)
    local nodes, speed = g.nodes, self:Speed()
    local n = #nodes
    local wc, wx, wy, zone = g._wc, g._wx, g._wy, g._zone
    local byCont, byMap, byMapNoPos = g._byCont, g._byMap, g._byMapNoPos
    if not wc or g._n ~= n then
        wc, wx, wy, zone = {}, {}, {}, {}
        -- the spots each spot can have a distance to (nothing else is ever a walk or a flight): the same
        -- continent, or the same map where the game gives no world position. Only those are looked at.
        byCont, byMap, byMapNoPos = {}, {}, {}
        for i = 1, n do
            local nd = nodes[i]
            local c, x, y = W(nd)
            wc[i], wx[i], wy[i] = c or false, x, y
            zone[i] = self:ZoneOfNode(nd) or false
            local m = nd.map
            if c then
                local l = byCont[c]
                if not l then l = {}; byCont[c] = l end
                l[#l + 1] = i
            elseif m then
                local l = byMapNoPos[m]
                if not l then l = {}; byMapNoPos[m] = l end
                l[#l + 1] = i
            end
            if m then
                local l = byMap[m]
                if not l then l = {}; byMap[m] = l end
                l[#l + 1] = i
            end
        end
        g._wc, g._wx, g._wy, g._zone, g._n = wc, wx, wy, zone, n
        g._byCont, g._byMap, g._byMapNoPos = byCont, byMap, byMapNoPos
        g._roadPair = {}
    end
    local dist, prev, done = { [src] = 0 }, {}, {}
    -- the spots still to settle, nearest first (a small heap: picking the nearest used to mean a look
    -- through every spot reached so far, for every spot settled); equally near: the lower number first
    local hd, hj, hn = {}, {}, 0
    local function push(d, j)
        hn = hn + 1
        local i = hn
        while i > 1 do
            local p = (i - i % 2) / 2
            local pd, pj = hd[p], hj[p]
            if pd < d or (pd == d and pj < j) then break end
            hd[i], hj[i] = pd, pj
            i = p
        end
        hd[i], hj[i] = d, j
    end
    local function pop()
        if hn == 0 then return nil end
        local tj, td = hj[1], hd[1]
        local ld, lj = hd[hn], hj[hn]
        hd[hn], hj[hn] = nil, nil
        hn = hn - 1
        if hn > 0 then
            local i = 1
            while true do
                local c = i * 2
                if c > hn then break end
                if c < hn and (hd[c + 1] < hd[c] or (hd[c + 1] == hd[c] and hj[c + 1] < hj[c])) then c = c + 1 end
                if ld < hd[c] or (ld == hd[c] and lj < hj[c]) then break end
                hd[i], hj[i] = hd[c], hj[c]
                i = c
            end
            hd[i], hj[i] = ld, lj
        end
        return tj, td
    end
    push(0, src)
    local function relax(u, j, secs, how, text)
        local nd = dist[u] + secs
        if not dist[j] or nd < dist[j] - 0.01 then
            dist[j], prev[j] = nd, { from = u, how = how, text = text }
            push(nd, j)
        end
    end
    if fromHere then for _, x in ipairs(g.jumps or {}) do relax(src, x.j, x.secs, x.how, x.text) end end
    local safe = { [zone[src] or 0] = true }
    for _, k in ipairs(g.stops or {}) do local z = zone[k]; if z then safe[z] = true end end
    local dang = {}
    local function danger(z)
        local d = dang[z]
        if d == nil then d = self:Dangerous(z, safe) and true or false; dang[z] = d end
        return d
    end
    local roadPair, roads = g._roadPair, g.roads
    local function road(za, zb)
        local t = roadPair[za]
        if not t then t = {}; roadPair[za] = t end
        local v = t[zb]
        if v == nil then v = (roads and roads[za .. ":" .. zb]) and true or false; t[zb] = v end
        return v
    end
    local sides, fp, strict, roadZones = g.side, g.fp, g.strict, g.roadZones
    local BEND, CROSS, DANGER, FP_STOP, FLY = self.BEND, self.CROSS_PENALTY, self.DANGER_PENALTY, self.FP_STOP, self.FLY_SPEED
    local sqrt = math.sqrt
    while true do
        local u, du = pop()
        while u and (done[u] or du ~= dist[u]) do u, du = pop() end -- (older, longer ways since bettered: passed over)
        if not u then break end
        done[u] = true
        if want and u == want then break end -- the way to the stop is settled: nothing further is needed
        local a = nodes[u]
        local side = sides[u]
        -- a zone crossing's start is only for crossing: no walking on from it (so a step never reads
        -- "Head into Duskwood" while you're leaving Duskwood)
        if a.kind ~= "cross" then
            local fpu = fp[u]
            local cu, xu, yu = wc[u], wx[u], wy[u]
            local za = zone[u] or nil
            local list1, list2
            if cu then list1, list2 = byCont[cu], a.map and byMapNoPos[a.map]
            else list1 = a.map and byMap[a.map] end
            for pass = 1, 2 do
                local list = (pass == 1 and list1 or list2) or NONE
                for k = 1, #list do
                    local j = list[k]
                    if j ~= u and not done[j] then
                        -- walking only between spots in the same area (inside / outside / the Ruins); a
                        -- flight only between flight masters: anything else isn't worth measuring
                        local sameSide = side == sides[j]
                        local canFly = fpu and fp[j] == "known"
                        if sameSide or canFly then
                            local b = nodes[j]
                            local y
                            local cj = wc[j]
                            if cu and cj then
                                if cu == cj then local dx, dy = xu - wx[j], yu - wy[j]; y = sqrt(dx * dx + dy * dy) end
                            else
                                y = self:Yards(a, b)
                            end
                            if y then
                                if sameSide then
                                    local walk = y * BEND / speed
                                    local zb = zone[j] or nil
                                    -- two zones joined by a known road: by the road, never straight over the hills
                                    local offRoad = za and zb and za ~= zb and road(za, zb)
                                    -- by roads first: zones that both have known roads are only crossed by road
                                    if not offRoad and strict and za and zb and za ~= zb and roadZones and roadZones[za] and roadZones[zb] then
                                        offRoad = true
                                    end
                                    if offRoad then walk = nil
                                    elseif (za and zb and za ~= zb) or ((not za or not zb) and a.map ~= b.map and not self:CityPair(a.map, b.map)) then
                                        walk = walk * CROSS
                                    end
                                    if walk and ((za and danger(za)) or (zb and danger(zb))) then
                                        walk = walk * DANGER
                                    end
                                    if walk then relax(u, j, walk, "walk") end
                                end
                                -- a flight: from any flight master of yours (one you walk up to is learned on the
                                -- spot) to one you already know
                                if canFly and y > 300 then
                                    relax(u, j, FP_STOP + y * BEND / FLY, "fly")
                                end
                            end
                        end
                    end
                end
            end
        end
        for _, l in ipairs(g.out[u] or NONE) do relax(u, l.to, l.secs, l.how, l.text) end
    end
    return dist, prev
end

-- by roads first; only when no way by roads is known (to the stop wanted, or to any of the stops),
-- straight across between zones
function Travel:DijkstraRoads(g, src, fromHere, want)
    g.strict = true
    local dist, prev = self:Dijkstra(g, src, fromHere, want)
    g.strict = nil
    local ok = true
    if want then ok = dist[want] ~= nil
    else for _, k in ipairs(g.stops or {}) do if not dist[k] then ok = false end end end
    if ok then return dist, prev end
    return self:Dijkstra(g, src, fromHere, want)
end

-- the zone a walk starts in: where you are, or where the last step left you (raw, and as compared)
local function FromZone(from)
    if not from then return nil end
    if from.name == "you" then
        local z = GetRealZoneText and GetRealZoneText()
        if z and z ~= "" then return z end
    end
    return Travel:ZoneOf(from)
end

-- dist/prev into the steps of one leg: { how, text, label, to, from, yd }
function Travel:Steps(g, prev, at, dest)
    local path = {}
    while prev[at] do
        local pv = prev[at]
        table.insert(path, 1, { to = g.nodes[at], how = pv.how, text = pv.text, from = g.nodes[pv.from] })
        at = pv.from
    end
    -- a walk that only passes a dock or flight master on the way (not one you use) is one walk;
    -- walks through zone crossings (and the Ruins entrance) stay separate steps
    local merged = {}
    for _, leg in ipairs(path) do
        local last = merged[#merged]
        if last and last.how == "walk" and leg.how == "walk" and last.to.kind ~= "cross" and last.to.kind ~= "ruins" then
            merged[#merged] = { to = leg.to, from = last.from, how = "walk" }
        else
            merged[#merged + 1] = leg
        end
    end
    local steps = {}
    for _, leg in ipairs(merged) do
        local how, to = leg.how, leg.to
        local text, label
        if how == "walk" then
            local yd = self:Yards(leg.from, to)
            local ydText = (yd and yd < 1e6) and (" (%d yd)"):format(math.floor(yd + 0.5)) or ""
            local first = leg.from and leg.from.name == "you"
            local fromZone = FromZone(leg.from)
            local fromCmp = self:OuterZone(fromZone)
            local function bracket(zone)
                zone = self:OuterZone(zone)
                if zone and fromCmp and zone ~= fromCmp then return " (" .. zone .. ")" end
                return ""
            end
            if to.kind == "flight" then
                -- the town first ("Walk to Sun Rock Retreat"); in it (its subzone, close by, or the town is
                -- the city you're in): "Walk to the flight master"
                local town = self:TownOf(to)
                local sub = first and GetSubZoneText and GetSubZoneText() or nil
                local inTown = not town or (sub and sub ~= "" and sub == town) or (yd and yd <= self.TOWN_NEAR)
                    or (fromZone and fromZone == town)
                if inTown then text, label = "Walk to the flight master" .. ydText, "Walk to the flight master"
                else text, label = "Walk to " .. town .. bracket(self:ZoneOf(to)) .. ydText, "Walk to " .. town end
            elseif to.kind == "dock" then
                local nm = "the " .. (to.how or "boat")
                text, label = "Walk to " .. nm .. bracket(to.zone) .. ydText, "Walk to " .. nm
            elseif to.kind == "lift" then
                text, label = "Walk to the elevator" .. ydText, "Walk to the elevator"
            elseif to.kind == "ruins" then
                if to.ruins == "in" then text, label = "Walk into the Ruins of Lordaeron" .. ydText, "Walk into the Ruins"
                else text, label = "Leave the Ruins of Lordaeron" .. ydText, "Leave the Ruins" end
            elseif to.kind == "cross" then
                if to.fromCity and to.fromName then
                    text, label = ("Leave %s for %s%s"):format(to.fromName, to.toName, ydText), "Leave " .. to.fromName
                else
                    text, label = ("Head into %s%s"):format(to.toName, ydText), "Head into " .. to.toName
                end
            elseif to.kind == "cross2" then
                text = nil -- (just over the border: the next step says where)
            else
                local nm = (to == dest and dest.name) or to.name or to.zone or "there"
                if to.kind == "hearth" then nm = "the inn" end
                local unsure = (to == dest and Places.Unconfirmed and Places:Unconfirmed(to)) and " (unconfirmed)" or ""
                text = "Walk to " .. nm .. unsure .. bracket(self:ZoneOf(to)) .. ydText
                label = "Walk to " .. nm
            end
            leg.yd = yd
        elseif how == "fly" then
            -- "Fly to Brackenwall Village (Dustwallow Marsh)" when the flight map's name is known
            local spot, zone = (to.taxiName or ""):match("^(.-),%s*(.+)$")
            if spot then text, label = ("Fly to %s (%s)"):format(spot, zone), "Fly to " .. spot
            else
                local nm = (to.zone and to.zone ~= "" and to.zone) or to.name or "?"
                text, label = "Fly to " .. nm, "Fly to " .. nm
            end
        elseif how == "hearth" then
            text, label = ("Use your Hearthstone (to %s)"):format(leg.text or to.zone or "your inn"), "Use your Hearthstone"
        elseif how == "teleport" then
            text = ("Cast %s"):format(leg.text or "your teleport"); label = text
        elseif how == "lift" then
            text, label = leg.text, leg.text
        elseif how == "cross" or how == "ruins" then
            text = nil -- (stepping over the border itself isn't a step of its own)
        else
            text = leg.text or ("Take the " .. how)
            label = "Take the " .. how
        end
        if text then
            if #label > 34 then label = label:gsub(" %(.-%)$", "") end
            steps[#steps + 1] = { how = how, text = text, label = label, to = to, from = leg.from, yd = leg.yd }
        end
    end
    -- standing at the flight master or the dock already (or landing next to it): that walk isn't a step
    for i = #steps - 1, 1, -1 do
        if steps[i].how == "walk" and (steps[i].yd or 999) < self.SKIP_WALK then table.remove(steps, i) end
    end
    return steps
end

---------------------------------------------------------------------------
-- Elevators (Undercity, Thunder Bluff): the way in and out of those cities. Spots are saved with
-- /pc elevator and shared on the MostlyNotBrokenAddons channel in the same form Snuggle Up uses
-- ("E|map|x|y"), and Snuggle Up's saved spots (and what its users send) count too.
---------------------------------------------------------------------------
-- a city and the ground under it: an elevator is the only way between them
Travel.LIFT_PAIRS = { [1458] = 1420, [1420] = 1458, [1456] = 1412, [1412] = 1456 }

Travel.ELEVATOR_CITIES = {
    { name = "Undercity", map = 1458, out = "up", into = "down" },
    { name = "Thunder Bluff", map = 1456, out = "down", into = "up" },
}

-- the elevator city on this map (or nil)
function Travel:ElevatorCity(map)
    if not map then return nil end
    for _, c in ipairs(self.ELEVATOR_CITIES) do
        local m = (PC.ToLearn and PC.ToLearn:ZoneMap(c.name)) or c.map
        if map == m or map == c.map then return c end
    end
    return nil
end

-- Spots that were never an elevator. Hearthstones land at the innkeeper and the city map flips as
-- you cross a bridge or the rim, and older versions wrote both down as elevators, so the guide sent
-- you into a tent. An elevator never stands on top of a person, a mailbox or an anvil.
Travel.ELEV_NOT = { inn = true, vendor = true, trainer = true, bank = true, ah = true, mail = true,
    mailbox = true, flight = true, station = true }

-- everyone and everything standing on this map that an elevator can't be (worked out once)
function Travel:ElevNoGo(map)
    local list = {}
    for _, p in pairs(Places:All()) do
        if p.map == map and self.ELEV_NOT[p.kind or ""] and p.x and p.y then list[#list + 1] = p end
    end
    return list
end

function Travel:ElevatorOnTopOfSomeone(e, noGo)
    for _, p in ipairs(noGo or self:ElevNoGo(e.map)) do
        local d = self:Yards(e, p)
        if d and d < 20 then return true end
    end
    return false
end

-- Spots strung out in a line are a bridge or the edge of the city map, not an elevator: an elevator
-- is a platform a few yards across, so its spots sit in a tight little knot.
local function TightKnots(list, link, span)
    local groups = {}
    for _, e in ipairs(list) do
        local hit
        for _, g in ipairs(groups) do
            for _, o in ipairs(g) do
                if math.abs(o.x - e.x) <= link and math.abs(o.y - e.y) <= link then hit = g break end
            end
            if hit then break end
        end
        if hit then hit[#hit + 1] = e else groups[#groups + 1] = { e } end
    end
    local out = {}
    for _, g in ipairs(groups) do
        local x1, x2, y1, y2 = g[1].x, g[1].x, g[1].y, g[1].y
        for _, e in ipairs(g) do
            x1, x2 = math.min(x1, e.x), math.max(x2, e.x)
            y1, y2 = math.min(y1, e.y), math.max(y2, e.y)
        end
        if (x2 - x1) <= span and (y2 - y1) <= span then
            -- one spot for the knot: the middle of it
            local sx, sy, dir = 0, 0, nil
            for _, e in ipairs(g) do sx, sy, dir = sx + e.x, sy + e.y, dir or e.dir end
            local mid = g[1]
            mid.x, mid.y, mid.dir = sx / #g, sy / #g, dir
            out[#out + 1] = mid
        end
    end
    return out
end

-- every elevator spot known on a map: yours, other users', and Snuggle Up's.
-- dir = "up" or "down" (where you get on to go that way); nil = not said (Snuggle Up's own)
function Travel:Elevators(map)
    if not map then return {} end
    local cache = self.elevCache and self.elevCache[map]
    if cache and GetTime() - cache.t < 60 then return cache.list end
    local out, marked = {}, {}
    local function add(list)
        for _, e in ipairs(list or {}) do
            if e.x and e.y then
                local dup
                for _, o in ipairs(out) do if math.abs(o.x - e.x) < 0.015 and math.abs(o.y - e.y) < 0.015 then dup = o end end
                if dup then dup.dir, dup.mine = dup.dir or e.dir, dup.mine or e.mine
                else out[#out + 1] = { map = map, x = e.x, y = e.y, from = e.from, dir = e.dir, mine = e.mine, name = "Elevator", kind = "elevator" } end
            end
        end
    end
    add(PC.db and PC.db.elevators and PC.db.elevators[map])
    for _, e in ipairs(out) do marked[#marked + 1] = e end -- these someone stood on and marked
    local su = _G.SnuggleUp
    if su and su.Elevators then
        local ok, all = pcall(su.Elevators, su)
        if ok and type(all) == "table" then add(all[map]) end
    end
    -- MostlyNotBroken's lift spots: { m, x, y, to } (going to the city: into it; out of it: out)
    local mnb = _G.MostlyNotBroken
    if type(mnb) == "table" and type(mnb.Lifts) == "function" then
        local ok, lifts = pcall(mnb.Lifts, mnb, map)
        if ok and type(lifts) == "table" then
            local list = {}
            for _, l in ipairs(lifts) do
                if type(l) == "table" then
                    local x, y, to = tonumber(l.x), tonumber(l.y), tonumber(l.to)
                    local dir
                    local here, there = self:ElevatorCity(map), to and self:ElevatorCity(to)
                    if here and to and to ~= map and there ~= here then dir = here.out
                    elseif there and there ~= here then dir = there.into end
                    if x and y then list[#list + 1] = { x = x, y = y, dir = dir } end
                end
            end
            add(list)
        end
    end
    -- what's trusted, best first: one you rode or marked yourself, then ones other players stood on
    -- and marked, and only then the ones worked out from people crossing between the two maps
    local noGo = self:ElevNoGo(map)
    local function noNPCs(list)
        local clean = {}
        for _, e in ipairs(list) do if not self:ElevatorOnTopOfSomeone(e, noGo) then clean[#clean + 1] = e end end
        return clean
    end
    local mine = {}
    for _, e in ipairs(out) do if e.mine then mine[#mine + 1] = e end end
    if #mine == 0 then mine = noNPCs(marked) end
    if #mine == 0 then
        local clean = noNPCs(out)
        if #clean > 0 then
            local knots = TightKnots(clean, 0.035, 0.08)
            mine = #knots > 0 and knots or clean
        else
            mine = out
        end
        while #mine > 12 do table.remove(mine) end
    end
    self.elevCache = self.elevCache or {}
    self.elevCache[map] = { list = mine, t = GetTime() }
    return mine
end

-- Save an elevator spot (false when one is already saved right there; a direction is added to it then)
function Travel:AddElevator(map, x, y, from, dir, mine)
    if not map or not x or not y or x <= 0 or x >= 1 or y <= 0 or y >= 1 then return false end
    if dir ~= "up" and dir ~= "down" then dir = nil end
    -- (in the city itself, or at the bottom of Thunder Bluff's lifts out in Mulgore: any map, with a direction)
    if not self:ElevatorCity(map) and not dir then return false end
    PC.db.elevators = PC.db.elevators or {}
    local list = PC.db.elevators[map] or {}
    PC.db.elevators[map] = list
    self.elevCache = nil
    for _, e in ipairs(list) do
        if math.abs(e.x - x) < 0.015 and math.abs(e.y - y) < 0.015 then
            local was = e.mine
            if mine then e.mine, e.x, e.y = true, x, y end
            if dir and e.dir ~= dir then e.dir = dir end
            if mine and not was then PC:RefreshUI(); return true end
            if dir and e.dir == dir then PC:RefreshUI(); return true end
            return false
        end
    end
    if #list >= 8 then
        -- a spot of your own always fits: the oldest one somebody else sent makes room for it
        local drop
        for i, e in ipairs(list) do if not e.mine then drop = drop or i end end
        if not (mine and drop) then return false end
        table.remove(list, drop)
    end
    list[#list + 1] = { x = x, y = y, from = from, dir = dir, mine = mine or nil }
    PC:RefreshUI()
    return true
end

-- /pc elevator up | down: stand where you get on, going that way (shared with other users)
function Travel:MarkElevator(dir)
    dir = (dir or ""):lower():match("up") and "up" or ((dir or ""):lower():match("down") and "down") or nil
    local map, x, y = Places:Here()
    if not x then return PC.Print("Can't tell where you are right now: try again in a moment.") end
    -- no need to say which way: up in the city, down from the ground outside it
    if not dir then
        local city = self:ElevatorCity(map)
        if city then dir = city.out
        else
            for _, c in ipairs(self.ELEVATOR_CITIES) do
                local cm = (PC.ToLearn and PC.ToLearn:ZoneMap(c.name)) or c.map
                if self.LIFT_PAIRS[cm or 0] == map then dir = c.into break end
            end
        end
    end
    if not dir then
        return PC.Print("Stand where you get on an elevator, then type |cffffd100/pc elevator up|r (it takes you up) or |cffffd100/pc elevator down|r (it takes you down).")
    end
    if self:AddElevator(map, x, y, nil, dir, true) then
        local city = self:ElevatorCity(map)
        PC.Print(("Saved the elevator %s%s."):format(dir, city and (" in " .. city.name) or ""))
        if PC.Share and PC.Share.SendElevator then PC.Share:SendElevator(map, x, y, dir) end
    else
        PC.Print("There's already an elevator saved right here.")
    end
end

-- the nearest elevator spot to you on this map going `dir` (one with no direction saved will do), or nil
function Travel:NearestElevator(map, x, y, dir)
    local best, bestD, bestExact
    for _, e in ipairs(self:Elevators(map)) do
        if not dir or not e.dir or e.dir == dir then
            local exact = dir and e.dir == dir
            local d = (x and y) and ((e.x - x) ^ 2 + (e.y - y) ^ 2) or 0
            -- one saved for this direction beats one with no direction
            if not best or (exact and not bestExact) or (exact == bestExact and d < bestD) then best, bestD, bestExact = e, d, exact end
        end
    end
    return best
end

-- "Tal (flight master)": who to talk to for a flight
---------------------------------------------------------------------------
-- On a flight: where it lands (the flight map's name for it), so nothing gets re-planned mid-air
---------------------------------------------------------------------------
if hooksecurefunc and TakeTaxiNode then
    hooksecurefunc("TakeTaxiNode", function(i)
        PC:Safe("travel", function()
            local name = TaxiNodeName and TaxiNodeName(i) or nil
            Travel.flight = { to = name, t = GetTime() }
        end)
    end)
end

-- On a flight right now? Returns where it lands ("Sun Rock Retreat, Stonetalon Mountains"), or
-- true when that isn't known; nil when you're not flying.
function Travel:InFlight()
    if not (UnitOnTaxi and UnitOnTaxi("player")) then
        -- (a moment's grace right after taking the flight, before the game says you're on it)
        if self.flight and GetTime() - (self.flight.t or 0) > 10 then self.flight = nil end
        return nil
    end
    return self.flight and self.flight.to or true
end

-- "Flying to Sun Rock Retreat (Stonetalon Mountains)"
function Travel:FlightText()
    local to = self:InFlight()
    if not to then return nil end
    if to == true then return "Flying", "On a flight: the next step shows when you land." end
    local spot, zone = to:match("^(.-),%s*(.+)$")
    local text = spot and ("Flying to %s (%s)"):format(spot, zone) or ("Flying to " .. to)
    return text, "On a flight: the next step shows when you land."
end

---------------------------------------------------------------------------
-- Walking step wording (the same in every Mostly Not Broken add-on):
--   a flight master: the town first ("Walk to Sun Rock Retreat"), then once you're in that town
--   (its subzone, or within 150 yd) "Walk to the flight master"; a dock: "Walk to the zeppelin".
--   The zone goes in brackets only when the walk starts in a different zone.
---------------------------------------------------------------------------
Travel.TOWN_NEAR = 150

function Travel:TownOf(p)
    if not p then return nil end
    local town = p.taxiName and p.taxiName:match("^(.-),")
    if town and town ~= "" then return town end
    if p.sub and p.sub ~= "" then return p.sub end
    return nil
end

function Travel:ZoneOf(p)
    if not p then return nil end
    local z = p.taxiName and p.taxiName:match(",%s*(.+)$")
    if z and z ~= "" then return z end
    if p.zone and p.zone ~= "" then return p.zone end
    local info = p.map and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(p.map)
    return info and info.name or nil
end

-- "Sun Rock Retreat (Stonetalon Mountains)", "the flight master", "the zeppelin", "Thrall"...
-- first = this walk starts where you stand (then "in that town" is checked)
function Travel:WalkName(to, from, first)
    if not to then return "there" end
    local name
    if to.kind == "flight" then
        local town = self:TownOf(to)
        local near = false
        if first then
            local sub = GetSubZoneText and GetSubZoneText() or nil
            local yd = from and from.x and to.x and self:Yards(from, to)
            local zt = GetRealZoneText and GetRealZoneText() or nil
            near = (town and sub and sub == town) or (yd and yd <= self.TOWN_NEAR) or (town and zt and zt == town) or false
        end
        name = (near or not town) and "the flight master" or town
    elseif to.kind == "dock" then name = "the " .. (to.how or "boat")
    elseif to.kind == "link" then name = "the dock"
    else name = to.name or to.zone or "there" end
    local z1, z2 = self:OuterZone(self:ZoneOf(from)), self:OuterZone(self:ZoneOf(to))
    if z2 and z1 and z1 ~= z2 and name ~= z2 then name = name .. " (" .. z2 .. ")" end
    return name
end

-- Working out a route (the whole map of roads, flights and crossings) is heavy: over half a second
-- with a long plan, and it ran twice on every refresh, which froze the game on every bag change at
-- the bank, a vendor or while crafting. The answer is kept while you stand still (up to 20 seconds),
-- and for 3 seconds while you're on the move.
function Travel:BestWay(dest)
    local here = self:Here()
    if not here or not dest or not dest.map then return nil end
    local now = GetTime and GetTime() or 0
    local key = ("%s:%d:%d"):format(tostring(dest.map), math.floor((dest.x or 0) * 2000), math.floor((dest.y or 0) * 2000))
    local taxi = UnitOnTaxi and UnitOnTaxi("player") and true or false
    -- which level you're on counts too: an elevator moves you up or down without moving you on the
    -- map, and the old answer ("walk to the elevator") must not be kept after you've ridden it
    local side = tostring(self:SideHere(here.map)) .. "|" .. tostring(GetRealZoneText and GetRealZoneText() or "")
        .. "|" .. tostring(GetSubZoneText and GetSubZoneText() or "")
    self.wayCache = self.wayCache or {}
    local c = self.wayCache[key]
    if c and c.map == here.map and c.taxi == taxi and c.side == side then
        local age = now - c.t
        local moved = self:Yards(c.here, here)
        if age < 3 or (age < 20 and moved and moved < 10) then return c.way end
    end
    local way = PC:Timed("route", self.BestWayRaw, self, dest, here)
    -- (only a handful are ever in use: start over rather than let it grow)
    local n = 0
    for _ in pairs(self.wayCache) do n = n + 1 end
    if n > 12 then self.wayCache = {} end
    self.wayCache[key] = { way = way, t = now, map = here.map, taxi = taxi, side = side, here = { map = here.map, x = here.x, y = here.y } }
    return way
end

function Travel:BestWayRaw(dest, here)
    here = here or self:Here()
    if not here or not dest or not dest.map then return nil end
    local mark = PC.PerfMark and PC:PerfMark("r_") or function() end -- (timing: building the map, then searching it)
    local g = self:Graph(here, { dest })
    mark("graph")
    local di = g.stops[1]
    local dist, prev = self:DijkstraRoads(g, 1, true, di)
    mark("search")
    if not dist[di] then return nil end
    local steps = self:Steps(g, prev, di, dest)
    mark("steps")
    -- where the pin goes now: where the step you're on says (the spot you walk to; for a flight, a
    -- boat or the elevator, where you get on)
    local first = dest
    local st = steps[1]
    if st then
        local p = st.how == "walk" and st.to or st.from
        if p and p.map and p.x then first = (p == g.nodes[di]) and dest or p end
    end
    return { secs = dist[di], steps = steps, first = first }
end

-- The quickest order to visit stops: the closest (by travel time) first, then the closest to that,
-- and so on. Another continent only when getting there is quicker than what's left here.
-- Returns the stops' indexes in order (ones it can't work out a way to come last) and the time of each leg.
function Travel:Order(stops)
    local here = self:Here()
    local order, secs = {}, {}
    if not here or #stops == 0 then for k = 1, #stops do order[k] = k end return order, secs end
    local g = self:Graph(here, stops)
    local left = {}
    for k = 1, #stops do left[k] = true end
    local cur, first = 1, true
    while next(left) do
        local dist = self:DijkstraRoads(g, cur, first)
        local bestK, bestD
        for k in pairs(left) do
            local d = dist[g.stops[k]]
            if d and (not bestD or d < bestD) then bestK, bestD = k, d end
        end
        if not bestK then break end
        order[#order + 1], secs[#order] = bestK, bestD
        left[bestK] = nil
        cur, first = g.stops[bestK], false
    end
    -- no known way there (yet): last, in the order you added them
    local rest = {}
    for k in pairs(left) do rest[#rest + 1] = k end
    table.sort(rest)
    for _, k in ipairs(rest) do order[#order + 1] = k end
    return order, secs
end

-- "2 min: Use your Hearthstone, then walk to Auction House (40 yd)"
function Travel:Describe(way)
    if not way then return nil end
    local parts = {}
    for i, st in ipairs(way.steps) do parts[#parts + 1] = i == 1 and st.text or (st.text:sub(1, 1):lower() .. st.text:sub(2)) end
    local secs = way.secs or 0
    secs = math.min(secs, 1e6)
    local t = secs < 90 and ("%d sec"):format(math.floor(secs + 0.5)) or ("%d min"):format(math.floor(secs / 60 + 0.5))
    return ("Quickest (~%s): %s"):format(t, table.concat(parts, ", then "))
end

---------------------------------------------------------------------------
-- Learning as you play
---------------------------------------------------------------------------
-- a trail of where you've been (for working out where a portal or boat started)
Travel.trail = {}
-- Which end of a Thunder Bluff lift you're at. Nothing in the game says: both ends are the same
-- spot on the same map with the same zone name. But standing still on an elevator for a quarter of
-- a minute and then walking off is a ride, so that's what's watched for.
function Travel:WatchLift()
    if PC.inCombat then return end
    local cdb = PC.cdb
    if not cdb then return end
    local here = self:Here()
    if not here or not here.x then return end
    local map = here.map
    if self.LIFT_PAIRS[map or 0] and not self:ElevatorCity(map) then
        cdb.liftSide, cdb.liftAt, self.liftStill = nil, nil, nil -- out on the ground: no doubt
        return
    end
    if map ~= 1456 then self.liftStill = nil return end
    local zt = GetRealZoneText and GetRealZoneText() or ""
    if zt ~= "" and zt ~= "Thunder Bluff" then
        cdb.liftSide, cdb.liftAt, self.liftStill = nil, nil, nil
        return
    end
    -- the high ground and the low ground of this city, learned as you walk (the only sure way to
    -- tell the top of a lift from the bottom: the map and the zone name are the same at both)
    local z = here.z
    if z then
        local t = cdb.tbZ
        if not t or not t.hi then t = { hi = z, lo = z }; cdb.tbZ = t end
        if z > t.hi then t.hi = z end
        if z < t.lo then t.lo = z end
    end
    local e = self:NearestElevator(map, here.x, here.y)
    local d = e and self:Yards(here, { map = map, x = e.x, y = e.y })
    -- walked a long way from every lift and still thought to be outside: that memory is wrong (the
    -- ground at the foot of the bluffs is only a short walk wide, the city on top is not).
    -- Height settles it where it can; until it has both ends of the city to compare, this does.
    local t2 = cdb.tbZ
    local zSure = z and t2 and t2.hi and t2.lo and (t2.hi - t2.lo) > 40
    -- "You're at the bottom" only holds near the lift you rode. The ground at the foot of the bluffs
    -- is a short walk wide and turns into Mulgore; the city on top is not, so anywhere else in the
    -- city, being up there is the better bet. (This client gives no height to settle it with.)
    if cdb.liftSide == "out" and not zSure then
        local sp = cdb.liftSpot
        local away = sp and self:Yards(here, { map = map, x = sp.x, y = sp.y }) or d
        if away and away > 100 then
            cdb.liftSide, cdb.liftAt, cdb.liftSpot = nil, nil, nil
            self.wayCache = nil
            if PC.Next and PC.Next.UpdateBar then PC.Next:UpdateBar() end
        end
    end
    if not d or d > 20 then self.liftStill = nil return end
    local sp = 0
    if GetUnitSpeed then local ok, v = pcall(GetUnitSpeed, "player"); sp = (ok and PC.Num(v)) or 0 end
    local now = GetTime()
    if sp == 0 then
        self.liftStill = self.liftStill or now
    elseif self.liftStill and now - self.liftStill >= 15 then
        cdb.liftSide = (self:SideHere(map) == "tbin") and "out" or "tbin"
        cdb.liftAt, cdb.liftSpot = time(), { x = e.x, y = e.y }
        -- a ride is 15 seconds of standing still: shorter than that and nothing is assumed
        self.liftStill, self.wayCache = nil, nil
        if PC.Next and PC.Next.UpdateBar then PC.Next:UpdateBar() end
        if PC.Places and PC.Places.DrawStars then pcall(PC.Places.DrawStars, PC.Places) end
    else
        self.liftStill = nil
    end
end

-- Walking changes the step and the yards in it, and nothing used to tell the Task Button you'd
-- moved: it waited for a bag, a window or a new zone. A route search costs a few milliseconds now,
-- so every 20 yards walked it works the step out again.
function Travel:WalkRefresh()
    if PC.inCombat then return end
    local N = PC.Next
    if not N or not N.bar or not N.bar:IsShown() then self.walkFrom = nil return end
    local here = self:Here()
    if not here or not here.x then return end
    local last = self.walkFrom
    if last then
        local y = self:Yards(last, here)
        if y and y < 20 then return end
        if not y and last.map == here.map then return end
    end
    self.walkFrom = here
    if not last then return end
    PC:WithMemo(function()
        N:UpdateBar()
        if PC.Steps and PC.Steps.Refresh then pcall(PC.Steps.Refresh, PC.Steps) end
    end)
end

-- Already at a stop: talking to its NPC, its window open (the AH, the bank, a mailbox), or standing a
-- few yards from it. No travel to it then.
Travel.AT_YARDS = 10
function Travel:AtPlace(p)
    if not p then return false end
    local kind = p.kind
    if kind == "ah" and PC.ahOpen then return true end
    if kind == "bank" and PC.Bank and PC.Bank.Open and PC.Bank:Open() then return true end
    if kind == "mail" and PC.Mail and PC.Mail.Open and PC.Mail:Open() then return true end
    if p.name and UnitExists and UnitName and UnitExists("npc") then
        local npc = UnitName("npc")
        if npc and not PC.IsSecret(npc) and npc == p.name then return true end
    end
    local here = self:Here()
    local yd = here and self:Yards(here, p)
    return yd ~= nil and yd <= self.AT_YARDS
end

function Travel:CheckArrived()
    if PC.inCombat then return end
    local P = PC.Places
    local pin = P and P.current
    if not pin or not pin.map or not pin.x then self.arrivedAt = nil return end
    local here = self:Here()
    local yd = here and self:Yards(here, pin)
    local key = ("%s:%.4f:%.4f"):format(tostring(pin.map), pin.x, pin.y)
    if yd and yd < 8 then
        if self.arrivedAt ~= key then
            self.arrivedAt = key
            self.wayCache = nil
            PC:RefreshUI()
        end
    elseif self.arrivedAt == key and yd and yd > 20 then
        self.arrivedAt = nil
    end
end

function Travel:Sample()
    local here = self:Here()
    if not here then return end
    local now = GetTime()
    here.t = now
    here.taxi = UnitOnTaxi and UnitOnTaxi("player") or false
    local tr = self.trail
    local last = tr[#tr]
    -- a jump: you went far (or to another continent) in a moment, not on a flight: a portal, boat or tram
    if last and not here.taxi and not last.taxi and now - last.t < 30 then
        local y = self:Yards(last, here)
        -- (another continent only counts when the game can tell continents apart)
        local far = (y == nil and last.map ~= here.map and W(last) and W(here)) or (y and y > 600 and y / math.max(now - last.t, 0.5) > 60)
        if far then self:Jumped(last, here) end
    end
    -- how fast you move on your own
    if GetUnitSpeed and not here.taxi then
        local ok, sp = pcall(GetUnitSpeed, "player")
        sp = ok and PC.Num(sp) or nil -- (kept secret in combat: skip it then)
        here.sp = sp
        if sp and sp > 0 and sp < 60 and PC.cdb then PC.cdb.runSpeed = math.max(PC.cdb.runSpeed or 7, sp) end
    end
    -- an elevator ride, learned from you: the city map and the ground under it swap places while
    -- you stand still. Walking over a bridge or the city rim swaps them too, but you're moving then.
    if last and not here.taxi and not last.taxi and self.LIFT_PAIRS[last.map or 0] == here.map
        and now - last.t < 8 and (here.sp == 0) and (last.sp == 0) then
        local y = self:Yards(last, here)
        if y and y < 12 then
            local cFrom, cTo = self:ElevatorCity(last.map), self:ElevatorCity(here.map)
            self:AddElevator(last.map, last.x, last.y, nil, cFrom and cFrom.out or (cTo and cTo.into), true)
            self:AddElevator(here.map, here.x, here.y, nil, cTo and cTo.out or (cFrom and cFrom.into), true)
        end
    end
    -- walked over a zone border (not a jump, not a flight): remember the way through
    if last and not here.taxi and not last.taxi and last.map ~= here.map and now - last.t < 5 then
        local y = self:Yards(last, here)
        if y and y < 60 then Places:NoteCrossing(last, here) end
    end
    tr[#tr + 1] = here
    while #tr > 240 do table.remove(tr, 1) end
end

-- You landed somewhere far away: your hearthstone or teleport (remember where it lands), or a
-- portal / boat / tram (remember both ends, as a link others can use too)
function Travel:Jumped(before, after)
    local now = GetTime()
    if self.casting and now - self.casting.t < 60 then
        local c = self.casting
        self.casting = nil
        local spot = { map = after.map, x = after.x, y = after.y, zone = after.zone, name = after.zone }
        if c.kind == "hearth" then
            spot.bind = GetBindLocation and GetBindLocation() or nil
            PC.cdb.hearthArrive = spot
        else
            PC.cdb.teleArrive = PC.cdb.teleArrive or {}
            PC.cdb.teleArrive[c.id] = spot
        end
        return
    end
    -- where it started: the last spot you stood still at for a few seconds (the dock, the portal)
    local tr = self.trail
    local start, startT = before, before.t
    for i = #tr, 2, -1 do
        local a, b = tr[i - 1], tr[i]
        local y = self:Yards(a, b)
        if y and y < 3 and b.t - a.t >= 2 then start, startT = b, a.t break end
    end
    local secs = math.max(now - (startT or now), 1)
    -- a sudden hop is a summon, a graveyard or a way out of a dungeon: not a ride to remember
    if secs <= 30 or (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) then return end
    local how = "Boat / zeppelin"
    local name = ("%s to %s"):format(how, after.zone ~= "" and after.zone or "?")
    local map, x, y, zone = start.map, start.x, start.y, start.zone
    local t = Places:Table()
    local key = ("link:%d:%d:%d:%d"):format(map, math.floor(x * 50), math.floor(y * 50), after.map)
    local p = t[key] or { kind = "link" }
    p.name, p.map, p.x, p.y, p.zone = name, map, x, y, zone
    p.tomap, p.tox, p.toy, p.tozone = after.map, after.x, after.y, after.zone
    p.secs = math.floor(math.min(secs, 300))
    p.seen, p.mine, p.confirmed = time(), true, true
    p.toPt, p.wc = nil, nil
    t[key] = p
    Places:Dirty()
    if PC.Share and PC.Share.SharePlace then PC.Share:SharePlace(key, p) end
end

-- Crossings that were never a ride: a hearthstone, a summon, a trip to the graveyard or the way
-- out of a dungeon looks like a jump from where you stood, so old versions saved it as a crossing
-- and shared it. Thrown out once, so no route ever sends you to one.
function Travel:DropFakeLinks()
    local t = Places and Places.Table and Places:Table()
    if not t then return 0 end
    local docks = self:TransportLinks() or {}
    local gone = 0
    for key, p in pairs(t) do
        if type(p) == "table" and p.kind == "link" and (p.secs or 0) <= 30 then
            local atDock = false
            for _, l in ipairs(docks) do
                local d = self:Yards(p, l.from)
                if d and d <= 150 then atDock = true break end
            end
            if not atDock then t[key] = nil; gone = gone + 1 end
        end
    end
    if gone > 0 then
        Places:Dirty()
        if self.wayCache then self.wayCache = nil end
    end
    return gone
end

-- what kind of trainer this is (a profession trainer: which one)
local function TrainerProf()
    if GetTrainerServiceSkillLine and GetNumTrainerServices then
        for i = 1, math.min(GetNumTrainerServices() or 0, 5) do
            local ok, line = pcall(GetTrainerServiceSkillLine, i)
            if ok and line and line ~= "" then return line end
        end
    end
    -- the title under the name: "Enchanting Trainer"
    if C_TooltipInfo and C_TooltipInfo.GetUnit then
        local ok, data = pcall(C_TooltipInfo.GetUnit, "npc")
        for _, l in ipairs(ok and data and data.lines or {}) do
            local t = type(l.leftText) == "string" and l.leftText or nil
            local prof = t and t:match("^<?([%a ]-) Trainer>?$")
            if prof and prof ~= "" and not prof:find("Class") then return prof end
        end
    end
    return nil
end

-- an innkeeper's chat has the "make this inn your home" option
local function IsInnkeeper()
    if C_GossipInfo and C_GossipInfo.GetOptions then
        local ok, opts = pcall(C_GossipInfo.GetOptions)
        if ok and type(opts) == "table" then
            for _, o in ipairs(opts) do
                local n = (o.name or ""):lower()
                if n:find("inn your home", 1, true) or o.icon == 132052 then return true end
            end
        end
    end
    if GetGossipOptions then
        local list = { GetGossipOptions() }
        for i = 1, #list do
            local v = list[i]
            if v == "binder" then return true end
            if type(v) == "string" and v:lower():find("inn your home", 1, true) then return true end
        end
    end
    return false
end

---------------------------------------------------------------------------
-- Flying: each flight master's name on the flight map is learned when you open it (taxiName),
-- and with "Fly automatically" on, the flight the route needs is taken for you
---------------------------------------------------------------------------
local function TaxiNodes()
    local list = {}
    -- the flight map's own list (its slot numbers are what TakeTaxiNode wants)
    if C_TaxiMap and C_TaxiMap.GetAllTaxiNodes and GetTaxiMapID then
        local ok, nodes = pcall(C_TaxiMap.GetAllTaxiNodes, GetTaxiMapID())
        if ok and type(nodes) == "table" and #nodes > 0 then
            local S = Enum and Enum.FlightPathState or {}
            for _, n in ipairs(nodes) do
                local kind = (n.state == (S.Current or 0) and "CURRENT") or (n.state == (S.Reachable or 1) and "REACHABLE") or "NONE"
                list[#list + 1] = { i = n.slotIndex, name = n.name or "", kind = kind }
            end
            return list
        end
    end
    local n = NumTaxiNodes and NumTaxiNodes() or 0
    for i = 1, n do
        list[#list + 1] = { i = i, name = TaxiNodeName and TaxiNodeName(i) or "", kind = TaxiNodeGetType and TaxiNodeGetType(i) or "" }
    end
    return list
end
Travel.TaxiNodes = TaxiNodes

-- the flight master you're at: remember what the flight map calls it
function Travel:NoteTaxi()
    local cur
    -- every flight path this map lists as yours (where you are, and where you can fly): known
    local known = self:KnownTaxi()
    for _, node in ipairs(TaxiNodes()) do
        if node.kind == "CURRENT" then cur = node.name end
        if (node.kind == "CURRENT" or node.kind == "REACHABLE") and node.name ~= "" then known[node.name] = true end
    end
    self.fpCache = nil
    if not cur then return end
    local map, x, y = Places:Here()
    local best, bestD -- (your own places: this one is written to)
    for _, p in pairs(Places:Table()) do
        if p.kind == "flight" and p.map == map and p.x then
            local d = (p.x - x) ^ 2 + (p.y - y) ^ 2
            if not bestD or d < bestD then best, bestD = p, d end
        end
    end
    if best then best.taxiName = cur; Places:Dirty() end
end

local function Plain(s) return (s or ""):lower():gsub("^the ", "") end

-- which flight-map node is this flight master (by the name learned there, else by its area)
function Travel:TaxiIndexFor(p)
    if not p then return nil end
    local nodes, hits = TaxiNodes(), {}
    for _, node in ipairs(nodes) do
        if node.kind == "REACHABLE" then
            if p.taxiName and node.name == p.taxiName then return node.i end
            local nm = node.name:lower()
            local sub, zone = Plain(p.sub), Plain(p.zone)
            if (sub ~= "" and nm:find(sub, 1, true)) or (zone ~= "" and nm:find(zone, 1, true)) then hits[#hits + 1] = node end
        end
    end
    if #hits == 1 then return hits[1].i end
    -- more than one in that zone: the one named for the area it's in
    for _, node in ipairs(hits) do
        if p.sub and p.sub ~= "" and node.name:lower():find(Plain(p.sub), 1, true) then return node.i end
    end
    return nil
end

-- the flight the route needs next (nil = no flight on the way)
function Travel:PendingFlight()
    local s = PC.Next and PC.Next.shown
    local way = s and s.way
    for _, st in ipairs(way and way.steps or {}) do
        if st.how == "fly" then return st end
    end
    return nil
end

function Travel:AutoFly()
    if not (PC.db and PC.db.autoFly == true) or not TakeTaxiNode then return end
    local st = self:PendingFlight()
    if not st then return end
    local i = self:TaxiIndexFor(st.to)
    if not i then
        PC.Print(("Couldn't find %s on the flight map: pick it yourself."):format(st.to.name or st.to.zone or "the next stop"))
        return
    end
    local name
    for _, node in ipairs(TaxiNodes()) do if node.i == i then name = node.name end end
    PC.Print(("Flying to %s."):format(name or st.to.zone or "your stop"))
    local ok, err = pcall(TakeTaxiNode, i)
    if not ok then PC.Print("|cffff5555Couldn't start the flight: " .. tostring(err) .. "|r") return end
    -- still standing there a moment later: say so plainly (pick it on the map)
    C_Timer.After(1.5, function()
        if UnitOnTaxi and not UnitOnTaxi("player") and not (Travel.flyCheck and GetTime() - Travel.flyCheck < 5) then
            Travel.flyCheck = GetTime()
            PC.Print(("|cffff8040The flight didn't start: click %s on the flight map.|r"):format(name or "your stop"))
        end
    end)
end

-- talking to a flight master who asks first ("Where would you like to fly to?"): open the
-- flight map for you, when a flight is next on the route and Fly automatically is on
function Travel:GossipFly()
    if not (PC.db and PC.db.autoFly == true) or not self:PendingFlight() then return end
    if C_GossipInfo and C_GossipInfo.GetOptions and C_GossipInfo.SelectOption then
        local ok, opts = pcall(C_GossipInfo.GetOptions)
        for _, o in ipairs(ok and opts or {}) do
            local nm = (o.name or ""):lower()
            if o.icon == 132057 or nm:find("fly") or nm:find("flight") then
                pcall(C_GossipInfo.SelectOption, o.gossipOptionID or o.optionID)
                return
            end
        end
    elseif GetGossipOptions and SelectGossipOption then
        local t = { GetGossipOptions() }
        for k = 1, #t, 2 do
            if t[k + 1] == "taxi" then SelectGossipOption((k + 1) / 2) return end
        end
    end
end

---------------------------------------------------------------------------
-- Leaving a city without your Hearthstone: say so before you get far (the standard pop-up)
---------------------------------------------------------------------------
function Travel:HaveHearth()
    local count = PC.BagCount and PC:BagCount(self.HEARTH_ITEM) or 0
    if count <= 0 and GetItemCount then count = GetItemCount(self.HEARTH_ITEM) or 0 end
    return count > 0
end

-- a city = somewhere with an Auction House or bank you've used
function Travel:IsCityMap(map)
    if not map then return false end
    for _, p in ipairs(Places:OfKind("ah")) do if p.map == map then return true end end
    for _, p in ipairs(Places:OfKind("bank")) do if p.map == map then return true end end
    return false
end

-- The warning, said once (in chat and in a window)
function Travel:HearthWarn(sub, lines)
    self.hearthWarned = GetTime()
    PC.Print("|cffff8040No Hearthstone:|r " .. table.concat(lines, " "))
    local Popup = PC.UI and PC.UI.Popup
    if Popup then
        self.hearthPopup = self.hearthPopup or Popup.New("ProfitCrafterHearthWarn")
        PC:Sound("warn")
        self.hearthPopup:Open({ title = "No Hearthstone", sub = sub, subColor = { 1, 0.69, 0.25 },
            sections = { { lines = lines, bullets = false } }, buttons = { { text = "OK" } }, fit = true })
    end
end

-- At a flight master in town without your Hearthstone: say so before you fly, not after you've
-- landed somewhere you can't hearth back from. The flight map closes once; open it again to fly anyway.
Travel.HEARTH_OVERRIDE = 120
function Travel:HearthBeforeFlying()
    if self:HaveHearth() then return true end
    local inTown = (IsResting and IsResting()) or self:IsCityMap(Places:Here())
    if not inTown then return true end
    if self.hearthOverride and GetTime() - self.hearthOverride < self.HEARTH_OVERRIDE then return true end
    self.hearthOverride = GetTime()
    if CloseTaxiMap then pcall(CloseTaxiMap) end
    local inBank = PC.cdb and PC.cdb.bank and PC.cdb.bank.count and (PC.cdb.bank.count[self.HEARTH_ITEM] or 0) > 0
    local lines = { "You don't have your Hearthstone, so you can't hearth back after this flight." }
    lines[#lines + 1] = inBank and "It's in your bank: take it out before you fly."
        or "Get one from an innkeeper (talk to them and make that inn your home)."
    lines[#lines + 1] = "Talk to the flight master again to fly without it."
    self:HearthWarn("Before you fly out", lines)
    return false
end

function Travel:CheckHearthLeaving()
    local resting = IsResting and IsResting() or false
    local map = Places:Here()
    if resting then
        if map then self.restMap = map end
        self.wasResting = true
        return
    end
    if not self.wasResting then return end
    self.wasResting = false
    -- left by flight: warned at the flight master already (or chose to fly anyway); too late now
    if (UnitOnTaxi and UnitOnTaxi("player")) or (self.hearthOverride and GetTime() - self.hearthOverride < 3600) then return end
    local from = self.restMap
    if not self:IsCityMap(from) or self:HaveHearth() then return end
    if GetTime() - (self.hearthWarned or -1000) < 600 then return end -- once in ten minutes at most
    self.hearthWarned = GetTime()
    local inBank = PC.cdb and PC.cdb.bank and PC.cdb.bank.count and (PC.cdb.bank.count[self.HEARTH_ITEM] or 0) > 0
    local lines = { "You're leaving town without your Hearthstone, so you can't hearth back." }
    lines[#lines + 1] = inBank and "It's in your bank: go back and take it out first."
        or "Get one from an innkeeper (talk to them and make that inn your home)."
    self:HearthWarn("You're leaving town without it", lines)
end

local ev = CreateFrame("Frame")
pcall(ev.RegisterEvent, ev, "PLAYER_UPDATE_RESTING")
for _, e in ipairs({ "TRAINER_SHOW", "GOSSIP_SHOW", "CONFIRM_BINDER", "MERCHANT_SHOW", "UNIT_SPELLCAST_SUCCEEDED",
    "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA" }) do pcall(ev.RegisterEvent, ev, e) end
pcall(ev.RegisterEvent, ev, "TAXIMAP_OPENED")
ev:SetScript("OnEvent", function(_, event, a1, a2, a3)
    PC:Safe("travel", function()
        if event == "GOSSIP_SHOW" then Travel:GossipFly() end
        if event == "TAXIMAP_OPENED" then
            -- after Places has learned this flight master
            C_Timer.After(0.2, function()
                PC:Safe("travel", Travel.NoteTaxi, Travel)
                local ok, go = pcall(Travel.HearthBeforeFlying, Travel)
                if ok and go == false then return end -- no flying out (or auto-flying) before you've got it
                PC:Safe("auto fly", Travel.AutoFly, Travel)
            end)
            return
        end
        if event == "PLAYER_UPDATE_RESTING" or event == "PLAYER_ENTERING_WORLD" then Travel:CheckHearthLeaving() end
        if event == "PLAYER_UPDATE_RESTING" then return end
        if not PC:RouteOn() then return end
        local npc = UnitName and UnitName("npc") or nil
        if event == "TRAINER_SHOW" then
            Places:Learn("trainer", npc or "Trainer", nil, { prof = TrainerProf() })
        elseif event == "GOSSIP_SHOW" then
            if IsInnkeeper() then Places:Learn("inn", npc or "Innkeeper") end
        elseif event == "CONFIRM_BINDER" then
            Places:Learn("inn", npc or "Innkeeper")
        elseif event == "MERCHANT_SHOW" then
            -- the vendor itself is learned by Places; mark the ones that repair
            if CanMerchantRepair and CanMerchantRepair() then
                Places:Learn("vendor", npc or "Vendor", nil, { repair = true })
            end
        elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
            if a1 ~= "player" then return end
            local id = a3
            if id == Travel.HEARTH_SPELL then Travel.casting = { kind = "hearth", t = GetTime() }
            elseif Travel.TELEPORTS[id] then Travel.casting = { kind = "teleport", id = id, t = GetTime() } end
        else
            -- after a loading screen: check for the jump straight away
            C_Timer.After(1, function() PC:Safe("travel", Travel.Sample, Travel) end)
        end
    end)
end)

-- a look every couple of seconds (cheap: one position)
local tick = CreateFrame("Frame")
tick.left, tick.n = 1, 0
tick:SetScript("OnUpdate", function(f, dt)
    f.left = f.left - (dt or 0)
    if f.left > 0 then return end
    f.left = 1
    f.n = f.n + 1
    -- once a second: walked into the Ruins of Lordaeron? (its entrance is learned right there)
    PC:Safe("travel", Travel.WatchRuins, Travel)
    -- reached the spot the Task Button was sending you to: it moves on to the next leg straight away
    PC:Safe("travel", Travel.CheckArrived, Travel)
    -- rode a Thunder Bluff lift? and the step kept up to date while you walk
    PC:Safe("travel", Travel.WatchLift, Travel)
    PC:Safe("travel", Travel.WalkRefresh, Travel)
    if f.n % 2 == 1 then return end
    PC:Safe("travel", Travel.Sample, Travel)
    -- landed (or got off a flight): the step moves on straight away
    PC:Safe("travel", Travel.CheckLanded, Travel)
end)

---------------------------------------------------------------------------
-- /pc where: where the route thinks you are, and the way it's taking (same as SnuggleUp's /su where)
---------------------------------------------------------------------------
local function Coords(p) return p and p.x and ("%.1f, %.1f"):format(p.x * 100, p.y * 100) or "?" end
Travel.AREA_NAMES = { out = "outside", uctop = "the Ruins of Lordaeron (outside, on top)", ucin = "inside Undercity", tbin = "inside Thunder Bluff" }

function Travel:Where()
    local P = PC.Print
    P(("%s %s: where am I"):format(PC.NAME, PC.VERSION or "?"))
    local raw = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local map, x, y = Places:Here()
    local side = map and self:SideHere(map) or "out"
    local function mapName(m) local i = m and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(m); return i and i.name or "?" end
    local counted = (side == "out" and self.CITY_OUTER[map]) and self.CITY_OUTER[map] or map
    print(("  Map: %s (%s), counted as %s (%s), at %s, %s"):format(tostring(raw), mapName(raw), tostring(counted), mapName(counted),
        x and ("%.1f, %.1f"):format(x * 100, y * 100) or "?", self.AREA_NAMES[side] or side))
    print(("  Zone: %s  Subzone: %s  Minimap: %s"):format(GetRealZoneText and GetRealZoneText() or "?", SubZone(), MinimapZone()))
    local s = PC.Next and PC.Next:Compute() or {}
    print(("  Button: %s"):format(PC.Next and PC.Next:Label(s) or "?"))
    local pin = Places.current
    print(("  Pin: %s"):format(pin and ("%s (%s %s)"):format(pin.name or "?", mapName(pin.map), Coords(pin)) or "none"))
    if s.way and s.way.steps then
        for i, st in ipairs(s.way.steps) do print(("  %d. %s"):format(i, st.text)) end
    else
        print("  No route right now.")
    end
    local r = self:RuinsEntrance()
    print(("  Ruins entrance: %s"):format(r and ("Tirisfal %.1f, %.1f / Undercity %.1f, %.1f"):format(r.tx * 100, r.ty * 100, r.ux * 100, r.uy * 100) or "not known yet"))
    -- the route's time to the elevator top and bottom, the Undercity flight master and the stop
    local here = self:Here()
    if here then
        local dest = s.dest
        local g = self:Graph(here, dest and { dest } or {})
        local dist = self:DijkstraRoads(g, 1, true, dest and g.stops[1] or nil)
        local top, bottom, fp
        for i, nd in ipairs(g.nodes) do
            local d = dist[i]
            if d and nd.kind == "lift" and nd.map == 1458 then
                if g.side[i] == "ucin" then bottom = math.min(bottom or d, d) else top = math.min(top or d, d) end
            elseif d and nd.kind == "flight" and (nd.taxiName or ""):find("^Undercity") then fp = math.min(fp or d, d) end
        end
        local function sec(v) return v and ("%d sec"):format(math.floor(v + 0.5)) or "no way" end
        print(("  Route time: elevator top %s, bottom %s, Undercity flight master %s, the stop %s"):format(sec(top), sec(bottom), sec(fp),
            sec(dest and dist[g.stops[1]] or nil)))
    end
end

-- Was on a flight, isn't any more: show the next step
function Travel:CheckLanded()
    local on = UnitOnTaxi and UnitOnTaxi("player") and true or false
    if self.wasOnTaxi and not on then
        self.flight = nil
        PC:RefreshUI()
    end
    self.wasOnTaxi = on
end

do
    local land = CreateFrame("Frame")
    for _, e in ipairs({ "PLAYER_CONTROL_GAINED", "PLAYER_CONTROL_LOST" }) do pcall(land.RegisterEvent, land, e) end
    land:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_CONTROL_LOST" then
            -- (a flight starting: the bar says where it's going)
            C_Timer.After(0.5, function() PC:Safe("travel", Travel.CheckLanded, Travel); PC:RefreshUI() end)
            return
        end
        -- control back after a flight: a moment for the game to finish landing, then the next step
        C_Timer.After(0.3, function() PC:Safe("travel", Travel.CheckLanded, Travel); PC:RefreshUI() end)
        C_Timer.After(1.5, function() PC:RefreshUI() end)
    end)
end
