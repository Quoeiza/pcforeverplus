-- ProfitCrafter: window, Crafting plan tab

local ADDON, ns = ...
local PC = ns.PC
local UI = PC.UI
local P = UI.Parts
local HasTemplate = P.HasTemplate
local Text = P.Text
local CraftButton = P.CraftButton
local Columns, FitCell, PW, RW, LIST_Y = P.Columns, P.FitCell, P.PW, P.RW, P.LIST_Y
local HeaderStrip = P.HeaderStrip
local ItemIcon = P.ItemIcon
local Panel = P.Panel
local ROW_H = P.ROW_H
local RowText = P.RowText
local SetSkillArrows = P.SetSkillArrows
local ShowTooltip = P.ShowTooltip
local SkillArrows = P.SkillArrows
local Stripe = P.Stripe
local T = P.T
local ITEM_ROWS = P.ITEM_ROWS
local ITEM_ROW_H = P.ITEM_ROW_H
local QUESTION = P.QUESTION
local STATUS_TEXT = P.STATUS_TEXT
local RECENT_ROWS = P.RECENT_ROWS
local StatStrip = P.StatStrip
local CLICK_HINT = P.CLICK_HINT

---------------------------------------------------------------------------
-- Tab 2: Crafting plan
---------------------------------------------------------------------------
-- The Crafting plan: every recipe you want to make, how many of each, and everything to buy for all of it.
-- Recipes get here from the bag icon on the Recipes tab (it asks how many).
local PLAN_ROWS, MAT_ROWS = 5, 5
local PLAN_TOP = -90   -- plan bar (which saved plan) sits above, at -62
local PLAN_H = -LIST_Y + PLAN_ROWS * ROW_H + 8 -- a table: its header, the rows, a little room
local MAT_H = -LIST_Y + MAT_ROWS * ROW_H + 8

-- The plan you're working on (saved per character; pick another from the plan bar)
function UI:PlanTable()
    return PC:CurrentPlan()
end

-- Plan entries (the recipe list entries, each with .planCount), sorted by name
function UI:PlanEntries()
    local plan, out = self:PlanTable(), {}
    for _, e in ipairs(self.allEntries or {}) do
        local n = plan[e.id]
        if n and n > 0 then
            e.planCount = n
            out[#out + 1] = e
        end
    end
    table.sort(out, function(a, b) return a.r.name < b.r.name end)
    return out
end

-- Vertical crafting: the materials the plan makes itself (bolts for shirts), as craft entries
-- that come before the plan's own recipes
function UI:SubCrafts(list)
    list = list or PC:CombinedShoppingList(self:PlanEntries(), 1)
    local out = {}
    for _, it in ipairs(list) do
        if it.craft then
            out[#out + 1] = { id = it.craft.id, r = it.craft.r, planCount = it.craft.n, sub = true, outID = it.id,
                disenchant = it.craft.disenchant, deFor = it.craft.disenchant and it.id or nil, deNeed = it.craft.disenchant and math.max(it.need - it.have, 0) or nil }
        end
    end
    -- what another one is made from comes first (cloth -> bolt -> green): count how deep each is used
    local uses = {}
    for _, a in ipairs(out) do
        for _, b in ipairs(out) do
            for _, rg in ipairs(b.r.reagents or {}) do
                for _, rid in ipairs(PC:ReagentIDs(rg)) do if rid == a.r.output then uses[a] = (uses[a] or 0) + 1 end end
            end
        end
    end
    table.sort(out, function(a, b)
        if (uses[a] or 0) ~= (uses[b] or 0) then return (uses[a] or 0) > (uses[b] or 0) end
        return a.r.name < b.r.name
    end)
    return out
end

function UI:SetPlanCount(id, n)
    local plan = self:PlanTable()
    n = math.floor(tonumber(n) or 0)
    if n > (plan[id] or 0) then
        local ok, cost, budget, why, need, free = self:PlanFits(id, n, true)
        if not ok then
            self:SayOverBudget(cost, budget, "Can't add more", why, need, free)
            PC:RefreshUI()
            return
        end
    end
    if n <= 0 then plan[id] = nil else plan[id] = math.min(n, 9999) end
    PC:RefreshUI()
end

---------------------------------------------------------------------------
-- Plan budget: a plan can't grow past your spending limit (or your gold, with no limit set)
---------------------------------------------------------------------------
function UI:PlanBudget()
    return PC:Gold() -- spending limit if set (never more than your gold), otherwise your gold
end

function UI:BudgetName()
    local o = PC.cdb.overrides.gold
    if o and o <= GetMoney() then return "your spending limit" end
    return "your gold"
end

-- Materials cost of the current plan; with id/n, as if that recipe were set to n crafts
-- Shrink the plan until what's left to buy fits your gold (spending limit), least profitable crafts
-- first. Returns how many crafts were taken off.
function UI:TrimToGold()
    local plan = self:PlanTable()
    local budget = PC:Gold()
    local entries = self:PlanEntries()
    table.sort(entries, function(a, b)
        local ra = (a.profit or 0) / math.max(a.cost or 1, 1)
        local rb = (b.profit or 0) / math.max(b.cost or 1, 1)
        return ra < rb -- worst return first
    end)
    local removed = 0
    for _, e in ipairs(entries) do
        local cost = self:PlanCost()
        if cost <= budget then break end
        -- binary search: the most of this recipe that still fits
        local cur = plan[e.id] or 0
        local lo, hi = 0, cur
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            plan[e.id] = mid > 0 and mid or nil
            if self:PlanCost() <= budget then lo = mid else hi = mid - 1 end
        end
        plan[e.id] = lo > 0 and lo or nil
        removed = removed + (cur - lo)
    end
    self.allEntries = nil
    PC:RefreshUI()
    return removed
end

function UI:PlanCost(id, n)
    local plan = self:PlanTable()
    local old
    if id then old = plan[id]; plan[id] = (n and n > 0) and math.min(n, 9999) or nil end
    -- materials still to buy, plus the AH deposits for posting what the plan makes
    local ok, _, total, missing = pcall(function()
        local entries = self:PlanEntries()
        local list, t, m = PC:CombinedShoppingList(entries, 1)
        return list, (t or 0) + (PC.PostReserve and PC:PostReserve(entries) or 0), m
    end)
    if id then plan[id] = old end
    if not ok then return 0, true end
    return total or 0, missing
end

-- Bag slots the current plan needs; with id/n, as if that recipe were set to n crafts
function UI:PlanSlots(id, n)
    local plan = self:PlanTable()
    local old
    if id then old = plan[id]; plan[id] = (n and n > 0) and math.min(n, 9999) or nil end
    local ok, slots = pcall(function() return PC:PlanSlots(self:PlanEntries()) end)
    if id then plan[id] = old end
    return ok and slots or 0
end

-- Would setting recipe id to n crafts keep the plan within budget AND bag space?
-- returns ok, cost, budget, why ("gold" or "bags"), slots needed, slots free
function UI:PlanFits(id, n, ignoreMarket)
    local cost, missing = self:PlanCost(id, n)
    local budget = self:PlanBudget()
    if not missing and cost > budget then return false, cost, budget, "gold" end
    local need, free = self:PlanSlots(id, n), PC:FreeBagSlots()
    if need > free then return false, cost, budget, "bags", need, free end
    -- more than the market wants: your share of sales, a slice of what's listed, minus what you hold
    if id and PC.MakeGold and not ignoreMarket and not self:IsSkillPlan() then
        local e
        for _, x in ipairs(self.allEntries or {}) do if x.id == id then e = x break end end
        local cap, why
        if e and e.route ~= "Vendor" then cap, why = PC.MakeGold:MarketCap(e) end -- vendor flips: no market limit
        if cap and n > cap then return false, cost, budget, "market", cap, why or "" end
    end
    return true, cost, budget
end

-- Most extra crafts of a recipe that still fit the budget
function UI:MaxMoreFitting(id, ignoreMarket)
    local cur = self:PlanTable()[id] or 0
    if not self:PlanFits(id, cur + 1, ignoreMarket) then return 0 end
    local lo, hi = 1, 1
    while hi < 9999 - cur and self:PlanFits(id, cur + hi * 2, ignoreMarket) do hi = hi * 2 end
    hi = math.min(hi * 2, 9999 - cur)
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if self:PlanFits(id, cur + mid, ignoreMarket) then lo = mid else hi = mid - 1 end
    end
    return lo
end

function UI:SayOverBudget(cost, budget, lead, why, need, free)
    local text
    if why == "bags" then
        text = ("%s: the plan would need %d bag slots and you have %d free."):format(lead, need or 0, free or 0)
    elseif why == "market" then
        text = ("%s: the market only wants about %d more right now (%s)."):format(lead, need or 0, free or "")
    else
        text = ("%s: the plan would cost %s, more than %s (%s)."):format(lead, PC:Money(cost, false, true), self:BudgetName(), PC:Money(budget, false, true))
    end
    PC.Print("|cffff5555" .. text .. "|r")
    PC.Buy:Say("|cffff5555" .. text .. "|r")
end

-- Warn if the current plan already costs more than the spending limit or your gold
function UI:WarnPlanBudget()
    if not self.allEntries then self.allEntries = PC:Analyze() end
    local cost, missing = self:PlanCost()
    if missing or cost <= 0 then return end
    local limit = PC.cdb.overrides.gold
    local text
    if limit and cost > limit then
        text = ("Warning: the plan \"%s\" costs %s, more than your spending limit (%s)."):format(PC:PlanName(), PC:Money(cost, false, true), PC:Money(limit, false, true))
    elseif cost > GetMoney() then
        text = ("Warning: the plan \"%s\" costs %s, more than the gold you have (%s)."):format(PC:PlanName(), PC:Money(cost, false, true), PC:Money(GetMoney(), false, true))
    end
    if text then
        PC.Print("|cffff8040" .. text .. "|r")
        PC.Buy:Say("|cffff8040" .. text .. "|r")
    end
end

---------------------------------------------------------------------------
-- "How many?" pop-up (opens from the bag icon)
---------------------------------------------------------------------------
function UI:CreateQtyPopup()
    if self.qty then return self.qty end
    local q = CreateFrame("Frame", "ProfitCrafterQtyPopup", self.f, "BackdropTemplate")
    q:SetSize(380, 156)
    q:SetFrameStrata("DIALOG")
    q:EnableMouse(true)
    if q.SetBackdrop then
        q:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        q:SetBackdropColor(0.04, 0.035, 0.03, 0.98)
        q:SetBackdropBorderColor(0.78, 0.6, 0.23, 1)
    end
    tinsert(UISpecialFrames, "ProfitCrafterQtyPopup") -- Esc closes it
    q:Hide()
    q.title = q:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    q.title:SetPoint("TOPLEFT", 12, -12)
    q.title:SetWidth(356)
    q.title:SetJustifyH("LEFT")
    q.title:SetWordWrap(false)

    local function Small(text, onClick)
        local b = CreateFrame("Button", nil, q, "UIPanelButtonTemplate")
        b:SetSize(22, 22)
        b:SetText(text)
        b:SetScript("OnClick", onClick)
        return b
    end
    local eb = CreateFrame("EditBox", nil, q, "InputBoxTemplate")
    eb:SetSize(46, 20)
    eb:SetPoint("TOPLEFT", 44, -36)
    eb:SetAutoFocus(false)
    eb:SetNumeric(true)
    eb:SetMaxLetters(4)
    eb:SetJustifyH("CENTER")
    eb:SetScript("OnTextChanged", function() UI:UpdateQtyPopup() end)
    eb:SetScript("OnEnterPressed", function() UI:QtyAdd() end)
    eb:SetScript("OnEscapePressed", function() q:Hide() end)
    q.eb = eb
    q.minus = Small("-", function() UI:QtyStep(-1) end)
    q.minus:SetPoint("RIGHT", eb, "LEFT", -6, 0)
    q.plus = Small("+", function() UI:QtyStep(1) end)
    q.plus:SetPoint("LEFT", eb, "RIGHT", 2, 0)
    q.max = CreateFrame("Button", nil, q, "UIPanelButtonTemplate")
    q.max:SetSize(84, 22)
    q.max:SetPoint("LEFT", q.plus, "RIGHT", 8, 0)
    q.max:SetScript("OnClick", function()
        local e = q.entry
        if e then eb:SetText(tostring(math.max(UI:MaxMoreFitting(e.id, true), 1))); UI:UpdateQtyPopup() end
    end)
    q.max:SetScript("OnEnter", function(b)
        ShowTooltip(b, { "Max", "The most your gold (or spending limit) and bags allow, at any profit." })
    end)
    q.max:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Max profitable: the most that fit AND still make a profit, every craft priced up the listings
    q.maxProfit = CreateFrame("Button", nil, q, "UIPanelButtonTemplate")
    q.maxProfit:SetSize(140, 22)
    q.maxProfit:SetPoint("LEFT", q.max, "RIGHT", 6, 0)
    q.maxProfit:SetScript("OnClick", function()
        local e = q.entry
        if e then eb:SetText(tostring(math.max(UI:MaxProfitable(e), 1))); UI:UpdateQtyPopup() end
    end)
    q.maxProfit:SetScript("OnEnter", function(b)
        ShowTooltip(b, { "Max profitable", "The most your gold, bags and plan allow while every craft still makes a profit",
            "(auction or vendor), at live listing prices.",
            ("|cff888888Buying stops at your %d%% minimum profit.|r"):format(PC:MinProfitPct()) })
    end)
    q.maxProfit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    q.info = q:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    q.info:SetPoint("TOPLEFT", 12, -66)
    q.info:SetWidth(356)
    -- over-budget warning on its own lines, below the info (the popup grows to fit it)
    q.warn = q:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    q.warn:SetPoint("TOPLEFT", q.info, "BOTTOMLEFT", 0, -8)
    q.warn:SetWidth(356)
    q.warn:SetJustifyH("LEFT")
    q.warn:SetSpacing(2)
    q.info:SetJustifyH("LEFT")
    q.info:SetSpacing(3)
    q.add = CreateFrame("Button", nil, q, "UIPanelButtonTemplate")
    q.add:SetSize(118, 22)
    q.add:SetPoint("BOTTOMLEFT", 10, 10)
    q.add:SetText("Add to plan")
    q.add:SetScript("OnClick", function() UI:QtyAdd() end)
    q.cancel = CreateFrame("Button", nil, q, "UIPanelButtonTemplate")
    q.cancel:SetSize(96, 22)
    q.cancel:SetPoint("BOTTOMRIGHT", -10, 10)
    q.cancel:SetText(CANCEL or "Cancel")
    q.cancel:SetScript("OnClick", function() q:Hide() end)
    self.qty = q
    return q
end

function UI:ShowQtyPopup(e, anchor)
    if not e then return end
    if e.ahFlip then return self:BuyAHFlip(e) end -- not a recipe: buying it is the action
    local q = self:CreateQtyPopup()
    q.entry = e
    q:ClearAllPoints()
    if anchor then q:SetPoint("TOPLEFT", anchor, "BOTTOMRIGHT", 4, -2) else q:SetPoint("CENTER", self.f, "CENTER") end
    q.title:SetText(e.r.name .. ": how many?")
    q.add:SetText("Add to plan")
    q.eb:SetText("1")
    q:Show()
    q.eb:SetFocus()
    if q.eb.HighlightText then q.eb:HighlightText() end
    if q.Raise then q:Raise() end
    self:UpdateQtyPopup()
end

function UI:QtyStep(d)
    local q = self.qty
    if not q then return end
    local n = (tonumber(q.eb:GetText()) or 0) + d
    q.eb:SetText(tostring(math.max(n, 1)))
    self:UpdateQtyPopup()
end

function UI:UpdateQtyPopup()
    local q = self.qty
    if not q or not q:IsShown() or not q.entry then return end
    local e = q.entry
    local n = math.max(tonumber(q.eb:GetText()) or 0, 0)
    local maxN = self:MaxMoreFitting(e.id, true)
    q.max:SetText(("Max (%d)"):format(maxN))
    local maxP = self:MaxProfitable(e, maxN)
    q.maxProfit:SetText(("Max profitable (%d)"):format(maxP))
    q.maxProfit:SetEnabled(maxP > 0)
    -- what stops it there: your gold (or spending limit), or bag room
    local cur = PC:CurrentPlan()[e.id] or 0
    local _, _, _, limitWhy, lneed, lfree = self:PlanFits(e.id, cur + maxN + 1, true)
    local maxWhy
    if maxN < 9999 - cur then
        if limitWhy == "bags" then
            maxWhy = ("|cff888888Max %d: bag room (it would need %d slots, %d free).|r"):format(maxN, lneed or 0, lfree or 0)
        elseif limitWhy == "gold" then
            maxWhy = ("|cff888888Max %d: %s, counting auction prices as the cheap ones run out, and posting fees.|r"):format(maxN, self:BudgetName())
        end
    end
    local _, total, missing = PC:ShoppingList(e, math.max(n, 1))
    local lines = {}
    lines[#lines + 1] = "Materials to buy: " .. (missing and "|cffff5555unknown|r" or PC:Money(n > 0 and total or 0))
    -- the whole batch, its materials priced up the listings
    local ah, v = PC:BatchProfit(e, math.max(n, 1))
    if n <= 0 then ah, v = 0, 0 end
    lines[#lines + 1] = ("Auction Profit: %s   Vendor Profit: %s"):format(PC:Money(ah, true), PC:Money(v, true))
    if e.noSalesToday then lines[#lines + 1] = "|cffff8040No sales today: not recommended for auction.|r" end
    local qty = e.r.qty or 1
    lines[#lines + 1] = ("|cff888888Makes %s %s|r"):format(qty % 1 == 0 and tostring(qty * n) or ("about " .. math.floor(qty * n + 0.5)), e.r.name)
    local have = PC:CurrentPlan()[e.id]
    if have then lines[#lines + 1] = ("|cff40a0ffAlready %d in your plan; this adds more.|r"):format(have) end
    if maxWhy then lines[#lines + 1] = maxWhy end
    -- where buying stops: past it a craft makes under the minimum profit (the plan is cut to it then)
    local buyN = PC:BuyCrafts(e)
    if buyN and buyN < cur + math.max(n, maxP) then
        lines[#lines + 1] = buyN <= cur and ("|cffff8040Buying stops here: more would drop under your %d%% minimum profit.|r"):format(PC:MinProfitPct())
            or ("|cffff8040Buying stops at %d: beyond that a craft drops under your %d%% minimum profit.|r"):format(buyN - cur, PC:MinProfitPct())
    end
    local ok, cost, budget, why, need, free = self:PlanFits(e.id, (PC:CurrentPlan()[e.id] or 0) + n, true)
    -- more than the market wants: allowed (crafting waits on sales, in batches), just said
    if ok and n > 0 then
        local mok, _, _, mwhy, mneed, mfree = self:PlanFits(e.id, (PC:CurrentPlan()[e.id] or 0) + n)
        if not mok and mwhy == "market" then
            lines[#lines + 1] = ("|cffff8040More than the market wants right now (about %d sell). It's added; crafting goes in batches as they sell.|r"):format(mneed or 0)
        end
    end
    q.info:SetText(table.concat(lines, "\n"))
    local over = n > 0 and not ok
    if over and why == "bags" then
        q.warn:SetText(("|cffff5555Not enough bag space|r\nPlan would need %d slots  |cff888888(%d free)|r"):format(need or 0, free or 0))
    elseif over and why == "market" then
        q.warn:SetText(("|cffff5555More than the market wants|r\nAbout %d more would sell  |cff888888(%s)|r"):format(need or 0, free or ""))
    elseif over then
        local what = self:BudgetName() == "your spending limit" and "Over your spending limit" or "More than your gold"
        q.warn:SetText(("|cffff5555%s|r\nPlan would cost %s  |cff888888(you have %s)|r"):format(what,
            PC:Money(cost, false, true), PC:Money(budget, false, true)))
        q.warn:Show()
    else
        q.warn:SetText("")
        q.warn:Hide()
    end
    -- fit the popup to what's in it: title + amount row + info (+ warning) + buttons
    local infoH = (q.info.GetStringHeight and q.info:GetStringHeight()) or (#lines * 14)
    local warnH = over and (((q.warn.GetStringHeight and q.warn:GetStringHeight()) or 28) + 8) or 0
    q:SetHeight(math.max(66 + infoH + warnH + 44, 156))
    q.add:SetEnabled(n > 0 and ok)
end

-- The most crafts of a recipe to add that fit the plan (gold, bags) and where every craft still makes a
-- profit (Craftable at Profit, less what the plan already holds of it). maxFit: MaxMoreFitting, if known.
function UI:MaxProfitable(e, maxFit)
    if not e then return 0 end
    maxFit = maxFit or self:MaxMoreFitting(e.id, true)
    local n = PC:Craftable(e) or 0
    local cur = PC:CurrentPlan()[e.id] or 0
    return math.max(math.min(maxFit, n - cur), 0)
end

-- The material a recipe's crafts spend most on that's bought on the AH (nil: none to buy there):
-- { id, name, qty } for `crafts` crafts (default: what the plan holds of it)
function UI:MainAHMaterial(e, crafts)
    crafts = crafts or (self:PlanTable()[e.id] or 0)
    if not e or crafts <= 0 then return nil end
    local list = PC:CombinedShoppingList({ setmetatable({ planCount = crafts }, { __index = e }) }, 1)
    local best, bestSpend
    for _, it in ipairs(list or {}) do
        if (it.buy or 0) > 0 and it.src ~= "Vendor" and not it.craft and not it.tool and PC.Buy:CanBuy(it.id)
            and PC.Buy:AHQty(it.id, it.buy) > 0 then
            local spend = it.sub or ((it.unit or 0) * it.buy)
            if not best or spend > bestSpend then best, bestSpend = it, spend end
        end
    end
    return best and { id = best.id, name = PC:ItemName(best.id), qty = best.buy } or nil
end

-- Quick Buy: as many crafts as make the minimum profit right now and fit your gold and bags go in
-- the plan, the main AH material is bought in this same click (the game needs the click to ask the
-- AH for the price; it's checked and confirmed by itself), and the plan opens for the rest.
function UI:QuickBuy(e)
    if not e or e.ahFlip or not e.r then return end
    local plan = self:PlanTable()
    local cur = plan[e.id] or 0
    local pct = PC:MinProfitPct()
    local target = PC:BuyCrafts(e)
    local add = target and math.max(math.min(target - cur, self:MaxMoreFitting(e.id, true)), 0) or 0
    if add <= 0 and cur <= 0 then
        local why = (target and target > 0) and "none fit your gold or bags"
            or ("none make %d%% profit at today's prices"):format(pct)
        return PC.Buy:Say(("|cffff8040Quick Buy: no %s added: %s.|r"):format(e.r.name, why))
    end
    if add > 0 then
        plan[e.id] = math.min(cur + add, 9999)
        if self.tab == 1 and self.category == "VENDOR" then self:SetSellVia(e.outID or e.r.output, "Vendor", true) end
        PC:ForgetStopList()
    end
    local main = self:MainAHMaterial(e)
    -- (bought before anything else: the purchase has to start inside this click)
    if main and PC.ahOpen then PC.Buy:Start({ id = main.id, name = main.name }, false, true) end
    local parts = {}
    parts[#parts + 1] = add > 0 and ("Quick Buy: added %d %s (%d planned), all that make %d%% profit."):format(add, e.r.name, plan[e.id], pct)
        or ("Quick Buy: %s already planned (%d); no more make %d%% profit."):format(e.r.name, cur, pct)
    if main and PC.ahOpen then parts[#parts + 1] = ("Buying %s now. Click Buy for the other materials."):format(main.name or "main material")
    elseif main then parts[#parts + 1] = "Open the Auction House to buy its materials."
    else parts[#parts + 1] = "Nothing to buy at auction: its materials come from vendors or your bags." end
    PC.Print(table.concat(parts, " "))
    self:ShowTab(2)
    PC:RefreshUI()
end

function UI:QtyAdd()
    local q = self.qty
    if not q or not q.entry then return end
    local n = tonumber(q.eb:GetText()) or 0
    if n <= 0 then return end
    local e = q.entry
    local plan = self:PlanTable()
    local ok, cost, budget, why, need, free = self:PlanFits(e.id, (plan[e.id] or 0) + n, true)
    if not ok then
        self:SayOverBudget(cost, budget, "Can't add " .. n .. " " .. e.r.name, why, need, free)
        return
    end
    plan[e.id] = math.min((plan[e.id] or 0) + n, 9999)
    -- added from the Vendor flips list: it's meant for the vendor, so it's sold there
    if self.tab == 1 and self.category == "VENDOR" then UI:SetSellVia(e.outID or e.r.output, "Vendor", true) end
    q:Hide()
    PC.Print(("Added %d %s to your crafting plan \"%s\" (%d in total)."):format(n, e.r.name, PC:PlanName(), plan[e.id]))
    PC:RefreshUI()
end

---------------------------------------------------------------------------
-- Tab 2: Crafting plan
---------------------------------------------------------------------------
function UI:CreateShoppingPage(p)
    PC:Safe("plan bar", self.CreatePlanBar, self, p)
    -- recipes in the plan
    local pp = Panel(p, 12, PLAN_TOP, PW, PLAN_H)
    HeaderStrip(pp)
    local cols = {
        { "name", "Recipe", nil, "The hammer opens it in your profession window.", text = true },
        { "planCount", "How many", 96, "How many crafts are planned. Type a number, or use - and +." },
        { "craftable", "Craftable at Profit", 70, "How many you can craft at a profit with your materials and gold (or spending limit), buying the rest at live listing prices. Buying stops sooner, at your minimum profit.", fit = "num" },
        { "mats", "Materials to buy", 84, "Cost of the materials still to buy (what you have counts first).", fit = "gold" },
        { "ahProfit", "Auction Profit", 92, "Auction Profit for all planned crafts, materials at live listing prices, after the 5% auction cut.", fit = "gold" },
        { "vendorProfit", "Vendor Profit", 92, "Vendor Profit for all planned crafts, priced the same way.", fit = "gold" },
        { "matsMode", "Materials", 110, "Cheapest or top-quality materials (recipes with quality ranks). At the profession window: craft them.", text = true },
        { nil, nil, 30 }, -- the X that takes it off the plan
    }
    cols.font = UI.CELL_FONT
    self.planHeaders = Columns(pp, cols, "plan")
    local C = cols.by
    self.planEmpty = pp:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.planEmpty:SetPoint("CENTER", 0, -10)
    self.planEmpty:SetWidth(600)
    pp:EnableMouseWheel(true)
    pp:SetScript("OnMouseWheel", function(_, d) UI.planOffset = (UI.planOffset or 0) - d * 2; UI:UpdateShopping() end)
    self.planRows = {}
    for i = 1, PLAN_ROWS do
        local row = CreateFrame("Button", nil, pp)
        row:SetSize(RW, ROW_H)
        row:SetPoint("TOPLEFT", 4, LIST_Y - (i - 1) * ROW_H)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        Stripe(row, i)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(unpack(T.rowHover))
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(22, 22)
        row.icon:SetPoint("LEFT", 4, 0)
        SkillArrows(row, 27)
        row.name = RowText(row, 41, C.name.w - 41 - 30)
        row.craft = CraftButton(row, 18)
        row.craft:SetPoint("LEFT", C.name.w - 26, 0)
        local function Small(text, x, onClick)
            local b = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            b:SetSize(20, 18)
            b:SetPoint("LEFT", x, 0)
            b:SetText(text)
            b:SetScript("OnClick", onClick)
            return b
        end
        -- -, the count, + : against the right of the column, under its label
        local plusX = C.planCount.x + C.planCount.w - 4 - 20
        row.minus = Small("-", plusX - 70, function() if row.entry then UI:SetPlanCount(row.entry.id, row.entry.planCount - 1) end end)
        row.count = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        row.count:SetSize(40, 18)
        row.count:SetPoint("LEFT", plusX - 42, 0)
        row.count:SetAutoFocus(false)
        row.count:SetNumeric(true)
        row.count:SetMaxLetters(4)
        row.count:SetJustifyH("CENTER")
        -- the number goes to the recipe the box was for when you started typing (the rows can move)
        row.count:SetScript("OnEditFocusGained", function(eb) eb.editID = row.entry and row.entry.id end)
        row.count:SetScript("OnEnterPressed", function(eb) eb:ClearFocus() end)
        row.count:SetScript("OnEscapePressed", function(eb) eb.editID = nil; eb:ClearFocus(); UI:UpdateShopping() end)
        row.count:SetScript("OnEditFocusLost", function(eb)
            local id, n = eb.editID, tonumber(eb:GetText())
            eb.editID = nil
            if id and n and n ~= (UI:PlanTable()[id] or 0) then UI:SetPlanCount(id, n)
            else UI:UpdateShopping() end -- (left empty: nothing changes; the X takes it off)
        end)
        row.plus = Small("+", plusX, function() if row.entry then UI:SetPlanCount(row.entry.id, row.entry.planCount + 1) end end)
        row.cell = {}
        for _, k in ipairs({ "craftable", "mats", "ahProfit", "vendorProfit" }) do
            local fs = RowText(row, C[k].x, C[k].w - 4, "RIGHT")
            fs:SetFontObject(UI.CELL_FONT)
            fs.bigFont = UI.CELL_FONT
            row.cell[k] = fs
        end
        local btnX = C.matsMode.x + C.matsMode.w - 4 - 100
        row.matsBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.matsBtn:SetSize(100, 18)
        row.matsBtn:SetPoint("LEFT", btnX, 0)
        row.matsBtn:SetScript("OnClick", function()
            local e = row.entry
            if not e or not e.high then return end
            local picks = PC.cdb.matsPick
            picks[e.r.name] = (e.mats == "high") and "low" or "high"
            PC:RefreshUI()
        end)
        row.matsBtn:SetScript("OnEnter", function(b)
            ShowTooltip(b, { "Which materials", "|cffffffffCheapest|r: buy whichever quality is cheapest.",
                "|cffffffffTop quality|r: buy the best quality, for the best crafted quality.", "Click to switch." })
        end)
        row.matsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- Craft N: shows instead of the materials button while that profession's window is open
        row.craftNow = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.craftNow:SetSize(100, 18)
        row.craftNow:SetPoint("LEFT", btnX, 0)
        row.craftNow:SetScript("OnClick", function()
            local e = row.entry
            if e then PC:Safe("crafting", PC.Craft.Go, PC.Craft, e) end
        end)
        row.craftNow:SetScript("OnEnter", function(b)
            local e = row.entry
            if not e then return end
            local n = PC.Craft:Count(e)
            ShowTooltip(b, n > 0 and { "Craft " .. n, ("Crafts %d %s in one go, with the materials in your bags."):format(n, e.r.name) }
                or { "Need materials", "Your bags don't have the materials for this yet." })
        end)
        row.craftNow:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.craftNow:Hide()
        row.remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
        row.remove:SetSize(22, 22)
        row.remove:SetPoint("RIGHT", -4, 0)
        row.remove:SetScript("OnClick", function() if row.entry then UI:SetPlanCount(row.entry.id, 0) end end)
        row:SetScript("OnEnter", function(r)
            local e = r.entry
            if not e then return end
            local note = PC:PlanName() == "Gear upgrades" and PC.cdb.gearNotes and PC.cdb.gearNotes[e.r.output]
            local lines = { e.r.name }
            if not note then
                local ah, v = PC:BatchProfit(e, e.planCount)
                lines[#lines + 1] = ("%d crafts: Auction Profit %s, Vendor Profit %s"):format(e.planCount, PC:Money(ah, true), PC:Money(v, true))
                lines[#lines + 1] = "|cff888888(the whole batch, at live listing prices)|r"
                lines[#lines + 1] = ("Sells: %s"):format(e.route == "Vendor" and "|cff40c0ffto a vendor|r" or e.route == "Disenchant" and "|cffc080ffdisenchanted for dust|r" or "at auction")
                if e.noSalesToday then lines[#lines + 1] = "|cffff8040No sales today: not recommended for auction.|r" end
                for _, l in ipairs(UI:IngredientLines(e.r, e.mats)) do lines[#lines + 1] = l end
                for _, l in ipairs(UI:CraftableLines(e)) do lines[#lines + 1] = l end
            end
            if note then
                local what, changes = UI:GearLine({ kind = note.kind, oldName = note.old, ups = note.ups, downs = note.downs })
                lines[#lines + 1] = note.kind == "upgrade" and ("|cff40ff40Upgrade:|r " .. what) or ("|cffffd100Suggestion:|r " .. what .. ", your call")
                if changes ~= "" then lines[#lines + 1] = changes end
            end
            lines[#lines + 1] = "|cff888888Right-click: craft it   Shift-click: search the Auction House   Alt-click: vendor / auction|r"
            ShowTooltip(r, lines, e.outID or e.r.output)
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(r, button)
            local e = r.entry
            if not e then return end
            if button == "RightButton" and not (IsShiftKeyDown and IsShiftKeyDown()) then UI:OpenRecipe(e.id, e.r) return end
            -- Alt-click: sell this one to a vendor or on the AH
            if IsAltKeyDown and IsAltKeyDown() then
                UI:SetSellVia(e.outID or e.r.output, e.route == "Vendor" and "AH" or "Vendor")
                return
            end
            UI:ClickItem(e.outID or e.r.output, button)
        end)
        self.planRows[i] = row
    end

    -- everything to buy for the whole plan
    local mp = Panel(p, 12, PLAN_TOP - PLAN_H - 6, PW, MAT_H)
    HeaderStrip(mp)
    local mcols = {
        { "name", "Materials for everything", nil, "Everything to buy or make for the whole plan.", text = true },
        { "need", "Need", 60, "How many the whole plan needs.", fit = "num" },
        { "have", "Have", 100, "How many you have: bags, bank, mail and purchases on the way (the brackets say where)." },
        { "buy", "Buy", 70, "How many are still to buy. Make: cheaper to craft yourself." },
        { "each", "Each", 96, "Average price each, buying from the cheapest listing up.", fit = "money" },
        { "total", "Total", 196, "What buying them costs. Red with a +: not enough are listed." },
        { nil, nil, 92 }, -- the Buy button
    }
    self.matHeaders = Columns(mp, mcols, "mats")
    local M = mcols.by
    local list = CreateFrame("Frame", nil, mp)
    list:SetPoint("TOPLEFT", 4, LIST_Y)
    list:SetSize(RW, MAT_ROWS * ROW_H)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        UI.shopOffset = (UI.shopOffset or 0) - delta * 3
        UI:UpdateShopping()
    end)
    self.shopEmpty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.shopEmpty:SetPoint("CENTER")
    self.shopRows = {}
    for i = 1, MAT_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetSize(RW, ROW_H)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        Stripe(row, i)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(22, 22)
        row.icon:SetPoint("LEFT", 4, 0)
        -- (Have is wide enough for "45 (120 bank)" without running into Need)
        row.name = RowText(row, 30, M.name.w - 34)
        for _, k in ipairs({ "need", "have", "buy", "each", "total" }) do row[k] = RowText(row, M[k].x, M[k].w - 4, "RIGHT") end
        -- Buy straight from the AH: first click gets the price, second click buys
        row.buyBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.buyBtn:SetSize(84, 20)
        row.buyBtn:SetPoint("RIGHT", -4, 0)
        row.buyBtn:SetText("Buy")
        row.buyBtn:SetScript("OnClick", function()
            local it = row.buyItem
            if not it then return end
            if it.vendor then PC:Safe("buying", PC.VendorBuy.Buy, PC.VendorBuy, it.id, it.qty, nil, nil, true)
            elseif it.search then PC:Safe("search", PC.Buy.SearchAH, PC.Buy, it)
            else PC:Safe("buying", PC.Buy.Click, PC.Buy, it) end
        end)
        row.buyBtn:SetScript("OnEnter", function(b)
            if row.buyItem and row.buyItem.search then
                local cap = PC.Buy:VendorPrice(row.buyItem.id)
                ShowTooltip(b, { "Find it at auction",
                    ("This game's Auction House can't buy for you: this runs the search, you click the buyout. Buy %d%s."):format(row.buyItem.qty,
                        cap and (", under " .. PC:Money(cap, false, true) .. " each (what a vendor charges)") or "") })
                return
            end
            if row.buyItem and row.buyItem.vendor then
                ShowTooltip(b, { "Buy " .. row.buyItem.qty .. " from this vendor",
                    "Goes straight into your bags.", "|cff888888Cheaper here than at auction.|r" })
                return
            end
            local tip = { "Buy " .. (row.buyItem and row.buyItem.qty or "") .. " now" }
            if row.buyItem and (row.buyItem.vendorRest or 0) > 0 then
                tip[#tip + 1] = ("|cffff8040Only %d are listed under what a vendor charges. Buy the other %d from a vendor.|r"):format(
                    row.buyItem.qty + (row.buyItem.stopped or 0), row.buyItem.vendorRest)
            end
            if row.buyItem and (row.buyItem.stopped or 0) > 0 then
                tip[#tip + 1] = ("|cffff8040%d more would drop the craft under %d%% profit: not bought.|r"):format(
                    row.buyItem.stopped, PC:MinProfitPct())
            end
            if not PC.ahOpen then tip[#tip + 1] = "|cffff8040Open the Auction House to buy.|r" end
            tip[#tip + 1] = "First click gets the live price, the next click buys."
            tip[#tip + 1] = "|cff888888Purchases go to your mailbox and count as \"have\" right away.|r"
            ShowTooltip(b, tip)
        end)
        row.buyBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.hl = row:CreateTexture(nil, "BORDER")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(unpack(T.rowHover))
        row.hl:Hide()
        row:SetScript("OnEnter", function(r)
            r.hl:Show()
            if r.itemID then
                local tip = { PC:ItemName(r.itemID) }
                if r.usedBy and #r.usedBy > 0 then
                    tip[#tip + 1] = "|cff888888Needed for:|r " .. table.concat(r.usedBy, ", ")
                end
                if r.slot and #PC:ReagentIDs(r.slot) > 1 then
                    tip[#tip + 1] = "|cffffd100Every quality:|r"
                    for qq, id in ipairs(PC:RankedReagentIDs(r.slot)) do
                        local c = PC:UnitCost(id)
                        tip[#tip + 1] = ("  %s  %s%s"):format(UI.QualityLabel(qq, #PC:ReagentIDs(r.slot), id), c and PC:Money(c) or "|cff888888no price|r",
                            id == r.itemID and ("  " .. PC.ARROW_L .. " |cff40ff40this list|r") or "")
                    end
                end
                for _, l in ipairs(PC:PriceSourceLines(r.itemID)) do tip[#tip + 1] = l end
                tip[#tip + 1] = " "
                for _, l in ipairs(PC:DepthLines(r.itemID, r.buyN)) do tip[#tip + 1] = l end
                ShowTooltip(r, tip, r.itemID)
            end
        end)
        row:SetScript("OnLeave", function(r) r.hl:Hide(); GameTooltip:Hide() end)
        row:SetScript("OnClick", function(r, button)
            if UI:ClickItem(r.itemID, button) then return end
            if button == "LeftButton" then PC.Depth:CheckNow(r.itemID); UI.RefreshTip(r) end
        end)
        self.shopRows[i] = row
    end

    -- totals + actions
    local by = PLAN_TOP - PLAN_H - 6 - MAT_H - 8
    -- (the buttons along the right take 490; the clean look moves them and gives this the whole width)
    self.shopSummary = UI.Ink(Text(p, "GameFontHighlightSmall", 16, by - 6, PW - 500))
    self.shopSummary:SetWordWrap(false)
    -- (the Next task button lives on the floating Task Button bar, not here)
    local clear = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    clear:SetSize(80, 24)
    clear:SetText("Clear Plan")
    clear:SetScript("OnClick", function()
        wipe(UI:PlanTable())
        PC:RefreshUI()
    end)
    clear:SetScript("OnEnter", function(b) ShowTooltip(b, { "Clear plan", "Empties the plan shown at the top. The plan itself stays saved." }) end)
    clear:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.shopClear = clear
    clear:SetPoint("TOPRIGHT", p, "TOPLEFT", 12 + PW, by)
    -- Skill up: a plan of crafts that raise your skill, cheapest per point (profit not needed)
    local skill = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    skill:SetSize(74, 24)
    skill:SetPoint("RIGHT", clear, "LEFT", -6, 0)
    skill:SetText("Skill up")
    skill:SetScript("OnClick", function() UI:ToggleSkillMenu() end)
    skill:SetScript("OnEnter", function(b)
        if b.none then return ShowTooltip(b, { "Skill up", "|cffff8040You're maxed out:|r nothing you know gives skill right now." }) end
        ShowTooltip(b, { "Skill up",
            "|cffff8040Builds a plan to raise your profession skill, not to make gold.|r",
            " ",
            "|cffffd100Pick|r All professions or just one, and which colours count:",
            "   |cffff8040Orange|r  a point every craft",
            "   |cffffff00Yellow|r  usually a point",
            "   |cff40c040Green|r  sometimes (about 4x the cost per point; off unless you tick it)",
            "   |cff909090Grey|r  never, so never used",
            " ",
            "|cffffd100Cheapest per skill point first:|r what the materials cost,",
            "minus what the result sells back for. Crafts that lose gold are allowed.",
            " ",
            "|cffffd100Stays within|r your spending limit and bag space.",
            "What you make still gets sold, so some gold comes back, but expect to spend." })
    end)
    skill:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.skillBtn = skill
    -- which profession to level: All, or one of yours
    local smenu = CreateFrame("Frame", nil, p, "BackdropTemplate")
    smenu:SetPoint("BOTTOMLEFT", skill, "TOPLEFT", 0, 2)
    smenu:SetWidth(200)
    smenu:SetFrameStrata("DIALOG")
    if smenu.SetBackdrop then
        smenu:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        smenu:SetBackdropColor(0.04, 0.035, 0.03, 0.98)
        smenu:SetBackdropBorderColor(0.78, 0.6, 0.23, 1)
    end
    smenu.buttons = {}
    smenu:Hide()
    self.skillMenu = smenu
    -- Upgrade gear: a plan of what you can craft that beats what you're wearing (one of each)
    local gear = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    gear:SetSize(96, 24)
    gear:SetPoint("RIGHT", skill, "LEFT", -6, 0)
    gear:SetText("Upgrade gear")
    gear:SetScript("OnClick", function() PC:Safe("gear upgrades", UI.PlanGearUpgrades, UI) end)
    gear:SetScript("OnEnter", function(b)
        if b.none then return ShowTooltip(b, { "Upgrade gear", "You have no items you can craft to upgrade your own gear." }) end
        local tip = { "Upgrade gear", "Makes a \"Gear upgrades\" plan: one of each item you can craft",
            "that beats what you're wearing now (more of its stats go up than down)." }
        local shown = 0
        for i, u in ipairs(b.list or {}) do
            if shown >= 8 then tip[#tip + 1] = ("|cff888888and %d more|r"):format(#b.list - shown) break end
            shown = shown + 1
            local what, changes = UI:GearLine(u)
            tip[#tip + 1] = ("%s%s|r  |cff888888%s|r"):format(u.kind == "upgrade" and "|cffffd100" or "|cffaaaaaa",
                PC:ItemName(u.e.r.output) or "?", u.kind == "upgrade" and what or ("suggestion: " .. what))
            if changes ~= "" then tip[#tip + 1] = "    " .. changes end
        end
        ShowTooltip(b, tip)
    end)
    gear:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.gearBtn = gear
    -- Make me gold, back down here too (it also hangs off the side with the tabs)
    local goldBtn = UI.GreenButton(p, 104, 24, "Make me gold")
    goldBtn:SetPoint("RIGHT", gear, "LEFT", -6, 0)
    goldBtn:SetScript("OnClick", function() PC:Safe("make me gold", PC.MakeGold.Open, PC.MakeGold) end)
    goldBtn:SetScript("OnEnter", function(b)
        ShowTooltip(b, { "Make me gold", "Builds a plan with the best crafts that fit your spending limit",
            "and that actually sell." })
    end)
    goldBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.footerGoldBtn = goldBtn
    local haveBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    haveBtn:SetSize(112, 24)
    haveBtn:SetPoint("RIGHT", goldBtn, "LEFT", -6, 0)
    haveBtn:SetText("Have materials")
    haveBtn:SetScript("OnClick", function() PC:Safe("have materials", UI.PlanFromBags, UI) end)
    haveBtn:SetScript("OnEnter", function(b)
        if b.none then return ShowTooltip(b, { "Have materials", ("Your materials don't make anything at %s%%+ profit right now."):format(PC:MinProfitPct()) }) end
        ShowTooltip(b, { "Have materials", ("Plans every recipe making %s%%+ profit that your materials already cover, as many as"):format(PC:MinProfitPct()),
            "they make (auction crafts only if they sold today).",
            "Best profit first, so shared materials go to the top earner." })
    end)
    haveBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.haveBtn = haveBtn
end

-- "Skill up": a plan of crafts that raise your skill, cheapest per expected skill point first.
-- Orange always gives a point, yellow usually, green sometimes; grey never (left out).
UI.SKILL_CHANCE = { [0] = 1, [1] = 0.75, [2] = 0.25 }
UI.SKILL_CAP = { [0] = 5, [1] = 8, [2] = 12 } -- crafts per recipe before it likely changes colour
UI.SKILL_POINTS = 15                             -- points to aim for per profession in one plan

-- Recipes saved under the smelting window's name count as Mining
local function ProfMatch(recipeProf, want)
    if not want or want == "ALL" then return true end
    if recipeProf == want then return true end
    return want == "Mining" and recipeProf == "Smelting"
end
UI.ProfMatch = ProfMatch

-- The menu over the Skill up button: All professions, then each of yours (gathering ones too)
function UI:SkillMenuChoices()
    local out, seen = { { value = "ALL", label = "All professions" } }, {}
    local hasRecipes = {}
    for _, r in pairs(PC.cdb.recipes or {}) do hasRecipes[r.prof == "Smelting" and "Mining" or r.prof] = true end
    local names = {}
    for _, pr in pairs(PC.cdb.professions or {}) do
        if pr.name and not seen[pr.name] then seen[pr.name] = true; names[#names + 1] = pr end
    end
    table.sort(names, function(a, b) return a.name < b.name end)
    for _, pr in ipairs(names) do
        local lvl = (pr.max or 0) > 0 and (" |cff888888%d/%d|r"):format(pr.rank or 0, pr.max) or ""
        out[#out + 1] = { value = pr.name, label = pr.name .. lvl, empty = not hasRecipes[pr.name] }
    end
    return out
end

-- Which colours count: orange (sure point) and yellow (usually) on; green (rarely) off unless you tick it
function UI:SkillColors()
    PC.db.skillColors = PC.db.skillColors or { [0] = true, [1] = true, [2] = false }
    return PC.db.skillColors
end

function UI:ToggleSkillMenu()
    local menu = self.skillMenu
    if not menu then return PC:Safe("skill up", UI.PlanSkillUp, UI) end
    if menu:IsShown() then menu:Hide() return end
    local choices = self:SkillMenuChoices()
    for i, c in ipairs(choices) do
        local b = menu.buttons[i]
        if not b then
            b = CreateFrame("Button", nil, menu)
            b:SetSize(192, 20)
            b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 20)
            local hl = b:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(unpack(T.rowHover))
            b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            b.text:SetPoint("LEFT", 6, 0)
            b.text:SetWidth(180)
            b.text:SetJustifyH("LEFT")
            b.text:SetWordWrap(false)
            b:SetScript("OnClick", function(btn)
                menu:Hide()
                PC:Safe("skill up", UI.PlanSkillUp, UI, btn.value)
            end)
            menu.buttons[i] = b
        end
        b.value = c.value
        b.text:SetText((c.empty and "|cff888888" or "|cffffffff") .. c.label .. (c.empty and "  (no recipes yet)" or "") .. "|r")
        b:Show()
    end
    for i = #choices + 1, #menu.buttons do menu.buttons[i]:Hide() end
    -- colour ticks under the list
    menu.colors = menu.colors or {}
    local COL = { { 0, "|cffff8040Orange|r  always a point" }, { 1, "|cffffff00Yellow|r  usually a point" }, { 2, "|cff40c040Green|r  sometimes" } }
    local y = -8 - #choices * 20
    for k, c in ipairs(COL) do
        local cb = menu.colors[k]
        if not cb then
            cb = CreateFrame("CheckButton", nil, menu, "UICheckButtonTemplate")
            cb:SetSize(20, 20)
            cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
            cb:SetScript("OnClick", function(b) UI:SkillColors()[b.diff] = b:GetChecked() and true or false end)
            menu.colors[k] = cb
        end
        cb.diff = c[1]
        cb.label:SetText(c[2])
        cb:ClearAllPoints()
        cb:SetPoint("TOPLEFT", 6, y - (k - 1) * 20)
        cb:SetChecked(self:SkillColors()[c[1]] and true or false)
        cb:Show()
    end
    menu:SetHeight(14 + #choices * 20 + #COL * 20)
    menu:Show()
    if menu.Raise then menu:Raise() end
end

function UI:PlanSkillUp(prof)
    prof = prof or "ALL"
    if not self.allEntries then self.allEntries = PC:Analyze() end
    local planName = prof == "ALL" and "Skill up" or ("Skill up: " .. prof)
    if PC:Plans()[planName] then PC:SwitchPlan(planName) else PC:NewPlan(planName) end
    local plan = self:PlanTable()
    wipe(plan)
    if PC.cdb.skipCraft then PC.cdb.skipCraft[planName] = nil end -- made fresh: nothing from last time stays skipped
    -- how many points each profession still has to go
    local need = {}
    for _, pr in pairs(PC.cdb.professions or {}) do
        if pr.name and (pr.max or 0) > 0 then need[pr.name] = math.max(pr.max - (pr.rank or 0), 0) end
    end
    local byProf = {}
    for _, e in ipairs(self.allEntries) do
        local ch = self.SKILL_CHANCE[e.r.diff]
        if ch and self:SkillColors()[e.r.diff] and e.cost and e.cost > 0 and ProfMatch(e.r.prof, prof) and not (PC.Learn and PC.Learn:Avoided(e.id)) then
            -- what it really costs you: materials minus what the result sells back for
            local back = e.profit and (e.cost + e.profit) or 0
            e.skillCost = math.max(e.cost - back, 0) / ch
            local pname = (e.r.prof == "Smelting" and "Mining") or e.r.prof or "?"
            byProf[pname] = byProf[pname] or {}
            table.insert(byProf[pname], e)
        end
    end
    local budget = self:PlanBudget()
    local free = PC:FreeBagSlots()
    local function fits(id, n)
        local cost, missing = self:PlanCost(id, n)
        if not missing and cost > budget then return false end
        return self:PlanSlots(id, n) <= free
    end
    local crafts, recipes, points = 0, 0, 0
    for pname, list in pairs(byProf) do
        table.sort(list, function(a, b)
            if a.skillCost ~= b.skillCost then return a.skillCost < b.skillCost end
            return (a.r.diff or 3) < (b.r.diff or 3)
        end)
        local left = math.min(need[pname] or self.SKILL_POINTS, self.SKILL_POINTS)
        for _, e in ipairs(list) do
            if left <= 0 then break end
            local ch = self.SKILL_CHANCE[e.r.diff]
            local n = math.min(math.ceil(left / ch), self.SKILL_CAP[e.r.diff] or 5)
            while n > 0 and not fits(e.id, n) do n = n - 1 end
            if n > 0 then
                plan[e.id] = n
                crafts, recipes = crafts + n, recipes + 1
                points = points + n * ch
                left = left - n * ch
            end
        end
    end
    self.allEntries = nil
    if crafts == 0 and prof ~= "ALL" and not next(byProf) then
        local known = false
        for _, r in pairs(PC.cdb.recipes or {}) do if ProfMatch(r.prof, prof) then known = true break end end
        PC.Print(known and ("No %s recipes give skill right now (they're all grey)."):format(prof)
            or ((prof == "Herbalism" or prof == "Skinning" or prof == "Fishing" or prof == "Archaeology")
                and ("%s levels by gathering, not crafting: ProfitCrafter will help with that later."):format(prof)
                or prof == "Mining" and "Mining levels by smelting too: open the Smelting window once so ProfitCrafter learns your smelts, then try again."
                or ("ProfitCrafter doesn't know any %s recipes yet: open its window once, then try again."):format(prof)))
    elseif crafts == 0 then
        PC.Print("No crafts of the colours you ticked fit your gold and bags right now (try ticking Green on the Skill up menu; grey never gives points).")
    else
        local cost = self:PlanCost()
        PC.Print("|cffff8040Heads up: you're now using a plan set up to raise your skill, not to make a profit. Switch plans (or Make me gold) to earn.|r")
        UI:SkillPlanNotice(planName)
        PC.Print(("%s plan: %d crafts of %d recipe%s, about %d skill point%s, materials about %s. What you make still gets sold."):format(
            planName, crafts, recipes, recipes == 1 and "" or "s", math.floor(points + 0.5), math.floor(points + 0.5) == 1 and "" or "s", PC:Money(cost, false, true)))
        -- other professions helping: materials you make yourself (bars, bolts, greens to disenchant)
        -- give their own skill-ups too
        if not self.allEntries then self.allEntries = PC:Analyze() end
        local ok, list = pcall(PC.CombinedShoppingList, PC, self:PlanEntries(), 1)
        local extra, de = {}, 0
        for _, it in ipairs(ok and list or {}) do
            if it.craft and it.craft.r then
                local ch = self.SKILL_CHANCE[it.craft.r.diff]
                local p = it.craft.r.prof or "?"
                if ch then extra[p] = (extra[p] or 0) + it.craft.n * ch end
                if it.craft.disenchant then de = de + it.craft.n end
            end
        end
        local parts = {}
        for p, n in pairs(extra) do if n >= 0.5 then parts[#parts + 1] = ("%s +%d"):format(p, math.floor(n + 0.5)) end end
        if #parts > 0 then PC.Print("Also levels: " .. table.concat(parts, ", ") .. " (materials you make yourself).") end
        if de > 0 then PC.Print(("Includes %d green%s to craft and disenchant for the dust (cheaper than buying it)."):format(de, de == 1 and "" or "s")) end
    end
    PC:RefreshUI()
end

---------------------------------------------------------------------------
-- Gear upgrades: what you can craft that beats what you're wearing, one of each
---------------------------------------------------------------------------
UI.GEAR_SLOTS = { INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },
    INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 }, INVTYPE_WEAPON = { 16 },
    INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 },
    INVTYPE_HOLDABLE = { 17 }, INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 } }

local function ItemInfo(id)
    local gi = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not gi or not id then return nil end
    local ok, name, link, _, ilvl, minLevel, _, _, _, equipLoc = pcall(gi, id)
    if not ok then return nil end
    return name, link, ilvl, minLevel, equipLoc
end

local function ItemLevelOf(linkOrID)
    if GetDetailedItemLevelInfo then
        local ok, l = pcall(GetDetailedItemLevelInfo, linkOrID)
        if ok and type(l) == "number" and l > 0 then return l end
    end
    local _, _, ilvl = ItemInfo(linkOrID)
    return ilvl
end

-- Can you wear or wield it? Nothing on its tooltip in red (armor type, weapon skill, class, level)
local function Red(c) return type(c) == "table" and (c.r or 0) > 0.9 and (c.g or 1) < 0.3 and (c.b or 1) < 0.3 end
local gearTip
-- Tooltips are slow to read, and Gear upgrades reads them for every piece you can make: whether you can
-- wear an item (per level) and what an item gives are read once, not on every redraw
local wearCache, statsCache = {}, {}
-- a weapon skill or spell learned can clear a red tooltip line without a level-up
local wearEv = CreateFrame("Frame")
for _, e in ipairs({ "SKILL_LINES_CHANGED", "LEARNED_SPELL_IN_TAB" }) do pcall(wearEv.RegisterEvent, wearEv, e) end
wearEv:SetScript("OnEvent", function() wipe(wearCache) end)
function UI:CanWear(id)
    local key = tostring(id) .. ":" .. tostring(UnitLevel and UnitLevel("player") or 0)
    if wearCache[key] == nil then wearCache[key] = self:CanWearRaw(id) end -- (nil: not loaded yet, asked again)
    return wearCache[key]
end
function UI:CanWearRaw(id)
    local name, _, _, minLevel = ItemInfo(id)
    if not name then return nil end
    if minLevel and UnitLevel and minLevel > (UnitLevel("player") or 1) then return false end
    if C_TooltipInfo and C_TooltipInfo.GetItemByID then
        local ok, data = pcall(C_TooltipInfo.GetItemByID, id)
        if ok and type(data) == "table" and data.lines then
            for _, l in ipairs(data.lines) do
                if Red(l.leftColor) or Red(l.rightColor) then return false end
            end
            return true
        end
    end
    if not gearTip and CreateFrame then
        local ok, t = pcall(CreateFrame, "GameTooltip", "ProfitCrafterGearTip", nil, "GameTooltipTemplate")
        if ok then gearTip = t end
    end
    if gearTip and gearTip.SetItemByID then
        gearTip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
        pcall(gearTip.SetItemByID, gearTip, id)
        for i = 1, (gearTip.NumLines and gearTip:NumLines() or 0) do
            for _, side in ipairs({ "Left", "Right" }) do
                local fs = _G["ProfitCrafterGearTip" .. side .. "Text" .. i] or _G["ProfitCrafterGearTipText" .. side .. i]
                if fs and fs.IsShown and fs:IsShown() and fs.GetTextColor then
                    local r, g, b = fs:GetTextColor()
                    if Red({ r = r, g = g, b = b }) then gearTip:Hide() return false end
                end
            end
        end
        gearTip:Hide()
    end
    return true
end

-- What an item gives: { [stat] = amount } (armor, resistances, the main stats, spell power, weapon damage...)
-- Enchants on what you wear aren't counted (the game's own comparison leaves them out too).
local function ArmorFromTooltip(link)
    local pat = (ARMOR_TEMPLATE or "%s Armor"):gsub("%%s", "(%%d+)")
    local lines
    if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
        local ok, data = pcall(C_TooltipInfo.GetHyperlink, link)
        lines = ok and type(data) == "table" and data.lines
    end
    for _, l in ipairs(lines or {}) do
        local n = l.leftText and tonumber(l.leftText:match("^" .. pat .. "$"))
        if n then return n end
    end
    return nil
end
function UI:ItemStats(link)
    if link and statsCache[link] == nil then statsCache[link] = self:ItemStatsRaw(link) end
    return link and statsCache[link]
end
function UI:ItemStatsRaw(link)
    local f = (C_Item and C_Item.GetItemStats) or GetItemStats
    if not f or not link then return nil end
    local ok, t = pcall(f, link)
    if not ok or type(t) ~= "table" then
        -- (the old way: fills a table you hand it)
        local into = {}
        ok = pcall(f, link, into)
        t = ok and next(into) and into or nil
    end
    if not t then return nil end
    local out = {}
    for k, v in pairs(t) do
        if type(v) == "number" and v ~= 0 and not tostring(k):find("SOCKET", 1, true) then out[k] = v end
    end
    if not out.RESISTANCE0_NAME then out.RESISTANCE0_NAME = ArmorFromTooltip(link) end
    return out
end

-- How much a point of each is worth, against one point of a main stat
UI.STAT_WORTH = { RESISTANCE0_NAME = 0.1, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 3 }
for i = 1, 6 do UI.STAT_WORTH["RESISTANCE" .. i .. "_NAME"] = 0.5 end
local function StatName(k) return (type(_G[k]) == "string" and _G[k]) or (k == "RESISTANCE0_NAME" and "Armor") or k end
UI.StatName = StatName

-- Is the new one better than what you wear? Counted the way you'd look at the two tooltips:
--   "upgrade": nothing goes down, or more stats go up than down and they're worth at least twice as much
--   "close":   about the same (as many go up as down, or close to it) - worth a look, not a sure thing
--   "worse":   more of its stats go down than up
function UI:CompareGear(newLink, oldLink)
    if not oldLink then return "upgrade", { ups = {}, downs = {}, net = 99 } end
    local new, old = self:ItemStats(newLink), self:ItemStats(oldLink)
    if not new or not old then return nil end
    local ups, downs, gain, loss = {}, {}, 0, 0
    local keys = {}
    for k in pairs(new) do keys[k] = true end
    for k in pairs(old) do keys[k] = true end
    for k in pairs(keys) do
        local d = (new[k] or 0) - (old[k] or 0)
        if math.abs(d) >= 0.05 then
            local worth = math.abs(d) * (self.STAT_WORTH[k] or 1)
            local txt = ("%s%s %s"):format(d > 0 and "+" or "-", (math.floor(math.abs(d) * 10 + 0.5) / 10), StatName(k))
            if d > 0 then ups[#ups + 1] = txt; gain = gain + worth else downs[#downs + 1] = txt; loss = loss + worth end
        end
    end
    table.sort(ups); table.sort(downs)
    local info = { ups = ups, downs = downs, net = gain - loss }
    if #ups == 0 then return "worse", info end
    if #downs == 0 then return "upgrade", info end
    if #ups > #downs and gain >= loss * 2 then return "upgrade", info end
    if #ups >= #downs then return "close", info end
    return "worse", info
end

-- { { e, kind, ilvl, old, oldName, ups, downs, slot } }: the best one for each slot, upgrades first, then ones
-- about the same as yours (suggestions). Two-slot rings and trinkets: against whichever of yours it beats most.
local RANK = { upgrade = 2, close = 1 }
function UI:GearUpgrades()
    if not self.allEntries then self.allEntries = PC:Analyze() end
    local best = {}
    for _, e in ipairs(self.allEntries or {}) do
        local id = e.r and e.r.output
        local name, link, ilvl, _, equipLoc = ItemInfo(id)
        local slots = equipLoc and self.GEAR_SLOTS[equipLoc]
        -- (one you already have, in your bags or bank, isn't crafted again)
        if name and slots and ilvl and e.route ~= "Disenchant" and (PC:OwnedCount(id) or 0) == 0 and self:CanWear(id) then
            ilvl = ItemLevelOf(link or id) or ilvl
            local pick
            for _, sl in ipairs(slots) do
                local l = GetInventoryItemLink and GetInventoryItemLink("player", sl)
                local kind, info = self:CompareGear(link or ("item:" .. id), l)
                if kind == nil and l and not ((C_Item and C_Item.GetItemStats) or GetItemStats) then
                    -- no way to read stats in this game: item level decides (stats not loaded yet: left out for now)
                    local lv = ItemLevelOf(l) or 0
                    kind, info = (ilvl > lv) and "upgrade" or "worse", { ups = {}, downs = {}, net = ilvl - lv }
                end
                if RANK[kind] and (not pick or RANK[kind] > RANK[pick.kind] or (RANK[kind] == RANK[pick.kind] and info.net > pick.net)) then
                    pick = { e = e, kind = kind, ilvl = ilvl, old = l and ItemLevelOf(l) or 0, oldName = l and ItemInfo(l) or nil,
                        ups = info.ups, downs = info.downs, net = info.net, slot = equipLoc }
                end
            end
            if pick then
                local key = table.concat(slots, ",")
                local b = best[key]
                if not b or RANK[pick.kind] > RANK[b.kind] or (RANK[pick.kind] == RANK[b.kind]
                    and (pick.net > b.net or (pick.net == b.net and (e.cost or 0) < (b.e.cost or 0)))) then
                    best[key] = pick
                end
            end
        end
    end
    local out = {}
    for _, b in pairs(best) do out[#out + 1] = b end
    table.sort(out, function(a, b)
        if a.kind ~= b.kind then return RANK[a.kind] > RANK[b.kind] end
        return a.net > b.net
    end)
    return out
end

-- Made on a Gear upgrades plan to wear: put on, never sold. (Only those: what any other plan makes is
-- sold as usual, even if it would beat what you wear.) Each: { id, name, bag, slot, invSlot, kind, old }
-- Once it's on, it's no longer better than what you wear (it IS what you wear) and drops off.
function UI:WornID(sl)
    local f = GetInventoryItemID
    if f then local ok, id = pcall(f, "player", sl); if ok then return id end end
    local l = GetInventoryItemLink and GetInventoryItemLink("player", sl)
    return l and tonumber(l:match("item:(%d+)")) or nil
end
function UI:ToEquip(id)
    local keep = PC.cdb and PC.cdb.gearKeep
    if not (keep and keep[id]) then return nil end
    local name, link, _, _, equipLoc = ItemInfo(id)
    local slots = equipLoc and self.GEAR_SLOTS[equipLoc]
    if not slots then return nil end
    local pick
    for _, sl in ipairs(slots) do
        if self:WornID(sl) == id and #slots == 1 then return nil end -- already wearing it
        local worn = GetInventoryItemLink and GetInventoryItemLink("player", sl)
        local kind = self:CompareGear(link or ("item:" .. id), worn)
        if kind == nil then kind = "upgrade" end -- (no stats to compare: it was planned as one)
        if RANK[kind] and (not pick or RANK[kind] > RANK[pick.kind]) then
            pick = { kind = kind, invSlot = sl, old = worn and ItemInfo(worn) or nil }
        end
    end
    if not pick then return nil end
    pick.id, pick.name = id, name or PC:ItemName(id) or "?"
    return pick
end
function UI:EquipList()
    local out, seen = {}, {}
    for _, b in ipairs(PC.BagSlots and PC.BagSlots() or {}) do
        if not seen[b.id] then
            seen[b.id] = true
            local u = self:ToEquip(b.id)
            if u then u.bag, u.slot = b.bag, b.slot; out[#out + 1] = u end
        end
    end
    return out
end
-- Put it on (the game asks first if it binds to you)
function UI:Equip(u)
    if not u then return end
    if InCombatLockdown and InCombatLockdown() then return PC.Print("Can't change gear in combat.") end
    local f = (C_Item and C_Item.EquipItemByName) or EquipItemByName
    if f then pcall(f, u.id, u.invSlot) end
    if PC.UI then PC.UI.planBtnCache = nil end
    C_Timer.After(0.5, function() PC:RefreshUI() end)
end
-- Not wearing it after all: it's no longer kept, and sells like anything else
function UI:DontEquip(id)
    if PC.cdb.gearKeep then PC.cdb.gearKeep[id] = nil end
    if PC.PushUndo then PC:PushUndo({ kind = "equip", id = id }) end
    PC.Buy:Say(("%s: not put on. It's sold like anything else now. |cff888888(/pc undo puts it back)|r"):format(PC:ItemName(id) or "That item"))
    PC:RefreshUI()
end

-- One line about it: "beats your X" / "about the same as your X", and what goes up and down
function UI:GearLine(u)
    local what = u.oldName and ((u.kind == "upgrade" and "beats your %s" or "about the same as your %s"):format(u.oldName))
        or "nothing worn there now"
    local changes = {}
    for _, t in ipairs(u.ups or {}) do changes[#changes + 1] = "|cff40ff40" .. t .. "|r" end
    for _, t in ipairs(u.downs or {}) do changes[#changes + 1] = "|cffff4040" .. t .. "|r" end
    return what, table.concat(changes, ", ")
end

function UI:PlanGearUpgrades()
    local list = self:GearUpgrades()
    if #list == 0 then return PC.Print("You have no items you can craft to upgrade your own gear.") end
    if PC:Plans()["Gear upgrades"] then PC:SwitchPlan("Gear upgrades") else PC:NewPlan("Gear upgrades") end
    local plan = self:PlanTable()
    wipe(plan)
    if PC.cdb.skipCraft then PC.cdb.skipCraft["Gear upgrades"] = nil end -- made fresh
    -- what's made is yours to wear: never posted or sold (for a few days)
    PC.cdb.gearKeep = PC.cdb.gearKeep or {}
    PC.cdb.gearNotes = {}
    local ups, close = {}, {}
    for _, u in ipairs(list) do
        plan[u.e.id] = 1
        PC.cdb.gearKeep[u.e.r.output] = time()
        PC.cdb.gearNotes[u.e.r.output] = { kind = u.kind, old = u.oldName, ups = u.ups, downs = u.downs }
        local n = PC:ItemName(u.e.r.output) or "?"
        if u.kind == "upgrade" then ups[#ups + 1] = n else close[#close + 1] = n end
    end
    local msg = ("Gear upgrades plan: %s"):format(#ups > 0 and table.concat(ups, ", ") or "no clear upgrades")
    if #close > 0 then msg = msg .. (". About the same as yours (your call): %s"):format(table.concat(close, ", ")) end
    PC.Print(msg .. ".")
    PC:RefreshUI()
end

-- Something to make for each of these buttons? (greyed out when not, with a tooltip saying why)
function UI:PlanButtonStates()
    local now = GetTime and GetTime() or 0
    local c = self.planBtnCache
    if c and now - c.t < 5 then return c end
    if not self.allEntries then self.allEntries = PC:Analyze() end
    local entries = self.allEntries or {}
    -- Have materials: a recipe your materials already make, that it would recommend
    local have = false
    for _, e in ipairs(entries) do
        if PC:MeetsMin(e) and PC:SalesOK(e) and e.r and e.r.reagents and #e.r.reagents > 0 then
            local ok = true
            for _, rg in ipairs(e.r.reagents) do
                if (PC:ReagentCount(rg) or 0) < (rg.n or 1) then ok = false break end
            end
            if ok then have = true break end
        end
    end
    -- Skill up: a profession with points to go, and a recipe in it that isn't grey
    local need = {}
    for _, pr in pairs(PC.cdb.professions or {}) do
        if pr.name and (pr.max or 0) > 0 and (pr.rank or 0) < pr.max then need[pr.name] = true end
    end
    local skill = false
    for _, e in ipairs(entries) do
        local pname = e.r and ((e.r.prof == "Smelting" and "Mining") or e.r.prof)
        if pname and need[pname] and self.SKILL_CHANCE[e.r.diff] then skill = true break end
    end
    local gear = self:GearUpgrades()
    c = { t = now, have = have, skill = skill, gear = gear }
    self.planBtnCache = c
    return c
end

function UI:UpdatePlanButtons()
    if not (self.haveBtn and self.skillBtn and self.gearBtn) then return end
    local ok, st = pcall(self.PlanButtonStates, self)
    if not ok or not st then return end
    self.haveBtn.none = not st.have
    self.skillBtn.none = not st.skill
    self.gearBtn.none = #st.gear == 0
    self.gearBtn.list = st.gear
    if UI.nav and UI.LayoutNav then UI:LayoutNav() end -- the same three in the list on the left
    -- (greyed out, the tooltip still says why)
    for _, btn in ipairs({ self.haveBtn, self.skillBtn, self.gearBtn }) do
        if btn.SetMotionScriptsWhileDisabled then btn:SetMotionScriptsWhileDisabled(true) end
    end
    self.haveBtn:SetEnabled(st.have)
    self.skillBtn:SetEnabled(st.skill)
    self.gearBtn:SetEnabled(#st.gear > 0)
end

-- "Have materials": fill the plan with what your materials can already make (best profit first)
function UI:PlanFromBags()
    -- its own plan, called "Have materials" (made fresh each click); your other plans stay as they are
    if PC:Plans()["Have materials"] then PC:SwitchPlan("Have materials") else PC:NewPlan("Have materials") end
    local plan = self:PlanTable()
    wipe(plan)
    if PC.cdb.skipCraft then PC.cdb.skipCraft["Have materials"] = nil end -- made fresh
    -- what you own, by material slot item (any quality counts, like the materials list)
    local stock = {}
    local function slotKey(rg) return table.concat(PC:ReagentIDs(rg), ",") end
    local function have(rg)
        local k = slotKey(rg)
        if stock[k] == nil then stock[k] = PC:ReagentCount(rg) end
        return stock[k]
    end
    local function use(rg, n) local k = slotKey(rg); stock[k] = have(rg) - n end
    local byID = {}
    for _, e in ipairs(self.allEntries or {}) do byID[e.id] = e end
    -- what's already planned uses materials first
    for id, n in pairs(plan) do
        local e = byID[id]
        if e then for _, rg in ipairs(e.r.reagents) do use(rg, rg.n * n) end end
    end
    -- then the most profitable recipes get what's left (only ones that make the minimum profit, and
    -- for the AH only ones that sold there today: it's a recommendation)
    local list = {}
    for _, e in ipairs(self.allEntries or {}) do
        if PC:MeetsMin(e) and PC:SalesOK(e) then list[#list + 1] = e end
    end
    table.sort(list, function(a, b) return a.profit > b.profit end)
    local added, crafts = 0, 0
    for _, e in ipairs(list) do
        local can = math.huge
        for _, rg in ipairs(e.r.reagents) do
            can = math.min(can, math.floor(math.max(have(rg), 0) / rg.n))
        end
        if can ~= math.huge and can > 0 then
            -- only as many as your bags have room for
            local cur = plan[e.id] or 0
            while can > 0 and not self:PlanFits(e.id, cur + can) do can = can - 1 end
            if can > 0 then
                for _, rg in ipairs(e.r.reagents) do use(rg, rg.n * can) end
                plan[e.id] = math.min(cur + can, 9999)
                added, crafts = added + 1, crafts + can
            else
                self.bagLimited = true
            end
        end
    end
    if self.bagLimited then
        PC.Print(("|cffff8040Some crafts were left out: not enough bag space (%d free slots).|r"):format(PC:FreeBagSlots()))
        self.bagLimited = nil
    end
    if added == 0 then
        PC.Print(("Your materials don't make any more crafts at %s%%+ profit right now."):format(PC:MinProfitPct()))
    else
        PC.Print(("Added %d recipe%s (%d crafts) you can make with the materials you have."):format(added, added == 1 and "" or "s", crafts))
    end
    PC:RefreshUI()
end

-- Fishmonger Forever's "Make gold from my catch": a "My catch" plan. Cooks the fish that are worth more
-- cooked (from the fish themselves, so no bag room is needed), and the rest of the fish are the plan's to
-- sell, Auction House or vendor, whichever pays more. The player asked for it, so a skipped "sell" is
-- back on. Nothing is sold until the player asks for this. ids: { [itemID] = true } (the fish).
function UI:PlanFromCatch(ids)
    if PC.inCombat then return end
    if not self.allEntries then self.allEntries = PC:Analyze() end
    local planName = "My catch"
    if PC:Plans()[planName] then PC:SwitchPlan(planName) else PC:NewPlan(planName) end
    local plan = self:PlanTable()
    wipe(plan)
    local cdb = PC.cdb
    if cdb.skipCraft then cdb.skipCraft[planName] = nil end
    local left = {}
    for id in pairs(ids or {}) do
        local n = PC:BagCount(id)
        if n > 0 then left[id] = n end
    end
    -- recipes that use the catch and pay more than the fish do, best first
    local list = {}
    for _, e in ipairs(self.allEntries or {}) do
        if e.profit and e.profit > 0 and e.r and e.r.reagents then
            for _, rg in ipairs(e.r.reagents) do
                for _, iid in ipairs(PC:ReagentIDs(rg)) do if left[iid] then list[#list + 1] = e; break end end
                if list[#list] == e then break end
            end
        end
    end
    table.sort(list, function(a, b) return a.profit > b.profit end)
    local cooks = {}
    for _, e in ipairs(list) do
        local can = math.huge
        for _, rg in ipairs(e.r.reagents) do
            local have, fish = 0, false
            for _, iid in ipairs(PC:ReagentIDs(rg)) do
                if left[iid] then have, fish = have + left[iid], true end
            end
            if not fish then have = PC:ReagentCount(rg) end
            can = math.min(can, math.floor(have / math.max(rg.n or 1, 1)))
        end
        if can ~= math.huge and can > 0 then
            plan[e.id] = math.min((plan[e.id] or 0) + can, 9999)
            for _, rg in ipairs(e.r.reagents) do
                local need = (rg.n or 1) * can
                for _, iid in ipairs(PC:ReagentIDs(rg)) do
                    if left[iid] and need > 0 then
                        local u = math.min(left[iid], need)
                        left[iid], need = left[iid] - u, need - u
                    end
                end
            end
            cooks[#cooks + 1] = ("%d %s"):format(can, e.r.name or "?")
        end
    end
    -- the fish nothing uses: this plan's to sell
    cdb.planCrafted, cdb.planCraftedPlan = cdb.planCrafted or {}, cdb.planCraftedPlan or {}
    cdb.planLeftover = cdb.planLeftover or {}
    cdb.catchIDs = {}
    local made = PC:PlanMade(planName)
    local fish = 0
    for id, n in pairs(left) do
        if n > 0 then
            cdb.planCrafted[id] = cdb.planCrafted[id] or time()
            cdb.planCraftedPlan[id] = planName
            cdb.planLeftover[id] = true
            cdb.catchIDs[id] = true
            made[id] = math.max(made[id] or 0, n)
            fish = fish + n
        end
    end
    -- you asked to sell: a skipped "sell" is back on, and a Task Button closed with the X comes back
    cdb.sellSkipUntil = nil
    if PC.Next then PC.Next.dismissed = nil end
    cdb.barClosed = nil
    local parts = {}
    if #cooks > 0 then parts[#parts + 1] = "cook " .. table.concat(cooks, ", ") end
    if fish > 0 then parts[#parts + 1] = ("sell %d fish (Auction House or vendor, whichever pays more)"):format(fish) end
    if #parts == 0 then
        PC.Print("Your catch: nothing in your bags to cook or sell.")
    else
        PC.Print("Your catch: " .. table.concat(parts, ", then ") .. ". The Task Button shows the way.")
    end
    PC:RefreshUI(true)
end

-- Where a crafted item sells: "Vendor", "AH", or nil (whichever pays more)
function UI:SetSellVia(itemID, via, quiet)
    if not itemID then return end
    PC.cdb.sellVia = PC.cdb.sellVia or {}
    PC.cdb.sellVia[itemID] = via
    self.allEntries = nil
    if not quiet then
        PC.Print(("%s now sells %s."):format(PC:ItemName(itemID) or "It", via == "Vendor" and "to a vendor" or via == "AH" and "on the Auction House" or "wherever pays more"))
    end
    PC:RefreshUI()
end

-- Fill the materials table
function UI:FillShopRows(list)
    local maxOff = math.max(#list - #self.shopRows, 0)
    self.shopOffset = math.min(math.max(self.shopOffset or 0, 0), maxOff)
    for i, row in ipairs(self.shopRows) do
        local it = list[i + self.shopOffset]
        row.itemID = it and it.id
        row.usedBy = it and it.usedBy
        row.slot = it and it.slot
        if it then
            row.icon:SetTexture(ItemIcon(it.id))
            local nm = PC:ItemName(it.id)
            if it.rank then nm = nm .. UI.QualityTag(it.rank, it.ranks, it.id) end
            row.name:SetText(nm)
            row.need:SetText(it.need)
            -- what's on you, and how much of it is really in the bank, in the mail or still on its way
            local inBank = PC.Bank and PC.Bank:Known() and PC.Bank:Count(it.id) or 0
            local coming = PC.Buy:InFlight(it.id)
            local inMail = PC:MailPending(it.id)
            local onYou = math.max(it.have - inBank - coming - inMail, 0)
            local extra = {}
            if inBank > 0 then extra[#extra + 1] = inBank .. " bank" end
            if inMail > 0 then extra[#extra + 1] = inMail .. " mail" end
            if coming > 0 then extra[#extra + 1] = "|cffffd100" .. coming .. " coming|r" end
            if #extra > 0 then
                row.have:SetText(("%d |cff888888(%s)|r"):format(onYou, table.concat(extra, ", ")))
            else
                row.have:SetText(it.have)
            end
            local buyState = PC.Buy:StateFor(it.id)
            if it.craft then
                if it.craft.disenchant then
                    -- short in the Buy column; the Total column says which green to make and disenchant
                    row.buy:SetText(("|cffc080ffDE %d|r"):format(it.craft.n))
                    row.total:SetText(("|cffc080ff(make %d %s, disenchant)|r"):format(it.craft.n, it.craft.r.name or "a green"))
                else
                    row.buy:SetText("|cff40c0ffmake " .. it.craft.n .. "|r")
                    row.total:SetText("|cff40c0ff(craft it: cheaper than buying)|r")
                end
            elseif coming > 0 or buyState == "buying" then
                -- sent to the AH, waiting for its answer: counted as had, said as being bought
                row.buy:SetText(("|cffffd100buying %d|r"):format(coming > 0 and coming or (PC.Buy.buy and PC.Buy.buy.qty or 0)))
                row.total:SetText("")
            elseif it.buy == 0 then
                row.buy:SetText("|cff40ff40ok|r")
                row.total:SetText("")
            else
                row.buy:SetText("|cffffd100" .. it.buy .. "|r")
                if it.src == "Vendor" then
                    row.total:SetText(PC:Money(it.sub, false, true) .. " |cff40c0ff(vendor)|r")
                elseif it.short then
                    row.total:SetText(it.sub and ("|cffff5555" .. PC:Money(it.sub, false, true) .. "+|r") or "|cffff5555?|r")
                else
                    row.total:SetText(it.sub and PC:Money(it.sub, false, true) or "|cffff5555?|r")
                end
            end
            row.each:SetText(it.unit and PC:Money(it.unit, false, "silver") or "|cffff5555none|r")
            row.buyN = it.buy
            local btn = row.buyBtn
            local state = PC.Buy:StateFor(it.id)
            local vqty = self:VendorQty(it)
            if not state and vqty > 0 and PC.VendorBuy:Open() and PC.VendorBuy:Sells(it.id) then
                -- at a vendor that sells it: buy it here
                row.buyItem = { id = it.id, name = PC:ItemName(it.id), qty = vqty, vendor = true }
            elseif state then
                row.buyItem = { id = it.id, name = PC:ItemName(it.id), qty = PC.Buy.buy.qty }
            elseif it.buy > 0 and it.src ~= "Vendor" and PC.Buy:CanBuy(it.id) and PC.Buy:AHQty(it.id, it.buy) > 0
                and PC:ProfitableBuyQty(it.id, PC.Buy:AHQty(it.id, it.buy)) > 0 then
                -- items a vendor also sells: only what's listed under the vendor's price; and only while
                -- each keeps its craft at the minimum profit (a click works it all out again)
                local ah = PC.Buy:AHQty(it.id, it.buy)
                local n = PC:ProfitableBuyQty(it.id, ah)
                row.buyItem = { id = it.id, name = PC:ItemName(it.id), qty = n, vendorRest = it.buy - ah, stopped = ah - n }
            elseif it.buy > 0 and it.src ~= "Vendor" and PC.Buy:ClassicAH() and PC.Buy:AHQty(it.id, it.buy) > 0 then
                -- classic-style AH: the button runs the search; you click the buyout
                local n = PC.Buy:AHQty(it.id, it.buy)
                row.buyItem = { id = it.id, name = PC:ItemName(it.id), qty = n, vendorRest = it.buy - n, search = true }
            else
                row.buyItem = nil
            end
            if row.buyItem and row.buyItem.vendor then
                btn:Show()
                btn:SetText("|cff40c0ffVendor|r")
                btn:Enable()
            elseif row.buyItem and row.buyItem.search then
                btn:Show()
                btn:SetText("Find")
                btn:Enable()
            elseif not row.buyItem then
                btn:Hide()
                if it.buy > 0 and it.src ~= "Vendor" and PC.Buy:VendorPrice(it.id) then
                    -- the AH can't beat the vendor for this amount
                    row.total:SetText((row.total:GetText() or "") .. " |cff40c0ff(vendor)|r")
                end
            else
                btn:Show()
                if state == "quoted" then
                    local b = PC.Buy.buy
                    btn:SetText((b.warn and "|cffff5555" or "|cff40ff40") .. PC:Money(b.total or 0, false, true) .. "|r")
                elseif state == "buying" then
                    btn:SetText("Buying...") -- (sent: it can't be taken back, only waited for)
                elseif state then
                    btn:SetText("Cancel")
                else
                    btn:SetText("Buy")
                end
                btn:SetEnabled((PC.ahOpen and state ~= "buying") and true or false)
            end
            row:Show()
        else
            row:Hide()
        end
    end
end

function UI:UpdateShopping()
    if not self.planRows then return end
    self:UpdatePlanBar()
    local entries = self:PlanEntries() -- (in name order: the materials list is worked out from this one)

    -- AH and V Profit of each recipe's whole batch (the totals line needs them all); the rest only
    -- for the rows on show, or for all of them when sorting by it
    local profits, matsOf = {}, {}
    for _, e in ipairs(entries) do profits[e] = { PC:BatchProfit(e, e.planCount) } end
    local function Mats(e)
        if matsOf[e] == nil then
            local _, spend, missing = PC:ShoppingList(e, e.planCount)
            matsOf[e] = (not missing) and spend or false
        end
        return matsOf[e] or nil
    end
    local shown = {}
    for i, e in ipairs(entries) do shown[i] = e end
    local editing = false
    for _, row in ipairs(self.planRows) do if row.count:HasFocus() then editing = true end end
    if editing and self.planOrder then
        -- typing in a count box: the rows stay where they are until you're done
        local pos = {}
        for i, id in ipairs(self.planOrder) do pos[id] = i end
        table.sort(shown, function(a, b) return (pos[a.id] or 1e9) < (pos[b.id] or 1e9) end)
    else
        local s = self:SortState("plan")
        UI.SortRows(shown, s.key, s.dir, function(e, k)
            if k == "name" then return e.r.name:lower() end
            if k == "planCount" then return e.planCount end
            if k == "craftable" then return (PC:Craftable(e)) end
            if k == "mats" then return Mats(e) end
            if k == "ahProfit" then return profits[e][1] end
            if k == "vendorProfit" then return profits[e][2] end
            if k == "matsMode" then return e.high and (e.mats == "high" and "top quality" or "cheapest") or nil end
        end, function(e) return e.r.name:lower() end)
    end
    self.planOrder = {}
    for i, e in ipairs(shown) do self.planOrder[i] = e.id end
    self:PaintHeaders(self.planHeaders, "plan")

    -- plan rows
    self.planOffset = math.min(math.max(self.planOffset or 0, 0), math.max(#shown - PLAN_ROWS, 0))
    for i, row in ipairs(self.planRows) do
        local e = shown[i + self.planOffset]
        row.entry = e
        if e then
            row.icon:SetTexture(ItemIcon(e.outID or e.r.output))
            local makes = UI.QualityTag(e.qualityUsed, e.r.outputs and #e.r.outputs, e.outID)
            if e.r.qty and e.r.qty ~= 1 then
                makes = makes .. (" |cff888888x%s|r"):format(e.r.qty % 1 == 0 and tostring(e.r.qty) or ("%.1f"):format(e.r.qty))
            end
            row.name:SetText(("|cffffffff%s|r%s"):format(e.r.name, makes)) -- white: grey looked "unavailable"; the arrows show skill-ups
            SetSkillArrows(row, e.r.diff)
            row.craft.recipeID, row.craft.recipe = e.id, e.r
            if not row.count:HasFocus() then row.count:SetText(tostring(e.planCount)) end
            local c, pr = row.cell, profits[e]
            FitCell(c.craftable, (UI.CraftableCells(e)))
            local m = Mats(e)
            FitCell(c.mats, m and PC:Money(m) or "|cffff5555?|r")
            FitCell(c.ahProfit, PC:Money(pr[1], true))
            -- blue: it's sold to a vendor
            FitCell(c.vendorProfit, (e.route == "Vendor" and pr[2] and pr[2] > 0) and ("|cff40c0ff" .. PC:Money(pr[2]) .. "|r") or PC:Money(pr[2], true))
            if PC.Craft:IsOpenFor(e.r) then
                -- at this profession's window: craft instead of choosing materials
                row.matsBtn:Hide()
                local n = PC.Craft:Count(e)
                row.craftNow:SetText(n > 0 and ("Craft " .. n) or "Need mats")
                row.craftNow:SetEnabled(n > 0)
                row.craftNow:Show()
            else
                row.craftNow:Hide()
                if e.high then
                    row.matsBtn:SetText(e.mats == "high" and "Top quality" or "Cheapest")
                    row.matsBtn:Show()
                else
                    row.matsBtn:Hide()
                end
            end
            row:Show()
        else
            row:Hide()
        end
    end
    self.planEmpty:SetText(#entries == 0 and
        ("\"%s\" is empty.\nOn the Recipes tab, click the bag icon next to a recipe, pick how many, and Add to plan."):format(PC:PlanName()) or "")

    -- combined materials (sorted on a copy: the list is shared with the buying and the Task Button)
    local list, total, missing = PC:CombinedShoppingList(entries, 1)
    local mats = {}
    for i, it in ipairs(list) do mats[i] = it end
    local ms = self:SortState("mats")
    local function MatName(it) return (PC:ItemName(it.id) or ""):lower() end
    UI.SortRows(mats, ms.key, ms.dir, function(it, k)
        if k == "name" then return MatName(it) end
        if k == "each" then return it.unit end
        if k == "total" then return ((it.buy or 0) > 0 and not it.craft) and it.sub or nil end -- (made or had: nothing to pay)
        return it[k]
    end, MatName)
    self:PaintHeaders(self.matHeaders, "mats")
    self.matData = mats
    self:FillShopRows(mats)
    self.shopEmpty:SetText("")

    -- the whole plan's AH and V Profit (recipes with no price at all are counted apart)
    local ahT, vT, nAH, nV, unknown = 0, 0, 0, 0, 0
    for _, e in ipairs(entries) do
        local pr = profits[e]
        if pr[1] then ahT, nAH = ahT + pr[1], nAH + 1 end
        if pr[2] then vT, nV = vT + pr[2], nV + 1 end
        if not pr[1] and not pr[2] then unknown = unknown + 1 end
    end
    local money = PC:Gold()
    local b, msg = PC.Buy.buy, PC.Buy:Message()
    if b and b.state == "quoting" then
        self.shopSummary:SetText(("|cffffd100Getting the price for %d %s...|r"):format(b.qty, b.name))
    elseif b and b.state == "quoted" then
        self.shopSummary:SetText(("%s%d %s: %s|r (%s each)%s"):format(b.warn and "|cffff5555" or "|cffffffff", b.qty, b.name,
            PC:Money(b.total or 0, false, true), PC:Money(b.unit or 0, false, "silver"), b.warn and " |cffff5555price went up!|r" or ""))
    elseif b and b.state == "buying" then
        self.shopSummary:SetText(("|cffffd100Buying %d %s...|r"):format(b.qty, b.name))
    elseif msg then
        self.shopSummary:SetText(msg)
    elseif #entries == 0 then
        self.shopSummary:SetText("")
    else
        local spendText = missing and "|cffff5555unknown|r" or ((total > money and "|cffff5555" or "|cffffffff") .. PC:Money(total) .. "|r")
        self.shopSummary:SetText(("Spend %s  " .. UI.DIM .. "(you have %s)|r   Auction Profit %s   Vendor Profit %s%s"):format(
            spendText, PC:Money(money), nAH > 0 and PC:Money(ahT, true) or PC:Money(nil), nV > 0 and PC:Money(vT, true) or PC:Money(nil),
            unknown > 0 and " " .. UI.DIM .. "(+" .. unknown .. " unpriced)|r" or ""))
    end
    self.shopClear:SetEnabled(#entries > 0)
end

-- How many of a material should come from a vendor (vendor cheaper, or the AH can't beat it for the rest)
function UI:VendorQty(it)
    if not it.buy or it.buy <= 0 then return 0 end
    if it.src == "Vendor" then return it.buy end
    if PC.Buy:VendorPrice(it.id) then return it.buy - PC.Buy:AHQty(it.id, it.buy) end
    return 0
end

-- What the plan needs from vendors: { id, name, qty }
function UI:PlanVendorList(list)
    if not list then list = PC:CombinedShoppingList(self:PlanEntries(), 1) end
    local memo = PC:Memo()
    if memo and memo.vendListFor == list then return memo.vendList end
    local out = {}
    local later = PC:LaterMats(list) -- a later stage's materials: bought when that stage comes
    local k = PC:BatchScale(list, later) -- a batch your bags can hold, not the whole plan at once
    for _, it in ipairs(list) do
        local n = self:VendorQty(it)
        if k < 1 then
            -- a batch is a share of the WHOLE need (not of what's left: that shrank to 1 at a time, a
            -- maple seed per click): buy up to that share, counting what you already have
            local need = it.need or n
            local have = it.have or math.max(need - (it.buy or 0), 0)
            local target = math.ceil(need * k)
            n = math.max(math.min(n, target - have), 0)
        end
        if n > 0 and not later[it.id] then out[#out + 1] = { id = it.id, name = PC:ItemName(it.id), qty = n } end
    end
    if memo then memo.vendListFor, memo.vendList = list, out end
    return out
end

-- What the plan still needs from the AH, top to bottom: { id, name, qty } (vendor items left out)
function UI:PlanBuyList(list)
    if not list then list = PC:CombinedShoppingList(self:PlanEntries(), 1) end
    local memo = PC:Memo()
    if memo and memo.buyListFor == list then return memo.buyList end
    local out = {}
    local later = PC:LaterMats(list)
    -- (no bag-room batches here: what you buy on the AH waits in your mailbox, not your bags)
    for _, it in ipairs(list) do
        if it.buy and it.buy > 0 and it.src ~= "Vendor" and not later[it.id] then
            local want = it.buy
            local n = want > 0 and PC.Buy:AHQty(it.id, want) or 0 -- vendor items: only under the vendor's price
            if n > 0 then out[#out + 1] = { id = it.id, name = PC:ItemName(it.id), qty = n } end
        end
    end
    if memo then memo.buyListFor, memo.buyList = list, out end
    return out
end

---------------------------------------------------------------------------
-- Plan bar: which saved plan you're working on (per character), with New / Rename / Delete
---------------------------------------------------------------------------
function UI:CreatePlanBar(p)
    local label = UI.Ink(p:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
    label:SetPoint("TOPLEFT", 16, -66)
    label:SetText("Plan")
    local pick = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    pick:SetSize(190, 22)
    pick:SetPoint("LEFT", label, "RIGHT", 8, 0)
    pick:SetScript("OnClick", function() UI:TogglePlanMenu() end)
    pick:SetScript("OnEnter", function(b)
        ShowTooltip(b, { "Saved crafting plans", "Click to switch to another plan. Changes save by themselves.",
            "The bag icon next to a recipe adds to the plan shown here." })
    end)
    pick:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.planPick = pick
    local function Btn(text, w, what, anchor)
        local b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
        b:SetSize(w, 22)
        b:SetPoint("LEFT", anchor, "RIGHT", 4, 0)
        b:SetText(text)
        b:SetScript("OnClick", function() UI:AskPlan(what) end)
        return b
    end
    local new = Btn("New", 56, "new", pick)
    local rename = Btn("Rename", 72, "rename", new)
    self.planDelete = Btn("Delete", 64, "delete", rename)
    local gold = UI.GreenButton(p, 118, 22, "Make me gold")
    gold:SetPoint("TOPRIGHT", p, "TOPLEFT", 12 + PW, -62)
    gold:SetScript("OnClick", function() PC:Safe("make me gold", PC.MakeGold.Open, PC.MakeGold) end)
    gold:SetScript("OnEnter", function(b)
        ShowTooltip(b, { "Make me gold", "Builds a plan with the best crafts that fit your spending limit",
            "and that actually sell." })
    end)
    gold:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.makeGoldBtn = gold
    gold:Hide() -- Make me gold now hangs off the side with the tabs
    self.planInfo = UI.Ink(p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), true)
    self.planInfo:SetPoint("LEFT", self.planDelete, "RIGHT", 10, 0)
    self.planInfo:SetPoint("RIGHT", p, "TOPLEFT", 12 + PW, -72) -- (level with the plan bar's buttons, like its left end)
    self.planInfo:SetJustifyH("RIGHT")
    self.planInfo:SetWordWrap(false)

    local menu = CreateFrame("Frame", nil, p, "BackdropTemplate")
    menu:SetPoint("TOPLEFT", pick, "BOTTOMLEFT", 0, -2)
    menu:SetWidth(300)
    menu:SetFrameStrata("DIALOG")
    if menu.SetBackdrop then
        menu:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        menu:SetBackdropColor(0.04, 0.035, 0.03, 0.98)
        menu:SetBackdropBorderColor(0.78, 0.6, 0.23, 1)
    end
    menu.buttons = {}
    menu:Hide()
    menu:SetScript("OnHide", function() end)
    self.planMenu = menu
end

-- The standard pop-up: a Skill up plan isn't for profit
function UI:SkillPlanNotice(name)
    local Popup = self.Popup
    if not Popup then return end
    self.skillPopup = self.skillPopup or Popup.New("ProfitCrafterSkillPlan")
    self.skillPopup:Open({
        title = "Skill-up plan", sub = name or "Skill up", subColor = { 1, 0.69, 0.25 },
        sections = { { lines = {
            "This plan is not for profit. It's only meant to raise your crafting skill.",
            "It picks the cheapest crafts that still give skill points, so expect to spend gold. Whatever you make still gets sold.",
            "To earn gold, switch to another plan or use Make me gold.",
        }, bullets = false } },
        buttons = { { text = "OK" } },
        fit = true,
    })
end

-- Is the plan shown a Skill up plan (made to level a profession, not to earn)?
function UI:IsSkillPlan(name)
    name = name or PC:PlanName() or ""
    return name:find("^Skill up") ~= nil
end

function UI:UpdatePlanBar()
    if not self.planPick then return end
    self:UpdatePlanButtons()
    local name = PC:PlanName()
    -- temporary plans (Make me gold, Have materials, Skill up) say so; yours are saved
    local tag = PC:IsTempPlan(name) and " |cffff8040(temp)|r" or ""
    self.planPick:SetText("|TInterface\\Icons\\INV_Misc_Note_01:14:14|t " .. name .. tag .. (UI.DROP or "  |cff888888v|r"))
    local n = 0
    for _ in pairs(PC:CurrentPlan()) do n = n + 1 end
    local plans = #PC:PlanNames()
    local cost, missing = self:PlanCost()
    local limit = PC.cdb.overrides.gold
    local need, free = self:PlanSlots(), PC:FreeBagSlots()
    local overMarket
    if PC.MakeGold then
        for _, e in ipairs(self:PlanEntries()) do
            local cap = PC.MakeGold:MarketCap(e)
            if cap and (e.planCount or 0) > cap then overMarket = (overMarket or 0) + 1 end
        end
    end
    local skillPlan = self:IsSkillPlan()
    if PC:PlanFinished(name) then
        self.planInfo:SetText("|cff40ff40Finished. Saved: pick it in the plan menu to run it again|r")
    elseif need > free then
        self.planInfo:SetText(("|cffff5555Needs %d bag slots, %d free|r"):format(need, free))
    elseif skillPlan and not (not missing and limit and cost > limit) and not (not missing and cost > GetMoney()) then
        -- a skill-up plan: say so plainly, it's not about profit
        self.planInfo:SetText("|cffff8040Skill-up plan: built to raise skill, not to make a profit|r")
    elseif overMarket and not skillPlan then
        self.planInfo:SetText(("|cffff8040%d recipe%s set above what the market wants|r"):format(overMarket, overMarket == 1 and "" or "s"))
    elseif not missing and limit and cost > limit then
        self.planInfo:SetText(("|cffff5555Over limit by %s|r"):format(PC:Money(cost - limit, false, true)))
    elseif not missing and cost > GetMoney() then
        self.planInfo:SetText(("|cffff5555%s more than your gold|r"):format(PC:Money(cost - GetMoney(), false, true)))
    else
        self.planInfo:SetText(("%d recipe%s  ·  %d plan%s"):format(n, n == 1 and "" or "s", plans, plans == 1 and "" or "s"))
        UI.Ink(self.planInfo, true)
    end
end

function UI:TogglePlanMenu()
    local menu = self.planMenu
    if not menu then return end
    if menu:IsShown() then menu:Hide() return end
    local names, cur = PC:PlanNames(), PC:PlanName()
    for i, name in ipairs(names) do
        local b = menu.buttons[i]
        if not b then
            b = CreateFrame("Button", nil, menu)
            b:SetSize(292, 20)
            b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 20)
            local hl = b:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(unpack(T.rowHover))
            b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            b.text:SetPoint("LEFT", 6, 0)
            b.text:SetWidth(280)
            b.text:SetJustifyH("LEFT")
            b.text:SetWordWrap(false)
            b:SetScript("OnClick", function(btn)
                menu:Hide()
                if PC.ToLearn and PC.ToLearn:IsRun(btn.name) then
                    PC.ToLearn:StartRun()
                    UI.planOffset, UI.shopOffset = 0, 0
                    PC:RefreshUI()
                    return
                end
                PC:SwitchPlan(btn.name) -- (a finished saved plan fills back up)
                if UI:IsSkillPlan(btn.name) then
                    PC.Print("|cffff8040Heads up: \"" .. btn.name .. "\" is set up to raise your skill, not to make a profit.|r")
                    UI:SkillPlanNotice(btn.name)
                end
                UI.planOffset, UI.shopOffset = 0, 0
                UI:WarnPlanBudget()
                PC:RefreshUI()
            end)
            menu.buttons[i] = b
        end
        b.name = name
        local n = 0
        for _ in pairs(PC:Plans()[name]) do n = n + 1 end
        local isRun = PC.ToLearn and PC.ToLearn:IsRun(name)
        if isRun then n = #PC.ToLearn.Data().trip end
        local isGuide = PC.Guide and PC.Guide:IsName(name)
        if isGuide then
            local st = PC.Guide:State() or {}
            n = math.max((tonumber(st.total) or 0) - (tonumber(st.doneN) or 0), 0)
        end
        local tag = isGuide and "  |cffffff60SnuggleUp guide|r" or isRun and "  |cffffd100recipes to get|r" or PC:IsTempPlan(name) and "  |cffff8040temp|r"
            or (PC:PlanFinished(name) and "  |cff40ff40finished: click to run again|r") or ""
        b.text:SetText((name == cur and (PC.ARROW_R .. " |cffffd100") or "|cffffffff     ") .. name .. "|r  |cff888888(" .. n .. ")|r" .. tag)
        b:Show()
    end
    for i = #names + 1, #menu.buttons do menu.buttons[i]:Hide() end
    menu:SetHeight(8 + #names * 20)
    menu:Show()
    if menu.Raise then menu:Raise() end
end

-- New / Rename / Delete: the standard pop-up (with a box to type the name)
function UI:AskPlan(what)
    if self.planMenu then self.planMenu:Hide() end
    if not self.Ask then return end
    local cur = PC:PlanName()
    local spec
    if what == "delete" then
        spec = { title = "Delete this plan?", sub = cur, subColor = { 1, 0.44, 0.44 },
            sections = { { lines = { "The plan and its list of crafts are removed. Your items aren't touched." }, bullets = false } },
            buttons = { { text = "Delete", onClick = function() UI:DoPlanAction("delete", "") end }, { text = "Cancel" } } }
    else
        spec = { title = what == "new" and "New crafting plan" or "Rename plan", sub = what == "rename" and cur or nil,
            sections = { { lines = { what == "new" and "Name for the new plan:" or "New name:" }, bullets = false } },
            input = { text = what == "rename" and cur or "", letters = 40 },
            buttons = { { text = "OK", onClick = function(typed) UI:DoPlanAction(what, typed or "") end }, { text = "Cancel" } } }
    end
    spec.fit = true
    self:Ask("ProfitCrafterPlanName", spec)
end

function UI:DoPlanAction(what, text)
    PC:Safe("crafting plans", function()
        local ok, why = true, nil
        if what == "new" then ok, why = PC:NewPlan(text)
        elseif what == "rename" then ok, why = PC:RenamePlan(text)
        else PC:DeletePlan() end
        if not ok and why then PC.Print(why) end
        UI.planOffset, UI.shopOffset = 0, 0
        UI:WarnPlanBudget()
        PC:RefreshUI()
    end)
end
