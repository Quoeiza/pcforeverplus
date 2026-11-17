-- ProfitCrafter: bank
--   Knows every bank slot and how many of each item is in it (updated whenever the bank is open),
--   and moves things in one click: plan materials come OUT to your bags, crafted goods you're not
--   selling yet and spare materials go IN. It only ever touches crafting materials and items you
--   crafted; nothing else in your bags or bank is moved. It never overfills: every move is checked
--   against the free slots and stack sizes it knows about.

local ADDON, ns = ...
local PC = ns.PC

local Bank = {}
PC.Bank = Bank

Bank.MOVE_GAP = 0.25 -- seconds between moves (the game needs a moment per item)

local SlotsNeeded -- defined below (Plan uses it)
local CountIn     -- defined below (moving uses it)

Bank.BAG_RESERVE = 6   -- free bag slots to keep: below this, spare materials go to the bank

-- Your bags' slots: read once per refresh (each list here went through every slot again; nothing moves
-- in the middle of a refresh)
local function MyBagSlots()
    local memo = PC:Memo()
    local s = memo and memo.bankBagSlots
    if not s then
        s = PC.BagSlots and PC.BagSlots() or {}
        if memo then memo.bankBagSlots = s end
    end
    return s
end
Bank.BANK_RESERVE = 2  -- free bank slots never filled

-- The bank's containers: the main bank and its bags (never one of your own bags)
local function BankBags()
    local list = {}
    local E = Enum and Enum.BagIndex
    -- newer clients (bank tabs): the tabs ARE the bank; the old main bank and bank bags are gone
    if E and E.CharacterBankTab_1 then
        local n = 0
        for i = 0, 5 do
            local b = E.CharacterBankTab_1 + i
            if not PC:IsPlayerBag(b) then list[#list + 1] = b end
        end
        if #list > 0 then return list end
    end
    local main = (E and E.Bank) or BANK_CONTAINER or -1
    list[#list + 1] = main
    local first = (E and E.BankBag_1) or ((NUM_BAG_SLOTS or 4) + 1)
    local n = NUM_BANKBAGSLOTS or 7
    for i = 0, n - 1 do
        local b = first + i
        if not PC:IsPlayerBag(b) then list[#list + 1] = b end
    end
    return list
end
Bank.BankBags = BankBags

local function NumSlots(bag)
    local C = C_Container
    local fn = (C and C.GetContainerNumSlots) or GetContainerNumSlots
    return fn and (fn(bag) or 0) or 0
end

local function SlotInfo(bag, slot)
    local C = C_Container
    if C and C.GetContainerItemInfo then
        local info = C.GetContainerItemInfo(bag, slot)
        if info then return info.itemID, info.stackCount or 1, info.isLocked end
        return nil
    elseif GetContainerItemInfo then
        local _, n, locked, _, _, _, _, _, _, id = GetContainerItemInfo(bag, slot)
        return id, n or 1, locked
    end
end

local function FreeSlotsIn(bag)
    local C = C_Container
    local fn = (C and C.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
    if not fn then return 0 end
    local n, family = fn(bag)
    if (family or 0) ~= 0 then return 0 end
    return n or 0
end

function Bank:Open() return self.open and true or false end

---------------------------------------------------------------------------
-- What's in the bank (read live while it's open; remembered after, per character)
---------------------------------------------------------------------------
-- cdb.bank = { t = time, free = n, slots = { {bag, slot, id, n}, ... }, count = { [id] = n } }
function Bank:Scan()
    if not self.open or not PC.cdb then return end
    local slots, count, free = {}, {}, 0
    for _, bag in ipairs(BankBags()) do
        local n = NumSlots(bag)
        if n > 0 then
            free = free + FreeSlotsIn(bag)
            for slot = 1, n do
                local id, qty = SlotInfo(bag, slot)
                if id then
                    slots[#slots + 1] = { bag = bag, slot = slot, id = id, n = qty }
                    count[id] = (count[id] or 0) + qty
                end
            end
        end
    end
    PC.cdb.bank = { t = time(), free = free, slots = slots, count = count }
    return PC.cdb.bank
end

function Bank:Known()
    if not PC:UseBank() then return nil end -- (Settings: your bank is left alone)
    return PC.cdb and PC.cdb.bank
end

-- Where everything sits right now, bags and bank, as one string: changes when you move or sort
function Bank:Signature()
    local parts = {}
    local bags = {}
    for _, b in ipairs(PC:PlayerBags()) do bags[#bags + 1] = b end -- a copy: never add to the shared list
    for _, b in ipairs(BankBags()) do bags[#bags + 1] = b end
    for _, bag in ipairs(bags) do
        for slot = 1, NumSlots(bag) do
            local id, n = SlotInfo(bag, slot)
            if id then parts[#parts + 1] = bag .. ":" .. slot .. "=" .. id .. "x" .. (n or 1) end
        end
    end
    return table.concat(parts, ",")
end
function Bank:FreeSlots() local b = self:Known(); return b and b.free or 0 end
function Bank:Count(itemID) local b = self:Known(); return b and b.count[itemID] or 0 end

---------------------------------------------------------------------------
-- What should move
---------------------------------------------------------------------------
-- Items ProfitCrafter is allowed to touch: materials of recipes you know, and things those recipes make
-- Crafting tools you carry only to craft: rods, hammers, spanners (gathering tools aren't here:
-- a miner or skinner keeps their pick and knife)
Bank.KNOWN_TOOLS = {
    5956,  -- Blacksmith Hammer
    6218,  -- Runed Copper Rod
    6339,  -- Runed Silver Rod
    11130, -- Runed Golden Rod
    11145, -- Runed Truesilver Rod
    16207, -- Runed Arcanite Rod
    6219,  -- Arclight Spanner
    10498, -- Gyromatic Micro-Adjustor
    4471,  -- Flint and Tinder
    9149,  -- Philosopher's Stone
}

function Bank:Allowed()
    -- (asked by every list here, several times a refresh: worked out once per refresh)
    local memo = PC:Memo()
    if memo and memo.bankAllowed then return memo.bankAllowed end
    local ok = {}
    for _, r in pairs(PC.cdb and PC.cdb.recipes or {}) do
        if r.output then ok[r.output] = "crafted" end
        for _, o in ipairs(r.outputs or {}) do ok[o] = "crafted" end
        for _, rg in ipairs(r.reagents or {}) do
            for _, id in ipairs(PC:ReagentIDs(rg)) do ok[id] = ok[id] or "material" end
        end
    end
    -- tools crafting recipes need (runed rods): parked once no plan recipe needs them.
    -- Gathering tools stay with you: a skinner or miner wants their knife and pick on them
    local tools = {}
    for id in pairs(PC.Craft and PC.Craft.toolIDs or {}) do tools[id] = true end
    for id in pairs(PC.cdb and PC.cdb.toolIDs or {}) do tools[id] = true end
    for _, id in ipairs(self.KNOWN_TOOLS) do tools[id] = true end
    for id in pairs(tools) do
        local n = (PC:ItemName(id) or ""):lower()
        local gather = n:find("skinning knife", 1, true) or n:find("mining pick", 1, true) or n:find("pick", 1, true)
            or n:find("fishing pole", 1, true) or n:find("herbal", 1, true)
        if not gather then ok[id] = "tool" end
    end
    if memo then memo.bankAllowed = ok end
    return ok
end

-- Materials the plan needs that are sitting in the bank: { id, name, qty }
-- How many of a crafted item in the bank are worth taking out to sell right now: it has to sell at
-- a profit, and only as many as the market takes (a day's sales, or a slice of what's listed,
-- minus what you already have listed or in your bags)
-- How many of a finished item the market takes right now (about a day's sales), minus what you
-- already have up on the AH: that many stay in your bags to post; the rest can wait in the bank
function Bank:MarketKeep(id)
    local sold = PC.SalesEstimate and PC:SalesEstimate(id, 86400)
    local room
    if sold and sold > 0 then room = sold
    else
        local listed = PC:Supply()[id]
        if listed and listed > 0 then room = math.floor(listed * (PC.db.goldFlood or 20) / 100) else room = 5 end
    end
    local posted = PC.Posted and PC.Posted.Count and PC.Posted:Count(id) or 0
    return math.max(math.ceil(room) - posted, 1)
end

function Bank:SellableNow(id, n)
    local S = PC.Sell
    if not S or not S.Price then return 0 end
    local price, floor = S:Price(id)
    if not price or (floor and price < floor) then return 0 end
    local room
    local sold = PC.SalesEstimate and PC:SalesEstimate(id, 86400)
    if sold and sold > 0 then room = sold
    else
        local listed = PC:Supply()[id]
        if listed and listed > 0 then room = math.floor(listed * (PC.db.goldFlood or 20) / 100) else room = 5 end
    end
    local have = (PC.Posted and PC.Posted.Count and PC.Posted:Count(id) or 0) + PC:BagCount(id)
    return math.max(math.min(n, room - have), 0)
end

-- Is the bank open, by any sign the game gives? (the window, "talking to a banker", or the bank's own
-- slots answering) - if so and it wasn't noticed, it is now. Returns true when the bank is open.
function Bank:CheckOpen()
    if self.open then return true end
    local bf = _G.BankFrame
    local yes = (bf and bf.IsShown and bf:IsShown()) or (PC.Interacting and PC.Interacting("Banker"))
    if not yes then
        -- the bank's main bag reads back items only while you're at the bank
        local C = C_Container
        local BANK = (Enum and Enum.BagIndex and Enum.BagIndex.Bank) or -1
        local n = C and C.GetContainerNumSlots and C.GetContainerNumSlots(BANK) or 0
        for slot = 1, n do
            local info = C.GetContainerItemInfo and C.GetContainerItemInfo(BANK, slot)
            if info and info.itemID then yes = true break end
        end
    end
    if yes then self:OnEvent("BANKFRAME_OPENED") end
    return yes and true or false
end

-- a bank task you removed from the list: no bank trips for an hour
function Bank:Skipped() return (PC.cdb and PC.cdb.bankSkipUntil or 0) > time() end

function Bank:TakeList()
    local out = {}
    if not PC.UI or not self:Known() or self:Skipped() then return out end
    local entries = PC.UI:PlanEntries()
    -- the hearthstone you stored for room: back out once there's no crafting left to do
    if PC.cdb.hearthStored then
        if PC:BagCount(self.HEARTH) > 0 then PC.cdb.hearthStored = nil
        elseif self:Count(self.HEARTH) > 0 and (#entries == 0 or self.craftingDone) then
            out[#out + 1] = { id = self.HEARTH, name = PC:ItemName(self.HEARTH) or "Hearthstone", qty = 1, hearth = true }
        end
    end
    -- no plan, no bank trips: nothing comes out unless you're about to craft with it
    if #entries == 0 then return out end
    -- only for what will be crafted now (the market's share), not the whole plan
    if PC.Craft and PC.Craft.BuyEntries then entries = PC.Craft:BuyEntries(entries) end
    local list = PC:CombinedShoppingList(entries, 1)
    local visit = self.visit or { out = {}, inn = {} }
    -- something can be crafted from your bags already: that comes first, no materials out yet
    local later = PC:LaterMats(list) -- a later stage's materials stay in the bank until then
    if self.craftFirst then list = {} end
    for _, it in ipairs(list) do
        local inBank = later[it.id] and 0 or self:Count(it.id)
        if inBank > 0 and not (self.failed and self.failed[it.id]) and not visit.inn[it.id] then
            -- what the plan needs beyond what's already in your bags
            local need = (it.need or 0) - PC:BagCount(it.id)
            local take = math.min(need, inBank)
            if take > 0 then out[#out + 1] = { id = it.id, name = PC:ItemName(it.id), qty = take } end
        end
    end
    -- leftovers you chose to sell back: out they come, the next vendor buys them
    for id in pairs(self:SellBack()) do
        local inBank = self:Count(id)
        if inBank > 0 and not (self.failed and self.failed[id]) and not visit.inn[id] then
            out[#out + 1] = { id = id, name = PC:ItemName(id), qty = inBank, sellBack = true }
        end
    end
    -- crafted goods the current plan makes to sell, parked in the bank: out they come, to be sold
    -- (never materials, and nothing from an old plan)
    local allowed = self:Allowed()
    local b = self:Known()
    local sells = PC.Sell and PC.Sell.PlanItems and PC.Sell:PlanItems() or {}
    local need = PC.Sell and PC.Sell.PlanNeeds and PC.Sell:PlanNeeds() or {}
    for id, n in pairs(b and b.count or {}) do
        if allowed[id] == "crafted" and sells[id] and not need[id] and n > 0 and not (self.failed and self.failed[id]) and not visit.inn[id] then
            -- only what would actually sell now, at a profit, without flooding the AH: the rest stays put
            local qty = self:SellableNow(id, n)
            if qty > 0 then out[#out + 1] = { id = id, name = PC:ItemName(id), qty = qty, crafted = true } end
        end
    end
    -- tools the plan's recipes need (runed rods...) that are in the bank and not on you
    if PC.Craft and PC.Craft.Tool then
        local seen = {}
        for _, e in ipairs(entries) do
            local name, has, id = PC.Craft:Tool(e)
            if id and not has and not seen[id] and self:Count(id) > 0 and PC:BagCount(id) == 0 then
                seen[id] = true
                out[#out + 1] = { id = id, name = name, qty = 1, tool = true }
            end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Leftovers in the bank: materials and vendor tools the plan doesn't need. For each, the better of
-- crafting something profitable that uses them up, or selling them back to a vendor.
--   { id, name, n, craft = { recipeID, name, crafts, profit } | nil, vendor = copper | nil, chosen }
---------------------------------------------------------------------------
-- Vendor-bought materials in the bank your plan doesn't need (bleach, dyes, flint...): they come
-- out and go back to a vendor, unless you ticked them off as "keep" on the Sell page.
-- { [itemID] = true }
function Bank:KeepMats()
    PC.cdb.keepMats = PC.cdb.keepMats or {}
    return PC.cdb.keepMats
end

function Bank:SellBack()
    if not PC:SellLeftovers() then return {} end -- nothing comes out of the bank to be sold
    PC.cdb.bankSellBack = PC.cdb.bankSellBack or {}
    local t = PC.cdb.bankSellBack
    -- sold: none left in the bank or your bags
    for id in pairs(t) do
        if self:Count(id) == 0 and PC:BagCount(id) == 0 then t[id] = nil end
    end
    local now = GetTime and GetTime() or 0
    if self._sb and self._sbAt and now - self._sbAt < 1 then return self._sb end
    local out = {}
    local keep = self:KeepMats()
    for id in pairs(t) do if not keep[id] then out[id] = true end end
    local b = self:Known()
    if b and PC.UI and PC.UI.allEntries then
        local needed = {}
        local ok, list = pcall(PC.CombinedShoppingList, PC, PC.UI:PlanEntries(), 1)
        for _, it in ipairs(ok and list or {}) do needed[it.id] = true end
        local allowed = self:Allowed()
        for id, n in pairs(b.count or {}) do
            if n > 0 and not keep[id] and not needed[id] and allowed[id] == "material" and PC:IsVendorItem(id) and not PC:IsTool(id) then
                out[id] = true
            end
        end
    end
    self._sb, self._sbAt = out, now
    return out
end

function Bank:Leftovers()
    local out = {}
    local b = self:Known()
    if not b or not PC.UI then return out end
    local UI = PC.UI
    if not UI.allEntries then UI.allEntries = PC:Analyze() end
    local allowed = self:Allowed()
    local plan = PC:CurrentPlan()
    local needed = {}
    for _, it in ipairs(PC:CombinedShoppingList(UI:PlanEntries(), 1)) do needed[it.id] = true end
    for id, n in pairs(b.count or {}) do
        local kind = allowed[id] or (PC:IsVendorItem(id) and "material")
        if n > 0 and kind and kind ~= "crafted" and kind ~= "tool" and not PC:IsTool(id) and not needed[id] then
            local best
            for _, e in ipairs(UI.allEntries) do
                -- (a craft to suggest: one that clears the minimum profit, and for the AH, sold today)
                if e.profit and e.profit > 0 and PC:MeetsMin(e) and PC:SalesOK(e) then
                    for _, rg in ipairs(e.r.reagents or {}) do
                        local uses = false
                        for _, rid in ipairs(PC:ReagentIDs(rg)) do if rid == id then uses = true end end
                        if uses then
                            local crafts = math.floor(n / math.max(rg.n, 1))
                            local cap = PC.MakeGold and PC.MakeGold:MarketCap(e)
                            if cap then crafts = math.min(crafts, cap) end
                            crafts = math.min(crafts, 200)
                            if crafts > 0 and (not best or e.profit * crafts > best.profit) then
                                best = { recipeID = e.id, name = e.r.name, crafts = crafts, profit = e.profit * crafts }
                            end
                        end
                    end
                end
            end
            local each = PC.SellPrice and PC:SellPrice(id) or 0
            local entry = { id = id, name = PC:ItemName(id), n = n, craft = best, vendor = each > 0 and each * n or nil }
            entry.chosen = (best and plan[best.recipeID]) and "craft" or (self:SellBack()[id] and "sell") or nil
            if best or entry.vendor then out[#out + 1] = entry end
        end
    end
    table.sort(out, function(a, c) return (a.craft and a.craft.profit or a.vendor or 0) > (c.craft and c.craft.profit or c.vendor or 0) end)
    return out
end

-- Tick: craft it (adds the recipe to the plan) or sell it back (taken out, sold at the next vendor)
function Bank:ChooseLeftover(lo, on)
    if lo.craft then
        local plan = PC:CurrentPlan()
        if on then plan[lo.craft.recipeID] = (plan[lo.craft.recipeID] or 0) + lo.craft.crafts
        else plan[lo.craft.recipeID] = nil end
        if PC.UI then PC.UI.allEntries = nil end
    else
        self:KeepMats()[lo.id] = (not on) and true or nil -- unticked = keep it
        PC.cdb.bankSellBack = PC.cdb.bankSellBack or {}
        PC.cdb.bankSellBack[lo.id] = on and true or nil   -- ticked = sell it back, whatever it is
        self._sb = nil
    end
    PC:RefreshUI()
end

-- Things to park in the bank: crafted goods you're holding (not posting) and materials the plan doesn't use
-- Store unused items (a task you can skip): everything in your bags the plan doesn't use right
-- now - your other gear, food, odds and ends, even the hearthstone (it comes back out once the
-- crafting is done). Never: what the plan crafts with or makes, its tools, quest items, keep-in-stock.
Bank.HEARTH = 6948
function Bank:UnusedSkipped()
    local k = PC.cdb.unusedSkip
    return k and k == PC:PlanName() or false
end
function Bank:SkipUnused() PC.cdb.unusedSkip = PC:PlanName(); PC:RefreshUI() end

function Bank:UnusedList()
    local out = {}
    if not PC.UI or not PC.cdb or self:UnusedSkipped() then return out end
    local entries = PC.UI:PlanEntries()
    if #entries == 0 then return out end
    local used = {}
    local ok, list = pcall(PC.CombinedShoppingList, PC, entries, 1)
    for _, it in ipairs(ok and list or {}) do
        used[it.id] = true
        if it.craft and it.craft.r and it.craft.r.output then used[it.craft.r.output] = true end
    end
    for _, e in ipairs(entries) do
        used[e.outID or e.r.output or 0] = true
        for _, o in ipairs(e.r.outputs or {}) do used[o] = true end
        if PC.Craft and PC.Craft.Tool then local _, _, tid = PC.Craft:Tool(e); if tid then used[tid] = true end end
    end
    for id in pairs(PC.Sell and PC.Sell.PlanItems and PC.Sell:PlanItems() or {}) do used[id] = true end
    for id in pairs(PC.Synergy and PC.Synergy.PlanIDs and PC.Synergy:PlanIDs() or {}) do used[id] = true end
    for id in pairs(PC.Sell and PC.Sell.Stock and PC.Sell:Stock() or {}) do used[id] = true end
    local later = PC:LaterMats(ok and list or nil) -- (those go in as "later" already)
    local counts, slots = {}, {}
    local C = C_Container
    for _, s in ipairs(MyBagSlots()) do
        local quest = false
        if C and C.GetContainerItemQuestInfo then
            local okq, q = pcall(C.GetContainerItemQuestInfo, s.bag, s.slot)
            quest = okq and q and (q.isQuestItem or q.questID) and true or false
        end
        if not used[s.id] and not later[s.id] and not quest and not s.locked then
            counts[s.id] = (counts[s.id] or 0) + s.n
            slots[s.id] = (slots[s.id] or 0) + 1
        end
    end
    for id, n in pairs(counts) do out[#out + 1] = { id = id, name = PC:ItemName(id) or ("item " .. id), qty = n, kind = "unused", slots = slots[id] } end
    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
    return out
end

function Bank:StoreList()
    local out = {}
    if not PC.UI or not PC.cdb or self:Skipped() or not PC:UseBank() then return out end
    -- recipes you bought that you can't learn yet: they wait in the bank (plan or no plan)
    -- (only once you're back in town: a bank on this map, or at the bank)
    local br = PC.cdb.bankRecipes
    local inTown = (self.open or (PC.Bank and PC.Bank.Open and PC.Bank:Open())) or (PC.Places and select(2, PC.Places:Nearest("bank")) ~= nil)
    if br and next(br) and inTown then
        local n = {}
        for _, sl in ipairs(MyBagSlots()) do
            if br[sl.id] and not sl.locked then n[sl.id] = (n[sl.id] or 0) + sl.n end
        end
        for id, qty in pairs(n) do
            local ri = PC.ToLearn and PC.ToLearn:RecipeItem(id)
            if ri and (ri.known or PC.ToLearn:CanLearnNow(ri)) then br[id] = nil -- learnable now: learned instead
            else out[#out + 1] = { id = id, name = PC:ItemName(id), qty = qty, kind = "stash" } end
        end
    end
    local allowed = self:Allowed()
    local entries = PC.UI:PlanEntries()
    if #entries == 0 then return out end -- no plan: your bags are yours, nothing to store
    local list = PC:CombinedShoppingList(entries, 1)
    local needed = {}
    for _, it in ipairs(list) do needed[it.id] = (needed[it.id] or 0) + (it.need or 0) end
    -- a later stage's materials (the oil's vials while the greens are still being made): bank them
    local later = PC:LaterMats(list)
    for id in pairs(later) do needed[id] = 0 end
    for _, rg in ipairs({}) do end
    -- crafted items ready to sell stay in bags (you'll post them); held ones can be parked
    local selling = {}
    for _, it in ipairs(PC.Sell and PC.Sell:Items() or {}) do
        if it.have > 0 and it.price and not it.hold then selling[it.id] = true end
    end
    -- tools the plan's recipes still need stay with you; the rest can go back in
    local toolNeeded = {}
    if PC.Craft and PC.Craft.Tool then
        for _, e in ipairs(entries) do
            local _, _, id = PC.Craft:Tool(e)
            if id then toolNeeded[id] = true end
        end
    end
    local counts = {}
    for _, s in ipairs(MyBagSlots()) do
        if allowed[s.id] and not s.locked then counts[s.id] = (counts[s.id] or 0) + s.n end
    end
    local stash = PC.cdb.stashMats or {}
    for id, have in pairs(counts) do
        local keep = needed[id] or 0
        -- finished goods: what the market takes now stays to be posted; the rest waits in the bank
        -- and comes out a batch at a time (vendor items all stay: any vendor takes them)
        if allowed[id] == "crafted" then
            local via = PC.cdb.sellVia and PC.cdb.sellVia[id]
            if via == "Vendor" or not selling[id] then keep = have
            else keep = math.min(have, math.max(keep, self:MarketKeep(id))) end
        end
        if toolNeeded[id] then keep = have end
        if allowed[id] == "tool" and not toolNeeded[id] then keep = 0 end
        -- keep-in-stock targets stay in bags too
        if PC.Sell and PC.Sell:Stock()[id] then keep = math.max(keep, PC.Sell:Stock()[id]) end
        local spare = have - keep
        local visit = self.visit or { out = {}, inn = {} }
        -- vendor-bought materials the plan doesn't need go back to a vendor, not into the bank
        local sellsBack = PC:SellLeftovers() and PC:IsVendorItem(id) and not self:KeepMats()[id] and allowed[id] == "material"
        if spare > 0 and not (self.failed and self.failed[id]) and not self:SellBack()[id] and not visit.out[id]
            and not sellsBack and not (PC.cdb.bankSellBack or {})[id] then
            -- leftovers you chose to keep in the bank: always stored (not only when bags are tight)
            -- leftover materials go in the bank for the next craft (unless you sell them back)
            -- "stash" (always stored) only for what you chose to keep in the bank; anything else spare
            -- is stored only when your bags are short of room
            local kind = stash[id] and "stash" or allowed[id]
            if later[id] then kind = "later" end
            out[#out + 1] = { id = id, name = PC:ItemName(id), qty = spare, kind = kind }
        end
    end
    -- bags (nearly) full of the plan's own materials: one trip frees a real batch of room, not one
    -- slot - whole stacks of what you carry most of go in (at least one stack of each stays with you)
    local free = PC:FreeBagSlotsOnly()
    local target = self.BAG_RESERVE or 6
    if free < target then
        local freed = 0
        for _, it in ipairs(out) do freed = freed + math.floor(it.qty / math.max(PC:StackSize(it.id), 1)) end
        local need = target - free - freed
        if need > 0 then
            local full = {}
            for _, s in ipairs(MyBagSlots()) do
                local size = PC:StackSize(s.id)
                if allowed[s.id] == "material" and not s.locked and size > 1 and s.n >= size then
                    full[s.id] = (full[s.id] or 0) + 1
                end
            end
            local ids = {}
            for id, n in pairs(full) do if n >= 2 then ids[#ids + 1] = id end end
            table.sort(ids, function(x, y) return full[x] > full[y] end)
            -- a stack from whichever has most, round and round, until enough room is made
            local take = {}
            local progress = true
            while need > 0 and progress do
                progress = false
                table.sort(ids, function(x, y) return (full[x] - (take[x] or 0)) > (full[y] - (take[y] or 0)) end)
                local id = ids[1]
                if id and full[id] - (take[id] or 0) >= 2 then
                    take[id] = (take[id] or 0) + 1
                    need = need - 1
                    progress = true
                end
            end
            for id, n in pairs(take) do
                out[#out + 1] = { id = id, name = PC:ItemName(id), qty = n * PC:StackSize(id), kind = "room" }
            end
        end
    end
    -- the "Store unused items" task (unless you skipped it): your other things go in too
    if self.unusedWanted then
        local have = {}
        for _, it in ipairs(out) do have[it.id] = true end
        for _, it in ipairs(self:UnusedList()) do
            if not have[it.id] then
                out[#out + 1] = it
                if it.id == self.HEARTH then PC.cdb.hearthStored = true end -- it comes back after crafting
            end
        end
    end
    -- what frees the most bag room first; held goods and spent tools before materials
    local rank = { tool = 0, stash = 0, room = 0, later = 0, unused = 0, crafted = 1, material = 2 }
    table.sort(out, function(a, b)
        local ra, rb = rank[a.kind] or 3, rank[b.kind] or 3
        if ra ~= rb then return ra < rb end
        local sa, sb = math.ceil(a.qty / PC:StackSize(a.id)), math.ceil(b.qty / PC:StackSize(b.id))
        if sa ~= sb then return sa > sb end
        return (a.name or "") < (b.name or "")
    end)
    return out
end

-- What one click at the bank should really do, trimmed so neither side ever fills up:
--   take: plan materials that fit in your bags
--   store: held goods and spent tools; spare materials only while your bags are short of room;
--          never past the bank's reserve
-- returns take, store, and a note when something couldn't be placed (bank full)
function Bank:Plan()
    local take, store = self:TakeList(), self:StoreList()
    local b = self:Known()
    local bankRoom = math.max((b and b.free or 0) - self.BANK_RESERVE, 0)
    local bagFree = PC:FreeBagSlotsOnly()
    -- bag room the takes will use
    local takeSlots = 0
    for _, it in ipairs(take) do takeSlots = takeSlots + PC:SlotsFor(it.id, it.qty) end
    local wantFree = self.BAG_RESERVE + takeSlots
    local picked, usedBank, freed, blocked = {}, 0, 0, nil
    for _, it in ipairs(store) do
        local always = it.kind == "tool" or it.kind == "stash" or it.kind == "room" or it.kind == "later" or it.kind == "unused"
        if always or bagFree + freed < wantFree then
            local stack = PC:StackSize(it.id)
            local qty = it.qty
            -- spare materials: only as many stacks as it takes to get the bag reserve back
            if not always then
                local short = wantFree - (bagFree + freed)
                qty = math.min(qty, short * stack)
            end
            -- and only what the bank can take above its reserve (topping up its part stacks first)
            local room = 0
            for _, bs in ipairs(b and b.slots or {}) do if bs.id == it.id and bs.n < stack then room = room + (stack - bs.n) end end
            qty = math.min(qty, room + math.max(bankRoom - usedBank, 0) * stack)
            if qty > 0 then
                local c = {}
                for k, v in pairs(it) do c[k] = v end
                c.qty = qty
                picked[#picked + 1] = c
                usedBank = usedBank + SlotsNeeded(it.id, qty, b and b.slots or {})
                freed = freed + math.floor(qty / stack)
            end
            if qty < it.qty and not always then blocked = blocked or it end
        end
    end
    take = self:FitTake(take, freed)
    return take, picked, blocked
end

---------------------------------------------------------------------------
-- Will it fit? (slots after merging into stacks that already exist there)
---------------------------------------------------------------------------
-- how many slots `qty` of an item needs in a container, given free space in existing stacks
function SlotsNeeded(itemID, qty, existing)
    local stack = PC:StackSize(itemID)
    local room = 0
    for _, s in ipairs(existing) do
        if s.id == itemID and s.n < stack then room = room + (stack - s.n) end
    end
    local left = qty - room
    if left <= 0 then return 0 end
    return math.ceil(left / stack)
end

-- Trim a take list to what your bags can hold right now: part stacks fill up first, then free slots
function Bank:FitTake(list, extra)
    local bagSlots = MyBagSlots()
    -- taking out leaves room to work with (never fills the bags back up after a trip that emptied them)
    -- (a reagent bag takes materials too: they're what gets taken out)
    local free = math.max(PC:FreeBagSlotsOnly() + (PC.FreeReagentBagSlots and PC:FreeReagentBagSlots() or 0) + (extra or 0) - (self.BAG_RESERVE or 6), 0)
    local out = {}
    for _, it in ipairs(list) do
        local stack = PC:StackSize(it.id)
        local room = 0
        for _, s in ipairs(bagSlots) do if s.id == it.id and s.n < stack then room = room + (stack - s.n) end end
        local qty = math.min(it.qty, room + free * stack)
        if qty > 0 then
            local slotsUsed = math.max(math.ceil((qty - room) / stack), 0)
            free = free - slotsUsed
            local c = {}
            for k, v in pairs(it) do c[k] = v end
            c.qty = qty
            out[#out + 1] = c
        end
    end
    return out
end

function Bank:TakeFits(list)
    local bagSlots = MyBagSlots()
    local need = 0
    for _, it in ipairs(list) do need = need + SlotsNeeded(it.id, it.qty, bagSlots) end
    local free = PC:FreeBagSlotsOnly()
    return need <= free, need, free
end

---------------------------------------------------------------------------
-- Moving (one stack at a time, with a short gap, so the game keeps up)
---------------------------------------------------------------------------
local function PickUp(bag, slot)
    if C_Container and C_Container.PickupContainerItem then return C_Container.PickupContainerItem(bag, slot) end
    if PickupContainerItem then return PickupContainerItem(bag, slot) end
end
local function Split(bag, slot, n)
    if C_Container and C_Container.SplitContainerItem then return C_Container.SplitContainerItem(bag, slot, n) end
    if SplitContainerItem then return SplitContainerItem(bag, slot, n) end
end
local function UseItem(bag, slot)
    if C_Container and C_Container.UseContainerItem then return C_Container.UseContainerItem(bag, slot) end
    if UseContainerItem then return UseContainerItem(bag, slot) end
end

-- How many of an item sit in a set of bags
CountIn = function(bags, itemID)
    local n = 0
    for _, bag in ipairs(bags or {}) do
        for slot = 1, NumSlots(bag) do
            local id, c = SlotInfo(bag, slot)
            if id == itemID then n = n + (c or 1) end
        end
    end
    return n
end

-- First empty slot in a set of bags (nil if none)
local function EmptySlot(bags, itemID)
    local C = C_Container
    local fn = (C and C.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
    for _, bag in ipairs(bags) do
        local free = fn and (fn(bag) or 0) or 0
        if free > 0 and PC:CanHold(bag, itemID) then
            for slot = 1, NumSlots(bag) do
                if not SlotInfo(bag, slot) then return bag, slot end
            end
        end
    end
end

-- Move up to qty of itemID from one set of bags to another: pick the stack up and drop it on an
-- empty slot on the other side (part stacks are split first). Every move is checked afterwards,
-- so a stack that didn't go anywhere isn't counted and isn't offered again this visit.
function Bank:Queue(itemID, qty, fromBags, toBags, dir)
    local left = qty
    for _, bag in ipairs(fromBags) do
        for slot = 1, NumSlots(bag) do
            if left <= 0 then return end
            local id, n, locked = SlotInfo(bag, slot)
            if id == itemID and not locked then
                self.moves[#self.moves + 1] = { bag = bag, slot = slot, n = math.min(n, left), whole = n <= left, to = toBags, from = fromBags, id = itemID, dir = dir }
                left = left - math.min(n, left)
            end
        end
    end
end

-- (named apart from the game's ClearCursor: a local of that name called itself, a stack overflow whenever
-- an item was on the cursor)
local function DropCursor()
    if CursorHasItem and CursorHasItem() and ClearCursor then ClearCursor() end
end

function Bank:Step()
    if not self.open then self.busy = false; DropCursor() return end
    -- did the last move land? The server takes a moment: the item shows up on the far side (or leaves
    -- its old slot) a little after the drop, so look a few times before giving up on it
    local last = self.last
    if last and last.refused then
        -- the game said that bag can't hold it: put it back, never try that bag for it again, retry
        DropCursor()
        PC.refusedBag[last.tb .. ":" .. last.id] = true
        self.last = nil
        if last.m and (last.m.refusals or 0) < 4 then
            last.m.refusals = (last.m.refusals or 0) + 1
            table.insert(self.moves, 1, last.m)
        else
            self.skipped = self.skipped + 1
        end
        C_Timer.After(self.MOVE_GAP, function() PC:Safe("bank", Bank.Step, Bank) end)
        return
    end
    if last then
        -- landed? count it on the far side (works however the game placed it)
        local there = CountIn(last.m.to, last.id) > (last.toBefore or 0)
        local tid, tn = SlotInfo(last.tb, last.ts)
        there = there or (last.method == "drop" and tid == last.id and (tn or 0) >= (last.tn or 0) + 1)
        if there then
            self.moved = self.moved + 1
            self.method = last.method -- this way works on this client: use it first from now on
            -- what went where, for the summary
            local t = last.dir == "out" and self.movedOut or self.movedIn
            if t then t[last.id] = (t[last.id] or 0) + (last.n or 1) end
            -- never undo a move in the same visit (took it out: don't store it; stored it: don't take it)
            self.visit = self.visit or { out = {}, inn = {} }
            if last.dir == "out" then self.visit.out[last.id] = true else self.visit.inn[last.id] = true end
        elseif (last.tries or 0) < 8 then
            last.tries = (last.tries or 0) + 1
            C_Timer.After(self.MOVE_GAP, function() PC:Safe("bank", Bank.Step, Bank) end)
            return
        else
            DropCursor()
            self.last = nil
            -- didn't land: try the other way of moving it (drag-and-drop vs right-click) before giving up
            local other = last.method == "drop" and "use" or "drop"
            if not last.m.triedOther then
                last.m.triedOther = true
                last.m.method = other
                table.insert(self.moves, 1, last.m)
                C_Timer.After(self.MOVE_GAP, function() PC:Safe("bank", Bank.Step, Bank) end)
                return
            end
            self.skipped = self.skipped + 1
            self.failed = self.failed or {}
            self.failed[last.id] = true -- not offered again this visit
        end
        self.last = nil
    end
    local m = table.remove(self.moves, 1)
    if not m then return self:Done() end
    -- find the stack where it is now: you may have sorted your bags or bank since the list was made
    local id, have, locked = SlotInfo(m.bag, m.slot)
    if id ~= m.id or locked then
        local fb, fs, fn
        for _, bag in ipairs(m.from or {}) do
            for slot = 1, NumSlots(bag) do
                local sid, sn, sl = SlotInfo(bag, slot)
                if sid == m.id and not sl then
                    if not fn or (sn >= m.n and (fn < m.n or sn < fn)) then fb, fs, fn = bag, slot, sn end
                end
            end
        end
        if not fb then
            -- locked (the game or a sort is still moving it): wait a moment; gone: skip it
            if locked and id == m.id and (m.waits or 0) < 10 then
                m.waits = (m.waits or 0) + 1
                table.insert(self.moves, 1, m)
                C_Timer.After(self.MOVE_GAP, function() PC:Safe("bank", Bank.Step, Bank) end)
                return
            end
            return self:Step()
        end
        m.bag, m.slot = fb, fs
        m.n = math.min(m.n, fn)
        m.whole = fn <= m.n
    else
        m.n = math.min(m.n, have or m.n)
        m.whole = (have or 0) <= m.n
    end
    -- a part stack of the same item with room takes it first (the game merges them); else an empty slot
    local tb, ts
    local stack = PC:StackSize(m.id)
    for _, bag in ipairs(m.to) do
        for slot = 1, NumSlots(bag) do
            local sid, sn, slocked = SlotInfo(bag, slot)
            if sid == m.id and not slocked and (sn or 0) + m.n <= stack then tb, ts = bag, slot break end
        end
        if tb then break end
    end
    if not tb then tb, ts = EmptySlot(m.to, m.id) end
    if not tb then
        self.skipped = self.skipped + 1
        self.failed = self.failed or {}
        self.failed[m.id] = true
        self.moves = {} -- no room left on that side: stop
        return self:Done()
    end
    local _, srcN = SlotInfo(m.bag, m.slot)
    local _, tnBefore = SlotInfo(tb, ts)
    local toBefore = CountIn(m.to, m.id)
    -- the way that worked last time first: drag-and-drop, or right-click (the game picks the slot)
    local method = m.method or self.method or "drop"
    if method == "use" and m.whole then
        UseItem(m.bag, m.slot)
    else
        method = "drop"
        if m.whole then PickUp(m.bag, m.slot) else Split(m.bag, m.slot, m.n) end
        PickUp(tb, ts)
    end
    self.lastFrom, self.lastTo, self.lastTB = m.from, m.to, tb
    self.last = { m = m, method = method, toBefore = toBefore, dir = m.dir, n = m.n, tb = tb, ts = ts, id = m.id, fb = m.bag, fs = m.slot, srcN = srcN or 1, part = not m.whole, tn = tnBefore or 0 }
    C_Timer.After(self.MOVE_GAP, function() PC:Safe("bank", Bank.Step, Bank) end)
end

function Bank:Done()
    self.busy = false
    DropCursor()
    self:Scan()
    self.sig = self:Signature() -- our own moves aren't "you reorganised"
    local lines = {}
    local function list(t)
        local out = {}
        for id, n in pairs(t or {}) do out[#out + 1] = ("%d %s"):format(n, PC:ItemName(id) or ("item " .. id)) end
        table.sort(out)
        return out
    end
    local outL, inL = list(self.movedOut), list(self.movedIn)
    if #outL > 0 then
        lines[#lines + 1] = "Out to your bags (your plan needs them):"
        for _, l in ipairs(outL) do lines[#lines + 1] = "  " .. l end
    end
    if #inL > 0 then
        lines[#lines + 1] = "Into the bank (to free bag room):"
        for _, l in ipairs(inL) do lines[#lines + 1] = "  " .. l end
    end
    if self.moved > 0 and #outL + #inL == 0 then
        lines[#lines + 1] = ("Moved %d stack%s"):format(self.moved, self.moved == 1 and "" or "s")
    end
    if self.skipped > 0 then
        local names = {}
        for id in pairs(self.failed or {}) do names[#names + 1] = PC:ItemName(id) or ("item " .. id) end
        table.sort(names)
        lines[#lines + 1] = ("|cffff8040%d stack%s couldn't be moved (tried drag-and-drop and right-click)%s|r"):format(self.skipped, self.skipped == 1 and "" or "s",
            #names > 0 and (": " .. table.concat(names, ", ")) or ".")
        local errs = {}
        for msg in pairs(self.errors or {}) do errs[#errs + 1] = msg end
        if #errs > 0 then lines[#lines + 1] = "|cffff8040The game said: " .. table.concat(errs, " / ") .. "|r" end
        -- what it tried, so it can be fixed for your client: which bags, and how
        PC.Print(("Bank move details: from bags %s to bags %s, last bag tried %s, %s."):format(
            table.concat(self.lastFrom or {}, ","), table.concat(self.lastTo or {}, ","), tostring(self.lastTB or "?"),
            #errs > 0 and ("errors: " .. table.concat(errs, " / ")) or "no error from the game"))
    end
    if self.moved == 0 and self.skipped > 0 then
        lines[#lines + 1] = "|cff888888Close and reopen the bank to try again. The details are in your chat.|r"
        self.stuck = (self.stuck or 0) + 2
    end
    if #lines > 0 then PC:Note("At the bank", lines) end
    PC:RefreshUI()
end

-- One click: take plan materials out, put spare crafted goods and materials in. Never more than fits.
function Bank:Run()
    if not self.open then return PC.Buy:Say("|cffff8040Open your bank first.|r") end
    if self.busy then return end
    self:Scan()
    local take, store, blocked = self:Plan()
    if #take == 0 and #store == 0 then
        return PC.Buy:Say(blocked and ("|cffff8040Your bank is full: %s won't fit. Sell it or vendor it.|r"):format(blocked.name or "that")
            or "Nothing to move: your bags and bank are set for this plan.")
    end
    self.moves, self.moved, self.skipped, self.last = {}, 0, 0, nil
    self.errors = {}
    self.movedOut, self.movedIn = {}, {}
    self.plan = { take = #take, store = #store }
    local bags = PC:PlayerBags()
    local bankBags = BankBags()
    for _, it in ipairs(store) do self:Queue(it.id, it.qty, bags, bankBags, "in") end
    for _, it in ipairs(take) do self:Queue(it.id, it.qty, bankBags, bags, "out") end
    self.busy = true
    self:Step()
end

-- Text for the Next step button while the bank is open
function Bank:NextText()
    if not self.open or self.busy or (self.stuck or 0) >= 2 then return nil end
    self:Scan()
    local take, store = self:Plan()
    if #take == 0 and #store == 0 then return nil end -- nothing worth doing here: the next step takes over
    local parts = {}
    if #take > 0 then parts[#parts + 1] = "take " .. #take end
    if #store > 0 then parts[#parts + 1] = "store " .. #store end
    local tip, items = {}, {}
    for _, it in ipairs(take) do items[#items + 1] = ("take out %d %s"):format(it.qty, it.name or "") end
    for _, it in ipairs(store) do items[#items + 1] = ("store %d %s"):format(it.qty, it.name or "") end
    for _, it in ipairs(take) do tip[#tip + 1] = ("Take out %d %s (%s)"):format(it.qty, it.name or "",
        it.tool and "a tool your plan's recipes need" or it.crafted and "crafted: to sell" or "your plan needs it") end
    for _, it in ipairs(store) do
        tip[#tip + 1] = ("Store %d %s (%s)"):format(it.qty, it.name or "",
            it.kind == "tool" and "tool: the plan is done with it" or "spare material: kept for restocking, frees bag room")
    end
    tip[#tip + 1] = ("|cff888888Bags: %d free, bank: %d free. Keeps %d bag and %d bank slots empty.|r"):format(
        PC:FreeBagSlotsOnly(), self:FreeSlots(), self.BAG_RESERVE, self.BANK_RESERVE)
    return "Bank: " .. table.concat(parts, ", "), table.concat(tip, "\n"), items
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED", "BAG_UPDATE_DELAYED", "UI_ERROR_MESSAGE",
    "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }) do pcall(ev.RegisterEvent, ev, e) end
-- "That item doesn't go in that container" (a reagent or profession bag)
local function WrongBag(msg)
    if type(msg) ~= "string" then return false end
    if ERR_WRONG_BAG_TYPE and msg == ERR_WRONG_BAG_TYPE then return true end
    if ERR_ITEM_DOESNT_GO_INTO_BAG and msg == ERR_ITEM_DOESNT_GO_INTO_BAG then return true end
    if ERR_ITEM_DOESNT_GO_TO_BAG and msg == ERR_ITEM_DOESNT_GO_TO_BAG then return true end
    local l = msg:lower()
    return l:find("doesn't go in") ~= nil or l:find("does not go in") ~= nil or l:find("can't go in") ~= nil
end
function Bank:OnEvent(event, a1, a2)
    PC:Safe("bank", function()
        if event == "UI_ERROR_MESSAGE" then
            if Bank.busy then
                -- (the game keeps its messages secret at times: one that can't be read is passed over)
                if PC.IsSecret(a1) then a1 = nil end
                if PC.IsSecret(a2) then a2 = nil end
                local msg = type(a2) == "string" and a2 or (type(a1) == "string" and a1) or nil
                if msg then Bank.errors = Bank.errors or {}; Bank.errors[msg] = true end
                if Bank.last and (WrongBag(a2) or WrongBag(a1)) then Bank.last.refused = true end
            end
            return
        end
        if event == "BANKFRAME_OPENED" then
            Bank.open = true
            Bank.stuck, Bank.failed = nil, {}
            Bank.visit = { out = {}, inn = {} } -- what moved this visit (never moved back and forth)
            Bank:Scan()
            Bank.sig = Bank:Signature()
            PC:RefreshUI()
        elseif event == "BANKFRAME_CLOSED" then
            Bank.open, Bank.busy = false, false
            PC:RefreshUI()
        elseif Bank.open and not Bank.busy then
            -- you moved or sorted things: read where everything is now, and try again what failed
            -- (only when something really moved: a lock flicker after a failed drop doesn't count)
            PC:Debounce("bankscan", 0.5, function()
                local sig = Bank:Signature()
                if sig ~= Bank.sig then
                    Bank.sig = sig
                    Bank.stuck, Bank.failed = nil, {}
                end
                Bank:Scan()
                PC:RefreshUI()
            end)
        end
    end)
end
ev:SetScript("OnEvent", function(_, event, a1, a2)
    -- remember the last few (for /pc bank)
    if event ~= "BAG_UPDATE_DELAYED" and event ~= "UI_ERROR_MESSAGE" then
        Bank.seen = Bank.seen or {}
        table.insert(Bank.seen, event:gsub("PLAYER_INTERACTION_MANAGER_FRAME_", "PIM_") .. (a1 and ("(" .. tostring(a1) .. ")") or "") .. date(" %H:%M:%S"))
        while #Bank.seen > 6 do table.remove(Bank.seen, 1) end
    end
    -- the newer game clients say "talking to a banker" this way (some never send BANKFRAME_OPENED)
    if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        local E = Enum and Enum.PlayerInteractionType
        if not (E and E.Banker and a1 == E.Banker) then return end
        if event:find("SHOW") then
            if not Bank.open then Bank:OnEvent("BANKFRAME_OPENED") end
        elseif Bank.open then Bank:OnEvent("BANKFRAME_CLOSED") end
        return
    end
    Bank:OnEvent(event, a1, a2)
end)
