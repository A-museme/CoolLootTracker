-- Cool Loot Tracker - Main Addon File
-- A lightweight, full-featured loot tracking addon for WoW Classic Anniversary Edition
-- Fixed for Classic API compatibility

local ADDON_NAME = "CoolLootTracker"
local CLT = CreateFrame("Frame")
CLT:RegisterEvent("ADDON_LOADED")
CLT:RegisterEvent("CHAT_MSG_LOOT")
CLT:RegisterEvent("CHAT_MSG_MONEY")
CLT:RegisterEvent("PLAYER_LOGOUT")

-- Database
CoolLootTrackerDB = CoolLootTrackerDB or {
    lootLog = {},
    sessionStart = time(),
    totalValue = 0,
    minimapButton = {
        hide = false,
        position = 45
    },
    windowPosition = {}
}

local db = CoolLootTrackerDB

-- Helper Functions
local function FormatMoney(copper)
    if not copper or copper < 0 then return "0c" end
    copper = math.floor(copper)  -- Remove decimals
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local c = copper % 100
    
    local str = ""
    if gold > 0 then str = str .. gold .. "|cffffd700g|r " end
    if silver > 0 or gold > 0 then str = str .. silver .. "|cffc7c7cfs|r " end
    str = str .. c .. "|cffeda55fc|r"
    return str
end

local function GetItemValue(itemLink)
    local vendorPrice = 0
    local auctionPrice = 0
    
    -- Get vendor price
    if itemLink then
        local _, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemLink)
        if sellPrice then
            vendorPrice = sellPrice
        end
    end
    
    -- Try to get Auctionator price if available
    if Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetAuctionPriceByItemLink then
        local success, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemLink, Auctionator, itemLink)
        if success and price and type(price) == "number" then
            auctionPrice = price
        end
    end
    
    return math.max(vendorPrice, auctionPrice), vendorPrice, auctionPrice
end

local function GetSessionDuration()
    return time() - db.sessionStart
end

local function GetGoldPerHour()
    local duration = GetSessionDuration()
    if duration < 60 then return 0 end
    return (db.totalValue / duration) * 3600
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
    GameTooltip:AddLine("Session Value: " .. FormatMoney(db.totalValue), 1, 1, 1)
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
local mainFrame = CreateFrame("Frame", "CoolLootTrackerFrame", UIParent, "BackdropTemplate")
mainFrame:SetWidth(400)
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
local statsFrame = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
statsFrame:SetPoint("TOPLEFT", 20, -50)
statsFrame:SetPoint("TOPRIGHT", -20, -50)
statsFrame:SetHeight(100)
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
    CLT:UpdateDisplay()
end)

-- Loot frame pool for better performance
local lootFramePool = {}

local function GetLootFrame()
    local frame = table.remove(lootFramePool)
    if not frame then
        frame = CreateFrame("Frame", nil, scrollChild, "BackdropTemplate")
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
        frame.nameText:SetPoint("LEFT", frame.icon, "RIGHT", 5, 5)
        frame.nameText:SetJustifyH("LEFT")
        
        frame.valueText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        frame.valueText:SetPoint("TOPLEFT", frame.nameText, "BOTTOMLEFT", 0, -2)
        frame.valueText:SetTextColor(1, 0.82, 0)
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
    sessionValue:SetText("Total Value: " .. FormatMoney(db.totalValue))
    sessionGPH:SetText("Gold/Hour: " .. FormatMoney(GetGoldPerHour()))
    
    local duration = GetSessionDuration()
    local hours = math.floor(duration / 3600)
    local mins = math.floor((duration % 3600) / 60)
    sessionTime:SetText(string.format("Session Time: %dh %dm", hours, mins))
    itemCount:SetText("Items Looted: " .. #db.lootLog)
    
    -- Clear existing loot frames
    for _, child in ipairs({scrollChild:GetChildren()}) do
        ReleaseLootFrame(child)
    end
    
    -- Consolidate duplicate items
    local consolidatedLoot = {}
    local itemKeys = {}
    
    for i = 1, #db.lootLog do
        local loot = db.lootLog[i]
        local key = loot.link or loot.name
        
        if not consolidatedLoot[key] then
            consolidatedLoot[key] = {
                name = loot.name,
                link = loot.link,
                quantity = loot.quantity,
                texture = loot.texture,
                value = loot.value,
                vendorValue = loot.vendorValue,
                auctionValue = loot.auctionValue,
                timestamp = loot.timestamp,
                count = 1
            }
            table.insert(itemKeys, key)
        else
            consolidatedLoot[key].quantity = consolidatedLoot[key].quantity + loot.quantity
            consolidatedLoot[key].value = consolidatedLoot[key].value + loot.value
            consolidatedLoot[key].vendorValue = consolidatedLoot[key].vendorValue + loot.vendorValue
            consolidatedLoot[key].auctionValue = consolidatedLoot[key].auctionValue + loot.auctionValue
            consolidatedLoot[key].count = consolidatedLoot[key].count + 1
            -- Keep the most recent timestamp
            if loot.timestamp > consolidatedLoot[key].timestamp then
                consolidatedLoot[key].timestamp = loot.timestamp
            end
        end
    end
    
    -- Create loot frames from consolidated data
    local yOffset = -5
    for i = #itemKeys, math.max(1, #itemKeys - 100), -1 do
        local key = itemKeys[i]
        local loot = consolidatedLoot[key]
        
        local lootFrame = GetLootFrame()
        lootFrame:SetWidth(scrollChild:GetWidth() - 10)
        lootFrame:SetHeight(40)
        lootFrame:SetPoint("TOPLEFT", 5, yOffset)
        lootFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
        lootFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        
        -- Icon
        if loot.texture then
            lootFrame.icon:SetTexture(loot.texture)
        else
            lootFrame.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        end
        
        -- Item name with count
        lootFrame.nameText:SetPoint("RIGHT", -5, 5)
        local displayText = ""
        if loot.link then
            displayText = loot.link
        else
            displayText = loot.name
        end
        
        -- Show total quantity and number of times looted
        if loot.count > 1 then
            displayText = displayText .. " |cffaaaaaa(x" .. loot.count .. ")|r"
        end
        if loot.quantity > 1 or loot.count > 1 then
            displayText = displayText .. " |cffffff00[" .. loot.quantity .. " total]|r"
        end
        
        lootFrame.nameText:SetText(displayText)
        
        -- Value
        local valueStr = ""
        
        -- Show vendor value
        if loot.vendorValue > 0 then
            valueStr = "|cffffffffV:|r " .. FormatMoney(loot.vendorValue)
        end
        
        -- Show auction value
        if loot.auctionValue > 0 then
            if valueStr ~= "" then
                valueStr = valueStr .. " |cffffffffAH:|r " .. FormatMoney(loot.auctionValue)
            else
                valueStr = "|cffffffffAH:|r " .. FormatMoney(loot.auctionValue)
            end
        end
        
        -- If no prices available
        if valueStr == "" then
            valueStr = "|cffff0000No price data|r"
        end
        
        lootFrame.valueText:SetText(valueStr)
        
        lootFrame:SetScript("OnEnter", function(self)
            if loot.link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(loot.link)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Total Quantity: " .. loot.quantity, 1, 1, 1)
                GameTooltip:AddLine("Times Looted: " .. loot.count, 1, 1, 1)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Vendor (Total): " .. FormatMoney(loot.vendorValue), 1, 1, 1)
                if loot.auctionValue > 0 then
                    GameTooltip:AddLine("Auction (Total): " .. FormatMoney(loot.auctionValue), 1, 1, 1)
                end
                GameTooltip:Show()
            elseif loot.name == "Gold" then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Gold Looted", 1, 0.82, 0)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Total Amount: " .. FormatMoney(loot.value), 1, 1, 1)
                GameTooltip:AddLine("Times Looted: " .. loot.count, 1, 1, 1)
                GameTooltip:Show()
            end
        end)
        
        lootFrame:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)
        
        yOffset = yOffset - 45
    end
    
    scrollChild:SetHeight(math.abs(yOffset) + 5)
end

function CLT:ToggleMainWindow()
    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
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
            db.totalValue = 0
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

-- Classic-compatible delayed callback function
local function DelayedCallback(delay, callback)
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
            
            print("|cff00ff00Cool Loot Tracker|r loaded! Click the minimap button to open.")
        end
        
    elseif event == "CHAT_MSG_LOOT" then
        local msg = ...
        
        -- Only track YOUR loot - must contain "You receive loot:" or "You create"
        if not (msg:find("You receive loot:") or msg:find("You create")) then
            return
        end
        
        -- Parse loot message
        local itemLink = msg:match("(|c%x+|Hitem:.-|h%[.-%]|h|r)")
        
        if itemLink then
            local qty = msg:match("x(%d+)") or "1"
            qty = tonumber(qty)
            
            -- Get item info (may need to wait for server response)
            local itemName, _, _, _, _, _, _, _, _, itemTexture, vendorPrice = GetItemInfo(itemLink)
            
            if itemName then
                local value, vendorVal, auctionVal = GetItemValue(itemLink)
                value = value * qty
                vendorVal = vendorVal * qty
                auctionVal = auctionVal * qty
                
                local lootEntry = {
                    name = itemName,
                    link = itemLink,
                    quantity = qty,
                    texture = itemTexture,
                    value = value,
                    vendorValue = vendorVal,
                    auctionValue = auctionVal,
                    timestamp = time()
                }
                
                table.insert(db.lootLog, lootEntry)
                db.totalValue = db.totalValue + value
                
                if mainFrame:IsShown() then
                    self:UpdateDisplay()
                end
            else
                -- Item info not cached, use Classic-compatible delayed callback
                DelayedCallback(0.5, function()
                    local itemName, _, _, _, _, _, _, _, _, itemTexture, vendorPrice = GetItemInfo(itemLink)
                    if itemName then
                        local value, vendorVal, auctionVal = GetItemValue(itemLink)
                        value = value * qty
                        vendorVal = vendorVal * qty
                        auctionVal = auctionVal * qty
                        
                        local lootEntry = {
                            name = itemName,
                            link = itemLink,
                            quantity = qty,
                            texture = itemTexture,
                            value = value,
                            vendorValue = vendorVal,
                            auctionValue = auctionVal,
                            timestamp = time()
                        }
                        
                        table.insert(db.lootLog, lootEntry)
                        db.totalValue = db.totalValue + value
                        
                        if mainFrame:IsShown() then
                            CLT:UpdateDisplay()
                        end
                    end
                end)
            end
        end
        
    elseif event == "CHAT_MSG_MONEY" then
        local msg = ...
        
        -- Parse money gained: "You loot 5 Gold, 23 Silver, 45 Copper"
        local gold = msg:match("(%d+) Gold") or 0
        local silver = msg:match("(%d+) Silver") or 0
        local copper = msg:match("(%d+) Copper") or 0
        
        gold = tonumber(gold) or 0
        silver = tonumber(silver) or 0
        copper = tonumber(copper) or 0
        
        local totalCopper = (gold * 10000) + (silver * 100) + copper
        
        if totalCopper > 0 then
            local lootEntry = {
                name = "Gold",
                link = nil,
                quantity = 1,
                texture = "Interface\\Icons\\INV_Misc_Coin_01",
                value = totalCopper,
                vendorValue = totalCopper,
                auctionValue = 0,
                timestamp = time()
            }
            
            table.insert(db.lootLog, lootEntry)
            db.totalValue = db.totalValue + totalCopper
            
            if mainFrame:IsShown() then
                self:UpdateDisplay()
            end
        end
        
    elseif event == "PLAYER_LOGOUT" then
        -- Save handled automatically by SavedVariables
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
    else
        print("|cff00ff00Cool Loot Tracker Commands:|r")
        print("/clt show - Show tracker window")
        print("/clt hide - Hide tracker window")
        print("/clt reset - Reset session")
        print("/clt minimap - Toggle minimap button")
    end
end