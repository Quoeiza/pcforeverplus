-- ProfitCrafter: buying materials straight from the Crafting plan
--   Each material row has a Buy button, and the Task Button works down the list.
--   The game needs a real click to ask the AH for a price; the price that comes back is checked
--   (still under your minimum profit's ceiling, no more than the listings showed) and the purchase is
--   confirmed by itself: one click buys (Settings: off, or if the game refuses, the next click
--   confirms). After each purchase the next stack is lined up (worked out fresh).
--   Purchases arrive by mail; until you take them out they still count as "have" (PC:MailPending).
--   Never more than the plan needs, whatever the lag: a purchase counts as had the moment it's sent
--   (Buy:InFlight), and nothing more is bought on the AH until its outcome is known.

local ADDON, ns = ...
local PC = ns.PC

local Buy = {}
PC.Buy = Buy

Buy.PRICE_WARN = 1.25    -- separate auctions: never far over the usual price
Buy.PRICE_TOL = 1.05     -- the AH's price may be up to 5% over what its listings showed; more and they're read again
Buy.QUOTE_TIMEOUT = 4    -- seconds to wait for the AH's price before asking again
Buy.QUOTE_AGE = 10       -- seconds a price is trusted before the confirm click asks again
Buy.MSG_TIME = 12        -- seconds a message stays on the Crafting plan page
Buy.retry = {}           -- [itemID] = { qty, errors, refused }: a smaller retry the game blocked, for the next click
Buy.chunkLimit = {}      -- [itemID] = the most this AH took in one purchase after refusing more
Buy.asked = 0            -- price requests sent and not answered (no request ids: answers come in order)

local function Refresh() if PC.RefreshUI then PC:RefreshUI() end end
local function Name(id) return PC:ItemName(id) or "" end

-- Drop the AH's held price request; an answer still on its way no longer belongs to any buy
local function CancelQuote()
    Buy.askedBy = nil
    if C_AuctionHouse and C_AuctionHouse.CancelCommoditiesPurchase then pcall(C_AuctionHouse.CancelCommoditiesPurchase) end
end

-- A price event: "mine", "stale" (an older request's) or "push" (none out: the AH repricing its hold)
function Buy:TakeAnswer()
    local n = self.asked or 0
    if n == 0 then return "push" end
    self.asked = n - 1
    local b, by = self.buy, self.askedBy
    if self.asked == 0 then self.askedBy = nil end
    if n == 1 and b and by == b and b.state == "quoting" then return "mine" end
    return "stale"
end

function Buy:ReadAgain(id)
    if PC.Depth and PC.Depth.CheckNow then pcall(PC.Depth.CheckNow, PC.Depth, id) end
end

-- The plan's shopping list the way the Task Button sees it (settled when you walked up to the AH or
-- a vendor, what's still to buy kept current), worked out now: nil without a plan page
local function PlanShop()
    local UI = PC.UI
    if not (UI and UI.PlanEntries) then return nil end
    if not UI.allEntries and PC.Analyze then UI.allEntries = PC:Analyze() end -- (cleared after a change)
    local _, list = PC:StopShopList(UI:PlanEntries(), 1)
    return list
end

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
    if not ok then return self:Say("|cffff8040Couldn't run the search: type " .. name .. " into the Auction House's search box.|r") end
    local cap = self:VendorPrice(it.id)
    local price = PC:Price(it.id)
    local limit = cap and ("under " .. PC:Money(cap, false, true) .. " each (what a vendor charges)")
        or (price and ("about " .. PC:Money(price, false, true) .. " each") or "")
    self:Say(("|cff40ff40Searching the Auction House for %s: buy %d, %s.|r"):format(name, it.qty or 1, limit))
    return true
end

-- Can this material be bought from here? (commodities only: gear and such need the AH's own window)
function Buy:CanBuy(itemID)
    -- (the AH's own search answering with commodity listings settles it, whatever the item info says)
    return itemID and self:Supported() and (PC:IsCommodity(itemID) or (self.commodityHere and self.commodityHere[itemID])) or false
end

-- What a vendor charges for it (nil when no vendor sells it)
function Buy:VendorPrice(itemID)
    return PC.db and PC.db.vendor and PC:VendorCost(itemID)
end

-- Items a vendor also sells come from the AH only while it's cheaper there than the vendor (the
-- AH's quote has to confirm it). Returns how many of `want` can be bought on the AH that way
-- (0 = buy them all from the vendor).
Buy.vendorOnly = {} -- the AH quoted the vendor's price or more: vendor it for a while
function Buy:AHQty(itemID, want)
    want = want or 0
    local v = self:VendorPrice(itemID)
    if not v or want <= 0 then return want end
    local t = self.vendorOnly[itemID]
    if t and GetTime() - t < 1800 then return 0 end
    local d = PC:DepthTable()[itemID]
    if d and d.list and #d.list > 0 then
        local n = 0
        for _, step in ipairs(d.list) do
            if step.p < v then n = n + step.q else break end -- listings are cheapest first
        end
        return math.min(want, n)
    end
    -- no live listings read yet: go by the cheapest price we know (the AH's quote is checked again)
    local p = PC:Price(itemID)
    if p and p < v then return want end
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

-- Drop the purchase being set up (never one already sent: that waits for its outcome)
function Buy:Cancel()
    local b = self.buy
    if b and b.state == "buying" then return end
    if b then CancelQuote() end
    self.buy = nil
end

-- How many of an item to buy on the AH now, worked out fresh every time (never from a list made
-- earlier): what the plan still needs (purchases sent a moment ago already count as had), only the
-- listings under a vendor's price, and only while each one keeps its craft at the minimum profit.
-- asked: the most wanted (nil = what the plan needs). Returns how many, the most one may cost
-- (nil = no limit), and why it's fewer than asked: "have", "vendor", "profit", "market" or nil.
function Buy:Goal(id, asked)
    local want, why = asked, nil
    for _, it in ipairs(PlanShop() or {}) do
        -- a plan material: never more than the plan still needs (not in the plan: as asked)
        if it.id == id and not it.tool then want = math.min(asked or math.huge, it.buy or 0) break end
    end
    want = math.max(math.floor(want or 0), 0)
    if asked and want < asked then why = "have" end
    if want <= 0 then return 0, nil, why or "have" end
    local ah = self:AHQty(id, want)
    if ah < want then why = "vendor" end
    if ah <= 0 then return 0, nil, why end
    local n, maxEach, pwhy = PC:ProfitableBuyQty(id, ah)
    if n < ah then why = pwhy or "profit" end
    return n, maxEach, why
end

-- Why fewer (or none) are bought, in words
function Buy:SayGoal(id, name, n, why)
    local pct = PC:MinProfitPct()
    if why == "profit" then
        if n <= 0 then return self:Say(("|cffff8040Stopped buying %s: more would drop the craft under %d%% profit.|r"):format(name, pct)) end
        self:Say(("|cffff8040Buying only %d %s: more would drop the craft under %d%% profit.|r"):format(n, name, pct))
    elseif why == "vendor" then
        if n <= 0 then
            return self:Say(("|cffff8040%s is cheaper from a vendor (%s each): buy it there.|r"):format(name, PC:Money(self:VendorPrice(id) or 0, false, "silver")))
        end
        self:Say(("|cffff8040Buying %d %s here; the rest is cheaper from a vendor.|r"):format(n, name))
    elseif why == "have" then
        if n <= 0 then return self:Say(("|cff40ff40You already have all the %s the plan needs (mail and purchases on the way included).|r"):format(name)) end
        self:Say(("|cffffd100Buying %d %s; you have the rest (mail and purchases on the way included).|r"):format(n, name))
    end
end

-- One click buys: the price is checked and confirmed by itself (Settings), unless the game said no
function Buy:AutoConfirm()
    return PC.db and PC.db.autoConfirm ~= false and not PC.db.confirmNeedsClick
end

-- it = { id, name, qty (the most wanted; nil = what the plan needs) }; chain = keep going down the plan;
-- auto = a click that buys in one go (the price checked, then confirmed by itself)
function Buy:Start(it, chain, auto)
    if not PC.ahOpen then return self:Say("|cffff8040Open the Auction House to buy.|r") end
    if not self:Supported() then return self:Say("|cffff5555This game version can't buy from here: shift-click the item to search the Auction House.|r") end
    if not it or not it.id then return end
    -- one AH purchase at a time: nothing new until the last one's outcome is known
    local waiting = self:Unsettled()
    if waiting then return self:SayWaiting(waiting) end
    if self:Scanning() then return self:Say("|cffff8040Still reading the Auction House: buying waits until the scan is done.|r") end
    -- prices more than an hour old: suggest a scan first (Close goes ahead)
    if PC.UI and PC.UI.StaleScan and not PC.UI.StaleScan:Check() then return end
    self:Cancel()
    local r = self.retry[it.id]
    self.retry[it.id] = nil
    -- the smaller amount a blocked retry was about to ask for, so the halving still converges
    if r and not it.errors then it = { id = it.id, name = it.name, qty = math.min(it.qty or r.qty, r.qty), errors = r.errors, refused = r.refused } end
    local name = it.name or Name(it.id)
    -- how many: worked out now (a row or step made earlier may be out of date)
    -- (no bag-room limit: AH purchases arrive in your mailbox and wait there until you have room)
    local qty, maxEach, why = self:Goal(it.id, it.qty)
    if why then self:SayGoal(it.id, name, qty, why) end
    -- nothing more pays: the plan is amended to what you have of it
    if qty <= 0 and why == "profit" then PC:AmendPlanSoon(it.id) end
    if qty <= 0 then return end
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
            return self:Say(("|cffff5555Not enough gold for any %s (%s spare after keeping %s for deposits).|r"):format(name, PC:Money(budget, false, true), PC:Money(reserve, false, true)))
        end
        self:Say(("|cffff8040%d %s costs about %s, more than you have to spend: buying the %d you can afford.|r"):format(
            qty, name, PC:Money(expected, false, true), lo))
        qty = lo
        expected = PC:CostForQty(it.id, qty)
    end
    -- this AH refused big purchases before ("Internal auction error"): no more than what worked
    local lim = self.chunkLimit and self.chunkLimit[it.id]
    if lim and qty > lim then
        qty = lim
        expected = PC:CostForQty(it.id, qty)
    end
    self.msg = nil
    self.buy = { id = it.id, name = name, qty = qty, state = "quoting", expected = expected, maxEach = maxEach,
        chain = chain, errors = it.errors, refused = it.refused, tries = 0, t0 = GetTime(), auto = auto }
    -- live-listing reads and the purchase share the AH's message queue: pause the reads while buying
    if PC.Depth and PC.Depth.busy then PC.Depth:Stop() end
    self:SendQuote()
    Refresh()
end

-- "Internal auction error" while buying: ask again for half as many (down to 1), then give up.
-- (a purchase already sent is left alone: its own outcome settles it)
-- shortage: too few listed, which says nothing about how much this AH takes at once
function Buy:OnAuctionError(shortage)
    local b = self.buy
    if not b then return false end
    if b.state == "buying" then return true end
    CancelQuote()
    self:ReadAgain(b.id)
    b.errors = (b.errors or 0) + 1
    if not shortage then b.refused = true end
    if b.qty > 1 and b.errors <= 4 then
        b.qty = math.max(math.floor(b.qty / 2), 1)
        b.expected = PC:CostForQty(b.id, b.qty)
        b.state, b.tries, b.t0 = "quoting", 0, GetTime()
        self:Say(("|cffff8040The Auction House refused that: trying %d %s.|r"):format(b.qty, b.name))
        C_Timer.After(1.0, function() if Buy.buy == b then Buy:SendQuote() end end)
    else
        self.buy = nil
        self:Say(("|cffff5555The Auction House keeps refusing %s right now. Close and reopen it, then click Buy again.|r"):format(b.name))
    end
    Refresh()
    return true
end

-- Ask the AH for the price (when it's ready to take a request), and keep an eye on it
function Buy:SendQuote()
    local b = self.buy
    if not b or b.state ~= "quoting" then return end
    local A = C_AuctionHouse
    -- (an older request still unanswered: its answer would be taken for this one's)
    if (A.IsThrottledMessageSystemReady and not A.IsThrottledMessageSystemReady()) or (self.asked or 0) > 0 then
        -- the AH never got ready: don't wait forever
        if GetTime() - (b.t0 or GetTime()) > 10 then
            self.buy = nil
            Refresh()
            return self:Say("|cffff8040The Auction House is busy and didn't answer. Click Buy to try again.|r")
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
    if self.buy ~= b then return end -- (blocked: the game sent nothing)
    self.asked, self.askedBy = (self.asked or 0) + 1, b
    local try, sent = b.tries, {}
    self.askedToken = sent
    C_Timer.After(self.QUOTE_TIMEOUT, function()
        -- no answer in time: an answer that never comes mustn't hold up the next request
        if Buy.askedToken == sent then
            Buy.asked, Buy.askedBy = 0, nil
            local w = Buy.buy
            if w and w.waitingThrottle then w.waitingThrottle = false; Buy:SendQuote() end
        end
        if Buy.buy ~= b or b.state ~= "quoting" or b.tries ~= try then return end
        CancelQuote()
        if b.tries < 2 then
            Buy:SendQuote() -- ask once more
        else
            Buy.buy = nil
            Buy:Say("|cffff5555The Auction House didn't send a price for " .. b.name .. ". Click Buy again.|r")
        end
    end)
end

-- The AH's price, checked before it can be bought: under the vendor's price, no more than the
-- listings showed (a little leeway), and still a profit. Otherwise it's cancelled and said why.
function Buy:CheckQuote(b)
    local total, qty = b.total or 0, b.qty
    b.warn = b.expected and total > b.expected or false
    local function readAgain() self:ReadAgain(b.id) end
    local v = self:VendorPrice(b.id)
    if v and total >= v * qty then
        self:Cancel()
        -- the cheap listings are gone: a vendor it is (for the next half hour), and the plan says so
        self.vendorOnly[b.id] = GetTime()
        readAgain()
        self:Say(("|cffff8040The Auction House wants %s for %d %s; a vendor charges %s. Switched to buying them from a vendor.|r"):format(
            PC:Money(total, false, true), qty, b.name, PC:Money(v * qty, false, true)))
        if PC.UI then PC.UI.allEntries = nil end
        return false
    end
    if b.maxEach and total > b.maxEach * qty then
        self:Cancel()
        readAgain()
        self:Say(("|cffff8040Stopped buying %s: the Auction House wants %s each, and over %s drops the craft under %d%% profit.|r"):format(
            b.name, PC:Money(math.floor(total / qty), false, true), PC:Money(math.floor(b.maxEach), false, true), PC:MinProfitPct()))
        return false
    end
    if b.expected and total > b.expected * self.PRICE_TOL then
        self:Cancel()
        readAgain()
        self:Say(("|cffff8040The Auction House wants %s for %d %s, more than its listings showed (%s). Rechecking them; click Buy when done.|r"):format(
            PC:Money(total, false, true), qty, b.name, PC:Money(b.expected, false, true)))
        return false
    end
    return true
end

function Buy:Confirm()
    local b = self.buy
    if not b or b.state ~= "quoted" then return end
    -- an old price may no longer be the one the AH holds (this is a click, so asking again is allowed)
    if GetTime() - (b.quotedAt or GetTime()) > self.QUOTE_AGE then
        self:Cancel()
        self:Say(("|cffffd100The price for %s was over %d seconds old. Asking again.|r"):format(b.name, self.QUOTE_AGE))
        return self:Start({ id = b.id, name = b.name, qty = b.qty, errors = b.errors, refused = b.refused }, b.chain, b.auto)
    end
    -- checked once more right before buying: the plan may need fewer by now (an earlier purchase
    -- was answered meanwhile): ask again for the smaller amount, or stop
    local goal, maxEach, why = self:Goal(b.id, b.qty)
    if goal < b.qty then
        self:Cancel()
        if goal <= 0 and why == "profit" then PC:AmendPlanSoon(b.id) end
        if goal <= 0 then return self:SayGoal(b.id, b.name, 0, why) end
        return self:Start({ id = b.id, name = b.name, qty = goal, errors = b.errors, refused = b.refused }, b.chain, b.auto)
    end
    if maxEach and (b.total or 0) > maxEach * b.qty then
        self:Cancel()
        return self:SayGoal(b.id, b.name, 0, "profit")
    end
    if b.total and b.total > PC:Gold() then
        self:Cancel()
        return self:Say(("|cffff5555%d %s is %s now: more than you have to spend (%s).|r"):format(
            b.qty, b.name, PC:Money(b.total, false, true), PC:Money(PC:Gold(), false, true)))
    end
    b.state = "buying"
    local ok, err = pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, b.id, b.qty)
    if not ok then
        self.buy = nil
        return self:Say("|cffff5555Purchase didn't go through: " .. tostring(err) .. "|r")
    end
    -- (the game stopped it there and then: it's back to waiting for the click, nothing was sent)
    if b.state ~= "buying" then return Refresh() end
    -- (noted by the hook on the game's function; here too in case it didn't run)
    if not b.attempt then
        b.attempt = self:Attempt(b.id, b.qty, b.total, "commodity")
        if b.attempt then b.attempt.b = b end
    end
    if b.attempt and b.autoConfirm then b.attempt.auto = true end
    Refresh()
end

-- The game wouldn't let ProfitCrafter confirm by itself: from now on the next click confirms (the
-- price already asked for stays: one more click buys it). Said once.
function Buy:ConfirmNeedsClick(b)
    if not PC.db.confirmNeedsClick then
        PC.db.confirmNeedsClick = true
        self:Say("|cffff8040The game wants a click to confirm each purchase. From now on the first click gets the price and the second buys.|r")
    end
    if b and self.buy == b and b.state == "buying" then
        if b.attempt then b.attempt.settled, b.attempt.outcome, b.attempt.gold0 = true, "blocked", nil end
        b.attempt, b.state, b.autoConfirm = nil, "quoted", nil
    end
    Refresh()
end

---------------------------------------------------------------------------
-- Every AH purchase sent (ours or by hand) is an attempt, settled exactly once. Until then it
-- counts as had (InFlight: the plan's "still to buy" drops the moment it's sent) and nothing more
-- is bought on the AH, so every answer is known to be for it. Two checks, and both count: the AH's
-- answer, and the gold leaving your bags. Bought = waiting in the mail (PC:MailPending).
--   answer + gold: bought. An answer with no gold (or gold with no answer) a moment later: bought,
--   and said. Failed: not bought. No answer and no gold in ANSWER_TIME: it never went through.
---------------------------------------------------------------------------
Buy.attempts = {}
Buy.ATTEMPT_TIME = 180  -- seconds an attempt is remembered (its gold watched, for a late purchase)
Buy.ANSWER_TIME = 60    -- no answer and no gold by then: it never went through
Buy.GOLD_WAIT = 5       -- the AH said bought: how long the gold may take to leave
Buy.ANSWER_WAIT = 10    -- the gold left: how long the AH's answer may take

function Buy:Log(what, id, qty, cost)
    local c = PC.cdb
    if not c then return end
    c.buyLog = c.buyLog or {}
    local L = c.buyLog
    L[#L + 1] = { t = time(), what = what, id = id, qty = qty, cost = cost, gold = GetMoney and GetMoney() or nil }
    while #L > 60 do table.remove(L, 1) end
end

function Buy:Attempt(id, qty, cost, how, auctionID)
    if not id or not qty or qty <= 0 then return end
    local now = GetTime()
    for i = #self.attempts, 1, -1 do -- forget old ones
        local o = self.attempts[i]
        if o.settled and now - o.t > self.ATTEMPT_TIME then table.remove(self.attempts, i) end
    end
    local a = { id = id, qty = qty, cost = cost, t = now, gold0 = GetMoney and GetMoney() or nil, how = how, auctionID = auctionID }
    self.attempts[#self.attempts + 1] = a
    self:Log("try " .. (how or ""), id, qty, cost)
    C_Timer.After(self.ANSWER_TIME, function() PC:Safe("buying", Buy.TimeUp, Buy, a) end)
    Refresh()
    return a
end

-- AH units sent whose outcome isn't settled yet (PC:ItemCount counts them as had)
function Buy:InFlight(itemID)
    local n = 0
    for _, a in ipairs(self.attempts) do
        if a.id == itemID and not a.settled and not a.recorded then n = n + a.qty end
    end
    return n
end

-- The AH purchase whose outcome isn't known yet (nil when there's none)
function Buy:Unsettled()
    for _, a in ipairs(self.attempts) do if not a.settled then return a end end
end

function Buy:SayWaiting(a)
    a = a or self:Unsettled()
    if not a then return end
    local text = ("|cffffd100Waiting for the Auction House to confirm %d %s. Nothing else is bought until it does.|r"):format(a.qty, Name(a.id))
    -- said in chat once per purchase (pressing again while it waits only shows it on the plan page)
    if a.told then
        self.msg, self.msgAt = text, GetTime()
        return Refresh()
    end
    a.told = true
    self:Say(text)
end

-- Counted as bought: it waits in the mail (PC:MailPending) until it's in your bags. Only ever once.
function Buy:Record(a, why)
    if a.recorded then return end
    a.recorded = true
    PC:NoteMailBought(a.id, a.qty)
    if PC.Activity then PC:Activity("Bought at auction", a.id, a.qty, a.cost) end
    self:Consume(a.id, a.qty) -- those listings are gone: take them off the price ladder
    self:Log("bought (" .. why .. ")", a.id, a.qty, a.cost)
end

-- The AH's answer (ok: it went through) for the oldest commodity purchase still waiting for one
function Buy:Answer(ok)
    local a
    for pass = 1, 2 do
        for _, x in ipairs(self.attempts) do
            -- (else a late answer for one given up on; a call the game blocked was never sent)
            if x.how == "commodity" and not x.answer and (pass == 2 and GetTime() - x.t <= self.ATTEMPT_TIME and x.outcome ~= "blocked" or not x.settled) then a = x break end
        end
        if a then break end
    end
    self:Log("answer: " .. (ok and "bought" or "failed"), a and a.id, a and a.qty)
    if not a then return end
    a.answer = ok and "ok" or "failed"
    self:Update(a)
end

-- Gold left your bags: the purchase it pays for went through (the one waiting first, then any given
-- up on). Once that gold is counted for one, it doesn't count for another.
function Buy:CheckGold()
    local now = GetMoney and GetMoney()
    if not now then return end
    for pass = 1, 2 do
        for _, a in ipairs(self.attempts) do
            -- (refused or blocked: nothing went through, so later spending is something else)
            if not a.paid and a.gold0 and (a.settled and 2 or 1) == pass and GetTime() - a.t <= self.ATTEMPT_TIME
                and a.outcome ~= "failed" and a.outcome ~= "blocked"
                and now <= a.gold0 - math.max((a.cost or 0) * 0.9, 1) then
                a.paid = true
                for _, o in ipairs(self.attempts) do if o.gold0 and not o.paid then o.gold0 = math.min(o.gold0, now) end end
                self:Update(a)
            end
        end
    end
end

-- What an attempt's answer and gold add up to: bought as soon as either says so; settled once both
-- are in, or when the other takes too long
function Buy:Update(a)
    if (a.answer == "ok" or a.paid) and not a.recorded then
        self:Record(a, a.paid and "gold" or "answer")
        if a.settled then
            self:Say(("|cffffd100%d %s went through after all. It's in your mailbox.|r"):format(a.qty, Name(a.id)))
        end
    end
    if a.settled then return Refresh() end
    if a.answer == "failed" then return self:Settle(a, a.paid and "failed-paid" or "failed") end
    if a.answer == "ok" and a.paid then return self:Settle(a, "bought") end
    if a.paid and a.how == "classic" then return self:Settle(a, "bought") end -- (a classic AH never answers)
    if a.answer == "ok" and not a.waitGold then
        a.waitGold = true
        C_Timer.After(self.GOLD_WAIT, function() PC:Safe("buying", function()
            Buy:CheckGold()
            if not a.settled then Buy:Settle(a, "nogold") end
        end) end)
    elseif a.paid and not a.waitAnswer then
        a.waitAnswer = true
        C_Timer.After(self.ANSWER_WAIT, function() PC:Safe("buying", function()
            if not a.settled then Buy:Settle(a, "noanswer") end
        end) end)
    end
    Refresh()
end

-- No outcome in ANSWER_TIME: one last look at your gold, then it never went through
function Buy:TimeUp(a)
    if a.settled then return end
    self:CheckGold()
    if a.settled then return end
    self:Settle(a, a.recorded and (a.paid and "noanswer" or "nogold") or "lost")
end

Buy.SETTLED = {
    nogold = "|cffffd100The Auction House says you bought %d %s, but no gold was taken. Check your mailbox.|r",
    noanswer = "|cffffd100Paid for %d %s, but the Auction House never answered. Check your mailbox.|r",
    ["failed-paid"] = "|cffffd100The Auction House says buying %d %s failed, but the gold was taken. Check your mailbox before buying more.|r",
    lost = "|cffff8040No answer from the Auction House for %d %s and no gold taken, so it never went through. Click Buy to try again.|r",
}

function Buy:Settle(a, outcome)
    if a.settled then return end
    a.settled, a.outcome = true, outcome
    self:Log("settled: " .. outcome, a.id, a.qty, a.cost)
    local b = a.b
    if b and self.buy == b then self.buy = nil end
    local name = Name(a.id)
    if outcome == "bought" then
        local text = ("Bought %d %s%s. It's in your mailbox."):format(a.qty, name, a.cost and (" for " .. PC:Money(a.cost, false, true)) or "")
        if b then
            -- the AH refused more ("Internal auction error"): this size is what it takes for this item
            if b.refused then
                self.chunkLimit = self.chunkLimit or {}
                self.chunkLimit[b.id] = b.qty
            end
            self:Say("|cff40ff40" .. text .. "|r")
            self:Continue(b)
        else
            PC.Print(text)
        end
    elseif outcome == "lost" and a.auto then
        -- confirmed by itself and nothing happened at all: this game wants a click to confirm
        self:Say(self.SETTLED.lost:format(a.qty, name))
        self:ConfirmNeedsClick()
    elseif outcome == "failed" then
        -- refused: ask again for fewer (it gives up by itself once it's down to 1)
        if b and b.qty > 1 and (b.errors or 0) < 4 and PC.ahOpen then
            local half = math.max(math.floor(b.qty / 2), 1)
            self:Say(("|cffff8040The Auction House refused %d %s. Trying %d.|r"):format(b.qty, name, half))
            C_Timer.After(1.0, function()
                if not Buy.buy and PC.ahOpen then Buy:Start({ id = b.id, name = b.name, qty = half, errors = (b.errors or 0) + 1, refused = b.refused }, b.chain) end
            end)
        else
            self:Say(("|cffff5555Buying %d %s failed. Try again in a moment.|r"):format(a.qty, name))
        end
    else
        self:Say(self.SETTLED[outcome]:format(a.qty, name))
    end
    Refresh()
end

-- After a purchase: the next stack of the same item while the plan still needs more, else (Buy next)
-- the next material. Worked out fresh, so it stops the moment the goal is met.
function Buy:Continue(b)
    local more, _, why = self:Goal(b.id)
    -- bought what still pays: the plan is amended to what buying gets (the AH closed meanwhile or not)
    if more <= 0 and why == "profit" then PC:AmendPlanSoon(b.id) end
    if not PC.ahOpen then return end
    local nextItem = more <= 0 and b.chain and self:NextToBuy(b.id) or nil
    if more > 0 or nextItem then
        C_Timer.After(0.6, function()
            if Buy.buy or not PC.ahOpen then return end
            if more > 0 then Buy:Start({ id = b.id, name = b.name }, b.chain) else Buy:Start(nextItem, true) end
        end)
    elseif PC.Depth and PC.Depth.CheckNow then
        PC.Depth:CheckNow(b.id) -- prices moved: read the listings again
    end
end

-- While a price is coming, a click cancels it (so a button can never get stuck). A purchase already
-- sent can't be taken back: that waits for its outcome.
function Buy:CancelWaiting()
    local b = self.buy
    if not b then return end
    if b.state == "buying" then return self:SayWaiting(b.attempt) end
    self:Cancel()
    self:Say("Cancelled. Click Buy to try again.")
end

-- A material row's Buy button: one click gets the price and buys (or, when the game wants it, a
-- second click confirms)
function Buy:Click(it)
    if not it then return end
    local b = self.buy
    if b and b.id == it.id and b.state == "quoted" then return self:Confirm() end
    if b and b.id == it.id then return self:CancelWaiting() end
    self:Start(it, false, true)
end

-- A buying list ({ id, name, qty }) cut to what keeps its crafts at the minimum profit: AH listings,
-- or (vendor) the vendor's price. Standing at the AH or a vendor, each stop is said once.
Buy.profitStop = {}
function Buy:ProfitList(list, vendor)
    local out = {}
    for _, it in ipairs(list or {}) do
        local v = vendor and self:VendorPrice(it.id)
        local n, _, why = PC:ProfitableBuyQty(it.id, it.qty, v and { { p = v, q = it.qty } } or nil)
        if n > 0 then out[#out + 1] = (n == it.qty) and it or { id = it.id, name = it.name, qty = n } end
        if n < it.qty and why == "profit" then
            if (PC.ahOpen or PC.merchantOpen) and not self.profitStop[it.id] then
                self.profitStop[it.id] = true
                self:SayGoal(it.id, it.name or Name(it.id), n, "profit")
            end
            -- standing where it's sold and none of it pays: the plan is amended to what you have
            if n <= 0 and (PC.ahOpen or PC.merchantOpen) then PC:AmendPlanSoon(it.id) end
        else
            self.profitStop[it.id] = nil
        end
    end
    return out
end

-- The next material the plan still needs from the AH (the list settled at the AH, kept current)
function Buy:NextToBuy(skipID)
    local list = PlanShop()
    if not (list and PC.UI.PlanBuyList) then return nil end
    for _, it in ipairs(self:ProfitList(PC.UI:PlanBuyList(list))) do
        if it.id ~= skipID and it.qty > 0 and self:CanBuy(it.id) then return it end
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN",
    "AUCTION_HOUSE_CLOSED", "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
    "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
    "AUCTION_HOUSE_SHOW_ERROR", "PLAYER_MONEY", "AUCTION_HOUSE_SHOW" }) do
    pcall(ev.RegisterEvent, ev, e)
end
local function Resume(b)
    if b and b.waitingThrottle and (Buy.asked or 0) == 0 then b.waitingThrottle = false; Buy:SendQuote() end
end
ev:SetScript("OnEvent", function(_, event, a1, a2)
    PC:Safe("buying", function()
        local b = Buy.buy
        if event == "AUCTION_HOUSE_SHOW" then
            Buy.chunkLimit = {} -- (what one visit's AH refused says nothing about the next)
            return
        elseif event == "AUCTION_HOUSE_CLOSED" then
            -- (a purchase already sent still settles: it keeps counting as had until then)
            Buy.buy = nil
            Buy.asked, Buy.askedBy = 0, nil
            wipe(Buy.profitStop)
            wipe(Buy.retry)
        elseif event == "COMMODITY_PRICE_UPDATED" then
            local kind = Buy:TakeAnswer()
            if kind == "mine" then
                b.unit, b.total = a1, a2
                b.state, b.quotedAt = "quoted", GetTime()
                -- one click: the price passed every check, so it's bought now
                if Buy:CheckQuote(b) and b.auto and Buy:AutoConfirm() and Buy.buy == b then
                    b.autoConfirm = true
                    Buy:Confirm()
                end
            elseif kind == "push" and b and b.state == "quoted" then
                -- the AH repriced its held quote: the click would pay the new price, so it's checked again
                b.unit, b.total, b.quotedAt = a1, a2, GetTime()
                Buy:CheckQuote(b)
            else
                Resume(b)
            end
        elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
            -- the game stopped one of ours: confirming wants a click, or asking the price did
            if a1 ~= ADDON or type(a2) ~= "string" then return end
            if a2:find("ConfirmCommoditiesPurchase", 1, true) then
                Buy.blockedAt = GetTime()
                Buy:ConfirmNeedsClick(b)
            elseif a2:find("StartCommoditiesPurchase", 1, true) and b and b.state == "quoting" then
                -- (counted already if this came after the call: nothing was sent)
                if Buy.askedBy == b then Buy.asked, Buy.askedBy = math.max((Buy.asked or 0) - 1, 0), nil end
                -- a smaller retry keeps its amount for the next click
                if (b.errors or 0) > 0 then Buy.retry[b.id] = { qty = b.qty, errors = b.errors, refused = b.refused } end
                Buy.buy = nil
                Buy:Say("|cffff8040The game wants a click to get the Auction House's price. Click Buy or the Task Button.|r")
            end
            return
        elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
            Resume(b)
            return
        elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
            -- the AH's own error ("Internal auction error"): a price request is asked again smaller
            if b then Buy:OnAuctionError() end
            return
        elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
            local kind = Buy:TakeAnswer()
            if b and (kind == "mine" or (kind == "push" and b.state == "quoted")) then
                -- not that many for sale at once: ask for fewer
                if b.qty > 1 and Buy:OnAuctionError(true) then return end
                Buy.buy = nil
                return Buy:Say("|cffff5555Not enough " .. b.name .. " for sale right now. Buy fewer or try later.|r")
            end
            Resume(b)
        elseif event == "PLAYER_MONEY" then
            -- the gold for a purchase left your bags: it went through, even with no answer from the AH
            Buy:CheckGold()
            return
        elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
            Buy:Answer(true)
        elseif event == "COMMODITY_PURCHASE_FAILED" then
            Buy:Answer(false)
        end
        Refresh()
    end)
end)

---------------------------------------------------------------------------
-- Buying from a vendor (while a merchant window is open)
--   One purchase at a time: each is sent, then waited for until it's in your bags and the gold has
--   gone, before the next. Before each one everything is checked again: the vendor still open and
--   selling it, still needed (worked out now), your gold, bag room, the minimum profit. A purchase
--   that doesn't arrive in time, the game's refusal (no gold, bags full, sold out) or the vendor
--   closing stops it and says exactly what arrived; nothing is bought again by itself.
---------------------------------------------------------------------------
local VB = {}
PC.VendorBuy = VB
VB.WAIT = 8   -- seconds a purchase may take to reach your bags before buying stops
VB.LATE = 30  -- ...and until then it's still watched for (nothing else is sent meanwhile)

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

-- the most one purchase can be: the vendor's max stack, in whole bundles
function VB:PerPurchase(i, batch, itemID)
    batch = math.max(batch or 1, 1)
    local maxStack = math.max((GetMerchantItemMaxStack and GetMerchantItemMaxStack(i)) or 1, 1)
    -- this game says 1 (or nothing) for things that stack: a full stack is what a vendor sells at once
    -- (26 vials used to be 26 purchases)
    if itemID then maxStack = math.max(maxStack, PC:StackSize(itemID) or 1) end
    return math.max(math.floor(maxStack / batch) * batch, batch)
end

-- The queue: one job per item, { id, name, want, got, spent, group }, bought in order. A group is
-- one call (Buy or BuyAll): { bought = {}, failed = {}, left, quiet, onDone }.
VB.queue = {}
VB.wait = nil -- the purchase sent and not in your bags yet: { job, id, n, cost, bags0, money, paid, t, late }

-- how many of an item are still to come: queued, plus the purchase on its way to your bags
function VB:Pending(itemID)
    local n = 0
    for _, j in ipairs(self.queue) do
        if j.id == itemID then n = n + math.max(j.want - j.got, 0) end
    end
    local w = self.wait
    if w and w.late and w.id == itemID then n = n + w.n - w.counted end
    return n
end

function VB:Busy() return self.queue[1] ~= nil or self.wait ~= nil end
function VB:Queued(itemID)
    for _, j in ipairs(self.queue) do if j.id == itemID then return true end end
    return false
end

-- What the plan still needs of an item from vendors, worked out now (nil: not a plan material).
-- (bag room is checked on its own, purchase by purchase)
function VB:PlanNeed(itemID)
    local list = PlanShop()
    if not (list and PC.UI.VendorQty) then return nil end
    for _, it in ipairs(list) do
        if it.id == itemID and not it.tool then return PC.UI:VendorQty(it) end
    end
end

-- The next purchase of a job, everything checked again: how many (0 = this job is over), why it
-- stops (nil = nothing left to buy), the merchant slot and what it costs
function VB:NextQty(j)
    if not self:Open() then return 0, "the vendor closed" end
    local i = self:Find(j.id)
    if not i then return 0, "the vendor doesn't sell it now" end
    local price, batch, avail = MerchantInfo(i)
    batch = math.max(batch or 1, 1)
    local left = j.want - j.got
    if left <= 0 then return 0 end
    local need = self:PlanNeed(j.id)
    -- (bought for the plan and the plan no longer lists it: it has all it needs)
    if j.plan and not need then need = 0 end
    if need and need < left then
        left = need
        if left <= 0 then return 0, j.got == 0 and "your plan has all it needs" or nil end
    end
    left = math.ceil(left / batch) * batch -- whole bundles: the vendor sells them in its 5s
    local n = math.min(left, self:PerPurchase(i, batch, j.id))
    if avail and avail > 0 then n = math.min(n, avail * batch) end
    local q, _, why = PC:ProfitableBuyQty(j.id, n, { { p = price / batch, q = n } })
    if why == "profit" and q < n then
        n = math.floor(q / batch) * batch
        if n <= 0 then return 0, "profit" end
    end
    n = math.min(n, math.floor(PC:FitsQty(j.id, n, PC.BUY_RESERVE) / batch) * batch)
    if n <= 0 then return 0, "your bags are full" end
    n = math.min(n, math.floor(PC:Gold() / price) * batch)
    if n <= 0 then return 0, "not enough gold" end
    return n, nil, i, n / batch * price
end

-- Send the next purchase (one at a time: nothing while one is on its way)
function VB:Next()
    while not self.wait and self.queue[1] do
        local j = self.queue[1]
        local n, why, i, cost = self:NextQty(j)
        if n <= 0 then
            if why == "profit" then PC:AmendPlanSoon(j.id) end
            self:Finish(j, why)
        else
            local w = { job = j, id = j.id, n = n, cost = cost, bags0 = PC:BagCount(j.id), money = GetMoney(), paid = 0,
                counted = 0, t = GetTime() }
            self.wait = w
            local ok, err = pcall(BuyMerchantItem, i, n)
            if not ok then
                self.wait = nil
                self:Finish(j, "couldn't buy it (" .. tostring(err) .. ")")
            else
                C_Timer.After(self.WAIT, function() PC:Safe("vendor buy", VB.TimeUp, VB, w) end)
            end
        end
    end
end

-- Is the purchase on its way in your bags yet, and the gold gone?
function VB:Check()
    local w = self.wait
    if not w then return end
    local money = GetMoney()
    if money < w.money then w.paid = w.paid + (w.money - money) end -- (gold coming in meanwhile can't hide it)
    w.money = money
    local got = math.min(math.max(PC:BagCount(w.id) - w.bags0, 0), w.n)
    if got < w.n or w.paid < w.cost * 0.9 then return end
    self.wait = nil
    if w.late then
        -- given up on, but it came after all
        local n = w.n - w.counted
        local spent = math.floor(w.cost * n / w.n + 0.5)
        PC:Record("buy", spent, PC:ItemName(w.id), n)
        PC:NotePaid(w.id, n, spent)
        Buy:Say(("|cffffd100%d %s from the vendor arrived after all.|r"):format(n, PC:ItemName(w.id) or ""))
    else
        w.job.got, w.job.spent = w.job.got + w.n, w.job.spent + w.cost
    end
    self:Next()
    Refresh()
end

-- Stop: what arrived of the purchase on its way counts, the rest of the queue is over (said why)
function VB:Stop(w, why, all)
    local j = w.job
    local got = math.min(math.max(PC:BagCount(w.id) - w.bags0, 0), w.n)
    w.counted = got
    j.got, j.spent = j.got + got, j.spent + math.floor(w.cost * got / w.n + 0.5)
    self:Finish(j, why)
    if all then
        local rest = {}
        for _, x in ipairs(self.queue) do rest[#rest + 1] = x end
        for _, x in ipairs(rest) do self:Finish(x, "stopped (" .. why .. ")") end
    end
end

-- Not in your bags in time: stop everything and say what arrived (still watched for a while)
function VB:TimeUp(w)
    if self.wait ~= w or w.late then return end
    self:Check()
    if self.wait ~= w then return end
    w.late = true
    self:Stop(w, self:Open() and "it didn't arrive in time" or "the vendor closed before it arrived", true)
    C_Timer.After(self.LATE - self.WAIT, function()
        if VB.wait == w then VB.wait = nil; PC:Safe("vendor buy", VB.Next, VB) end
    end)
end

-- The game's refusal (no gold, bags full, sold out): nothing arrives; stop and say so
VB.ERRORS = {
    { "ERR_NOT_ENOUGH_MONEY", "enough money", "not enough gold", true },
    { "ERR_INV_FULL", "inventory is full", "your bags are full", true },
    { "ERR_BAG_FULL", "bag is full", "your bags are full", true },
    { "ERR_ITEM_MAX_COUNT", "carry any more", "you can't carry any more" },
    { "ERR_VENDOR_SOLD_OUT", "sold out", "sold out" },
    { "ERR_ITEM_NOT_AVAILABLE", "not available", "sold out" },
}
function VB:OnError(msg)
    local w = self.wait
    if not w or w.late or type(msg) ~= "string" then return end
    local m = msg:lower()
    for _, e in ipairs(self.ERRORS) do
        if msg == _G[e[1]] or m:find(e[2], 1, true) then
            self.wait = nil
            self:Stop(w, e[3], e[4])
            self:Next()
            return Refresh()
        end
    end
end

-- The vendor closed: nothing more is sent (what's on its way is still waited for)
function VB:Closed()
    local rest = {}
    for _, j in ipairs(self.queue) do if not (self.wait and self.wait.job == j) then rest[#rest + 1] = j end end
    for _, j in ipairs(rest) do self:Finish(j, "the vendor closed") end
end

-- A job is over: what arrived is recorded, and its group is told (onDone once all its jobs are over)
function VB:Finish(j, why)
    for k, x in ipairs(self.queue) do if x == j then table.remove(self.queue, k) break end end
    j.over = true
    local g = j.group
    if j.got > 0 then
        PC:Record("buy", j.spent, j.name, j.got) -- vendor buys count in Profit & loss too
        PC:NotePaid(j.id, j.got, j.spent)
        g.bought[#g.bought + 1] = { id = j.id, name = j.name, qty = j.got, spent = j.spent }
    end
    if why then g.failed[#g.failed + 1] = { id = j.id, name = j.name, want = j.want, got = j.got, why = why } end
    self:Release(g)
end

-- One less job (or the call itself done adding them): the summary once nothing's left
function VB:Release(g)
    g.left = g.left - 1
    if g.left > 0 then return end
    local spent, parts, lines = 0, {}, {}
    for _, b in ipairs(g.bought) do spent = spent + b.spent; parts[#parts + 1] = b.qty .. " " .. b.name end
    if #parts > 0 and not g.quiet then
        Buy:Say(("|cff40ff40Bought %s from the vendor for %s.|r"):format(table.concat(parts, ", "), PC:Money(spent, false, true)))
    end
    for _, f in ipairs(g.failed) do
        lines[#lines + 1] = (f.why == "profit")
            and ("Stopped buying %s: more would drop the craft under %d%% profit."):format(f.name, PC:MinProfitPct())
            or ("Bought %d of %d %s: %s."):format(f.got, f.want, f.name, f.why)
    end
    -- (failures are always said, unless the caller says them itself)
    if #lines > 0 and not (g.quiet and g.onDone) then Buy:Say("|cffff8040" .. table.concat(lines, " ") .. "|r") end
    if g.onDone then PC:Safe("vendor buy", g.onDone, { bought = g.bought, failed = g.failed }) end
    Refresh()
end

-- Queue an item for a call (one job per item: one already queued isn't queued twice). plan: bought for
-- the plan, so never more than the plan still needs (checked now, and again before every purchase)
function VB:Add(g, itemID, qty, plan)
    if not qty or qty <= 0 then return end
    local j = { id = itemID, name = PC:ItemName(itemID) or "that item", want = qty, got = 0, spent = 0, group = g, plan = plan }
    g.left = g.left + 1
    if self:Queued(itemID) then return self:Finish(j, "already being bought") end
    if plan then
        local need = self:PlanNeed(itemID) or 0
        if need < j.want then j.want = need end
        if j.want <= 0 then return self:Finish(j, "your plan has all it needs") end
    end
    self.queue[#self.queue + 1] = j
    return j
end

-- Buy qty of an item from the open vendor; onDone(summary) once it's over, summary =
-- { bought = { {id, name, qty, spent}, ... }, failed = { {id, name, want, got, why}, ... } }.
-- Returns how many it set out to buy (0 = none: said why) and about what they cost.
function VB:Buy(itemID, qty, quiet, onDone, plan)
    local g = { bought = {}, failed = {}, left = 1, quiet = quiet, onDone = onDone }
    local j = self:Add(g, itemID, qty, plan)
    qty = j and j.want or qty
    local cost = 0
    if j then
        local i = self:Find(itemID)
        if i then
            local price, batch = MerchantInfo(i)
            cost = math.ceil(qty / math.max(batch or 1, 1)) * price
        end
        if not quiet then Buy:Say(("|cffffd100Buying %d %s from the vendor...|r"):format(qty, j.name)) end
    end
    self:Next()
    local n = (j and (not j.over or j.got > 0)) and qty or 0
    self:Release(g)
    return n, cost
end

-- Everything the plan needs from vendors that this vendor sells (anything already on its way left
-- out), and only what keeps its craft at the minimum profit: { id, name, qty }
function VB:PlanList()
    local shop = PlanShop()
    local list = (shop and PC.UI.PlanVendorList) and PC.UI:PlanVendorList(shop) or {}
    local out = {}
    for _, it in ipairs(list) do
        local left = it.qty - self:Pending(it.id) -- already on its way: not bought twice
        local i = left > 0 and self:Find(it.id)
        if i then
            local price, batch = MerchantInfo(i)
            left = PC:ProfitableBuyQty(it.id, left, { { p = price / math.max(batch or 1, 1), q = left } })
            if left > 0 then out[#out + 1] = { id = it.id, name = it.name, qty = left } end
        end
    end
    return out
end

-- Everything the plan needs from this vendor, one purchase at a time; onDone(summary) once it's over
function VB:BuyAll(quiet, onDone)
    local list = self:PlanList()
    local g = { bought = {}, failed = {}, left = 1, quiet = quiet, onDone = onDone }
    if #list == 0 and not quiet then
        Buy:Say((self:Busy() and "|cffffd100Already buying from this vendor.|r")
            or (PC:FreeBagSlotsOnly() <= (PC.BUY_RESERVE or 1) and "|cffff5555Your bags are full: make room first.|r")
            or "This vendor doesn't sell anything your plan still needs.")
    end
    local n = 0
    for _, it in ipairs(list) do
        if not self:Queued(it.id) and self:Add(g, it.id, it.qty, true) then n = n + 1 end
    end
    if n > 0 and not quiet then
        Buy:Say(("|cffffd100Buying %d material%s from the vendor...|r"):format(n, n == 1 and "" or "s"))
    end
    self:Next()
    self:Release(g)
    return n
end

local mev = CreateFrame("Frame")
for _, e in ipairs({ "MERCHANT_UPDATE", "MERCHANT_CLOSED", "BAG_UPDATE_DELAYED", "PLAYER_MONEY", "UI_ERROR_MESSAGE" }) do
    pcall(mev.RegisterEvent, mev, e)
end
mev:SetScript("OnEvent", function(_, event, a1, a2)
    PC:Safe("vendor buy", function()
        if event == "UI_ERROR_MESSAGE" then
            local msg = type(a2) == "string" and a2 or a1
            if not PC.IsSecret(msg) then VB:OnError(msg) end
            return
        elseif event == "MERCHANT_CLOSED" then
            wipe(Buy.profitStop)
            return VB:Closed()
        end
        VB:Check()
        if event == "MERCHANT_UPDATE" and PC.merchantOpen then PC:RefreshUI() end
    end)
end)

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

-- the most to pay for one: under a vendor's price, and not far over the usual price
function Buy:Cap(itemID)
    local v, p = self:VendorPrice(itemID), PC:Price(itemID)
    local cap = p and p * self.PRICE_WARN or nil
    if v then cap = math.min(cap or math.huge, v) end
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

-- the next listing worth buying: cheapest first, within the price cap (under a vendor's price), and
-- never more than wanted (a listing can't be split)
function Buy:NextListing(it, room)
    local res = self.itemResults[it.id]
    if not res then return nil end
    local cap, v = self:Cap(it.id), self:VendorPrice(it.id)
    room = room or it.qty or 1
    for i, r in ipairs(res.list) do
        if (not cap or r.unit <= cap) and (not v or r.unit < v) and r.qty <= room then return r, i, cap end
    end
    return nil, nil, cap
end

function Buy:BuyListing(it)
    if not PC.ahOpen then return self:Say("|cffff8040Open the Auction House first.|r") end
    local waiting = self:Unsettled()
    if waiting then return self:SayWaiting(waiting) end
    if PC.UI and PC.UI.StaleScan and not PC.UI.StaleScan:Check() then return end
    if not self:HasListings(it.id) then return self:SearchAH(it) end
    local name = it.name or Name(it.id)
    -- how many: worked out now, never more than the plan still needs
    local goal, _, why = self:Goal(it.id, it.qty)
    if goal <= 0 then return self:SayGoal(it.id, name, 0, why) end
    local r, i, cap = self:NextListing(it, goal)
    if not r then
        self.itemResults[it.id] = nil
        return self:Say(("|cffff8040No %s listed under %s each (in lots of %d or fewer) right now.|r"):format(name,
            cap and PC:Money(cap, false, true) or "a fair price", goal))
    end
    local money = GetMoney and GetMoney() or 0
    if money < r.buyout then
        return self:Say(("|cffff8040Not enough gold: %d %s costs %s.|r"):format(r.qty, name, PC:Money(r.buyout, false, true)))
    end
    table.remove(self.itemResults[it.id].list, i)
    local ok, err = pcall(C_AuctionHouse.PlaceBid, r.auctionID, r.buyout)
    if not ok then return self:Say("|cffff5555Couldn't buy it: " .. tostring(err) .. "|r") end
    -- (noted by the hook on the game's function; here too in case it didn't run)
    local noted = false
    for _, a in ipairs(self.attempts) do if a.auctionID == r.auctionID and not a.settled then noted = true end end
    if not noted then self:Attempt(it.id, r.qty, r.buyout, "listing", r.auctionID) end
    self:Say(("Buying %d %s for %s..."):format(r.qty, name, PC:Money(r.buyout, false, true)))
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
                -- a separate auction bought (it says which): that attempt's answer
                local a
                for _, x in ipairs(Buy.attempts) do if x.auctionID == a1 and not x.answer then a = x break end end
                local seen = Buy.seenAuction[a1]
                if not a and seen then a = Buy:Attempt(seen.id, seen.qty, seen.cost, "listing", a1) end
                Buy.seenAuction[a1] = nil
                if a then a.answer = "ok"; Buy:Update(a) end
            end
            Refresh()
        end)
    end)
    -- every purchase sent to the AH, by ProfitCrafter or by hand: noted so it's counted when it goes through
    if hooksecurefunc and C_AuctionHouse then
        if C_AuctionHouse.ConfirmCommoditiesPurchase then
            hooksecurefunc(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(id, q)
                PC:Safe("buying", function()
                    if Buy.blockedAt == GetTime() then return end -- (the game blocked this very call: nothing was sent)
                    local b = Buy.buy
                    local ours = b and b.id == id and b.state == "buying" and not b.attempt
                    local a = Buy:Attempt(id, q, (ours and b.total) or PC:CostForQty(id, q or 1), "commodity")
                    if ours and a then b.attempt, a.b = a, b end
                end)
            end)
        end
        if C_AuctionHouse.PlaceBid then
            hooksecurefunc(C_AuctionHouse, "PlaceBid", function(auctionID, amount)
                PC:Safe("buying", function()
                    local a = Buy.seenAuction[auctionID]
                    if a then Buy:Attempt(a.id, a.qty, amount or a.cost, "listing", auctionID) end
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
