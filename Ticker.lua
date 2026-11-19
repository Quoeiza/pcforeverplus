-- ProfitCrafter: price ticker
--   A stock-market style strip of the materials that are moving: price now vs. usual, with good volume.
--   * one under the window's title bar
--   * optional: one across the whole screen, which you can drag up or down and lock in place
--   Hover pauses it. Click an item to see its price graph; shift-click searches the AH.

local ADDON, ns = ...
local PC = ns.PC

local Ticker = {}
PC.Ticker = Ticker

Ticker.MIN_MOVE = 5          -- % away from the usual price to count as "moving"
Ticker.MIN_LISTED = 100      -- good volume: at least this many listed...
Ticker.MIN_SOLD = 20         -- ...or about this many sold in the last day
Ticker.MAX_ITEMS = 25
Ticker.SPEED = 40            -- pixels per second
Ticker.GAP = 34              -- space between items
Ticker.REFRESH = 30          -- seconds between rebuilding the list

local MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"

---------------------------------------------------------------------------
-- What's on the ticker
---------------------------------------------------------------------------
-- Every material your shown recipes use (all qualities)
local function MaterialIDs()
    local set, ids = {}, {}
    for _, r in pairs(PC:ShownRecipes()) do
        for _, rg in ipairs(r.reagents or {}) do
            for _, id in ipairs(PC:ReagentIDs(rg)) do
                if not set[id] then set[id] = true; ids[#ids + 1] = id end
            end
        end
    end
    return ids
end

-- { id, name, price, pct, listed, sold } for materials that moved and have volume, biggest moves first
function Ticker:Items()
    local out = {}
    local prices, supply = PC:Prices(), PC:Supply()
    for _, id in ipairs(MaterialIDs()) do
        local pct, usual = PC:Trend(id)
        local price = prices[id]
        if pct and price and math.abs(pct) >= self.MIN_MOVE and not PC:IsVendorItem(id) then
            local listed = supply[id] or 0
            local sold = PC.SalesEstimate and PC:SalesEstimate(id, 86400) or nil
            if listed >= self.MIN_LISTED or (sold or 0) >= self.MIN_SOLD then
                out[#out + 1] = { id = id, name = PC:ItemName(id) or ("Item " .. id), price = price, usual = usual,
                    pct = pct, listed = listed, sold = sold }
            end
        end
    end
    table.sort(out, function(a, b) return math.abs(a.pct) > math.abs(b.pct) end)
    while #out > self.MAX_ITEMS do table.remove(out) end
    return out
end

local function Volume(n)
    if not n then return "?" end
    if n >= 10000 then return ("%.0fk"):format(n / 1000) end
    if n >= 1000 then return ("%.1fk"):format(n / 1000) end
    return tostring(n)
end

function Ticker:Text(it)
    local up = it.pct >= 0
    local arrow = "|T" .. MEDIA .. (up and "SortUp" or "SortDown") .. ":12:12:0:0|t"
    -- market colors: price up = green, down = red
    local col = up and "40ff40" or "ff5555"
    return ("|cffffd100%s|r  %s  |cff%s%s%d%%|r  |cff888888%s listed|r"):format(
        it.name, PC:Money(it.price, false, it.price >= 10000 and true or "silver"), col, arrow,
        math.floor(math.abs(it.pct) + 0.5), Volume(it.listed))
end

---------------------------------------------------------------------------
-- A scrolling strip (used for both tickers)
---------------------------------------------------------------------------
local Strip = {}
Strip.__index = Strip

local function NewStrip(frame)
    local st = setmetatable({ frame = frame, buttons = {}, offset = 0 }, Strip)
    if frame.SetClipsChildren then frame:SetClipsChildren(true) end
    st.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    st.empty:SetPoint("LEFT", 10, 0)
    st.empty:SetPoint("RIGHT", -10, 0)
    st.empty:SetJustifyH("LEFT")
    st.empty:SetWordWrap(false)
    frame:SetScript("OnUpdate", function(_, elapsed) st:Step(elapsed) end)
    return st
end

function Strip:Button(i)
    local b = self.buttons[i]
    if b then return b end
    b = CreateFrame("Button", nil, self.frame)
    b:SetHeight(self.frame:GetHeight() or 18)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("LEFT")
    b.text:SetWordWrap(false)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    b:SetScript("OnEnter", function(btn)
        self.paused = true
        local it = btn.item
        if not it then return end
        local tip = { it.name, ("Now %s, usually %s (%s%d%%)"):format(PC:Money(it.price), PC:Money(it.usual or 0),
            it.pct >= 0 and "+" or "-", math.floor(math.abs(it.pct) + 0.5)),
            ("%d listed at auction"):format(it.listed or 0) }
        if it.sold then tip[#tip + 1] = ("About %d sold in the last day"):format(it.sold) end
        tip[#tip + 1] = "|cff888888Click: price graph   Shift-click: search the Auction House|r"
        if PC.UI and PC.UI.ShowTooltip then PC.UI.ShowTooltip(btn, tip, it.id, nil, true) end
    end)
    b:SetScript("OnLeave", function()
        self.paused = false
        if GameTooltip then GameTooltip:Hide() end
    end)
    b:SetScript("OnClick", function(btn, button) Ticker:ClickItem(btn.item, button) end)
    self.buttons[i] = b
    return b
end

function Strip:SetItems(items, emptyText)
    self.items = items
    local x = 0
    for i, it in ipairs(items) do
        local b = self:Button(i)
        b.item = it
        b.text:SetText(Ticker:Text(it))
        local w = math.ceil((b.text:GetStringWidth() or 200)) + 4
        if w < 20 then w = 200 end
        b:SetWidth(w)
        b.w = w
        b.base = x
        x = x + w + Ticker.GAP
        b:Show()
    end
    for i = #items + 1, #self.buttons do self.buttons[i]:Hide(); self.buttons[i].item = nil end
    self.total = x
    self.empty:SetText(#items == 0 and (emptyText or "") or "")
    self:Place()
end

-- Lay the items out at the current scroll position; they wrap around to keep the strip full
function Strip:Place()
    local items = self.items or {}
    if #items == 0 then return end
    local width = self.frame:GetWidth() or 600
    local loop = math.max(self.total or 0, width + Ticker.GAP)
    self.offset = self.offset % loop
    for i = 1, #items do
        local b = self.buttons[i]
        local x = b.base - self.offset
        if x + (b.w or 0) < 0 then x = x + loop end
        b:ClearAllPoints()
        b:SetPoint("LEFT", self.frame, "LEFT", x, 0)
        -- fade items at the edges so nothing is cut off mid-word
        local w = b.w or 0
        local a = 1
        if x < 0 then a = math.max(0, 1 + x / w) elseif x + w > width then a = math.max(0, (width - x) / w) end
        b:SetAlpha(a)
    end
end

function Strip:Step(elapsed)
    if self.paused or not self.items or #self.items == 0 then return end
    self.offset = self.offset + Ticker.SPEED * (elapsed or 0)
    self:Place()
end

---------------------------------------------------------------------------
-- Clicking an item
---------------------------------------------------------------------------
function Ticker:ClickItem(it, button)
    if not it then return end
    local UI = PC.UI
    if not UI then return end
    if UI.ClickItem and UI:ClickItem(it.id, button) then return end -- shift-click searches, etc.
    if button == "LeftButton" then
        UI.itemSel = it.id
        if UI.OpenTab then UI:OpenTab(3) end
        -- scroll the Scanned items list to it
        for n, e in ipairs(UI.itemData or {}) do
            if e.id == it.id then UI.itemOffset = math.max(n - 3, 0) break end
        end
        PC:RefreshUI()
    end
end

---------------------------------------------------------------------------
-- The two tickers
---------------------------------------------------------------------------
local function Backdrop(frame, alpha)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.03, 0.025, 0.02, alpha)
    local top = frame:CreateTexture(nil, "BORDER")
    top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT")
    top:SetHeight(1)
    top:SetColorTexture(0.78, 0.6, 0.23, 0.7)
    local bottom = frame:CreateTexture(nil, "BORDER")
    bottom:SetPoint("BOTTOMLEFT"); bottom:SetPoint("BOTTOMRIGHT")
    bottom:SetHeight(1)
    bottom:SetColorTexture(0.78, 0.6, 0.23, 0.7)
    return bg
end

-- Under the window's title bar
function Ticker:CreateWindowTicker(win)
    if self.win then return end
    local f = CreateFrame("Frame", nil, win)
    f:SetPoint("TOPLEFT", win, "TOPLEFT", 2, -22)    -- all the way across, behind the round portrait
    f:SetPoint("TOPRIGHT", win, "TOPRIGHT", -8, -22)
    f:SetHeight(18)
    Backdrop(f, 0.55)
    -- the portrait, its gold ring (the window's border art), the title and the close button sit on top
    local base = (win.GetFrameLevel and win:GetFrameLevel()) or 1
    f:SetFrameLevel(base + 1)
    local function Above(fr, lvl)
        if fr and fr.GetFrameLevel and fr.SetFrameLevel and (fr:GetFrameLevel() or 0) < lvl then fr:SetFrameLevel(lvl) end
    end
    Above(win.PortraitContainer, base + 5) -- above the strip's own items (they sit a level or two up)
    Above(win.NineSlice, base + 6)
    Above(win.TitleContainer, base + 7)
    Above(win.CloseButton, base + 8)
    self.win = NewStrip(f)
    self.winFrame = f
    -- "no prices yet" starts right of the portrait, where it can be read
    if win.PortraitContainer then self.win.empty:SetPoint("LEFT", 72, 0) end
    self:Apply()
    self:Refresh(true)
end

-- Across the whole screen: drag it up or down while unlocked
function Ticker:CreateScreenTicker()
    if self.screen then return end
    local f = CreateFrame("Frame", "ProfitCrafterScreenTicker", UIParent)
    f:SetHeight(20)
    f:SetFrameStrata("LOW")
    Backdrop(f, 0.8)
    f.unlockedBg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.unlockedBg:SetAllPoints()
    f.unlockedBg:SetColorTexture(0.25, 0.55, 1, 0.25)
    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.hint:SetPoint("RIGHT", -8, 0)
    f.hint:SetText("|cff40c0ffDrag to move  |  lock it in ProfitCrafter's settings or /pc ticker lock|r")
    f:EnableMouse(true)
    f:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" and not PC.db.tickerLocked then Ticker.dragging = true end
    end)
    f:SetScript("OnMouseUp", function() Ticker.dragging = false end)
    self.screen = NewStrip(f)
    self.screenFrame = f
    -- dragging moves it up/down; it always spans the full width
    local strip = self.screen
    f:SetScript("OnUpdate", function(_, elapsed)
        if Ticker.dragging then
            if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then Ticker.dragging = false end
            local _, cy = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale() or 1
            local h = UIParent:GetHeight() or 768
            PC.db.tickerY = math.floor(math.min(math.max(h - cy / scale - 10, 0), h - 20) + 0.5)
            Ticker:PlaceScreen()
        end
        strip:Step(elapsed)
    end)
    self:PlaceScreen()
end

function Ticker:PlaceScreen()
    local f = self.screenFrame
    if not f then return end
    local y = PC.db.tickerY or 0
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -y)
    f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, -y)
    local locked = PC.db.tickerLocked and true or false
    f.unlockedBg:SetShown(not locked)
    f.hint:SetShown(not locked)
end

-- Settings: which tickers show, and whether the screen one is locked
function Ticker:Apply()
    if not PC.db then return end
    if self.winFrame then
        local on = PC.db.tickerWindow ~= false
        self.winFrame:SetShown(on)
    end
    if PC.db.tickerScreen then
        self:CreateScreenTicker()
        self.screenFrame:Show()
        self:PlaceScreen()
        self:Refresh(true)
    elseif self.screenFrame then
        self.screenFrame:Hide()
        self.dragging = false
    end
end

local EMPTY = "No big movers right now. Prices that move %d%%+ from usual, with good volume, show up here as you scan."

function Ticker:Refresh(force)
    if not PC.db then return end
    if not force and self.lastBuild and GetTime() - self.lastBuild < 5 then return end
    self.lastBuild = GetTime()
    local ok, items = pcall(self.Items, self)
    if not ok then items = {} end
    local empty = EMPTY:format(self.MIN_MOVE)
    if self.win then self.win:SetItems(items, empty) end
    if self.screen and self.screenFrame:IsShown() then self.screen:SetItems(items, empty) end
end

-- keep it fresh: after scans (RefreshUI) and every half minute
local ticker = CreateFrame("Frame")
ticker:RegisterEvent("PLAYER_LOGIN")
ticker:SetScript("OnEvent", function()
    C_Timer.After(3, function()
        PC:Safe("price ticker", function()
            Ticker:Apply()
            Ticker:Refresh(true)
        end)
    end)
    if C_Timer.NewTicker then
        C_Timer.NewTicker(Ticker.REFRESH, function() PC:Safe("price ticker", Ticker.Refresh, Ticker, true) end)
    end
end)
