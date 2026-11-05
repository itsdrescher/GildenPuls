-- GildenPuls – Core
-- Erkennt Level-Ups, Tode, Beitritte und Austritte in der Gilde und
-- teilt eigene Events unsichtbar mit allen Gildenmitgliedern, die das Addon nutzen.

local ADDON, ns = ...

local PREFIX      = "GildenPuls"   -- max. 16 Zeichen
local MAX_EVENTS  = 500            -- so viele Events bleiben im Verlauf gespeichert
local ROSTER_POLL = 20             -- Sekunden zwischen Roster-Abfragen
ns.MAX_LEVEL      = 60

ns.addonUsers = {}   -- [Schlüssel] = { name = Name-Realm, v = Version }
ns.reported   = {}   -- [Name-Realm] = höchstes bereits gemeldetes Level
ns.lastDeath  = {}   -- [Name-Realm] = GetTime() des letzten gemeldeten Todes
ns.classOf    = {}   -- [Name-Realm] = Klassen-Token (z. B. "WARRIOR")

---------------------------------------------------------------------------
-- Hilfsfunktionen
---------------------------------------------------------------------------
local function GetVersion()
  local fn = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  local v = fn and fn(ADDON, "Version")
  if not v or v:find("@", 1, true) then v = "dev" end
  return v
end
ns.VERSION = GetVersion()

local defaults = {
  settings = {
    point         = { "TOP", "TOP", 0, -140 },
    locked        = true,
    sound         = true,
    duration      = 7,
    scale         = 1,
    showJoinLeave = true,
  },
  guild  = nil,
  roster = {},   -- [Name-Realm] = Level (letzter bekannter Stand)
  events = {},   -- Verlauf, Grundlage für spätere Statistiken/Website
}

local function CopyDefaults(src, dst)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      CopyDefaults(v, dst[k])
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

local function Normalize(name)
  if not name or name == "" then return nil end
  if not name:find("-", 1, true) and ns.myRealm then
    return name .. "-" .. ns.myRealm
  end
  return name
end
ns.Normalize = Normalize

-- Vergleichs-Schlüssel: Groß/Klein, Leerzeichen, Bindestriche und Apostrophe im
-- Realm-Namen werden ignoriert ("Michael-Die Aldor" == "michael-diealdor").
local function Key(name)
  name = Normalize(name)
  if not name then return nil end
  local short, realm = name:match("^([^-]+)-(.+)$")
  if not short then short, realm = name, ns.myRealm or "" end
  realm = realm:gsub("[%s%-']", "")
  return (short .. "-" .. realm):lower()
end
ns.Key = Key

-- Zufällige Kennung dieser Spielsitzung: so erkennt das Addon seine eigenen
-- Nachrichten sicher wieder, egal wie WoW den Absender schreibt.
ns.session = ("%06x%04x"):format(math.random(0, 0xFFFFFF), math.floor(GetTime() * 1000) % 0xFFFF)

function ns.Short(name)
  return name and (name:match("^[^-]+") or name) or "?"
end

local function Clean(s)
  if not s or s == "" then return "" end
  return (s:gsub(";", ","))
end

local function Zone()
  return GetRealZoneText() or GetZoneText() or ""
end

local function MyClass()
  local _, classFile = UnitClass("player")
  return classFile
end

local function Print(msg)
  print("|cffffd100GildenPuls:|r " .. msg)
end
ns.Print = Print

---------------------------------------------------------------------------
-- Events speichern und anzeigen
---------------------------------------------------------------------------
function ns.Fire(ev, silent)
  ev.t = ev.t or time()
  local list = ns.db.events
  list[#list + 1] = ev
  while #list > MAX_EVENTS do table.remove(list, 1) end
  if not silent and ns.ShowToast then ns.ShowToast(ev) end
end

local function ReportLevel(name, level, classFile, zone, source)
  local k = Key(name)
  if not k or not level then return end
  if level <= (ns.reported[k] or 0) then return end   -- schon gemeldet
  ns.reported[k] = level
  if classFile then ns.classOf[k] = classFile end
  ns.Fire({
    type = "LEVEL", name = name, level = level,
    class = classFile or ns.classOf[k],
    zone = (zone ~= "" and zone) or nil, source = source,
  })
end

local function ReportDeath(name, level, classFile, zone, killer)
  local k = Key(name)
  if not k then return end
  local now = GetTime()
  if ns.lastDeath[k] and now - ns.lastDeath[k] < 20 then return end   -- doppelte Meldung
  ns.lastDeath[k] = now
  if classFile then ns.classOf[k] = classFile end
  ns.Fire({
    type = "DEATH", name = name, level = level,
    class = classFile or ns.classOf[k],
    zone = (zone ~= "" and zone) or nil,
    killer = (killer ~= "" and killer) or nil,
  })
end

---------------------------------------------------------------------------
-- Kommunikation mit anderen Addon-Nutzern in der Gilde
---------------------------------------------------------------------------
-- In WoW Forever können Addon-Nachrichten zeitweise gesperrt sein (z. B. im Kampf).
-- Dann landen sie in einer Warteschlange und werden später nachgeschickt.
local queue = {}

local function TrySend(msg)
  if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
    return false
  end
  local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "GUILD")
  if not ok then return false end
  return res == nil or res == true or res == 0
end

local function Send(msg)
  if not IsInGuild() then return end
  if #queue > 0 or not TrySend(msg) then
    if #queue < 20 then queue[#queue + 1] = msg end
  end
end

local function FlushQueue()
  while #queue > 0 and IsInGuild() do
    if not TrySend(queue[1]) then return end
    table.remove(queue, 1)
  end
end

local function OnAddonMessage(prefix, msg, _, sender)
  if prefix ~= PREFIX then return end
  sender = Normalize(sender)
  if not sender then return end

  local cmd, a, b, c, d, sid = strsplit(";", msg)
  if cmd == "HELLO" or cmd == "HI" then sid = b end
  if cmd == "LVL" then sid = d end

  -- Eigene Nachricht? (kommt bei WoW immer auch an einen selbst zurück)
  if sid == ns.session or Key(sender) == Key(ns.me) then return end
  local short = sender:match("^[^-]+")
  if short == UnitName("player") and not sid then return end   -- ältere Version ohne Kennung

  if cmd == "LVL" then
    ReportLevel(sender, tonumber(a), (b ~= "" and b) or nil, c, "addon")
  elseif cmd == "DIE" then
    ReportDeath(sender, tonumber(a), (b ~= "" and b) or nil, c, d)
  elseif cmd == "HELLO" then
    ns.addonUsers[Key(sender)] = { name = sender, v = a }
    Send(("HI;%s;%s"):format(ns.VERSION, ns.session))
  elseif cmd == "HI" then
    ns.addonUsers[Key(sender)] = { name = sender, v = a }
  end
end

---------------------------------------------------------------------------
-- Eigener Charakter
---------------------------------------------------------------------------
local ENV = {
  Falling = "Sturzschaden", Drowning = "Ertrinken", Fatigue = "Erschöpfung",
  Fire = "Feuer", Lava = "Lava", Slime = "Schleim",
}
local DAMAGE = {
  SWING_DAMAGE = true, RANGE_DAMAGE = true, SPELL_DAMAGE = true,
  SPELL_PERIODIC_DAMAGE = true, ENVIRONMENTAL_DAMAGE = true,
}

-- Kampflog gibt es in Classic Era, in WoW Forever evtl. nicht.
-- Ohne Kampflog wird der Tod trotzdem gemeldet, nur ohne Gegner/Ursache.
ns.hasCombatLog = type(CombatLogGetCurrentEventInfo) == "function"

local function OnCombatLog()
  local _, sub, _, _, sourceName, _, _, destGUID, _, _, _, p12 = CombatLogGetCurrentEventInfo()
  if destGUID ~= ns.myGUID or not DAMAGE[sub] then return end
  local who
  if sub == "ENVIRONMENTAL_DAMAGE" then who = ENV[p12] or p12 else who = sourceName end
  if who then ns.lastHit = { name = who, t = GetTime() } end
end

local function OnPlayerLevelUp(level)
  local class, zone = MyClass(), Clean(Zone())
  ReportLevel(ns.me, level, class, zone, "self")
  Send(("LVL;%d;%s;%s;%s"):format(level, class or "", zone, ns.session))
end

local function OnPlayerDead()
  local killer = ""
  if ns.lastHit and GetTime() - ns.lastHit.t < 15 then killer = Clean(ns.lastHit.name) end
  local level, class, zone = UnitLevel("player"), MyClass(), Clean(Zone())
  ReportDeath(ns.me, level, class, zone, killer)
  Send(("DIE;%d;%s;%s;%s;%s"):format(level, class or "", zone, killer, ns.session))
end

---------------------------------------------------------------------------
-- Gilden-Roster: erkennt Level-Ups auch bei Mitgliedern ohne Addon
-- sowie Beitritte und Austritte
---------------------------------------------------------------------------
local function RequestRoster()
  if not IsInGuild() then return end
  if C_GuildInfo and C_GuildInfo.GuildRoster then
    C_GuildInfo.GuildRoster()
  elseif GuildRoster then
    GuildRoster()
  end
end

local function ScanRoster()
  if not IsInGuild() then return end
  local guildName = GetGuildInfo("player")
  if not guildName then return end

  local db = ns.db
  if db.guild ~= guildName then          -- neue Gilde → frischer Stand
    db.guild, db.roster, ns.rosterReady = guildName, {}, false
  end

  local total = GetNumGuildMembers()
  if not total or total == 0 then return end

  local roster  = db.roster
  local initial = not ns.rosterReady     -- erster Scan der Sitzung: still abgleichen
  local seen, joins = {}, {}

  for i = 1, total do
    local name, _, _, level, _, zone, _, _, _, _, classFile = GetGuildRosterInfo(i)
    name = Normalize(name)
    if name then
      seen[name] = true
      if classFile then ns.classOf[Key(name)] = classFile end
      local old = roster[name]
      if not initial then
        if old == nil then
          joins[#joins + 1] = { type = "JOIN", name = name, level = level, class = classFile }
        elseif level and level > old then
          ReportLevel(name, level, classFile, zone, "roster")
        end
      end
      if level then
        roster[name] = level
        local k = Key(name)
        if (ns.reported[k] or 0) < level then ns.reported[k] = level end
      end
    end
  end

  local quiet = not db.settings.showJoinLeave
  if initial then
    for name in pairs(roster) do
      if not seen[name] then roster[name] = nil end
    end
  else
    -- Schutz vor unvollständig geladenen Listen: große Sprünge nicht melden
    if #joins <= 3 then
      for _, ev in ipairs(joins) do ns.Fire(ev, quiet) end
    end
    local missing = {}
    for name in pairs(roster) do
      if not seen[name] then missing[#missing + 1] = name end
    end
    if #missing <= 3 then
      for _, name in ipairs(missing) do
        roster[name] = nil
        ns.Fire({ type = "LEAVE", name = name, class = ns.classOf[Key(name)] }, quiet)
      end
    end
  end
  ns.rosterReady = true
end

---------------------------------------------------------------------------
-- Event-Verteilung
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    if ... ~= ADDON then return end
    GildenPulsDB = GildenPulsDB or {}
    CopyDefaults(defaults, GildenPulsDB)
    ns.db = GildenPulsDB
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    self:UnregisterEvent("ADDON_LOADED")
    for _, e in ipairs({
      "PLAYER_LOGIN", "PLAYER_LEVEL_UP", "PLAYER_DEAD", "CHAT_MSG_ADDON",
      "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE",
    }) do self:RegisterEvent(e) end
    if ns.hasCombatLog then
      -- pcall: falls das Event in einem Client gesperrt ist, läuft der Rest weiter
      if not pcall(self.RegisterEvent, self, "COMBAT_LOG_EVENT_UNFILTERED") then
        ns.hasCombatLog = false
      end
    end

  elseif event == "PLAYER_LOGIN" then
    ns.myRealm = GetNormalizedRealmName()
    ns.me      = Normalize(UnitName("player"))
    ns.myGUID  = UnitGUID("player")
    ns.reported[Key(ns.me)] = UnitLevel("player")
    if ns.InitUI then ns.InitUI() end
    RequestRoster()
    C_Timer.NewTicker(ROSTER_POLL, RequestRoster)
    C_Timer.NewTicker(2, FlushQueue)
    C_Timer.After(5, function() Send(("HELLO;%s;%s"):format(ns.VERSION, ns.session)) end)
    Print(("v%s geladen – |cffffffff/gp|r für Befehle."):format(ns.VERSION))

  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
    if ns.hasCombatLog then pcall(OnCombatLog) end
  elseif event == "PLAYER_LEVEL_UP" then
    OnPlayerLevelUp(...)
  elseif event == "PLAYER_DEAD" then
    OnPlayerDead()
  elseif event == "CHAT_MSG_ADDON" then
    OnAddonMessage(...)
  elseif event == "GUILD_ROSTER_UPDATE" then
    ScanRoster()
  elseif event == "PLAYER_GUILD_UPDATE" then
    RequestRoster()
  end
end)

---------------------------------------------------------------------------
-- Slash-Befehle
---------------------------------------------------------------------------
local TESTS = {
  level  = { type = "LEVEL", name = "Testheld", level = 23, class = "WARRIOR", zone = "Westfall" },
  meilenstein = { type = "LEVEL", name = "Testmagierin", level = 40, class = "MAGE", zone = "Arathihochland" },
  max    = { type = "LEVEL", name = "Testjäger", level = 60, class = "HUNTER", zone = "Winterquell" },
  tod    = { type = "DEATH", name = "Testpriester", level = 14, class = "PRIEST", zone = "Wald von Elwynn", killer = "Hogger" },
  join   = { type = "JOIN", name = "Neuling", level = 1, class = "PALADIN" },
  leave  = { type = "LEAVE", name = "Abtrünniger", class = "ROGUE" },
}
local TEST_ORDER = { "level", "meilenstein", "max", "tod", "join", "leave" }

local function ShowTest(key)
  local ev = {}
  for k, v in pairs(TESTS[key]) do ev[k] = v end
  ev.t = time()
  ns.ShowToast(ev)   -- Tests werden NICHT gespeichert und NICHT an die Gilde gesendet
end

local HELP = {
  "|cffffffff/gp test|r [level|meilenstein|max|tod|join|leave] – Beispiel-Pop-ups zeigen",
  "|cffffffff/gp unlock|r / |cffffffff/gp lock|r – Position verschieben / fixieren",
  "|cffffffff/gp scale 1.2|r – Größe ändern",
  "|cffffffff/gp dauer 7|r – Anzeigedauer in Sekunden",
  "|cffffffff/gp sound|r – Sound an/aus",
  "|cffffffff/gp joinleave|r – Beitritte/Austritte an/aus",
  "|cffffffff/gp verlauf 10|r – letzte Events im Chat",
  "|cffffffff/gp wer|r – wer in der Gilde das Addon nutzt",
  "|cffffffff/gp reset|r – Verlauf löschen",
}

SLASH_GILDENPULS1 = "/gp"
SLASH_GILDENPULS2 = "/gildenpuls"
SlashCmdList.GILDENPULS = function(input)
  local cmd, arg = (input or ""):lower():match("^(%S*)%s*(.-)$")
  local s = ns.db.settings

  if cmd == "test" then
    if TESTS[arg] then
      ShowTest(arg)
    else
      for i, key in ipairs(TEST_ORDER) do
        C_Timer.After((i - 1) * 1.5, function() ShowTest(key) end)
      end
    end
  elseif cmd == "unlock" then
    ns.SetLocked(false); Print("Entsperrt – Rahmen mit der Maus verschieben, dann |cffffffff/gp lock|r.")
  elseif cmd == "lock" then
    ns.SetLocked(true); Print("Position gespeichert.")
  elseif cmd == "scale" then
    local v = tonumber(arg)
    if v and v >= 0.5 and v <= 3 then s.scale = v; ns.ApplyScale(); Print("Größe: " .. v)
    else Print("Wert zwischen 0.5 und 3 angeben, z. B. /gp scale 1.2") end
  elseif cmd == "dauer" or cmd == "duration" then
    local v = tonumber(arg)
    if v and v >= 2 and v <= 30 then s.duration = v; Print("Anzeigedauer: " .. v .. " s")
    else Print("Wert zwischen 2 und 30 Sekunden angeben.") end
  elseif cmd == "sound" then
    s.sound = not s.sound; Print("Sound " .. (s.sound and "an" or "aus"))
  elseif cmd == "joinleave" then
    s.showJoinLeave = not s.showJoinLeave
    Print("Beitritte/Austritte " .. (s.showJoinLeave and "werden angezeigt" or "ausgeblendet"))
  elseif cmd == "verlauf" or cmd == "history" then
    local list, n = ns.db.events, tonumber(arg) or 10
    if #list == 0 then Print("Noch keine Events gespeichert.") return end
    for i = math.max(1, #list - n + 1), #list do
      local e = list[i]
      print(("|cff999999%s|r %s"):format(date("%d.%m. %H:%M", e.t), ns.Describe(e)))
    end
  elseif cmd == "wer" or cmd == "who" then
    local names = {}
    for _, u in pairs(ns.addonUsers) do names[#names + 1] = ns.Short(u.name) .. " (" .. tostring(u.v) .. ")" end
    table.sort(names)
    Print(#names == 0 and "Noch niemand sonst online mit GildenPuls."
      or ("%d online mit GildenPuls: %s"):format(#names, table.concat(names, ", ")))
  elseif cmd == "reset" then
    wipe(ns.db.events); Print("Verlauf gelöscht.")
  else
    Print("Befehle:")
    for _, line in ipairs(HELP) do print("  " .. line) end
  end
end
