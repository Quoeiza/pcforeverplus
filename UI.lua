-- ProfitCrafter: window (Auction House style, five tabs)
--   1 Recipes        profession categories + sortable profit list
--   2 Crafting plan  what to craft and the materials to buy
--   3 Scanned items  every recipe item and whether it was priced
--   4 Profit & loss  ProfitCrafter's trades, or all your gold, over time
--   5 History        every purchase and sale
-- Bottom-left: your gold, with an optional spending limit above it

local ADDON, ns = ...
local PC = ns.PC

local UI = {
    tab = 1,
    offset = 0,
    itemOffset = 0,
    category = "ALL",
    search = "",
    pnlRange = 7,
}
PC.UI = UI

local W, H = 966, 560             -- (with the page list: 1150 wide, room for every column of the Recipes table)
local PW = W - 24                  -- a page's panels and tables: 12 in from each side
local RW = PW - 8                  -- a table's rows: 4 in from the panel's edges
local HEAD_H = 30                  -- column headers: two lines of small lettering
local LIST_Y = -(HEAD_H + 6)       -- where a table's rows start, under its header and the line below it
local NAV_W = 184                 -- the page list down the left side (the clean look)
UI.navW = 0
local TICKER_H = 20                -- price ticker strip under the title bar; everything below sits this much lower
UI.TICKER_H = TICKER_H
local ROW_H = 26                   -- roomy rows with bigger icons
local ITEM_ROW_H = 18
local RECIPE_ROWS = 12
local SHOP_ROWS = 9
local ITEM_ROWS = 9
local RECENT_ROWS = 5
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local TAB_NAMES = { "Recipes", "Crafting plan", "Scanned items", "Profit & loss", "History", "Sell", "Settings", "Scout recipes" }
-- The tab strip down the right edge: short labels, in this order (Simple mode hides the "advanced" ones)
local TAB_STRIP = {
    { 2, "Plan", icon = "Interface\\Icons\\INV_Misc_Note_01" },
    { 1, "Recipes", icon = "Interface\\Icons\\INV_Scroll_03" },
    { 3, "Items", advanced = true, icon = "Interface\\Icons\\INV_Misc_Bag_08" },
    { 6, "Sell", advanced = true, icon = "Interface\\Icons\\INV_Misc_Coin_01" },
    { 8, "Learn", advanced = true, icon = "Interface\\Icons\\INV_Scroll_06" },
    { 4, "P&L", advanced = true, icon = "Interface\\Icons\\INV_Misc_Book_09" },
    { 5, "History", advanced = true, icon = "Interface\\Icons\\INV_Misc_PocketWatch_01" },
    { 7, "Settings", bottom = true, icon = "Interface\\Icons\\Trade_Engineering" },
}
-- tooltips for the side tabs
local TAB_TIPS = {
    [1] = "Every recipe you can craft in all your professions.", [2] = "Your crafting plan: what to buy, craft and sell.",
    [3] = "Prices for everything scanned.", [4] = "Profit & loss: what you made and spent.",
    [5] = "Every trade, newest first.", [6] = "Your crafted items for sale, Keep and Purge.", [7] = "Settings and automation.",
    [8] = "Recipes, patterns and plans you can get: where from, at what level, what they'd earn, and a trip to go get them.",
}
UI.TAB_STRIP = TAB_STRIP

-- Recipe name colors match skill-up chance: orange, yellow, green, gray
local DIFF_COLORS = { [0] = "ff8040", [1] = "ffff00", [2] = "40c040", [3] = "a0a0a0" }

local STATUS_TEXT = {
    [1] = "|cffff5555Not scanned|r",
    [2] = "|cffff8040Not at auction|r",
    [3] = "|cff40ff40Priced|r",
    [4] = "|cff40c0ffAuctionator|r",
}

---------------------------------------------------------------------------
-- Colors for panels, headers and rows
---------------------------------------------------------------------------
local THEMES = {
    retail = {
        -- the Auction House's own look: dark inner area, with the game's torn-paper edge round it
        bodyColor = { 61 / 255, 55 / 255, 48 / 255, 1 }, -- the AH's grey round its panes (measured)
        tearAtlas = nil,                                  -- flat AH grey, no torn-paper art
        insetAtlas = "auctionhouse-background-index",     -- the AH's own list background (dark, faint scratches)
        insetColor = { 37 / 255, 33 / 255, 30 / 255, 1 }, -- same colour, for clients without that art
        insetEdge = { 82 / 255, 76 / 255, 68 / 255, 1 },  -- the thin lighter edge round each pane
        ink = { 1, 0.82, 0 },                        -- gold text on the dark body (like the AH's labels)
        inkDim = { 0.65, 0.56, 0.4 },
        tanBg = { 0.33, 0.27, 0.19, 1 }, tanOn = { 0.62, 0.47, 0.22, 1 }, tanEdge = { 0.55, 0.42, 0.2, 1 },
        panelBg = "Interface\\Buttons\\WHITE8X8", panelBgColor = { 0.04, 0.035, 0.03, 0.92 },
        panelEdge = "Interface\\Tooltips\\UI-Tooltip-Border", panelEdgeSize = 12,
        panelBorder = { 0.55, 0.45, 0.28, 1 },
        header = { 0.2, 0.17, 0.12, 1 }, headerLine = { 1, 0.82, 0, 0.35 },
        catOn = { 0.24, 0.19, 0.12, 0.9 }, catOff = { 0.12, 0.1, 0.08, 0.6 },
        rowSel = { 0.15, 0.3, 0.5, 0.6 }, rowHover = { 0.2, 0.35, 0.55, 0.35 },
    },
    -- the clean look (the default): flat dark panels, thin edges, gold for what matters
    clean = {
        bodyColor = { 0.052, 0.048, 0.044, 0.985 },
        tearAtlas = false,
        insetAtlas = false,
        insetColor = { 0.052, 0.048, 0.044, 1 },       -- no boxes: tables sit straight on the window
        insetEdge = { 1, 1, 1, 0 },
        ink = { 1, 0.82, 0 },
        inkDim = { 0.62, 0.59, 0.54 },
        tanBg = { 0, 0, 0, 0 }, tanOn = { 0.91, 0.72, 0.29, 0.14 }, tanEdge = { 0.35, 0.3, 0.2, 1 },
        panelBg = "Interface\\Buttons\\WHITE8X8", panelBgColor = { 0.052, 0.048, 0.044, 1 },
        panelEdge = "Interface\\Buttons\\WHITE8X8", panelEdgeSize = 1,
        panelBorder = { 1, 1, 1, 0 },
        header = { 0.052, 0.048, 0.044, 1 }, headerLine = { 1, 1, 1, 0.10 },
        catOn = { 0.91, 0.72, 0.29, 0.18 }, catOff = { 0, 0, 0, 0 },
        rowSel = { 0.91, 0.72, 0.29, 0.14 }, rowHover = { 1, 1, 1, 0.05 },
        edge = { 0.91, 0.72, 0.29, 0.28 }, bar = { 0.052, 0.048, 0.044, 1 },
        nav = { 0.052, 0.048, 0.044, 1 }, navLine = { 1, 1, 1, 0.08 },
        button = { 0.17, 0.155, 0.13, 1 }, buttonHover = { 0.24, 0.215, 0.175, 1 }, buttonOff = { 0.105, 0.10, 0.092, 1 },
        buttonMain = { 0.93, 0.73, 0.27, 1 }, buttonMainHover = { 1, 0.82, 0.36, 1 },
    },
}
local T = THEMES.retail
UI.TAB_NAMES = TAB_NAMES
UI.W, UI.H = W, H


---------------------------------------------------------------------------
-- Small building blocks
---------------------------------------------------------------------------
local function HasTemplate(name)
    if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
        return C_XMLUtil.GetTemplateInfo(name) ~= nil
    end
    return false
end

UI.HasTemplate = HasTemplate

local function Text(parent, template, x, y, width, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", x, y)
    if width then fs:SetWidth(width) end
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end
UI.DIM = "|cffa08f66" -- dim tan for secondary text (reads on the dark AH body)
-- Dark-brown text for labels that sit on the parchment (not inside a dark panel)
function UI.Ink(fs, dim)
    if fs and fs.SetTextColor then
        if dim then fs:SetTextColor(unpack(T.inkDim)) else fs:SetTextColor(0.95, 0.92, 0.85) end
    end
    return fs
end

-- A green button (for "Make me gold")
function UI.GreenButton(parent, w, h, text)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w, h)
    if b.SetBackdrop then
        b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        b:SetBackdropColor(0.12, 0.45, 0.12, 1)
        b:SetBackdropBorderColor(0.85, 0.7, 0.25, 1)
    end
    local shine = b:CreateTexture(nil, "ARTWORK")
    shine:SetPoint("TOPLEFT", 3, -3); shine:SetPoint("TOPRIGHT", -3, -3)
    shine:SetHeight(math.floor(h / 2) - 2)
    shine:SetColorTexture(1, 1, 1, 0.08)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", 3, -3); hl:SetPoint("BOTTOMRIGHT", -3, 3)
    hl:SetColorTexture(0.6, 1, 0.6, 0.18)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("CENTER", 0, 0)
    fs:SetText(text or "")
    fs:SetTextColor(0.85, 1, 0.85)
    if b.SetFontString then b:SetFontString(fs) end
    b.text = fs
    b:SetScript("OnMouseDown", function() fs:SetPoint("CENTER", 1, -1) end)
    b:SetScript("OnMouseUp", function() fs:SetPoint("CENTER", 0, 0) end)
    return b
end

-- Button text that always stays inside the button: smaller font if it's long, cut off with "..." if still too long
function UI.FitText(btn, text)
    btn:SetText(text or "")
    local fs = btn.GetFontString and btn:GetFontString()
    if not fs then return end
    local maxW = math.max((btn:GetWidth() or 100) - 16, 20)
    if fs.SetFontObject then fs:SetFontObject(GameFontNormal) end
    local w = fs.GetStringWidth and fs:GetStringWidth() or 0
    if w > maxW and fs.SetFontObject then
        fs:SetFontObject(GameFontNormalSmall)
        w = fs.GetStringWidth and fs:GetStringWidth() or 0
    end
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    if fs.SetWidth then fs:SetWidth(maxW) end
end

-- Text vertically centered in a row
-- The profession window's own skill-up icons: orange (always a point), yellow (likely), green (a chance);
-- nothing for grey. Same art the game draws next to recipe names.
local SKILL_ATLAS = { [0] = "Professions-Icon-Skill-High", [1] = "Professions-Icon-Skill-Medium", [2] = "Professions-Icon-Skill-Low" }
local SKILL_TEXT = { [0] = "|cffff8040^|r", [1] = "|cffffff00^|r", [2] = "|cff40c040^|r" } -- if the art isn't in this client

local function HasAtlas(name)
    if C_Texture and C_Texture.GetAtlasInfo then
        local ok, info = pcall(C_Texture.GetAtlasInfo, name)
        return ok and info ~= nil
    end
    return false
end

local function SkillArrows(row, x)
    local t = row:CreateTexture(nil, "OVERLAY")
    t:SetSize(13, 13)
    t:SetPoint("LEFT", x, 0)
    t:Hide()
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", x + 2, 0)
    fs:Hide()
    row.skill, row.skillText = t, fs
end

local function SetSkillArrows(row, diff)
    local t, fs = row.skill, row.skillText
    if not t then return end
    t:Hide(); if fs then fs:Hide() end
    local atlas = SKILL_ATLAS[diff]
    if not atlas then return end
    if HasAtlas(atlas) and t.SetAtlas then
        t:SetAtlas(atlas)
        t:Show()
    elseif fs then
        fs:SetText(SKILL_TEXT[diff])
        fs:Show()
    end
end
UI.SetSkillArrows = SetSkillArrows

local function RowText(row, x, width, justify)
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", x, 0)
    fs:SetWidth(width)
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

-- How wide a font string's text is, whatever width the string is held to (GetStringWidth can stop there)
local function TextWidth(fs)
    return (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth()) or fs:GetStringWidth() or 0
end

-- A cell's text in the row's big lettering, or the small one when it wouldn't fit: money is never cut short
-- (a sum of money with gold in it, shortened: the copper left off, then the silver; the tooltips keep it exact)
local COPPER_PART = "%s*%d+|TInterface\\MoneyFrame\\UI%-CopperIcon[^|]*|t"
local SILVER_PART = "%s*%d+|TInterface\\MoneyFrame\\UI%-SilverIcon[^|]*|t"
local function Shorter(text, part)
    if not (text and text:find("UI%-GoldIcon")) then return nil end
    local s, n = text:gsub(part, "")
    return n > 0 and s or nil
end
local function FitCell(fs, text)
    fs:SetText(text or "")
    if not fs.bigFont then return end
    if fs.isSmall then fs:SetFontObject(fs.bigFont); fs.isSmall = false end
    local room = fs:GetWidth() or 0
    if TextWidth(fs) <= room then return end
    fs:SetFontObject("GameFontHighlightSmall"); fs.isSmall = true
    -- still too wide (a big sum): drop the copper, then the silver, rather than cut it off
    for _, part in ipairs({ COPPER_PART, SILVER_PART }) do
        if TextWidth(fs) <= room then return end
        local s = Shorter(fs:GetText(), part)
        if not s then return end
        fs:SetText(s)
    end
end

-- Dark inset box with a bronze border, like the Auction House lists
local function Panel(parent, x, y, w, h)
    local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    p:SetPoint("TOPLEFT", x, y)
    p:SetSize(w, h)
    if T.insetAtlas or T.insetColor then
        -- the AH's own pane: its list background art, a thin lighter edge
        local bg = p:CreateTexture(nil, "BACKGROUND", nil, -7)
        bg:SetPoint("TOPLEFT", 1, -1)
        bg:SetPoint("BOTTOMRIGHT", -1, 1)
        local ok = false
        if T.insetAtlas and bg.SetAtlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(T.insetAtlas) then
            ok = pcall(bg.SetAtlas, bg, T.insetAtlas, false)
        end
        if not ok then bg:SetColorTexture(unpack(T.insetColor)) end
        p.bg = bg
        if p.SetBackdrop then
            p:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
            p:SetBackdropBorderColor(unpack(T.insetEdge))
        end
        return p
    end
    if p.SetBackdrop then
        p:SetBackdrop({
            bgFile = T.panelBg,
            edgeFile = T.panelEdge,
            edgeSize = T.panelEdgeSize,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        p:SetBackdropColor(unpack(T.panelBgColor))
        p:SetBackdropBorderColor(unpack(T.panelBorder))
    end
    return p
end

-- A row of fixed-width totals (Sold / Bought / Fees / Net ...). Every value gets its own column so
-- nothing wraps or drifts; stacked = small label above the value. Hover shows exact amounts.
local function StatStrip(parent, x, y, width, labels, stacked)
    local strip = CreateFrame("Frame", nil, parent)
    strip:SetPoint("TOPLEFT", x, y)
    local cellW = math.floor(width / #labels)
    strip:SetSize(cellW * #labels, stacked and 30 or 16)
    strip.cells = {}
    for i, label in ipairs(labels) do
        local c = {}
        c.label = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        c.value = strip:CreateFontString(nil, "OVERLAY", stacked and "GameFontHighlight" or "GameFontHighlightSmall")
        c.label:SetText(label)
        c.label:SetTextColor(0.6, 0.6, 0.6)
        if label == "Net" then c.label:SetTextColor(1, 0.82, 0) end
        for _, fs in ipairs({ c.label, c.value }) do
            fs:SetWordWrap(false)
            if fs.SetNonSpaceWrap then fs:SetNonSpaceWrap(false) end
        end
        if stacked then
            c.label:SetPoint("TOPLEFT", (i - 1) * cellW, 0)
            c.label:SetWidth(cellW - 6)
            c.label:SetJustifyH("RIGHT")
            c.value:SetPoint("TOPLEFT", (i - 1) * cellW, -13)
            c.value:SetWidth(cellW - 6)
            c.value:SetJustifyH("RIGHT")
        else
            c.label:SetPoint("LEFT", strip, "LEFT", (i - 1) * cellW, 0)
            c.label:SetJustifyH("LEFT")
            c.value:SetPoint("LEFT", c.label, "RIGHT", 4, 0)
            c.value:SetJustifyH("LEFT")
        end
        strip.cells[i] = c
    end
    strip.exact = {}
    strip:EnableMouse(true)
    strip:SetScript("OnEnter", function(self)
        local lines = { "Totals" }
        for i, c in ipairs(self.cells) do
            if self.exact[i] then lines[#lines + 1] = c.label:GetText() .. ":  " .. self.exact[i] end
        end
        UI.ShowTooltip(self, lines)
    end)
    strip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    function strip:SetLabels(labels2)
        for i, c in ipairs(self.cells) do
            local l = labels2[i] or ""
            c.label:SetText(l)
            if l == "Net" then c.label:SetTextColor(1, 0.82, 0) else c.label:SetTextColor(0.6, 0.6, 0.6) end
        end
    end
    -- values: list of { shown text, exact text (tooltip) }
    function strip:Set(values)
        for i, c in ipairs(self.cells) do
            local v = values[i] or {}
            c.value:SetText(v[1] or "")
            if not stacked then
                -- the value gets what's left of its column after the label, so it never runs into the next one
                local used = (c.label.GetStringWidth and c.label:GetStringWidth()) or 40
                c.value:SetWidth(math.max(cellW - used - 10, 20))
            end
            self.exact[i] = v[2]
        end
    end
    return strip
end
UI.StatStrip = StatStrip

-- Dark header bar with a gold underline across the top of a panel
local function HeaderStrip(panel, width)
    local strip = panel:CreateTexture(nil, "ARTWORK")
    strip:SetPoint("TOPLEFT", 4, -4)
    strip:SetSize(width or RW, HEAD_H)
    strip:SetColorTexture(unpack(T.header))
    local line = panel:CreateTexture(nil, "ARTWORK", nil, 1)
    line:SetPoint("TOPLEFT", 4, -(4 + HEAD_H))
    line:SetSize(width or RW, 1)
    line:SetColorTexture(unpack(T.headerLine))
end

-- Short quality-rank tag shown after names: Q1, Q2, Q3...
local QUALITY_COLORS = { "c08040", "c0c0c0", "ffd100", "40c0ff", "ff80ff" }
-- The game's own quality gems (like in the AH and profession windows), falling back to Q1/Q2 text.
--   q = rank (1 = lowest), maxQ = how many ranks the item has, itemID = lets the game pick the icon itself
local function AtlasOK(a)
    return a and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(a) ~= nil
end
local gemCache = {}
function UI.QualityIcon(q, maxQ, itemID, size)
    if not q then return nil end
    size = size or 15
    local T = C_TradeSkillUI
    -- 1) ask the game for this item's quality icon
    if itemID and T then
        for _, fn in ipairs({ "GetItemReagentQualityInfo", "GetItemCraftedQualityInfo" }) do
            if T[fn] then
                local ok, info = pcall(T[fn], itemID)
                local atlas = ok and type(info) == "table" and (info.iconChat or info.iconSmall or info.iconInventory)
                if AtlasOK(atlas) then return ("|A:%s:%d:%d|a"):format(atlas, size, size) end
            end
        end
    end
    -- 2) the game's gem art by name
    if not maxQ and itemID then
        local e = PC:ExpansionOf(itemID)
        if e and e >= 11 then maxQ = 2 end -- Midnight and later use 2 qualities
    end
    local key = q .. ":" .. tostring(maxQ)
    if not gemCache[key] then
        local names
        if maxQ == 2 then
            names = { "Professions-ChatIcon-Quality-12-Tier" .. q, "Professions-Icon-Quality-12-Tier" .. q .. "-Small",
                "Professions-ChatIcon-Quality-Tier" .. (q + 1) } -- 2-rank items: silver, then gold
        else
            names = { "Professions-ChatIcon-Quality-Tier" .. q, "Professions-Icon-Quality-Tier" .. q .. "-Small" }
        end
        gemCache[key] = false
        for _, a in ipairs(names) do
            if AtlasOK(a) then gemCache[key] = a break end
        end
    end
    if gemCache[key] then return ("|A:%s:%d:%d|a"):format(gemCache[key], size, size) end
    return nil
end

function UI.QualityTag(q, maxQ, itemID)
    if not q then return "" end
    local icon = UI.QualityIcon(q, maxQ, itemID)
    if icon then return " " .. icon end
    return (" |cff%sQ%d|r"):format(QUALITY_COLORS[q] or "ffffff", q)
end

-- "Q2:" label for tooltips, as a gem when the game has the art
function UI.QualityLabel(q, maxQ, itemID)
    local icon = UI.QualityIcon(q, maxQ, itemID, 14)
    return icon or ("Q" .. q)
end

-- "today", "1 day ago"/"1d", "?" when unknown. Green = sold recently, yellow = this week, red = slow
function UI.DaysText(days, long)
    if days == nil then return "|cff888888?|r" end
    local color = (days <= 1 and "40ff40") or (days <= 7 and "ffff00") or "ff5555"
    local text
    if days == 0 then text = "today"
    elseif long then text = days .. (days == 1 and " day ago" or " days ago")
    else text = days .. "d" end
    return "|cff" .. color .. text .. "|r"
end

local ShowTooltip -- defined below; the column headers use it on hover

---------------------------------------------------------------------------
-- Sortable tables. Every table's column headers are the same: two lines high, the label word-wrapped
-- inside its column and right-aligned, the sort arrow in its own room just left of the label (never
-- over it). Click sorts by that column, click again reverses. Each table keeps its sort (PC.db.sorts).
---------------------------------------------------------------------------
-- where each table starts: names A-Z, numbers biggest first; nil = the order it comes in
UI.SORT_DEFAULTS = { recipes = { "profit", -1 }, plan = { "name", 1 }, items = { "status", 1 }, history = { "t", -1 }, recent = { "t", -1 } }
-- the scroll position that goes back to the top when a table's sort changes
local SORT_OFFSET = { recipes = "offset", plan = "planOffset", mats = "shopOffset", items = "itemOffset",
    sell = "sellOffset", learn = "learnOffset", history = "historyOffset" }
local SORT_MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"
local ARROW = 10

function UI:SortState(tbl)
    local all = PC.db and PC.db.sorts
    if PC.db and not all then all = {}; PC.db.sorts = all end
    all = all or {}
    local s = all[tbl]
    if not s then
        local d = self.SORT_DEFAULTS[tbl] or {}
        s = { key = d[1], dir = d[2] or -1 }
        all[tbl] = s
    end
    return s
end

function UI:SortBy(tbl, key, first)
    local s = self:SortState(tbl)
    if s.key == key then s.dir = -s.dir else s.key, s.dir = key, first or -1 end
    s.auto = nil -- picked by you (not by a Recipes category)
    if SORT_OFFSET[tbl] then self[SORT_OFFSET[tbl]] = 0 end
    self:Redraw()
end

-- Sort rows by one column: get(row, key) gives each row's value (worked out once per row). Rows with no
-- value always go last, ties go by name (nameOf), then by where they were.
function UI.SortRows(data, key, dir, get, nameOf)
    if not key then return data end
    local val, name, pos = {}, {}, {}
    for i, e in ipairs(data) do
        local v = get(e, key)
        if v ~= v then v = nil end -- (0/0 from a missing price: no value, or the sort would break)
        val[e], name[e], pos[e] = v, nameOf(e) or "", i
    end
    table.sort(data, function(a, b)
        local x, y = val[a], val[b]
        if x == nil or y == nil then
            if x ~= nil then return true end
            if y ~= nil then return false end
        elseif x ~= y then
            if dir > 0 then return x < y end
            return x > y
        end
        if name[a] ~= name[b] then return name[a] < name[b] end
        return pos[a] < pos[b]
    end)
    return data
end

local function Header(parent, x, w, label, key, desc, tbl, first)
    local b = CreateFrame("Button", nil, parent)
    b:SetPoint("TOPLEFT", x, -4)
    b:SetSize(w, HEAD_H)
    b.label, b.key, b.tbl, b.first = label, key, tbl, first
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPRIGHT", -4, 0)
    fs:SetPoint("BOTTOMRIGHT", -4, 0)
    fs:SetWidth(math.max(w - 8 - ARROW, 8)) -- the arrow's room (and a gap) stays clear on the left
    fs:SetJustifyH("RIGHT")
    if fs.SetJustifyV then fs:SetJustifyV("MIDDLE") end
    fs:SetWordWrap(true)
    if fs.SetNonSpaceWrap then fs:SetNonSpaceWrap(false) end
    if fs.SetMaxLines then fs:SetMaxLines(2) end
    fs:SetText(label or "")
    b.text = fs
    b.arrow = b:CreateTexture(nil, "OVERLAY")
    b.arrow:SetSize(ARROW, ARROW)
    b.arrow:Hide()
    b.active = b:CreateTexture(nil, "ARTWORK")
    b.active:SetPoint("BOTTOMLEFT", 2, 0)
    b.active:SetPoint("BOTTOMRIGHT", -2, 0)
    b.active:SetHeight(2)
    b.active:SetColorTexture(1, 0.82, 0, 0.9)
    b.active:Hide()
    if key then
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        b:SetScript("OnEnter", function(btn)
            local tip = { label }
            if desc then tip[#tip + 1] = desc end
            tip[#tip + 1] = "|cff888888Click to sort, click again to reverse.|r"
            ShowTooltip(btn, tip)
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:SetScript("OnClick", function(btn) UI:SortBy(btn.tbl, btn.key, btn.first) end)
    end
    return b
end

-- A table's columns, left to right: { key, label, width, tooltip, text = true (A-Z first) }. The one
-- column with no width takes the room the others leave; a column with no label is just room (buttons).
-- Makes the headers, and gives every column its x and width (cols.by[key] finds one).
local function Columns(panel, cols, tbl, width)
    local used = 0
    for _, c in ipairs(cols) do used = used + (c[3] or 0) end
    local x, heads = 0, {}
    cols.by = {}
    for _, c in ipairs(cols) do
        c.x, c.w = x, c[3] or ((width or RW) - used)
        x = x + c.w
        if c[1] then cols.by[c[1]] = c end
        if c[2] then heads[#heads + 1] = Header(panel, 4 + c.x, c.w, c[2], c[1], c[4], tbl, c.text and 1 or -1) end
    end
    return heads
end

-- Mark the column a table is sorted by: its arrow (just left of the label) and the gold line under it
function UI:PaintHeaders(heads, tbl)
    local s = self:SortState(tbl)
    for _, h in ipairs(heads or {}) do
        local on = h.key ~= nil and h.key == s.key
        if on then
            local fs = h.text
            local room, full = fs:GetWidth() or 0, TextWidth(fs)
            local lw = math.min(full, room)
            if full > room and fs.GetWrappedWidth then lw = math.min(fs:GetWrappedWidth() or room, room) end -- (two lines)
            h.arrow:ClearAllPoints()
            h.arrow:SetPoint("RIGHT", h, "RIGHT", -(4 + lw + 2), 0)
            h.arrow:SetTexture(SORT_MEDIA .. (s.dir > 0 and "SortUp" or "SortDown"))
            fs:SetTextColor(1, 1, 1)
        else
            h.text:SetTextColor(1, 0.82, 0)
        end
        h.arrow:SetShown(on)
        h.active:SetShown(on)
    end
end

local function Stripe(row, index)
    if index % 2 == 0 then
        local t = row:CreateTexture(nil, "BACKGROUND")
        t:SetAllPoints()
        t:SetColorTexture(1, 1, 1, 0.035)
    end
end

local function ItemIcon(itemID)
    if not itemID then return QUESTION end
    local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
    if not icon and GetItemIcon then icon = GetItemIcon(itemID) end
    return icon or QUESTION
end

local CLICK_HINT = "|cff888888Shift-click: search the Auction House   Right-click: craft it   Shift-right-click: link in chat|r"

-- Tooltip: the game's own item tooltip (when we know the item), then ProfitCrafter's lines
-- Which expansion an item comes from (the game's own names when it has them)
function UI.ExpansionName(itemID)
    return PC:ExpansionName(PC:ExpansionOf(itemID))
end

ShowTooltip = function(owner, lines, itemID, noWrap)
    if not lines and not itemID then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local start = 1
    if itemID and GameTooltip.SetItemByID then
        UI.ownTip = true -- our own tooltip adds the expansion and item ID at the bottom instead
        pcall(GameTooltip.SetItemByID, GameTooltip, itemID)
        UI.ownTip = false
        GameTooltip:AddLine(" ")
        start = 2 -- the item tooltip already shows the name
    end
    for n, line in ipairs(lines or {}) do
        if n >= start then
            if n == 1 then GameTooltip:SetText(line) else GameTooltip:AddLine(line, 1, 1, 1, not noWrap) end
        end
    end
    if itemID then
        GameTooltip:AddLine(" ")
        UI.AddItemInfoLines(GameTooltip, itemID)
        GameTooltip:AddLine(CLICK_HINT, 1, 1, 1, true)
    end
    GameTooltip:Show()
    UI.SolidTooltip(GameTooltip)
end
UI.ShowTooltip = function(...) return ShowTooltip(...) end

-- ProfitCrafter's tooltips get a nearly solid dark background so they're easy to read over the
-- rows behind them. The tooltip's normal look comes back as soon as it hides.
local SOLID = { 0.04, 0.035, 0.03, 0.97 }
function UI.SolidTooltip(tip)
    if not tip then return end
    -- A dark sheet UNDER the tooltip's own frame: it stays put even when the game (or another addon)
    -- repaints the tooltip, so the rows behind never show through. Hidden again when the tooltip closes.
    local sheet = tip.pcSheet
    if not sheet and tip.CreateTexture then
        sheet = tip:CreateTexture(nil, "BACKGROUND", nil, -8)
        sheet:SetPoint("TOPLEFT", 3, -3)
        sheet:SetPoint("BOTTOMRIGHT", -3, 3)
        sheet:SetColorTexture(unpack(SOLID))
        tip.pcSheet = sheet
        if tip.HookScript then
            tip:HookScript("OnHide", function(t) if t.pcSheet then t.pcSheet:Hide() end end)
        end
    end
    if sheet then sheet:Show() end
    -- also darken the tooltip's own center while it's ours
    local ns = tip.NineSlice
    if ns and ns.SetCenterColor and ns.GetCenterColor then
        if not tip.pcSaved then tip.pcSaved = { ns:GetCenterColor() } end
        ns:SetCenterColor(unpack(SOLID))
        if not tip.pcHooked and tip.HookScript then
            tip.pcHooked = true
            tip:HookScript("OnHide", function(t)
                local saved = t.pcSaved
                if saved and saved[1] and t.NineSlice and t.NineSlice.SetCenterColor then
                    t.NineSlice:SetCenterColor(unpack(saved))
                end
                t.pcSaved = nil
            end)
        end
    end
end

-- Open your profession window straight to a recipe
-- How far anything on the profession window (its side tabs) sticks out past its right edge
function UI:ProfessionTabsWidth(pf)
    local right = pf and pf.GetRight and pf:GetRight()
    if not right then return 58 end
    local out = 0
    local function look(frame, depth)
        if depth > 3 or not frame.GetChildren then return end
        for _, c in ipairs({ frame:GetChildren() }) do
            if c.IsShown and c:IsShown() and c.GetRight then
                -- only the tab buttons themselves: small and square-ish, poking out past the edge
                -- a tab: a small square-ish button that STARTS at the window's edge and hangs past it
                -- (not a bigger panel that happens to poke out a bit, which made the gap too wide)
                local r, w, h = c:GetRight(), c.GetWidth and c:GetWidth() or 0, c.GetHeight and c:GetHeight() or 0
                local l = c.GetLeft and c:GetLeft()
                local tabLike = w >= 16 and w <= 70 and h >= 16 and h <= 70 and l and l >= right - 15
                if r and tabLike and r - right > out and r - right < 90 then out = r - right end
            end
            look(c, depth + 1)
        end
    end
    pcall(look, pf, 0)
    if out <= 0 then out = 50 end -- couldn't tell: the usual width of the profession tabs
    return math.ceil(out)
end

-- After opening a profession, move ProfitCrafter right next to the profession window
function UI:DockBesideProfessions(tries)
    tries = tries or 0
    local pf = ProfessionsFrame or TradeSkillFrame
    local f = self.f
    if not f then return end
    if not (pf and pf:IsShown()) then
        if tries < 6 then C_Timer.After(0.25, function() UI:DockBesideProfessions(tries + 1) end) end
        return
    end
    self.docked = false
    f:ClearAllPoints()
    -- the profession window's side tabs hang off its right edge: dock past them so they stay usable
    -- measured in the profession window's scale; our window may be scaled differently, so convert
    local tabs = UI:ProfessionTabsWidth(pf)
    local pfS = pf.GetEffectiveScale and pf:GetEffectiveScale() or 1
    local fS = f.GetEffectiveScale and f:GetEffectiveScale() or 1
    if not pfS or pfS <= 0 then pfS = 1 end
    if not fS or fS <= 0 then fS = 1 end
    -- half the old gap: just clear of the tabs
    f:SetPoint("TOPLEFT", pf, "TOPRIGHT", math.floor(tabs * pfS / fS + 0.5) + 2, 0)
    f:Show()
    self.besideProf = true
    if not pf.pcHooked and pf.HookScript then
        pf.pcHooked = true
        -- profession window closed: ProfitCrafter goes back to the middle of the screen
        pf:HookScript("OnHide", function()
            if UI.autoProf and UI.f and not UI.docked then
                UI.autoProf, UI.besideProf = false, false
                UI.f:Hide()
                return
            end
            if UI.besideProf and UI.f then
                UI.besideProf = false
                if not UI.docked then
                    UI.f:ClearAllPoints()
                    UI.f:SetPoint("CENTER")
                end
            end
        end)
    end
end

-- Profession window opened: ProfitCrafter opens beside it on the plan (setting), and closes with it
function UI:OnProfessionShow()
    -- first time: borrow the profession window's own background so the two match
    -- (no automatic skin from the profession window any more: the AH's own grey look is the default; /pc skin still does it)
    if (self.docked and self.f and self.f:IsShown()) then return end
    if self.f and self.f:IsShown() and self.besideProf then return end
    -- off by default: the Next step bar does the work; the window opens when you ask for it
    -- (or when a step needs it). Already open: just line it up beside the profession window.
    if PC.db.dockProf ~= true and not (self.f and self.f:IsShown()) then return end
    self:Create()
    local wasShown = self.f:IsShown()
    self:DockBesideProfessions()
    if not wasShown then
        self.autoProf = true
        self:ShowTab(2)
    end
end

function UI:OpenRecipe(recipeID, r)
    local T = C_TradeSkillUI
    if InCombatLockdown and InCombatLockdown() then
        PC.Print("Can't open professions in combat.")
        return
    end
    if not (T and recipeID) then return end
    -- the AH (or a vendor, mailbox, bank) in the way: close it first so the profession window
    -- opens cleanly and ProfitCrafter lines up beside it
    if PC.ahOpen and CloseAuctionHouse then pcall(CloseAuctionHouse) end
    if PC.merchantOpen and CloseMerchant then pcall(CloseMerchant) end
    if MailFrame and MailFrame:IsShown() and CloseMail then pcall(CloseMail) end
    if PC.Bank and PC.Bank:Open() and CloseBankFrame then pcall(CloseBankFrame) end
    -- 1) the game's own "open this recipe" (opens the profession and selects it)
    local quiet = PC.Craft and PC.Craft.quick -- crafting from the button: no windows popping up
    if T.OpenRecipe and pcall(T.OpenRecipe, recipeID) then
        if not quiet and self.f and self.f:IsShown() then self:DockBesideProfessions() end
        return true
    end
    -- 2) open the profession, then select the recipe once its window is up
    local skillLine
    if T.GetTradeSkillLineForRecipe then
        local ok, sl = pcall(T.GetTradeSkillLineForRecipe, recipeID)
        if ok then skillLine = sl end
    end
    if T.OpenTradeSkill and skillLine and pcall(T.OpenTradeSkill, skillLine) then
        C_Timer.After(0.3, function()
            local pf = ProfessionsFrame
            if pf and pf.SetToRecipe then pcall(pf.SetToRecipe, pf, recipeID) end
            if pf and pf.CraftingPage and pf.CraftingPage.SelectRecipe then
                local info = T.GetRecipeInfo and T.GetRecipeInfo(recipeID)
                if info then pcall(pf.CraftingPage.SelectRecipe, pf.CraftingPage, info) end
            end
            if not quiet and UI.f and UI.f:IsShown() then UI:DockBesideProfessions() end
        end)
        return true
    end
    PC.Print(("Open your %s window to craft %s."):format(r and r.prof or "profession", r and r.name or "it"))
end

local CRAFT_ICON = "Interface\\Icons\\Trade_BlackSmithing"

-- Small clickable icon that opens the profession window to a recipe
local function CraftButton(parent, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b.tex = b:CreateTexture(nil, "ARTWORK")
    b.tex:SetAllPoints()
    b.tex:SetTexture(CRAFT_ICON)
    b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.25)
    b:SetScript("OnClick", function(btn)
        if btn.recipeID then PC:Safe("open recipe", UI.OpenRecipe, UI, btn.recipeID, btn.recipe) end
    end)
    b:SetScript("OnEnter", function(btn)
        if not btn.recipe then return end
        ShowTooltip(btn, { "Craft it", ("Opens %s to %s."):format(btn.recipe.prof or "your profession", btn.recipe.name) })
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end
UI.CraftButton = CraftButton

-- Small clickable bag icon: add a recipe to the crafting plan (asks how many)
local function ShopButton(parent, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b.tex = b:CreateTexture(nil, "ARTWORK")
    b.tex:SetAllPoints()
    b.tex:SetTexture("Interface\\Icons\\INV_Misc_Bag_08")
    b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.25)
    b:SetScript("OnClick", function(btn)
        PC:Safe("crafting plan", function()
            local entries = btn.getEntries and btn.getEntries() or {}
            if entries[1] then UI:ShowQtyPopup(entries[1], btn) end
        end)
    end)
    b:SetScript("OnEnter", function(btn)
        ShowTooltip(btn, { "Add to crafting plan", "Pick how many to craft. Everything in your plan is shopped for together." })
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end
UI.ShopButton = ShopButton

-- Quick Buy: the crafts that make your minimum profit go in the plan, the main AH material is bought
-- in the same click, and the plan opens for the rest
local function QuickButton(parent, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b.tex = b:CreateTexture(nil, "ARTWORK")
    b.tex:SetAllPoints()
    b.tex:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
    b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.25)
    b:SetScript("OnClick", function(btn)
        local e = btn.getEntry and btn.getEntry()
        if e then PC:Safe("quick buy", UI.QuickBuy, UI, e) end
    end)
    b:SetScript("OnEnter", function(btn)
        ShowTooltip(btn, { "Quick Buy", ("Plans as many crafts as clear your %d%% minimum profit (within your gold and bags), buys the main auction material and opens the plan. Buy the other materials there."):format(PC:MinProfitPct()),
            "|cff888888Nothing is bought if the price no longer pays.|r" })
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end
UI.QuickButton = QuickButton


-- A clickable item link for an item ID
function UI:ItemLink(itemID)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local link = getInfo and select(2, getInfo(itemID))
    if link then return link end
    if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
    return ("|cffffffff|Hitem:%d::::::::::::|h[%s]|h|r"):format(itemID, PC:ItemName(itemID))
end

local function ActiveChatBox()
    if ChatEdit_GetActiveWindow then return ChatEdit_GetActiveWindow() end
    if ChatFrameUtil and ChatFrameUtil.GetActiveWindow then return ChatFrameUtil.GetActiveWindow() end
end

local function InsertIntoChat(link)
    if ChatEdit_InsertLink and ChatEdit_InsertLink(link) then return true end
    if ChatFrameUtil and ChatFrameUtil.InsertLink and ChatFrameUtil.InsertLink(link) then return true end
    local box = ActiveChatBox()
    if box and box.Insert then box:Insert(link) return true end
    return false
end

-- Search the Auction House for exactly this item (switches the AH to its Buy page first)
function UI:SearchAH(itemID)
    local ah = AuctionHouseFrame
    if not PC.ahOpen or not ah then
        PC.Print("Open the Auction House to search for " .. PC:ItemName(itemID) .. ".")
        return false
    end
    local name = PC:ItemName(itemID)
    if ah.SetDisplayMode and AuctionHouseFrameDisplayMode and AuctionHouseFrameDisplayMode.Buy then
        pcall(ah.SetDisplayMode, ah, AuctionHouseFrameDisplayMode.Buy)
    end
    local bar = ah.SearchBar
    local text = '"' .. name .. '"' -- quotes = exact match
    if bar and bar.SetSearchText then
        bar:SetSearchText(text)
    elseif bar and bar.SearchBox then
        bar.SearchBox:SetText(text)
    end
    if bar and bar.StartSearch then
        bar:StartSearch()
    elseif C_AuctionHouse and C_AuctionHouse.SendSearchQuery and C_AuctionHouse.MakeItemKey then
        C_AuctionHouse.SendSearchQuery(C_AuctionHouse.MakeItemKey(itemID), {}, true)
    end
    return true
end

-- Shared click handling for item rows. Returns true when the click did something.
--   Shift-click:       search the AH for it
--   Right-click:       open the profession window to the recipe that makes it
--   Shift-right-click: link it in chat
--   Ctrl-click:        the game's usual action (e.g. preview in the dressing room)
function UI:ClickItem(itemID, button)
    if not itemID then return false end
    local shift = IsShiftKeyDown and IsShiftKeyDown()
    if button == "RightButton" then
        if shift then
            local link = self:ItemLink(itemID)
            if ActiveChatBox() and InsertIntoChat(link) then return true end
            if ChatFrame_OpenChat then ChatFrame_OpenChat(link) return true end
            return InsertIntoChat(link)
        end
        local recipeID, r = PC:RecipeFor(itemID)
        if recipeID then
            self:OpenRecipe(recipeID, r)
        else
            PC.Print(("You don't know a recipe that makes %s."):format(PC:ItemName(itemID) or "that"))
        end
        return true
    end
    if shift then return self:SearchAH(itemID) end
    if IsAltKeyDown and IsAltKeyDown() and PC.Alerts then PC.Alerts:Ask(itemID) return true end
    if IsControlKeyDown and IsControlKeyDown() and HandleModifiedItemClick then
        return HandleModifiedItemClick(self:ItemLink(itemID)) and true or false
    end
    return false
end

---------------------------------------------------------------------------
-- Main frame
---------------------------------------------------------------------------
function UI:IsClean() return not (PC.db and PC.db.look == "classic") end

function UI:Create()
    if self.f then return end
    local NAV = 0
    if self:IsClean() then
        for k, v in pairs(THEMES.clean) do T[k] = v end
        NAV = NAV_W
    end
    self.navW = NAV
    UI.W = W + NAV
    -- the Recipes list opens on All professions: a sort Best bets or Vendor flips picked doesn't carry over
    local rs = self:SortState("recipes")
    if rs.auto then rs.key, rs.dir, rs.auto = "profit", -1, nil end

    local usePortrait = HasTemplate("PortraitFrameTemplate")
    local f = CreateFrame("Frame", "ProfitCrafterFrame", UIParent,
        usePortrait and "PortraitFrameTemplate" or "BasicFrameTemplateWithInset")
    self.f = f
    f:SetSize(W + NAV, H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(fr) if not UI.docked then fr:StartMoving() end end)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetScript("OnHide", function() if UI.OnWindowHidden then UI:OnWindowHidden() end end)
    f:SetScript("OnShow", function()
        -- opening ProfitCrafter lets the Task Button show outside a city (a plan you closed with the X stays closed)
        if PC.Next then PC.Next.wanted = true; PC:Safe("Task Button", PC.Next.UpdateBar, PC.Next) end
        UI:Refresh()
        if PC.Share then PC.Share:Request() end -- ask guild/group for newer prices
    end)
    f:Hide()
    tinsert(UISpecialFrames, "ProfitCrafterFrame") -- Esc closes it

    -- The Auction House's own background: dark body with the torn-paper edges, same colors as the AH beside it
    local bg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetPoint("TOPLEFT", 2, -21)
    bg:SetPoint("BOTTOMRIGHT", -2, 2)
    local usedAtlas = false
    if T.tearAtlas and bg.SetAtlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(T.tearAtlas) then
        usedAtlas = pcall(bg.SetAtlas, bg, T.tearAtlas, false) -- stretched to fit, like the AH does
    end
    if not usedAtlas then
        -- older clients: the AH's flat background color (no paper tears available)
        bg:SetColorTexture(unpack(T.bodyColor))
    end
    f.parchment = bg
    C_Timer.After(0, function() UI:ApplySkin() end)

    local title = PC.NAME .. " |cff888888v" .. PC.VERSION .. "|r"
    if f.SetTitle then
        f:SetTitle(title)
    else
        local t = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        t:SetPoint("TOP", 0, -5)
        t:SetText(title)
    end
    self.usePortrait = usePortrait
    self:ApplyIcon()

    -- Top row: search, "Only profitable", status / progress bar
    local left = NAV > 0 and (NAV + 8) or (usePortrait and 64 or 14)

    local search = CreateFrame("EditBox", nil, f,
        HasTemplate("SearchBoxTemplate") and "SearchBoxTemplate" or "InputBoxTemplate")
    search:SetSize(220, 22)
    search:SetPoint("TOPLEFT", left + 6, -32 - TICKER_H)
    search:SetAutoFocus(false)
    if search.Instructions then search.Instructions:SetText("Search recipes") end
    search:HookScript("OnTextChanged", function(sb)
        UI.search = strtrim((sb:GetText() or ""):lower())
        UI.offset = 0
        UI:Redraw()
    end)
    search:HookScript("OnEnterPressed", search.ClearFocus)
    f.search = search

    local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetPoint("LEFT", search, "RIGHT", 14, 0)
    cb:SetScript("OnClick", function(btn)
        PC.db.onlyProfit = btn:GetChecked() and true or false
        UI.offset = 0
        UI:Redraw()
    end)
    cb:SetScript("OnEnter", function(btn)
        ShowTooltip(btn, { btn.label or "Only Auction profit", ("Only recipes making at least %s%% Auction Profit, after the 5%% auction cut."):format(PC:MinProfitPct()),
            "With Vendor profit ticked too, a recipe must meet both. Ignored in Best bets and Vendor flips. Set the minimum in Settings." })
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local cbText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cbText:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cbText:SetText("Only Auction profit"); UI.Ink(cbText) -- (shows the minimum once the window draws)
    f.onlyProfit, f.onlyProfitText = cb, cbText

    -- the same for V Profit (what a vendor pays you, less the materials)
    local cbV = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    cbV:SetSize(22, 22)
    cbV:SetPoint("LEFT", cbText, "RIGHT", 10, 0)
    cbV:SetScript("OnClick", function(btn)
        PC.db.onlyVProfit = btn:GetChecked() and true or false
        UI.offset = 0
        UI:Redraw()
    end)
    cbV:SetScript("OnEnter", function(btn)
        ShowTooltip(btn, { btn.label or "Only Vendor profit", ("Only recipes making at least %s%% Vendor Profit, selling to a vendor."):format(PC:MinProfitPct()),
            "With Auction profit ticked too, a recipe must meet both. Ignored in Best bets. Set the minimum in Settings." })
    end)
    cbV:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local cbVText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cbVText:SetPoint("LEFT", cbV, "RIGHT", 2, 0)
    cbVText:SetText("Only Vendor profit"); UI.Ink(cbVText)
    f.onlyVProfit, f.onlyVProfitText = cbV, cbVText

    -- Only recipes your gold (or the amount you set on Levels & gold) can pay the materials for
    local cb2 = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    cb2:SetSize(22, 22)
    cb2:SetPoint("LEFT", cbVText, "RIGHT", 10, 0)
    cb2:SetScript("OnClick", function(btn)
        PC.db.onlyAffordable = btn:GetChecked() and true or false
        UI.offset = 0
        UI:Redraw()
    end)
    cb2:SetScript("OnEnter", function(btn)
        ShowTooltip(btn, { "Can afford", "Only show recipes whose materials you can pay for right now (one craft),",
            "counting what's already in your bags. Uses your spending limit if you set one." })
    end)
    cb2:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local cb2Text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cb2Text:SetPoint("LEFT", cb2, "RIGHT", 2, 0)
    cb2Text:SetText("Can afford"); UI.Ink(cb2Text)
    f.onlyAfford = cb2

    f.status = UI.Ink(Text(f, "GameFontHighlightSmall", W - 12 - 300 + NAV, -37 - TICKER_H, 300, "RIGHT"), true)

    local bar = CreateFrame("StatusBar", nil, f)
    bar:SetPoint("TOPLEFT", W - 12 - 300 + NAV, -33 - TICKER_H)
    bar:SetSize(300, 18)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetMinMaxValues(0, 1)
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetColorTexture(0, 0, 0, 0.7)
    bar.border = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    bar.border:SetPoint("TOPLEFT", -2, 2)
    bar.border:SetPoint("BOTTOMRIGHT", 2, -2)
    if bar.border.SetBackdrop then
        bar.border:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10 })
        bar.border:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    end
    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("CENTER")
    bar:Hide()
    f.bar = bar

    -- Footer: gold bottom-left, buttons bottom-right
    f.money = UI.Ink(f:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
    f.money:SetPoint("BOTTOMLEFT", 16 + NAV, 14)

    -- Spending limit, just above your gold: the most ProfitCrafter plans to spend (blank = all your gold)
    local lim = CreateFrame("Frame", nil, f)
    lim:SetSize(260, 20)
    lim:SetPoint("BOTTOMLEFT", 14 + NAV, 32)
    lim.label = UI.Ink(lim:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
    lim.label:SetText("Spending limit") -- placed after the boxes (below)
    -- gold, silver and copper boxes, like the game's own money input
    local COIN = { "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t", "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t",
        "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t" }
    local WIDTH, LETTERS = { 60, 34, 34 }, { 6, 2, 2 } -- room for every digit plus the padding
    lim.boxes = {}
    -- the boxes first, right above your gold; then the label and the note
    local anchor, rel, gap = lim, "LEFT", 6
    for i = 1, 3 do
        local b = CreateFrame("EditBox", nil, lim, "InputBoxTemplate")
        b:SetSize(WIDTH[i], 18)
        b:SetPoint("LEFT", anchor, rel, gap, 0)
        b:SetAutoFocus(false)
        b:SetNumeric(true)
        b:SetMaxLetters(LETTERS[i])
        b:SetJustifyH("RIGHT")
        -- padding inside the box: digits and cursor stay inside the frame, off its edge
        if b.SetTextInsets then b:SetTextInsets(0, 6, 0, 0) end
        local c = lim:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        c:SetPoint("LEFT", b, "RIGHT", 1, 0)
        c:SetText(COIN[i])
        lim.boxes[i] = b
        anchor, rel, gap = c, "RIGHT", 8
        lim.coin = c
    end
    lim:SetWidth(330)
    lim.label:SetPoint("LEFT", lim.coin, "RIGHT", 10, 0)
    lim.note = UI.Ink(lim:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), true)
    lim.note:SetPoint("LEFT", lim.label, "RIGHT", 6, 0)
    local function apply(box)
        local g = tonumber(lim.boxes[1]:GetText() or "") or 0
        local sv = math.min(tonumber(lim.boxes[2]:GetText() or "") or 0, 99)
        local c = math.min(tonumber(lim.boxes[3]:GetText() or "") or 0, 99)
        local total = g * 10000 + sv * 100 + c
        -- never more than the gold you have
        local have = GetMoney and GetMoney() or total
        if total > have then
            total = have
            PC.Print(("Spending limit set to %s: that's all the gold you have."):format(PC:Money(have)))
        end
        local new = total > 0 and total or nil
        if new ~= PC.cdb.overrides.gold then
            PC:SetSpendingLimit(new)
            UI:WarnPlanBudget()
        end
        if box then box:ClearFocus() end
        UI:Refresh()
    end
    for i, b in ipairs(lim.boxes) do
        b:SetScript("OnEnterPressed", apply)
        b:SetScript("OnTabPressed", function() lim.boxes[i % 3 + 1]:SetFocus() end) -- Tab: gold -> silver -> copper
        b:SetScript("OnEditFocusLost", function(box)
            if UI.limitSkip then return end
            -- moving between the three boxes isn't "done" yet
            C_Timer.After(0, function()
                for _, o in ipairs(lim.boxes) do if o.HasFocus and o:HasFocus() then return end end
                apply(nil)
            end)
        end)
        b:SetScript("OnEscapePressed", function(box)
            UI.limitSkip = true; box:ClearFocus(); UI.limitSkip = nil
            UI:UpdateLimit(true)
        end)
    end
    local eb = lim.boxes[1]
    local function tip(owner)
        ShowTooltip(owner, { "Spending limit",
            "The most gold ProfitCrafter plans with: \"Can afford\", Have materials and buying from",
            "the Crafting plan stay inside it.",
            "Crafting plans can't grow past it, and you're warned if a plan already costs more.",
            "Leave it blank to use all your gold. It never goes above the gold you really have." })
    end
    for _, b in ipairs(lim.boxes) do
        b:SetScript("OnEnter", tip)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    lim:EnableMouse(true)
    lim:SetScript("OnEnter", tip)
    lim:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.limit = lim

    local scan = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    scan:SetSize(120, 22)
    scan:SetPoint("BOTTOMRIGHT", -10, 9)
    scan:SetText("Scan auctions")
    scan:SetScript("OnClick", function() PC:StartScan() end)
    f.scanBtn = scan

    local second = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    second:SetSize(130, 22)
    second:SetPoint("RIGHT", scan, "LEFT", -6, 0)
    second:SetScript("OnClick", function()
        UI:ShowTab(UI.tab == 1 and 2 or 1)
    end)
    f.secondBtn = second

    -- Pages
    self.pages = {}
    for i = 1, #TAB_NAMES do
        local p = CreateFrame("Frame", nil, f)
        p:SetPoint("TOPLEFT", NAV, -TICKER_H) -- pages start below the ticker, right of the page list
        p:SetPoint("BOTTOMRIGHT", 0, 0)
        p:Hide()
        self.pages[i] = p
    end
    -- each part is built on its own: if one fails, the rest still work (and the error shows in chat)
    PC:Safe("Recipes tab", self.CreateRecipesPage, self, self.pages[1])
    PC:Safe("Crafting plan tab", self.CreateShoppingPage, self, self.pages[2])
    PC:Safe("Scanned items tab", self.CreateItemsPage, self, self.pages[3])
    PC:Safe("Profit & loss tab", self.CreatePnLPage, self, self.pages[4])
    PC:Safe("History tab", self.CreateHistoryPage, self, self.pages[5])
    PC:Safe("Sell tab", self.CreateSellPage, self, self.pages[6])
    PC:Safe("Settings tab", self.CreateSettingsTab, self, self.pages[7])
    PC:Safe("Recipes to get tab", self.CreateLearnPage, self, self.pages[8])

    -- price ticker under the title bar (Ticker.lua)
    if PC.Ticker then PC:Safe("price ticker", PC.Ticker.CreateWindowTicker, PC.Ticker, f) end

    PC:Safe("tabs", self.CreateTabs, self)
    if self:IsClean() then PC:Safe("clean look", self.CleanChrome, self, f) end
    if not (self.tab and self.pages[self.tab]) then self.tab = 1 end
    PC:Safe("tabs", self.ShowTab, self, self.tab)
    PC:Safe("text size", self.ApplyTextSize, self)
end

---------------------------------------------------------------------------
-- The clean look: our own flat frame instead of the game's window art
---------------------------------------------------------------------------
local function Fill(owner, layer, sub, color)
    local t = owner:CreateTexture(nil, layer, nil, sub)
    t:SetColorTexture(unpack(color))
    return t
end

-- a one-pixel edge round a frame
local function Edge(owner, color, layer, inset)
    inset = inset or 0
    local e = {}
    for i, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local t = Fill(owner, layer or "BORDER", 7, color)
        if side == "TOP" or side == "BOTTOM" then
            t:SetHeight(1)
            t:SetPoint(side .. "LEFT", inset, side == "TOP" and -inset or inset)
            t:SetPoint(side .. "RIGHT", -inset, side == "TOP" and -inset or inset)
        else
            t:SetWidth(1)
            t:SetPoint("TOP" .. side, side == "LEFT" and inset or -inset, -inset)
            t:SetPoint("BOTTOM" .. side, side == "LEFT" and inset or -inset, inset)
        end
        e[i] = t
    end
    return e
end
UI.Edge = Edge

-- a plain square-cornered block of colour (buttons, highlights)
-- the little gold arrow that marks a pull-down
UI.DROP = "  |TInterface\\AddOns\\" .. ADDON .. "\\Media\\SortDown:10:10:0:-1|t"
local function Pill(owner, layer, sub, color)
    local m = owner:CreateTexture(nil, layer, nil, sub)
    m:SetAllPoints()
    local pill = {}
    function pill:SetColor(cr, cg, cb, ca) m:SetColorTexture(cr, cg, cb, ca or 1) end
    function pill:SetShown(on) m:SetShown(on) end
    pill:SetColor(unpack(color))
    return pill
end
UI.Pill = Pill

-- dark lettering for the gold buttons
local darkFont
local function DarkFont()
    if not darkFont then
        darkFont = CreateFont("ProfitCrafterDarkFont")
        darkFont:CopyFontObject(GameFontNormal)
        darkFont:SetTextColor(0.13, 0.09, 0.02)
        if darkFont.SetShadowOffset then darkFont:SetShadowOffset(0, 0) end
    end
    return darkFont
end
UI.DarkFont = DarkFont

-- a flat square button: dark with gold lettering, or (main) gold with dark lettering; all the same height
function UI.FlatButton(b, main)
    if not b or b.flat then return end
    for _, k in ipairs({ "Left", "Middle", "Right", "LeftSeparator", "RightSeparator" }) do
        if b[k] and b[k].SetAlpha then b[k]:SetAlpha(0) end
    end
    for _, get in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture", "GetHighlightTexture" }) do
        local t = b[get] and b[get](b)
        if t and t.SetAlpha then t:SetAlpha(0) end
    end
    local base, hover = T.button, T.buttonHover
    b.flat = Pill(b, "BACKGROUND", 1, base)
    local h = b.GetHeight and b:GetHeight() or 0
    if h > 0 and h < 25 then b:SetHeight(25) end
    local fs = b.GetFontString and b:GetFontString()
    if fs and fs.SetTextColor then fs:SetTextColor(1, 0.86, 0.42) end
    if main then b.mainEdge = Edge(b, T.buttonMain, "BORDER") end -- the main button: a gold edge
    local function paint(self, over)
        if self.IsEnabled and not self:IsEnabled() then self.flat:SetColor(unpack(T.buttonOff))
        else self.flat:SetColor(unpack(over and hover or base)) end
    end
    b:HookScript("OnEnter", function(self) paint(self, true) end)
    b:HookScript("OnLeave", function(self) paint(self, false) end)
    b:HookScript("OnEnable", function(self) paint(self, false) end)
    b:HookScript("OnDisable", function(self) paint(self, false) end)
    paint(b, false)
end

-- every game-style button under a frame gets the flat look
function UI:FlattenButtons(frame, depth)
    depth = depth or 0
    if not frame or depth > 8 or not frame.GetChildren then return end
    for _, c in ipairs({ frame:GetChildren() }) do
        local ok, kind = pcall(c.GetObjectType, c)
        if ok and kind == "Button" and c.Left and c.Middle and c.Right then UI.FlatButton(c) end
        self:FlattenButtons(c, depth + 1)
    end
end

function UI:CleanChrome(f)
    -- the game's window art goes
    -- (the round logo in the corner stays)
    for _, k in ipairs({ "NineSlice", "Bg", "TopTileStreaks", "TitleBg", "Inset", "InsetBg" }) do
        local r = f[k]
        if r and r.Hide then r:Hide() end
    end
    if f.CloseButton then f.CloseButton:Hide() end
    -- one dark body, edge to edge, with a thin gold edge
    if f.parchment then
        f.parchment:ClearAllPoints()
        f.parchment:SetPoint("TOPLEFT", 0, 0)
        f.parchment:SetPoint("BOTTOMRIGHT", 0, 0)
        f.parchment:SetColorTexture(unpack(T.bodyColor))
    end
    Edge(f, T.edge, "BORDER")
    -- title bar
    local bar = Fill(f, "BACKGROUND", 2, T.bar)
    bar:SetPoint("TOPLEFT", 1, -1); bar:SetPoint("TOPRIGHT", -1, -1); bar:SetHeight(21)
    local line = Fill(f, "BORDER", 2, T.insetEdge)
    line:SetPoint("TOPLEFT", bar, "BOTTOMLEFT"); line:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT"); line:SetHeight(1)
    local pc = f.PortraitContainer or f.portrait
    if pc and pc.SetFrameLevel then pc:SetFrameLevel(f:GetFrameLevel() + 20) end -- the round logo above our title bar
    local tt = f.TitleContainer and f.TitleContainer.TitleText or f.TitleText
    if tt then
        tt:ClearAllPoints()
        tt:SetPoint("TOP", f, "TOP", 0, -5)   -- centered along the top of the window
        tt:SetJustifyH("CENTER")
        tt:SetTextColor(0.95, 0.75, 0.3)
    end
    -- our own close button: a plain x
    local x = CreateFrame("Button", nil, f)
    x:SetSize(22, 22)
    x:SetPoint("TOPRIGHT", -3, 0)
    x.text = x:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    x.text:SetPoint("CENTER", 0, 1)
    x.text:SetText("x")
    x.text:SetTextColor(0.72, 0.66, 0.55)
    x:SetScript("OnEnter", function(b) b.text:SetTextColor(1, 0.82, 0) end)
    x:SetScript("OnLeave", function(b) b.text:SetTextColor(0.72, 0.66, 0.55) end)
    x:SetScript("OnClick", function() f:Hide() end)
    f.cleanClose = x
    -- beside it, a small "i": this version's release notes
    local info = CreateFrame("Button", nil, f)
    info:SetSize(16, 16)
    info:SetPoint("RIGHT", x, "LEFT", -4, 1)
    info.icon = info:CreateTexture(nil, "ARTWORK")
    info.icon:SetAllPoints()
    info.icon:SetTexture("Interface\\FriendsFrame\\InformationIcon")
    info.icon:SetVertexColor(0.85, 0.78, 0.6)
    info:SetScript("OnEnter", function(b) b.icon:SetVertexColor(1, 0.82, 0) end)
    info:SetScript("OnLeave", function(b) b.icon:SetVertexColor(0.85, 0.78, 0.6) end)
    info:SetScript("OnClick", function() if PC.News then PC.News:Present() end end)
    f.cleanInfo = info
    -- the round logo gets its own gold ring
    local port = pc and (pc.portrait or (pc.GetRegions and pc:GetRegions())) or f.portrait
    if port then
        -- on its own layer, above the logo and the page list
        local holder = CreateFrame("Frame", nil, f)
        holder:SetAllPoints(port)
        holder:SetFrameLevel(f:GetFrameLevel() + 21)
        local ring = holder:CreateTexture(nil, "OVERLAY", nil, 7)
        ring:SetTexture("Interface\\AddOns\\" .. ADDON .. "\\Media\\Ring")
        ring:SetPoint("TOPLEFT", port, "TOPLEFT", -8, 8)
        ring:SetPoint("BOTTOMRIGHT", port, "BOTTOMRIGHT", 8, -8)
        f.cleanRing = ring
        -- a solid dark disc right behind the logo: nothing (the price ticker) shows through it
        local owner = (pc and pc.CreateTexture) and pc or holder
        if not f.logoBack and owner.CreateTexture then
            local back = owner:CreateTexture(nil, "BACKGROUND", nil, -8)
            back:SetPoint("TOPLEFT", port, "TOPLEFT", 1, -1)
            back:SetPoint("BOTTOMRIGHT", port, "BOTTOMRIGHT", -1, 1)
            back:SetColorTexture(0.06, 0.045, 0.03, 1)
            if owner.CreateMaskTexture then
                local m = owner:CreateMaskTexture()
                m:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
                m:SetAllPoints(back)
                back:AddMaskTexture(m)
            end
            f.logoBack = back
        end
    end
    -- the two footer buttons: bigger
    -- the two footer buttons: Scan AH is the main one; the spending limit row sits clear above them
    if f.scanBtn then f.scanBtn:SetSize(132, 28); f.scanBtn:ClearAllPoints(); f.scanBtn:SetPoint("BOTTOMRIGHT", -12, 8); UI.FlatButton(f.scanBtn, true) end
    if f.secondBtn then f.secondBtn:SetSize(142, 28) end
    if f.limit then f.limit:ClearAllPoints(); f.limit:SetPoint("BOTTOMLEFT", 14 + self.navW, 42) end
    if f.money then f.money:ClearAllPoints(); f.money:SetPoint("BOTTOMLEFT", 16 + self.navW, 16) end
    PC:Safe("page list", self.CreateNav, self, f)
    self:FlattenButtons(f)
end

---------------------------------------------------------------------------
-- The page list down the left side (the clean look): every page, always there
---------------------------------------------------------------------------
local NAV_ROW, NAV_ICON = 34, 24
-- short names, so nothing is cut off
local NAV_NAMES = { [1] = "Recipes", [2] = "Crafting plan", [3] = "Items", [4] = "Profit & loss", [5] = "History",
    [6] = "Sell", [7] = "Settings", [8] = "Scout recipes" }

local function NavButton(nav, label, icon, tip)
    local b = CreateFrame("Button", nil, nav)
    b:SetHeight(NAV_ROW)
    b.on = Pill(b, "BACKGROUND", 1, { 0.91, 0.72, 0.29, 0.16 })
    b.on:SetShown(false)
    b.over = Pill(b, "BACKGROUND", 0, { 1, 1, 1, 0.05 })
    b.over:SetShown(false)
    -- the icon: square, in a thin gold frame
    b.iconEdge = b:CreateTexture(nil, "ARTWORK", nil, 1)
    b.iconEdge:SetSize(NAV_ICON + 2, NAV_ICON + 2)
    b.iconEdge:SetPoint("LEFT", 8, 0)
    b.iconEdge:SetColorTexture(0.80, 0.62, 0.26, 0.85)
    b.icon = b:CreateTexture(nil, "ARTWORK", nil, 2)
    b.icon:SetSize(NAV_ICON, NAV_ICON)
    b.icon:SetPoint("CENTER", b.iconEdge, "CENTER")
    b.icon:SetTexture(icon)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.text:SetPoint("LEFT", b.iconEdge, "RIGHT", 9, 0)
    b.text:SetPoint("RIGHT", -8, 0)
    b.text:SetJustifyH("LEFT")
    if b.text.SetWordWrap then b.text:SetWordWrap(false) end
    b.text:SetText(label)
    b.text:SetTextColor(0.86, 0.80, 0.68)
    b:SetScript("OnEnter", function(btn)
        if not btn.sel then btn.over:SetShown(true) end
        local t = tip
        if type(tip) == "function" then t = tip(btn) end
        if t then ShowTooltip(btn, t) end
    end)
    b:SetScript("OnLeave", function(btn) btn.over:SetShown(false); GameTooltip:Hide() end)
    return b
end

function UI:CreateNav(f)
    local nav = CreateFrame("Frame", nil, f)
    nav:SetPoint("TOPLEFT", 1, -(22 + TICKER_H))
    nav:SetPoint("BOTTOMLEFT", 1, 1)
    nav:SetWidth(self.navW - 1)
    local back = Fill(nav, "BACKGROUND", 3, T.nav)
    back:SetAllPoints()
    local line = Fill(nav, "BORDER", 3, T.navLine)
    line:SetPoint("TOPRIGHT", 0, 0); line:SetPoint("BOTTOMRIGHT", 0, 0); line:SetWidth(1)
    self.nav = nav
    nav.rows = {}

    -- Make me gold: the one that stands out, first in the list
    local gold = NavButton(nav, "Make me gold", "Interface\\Icons\\INV_Misc_Coin_02",
        { "|cff40ff40Make me gold|r", "Builds a plan with the best crafts that fit your spending limit",
            "and that actually sell." })
    gold.text:SetTextColor(1, 0.86, 0.35)
    gold:SetScript("OnClick", function() PC:Safe("make me gold", PC.MakeGold.Open, PC.MakeGold) end)
    nav.gold = gold

    -- the other ways to build a plan (they were buttons at the bottom of the Crafting plan page)
    nav.builders = {}
    local BUILD = {
        { key = "gearBtn", name = "Upgrade gear", icon = "Interface\\Icons\\Trade_BlackSmithing",
            what = { "Craftable items you're able to make that upgrade your own gear.",
                "Builds a plan with one of each. They're yours to wear, not sold." },
            none = "Nothing you can craft beats what you're wearing.",
            lines = { "Builds a plan called \"Gear upgrades\": one of each item you can craft that beats what you're wearing now.",
                "What you make is kept for you to wear; it isn't posted or sold.",
                "It opens on the Crafting plan page. Your other plans stay as they are." },
            run = function() PC:Safe("gear upgrades", UI.PlanGearUpgrades, UI) end },
        { key = "skillBtn", name = "Skill up", icon = "Interface\\Icons\\INV_Misc_Book_11",
            what = { "Builds a plan to raise a profession's skill, not to make gold:",
                "the cheapest crafts per skill point, inside your spending limit.",
                "Click to pick the profession." },
            none = "You're maxed out: nothing you know gives skill right now." },
    }
    for _, d in ipairs(BUILD) do
        local src = self[d.key]
        if src then
            local b = NavButton(nav, d.name, d.icon, function(btn)
                local t = { d.name }
                if btn.src.none then
                    t[#t + 1] = "|cffff8040" .. d.none .. "|r"
                else
                    for _, l in ipairs(d.what) do t[#t + 1] = l end
                end
                return t
            end)
            b.src = src
            b:SetScript("OnClick", function(btn)
                if btn.src.none then return end
                if d.key == "skillBtn" then
                    -- its menu (which profession, which colours) opens right beside this button
                    UI:ShowTab(2)
                    if UI.skillMenu then
                        UI.skillMenu:ClearAllPoints()
                        UI.skillMenu:SetPoint("TOPLEFT", btn, "TOPRIGHT", 10, 0)
                    end
                    UI:ToggleSkillMenu()
                    return
                end
                -- say what it's about to do, and what it would make, before doing it
                local sections = { { lines = d.lines, bullets = false } }
                if d.key == "gearBtn" and btn.src.list and #btn.src.list > 0 then
                    local items = {}
                    for i, u in ipairs(btn.src.list) do
                        if i > 10 then items[#items + 1] = ("and %d more"):format(#btn.src.list - 10) break end
                        items[#items + 1] = (PC:ItemName(u.e.r.output) or "?") .. (u.kind == "upgrade" and "" or "  (about the same as yours)")
                    end
                    sections[#sections + 1] = { title = "What it would make", lines = items }
                end
                UI:Ask("ProfitCrafterBuildPlan", {
                    title = d.name, sections = sections, fit = true,
                    buttons = { { text = "Build this plan", onClick = function() UI:ShowTab(2); d.run() end }, { text = "Cancel" } },
                })
            end)
            nav.builders[#nav.builders + 1] = b
            -- the old button stays where it was but can't be seen or clicked
            src:SetAlpha(0); src:EnableMouse(false)
        end
    end
    for _, k in ipairs({ "footerGoldBtn", "makeGoldBtn" }) do
        local old = self[k]
        if old then old:SetAlpha(0); old:EnableMouse(false) end
    end
    -- with those buttons gone, the plan's totals line gets the whole width (it was cut off)
    if self.shopSummary then self.shopSummary:SetWidth(PW - 8) end
    -- Clear Plan joins New / Rename / Delete at the top of the Crafting plan page
    if self.shopClear and self.planDelete then
        self.shopClear:ClearAllPoints()
        self.shopClear:SetPoint("LEFT", self.planDelete, "RIGHT", 4, 0)
        self.shopClear:SetSize(84, 22)
    end

    nav.rule = Fill(nav, "ARTWORK", 1, T.navLine)
    nav.rule:SetHeight(1)

    for _, t in ipairs(TAB_STRIP) do
        local id = t[1]
        local b = NavButton(nav, NAV_NAMES[id] or t[2], t.icon or QUESTION, { TAB_NAMES[id] or t[2], TAB_TIPS[id] })
        b.id, b.advanced, b.bottom = id, t.advanced, t.bottom
        b:SetScript("OnClick", function(btn) UI:ShowTab(btn.id) end)
        nav.rows[#nav.rows + 1] = b
    end
    self:LayoutNav()
end

function UI:LayoutNav()
    local nav = self.nav
    if not nav then return end
    local advanced = PC.db and PC.db.mode == "advanced"
    local y = -28                                  -- clear of the round logo
    local function place(b)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", 7, y); b:SetPoint("TOPRIGHT", -8, y)
        y = y - NAV_ROW - 2
    end
    place(nav.gold)
    for _, b in ipairs(nav.builders) do
        place(b)
        if b.src.none then b.text:SetTextColor(0.45, 0.43, 0.40) else b.text:SetTextColor(0.86, 0.80, 0.68) end
        if b.icon.SetDesaturated then b.icon:SetDesaturated(b.src.none and true or false) end
    end
    y = y - 5
    nav.rule:ClearAllPoints()
    nav.rule:SetPoint("TOPLEFT", 12, y); nav.rule:SetPoint("TOPRIGHT", -13, y)
    y = y - 7
    for _, b in ipairs(nav.rows) do
        local show = advanced or not b.advanced
        b:SetShown(show)
        if show then
            if b.bottom then
                b:ClearAllPoints()
                b:SetPoint("BOTTOMLEFT", 7, 8); b:SetPoint("BOTTOMRIGHT", -8, 8)
            else
                place(b)
            end
            local on = b.id == self.tab
            b.sel = on
            b.on:SetShown(on)
            if on then b.over:SetShown(false); b.text:SetTextColor(1, 0.86, 0.35) else b.text:SetTextColor(0.86, 0.80, 0.68) end
        end
    end
end

-- Small, normal or larger: the whole window scales, lettering and all, so nothing can overlap
UI.TEXT_SIZES = { small = 0.88, normal = 1, large = 1.14 }
function UI:ApplyTextSize()
    if not self.f then return end
    self.f:SetScale(UI.TEXT_SIZES[PC.db and PC.db.textSize or "normal"] or 1)
end

-- Tabs along the bottom, using the game's own tab buttons when available

-- One side tab in the profession window's style: a square icon in a gold frame hanging off the edge
local function SideTab(parent, name, icon)
    local tab = CreateFrame("CheckButton", name, parent)
    tab:SetSize(32, 32)
    local bg = tab:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
    bg:SetSize(64, 64)
    bg:SetPoint("TOPLEFT", -3, 11)
    tab.bg = bg
    tab:SetNormalTexture(icon)
    local hl = tab:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    hl:SetBlendMode("ADD")
    tab.checkedTex = tab:CreateTexture(nil, "OVERLAY")
    tab.checkedTex:SetAllPoints()
    tab.checkedTex:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    tab.checkedTex:SetBlendMode("ADD")
    tab.checkedTex:Hide()
    return tab
end
UI.SideTab = SideTab

function UI:CreateTabs()
    local f = self.f
    self.useGameTabs = false
    f.Tabs = {}
    for _, t in ipairs(TAB_STRIP) do
        local id, label = t[1], t[2]
        local tab = SideTab(f, "ProfitCrafterFrameTab" .. id, t.icon or QUESTION)
        tab.label = label
        tab:SetID(id)
        tab.advanced = t.advanced
        tab:SetScript("OnClick", function(btn) UI:ShowTab(btn:GetID()) end)
        tab:SetScript("OnEnter", function(btn)
            ShowTooltip(btn, { btn.label, TAB_TIPS[btn:GetID()] })
        end)
        tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.Tabs[id] = tab
    end
    -- Make me gold: same look, set apart at the bottom; a button, not a page
    local gold = SideTab(f, "ProfitCrafterMakeGoldTab", "Interface\\Icons\\INV_Misc_Coin_02")
    -- a pulsing gold glow around it (like a proc glow), with a sparkle circling the edge
    gold.glow = gold:CreateTexture(nil, "OVERLAY")
    gold.glow:SetPoint("TOPLEFT", -14, 14); gold.glow:SetPoint("BOTTOMRIGHT", 14, -14)
    gold.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    gold.glow:SetBlendMode("ADD")
    gold.glow:SetVertexColor(1, 0.82, 0.25)
    gold.halo = gold:CreateTexture(nil, "BACKGROUND", nil, -1)
    gold.halo:SetPoint("TOPLEFT", -10, 10); gold.halo:SetPoint("BOTTOMRIGHT", 10, -10)
    gold.halo:SetTexture("Interface\\Cooldown\\ping4")
    gold.halo:SetBlendMode("ADD")
    gold.halo:SetVertexColor(1, 0.75, 0.2)
    -- two sparks orbiting the edge in opposite directions
    gold.sparks = {}
    for k = 1, 2 do
        local sp = gold:CreateTexture(nil, "OVERLAY", nil, 2)
        sp:SetSize(20, 20)
        sp:SetTexture("Interface\\Cooldown\\star4")
        sp:SetBlendMode("ADD")
        sp:SetVertexColor(1, 0.95, 0.6)
        gold.sparks[k] = sp
    end
    -- twinkles: little stars that pop up all over the coins and fade, each on its own clock
    gold.twinkles = {}
    for k = 1, 7 do
        local tw = gold:CreateTexture(nil, "OVERLAY", nil, 3)
        tw:SetTexture("Interface\\Cooldown\\star4")
        tw:SetBlendMode("ADD")
        tw:SetVertexColor(1, 1, 0.75)
        tw:SetAlpha(0)
        tw.phase = math.random() * 3
        tw.speed = 0.7 + math.random() * 0.8
        gold.twinkles[k] = tw
    end
    -- a shine sweeping across the icon every couple of seconds
    gold.shine = gold:CreateTexture(nil, "OVERLAY", nil, 1)
    gold.shine:SetSize(8, 30)
    gold.shine:SetColorTexture(1, 1, 0.85, 1)
    gold.shine:SetBlendMode("ADD")
    if gold.shine.SetRotation then gold.shine:SetRotation(math.rad(-30)) end
    gold.shine:SetAlpha(0)
    gold:SetScript("OnUpdate", function(btn)
        local t = GetTime()
        local pulse = 0.55 + 0.45 * math.sin(t * 3.5)       -- breathes a bit faster than twice a second
        btn.glow:SetAlpha(0.55 + 0.45 * pulse)
        btn.halo:SetAlpha(0.25 + 0.45 * pulse)
        -- orbiting sparks
        for k, sp in ipairs(btn.sparks) do
            local a = (k == 1 and 1 or -1) * t * 2.6 + (k - 1) * math.pi
            sp:ClearAllPoints()
            sp:SetPoint("CENTER", btn, "CENTER", math.cos(a) * 21, math.sin(a) * 21)
            sp:SetAlpha(0.65 + 0.35 * pulse)
            if sp.SetRotation then sp:SetRotation(-a * 1.6) end
        end
        -- twinkles: grow, flash, shrink, then jump somewhere new
        for _, tw in ipairs(btn.twinkles) do
            local c = ((t + tw.phase) * tw.speed) % 1.6
            if c < 0.8 then
                if not tw.placed then
                    tw:ClearAllPoints()
                    tw:SetPoint("CENTER", btn, "CENTER", math.random(-16, 16), math.random(-16, 16))
                    tw.placed = true
                end
                local f = math.sin(c / 0.8 * math.pi)        -- 0 -> 1 -> 0
                tw:SetSize(6 + 12 * f, 6 + 12 * f)
                tw:SetAlpha(f)
                if tw.SetRotation then tw:SetRotation(c * 3) end
            else
                tw:SetAlpha(0)
                tw.placed = false
            end
        end
        -- the shine: across the icon once every 2.5 seconds
        local sweep = (t % 2.5) / 0.6
        if sweep <= 1 then
            btn.shine:ClearAllPoints()
            btn.shine:SetPoint("CENTER", btn, "CENTER", -13 + 26 * sweep, 0)
            btn.shine:SetAlpha(0.4 * math.sin(sweep * math.pi))
        else
            btn.shine:SetAlpha(0)
        end
    end)
    gold:SetScript("OnClick", function(btn)
        btn:SetChecked(false)
        PC:Safe("make me gold", PC.MakeGold.Open, PC.MakeGold)
    end)
    gold:SetScript("OnEnter", function(btn)
        ShowTooltip(btn, { "|cff40ff40Make me gold|r", "Builds a plan with the best crafts that fit your spending limit",
            "and that actually sell." })
    end)
    gold:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.goldTab = gold
    self:LayoutTabs()
end

-- Tabs down the right edge of the window (Simple mode hides Items and History)
function UI:LayoutTabs()
    local f = self.f
    if not f or not f.Tabs then return end
    if self.nav then
        -- the clean look: the page list on the left does this job
        for _, tab in pairs(f.Tabs) do tab:Hide() end
        if f.goldTab then f.goldTab:Hide() end
        self:LayoutNav()
        return
    end
    local advanced = PC.db and PC.db.mode == "advanced"
    local y = -40
    -- Make me gold first, glowing, with a little room before the page tabs
    if f.goldTab then
        f.goldTab:ClearAllPoints()
        f.goldTab:SetPoint("TOPLEFT", f, "TOPRIGHT", 0, y)
        y = y - 60
    end
    for _, t in ipairs(TAB_STRIP) do
        local tab = f.Tabs[t[1]]
        if tab then
            local show = advanced or not tab.advanced
            tab:SetShown(show)
            if show and t.bottom then
                -- Settings: always there, at the bottom of the side tabs
                tab:ClearAllPoints()
                tab:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT", 0, 40)
            elseif show then
                tab:ClearAllPoints()
                tab:SetPoint("TOPLEFT", f, "TOPRIGHT", 0, y)
                y = y - 46
            end
        end
    end
    self:PaintTabs()
end

function UI:PaintTabs()
    local f = self.f
    if not f or not f.Tabs then return end
    for id, tab in pairs(f.Tabs) do
        local on = id == self.tab
        if tab.SetChecked then tab:SetChecked(on) end
        if tab.checkedTex then tab.checkedTex:SetShown(on) end
    end
end

function UI:ShowTab(n)
    self.tab = n
    if not self.f then return end
    for i, p in ipairs(self.pages) do p:SetShown(i == n) end
    self:LayoutTabs()
    self.f.secondBtn:SetText(n == 1 and "Crafting plan" or "Back to recipes")
    if self.f.search and self.f.search.Instructions then
        self.f.search.Instructions:SetText(n == 5 and "Search history" or "Search recipes")
    end
    if self.UpdateNav then self:UpdateNav() end
    self:Redraw()
end

-- Simple mode: Make me gold, Plan, Recipes and Settings (at the bottom) show; a page it hides isn't opened by itself
function UI:TabHidden(n)
    if PC.db and PC.db.mode == "advanced" then return false end
    for _, t in ipairs(TAB_STRIP) do if t[1] == n then return t.advanced and true or false end end
    return false
end

function UI:Show()
    if PC.inCombat then return end -- nothing of ProfitCrafter's shows in combat
    self:Create()
    if self:TabHidden(self.tab) then self:ShowTab(2) end
    if self.CanEmbed and PC.ahOpen and self:CanEmbed() then
        self:ShowInAH()
    else
        self.f:Show()
    end
end

function UI:Toggle()
    self:Create()
    if self.f:IsShown() then
        self.f:Hide()
    else
        self:Show()
    end
end

function UI:OpenTab(n)
    self:Show()
    self:ShowTab(n)
end

function UI:ToggleItems() self:OpenTab(3) end

---------------------------------------------------------------------------
-- Refresh (with a safety net so one error doesn't blank the window)
---------------------------------------------------------------------------
function UI:UpdateLimit(force)
    local lim = self.f and self.f.limit
    if not lim then return end
    local o = PC.cdb.overrides.gold
    -- the limit never sits above your gold (you spent some since setting it): it comes down with it
    if o and GetMoney and o > GetMoney() then
        o = math.max(GetMoney(), 0)
        PC.cdb.overrides.gold = o > 0 and o or nil
        o = PC.cdb.overrides.gold
        force = true
    end
    local editing = false
    for _, b in ipairs(lim.boxes or {}) do if b.HasFocus and b:HasFocus() then editing = true end end
    if force or not editing then
        local boxes = lim.boxes or {}
        if o then
            boxes[1]:SetText(tostring(math.floor(o / 10000)))
            if boxes[2] then boxes[2]:SetText(tostring(math.floor(o / 100) % 100)) end
            if boxes[3] then boxes[3]:SetText(tostring(o % 100)) end
        else
            for _, b in ipairs(boxes) do b:SetText("") end
        end
    end
    -- what the plan still costs (materials to buy + posting fees), and what that leaves of the limit
    local cost = 0
    if self.allEntries then
        local ok, c = pcall(self.PlanCost, self)
        if ok and c then cost = c end
    end
    local budget = PC:Gold()
    local left = budget - cost
    -- in plain words: what the plan costs, and how much more you could still spend on it
    local planTxt = cost > 0 and ("Plan costs " .. PC:Money(cost, false, true)) or "Nothing to buy"
    local leftTxt = left < 0 and ("|cffff5555" .. PC:Money(-left, false, true) .. " over|r")
        or ("|cffffd100" .. PC:Money(left, false, true) .. " more to spend|r")
    if o and o <= 0 then
        lim.note:SetText("|cffff5555Limit is 0: raise it to buy anything|r")
    else
        lim.note:SetText(planTxt .. "  ·  " .. leftTxt .. (o and "" or " |cff888888(no limit set)|r"))
    end
    lim.note.cost, lim.note.left = cost, left
end

function UI:Refresh()
    -- (one shared memo for the whole redraw, also when a click redraws straight away: prices, ladders
    -- and the shopping list are worked out once, not once per table)
    local ok, err = pcall(PC.WithMemo, PC, self.DoRefresh, self)
    if not ok and err ~= self.lastError then
        self.lastError = err
        PC.Print("|cffff5555Something went wrong drawing the window. Please send this to whoever made the addon:|r " .. tostring(err))
    end
end

-- Sorting, searching, a filter, another tab: the same recipes drawn again, nothing worked out again
-- (working every recipe out again was most of the time a redraw took)
function UI:Redraw()
    self.reuse = self.allEntries ~= nil
    self:Refresh()
    self.reuse = nil
end

function UI:DoRefresh()
    local f = self.f
    if not PC.cdb then return end
    -- the Next step bar works without the window: keep the numbers fresh even while it's closed
    -- (with the window closed, working out every recipe again on every refresh was the lag while
    -- following the task list: now only when something marked it out of date, or every 15 seconds)
    if not f or not f:IsShown() then
        local now = GetTime and GetTime() or 0
        if not self.allEntries or now - (self.analyzedAt or -100) > 15 then
            self.allEntries = PC:Analyze()
            self.analyzedAt = now
        end
        return
    end

    f.money:SetText(PC:Money(GetMoney()))
    self:UpdateLimit()
    f.onlyProfit:SetChecked(PC.db.onlyProfit)
    f.onlyProfit.label = ("Only %s%%+ Auction profit"):format(PC:MinProfitPct()) -- follows the minimum in Settings
    f.onlyProfitText:SetText(f.onlyProfit.label)
    f.onlyVProfit:SetChecked(PC.db.onlyVProfit and true or false)
    f.onlyVProfit.label = ("Only %s%%+ Vendor profit"):format(PC:MinProfitPct())
    f.onlyVProfitText:SetText(f.onlyVProfit.label)
    f.onlyAfford:SetChecked(PC.db.onlyAffordable ~= false)

    -- Status line (hidden behind the progress bar while scanning)
    local nRecipes = 0
    for _ in pairs(PC.cdb.recipes) do nRecipes = nRecipes + 1 end
    local t = PC.db.scanTime[PC:Faction()]
    local status
    if nRecipes == 0 then
        status = "|cffff8040Open each profession window once|r"
    elseif t then
        status = ("Prices from %s ago"):format(PC:Ago(time() - t))
    else
        status = "|cffff8040No prices yet: open the Auction House and scan|r"
    end
    f.status:SetText(status)

    f.scanBtn:SetEnabled(PC.ahOpen and not PC.scanning)
    if not PC.scanning then f.scanBtn:SetText("Scan auctions") end

    if not (self.reuse and self.allEntries) then
        self.allEntries = PC:Analyze()
        self.analyzedAt = GetTime and GetTime() or 0
    end

    if self.tab == 1 then self:UpdateRecipes()
    elseif self.tab == 2 then self:UpdateShopping()
    elseif self.tab == 3 then self:UpdateItems()
    elseif self.tab == 4 then self:UpdatePnL()
    elseif self.tab == 5 then self:UpdateHistory()
    elseif self.tab == 6 then self:UpdateSell()
    elseif self.tab == 8 then self:UpdateLearn() end

    self:UpdateBar()
end

function UI:FindEntry(id)
    for _, e in ipairs(self.allEntries or {}) do
        if e.id == id then return e end
    end
end

---------------------------------------------------------------------------
-- Progress bar
---------------------------------------------------------------------------
function UI:UpdateBar()
    local f = self.f
    if not f then return end
    local bar = f.bar

    if PC.scanning then
        local value, label
        if PC.scanMode == "quick" and PC.quick then
            local q = PC.quick
            value = PC.progress or 0
            label = ("Checking prices: %d of %d items (%d%%)"):format(
                math.max(q.pos - (q.batch and #q.batch or 0), 0), #q.items, math.floor(value * 100))
        elseif PC.scanMode == "depth" then
            local d = PC.Depth
            value = PC.progress or 0
            label = ("Reading live listings: %d of %d materials"):format(math.max((d.pos or 1) - 1, 0), d.count or 0)
        elseif PC.progress then
            value = 0.1 + 0.9 * PC.progress
            label = ("Reading prices... %d%%"):format(math.floor(PC.progress * 100))
        else
            local elapsed = GetTime() - (PC.scanStartedAt or GetTime())
            value = math.min(elapsed / 30, 1) * 0.1
            label = ("Waiting for Auction House data... %ds"):format(math.floor(elapsed))
        end
        f.scanBtn:SetText(("Scanning %d%%"):format(math.floor(value * 100)))
        f.scanBtn:SetEnabled(false)
        bar:SetStatusBarColor(1, 0.82, 0)
        bar:SetValue(value)
        bar.text:SetText(label)
        bar:Show()
        f.status:Hide()
    elseif self.doneUntil and GetTime() < self.doneUntil then
        if self.doneOk then bar:SetStatusBarColor(0.1, 0.8, 0.1) else bar:SetStatusBarColor(0.8, 0.1, 0.1) end
        bar:SetValue(1)
        bar.text:SetText(self.doneText)
        bar:Show()
        f.status:Hide()
    else
        bar:Hide()
        f.status:Show()
    end
end

function UI:ScanFinished(ok, text)
    self.doneOk = ok
    -- keep it short so it fits the bar; the details are in chat
    self.doneText = ok and "Scan complete!" or "Scan stopped. See chat."
    self.doneUntil = GetTime() + 8
    if ok and PlaySound and SOUNDKIT and SOUNDKIT.READY_CHECK then
        PlaySound(SOUNDKIT.READY_CHECK)
    end
    self:UpdateBar()
    C_Timer.After(8.1, function() UI:UpdateBar() end)
end

---------------------------------------------------------------------------
-- Tab 1: Recipes
---------------------------------------------------------------------------
UI.ROUTE_TEXT = { AH = "selling at auction", Vendor = "selling to a vendor", Disenchant = "disenchanting it" }
-- what stops the Craftable at Profit count
UI.CRAFT_WHY = { gold = "your gold or spending limit, deposits included", market = "Auction listings run out",
    profit = "the next craft would lose money", max = "the plan limit", bags = "bag space" }

-- Tooltip lines: how many you can craft at a profit, what stops it there, and each way's total
function UI:CraftableLines(e)
    local n, worth, spend, tAH, tV, why, est, nAH, nV = PC:Craftable(e)
    if not n then return { " ", "Craftable at Profit: |cff888888n/a (a price is missing)|r" } end
    if e.ahFlip and not self.CRAFT_WHY_FLIP then
        self.CRAFT_WHY_FLIP = { gold = "your gold or spending limit", market = "listings run out",
            profit = "the next listing costs as much as a vendor pays", max = "the plan limit", bags = "bag space" }
    end
    local whyText = e.ahFlip and self.CRAFT_WHY_FLIP or self.CRAFT_WHY
    local out = { " ", ("%s: |cffffffff%d|r%s"):format(e.ahFlip and "To buy at a profit" or "Craftable at Profit", n,
        why and ("  |cff888888(stops at: " .. (whyText[why] or why) .. ")|r") or "") }
    local unit = e.ahFlip and "bought" or "craft"
    local function way(label, t, k)
        if t == nil then return ("%s: |cff888888n/a|r"):format(label) end
        if (k or 0) <= 0 then
            local m = math.max(n, 1)
            return ("%s: %s  |cffff8040(no profit this way: the loss on %d %s%s)|r"):format(label, PC:Money(t, true), m, unit, m == 1 and "" or "s")
        end
        return ("%s: %s  |cff888888(%d %s%s)|r"):format(label, PC:Money(t, true), k, unit, k == 1 and "" or "s")
    end
    out[#out + 1] = way("Total Auction Profit", tAH, nAH)
    out[#out + 1] = way("Total Vendor Profit", tV, nV)
    if n > 0 then
        out[#out + 1] = ("|cff888888All %d: materials worth %s, %s still to buy, at live listing prices.|r"):format(n, PC:Money(worth), PC:Money(spend))
    end
    -- what buying will really do: it stops before a craft would make less than the minimum profit
    local m, _, _, mwhy = PC:BuyCrafts(e)
    local pct = PC:MinProfitPct()
    if m and m < n and mwhy == "profit" then
        out[#out + 1] = m == 0 and ("|cffff8040At your %d%% minimum profit: none, so nothing is bought for it.|r"):format(pct)
            or ("|cffff8040At your %d%% minimum profit: %d. Buying stops there.|r"):format(pct, m)
    end
    if est then out[#out + 1] = "|cffffd100~ Estimate: a material has no live listings, so its last cheapest price is used.|r" end
    return out
end

-- A recipe's ingredients for one craft and what each costs (the way it's priced): a tooltip paragraph
UI.SRC_TEXT = { AH = "Auction House, cheapest listing", Vendor = "what a vendor charges, after Bartering", Craft = "cheaper to make yourself",
    Disenchant = "disenchanting a crafted green (an estimate: yields vary)" }
function UI:IngredientLines(r, mats)
    local out = { " ", "|cffffd100Ingredients for one craft:|r" }
    local total, missing = 0, false
    for _, rg in ipairs(r and r.reagents or {}) do
        local id, unit, src = PC:ReagentFor(rg, mats)
        local n = rg.n or 1
        local qty = n % 1 == 0 and tostring(n) or ("%.1f"):format(n)
        local name = (id and PC:ItemName(id)) or "?"
        local have = PC:ReagentCount(rg)
        if unit then
            total = total + unit * n
            out[#out + 1] = ("  %s x %s: %s each = |cffffffff%s|r  |cff888888(%s; you have %d)|r"):format(qty, name,
                PC:Money(unit), PC:Money(unit * n), self.SRC_TEXT[src] or src or "?", have)
        else
            missing = true
            out[#out + 1] = ("  %s x %s: |cffff5555no price yet|r  |cff888888(you have %d)|r"):format(qty, name, have)
        end
    end
    out[#out + 1] = ("  Total: |cffffffff%s|r%s"):format(PC:Money(total), missing and " |cffff5555+ the unpriced ones|r" or "")
    return out
end

function UI:CreateRecipesPage(p)
    -- Professions in a row across the top (placed in UpdateRecipes, each as wide as its name)
    local cat = CreateFrame("Frame", nil, p)
    cat:SetPoint("TOPLEFT", 12, -60)
    cat:SetSize(PW, 28)
    self.catBar = cat
    self.catButtons = {}
    for i = 1, 9 do
        local b = CreateFrame("Button", nil, cat)
        b:SetSize(80, 26)
        b:SetPoint("LEFT", (i - 1) * 84, 0)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.edge = b:CreateTexture(nil, "BORDER")
        b.edge:SetPoint("BOTTOMLEFT")
        b.edge:SetPoint("BOTTOMRIGHT")
        b.edge:SetHeight(2)
        b.edge:SetColorTexture(1, 0.82, 0, 1)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.12)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        b.text:SetPoint("CENTER", 0, 0)
        b.text:SetWordWrap(false)
        b:SetScript("OnClick", function(btn)
            UI.category = btn.value
            UI.offset = 0
            local s = UI:SortState("recipes")
            if btn.value == "BEST" then
                s.key, s.dir, s.auto = "score", -1, true          -- best bets start in "most likely gold" order
            elseif btn.value == "VENDOR" then
                s.key, s.dir, s.auto = "vendorProfit", -1, true   -- vendor flips start biggest V Profit first
            elseif s.auto then
                s.key, s.dir, s.auto = "profit", -1, nil          -- (a sort you picked yourself stays)
            end
            UI:Redraw()
        end)
        b:Hide()
        self.catButtons[i] = b
    end
    -- Sortable recipe list, the full width of the page
    local lp = Panel(p, 12, -92, PW, 380)
    HeaderStrip(lp)
    local cols = {
        { "name", "Name", nil, "The arrows show the chance of a skill-up.", text = true },
        { "cost", "Mats", 76, "Material cost of one craft, each from its cheapest source: the Auction House, a vendor (after Bartering) or making it yourself. The recipe's tooltip lists every ingredient. Auction House flips: the auction price of one." },
        { "sell", "Sells at auction", 68, "What one craft's output sells for at auction, at the cheapest listing." },
        { "vendorSell", "Sells to vendor for", 68, "What a vendor pays you for one craft's output. Orange: not confirmed yet (sell one to a vendor to confirm it)." },
        { "ahProfit", "Auction Profit", 80, "Profit per craft selling at auction, after its 5% cut." },
        { "vendorProfit", "Vendor Profit", 80, "Profit per craft selling to a vendor. Blue: set to sell to a vendor." },
        { "profitPct", "Profit %", 48, "Profit as a % of material cost, for how it's sold (auction, vendor or disenchanting)." },
        { "listed", "Listed", 52, "How many are at auction now." },
        { "soldToday", "Sold today", 50, "Sales since midnight (0 if unknown). Orange 0: no sales today, so not recommended for auction." },
        { "craftable", "Craftable at Profit", 64, "How many you can craft at a profit (auction or vendor) with your materials, gold or spending limit and bag space, buying the rest at live listing prices. Matches Max profitable for an empty plan. The recipe's tooltip says how many clear your minimum profit, where buying stops. ~ = a material has no live listings." },
        { "totalAH", "Total Auction Profit", 84, "Auction Profit for every craft that still profits at auction, the whole batch at live listing prices." },
        { "totalV", "Total Vendor Profit", 84, "Vendor Profit for every craft that still profits selling to a vendor, priced the same way." },
    }
    self.recipeCols = cols
    self.recipeHeaders = Columns(lp, cols, "recipes")
    local C = cols.by

    local list = CreateFrame("Frame", nil, lp)
    list:SetPoint("TOPLEFT", 4, LIST_Y)
    list:SetSize(RW, RECIPE_ROWS * ROW_H)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        UI.offset = UI.offset - delta * 3
        UI:UpdateRecipeRows()
    end)

    self.recipeEmpty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.recipeEmpty:SetPoint("CENTER")
    self.recipeEmpty:SetWidth(560)

    self.recipeRows = {}
    for i = 1, RECIPE_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetSize(RW, ROW_H)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        Stripe(row, i)
        row.sel = row:CreateTexture(nil, "BORDER")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(unpack(T.rowSel))
        row.sel:Hide()
        -- In the crafting plan: tint + check mark on the icon
        row.multi = row:CreateTexture(nil, "BORDER", nil, 1)
        row.multi:SetAllPoints()
        row.multi:SetColorTexture(0.25, 0.55, 1, 0.36)
        row.multi:Hide()
        -- bright edge on the left so rows in your plan pop out
        row.multiEdge = row:CreateTexture(nil, "ARTWORK", nil, 2)
        row.multiEdge:SetPoint("TOPLEFT")
        row.multiEdge:SetPoint("BOTTOMLEFT")
        row.multiEdge:SetWidth(3)
        row.multiEdge:SetColorTexture(0.4, 0.75, 1, 1)
        row.multiEdge:Hide()
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(unpack(T.rowHover))

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(22, 22)
        row.icon:SetPoint("LEFT", 4, 0)
        SkillArrows(row, 30)
        row.name = RowText(row, 46, C.name.w - 46 - 48)
        row.shop = ShopButton(row, 18)
        row.shop:SetPoint("LEFT", C.name.w - 22, 0)
        row.shop.getEntries = function() return row.entry and { row.entry } or {} end
        row.quick = QuickButton(row, 18)
        row.quick:SetPoint("RIGHT", row.shop, "LEFT", -4, 0)
        row.quick.getEntry = function() return row.entry end
        -- larger lettering to go with the taller rows (a value too wide for it gets the small one)
        row.name:SetFontObject("GameFontHighlight")
        row.name.bigFont = "GameFontHighlight"
        row.cell = {}
        for i2 = 2, #cols do
            local c = cols[i2]
            local fs = RowText(row, c.x, c.w - 4, "RIGHT")
            fs:SetFontObject("GameFontHighlight")
            fs.bigFont = "GameFontHighlight"
            row.cell[c[1]] = fs
        end
        row:SetScript("OnEnter", function(btn)
            local e = btn.entry
            if not e then return end
            if e.ahFlip then
                local sure = PC.db.vendorPaid and PC.db.vendorPaid[e.ahFlipID]
                local tip = { e.r.name .. "  |cff40c0ff(auction flip)|r",
                    "|cff40c0ffNot a craft:|r bought at auction and sold to any vendor for more.",
                    " ",
                    ("Cheapest at auction: %s each |cff888888(the Mats column)|r"):format(PC:Money(e.cost)),
                    ("A vendor pays: %s each%s"):format(PC:Money(e.sell), sure and " |cff888888(confirmed)|r"
                        or " |cffff8040(not confirmed yet: sell one to a vendor to confirm it)|r"),
                    ("Vendor Profit each: %s (%d%%)"):format(PC:Money(e.vendorProfit, true), math.floor((e.vendorProfitPct or 0) + 0.5)),
                    ("Auction Profit each: %s |cff888888(relisting it, after the 5%% auction cut)|r"):format(PC:Money(e.ahProfit, true)),
                }
                for _, l in ipairs(UI:CraftableLines(e)) do tip[#tip + 1] = l end
                tip[#tip + 1] = ("Sold today: |cffffffff%d|r%s"):format(e.soldToday or 0, e.soldTodayKnown and "" or " |cff888888(not scanned today)|r")
                tip[#tip + 1] = " "
                for _, line in ipairs(PC:SalesTooltip(e.ahFlipID)) do tip[#tip + 1] = line end
                tip[#tip + 1] = " "
                for _, l in ipairs(PC:DepthLines(e.ahFlipID)) do tip[#tip + 1] = l end
                tip[#tip + 1] = "|cff888888Click at the Auction House to buy those listed below what a vendor pays. They're sold at your next vendor.|r"
                ShowTooltip(btn, tip, e.ahFlipID)
                return
            end
            local tip = { e.r.name }
            local qty = e.r.qty or 1
            if e.sellEach then
                if qty ~= 1 then
                    tip[#tip + 1] = ("Makes %s per craft: %s each = |cffffffff%s per craft|r."):format(
                        qty % 1 == 0 and tostring(qty) or ("%.1f"):format(qty), PC:Money(e.sellEach), PC:Money(e.sell))
                else
                    tip[#tip + 1] = "Sells for " .. PC:Money(e.sellEach) .. " (cheapest listing)."
                end
            end
            if e.vendorSell then tip[#tip + 1] = ("A vendor pays %s per craft."):format(PC:Money(e.vendorSell)) end
            if e.cost then tip[#tip + 1] = "Materials per craft: " .. PC:Money(e.cost) end
            for _, l in ipairs(UI:IngredientLines(e.r, e.mats)) do tip[#tip + 1] = l end
            tip[#tip + 1] = " "
            tip[#tip + 1] = "Auction Profit per craft: " .. PC:Money(e.ahProfit, true)
                .. (e.ahProfit and " (after the 5% auction cut)" or " |cff888888(no auction price, or it can't be listed)|r")
            local sure = PC.db.vendorPaid and PC.db.vendorPaid[e.outID or e.r.output]
            tip[#tip + 1] = "Vendor Profit per craft: " .. PC:Money(e.vendorProfit, true)
                .. ((e.vendorProfit and not sure) and " |cffff8040(not confirmed yet: sell one to a vendor to confirm it)|r" or "")
            if e.noSalesToday then tip[#tip + 1] = "|cffff8040No sales today: not recommended for auction.|r" end
            if e.route == "Vendor" and e.profit and e.profit > 0 then
                tip[#tip + 1] = "|cff40c0ffBest: sell to any vendor. Instant gold, no auction.|r"
            end
            -- a green: what disenchanting it gives (and whether that beats selling it)
            local de = PC.Synergy and PC.Synergy:Describe(e.outID or e.r.output)
            if de then
                tip[#tip + 1] = "|cffc080ff" .. de .. "|r"
                if e.deProfit then tip[#tip + 1] = "Profit per craft if disenchanted: " .. PC:Money(e.deProfit, true) end
                if e.route == "Disenchant" then tip[#tip + 1] = "|cffc080ffBest: craft it and disenchant it; sell the dust.|r" end
            end
            if e.listed then
                tip[#tip + 1] = ("%d already listed at auction."):format(e.listed)
            else
                tip[#tip + 1] = "Number listed at auction: not scanned yet."
            end
            if e.qualities then
                tip[#tip + 1] = " "
                tip[#tip + 1] = "|cffffd100Sells for, by quality (each):|r"
                for q, d in ipairs(e.qualities) do
                    local mark = ""
                    if q == e.qualityUsed then mark = "  " .. PC.ARROW_L .. " |cff40ff40used|r" end
                    if q == e.quality and q ~= e.qualityUsed then mark = "  " .. PC.ARROW_L .. " |cffff8040yours, no price yet|r" end
                    tip[#tip + 1] = ("  %s  %s%s%s"):format(UI.QualityLabel(q, #e.qualities, d.id), d.price and PC:Money(d.price) or "|cff888888not scanned / none listed|r",
                        d.listed and (" |cff888888(" .. d.listed .. " listed)|r") or "", mark)
                end
                if e.qualitySet then
                    tip[#tip + 1] = ("|cff888888Priced at|r %s |cff888888because you picked it. Ctrl-click to change.|r"):format(UI.QualityLabel(e.quality, #e.qualities))
                else
                    tip[#tip + 1] = ("|cff888888Priced at|r %s|cff888888: what your skill makes with basic materials. Ctrl-click to pick another.|r"):format(UI.QualityLabel(e.quality, #e.qualities))
                end
            end
            if e.high then
                tip[#tip + 1] = " "
                tip[#tip + 1] = "|cffffd100Worked out both ways (per craft):|r"
                for _, w in ipairs({ { e.low, "Cheapest mats" }, { e.high, "Top-quality mats" } }) do
                    local d = w[1]
                    tip[#tip + 1] = ("  %s: mats %s " .. PC.ARROW_R .. " Q%s sells %s, Auction Profit %s, Vendor Profit %s%s"):format(w[2],
                        d.cost and PC:Money(d.cost) or "?", tostring(d.qualityUsed or "?"),
                        d.sell and PC:Money(d.sell * (e.r.qty or 1)) or "?",
                        PC:Money(d.ahProfit, true), PC:Money(d.vendorProfit, true),
                        d.mode == e.mats and ("  " .. PC.ARROW_L .. " |cff40ff40used|r") or "")
                end
                tip[#tip + 1] = "|cff888888Top quality also depends on your skill.|r"
                tip[#tip + 1] = e.matsPicked and "|cff888888You picked this on the Crafting plan tab.|r"
                    or "|cff888888Using whichever makes more. Pick one on the Crafting plan tab.|r"
            end
            if e.profitPct then
                tip[#tip + 1] = ("Profit %%: |cffffffff%d%%|r of material cost, %s."):format(math.floor(e.profitPct + 0.5),
                    UI.ROUTE_TEXT[e.route] or "the way it's sold")
            end
            for _, l in ipairs(UI:CraftableLines(e)) do tip[#tip + 1] = l end
            if e.lastSoldDays then
                tip[#tip + 1] = "Last sold: " .. UI.DaysText(e.lastSoldDays, true)
                    .. (e.lastSoldMine and " (your own sale)" or " (seen leaving the Auction House)")
            else
                tip[#tip + 1] = "Last sold: |cff888888? not seen yet (scan a few times)|r"
            end
            tip[#tip + 1] = ("Sold today: |cffffffff%d|r%s"):format(e.soldToday or 0,
                e.soldTodayKnown and "" or " |cff888888(not scanned today)|r")
            tip[#tip + 1] = " "
            for _, line in ipairs(PC:SalesTooltip(e.outID or e.r.output)) do tip[#tip + 1] = line end
            tip[#tip + 1] = " "
            for _, l in ipairs(PC:DepthLines(e.outID or e.r.output)) do tip[#tip + 1] = l end
            tip[#tip + 1] = "|cff888888Click: select   Shift-click: search the Auction House   Right-click: craft it   Shift-right-click: link|r"
            ShowTooltip(btn, tip, e.outID or e.r.output)
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", function(btn, button)
            if btn.entry and btn.entry.ahFlip then
                if UI:ClickItem(btn.entry.ahFlipID, button) then return end
                if button == "LeftButton" then UI:BuyAHFlip(btn.entry) end
                return
            end
            if btn.entry then
                local e = btn.entry
                local ctrl = IsControlKeyDown and IsControlKeyDown()
                -- Ctrl-click: choose which quality rank to price it at (cycles, then back to automatic)
                if e.qualities and ctrl and button == "LeftButton" then
                    local picks = PC.cdb.qualityPick
                    local cur = picks[e.r.name]
                    if not cur then cur = 0 end
                    local nextQ = cur + 1
                    if nextQ > #e.qualities then picks[e.r.name] = nil else picks[e.r.name] = nextQ end
                    PC.Print(("%s: priced at %s."):format(e.r.name,
                        picks[e.r.name] and ("Q" .. picks[e.r.name]) or "your skill's quality (automatic)"))
                    PC:RefreshUI()
                    return
                end
                if button == "RightButton" and not (IsShiftKeyDown and IsShiftKeyDown()) then
                    UI:OpenRecipe(e.id, e.r)
                    return
                end
                if UI:ClickItem(e.outID or e.r.output, button) then return end
                if button == "LeftButton" and PC.ahOpen then
                    PC.Depth:CheckNow(e.outID or e.r.output)
                    for _, rg in ipairs(e.r.reagents) do
                        local id = PC:ReagentFor(rg, e.mats)
                        if id then PC.Depth:CheckNow(id) end
                    end
                end
                UI.selected = btn.entry.id
                UI:UpdateRecipeRows()
            end
        end)
        row:SetScript("OnDoubleClick", function(btn)
            if btn.entry then UI:ShowQtyPopup(btn.entry, btn.shop) end
        end)
        self.recipeRows[i] = row
    end

    self.recipeCount = Text(lp, "GameFontDisableSmall", 10, LIST_Y - RECIPE_ROWS * ROW_H - 8, RW - 12)
    self.recipeCount:SetWordWrap(false)
end

-- AH -> vendor flips: things listed on the AH for clearly less (10%+) than a vendor pays for them.
-- Buy them here, sell them to any vendor. Shown in Vendor flips (they aren't recipes, so they can't
-- go in a crafting plan: clicking one buys it). Only items whose vendor price is already known.
UI.AH_FLIP_MARGIN = 0.9
function UI:AHFlips()
    local out = {}
    local today = PC:SecondsToday()
    local prices, supply = PC:Prices(), PC:Supply()
    local sells = PC.db and PC.db.sellPrice or {}
    for id, sell in pairs(sells) do
        local p = prices[id]
        if type(p) == "number" and p > 0 and type(sell) == "number" and sell > 0 and p <= sell * self.AH_FLIP_MARGIN then
            local name = PC:ItemName(id)
            if name then
                local n = supply[id]
                -- (every column filled: listing it again on the AH would lose the cut, a vendor pays more)
                local ahProfit = p * (1 - PC.AH_CUT) - p
                local est = PC:SalesEstimate(id, today)
                local mine = PC:MySales(name, today)
                out[#out + 1] = { id = -id, ahFlipID = id, ahFlip = true, outID = id,
                    r = { name = name, prof = "Auction flip", output = id, reagents = {}, qty = 1 },
                    cost = p, sell = sell, sellAH = p, vendorSell = sell, profit = sell - p, vendorProfit = sell - p,
                    ahProfit = ahProfit, ahProfitPct = ahProfit / p * 100, vendorProfitPct = (sell - p) / p * 100,
                    profitPct = (sell - p) / p * 100, route = "Vendor", listed = type(n) == "number" and n or nil,
                    soldToday = math.max(est or 0, mine or 0), soldTodayKnown = est ~= nil or (mine or 0) > 0 }
            end
        end
    end
    return out
end

-- Click an AH flip: buy the cheap listings (at the AH), and they're marked to sell to a vendor
function UI:BuyAHFlip(e)
    local id = e.ahFlipID
    if not id then return end
    PC.cdb.ahFlipItems = PC.cdb.ahFlipItems or {}
    PC.cdb.ahFlipItems[id] = true
    PC.cdb.sellVia = PC.cdb.sellVia or {}
    PC.cdb.sellVia[id] = "Vendor"
    if not PC.ahOpen then
        return PC.Buy:Say(("|cffff8040Open the Auction House to buy %s: any vendor pays %s each for it.|r"):format(e.r.name, PC:Money(e.sell, false, true)))
    end
    local cap = math.floor(e.sell * self.AH_FLIP_MARGIN)
    local qty = 0
    local d = PC:DepthTable()[id]
    if d and d.list and #d.list > 0 then
        for _, step in ipairs(d.list) do if step.p <= cap then qty = qty + step.q else break end end
    else
        qty = math.max(e.listed or 1, 1)
    end
    if qty <= 0 then return PC.Buy:Say(("|cffff8040No %s at auction below what a vendor pays right now.|r"):format(e.r.name)) end
    PC.Buy:Start({ id = id, name = e.r.name, qty = qty }, false)
end

function UI:UpdateRecipes()
    -- Categories: every profession you have, with its skill level
    local names, seen, ranks = {}, {}, {}
    -- Only professions that make something (gathering ones like Skinning, Fishing and Archaeology have
    -- no recipes, so they'd just be empty). Mining stays if you know smelting recipes.
    local crafts = {}
    for _, r in pairs(PC.cdb.recipes) do crafts[r.prof] = true end
    for prof in pairs(PC.cdb.skipped or {}) do
        if #PC.cdb.skipped[prof] > 0 then crafts[prof] = true end
    end
    -- every profession you have, gathering ones too (Mining smelts; leveling help for the rest is coming)
    for _, prof in pairs(PC.cdb.professions) do
        ranks[prof.name] = prof
        if not seen[prof.name] then seen[prof.name] = true; names[#names + 1] = prof.name end
    end
    for _, r in pairs(PC.cdb.recipes) do
        if not seen[r.prof] then seen[r.prof] = true; names[#names + 1] = r.prof end
    end
    table.sort(names)
    table.insert(names, 1, "ALL")
    table.insert(names, 2, "BEST")
    table.insert(names, 3, "VENDOR")
    local special = { ALL = true, BEST = true, VENDOR = true }
    if not special[self.category] and not seen[self.category] then self.category = "ALL" end

    -- one row across the top; if the full names don't fit, the skill shows without its cap
    local function CatLabel(v, short)
        local label = (v == "ALL" and (short and "All" or "All professions")) or (v == "BEST" and "|TInterface\\Icons\\INV_Misc_Coin_01:14:14|t Best bets")
            or (v == "VENDOR" and "|TInterface\\Icons\\INV_Misc_Bag_10:14:14|t Vendor flips") or v
        local rk = ranks[v]
        if rk then
            local lvl, custom = PC:ProfLevel(rk)
            if custom then
                label = label .. ("  |cffffd100%d*|r"):format(lvl)
            elseif short then
                label = label .. ("  |cffffffff%d|r"):format(lvl)
            else
                label = label .. ("  |cffffffff%d/%d|r"):format(lvl, rk.max)
            end
        end
        return label
    end
    local function CatFlow(short, pad, gap)
        pad, gap = pad or 20, gap or 4
        local x = 0
        for i, b in ipairs(self.catButtons) do
            local v = names[i]
            if v then
                b.text:SetText(CatLabel(v, short))
                local w = math.ceil(b.text:GetStringWidth() or 60) + pad
                b:SetWidth(w)
                b:ClearAllPoints()
                b:SetPoint("LEFT", x, 0)
                x = x + w + gap
            end
        end
        return x - gap
    end
    -- still too wide with the short names (many professions): the buttons close up until the row fits
    self.catShort = CatFlow(false) > PW
    if self.catShort and CatFlow(true) > PW and CatFlow(true, 12, 2) > PW then CatFlow(true, 6, 0) end

    for i, b in ipairs(self.catButtons) do
        local v = names[i]
        if v then
            b.value = v
            local label = CatLabel(v, self.catShort)
            b.text:SetText(label)
            local on = (v == self.category)
            if on then
                b.bg:SetColorTexture(unpack(T.tanOn))
                b.text:SetTextColor(1, 1, 1)
            else
                b.bg:SetColorTexture(unpack(T.tanBg))
                b.text:SetTextColor(1, 0.82, 0)
            end
            b.edge:SetShown(on)
            b:Show()
        else
            b:Hide()
        end
    end

    -- Filter: "Only N%+ AH profit" and "Only N%+ V profit", each ticked box a condition (both ticked: both).
    -- Vendor flips are judged the vendor way only (the AH box isn't used there).
    local data = {}
    local onlyAH, onlyV, minPct = PC.db.onlyProfit, PC.db.onlyVProfit, PC:MinProfitPct()
    local vendorCat = self.category == "VENDOR"
    local onlyMin = onlyV or (onlyAH and not vendorCat)
    self.hiddenAfford, self.hiddenMin = 0, 0
    for _, e in ipairs(self.allEntries) do
        local keep, meets
        if self.category == "BEST" then
            keep, meets = e.score ~= nil, true
        elseif vendorCat then
            keep = e.vendorProfit and e.vendorProfit > 0
            meets = not onlyV or PC:MeetsMinV(e)
        else
            keep = (self.category == "ALL" or e.r.prof == self.category)
            meets = (not onlyAH or PC:MeetsMinAH(e)) and (not onlyV or PC:MeetsMinV(e))
        end
        if keep and self.search ~= "" and not e.r.name:lower():find(self.search, 1, true) then keep = false end
        if keep and onlyMin and not meets then
            keep = false
            self.hiddenMin = self.hiddenMin + 1
        end
        if keep and PC.db.onlyAffordable ~= false and not PC:CanAfford(e) then
            keep = false
            self.hiddenAfford = self.hiddenAfford + 1
        end
        if keep then data[#data + 1] = e end
    end
    if vendorCat then
        for _, e in ipairs(self:AHFlips()) do
            if self.search == "" or e.r.name:lower():find(self.search, 1, true) then
                if not onlyV or (e.profitPct or 0) >= minPct then data[#data + 1] = e
                else self.hiddenMin = self.hiddenMin + 1 end
            end
        end
    end

    -- Sort. Craftable and its totals are only worked out for every row when sorting by them.
    local s = self:SortState("recipes")
    local CRAFT_I = { craftable = 1, totalAH = 4, totalV = 5 }
    local function val(e, k)
        if k == "name" then return e.r.name:lower() end
        if k == "sell" then return e.ahFlip and e.sellAH or e.sell end -- (an AH flip: its price on the AH)
        if k == "vendorSell" then return e.vendorSell end
        local ci = CRAFT_I[k]
        if ci then
            local n, _, _, tAH, tV, _, _, nAH, nV = PC:Craftable(e)
            if ci == 1 then return n end
            if ci == 4 then return tAH end -- (none at a profit that way: its loss)
            return tV
        end
        return e[k]
    end
    UI.SortRows(data, s.key, s.dir, val, function(e) return e.r.name:lower() end)
    self.recipeData = data
    self:PaintHeaders(self.recipeHeaders, "recipes")
    -- sorted by something that isn't a column: say so
    self.sortNote = (s.key == "score" and "Sorted by best bet") or (s.key == "profit" and "Sorted by profit") or nil

    if not self.selected and data[1] then self.selected = data[1].id end
    self:UpdateRecipeRows()
end

-- Craftable and its totals for one row: "12", "~12" (an estimate), "0", n/a without prices
local GREY_DASH = "|cff888888-|r"
local function CraftableCells(e)
    local n, _, _, tAH, tV, _, est, nAH, nV = PC:Craftable(e)
    if not n then return PC:Money(nil), PC:Money(nil), PC:Money(nil) end
    local mark = est and "|cffffd100~|r" or ""
    -- each total counts the crafts that still profit that way; none do: the loss (never left blank)
    local function total(t) return t == nil and PC:Money(nil) or (mark .. PC:Money(t, true)) end
    return n == 0 and "|cff8888880|r" or (mark .. "|cffffffff" .. n .. "|r"), total(tAH), total(tV)
end
UI.CraftableCells = CraftableCells

function UI:UpdateRecipeRows()
    local data = self.recipeData or {}
    self.offset = math.min(math.max(self.offset, 0), math.max(#data - RECIPE_ROWS, 0))
    local vendorCat = self.category == "VENDOR"
    local plan = UI:PlanTable()
    local paid = PC.db.vendorPaid or {}

    for i, row in ipairs(self.recipeRows) do
        local e = data[i + self.offset]
        if e then
            row.entry = e
            local c = row.cell
            row.icon:SetTexture(ItemIcon(e.outID or e.r.output))
            local makes = UI.QualityTag(e.qualityUsed, e.r.outputs and #e.r.outputs, e.outID)
            if e.r.qty and e.r.qty ~= 1 then
                makes = makes .. (" |cff888888x%s|r"):format(e.r.qty % 1 == 0 and tostring(e.r.qty) or ("%.1f"):format(e.r.qty))
            end
            if e.ahFlip then makes = makes .. " |cff40c0ff(auction flip)|r" end -- (not a craft: bought on the AH, sold to a vendor)
            FitCell(row.name, ("|cffffffff%s|r%s"):format(e.r.name, makes)) -- white: grey looked "unavailable"; the arrows show skill-ups
            SetSkillArrows(row, e.r.diff)
            row.shop:SetShown(not e.ahFlip) -- (an AH flip isn't a recipe: clicking it buys it)
            row.quick:SetShown(not e.ahFlip)
            FitCell(c.cost, PC:Money(e.cost))
            -- orange "?" = that vendor price hasn't been seen paid yet
            local sure = paid[e.outID or e.r.output]
            -- one craft (all the items it makes), like Mats; an AH flip: its price on the AH
            FitCell(c.sell, PC:Money(e.ahFlip and e.sellAH or e.sell))
            FitCell(c.vendorSell, e.vendorSell and (PC:Money(e.vendorSell) .. (sure and "" or "|cffff8040?|r")) or PC:Money(nil))
            FitCell(c.ahProfit, PC:Money(e.ahProfit, true))
            -- V Profit in blue when that's where it sells
            local v = e.vendorProfit
            if v and v > 0 and (e.route == "Vendor" or vendorCat) then
                FitCell(c.vendorProfit, (sure and "|cff40c0ff" or "|cffff8040") .. PC:Money(v) .. "|r")
            else
                FitCell(c.vendorProfit, PC:Money(v, true))
            end
            local pct = e.profitPct
            if pct == nil then FitCell(c.profitPct, "|cff888888?|r")
            else
                local shown = pct >= 10000 and ">9999" or tostring(math.floor(pct + 0.5))
                FitCell(c.profitPct, (pct >= 0 and "|cff40ff40" or "|cffff5555") .. shown .. "%|r")
            end
            local n = e.listed
            if n == nil then FitCell(c.listed, "|cff888888?|r")
            elseif n <= 5 then FitCell(c.listed, "|cff40ff40" .. n .. "|r")
            elseif n <= 20 then FitCell(c.listed, "|cffffff00" .. n .. "|r")
            else FitCell(c.listed, "|cffff5555" .. n .. "|r") end
            local st = e.soldToday or 0
            if st > 0 then FitCell(c.soldToday, "|cff40ff40" .. st .. "|r")
            else FitCell(c.soldToday, e.noSalesToday and "|cffff80400|r" or "|cff8888880|r") end -- orange: not recommended for the AH
            local cn, tah, tv = CraftableCells(e)
            FitCell(c.craftable, cn); FitCell(c.totalAH, tah); FitCell(c.totalV, tv)
            row.sel:SetShown(e.id == self.selected)
            local inPlan = (plan[e.id] or 0) > 0 -- in your crafting plan
            row.multi:SetShown(inPlan)
            row.multiEdge:SetShown(inPlan)
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
    end

    local minText = ("%s%%"):format(PC:MinProfitPct())
    local msg = ""
    -- (said by what really hid the rows: a ticked box that hid nothing isn't blamed)
    local hidMin, hidAfford = (self.hiddenMin or 0) > 0, (self.hiddenAfford or 0) > 0
    local affordMsg = "Nothing here you can afford right now.\nUntick \"Can afford\" to see the rest."
    if #data == 0 then
        if not next(PC.cdb.recipes) then
            msg = "No recipes yet.\nOpen each of your profession windows once and they'll show up here."
        elseif self.category ~= "ALL" and PC.cdb.skipped and PC.cdb.skipped[self.category]
            and #PC.cdb.skipped[self.category] > 0 then
            msg = self.category .. " recipes make no item to sell, so they can't be priced.\nSee the Scanned items tab for details."
        elseif self.category == "BEST" then
            msg = ("No best bets yet.\nA best bet makes at least %s profit and, for auction, sold today at least half as many as are listed. Scan the Auction House to find some."):format(minText)
        elseif self.category == "VENDOR" then
            msg = hidMin and ("No vendor flips at %s+ Vendor profit right now.\nUntick \"Only %s+ Vendor profit\" to see smaller ones."):format(minText, minText)
                or hidAfford and affordMsg
                or "No vendor flips right now.\nNo recipe sells to a vendor for more than its materials cost, and nothing at auction is below what a vendor pays."
        elseif self.search ~= "" then
            msg = "No recipes match your search."
        elseif hidMin then
            local onlyAH, onlyV = PC.db.onlyProfit, PC.db.onlyVProfit
            local boxes = (onlyAH and onlyV) and ("\"Only %s+ Auction profit\" or \"Only %s+ Vendor profit\""):format(minText, minText)
                or ("\"Only %s+ %s profit\""):format(minText, onlyV and "V" or "AH")
            msg = ("Nothing here makes %s profit as ticked.\nScan the Auction House, or untick %s."):format(minText, boxes)
        elseif hidAfford then
            msg = affordMsg
        end
    end
    self.recipeEmpty:SetText(msg)
    -- one short line: [in plan] · how it's sorted · rows shown · what's hidden
    local parts = {}
    local nPlan = 0
    for _ in pairs(plan) do nPlan = nPlan + 1 end
    if nPlan > 0 then parts[#parts + 1] = ("|cff40a0ff%d in plan|r"):format(nPlan) end
    if self.sortNote and #data > 0 then parts[#parts + 1] = self.sortNote end
    if #data > 0 then
        parts[#parts + 1] = ("%d-%d of %d%s"):format(self.offset + 1, math.min(self.offset + RECIPE_ROWS, #data), #data,
            #data > RECIPE_ROWS and " (scroll)" or "")
    end
    local nAll, nShown = 0, 0
    for _ in pairs(PC.cdb.recipes) do nAll = nAll + 1 end
    for _ in pairs(PC:ShownRecipes()) do nShown = nShown + 1 end
    local hidden = {}
    if (self.hiddenMin or 0) > 0 then hidden[#hidden + 1] = ("%d under %s profit"):format(self.hiddenMin, minText) end
    if (self.hiddenAfford or 0) > 0 then hidden[#hidden + 1] = self.hiddenAfford .. " too pricey" end
    if nShown < nAll then hidden[#hidden + 1] = (nAll - nShown) .. " other expansions" end
    if #hidden > 0 then parts[#parts + 1] = "|cff888888hidden: " .. table.concat(hidden, ", ") .. "|r" end
    self.recipeCount:SetText(table.concat(parts, "  |cff666666·|r  "))
end

---------------------------------------------------------------------------
-- Tab 7: Settings (the same settings as in the game's AddOns options)
---------------------------------------------------------------------------
function UI:CreateSettingsTab(p)
    local box = Panel(p, 12, -60, PW, 10)
    box:ClearAllPoints()
    box:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -60)
    box:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -12, 62)
    local inner = CreateFrame("Frame", nil, box)
    inner:SetPoint("TOPLEFT", 6, -6)
    inner:SetPoint("BOTTOMRIGHT", -4, 6)
    if PC.Options and PC.Options.BuildInto then
        self.settingsInst = PC.Options:BuildInto(inner, false)
    end
    p:HookScript("OnShow", function()
        if UI.settingsInst and PC.Options then PC.Options:RefreshInstance(UI.settingsInst) end
    end)
end

---------------------------------------------------------------------------
-- Icon picker: choose the window's portrait from the game's own icons
---------------------------------------------------------------------------
local CUSTOM_ICON = "Interface\\AddOns\\" .. ADDON .. "\\Media\\Icon"          -- PC forged on the anvil (main icon)
local CLASSIC_ICON = "Interface\\AddOns\\" .. ADDON .. "\\Media\\IconClassic"   -- the original anvil + hammer
local DEFAULT_ICON = CUSTOM_ICON
UI.MINIMAP_ICON = CLASSIC_ICON -- the minimap button keeps the original icon
local ICON_CHOICES = {
    -- ProfitCrafter's own icons
    CUSTOM_ICON, CLASSIC_ICON,
    -- Profit
    "INV_Misc_Coin_01", "INV_Misc_Coin_02", "INV_Misc_Coin_03", "INV_Misc_Coin_04",
    "INV_Misc_Coin_05", "INV_Misc_Coin_06", "INV_Misc_Bag_10", "INV_Misc_Bag_07",
    "INV_Ingot_03", "INV_Ingot_06", "INV_Ingot_08", "INV_Box_01",
    "INV_Crate_01", "INV_Misc_Key_03", "INV_Misc_Gem_01", "INV_Misc_Ticket_Darkmoon_01",
    -- Crafting
    "Trade_BlackSmithing", "Trade_Tailoring", "Trade_Alchemy", "Trade_Engineering",
    "Trade_Mining", "Trade_Engraving", "Trade_Herbalism", "Trade_LeatherWorking",
    "INV_Hammer_20", "INV_Misc_Gear_01", "INV_Misc_Note_01", "INV_Scroll_03",
    "INV_Misc_Book_09", "INV_Fabric_Linen_01", "INV_Misc_Spyglass_02", "Ability_Repair",
}

-- WoW Forever: its own gold-framed logo is a choice too (only that build has it)
local FOREVER_ICON = "Interface\\AddOns\\" .. ADDON .. "\\Media\\IconForever"
if PC.FOREVER then table.insert(ICON_CHOICES, 3, FOREVER_ICON) end

local function IconPath(name)
    if name:find("\\", 1, true) then return name end -- already a full path (our own icon)
    return "Interface\\Icons\\" .. name
end

function UI:CurrentIcon()
    return IconPath((PC.db and PC.db.icon) or DEFAULT_ICON)
end

function UI:ApplyIcon()
    local f = self.f
    if self.mm then self.mm.icon:SetTexture(UI.MINIMAP_ICON) end -- minimap button: always the original icon
    if not f then return end
    local icon = IconPath((PC.db and PC.db.icon) or DEFAULT_ICON)
    if not self.usePortrait then return end
    if f.SetPortraitToAsset then
        f:SetPortraitToAsset(icon)
    elseif f.PortraitContainer and f.PortraitContainer.portrait and SetPortraitToTexture then
        SetPortraitToTexture(f.PortraitContainer.portrait, icon)
    end
end

function UI:CreateIconPicker()
    if self.picker then return end
    local cols, size, gap = 8, 40, 6
    local rows = math.ceil(#ICON_CHOICES / cols)
    local w = CreateFrame("Frame", "ProfitCrafterIconPicker", UIParent, "BasicFrameTemplateWithInset")
    self.picker = w
    w:SetSize(cols * (size + gap) + 30, rows * (size + gap) + 86)
    w:SetPoint("CENTER", 0, 40)
    w:SetFrameStrata("DIALOG")
    w:SetMovable(true)
    w:SetClampedToScreen(true)
    w:EnableMouse(true)
    w:RegisterForDrag("LeftButton")
    w:SetScript("OnDragStart", w.StartMoving)
    w:SetScript("OnDragStop", w.StopMovingOrSizing)
    w:Hide()
    tinsert(UISpecialFrames, "ProfitCrafterIconPicker")

    local title = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Pick an icon")
    Text(w, "GameFontDisableSmall", 16, -32, cols * (size + gap)):SetText(
        "First: ProfitCrafter's own icon. Then profit icons, then crafting icons. Click one to use it.")

    w.buttons = {}
    for i, name in ipairs(ICON_CHOICES) do
        local b = CreateFrame("Button", nil, w)
        b:SetSize(size, size)
        local c, r = (i - 1) % cols, math.floor((i - 1) / cols)
        b:SetPoint("TOPLEFT", 16 + c * (size + gap), -52 - r * (size + gap))
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints()
        b.icon:SetTexture(IconPath(name))
        b.sel = b:CreateTexture(nil, "OVERLAY")
        b.sel:SetPoint("TOPLEFT", -3, 3)
        b.sel:SetPoint("BOTTOMRIGHT", 3, -3)
        b.sel:SetColorTexture(1, 0.82, 0, 0.5)
        b.sel:SetDrawLayer("BACKGROUND")
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.25)
        b.name = name
        b:SetScript("OnEnter", function(btn)
            ShowTooltip(btn, { (i == 1 and "ProfitCrafter (PC on the anvil)") or (i == 2 and "ProfitCrafter classic (the minimap button)") or ("Icon #" .. i),
                "Click to use this as the ProfitCrafter icon." })
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:SetScript("OnClick", function(btn)
            PC.db.icon = btn.name
            UI:ApplyIcon()
            UI:UpdateIconPicker()
            PC.Print("Icon changed to #" .. i .. ".")
        end)
        w.buttons[i] = b
    end

    local reset = CreateFrame("Button", nil, w, "UIPanelButtonTemplate")
    reset:SetSize(120, 22)
    reset:SetPoint("BOTTOMLEFT", 14, 10)
    reset:SetText("Default icon")
    reset:SetScript("OnClick", function()
        PC.db.icon = nil
        UI:ApplyIcon()
        UI:UpdateIconPicker()
    end)
    w.note = w:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    w.note:SetPoint("LEFT", reset, "RIGHT", 10, 0)
end

function UI:UpdateIconPicker()
    local w = self.picker
    if not w then return end
    local current = PC.db.icon or DEFAULT_ICON
    for _, b in ipairs(w.buttons) do b.sel:SetShown(b.name == current) end
    w.note:SetText(self.usePortrait and "" or "Your game's window style has no portrait, so the icon won't show.")
end

function UI:ToggleIconPicker()
    self:Create()
    self:CreateIconPicker()
    self.picker:SetShown(not self.picker:IsShown())
    if self.picker:IsShown() then
        self.f:Show()
        self:UpdateIconPicker()
    end
end

-- Expansion + item ID lines
function UI.AddItemInfoLines(tip, itemID)
    local exp = UI.ExpansionName(itemID)
    if exp then tip:AddLine("|cffffd100Expansion:|r " .. exp, 1, 1, 1) end
    tip:AddLine("|cffffd100Item ID:|r " .. itemID, 1, 1, 1)
end

-- Every item tooltip in the game (bags, Auction House, chat links, vendors, loot...)
local function OnItemTooltip(tip, data)
    if UI.ownTip or PC.db.itemTipInfo == false then return end
    if tip.IsForbidden and tip:IsForbidden() then return end
    local id = data and data.id
    if not id and tip.GetItem then
        local _, link, linkID = tip:GetItem()
        id = linkID or (link and tonumber(link:match("item:(%d+)")))
    end
    if not id then return end
    tip:AddLine(" ")
    UI.AddItemInfoLines(tip, id)
    if tip.Show then tip:Show() end -- resize to fit the new lines
end

function UI:HookItemTooltips()
    if self.itemTipsHooked then return end
    self.itemTipsHooked = true
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tip, data)
            PC:Safe("item tooltip", OnItemTooltip, tip, data)
        end)
    else
        for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do
            if tip and tip.HookScript then
                tip:HookScript("OnTooltipSetItem", function(t) PC:Safe("item tooltip", OnItemTooltip, t) end)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Match the profession window: copy its real background/border art onto ProfitCrafter
-- (the art differs between clients, so this reads it from the window itself instead of guessing)
---------------------------------------------------------------------------
local function FirstArt(frame, depth)
    -- the first big texture on a frame: an atlas name or a file path, plus vertex color
    if not frame or depth > 3 then return nil end
    if frame.IsForbidden and frame:IsForbidden() then return nil end -- locked away from add-ons
    for _, region in ipairs({ frame.GetRegions and frame:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "Texture" and region.IsShown and region:IsShown() then
            local w = region:GetWidth() or 0
            if w > 200 then
                local atlas = region.GetAtlas and region:GetAtlas()
                local tex = region.GetTexture and region:GetTexture()
                if atlas or (tex and tex ~= "") then
                    local r, g, b, a = 1, 1, 1, 1
                    if region.GetVertexColor then r, g, b, a = region:GetVertexColor() end
                    return { atlas = atlas, texture = tex, color = { r, g, b, a } }
                end
            end
        end
    end
    for _, child in ipairs({ frame.GetChildren and frame:GetChildren() }) do
        local found = FirstArt(child, depth + 1)
        if found then return found end
    end
end

function UI:MatchProfessionWindow(quiet)
    local pf = ProfessionsFrame or TradeSkillFrame
    if not (pf and pf:IsShown()) then
        if not quiet then PC.Print("Open a profession window first, then /pc skin copies its look.") end
        return false
    end
    local src = (pf.CraftingPage and FirstArt(pf.CraftingPage, 0)) or FirstArt(pf, 0)
    if not src then
        if not quiet then PC.Print("Couldn't read that window's art.") end
        return false
    end
    PC.db.skin = src
    self:ApplySkin()
    if not quiet then PC.Print("ProfitCrafter now uses your profession window's background.") end
    return true
end

function UI:ApplySkin()
    local f, skin = self.f, PC.db and PC.db.skin
    if not f or not f.parchment then return end
    local bg = f.parchment
    if skin then
        local ok = false
        if skin.atlas and bg.SetAtlas then ok = pcall(bg.SetAtlas, bg, skin.atlas, false) end
        if not ok and skin.texture then ok = pcall(bg.SetTexture, bg, skin.texture) end
        if ok then
            bg:SetTexCoord(0, 1, 0, 1)
            if skin.color and bg.SetVertexColor then bg:SetVertexColor(unpack(skin.color)) end
            return
        end
    end
end

-- Re-show the tooltip of whatever row the mouse is on (after live listings arrive)
function UI.RefreshTip(row)
    if not row or not row.IsMouseOver or not row:IsMouseOver() then return end
    local onEnter = row.GetScript and row:GetScript("OnEnter")
    if onEnter then onEnter(row) end
end
PC.Depth.onItem = function()
    local owner = GameTooltip.GetOwner and GameTooltip:GetOwner()
    if owner then UI.RefreshTip(owner) end
end


-- Building blocks shared with the other window files (UIPlan.lua, UIPages.lua, News.lua)
UI.Parts = {
    HasTemplate = HasTemplate,
    Text = Text,
    CraftButton = CraftButton,
    Header = Header,
    Columns = Columns,
    FitCell = FitCell,
    HEAD_H = HEAD_H,
    LIST_Y = LIST_Y,
    PW = PW,
    RW = RW,
    HeaderStrip = HeaderStrip,
    ItemIcon = ItemIcon,
    Panel = Panel,
    ROW_H = ROW_H,
    RowText = RowText,
    SetSkillArrows = SetSkillArrows,
    ShowTooltip = ShowTooltip,
    SkillArrows = SkillArrows,
    Stripe = Stripe,
    T = T,
    ITEM_ROWS = ITEM_ROWS,
    ITEM_ROW_H = ITEM_ROW_H,
    QUESTION = QUESTION,
    STATUS_TEXT = STATUS_TEXT,
    RECENT_ROWS = RECENT_ROWS,
    StatStrip = StatStrip,
    CLICK_HINT = CLICK_HINT,
}
