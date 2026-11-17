-- MostlyNotBroken shared data (MNB)
-- One copy of this file ships inside every MostlyNotBroken addon (ProfitCrafter Forever, SnuggleUp Forever, ...).
-- The newest copy loaded takes over; older copies step aside. While the game runs, every family addon
-- shares one pool of learned data, and each one saves that same pool in its own saved variables.
--
-- What it learns as you play (places: when an addon turns gathering on):
--   vendor   - vendors, with the items they sell          ah     - auctioneers
--   bank     - bankers                                     mail   - mailboxes
--   flight   - flight masters                              fnode  - every flight path on the flight map
--   trainer  - trainers                                    inn    - innkeepers
--   npc      - anyone else you talk to                     cross  - where you crossed from one zone to another
--   lift     - elevators (Undercity, Thunder Bluff), found by riding them
--   grave    - graveyards: where your ghost appears when you release your spirit
-- And always, whenever any family addon is loaded: the walked ground (see "Walked ground" below):
-- which 25-yard squares of the world people walk through, how they move between them, and where
-- fights start. It's what the arrows use to follow roads and keep out of trouble.
-- Everything is shared over the hidden MostlyNotBrokenAddons channel only (never guild, party or
-- raid) under the "MNB1" prefix. Walked ground goes out in batches, minutes later, and never the
-- squares around where you are when it's sent.
--
-- For addons:
--   MNB:Attach(savedTable)          keep the pool in this addon's saved variables (call at ADDON_LOADED or later)
--   MNB:Gather(true)                learn places as you play
--   MNB:Listen(name, fn)            fn(key, place, mine) for every place learned or heard
--   MNB:Each(kind, fn)              fn(key, place) for every saved place of a kind
--   MNB:Lifts(map)                  elevators on a map
--   MNB:GroundAim(c, wx, wy, tx, ty) the next spot (world x, y) to head for on the way from (wx, wy) to
--                                   (tx, ty) on continent c, following walked ground; nil = go straight
--   MNB:GroundWay(c, wx, wy, tx, ty) the whole way, as a list of { x, y } world spots (or nil)
--   MNB:GroundCount()               how many squares are known
--   MNB:Present(name)               this add-on is installed (its users are counted online, by name)
--   MNB:OnlineCount(name)           how many players are online with that add-on (you included), and
--                                   true while still counting (the first few minutes after you log in)
--   MNB:OnlineNames(name)           their names (you included), sorted; full names (first and last on WoW Forever)
--   MNB:MyName()                    your own full name, as other players see it (first and last on WoW Forever)
--   MNB:Who(name, print)            prints who's online with that add-on (each add-on's "/xx who")
--   MNB:Setting(key)                a setting every family add-on shares (nil = never set)
--   MNB:SetSetting(key, value)      change it: every add-on that asked with OnSetting is told
--   MNB:OnSetting(name, fn)         fn(key, value) whenever a shared setting changes
--   /rl                             reloads the interface (every add-on that ships this file has it)
--   /mnb users                      a private marker (only on your own screen, off until you turn it on):
--                                   players who use a MostlyNotBroken add-on get a badge over their head and a
--                                   line in their tooltip saying which add-ons
--   Shared settings so far: dropDown (true = the task list hangs under the Task Button)
-- Place fields: k kind, f faction (A, H or N), id NPC/node id, n name, m map, x, y (0-1), s seen time,
--   mine (you saw it), from (who told you), c reports, st { [itemID] = true }, to (map it leads to),
--   x2/y2 (where you come out, for cross), t title or profession, rep (repairs), sz subzone (innkeepers:
--   the name your hearthstone's home goes by)

local MINOR = 17

-- /rl reloads the interface in every MostlyNotBroken add-on (set before the version check, so any copy does it)
if SlashCmdList and not SlashCmdList.MNBRELOAD then
    SLASH_MNBRELOAD1 = "/rl"
    SlashCmdList.MNBRELOAD = function() if ReloadUI then ReloadUI() end end
end

local MNB = _G.MostlyNotBroken
if MNB and (MNB.MINOR or 0) >= MINOR then return end -- the same or a newer copy is already running
MNB = MNB or {}
_G.MostlyNotBroken = MNB
MNB.MINOR = MINOR

local PREFIX = "MNB1"
local CHANNEL_NAME = "MostlyNotBrokenAddons"
local MAX_LEN = 240
local SEND_GAP = 1.1
local RESHARE = 3600            -- your own sighting of a place goes out again at most once an hour
local MAX_PLACES = 8000         -- oldest heard places go first past this
local MAX_STOCK = 80
local ZONE_ASK_DELAY = 10       -- seconds in a zone before asking others what they know about it
local ZONE_REPLY_COOLDOWN = 600
local ZONE_REPLY_MAX = 25

MNB.KINDS = { vendor = "Vendor", ah = "Auctioneer", bank = "Banker", mail = "Mailbox", flight = "Flight master",
    fnode = "Flight path", trainer = "Trainer", inn = "Innkeeper", npc = "NPC", cross = "Zone crossing", lift = "Elevator",
    grave = "Graveyard", dungeon = "Dungeon entrance" }
-- elevator cities: riding between these maps is an elevator, not a zone border
MNB.LIFT_PAIRS = { [1458] = 1420, [1420] = 1458, [1456] = 1412, [1412] = 1456 } -- Undercity/Tirisfal, Thunder Bluff/Mulgore

MNB.listeners = MNB.listeners or {}
MNB.sentAt = MNB.sentAt or {}
MNB.queue = MNB.queue or {}
MNB.asked = MNB.asked or {}
MNB.replied = MNB.replied or {}
MNB.gathering = MNB.gathering or 0
MNB.settingFns = MNB.settingFns or {}

---------------------------------------------------------------------------
-- The pool
---------------------------------------------------------------------------
local function NewPool() return { v = 1, places = {}, ground = {}, settings = { share = true } } end
MNB.pool = MNB.pool or NewPool()

local function Merge(into, p)
    if not p.mine and into.mine then
        into.c = (into.c or 1) + 1
    elseif p.mine and not into.mine then
        into.n, into.m, into.x, into.y, into.mine, into.from = p.n, p.m, p.x, p.y, true, nil
    elseif (p.s or 0) > (into.s or 0) and not into.mine then
        into.n, into.m, into.x, into.y = p.n, p.m, p.x, p.y
    end
    into.s = math.max(into.s or 0, p.s or 0)
    for _, f in ipairs({ "id", "f", "to", "x2", "y2", "t", "rep", "sz" }) do
        if into[f] == nil and p[f] ~= nil then into[f] = p[f] end
    end
    if p.st then
        into.st = into.st or {}
        local n = 0
        for _ in pairs(into.st) do n = n + 1 end
        for id in pairs(p.st) do
            if not into.st[id] and n < MAX_STOCK then into.st[id] = true; n = n + 1 end
        end
    end
end

-- Keep the pool in an addon's saved variables: what it saved before joins the pool, and from now on
-- the addon saves the whole pool (every family addon saves the same table)
function MNB:Attach(saved, field)
    if type(saved) ~= "table" then return end
    field = field or "mnb"
    local old = saved[field]
    if old == self.pool then return end
    if type(old) == "table" and type(old.places) == "table" then
        for key, p in pairs(old.places) do
            if type(p) == "table" and self.KINDS[p.k] then
                local have = self.pool.places[key]
                if have then Merge(have, p) else self.pool.places[key] = p end
            end
        end
        if type(old.ground) == "table" and self.MergeGround then self:MergeGround(old.ground) end
    end
    self.pool.settings = self.pool.settings or {}
    -- shared settings this add-on saved before: kept where the pool doesn't have them yet
    if type(old) == "table" and type(old.settings) == "table" then
        for k, v in pairs(old.settings) do
            if k ~= "share" and self.pool.settings[k] == nil then self.pool.settings[k] = v end
        end
    end
    self.pool.settings.share = true
    saved[field] = self.pool
end

-- settings every family add-on shares (one switch, the same in each add-on's settings)
function MNB:Setting(key)
    local s = self.pool and self.pool.settings
    if s then return s[key] end
end

function MNB:SetSetting(key, value)
    self.pool.settings = self.pool.settings or {}
    self.pool.settings[key] = value
    for name, fn in pairs(self.settingFns) do
        local ok, err = pcall(fn, key, value)
        if not ok and not self.settingErr then
            self.settingErr = true
            print("|cffff5555MostlyNotBroken setting (" .. tostring(name) .. "):|r " .. tostring(err))
        end
    end
end

function MNB:OnSetting(name, fn) self.settingFns[name] = fn end

-- sharing is always on (kept as calls so older family addons asking about it still work)
function MNB:Sharing() return true end
function MNB:SetSharing() self:JoinChannel() end

function MNB:Listen(name, fn) self.listeners[name] = fn end

local function Tell(key, p, mine)
    for name, fn in pairs(MNB.listeners) do
        local ok, err = pcall(fn, key, p, mine)
        if not ok and not MNB.listenErr then
            MNB.listenErr = true
            print("|cffff5555MostlyNotBroken data (" .. tostring(name) .. "):|r " .. tostring(err))
        end
    end
end

function MNB:Each(kind, fn)
    for key, p in pairs(self.pool.places) do
        if not kind or p.k == kind then fn(key, p) end
    end
end

function MNB:Lifts(map)
    local out = {}
    for _, p in pairs(self.pool.places) do
        if p.k == "lift" and p.m == map then out[#out + 1] = p end
    end
    return out
end

function MNB:Count()
    local n = 0
    for _ in pairs(self.pool.places) do n = n + 1 end
    return n
end

---------------------------------------------------------------------------
-- Keys and checks
---------------------------------------------------------------------------
local function Grid(v, n) return math.floor((v or 0) * n) end

function MNB:Key(p)
    local k = p.k
    if k == "mail" then return ("mail:%d:%d:%d"):format(p.m, Grid(p.x, 50), Grid(p.y, 50)) end
    if k == "lift" then return ("lift:%d:%d:%d"):format(p.m, Grid(p.x, 100), Grid(p.y, 100)) end
    if k == "grave" then return ("grave:%d:%d:%d"):format(p.m, Grid(p.x, 40), Grid(p.y, 40)) end
    if k == "cross" then return ("cross:%d:%d:%d:%d"):format(p.m, p.to or 0, Grid(p.x, 40), Grid(p.y, 40)) end
    if k == "fnode" then return p.id and ("fnode:" .. p.id) or ("fnode:%s:%s:%d"):format(p.f or "N", p.n or "?", p.m) end
    if p.id then return k .. ":" .. p.id end
    return ("%s:%s:%s:%d"):format(k, p.f or "N", p.n or "?", p.m)
end

local function Clean(s)
    s = tostring(s or ""):gsub("[|;=\n\r]", ""):sub(1, 60)
    return s
end

local function Valid(p)
    if type(p) ~= "table" or not MNB.KINDS[p.k] then return false end
    if type(p.m) ~= "number" or p.m <= 0 or p.m > 100000 then return false end
    if type(p.x) ~= "number" or type(p.y) ~= "number" then return false end
    if p.x <= 0 or p.x >= 1 or p.y <= 0 or p.y >= 1 then return false end
    if p.f ~= "A" and p.f ~= "H" and p.f ~= "N" then p.f = "N" end
    return true
end

-- Too many places: the oldest ones only heard about (never seen yourself) go first
local function Trim()
    local places = MNB.pool.places
    local n = 0
    for _ in pairs(places) do n = n + 1 end
    if n <= MAX_PLACES then return end
    local list = {}
    for key, p in pairs(places) do if not p.mine then list[#list + 1] = { key, p.s or 0 } end end
    table.sort(list, function(a, b) return a[2] < b[2] end)
    for i = 1, math.min(n - MAX_PLACES + 200, #list) do places[list[i][1]] = nil end
end

-- Save a place. mine = you saw it yourself (then it's shared). Returns the key, or nil if it was no good.
function MNB:Record(p, mine)
    if not Valid(p) then return nil end
    p.n = Clean(p.n ~= "" and p.n or self.KINDS[p.k])
    p.s = p.s or time()
    p.mine = mine and true or nil
    local key = self:Key(p)
    local have = self.pool.places[key]
    local stockBefore = 0
    if have then
        if have.st then for _ in pairs(have.st) do stockBefore = stockBefore + 1 end end
        Merge(have, p)
    else
        if p.st then
            local st, n = {}, 0
            for id in pairs(p.st) do if n < MAX_STOCK then st[id] = true; n = n + 1 end end
            p.st = st
        end
        self.pool.places[key] = p
        have = p
        Trim()
    end
    Tell(key, have, mine)
    if mine then
        local stockNow = 0
        if have.st then for _ in pairs(have.st) do stockNow = stockNow + 1 end end
        self:SharePlace(key, have, stockNow ~= stockBefore)
    end
    return key
end

---------------------------------------------------------------------------
-- The shared channel (joined quietly, hidden from your chat windows)
---------------------------------------------------------------------------
local function HideChannel()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local frame = _G["ChatFrame" .. i]
        if frame then
            if ChatFrame_RemoveChannel then pcall(ChatFrame_RemoveChannel, frame, CHANNEL_NAME)
            elseif ChatFrameUtil and ChatFrameUtil.RemoveChannel then pcall(ChatFrameUtil.RemoveChannel, frame, CHANNEL_NAME) end
        end
    end
end

function MNB:ChannelID()
    if not GetChannelName then return nil end
    local id = GetChannelName(CHANNEL_NAME)
    if id and id > 0 then return id end
    return nil
end

function MNB:JoinChannel()
    if not self:Sharing() or not JoinTemporaryChannel then return end
    if not self:ChannelID() then pcall(JoinTemporaryChannel, CHANNEL_NAME) end
    C_Timer.After(1, HideChannel)
end

-- Everything goes to the hidden channel only: never guild, party or raid
local function Targets()
    local chan = MNB:ChannelID()
    if chan then return { { "CHANNEL", chan } } end
    return {}
end

function MNB:Pump()
    local q = self.queue
    if #q == 0 then self.pumping = false return end
    if InCombatLockdown and InCombatLockdown() then C_Timer.After(3, function() MNB:Pump() end) return end
    local m = table.remove(q, 1)
    pcall(C_ChatInfo.SendAddonMessage, PREFIX, m.text, m.ch[1], m.ch[2])
    C_Timer.After(SEND_GAP, function() MNB:Pump() end)
end

-- false when it couldn't go (not on the channel yet)
function MNB:Send(text)
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return false end
    local targets = Targets()
    if #targets == 0 then return false end
    for _, ch in ipairs(targets) do self.queue[#self.queue + 1] = { text = text, ch = ch } end
    if #self.queue > 400 then while #self.queue > 400 do table.remove(self.queue, 1) end end
    if not self.pumping and #self.queue > 0 then self.pumping = true; self:Pump() end
    return true
end

---------------------------------------------------------------------------
-- Messages
--   P|kind|fac|id|map|x|y|name|k=v;k=v       a place
--   S|key|itemID,itemID,...                  what a vendor sells (in pieces)
--   Z|map|count                              "what do you know about this zone?"
--   G|cont|cx,cy,walks,trouble,links;...     walked ground (see "Walked ground")
--   I|name,name,...                          "I'm here, with these add-ons" (on joining, then every 5 minutes)
---------------------------------------------------------------------------
local function PlaceText(p)
    local extra = {}
    for _, f in ipairs({ "to", "x2", "y2", "t", "rep", "sz" }) do
        local v = p[f]
        if v ~= nil then
            if type(v) == "number" and v % 1 ~= 0 then v = ("%.4f"):format(v) end
            extra[#extra + 1] = f .. "=" .. Clean(v)
        end
    end
    return ("P|%s|%s|%d|%d|%.4f|%.4f|%s|%s"):format(p.k, p.f or "N", p.id or 0, p.m, p.x, p.y, Clean(p.n), table.concat(extra, ";"))
end

local function SendStock(key, p)
    if not p.st then return end
    local head = "S|" .. key .. "|"
    local parts, len = {}, #head
    for id in pairs(p.st) do
        local s = tostring(id)
        if len + #s + 1 > MAX_LEN then
            MNB:Send(head .. table.concat(parts, ","))
            parts, len = {}, #head
        end
        parts[#parts + 1] = s
        len = len + #s + 1
    end
    if #parts > 0 then MNB:Send(head .. table.concat(parts, ",")) end
end

function MNB:SharePlace(key, p, stockChanged)
    if not self:Sharing() then return end
    local last = self.sentAt[key]
    if last and GetTime() - last < RESHARE and not stockChanged then return end
    self.sentAt[key] = GetTime()
    self:Send(PlaceText(p))
    if p.st and (stockChanged or not last) then SendStock(key, p) end
end

-- a name to compare by: no realm, no spaces (WoW Forever's two-part names), any capitals
local function Norm(name)
    if type(name) ~= "string" or (issecretvalue and issecretvalue(name)) then return nil end
    return (name:gsub("%-.*$", ""):gsub("[%s\194\160]", ""):lower())
end
MNB.Norm = Norm

-- this copy's own mark (made fresh each login): a message carrying it is our own, whatever the name says
MNB.token = MNB.token or ("%06x"):format(math.random(0, 0xFFFFFF))

-- is this message from you? (by name, or by the name your own "I" messages came back under)
function MNB:IsMe(sender)
    local n = Norm(sender)
    if not n then return false end
    if n == Norm(UnitName and UnitName("player")) then return true end
    return self.selfSender ~= nil and n == self.selfSender
end

local function ShortName(name)
    if Ambiguate then return Ambiguate(name, "short") end
    return (name:gsub("%-.*", ""))
end

function MNB:OnMessage(text, sender)
    if not self:Sharing() then return end
    -- (Retail hides some chat from add-ons in instances: skip anything it won't let us read)
    if issecretvalue and (issecretvalue(text) or issecretvalue(sender)) then return end
    if type(text) ~= "string" then return end
    local who = ShortName(sender or "?")
    if self:IsMe(sender) then return end
    local kind, rest = text:match("^(%a)|(.*)$")
    if kind == "P" then
        local k, f, id, m, x, y, n, extra = rest:match("^(%a+)|(%a)|(%d+)|(%d+)|([%d%.]+)|([%d%.]+)|([^|]*)|?(.*)$")
        if not k then return end
        local p = { k = k, f = f, id = tonumber(id), m = tonumber(m), x = tonumber(x), y = tonumber(y), n = n,
            from = who, s = time() }
        if p.id == 0 then p.id = nil end
        for ek, ev in (extra or ""):gmatch("(%a+%d?)=([^;]*)") do
            if ek == "to" or ek == "x2" or ek == "y2" then p[ek] = tonumber(ev)
            elseif ek == "rep" then p.rep = ev == "true"
            elseif ek == "t" then p.t = ev
            elseif ek == "sz" then p.sz = ev end
        end
        if p.x2 and (p.x2 <= 0 or p.x2 >= 1) then p.x2 = nil end
        if p.y2 and (p.y2 <= 0 or p.y2 >= 1) then p.y2 = nil end
        if self:Record(p, false) and self.replyFor and self.replyFor[p.m] then
            self.replyFor[p.m] = nil -- someone else is already answering for this zone
        end
    elseif kind == "S" then
        local key, ids = rest:match("^([^|]+)|([%d,]+)$")
        local p = key and self.pool.places[key]
        if not p or p.k ~= "vendor" then return end
        p.st = p.st or {}
        local n = 0
        for _ in pairs(p.st) do n = n + 1 end
        for id in ids:gmatch("%d+") do
            id = tonumber(id)
            if id and id > 0 and not p.st[id] and n < MAX_STOCK then p.st[id] = true; n = n + 1 end
        end
        Tell(key, p, false)
    elseif kind == "G" then
        self:HearGround(rest)
    elseif kind == "I" then
        local set, mine = {}, false
        for n in rest:gmatch("[^,]+") do
            if n:sub(1, 1) == "#" then
                -- a copy's own mark ("#" + token): our own mark means this came back from us
                if n == "#" .. self.token then mine = true end
            else
                set[n] = true
            end
        end
        if mine then
            self.selfSender = Norm(sender)
            -- the name the channel gives us: on WoW Forever it has your last name too ("Sheep Thrillz")
            self.selfName = who
            self.online[who] = nil
            return
        end
        self.online[who] = { t = GetTime(), addons = set }
    elseif kind == "Z" then
        local m, count = rest:match("^(%d+)|(%d+)$")
        m, count = tonumber(m), tonumber(count) or 0
        if not m then return end
        if self.replied[m] and GetTime() - self.replied[m] < ZONE_REPLY_COOLDOWN then return end
        local list = {}
        for key, p in pairs(self.pool.places) do
            if p.m == m or (p.k == "cross" and p.to == m) then list[#list + 1] = { key = key, p = p } end
        end
        if #list <= count + 5 then return end -- they already know about as much as we do
        table.sort(list, function(a, b) return (a.p.mine and 1 or 0) > (b.p.mine and 1 or 0) end)
        local token = {}
        self.replyFor = self.replyFor or {}
        self.replyFor[m] = token
        C_Timer.After(2 + math.random() * 5, function()
            if self.replyFor[m] ~= token then return end -- someone else answered first
            self.replyFor[m] = nil
            self.replied[m] = GetTime()
            local vendors = 0
            for i = 1, math.min(#list, ZONE_REPLY_MAX) do
                local e = list[i]
                self:Send(PlaceText(e.p))
                if e.p.st and vendors < 6 then vendors = vendors + 1; SendStock(e.key, e.p) end
            end
        end)
    end
end

-- Ask once per zone per session, after you've been there a little while
function MNB:AskZone(map)
    if not map or self.asked[map] or not self:Sharing() then return end
    self.asked[map] = true
    local count = 0
    for _, p in pairs(self.pool.places) do if p.m == map then count = count + 1 end end
    self:Send(("Z|%d|%d"):format(map, count))
end

---------------------------------------------------------------------------
-- Learning as you play
---------------------------------------------------------------------------
function MNB:Gather(on)
    self.gathering = (self.gathering or 0) + (on and 1 or -1)
end
local function Gathering() return (MNB.gathering or 0) > 0 end

local function Num(v)
    if v == nil or type(v) ~= "number" then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

-- Elevator cities: the game can go on calling the ground around a city by the city's map after you've
-- ridden out (the bottom of Thunder Bluff's elevators, the courtyard above Undercity). The zone name
-- says where you really are: not the city's name = you're out, on the zone around it.
MNB.CITY_OUTER = { [1458] = 1420, [1456] = 1412 } -- Undercity -> Tirisfal Glades, Thunder Bluff -> Mulgore
-- the top of Undercity's elevators is still "Undercity" (zone and map), but its subzone is the Ruins of
-- Lordaeron: up there you're out of the city
-- (the Ruins' name in each language of the game)
MNB.CITY_TOP = { [1458] = { ["Ruins of Lordaeron"] = true, ["Ruinen von Lordaeron"] = true, ["Ruines de Lordaeron"] = true,
    ["Ruinas de Lordaeron"] = true, ["Ruínas de Lordaeron"] = true, ["Rovine di Lordaeron"] = true,
    ["Руины Лордерона"] = true, ["로데론의 폐허"] = true, ["洛丹伦废墟"] = true, ["羅德隆廢墟"] = true } }
function MNB:OuterIfLeft(map)
    local outer = map and self.CITY_OUTER[map]
    if not outer then return map end
    local sub = GetSubZoneText and GetSubZoneText()
    local mini = GetMinimapZoneText and GetMinimapZoneText() -- the name over the minimap
    local top = self.CITY_TOP[map]
    if top and ((sub and top[sub]) or (mini and top[mini])) then return outer end
    -- the name over the minimap is the zone around the city (Tirisfal Glades, in any language): out
    local oi = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(outer)
    if oi and oi.name and mini == oi.name then return outer end
    local zt = GetRealZoneText and GetRealZoneText()
    if not zt or zt == "" then return map end
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(map)
    if info and info.name and zt ~= info.name then return outer end
    return map
end

-- Where you are: map, x, y (nil inside dungeons, or when the game won't say)
function MNB:Here()
    if IsInInstance then
        local inside = IsInInstance()
        if inside then return nil end
    end
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if not map then return nil end
    map = self:OuterIfLeft(map)
    local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return nil end
    local x, y = pos.x, pos.y
    if (x == nil or y == nil) and pos.GetXY then x, y = pos:GetXY() end
    x, y = Num(x), Num(y)
    if not x or not y or x <= 0 or y <= 0 then return nil end
    return map, x, y
end

local function FactionLetter(f)
    if f == "Alliance" then return "A" elseif f == "Horde" then return "H" end
    return "N"
end

-- The NPC (or object) you're talking to
local function Npc()
    local guid = UnitGUID and UnitGUID("npc")
    local id
    if guid then
        local kind, _, _, _, _, nid = strsplit("-", guid)
        if kind == "Creature" or kind == "Vehicle" or kind == "GameObject" then id = tonumber(nid) end
    end
    local name = UnitName and UnitName("npc")
    local fac = UnitFactionGroup and UnitFactionGroup("npc")
    return id, name, FactionLetter(fac)
end

local function Stock()
    local st = {}
    if not GetMerchantNumItems then return st end
    for i = 1, GetMerchantNumItems() or 0 do
        local id
        if GetMerchantItemID then local ok, v = pcall(GetMerchantItemID, i); if ok then id = v end end
        if not id and GetMerchantItemLink then
            local link = GetMerchantItemLink(i)
            id = link and tonumber(link:match("item:(%d+)"))
        end
        if id then st[id] = true end
    end
    return st
end

function MNB:LearnHere(kind, extra)
    local map, x, y = self:Here()
    if not map then return end
    local id, name, fac = Npc()
    local p = { k = kind, id = id, n = name, f = fac, m = map, x = x, y = y }
    for k, v in pairs(extra or {}) do p[k] = v end
    return self:Record(p, true)
end

-- Every flight path on the flight map
function MNB:LearnNodes()
    local tmap = GetTaxiMapID and GetTaxiMapID()
    if not tmap then return end
    local fac = FactionLetter(UnitFactionGroup and UnitFactionGroup("player"))
    local nodes = C_TaxiMap and C_TaxiMap.GetAllTaxiNodes and C_TaxiMap.GetAllTaxiNodes(tmap)
    if type(nodes) == "table" then
        for _, nd in ipairs(nodes) do
            local pos = nd.position
            local x, y = pos and (pos.x or (pos.GetXY and select(1, pos:GetXY()))), pos and (pos.y or (pos.GetXY and select(2, pos:GetXY())))
            if nd.name and x and y then
                self:Record({ k = "fnode", id = nd.nodeID, n = nd.name, f = fac, m = tmap, x = x, y = y }, true)
            end
        end
    elseif NumTaxiNodes and TaxiNodeName and TaxiNodePosition then
        for i = 1, NumTaxiNodes() or 0 do
            local name = TaxiNodeName(i)
            local x, y = TaxiNodePosition(i)
            if name and x and y then
                self:Record({ k = "fnode", n = name, f = fac, m = tmap, x = x, y = y }, true)
            end
        end
    end
end

-- Talking to someone: an innkeeper (they offer to set your home), or just an NPC
function MNB:LearnTalk()
    local id, name = Npc()
    if not name or (UnitIsPlayer and UnitIsPlayer("npc")) then return end
    local inn = false
    if C_GossipInfo and C_GossipInfo.GetOptions then
        local ok, opts = pcall(C_GossipInfo.GetOptions)
        if ok and type(opts) == "table" then
            for _, o in ipairs(opts) do if o.type == "binder" or o.icon == 132052 then inn = true end end
        end
    elseif GetGossipOptions then
        local list = { pcall(GetGossipOptions) }
        for i = 3, #list, 2 do if list[i] == "binder" then inn = true end end
    end
    if inn then return self:LearnHere("inn", { sz = GetSubZoneText and GetSubZoneText() or nil }) end
    -- already known as something more specific: nothing new to say
    if id then
        for _, k in ipairs({ "vendor", "ah", "bank", "flight", "trainer", "inn" }) do
            if self.pool.places[k .. ":" .. id] then return end
        end
    end
    return self:LearnHere("npc")
end

-- A dungeon or raid you just went into: its entrance is where you last stood outside
function MNB:NoteDungeon()
    local out = self.lastOut
    if not out or GetTime() - out.t > 30 or not GetInstanceInfo then return end
    local name, kind, _, _, _, _, _, id = GetInstanceInfo()
    if (kind ~= "party" and kind ~= "raid") or not name or name == "" then return end
    if issecretvalue and (issecretvalue(name) or issecretvalue(id)) then return end
    self:Record({ k = "dungeon", f = "N", id = id and tostring(id) or nil, m = out.m, x = out.x, y = out.y, n = name,
        t = kind == "raid" and "raid" or "dungeon" }, true)
end

-- Zone crossings and elevators: where you were just before the map changed under you
function MNB:Tick()
    pcall(self.HelloTick, self)
    local ok, err = pcall(self.GroundTick, self)
    if not ok and not self.groundErr then
        self.groundErr = true
        print("|cffff5555MostlyNotBroken data (ground):|r " .. tostring(err))
    end
    if not Gathering() then return end
    -- going into a dungeon or raid: the last spot outside is its entrance (learned and shared, so new
    -- dungeons are known as soon as somebody visits them)
    local inInst = IsInInstance and IsInInstance() and true or nil
    if inInst and not self.wasInInstance then pcall(self.NoteDungeon, self) end
    self.wasInInstance = inInst
    local map, x, y = self:Here()
    local now = GetTime()
    if map and not inInst then self.lastOut = { m = map, x = x, y = y, t = now } end
    -- (no crossings learned on a flight, as a ghost or swimming: a swim along the coast isn't a road)
    local away = (UnitOnTaxi and UnitOnTaxi("player")) or (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player"))
        or (IsSwimming and IsSwimming())
    if not map or away then self.last = nil return end
    local wy, wx = nil, nil
    if UnitPosition then wy, wx = UnitPosition("player") end
    local last = self.last
    if last and last.m ~= map and now - last.t <= 2.5 then
        -- a short hop (not a hearthstone or portal): you walked, rode or took the elevator across
        local near = true
        if wx and last.wx then
            local d = math.sqrt((wx - last.wx) ^ 2 + (wy - last.wy) ^ 2)
            near = d < 80
        end
        if near then
            if MNB.LIFT_PAIRS[last.m] == map then
                self:Record({ k = "lift", f = "N", m = last.m, x = last.x, y = last.y, to = map }, true)
                self:Record({ k = "lift", f = "N", m = map, x = x, y = y, to = last.m }, true)
            else
                local zone = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
                local a = C_Map.GetMapInfo and C_Map.GetMapInfo(last.m)
                local b = C_Map.GetMapInfo and C_Map.GetMapInfo(map)
                if a and b and a.mapType == zone and b.mapType == zone then
                    self:Record({ k = "cross", f = "N", m = last.m, x = last.x, y = last.y, to = map, x2 = x, y2 = y,
                        n = (a.name or "?") .. " to " .. (b.name or "?") }, true)
                end
            end
        end
    end
    if not last or last.m ~= map then
        local m = map
        C_Timer.After(ZONE_ASK_DELAY, function()
            local now2 = MNB:Here()
            if now2 == m then MNB:AskZone(m) end
        end)
    end
    self.last = { m = map, x = x, y = y, t = now, wx = wx, wy = wy }
end

---------------------------------------------------------------------------
-- Walked ground
--   The world is cut into 25-yard squares (on each continent, in world yards). Whenever any family
--   addon is loaded, every square you walk or ride into counts one more walk, and the way you went
--   from square to square is kept (one bit for each of the 8 neighbours). A fight starting counts
--   as trouble on that square (dying, double). Being carried (boats, zeppelins, elevators, flights,
--   a ghost) isn't walking and isn't counted.
--   Saved as one number per square: walks * 65536 + trouble * 256 + links
--     pool.ground[continent]["cx:cy"] = number
--   Shared in batches: squares walked at least BATCH_AGE seconds ago, never the ones near where you
--   are when the batch goes out.
---------------------------------------------------------------------------
local CELL = 25
local MAX_CELLS = 250000
local BATCH_AGE = 300         -- seconds before a walked square can be shared
local BATCH_CHECK = 60        -- how often to look for squares ready to share
local BATCH_HIDE = 300        -- yards: squares this close to you stay back until you've moved on
local BATCH_MIN = 8           -- squares in a batch (unless they've waited 15 minutes)
local BATCH_MAX_MSGS = 12     -- messages per batch
local HEARD_MAX_WALKS = 5     -- what one message can add to one square
local HEARD_MAX_TROUBLE = 3

-- the 8 neighbours, one bit each
local DIRS = { { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 } }
local DIR_BIT = {} -- by (dx + 1) * 3 + (dy + 1)
for i, d in ipairs(DIRS) do DIR_BIT[(d[1] + 1) * 3 + (d[2] + 1)] = 2 ^ (i - 1) end

local function HasBit(mask, b) return mask % (b + b) >= b end
local function OrBits(a, b)
    local out, bit = 0, 1
    for _ = 1, 8 do
        if HasBit(a, bit) or HasBit(b, bit) then out = out + bit end
        bit = bit + bit
    end
    return out
end
local function Unpack(v)
    v = v or 0
    local walks = math.floor(v / 65536)
    local rest = v - walks * 65536
    local trouble = math.floor(rest / 256)
    return walks, trouble, rest - trouble * 256
end
local function Pack(walks, trouble, links)
    return math.min(walks, 60000) * 65536 + math.min(trouble, 255) * 256 + links
end

function MNB:Ground(cont)
    self.pool.ground = self.pool.ground or {}
    if not cont then return self.pool.ground end
    local g = self.pool.ground[cont]
    if not g then g = {}; self.pool.ground[cont] = g end
    return g
end

function MNB:GroundCount()
    local n = 0
    for _, g in pairs(self:Ground()) do for _ in pairs(g) do n = n + 1 end end
    return n
end

-- too many squares: the least walked go
function MNB:TrimGround()
    local n = self:GroundCount()
    if n <= MAX_CELLS then return end
    for limit = 1, 60000 do
        for _, g in pairs(self:Ground()) do
            for key, v in pairs(g) do
                if Unpack(v) <= limit then g[key] = nil; n = n - 1 end
            end
        end
        if n <= MAX_CELLS * 0.9 then return end
    end
end

-- another saved copy of the ground (the same pool, saved by another family addon): the bigger counts
-- win, links join (never added up: it's the same walking saved twice)
function MNB:MergeGround(other)
    for cont, cells in pairs(other) do
        if type(cells) == "table" then
            local g = self:Ground(cont)
            for key, v in pairs(cells) do
                if type(v) == "number" then
                    local w1, t1, l1 = Unpack(g[key])
                    local w2, t2, l2 = Unpack(v)
                    g[key] = Pack(math.max(w1, w2), math.max(t1, t2), OrBits(l1, l2))
                end
            end
        end
    end
end

-- add to a square (and remember it for the next batch when it's yours)
function MNB:AddCell(cont, cx, cy, walks, trouble, links, mine)
    local g = self:Ground(cont)
    local key = cx .. ":" .. cy
    local w, t, l = Unpack(g[key])
    if not g[key] then self.newCells = (self.newCells or 0) + 1 end
    g[key] = Pack(w + walks, t + trouble, OrBits(l, links))
    if mine then
        self.outbox = self.outbox or {}
        local ob = self.outbox[cont]
        if not ob then ob = {}; self.outbox[cont] = ob end
        local e = ob[key]
        if not e then e = { cx = cx, cy = cy, w = 0, t = 0, l = 0, at = GetTime() }; ob[key] = e end
        e.w, e.t, e.l = e.w + walks, e.t + trouble, OrBits(e.l, links)
    end
    if (self.newCells or 0) > 2000 then self.newCells = 0; self:TrimGround() end
end

-- where you are, in world yards: continent, x, y
function MNB:WorldHere()
    local map, x, y = self:Here()
    if not map then return nil end
    if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
    if not ok or not cont or not pos then return nil end
    local wx, wy = pos.x, pos.y
    if (wx == nil or wy == nil) and pos.GetXY then wx, wy = pos:GetXY() end
    if not wx or not wy then return nil end
    return cont, wx, wy
end

local function CellOf(v) return math.floor(v / CELL) end

-- every half second, from the ticker
function MNB:GroundTick()
    local now = GetTime()
    local away = (UnitOnTaxi and UnitOnTaxi("player")) or (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player"))
    local cont, wx, wy
    if not away then cont, wx, wy = self:WorldHere() end
    if self.groundSentAt == nil then self.groundSentAt = now end
    if now - self.groundSentAt >= BATCH_CHECK then
        self.groundSentAt = now
        self:SendGround(cont, wx, wy)
    end
    if not cont then self.walk = nil return end
    local last = self.walk
    self.walk = { c = cont, x = wx, y = wy, t = now }
    if not last or last.c ~= cont then return end
    local dt = now - last.t
    if dt <= 0 then return end
    local moved = math.sqrt((wx - last.x) ^ 2 + (wy - last.y) ^ 2)
    -- faster than your own feet (or mount) can go: you're being carried (or you teleported)
    local speed = GetUnitSpeed and GetUnitSpeed("player") or 7
    if speed and issecretvalue and issecretvalue(speed) then speed = 7 end
    if moved > (speed or 7) * dt * 1.3 + 3 then return end
    if speed == 0 and moved > 1 then return end -- standing still on something moving
    local ax, ay, bx, by = CellOf(last.x), CellOf(last.y), CellOf(wx), CellOf(wy)
    if ax == bx and ay == by then return end
    -- one square at a time (a fast half second can cross two)
    local steps = math.max(math.abs(bx - ax), math.abs(by - ay))
    if steps > 4 then return end
    local px, py = ax, ay
    for i = 1, steps do
        local nx = ax + math.floor((bx - ax) * i / steps + 0.5)
        local ny = ay + math.floor((by - ay) * i / steps + 0.5)
        local dx, dy = nx - px, ny - py
        local fwd, back = DIR_BIT[(dx + 1) * 3 + (dy + 1)], DIR_BIT[(1 - dx) * 3 + (1 - dy)]
        if fwd then
            self:AddCell(cont, px, py, 0, 0, fwd, true)
            self:AddCell(cont, nx, ny, 1, 0, back, true)
        end
        px, py = nx, ny
    end
end

-- a fight started (n = 1) or you died (n = 2) where you stand
function MNB:GroundTrouble(n)
    local cont, wx, wy = self:WorldHere()
    if not cont then return end
    self:AddCell(cont, CellOf(wx), CellOf(wy), 0, n, 0, true)
end

-- the walked squares that are ready go out: G|cont|cx,cy,walks,trouble,links;...
function MNB:SendGround(cont, wx, wy)
    if not self.outbox then return end
    if InCombatLockdown and InCombatLockdown() then return end
    if not self:ChannelID() then return end
    local now = GetTime()
    local hx, hy = wx and CellOf(wx), wy and CellOf(wy)
    local hide = math.ceil(BATCH_HIDE / CELL)
    local msgs = 0
    for c, ob in pairs(self.outbox) do
        local ready, oldest = {}, now
        for key, e in pairs(ob) do
            local near = cont == c and hx and math.abs(e.cx - hx) <= hide and math.abs(e.cy - hy) <= hide
            if now - e.at >= BATCH_AGE and not near then
                ready[#ready + 1] = key
                if e.at < oldest then oldest = e.at end
            end
        end
        if #ready >= BATCH_MIN or (#ready > 0 and now - oldest >= 900) then
            local head = "G|" .. c .. "|"
            local parts, len = {}, #head
            local function flush()
                if #parts == 0 then return true end
                if not self:Send(head .. table.concat(parts, ";")) then return false end
                msgs = msgs + 1
                parts, len = {}, #head
                return true
            end
            for _, key in ipairs(ready) do
                local e = ob[key]
                local s = ("%d,%d,%d,%d,%d"):format(e.cx, e.cy, math.min(e.w, HEARD_MAX_WALKS), math.min(e.t, HEARD_MAX_TROUBLE), e.l)
                if len + #s + 1 > MAX_LEN then
                    if msgs >= BATCH_MAX_MSGS or not flush() then return end
                end
                parts[#parts + 1] = s
                len = len + #s + 1
                ob[key] = nil
            end
            if not flush() then return end
        end
        if msgs >= BATCH_MAX_MSGS then return end
    end
end

-- walked ground from someone else
function MNB:HearGround(rest)
    local cont, body = rest:match("^(%d+)|([%d,;%-]+)$")
    cont = tonumber(cont)
    if not cont or cont > 100000 then return end
    for cx, cy, w, t, l in body:gmatch("(%-?%d+),(%-?%d+),(%d+),(%d+),(%d+)") do
        cx, cy, w, t, l = tonumber(cx), tonumber(cy), tonumber(w), tonumber(t), tonumber(l)
        if cx and math.abs(cx) < 4000 and math.abs(cy) < 4000 and l <= 255 then
            self:AddCell(cont, cx, cy, math.min(w, HEARD_MAX_WALKS), math.min(t, HEARD_MAX_TROUBLE), l, false)
        end
    end
end

---------------------------------------------------------------------------
-- Following the walked ground: the cheapest way over the squares (A*). Walked squares cost less,
-- moves people have made between them less still; squares where fights start cost more. Squares
-- nobody has walked can still be crossed (just dearer): with no walked ground near, it's a straight line.
---------------------------------------------------------------------------
local MAX_SEARCH = 6000
local MAX_SPAN = 160          -- squares (4000 yards): farther than this, it plans toward a spot this far along
local COST_ROAD, COST_WALKED, COST_UNKNOWN = 0.55, 0.8, 1.5
local TROUBLE_COST = 2.5

local function StepCost(g, fromKey, toKey, dirBit, diag)
    local w, t, l = Unpack(g[toKey])
    local base
    if w > 0 then
        local _, _, fl = Unpack(g[fromKey])
        base = HasBit(fl, dirBit) and COST_ROAD or COST_WALKED
        if t > 0 then base = base + TROUBLE_COST * math.min(1, t / (w * 0.25 + 1)) end
    else
        base = COST_UNKNOWN
        if t > 0 then base = base + TROUBLE_COST end
    end
    return base * (diag and 1.4142 or 1)
end

-- a small binary heap
local function Push(h, node, f)
    h.n = h.n + 1
    local i = h.n
    h[i] = { node, f }
    while i > 1 do
        local p = math.floor(i / 2)
        if h[p][2] <= h[i][2] then break end
        h[p], h[i] = h[i], h[p]
        i = p
    end
end
local function Pop(h)
    if h.n == 0 then return nil end
    local top = h[1]
    h[1] = h[h.n]; h[h.n] = nil; h.n = h.n - 1
    local i = 1
    while true do
        local a, b, m = i * 2, i * 2 + 1, i
        if a <= h.n and h[a][2] < h[m][2] then m = a end
        if b <= h.n and h[b][2] < h[m][2] then m = b end
        if m == i then break end
        h[m], h[i] = h[i], h[m]
        i = m
    end
    return top[1]
end

function MNB:GroundWay(cont, wx, wy, tx, ty)
    local g = self.pool.ground and self.pool.ground[cont]
    if not g or not next(g) then return nil end
    local sx, sy, ex, ey = CellOf(wx), CellOf(wy), CellOf(tx), CellOf(ty)
    if sx == ex and sy == ey then return nil end
    local span = math.max(math.abs(ex - sx), math.abs(ey - sy))
    if span > MAX_SPAN then
        -- a long way: plan the first part, toward a spot that far along the straight line
        local f = MAX_SPAN / span
        tx, ty = wx + (tx - wx) * f, wy + (ty - wy) * f
        ex, ey = CellOf(tx), CellOf(ty)
        span = math.max(math.abs(ex - sx), math.abs(ey - sy))
    end
    local function key(x, y) return x .. ":" .. y end
    local function h(x, y)
        local dx, dy = math.abs(x - ex), math.abs(y - ey)
        -- greedy on purpose: on unwalked ground it heads almost straight there (a quick search), and
        -- walked ground (a lot cheaper) still pulls the way onto it
        return (math.max(dx, dy) + 0.4142 * math.min(dx, dy)) * 1.4
    end
    local margin = math.max(20, math.floor(span * 0.5))
    local minx, maxx = math.min(sx, ex) - margin, math.max(sx, ex) + margin
    local miny, maxy = math.min(sy, ey) - margin, math.max(sy, ey) + margin
    local open, cost, came, cx, cy = { n = 0 }, {}, {}, {}, {}
    local sk, ek = key(sx, sy), key(ex, ey)
    cost[sk], cx[sk], cy[sk] = 0, sx, sy
    Push(open, sk, h(sx, sy))
    local done, searched = {}, 0
    while true do
        local k = Pop(open)
        if not k then return nil end
        if k == ek then break end
        if not done[k] then
            done[k] = true
            searched = searched + 1
            if searched > MAX_SEARCH then return nil end
            local x, y = cx[k], cy[k]
            for i, d in ipairs(DIRS) do
                local nx, ny = x + d[1], y + d[2]
                if nx >= minx and nx <= maxx and ny >= miny and ny <= maxy then
                    local nk = key(nx, ny)
                    if not done[nk] then
                        local c = cost[k] + StepCost(g, k, nk, 2 ^ (i - 1), d[1] ~= 0 and d[2] ~= 0)
                        if not cost[nk] or c < cost[nk] then
                            cost[nk], came[nk], cx[nk], cy[nk] = c, k, nx, ny
                            Push(open, nk, c + h(nx, ny))
                        end
                    end
                end
            end
        end
    end
    local way, k, walked = {}, ek, 0
    while k do
        table.insert(way, 1, { (cx[k] + 0.5) * CELL, (cy[k] + 0.5) * CELL })
        if g[k] and Unpack(g[k]) > 0 then walked = walked + 1 end
        k = came[k]
    end
    if walked == 0 then return nil end -- nobody has walked any of it: straight is as good
    way[1] = { wx, wy }
    way[#way] = { tx, ty }
    return way
end

-- the next spot to head for (world x, y), or nil to go straight at the target
--   Steady on purpose: it aims along the way from the point nearest you (never one behind you), as far
--   ahead as the way runs straight (so the squares' zigzag doesn't swing the arrow), and it keeps the
--   way it has until you're well off it.
MNB.AIM_AHEAD = 45      -- yards: never aim closer than this
MNB.AIM_FAR = 300       -- yards: look this far along the way for the straight run
MNB.AIM_SLACK = 20      -- yards: the way counts as straight while it stays this close to the line
MNB.AIM_OFF = 75        -- yards off the way before it's worked out again

local function SegDist(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = len2 > 0 and math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / len2)) or 0
    return math.sqrt((ax + dx * t - px) ^ 2 + (ay + dy * t - py) ^ 2)
end

function MNB:GroundAim(cont, wx, wy, tx, ty)
    local c = self.aimCache
    local now = GetTime()
    local tk = ("%d:%d:%d"):format(cont, CellOf(tx), CellOf(ty))
    if not c or c.tk ~= tk then c = nil end
    -- the point of the way nearest you (from where you were last time on)
    local function nearest(way, from)
        local best, bestD
        for i = from or 1, #way do
            local d = math.sqrt((way[i][1] - wx) ^ 2 + (way[i][2] - wy) ^ 2)
            if not bestD or d < bestD then best, bestD = i, d end
        end
        return best, bestD
    end
    local idx, off
    if c and c.way then idx, off = nearest(c.way, c.i) end
    local stale = not c or (now - c.t >= 20) or (off and off > self.AIM_OFF)
    if stale and not (c and now - c.t < 3) then
        local way = self:GroundWay(cont, wx, wy, tx, ty)
        c = { tk = tk, t = now, way = way, i = 1 }
        self.aimCache = c
        idx, off = nil, nil
        if way then idx, off = nearest(way, 1) end
    end
    local way = c and c.way
    if not way or not idx then return nil end
    c.i = idx
    -- as far ahead as the way runs straight from you
    local pick
    for j = idx + 1, #way do
        local p = way[j]
        local d = math.sqrt((p[1] - wx) ^ 2 + (p[2] - wy) ^ 2)
        if d > self.AIM_FAR then break end
        local straight = true
        for k = idx + 1, j - 1 do
            if SegDist(way[k][1], way[k][2], wx, wy, p[1], p[2]) > self.AIM_SLACK then straight = false break end
        end
        if not straight then break end
        pick = j
    end
    -- straight all the way to the stop (or nothing to bend around): aim at the stop itself
    if not pick or pick >= #way then return nil end
    local p = way[pick]
    if math.sqrt((p[1] - wx) ^ 2 + (p[2] - wy) ^ 2) < self.AIM_AHEAD then
        p = way[math.min(pick + 1, #way)]
        if pick + 1 >= #way then return nil end
    end
    return p[1], p[2]
end

---------------------------------------------------------------------------
-- Who's online: each player's copy says "I'm here, with these add-ons" when it joins the channel and
-- then every 5 minutes. Someone leaving the channel (logging out) drops off at once; anyone not heard
-- from for 11 minutes drops off too (a disconnect).
---------------------------------------------------------------------------
MNB.HELLO_EVERY = 300
MNB.ONLINE_FOR = 660
MNB.mine = MNB.mine or {}
MNB.online = MNB.online or {}

function MNB:Present(name)
    if type(name) == "string" and name ~= "" then self.mine[name] = true end
end

function MNB:Hello()
    local names = {}
    for n in pairs(self.mine) do names[#names + 1] = Clean(n) end
    if #names == 0 then return end
    table.sort(names)
    -- (our mark goes last: older copies just see one more add-on name nobody asks about)
    names[#names + 1] = "#" .. self.token
    if self:Send("I|" .. table.concat(names, ",")) then
        self.helloAt = GetTime()
        self.firstHello = self.firstHello or GetTime()
    end
end

function MNB:HelloTick()
    local now = GetTime()
    if not self.helloAt or now - self.helloAt >= self.HELLO_EVERY then self:Hello() end
end

function MNB:OnlineCount(name)
    local now, n = GetTime(), (self.mine[name] and 1 or 0)
    for who, e in pairs(self.online) do
        if now - e.t > self.ONLINE_FOR then self.online[who] = nil
        elseif e.addons[name] then n = n + 1 end
    end
    local counting = not self.firstHello or now - self.firstHello < self.HELLO_EVERY + 30
    return n, counting
end

-- your own full name: the one your own messages come back under (WoW Forever adds your last name, which
-- UnitName leaves off), or the game's until the first one comes back
function MNB:MyName()
    if self.selfName and self.selfName ~= "" then return self.selfName end
    return UnitName and UnitName("player") or "?"
end

-- who they are (you included), sorted by name
function MNB:OnlineNames(name)
    local now, out = GetTime(), {}
    if self.mine[name] then out[#out + 1] = self:MyName() end
    for who, e in pairs(self.online) do
        if now - e.t > self.ONLINE_FOR then self.online[who] = nil
        elseif e.addons[name] then out[#out + 1] = who end
    end
    table.sort(out, function(a, b) return tostring(a):lower() < tostring(b):lower() end)
    return out
end

-- "/xx who": everybody online with this add-on, in chat (out = the add-on's own print, or print)
function MNB:Who(name, out)
    out = out or print
    local names = self:OnlineNames(name)
    local counting = not self.firstHello or GetTime() - self.firstHello < self.HELLO_EVERY + 30
    out(("%d %s user%s online%s:"):format(#names, name, #names == 1 and "" or "s", counting and " (still counting: everyone checks in within 5 minutes of you logging in)" or ""))
    local line = {}
    for i, n in ipairs(names) do
        line[#line + 1] = n
        if #line == 10 or i == #names then out("  " .. table.concat(line, ", ")); line = {} end
    end
end

---------------------------------------------------------------------------
-- Wiring (one frame and one ticker, whichever copy is running)
---------------------------------------------------------------------------
function MNB:OnEvent(event, ...)
    if event == "PLAYER_LOGIN" then
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end
        C_Timer.After(10, function() MNB:JoinChannel() end)
        if not self.ticker and C_Timer.NewTicker then
            self.ticker = C_Timer.NewTicker(0.5, function() MNB:Tick() end)
        end
        return
    end
    if event == "CHAT_MSG_ADDON" then
        local prefix, text, _, sender = ...
        if prefix == PREFIX then self:OnMessage(text, sender) end
        return
    end
    -- someone left the hidden channel (logged out): off the online count straight away
    if event == "CHAT_MSG_CHANNEL_LEAVE" then
        local _, who, _, chan, _, _, _, _, base = ...
        if (base == CHANNEL_NAME or (type(chan) == "string" and chan:find(CHANNEL_NAME, 1, true))) and who then
            self.online[ShortName(who)] = nil
        end
        return
    end
    if event == "PLAYER_REGEN_DISABLED" then return self:GroundTrouble(1) end
    -- released your spirit: you're standing at a graveyard (a moment later, once the game has moved you)
    if event == "PLAYER_ALIVE" then
        C_Timer.After(1.5, function()
            if not (UnitIsGhost and UnitIsGhost("player")) then return end
            local map, x, y = MNB:Here()
            if not map then return end
            local sub = GetSubZoneText and GetSubZoneText() or ""
            local zone = GetRealZoneText and GetRealZoneText() or ""
            MNB:Record({ k = "grave", f = "N", m = map, x = x, y = y, n = (sub ~= "" and sub) or zone }, true)
        end)
        return
    end
    if event == "PLAYER_DEAD" then return self:GroundTrouble(2) end
    if not Gathering() then return end
    if event == "MERCHANT_SHOW" then
        self:LearnHere("vendor", { st = Stock(), rep = CanMerchantRepair and CanMerchantRepair() and true or nil })
    elseif event == "AUCTION_HOUSE_SHOW" then
        self:LearnHere("ah")
    elseif event == "BANKFRAME_OPENED" then
        self:LearnHere("bank")
    elseif event == "MAIL_SHOW" then
        local map, x, y = self:Here()
        if map then self:Record({ k = "mail", f = "N", m = map, x = x, y = y, n = "Mailbox" }, true) end
    elseif event == "TAXIMAP_OPENED" then
        self:LearnHere("flight")
        self:LearnNodes()
    elseif event == "TRAINER_SHOW" then
        local prof
        if GetTrainerServiceSkillLine then local ok, v = pcall(GetTrainerServiceSkillLine, 1); if ok then prof = v end end
        self:LearnHere("trainer", { t = prof })
    elseif event == "CONFIRM_BINDER" then
        self:LearnHere("inn", { sz = GetSubZoneText and GetSubZoneText() or nil })
    elseif event == "GOSSIP_SHOW" or event == "QUEST_GREETING" or event == "QUEST_DETAIL" then
        self:LearnTalk()
    end
end

MNB.frame = MNB.frame or CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "CHAT_MSG_ADDON", "MERCHANT_SHOW", "AUCTION_HOUSE_SHOW", "BANKFRAME_OPENED",
    "MAIL_SHOW", "TAXIMAP_OPENED", "TRAINER_SHOW", "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL", "CONFIRM_BINDER",
    "PLAYER_REGEN_DISABLED", "PLAYER_DEAD", "PLAYER_ALIVE", "CHAT_MSG_CHANNEL_LEAVE" }) do
    pcall(MNB.frame.RegisterEvent, MNB.frame, e)
end
MNB.frame:SetScript("OnEvent", function(_, event, ...)
    local ok, err = pcall(MNB.OnEvent, MNB, event, ...)
    if not ok and not MNB.eventErr then
        MNB.eventErr = true
        print("|cffff5555MostlyNotBroken data error (" .. tostring(event) .. "):|r " .. tostring(err))
    end
end)
-- (a newer copy loading after login: the ticker and prefix are already set up by the older one)
if IsLoggedIn and IsLoggedIn() and not MNB.ticker and C_Timer and C_Timer.NewTicker then
    MNB.ticker = C_Timer.NewTicker(0.5, function() MNB:Tick() end)
end

---------------------------------------------------------------------------
-- Who uses our add-ons: a badge over their nameplate and a tooltip line. Only on your own screen, and
-- only after "/mnb users" turns it on (saved with your settings; nothing about it is ever sent).
---------------------------------------------------------------------------
-- the add-ons a player (unit) is using, from the online list: { "SnuggleUp Forever", ... } or nil.
-- shown = the name the game shows for them (nameplate or tooltip), which on WoW Forever has their last
-- name too ("Mary Potter"): matched in full. Without it only the first name is known, and that's only
-- used when exactly one online user has it.
function MNB:AddonsOf(unit, shown)
    if not UnitIsPlayer or not UnitIsPlayer(unit) or (UnitIsUnit and UnitIsUnit(unit, "player")) then return nil end
    local function ok(v) return type(v) == "string" and v ~= "" and not (issecretvalue and issecretvalue(v)) end
    local full = ok(shown) and Norm((shown:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("%s*<.*$", ""))) or nil
    local name = UnitName and UnitName(unit)
    local first = ok(name) and Norm(name) or nil
    if not full and not first then return nil end
    local now, found, firstHits, firstSet = GetTime(), nil, 0, nil
    for who, e in pairs(self.online) do
        if now - e.t <= self.ONLINE_FOR then
            if full and Norm(who) == full then
                found = found or {}
                for a in pairs(e.addons) do found[#found + 1] = a end
            elseif first and Norm((tostring(who):match("^(%S+)"))) == first then
                firstHits = firstHits + 1
                firstSet = e.addons
            end
        end
    end
    -- only the first name to go on (or the full name didn't match anyone): one match only
    if not found and firstHits == 1 and (not full or full == first) then
        found = {}
        for a in pairs(firstSet) do found[#found + 1] = a end
    end
    if found then table.sort(found) end
    return found
end

function MNB:MarkOn() return self:Setting("markUsers") and true or false end

local function Badge(plate)
    local b = plate.mnbBadge
    if not b then
        b = plate:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b:SetPoint("BOTTOM", plate, "TOP", 0, 2)
        b:SetText("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_3:12|t|cffffd100MNB|r")
        plate.mnbBadge = b
    end
    return b
end

function MNB:MarkPlate(unit)
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return end
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then return end
    local uf = plate.UnitFrame
    local shown = uf and uf.name and uf.name.GetText and uf.name:GetText()
    local list = self:MarkOn() and self:AddonsOf(unit, shown)
    if list then Badge(plate):Show() elseif plate.mnbBadge then plate.mnbBadge:Hide() end
end

function MNB:MarkAll()
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
        local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        if unit then pcall(self.MarkPlate, self, unit) elseif plate.mnbBadge then plate.mnbBadge:Hide() end
    end
end

function MNB:MarkTooltip(tip)
    if not self:MarkOn() or not tip or not tip.GetUnit then return end
    local _, unit = tip:GetUnit()
    if not unit then return end
    local line1 = _G[(tip.GetName and tip:GetName() or "GameTooltip") .. "TextLeft1"]
    local shown = line1 and line1.GetText and line1:GetText()
    local list = self:AddonsOf(unit, shown)
    if list then
        tip:AddLine("|cffffd100MostlyNotBroken:|r " .. table.concat(list, ", "), 1, 1, 1, true)
        tip:Show()
    end
end

if not MNB.markHooked then
    MNB.markHooked = true
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tip)
            local M = _G.MostlyNotBroken
            if M and M.MarkTooltip then pcall(M.MarkTooltip, M, tip) end
        end)
    elseif GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetUnit", function(tip)
            local M = _G.MostlyNotBroken
            if M and M.MarkTooltip then pcall(M.MarkTooltip, M, tip) end
        end)
    end
    local mf = CreateFrame("Frame")
    pcall(mf.RegisterEvent, mf, "NAME_PLATE_UNIT_ADDED")
    pcall(mf.RegisterEvent, mf, "NAME_PLATE_UNIT_REMOVED")
    mf:SetScript("OnEvent", function(_, event, unit)
        local M = _G.MostlyNotBroken
        if not M or not M.MarkPlate then return end
        if event == "NAME_PLATE_UNIT_ADDED" then pcall(M.MarkPlate, M, unit)
        elseif C_NamePlate and C_NamePlate.GetNamePlateForUnit then
            local plate = C_NamePlate.GetNamePlateForUnit(unit)
            if plate and plate.mnbBadge then plate.mnbBadge:Hide() end
        end
    end)
    -- the online list changes as people say hello: look again every few seconds
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(5, function()
            local M = _G.MostlyNotBroken
            if M and M.MarkOn and M:MarkOn() then pcall(M.MarkAll, M) end
        end)
    end
    SLASH_MNBMARK1 = "/mnb"
    SlashCmdList.MNBMARK = function(msg)
        local M = _G.MostlyNotBroken
        if not M then return end
        if (msg or ""):lower():match("^%s*users") then
            M:SetSetting("markUsers", not M:MarkOn() or nil)
            print(M:MarkOn() and "|cffffd100MostlyNotBroken:|r players using our add-ons are marked (only you see it)."
                or "|cffffd100MostlyNotBroken:|r marks off.")
            pcall(M.MarkAll, M)
        end
    end
end
