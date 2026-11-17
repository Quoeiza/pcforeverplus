-- ProfitCrafter: live Auction House listings ("market depth")
--   The quick scan only tells us the CHEAPEST price. Buying a lot climbs the price ladder:
--   the cheapest few hundred go first, then you pay more. After each scan ProfitCrafter reads the
--   full list of listings for your materials, and clicking an item checks it again right away.

local ADDON, ns = ...
local PC = ns.PC

local Depth = {}
PC.Depth = Depth

PC.DEPTH_MAX_TIERS = 80        -- price steps kept per item (cheapest first)
PC.DEPTH_TIMEOUT = 6           -- seconds to wait for one item before moving on
PC.DEPTH_MAX_ITEMS = 120       -- most items read after one scan

---------------------------------------------------------------------------
-- Stored listings: db.depth[faction][itemID] = { t = time, total = qty, list = { {p, q}, ... } }
---------------------------------------------------------------------------
function PC:DepthTable()
    local db = self.db
    db.depth = db.depth or {}
    local f = self:Faction()
    db.depth[f] = db.depth[f] or {}
    return db.depth[f]
end

function PC:IsCommodity(itemID)
    local AH = C_AuctionHouse
    if AH and AH.GetItemCommodityStatus and Enum and Enum.ItemCommodityStatus then
        local ok, st = pcall(AH.GetItemCommodityStatus, itemID)
        if ok and st == Enum.ItemCommodityStatus.Commodity then return true end
        if ok and st == Enum.ItemCommodityStatus.Item then return false end
    end
    -- unknown yet: stackable items are sold as commodities
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local stack = getInfo and select(8, getInfo(itemID))
    return type(stack) == "number" and stack > 1
end

-- What buying n of an item costs, walking the listings cheapest first.
-- returns total, average each, priciest each you'd pay, how many short (not enough listed), when checked
function PC:CostForQty(itemID, n)
    n = math.max(n or 1, 0)
    local d = self:DepthTable()[itemID]
    if not d or not d.list or #d.list == 0 then
        local p = self:Price(itemID)
        if not p then return nil end
        return p * n, p, p, nil, nil
    end
    local left, total, top = n, 0, d.list[1].p
    for _, step in ipairs(d.list) do
        if left <= 0 then break end
        local take = math.min(left, step.q)
        total = total + take * step.p
        top = step.p
        left = left - take
    end
    local short
    if left > 0 then
        -- more than we saw listed: count the rest at the highest price seen
        short = left
        total = total + left * top
    end
    return total, (n > 0) and (total / n) or d.list[1].p, top, short, d.t
end

-- Tooltip lines: the live price ladder for an item, and what buying `want` would cost
function PC:DepthLines(itemID, want)
    local lines = {}
    if Depth.busy == itemID then
        lines[#lines + 1] = "|cffffd100Checking live listings...|r"
        return lines
    end
    local d = self:DepthTable()[itemID]
    if not d or not d.list or #d.list == 0 then
        lines[#lines + 1] = PC.ahOpen and "|cff888888Live listings not checked yet. Click to check now.|r"
            or "|cff888888Live listings: open the AH and click to check.|r"
        return lines
    end
    lines[#lines + 1] = ("|cffffd100Live listings|r |cff888888(checked %s ago, %d for sale)|r"):format(
        self:Ago(time() - d.t), d.total or 0)
    local shown = 0
    for _, step in ipairs(d.list) do
        shown = shown + 1
        if shown > 6 then
            lines[#lines + 1] = ("  |cff888888...and %d more price steps|r"):format(#d.list - 6)
            break
        end
        lines[#lines + 1] = ("  %s  x%d"):format(self:Money(step.p), step.q)
    end
    if want and want > 0 then
        local total, avg, top, short = self:CostForQty(itemID, want)
        if total then
            lines[#lines + 1] = ("Buying |cffffffff%d|r: %s total, %s each on average, up to %s"):format(
                want, self:Money(total), self:Money(avg), self:Money(top))
            if short then
                lines[#lines + 1] = ("|cffff5555Only %d listed: %d more than that is priced at the highest step.|r"):format(want - short, short)
            end
        end
    end
    if PC.ahOpen then lines[#lines + 1] = "|cff888888Click to check again.|r" end
    return lines
end

---------------------------------------------------------------------------
-- Reading listings from the AH, one item at a time
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
Depth.queue, Depth.done = {}, nil

local function AH() return C_AuctionHouse end

function Depth:Supported()
    local A = AH()
    return A and A.SendSearchQuery and A.GetNumCommoditySearchResults and A.GetCommoditySearchResultInfo and A.MakeItemKey
end

function Depth:Read(itemID)
    local A = AH()
    local n = A.GetNumCommoditySearchResults(itemID) or 0
    local byPrice, list, total = {}, {}, 0
    for i = 1, n do
        local r = A.GetCommoditySearchResultInfo(itemID, i)
        if r and r.unitPrice and r.quantity then
            local step = byPrice[r.unitPrice]
            if not step then
                if #list >= PC.DEPTH_MAX_TIERS then break end
                step = { p = r.unitPrice, q = 0 }
                byPrice[r.unitPrice] = step
                list[#list + 1] = step
            end
            step.q = step.q + r.quantity
            total = total + r.quantity
        end
    end
    if total == 0 then return end -- nothing arrived (or nothing for sale): keep what we had
    table.sort(list, function(a, b) return a.p < b.p end)
    PC:DepthTable()[itemID] = { t = time(), total = total, list = list }
    if list[1] then
        -- the live cheapest price is the best price we know
        PC:Prices()[itemID] = list[1].p
        PC:Checked()[itemID] = time()
        if PC.Source then PC:Source()[itemID] = nil end
    end
end

function Depth:Send(itemID)
    local A = AH()
    if A.IsThrottledMessageSystemReady and not A.IsThrottledMessageSystemReady() then
        self.waitingThrottle = true
        C_Timer.After(0.5, function() if self.waitingThrottle and self.busy == itemID then self:Send(itemID) end end)
        return
    end
    self.waitingThrottle = false
    self.askedMore = nil
    local sorts = { { sortOrder = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0, reverseSort = false } }
    A.SendSearchQuery(A.MakeItemKey(itemID), sorts, false)
    local token = {}
    self.token = token
    C_Timer.After(PC.DEPTH_TIMEOUT, function()
        -- out of time: keep whatever listings did arrive
        if self.token == token and self.busy == itemID then self:Finish(itemID, true) end
    end)
end

function Depth:Next()
    if not PC.ahOpen then return self:Stop() end
    local id = table.remove(self.queue, 1)
    if not id then return self:Stop() end
    self.busy = id
    self.pos = (self.pos or 0) + 1
    PC.lastProgressAt = GetTime()
    if PC.scanMode == "depth" then PC.progress = (self.pos - 1) / math.max(self.count or 1, 1) end
    PC:Safe("live listings", self.Send, self, id)
end

function Depth:Finish(itemID, ok)
    if self.busy ~= itemID then return end
    if ok then PC:Safe("live listings", self.Read, self, itemID) end
    self.busy, self.token = nil, nil
    PC:RefreshUI()
    if self.onItem then self.onItem(itemID) end
    C_Timer.After(0.15, function() Depth:Next() end)
end

function Depth:Stop()
    self.busy, self.token, self.waitingThrottle = nil, nil, false
    wipe(self.queue)
    local done = self.done
    self.done, self.pos, self.count = nil, nil, nil
    if done then done() end
end

-- Check a list of items; `done` runs when all are read (or skipped)
function Depth:Run(ids, done)
    wipe(self.queue)
    for _, id in ipairs(ids) do self.queue[#self.queue + 1] = id end
    self.count, self.pos, self.done = #self.queue, 0, done
    self:Next()
end

-- Clicked an item: check it now (jumps ahead of anything queued)
function Depth:CheckNow(itemID)
    if not itemID then return end
    if not PC.ahOpen then
        PC.Print("Open the Auction House to check live listings.")
        return
    end
    if not self:Supported() or not PC:IsCommodity(itemID) then return end
    if self.busy == itemID then return end
    for i = #self.queue, 1, -1 do if self.queue[i] == itemID then table.remove(self.queue, i) end end
    if self.busy or PC.scanning then
        table.insert(self.queue, 1, itemID)
        return
    end
    self.queue[#self.queue + 1] = itemID
    self.count, self.pos = 1, 0
    self:Next()
end

-- After a scan: the materials your recipes use (both the cheapest and the top-quality ranks)
function Depth:ScanIDs()
    local set, ids = {}, {}
    local supply = PC:Supply()
    for _, r in pairs(PC:ShownRecipes()) do
        for _, rg in ipairs(r.reagents) do
            for _, mode in ipairs({ "low", "high" }) do
                local id, _, src = PC:ReagentFor(rg, mode)
                if id and not set[id] and src == "AH" and (supply[id] or 1) > 0 and PC:IsCommodity(id) then
                    set[id] = true
                    ids[#ids + 1] = id
                end
            end
        end
    end
    while #ids > PC.DEPTH_MAX_ITEMS do table.remove(ids) end
    return ids
end

function Depth:ShouldRun()
    return PC.db.depthScan ~= false and self:Supported() and PC.ahOpen
end

ev:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
ev:RegisterEvent("COMMODITY_SEARCH_RESULTS_ADDED")
ev:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
ev:SetScript("OnEvent", function(_, event, itemID)
    PC:Safe("live listings", function()
        if event == "AUCTION_HOUSE_CLOSED" then
            Depth:Stop()
        elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
            if Depth.waitingThrottle and Depth.busy then Depth:Send(Depth.busy) end
        elseif Depth.busy and (itemID == nil or itemID == Depth.busy) then
            local id = Depth.busy
            local A = AH()
            -- long lists come in pages; one more page is plenty for the price ladder
            if A.HasFullCommoditySearchResults and not A.HasFullCommoditySearchResults(id)
                and A.RequestMoreCommoditySearchResults and not Depth.askedMore then
                Depth.askedMore = true
                A.RequestMoreCommoditySearchResults(id)
                return
            end
            Depth.askedMore = nil
            Depth:Finish(id, true)
        end
    end)
end)
