-- Cool Loot Tracker - TBC Classic Anniversary Edition
-- Refactored with dynamic pricing system

local ADDON_NAME = "CoolLootTracker"
local CLT = CreateFrame("Frame")
CLT:RegisterEvent("ADDON_LOADED")
CLT:RegisterEvent("CHAT_MSG_LOOT")
CLT:RegisterEvent("CHAT_MSG_MONEY")
CLT:RegisterEvent("QUEST_TURNED_IN")
CLT:RegisterEvent("PLAYER_LOGOUT")
CLT:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
CLT:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
CLT:RegisterEvent("PLAYER_ENTERING_WORLD")

-- Database
CoolLootTrackerDB = CoolLootTrackerDB or {
    lootLog = {},
    sessionStart = time(),
    minimapButton = {
        hide = false,
        position = 45
    },
    windowPosition = {},
    emaGPH = 0,  -- Exponential Moving Average for GPH
    oldMoney = 0,  -- Track money for interaction pausing
    filterGreyItems = false,  -- Filter out poor quality items
    -- Per-quality price sources: 'vendor', 'auction', or 'best' (prefer auction, fallback to vendor)
    priceByQuality = {
        [0] = "vendor",  -- Poor: vendor
        [1] = "best",    -- Common: best available
        [2] = "best",    -- Uncommon: best available
        [3] = "best",    -- Rare: best available
        [4] = "best",    -- Epic: best available
        [5] = "best"     -- Legendary: best available
    },
    -- Separate tracking for different money sources
    moneyCash = 0,   -- Raw money from loot
    moneyQuests = 0  -- Money from quest rewards
}

local db = CoolLootTrackerDB

-- Interaction pausing state
local interactionPaused = false

-- Helper function to create frames with backdrop support for TBC
local function CreateFrameWithBackdrop(frameType, name, parent, template)
    local frame = CreateFrame(frameType, name, parent, template)
    if not frame.SetBackdrop then
        Mixin(frame, BackdropTemplateMixin)
    end
    return frame
end

-- Pricing System with improved caching
local PriceCache = {}
local ItemInfoCache = {}
local CACHE_TTL = 60 * 60  -- 60 minutes for price cache
local ITEM_INFO_CACHE_TTL = 300  -- 5 minutes for item info cache

local function GetCachedItemInfo(itemLink)
    local cached = ItemInfoCache[itemLink]
    if cached and (time() - cached.timestamp) < ITEM_INFO_CACHE_TTL then
        return cached.name, cached.texture, cached.sellPrice
    end
    return nil
end

local function SetCachedItemInfo(itemLink, name, texture, sellPrice)
    ItemInfoCache[itemLink] = {
        name = name,
        texture = texture,
        sellPrice = sellPrice,
        timestamp = time()
    }
end

local function GetPrices(itemLink)
    if not itemLink then return 0, 0 end
    
    -- Check price cache first (valid for 60 minutes)
    local cached = PriceCache[itemLink]
    if cached and (time() - cached.timestamp) < CACHE_TTL then
        return cached.vendor, cached.auction
    end
    
    local vendorPrice = 0
    local auctionPrice = 0
    
    -- Get vendor price from game (use cache if available)
    local cachedName, cachedTexture, cachedSellPrice = GetCachedItemInfo(itemLink)
    local sellPrice = cachedSellPrice
    
    if not sellPrice then
        local _, _, _, _, _, _, _, _, _, _, sellPriceRaw = GetItemInfo(itemLink)
        sellPrice = sellPriceRaw
        if cachedName and cachedTexture then
            SetCachedItemInfo(itemLink, cachedName, cachedTexture, sellPrice)
        end
    end
    
    if sellPrice and sellPrice > 0 then
        vendorPrice = sellPrice
    end
    
    -- Try Auctionator
    if Auctionator and Auctionator.API and Auctionator.API.v1 then
        local success, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemLink, "CoolLootTracker", itemLink)
        if success and price and type(price) == "number" and price > 0 then
            auctionPrice = price
        end
    end
    
    -- Try Auctioneer if no Auctionator data
    if auctionPrice == 0 and AucAdvanced and AucAdvanced.API then
        local success, price = pcall(AucAdvanced.API.GetMarketValue, itemLink)
        if success and price and type(price) == "number" and price > 0 then
            auctionPrice = price
        end
    end
    
    -- Cache the results
    PriceCache[itemLink] = {
        vendor = vendorPrice,
        auction = auctionPrice,
        timestamp = time()
    }
    
    return vendorPrice, auctionPrice
end

local function GetBestPrice(itemLink)
    local vendor, auction = GetPrices(itemLink)
    
    -- Get item quality to determine price source
    local _, _, quality = GetItemInfo(itemLink)
    quality = quality or 0
    
    -- Get price source preference for this quality
    local priceSource = db.priceByQuality[quality] or "best"
    
    -- Apply price source logic
    if priceSource == "vendor" then
        return vendor
    elseif priceSource == "auction" then
        return auction > 0 and auction or vendor
    else -- "best" - prefer auction, fallback to vendor
        if auction > 0 then
            return auction
        elseif vendor > 0 then
            return vendor
        else
            return 0
        end
    end
end

local function CalculateTotalValue()
    local total = 0
    -- Add item values
    for i = 1, #db.lootLog do
        local loot = db.lootLog[i]
        if loot.link then
            local price = GetBestPrice(loot.link)
            total = total + (price * loot.quantity)
        elseif loot.value then
            total = total + loot.value
        end
    end
    -- Add tracked money sources
    total = total + (db.moneyCash or 0) + (db.moneyQuests or 0)
    return total
end

local function FormatMoney(copper)
    if not copper or copper < 0 then return "0c" end
    copper = math.floor(copper)
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local c = copper % 100
    
    local str = ""
    if gold > 0 then str = str .. gold .. "|cffffd700g|r " end
    if silver > 0 or gold > 0 then str = str .. silver .. "|cffc7c7cfs|r " end
    str = str .. c .. "|cffeda55fc|r"
    return str
end

local function GetSessionDuration()
    return time() - db.sessionStart
end

-- EMA (Exponential Moving Average) for GPH calculation
local function GetGoldPerHour()
    local duration = GetSessionDuration()
    if duration < 1 then return 0 end
    
    local total = CalculateTotalValue()
    
    -- Calculate current rate
    local currentRate = 0
    if total > 0 and duration > 0 then
        currentRate = (total / duration) * 3600
    end
    
    -- EMA parameters
    local baseAlpha = 0.1
    local warmupSeconds = 30
    local alpha = baseAlpha * math.min(1, duration / warmupSeconds)
    
    -- Initialize EMA if not set
    if not db.emaGPH then
        db.emaGPH = 0
    end
    
    -- Calculate EMA: new_value = alpha * current + (1 - alpha) * previous
    db.emaGPH = alpha * currentRate + (1 - alpha) * db.emaGPH
    
    return math.floor(db.emaGPH)
end

-- Minimap Button
local minimapButton = CreateFrame("Button", "CoolLootTrackerMinimapButton", Minimap)
minimapButton:SetWidth(31)
minimapButton:SetHeight(31)
minimapButton:SetFrameStrata("MEDIUM")
minimapButton:SetFrameLevel(8)
minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local minimapIcon = minimapButton:CreateTexture(nil, "BACKGROUND")
minimapIcon:SetWidth(20)
minimapIcon:SetHeight(20)
minimapIcon:SetPoint("CENTER", 0, 1)
minimapIcon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10_Green")

local minimapBorder = minimapButton:CreateTexture(nil, "OVERLAY")
minimapBorder:SetWidth(52)
minimapBorder:SetHeight(52)
minimapBorder:SetPoint("TOPLEFT")
minimapBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

local function UpdateMinimapButtonPosition()
    local angle = math.rad(db.minimapButton.position)
    local x = math.cos(angle) * 80
    local y = math.sin(angle) * 80
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

minimapButton:SetScript("OnClick", function(self, button)
    if button == "LeftButton" then
        CLT:ToggleMainWindow()
    elseif button == "RightButton" then
        CLT:ResetSession()
    end
end)

minimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Cool Loot Tracker", 1, 1, 1)
    GameTooltip:AddLine("Left-click: Toggle window", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click: Reset session", 0.8, 0.8, 0.8)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Total Value: " .. FormatMoney(CalculateTotalValue()), 1, 1, 1)
    GameTooltip:AddLine("Gold/Hour: " .. FormatMoney(GetGoldPerHour()), 1, 1, 1)
    GameTooltip:Show()
end)

minimapButton:SetScript("OnLeave", function(self)
    GameTooltip:Hide()
end)

minimapButton:RegisterForDrag("LeftButton")
minimapButton:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function(self)
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        local angle = math.deg(math.atan2(py - my, px - mx))
        db.minimapButton.position = angle
        UpdateMinimapButtonPosition()
    end)
end)

minimapButton:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)

-- Main Window
local mainFrame = CreateFrameWithBackdrop("Frame", "CoolLootTrackerFrame", UIParent)
mainFrame:SetWidth(450)
mainFrame:SetHeight(500)
mainFrame:SetPoint("CENTER")
mainFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})
mainFrame:SetBackdropColor(0, 0, 0, 1)
mainFrame:EnableMouse(true)
mainFrame:SetMovable(true)
mainFrame:RegisterForDrag("LeftButton")
mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
mainFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
    db.windowPosition = {point, relativePoint, xOfs, yOfs}
end)
mainFrame:Hide()
mainFrame:SetClampedToScreen(true)

-- Title
local title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -20)
title:SetText("Cool Loot Tracker")

-- Close Button
local closeButton = CreateFrame("Button", nil, mainFrame, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", -5, -5)

-- Stats Panel
local statsFrame = CreateFrameWithBackdrop("Frame", nil, mainFrame)
statsFrame:SetPoint("TOPLEFT", 20, -50)
statsFrame:SetPoint("TOPRIGHT", -20, -50)
statsFrame:SetHeight(150)
statsFrame:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
})
statsFrame:SetBackdropColor(0, 0, 0, 0.5)
statsFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

local sessionValue = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
sessionValue:SetPoint("TOPLEFT", 10, -10)
sessionValue:SetJustifyH("LEFT")

local sessionGPH = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
sessionGPH:SetPoint("TOPLEFT", sessionValue, "BOTTOMLEFT", 0, -5)

local sessionTime = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
sessionTime:SetPoint("TOPLEFT", sessionGPH, "BOTTOMLEFT", 0, -5)

local itemCount = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
itemCount:SetPoint("TOPLEFT", sessionTime, "BOTTOMLEFT", 0, -5)

-- Filter Checkboxes
local filterGreyCheckbox = CreateFrame("CheckButton", nil, statsFrame, "UICheckButtonTemplate")
filterGreyCheckbox:SetPoint("TOPLEFT", itemCount, "BOTTOMLEFT", 0, -8)
filterGreyCheckbox:SetSize(20, 20)
filterGreyCheckbox:SetChecked(db.filterGreyItems or false)
filterGreyCheckbox:SetScript("OnClick", function(self)
    db.filterGreyItems = self:GetChecked()
    -- Refresh display to show current state
    CLT:UpdateDisplay()
end)
filterGreyCheckbox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Filter Grey Items", 1, 1, 1)
    GameTooltip:AddLine("When enabled, poor quality (grey) items will not be tracked.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
filterGreyCheckbox:SetScript("OnLeave", function(self)
    GameTooltip:Hide()
end)

local filterGreyLabel = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
filterGreyLabel:SetPoint("LEFT", filterGreyCheckbox, "RIGHT", 5, 0)
filterGreyLabel:SetText("Filter Grey Items")

-- Per-quality price source dropdown (simplified - just for grey items)
local priceSourceLabel = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
priceSourceLabel:SetPoint("TOPLEFT", filterGreyCheckbox, "BOTTOMLEFT", 0, -8)
priceSourceLabel:SetText("Grey Items Price:")

local priceSourceDropdown = CreateFrame("Frame", nil, statsFrame, "UIDropDownMenuTemplate")
priceSourceDropdown:SetPoint("LEFT", priceSourceLabel, "RIGHT", 10, 0)
UIDropDownMenu_SetWidth(priceSourceDropdown, 100)
UIDropDownMenu_SetText(priceSourceDropdown, db.priceByQuality[0] == "vendor" and "Vendor" or (db.priceByQuality[0] == "auction" and "Auction" or "Best"))

local function PriceSourceMenu_Initialize(self, level)
    local info = UIDropDownMenu_CreateInfo()
    local current = db.priceByQuality[0] or "best"
    
    info.text = "Best"
    info.func = function()
        db.priceByQuality[0] = "best"
        UIDropDownMenu_SetText(priceSourceDropdown, "Best")
        PriceCache = {}
        CLT:UpdateDisplay()
    end
    info.checked = (current == "best")
    UIDropDownMenu_AddButton(info)
    
    info.text = "Vendor"
    info.func = function()
        db.priceByQuality[0] = "vendor"
        UIDropDownMenu_SetText(priceSourceDropdown, "Vendor")
        PriceCache = {}
        CLT:UpdateDisplay()
    end
    info.checked = (current == "vendor")
    UIDropDownMenu_AddButton(info)
    
    info.text = "Auction"
    info.func = function()
        db.priceByQuality[0] = "auction"
        UIDropDownMenu_SetText(priceSourceDropdown, "Auction")
        PriceCache = {}
        CLT:UpdateDisplay()
    end
    info.checked = (current == "auction")
    UIDropDownMenu_AddButton(info)
end

UIDropDownMenu_Initialize(priceSourceDropdown, PriceSourceMenu_Initialize)

-- Loot Log ScrollFrame
local scrollFrame = CreateFrame("ScrollFrame", "CoolLootTrackerScrollFrame", mainFrame, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", statsFrame, "BOTTOMLEFT", 0, -10)
scrollFrame:SetPoint("BOTTOMRIGHT", -40, 45)

local scrollChild = CreateFrame("Frame", nil, scrollFrame)
scrollChild:SetWidth(scrollFrame:GetWidth())
scrollChild:SetHeight(1)
scrollFrame:SetScrollChild(scrollChild)

-- Buttons
local resetButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
resetButton:SetWidth(100)
resetButton:SetHeight(25)
resetButton:SetPoint("BOTTOMLEFT", 20, 12)
resetButton:SetText("Reset Session")
resetButton:SetScript("OnClick", function()
    CLT:ResetSession()
end)

local clearButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
clearButton:SetWidth(100)
clearButton:SetHeight(25)
clearButton:SetPoint("LEFT", resetButton, "RIGHT", 10, 0)
clearButton:SetText("Clear Log")
        clearButton:SetScript("OnClick", function()
            db.lootLog = {}
            PriceCache = {}
            ItemInfoCache = {}
            CLT:UpdateDisplay()
        end)

-- Loot frame pool
local lootFramePool = {}

local function GetLootFrame()
    local frame = table.remove(lootFramePool)
    if not frame then
        frame = CreateFrameWithBackdrop("Frame", nil, scrollChild)
        frame:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 }
        })
        
        frame.icon = frame:CreateTexture(nil, "ARTWORK")
        frame.icon:SetWidth(32)
        frame.icon:SetHeight(32)
        frame.icon:SetPoint("LEFT", 5, 0)
        
        frame.nameText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        frame.nameText:SetPoint("LEFT", frame.icon, "RIGHT", 5, 8)
        frame.nameText:SetPoint("RIGHT", -5, 8)
        frame.nameText:SetJustifyH("LEFT")
        
        frame.priceText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        frame.priceText:SetPoint("TOPLEFT", frame.nameText, "BOTTOMLEFT", 0, -2)
        frame.priceText:SetPoint("RIGHT", -5, 0)
        frame.priceText:SetJustifyH("LEFT")
    end
    frame:Show()
    return frame
end

local function ReleaseLootFrame(frame)
    frame:Hide()
    frame:ClearAllPoints()
    frame:SetScript("OnEnter", nil)
    frame:SetScript("OnLeave", nil)
    table.insert(lootFramePool, frame)
end

-- Update Display Function
function CLT:UpdateDisplay()
    -- Update stats
    local totalValue = CalculateTotalValue()
    sessionValue:SetText("Total Value: " .. FormatMoney(totalValue))
    sessionGPH:SetText("Gold/Hour: " .. FormatMoney(GetGoldPerHour()))
    
    local duration = GetSessionDuration()
    local hours = math.floor(duration / 3600)
    local mins = math.floor((duration % 3600) / 60)
    sessionTime:SetText(string.format("Session Time: %dh %dm", hours, mins))
    
    -- Show money breakdown
    local moneyBreakdown = "Items: " .. #db.lootLog
    if (db.moneyCash or 0) > 0 or (db.moneyQuests or 0) > 0 then
        moneyBreakdown = moneyBreakdown .. " | "
        if (db.moneyCash or 0) > 0 then
            moneyBreakdown = moneyBreakdown .. "Loot: " .. FormatMoney(db.moneyCash)
        end
        if (db.moneyQuests or 0) > 0 then
            if (db.moneyCash or 0) > 0 then
                moneyBreakdown = moneyBreakdown .. " | "
            end
            moneyBreakdown = moneyBreakdown .. "Quests: " .. FormatMoney(db.moneyQuests)
        end
    end
    itemCount:SetText(moneyBreakdown)
    
    -- Clear existing loot frames
    for _, child in ipairs({scrollChild:GetChildren()}) do
        ReleaseLootFrame(child)
    end
    
    -- Consolidate only money entries, keep all items separate
    local processedLoot = {}
    local lootGoldTotal = 0
    local lootGoldCount = 0
    local questGoldTotal = 0
    local questGoldCount = 0
    local lootGoldTimestamp = 0
    local questGoldTimestamp = 0
    
    for i = 1, #db.lootLog do
        local loot = db.lootLog[i]
        
        -- Check if this is a money entry (handle both "Gold" and "Quest Gold", and old entries without source)
        -- Also check if it's a money entry by checking if name is "Gold" or if it has no link but has a value
        if (loot.name == "Gold" or loot.name == "Quest Gold") or (not loot.link and loot.value and loot.value > 0) then
            -- Determine source: use explicit source, or infer from name, or default to "loot"
            local source = loot.source
            if not source then
                if loot.name == "Quest Gold" then
                    source = "quest"
                else
                    source = "loot"  -- Default to "loot" for backward compatibility
                end
            end
            
            -- Consolidate money by source
            if source == "quest" then
                questGoldTotal = questGoldTotal + (loot.value or 0)
                questGoldCount = questGoldCount + 1
                if loot.timestamp and loot.timestamp > questGoldTimestamp then
                    questGoldTimestamp = loot.timestamp
                end
            else
                -- All other money (including "loot" source and old entries without source)
                lootGoldTotal = lootGoldTotal + (loot.value or 0)
                lootGoldCount = lootGoldCount + 1
                if loot.timestamp and loot.timestamp > lootGoldTimestamp then
                    lootGoldTimestamp = loot.timestamp
                end
            end
        else
            -- Keep items separate
            table.insert(processedLoot, loot)
        end
    end
    
    -- Add consolidated gold entries if there's any (always add, even if 0, to show in log)
    -- But only add if we actually have money entries
    if lootGoldCount > 0 and lootGoldTotal > 0 then
        table.insert(processedLoot, {
            name = "Gold",
            link = nil,
            quantity = 1,
            texture = "Interface\\Icons\\INV_Misc_Coin_01",
            value = lootGoldTotal,
            timestamp = lootGoldTimestamp > 0 and lootGoldTimestamp or time(),
            count = lootGoldCount,
            source = "loot"
        })
    end
    
    if questGoldCount > 0 and questGoldTotal > 0 then
        table.insert(processedLoot, {
            name = "Quest Gold",
            link = nil,
            quantity = 1,
            texture = "Interface\\Icons\\INV_Misc_Coin_01",
            value = questGoldTotal,
            timestamp = questGoldTimestamp > 0 and questGoldTimestamp or time(),
            count = questGoldCount,
            source = "quest"
        })
    end
    
    -- Sort by timestamp (newest first) to show proper chronological order
    table.sort(processedLoot, function(a, b)
        return (a.timestamp or 0) > (b.timestamp or 0)
    end)
    
    -- Create loot frames (newest first, show all entries)
    local yOffset = -5
    for i = 1, #processedLoot do
        local loot = processedLoot[i]
        
        local lootFrame = GetLootFrame()
        lootFrame:SetWidth(scrollChild:GetWidth() - 10)
        lootFrame:SetHeight(45)
        lootFrame:SetPoint("TOPLEFT", 5, yOffset)
        lootFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
        lootFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        
        -- Icon
        if loot.texture then
            lootFrame.icon:SetTexture(loot.texture)
        else
            lootFrame.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        end
        
        -- Item name with quantity (only show quantity if > 1)
        local displayText = ""
        if loot.link then
            displayText = loot.link
        else
            displayText = loot.name
        end
        
        -- Only show quantity for items if > 1, and show count for consolidated gold
        if (loot.name == "Gold" or loot.name == "Quest Gold") and loot.count and loot.count > 1 then
            displayText = displayText .. " |cffaaaaaa(consolidated from " .. loot.count .. " " .. (loot.source == "quest" and "quests" or "drops") .. ")|r"
        elseif loot.link and loot.quantity > 1 then
            displayText = displayText .. " |cffffff00x" .. loot.quantity .. "|r"
        end
        
        lootFrame.nameText:SetText(displayText)
        
        -- Price display
        local priceText = ""
        
        if loot.name == "Gold" or loot.name == "Quest Gold" then
            priceText = "|cffffd700" .. FormatMoney(loot.value) .. "|r"
        elseif loot.link then
            local vendorPrice, auctionPrice = GetPrices(loot.link)
            local totalVendor = vendorPrice * loot.quantity
            local totalAuction = auctionPrice * loot.quantity
            
            -- Get item quality to determine which price is being used
            local _, _, quality = GetItemInfo(loot.link)
            quality = quality or 0
            local priceSource = db.priceByQuality[quality] or "best"
            local bestPrice = GetBestPrice(loot.link)
            local totalBest = bestPrice * loot.quantity
            
            -- Show the price being used based on quality settings
            if priceSource == "vendor" then
                -- Vendor price is primary
                if vendorPrice > 0 then
                    priceText = "|cffaaaaaaVendor: " .. FormatMoney(totalVendor) .. "|r"
                    if auctionPrice > 0 then
                        priceText = priceText .. "  |cff888888(AH: " .. FormatMoney(totalAuction) .. ")|r"
                    end
                else
                    priceText = "|cffff0000No vendor price|r"
                end
            elseif priceSource == "auction" then
                -- Auction price is primary
                if auctionPrice > 0 then
                    priceText = "|cff00ff00AH: " .. FormatMoney(totalAuction) .. "|r"
                    if vendorPrice > 0 then
                        priceText = priceText .. "  |cffaaaaaa(Vendor: " .. FormatMoney(totalVendor) .. ")|r"
                    end
                elseif vendorPrice > 0 then
                    priceText = "|cffaaaaaaVendor: " .. FormatMoney(totalVendor) .. "|r (AH unavailable)"
                else
                    priceText = "|cffff0000No price data|r"
                end
            else
                -- Best available (prefer auction, fallback to vendor)
                if auctionPrice > 0 then
                    priceText = "|cff00ff00AH: " .. FormatMoney(totalAuction) .. "|r"
                    if vendorPrice > 0 then
                        priceText = priceText .. "  |cffaaaaaa(Vendor: " .. FormatMoney(totalVendor) .. ")|r"
                    end
                elseif vendorPrice > 0 then
                    priceText = "|cffaaaaaaVendor: " .. FormatMoney(totalVendor) .. "|r"
                else
                    priceText = "|cffff0000No price data|r"
                end
            end
        end
        
        lootFrame.priceText:SetText(priceText)
        
        -- Tooltip
        lootFrame:SetScript("OnEnter", function(self)
            if loot.link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(loot.link)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Quantity: " .. loot.quantity, 1, 1, 1)
                
                local vendorPrice, auctionPrice = GetPrices(loot.link)
                if auctionPrice > 0 or vendorPrice > 0 then
                    GameTooltip:AddLine(" ")
                    if db.forceVendorPrice then
                        -- Show vendor price as primary when forced
                        if vendorPrice > 0 then
                            GameTooltip:AddLine("Vendor (Each): " .. FormatMoney(vendorPrice), 0.7, 0.7, 0.7)
                            GameTooltip:AddLine("Vendor Total: " .. FormatMoney(vendorPrice * loot.quantity), 0.7, 0.7, 0.7)
                        end
                        if auctionPrice > 0 then
                            GameTooltip:AddLine("AH Price (Each): " .. FormatMoney(auctionPrice), 0.5, 0.5, 0.5)
                            GameTooltip:AddLine("AH Total: " .. FormatMoney(auctionPrice * loot.quantity), 0.5, 0.5, 0.5)
                        end
                    else
                        -- Show auction price as primary when not forced
                        if auctionPrice > 0 then
                            GameTooltip:AddLine("AH Price (Each): " .. FormatMoney(auctionPrice), 0, 1, 0)
                            GameTooltip:AddLine("AH Total: " .. FormatMoney(auctionPrice * loot.quantity), 0, 1, 0)
                        end
                        if vendorPrice > 0 then
                            GameTooltip:AddLine("Vendor (Each): " .. FormatMoney(vendorPrice), 0.7, 0.7, 0.7)
                            GameTooltip:AddLine("Vendor Total: " .. FormatMoney(vendorPrice * loot.quantity), 0.7, 0.7, 0.7)
                        end
                    end
                end
                
                GameTooltip:Show()
            elseif loot.name == "Gold" or loot.name == "Quest Gold" then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(loot.name, 1, 0.82, 0)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Total Amount: " .. FormatMoney(loot.value), 1, 1, 1)
                if loot.count and loot.count > 1 then
                    GameTooltip:AddLine("Consolidated from " .. loot.count .. " " .. (loot.source == "quest" and "quests" or "drops"), 0.8, 0.8, 0.8)
                end
                GameTooltip:Show()
            end
        end)
        
        lootFrame:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)
        
        yOffset = yOffset - 50
    end
    
    scrollChild:SetHeight(math.abs(yOffset) + 5)
end

function CLT:ToggleMainWindow()
    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
        -- Update checkboxes to match database
        filterGreyCheckbox:SetChecked(db.filterGreyItems or false)
        -- Update dropdown
        local greyPriceSource = db.priceByQuality[0] or "best"
        UIDropDownMenu_SetText(priceSourceDropdown, greyPriceSource == "vendor" and "Vendor" or (greyPriceSource == "auction" and "Auction" or "Best"))
        self:UpdateDisplay()
        mainFrame:Show()
    end
end

function CLT:ResetSession()
    StaticPopupDialogs["CLT_RESET_CONFIRM"] = {
        text = "Reset loot tracker session?\n\nThis will clear your current session stats but keep the loot log.",
        button1 = "Reset",
        button2 = "Cancel",
        OnAccept = function()
            db.sessionStart = time()
            db.emaGPH = 0
            db.moneyCash = 0
            db.moneyQuests = 0
            PriceCache = {}
            ItemInfoCache = {}
            CLT:UpdateDisplay()
            print("|cff00ff00Cool Loot Tracker:|r Session reset!")
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopup_Show("CLT_RESET_CONFIRM")
end

-- TBC-compatible delayed callback
local function DelayedCallback(delay, callback)
    if C_Timer and C_Timer.After then
        C_Timer.After(delay, callback)
    else
        local frame = CreateFrame("Frame")
        local timeElapsed = 0
        frame:SetScript("OnUpdate", function(self, elapsed)
            timeElapsed = timeElapsed + elapsed
            if timeElapsed >= delay then
                self:SetScript("OnUpdate", nil)
                callback()
            end
        end)
    end
end

-- Event Handlers
CLT:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON_NAME then
            -- Restore window position
            if db.windowPosition and db.windowPosition[1] then
                mainFrame:ClearAllPoints()
                mainFrame:SetPoint(db.windowPosition[1], UIParent, db.windowPosition[2], db.windowPosition[3], db.windowPosition[4])
            end
            
            -- Position minimap button
            UpdateMinimapButtonPosition()
            
            if db.minimapButton.hide then
                minimapButton:Hide()
            end
            
            -- Initialize money tracking
            if not db.oldMoney or db.oldMoney == 0 then
                db.oldMoney = GetMoney()
            end
            
            -- Initialize price by quality if not set
            if not db.priceByQuality then
                db.priceByQuality = {
                    [0] = "vendor",  -- Poor: vendor
                    [1] = "best",    -- Common: best available
                    [2] = "best",    -- Uncommon: best available
                    [3] = "best",    -- Rare: best available
                    [4] = "best",    -- Epic: best available
                    [5] = "best"     -- Legendary: best available
                }
            end
            
            -- Initialize money counters if not set
            if not db.moneyCash then db.moneyCash = 0 end
            if not db.moneyQuests then db.moneyQuests = 0 end
            
            -- Register for Auctionator database updates (if already loaded)
            if Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.RegisterForDBUpdate then
                Auctionator.API.v1.RegisterForDBUpdate("CoolLootTracker", function()
                    -- Clear price cache when database updates
                    PriceCache = {}
                    -- Refresh display if window is open
                    if mainFrame:IsShown() then
                        CLT:UpdateDisplay()
                    end
                end)
            end
            
            print("|cff00ff00Cool Loot Tracker|r loaded! Type /clt for commands.")
        elseif addonName == "Auctionator" then
            -- Auctionator just loaded, register for database updates
            if Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.RegisterForDBUpdate then
                Auctionator.API.v1.RegisterForDBUpdate("CoolLootTracker", function()
                    -- Clear price cache when database updates
                    PriceCache = {}
                    -- Refresh display if window is open
                    if mainFrame:IsShown() then
                        CLT:UpdateDisplay()
                    end
                end)
            end
        end
        
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        local interaction = ...
        -- Pause tracking during relevant interactions (TBC compatible)
        if Enum and Enum.PlayerInteractionType then
            if interaction == Enum.PlayerInteractionType.Merchant or
               interaction == Enum.PlayerInteractionType.Banker or
               interaction == Enum.PlayerInteractionType.GuildBanker or
               interaction == Enum.PlayerInteractionType.MailInfo or
               interaction == Enum.PlayerInteractionType.Auctioneer or
               interaction == Enum.PlayerInteractionType.BlackMarketAuctioneer then
                interactionPaused = true
                -- Store current money to detect changes when interaction closes
                db.oldMoney = GetMoney()
            end
        else
            -- TBC fallback: pause on any interaction
            interactionPaused = true
            db.oldMoney = GetMoney()
        end
        
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        -- Resume tracking and check for money changes
        if interactionPaused then
            interactionPaused = false
            -- Update old money for next interaction
            db.oldMoney = GetMoney()
        end
        
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Initialize money tracking
        if not db.oldMoney or db.oldMoney == 0 then
            db.oldMoney = GetMoney()
        end
        
    elseif event == "CHAT_MSG_LOOT" then
        -- Skip tracking if interaction is paused
        if interactionPaused then return end
        
        local msg = ...
        
        -- Check for crafted items first and skip them
        if LOOT_ITEM_CREATED_SELF_MULTIPLE and msg:match(LOOT_ITEM_CREATED_SELF_MULTIPLE:gsub("%%s", ".+"):gsub("%%d", "%%d+")) then
            return  -- Skip crafted items
        end
        if LOOT_ITEM_CREATED_SELF and msg:match(LOOT_ITEM_CREATED_SELF:gsub("%%s", ".+")) then
            return  -- Skip crafted items
        end
        
        -- Use game constants for better pattern matching (TBC compatible)
        local itemLink, quantity
        local matched = false
        
        -- Try matching against game constants
        if LOOT_ITEM_SELF_MULTIPLE then
            local pattern = LOOT_ITEM_SELF_MULTIPLE:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
            itemLink, quantity = msg:match(pattern)
            if itemLink then matched = true end
        end
        
        if not matched and LOOT_ITEM_PUSHED_SELF_MULTIPLE then
            local pattern = LOOT_ITEM_PUSHED_SELF_MULTIPLE:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
            itemLink, quantity = msg:match(pattern)
            if itemLink then matched = true end
        end
        
        if not matched and LOOT_ITEM_SELF then
            local pattern = LOOT_ITEM_SELF:gsub("%%s", "(.+)")
            itemLink = msg:match(pattern)
            if itemLink then
                matched = true
                quantity = 1
            end
        end
        
        if not matched and LOOT_ITEM_PUSHED_SELF then
            local pattern = LOOT_ITEM_PUSHED_SELF:gsub("%%s", "(.+)")
            itemLink = msg:match(pattern)
            if itemLink then
                matched = true
                quantity = 1
            end
        end
        
        -- Fallback to old pattern matching if constants not available or didn't match
        if not matched then
            if not (msg:find("You receive loot:") or msg:find("You create")) then
                return
            end
            itemLink = msg:match("(|c%x+|Hitem:.-|h%[.-%]|h|r)")
            if not itemLink then return end
            quantity = tonumber(msg:match("x(%d+)") or "1")
        else
            -- Extract itemLink from the matched string if it's not already a link
            if not itemLink:match("^|c%x+|Hitem:") then
                itemLink = itemLink:match("(|c%x+|Hitem:.-|h%[.-%]|h|r)")
            end
            if not itemLink then return end
            quantity = tonumber(quantity) or 1
        end
        
        if itemLink then
            local itemName, _, quality, _, _, _, _, _, _, itemTexture, sellPrice = GetItemInfo(itemLink)
            
            if itemName then
                -- Filter out grey items if option is enabled (quality 0 = poor/grey)
                if db.filterGreyItems and quality == 0 then
                    return  -- Skip grey items
                end
                
                -- Cache item info
                SetCachedItemInfo(itemLink, itemName, itemTexture, sellPrice)
                
                table.insert(db.lootLog, {
                    name = itemName,
                    link = itemLink,
                    quantity = quantity,
                    texture = itemTexture,
                    timestamp = time()
                })
                
                if mainFrame:IsShown() then
                    self:UpdateDisplay()
                end
            else
                -- Item not cached, retry after delay
                DelayedCallback(0.5, function()
                    local itemName, _, quality, _, _, _, _, _, _, itemTexture, sellPrice = GetItemInfo(itemLink)
                    if itemName then
                        -- Filter out grey items if option is enabled
                        if db.filterGreyItems and quality == 0 then
                            return  -- Skip grey items
                        end
                        
                        -- Cache item info
                        SetCachedItemInfo(itemLink, itemName, itemTexture, sellPrice)
                        
                        table.insert(db.lootLog, {
                            name = itemName,
                            link = itemLink,
                            quantity = quantity,
                            texture = itemTexture,
                            timestamp = time()
                        })
                        
                        if mainFrame:IsShown() then
                            CLT:UpdateDisplay()
                        end
                    end
                end)
            end
        end
        
    elseif event == "CHAT_MSG_MONEY" then
        -- Skip tracking if interaction is paused
        if interactionPaused then return end
        
        local msg = ...
        
        -- Use game constants for better locale support (like KiwiFarm)
        local GOLD_PTN = GOLD_AMOUNT and GOLD_AMOUNT:gsub("%%d", "(%d+)") or "(%d+) Gold"
        local SILV_PTN = SILVER_AMOUNT and SILVER_AMOUNT:gsub("%%d", "(%d+)") or "(%d+) Silver"
        local COPP_PTN = COPPER_AMOUNT and COPPER_AMOUNT:gsub("%%d", "(%d+)") or "(%d+) Copper"
        
        local gold = tonumber(msg:match(GOLD_PTN) or 0)
        local silver = tonumber(msg:match(SILV_PTN) or 0)
        local copper = tonumber(msg:match(COPP_PTN) or 0)
        
        local totalCopper = (gold * 10000) + (silver * 100) + copper
        
        if totalCopper > 0 then
            -- Track in separate money counter
            db.moneyCash = (db.moneyCash or 0) + totalCopper
            
            -- Also add to loot log for display
            table.insert(db.lootLog, {
                name = "Gold",
                link = nil,
                quantity = 1,
                texture = "Interface\\Icons\\INV_Misc_Coin_01",
                value = totalCopper,
                timestamp = time(),
                source = "loot"
            })
            
            if mainFrame:IsShown() then
                self:UpdateDisplay()
            end
        end
        
    elseif event == "QUEST_TURNED_IN" then
        -- Skip tracking if interaction is paused
        if interactionPaused then return end
        
        local questID, experience, money = ...
        
        if money and money > 0 then
            -- Track in separate quest money counter
            db.moneyQuests = (db.moneyQuests or 0) + money
            
            -- Also add to loot log for display
            table.insert(db.lootLog, {
                name = "Quest Gold",
                link = nil,
                quantity = 1,
                texture = "Interface\\Icons\\INV_Misc_Coin_01",
                value = money,
                timestamp = time(),
                source = "quest"
            })
            
            if mainFrame:IsShown() then
                self:UpdateDisplay()
            end
        end
    end
end)

-- Slash Commands
SLASH_COOLLOOTTRACKER1 = "/clt"
SLASH_COOLLOOTTRACKER2 = "/coolloot"
SlashCmdList["COOLLOOTTRACKER"] = function(msg)
    msg = msg:lower()
    if msg == "reset" then
        CLT:ResetSession()
    elseif msg == "show" then
        mainFrame:Show()
        CLT:UpdateDisplay()
    elseif msg == "hide" then
        mainFrame:Hide()
    elseif msg == "minimap" then
        if minimapButton:IsShown() then
            minimapButton:Hide()
            db.minimapButton.hide = true
            print("|cff00ff00Cool Loot Tracker:|r Minimap button hidden. Use /clt minimap to show.")
        else
            minimapButton:Show()
            db.minimapButton.hide = false
            print("|cff00ff00Cool Loot Tracker:|r Minimap button shown.")
        end
    elseif msg == "debug" then
        print("|cff00ff00Cool Loot Tracker Debug:|r")
        print("Auctionator available: " .. tostring(Auctionator ~= nil))
        if Auctionator then
            print("Auctionator API available: " .. tostring(Auctionator.API ~= nil))
            if Auctionator.API and Auctionator.API.v1 then
                print("Auctionator API v1 available: true")
            end
            print("Auctionator Database available: " .. tostring(Auctionator.Database ~= nil))
            print("|cffffcc00Note:|r Auctionator needs AH scan data to show prices.")
            print("Visit the AH and do a scan to populate price data.")
        end
        print("Total items logged: " .. #db.lootLog)
        print("Total value: " .. FormatMoney(CalculateTotalValue()))
        print("Session duration: " .. GetSessionDuration() .. " seconds")
        print("Gold per hour (EMA): " .. FormatMoney(GetGoldPerHour()))
        print("Interaction paused: " .. tostring(interactionPaused))
        print("Price cache entries: " .. (function() local count = 0 for _ in pairs(PriceCache) do count = count + 1 end return count end)())
        print("Item info cache entries: " .. (function() local count = 0 for _ in pairs(ItemInfoCache) do count = count + 1 end return count end)())
        
        -- Show price breakdown for first 5 items
        print("Price breakdown (first 5 items):")
        for i = 1, math.min(5, #db.lootLog) do
            local loot = db.lootLog[i]
            if loot.link then
                local vendor, auction = GetPrices(loot.link)
                local best = GetBestPrice(loot.link)
                print(string.format("  %s x%d:", loot.name, loot.quantity))
                print(string.format("    Vendor: %s, AH: %s, Using: %s", 
                    vendor > 0 and FormatMoney(vendor) or "none",
                    auction > 0 and FormatMoney(auction) or "none",
                    best > 0 and FormatMoney(best) or "none"))
            elseif loot.name == "Gold" then
                print(string.format("  Gold: %s", FormatMoney(loot.value)))
            end
        end
    else
        print("|cff00ff00Cool Loot Tracker Commands:|r")
        print("/clt show - Show tracker window")
        print("/clt hide - Hide tracker window")
        print("/clt reset - Reset session")
        print("/clt minimap - Toggle minimap button")
        print("/clt debug - Show debug info")
    end
endd