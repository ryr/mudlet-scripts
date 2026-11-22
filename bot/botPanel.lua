-- Создайте скрипт:
-- name: BotPanel
-- body:
-- =====================================================================
-- BotPanel — плашка состояния бота (Geyser)
-- =====================================================================
-- Показывает режим, зону, шаг/всего, VNUM комнаты, выходы (VNUM соседей или «-»), бой и паузу.
-- Обновляется из Bot.panelUpdate(), которую зовёт BotCore (раз в секунду
-- и по событиям). Позиция настраивается в BotPanelConfig.
--
-- Зависимости: BotCore. Плашку mapperLabel (MAP: ON/OFF) не перекрывает:
-- та занимает x = -465..-390, эта встаёт ниже.
-- =====================================================================

Bot = Bot or {}

BotPanelConfig = BotPanelConfig or {
  x = "-625px",
  y = "44px",
  width = "150px",
  height = "72px",
}

botPanel = botPanel or Geyser.Label:new({
  name = "botPanel",
  x = BotPanelConfig.x,
  y = BotPanelConfig.y,
  width = BotPanelConfig.width,
  height = BotPanelConfig.height,
})

local stateColors = {
  idle = "rgb(90, 90, 90)",
  record = "rgb(180, 120, 0)",
  transit = "rgb(0, 120, 180)",
  entry = "rgb(0, 90, 160)",
  walk = "rgb(0, 140, 60)",
  pause = "rgb(150, 60, 0)",
  battle = "rgb(170, 0, 0)",
}

local lastPanelKey = nil

-- выходы из текущей клетки: для каждого направления VNUM соседней комнаты или «-»
local exitDirs = {
  { "n", "N" }, { "e", "E" }, { "u", "U" },
  { "s", "S" }, { "w", "W" }, { "d", "D" },
}

function Bot.panel_exits()
  local out = {}
  for _, d in ipairs(exitDirs) do
    local v = Bot.exit_vnum and Bot.exit_vnum(d[1]) or nil
    local n = tonumber(v)
    -- VNUM всегда 6 цифр; нет выхода — прочерк в 6-символьном поле (та же ширина)
    local cell = n and string.format("%06d", n) or "--------"
    out[#out + 1] = d[2] .. ":" .. cell
  end
  return out
end

function Bot.panel_key()
  local ex = Bot.panel_exits()
  return table.concat({
    tostring(Bot.state), tostring(Bot.zone),
    tostring(Bot.zone_rules and Bot.zone_rules().mode or "all"), tostring(Bot.i),
    tostring(#((Bot.route or {}).steps or {})),
    tostring(Bot.room.vnum), tostring(Bot.battle), tostring(Bot.paused),
    tostring(Bot.waiting and Bot.waiting()), table.concat(ex, ","),
  }, "|")
end

function Bot.panel_color()
  if Bot.paused then return stateColors.pause end
  if Bot.battle then return stateColors.battle end
  return stateColors[Bot.state or "idle"] or stateColors.idle
end

function Bot.panel_lines()
  local mode = Bot.state or "idle"
  if Bot.paused then mode = "ПАУЗА" end
  if Bot.battle then mode = "БОЙ" end

  local lines = {}
  local wait = Bot.waiting and Bot.waiting()
  lines[#lines + 1] = string.format("<b>%s</b>", tostring(mode):upper()) ..
    (wait and " ждём" or "")
  if Bot.zone then
    local mark = (Bot.zone_rules and Bot.zone_rules().mode == "list") and " [L]" or ""
    lines[#lines + 1] = string.format("%s%s %d/%d", tostring(Bot.zone), mark,
      tonumber(Bot.i) or 0, #((Bot.route or {}).steps or {}))
  else
    lines[#lines + 1] = string.format("VNUM: %s", tostring(Bot.room.vnum or "-"))
  end
  if Bot.zone then
    lines[#lines + 1] = string.format("VNUM: %s", tostring(Bot.room.vnum or "-"))
  end
  -- выходы: VNUM соседней комнаты по каждому направлению, «-» если выхода нет
  local ex = Bot.panel_exits()
  lines[#lines + 1] = table.concat({ ex[1], ex[2], ex[3] }, " ")
  lines[#lines + 1] = table.concat({ ex[4], ex[5], ex[6] }, " ")
  if Bot.paused then lines[#lines + 1] = ".бот пауза 0" end
  return lines
end

function Bot.panelUpdate(force)
  if not botPanel then return end
  local key = Bot.panel_key()
  if not force and key == lastPanelKey then return end
  lastPanelKey = key

  local body = table.concat(Bot.panel_lines(), "<br>")
  botPanel:echo(body, "white", "c")
  botPanel:setStyleSheet(string.format([[
    background-color: %s;
    border: 2px solid rgba(0, 0, 0, 120);
    border-radius: 5px;
  ]], Bot.panel_color()))
end

tempTimer(1, function() Bot.panelUpdate(true) end)
