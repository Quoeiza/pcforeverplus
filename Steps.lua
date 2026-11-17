-- ProfitCrafter: the whole plan, step by step
--   Every step from here to done, in order, each tagged with what kind of step it is:
--     Mail - collect your mail          Bank - take out 40 Linen Cloth
--     Travel - walk to the AH (90 yd)   Travel - take the flight to Thunder Bluff
--     AH - buy 12 Linen Cloth           Vendor - buy 5 Coarse Thread
--     Craft - 20 Linen Bag              AH - post 20 Linen Bag
--   Untick a Craft line to leave that recipe out: every other step adjusts. Tick it to bring it back.
--   Opens from the icon on the Next step bar, or /pc steps.

local ADDON, ns = ...
local PC = ns.PC

local Steps = {}
PC.Steps = Steps

Steps.COLORS = {
    Mail = "40c0ff", Bank = "d8b060", Travel = "b8b8b8", Vendor = "ff9f40", Trainer = "c080ff", Drop = "ff7070", Quest = "ffff60",
    AH = "ffd100", Craft = "40ff40", Wait = "909090", Done = "40ff40", Equip = "40e0ff",
    Careful = "ff8000", Tip = "40c0ff", -- (the Cozy Sleeping Bag Guide's warnings)
}
Steps.ROWS = 40        -- most rows it can show (drag the top edge to choose)
Steps.DEFAULT_ROWS = 14
Steps.ROW_H = 18
Steps.NOW_H = 24 -- the NOW line at the bottom

local function Tag(cat) return ("|cff%s%s|r"):format(Steps.COLORS[cat] or "ffffff", cat) end
Steps.Tag = Tag

---------------------------------------------------------------------------
-- Skipping a recipe: it leaves the plan, and its count is remembered so ticking it brings it back
---------------------------------------------------------------------------
function Steps:Skipped()
    local cdb = PC.cdb
    cdb.skipCraft = cdb.skipCraft or {}
    local name = PC:PlanName() or "?"
    cdb.skipCraft[name] = cdb.skipCraft[name] or {}
    return cdb.skipCraft[name]
end

function Steps:SetSkipped(recipeID, skip)
    local plan, sk = PC:CurrentPlan(), self:Skipped()
    if skip then
        if plan[recipeID] then sk[recipeID] = plan[recipeID] end
        plan[recipeID] = nil
        if PC.Learn then PC.Learn:Unticked(recipeID) end
    else
        if sk[recipeID] then plan[recipeID] = sk[recipeID] end
        sk[recipeID] = nil
        if PC.Learn then PC.Learn:Ticked(recipeID) end
    end
    if PC.UI then PC.UI.allEntries = nil end
    PC:RefreshUI()
    self:Refresh()
end

---------------------------------------------------------------------------
-- Removing any task: the plan adjusts (and /pc undo puts it back)
--   craft from the plan     -> it leaves the plan (shown unticked: tick to bring it back)
--   make a material / disenchant for dust -> buy that material instead
--   buy a material          -> the crafts that need it leave the plan
--   post / sell an item     -> this plan doesn't sell it
--   bank / mailbox / undercut check -> skipped for an hour
---------------------------------------------------------------------------
function Steps:Remove(st)
    local rm = st and st.rm
    if not rm then return end
    local say
    if rm.kind == "craft" then
        self:SetSkipped(rm.id, true)
        PC:PushUndo({ kind = "unskip", ids = { rm.id } })
        say = "Taken out of the plan: " .. ((PC.cdb.recipes[rm.id] or {}).name or "that craft") .. "."
    elseif rm.kind == "make" and rm.id then
        PC:BuyOnly()[rm.id] = true
        PC:PushUndo({ kind = "make", id = rm.id })
        say = ("%s: bought instead of made from now on."):format(PC:ItemName(rm.id) or "That material")
    elseif rm.kind == "buy" then
        -- the plan's crafts that need any of these (directly, or through a material they make)
        local want = {}
        for _, id in ipairs(rm.ids or {}) do want[id] = true end
        local hit, names = {}, {}
        for _, e in ipairs(PC.UI:PlanEntries()) do
            if not e.sub then
                local ok, list = pcall(PC.CombinedShoppingList, PC, { e }, 1)
                for _, it in ipairs(ok and list or {}) do
                    if want[it.id] and (it.need or 0) > 0 then hit[#hit + 1] = e.id; names[#names + 1] = e.r.name; break end
                end
            end
        end
        for _, id in ipairs(hit) do self:SetSkipped(id, true) end
        if #hit > 0 then PC:PushUndo({ kind = "unskip", ids = hit }) end
        say = #hit > 0 and ("Taken out of the plan (they needed it): %s."):format(table.concat(names, ", "))
            or "Nothing in the plan needs that any more."
    elseif rm.kind == "sell" and rm.id then
        PC:NoSell()[rm.id] = true
        PC:PushUndo({ kind = "sell", id = rm.id })
        say = ("%s: not sold for this plan."):format(PC:ItemName(rm.id) or "That item")
    elseif rm.kind == "dequeue" and rm.id then
        if PC.cdb.deQueue then PC.cdb.deQueue[rm.id] = nil end
        say = ("%s: not disenchanted."):format(PC:ItemName(rm.id) or "That item")
    elseif rm.kind == "bank" then
        PC.cdb.bankSkipUntil = time() + 3600
        PC:PushUndo({ kind = "bank" })
        say = "No bank trips for an hour."
    elseif rm.kind == "mail" then
        if PC.Mail and PC.Mail.Snooze then PC.Mail:Snooze() end
        say = "Mailbox skipped for an hour."
    elseif rm.kind == "undercut" then
        if PC.Undercut and PC.Undercut.SkipScan then PC.Undercut:SkipScan() end
        say = "Undercut check skipped."
    elseif rm.kind == "equip" and rm.id then
        if PC.cdb.gearKeep then PC.cdb.gearKeep[rm.id] = nil end
        PC:PushUndo({ kind = "equip", id = rm.id })
        say = ("%s: not put on. It's sold like anything else now."):format(PC:ItemName(rm.id) or "That item")
    end
    if PC.UI then PC.UI.allEntries = nil end
    if say then PC.Buy:Say(say .. " |cff888888(/pc undo puts it back)|r") end
    PC:RefreshUI()
    self:Refresh()
end

---------------------------------------------------------------------------
-- The tick box on the left of a task: ticked = do it, unticked = skip it. A skipped task stays
-- on the list, greyed, so it can be ticked again; it goes when the rest of the list is done.
---------------------------------------------------------------------------
Steps.ghosts = {}
function Steps:Skip(st, idx)
    local rm = st and st.rm
    if not rm then return end
    local cdb = PC.cdb
    local undo
    if rm.kind == "craft" then
        self:SetSkipped(rm.id, true) -- a craft stays on the list by itself
        if PC.UI then PC.UI.allEntries = nil end
        PC:RefreshUI(); self:Refresh()
        return
    elseif rm.kind == "make" and rm.id then
        PC:BuyOnly()[rm.id] = true
        undo = function() PC:BuyOnly()[rm.id] = nil end
    elseif rm.kind == "buy" then
        local want = {}
        for _, id in ipairs(rm.ids or {}) do want[id] = true end
        local hit = {}
        for _, e in ipairs(PC.UI:PlanEntries()) do
            if not e.sub then
                local ok, list = pcall(PC.CombinedShoppingList, PC, { e }, 1)
                for _, it in ipairs(ok and list or {}) do
                    if want[it.id] and (it.need or 0) > 0 then hit[#hit + 1] = e.id; break end
                end
            end
        end
        for _, id in ipairs(hit) do self:SetSkipped(id, true) end
        undo = function() for _, id in ipairs(hit) do Steps:SetSkipped(id, false) end end
    elseif rm.kind == "sell" and rm.id then
        PC:NoSell()[rm.id] = true
        undo = function() PC:NoSell()[rm.id] = nil end
    elseif rm.kind == "dequeue" and rm.id then
        local old = cdb.deQueue and cdb.deQueue[rm.id]
        if cdb.deQueue then cdb.deQueue[rm.id] = nil end
        cdb.extraSkip = cdb.extraSkip or {}
        cdb.extraSkip[rm.id] = time() -- (and they aren't put straight back on the list)
        undo = function() cdb.deQueue = cdb.deQueue or {}; cdb.deQueue[rm.id] = old; cdb.extraSkip[rm.id] = nil end
    elseif rm.kind == "bank" then
        cdb.bankSkipUntil = time() + 3600
        undo = function() cdb.bankSkipUntil = nil end
    elseif rm.kind == "mail" then
        cdb.mailSnooze = time() + ((PC.Mail and PC.Mail.SNOOZE) or 3600)
        undo = function() cdb.mailSnooze = nil end
    elseif rm.kind == "undercut" then
        local old = cdb.undercutCheck
        local visit = PC.Undercut and PC.Undercut.Visit and PC.Undercut:Visit()
        if PC.Undercut and PC.Undercut.Done then PC.Undercut:Done() end
        undo = function() cdb.undercutCheck = old; if visit then visit.done = nil end end
    elseif rm.kind == "equip" and rm.id then
        local old = cdb.gearKeep and cdb.gearKeep[rm.id]
        if cdb.gearKeep then cdb.gearKeep[rm.id] = nil end
        undo = function() cdb.gearKeep = cdb.gearKeep or {}; cdb.gearKeep[rm.id] = old or time() end
    else
        return
    end
    self.ghosts[#self.ghosts + 1] = { key = self:TaskKey(st), cat = st.cat, text = st.text, idx = idx or 1, undo = undo, plan = PC:PlanName() }
    if PC.UI then PC.UI.allEntries = nil end
    PC:RefreshUI()
    self:Refresh()
end

function Steps:Unskip(st)
    local g = st and st.ghost
    if not g then return end
    for i, x in ipairs(self.ghosts) do if x == g then table.remove(self.ghosts, i) break end end
    if g.undo then pcall(g.undo) end
    if PC.UI then PC.UI.allEntries = nil end
    PC:RefreshUI()
    self:Refresh()
end

-- the skipped tasks go back on the list where they were, greyed
function Steps:AddGhosts(list)
    if #self.ghosts == 0 then return end
    local plan, tasks, have = PC:PlanName(), 0, {}
    for _, st in ipairs(list) do
        if self:IsTask(st) and not st.skipped then tasks = tasks + 1 end
        have[self:TaskKey(st)] = true
    end
    -- the rest of the list is done (or it's another plan now): they're gone
    if tasks == 0 then wipe(self.ghosts) return end
    for i = #self.ghosts, 1, -1 do
        local g = self.ghosts[i]
        if g.plan ~= plan or have[g.key] then table.remove(self.ghosts, i) end
    end
    table.sort(self.ghosts, function(a, b) return (a.idx or 1) < (b.idx or 1) end)
    for _, g in ipairs(self.ghosts) do
        table.insert(list, math.max(1, math.min(g.idx or 1, #list + 1)), { cat = g.cat, text = g.text, skipped = true, ghost = g })
    end
end

-- What removing a task will do, in a line (for its tooltip)
function Steps:RemoveHint(st)
    local k = st and st.rm and st.rm.kind
    return ({
        craft = "It leaves the plan; what to buy, where to go and what to sell all adjust.",
        make = "The plan buys this material instead of making it.",
        buy = "The crafts that need it leave the plan; everything else adjusts.",
        sell = "This plan won't sell it (it stays in your bags).",
        dequeue = "It won't be disenchanted.",
        bank = "No bank trips for an hour.",
        mail = "The mailbox is skipped for an hour.",
        undercut = "The undercut check is skipped until you come back to a city.",
        equip = "You won't put it on: it's sold like anything else.",
    })[k] or "Travel lines follow the tasks they lead to: remove the task itself."
end

-- /pc undo: the last task you removed comes back. Returns true when there was one.
function Steps:Undo()
    local stack = PC.cdb and PC.cdb.undo
    local u = stack and stack[#stack]
    if not u then return false end
    if u.plan ~= PC:PlanName() then
        PC.Buy:Say(("The last removal was in plan \"%s\": switch to it to undo."):format(tostring(u.plan)))
        return true
    end
    table.remove(stack)
    local say
    if u.kind == "unskip" then
        local names = {}
        for _, id in ipairs(u.ids or {}) do
            self:SetSkipped(id, false)
            names[#names + 1] = (PC.cdb.recipes[id] or {}).name or "?"
        end
        say = "Back in the plan: " .. table.concat(names, ", ") .. "."
    elseif u.kind == "make" then
        PC:BuyOnly()[u.id] = nil
        say = ("%s: made by the plan again."):format(PC:ItemName(u.id) or "That material")
    elseif u.kind == "sell" then
        PC:NoSell()[u.id] = nil
        say = ("%s: sold again."):format(PC:ItemName(u.id) or "That item")
    elseif u.kind == "equip" then
        PC.cdb.gearKeep = PC.cdb.gearKeep or {}
        PC.cdb.gearKeep[u.id] = time()
        say = ("%s: kept for you to put on again."):format(PC:ItemName(u.id) or "That item")
    elseif u.kind == "bank" then
        PC.cdb.bankSkipUntil = nil
        say = "Bank trips are back."
    elseif u.kind == "sellskip" then
        PC.cdb.sellSkipUntil = nil
        say = "Selling is back."
    elseif u.kind == "amend" then
        -- a plan cut back when buying stopped at the minimum profit: the counts it had come back
        local plan, names = PC:CurrentPlan(), {}
        for id, n in pairs(u.counts or {}) do
            plan[id] = n
            names[#names + 1] = ("%s %d"):format((PC.cdb.recipes[id] or {}).name or "?", n)
        end
        PC:ForgetStopList()
        say = "Plan restored: " .. table.concat(names, ", ") .. "."
    end
    if PC.UI then PC.UI.allEntries = nil end
    if say then PC.Buy:Say(say) end
    PC:RefreshUI()
    self:Refresh()
    return true
end

---------------------------------------------------------------------------
-- Building the list
---------------------------------------------------------------------------
-- Travel lines for getting to a place: a flight first when it's in another zone
local function TravelTo(out, kind, place, label)
    local P = PC.Places
    -- already there: from where you stand (talking to them, their window open, or a few yards off), or
    -- later in the list, a few yards from the stop before. Nothing to travel then.
    if place and PC.Travel then
        local T = PC.Travel
        if Steps.firstTrip then
            if T:AtPlace(place) then return end
        else
            local yd = Steps.lastPlace and T:Yards(Steps.lastPlace, place)
            if yd and yd <= T.AT_YARDS then Steps.lastPlace = place return end
        end
        Steps.lastPlace = place
    end
    if not place then
        out[#out + 1] = { cat = "Travel", text = ("find %s"):format(label) }
        return
    end
    -- the first trip from where you stand: the quickest way (flight, hearthstone, teleport, portal)
    if Steps.firstTrip and PC.Travel and PC:RouteOn() then
        Steps.firstTrip = false
        local ok, way = pcall(PC.Travel.BestWay, PC.Travel, place)
        if ok and way and way.steps and #way.steps > 0 then
            -- every leg as the route says it (the elevator, the Ruins, roads, flights and boats included)
            for _, st in ipairs(way.steps) do
                out[#out + 1] = { cat = "Travel", text = st.text:sub(1, 1):lower() .. st.text:sub(2) }
            end
            return
        end
    end
    Steps.firstTrip = false
    local fly = P and P:FlightHint(place)
    if fly then
        local here = P:Nearest("flight")
        if here then out[#out + 1] = { cat = "Travel", text = "walk to " .. PC.Travel:WalkName(here, PC.Travel:Here(), true) } end
        out[#out + 1] = { cat = "Travel", text = ("take the flight to %s"):format(place.zone or "that zone") }
    end
    -- how far: to this very place (not the nearest one of its kind)
    local here = PC.Travel and PC.Travel:Here()
    local d = here and PC.Travel:Yards(here, place)
    local dist = (not fly and d and d < 1e6) and (" (%d yd)"):format(math.floor(d + 0.5)) or ""
    local unsure = P.Unconfirmed and P:Unconfirmed(place) and " (unconfirmed)" or ""
    out[#out + 1] = { cat = "Travel", text = ("walk to %s%s%s"):format(place.name or label, unsure, dist) }
end

local function Names(list, max)
    local parts = {}
    for i = 1, math.min(#list, max or 3) do parts[#parts + 1] = list[i] end
    if #list > (max or 3) then parts[#parts + 1] = ("+%d more"):format(#list - (max or 3)) end
    return table.concat(parts, ", ")
end

-- The full sequence, from what you have now: { cat, text, recipeID, skipped }
-- One task in plain words, no place or person: "Craft 5 Bolt of Silk Cloth", "Buy 20 Silk Cloth on AH",
-- "Sell 3 Linen Bag at vendor", "Post 5 Minor Healing Potion on AH"
local function Cap(t) return (t:gsub("^%l", string.upper)) end
function Steps:Simple(st)
    local t, cat = st.text or "", st.cat
    t = t:gsub(" %(purge%)$", "")
    if cat == "Craft" then
        if t:find("^disenchant") then return Cap(t) end
        return "Craft " .. t
    elseif cat == "Vendor" then
        if t:find("^sell back leftover ") then return "Sell leftover " .. t:gsub("^sell back leftover ", "") .. " at vendor" end
        if t:find("^sell ") then return Cap(t) .. " at vendor" end
        if t:find("^buy ") then return Cap(t) .. " at vendor" end
        return Cap(t)
    elseif cat == "AH" then
        if t:find("^buy ") or t:find("^post ") then return Cap(t) .. " at auction" end
        if t:find("^check undercuts") then return "Check your auctions" end
        return Cap(t)
    elseif cat == "Bank" then
        if t:find("^take out ") then return Cap(t) .. " of the bank" end
        if t:find("^store ") then return Cap(t) .. " in the bank" end
        return Cap(t)
    elseif cat == "Mail" then
        return Cap(t)
    elseif cat == "Equip" then
        return Cap(t:gsub(" %(about the same as yours: your call%)$", ""))
    end
    return Cap(t)
end

function Steps:Build()
    -- SnuggleUp's guide running: its own list (item 1 is what the button does now)
    if PC.Guide and PC.Guide.Active and PC.Guide:Active() then return PC.Guide:Rows() end
    local out = {}
    local mark = PC.PerfMark and PC:PerfMark("b_") or function() end -- (timing each part, to find the slow one)
    -- on a flight: no ways worked out from up here (that's when it suggested a hearthstone mid-air)
    local flying = PC.Travel and PC.Travel.FlightText and PC.Travel:FlightText()
    self.firstTrip = not flying
    self.lastPlace = nil
    local UI, P = PC.UI, PC.Places
    if not UI or not PC.cdb then return out end
    if not UI.allEntries then UI.allEntries = PC:Analyze() end
    mark("l_analyze")
    local entries = UI:PlanEntries()
    mark("l_entries")
    -- buying: only for what will be crafted now (same as the button). At a vendor or the auction
    -- house this is settled on arrival and only checked off as you buy.
    local buyEntries, list = PC:StopShopList(entries, 1)
    mark("l_buyentries")
    mark("l_shop")
    local ahList, vendorList = UI:PlanBuyList(list), UI:PlanVendorList(list)
    -- only what keeps its craft at the minimum profit (the same as the Task Button)
    if PC.Buy and PC.Buy.ProfitList then ahList, vendorList = PC.Buy:ProfitList(ahList), PC.Buy:ProfitList(vendorList, true) end
    mark("lists")
    local at = nil -- where you'll be standing: no travel line between steps at the same place
    local function nearest(kind)
        if not P then return nil end
        local best, _, other = P:Nearest(kind)
        return best or other -- nearest in this zone, else one you know elsewhere (with the flight to it)
    end
    local function go(kind, label, place)
        if at == kind then return end
        TravelTo(out, kind, place or nearest(kind), label)
        at = kind
    end

    -- purging: every crafted item with a tick box (untick to keep it)
    local purged = {}
    if PC.Sell and PC.Sell.purge then
        for _, it in ipairs(PC.Sell:PurgeCandidates()) do
            out[#out + 1] = { cat = it.vendor and "Vendor" or "AH",
                text = ("%s %d %s (purge)"):format(it.vendor and "sell" or "post", it.sellN, it.name), purgeID = it.id, skipped = it.skipped }
            purged[it.id] = true
        end
    end
    -- 0) standing at the AH with things to sell: post them before going anywhere
    local postedHere = purged
    if PC.ahOpen and PC.Sell then
        for _, it in ipairs(PC.Sell:Items()) do
            if not purged[it.id] and it.sellN > 0 and it.price and not it.hold and not it.vendor then
                out[#out + 1] = { cat = "AH", text = ("post %d %s"):format(it.sellN, it.name), rm = { kind = "sell", id = it.id } }
                postedHere[it.id] = true
            end
        end
        if #out > 0 then at = "ah" end
    end
    -- 1+2) collect and buy, in the SAME order as the Next step button: nearest stop first
    --      (mailbox, bank, vendors, AH); the place you're standing at comes first; buying waits
    --      until plan materials are out of the bank
    local now = PC.Next and PC.Next:Compute() or {}
    mark("compute")
    -- out in the world only your plan shows: no bank, mail, selling or undercut rows until a city
    local town = PC.Next and PC.Next.Town and PC.Next:Town()
    local mailN = 0
    mailN = PC:MailTrips()
    local mailStep = now.text == "Go to the mailbox" or (now.text or ""):find("from the mailbox$") ~= nil
    local wantMail = mailN > 0 or (PC.Mail and PC.Mail:HasNew()) or mailStep
    if PC.Mail and PC.Mail.Snoozed and PC.Mail:Snoozed() and not mailStep then wantMail = false end -- skipped for an hour
    if wantMail and not mailStep and not (PC.Mail and PC.Mail.Near and PC.Mail:Near()) then wantMail = false end -- no mailbox nearby
    if not town and not mailStep then wantMail = false end -- (the plan's own materials: wherever you are)
    local B = PC.Bank
    local take = (B and B:Known()) and B:TakeList() or {}
    local bankCheck = now.text == "Go to the bank" and #take == 0
    local dueAway = PC.Undercut and PC.Undercut:DueAway()
    mark("mailbank")
    local function buyStops(list)
        for _, it in ipairs(vendorList) do list[#list + 1] = { kind = "vendor", itemID = it.id } end
        if #ahList > 0 then list[#list + 1] = { kind = "ah" } end
    end
    local first = {}
    if wantMail then first[#first + 1] = { kind = "mail" } end
    if #take > 0 or bankCheck then first[#first + 1] = { kind = "bank" } end
    if dueAway and #ahList == 0 then first[#first + 1] = { kind = "ah", undercut = true } end
    local later = {}
    if #take > 0 then buyStops(later) else buyStops(first) end
    local function standing(kind)
        return (kind == "mail" and PC.Mail and PC.Mail:Open()) or (kind == "bank" and B and B:Open())
            or (kind == "ah" and PC.ahOpen) or (kind == "vendor" and PC.VendorBuy and PC.VendorBuy:Open())
    end
    local function order(stops)
        local route = P and P:Route(stops) or {}
        -- where you're standing goes first
        table.sort(route, function(a, b)
            local sa, sb = standing(a.kind) and 0 or 1, standing(b.kind) and 0 or 1
            if sa ~= sb then return sa < sb end
            return (a.d or 1e9) < (b.d or 1e9)
        end)
        return route
    end
    local function render(stop)
        local kind = stop.kind
        if standing(kind) then at = kind
        elseif at ~= kind or kind == "vendor" then
            local label = ({ mail = "a mailbox", bank = "the bank", ah = "the Auction House", vendor = "a vendor that sells them" })[kind]
            TravelTo(out, kind == "vendor" and "vendor" or kind, (not stop.unknown) and stop.place or nil, label)
            at = kind
        end
        if kind == "mail" then
            out[#out + 1] = { cat = "Mail", text = mailN > 0 and ("collect %d auction purchase%s"):format(mailN, mailN == 1 and "" or "s") or "check the mailbox", rm = { kind = "mail" } }
        elseif kind == "bank" then
            if #take > 0 then
                local n = {}
                for _, it in ipairs(take) do n[#n + 1] = it.qty .. " " .. (it.name or "") end
                out[#out + 1] = { cat = "Bank", text = "take out " .. Names(n), rm = { kind = "bank" } }
            else
                out[#out + 1] = { cat = "Bank", text = (now.tip or ""):find("Start of the day") and "check what's in your bank" or "sort your bank", rm = { kind = "bank" } }
            end
        elseif kind == "vendor" then
            local n, wanted, ids = {}, {}, {}
            for _, id in ipairs(stop.items or {}) do wanted[id] = true end
            for _, it in ipairs(vendorList) do
                if stop.unknown or wanted[it.id] or #(stop.items or {}) == 0 then n[#n + 1] = it.qty .. " " .. (it.name or ""); ids[#ids + 1] = it.id end
            end
            if #n > 0 then out[#out + 1] = { cat = "Vendor", text = "buy " .. Names(n), rm = { kind = "buy", ids = ids } } end
        else
            for _, it in ipairs(ahList) do out[#out + 1] = { cat = "AH", text = ("buy %d %s"):format(it.qty, it.name or ""), rm = { kind = "buy", ids = { it.id } } } end
            if dueAway and #ahList == 0 then out[#out + 1] = { cat = "AH", text = ("check undercuts (%s)"):format(PC.Undercut and PC.Undercut:Helper() or "Auctionator"), rm = { kind = "undercut" } } end
        end
    end
    for _, stop in ipairs(order(first)) do render(stop) end
    for _, stop in ipairs(order(later)) do render(stop) end

    -- 3) craft: materials you make yourself first, then the plan; skipped recipes shown unticked
    mark("stops")
    local crafts = {}
    for _, e in ipairs(UI:SubCrafts(list)) do crafts[#crafts + 1] = e end
    for _, e in ipairs(entries) do crafts[#crafts + 1] = e end
    local lastStation
    for _, e in ipairs(crafts) do
        local station = PC.Craft and PC.Craft:Station(e)
        if station and station ~= lastStation then
            local p = P and P:Nearest("station", nil, station)
            TravelTo(out, "station", p, "a " .. station)
            at, lastStation = "station", station
        end
        out[#out + 1] = { cat = "Craft", text = PC:CraftCount(e.planCount or 0, e.r), recipeID = (not e.sub) and e.id or nil, sub = e.sub,
            rm = e.sub and { kind = "make", id = e.outID } or { kind = "craft", id = e.id } }
        -- made for its dust: disenchant them right after, before what needs the dust
        if e.disenchant then
            local dust = PC:ItemName(e.deFor) or "dust"
            out[#out + 1] = { cat = "Craft", text = ("disenchant %d %s (for about %d %s)"):format(e.planCount or 0, e.r.name, e.deNeed or 0, dust), deRow = e.r.name,
                rm = { kind = "make", id = e.deFor } }
        end
    end
    -- crafts you took out (tick to bring back): only while the plan still has something in it
    mark("crafts")
    local planHasCrafts = next(PC:CurrentPlan() or {}) ~= nil
    for id, n in pairs(planHasCrafts and self:Skipped() or {}) do
        local r = PC.cdb.recipes[id]
        if r then out[#out + 1] = { cat = "Craft", text = PC:CraftCount(n, r), recipeID = id, skipped = true } end
    end

    -- 3b) greens made for their dust: disenchant them
    if PC.Synergy then
        local counts, order, idOf = {}, {}, {}
        for _, it in ipairs(PC.Synergy:ToDisenchant()) do
            if not counts[it.name] then order[#order + 1] = it.name end
            counts[it.name] = (counts[it.name] or 0) + 1
            idOf[it.name] = it.id
        end
        local listed = {}
        for _, st in ipairs(out) do if st.deRow then listed[st.deRow] = true end end
        for _, name in ipairs(order) do
            if not listed[name] then out[#out + 1] = { cat = "Craft", text = ("disenchant %d %s"):format(counts[name], name), rm = { kind = "dequeue", id = idOf[name] } } end
        end
    end
    -- 4) gear made on a Gear upgrades plan: put it on, never sold
    mark("de")
    local wear = PC.cdb.gearKeep or {}
    local equipped = {}
    for _, u in ipairs(UI.EquipList and UI:EquipList() or {}) do
        out[#out + 1] = { cat = "Equip", text = ("put on %s%s"):format(u.name, u.kind == "close" and " (about the same as yours: your call)" or ""),
            rm = { kind = "equip", id = u.id } }
        equipped[u.id] = true
    end
    for _, e in ipairs(entries) do
        local id = e.outID or e.r.output
        if id and wear[id] and not equipped[id] and (PC:OwnedCount(id) or 0) == 0 and UI.ToEquip and UI:ToEquip(id) then
            local u = UI:ToEquip(id)
            out[#out + 1] = { cat = "Equip", text = ("put on %s%s"):format(PC:ItemName(id) or e.r.name, u.kind == "close" and " (about the same as yours: your call)" or ""),
                rm = { kind = "equip", id = id } }
            equipped[id] = true
        end
    end
    -- 5) sell: what the plan makes (and what you already crafted), wherever pays more
    mark("equip")
    local toAH, toVendor, seen = {}, {}, {}
    for id in pairs(wear) do seen[id] = true end -- (made to wear: never sold)
    for id in pairs(postedHere) do seen[id] = true end
    for _, it in ipairs(town and PC.Sell and PC.Sell:Items() or {}) do
        if seen[it.id] then -- already posted at the top
        elseif it.sellN > 0 and it.vendor then toVendor[#toVendor + 1] = { n = it.sellN, name = it.name, id = it.id }; seen[it.id] = true
        elseif it.sellN > 0 and it.price and not it.hold then toAH[#toAH + 1] = { n = it.sellN, name = it.name, id = it.id }; seen[it.id] = true end
    end
    -- selling skipped for an hour: no AH posting rows (or trip) until then
    local sellOff = PC:SellSnoozed() and not PC.ahOpen
    if sellOff then toAH = {} end
    for _, e in ipairs(entries) do
        local id = e.outID or e.r.output
        if id and not seen[id] then
            local n = (e.planCount or 0) * math.max(e.r.qty or 1, 1)
            -- what's on your Keep list: crafts that only bring you up to it aren't sold (keep 5, have 3: the 2 made are kept)
            local keep = PC.Sell and PC.Sell.Stock and PC.Sell:Stock()[id]
            if keep then n = math.max(n - math.max(keep - PC:BagCount(id), 0), 0) end
            local name = PC:ItemName(id) or e.r.name
            if n > 0 and not PC:NoSell()[id] and not (sellOff and e.route ~= "Vendor") then
                if e.route == "Vendor" then toVendor[#toVendor + 1] = { n = n, name = name, id = id } else toAH[#toAH + 1] = { n = n, name = name, id = id } end
            end
            seen[id] = true
        end
    end
    if #toAH > 0 then
        if not PC.ahOpen or at ~= "ah" then go("ah", "the Auction House") end
        for _, x in ipairs(toAH) do out[#out + 1] = { cat = "AH", text = ("post %d %s"):format(math.floor(x.n), x.name), rm = { kind = "sell", id = x.id } } end
    end
    mark("sell")
    local leftovers = (town and PC.VendorAuto and PC.VendorAuto.Leftovers) and PC.VendorAuto:Leftovers(entries) or {}
    if #toVendor > 0 or #leftovers > 0 then
        go("vendor", "a vendor")
        for _, x in ipairs(toVendor) do out[#out + 1] = { cat = "Vendor", text = ("sell %d %s"):format(math.floor(x.n), x.name), rm = { kind = "sell", id = x.id } } end
        if #leftovers > 0 then
            local n = {}
            for _, lo in ipairs(leftovers) do n[#n + 1] = lo.n .. " " .. lo.name end
            out[#out + 1] = { cat = "Vendor", text = "sell back leftover " .. Names(n) }
        end
    end

    -- 5) tidy up: spare materials to the bank when your bags are short of room
    mark("leftovers")
    if town and B and B:Known() then
        local _, store = B:Plan()
        -- bags short of room: spare materials too; otherwise just tools no craft left needs
        if PC:FreeBagSlotsOnly() >= (B.BAG_RESERVE or 6) then
            local tools = {}
            for _, it in ipairs(store) do if it.kind == "tool" or it.kind == "stash" or it.kind == "later" then tools[#tools + 1] = it end end
            store = tools
        end
        if #store > 0 then
            go("bank", "the bank")
            local n = {}
            for _, it in ipairs(store) do n[#n + 1] = it.qty .. " " .. (it.name or "") end
            out[#out + 1] = { cat = "Bank", text = "store " .. Names(n), rm = { kind = "bank" } }
        end
    end
    -- (no suggestions to craft with bank leftovers: only your plan's own steps show here)
    -- the step the button does right now, item by item, always first (and not repeated further up)
    mark("bankstore")
    if now.items and #now.items > 0 then
        local cat = now.cat or ((now.text or ""):find("bank") and "Bank") or "Bank"
        local mine = {}
        for _, t in ipairs(now.items) do mine[t:lower()] = true end
        local rest = {}
        for _, st in ipairs(out) do
            local dup = mine[(st.text or ""):lower()]
                or (cat == "Bank" and st.cat == "Bank" and ((st.text or ""):find("^take out ") or (st.text or ""):find("^store ")))
            if not dup then rest[#rest + 1] = st end
        end
        out = {}
        -- travelling there first: the walk comes before what you do there
        if now.dest and not flying then
            -- the way there, leg by leg (a flight, a zeppelin...), with the real distance
            Steps.firstTrip = true
            TravelTo(out, now.dest.kind or "vendor", now.dest, now.dest.name or "there")
            for i = #rest, 1, -1 do
                if rest[i].cat == "Travel" and (rest[i].text or ""):find("bank", 1, true) then table.remove(rest, i) end
            end
        end
        for _, t in ipairs(now.items) do out[#out + 1] = { cat = cat, text = t } end
        for _, st in ipairs(rest) do out[#out + 1] = st end
    end
    -- "Plan my route for me" off: no travel at all and no who or where, just what to do
    if not PC:RouteOn() then
        local kept = {}
        for _, st in ipairs(out) do
            if st.cat ~= "Travel" then
                st.text, st.plain = Steps:Simple(st), true
                kept[#kept + 1] = st
            end
        end
        out = kept
    end
    -- skipped (unticked) crafts go to the end: they aren't something to do
    local doing, skippedRows = {}, {}
    for _, st in ipairs(out) do
        if st.skipped and st.recipeID then skippedRows[#skippedRows + 1] = st else doing[#doing + 1] = st end
    end
    for _, st in ipairs(skippedRows) do doing[#doing + 1] = st end
    out = doing
    -- the Recipe Run: every stop, in the order you'll visit them (the one you're heading to is first)
    mark("tail")
    if PC.ToLearn and PC.ToLearn.StopRows then
        local run = PC.ToLearn:IsRun()
        local stops = PC.ToLearn:StopRows()
        if #stops > 0 and (run or #entries == 0) then
            -- (the NOW stop's own "get X" line says the same thing: the numbered list replaces it)
            for i = #out, 1, -1 do if (out[i].text or ""):find("^get .+ %(.-%)$") then table.remove(out, i) end end
            for _, st in ipairs(stops) do out[#out + 1] = st end
        end
    end
    if #out == 0 then out[#out + 1] = { cat = "Done", text = #entries == 0 and "the plan is empty: try Make me gold" or "nothing left to do" } end
    -- on a flight: the flight first, and none of the walking that leads up to it
    if flying then
        while out[1] and out[1].cat == "Travel" do table.remove(out, 1) end
        table.insert(out, 1, { cat = "Travel", text = flying:sub(1, 1):lower() .. flying:sub(2) })
    end
    mark("end")
    return out
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------
function Steps:Create()
    if self.f then return self.f end
    local f = CreateFrame("Frame", "ProfitCrafterSteps", UIParent, "BackdropTemplate")
    f:SetSize(380, 80 + self.ROWS * self.ROW_H)
    f:SetFrameStrata("MEDIUM")
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        f:SetBackdropColor(0.07, 0.05, 0.03, 0.94)
        f:SetBackdropBorderColor(0.78, 0.59, 0.18, 1)
    end
    f:SetPoint("BOTTOM", PC.Next and PC.Next.bar or UIParent, "TOP", 0, 6)
    f:EnableMouse(true)
    f:SetMovable(true) -- docked: it moves with the bar, by the bar's icon
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 12, -10)
    f.title:SetText("Plan tasks")
    -- while a purge runs: one click stops it
    f.stopPurge = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.stopPurge:SetSize(96, 20)
    f.stopPurge:SetPoint("TOPRIGHT", -10, -5)
    f.stopPurge:SetText("Stop purge")
    f.stopPurge:SetScript("OnClick", function() PC.Sell:SetPurge(false); Steps:Refresh() end)
    f.stopPurge:Hide()
    f.rows = {}
    for i = 1, self.ROWS do
        local row = CreateFrame("Frame", nil, f)
        row:SetHeight(self.ROW_H)
        row:SetPoint("RIGHT", f, "RIGHT", -10, 0)
        row:SetPoint("BOTTOMLEFT", 12, 8 + self.NOW_H + (i - 1) * self.ROW_H)
        row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        row.check:SetSize(18, 18)
        row.check:SetPoint("LEFT", 0, 0)
        row.check:SetScript("OnClick", function(b)
            local st = row.step
            if st and st.ghost then Steps:Unskip(st)
            elseif st and st.recipeID then Steps:SetSkipped(st.recipeID, not b:GetChecked())
            elseif st and st.purgeID then PC.Sell:SetPurgeSkip(st.purgeID, not b:GetChecked())
            elseif st and st.leftover then PC.Bank:ChooseLeftover(st.leftover, b:GetChecked()); Steps:Refresh()
            elseif st and st.rm and not b:GetChecked() then Steps:Skip(st, i + (Steps.offset or 0)) end
        end)
        row.check:SetScript("OnEnter", function(b)
            if PC.UI and PC.UI.ShowTooltip then
                if row.step and row.step.leftover then
                    local lo = row.step.leftover
                    PC.UI.ShowTooltip(b, { b:GetChecked() and "Untick to leave it in the bank" or (lo.craft and "Tick to craft it" or "Tick to sell it back"),
                        lo.craft and ("Adds %d %s to your plan; the bank task takes the materials out."):format(lo.craft.crafts, lo.craft.name)
                            or "The bank task takes it out and the next vendor buys it back." })
                elseif row.step and row.step.purgeID then
                    PC.UI.ShowTooltip(b, { b:GetChecked() and "Untick to keep this out of the purge" or "Tick to purge it too",
                        "Kept items sell only at a profit, as usual." })
                else
                    PC.UI.ShowTooltip(b, { b:GetChecked() and "Untick to skip this craft" or "Tick to craft it again",
                        "Every other task adjusts: what to buy, where to go, what to sell." })
                end
            end
        end)
        row.check:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        -- a craft from your plan: click it to change how many
        row:EnableMouse(true)
        row:SetScript("OnMouseUp", function(r, button)
            local st = r.step
            if button == "LeftButton" and st and st.recipeID and not st.skipped then Steps:EditCount(st.recipeID, r) end
        end)
        -- the remove button: shows on the row under the mouse
        row.rmBtn = CreateFrame("Button", nil, row)
        row.rmBtn:SetSize(14, 14)
        row.rmBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        row.rmBtn.t = row.rmBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.rmBtn.t:SetPoint("CENTER")
        row.rmBtn.t:SetText("|cffff5555x|r")
        row.rmBtn:Hide() -- shown on every task that can be removed (see Draw)
        row.rmBtn:SetScript("OnClick", function() Steps:Remove(row.step) end)
        row.rmBtn:SetScript("OnEnter", function(b)
            b:Show()
            if PC.UI and PC.UI.ShowTooltip then
                PC.UI.ShowTooltip(b, { "Remove this task", Steps:RemoveHint(row.step), "|cff888888/pc undo puts it back.|r" })
            end
        end)
        row.rmBtn:SetScript("OnLeave", function(b)
            if GameTooltip then GameTooltip:Hide() end
        end)
        row:SetScript("OnEnter", function(r)
            local st = r.step
            if st and st.recipeID and not st.skipped and PC.UI and PC.UI.ShowTooltip then
                PC.UI.ShowTooltip(r, { "Click to change how many", "Set a new total for this craft; every other task adjusts." })
            end
        end)
        row:SetScript("OnLeave", function(r)
            if GameTooltip then GameTooltip:Hide() end
        end)
        row.num = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.num:SetPoint("LEFT", 22, 0)
        row.num:SetWidth(20)
        row.num:SetJustifyH("RIGHT")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", row.num, "RIGHT", 6, 0)
        row.text:SetPoint("RIGHT", -16, 0) -- room for the remove x
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        f.rows[i] = row
    end
    -- NOW: what the button does right now, in full, fixed at the bottom next to the button (never scrolls)
    f.nowBar = CreateFrame("Frame", nil, f)
    f.nowBar:SetPoint("BOTTOMLEFT", 6, 6)
    f.nowBar:SetPoint("BOTTOMRIGHT", -6, 6)
    f.nowBar:SetHeight(self.NOW_H - 2)
    f.nowBar.bg = f.nowBar:CreateTexture(nil, "BACKGROUND")
    f.nowBar.bg:SetAllPoints()
    f.nowBar.bg:SetColorTexture(0.55, 0.40, 0.08, 0.45)
    f.nowBar.label = f.nowBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.nowBar.label:SetPoint("LEFT", 8, 0)
    f.nowBar.label:SetText("|cffffd100NOW|r")
    f.nowBar.text = f.nowBar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.nowBar.text:SetPoint("LEFT", f.nowBar.label, "RIGHT", 8, 0)
    f.nowBar.text:SetPoint("RIGHT", -6, 0)
    f.nowBar.text:SetJustifyH("LEFT")
    f.nowBar.text:SetWordWrap(false)
    f.nowBar:EnableMouse(true)
    f.nowBar:SetScript("OnEnter", function(b)
        if PC.UI and PC.UI.ShowTooltip and Steps.nowFull then PC.UI.ShowTooltip(b, Steps.nowFull) end
    end)
    f.nowBar:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    -- "N more above": right-aligned before the fold button, never past the window's edge
    f.more = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.more:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -10)
    f.more:SetJustifyH("RIGHT")
    f.more:SetWordWrap(false)
    f.title:SetPoint("RIGHT", f.more, "LEFT", -8, 0)
    f.title:SetJustifyH("LEFT")
    f.title:SetWordWrap(false)
    -- the pull tab, above the window's top edge (covers nothing): drag it like a blind - up for
    -- more steps, down for fewer, all the way down rolls the list up to the NOW line; a click
    -- rolls it up or down in one go
    -- the tab (same shape as before): up and down arrows with a bar between
    f.grip = CreateFrame("Button", nil, f, "BackdropTemplate")
    f.grip:SetSize(64, 16)
    f.grip:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 12, -3)
    if f.grip.SetBackdrop then
        f.grip:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
        f.grip:SetBackdropColor(0.07, 0.05, 0.03, 0.94)
        f.grip:SetBackdropBorderColor(0.78, 0.59, 0.18, 1)
    end
    f.grip.text = f.grip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.grip.text:SetPoint("CENTER", 0, 0)
    -- both arrows from one font, so they sit on the same line (the game's arrow pictures don't)
    if f.grip.text.SetFont then pcall(f.grip.text.SetFont, f.grip.text, "Fonts\\ARIALN.TTF", 8, "") end
    f.grip.text:SetTextColor(1, 0.82, 0)
    f.grip.text:SetText("\226\150\178   \226\150\188") -- up and down triangles
    -- (if that font ever lacks the triangles, plain text arrows instead)
    if f.grip.text.GetStringWidth and (f.grip.text:GetStringWidth() or 10) < 6 then f.grip.text:SetText(PC.ARROW_U .. "  " .. PC.ARROW_D) end
    f.grip.tex = { SetColorTexture = function(_, r, g, b) if f.grip.SetBackdropBorderColor then f.grip:SetBackdropBorderColor(r, g, b, 1) end end }
    f.grip:SetScript("OnEnter", function(b)
        b.tex:SetColorTexture(1, 0.82, 0.3, 1)
        if PC.UI and PC.UI.ShowTooltip then PC.UI.ShowTooltip(b, { "Pull up or down", "Drag up for more tasks, down for fewer; all the way down rolls the list away. Click to roll it up or down." }) end
    end)
    f.grip:SetScript("OnLeave", function(b) b.tex:SetColorTexture(0.78, 0.59, 0.18, 1); if GameTooltip then GameTooltip:Hide() end end)
    f.grip:SetScript("OnMouseDown", function(b)
        local scale = (UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1
        local _, y = GetCursorPosition()
        -- start from the rows you can actually see (0 when rolled up)
        local seen = PC.db.stepsMin and 0 or math.max(math.min(#(Steps.list or {}) - (Steps.offset or 0), Steps:Visible()), 1)
        b.startY, b.startRows, b.moved = (y or 0) / scale, seen, false
        b:SetScript("OnUpdate", function(bb)
            local _, cy = GetCursorPosition()
            local dy = (cy or 0) / scale - bb.startY
            if PC.db.dropDown then dy = -dy end -- pull-down: drag down for more
            if math.abs(dy) >= 4 then bb.moved = true end
            if not bb.moved then return end
            local rows = bb.startRows + math.floor(dy / Steps.ROW_H + 0.5)
            rows = math.min(rows, Steps.ROWS)
            local min = rows <= 0 or nil
            if min ~= PC.db.stepsMin or (not min and rows ~= PC.db.stepsRows) then
                PC.db.stepsMin = min
                if not min then PC.db.stepsRows = rows end
                Steps:Draw()
            end
        end)
    end)
    f.grip:SetScript("OnMouseUp", function(b)
        b:SetScript("OnUpdate", nil)
        if not b.moved then Steps:ToggleMin() end -- a click: roll up / down
    end)
    f.grip:SetScript("OnHide", function(b) b:SetScript("OnUpdate", nil) end)
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(_, delta)
        -- wheel up shows the later steps (they're above)
        if PC.db.dropDown then delta = -delta end -- pull-down: the later steps are below
        Steps.offset = math.max(0, math.min((Steps.offset or 0) + delta * 3, math.max(#(Steps.list or {}) - Steps:Visible(), 0)))
        Steps:Draw()
    end)
    f:Hide()
    -- the name tab: the addon's name ("ProfitCrafter Forever" / "ProfitCrafter") in the NOW line's colours,
    -- on top of the window at the right end (the pull tab is at the left end). Same tab as Snuggle Up's.
    f.nameTab = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.nameTab:SetHeight(22)
    f.nameTab:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -12, -3)
    if f.nameTab.SetBackdrop then
        f.nameTab:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
        f.nameTab:SetBackdropColor(0.07, 0.05, 0.03, 0.94)
        f.nameTab:SetBackdropBorderColor(0.78, 0.59, 0.18, 1)
    end
    f.nameTab.bg = f.nameTab:CreateTexture(nil, "BORDER")
    f.nameTab.bg:SetPoint("TOPLEFT", 3, -3)
    f.nameTab.bg:SetPoint("BOTTOMRIGHT", -3, 3)
    f.nameTab.bg:SetColorTexture(0.55, 0.40, 0.08, 0.45)
    f.nameTab.text = f.nameTab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.nameTab.text:SetPoint("CENTER", 0, 0)
    f.nameTab.text:SetTextColor(1, 0.82, 0)
    f.nameTab.text:SetText(PC.NAME or "ProfitCrafter")
    -- a handle too: press and drag to move the window (the bar and the list together)
    f.nameTab:EnableMouse(true)
    f.nameTab:SetScript("OnMouseDown", function(_, button)
        if Steps.docked and PC.Next and PC.Next.bar then return PC.Next:BeginMove(button) end
        if button ~= "LeftButton" then return end
        if f.SetMovable then f:SetMovable(true) end
        f.tabMoving = true
        f:StartMoving()
    end)
    f.nameTab:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then return Steps:ToggleLayout() end
        if f.tabMoving then f.tabMoving = false; f:StopMovingOrSizing() return end
        if PC.Next then PC.Next:EndMove() end
    end)
    f.nameTab:SetScript("OnHide", function() if PC.Next and PC.Next.bar and PC.Next.bar.moving then PC.Next:EndMove() end end)
    f.nameTab:SetScript("OnEnter", function(b)
        if PC.UI and PC.UI.ShowTooltip then PC.UI.ShowTooltip(b, { Steps:NameTabText(), "Click and hold here to drag the window; let go and it stays there.",
            PC.db.dropDown and "Right-click: list above the button instead" or "Right-click: pull-down (button on top, list below it)" }) end
    end)
    f.nameTab:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    f.nameTab:SetWidth(math.max(((f.nameTab.text.GetStringWidth and f.nameTab.text:GetStringWidth()) or 120) + 24, 140))
    self.f = f
    return f
end

function Steps:Visible()
    local n = math.max(1, math.min(PC.db.stepsRows or self.DEFAULT_ROWS, self.ROWS))
    if self.animRows then n = math.min(n, self.animRows) end -- rolling out: this many so far
    return n
end

-- A new plan: the list comes up folded, then rolls out a step at a time until at least 8 show
-- (all of them if there are fewer). It rolls up, or down when the list hangs under the button.
function Steps:Unfold()
    if not (C_Timer and C_Timer.After) then return end
    PC.db.stepsMin = nil
    PC.db.stepsRows = 8 -- like pulling a shade down to step 8; drag its edge for more
    self.animRows = 0
    self.animGen = (self.animGen or 0) + 1
    local gen = self.animGen
    if PC.Next and PC.Next.PaintMin and PC.Next.bar then pcall(PC.Next.PaintMin, PC.Next) end
    local function step()
        if gen ~= self.animGen or not self.animRows then return end
        self.animRows = self.animRows + 1
        local target = math.max(1, math.min(PC.db.stepsRows or self.DEFAULT_ROWS, self.ROWS, #(self.list or {})))
        if self.animRows >= target then self.animRows = nil end
        if self.f and self.f:IsShown() then pcall(self.Draw, self) end
        if self.animRows then C_Timer.After(0.22, step) end -- slow enough to watch it roll out
    end
    C_Timer.After(0.6, step)
end

function Steps:Draw()
    local f, list = self.f, self.list or {}
    if not f then return end
    local off = self.offset or 0
    local visible = PC.db.stepsMin and 0 or self:Visible() -- folded: only the NOW line
    for i, row in ipairs(f.rows) do
        local st = i <= visible and list[i + off] or nil
        row.step = st
        if row.rmBtn then row.rmBtn:Hide() end -- (no x on the right any more: the tick box on the left skips a task)
        -- fades upward: the step you're on is bright, later ones dimmer
        row:SetAlpha(1 - 0.6 * math.min((i - 1) / math.max(visible - 1, 1), 1))
        if st then
            local first = (i + off) == 1
            row.num:SetText(st.note and "|cffff8000!|r" or (i + off))
            local text = st.plain and st.text or (Tag(st.cat) .. " - " .. st.text)
            if st.skipped and st.leftover then text = Tag(st.cat) .. " - |cffc0c0c0" .. st.text .. "|r"
            elseif st.skipped then text = "|cff707070" .. st.cat .. " - " .. st.text .. (st.purgeID and " (kept)" or " (skipped)") .. "|r" end
            row.text:SetText(text)
            if st.recipeID or st.purgeID or st.leftover or st.rm or st.ghost then
                row.check:Show()
                row.check:SetChecked(not st.skipped)
            else
                row.check:Hide()
            end
            row:Show()
        else
            row:Hide()
        end
    end
    if f.stopPurge then f.stopPurge:SetShown(PC.Sell and PC.Sell.purge and true or false) end
    -- the "more above" note sits left of whatever is at the top right (Stop purge or the fold button)
    f.more:ClearAllPoints()
    local down = PC.db.dropDown and true or false
    if f.stopPurge and f.stopPurge:IsShown() then f.more:SetPoint("RIGHT", f.stopPurge, "LEFT", -6, 0)
    elseif down then f.more:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
    else f.more:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -10) end
    local hidden = #list - (off + visible)
    f.more:SetText(hidden > 0 and ("%d more %s"):format(hidden, down and "below" or "above") or "")
    -- as tall as the steps it shows, no empty block (or as tall as you dragged it)
    local shown = math.min(#list - off, visible)
    if PC.db.stepsMin or self.animRows == 0 then shown = 0; f.more:SetText("") else shown = math.max(shown, 1) end
    f:SetHeight(34 + self.NOW_H + shown * self.ROW_H)
    self:PaintNow()
    -- (only when the size or the way round changed: nothing to look at otherwise)
    local keep = f:GetHeight() .. ":" .. tostring(PC.db.dropDown)
    if keep ~= self.keepKey and not self.animRows and PC.Next and PC.Next.KeepOnScreenSoon then self.keepKey = keep; PC.Next:KeepOnScreenSoon() end
end

-- The step's kind, for its colour tag
function Steps:CatOf(s)
    if s and s.guide then return s.cat or "Quest" end
    local label = PC.Next and PC.Next.Label and PC.Next:Label(s) or (s.text or "")
    -- a leg of the way there (walking, flying, a zeppelin, the hearthstone) is Travel, whatever it's for
    if label:find("^Travel") or label:find("^Fly") or label:find("^Take the") or label:find("^Walk") or label:find("Hearthstone") then return "Travel" end
    if s.cat then return s.cat end
    if label:find("bank") or label:find("^Store") or label:find("^Take") then return "Bank" end
    if label:find("mail") then return "Mail" end
    if label:find("^Craft") then return "Craft" end
    if label:find("^Post") or label:find("^Cancel") or label:find("undercut") or label:find("^Confirm") or (s.text or ""):find("AH") then return "AH" end
    if label:find("^Sell") or label:find("vendor") or label:find("^Buy") then return "Vendor" end
    if (s.text or ""):find("^Waiting") then return "Wait" end
    return "Done"
end

-- Exactly what to do now: the step's own words, plus every item it covers
function Steps:NowText(s)
    local text = s.text or ""
    if s.items and #s.items > 0 then
        local parts = {}
        for _, t in ipairs(s.items) do parts[#parts + 1] = t end
        local verbs = table.concat(parts, ", ")
        if s.via then verbs = verbs .. " (" .. s.via:sub(1, 1):lower() .. s.via:sub(2) .. " first)" end
        verbs = verbs:sub(1, 1):upper() .. verbs:sub(2)
        if PC.Next and PC.Next.IsTravel and PC.Next:IsTravel(s) then return text .. ": " .. verbs:sub(1, 1):lower() .. verbs:sub(2) end
        return verbs
    end
    if s.via then return text .. ": " .. s.via:sub(1, 1):lower() .. s.via:sub(2) end
    return text
end

-- The name tab on top: "SnuggleUp Forever" while its guide is the running plan, else ProfitCrafter's name
Steps.GUIDE_TAB = "SnuggleUp Forever"
function Steps:NameTabText()
    if PC.Guide and PC.Guide.Active and PC.Guide:Active() then return self.GUIDE_TAB end
    return PC.NAME or "ProfitCrafter"
end
function Steps:PaintNameTab()
    local tab = self.f and self.f.nameTab
    if not tab or not tab.text then return end
    local name = self:NameTabText()
    if tab.shownName == name then return end
    tab.shownName = name
    tab.text:SetText(name)
    tab:SetWidth(math.max(((tab.text.GetStringWidth and tab.text:GetStringWidth()) or 120) + 24, 140))
end

function Steps:PaintNow()
    local f = self.f
    if not f or not f.nowBar then return end
    -- the title says when the plan is for skill, not profit
    self:PaintNameTab()
    if f.title and PC.Guide and PC.Guide.Active and PC.Guide:Active() then
        f.title:SetText(PC.Guide:Title())
    elseif f.title then
        local skill = PC.UI and PC.UI.IsSkillPlan and PC.UI:IsSkillPlan() and next(PC:CurrentPlan() or {}) ~= nil
        local run = PC.ToLearn and PC.ToLearn:IsRun()
        local n = run and #PC.ToLearn.Data().trip or 0
        local done, total = self.doneN or 0, self.totalN or 0
        local count = total > 0 and ("  |cff888888(%d of %d done)|r"):format(done, total) or ""
        if run and total == 0 then count = ("  |cff888888(%d stop%s)|r"):format(n, n == 1 and "" or "s") end
        f.title:SetText((run and "Recipe Run" or "Plan tasks") .. count
            .. ((skill and not run) and "  |cffff8040(skill-up: not for profit)|r" or ""))
    end
    -- outside a refresh (rolling out, dragging the tab, the mouse wheel): the step the button shows, not
    -- the whole next step worked out again for every row the list moves
    local N = PC.Next
    local s = (not PC:Memo() and N and N.shown) or ((N and N.Compute) and N:Compute()) or {}
    local cat = self:CatOf(s)
    local text = self:NowText(s)
    f.nowBar.text:SetText(Tag(cat) .. " - " .. text)
    local full = { "Now: " .. text }
    if s.tip and s.tip ~= "" then full[#full + 1] = s.tip end
    self.nowFull = full
end

-- "3 of 7 done" in the title: the plan's tasks (crafts, buys, sells, posts, bank and mail), never the travel.
-- Every task seen while this plan runs is remembered; one that's gone from the list is done.
-- Starts over with a new plan, or when a finished one gets new tasks.
function Steps:TaskKey(st)
    if st.key then return "stop:" .. tostring(st.key) end
    if st.recipeID then return (st.cat or "") .. ":r" .. tostring(st.recipeID) .. ":" .. ((st.text or ""):lower():match("^(%a+)") or "") end
    local t = (st.text or ""):lower():gsub("%d+", ""):gsub("%s+", " ")
    return (st.cat or "") .. ":" .. t
end
function Steps:IsTask(st)
    local cat = self:CatOf(st)
    return cat ~= "Travel" and cat ~= "Done" and cat ~= "Wait"
end
function Steps:CountTasks(list)
    local cdb = PC.cdb
    if not cdb then return 0, 0 end
    local name = (PC.ToLearn and PC.ToLearn.IsRun and PC.ToLearn:IsRun()) and "Recipe Run" or (PC:PlanName() or "")
    local cur, skipped, n = {}, {}, 0
    for _, st in ipairs(list or {}) do
        if self:IsTask(st) then
            local k = self:TaskKey(st)
            if st.skipped then skipped[k] = true
            elseif not cur[k] then cur[k] = true; n = n + 1 end
        end
    end
    local tc = cdb.taskCount
    if not tc or tc.plan ~= name or (tc.finished and n > 0) then
        tc = { plan = name, seen = {} }
        cdb.taskCount = tc
    end
    for k in pairs(skipped) do if not cur[k] then tc.seen[k] = nil end end -- skipped: not a task
    for k in pairs(cur) do tc.seen[k] = true end
    local done, total = 0, 0
    for k in pairs(tc.seen) do
        total = total + 1
        if not cur[k] then done = done + 1 end
    end
    tc.finished = (n == 0 and total > 0) or nil
    return done, total
end

function Steps:Refresh()
    if PC.inCombat then return end
    if not PC:Memo() then return PC:WithMemo(Steps.Refresh, self) end
    -- the Task Button's update and the refresh both ask for this: once per refresh is enough
    local memo = PC:Memo()
    if memo then
        if memo.stepsDone then return end
        memo.stepsDone = true
    end
    -- docked to the button: never on screen without it
    local bar = PC.Next and PC.Next.bar
    if self.docked and self.f and self.f:IsShown() and not (bar and bar:IsShown()) then self.f:Hide() return end
    -- no plan loaded, or another MostlyNotBroken add-on in use: no task list at all (docked or not)
    local N = PC.Next
    if self.f and self.f:IsShown() and N and ((N.lastText == "Set up a plan") or (N.NoPlan and N:NoPlan()) or (N.OtherBusy and N:OtherBusy())) then
        self.f:Hide()
        return
    end
    if not self.f or not self.f:IsShown() then return end
    self.list = PC:Timed("build", self.Build, self)
    -- a new plan on the list: folded first, then it rolls out
    local plan = PC:PlanName()
    if plan ~= self.planShown then
        local first = self.planShown == nil and not self.planFresh
        self.planShown, self.planFresh = plan, nil
        if not first and #self.list > 0 then self:Unfold() end
    end
    if not (PC.Guide and PC.Guide.Active and PC.Guide:Active()) then self.doneN, self.totalN = self:CountTasks(self.list) end
    pcall(self.AddGhosts, self, self.list) -- tasks you unticked stay on the list, greyed
    -- a new first step: scroll back down so the step you're on shows next to the button
    local first = self.list[1] and self.list[1].text
    if first ~= self.firstText then self.firstText = first; self.offset = 0 end
    self.offset = math.min(self.offset or 0, math.max(#self.list - self:Visible(), 0))
    self:Draw()
end

-- Docked above the Next step bar (shown with it unless you closed it)
-- Two ways round (Settings, or right-click the name tab, or /pc layout):
--   normal:    tabs on top, the list above the button, NOW at the bottom next to the button
--   pull-down: the button on top, NOW right under it, the list below, tabs at the very bottom
function Steps:Layout()
    local f = self.f
    if not f then return end
    local down = PC.db.dropDown and true or false
    if f.laidDown == down then return end
    f.laidDown = down
    for i, row in ipairs(f.rows) do
        row:ClearAllPoints()
        row:SetPoint("RIGHT", f, "RIGHT", -10, 0)
        if down then row:SetPoint("TOPLEFT", 12, -(8 + self.NOW_H + (i - 1) * self.ROW_H))
        else row:SetPoint("BOTTOMLEFT", 12, 8 + self.NOW_H + (i - 1) * self.ROW_H) end
    end
    f.nowBar:ClearAllPoints()
    f.title:ClearAllPoints()
    f.grip:ClearAllPoints()
    f.nameTab:ClearAllPoints()
    if f.stopPurge then f.stopPurge:ClearAllPoints() end
    if down then
        f.nowBar:SetPoint("TOPLEFT", 6, -6)
        f.nowBar:SetPoint("TOPRIGHT", -6, -6)
        f.title:SetPoint("BOTTOMLEFT", 12, 10)
        f.grip:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, 3)
        f.nameTab:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", -12, 3)
        if f.stopPurge then f.stopPurge:SetPoint("BOTTOMRIGHT", -10, 5) end
    else
        f.nowBar:SetPoint("BOTTOMLEFT", 6, 6)
        f.nowBar:SetPoint("BOTTOMRIGHT", -6, 6)
        f.title:SetPoint("TOPLEFT", 12, -10)
        f.grip:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 12, -3)
        f.nameTab:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -12, -3)
        if f.stopPurge then f.stopPurge:SetPoint("TOPRIGHT", -10, -5) end
    end
    f.title:SetPoint("RIGHT", f.more, "LEFT", -8, 0)
end

-- switch between the two (quiet = from the Settings switch)
function Steps:ToggleLayout(quiet)
    PC.db.dropDown = not PC.db.dropDown or nil
    if self.docked or (self.f and self.f:IsShown()) then self:ShowDocked() end
    self:Draw()
    if PC.Next and PC.Next.KeepOnScreen then PC:Safe("keep on screen", PC.Next.KeepOnScreen, PC.Next) end
    if PC.Options and PC.Options.RefreshAll then pcall(PC.Options.RefreshAll, PC.Options) end
    if not quiet then
        PC.Print(PC.db.dropDown and "Pull-down layout: the button on top, the task list below it." or "Normal layout: the task list above the button.")
    end
end

function Steps:ShowDocked()
    if PC.inCombat then return end
    local bar = PC.Next and PC.Next.bar
    if not bar or not bar:IsShown() then return end
    local f = self:Create()
    -- folded: just the NOW line above the bar (the rest of the list is hidden)
    f:ClearAllPoints()
    if PC.db.dropDown then
        -- pull-down: hangs under the button (overlapping its bottom edge: one window)
        f:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, 4)
        f:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, 4)
    else
        f:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, -4)   -- overlaps the bar's top edge: one window
        f:SetPoint("BOTTOMRIGHT", bar, "TOPRIGHT", 0, -4)
    end
    self:Layout()
    f:SetFrameLevel(math.max((bar:GetFrameLevel() or 1) - 1, 0))
    f:Show()
    self.docked = true
    self:Refresh()
end

-- Change how many of a plan craft, right from the steps list
function Steps:EditCount(recipeID, anchor)
    local plan = PC.UI and PC.UI.PlanTable and PC.UI:PlanTable()
    local r = PC.cdb.recipes[recipeID]
    if not plan or not r then return end
    local q = self.qty
    if not q then
        q = CreateFrame("Frame", "ProfitCrafterStepQty", UIParent, "BackdropTemplate")
        q:SetSize(220, 78)
        q:SetFrameStrata("DIALOG")
        q:EnableMouse(true)
        if q.SetBackdrop then
            q:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
            q:SetBackdropColor(0.04, 0.035, 0.03, 0.98)
            q:SetBackdropBorderColor(0.78, 0.6, 0.23, 1)
        end
        if UISpecialFrames then tinsert(UISpecialFrames, "ProfitCrafterStepQty") end -- Esc closes it
        q.title = q:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        q.title:SetPoint("TOPLEFT", 10, -10)
        q.title:SetPoint("RIGHT", -10, 0)
        q.title:SetJustifyH("LEFT")
        q.title:SetWordWrap(false)
        q.minus = CreateFrame("Button", nil, q, "UIPanelButtonTemplate")
        q.minus:SetSize(22, 20)
        q.minus:SetPoint("TOPLEFT", 10, -32)
        q.minus:SetText("-")
        q.eb = CreateFrame("EditBox", nil, q, "InputBoxTemplate")
        q.eb:SetSize(60, 20)
        q.eb:SetPoint("LEFT", q.minus, "RIGHT", 8, 0)
        q.eb:SetAutoFocus(false)
        q.eb:SetNumeric(true)
        q.plus = CreateFrame("Button", nil, q, "UIPanelButtonTemplate")
        q.plus:SetSize(22, 20)
        q.plus:SetPoint("LEFT", q.eb, "RIGHT", 4, 0)
        q.plus:SetText("+")
        q.set = CreateFrame("Button", nil, q, "UIPanelButtonTemplate")
        q.set:SetSize(60, 20)
        q.set:SetPoint("LEFT", q.plus, "RIGHT", 6, 0)
        q.set:SetText("Set")
        local function step(d)
            q.eb:SetText(tostring(math.max((tonumber(q.eb:GetText()) or 0) + d, 0)))
        end
        q.minus:SetScript("OnClick", function() step(IsShiftKeyDown and IsShiftKeyDown() and -10 or -1) end)
        q.plus:SetScript("OnClick", function() step(IsShiftKeyDown and IsShiftKeyDown() and 10 or 1) end)
        local function apply()
            local n = math.floor(tonumber(q.eb:GetText()) or 0)
            if PC.UI and PC.UI.SetPlanCount then PC.UI:SetPlanCount(q.recipeID, n) end
            q:Hide()
            PC:RefreshUI()
        end
        q.set:SetScript("OnClick", apply)
        q.eb:SetScript("OnEnterPressed", apply)
        q.eb:SetScript("OnEscapePressed", function() q:Hide() end)
        q.hint = q:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        q.hint:SetPoint("BOTTOMLEFT", 10, 8)
        q.hint:SetText("0 takes it out of the plan  ·  Shift: 10 at a time")
        q:Hide()
        self.qty = q
    end
    q.recipeID = recipeID
    q.title:SetText(r.name .. ": how many?")
    q.eb:SetText(tostring(plan[recipeID] or 0))
    q:ClearAllPoints()
    if anchor then q:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 40, 2) else q:SetPoint("CENTER") end
    q:Show()
    q.eb:SetFocus()
    if q.eb.HighlightText then q.eb:HighlightText() end
end

-- The -/+ on the bar: fold the list away, or open it again
function Steps:ToggleMin()
    PC.db.stepsMin = not PC.db.stepsMin or nil
    self:ShowDocked()
    self:Draw()
    if PC.Next and PC.Next.bar then PC.Next:PaintMin() end
end

function Steps:Hide()
    if self.f then self.f:Hide() end
end

function Steps:Toggle()
    local f = self:Create()
    -- with the task button up, the list is always there: /pc tasks folds it away or opens it again
    if PC.Next and PC.Next.bar and PC.Next.bar:IsShown() then return self:ToggleMin() end
    if f:IsShown() then f:Hide(); self.docked = false return end
    f:ClearAllPoints()
    f:SetPoint("BOTTOM", PC.Next and PC.Next.bar and PC.Next.bar:IsShown() and PC.Next.bar or UIParent, PC.Next and PC.Next.bar and PC.Next.bar:IsShown() and "TOP" or "CENTER", 0, 6)
    f:Show()
    self.offset = 0
    self:Refresh()
end
