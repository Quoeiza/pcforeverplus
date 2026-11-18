-- ProfitCrafter: settings
--   The same settings show in two places: the Settings tab in ProfitCrafter's own window, and the
--   game's settings (Game Menu > Options > AddOns). Three sections: General, Automation, and
--   Advanced (folded away until you open it).

local ADDON, ns = ...
local PC = ns.PC

local Options = {}
PC.Options = Options
Options.instances = {}

local COLLAPSED_H, EXPANDED_H = 1300, 2200

-- An On/Off switch (used for every on-or-off setting). Works like a checkbox for the code that
-- drives it: GetChecked/SetChecked, and onClick runs after it flips.
local function Toggle(parent, onClick)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(46, 20)
    if b.SetBackdrop then
        b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    end
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("CENTER", 0, 0)
    function b:SetChecked(v)
        self.on = v and true or false
        if self.SetBackdropColor then
            if self.on then
                self:SetBackdropColor(0.12, 0.5, 0.12, 1); self:SetBackdropBorderColor(0.4, 0.9, 0.4, 1)
            else
                self:SetBackdropColor(0.18, 0.18, 0.18, 1); self:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
            end
        end
        self.text:SetText(self.on and "ON" or "OFF")
        self.text:SetTextColor(self.on and 1 or 0.7, self.on and 1 or 0.7, self.on and 1 or 0.7)
    end
    function b:GetChecked() return self.on end
    b:SetScript("OnClick", function(btn)
        btn:SetChecked(not btn.on)
        if PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) or 856) end
        if onClick then onClick(btn) end
    end)
    b:SetChecked(false)
    return b
end
Options.Toggle = Toggle

local function Check(inst, panel, anchor, label, note, get, set)
    local cb = Toggle(panel)
    cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
    local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    text:SetText(label)
    local sub
    if note then
        sub = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        sub:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -2)
        sub:SetWidth(600)
        sub:SetJustifyH("LEFT")
        sub:SetText(note)
    end
    cb:SetScript("OnClick", function(btn)
        -- flips the setting itself (not whatever the switch happens to be showing), so a switch
        -- can never get stuck; if applying it hits a problem the setting is still saved
        local okGet, cur = pcall(get)
        local new = not (okGet and cur)
        if PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) or 856) end
        PC:Safe("setting: " .. label, set, new)
        local okNow, now = pcall(get)
        btn:SetChecked(okNow and now)
        Options:RefreshAll() -- keep the other copy (tab / game settings) in step
    end)
    cb.get = get
    inst.checks[#inst.checks + 1] = cb
    -- leave room for the note line under the label
    local spacer = CreateFrame("Frame", nil, panel)
    -- as tall as the note really is (a long note wraps onto more lines)
    local noteH = sub and sub.GetStringHeight and sub:GetStringHeight() or 0
    local lines = 0
    if note then for part in (note .. "\n"):gmatch("(.-)\n") do
        local plain = part:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        lines = lines + math.max(1, math.ceil(#plain / 100))
    end end
    local nLines = math.max(lines, math.floor(((noteH or 0) + 5) / 11))
    spacer:SetSize(1, note and math.max(14, nLines * 11 + 6) or 1)
    spacer:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 0, 0)
    return spacer
end

local function Heading(panel, anchor, text, gap)
    local h = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    h:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -(gap or 18))
    h:SetText(text)
    local line = panel:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.35)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -3)
    line:SetWidth(620)
    local spacer = CreateFrame("Frame", nil, panel)
    spacer:SetSize(1, 6)
    spacer:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -2)
    return spacer
end

-- Build one copy of the settings inside `root` (a scrolling area fills it)
function Options:BuildInto(root, withTitle)
    local inst = { checks = {}, expChecks = {}, root = root }
    self.instances[#self.instances + 1] = inst

    local tmpl = (C_XMLUtil and C_XMLUtil.GetTemplateInfo and C_XMLUtil.GetTemplateInfo("ScrollFrameTemplate")) and "ScrollFrameTemplate"
        or "UIPanelScrollFrameTemplate"
    local scroll = CreateFrame("ScrollFrame", nil, root, tmpl)
    scroll:SetPoint("TOPLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", -30, 4)
    local panel = CreateFrame("Frame", nil, scroll)
    panel:SetSize(660, COLLAPSED_H)
    scroll:SetScrollChild(panel)
    scroll:EnableMouseWheel(true)
    root:HookScript("OnSizeChanged", function(_, w) if w and w > 100 then panel:SetWidth(w - 40) end end)
    inst.scroll, inst.panel = scroll, panel

    local top = CreateFrame("Frame", nil, panel)
    top:SetSize(1, 1)
    top:SetPoint("TOPLEFT", 16, -8)
    local a = top
    if withTitle then
        local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", 16, -16)
        title:SetText(PC.NAME .. "  |cff888888v" .. PC.VERSION .. "|r")
        local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
        sub:SetText("Find profitable crafts and track your Auction House profit.")
        a = sub
    end

    -----------------------------------------------------------------------
    -- Grouped by what they're about; the Next task key first
    -----------------------------------------------------------------------
    a = Heading(panel, a, "General", withTitle and 18 or 4)
    -- Text size: small, normal or larger (the whole window scales with it, so nothing overlaps)
    do
        local row = CreateFrame("Frame", nil, panel)
        row:SetSize(620, 26)
        row:SetPoint("TOPLEFT", a, "BOTTOMLEFT", 0, -6)
        local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("LEFT", 0, 0)
        label:SetText("Text size")
        local btns, prev = {}, nil
        for i, sz in ipairs({ { "small", "Small" }, { "normal", "Normal" }, { "large", "Larger" } }) do
            local b = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            b:SetSize(92, 22)
            if prev then b:SetPoint("LEFT", prev, "RIGHT", 6, 0) else b:SetPoint("LEFT", label, "RIGHT", 16, 0) end
            b.value, b.label = sz[1], sz[2]
            b:SetText(sz[2])
            b:SetScript("OnClick", function(btn)
                PC.db.textSize = btn.value
                if PC.UI and PC.UI.ApplyTextSize then PC.UI:ApplyTextSize() end
                Options:RefreshAll()
            end)
            btns[i], prev = b, b
        end
        inst.checks[#inst.checks + 1] = {
            get = function() return PC.db.textSize or "normal" end,
            SetChecked = function(_, v)
                for _, b in ipairs(btns) do
                    b:SetText(b.value == v and ("|TInterface\\Buttons\\UI-CheckBox-Check:16:16|t " .. b.label) or b.label)
                end
            end,
        }
        local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        sub:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -1)
        sub:SetText("Makes ProfitCrafter's window and everything written in it smaller or larger.")
        local spacer = CreateFrame("Frame", nil, panel)
        spacer:SetSize(1, 18)
        spacer:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, 0)
        a = spacer
    end
    -- the key for Next task: a row like the others, with the key drawn as a keyboard key (click to change)
    local keyBtn = CreateFrame("Button", nil, panel, "BackdropTemplate")
    keyBtn:SetSize(46, 20)
    keyBtn:SetPoint("TOPLEFT", a, "BOTTOMLEFT", 0, -6)
    if keyBtn.SetBackdrop then
        keyBtn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        keyBtn:SetBackdropColor(0.05, 0.05, 0.05, 1)
        keyBtn:SetBackdropBorderColor(0.85, 0.85, 0.85, 1)
    end
    local hl = keyBtn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", 1, -1); hl:SetPoint("BOTTOMRIGHT", -1, 1)
    hl:SetColorTexture(1, 1, 1, 0.12)
    keyBtn.text = keyBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    keyBtn.text:SetPoint("CENTER", 0, 0)
    local keyLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    keyLabel:SetPoint("LEFT", keyBtn, "RIGHT", 8, 0)
    keyLabel:SetText("Bind a key for the Task Button")
    local function keyText()
        local k = PC.Next and PC.Next:KeyText()
        -- "PAGEDOWN" reads better as "Page Down", like a key's label
        -- same size as the other switches: long key names are shortened like a keyboard prints them
        local SHORT = { PAGEDOWN = "PgDn", PAGEUP = "PgUp", INSERT = "Ins", DELETE = "Del", BACKSPACE = "Bksp",
            ESCAPE = "Esc", ENTER = "Enter", SPACE = "Space", HOME = "Home", END = "End", SHIFT = "S", CTRL = "C", ALT = "A",
            BUTTON3 = "M3", BUTTON4 = "M4", BUTTON5 = "M5", MOUSEWHEELUP = "WhUp", MOUSEWHEELDOWN = "WhDn" }
        local shown = "SET"
        if k then
            local parts = {}
            for part in k:gmatch("[^-]+") do
                parts[#parts + 1] = SHORT[part] or (part:sub(1, 1) .. part:sub(2):lower())
            end
            shown = table.concat(parts, "-")
        end
        keyBtn.text:SetFontObject("GameFontHighlight")
        keyBtn.text:SetText(shown)
        if (keyBtn.text:GetStringWidth() or 0) > 40 then keyBtn.text:SetFontObject("GameFontHighlightSmall") end
        keyBtn.text:SetTextColor(k and 1 or 0.6, k and 1 or 0.6, k and 1 or 0.6)
    end
    keyBtn:SetScript("OnClick", function() if PC.Next then PC.Next:CaptureKey(function() Options:RefreshAll() end) end end)
    keyBtn:SetScript("OnShow", keyText)
    keyText()
    inst.keyText = keyText
    local keySpacer = CreateFrame("Frame", nil, panel)
    keySpacer:SetSize(1, 6)
    keySpacer:SetPoint("TOPLEFT", keyBtn, "BOTTOMLEFT", 0, 0)
    a = keySpacer
    a = Check(inst, panel, a, "Use Task Button",
        "The Task Button always does the next thing in your plan. Drag it where you want it.",
        function() return PC.db.nextBar ~= false end,
        function(v)
            PC.db.nextBar = v
            if v and PC.Next then PC.Next.dismissed = nil; PC.Next.wanted = true end -- turned on: show it
            if PC.Next then PC.Next:UpdateBar() end
        end)
    a = Check(inst, panel, a, "Show the task list under the Task Button",
        "On: the tasks appear underneath the button (a pull-down). Off: the list sits above the button.",
        function() return PC.db.dropDown == true end,
        function(v) if (PC.db.dropDown == true) ~= (v and true or false) and PC.Steps then PC.Steps:ToggleLayout(true) end end)


    -- (WoW Forever: sharing is always on, so there's nothing to set or show)
    if not PC.FOREVER then
    a = Check(inst, panel, a, "Share prices with other ProfitCrafter users",
        "Through the hidden MostlyNotBrokenAddons channel plus your guild and group, after each scan and when you open the window.",
        function() return PC.db.share ~= false end,
        function(v)
            PC.db.share = v
            if PC.Share then
                if v then
                    PC.Share:JoinChannel()
                    C_Timer.After(2, function() PC.Share:Request(true) end)
                else
                    PC.Share:LeaveChannel()
                end
            end
        end)
    -- Sharing works through hidden addon messages, so show here what it has done
    local shareBox = CreateFrame("Frame", nil, panel)
    shareBox:SetPoint("TOPLEFT", a, "BOTTOMLEFT", 0, -4)
    shareBox:SetSize(600, 20)
    local shareStatus = shareBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    shareStatus:SetPoint("TOPLEFT", 30, 0)
    shareStatus:SetWidth(580)
    shareStatus:SetJustifyH("LEFT")
    shareStatus:SetSpacing(2)
    inst.updateShare = function()
        local lines = PC.Share and PC.Share:StatusLines() or {}
        while #lines > 6 do table.remove(lines) end
        shareStatus:SetText(table.concat(lines, "\n"))
        shareBox:SetHeight(math.max(#lines, 1) * 13 + 2) -- one line each (no extra gap under it)
    end
    inst.updateShare()
    a = shareBox
    end
    a = Check(inst, panel, a, "Play sounds",
        "A short game sound when something worth knowing happens: gold from sales, a plan finished, not enough gold, a warning.",
        function() return PC.db.sounds ~= false end,
        function(v) PC.db.sounds = v; if v then PC:Sound("sold") end end)

    a = Heading(panel, a, "Auction House")
    a = Check(inst, panel, a, "Scan automatically when the Auction House opens",
        "Checks prices for everything your recipes use. You can always click Scan auctions yourself.",
        function() return PC.db.autoScan ~= false end,
        function(v) PC.db.autoScan = v end)
    a = Check(inst, panel, a, "Open the window beside the Auction House",
        "Off: the Task Button does the work on its own; open the window with the minimap button or /pc when you want it.",
        function() return PC.db.openOnAH == true end,
        function(v) PC.db.openOnAH = v end)
    a = Check(inst, panel, a, "Buy in one click",
        "Buy (or the Task Button) gets the Auction House's price and buys at once if the item is still profitable. Off, or if the game won't allow it: the first click gets the price, the second buys.",
        function() return PC.db.autoConfirm ~= false and not PC.db.confirmNeedsClick end,
        function(v) PC.db.autoConfirm = v; if v then PC.db.confirmNeedsClick = nil end end)
    a = Check(inst, panel, a, "Collect auction purchases and sale gold from the mail",
        "Only Auction House mail: everything else in your mailbox is left alone.",
        function() return PC.db.autoMail ~= false end,
        function(v) PC.db.autoMail = v end)

    a = Heading(panel, a, "Crafting and plans")
    local function profitChanged()
        if PC.UI then PC.UI.allEntries = nil end
        PC:ForgetStopList()
        PC:RefreshUI()
    end
    a = Check(inst, panel, a, "Only recommend auction crafts that sold in the last day",
        "Best bets, Make me gold and Have materials skip auction crafts with no sales today. Vendor flips and disenchanting are unaffected.",
        function() return PC.db.needSalesToday ~= false end,
        function(v) PC.db.needSalesToday = v; profitChanged() end)
    a = Check(inst, panel, a, "Open the window beside my profession window",
        "Off: the Task Button crafts from the plan on its own; open the window when you want it.",
        function() return PC.db.dockProf == true end,
        function(v) PC.db.dockProf = v end)
    a = Check(inst, panel, a, "Use what's in my bank",
        "On: your bank counts towards plans and profits, and a bank trip collects what the plan needs. Off: the bank is ignored entirely. Nothing in it is counted, taken out or stored.",
        function() return PC:UseBank() end,
        function(v)
            PC.db.useBank = v
            PC:ForgetStopList()
            if PC.UI then PC.UI.allEntries = nil end
            PC:RefreshUI()
        end)
    a = Check(inst, panel, a, "Make materials yourself when that's cheaper",
        "Bolts of cloth, bars, inks: when the plan needs one and making it costs less than buying it, the plan buys the raw materials and crafts it first.",
        function() return PC.cdb.vertical ~= false end,
        function(v) PC.cdb.vertical = v; PC._omap = nil; if PC.UI then PC.UI.allEntries = nil end; PC:RefreshUI() end)
    a = Check(inst, panel, a, "Make enchanting dust by crafting greens and disenchanting them",
        "Only when disenchanting it yourself works out cheaper than buying the dust: at least a quarter cheaper, since disenchant results vary. No price to compare against: it buys the dust. Off: always buy the dust.",
        function() return PC.db.deForMats ~= false end,
        function(v) PC.db.deForMats = v; if PC.UI then PC.UI.allEntries = nil end; PC:RefreshUI() end)
    a = Check(inst, panel, a, "Learn from my results",
        "Items that keep coming back unsold get a smaller batch and a slightly deeper undercut; recipes you keep unticking and items you had to purge rank lower in Make me gold; a skipped undercut check is offered less often. /pc learned shows what it has learned.",
        function() return PC.db.learn ~= false end,
        function(v) PC.db.learn = v; if PC.UI then PC.UI.allEntries = nil end; PC:RefreshUI() end)

    a = Heading(panel, a, "Vendors")
    a = Check(inst, panel, a, "Buy plan materials at vendors automatically",
        "Only what's cheaper there than at auction, and never over your spending limit.",
        function() return PC.db.autoVendorBuy ~= false end,
        function(v) PC.db.autoVendorBuy = v end)
    a = Check(inst, panel, a, "Sell junk at vendors",
        "Grey items, sold the moment you talk to a merchant. Left to Scrap when it's installed.",
        function() return PC.db.autoJunk ~= false end,
        function(v) PC.db.autoJunk = v end)
    a = Check(inst, panel, a, "Sell leftover materials back to a vendor",
        "Off: leftover materials go in your bank and the next craft takes them back out. On: the next vendor buys the extras back (for less than you paid).",
        function() return PC.db.sellLeftovers == true end,
        function(v)
            if not v then PC.db.sellLeftovers = false; PC:RefreshUI() return end
            -- turning it on: warn first (the standard pop-up); it only goes on from there
            local Popup = PC.UI and PC.UI.Popup
            if not Popup then PC.db.sellLeftovers = true; PC:RefreshUI() return end
            Options.leftoverPopup = Options.leftoverPopup or Popup.New("ProfitCrafterLeftoverWarn")
            Options.leftoverPopup:Open({
                title = "Sell leftovers to a vendor?", sub = "Items may be sold at a loss", subColor = { 1, 0.82, 0 },
                sections = { { lines = {
                    "Vendors pay much less than you paid for most materials, so leftovers sold back usually lose gold.",
                    "Off, they go in your bank and the next craft takes them back out at no loss.",
                }, bullets = false } },
                buttons = {
                    { text = "Turn on", onClick = function() PC.db.sellLeftovers = true; Options:RefreshAll(); PC:RefreshUI() end },
                    { text = "Cancel", onClick = function() Options:RefreshAll() end },
                },
                fit = true,
            })
        end)

    a = Heading(panel, a, "Travel and directions")
    -- one switch for all of it (map pin, arrows, NPC star, quickest route, Hearthstone, learning places)
    a = Check(inst, panel, a, "Plan my route for me",
        "Points the way to each stop (an arrow on screen and on the minimap, a star over the NPC), picks the quickest way there (walking, flights, portals, boats, your Hearthstone and teleports) and learns places as you play.",
        function() return PC.db.mapPins ~= false end,
        function(v)
            PC.db.mapPins = v
            if not v and PC.Places then PC.Places:ClearPin() end
            if PC.Places and PC.Places.TickArrow then PC.Places:TickArrow() end
            PC:RefreshUI()
        end)
    a = Check(inst, panel, a, "Fly automatically",
        "When you talk to a flight master and your route needs a flight, take it for you.",
        function() return PC.db.autoFly == true end,
        function(v) PC.db.autoFly = v end)
    a = Check(inst, panel, a, "Show the flight line on flights",
        "A gold line by the Task Button with the time left. Hidden while another flight timer is showing (EllesmereUI's flight bar, Forever++, Leatrix Plus, InFlight).",
        function() return PC.db.flightLine ~= false end,
        function(v)
            PC.db.flightLine = v
            local F = PC.FlightLine
            if not v and F and F.frame then F.frame:Hide() end
        end)

    a = Heading(panel, a, "Interface")
    a = Check(inst, panel, a, "Show the minimap button",
        "Left-click opens ProfitCrafter, right-click scans, drag to move it.",
        function() return not (PC.db.minimap and PC.db.minimap.hide) end,
        function(v)
            PC.db.minimap = PC.db.minimap or {}
            PC.db.minimap.hide = not v
            if PC.UI and PC.UI.UpdateMinimapButton then PC.UI:UpdateMinimapButton() end
        end)


    -----------------------------------------------------------------------
    -- Advanced (folded away until opened)
    -----------------------------------------------------------------------
    -- Advanced mode: a switch like the others. On shows the advanced settings below (scrolled to)
    -- and every tab; off goes back to the simple view.
    -- set apart in its own gold-edged box so it stands out
    local advBox = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    advBox:SetPoint("TOPLEFT", a, "BOTTOMLEFT", -6, -24)
    advBox:SetSize(640, 52)
    if advBox.SetBackdrop then
        advBox:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        advBox:SetBackdropColor(0.18, 0.13, 0.04, 0.85)
        advBox:SetBackdropBorderColor(0.85, 0.7, 0.25, 1)
    end
    local advBtn = Toggle(panel)
    advBtn:SetSize(56, 24)
    advBtn:SetPoint("TOPLEFT", advBox, "TOPLEFT", 12, -14)
    advBtn:SetFrameLevel(advBox:GetFrameLevel() + 2)
    inst.advBtn = advBtn
    local advLabel = advBox:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    advLabel:SetPoint("BOTTOMLEFT", advBtn, "RIGHT", 10, 1)
    advLabel:SetText("Advanced Mode")
    local advNote = advBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    advNote:SetPoint("TOPLEFT", advLabel, "BOTTOMLEFT", 0, -3)
    advNote:SetWidth(540)
    advNote:SetJustifyH("LEFT")
    advNote:SetText("Shows the advanced settings and every tab (Items, Sell, Learn, P&L, History).")
    -- the advanced settings sit inside the same box, which grows to hold them
    local adv = CreateFrame("Frame", nil, panel)
    adv:SetPoint("TOPLEFT", advBox, "TOPLEFT", 14, -58)
    adv:SetSize(616, EXPANDED_H - COLLAPSED_H)
    adv:SetFrameLevel(advBox:GetFrameLevel() + 2)
    inst.adv = adv
    local function showAdv(open)
        adv:SetShown(open)
        if not open then advBox:SetHeight(52) end
        advBtn:SetChecked(open)
        panel:SetHeight(open and EXPANDED_H or COLLAPSED_H)
        -- then fit it to what's really there (so the last setting can always be scrolled to)
        if inst.fitHeight then
            if C_Timer and C_Timer.After then C_Timer.After(0, inst.fitHeight) else inst.fitHeight() end
        end
    end
    advBtn:SetScript("OnClick", function()
        local on = PC.db.mode ~= "advanced"
        Options:SetAdvanced(on)
        if on then
            -- bring the advanced settings into view
            local function jump()
                local top, at = panel:GetTop(), adv:GetTop()
                if top and at and scroll.SetVerticalScroll then
                    local max = scroll.GetVerticalScrollRange and scroll:GetVerticalScrollRange() or (top - at)
                    scroll:SetVerticalScroll(math.max(0, math.min(top - at - 30, max or (top - at))))
                end
            end
            if C_Timer and C_Timer.After then C_Timer.After(0.05, jump) else jump() end
        end
    end)
    inst.showAdv = showAdv

    local b = CreateFrame("Frame", nil, adv)
    b:SetSize(1, 1)
    b:SetPoint("TOPLEFT", 0, 0)
    b = Check(inst, adv, b, "Show ProfitCrafter messages in their own chat tab",
        "A \"ProfitCrafter\" chat tab collects everything the addon says (buying, selling, crafting), so it doesn't get lost in General. Off: messages go to your main chat.",
        function() return PC.db.ownChat == true end,
        function(v) PC.db.ownChat = v; PC._chat = nil; if v then PC:EnsureChatTab() end end)
    b = Check(inst, adv, b, "Craft from the Task Button without the profession window",
        "The button opens the profession out of sight, starts the craft and closes it. Turn off if your game stops crafting when the window closes.",
        function() return PC.db.quickCraftClose == true end,
        function(v) PC.db.quickCraftClose = v; PC.db.quickCraftHide = v end)
    b = Check(inst, adv, b, "Price alerts",
        "Alt-click any item in ProfitCrafter to get a note and a sound when it's at or below a price you pick.",
        function() return PC.db.alertsOn ~= false end,
        function(v) PC.db.alertsOn = v end)
    b = Check(inst, adv, b, "Sell vendor flips automatically",
        "Crafted items from your plan that a vendor pays more for than the Auction House.",
        function() return PC.db.autoFlips ~= false end,
        function(v) PC.db.autoFlips = v end)
    b = Check(inst, adv, b, "Keep stock topped up",
        "On the Sell tab, set Keep for an item: your plan adds crafts whenever you have fewer (within your spending limit).",
        function() return PC.db.autoRestock == true end,
        function(v) PC.db.autoRestock = v; if v and PC.Sell then PC.Sell:Restock() end end)
    b = Check(inst, adv, b, "Read live listings for materials after each scan",
        "Checks how many are for sale at each price, so buying a lot is priced right (the cheapest ones run out). Adds a little time to each scan.",
        function() return PC.db.depthScan ~= false end,
        function(v) PC.db.depthScan = v end)
    b = Check(inst, adv, b, "Show the price ticker under the window's title bar",
        "Materials moving 5%+ from their usual price, with good volume. Hover pauses it, click shows the price graph.",
        function() return PC.db.tickerWindow ~= false end,
        function(v) PC.db.tickerWindow = v; if PC.Ticker then PC.Ticker:Apply() end end)
    b = Check(inst, adv, b, "Show a price ticker across the whole screen",
        "Same ticker, across the full width of your screen even when ProfitCrafter is closed. Drag it up or down while unlocked.",
        function() return PC.db.tickerScreen == true end,
        function(v) PC.db.tickerScreen = v; if PC.Ticker then PC.Ticker:Apply() end end)
    b = Check(inst, adv, b, "Lock the screen ticker in place",
        "Unlock to drag it somewhere else (it shows a blue highlight while unlocked).",
        function() return PC.db.tickerLocked == true end,
        function(v) PC.db.tickerLocked = v; if PC.Ticker then PC.Ticker:Apply() end end)
    b = Check(inst, adv, b, "Show expansion and item ID on every item tooltip",
        "Adds two lines to item tooltips everywhere: bags, Auction House, chat links, vendors.",
        function() return PC.db.itemTipInfo ~= false end,
        function(v) PC.db.itemTipInfo = v end)

    local iconBtn = CreateFrame("Button", nil, adv, "UIPanelButtonTemplate")
    iconBtn:SetSize(170, 24)
    iconBtn:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 2, -14)
    iconBtn:SetText("Change addon icon")
    iconBtn:SetScript("OnClick", function() if PC.UI then PC.UI:ToggleIconPicker() end end)

    -- Chat commands: the handy ones, under the icon button
    local cmdTitle = adv:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cmdTitle:SetPoint("TOPLEFT", iconBtn, "BOTTOMLEFT", -2, -20)
    cmdTitle:SetText("Primary chat commands")
    local cmds = {
        { "/pc", "Show or hide the window" },
        { "/pc help", "List all chat commands available for this addon" },
        { "/pc status", "Check that everything is working" },
        { "/pc scan", "Check auction prices for your recipes (the Auction House must be open)" },
        { "/pc config", "Open settings" },
    }
    if PC.FOREVER then
        cmds[#cmds + 1] = { "/pc bartering 0, 1, 2 or auto", "Set your bartering points (auto: read at vendors)" }
    end
    local lastCmd = cmdTitle
    for i, c in ipairs(cmds) do
        local k = adv:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        k:SetPoint("TOPLEFT", lastCmd, "BOTTOMLEFT", 0, i == 1 and -6 or -4)
        k:SetText("|cffffd100" .. c[1] .. "|r")
        local d = adv:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        d:SetPoint("TOPLEFT", k, "TOPLEFT", 190, 0)
        d:SetText(c[2])
        lastCmd = k
    end
    inst.cmdLast = lastCmd

    -- Which expansions to scan and show (not on WoW Forever: there's only Classic)
    if not PC.FOREVER then
        -- Which expansions to scan and show
        local expTitle = adv:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        expTitle:SetPoint("TOPLEFT", inst.cmdLast, "BOTTOMLEFT", 0, -20)
        expTitle:SetText("Expansions to scan and show")
        local expNote = adv:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        expNote:SetPoint("TOPLEFT", expTitle, "BOTTOMLEFT", 0, -3)
        expNote:SetWidth(600)
        expNote:SetJustifyH("LEFT")
        expNote:SetText("Recipes whose crafted item is from an expansion turned off are left out of scans and hidden from every list. Their prices are kept.")
        local function onExpChanged()
            Options:RefreshAll()
            PC:RefreshUI()
        end
        for i, x in ipairs(PC:ExpansionList()) do
            local col, rowN = (i - 1) % 3, math.floor((i - 1) / 3)
            local cb = Toggle(adv, function(btn)
                PC.db.hideExp[btn.expID] = (not btn:GetChecked()) or nil
                onExpChanged()
            end)
            cb:SetPoint("TOPLEFT", expNote, "BOTTOMLEFT", col * 200, -6 - rowN * 24)
            local t = adv:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            t:SetPoint("LEFT", cb, "RIGHT", 6, 0)
            t:SetText(x.name)
            cb.expID = x.id
            inst.expChecks[#inst.expChecks + 1] = cb
        end
        local function setAll(fn)
            for _, cb in ipairs(inst.expChecks) do
                PC.db.hideExp[cb.expID] = (not fn(cb.expID)) or nil
            end
            onExpChanged()
        end
        local nRows = math.ceil(#inst.expChecks / 3)
        local allBtn = CreateFrame("Button", nil, adv, "UIPanelButtonTemplate")
        allBtn:SetSize(110, 22)
        allBtn:SetPoint("TOPLEFT", expNote, "BOTTOMLEFT", 2, -12 - nRows * 24)
        allBtn:SetText("All")
        allBtn:SetScript("OnClick", function() setAll(function() return true end) end)
        local newestBtn = CreateFrame("Button", nil, adv, "UIPanelButtonTemplate")
        newestBtn:SetSize(130, 22)
        newestBtn:SetPoint("LEFT", allBtn, "RIGHT", 8, 0)
        newestBtn:SetText("Newest only")
        newestBtn:SetScript("OnClick", function()
            local newest = inst.expChecks[#inst.expChecks] and inst.expChecks[#inst.expChecks].expID
            if GetExpansionLevel then
                local ok, lvl = pcall(GetExpansionLevel)
                if ok and type(lvl) == "number" then newest = lvl end
            end
            setAll(function(id) return id == newest end)
        end)
        inst.allBtn, inst.newestBtn = allBtn, newestBtn
    end

    showAdv(PC.db.mode == "advanced")
    -- the panel is as tall as its settings: measured from the top to the last thing shown
    inst.lastAdv = inst.allBtn or inst.cmdLast or iconBtn
    -- (the positions only exist once the game has laid the page out: keep trying for a moment)
    local tries = 0
    inst.fitHeight = function()
        local top = panel:GetTop()
        -- open: the box grows down to just past the last advanced setting
        if adv:IsShown() then
            local bt, lb = advBox:GetTop(), inst.lastAdv and inst.lastAdv:GetBottom()
            if bt and lb and bt > lb then advBox:SetHeight(bt - lb + 16) else bt = nil end
            if not bt then
                if tries < 20 and C_Timer and C_Timer.After then tries = tries + 1; C_Timer.After(0.1, inst.fitHeight) end
                return
            end
        end
        local bottom = advBox:GetBottom()
        if top and bottom and top > bottom then
            tries = 0
            panel:SetHeight(top - bottom + 30)
        elseif tries < 20 and C_Timer and C_Timer.After then
            tries = tries + 1
            C_Timer.After(0.1, inst.fitHeight)
        end
    end
    root:HookScript("OnShow", function() Options:RefreshInstance(inst); inst.fitHeight() end)
    scroll:HookScript("OnShow", function() if C_Timer and C_Timer.After then C_Timer.After(0, inst.fitHeight) end end)
    return inst
end

-- Advanced mode = the advanced settings shown + every tab
function Options:SetAdvanced(on)
    PC.db.mode = on and "advanced" or "simple"
    for _, i in ipairs(self.instances) do i.showAdv(on) end
    if PC.UI and PC.UI.LayoutTabs then PC.UI:LayoutTabs() end
    PC:RefreshUI()
end

function Options:RefreshInstance(inst)
    if not PC.db then return end
    -- each on its own: one that can't be read never stops the rest from showing right
    for _, cb in ipairs(inst.checks) do
        local ok, v = pcall(cb.get)
        if ok then pcall(cb.SetChecked, cb, v) end
    end
    for _, cb in ipairs(inst.expChecks) do cb:SetChecked(not PC.db.hideExp[cb.expID]) end
    if inst.updateShare then inst.updateShare() end
    if inst.keyText then inst.keyText() end
    inst.showAdv(PC.db.mode == "advanced")
end

function Options:RefreshAll()
    for _, inst in ipairs(self.instances) do self:RefreshInstance(inst) end
end

-- The game's settings page (Game Menu > Options > AddOns)
function Options:Build()
    if self.panel then return end
    local root = CreateFrame("Frame")
    root.name = PC.NAME
    self.panel = root
    local inst = self:BuildInto(root, true)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(root, PC.NAME)
        Settings.RegisterAddOnCategory(category)
        self.category = category
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(root)
    end
end

-- /pc config: the Settings tab in ProfitCrafter's own window
function Options:Open()
    self:Build()
    if PC.UI and PC.UI.OpenTab then
        PC.UI:OpenTab(7)
        return
    end
    self:OpenGameSettings()
end

function Options:OpenGameSettings()
    self:Build()
    if Settings and Settings.OpenToCategory and self.category then
        local id = self.category.GetID and self.category:GetID() or self.category.ID
        Settings.OpenToCategory(id)
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(self.panel)
        InterfaceOptionsFrame_OpenToCategory(self.panel) -- opening twice is a known fix for the old panel
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function() PC:Safe("settings page", Options.Build, Options) end)
