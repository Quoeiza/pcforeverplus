-- ProfitCrafter: Core
-- Tracks your professions, learned recipes, gold, Auction House prices and
-- vendor prices, and works out which crafts make a profit.

local ADDON, ns = ...

local PC = CreateFrame("Frame")
ns.PC = PC
ProfitCrafter = PC

local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata

-- Some game values are "secret" at times (in combat, for example): they can't be compared or
-- used in maths by an addon. Anything that might be one is checked with this first.
function PC.IsSecret(v)
    return v ~= nil and issecretvalue ~= nil and issecretvalue(v) and true or false
end
-- Text in another alphabet than this game client's (Cyrillic on an English client, Chinese or Korean
-- on a Russian one...): names and zones other players' clients sent in their own language
local CLIENT_LOCALE = GetLocale and GetLocale() or "enUS"
function PC.Foreign(s)
    if type(s) ~= "string" or s == "" or PC.IsSecret(s) then return false end
    if CLIENT_LOCALE ~= "ruRU" and s:find("[\208-\211][\128-\191]") then return true end
    if CLIENT_LOCALE ~= "koKR" and CLIENT_LOCALE ~= "zhCN" and CLIENT_LOCALE ~= "zhTW"
        and s:find("[\227-\237][\128-\191][\128-\191]") then return true end
    return false
end
-- a plain number, or nil when the game is keeping it secret right now
function PC.Num(v)
    if v == nil or PC.IsSecret(v) or type(v) ~= "number" then return nil end
    return v
end
PC.BUILD = "0.3.0" -- stamped with the real version when the zip is built
-- real arrows (pictures, not typed characters) for use inside text
PC.ARROW_R = "|TInterface\\AddOns\\" .. ADDON .. "\\Media\\ArrowRight:12:12:0:0|t"
PC.ARROW_L = "|TInterface\\AddOns\\" .. ADDON .. "\\Media\\ArrowLeft:12:12:0:0|t"
PC.ARROW_U = "|TInterface\\AddOns\\" .. ADDON .. "\\Media\\SortUp:10:10:0:0|t"
PC.ARROW_D = "|TInterface\\AddOns\\" .. ADDON .. "\\Media\\SortDown:10:10:0:0|t"
PC.TOC_VERSION = (GetMeta and GetMeta(ADDON, "Version")) or "?"
PC.VERSION = (PC.BUILD ~= "dev" and PC.BUILD) or PC.TOC_VERSION -- the version of the files actually running
PC.NAME = (GetMeta and GetMeta(ADDON, "Title")) or "ProfitCrafter"   -- "ProfitCrafter" or "ProfitCrafter Forever"

PC.AH_CUT = 0.05             -- Auction House takes 5% of the sale
PC.MIN_PROFIT_DEFAULT = 10   -- percent of the materials cost a craft must make (Settings)
PC.MAX_CRAFTABLE = 9999      -- most crafts the Craftable column counts up to (a plan holds at most 9999)
PC.SCAN_COOLDOWN = 15 * 60   -- Blizzard allows one full AH scan every 15 minutes
PC.MAX_AFFORD_CHECK = 200    -- most crafts we'll check when working out what you can afford
PC.QUICK_BATCH = 100         -- items per Auction House search in the normal scan (the most the game takes)
PC.HOT_TIER = 1e12           -- (a best bet's score: hot sellers ahead of everything else)

local BASIC_REAGENT = (Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic) or 1

-- ProfitCrafter's messages go to their own chat tab ("ProfitCrafter"), made once at login
PC.CHAT_NAME = "ProfitCrafter"
local function ChatTab()
    if not (PC.db and PC.db.ownChat == true) then return nil end -- off unless turned on
    if PC._chat and PC._chat.AddMessage then return PC._chat end
    if not GetChatWindowInfo then return nil end
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local name = GetChatWindowInfo(i)
        if name == PC.CHAT_NAME then
            local f = _G["ChatFrame" .. i]
            if f and f.AddMessage then PC._chat = f; return f end
        end
    end
    return nil
end
function PC:EnsureChatTab()
    if not (self.db and self.db.ownChat == true) then return end
    if ChatTab() or not FCF_OpenNewWindow then return end
    if InCombatLockdown and InCombatLockdown() then return end
    local ok, f = pcall(FCF_OpenNewWindow, self.CHAT_NAME)
    f = (ok and type(f) == "table" and f.AddMessage) and f or ChatTab()
    if f then
        -- only ProfitCrafter's own lines in it: no say, guild, trade...
        if ChatFrame_RemoveAllMessageGroups then pcall(ChatFrame_RemoveAllMessageGroups, f) end
        if ChatFrame_RemoveAllChannels then pcall(ChatFrame_RemoveAllChannels, f) end
        self._chat = f
        f:AddMessage("|cff33ff99" .. self.NAME .. ":|r messages from ProfitCrafter show here (Settings to turn this off).")
    end
end
local function Print(msg)
    local text = "|cff33ff99" .. PC.NAME .. ":|r " .. tostring(msg)
    local f = ChatTab()
    if f then f:AddMessage(text) else print(text) end
end
PC.Print = Print
do
    local cev = CreateFrame and CreateFrame("Frame")
    if cev then
        pcall(cev.RegisterEvent, cev, "PLAYER_ENTERING_WORLD")
        cev:SetScript("OnEvent", function(self)
            self:UnregisterAllEvents()
            if C_Timer then C_Timer.After(3, function() pcall(PC.EnsureChatTab, PC) end) end
        end)
    end
end

-- Calls fn only if it exists (some APIs may be missing in a given game version)
local function Try(fn, ...)
    if fn then return fn(...) end
end

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------
local db, cdb

-- Reagents every reagent/trade vendor sells, with their usual price in copper
PC.KNOWN_VENDOR = {
    [2678] = 10, [2692] = 40, [3713] = 20,                       -- Mild / Hot / Soothing Spices
    [159] = 25, [1179] = 125, [1205] = 400, [1708] = 1000,       -- Refreshing Spring Water, Ice Cold Milk, Melon Juice, Sweet Nectar
    [2320] = 10, [2321] = 100, [4291] = 500, [8343] = 2000, [14341] = 5000, -- Coarse/Fine/Silken/Heavy Silken/Rune Thread
    [3371] = 20, [3372] = 200, [8925] = 2000,                    -- Empty / Leaded / Crystal Vial
    [4470] = 10, [4471] = 10,                                    -- Simple Wood, Flint and Tinder
    [2880] = 10, [3466] = 2000,                                  -- Weak Flux, Strong Flux
    [2604] = 50, [2605] = 100, [6260] = 50, [2324] = 25, [4340] = 100, [4341] = 150, [4342] = 2500, [6261] = 250, -- dyes, bleach
    [4399] = 10, [4400] = 200, [11291] = 4000, [18256] = 3000,   -- Wooden Stock, Heavy Stock, Star Wood, Imbued Vial
    [6530] = 300, [6529] = 50, [6532] = 1000, [6533] = 1500,     -- Nightcrawlers, Shiny Bauble, Bright Baubles, Aquadynamic Fish Attractor
    [30817] = 25,                                                -- Simple Flour
    [6217] = 124, [6338] = 2000, [11128] = 10000, [11144] = 20000, [16206] = 40000, -- Copper/Silver/Golden/Truesilver/Arcanite Rod
}

local function InitDB()
    ProfitCrafterDB = ProfitCrafterDB or {}
    ProfitCrafterCharDB = ProfitCrafterCharDB or {}
    db, cdb = ProfitCrafterDB, ProfitCrafterCharDB

    db.prices = db.prices or {}        -- [faction][itemID] = lowest buyout per item (copper)
    db.scanTime = db.scanTime or {}    -- [faction] = time of last finished scan
    db.vendor = db.vendor or {}        -- [itemID] = vendor price per item (copper)
    -- settings that are gone, or that "Plan my route for me" (mapPins) now covers
    for _, k in ipairs({ "tickerScreenReset", "ownChatReset", "quickCraftReset", "routeOneSwitch", "stepsPanel", "toasts",
        "craftFX", "screenArrow", "starNpc", "smartTravel", "useHearth", "learnPlaces" }) do db[k] = nil end
    -- the usual vendor-sold reagents are known from the start (approximate prices, replaced the first
    -- time you see them at a vendor), so their scam AH listings never show up as deals or on tickers
    for id, price in pairs(PC.KNOWN_VENDOR) do
        if db.vendor[id] == nil then db.vendor[id] = price end
    end
    db.checked = db.checked or {}      -- [faction][itemID] = time the AH was last checked for it
    db.supply = db.supply or {}        -- [faction][itemID] = how many are listed on the AH right now
    db.history = db.history or {}      -- [faction][itemID] = { {t, p}, ... } past lowest prices
    db.sellPrice = db.sellPrice or {}  -- [itemID] = what a vendor pays you for one (copper)
    db.supplyHist = db.supplyHist or {} -- [faction][itemID] = { {t, q}, ... } how many were listed over time
    db.lastSold = db.lastSold or {}
    db.hideExp = db.hideExp or {}      -- [expansion id] = true: don't scan or show that expansion's recipes    -- [faction][itemID] = last time we saw one sell (kept for good, unlike supplyHist)
    db.lastScanStart = db.lastScanStart or 0
    if db.autoScan == nil then db.autoScan = true end
    -- the minimum profit (percent of the materials cost): lists hide recipes under it and buying stops
    -- before a craft would make less (the Minimum profit % box on the Recipes and Learn pages)
    if type(db.minProfitPct) ~= "number" then db.minProfitPct = PC.MIN_PROFIT_DEFAULT end
    db.onlyProfit, db.onlyVProfit, db.minProfitFilter = nil, nil, nil -- old profit boxes (removed)
    -- recommendations (Best bets, Make me gold, Have materials) leave out AH crafts nobody bought today
    if db.needSalesToday == nil then db.needSalesToday = true end
    db.uiStyle, db.reopenTab = nil, nil              -- old window-style setting (removed)
    if db.share == nil then db.share = true end     -- trade prices with guild/group automatically
    db.source = db.source or {}                     -- [faction][itemID] = who shared that price (nil = your own scan)

    cdb.professions = cdb.professions or {} -- [skillLine] = { name, rank, max }
    cdb.recipes = cdb.recipes or {}         -- [recipeID] = { name, prof, output, qty, reagents, diff }
    cdb.overrides = cdb.overrides or {}     -- { gold = copper }: the spending limit
    cdb.overrides.levels = nil              -- typed-in profession levels: removed with the Levels & gold tab
    cdb.ledger = cdb.ledger or {}           -- AH trades: { t, kind = "buy"|"sell"|"fee", amount, item, qty }
    cdb.skipped = cdb.skipped or {}         -- [prof] = { {name, why}, ... } recipes we can't price
    cdb.qualityPick = cdb.qualityPick or {} -- [recipe name] = quality rank you want it priced at
    cdb.plans = cdb.plans or {}             -- saved crafting plans: [name] = { [recipeID] = crafts }
    cdb.mailBought = cdb.mailBought or {}   -- bought here, waiting in the mailbox: [itemID] = { q, base, t }
    db.pcLists, cdb.pcCurrent, cdb.pcShopping = nil, nil, nil -- old shopping lists (removed)
    db.useAuctionator = nil
    cdb.matsPick = cdb.matsPick or {}       -- [recipe name] = "low" or "high": which material quality to plan with
    cdb.goldDays = cdb.goldDays or {}       -- ["YYYY-MM-DD"] = { gained, spent }: every change to your gold (All gold view)
    if db.pnlMode ~= "all" then db.pnlMode = "app" end -- Profit & loss: "app" = only ProfitCrafter's trades, "all" = all gold

    PC.db, PC.cdb = db, cdb
    -- WoW Forever: the Mostly Not Broken shared data (MNB.lua) is kept in this addon's saved variables too
    local mnb = _G.MostlyNotBroken
    if PC.FOREVER and type(mnb) == "table" and type(mnb.Attach) == "function" then
        pcall(mnb.Attach, mnb, db, "mnb")
        -- (counted among the players online with ProfitCrafter Forever: the minimap button's tooltip)
        if type(mnb.Present) == "function" then pcall(mnb.Present, mnb, PC.NAME) end
    end
end

---------------------------------------------------------------------------
-- Bag space: a plan can't need more slots than your bags have free
---------------------------------------------------------------------------
function PC:StackSize(itemID)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local stack = getInfo and select(8, getInfo(itemID))
    if type(stack) == "number" and stack > 0 then return stack end
    return 1 -- unknown yet: play it safe
end

-- Free slots a plan can use: your bags, plus the bank's free slots while you're standing at it
function PC:FreeBagSlots(bagsOnly)
    local free = self:FreeBagSlotsOnly()
    if not bagsOnly and self.Bank and self.Bank:Open() then free = free + self.Bank:FreeSlots() end
    return free
end

-- Your own bags (never the bank's): the backpack, your bag slots, and the reagent bag where the game
-- has one. On classic-style clients container 5 is the first BANK bag, so it must not count as yours.
function PC:PlayerBags()
    if self._playerBags then return self._playerBags end
    local list = {}
    local n = NUM_BAG_SLOTS or 4
    for b = 0, n do list[#list + 1] = b end
    local E = Enum and Enum.BagIndex
    local rb = E and E.ReagentBag
    if rb and rb > n and (not E.BankBag_1 or E.BankBag_1 > rb) then list[#list + 1] = rb end
    self._playerBags = list
    return list
end

function PC:IsPlayerBag(bag)
    for _, b in ipairs(self:PlayerBags()) do if b == bag then return true end end
    return false
end

-- What kind of bag sits in a bag slot: "plain", "reagent" (crafting materials only) or "special"
-- (herb, enchanting, mining... its own kind only). Read from the bag item itself, so it's right even
-- where the game doesn't flag the reagent bag (a Linen Reagent Bag in a normal bag slot).
PC._bagKind = {}
function PC:BagKind(bag)
    if bag == 0 then return "plain" end -- the backpack
    local now = GetTime and GetTime() or 0
    local c = self._bagKind[bag]
    if c and now - c.t < 2 then return c.kind end
    local kind = self:BagKindNow(bag)
    self._bagKind[bag] = { kind = kind, t = now }
    return kind
end

function PC:BagKindNow(bag)
    local reagentBag = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
    if reagentBag and bag == reagentBag then return "reagent" end
    local C = C_Container
    local inv = C and C.ContainerIDToInventoryID and C.ContainerIDToInventoryID(bag)
        or (ContainerIDToInventoryID and ContainerIDToInventoryID(bag))
    local id = inv and GetInventoryItemID and GetInventoryItemID("player", inv)
    if id then
        local info = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
        local cls, sub
        if info then local r = { info(id) }; cls, sub = r[6], r[7] end
        local name = (self:ItemName(id) or ""):lower()
        if (cls == 1 and sub == 11) or name:find("reagent bag", 1, true) then return "reagent" end
        if cls == 1 and sub and sub ~= 0 then return "special" end
    end
    local fn = (C and C.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
    local _, family = 0, 0
    if fn then _, family = fn(bag) end
    if (family or 0) ~= 0 then return "special" end
    return "plain"
end

function PC:FreeBagSlotsOnly()
    local C = C_Container
    local fn = (C and C.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
    if not fn then return 99 end
    local free = 0
    for _, bag in ipairs(self:PlayerBags()) do
        local n = fn(bag)
        -- plain bags only: never the reagent bag (materials only, so no room for anything you craft)
        -- or a profession bag
        if self:BagKind(bag) == "plain" then free = free + (n or 0) end
    end
    return free
end

-- Bag slots that qty more of an item would take, counting the room left in stacks you already have
function PC:SlotsFor(itemID, qty)
    local size = self:StackSize(itemID)
    local room = 0
    for _, s in ipairs(self.BagSlots and self:BagSlots() or {}) do
        if s.id == itemID and size > 1 then room = room + math.max(size - (s.n or 1), 0) end
    end
    local left = math.max(qty - room, 0)
    return math.ceil(left / math.max(size, 1))
end

-- How many more of an item fit in your bags right now (your bags only: the bank doesn't count)
-- Free slots this item can actually go into: plain bags, plus any special bag that takes it
-- (a reagent bag for crafting materials, a herb/enchanting/mining bag for its own kind)
function PC:FreeSlotsFor(itemID)
    local free = self:FreeBagSlotsOnly() -- plain bags (all of them count for anything)
    local C = C_Container
    local fn = (C and C.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
    if not fn then return free end
    local famFn = (C_Item and C_Item.GetItemFamily) or GetItemFamily
    local okF, itemFam = false, 0
    if famFn and itemID then okF, itemFam = pcall(famFn, itemID) end
    if not okF or type(itemFam) ~= "number" then itemFam = 0 end
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local reagent = getInfo and itemID and select(17, getInfo(itemID)) or false
    -- (where the game doesn't say: a material your recipes use counts as a crafting material)
    if not reagent and itemID and PC.Bank and PC.Bank.Allowed then reagent = PC.Bank:Allowed()[itemID] == "material" end
    for _, bag in ipairs(self:PlayerBags()) do
        local n, family = fn(bag)
        n, family = n or 0, family or 0
        local kind = self:BagKind(bag)
        if kind == "plain" then
            -- (already counted)
        elseif kind == "reagent" then
            -- the reagent bag holds crafting materials only (plain-bag count leaves it out)
            if reagent then free = free + n end
        elseif family ~= 0 and bit and bit.band and bit.band(itemFam, family) ~= 0 then
            free = free + n -- a profession bag (herbs, enchanting...) that takes this kind of item
        end
    end
    return math.max(free, 0)
end

-- Can this bag take this item? Plain bags take anything; the reagent bag only crafting materials;
-- profession bags (herbs, enchanting, mining...) only their kind. Bags the game refused this item
-- for ("That item doesn't go in that container") are remembered for the session.
PC.refusedBag = {}
function PC:CanHold(bag, itemID)
    if not itemID then return true end
    if self.refusedBag[bag .. ":" .. itemID] then return false end
    local C = C_Container
    local fn = (C and C.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
    local _, family = 0, 0
    if fn then _, family = fn(bag) end
    family = family or 0
    if self:BagKind(bag) == "reagent" then
        local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
        local reagent = getInfo and select(17, getInfo(itemID)) or false
        if not reagent and PC.Bank and PC.Bank.Allowed then reagent = PC.Bank:Allowed()[itemID] == "material" end
        return reagent and true or false
    end
    if family == 0 then return true end
    local famFn = (C_Item and C_Item.GetItemFamily) or GetItemFamily
    local ok, itemFam = false, 0
    if famFn then ok, itemFam = pcall(famFn, itemID) end
    if not ok or type(itemFam) ~= "number" then return false end
    return bit and bit.band and bit.band(itemFam, family) ~= 0 or false
end

-- A tool you craft with (Runed Copper Rod, Blacksmith Hammer...) or gather with: never sold or purged
function PC:IsTool(itemID)
    if not itemID then return false end
    if self.cdb and self.cdb.toolIDs and self.cdb.toolIDs[itemID] then return true end
    if self.Craft and self.Craft.toolIDs and self.Craft.toolIDs[itemID] then return true end
    for _, id in ipairs(self.Bank and self.Bank.KNOWN_TOOLS or {}) do if id == itemID then return true end end
    local n = (self:ItemName(itemID) or ""):lower()
    return n:find("^runed .* rod$") ~= nil or n == "blacksmith hammer" or n == "mining pick" or n == "skinning knife"
        or n == "arclight spanner" or n == "gyromatic micro-adjustor" or n:find("fishing pole", 1, true) ~= nil
end

-- reserve: empty bag slots to leave free (buying leaves one, so crafting and loot always have room)
PC.BUY_RESERVE = 1
function PC:FitsQty(itemID, qty, reserve)
    local free = math.max(self:FreeSlotsFor(itemID) - (reserve or 0), 0)
    if self:SlotsFor(itemID, qty) <= free then return qty end
    local size = self:StackSize(itemID)
    local room = 0
    for _, s in ipairs(self.BagSlots and self:BagSlots() or {}) do
        if s.id == itemID and size > 1 then room = room + math.max(size - (s.n or 1), 0) end
    end
    return math.max(math.min(qty, room + free * size), 0)
end

-- Slots a list of plan entries needs at its fullest: every material bought, nothing crafted yet,
-- plus the crafted items that don't stack over what's been used up. Counts only what you still
-- need to get (what's in your bags is already taking its slots).
function PC:PlanSlots(entries)
    local slots, tools = 0, 0
    local list = self:CombinedShoppingList(entries, 1)
    for _, it in ipairs(list) do
        if it.buy and it.buy > 0 then
            local n = math.ceil(it.buy / self:StackSize(it.id))
            if it.tool then tools = tools + n else slots = slots + n end
        end
    end
    -- (materials fill the reagent bag first: the free slots compared against leave it out)
    local inReagent = math.min(slots, self:FreeReagentBagSlots())
    -- crafted output: materials get used up as you craft, so most of its space is freed material slots;
    -- gear (stack 1) can still need more slots than its materials took
    local made, credit = 0, 0
    -- skill-ups and vendor flips: what you make can go to a vendor (or be disenchanted) as you go,
    -- so it never limits the plan; only the materials need room
    local skill = self.UI and self.UI.IsSkillPlan and self.UI:IsSkillPlan()
    for _, e in ipairs(entries) do
        if skill or e.route == "Vendor" or e.route == "Disenchant" then
            -- (no room counted for the output)
        else
        local id = e.outID or e.r.output
        local qty = math.max(e.r.qty or 1, 1) * (e.planCount or 1)
        local out = math.ceil(qty / self:StackSize(id))
        local matSlots = 0
        for _, rg in ipairs(e.r.reagents or {}) do
            local rid = self:ReagentFor(rg, e.mats)
            if rid then matSlots = matSlots + math.ceil(rg.n * (e.planCount or 1) / self:StackSize(rid)) end
        end
        made = made + math.max(out - matSlots, 0)
        credit = credit + math.min(out, matSlots)
        end
    end
    -- (materials used up from the reagent bag free no room for what's made)
    return slots - inReagent + tools + made + math.min(inReagent, credit)
end

-- Gold to plan with: your spending limit (bottom-left of the window) if you set one, never more than
-- you really have. The limit stays as you set it: plans can't grow past it (see the Crafting plan).
function PC:Gold()
    local real = GetMoney()
    local o = cdb and cdb.overrides and cdb.overrides.gold
    if o then return math.max(math.min(o, real), 0) end
    return real
end

function PC:SetSpendingLimit(copper)
    cdb.overrides.gold = copper
    cdb.overrides.spent = nil
end


---------------------------------------------------------------------------
-- Saved crafting plans (per character): cdb.plans[name] = { [recipeID] = crafts }
---------------------------------------------------------------------------
PC.DEFAULT_PLAN = "My plan"

function PC:Plans()
    local plans = cdb.plans
    -- older versions had one plan (and before that, ticked recipes)
    if cdb.plan then
        if next(cdb.plan) and not plans[self.DEFAULT_PLAN] then plans[self.DEFAULT_PLAN] = cdb.plan end
        cdb.plan = nil
    end
    if cdb.shopMulti then
        if next(cdb.shopMulti) then
            plans[self.DEFAULT_PLAN] = plans[self.DEFAULT_PLAN] or {}
            for id in pairs(cdb.shopMulti) do plans[self.DEFAULT_PLAN][id] = plans[self.DEFAULT_PLAN][id] or 1 end
        end
        cdb.shopMulti = nil
    end
    if not next(plans) then plans[self.DEFAULT_PLAN] = {} end
    return plans
end

function PC:PlanNames()
    local names = {}
    for name in pairs(self:Plans()) do names[#names + 1] = name end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

function PC:PlanName()
    local plans = self:Plans()
    local cur = cdb.planCurrent
    if not cur or not plans[cur] then
        cur = plans[self.DEFAULT_PLAN] and self.DEFAULT_PLAN or self:PlanNames()[1]
        cdb.planCurrent = cur
    end
    return cur
end

-- "34 Seasoned Wolf Kabob (makes 102)": crafts, and what they make when a craft makes more than one
function PC:CraftCount(n, r)
    local q = r and r.qty or 1
    local name = r and r.name or "?"
    if not q or q == 1 then return ("%d %s"):format(n, name) end
    local made = n * q
    return ("%d %s (makes %s%d)"):format(n, name, made % 1 == 0 and "" or "about ", math.floor(made + 0.5))
end

function PC:CurrentPlan()
    return self:Plans()[self:PlanName()]
end

function PC:SwitchPlan(name)
    if self:Plans()[name] then
        cdb.planCurrent = name
        self:ForgetStopList()
        if self.Next then self.Next.dismissed = nil end -- picking a plan starts it: the Task Button is back
        if self.Steps then self.Steps.planShown, self.Steps.planFresh = nil, true end -- and its task list rolls out
        cdb.taskCount = nil -- the "N of M done" count starts over
        if self.Guide and self.Guide.Sync then pcall(self.Guide.Sync, self.Guide) end
        self:RunPlanAgain(name, true) -- a finished saved plan comes back full
    end
end

---------------------------------------------------------------------------
-- Temporary vs saved plans. Make me gold, Have materials and Skill up are made fresh each time and
-- empty out as you craft. Plans you make are saved: crafting counts down this run, but the plan
-- itself is kept (cdb.planSaved), and once it's finished it can be run again.
---------------------------------------------------------------------------
function PC:IsTempPlan(name)
    name = name or self:PlanName() or ""
    return name == "Make me gold" or name == "Have materials" or name == "Gear upgrades" or name == "My catch"
        or name:find("^Skill up") ~= nil
end

-- A temporary plan is gone once it's finished: an empty one that isn't the plan in use goes right
-- away; the one in use goes when the Task Button has nothing left to do for it.
-- fish from Fishmonger's "Make gold from my catch" still in your bags for the "My catch" plan to sell
function PC:CatchLeft()
    local ids = cdb and cdb.catchIDs
    if not ids then return false end
    for id in pairs(ids) do
        if cdb.planCraftedPlan and cdb.planCraftedPlan[id] == "My catch" and self:BagCount(id) > 0 then return true end
    end
    return false
end

-- What the plan in use made or took on to sell is still in your bags: it isn't finished yet. (A plan
-- you closed or deleted is done: what it left behind doesn't bring it back.)
function PC:PlanGoodsLeft(name)
    if not cdb or not cdb.planCrafted then return false end
    local which = cdb.planCraftedPlan or {}
    local pn = name or self:PlanName()
    if not pn or not self:Plans()[pn] then return false end
    for id in pairs(cdb.planCrafted) do
        if which[id] == pn and self:BagCount(id) > 0 then return true end
    end
    return false
end

function PC:DropFinishedTempPlans()
    local plans = self:Plans()
    local cur = self:PlanName()
    local idle = not self.Next or self.Next.lastText == nil or self.Next.lastText == "All done!" or self.Next.lastText == "Set up a plan"
    local gone = {}
    for name, work in pairs(plans) do
        -- "My catch" (Fishmonger) stays while its fish are still in your bags to be sold
        local keep = (name == "My catch" and self:CatchLeft()) or self:PlanGoodsLeft(name)
        if self:IsTempPlan(name) and next(work) == nil and (name ~= cur or idle) and not keep then gone[#gone + 1] = name end
    end
    for _, name in ipairs(gone) do
        plans[name] = nil
        if cdb.planSaved then cdb.planSaved[name] = nil end
        if cdb.planDone then cdb.planDone[name] = nil end
        if cdb.planFin then cdb.planFin[name] = nil end
        if cdb.skipCraft then cdb.skipCraft[name] = nil end
        if name == cur then cdb.planCurrent = nil end
    end
    if #gone > 0 then self:PlanName() end -- picks another (or makes an empty "My plan")
end

-- keep each saved plan's full list in step with edits (what's left + what's been made this run)
function PC:SyncPlanTemplates()
    cdb.planSaved = cdb.planSaved or {}
    cdb.planDone = cdb.planDone or {}
    self:DropFinishedTempPlans()
    for name, work in pairs(self:Plans()) do
        if self:IsTempPlan(name) then
            cdb.planSaved[name], cdb.planDone[name] = nil, nil
        else
            cdb.planFin = cdb.planFin or {}
            if next(work) ~= nil then cdb.planFin[name] = nil
            elseif not cdb.planFin[name] then cdb.planDone[name] = nil end -- emptied by you, not by crafting it all
            local done = cdb.planDone[name] or {}
            local old = cdb.planSaved[name] or {}
            local t = {}
            for id, n in pairs(work) do if n and n > 0 then t[id] = n + (done[id] or 0) end end
            -- finished ones stay in the plan
            for id, d in pairs(done) do if not t[id] and d > 0 then t[id] = old[id] or d end end
            cdb.planSaved[name] = t
        end
    end
    for name in pairs(cdb.planSaved) do if not self:Plans()[name] then cdb.planSaved[name] = nil end end
end

function PC:PlanFinished(name)
    name = name or self:PlanName()
    if self:IsTempPlan(name) then return false end
    local t = cdb.planSaved and cdb.planSaved[name]
    return t ~= nil and next(t) ~= nil and next(self:Plans()[name] or {}) == nil and cdb.planFin ~= nil and cdb.planFin[name] == true
end

-- fill a saved plan back up from its full list (quiet = only when it's finished)
function PC:RunPlanAgain(name, quiet)
    name = name or self:PlanName()
    if self:IsTempPlan(name) then return false end
    local t = cdb.planSaved and cdb.planSaved[name]
    if not t or not next(t) then return false end
    if quiet and not self:PlanFinished(name) then return false end
    local work = self:Plans()[name]
    wipe(work)
    for id, n in pairs(t) do work[id] = n end
    cdb.planDone = cdb.planDone or {}
    cdb.planDone[name] = {}
    if cdb.planFin then cdb.planFin[name] = nil end
    Print(("Plan \"%s\" is ready to run again."):format(name))
    return true
end

-- returns false and a reason if the name can't be used
function PC:NewPlan(name)
    name = strtrim(name or "")
    if name == "" then return false, "Type a name for the plan." end
    if self.ToLearn and name:lower() == self.ToLearn.RUN:lower() then return false, "That name is for your recipe trip." end
    if self.Guide and self.Guide:On() and name:lower() == self.Guide:Name():lower() then return false, "That name is for SnuggleUp's guide." end
    for n in pairs(self:Plans()) do
        if n:lower() == name:lower() then return false, ("There's already a plan called \"%s\"."):format(n) end
    end
    self:Plans()[name] = {}
    cdb.planCurrent = name
    if self.Next then self.Next.dismissed = nil end -- a new plan: the Task Button is back
    return true
end

function PC:RenamePlan(newName)
    newName = strtrim(newName or "")
    local plans, old = self:Plans(), self:PlanName()
    if self.ToLearn and (self.ToLearn:IsRun(old) or newName:lower() == self.ToLearn.RUN:lower()) then
        return false, "The Recipe Run keeps its name (it's your recipe trip)."
    end
    if self.Guide and self.Guide:On() and (self.Guide:IsName(old) or newName:lower() == self.Guide:Name():lower()) then
        return false, "The guide keeps its name."
    end
    if newName == "" then return false, "Type a name for the plan." end
    if newName == old then return true end
    for n in pairs(plans) do
        if n ~= old and n:lower() == newName:lower() then return false, ("There's already a plan called \"%s\"."):format(n) end
    end
    plans[newName], plans[old] = plans[old], nil
    if cdb.planSaved then cdb.planSaved[newName], cdb.planSaved[old] = cdb.planSaved[old], nil end
    if cdb.planDone then cdb.planDone[newName], cdb.planDone[old] = cdb.planDone[old], nil end
    if cdb.planFin then cdb.planFin[newName], cdb.planFin[old] = cdb.planFin[old], nil end
    cdb.planCurrent = newName
    return true
end

function PC:DeletePlan()
    local plans = self:Plans()
    local name = self:PlanName()
    if self.Guide and self.Guide:IsName(name) then
        Print("The guide stays in your plans while SnuggleUp is installed: pick another plan to stop it.")
        return
    end
    -- deleting the Recipe Run empties the trip
    if self.ToLearn and self.ToLearn:IsRun(name) then
        wipe(self.ToLearn.Data().trip)
        self.ToLearn:Changed()
    end
    plans[name] = nil
    if cdb.planSaved then cdb.planSaved[name] = nil end
    if cdb.planDone then cdb.planDone[name] = nil end
    if cdb.planFin then cdb.planFin[name] = nil end
    cdb.planCurrent = nil
    self:PlanName() -- picks another (or makes an empty "My plan")
end

-- A profession's level (your real one; typed-in levels were removed with the Levels & gold tab)
function PC:ProfLevel(prof)
    return prof.rank, false
end

-- Each faction has its own Auction House economy
function PC:Faction()
    return UnitFactionGroup("player") or "Neutral"
end

function PC:Checked()
    local f = self:Faction()
    db.checked[f] = db.checked[f] or {}
    return db.checked[f]
end

-- How long ago an item's AH price was seen (seconds; nil: never). Older than OLD_PRICE: marked ~.
PC.OLD_PRICE = 6 * 3600
function PC:PriceAge(itemID)
    local t = itemID and self:Checked()[itemID]
    return t and math.max(time() - t, 0) or nil
end

function PC:Supply()
    local f = self:Faction()
    db.supply[f] = db.supply[f] or {}
    return db.supply[f]
end

function PC:History()
    local f = self:Faction()
    db.history[f] = db.history[f] or {}
    return db.history[f]
end

function PC:Prices()
    local f = self:Faction()
    db.prices[f] = db.prices[f] or {}
    return db.prices[f]
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
-- Coin icons drawn by the addon itself (doesn't rely on game helper functions)
local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

local function CoinText(copper)
    local g = math.floor(copper / 10000)
    local s = math.floor(copper / 100) % 100
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. GOLD_ICON end
    if s > 0 then parts[#parts + 1] = s .. SILVER_ICON end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. COPPER_ICON end
    return table.concat(parts, " ")
end

function PC:Money(copper, colorPositive, compact)
    if copper == nil then return "|cff888888n/a|r" end
    local neg = copper < 0
    copper = math.floor(math.abs(copper) + 0.5)
    -- always exact: gold, silver and copper, never rounded
    local text = CoinText(copper)
    if neg then return "|cffff5555-" .. text .. "|r" end
    if colorPositive and copper > 0 then return "|cff40ff40" .. text .. "|r" end
    return text
end

-- Compact money for chart labels: "12.5g", "40s", "8c"
function PC:ShortMoney(c)
    local a = math.abs(c)
    local text
    if a >= 10000 then
        text = ("%.1fg"):format(a / 10000)
    elseif a >= 100 then
        text = ("%ds"):format(math.floor(a / 100))
    else
        text = ("%dc"):format(math.floor(a))
    end
    return (c < 0 and "-" or "") .. text
end

-- "45 sec", "12 min", "3 hr 5 min", "2 days"
function PC:Ago(seconds)
    seconds = math.max(math.floor(seconds), 1)
    if seconds < 60 then return seconds .. " sec" end
    if seconds < 3600 then return math.floor(seconds / 60) .. " min" end
    if seconds < 86400 then
        return ("%d hr %d min"):format(math.floor(seconds / 3600), math.floor(seconds / 60) % 60)
    end
    local d = math.floor(seconds / 86400)
    return d .. (d == 1 and " day" or " days")
end

function PC:ItemName(itemID)
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
    if not name then
        Try(C_Item and C_Item.RequestLoadItemDataByID, itemID)
        return "Item #" .. itemID
    end
    return name
end

-- Counts what you have in your bags and bank
-- What you own: bags, bank and reagent bank
-- Use what's in your bank (Settings, on by default). Off: the bank is left alone completely: nothing in
-- it counts as yours (plans, profits, what to buy), and nothing is taken out of it or put in it.
function PC:UseBank()
    return not (db and db.useBank == false)
end

-- anyBank: count the bank even with the setting off (mail tracking must not jump when it's switched)
function PC:OwnedCount(itemID, anyBank)
    local all, bags
    if C_Item and C_Item.GetItemCount then
        all = C_Item.GetItemCount(itemID, true, false, true) or 0
        bags = C_Item.GetItemCount(itemID, false) or 0
    else
        all = GetItemCount(itemID, true) or 0
        bags = GetItemCount(itemID) or 0
    end
    all, bags = self.Num(all) or 0, self.Num(bags) or 0
    if not anyBank and not self:UseBank() then return bags end -- (your bank is left out: bags only)
    -- away from the bank the game may only count your bags (it forgets the bank after a relog):
    -- what ProfitCrafter saw in your bank on the last visit counts too
    if not (self.Bank and self.Bank.Open and self.Bank:Open()) then
        local b = cdb and cdb.bank and cdb.bank.count
        local saved = b and b[itemID]
        if saved and saved > 0 then all = math.max(all, bags + saved) end
    end
    return all
end

-- Bought from the Crafting plan and still waiting in the mailbox (AH purchases arrive by mail).
-- Counts down as the items show up in your bags; forgotten after 2 days.
function PC:MailPending(itemID)
    local m = cdb and cdb.mailBought and cdb.mailBought[itemID]
    if not m then return 0 end
    if time() - (m.t or 0) > 2 * 86400 then cdb.mailBought[itemID] = nil return 0 end
    local owned = self:OwnedCount(itemID, true)
    if owned < m.base then m.base = owned end -- used some up: arrivals count from here
    local left = m.q - (owned - m.base)
    if left <= 0 then cdb.mailBought[itemID] = nil return 0 end
    return left
end

-- The mailbox is empty: what was bought a while ago has been taken out (or used). A purchase from the
-- last hour stays: the AH's mail can take a while to arrive, and forgetting it means buying it again.
-- (as it shows up in your bags it counts down by itself)
-- Selling skipped from the Task Button: no trips to the AH to post for an hour
function PC:SellSnoozed()
    return cdb and cdb.sellSkipUntil and time() < cdb.sellSkipUntil or false
end
function PC:SnoozeSell()
    cdb.sellSkipUntil = time() + 3600
    if self.PushUndo then self:PushUndo({ kind = "sellskip" }) end
    self.Buy:Say("Selling skipped for an hour. |cff888888(/pc undo puts it back)|r")
    self:RefreshUI()
end

PC.MAIL_DELAY = 3600
function PC:MailEmptied()
    local m = cdb and cdb.mailBought
    if not m then return end
    for id, e in pairs(m) do
        if time() - (e.t or 0) > self.MAIL_DELAY then m[id] = nil
        else e.late = true end -- still counts as yours, but no trips back to an empty mailbox for it
    end
end

-- AH purchases worth a trip to the mailbox (not ones still on their way to an empty mailbox)
function PC:MailTrips()
    local n = 0
    for _, e in pairs(cdb and cdb.mailBought or {}) do if not e.late then n = n + 1 end end
    return n
end


function PC:NoteMailBought(itemID, qty)
    local m = cdb.mailBought[itemID]
    local owned = self:OwnedCount(itemID, true)
    if m then
        local left = self:MailPending(itemID)
        cdb.mailBought[itemID] = { q = left + qty, base = owned, t = time() }
    else
        cdb.mailBought[itemID] = { q = qty, base = owned, t = time() }
    end
end

-- What you have to craft with: bags, bank, reagent bank, plus purchases waiting in the mailbox, plus
-- AH purchases sent but not answered yet (so a slow answer can never get the same thing bought twice)
function PC:ItemCount(itemID)
    local flying = self.Buy and self.Buy.InFlight and self.Buy:InFlight(itemID) or 0
    return self:OwnedCount(itemID) + self:MailPending(itemID) + flying
end

local pending = {}
function PC:Debounce(key, delay, fn)
    if pending[key] then return end
    pending[key] = true
    C_Timer.After(delay, function()
        pending[key] = nil
        fn()
    end)
end

function PC:Pending(key) return pending[key] and true or false end

-- how long each part of a refresh takes (kept with the saved settings, never shown)
function PC:Timed(name, fn, ...)
    local t0 = debugprofilestop and db and debugprofilestop()
    local a, b = fn(...)
    if t0 then
        local ms = debugprofilestop() - t0
        if type(db.perf) ~= "table" or db.perf.v ~= PC.BUILD then db.perf = { v = PC.BUILD } end
        local p = db.perf[name]
        if not p then p = { n = 0, total = 0, max = 0 }; db.perf[name] = p end
        p.n, p.total, p.last = p.n + 1, p.total + ms, ms
        if ms > p.max then p.max = ms end
    end
    return a, b
end

-- A stopwatch for the parts of one piece of work: each mark(name) files the time since the last one
function PC:PerfMark(prefix)
    if not (debugprofilestop and db) then return function() end end
    local t = debugprofilestop()
    return function(name)
        local now = debugprofilestop()
        local ms = now - t
        t = now
        if type(db.perf) ~= "table" or db.perf.v ~= PC.BUILD then db.perf = { v = PC.BUILD } end
        local k = prefix .. name
        local p = db.perf[k]
        if not p then p = { n = 0, total = 0, max = 0 }; db.perf[k] = p end
        p.n, p.total, p.last = p.n + 1, p.total + ms, ms
        if ms > p.max then p.max = ms end
    end
end

-- Work worked out once and reused for the rest of a refresh (prices, bags and the plan don't change
-- in the middle of one): what each material costs, and the next task. Gone again when it ends.
-- (WoW runs Lua 5.1: no table.pack/table.unpack - a crash here once left the memo stuck, freezing the bar)
local function Finish(self, ok, ...)
    self._memo = nil
    if not ok then error((...), 0) end
    return ...
end
function PC:WithMemo(fn, ...)
    if self._memo then return fn(...) end
    self._memo = {}
    return Finish(self, pcall(fn, ...))
end
function PC:Memo() return self._memo end

-- Redraws everything: at most every half second, however many events come in (bags, gold, item info)
PC.REFRESH_GAP = 0.5
-- A short summary in chat: "Collected from the mail: ..." with any further lines under it
function PC:Note(title, lines)
    lines = lines or {}
    Print(("|cffffd100%s:|r %s"):format(title or "", lines[1] or ""))
    for i = 2, math.min(#lines, 12) do Print("  " .. lines[i]) end
end

-- Sounds: the game's own, for moments worth hearing about (Settings > General > Play sounds)
-- Each tries the voice clips first (the first one this game has plays) and falls back to a plain
-- game sound, so a clip that isn't in this version of the game just means the plain sound.
-- Goblin merchant greetings ("Time is money, friend!"): where the game may keep them
local GOBLIN = {}
for _, base in ipairs({ "GoblinMaleZanyNPC\\GoblinMaleZanyNPCVendor0%d.ogg", "GoblinMaleZanyNPC\\GoblinMaleZanyNPCGreeting0%d.ogg",
    "GoblinMaleMerchant\\GoblinMaleMerchantGreeting0%d.ogg", "GoblinMerchant\\GoblinMerchantGreeting0%d.ogg" }) do
    for n = 1, 3 do GOBLIN[#GOBLIN + 1] = "Sound\\Creature\\" .. base:format(n) end
end
-- An innkeeper's greeting ("Welcome to the inn..."): where the game may keep it
local INNKEEPER = {}
for _, who in ipairs({ "Innkeeper", "HumanFemaleInnkeeper", "HumanMaleInnkeeper", "OrcFemaleInnkeeper", "OrcMaleInnkeeper",
    "TaurenFemaleInnkeeper", "TaurenMaleInnkeeper", "DwarfMaleInnkeeper", "DwarfFemaleInnkeeper", "UndeadFemaleInnkeeper",
    "UndeadMaleInnkeeper", "TrollFemaleInnkeeper", "NightElfFemaleInnkeeper", "GnomeFemaleInnkeeper", "GoblinMaleInnkeeper" }) do
    for n = 1, 2 do INNKEEPER[#INNKEEPER + 1] = ("Sound\\Creature\\%s\\%sGreeting0%d.ogg"):format(who, who, n) end
end
PC.SOUNDS = {
    sold = { kit = "LOOTWINDOWCOINSOUND", id = 120, files = GOBLIN },  -- gold from sales: "Time is money, friend!"
    done = { kit = "LEVELUP", id = 888, files = {                    -- a plan finished: "Job's done!"
        "Sound\\Creature\\Peon\\PeonBuildingComplete1.ogg",
        "Sound\\Creature\\Peon\\PeonJobDone.ogg" } },
    start = { kit = "READY_CHECK", id = 8960, files = GOBLIN },       -- Make me gold clicked: "Time is money, friend!"
    nogold = { kit = "IG_QUEST_FAILED", id = 847, files = {          -- not enough gold
        "Sound\\Interface\\Error.ogg" } },
    warn = { kit = "RAID_WARNING", id = 8959, files = INNKEEPER },   -- no Hearthstone: an innkeeper's greeting
}
function PC:Sound(what, force)
    if db and db.sounds == false and not force then return end
    local s = self.SOUNDS[what]
    if not s then return end
    if PlaySoundFile then
        for _, f in ipairs(s.files or {}) do
            local ok, willPlay = pcall(PlaySoundFile, f, "Master")
            if ok and willPlay then return "clip" end
        end
    end
    local id = (SOUNDKIT and s.kit and SOUNDKIT[s.kit]) or s.id
    if id and PlaySound then pcall(PlaySound, id, "Master") end
    return "plain"
end

-- "Plan my route for me": directions, the arrow, the NPC star, the quickest way and learning places
function PC:RouteOn()
    return not (db and db.mapPins == false)
end

-- Busy: in the middle of a crafting batch or an AH price scan. A full refresh then (every recipe,
-- the plan, the task list, the window) froze the game for a second after every single craft and
-- every scan batch. It waits until things settle, then runs once.
PC.BUSY_MAX = 120 -- never wait longer than this for a refresh
function PC:Busy()
    if self.scanning then return true end
    if self.craftingUntil and GetTime() < self.craftingUntil then return true end
    if UnitCastingInfo then
        local ok, name, _, _, _, _, trade, _, _, spellID = pcall(UnitCastingInfo, "player")
        if ok and name and (trade or (spellID and cdb and cdb.recipes and cdb.recipes[spellID])) then
            -- (and a moment after it, while the next one of the batch starts)
            self.craftingUntil = math.max(self.craftingUntil or 0, GetTime() + 1.5)
            return true
        end
    end
    -- more of the batch still to go
    local T = C_TradeSkillUI
    if T and T.GetRemainingRecasts then
        local ok, n = pcall(T.GetRemainingRecasts)
        if ok and type(n) == "number" and n > 0 then return true end
    end
    if GetTradeskillRepeatCount then
        local ok, n = pcall(GetTradeskillRepeatCount)
        if ok and type(n) == "number" and n > 1 then return true end
    end
    return false
end
-- run fn once things aren't busy any more (or after BUSY_MAX seconds, whatever happens)
function PC:WhenIdle(key, fn)
    self.idleWait = self.idleWait or {}
    if not self:Busy() then self.idleWait[key] = nil; return fn() end
    if self.idleWait[key] and GetTime() - self.idleWait[key] > self.BUSY_MAX then
        self.idleWait[key] = nil; return fn()
    end
    self.idleWait[key] = self.idleWait[key] or GetTime()
    self:Debounce("idle:" .. key, 1, function() self:WhenIdle(key, fn) end)
end

-- Downtime: bags changing (looting, vendoring, mail, the bank) doesn't refresh right away. The work
-- waits until you're doing nothing: standing still, out of combat, not casting, no loot window, and
-- no bag change for a couple of seconds. Never longer than DOWNTIME_MAX.
PC.DOWNTIME_QUIET = 2
PC.DOWNTIME_MAX = 60
local downWait, downTicker = {}, nil
local function SecretSpeed(v) return issecretvalue and issecretvalue(v) end
function PC:Idle()
    if self:Busy() then return false end
    if (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player")) then return false end
    if GetUnitSpeed then
        local ok, speed = pcall(GetUnitSpeed, "player")
        if ok and not SecretSpeed(speed) and type(speed) == "number" and speed > 0 then return false end
    end
    if UnitCastingInfo then
        local ok, name = pcall(UnitCastingInfo, "player")
        if ok and name then return false end
    end
    if UnitChannelInfo then
        local ok, name = pcall(UnitChannelInfo, "player")
        if ok and name then return false end
    end
    if LootFrame and LootFrame.IsShown and LootFrame:IsShown() then return false end
    return GetTime() - (self.lastBagChange or 0) >= self.DOWNTIME_QUIET
end
function PC:Downtime(key, fn)
    self.lastBagChange = GetTime()
    local w = downWait[key]
    if w then w.fn = fn else downWait[key] = { fn = fn, since = GetTime() } end
    if downTicker or not (C_Timer and C_Timer.NewTicker) then return end
    downTicker = C_Timer.NewTicker(0.5, function()
        local idle = PC:Idle()
        local now = GetTime()
        for k, e in pairs(downWait) do
            if idle or now - e.since >= PC.DOWNTIME_MAX then
                downWait[k] = nil
                PC:Safe("downtime " .. k, e.fn)
            end
        end
        if not next(downWait) then downTicker:Cancel(); downTicker = nil end
    end)
end

function PC:RefreshUI(force)
    if self.inCombat then return end -- in combat: nothing is worked out and nothing is drawn
    if not force and self:Busy() then return self:WhenIdle("ui", function() self:RefreshUI(true) end) end
    local since = GetTime() - (self.lastRefresh or -100)
    local delay = math.max(0.2, self.REFRESH_GAP - since)
    self:Debounce("ui", delay, function()
        self.lastRefresh = GetTime()
        self:WithMemo(function()
            self:Timed("plans", self.Safe, self, "saved plans", self.SyncPlanTemplates, self)
            if self.UI then self:Timed("window", self.UI.Refresh, self.UI) end
            if self.Ticker then self:Timed("ticker", self.Safe, self, "price ticker", self.Ticker.Refresh, self.Ticker) end
            if self.Next and not self:Timed("button", self.Safe, self, "Task Button", self.Next.UpdateBar, self.Next) then
                -- never a blank bar: say something broke (hover it for the message)
                local b = self.Next.bar
                if b and b.btn then
                    b.btn:SetText("|cffff5555Error (hover)|r")
                    b.btn.tip = "ProfitCrafter hit an error working out the next task:\n" .. tostring(self.lastError) .. "\n/reload, and send a screenshot of this."
                end
            end
            if self.Steps then self:Timed("tasks", self.Safe, self, "plan tasks", self.Steps.Refresh, self.Steps) end
            if self.Alerts then self:Timed("alerts", self.Safe, self, "price alerts", self.Alerts.Check, self.Alerts) end
        end)
    end)
end

---------------------------------------------------------------------------
-- Professions (always available, no window needed)
---------------------------------------------------------------------------
function PC:UpdateProfessions()
    local idxs = { GetProfessions() }
    local found = {}
    for i = 1, 5 do
        local idx = idxs[i]
        if idx then
            local name, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(idx)
            if name and skillLine then
                found[skillLine] = { name = name, rank = rank or 0, max = maxRank or 0 }
            end
        end
    end

    if next(found) then
        cdb.professions = found
        -- Forget recipes from professions you've dropped
        local names = {}
        for _, p in pairs(found) do names[p.name] = true end
        -- the smelting window goes by "Smelting" on some clients: it belongs to Mining
        if names["Mining"] then names["Smelting"] = true end
        for id, r in pairs(cdb.recipes) do
            if not names[r.prof] then cdb.recipes[id] = nil end
        end
    end
    self:RefreshUI()
end

---------------------------------------------------------------------------
-- Recipes (read when you open a profession window)
---------------------------------------------------------------------------
PC.announced = {}

function PC:CacheRecipes()
    local T = C_TradeSkillUI
    if not T or not T.GetAllRecipeIDs then return end
    if T.IsTradeSkillReady and not T.IsTradeSkillReady() then return end
    -- Skip someone else's linked profession, guild lists, and NPC crafting orders
    if Try(T.IsTradeSkillLinked) or Try(T.IsTradeSkillGuild) or Try(T.IsNPCCrafting) then return end

    local base = Try(T.GetBaseProfessionInfo)
    local prof = base and base.professionName
    if not prof or prof == "" then return end

    local fresh, n, skipped = {}, 0, {}
    for _, recipeID in ipairs(T.GetAllRecipeIDs() or {}) do
        local info = T.GetRecipeInfo(recipeID)
        -- one you haven't learned: where it comes from goes on the Learn tab
        if info and info.learned == false and not info.isRecraft and not info.isDummyRecipe and PC.ToLearn then
            pcall(PC.ToLearn.NoteUnlearned, PC.ToLearn, recipeID, info, prof)
        end
        if info and info.learned and not info.isRecraft and not info.isSalvageRecipe and not info.isDummyRecipe then
            local s = T.GetRecipeSchematic(recipeID, false)
            -- Enchants (and similar) don't list an item, but the game can tell us the scroll they make
            local outputID = s and s.outputItemID
            if s and not outputID and T.GetRecipeOutputItemData then
                local ok, out = pcall(T.GetRecipeOutputItemData, recipeID)
                if ok and type(out) == "table" then
                    outputID = out.itemID
                    if not outputID and out.hyperlink then outputID = tonumber(out.hyperlink:match("item:(%d+)")) end
                end
            end
            if not s then
                skipped[#skipped + 1] = { name = info.name, why = "game didn't return the recipe details" }
            elseif not outputID then
                skipped[#skipped + 1] = { name = info.name, why = "makes no item to sell (e.g. an enchant applied directly to gear)" }
            else
                local reagents, ok = {}, true
                for _, slot in ipairs(s.reagentSlotSchematics or {}) do
                    -- Required materials only (skip optional add-ons)
                    if slot.required == true or (slot.required ~= false and slot.reagentType == BASIC_REAGENT) then
                        local first = slot.reagents and slot.reagents[1]
                        if first and first.itemID then
                            -- Every quality rank that can fill this slot; we'll buy whichever is cheapest
                            local alts = {}
                            for _, r in ipairs(slot.reagents) do
                                if r.itemID then alts[#alts + 1] = r.itemID end
                            end
                            reagents[#reagents + 1] = { id = first.itemID, n = slot.quantityRequired or 1, alts = alts }
                        else
                            ok = false
                        end
                    end
                end
                if not ok then
                    skipped[#skipped + 1] = { name = info.name, why = "a material couldn't be read" }
                elseif #reagents == 0 then
                    skipped[#skipped + 1] = { name = info.name, why = "uses no materials" }
                else
                    -- Crafted items that come in quality ranks have one item per rank; scan them all
                    local outputs
                    local qids = s.qualityItemIDs or info.qualityItemIDs
                    if type(qids) == "table" and #qids > 1 then
                        outputs = {}
                        for i, id in ipairs(qids) do outputs[i] = id end
                    end
                    local expQ
                    if outputs and T.GetCraftingOperationInfo then
                        local okOp, op = pcall(T.GetCraftingOperationInfo, recipeID, {}, nil, false)
                        local q = okOp and type(op) == "table" and (op.craftingQuality or op.quality)
                        if type(q) == "number" and q >= 1 and q <= #outputs then expQ = math.floor(q) end
                    end
                    local qmin = s.quantityMin or 1
                    local qmax = s.quantityMax or qmin
                    fresh[recipeID] = {
                        name = info.name,
                        prof = prof,
                        output = outputID,
                        outputs = outputs,            -- every quality rank of what it makes (nil = no ranks)
                        expQ = expQ,                  -- the rank your skill makes with basic materials
                        qty = (qmin + qmax) / 2,
                        reagents = reagents,
                        diff = info.relativeDifficulty,
                    }
                    n = n + 1
                end
            end
        end
    end

    if n == 0 and #skipped == 0 then return end -- list wasn't ready yet; keep what we had
    cdb.skipped[prof] = skipped
    -- when each profession was last looked at (the weekly check-in asks for any that are stale)
    cdb.profSeen = cdb.profSeen or {}
    cdb.profSeen[prof] = time()
    if prof == "Smelting" then cdb.profSeen["Mining"] = time() end


    for id, r in pairs(cdb.recipes) do
        if r.prof == prof then cdb.recipes[id] = nil end
    end
    for id, r in pairs(fresh) do cdb.recipes[id] = r end
    -- which recipes need a tool (Flint and Tinder, a runed rod...): remembered for when the window is closed
    if self.Craft and self.Craft.Tool then
        for id, r in pairs(fresh) do pcall(self.Craft.Tool, self.Craft, { id = id, r = r }) end
    end
    self._omap = nil -- outputs changed: rebuild the "which recipe makes this" map

    if self.announced[prof] ~= n then
        self.announced[prof] = n
        Print(("Learned %d %s recipes."):format(n, prof))
    end
    self.recipesRead = prof
    self:RefreshUI()
end

-- Reading every recipe is slow, so a profession is read once, and again only when what you know or
-- your skill in it has changed. Opening its window otherwise costs nothing.
function PC:ReadRecipes()
    local T = C_TradeSkillUI
    local prof, key
    if T and T.GetAllRecipeIDs and T.GetRecipeInfo then
        local base = Try(T.GetBaseProfessionInfo)
        local name = base and base.professionName
        local okN, ids = pcall(T.GetAllRecipeIDs)
        if name and name ~= "" and not SecretSpeed(name) and okN and type(ids) == "table" then
            local learned = 0
            for _, id in ipairs(ids) do
                local okI, info = pcall(T.GetRecipeInfo, id)
                if okI and info and info.learned then learned = learned + 1 end
            end
            local skill = base.skillLevel
            if SecretSpeed(skill) or type(skill) ~= "number" then skill = 0 end
            prof, key = name, learned .. ":" .. #ids .. ":" .. skill
        end
    end
    self.recipeKeys = self.recipeKeys or {}
    if prof and self.recipeKeys[prof] == key then
        -- nothing new: only note that you looked at it
        if cdb then
            cdb.profSeen = cdb.profSeen or {}
            cdb.profSeen[prof] = time()
            if prof == "Smelting" then cdb.profSeen["Mining"] = time() end
        end
        return
    end
    self.recipesRead = nil
    self:Timed("recipes", self.CacheRecipes, self)
    if prof and self.recipesRead == prof then self.recipeKeys[prof] = key end
end

---------------------------------------------------------------------------
-- Vendor prices (recorded whenever you talk to a merchant)
---------------------------------------------------------------------------
-- WoW Forever legacy perk Bartering: 5% off everything vendors sell per point (2 points max = 10%).
-- db.vendor holds the full (undiscounted) price; what you pay is that times PC:BarterMult().
-- The points are worked out at merchants from the reagents whose full price is known
-- (Empty Vial 20c showing as 18c = 2 points), or set by hand with /pc bartering 0/1/2.
do
    local tocv = GetBuildInfo and select(4, GetBuildInfo()) or 0
    PC.FOREVER = (ADDON == "ProfitCrafterForever") or (tocv >= 16000 and tocv < 20000)
end
PC.BARTER_STEP = 0.05
PC.BARTER_MAX = 2

function PC:BarterRank()
    if not self.FOREVER or not db then return 0 end
    if db.barterSet then return db.barterSet end
    -- (asked for every vendor price: worked out once per refresh)
    local memo = self._memo
    if memo and memo.barter then return memo.barter end
    local r = self:BarterRankRaw()
    if memo then memo.barter = r end
    return r
end
function PC:BarterRankRaw()
    -- a reputation discount (Honored) can make one vendor look cheaper, so the lowest recent
    -- reading across vendors is the one that's only the perk
    local best
    for _, r in pairs(db.barterSeen or {}) do
        if time() - (r.t or 0) < 14 * 86400 and (not best or r.rank < best) then best = r.rank end
    end
    return best or 0
end

function PC:BarterMult()
    return 1 - self.BARTER_STEP * self:BarterRank()
end

-- What you'd pay a vendor for one, with your perks
function PC:VendorCost(itemID)
    local v = itemID and db.vendor[itemID]
    if not v then return nil end
    return v * self:BarterMult()
end

-- Read the points from this merchant's prices of known reagents. Returns the rank, or nil if unsure.
function PC:ReadBarter(rows)
    local votes = {}
    for _, row in ipairs(rows) do
        local base = PC.KNOWN_VENDOR[row.id]
        if base and base * row.qty >= 20 then
            local full = base * row.qty
            local bestR, bestD
            for r = 0, PC.BARTER_MAX do
                local d = math.abs(row.price - full * (1 - PC.BARTER_STEP * r))
                if not bestD or d < bestD then bestR, bestD = r, d end
            end
            if bestD <= math.max(1, full * 0.01) then votes[bestR] = (votes[bestR] or 0) + 1 end
        end
    end
    local rank, n, tie = nil, 0, false
    for r, c in pairs(votes) do
        if c > n then rank, n, tie = r, c, false elseif c == n then tie = true end
    end
    if tie then return nil end
    return rank
end

function PC:CaptureVendor()
    local num = GetMerchantNumItems and GetMerchantNumItems() or 0
    local rows = {}
    for i = 1, num do
        local itemID = GetMerchantItemID(i)
        local price, qty, extended, numAvailable
        if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
            local info = C_MerchantFrame.GetItemInfo(i)
            if info then
                price, qty, extended, numAvailable = info.price, info.stackCount, info.hasExtendedCost, info.numAvailable
            end
        elseif GetMerchantItemInfo then
            local _, _, p, q, avail, _, _, ext = GetMerchantItemInfo(i)
            price, qty, extended, numAvailable = p, q, ext, avail
        end
        -- Only unlimited items bought with plain gold
        if itemID and price and price > 0 and not extended and (numAvailable == nil or numAvailable < 0) then
            rows[#rows + 1] = { id = itemID, price = price, qty = math.max(qty or 1, 1) }
        end
    end
    if self.FOREVER then
        local before = self:BarterRank()
        local rank = self:ReadBarter(rows)
        if rank then
            local key = (UnitGUID and UnitGUID("npc")) or (UnitName and UnitName("npc")) or "?"
            key = tostring(key):gsub("%-%x+$", "") -- same NPC, any spawn
            db.barterSeen = db.barterSeen or {}
            db.barterSeen[key] = { rank = rank, t = time() }
        end
        -- prices saved before this version were what you paid (already discounted): turn them into
        -- full prices once, the first time the points are known
        if not db.vendorFull and (rank or db.barterSet) then
            local m = self:BarterMult()
            for id, v in pairs(db.vendor) do
                if PC.KNOWN_VENDOR[id] ~= v then db.vendor[id] = v / m end
            end
            db.vendorFull = true
        end
        local after = self:BarterRank()
        if after ~= before or (rank and not db.barterTold) then
            db.barterTold = true
            Print(("Bartering: %d point%s, vendors charge you %d%% less."):format(after, after == 1 and "" or "s", after * 5))
        end
    end
    local m = self:BarterMult()
    for _, row in ipairs(rows) do
        db.vendor[row.id] = row.price / row.qty / m
    end
    self:RefreshUI()
end

---------------------------------------------------------------------------
-- Auction House scan
---------------------------------------------------------------------------
function PC:ScanWait()
    return math.max(0, self.SCAN_COOLDOWN - (time() - db.lastScanStart))
end

-- Shared start-of-scan setup: flags, window, and the progress bar animation
-- Run one scan step; if it errors, report it and end the scan so it can't get stuck
function PC:ScanStep(fn, ...)
    local ok = self:Safe("scan", fn, self, ...)
    if not ok and self.scanning then
        self:EndScan(false, "Scan stopped because of an error (see the red message above).",
            "Scan stopped: something went wrong. See chat.")
    end
end

PC.SCAN_STALL = 45 -- seconds with no progress before a scan gives up

function PC:BeginScan(mode, auto)
    self.scanning = true
    self.scanMode = mode
    self.progress = nil
    self.scanStartedAt = GetTime()
    self.lastProgressAt = GetTime()
    -- Show the window for the progress bar, unless this is the automatic scan and you turned auto-open off
    if self.UI and not (auto and db.openOnAH == false) then self.UI:Show() end
    if self.UI and self.UI.f and self.UI.f.scanBtn then self.UI.f.scanBtn:SetEnabled(false) end
    self:RefreshUI()

    if self.ticker then self.ticker:Cancel() end
    self.ticker = C_Timer.NewTicker(0.1, function()
        if not self.scanning then
            if self.ticker then self.ticker:Cancel() end
            self.ticker = nil
        elseif (self.scanMode == "quick" or self.scanMode == "depth") and GetTime() - (self.lastProgressAt or GetTime()) > self.SCAN_STALL then
            self:EndScan(false, "The scan stopped getting answers from the Auction House. Prices found so far were kept; try Scan auctions again.",
                "Scan stopped: the Auction House stopped answering. Try again.")
        end
        if self.UI then self.UI:UpdateBar() end
    end)
end

function PC:EndScan(ok, chatMsg, barMsg)
    -- After a good quick scan, read the live listings for your materials before finishing
    if ok and self.scanMode == "quick" and self.Depth and self.Depth:ShouldRun() then
        local ids = self.Depth:ScanIDs()
        if #ids > 0 then
            self.quick = nil
            self.scanMode = "depth"
            self.progress = 0
            self.lastProgressAt = GetTime()
            self.Depth:Run(ids, function()
                if self.scanMode == "depth" then
                    self:EndScan(true, chatMsg .. (" Live listings read for %d materials."):format(#ids), barMsg)
                end
            end)
            return
        end
    end
    if self.scanMode == "depth" and self.Depth then
        local depth = self.Depth
        self.scanMode = nil
        if depth.busy or #depth.queue > 0 then depth.done = nil; depth:Stop() end
    end
    self.scanning, self.processing = false, false
    self.scanMode = nil
    self.quick = nil
    if ok then db.scanTime[self:Faction()] = time() end
    Print(chatMsg)
    if ok then
        local n = self:ReportAlerts()
        if n > 0 then barMsg = barMsg .. (" %d tip%s in chat."):format(n, n == 1 and "" or "s") end
    end
    if self.UI then self.UI:ScanFinished(ok, barMsg) end
    if ok and self.Share then
        C_Timer.After(2, function() self.Share:Broadcast("scan") end)
    end
    self:RefreshUI()
end

-- Default scan: only the items your recipes make and the materials they use
function PC:StartScan(auto)
    if not self.ahOpen then
        Print("Open the Auction House first.")
        return
    end
    if self.scanning then return end
    if not (C_AuctionHouse and C_AuctionHouse.SearchForItemKeys and C_AuctionHouse.MakeItemKey) then
        Print("Quick scan isn't supported in this game version. Using a full scan instead.")
        return self:StartFullScan()
    end

    local set, items = {}, {}
    local function add(id)
        if id and not set[id] then
            set[id] = true
            items[#items + 1] = id
        end
    end
    for _, r in pairs(self:ShownRecipes()) do
        for _, id in ipairs(self:OutputIDs(r)) do add(id) end
        for _, rg in ipairs(r.reagents) do
            for _, id in ipairs(self:ReagentIDs(rg)) do add(id) end
        end
    end
    -- and what the recipes you can learn now or soon (Scout recipes) make and use: else their AH Profit
    -- went by whatever an old scan saw
    local known, scout = #items, 0
    if known > 0 and self.ToLearn then
        local okL, list = pcall(self.ToLearn.List, self.ToLearn)
        for _, e in ipairs(okL and list or {}) do
            if (e.status == "now" or e.status == "soon") and e.output then
                add(e.output)
                for _, rg in ipairs(e.reagents or {}) do
                    for _, id in ipairs(self:ReagentIDs(rg)) do add(id) end
                end
            end
        end
        scout = #items - known
    end
    if #items == 0 and next(cdb.recipes) then
        Print("All your recipes are from expansions you turned off. Pick expansions in /pc config.")
        return
    end
    if #items == 0 then
        Print("No recipes learned yet. Open each of your profession windows once, then scan.")
        return
    end

    self:SnapshotProfitable()
    self.quick = { items = items, pos = 0, found = 0, missed = 0 }
    self:BeginScan("quick", auto)
    self.progress = 0
    Print(("Scanning prices for %d items from your recipes%s..."):format(#items,
        scout > 0 and (" (%d for recipes you can learn)"):format(scout) or ""))
    self:ScanStep(self.QuickNextBatch)
end

function PC:QuickNextBatch()
    local q = self.quick
    if not q then return end
    if q.pos >= #q.items then
        local missed = ""
        if q.missed > 0 then
            missed = (" %d got no reply from the Auction House (shown as \"Not scanned\" in /pc items)."):format(q.missed)
        end
        return self:EndScan(true,
            ("Scan complete: %d of %d items are for sale.%s"):format(q.found, #q.items, missed),
            ("Scan complete! %d of %d items priced."):format(q.found, #q.items))
    end
    -- Blizzard spaces out AH searches; wait until it says we can send the next one
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        q.waitingThrottle = true
        C_Timer.After(1, function() -- backup in case the "ready" event doesn't fire
            if self.quick == q and q.waitingThrottle then self:ScanStep(self.QuickNextBatch) end
        end)
        return
    end
    q.waitingThrottle = false

    local keys, batch = {}, {}
    for i = q.pos + 1, math.min(q.pos + self.QUICK_BATCH, #q.items) do
        local id = q.items[i]
        batch[#batch + 1] = id
        keys[#keys + 1] = C_AuctionHouse.MakeItemKey(id)
    end
    q.batch = batch
    q.pages = 0
    q.pos = q.pos + #batch

    local sorts = {}
    if Enum and Enum.AuctionHouseSortOrder then
        sorts[1] = { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false }
    end
    C_AuctionHouse.SearchForItemKeys(keys, sorts)

    -- If the results never arrive, move on after 10 seconds
    local sentPos = q.pos
    C_Timer.After(15, function()
        if self.quick == q and q.batch and q.pos == sentPos then self:ScanStep(self.QuickBatchDone, true) end
    end)
end

-- Called when a batch's results have arrived (or timed out)
function PC:QuickResultsArrived()
    local q = self.quick
    if not q or not q.batch then return end
    -- Long result lists come in pages: ask for the rest before reading them
    if C_AuctionHouse.HasFullBrowseResults and not C_AuctionHouse.HasFullBrowseResults()
        and C_AuctionHouse.RequestMoreBrowseResults and q.pages < 10 then
        q.pages = q.pages + 1
        C_AuctionHouse.RequestMoreBrowseResults()
        return
    end
    self:QuickBatchDone(false)
end

function PC:QuickBatchDone(timedOut)
    local q = self.quick
    if not q or not q.batch then return end

    -- These results must be for OUR search. When you open the AH, the game runs its own search
    -- (like your favorites list); if those results show up instead, ignore them and search again.
    local inBatch = {}
    for _, id in ipairs(q.batch) do inBatch[id] = true end
    local foreign = false
    for _, res in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
        local id = res.itemKey and res.itemKey.itemID
        if id and not inBatch[id] then foreign = true break end
    end
    if foreign and not timedOut then
        q.retries = (q.retries or 0) + 1
        if q.retries <= 3 then
            q.pos = q.pos - #q.batch
            q.batch = nil
            C_Timer.After(1.5, function()
                if self.quick == q then self:ScanStep(self.QuickNextBatch) end
            end)
            return
        end
        timedOut = true -- the AH keeps showing other results: keep old prices for this batch
    end
    q.retries = 0
    self.lastProgressAt = GetTime()

    local got, qty = {}, {}
    for _, res in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
        local id = res.itemKey and res.itemKey.itemID
        if id and inBatch[id] and res.minPrice and res.minPrice > 0 then
            if not got[id] or res.minPrice < got[id] then got[id] = res.minPrice end
            qty[id] = (qty[id] or 0) + (res.totalQuantity or 0)
        end
    end

    local prices, checked, supply, now = self:Prices(), self:Checked(), self:Supply(), time()
    for _, id in ipairs(q.batch) do
        if got[id] then
            prices[id] = got[id]
            supply[id] = qty[id]
            checked[id] = now
            self:Source()[id] = nil
            self:AddSupplyPoint(id, qty[id] or 0, now)
            self:AddHistory(id, got[id])
            self:DepthScanned(id, got[id], qty[id])
            q.found = q.found + 1
        elseif timedOut then
            q.missed = q.missed + 1 -- no answer: keep the old price, don't mark as checked
        else
            prices[id] = nil -- nobody is selling it right now
            supply[id] = 0
            checked[id] = now
            self:Source()[id] = nil
            self:AddSupplyPoint(id, 0, now)
            self:DepthScanned(id, nil, 0)
        end
    end
    q.batch = nil
    self.progress = q.pos / #q.items
    self:RefreshUI()

    C_Timer.After(0.2, function()
        if self.quick == q then self:ScanStep(self.QuickNextBatch) end
    end)
end

-- Full scan: downloads every auction (once per 15 minutes)
function PC:StartFullScan()
    if not self.ahOpen then
        Print("Open the Auction House first.")
        return
    end
    if not (C_AuctionHouse and C_AuctionHouse.ReplicateItems) then
        Print("This game version doesn't support a full Auction House scan.")
        return
    end
    if self.scanning then return end
    local wait = self:ScanWait()
    if wait > 0 then
        Print(("Blizzard allows one full scan every 15 minutes. Try again in %d:%02d, or use the normal Scan auctions button."):format(math.floor(wait / 60), wait % 60))
        return
    end

    db.lastScanStart = time()
    self:SnapshotProfitable()
    self:BeginScan("full")
    Print("Full scan started. Waiting for the Auction House to send data (the game may pause for a few seconds)...")
    C_AuctionHouse.ReplicateItems()

    C_Timer.After(90, function()
        if self.scanning and self.scanMode == "full" and not self.processing then
            self:EndScan(false, "The full scan didn't come back. Try again in 15 minutes.",
                "Scan failed: no data came back. Try again in 15 minutes.")
        end
    end)
end

-- The full scan lists every auction with a price and a count. Depending on the item, that price can
-- be for the whole auction or already for one item. The right reading is the one where the same item
-- costs about the same per item across all its auctions, so pick whichever spreads less.
local function LogSpread(values)
    local n, sum, sq = 0, 0, 0
    for _, v in ipairs(values) do
        local l = math.log(v)
        n, sum, sq = n + 1, sum + l, sq + l * l
    end
    if n < 2 then return 0 end
    local mean = sum / n
    return sq / n - mean * mean
end

function PC:FullScanUnitPrice(s)
    local multi = false
    for _, e in ipairs(s) do if e.c > 1 then multi = true break end end
    if not multi then return s.minRaw end -- every auction is a single item: both readings agree

    local each, raw = {}, {}
    for _, e in ipairs(s) do
        each[#each + 1] = e.b / e.c
        raw[#raw + 1] = e.b
    end
    if LogSpread(raw) < LogSpread(each) then
        return s.minRaw   -- the price was already per item
    end
    return s.minEach      -- the price was for the whole auction
end

function PC:ProcessScan()
    if not self.scanning or self.scanMode ~= "full" or self.processing then return end
    self.processing = true

    local total = C_AuctionHouse.GetNumReplicateItems() or 0
    local prices, qty, i = {}, {}, 0
    local samples = {} -- [itemID] = { {b = buyout, c = count}, ... } to work out how the game reports the price
    self.progress = 0
    Print(("Data received. Reading %d auctions..."):format(total))

    local function chunk()
        local stop = math.min(i + 2000, total)
        for j = i, stop - 1 do
            local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(j)
            if itemID and buyout and buyout > 0 and count and count > 0 then
                local s = samples[itemID]
                if not s then s = {}; samples[itemID] = s end
                if #s < 60 then s[#s + 1] = { b = buyout, c = count } end
                s.minEach = math.min(s.minEach or math.huge, buyout / count) -- if the price is for the whole auction
                s.minRaw = math.min(s.minRaw or math.huge, buyout)           -- if the price is already per item
                qty[itemID] = (qty[itemID] or 0) + count
            end
        end
        i = stop
        self.progress = (total > 0) and (i / total) or 1
        if i < total then
            C_Timer.After(0, chunk) -- spread the work over frames so the game doesn't freeze
        else
            for id, s in pairs(samples) do prices[id] = self:FullScanUnitPrice(s) end
            db.prices[self:Faction()] = prices
            db.supply[self:Faction()] = qty
            for id in pairs(self:DepthTable()) do self:DepthScanned(id, prices[id], qty[id]) end
            db.source[self:Faction()] = {}  -- everything is now from your own scan
            local checked, now = self:Checked(), time()
            local function mark(id)
                checked[id] = now
                if prices[id] then self:AddHistory(id, prices[id]) end
                self:AddSupplyPoint(id, qty[id] or 0, now)
            end
            for _, r in pairs(cdb.recipes) do
                for _, id in ipairs(self:OutputIDs(r)) do mark(id) end
                for _, rg in ipairs(r.reagents) do
                    for _, id in ipairs(self:ReagentIDs(rg)) do mark(id) end
                end
            end
            local n = 0
            for _ in pairs(prices) do n = n + 1 end
            self:EndScan(true,
                ("Full scan complete: %d auctions, %d different items priced."):format(total, n),
                ("Scan complete! %d items priced."):format(n))
        end
    end
    chunk()
end

---------------------------------------------------------------------------
-- Profit & loss tracking (Auction House buys, sales and posting fees)
---------------------------------------------------------------------------
PC.MAX_LEDGER = 10000

---------------------------------------------------------------------------
-- What things really cost you (per character):
--   cdb.paid[itemID] = { n, total }  materials you bought (AH invoices, vendor buys)
--   cdb.made[itemID] = { n, total }  things you crafted, at what their materials cost you then
-- so a sale is judged against what you paid, not against today's prices.
---------------------------------------------------------------------------
local function Pool(t, id) t[id] = t[id] or { n = 0, total = 0 }; return t[id] end

function PC:NotePaid(itemID, qty, total)
    if not itemID or not qty or qty <= 0 or not total or total <= 0 or not cdb then return end
    cdb.paid = cdb.paid or {}
    local p = Pool(cdb.paid, itemID)
    -- the pool never holds more than you own (what was used or sold before isn't counted twice)
    local own = self.ItemCount and self:ItemCount(itemID) or p.n
    if p.n > own then p.total = p.n > 0 and p.total * own / p.n or 0; p.n = own end
    p.n, p.total = p.n + qty, p.total + total
end

-- What one of these really cost you; nil when ProfitCrafter never saw you buy or make it
function PC:PaidEach(itemID)
    local p = cdb and cdb.paid and cdb.paid[itemID]
    if p and p.n > 0 then return p.total / p.n end
end

function PC:MadeEach(itemID)
    local m = cdb and cdb.made and cdb.made[itemID]
    if m and m.n > 0 then return m.total / m.n end
end

-- A craft finished: its materials leave the paid pools and the result joins the made pool at that cost
function PC:NoteCrafted(r)
    if not r or not cdb then return end
    cdb.paid, cdb.made = cdb.paid or {}, cdb.made or {}
    local cost = 0
    for _, rg in ipairs(r.reagents or {}) do
        local need = rg.n or 1
        local each
        for _, id in ipairs(self:ReagentIDs(rg)) do
            local p = cdb.paid[id]
            if p and p.n > 0 then
                each = p.total / p.n
                local use = math.min(need, p.n)
                p.n, p.total = p.n - use, math.max(p.total - each * use, 0)
                break
            end
        end
        each = each or select(2, self:BestReagent(rg)) or 0
        cost = cost + each * need
    end
    local out = r.output
    local qty = math.max(r.qty or 1, 1)
    -- everything you've crafted is remembered (a finished item to sell later, whatever plan it was for)
    if out then cdb.madeIDs = cdb.madeIDs or {}; cdb.madeIDs[out] = true end
    if out and cost > 0 then
        local m = Pool(cdb.made, out)
        local own = self:ItemCount(out)
        if m.n > own then m.total = m.n > 0 and m.total * own / m.n or 0; m.n = own end
        m.n, m.total = m.n + qty, m.total + cost
    end
    -- made to be disenchanted (its route, or a green made for an enchant's dust): queue it
    if out and self.Synergy and self.UI then
        local forDE = false
        for _, e in ipairs(self.UI:PlanEntries()) do
            if (e.outID or e.r.output) == out and e.route == "Disenchant" then forDE = true end
        end
        if not forDE then
            local ok, list = pcall(self.CombinedShoppingList, self, self.UI:PlanEntries(), 1)
            for _, it in ipairs(ok and list or {}) do
                if it.craft and it.craft.disenchant and it.craft.r and it.craft.r.output == out then forDE = true end
            end
        end
        if forDE then self.Synergy:Queue(out, qty) end
    end
end

function PC:Record(kind, amount, item, qty)
    if not amount or amount <= 0 then return end
    local L = cdb.ledger
    L[#L + 1] = { t = time(), kind = kind, amount = math.floor(amount + 0.5), item = item, qty = qty }
    while #L > self.MAX_LEDGER do table.remove(L, 1) end
    self.ledgerVersion = (self.ledgerVersion or 0) + 1
    self:RefreshUI()
end

-- Mail from the Auction House carries an "invoice" saying what was bought or sold
local seenMail = {}
local function HandleMail(index, what)
    if not GetInboxInvoiceInfo or not GetInboxHeaderInfo then return end
    local invoiceType, itemName, _, bid, _, _, _, _, _, _, count = GetInboxInvoiceInfo(index)
    if invoiceType ~= "seller" and invoiceType ~= "buyer" then return end
    local _, _, _, _, money, _, daysLeft = GetInboxHeaderInfo(index)
    local key = table.concat({ invoiceType, tostring(itemName), tostring(bid), tostring(daysLeft) }, "|")
    if seenMail[key] then return end

    if invoiceType == "seller" and (what == "money" or what == "auto") and money and money > 0 then
        -- Gold received (sale price minus the AH cut, plus your deposit back)
        seenMail[key] = true
        -- (a sale the game already announced was counted then: only what it didn't cover is new)
        local counted = PC.TakeSoldNow and PC:TakeSoldNow(itemName)
        PC:Record("sell", money, itemName, count)
        local more = (count or 1) - (counted or 0)
        if more > 0 and PC.Posted then PC.Posted:RemoveByName(itemName, more) end
        if more > 0 and PC.Learn then PC.Learn:Sold(PC:ItemIDByName(itemName), more) end
    elseif invoiceType == "buyer" and (what == "item" or what == "auto") and bid and bid > 0 then
        seenMail[key] = true
        PC:Record("buy", bid, itemName, count)
        PC:NotePaid(PC:ItemIDByName(itemName), count or 1, bid)
    end
end

local pendingPost
function PC:SetupTradeTracking()
    if self.tradeHooks then return end
    self.tradeHooks = true

    if TakeInboxMoney then hooksecurefunc("TakeInboxMoney", function(i) HandleMail(i, "money") end) end
    if TakeInboxItem then hooksecurefunc("TakeInboxItem", function(i) HandleMail(i, "item") end) end
    if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", function(i) HandleMail(i, "auto") end) end

    -- Posting an auction costs a deposit; note our gold so the next drop can be recorded as a fee
    local AH = C_AuctionHouse
    if AH then
        local function OnPost(itemLocation)
            local name
            if itemLocation and C_Item and C_Item.GetItemName then
                local ok, n = pcall(C_Item.GetItemName, itemLocation)
                if ok then name = n end
            end
            pendingPost = { money = GetMoney(), at = GetTime(), item = name }
        end
        if AH.PostItem then hooksecurefunc(AH, "PostItem", OnPost) end
        if AH.PostCommodity then hooksecurefunc(AH, "PostCommodity", OnPost) end
    end
end

function PC:CheckPostingFee()
    if not pendingPost then return end
    if GetTime() - pendingPost.at > 10 then
        pendingPost = nil
        return
    end
    local paid = pendingPost.money - GetMoney()
    if paid > 0 then
        self:Record("fee", paid, pendingPost.item or "Auction deposit", nil)
        pendingPost = nil
    end
end

-- Totals for the last N days (0 = all time)
---------------------------------------------------------------------------
-- All gold: every rise and drop of your gold, per day (quests, loot, repairs, mail, AH, vendors...)
---------------------------------------------------------------------------
function PC:TrackGold()
    local now = GetMoney and GetMoney()
    if not now or not cdb then return end
    local last = cdb.goldLast
    cdb.goldLast = now
    if not last or not self.goldReady then return end -- first reading after login is the starting point
    local d = now - last
    if d == 0 then return end
    local key = date("%Y-%m-%d")
    local day = cdb.goldDays[key] or { 0, 0 }
    cdb.goldDays[key] = day
    if d > 0 then day[1] = day[1] + d else day[2] = day[2] - d end
    -- every change, with where you were (vendor, AH, mailbox, flight master, trainer...): so any
    -- gold that goes missing can be traced to the minute (the last 300 changes)
    cdb.goldLog = cdb.goldLog or {}
    local function shown(n) local f = _G[n]; return f and f.IsShown and f:IsShown() end
    local where = (self.merchantOpen and ("vendor " .. (UnitName and UnitName("npc") or "")))
        or (self.ahOpen and "AH") or ((self.Mail and self.Mail.Open and self.Mail:Open()) and "mailbox")
        or (shown("TaxiFrame") and "flight master") or (shown("ClassTrainerFrame") and "trainer")
        or (UnitOnTaxi and UnitOnTaxi("player") and "flying") or (self.Bank and self.Bank.open and "bank") or "elsewhere"
    table.insert(cdb.goldLog, { t = time(), d = d, at = where, gold = now })
    while #cdb.goldLog > 300 do table.remove(cdb.goldLog, 1) end
    -- keep a year of days
    local cutoff = date("%Y-%m-%d", time() - 366 * 86400)
    for k in pairs(cdb.goldDays) do if k < cutoff then cdb.goldDays[k] = nil end end
end

-- When All gold tracking started (oldest day recorded), nil if nothing yet
function PC:GoldSince()
    local first
    for k in pairs(cdb.goldDays) do if not first or k < first then first = k end end
    return first
end

-- Gold gained and spent in the last `days` days (0 = all time)
function PC:GoldTotals(days)
    local cutoff = (days and days > 0) and date("%Y-%m-%d", time() - (days - 1) * 86400) or ""
    local gained, spent = 0, 0
    for k, v in pairs(cdb.goldDays) do
        if k >= cutoff then gained, spent = gained + v[1], spent + v[2] end
    end
    return gained, spent, gained - spent
end

function PC:PnLTotals(days)
    local since = (days and days > 0) and (time() - days * 86400) or 0
    local sold, bought, fees = 0, 0, 0
    for _, e in ipairs(cdb.ledger) do
        if e.t >= since then
            if e.kind == "sell" or e.kind == "vendor" then sold = sold + e.amount
            elseif e.kind == "buy" then bought = bought + e.amount
            else fees = fees + e.amount end
        end
    end
    return sold, bought, fees, sold - bought - fees
end

---------------------------------------------------------------------------
-- Vendor sales: while a merchant is open, items that leave your bags at the same
-- time your gold goes up by their vendor price were sold. Works for right-click,
-- drag-and-drop and the "Sell junk" button. Buying an item back undoes the sale.
---------------------------------------------------------------------------
function PC:BagCounts()
    local counts = {}
    local C = C_Container
    local numSlots = (C and C.GetContainerNumSlots) or GetContainerNumSlots
    if not numSlots then return counts end
    for _, bag in ipairs(self:PlayerBags()) do -- backpack, bags, reagent bag (never a bank bag)
        for slot = 1, (numSlots(bag) or 0) do
            local id, n
            if C and C.GetContainerItemInfo then
                local info = C.GetContainerItemInfo(bag, slot)
                if info then id, n = info.itemID, info.stackCount end
            elseif GetContainerItemInfo then
                local _, cnt, _, _, _, _, _, _, _, itemID = GetContainerItemInfo(bag, slot)
                id, n = itemID, cnt
            end
            if id then counts[id] = (counts[id] or 0) + (n or 1) end
        end
    end
    return counts
end

function PC:VendorOpen()
    self.vendorVisit = { bags = self:BagCounts(), money = GetMoney(), gain = 0, spent = 0, sold = {} }
end

function PC:VendorMoney()
    local v = self.vendorVisit
    if not v then return end
    local now = GetMoney()
    local d = now - v.money
    v.money = now
    if d > 0 then v.gain, v.gainAt = v.gain + d, GetTime() elseif d < 0 then v.spent = v.spent - d end
    self:VendorSoon()
end

function PC:VendorSoon()
    if self.vendorTimer then return end
    self.vendorTimer = true
    C_Timer.After(0.4, function()
        self.vendorTimer = nil
        self:Safe("vendor sales", self.VendorCheck, self)
    end)
end

function PC:VendorCheck()
    local v = self.vendorVisit
    if not v then return end
    local now = self:BagCounts()
    local changed = false

    -- Items that left your bags, if your gold went up by what a vendor pays for them.
    -- The gold and the bag change can arrive in either order, so wait a few seconds for the other half.
    local t = GetTime()
    if v.gain > 0 and v.gainAt and t - v.gainAt > 5 then v.gain = 0 end -- gold from something else
    local gone = {}
    for id, n in pairs(v.bags) do
        local lost = n - (now[id] or 0)
        local each = self:SellPrice(id)
        if lost > 0 and each and each > 0 then gone[#gone + 1] = { id = id, n = lost, value = each * lost } end
    end
    local keepOld = false
    if v.gain > 0 and #gone == 1 then
        -- one kind of item went and gold came in: that IS what the vendor pays (record it as it was)
        local g = gone[1]
        local each = math.floor(v.gain / g.n + 0.5)
        if each > 0 then
            db.vendorPaid = db.vendorPaid or {}
            db.vendorPaid[g.id] = each
            g.value = v.gain
        end
    end
    if v.gain > 0 and #gone > 0 then
        table.sort(gone, function(a, b) return a.value > b.value end)
        for _, g in ipairs(gone) do
            if g.value <= v.gain + 1 then
                v.gain = math.max(0, v.gain - g.value)
                self:Record("vendor", g.value, self:ItemName(g.id), g.n)
                if self.Activity then self:Activity("Sold to a vendor", g.id, g.n, g.value) end
                v.sold[g.id] = (v.sold[g.id] or 0) + g.n
                changed = true
            end
        end
        v.gain, v.lossAt = 0, nil
    elseif #gone > 0 then
        -- items left but no gold yet: keep the old bag list a moment in case the gold is on its way
        v.lossAt = v.lossAt or t
        if t - v.lossAt < 3 then keepOld = true; C_Timer.After(1, function() self:VendorSoon() end)
        else v.lossAt = nil end -- used, destroyed or mailed, not sold
    end

    -- Buyback: an item you sold this visit came back and your gold went down
    if v.spent > 0 then
        for id, soldN in pairs(v.sold) do
            local back = (now[id] or 0) - (v.bags[id] or 0)
            if back > 0 then
                local name, n = self:ItemName(id), math.min(back, soldN)
                local L = cdb.ledger
                for i = #L, 1, -1 do
                    if n <= 0 then break end
                    local e = L[i]
                    if e.kind == "vendor" and e.item == name then
                        local q = e.qty or 1
                        if q <= n then table.remove(L, i); n = n - q
                        else e.amount = math.floor(e.amount * (q - n) / q + 0.5); e.qty = q - n; n = 0 end
                    end
                end
                v.sold[id] = soldN - math.min(back, soldN)
                changed = true
            end
        end
        v.spent = 0
    end

    if not keepOld then v.bags = now end
    if changed then self:RefreshUI() end
end

---------------------------------------------------------------------------
-- Sales estimates: how many sold, worked out from how the listed count drops between scans
---------------------------------------------------------------------------
PC.SALES_KEEP = 5 * 86400     -- keep 5 days of listing counts
PC.SALES_GAP = 5 * 60         -- scans closer than 5 minutes update the last point instead of adding one
PC.SALES_WINDOWS = {
    { 3600, "Last hour" }, { 12 * 3600, "Last 12 hours" }, { 86400, "Last 24 hours" }, { 5 * 86400, "Last 5 days" },
}

function PC:SupplyHistory()
    local f = self:Faction()
    db.supplyHist[f] = db.supplyHist[f] or {}
    return db.supplyHist[f]
end

function PC:AddSupplyPoint(itemID, qty, t)
    if not itemID or not qty then return end
    t = t or time()
    local h = self:SupplyHistory()
    local list = h[itemID]
    if not list then list = {}; h[itemID] = list end
    local last = list[#list]
    if last and t < last.t then return end -- older than what we have; ignore
    if last and qty < last.q then self:NoteSold(itemID, t) end -- fewer listed than last time: some sold
    if last and t - last.t < self.SALES_GAP then
        last.q, last.t = qty, t
    else
        list[#list + 1] = { t = t, q = qty }
    end
    local cutoff = time() - self.SALES_KEEP
    while list[1] and list[1].t < cutoff and list[2] and list[2].t < cutoff do table.remove(list, 1) end
end

function PC:LastSoldTable()
    local f = self:Faction()
    db.lastSold[f] = db.lastSold[f] or {}
    return db.lastSold[f]
end

function PC:NoteSold(itemID, t)
    local ls = self:LastSoldTable()
    if not ls[itemID] or t > ls[itemID] then ls[itemID] = t end
end

-- Your own AH sales by item name, from the Profit & loss ledger: [name] = { last = t, list = { {t, qty}, ... } }
-- (oldest first). Built once and reused until the ledger changes: every recipe used to read the whole
-- ledger twice per refresh, which got slower the longer you played.
function PC:SellIndex()
    local memo = self._memo
    if memo and memo.sellIdx then return memo.sellIdx end
    local L = cdb and cdb.ledger or {}
    local first, last = L[1], L[#L]
    local key = #L .. ":" .. tostring(first and first.t) .. ":" .. tostring(last and last.t) .. ":" .. tostring(last and last.qty)
        .. ":" .. tostring(self.ledgerVersion or 0)
    if self._sellIdxKey ~= key then
        local idx = {}
        for _, e in ipairs(L) do
            if e.kind == "sell" and e.item and e.t then
                local s = idx[e.item]
                if not s then s = { last = e.t, list = {} }; idx[e.item] = s end
                if e.t > s.last then s.last = e.t end
                s.list[#s.list + 1] = { e.t, e.qty or 1 }
            end
        end
        self._sellIdx, self._sellIdxKey = idx, key
    end
    if memo then memo.sellIdx = self._sellIdx end
    return self._sellIdx
end

-- When this item last sold (seen dropping on the AH, or one of your own sales); nil = not known
function PC:LastSold(itemID)
    if not itemID then return nil end
    local best, mine = self:LastSoldTable()[itemID], false
    -- older saves: look back through the listing history too
    local list = self:SupplyHistory()[itemID]
    if list then
        for i = 2, #list do
            if list[i].q < list[i - 1].q and (not best or list[i].t > best) then best = list[i].t end
        end
    end
    local name = self:ItemName(itemID)
    local s = name and self:SellIndex()[name]
    if s and (not best or s.last >= best) then best, mine = s.last, true end
    return best, mine
end

-- Seconds since local midnight
function PC:SecondsToday()
    local d = date("*t")
    if type(d) ~= "table" then return 86400 end
    return math.max(60, (d.hour or 0) * 3600 + (d.min or 0) * 60 + (d.sec or 0))
end

-- Whole days since a time (0 = today)
function PC:DaysAgo(t)
    if not t then return nil end
    return math.max(0, math.floor((time() - t) / 86400))
end

-- Estimated number sold in the last `seconds`, plus how much of that time we actually have data for
function PC:SalesEstimate(itemID, seconds)
    local memo = self._memo
    if memo and itemID then
        local key = "se" .. itemID .. ":" .. seconds
        local hit = memo[key]
        if hit then return hit[1], hit[2] end
        local a, b = self:SalesEstimateRaw(itemID, seconds)
        memo[key] = { a, b }
        return a, b
    end
    return self:SalesEstimateRaw(itemID, seconds)
end
function PC:SalesEstimateRaw(itemID, seconds)
    local list = self:SupplyHistory()[itemID]
    if not list or #list < 2 then return nil end
    local since = time() - seconds
    local sold, first = 0, nil
    for i = 2, #list do
        local a, b = list[i - 1], list[i]
        if b.t >= since then
            local start = math.max(a.t, since)
            first = first or start
            if b.q < a.q then
                -- The drop happened somewhere between the two scans; count only the part inside the window
                local span = b.t - a.t
                local frac = (span > 0) and ((b.t - start) / span) or 1
                sold = sold + (a.q - b.q) * frac
            end
        end
    end
    if not first then return nil end
    return math.floor(sold + 0.5), time() - first
end

-- Exactly how many you sold yourself (from your Profit & loss history)
function PC:MySales(itemName, seconds)
    if not itemName then return 0 end
    local s = self:SellIndex()[itemName]
    if not s then return 0 end
    local since, n = time() - seconds, 0
    for i = #s.list, 1, -1 do
        local e = s.list[i]
        if e[1] >= since then n = n + e[2] end
    end
    return n
end

-- Tooltip lines for the sales info of an item
function PC:SalesTooltip(itemID)
    local lines = { "|cffffd100Sold at auction (estimated):|r" }
    local any, partial = false, false
    for _, w in ipairs(self.SALES_WINDOWS) do
        local sold, covered = self:SalesEstimate(itemID, w[1])
        if sold then
            any = true
            local text = ("  %s: |cffffffff%d|r"):format(w[2], sold)
            if covered < w[1] * 0.8 then
                text = text .. (" |cff888888(only %s of data)|r"):format(self:Ago(covered))
                partial = true
            end
            lines[#lines + 1] = text
        else
            lines[#lines + 1] = ("  %s: |cff888888not enough scans|r"):format(w[2])
        end
    end
    if any then
        lines[#lines + 1] = "|cff888888Counted from listings that disappear between scans, so cancelled or expired auctions count too.|r"
    else
        lines[#lines + 1] = "|cff888888Needs at least 2 scans of this item. Scan regularly for better numbers.|r"
    end

    local name = self:ItemName(itemID)
    local mine = {}
    for _, w in ipairs(self.SALES_WINDOWS) do
        mine[#mine + 1] = self:MySales(name, w[1])
    end
    if mine[4] > 0 then
        lines[#lines + 1] = ("|cff40ff40You sold:|r 1h %d, 12h %d, 24h %d, 5d %d"):format(mine[1], mine[2], mine[3], mine[4])
    end
    return lines
end

---------------------------------------------------------------------------
-- Price history, trends and alerts
---------------------------------------------------------------------------
PC.HISTORY_KEEP = 30          -- price points kept per item
PC.HISTORY_GAP = 30 * 60      -- scans closer together than this update the last point instead of adding one
PC.DEAL_PCT = -30             -- a material this far below its normal price is a deal

function PC:AddHistory(itemID, price)
    local h = self:History()
    local list = h[itemID]
    if not list then list = {}; h[itemID] = list end
    local now = time()
    local last = list[#list]
    if last and now - last.t < self.HISTORY_GAP then
        last.p, last.t = price, now
    else
        list[#list + 1] = { t = now, p = price }
        while #list > self.HISTORY_KEEP do table.remove(list, 1) end
    end
end

-- Keep saved data small: old price points and listing counts go, shared places nobody confirmed
-- go after a few weeks. Runs once per login, over every faction.
PC.HISTORY_DAYS = 14          -- price points older than this are dropped (the newest one is always kept)
PC.PLACE_STALE_DAYS = 21      -- someone else's unconfirmed place, not heard about in this long, is dropped

function PC:TrimSaved()
    local now = time()
    local cutoff = now - self.HISTORY_DAYS * 86400
    for _, byItem in pairs(db.history or {}) do
        for id, list in pairs(byItem) do
            if type(list) ~= "table" or #list == 0 then
                byItem[id] = nil
            else
                while #list > 1 and (list[1].t or 0) < cutoff do table.remove(list, 1) end
            end
        end
    end
    local sCut = now - self.SALES_KEEP
    for f, byItem in pairs(db.supplyHist or {}) do
        db.lastSold[f] = db.lastSold[f] or {}
        local ls = db.lastSold[f]
        for id, list in pairs(byItem) do
            if type(list) ~= "table" then
                byItem[id] = nil
            else
                -- remember the last time it sold before the points that showed it go
                for i = 2, #list do
                    if list[i].q < list[i - 1].q and (not ls[id] or list[i].t > ls[id]) then ls[id] = list[i].t end
                end
                while list[1] and list[1].t < sCut and list[2] and list[2].t < sCut do table.remove(list, 1) end
                local last = list[#list]
                if not last or last.t < sCut then byItem[id] = nil end
            end
        end
    end
    local pCut = now - self.PLACE_STALE_DAYS * 86400
    for _, t in pairs(db.places or {}) do
        for key, p in pairs(t) do
            if type(p) == "table" and not p.mine and not p.confirmed
                and math.max(p.seen or 0, p.heard or 0) < pCut then
                t[key] = nil
            end
        end
    end
end

-- How today's price compares with the usual price: returns percent difference and the usual price
function PC:Trend(itemID)
    local list = self:History()[itemID]
    if not list or #list < 3 then return nil end
    local sum, n = 0, 0
    for i = 1, #list - 1 do sum = sum + list[i].p; n = n + 1 end
    local avg = sum / n
    if avg <= 0 then return nil end
    return (list[#list].p - avg) / avg * 100, avg
end

-- What a vendor pays for one of an item (nil until the game has loaded the item)
function PC:SellPrice(itemID)
    -- what a vendor really paid you for it (learned at the vendor) beats everything
    local paid = db.vendorPaid and db.vendorPaid[itemID]
    if paid then return paid end
    -- (the same item is asked about many times in one refresh: the game is asked once)
    local memo = self._memo
    if memo and itemID then
        local key = "sp" .. itemID
        local hit = memo[key]
        if hit ~= nil then return hit or nil end
        local v = self:SellPriceRaw(itemID)
        memo[key] = v or false
        return v
    end
    return self:SellPriceRaw(itemID)
end
function PC:SellPriceRaw(itemID)
    -- the game's own number, every time (a saved copy can be out of date after a patch: Minor Wizard
    -- Oil was remembered at 5s while the vendor pays 1s)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local sell = getInfo and select(11, getInfo(itemID))
    if sell then
        db.sellPrice[itemID] = sell
        return sell
    end
    local known = db.sellPrice[itemID]
    if known then return known end
    Try(C_Item and C_Item.RequestLoadItemDataByID, itemID)
    return nil
end

-- After a scan: tell you about recipes that just became profitable and materials on sale
function PC:ReportAlerts()
    local alerts = {}

    -- Newly profitable recipes (clearing the minimum profit)
    local newly = {}
    for _, e in ipairs(self:Analyze()) do
        if self:MeetsMin(e) and self.prevProfitable and not self.prevProfitable[e.id] then
            newly[#newly + 1] = e
        end
    end
    table.sort(newly, function(a, b) return a.profit > b.profit end)
    for i = 1, math.min(3, #newly) do
        local e = newly[i]
        alerts[#alerts + 1] = ("|cff40ff40Now profitable:|r %s (per craft: Auction Profit %s, Vendor Profit %s)"):format(e.r.name,
            e.ahProfit and self:Money(e.ahProfit, true) or "n/a", e.vendorProfit and self:Money(e.vendorProfit, true) or "n/a")
    end

    -- Materials well below their usual price
    local seen, deals = {}, {}
    for _, r in pairs(self:ShownRecipes()) do
        for _, rg in ipairs(r.reagents) do
            for _, id in ipairs(self:ReagentIDs(rg)) do
                if not seen[id] then
                    seen[id] = true
                    local pct, avg -- (both of Trend's answers: an "and/or" kept only the first, so every tip said "usually n/a")
                    if not self:IsVendorItem(id) then pct, avg = self:Trend(id) end
                    if pct and pct <= self.DEAL_PCT and self:Prices()[id] then
                        deals[#deals + 1] = { id = id, pct = pct, avg = avg }
                    end
                end
            end
        end
    end
    table.sort(deals, function(a, b) return a.pct < b.pct end)
    for i = 1, math.min(3, #deals) do
        local d = deals[i]
        alerts[#alerts + 1] = ("|cffffd100Stock up:|r %s is %d%% below normal (%s, usually %s)"):format(
            self:ItemName(d.id), math.floor(-d.pct + 0.5), self:Money(self:Prices()[d.id]), self:Money(d.avg))
    end

    self.lastAlerts = alerts
    for _, line in ipairs(alerts) do Print(line) end
    return #alerts
end

-- Remember which recipes were profitable before a scan, so we can spot new ones after
function PC:SnapshotProfitable()
    local set = {}
    for _, e in ipairs(self:Analyze()) do
        if self:MeetsMin(e) then set[e.id] = true end
    end
    self.prevProfitable = set
end

---------------------------------------------------------------------------
-- Profit math
---------------------------------------------------------------------------

-- Every quality rank of what a recipe makes (just one item for recipes without ranks)
function PC:OutputIDs(r)
    if r.outputs and #r.outputs > 0 then return r.outputs end
    return { r.output }
end

-- Which rank to price a recipe at: the one you'll make (your choice, else what your skill makes, else rank 1)
function PC:CraftQuality(r)
    if not r.outputs then return nil end
    local set = cdb.qualityPick and cdb.qualityPick[r.name]
    local q = set or r.expQ or 1
    return math.max(1, math.min(q, #r.outputs)), set ~= nil
end

-- Quality rank of an item (materials and crafted items), if the game knows one
function PC:ItemQuality(itemID)
    local T = C_TradeSkillUI
    if not T or not itemID then return nil end
    local q = (T.GetItemReagentQualityByItemInfo and Try(T.GetItemReagentQualityByItemInfo, itemID))
        or (T.GetItemCraftedQualityByItemInfo and Try(T.GetItemCraftedQualityByItemInfo, itemID))
    return type(q) == "number" and q > 0 and q or nil
end

---------------------------------------------------------------------------
-- Expansions: pick which expansions' recipes to scan and show (Settings > AddOns > ProfitCrafter)
---------------------------------------------------------------------------
PC.EXPANSION_NAMES = {
    [0] = "Classic", "The Burning Crusade", "Wrath of the Lich King", "Cataclysm", "Mists of Pandaria",
    "Warlords of Draenor", "Legion", "Battle for Azeroth", "Shadowlands", "Dragonflight", "The War Within",
    "Midnight", "The Last Titan",
}

function PC:ExpansionName(expID)
    if type(expID) ~= "number" then return nil end
    return _G["EXPANSION_NAME" .. expID] or self.EXPANSION_NAMES[expID] or ("Expansion " .. expID)
end

-- Every expansion this game has: { {id, name}, ... }
function PC:ExpansionList()
    local n = (GetNumExpansions and Try(GetNumExpansions)) or 12
    if type(n) ~= "number" or n < 1 then n = 12 end
    local out = {}
    for i = 0, n - 1 do
        local name = self:ExpansionName(i)
        if name then out[#out + 1] = { id = i, name = name } end
    end
    return out
end

-- Which expansion an item comes from (nil if the game hasn't loaded the item yet)
function PC:ExpansionOf(itemID)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not getInfo or not itemID then return nil end
    local expID = select(15, getInfo(itemID))
    if type(expID) == "number" then return expID end
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
end

-- A recipe's expansion = the expansion of the item it makes (same as the item tooltip says)
-- What a plan made that's still to be sold (skill-up plans sell only these); selling uses them up
function PC:PlanMade(name)
    cdb.planMadeN = cdb.planMadeN or {}
    name = name or self:PlanName()
    cdb.planMadeN[name] = cdb.planMadeN[name] or {}
    return cdb.planMadeN[name]
end
function PC:PlanMadeUsed(itemID, n)
    if not itemID or not n or not cdb or not cdb.planMadeN then return end
    local t = cdb.planMadeN[self:PlanName()]
    if t and t[itemID] then
        t[itemID] = t[itemID] - n
        if t[itemID] <= 0 then t[itemID] = nil end
    end
end

function PC:RecipeExpansion(r)
    if r.expac == nil then r.expac = self:ExpansionOf(r.output) end
    return r.expac
end

function PC:ExpansionShown(expID)
    if self.FOREVER then return true end -- one expansion: nothing to hide
    return not (db.hideExp and db.hideExp[expID])
end

-- Your recipes, minus the expansions you turned off (unknown expansion = shown)
function PC:ShownRecipes()
    local hide = db.hideExp
    if self.FOREVER or not hide or not next(hide) then return cdb.recipes end
    local out = {}
    for id, r in pairs(cdb.recipes) do
        local e = self:RecipeExpansion(r)
        if e == nil or not hide[e] then out[id] = r end
    end
    return out
end

-- A recipe you know that makes this item (any quality rank)
function PC:RecipeFor(itemID)
    for recipeID, r in pairs(cdb.recipes) do
        for _, id in ipairs(self:OutputIDs(r)) do
            if id == itemID then return recipeID, r end
        end
    end
end

-- Item ID from a name (for history entries, which store names); only items from your recipes
-- Profession tools (not materials, so no recipe lists them): matched by their names in your client
PC.TOOL_IDS = { 4471, 5956, 2901, 7005, 6219, 6256, 10498, 6218, 6339, 11130, 11145, 16207, 9149, 20815, 20824 }

function PC:ItemIDByName(name)
    if not name then return nil end
    db.nameIDs = db.nameIDs or {}
    local known = db.nameIDs[name]
    if known and self:ItemName(known) == name then return known end
    local function hit(id)
        if id and self:ItemName(id) == name then db.nameIDs[name] = id; return true end
    end
    for _, id in ipairs(self.TOOL_IDS) do if hit(id) then return id end end
    for id in pairs(cdb.toolIDs or {}) do if hit(id) then return id end end
    -- your bags, and the vendor you're talking to
    for _, bs in ipairs(self.BagSlots and self.BagSlots() or {}) do if hit(bs.id) then return bs.id end end
    if self.merchantOpen and GetMerchantNumItems then
        for i = 1, GetMerchantNumItems() or 0 do
            local id = GetMerchantItemID and GetMerchantItemID(i)
            if not id and GetMerchantItemLink then
                local link = GetMerchantItemLink(i); id = link and tonumber(link:match("item:(%d+)"))
            end
            if hit(id) then return id end
        end
    end
    for _, r in pairs(cdb.recipes) do
        for _, id in ipairs(self:OutputIDs(r)) do
            if self:ItemName(id) == name then return id end
        end
        for _, rg in ipairs(r.reagents) do
            for _, id in ipairs(self:ReagentIDs(rg)) do
                if self:ItemName(id) == name then return id end
            end
        end
    end
end

-- All item IDs that can fill a material slot (every quality rank)
function PC:ReagentIDs(rg)
    if rg.alts and #rg.alts > 0 then return rg.alts end
    return { rg.id }
end

---------------------------------------------------------------------------
-- Vertical crafting: a material you can make yourself (Bolt of Linen Cloth from Linen Cloth)
-- counts as costing what ITS materials cost when that's cheaper than buying it. The plan then
-- buys the cloth and crafts the bolts first.
---------------------------------------------------------------------------
-- [itemID] = recipeID of a recipe you know that makes it
function PC:OutputMap()
    if self._omap then return self._omap end
    local m = {}
    for id, r in pairs(cdb.recipes) do
        local function add(o)
            if o and (not m[o] or (r.qty or 1) > (cdb.recipes[m[o]].qty or 1)) then m[o] = id end
        end
        add(r.output)
        for _, o in ipairs(r.outputs or {}) do add(o) end
    end
    self._omap = m
    return m
end

function PC:RecipeFor(itemID)
    local id = itemID and self:OutputMap()[itemID]
    return id, id and cdb.recipes[id] or nil
end

-- What one costs when you make it: nil when you can't, when it's turned off, or when a price is missing
function PC:CraftCost(itemID, depth)
    if cdb.vertical == false then return nil end
    depth = depth or 0
    local memo = self._memo
    if memo then
        local key = "cc" .. tostring(itemID) .. ":" .. depth
        local hit = memo[key]
        if hit then return hit[1], hit[2], hit[3] end
        local a, b, c = self:CraftCostRaw(itemID, depth)
        memo[key] = { a, b, c }
        return a, b, c
    end
    return self:CraftCostRaw(itemID, depth)
end
function PC:CraftCostRaw(itemID, depth)
    if depth > 2 then return nil end -- cloth -> bolt -> shirt is as deep as it goes
    local id, r = self:RecipeFor(itemID)
    if not r or not r.reagents or #r.reagents == 0 then return nil end
    local cost = 0
    for _, rg in ipairs(r.reagents) do
        local _, c = self:BestReagent(rg, depth + 1)
        if not c then return nil end
        cost = cost + c * rg.n
    end
    return cost / math.max(r.qty or 1, 1), id, r
end

-- The cheapest item that can fill a material slot: id, price per item, where to get it
-- ("Vendor", "AH", or "Craft" when making it yourself is cheaper than buying)
-- Materials this plan buys instead of making (you removed "Craft 240 Bolt..." or "disenchant ..." from
-- the tasks), and items it doesn't sell (you removed "post 4 Strange Dust"): per plan
local function PerPlan(key)
    if not cdb then return {} end
    cdb[key] = cdb[key] or {}
    local n = PC:PlanName() or "?"
    cdb[key][n] = cdb[key][n] or {}
    return cdb[key][n]
end
function PC:BuyOnly() return PerPlan("buyOnly") end
function PC:NoSell() return PerPlan("noSell") end

-- What a removed task did, so /pc undo can put it back (most recent first)
function PC:PushUndo(u)
    cdb.undo = cdb.undo or {}
    u.plan, u.t = self:PlanName(), time()
    table.insert(cdb.undo, u)
    while #cdb.undo > 20 do table.remove(cdb.undo, 1) end
end

function PC:BestReagent(rg, depth)
    local bestID, bestCost, bestSrc
    local buyOnly = self:BuyOnly()
    for _, id in ipairs(self:ReagentIDs(rg)) do
        local c, src = self:UnitCost(id)
        local cc = (not buyOnly[id]) and self:CraftCost(id, depth) or nil
        if cc and (not c or cc < c) then c, src = cc, "Craft" end
        -- dust/essence/shards: craft a green you know and disenchant it, when that's cheaper
        -- (only when the numbers show a saving, a quarter or more: it's more work than buying, and
        -- yields vary. No price to buy it at = nothing to compare = buy it.)
        local dc = db.deForMats ~= false and not buyOnly[id] and self.Synergy and self.Synergy:DECost(id, depth)
        if dc and c and dc < c * 0.75 then c, src = dc, "Disenchant" end
        if c and (not bestCost or c < bestCost) then bestID, bestCost, bestSrc = id, c, src end
    end
    return bestID or rg.id, bestCost, bestSrc
end

-- How many of a material slot you already have (any quality rank counts)
function PC:ReagentCount(rg)
    local n = 0
    for _, id in ipairs(self:ReagentIDs(rg)) do n = n + self:ItemCount(id) end
    return n
end

-- Cheapest place to buy one of an item: vendor or AH
-- Items a vendor sells: their AH listings are often scams at silly prices, so they get no trend,
-- no ticker spot and no price alert; recipes always cost them at the vendor price.
function PC:IsVendorItem(itemID)
    return itemID ~= nil and db.vendor[itemID] ~= nil
end

function PC:UnitCost(itemID)
    local ah = self:Price(itemID)
    local v = self:VendorCost(itemID)
    if v and (not ah or v <= ah) then return v, "Vendor" end
    if ah then return ah, "AH" end
    return nil
end

---------------------------------------------------------------------------
-- Buying a lot: the price ladder. The cheapest listing rarely has enough, so every amount is priced
-- by walking the listings cheapest first (the live listings read after each scan; without them, the
-- cheapest price for as many as are listed). Items a vendor also sells: only the listings under the
-- vendor's price, then the vendor for the rest (it never runs out).
--   ladder = { steps = { {p, q}, ... }, cq = running count, cc = running cost, vendor = price or nil,
--              est = true when it's only the cheapest price (no live listings read) }
---------------------------------------------------------------------------
function PC:Ladder(itemID)
    local memo = self._memo
    local key = memo and ("lad" .. tostring(itemID))
    if memo then
        local hit = memo[key]
        if hit ~= nil then return hit or nil end
    end
    local lad = self:LadderRaw(itemID)
    if memo then memo[key] = lad or false end
    return lad
end

function PC:LadderRaw(itemID)
    if not itemID then return nil end
    local v = self:VendorCost(itemID)
    local steps, est = {}, false
    local d = self:DepthTable()[itemID]
    if d and d.list and #d.list > 0 then
        for _, s in ipairs(d.list) do
            if v and s.p >= v then break end -- the vendor's price or more: the vendor sells it for less
            if s.p > 0 and s.q > 0 then steps[#steps + 1] = { p = s.p, q = s.q } end
        end
    else
        local p = self:Price(itemID)
        if p and p > 0 and (not v or p < v) then
            local listed = self:Supply()[itemID]
            steps[1] = { p = p, q = (type(listed) == "number" and listed > 0) and listed or math.huge }
            est = true
        end
    end
    if #steps == 0 and not v then return nil end
    local cq, cc, q, c = {}, {}, 0, 0
    for i, s in ipairs(steps) do
        q = q + s.q
        c = (s.q == math.huge) and c or (c + s.q * s.p) -- (an open-ended step only ever comes last)
        cq[i], cc[i] = q, c
    end
    return { steps = steps, cq = cq, cc = cc, vendor = v, est = est }
end

-- A ladder with no listings: any amount at one price (made yourself, or a vendor)
function PC:FlatLadder(price)
    if not price then return nil end
    return { steps = {}, cq = {}, cc = {}, vendor = price, flat = true }
end

-- What buying n off a ladder costs: total, average each, the priciest each, how many couldn't be had
-- (nil when all can: only when nothing's left listed and no vendor sells it)
function PC:LadderCost(lad, n)
    if not lad or not n or n <= 0 then return 0, nil, nil, nil end
    local steps, cq, cc = lad.steps, lad.cq, lad.cc
    local last = #steps
    if last > 0 and n <= cq[last] then
        local lo, hi = 1, last
        while lo < hi do
            local mid = math.floor((lo + hi) / 2)
            if cq[mid] >= n then hi = mid else lo = mid + 1 end
        end
        local total = (lo > 1 and cc[lo - 1] or 0) + (n - (lo > 1 and cq[lo - 1] or 0)) * steps[lo].p
        return total, total / n, steps[lo].p, nil
    end
    local have = last > 0 and cq[last] or 0
    local spent = last > 0 and cc[last] or 0
    local rest = n - have
    if lad.vendor then
        local total = spent + rest * lad.vendor
        return total, total / n, lad.vendor, nil
    end
    local top = last > 0 and steps[last].p or 0
    local total = spent + rest * top
    return total, total / n, top, rest
end

-- What buying n of an item costs the way the plan buys it (AH listings under the vendor's price,
-- then the vendor): total, average each, priciest each, how many short. nil when there's no price.
function PC:EffectiveCost(itemID, n)
    local lad = self:Ladder(itemID)
    if not lad then return nil end
    return self:LadderCost(lad, n)
end

---------------------------------------------------------------------------
-- The minimum profit: a craft has to make at least this share of what its materials cost.
-- Lists hide recipes under it, buying stops before a craft would fall under it, and the Craftable
-- column counts only the crafts that still clear it.
---------------------------------------------------------------------------
function PC:MinProfitPct()
    local p = db and tonumber(db.minProfitPct) or self.MIN_PROFIT_DEFAULT
    return math.max(0, math.min(p, 1000))
end

-- Does this recipe make at least the minimum profit (the way it's sold)?
function PC:MeetsMin(e)
    return e ~= nil and e.profitPct ~= nil and e.profit ~= nil and e.profit > 0 and e.profitPct >= self:MinProfitPct()
end

-- Does an AH craft really sell? What sold today against what's listed now: fewer than half as many sold
-- as are listed won't sell in the window you post it (not a best bet, not for Make me gold); more sold
-- than listed is a hot seller (those come first). A vendor buys on the spot and disenchanting isn't
-- sold as the item: neither is held to it. Returns ok, hot, sold/listed (nil when it can't be told).
PC.SELL_THROUGH_MIN = 0.5
function PC:SellThroughOf(route, listed, soldToday)
    if route ~= "AH" then return true, false, nil end
    soldToday = soldToday or 0
    if listed == nil then return true, false, nil end -- (not scanned yet: the sold-today rule decides)
    if listed <= 0 then return true, soldToday > 0, nil end
    local r = soldToday / listed
    return r >= self.SELL_THROUGH_MIN, soldToday > listed, r
end
function PC:SellThrough(e)
    if not e then return false, false, nil end
    return self:SellThroughOf(e.route, e.listed, e.soldToday)
end

-- The same, one way of selling: on the AH (after its cut) or to a vendor (the recipe tables' two boxes)
function PC:MeetsMinAH(e)
    return e ~= nil and e.ahProfit ~= nil and e.ahProfit > 0 and e.ahProfitPct ~= nil and e.ahProfitPct >= self:MinProfitPct()
end
function PC:MeetsMinV(e)
    return e ~= nil and e.vendorProfit ~= nil and e.vendorProfit > 0 and e.vendorProfitPct ~= nil and e.vendorProfitPct >= self:MinProfitPct()
end

-- May this recipe be recommended? Not for the Auction House when none sold there today
-- (Settings: "Only recommend AH crafts that sold today")
function PC:SalesOK(e)
    if not e or e.route ~= "AH" or not (db and db.needSalesToday ~= false) then return true end
    return (e.soldToday or 0) > 0
end

-- Is the plan in hand made to earn gold? (Skill up and Gear upgrades plans aren't: the minimum
-- profit doesn't hold them back)
function PC:PlanForProfit(name)
    name = name or self:PlanName()
    if name == "Gear upgrades" then return false end
    if self.UI and self.UI.IsSkillPlan and self.UI:IsSkillPlan(name) then return false end
    return true
end

-- What one craft brings in, each way: on the AH (after its cut; nil when it can't be listed there),
-- to a vendor, and the way the recipe is sold
function PC:CraftIncome(e)
    local qty = e.r and e.r.qty or 1
    local ah = (e.sellEach and self:AHSellable(e.sellEach)) and e.sellEach * qty * (1 - self.AH_CUT) or nil
    local v = (e.vendorSell and e.vendorSell > 0) and e.vendorSell or nil
    local route = (e.profit and e.cost) and (e.profit + e.cost) or nil
    return ah, v, route
end

-- Craftable at Profit: how many crafts of a recipe your materials (bags, bank, mail) and your budget
-- cover, buying the rest cheapest first at real listing prices, while every craft still makes the
-- minimum profit (on the AH or to a vendor, whichever lasts longer). Returns:
--   n, worth and spend for those n (materials: yours at today's price, the rest at what they'd cost;
--   the gold it takes), Total AH Profit (only the crafts making the minimum on the AH: nAH of them),
--   Total V Profit (the same to a vendor: nV), why it stops ("gold", "market", "profit", "max"),
--   est (true when a material had no live listings: priced at its cheapest), nAH, nV
-- nil when a material has no price, or there's no price to sell at.
function PC:Craftable(e, budget)
    if not e or not e.r or not e.r.reagents then return nil end
    -- (explicit lengths: some of the answers can be nil, and unpack stops at the first gap otherwise)
    if not budget and e._craft then return unpack(e._craft, 1, 9) end
    local res
    if e.ahFlip then res = { self:FlipCraftableRaw(e, budget or self:Gold()) }
    else res = { self:CraftableRaw(e, budget or self:Gold()) } end
    if not budget then e._craft = res end
    return unpack(res, 1, 9)
end

-- How many crafts of a recipe your bags have room for, up to `upto`: the materials still to buy (made
-- ones opened up into what makes them) and what's made, when it has to wait in your bags - the same
-- count as the plan's own bag check (PC:PlanSlots), the bank's free slots included while it's open.
-- A quick count first, then the plan's own check settles the exact number.
function PC:BagRoomCrafts(e, upto)
    upto = math.max(math.floor(upto or 0), 0)
    if upto == 0 then return 0 end
    local free = self:FreeBagSlots()
    local memo = self._memo
    local function exact(k)
        if k <= 0 then return true end
        local key = memo and ("room" .. tostring(e.id) .. ":" .. k)
        if key and memo[key] ~= nil then return memo[key] end
        local okS, need = pcall(self.PlanSlots, self, { setmetatable({ planCount = k }, { __index = e }) })
        local fits = (not okS) or need <= free -- (can't tell: no limit from the bags)
        if key then memo[key] = fits end
        return fits
    end
    if exact(upto) then return upto end
    -- quick count: each raw thing to buy per craft, stacks, what you already have
    local items = {}
    local function add(id, per, have)
        local it = items[id]
        if not it then it = { per = 0, have = have or 0, stack = math.max(self:StackSize(id), 1) }; items[id] = it end
        it.per = it.per + per
    end
    for _, rg in ipairs(e.r.reagents or {}) do
        local id, _, src = self:ReagentFor(rg, e.mats)
        local _, sr = self:RecipeFor(id)
        if src == "Craft" and sr and sr.reagents and #sr.reagents > 0 then
            local per = rg.n / math.max(sr.qty or 1, 1)
            for _, sg in ipairs(sr.reagents) do add((self:ReagentFor(sg, "low")), sg.n * per, self:ReagentCount(sg)) end
        else
            add(id, rg.n, (e.mats == "high") and self:ItemCount(id) or self:ReagentCount(rg))
        end
    end
    local outID = e.outID or e.r.output
    local outStack = math.max(self:StackSize(outID), 1)
    local skill = self.UI and self.UI.IsSkillPlan and self.UI:IsSkillPlan()
    local countOut = not (skill or e.route == "Vendor" or e.route == "Disenchant")
    local reagentFree = self:FreeReagentBagSlots()
    local function quick(k)
        local s = 0
        for _, it in pairs(items) do
            local buy = math.ceil(k * it.per) - it.have
            if buy > 0 then s = s + math.ceil(buy / it.stack) end
        end
        local inReagent = math.min(s, reagentFree)
        s = s - inReagent
        if countOut then
            local out = math.ceil(k * math.max(e.r.qty or 1, 1) / outStack)
            local mats = 0
            for _, rg in ipairs(e.r.reagents or {}) do
                mats = mats + math.ceil(rg.n * k / math.max(self:StackSize((self:ReagentFor(rg, e.mats))), 1))
            end
            s = s + math.max(out - mats, 0) + math.min(inReagent, out, mats)
        end
        return s
    end
    local lo, hi = 0, upto
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if quick(mid) <= free then lo = mid else hi = mid - 1 end
    end
    -- the plan's own check, from the quick count: up while it still fits, down while it doesn't
    local k = lo
    if exact(k) then
        while k < upto and exact(k + 1) do k = k + 1 end
    else
        while k > 0 and not exact(k) do k = k - 1 end
    end
    return k
end

-- The same, but the way it's sold must make at least the minimum profit (what buying will really do)
function PC:CraftableAtMin(e, budget)
    if not e or not e.r or not e.r.reagents or e.ahFlip then return nil end
    if not budget and e._craftMin then return unpack(e._craftMin, 1, 9) end
    local res = { self:CraftableRaw(e, budget or self:Gold(), self:MinProfitPct()) }
    if not budget then e._craftMin = res end
    return unpack(res, 1, 9)
end

-- How many crafts of a recipe buying goes for: the ones that each still make the minimum profit with all
-- their materials together (yours first, the rest priced up the listings: CraftableRaw), and never fewer
-- than the crafts your scarce materials (ones no vendor sells) already cover: their other materials are
-- bought to finish them. Returns that count, the count at the minimum, the count you hold the scarce
-- materials for, and why the count at the minimum stops; nil when a price is missing (no limit from the profit).
function PC:BuyCrafts(e)
    if not e or not e.r or not e.r.reagents or e.ahFlip then return nil end
    local memo = self._memo
    local key = memo and ("buyc" .. tostring(e.id) .. ":" .. tostring(e.mats))
    if key and memo[key] then return unpack(memo[key], 1, 4) end
    local res = {}
    local slots = self:BatchSlots(e)
    if slots then
        local j, _, _, _, _, jwhy = self:CraftableRaw(e, math.huge, self:MinProfitPct(), true)
        local held, all
        for _, s in ipairs(slots) do
            local c = math.floor(s.have / math.max(s.n, 1))
            all = math.min(all or c, c)
            if not s.lad.vendor then held = math.min(held or c, c) end
        end
        held = held or all or 0
        if j then res = { math.max(j, held), j, held, jwhy } end
    end
    if key then memo[key] = res end
    return unpack(res, 1, 4)
end

-- A recipe's materials for batch maths: { {n, have, unit, lad}, ... } and whether a price is only the
-- cheapest one (no live listings). nil when a material has no price.
function PC:BatchSlots(e)
    if not e or not e.r or not e.r.reagents or not e.cost then return nil end
    local mode = e.mats or "low"
    local slots, est = {}, false
    for _, rg in ipairs(e.r.reagents) do
        local id, unit, src, rank = self:ReagentFor(rg, mode)
        if not unit then return nil end
        local lad = (src == "AH" or src == "Vendor") and self:Ladder(id) or nil
        lad = lad or self:FlatLadder(unit)
        if lad.est then est = true end
        local have = (mode == "high" and rank) and self:ItemCount(id) or self:ReagentCount(rg)
        slots[#slots + 1] = { n = rg.n, have = have, unit = unit, lad = lad }
    end
    return slots, est
end

-- n crafts' materials: the gold to buy what you don't have, and what they're all worth (yours at
-- today's price, the rest at what they'd cost). nil when the market doesn't have enough.
function PC:BatchCost(slots, n)
    local spend, worth = 0, 0
    for _, s in ipairs(slots) do
        local need = n * s.n
        local own = math.min(need, s.have)
        local buy = need - own
        if buy > 0 then
            local total, _, _, short = self:LadderCost(s.lad, buy)
            if short then return nil end
            spend, worth = spend + total, worth + total
        end
        worth = worth + own * s.unit
    end
    return spend, worth
end

-- Profit of exactly n crafts, materials priced for the whole batch: AH profit, vendor profit, the
-- profit the way it's sold, the gold it takes. nil when a price is missing or the market runs short.
function PC:BatchProfit(e, n)
    local slots = self:BatchSlots(e)
    if not slots or not n or n <= 0 then return nil end
    local spend, worth = self:BatchCost(slots, n)
    if not spend then return nil end
    local ahIn, vIn, routeIn = self:CraftIncome(e)
    return ahIn and (n * ahIn - worth) or nil, vIn and (n * vIn - worth) or nil,
        routeIn and (n * routeIn - worth) or nil, spend
end

-- minPct nil: Craftable at Profit: the crafts that make the minimum profit, each way (on the AH, to a
-- vendor, the way it's sold), every craft priced as the batch climbs the listings; the way that lasts
-- longest counts. minPct a number: only the way it's sold, at that share of its materials' cost
-- (CraftableAtMin, what buying will do).
function PC:CraftableRaw(e, budget, minPct, noBags)
    local slots, est = self:BatchSlots(e)
    if not slots then return nil end
    local ahIn, vIn, routeIn = self:CraftIncome(e)
    if not (ahIn or vIn or routeIn) then return nil end -- no price to sell at: can't tell
    -- (each amount is worked out once: the searches ask for the same ones again)
    local seen = {}
    local function batch(n)
        local c = seen[n]
        if not c then c = { self:BatchCost(slots, n) }; seen[n] = c end
        return c[1], c[2]
    end
    -- the most the market could ever supply (a material nobody else sells: what's listed plus yours)
    local most = self.MAX_CRAFTABLE
    for _, s in ipairs(slots) do
        local lad = s.lad
        if not lad.vendor then
            local listed = #lad.steps > 0 and lad.cq[#lad.steps] or 0
            most = math.min(most, math.floor((s.have + listed) / math.max(s.n, 1)))
        end
    end
    -- the most crafts your gold and the market cover where every craft, selling at `income` each, makes a
    -- profit of at least pct% of what its materials are worth (more than nothing at 0%) -> n, why
    -- the AH deposit for what's posted comes out of the same gold (as the plan counts it)
    local feeEach = 0
    if e.route ~= "Vendor" and e.route ~= "Disenchant" and self.Sell and self.Sell.FeeEach then
        local okF, f = pcall(self.Sell.FeeEach, self.Sell, e.outID or e.r.output)
        feeEach = (okF and f or 0) * math.max(e.r.qty or 1, 1)
    end
    local function search(income, pct)
        if not income then return 0, "profit" end
        local why
        local function ok(k)
            local s1, w1 = batch(k)
            if not s1 then why = "market" return false end
            if s1 + (feeEach > 0 and (feeEach * k + 100) or 0) > budget then why = "gold" return false end
            local _, w0 = batch(k - 1)
            local cost = w1 - (w0 or 0)
            local margin = income - cost
            if margin <= 0 or margin < cost * pct / 100 then why = "profit" return false end
            return true
        end
        if most < 1 then return 0, "market" end
        if not ok(1) then return 0, why end
        local cap = math.min(self.MAX_CRAFTABLE, most + 1) -- (one past what's listed: its "no" says why)
        local lo, hi = 1, 2
        while hi <= cap and ok(hi) do lo, hi = hi, hi * 2 end
        if hi > cap then
            hi = cap
            if ok(hi) then lo = hi; if hi == self.MAX_CRAFTABLE then why = "max" end end
        end
        while lo < hi - 1 do
            local mid = math.floor((lo + hi) / 2)
            if ok(mid) then lo = mid else hi = mid end
        end
        if lo < self.MAX_CRAFTABLE then ok(lo + 1) end -- (says why it stops there)
        return lo, why
    end
    -- the profit of the first k crafts at `income` each (the whole batch's materials); none at a profit
    -- that way: what it would lose on the crafts counted (or on one), never left blank
    local function total(income, k, n)
        if not income then return nil end
        local m = (k > 0) and k or math.max(n, 1)
        local s, w = batch(m)
        if not s then return nil end -- (the market doesn't have even that)
        return m * income - w
    end
    local n, why, nAH, nV
    if minPct then
        n, why = search(routeIn, minPct)
        nAH, nV = n, n
    else
        local pct = self:MinProfitPct()
        local nR, wR = search(routeIn, pct)
        local wA, wV
        nAH, wA = search(ahIn, pct)
        nV, wV = search(vIn, pct)
        n, why = nR, wR
        if nAH > n then n, why = nAH, wA end
        if nV > n then n, why = nV, wV end
    end
    -- and no more than your bags have room for (what the plan would let you add)
    if n > 0 and not noBags then
        local room = self:BagRoomCrafts(e, n)
        if room < n then
            n, why = room, "bags"
            nAH, nV = math.min(nAH, room), math.min(nV, room)
        end
    end
    local spend, worth = 0, 0
    if n > 0 then spend, worth = batch(n) end
    return n, worth, spend, total(ahIn, nAH, n), total(vIn, nV, n), why, est, nAH, nV
end

-- An AH flip (bought on the AH, sold to a vendor): how many listed under what a vendor pays your gold
-- covers, and the profit selling those to a vendor (or listing them again on the AH, after its cut).
-- Same answers as CraftableRaw (nAH is 0: listing it again never pays).
function PC:FlipCraftableRaw(e, budget)
    local id, vend, p0 = e.ahFlipID, e.sell, e.cost
    local lad = id and self:Ladder(id)
    if not (lad and vend and p0) then return nil end
    local n, spend, why = 0, 0, "market"
    for _, s in ipairs(lad.steps) do
        if s.p >= vend then why = "profit" break end
        local afford = math.floor((budget - spend) / s.p)
        local take = math.min(s.q, afford, self.MAX_CRAFTABLE - n)
        if take > 0 then n, spend = n + take, spend + take * s.p end
        if n >= self.MAX_CRAFTABLE then why = "max" break end
        if take < s.q then why = "gold" break end
    end
    local ahEach = p0 * (1 - self.AH_CUT)
    if n == 0 then return 0, 0, 0, ahEach - p0, vend - p0, why, lad.est, 0, 0 end
    return n, spend, spend, n * ahEach - spend, n * vend - spend, why, lad.est, 0, n
end

---------------------------------------------------------------------------
-- The plan's recipes that use a material, the ones that can pay most for it first:
-- { { e, n (per craft), need (for the plan), cap (the most one may cost at the minimum profit) }, ... }
---------------------------------------------------------------------------
--   need: what the crafts buying goes for take (PC:BuyCrafts, no more than the plan's count), cut: that's
--   fewer than the plan's count, heldCrafts: the crafts your scarce materials cover, free: the most one
--   may cost to finish one of those (the craft still brings in more than it and the others still to buy)
function PC:MaterialDemands(itemID, entries)
    local minPct = self:MinProfitPct()
    -- what a recipe's other materials cost for its k-th craft, yours first (cash: only the gold still to spend)
    local function othersAt(slots, skip, k, cash)
        local c = 0
        for i, s in ipairs(slots) do
            if i ~= skip then
                local s1, w1 = self:BatchCost({ s }, k)
                local s0, w0 = self:BatchCost({ s }, k - 1)
                if not w1 then return nil end
                if cash then c = c + s1 - (s0 or 0) else c = c + w1 - (w0 or 0) end
            end
        end
        return c
    end
    local demands = {}
    for _, e in ipairs(entries) do
        local _, _, routeIn = self:CraftIncome(e)
        for i, rg in ipairs(e.r and e.r.reagents or {}) do
            local id = self:ReagentFor(rg, e.mats)
            if id == itemID then
                local n = math.max(rg.n, 1)
                local target, j, held, jwhy = self:BuyCrafts(e)
                local cap, free = math.huge, math.huge
                if routeIn then
                    -- the most one may cost for the last craft that still makes the minimum
                    local slots = self:BatchSlots(e)
                    slots = slots and #slots == #e.r.reagents and slots or nil
                    local others = slots and othersAt(slots, i, math.max(j or 1, 1))
                    if not others then
                        others = 0
                        for _, rg2 in ipairs(e.r.reagents) do
                            if rg2 ~= rg then
                                local _, u2 = self:ReagentFor(rg2, e.mats)
                                others = others + (u2 or 0) * rg2.n
                            end
                        end
                    end
                    cap = (routeIn / (1 + minPct / 100) - others) / n
                    -- (finishing a held craft must not cost more gold than it brings in, all its materials together)
                    local cash = slots and othersAt(slots, i, math.max(held or 1, 1), true)
                    free = (routeIn - (cash or others)) / n
                end
                local want = e.planCount or 1
                -- (a count cut short by the market isn't a profit stop: that material's own buying runs out)
                local limit = jwhy == "profit" and target or nil
                local crafts = limit and math.min(want, limit) or want
                demands[#demands + 1] = { e = e, n = rg.n, need = rg.n * crafts, cap = cap, free = free,
                    heldCrafts = held or 0, cut = crafts < want }
            end
        end
    end
    table.sort(demands, function(a, b) return a.cap > b.cap end)
    return demands
end

-- Buying a material stopped for good at the minimum profit: each recipe in the plan that uses it is
-- amended to the crafts buying goes for (PC:BuyCrafts: the ones that make the minimum, or what your
-- scarce materials already cover, bags, bank, mail and purchases on their way counted), so it stops
-- asking for what won't be bought. Not for Skill up / Gear plans. /pc undo puts it back.
-- Returns the changes { { e, from, to }, ... } (said in chat).
function PC:AmendPlanToHeld(itemID)
    if not itemID or not self:PlanForProfit() or not (self.UI and self.UI.PlanEntries) then return {} end
    if not self.UI.allEntries then self.UI.allEntries = self:Analyze() end
    local plan = self:CurrentPlan()
    local changes, old = {}, {}
    for _, d in ipairs(self:MaterialDemands(itemID, self.UI:PlanEntries())) do
        local cur = plan[d.e.id] or 0
        local crafts = math.min(cur, math.floor(d.need / math.max(d.n, 1)))
        if crafts < cur then
            old[d.e.id] = cur
            plan[d.e.id] = crafts > 0 and crafts or nil
            changes[#changes + 1] = { e = d.e, from = cur, to = crafts }
        end
    end
    if #changes == 0 then return changes end
    self:PushUndo({ kind = "amend", counts = old })
    self:ForgetStopList()
    if self.UI then self.UI.allEntries = nil end
    local parts = {}
    for _, c in ipairs(changes) do parts[#parts + 1] = ("%s %d %s %d"):format(c.e.r.name, c.from, self.ARROW_R, c.to) end
    self.Buy:Say(("|cffffd100Plan amended to what buying gets: %s. More %s would drop the craft under %d%% profit. |cff888888(/pc undo reverts it)|r|r"):format(
        table.concat(parts, ", "), self:ItemName(itemID) or "material", self:MinProfitPct()))
    self:RefreshUI()
    return changes
end

-- (an amendment is asked for from inside a refresh too: it happens just after it)
function PC:AmendPlanSoon(itemID)
    self._amend = self._amend or {}
    if self._amend[itemID] then return end
    self._amend[itemID] = true
    C_Timer.After(0, function()
        self._amend[itemID] = nil
        self:Safe("amend plan", self.AmendPlanToHeld, self, itemID)
    end)
end

---------------------------------------------------------------------------
-- How much of a material to buy before it stops paying: walking the listings cheapest first, each one
-- bought has to keep the craft it's for at or above the minimum profit. A material several recipes in
-- the plan use goes to whichever can pay for it. Materials you already hold go to the recipes that
-- can pay most (buying is only for the ones further down).
--   want: how many the plan still wants; ladder: what's listed ({ {p, q}, ... } cheapest first;
--   default: the live listings); entries: the plan's recipes (default: the plan in hand)
-- Returns how many to buy, the most to pay for one (nil = no limit), and why it stops ("profit", "market", "have" or nil).
---------------------------------------------------------------------------
function PC:ProfitableBuyQty(itemID, want, ladder, entries)
    want = math.max(math.floor(want or 0), 0)
    if want == 0 or not itemID then return 0 end
    if not self:PlanForProfit() then return want end -- skill-ups and gear: not held to a profit
    entries = entries or (self.UI and self.UI.PlanEntries and self.UI:PlanEntries()) or {}
    local demands = self:MaterialDemands(itemID, entries)
    if #demands == 0 then return want end -- not for a recipe in the plan (a tool, a flip): as asked
    -- what you hold (bags, bank, mail, purchases on their way) covers the recipes that pay most: buying
    -- is only ever for the next ones down. (Handed to the ones that pay least, every fresh look after a
    -- purchase moved the line and bought past the stop, a bit at a time.)
    local own = self:ItemCount(itemID)
    local cut = false
    for _, d in ipairs(demands) do
        local use = math.min(own, d.need)
        d.need, own = d.need - use, own - use
        d.ownCrafts = math.floor(use / math.max(d.n, 1))
        if d.cut then cut = true end
    end
    -- the units still to buy, each with the most it may cost (finishing crafts your scarce materials
    -- cover: while the craft brings in more), priciest-allowed first
    local caps = {}
    for _, d in ipairs(demands) do
        local freeN = math.min(d.need, math.max(d.heldCrafts - d.ownCrafts, 0) * d.n)
        for k = 1, math.min(d.need, want - #caps) do caps[#caps + 1] = (k <= freeN) and math.max(d.free, d.cap) or d.cap end
        if #caps >= want then break end
    end
    -- (fewer crafts than the plan's count make the minimum: the rest stop for the profit)
    if #caps == 0 then return 0, nil, cut and "profit" or "have" end
    table.sort(caps, function(a, b) return a > b end)
    local maxEach = caps[1] ~= math.huge and caps[1] or nil
    -- the listings, cheapest first, one price per unit (only as many as could be wanted); by default
    -- the AH listings under the vendor's price (the vendor sells the rest)
    local prices = {}
    local lad = ladder
    if not lad then
        local L = self:Ladder(itemID)
        lad = L and L.steps
    end
    -- nothing known about what's listed: the AH's own price quote has to settle it (most to pay: maxEach)
    if not lad or #lad == 0 then return math.min(want, #caps), maxEach, (cut and #caps < want) and "profit" or nil end
    for _, s in ipairs(lad) do
        for _ = 1, s.q do
            prices[#prices + 1] = s.p
            if #prices >= math.min(want, #caps) then break end
        end
        if #prices >= math.min(want, #caps) then break end
    end
    -- the most of the cheapest q units that can each go to a recipe that pays for it:
    -- match the priciest of them to the most generous caps
    local function fits(q)
        for j = 1, q do
            if prices[q - j + 1] > caps[j] then return false end
        end
        return true
    end
    local lo, hi = 0, math.min(want, #caps, #prices)
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if fits(mid) then lo = mid else hi = mid - 1 end
    end
    -- (prices were only read as far as the units wanted: fewer than that is the market running out)
    local top = math.min(want, #caps)
    local why
    if lo < math.min(top, #prices) then why = "profit"
    elseif lo < top and #prices < top then why = "market"
    elseif cut and lo < want then why = "profit" end
    return lo, maxEach, why
end

-- Every price ProfitCrafter knows for an item, for tooltips. Marks the one it's using.
function PC:PriceSourceLines(itemID)
    local lines = { "|cffffd100Prices known:|r" }
    local used, usedSrc = self:UnitCost(itemID)
    local ah = self:Prices()[itemID]
    local src = self:Source()[itemID]
    local function line(label, price, isUsed)
        lines[#lines + 1] = ("  %s: %s%s"):format(label, self:Money(price), isUsed and (" " .. PC.ARROW_L .. " |cff40ff40used|r") or "")
    end
    if ah then
        local when = self:Checked()[itemID]
        local label = src and ("From " .. src) or "Your auction scan"
        if when then label = label .. (" (%s ago)"):format(self:Ago(time() - when)) end
        line(label, ah, usedSrc == "AH" and used == ah)
    end
    if db.vendor[itemID] then
        local r = self:BarterRank()
        line(r > 0 and ("A vendor charges (Bartering %d%% off)"):format(r * 5) or "A vendor charges", self:VendorCost(itemID), usedSrc == "Vendor")
    end
    if not ah then
        local auc = self:AuctionatorPrice(itemID)
        if auc then line("Auctionator", auc, usedSrc == "AH" and used == auc) end
        local tsm = self.TSMPrice and self:TSMPrice(itemID)
        if tsm then line("TSM", tsm, usedSrc == "AH" and used == tsm) end
    end
    if #lines == 1 then lines[#lines + 1] = "  |cff888888none yet: scan the Auction House or visit a vendor that sells it|r" end
    return lines
end

-- One entry per known recipe, best profit first
-- Every rank that can fill a material slot, lowest quality first
function PC:RankedReagentIDs(rg)
    local ids = self:ReagentIDs(rg)
    if #ids < 2 then return ids end
    local list = {}
    for i, id in ipairs(ids) do list[i] = { id = id, q = self:ItemQuality(id) or i, i = i } end
    table.sort(list, function(a, b) if a.q == b.q then return a.i < b.i end return a.q < b.q end)
    local out = {}
    for i, it in ipairs(list) do out[i] = it.id end
    return out
end

-- Which item to buy for a material slot:
--   "low"  = the cheapest rank (usually the lowest quality)
--   "high" = the highest quality rank, for the best crafted quality
-- returns id, price each, where, rank (1 = lowest; nil when the material has no ranks)
function PC:ReagentFor(rg, mode)
    local ranked = self:RankedReagentIDs(rg)
    if mode == "high" and #ranked > 1 then
        local id = ranked[#ranked]
        local c, src = self:UnitCost(id)
        return id, c, src, #ranked
    end
    local id, c, src = self:BestReagent(rg)
    local rank
    for i, rid in ipairs(ranked) do if rid == id then rank = i end end
    return id, c, src, (#ranked > 1) and rank or nil
end

function PC:HasRankedMats(r)
    for _, rg in ipairs(r.reagents) do
        if #self:ReagentIDs(rg) > 1 then return true end
    end
    return false
end

-- Cost and profit of one craft with a given choice of materials and crafted quality
function PC:Evaluate(r, mode, quality)
    local cost, missing = 0, false
    for _, rg in ipairs(r.reagents) do
        local _, c = self:ReagentFor(rg, mode)
        if c then cost = cost + c * rg.n else missing = true end
    end
    -- Price the quality you'll make; if it has no price yet, fall back to a LOWER rank (never guess high)
    local outID, qFallback = r.output, nil
    if quality and r.outputs then
        outID = r.outputs[quality]
        if not self:Price(outID) then
            for q = quality - 1, 1, -1 do
                if self:Price(r.outputs[q]) then outID, qFallback = r.outputs[q], q break end
            end
        end
    end
    local sell = self:Price(outID)
    local ahProfit
    -- (under 1s on an AH that only takes whole silver it can't be listed at that price: no AH route)
    if sell and not missing and self:AHSellable(sell) then ahProfit = sell * r.qty * (1 - self.AH_CUT) - cost end
    -- Selling to a vendor: no AH cut, no waiting, no competition
    local vSell = self:SellPrice(outID)
    local vendorProfit
    if vSell and vSell > 0 and not missing then vendorProfit = vSell * r.qty - cost end
    local profit, route = ahProfit, "AH"
    -- a vendor flip (the vendor pays more than the materials cost): it goes to the vendor, even when
    -- the AH might pay a bit more - instant gold, no deposit, no waiting, no competition
    -- (only on a vendor price you've seen a vendor really pay: this game's item data can be wrong - it
    -- said 5s for Minor Wizard Oil and the vendor pays 1s, which turned every oil into a loss)
    local confirmed = db.vendorPaid and db.vendorPaid[outID]
    if vendorProfit and confirmed and (vendorProfit > 0 or not ahProfit or vendorProfit >= ahProfit) then profit, route = vendorProfit, "Vendor" end
    -- craft it and disenchant it: when the dust/essence is worth more than selling the item
    local deProfit
    if self.Synergy and outID and not missing and self.Synergy:CanDisenchant(outID) then
        local v = self.Synergy:Value(outID)
        if v then deProfit = v * (r.qty or 1) - cost end
        if deProfit and (not profit or deProfit > profit) then profit, route = deProfit, "Disenchant" end
    end
    return {
        mode = mode, cost = (not missing) and cost or nil, outID = outID,
        quality = quality, qualityUsed = qFallback or quality,
        sell = sell, ahProfit = ahProfit, vSell = vSell, vendorProfit = vendorProfit,
        profit = profit, route = route, deProfit = deProfit,
    }
end

-- One entry per known recipe, best profit first.
-- Recipes with quality-ranked materials are worked out both ways: cheapest (low-quality) materials,
-- and top-quality materials for the top crafted quality. The better one is used unless you pick.
function PC:Analyze()
    return self:WithMemo(self.AnalyzeRaw, self)
end
function PC:AnalyzeRaw()
    local out = {}
    self._omap = nil -- recipes may have changed since last time
    local today, minPct = self:SecondsToday(), self:MinProfitPct()
    local needSales = db.needSalesToday ~= false
    for recipeID, r in pairs(self:ShownRecipes()) do
        local quality, qualitySet = self:CraftQuality(r)
        local low = self:Evaluate(r, "low", quality)
        local high
        if r.outputs and self:HasRankedMats(r) then
            high = self:Evaluate(r, "high", #r.outputs)
        end
        local pick = cdb.matsPick and cdb.matsPick[r.name]
        local best = low
        if high then
            if pick == "high" then
                best = high
            elseif pick ~= "low" and high.profit and (not low.profit or high.profit > low.profit) then
                best = high
            end
        end

        local qualities
        if r.outputs then
            qualities = {}
            for q, id in ipairs(r.outputs) do
                qualities[q] = { id = id, price = self:Price(id), listed = self:Supply()[id] }
            end
        end

        local outID, profit, route, cost = best.outID, best.profit, best.route, best.cost
        -- you chose where it sells (added from Vendor flips, or switched on the Plan page): that wins
        local via = cdb.sellVia and outID and cdb.sellVia[outID]
        if via == "Vendor" and best.vendorProfit then profit, route = best.vendorProfit, "Vendor"
        elseif via == "AH" and best.ahProfit then profit, route = best.ahProfit, "AH" end
        -- How many are already listed, and a "best bet" score that favors items that will actually sell
        local listed = self:Supply()[outID]
        local soldAt, soldMine = self:LastSold(outID)
        -- Sold today (since midnight): estimated from scans, or your own sales if that's more; 0 when unknown
        local est = self:SalesEstimate(outID, today)
        local mine = self:MySales(self:ItemName(outID), today)
        local soldToday = math.max(est or 0, mine or 0)
        local profitPct = (profit and cost and cost > 0) and (profit / cost * 100) or nil
        local score
        -- best bets clear the minimum profit, and an AH craft only when some sold there today and at
        -- least half as many sold today as are listed now (else it won't sell in the window you post it)
        local salesOK = route ~= "AH" or not needSales or soldToday > 0
        local sells, hot = self:SellThroughOf(route, listed, soldToday)
        if profit and profit > 0 and profitPct and profitPct >= minPct and salesOK and sells then
            -- profit potential: the profit on what the market buys in a day (at least one craft); hot
            -- sellers (more sold today than listed) ahead of the rest
            local per = math.max(r.qty or 1, 1)
            local potential
            if route == "Vendor" then
                potential = profit * 20                         -- a vendor buys any amount: counted as 20 a day
            elseif route == "Disenchant" then
                potential = profit / 2                          -- the dust still has to sell
            elseif soldToday > 0 then
                potential = profit * math.max(soldToday / per, 1)
            else
                potential = profit / 3                          -- nothing to go on: be cautious
            end
            score = potential + (hot and self.HOT_TIER or 0)
        end

        out[#out + 1] = {
            id = recipeID,
            r = r,
            cost = cost,
            sell = best.sell and best.sell * r.qty or nil,  -- per craft (used for the math)
            sellEach = best.sell,                           -- one item: matches the AH's unit price
            ahProfit = best.ahProfit,
            vendorSell = best.vSell and best.vSell * r.qty or nil,
            vendorProfit = best.vendorProfit,
            profit = profit,
            route = route,
            deProfit = best.deProfit,
            listed = listed,
            score = score,
            outID = outID,                            -- the exact item priced (which quality rank)
            quality = best.quality,                   -- rank you'll make (nil = item has no ranks)
            qualitySet = qualitySet and best == low,  -- true when you picked the rank yourself
            qualityUsed = best.qualityUsed,           -- rank actually priced (lower if yours has no price yet)
            qualities = qualities,                    -- { [rank] = { id, price, listed } }
            mats = best.mode,                         -- "low" or "high" quality materials
            matsPicked = pick ~= nil and high ~= nil, -- you chose low/high yourself
            low = low, high = high,                   -- both ways worked out (high = nil if it doesn't apply)
            profitPct = profitPct,                    -- return on the mats, the way it's sold
            ahProfitPct = (best.ahProfit and cost and cost > 0) and (best.ahProfit / cost * 100) or nil,
            vendorProfitPct = (best.vendorProfit and cost and cost > 0) and (best.vendorProfit / cost * 100) or nil,
            noSalesToday = route == "AH" and soldToday <= 0 or nil, -- not recommended for the AH (see PC:SalesOK)
            lastSold = soldAt and (time() - soldAt) or nil,   -- seconds ago (sorts newest first)
            lastSoldDays = self:DaysAgo(soldAt),
            soldToday = soldToday,
            soldTodayKnown = est ~= nil or (mine or 0) > 0,
            hot = (score ~= nil and hot) or nil,      -- a best bet selling faster than it's listed
            lastSoldMine = soldMine,
        }
    end
    table.sort(out, function(a, b)
        if a.profit and b.profit then return a.profit > b.profit end
        if a.profit then return true end
        if b.profit then return false end
        return a.r.name < b.r.name
    end)
    return out
end

-- Every item that appears in your recipes, with its price and scan status
function PC:RecipeItems()
    local map = {}
    local function entry(id)
        local e = map[id]
        if not e then
            e = { id = id, made = 0, used = 0 }
            map[id] = e
        end
        return e
    end
    for _, r in pairs(self:ShownRecipes()) do
        for q, id in ipairs(self:OutputIDs(r)) do
            local e = entry(id)
            e.made = e.made + 1
            if r.outputs then e.quality, e.maxQ = q, #r.outputs end
        end
        for _, rg in ipairs(r.reagents) do
            local ranked = self:RankedReagentIDs(rg)
            for q, id in ipairs(ranked) do
                local m = entry(id)
                m.used = m.used + 1
                if #ranked > 1 then m.quality, m.maxQ = q, #ranked end
            end
        end
    end

    local prices, checked = self:Prices(), self:Checked()
    local out = {}
    for id, e in pairs(map) do
        e.name = self:ItemName(id)
        e.ah, e.source = self:Price(id)
        e.vendor = self:VendorCost(id)
        e.checked = checked[id]
        e.listed = self:Supply()[id]
        if not self:IsVendorItem(id) then e.trend, e.usual = self:Trend(id) end -- vendor items: AH listings are usually scams
        if not e.checked and e.ah then
            e.state = 4 -- not scanned, but Auctionator or TSM knows a price
        elseif not e.checked then
            e.state = 1 -- never scanned
        elseif not e.ah then
            e.state = 2 -- scanned, nobody selling
        else
            e.state = 3 -- priced
        end
        out[#out + 1] = e
    end
    -- Problems first, then alphabetical
    table.sort(out, function(a, b)
        if a.state ~= b.state then return a.state < b.state end
        return a.name < b.name
    end)
    return out
end

-- What to buy for a number of crafts, after counting what's already in your bags/bank
-- What to buy for a number of crafts. mode: "low" (cheapest materials) or "high" (top-quality materials);
-- defaults to the way the recipe list priced it
function PC:ShoppingList(entry, crafts, mode)
    mode = mode or entry.mats or "low"
    local list, total, missing = {}, 0, false
    for _, rg in ipairs(entry.r.reagents) do
        local need = rg.n * crafts
        local id, unit, src, rank = self:ReagentFor(rg, mode)
        -- top-quality plan: only that rank counts as "have"; cheap plan: any rank you own counts
        local have = (mode == "high" and rank) and self:ItemCount(id) or self:ReagentCount(rg)
        local buy = math.max(need - have, 0)
        local sub, short, top
        if buy > 0 then
            if unit then
                sub = buy * unit
                if src == "AH" then
                    -- buying a lot climbs the price ladder: the live listings (under a vendor's price,
                    -- then the vendor for the rest)
                    local t, avg, hi, sh = self:EffectiveCost(id, buy)
                    if t then sub, unit, top, short = t, avg, hi, sh end
                end
                total = total + sub
            else
                missing = true
            end
        else
            sub = 0
        end
        list[#list + 1] = { id = id, need = need, have = have, buy = buy, unit = unit, src = src, sub = sub,
            ranks = #self:ReagentIDs(rg), rank = rank, slot = rg, short = short, top = top }
    end
    return list, total, missing
end

-- Standing at a vendor or the auction house, nothing is planned again: what to buy was settled when
-- you walked up, and the only thing watched for is whether you've bought it yet. Every purchase used
-- to set the whole plan going again - the market, every recipe, the lot - which is what made vendors
-- and the auction house stutter.
function PC:AtAStop()
    if self.ahOpen then return true end
    local V = self.VendorBuy
    return (V and V.Open and V:Open()) and true or false
end

function PC:StopShopList(entries, crafts)
    local at = self:AtAStop()
    local f = self.frozenShop
    if not at then
        self.frozenShop = nil
    elseif f and f.plan == self:PlanName() and f.crafts == crafts and (GetTime() - f.t) < 120 and f.sig == self:EntriesSig(entries) then
        -- what's in your bags is the only thing that can have changed while you stand here
        for _, it in ipairs(f.list) do
            if it.high or not (it.slot and it.slot.n) then it.have = self:ItemCount(it.id)
            else it.have = self:ReagentCount(it.slot) end
            -- and so what's still to buy (it used to stay at the amount from when you walked up, so the
            -- Task Button kept offering what you'd already bought)
            it.buy = math.max((it.need or 0) - it.have, 0)
            if it.craft then
                it.buy = it.craft.fromOwn and math.max((it.need or 0) - it.have - (it.craftCover or 0), 0) or 0
            end
        end
        return f.buy, f.list
    end
    local buy = (self.Craft and self.Craft.BuyEntries) and self.Craft:BuyEntries(entries) or entries
    local list = self:CombinedShoppingList(buy, crafts)
    if at then self.frozenShop = { plan = self:PlanName(), crafts = crafts, buy = buy, list = list, t = GetTime(), sig = self:EntriesSig(entries) } end
    return buy, list
end

-- The plan's recipes and counts in one string: the list kept at a stop is only kept while it's the same
-- (a count changed, the plan amended, a craft made: what to buy is worked out again)
function PC:EntriesSig(entries)
    local parts = {}
    for _, e in ipairs(entries or {}) do
        parts[#parts + 1] = tostring(e.id) .. "/" .. tostring(e.planCount) .. "/" .. tostring(e.mats) .. "/" .. tostring(e.sub)
    end
    table.sort(parts)
    return table.concat(parts, ":")
end

-- the plan changed, or something was crafted: what to buy is worked out again next time
function PC:ForgetStopList() self.frozenShop = nil end

-- One materials list for several recipes: the same material needed by two recipes is added together
-- (the same list is asked for several times in one refresh: worked out once per refresh)
function PC:CombinedShoppingList(entries, crafts)
    local memo = self:Memo()
    if not memo then return self:CombinedShoppingListRaw(entries, crafts) end
    local parts = { "shop", tostring(crafts) }
    for _, e in ipairs(entries) do
        parts[#parts + 1] = tostring(e.id) .. "/" .. tostring(e.planCount) .. "/" .. tostring(e.mats) .. "/" .. tostring(e.sub)
    end
    local key = table.concat(parts, ":")
    local c = memo[key]
    if not c then
        local t0 = debugprofilestop and debugprofilestop()
        c = { self:CombinedShoppingListRaw(entries, crafts) }
        if t0 and db then
            if type(db.perf) ~= "table" or db.perf.v ~= PC.BUILD then db.perf = { v = PC.BUILD } end
            local p = db.perf.shopList
            if not p then p = { n = 0, total = 0, max = 0 }; db.perf.shopList = p end
            local ms = debugprofilestop() - t0
            p.n, p.total, p.last = p.n + 1, p.total + ms, ms
            if ms > p.max then p.max = ms end
        end
        memo[key] = c
    end
    return c[1], c[2], c[3]
end

function PC:CombinedShoppingListRaw(entries, crafts)
    local byID, list, total, missing = {}, {}, 0, false
    for _, e in ipairs(entries) do
        for _, rg in ipairs(e.r.reagents) do
            local mode = e.mats or "low"
            local bestID, unit, src, rank = self:ReagentFor(rg, mode)
            local it = byID[bestID]
            if not it then
                local have = (mode == "high" and rank) and self:ItemCount(bestID) or self:ReagentCount(rg)
                it = { id = bestID, need = 0, have = have, unit = unit, src = src, high = (mode == "high" and rank) and true or nil,
                    ranks = #self:ReagentIDs(rg), rank = rank, slot = rg, usedBy = {} }
                byID[bestID] = it
                list[#list + 1] = it
            end
            it.need = it.need + rg.n * (e.planCount or crafts)
            it.usedBy[#it.usedBy + 1] = e.planCount and (e.r.name .. " x" .. e.planCount) or e.r.name
        end
    end
    -- tools a recipe needs that you don't have (a runed rod): if you can make one, it's a craft step too
    if self.Craft and self.Craft.Tool then
        for _, e in ipairs(entries) do
            local name, has, id = self.Craft:Tool(e)
            local inBank = id and self.Bank and self.Bank:Known() and self.Bank:Count(id) > 0
            if id and has == false and not inBank and not byID[id] and self:RecipeFor(id) then
                local it = { id = id, need = 1, have = 0, unit = nil, src = "Craft", tool = true, slot = {}, ranks = 1, usedBy = { e.r.name .. " (tool)" } }
                byID[id] = it
                list[#list + 1] = it
            end
        end
    end
    -- vertical crafting: a material that's cheaper to make becomes a craft step plus its own materials
    -- (the list grows while this runs, so the new materials get the same treatment)
    local i = 0
    while i < #list do
        i = i + 1
        local it = list[i]
        local short = math.max(it.need - it.have, 0)
        local cc, rid, r, yield, own
        if short > 0 and (it.src == "Craft" or it.src == "Disenchant") then
            if it.src == "Disenchant" and self.Synergy then
                cc, rid, r, yield = self.Synergy:DECost(it.id)
            else
                cc, rid, r = self:CraftCost(it.id)
                if not r then rid, r = self:RecipeFor(it.id) end -- a price may be missing: still a craft step
            end
        elseif short > 0 and cdb.vertical ~= false then
            -- cheaper to buy, but you already have what makes it: make it from that instead of buying
            -- (as many as your materials cover; only the rest is bought)
            local orid, or_ = self:RecipeFor(it.id)
            if or_ and or_.reagents and #or_.reagents > 0 then
                local per = math.max(or_.qty or 1, 1)
                local can = math.huge
                for _, rg in ipairs(or_.reagents) do
                    local bestID = self:ReagentFor(rg, "low")
                    local used = byID[bestID] and byID[bestID].need or 0
                    can = math.min(can, math.floor((self:ReagentCount(rg) - used) / math.max(rg.n, 1)))
                end
                local n = math.min(can, math.ceil(short / per))
                if n > 0 then rid, r, own = orid, or_, n end
            end
        end
        if r then
            do
                local per = yield or math.max(r.qty or 1, 1)
                it.craft = { id = rid, r = r, n = own or math.ceil(short / per), disenchant = yield and true or nil, fromOwn = own and true or nil }
                it.craftUnit = cc
                if own then it.craftCover = own * per end
                for _, rg in ipairs(r.reagents) do
                    local bestID, unit, src, rank = self:ReagentFor(rg, "low")
                    local sub = byID[bestID]
                    if not sub then
                        sub = { id = bestID, need = 0, have = self:ReagentCount(rg), unit = unit, src = src,
                            ranks = #self:ReagentIDs(rg), rank = rank, slot = rg, usedBy = {} }
                        byID[bestID] = sub
                        list[#list + 1] = sub
                    end
                    sub.need = sub.need + rg.n * it.craft.n
                    sub.usedBy[#sub.usedBy + 1] = r.name .. " x" .. it.craft.n
                        .. (it.craft.disenchant and (" (to disenchant for " .. (self:ItemName(it.id) or "dust") .. ")") or "")
                end
            end
        end
    end
    for _, it in ipairs(list) do
        it.buy = math.max(it.need - it.have, 0)
        if it.craft then
            -- made, not bought: its materials are on the list instead (made from what you have: the
            -- rest, if your materials don't cover it all, is still bought)
            it.buy = it.craft.fromOwn and math.max(it.need - it.have - (it.craftCover or 0), 0) or 0
        end
        if it.buy == 0 then
            it.sub = 0
        elseif it.unit then
            it.sub = it.buy * it.unit
            if it.src == "AH" then
                local t, avg, hi, sh = self:EffectiveCost(it.id, it.buy)
                if t then it.sub, it.unit, it.top, it.short = t, avg, hi, sh end
            end
            total = total + it.sub
        else
            missing = true
        end
    end
    -- Most expensive to buy first
    table.sort(list, function(a, b) return (a.sub or math.huge) > (b.sub or math.huge) end)
    return list, total, missing
end

-- Only what's in your bags right now (not the bank)
function PC:BagCount(itemID)
    if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(itemID, false, false, false) or 0 end
    return GetItemCount(itemID, false) or 0
end

-- Can your gold pay for one craft's materials? Same price as the Materials column, minus materials already
-- in your BAGS (bank doesn't count: you'd have to go get them). Unknown prices count as "no".
function PC:CanAfford(entry)
    if not entry.cost then return false end
    local spend = 0
    for _, rg in ipairs(entry.r.reagents) do
        local id, unit = self:ReagentFor(rg, entry.mats)
        if not unit then return false end
        local have = 0
        for _, rid in ipairs(self:ReagentIDs(rg)) do have = have + self:BagCount(rid) end
        if entry.mats == "high" and id then have = self:BagCount(id) end
        spend = spend + math.max(rg.n - have, 0) * unit
    end
    return spend <= self:Gold()
end

-- How many rounds of crafts (one of each recipe) your gold covers
function PC:MaxAffordableMulti(entries)
    local money, n = self:Gold(), 0
    for c = 1, self.MAX_AFFORD_CHECK do
        local _, total, missing = self:CombinedShoppingList(entries, c)
        if missing or total > money then break end
        n = c
    end
    return n
end

-- How many crafts your current gold covers
function PC:MaxAffordable(entry, mode)
    local money = self:Gold()
    local n = 0
    for c = 1, self.MAX_AFFORD_CHECK do
        local _, total, missing = self:ShoppingList(entry, c, mode)
        if missing or total > money then break end
        n = c
    end
    return n
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
-- Any error is caught and shown in chat (retail hides addon errors by default)
local reported = {}
function PC:ReportError(where, err)
    local msg = tostring(err)
    -- kept (saved with your settings) so it can be read back and fixed: the last 10
    PC.lastError = ("%s: %s"):format(tostring(where), msg)
    if db then
        db.errors = db.errors or {}
        local last = db.errors[#db.errors]
        if not (last and last.msg == msg) then
            table.insert(db.errors, { t = date("%Y-%m-%d %H:%M:%S"), where = tostring(where), msg = msg, v = PC.VERSION })
            while #db.errors > 10 do table.remove(db.errors, 1) end
        end
    end
    if reported[msg] then return end
    reported[msg] = true
    print(("|cffff5555%s error (%s):|r %s"):format(PC.NAME or "ProfitCrafter", tostring(where), msg))
    print("|cffff5555Please send this message (a screenshot is fine) so it can be fixed.|r")
end

function PC:Safe(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then self:ReportError(where, err) end
    return ok
end

PC:SetScript("OnEvent", function(self, event, ...)
    local fn = self[event]
    if fn then self:Safe(event, fn, self, ...) end
end)

for _, e in ipairs({
    "ADDON_LOADED", "PLAYER_LOGIN", "SKILL_LINES_CHANGED",
    "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE",
    "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "REPLICATE_ITEM_LIST_UPDATE",
    "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
    "MERCHANT_SHOW", "MERCHANT_CLOSED", "PLAYER_MONEY", "BAG_UPDATE_DELAYED", "GET_ITEM_INFO_RECEIVED",
}) do
    pcall(PC.RegisterEvent, PC, e) -- pcall: ignore any event this game version lacks
end
-- Crafting: every finished craft is a "spell cast" whose ID is the recipe ID
if PC.RegisterUnitEvent then pcall(PC.RegisterUnitEvent, PC, "UNIT_SPELLCAST_SUCCEEDED", "player")
else pcall(PC.RegisterEvent, PC, "UNIT_SPELLCAST_SUCCEEDED") end

-- Each craft of a recipe in your Crafting plan counts down; at 0 it leaves the plan
function PC:UNIT_SPELLCAST_SUCCEEDED(unit, _, spellID)
    if unit ~= "player" or not spellID or not cdb or not cdb.plans then return end
    if cdb.recipes[spellID] then
        self.craftingUntil = GetTime() + 1.5 -- the next one of a batch starts within this
        self:Safe("crafting cost", self.NoteCrafted, self, cdb.recipes[spellID])
    end
    if self.CraftedOne then
        -- the game's spell number can differ from the recipe's: match by name then
        local r = cdb.recipes[spellID]
        if not r then
            local name
            if C_Spell and C_Spell.GetSpellName then local ok, n = pcall(C_Spell.GetSpellName, spellID); name = ok and n or nil end
            if not name and GetSpellInfo then local ok, n = pcall(GetSpellInfo, spellID); name = ok and n or nil end
            if type(name) == "string" and not self.IsSecret(name) then
                for _, rr in pairs(cdb.recipes) do if rr.name == name then r = rr break end end
            end
        end
        if r then self:Safe("crafted note", self.CraftedOne, self, r) end
    end
    -- any recipe you know that needs a station: remember where you were standing when it worked
    -- (whether or not it's in a plan, and however you started it) and share that spot
    local r0 = cdb.recipes[spellID]
    if r0 and self.Craft and self.Places then
        local station = self.Craft:Station({ id = spellID, r = r0 })
        if station then
            self.stationSeen = self.stationSeen or {}
            if GetTime() - (self.stationSeen[station] or 0) > 30 then -- once per half minute is plenty
                self.stationSeen[station] = GetTime()
                self.Places:Learn("station", station)
            end
        end
    end
    local plan = self:CurrentPlan()
    local left = plan[spellID]
    if not left then return end
    left = left - 1
    local r = cdb.recipes[spellID]
    local name = r and r.name or "that recipe"
    -- remember what you crafted from your plan: only those go on the Sell tab and Next step
    cdb.planCrafted = cdb.planCrafted or {}
    -- (and which plan they were for: an older plan's leftovers are never posted for this one)
    cdb.planCraftedPlan = cdb.planCraftedPlan or {}
    if r then
        local pn = self:PlanName()
        self:ForgetStopList() -- a craft uses materials up: what's left to buy is worked out again
        if r.output then cdb.planCrafted[r.output] = time(); cdb.planCraftedPlan[r.output] = pn end
        -- how many this plan made (a skill-up plan sells just those, never the rest of your stack)
        if r.output then
            cdb.planMadeN = cdb.planMadeN or {}
            cdb.planMadeN[pn] = cdb.planMadeN[pn] or {}
            cdb.planMadeN[pn][r.output] = (cdb.planMadeN[pn][r.output] or 0) + math.max(r.qty or 1, 1)
        end
        for _, o in ipairs(r.outputs or {}) do cdb.planCrafted[o] = time(); cdb.planCraftedPlan[o] = pn end
    end
    local pn = self:PlanName()
    local saved = not self:IsTempPlan(pn)
    if saved then
        self:SyncPlanTemplates() -- the full list is up to date before this one counts down
        cdb.planDone[pn] = cdb.planDone[pn] or {}
        cdb.planDone[pn][spellID] = (cdb.planDone[pn][spellID] or 0) + 1
    end
    if left <= 0 then
        plan[spellID] = nil
        if saved and next(plan) == nil then cdb.planFin = cdb.planFin or {}; cdb.planFin[pn] = true end
        if not saved and next(plan) == nil then self:Sound("done") end
        Print(("|cff40ff40Done crafting %s.|r %s"):format(name, saved and "Done for this run (it stays in your saved plan)." or "Removed it from your crafting plan."))
        if saved and self:PlanFinished(pn) then
            Print(("|cff40ff40Plan \"%s\" finished.|r It's saved: pick it in the plan menu to run it again."):format(pn))
            self:Sound("done")
        end
    else
        plan[spellID] = left
    end
    self:RefreshUI()
end

-- On /reload or logout: a note of what's in your bags and your gold (saved with your settings), so
-- "where did my gold go" can be answered from the records
function PC:PLAYER_LOGOUT()
    -- friendly NPC nameplates turned on for the star: back the way you had them
    if PC.Places and PC.Places.NpcPlates then pcall(PC.Places.NpcPlates, PC.Places, false) end
    if not cdb then return end
    local ok, counts = pcall(self.BagCounts, self)
    cdb.bagSnap = { t = time(), gold = GetMoney and GetMoney() or nil, items = ok and counts or nil }
end
pcall(PC.RegisterEvent, PC, "PLAYER_LOGOUT")

function PC:ADDON_LOADED(name)
    if name ~= ADDON then return end
    InitDB()
    self:UnregisterEvent("ADDON_LOADED")
end

function PC:PLAYER_LOGIN()
    -- gold changes from here on count for the All gold view (what changed while logged out doesn't)
    self:TrackGold()
    self.goldReady = true
    pcall(self.TrimSaved, self)
    self:UpdateProfessions()
    self:SetupTradeTracking()
    -- the star key: Page Up, the first time (change it under Key Bindings > AddOns > ProfitCrafter)
    if db and not db.starKeyDone and SetBinding and GetBindingKey and not (InCombatLockdown and InCombatLockdown()) then
        if not GetBindingKey("PROFITCRAFTER_STAR") then
            if SetBinding("PAGEUP", "PROFITCRAFTER_STAR") then
                db.starKeyDone = true
                if SaveBindings and GetCurrentBindingSet then pcall(SaveBindings, GetCurrentBindingSet()) end
            end
        else
            db.starKeyDone = true
        end
    end
    -- made-up crossings saved by older versions (a hearthstone or summon read as a portal): once
    if db and not db.linkFix1 and PC.Travel and PC.Travel.DropFakeLinks then
        db.linkFix1 = true
        pcall(PC.Travel.DropFakeLinks, PC.Travel)
    end
    Print("v" .. PC.VERSION .. " loaded. Type /pc to open the window, or /pc status to check that everything is working.")
    -- new files but the game still has the old file list (a /reload doesn't re-read it): say so
    if (PC.BUILD ~= "dev" and PC.TOC_VERSION ~= PC.BUILD) or not (PC.Next and PC.News and PC.MakeGold and PC.UI and PC.UI.Popup) then
        Print("|cffff8040Half-updated: the game is still using the old file list. Quit and restart the game (a /reload isn't enough) so every new file loads.|r")
    end
    if not next(cdb.recipes) then
        Print("Open each of your profession windows once so I can learn your recipes. Type /pc to open the window.")
    end
end

function PC:SKILL_LINES_CHANGED()
    self:Debounce("profs", 0.5, function() self:UpdateProfessions() end)
end

function PC:TRADE_SKILL_SHOW()
    self:Debounce("recipes", 0.5, function() self:ReadRecipes() end)
end
-- The list updates after every single craft (counts, skill-ups): it waits until the batch is over
function PC:TRADE_SKILL_LIST_UPDATE()
    self:Debounce("recipes", 0.5, function()
        self:WhenIdle("recipes", function() self:ReadRecipes() end)
    end)
end

PC.AUTO_SCAN_EVERY = 3600 -- seconds between automatic full scans

function PC:AUCTION_HOUSE_SHOW()
    self.ahOpen = true
    -- Start the scan first, so nothing else can stop it
    -- auto-scan at most once an hour: scanned within the hour, the prices are fresh enough
    -- (the item-by-item reads for buying and posting still happen as usual)
    local last = db.scanTime[self:Faction()]
    local fresh = last and time() - last < self.AUTO_SCAN_EVERY
    if db.autoScan and fresh then
        Print(("Auction House opened. Prices are from %d min ago: no full scan until the hour's up (Scan auctions to do one now)."):format(math.floor((time() - last) / 60)))
    elseif db.autoScan then
        Print("Auction House opened.")
        C_Timer.After(2.5, function() self:Safe("auto scan", self.StartScan, self, true) end)
    else
        Print("Auction House opened. Auto-scan is off: click Scan auctions or type /pc scan.")
    end
    -- Add the ProfitCrafter tab once the game has finished building the AH window
    C_Timer.After(0.1, function()
        if self.UI and self.ahOpen then self:Safe("Auction House tab", self.UI.OnAHShow, self.UI) end
    end)
    self:RefreshUI()
end

function PC:AUCTION_HOUSE_CLOSED()
    self.ahOpen = false
    if self.UI and self.UI.OnAHClosed then self.UI:OnAHClosed() end
    if self.scanning and self.scanMode == "quick" then
        self:EndScan(false, "Scan stopped because the Auction House closed. Prices found so far were kept.",
            "Scan stopped: the Auction House closed.")
    end
    self:RefreshUI()
end

-- The AH window is the truth: if it's showing and the open event was missed (or a stray close event
-- came in while it's still up), catch up - so "Go to the AH" never shows while you're standing at it
-- Talking to that kind of NPC right now? (the game's own answer: works whatever bag/bank addon
-- replaces the window - EllesmereUI's bank, for one, never shows the game's BankFrame)
local function Interacting(kind)
    local M = C_PlayerInteractionManager
    local E = Enum and Enum.PlayerInteractionType
    if not (M and M.IsInteractingWithNpcOfType and E and E[kind]) then return false end
    local ok, yes = pcall(M.IsInteractingWithNpcOfType, E[kind])
    return ok and yes and true or false
end
PC.Interacting = Interacting
local function AHFrameShown()
    for _, name in ipairs({ "AuctionHouseFrame", "AuctionFrame" }) do
        local f = _G[name]
        if f and f.IsShown and f:IsShown() then return true end
    end
    return Interacting("Auctioneer")
end
PC.AHFrameShown = AHFrameShown
local ahWasShown, bankWasShown = false, false
function PC:WatchAH()
    local shown = AHFrameShown()
    if shown and not self.ahOpen then self:Safe("Auction House", self.AUCTION_HOUSE_SHOW, self)
    elseif ahWasShown and not shown and self.ahOpen then self:Safe("Auction House", self.AUCTION_HOUSE_CLOSED, self) end
    ahWasShown = shown
    -- the bank the same way: its window up but the open event missed = "Go to the bank" while you're at it
    local B = self.Bank
    if B and B.OnEvent then
        local bf = _G.BankFrame
        local bshown = (bf and bf.IsShown and bf:IsShown()) or Interacting("Banker") or false
        if bshown and not B.open then B:OnEvent("BANKFRAME_OPENED")
        elseif bankWasShown and not bshown and B.open then B:OnEvent("BANKFRAME_CLOSED") end
        bankWasShown = bshown
    end
end
do
    local w, acc = CreateFrame("Frame"), 0
    w:SetScript("OnUpdate", function(_, dt)
        acc = acc + (dt or 0)
        if acc >= 1 then acc = 0; PC:WatchAH() end
    end)
end

function PC:REPLICATE_ITEM_LIST_UPDATE()
    self:ProcessScan()
end

function PC:AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
    if self.scanMode == "quick" and self.quick and self.quick.batch then
        -- all of them in (the AH says so): read them now; else they can arrive in pieces: a moment for the rest
        local A = C_AuctionHouse
        if A.HasFullBrowseResults and A.HasFullBrowseResults() then
            self:Debounce("browse", 0, function() self:ScanStep(self.QuickResultsArrived) end)
        else
            self:Debounce("browse", 0.5, function() self:ScanStep(self.QuickResultsArrived) end)
        end
    end
end
PC.AUCTION_HOUSE_BROWSE_RESULTS_ADDED = PC.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED

function PC:AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
    if self.quick and self.quick.waitingThrottle then self:ScanStep(self.QuickNextBatch) end
end

-- Leftover materials: kept (the bank holds them for the next craft) unless you switch selling back on
function PC:SellLeftovers() return self.db and self.db.sellLeftovers == true end

-- Materials for a later stage: used only by crafts that wait on something still being disenchanted
-- (the oil waits on the dust from the greens). They're not bought or taken from the bank yet, and
-- they go in the bank until that stage comes. { [itemID] = true }
function PC:LaterMats(list)
    local memo = self:Memo()
    if memo and list and memo.laterFor == list then return memo.later end
    local later = {}
    if not list then
        if not (self.UI and self.UI.PlanEntries) then return later end
        local ok, l = pcall(self.CombinedShoppingList, self, self.UI:PlanEntries(), 1)
        if not ok then return later end
        list = l
    end
    local pending = {}
    for _, it in ipairs(list) do
        if it.craft and it.craft.disenchant and (it.have or 0) < (it.need or 0) then pending[it.id] = true end
    end
    if not next(pending) then return later end
    local recipes = {}
    for _, e in ipairs(self.UI and self.UI.PlanEntries and self.UI:PlanEntries() or {}) do recipes[#recipes + 1] = e.r end
    for _, it in ipairs(list) do if it.craft and it.craft.r then recipes[#recipes + 1] = it.craft.r end end
    local now, wait = {}, {}
    for _, r in ipairs(recipes) do
        local blocked = false
        for _, rg in ipairs(r.reagents or {}) do
            for _, id in ipairs(self:ReagentIDs(rg)) do if pending[id] then blocked = true end end
        end
        for _, rg in ipairs(r.reagents or {}) do
            for _, id in ipairs(self:ReagentIDs(rg)) do
                if blocked then wait[id] = true else now[id] = true end
            end
        end
    end
    for id in pairs(wait) do if not now[id] then later[id] = true end end
    if memo and list then memo.laterFor, memo.later = list, later end
    return later
end

-- Free slots in a reagent bag (crafting materials only)
function PC:FreeReagentBagSlots()
    local C = C_Container
    local fn = (C and C.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
    if not fn then return 0 end
    local free = 0
    for _, bag in ipairs(self:PlayerBags()) do
        if self:BagKind(bag) == "reagent" then free = free + (fn(bag) or 0) end
    end
    return free
end

-- Buy in batches only when your bags can't take the whole plan: as much as fits, using every free
-- slot - the materials (reagent bag first, then your bags) plus room for what gets crafted from them,
-- always leaving a slot free. 1 = everything fits.
-- (worked out once per refresh: the task list and the Task Button both ask for it)
function PC:BatchScale(list, later, matsOnly)
    if not list then return 1 end
    local memo = self:Memo()
    local key = (matsOnly and "batchM" or "batch")
    if memo and memo[key .. "For"] == list then return memo[key] end
    local k = self:BatchScaleRaw(list, later, matsOnly)
    if memo then memo[key .. "For"], memo[key] = list, k end
    return k
end

function PC:BatchScaleRaw(list, later, matsOnly)
    if not list then return 1 end
    later = later or {}
    local vend = {}
    for _, it in ipairs(list) do
        -- only what a vendor hands you: AH purchases wait in the mailbox, not your bags
        local v = (it.buy and it.buy > 0 and not later[it.id] and self.UI and self.UI.VendorQty) and self.UI:VendorQty(it) or 0
        if v > 0 then vend[#vend + 1] = { id = it.id, qty = v } end
    end
    if #vend == 0 then return 1 end
    -- materials bought on the AH and waiting in the mail: they need room once they're taken out
    local mail = {}
    for _, it in ipairs(list) do
        local m = (not later[it.id] and self.MailPending) and math.min(self:MailPending(it.id), it.need or 0) or 0
        if m > 0 then mail[#mail + 1] = { id = it.id, qty = m } end
    end
    -- what the plan crafts now: only the room its finished items take beyond the slots their materials
    -- free up as they're used (as the plan's own bag check counts it: 1 clam + 1 spice make 1 clam dish,
    -- no extra room; gear, a slot each, can need more than its materials took)
    local outs = {}
    local entries = (not matsOnly and self.UI and self.UI.PlanEntries) and self.UI:PlanEntries() or {}
    if not matsOnly and self.Craft and self.Craft.BuyEntries then entries = self.Craft:BuyEntries(entries) end
    local skill = self.UI and self.UI.IsSkillPlan and self.UI:IsSkillPlan()
    for _, e in ipairs(entries) do
        local out = (e.disenchant and e.r.output) or e.outID or e.r.output
        local n = (e.planCount or 0) * math.max(e.r.qty or 1, 1)
        if out and n > 0 and not (skill or e.route == "Vendor" or e.route == "Disenchant") then
            local mats = {}
            for _, rg in ipairs(e.r.reagents or {}) do
                local rid = self:ReagentFor(rg, e.mats)
                if rid then mats[#mats + 1] = { id = rid, per = rg.n * (e.planCount or 0) } end
            end
            outs[#outs + 1] = { id = out, qty = n, mats = mats }
        end
    end
    local plain = self:FreeBagSlotsOnly() - (self.BUY_RESERVE or 1)
    local reagentBag = self:FreeReagentBagSlots()
    -- (only materials in your bags or bought here free room as they're used: AH ones still to buy take none yet)
    local inBags, vendQ, mailQ = {}, {}, {}
    -- (held in the reagent bag, a material frees no room for what's made)
    local plainHeld = {}
    for _, sl in ipairs(self.BagSlots and self.BagSlots() or {}) do
        if self:BagKind(sl.bag) ~= "reagent" then plainHeld[sl.id] = (plainHeld[sl.id] or 0) + sl.n end
    end
    for _, x in ipairs(outs) do for _, m in ipairs(x.mats) do inBags[m.id] = plainHeld[m.id] or 0 end end
    for _, m in ipairs(vend) do vendQ[m.id] = m.qty end
    for _, m in ipairs(mail) do mailQ[m.id] = m.qty end
    local function fits(k)
        local mats = 0
        for _, m in ipairs(vend) do mats = mats + self:SlotsFor(m.id, math.floor(m.qty * k)) end
        for _, m in ipairs(mail) do mats = mats + self:SlotsFor(m.id, math.ceil(m.qty * k)) end
        local inReagent = math.min(mats, reagentBag)
        local o, credit, left = 0, 0, {}
        for _, x in ipairs(outs) do
            local freed = 0
            for _, m in ipairs(x.mats) do
                if not left[m.id] then
                    left[m.id] = inBags[m.id] + math.floor((vendQ[m.id] or 0) * k) + math.ceil((mailQ[m.id] or 0) * k)
                end
                local use = math.min(m.per * k, left[m.id])
                left[m.id] = left[m.id] - use
                freed = freed + math.ceil(use / math.max(self:StackSize(m.id), 1))
            end
            local slots = self:SlotsFor(x.id, math.ceil(x.qty * k))
            o = o + math.max(slots - freed, 0)
            credit = credit + math.min(slots, freed)
        end
        -- (materials used up from the reagent bag free no room for what's made)
        return mats - inReagent + o + math.min(inReagent, credit) <= plain
    end
    if fits(1) then return 1 end
    if plain <= 0 or not fits(0.02) then return 0 end
    local lo, hi = 0.02, 1
    for _ = 1, 12 do
        local mid = (lo + hi) / 2
        if fits(mid) then lo = mid else hi = mid end
    end
    return lo
end

function PC:MERCHANT_SHOW()
    self.merchantOpen = true
    self:Timed("vendor", self.CaptureVendor, self)
    self:VendorOpen()
    self:RefreshUI()
end

function PC:MERCHANT_CLOSED()
    self.merchantOpen = false
    self:RefreshUI()
    self:VendorCheck()
    self.vendorVisit = nil
end

function PC:PLAYER_MONEY()
    self:TrackGold()
    self:CheckPostingFee()
    self:VendorMoney()
    self:RefreshUI()
end
function PC:BAG_UPDATE_DELAYED()
    if self.vendorVisit then self:VendorSoon() end
    self:Downtime("ui", function() PC:RefreshUI(true) end)
end
-- item names and icons arriving (often hundreds at login): one refresh once they've settled
function PC:GET_ITEM_INFO_RECEIVED() self:Debounce("iteminfo", 1.5, function() self:RefreshUI() end) end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
-- /rl reloads the UI (handy while testing; /pc reload does the same)
SLASH_PCRELOAD1 = "/rl"
SlashCmdList.PCRELOAD = function() if ReloadUI then ReloadUI() end end

SLASH_PROFITCRAFTER1 = "/pc"
SLASH_PROFITCRAFTER2 = "/profitcrafter"
SlashCmdList.PROFITCRAFTER = function(msg) PC:Safe("/pc " .. tostring(msg), PC.HandleSlash, PC, msg) end
function PC:HandleSlash(msg)
    local raw = strtrim(msg or "")
    msg = raw:lower()
    if msg == "scan" then
        PC:StartScan()
    elseif msg == "fullscan" then
        PC:StartFullScan()
    elseif msg == "items" then
        if PC.UI then PC.UI:OpenTab(3) end
    elseif msg == "icon" or msg == "icons" then
        if PC.UI then PC.UI:ToggleIconPicker() end
    elseif msg == "config" or msg == "settings" or msg == "options" then
        if PC.Options then PC.Options:Open() end
    elseif msg == "resetprices" then
        wipe(PC:Prices()); wipe(PC:Checked()); wipe(PC:Supply()); wipe(PC:Source())
        Print("All Auction House prices cleared. Open the Auction House and scan to get fresh ones.")
        PC:RefreshUI()
    elseif msg == "layout" then
        if PC.Steps then PC.Steps:ToggleLayout() end
    elseif msg == "minimap" then
        db.minimap = db.minimap or {}
        db.minimap.hide = not db.minimap.hide
        if PC.UI then PC.UI:UpdateMinimapButton() end
        Print("Minimap button: " .. (db.minimap.hide and "hidden" or "shown"))
    elseif msg == "ahtab" then
        db.openOnAH = (db.openOnAH == false)
        Print("Open ProfitCrafter automatically when the Auction House opens: " .. (db.openOnAH and "ON" or "OFF"))
    elseif (msg == "share" or msg == "share on" or msg == "share off") and PC.FOREVER then
        Print("Unknown command. Type /pc help for the list.")
    elseif msg == "share" then
        Print("Price sharing (addon messages are hidden, so the channel always looks empty):")
        if PC.Share then for _, line in ipairs(PC.Share:StatusLines()) do Print("  " .. line) end end
        Print("  |cff888888/pc share on  or  /pc share off  to change it.|r")
    elseif msg == "share on" or msg == "share off" then
        db.share = (msg == "share on")
        Print("Sharing prices with other ProfitCrafter users: " .. (db.share and "ON" or "OFF"))
        if PC.Share then
            if db.share then
                PC.Share:JoinChannel()
                C_Timer.After(2, function() PC.Share:Request(true) end)
            else
                PC.Share:LeaveChannel()
            end
        end
        PC:RefreshUI()
    elseif msg == "pnl" then
        if PC.UI then PC.UI:OpenTab(4) end
    elseif msg == "plan" or msg == "plans" then
        Print(("Crafting plans (current: %s): %s"):format(PC:PlanName(), table.concat(PC:PlanNames(), ", ")))
        Print("/pc plan <name> - switch to (or create) a crafting plan")
    elseif msg:match("^plan ") then
        local name = strtrim(raw:sub(6))
        local found
        for n in pairs(PC:Plans()) do if n:lower() == name:lower() then found = n end end
        if found then PC:SwitchPlan(found) else PC:NewPlan(name) end
        Print(("Crafting plan: \"%s\"."):format(PC:PlanName()))
        if PC.UI and PC.UI.WarnPlanBudget then PC.UI:WarnPlanBudget() end
        if PC.UI then PC.UI:OpenTab(2) end
        PC:RefreshUI()
    elseif msg == "learned reset" or msg == "learn reset" then
        if PC.Learn then PC.Learn:Reset() end
    elseif msg == "learned" or msg == "learn" then
        if PC.Learn then PC.Learn:Report() end
    elseif msg == "online" or msg == "users" or msg == "who" then
        if PC.Share then PC.Share:Online() end
    elseif msg == "purge stop" or msg == "purge off" or msg == "stop purge" then
        if PC.Sell then PC.Sell:SetPurge(false) end
    elseif msg == "purge" then
        if PC.Sell then if PC.Sell.purge then PC.Sell:SetPurge(false) else PC.Sell:AskPurge() end end
    elseif msg == "bank" then
        -- what ProfitCrafter can tell about the bank right now (for when it doesn't notice you're there)
        local B = PC.Bank
        local bf = _G.BankFrame
        local names = {}
        for _, n in ipairs({ "BankFrame", "BankPanel", "AccountBankPanel", "ContainerFrameCombinedBags" }) do
            local f = _G[n]
            names[#names + 1] = n .. "=" .. (f and (f.IsShown and f:IsShown() and "shown" or "hidden") or "none")
        end
        Print(("Bank: open=%s, talking to a banker=%s, %s"):format(tostring(B and B.open), tostring(PC.Interacting and PC.Interacting("Banker")), table.concat(names, ", ")))
        Print("Bank events seen: " .. ((B and B.seen and table.concat(B.seen, ", ")) or "none"))
    elseif msg:match("^star") then
        if PC.Places and PC.Places.MarkStar then PC:Safe("star", PC.Places.MarkStar, PC.Places) end
    elseif msg:match("^elevator") then
        if PC.Travel then PC.Travel:MarkElevator(msg:match("^elevator%s*(.*)$")) end
    elseif msg:match("^barter") then
        local arg = msg:match("^%S+%s+(%S+)")
        local n = tonumber(arg)
        if not PC.FOREVER then
            Print("Bartering is a WoW Forever legacy perk; it doesn't apply here.")
        elseif n and n >= 0 and n <= PC.BARTER_MAX then
            db.barterSet = math.floor(n)
            Print(("Bartering set to %d point%s: vendors charge you %d%% less."):format(db.barterSet, db.barterSet == 1 and "" or "s", db.barterSet * 5))
            PC:RefreshUI()
        elseif arg == "auto" then
            db.barterSet = nil
            Print(("Bartering: worked out at vendors (now %d point%s, %d%% off)."):format(PC:BarterRank(), PC:BarterRank() == 1 and "" or "s", PC:BarterRank() * 5))
            PC:RefreshUI()
        else
            Print(("Bartering: %d point%s, vendors charge you %d%% less (%s). Set it with /pc bartering 0, 1, 2 or auto."):format(PC:BarterRank(),
                PC:BarterRank() == 1 and "" or "s", PC:BarterRank() * 5, db.barterSet and "set by you" or "read at vendors"))
        end
    elseif msg == "advanced" or msg == "simple" then
        if PC.Options and PC.Options.SetAdvanced then PC.Options:SetAdvanced(msg == "advanced")
        else db.mode = msg; if PC.UI and PC.UI.LayoutTabs then PC.UI:LayoutTabs() end; PC:RefreshUI() end
        Print(msg == "advanced" and "Advanced Mode on: advanced settings and every tab (Items, Sell, Learn, P&L, History) showing. /pc simple turns it off."
            or "Advanced Mode off: Make me gold, Plan, Recipes and Settings. /pc advanced (or Advanced Mode in Settings) turns it on.")
    elseif msg == "arrow why" then
        if PC.Places and PC.Places.ArrowWhy then PC.Places:ArrowWhy() end
    elseif msg == "where" then
        if PC.Travel and PC.Travel.Where then PC.Travel:Where() end
    elseif msg == "star off" or msg == "star on" then
        db.starPlates = (msg == "star on") and nil or false
        if msg == "star off" and PC.Places and PC.Places.NpcPlates then PC.Places:NpcPlates(false) end
        Print(msg == "star on" and "Near your stop, friendly NPC nameplates come on so the star can show over the NPC. /pc star off stops that."
            or "Friendly NPC nameplates are left as you set them. The star shows once the NPC has a nameplate (after you click them). /pc star on turns it back on.")
    elseif msg == "arrow reset" or msg == "arrow" then
        if db then db.arrowPos = nil end
        if PC.Places and PC.Places.PlaceScreenArrow then PC.Places:PlaceScreenArrow() end
        Print("The travel arrow is back at the top of the screen. Drag it to move it.")
    elseif msg == "popups reset" or msg == "popup reset" or msg == "toast reset" then
        if db then db.toastPos = nil end
        if PC.Toast and PC.Toast.Place then PC.Toast:Place() end
        Print("Pop-up notes are back at the top of the screen. Drag one to move them.")
    elseif msg == "sounds" or msg == "sound" then
        -- hear each one, two seconds apart, and see which have their voice clip in this game
        local order = { "start", "sold", "nogold", "warn", "done" }
        for i, k in ipairs(order) do
            C_Timer.After((i - 1) * 2.5, function()
                local how = PC:Sound(k, true)
                Print(("Sound \"%s\": %s"):format(k, how == "clip" and "voice clip" or "plain game sound (clip not found)"))
            end)
        end
    elseif msg == "undo" then
        if PC.Steps and PC.Steps.Undo and PC.Steps:Undo() then return end
        if PC.Next and PC.Next.UndoFlipsSkip then PC.Next:UndoFlipsSkip() end
    elseif msg == "tasks" or msg == "steps" then
        if PC.Steps then PC.Steps:Toggle() end
    elseif msg == "reload" or msg == "rl" then
        if ReloadUI then ReloadUI() end
    elseif msg == "look classic" or msg == "look clean" then
        db.look = msg == "look classic" and "classic" or "clean"
        Print(("Window look: %s. Type /rl to see it."):format(msg == "look classic" and "classic" or "clean"))
    elseif msg == "skin" then
        if PC.UI then PC.UI:MatchProfessionWindow() end
    elseif msg == "skin reset" then
        db.skin = nil
        if PC.UI then PC.UI:ApplySkin() end
        Print("ProfitCrafter is back to its own background.")
    elseif msg == "ticker" then
        db.tickerScreen = not db.tickerScreen
        Print("Screen-wide price ticker: " .. (db.tickerScreen and "ON" or "OFF")
            .. (db.tickerScreen and not db.tickerLocked and " (drag it where you want it, then /pc ticker lock)" or ""))
        if PC.Ticker then PC.Ticker:Apply() end
    elseif msg == "ticker lock" or msg == "ticker unlock" then
        db.tickerLocked = (msg == "ticker lock")
        Print("Screen-wide price ticker: " .. (db.tickerLocked and "locked" or "unlocked (drag it to move)"))
        if PC.Ticker then PC.Ticker:Apply() end
    elseif msg == "history" then
        if PC.UI then PC.UI:OpenTab(5) end
    elseif msg == "auto" then
        db.autoScan = not db.autoScan
        Print("Auto-scan when the Auction House opens: " .. (db.autoScan and "ON" or "OFF"))
    elseif msg == "reset" then
        wipe(cdb.recipes)
        PC.announced = {}
        Print("Recipe list cleared. Open your profession windows again to relearn them.")
        PC:RefreshUI()
    elseif msg == "de" or msg == "disenchant" then
        -- what the Disenchant button is set to, for working out why a click does nothing
        local S, b = PC.Synergy, PC.Synergy and PC.Synergy.secure
        if not b then Print("Disenchant button: not made yet (it's made when there's something to disenchant).")
        else
            local function a(k) return tostring(b:GetAttribute(k)) end
            local bar = PC.Next and PC.Next.bar
            Print(("Disenchant button: shown=%s visible=%s size=%dx%d level=%d (bar button level %d) mouse=%s"):format(
                tostring(b:IsShown()), tostring(b:IsVisible()), b:GetWidth() or 0, b:GetHeight() or 0, b:GetFrameLevel() or 0,
                bar and bar.btn and bar.btn:GetFrameLevel() or 0, tostring(b:IsMouseEnabled())))
            Print(("  type=%s spell=%s bag=%s slot=%s target=%s"):format(a("type"), a("spell"), a("target-bag"), a("target-slot"),
                S.target and S.target.name or "none"))
            Print(("  strata=%s (bar %s) task button takes mouse=%s  last problem: %s"):format(tostring(b:GetFrameStrata()),
                tostring(bar and bar:GetFrameStrata()), tostring(bar and bar.btn and bar.btn:IsMouseEnabled()), tostring(S.lastErr or "none")))
        end
    elseif msg == "status" then
        local nRecipes, nPrices, nVendor = 0, 0, 0
        for _ in pairs(cdb.recipes) do nRecipes = nRecipes + 1 end
        for _ in pairs(PC:Prices()) do nPrices = nPrices + 1 end
        for _ in pairs(db.vendor) do nVendor = nVendor + 1 end
        local yes, no = "|cff40ff40yes|r", "|cffff5555no|r"
        local t = db.scanTime[PC:Faction()]
        local wait = PC:ScanWait()
        Print("Status check:")
        Print("  Addon loaded: " .. yes)
        Print("  Auction House scanning supported: " .. ((C_AuctionHouse and C_AuctionHouse.ReplicateItems) and yes or no))
        Print("  Auction House open right now: " .. (PC.ahOpen and yes or no))
        local A = C_AuctionHouse or {}
        Print("  Buying from the addon: " .. (A.StartCommoditiesPurchase and yes or no) .. "  (item bids: " .. (A.PlaceBid and yes or no)
            .. ", classic search: " .. ((QueryAuctionItems or AuctionFrameBrowse) and yes or no) .. ", classic buyout: " .. (PlaceAuctionBid and yes or no) .. ")")
        Print("  Posting from the addon: " .. ((A.PostCommodity or StartAuction) and yes or no))
        Print("  Scanning right now: " .. (PC.scanning and yes or no))
        Print("  Next full scan allowed: " .. (wait > 0 and ("in %d:%02d"):format(math.floor(wait / 60), wait % 60) or "now"))
        Print("  Last finished scan: " .. (t and (PC:Ago(time() - t) .. " ago") or "never"))
        Print(("  Items with auction prices: %d   Items vendors sell: %d   Recipes known: %d"):format(nPrices, nVendor, nRecipes))
        Print("  Auto-scan when the Auction House opens: " .. (db.autoScan and yes or no))
    elseif msg == "help" then
        Print("/pc - show or hide the window")
        Print("/pc status - check that everything is working")
        Print("/pc scan - check auction prices for your recipes (the Auction House must be open)")
        Print("/pc fullscan - download every auction (once per 15 minutes)")
        Print("/pc items - show every recipe item and whether it was scanned")
        Print("/pc pnl - show your profit and loss")
        Print("/pc tasks - every task of the plan, in order")
        Print("/pc learned - what ProfitCrafter has learned from your sales and choices (/pc learned reset forgets it)")
        Print("/pc online - how many ProfitCrafter users are online now (your faction)")
        Print("/pc purge - sell all crafted items to clear bag space (even below cost); again, or /pc purge stop, to stop")
        Print("/pc ticker - screen-wide price ticker on or off; /pc ticker lock|unlock")
        Print("/pc skin - copy the open profession window's background onto ProfitCrafter (/pc skin reset undoes it)")
        Print("/pc history - every purchase and sale")
        Print("/pc plan - your saved crafting plans; /pc plan <name> switches to (or creates) one")
        Print("/pc config - open ProfitCrafter's settings")
        Print("/pc resetprices - forget all auction prices and start fresh")
        Print("/pc icon - pick the addon's icon")
        Print("/pc minimap - show or hide the minimap button")
        Print("/pc layout - task list above the Task Button, or pull-down (button on top, list below)")
        Print("/pc where - where the route thinks you are, and every step of the way")
        Print("/pc arrow why - what the arrow points at, and why that way")
        Print("/pc ahtab - open ProfitCrafter automatically with the Auction House, on or off")
        if not PC.FOREVER then Print("/pc share - who you've traded prices with; /pc share on|off turns sharing on or off") end
        Print("/pc auto - auto-scan when the Auction House opens, on or off")
        Print("/pc reset - forget recipes and relearn them")
    else
        if PC.UI then PC.UI:Toggle() end
    end
end

---------------------------------------------------------------------------
-- In combat ProfitCrafter is gone from the screen and does nothing; it's all back when the fight ends
---------------------------------------------------------------------------
do
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_REGEN_DISABLED")
    ev:RegisterEvent("PLAYER_REGEN_ENABLED")
    ev:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            PC.inCombat = true
            local win = PC.UI and PC.UI.f
            PC.combatWindow = win and win:IsShown() or false
            local mm = PC.UI and PC.UI.mm
            PC.combatMinimap = mm and mm.IsShown and mm:IsShown() or false
            for _, fr in ipairs({ win, PC.Next and PC.Next.bar, PC.Steps and PC.Steps.f, PC.Places and PC.Places.arrow,
                PC.Places and PC.Places.sArrow, PC.Ticker and PC.Ticker.screenFrame, mm }) do
                if fr and fr.Hide then pcall(fr.Hide, fr) end
            end
        else
            PC.inCombat = nil
            if PC.combatWindow and PC.UI and PC.UI.f then pcall(PC.UI.f.Show, PC.UI.f) end
            if PC.combatMinimap and PC.UI and PC.UI.mm then pcall(PC.UI.mm.Show, PC.UI.mm) end
            if PC.Ticker and PC.Ticker.Apply then pcall(PC.Ticker.Apply, PC.Ticker) end
            PC:RefreshUI(true)
        end
    end)
end
