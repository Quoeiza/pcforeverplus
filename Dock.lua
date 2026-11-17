-- ProfitCrafter: Auction House tab + minimap button
--   * When the Auction House opens, ProfitCrafter attaches to its right side.
--   * No tab on the AH: use the minimap button or /pc to show/hide it while the AH is open.
--   * Away from the AH, ProfitCrafter opens as its own window.
--   * A draggable minimap button: left-click opens/closes, right-click scans (at the AH).

local ADDON, ns = ...
local PC = ns.PC
local UI = PC.UI


---------------------------------------------------------------------------
-- Auction House: ProfitCrafter attaches to the right side of the AH window
-- (beside it, not on top, so it works alongside Auctionator and other AH addons)
---------------------------------------------------------------------------
local function AH() return AuctionHouseFrame end

function UI:CanEmbed()
    return AH() ~= nil
end

local function SelectTab(tab, on)
    if not tab then return end
    if on then
        if PanelTemplates_SelectTab then PanelTemplates_SelectTab(tab) else tab:LockHighlight() end
    else
        if PanelTemplates_DeselectTab then PanelTemplates_DeselectTab(tab) else tab:UnlockHighlight() end
    end
end

-- Every tab along the bottom of the AH, including ones other addons added (like Auctionator's)
function UI:AHTabs()
    local ah = AH()
    local list = {}
    if ah and ah.Tabs and #ah.Tabs > 0 then
        for _, t in ipairs(ah.Tabs) do if t ~= self.ahTab then list[#list + 1] = t end end
    else
        for _, n in ipairs({ "AuctionHouseFrameBuyTab", "AuctionHouseFrameSellTab", "AuctionHouseFrameAuctionsTab" }) do
            if _G[n] then list[#list + 1] = _G[n] end
        end
    end
    return list
end

-- Show ProfitCrafter attached to the right side of the Auction House
function UI:ShowInAH()
    self:Create()
    local ah = AH()
    local f = self.f
    if not ah then
        f:Show()
        return
    end
    self.docked = true
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", ah, "TOPRIGHT", 6, 0)
    f:SetSize(UI.W or 780, UI.H or 540)
    f:SetFrameStrata("HIGH")
    f:Show()
    f:Raise()
    SelectTab(self.ahTab, true)
    self:Refresh()
end

function UI:UpdateNav() end

-- When the window closes, un-highlight our tab and let it open normally next time
function UI:OnWindowHidden()
    if self.docked then
        self.docked = false
        SelectTab(self.ahTab, false)
        if self.f then
            self.f:ClearAllPoints()
            self.f:SetPoint("CENTER")
        end
    end
end

function UI:OnAHShow()
    self:Create()
    if self:CanEmbed() then
        -- (no tab on the AH itself: open/close with the minimap button, /pc, or the X)
        if PC.db.openOnAH == true or self.f:IsShown() then self:ShowInAH() end
    else
        -- No modern AH window in this game version: open beside the old one
        local f = self.f
        f:ClearAllPoints()
        local old = AuctionFrame
        if old then f:SetPoint("TOPLEFT", old, "TOPRIGHT", 10, 0) else f:SetPoint("CENTER") end
        if PC.db.openOnAH == true then f:Show() end
    end
end

function UI:OnAHClosed()
    if self.f and self.docked then self.f:Hide() end
    SelectTab(self.ahTab, false)
end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------
function UI:PlaceMinimapButton()
    local b = self.mm
    if not b or not Minimap then return end
    local angle = math.rad((PC.db.minimap and PC.db.minimap.angle) or 210)
    local r = (Minimap:GetWidth() or 140) / 2 + 5
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

function UI:UpdateMinimapButton()
    if not self.mm then return end
    self.mm:SetShown(not (PC.db.minimap and PC.db.minimap.hide))
    self:PlaceMinimapButton()
end

function UI:CreateMinimapButton()
    if self.mm or not Minimap then return end
    PC.db.minimap = PC.db.minimap or {}

    local b = CreateFrame("Button", "ProfitCrafterMinimapButton", Minimap)
    self.mm = b
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexture(UI.MINIMAP_ICON or self:CurrentIcon()) -- keeps the original icon
    if b.CreateMaskTexture then
        local mask = b:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(icon)
        icon:AddMaskTexture(mask)
    end
    b.icon = icon

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            if PC.ahOpen then PC:StartScan() else PC.Print("Open the Auction House to scan.") end
        else
            UI:Toggle()
        end
    end)
    b:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
        GameTooltip:SetText(PC.NAME)
        -- how many players are online with this add-on (you included; the shared data counts them)
        local mnb = _G.MostlyNotBroken
        if type(mnb) == "table" and type(mnb.OnlineCount) == "function" then
            local ok, c, counting = pcall(mnb.OnlineCount, mnb, PC.NAME)
            if ok and c then
                GameTooltip:AddLine(("%d %s %s online"):format(c, PC.NAME, c == 1 and "user" or "users"), 0.4, 1, 0.4)
                if counting then GameTooltip:AddLine("(still counting: it takes a few minutes after you log in)", 0.6, 0.6, 0.6) end
            end
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnDragStart", function(btn)
        btn:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            px, py = px / scale, py / scale
            PC.db.minimap.angle = math.deg(math.atan2(py - my, px - mx))
            UI:PlaceMinimapButton()
        end)
    end)
    b:SetScript("OnDragStop", function(btn) btn:SetScript("OnUpdate", nil) end)

    self:UpdateMinimapButton()
end

-- Retail's addon menu (the puzzle-piece button by the minimap) can open it too
function ProfitCrafter_OnCompartmentClick() UI:Toggle() end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
    PC:Safe("minimap button", UI.CreateMinimapButton, UI)
    PC:Safe("item tooltips", UI.HookItemTooltips, UI)
end)
