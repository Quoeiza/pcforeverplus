-- ProfitCrafter: professions helping each other
--   Disenchanting: green (uncommon) gear you can craft with one profession turns into dust, essences
--   and shards for Enchanting. So:
--     * an enchant that needs Strange Dust can get it by crafting a cheap green and disenchanting it,
--       when that's cheaper than buying the dust (and the green's own profession gets skill-ups too);
--     * a green that disenchants into more than it sells for is crafted and disenchanted, and the
--       dust is sold instead;
--     * tooltips say what a green disenchants into and what that's worth.
--   Other links (bars for Blacksmithing, bolts for Leatherworking, potions for Engineering...) go
--   through "make materials yourself": any recipe you know, in any profession, can supply another.

local ADDON, ns = ...
local PC = ns.PC

local Synergy = {}
PC.Synergy = Synergy

-- Disenchanting uncommon (green) armor and weapons, by item level: { maxLevel, skill needed,
-- { {itemID, expected per disenchant} ... } armor, then the weapon split (more essence) }
-- Dust / essence / shard ids
local STRANGE, SOUL, VISION, DREAM, ILLUSION = 10940, 11083, 11137, 11176, 16204
local LME, GME, LAE, GAE, LMYE, GMYE, LNE, GNE, LEE, GEE = 10938, 10939, 10998, 11082, 11134, 11135, 11174, 11175, 16202, 16203
local SGS, LGS, SGLS, LGLS, SRS, LRS, SBS, LBS = 10978, 11084, 11138, 11139, 11177, 11178, 14343, 14344
Synergy.DE_TABLE = {
    { 15, 1,   { { STRANGE, 1.2 }, { LME, 0.3 } },                     { { STRANGE, 0.3 }, { LME, 1.2 } } },
    { 20, 1,   { { STRANGE, 1.9 }, { GME, 0.3 }, { SGS, 0.05 } },     { { STRANGE, 0.5 }, { GME, 1.1 }, { SGS, 0.05 } } },
    { 25, 25,  { { STRANGE, 3.75 }, { LAE, 0.23 }, { SGS, 0.1 } },    { { STRANGE, 1.0 }, { LAE, 1.1 }, { SGS, 0.1 } } },
    { 30, 50,  { { SOUL, 1.1 }, { GAE, 0.3 }, { LGS, 0.05 } },        { { SOUL, 0.3 }, { GAE, 1.1 }, { LGS, 0.05 } } },
    { 35, 75,  { { SOUL, 2.6 }, { LMYE, 0.3 }, { SGLS, 0.05 } },      { { SOUL, 0.7 }, { LMYE, 1.1 }, { SGLS, 0.05 } } },
    { 40, 100, { { VISION, 1.1 }, { GMYE, 0.3 }, { LGLS, 0.05 } },    { { VISION, 0.3 }, { GMYE, 1.1 }, { LGLS, 0.05 } } },
    { 45, 125, { { VISION, 2.6 }, { LNE, 0.3 }, { SRS, 0.05 } },      { { VISION, 0.7 }, { LNE, 1.1 }, { SRS, 0.05 } } },
    { 50, 150, { { DREAM, 1.1 }, { GNE, 0.3 }, { LRS, 0.05 } },       { { DREAM, 0.3 }, { GNE, 1.1 }, { LRS, 0.05 } } },
    { 55, 175, { { DREAM, 2.6 }, { LEE, 0.3 }, { SBS, 0.05 } },       { { DREAM, 0.7 }, { LEE, 1.1 }, { SBS, 0.05 } } },
    { 60, 200, { { ILLUSION, 1.1 }, { GEE, 0.3 }, { LBS, 0.05 } },    { { ILLUSION, 0.3 }, { GEE, 1.1 }, { LBS, 0.05 } } },
    { 65, 225, { { ILLUSION, 2.6 }, { GEE, 0.5 }, { LBS, 0.05 } },    { { ILLUSION, 0.7 }, { GEE, 1.5 }, { LBS, 0.05 } } },
}
Synergy.DE_MATS = {}
for _, row in ipairs(Synergy.DE_TABLE) do
    for _, part in ipairs({ row[3], row[4] }) do for _, m in ipairs(part) do Synergy.DE_MATS[m[1]] = true end end
end

local function Info(itemID)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not getInfo or not itemID then return nil end
    local name, _, quality, ilvl, _, _, _, _, equipLoc, _, _, classID = getInfo(itemID)
    if not name then return nil end
    return quality, ilvl, classID, equipLoc
end

-- Your Enchanting skill (nil if you don't have Enchanting)
function Synergy:EnchantingSkill()
    for _, pr in pairs(PC.cdb and PC.cdb.professions or {}) do
        if pr.name == "Enchanting" then return pr.rank or 0 end
    end
    return nil
end

-- What one disenchant of an item gives: { {itemID, expected}, ... } and the skill it needs (nil: can't)
function Synergy:Yield(itemID)
    local quality, ilvl, classID = Info(itemID)
    if quality ~= 2 or not ilvl or (classID ~= 2 and classID ~= 4) then return nil end -- green armor/weapons only
    for _, row in ipairs(self.DE_TABLE) do
        if ilvl <= row[1] then return classID == 2 and row[4] or row[3], row[2] end
    end
    return nil
end

-- Does the game say "Cannot be disenchanted" on this item? (the Greater Magic Wand does here)
-- Read once from its tooltip and remembered; also learned when a disenchant gets refused.
local NOT_DE = ITEM_DISENCHANT_NOT_DISENCHANTABLE or "Cannot be disenchanted"
-- the enchanters' own wands say so (known up front, so they're never planned for dust)
Synergy.NEVER_DE = { [11287] = true, [11288] = true } -- Lesser Magic Wand, Greater Magic Wand
function Synergy:Blocked(itemID)
    if not itemID then return false end
    if self.NEVER_DE[itemID] then return true end
    local db = PC.db
    db.noDE = db.noDE or {}
    if db.noDE[itemID] ~= nil then return db.noDE[itemID] end
    local T = C_TooltipInfo
    if not (T and T.GetItemByID) then return false end
    local ok, data = pcall(T.GetItemByID, itemID)
    -- not loaded yet: not planned for dust until the game says it can be (asked again later)
    if not ok or not data or not data.lines or #data.lines == 0 then
        if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
        return true
    end
    local blocked = false
    for _, line in ipairs(data.lines) do
        local t = line.leftText or ""
        if t == NOT_DE or t:find("annot be disenchanted") then blocked = true end
    end
    db.noDE[itemID] = blocked
    return blocked
end

-- Can you disenchant it (you have Enchanting, with enough skill)?
function Synergy:CanDisenchant(itemID)
    local skill = self:EnchantingSkill()
    if not skill then return false end
    if self:Blocked(itemID) then return false end
    local yield, need = self:Yield(itemID)
    return yield ~= nil and skill >= (need or 1)
end

-- What disenchanting one is worth at AH prices (after the AH's cut), or nil
function Synergy:Value(itemID)
    local yield = self:Yield(itemID)
    if not yield then return nil end
    local total, known = 0, false
    for _, m in ipairs(yield) do
        local p = PC:Price(m[1])
        if p then total = total + p * m[2]; known = true end
    end
    if not known then return nil end
    return total * (1 - (PC.AH_CUT or 0.05))
end

-- "Disenchants into ~1.9 Strange Dust, 0.3 Greater Magic Essence (worth 45s)"
function Synergy:Describe(itemID)
    local yield, need = self:Yield(itemID)
    if not yield then return nil end
    local parts = {}
    for _, m in ipairs(yield) do
        if m[2] >= 0.1 then parts[#parts + 1] = ("%s %s"):format(m[2] % 1 == 0 and tostring(m[2]) or ("%.1f"):format(m[2]), PC:ItemName(m[1]) or ("item " .. m[1])) end
    end
    local v = self:Value(itemID)
    local skill = self:EnchantingSkill()
    local note = (not skill and " (needs Enchanting)") or (skill < (need or 1) and (" (needs Enchanting %d)"):format(need)) or ""
    return ("Disenchants into about %s%s%s"):format(table.concat(parts, ", "), v and (" (worth %s)"):format(PC:Money(v, false, true)) or "", note)
end

-- The cheapest way to get a dust/essence/shard by crafting a green you know and disenchanting it:
-- cost per one, the recipe id, the recipe, and how many one craft yields. nil if none is cheaper to know.
function Synergy:DECost(matID, depth)
    local memo = PC:Memo()
    if memo then
        local key = "de" .. tostring(matID) .. ":" .. tostring(depth or 0)
        local hit = memo[key]
        if hit then return hit[1], hit[2], hit[3], hit[4] end
        local a, b, c, d = self:DECostRaw(matID, depth)
        memo[key] = { a, b, c, d }
        return a, b, c, d
    end
    return self:DECostRaw(matID, depth)
end
function Synergy:DECostRaw(matID, depth)
    if not self.DE_MATS[matID] or PC.cdb.vertical == false or (depth or 0) > 1 then return nil end
    if not self:EnchantingSkill() then return nil end
    local best, bestID, bestR, bestY
    -- never something the plan makes to sell (that wand goes to the AH, not into dust)
    local selling = {}
    for recipeID in pairs(PC.CurrentPlan and PC:CurrentPlan() or {}) do
        local pr = PC.cdb.recipes[recipeID]
        if pr and pr.output then selling[pr.output] = true end
    end
    for id, r in pairs(PC.cdb.recipes or {}) do
        local out = r.output
        -- and never a recipe that needs the very thing it would be disenchanted for (a wand made
        -- from essence, disenchanted for essence, goes round in circles)
        local loops = false
        for _, rg in ipairs(r.reagents or {}) do
            for _, rid in ipairs(PC:ReagentIDs(rg)) do if rid == matID then loops = true end end
        end
        if out and not loops and not selling[out] and r.reagents and #r.reagents > 0 and self:CanDisenchant(out) then
            local yield = self:Yield(out)
            local y = 0
            for _, m in ipairs(yield or {}) do if m[1] == matID then y = m[2] end end
            if y >= 0.25 then
                local cost = 0
                for _, rg in ipairs(r.reagents) do
                    local _, c = PC:BestReagent(rg, (depth or 0) + 1)
                    if not c then cost = nil break end
                    cost = cost + c * rg.n
                end
                if cost then
                    local per = cost / (y * math.max(r.qty or 1, 1))
                    if not best or per < best then best, bestID, bestR, bestY = per, id, r, y * math.max(r.qty or 1, 1) end
                end
            end
        end
    end
    return best, bestID, bestR, bestY
end

-- Disenchanting: the game's spell (the button casts it on the item through a secure click)
Synergy.DISENCHANT_SPELL = 13262
function Synergy:SpellName()
    if C_Spell and C_Spell.GetSpellName then local ok, n = pcall(C_Spell.GetSpellName, self.DISENCHANT_SPELL); if ok and n then return n end end
    if GetSpellInfo then local ok, n = pcall(GetSpellInfo, self.DISENCHANT_SPELL); if ok and n then return n end end
    return "Disenchant"
end

-- Greens in your bags waiting to be disenchanted (made for it): { id, name, bag, slot, n }
-- what the plan makes to disenchant (its route, or greens made for an enchant's dust)
function Synergy:PlanIDs()
    local now = GetTime and GetTime() or 0
    if self._ids and self._idsAt and now - self._idsAt < 2 then return self._ids end
    local ids = {}
    local UI = PC.UI
    if UI and UI.PlanEntries then
        local entries = UI:PlanEntries()
        for _, e in ipairs(entries) do
            if e.route == "Disenchant" then ids[e.outID or e.r.output or 0] = true end
        end
        local ok, list = pcall(PC.CombinedShoppingList, PC, entries, 1)
        for _, it in ipairs(ok and list or {}) do
            if it.craft and it.craft.disenchant and it.craft.r and it.craft.r.output then ids[it.craft.r.output] = true end
        end
    end
    self._ids, self._idsAt = ids, now
    return ids
end

function Synergy:ToDisenchant()
    local cdb = PC.cdb
    cdb.deMade = cdb.deMade or {}
    -- (one time: greens a Make me gold plan made for their dust in the last few hours, which were
    -- wrongly taken off the list when the plan finished, go back on it)
    if not cdb.deFix1 and PC.UI and PC.UI.allEntries then
        cdb.deFix1 = true
        for _, e in ipairs(PC.UI.allEntries) do
            local id = e.outID or e.r.output
            local t = id and cdb.planCrafted and cdb.planCrafted[id]
            if t and e.route == "Disenchant" and time() - t < 6 * 3600 and (cdb.planCraftedPlan or {})[id] == "Make me gold" then
                local n = PC:BagCount(id)
                if n > 0 then
                    cdb.deQueue = cdb.deQueue or {}
                    cdb.deQueue[id] = n
                    cdb.deMade[id] = time()
                end
            end
        end
    end
    -- made for their dust: remembered for a day, or until none are left in your bags
    for id, t in pairs(cdb.deMade) do
        if time() - t > 86400 or (time() - t > 120 and PC:BagCount(id) == 0) then cdb.deMade[id] = nil end
    end
    -- queued when crafted, plus anything in your bags the plan made for disenchanting
    local want = {}
    for id, n in pairs(PC.cdb.deQueue or {}) do if n > 0 then want[id] = n end end
    for id in pairs(self:PlanIDs()) do want[id] = want[id] or 1 end
    -- never what the game won't disenchant (it'd sit on "Disenchant" forever)
    for id in pairs(want) do
        if self:Blocked(id) then want[id] = nil; if PC.cdb.deQueue then PC.cdb.deQueue[id] = nil end end
    end
    -- never anything the plan makes to sell (a wand going to the AH stays a wand): it comes off the
    -- queue too, so the step doesn't get stuck on it
    local de = self:PlanIDs()
    local sells = {}
    for _, e in ipairs(PC.UI and PC.UI.PlanEntries and PC.UI:PlanEntries() or {}) do
        local id = e.outID or e.r.output
        if id and e.route ~= "Disenchant" and not de[id] then sells[id] = true end
    end
    -- (a green made for its dust stays for disenchanting after its plan is finished and gone: all 18
    -- gloves, not 2 on the AH and 16 left in your bags)
    for id in pairs(sells) do if cdb.deMade[id] then sells[id] = nil end end
    for id in pairs(PC.cdb.planCrafted or {}) do if not de[id] and not cdb.deMade[id] then sells[id] = true end end
    for id in pairs(sells) do
        want[id] = nil
        if PC.cdb.deQueue then PC.cdb.deQueue[id] = nil end
    end
    local out = {}
    if not next(want) then return out end
    local C = C_Container
    local numSlots = (C and C.GetContainerNumSlots) or GetContainerNumSlots
    for _, bag in ipairs(PC:PlayerBags()) do
        for slot = 1, (numSlots and numSlots(bag) or 0) do
            local id
            if C and C.GetContainerItemInfo then
                local info = C.GetContainerItemInfo(bag, slot)
                id = info and info.itemID
            elseif GetContainerItemID then id = GetContainerItemID(bag, slot) end
            if id and (want[id] or 0) > 0 then
                out[#out + 1] = { id = id, name = PC:ItemName(id) or ("item " .. id), bag = bag, slot = slot }
            end
        end
    end
    return out
end

-- Nothing a plan made is left sitting in your bags: what it crafted in the last day beyond what the
-- Auction House will take (already posted, plus what sells in a day) goes on the disenchant list,
-- when you can disenchant it and its dust is worth at least what a vendor pays.
function Synergy:QueueExtras()
    local cdb = PC.cdb
    if not cdb or not PC.Sell or not self:EnchantingSkill() then return end
    local Bk, now = PC.Bank, time()
    for _, it in ipairs(PC.Sell:Items()) do
        local made = cdb.planCrafted and cdb.planCrafted[it.id]
        local skipped = cdb.extraSkip and cdb.extraSkip[it.id] and now - cdb.extraSkip[it.id] < 3600
        if (it.have or 0) > 0 and made and now - made < 86400 and not skipped and self:CanDisenchant(it.id) then
            -- (what's going up on the AH now, and your keep-in-stock number, stay; the rest is extra)
            local keep = math.max(it.stock or 0, it.sellN or 0)
            local extra = it.have - keep
            local vend = PC:SellPrice(it.id) or 0
            local val = self:Value(it.id)
            -- worth more as dust than on the AH at today's price (prices move after the plan was
            -- made): all of them are disenchanted, not posted
            local ahNet = (not it.vendor and it.price) and it.price * (1 - (PC.AH_CUT or 0.05)) or nil
            local all = it.have - (it.stock or 0)
            if val and ahNet and val > ahNet and val >= vend and all >= 1 and PC.db.deForMats ~= false then
                self:Queue(it.id, all)
            elseif extra >= 2 and val and val >= vend then
                self:Queue(it.id, extra)
            end
        end
    end
end

-- Mark crafted greens for disenchanting (the plan made them for their dust)
function Synergy:Queue(itemID, n)
    PC.cdb.deMade = PC.cdb.deMade or {}
    PC.cdb.deMade[itemID] = time()
    PC.cdb.deQueue = PC.cdb.deQueue or {}
    PC.cdb.deQueue[itemID] = (PC.cdb.deQueue[itemID] or 0) + (n or 1)
end

-- One was disenchanted (or sold, or gone): one fewer waiting
function Synergy:Done(itemID)
    local q = PC.cdb.deQueue
    if not q or not q[itemID] then return end
    q[itemID] = q[itemID] - 1
    if q[itemID] <= 0 then q[itemID] = nil end
end

-- The secure click that casts Disenchant on a bag slot (the game only allows this from a real click)
function Synergy:SecureButton()
    if self.secure then return self.secure end
    if not CreateFrame then return nil end
    -- made once, at load, on the screen itself (not inside the bar), so nothing can stop it being made
    local ok, b = pcall(CreateFrame, "Button", "ProfitCrafterDisenchantButton", UIParent, "SecureActionButtonTemplate")
    if not ok or not b then
        if not self.madeErr then self.madeErr = true; PC.Print("|cffff5555Disenchant button couldn't be made: " .. tostring(b) .. "|r") end
        return nil
    end
    b:SetSize(10, 10)
    b:SetPoint("CENTER")
    b:EnableMouse(true)
    -- both: a mouse click, a key and a /click macro each arrive as a press or a release depending on
    -- the game's "cast on key down" setting; a second cast while the first is going just fails harmlessly
    b:RegisterForClicks("AnyUp", "AnyDown")
    -- the game's own way to cast a spell on a bag item: spell + target-bag/target-slot
    b:SetAttribute("type", "spell")
    b:SetAttribute("spell", self:SpellName())
    b:SetAttribute("type2", "stop") -- right-click: cast nothing (it skips the step, below)
    b:SetScript("PostClick", function(_, mouse, down)
        if mouse == "RightButton" and not down and PC.Next and PC.Next.Skip then PC.Next:Skip() end
    end)
    -- no highlight of its own: hovering lights up the real step button underneath, the whole of it
    b:SetScript("OnEnter", function()
        local p = Synergy.under
        if p and p.LockHighlight then p:LockHighlight() end
        if p and p:GetScript("OnEnter") then p:GetScript("OnEnter")(p) end
    end)
    b:SetScript("OnLeave", function()
        local p = Synergy.under
        if p and p.UnlockHighlight then p:UnlockHighlight() end
        if GameTooltip then GameTooltip:Hide() end
    end)
    b:Hide()
    -- aim it at the next green right as it's clicked (before the cast happens), so it never fires
    -- unaimed, whatever the bar was doing
    b:SetScript("PreClick", function(btn)
        if InCombatLockdown and InCombatLockdown() then return end
        -- learning a recipe from your bags: use that item (found again, in case it moved)
        local u = Synergy.useTarget
        if u then
            for _, sl in ipairs(PC.BagSlots and PC.BagSlots() or {}) do
                if sl.id == u.id then u.bag, u.slot = sl.bag, sl.slot break end
            end
            btn:SetAttribute("type", "item")
            btn:SetAttribute("item", u.bag .. " " .. u.slot)
            return
        end
        local list = Synergy:ToDisenchant()
        local it = list[1]
        Synergy.target = it
        if it then
            btn:SetAttribute("type", "spell")
            btn:SetAttribute("spell", Synergy:SpellName())
            btn:SetAttribute("target-bag", it.bag)
            btn:SetAttribute("target-slot", it.slot)
        else
            btn:SetAttribute("type", nil) -- nothing to disenchant: the click does nothing
        end
    end)
    b:HookScript("OnClick", function(_, mouse, down)
        if mouse == "RightButton" then return end
        if Synergy.useTarget then
            if not down then
                local u = Synergy.useTarget
                PC.Print(u.hearth and "Using your Hearthstone." or ("Learning %s."):format(u.name or "the recipe"))
                C_Timer.After(2, function() if PC.ToLearn then PC.ToLearn:Changed() end; PC:RefreshUI() end)
            end
            return
        end
        local t = Synergy.target
        -- say what the click did, so a problem can be told apart from a click that never arrived
        PC.Print(("Disenchant: casting on %s (bag %s, slot %s) [%s]%s"):format(t and t.name or "?", t and tostring(t.bag) or "?",
            t and tostring(t.slot) or "?", (down and "press" or "release") .. ((GetCVar and (" kd" .. tostring(GetCVar("ActionButtonUseKeyDown")))) or ""), (InCombatLockdown and InCombatLockdown()) and " |cffff5555(in combat: the game blocks it)|r" or ""))
        Synergy.clickedAt = GetTime()
        if t then C_Timer.After(3, function() PC:RefreshUI() end) end
    end)
    self.secure = b
    return b
end

-- Point the secure click at one item (out of combat only; the game locks it in combat)
function Synergy:Arm(parent, item)
    local b = self:SecureButton()
    if not b or (InCombatLockdown and InCombatLockdown()) then return false end
    self.target = item
    -- sit exactly over the step button, one layer above it. It stays a child of the screen and is
    -- placed by screen position (not hooked to the bar): the game can refuse to tie a protected
    -- button to an addon's frame, which is what kept clicks from reaching it before.
    local ok, err = pcall(function()
        if b:GetParent() ~= UIParent then b:SetParent(UIParent) end
        b:ClearAllPoints()
        local l, bt = parent and parent:IsVisible() and parent:GetLeft(), parent and parent:GetBottom()
        if l and bt then
            local k = parent:GetEffectiveScale() / UIParent:GetEffectiveScale()
            b:SetSize(parent:GetWidth() * k, parent:GetHeight() * k)
            b:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l * k, bt * k)
            b:SetFrameStrata("HIGH")
            b:EnableMouse(true)
            self.under = parent
        else
            -- no bar on screen: off to the side, still there for your key
            b:SetSize(1, 1)
            b:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", -10, -10)
            b:EnableMouse(false)
            self.under = nil
        end
    end)
    if ok then
        self.lastErr = nil
        -- only now that it's in place: the step button under it stops taking the mouse
        if self.under and self.under.EnableMouse then self.under:EnableMouse(false) end
    else
        self.lastErr = tostring(err)
        if self.under and self.under.EnableMouse then self.under:EnableMouse(true) end
        if not self.errAt or GetTime() - self.errAt > 10 then
            self.errAt = GetTime()
            PC.Print("|cffff5555Disenchant button couldn't sit on the Task Button: " .. self.lastErr .. "|r")
        end
    end
    if item.use then
        -- a recipe to learn: use the item
        self.useTarget, self.target = item, nil
        b:SetAttribute("type", "item")
        b:SetAttribute("item", item.bag .. " " .. item.slot)
        b:SetAttribute("spell", nil)
        b:SetAttribute("target-bag", nil)
        b:SetAttribute("target-slot", nil)
    else
        self.useTarget, self.target = nil, item
        b:SetAttribute("type", "spell")
        b:SetAttribute("item", nil)
        b:SetAttribute("spell", self:SpellName())
        b:SetAttribute("target-bag", item.bag)
        b:SetAttribute("target-slot", item.slot)
    end
    b:SetAttribute("unit", nil)
    b:Show()
    -- your Next step key does it too: while there's something to disenchant, the key clicks this button
    if SetOverrideBindingClick and GetBindingKey then
        local keys = { GetBindingKey("PROFITCRAFTER_NEXT") }
        if #keys > 0 then
            for _, k in ipairs(keys) do pcall(SetOverrideBindingClick, b, true, k, "ProfitCrafterDisenchantButton", "LeftButton") end
            self.keyBound = true
        end
    end
    return ok, err
end

function Synergy:Disarm()
    if self.secure and not (InCombatLockdown and InCombatLockdown()) then
        self.secure:Hide()
        if self.under and self.under.EnableMouse then self.under:EnableMouse(true) end
        if self.under and self.under.UnlockHighlight then self.under:UnlockHighlight() end
        self.under = nil
        if self.keyBound and ClearOverrideBindings then pcall(ClearOverrideBindings, self.secure); self.keyBound = nil end
    end
    self.target, self.useTarget = nil, nil
end

-- the disenchant went through: one fewer waiting (and if it didn't, say why)
local ev = CreateFrame("Frame")
for _, e in ipairs({ "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED", "UI_ERROR_MESSAGE" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, event, unit, a2, spellID)
    local recent = Synergy.clickedAt and GetTime() - Synergy.clickedAt < 3
    if event == "UI_ERROR_MESSAGE" then
        if recent then
            local msg = tostring(a2 or unit)
            PC.Print("Disenchant: the game said: " .. msg)
            -- refused for good ("Cannot be disenchanted"): never asked to disenchant it again
            local t = Synergy.target
            if t and t.id and msg:lower():find("disenchant") then
                PC.db.noDE = PC.db.noDE or {}
                PC.db.noDE[t.id] = true
                if PC.cdb.deQueue then PC.cdb.deQueue[t.id] = nil end
                Synergy.target = nil
                PC:RefreshUI()
            end
        end
        return
    end
    if event == "UNIT_SPELLCAST_FAILED" then
        if unit == "player" and recent then PC.Print("Disenchant: the cast failed (spell " .. tostring(spellID) .. ").") end
        return
    end
    if unit ~= "player" or spellID ~= Synergy.DISENCHANT_SPELL then return end
    -- disenchanting one after another: the full refresh waits until you stop
    Synergy.deAt = GetTime()
    PC.craftingUntil = GetTime() + 3
    PC:Safe("disenchant", function()
        local t = Synergy.target
        if t then
            Synergy:Done(t.id)
            -- what it gave counts as yours to sell (the AH gets the dust)
            -- the dust is for sale only when the plan made this item to sell its dust; dust made
            -- for crafting (the oil) stays yours to craft with
            local sells = false
            for _, e in ipairs(PC.UI and PC.UI.PlanEntries and PC.UI:PlanEntries() or {}) do
                if (e.outID or e.r.output) == t.id and e.route == "Disenchant" then sells = true end
            end
            if sells then
                PC.cdb.deSell = PC.cdb.deSell or {}
                for _, m in ipairs(Synergy:Yield(t.id) or {}) do PC.cdb.deSell[m[1]] = true end
            end
        end
        Synergy.target = nil
        C_Timer.After(1.5, function() PC:RefreshUI() end)
    end)
end)

-- Keep the button aimed at the next green to disenchant, whether or not the step bar is showing,
-- and keep the count honest (greens disenchanted by hand, sold or banked come off it)
function Synergy:Refresh()
    if InCombatLockdown and InCombatLockdown() then return end
    local q = PC.cdb and PC.cdb.deQueue
    if q then
        for id, n in pairs(q) do
            local have = PC:BagCount(id)
            if have < n then q[id] = have > 0 and have or nil end
        end
    end
    local list = self:ToDisenchant()
    local bar = PC.Next and PC.Next.bar
    local parent = bar and bar:IsShown() and bar.btn or nil
    -- only while the step itself says Disenchant: otherwise the button and key do that step
    local step = PC.Next and PC.Next.Compute and PC.Next:Compute()
    if list[1] and step and step.deItem then self:Arm(parent, step.deItem)
    elseif step and step.useItem then self:Arm(parent, step.useItem)
    else self:Disarm() end
end

-- In the middle of disenchanting one after another: just aim the button at the next one (the full
-- work-out of the next task waits until you stop; doing it after every disenchant froze the game)
function Synergy:Rearm()
    if InCombatLockdown and InCombatLockdown() then return end
    local q = PC.cdb and PC.cdb.deQueue
    if q then
        for id, n in pairs(q) do
            local have = PC:BagCount(id)
            if have < n then q[id] = have > 0 and have or nil end
        end
    end
    local list = self:ToDisenchant()
    local bar = PC.Next and PC.Next.bar
    local parent = bar and bar:IsShown() and bar.btn or nil
    if list[1] then
        self:Arm(parent, list[1])
        -- the count on the button, kept honest without the full refresh
        if bar and bar.btn and bar.btn.SetText then
            pcall(bar.btn.SetText, bar.btn, ("Disenchant %s"):format(list[1].name or "?"))
        end
    else
        -- all done: now the next task
        self.deAt = nil
        if PC.craftingUntil then PC.craftingUntil = nil end
        self:Refresh()
        PC:RefreshUI(true)
    end
end

local bagEv = CreateFrame("Frame")
for _, e in ipairs({ "BAG_UPDATE_DELAYED", "PLAYER_REGEN_ENABLED" }) do pcall(bagEv.RegisterEvent, bagEv, e) end
bagEv:SetScript("OnEvent", function()
    if Synergy.deAt and GetTime() - Synergy.deAt < 3 then
        return PC:Safe("disenchant", Synergy.Rearm, Synergy)
    end
    -- not after every craft of a batch: once it's over
    if PC.Downtime then PC:Downtime("disenchant", function() Synergy:Refresh() end)
    elseif PC.WhenIdle then PC:WhenIdle("disenchant", function() PC:Safe("disenchant", Synergy.Refresh, Synergy) end)
    else PC:Safe("disenchant", Synergy.Refresh, Synergy) end
end)

-- make the button now, while nothing can be in the way (out of combat at load)
if PC.Safe then PC:Safe("disenchant button", Synergy.SecureButton, Synergy) else Synergy:SecureButton() end
