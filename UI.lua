-- GildenPuls – UI
-- Pop-up-Benachrichtigungen ("Toasts"), die im Spielbild und damit im Stream erscheinen.

local ADDON, ns = ...

local TOAST_W, TOAST_H = 330, 60
local SPACING, MAX_TOASTS = 6, 4
local FADE_IN, FADE_OUT = 0.25, 0.6
local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

local anchor
local active, pool = {}, {}

---------------------------------------------------------------------------
-- Aussehen je Event-Typ
---------------------------------------------------------------------------
local STYLES = {
  LEVEL     = { title = "LEVEL UP",          icon = "Interface\\Icons\\Spell_Holy_HolyBolt",          color = { 1.00, 0.82, 0.00 }, sound = "READY_CHECK" },
  MILESTONE = { title = "MEILENSTEIN!",      icon = "Interface\\Icons\\Spell_Holy_HolyBolt",          color = { 1.00, 0.55, 0.00 }, sound = "READY_CHECK" },
  MAX       = { title = "MAX LEVEL!",        icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01",      color = { 0.64, 0.21, 0.93 }, sound = "READY_CHECK" },
  DEATH     = { title = "GESTORBEN",         icon = "Interface\\Icons\\Ability_Rogue_FeignDeath",     color = { 0.85, 0.10, 0.10 }, sound = "RAID_WARNING" },
  JOIN      = { title = "NEU IN DER GILDE",  icon = "Interface\\Icons\\Ability_Warrior_BattleShout",  color = { 0.20, 0.80, 0.30 }, sound = "IG_PLAYER_INVITE" },
  LEAVE     = { title = "GILDE VERLASSEN",   icon = "Interface\\Icons\\Ability_Rogue_Sprint",         color = { 0.55, 0.55, 0.55 } },
}

local function StyleKey(ev)
  if ev.type == "LEVEL" then
    if ev.level and ev.level >= ns.MAX_LEVEL then return "MAX" end
    if ev.level and ev.level % 10 == 0 then return "MILESTONE" end
  end
  return ev.type
end

local function ClassColored(name, class)
  local short = ns.Short(name)
  local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  if not c then return short end
  return ("|cff%02x%02x%02x%s|r"):format(
    math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255), short)
end

-- Liefert Zeile 1 und Zeile 2 für Pop-up und Verlauf
local function Lines(ev)
  local who = ClassColored(ev.name, ev.class)
  if ev.type == "LEVEL" then
    return ("%s ist jetzt |cffffffffLevel %d|r"):format(who, ev.level or 0), ev.zone
  elseif ev.type == "DEATH" then
    local l1 = ev.level and ("%s (Lvl %d) ist gestorben"):format(who, ev.level)
      or ("%s ist gestorben"):format(who)
    local parts = {}
    if ev.killer then parts[#parts + 1] = "durch " .. ev.killer end
    if ev.zone then parts[#parts + 1] = ev.zone end
    return l1, table.concat(parts, " · ")
  elseif ev.type == "JOIN" then
    return ("%s ist der Gilde beigetreten"):format(who), "Willkommen!"
  elseif ev.type == "LEAVE" then
    return ("%s hat die Gilde verlassen"):format(who), nil
  end
  return who, nil
end

function ns.Describe(ev)
  local style = STYLES[StyleKey(ev)] or STYLES.LEVEL
  local l1, l2 = Lines(ev)
  return ("[%s] %s%s"):format(style.title, l1, (l2 and l2 ~= "") and (" – " .. l2) or "")
end

---------------------------------------------------------------------------
-- Toasts
---------------------------------------------------------------------------
local function Layout()
  for i, t in ipairs(active) do
    t:ClearAllPoints()
    t:SetPoint("TOP", anchor, "TOP", 0, -(i - 1) * (TOAST_H + SPACING))
  end
end

local function Release(t)
  for i, a in ipairs(active) do
    if a == t then table.remove(active, i) break end
  end
  t:Hide()
  pool[#pool + 1] = t
  Layout()
end

local function OnToastUpdate(self, elapsed)
  self.age = self.age + elapsed
  local dur = ns.db.settings.duration
  if self.age < FADE_IN then
    self:SetAlpha(self.age / FADE_IN)
  elseif self.age < dur then
    self:SetAlpha(1)
  elseif self.age < dur + FADE_OUT then
    self:SetAlpha(1 - (self.age - dur) / FADE_OUT)
  else
    Release(self)
  end
end

local function CreateToast()
  local t = CreateFrame("Frame", nil, anchor, BACKDROP_TEMPLATE)
  t:SetSize(TOAST_W, TOAST_H)
  t:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 2,
  })
  t:SetBackdropColor(0.04, 0.04, 0.06, 0.90)

  t.bar = t:CreateTexture(nil, "ARTWORK")
  t.bar:SetPoint("TOPLEFT", 2, -2)
  t.bar:SetPoint("BOTTOMLEFT", 2, 2)
  t.bar:SetWidth(4)
  t.bar:SetTexture("Interface\\Buttons\\WHITE8X8")

  t.icon = t:CreateTexture(nil, "ARTWORK")
  t.icon:SetSize(44, 44)
  t.icon:SetPoint("LEFT", 12, 0)
  t.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  t.title = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  t.title:SetPoint("TOPLEFT", t.icon, "TOPRIGHT", 10, -1)

  t.line1 = t:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  t.line1:SetPoint("TOPLEFT", t.title, "BOTTOMLEFT", 0, -3)
  t.line1:SetWidth(TOAST_W - 76)
  t.line1:SetJustifyH("LEFT")
  t.line1:SetWordWrap(false)

  t.line2 = t:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  t.line2:SetPoint("TOPLEFT", t.line1, "BOTTOMLEFT", 0, -3)
  t.line2:SetWidth(TOAST_W - 76)
  t.line2:SetJustifyH("LEFT")
  t.line2:SetWordWrap(false)

  t:SetScript("OnUpdate", OnToastUpdate)
  t:Hide()
  return t
end

local function PlayFor(style)
  if not ns.db.settings.sound or not style.sound then return end
  local id = SOUNDKIT and SOUNDKIT[style.sound]
  if id then PlaySound(id, "Master") end
end

function ns.ShowToast(ev)
  if not anchor then return end
  local style = STYLES[StyleKey(ev)] or STYLES.LEVEL
  local t = table.remove(pool) or CreateToast()
  local r, g, b = unpack(style.color)
  local l1, l2 = Lines(ev)

  t.icon:SetTexture(style.icon)
  t.title:SetText(style.title)
  t.title:SetTextColor(r, g, b)
  t.bar:SetVertexColor(r, g, b)
  t:SetBackdropBorderColor(r, g, b, 0.9)
  t.line1:SetText(l1)
  t.line2:SetText(l2 or "")

  t.age = 0
  t:SetAlpha(0)
  t:Show()
  table.insert(active, 1, t)
  while #active > MAX_TOASTS do Release(active[#active]) end
  Layout()
  PlayFor(style)
end

---------------------------------------------------------------------------
-- Anker (Position) – mit /gp unlock verschiebbar
---------------------------------------------------------------------------
function ns.ApplyScale()
  if anchor then anchor:SetScale(ns.db.settings.scale or 1) end
end

function ns.SetLocked(locked)
  ns.db.settings.locked = locked
  anchor:EnableMouse(not locked)
  if locked then
    anchor:SetBackdropColor(0, 0, 0, 0)
    anchor:SetBackdropBorderColor(0, 0, 0, 0)
    anchor.label:Hide()
  else
    anchor:SetBackdropColor(1, 0.82, 0, 0.25)
    anchor:SetBackdropBorderColor(1, 0.82, 0, 1)
    anchor.label:Show()
  end
end

function ns.InitUI()
  local s = ns.db.settings
  anchor = CreateFrame("Frame", "GildenPulsAnchor", UIParent, BACKDROP_TEMPLATE)
  anchor:SetSize(TOAST_W, TOAST_H)
  anchor:SetPoint(s.point[1], UIParent, s.point[2], s.point[3], s.point[4])
  anchor:SetFrameStrata("HIGH")
  anchor:SetClampedToScreen(true)
  anchor:SetMovable(true)
  anchor:RegisterForDrag("LeftButton")
  anchor:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
  })
  anchor:SetScript("OnDragStart", anchor.StartMoving)
  anchor:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    s.point = { p, rp, x, y }
  end)

  anchor.label = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  anchor.label:SetPoint("CENTER")
  anchor.label:SetText("GildenPuls – zum Verschieben ziehen")

  ns.ApplyScale()
  ns.SetLocked(s.locked)
end
