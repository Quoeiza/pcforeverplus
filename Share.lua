-- ProfitCrafter: price sharing
-- Automatically trades Auction House prices with other ProfitCrafter users through the hidden
-- MostlyNotBrokenAddons chat channel (shared by all of these addons), plus your guild and group:
--   * after each of your scans, your fresh prices are sent out
--   * when you log in or open the window, it asks others for anything newer than yours
-- Also reads Auctionator's saved prices (if installed) for items nobody has priced yet.

local ADDON, ns = ...
local PC = ns.PC

local PREFIX = "PCrafter1"          -- hidden addon-message channel name (max 16 characters)
local SU_PREFIX = "SnuggleUp1"      -- Snuggle Up's (same channel): its elevator spots are read too
local CHANNEL_NAME = "MostlyNotBrokenAddons" -- hidden chat channel shared by all MostlyNotBroken addons (each uses its own PREFIX)
local MAX_LEN = 240                 -- addon messages are limited to 255 characters
local SEND_GAP = 1.1                -- seconds between messages, to stay under Blizzard's limit
local SHARE_MAX_AGE = 2 * 3600      -- only share prices from your own scans in the last 2 hours
local ACCEPT_MAX_AGE = 3 * 86400    -- ignore shared prices older than 3 days
local REQUEST_COOLDOWN = 10 * 60    -- ask others for prices at most every 10 minutes
local REPLY_COOLDOWN = 5 * 60       -- answer requests at most every 5 minutes
local MAX_ITEMS = 400               -- most prices sent in one share
local OWN_SCAN_WINS = 60            -- seconds your own scan of an item beats other players' reports

local Share = {}
PC.Share = Share

---------------------------------------------------------------------------
-- Saved data helpers
---------------------------------------------------------------------------
-- Who a price came from: nil = your own scan, otherwise the sharing player's name
function PC:Source()
    local f = self:Faction()
    self.db.source = self.db.source or {}
    self.db.source[f] = self.db.source[f] or {}
    return self.db.source[f]
end

function Share:Enabled()
    if PC.FOREVER then return true end -- WoW Forever: always on (the Mostly Not Broken standard)
    return PC.db and PC.db.share ~= false
end

-- What sharing has done, so you can see it working (addon messages never show up as chat):
-- db.shareLog[faction] = { sent = {t, n}, asked = t, users = { [name] = { seen = t, t = t, n = last count, total = n } } }
function Share:Log()
    local db = PC.db
    db.shareLog = db.shareLog or {}
    local f = PC:Faction()
    db.shareLog[f] = db.shareLog[f] or {}
    local log = db.shareLog[f]
    log.users = log.users or {}
    return log
end

local function NoteUser(who, applied)
    local u = Share:Log().users
    u[who] = u[who] or { total = 0 }
    local e = u[who]
    e.seen = time()
    if applied and applied > 0 then
        e.t, e.n, e.total = time(), applied, (e.total or 0) + applied
    end
    -- keep the list short: drop people not heard from in 30 days
    for name, x in pairs(u) do
        if time() - (x.seen or 0) > 30 * 86400 then u[name] = nil end
    end
end

-- Lines for /pc share and the settings page
function Share:StatusLines()
    local lines = {}
    local yes, no = "|cff40ff40", "|cffff5555"
    if not self:Enabled() then
        lines[1] = no .. "Price sharing is off.|r Turn it on in settings or with /pc share on."
        return lines
    end
    local where = {}
    if self:ChannelID() then where[#where + 1] = "the hidden MostlyNotBrokenAddons channel" end
    if IsInGuild and IsInGuild() then where[#where + 1] = "your guild" end
    if IsInRaid and IsInRaid() then where[#where + 1] = "your raid"
    elseif IsInGroup and IsInGroup() then where[#where + 1] = "your group" end
    lines[#lines + 1] = #where > 0 and (yes .. "Sharing is on|r through " .. table.concat(where, ", ") .. ".")
        or (no .. "Not connected yet|r (the hidden channel is joined a few seconds after login).")

    local log = self:Log()
    if log.sent then
        lines[#lines + 1] = ("You sent |cffffffff%d|r prices %s ago."):format(log.sent.n or 0, PC:Ago(time() - log.sent.t))
    else
        lines[#lines + 1] = "You haven't sent prices yet. They go out after each of your scans."
    end
    if log.asked then
        lines[#lines + 1] = ("Last asked others for newer prices %s ago."):format(PC:Ago(time() - log.asked))
    end

    local people = {}
    for name, e in pairs(log.users) do people[#people + 1] = { name = name, e = e } end
    table.sort(people, function(a, b) return (a.e.seen or 0) > (b.e.seen or 0) end)
    if #people == 0 then
        lines[#lines + 1] = "|cff888888No other ProfitCrafter users heard from yet on your faction.|r"
    else
        lines[#lines + 1] = ("Heard from |cffffffff%d|r ProfitCrafter user%s:"):format(#people, #people == 1 and "" or "s")
        for i, x in ipairs(people) do
            if i > 8 then
                lines[#lines + 1] = ("  |cff888888...and %d more|r"):format(#people - 8)
                break
            end
            local e = x.e
            if e.t then
                lines[#lines + 1] = ("  |cffffffff%s|r  got %d prices %s ago  |cff888888(%d in all)|r"):format(
                    x.name, e.n or 0, PC:Ago(time() - e.t), e.total or 0)
            else
                lines[#lines + 1] = ("  |cffffffff%s|r  seen %s ago  |cff888888(nothing newer than yours)|r"):format(
                    x.name, PC:Ago(time() - e.seen))
            end
        end
    end
    return lines
end

---------------------------------------------------------------------------
-- The shared MostlyNotBrokenAddons chat channel (joined quietly, hidden from your chat windows)
---------------------------------------------------------------------------
local function HideChannel()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local frame = _G["ChatFrame" .. i]
        if frame then
            if ChatFrame_RemoveChannel then
                pcall(ChatFrame_RemoveChannel, frame, CHANNEL_NAME)
            elseif ChatFrameUtil and ChatFrameUtil.RemoveChannel then
                pcall(ChatFrameUtil.RemoveChannel, frame, CHANNEL_NAME)
            end
        end
    end
end

function Share:ChannelID()
    if not GetChannelName then return nil end
    local id = GetChannelName(CHANNEL_NAME)
    if id and id > 0 then return id end
    return nil
end

function Share:JoinChannel()
    if not self:Enabled() or not JoinTemporaryChannel then return end
    if not self:ChannelID() then
        pcall(JoinTemporaryChannel, CHANNEL_NAME)
    end
    C_Timer.After(1, HideChannel)
end

function Share:LeaveChannel()
    if self:ChannelID() and LeaveChannelByName then pcall(LeaveChannelByName, CHANNEL_NAME) end
end

---------------------------------------------------------------------------
-- Auctionator fallback
---------------------------------------------------------------------------
local AUCTIONATOR_MAX_AGE = 7 -- days

function PC:AuctionatorPrice(itemID)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not api or not api.GetAuctionPriceByItemID then return nil end
    local ok, price = pcall(api.GetAuctionPriceByItemID, PC.NAME, itemID)
    if not ok or not price or price <= 0 then return nil end
    if api.GetAuctionAgeByItemID then
        local okAge, age = pcall(api.GetAuctionAgeByItemID, PC.NAME, itemID)
        if okAge and age and age > AUCTIONATOR_MAX_AGE then return nil end
    end
    return price
end

-- TradeSkillMaster's numbers (if installed): any TSM price source, e.g. "dbminbuyout", "dbmarket",
-- "dbregionsoldperday" (nil when TSM isn't there or has no data)
function PC:TSMValue(source, itemID)
    local api = TSM_API
    if not api or not api.GetCustomPriceValue or not itemID then return nil end
    local ok, v = pcall(api.GetCustomPriceValue, source, "i:" .. itemID)
    if ok and type(v) == "number" and v > 0 then return v end
    return nil
end

-- TSM's price for an item: its last scan's lowest buyout, else its market value
function PC:TSMPrice(itemID)
    return self:TSMValue("dbminbuyout", itemID) or self:TSMValue("dbmarket", itemID)
end

-- Best known AH price for an item: your scans and shared prices first, then Auctionator, then TSM
function PC:Price(itemID)
    local p = self:Prices()[itemID]
    if p then return p, self:Source()[itemID] or "own" end
    p = self:AuctionatorPrice(itemID)
    if p then return p, "Auctionator" end
    p = self:TSMPrice(itemID)
    if p then return p, "TSM" end
    return nil
end

---------------------------------------------------------------------------
-- Sending (queued, one message at a time)
---------------------------------------------------------------------------
local queue, pumping = {}, false

local function Channels()
    local list = {}
    local chan = Share:ChannelID()
    if chan then list[#list + 1] = { "CHANNEL", chan } end
    -- WoW Forever: the hidden channel only (never guild, party or raid); not joined yet = nothing goes out
    if PC.FOREVER then return list end
    if IsInGuild and IsInGuild() then list[#list + 1] = { "GUILD" } end
    if IsInRaid and IsInRaid() then
        list[#list + 1] = { "RAID" }
    elseif IsInGroup and IsInGroup(LE_PARTY_CATEGORY_HOME) then
        list[#list + 1] = { "PARTY" }
    end
    return list
end

local function Pump()
    if #queue == 0 then
        pumping = false
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        C_Timer.After(3, Pump) -- wait until out of combat
        return
    end
    local m = table.remove(queue, 1)
    pcall(C_ChatInfo.SendAddonMessage, PREFIX, m.text, m.channel[1], m.channel[2])
    C_Timer.After(SEND_GAP, Pump)
end

local function Send(text)
    for _, ch in ipairs(Channels()) do
        queue[#queue + 1] = { text = text, channel = ch }
    end
    if not pumping and #queue > 0 then
        pumping = true
        Pump()
    end
end

---------------------------------------------------------------------------
-- Sharing your prices
---------------------------------------------------------------------------
function Share:OwnFreshPrices()
    local prices, checked, supply, source = PC:Prices(), PC:Checked(), PC:Supply(), PC:Source()
    local now, list = time(), {}
    for id, p in pairs(prices) do
        local t = checked[id]
        if t and not source[id] and now - t <= SHARE_MAX_AGE then
            list[#list + 1] = { id = id, p = math.floor(p + 0.5), q = supply[id] or 0, t = t }
        end
    end
    table.sort(list, function(a, b) return a.t > b.t end)
    while #list > MAX_ITEMS do table.remove(list) end
    return list
end

function Share:Broadcast(reason)
    if not self:Enabled() or not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return end
    if #Channels() == 0 then return end
    local list = self:OwnFreshPrices()
    if #list == 0 then return end

    local scanTime = PC.db.scanTime[PC:Faction()] or time()
    local header = ("P|%s|%d|"):format(PC:Faction(), scanTime)
    local parts, len = {}, #header
    local sent = 0
    for _, it in ipairs(list) do
        local piece = ("%d:%d:%d"):format(it.id, it.p, it.q)
        if len + #piece + 1 > MAX_LEN then
            Send(header .. table.concat(parts, ","))
            sent = sent + 1
            parts, len = {}, #header
        end
        parts[#parts + 1] = piece
        len = len + #piece + 1
    end
    if #parts > 0 then
        Send(header .. table.concat(parts, ","))
        sent = sent + 1
    end
    self.lastShare = GetTime()
    self:Log().sent = { t = time(), n = #list }
    if reason == "scan" and not PC.FOREVER then
        PC.Print(("Sharing %d prices with other ProfitCrafter users."):format(#list))
    end
end

-- Tell others about a place you just used (vendors with what they sell)
function Share:SharePlace(key, p)
    if not self:Enabled() or not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return end
    if #Channels() == 0 or not p or not p.map then return end
    self.placeSent = self.placeSent or {}
    if self.placeSent[key] and GetTime() - self.placeSent[key] < 3600 then return end -- once an hour per place
    self.placeSent[key] = GetTime()
    local ids = {}
    for id in pairs(p.stock or {}) do ids[#ids + 1] = tostring(id) end
    -- newer kinds (trainers, inns, portals, boats) and extra details go in the "X" message; older
    -- versions ignore it and keep getting the plain "L" one for the kinds they know
    local extra = {}
    for _, k in ipairs({ "prof", "repair", "sub", "tomap", "tox", "toy", "tozone", "secs", "via" }) do
        local v = p[k]
        if v ~= nil then
            if type(v) == "number" and v % 1 ~= 0 then v = ("%.4f"):format(v) end
            extra[#extra + 1] = k .. "=" .. tostring(v):gsub("[|;=]", "")
        end
    end
    if #extra > 0 or not (PC.Places.OLD_KINDS or {})[p.kind] then
        Send(("X|%s|%s|%s|%d|%.4f|%.4f|%s|%s|"):format(PC:Faction(), key, (p.name or ""):gsub("|", ""), p.map, p.x, p.y,
            (p.zone or ""):gsub("|", ""), table.concat(extra, ";")))
        if not (PC.Places.OLD_KINDS or {})[p.kind] then return end
    end
    local head = ("L|%s|%s|%s|%d|%.4f|%.4f|%s|"):format(PC:Faction(), key, (p.name or ""):gsub("|", ""), p.map, p.x, p.y, (p.zone or ""):gsub("|", ""))
    local body, len = {}, #head
    for _, id in ipairs(ids) do
        if len + #id + 1 > MAX_LEN then break end
        body[#body + 1] = id
        len = len + #id + 1
    end
    Send(head .. table.concat(body, ","))
end

-- Something another part of ProfitCrafter shares (recipe finds, trainer lists): sent like the rest
function Share:SendRaw(text)
    if not self:Enabled() or not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return end
    if #Channels() == 0 then return end
    Send(text)
end

-- An elevator spot (Undercity, Thunder Bluff), in the same form Snuggle Up uses: E|map|x|y
-- (the direction goes last: Snuggle Up reads map|x|y and skips the rest)
function Share:SendElevator(map, x, y, dir)
    if not self:Enabled() or not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return end
    Send(("E|%d|%.4f|%.4f%s"):format(map, x, y, dir and ("|" .. dir) or ""))
end

-- Who's online with ProfitCrafter right now (your faction): ask, collect answers for a few seconds, report
function Share:Online()
    if not self:Enabled() then return PC.Print("Price sharing is off, so ProfitCrafter can't reach other users. Turn it on with /pc share on.") end
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage or #Channels() == 0 then
        return PC.Print(PC.FOREVER and "Can't reach other ProfitCrafter users yet. Try again in a moment."
            or "Not connected to the MostlyNotBrokenAddons channel yet. Try again in a moment.")
    end
    if self.census then return PC.Print("Already asking: answers in a few seconds.") end
    self.census = {}
    Send(("H|%s|%s"):format(PC:Faction(), PC.VERSION or "?"))
    PC.Print("Asking who's online with ProfitCrafter...")
    C_Timer.After(8, function()
        local names = {}
        for who, ver in pairs(self.census or {}) do names[#names + 1] = who .. " |cff888888(" .. ver .. ")|r" end
        self.census = nil
        table.sort(names)
        local recent, month = 0, 0
        for _, e in pairs(self:Log().users) do
            if time() - (e.seen or 0) < 15 * 60 then recent = recent + 1 end
            month = month + 1
        end
        PC.Print(("|cff40ff40%d other ProfitCrafter user%s online now|r (your faction)%s"):format(#names, #names == 1 and "" or "s",
            #names > 0 and (": " .. table.concat(names, ", ")) or "."))
        PC.Print(("Heard from %d in the last 15 minutes, %d in the last 30 days."):format(recent, month))
    end)
end

-- Ask others for prices newer than ours
function Share:Request(force)
    if not self:Enabled() or not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return end
    if #Channels() == 0 then return end
    if not force and self.lastRequest and GetTime() - self.lastRequest < REQUEST_COOLDOWN then return end
    self.lastRequest = GetTime()
    self:Log().asked = time()
    Send(("R|%s|%d"):format(PC:Faction(), PC.db.scanTime[PC:Faction()] or 0))
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local received = {} -- [sender] = count, reported in chat a moment later

local function ShortName(name)
    if Ambiguate then return Ambiguate(name, "short") end
    return (name:gsub("%-.*", ""))
end

function Share:OnMessage(text, sender)
    if not self:Enabled() or not PC.db then return end
    local who = ShortName(sender or "?")
    if who == UnitName("player") then return end

    -- shared with the other MostlyNotBroken addons (no faction in it): an elevator spot
    local emap, ex, ey = text:match("^E|(%d+)|([%d%.]+)|([%d%.]+)")
    if emap then
        local edir = text:match("^E|%d+|[%d%.]+|[%d%.]+|(%a+)")
        if PC.Travel and PC.Travel:AddElevator(tonumber(emap), tonumber(ex), tonumber(ey), who, edir) then
            local c = PC.Travel:ElevatorCity(tonumber(emap))
            if not PC.FOREVER then PC.Print(("Got an elevator spot in %s from %s."):format(c and c.name or "a city", who)) end
        end
        return
    end
    local kind, faction, rest = text:match("^(%a)|([^|]*)|(.*)$")
    -- recipes players found (either faction: a drop is a drop) and trainers' lists
    if (kind == "F" or kind == "T") and PC.Finds then NoteUser(who); return PC.Finds:OnMessage(kind, faction, rest, who) end
    if not kind or faction ~= PC:Faction() then return end -- other faction's AH is a different market
    NoteUser(who)

    if kind == "H" then
        -- "who's online?": answer after a short random wait (so not everyone answers at once), at most once a minute
        if not (self.lastHello and GetTime() - self.lastHello < 60) then
            self.lastHello = GetTime()
            C_Timer.After(0.5 + math.random() * 3, function()
                Send(("O|%s|%s"):format(PC:Faction(), PC.VERSION or "?"))
            end)
        end
        return
    end
    if kind == "O" then
        if self.census then self.census[who] = rest ~= "" and rest or "?" end
        return
    end

    if kind == "R" then
        -- Someone wants prices. Answer if ours are newer, after a short random wait so not everyone answers at once.
        local theirs = tonumber(rest) or 0
        local mine = PC.db.scanTime[PC:Faction()] or 0
        if mine > theirs + 60 and not (self.lastShare and GetTime() - self.lastShare < REPLY_COOLDOWN) then
            local token = {}
            self.pendingReply = token
            C_Timer.After(1 + math.random() * 5, function()
                if self.pendingReply == token then
                    self.pendingReply = nil
                    self:Broadcast("reply")
                end
            end)
        end
        return
    end

    if kind == "X" then
        -- a place with extra details: key|name|map|x|y|zone|k=v;k=v|
        if not PC.Places then return end
        local key, name, map, x, y, zone, extra = rest:match("^([^|]*)|([^|]*)|(%d+)|([%d%.]+)|([%d%.]+)|([^|]*)|([^|]*)")
        if not key then return end
        local pkind = key:match("^(%a+):")
        if not PC.Places.KINDS[pkind] then return end
        local p = { kind = pkind, name = name, map = tonumber(map), x = tonumber(x), y = tonumber(y), zone = zone, seen = time() }
        for k, v in (extra or ""):gmatch("([%a]+)=([^;]*)") do
            if k == "repair" then p.repair = v == "true"
            elseif k == "tomap" or k == "tox" or k == "toy" or k == "secs" then p[k] = tonumber(v)
            else p[k] = v end
        end
        PC.Places:Heard(key, p)
        return
    end

    if kind == "L" then
        -- a place someone learned: key|name|map|x|y|zone|stock ids
        if not PC.Places then return end
        local key, name, map, x, y, zone, stock = rest:match("^([^|]*)|([^|]*)|(%d+)|([%d%.]+)|([%d%.]+)|([^|]*)|(.*)$")
        if not key then return end
        local pkind = key:match("^(%a+):")
        if not PC.Places.KINDS[pkind] then return end
        local p = { kind = pkind, name = name, map = tonumber(map), x = tonumber(x), y = tonumber(y), zone = zone, seen = time() }
        if stock ~= "" then
            p.stock = {}
            for id in stock:gmatch("%d+") do p.stock[tonumber(id)] = true end
        end
        PC.Places:Heard(key, p)
        return
    end

    if kind ~= "P" then return end
    local stamp, body = rest:match("^(%d+)|(.*)$")
    stamp = tonumber(stamp)
    if not stamp then return end
    local now = time()
    if stamp > now + 300 or now - stamp > ACCEPT_MAX_AGE then return end -- clock nonsense or too old

    -- Someone else already answered with data at least as new as ours: no need to reply too
    if self.pendingReply and stamp >= (PC.db.scanTime[PC:Faction()] or 0) then self.pendingReply = nil end

    -- a clock a little ahead: never stamp prices with a time that hasn't come yet (it would block
    -- newer prices, your own included, until that time passed)
    if stamp > now then stamp = now end

    local prices, checked, supply, source = PC:Prices(), PC:Checked(), PC:Supply(), PC:Source()
    local applied = 0
    for id, p, q in body:gmatch("(%d+):(%d+):(%d+)") do
        id, p, q = tonumber(id), tonumber(p), tonumber(q)
        if id and p and p > 0 and p < 1e10 then
            -- your own scan (or live listings read) of it in the last minute wins over anyone's report:
            -- yours is what's on the AH right now
            local t = checked[id]
            local ownFresh = t and not source[id] and (now - t <= OWN_SCAN_WINS or stamp - t <= OWN_SCAN_WINS)
            -- otherwise only take it if it's newer than what we have
            if not ownFresh and (t or 0) < stamp then
                -- Guard against bad data: ignore prices wildly off from what this item usually costs
                local _, usual = PC:Trend(id)
                if not usual or (p < usual * 5 and p > usual / 5) then
                    prices[id] = p
                    supply[id] = q
                    checked[id] = stamp
                    source[id] = who
                    PC:AddHistory(id, p)
                    PC:AddSupplyPoint(id, q, stamp) -- shared counts improve everyone's sales estimates
                    applied = applied + 1
                end
            end
        end
    end

    if applied > 0 then
        NoteUser(who, applied)
        received[who] = (received[who] or 0) + applied
        PC:Debounce("shareNotice", 4, function()
            for name, n in pairs(received) do
                if not PC.FOREVER then PC.Print(("Got %d newer prices from %s."):format(n, name)) end
            end
            wipe(received)
        end)
        PC:RefreshUI()
    end
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
pcall(f.RegisterEvent, f, "CHAT_MSG_ADDON")
local function OnShareEvent(event, ...)
    if event == "PLAYER_LOGIN" then
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
            -- Snuggle Up's messages too: the elevator spots its users share (same channel, its own prefix)
            pcall(C_ChatInfo.RegisterAddonMessagePrefix, SU_PREFIX)
        end
        C_Timer.After(8, function() Share:JoinChannel() end)  -- join after the game's own channels
        C_Timer.After(20, function() Share:Request() end)     -- then ask everyone for newer prices
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, text, _, sender = ...
        if prefix == PREFIX then Share:OnMessage(text, sender)
        elseif prefix == SU_PREFIX and type(text) == "string" and text:find("^E|") then Share:OnMessage(text, sender) end
    end
end
f:SetScript("OnEvent", function(_, event, ...) PC:Safe("price sharing", OnShareEvent, event, ...) end)
