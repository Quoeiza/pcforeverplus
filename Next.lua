-- ProfitCrafter: Next step (the Task Button) and the floating bar

local ADDON, ns = ...
local PC = ns.PC

local function Safe(name, fn, ...) return PC:Safe(name, fn, ...) end
local On = PC.AutoOn
local Bags = PC.BagSlots
local UseBagItem = PC.UseBagItem
local Sell = PC.Sell
local Craft = PC.Craft
local Undercut = PC.Undercut

local Next = {}
PC.Next = Next

-- Returns { text, run (function or nil), left (steps still to do) }
-- The step, plus the quickest way to get there when it sends you somewhere
function Next:Compute()
    -- once per refresh: the bar, the tasks list and the disenchant button all ask for it
    local memo = PC:Memo()
    if memo and memo.step then return memo.step end
    -- SnuggleUp's guide is the running plan: the button shows its step (only one plan runs at a time)
    local G = PC.Guide
    if G and G.On and G:On() then
        G:Sync()
        if G:Active() then
            local s = G:Step()
            -- in a city, greens waiting to be disenchanted come first, even while the guide is the plan
            if self.Town and self:Town() then
                local ok, de = pcall(self.DisenchantStep, self, s)
                if ok and de then s = de
                else
                    -- and so does selling what an earlier plan made and left in your bags
                    local left = false
                    local okI, items = pcall(Sell.Items, Sell)
                    for _, it in ipairs(okI and items or {}) do
                        if (it.sellN or 0) > 0 and (it.vendor or (it.price and not it.hold)) then left = true break end
                    end
                    if left then
                        local okR, r = pcall(self.ComputeRaw, self)
                        if okR and r and r.text and r.text ~= "Set up a plan" and r.text ~= "All done!" then s = r; s.leftover = true end
                    end
                end
            end
            if memo then memo.step = s end
            return s
        end
    end
    -- on a flight: just where it's going; nothing is re-planned until you land
    local flying, why = PC.Travel and PC.Travel.FlightText and PC.Travel:FlightText()
    if flying then
        local s = { text = flying, tip = why, cat = "Travel", flying = true }
        -- no plan and no recipe trip: a flight is nothing to show
        local UI = PC.UI
        local work = (UI and UI.PlanEntries and #UI:PlanEntries() > 0)
            or (PC.ToLearn and PC.ToLearn.Data and #(PC.ToLearn.Data().trip or {}) > 0)
        if not work then s.quiet = true end
        if memo then memo.step = s end
        return s
    end
    local s = self:ComputeRaw()
    if memo then memo.step = s end
    return s
end
-- Greens waiting to be disenchanted (made for their dust, or more than the AH will take): the step
-- for the first one, or nil. `s` is the step it would replace.
function Next:DisenchantStep(s)
    local crafting = Craft.quick and Craft.quick.started
    if not PC.Synergy or crafting or (InCombatLockdown and InCombatLockdown()) then return nil end
    if PC.Synergy.QueueExtras then pcall(PC.Synergy.QueueExtras, PC.Synergy) end
    local list = PC.Synergy:ToDisenchant()
    if #list == 0 then return nil end
    local idle = not s or s.text == "Set up a plan" or s.text == "All done!" or (s.text or ""):find("^Waiting")
    -- a window you're standing at (AH, vendor, bank, mailbox) goes first; otherwise the greens do
    -- (a profession window open doesn't count: disenchanting works with it open)
    local function open(name) local f = _G[name]; return f and f.IsShown and f:IsShown() end
    local busy = open("AuctionHouseFrame") or open("AuctionFrame") or open("MerchantFrame") or open("BankFrame")
        or open("MailFrame")
    if not (idle or not busy) then return nil end
    local it = list[1]
    return { text = ("Disenchant %s"):format(it.name), cat = "Craft", deItem = it,
        items = { ("disenchant %s (%d to go)"):format(it.name, #list) },
        tip = (PC.Synergy:Describe(it.id) or "") .. "\nMade for its dust: the button casts Disenchant on it." }
end

-- One craft step for every place that offers one: where the recipe needs a fire, forge or anvil
-- and you aren't at one, the step is to walk to it instead. (It used to offer the craft and only
-- mention the fire once you pressed the button.)
function Next:CraftStep(s, e, n, tip)
    local station, near = Craft:Station(e)
    if station and near == false then
        local P = PC.Places
        local p = P and P:Nearest("station", nil, station)
        local T = PC.Travel
        local yd = (p and T) and T:Yards(T:Here(), p) or nil
        s.text = p and (("Walk to the %s%s"):format(station, yd and (" (%d yd)"):format(math.floor(yd)) or ""))
            or ("Find a " .. station)
        s.tip = ("%s needs a %s. "):format(e.r.name, station) ..
            (p and P:Describe(p) or "ProfitCrafter learns where they are when you craft next to one.")
        s.dest = p
        s.run = nil
        return s
    end
    s.text = "Craft " .. PC:CraftCount(n, e.r)
    s.tip = tip
    s.run = function() Craft:Quick(e, n) end
    return s
end

function Next:ComputeRaw()
    local mark = PC.PerfMark and PC:PerfMark("n_") or function() end -- (timing each part, to find the slow one)
    local s = self:ComputeStep()
    mark("step")
    -- greens made for their dust: disenchant them (a secure click on the button casts it), unless
    -- there's something to do right where you stand
    local crafting = Craft.quick and Craft.quick.started
    local de = self:DisenchantStep(s)
    mark("de")
    if de then return de end
    -- gear made on a Gear upgrades plan, crafted and in your bags: put it on (right where you stand)
    if PC.UI and PC.UI.EquipList and not crafting and not (InCombatLockdown and InCombatLockdown()) then
        local list = PC.UI:EquipList()
        local u = list[1]
        if u then
            local what = u.old and ((u.kind == "upgrade" and "Beats your %s." or "About the same as your %s: your call."):format(u.old)) or "Nothing worn there now."
            return { text = ("Put on %s"):format(u.name), cat = "Equip",
                items = { ("put on %s%s"):format(u.name, #list > 1 and (" (%d to go)"):format(#list) or "") },
                tip = what,
                run = function() PC.UI:Equip(u) end,
                skip = function() PC.UI:DontEquip(u.id) end,
                skipTip = "Keep what you're wearing: this one is sold like anything else." }
        end
    end
    -- any mailbox step can be skipped for an hour
    if s and not s.skip and PC.Mail and ((s.text or ""):find("mailbox") or s.text == "Collect auction mail") then
        s.skip = function() PC.Mail:Snooze() end
        s.skipTip = "Not now: I'll remind you about the mail again in an hour."
    end
    mark("equip")
    -- a recipe trip (Learn tab): it takes over, unless there's something to do right where you stand
    if PC.ToLearn then
        local ok, trip = pcall(PC.ToLearn.Step, PC.ToLearn)
        local idle = not s or s.text == "Set up a plan" or s.text == "All done!" or (s.text or ""):find("^Waiting")
        if ok and trip and (idle or not (s.run and not self:IsTravel(s))) then s = trip end
    end
    -- "Plan my route for me" off: no travel or directions, just what to do
    if s and not PC:RouteOn() and s.dest and not s.run then
        if s.simple then s.text = s.simple
        else
            -- no plain wording of its own: the first thing to do on the tasks list (no who or where)
            for _, st in ipairs(PC.Steps and PC.Steps.list or {}) do
                if st.cat ~= "Travel" and st.cat ~= "Done" and not st.skipped then
                    s.text = st.plain and st.text or PC.Steps:Simple(st)
                    break
                end
            end
        end
        s.dest, s.pin, s.via, s.way = nil, nil, nil, nil
        s.tip = nil
        return s
    end
    mark("tolearn")
    if s and s.dest and PC.Travel and PC:RouteOn() and not PC.Travel:AtPlace(s.dest) then
        local ok, way = pcall(PC.Travel.BestWay, PC.Travel, s.dest)
        if ok and way and way.steps and #way.steps > 0 then
            s.way = way
            local leg = way.steps[1]
            -- one walk straight to the stop: the task itself says it (and the pin is the stop); anything
            -- more (a flight, a boat, the elevator, another zone): the button says the leg you're on
            local direct = #way.steps == 1 and leg.how == "walk" and leg.to == nil
            if #way.steps == 1 and leg.how == "walk" and leg.to and leg.to.map == s.dest.map and leg.to.x == s.dest.x
                and leg.to.y == s.dest.y then direct = true end
            if not direct and not s.run then
                local lines = { PC.Travel:Describe(way) }
                if s.text and s.text ~= "" then lines[#lines + 1] = "Then: " .. s.text end
                s.tip = table.concat(lines, "\n") .. (s.tip and ("\n" .. s.tip) or "")
                s.forText = s.text
                s.text, s.label = leg.text, leg.label
                s.pin = way.first
                if leg.how == "hearth" then
                    -- the click uses it (a real click on the game's own item button). With a vendor,
                    -- bank or mailbox open it would be sold or put away: that window is closed first.
                    local hb
                    for _, sl in ipairs(PC.BagSlots and PC.BagSlots() or {}) do
                        if sl.id == PC.Travel.HEARTH_ITEM then hb = sl break end
                    end
                    local function shown(n) local fr = _G[n]; return fr and fr.IsShown and fr:IsShown() end
                    local close
                    if PC.merchantOpen or shown("MerchantFrame") then close = CloseMerchant
                    elseif (PC.Bank and PC.Bank.open) or shown("BankFrame") then close = CloseBankFrame
                    elseif (PC.Mail and PC.Mail.open) or shown("MailFrame") then close = CloseMail end
                    if hb and close then
                        s.text, s.label = "Close this window, then Hearthstone", "Close this window first"
                        s.run = function() pcall(close); C_Timer.After(0.3, function() PC:RefreshUI() end) end
                    elseif hb then
                        s.useItem = { use = true, bag = hb.bag, slot = hb.slot, id = hb.id, name = "your Hearthstone", hearth = true }
                    end
                end
            end
        end
    end
    return s
end

function Next:ComputeStep()
    local UI = PC.UI
    if not UI or not PC.cdb then return { text = "" } end
    local mark = PC.PerfMark and PC:PerfMark("s_") or function() end
    if not UI.allEntries then UI.allEntries = PC:Analyze() end
    local B, VB = PC.Buy, PC.VendorBuy
    local entries = UI:PlanEntries()
    mark("entries")
    -- no plan loaded: ProfitCrafter has nothing to do, so it does nothing (no selling, no trips, no
    -- Task Button). A plan whose crafts are all done still has a job until what it made is sold (a
    -- Make me gold plan empties out as you craft), so that counts as loaded.
    if #entries == 0 and next(PC:CurrentPlan() or {}) == nil and not PC:PlanGoodsLeft() then
        return { text = "Set up a plan", tip = "Opens ProfitCrafter on the plan tab. Make me gold fills it for you.",
            run = function() if PC.UI then PC.UI:Create(); PC.UI.f:Show(); PC.UI:ShowTab(2) end end }
    end
    -- buy only for what will be crafted now (the market's share), not the whole plan; standing at a
    -- vendor or the auction house this is settled on arrival and only checked off as you buy
    local buyEntries, list = PC:StopShopList(entries, 1)
    mark("shop")
    local ahList = UI:PlanBuyList(list)
    local vendorList = UI:PlanVendorList(list)
    mark("lists")
    -- purging clears bag space: buying waits until it's done
    if Sell.purge then ahList, vendorList = {}, {} end
    -- only what keeps its craft at the minimum profit (a stop is said once, at the AH or vendor)
    ahList, vendorList = B:ProfitList(ahList), B:ProfitList(vendorList, true)
    if Sell.purge and #Sell:PurgeList() == 0 then Sell.purge = nil; PC.Buy:Say("|cff40ff40Purge done: nothing left to purge.|r") end
    local sell, vsell = {}, {} -- crafted goods for the AH / for a vendor (whichever pays more)
    for _, it in ipairs(Sell:Items()) do
        if it.sellN > 0 and it.vendor then vsell[#vsell + 1] = it
        elseif it.sellN > 0 and it.price and not it.hold then sell[#sell + 1] = it end
    end
    mark("sell")
    -- the trip to the AH to sell was skipped: not for an hour (standing at the AH, it still posts)
    if PC:SellSnoozed() and not PC.ahOpen then sell = {} end
    -- crafts still to do with materials already in your bags (profession window open or not)
    Craft.blocked, Craft.noRoom = {}, nil
    local craft = {}
    for _, e in ipairs(UI:SubCrafts(list)) do
        if Craft:Count(e) > 0 then craft[#craft + 1] = e end
    end
    for _, e in ipairs(entries) do
        if Craft:Count(e) > 0 then craft[#craft + 1] = e end
    end
    mark("crafts")
    -- materials you make yourself (bolts) first, then things that stack (potions, food, cloth):
    -- crafting them frees bag slots for the gear
    table.sort(craft, function(a, b)
        if (a.sub or false) ~= (b.sub or false) then return a.sub and true or false end
        local sa, sb = PC:StackSize(a.outID or a.r.output), PC:StackSize(b.outID or b.r.output)
        if sa ~= sb then return sa > sb end
        return (a.r.name or "") < (b.r.name or "")
    end)
    -- bag room: is there plan stuff still to buy, does a batch of it fit, and is the crafting done
    local laterNow = PC:LaterMats(list)
    local rawBuy = false
    for _, it in ipairs(list) do if it.buy and it.buy > 0 and not laterNow[it.id] then rawBuy = true end end
    local scale = PC:BatchScale(list, laterNow)
    if PC.Bank then
        PC.Bank.craftingDone = not rawBuy and #craft == 0
        -- "Store unused items": asked for when the bags are short of room for the plan (skippable)
        -- (really short: the materials to buy don't fit, or the bags are nearly full - not just "the whole
        -- plan's finished items wouldn't fit at once": those get sold as you go)
        local short = PC:BatchScale(list, laterNow, true) < 1 or PC:FreeBagSlotsOnly() < (PC.Bank.BAG_RESERVE or 6)
        PC.Bank.unusedWanted = #entries > 0 and short and not PC.Bank:UnusedSkipped() and PC.Bank:Known() and true or false
    end
    -- craft what your bags already hold before fetching more from the bank (no refilling full bags)
    -- (when bags are tight: with plenty of room, taking the rest out first makes fewer trips)
    if PC.Bank then PC.Bank.craftFirst = #craft > 0 and PC:FreeBagSlotsOnly() < (PC.Bank.BAG_RESERVE or 6) end
    local mailN = 0
    mailN = PC:MailTrips()
    -- the game's own "you have mail" flag (the envelope by the minimap) counts too
    if PC.Mail and PC.Mail:HasNew() then mailN = mailN + 1 end
    -- skipped the mailbox: not again for an hour
    local mailSnoozed = PC.Mail and PC.Mail:Snoozed()
    -- items still in the mail but your bags are full: deal with your bags first (sell, post, store),
    -- then come back for them. Gold from sales needs no room, so that's still worth the trip.
    if PC.Mail and PC.Mail.itemsWaiting and PC.Mail.itemsWaiting > 0 then
        if PC:FreeBagSlotsOnly() > (PC.BUY_RESERVE or 1) then mailN = mailN + 1 end
    end
    -- bags full: no trip for items (AH purchases, returns) - only when there's gold to collect
    if mailN > 0 and PC:FreeBagSlotsOnly() <= (PC.BUY_RESERVE or 1) and PC.Mail and not PC.Mail:HasMoney()
        and not (PC.Mail.arrived and PC.Mail.lastVisit and PC.Mail.arrived > PC.Mail.lastVisit) then mailN = 0 end
    if mailSnoozed and not (PC.Mail and PC.Mail:Open()) then mailN = 0 end
    -- out questing: no mail trips (only in a city, with a mailbox right there)
    local town = Next:Town()
    local planWork = #entries > 0
    mailN = 0 -- the mailbox is a stop only when the plan needs what's in it (below)
    -- materials your plan needs are waiting in the mail (AH purchases): that's the plan, not a chore, so
    -- the mailbox is a stop wherever it is (the plan can't go on without them)
    local planMail = Next:PlanMailWaiting(entries)
    if #planMail > 0 and mailN == 0 and not mailSnoozed and PC:FreeBagSlotsOnly() > (PC.BUY_RESERVE or 1) then mailN = 1 end
    -- standing at the open mailbox: either there's AH mail to take (collect it here), or there's none
    -- and the mailbox is done - never "Go to the mailbox" while you're at it
    if PC.Mail and PC.Mail:Open() then
        if PC.Mail:Count() == 0 then
            mailN = 0
            if not PC.Mail.busy and PC.cdb then PC:MailEmptied(); PC.Mail.itemsWaiting = nil end
        elseif not PC.Mail.busy and (PC.Mail:HasMoney() or PC:FreeBagSlotsOnly() > (PC.BUY_RESERVE or 1)) then
            -- (bags full and only items left: nothing to take now - that's handled below, no loop)
            local M = PC.Mail
            local s0 = { text = "Collect auction mail", cat = "Mail", tip = ("%d auction mail%s to take: purchases, sales gold, returns."):format(M:Count(), M:Count() == 1 and "" or "s"),
                run = function() M:Collect() end }
            s0.skip = function() M:Snooze() end
            return s0
        end
    end
    -- cheap vendor materials left over once the plan's crafting is done (Flint and Tinder...): sell them back
    -- selling can start once the crafting is done, or right away while purging
    -- (or whenever bags are tight: sell this batch to make room for the next one)
    -- finished items taking up room (wands don't stack: 25 wands = 25 slots): offload them first
    local sellSlots = 0
    for _, it in ipairs(sell) do sellSlots = sellSlots + math.ceil(it.sellN / math.max(PC:StackSize(it.id), 1)) end
    for _, it in ipairs(vsell) do sellSlots = sellSlots + math.ceil(it.sellN / math.max(PC:StackSize(it.id), 1)) end
    local offload = (#sell > 0 or #vsell > 0) and (sellSlots >= 5
        or PC:FreeBagSlotsOnly() < ((PC.Bank and PC.Bank.BAG_RESERVE) or 6)
        or (PC.ahOpen and #sell > 0) or (PC.merchantOpen and #vsell > 0))
    -- what you were already carrying when the plan was made comes first, whatever the bags are
    -- like: it's bag space back before anything new is made
    local lo = PC.cdb.planLeftover
    if lo and next(lo) then
        local any = false
        for _, it in ipairs(sell) do if lo[it.id] then any = true end end
        for _, it in ipairs(vsell) do if lo[it.id] then any = true end end
        if any then offload = true end
    end
    -- out in the world: no selling, unless the plan you're running can't go on without the bag room
    -- (a "My catch" plan from Fishmonger is selling you asked for: it shows wherever you are)
    if not town and not (planWork and offload) and PC:PlanName() ~= "My catch" then
        sell, vsell, offload = {}, {}, false
    end
    local ready = #craft == 0 or Sell.purge or offload
    local leftovers = (town and #craft == 0 and PC.VendorAuto and PC:SellLeftovers()) and PC.VendorAuto:Leftovers(entries) or {}
    local left = #ahList + #vendorList + #craft + #sell + #vsell + (mailN > 0 and 1 or 0) + (#leftovers > 0 and 1 or 0)
    local s = { left = left }
    -- bags short of room for the plan: put the things it doesn't use in the bank first (skippable;
    -- skipped, the plan works with the room you have, always keeping a slot free)
    -- finished items to sell come first: selling them frees the room, so no bank trip before it
    if town and PC.Bank and PC.Bank.unusedWanted and not offload and not PC.Bank:Open() and not (Craft.quick and Craft.quick.started) then
        local unused = PC.Bank:UnusedList()
        local slots = 0
        for _, it in ipairs(unused) do slots = slots + (it.slots or 1) end -- the bag slots they take up now
        if #unused > 0 and slots > 0 and PC.Bank:FreeSlots() - (PC.Bank.BANK_RESERVE or 2) > 0 then
            local P = PC.Places
            local p = P and P:Nearest("bank")
            local names = {}
            for i2 = 1, math.min(#unused, 6) do names[#names + 1] = unused[i2].qty .. " " .. unused[i2].name end
            if #unused > 6 then names[#names + 1] = ("+%d more"):format(#unused - 6) end
            s.text = ("Store unused items (%d slot%s)"):format(slots, slots == 1 and "" or "s")
            s.cat = "Bank"
            s.tip = ("Your bags are short of room for this plan. These aren't used by it: %s.%s\n|cff888888Skip: keep them; the plan works with the room you have.|r"):format(
                table.concat(names, ", "), (function() for _, it in ipairs(unused) do if it.id == PC.Bank.HEARTH then return "\nYour hearthstone comes back out once the crafting is done." end end return "" end)())
            s.dest = p
            if p and P then s.tip = s.tip .. "\n" .. P:Describe(p) end
            s.skip = function() PC.Bank:SkipUnused() end
            s.skipTip = "Keep them in your bags: the plan works with the room you have (one slot always stays free)."
            -- standing at the bank and it still says this: the click looks again, and says what it sees
            s.run = function()
                if PC.Bank.CheckOpen and PC.Bank:CheckOpen() then return end
                if p and P then P:Point(p, s.text) end
                SlashCmdList.PROFITCRAFTER("bank")
            end
            return s
        end
    end
    -- more finished items than the market takes, bags tight and no room in the bank: don't flood the
    -- AH - disenchant the extras (when that's worth more than a vendor pays) or sell them to a vendor
    local Bk = PC.Bank
    local bankFull = not (Bk and Bk:Known()) or (Bk:FreeSlots() - (Bk.BANK_RESERVE or 2)) <= 0
    if town and bankFull and PC:FreeBagSlotsOnly() < ((Bk and Bk.BAG_RESERVE) or 6) and not (Craft.quick and Craft.quick.started) then
        for _, it in ipairs(sell) do
            local extra = it.have - (Bk and Bk.MarketKeep and Bk:MarketKeep(it.id) or it.have)
            if extra >= 2 then
                local Sy = PC.Synergy
                local vend = PC:SellPrice(it.id) or 0
                local deVal = Sy and Sy:CanDisenchant(it.id) and Sy:EnchantingSkill() and Sy:Value(it.id) or nil
                if deVal and deVal >= vend then
                    s.text = ("Too many %s: disenchant %d"):format(it.name, extra)
                    s.tip = ("More than the Auction House will buy any time soon, and your bags and bank are full. Disenchanting %d gives about %s of materials each (a vendor pays %s)."):format(
                        extra, PC:Money(deVal, false, true), PC:Money(vend, false, true))
                    s.run = function() Sy:Queue(it.id, extra); PC:RefreshUI() end
                else
                    s.text = ("Too many %s: vendor %d"):format(it.name, extra)
                    s.tip = ("More than the Auction House will buy any time soon, and your bags and bank are full. A vendor pays %s each; the rest still go to auction."):format(PC:Money(vend, false, true))
                    s.run = function()
                        PC.cdb.dumpVendor = PC.cdb.dumpVendor or {}
                        PC.cdb.dumpVendor[it.id] = extra
                        PC:RefreshUI()
                    end
                end
                s.skip = function() PC.cdb.extraSkip = PC.cdb.extraSkip or {}; PC.cdb.extraSkip[it.id] = time(); PC:RefreshUI() end
                s.skipTip = "Keep them all for auction."
                if not (PC.cdb.extraSkip and PC.cdb.extraSkip[it.id] and time() - PC.cdb.extraSkip[it.id] < 3600)
                    and not (PC.cdb.dumpVendor and PC.cdb.dumpVendor[it.id]) then
                    return s
                end
                s.text, s.tip, s.run, s.skip, s.skipTip = nil, nil, nil, nil, nil
            end
        end
    end
    -- bags full with plan materials still to buy and nothing to craft: say how to make room
    -- (never "All done" while the plan isn't)
    if rawBuy and scale <= 0 and #craft == 0 and not Sell.purge and not (PC.Bank and PC.Bank:Open())
        and not (Craft.quick and Craft.quick.started) and not (PC.Mail and PC.Mail:Open()) then
        return PC.VendorAuto:MakeRoomStep(s)
    end
    -- you chose Purge materials: a vendor visit to sell them
    if Sell.purgeMats and not (Craft.quick and Craft.quick.started) then
        local mats = Sell:PurgeMatsList()
        if #mats == 0 then
            Sell.purgeMats = nil
        elseif PC.merchantOpen then
            s.text = ("Sell %d spare material%s"):format(#mats, #mats == 1 and "" or "s")
            s.tip = "You chose Purge materials: sells the spare materials to this vendor."
            s.run = function() Sell:SellMats() end
            return s
        else
            local P = PC.Places
            local p = P and P:Nearest("vendor")
            s.text = "Vendor: sell spare materials"
            s.tip = "You chose Purge materials. Any vendor buys them." .. (p and ("\n" .. P:Describe(p)) or "")
            s.dest = p
            s.skip = function() Sell.purgeMats = nil; PC:RefreshUI() end
            s.skipTip = "Stop purging materials."
            return s
        end
    end

    -- a batch crafting from the button: say so until it's done
    local q = Craft.quick
    -- a batch that quietly stopped (bags full, an error, no "failed" from the game): over, not stuck
    if q and q.started then
        local casting = (UnitCastingInfo and UnitCastingInfo("player")) or (UnitChannelInfo and UnitChannelInfo("player"))
        if not casting and GetTime() - (q.last or q.started) > 6 then
            Craft:EndQuick(false)
            q = nil
        end
    end
    if q and q.ready and not q.started then
        local n = math.min(q.n or 1, Craft:Count(q.e))
        if n > 0 then
            local st = self:CraftStep(s, q.e, n, "The profession is open out of sight. Press once more: the game only starts crafting from a key press or click.")
            if st.run then st.text = ("Start crafting %d %s"):format(n, q.e.r.name) else Craft:EndQuick(false) end
            return st
        end
        Craft:EndQuick(false)
        q = nil
    end
    if q and q.started then
        s.text = ("Crafting %s... (%d to go)"):format(q.e.r.name, q.left or q.n)
        s.tip = "The whole batch runs in the background. Moving stops it; click again to carry on."
        return s
    end
    -- something in progress at the AH comes first
    local b = B.buy
    -- a price request the AH never answered (15 seconds): drop it instead of "Waiting..." forever
    -- (only a request: a purchase already sent is never dropped, it waits for its outcome)
    if b and b.state == "quoting" and b.t0 and GetTime() - b.t0 > 15 then
        B:Cancel()
        b = nil
        B:Say("|cffff8040No price from the Auction House. Click to try again.|r")
    end
    local sent = B:Unsettled()
    if b and b.state == "quoted" then
        s.text = "Confirm " .. PC:Money(b.total or 0, false, true)
        s.tip = ("Buy %d %s for %s"):format(b.qty, b.name, PC:Money(b.total or 0))
        s.run = function() B:Confirm() end
        return s
    elseif (b and b.state == "buying") or (sent and PC.ahOpen) then
        -- sent: nothing more is bought on the AH until the AH and your gold both say how it went
        s.text = "Waiting for the Auction House to confirm..."
        s.tip = sent and ("%d %s, sent %d sec ago. Nothing else is bought until the Auction House answers."):format(
            sent.qty, PC:ItemName(sent.id) or "", math.floor(GetTime() - sent.t)) or nil
        s.run = function() B:SayWaiting() end
        return s
    elseif b then
        s.text = "Waiting... (click to cancel)"
        s.run = function() B:CancelWaiting() end
        return s
    end
    -- can the next thing to buy even be carried? If not, the bank comes first
    local function noRoom(it)
        return it and PC:FitsQty(it.id, it.qty, PC.BUY_RESERVE) <= 0
    end
    local function bagsFull(it)
        -- no room to buy more: craft with what you already have (that frees the room), then come
        -- back for the rest. The plan doesn't have to be done in one trip.
        if #craft > 0 then
            local e = craft[1]
            local n = Craft:Count(e)
            return Next:CraftStep(s, e, n, ("Your bags are full, so craft with what you have first; then come back and buy the rest%s."):format(
                it and it.name and (" (" .. it.name .. ")") or ""))
        end
        return PC.VendorAuto:MakeRoomStep(s, it and it.name)
    end
    -- what's left to buy costs more than your gold: trim the plan before buying anything
    if (#ahList > 0 or #vendorList > 0) and not Sell.purge then
        local cost, missing = UI:PlanCost()
        local budget = PC:Gold()
        -- short of gold with mail waiting: collect it first, it may be gold from sales
        if not missing and cost > budget and Next:MailForGold(s, ("The plan needs about %s and you have %s to spend. You have mail: it may be gold from your sales."):format(
            PC:Money(cost, false, true), PC:Money(budget, false, true))) then
            return s
        end
        if not missing and cost > budget then
            s.text = "Trim plan to fit your gold"
            s.tip = ("What's left to buy, plus the auction fees to post what you make, comes to about %s; you have %s to spend.\nOne click shrinks the plan (least profitable crafts first) until it fits."):format(
                PC:Money(cost, false, true), PC:Money(budget, false, true))
            s.run = function()
                local n = UI:TrimToGold()
                PC.Buy:Say(("|cffff8040Plan trimmed by %d craft%s to fit %s.|r"):format(n, n == 1 and "" or "s", PC:Money(budget, false, true)))
            end
            return s
        end
    end
    -- vendor flips in the plan: ask once before buying their materials (Buy them, or skip the flips)
    local flips = {}
    for _, e in ipairs(entries) do if e.route == "Vendor" then flips[#flips + 1] = e end end
    if #flips > 0 and (#ahList > 0 or #vendorList > 0) and not Next:FlipsOK() then
        local names, ahProfit, vProfit = {}, 0, 0
        for _, e in ipairs(flips) do
            names[#names + 1] = ("%d %s"):format(e.planCount or 0, e.r.name)
            ahProfit = ahProfit and e.ahProfit and ahProfit + e.ahProfit * (e.planCount or 0) or nil
            vProfit = vProfit + (e.vendorProfit or e.profit or 0) * (e.planCount or 0)
        end
        s.text = "Vendor flips: buy materials?"
        s.tip = ("Crafted to sell to a vendor. Vendor Profit %s, Auction Profit %s:\n%s\nClick: buy the materials. Skip: drop them from the plan."):format(
            PC:Money(vProfit, true, true), PC:Money(ahProfit, true, true), table.concat(names, "\n"))
        -- the choice is right on the bar (no pop-up that can get lost behind windows)
        s.run = function() Next:FlipsGo() end
        s.skip = function() Next:FlipsSkip(flips) end
        s.skipTip = "Skip the vendor flips: they come out of the plan, nothing is bought for them."
        return s
    end
    if PC.ahOpen then
        -- prices still coming in: nothing gets bought on stale numbers
        if B:Scanning() and (#ahList > 0 or #sell > 0) then
            s.text = "Scanning the Auction House..."
            s.tip = "Buying and posting wait until the scan is done, so they use today's prices."
            return s
        end
        -- the next thing to buy, from the list settled when you walked up (what's still to buy kept
        -- current, purchases sent a moment ago included); Start works the amount out again
        local it
        for _, x in ipairs(ahList) do if B:CanBuy(x.id) then it = x break end end
        -- (AH purchases go to the mailbox: no bag room needed to buy them)
        if it then
            local cost = PC:CostForQty(it.id, it.qty)
            s.text = ("Buy %d %s"):format(it.qty, it.name or "")
            s.tip = cost and ("About " .. PC:Money(cost) .. " at auction") or nil
            s.run = function() B:Start(it, false, true) end
            return s
        end
        -- classic-style AH: can't buy for you, but can run the search so the listing is one click away
        local function findStep()
            local first = ahList[1]
            -- this AH lists it as separate auctions and the search has them: buy the cheapest, one per click
            if B.HasListings and B:HasListings(first.id) and not B:ClassicAH() then
                local r, _, cap = B:NextListing(first)
                s.text = ("Buy %d %s"):format(first.qty, first.name or "")
                s.tip = (r and ("This click: %d for %s (%s each), the cheapest listing."):format(r.qty, PC:Money(r.buyout, false, true), PC:Money(math.floor(r.unit), false, true))
                    or ("Nothing listed under %s each right now: click to search again."):format(cap and PC:Money(cap, false, true) or "a fair price"))
                    .. "\nOne listing per click; it goes to your mailbox."
                s.run = function() B:BuyListing(first) end
                return s
            end
            -- (AH purchases go to the mailbox: no bag room needed)
            local cap = B:VendorPrice(first.id)
            s.text = ("Find %d %s"):format(first.qty, first.name or "")
            s.tip = ("Searches the Auction House for it. Buy out %d%s."):format(first.qty,
                cap and (" under " .. PC:Money(cap, false, true) .. " each (what a vendor charges)") or "")
            s.run = function()
                if PC.UI and PC.UI.StaleScan and not PC.UI.StaleScan:Check() then return end
                B:SearchAH(first)
            end
            return s
        end
        if B:ClassicAH() and #ahList > 0 then return findStep() end
        -- post only once the plan's crafting is done (a reload mustn't skip "Craft 100")
        -- already standing at the AH: post what's sellable in your bags now, crafting left or not
        -- (the craft-first rule is only about not sending you here too early)
        if Sell:Supported() and #sell > 0 then
            local units, stacks, names = 0, 0, {}
            for _, it in ipairs(sell) do
                units = units + it.sellN
                names[#names + 1] = ("%d %s at %s"):format(it.sellN, it.name, PC:Money(it.price, false, true))
                for _, bs in ipairs(Bags()) do if bs.id == it.id and not bs.locked then stacks = stacks + 1 end end
            end
            -- one post per click: say what this click posts, and how many more to go
            local first = sell[1]
            local n = first.sellN
            if Sell:Classic() then
                for _, bs in ipairs(Bags()) do if bs.id == first.id and not bs.locked then n = bs.n break end end
            elseif Sell.oneAtATime and not PC:IsCommodity(first.id) then
                n = 1
            end
            -- the deposit is paid up front: not enough gold for it, say so instead of a post that fails
            local money = GetMoney and GetMoney() or 0
            local dep = first.deposit and first.sellN > 0 and math.ceil(first.deposit * n / first.sellN) or 0
            if dep > money and Next:MailForGold(s, ("You need %s for the auction deposit and have %s. You have mail: it may be gold from your sales."):format(PC:Money(dep, false, true), PC:Money(money, false, true))) then
                return s
            end
            if dep > money then
                s.text = ("Need %s to post (fee)"):format(PC:Money(dep, false, true))
                local spare = {}
                for _, it in ipairs(PC.VendorAuto and PC.VendorAuto:Leftovers() or {}) do spare[#spare + 1] = it.name end
                s.tip = ("The Auction House takes a %s deposit to list %d %s and you have %s.\n"):format(PC:Money(dep, false, true), n, first.name, PC:Money(money, false, true))
                    .. (#spare > 0 and ("Sell leftover materials at a vendor first: " .. table.concat(spare, ", ") .. ".") or "Sell something at a vendor or collect your mail, then come back.")
                s.run = function() PC.Buy:Say("|cffff8040" .. s.tip:gsub("\n", " ") .. "|r") end
                return s
            end
            -- one item type per click: all the Brown Linen Pants, then all the shirts...
            s.text = (n == first.sellN and n > 1) and ("Post all %d %s"):format(n, first.name) or ("Post %d %s"):format(n, first.name)
            local more = #sell - 1
            if more > 0 then s.text = s.text .. (" (then %d more)"):format(more) end
            local rest = {}
            for i = 2, #names do rest[#rest + 1] = names[i] end
            s.tip = (Sell.purge and "|cffff8040Purging|r (Stop purge in the tasks list, or /pc purge stop).\n" or "")
                .. ("This click: %s, at the cheapest listing."):format(names[1])
                .. (#rest > 0 and ("\nNext clicks, one item at a time:\n" .. table.concat(rest, "\n")) or "")
            s.run = function() Sell:PostAll() end
            return s
        elseif #sell > 0 and ready then
            -- already here, but this client can't post from an addon: say what to do, don't send you to the AH
            s.text = ("Post %d %s yourself"):format(sell[1].sellN, sell[1].name)
            s.tip = ("Use the Auction House's Auctions tab: %s each."):format(PC:Money(sell[1].price, false, true))
            return s
        end
        -- something left to buy that the button can't buy for you here: the search, never "Go to the AH"
        -- while you're standing at it
        if #ahList > 0 then return findStep() end
    end
    -- at the AH with Auctionator: check your listings for undercuts, cancel the ones that won't sell
    if PC.ahOpen and Undercut:Auctionator() then
        local cancel = Undercut:Supported() and Undercut:ToCancel() or {}
        if #cancel > 0 then
            local c = cancel[1]
            s.text = ("Cancel %d %s"):format(c.qty, c.name) -- short: fits the button next to Skip
            s.tip = ("Yours: %s each, cheapest now: %s.\nWon't sell in the next 4 hours: %s.\nCancelling loses the deposit; it comes back by mail and is posted again at about %s.%s"):format(
                PC:Money(c.unit, false, true), PC:Money(c.cheapest, false, true), c.why or "",
                PC:Money(c.repost, false, true), #cancel > 1 and ("\n%d more after this."):format(#cancel - 1) or "")
            s.run = function() Undercut:Cancel(c) end
            s.skip = function() Undercut:SkipItem(c.itemID) end
            s.tip = s.tip .. "\n|cff888888Skip (or right-click): leave it up.|r"
            return s
        end
        if Undercut:Due() then
            local helper = Undercut:Helper() or "Auctionator"
            s.text = ("Check undercuts (%s)"):format(helper)
            s.tip = (helper == "TSM" and "Runs TSM's cancel scan on your listings (and reads them itself too)." or "Runs Auctionator's undercut scan on your listings.") .. " Anything undercut that won't sell in the next 4 hours is offered for cancelling and reposting.\n|cff888888Skip (or right-click): not until you come back to a city.|r"
            s.run = function() Undercut:Scan() end
            s.skip = function() Undercut:SkipScan() end
            return s
        end
    end
    if VB:Open() and #vsell > 0 and ready then
        local units, names = 0, {}
        for _, it in ipairs(vsell) do units = units + it.sellN; names[#names + 1] = ("%d %s at %s"):format(it.sellN, it.name, PC:Money(it.vendorPrice, false, true)) end
        s.text = ("Sell %d crafted to vendor"):format(units)
        s.tip = "The vendor pays more than the Auction House for these (after its cut), and it's still a profit:\n" .. table.concat(names, "\n")
        s.run = function() PC.VendorAuto:SellCrafted() end
        return s
    end
    if VB:Open() and VB:Busy() then
        -- one purchase at a time, each waited for in your bags: say so until it's done
        local j = VB.queue[1]
        s.text = "Buying from vendor..."
        s.tip = j and ("%d of %d %s so far, %d more item%s to go."):format(
            j.got, j.want, j.name, #VB.queue - 1, #VB.queue == 2 and "" or "s") or "Waiting for the last purchase to reach your bags."
        s.run = function() PC.Buy:Say("|cffffd100" .. s.tip .. "|r") end
        return s
    end
    if VB:Open() then
        local vl = VB:PlanList()
        if #vl > 0 and noRoom(vl[1]) then return bagsFull(vl[1]) end
        if #vl > 0 then
            s.text = ("Buy from vendor (%d)"):format(#vl)
            s.run = function() VB:BuyAll() end
            return s
        end
        if #leftovers > 0 then
            local lo = leftovers[1]
            s.text = ("Sell back %d %s"):format(lo.n, lo.name)
            s.tip = "Left over from the plan: the vendor takes it back for " .. PC:Money(lo.value)
            s.run = function() PC.VendorAuto:SellBack(entries) end
            s.skip = function() PC.VendorAuto:AskLeftovers(leftovers) end
            s.skipTip = "Don't sell them back: keep them in your bags or store them in the bank. You won't be asked again (even after a reload); change it on the Sell page."
            return s
        end
    end
    if PC.Bank and PC.Bank:Open() and PC:UseBank() then
        local text, tip, items = PC.Bank:NextText()
        if text then
            s.text, s.tip, s.items, s.cat = text, tip, items, "Bank"
            s.run = function() PC.Bank:Run() end
            return s
        end
    end
    -- at the mailbox with full bags: take the gold, leave the items until there's room
    if PC.Mail and PC.Mail:Open() and PC.Mail:Count() > 0 and PC:FreeBagSlotsOnly() <= (PC.BUY_RESERVE or 1) and not PC.Mail:HasMoney() then
        PC.Mail.itemsWaiting = PC.Mail:Count()
    elseif PC.Mail and PC.Mail:Open() and PC.Mail:Count() > 0 then
        s.text = "Collect auction mail"
        s.run = function() PC.Mail:Collect() end
        return s
    end
    local prof = Craft:OpenProfession()
    if prof then
        for _, e in ipairs(craft) do
            if Craft:IsOpenFor(e.r) then
                local n = Craft:Count(e)
                if n > 0 then
                    local tool, has, toolID = Craft:Tool(e)
                    if tool and has == false then
                        local st = Craft:ToolStep(e, tool, toolID, s)
                        if st then return st end
                        n = 0 -- can't craft this one until the tool is made: see the other steps
                    end
                    local station, near
                    if n > 0 then station, near = Craft:Station(e) end
                    if n > 0 then -- (noted for the silent record: why this step was chosen)
                        local P2 = PC.Places
                        local sp = station and P2 and P2:Nearest("station", nil, station)
                        local T3 = PC.Travel
                        s.stationDiag = { recipe = e.r.name, station = station or "none", near = near,
                            known = sp and true or false,
                            yd = (sp and T3) and T3:Yards(T3:Here(), sp) or nil }
                    end
                    if n <= 0 then
                        -- skip to the next recipe
                    elseif station and near == false then
                        local P = PC.Places
                        local p = P and P:Nearest("station", nil, station)
                        local yd = p and PC.Travel and PC.Travel:Yards(PC.Travel:Here(), p)
                        -- where it's known, say where to walk; "find one" is for when it isn't
                        s.text = p and (("Walk to the %s%s"):format(station, yd and (" (%d yd)"):format(yd) or ""))
                            or ("Find a " .. station)
                        s.tip = ("%s needs a %s. "):format(e.r.name, station) .. (p and P:Describe(p) or "ProfitCrafter learns where they are when you craft next to one.")
                        s.dest = p
                        return s
                    else
                        s.text = "Craft " .. PC:CraftCount(n, e.r)
                        s.run = function() Craft:Go(e, n) end
                        return s
                    end
                end
            end
        end
    end
    -- start of a play day: check the mail, and look in the bank if it hasn't been seen today,
    -- so the plan works from what you really have
    local today = date("%Y-%m-%d")
    PC.cdb.dayCheck = PC.cdb.dayCheck or {}
    local dc = PC.cdb.dayCheck
    if dc.day ~= today then dc.day, dc.mail, dc.bank = today, nil, nil end
    -- (only in a city: out in the world nothing is asked, and it's asked once you get to one)
    if not dc.mail and town then
        dc.mail = true -- no mail waiting: that's checked for today
    end
    if not dc.bank and PC.Bank and town then
        local b = PC.Bank:Known()
        local seenToday = b and b.t and date("%Y-%m-%d", b.t) == today
        if not b and not PC.cdb.bankAsked then
            -- never seen: ProfitCrafter can't plan with what's in there until you open it once
            s.text = "Go to the bank"
            s.items = { "open your bank once so ProfitCrafter knows what's in it" }
            s.tip = "First time: ProfitCrafter hasn't seen your bank yet. Open it once and it remembers what's in it (and checks again each day you play)."
            local P = PC.Places; local p = P and P:Nearest("bank")
            if p then s.dest = p end
            s.skip = function() dc.bank = true; PC.cdb.bankAsked = true; PC:RefreshUI() end
            return s
        elseif b and not seenToday then
            s.text = "Go to the bank"
            s.tip = "Start of the day: ProfitCrafter hasn't seen your bank today. A quick visit updates what you have."
            local P = PC.Places; local p = P and P:Nearest("bank")
            if p then s.dest = p end
            return s
        end
        dc.bank = true
    end
    -- first use, then once a week: open each profession so ProfitCrafter knows your recipes and their
    -- colours (skill-ups change as you level). Skip puts it off until tomorrow.
    if not dc.profs and town then
        local stale = Next:StaleProfessions()
        if #stale > 0 then
            local first = stale[1]
            local never = not (PC.cdb.profSeen and next(PC.cdb.profSeen))
            s.text = ("Open %s"):format(first.name)
            s.items = {}
            for _, p in ipairs(stale) do s.items[#s.items + 1] = "open " .. p.name end
            s.tip = (never and "First time: open each of your professions once so ProfitCrafter learns your recipes."
                or "Weekly check-in: open these professions so ProfitCrafter has your latest recipes and skill-up colours.")
                .. "\nThe button opens them one at a time; nothing is crafted."
                .. "\n|cff888888Skip (or right-click): not until tomorrow.|r"
            if C_TradeSkillUI and C_TradeSkillUI.OpenTradeSkill and first.skillLine then
                s.run = function()
                    if not pcall(C_TradeSkillUI.OpenTradeSkill, first.skillLine) then
                        PC.Buy:Say(("Open %s from your spellbook (or profession button)."):format(first.name))
                    end
                end
            end
            s.skip = function() dc.profs = true; PC:RefreshUI() end
            return s
        end
    end
    -- after a reload, carry on with the crafting you were in the middle of before anything else
    local last = PC.cdb.lastStep
    if last and last.text and last.text:find("^Craft ") and #craft > 0 and not offload then
        local e = craft[1]
        local n = Craft:Count(e)
        return self:CraftStep(s, e, n, "Carries on where you left off. No window needed: the button does it.")
    end
    -- the hourly undercut check (near an AH, things listed): one more stop on the route, nearest first
    local dueAway, ahPlace = Undercut:DueAway()
    local P = PC.Places
    -- materials already in your bank: a bank stop; buying waits until they're out
    local bankTake = PC.Bank and PC.Bank:Known() and not PC.Bank:Open() and #PC.Bank:TakeList() > 0
        and PC.Bank:TakeFits({ PC.Bank:TakeList()[1] })
    -- bags filling up with things that belong in the bank (held items, spare materials), or no room
    -- for what the plan still has to buy: a bank stop comes first
    local needSlots = 0
    -- (AH purchases go to the mailbox, so they need no bag room up front)
    for _, it in ipairs(vendorList) do needSlots = needSlots + PC:SlotsFor(it.id, it.qty) end
    local freeNow = PC:FreeBagSlotsOnly()
    -- can craft now: craft first, buy after (use what you carry before fetching more) - unless
    -- finished items are taking up the room: those get sold first
    if #craft > 0 and not Sell.purge and not offload then
        local e = craft[1]
        local n = Craft:Count(e)
        return self:CraftStep(s, e, n, "Craft with what's in your bags first: that frees room for the rest of the materials.")
    end
    local store = (PC.Bank and PC.Bank:Known() and (freeNow <= 4 or needSlots > freeNow)) and PC.Bank:StoreList() or {}
    -- a later stage's materials in your bags (the oil's vials while the greens are made): to the bank
    if #store == 0 and PC.Bank and PC.Bank:Known() then
        for _, it in ipairs(PC.Bank:StoreList()) do if it.kind == "later" then store[#store + 1] = it end end
    end
    -- crafting tools (rods, hammers, spanners) live in the bank when no craft left needs them
    if #store == 0 and #craft == 0 and PC.Bank and PC.Bank:Known() then
        for _, it in ipairs(PC.Bank:StoreList()) do if it.kind == "tool" then store[#store + 1] = it end end
    end
    if PC.Bank and PC.Bank:Open() then store = {} end -- already standing at it: never "go to the bank" from the bank
    if not town then store = {} end -- out in the world: the bank can wait until you're in a city
    local stops = {}
    -- don't buy what's sitting in your bank; and with bags tight, sell what's finished before buying more
    local tight = freeNow < ((PC.Bank and PC.Bank.BAG_RESERVE) or 6)
    local buying = not bankTake and not (tight and (#vsell > 0 or #sell > 0))
    if buying then for _, it in ipairs(vendorList) do stops[#stops + 1] = { kind = "vendor", itemID = it.id } end end
    -- finished items waiting to be sold: sell them before storing (or fetching) materials
    if (#store > 0 or bankTake) and not offload then stops[#stops + 1] = { kind = "bank" } end
    local dumping = town and next(PC.cdb.dumpVendor or {}) ~= nil
    if (#leftovers > 0 or (#vsell > 0 and ready) or dumping) and (#vendorList == 0 or not buying or dumping) then stops[#stops + 1] = { kind = "vendor" } end
    -- the AH for selling only once everything in the plan is crafted
    local ahBuy = buying and #ahList > 0
    if ahBuy or (#sell > 0 and ready) or dueAway then stops[#stops + 1] = { kind = "ah" } end
    if mailN > 0 then stops[#stops + 1] = { kind = "mail" } end
    local route = P and P:Route(stops) or {}
    local first = route[1]
    if first and not first.unknown then
        local p = first.place
        local what = (first.kind == "vendor" and ("Vendor: " .. (p.name or "")))
            or (first.kind == "ah" and (ahBuy and ("Go to the Auction House: buy %d %s%s"):format(ahList[1].qty, ahList[1].name or "", #ahList > 1 and (" (+%d)"):format(#ahList - 1) or "")
                or (#sell > 0 and ready) and "Go to the Auction House to sell" or "Go to the Auction House: check undercuts"))
            or (first.kind == "bank" and "Go to the bank")
            or "Go to the mailbox"
        s.text = what
        s.dest = p
        -- the same thing with no travel in it (for when "Plan my route for me" is off)
        local function few(list, nameOf)
            local a = list[1]
            if not a then return "" end
            return nameOf(a) .. (#list > 1 and (" (+%d more)"):format(#list - 1) or "")
        end
        if first.kind == "vendor" then
            if first.items and #first.items > 0 then
                s.simple = "Buy " .. few(first.items, function(id) return PC:ItemName(id) or ("item " .. id) end) .. " at vendor"
            elseif #vsell > 0 then
                s.simple = "Sell " .. few(vsell, function(it) return it.sellN .. " " .. it.name end) .. " at vendor"
            elseif #leftovers > 0 then
                s.simple = "Sell " .. few(leftovers, function(lo) return lo.n .. " " .. lo.name end) .. " at vendor"
            else
                s.simple = "Sell at vendor"
            end
        elseif first.kind == "ah" then
            s.simple = (ahBuy and ("Buy %d %s at auction"):format(ahList[1].qty, ahList[1].name or "") .. (#ahList > 1 and (" (+%d more)"):format(#ahList - 1) or ""))
                or ((#sell > 0 and ready) and ("Post " .. few(sell, function(it) return it.sellN .. " " .. it.name end) .. " at auction"))
                or "Check your auctions"
        elseif first.kind == "bank" then
            s.simple = bankTake and "Take your materials out of the bank" or "Put spare items in the bank"
        else
            s.simple = "Collect your auction mail"
        end
        local tip = { P:Describe(p, first.d) }
        if first.kind == "bank" then
            local names = {}
            if bankTake then
                s.items = {}
                for _, it in ipairs(PC.Bank:TakeList()) do
                    names[#names + 1] = it.qty .. " " .. (it.name or "")
                    s.items[#s.items + 1] = ("take out %d %s"):format(it.qty, it.name or "")
                end
                tip[#tip + 1] = "Take out: " .. table.concat(names, ", ") .. " (your plan needs them; no buying them again)"
            else
                s.items = {}
                for _, it in ipairs(store) do
                    names[#names + 1] = it.qty .. " " .. (it.name or "")
                    s.items[#s.items + 1] = ("store %d %s"):format(it.qty, it.name or "")
                end
                local allLater = true
                for _, it in ipairs(store) do if it.kind ~= "later" then allLater = false end end
                if allLater then
                    tip[#tip + 1] = ("Not needed until the greens are disenchanted: store %s for now (they come back out when it's their turn)"):format(table.concat(names, ", "))
                else
                    tip[#tip + 1] = ("Bags nearly full (%d free): store %s"):format(PC:FreeBagSlotsOnly(), table.concat(names, ", "))
                end
            end
        elseif first.kind == "ah" then
            local names = {}
            for _, it in ipairs(ahList) do
                local cap = B:VendorPrice(it.id)
                names[#names + 1] = it.qty .. " " .. (it.name or "") .. (cap and (" (under " .. PC:Money(cap, false, true) .. " each)") or "")
            end
            if #names > 0 then tip[#tip + 1] = "Buy there: " .. table.concat(names, ", ") end
            if #sell > 0 and ready then
                local sn = {}
                for _, it in ipairs(sell) do sn[#sn + 1] = it.sellN .. " " .. it.name end
                tip[#tip + 1] = "Sell there: " .. table.concat(sn, ", ")
            end
        elseif first.kind == "mail" then
            local n = 0
            n = PC:MailTrips()
            if #planMail > 0 then
                Next:MailMatsStep(s, entries, planMail)
                tip[#tip + 1] = s.matsTip
            else
                tip[#tip + 1] = n > 0 and (n .. " auction purchase" .. (n == 1 and "" or "s") .. " waiting") or "You have new mail."
            end
        end
        if first.kind == "vendor" then
            local names = {}
            for _, id in ipairs(first.items) do names[#names + 1] = PC:ItemName(id) or ("item " .. id) end
            if #names > 0 then tip[#tip + 1] = "Buy here: " .. table.concat(names, ", ") end
            if #vsell > 0 and ready then
                local vn = {}
                for _, it in ipairs(vsell) do vn[#vn + 1] = it.sellN .. " " .. it.name end
                tip[#tip + 1] = "Sell here (pays more than the Auction House): " .. table.concat(vn, ", ")
            end
            if #leftovers > 0 then
                local back = {}
                for _, lo in ipairs(leftovers) do back[#back + 1] = lo.n .. " " .. lo.name end
                tip[#tip + 1] = "Sell back: " .. table.concat(back, ", ")
            end
        end
        if first.kind == "ah" and not ahBuy and #sell > 0 and ready then
            s.skip = function() PC:SnoozeSell() end
            s.skipTip = "Skip selling for an hour: what's crafted stays in your bags."
            tip[#tip + 1] = "|cff888888Skip (or right-click): not for an hour.|r"
        end
        if first.kind == "ah" and dueAway and not ahBuy and not (#sell > 0 and ready) then
            tip[#tip + 1] = ("You're in town: at the Auction House the button runs %s's undercut scan (asked once per visit)."):format(Undercut:Helper() or "Auctionator")
            s.skip = function() Undercut:SkipScan() end
        end
        local fly = P:FlightHint(p)
        if fly then tip[#tip + 1] = fly end
        if #route > 1 then tip[#tip + 1] = ("Then %d more stop%s."):format(#route - 1, #route == 2 and "" or "s") end
        s.tip = table.concat(tip, "\n")
    elseif offload and #sell > 0 then
        local sn = {}
        for _, it in ipairs(sell) do sn[#sn + 1] = it.sellN .. " " .. it.name end
        s.text = "Go to the Auction House to sell"
        s.tip = "Sell there first (it frees bag room): " .. table.concat(sn, ", ") .. "\nProfitCrafter learns where the Auction House is the first time you use it."
        s.skip = function() PC:SnoozeSell() end
    elseif offload and #vsell > 0 then
        s.text = "Visit a vendor"; s.tip = ("To sell %d %s first: it frees bag room."):format(vsell[1].sellN, vsell[1].name)
    elseif bankTake then
        s.text = "Go to the bank"
        s.tip = "Some of your plan's materials are in your bank: take them out before buying more."
    elseif #ahList > 0 then
        s.text = ("Go to the Auction House: buy %d %s%s"):format(ahList[1].qty, ahList[1].name or "", #ahList > 1 and (" (+%d)"):format(#ahList - 1) or "")
        local names = {}
        for _, it in ipairs(ahList) do names[#names + 1] = it.qty .. " " .. (it.name or "") end
        s.tip = "Buy there: " .. table.concat(names, ", ") .. "\nProfitCrafter learns where the Auction House is the first time you use it."
    elseif #vendorList > 0 then s.text = "Visit a vendor"; s.tip = "For " .. (vendorList[1].name or "materials") .. ". ProfitCrafter learns vendors as you use them."
    elseif #vsell > 0 and ready then s.text = "Visit a vendor"; s.tip = ("To sell %d %s: a vendor pays more than the Auction House."):format(vsell[1].sellN, vsell[1].name)
    elseif #leftovers > 0 then
        s.text = "Visit a vendor"; s.tip = "To sell back " .. leftovers[1].n .. " " .. leftovers[1].name .. " left over from the plan."
        s.skip = function() PC.VendorAuto:AskLeftovers(leftovers) end
        s.skipTip = "Don't sell them back: keep them in your bags or store them in the bank. You won't be asked again (even after a reload); change it on the Sell page."
    elseif mailN > 0 and #planMail > 0 then
        Next:MailMatsStep(s, entries, planMail)
        s.tip = s.matsTip
        s.dest = PC.Places and PC.Places:Nearest("mail") or nil
    elseif mailN > 0 then s.text = "Go to the mailbox"; s.tip = (PC.Mail and PC.Mail:HasNew()) and "You have new mail." or "Your auction purchases are waiting."
    elseif #craft > 0 and not offload then
        -- opens the profession window itself (to the first recipe to craft), not just ProfitCrafter
        local e = craft[1]
        local n = Craft:Count(e)
        Next:CraftStep(s, e, n, ("No window needed: the button opens %s out of sight, starts the craft and closes it again."):format(e.r.prof or "the profession"))
    elseif #store > 0 then
        s.text = "Go to the bank"
        s.items = {}
        for _, it in ipairs(store) do s.items[#s.items + 1] = ("store %d %s"):format(it.qty, it.name or "") end
        s.tip = ("Bags nearly full (%d free): store %s there."):format(PC:FreeBagSlotsOnly(), table.concat(s.items, ", "):gsub("store ", ""))
    elseif #sell > 0 and ready then s.text = "Go to the Auction House to sell"; s.skip = function() PC:SnoozeSell() end
    elseif Craft.noRoom then
        PC.VendorAuto:MakeRoomStep(s, Craft.noRoom)
    elseif next(Craft.blocked or {}) then
        -- everything left to craft is waiting on the market: say so instead of "All done"
        local id, why = next(Craft.blocked)
        local r = PC.cdb.recipes[id]
        s.text = "Waiting on sales"
        s.quiet = not town or nil -- out in the world: nothing to show
        s.tip = ("%s: the market is full for now (%s). Crafting more waits until some of yours sell."):format(r and r.name or "Your plan", why or "")
        s.left = 0
    elseif #entries == 0 then
        -- the one time the window is needed: there's no plan to work from
        s.text = "Set up a plan"
        s.tip = "Opens ProfitCrafter on the plan tab. Make me gold fills it for you."
        s.run = function() if PC.UI then PC.UI:Create(); PC.UI.f:Show(); PC.UI:ShowTab(2) end end
    elseif (function()
            for _, e in ipairs(entries) do
                local tool, has, toolID = Craft:Tool(e)
                if tool and has == false then
                    local st = Craft:ToolStep(e, tool, toolID, s)
                    if st then return true end
                    -- craftable: say what its materials need
                    s.text = "Get materials for " .. tool
                    s.tip = ("%s needs a %s. You can make one: buy its materials first (see the plan's list)."):format(e.r.name, tool)
                    return true
                end
            end
        end)() then
    elseif (function()
            -- crafts still in the plan, but their materials aren't in your bags: say what's missing and
            -- where each one is (mailbox, bank, AH or a vendor), and send you to the first place.
            -- (the plan can't go on without them, so the mailbox counts here even when it's far away)
            if (PC.Bank and PC.Bank.Open and PC.Bank:Open()) or (PC.Mail and PC.Mail.Open and PC.Mail:Open()) then return false end
            if Craft.noRoom then return false end
            local rows, first = Next:MissingMats(entries)
            if not first then return false end
            local P = PC.Places
            s.items, s.cat = {}, first.cat
            for _, r in ipairs(rows) do s.items[#s.items + 1] = r.line end
            if first.where == "mail" then
                s.text = ("Get %s from the mailbox"):format(first.name)
                s.dest = P and P:Nearest("mail") or nil
            elseif first.where == "bank" then
                s.text = ("Get %s from the bank"):format(first.name)
                s.dest = P and P:Nearest("bank") or nil
            elseif first.where == "vendor" then
                s.text = ("Buy %d %s at a vendor"):format(first.n, first.name)
                local v = P and P:Nearest("vendor", first.id)
                s.dest = v
                if v and v.name then s.text = ("Buy %d %s from %s"):format(first.n, first.name, v.name) end
            elseif first.where == "stopped" then
                -- all that's left would lose the minimum profit: nowhere to go for it
                s.text = ("Stopped buying %s (under %d%% profit)"):format(first.name, PC:MinProfitPct())
                -- nothing sends you to the AH or a vendor for it, so the plan is cut here (else this step never goes)
                for _, r in ipairs(rows) do if r.where == "stopped" then PC:AmendPlanSoon(r.id) end end
            else
                s.text = ("Buy %d %s at auction"):format(first.n, first.name)
                s.dest = P and P:Nearest("ah") or nil
            end
            local lines = {}
            for _, r in ipairs(rows) do lines[#lines + 1] = r.tip end
            s.tip = "Your plan still needs, in your bags:\n" .. table.concat(lines, "\n")
            return true
        end)() then
    elseif (function()
            -- never "All done" while the plan still has crafts left: say what's missing for the first one
            for _, e in ipairs(entries) do
                if (e.planCount or 0) > 0 and not e.sub then
                    local missing = {}
                    for _, rg in ipairs(e.r.reagents or {}) do
                        local bags = 0
                        for _, id in ipairs(PC:ReagentIDs(rg)) do bags = bags + PC:BagCount(id) end
                        local need = (rg.n or 1) - bags
                        if need > 0 then missing[#missing + 1] = ("%d %s"):format(need, PC:ItemName(rg.id) or "?") end
                    end
                    s.text = "Get materials for " .. e.r.name
                    s.tip = #missing > 0 and ("Still needed in your bags: %s."):format(table.concat(missing, ", "))
                        or ("Open your profession window to craft %s."):format(e.r.name)
                    -- (bought and waiting in the mail: say so, and point at the mailbox)
                    local waiting = Next:PlanMailWaiting(entries)
                    if #waiting > 0 or PC:MailTrips() > 0 then
                        local P = PC.Places
                        s.text = ("Get materials for %s from the mailbox"):format(e.r.name)
                        s.cat = "Mail"
                        s.dest = P and P:Nearest("mail") or nil
                        s.items = {}
                        for _, m in ipairs(waiting) do s.items[#s.items + 1] = ("collect %d %s"):format(m.n, m.name) end
                    end
                    return true
                end
            end
        end)() then
    else s.text = "All done!" end
    return s
end

-- The mailbox step when it's for the plan's materials: "Get Linen Cloth from the mailbox", with what
-- each material still needs and where it is
function Next:MailMatsStep(s, entries, planMail)
    local rows = self:MissingMats(entries)
    local first = planMail[1]
    s.text = ("Get %s from the mailbox"):format(first.name)
    s.cat = "Mail"
    s.items, s.forText = {}, nil
    local lines = {}
    for _, r in ipairs(rows or {}) do s.items[#s.items + 1] = r.line; lines[#lines + 1] = r.tip end
    if #lines == 0 then
        for _, m in ipairs(planMail) do
            s.items[#s.items + 1] = ("collect %d %s"):format(m.n, m.name)
            lines[#lines + 1] = ("%d %s: in your mailbox"):format(m.n, m.name)
        end
    end
    s.matsTip = "Your plan still needs, in your bags:\n" .. table.concat(lines, "\n")
    return s
end

-- The plan's materials (and what its own crafted parts are made from) bought on the AH and still
-- waiting in the mail, that your bags don't hold enough of yet: { id, name, n }
function Next:PlanMailWaiting(entries)
    local out = {}
    if not entries or #entries == 0 or not PC.MailPending then return out end
    local ok, list = pcall(PC.CombinedShoppingList, PC, entries, 1)
    if not ok or type(list) ~= "table" then return out end
    for _, it in ipairs(list) do
        if it.id and not it.tool then
            local short = (it.need or 0) - PC:BagCount(it.id)
            local mail = PC:MailPending(it.id)
            if short > 0 and mail > 0 then
                out[#out + 1] = { id = it.id, name = PC:ItemName(it.id) or ("item " .. it.id), n = math.min(mail, short) }
            end
        end
    end
    return out
end

-- What the plan's crafts still need in your bags, and where each one is: { name, id, n, where, line, tip, cat }
-- where = "mail" | "bank" | "vendor" | "ah". The first stop: mailbox, then bank, then buying.
function Next:MissingMats(entries)
    local ok, list = pcall(PC.CombinedShoppingList, PC, entries, 1)
    if not ok then return {} end
    local rows, best = {}, nil
    local rank = { mail = 1, bank = 2, vendor = 3, ah = 4, stopped = 5 }
    local cats = { mail = "Mail", bank = "Bank", vendor = "Vendor", ah = "AH", stopped = "AH" }
    for _, it in ipairs(list or {}) do
        if not it.craft and not it.tool and (it.need or 0) > 0 and it.id then
            local short = it.need - PC:BagCount(it.id)
            if short > 0 then
                local name = PC:ItemName(it.id) or ("item " .. it.id)
                local parts, where = {}, nil
                local mail = math.min(PC:MailPending(it.id), short)
                if mail > 0 then parts[#parts + 1] = mail .. " in your mailbox"; short = short - mail; where = where or "mail" end
                local bank = (PC.Bank and PC.Bank.Count) and math.min(PC.Bank:Count(it.id), short) or 0
                if bank > 0 then parts[#parts + 1] = bank .. " in your bank"; short = short - bank; where = where or "bank" end
                local buyAt
                if short > 0 then
                    buyAt = (it.src == "Vendor") and "vendor" or "ah"
                    -- (what would take the craft under the minimum profit isn't bought: no trip for it)
                    local vc = buyAt == "vendor" and PC:VendorCost(it.id)
                    local can, _, pwhy = PC:ProfitableBuyQty(it.id, short, vc and { { p = vc, q = short } } or nil)
                    if pwhy == "profit" and can < short then
                        parts[#parts + 1] = ("%d not bought: under %d%% profit"):format(short - can, PC:MinProfitPct())
                        short = can
                        if short <= 0 then where = where or "stopped" end
                    end
                end
                if short > 0 then
                    local v = buyAt == "vendor" and PC.Places and PC.Places:Nearest("vendor", it.id)
                    parts[#parts + 1] = ("buy %d %s"):format(short, buyAt == "vendor" and ("from " .. ((v and v.name) or "a vendor")) or "at auction")
                    where = where or buyAt
                end
                local need = it.need - PC:BagCount(it.id)
                local r = { id = it.id, name = name, n = (where == "vendor" or where == "ah") and short or need, where = where,
                    cat = (where == "stopped" and buyAt == "vendor") and "Vendor" or cats[where], line = ("get %d %s: %s"):format(need, name, table.concat(parts, ", ")),
                    tip = ("%d %s: %s"):format(need, name, table.concat(parts, ", ")) }
                rows[#rows + 1] = r
                if not best or rank[where] < rank[best.where] then best = r end
            end
        end
    end
    return rows, best
end

-- Buy the flips' materials, or take the flips out of the plan
-- vendor flips: said yes once for this plan, it stays yes (a reload doesn't ask again)
function Next:FlipsOK()
    local name = PC:PlanName()
    return Next.flipsOK == name or (PC.cdb and PC.cdb.flipsOK == name)
end
function Next:FlipsGo()
    Next.flipsOK = PC:PlanName()
    if PC.cdb then PC.cdb.flipsOK = Next.flipsOK end
    PC.Buy:Say("Vendor flips: buying their materials.")
    PC:RefreshUI()
end
function Next:FlipsSkip(flips)
    local plan = PC:CurrentPlan()
    -- kept, so a skip can be undone (/pc undo puts them back with their counts)
    local removed = {}
    for _, e in ipairs(flips or {}) do
        if plan[e.id] then removed[e.id] = plan[e.id] end
        plan[e.id] = nil
    end
    if PC.cdb then PC.cdb.lastSkip = { plan = PC:PlanName(), items = removed, t = time() } end
    PC.Buy:Say(("Skipped %d vendor flip%s: taken out of the plan. Changed your mind? Type /pc undo to put them back."):format(#flips, #flips == 1 and "" or "s"))
    Next.flipsOK = nil
    if PC.cdb then PC.cdb.flipsOK = nil end
    PC:RefreshUI()
end
function Next:UndoFlipsSkip()
    local u = PC.cdb and PC.cdb.lastSkip
    if not u or not next(u.items or {}) then return PC.Buy:Say("Nothing to undo.") end
    if u.plan ~= PC:PlanName() then return PC.Buy:Say(("That skip was in plan \"%s\": switch to it first."):format(tostring(u.plan))) end
    local plan = PC:CurrentPlan()
    local names = {}
    for id, n in pairs(u.items) do
        plan[id] = (plan[id] or 0) + n
        local r = PC.cdb.recipes[id]
        names[#names + 1] = n .. " " .. (r and r.name or ("recipe " .. id))
    end
    PC.cdb.lastSkip = nil
    Next.flipsOK = PC:PlanName(); PC.cdb.flipsOK = Next.flipsOK -- you want them: no asking again
    if PC.UI then PC.UI.allEntries = nil end
    PC.Buy:Say("Put back in the plan: " .. table.concat(names, ", ") .. ".")
    PC:RefreshUI()
end

-- Short of gold and there's mail: it may well be gold from AH sales, so the mailbox comes first
-- (nearest one; at the mailbox, collect). Returns true when it set the step.
function Next:MailForGold(s, why)
    do return false end -- the mailbox only for the plan's materials
    local M = PC.Mail
    if not M or not M:HasNew() or (M:Snoozed() and not M:Open()) then return false end
    -- already looked since this mail came in (the rest is letters, not gold): don't walk back for it
    if not M:Open() and M.lastVisit and (not M.arrived or M.arrived <= M.lastVisit) then return false end
    if M:Open() then
        if M:Count() == 0 then return false end
        s.text = "Collect auction mail"
        s.tip = why
        s.items = { "collect gold from your sales" }
        s.run = function() M:Collect() end
        return true
    end
    s.text = "Go to the mailbox"
    s.tip = why
    s.items = { "collect gold from your sales" }
    s.cat = nil
    local P = PC.Places
    local p = P and P:Nearest("mail")
    if p then s.dest = p; s.tip = s.tip .. "\n" .. P:Describe(p) end
    return true
end

-- Professions not looked at in the last week (or ever): { name, skillLine }. Gathering ones without a
-- window (Herbalism, Skinning, Fishing, Archaeology) aren't asked for; Mining is (its smelting window).
Next.NO_WINDOW = { [182] = true, [393] = true, [356] = true, [794] = true,
    Herbalism = true, Skinning = true, Fishing = true, Archaeology = true }
Next.CHECKIN_EVERY = 7 * 86400
function Next:StaleProfessions()
    local out = {}
    local seen = PC.cdb.profSeen or {}
    for skillLine, pr in pairs(PC.cdb.professions or {}) do
        if pr.name and not self.NO_WINDOW[skillLine] and not self.NO_WINDOW[pr.name] then
            local t = seen[pr.name]
            if not t or time() - t > self.CHECKIN_EVERY then out[#out + 1] = { name = pr.name, skillLine = skillLine, t = t or 0 } end
        end
    end
    table.sort(out, function(a, b) if a.t ~= b.t then return a.t < b.t end return a.name < b.name end)
    return out
end

-- Short, generic words for the button: what kind of step it is. The steps list above says exactly what.
Next.LABELS = {
    { "^Get .+ from the mailbox$", "Travel to the mailbox" }, { "^Get .+ from the bank$", "Travel to the bank" },
    { "^Buy %d+ .+ at auction$", "Travel to the Auction House" }, { "^Buy %d+ .+ at a vendor$", "Travel to a vendor" },
    { "^Buy %d+ .+ from .+$", "Travel to the vendor" }, { "^Stopped buying", "Under minimum profit" },
    { "^Waiting for the Auction House", "Waiting for the Auction House" }, { "^Buying from vendor", "Buying..." },
    { "^Bank: take %d+, store", "Bank items" }, { "^Bank: take", "Take from bank" }, { "^Bank: store", "Store items" },
    { "^Go to the bank", "Travel to the bank" }, { "^Go to the mailbox", "Travel to the mailbox" },
    { "^Go to the Auction House", "Travel to the Auction House" }, { "^Visit a vendor", "Travel to a vendor" }, { "^Find a ", "Travel to a station" },
    { "^Find %d", "Find materials" },
    { "^Collect auction mail", "Collect mail" }, { "^Buy from vendor", "Buy materials" },
    { "^Buy %a+: ", "Buy recipe" }, { "^Buy a .+ at a vendor$", "Buy tool at vendor" },
    { "^Buy a ", "Buy tool" }, { "^Buy ", "Buy materials" }, { "^Train ", "Train recipe" },
    { "^Confirm ", "Confirm purchase" }, { "^Post all", "Post items" }, { "^Post %d+ .* yourself", "Post items yourself" }, { "^Post ", "Post items" },
    { "^Cancel ", "Cancel auction" }, { "^Craft ", "Craft" }, { "^Crafting ", "Crafting..." },
    { "^Sell back", "Sell leftovers" }, { "^Sell spare", "Sell spare items" }, { "^Sell %d+ crafted", "Sell items" }, { "^Vendor spare", "Sell spare items" },
    { "^Get materials for", "Get materials" }, { "^Get a ", "Get a tool" }, { "^Open ", "Open professions" },
    { "^Need .* to post", "Not enough gold to post" },
    { "isn't in stock$", "Try later" }, { "^Disenchant ", "Disenchant" }, { "^Start crafting", "Start crafting" }, { "^Too many .*: disenchant", "Disenchant extras" }, { "^Bags full: purge crafted", "Purge crafted?" }, { "^Bags full: purge materials", "Purge materials?" }, { "^Bags full: make space", "Make space" }, { "^Too many .*: vendor", "Vendor extras" }, { "^Go to ", "Travel" }, { "^Get ", "Get recipe" },
}
-- a step that sends you somewhere (yellow button), as opposed to one you do here (red)
-- In a city, or standing at an AH, bank, mailbox or vendor: chores (bank, mail, selling, undercuts)
-- can be asked for. Out in the world, only your plan runs.
function Next:Town()
    if PC.ahOpen or PC.merchantOpen then return true end
    if PC.Bank and PC.Bank.Open and PC.Bank:Open() then return true end
    if PC.Mail and PC.Mail.Open and PC.Mail:Open() then return true end
    return PC.Places and PC.Places.InCity and PC.Places:InCity() or false
end

function Next:IsTravel(s)
    if not s then return false end
    if s.guide then return s.travel and true or false end -- the guide says: going somewhere = yellow
    if s.flying then return true end -- on a flight: nothing to click, a going step (yellow)
    if s.useItem then return false end -- the click does it (your Hearthstone): a doing step
    if (self:Label(s) or ""):find("^Travel") then return true end
    return (s.dest and not s.run) and true or false
end

function Next:Label(s)
    if s and s.guide then return s.label or s.text or "" end
    if s and s.label and s.label ~= "" then return s.label end -- a travel leg says its own
    local t = s and s.text or ""
    -- travel legs: the button says how ("Fly to Orgrimmar", "Take the zeppelin")
    local city = t:match("^Fly to (.+)$")
    if city then return "Fly to " .. city end
    if t:find("^Flying") then return t end
    local ride = t:match("^Take the (%a+)")
    if ride then return "Take the " .. ride end
    local walkRide = t:match("^Walk to the (%a+)")
    if walkRide and (walkRide == "zeppelin" or walkRide == "boat" or walkRide == "tram" or walkRide == "portal") then return "Walk to the " .. walkRide end
    if t:find("^Walk to the flight master") then return "Walk to the flight master" end
    if t:find("^Walk to ") then
        if #t <= 34 then return t end
        local short = t:gsub(" %(.-%)$", "") -- the zone in brackets goes first when it's too long
        return #short <= 34 and short or "Walk there"
    end
    -- a batch running: the button says what's being crafted
    local q = Craft.quick
    if q and q.started and t:find("^Crafting ") then return ("Crafting %s"):format(q.e.r.name) end
    for _, m in ipairs(self.LABELS) do
        if t:find(m[1]) then return m[2] end
    end
    return t
end

-- The step you were on is saved so a reload or relog picks up where you left off
function Next:Remember(s)
    if not PC.cdb then return end
    if s and (s.run or s.dest) and s.text ~= "All done!" then
        PC.cdb.lastStep = { text = s.text, t = time() }
    else
        PC.cdb.lastStep = nil
    end
end

-- Right-click on the button: skip this step when it's one that can be skipped (undercut checks)
-- Colour a game button's own art (its left, middle and right pieces), leaving the text alone
function Next.TintButton(btn, c)
    if not btn or not btn.GetRegions then return end
    -- the button art is red, and a colour can only darken it (red x yellow is still red): take the
    -- colour out first (grey), then tint the grey. White = the normal red art back.
    local plain = c[1] >= 1 and c[2] >= 1 and c[3] >= 1
    local function paint(t)
        if not t then return end
        if t.SetDesaturated then t:SetDesaturated(not plain) end
        if t.SetVertexColor then t:SetVertexColor(c[1], c[2], c[3]) end
    end
    for _, r in ipairs({ btn:GetRegions() }) do
        if r.GetObjectType and r:GetObjectType() == "Texture" and r.GetDrawLayer then
            if r:GetDrawLayer() ~= "HIGHLIGHT" then paint(r) end
        end
    end
    for _, key in ipairs({ "Left", "Middle", "Right" }) do paint(btn[key]) end
    paint(btn.GetNormalTexture and btn:GetNormalTexture())
    paint(btn.GetPushedTexture and btn:GetPushedTexture())
end

function Next:PaintMin()
    local b = self.bar and self.bar.unfold
    if not b then return end
    b:Hide() -- replaced by the pull tab on top of the steps window
end

function Next:Skip()
    local s = self:Compute()
    if s.skip then Safe("skip", s.skip) else PC.Buy:Say("This task can't be skipped.") end
    PC:RefreshUI()
end

function Next:Run()
    local s = self:Compute()
    if s.run then Safe("Task Button", s.run) end
    PC:RefreshUI()
end

-- the key binding (Bindings.xml)
function ProfitCrafter_NextStep() Next:Run() end
BINDING_HEADER_PROFITCRAFTER = "ProfitCrafter"
BINDING_NAME_PROFITCRAFTER_NEXT = "Task Button"
BINDING_NAME_PROFITCRAFTER_STAR = "Add or remove a star where you stand"
function ProfitCrafter_MarkStar() if PC.Places and PC.Places.MarkStar then PC:Safe("star", PC.Places.MarkStar, PC.Places) end end

-- The Task Button's tooltip: the task in full, then the way there step by step (how long, each leg
-- with its distance), then what you'll do when you get there
function Next:TooltipLines(s, tip)
    local lines = { "Next task" }
    s = s or {}
    if s.text and s.text ~= "" then lines[#lines + 1] = "|cffffd100" .. s.text .. "|r" end
    local way = s.way
    if way and way.steps and #way.steps > 0 then
        local secs = math.min(way.secs or 0, 1e6)
        local t = secs < 90 and ("%d sec"):format(math.floor(secs + 0.5)) or ("%d min"):format(math.floor(secs / 60 + 0.5))
        lines[#lines + 1] = ("About %s from here, %d step%s."):format(t, #way.steps, #way.steps == 1 and "" or "s")
        for i, st in ipairs(way.steps) do lines[#lines + 1] = ("%d. %s"):format(i, st.text or "?") end
    end
    -- the rest of the tip (the quickest-way line and the "Then:" line are said above and below)
    for line in ((tip or (s.text and "" or "Does the next thing in your crafting plan.")) .. "\n"):gmatch("(.-)\n") do
        if line ~= "" and not (way and line:find("^Quickest %(")) and not line:find("^Then: ") then lines[#lines + 1] = line end
    end
    if s.forText and s.forText ~= "" and s.forText ~= s.text then lines[#lines + 1] = "|cff40ff40Then: " .. s.forText .. "|r" end
    local key = self:KeyText()
    lines[#lines + 1] = key and ("|cff888888Key: " .. key .. "|r") or "|cff888888Set a key in ProfitCrafter's settings.|r"
    return lines
end

-- Short key names for the key cap: PAGEDOWN -> PgDn, CTRL-F -> Ctrl-F
local SHORT = { PAGEDOWN = "PgDn", PAGEUP = "PgUp", INSERT = "Ins", DELETE = "Del", HOME = "Home", END = "End",
    SPACE = "Space", BACKSPACE = "Bksp", ENTER = "Enter", TAB = "Tab", CAPSLOCK = "Caps", ESCAPE = "Esc",
    BUTTON3 = "M3", BUTTON4 = "M4", BUTTON5 = "M5", MOUSEWHEELUP = "WhUp", MOUSEWHEELDOWN = "WhDn",
    NUMLOCK = "NumLk", PRINTSCREEN = "PrtSc", SCROLLLOCK = "ScrLk", PAUSE = "Pause" }
function Next:ShortKey(key)
    local mods, base = key:match("^(.*%-)([^%-]+)$")
    if not base then mods, base = "", key end
    base = SHORT[base] or base:gsub("^NUMPAD", "Num")
    mods = mods:gsub("SHIFT%-", "S-"):gsub("CTRL%-", "C-"):gsub("ALT%-", "A-")
    return mods .. base
end

function Next:KeyText()
    local key = GetBindingKey and GetBindingKey("PROFITCRAFTER_NEXT")
    return key
end

---------------------------------------------------------------------------
-- Floating Next step bar (move it while unlocked, lock it in settings)
---------------------------------------------------------------------------
-- Moving the bar (and the task list docked above it): press on the icon or the name tab, let go
function Next:BeginMove(button)
    local f = self.bar
    if not f or (button and button ~= "LeftButton") then return end
    if f.SetMovable then f:SetMovable(true) end
    f.moving = true
    f:StartMoving()
end
function Next:EndMove()
    local f = self.bar
    if not f or not f.moving then return end
    f.moving = false
    f:StopMovingOrSizing()
    local point, _, rel, x, y = f:GetPoint()
    PC.db.barPos = { point or "CENTER", (type(rel) == "string" and rel) or point or "CENTER", x or 0, y or 0 }
    if f.SetUserPlaced then f:SetUserPlaced(false) end -- we save the spot ourselves
    if PC.Synergy and PC.Synergy.Refresh then pcall(PC.Synergy.Refresh, PC.Synergy) end
    self:KeepOnScreenSoon()
end

-- Never off the screen: when the list grows, rolls out, or flips between above and below the button,
-- the whole window (button, list and the tabs on its edge) slides back onto the screen
function Next:KeepOnScreen(retry)
    local bar = self.bar
    if not bar or not bar:IsShown() or bar.moving or not UIParent then return end
    local top, bottom = bar:GetTop(), bar:GetBottom()
    if not top or not bottom then
        -- not placed yet (just after loading): look again in a moment
        if not retry and not self.keepRetry then
            self.keepRetry = true
            C_Timer.After(0.2, function() Next.keepRetry = nil; PC:Safe("keep on screen", Next.KeepOnScreen, Next, true) end)
        end
        return
    end
    -- the list's own height (always up to date), not where the game last drew it
    local list = PC.Steps and PC.Steps.f
    if list and list:IsShown() then
        local h = (list:GetHeight() or 0) + 16 -- plus the pull tab and name tab on its edge
        if PC.db.dropDown then bottom = bottom + 4 - h else top = top - 4 + h end
    end
    local screenTop = UIParent:GetTop() or 768
    local dy = 0
    if top > screenTop then dy = screenTop - top
    elseif bottom < 0 then dy = -bottom end
    if math.abs(dy) < 1 then return end
    local point, _, rp, x, y = bar:GetPoint()
    point, rp = point or "CENTER", rp or point or "CENTER"
    bar:ClearAllPoints()
    bar:SetPoint(point, UIParent, rp, x or 0, (y or 0) + dy)
    PC.db.barPos = { point, rp, x or 0, (y or 0) + dy }
end

-- (sizes settle on the next frame: look then)
function Next:KeepOnScreenSoon()
    if self.keepPending then return end
    self.keepPending = true
    C_Timer.After(0, function()
        Next.keepPending = nil
        PC:Safe("keep on screen", Next.KeepOnScreen, Next)
    end)
end

-- the icon by the button: SnuggleUp's while its guide runs, else ProfitCrafter's
Next.GUIDE_ICON = "Interface\\AddOns\\SnuggleUpForever\\Media\\IconClassic" -- (SnuggleUp's own Task Button icon)
function Next:IconPath()
    if PC.Guide and PC.Guide.Active and PC.Guide:Active() then return self.GUIDE_ICON end
    return PC.UI and PC.UI.MINIMAP_ICON or "Interface\\Icons\\INV_Misc_Coin_01"
end

function Next:CreateBar()
    if self.bar then return self.bar end
    local f = CreateFrame("Frame", "ProfitCrafterNextBar", UIParent, "BackdropTemplate")
    f:SetSize(380, 40)
    f:SetFrameStrata("MEDIUM")
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        f:SetBackdropColor(0.07, 0.05, 0.03, 0.92)
        f:SetBackdropBorderColor(0.78, 0.59, 0.18, 1)
    end
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(26, 26)
    f.icon:SetPoint("LEFT", 8, 0)
    -- the icon is the handle: click and hold to move the bar (and the steps above it); let go and it
    -- stays put. It does nothing else, and nothing else moves the window.
    f.list = CreateFrame("Button", nil, f)
    f.list:SetAllPoints(f.icon)
    f.list:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    -- press = pick it up, release = put it down (no drag threshold, and no lock setting in the way)
    f.list:RegisterForClicks("LeftButtonUp")
    f.list:SetScript("OnMouseDown", function(_, button) Next:BeginMove(button) end)
    f.list:SetScript("OnMouseUp", function() Next:EndMove() end)
    f.list:SetScript("OnHide", function() if f.moving then f.moving = false; f:StopMovingOrSizing() end end)
    f.list:SetScript("OnEnter", function(b)
        if PC.UI and PC.UI.ShowTooltip then PC.UI.ShowTooltip(b, { "Move", "Click and hold here to drag the window; let go and it stays there." }) end
    end)
    f.list:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    f.btn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.btn:SetSize(236, 24)
    f.btn:SetPoint("LEFT", f.icon, "RIGHT", 6, 0)
    f.btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f.btn:SetScript("OnClick", function(b, mouse)
        if mouse == "RightButton" then return Next:Skip() end
        local cur = Next:Compute()
        if cur.deItem or cur.useItem then
            -- the disenchant button sits on top of this one; landing here means it wasn't there yet
            local fine, why = false, "in combat"
            if PC.Synergy and not (InCombatLockdown and InCombatLockdown()) then
                local okc, a, e = pcall(PC.Synergy.Arm, PC.Synergy, b, cur.deItem or cur.useItem)
                fine, why = okc and a == true, (not okc and tostring(a)) or e or PC.Synergy.lastErr
            end
            PC.Print((cur.useItem and "Learn" or "Disenchant") .. ": the button wasn't ready (" .. (fine and "fixed now, click again" or ("|cffff5555" .. tostring(why or "unknown") .. "|r")) .. ").")
            return
        end
        if b.hint then
            -- a travel step: point the way again and say where and what
            local s = Next:Compute()
            if s.dest and PC.Places then PC.Places:Point(s.dest, s.text) end
            local lines = {}
            for line in ((s.tip or "") .. "\n"):gmatch("(.-)\n") do if line ~= "" then lines[#lines + 1] = line end end
            if #lines == 0 then lines[1] = s.dest and "Follow the arrow on your minimap." or "ProfitCrafter learns places the first time you use them." end
            PC:Note(s.text or "Next task", lines)
        else
            Next:Run()
        end
    end)
    f.btn:SetScript("OnEnter", function(b)
        if PC.UI and PC.UI.ShowTooltip then PC.UI.ShowTooltip(b, Next:TooltipLines(b.step, b.tip)) end
    end)
    f.btn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    -- your key, drawn as a little key cap
    f.key = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.key:SetSize(46, 22)
    f.key:SetPoint("LEFT", f.btn, "RIGHT", 10, 0) -- 10 from the button, 10 from the X (the bar is sized to match)
    if f.key.SetBackdrop then
        f.key:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
        f.key:SetBackdropColor(0.85, 0.83, 0.78, 1)
        f.key:SetBackdropBorderColor(0.45, 0.42, 0.38, 1)
    end
    f.key.text = f.key:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.key.text:SetPoint("CENTER", 0, 1)
    f.key.text:SetTextColor(0.12, 0.1, 0.08)
    -- close: hide the bar for now; it comes back when your next step changes
    -- Skip: shown when the step can be skipped (like the undercut check); same as right-clicking
    f.skipBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.skipBtn:SetSize(44, 22)
    f.skipBtn:SetPoint("LEFT", f.btn, "RIGHT", 4, 0)
    f.skipBtn:SetText("Skip")
    f.skipBtn:SetScript("OnClick", function() Next:Skip() end)
    f.skipBtn:SetScript("OnEnter", function(b)
        if PC.UI and PC.UI.ShowTooltip then PC.UI.ShowTooltip(b, { "Skip this task", b.tip or "Skips it for now." }) end
    end)
    f.skipBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    f.skipBtn:Hide()
    f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.close:SetSize(22, 22)
    f.close:SetPoint("RIGHT", -8, 0)
    f.close:SetScript("OnClick", function()
        -- closed: that plan is over. A temporary plan is thrown away; the Task Button stays gone
        -- until you start another plan (or add to this one)
        if PC:IsTempPlan() and not (PC.Guide and PC.Guide:IsName(PC:PlanName())) then
            local plan = PC:CurrentPlan()
            if plan then wipe(plan) end
            Next.lastText = "All done!"
            PC:Safe("temp plans", PC.DropFinishedTempPlans, PC)
        end
        -- and what it had lined up to sell is cleared off the Sell page (the items stay in your bags)
        if PC.Sell and PC.Sell.Items and PC.cdb then
            local ok, items = pcall(PC.Sell.Items, PC.Sell)
            if ok and items then
                PC.cdb.sellClosed = PC.cdb.sellClosed or {}
                for _, it in ipairs(items) do
                    if (it.have or 0) > 0 then PC.cdb.sellClosed[it.id] = (PC.cdb.sellClosed[it.id] or 0) + it.have end
                end
            end
        end
        local n = 0
        for _ in pairs(PC:CurrentPlan() or {}) do n = n + 1 end
        Next.dismissed = { plan = PC:PlanName(), n = n }
        PC:RefreshUI()
        Next.wanted = nil
        if PC.cdb then PC.cdb.barClosed = Next.dismissed end
        f:Hide()
        if PC.Steps then PC.Steps:Hide() end -- the steps (and NOW line) go with the button
    end)
    f.close:SetScript("OnEnter", function(b)
        if PC.UI and PC.UI.ShowTooltip then PC.UI.ShowTooltip(b, { "Close" }) end
    end)
    f.close:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    -- folded steps list: a small "Tasks" handle on top of the bar opens it again
    f.unfold = CreateFrame("Button", nil, f, "BackdropTemplate")
    f.unfold:SetSize(70, 16)
    f.unfold:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 12, -3)
    if f.unfold.SetBackdrop then
        f.unfold:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
        f.unfold:SetBackdropColor(0.07, 0.05, 0.03, 0.92)
        f.unfold:SetBackdropBorderColor(0.78, 0.59, 0.18, 1)
    end
    f.unfold.text = f.unfold:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.unfold.text:SetPoint("CENTER", 0, 0)
    f.unfold.text:SetText("Tasks |TInterface\\Buttons\\Arrow-Up-Up:12:12|t")
    f.unfold:SetScript("OnClick", function() if PC.Steps then PC.Steps:ToggleMin() end end)
    f.unfold:SetScript("OnEnter", function(b)
        if PC.UI and PC.UI.ShowTooltip then PC.UI.ShowTooltip(b, { "Show all tasks", "Every task of the plan, in order." }) end
    end)
    f.unfold:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    f.unfold:Hide()
    f:EnableMouse(true)
    f:SetMovable(true) -- moved only by its icon (see above)
    f:SetClampedToScreen(true)
    local pos = PC.db.barPos
    if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 190) end
    self.bar = f
    return f
end

-- Map pin + minimap arrow for the step's destination (re-applied each refresh in case the game cleared it)
-- The NOW step's words, as the arrows, pins and TomTom show them (no "(N yd)": the yards follow it)
function Next:PinText(s)
    if not s then return nil end
    -- (a long list of things to do there: the first three, and how many more)
    local short = s
    if s.items and #s.items > 3 then
        short = setmetatable({ items = { s.items[1], s.items[2], s.items[3], ("and %d more"):format(#s.items - 3) } }, { __index = s })
    end
    local t = (PC.Steps and PC.Steps.NowText) and PC.Steps:NowText(short) or s.text or ""
    t = t:gsub("%s*%(%d+ yd%)", "")
    return t ~= "" and t or nil
end

-- The same, for the window under the screen arrow: the step, then one line for each thing to do
-- ("get 2 Light Leather: 2 in your mailbox" reads "2 Light Leather (in your mailbox)")
function Next:PinDetail(s)
    if not s then return nil end
    local title = s.text
    if not title or title == "" then return nil end
    title = title:gsub("%s*%(%d+ yd%)", "")
    local lines = {}
    for _, t in ipairs(s.items or {}) do
        local n, name, m = t:match("^[Gg]et (%d+) (.-): (%d+) in your mailbox$")
        if n and n == m then t = ("%s %s (in your mailbox)"):format(n, name) end
        t = t:gsub("%s*%(%d+ yd%)", "")
        lines[#lines + 1] = t:sub(1, 1):upper() .. t:sub(2)
    end
    if s.via then lines[#lines + 1] = "First: " .. s.via end
    return { title = title, lines = lines }
end

function Next:ApplyPin(s)
    if not PC.Places or not PC:RouteOn() then return end
    if s.guide and not s.dest then return end -- the guide on a flight: the pin stays where it was
    if s.dest then
        PC.Places:Point(s.pin or s.dest, self:PinText(s), self:PinDetail(s))
    elseif PC.Places.current then
        PC.Places:ClearPin()
    end
end

-- No plan loaded: nothing in the plan in use, and nothing it made or took on left to sell (a guide
-- that's running counts as a plan)
function Next:NoPlan()
    local G = PC.Guide
    if G and G.Active and G:Active() then return false end
    if next(PC:CurrentPlan() or {}) ~= nil then return false end
    if PC.PlanGoodsLeft and PC:PlanGoodsLeft() then return false end
    return true
end

function Next:OtherBusy()
    for _, k in ipairs({ "MostlyNotBrokenBusy", "MostlyNotBrokenWay" }) do
        local w = _G[k]
        if w and w.by and w.by ~= PC.NAME then return true end
    end
    return false
end

function Next:UpdateBar()
    if PC.inCombat then return end -- in combat ProfitCrafter is off the screen and does nothing
    -- Everything worked out here is worked out once and shared (the step, the task list, the lists
    -- of what to buy). Called on its own - walking, arriving, a lift ride - there was no such sharing
    -- and the whole lot was worked out twice over, which is where a good half of the delay came from.
    if not PC:Memo() then return PC:WithMemo(Next.UpdateBar, self) end
    local show = On("nextBar", true)
    if not show then
        if self.bar then self.bar:Hide() end
        return
    end
    local f = self:CreateBar()
    local s = PC:Timed("compute", self.Compute, self)
    self:Remember(s)
    self.shown = s -- the step on the bar right now (the star over the NPC goes by it)
    if PC.Places and PC.Places.CheckStar then pcall(PC.Places.CheckStar, PC.Places) end -- NPCs already in view
    -- shows while anything in the plan still needs doing (a hint says where to go);
    -- hidden when it's all done, or when you closed it, until the next step changes
    -- a step that sends you somewhere (it has a map pin) is work too: the bar shows it
    local hasWork = s.run ~= nil or s.dest ~= nil or s.deItem ~= nil or s.useItem ~= nil or ((s.left or 0) > 0 and s.text ~= "All done!")
    -- with a plan the bar stays put, even on a step with nothing to click (it never vanishes
    -- mid-run, e.g. right after buying); only no plan at all, or the X, hides it
    -- nothing to do (out questing, or the plan's finished): no bar and no task list at all
    local showBar = s.text ~= "Set up a plan" and s.text ~= "All done!" and not s.quiet
    self.lastText = s.text
    -- the map pin points the way only for a step you can see (or that you hid with the X):
    -- never a pin with no instruction
    if hasWork then self:ApplyPin(s) elseif PC.Places and PC.Places.current then PC.Places:ClearPin() end
    -- closed with the X (kept over a reload): back when you arrive in a city
    if not self.closedLoaded and PC.cdb then self.closedLoaded = true; if self.dismissed == nil then self.dismissed = PC.cdb.barClosed end end
    if type(self.dismissed) ~= "table" then self.dismissed = self.dismissed and { out = true } or nil end
    -- closed with the X, but there are greens to disenchant now: that's new work, so it's back
    if self.dismissed and (s.deItem or s.leftover) then self.dismissed = nil end
    -- (the same for an empty plan: anything to do then is left over from a finished plan)
    if self.dismissed and hasWork and showBar and next(PC:CurrentPlan() or {}) == nil
        and not (PC.Guide and PC.Guide.Active and PC.Guide:Active() and not s.leftover) then
        self.dismissed = nil
    end
    if self.dismissed then
        -- it comes back only for a new plan, or when more is added to the one you closed
        local n = 0
        for _ in pairs(PC:CurrentPlan() or {}) do n = n + 1 end
        if self.dismissed.plan == nil then self.dismissed.plan, self.dismissed.n = PC:PlanName(), n end -- closed before this version
        if self.dismissed.plan ~= PC:PlanName() or n > (self.dismissed.n or 0) then self.dismissed = nil
        else self.dismissed.n = n end
    end
    if PC.cdb then PC.cdb.barClosed = self.dismissed end
    -- (kept with the saved settings, never shown: what the Task Button decided and why)
    if PC.db then
        local d = { t = date("%H:%M:%S"), v = PC.VERSION, text = tostring(s.text), plan = tostring(PC:PlanName()), showBar = showBar and true or false,
            hasWork = hasWork and true or false, closed = self.dismissed and true or false, wanted = self.wanted and true or false,
            city = PC.Places and PC.Places:InCity() and true or false, de = s.deItem and true or false, leftover = s.leftover and true or false,
            guide = PC.Guide and PC.Guide.Active and PC.Guide:Active() and true or false, items = {} }
        local okI, items = pcall(Sell.Items, Sell)
        for _, it in ipairs(okI and items or {}) do
            if #d.items < 12 then
                local Sy = PC.Synergy
                d.items[#d.items + 1] = { id = it.id, have = it.have, sellN = it.sellN, hold = it.hold and true or false, vendor = it.vendor and true or false,
                    price = it.price, cap = Sell.PostCap and Sell:PostCap(it.id), canDE = Sy and Sy:CanDisenchant(it.id) and true or false,
                    deVal = Sy and Sy:Value(it.id), vend = PC:SellPrice(it.id) }
            end
        end
        d.deQueue = PC.cdb and PC.cdb.deQueue
        -- where it thinks you are, and the first legs of the way it worked out
        local T = PC.Travel
        if T then
            local okH, here = pcall(T.Here, T)
            if okH and here then
                d.map, d.x, d.y = here.map, here.x, here.y
                d.z = here.z
                d.station = s.stationDiag
                d.tbZ = PC.cdb and PC.cdb.tbZ and { hi = PC.cdb.tbZ.hi, lo = PC.cdb.tbZ.lo } or nil
                d.liftSide = PC.cdb and PC.cdb.liftSide
                d.side = tostring(T:SideHere(here.map))
                d.ruins = T.InRuins and T:InRuins() and true or false
            end
            d.zone = GetRealZoneText and GetRealZoneText() or ""
            d.sub = GetSubZoneText and GetSubZoneText() or ""
            d.legs = {}
            for i, st in ipairs(s.way and s.way.steps or {}) do
                if i <= 6 then d.legs[i] = tostring(st.how) .. ": " .. tostring(st.text) end
            end
            d.dest = s.dest and { map = s.dest.map, x = s.dest.x, y = s.dest.y, name = s.dest.name } or nil
        end
        PC.db.diag = d
    end
    -- out of a city it only shows when you opened it yourself
    if not showBar then self.wanted = nil end
    local outside = not (PC.Places and PC.Places:InCity())
    -- another MostlyNotBroken add-on is in use right now (Fishmonger's windows open, or it's showing
    -- the way), or there's no plan loaded: the Task Button and its task list don't show, whatever the
    -- step would be (selling, learning a recipe, disenchanting, mail)
    if self:OtherBusy() or self:NoPlan() then
        f:Hide()
        if PC.Steps and PC.Steps.Hide then PC.Steps:Hide() end
        return
    end
    if not showBar or self.dismissed or (outside and not self.wanted) then
        f:Hide()
        -- with no plan the task list goes too, docked or not
        if PC.Steps and (PC.Steps.docked or not showBar) then PC.Steps:Hide() end
        return
    end
    f:Show()
    self:PaintMin()
    -- the full list of tasks always rides along above the task button (the -/+ folds it away)
    if PC.Steps then PC.Steps:ShowDocked() end
    -- small spot: the plain anvil-and-hammer icon reads better than the lettered one
    f.icon:SetTexture(Next:IconPath())
    f.btn.tip = s.tip
    f.btn.step = s
    Next:ApplyPin(s)
    -- travel steps (go somewhere, nothing to click) show a yellow button; doing steps stay red
    Next.TintButton(f.btn, Next:IsTravel(s) and { 1, 0.9, 0.2 } or { 1, 1, 1 })
    -- room for Skip when the step can be skipped
    if s.skip then
        f.btn:SetWidth(188)
        f.skipBtn.tip = s.skipTip or ((s.text or ""):find("undercut") and "Not this visit: asked again next time you're in a city." or nil)
        f.skipBtn:Show()
    else
        f.btn:SetWidth(236)
        f.skipBtn:Hide()
    end
    -- the button says what kind of step it is ("Store items", "Travel to the bank"); the steps list
    -- above it says exactly what (and the tooltip)
    PC.UI.FitText(f.btn, Next:Label(s))

    f.btn.tip = (s.text and s.text ~= Next:Label(s)) and ("|cffffd100" .. s.text .. "|r" .. (s.tip and ("\n" .. s.tip) or "")) or s.tip
    if PC.UI and PC.UI.IsSkillPlan and PC.UI:IsSkillPlan() then
        f.btn.tip = (f.btn.tip or "") .. "\n|cffff8040Skill-up plan: built to raise skill, not to make a profit.|r"
    end
    -- the step you're on is always the bottom row of the list
    if PC.Steps and self.shownText ~= s.text then self.shownText = s.text; PC.Steps.offset = 0 end
    f.btn:SetEnabled(true)
    -- a hint ("Go to the AH to buy") isn't greyed out: clicking it opens your plan
    f.btn.hint = s.run == nil
    local key = self:KeyText()
    -- the key sits after whatever is last in the row: Skip when it shows, else the button
    f.key:ClearAllPoints()
    f.key:SetPoint("LEFT", s.skip and f.skipBtn or f.btn, "RIGHT", 10, 0)
    if key then
        f.key.text:SetText(Next:ShortKey(key))
        local kw = math.max(((f.key.text.GetStringWidth and f.key.text:GetStringWidth()) or 30) + 14, 30)
        f.key:SetWidth(kw)
        f.key:Show()
        f:SetWidth(8 + 26 + 6 + 240 + 6 + kw + 8 + 22 + 10)
    else
        f.key:Hide()
        f:SetWidth(8 + 26 + 6 + 240 + 8 + 22 + 10)
    end
    -- disenchanting needs a real click on a secure button: lay it over this one for the step
    -- (last, and guarded: nothing about it can stop the rest of the bar from drawing)
    if PC.Synergy then
        local ok, err = pcall(function()
            if s.deItem then PC.Synergy:Arm(f.btn, s.deItem)
            elseif s.useItem then PC.Synergy:Arm(f.btn, s.useItem)
            else PC.Synergy:Refresh() end
        end)
        if not ok and not self.deErr then self.deErr = true; PC.Print("|cffff5555Disenchant button: " .. tostring(err) .. "|r") end
    end
end

-- "Set key": press a key to bind Next step to it
function Next:CaptureKey(onDone)
    local cap = self.capture
    if not cap then
        cap = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        cap:SetSize(300, 60)
        cap:SetPoint("CENTER")
        cap:SetFrameStrata("FULLSCREEN_DIALOG")
        if cap.SetBackdrop then
            cap:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
            cap:SetBackdropColor(0.07, 0.05, 0.03, 0.97)
            cap:SetBackdropBorderColor(1, 0.82, 0, 1)
        end
        cap.text = cap:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        cap.text:SetPoint("CENTER")
        cap.text:SetText("Press a key for the Task Button\n|cff888888(Escape cancels)|r")
        cap:EnableKeyboard(true)
        cap:SetScript("OnKeyDown", function(c, key)
            if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL" or key == "LALT" or key == "RALT" then return end
            c:Hide()
            if key == "ESCAPE" then return end
            local combo = key
            if IsAltKeyDown and IsAltKeyDown() then combo = "ALT-" .. combo end
            if IsControlKeyDown and IsControlKeyDown() then combo = "CTRL-" .. combo end
            if IsShiftKeyDown and IsShiftKeyDown() then combo = "SHIFT-" .. combo end
            if InCombatLockdown and InCombatLockdown() then return PC.Print("Can't change key bindings in combat.") end
            local old = GetBindingKey and GetBindingKey("PROFITCRAFTER_NEXT")
            if old and SetBinding then SetBinding(old) end
            if SetBinding and SetBinding(combo, "PROFITCRAFTER_NEXT") then
                if SaveBindings and GetCurrentBindingSet then SaveBindings(GetCurrentBindingSet()) end
                PC.Print("The Task Button is now on " .. combo .. ".")
            end
            if c.onDone then c.onDone() end
            Next:UpdateBar()
        end)
        self.capture = cap
    end
    cap.onDone = onDone
    cap:Show()
end
