-- ProfitCrafter: Make me gold, and the events that drive the automation

local ADDON, ns = ...
local PC = ns.PC

local function Safe(name, fn, ...) return PC:Safe(name, fn, ...) end
local On = PC.AutoOn
local Bags = PC.BagSlots
local UseBagItem = PC.UseBagItem
local Posted = PC.Posted
local Sell = PC.Sell
local Craft = PC.Craft
local Undercut = PC.Undercut
local Next = PC.Next
local Mail = PC.Mail
local VendorAuto = PC.VendorAuto

---------------------------------------------------------------------------
-- Make me gold: fill a plan with the best crafts that fit your budget and actually sell
---------------------------------------------------------------------------
local Gold = {}
PC.MakeGold = Gold
Gold.MAX_ROWS = 6   -- crafts to buy for (at most)
Gold.MIN_ROWS = 2   -- and at least, when that many are worth it
Gold.MAX_CRAFTS = 200 -- of one recipe (vendor flips: FLIP_MAX)
Gold.MAX_LEFT = 6   -- what you're still carrying
Gold.MAX_MATS = 6   -- crafts from your materials
Gold.MAX_SELL = 8   -- materials to sell

-- Sold per day for what a recipe makes (nil = not enough scans to tell)
function Gold:SoldPerDay(e)
    local id = e.outID or e.r.output
    if not id or not PC.SalesEstimate then return nil end
    local sold, covered = PC:SalesEstimate(id, 86400)
    if not sold or not covered or covered <= 0 then
        -- none of our own scans yet: TradeSkillMaster's sales rate (per realm, averaged over the region)
        local tsm = PC.TSMValue and PC:TSMValue("dbregionsoldperday*1000", id)
        if tsm then return tsm / 1000 end
        return nil
    end
    -- under 6 hours of scans: only what really sold (a short burst isn't stretched into a whole day)
    if covered < 6 * 3600 then return sold end
    return sold * 86400 / math.max(covered, 1)
end

-- Gear (armor, weapons, bags) or something that gets used up (consumables, trade goods)?
function Gold:IsGear(itemID)
    local getInfo = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not getInfo or not itemID then return false end
    local ok, _, _, _, equipLoc, _, classID = pcall(getInfo, itemID)
    if not ok then return false end
    if equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE" then return true end
    return classID == 2 or classID == 4 -- weapon, armor
end

-- Your share of what players typically buy in a day: gear sells slowly (10%), everything else faster (20%,
-- 5% more for a hot seller: more bought than listed over the last day, not after a buyout)
function Gold:Share(e)
    local id = e.outID or e.r.output
    if self:IsGear(id) then return (PC.db.goldShareGear or 10) / 100 end
    local pct = PC.db.goldShareUse or 20
    if e.hot then pct = pct + 5 end
    return pct / 100
end

-- What one craft brings in, the way it's sold (after the auction cut)
function Gold:Income(e)
    local ah, v, route = PC:CraftIncome(e)
    return (e.route == "Vendor" and v) or (e.route == "AH" and ah) or route
end

-- What YOU really sell of an item a day, from your own sales over the last two weeks (nil = you
-- haven't sold it on the AH yet). The AH scans can make a slow seller look busy; your own record can't.
Gold.OWN_DAYS = 14
function Gold:OwnPerDay(itemID)
    local cdb = PC.cdb
    if not itemID or not cdb or not cdb.ledger then return nil end
    local L = PC.Learn and PC.Learn.Data and PC.Learn:Data().items[itemID]
    if not L or (L.posted or 0) < 3 then return nil end
    local name = PC:ItemName(itemID)
    if not name then return nil end
    local now = time()
    local since, sold, first = now - self.OWN_DAYS * 86400, 0, now
    for _, e in ipairs(cdb.ledger) do
        if e.kind == "sell" and e.item == name and (e.t or 0) >= since then
            sold = sold + (e.qty or 1)
            first = math.min(first, e.t)
        end
    end
    -- over the days since your first sale in that window (at least one): a batch that sold out yesterday
    -- isn't spread over two weeks
    -- shortcut: counts from the first sale, not the first post; store first posts if that overstates slow sellers
    local days = math.min(math.max((now - first) / 86400, 1), self.OWN_DAYS)
    return sold / days
end

-- How many of an item you already hold: bags, bank, in the mail, and posted on the AH
function Gold:Holding(itemID)
    return (PC:ItemCount(itemID) or 0) + Posted:Count(itemID)
end

-- The same, but the batch the plan in hand is making right now doesn't count against itself.
-- Without this a batch eats itself: every craft adds one to what you hold, which takes one off
-- what the market says you may make, so five kits turn into buy one, craft one, five times over.
function Gold:HoldingForPlan(itemID)
    local held = self:Holding(itemID)
    if not itemID or not PC.cdb then return held end
    local t = PC.cdb.planCrafted and PC.cdb.planCrafted[itemID]
    if not t or (time() - t) > 2 * 3600 then return held end
    local made = (PC.cdb.planMadeN and (PC.cdb.planMadeN[PC:PlanName()] or {})[itemID]) or 0
    if made <= 0 then return held end
    -- only what's still in your bags: once it's posted or sold it counts again
    local inBags = PC.BagCount and PC:BagCount(itemID) or 0
    return math.max(held - math.min(made, inBags), 0)
end

-- The most crafts of a recipe worth doing right now, from the market:
--   your share of a day's sales, no more than a slice of what's listed, minus what you already hold.
-- Returns the cap (crafts), and the reason text. nil = the market can't be judged yet (no scans).
-- Vendor flips: a vendor buys any amount, so the only limit is the materials. Buying lots pushes their
-- AH price up the listings, so this is the most crafts where the LAST one still makes a profit.
function Gold:FlipCap(e)
    local rev = e.vendorSell
    if not rev or rev <= 0 then return 0 end
    local function cost(n)
        local _, total, missing = PC:CombinedShoppingList({ setmetatable({ planCount = n }, { __index = e }) }, 1)
        if missing then return nil end
        return total or 0
    end
    local lo, hi = 0, self.FLIP_MAX
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        local a, b = cost(mid - 1), cost(mid)
        if a and b and (b - a) < rev then lo = mid else hi = mid - 1 end -- the mid-th craft still profits
    end
    return lo
end
Gold.FLIP_MAX = 500

-- The market cap is asked for several times in one refresh (the plan, the shopping list, the task
-- list, the Task Button), and working it out is not cheap: once per refresh is enough.
function Gold:MarketCap(e, ...)
    local memo = PC.Memo and PC:Memo()
    if not memo then return self:MarketCapRaw(e, ...) end
    local key = "cap:" .. tostring(e and e.id) .. "/" .. tostring(e and e.planCount)
    local c = memo[key]
    if not c then c = { self:MarketCapRaw(e, ...) }; memo[key] = c end
    return c[1], c[2], c[3]
end

function Gold:MarketCapRaw(e)
    if not e or not e.r then return nil end
    if e.route == "Disenchant" then return 20, "disenchanted: the dust sells, not the item" end
    if e.route == "Vendor" then
        local cap = self:FlipCap(e)
        return cap, ("vendor flip: profitable up to %d before materials cost too much"):format(cap)
    end
    local id = e.outID or e.r.output
    local per = math.max(e.r.qty or 1, 1)
    local perDay = self:SoldPerDay(e)
    local listed = PC:Supply()[id]
    if not perDay and not listed then return nil end
    local items
    local why = {}
    if perDay then
        items = perDay * self:Share(e, perDay)
        -- learned: a smaller share for things that keep coming back unsold, a bit more for sure sellers
        local f = PC.Learn and PC.Learn:ShareFactor(id) or 1
        if f ~= 1 then items = items * f; why[#why + 1] = f < 1 and "often comes back unsold" or "always sells" end
        why[#why + 1] = ("~%d sell a day"):format(math.floor(perDay + 0.5))
        -- other ProfitCrafter users' plans will put more on the AH: a smaller share, never under half
        local coming, players = PC:ComingSupply(id, perDay)
        if coming > 0 then
            items = items * math.max(0.5, perDay / (perDay + coming))
            why[#why + 1] = ("%d more coming from %d other ProfitCrafter user%s"):format(coming, players, players == 1 and "" or "s")
        end
    end
    if listed and listed > 0 then
        local slice = listed * (PC.db.goldFlood or 20) / 100
        items = items and math.min(items, slice) or slice
        why[#why + 1] = ("%d listed"):format(listed)
    elseif listed == 0 and not perDay then
        items = 5 -- nothing listed and no sales data: a small batch to test the water
        why[#why + 1] = "none listed"
    end
    local holding = self:HoldingForPlan(id)
    if holding > 0 then why[#why + 1] = ("you hold %d"):format(holding) end
    -- none of yours sold in the last two weeks: half your share for a first batch
    local mine, fast = PC:SoldSince(id, time() - 86400)
    if mine == 0 and PC:SoldSince(id, time() - self.OWN_DAYS * 86400) == 0 then
        items = items / 2
        why[#why + 1] = "half for a first batch"
    end
    -- what you yourself sell of it: no more than two days' worth (the scans can make a slow seller look busy)
    local own = self:OwnPerDay(id)
    if own and own * 2 < items then
        items = math.ceil(own * 2)
        why[#why + 1] = ("you sell ~%d a day"):format(math.floor(own + 0.5))
    end
    -- yours are selling faster than that today: follow your own sales (three times when they went within the hour)
    local more = mine * (fast and self.FAST_MORE or 2)
    if more > items then
        items = more
        why[#why + 1] = ("%d of yours sold today: making more"):format(mine)
    end
    return math.max(math.floor((items - holding) / per), 0), table.concat(why, ", ")
end

-- Start small, then follow your own sales (what gets posted that no plan made, and crafts held back with
-- the "hold crafts for the market" option; Make me gold and Best bets go by the market cap above):
--   * never sold: a test batch of 3 (gear 2). Nothing more while those are still around.
--   * none of yours sold in 3 days: no more, until the test batch is gone and a few days have passed;
--     then another test batch
--   * sold in the last 3 days, but not today: keep up to 3 on hand
--   * sold today: up to twice what sold today (gear: as many as sold today, at least 2) - the more
--     it sells, the more is made. Sold within the hour of posting: three times (gear twice).
--   * your own sales beat the market's guess: when yours sell faster than it expects, they decide
-- "On hand" is everything you have of it: bags, bank, mail and listed. Returns the most on hand, why.
Gold.TEST_BATCH = 3
Gold.TEST_GEAR = 2
Gold.RETRY_DAYS = 3
Gold.START_SMALL = true
Gold.FAST_MORE = 3
function Gold:HoldCap(id)
    if not id or not self.START_SMALL then return nil end
    local gear = self:IsGear(id)
    local today, fast = PC:SoldSince(id, time() - 86400)
    if today > 0 then
        -- sold within the hour of going up: three times as many
        local more = fast and self.FAST_MORE or 2
        if gear then
            local most = fast and today * 2 or today
            return math.max(self.TEST_GEAR, most), ("%d of yours sold today"):format(today)
        end
        return math.max(self.TEST_BATCH, today * more), fast and ("%d of yours sold within the hour: making more"):format(today)
            or ("%d of yours sold today: making more"):format(today)
    end
    local recent = PC:SoldSince(id, time() - self.RETRY_DAYS * 86400)
    local test = gear and self.TEST_GEAR or self.TEST_BATCH
    if recent > 0 then return test, "selling slowly: a few at a time" end
    local made = PC.cdb.planCrafted and PC.cdb.planCrafted[id]
    -- crafted in the last couple of hours: that's this test batch still being made
    if made and time() - made < 2 * 3600 then return test, "a small test batch first" end
    if made and time() - made < self.RETRY_DAYS * 86400 then
        local days = math.max(math.ceil((made + self.RETRY_DAYS * 86400 - time()) / 86400), 1)
        return 0, ("none of yours sold yet: trying again in %d day%s"):format(days, days == 1 and "" or "s")
    end
    return test, made and "didn't sell before: another small test batch" or "new: a small test batch first"
end

-- The same as crafts for a recipe (nil = no limit from this rule)
function Gold:SlowCap(e)
    local id = e and (e.outID or (e.r and e.r.output))
    if not id or e.route == "Vendor" or e.route == "Disenchant" then return nil end
    local most, why = self:HoldCap(id)
    if not most then return nil end
    local per = math.max(e.r.qty or 1, 1)
    local crafts = math.max(math.floor((most - self:HoldingForPlan(id)) / per), 0)
    return crafts, why
end

-- returns picks { {e, n, cost, profit} }, total cost, total profit
function Gold:Build(budget)
    local UI = PC.UI
    if not UI.allEntries then UI.allEntries = PC:Analyze() end
    local cands = {}
    for _, e in ipairs(UI.allEntries) do
        -- at least the minimum profit, and nothing for the AH that nobody bought there in the last day
        -- (and for the AH, at least half as many sold in the last day as are listed: else it won't sell in time)
        if e.profit and e.profit > 0 and e.cost and e.cost > 0 and PC:MeetsMin(e) and PC:SalesOK(e)
            and (PC:SellThrough(e))
            and not (PC.Learn and PC.Learn:Avoided(e.id))
            and not (self.skip and self.skip.pick[e.id]) then
            -- the one market rule: your share of sales, a slice of what's listed, minus what you hold
            -- (no market numbers: 2 to try)
            local cap = math.min(self:MarketCap(e) or 2, e.route == "Vendor" and self.FLIP_MAX or self.MAX_CRAFTS)
            -- no more than the materials can be bought for while each craft still clears the minimum profit
            local most = cap > 0 and PC:CraftableAtMin(e, math.huge) or 0
            local n = math.min(cap, most or cap)
            if n > 0 then
                -- gold an hour for that batch, as in Best bets (a quarter more when it sold out over the last
                -- day; learned: purged or twice-unsold items rank lower until they sell again)
                local pen = PC.Learn and PC.Learn:Penalty(e.outID or e.r.output) or 0
                local rate = PC:GoldAnHour(e, n) * (1 - pen) * (e.hot and PC.HOT_BONUS or 1)
                if rate > 0 then cands[#cands + 1] = { e = e, cap = n, perDay = self:SoldPerDay(e), rate = rate } end
            end
        end
    end
    table.sort(cands, function(a, b) return a.rate > b.rate end)
    local picks, chosen = {}, {}
    self.bagLimited = nil
    local free = PC:FreeBagSlots()
    local function slotsOf(list)
        local entries = {}
        for _, p in ipairs(list) do entries[#entries + 1] = setmetatable({ planCount = p.n }, { __index = p.e }) end
        return PC:PlanSlots(entries)
    end
    local function costOf(list)
        local entries = {}
        for _, p in ipairs(list) do entries[#entries + 1] = setmetatable({ planCount = p.n }, { __index = p.e }) end
        local _, total, missing = PC:CombinedShoppingList(entries, 1)
        return (total or 0) + PC:PostReserve(entries), missing
    end
    for _, c in ipairs(cands) do
        -- 2 to 6 recipes, none making under half the best one's gold an hour: fewer runs between the
        -- bench and the AH for a few silver
        if #picks >= self.MIN_ROWS and c.rate < picks[1].rate / 2 then break end
        local pick = { e = c.e, n = 0, perDay = c.perDay, rate = c.rate }
        chosen[#chosen + 1] = pick
        local lo, hi = 0, c.cap
        while lo < hi do -- most crafts of this recipe that still fit the gold and your bags
            local mid = math.floor((lo + hi + 1) / 2)
            pick.n = mid
            local t, miss = costOf(chosen)
            if not miss and t <= budget and slotsOf(chosen) <= free then lo = mid else hi = mid - 1 end
        end
        pick.n = lo
        if lo == 0 then
            table.remove(chosen)
            pick.n = 1
            if slotsOf({ pick }) > free then self.bagLimited = true end
        else
            picks[#picks + 1] = pick
        end
        if #picks >= self.MAX_ROWS then break end
    end
    -- (shown with the reagent bag: the materials it takes, and its free slots)
    local need, inReagent = slotsOf(chosen)
    self.slotsUsed, self.slotsFree = need + (inReagent or 0), free + PC:FreeReagentBagSlots()
    local total = costOf(chosen)
    -- each line: the gold it adds to the shopping list in turn (materials priced up the listings; yours go
    -- to the first lines that use them, free), what it brings in, and which of yours it uses. The lines add
    -- up to the totals. Returns the picks, the gold to keep back (materials and deposits), the profit, and
    -- the gold the materials cost.
    local profit, spent, sofar, prevOwn = 0, 0, {}, {}
    for _, p in ipairs(picks) do
        sofar[#sofar + 1] = setmetatable({ planCount = p.n }, { __index = p.e })
        local list, spend = PC:CombinedShoppingList(sofar, 1)
        local own = {}
        for _, it in ipairs(list or {}) do
            local used = math.min(it.need or 0, it.have or 0)
            if used > 0 then own[it.id] = used end
        end
        p.own = {}
        for id, used in pairs(own) do
            local d = used - (prevOwn[id] or 0)
            if d > 0 then p.own[#p.own + 1] = { id = id, n = d } end
        end
        prevOwn = own
        p.cost = math.max((spend or 0) - spent, 0)
        spent = spent + p.cost
        p.income = p.n * (self:Income(p.e) or 0)
        p.profit = p.income - p.cost
        profit = profit + p.profit
    end
    return picks, total, profit, spent
end

function Gold:Open()
    PC:Sound("start") -- "Work, work."
    local UI = PC.UI
    UI:Create()
    local w = self.win
    if not w then
        w = CreateFrame("Frame", "ProfitCrafterMakeGold", UI.f, "BackdropTemplate")
        w:SetSize(840, 368) -- (wide enough for both profits on every line)
        w:SetPoint("CENTER", UI.f, "CENTER")
        w:SetFrameStrata("DIALOG")
        w:EnableMouse(true)
        if w.SetBackdrop then
            w:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
            w:SetBackdropColor(0.07, 0.05, 0.03, 0.98)
            w:SetBackdropBorderColor(0.78, 0.59, 0.18, 1)
        end
        tinsert(UISpecialFrames, "ProfitCrafterMakeGold")
        w.title = w:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        w.title:SetPoint("TOPLEFT", 14, -12)
        w.title:SetText("Make me gold")
        w.budget = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        w.budget:SetPoint("TOPLEFT", 14, -40)
        -- selling what's already in your bags and bank (what you're still carrying, spare materials, crafts made
        -- only from your materials): off keeps them
        w.sellBags = CreateFrame("CheckButton", nil, w, "UICheckButtonTemplate")
        w.sellBags:SetSize(22, 22)
        w.sellBags:SetPoint("TOPLEFT", 10, -58)
        w.sellBags:SetScript("OnClick", function(btn)
            PC.db.goldSellBags = btn:GetChecked() and true or false
            Gold:Update()
        end)
        w.sellBags:SetScript("OnEnter", function(btn)
            GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
            GameTooltip:SetText("Sell what's already in my bags & bank")
            GameTooltip:AddLine("What you're still carrying from an earlier plan, materials no craft here uses, and crafts made only from your materials.", 1, 1, 1, true)
            GameTooltip:AddLine("Untick to keep them.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        w.sellBags:SetScript("OnLeave", function() GameTooltip:Hide() end)
        local l7 = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        l7:SetPoint("LEFT", w.sellBags, "RIGHT", 2, 0)
        l7:SetText("Sell what's already in my bags & bank")
        local l3 = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        l3:SetPoint("TOPLEFT", 14, -88)
        l3:SetText("Don't sell more gear than")
        local function pctBox(anchor)
            local eb = CreateFrame("EditBox", nil, w, "InputBoxTemplate")
            eb:SetSize(32, 20)
            eb:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
            eb:SetAutoFocus(false)
            eb:SetNumeric(true)
            eb:SetMaxLetters(3)
            eb:SetScript("OnEnterPressed", function(b) b:ClearFocus(); Gold:Update() end)
            eb:SetScript("OnEditFocusLost", function() Gold:Update() end)
            return eb
        end
        w.gearBox = pctBox(l3)
        local l4 = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        l4:SetPoint("LEFT", w.gearBox, "RIGHT", 4, 0)
        l4:SetText("% of what players typically buy in a day")
        local l5 = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        l5:SetPoint("TOPLEFT", l3, "BOTTOMLEFT", 0, -12)
        l5:SetText("Don't sell more misc than")
        w.useBox = pctBox(l5)
        local l6 = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        l6:SetPoint("LEFT", w.useBox, "RIGHT", 4, 0)
        l6:SetText("% of what players typically buy in a day")
        w.note = w:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        w.note:SetPoint("TOPLEFT", l5, "BOTTOMLEFT", 0, -8)
        w.lines = {}
        w.total = w:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        w.total:SetPoint("BOTTOMLEFT", 14, 44)
        w.total:SetJustifyH("LEFT")
        w.total:SetSpacing(4)
        w.use = CreateFrame("Button", nil, w, "UIPanelButtonTemplate")
        w.use:SetSize(130, 24)
        w.use:SetPoint("BOTTOMRIGHT", -12, 12)
        w.use:SetText("Use this plan")
        w.use:SetScript("OnClick", function() Safe("make me gold", Gold.Use, Gold) end)
        w.cancel = CreateFrame("Button", nil, w, "UIPanelButtonTemplate")
        w.cancel:SetSize(90, 24)
        w.cancel:SetPoint("RIGHT", w.use, "LEFT", -6, 0)
        w.cancel:SetText(CANCEL or "Cancel")
        w.cancel:SetScript("OnClick", function() w:Hide() end)
        self.win = w
    end
    -- a fresh window: nothing taken off yet
    self.skip = { left = {}, pick = {}, mat = {}, sell = {} }
    w.sellBags:SetChecked(PC.db.goldSellBags ~= false)
    w.gearBox:SetText(tostring(PC.db.goldShareGear or 10))
    w.useBox:SetText(tostring(PC.db.goldShareUse or 20))
    w:Show()
    if w.Raise then w:Raise() end
    self:Update()
end

function Gold:Update()
    local w = self.win
    if not w or not w:IsShown() then return end
    PC.db.goldShareGear = math.min(math.max(tonumber(w.gearBox:GetText()) or 10, 1), 100)
    PC.db.goldShareUse = math.min(math.max(tonumber(w.useBox:GetText()) or 20, 1), 100)
    w.note:SetText(("Misc: 5%% more for a hot seller (%d%% becomes %d%%)"):format(PC.db.goldShareUse, PC.db.goldShareUse + 5))
    local budget = PC.UI:PlanBudget()
    w.budget:SetText(("Spend up to %s  |cff888888(%s)|r"):format(PC:Money(budget, false, true), PC.UI:BudgetName()))
    local picks, total, _, spent = self:Build(budget)
    self.picks = picks
    -- deposits for what goes on the AH come out of what's left of your spending limit
    local room = { left = math.max(budget - (#picks > 0 and total or 0), 0) }
    -- (what's in your bags and bank is only sold, or crafted on its own, when you want it to be)
    local keep = PC.db.goldSellBags == false
    local left, mats, sells = {}, {}, {}
    if not keep then
        left, mats = self:Carrying(room), self:MatCrafts(picks, room)
        sells = self:MatSells(picks, mats, left, room)
    end
    self.left, self.mats, self.sells = left, mats, sells
    local words = { post = "|cff40c0ffpost at auction|r", disenchant = "|cffc080ffdisenchant for dust|r", vendor = "|cffffd100sell to a vendor|r" }
    local function routeWords(e)
        local route = e.route
        return (route == "Vendor" and words.vendor) or (route == "Disenchant" and words.disenchant) or words.post
    end
    -- a line's profit, the way it's sold (only that one: the other way isn't what the plan does)
    local function profits(x)
        local route = x.e.route
        local label = (route == "Vendor" and "Vendor Profit") or (route == "Disenchant" and "Disenchant Profit") or "Auction Profit"
        return "|cffffffff" .. label .. "|r " .. PC:Money(x.profit or 0, true, true)
    end
    -- a line that uses materials you already have (free)
    local function yours(x)
        return (x.own and #x.own > 0) and "   |cff888888(using bag materials)|r" or ""
    end
    local n, y = 0, -154
    local function line(text, kind, key)
        n = n + 1
        local L = self:Line(n)
        L:ClearAllPoints()
        L:SetPoint("TOPLEFT", w, "TOPLEFT", 14, y)
        L:SetPoint("RIGHT", w, "RIGHT", -14, 0)
        L.text:SetText(text)
        L.kind, L.key = kind, key
        L.x:SetShown(kind ~= nil)
        if kind then L.text:SetFontObject("GameFontHighlightSmall") else L.text:SetFontObject("GameFontNormal") end
        L:Show()
        y = y - (kind and 19 or 22)
    end
    local sellValue = 0
    -- 1. what you're still carrying from an earlier plan
    if #left > 0 then
        line("|cffffd100First, what you're still carrying|r")
        for _, l in ipairs(left) do
            sellValue = sellValue + (l.each or 0) * l.n
            line(("%s  |cffffffffx%d|r  %s   |cff888888about|r %s"):format(l.name, l.n, words[l.what] or l.what, PC:Money((l.each or 0) * l.n, false, true)), "left", l.id)
        end
        y = y - 6
    end
    -- 2. crafts (buying what they need)
    if #picks > 0 then
        line("|cffffd100Crafts|r")
        for _, p in ipairs(picks) do
            local listed = PC:Supply()[p.e.outID or p.e.r.output]
            local sells = p.perDay and ("|cff888888~%d/day, %s listed|r"):format(math.floor(p.perDay + 0.5), listed and tostring(listed) or "?") or "|cff888888sales unknown|r"
            line(("%s  |cffffffffx%d|r  %s   %s   |cff888888cost|r %s   %s%s"):format(p.e.r.name, p.n, routeWords(p.e), sells,
                PC:Money(p.cost or 0, false, true), profits(p), yours(p)), "pick", p.e.id)
        end
        y = y - 6
    end
    -- 3. your materials: crafts they already make, and the rest to sell
    if #mats > 0 or #sells > 0 then
        line("|cffffd100Your materials|r")
        for _, m in ipairs(mats) do
            line(("%s  |cffffffffx%d|r  %s   |cff888888nothing to buy|r   %s%s"):format(m.e.r.name, m.n, routeWords(m.e), profits(m), yours(m)), "mat", m.e.id)
        end
        for _, l in ipairs(sells) do
            sellValue = sellValue + (l.each or 0) * l.n
            line(("%s  |cffffffffx%d|r  %s   |cff888888about|r %s"):format(l.name, l.n, words[l.what] or l.what, PC:Money((l.each or 0) * l.n, false, true)), "sell", l.id)
        end
        y = y - 6
    end
    if n == 0 then
        line("|cff888888Nothing fits yet. Scan the Auction House a few times so sales can be estimated.|r")
    end
    for i = n + 1, #w.lines do w.lines[i]:Hide() end
    local any = #picks > 0 or #mats > 0 or #left > 0 or #sells > 0
    -- the totals: the gold you spend, the gold you get back (the crafts sold the way each is marked, and
    -- what's in your bags), and the difference. What you already have counts as free.
    local returns = sellValue
    for _, list in ipairs({ picks, mats }) do
        for _, x in ipairs(list) do returns = returns + (x.income or 0) end
    end
    local parts = {
        ("Total predicted cost: |cffffffff%s|r"):format(PC:Money(spent or 0, false, true)),
        ("Total predicted returns: |cffffffff%s|r"):format(PC:Money(returns, false, true)),
        ("Total predicted profit: %s"):format(PC:Money(returns - (spent or 0), true, true)),
    }
    if #picks > 0 or self.bagLimited then
        parts[#parts + 1] = ("Bag slots used: %d of %d free%s"):format(self.slotsUsed or 0, self.slotsFree or 0,
            self.bagLimited and " |cffff8040(limited by bag space)|r" or "")
    end
    w.total:SetText(any and table.concat(parts, "\n")
        or (self.bagLimited and ("|cffff8040Nothing fits in your bags (%d free slots).|r"):format(self.slotsFree or 0) or ""))
    w:SetHeight(math.max(368, -y + 66 + math.max(w.total:GetStringHeight() or 0, 14)))
    w.use:SetEnabled(any)
end

-- one line of the window, with its own X to take it off
function Gold:Line(i)
    local w = self.win
    local L = w.lines[i]
    if L then return L end
    L = CreateFrame("Frame", nil, w)
    L:SetHeight(18)
    L.x = CreateFrame("Button", nil, L)
    L.x:SetSize(14, 14)
    L.x:SetPoint("RIGHT", L, "RIGHT", 0, 0)
    L.x:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    L.x:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight", "ADD")
    L.x:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Down")
    L.x:SetScript("OnClick", function()
        if L.kind and L.key and Gold.skip and Gold.skip[L.kind] then
            Gold.skip[L.kind][L.key] = true
            Gold:Update()
        end
    end)
    L.text = L:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    L.text:SetPoint("LEFT", L, "LEFT", 2, 0)
    L.text:SetPoint("RIGHT", L.x, "LEFT", -6, 0)
    L.text:SetJustifyH("LEFT")
    L.text:SetWordWrap(false)
    w.lines[i] = L
    return L
end

-- Where to sell n of an item, or nil: the AH only when it really sells there (at least one a day) and
-- the deposit fits what's left of your spending limit; otherwise a vendor when one
-- pays; otherwise it isn't offered. room = { left = copper you can still spend }.
function Gold:SellRoute(id, n, room)
    local what, each = PC.Sell:Recommend(id)
    local vend = PC:SellPrice(id) or 0
    -- a vendor only when it pays at least what it cost you (otherwise it's kept, never sold at a loss)
    local costEach = PC.Sell.CostEach and PC.Sell:CostEach(id)
    if costEach and vend < costEach then vend = 0 end
    if what == "post" then
        local perDay = self:SoldPerDay({ outID = id, r = {} })
        local deposit = (PC.Sell.FeeEach and (PC.Sell:FeeEach(id) or 0) * n) or (PC.Sell.Deposit and PC.Sell:Deposit(id, nil, n)) or 0
        -- (and only at a profit: what it brings in after the deposit beats a vendor)
        local net = (each or 0) * n - (deposit or 0)
        if not perDay or perDay < 1 or (deposit or 0) > room.left or net <= 0 or net <= vend * n then
            if vend > 0 then return "vendor", vend end
            return nil
        end
        room.left = room.left - (deposit or 0)
        return "post", each
    end
    if what == "vendor" and vend <= 0 then return nil end
    return what, each
end

-- what you're still carrying from an earlier plan (minus what you took off)
function Gold:Carrying(room)
    local out = {}
    local okL, left = pcall(PC.Sell.LeftoverList, PC.Sell)
    for _, l in ipairs(okL and left or {}) do
        if not self.skip.left[l.id] and #out < self.MAX_LEFT then
            local what, each = l.what, l.each
            if what ~= "disenchant" then what, each = self:SellRoute(l.id, l.n, room) end
            if what then out[#out + 1] = { id = l.id, n = l.n, name = l.name, what = what, each = each } end
        end
    end
    return out
end

-- crafts your materials already make (nothing to buy), after the crafts above have taken theirs
function Gold:MatCrafts(picks, room)
    local UI = PC.UI
    local stock = {}
    local function slotKey(rg) return table.concat(PC:ReagentIDs(rg), ",") end
    local function have(rg)
        local k = slotKey(rg)
        if stock[k] == nil then stock[k] = PC:ReagentCount(rg) or 0 end
        return stock[k]
    end
    local function use(rg, n) local k = slotKey(rg); stock[k] = have(rg) - n end
    local taken = {}
    for _, p in ipairs(picks) do
        taken[p.e.id] = true
        for _, rg in ipairs(p.e.r.reagents or {}) do use(rg, (rg.n or 1) * p.n) end
    end
    local list = {}
    for _, e in ipairs(UI.allEntries or {}) do
        if e.profit and e.profit > 0 and e.r and e.r.reagents and #e.r.reagents > 0 and not taken[e.id]
            and PC:MeetsMin(e) and PC:SalesOK(e) and (PC:SellThrough(e))
            and not self.skip.mat[e.id] and not (PC.Learn and PC.Learn:Avoided(e.id)) then
            list[#list + 1] = e
        end
    end
    table.sort(list, function(a, b) return a.profit > b.profit end)
    local out = {}
    for _, e in ipairs(list) do
        local can = math.huge
        for _, rg in ipairs(e.r.reagents) do can = math.min(can, math.floor(math.max(have(rg), 0) / (rg.n or 1))) end
        if can ~= math.huge and can > 0 and e.route ~= "Vendor" and e.route ~= "Disenchant" then
            -- the same rules as any craft: only what really sells (your own sales first, then the market)
            local cap = self:MarketCap(e)
            if cap ~= nil then can = math.min(can, cap) end
        end
        if can ~= math.huge and can > 0 then
            can = math.min(can, self.MAX_CRAFTS)
            -- going on the AH: its deposit has to fit what's left of your spending limit
            local fits = true
            if room and e.route ~= "Vendor" and e.route ~= "Disenchant" then
                local id = e.outID or e.r.output
                local dep = (id and PC.Sell.FeeEach and PC.Sell:FeeEach(id) or 0) * can * math.max(e.r.qty or 1, 1)
                if dep > room.left then fits = false else room.left = room.left - dep end
            end
            if fits then
                local own = {}
                for _, rg in ipairs(e.r.reagents) do
                    use(rg, (rg.n or 1) * can)
                    own[#own + 1] = { id = (PC:ReagentFor(rg, e.mats)), n = (rg.n or 1) * can }
                end
                -- (nothing to buy: what it brings in is all profit)
                local income = can * (self:Income(e) or 0)
                out[#out + 1] = { e = e, n = can, income = income, profit = income, own = own }
                if #out >= self.MAX_MATS then break end
            end
        end
    end
    return out
end

-- materials in your bags no craft here uses (fish, meat, cloth...): sold, wherever pays more
function Gold:MatSells(picks, mats, left, room)
    local out, cdb = {}, PC.cdb
    local Sell = PC.Sell
    local used, isMat, skipID = {}, {}, {}
    for _, l in ipairs(left) do skipID[l.id] = true end
    local okLL, allLeft = pcall(Sell.LeftoverList, Sell)
    for _, l in ipairs(okLL and allLeft or {}) do skipID[l.id] = true end
    local function mark(list)
        for _, p in ipairs(list) do
            for _, rg in ipairs(p.e.r.reagents or {}) do for _, id in ipairs(PC:ReagentIDs(rg)) do used[id] = true end end
        end
    end
    mark(picks); mark(mats)
    for _, e in ipairs(PC.UI.allEntries or {}) do
        for _, rg in ipairs(e.r and e.r.reagents or {}) do for _, id in ipairs(PC:ReagentIDs(rg)) do isMat[id] = true end end
    end
    local stock, noSell = Sell:Stock() or {}, PC:NoSell() or {}
    for id, n in pairs(PC.BagCounts and PC:BagCounts() or {}) do
        local trade = false
        if not isMat[id] and C_Item and C_Item.GetItemInfoInstant then
            local ok, _, _, _, _, _, classID = pcall(C_Item.GetItemInfoInstant, id)
            trade = ok and classID == 7
        end
        -- (never what a vendor sells: nobody buys Mild Spices on the AH)
        local vendorItem = (PC.VendorCost and PC:VendorCost(id)) or (PC.KNOWN_VENDOR and PC.KNOWN_VENDOR[id])
        if n > 0 and (isMat[id] or trade) and not used[id] and not skipID[id] and not stock[id] and not noSell[id]
            and not vendorItem and not self.skip.sell[id] then
            local what, each = self:SellRoute(id, n, room)
            if what and each and each > 0 then
                out[#out + 1] = { id = id, n = n, name = PC:ItemName(id) or ("item " .. id), what = what, each = each }
            end
        end
    end
    table.sort(out, function(a, b) return a.each * a.n > b.each * b.n end)
    while #out > self.MAX_SELL do table.remove(out) end
    return out
end

-- Put the picks in a plan called "Make me gold" (your other plans stay as they are)
function Gold:Use()
    local picks, mats = self.picks or {}, self.mats or {}
    local left, sells = self.left or {}, self.sells or {}
    if #picks + #mats + #left + #sells == 0 then return end
    local plans = PC:Plans()
    plans["Make me gold"] = {}
    local cdb = PC.cdb
    if cdb.skipCraft then cdb.skipCraft["Make me gold"] = nil end -- made fresh: nothing from last time stays skipped
    local plan = plans["Make me gold"]
    for _, p in ipairs(picks) do plan[p.e.id] = (plan[p.e.id] or 0) + p.n end
    for _, m in ipairs(mats) do plan[m.e.id] = (plan[m.e.id] or 0) + m.n end
    -- what you're carrying and the materials to sell are the plan's to sell now (the ones left on)
    cdb.planCrafted, cdb.planCraftedPlan = cdb.planCrafted or {}, cdb.planCraftedPlan or {}
    cdb.planLeftover = {}
    local made = PC:PlanMade("Make me gold")
    local function adopt(l)
        cdb.planCrafted[l.id] = time()
        cdb.planCraftedPlan[l.id] = "Make me gold"
        cdb.planLeftover[l.id] = true -- dealt with first: it's bag space back
        made[l.id] = math.max(made[l.id] or 0, l.n)
        if l.what == "disenchant" and PC.Synergy and PC.Synergy.Queue then pcall(PC.Synergy.Queue, PC.Synergy, l.id, l.n) end
    end
    local okL, allLeft = pcall(PC.Sell.LeftoverList, PC.Sell)
    for _, l in ipairs(okL and allLeft or {}) do if not self.skip.left[l.id] then adopt(l) end end
    for _, l in ipairs(sells) do adopt(l) end
    if PC.SellSnoozed and PC:SellSnoozed() then cdb.sellSkipUntil = nil end
    PC:SwitchPlan("Make me gold")
    self.win:Hide()
    local crafts = #picks + #mats
    PC.Print(("Made the plan \"Make me gold\": %d recipe%s, %d thing%s to sell."):format(crafts, crafts == 1 and "" or "s",
        #left + #sells, (#left + #sells) == 1 and "" or "s"))
    PC.UI:OpenTab(2)
    PC:RefreshUI()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "MAIL_SHOW", "MAIL_CLOSED", "MAIL_INBOX_UPDATE", "UPDATE_PENDING_MAIL", "MERCHANT_SHOW",
    "OWNED_AUCTIONS_UPDATED", "AUCTION_HOUSE_SHOW", "UI_ERROR_MESSAGE", "AUCTION_HOUSE_AUCTION_CREATED",
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_FAILED", "AUCTION_OWNED_LIST_UPDATE", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "PLAYER_UPDATE_RESTING",
    -- (a new part of a zone, indoors or out: the top of an elevator, a city quarter, a building.
    -- Without these the Task Button kept saying "walk to the elevator" after you'd ridden it)
    "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
    "BAG_UPDATE_DELAYED", "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "PLAYER_REGEN_ENABLED", "CHAT_MSG_SYSTEM" }) do
    pcall(ev.RegisterEvent, ev, e)
end
-- "A buyer has been found for your auction of %s." as a pattern (the game's own text, any language)
local soldPattern
local function SoldName(msg)
    -- (a message the game keeps secret, in combat for one, can't be read: never an error)
    if type(msg) ~= "string" or PC.IsSecret(msg) then return nil end
    if not soldPattern then
        local s = ERR_AUCTION_SOLD_S or "A buyer has been found for your auction of %s."
        s = s:gsub("%%", "%%%%"):gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)")
        soldPattern = "^" .. s .. "$"
    end
    return msg:match(soldPattern)
end
Gold.SoldName = SoldName
ev:SetScript("OnEvent", function(_, event, arg1, arg2, ...)
    local rest = { arg2, ... }
    Safe("automation", function()
        if event == "CHAT_MSG_SYSTEM" then
            -- one of yours sold: count it now (its gold comes by mail later)
            local name = type(arg1) == "string" and SoldName(arg1)
            if name then PC:NoteAuctionSold(name) end
        elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_UPDATE_RESTING" then
            -- arriving in a city (or logging in there): time for an undercut check
            C_Timer.After(3, function() Safe("undercut", Undercut.OnArrive, Undercut) end)
        elseif event == "UI_ERROR_MESSAGE" then
            local msg = type(arg2) == "string" and arg2 or arg1
            if PC.IsSecret(msg) then return end -- kept secret by the game right now: can't be read
            -- bags filled mid-batch ("Inventory is full"): the batch is over
            if Craft.quick and Craft.quick.started and type(msg) == "string"
                and (msg == (ERR_INV_FULL or "Inventory is full.") or msg:lower():find("inventory is full", 1, true)) then
                local q = Craft.quick
                C_Timer.After(0.3, function() if Craft.quick == q then Craft:EndQuick(false) end end)
            end
            if type(msg) == "string" and (msg == (ERR_AUCTION_DATABASE_ERROR or "Internal auction error.") or msg:lower():find("auction error", 1, true)) then
                -- a purchase in progress gets retried smaller; otherwise it's about posting
                if not (PC.Buy and PC.Buy.OnAuctionError and PC.Buy:OnAuctionError()) then Sell:OnAuctionError() end
            end
        elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
            if Sell.pending and not PC.db.auctionRunTime then PC.db.auctionRunTime = (Sell:ClassicRunTime(1) == 1) and "index" or "minutes" end
            Sell.pending = nil
        elseif event == "PLAYER_LOGIN" then
            C_Timer.After(2, function() Safe("Task Button", Next.UpdateBar, Next) end)
        elseif event == "OWNED_AUCTIONS_UPDATED" then
            Posted:SyncFromAH()
        elseif event == "AUCTION_HOUSE_SHOW" then
            Sell.posting = false
            Sell:LearnFromManual()
            Posted:AskClassic() -- the classic AH: read your auctions (it answers with AUCTION_OWNED_LIST_UPDATE)
        elseif event == "AUCTION_OWNED_LIST_UPDATE" then
            Posted:SyncClassic()
            if C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions then pcall(C_AuctionHouse.QueryOwnedAuctions, {}) end
        elseif event == "MAIL_SHOW" then
            Mail.open = true
            Mail.autoDone = false
            PC.cdb.dayCheck = PC.cdb.dayCheck or {}
            if PC.cdb.dayCheck.day == date("%Y-%m-%d") then PC.cdb.dayCheck.mail = true end
        elseif event == "MAIL_CLOSED" then
            Mail.open, Mail.busy, Mail.newMail = false, false, false
            Mail.lastVisit = time() -- what's left unread now isn't AH gold: don't send you back for it
        elseif event == "UPDATE_PENDING_MAIL" then
            if HasNewMail and HasNewMail() and not Mail.open then Mail.arrived = time() end
            Mail.newMail = HasNewMail and HasNewMail() or false
        elseif event == "MAIL_INBOX_UPDATE" then
            -- emptied (by us or by hand): nothing from the AH is waiting any more
            if Mail.open and not Mail.busy and Mail:Count() == 0 and PC.cdb then
                PC:MailEmptied(); Mail.itemsWaiting = nil; Mail.newMail = false
                PC:RefreshUI()
            end
            -- the inbox has loaded: collect once per visit
            if Mail.open and not Mail.autoDone and not Mail.busy then
                Mail.autoDone = true
                if Mail:Count() == 0 then
                    if PC.cdb then PC:MailEmptied() end -- nothing from the AH waiting
                elseif On("autoMail", true) then
                    Mail:Collect()
                end
            end
        elseif event == "MERCHANT_SHOW" then
            C_Timer.After(0.3, function() Safe("vendor", VendorAuto.Run, VendorAuto) end)
        elseif event == "BAG_UPDATE_DELAYED" then
            PC:Downtime("restock", function() Safe("restock", Sell.Restock, Sell) end)
        elseif event == "TRADE_SKILL_CLOSE" then
            -- the hidden window closed (you walked off, or the batch ended): nothing is waiting any more
            if Craft.quick then
                local q = Craft.quick
                C_Timer.After(0.2, function() if Craft.quick == q then Craft:EndQuick(false) end end)
            end
        elseif event == "TRADE_SKILL_SHOW" then
            if Craft.quick then Craft:OnShow()
            elseif PC.UI and PC.UI.OnProfessionShow then PC.UI:OnProfessionShow() end
        elseif event:find("^UNIT_SPELLCAST_") then
            -- the quick craft's batch: count it down, close the hidden window when it's done
            if arg1 == "player" then Craft:OnCast(event, rest[2]) end
        end
        if event ~= "BAG_UPDATE_DELAYED" then -- (bags: the downtime refresh updates it)
            -- (every spell you cast lands here: those wait longer, so casting and crafting stay smooth)
            PC:Debounce("nextbar", event:find("^UNIT_SPELLCAST_") and 2 or 0.3, function()
                if PC:Pending("ui") then return end -- the refresh on its way does it
                PC:WithMemo(function() PC:Timed("button2", Safe, "Task Button", Next.UpdateBar, Next) end)
            end)
        end
    end)
end)
