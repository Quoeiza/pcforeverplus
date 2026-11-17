-- ProfitCrafter: automation (selling, crafting, undercuts). See also Next.lua, Errands.lua, MakeGold.lua
--   * Sell: crafted items in your bags, priced at the cheapest listing, no undercut (never below cost), posted from the Sell tab
--   * Next step: one button (and a key) that always does the next thing in your plan
--   * Floating Next step bar you can move and lock
--   * Mailbox: collect AH purchases and sale gold
--   * Vendors: buy plan materials, sell junk, sell vendor flips
--   * Price alerts, keep-in-stock targets, and "Make me gold"
-- Every automatic action has its own on/off setting. Buying, posting and crafting still need one click
-- (or key press) each: the game doesn't allow addons to do those by themselves.

local ADDON, ns = ...
local PC = ns.PC

local function Safe(name, fn, ...) return PC:Safe(name, fn, ...) end
local function On(key, default)
    local v = PC.db and PC.db[key]
    if v == nil then return default end
    return v and true or false
end
PC.AutoOn = On

---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Bags
---------------------------------------------------------------------------
local function Bags()
    -- inside a refresh every slot is read once (nothing moves in the middle of one; the plan's bag-room
    -- maths asked for this list hundreds of times per refresh). Outside one it's always read fresh.
    local memo = PC._memo
    if memo and memo.bagSlots then return memo.bagSlots end
    local C = C_Container
    local numSlots = (C and C.GetContainerNumSlots) or GetContainerNumSlots
    local out = {}
    if not numSlots then return out end
    for _, bag in ipairs(PC:PlayerBags()) do -- your bags only: never the bank's
        for slot = 1, (numSlots(bag) or 0) do
            local id, n, quality, noValue, locked
            if C and C.GetContainerItemInfo then
                local info = C.GetContainerItemInfo(bag, slot)
                if info then id, n, quality, noValue, locked = info.itemID, info.stackCount, info.quality, info.hasNoValue, info.isLocked end
            elseif GetContainerItemInfo then
                local _, cnt, lk, q, _, _, _, _, nv, itemID = GetContainerItemInfo(bag, slot)
                id, n, quality, noValue, locked = itemID, cnt, q, nv, lk
            end
            if id then out[#out + 1] = { bag = bag, slot = slot, id = id, n = n or 1, quality = quality, noValue = noValue, locked = locked } end
        end
    end
    if memo then memo.bagSlots = out end
    return out
end
PC.BagSlots = Bags

-- Never sold to a vendor automatically: recipes (patterns, plans, formulas...). You can sell them by hand.
function PC:NeverSell(itemID)
    if not itemID then return false end
    local inst = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if inst then
        local ok, _, _, _, _, _, classID = pcall(inst, itemID)
        if ok and classID == 9 then return true end
    end
    return false
end

local function BagItemID(bag, slot)
    if C_Container and C_Container.GetContainerItemID then return C_Container.GetContainerItemID(bag, slot) end
    if GetContainerItemID then return GetContainerItemID(bag, slot) end
end

local function UseBagItem(bag, slot)
    -- at a vendor, using an item sells it: never a recipe (the bank and mailbox still take them)
    if PC.merchantOpen and not (PC.Bank and PC.Bank.open) and PC:NeverSell(BagItemID(bag, slot)) then return end
    if C_Container and C_Container.UseContainerItem then return C_Container.UseContainerItem(bag, slot) end
    if UseContainerItem then return UseContainerItem(bag, slot) end
end
PC.UseBagItem = UseBagItem

---------------------------------------------------------------------------
-- Selling to a vendor, to the exact amount: PC:SellExact({ {id, n}, ... }, onDone, quiet)
-- Whole stacks that fit go first, smallest first (what you keep stays in as few stacks as possible;
-- an exact fit needs no split). The rest is split off a bigger stack into an empty slot and sold once
-- it's really there. One sale at a time, each checked: the stack leaves your bags and gold comes in.
-- Never more than asked, never a locked stack or a recipe, nothing left on the cursor.
-- onDone(res) once at the end: res = { sold = { {id, name, n, gold} }, short = { {id, name, want,
-- got, why} }, n, gold, stopped = nil | "closed" | "nogold" | "busy" | "error" }.
-- (Core's vendor-sale watch records each sale in Profit & loss: nothing is recorded here.)
---------------------------------------------------------------------------
PC.SELL_POLL = 0.1 -- seconds between checks
PC.SELL_WAIT = 6   -- how long a sale or a split may take to land (lag)

local function SlotInfo(bag, slot)
    local C = C_Container
    if C and C.GetContainerItemInfo then
        local info = C.GetContainerItemInfo(bag, slot)
        if info then return info.itemID, info.stackCount or 1, info.isLocked end
        return nil
    end
    if GetContainerItemInfo then
        local _, n, locked, _, _, _, _, _, _, id = GetContainerItemInfo(bag, slot)
        if id then return id, n or 1, locked end
    end
end

-- what's on the cursor: an item's id, true for anything else, nil when it's empty
local function OnCursor()
    if CursorHasItem and not CursorHasItem() then return nil end
    if GetCursorInfo then
        local kind, id = GetCursorInfo()
        if kind == "item" then return id end
        return kind and true or nil
    end
    return CursorHasItem and CursorHasItem() or nil
end
local function Clear() if ClearCursor then ClearCursor() end end

-- this item's stacks a vendor will take (unlocked, worth something), how many in all, any locked
local function Stacks(id)
    local out, total, locked = {}, 0, false
    for _, s in ipairs(Bags()) do
        if s.id == id then
            total = total + s.n
            if s.locked then locked = true elseif not s.noValue then out[#out + 1] = s end
        end
    end
    return out, total, locked
end

-- an empty slot in a bag that takes this item (nil when there's none)
local function EmptySlot(id)
    local numSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    if not numSlots then return nil end
    for _, bag in ipairs(PC:PlayerBags()) do
        if PC:CanHold(bag, id) then
            for slot = 1, numSlots(bag) or 0 do
                if not SlotInfo(bag, slot) then return bag, slot end
            end
        end
    end
end

-- The next stack to sell for exactly n: a whole stack that fits (smallest first, or one that makes an
-- exact fit with the same number of stacks), else the smallest bigger one to split n off. -> stack, whole
local function NextStack(stacks, n)
    table.sort(stacks, function(a, b) return a.n < b.n end)
    local pick, rest, sum = {}, {}, 0
    for _, s in ipairs(stacks) do
        if sum + s.n <= n then pick[#pick + 1] = s; sum = sum + s.n else rest[#rest + 1] = s end
    end
    for k = 1, (sum < n) and #pick or 0 do
        for _, b in ipairs(rest) do
            if sum - pick[k].n + b.n == n then return b, true end
        end
    end
    if pick[1] then return pick[1], true end
    return rest[1], false
end
PC.SellNextStack = NextStack

function PC:SellExact(list, onDone, quiet)
    local res = { sold = {}, short = {}, n = 0, gold = 0 }
    if self.selling then
        -- one sale at a time: a second list worked out now could sell what the first already sold
        self.Buy:Say("Still selling to the vendor...")
        res.stopped = "busy"
        if onDone then onDone(res) end
        return false
    end
    local jobs, byID = {}, {}
    for _, it in ipairs(list or {}) do
        local id, n = it.id or it[1], math.floor(tonumber(it.n or it[2]) or 0)
        if id and n > 0 then
            local j = byID[id]
            if not j then j = { id = id, want = 0, got = 0, gold = 0 }; byID[id] = j; jobs[#jobs + 1] = j end
            j.want = j.want + n
            if self:NeverSell(id) then j.done, j.why = true, "recipes are never sold" end
        end
    end
    local run = {}
    self.selling = run
    local i, step = 1, nil
    local function finish(stopped)
        if run.over then return end
        run.over = true
        if self.selling == run then self.selling = nil end
        if run.cursor and OnCursor() then Clear() end
        for _, j in ipairs(jobs) do
            local name = self:ItemName(j.id) or ("item " .. j.id)
            if j.got > 0 then
                res.sold[#res.sold + 1] = { id = j.id, name = name, n = j.got, gold = j.gold }
                res.n, res.gold = res.n + j.got, res.gold + j.gold
            end
            if j.got < j.want then
                res.short[#res.short + 1] = { id = j.id, name = name, want = j.want, got = j.got,
                    why = j.why or (stopped == "closed" and "the vendor window closed") or "selling stopped" }
            end
        end
        res.stopped = stopped
        if not quiet then
            local t = self:SellSummary(res)
            if t ~= "" then self.Buy:Say(t) end
        end
        if onDone then onDone(res) end
        self:RefreshUI()
    end
    -- the next check, a moment from now (an error ends the run: never stuck "selling")
    local function later(fn)
        C_Timer.After(self.SELL_POLL, function()
            if not run.over and not self:Safe("selling", fn) then finish("error") end
        end)
    end
    -- check every SELL_POLL until cond() holds (then ok()) or SELL_WAIT runs out (then late())
    local function waitFor(cond, ok, late)
        local t0 = GetTime()
        local function poll()
            if cond() then return ok() end
            if GetTime() - t0 >= self.SELL_WAIT then return late() end
            later(poll)
        end
        later(poll)
    end
    local function stop(j, why) j.done, j.why = true, why; return step() end
    -- sell the c of the item sitting at s, then wait until it has left your bags and the gold is in
    local function sell(j, s, c)
        local id, n, locked = SlotInfo(s.bag, s.slot)
        if id ~= j.id or n ~= c or locked then return later(step) end -- it moved: work it out again
        local _, before = Stacks(j.id)
        local money, gain = GetMoney(), 0
        UseBagItem(s.bag, s.slot)
        local function gone()
            local sid, sn = SlotInfo(s.bag, s.slot)
            local _, now = Stacks(j.id)
            return now <= before - c and not (sid == j.id and sn == c)
        end
        waitFor(function()
            local m = GetMoney()
            gain, money = gain + math.max(m - money, 0), m -- (what you buy meanwhile doesn't hide it)
            return gain > 0 and gone()
        end, function()
            j.got, j.gold = j.got + c, j.gold + gain
            self:PlanMadeUsed(j.id, c)
            step()
        end, function()
            if not gone() then return stop(j, self.merchantOpen and "the vendor didn't take it" or "the vendor window closed") end
            -- it left your bags but no gold came in: counted, and nothing more is sold
            j.got = j.got + c
            self:PlanMadeUsed(j.id, c)
            j.why = "no gold came in for the last sale"
            finish("nogold")
        end)
    end
    -- split r off stack s into an empty slot, wait until exactly r sit there, then sell them
    local function split(j, s, r)
        local eb, es = EmptySlot(j.id)
        if not eb then return stop(j, "no free bag slot to split a stack") end
        local C = C_Container
        local splitFn = (C and C.SplitContainerItem) or SplitContainerItem
        local pick = (C and C.PickupContainerItem) or PickupContainerItem
        if not (splitFn and pick) then return stop(j, "stacks can't be split here") end
        local id, n, locked = SlotInfo(s.bag, s.slot)
        if id ~= j.id or locked or (n or 0) <= r then return later(step) end
        if OnCursor() then Clear() end
        run.cursor = true
        splitFn(s.bag, s.slot, r)
        if OnCursor() ~= j.id then Clear(); run.cursor = nil; return stop(j, "the stack couldn't be split") end
        pick(eb, es)
        if OnCursor() then
            -- that bag won't take it ("doesn't go in that container"): back it goes, that bag is skipped
            Clear(); run.cursor = nil
            self.refusedBag[eb .. ":" .. j.id] = true
            j.refused = (j.refused or 0) + 1
            if j.refused >= 3 then return stop(j, "no bag would take the split stack") end
            return step()
        end
        run.cursor = nil
        waitFor(function()
            if not self.merchantOpen then return true end
            local tid, tn, tl = SlotInfo(eb, es)
            return tid == j.id and tn == r and not tl
        end, function()
            if not self.merchantOpen then return finish("closed") end
            sell(j, { bag = eb, slot = es }, r)
        end, function()
            if OnCursor() == j.id then Clear() end
            stop(j, "the split stack didn't arrive")
        end)
    end
    step = function()
        local j = jobs[i]
        while j and (j.done or j.got >= j.want) do i = i + 1; j = jobs[i] end
        if not j then return finish() end
        if not self.merchantOpen then return finish("closed") end
        local stacks, total, locked = Stacks(j.id)
        if locked and not j.waited then
            -- a stack of it is busy (being moved): give it a moment before working out what to sell
            j.waited = true
            return waitFor(function() local _, _, l = Stacks(j.id); return not l or not self.merchantOpen end, step, step)
        end
        if #stacks == 0 then
            return stop(j, total > 0 and "locked, or a vendor won't buy it" or (j.got > 0 and "no more in your bags" or "not in your bags"))
        end
        local s, whole = NextStack(stacks, j.want - j.got)
        if whole then return sell(j, s, s.n) end
        return split(j, s, j.want - j.got)
    end
    if not self:Safe("selling", step) then finish("error") end
    return true
end

-- One line for a finished vendor sale: what sold and the gold (with AH Profit and V Profit for
-- crafted goods), then what didn't sell and why. "" when there's nothing to say.
function PC:SellSummary(res, withProfit)
    local parts, text = {}, ""
    for _, s in ipairs(res.sold) do parts[#parts + 1] = s.n .. " " .. s.name end
    if #parts > 0 then
        text = ("Sold %s to the vendor for %s"):format(table.concat(parts, ", "), self:Money(res.gold))
        if withProfit then
            local ah, v
            for _, s in ipairs(res.sold) do
                local a, b = self.Sell:Profits(s.id, s.n, s.gold)
                if a then ah = (ah or 0) + a end
                if b then v = (v or 0) + b end
            end
            text = text .. " (" .. self.Sell:ProfitText(ah, v) .. ")"
        end
        text = "|cff40ff40" .. text .. ".|r"
    end
    for _, s in ipairs(res.short) do
        text = text .. (text ~= "" and " " or "") .. ("|cffff8040%d %s not sold: %s.|r"):format(s.want - s.got, s.name, s.why)
    end
    return text
end

---------------------------------------------------------------------------
-- What you've posted on the AH, remembered until it sells or comes back (cdb.posted[itemID] = { n, t })
-- so you don't craft the same thing again while it's still up for sale
---------------------------------------------------------------------------
local Posted = {}
PC.Posted = Posted
Posted.MAX_AGE = 3 * 86400 -- 48h listing + slack: after that it must have expired and come back

function Posted:Table()
    PC.cdb.posted = PC.cdb.posted or {}
    return PC.cdb.posted
end

function Posted:Add(itemID, n, each)
    if PC.PlanMadeUsed then PC:PlanMadeUsed(itemID, n) end
    PC.cdb.postEach = PC.cdb.postEach or {}
    PC.cdb.postEach[itemID] = math.max(each or 1, 1) -- how many one auction holds (one sale's worth)
    local t = self:Table()
    local e = t[itemID] or { n = 0 }
    e.n, e.t, e.name = e.n + n, time(), PC:ItemName(itemID)
    t[itemID] = e
    PC.cdb.postTimes = PC.cdb.postTimes or {}
    PC.cdb.postTimes[itemID] = time() -- when this batch went up (how long it's been listed)
    if PC.Learn then PC.Learn:Posted(itemID, n) end
end

-- When an item went up for sale (first seen, for posts made by hand)
function Posted:Since(itemID)
    PC.cdb.postTimes = PC.cdb.postTimes or {}
    local t = PC.cdb.postTimes[itemID]
    if not t then t = time(); PC.cdb.postTimes[itemID] = t end
    return t
end

-- An auction sold, or expired and came back in the mail: that many fewer posted
function Posted:Remove(itemID, n)
    local t = self:Table()
    local e = t[itemID]
    if not e then return end
    e.n = e.n - (n or 1)
    if e.n <= 0 then t[itemID] = nil end
end

function Posted:RemoveByName(name, n)
    if not name then return end
    for id, e in pairs(self:Table()) do
        if e.name == name then return self:Remove(id, n) end
    end
end

-- While the AH is open, the game's own list is the truth: replace what we remember with it
-- Classic-style AH: your auctions come from the "owner" list (asked for when the AH opens)
function Posted:SyncClassic()
    if not (GetNumAuctionItems and GetAuctionItemInfo) then return end
    local ok, num = pcall(GetNumAuctionItems, "owner")
    if not ok or type(num) ~= "number" then return end
    local fresh = {}
    for i = 1, num do
        local info = { pcall(GetAuctionItemInfo, "owner", i) }
        if info[1] then
            local name, count, saleStatus, itemID = info[2], info[4], info[17], info[18]
            if not itemID and name then itemID = PC:ItemIDByName(name) end
            if itemID and saleStatus ~= 1 then -- 1 = sold, the gold is on its way by mail
                fresh[itemID] = fresh[itemID] or { n = 0, t = time(), name = name }
                fresh[itemID].n = fresh[itemID].n + (count or 1)
            end
        end
    end
    PC.cdb.posted = fresh
    PC:RefreshUI()
end

function Posted:AskClassic()
    if GetOwnerAuctionItems then pcall(GetOwnerAuctionItems) end
end

function Posted:SyncFromAH()
    local A = C_AuctionHouse
    if not (A and A.GetNumOwnedAuctions and A.GetOwnedAuctionInfo) then return self:SyncClassic() end
    local ok, num = pcall(A.GetNumOwnedAuctions)
    if not ok or not num then return end
    local fresh = {}
    for i = 1, num do
        local ok2, a = pcall(A.GetOwnedAuctionInfo, i)
        if ok2 and a and a.itemKey and a.itemKey.itemID and a.status ~= 1 then -- 1 = sold, waiting in the mail
            local id = a.itemKey.itemID
            fresh[id] = fresh[id] or { n = 0, t = time(), name = PC:ItemName(id) }
            fresh[id].n = fresh[id].n + (a.quantity or 1)
        end
    end
    PC.cdb.posted = fresh
end

function Posted:Count(itemID)
    local e = self:Table()[itemID]
    if not e then return 0 end
    if time() - (e.t or 0) > self.MAX_AGE then self:Table()[itemID] = nil return 0 end
    return e.n
end

---------------------------------------------------------------------------
-- Sell: crafted items in your bags, at a smart price
---------------------------------------------------------------------------
local Sell = {}
PC.Sell = Sell
Sell.AH_CUT = 0.05
Sell.UNDERCUT = 0 -- no undercutting: match the cheapest listing

-- The recipe entry that makes an item (for its cost), from the latest analysis (looked up by item,
-- indexed once per analysis: this used to walk every recipe twice for every item you hold)
function Sell:EntryFor(itemID)
    local entries = (PC.UI and PC.UI.allEntries) or {}
    if self._efList ~= entries then
        local idx = {}
        for _, e in ipairs(entries) do -- (the first recipe making it wins, as before)
            if e.outID and not idx[e.outID] then idx[e.outID] = e end
            if e.r.output and not idx[e.r.output] then idx[e.r.output] = e end
            for _, o in ipairs(e.r.outputs or {}) do if not idx[o] then idx[o] = e end end
        end
        self._efList, self._efIdx = entries, idx
    end
    return self._efIdx[itemID]
end

-- AH Profit and V Profit for n of an item (nil when a price or what it cost isn't known);
-- vendGold: what the vendor really paid for them, when it's known
function Sell:Profits(itemID, n, vendGold)
    local cost = self:CostEach(itemID)
    if not cost then return nil, nil end
    local price = self:Price(itemID)
    local vend = vendGold or (PC:SellPrice(itemID) or 0) * n
    local ah = price and math.floor((price * (1 - self.AH_CUT) - cost) * n + 0.5) or nil
    local v = vend > 0 and math.floor(vend - cost * n + 0.5) or nil
    return ah, v
end

function Sell:ProfitText(ah, v)
    return ("Auction Profit %s · Vendor Profit %s"):format(PC:Money(ah, true, true), PC:Money(v, true, true))
end

-- What one crafted item cost you in materials
-- What one cost you: what you really paid when ProfitCrafter saw you craft it (known = true),
-- else today's materials. Never the lower of the two: selling below what you paid is a loss.
function Sell:CostEach(itemID)
    local made = PC:MadeEach(itemID)
    local e = self:EntryFor(itemID)
    local now = e and e.cost and e.cost / math.max(e.r.qty or 1, 1) or nil
    if made then return math.max(made, now or 0), true end
    return now, false
end

-- Smart price: the cheapest listing (no undercutting); nil if we have no AH price.
-- Never below what it cost you (after the AH's cut): then it says "hold".
function Sell:Price(itemID)
    local d = PC:DepthTable()[itemID]
    local cheapest = d and d.list and d.list[1] and d.list[1].p or PC:Price(itemID)
    local floorPrice
    local cost, known = self:CostEach(itemID)
    if cost then floorPrice = math.ceil(cost / (1 - self.AH_CUT)) end
    if not cheapest then return nil, floorPrice, cost, nil, known end
    -- match the cheapest listing: no undercutting
    local price = math.max(cheapest - self.UNDERCUT, 1)
    -- exact to the copper. Only Retail's AH refuses copper in a price (it wants whole silver): there,
    -- under 1 silver can't match the market (1 silver when a thousand sit at 6 copper never sells): not posted.
    local tooCheap = false
    if self:WholeSilver() then
        if price < 100 then tooCheap = true end
        price = math.max(price - price % 100, 100)
    end
    return price, floorPrice, cost, tooCheap, known
end

-- This AH only takes prices in whole silver: Retail's. WoW Forever and classic take copper.
function Sell:WholeSilver()
    return not PC.FOREVER and not self:Classic()
end

-- Selling on the AH at all makes sense at this price (under 1s it can't be listed at the market price)
function PC:AHSellable(price)
    if not price then return false end
    return not (PC.Sell and PC.Sell:WholeSilver() and price < 100)
end

-- Crafted items you can sell: { id, name, have, price, floor, cost, profit, hold, stock }
-- Only things that came from your plan: what the current plan makes, what you crafted from a plan,
-- and your keep-in-stock items. Anything else in your bags is never touched.
Sell.PILE = 5 -- this many of one thing you made, with no plan for them, is a pile to deal with

-- What a thing you're holding is worth each way, and which way wins: on the auction house (after
-- its cut), as dust, or to a vendor.
function Sell:Recommend(id)
    local Sy = PC.Synergy
    local ah = PC:Price(id)
    local ahNet = ah and ah > 0 and (ah * (1 - (self.AH_CUT or 0.05))) or nil
    local vend = PC:SellPrice(id) or 0
    local dust = (Sy and Sy.CanDisenchant and Sy:CanDisenchant(id) and Sy.Value and Sy:EnchantingSkill()) and Sy:Value(id) or nil
    local best, what
    if ahNet then best, what = ahNet, "post" end
    if dust and (not best or dust > best) then best, what = dust, "disenchant" end
    if vend > 0 and (not best or vend > best) then best, what = vend, "vendor" end
    return what or "post", best or 0
end

-- Things you made that no plan is looking after any more. They go into the next plan you make, with
-- what to do with each one, so nothing is left sitting in your bags.
function Sell:LeftoverList()
    local out, cdb = {}, PC.cdb
    if not cdb then return out end
    local counts = PC.BagCounts and PC:BagCounts() or {}
    local crafted = self:CraftedIDs()
    local inPlan, stock, noSell = {}, self:Stock() or {}, PC:NoSell() or {}
    for recipeID in pairs(PC:CurrentPlan() or {}) do
        local r = cdb.recipes[recipeID]
        if r then
            if r.output then inPlan[r.output] = true end
            for _, o in ipairs(r.outputs or {}) do inPlan[o] = true end
        end
    end
    -- materials the plan in hand still needs are not leftovers
    local okL, list = pcall(PC.CombinedShoppingList, PC, PC.UI and PC.UI:PlanEntries() or {}, 1)
    for _, it in ipairs(okL and list or {}) do if (it.need or 0) > 0 then inPlan[it.id] = true end end
    for id, n in pairs(counts) do
        if n > 0 and crafted[id] and not inPlan[id] and not stock[id] and not noSell[id] then
            local what, each = self:Recommend(id)
            out[#out + 1] = { id = id, n = n, name = PC:ItemName(id) or ("item " .. id), what = what, each = each }
        end
    end
    table.sort(out, function(x, y) return (x.each * x.n) > (y.each * y.n) end)
    return out
end

-- Hand them to a plan: from here on they're its goods, so they're posted, vendored or disenchanted
-- like anything else it made.
function Sell:AdoptLeftovers(planName)
    local cdb = PC.cdb
    if not cdb or not planName then return 0 end
    local list = self:LeftoverList()
    cdb.planCrafted, cdb.planCraftedPlan = cdb.planCrafted or {}, cdb.planCraftedPlan or {}
    local made = PC:PlanMade(planName)
    cdb.planLeftover = {}
    for _, l in ipairs(list) do
        cdb.planCrafted[l.id] = cdb.planCrafted[l.id] or time()
        cdb.planCraftedPlan[l.id] = planName
        cdb.planLeftover[l.id] = true -- dealt with first: it's bag space back
        made[l.id] = math.max(made[l.id] or 0, l.n)
        if l.what == "disenchant" and PC.Synergy and PC.Synergy.Queue then pcall(PC.Synergy.Queue, PC.Synergy, l.id, l.n) end
    end
    return #list
end

-- Everything your recipes can make (worked out once per refresh)
function Sell:CraftedIDs()
    local memo = PC.Memo and PC:Memo()
    if memo and memo.craftedIDs then return memo.craftedIDs end
    local out = {}
    for _, r in pairs(PC.cdb and PC.cdb.recipes or {}) do
        if r.output then out[r.output] = true end
        for _, o in ipairs(r.outputs or {}) do out[o] = true end
    end
    if memo then memo.craftedIDs = out end
    return out
end

function Sell:PlanItems()
    local known = {}
    local cdb = PC.cdb
    self.orphan = {}
    if not cdb then return known end
    -- ONLY what the current plan makes to sell: its finished products. Never materials, in-between
    -- crafts, leftovers from older plans, or dust from disenchanting that the plan isn't selling.
    local skill = PC.UI and PC.UI.IsSkillPlan and PC.UI:IsSkillPlan()
    local route = {}
    for _, e in ipairs(PC.UI and PC.UI.PlanEntries and PC.UI:PlanEntries() or {}) do route[e.id] = e.route end
    -- a skill-up plan: only what it crafted (and only as many as it made), sold further down
    if skill and not self.purge then
        for id, n in pairs(PC:PlanMade()) do if n > 0 then known[id] = true end end
        for id in pairs(self:Stock()) do known[id] = true end
        if not self.purge then for id in pairs(PC:NoSell()) do known[id] = nil end end
        return known
    end
    for recipeID in pairs(PC:CurrentPlan()) do
        local r = cdb.recipes[recipeID]
        if r and route[recipeID] == "Disenchant" then
            -- made for its dust (a money plan): the dust is what's sold. A skill-up plan sells no dust.
            if PC.Synergy and r.output and not skill then
                for _, m in ipairs(PC.Synergy:Yield(r.output) or {}) do known[m[1]] = true end
            end
        elseif r then
            if r.output then known[r.output] = true end
            for _, o in ipairs(r.outputs or {}) do known[o] = true end
        end
    end
    -- AH -> vendor flips you bought: they go to a vendor (never posted)
    for id in pairs(cdb.ahFlipItems or {}) do known[id] = true end
    -- crafted for this plan (finished crafts leave the plan, their items still sell); crafted for an
    -- earlier plan and still in your bags: not this plan's, so left alone
    cdb.planCrafted = cdb.planCrafted or {}
    local which = cdb.planCraftedPlan or {}
    local pn = PC:PlanName()
    for id, t in pairs(cdb.planCrafted) do
        -- Out of your bags isn't finished with: posting them empties the bags, and what doesn't sell
        -- comes back through the mail. Dropping the record there was why a plan's own goods came home
        -- as strangers - no plan would own them, so only the "start small" two or three went back up
        -- while the rest sat in the bags. The record is kept for the day, as the posting cap is.
        local away = PC:BagCount(id) == 0 and (PC.Posted and PC.Posted:Count(id) or 0) == 0
            and (PC.MailPending and PC:MailPending(id) or 0) == 0
        if away and time() - t > 86400 then cdb.planCrafted[id] = nil; which[id] = nil
        elseif which[id] == pn then known[id] = true
        -- made by a plan that's finished and gone (a temporary plan is removed when it's done): its
        -- items are still in your bags, so the job gets finished - sold, or disenchanted
        elseif which[id] and not PC:Plans()[which[id]] and not (cdb.planLeftover and cdb.planLeftover[id]) then known[id] = true end
    end
    -- dust and essences from disenchanting are sold, plan or no plan (what the plan in use still needs
    -- for its crafts is kept back further down); a skill-up plan sells none (it returned above)
    for id in pairs(cdb.deSell or {}) do
        if PC:BagCount(id) == 0 then cdb.deSell[id] = nil else known[id] = true end
    end
    -- A pile of something you made, sitting in your bags with no plan claiming it (a plan that was
    -- replaced, a craft you did yourself): never left to rot. Five or more and it's handled like
    -- anything else - posted, sold to a vendor or disenchanted, whichever is worth most.
    local counts = PC.BagCounts and PC:BagCounts() or nil
    if counts then
        local crafted = self:CraftedIDs()
        for id, n in pairs(counts) do
            if n >= self.PILE and crafted[id] and not known[id] then known[id] = true end
        end
    end
    -- items you took off this plan's tasks ("post 4 Strange Dust" removed): not sold
    if not self.purge then for id in pairs(PC:NoSell()) do known[id] = nil end end
    -- keep-in-stock items follow their own rules
    for id in pairs(self:Stock()) do known[id] = true; self.orphan[id] = nil end
    -- purging: every crafted item in your bags, whatever plan it came from (except the ones you unticked)
    if self.purge then
        local skip = self:PurgeSkip()
        for _, r in pairs(cdb.recipes) do
            if r.output and not skip[r.output] then known[r.output] = true end
            for _, o in ipairs(r.outputs or {}) do if not skip[o] then known[o] = true end end
        end
    end
    return known
end

-- Items you unticked: the purge leaves them alone (they sell only at a profit, as usual)
function Sell:PurgeSkip()
    if self.noSkip then return {} end -- (PurgeCandidates: every one, ticked or not)
    PC.cdb.purgeSkip = PC.cdb.purgeSkip or {}
    return PC.cdb.purgeSkip
end

function Sell:SetPurgeSkip(itemID, skip)
    self:PurgeSkip()[itemID] = skip and true or nil
    PC:RefreshUI()
    if PC.Steps then PC.Steps:Refresh() end
end

-- Every crafted item in your bags, ticked or not: { id, name, have, vendor, skipped }
-- (the saved unticks are never swapped out to do this: an error halfway used to lose them)
function Sell:PurgeCandidates()
    local skip, was = self:PurgeSkip(), self.purge
    self.noSkip = true
    local ok, list = pcall(self.PurgeList, self)
    self.noSkip, self.purge = nil, was -- (PurgeList turns purge on for itself; an error there mustn't leave it on)
    if not ok then error(list, 0) end
    for _, it in ipairs(list) do it.skipped = skip[it.id] and true or false end
    return list
end

---------------------------------------------------------------------------
-- Purge: sell every crafted item in your bags to clear space, even at a loss, each one wherever it
-- brings in more gold (the AH after its cut and deposit, or a vendor). Turns itself off when done.
---------------------------------------------------------------------------
function Sell:PurgeList()
    local was = self.purge
    self.purge = true
    local out = {}
    local skip = self:PurgeSkip()
    -- what the plan still uses (bolts, bars...) isn't "crafted to sell": never purged
    local uses = {}
    for _, e in ipairs(PC.UI and PC.UI.PlanEntries and PC.UI:PlanEntries() or {}) do
        for _, rg in ipairs(e.r.reagents or {}) do
            for _, id in ipairs(PC:ReagentIDs(rg)) do uses[id] = true end
        end
    end
    local de = PC.cdb and PC.cdb.deQueue or {}
    for _, it in ipairs(self:Items()) do
        if it.sellN > 0 and not skip[it.id] and not uses[it.id] and not de[it.id] and (it.vendor or it.price) then out[#out + 1] = it end
    end
    self.purge = was
    return out
end

function Sell:SetPurge(on)
    self.purge = on and true or nil
    if on then
        local list = self:PurgeList()
        if #list == 0 then self.purge = nil; return PC.Buy:Say("No crafted items in your bags to purge.") end
        local n = 0
        for _, it in ipairs(list) do n = n + it.sellN end
        -- learned: things that had to be dumped below cost were a bad bet; Make me gold ranks them lower
        if PC.Learn then
            self.purge = nil
            local holding = {}
            for _, it in ipairs(self:Items()) do if it.hold then holding[it.id] = true end end
            self.purge = true
            for _, it in ipairs(list) do if holding[it.id] then PC.Learn:Purged(it.id) end end
        end
        PC.Buy:Say(("|cffff8040Purging %d crafted item%s: each goes wherever pays more, even below cost.|r"):format(n, n == 1 and "" or "s"))
    else
        PC.Buy:Say("Purge off: crafted items sell only at a profit again.")
    end
    PC:RefreshUI()
end

-- Purge materials (only when you ask): spare materials in your bags the plan doesn't need, sold to a
-- vendor. Plan materials and tools are never in it. { id, name, n, value }
-- How many more of an item to have up on the AH right now: what you sold of it in the last day (at
-- least 2), minus what's already listed. Scan estimates of "sold today" overcount (cancels and
-- expiries look like sales), so your own sales decide.
-- Sales the game announced ("A buyer has been found for your auction of X"): counted the moment they
-- sell, not an hour later when the gold reaches your mailbox. { t, name, id, n, fast }
PC.FAST_SALE = 3600 -- sold within an hour of going up
function PC:SoldNow()
    self.cdb.soldNow = self.cdb.soldNow or {}
    local L, cut = self.cdb.soldNow, time() - 2 * 86400
    while L[1] and (L[1].t or 0) < cut do table.remove(L, 1) end
    return L
end

function PC:NoteAuctionSold(name)
    if type(name) ~= "string" or self.IsSecret(name) or name == "" then return end
    name = name:match("%[(.-)%]") or name
    local id = self:ItemIDByName(name)
    local each = id and self.cdb.postEach and self.cdb.postEach[id] or 1
    local up = id and self.cdb.postTimes and self.cdb.postTimes[id]
    local L = self:SoldNow()
    L[#L + 1] = { t = time(), name = name, id = id, n = each, fast = (up and time() - up <= self.FAST_SALE) or nil }
    if id and self.Posted then self.Posted:Remove(id, each) end
    if id and self.Learn then self.Learn:Sold(id, each) end
    self:RefreshUI()
end

-- The gold for an announced sale reached the mailbox: it's in the ledger now (returns how many it counted)
function PC:TakeSoldNow(name)
    if self.IsSecret(name) then return end
    for i, e in ipairs(self:SoldNow()) do
        if e.name == name then table.remove(self.cdb.soldNow, i) return e.n or 1 end
    end
end

-- How many of yours sold since a time: gold collected from the mail, and sales announced but not collected
function PC:SoldSince(itemID, cut)
    local name = self:ItemName(itemID)
    if not name then return 0, false end
    local sold, fast = 0, false
    local s = self:SellIndex()[name] -- (your sales of this item only, not the whole ledger)
    for _, e in ipairs(s and s.list or {}) do
        if e[1] >= cut then sold = sold + (e[2] or 1) end
    end
    for _, e in ipairs(self:SoldNow()) do
        if e.name == name and e.t >= cut then sold = sold + (e.n or 1); fast = fast or e.fast == true end
    end
    return sold, fast
end

function PC:SoldToday(itemID)
    return (self:SoldSince(itemID, time() - 86400))
end

-- How many more to put up now: a few unless they're selling, then more (the same rule as crafting)
function Sell:PostCap(itemID)
    -- dust and essences from disenchanting: no "start small" for these (they're traded by the
    -- thousand): everything you have goes up, so none of it sits in your bags
    if PC.cdb and PC.cdb.deSell and PC.cdb.deSell[itemID] then return 100000 end
    local up = PC.Posted and PC.Posted.Count and PC.Posted:Count(itemID) or 0
    local most = PC.MakeGold and PC.MakeGold.HoldCap and PC.MakeGold:HoldCap(itemID)
    if most then
        -- (what's already made is posted even during the wait: at least the test batch's worth)
        most = math.max(most, PC.MakeGold.TEST_GEAR or 2)
    else
        local stack = math.max(PC:StackSize(itemID) or 1, 1)
        most = math.max(PC:SoldToday(itemID), 2 * stack)
    end
    -- what a plan made to sell in the last day all gets posted (the plan already judged how many the
    -- market takes): never 2 on the AH and the rest left in your bags
    local cdb = PC.cdb
    local t = cdb and cdb.planCrafted and cdb.planCrafted[itemID]
    local plan = cdb and cdb.planCraftedPlan and cdb.planCraftedPlan[itemID]
    if t and plan and time() - t < 86400 then
        local madeN = ((cdb.planMadeN or {})[plan] or {})[itemID]
        if type(madeN) == "number" and madeN > most then most = madeN end
    end
    -- what you yourself sell of it a day: never more than two days' worth up at once (deposits on
    -- things that sit unsold are gold lost), whatever a plan made
    local own = PC.MakeGold and PC.MakeGold.OwnPerDay and PC.MakeGold:OwnPerDay(itemID)
    if own and not (PC.cdb and PC.cdb.deSell and PC.cdb.deSell[itemID]) then most = math.min(most, math.max(math.ceil(own * 2), 1)) end
    return math.max(most - up, 0)
end

-- What you paid for one of an item lately (the last 7 days of purchases), or nil
-- (purchases by item, indexed once per ledger change: the ledger holds up to 10,000 entries)
local buyIdx, buyKey
function Sell:PaidEach(itemID)
    local name = PC:ItemName(itemID)
    if not name then return nil end
    local L = PC.cdb.ledger or {}
    local last = L[#L]
    local key = #L .. ":" .. tostring(L[1] and L[1].t) .. ":" .. tostring(last and last.t) .. ":" .. tostring(PC.ledgerVersion or 0)
    if key ~= buyKey then
        buyIdx, buyKey = {}, key
        for _, e in ipairs(L) do
            if e.kind == "buy" and e.item then
                buyIdx[e.item] = buyIdx[e.item] or {}
                table.insert(buyIdx[e.item], e)
            end
        end
    end
    local cut, n, total = time() - 7 * 86400, 0, 0
    for _, e in ipairs(buyIdx[name] or {}) do
        if e.t >= cut then n = n + (e.qty or 1); total = total + e.amount end
    end
    if n == 0 then return nil end
    return total / n
end

-- Never sold to a vendor for less than you paid for it: materials bought for crafting (1s 80c maple
-- seeds don't go back for 50c). Returns true when a vendor sale would be a loss.
function Sell:LossToVendor(itemID)
    local paid = self:PaidEach(itemID)
    local vend = PC.SellPrice and PC:SellPrice(itemID) or 0
    return paid ~= nil and vend < paid
end

function Sell:PurgeMatsList()
    local out = {}
    local B = PC.Bank
    -- (StoreList already leaves out what the plan needs)
    for _, it in ipairs(B and B.StoreList and B:StoreList() or {}) do
        local price = PC.SellPrice and PC:SellPrice(it.id) or 0
        if (it.kind == "material" or it.kind == "stash") and price > 0 and not PC:IsTool(it.id) and not self:LossToVendor(it.id) then
            local n = it.qty
            if n > 0 then out[#out + 1] = { id = it.id, name = it.name or PC:ItemName(it.id) or ("item " .. it.id), n = n, value = price * n } end
        end
    end
    table.sort(out, function(a, b) return a.value > b.value end)
    return out
end

function Sell:AskPurgeMats()
    local list = self:PurgeMatsList()
    if #list == 0 then return PC.Buy:Say("No spare materials in your bags: everything there is for your plan.") end
    local names, gold = {}, 0
    for _, it in ipairs(list) do
        names[#names + 1] = it.n .. " " .. it.name
        gold = gold + it.value
    end
    local function go()
        Sell.purgeMats = true
        if PC.merchantOpen then Sell:SellMats() end
        PC:RefreshUI()
    end
    if not (PC.UI and PC.UI.Ask) then return go() end
    PC.UI:Ask("ProfitCrafterPurgeMats", {
        title = "Sell spare materials?", sub = ("About %s at a vendor"):format(PC:Money(gold, false, true)),
        subColor = { 1, 0.82, 0 },
        sections = { { lines = names }, { lines = { "Materials your plan still needs are kept." }, bullets = false } },
        buttons = { { text = "Purge", onClick = go }, { text = "Cancel" } },
        fit = true,
    })
end

-- at an open vendor: sell the purge list, exactly what's spare (a stack is split if it has to be)
function Sell:SellMats()
    if not PC.merchantOpen then return 0 end
    local list, n = {}, 0
    for _, it in ipairs(self:PurgeMatsList()) do list[#list + 1] = { id = it.id, n = it.n }; n = n + it.n end
    if n == 0 then Sell.purgeMats = nil; PC:RefreshUI() return 0 end
    local ok = PC:SellExact(list, function(res)
        if not res.stopped then Sell.purgeMats = nil end -- done (stopped part way: the task stays)
    end)
    return ok and n or 0
end

function Sell:AskPurge()
    if not (PC.UI and PC.UI.Ask) then return self:SetPurge(true) end
    local list = self:PurgeList()
    local names, gold = {}, 0
    for _, it in ipairs(list) do
        local ahP, vP = self:Profits(it.id, it.sellN)
        names[#names + 1] = ("%d %s (%s)"):format(it.sellN, it.name, self:ProfitText(ahP, vP))
        local ah = it.price and it.price * (1 - self.AH_CUT) or 0
        gold = gold + math.max(ah, it.vendorPrice or 0) * it.sellN
    end
    PC.UI:Ask("ProfitCrafterPurge", {
        title = "Purge crafted items?", sub = ("Clears bag space, about %s in all"):format(PC:Money(gold, false, true)),
        subColor = { 1, 0.82, 0 },
        sections = { { lines = names }, { lines = {
            "Each sells wherever pays more (auction or vendor), even below what it cost.",
            "Untick any in the Plan tasks list to keep it.",
        }, bullets = false } },
        buttons = { { text = "Purge", onClick = function() Sell:SetPurge(true) end }, { text = "Cancel" } },
        fit = true,
    })
end

-- What the plan still uses of each item (dust for the oil, bolts for the gloves...): never sold
function Sell:PlanNeeds()
    local need = {}
    local UI = PC.UI
    if not UI or not UI.PlanEntries then return need end
    local ok, list = pcall(PC.CombinedShoppingList, PC, UI:PlanEntries(), 1)
    for _, it in ipairs(ok and list or {}) do
        if it.id and (it.need or 0) > 0 then need[it.id] = math.max(need[it.id] or 0, it.need) end
    end
    return need
end

-- (asked for many times in one refresh by the Task Button, the task list, the bank and the vendor:
-- worked out once per refresh and handed back to all of them)
function Sell:Items()
    local memo = PC:Memo()
    if not memo then return PC:WithMemo(self.Items, self) end -- (outside a refresh its parts still share their work)
    -- (a purge with items unticked is worked out apart from one with every item: the purge list and
    -- the tick list used to get whichever came first)
    local key = "sellItems:" .. (not self.purge and "n" or next(self:PurgeSkip()) and "ps" or "p")
    if memo and memo[key] then return memo[key] end
    local out = PC:Timed("sellItems", self.ItemsRaw, self)
    if memo then memo[key] = out end
    return out
end

function Sell:ItemsRaw()
    local known = self:PlanItems()
    local skillPlan = PC.UI and PC.UI.IsSkillPlan and PC.UI:IsSkillPlan()
    local planNeed = self:PlanNeeds()
    local have = {}
    local deQ = PC.cdb.deQueue or {}
    -- gear upgrades you crafted to wear: kept (for 3 days, time enough to put them on)
    local keepGear = PC.cdb.gearKeep or {}
    -- once you're wearing it, the job's done: any more of them you make are sold like anything else
    local function wearing(id)
        if IsEquippedItem then local ok, on = pcall(IsEquippedItem, id); if ok and on ~= nil then return on and true or false end end
        for sl = 1, 19 do
            local okw, worn = pcall(GetInventoryItemID or function() end, "player", sl)
            if okw and worn == id then return true end
        end
        return false
    end
    for id, t in pairs(keepGear) do
        if time() - t > 3 * 86400 or wearing(id) then keepGear[id] = nil end
    end
    for _, s in ipairs(Bags()) do
        -- tools are kept, never sold; greens waiting to be disenchanted aren't posted
        if known[s.id] and not PC:IsTool(s.id) and not deQ[s.id] and not keepGear[s.id] then have[s.id] = (have[s.id] or 0) + s.n end
    end
    -- what was waiting to be sold when you closed a plan with the X is left alone: only what you
    -- make after that counts (Purge crafted items still sells everything)
    local closed = PC.cdb.sellClosed
    if closed and not self.purge then
        for id, was in pairs(closed) do
            local n = have[id] or 0
            if n <= was then
                have[id] = nil
                if n > 0 then closed[id] = n else closed[id] = nil end
            else
                have[id] = n - was
            end
        end
    end
    -- keep-in-stock targets show even with none in your bags
    for id in pairs(self:Stock()) do if known[id] and not have[id] then have[id] = 0 end end
    local out = {}
    for id, n in pairs(have) do
        local price, floorPrice, cost, tooCheap, costKnown = self:Price(id)
        local hold = price and floorPrice and price < floorPrice or false
        if tooCheap then hold = true end
        local profit, duration, deposit
        if price and n > 0 then
            local qty = PC:IsCommodity(id) and n or 1
            if PC.db.postDuration then duration = PC.db.postDuration; deposit = self:Deposit(id, duration, qty) or 0
            else duration, deposit = self:BestDuration(id, qty, price) end
        end
        if price and cost then profit = (price * (1 - self.AH_CUT) - cost) * n - (deposit or 0) end
        -- the vendor instead, when it pays more than the AH after its cut and deposit (or the AH can't
        -- beat what it cost) - and only when that's still a profit
        local vend = PC.SellPrice and PC:SellPrice(id) or 0
        -- both ways, whichever it goes (AH Profit after the cut and deposit, V Profit), nil = not known
        local ahProfit, vendorProfit = profit, (cost and vend > 0) and (vend - cost) * n or nil
        local vendor = false
        local via = PC.cdb.sellVia and PC.cdb.sellVia[id]
        if via == "Vendor" and vend > 0 and n > 0 and not (self.purge and not self:PurgeSkip()[id])
            and not (costKnown and cost and vend < cost) then
            -- you chose the vendor for this one (a vendor flip): the vendor - but never for less than
            -- what you really paid for them (then it's held like anything else below cost)
            vendor = true
        elseif (self.purge and not self:PurgeSkip()[id]) or (self.orphan and self.orphan[id] and price) then
            -- clearing space (or a leftover from an old plan): no profit rule, just whichever brings in more gold
            hold = tooCheap or false
            local ahEach = price and (price * (1 - self.AH_CUT) - (deposit or 0) / math.max(PC:IsCommodity(id) and n or 1, 1)) or nil
            vendor = vend > 0 and n > 0 and (tooCheap or not ahEach or vend >= ahEach)
                and (self.purge or not (cost and vend < cost)) -- (a leftover: never to a vendor at a loss)
            if vendor then hold = false end
        -- only when ProfitCrafter knows what these really cost you: never on a guess
        elseif via ~= "AH" and vend > 0 and n > 0 and costKnown and cost and vend >= cost then
            -- a vendor flip (the vendor pays more than it cost): to the vendor, AH or not
            vendor = true
        end
        if vendor then hold = false; profit = cost and (vend - cost) * n or nil end
        -- the AH only when it pays: the deposit has to fit your spending limit, and what it brings in
        -- after the AH's cut and the deposit has to beat nothing (and a vendor). Otherwise a vendor
        -- when one pays, or it stays in your bags.
        if not vendor and price and n > 0 and not self.purge then
            local limit = math.min(GetMoney and GetMoney() or PC:Gold(), (PC.UI and PC.UI.PlanBudget and PC.UI:PlanBudget()) or math.huge)
            local qty = PC:IsCommodity(id) and n or 1
            local dep = deposit or (self.FeeEach and self:FeeEach(id) * qty) or 0
            local net = price * (1 - self.AH_CUT) * qty - dep
            if dep > limit or net <= 0 or (vend > 0 and net <= vend * qty) then
                -- a vendor only when it pays at least what it cost you: never sold at a loss, it's kept
                if vend > 0 and not (cost and vend < cost) then vendor = true; hold = false; profit = cost and (vend - cost) * n or nil
                else vendor = false; hold = true end
            end
        end
        -- what's for sale: everything above your Keep number (Keep 20 of 25 = sell 5)
        -- and never what the plan still needs to craft with (the dust you just made for the oil)
        local keep = math.max(self:Stock()[id] or 0, planNeed[id] or 0)
        if self.purge then keep = self:Stock()[id] or 0 end
        local sellN = math.max(n - keep, 0)
        -- on the AH: no more up at once than really sells in a day (more just comes back by mail and
        -- the deposit is lost) - what you yourself sold in the last day, at least 2, minus what's up
        if not vendor and not self.purge and sellN > 0 then sellN = math.min(sellN, self:PostCap(id)) end
        -- a skill-up plan: only as many as it crafted (made 2 bolts, have 20: sell 2), and only at a profit
        local skip = false
        if skillPlan and not self.purge and not self:Stock()[id] then
            sellN = math.min(sellN, PC:PlanMade()[id] or 0)
            if not profit or profit <= 0 or hold then skip = true end
        end
        if not skip then out[#out + 1] = { id = id, name = PC:ItemName(id) or ("Item " .. id), have = n, sellN = sellN, price = price, floor = floorPrice,
            cost = cost, profit = profit, hold = hold, stock = self:Stock()[id], duration = duration, deposit = deposit,
            vendor = vendor, vendorPrice = vend, tooCheap = tooCheap and not vendor,
            ahProfit = ahProfit, vendorProfit = vendorProfit } end
    end
    table.sort(out, function(a, b)
        if (a.have > 0) ~= (b.have > 0) then return a.have > 0 end
        return (a.profit or -1e12) > (b.profit or -1e12)
    end)
    return out
end

-- Can we post this from here?
-- Retail posts through C_AuctionHouse; the classic-style AH (WoW Forever) puts the item in the sell slot
-- and calls StartAuction. Either way works from here.
function Sell:Retail()
    local A = C_AuctionHouse
    return A and A.PostCommodity and A.PostItem and ItemLocation and ItemLocation.CreateFromBagAndSlot and true or false
end

function Sell:Classic()
    return not self:Retail() and StartAuction ~= nil and ClickAuctionSellItemButton ~= nil
end

function Sell:Supported()
    return self:Retail() or self:Classic()
end

-- Classic durations are 12/24/48 hours as minutes on most clients; some count them 1/2/3
function Sell:ClassicRunTime(duration)
    -- learned from a post you made yourself: exactly what the game sent then
    local L = PC.db and PC.db.auctionLearned
    if L and L.byIndex and L.byIndex[duration] then return L.byIndex[duration] end
    local unit = PC.db and PC.db.auctionRunTime
    if not unit then
        local native = AuctionFrameAuctions and AuctionFrameAuctions.duration
        if type(native) == "number" then unit = native < 100 and "index" or "minutes" end
    end
    if unit == "minutes" then return ({ [1] = 120, [2] = 480, [3] = 1440 })[duration] or 1440 end
    return duration -- the classic AH's own buttons send 1 / 2 / 3
end

-- Watch the game's own posting: whatever you post by hand teaches ProfitCrafter this client's format
function Sell:LearnFromManual()
    if self.learnHooked or not StartAuction or not hooksecurefunc then return end
    self.learnHooked = true
    hooksecurefunc("StartAuction", function(bid, buyout, runTime, stackSize)
        -- any post, yours or ProfitCrafter's: re-read your auctions so the plan knows what's up for sale
        C_Timer.After(1.5, function() Safe("auctions", Posted.AskClassic, Posted) end)
        if Sell.ourPost or type(runTime) ~= "number" then return end
        PC.db.auctionLearned = PC.db.auctionLearned or { byIndex = {} }
        local L = PC.db.auctionLearned
        if runTime <= 3 then
            PC.db.auctionRunTime = "index"
            for i = 1, 3 do L.byIndex[i] = i end
        else
            PC.db.auctionRunTime = "minutes"
            -- which of the three buttons it was: short, medium or long by size
            local hours = runTime / 60
            local idx = hours <= 2 and 1 or (hours <= 8 and 2) or (hours <= 12 and 1) or (hours <= 24 and (L.byIndex[1] == 120 and 3 or 2)) or 3
            L.byIndex[idx] = runTime
        end
        PC.Buy:Say("|cff40ff40Learned how this Auction House takes posts: ProfitCrafter's Post button will work the same way.|r")
    end)
end

-- The game said "Internal auction error" right after our post: the duration was in the wrong unit
-- for this client. Flip it, remember, and post again once.
function Sell:OnAuctionError()
    local p = self.pending
    if not p or GetTime() - p.t > 2 then return end
    self.pending = nil
    Posted:Remove(p.itemID, p.n)
    if p.retail then
        if p.many then
            self.oneAtATime = true
            return PC.Buy:Say("|cffff8040The Auction House refused posting them all at once. Click Post again: it'll post one at a time.|r")
        end
        return PC.Buy:Say("|cffff5555The Auction House refused that post. Try posting one yourself from the Auction House's Sell tab and tell me what it says.|r")
    end
    if p.retried then
        return PC.Buy:Say("|cffff5555The Auction House refused the post. Try it once from the Auction House's Auctions tab; after that ProfitCrafter will know this client's rules.|r")
    end
    -- the game only posts inside a click, so no automatic retry: switch format and let the next click try it
    local learned = PC.db.auctionLearned and next(PC.db.auctionLearned.byIndex or {})
    if not learned then
        local unit = (self:ClassicRunTime(1) == 1) and "minutes" or "index"
        PC.db.auctionRunTime = unit
        PC.Buy:Say(("|cffff8040The Auction House refused that post. Click Post again: it'll try %s durations. If it still fails, post one item yourself from the Auction House and ProfitCrafter learns how.|r"):format(unit == "index" and "1/2/3" or "minute"))
    else
        PC.Buy:Say("|cffff5555The Auction House refused that post. Post one item yourself from the Auction House's Sell tab so ProfitCrafter can learn this client's format.|r")
    end
    self.failedPost = (self.failedPost or 0) + 1
end

-- Classic: put a bag stack into the AH's sell slot (true when it got there)
function Sell:ClassicPlace(slot)
    if ClearCursor then ClearCursor() end
    local pick = (C_Container and C_Container.PickupContainerItem) or PickupContainerItem
    if not pick then return false end
    pick(slot.bag, slot.slot)
    ClickAuctionSellItemButton()
    if ClearCursor then ClearCursor() end
    local name = GetAuctionSellItemInfo and GetAuctionSellItemInfo()
    return name ~= nil
end

function Sell:CanPost(it)
    return it and it.sellN > 0 and it.price and not it.hold and PC.ahOpen and self:Supported()
end

Sell.DURATION = 2 -- 1 = 12 hours, 2 = 24 hours, 3 = 48 hours
Sell.HOURS_RETAIL = { [1] = 12, [2] = 24, [3] = 48 }
Sell.HOURS_CLASSIC = { [1] = 2, [2] = 8, [3] = 24 } -- the classic-style AH's three choices
Sell.HOURS = Sell.HOURS_RETAIL
-- the hours each duration choice means on this client
function Sell:Hours() return self:Classic() and self.HOURS_CLASSIC or self.HOURS_RETAIL end

-- Deposit the AH would charge to list qty of an item for a duration (nil if the game can't say)
function Sell:Deposit(itemID, duration, qty)
    local A = C_AuctionHouse
    if self:Classic() then
        -- exact once the item sits in the sell slot (Post puts it there first); else the usual 5% of vendor price per 12h
        if CalculateAuctionDeposit and GetAuctionSellItemInfo and GetAuctionSellItemInfo() then
            local ok, d = pcall(CalculateAuctionDeposit, self:ClassicRunTime(duration))
            if ok and d then return d end
        end
        local v = PC.SellPrice and PC:SellPrice(itemID) or 0
        return math.floor(v * qty * 0.05 * (self:Hours()[duration] or 24) / 12 + 0.5)
    end
    if not A then return nil end
    if PC:IsCommodity(itemID) and A.CalculateCommodityDeposit then
        local ok, d = pcall(A.CalculateCommodityDeposit, itemID, duration, qty)
        if ok and d then return d end
    elseif A.CalculateItemDeposit and ItemLocation then
        -- (where each item sits is read once per refresh: this used to scan your bags three times an item)
        local memo = PC:Memo()
        local first = memo and memo.firstSlot
        if not first then
            first = {}
            for _, s in ipairs(Bags()) do if not first[s.id] then first[s.id] = s end end
            if memo then memo.firstSlot = first end
        end
        local s = first[itemID]
        if s then
            local ok, d = pcall(A.CalculateItemDeposit, ItemLocation:CreateFromBagAndSlot(s.bag, s.slot), duration, 1)
            if ok and d then return d end
        end
    end
    return nil
end

-- Posting fees, estimated before anything is crafted: the AH takes a deposit up front (15% of the
-- vendor price per 12 hours), so a plan has to leave gold for it. Counted at the longest listing so
-- it never comes up short, plus a little per listing.
Sell.FEE_RATE = 0.15 -- per 12 hours
function Sell:FeeEach(itemID)
    local v = PC.SellPrice and PC:SellPrice(itemID) or 0
    local hours = self:Hours()[3] or 48
    return v * self.FEE_RATE * hours / 12
end

-- Gold to keep back for posting: the plan's AH crafts still to make, plus crafted items in your
-- bags waiting to go up
function PC:PostReserve(entries)
    local total = 0
    for _, e in ipairs(entries or {}) do
        local n = e.planCount or 0
        if n > 0 and e.route ~= "Vendor" then
            local id = e.outID or (e.r and e.r.output)
            if id then total = total + Sell:FeeEach(id) * n * math.max(e.r and e.r.qty or 1, 1) + 100 end
        end
    end
    local ok, items = pcall(Sell.Items, Sell)
    for _, it in ipairs(ok and items or {}) do
        if not it.vendor and not it.hold and (it.sellN or 0) > 0 then
            total = total + (it.deposit or Sell:FeeEach(it.id) * it.sellN)
        end
    end
    return math.ceil(total)
end

-- Pick the duration that leaves the most expected profit after the deposit:
--   deposit is paid up front and lost if it doesn't sell; a longer listing is more likely to sell.
-- Expected sell chance comes from how many sell a day vs how many are listed.
function Sell:BestDuration(itemID, qty, price)
    local best, bestNet, deposits = self.DURATION, nil, {}
    local sold = PC.SalesEstimate and PC:SalesEstimate(itemID, 86400) or nil
    local listed = PC:Supply()[itemID] or 0
    local perDay = sold or 1
    local gross = (price or 0) * qty * (1 - self.AH_CUT)
    for dur, hours in pairs(self:Hours()) do
        local dep = self:Deposit(itemID, dur, qty) or 0
        deposits[dur] = dep
        -- chance your stack moves within the window: sales over the window vs what's ahead of you
        local sales = perDay * hours / 24
        local chance = math.min(1, sales / math.max(listed + qty, 1))
        chance = math.max(chance, hours / (self:Hours()[3] or 48) * 0.5) -- never below a floor that favours longer listings a little
        local net = chance * gross - dep
        if not bestNet or net > bestNet + 1 then best, bestNet = dur, net end
    end
    return best, deposits[best] or 0, deposits
end

-- Post an item at its smart price. Commodities post the whole amount at once; other items one per click.
function Sell:Post(itemID)
    local it
    for _, x in ipairs(self:Items()) do if x.id == itemID then it = x end end
    if not it or it.sellN <= 0 then return end
    if not PC.ahOpen then return PC.Buy:Say("|cffff8040Open the Auction House to post.|r") end
    if not self:Supported() then return PC.Buy:Say("|cffff5555This game version can't post from here: use the Auction House's Sell tab.|r") end
    if not it.price then return PC.Buy:Say("|cffff8040No auction price for " .. it.name .. " yet: scan first.|r") end
    if it.tooCheap then return PC.Buy:Say(("|cffff8040%s sells for under 1s at auction: not worth posting. Holding it.|r"):format(it.name)) end
    if it.hold then return PC.Buy:Say(("|cffff8040%s would sell below what it cost you. Holding it.|r"):format(it.name)) end
    local slot, free = nil, 0
    for _, s in ipairs(Bags()) do
        if s.id == itemID and not s.locked then slot = slot or s; free = free + s.n end
    end
    if not slot then return end
    if self:Classic() then return self:ClassicPost(it, slot) end
    local A = C_AuctionHouse
    if A.IsThrottledMessageSystemReady and not A.IsThrottledMessageSystemReady() then
        return PC.Buy:Say("The Auction House is busy. Try again in a moment.")
    end
    local loc = ItemLocation:CreateFromBagAndSlot(slot.bag, slot.slot)
    -- commodity or not: ask the game about this very item (the id-based answer can be "unknown" early on)
    local commodity = PC:IsCommodity(itemID)
    if A.GetItemCommodityStatus and Enum and Enum.ItemCommodityStatus then
        local ok, st = pcall(A.GetItemCommodityStatus, loc)
        if ok and st == Enum.ItemCommodityStatus.Commodity then commodity = true
        elseif ok and st == Enum.ItemCommodityStatus.Item then commodity = false end
    end
    -- commodities: everything you have in one post; identical items (bags, shirts): all of them as
    -- separate auctions in one post, unless the AH refused that before (then one at a time)
    local qty = commodity and it.sellN or (self.oneAtATime and 1 or it.sellN)
    -- never more than you have to hand: a locked stack is still on its way (the last post, a move)
    qty = math.min(qty, free)
    local price = it.price
    if self:WholeSilver() then price = math.max(price - price % 100, 100) end -- Retail's AH: whole silver only
    local duration, deposit = self:BestDuration(itemID, qty, price)
    if PC.db.postDuration then duration = PC.db.postDuration; deposit = self:Deposit(itemID, duration, qty) or 0 end
    if deposit > (GetMoney and GetMoney() or PC:Gold()) then
        return PC.Buy:Say(("|cffff5555The deposit (%s) is more than you have to spend.|r"):format(PC:Money(deposit)))
    end
    local ok, err
    if commodity then
        ok, err = pcall(A.PostCommodity, loc, duration, qty, price)
    else
        ok, err = pcall(A.PostItem, loc, duration, qty, nil, price)
    end
    if not ok then return PC.Buy:Say("|cffff5555Couldn't post: " .. tostring(err) .. "|r") end
    self.pending = { itemID = itemID, n = qty, t = GetTime(), retail = true, many = (not commodity and qty > 1) }
    it.price = price
    Posted:Add(itemID, qty)
    PC.Buy:Say(("|cff40ff40Posted %d %s at %s each for %dh (deposit %s).|r"):format(qty, it.name, PC:Money(it.price, false, true),
        self:Hours()[duration] or 24, PC:Money(deposit)))
    PC:RefreshUI()
end

-- Classic AH: one bag stack at a time (full stacks as one listing each; a part stack on its own)
function Sell:ClassicPost(it, slot)
    local itemID = it.id
    if not self:ClassicPlace(slot) then
        return PC.Buy:Say("|cffff5555Couldn't put " .. it.name .. " in the sell slot. Open the Auction House's Auctions tab and try again.|r")
    end
    local stackSize = math.min(slot.n, it.sellN or slot.n) -- never into what you keep
    local duration, deposit = self:BestDuration(itemID, stackSize, it.price)
    if PC.db.postDuration then duration = PC.db.postDuration; deposit = self:Deposit(itemID, duration, stackSize) or 0 end
    -- the deposit is spending too: never more than your spending limit (or your gold)
    local limit = math.min(GetMoney and GetMoney() or PC:Gold(), (PC.UI and PC.UI.PlanBudget and PC.UI:PlanBudget()) or math.huge)
    if deposit > limit then
        if ClickAuctionSellItemButton then ClickAuctionSellItemButton(); if ClearCursor then ClearCursor() end end
        return PC.Buy:Say(("|cffff5555Not posted: the deposit (%s) is more than your spending limit.|r"):format(PC:Money(deposit)))
    end
    local buyout = it.price * stackSize
    local bid = math.max(math.floor(buyout * 0.95), 1)
    self:LearnFromManual()
    self.ourPost = true
    local ok, err = pcall(StartAuction, bid, buyout, self:ClassicRunTime(duration), stackSize, 1)
    self.ourPost = false
    if not ok then return PC.Buy:Say("|cffff5555Couldn't post: " .. tostring(err) .. "|r") end
    -- the server answers a moment later; an "Internal auction error" within 2s means it refused it
    self.pending = { itemID = itemID, n = stackSize, t = GetTime(), retried = self.retrying }
    Posted:Add(itemID, stackSize, stackSize)
    PC.Buy:Say(("|cff40ff40Posted %d %s at %s each for %dh (deposit %s).|r"):format(stackSize, it.name, PC:Money(it.price, false, true),
        self:Hours()[duration] or 24, PC:Money(deposit)))
    PC:RefreshUI()
end

-- One click, one post: the AH only takes a post during your click (the next click posts the next item)
function Sell:PostAll()
    if not PC.ahOpen then return PC.Buy:Say("|cffff8040Open the Auction House to post.|r") end
    self.posting = false
    for _, it in ipairs(self:Items()) do
        if it.sellN > 0 and it.price and not it.hold and not it.vendor then return self:Post(it.id) end
    end
    return PC.Buy:Say("Nothing to post.")
end

-- Keep-in-stock targets: [itemID] = how many you want on hand (per character)
function Sell:Stock()
    PC.cdb.stock = PC.cdb.stock or {}
    return PC.cdb.stock
end

function Sell:SetStock(itemID, n)
    n = math.floor(tonumber(n) or 0)
    self:Stock()[itemID] = (n > 0) and n or nil
    PC:RefreshUI()
end

---------------------------------------------------------------------------
-- Keep in stock: top the plan up so you always have N of an item
---------------------------------------------------------------------------
function Sell:Restock()
    if not On("autoRestock", false) or not PC.UI or not PC.UI.PlanTable then return end
    local UI = PC.UI
    local plan = UI:PlanTable()
    local added = {}
    for id, want in pairs(self:Stock()) do
        local e = self:EntryFor(id)
        if e then
            local have = PC:BagCount(id)
            local per = math.max(e.r.qty or 1, 1)
            local need = math.ceil(math.max(want - have, 0) / per)
            local cap = PC.MakeGold and PC.MakeGold:MarketCap(e)
            if cap and need > cap then need = cap end
            local cur = plan[e.id] or 0
            if need > cur then
                -- as many as fit in the budget
                local n = need
                while n > cur and not UI:PlanFits(e.id, n) do n = n - 1 end
                if n > cur then
                    plan[e.id] = n
                    added[#added + 1] = ("%d %s"):format(n - cur, e.r.name)
                end
            end
        end
    end
    if #added > 0 then
        PC:Note("Restocking", { "Added to your plan: " .. table.concat(added, ", ") })
        PC:RefreshUI()
    end
end

---------------------------------------------------------------------------
-- Crafting from the plan (one click crafts the whole amount)
---------------------------------------------------------------------------
local Craft = {}
PC.Craft = Craft

-- Name of the profession whose window is open (nil if none)
function Craft:OpenProfession()
    local pf = ProfessionsFrame or TradeSkillFrame
    if not (pf and pf:IsShown()) then return nil end
    local T = C_TradeSkillUI
    if T and T.GetBaseProfessionInfo then
        local ok, info = pcall(T.GetBaseProfessionInfo)
        if ok and info and info.professionName then return info.professionName end
    end
    if GetTradeSkillLine then return (GetTradeSkillLine()) end
end

function Craft:IsOpenFor(r)
    local open = self:OpenProfession()
    return open ~= nil and r ~= nil and (r.prof == open or (r.prof and open:find(r.prof, 1, true)) or (r.prof and r.prof:find(open, 1, true))) and true or false
end

-- How many you can craft with what's in your bags (reagent bag counts)
function Craft:Available(e)
    local T = C_TradeSkillUI
    -- the game's count is only trustworthy while that profession's window is open
    -- (closed, it says 0 for everything, which used to look like "crafting done")
    if T and T.GetRecipeInfo and self:IsOpenFor(e.r) then
        local ok, info = pcall(T.GetRecipeInfo, e.id)
        if ok and info and info.numAvailable then return info.numAvailable end
    end
    local n = math.huge
    for _, rg in ipairs(e.r.reagents or {}) do
        local have = 0
        for _, id in ipairs(PC:ReagentIDs(rg)) do have = have + PC:BagCount(id) end
        n = math.min(n, math.floor(have / math.max(rg.n, 1)))
    end
    if n == math.huge then n = 0 end
    return n
end

-- Crafts to do now: what's left in the plan, limited by materials in your bags
Craft.MIN_BATCH = 5   -- fewer than this worth of market room: wait for sales rather than craft a trickle
Craft.BLIND_BATCH = 20 -- with no market data at all: craft this many, sell them, then carry on

function Craft:Count(e)
    -- a material the plan makes itself (vertical crafting) has its own count; the market cap doesn't apply
    local left = e.sub and (e.planCount or 0) or (PC.UI and PC.UI:PlanTable()[e.id]) or 0
    local n = math.min(left, self:Available(e))
    if not e.sub and n > 0 then
        local tool, has = self:Tool(e)
        if tool and has == false then return 0 end -- the rod/pick it needs isn't on you
    end
    -- never more than the market will take right now (what sells a day, what's listed, what you already
    -- hold or have listed) - but in batches: when the market only has room for a couple, crafting waits
    -- until some of yours sell instead of trickling one at a time between the bench and the AH
    -- (vendor flips sell to any vendor, and skill-ups don't care: no market limit for those)
    -- (what's in your plan is what gets made: the market only decides how much Make me gold and
    -- restocking put in it, and what gets posted. Holding crafts back is an option, off by default.)
    if PC.db and PC.db.marketHold and not e.sub and n > 0 and PC.MakeGold and e.route ~= "Vendor" and not (PC.UI and PC.UI.IsSkillPlan and PC.UI:IsSkillPlan()) then
        local cap, why, small = PC.MakeGold:MarketCap(e)
        if not cap then
            -- no market data yet: still never a mountain before selling any - a batch, then sell it
            local holding = PC.MakeGold:Holding(e.outID or e.r.output)
            cap, why = math.max(self.BLIND_BATCH - holding, 0), "no sales data yet: sell a batch first"
            local slow, swhy = PC.MakeGold:SlowCap(e)
            if slow and slow < cap then cap, why, small = slow, swhy, true end
        end
        -- a slow seller: one or two at a time is the point (not a batch)
        if small and cap > 0 then
            if cap < n then n = cap end
        elseif cap < math.min(self.MIN_BATCH, n) then
            self.blocked = self.blocked or {}
            self.blocked[e.id] = why
            return 0
        end
        if cap < n then n = cap end
    end
    -- and never more than your bags can hold (gear takes a slot each; stacks fill up)
    if n > 0 then
        local per = math.max(e.r.qty or 1, 1)
        -- what lands in your bags is what's crafted: the green, not the dust it's disenchanted into
        local outID = (e.disenchant and e.r.output) or e.outID or e.r.output
        if outID then
            local fit = self:FitCrafts(e, outID, per, n)
            if fit < n then n = math.max(fit, 0) end
            if n == 0 then self.noRoom = e.r.name end -- crafting waits for bag room
        end
    end
    return n
end

-- How many crafts' output fits as you go (up to n): each craft uses its materials, and a stack of them
-- that runs out frees its slot for what's made (1 clam + 1 spice make 1 dish: one free slot to start
-- is enough for the lot). Only stacks in bags that can hold what's made count as freed (a reagent bag
-- can't take a cooked dish), those elsewhere assumed to run out first; the craft's own materials only
-- free their slot once the craft after it starts.
function Craft:FitCrafts(e, outID, per, n)
    local size = math.max(PC:StackSize(outID), 1)
    local free = PC:FreeSlotsFor(outID)
    local room, mats = 0, {}
    for _, rg in ipairs(e.r.reagents or {}) do
        local id = PC:ReagentFor(rg, e.mats)
        if id and id ~= outID and not mats[id] then
            mats[id] = { n = 0, size = math.max(PC:StackSize(id), 1), away = 0 }
        end
        if id and mats[id] then mats[id].n = mats[id].n + rg.n end
    end
    for _, sl in ipairs(PC.BagSlots and PC:BagSlots() or {}) do
        if sl.id == outID and size > 1 then room = room + math.max(size - (sl.n or 1), 0) end
        local m = mats[sl.id]
        if m and not PC:CanHold(sl.bag, outID) then m.away = m.away + 1 end
    end
    local best = 0
    for k = 1, n do
        local need = math.max(math.ceil((k * per - room) / size), 0)
        local freed = 0
        for _, m in pairs(mats) do freed = freed + math.max(math.floor((k - 1) * m.n / m.size) - m.away, 0) end
        if need - freed > free then break end
        best = k
    end
    return best
end

-- How many of a recipe the market will let you craft now (the same rule as Count, without the bag
-- and materials limits): what's worth buying materials for. A skill-up plan isn't held back.
function Craft:MarketCount(e)
    local n = (PC.UI and PC.UI:PlanTable()[e.id]) or e.planCount or 0
    if n <= 0 or not (PC.db and PC.db.marketHold) or not PC.MakeGold or e.route == "Vendor" or (PC.UI and PC.UI.IsSkillPlan and PC.UI:IsSkillPlan()) then return n end
    local cap, _, small = PC.MakeGold:MarketCap(e)
    if not cap then
        cap = math.max(self.BLIND_BATCH - PC.MakeGold:Holding(e.outID or e.r.output), 0)
        local slow = PC.MakeGold:SlowCap(e)
        if slow and slow < cap then cap, small = slow, true end
    end
    if small then return math.min(n, cap) end
    if cap < math.min(self.MIN_BATCH, n) then return 0 end
    return math.min(n, cap)
end

-- The plan as it'll really be crafted now: each recipe cut to what the market takes. Shopping uses
-- this, so you never buy materials (fine thread...) for crafts that are waiting on sales.
function Craft:BuyEntries(entries)
    local out = {}
    for _, e in ipairs(entries) do
        local n = self:MarketCount(e)
        if n > 0 then
            if n == e.planCount then out[#out + 1] = e
            else out[#out + 1] = setmetatable({ planCount = n }, { __index = e }) end
        end
    end
    return out
end

-- Does this recipe need a forge, anvil, cooking fire or other station? Returns the station's name
-- ("Anvil", "Cooking Fire"...) and whether you're next to one right now.
local STATION_WORDS = { "anvil", "forge", "cooking fire", "fire", "alchemy lab", "moonwell", "loom" }
local function IsStationName(n)
    n = (n or ""):lower()
    for _, w in ipairs(STATION_WORDS) do if n:find(w, 1, true) then return true end end
    return false
end

-- A tool the recipe needs that you have to CARRY (a runed rod, a mining pick): name and whether
-- you have it on you. Unlike a station, it can sit in your bank or be crafted.
function Craft:Tool(e)
    local T = C_TradeSkillUI
    if not e then return nil end
    local name, met, asked
    if T and T.GetRecipeRequirements then
        local ok, reqs = pcall(T.GetRecipeRequirements, e.id)
        if ok and type(reqs) == "table" then
            asked = true
            for _, r in ipairs(reqs) do
                if r.name and not IsStationName(r.name) then name, met = r.name, r.met and true or false break end
            end
        end
    end
    if not name and GetTradeSkillTools and GetNumTradeSkills then
        for i = 1, GetNumTradeSkills() do
            if GetTradeSkillInfo(i) == e.r.name then
                local tools = { GetTradeSkillTools(i) }
                for k = 1, #tools, 2 do
                    if type(tools[k]) == "string" and not IsStationName(tools[k]) then name, met = tools[k], tools[k + 1] == 1 break end
                end
                break
            end
        end
    end
    -- remembered per recipe, for when the game can't say (the profession window is closed)
    if PC.cdb then
        PC.cdb.recipeTools = PC.cdb.recipeTools or {}
        if name then PC.cdb.recipeTools[e.id] = name
        elseif asked then PC.cdb.recipeTools[e.id] = nil
        else name = PC.cdb.recipeTools[e.id]; met = false end
    end
    if not name then return nil end
    -- the game's flag can lag; your bags are the truth
    local id = PC:ItemIDByName(name)
    if id then
        self.toolIDs = self.toolIDs or {}
        self.toolIDs[id] = true -- the bank may park it once the plan is done with it
        if PC.cdb then PC.cdb.toolIDs = PC.cdb.toolIDs or {}; PC.cdb.toolIDs[id] = true end -- remembered across reloads
        if PC:BagCount(id) > 0 then met = true end
    end
    return name, met, id
end

-- What to do about a missing tool: take it from the bank, craft it, or go get it
function Craft:ToolStep(e, name, id, s)
    s.tip = ("%s needs a %s."):format(e.r.name, name)
    local P = PC.Places
    if id and PC.Bank and PC.Bank:Known() and PC.Bank:Count(id) > 0 then
        s.text = "Go to the bank"
        s.tip = s.tip .. (" Your %s is in the bank: take it out."):format(name)
        local p = P and P:Nearest("bank")
        if p then s.dest = p; s.tip = s.tip .. "\n" .. P:Describe(p) end
        return s
    end
    local rid, r = PC:RecipeFor(id)
    if r then
        local sub = { id = rid, r = r, planCount = 1, sub = true, outID = id }
        if self:IsOpenFor(r) and self:Available(sub) > 0 then
            s.text = "Craft " .. name
            s.tip = s.tip .. " You can make one: that recipe comes first."
            s.run = function() self:Go(sub, 1) end
            return s
        end
        -- you can make one but not yet: its materials are on the plan's list, so the normal
        -- buy / vendor / bank steps handle it (nil = carry on with those)
        return nil
    end
    -- where to get one: this vendor, a vendor you've seen selling it, or any vendor (never the AH)
    local VB = PC.VendorBuy
    if id and VB and VB:Open() and VB:Sells(id) then
        s.text = "Buy a " .. name
        s.tip = s.tip .. " This vendor sells it."
        s.run = function() VB:Buy(id, 1) end
        return s
    end
    local v, other
    if id and P then local _; v, _, other = P:Nearest("vendor", id); v = v or other end
    if v or (id and PC:VendorCost(id)) then
        s.text = ("Buy a %s at a vendor"):format(name)
        if v then
            s.dest = v
            s.tip = s.tip .. (" %s sells it."):format(v.name or "A vendor") .. "\n" .. P:Describe(v)
        else
            s.tip = s.tip .. " Vendors sell it (Trade Supplies or General Goods)."
        end
        return s
    end
    s.text = ("Buy a %s at a vendor"):format(name)
    s.tip = s.tip .. " Try a Trade Supplies or General Goods vendor (tools aren't bought at auction)."
    return s
end

Craft.STATION_NEAR = 8 -- yards: close enough to use a forge, anvil or cooking fire
Craft.STATION_RISE = 8 -- yards of height: one standing below it on the stairs isn't at it

-- What a recipe needs to be crafted at, remembered. The client only answers while the profession
-- window is open, so without this the step offered "start crafting" from the middle of nowhere and
-- only mentioned the fire once you pressed it.
function Craft:StationRemembered(id)
    local t = PC.cdb and PC.cdb.recStation
    return (t and id) and t[id] or nil
end

function Craft:RememberStation(id, name)
    if not id or not PC.cdb then return end
    PC.cdb.recStation = PC.cdb.recStation or {}
    if name then PC.cdb.recStation[id] = name end
end

function Craft:Station(e)
    local T = C_TradeSkillUI
    if not e then return nil end
    local name, near, sure
    if not T then name = self:StationRemembered(e.id) end
    if T and T.GetRecipeRequirements then
        local ok, reqs = pcall(T.GetRecipeRequirements, e.id)
        if ok and type(reqs) == "table" then
            for _, r in ipairs(reqs) do
                -- type 2 = totem/station in newer clients; older ones only give a name + met flag
                if r.type == (Enum and Enum.RecipeRequirementType and Enum.RecipeRequirementType.Totem) or r.type == 2 or r.name then
                    local n = r.name or ""
                    for _, w in ipairs(STATION_WORDS) do
                        if n:lower():find(w, 1, true) then name, near, sure = n, r.met and true or false, true break end
                    end
                end
                if name then break end
            end
        end
    end
    if not name and T and T.GetRecipeInfo then
        local ok, info = pcall(T.GetRecipeInfo, e.id)
        local tools = ok and info and (info.requiredTool or info.tools)
        if type(tools) == "string" and tools ~= "" then
            name = tools
            near = (info.craftable ~= false) and (info.numAvailable or 0) > 0 -- can't tell exactly: craftable is the best hint
        end
    end
    if not name and GetTradeSkillTools and GetNumTradeSkills then
        for i = 1, GetNumTradeSkills() do
            if GetTradeSkillInfo(i) == e.r.name then
                local tools = { GetTradeSkillTools(i) }
                -- comes as name, met, name, met...
                for k = 1, #tools, 2 do
                    if type(tools[k]) == "string" then name, near, sure = tools[k], tools[k + 1] == 1, true break end
                end
                break
            end
        end
    end
    -- the client only answers with the profession window open: what it said last time stands in
    if name then self:RememberStation(e.id, name) else name = self:StationRemembered(e.id) end
    -- Whatever the client says, where we know a fire, forge or anvil of this kind, how far away it
    -- is settles it: this client answers "yes" for a recipe you have the materials for, wherever you
    -- are standing. Only when none is known does its answer count.
    if name then
        local now = GetTime and GetTime() or 0
        local c = self.statCache and self.statCache[name]
        if c and now - c.t < 3 then
            near = c.near
        else
            local P, T2 = PC.Places, PC.Travel
            local p = P and P.Nearest and P:Nearest("station", nil, name)
            local here = T2 and T2:Here()
            local d = (p and here and p.map) and T2:Yards(here, p) or nil
            -- a fire on the floor above, with you on the stairs below it, is not a fire you can use
            if d and p.z and here.z and math.abs(p.z - here.z) > self.STATION_RISE then d = nil; near = false end
            -- none known anywhere: the client's answer is all there is (or, failing that, let it craft)
            if d then near = d <= self.STATION_NEAR
            elseif not sure then near = p and false or near end
            self.statCache = self.statCache or {}
            self.statCache[name] = { t = now, near = near }
        end
    end
    return name, near
end

---------------------------------------------------------------------------
-- Craft from the button alone: the game only crafts with the profession open, so this opens it
-- out of sight, starts the craft, and closes it again once the first one is under way.
---------------------------------------------------------------------------
local function ProfFrame() return ProfessionsFrame or TradeSkillFrame end

function Craft:Quick(e, n)
    -- the window is open (out of sight) and waiting: this press starts the batch. The game only
    -- starts a craft from a key press or click, so it can't start on its own after the window loads.
    local q0 = self.quick
    if q0 and q0.ready and q0.e.id == e.id and self:IsOpenFor(e.r) then
        local m = math.min(n, self:Count(e))
        if m <= 0 then return self:EndQuick(false) end
        q0.ready, q0.casting = nil, nil
        q0.started, q0.left, q0.n, q0.last = GetTime(), m, m, GetTime()
        -- refused (no fire, no anvil, no tool): don't leave the button saying it's crafting
        if self:Go(e, m) == false then return self:EndQuick(false) end
        return
    end
    if self:IsOpenFor(e.r) then return self:Go(e, n) end
    if InCombatLockdown and InCombatLockdown() then return PC.Buy:Say("Can't craft in combat.") end
    self.quick = { e = e, n = n, t = GetTime() }
    self.hidden = On("quickCraftHide", false)
    if PC.UI and PC.UI.OpenRecipe then PC.UI:OpenRecipe(e.id, e.r) end
    -- give up quietly if the window never came (wrong profession, not learned...)
    -- (only if the batch never started: once it's crafting, this must not bring the window back)
    local q = self.quick
    C_Timer.After(3, function()
        if Craft.quick == q and not q.started and not q.ready and not q.casting then Craft:EndQuick(true) end
    end)
end

-- The profession window opened for a quick craft: craft, then put the window away
-- Out of sight while a quick craft runs: invisible and parked off screen, so it can't catch your clicks.
-- (The window has to stay OPEN: the game cancels the rest of a batch when it closes.)
function Craft:Hide()
    local pf = ProfFrame()
    if not pf or self.parked then return end
    local pts = {}
    for i = 1, (pf.GetNumPoints and pf:GetNumPoints() or 0) do pts[i] = { pf:GetPoint(i) } end
    self.parked = pts
    if pf.SetAlpha then pf:SetAlpha(0) end
    pf:ClearAllPoints()
    pf:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -5000, 5000)
end

function Craft:Unhide()
    local pf = ProfFrame()
    local pts = self.parked
    self.parked = nil
    if not pf then return end
    if pf.SetAlpha then pf:SetAlpha(1) end
    if pts then
        pf:ClearAllPoints()
        for _, p in ipairs(pts) do if p[1] then pf:SetPoint(unpack(p)) end end
    end
end

-- The profession window opened for a quick craft: start the whole batch, keep it open until it's done
function Craft:OnShow()
    local q = self.quick
    if not q then return end
    if self.hidden then self:Hide() end
    -- the game only starts a craft from a key press or click (trying from here gets "Interface action
    -- failed because of an AddOn"): the window waits out of sight and the button says "Start crafting" -
    -- one more press does the whole batch
    C_Timer.After(0.4, function()
        Safe("quick craft", function()
            if Craft.quick ~= q then return end
            local n = math.min(q.n, Craft:Count(q.e))
            if n <= 0 then return Craft:EndQuick(true) end
            q.started, q.left = nil, nil
            q.ready = GetTime()
            PC:RefreshUI()
        end)
    end)
end

-- one craft of the batch finished (or the batch stopped): close when it's all done
function Craft:OnCast(event, spellID)
    local q = self.quick
    if not q or not q.started then return end
    -- ours: the recipe's id, or a cast with the recipe's name (the game's spell number can differ
    -- from the recipe's, and then the batch looked like it never started)
    if spellID and spellID ~= q.e.id then
        local name
        if C_Spell and C_Spell.GetSpellName then local ok, n = pcall(C_Spell.GetSpellName, spellID); name = ok and n or nil end
        if not name and GetSpellInfo then local ok, n = pcall(GetSpellInfo, spellID); name = ok and n or nil end
        if not name or name ~= q.e.r.name then return end
    end
    q.last = GetTime()
    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        q.casting = true
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        q.left = (q.left or 1) - 1
        if q.left <= 0 then C_Timer.After(0.3, function() if Craft.quick == q then Craft:EndQuick(false) end end) end
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
        -- you moved, or ran out of something: the batch is over
        C_Timer.After(0.5, function() if Craft.quick == q then Craft:EndQuick(false) end end)
    end
end

-- show = put the window back in sight (something went wrong); else close it
function Craft:EndQuick(show)
    local pf = ProfFrame()
    local wasHidden = self.hidden
    self.quick, self.hidden = nil, nil
    self:Unhide()
    if show then return end
    if wasHidden and pf and pf:IsShown() and On("quickCraftClose", false) then
        if C_TradeSkillUI and C_TradeSkillUI.CloseTradeSkill then pcall(C_TradeSkillUI.CloseTradeSkill)
        elseif CloseTradeSkill then pcall(CloseTradeSkill) end
        if pf:IsShown() and HideUIPanel then pcall(HideUIPanel, pf) end
    end
    PC:RefreshUI()
end

function Craft:Go(e, n)
    n = n or self:Count(e)
    if not e or n <= 0 then return false end
    if InCombatLockdown and InCombatLockdown() then PC.Buy:Say("Can't craft in combat.") return false end
    local tool, has, toolID = self:Tool(e)
    if tool and has == false then
        local st = self:ToolStep(e, tool, toolID, {})
        PC.Buy:Say(("|cffff8040%s needs a %s you don't have on you. %s|r"):format(e.r.name, tool, st.text))
        return false
    end
    local station, near = self:Station(e)
    if station and near == false then
        local P = PC.Places
        local p = P and P:Nearest("station", nil, station)
        local where = p and (": " .. P:Describe(p)) or ". ProfitCrafter learns where they are when you craft next to one."
        if p then P:Point(p, station) end
        PC.Buy:Say(("|cffff8040%s needs a %s nearby%s|r"):format(e.r.name, station, where))
        return false
    end
    local T = C_TradeSkillUI
    if T and T.CraftRecipe then
        -- crafting here: remember this spot as a station for next time
        if station and PC.Places then PC.Places:Learn("station", station) end
        local ok, err = pcall(T.CraftRecipe, e.id, n)
        if not ok then PC.Buy:Say("|cffff5555Couldn't start crafting: " .. tostring(err) .. "|r") return false end
    elseif DoTradeSkill and GetNumTradeSkills then
        for i = 1, GetNumTradeSkills() do
            if GetTradeSkillInfo(i) == e.r.name then DoTradeSkill(i, n) break end
        end
    else
        return PC.UI:OpenRecipe(e.id, e.r)
    end
    PC.Buy:Say(("Crafting %d %s..."):format(n, e.r.name))
end

---------------------------------------------------------------------------
-- Next step: the one thing to do next
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Undercuts (only with Auctionator installed): once your listings have been up 2 hours, the Next step
-- offers Auctionator's undercut scan. A listing that's been undercut and won't sell in the next 4 hours
-- (fewer sales expected than what's listed below it) is cancelled; it comes back by mail and is posted
-- again at the new cheapest - never below what it cost you.
---------------------------------------------------------------------------
local Undercut = {}
PC.Undercut = Undercut
Undercut.AGE = 0              -- any listing can be checked
Undercut.AWAY = 10 * 60       -- out of the city this long: coming back is a new visit (asked again)
Undercut.RECENT = 24 * 3600  -- a check this recent (done or skipped): not asked again (once a day)
Undercut.NEAR = 50            -- yards: "near an Auction House"
Undercut.WINDOW = 4 * 3600    -- "will it sell in the next 4 hours?"

local function Loaded(name)
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if not loaded then return false end
    local ok, v = pcall(loaded, name)
    return ok and v and true or false
end
PC.AddOnLoaded = Loaded

-- Which auction addon helps with undercut scans: Auctionator, else TradeSkillMaster, else none
function Undercut:Helper()
    if Loaded("Auctionator") then return "Auctionator" end
    if Loaded("TradeSkillMaster") or TSM_API then return "TSM" end
    return nil
end

-- (kept under its old name: true when Auctionator or TSM is there to help)
function Undercut:Auctionator()
    return self:Helper() ~= nil
end

function Undercut:Supported()
    local A = C_AuctionHouse
    return self:Auctionator() and A and A.GetNumOwnedAuctions and A.GetOwnedAuctionInfo and A.CancelAuction and true or false
end

-- your auctions on the AH: { auctionID, itemID, name, unit, qty, age }
function Undercut:Mine()
    local out = {}
    local A = C_AuctionHouse
    if not (A and A.GetNumOwnedAuctions) then return out end
    local ok, num = pcall(A.GetNumOwnedAuctions)
    if not ok or not num then return out end
    for i = 1, num do
        local ok2, a = pcall(A.GetOwnedAuctionInfo, i)
        if ok2 and a and a.itemKey and a.itemKey.itemID and a.status ~= 1 and a.auctionID then
            local id = a.itemKey.itemID
            local qty = a.quantity or 1
            local unit = a.buyoutAmount and (PC:IsCommodity(id) and a.buyoutAmount or a.buyoutAmount / math.max(qty, 1))
            out[#out + 1] = { auctionID = a.auctionID, itemID = id, name = PC:ItemName(id) or ("Item " .. id),
                unit = unit, qty = qty, age = time() - Posted:Since(id) }
        end
    end
    return out
end

-- the cheapest listing now: live listings first, then Auctionator's latest price, then the last scan
function Undercut:Cheapest(itemID)
    local d = PC:DepthTable()[itemID]
    if d and d.list and d.list[1] and d.t and time() - d.t < 15 * 60 then return d.list[1].p, d end
    local API = Auctionator and Auctionator.API and Auctionator.API.v1
    if API and API.GetAuctionPriceByItemID then
        local ok, p = pcall(API.GetAuctionPriceByItemID, PC.NAME or "ProfitCrafter", itemID)
        if ok and p and p > 0 then return p end
    end
    local tsm = PC.TSMValue and PC:TSMValue("dbminbuyout", itemID)
    if tsm and tsm > 0 then return tsm end
    return PC:Price(itemID)
end

-- Anything of yours up for sale: the game's own list (once the AH has sent it) or what we recorded
function Undercut:HasListings()
    for itemID in pairs(Posted:Table()) do if Posted:Count(itemID) > 0 then return true end end
    if PC.ahOpen and self:Supported() and #self:Mine() > 0 then return true end
    return false
end

-- a plan still being worked on: undercut checks wait until it's done (they'd only interrupt it)
function Undercut:PlanActive()
    local UI = PC.UI
    return UI and UI.PlanEntries and #UI:PlanEntries() > 0 or false
end

-- The city visit you're on: { map, last, done } (nil out in the world). Asked once per visit: a new
-- city, or back after 10 minutes away. Not asked within 30 minutes of a check (done or skipped).
function Undercut:Visit()
    local P = PC.Places
    local map = P and P.Here and P:Here()
    if not P or not P:InCity(map) then return nil end
    map = map or 0
    local now = time()
    local v = PC.cdb.ucVisit
    if not v or v.map ~= map or now - (v.last or 0) >= self.AWAY then
        v = { map = map, done = now - (PC.cdb.undercutCheck or 0) < self.RECENT or nil }
        PC.cdb.ucVisit = v
    end
    v.last = now
    return v
end

function Undercut:Due()
    local v = self:Visit()
    if not self:Auctionator() or not PC.ahOpen or self:PlanActive() then return false end
    if not v or v.done then return false end
    return self:HasListings()
end

-- In a city with things listed, not asked yet this visit: the AH here is one more stop
function Undercut:DueAway()
    local v = self:Visit()
    if PC.ahOpen or not self:Auctionator() or self:PlanActive() then return false end
    if not v or v.done or not self:HasListings() then return false end
    local P = PC.Places
    local ah, d = P:Nearest("ah")
    if ah and d then return true, ah end -- the AH in this city
    return false
end

function Undercut:InCity()
    return PC.Places and PC.Places:InCity() or false
end

-- Logged in, or just arrived, in a city: the check is offered then (once per visit)
function Undercut:OnArrive()
    if not self:Auctionator() then return end
    local P = PC.Places
    local map = P and P.Here and P:Here()
    if not self:InCity() then self.lastCity = nil return end
    if map and map == self.lastCity then return end
    self.lastCity = map
    PC:RefreshUI()
end

-- done for this visit (scanned or skipped)
function Undercut:Done()
    PC.cdb.undercutCheck = time()
    local v = self:Visit()
    if v then v.done = true end
end
function Undercut:SkipScan()
    self:Done()
    if PC.Learn then PC.Learn:SkippedUndercut() end
    PC.Buy:Say("Undercut check skipped: I'll ask again tomorrow.")
end
function Undercut:SkipItem(itemID)
    PC.cdb.undercutKeep = PC.cdb.undercutKeep or {}
    PC.cdb.undercutKeep[itemID] = time()
    PC.Buy:Say("Leaving that one up: won't suggest cancelling it for an hour.")
end

-- A button somewhere under a frame, by the text on it (Auctionator's names change between versions)
-- (the game locks some of its own frames away from add-ons: those are skipped, never touched)
local function Locked(f)
    if not f then return true end
    local ok, locked = pcall(function() return f.IsForbidden and f:IsForbidden() end)
    return not ok or locked
end
function Undercut:FindButton(root, texts, depth, anyCase)
    if Locked(root) or (depth or 0) < 0 or not root.GetChildren then return nil end
    local ok, kids = pcall(function() return { root:GetChildren() } end)
    if not ok then return nil end
    for _, child in ipairs(kids) do
        if not Locked(child) then
            local hit, found = pcall(function()
                local t = child.GetText and child:GetText()
                -- some addons (TSM) put the label on a font string inside the button
                if type(t) ~= "string" and child.GetRegions then
                    for _, r in ipairs({ child:GetRegions() }) do
                        if r.GetObjectType and r:GetObjectType() == "FontString" and r.GetText then t = r:GetText(); if type(t) == "string" then break end end
                    end
                end
                if type(t) == "string" then
                    for _, want in ipairs(texts) do
                        if t == want or (anyCase and t:lower() == want:lower()) then return child end
                    end
                end
            end)
            if hit and found then return found end
            found = self:FindButton(child, texts, (depth or 0) - 1, anyCase)
            if found then return found end
        end
    end
end

-- Run Auctionator's own undercut scan (its Cancelling tab) and read the live listings ourselves too
function Undercut:Scan()
    self:Done()
    if PC.Learn then PC.Learn:UsedUndercut() end
    if C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions then pcall(C_AuctionHouse.QueryOwnedAuctions, {}) end
    local mine = self:Mine()
    -- Auctionator's Cancelling tab and its "Undercut Scan" button, found by their text
    local tab = AuctionatorTabs_Cancelling or self:FindButton(AuctionHouseFrame, { "Cancelling" }, 3)
    if tab and tab.Click then pcall(tab.Click, tab) end
    local start = self:FindButton(AuctionatorCancellingFrame or AuctionHouseFrame, { "Undercut Scan" }, 7)
    if self:Helper() == "TSM" then
        -- TSM: its Auctioning tab, then its cancel scan (TSM's own buttons, found by their text)
        local roots = { TSMAuctionHouseFrame or false, AuctionHouseFrame or false, UIParent or false }
        local tsmTab, tsmStart
        for _, root in ipairs(roots) do
            if root and not tsmTab then tsmTab = self:FindButton(root, { "Auctioning", "AUCTIONING" }, 6, true) end
        end
        if tsmTab and tsmTab.Click then pcall(tsmTab.Click, tsmTab) end
        for _, root in ipairs(roots) do
            if root and not tsmStart then tsmStart = self:FindButton(root, { "Run Cancel Scan", "Cancel Scan" }, 10, true) end
        end
        start = tsmStart
    end
    if start and start.Click and (not start.IsEnabled or start:IsEnabled()) then
        pcall(start.Click, start)
        PC.Buy:Say(("|cff40ff40%s is checking your auctions for undercuts.|r"):format(self:Helper() or "Auctionator"))
    else
        PC.Buy:Say("Checking your auctions for undercuts.")
    end
    local ids, seen = {}, {}
    for _, a in ipairs(mine) do
        if not seen[a.itemID] and PC:IsCommodity(a.itemID) then seen[a.itemID] = true; ids[#ids + 1] = a.itemID end
    end
    if #ids > 0 and PC.Depth and PC.Depth:Supported() then PC.Depth:Run(ids, function() PC:RefreshUI() end) end
    PC:RefreshUI()
end

-- Listings that have been undercut and won't sell in the next 4 hours: cancel them
--   { auctionID, itemID, name, qty, unit, cheapest, repost }
function Undercut:ToCancel()
    local out = {}
    if not self:Supported() or not PC.cdb.undercutCheck then return out end
    for _, a in ipairs(self:Mine()) do
        if a.age >= self.AGE and a.unit then
            local cheapest, d = self:Cheapest(a.itemID)
            if cheapest and cheapest < a.unit then
                -- how much is listed below yours, and how much sells in 4 hours
                local ahead, sells, why = self:WillSell(a, d)
                -- the new price: the cheapest, to the copper (no undercutting; whole silver on Retail only), never below what it cost you
                local repost = math.max(cheapest - (Sell.UNDERCUT or 0), 1)
                if Sell:WholeSilver() then repost = math.max(repost - repost % 100, 100) end
                local _, floorPrice = Sell:Price(a.itemID)
                local worth = not floorPrice or repost >= floorPrice
                local kept = (PC.cdb.undercutKeep or {})[a.itemID]
                if kept and time() - kept > 3600 then PC.cdb.undercutKeep[a.itemID] = nil; kept = nil end
                if sells < ahead and worth and not kept then
                    out[#out + 1] = { auctionID = a.auctionID, itemID = a.itemID, name = a.name, qty = a.qty,
                        unit = a.unit, cheapest = cheapest, repost = repost, ahead = ahead, sells = sells, why = why }
                end
            end
        end
    end
    return out
end

-- Will this listing sell in the next 4 hours anyway? How much is ahead of it, and how much should sell:
-- the faster of today's rate and the last few hours', boosted when the price has been jumping around
-- (cheap listings get bought up quickly then). Gear: listings within 3% of yours don't count against it.
function Undercut:WillSell(a, d)
    local commodity = PC:IsCommodity(a.itemID)
    local near = commodity and a.unit or a.unit * 0.97
    local ahead = 0
    if d and d.list then
        for _, l in ipairs(d.list) do if l.p < near then ahead = ahead + (l.q or 1) end end
    else
        ahead = PC:Supply()[a.itemID] or 999
    end
    -- sales: the day's rate, or the last 6 hours' if that's faster
    local e = Sell:EntryFor(a.itemID)
    local perDay = e and PC.MakeGold and PC.MakeGold:SoldPerDay(e) or 0
    local rate = perDay / 86400
    local recent, covered = nil, nil
    if PC.SalesEstimate then recent, covered = PC:SalesEstimate(a.itemID, 6 * 3600) end
    if recent and covered and covered >= 1800 then rate = math.max(rate, recent / covered) end
    -- volatility: how much the price has been moving (coefficient of variation of recent prices)
    local swing = 0
    local hist = PC.History and PC:History()[a.itemID]
    if hist and #hist >= 3 then
        local n, sum, sq = 0, 0, 0
        for i = math.max(1, #hist - 9), #hist do local p = hist[i].p or 0; n = n + 1; sum = sum + p; sq = sq + p * p end
        local mean = sum / n
        if mean > 0 then swing = math.sqrt(math.max(sq / n - mean * mean, 0)) / mean end
    end
    local boost = 1 + math.min(swing * 2, 1) -- up to twice as fast when prices swing a lot
    local sells = rate * self.WINDOW * boost
    local why = ("~%d sell in 4h%s, %d listed below yours"):format(math.floor(sells + 0.5),
        boost > 1.05 and (" (prices moving %d%%)"):format(math.floor(swing * 100 + 0.5)) or "", ahead)
    return ahead, sells, why
end

function Undercut:Cancel(c)
    local ok, err = pcall(C_AuctionHouse.CancelAuction, c.auctionID)
    if not ok then return PC.Buy:Say("|cffff5555Couldn't cancel: " .. tostring(err) .. "|r") end
    Posted:Remove(c.itemID, c.qty)
    PC.cdb.postTimes = PC.cdb.postTimes or {}
    PC.cdb.postTimes[c.itemID] = nil
    PC.Buy:Say(("|cffff8040Cancelled %d %s (undercut at %s). It comes back by mail; then it's posted again at about %s.|r"):format(
        c.qty, c.name, PC:Money(c.cheapest, false, true), PC:Money(c.repost, false, true)))
    if C_AuctionHouse.QueryOwnedAuctions then pcall(C_AuctionHouse.QueryOwnedAuctions, {}) end
    PC:RefreshUI()
end
