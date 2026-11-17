-- ProfitCrafter: places
--   Learns where things are as you use them: vendors (and what they sell), Auction Houses, mailboxes
--   and flight masters. Then Next step can point you to the nearest one with the game's map pin,
--   order your stops by distance, and say which flight to take. Learned spots are shared with other
--   ProfitCrafter users on your faction (same hidden channel as prices), marked "unconfirmed" until
--   a second person, or you, has been there.

local ADDON, ns = ...
local PC = ns.PC

local Places = {}
PC.Places = Places

Places.KINDS = { vendor = "Vendor", ah = "Auction House", mail = "Mailbox", flight = "Flight master", bank = "Bank", station = "Crafting station",
    trainer = "Trainer", inn = "Innkeeper", link = "Boat / zeppelin" }
-- kinds older versions understand (sent the old way); the rest go in the newer message
Places.OLD_KINDS = { vendor = true, ah = true, mail = true, flight = true, bank = true, station = true }
Places.MAX_STOCK = 60     -- items remembered per vendor

---------------------------------------------------------------------------
-- Storage: db.places[faction][key] = { kind, name, map, x, y, zone, seen, mine, confirmed, stock = {id=true} }
---------------------------------------------------------------------------
function Places:Table()
    local db = PC.db
    db.places = db.places or {}
    local f = PC:Faction()
    db.places[f] = db.places[f] or {}
    return db.places[f]
end

local function Key(kind, map, x, y, name)
    -- vendors are told apart by name; mailboxes/AHs by rounded position
    if kind == "vendor" or kind == "flight" or kind == "trainer" or kind == "inn" then return kind .. ":" .. (name or "?") .. ":" .. (map or 0) end
    if kind == "station" then return ("station:%s:%d:%d:%d"):format(name or "?", map or 0, math.floor((x or 0) * 50), math.floor((y or 0) * 50)) end
    return ("%s:%d:%d:%d"):format(kind, map or 0, math.floor((x or 0) * 50), math.floor((y or 0) * 50))
end

-- Where you are: map id, x, y (0-1), zone name
function Places:Here()
    if not C_Map or not C_Map.GetBestMapForUnit then return nil end
    local map = C_Map.GetBestMapForUnit("player")
    if not map then return nil end
    local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return nil end
    local x, y = pos.x, pos.y
    if (x == nil or y == nil) and pos.GetXY then x, y = pos:GetXY() end
    x, y = PC.Num(x), PC.Num(y) -- (secret at times: then we don't know where you are for now)
    if not x or not y then return nil end
    local info = C_Map.GetMapInfo and C_Map.GetMapInfo(map)
    return map, x, y, info and info.name or ""
end

Places.Key = Key

-- Remember the place you're at (extra: more fields to keep, e.g. prof for a trainer, repair for a vendor)
function Places:Learn(kind, name, stock, extra)
    if not PC:RouteOn() then return end
    local map, x, y, zone = self:Here()
    if not map then return end
    local t = self:Table()
    local key = Key(kind, map, x, y, name)
    local p = t[key] or { kind = kind, confirmed = false }
    -- where you stood isn't the spot itself (you click a mailbox or NPC from a few yards off), so
    -- your visits are averaged: from different sides they close in on the real spot
    if p.mine and p.map == map and p.x and p.y then
        local n = math.min(p.visits or 1, 4)
        x, y = (p.x * n + x) / (n + 1), (p.y * n + y) / (n + 1)
        p.visits = n + 1
    end
    p.name, p.map, p.x, p.y, p.zone = name or self.KINDS[kind], map, x, y, zone
    p.seen, p.mine, p.confirmed = time(), true, true
    if GetSubZoneText then p.sub = GetSubZoneText() end
    -- how high up it is, where the game says: a fire one floor above you is not a fire you can use
    local T = PC.Travel
    if T and T.HeightHere then p.z = T:HeightHere() or p.z end
    for k, v in pairs(extra or {}) do p[k] = v end
    p.wc = nil -- world position worked out again
    if stock then
        p.stock = p.stock or {}
        -- patterns, plans and recipes are always kept (the Learn tab needs every one); other items
        -- up to MAX_STOCK
        local inst = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
        local n = 0
        for id in pairs(stock) do
            local recipe = false
            if inst then local ok, _, _, _, _, _, classID = pcall(inst, id); recipe = ok and classID == 9 end
            if recipe or n < self.MAX_STOCK then
                p.stock[id] = true
                if not recipe then n = n + 1 end
            end
        end
    end
    t[key] = p
    self.allPlaces = nil
    if PC.Share and PC.Share.SharePlace then PC.Share:SharePlace(key, p) end
    return p
end

-- A place someone else told us about
function Places:Heard(key, p)
    -- a crossing someone made in a moment was their hearthstone, a summon or the graveyard, not a
    -- ride anyone can take: don't keep it
    if p and p.kind == "link" and (p.secs or 0) <= 30 then return end
    local t = self:Table()
    self.allPlaces = nil
    local have = t[key]
    if have and have.mine then return end -- our own visits always win
    if have then
        have.confirmed = true -- a second report confirms it
        for _, k in ipairs({ "prof", "repair", "sub", "tomap", "tox", "toy", "tozone", "secs", "via" }) do
            if have[k] == nil and p[k] ~= nil then have[k] = p[k] end
        end
        have.seen = math.max(have.seen or 0, p.seen or 0)
        if not have.mine then have.heard = time() end
        if p.stock then have.stock = have.stock or {}; for id in pairs(p.stock) do have.stock[id] = true end end
    else
        p.mine, p.confirmed = false, false
        p.heard = time()
        t[key] = p
    end
end

---------------------------------------------------------------------------
-- Places other Mostly Not Broken add-ons know (Snuggle Up Forever: the global MostlyNotBroken).
-- Only read, never changed; copies are kept here. Your faction or neutral only, and treated like
-- places other users told us about: unconfirmed until you've been there yourself.
---------------------------------------------------------------------------
Places.MNB_KINDS = { "vendor", "ah", "bank", "mail", "flight", "inn" }
Places.MNB_KEEP = 30 -- seconds a read is kept

function Places:MNB()
    local m = _G.MostlyNotBroken
    if type(m) == "table" and type(m.Each) == "function" then return m end
    return nil
end

local mapNames = {}
local function MapName(m)
    if mapNames[m] == nil then
        local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(m)
        mapNames[m] = info and info.name or false
    end
    return mapNames[m] or nil
end
Places.MapName = MapName

local function MyLetter()
    local f = PC:Faction()
    return (f == "Horde" and "H") or (f == "Alliance" and "A") or "N"
end

-- calls fn(key, place) for each MostlyNotBroken place of a kind (guarded)
function Places:MNBEach(kind, fn)
    local m = self:MNB()
    if not m then return end
    -- one bad place doesn't stop the rest; nothing is handed back to it
    pcall(m.Each, m, kind, function(key, pl) pcall(fn, key, pl) end)
end

-- MostlyNotBroken places (copies), your faction or neutral: { [key] = place }
function Places:Borrowed()
    local now = GetTime and GetTime() or 0
    local c = self.borrowed
    if c and now - c.t < self.MNB_KEEP then return c.list end
    local list = {}
    if self:MNB() then
        local my = MyLetter()
        for _, kind in ipairs(self.MNB_KINDS) do
            self:MNBEach(kind, function(_, pl)
                if type(pl) ~= "table" then return end
                local m, x, y = tonumber(pl.m), tonumber(pl.x), tonumber(pl.y)
                if not m or not x or not y or x <= 0 or x >= 1 or y <= 0 or y >= 1 then return end
                if pl.f ~= my and pl.f ~= "N" then return end
                local name = type(pl.n) == "string" and pl.n ~= "" and pl.n or self.KINDS[kind]
                local p = { kind = kind, name = name, map = m, x = x, y = y, zone = MapName(m) or "",
                    mine = false, confirmed = false, mnb = true, heard = 0 }
                if type(pl.sz) == "string" and pl.sz ~= "" then p.sub = pl.sz end
                if kind == "vendor" and type(pl.st) == "table" then
                    p.stock = {}
                    for id, v in pairs(pl.st) do if v and tonumber(id) then p.stock[tonumber(id)] = true end end
                end
                list[Key(kind, m, x, y, name)] = p
            end)
        end
    end
    self.borrowed = { t = now, list = list }
    self.allPlaces = nil
    return list
end

-- Every place to look through: your own and shared ones, plus the borrowed ones you don't know yet
-- (one you know at the same spot wins). Read only: learning still goes in Places:Table().
function Places:All()
    local t = self:Table()
    local b = self:Borrowed()
    if not next(b) then return t end
    local c = self.allPlaces
    if c and c.own == t and c.b == b then return c.list end -- (made again when either changes)
    local out, byMap = {}, {}
    for k, p in pairs(t) do
        out[k] = p
        if p.kind and p.map and p.x and p.y then
            local mk = p.kind .. ":" .. p.map
            byMap[mk] = byMap[mk] or {}
            table.insert(byMap[mk], p)
        end
    end
    for k, p in pairs(b) do
        local known = t[k] ~= nil
        if not known then
            for _, o in ipairs(byMap[p.kind .. ":" .. p.map] or {}) do
                if math.abs(o.x - p.x) < 0.02 and math.abs(o.y - p.y) < 0.02 then known = true break end
            end
        end
        if not known then out["mnb:" .. k] = p end
    end
    self.allPlaces = { own = t, b = b, list = out }
    return out
end

---------------------------------------------------------------------------
-- In a city: one of the big cities, or a map where you know an Auction House or bank. Out in the
-- world, ProfitCrafter only runs your plan: no bank, mail, selling or undercut tasks.
---------------------------------------------------------------------------
Places.CITY_NAMES = {
    ["Orgrimmar"] = true, ["Undercity"] = true, ["Thunder Bluff"] = true, ["Silvermoon City"] = true,
    ["Stormwind City"] = true, ["Ironforge"] = true, ["Darnassus"] = true, ["The Exodar"] = true,
    ["Shattrath City"] = true, ["Dalaran"] = true, ["Valdrakken"] = true, ["Dornogal"] = true,
    ["Oribos"] = true, ["Boralus"] = true, ["Dazar'alor"] = true,
}
function Places:InCity(map)
    map = map or self:Here()
    if not map then return false end
    local now = GetTime and GetTime() or 0
    local c = self.cityCache
    if c and c.map == map and now - c.t < 2 then return c.yes end
    local yes = self.CITY_NAMES[MapName(map) or ""] or false
    if not yes and PC.Travel and PC.Travel.IsCityMap then yes = PC.Travel:IsCityMap(map) and true or false end
    self.cityCache = { map = map, t = now, yes = yes }
    return yes
end

---------------------------------------------------------------------------
-- Finding the nearest place of a kind (same map only: no cross-zone distances without a route)
---------------------------------------------------------------------------
local function Dist(map, x, y, p)
    if p.map ~= map then return nil end
    local dx, dy = (p.x - x) * 100, (p.y - y) * 100 -- map units (0-100)
    return math.sqrt(dx * dx + dy * dy)
end

-- Nearest place of `kind`; for vendors, one that sells `itemID` (nil = any). Falls back to another zone.
function Places:Nearest(kind, itemID, name, test)
    local map, x, y = self:Here()
    local best, bestD, other
    local stars = map and self:StarMesh(map) -- in a city, how far it really is to walk there
    for _, p in pairs(self:All()) do
        if p.kind == kind and (not itemID or (p.stock and p.stock[itemID])) and (not name or (p.name or ""):lower() == name:lower())
            and (not test or test(p)) then
            local d = map and ((stars and self:StarDist(map, p)) or Dist(map, x, y, p))
            if d then
                if not bestD or d < bestD or (d == bestD and p.confirmed and not best.confirmed) then best, bestD = p, d end
            elseif not other or (p.confirmed and not other.confirmed) or (p.mine and not other.mine) then
                other = p
            end
        end
    end
    return best, bestD, other
end

---------------------------------------------------------------------------
-- The map pin (the game's own waypoint, or TomTom if you have it)
---------------------------------------------------------------------------
-- detail (optional): { title = "Get Light Leather from the mailbox", lines = { "2 Light Leather (in your mailbox)", ... } }
-- for the little window under the screen arrow; without it the window shows the label alone
function Places:Point(p, label, detail)
    if not p or not p.map then return false end
    self.current = p
    self.label = label -- what the pin is for, shown on the minimap arrow's tooltip
    self.detail = detail
    self:ShowArrow(p) -- our own arrow on the minimap, always
    -- only when the spot changes: setting the same waypoint again on every refresh restarted the game's
    -- marker over and over, so the one floating over the mailbox (or anywhere) never got to show
    local key = ("%s:%.4f:%.4f:%s"):format(p.map, p.x or 0, p.y or 0, tostring(label or p.name))
    self.pinned = nil -- set again below when the game or TomTom shows the way
    -- TomTom is the preferred arrow: its waypoint (titled ProfitCrafter Forever, what it's for underneath)
    -- and arrow show the way, and ours stay hidden. cleardistance 0: TomTom doesn't delete it when you arrive.
    if TomTom and TomTom.AddWaypoint then
        if self.tomtom and self.pointKey == key and self:TomTomValid() then self.pinned = true return true end
        if self.tomtom and TomTom.RemoveWaypoint then pcall(TomTom.RemoveWaypoint, TomTom, self.tomtom) end
        self.tomP, self.tomLabel = p, label
        local ok, uid = pcall(TomTom.AddWaypoint, TomTom, p.map, p.x, p.y, { title = PC.NAME .. "\n" .. (label or p.name or "next stop"),
            persistent = false, from = PC.NAME, cleardistance = 0, crazy = true })
        if ok and uid then self.tomtom, self.pointKey, self.pinned = uid, key, true return true end
    end
    local M, ST = C_Map, C_SuperTrack
    -- the game's own waypoint puts a second arrow on the minimap; ProfitCrafter's arrow does the job,
    -- so the game's is only used when turned on (db.gamePin). One left over from before is cleared.
    if not (PC.db and PC.db.gamePin == true) then
        if not self.clearedOld and M and M.GetUserWaypoint and M.ClearUserWaypoint then
            self.clearedOld = true
            local cur = M.GetUserWaypoint()
            if cur and cur.position then
                for _, q in pairs(self:Table()) do
                    if q.map == cur.uiMapID and q.x and math.abs(q.x - (cur.position.x or 0)) < 0.002
                        and math.abs(q.y - (cur.position.y or 0)) < 0.002 then
                        pcall(M.ClearUserWaypoint)
                        break
                    end
                end
            end
        end
        self.pointKey = key
        return true
    end
    if M and M.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
        local can = not M.CanSetUserWaypointOnMap or M.CanSetUserWaypointOnMap(p.map)
        if can then
            -- already there (and still ours: the game or you haven't moved it)? leave it be
            local cur = M.GetUserWaypoint and M.GetUserWaypoint()
            local same = cur and cur.uiMapID == p.map and cur.position
                and math.abs((cur.position.x or 0) - p.x) < 0.0005 and math.abs((cur.position.y or 0) - p.y) < 0.0005
            if not same then
                local ok = pcall(M.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(p.map, p.x, p.y))
                if not ok then return false end
            end
            self.pointKey = key
            -- keep the game's marker on OUR waypoint: a quest you pick up takes it over (that's when the
            -- marker over the mailbox disappeared), so it's taken back whenever it's not ours
            if ST and ST.SetSuperTrackedUserWaypoint then
                local tracking
                if ST.IsSuperTrackingUserWaypoint then
                    local ok2, t = pcall(ST.IsSuperTrackingUserWaypoint)
                    if ok2 then tracking = t and true or false end
                end
                local now = GetTime and GetTime() or 0
                if not same or tracking == false or (tracking == nil and now - (self.trackAt or 0) > 3) then
                    self.trackAt = now
                    pcall(ST.SetSuperTrackedUserWaypoint, true)
                end
            end
            return true
        end
    end
    return false
end

---------------------------------------------------------------------------
-- Our own arrow on the minimap (for clients without the game's waypoint pin, and as a backup)
---------------------------------------------------------------------------
Places.ARRIVE = 25 -- yards: within this the arrow and distance go away
-- our own arrow, drawn large and sharp (the game's minimap arrow is tiny and blurs when it's made bigger)
Places.ARROW = "Interface\\AddOns\\" .. ADDON .. "\\Media\\Arrow"
Places.ARROW_COLOR = { 0.78, 0.59, 0.18 } -- the add-on's gold (its window borders), not bright yellow
Places.ARROW_SCALE = 0.55 -- (the picture fills its square; the game's old one sat small in the middle of it: same size as before)

-- TomTom still has our waypoint (it can drop one): false = gone
function Places:TomTomValid()
    if not self.tomtom or not TomTom then return false end
    if TomTom.IsValidWaypoint then
        local ok, valid = pcall(TomTom.IsValidWaypoint, TomTom, self.tomtom)
        if ok and not valid then return false end
    end
    return true
end

function Places:Arrow()
    if self.arrow or not Minimap then return self.arrow end
    local a = CreateFrame("Frame", "ProfitCrafterMinimapArrow", Minimap)
    a:SetSize(30, 30)
    a:SetFrameStrata("MEDIUM")
    a:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 5)
    a.tex = a:CreateTexture(nil, "OVERLAY")
    a.tex:SetSize(30 * Places.ARROW_SCALE, 30 * Places.ARROW_SCALE)
    a.tex:SetPoint("CENTER")
    a.tex:SetTexture(Places.ARROW)
    a.tex:SetVertexColor(unpack(Places.ARROW_COLOR))
    a.label = a:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    a.label:SetPoint("CENTER", a, "CENTER", 0, 0) -- moved inward from the arrow every tick
    a:EnableMouse(true)
    a:SetScript("OnEnter", function(f)
        if GameTooltip and Places.current then
            GameTooltip:SetOwner(f, "ANCHOR_LEFT")
            GameTooltip:SetText(PC.NAME, 1, 0.82, 0)
            GameTooltip:AddLine(Places.label or "Next stop", 1, 1, 1, true)
            if Places.lastYards then GameTooltip:AddLine(("%d yd"):format(math.floor(Places.lastYards + 0.5)), 0.8, 0.8, 0.8) end
            GameTooltip:Show()
        end
    end)
    a:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    a:SetScript("OnMouseUp", function(_, button) Places:ArrowClicked(button) end)
    a:Hide()
    self.arrow = a
    return a
end

-- Yards and direction from you to p (same map). dxw/dyh are the east/south offsets in yards.
-- Uses the map's real size when the game gives it, else world positions, else a rough guess.
function Places:Offset(p, map, x, y)
    local dx, dy = p.x - x, p.y - y
    local M = C_Map
    if M and M.GetMapWorldSize then
        local ok, w, h = pcall(M.GetMapWorldSize, map)
        if ok and w and h and w > 0 and h > 0 then
            local ex, sy = dx * w, dy * h
            return math.sqrt(ex * ex + sy * sy), ex, sy
        end
    end
    if M and M.GetWorldPosFromMapPos and CreateVector2D then
        local ok1, _, a = pcall(M.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
        local ok2, _, b = pcall(M.GetWorldPosFromMapPos, map, CreateVector2D(p.x, p.y))
        if ok1 and ok2 and a and b then
            local ax, ay = a.x, a.y
            local bx, by = b.x, b.y
            if (not ax) and a.GetXY then ax, ay = a:GetXY() end
            if (not bx) and b.GetXY then bx, by = b:GetXY() end
            if ax and bx then
                -- world x is north, world y is west
                local north, west = bx - ax, by - ay
                return math.sqrt(north * north + west * west), -west, -north
            end
        end
    end
    local ex, sy = dx * 1000, dy * 1000
    return math.sqrt(ex * ex + sy * sy), ex, sy
end

-- Talking to something (mailbox, vendor, bank, AH, flight master, trainer, any NPC): the arrow
-- steps aside; it comes back when you walk off if the stop isn't done yet
local TALK_FRAMES = { "MailFrame", "MerchantFrame", "BankFrame", "AuctionFrame", "AuctionHouseFrame",
    "TaxiFrame", "FlightMapFrame", "ClassTrainerFrame", "GossipFrame", "QuestFrame" }
function Places:Talking()
    -- goes by the windows really on screen (and who the game says you're talking to), never by a
    -- remembered "it's open": one of those left over kept the screen arrow hidden for good
    for _, n in ipairs(TALK_FRAMES) do
        local f = _G[n]
        if f and f.IsShown and f:IsShown() then return true end
    end
    local m, PIT = C_PlayerInteractionManager, Enum and Enum.PlayerInteractionType
    if m and m.IsInteractingWithNpcOfType and PIT then
        for _, kind in ipairs({ "MailInfo", "Merchant", "Banker", "Auctioneer", "TaxiNode", "Trainer", "Gossip" }) do
            if PIT[kind] then
                local ok, v = pcall(m.IsInteractingWithNpcOfType, PIT[kind])
                if ok and v then return true end
            end
        end
    end
    return false
end

-- An arrow at the top of the screen pointing the way (turns as you turn), with the name and
-- distance: shown the whole way to any stop, gone within a yard of it or while you're using it
function Places:ScreenArrow()
    if self.sArrow or not UIParent then return self.sArrow end
    local f = CreateFrame("Frame", "ProfitCrafterScreenArrow", UIParent)
    f:SetSize(56, 56)
    self:PlaceScreenArrow(f)
    f:SetFrameStrata("HIGH")
    -- click and drag to move it; it stays where you put it
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(fr) fr:StartMoving() end)
    f:SetScript("OnMouseUp", function(fr, button)
        -- the end of a drag isn't a click
        if fr.dragStopAt and (GetTime and GetTime() or 0) - fr.dragStopAt < 0.15 then return end
        Places:ArrowClicked(button)
    end)
    f:SetScript("OnDragStop", function(fr)
        fr:StopMovingOrSizing()
        fr.dragStopAt = GetTime and GetTime() or 0
        local cx, cy = fr:GetCenter()
        local ux, uy = UIParent:GetCenter()
        if cx and ux and PC.db then PC.db.arrowPos = { x = cx - ux, y = cy - uy } end
    end)
    f:SetScript("OnEnter", function(fr)
        if GameTooltip then
            GameTooltip:SetOwner(fr, "ANCHOR_BOTTOM")
            GameTooltip:SetText(PC.NAME, 1, 0.82, 0)
            GameTooltip:AddLine(Places.label or "Next stop", 1, 1, 1, true)
            if Places:Unconfirmed(Places.current) then
                GameTooltip:AddLine("From another player and not checked yet. It's confirmed once you get there or a second player reports it.", 0.8, 0.8, 0.8, true)
            end
            GameTooltip:AddLine("Drag to move. /pc arrow reset puts it back.", 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end
    end)
    f:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    f.tex = f:CreateTexture(nil, "OVERLAY")
    f.tex:SetSize(56 * Places.ARROW_SCALE, 56 * Places.ARROW_SCALE)
    f.tex:SetPoint("CENTER")
    f.tex:SetTexture(Places.ARROW)
    f.tex:SetVertexColor(unpack(Places.ARROW_COLOR))
    -- what to do there, in its own little window under the arrow (like the "Bought on the AH" notes):
    -- the step on top with the distance on the right, then one line for each thing to get
    local box = CreateFrame("Frame", nil, f, "BackdropTemplate")
    box:SetPoint("TOP", f, "BOTTOM", 0, -2)
    box:SetSize(Places.BOX_MIN, 34)
    if box.SetBackdrop then
        box:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        box:SetBackdropColor(0.07, 0.05, 0.03, 0.94)
        box:SetBackdropBorderColor(0.78, 0.59, 0.18, 1)
    end
    if box.EnableMouse then box:EnableMouse(false) end -- (clicks go through to the world)
    f.box = box
    f.label = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.label:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -9)
    f.label:SetJustifyH("LEFT")
    if f.label.SetWordWrap then f.label:SetWordWrap(true) end
    if f.label.SetMaxLines then f.label:SetMaxLines(2) end
    f.dist = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.dist:SetPoint("TOPRIGHT", box, "TOPRIGHT", -10, -9)
    f.dist:SetJustifyH("RIGHT")
    f.body = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.body:SetPoint("TOPLEFT", f.label, "BOTTOMLEFT", 0, -5)
    f.body:SetJustifyH("LEFT")
    if f.body.SetSpacing then f.body:SetSpacing(2) end
    f:Hide()
    self.sArrow = f
    return f
end

Places.BOX_MIN, Places.BOX_MAX = 170, 330 -- the window under the arrow: how narrow and how wide it gets
Places.BOX_LINES = 5                       -- things listed in it (then "and N more")

-- What the window says: { title, lines }
function Places:BoxText(label)
    local d = self.detail
    if type(d) == "table" and d.title then return d.title, d.lines or {} end
    return label or "Next stop", {}
end

-- Fill the window and size it to fit (only when the words change; the distance changes every step)
local function Width(fs) return (fs and fs.GetStringWidth and fs:GetStringWidth()) or 0 end
local function Height(fs, n) return (fs and fs.GetStringHeight and fs:GetStringHeight()) or (n * 14) end
function Places:FillBox(f, title, lines, yards)
    f.dist:SetText(("%d yd"):format(math.min(math.floor(yards + 0.5), 999999)))
    local shown = {}
    for i, l in ipairs(lines) do
        if i > self.BOX_LINES then shown[#shown + 1] = ("|cff888888and %d more|r"):format(#lines - self.BOX_LINES) break end
        shown[#shown + 1] = l
    end
    local key = title .. "\n" .. table.concat(shown, "\n")
    if f.boxKey == key then return end
    f.boxKey = key
    f.label:SetWidth(0); f.body:SetWidth(0)
    f.label:SetText(title)
    f.body:SetText(table.concat(shown, "\n"))
    if #shown > 0 then f.body:Show() else f.body:Hide() end
    local distW = math.max(Width(f.dist), 40)
    local w = math.max(Width(f.label) + distW + 34, (#shown > 0 and Width(f.body) or 0) + 24, self.BOX_MIN)
    w = math.min(w, self.BOX_MAX)
    f.label:SetWidth(w - distW - 34)
    f.body:SetWidth(w - 22)
    local h = 18 + Height(f.label, 1) + (#shown > 0 and (Height(f.body, #shown) + 5) or 0)
    f.box:SetSize(w, h)
end

Places.SCREEN_ARRIVE = 1 -- yards: closer than this the screen arrow hides (it's back if you walk away)

function Places:PlaceScreenArrow(f)
    f = f or self.sArrow
    if not f then return end
    f:ClearAllPoints()
    local pos = PC.db and PC.db.arrowPos
    if pos and pos.x then f:SetPoint("CENTER", UIParent, "CENTER", pos.x, pos.y)
    else f:SetPoint("TOP", UIParent, "TOP", 0, -110) end
end

---------------------------------------------------------------------------
-- Zone exits: learned as you walk from one zone into the next, so a stop in another zone can be
-- reached on foot by heading for the way out (db.exits[fromMap] = { {x, y, to, tx, ty, zone}, ... })
---------------------------------------------------------------------------
Places.MAX_EXITS = 16

function Places:Exits()
    if not PC.db then return {} end
    PC.db.exits = PC.db.exits or {}
    return PC.db.exits
end

-- you walked from `a` (one map) into `b` (the next): remember where the border is
function Places:NoteCrossing(a, b)
    if not a or not b or not a.map or not b.map or a.map == b.map then return end
    if not PC:RouteOn() then return end
    -- Tirisfal into Undercity's map at ground level: that's the Ruins of Lordaeron's entrance (not a road);
    -- Mulgore and Thunder Bluff only meet at the elevators
    local T = PC.Travel
    if T and T.CityPair and T:CityPair(a.map, b.map) then
        if (a.map == 1420 and b.map == 1458) or (a.map == 1458 and b.map == 1420) then
            local t, u = a.map == 1420 and a or b, a.map == 1458 and a or b
            PC.db.ruinsEntrance = { tx = t.x, ty = t.y, ux = u.x, uy = u.y, t = time() }
        end
        return
    end
    local all = self:Exits()
    local list = all[a.map] or {}
    all[a.map] = list
    for _, e in ipairs(list) do
        if e.to == b.map and self:Offset(e, a.map, a.x, a.y) < 40 then
            -- the same crossing again: nudge it toward this one
            e.x, e.y = (e.x * 3 + a.x) / 4, (e.y * 3 + a.y) / 4
            e.tx, e.ty, e.seen = b.x, b.y, time()
            return
        end
    end
    list[#list + 1] = { map = a.map, x = a.x, y = a.y, to = b.map, tx = b.x, ty = b.y, zone = b.zone, seen = time() }
    self.allExits = nil
    while #list > self.MAX_EXITS do table.remove(list, 1) end
end

-- The main roads between zones (classic), as a start: where you cross from one zone into the next.
-- Placed from memory, so roughly right; any crossing you walk yourself replaces the one here.
-- { zone, x, y, other zone, x, y } (map percent), both ways
Places.CROSSINGS = {
    -- Kalimdor
    { "Durotar", 45.6, 12.1, "Orgrimmar", 49.0, 92.6 },
    { "Durotar", 34.4, 42.3, "The Barrens", 62.6, 20.8 },
    { "Mulgore", 68.6, 61.2, "The Barrens", 39.4, 58.7 },
    { "The Barrens", 44.6, 91.8, "Thousand Needles", 32.0, 21.5 },
    { "The Barrens", 48.2, 5.8, "Ashenvale", 71.5, 86.0 },
    { "The Barrens", 35.0, 27.6, "Stonetalon Mountains", 82.0, 96.0 },
    { "The Barrens", 59.0, 49.0, "Dustwallow Marsh", 28.5, 48.0 },
    -- Eastern Kingdoms
    { "Tirisfal Glades", 51.6, 68.3, "Silverpine Forest", 67.8, 4.6 },
    { "Silverpine Forest", 66.0, 79.0, "Hillsbrad Foothills", 13.0, 46.0 },
    { "Stranglethorn Vale", 39.0, 1.5, "Duskwood", 46.0, 97.0 },
    { "Elwynn Forest", 20.5, 82.0, "Westfall", 61.0, 18.0 },
    { "Elwynn Forest", 32.0, 49.5, "Stormwind City", 70.0, 89.0 },
    { "Dun Morogh", 53.4, 34.8, "Ironforge", 15.4, 85.0 },
    { "Dun Morogh", 84.0, 50.5, "Loch Modan", 21.0, 68.0 },
    { "Loch Modan", 25.0, 10.0, "Wetlands", 55.0, 74.0 },
    { "Wetlands", 49.5, 18.0, "Arathi Highlands", 44.5, 89.0 },
    { "Westfall", 68.5, 72.0, "Duskwood", 8.0, 48.0 },
    { "Hillsbrad Foothills", 87.0, 33.0, "Arathi Highlands", 19.0, 31.0 }, -- Thoradin's Wall (rough)
}

-- The crossings you've walked, plus the built-in ones between zones you haven't crossed yourself
-- (worked out again now and then: the map numbers come from the game)
function Places:AllExits()
    local now = GetTime and GetTime() or 0
    local learned = self:Exits()
    local c = self.allExits
    if c and now - c.t < 10 then return c.list end
    local all = {}
    -- (never between a city and the zone round it: Tirisfal/Undercity, Mulgore/Thunder Bluff)
    local T = PC.Travel
    local function cityPair(a, b) return T and T.CityPair and T:CityPair(a, b) end
    for m, list in pairs(learned) do
        all[m] = {}
        for _, e in ipairs(list) do if not cityPair(m, e.to) then table.insert(all[m], e) end end
    end
    -- crossings Snuggle Up (MostlyNotBroken) knows, where you haven't walked one between those zones
    self:MNBEach("cross", function(_, pl)
        if type(pl) ~= "table" then return end
        local m1, x1, y1 = tonumber(pl.m), tonumber(pl.x), tonumber(pl.y)
        local m2, x2, y2 = tonumber(pl.to), tonumber(pl.x2), tonumber(pl.y2)
        if not m1 or not x1 or not y1 or not m2 or not x2 or not y2 or m1 == m2 or cityPair(m1, m2) then return end
        all[m1] = all[m1] or {}
        for _, e in ipairs(all[m1]) do if e.to == m2 and not e.starter then return end end -- yours wins
        table.insert(all[m1], { map = m1, x = x1, y = y1, to = m2, tx = x2, ty = y2, zone = MapName(m2), starter = true, mnb = true })
    end)
    local zm = PC.ToLearn and PC.ToLearn.ZoneMap
    local function add(m1, x1, y1, m2, x2, y2, zone2)
        all[m1] = all[m1] or {}
        for _, e in ipairs(all[m1]) do if e.to == m2 then return end end -- yours (or Snuggle Up's) wins
        table.insert(all[m1], { map = m1, x = x1 / 100, y = y1 / 100, to = m2, tx = x2 / 100, ty = y2 / 100, zone = zone2, starter = true })
    end
    if zm then
        for _, t in ipairs(self.CROSSINGS) do
            local m1, m2 = zm(PC.ToLearn, t[1]), zm(PC.ToLearn, t[4])
            if m1 and m2 and not cityPair(m1, m2) then
                add(m1, t[2], t[3], m2, t[5], t[6], t[4])
                add(m2, t[5], t[6], m1, t[2], t[3], t[1])
            end
        end
    end
    self.allExits = { t = now, list = all }
    return all
end

-- yards and direction (east, south) from you to a point on any map on this continent
function Places:OffsetAny(t, map, x, y)
    if t.map == map then return self:Offset(t, map, x, y) end
    local T = PC.Travel
    if not T or not T.World then return nil end
    local c1, ax, ay = T:World(map, x, y)
    local c2, bx, by = T:World(t.map, t.x, t.y)
    if not c1 or not c2 or c1 ~= c2 then return nil end
    local north, west = bx - ax, by - ay
    return math.sqrt(north * north + west * west), -west, -north
end

-- What the arrows point at: the stop itself in this zone; else the way out toward it (a zone exit
-- you've walked through before), else straight at it when the game can tell where it is.
-- Returns target, label, final (true = the stop itself)
-- Someone else's spot that no second report (or your own visit) has backed up yet
function Places:Unconfirmed(p)
    return p and p.mine == false and not p.confirmed and true or false
end
Places.UNCONFIRMED = " |cffa0a0a0(unconfirmed)|r"

function Places:Aim(p, map, x, y)
    local t, label, final = self:AimRaw(p, map, x, y)
    -- your stars: on the way to a stop on this map the arrows go from star to star
    if t and t.map == map and self.NextStar then
        local ok, s = pcall(self.NextStar, self, t, map, x, y)
        if ok and s then return s, label, false end
    end
    return t, label, final
end

function Places:AimRaw(p, map, x, y)
    -- the arrow points where the NOW step says: the same spot as the pin (the route already splits the
    -- way into legs: the elevator, the Ruins, the road into the next zone, the flight master...)
    if p.map == map or self:OffsetAny(p, map, x, y) then return p, self.label or p.name or "Next stop", true end
    return nil
end

---------------------------------------------------------------------------
-- Walked ground (MostlyNotBroken): the arrows follow the roads people walk and keep out of trouble.
-- The yards always stay to the real spot; only the direction bends, and only gently.
---------------------------------------------------------------------------
Places.PATH_MAX_TURN = math.rad(50) -- never more than this off the straight direction to the stop
Places.PATH_MIN_YD = 80             -- closer than this: straight at it
Places.SMOOTH = 0.35                -- each tenth of a second the arrow turns this share of the way

-- the next walked-ground spot toward t, as a direction (east, south) from you; nil = go straight
function Places:GroundAim(t, map, x, y)
    local mnb = _G.MostlyNotBroken
    if type(mnb) ~= "table" or type(mnb.GroundAim) ~= "function" then return nil end
    local T = PC.Travel
    if not T or not T.World or not t then return nil end
    local c, wx, wy = T:World(map, x, y)
    local tc, tx, ty = T:World(t.map, t.x, t.y)
    if not c or not tc or c ~= tc then return nil end
    local ok, ax, ay = pcall(mnb.GroundAim, mnb, c, wx, wy, tx, ty)
    if not ok or type(ax) ~= "number" or type(ay) ~= "number" then return nil end
    return -(ay - wy), -(ax - wx) -- (world x is north, world y is west)
end

-- The roads (the shared MNBRoads.lua): the next road junction ahead (east, south from you) when you're on
-- the road, or the way to the road when you aren't; nil = no road helps
function Places:RoadAim(t, map, x, y)
    local R = _G.MostlyNotBrokenRoads
    if type(R) ~= "table" or type(R.Aim) ~= "function" then return nil end
    local T = PC.Travel
    if not T or not T.World or not t then return nil end
    local c, wx, wy = T:World(map, x, y)
    local tc, tx, ty = T:World(t.map, t.x, t.y)
    if not c or not tc or c ~= tc then return nil end
    local ok, ax, ay, on, jx, jy = pcall(R.Aim, R, c, wx, wy, tx, ty)
    if not ok or type(ax) ~= "number" then return nil end
    if on and jx then return -(jy - wy), -(jx - wx), true end
    -- off the road: walked ground to the road, if any, else straight to it
    local mnb = _G.MostlyNotBroken
    if type(mnb) == "table" and type(mnb.GroundAim) == "function" then
        local ok2, gx, gy = pcall(mnb.GroundAim, mnb, c, wx, wy, ax, ay)
        if ok2 and type(gx) == "number" then return -(gy - wy), -(gx - wx), false end
    end
    return -(ay - wy), -(ax - wx), false
end

-- The arrows' direction this tick (radians, screen angle from east): walked ground when it bends
-- gently off the straight line and the stop is a fair way off, turned smoothly toward
function Places:Bearing(t, map, x, y, yards, ex, sy)
    local atan2 = math.atan2 or function(yy, xx) return math.atan(yy, xx) end
    self.why = "straight at the stop"
    local rex, rsy, onRoad
    -- in Undercity, up in the Ruins of Lordaeron and in Thunder Bluff the arrow goes straight at the
    -- stop: those places sit on top of each other on the map, so "the nearest road" can be on another
    -- level (it sent the arrow back toward the elevator when the way out of the Ruins was the other way)
    local stacked = map == 1458 or map == 1456 or (PC.Travel and PC.Travel.InRuins and PC.Travel:InRuins())
    if stacked then yards = nil; self.why = "straight at the stop (city levels)" end
    if yards and yards > self.PATH_MIN_YD then rex, rsy, onRoad = self:RoadAim(t, map, x, y) end
    if rex and (rex ~= 0 or rsy ~= 0) then
        -- by road: the next junction, or the way to the road (round the mountain, wherever it goes)
        ex, sy = rex, rsy
        self.why = onRoad and "along the road, to the next junction" or "to the road"
    elseif yards and yards > self.PATH_MIN_YD then
        local pex, psy = self:GroundAim(t, map, x, y)
        if pex then
            local dl, pl = math.sqrt(ex * ex + sy * sy), math.sqrt(pex * pex + psy * psy)
            if dl > 0 and pl > 0 and (ex * pex + sy * psy) / (dl * pl) >= math.cos(self.PATH_MAX_TURN) then
                ex, sy = pex, psy
                self.why = "along walked ground"
            else
                self.why = "straight at the stop (walked ground turned too far off)"
            end
        end
    end
    local want = atan2(-sy, ex)
    local key = ("%s:%.4f:%.4f"):format(tostring(t.map), t.x or 0, t.y or 0)
    local cur = self.bearing
    if not cur or self.bearingKey ~= key then
        cur = want
    else
        local d = (want - cur + math.pi) % (2 * math.pi) - math.pi
        cur = cur + d * self.SMOOTH
    end
    self.bearing, self.bearingKey = cur, key
    return cur
end

-- this tick's direction, when it was worked out for this same target
function Places:BearingFor(t)
    if not self.curBearing or not t then return nil end
    local key = ("%s:%.4f:%.4f"):format(tostring(t.map), t.x or 0, t.y or 0)
    return self.bearingKey == key and self.curBearing or nil
end

function Places:TickScreenArrow(p, map, x, y)
    local f = self:ScreenArrow()
    if not f then return end
    -- off in settings, or TomTom is showing the way (its own arrow): ours stays out of it
    if not p or not map or not PC:RouteOn() or self.tomtom
        or self:Talking() then f:Hide() return end
    local t, label, final = self:Aim(p, map, x, y)
    if not t then f:Hide() return end
    -- which way you face can be kept secret (in combat): no arrow until it's known again
    if GetPlayerFacing and PC.IsSecret(GetPlayerFacing()) then f:Hide() return end
    local yards, ex, sy = self:OffsetAny(t, map, x, y)
    if not yards then f:Hide() return end
    if not final and yards <= 3 then
        -- at the zone exit: keep going the same way, into the next zone
        local T = PC.Travel
        local c1, ax, ay = T and T:World(t.map, t.x, t.y)
        local c2, bx, by = T and T:World(t.to, t.tx, t.ty)
        if c1 and c2 and c1 == c2 and (ax ~= bx or ay ~= by) then ex, sy = -(by - ay), -(bx - ax) end
    elseif yards <= self.SCREEN_ARRIVE then
        f:Hide() return
    end
    local atan2 = math.atan2 or function(yy, xx) return math.atan(yy, xx) end
    local facing = PC.Num(GetPlayerFacing and GetPlayerFacing()) or 0
    -- the bearing from north (south grows downward), turned by where you face: straight up = ahead
    -- (your own turning shows at once; the direction itself turns smoothly)
    if ex ~= 0 or sy ~= 0 then
        local ang = (not final and yards <= 3) and atan2(-sy, ex) or (self:BearingFor(t) or atan2(-sy, ex))
        local rel = ang - math.pi / 2 - facing
        if f.tex.SetRotation then f.tex:SetRotation(rel) end
    end
    local title, lines = self:BoxText(label)
    self:FillBox(f, title, lines, yards)
    f:Show()
end

-- /pc arrow why: what the arrow points at, and why that way
function Places:ArrowWhy()
    local p = self.current
    if not p then return PC.Print("The arrow has nowhere to point right now.") end
    local map, x, y = self:Here()
    local yards, ex, sy = self:OffsetAny(p, map, x, y)
    local function dir(e, s2)
        if not e then return "?" end
        local atan2 = math.atan2 or function(a, b) return math.atan(a, b) end
        local deg = math.deg(atan2(e, -s2)) % 360 -- compass: 0 north, 90 east
        local names = { "north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west" }
        return ("%s (%d)"):format(names[math.floor((deg + 22.5) / 45) % 8 + 1], math.floor(deg + 0.5))
    end
    local pex, psy = self:GroundAim(p, map, x, y)
    PC.Print(("Arrow: %s, %d yd to %s at %.1f, %.1f."):format(self.label or "next stop", math.floor((yards or 0) + 0.5),
        p.name or "the stop", (p.x or 0) * 100, (p.y or 0) * 100))
    print(("  The stop is %s of you. Walked ground says %s. Pointing %s."):format(dir(ex, sy),
        pex and dir(pex, psy) or "nothing", self.why or "straight at the stop"))
end

-- One ticker for both arrows (ten times a second), always running while there's a stop, so the
-- screen arrow keeps working even when the minimap one is hidden
function Places:Ticker()
    if self.ticker or not CreateFrame then return end
    local t = CreateFrame("Frame")
    t:SetScript("OnUpdate", function(f, dt)
        f.acc = (f.acc or 0) + (dt or 0)
        if f.acc < 0.1 then return end
        f.acc = 0
        if Places.current then Places:TickArrow() end
    end)
    self.ticker = t
end

-- another MostlyNotBroken add-on is showing the way right now (Fishmonger's "Go fish here"): only one
-- arrow at a time, so ours steps aside until it's done
-- Double-click either arrow: wayfinding stops (the arrows stay off until the next stop is somewhere else)
function Places:PinKey(p)
    return p and ("%s:%.4f:%.4f"):format(tostring(p.map), p.x or 0, p.y or 0) or nil
end

function Places:ArrowClicked(button)
    if button ~= "LeftButton" then return end
    local now = GetTime and GetTime() or 0
    if self.lastClick and now - self.lastClick <= 0.4 then
        self.lastClick = nil
        self.offKey = self:PinKey(self.current)
        if self.arrow then self.arrow:Hide() end
        if self.sArrow then self.sArrow:Hide() end
        if GameTooltip then GameTooltip:Hide() end
        PC.Print("Wayfinding stopped.")
        return
    end
    self.lastClick = now
end

function Places:OtherGuiding()
    -- (or just in use: Fishmonger's fishing session or its window open)
    for _, k in ipairs({ "MostlyNotBrokenWay", "MostlyNotBrokenBusy" }) do
        local w = _G[k]
        if w and w.by and w.by ~= PC.NAME then return true end
    end
    return false
end

function Places:TickArrow()
    if PC.inCombat or self:OtherGuiding() or (self.offKey and self.offKey == self:PinKey(self.current)) then
        if self.arrow then self.arrow:Hide() end
        if self.sArrow then self.sArrow:Hide() end
        return
    end
    -- TomTom dropped our waypoint (you removed it, or it cleared itself): put it back
    -- (looked at once a second)
    local nowT = GetTime and GetTime() or 0
    local look = nowT - (self.tomCheck or -10) >= 1
    if look then self.tomCheck = nowT end
    if look and self.tomtom and self.current and TomTom and not self:TomTomValid() then
        self.tomtom = nil
        pcall(self.Point, self, self.current, self.label)
    end
    local a, p = self.arrow, self.current
    if not p then
        if a then a:Hide() end
        if self.sArrow then self.sArrow:Hide() end
        return
    end
    -- on a flight: nothing to point at until you land (then it picks up from where you are)
    if UnitOnTaxi and UnitOnTaxi("player") then
        if a then a:Hide() end
        if self.sArrow then self.sArrow:Hide() end
        self.lastSpot = nil
        return
    end
    local map, x, y = self:Here()
    -- walked into another zone: remember where the border is (for pointing the way out later)
    local now = GetTime and GetTime() or 0
    local last = self.lastSpot
    if map and last and last.map ~= map and now - (last.t or 0) < 1 and not (UnitOnTaxi and UnitOnTaxi("player")) then
        local far = PC.Travel and PC.Travel.Yards and PC.Travel:Yards(last, { map = map, x = x, y = y })
        if not far or far < 60 then -- not a portal, boat or hearth
            self:NoteCrossing(last, { map = map, x = x, y = y, zone = select(4, self:Here()) })
        end
    end
    if map then self.lastSpot = { map = map, x = x, y = y, t = now } end
    -- one direction for both arrows this tick (walked ground, turned smoothly)
    self.curBearing = nil
    if map then
        local t0 = self:Aim(p, map, x, y)
        local yd, e0, s0
        if t0 then yd, e0, s0 = self:OffsetAny(t0, map, x, y) end
        if yd and (e0 ~= 0 or s0 ~= 0) then self.curBearing = self:Bearing(t0, map, x, y, yd, e0, s0) end
    end
    self:TickScreenArrow(p, map, x, y)
    if not a or not Minimap then return end
    if not map then a:Hide() return end
    local t, _, final = self:Aim(p, map, x, y)
    if not t then a:Hide() return end
    if t.map == map then
        local dx, dy = t.x - x, t.y - y
        self.lastDist = math.sqrt(dx * dx + dy * dy) * 100 -- map units
    end
    local yards, ex, sy = self:OffsetAny(t, map, x, y)
    if not yards then a:Hide() return end
    self.lastYards = yards
    if final and yards < self.ARRIVE then a:Hide() return end
    -- TomTom shows the way (its waypoint and arrow): just the one arrow
    if self.tomtom and self.pinned then a:Hide() return end
    local facing = PC.Num(GetPlayerFacing and GetPlayerFacing()) or 0
    -- south grows downward, so -sy is north. With north up (the default) the bearing is the screen angle;
    -- with "rotate minimap" on, the player's facing is up instead, so the bearing turns back by the facing.
    local atan2 = math.atan2 or function(yy, xx) return math.atan(yy, xx) end
    local angle = self:BearingFor(t) or atan2(-sy, ex)
    if GetCVar and GetCVar("rotateMinimap") == "1" then angle = angle - facing end
    local r = (Minimap:GetWidth() or 140) / 2 - 8
    -- always on the rim, pointing the way, with the distance just inside it (never over the arrow)
    local px, py = math.cos(angle) * r, math.sin(angle) * r
    a:ClearAllPoints()
    a:SetPoint("CENTER", Minimap, "CENTER", px, py)
    if a.tex.SetRotation then a.tex:SetRotation(angle - math.pi / 2) end
    local lr = r - 26
    a.label:ClearAllPoints()
    a.label:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * lr, math.sin(angle) * lr)
    a.label:SetText(("%d yd"):format(math.min(math.floor(yards + 0.5), 999999)))
    a:Show()
end

function Places:ShowArrow(p)
    self:Arrow()
    self:Ticker()
    self.current = p
    self:TickArrow()
end

function Places:ClearPin()
    if not self.current then return end
    self.current = nil
    if self.arrow then self.arrow:Hide() end
    if self.sArrow then self.sArrow:Hide() end
    if self.tomtom and TomTom and TomTom.RemoveWaypoint then pcall(TomTom.RemoveWaypoint, TomTom, self.tomtom); self.tomtom = nil end
    self.pointKey, self.pinned = nil, nil
    if C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
end

-- Text for where to go: "Tailoring Supplies, Orgrimmar (120 yd)" / "Auction House, Thunder Bluff (other zone)"
function Places:Describe(p, d)
    if not p then return nil end
    local where = p.zone and p.zone ~= "" and (", " .. p.zone) or ""
    -- (1e9 = "somewhere else": a far-off or unknown place sorts last; it's no distance to show)
    local how = (d and d < 1e6) and (("%d yd"):format(math.floor(d * 10))) or "other zone" -- map units are roughly 10 yards
    return ("%s%s (%s%s)"):format(p.name or self.KINDS[p.kind] or "?", where, how, p.confirmed and "" or ", unconfirmed")
end

---------------------------------------------------------------------------
-- Getting there from another zone: the flight masters you've used
---------------------------------------------------------------------------
-- Flight master in the zone you're in, and one in the zone of the destination
function Places:FlightHint(dest)
    if not dest or not dest.map then return nil end
    local map = self:Here()
    if not map or map == dest.map then return nil end
    local there
    for _, p in pairs(self:Table()) do
        if p.kind == "flight" and p.map == dest.map then there = p break end
    end
    local here = self:Nearest("flight")
    if there and here then
        return ("Take the flight from %s to %s (lands at %s), then go to %s."):format(here.name or "the flight master", dest.zone or "that zone", there.name or "?", dest.name or "")
    elseif there then
        return ("Take a flight to %s (flight master there: %s)."):format(dest.zone or "that zone", there.name or "?")
    end
    return ("It's in %s. Use a flight path, boat or zeppelin to get there."):format(dest.zone or "another zone")
end

---------------------------------------------------------------------------
-- Ordering stops: nearest first, each vendor visit covering everything it sells
---------------------------------------------------------------------------
-- stops: list of { kind, itemID (vendors) }. Returns ordered { place, kind, items = {...}, d }
function Places:Route(stops)
    local groups = {}
    for _, st in ipairs(stops) do
        local p, d, other = self:Nearest(st.kind, st.itemID)
        local place = p or other
        if place then
            local g = groups[place]
            if not g then g = { place = place, kind = st.kind, items = {}, d = d or 1e9 }; groups[place] = g end
            if st.itemID then g.items[#g.items + 1] = st.itemID end
        else
            groups["?" .. st.kind .. (st.itemID or "")] = { kind = st.kind, items = { st.itemID }, d = 1e9, unknown = true }
        end
    end
    local out = {}
    for _, g in pairs(groups) do out[#out + 1] = g end
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

---------------------------------------------------------------------------
-- Learning as you play
---------------------------------------------------------------------------
local function MerchantStock()
    local stock = {}
    if not GetMerchantNumItems then return stock end
    for i = 1, GetMerchantNumItems() or 0 do
        local id
        if GetMerchantItemID then local ok, v = pcall(GetMerchantItemID, i); if ok then id = v end end
        if not id and GetMerchantItemLink then
            local link = GetMerchantItemLink(i)
            id = link and tonumber(link:match("item:(%d+)"))
        end
        if id then stock[id] = true end
    end
    return stock
end

-- the auctioneer / banker you're talking to: remembered by name (for the star over their head)
function Places:NoteRole(kind)
    local name = UnitName and UnitName("npc")
    if not name or name == "" or not PC.db then return end
    PC.db.npcRoles = PC.db.npcRoles or {}
    PC.db.npcRoles[name] = kind
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "MERCHANT_SHOW", "AUCTION_HOUSE_SHOW", "MAIL_SHOW", "TAXIMAP_OPENED", "BANKFRAME_OPENED" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, event)
    PC:Safe("places", function()
        if event == "MERCHANT_SHOW" then
            Places:Learn("vendor", UnitName and UnitName("npc") or "Vendor", MerchantStock())
        elseif event == "AUCTION_HOUSE_SHOW" then
            Places:Learn("ah", "Auction House")
            Places:NoteRole("ah")
        elseif event == "MAIL_SHOW" then
            Places:Learn("mail", "Mailbox")
        elseif event == "TAXIMAP_OPENED" then
            Places:Learn("flight", UnitName and UnitName("npc") or "Flight master")
        elseif event == "BANKFRAME_OPENED" then
            Places:Learn("bank", "Bank")
            Places:NoteRole("bank")
        end
    end)
end)

---------------------------------------------------------------------------
-- A star over the NPC your step sends you to, once they're close enough to see
---------------------------------------------------------------------------
-- Drawn by us, over the NPC's nameplate: the game's own raid markers can only be set from a click,
-- so setting one by itself gets the addon blocked.
Places.STAR_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"

-- who the step on the bar wants you to go to: { name = NPC name or nil, role = title words or nil }
-- (the AH and bank are learned as places, not people: any auctioneer or banker gets the star)
local ROLES = {
    ah = { "Auctioneer" }, bank = { "Banker" }, inn = { "Innkeeper" },
    flight = { "Flight Master", "Wind Rider Master", "Gryphon Master", "Hippogryph Master", "Bat Handler" },
    trainer = { "Trainer" },
}
function Places:StarTarget()
    if not PC:RouteOn() then return nil end
    local s = PC.Next and PC.Next.shown
    -- the stop you're heading to right now: the flight master on the way, or the stop itself
    -- (the step you're on now wins over an older pin, like the flight master before a flight)
    if s and s.flying then return nil end
    local p = (s and (s.pin or s.dest)) or self.current
    if not p then return nil end
    -- places that aren't a person: mailboxes, portals, boats, crafting stations
    if p.kind == "mail" or p.kind == "mailbox" or p.kind == "link" or p.kind == "portal" or p.kind == "station"
        or p.kind == "elevator" or p.kind == "lift" or p.kind == "ruins" or p.kind == "cross" or p.kind == "cross2"
        or p.kind == "dock" then return nil end
    local generic = { ["Auction House"] = true, ["Bank"] = true, ["Innkeeper"] = true, ["Flight master"] = true, ["Trainer"] = true, ["Vendor"] = true }
    local name = p.name and p.name ~= "" and not generic[p.name] and p.name or nil
    local role = ROLES[p.kind]
    if not name and not role then return nil end
    return { name = name, role = role, prof = p.prof, kind = p.kind, place = p }
end

-- The star sits on the NPC's nameplate, and the game gives friendly NPCs one only once you click them
-- (unless friendly NPC nameplates are on). So near the stop they're turned on for you, and put back the
-- way you had them as soon as you're done there or walk away. (Not in combat: the game locks them then.)
Places.NPC_PLATES = "nameplateShowFriendlyNPCs"
Places.NPC_PLATES_NEAR = 60 -- yards from the stop
function Places:NpcPlates(on)
    if not (GetCVar and SetCVar) or (InCombatLockdown and InCombatLockdown()) then return end
    if PC.db and PC.db.starPlates == false then on = false end
    local db = PC.db
    if not db then return end
    if on then
        if db.npcPlatesWas == nil then
            local was = GetCVar(self.NPC_PLATES)
            if was == nil or was == "1" then return end -- already on (yours): nothing to do or undo
            db.npcPlatesWas = was
            pcall(SetCVar, self.NPC_PLATES, "1")
        end
    elseif db.npcPlatesWas ~= nil then
        pcall(SetCVar, self.NPC_PLATES, db.npcPlatesWas)
        db.npcPlatesWas = nil
    end
end
function Places:StarNear(want)
    local p = want and want.place
    if not p then return false end
    local map, x, y = self:Here()
    local yards = map and self:OffsetAny(p, map, x, y)
    return yards ~= nil and yards <= self.NPC_PLATES_NEAR
end

-- the title under an NPC's name ("<Banker>"), read from the game's own tooltip data
Places.titles = {}
local scanTip
function Places:UnitTitle(u)
    local guid = UnitGUID and UnitGUID(u)
    if guid and self.titles[guid] then return self.titles[guid] end
    local title
    if C_TooltipInfo and C_TooltipInfo.GetUnit then
        local ok, data = pcall(C_TooltipInfo.GetUnit, u)
        local line = ok and data and data.lines and data.lines[2]
        title = line and line.leftText
    elseif CreateFrame and UIParent then
        scanTip = scanTip or CreateFrame("GameTooltip", "ProfitCrafterScanTip", UIParent, "GameTooltipTemplate")
        scanTip:SetOwner(UIParent, "ANCHOR_NONE")
        pcall(scanTip.SetUnit, scanTip, u)
        local fs = _G["ProfitCrafterScanTipTextLeft2"]
        title = fs and fs.GetText and fs:GetText()
        scanTip:Hide()
    end
    if type(title) ~= "string" or title == "" then title = nil end
    -- remembered only once found: the title often isn't loaded the first time a nameplate appears
    if guid and title then self.titles[guid] = title end
    return title
end

function Places:IsStarUnit(u, want)
    if not UnitExists(u) or (UnitIsPlayer and UnitIsPlayer(u)) then return false end
    local name = UnitName(u)
    if want.name then return name == want.name end
    -- auctioneers and bankers you've used: known by name, no title needed
    local known = PC.db and PC.db.npcRoles and PC.db.npcRoles[name]
    if known and want.kind and known == want.kind then return true end
    local title = self:UnitTitle(u)
    if not title then return false end
    for _, r in ipairs(want.role or {}) do
        if title:find(r, 1, true) then
            -- a trainer: the right profession's trainer
            if r == "Trainer" and want.prof and not title:find(want.prof, 1, true) then return false end
            return true
        end
    end
    return false
end

function Places:StarFrame()
    if self.star then return self.star end
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(38, 38)
    f:SetFrameStrata("HIGH")
    f.tex = f:CreateTexture(nil, "OVERLAY")
    f.tex:SetAllPoints(f)
    f.tex:SetTexture(self.STAR_ICON)
    f:Hide()
    self.star = f
    return f
end

-- put the star over the right NPC's nameplate, or hide it
-- A mailbox has no nameplate to put a star on: the game's own waypoint marker (set by Places:Point
-- for every destination) is what floats over it. When that can't show, say why once in chat.
function Places:CheckStar()
    local f = self:StarFrame()
    local want = self:StarTarget()
    self:NpcPlates(want ~= nil and self:StarNear(want))
    local plate
    if want and C_NamePlate and C_NamePlate.GetNamePlateForUnit and UnitExists then
        for i = 1, 40 do
            local u = "nameplate" .. i
            if self:IsStarUnit(u, want) then
                plate = C_NamePlate.GetNamePlateForUnit(u) -- nil where the game keeps nameplates to itself
                if plate then break end
            end
        end
    end
    if plate then
        local ok = pcall(function()
            f:ClearAllPoints()
            f:SetPoint("BOTTOM", plate, "TOP", 0, 45) -- well above the name, easy to spot
        end)
        f:SetShown(ok)
        self.starUnitName = ok and (want.name or (want.role and want.role[1])) or nil
    else
        f:Hide()
        self.starUnitName = nil
    end
end

local starEv = CreateFrame("Frame")
for _, e in ipairs({ "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED" }) do pcall(starEv.RegisterEvent, starEv, e) end
starEv:SetScript("OnEvent", function() PC:Safe("star", Places.CheckStar, Places) end)
-- and every second: the stop can change while its NPC is already in view (you land, the step moves on)
starEv.left = 1
starEv:SetScript("OnUpdate", function(f, dt)
    f.left = f.left - (dt or 0)
    if f.left > 0 then return end
    f.left = 1
    PC:Safe("star", Places.CheckStar, Places)
end)

---------------------------------------------------------------------------
-- Markers on the world map: where you're heading now (a star) and each stop of the Recipe Run (numbered).
-- Drawn by ProfitCrafter itself on whatever map you're looking at (zone or continent).
---------------------------------------------------------------------------
Places.MAP_PIN = 22 -- size on screen
function Places:MapCanvas()
    local W = WorldMapFrame
    if not W or not W.IsShown or not W:IsShown() then return nil end
    local c = (W.GetCanvas and W:GetCanvas()) or (W.ScrollContainer and W.ScrollContainer.Child)
    local mapID = W.GetMapID and W:GetMapID()
    return c, mapID
end

-- a place's spot on the map you're looking at (0-1), or nil when it isn't on it
function Places:OnMap(p, mapID)
    if not p or not p.map or not p.x or not mapID then return nil end
    if p.map == mapID then return p.x, p.y end
    local T = PC.Travel
    if not (T and C_Map and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return nil end
    local cont, wx, wy = T:World(p.map, p.x, p.y)
    if not cont then return nil end
    local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, cont, CreateVector2D(wx, wy), mapID)
    if not ok or not pos then return nil end
    local x, y = pos.x, pos.y
    if (x == nil or y == nil) and pos.GetXY then x, y = pos:GetXY() end
    x, y = PC.Num(x), PC.Num(y)
    if not x or not y or x < 0 or x > 1 or y < 0 or y > 1 then return nil end
    return x, y
end

-- what to mark: { place, label, n (stop number) or nil for the current stop }
function Places:MapMarks()
    local out = {}
    if not PC:RouteOn() then return out end
    local s = PC.Next and PC.Next.shown
    local cur = s and not s.flying and (s.pin or s.dest)
    if cur and cur.map then out[#out + 1] = { place = cur, label = (PC.Next and PC.Next.PinText and PC.Next:PinText(s)) or s.text or cur.name or "Next stop" } end
    local TL = PC.ToLearn
    if TL and TL.Data then
        local trip = TL.Data().trip
        if #trip > 0 then
            local byKey = {}
            for _, e in ipairs(TL:List()) do byKey[e.key] = e end
            for i, k in ipairs(trip) do
                local e = byKey[k]
                if e and e.place and e.place.map then
                    out[#out + 1] = { place = e.place, n = i, label = ("Stop %d: %s (%s)"):format(i, e.name, e.where or e.place.name or "?") }
                end
            end
        end
    end
    return out
end

function Places:DrawMapPins()
    local canvas, mapID = self:MapCanvas()
    self.mapPins = self.mapPins or {}
    local pins = self.mapPins
    local used = 0
    if canvas and mapID then
        local w, h = canvas:GetWidth(), canvas:GetHeight()
        local scale = (canvas.GetEffectiveScale and canvas:GetEffectiveScale() or 1) / ((UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1)
        local size = self.MAP_PIN / math.max(scale, 0.01)
        for _, m in ipairs(self:MapMarks()) do
            local x, y = self:OnMap(m.place, mapID)
            if x and w and w > 0 then
                used = used + 1
                local pin = pins[used]
                if not pin then
                    pin = CreateFrame("Frame", nil, canvas)
                    pin.tex = pin:CreateTexture(nil, "OVERLAY")
                    pin.tex:SetAllPoints(pin)
                    pin.num = pin:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                    pin.num:SetPoint("CENTER", 0, 0)
                    pin:EnableMouse(true)
                    pin:SetScript("OnEnter", function(f)
                        if GameTooltip then
                            GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
                            GameTooltip:AddLine(PC.NAME, 1, 0.82, 0)
                            GameTooltip:AddLine(f.label or "", 1, 1, 1, true)
                            GameTooltip:Show()
                        end
                    end)
                    pin:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
                    pins[used] = pin
                end
                if pin:GetParent() ~= canvas then pin:SetParent(canvas) end
                pin:SetFrameStrata("HIGH")
                pin:SetSize(size, size)
                pin:ClearAllPoints()
                pin:SetPoint("CENTER", canvas, "TOPLEFT", x * w, -y * h)
                pin.label = m.label
                if m.n then
                    pin.tex:SetTexture("Interface\\COMMON\\Indicator-Yellow")
                    pin.num:SetText(tostring(m.n))
                    pin.num:Show()
                else
                    pin.tex:SetTexture(self.STAR_ICON)
                    pin.num:Hide()
                end
                pin:Show()
            end
        end
    end
    for i = used + 1, #pins do pins[i]:Hide() end
end

do
    local f = CreateFrame("Frame")
    f.left = 0
    f:SetScript("OnUpdate", function(fr, dt)
        fr.left = fr.left - (dt or 0)
        if fr.left > 0 then return end
        fr.left = 0.5
        -- only while the world map is open (and once more after it closes, to tidy up)
        local shown = WorldMapFrame and WorldMapFrame.IsShown and WorldMapFrame:IsShown()
        if shown or fr.wasShown then PC:Safe("map pins", Places.DrawMapPins, Places) end
        fr.wasShown = shown
    end)
end

---------------------------------------------------------------------------
-- Stars: waypoints you put down yourself (a key, Page Up to start with) at the turns that matter:
-- in front of an elevator, before a door, at a corner. Stars put down one after another are joined
-- up, so the way runs star to star; both arrows point at the next one and they show on the minimap.
-- Kept per map and per level (inside a city, on top of it, outside).
---------------------------------------------------------------------------
Places.STAR_NEAR = 7     -- yards: this close and the arrow moves on to the next star
Places.STAR_JOIN = 200   -- yards: stars further apart than this aren't joined up
Places.STAR_JOIN_SECS = 600
Places.STAR_ART = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"

local function StarLevel(map)
    local T = PC.Travel
    return T and T.SideHere and tostring(T:SideHere(map)) or "out"
end

function Places:Stars(map)
    PC.db.cityStars = PC.db.cityStars or {}
    PC.db.cityStars[map] = PC.db.cityStars[map] or {}
    return PC.db.cityStars[map]
end

-- copies to measure with (the saved ones stay clean), rebuilt when the list changes
function Places:StarPoints(map)
    local list = PC.db and PC.db.cityStars and PC.db.cityStars[map]
    if not list or #list == 0 then return nil end
    self.starPts = self.starPts or {}
    local c = self.starPts[map]
    if not c or c.rev ~= (self.starRev or 0) or c.n ~= #list then
        c = { rev = self.starRev or 0, n = #list, pts = {} }
        for i, s in ipairs(list) do c.pts[i] = { map = map, x = s.x, y = s.y, id = s.id, side = s.side, links = s.links or {} } end
        self.starPts[map] = c
    end
    return c.pts
end

-- the key: a star where you stand; standing on one takes it away again
function Places:MarkStar()
    local map, x, y = self:Here()
    if not map or not x then return PC.Print("Can't tell where you are right now: try again in a moment.") end
    local list = self:Stars(map)
    local T = PC.Travel
    local level = StarLevel(map)
    local me = { map = map, x = x, y = y }
    local now = time()
    for i, s in ipairs(list) do
        local yd = T and T:Yards(me, { map = map, x = s.x, y = s.y })
        if s.side == level and yd and yd <= self.STAR_NEAR then
            table.remove(list, i)
            for _, o in ipairs(list) do
                for k = #(o.links or {}), 1, -1 do if o.links[k] == s.id then table.remove(o.links, k) end end
            end
            self.starRev = (self.starRev or 0) + 1
            self.lastStar = nil
            PC.Print("Star removed.")
            self:DrawStars()
            return
        end
    end
    PC.db.cityStarId = (PC.db.cityStarId or 0) + 1
    local star = { id = PC.db.cityStarId, x = x, y = y, side = level, t = now, links = {} }
    -- joined to the star you put down just before (same map and level, not long ago, not far off)
    local last = self.lastStar
    if last and last.map == map and last.side == level and now - last.t <= self.STAR_JOIN_SECS then
        for _, o in ipairs(list) do
            if o.id == last.id then
                local yd = T and T:Yards(me, { map = map, x = o.x, y = o.y })
                if yd and yd <= self.STAR_JOIN then
                    o.links = o.links or {}
                    o.links[#o.links + 1] = star.id
                    star.links[1] = o.id
                end
            end
        end
    end
    list[#list + 1] = star
    self.lastStar = { map = map, side = level, id = star.id, t = now }
    self.starRev = (self.starRev or 0) + 1
    if PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.MAP_PING) or 3175) end
    PC.Print(("Star added (%d on this map)."):format(#list))
    self:DrawStars()
end

-- the next star to head for on the way to t (a spot on this map), or nil = straight at t
-- How far it really is to walk somewhere inside a city, along the stars you've put down. The rises
-- of Thunder Bluff and the levels of Undercity are joined by stairs and bridges, so a shop a short
-- way across the map can be a long walk round - and straight at it is often no way at all.
-- The whole mesh is worked out once per refresh; after that each place costs a handful of sums.
function Places:StarMesh(map)
    local memo = PC.Memo and PC:Memo()
    if memo and memo.starMeshMap == map then return memo.starMesh or nil end
    local mesh
    local pts = self:StarPoints(map)
    local T = PC.Travel
    local hereMap, hx, hy = self:Here()
    if pts and T and hereMap == map and hx then
        local level = StarLevel(map)
        local me = { map = map, x = hx, y = hy }
        local byId, start, ds = {}, nil, nil
        for _, s in ipairs(pts) do
            if s.side == level then
                byId[s.id] = s
                local a = T:Yards(me, s)
                if a and (not ds or a < ds) then start, ds = s, a end
            end
        end
        if start then
            local dist, done = { [start.id] = ds }, {}
            while true do
                local u, best
                for id, d in pairs(dist) do if not done[id] and (not best or d < best) then u, best = id, d end end
                if not u then break end
                done[u] = true
                for _, vid in ipairs(byId[u].links or {}) do
                    if byId[vid] then
                        local w = T:Yards(byId[u], byId[vid]) or 1e6
                        if not dist[vid] or best + w < dist[vid] then dist[vid] = best + w end
                    end
                end
            end
            mesh = { byId = byId, dist = dist, me = me }
        end
    end
    if memo then memo.starMeshMap, memo.starMesh = map, mesh or false end
    return mesh
end

-- map units (the same scale as the plain straight-line measure), or nil
function Places:StarDist(map, p)
    local mesh = self:StarMesh(map)
    local T = PC.Travel
    if not mesh or not T or not p or p.map ~= map then return nil end
    local direct = T:Yards(mesh.me, p)
    if not direct then return nil end
    if direct <= 30 then return direct / 10 end -- right here: no need to go round by the stars
    local best
    for id, s in pairs(mesh.byId) do
        local d, b = mesh.dist[id], T:Yards(s, p)
        if d and b then
            local tot = d + b
            if not best or tot < best then best = tot end
        end
    end
    return (best or direct) / 10 -- yards -> map units
end

function Places:NextStar(t, map, x, y)
    local pts = self:StarPoints(map)
    if not pts then return nil end
    local nowT = GetTime and GetTime() or 0
    local key = ("%s:%.4f:%.4f"):format(tostring(map), t.x or 0, t.y or 0)
    if self.starKey == key and nowT - (self.starAt or -10) < 0.4 then return self.starNext or nil end
    self.starKey, self.starAt, self.starNext = key, nowT, nil
    local T = PC.Travel
    if not T then return nil end
    local level = StarLevel(map)
    local me = { map = map, x = x, y = y }
    local dMe = T:Yards(me, t)
    if not dMe or dMe < 25 then return nil end -- nearly there: straight at it
    local start, goal, ds, dg
    local byId = {}
    for _, s in ipairs(pts) do
        if s.side == level then
            byId[s.id] = s
            local a, b = T:Yards(me, s), T:Yards(s, t)
            if a and (not ds or a < ds) then start, ds = s, a end
            if b and (not dg or b < dg) then goal, dg = s, b end
        end
    end
    -- the stars only help when the last of them is nearer the stop than you are
    if not start or not goal or dg >= dMe then return nil end
    -- the way from the star nearest you to the star nearest the stop, along the joins
    local dist, prev, done = { [start.id] = 0 }, {}, {}
    while true do
        local u, best
        for id, d in pairs(dist) do if not done[id] and (not best or d < best) then u, best = id, d end end
        if not u or u == goal.id then break end
        done[u] = true
        for _, vid in ipairs(byId[u].links) do
            local v = byId[vid]
            if v and not done[vid] then
                local w = T:Yards(byId[u], v) or 1e6
                if not dist[vid] or best + w < dist[vid] then dist[vid], prev[vid] = best + w, u end
            end
        end
    end
    local pick
    if dist[goal.id] then
        local path, id = {}, goal.id
        while id do table.insert(path, 1, byId[id]); id = prev[id] end
        local i = 1
        while path[i] do
            local a = T:Yards(me, path[i])
            local nxt = path[i + 1]
            if a and a <= self.STAR_NEAR then i = i + 1
            elseif nxt and (T:Yards(me, nxt) or 1e9) < (T:Yards(path[i], nxt) or 0) then i = i + 1 -- already past it
            else break end
        end
        pick = path[i]
    else
        -- not joined up: the nearest star that gets you closer to the stop
        local bestD
        for _, s in pairs(byId) do
            local a, b = T:Yards(me, s), T:Yards(s, t)
            if a and b and b < dMe - 5 and a > self.STAR_NEAR and (not bestD or a < bestD) then pick, bestD = s, a end
        end
    end
    self.starNext = pick
    return pick
end

-- the stars on the minimap (this map, this level, in range); the one the arrows point at is bigger
function Places:DrawStars()
    if not Minimap then return end
    self.starPins = self.starPins or {}
    local pins = self.starPins
    local used = 0
    local map, x, y = self:Here()
    local pts = map and x and not PC.inCombat and self:StarPoints(map)
    if pts then
        local radius = (C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius())
            or (Minimap.GetViewRadius and Minimap:GetViewRadius())
        if not radius or radius <= 0 then
            local inside = IsIndoors and IsIndoors()
            local size = inside and { 300, 240, 180, 120, 80, 50 } or { 466.67, 400, 333.33, 266.67, 200, 133.33 }
            radius = (size[(Minimap.GetZoom and Minimap:GetZoom() or 0) + 1] or size[1]) / 2
        end
        local half = (Minimap:GetWidth() or 140) / 2
        local rotate = GetCVar and GetCVar("rotateMinimap") == "1"
        local facing = rotate and PC.Num(GetPlayerFacing and GetPlayerFacing()) or nil
        local level = StarLevel(map)
        for _, s in ipairs(pts) do
            if s.side == level then
                local yd, ex, sy = self:Offset(s, map, x, y)
                if yd and yd <= radius * 0.92 then
                    local px, py = ex / radius * half, -sy / radius * half
                    if facing then
                        local c, sn = math.cos(facing), math.sin(facing)
                        px, py = px * c + py * sn, -px * sn + py * c
                    end
                    used = used + 1
                    local pin = pins[used]
                    if not pin then
                        pin = CreateFrame("Frame", nil, Minimap)
                        pin:SetFrameStrata("MEDIUM")
                        pin:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 5)
                        pin.tex = pin:CreateTexture(nil, "OVERLAY")
                        pin.tex:SetAllPoints()
                        pin.tex:SetTexture(self.STAR_ART)
                        pins[used] = pin
                    end
                    local nextOne = self.starNext and self.starNext.id == s.id
                    local sz = nextOne and 18 or 12
                    pin:SetSize(sz, sz)
                    pin:ClearAllPoints()
                    pin:SetPoint("CENTER", Minimap, "CENTER", px, py)
                    pin:Show()
                end
            end
        end
    end
    for i = used + 1, #pins do pins[i]:Hide() end
end

-- twice a second, whether or not there's a route (so a star shows the moment you put it down)
do
    local fr = CreateFrame("Frame")
    local left = 0
    fr:SetScript("OnUpdate", function(_, dt)
        left = left - (dt or 0)
        if left > 0 then return end
        left = 0.5
        if PC.db and PC.db.cityStars and next(PC.db.cityStars) then PC:Safe("stars", Places.DrawStars, Places) end
    end)
end
