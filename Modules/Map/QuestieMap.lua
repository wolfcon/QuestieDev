---@class QuestieMap
local QuestieMap = QuestieLoader:CreateModule("QuestieMap");

-------------------------
--Import modules.
-------------------------
---@type QuestieQuest
local QuestieQuest = QuestieLoader:ImportModule("QuestieQuest");
---@type QuestieFramePool
local QuestieFramePool = QuestieLoader:ImportModule("QuestieFramePool");
---@type QuestieDBMIntegration
local QuestieDBMIntegration = QuestieLoader:ImportModule("QuestieDBMIntegration");
---@type QuestieLib
local QuestieLib = QuestieLoader:ImportModule("QuestieLib");
---@type QuestiePlayer
local QuestiePlayer = QuestieLoader:ImportModule("QuestiePlayer");
---@type QuestieDB
local QuestieDB = QuestieLoader:ImportModule("QuestieDB");

QuestieMap.ICON_MAP_TYPE = "MAP";
QuestieMap.ICON_MINIMAP_TYPE = "MINIMAP";

-- List of frames sorted by quest ID (automatic notes)
-- E.g. {[questId] = {[frameName] = frame, ...}, ...}
-- For details about frame.data see calls to QuestieMap.DrawWorldIcon
QuestieMap.questIdFrames = {}
-- List of frames sorted by NPC/object ID (manual notes)
-- id > 0: NPC
-- id < 0: object
-- E.g. {[-objectId] = {[frameName] = frame, ...}, ...}
-- For details about frame.data see QuestieMap.ShowNPC and QuestieMap.ShowObject
QuestieMap.manualFrames = {}

QuestieMap.mapFramesShown = {};

QuestieMap.minimapFramesShown = {} -- I would do minimapFrames.shown but that would break the logic below

--Used in my fadelogic.
local fadeOverDistance = 10;

local HBD = LibStub("HereBeDragonsQuestie-2.0")
local HBDPins = LibStub("HereBeDragonsQuestie-Pins-2.0")
local HBDMigrate = LibStub("HereBeDragonsQuestie-Migrate")

--We should really try and squeeze out all the performance we can, especially in this.
local tostring = tostring;
local tinsert = table.insert;
local pairs = pairs;
local ipairs = ipairs;
local tpack = table.pack;
local tremove = table.remove;
local tunpack = unpack;


QUESTIE_CLUSTER_DISTANCE = 70; -- smaller numbers = more icons on the map
QuestieMap.drawTimer = nil;
QuestieMap.fadeLogicTimerShown = nil;

--Get the frames for a quest, this returns all of the frames
function QuestieMap:GetFramesForQuest(QuestId)
    local frames = {}
    --If no frames exists or if the quest does not exist we just return an empty list
    if (QuestieMap.questIdFrames[QuestId]) then
        for i, name in ipairs(QuestieMap.questIdFrames[QuestId]) do
            tinsert(frames, _G[name])
        end
    end
    return frames
end

function QuestieMap:UnloadQuestFrames(questId, iconType)
    if(QuestieMap.questIdFrames[questId]) then
        if(iconType == nil) then
            for index, frame in ipairs(QuestieMap:GetFramesForQuest(questId)) do
                frame:Unload();
            end
            QuestieMap.questIdFrames[questId] = nil;
        else
            for index, frame in ipairs(QuestieMap:GetFramesForQuest(questId)) do
                if(frame and frame.data and frame.data.Icon == iconType) then
                    frame:Unload();
                end
            end
        end
        Questie:Debug(DEBUG_DEVELOP, "[QuestieMap]: ".. QuestieLocale:GetUIString('DEBUG_UNLOAD_QFRAMES', questId))
    end
end

--Get the frames for manual note, this returns all of the frames/spawns
---@param id integer @The ID of the NPC (>0) or object (<0)
function QuestieMap:GetManualFrames(id)
    local frames = {}
    --If no frames exists or if the quest does not exist we just return an empty list
    if (QuestieMap.manualFrames[id]) then
        for _, name in pairs(QuestieMap.manualFrames[id]) do
            tinsert(frames, _G[name])
        end
    end
    return frames
end

---@param id integer @The ID of the NPC (>0) or object (<0)
function QuestieMap:UnloadManualFrames(id)
    if(QuestieMap.manualFrames[id]) then
        for index, frame in ipairs(QuestieMap:GetManualFrames(id)) do
            frame:Unload();
        end
        QuestieMap.manualFrames[id] = nil;
    end
end

-- Rescale a single icon
---@param frameName string @The global name of the icon frame, e.g. "QuestieFrame1"
local function rescaleIcon(frameName, modifier)
    local zoomModifier = modifier or 1;
    local frame = _G[frameName]
    if frame and frame.data then
        if(frame.data.GetIconScale) then
            frame.data.IconScale = frame.data:GetIconScale();
            local scale = nil
            if(frame.miniMapIcon) then
                scale = 16 * (frame.data.IconScale or 1) * (Questie.db.global.globalMiniMapScale or 0.7);
            else
                scale = 16 * (frame.data.IconScale or 1) * (Questie.db.global.globalScale or 0.7);
            end

            if(frame.miniMapIcon) then
                zoomModifier = 1;
            end

            if scale > 1 then
                frame:SetWidth(scale*zoomModifier)
                frame:SetHeight(scale*zoomModifier)
            end
        else
            Questie:Error("A frame is lacking the GetIconScale function for resizing!", frame.data.Id);
        end
    end
end

-- Rescale all the icons
function QuestieMap:RescaleIcons(modifier)
    for _, framelist in pairs(QuestieMap.questIdFrames) do
        for _, frameName in ipairs(framelist) do
            rescaleIcon(frameName, modifier)
        end
    end
    for _, framelist in pairs(QuestieMap.manualFrames) do
        for _, frameName in ipairs(framelist) do
            rescaleIcon(frameName, modifier)
        end
    end
end

-- Rescale all the shown map icons
function QuestieMap:RescaleShownMapIcons(modifier)
    for _, framelist in pairs(QuestieMap.mapFramesShown) do
        for _, frameName in ipairs(framelist) do
            rescaleIcon(frameName, modifier)
        end
    end
end

local mapDrawQueue = {};
local minimapDrawQueue = {};
function QuestieMap:InitializeQueue()
    Questie:Debug(DEBUG_DEVELOP, "[QuestieMap] Starting draw queue timer!")
    QuestieMap.drawTimer = C_Timer.NewTicker(0.005, QuestieMap.ProcessQueue)
    QuestieMap.fadeLogicTimerShown = C_Timer.NewTicker(0.3, QuestieMap.ProcessShownMinimapIcons);

    --Reduce the size of the icons on the map depending on zoom
    hooksecurefunc(WorldMapFrame, "ProcessCanvasClickHandlers", 
    function(self, button, cursorX, cursorY)
        --print(button.." clicked at ["..cursorX..", "..cursorY.."] ")
        QuestieMap:UpdateZoomScale()
    end)

    --We should probably reset this when the map opens.
    WorldMapFrame:HookScript("OnShow", QuestieMap.UpdateZoomScale);
end

function QuestieMap:UpdateZoomScale()
    --["Azeroth"] = {947,0},
    --["Kalimdor"] = {1414,947},
    --["Eastern Kingdoms"] = {1415,947},
    --This time is required because GetMapID does not return the correct ID without it.
    C_Timer.After(0.01, function()
        local mapId = WorldMapFrame:GetMapID();
        local scaling = 1;
        if(mapId == 947) then --Azeroth
            if(Questie.db.char.enableMinimalisticIcons) then
                scaling = 0.4
            else
                scaling = 0.85
            end
        elseif(mapId == 1414 or mapId == 1415) then -- EK and Kalimdor
            if(Questie.db.char.enableMinimalisticIcons) then
                scaling = 0.5
            else
                scaling = 0.9
            end
        end
        QuestieMap:RescaleShownMapIcons(scaling);
    end)
end

function QuestieMap:ProcessShownMinimapIcons()
    for frameName, minimapFrame in pairs(QuestieMap.minimapFramesShown) do
        if (minimapFrame.FadeLogic and minimapFrame.miniMapIcon) then
            minimapFrame:FadeLogic()
        end
        if minimapFrame.glowUpdate then
            minimapFrame:glowUpdate()
        end
    end
end

function QuestieMap:QueueDraw(drawType, ...)
  if(drawType == QuestieMap.ICON_MAP_TYPE) then
    tinsert(mapDrawQueue, {...});
  elseif(drawType == QuestieMap.ICON_MINIMAP_TYPE) then
    tinsert(minimapDrawQueue, {...});
  end
end


function QuestieMap:ProcessQueue()
    local mapDrawCall = tremove(mapDrawQueue, 1);
    if(mapDrawCall) then
        HBDPins:AddWorldMapIconMap(tunpack(mapDrawCall));
    end
    local minimapDrawCall = tremove(minimapDrawQueue, 1);
    if(minimapDrawCall) then
        HBDPins:AddMinimapIconMap(tunpack(minimapDrawCall));
    end
end

-- Show NPC on map
-- This function does the same for manualFrames as similar functions in
-- QuestieQuest do for questIdFrames
---@param npcID integer @The ID of the NPC
function QuestieMap:ShowNPC(npcID)
    if type(npcID) ~= "number" then return end
    -- get the NPC data
    local npc = QuestieDB:GetNPC(npcID)
    if npc == nil then return end

    -- create the icon data
    local data = {}
    data.id = npc.id
    data.Icon = "Interface\\WorldMap\\WorldMapPartyIcon"
    data.GetIconScale = function() return Questie.db.global.manualScale or 0.7 end
    data.IconScale = data:GetIconScale()
    data.Type = "manual"
    data.spawnType = "monster"
    data.npcData = npc
    data.Name = npc.name
    data.IsObjectiveNote = false
    data.ManualTooltipData = {}
    data.ManualTooltipData.Title = npc.name.." (NPC)"
    local level = tostring(npc.minLevel)
    local health = tostring(npc.minLevelHealth)
    if npc.minLevel ~= npc.maxLevel then
        level = level..'-'..tostring(npc.maxLevel)
        health = health..'-'..tostring(npc.maxLevelHealth)
    end
    data.ManualTooltipData.Body = {
        {'ID:', tostring(npc.id)},
        {'Level:', level},
        {'Health:', health},
    }

    -- draw the notes
    for zone, spawns in pairs(npc.spawns) do
        if(zone ~= nil and spawns ~= nil) then
            for _, coords in ipairs(spawns) do
                -- instance spawn, draw entrance on map
                if (instanceData[zone] ~= nil) then
                    for index, value in ipairs(instanceData[zone]) do
                        QuestieMap:DrawManualIcon(data, value[1], value[2], value[3])
                    end
                -- world spawn
                else
                    QuestieMap:DrawManualIcon(data, zone, coords[1], coords[2])
                end
            end
        end
    end
end

-- Show object on map
-- This function does the same for manualFrames as similar functions in
-- QuestieQuest do for questIdFrames
---@param objectID integer
function QuestieMap:ShowObject(objectID)
    if type(objectID) ~= "number" then return end
    -- get the gameobject data
    local object = QuestieDB:GetObject(objectID)
    if object == nil then return end

    -- create the icon data
    local data = {}
    data.id = -object.id
    data.Icon = "Interface\\WorldMap\\WorldMapPartyIcon"
    data.GetIconScale = function() return Questie.db.global.manualScale or 0.7 end
    data.IconScale = data:GetIconScale()
    data.Type = "manual"
    data.spawnType = "object"
    data.objectData = object
    data.Name = object.name
    data.IsObjectiveNote = false
    data.ManualTooltipData = {}
    data.ManualTooltipData.Title = object.name.." (object)"
    data.ManualTooltipData.Body = {
        {'ID:', tostring(object.id)},
    }

    -- draw the notes
    for zone, spawns in pairs(object.spawns) do
        if(zone ~= nil and spawns ~= nil) then
            for _, coords in ipairs(spawns) do
                -- instance spawn, draw entrance on map
                if (instanceData[zone] ~= nil) then
                    for index, value in ipairs(instanceData[zone]) do
                        QuestieMap:DrawManualIcon(data, value[1], value[2], value[3])
                    end
                -- world spawn
                else
                    QuestieMap:DrawManualIcon(data, zone, coords[1], coords[2])
                end
            end
        end
    end
end

function QuestieMap:DrawLineIcon(lineFrame, AreaID, x, y)
    if type(AreaID) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then
        error("Questie"..": AddWorldMapIconMap: 'AreaID', 'x' and 'y' must be numbers "..AreaID.." "..x.." "..y)
    end

    HBDPins:AddWorldMapIconMap(Questie, lineFrame, ZoneDataAreaIDToUiMapID[AreaID], x, y, HBD_PINS_WORLDMAP_SHOW_CURRENT)
end


-- Draw manually added NPC/object notes
-- TODO: item and custom notes
--@param data table<...> @A table created by the calling function, must contain `id`, `Name`, `GetIconScale()`, and `Type`
--@param AreaID integer @The zone ID from the raw data
--@param x float @The X coordinate in 0-100 format
--@param y float @The Y coordinate in 0-100 format
function QuestieMap:DrawManualIcon(data, AreaID, x, y)
    if type(data) ~= "table" then
        error("Questie"..": AddWorldMapIconMap: must have some data")
    end
    if type(AreaID) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then
        error("Questie"..": AddWorldMapIconMap: 'AreaID', 'x' and 'y' must be numbers "..AreaID.." "..x.." "..y)
    end
    if type(data.id) ~= "number" or type(data.id) ~= "number"then
        error("Questie".."Data.id must be set to the NPC or object ID!")
    end
    if ZoneDataAreaIDToUiMapID[AreaID] == nil then
        --Questie:Error("No UiMapID for ("..tostring(zoneDataClassic[AreaID])..") :".. AreaID .. tostring(data.Name))
        return nil, nil
    end
    -- set the icon
    local texture = "Interface\\WorldMap\\WorldMapPartyIcon"
    -- Save new zone ID format, used in QuestieFramePool
    data.UiMapID = ZoneDataAreaIDToUiMapID[AreaID]
    -- create a list for all frames belonging to a NPC (id > 0) or an object (id < 0)
    if(QuestieMap.manualFrames[data.id] == nil) then
        QuestieMap.manualFrames[data.id] = {}
    end

    -- create the map icon
    local icon = QuestieFramePool:GetFrame()
    icon.data = data
    icon.x = x
    icon.y = y
    icon.AreaID = AreaID -- used by QuestieFramePool
    icon.miniMapIcon = false;
    icon.texture:SetTexture(texture)
    icon:SetWidth(16 * (data:GetIconScale() or 0.7))
    icon:SetHeight(16 * (data:GetIconScale() or 0.7))

    -- add the map icon
    QuestieMap:QueueDraw(QuestieMap.ICON_MAP_TYPE, Questie, icon, data.UiMapID, x/100, y/100, 3) -- showFlag)
    tinsert(QuestieMap.manualFrames[data.id], icon:GetName())

    -- create the minimap icon
    local iconMinimap = QuestieFramePool:GetFrame()
    local colorsMinimap = {1, 1, 1}
    if data.IconColor ~= nil and Questie.db.global.questMinimapObjectiveColors then
        colorsMinimap = data.IconColor
    end
    iconMinimap:SetWidth(16 * ((data:GetIconScale() or 1) * (Questie.db.global.globalMiniMapScale or 0.7)))
    iconMinimap:SetHeight(16 * ((data:GetIconScale() or 1) * (Questie.db.global.globalMiniMapScale or 0.7)))
    iconMinimap.data = data
    iconMinimap.x = x
    iconMinimap.y = y
    iconMinimap.AreaID = AreaID -- used by QuestieFramePool
    iconMinimap.texture:SetTexture(texture)
    iconMinimap.texture:SetVertexColor(colorsMinimap[1], colorsMinimap[2], colorsMinimap[3], 1);
    iconMinimap.miniMapIcon = true;

    -- add the minimap icon
    QuestieMap:QueueDraw(QuestieMap.ICON_MINIMAP_TYPE, Questie, iconMinimap, data.UiMapID, x / 100, y / 100, true, true);
    tinsert(QuestieMap.manualFrames[data.id], iconMinimap:GetName())

    -- make sure notes are only shown when they are supposed to
    if (QuestieQuest.NotesHidden) then -- TODO: or (not Questie.db.global.manualNotes)
        icon:FakeHide()
        iconMinimap:FakeHide()
    else
        if (not Questie.db.global.enableMapIcons) then
            icon:FakeHide()
        end
        if (not Questie.db.global.enableMiniMapIcons) then
            iconMinimap:FakeHide()
        end
    end

    -- return the frames in case they need to be stored seperately from QuestieMap.manualFrames
    return icon, iconMinimap;
end

--A layer to keep the area convertion away from the other parts of the code
--coordinates need to be 0-1 instead of 0-100
--showFlag isn't required but may want to be Modified
function QuestieMap:DrawWorldIcon(data, AreaID, x, y, showFlag)
    if type(data) ~= "table" then
        error("Questie"..": AddWorldMapIconMap: must have some data")
    end
    if type(AreaID) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then
        error("Questie"..": AddWorldMapIconMap: 'AreaID', 'x' and 'y' must be numbers "..AreaID.." "..x.." "..y.." "..showFlag)
    end
    if type(data.Id) ~= "number" or type(data.Id) ~= "number"then
        error("Questie".."Data.Id must be set to the quests ID!")
    end
    if ZoneDataAreaIDToUiMapID[AreaID] == nil then
        --Questie:Error("No UiMapID for ("..tostring(zoneDataClassic[AreaID])..") :".. AreaID .. tostring(data.Name))
        return nil, nil
    end
    if(showFlag == nil) then showFlag = HBD_PINS_WORLDMAP_SHOW_WORLD; end
    -- if(floatOnEdge == nil) then floatOnEdge = true; end
    local floatOnEdge = true


    if AreaID then
        data.UiMapID = ZoneDataAreaIDToUiMapID[AreaID];
    end

    local icon = QuestieFramePool:GetFrame()
    icon.data = data
    icon.x = x
    icon.y = y
    icon.AreaID = AreaID
    icon.miniMapIcon = false;
    icon:UpdateTexture(data.Icon);

    local iconMinimap = QuestieFramePool:GetFrame()
    iconMinimap.data = data
    iconMinimap.x = x
    iconMinimap.y = y
    iconMinimap.AreaID = AreaID
    --data.refMiniMap = iconMinimap -- used for removing
    --Are we a minimap note?
    iconMinimap.miniMapIcon = true;
    iconMinimap:UpdateTexture(data.Icon);


    if(not iconMinimap.FadeLogic) then
        function iconMinimap:FadeLogic()
            if self.miniMapIcon and self.x and self.y and self.texture and self.data.UiMapID and self.texture.SetVertexColor and Questie and Questie.db and Questie.db.global and Questie.db.global.fadeLevel and HBD and HBD.GetPlayerZonePosition and QuestieLib and QuestieLib.Euclid then
                local playerX, playerY, playerInstanceID = HBD:GetPlayerWorldPosition()
                
                if(playerX and playerY) then
                    local x, y, instance = HBD:GetWorldCoordinatesFromZone(self.x/100, self.y/100, self.data.UiMapID)
                    if(x and y) then
                        local distance = QuestieLib:Euclid(playerX, playerY, x, y);

                        --Very small value before, hard to work with.
                        distance = distance / 10


                        local NormalizedValue = 1/fadeOverDistance; --Opacity / Distance to fade over

                        if(distance > Questie.db.global.fadeLevel) then
                            local fade = 1-(math.min(10, (distance-Questie.db.global.fadeLevel))*NormalizedValue);
                            local dr,dg,db = self.texture:GetVertexColor()
                            self.texture:SetVertexColor(dr, dg, db, fade)
                            if self.glowTexture and self.glowTexture.GetVertexColor then
                                local r,g,b = self.glowTexture:GetVertexColor()
                                self.glowTexture:SetVertexColor(r,g,b,fade)
                            end
                        elseif (distance < Questie.db.global.fadeOverPlayerDistance) and Questie.db.global.fadeOverPlayer then
                            local fadeAmount = QuestieLib:Remap(distance, 0, Questie.db.global.fadeOverPlayerDistance, Questie.db.global.fadeOverPlayerLevel, 1);
                            -- local fadeAmount = math.max(fadeAmount, 0.5);
                            if self.faded and fadeAmount > Questie.db.global.iconFadeLevel then fadeAmount = Questie.db.global.iconFadeLevel end
                            local dr,dg,db = self.texture:GetVertexColor()
                            self.texture:SetVertexColor(dr, dg, db, fadeAmount)
                            if self.glowTexture and self.glowTexture.GetVertexColor then
                                local r,g,b = self.glowTexture:GetVertexColor()
                                self.glowTexture:SetVertexColor(r,g,b,fadeAmount)
                            end
                        else
                            if self.faded then
                                local dr,dg,db = self.texture:GetVertexColor()
                                self.texture:SetVertexColor(dr, dg, db, Questie.db.global.iconFadeLevel)
                                if self.glowTexture and self.glowTexture.GetVertexColor then
                                    local r,g,b = self.glowTexture:GetVertexColor()
                                    self.glowTexture:SetVertexColor(r,g,b,Questie.db.global.iconFadeLevel)
                                end
                            else
                                local dr,dg,db = self.texture:GetVertexColor()
                                self.texture:SetVertexColor(dr, dg, db, 1)
                                if self.glowTexture and self.glowTexture.GetVertexColor then
                                    local r,g,b = self.glowTexture:GetVertexColor()
                                    self.glowTexture:SetVertexColor(r,g,b,1)
                                end
                            end
                        end
                    end
                else
                    if self.faded then
                        local dr,dg,db = self.texture:GetVertexColor()
                        self.texture:SetVertexColor(dr, dg, db, Questie.db.global.iconFadeLevel)
                        if self.glowTexture and self.glowTexture.GetVertexColor then
                            local r,g,b = self.glowTexture:GetVertexColor()
                            self.glowTexture:SetVertexColor(r,g,b,Questie.db.global.iconFadeLevel)
                        end
                    else
                        local dr,dg,db = self.texture:GetVertexColor()
                        self.texture:SetVertexColor(dr, dg, db, 1)
                        if self.glowTexture and self.glowTexture.GetVertexColor then
                            local r,g,b = self.glowTexture:GetVertexColor()
                            self.glowTexture:SetVertexColor(r,g,b,1)
                        end
                    end
                end
            end
        end
        -- We do not want to hook the OnUpdate again!
        -- iconMinimap:SetScript("OnUpdate", )
    end

    QuestieMap:QueueDraw(QuestieMap.ICON_MINIMAP_TYPE, Questie, iconMinimap, ZoneDataAreaIDToUiMapID[AreaID], x / 100, y / 100, true, floatOnEdge)
    QuestieMap:QueueDraw(QuestieMap.ICON_MAP_TYPE, Questie, icon, ZoneDataAreaIDToUiMapID[AreaID], x / 100, y / 100, showFlag)
    local r, g, b = iconMinimap.texture:GetVertexColor()
    QuestieDBMIntegration:RegisterHudQuestIcon(tostring(icon), data.Icon, ZoneDataAreaIDToUiMapID[AreaID], x, y, r, g, b)

    if(QuestieMap.questIdFrames[data.Id] == nil) then
        QuestieMap.questIdFrames[data.Id] = {}
    end

    tinsert(QuestieMap.questIdFrames[data.Id], icon:GetName())
    tinsert(QuestieMap.questIdFrames[data.Id], iconMinimap:GetName())


    --Hide unexplored logic
    if(not QuestieMap.utils:IsExplored(icon.data.UiMapID, x, y) and Questie.db.global.hideUnexploredMapIcons) then
        icon:FakeHide()
        iconMinimap:FakeHide()
    end

    -- preset hidden state when needed (logic from QuestieQuest:UpdateHiddenNotes
    -- we should add all this code to something like obj:CheckHide() instead of copying it
    if (QuestieQuest.NotesHidden or (((not Questie.db.global.enableObjectives) and (icon.data.Type == "monster" or icon.data.Type == "object" or icon.data.Type == "event" or icon.data.Type == "item"))
                or ((not Questie.db.global.enableTurnins) and icon.data.Type == "complete")
                or ((not Questie.db.global.enableAvailable) and icon.data.Type == "available"))
                or ((not Questie.db.global.enableMapIcons) and (not icon.miniMapIcon))
                or ((not Questie.db.global.enableMiniMapIcons) and (icon.miniMapIcon))) or (icon.data.ObjectiveData and icon.data.ObjectiveData.HideIcons) or (icon.data.QuestData and icon.data.QuestData.HideIcons and icon.data.Type ~= "complete") then
        icon:FakeHide()
        iconMinimap:FakeHide()
    end

    return icon, iconMinimap;
end

local closestStarter = {}
function QuestieMap:FindClosestStarter()
    local playerX, playerY, instance = HBD:GetPlayerWorldPosition();
    local playerZone = HBD:GetPlayerWorldPosition();
    for questId in pairs(QuestiePlayer.currentQuestlog) do
        if(not closestStarter[questId]) then
            local quest = QuestieDB:GetQuest(questId);
            if quest then
                closestStarter[questId] = {}
                closestStarter[questId].distance = 999999;
                closestStarter[questId].x = -1;
                closestStarter[questId].y = -1;
                closestStarter[questId].zone = -1;
                closestStarter[questId].type = "";
                for starterType, starters in pairs(quest.Starts) do
                        if(starterType == "GameObject") then
                            for index, ObjectID in ipairs(starters or {}) do
                                local obj = QuestieDB:GetObject(ObjectID)
                                if(obj ~= nil and obj.spawns ~= nil) then
                                    for Zone, Spawns in pairs(obj.spawns) do
                                        if(Zone ~= nil and Spawns ~= nil) then
                                            for _, coords in ipairs(Spawns) do
                                                if(coords[1] == -1 or coords[2] == -1) then
                                                    if(instanceData[Zone] ~= nil) then
                                                        for index, value in ipairs(instanceData[Zone]) do
                                                            if(value[1] and value[2]) then
                                                                local x, y, instance = HBD:GetWorldCoordinatesFromZone(value[1]/100, value[2]/100, ZoneDataAreaIDToUiMapID[value[3]])
                                                                if(x and y) then
                                                                    local distance = QuestieLib:Euclid(playerX or 0, playerY or 0, x, y);
                                                                    --Questie:Print(x, y, ZoneDataAreaIDToUiMapID[Zone], distance)
                                                                    if(closestStarter[questId].distance > distance) then
                                                                        closestStarter[questId].distance = distance;
                                                                        closestStarter[questId].x = x;
                                                                        closestStarter[questId].y = y;
                                                                        closestStarter[questId].zone = ZoneDataAreaIDToUiMapID[Zone];
                                                                        closestStarter[questId].type = "GameObject - " .. obj.name;
                                                                    end
                                                                end
                                                            end
                                                        end
                                                    end
                                                else
                                                    local x, y, instance = HBD:GetWorldCoordinatesFromZone(coords[1]/100, coords[2]/100, ZoneDataAreaIDToUiMapID[Zone])
                                                    if(x and y) then
                                                        local distance = QuestieLib:Euclid(playerX or 0, playerY or 0, x, y);
                                                        --Questie:Print(x, y, ZoneDataAreaIDToUiMapID[Zone], distance)
                                                        if(closestStarter[questId].distance > distance) then
                                                            closestStarter[questId].distance = distance;
                                                            closestStarter[questId].x = x;
                                                            closestStarter[questId].y = y;
                                                            closestStarter[questId].zone = ZoneDataAreaIDToUiMapID[Zone];
                                                            closestStarter[questId].type = "GameObject - " .. obj.name;
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        elseif(starterType == "NPC") then
                            for index, NPCID in ipairs(starters or {}) do
                                local NPC = QuestieDB:GetNPC(NPCID)
                                if (NPC ~= nil and NPC.spawns ~= nil and NPC.friendly) then
                                    for Zone, Spawns in pairs(NPC.spawns) do
                                        if(Zone ~= nil and Spawns ~= nil) then
                                            for _, coords in ipairs(Spawns) do
                                                if(coords[1] == -1 or coords[2] == -1) then
                                                    if(instanceData[Zone] ~= nil) then
                                                        for index, value in ipairs(instanceData[Zone]) do
                                                            if(value[1] and value[2]) then
                                                                local x, y, instance = HBD:GetWorldCoordinatesFromZone(value[1]/100, value[2]/100, ZoneDataAreaIDToUiMapID[value[3]])
                                                                if(x and y) then
                                                                    local distance = QuestieLib:Euclid(playerX or 0, playerY or 0, x, y);
                                                                    --Questie:Print(x, y, ZoneDataAreaIDToUiMapID[Zone], distance)
                                                                    if(closestStarter[questId].distance > distance) then
                                                                        closestStarter[questId].distance = distance;
                                                                        closestStarter[questId].x = x;
                                                                        closestStarter[questId].y = y;
                                                                        closestStarter[questId].zone = ZoneDataAreaIDToUiMapID[Zone];
                                                                        closestStarter[questId].type = "NPC - ".. NPC.name;
                                                                    end
                                                                end
                                                            end
                                                        end
                                                    end
                                                elseif(coords[1] and coords[2]) then
                                                    local x, y, instance = HBD:GetWorldCoordinatesFromZone(coords[1]/100, coords[2]/100, ZoneDataAreaIDToUiMapID[Zone])
                                                    if(x and y) then
                                                        local distance = QuestieLib:Euclid(playerX or 0, playerY or 0, x, y);
                                                        --Questie:Print(x, y, ZoneDataAreaIDToUiMapID[Zone], distance)
                                                        if(closestStarter[questId].distance > distance) then
                                                            closestStarter[questId].distance = distance;
                                                            closestStarter[questId].x = x;
                                                            closestStarter[questId].y = y;
                                                            closestStarter[questId].zone = ZoneDataAreaIDToUiMapID[Zone];
                                                            closestStarter[questId].type = "NPC - ".. NPC.name;
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                if(closestStarter[questId].x == -1) then
                    closestStarter[questId].distance = 0;
                    closestStarter[questId].x = playerX;
                    closestStarter[questId].y = playerY;
                    closestStarter[questId].zone = playerZone;
                    closestStarter[questId].type = "player";
                end
            end
        end
    end
    return closestStarter;
end

function QuestieMap:GetNearestSpawn(Objective)
    local playerX, playerY, playerI = HBD:GetPlayerWorldPosition()
    local bestDistance = 999999999
    local bestSpawn, bestSpawnZone, bestSpawnId, bestSpawnType, bestSpawnName
    if Objective.spawnList then
        for id, spawnData in pairs(Objective.spawnList) do
            for zone, spawns in pairs(spawnData.Spawns) do
                for _,spawn in pairs(spawns) do
                    local dX, dY, dInstance = HBD:GetWorldCoordinatesFromZone(spawn[1]/100.0, spawn[2]/100.0, ZoneDataAreaIDToUiMapID[zone])
                    --print (" " .. tostring(dX) .. " " .. tostring(dY) .. " " .. ZoneDataAreaIDToUiMapID[zone])
                    local dist = HBD:GetWorldDistance(dInstance, playerX, playerY, dX, dY)
                    if dist then
                        if dInstance ~= playerI then
                            dist = 500000 + dist * 100 -- hack
                        end
                        if dist < bestDistance then
                            bestDistance = dist
                            bestSpawn = spawn
                            bestSpawnZone = zone
                            bestSpawnId = id
                            bestSpawnType = spawnData.Type
                            bestSpawnName = spawnData.Name
                        end
                    end
                end
            end
        end
    end
    return bestSpawn, bestSpawnZone, bestSpawnName, bestSpawnId, bestSpawnType, bestDistance
end

function QuestieMap:GetNearestQuestSpawn(Quest)
    if QuestieQuest:IsComplete(Quest) then
        local finisher = nil
        if Quest.Finisher ~= nil then
            if Quest.Finisher.Type == "monster" then
                finisher = QuestieDB:GetNPC(Quest.Finisher.Id)
            elseif Quest.Finisher.Type == "object" then
                finisher = QuestieDB:GetObject(Quest.Finisher.Id)
            end
        end
        if finisher and finisher.spawns then -- redundant code
            local bestDistance = 999999999
            local playerX, playerY, playerI = HBD:GetPlayerWorldPosition()
            local bestSpawn, bestSpawnZone, bestSpawnId, bestSpawnType, bestSpawnName
            for zone, spawns in pairs(finisher.spawns) do
                for _, spawn in pairs(spawns) do
                    local dX, dY, dInstance = HBD:GetWorldCoordinatesFromZone(spawn[1]/100.0, spawn[2]/100.0, ZoneDataAreaIDToUiMapID[zone])
                    --print (" " .. tostring(dX) .. " " .. tostring(dY) .. " " .. ZoneDataAreaIDToUiMapID[zone])
                    local dist = HBD:GetWorldDistance(dInstance, playerX, playerY, dX, dY)
                    if dist then
                        if dInstance ~= playerI then
                            dist = 500000 + dist * 100 -- hack
                        end
                        if dist < bestDistance then
                            bestDistance = dist
                            bestSpawn = spawn
                            bestSpawnZone = zone
                            bestSpawnType = Quest.Finisher.Type
                            bestSpawnName = finisher.LocalizedName or finisher.name
                        end
                    end
                end
            end
            return bestSpawn, bestSpawnZone, bestSpawnName, bestSpawnId, bestSpawnType, bestDistance
        end
        return nil
    end
    local bestDistance = 999999999
    local bestSpawn, bestSpawnZone, bestSpawnId, bestSpawnType, bestSpawnName
    for _,Objective in pairs(Quest.Objectives) do
        local spawn, zone, Name, id, Type, dist = QuestieMap:GetNearestSpawn(Objective)
        if spawn and dist < bestDistance and ((not Objective.Needed) or Objective.Needed ~= Objective.Collected) then
            bestDistance = dist
            bestSpawn = spawn
            bestSpawnZone = zone
            bestSpawnId = id
            bestSpawnType = Type
            bestSpawnName = Name
        end
    end
    if Quest.SpecialObjectives then
        for _,Objective in pairs(Quest.SpecialObjectives) do
            local spawn, zone, Name, id, Type, dist = QuestieMap:GetNearestSpawn(Objective)
            if spawn and dist < bestDistance and ((not Objective.Needed) or Objective.Needed ~= Objective.Collected) then
                bestDistance = dist
                bestSpawn = spawn
                bestSpawnZone = zone
                bestSpawnId = id
                bestSpawnType = Type
                bestSpawnName = Name
            end
        end
    end
    return bestSpawn, bestSpawnZone, bestSpawnName, bestSpawnId, bestSpawnType, bestDistance
end
