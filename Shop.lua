-- ProfitCrafter: buying materials straight from the Crafting plan
--   Each material row has a Buy button, and "Buy next" works down the list.
--   The game needs a real click for every purchase: the first click asks the AH for the price,
--   the next click confirms it. "Buy next" lines up the following material after each purchase.
--   Purchases arrive by mail; until you take them out they still count as "have" (PC:MailPending).

local ADDON, ns = ...
local PC = ns.PC

local Buy = {}
PC.Buy = Buy

Buy.PRICE_WARN = 1.25    -- warn if the quote is 25% over what we expected
Buy.QUOTE_TIMEOUT = 4    -- seconds to wait for the AH's price before asking again
Buy.BUY_TIMEOUT = 10     -- seconds to wait for "purchase done"
Buy.MSG_TIME = 12        -- seconds a message stays on the Crafting plan page

local function Refresh() if PC.RefreshUI then PC:RefreshUI() end end

function Buy:Supported()
    local A = C_AuctionHouse
    return A and A.StartCommoditiesPurchase and A.ConfirmCommoditiesPurchase and true or false
end

-- Is the AH still being read? No buying until the prices are in (a scan or the live-listing reads)
function Buy:Scanning()
    return (PC.scanning or (PC.Depth and PC.Depth.busy)) and true or false
end

-- A classic-style AH (WoW Forever): no buying from an addon, but it can run the search for you
function Buy:ClassicAH()
    return PC.ahOpen and not self:Supported() and (AuctionFrameBrowse ~= nil or QueryAuctionItems ~= nil) or false
end

-- Put the item's name in the AH's Browse search and run it, so the listings are one click from bought
function Buy:SearchAH(it)
    if not PC.ahOpen then return self:Say("|cffff8040Open the Auction House first.|r") end
    if self:Scanning() then return self:Say("|cffff8040Still reading the Auction House: wait for the scan to finish before buying.|r") end
    local name = it.name or PC:ItemName(it.id) or ""
    local ok = false
    if AuctionFrameTab1 and AuctionFrameTab1.Click then pcall(AuctionFrameTab1.Click, AuctionFrameTab1) end
    if BrowseName and BrowseName.SetText then
        BrowseName:SetText(name)
        if BrowseSearchButton and BrowseSearchButton.Click then pcall(BrowseSearchButton.Click, BrowseSearchButton); ok = true end
    end
    -- the retail-style AH window (WoW Forever runs it too): its own search bar
    if not ok and AuctionHouseFrame and PC.UI and PC.UI.SearchAH then
        local q, r = pcall(PC.UI.SearchAH, PC.UI, it.id)
        ok = q and r and true or false
    end
    if not ok and QueryAuctionItems then
        local q = pcall(QueryAuctionItems, name, nil, nil, 0, 0, 0, false, true, nil)
        ok = q
    end
    if not ok then return self:Say("|cffff8040Couldn't run the search: type " .. name .. " into the AH's search box.|r") end
    local cap = self:VendorPrice(it.id)
    local price = PC:Price(it.id)
    local limit = cap and ("no more than " .. PC:Money(cap, false, true) .. " each (a vendor sells it for that)")
        or (price and ("about " .. PC:Money(price, false, true) .. " each") or "")
    self:Say(("|cff40ff40Searching the AH for %s: buy %d, %s.|r"):format(name, it.qty or 1, limit))
    return true
end

-- Can this material be bought from here? (commodities only: gear and such need the AH's own window)
function Buy:CanBuy(itemID)
    -- (the AH's own search answering with commodity listings settles it, whatever the item info says)
    return itemID and self:Supported() and (PC:IsCommodity(itemID) or (self.commodityHere and self.commodityHere[itemID])) or false
end

-- Items a vendor also sells: only buy AH listings priced at or below the vendor's price.
-- Returns how many of `want` can be bought on the AH that way (0 = buy them all from the vendor).
function Buy:VendorPrice(itemID)
    return PC.db and PC.db.vendor and PC:VendorCost(itemID)
end

-- A vendor item comes from the AH only when it's clearly cheaper there (10% or more): the same
-- price, or a copper less, isn't worth a trip to the AH.
Buy.AH_VS_VENDOR = 0.9
Buy.vendorOnly = {} -- the AH quoted more than a vendor charges: vendor it for a while
function Buy:AHQty(itemID, want)
    want = want or 0
    local v0 = self:VendorPrice(itemID)
    if not v0 or want <= 0 then return want end
    local t = self.vendorOnly[itemID]
    if t and GetTime() - t < 1800 then return 0 end
    local v = math.floor(v0 * self.AH_VS_VENDOR)
    local d = PC:DepthTable()[itemID]
    if d and d.list and #d.list > 0 then
        local n = 0
        for _, step in ipairs(d.list) do
            if step.p <= v then n = n + step.q else break end -- listings are cheapest first
        end
        return math.min(want, n)
    end
    -- no live listings read yet: go by the cheapest price we know (the AH's quote is checked again)
    local p = PC:Price(itemID)
    if p and p <= v then return want end
    return 0
end

-- After buying, the cheapest listings we bought are gone from the AH
function Buy:Consume(itemID, qty)
    local d = PC:DepthTable()[itemID]
    if not d or not d.list then return end
    local left = qty
    while left > 0 and d.list[1] do
        local step = d.list[1]
        local take = math.min(left, step.q)
        step.q = step.q - take
        left = left - take
        d.total = math.max((d.total or 0) - take, 0)
        if step.q <= 0 then table.remove(d.list, 1) end
    end
    if d.list[1] then PC:Prices()[itemID] = d.list[1].p end
end

function Buy:Say(text)
    -- also in chat: the plan page (where these show) often isn't the page you're looking at
    if text and (text ~= self.msg or GetTime() - (self.msgAt or 0) > 3) then PC.Print(text) end
    self.msg, self.msgAt = text, GetTime()
    Refresh()
end

-- Message to show on the plan page (nil when there's nothing to say)
function Buy:Message()
    if self.msg and GetTime() - (self.msgAt or 0) < self.MSG_TIME then return self.msg end
    self.msg = nil
end

-- Which state a material is in: nil, "quoting", "quoted", "buying"
function Buy:StateFor(itemID)
    local b = self.buy
    if b and b.id == itemID then return b.state end
end

function Buy:Cancel()
    if self.buy and self.buy.state ~= "buying" and C_AuctionHouse and C_AuctionHouse.CancelCommoditiesPurchase then
        pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    end
    self.buy = nil
end

-- it = { id, name, qty }; chain = keep going down the plan after this one (Buy next)
function Buy:Start(it, chain)
    if not PC.ahOpen then return self:Say("|cffff8040Open the Auction House to buy.|r") end
    if not self:Supported() then return self:Say("|cffff5555This game version can't buy from here: shift-click the item to search the AH.|r") end
    local qty = it.qty or 0
    if qty <= 0 then return end
    if self:Scanning() then return self:Say("|cffff8040Still reading the Auction House: buying waits until the scan is done.|r") end
    -- prices more than an hour old: suggest a scan first (Close goes ahead)
    if PC.UI and PC.UI.StaleScan and not PC.UI.StaleScan:Check() then return end
    self:Cancel()
    -- (no bag-room limit: AH purchases arrive in your mailbox and wait there until you have room)
    local v = self:VendorPrice(it.id)
    if v then
        -- a vendor item: buy just the listings that are clearly cheaper here; the rest comes from a vendor
        local cheap = self:AHQty(it.id, qty)
        if cheap <= 0 then
            return self:Say(("|cffff8040%s is cheaper from a vendor (%s each): buy it there.|r"):format(
                it.name or PC:ItemName(it.id) or "", PC:Money(v, false, "silver")))
        elseif cheap < qty then
            self:Say(("|cffff8040Buying the %d %s that are cheaper here; the other %d from a vendor.|r"):format(cheap, it.name or "", qty - cheap))
            qty = cheap
        end
    end
    local expected = PC:CostForQty(it.id, qty)
    -- keep back what posting the plan's crafts will cost (the AH deposit)
    local reserve = PC.PostReserve and PC.UI and PC:PostReserve(PC.UI:PlanEntries()) or 0
    local budget = math.max(PC:Gold() - reserve, 0)
    if expected and expected > budget then
        -- too much for your gold: buy as many as you can afford instead
        local lo, hi = 0, qty
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            local c = PC:CostForQty(it.id, mid)
            if c and c <= budget then lo = mid else hi = mid - 1 end
        end
        if lo <= 0 then
            PC:Sound("nogold")
            return self:Say(("|cffff5555Not enough gold for any %s (%s to spend after keeping %s for posting fees).|r"):format(it.name or "", PC:Money(budget, false, true), PC:Money(reserve, false, true)))
        end
        self:Say(("|cffff8040%d %s costs about %s, more than you have to spend: buying the %d you can afford.|r"):format(
            qty, it.name or "", PC:Money(expected, false, true), lo))
        qty = lo
        expected = PC:CostForQty(it.id, qty)
    end
    -- this AH refused big purchases before ("Internal auction error"): no more than what worked
    if self.chunkLimit and qty > self.chunkLimit then
        qty = self.chunkLimit
        expected = PC:CostForQty(it.id, qty)
    end
    self.msg = nil
    self.buy = { id = it.id, name = it.name or PC:ItemName(it.id) or "", qty = qty, state = "quoting",
        expected = expected, chain = chain, tries = 0, t0 = GetTime() }
    -- live-listing reads and the purchase share the AH's message queue: pause the reads while buying
    if PC.Depth and PC.Depth.busy then PC.Depth:Stop() end
    self:SendQuote()
    Refresh()
end

-- "Internal auction error" while buying: ask again for half as many (down to 1), then give up
function Buy:OnAuctionError()
    local b = self.buy
    if not b then return false end
    pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    b.errors = (b.errors or 0) + 1
    if b.qty > 1 and b.errors <= 4 then
        b.qty = math.max(math.floor(b.qty / 2), 1)
        b.expected = PC:CostForQty(b.id, b.qty)
        b.state, b.tries = "quoting", 0
        self:Say(("|cffff8040The AH refused that: trying %d %s.|r"):format(b.qty, b.name))
        C_Timer.After(1.0, function() if Buy.buy == b then Buy:SendQuote() end end)
    else
        self.buy = nil
        self:Say(("|cffff5555The AH keeps refusing %s right now. Close and reopen it, then click Buy again.|r"):format(b.name))
    end
    Refresh()
    return true
end

-- Ask the AH for the price (when it's ready to take a request), and keep an eye on it
function Buy:SendQuote()
    local b = self.buy
    if not b or b.state ~= "quoting" then return end
    local A = C_AuctionHouse
    if A.IsThrottledMessageSystemReady and not A.IsThrottledMessageSystemReady() then
        -- the AH never got ready: don't wait forever
        if GetTime() - (b.t0 or GetTime()) > 10 then
            self.buy = nil
            Refresh()
            return self:Say("|cffff8040The AH is busy and didn't answer. Click Buy to try again.|r")
        end
        b.waitingThrottle = true
        C_Timer.After(0.5, function() if Buy.buy == b and b.waitingThrottle then b.waitingThrottle = false; Buy:SendQuote() end end)
        return
    end
    b.waitingThrottle = false
    b.tries = b.tries + 1
    local ok, err = pcall(A.StartCommoditiesPurchase, b.id, b.qty)
    if not ok then
        self.buy = nil
        return self:Say("|cffff5555Couldn't start the purchase: " .. tostring(err) .. "|r")
    end
    local try = b.tries
    C_Timer.After(self.QUOTE_TIMEOUT, function()
        if Buy.buy ~= b or b.state ~= "quoting" or b.tries ~= try then return end
        pcall(C_AuctionHouse.CancelCommoditiesPurchase)
        if b.tries < 2 then
            Buy:SendQuote() -- ask once more
        else
            Buy.buy = nil
            Buy:Say("|cffff5555The AH didn't send a price for " .. b.name .. ". Click Buy again.|r")
        end
    end)
end

function Buy:Confirm()
    local b = self.buy
    if not b or b.state ~= "quoted" then return end
    if b.total and b.total > PC:Gold() then
        self:Cancel()
        return self:Say(("|cffff5555%d %s is %s now: more than you have to spend (%s).|r"):format(
            b.qty, b.name, PC:Money(b.total, false, true), PC:Money(PC:Gold(), false, true)))
    end
    b.state = "buying"
    C_Timer.After(self.BUY_TIMEOUT, function()
        if Buy.buy == b and b.state == "buying" then
            Buy.buy = nil
            Buy:Say("|cffffd100No answer from the AH about " .. b.name .. ". Check your mailbox; if it isn't there, click Buy again.|r")
        end
    end)
    local ok, err = pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, b.id, b.qty)
    if not ok then
        self.buy = nil
        return self:Say("|cffff5555Purchase didn't go through: " .. tostring(err) .. "|r")
    end
    Refresh()
end

-- Every AH purchase (ours or by hand, any kind) is noted when it's sent; it counts as bought once,
-- whichever comes first: the AH's answer, or the gold leaving your bags. Bought = waiting in the mail.
Buy.attempts = {}
Buy.ATTEMPT_TIME = 180

function Buy:Log(what, id, qty, cost)
    local c = PC.cdb
    if not c then return end
    c.buyLog = c.buyLog or {}
    local L = c.buyLog
    L[#L + 1] = { t = time(), what = what, id = id, qty = qty, cost = cost, gold = GetMoney and GetMoney() or nil }
    while #L > 60 do table.remove(L, 1) end
end

function Buy:Attempt(id, qty, cost, how)
    if not id or not qty or qty <= 0 then return end
    local a = { id = id, qty = qty, cost = cost, t = GetTime(), gold0 = GetMoney and GetMoney() or nil, how = how }
    self.attempts[#self.attempts + 1] = a
    self:Log("try " .. (how or ""), id, qty, cost)
    -- forget old ones
    for i = #self.attempts, 1, -1 do
        if GetTime() - self.attempts[i].t > self.ATTEMPT_TIME then table.remove(self.attempts, i) end
    end
    return a
end

-- The purchase of id went through (qty, cost when known). Returns true when it was new.
function Buy:Bought(id, qty, cost, why)
    if not id then return false end
    local match
    for _, a in ipairs(self.attempts) do
        if a.id == id and not a.recorded and GetTime() - a.t <= self.ATTEMPT_TIME then match = a break end
    end
    if not match then
        -- already counted (the gold left first, then the answer came): nothing more to do
        for _, a in ipairs(self.attempts) do
            if a.id == id and a.recorded and GetTime() - a.t <= self.ATTEMPT_TIME and not a.answered then a.answered = true; return false end
        end
    end
    if match then
        match.recorded = true
        if why == "answer" then match.answered = true end
        qty, cost = qty or match.qty, cost or match.cost
    end
    qty = qty or 1
    PC:NoteMailBought(id, qty)
    if PC.Activity then PC:Activity("Bought on the AH", id, qty, cost) end
    self:Consume(id, qty) -- those listings are gone: take them off the price ladder
    self:Log("bought (" .. (why or "?") .. ")", id, qty, cost)
    Refresh()
    return true
end

function Buy:RecordBought(b)
    if not b or b.recorded then return false end
    b.recorded = true
    return self:Bought(b.id, b.qty, b.total, "answer")
end

-- Gold left your bags at the AH: the purchase(s) it pays for went through
function Buy:CheckGold()
    local now = GetMoney and GetMoney() or nil
    if not now then return end
    for _, a in ipairs(self.attempts) do
        if not a.recorded and a.gold0 and GetTime() - a.t <= self.ATTEMPT_TIME then
            local need = (a.cost and a.cost > 0) and a.cost * 0.9 or 1
            if now <= a.gold0 - need then
                if self.buy and self.buy.id == a.id and self.buy.state == "buying" then self.buy.recorded = true end
                if self:Bought(a.id, a.qty, a.cost, "gold") then
                    PC.Print(("Bought %d %s%s. It's in your mailbox."):format(a.qty, PC:ItemName(a.id) or "",
                        a.cost and (" for " .. PC:Money(a.cost)) or ""))
                end
                -- the next one is measured from here
                for _, o in ipairs(self.attempts) do if not o.recorded and o.gold0 and o.t > a.t then o.gold0 = math.min(o.gold0, now + (a.cost or 0)) end end
            end
        end
    end
end

-- While waiting, a click cancels (so a button can never get stuck)
function Buy:CancelWaiting()
    if not self.buy then return end
    pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    self.buy = nil
    self:Say("Cancelled. Click Buy to try again.")
end

-- A material row's Buy button: first click gets the price, second click buys
function Buy:Click(it)
    if not it then return end
    local b = self.buy
    if b and b.id == it.id and b.state == "quoted" then return self:Confirm() end
    if b and b.id == it.id then return self:CancelWaiting() end
    self:Start(it, false)
end

-- The next material the plan still needs from the AH (the Crafting plan page supplies the list)
function Buy:NextToBuy(skipID)
    local list = PC.UI and PC.UI.PlanBuyList and PC.UI:PlanBuyList() or {}
    for _, it in ipairs(list) do
        if it.id ~= skipID and it.qty > 0 and self:CanBuy(it.id) then return it end
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({ "AUCTION_HOUSE_CLOSED", "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
    "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
    "AUCTION_HOUSE_SHOW_ERROR", "PLAYER_MONEY" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, a1, a2)
    PC:Safe("buying", function()
        local b = Buy.buy
        if event == "AUCTION_HOUSE_CLOSED" then
            Buy.buy = nil
        elseif event == "COMMODITY_PRICE_UPDATED" then
            if b and b.state == "quoting" then
                b.unit, b.total = a1, a2
                b.state = "quoted"
                b.warn = b.expected and b.total and b.total > b.expected * Buy.PRICE_WARN or false
                -- never pay more than the vendor would charge
                local v = Buy:VendorPrice(b.id)
                if v and b.total and b.total > v * b.qty * Buy.AH_VS_VENDOR then
                    Buy:Cancel()
                    -- the cheap listings are gone: a vendor it is (for the next half hour), and the plan says so
                    Buy.vendorOnly[b.id] = GetTime()
                    if PC.Depth and PC.Depth.CheckNow then pcall(PC.Depth.CheckNow, PC.Depth, b.id) end
                    Buy:Say(("|cffff8040The AH wants %s for %d %s; a vendor sells them for %s. Switched to buying them from a vendor.|r"):format(
                        PC:Money(b.total, false, true), b.qty, b.name, PC:Money(v * b.qty, false, true)))
                    PC.UI.allEntries = nil
                    return Refresh()
                end
            end
        elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
            if b and b.waitingThrottle then b.waitingThrottle = false; Buy:SendQuote() end
            return
        elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
            -- the AH's own error ("Internal auction error"): a purchase in progress is retried smaller
            if b then Buy:OnAuctionError() end
            return
        elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
            if b then
                -- not that many for sale at once: ask for fewer
                if b.qty > 1 and Buy:OnAuctionError() then return end
                Buy.buy = nil
                return Buy:Say("|cffff5555Not enough " .. b.name .. " for sale right now. Buy fewer or try later.|r")
            end
        elseif event == "PLAYER_MONEY" then
            -- the gold for a purchase left your bags: it went through, even with no answer from the AH
            Buy:CheckGold()
            return
        elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
            Buy:Log("answer: bought", b and b.id, b and b.qty)
            -- an answer for a purchase we'd stopped waiting for (or one made by hand in the AH's window)
            if not b then
                for _, a in ipairs(Buy.attempts) do
                    if not a.answered and GetTime() - a.t <= Buy.ATTEMPT_TIME and a.how == "commodity" then
                        if a.recorded then a.answered = true
                        else a.answered = true; Buy:Bought(a.id, a.qty, a.cost, "answer") end
                        break
                    end
                end
            end
            if b then
                Buy.buy = nil
                -- it took asking for fewer: that's the size this AH takes from now on
                if b.errors and b.errors > 0 then Buy.chunkLimit = b.qty end
                Buy:RecordBought(b)              -- counts as "have" until you take it out of the mail
                PC.Print(("Bought %d %s for %s. It's in your mailbox."):format(b.qty, b.name, PC:Money(b.total or 0)))
                Buy:Say(("|cff40ff40Bought %d %s for %s.|r"):format(b.qty, b.name, PC:Money(b.total or 0, false, true)))
                -- more of the same still to buy (a stack at a time): line up the next stack straight away
                local same
                for _, x in ipairs(PC.UI and PC.UI.PlanBuyList and PC.UI:PlanBuyList() or {}) do if x.id == b.id and x.qty > 0 then same = x end end
                if same then
                    C_Timer.After(0.6, function() if not Buy.buy and PC.ahOpen then Buy:Start(same, b.chain) end end)
                    Refresh()
                    return
                end
                -- Buy next: line up the next material, so the next click buys it
                local nextItem = b.chain and Buy:NextToBuy(b.id)
                if nextItem then
                    C_Timer.After(0.6, function() if not Buy.buy and PC.ahOpen then Buy:Start(nextItem, true) end end)
                elseif PC.Depth then
                    PC.Depth:CheckNow(b.id) -- prices moved: read the listings again
                end
            end
        elseif event == "COMMODITY_PURCHASE_FAILED" then
            -- refused: ask again for fewer (it gives up by itself once it's down to 1)
            if b and Buy:OnAuctionError() then return end
            Buy.buy = nil
            if b then return Buy:Say("|cffff5555Buying " .. b.name .. " failed. Try again.|r") end
        end
        Refresh()
    end)
end)

---------------------------------------------------------------------------
-- Buying from a vendor (while a merchant window is open)
--   Vendor purchases go straight into your bags, so everything can be bought in one click.
---------------------------------------------------------------------------
local VB = {}
PC.VendorBuy = VB

function VB:Open() return PC.merchantOpen and true or false end

local function MerchantItemID(i)
    if GetMerchantItemID then
        local ok, id = pcall(GetMerchantItemID, i)
        if ok and id then return id end
    end
    local link = GetMerchantItemLink and GetMerchantItemLink(i)
    return link and tonumber(link:match("item:(%d+)"))
end

-- price for `batch` items, how many are left (-1 = unlimited), and whether it costs something other than gold
local function MerchantInfo(i)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local ok, info = pcall(C_MerchantFrame.GetItemInfo, i)
        if ok and type(info) == "table" then
            return info.price, info.stackCount or 1, info.numAvailable or -1, info.isPurchasable ~= false, info.hasExtendedCost
        end
    end
    if GetMerchantItemInfo then
        local _, _, price, batch, avail, purchasable, _, ext = GetMerchantItemInfo(i)
        return price, batch or 1, avail or -1, purchasable ~= false, ext
    end
end

-- Merchant slot selling this item for gold (nil if this vendor doesn't)
function VB:Find(itemID)
    if not self:Open() or not GetMerchantNumItems then return nil end
    for i = 1, GetMerchantNumItems() or 0 do
        if MerchantItemID(i) == itemID then
            local price, _, avail, purchasable, ext = MerchantInfo(i)
            if price and price > 0 and purchasable and not ext and avail ~= 0 then return i end
        end
    end
end

function VB:Sells(itemID) return self:Find(itemID) ~= nil end

-- Buy qty of an item from the open vendor; returns how many were bought
function VB:Buy(itemID, qty, quiet)
    local i = self:Find(itemID)
    local name = PC:ItemName(itemID) or "that item"
    if not i then
        if not quiet then Buy:Say("|cffff8040This vendor doesn't sell " .. name .. ".|r") end
        return 0
    end
    local price, batch, avail = MerchantInfo(i)
    batch = math.max(batch or 1, 1)
    if avail and avail > 0 then qty = math.min(qty, avail * batch) end
    local fits = PC:FitsQty(itemID, qty, PC.BUY_RESERVE)
    if fits <= 0 then
        if not quiet then Buy:Say("|cffff5555Your bags are full: no room for " .. name .. ". Store something in the bank first.|r") end
        return 0
    end
    qty = math.min(qty, fits)
    local each = price / batch
    local cost = math.ceil(qty / batch) * price
    if cost > PC:Gold() then
        if not quiet then
            Buy:Say(("|cffff5555%d %s costs %s: more than you have to spend (%s).|r"):format(
                qty, name, PC:Money(cost, false, true), PC:Money(PC:Gold(), false, true)))
        end
        return 0
    end
    -- one purchase at a time, a moment apart: the server drops purchases sent all at once (that's
    -- why only the first batch used to arrive). Then count what's in your bags and top up what's short.
    -- as few purchases as the vendor allows: the game buys the number of ITEMS you ask for (sold in 5s
    -- or not), up to the most it sells at once - so 25 vials sold in 5s is one purchase of 25, not 5
    local calls = {}
    local bought = 0
    local per = self:PerPurchase(i, batch, itemID)
    local left = math.ceil(qty / batch) * batch -- whole bundles: the vendor only sells them in its 5s
    while left > 0 do
        local n = math.min(left, per)
        calls[#calls + 1] = n
        bought, left = bought + n, left - n
    end
    local start = PC:BagCount(itemID)
    self:Queue(itemID, calls, start + bought, batch, { start = start, each = each, name = name, want = bought, quiet = quiet })
    local spent = math.floor(each * bought + 0.5)
    -- (what you paid is recorded once the items are really in your bags, not before)
    if not quiet then
        Buy:Say(("|cffffd100Buying %d %s from the vendor (a few seconds)...|r"):format(bought, name))
    end
    return bought, spent
end

-- the most one purchase can be: the vendor's max stack, in whole bundles
function VB:PerPurchase(i, batch, itemID)
    batch = math.max(batch or 1, 1)
    local maxStack = math.max((GetMerchantItemMaxStack and GetMerchantItemMaxStack(i)) or 1, 1)
    -- this game says 1 (or nothing) for things that stack: a full stack is what a vendor sells at once
    -- (26 vials used to be 26 purchases)
    if itemID then maxStack = math.max(maxStack, PC:StackSize(itemID) or 1) end
    return math.max(math.floor(maxStack / batch) * batch, batch)
end

-- The purchase queue: { itemID, n } one every BUY_GAP seconds, re-found on the vendor each time
VB.BUY_GAP = 0.3 -- the vendor drops purchases that come too fast (0.3s is still safe)
VB.queue = {}
function VB:Queue(itemID, calls, target, batch, info)
    for _, n in ipairs(calls) do self.queue[#self.queue + 1] = { id = itemID, n = n } end
    self.queue[#self.queue + 1] = { id = itemID, check = target, batch = batch or 1, tries = 0, info = info }
    if not self.pumping then self:Pump() end
end

-- how many of an item are still waiting in the queue to be bought
function VB:Pending(itemID)
    local n = 0
    for _, q in ipairs(self.queue) do
        if q.id == itemID and q.n then n = n + q.n end -- (q.n is items, bundles or not)
    end
    return n
end

function VB:Pump()
    local q = table.remove(self.queue, 1)
    if not q or not PC.merchantOpen then
        self.pumping = nil
        if not PC.merchantOpen then self.queue = {} end
        return
    end
    self.pumping = true
    if q.check and not q.waited then
        -- give the last purchase a second to land in your bags before counting
        q.waited = true
        table.insert(self.queue, 1, q)
        C_Timer.After(1.0, function() PC:Safe("vendor buy", self.Pump, self) end)
        return
    end
    if q.check then
        -- all sent: anything that didn't arrive gets bought again (up to 3 times)
        local short = q.check - PC:BagCount(q.id)
        if short > 0 and q.tries < 3 then
            local i = self:Find(q.id)
            if i then
                local per = self:PerPurchase(i, q.batch, q.id)
                short = math.ceil(short / math.max(q.batch, 1)) * math.max(q.batch, 1)
                local add = {}
                while short > 0 do add[#add + 1] = math.min(short, per); short = short - per end
                for k = #add, 1, -1 do table.insert(self.queue, 1, { id = q.id, n = add[k] }) end
                table.insert(self.queue, #add + 1, { id = q.id, check = q.check, batch = q.batch, tries = q.tries + 1, info = q.info })
            end
        else
            -- done: say and record what really arrived
            local inf = q.info
            if inf then
                local got = math.max(PC:BagCount(q.id) - (inf.start or 0), 0)
                local spent = math.floor((inf.each or 0) * got + 0.5)
                if got > 0 then
                    PC:Record("buy", spent, inf.name, got) -- vendor buys count in Profit & loss too
                    PC:NotePaid(q.id, got, spent)
                end
                if short > 0 then
                    Buy:Say(("|cffff8040Bought %d of %d %s for %s: the vendor wouldn't sell the rest (sold out, or not enough gold).|r"):format(
                        got, inf.want or got, inf.name or "", PC:Money(spent, false, true)))
                elseif not inf.quiet then
                    Buy:Say(("|cff40ff40Bought %d %s from the vendor for %s.|r"):format(got, inf.name or "", PC:Money(spent, false, true)))
                end
            elseif short > 0 then
                Buy:Say(("|cffff8040Couldn't buy %d more %s: the vendor didn't sell them (sold out, or not enough gold).|r"):format(short, PC:ItemName(q.id) or "of that"))
            end
            PC:RefreshUI()
        end
        C_Timer.After(self.BUY_GAP, function() PC:Safe("vendor buy", self.Pump, self) end)
        return
    end
    local i = self:Find(q.id)
    if i then BuyMerchantItem(i, q.n) end
    C_Timer.After(self.BUY_GAP, function() PC:Safe("vendor buy", self.Pump, self) end)
end

-- Everything the plan needs from vendors that this vendor sells: { id, name, qty }
function VB:PlanList()
    local list = PC.UI and PC.UI.PlanVendorList and PC.UI:PlanVendorList() or {}
    local out = {}
    for _, it in ipairs(list) do
        local left = it.qty - self:Pending(it.id) -- already on its way: not bought twice
        if left > 0 and self:Sells(it.id) then out[#out + 1] = { id = it.id, name = it.name, qty = left } end
    end
    return out
end

function VB:BuyAll()
    local list = self:PlanList()
    if #list == 0 then return Buy:Say("This vendor doesn't sell anything your plan still needs.") end
    local total = 0
    for _, it in ipairs(list) do
        local cost = 0
        local i = self:Find(it.id)
        if i then
            local price, batch = MerchantInfo(i)
            cost = math.ceil(it.qty / math.max(batch or 1, 1)) * price
        end
        total = total + cost
    end
    if total > PC:Gold() then
        return Buy:Say(("|cffff5555Everything from this vendor costs %s: more than you have to spend (%s).|r"):format(
            PC:Money(total, false, true), PC:Money(PC:Gold(), false, true)))
    end
    local n, spent = 0, 0
    for _, it in ipairs(list) do
        local got, cost = self:Buy(it.id, it.qty, true)
        if got > 0 then n, spent = n + 1, spent + (cost or 0) end
    end
    -- (each item says what really arrived once it's in your bags)
    Buy:Say(("|cffffd100Buying %d material%s from the vendor (a few seconds)...|r"):format(n, n == 1 and "" or "s"))
end

local mev = CreateFrame("Frame")
pcall(mev.RegisterEvent, mev, "MERCHANT_UPDATE")
mev:SetScript("OnEvent", function() if PC.merchantOpen then PC:RefreshUI() end end)

---------------------------------------------------------------------------
-- Things this AH sells as separate auctions (not commodities): the button buys the cheapest
-- listing, one per click. Purchases made by hand in the AH's own window count too: they're in
-- the mail, so the plan doesn't ask for them again.
---------------------------------------------------------------------------
Buy.itemResults, Buy.seenAuction, Buy.commodityHere = {}, {}, {}
Buy.LISTING_FRESH = 120 -- seconds a search's listings are trusted

function Buy:ListingsSupported()
    local A = C_AuctionHouse
    return A and A.PlaceBid and A.GetItemSearchResultInfo and A.GetNumItemSearchResults and true or false
end

-- the most to pay for one: never over a vendor's price (less 10%), nor far over the usual price
function Buy:Cap(itemID)
    local v, p = self:VendorPrice(itemID), PC:Price(itemID)
    local cap = p and p * self.PRICE_WARN or nil
    if v then cap = math.min(cap or math.huge, v * self.AH_VS_VENDOR) end
    return cap
end

function Buy:ReadItemResults(itemKey)
    local id = type(itemKey) == "table" and itemKey.itemID
    if not id or not self:ListingsSupported() then return end
    local A = C_AuctionHouse
    local ok, n = pcall(A.GetNumItemSearchResults, itemKey)
    local list = {}
    for i = 1, (ok and n or 0) do
        local ok2, r = pcall(A.GetItemSearchResultInfo, itemKey, i)
        if ok2 and r and r.auctionID and (r.buyoutAmount or 0) > 0 and (r.quantity or 0) > 0 and not r.containsOwnerItem then
            local q = r.quantity
            list[#list + 1] = { auctionID = r.auctionID, qty = q, buyout = r.buyoutAmount, unit = r.buyoutAmount / q }
            self.seenAuction[r.auctionID] = { id = id, qty = q, cost = r.buyoutAmount }
        end
    end
    table.sort(list, function(a, b) return a.unit < b.unit end)
    self.itemResults[id] = { list = list, t = GetTime() }
end

-- listings read for this item lately (the step then says "Buy", not "Find")
function Buy:HasListings(itemID)
    local res = self.itemResults[itemID]
    return self:ListingsSupported() and res and GetTime() - res.t < self.LISTING_FRESH and #res.list > 0 or false
end

-- the next listing worth buying: cheapest first, within the price cap, not a huge stack over what's needed
function Buy:NextListing(it)
    local res = self.itemResults[it.id]
    if not res then return nil end
    local cap = self:Cap(it.id)
    local room = (it.qty or 1) + math.max(PC:StackSize(it.id), 1)
    for i, r in ipairs(res.list) do
        if (not cap or r.unit <= cap) and r.qty <= room then return r, i, cap end
    end
    return nil, nil, cap
end

function Buy:BuyListing(it)
    if not PC.ahOpen then return self:Say("|cffff8040Open the Auction House first.|r") end
    if PC.UI and PC.UI.StaleScan and not PC.UI.StaleScan:Check() then return end
    if not self:HasListings(it.id) then return self:SearchAH(it) end
    local r, i, cap = self:NextListing(it)
    if not r then
        self.itemResults[it.id] = nil
        return self:Say(("|cffff8040No %s listed at or under %s each right now.|r"):format(it.name or PC:ItemName(it.id) or "",
            cap and PC:Money(cap, false, true) or "a fair price"))
    end
    local money = GetMoney and GetMoney() or 0
    if money < r.buyout then
        return self:Say(("|cffff8040Not enough gold: %d %s costs %s.|r"):format(r.qty, it.name or "", PC:Money(r.buyout, false, true)))
    end
    table.remove(self.itemResults[it.id].list, i)
    self.pendingBid = { auctionID = r.auctionID, id = it.id, qty = r.qty, cost = r.buyout, t = GetTime() }
    local ok, err = pcall(C_AuctionHouse.PlaceBid, r.auctionID, r.buyout)
    if not ok then
        self.pendingBid = nil
        return self:Say("|cffff5555Couldn't buy it: " .. tostring(err) .. "|r")
    end
    self:Say(("Buying %d %s for %s..."):format(r.qty, it.name or "", PC:Money(r.buyout, false, true)))
    return true
end

do
    local f = CreateFrame("Frame")
    for _, e in ipairs({ "ITEM_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_UPDATED", "AUCTION_HOUSE_PURCHASE_COMPLETED" }) do
        pcall(f.RegisterEvent, f, e)
    end
    f:SetScript("OnEvent", function(_, event, a1)
        PC:Safe("buying", function()
            if event == "ITEM_SEARCH_RESULTS_UPDATED" then
                Buy:ReadItemResults(a1)
            elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
                if type(a1) == "number" then Buy.commodityHere[a1] = true end
            elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
                local a = Buy.seenAuction[a1]
                if a then
                    Buy.seenAuction[a1] = nil
                    if Buy.pendingBid and Buy.pendingBid.auctionID == a1 then Buy.pendingBid = nil end
                    Buy:Bought(a.id, a.qty, a.cost, "answer") -- waiting in the mail: counts as "have"
                    Buy:Say(("|cff40ff40Bought %d %s for %s. It's in your mailbox.|r"):format(a.qty, PC:ItemName(a.id) or "", PC:Money(a.cost, false, true)))
                end
            end
            Refresh()
        end)
    end)
    -- every purchase sent to the AH, by ProfitCrafter or by hand: noted so it's counted when it goes through
    if hooksecurefunc and C_AuctionHouse then
        if C_AuctionHouse.ConfirmCommoditiesPurchase then
            hooksecurefunc(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(id, q)
                PC:Safe("buying", function()
                    local b = Buy.buy
                    local cost = (b and b.id == id and b.total) or PC:CostForQty(id, q or 1)
                    Buy:Attempt(id, q, cost, "commodity")
                end)
            end)
        end
        if C_AuctionHouse.PlaceBid then
            hooksecurefunc(C_AuctionHouse, "PlaceBid", function(auctionID, amount)
                PC:Safe("buying", function()
                    local a = Buy.seenAuction[auctionID]
                    if a then Buy:Attempt(a.id, a.qty, amount or a.cost, "listing") end
                end)
            end)
        end
    end
    -- a classic-style AH: a buyout on the Browse list
    if hooksecurefunc and PlaceAuctionBid and GetAuctionItemInfo then
        hooksecurefunc("PlaceAuctionBid", function(kind, index, bid)
            PC:Safe("buying", function()
                local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = GetAuctionItemInfo(kind or "list", index)
                if itemID and bid and buyout and bid >= buyout then Buy:Attempt(itemID, count or 1, bid, "classic") end
            end)
        end)
    end
end
