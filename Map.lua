-- GildenPuls – Weltkarte
-- Zeigt Gildenmitglieder (mit GildenPuls) als Punkte auf der Weltkarte.
-- Jeder Spieler schickt seine Position unsichtbar an die Gilde; angezeigt wird
-- in Weltkoordinaten, damit es auf Zonen-, Kontinent- und Weltkarte passt.

local ADDON, ns = ...

local SEND_EVERY  = 10    -- Sekunden zwischen Positions-Updates
local HEARTBEAT   = 60    -- spätestens dann auch ohne Bewegung senden
local EXPIRE      = 45    -- Sekunden ohne Update → Punkt verschwindet
local MOVE_YARDS  = 8     -- erst ab dieser Bewegung neu senden
local PIN_SIZE    = 14

ns.positions = {}         -- [Schlüssel] = { name, cont, x, y, map, level, class, t, hidden }

---------------------------------------------------------------------------
-- Hilfsfunktionen
---------------------------------------------------------------------------
local function IsSecret(v)
  return issecretvalue and issecretvalue(v) or false
end

-- Eigene Position in Weltkoordinaten (oder nil, wenn WoW sie gerade nicht hergibt)
local function MyWorldPos()
  if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and C_Map.GetWorldPosFromMapPos) then return end
  local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
  if not ok or not mapID or IsSecret(mapID) then return end
  local ok2, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
  if not ok2 or not pos then return end
  local ok3, cont, world = pcall(C_Map.GetWorldPosFromMapPos, mapID, pos)
  if not ok3 or not cont or not world then return end
  local ok4, x, y = pcall(world.GetXY, world)
  if not ok4 or type(x) ~= "number" or type(y) ~= "number" or IsSecret(x) or IsSecret(y) then return end
  return cont, x, y, mapID
end

local function ClassColor(class)
  local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  if c then return c.r, c.g, c.b end
  return 1, 0.82, 0
end

---------------------------------------------------------------------------
-- Senden
---------------------------------------------------------------------------
local last = { t = 0 }

local function SendPosition(force)
  if not IsInGuild() or not ns.session then return end
  local now = GetTime()
  local _, classFile = UnitClass("player")
  local level = UnitLevel("player") or 0

  local inInstance = IsInInstance and IsInInstance()
  local cont, x, y, mapID
  if not inInstance then cont, x, y, mapID = MyWorldPos() end

  if not cont then
    -- in Dungeon/Raid oder Position gerade gesperrt: einmal "versteckt" melden
    if last.hidden and not force and now - last.t < HEARTBEAT then return end
    if ns.TrySend(("POS;-1;0;0;0;%d;%s;%s;%s"):format(level, classFile or "", inInstance and "I" or "", ns.session)) then
      last = { t = now, hidden = true }
    end
    return
  end

  local moved = not last.x or last.cont ~= cont or math.abs(last.x - x) + math.abs(last.y - y) > MOVE_YARDS
  if not force and not moved and now - last.t < HEARTBEAT then return end
  if ns.TrySend(("POS;%d;%.1f;%.1f;%d;%d;%s;;%s"):format(cont, x, y, mapID or 0, level, classFile or "", ns.session)) then
    last = { t = now, cont = cont, x = x, y = y }
  end
end

---------------------------------------------------------------------------
-- Empfangen  (POS;cont;x;y;map;level;class;flag;session)
---------------------------------------------------------------------------
function ns.OnPosition(sender, p)
  local cont, x, y = tonumber(p[2]), tonumber(p[3]), tonumber(p[4])
  local key = ns.Key(sender)
  if not key or not cont then return end
  ns.positions[key] = {
    name = sender, cont = cont, x = x, y = y, map = tonumber(p[5]),
    level = tonumber(p[6]), class = (p[7] ~= "" and p[7]) or nil,
    hidden = cont < 0, instance = p[8] == "I", t = GetTime(),
  }
  if ns.RefreshMap then ns.RefreshMap() end
end

---------------------------------------------------------------------------
-- Anzeige auf der Weltkarte
---------------------------------------------------------------------------
local pins, used = {}, 0

local function CreatePin(canvas)
  local pin = CreateFrame("Frame", nil, canvas)
  pin:SetSize(PIN_SIZE, PIN_SIZE)
  pin:EnableMouse(true)

  pin.border = pin:CreateTexture(nil, "BACKGROUND")
  pin.border:SetTexture("Interface\\Buttons\\WHITE8X8")
  pin.border:SetVertexColor(0, 0, 0, 0.9)
  pin.border:SetPoint("CENTER")
  pin.border:SetSize(PIN_SIZE + 4, PIN_SIZE + 4)

  pin.dot = pin:CreateTexture(nil, "ARTWORK")
  pin.dot:SetTexture("Interface\\Buttons\\WHITE8X8")
  pin.dot:SetPoint("CENTER")
  pin.dot:SetSize(PIN_SIZE, PIN_SIZE)

  if pin.CreateMaskTexture then
    local mask = pin:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(pin.border)
    pin.border:AddMaskTexture(mask)
    local mask2 = pin:CreateMaskTexture()
    mask2:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask2:SetAllPoints(pin.dot)
    pin.dot:AddMaskTexture(mask2)
  end

  pin.label = pin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  pin.label:SetPoint("TOP", pin, "BOTTOM", 0, -1)
  pin.label:SetShadowOffset(1, -1)

  pin:SetScript("OnEnter", function(self)
    local d = self.data
    if not d then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ns.Short(d.name), ClassColor(d.class))
    if d.level and d.level > 0 then GameTooltip:AddLine("Level " .. d.level, 1, 1, 1) end
    local info = d.map and d.map > 0 and C_Map.GetMapInfo and C_Map.GetMapInfo(d.map)
    if info and info.name then GameTooltip:AddLine(info.name, 0.7, 0.7, 0.7) end
    if d.test then GameTooltip:AddLine("(Testpunkt)", 0.6, 0.6, 0.6) end
    GameTooltip:Show()
  end)
  pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return pin
end

local function Place(pin, canvas, scale, mx, my)
  pin:SetScale(scale)
  pin:ClearAllPoints()
  pin:SetPoint("CENTER", canvas, "TOPLEFT", canvas:GetWidth() * mx / scale, -canvas:GetHeight() * my / scale)
end

function ns.RefreshMap()
  local map = WorldMapFrame
  if not map or not map:IsShown() or not map.GetCanvas then return end
  local canvas = map:GetCanvas()
  local mapID = map:GetMapID()
  if not canvas or not mapID then return end

  local canvasScale = (map.GetCanvasScale and map:GetCanvasScale()) or 1
  local scale = 1 / canvasScale
  local now = GetTime()
  used = 0

  for key, d in pairs(ns.positions) do
    if now - d.t > EXPIRE then
      ns.positions[key] = nil
    elseif not d.hidden and d.cont and d.x then
      local ok, onMap, pos = pcall(C_Map.GetMapPosFromWorldPos, d.cont, CreateVector2D(d.x, d.y), mapID)
      if ok and onMap and pos then
        local mx, my = pos:GetXY()
        if mx and my and mx >= 0 and mx <= 1 and my >= 0 and my <= 1 then
          used = used + 1
          local pin = pins[used] or CreatePin(canvas)
          pins[used] = pin
          pin:SetParent(canvas)
          pin:SetFrameLevel(canvas:GetFrameLevel() + 100)
          pin.data = d
          local r, g, b = ClassColor(d.class)
          pin.dot:SetVertexColor(r, g, b)
          pin.label:SetText(ns.Short(d.name))
          pin.label:SetTextColor(r, g, b)
          Place(pin, canvas, scale, mx, my)
          pin:Show()
        end
      end
    end
  end
  for i = used + 1, #pins do pins[i]:Hide() end
end

---------------------------------------------------------------------------
-- Test: Beispielpunkte rund um die eigene Position
---------------------------------------------------------------------------
function ns.MapTest()
  local cont, x, y, mapID = MyWorldPos()
  if not cont then
    ns.Print("Deine Position ist gerade nicht verfügbar (Dungeon oder Kampf?). Versuch es draußen nochmal.")
    return
  end
  local fake = {
    { "Testkrieger", "WARRIOR", 120, 40, 23 }, { "Testmagierin", "MAGE", -90, 150, 31 },
    { "Testjäger", "HUNTER", 300, -200, 18 }, { "Testpriester", "PRIEST", -400, -120, 27 },
  }
  for _, f in ipairs(fake) do
    ns.positions["test-" .. f[1]] = {
      name = f[1], class = f[2], cont = cont, x = x + f[3], y = y + f[4], map = mapID,
      level = f[5], t = GetTime() + 60, test = true,   -- bleiben ca. 100 Sekunden
    }
  end
  ns.RefreshMap()
  ns.Print("4 Testpunkte rund um dich gesetzt – öffne die Weltkarte (M).")
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
function ns.InitMap()
  -- regelmäßig senden
  C_Timer.After(8, function() SendPosition(true) end)
  C_Timer.NewTicker(SEND_EVERY, function() SendPosition(false) end)

  local map = WorldMapFrame
  if not map or not map.GetCanvas then return end   -- Kartenanzeige in diesem Client nicht möglich

  map:HookScript("OnShow", ns.RefreshMap)
  if map.OnMapChanged then hooksecurefunc(map, "OnMapChanged", ns.RefreshMap) end
  if map.OnCanvasScaleChanged then hooksecurefunc(map, "OnCanvasScaleChanged", ns.RefreshMap) end
  C_Timer.NewTicker(1, function() if map:IsShown() then ns.RefreshMap() end end)
end

-- Beim Zonenwechsel sofort senden
local f = CreateFrame("Frame")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function() C_Timer.After(3, function() SendPosition(true) end) end)
