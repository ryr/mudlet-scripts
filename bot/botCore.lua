-- Создайте скрипт:
-- name: BotCore
-- body:
-- =====================================================================
-- BotCore — автопрохождение зон «Сферы Миров» на MudMapper + generic_mapper
-- =====================================================================
-- Порт логики jmc-бота (scripts/BotCore.js) на Mudlet:
--   1) бег к клетке входа через MudMapper.goto_vnum (то же, что «гмуть», но по VNUM),
--      затем «гг !обл созда <направление> <сложность>» и проход;
--   2) пошаговый проход по записанным клеткам зоны: одна команда — один ack
--      по msdp.ROOM.VNUM, на каждой клетке бьём мобов по номеру (botkill);
--   3) действия в комнатах, записанные командой ".триг <команда>".
--
-- Установка:
--   * скрипты Mudlet (в таком порядке в дереве профиля):
--       BotCore (этот файл) → BotWalk → BotCombat → BotPanel
--   * алиасы: aliases/bot.lua (".бот ..."), aliases/botTrig.lua (".триг ..."),
--     aliases/botWait.lua (".пауза ..."), aliases/botkill.lua ("botkill")
--   * требуется mapper.lua (MudMapper + generic_mapper) и antibot.lua
--
-- Файлы данных (создаются/читаются автоматически):
--   <профиль>/bot/zones/<зона>.lua  — записанный маршрут + правила зоны
--       mode = "all" | "list", kill/aggro (имена), noattack ([vnume] = {имя})
--   <профиль>/bot/attack.lua        — способ атаки (необязательно)
--   <профиль>/bot/noattack.lua      — «не бить» для комнат вне записанных зон
--   <профиль>/bot/stats.csv         — статистика прогонов
--
-- Модель маршрута:
--   Bot.zones[зона] = {
--     entry = { vnum = "100051", dir = "юг", maxdiff = 2,        -- вход в зону
--               num = 472, title = "Королевский фрегат" },
--     steps = {
--       { dir = "юг", room = 506022 },     -- ход; room = ожидаемый VNUM после хода
--       { cmd = "вл $tempMoney;снять 500000", room = 506023 }, -- действие в комнате
--     },
--   }
-- =====================================================================

Bot = Bot or {}

-- ===================== настройки =====================

-- Значения по умолчанию. В живом профиле Bot.config уже существует (скрипт
-- перезапускается без очистки Lua), поэтому недостающие ключи доливаем: иначе
-- новые настройки (zoneProbe, entryWait, …) остались бы nil.
local config_defaults = {
  waitAfterMove   = 3.0,    -- сек: сколько ждём смену VNUM после хода
  waitAfterAct    = 1.0,    -- сек: пауза после действия из ".триг"
  actRoomLimit    = 5,      -- попыток дождаться комнаты действия (cmd) до остановки
  triggerTimeout  = 10,     -- сек: сколько ждём строку-синхронизацию (шаг trigger)
  recoverLimit    = 3,      -- recovery (pathfinding/двери) на один шаг
  dynamicResyncLimit = 3,   -- сверок «выход ведёт в другой VNUM из маршрута» до стопа
  moveFailLimit   = 5,      -- неудачных ходов подряд до остановки бота
  combatTimeout   = 180,    -- сек: бой дольше — предупреждение
  combatGrace     = 2,      -- сек: ждём боевой промпт после команды атаки
  lookAfterBattle = true,   -- "look краткий" после окончания боя
  lookWait        = 2,      -- сек: ждём блок комнаты в ответ на look, потом идём без него
  lookEveryCell   = false,  -- принудительный look на каждой клетке
  -- Бой в комнате идёт не только у нас: в группе партнёры добивают мобов, а наш
  -- таргет уже пропал. Пока в комнате кто-то сражается — из комнаты не уходим.
  groupFightWait    = true, -- ждать, пока в комнате идёт бой
  groupFightAny     = true, -- true: любой бой в комнате; false: только assist_who
  groupFightRequireGroup = true, -- ждать только если в группе/в комнате свой игрок
  groupFightProbe   = 10,   -- сек: перепроверка комнаты look'ом, пока ждём
  groupFightIdle    = 5,    -- сек: тишина в боевых строках перед перепроверкой
  groupFightTimeout = 300,  -- сек: максимум ожидания боя (0 = без ограничения)
  -- В группе выключать не нужно: botkill считает номера от group_count,
  -- поэтому согрупники под удар не попадают. Включайте, если драться
  -- в комнате с игроками вообще не хотите.
  skipFightWithPlayer = false, -- не драться, если в комнате игрок
  mobSource       = "color", -- "color" (по умолчанию) | "text" (отладка/сервер без цветов)
  -- Действия из маршрута (".триг …") выполняем как ввод из командной строки,
  -- чтобы работали алиасы профиля ("оов шкаф"): send() их не раскрывает.
  expandActions   = true,
  -- Двери открывает профильный триггер (он смотрит на глобальную переменную dir),
  -- бот только повторяет шаг. Лимит повторов одного хода и пауза перед повтором.
  doorRetryLimit  = 5,      -- повторов хода в закрытую дверь до остановки
  doorRetryDelay  = 0.4,    -- сек: даём триггеру отправить «отпер»/«откры» до повтора
  holdRetryDelay = 1.0,   -- сек: повтор хода, пока персонаж замер (без счёта попыток)
  zoneProbe       = "обл и",  -- запрос при записи: узнать смежные зоны ("" = не спрашивать)
  entryWait       = 5,      -- сек: ждём «Создан экземпляр зоны» после «гг !обл созда»
  entryMinDiff    = 0,      -- минимальная сложность при отказе сервера (0 = обычная, без +N)
  instanceWait    = 5,      -- сек: ждём ответ на «обл» (список экземпляров зон)
  repopUseInstances = true, -- круг: проверять «обл» (false = идти по списку без проверки)
  repopTick       = 60,     -- сек: как часто круг перепроверяет «обл»
  circleDeleteWait = 2,     -- сек: пауза перед повторным «обл» после «обл удалить»
  circleDeleteCooldown = 600, -- сек: не трогать «удалите вручную», если зона не освободилась
  restBelow       = 0,      -- MOVEMENT ниже — отдыхаем (0 = не отдыхать)
  restAbove       = 0.85,   -- доля от MOVEMENT_MAX, до которой отдыхаем
  restTimeout     = 300,    -- сек: максимум отдыха
  standAfterRest  = "встать", -- что шлём после отдыха ("" = ничего)
  lowHpPercent    = 0,      -- HP ниже доли от максимума — стоп (0 = выкл)
  debug           = false,  -- подробный вывод
  dry             = false,  -- не отправлять команды, только печатать
}

Bot.config = Bot.config or {}
for key, value in pairs(config_defaults) do
  if Bot.config[key] == nil then Bot.config[key] = value end
end

-- ===================== состояние =====================

-- "idle" | "record" | "transit" | "entry" | "walk" | "wait" | "done"
Bot.state = Bot.state or "idle"
Bot.zone = Bot.zone or nil            -- имя текущей зоны
Bot.route = Bot.route or nil          -- { entry = {...}, steps = {...} }
Bot.i = Bot.i or 0                    -- индекс текущего шага (1-based, шаг ещё не выполнен)
Bot.expect = Bot.expect or nil        -- ожидаемый VNUM после отправленного хода
Bot.deadline = Bot.deadline or 0      -- getEpoch()-дедлайн ожидания ack
Bot.waitUntil = Bot.waitUntil or 0    -- getEpoch()-дедлайн паузы Bot.wait()
Bot.paused = Bot.paused or false
-- getEpoch()-дедлайн: ждём блок комнаты в ответ на look (см. Bot.send)
Bot.lookPending = Bot.lookPending or nil
-- в комнате идёт бой (наш или группы): маршрут стоит, см. Bot.room_fight_wait
Bot.roomFight = Bot.roomFight or nil
Bot.roomFightUntil = Bot.roomFightUntil or nil
Bot.roomFightAt = Bot.roomFightAt or 0
Bot.roomFightProbeAt = Bot.roomFightProbeAt or 0
Bot.roomFightWarned = Bot.roomFightWarned or nil
Bot.fightNoiseAt = Bot.fightNoiseAt or 0

Bot.hp = Bot.hp or 0
Bot.hpMax = Bot.hpMax or 0
Bot.mp = Bot.mp or 0
Bot.mpMax = Bot.mpMax or 0
Bot.mv = Bot.mv or 0
Bot.mvMax = Bot.mvMax or 0
Bot.exp = Bot.exp or 0
Bot.money = Bot.money or 0
Bot.exits = Bot.exits or ""
Bot.battle = Bot.battle or false
Bot.target = Bot.target or ""

Bot.room = Bot.room or { vnum = "", name = "", area = "", exits = {} }
-- блок комнаты: заголовок -> [ Exits: ... ] -> содержимое -> промпт
Bot.block = Bot.block or { open = false, title = "", lines = {}, color_lines = {},
  item_lines = {}, items = 0, has_color = false, last_line = nil }
Bot.segment = Bot.segment or { lines = {} }  -- строки между промптами (вне блока)
Bot.mobs = Bot.mobs or {}                    -- мобы последнего разобранного блока
Bot.mobSourceUsed = Bot.mobSourceUsed or nil -- "color" | "text": чем реально собрано
Bot.colorHits = Bot.colorHits or { mob = 0, item = 0, player = 0, group = 0 }
Bot.playerInRoom = Bot.playerInRoom or false
Bot.groupInRoom = Bot.groupInRoom or {}

Bot.rest = Bot.rest or { active = false, started = 0 }
Bot.recover = Bot.recover or { step = 0, count = 0, fails = 0 }

Bot.timers = Bot.timers or {}
Bot.triggers = Bot.triggers or {}
Bot.handlers = Bot.handlers or {}

Bot.doorAttempts = Bot.doorAttempts or 0
Bot.lastSent = Bot.lastSent or ""
Bot.lastFail = Bot.lastFail or ""

-- ===================== утилиты =====================

Bot.tag = "<112,229,0>(<73,149,0>Bot<112,229,0>): <255,255,255>"
Bot.warnTag = "<255,140,0>(<200,80,0>Bot<255,140,0>): <255,255,255>"

function Bot.echo(msg)
  decho(Bot.tag)
  cecho(tostring(msg))
  echo("\n")
end

function Bot.warn(msg)
  decho(Bot.warnTag)
  cecho(tostring(msg))
  echo("\n")
end

function Bot.dbg(msg)
  if not Bot.config.debug then return end
  decho("<112,229,0>(<73,149,0>Bot<112,229,0>): <140,140,140>")
  echo(tostring(msg) .. "\n")
end

function Bot.trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Bot.split(s)
  local out = {}
  for word in tostring(s or ""):gmatch("%S+") do out[#out + 1] = word end
  return out
end

function Bot.now()
  return getEpoch()
end

-- любое написание направления -> полное русское имя (единый вид маршрута)
Bot.dir_names = {
  n = "север", north = "север", ["с"] = "север", ["север"] = "север",
  s = "юг", south = "юг", ["ю"] = "юг", ["юг"] = "юг",
  e = "восток", east = "восток", ["в"] = "восток", ["восток"] = "восток",
  w = "запад", west = "запад", ["з"] = "запад", ["запад"] = "запад",
  u = "вверх", up = "вверх", ["вв"] = "вверх", ["вверх"] = "вверх",
  d = "вниз", down = "вниз", ["вн"] = "вниз", ["вниз"] = "вниз",
}

Bot.dir_reverse = {
  ["север"] = "юг", ["юг"] = "север",
  ["восток"] = "запад", ["запад"] = "восток",
  ["вверх"] = "вниз", ["вниз"] = "вверх",
}

function Bot.dir_of(cmd)
  return Bot.dir_names[(tostring(cmd or ""):lower())]
end

-- короткое направление Mudlet/msdp: "север"/"с"/"north" -> "n"
Bot.dir_short = {
  ["n"] = "n", ["north"] = "n", ["север"] = "n", ["с"] = "n",
  ["s"] = "s", ["south"] = "s", ["юг"] = "s", ["ю"] = "s",
  ["e"] = "e", ["east"] = "e", ["восток"] = "e", ["в"] = "e",
  ["w"] = "w", ["west"] = "w", ["запад"] = "w", ["з"] = "w",
  ["u"] = "u", ["up"] = "u", ["вверх"] = "u", ["вв"] = "u",
  ["d"] = "d", ["down"] = "d", ["вниз"] = "d", ["вн"] = "d",
}

function Bot.dir_short_of(cmd)
  return Bot.dir_short[(tostring(cmd or ""):lower())]
end

-- Значение глобальной переменной dir для профильных триггеров: они открывают
-- двери по этой переменной, и в профиле её ставят стрелковые биндинги полными
-- именами («север», «запад»), а для вверх/вниз — коротко («вв»/«вн»).
Bot.dir_key_values = { ["вверх"] = "вв", ["вниз"] = "вн" }

function Bot.dir_for_profile(dir)
  dir = Bot.dir_of(dir) or dir
  if type(dir) ~= "string" or dir == "" then return nil end
  return Bot.dir_key_values[dir] or dir
end

-- выходы текущей комнаты по msdp.ROOM.EXITS (не путать с Bot.exits — текстом из промпта)
function Bot.exit_table()
  local ex = (msdp and msdp.ROOM and msdp.ROOM.EXITS) or Bot.room.exits
  if type(ex) ~= "table" then return nil end
  if next(ex) == nil then return nil end
  return ex
end

function Bot.exit_vnum(short)
  local ex = Bot.exit_table()
  if not ex or not short then return nil end
  for dir, vnum in pairs(ex) do
    if Bot.dir_short_of(dir) == short then return tostring(vnum) end
  end
  return nil
end

function Bot.running()
  return Bot.state == "walk" or Bot.state == "transit" or
    Bot.state == "entry" or Bot.state == "wait"
end

function Bot.in_battle()
  return Bot.battle == true
end

function Bot.waiting()
  return Bot.now() < Bot.waitUntil
end

-- ===================== отправка =====================

-- Единая точка отправки: анти-бот, dry-run, пауза бота.
function Bot.send(cmd)
  cmd = Bot.trim(cmd)
  if cmd == "" then return false end
  if Bot.paused then
    Bot.dbg("[send] пауза, команда отброшена: " .. cmd)
    return false
  end
  if Bot.config.dry then
    Bot.echo("[dry] " .. cmd)
    return true
  end
  if Bot.blocked_by_antibot() then
    Bot.paused = true
    Bot.warn("<orange>Проверка на бота — бот приостановлен. Снять: .бот пауза 0")
    return false
  end
  Bot.lastSent = cmd
  -- после хода или look сервер пришлёт новый блок комнаты
  local dir = Bot.dir_of(cmd)
  if dir or cmd:lower():match("^look") or cmd:lower():match("^осмотр") then
    Bot.expect_block()
    if dir then
      -- ход отменяет ожидание look: блок придёт от самого хода
      Bot.lookPending = nil
    else
      -- look: пока не пришёл блок комнаты, маршрут не двигаем (Bot.tick/W.pulse)
      Bot.lookPending = Bot.now() + (tonumber(Bot.config.lookWait) or 2)
    end
  end
  -- Профильные триггеры открывают двери по глобальной переменной dir; её ставят
  -- стрелковые биндинги профиля. Бот шлёт команды мимо них, поэтому выставляем
  -- сами: иначе триггер откроет дверь «восток» там, где бот идёт на север.
  if dir then _G.dir = Bot.dir_for_profile(dir) end
  send(cmd)
  return true
end

function Bot.blocked_by_antibot()
  return type(antiBotLastSent) == "number" and antiBotLastSent ~= 0
end

-- Действие из маршрута («.триг …»): выполняем как ввод из командной строки,
-- чтобы раскрывались алиасы профиля («оов шкаф» → отпер/откр/взя). send()
-- алиасы не раскрывает — команда уходила бы на сервер текстом.
function Bot.run_action(cmd)
  cmd = Bot.trim(cmd)
  if cmd == "" then return false end
  -- ходы и выключенное раскрытие — обычным путём (там своя логика dir/expect)
  if not Bot.config.expandActions or Bot.dir_of(cmd) then return Bot.send(cmd) end
  if Bot.paused or Bot.config.dry then return Bot.send(cmd) end
  if Bot.blocked_by_antibot() then
    Bot.paused = true
    Bot.warn("<orange>Проверка на бота — бот приостановлен. Снять: .бот пауза 0")
    return false
  end
  Bot.lastSent = cmd
  if cmd:lower():match("^look") or cmd:lower():match("^осмотр") then
    Bot.expect_block()
  end
  if type(expandAlias) ~= "function" then return Bot.send(cmd) end
  Bot.dbg("[act] как ввод: " .. cmd)
  local ok, err = pcall(expandAlias, cmd)
  if not ok then
    Bot.warn("<orange>Действие «" .. cmd .. "» не выполнилось: " .. tostring(err))
    return false
  end
  return true
end

-- Ошибка в колбэке не должна пропадать молча (и не должна убивать тик).
Bot.lastError = Bot.lastError or ""

function Bot.safe(label, fn, ...)
  local ok, err = pcall(fn, ...)
  if ok then return true end
  local text = tostring(err or "?")
  Bot.dbg("[safe] ошибка " .. tostring(label) .. ": " .. text)
  if text ~= Bot.lastError then
    Bot.lastError = text
    Bot.warn("<red>Ошибка " .. tostring(label) .. ": " .. text)
  end
  return false
end

-- tempTimer с защитой: падение колбэка не оставляет бота без следующего шага
function Bot.later(sec, label, fn)
  local generation = Bot.gen
  return tempTimer(sec, function()
    if generation ~= Bot.gen then return end
    Bot.safe(label, fn)
  end)
end

-- ===================== мир: MSDP, промпт, комната =====================

function Bot.vnum()
  local v = msdp and msdp.ROOM and msdp.ROOM.VNUM
  if v ~= nil and tostring(v) ~= "" then return tostring(v) end
  if map and map.currentRoom and map.currentRoom > 0 then
    local hash = getRoomHashByID(map.currentRoom)
    if hash and tostring(hash) ~= "" then return tostring(hash) end
  end
  return Bot.room.vnum or ""
end

-- обновление комнаты по MSDP (событие msdp.ROOM)
function Bot.on_msdp_room()
  local r = msdp and msdp.ROOM
  if not r then return end
  Bot.room.vnum = r.VNUM and tostring(r.VNUM) or Bot.room.vnum
  Bot.room.name = r.NAME and tostring(r.NAME) or Bot.room.name
  Bot.room.area = r.AREA and tostring(r.AREA) or Bot.room.area
  Bot.room.exits = type(r.EXITS) == "table" and r.EXITS or Bot.room.exits
  Bot.dbg("[room] vnum=" .. tostring(Bot.room.vnum) .. " name=" .. tostring(Bot.room.name))
  if Bot.walk and Bot.walk.on_room then Bot.walk.on_room(Bot.room.vnum) end
  if Bot.record and Bot.record.on_room then Bot.record.on_room(Bot.room.vnum) end
  if Bot.panelUpdate then Bot.panelUpdate() end
end

-- ===================== бой в комнате (наш или группы) =====================
-- Профиль по строке «… стоит здесь, сражается с …!» делает автопомощь, а после
-- каждой смерти моба шлёт «встат/пом». Бот по тем же строкам понимает, что бой
-- в комнате ещё идёт (наш таргет мог пропасть, а партнёры дерутся) — уходить
-- нельзя, иначе бот убежит один и разорвёт группу.
Bot.fight_line_markers = { "сражается", " fight!" }

function Bot.line_in_fight(line)
  local s = Bot.fold(line or "")
  if s == "" then return false end
  for _, marker in ipairs(Bot.fight_line_markers) do
    if s:find(Bot.fold(marker), 1, true) then return true end
  end
  return false
end

-- считать ли строку признаком боя: по умолчанию любой бой в комнате,
-- groupFightAny = false — только свои из assist_who
function Bot.fight_line_relevant(line)
  if not Bot.line_in_fight(line) then return false end
  if Bot.config.groupFightAny == false then return Bot.is_protected(line) end
  return true
end

-- бой в комнате по последнему блоку: в цветном режиме игроки/мобы лежат в
-- color_lines, в текстовом — в lines
function Bot.block_in_fight()
  for _, line in ipairs(Bot.block.lines or {}) do
    if not Bot.is_service_line(line) and Bot.fight_line_relevant(line) then
      return true
    end
  end
  for _, line in ipairs(Bot.block.color_lines or {}) do
    if not Bot.is_service_line(line) and Bot.fight_line_relevant(line) then
      return true
    end
  end
  return false
end

-- состояние «в комнате идёт бой»: ставится блоком/событием, снимается ответом
-- «пом» без цели, свежим блоком без боя или таймаутом
function Bot.set_room_fight(on)
  if on then
    if not Bot.roomFight then Bot.dbg("[room] в комнате идёт бой — маршрут ждёт") end
    Bot.roomFight = true
    Bot.roomFightAt = Bot.now()
    Bot.roomFightProbeAt = 0
    Bot.roomFightWarned = nil
    local wait = tonumber(Bot.config.groupFightTimeout) or 300
    Bot.roomFightUntil = wait > 0 and (Bot.now() + wait) or 0
    return
  end
  if Bot.roomFight then Bot.dbg("[room] бой в комнате закончился") end
  Bot.roomFight = nil
  Bot.roomFightUntil = nil
  Bot.roomFightAt = 0
  Bot.roomFightProbeAt = 0
  Bot.roomFightWarned = nil
end

-- есть кого ждать: я в группе (group_count в профиле — строка "15") или в
-- комнате стоит свой игрок из assist_who (Bot.playerInRoom считает блок комнаты)
function Bot.in_group()
  local g = tonumber(rawget(_G, "group_count")) or 1
  if g > 1 then return true end
  return Bot.playerInRoom == true
end

-- true, пока маршрут должен стоять из-за боя в комнате
function Bot.room_fight_wait()
  if not Bot.roomFight then return false end
  if not Bot.config.groupFightWait then return false end
  -- соло и в комнате нет своих: ждать некого
  if Bot.config.groupFightRequireGroup ~= false and not Bot.in_group() then
    return false
  end
  if Bot.roomFightUntil and Bot.roomFightUntil > 0 and Bot.now() > Bot.roomFightUntil then
    if not Bot.roomFightWarned then
      Bot.roomFightWarned = true
      Bot.warn("<orange>Бой в комнате идёт дольше " ..
        tostring(Bot.config.groupFightTimeout) .. "с — иду дальше")
    end
    return false
  end
  return true
end

-- пока ждём бой: изредка обновляем комнату look'ом (fallback, если «пом» без
-- цели не приходит — auto_assist выключен или нас вытолкнули из боя)
function Bot.room_fight_probe()
  if not Bot.room_fight_wait() then return end
  if Bot.lookPending then return end
  local idle = tonumber(Bot.config.groupFightIdle) or 5
  if Bot.now() - (Bot.fightNoiseAt or 0) < idle then return end
  local step = tonumber(Bot.config.groupFightProbe) or 10
  if Bot.now() - (Bot.roomFightProbeAt or 0) < step then return end
  Bot.roomFightProbeAt = Bot.now()
  Bot.dbg("[room] бой в комнате: перепроверяю look'ом")
  Bot.send("look краткий")
end

-- «пом» не нашёл, кому помогать: в комнате больше никто не сражается
Bot.no_assist_patterns = {
  "^Кому именно вы хотите помочь",
  "^Вам некому помочь",
}

function Bot.no_assist_line(line)
  local s = Bot.trim(line or "")
  if s == "" then return false end
  for _, pattern in ipairs(Bot.no_assist_patterns) do
    if s:find(pattern) then return true end
  end
  return false
end

function Bot.on_no_assist()
  if Bot.battle then return end          -- мы сами ещё дерёмся
  if not Bot.roomFight then
    Bot.dbg("[room] «пом» без цели, боя в комнате не ждали")
    return
  end
  Bot.set_room_fight(false)
  -- обновляем комнату: ход продолжится по промпту от look (Bot.lookPending)
  if Bot.state == "walk" then Bot.send("look краткий") end
end

-- «X вступил(а) в бой на стороне Y» — в комнате начался бой (свой ловит Bot.battle)
function Bot.fight_start_line(line)
  local s = tostring(line or "")
  if s == "" or s:find("^Вы ") then return false end
  return s:find("вступил", 1, true) ~= nil and
    s:find(" в бой на стороне", 1, true) ~= nil
end

-- конец комнатного блока (промпт): содержимое блока становится «мобами комнаты».
-- Если блок не открывался (промпт без описания комнаты), старые цели сохраняем:
-- так события между блоками («зайчик припрыгал с севера») не подменяют список.
function Bot.commit_packet()
  if not Bot.block.open then
    Bot.dbg("[room] промпт без блока — цели не меняем")
    Bot.segment.lines = {}
    return
  end
  -- комната пришла: ответ на look получен
  Bot.lookPending = nil
  -- бой в комнате считаем по блоку до его очистки, а применяем в конце — после
  -- обновления Bot.playerInRoom (его смотрит Bot.in_group)
  local block_fight = Bot.block_in_fight()
  local text, color = {}, {}
  for _, line in ipairs(Bot.block.lines) do
    if not Bot.is_service_line(line) then text[#text + 1] = line end
  end
  for _, line in ipairs(Bot.block.color_lines or {}) do
    -- продолжения описания («...светится розовым сиянием.») — не отдельные цели
    if not Bot.is_service_line(line) and not Bot.is_continuation_line(line) then
      color[#color + 1] = line
    end
  end

  -- в текстовом режиме отсекаем прозу описания комнаты: строка-существо — это
  -- заглавная буква + законченное предложение и не «Вы …». Строки, распознанные
  -- как предметы по цвету, и заголовок комнаты мобами не считаем.
  local item_lines = {}
  for _, line in ipairs(Bot.block.item_lines or {}) do item_lines[line] = true end
  local title = Bot.block.title
  local filtered = {}
  for _, line in ipairs(text) do
    local skip = (title ~= "" and line == title) or item_lines[line]
    if not skip and Bot.looks_like_mob(line) then
      filtered[#filtered + 1] = line
    end
  end
  text = filtered

  local mode = Bot.config.mobSource or "color"
  local source, mobs
  if mode == "text" then
    source, mobs = "text", text
  else
    -- "color" и старое "auto": моб — только красная строка. Не красный —
    -- не существо (проза, события, предметы), бить не надо.
    source, mobs = "color", color
  end

  Bot.mobs = {}
  -- боевые/эмоциональные строки — не существа (моб ударил, сказал, умер…)
  for _, line in ipairs(mobs) do
    if not Bot.is_action_line(line) then Bot.mobs[#Bot.mobs + 1] = line end
  end
  mobs = Bot.mobs
  Bot.mobSourceUsed = source
  Bot.itemsSeen = Bot.block.items or 0
  Bot.block.items = 0
  Bot.block.item_lines = {}
  Bot.block.has_color = false
  Bot.block.lines = {}
  Bot.block.color_lines = {}
  Bot.block.open = false
  Bot.block.title = ""
  Bot.block.last_line = nil
  Bot.segment.lines = {}
  -- игроки/согрупники того же цвета, что мобы: отмечаем по списку «не бить»
  if Bot.playerInRoom ~= true then
    for _, line in ipairs(mobs) do
      if Bot.is_protected(line) then
        Bot.playerInRoom = true
        break
      end
    end
  end
  Bot.dbg("[room] блок закрыт: источник " .. source .. ", строк " .. tostring(#mobs) ..
    (Bot.playerInRoom and ", в комнате игрок" or ""))
  -- бой в комнате: наш таргет мог пропасть, а партнёры ещё дерутся
  Bot.set_room_fight(block_fight)
end

-- MSDP-переменные (HEALTH/MANA/MOVEMENT/...)
function Bot.on_msdp_var(name, value)
  local n = tonumber(value)
  if name == "HEALTH" then Bot.hp = n or Bot.hp
  elseif name == "HEALTH_MAX" then Bot.hpMax = n or Bot.hpMax
  elseif name == "MANA" then Bot.mp = n or Bot.mp
  elseif name == "MANA_MAX" then Bot.mpMax = n or Bot.mpMax
  elseif name == "MOVEMENT" then Bot.mv = n or Bot.mv
  elseif name == "MOVEMENT_MAX" then Bot.mvMax = n or Bot.mvMax
  elseif name == "EXPERIENCE" then Bot.exp = n or Bot.exp
  elseif name == "MONEY" then Bot.money = n or Bot.money
  elseif name == "OPPONENT_NAME" then
    local was = Bot.battle
    Bot.target = Bot.trim(value)
    Bot.battle = Bot.target ~= ""
    if not was and Bot.battle and Bot.target ~= "" then
      Bot.safe("агрессор", Bot.learn_aggro, Bot.target)
    end
    if was and not Bot.battle then Bot.on_battle_end() end
  end
end

function Bot.on_battle_end()
  Bot.dbg("[battle] бой окончен")
  Bot.combat = Bot.combat or {}
  Bot.combat.target = nil
  Bot.combat.since = 0
  -- Обновляем комнату после боя: Bot.send("look краткий") выставит Bot.lookPending,
  -- и маршрут не двинется, пока не придёт блок комнаты (или не истечёт lookWait).
  if Bot.config.lookAfterBattle and Bot.running() then
    Bot.send("look краткий")
  end
end

-- разбор строки промпта: "11533H 20747M 2298V 91.6636%X 465681C Вых:СВЮЗ> "
-- в бою: "... C [Варвар:100] [зайчик:36] Вых:СВЮЗ>"
function Bot.parse_prompt(line)
  line = tostring(line or "")
  local hp, mp, mv = line:match("^(%d+)H (%d+)M (%d+)V")
  local exits = line:match("Вых:([^>]*)>")
  local head = line:match("^(.-)Вых:") or ""
  local target
  for name in head:gmatch("%[([^:]+):[^%]]*%]") do
    target = Bot.trim(name)
  end
  return {
    hp = tonumber(hp),
    mp = tonumber(mp),
    mv = tonumber(mv),
    exits = exits,
    battle = target ~= nil and target ~= "",
    target = target or "",
  }
end

-- промпт: в этой сборке Mudlet getCurrentLine() внутри prompt-триггера не даёт
-- строку (курсор может быть вне буфера → «ERROR: invalid line number»), поэтому
-- промпт берём из обычного строчного триггера — там строка из matches[2].
function Bot.on_prompt(line)
  line = tostring(line or "")
  if line == "" then return end
  Bot.safe("в промпте", function()
    Bot.apply_prompt(Bot.parse_prompt(line))
  end)
end

function Bot.apply_prompt(p)
  p = p or {}
  local was = Bot.battle
  if p.hp then Bot.hp = p.hp end
  if p.mp then Bot.mp = p.mp end
  if p.mv then Bot.mv = p.mv end
  if p.exits then Bot.exits = Bot.trim(p.exits) end
  Bot.battle = p.battle == true
  Bot.target = Bot.battle and (p.target or "") or ""
  if not was and Bot.battle and Bot.target ~= "" then
    Bot.safe("агрессор", Bot.learn_aggro, Bot.target)
  end

  Bot.commit_packet()
  if was and not Bot.battle then Bot.on_battle_end() end
  if Bot.battle and Bot.combat and Bot.combat.since == 0 then
    Bot.combat.since = Bot.now()
  end
  -- Пока не пришёл блок комнаты в ответ на look (после боя/обновления комнаты),
  -- маршрут стоит: иначе ход уйдёт раньше ответа и ROOM-событие от look собьёт
  -- ожидание (desync/recovery). Дедлайн истёк — продолжаем, как раньше.
  local look_pending = Bot.lookPending ~= nil and Bot.now() < Bot.lookPending
  if not look_pending then
    Bot.lookPending = nil
    if Bot.walk and Bot.walk.pulse then Bot.walk.pulse() end
  end
  if Bot.panelUpdate then Bot.panelUpdate() end
end

-- строки комнаты приходят в цветах сервера. Фактические цвета «Сферы Миров»
-- (проверено на живом клиенте через getFgColor):
--   мобы, другие игроки и согрупники — ВСЕ красные (255,0,0): цветом их не
--   разделить; предметы — жёлтые (255,255,0); название комнаты — светлый циан;
--   выходы — циан; промпт — зелёный; описание комнаты — обычный цвет.
-- Игроков отличаем по имени (assist_who из профиля).
--
-- Цвет берём из getTextFormat() по выделению capture-группы текущего триггера,
-- а не через tempColorTrigger и не по курсору: в этой сборке Mudlet цветовые
-- триггеры срабатывают на весь буфер (десятки раз в секунду), а getCurrentLine()
-- внутри них отдаёт «ERROR: invalid line number» — в мобов попадал мусор.
-- Классифицируем по оттенку (Mudlet отдаёт 0xBBGGRR), чтобы не зависеть от
-- конкретной палитры профиля и «светлых» вариантов.
function Bot.color_kind(r, g, b)
  if type(r) == "table" then
    local t = r
    r, g, b = t[1] or t.r, t[2] or t.g, t[3] or t.b
  elseif g == nil then
    local n = tonumber(r)
    if not n or n <= 0 then return nil end
    r = n % 256
    g = math.floor(n / 256) % 256
    b = math.floor(n / 65536) % 256
  end
  r, g, b = tonumber(r), tonumber(g), tonumber(b)
  if not (r and g and b) or r <= 0 then return nil end
  if r >= 128 and g >= 128 and b * 2 <= r + 96 then return "item" end -- жёлтый
  if r >= 128 and r >= 2 * g and r >= 2 * b then return "mob" end      -- красный
  return nil
end

-- цвет текущей строки как r, g, b.
-- В этой сборке Mudlet getCurrentLine()/getTextFormat() без выделения читают
-- строку под курсором пользователя, а не строку триггера (и возвращают
-- «ERROR: invalid line number», если курсор вне буфера). Поэтому цвет берём по
-- выделению capture-группы триггера: selectCaptureGroup(2) — это вся строка
-- шаблона ^(.+)$; getTextFormat() читает selectionStartChar. Старый
-- selectCurrentLine оставлен fallback'ом для стенда/других вызовов.
function Bot.line_rgb(capture)
  if type(getTextFormat) ~= "function" then return nil end
  local selected = false
  if type(selectCaptureGroup) == "function" then
    local ok, pos = pcall(selectCaptureGroup, capture or 2)
    pos = tonumber(pos)
    selected = ok and pos ~= nil and pos >= 0
  end
  if not selected and type(selectCurrentLine) == "function" then
    selected = pcall(selectCurrentLine)
  end
  if not selected then return nil end
  local ok, fmt = pcall(getTextFormat)
  pcall(deselect)
  if not ok or type(fmt) ~= "table" then return nil end
  local fg = fmt.foreground
  if type(fg) ~= "table" then return nil end
  local r = tonumber(fg[1] or fg.r)
  local g = tonumber(fg[2] or fg.g)
  local b = tonumber(fg[3] or fg.b)
  if not (r and g and b) then return nil end
  return r, g, b
end

-- суффиксы состояний, которые не входят в имя моба (как в BotCore.js)
Bot.mob_suffixes = {
  "(невидим)", "(невидима)", "(невидимо)", "(невидимы)",
  "(спрятался)", "(спряталась)", "(спряталось)", "(спрятались)",
  "(летит)", "(летят)",
  "...огненный щит", "...каменная кожа", "...магический щит",
  "...затуманивание", "...освящение", "...магическая аура",
}

function Bot.strip_mob_markers(line)
  local s = tostring(line or "")
  for _, suffix in ipairs(Bot.mob_suffixes) do
    s = s:gsub(suffix:gsub("%p", "%%%0"), "")
  end
  return Bot.trim(s)
end

function Bot.on_room_line(kind, line)
  -- строку храним как есть (вместе с «(невидим)» и «...огненный щит»): так её
  -- видно в .бот цель. Суффиксы срезаются только для сравнения — в line_head,
  -- is_continuation_line и looks_like_mob (Bot.strip_mob_markers).
  line = line or getCurrentLine()
  line = Bot.trim(line or "")
  if line == "" then return end
  -- Mudlet сам печатает в окно «ERROR: …» / «Lua: …», когда какой-то триггер
  -- профиля зовёт API без строки; такие строки не должны становиться мобами
  if line:find("^ERROR:") or line:find("^Lua:") then
    Bot.dbg("[room] служебная ошибка Mudlet: " .. line)
    return
  end
  if Bot.is_prompt_line(line) then return end

  -- 1) строка выходов — надёжный маркер: строка перед ней и есть заголовок комнаты
  if line:find("^%[%s*Exits") then
    Bot.mark_block_start()
    return
  end

  -- 2) строка «[Зона, на юг: Королевский фрегат, ур. 42-45]» — резерв для входа
  local hint_word, hint_title = line:match("^%[Зона,%s*на%s+(%S+):%s*(.-),%s*ур%.")
  if hint_word then
    Bot.zoneHint = { dir = Bot.dir_form(hint_word), title = Bot.trim(hint_title) }
  end

  -- 3) прочие служебные строки ([Зона, ...], (mapper): ..., ASCII-карта)
  if Bot.is_service_line(line) then return end

  -- 4) заголовок по имени из MSDP (комнаты без строки выходов)
  local name = Bot.room.name
  if name and name ~= "" and line == name then
    Bot.mark_block_start(line)
    return
  end

  if Bot.block.open then
    -- блок комнаты заканчивается на первой строке без цвета после цветного
    -- содержимого (мобов/предметов): дальше идут боевые сообщения, а не описание
    if kind == "text" and Bot.block.has_color then
      Bot.dbg("[room] блок закрыт: строка без цвета после содержимого: " .. line)
      Bot.commit_packet()
      if #Bot.segment.lines < 8 then
        Bot.segment.lines[#Bot.segment.lines + 1] = line
      end
      return
    end
    if kind == "player" then
      Bot.playerInRoom = true
      Bot.colorHits.player = (Bot.colorHits.player or 0) + 1
      Bot.dbg("[room] игрок: " .. line)
      return
    end
    if kind == "group" then
      Bot.groupInRoom[line] = true
      Bot.colorHits.group = (Bot.colorHits.group or 0) + 1
      return
    end
    if kind == "mob" then
      -- боевая строка (моб ударил/промахнулся/умер) закрывает блок: дальше
      -- идут события, а не существа комнаты
      if Bot.is_action_line(line) then
        Bot.dbg("[room] боевая строка закрывает блок: " .. line)
        Bot.commit_packet()
        return
      end
      -- цветная строка (моб): отдельно от текстового потока — в описании комнаты
      -- тоже есть строки, и они не должны попадать в цели
      Bot.colorHits.mob = (Bot.colorHits.mob or 0) + 1
      Bot.block.has_color = true
      Bot.block.color_lines[#Bot.block.color_lines + 1] = line
      Bot.dbg("[room] цвет-моб: " .. line)
      return
    end
    if kind == "item" then
      -- предметы в комнате (жёлтые) — не цели; запоминаем строки, чтобы они
      -- не всплыли мобами, когда блок придётся разбирать по тексту
      Bot.colorHits.item = (Bot.colorHits.item or 0) + 1
      Bot.block.items = (Bot.block.items or 0) + 1
      Bot.block.has_color = true
      Bot.block.item_lines = Bot.block.item_lines or {}
      Bot.block.item_lines[#Bot.block.item_lines + 1] = line
      Bot.dbg("[room] предмет: " .. line)
      return
    end
    if kind == "text" then
      Bot.block.lines[#Bot.block.lines + 1] = line
      Bot.dbg("[room] содержимое: " .. line)
    end
    return
  end

  -- 4) вне блока: событие («зайчик припрыгал с севера»), держим как кандидата в заголовок
  if #Bot.segment.lines < 8 then
    Bot.segment.lines[#Bot.segment.lines + 1] = line
  end
end

-- блок комнаты: последняя строка до "[ Exits: ... ]" (или известное имя) — заголовок
function Bot.mark_block_start(title)
  if Bot.block.open and not title then
    -- блок уже открыт по имени комнаты из MSDP, строку выходов просто пропускаем
    return
  end
  if not title then
    for i = #Bot.segment.lines, 1, -1 do
      if Bot.segment.lines[i] ~= "" then title = Bot.segment.lines[i] break end
    end
  end
  Bot.block.open = true
  Bot.block.title = title or ""
  Bot.block.lines = {}
  Bot.block.color_lines = {}
  Bot.block.item_lines = {}
  Bot.block.items = 0
  Bot.block.has_color = false
  Bot.block.last_line = nil
  Bot.segment.lines = {}
  Bot.playerInRoom = false
  Bot.groupInRoom = {}
  Bot.dbg("[room] блок комнаты, заголовок: " .. tostring(title))
end

-- служебные строки: [Зона, ...], (mapper): ..., ASCII-карта
Bot.service_line_patterns = {
  "^%[Зона",
  "^%(%a+%):",       -- сообщения mapper'а: "(mapper): Adding open door..."
  "^[%+%-|%s]+$",    -- ASCII-карта
}

function Bot.is_service_line(line)
  for _, pattern in ipairs(Bot.service_line_patterns) do
    if tostring(line):find(pattern) then return true end
  end
  return false
end

-- строка состояния (промпт), чтобы не тащить её в содержимое комнаты
function Bot.is_prompt_line(line)
  if tostring(line):find("^%d+H %d+M %d+V ") then return true end
  if tostring(line):find("Вых:[^>]*>%s*$") then return true end
  return false
end

-- текстовый сборщик: срабатывает на каждую строку (цвета у сервера могут быть выключены).
-- Строка приходит из matches[2] триггера: getCurrentLine() в этой сборке читает
-- курсор пользователя (его двигают echo/debug и серверное «очистить») и может
-- вернуть литерал «ERROR: invalid line number».
function Bot.on_text_line(line)
  line = line or getCurrentLine()
  line = tostring(line or "")
  if line:find("^ERROR:") or line:find("^Lua:") then
    Bot.dbg("[room] служебная строка Mudlet: " .. line)
    return
  end
  -- промпт ловим здесь же: prompt-триггер в этой сборке Mudlet не даёт строку
  if Bot.is_prompt_line(line) then
    if Bot.probe and Bot.probe.open then
      Bot.probe.open = false
      Bot.probe_apply()
    end
    Bot.on_prompt(line)
    return
  end
  -- «пом» без цели — в комнате больше никто не сражается (ответ на «встат/пом»,
  -- которые профиль шлёт после каждой смерти моба)
  if Bot.no_assist_line(line) then
    Bot.on_no_assist()
    return
  end
  -- «Вы замерли на месте, не в силах шевельнуться!» — это не отказ хода и не
  -- моб: BotWalk повторит движение, не расходуя лимит попыток
  if Bot.walk and Bot.walk.hold_line and Bot.walk.hold_line(line) then return end
  -- ожидание сообщения (шаг trigger): сверяем строку, но дальше её тоже разбираем
  if Bot.walk and Bot.walk.trigger_line then Bot.walk.trigger_line(line) end
  -- ответ «обл» (экземпляры зон и таймеры репопа)
  if Bot.instance_probe_line(line) then return end
  -- разбор ответа «обл и» (смежные зоны при записи маршрута)
  if Bot.zone_probe_line(line) then return end
  -- кто-то начал бой в комнате (в группе это партнёр): маршрут ждёт
  if Bot.fight_start_line(line) then Bot.set_room_fight(true) end
  -- боевая строка: пока комната «шумит», look-перепроверку не шлём
  if Bot.is_action_line(line) then Bot.fightNoiseAt = Bot.now() end
  -- агрессоры («… напал на вас»): в зоне-списке бьём их всегда
  Bot.safe("агрессор", Bot.aggro_scan, line)
  -- цвет нужен только внутри блока комнаты (проза/мобы/предметы приходят там);
  -- цвет читаем по выделению строки, см. Bot.line_rgb
  local kind = "text"
  if Bot.block.open then
    kind = Bot.color_kind(Bot.line_rgb()) or "text"
  end
  Bot.on_room_line(kind, line)
end

-- после хода/look начинается новый блок комнаты
function Bot.expect_block()
  Bot.segment.lines = {}
  Bot.block.open = false
  Bot.block.lines = {}
  Bot.block.color_lines = {}
  Bot.block.items = 0
  Bot.block.last_line = nil
end

-- ===================== файлы и лор мобов =====================

function Bot.base_dir()
  return getMudletHomeDir() .. "/bot"
end

function Bot.zone_path(name)
  return Bot.base_dir() .. "/zones/" .. tostring(name) .. ".lua"
end

function Bot.ensure_dir(path)
  if not (lfs and lfs.attributes and lfs.mkdir) then return end
  local parts = {}
  for part in tostring(path):gmatch("[^/]+") do parts[#parts + 1] = part end
  local cur = tostring(path):sub(1, 1) == "/" and "" or "."
  for _, part in ipairs(parts) do
    cur = cur .. "/" .. part
    if not lfs.attributes(cur) then lfs.mkdir(cur) end
  end
end

function Bot.file_exists(path)
  if io.exists then return io.exists(path) end
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

function Bot.count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

-- признак «строка похожа на существо», когда цветов нет:
-- описание комнаты сервер режет по строкам, продолжения начинаются со строчной
-- или обрываются на запятой; строки существ — отдельные предложения с заглавной.
Bot.mob_start_blacklist = {
  "^Вы ", "^Вам ", "^Вас ", "^Ваш", "^Ваше", "^Это ", "^Здесь", "^Тут", "^Там",
}

-- строка — продолжение описания предыдущей («...», аура, обрыв строки).
-- В цветном режиме такие строки приходят тем же цветом, что и моб, и не должны
-- становиться отдельной целью.
function Bot.is_continuation_line(line)
  local s = Bot.strip_mob_markers(line or "")
  if s == "" then return true end
  if s:sub(1, 3) == "..." then return true end
  return not Bot.starts_uppercase(s)
end

function Bot.starts_uppercase(s)
  local b1, b2 = tostring(s or ""):byte(1, 2)
  if not b1 then return false end
  if b1 >= 65 and b1 <= 90 then return true end          -- A-Z
  if b1 == 208 and b2 then                                -- UTF-8 D0 ..
    if (b2 >= 144 and b2 <= 175) or b2 == 129 then return true end -- А-Я, Ё
  end
  return false
end

function Bot.looks_like_mob(line)
  local s = Bot.strip_mob_markers(line)
  if s == "" then return false end
  local tail = s:sub(-1)
  if tail == "," or tail == ";" or tail == ":" then return false end
  if not s:match("[%.%)!%?]$") then return false end
  if not Bot.starts_uppercase(s) then return false end
  for _, pattern in ipairs(Bot.mob_start_blacklist) do
    if s:find(pattern) then return false end
  end
  -- боевые строки («… ударил вас ногой! ...[14]») — не существа и в тексте
  if Bot.is_action_line and Bot.is_action_line(s) then return false end
  return true
end

-- строки-действия: бой, эмоции, события. Существо в комнате описывается
-- состоянием («стоит тут», «щиплет здесь травку»), а действие — прошедшим
-- временем («ударил вас ногой! ...[14]», «попытался рубануть, но промахнулся»).
-- Без этого фильтра красные боевые строки попадали в цели: «мобов в комнате 4»
-- вместо 2, лишние атаки и «не добил мобов».
Bot.action_markers = {
  " попытал", " промахнул", " ударил", " ударила", " ударили", " забил", " забилась",
  " произнес", " произнесла", " сказал", " сказала", " сказали", " крикнул",
  " воскликнул", " прошептал", " прошептала", " улыбнул", " улыбнулась",
  " вздохнул", " вздохнула", " всхлипнул", " посмотрел", " посмотрела",
  " пришел", " пришла", " пришли", " ушел", " ушла", " ушли", " вошел",
  " вошла", " вышел", " вышла", " вышли", " поднялся", " поднялась",
  " прекратил", " прекратила", " запаниковал", " снова здоров", " снова здорова",
  " следует за", " следовать за", " взмахнул", " сделал", " сделала",
  " пронзил", " пронзила", " окутал", " окутала", " замерцал", " отвлек",
  " пролил", " двинул", " оглушен", " оглушена", " побежал", " отбежал",
  " исчез", " появил", " скрыл", " напал", " атаковал", " убежал",
  " поспешил", " двинулся", " отступил", " схватил", " бросил", " починил",
  " установил", " собрал", " освободил", " разбил", " нажал", " повернул",
  " оставил", " приложил", " втиснул", " дал вам", " дала вам",
}

function Bot.is_action_line(line)
  local s = Bot.trim(line)
  if s == "" then return false end
  -- урон/яд: «... [252]», «(x2)», «------------- [ POISON ]»
  if s:find("%.%.%.%s*%[%d+%]") then return true end
  if s:find("%(%s*x%d+%s*%)") then return true end
  if s:find("%[%s*POISON%s*%]") then return true end
  -- строки про игрока: «Вы …», «Вам …», «Ваш вред …»
  for _, pattern in ipairs(Bot.mob_start_blacklist) do
    if s:find(pattern) then return true end
  end
  for _, marker in ipairs(Bot.action_markers) do
    if s:find(marker, 1, true) then return true end
  end
  return false
end

-- ===================== маршруты зон =====================

Bot.zones = Bot.zones or {}   -- кэш: [зона] = { entry = ..., steps = {...} }

local function sorted_keys(t)
  local keys = {}
  for key, value in pairs(t or {}) do
    if value then keys[#keys + 1] = tostring(key) end
  end
  table.sort(keys)
  return keys
end

-- набор имён: kill = { ["Ученик магов"] = true }
local function write_str_set(f, name, set, indent)
  if type(set) ~= "table" then return end
  local keys = sorted_keys(set)
  if #keys == 0 then return end
  f:write(indent .. name .. " = {\n")
  for _, key in ipairs(keys) do
    f:write(indent .. "  [" .. string.format("%q", key) .. "] = true,\n")
  end
  f:write(indent .. "},\n")
end

-- «не бить» по комнатам: noattack = { ["110056"] = { ["Захудалый старикашка"] = true } }
local function write_room_set(f, name, set, indent)
  if type(set) ~= "table" then return end
  local rooms = sorted_keys(set)
  if #rooms == 0 then return end
  f:write(indent .. name .. " = {\n")
  for _, room in ipairs(rooms) do
    local list = type(set[room]) == "table" and set[room] or nil
    local names = sorted_keys(list)
    if #names > 0 then
      f:write(indent .. "  [" .. string.format("%q", room) .. "] = {\n")
      for _, one in ipairs(names) do
        f:write(indent .. "    [" .. string.format("%q", one) .. "] = true,\n")
      end
      f:write(indent .. "  },\n")
    end
  end
  f:write(indent .. "},\n")
end

local function chunk_load(src, name)
  local loader = loadstring or load
  return loader(src, name)
end

function Bot.save_zone(name, data)
  Bot.ensure_dir(Bot.base_dir() .. "/zones")
  local f, err = io.open(Bot.zone_path(name), "wb")
  if not f then return false, tostring(err) end
  f:write("-- маршрут зоны " .. tostring(name) .. " (сгенерировано BotCore)\n")
  f:write("-- dir — ход, room — ожидаемый VNUM после хода, cmd — действие в комнате, wait — пауза (сек)\n")
  f:write("-- entry — вход в зону: клетка перед зоной, направление и макс. сложность для «гг !обл созда»\n")
  f:write("return {\n")
  if data.entry then
    local e = data.entry
    local parts = {}
    if e.vnum then
      parts[#parts + 1] = "vnum = " .. string.format("%q", tostring(e.vnum))
    end
    if e.dir then parts[#parts + 1] = "dir = " .. string.format("%q", tostring(e.dir)) end
    if e.maxdiff then
      local n = tonumber((tostring(e.maxdiff):gsub("^%+", "")))
      if n then
        parts[#parts + 1] = "maxdiff = " .. tostring(n)
      else
        parts[#parts + 1] = "maxdiff = " .. string.format("%q", tostring(e.maxdiff))
      end
    end
    if e.num then parts[#parts + 1] = "num = " .. tostring(e.num) end
    if e.title and e.title ~= "" then
      parts[#parts + 1] = "title = " .. string.format("%q", tostring(e.title))
    end
    if #parts > 0 then
      f:write("  entry = { " .. table.concat(parts, ", ") .. " },\n")
    end
  end
  f:write("  mode = " .. string.format("%q", data.mode == "list" and "list" or "all") .. ",\n")
  write_str_set(f, "kill", data.kill, "  ")
  write_str_set(f, "aggro", data.aggro, "  ")
  write_room_set(f, "noattack", data.noattack, "  ")
  local function write_step(step, indent)
    local parts = {}
    if step.dir then parts[#parts + 1] = "dir = " .. string.format("%q", tostring(step.dir)) end
    if step.cmd then parts[#parts + 1] = "cmd = " .. string.format("%q", tostring(step.cmd)) end
    if step.trigger then
      parts[#parts + 1] = "trigger = " .. string.format("%q", tostring(step.trigger))
    end
    if step.timeout then parts[#parts + 1] = "timeout = " .. tostring(step.timeout) end
    if step.wait then parts[#parts + 1] = "wait = " .. tostring(step.wait) end
    if step.room then parts[#parts + 1] = "room = " .. tostring(step.room) end
    f:write(indent .. "{ " .. table.concat(parts, ", ") .. " },\n")
  end
  f:write("  steps = {\n")
  for _, step in ipairs(data.steps) do write_step(step, "    ") end
  f:write("  },\n")
  if type(data.final_steps) == "table" and #data.final_steps > 0 then
    f:write("  final_steps = {\n")
    for _, step in ipairs(data.final_steps) do write_step(step, "    ") end
    f:write("  },\n")
  end
  f:write("}\n")
  f:close()
  return true
end

-- только чтение файла и нормализация: без кэша и без переноса «не бить»
function Bot.read_zone(name)
  local path = Bot.zone_path(name)
  local f = io.open(path, "rb")
  if not f then return nil, "нет файла " .. path end
  local src = f:read("*a")
  f:close()
  local chunk, err = chunk_load(src, "@" .. path)
  if not chunk then return nil, "синтаксис: " .. tostring(err) end
  local ok, data = pcall(chunk)
  if not ok or type(data) ~= "table" or type(data.steps) ~= "table" then
    return nil, "битый маршрут " .. path
  end
  -- старые файлы без правил читаются как «бить всех», списки пустые
  data.mode = (data.mode == "list") and "list" or "all"
  data.kill = type(data.kill) == "table" and data.kill or {}
  data.aggro = type(data.aggro) == "table" and data.aggro or {}
  data.noattack = type(data.noattack) == "table" and data.noattack or {}
  -- финальные шаги после маршрута (например, возврат в город и путь на склад).
  -- Комнату для них не проверяем: после «сл.воз» игрок может оказаться где угодно.
  if type(data.final_steps) == "table" then
    local final = {}
    for _, step in ipairs(data.final_steps) do
      if type(step) == "table" then final[#final + 1] = step end
    end
    data.final_steps = #final > 0 and final or nil
  else
    data.final_steps = nil
  end
  -- сложность в файле — число; «+3» из ручной правки тоже принимаем
  if type(data.entry) == "table" and data.entry.maxdiff ~= nil then
    local n = tonumber((tostring(data.entry.maxdiff):gsub("^%+", "")))
    if n then data.entry.maxdiff = n end
  end
  return data
end

function Bot.load_zone(name)
  local data, err = Bot.read_zone(name)
  if not data then return nil, err end
  Bot.zones[name] = data
  Bot.invalidate_rules(name)
  -- «не бить» из старого глобального файла переезжает в зону, которой принадлежит
  Bot.migrate_noattack(name, data)
  return data
end

function Bot.zone_data(name)
  local cached = Bot.zones[name]
  if cached then return cached end
  return Bot.load_zone(name)
end

-- перечитать файл зоны с диска (ручные правки применяются без reload профиля)
function Bot.reload_zone(name)
  if not name or name == "" then return nil, "не указана зона" end
  Bot.zones[name] = nil
  Bot.invalidate_rules(name)
  return Bot.load_zone(name)
end

-- каталог записанных зон: имена файлов без ".lua", по алфавиту без регистра
local function zone_shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function zone_lfs()
  local lib = lfs
  if lib and lib.dir then return lib end
  if type(require) == "function" then
    local ok, mod = pcall(require, "lfs")
    if ok and type(mod) == "table" and mod.dir then return mod end
  end
  return nil
end

function Bot.zone_files()
  local dir = Bot.base_dir() .. "/zones"
  local names, listed = {}, false
  local lib = zone_lfs()
  if lib then
    local ok, iter, state, init = pcall(lib.dir, dir)
    if ok and iter then
      listed = pcall(function()
        for entry in iter, state, init do
          local name = tostring(entry):match("^(.+)%.lua$")
          if name and name ~= "" then names[#names + 1] = name end
        end
      end)
      if not listed then names = {} end
    end
  end
  if not listed and io.popen then
    local cmd = "ls -1 " .. zone_shell_quote(dir) .. " 2>/dev/null"
    local ok, pipe = pcall(io.popen, cmd, "r")
    if ok and pipe then
      local text = ""
      local read_ok = pcall(function() text = pipe:read("*a") or "" end)
      pipe:close()
      if read_ok then
        listed = true
        for line in tostring(text):gmatch("[^\r\n]+") do
          local name = line:match("^(.+)%.lua$")
          if name and name ~= "" then names[#names + 1] = name end
        end
      end
      if not listed then names = {} end
    end
  end
  if not listed then
    return nil, "не удалось прочитать каталог " .. dir
  end
  table.sort(names, function(a, b)
    local fa, fb = Bot.fold(a), Bot.fold(b)
    if fa == fb then return a < b end
    return fa < fb
  end)
  return names
end

-- .бот зоны: локальные файлы маршрутов, без запроса «обл»
function Bot.zones_list()
  local names, err = Bot.zone_files()
  if not names then
    Bot.warn("<red>Зоны: " .. tostring(err))
    return
  end
  if #names == 0 then
    Bot.echo("<gray>Записанных зон нет. Каталог: <reset>" .. Bot.base_dir() .. "/zones")
    Bot.echo("<gray>Начать запись: <reset>.бот запись старт «зона»")
    return
  end
  local in_circle = {}
  for _, zone in ipairs((Bot.loop and Bot.loop.list) or {}) do
    in_circle[zone] = true
  end
  Bot.echo("<green>Записанные зоны: <yellow>" .. tostring(#names) ..
    "<gray> (" .. Bot.base_dir() .. "/zones)")
  for i, name in ipairs(names) do
    local flags = {}
    if Bot.zone == name then flags[#flags + 1] = "<yellow>[идёт]" end
    if Bot.resume and Bot.resume.zone == name and Bot.zone ~= name then
      flags[#flags + 1] = "<gray>[продолжение]"
    end
    if in_circle[name] then flags[#flags + 1] = "<green>[в круге]" end
    local tail = #flags > 0 and ("  " .. table.concat(flags, " ")) or ""
    local data, readerr = Bot.read_zone(name)
    if not data then
      Bot.echo(string.format("<gray>%2d. <cyan>%s<reset> <red>не читается: %s%s",
        i, name, tostring(readerr), tail))
    else
      Bot.echo(string.format(
        "<gray>%2d. <cyan>%s<reset> <gray>— <yellow>%d<gray> шагов, режим <reset>%s" ..
        "<gray>, целей <reset>%d<gray>, агрессоров <reset>%d",
        i, name, #data.steps, data.mode == "list" and "список" or "все",
        Bot.count(data.kill), Bot.count(data.aggro)))
      Bot.echo("<gray>     вход: <reset>" .. Bot.entry_desc(data.entry) .. tail)
    end
  end
end

-- ===================== запись маршрута =====================

Bot.record = Bot.record or {
  name = nil,       -- имя записываемой зоны
  steps = {},       -- готовые шаги (подтверждённые ходы + действия/паузы)
  queue = {},       -- отправленные, но ещё не подтверждённые ходы (FIFO)
  deferred = {},    -- действия/паузы, набранные до подтверждения ходов
  drops = 0,        -- сколько ходов не подтвердилось
  mode = "all",     -- тип зоны: all | list (задаётся при старте записи)
  kill = {},        -- цели в записи (режим list)
  aggro = {},       -- агрессоры, выученные в записи
  noattack = {},    -- «не бить» по комнатам, набранное в записи
}

function Bot.record_start(name, mode)
  if Bot.running() then
    Bot.warn("<orange>Бот идёт по зоне — сначала .бот стоп")
    return
  end
  mode = Bot.fold(mode)
  Bot.record.name = name
  Bot.record.steps = {}
  Bot.record.queue = {}
  Bot.record.deferred = {}
  Bot.record.drops = 0
  Bot.record.mode = (mode == "list" or mode == "список") and "list" or "all"
  Bot.resume = nil
  Bot.record.kill = {}
  Bot.record.aggro = {}
  Bot.record.noattack = {}
  -- клетка, на которой начинается запись = клетка прямо перед зоной
  Bot.record.entry = { vnum = Bot.vnum() }
  Bot.probe_reset()
  Bot.zoneHint = nil
  Bot.state = "record"
  Bot.echo("<green>Запись зоны начата: <cyan>" .. tostring(name) ..
    "<reset>\n<gray>Ходы — по одной команде, действия — <yellow>.триг <команда>" ..
    "<gray>, ожидание — <yellow>.пауза <сек><gray>.")
  Bot.echo("<gray>Тип зоны: <yellow>" ..
    (Bot.record.mode == "list" and "список (бить только цели; .бот бить добавляет)"
      or "все (бить всех на пути)"))
  Bot.echo("<gray>Клетка входа: <yellow>" .. tostring(Bot.record.entry.vnum) ..
    "<gray>. Жду ответ «Наличие смежных зон» (можно набрать «обл и» руками).")
  local probe = Bot.config.zoneProbe
  if probe and probe ~= "" then Bot.send(probe) end
end

function Bot.record_stop()
  if not Bot.record.name then
    Bot.warn("Запись не ведётся")
    return
  end
  Bot.record_drain()
  local name = Bot.record.name
  local steps = Bot.record.steps
  Bot.record.name = nil
  Bot.state = "idle"
  local data = { steps = steps, mode = Bot.record.mode or "all" }
  -- списки целей/агрессоров/«не бить» не теряем при перезаписи маршрута
  local old = Bot.load_zone(name)
  data.kill, data.aggro, data.noattack = {}, {}, {}
  if old then
    -- ручные финальные действия не теряем при повторной записи маршрута
    data.final_steps = old.final_steps
    for k, v in pairs(old.kill or {}) do data.kill[k] = v end
    for k, v in pairs(old.aggro or {}) do data.aggro[k] = v end
    for room, list in pairs(old.noattack or {}) do
      data.noattack[room] = {}
      for k, v in pairs(list) do data.noattack[room][k] = v end
    end
  end
  local added = { kill = 0, aggro = 0, noattack = 0 }
  for k, v in pairs(Bot.record.kill or {}) do
    if v and not data.kill[k] then data.kill[k] = true; added.kill = added.kill + 1 end
  end
  for k, v in pairs(Bot.record.aggro or {}) do
    if v and not Bot.name_in(data.aggro, k) and not Bot.name_in(data.kill, k) then
      data.aggro[k] = true; added.aggro = added.aggro + 1
    end
  end
  for room, list in pairs(Bot.record.noattack or {}) do
    data.noattack[room] = data.noattack[room] or {}
    for k, v in pairs(list) do
      if v and not data.noattack[room][k] then
        data.noattack[room][k] = true; added.noattack = added.noattack + 1
      end
    end
  end
  local entry = Bot.record.entry
  if entry and (not entry.dir or not entry.maxdiff) and Bot.zoneHint then
    -- резерв: направление и название из строки «[Зона, на юг: …]»
    entry.dir = entry.dir or Bot.zoneHint.dir
    entry.title = entry.title or Bot.zoneHint.title
  end
  if entry and not (entry.dir and entry.maxdiff) then
    Bot.warn("<orange>Вход в зону распознан не полностью (нет направления/сложности): " ..
      "«гг !обл созда» при запуске отправлен не будет.")
    Bot.warn("<gray>Поправить можно до «стоп»: <yellow>.бот запись вход + <направление> <сложность>")
  end
  if entry then data.entry = entry end
  Bot.record.entry = nil
  if data.mode == "list" and Bot.count(data.kill) == 0 and Bot.count(data.aggro) == 0 then
    Bot.warn("<orange>Зона в режиме «список», но цели пусты: бот не будет драться. " ..
      "Пометьте мобов командой <yellow>.бот бить<orange> при проходе.")
  end
  local ok, err = Bot.save_zone(name, data)
  if ok then
    Bot.zones[name] = data
    Bot.invalidate_rules(name)
    Bot.echo("<green>Запись зоны <cyan>" .. name .. "<green> сохранена: <yellow>" ..
      tostring(#steps) .. "<green> шагов, потеряно ходов: <yellow>" ..
      tostring(Bot.record.drops) .. "\n<gray>режим: <reset>" ..
      (data.mode == "list" and "список" or "все") ..
      "<gray>, целей " .. tostring(Bot.count(data.kill)) ..
      " (+" .. tostring(added.kill) .. "), агрессоров " ..
      tostring(Bot.count(data.aggro)) .. " (+" .. tostring(added.aggro) .. "), не бью " ..
      tostring(Bot.count(data.noattack)) .. " (+" .. tostring(added.noattack) .. ")" ..
      "\n<gray>вход: " .. Bot.entry_desc(entry) ..
      "\n<gray>файл: " .. Bot.zone_path(name))
  else
    Bot.warn("Не смог сохранить маршрут: " .. tostring(err))
  end
end

function Bot.record_reset()
  Bot.record.name = nil
  Bot.record.steps = {}
  Bot.record.queue = {}
  Bot.record.deferred = {}
  Bot.record.entry = nil
  Bot.record.mode = "all"
  Bot.record.kill, Bot.record.aggro, Bot.record.noattack = {}, {}, {}
  Bot.probe_reset()
  Bot.zoneHint = nil
  if Bot.state == "record" then Bot.state = "idle" end
  Bot.echo("Запись маршрута сброшена")
end

-- ===================== «обл и»: смежные зоны =====================
-- При записи бот спрашивает «обл и» и разбирает ответ:
--   Наличие смежных зон:
--          На юге: [472] Королевский фрегат
--                  Сложность макс: 1, текущая: 0, прохождений: 0
-- Отсюда берётся направление входа, [номер] зоны и её макс. сложность —
-- потом это уходит в «гг !обл созда <направление> <сложность>».

Bot.dir_forms = {
  ["севере"] = "север", ["юге"] = "юг", ["востоке"] = "восток", ["западе"] = "запад",
  ["вверху"] = "вверх", ["наверху"] = "вверх", ["внизу"] = "вниз", ["под"] = "вниз",
  ["северо-востоке"] = "северо-восток", ["северо-западе"] = "северо-запад",
  ["юго-востоке"] = "юго-восток", ["юго-западе"] = "юго-запад",
}

-- «юге» → «юг», «наверху» → «вверх»
function Bot.dir_form(word)
  local w = tostring(word or ""):lower()
  if Bot.dir_forms[w] then return Bot.dir_forms[w] end
  w = w:gsub("е$", "")
  return Bot.dir_names[w] or w
end

function Bot.probe_reset()
  Bot.probe = { open = false, list = {} }
end

-- одна запись входа: «[472] Королевский фрегат, юг, макс. сложность 1, клетка 100051»
function Bot.entry_desc(e)
  if not e then return "не зафиксирован" end
  local parts = {}
  if e.num or e.title then
    parts[#parts + 1] = "[" .. tostring(e.num or "?") .. "] " .. tostring(e.title or "?")
  end
  if e.dir then parts[#parts + 1] = "направление " .. tostring(e.dir) end
  if e.maxdiff then parts[#parts + 1] = "макс. сложность " .. tostring(e.maxdiff) end
  if e.vnum and tostring(e.vnum) ~= "" then parts[#parts + 1] = "клетка " .. tostring(e.vnum) end
  return table.concat(parts, ", ")
end

-- разбор строки ответа «обл и»; true — строка наша (в блок комнаты её не пускаем)
function Bot.zone_probe_line(line)
  line = tostring(line or "")
  if line:find("^Наличие смежных зон") then
    Bot.probe = { open = true, list = {} }
    return true
  end
  if not (Bot.probe and Bot.probe.open) then return false end

  local dir_word, num, title = line:match("^%s*На%s+(%S+):%s*%[(%d+)%]%s*(.+)$")
  if dir_word then
    Bot.probe.list[#Bot.probe.list + 1] = {
      dir = Bot.dir_form(dir_word),
      num = tonumber(num),
      title = Bot.trim(title),
    }
    return true
  end

  local diff = line:match("^%s*Сложность макс:%s*(%d+)")
  if diff then
    local last = Bot.probe.list[#Bot.probe.list]
    if last then last.maxdiff = tonumber(diff) end
    return true
  end

  -- блок кончился: пустая строка или посторонний текст
  Bot.probe.open = false
  Bot.probe_apply()
  return Bot.trim(line) == ""
end

-- выбрать зону из ответа и запомнить её как вход в записываемую зону
function Bot.probe_apply()
  local list = Bot.probe and Bot.probe.list or {}
  if #list == 0 then return end
  if not (Bot.record and Bot.record.name) then return end

  local pick
  local want = tostring(Bot.record.name or ""):lower()
  if want ~= "" then
    for _, e in ipairs(list) do
      if tostring(e.title or ""):lower():find(want, 1, true) then pick = e break end
    end
  end
  if not pick then
    pick = list[1]
    if #list > 1 then
      local names = {}
      for _, e in ipairs(list) do names[#names + 1] = tostring(e.dir) .. " — " .. tostring(e.title) end
      Bot.warn("<orange>Смежных зон несколько, беру первую: " ..
        tostring(pick.title) .. " <gray>(" .. table.concat(names, "; ") .. ")")
    end
  end

  local entry = Bot.record.entry or {}
  entry.vnum = entry.vnum or Bot.vnum()
  entry.dir = pick.dir
  entry.maxdiff = pick.maxdiff
  entry.num = pick.num
  entry.title = pick.title
  Bot.record.entry = entry
  Bot.echo("<gray>[запись] вход в зону: <yellow>" .. Bot.entry_desc(entry))
end

-- ===================== «обл»: экземпляры зон и таймеры репопа =====================
-- Ответ:
--   Ваши экземпляры зон:
--    Статус  Номер  Название    Лидер      Репоп  Таймер
--    активен  138   Муравейник  Барг         60   1 минута 29 секунд
--    активен  466   Хельхейм    Элронг      180   удалите вручную
-- Если зоны в списке нет — её можно создавать/заходить.

function Bot.instance_key(name)
  local s = Bot.fold(name or "")
  s = s:gsub("_", " "):gsub("%s+", " ")
  return Bot.trim(s)
end

-- «1 минута 29 секунд» → 89; «удалите вручную» → nil, true
function Bot.parse_instance_timer(text)
  local s = Bot.fold(text or "")
  if s:find("вручную", 1, true) or s:find("удал", 1, true) then
    return nil, true
  end
  local h = tonumber(s:match("(%d+)%s*час"))
  local m = tonumber(s:match("(%d+)%s*минут"))
  local sec = tonumber(s:match("(%d+)%s*секунд"))
  if not (h or m or sec) then return nil, false end
  return (h or 0) * 3600 + (m or 0) * 60 + (sec or 0), false
end

function Bot.secs_desc(sec)
  sec = math.max(0, math.floor(tonumber(sec) or 0))
  local m = math.floor(sec / 60)
  local s = sec % 60
  if m > 0 then return tostring(m) .. "м " .. tostring(s) .. "с" end
  return tostring(s) .. "с"
end

function Bot.instance_probe_reset()
  Bot.instance_probe = { open = false, ignore = false, cols = nil, rows = 0 }
end

-- разбор строки ответа «обл»; true — строка наша (в блок комнаты её не пускаем)
function Bot.instance_probe_line(line)
  local s = Bot.trim(line or "")
  local P = Bot.instance_probe or {}
  Bot.instance_probe = P

  if P.ignore then
    if s == "" then P.ignore = false end
    return true
  end

  if s:find("^Ваши экземпляры зон") then
    P.open = true
    P.ignore = false
    P.cols = nil
    P.rows = 0
    Bot.instances = {}
    return true
  end
  if not P.open then return false end

  if s:find("^У вас нет экземпляр") or s:find("^Нет экземпляр") then
    Bot.instances = {}
    P.open = false
    Bot.on_instances_ready()
    return true
  end

  if s:find("^Статус") and s:find("Номер", 1, true) and s:find("Название", 1, true) then
    local function pos(word) return line:find(word, 1, true) end
    local cols = {
      status = pos("Статус"), num = pos("Номер"), name = pos("Название"),
      leader = pos("Лидер"), repop = pos("Репоп"), timer = pos("Таймер"),
    }
    if cols.status and cols.num and cols.name then P.cols = cols end
    return true
  end

  if s:find("^Использование:") then
    P.open = false
    P.ignore = true
    Bot.on_instances_ready()
    return true
  end

  if s == "" then
    if P.rows > 0 or P.cols then
      P.open = false
      Bot.on_instances_ready()
    end
    return true
  end

  local status, num, rest = s:match("^(%S+)%s+(%d+)%s+(.+)$")
  if not status then
    P.open = false
    Bot.on_instances_ready()
    return false
  end

  local inst = { status = status, num = tonumber(num) }
  -- Поля разделены 2+ пробелами: имя может быть из нескольких слов с одним
  -- пробелом («Башня магов»), а лидер — одним словом.
  local name, leader, repop, timer = rest:match("^(.-)%s%s+(%S+)%s+(%d+)%s+(.+)$")
  if name then
    inst.name, inst.leader = name, leader
    inst.repop_text, inst.timer_text = repop, timer
  elseif P.cols then
    local function slice(from, to)
      if not from then return "" end
      return Bot.trim(line:sub(from, (to and (to - 1)) or #line))
    end
    inst.name = slice(P.cols.name, P.cols.leader)
    inst.leader = slice(P.cols.leader, P.cols.repop)
    inst.repop_text = slice(P.cols.repop, P.cols.timer)
    inst.timer_text = slice(P.cols.timer)
  end
  inst.repop = tonumber(inst.repop_text)
  inst.seconds, inst.manual = Bot.parse_instance_timer(inst.timer_text)
  if inst.name and inst.name ~= "" then
    Bot.instances[Bot.instance_key(inst.name)] = inst
    P.rows = P.rows + 1
  end
  return true
end

-- экземпляр для зоны: по имени, по entry.title, затем по вхождению
function Bot.instance_for(zone)
  if not zone or zone == "" then return nil end
  local key = Bot.instance_key(zone)
  local inst = Bot.instances[key]
  if inst then return inst end
  local data = Bot.zones[zone]
  local title = data and data.entry and data.entry.title
  if title then
    inst = Bot.instances[Bot.instance_key(title)]
    if inst then return inst end
  end
  for k, value in pairs(Bot.instances) do
    if k:find(key, 1, true) or key:find(k, 1, true) then return value end
  end
  return nil
end

-- печать разобранного списка
function Bot.show_instances()
  if next(Bot.instances) == nil then
    Bot.echo("<gray>Экземпляров зон нет — все зоны свободны")
    return
  end
  Bot.echo("<green>Экземпляры зон:")
  local keys = {}
  for key in pairs(Bot.instances) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local i = Bot.instances[key]
    local timer
    if i.manual then
      timer = "<orange>удалите вручную"
    elseif i.seconds then
      timer = "осталось " .. Bot.secs_desc(i.seconds)
    else
      timer = tostring(i.timer_text or "?")
    end
    Bot.echo(string.format(
      "<gray>  %s <yellow>[%s]<reset> %s<gray> — лидер %s, репоп %s мин, %s",
      tostring(i.status or "?"), tostring(i.num or "?"), tostring(i.name or "?"),
      tostring(i.leader or "?"), tostring(i.repop or "?"), timer))
  end
end

-- блок «обл» закончился: обновить данные и выполнить запрос
function Bot.on_instances_ready()
  Bot.instancesAt = Bot.now()
  local mode = Bot.instanceQuery
  Bot.instanceQuery = nil
  if mode == "show" then
    Bot.show_instances()
  elseif mode == "circle" then
    if Bot.circle_step then Bot.circle_step() end
  elseif mode == "circle_info" then
    if Bot.circle_info then Bot.circle_info() end
  end
end

-- запрос «обл» под конкретную задачу (show / circle / circle_info)
function Bot.instance_query(mode)
  Bot.instanceQuery = mode
  Bot.instance_probe_reset()
  Bot.send("обл")
  local wait = Bot.config.instanceWait or 5
  Bot.later(wait, "обл", function()
    if Bot.instanceQuery ~= mode then return end
    Bot.instanceQuery = nil
    Bot.warn("<orange>Нет ответа на «обл» — использую сохранённые данные")
    if mode == "show" then
      Bot.show_instances()
    elseif mode == "circle" then
      if Bot.circle_fallback then Bot.circle_fallback() end
    elseif mode == "circle_info" then
      if Bot.circle_info then Bot.circle_info() end
    end
  end)
end

-- ход отправлен: ставим в очередь на подтверждение VNUM (очередь, а не один pending:
-- быстрый ввод и спидвок не теряют шаги)
function Bot.record_move(dir)
  Bot.record_expire()
  local item = { dir = dir, deadline = Bot.now() + (Bot.config.waitAfterMove or 3) }
  Bot.record.queue[#Bot.record.queue + 1] = item
  Bot.dbg("[record] ход в очередь: " .. tostring(dir) ..
    " (" .. tostring(#Bot.record.queue) .. ")")
end

-- общий путь для действий и пауз: если есть неподтверждённые ходы, шаг откладывается
function Bot.record_push(step)
  if #Bot.record.queue > 0 then
    Bot.record.deferred[#Bot.record.deferred + 1] = step
    return false
  end
  step.room = step.room or Bot.vnum()
  Bot.record.steps[#Bot.record.steps + 1] = step
  return true
end

-- отложенные шаги получают комнату, когда все ходы подтверждены
function Bot.record_flush()
  if #Bot.record.queue > 0 or #Bot.record.deferred == 0 then return end
  local room = Bot.vnum()
  for _, step in ipairs(Bot.record.deferred) do
    step.room = step.room or room
    Bot.record.steps[#Bot.record.steps + 1] = step
  end
  Bot.record.deferred = {}
  Bot.dbg("[record] отложенные шаги добавлены, комната " .. tostring(room))
end

-- действие записано: выполняется в текущей комнате
function Bot.record_action(cmd)
  Bot.record_expire()
  cmd = Bot.trim(cmd)
  if cmd == "" then return end
  local now_room = Bot.record_push({ cmd = cmd })
  Bot.echo("<cyan>[запись]<reset> действие " ..
    (now_room and ("в комнате <yellow>" .. tostring(Bot.vnum())) or
      "(<gray>после подтверждения хода<reset>)") .. ": " .. cmd)
end

-- пауза записана: шаг { wait = сек } в маршруте
function Bot.record_wait(sec)
  Bot.record_expire()
  sec = tonumber((tostring(sec or ""):gsub(",", ".")))
  if not sec or sec <= 0 then
    Bot.warn("<orange>Формат: <yellow>.пауза <сек><orange>, например .пауза 3")
    return
  end
  local now_room = Bot.record_push({ wait = sec })
  Bot.echo("<cyan>[запись]<reset> пауза <yellow>" .. tostring(sec) .. "с<reset> " ..
    (now_room and ("в комнате " .. tostring(Bot.vnum())) or "(после подтверждения хода)"))
end

-- ожидание сообщения записано: шаг { trigger = "..." } в маршруте
function Bot.record_trigger(text)
  Bot.record_expire()
  text = Bot.trim(text)
  if text == "" then
    Bot.warn("<orange>Формат: <yellow>.бот ждать <текст сообщения>")
    return
  end
  local now_room = Bot.record_push({ trigger = text })
  Bot.echo("<cyan>[запись]<reset> ждать сообщение <yellow>\"" .. text .. "\"<reset> " ..
    (now_room and ("в комнате " .. tostring(Bot.vnum())) or "(после подтверждения хода)"))
end

-- подтверждение хода по MSDP (событие msdp.ROOM): строго FIFO
function Bot.record.on_room(vnum)
  if Bot.state ~= "record" then return end
  local queue = Bot.record.queue
  if #queue == 0 or vnum == "" then return end
  local item = table.remove(queue, 1)
  item.deadline = nil
  item.room = vnum
  Bot.record.steps[#Bot.record.steps + 1] = item
  Bot.dbg("[record] " .. tostring(item.dir) .. " -> " .. tostring(vnum) ..
    " (шагов: " .. tostring(#Bot.record.steps) ..
    ", в очереди: " .. tostring(#queue) .. ")")
  if #queue == 0 then Bot.record_flush() end
  if Bot.panelUpdate then Bot.panelUpdate() end
end

-- истёкшие ходы выбрасываем; если очередь опустела — фиксируем отложенные шаги
function Bot.record_expire()
  local queue = Bot.record.queue
  local now = Bot.now()
  while queue[1] and now >= (queue[1].deadline or 0) do
    local item = table.remove(queue, 1)
    Bot.warn("<orange>Ход «" .. tostring(item.dir) .. "» не подтвердился — не записан")
    Bot.record.drops = Bot.record.drops + 1
  end
  if #queue == 0 then Bot.record_flush() end
end

-- принудительно закрыть запись: всё неподтверждённое выбрасываем, отложенное фиксируем
function Bot.record_drain()
  local queue = Bot.record.queue
  while #queue > 0 do
    local item = table.remove(queue, 1)
    Bot.warn("<orange>Ход «" .. tostring(item.dir) .. "» не подтвердился — не записан")
    Bot.record.drops = Bot.record.drops + 1
  end
  Bot.record_flush()
end

-- ход отклонён сервером ("Вы не можете идти…"): выбрасываем последний отправленный
function Bot.record_drop_last(dir)
  local queue = Bot.record.queue
  if #queue == 0 then return false end
  local item = table.remove(queue)
  Bot.warn("<orange>Ход «" .. tostring(dir or item.dir) ..
    "» отклонён сервером — не записан")
  Bot.record.drops = Bot.record.drops + 1
  if #queue == 0 then Bot.record_flush() end
  return true
end

-- Дверь на записи: ход НЕ выбрасываем. Профильный триггер (он и отпирает, и
-- открывает по переменной dir) откроет дверь, бот повторит ход, а подтверждение
-- по VNUM запишет шаг.
function Bot.record_retry(kind, door)
  local queue = Bot.record.queue
  local item = queue[#queue]
  if not item or not item.dir then return false end
  local dir = item.dir
  item.deadline = Bot.now() + (Bot.config.waitAfterMove or 3)
  Bot.warn("<cyan>[запись]<reset> " ..
    (kind == "заперто" and "дверь заперта" or "дверь закрыта") ..
    " («" .. tostring(door or "?") .. "») — повторяю ход «" .. dir .. "»")
  Bot.later(Bot.config.doorRetryDelay or 0.4, "повтор записи", function()
    if Bot.state ~= "record" then return end
    if Bot.record.queue[#Bot.record.queue] ~= item then return end
    -- sysDataSendRequest от повтора не должен добавить второй ход в очередь
    item.retry = true
    Bot.send(dir)
    item.retry = nil
  end)
  return true
end

-- перехват реально ушедших команд (событие sysDataSendRequest)
function Bot.record_on_send(cmd)
  Bot.lastSent = tostring(cmd or "")
  if Bot.state ~= "record" then return end
  local dir = Bot.dir_of(Bot.trim(cmd))
  if not dir then return end
  local last = Bot.record.queue[#Bot.record.queue]
  if last and last.retry and last.dir == dir then
    Bot.dbg("[record] повтор хода после двери — второй записи не нужно")
    return
  end
  Bot.record_move(dir)
end

-- ===================== управление прохождением =====================

Bot.queue = Bot.queue or {}         -- очередь зон после текущей
Bot.stats = Bot.stats or nil        -- статистика текущего прогона
Bot.entry = Bot.entry or nil        -- вход в текущую зону: { vnum, dir, maxdiff, num, title }
Bot.resume = Bot.resume or nil      -- точка остановки: { zone, entry, i } для .бот продолжить
Bot.entryTarget = Bot.entryTarget or nil
Bot.loop = Bot.loop or { list = {}, idx = 0, deleteAt = {} }
Bot.loop.deleteAt = Bot.loop.deleteAt or {}
Bot.circleDelete = nil

function Bot.copy_list(t)
  local r = {}
  for i = 1, #t do r[i] = t[i] end
  return r
end

function Bot.start(names)
  if Bot.state == "record" then
    Bot.warn("Идёт запись — сначала <yellow>.бот запись стоп")
    return
  end
  if type(names) == "string" then names = Bot.split(names) end
  if not names or #names == 0 then
    Bot.warn("Укажите зону: <yellow>.бот старт «зона»")
    return
  end
  if Bot.running() then
    for _, zone in ipairs(names) do
      Bot.queue[#Bot.queue + 1] = zone
      Bot.echo("В очередь добавлена зона <cyan>" .. zone)
    end
    return
  end
  Bot.queue = Bot.copy_list(names)
  Bot.resume = nil
  Bot.begin_zone(table.remove(Bot.queue, 1))
end

function Bot.begin_zone(name)
  -- всегда читаем актуальный файл: зону могли поправить руками
  local data, err = Bot.reload_zone(name)
  if not data then
    Bot.warn("Зона «" .. tostring(name) .. "»: " .. tostring(err))
    return Bot.next_zone()
  end
  if #data.steps == 0 then
    Bot.warn("Маршрут зоны «" .. tostring(name) .. "» пуст")
    return Bot.next_zone()
  end

  -- данные «обл» до старта зоны больше не актуальны: после прохода спросим заново
  Bot.instancesAt = 0
  Bot.circleDelete = nil
  Bot.zone = name
  Bot.route = data
  Bot.i = 1
  Bot.expect = nil
  Bot.deadline = 0
  Bot.waitUntil = 0
  Bot.paused = false
  Bot.doorAttempts = 0
  Bot.lookPending = nil
  Bot.set_room_fight(false)
  Bot.fightNoiseAt = 0
  Bot.recover = { step = 0, count = 0, fails = 0, queue = nil }
  Bot.stats = { zone = name, t0 = Bot.now(), money0 = Bot.money, kills = 0 }

  Bot.echo("<green>Бот включён: зона <cyan>" .. name .. "<reset> (" ..
    tostring(#data.steps) .. " шагов)")

  -- вход в зону: клетка перед ней + направление и макс. сложность для «гг !обл созда».
  -- Старые маршруты с transit = { vnum, portal } читаем как «только клетка».
  local entry = data.entry
  if not entry and data.transit then
    entry = { vnum = data.transit.vnum }
  end
  Bot.entry = entry
  Bot.entryDone = false
  Bot.entryDeadline = 0
  local cur = Bot.vnum()
  if entry and entry.vnum and tostring(entry.vnum) ~= cur then
    local on_map = getRoomIDbyHash and getRoomIDbyHash(tostring(entry.vnum)) or -1
    if not (on_map and on_map > 0) then
      Bot.warn("<orange>Клетка входа " .. tostring(entry.vnum) ..
        " не на карте — иду с текущей позиции")
    elseif MudMapper and MudMapper.goto_vnum then
      Bot.state = "transit"
      Bot.entryTarget = tostring(entry.vnum)
      Bot.deadline = Bot.now() + 300
      MudMapper.goto_vnum(tonumber(entry.vnum) or entry.vnum, "куп 2")
      Bot.echo("<green>Бегу к клетке входа <cyan>" .. tostring(entry.vnum) ..
        "<green> (MudMapper, куп 2)")
      if Bot.panelUpdate then Bot.panelUpdate() end
      return
    else
      Bot.warn("<orange>MudMapper недоступен — иду с текущей позиции")
    end
  end
  Bot.entry_begin()
end

-- сложность в «гг !обл созда»: +3; 0 — обычная сложность (аргумент не шлём)
function Bot.diff_arg(maxdiff)
  if maxdiff == nil then return "" end
  local s = tostring(maxdiff)
  if s == "" or tonumber(s) == 0 then return "" end
  local sign = s:sub(1, 1)
  if sign ~= "+" and sign ~= "-" then s = "+" .. s end
  return s
end

-- «Для создания области зоны 'X' сложности +2 вы должны 10 раз выполнить
-- задание в области сложности +1.» → 2, 10 (сложность и сколько заданий надо)
function Bot.parse_zone_diff_refused(line)
  local s = tostring(line or "")
  if not s:find("Для создания области зоны", 1, true) then return nil end
  local diff = s:match("сложности%s*%+(%d+)")
  if not diff and s:find("обычной сложности", 1, true) then diff = "0" end
  local times = s:match("вы должны.-(%d+)%s+раз")
  if not diff then return nil end
  return tonumber(diff), tonumber(times)
end

-- сервер отказал в сложности: пробуем следующую ниже (не трогая maxdiff зоны)
function Bot.on_zone_diff_refused(refused, times)
  if Bot.state ~= "entry" then return end
  local e = Bot.entry
  if not e or not e.dir then return end
  local min = tonumber(Bot.config.entryMinDiff) or 0
  local current = tonumber(refused) or tonumber(Bot.entryTryDiff) or
    tonumber(e.maxdiff) or min
  if Bot.entryTryDiff and tonumber(Bot.entryTryDiff) < current then
    current = tonumber(Bot.entryTryDiff)
  end
  Bot.entryTried = Bot.entryTried or {}
  local nextd = current - 1
  while nextd >= min and Bot.entryTried[nextd] do nextd = nextd - 1 end
  local current_label = (current == 0) and "обычная сложность"
    or ("сложность +" .. tostring(current))
  if nextd < min then
    return Bot.fail("не удалось создать область «" ..
      tostring(e.title or e.num or "?") .. "»: " .. current_label .. " недоступна" ..
      (times and (" (нужно " .. tostring(times) .. " раз выполнить задание)") or ""))
  end
  Bot.entryTryDiff = nextd
  Bot.entryTried[nextd] = true
  Bot.entryDeadline = Bot.now() + (Bot.config.entryWait or 5)
  local next_label = (nextd == 0) and "обычную сложность (без +N)"
    or ("+" .. tostring(nextd))
  Bot.warn("<orange>" ..
    ((current == 0) and "Обычная сложность" or ("Сложность +" .. tostring(current))) ..
    " недоступна" ..
    (times and (" (нужно " .. tostring(times) .. " раз выполнить задание)") or "") ..
    " — пробую " .. next_label)
  local cmd = "гг !обл созда " .. tostring(e.dir)
  if nextd > 0 then cmd = cmd .. " " .. Bot.diff_arg(nextd) end
  Bot.send(cmd)
end

-- фаза «вход»: создаём экземпляр зоны и ждём подтверждения
function Bot.entry_begin()
  local e = Bot.entry
  Bot.entryTarget = nil
  Bot.deadline = 0
  if e and e.dir and e.maxdiff and not Bot.entryDone then
    Bot.entryDone = true
    Bot.state = "entry"
    Bot.entryDeadline = Bot.now() + (Bot.config.entryWait or 5)
    Bot.entryTryDiff = tonumber(e.maxdiff) or 1
    Bot.entryTried = { [Bot.entryTryDiff] = true }
    local diff = Bot.diff_arg(Bot.entryTryDiff)
    local cmd = "гг !обл созда " .. tostring(e.dir)
    if diff ~= "" then cmd = cmd .. " " .. diff end
    Bot.send(cmd)
    Bot.echo("<green>Создаю экземпляр зоны: <reset>" .. cmd ..
      " <gray>([" .. tostring(e.num or "?") .. "] " .. tostring(e.title or "?") .. ")")
    if Bot.panelUpdate then Bot.panelUpdate() end
    return
  end
  Bot.walk_begin()
end

function Bot.walk_begin()
  Bot.entryTarget = nil
  Bot.entryDeadline = 0
  Bot.state = "walk"
  if Bot.walk and Bot.walk.begin then
    Bot.walk.begin()
  else
    Bot.warn("<red>BotWalk не загружен — проход невозможен")
    Bot.stop("нет BotWalk")
  end
  if Bot.panelUpdate then Bot.panelUpdate() end
end

function Bot.next_zone()
  local zone = table.remove(Bot.queue, 1)
  if zone then return Bot.begin_zone(zone) end
  return nil
end

function Bot.stop(reason)
  local was = Bot.state
  -- точка продолжения: запоминаем до очистки маршрута
  if Bot.route and Bot.zone and (tonumber(Bot.i) or 0) > 0 then
    Bot.resume = {
      zone = Bot.zone,
      entry = Bot.entry,
      i = tonumber(Bot.i) or 1,
    }
  end
  Bot.state = "idle"
  Bot.expect = nil
  Bot.deadline = 0
  Bot.waitUntil = 0
  Bot.lookPending = nil
  Bot.set_room_fight(false)
  Bot.fightNoiseAt = 0
  Bot.entryTarget = nil
  Bot.entryDeadline = 0
  Bot.entryDone = false
  Bot.entry = nil
  Bot.jump = nil
  Bot.jumpCounts = nil
  Bot.circleDelete = nil
  Bot.hold = nil
  Bot.holdWarned = nil
  Bot.final_i = nil
  Bot.trigger = nil
  if Bot.route then Bot.stats_log() end
  Bot.route = nil
  Bot.i = 0
  Bot.echo("<yellow>Бот остановлен" ..
    (reason and (" (" .. tostring(reason) .. ")") or "") ..
    (was ~= "idle" and "" or " — он и не работал"))
  if Bot.resume then
    Bot.echo("<gray>  продолжить: <yellow>.бот продолжить<gray> (" ..
      tostring(Bot.resume.zone) .. ", шаг " .. tostring(Bot.resume.i) .. ")")
  end
  if Bot.loop and #Bot.loop.list > 0 then
    Bot.echo("<gray>  круг остался: <yellow>.бот круг стоп<gray> (или ждать следующего тика)")
  end
  if Bot.panelUpdate then Bot.panelUpdate() end
end

-- продолжить остановленную зону с сохранённого шага
function Bot.resume_continue()
  if Bot.state == "record" then
    Bot.warn("Идёт запись — сначала <yellow>.бот запись стоп")
    return
  end
  if Bot.running() then
    Bot.warn("Бот уже идёт: <yellow>.бот стоп")
    return
  end
  local r = Bot.resume
  if not r or not r.zone then
    Bot.warn("Нет сохранённой точки. <yellow>.бот стоп<reset> во время прохода " ..
      "запоминает шаг; начать заново: <yellow>.бот старт «зона»")
    return
  end
  local route = Bot.reload_zone(r.zone) or r.route
  if not route or type(route.steps) ~= "table" then
    Bot.warn("Зона «" .. tostring(r.zone) .. "» не читается — продолжение отменено")
    return
  end

  local i = math.max(1, math.min(tonumber(r.i) or 1, #route.steps + 1))
  local vnum = tostring(Bot.vnum() or "")
  local function same(room)
    return room ~= nil and vnum ~= "" and tostring(room) == vnum
  end

  if vnum ~= "" then
    local before = (i > 1 and route.steps[i - 1] and route.steps[i - 1].room)
      or (r.entry and r.entry.vnum)
    if not same(before) then
      if route.steps[i] and same(route.steps[i].room) then
        i = i + 1
      else
        local idx
        for j = i, #route.steps do
          if same(route.steps[j].room) then idx = j break end
        end
        if not idx then
          for j = i - 1, 1, -1 do
            if same(route.steps[j].room) then idx = j break end
          end
        end
        if not idx then
          Bot.warn("<orange>Не нашёл комнату " .. tostring(vnum) ..
            " в маршруте «" .. tostring(r.zone) ..
            "» — продолжение отменено (точка сохранена)")
          return
        end
        i = idx + 1
      end
    end
  end

  Bot.resume = nil
  Bot.zone = r.zone
  Bot.route = route
  Bot.entry = r.entry
  Bot.entryDone = true          -- экземпляр зоны уже создан, «!обл созда» не шлём
  Bot.i = i
  Bot.paused = false
  Bot.expect, Bot.awaiting = nil, false
  Bot.deadline, Bot.waitUntil = 0, 0
  Bot.lookPending = nil
  Bot.set_room_fight(false)
  Bot.fightNoiseAt = 0
  Bot.recover = { step = 0, count = 0, fails = 0, queue = nil }
  Bot.walk_repair = nil
  Bot.doorAttempts = 0
  Bot.lastFail = ""
  Bot.stats = { zone = r.zone, t0 = Bot.now(), money0 = Bot.money, kills = 0 }
  Bot.echo("<green>Продолжаю зону <cyan>" .. tostring(r.zone) ..
    "<green> с шага <yellow>" .. tostring(i) .. "<green> (комната <cyan>" ..
    tostring(vnum) .. "<green>)")
  if Bot.panelUpdate then Bot.panelUpdate() end
  return Bot.walk_begin()
end

function Bot.fail(reason)
  Bot.lastFail = tostring(reason or "")
  Bot.warn("<red>Стоп: " .. tostring(reason))
  Bot.stop(reason)
end

function Bot.finish_zone(reason)
  local zone = Bot.zone
  Bot.state = "idle"
  Bot.expect = nil
  Bot.deadline = 0
  Bot.echo("<green>Зона <cyan>" .. tostring(zone) .. "<green> закончена" ..
    (reason and (" (" .. tostring(reason) .. ")") or ""))
  Bot.stats_log()
  Bot.zone = nil
  Bot.route = nil
  Bot.i = 0
  Bot.resume = nil
  Bot.final_i = nil

  -- объединённый круг сам решает, кого запускать (пропускает кулдауны)
  if Bot.circle_step() then return end
  if Bot.next_zone() then return end
  if Bot.panelUpdate then Bot.panelUpdate() end
end

function Bot.wait(sec)
  sec = tonumber(sec) or 1
  Bot.waitUntil = Bot.now() + sec
  if Bot.panelUpdate then Bot.panelUpdate() end
end

-- ===================== отдых и безопасность =====================

-- сколько выносливости надо набрать, чтобы идти дальше
function Bot.rest_target()
  local above = tonumber(Bot.config.restAbove) or 0
  if above > 0 and above <= 1 and (Bot.mvMax or 0) > 0 then
    return math.floor(Bot.mvMax * above)
  end
  return tonumber(Bot.config.restBelow) or 0
end

function Bot.needs_rest()
  local below = tonumber(Bot.config.restBelow) or 0
  if below <= 0 then return false end
  if (Bot.mv or 0) <= 0 then return false end   -- MSDP ещё не пришёл
  return Bot.mv < below
end

function Bot.rest_start()
  if Bot.rest.active then return end
  Bot.rest.active = true
  Bot.rest.started = Bot.now()
  Bot.echo("<yellow>Отдыхаю: выносливость " .. tostring(Bot.mv) ..
    " < " .. tostring(Bot.config.restBelow) ..
    " (цель " .. tostring(Bot.rest_target()) .. ")")
  Bot.send("отдых")
  Bot.wait(2)
end

-- true, пока отдыхаем (маршрут стоит на паузе)
function Bot.rest_tick()
  if not Bot.rest.active then return false end
  local target = Bot.rest_target()
  local timeout = tonumber(Bot.config.restTimeout) or 300
  if (Bot.mv or 0) >= target then
    Bot.rest.active = false
    Bot.echo("<green>Отдых закончен: выносливость " .. tostring(Bot.mv))
    if Bot.config.standAfterRest and Bot.config.standAfterRest ~= "" then
      Bot.send(Bot.config.standAfterRest)
    end
    Bot.wait(1)
    return false
  end
  if Bot.now() - (Bot.rest.started or 0) > timeout then
    Bot.rest.active = false
    Bot.warn("<orange>Отдых не дал выносливости за " .. tostring(timeout) .. "с")
    return false
  end
  return true
end

-- HP ниже заданной доли от максимума
function Bot.hp_critical()
  local share = tonumber(Bot.config.lowHpPercent) or 0
  if share <= 0 or (Bot.hpMax or 0) <= 0 then return false end
  return (Bot.hp or 0) < Bot.hpMax * share
end

-- ===================== статистика =====================

function Bot.stats_log()
  local s = Bot.stats
  if not s then return end
  Bot.stats = nil
  local dur = math.floor(Bot.now() - (s.t0 or Bot.now()))
  local money = math.floor((Bot.money or 0) - (s.money0 or 0))
  local line = string.format("%s;%s;%d;%d;%d;%s",
    os.date("%Y-%m-%d %H:%M:%S"), tostring(s.zone), dur, money,
    math.floor(tonumber(s.kills) or 0), tostring(Bot.lastFail or ""))
  Bot.ensure_dir(Bot.base_dir())
  local f = io.open(Bot.base_dir() .. "/stats.csv", "a")
  if f then
    f:write(line .. "\n")
    f:close()
  end
  local mins = math.floor(dur / 60)
  local secs = math.floor(dur - mins * 60)
  Bot.echo("<gray>Итог зоны <cyan>" .. tostring(s.zone) .. "<gray>: " ..
    tostring(mins) .. "м " .. tostring(secs) .. "с, монет " .. tostring(money) ..
    ", боёв " .. tostring(tonumber(s.kills) or 0))
end

-- ===================== данные «обл» =====================

Bot.instances = Bot.instances or {}   -- разобранный ответ «обл»: [имя] = {...}
Bot.instancesAt = Bot.instancesAt or 0
Bot.instanceQuery = Bot.instanceQuery or nil
Bot.instance_probe = Bot.instance_probe or { open = false, ignore = false, cols = nil, rows = 0 }

-- "Создан экземпляр зоны X." — зона заселена, сбрасываем данные «обл»
function Bot.on_zone_spawn(name)
  name = Bot.trim(name)
  if name == "" then return end
  -- заселённая зона теперь активна: данные «обл» устарели
  Bot.instancesAt = 0
  if Bot.state == "entry" then
    Bot.entryDeadline = 0
    Bot.echo("<green>Зона создана: <cyan>" .. name .. "<green>, начинаю проход")
    Bot.walk_begin()
    return
  end
end

-- ===================== круг зон с проверкой «обл» =====================

function Bot.circle_start(zone)
  Bot.echo("<green>Круг: иду <cyan>" .. tostring(zone))
  Bot.begin_zone(zone)
  return true
end

-- «обл» не ответил: идём в следующую зону без проверки кулдаунов
function Bot.circle_fallback()
  local L = Bot.loop
  if not L or #L.list == 0 then return false end
  if Bot.paused then return false end
  local pos = (L.idx % #L.list) + 1
  L.idx = pos
  Bot.warn("<orange>Нет ответа на «обл» — иду по кругу без проверки кулдаунов")
  return Bot.circle_start(L.list[pos])
end

-- следующая доступная зона: активные пропускаем, «вручную» удаляем
function Bot.circle_step()
  local L = Bot.loop
  if not L or #L.list == 0 then return false end
  if Bot.paused then return false end
  if Bot.running() then return false end

  if Bot.circleDelete then
    if Bot.now() < (Bot.circleDelete.at or 0) then return false end
    Bot.circleDelete = nil
    if not Bot.instanceQuery then Bot.instance_query("circle") end
    return false
  end

  local use = Bot.config.repopUseInstances
  local fresh = (Bot.instancesAt or 0) > 0 and
    (Bot.now() - Bot.instancesAt) <= (Bot.config.repopTick or 60)
  if use and not fresh and not Bot.instanceQuery then
    Bot.instance_query("circle")
    return false
  end
  if Bot.instanceQuery then return false end

  local n = #L.list
  for k = 1, n do
    local pos = (L.idx + k - 1) % n + 1
    local zone = L.list[pos]
    local inst = use and Bot.instance_for(zone) or nil
    if not inst then
      L.idx = pos
      return Bot.circle_start(zone)
    elseif inst.manual then
      local last = (L.deleteAt and L.deleteAt[zone]) or 0
      if Bot.now() - last >= (Bot.config.circleDeleteCooldown or 600) then
        local data = Bot.zone_data(zone)
        local dir = data and data.entry and data.entry.dir
        if dir then
          local cmd = "обл удалить " .. tostring(dir)
          Bot.warn("<orange>Экземпляр «" .. tostring(zone) ..
            "» висит (удалите вручную) — выполняю " .. cmd)
          if not Bot.send(cmd) then
            Bot.warn("<orange>Команда удаления не отправлена — повторю позже")
            return false
          end
          L.deleteAt = L.deleteAt or {}
          L.deleteAt[zone] = Bot.now()
          Bot.circleDelete = { zone = zone, dir = dir,
            at = Bot.now() + (Bot.config.circleDeleteWait or 2) }
          Bot.later(Bot.config.circleDeleteWait or 2, "круг удаление", function()
            if Bot.circleDelete and Bot.circleDelete.zone == zone then
              Bot.circleDelete = nil
              if not Bot.running() and not Bot.instanceQuery then
                Bot.instance_query("circle")
              end
            end
          end)
          return false
        end
        Bot.warn("<orange>«" .. tostring(zone) ..
          "»: нет entry.dir — не могу удалить экземпляр, пропускаю")
      end
    end
  end
  Bot.dbg("[circle] все зоны заняты/на кулдауне — жду")
  return false
end

function Bot.circle_tick()
  local L = Bot.loop
  if not L or #L.list == 0 then return end
  if Bot.running() then return end
  if Bot.paused then return end
  -- раз в repopTick спрашиваем «обл» заново, даже если данные ещё свежие
  if Bot.config.repopUseInstances and not Bot.instanceQuery then
    Bot.instance_query("circle")
    return
  end
  Bot.circle_step()
end

function Bot.circle_info()
  if not Bot.loop or #Bot.loop.list == 0 then
    Bot.echo("Круг пуст. Пример: <yellow>.бот круг тоннель_бесов башня_магов")
    return
  end
  Bot.echo("<green>Круг зон:")
  local fresh = (Bot.instancesAt or 0) > 0 and
    (Bot.now() - Bot.instancesAt) <= (Bot.config.repopTick or 60) * 2
  for i, zone in ipairs(Bot.loop.list) do
    local inst = fresh and Bot.instance_for(zone) or nil
    local status
    if not fresh then
      status = "<gray>нет данных «обл»"
    elseif not inst then
      status = "<green>свободна — можно идти"
    elseif inst.manual then
      status = "<orange>удалите вручную (обл удалить <направление>)"
    elseif inst.seconds then
      status = "<yellow>кулдаун, до репопа " .. Bot.secs_desc(inst.seconds)
    else
      status = "<yellow>активна"
    end
    Bot.echo(string.format("<gray>%2d. <cyan>%-28s<reset> %s", i, zone, status))
  end
end

-- ===================== команды ".бот ..." =====================

function Bot.help()
  Bot.echo("<green>[Бот v.1 — Mudlet]")
  Bot.echo("<gray>  .бот ?                        <reset>- эта справка")
  Bot.echo("<gray>  .бот старт «зона» [зона2...] <reset>- идти зону (бег к входу + «!обл созда»)")
  Bot.echo("<gray>  .бот стоп                     <reset>- остановить бота")
  Bot.echo("<gray>  .бот продолжить                <reset>- продолжить с сохранённого шага")
  Bot.echo("<gray>  .бот пауза 0|1                <reset>- снять/поставить паузу")
  Bot.echo("<gray>  .бот запись старт «зона» [список] <reset>- запись; «список» — бить только цели")
  Bot.echo("<gray>  .бот запись стоп              <reset>- сохранить маршрут в файл")
  Bot.echo("<gray>  .бот запись сброс             <reset>- выбросить запись")
  Bot.echo("<gray>  .бот запись вход [+ «напр» «слож»] <reset>- вход: клетка/направление/сложность")
  Bot.echo("<gray>  .бот круг «зона1» ...        <reset>- задать список и ходить, пропуская кулдауны")
  Bot.echo("<gray>  .бот круг + «зона» ...       <reset>- добавить зону в круг")
  Bot.echo("<gray>  .бот круг - «зона» ...       <reset>- убрать зону из круга")
  Bot.echo("<gray>  .бот круг                     <reset>- статус круга (из «обл»)")
  Bot.echo("<gray>  .бот круг стоп                <reset>- остановить круг")
  Bot.echo("<gray>  .бот перезагрузить [зона]     <reset>- перечитать файл зоны с диска")
  Bot.echo("<gray>  .бот зоны                     <reset>- записанные маршруты (локальные файлы)")
  Bot.echo("<gray>  .бот обл                      <reset>- экземпляры зон и таймеры репопа («обл»)")
  Bot.echo("<gray>  .бот маршрут [зона]           <reset>- сводка по маршруту")
  Bot.echo("<gray>  .бот цель                     <reset>- существа в комнате и номера для боя")
  Bot.echo("<gray>  .бот небить [сброс]           <reset>- не бить это существо / снять список комнаты")
  Bot.echo("<gray>  .бот режим [зона] все|список <reset>- тип зоны: бить всех или только цели")
  Bot.echo("<gray>  .бот атака [режим]            <reset>- способ атаки (дефолт: botkill)")
  Bot.echo("<gray>  .бот бить                      <reset>- ударить сейчас (в list-зоне — запомнить цель)")
  Bot.echo("<gray>  .бот debug / dry              <reset>- отладка / без отправки")
  Bot.echo("<gray>  .триг «команда»               <reset>- действие в комнате (при записи)")
  Bot.echo("<gray>  .пауза «сек»                  <reset>- ожидание в маршруте (при записи)")
end

-- ===================== способ атаки =====================
-- Бот бьёт по НОМЕРУ существа, а не по имени: в комнате ты №1, дальше
-- согрупники, петы и только потом мобы, которые были здесь до нас
-- (новый вошедший становится первым, остальные сдвигаются). Поэтому первый
-- «до-наш» моб — group_count + pet_count + 1; ровно это считает getTargets()
-- в профиле (autoAttack.lua). Имена мобов боту не нужны.
--
-- По умолчанию атака = алиас botkill (в нём sendWithClear(getAttack())).
-- Другой способ задаётся командой «.бот атака» или файлом bot/attack.lua:
--   return { mode = "botkill" }                          -- дефолт
--   return { mode = "alias",   alias = "мойбой" }        -- свой алиас
--   return { mode = "command", template = "убить %n" }   -- %n = номер цели
--   return { mode = "lua",     code = "sendWithClear(getAttack())" }

Bot.attack = Bot.attack or { mode = "botkill", alias = "botkill" }

Bot.attack_modes = { botkill = true, alias = true, command = true, lua = true }

function Bot.attack_path()
  return Bot.base_dir() .. "/attack.lua"
end

function Bot.attack_default()
  return { mode = "botkill", alias = "botkill" }
end

-- сколько существ идёт до первого моба: я + согрупники + петы
function Bot.target_offset()
  local g = tonumber(rawget(_G, "group_count")) or 0
  if g < 1 then g = 1 end          -- группа всегда включает меня
  local pets = tonumber(rawget(_G, "pet_count")) or 0
  if pets < 0 then pets = 0 end
  return g + pets
end

-- номер k-го моба (k = 1 — первый моб, который был в комнате до нас)
function Bot.target_number(k)
  return Bot.target_offset() + (tonumber(k) or 1)
end

-- человекочитаемое описание способа атаки
function Bot.attack_desc(n)
  n = tonumber(n) or Bot.target_number(1)
  local cfg = Bot.attack or Bot.attack_default()
  local mode = cfg.mode or "botkill"
  if mode == "command" then
    local cmd = tostring(cfg.template or "убить %n"):gsub("%%n", tostring(n))
    return "команда «" .. cmd .. "»"
  elseif mode == "lua" then
    return "lua: " .. tostring(cfg.code or "")
  elseif mode == "alias" then
    return "алиас «" .. tostring(cfg.alias or "") .. "»"
  end
  return "botkill → алиас «" .. tostring(cfg.alias or "botkill") ..
    "» (sendWithClear(getAttack()))"
end

function Bot.load_attack()
  Bot.attack = Bot.attack_default()
  local path = Bot.attack_path()
  local f = io.open(path, "rb")
  if not f then return end
  local src = f:read("*a")
  f:close()
  local chunk, err = chunk_load(src, "@" .. path)
  if not chunk then
    Bot.warn("<orange>attack.lua: " .. tostring(err))
    return
  end
  local ok, data = pcall(chunk)
  if not (ok and type(data) == "table") then
    Bot.warn('<orange>attack.lua: ожидался return { mode = "botkill" | "alias" | "command" | "lua", ... }')
    return
  end
  local mode = tostring(data.mode or "")
  if not Bot.attack_modes[mode] then
    Bot.warn("<orange>attack.lua: неизвестный mode «" .. mode .. "» — остаётся botkill")
    return
  end
  local cfg = { mode = mode }
  if mode == "botkill" or mode == "alias" then
    local alias = Bot.trim(data.alias or (mode == "botkill" and "botkill" or ""))
    if alias == "" then
      Bot.warn("<orange>attack.lua: для mode «" .. mode .. "» нужен alias — остаётся botkill")
      return
    end
    cfg.alias = alias
  elseif mode == "command" then
    local tmpl = Bot.trim(data.template or "")
    if tmpl == "" then
      Bot.warn("<orange>attack.lua: для mode command нужен template — остаётся botkill")
      return
    end
    cfg.template = tmpl
  else
    local code = tostring(data.code or "")
    if Bot.trim(code) == "" then
      Bot.warn("<orange>attack.lua: для mode lua нужен code — остаётся botkill")
      return
    end
    local loader = loadstring or load
    local fn, code_err = loader("local Bot, target = ...; " .. code, "=bot/attack.lua")
    if not fn then
      Bot.warn("<orange>attack.lua: код не компилируется: " .. tostring(code_err))
      return
    end
    cfg.code = code
  end
  Bot.attack = cfg
  Bot.dbg("[атака] " .. tostring(Bot.attack_desc()))
end

function Bot.save_attack()
  Bot.ensure_dir(Bot.base_dir())
  local path = Bot.attack_path()
  local cfg = Bot.attack or Bot.attack_default()
  local mode = cfg.mode or "botkill"
  local f, err = io.open(path, "wb")
  if not f then
    Bot.warn("<orange>не смог записать " .. path .. ": " .. tostring(err))
    return false
  end
  f:write("-- способ атаки бота (правится руками или командой .бот атака)\n")
  f:write('--   { mode = "botkill" }                        -- дефолт: expandAlias("botkill")\n')
  f:write('--   { mode = "alias",   alias = "мойбой" }      -- любой свой алиас\n')
  f:write('--   { mode = "command", template = "убить %n" } -- %n = group_count+pet_count+1\n')
  f:write('--   { mode = "lua",     code = "sendWithClear(getAttack())" } -- доступны Bot, target\n')
  f:write("return {\n")
  f:write("  mode = " .. string.format("%q", mode) .. ",\n")
  if mode == "command" then
    f:write("  template = " .. string.format("%q", cfg.template or "убить %n") .. ",\n")
  elseif mode == "lua" then
    f:write("  code = " .. string.format("%q", cfg.code or "") .. ",\n")
  else
    f:write("  alias = " .. string.format("%q", cfg.alias or "botkill") .. ",\n")
  end
  f:write("}\n")
  f:close()
  return true
end

-- одна атака текущим способом; n — номер цели.
-- Возвращает true и описание того, что ушло (для лога), либо false.
function Bot.attack_do(n)
  n = tonumber(n) or Bot.target_number(1)
  local cfg = Bot.attack or Bot.attack_default()
  local mode = cfg.mode or "botkill"

  if Bot.paused then
    Bot.dbg("[атака] бот на паузе — команда не отправлена")
    return false
  end

  if Bot.config.dry then
    Bot.echo("[dry] атака " .. Bot.attack_desc(n))
    return true, "dry"
  end

  if Bot.blocked_by_antibot and Bot.blocked_by_antibot() then
    Bot.paused = true
    Bot.warn("<orange>Проверка на бота — бот приостановлен. Снять: .бот пауза 0")
    return false
  end

  -- «очистить» + антибот-логика профиля, если функции есть; иначе обычная отправка
  local function send_clear(cmd)
    local clear_fn = rawget(_G, "sendWithClear")
    if type(clear_fn) == "function" then
      clear_fn(cmd)
      return true, cmd
    end
    if Bot.send(cmd) then return true, cmd end
    return false
  end

  if mode == "command" then
    local cmd = tostring(cfg.template or ""):gsub("%%n", tostring(n))
    return send_clear(cmd)
  end

  if mode == "lua" then
    local loader = loadstring or load
    local chunk, err = loader("local Bot, target = ...; " .. tostring(cfg.code or ""), "=bot/attack.lua")
    if not chunk then
      Bot.warn("<orange>атака lua: " .. tostring(err))
      return false
    end
    local ok, run_err = pcall(chunk, Bot, n)
    if not ok then
      Bot.warn("<orange>атака lua: " .. tostring(run_err))
      return false
    end
    return true, "lua"
  end

  local alias = Bot.trim(cfg.alias or (mode == "botkill" and "botkill" or ""))
  if alias == "" then alias = "botkill" end
  local exists_fn = rawget(_G, "exists")
  local expand_fn = rawget(_G, "expandAlias")
  if type(expand_fn) == "function" and
     (type(exists_fn) ~= "function" or exists_fn(alias, "alias") > 0) then
    Bot._attackSent = nil
    expand_fn(alias)
    -- алиас может сообщить, что ничего не отправил (пустой getAttack/антибот)
    if Bot._attackSent == false then return false end
    return true, "алиас «" .. alias .. "»"
  end

  -- алиаса нет: простой запасной вариант по номеру
  local cmd = "kill " .. tostring(n)
  Bot.warn("<orange>алиас «" .. alias .. "» не найден — отправляю " .. cmd)
  return send_clear(cmd)
end

-- обороты, с которых начинается описание существа: имя стоит ДО них.
-- «Личный телохранитель короля стоит здесь, сражается с Съезо!» — это моб,
-- хотя в строке упомянут игрок Съезо.
Bot.mob_verb_markers = {
  " стоит", " летает", " сидит", " лежит", " парит", " блуждает", " беседует",
  " шепчет", " заваривает", " сражается", " спит", " ждет", " ждёт", " охраняет",
  " точит", " щиплет", " перебирает", " показывает", " идет", " идёт", " бродит",
  " кружит", " пляшет", " служит", " пытался", " пыталась", " ударил", " ударила",
}

-- «имя» строки комнаты: текст до первого глагола-маркера
function Bot.line_head(line)
  local s = Bot.strip_mob_markers(line or "")
  local cut = #s
  for _, marker in ipairs(Bot.mob_verb_markers) do
    local at = s:find(marker, 1, true)
    if at and at > 1 and (at - 1) < cut then cut = at - 1 end
  end
  return s:sub(1, cut)
end

-- ключ существа для списков зоны: «имя» до глагола. Если известного глагола в
-- строке нет, режем по первому слову со строчной буквы («Ученик магов бормочет
-- заклинание.» → «Ученик магов»), иначе ключ прыгал бы вместе с описанием.
function Bot.first_lower_word(s)
  s = tostring(s or "")
  local i, n, prev, spaces = 1, #s, nil, 0
  while i <= n do
    local b = s:byte(i)
    local len = 1
    if b >= 240 then len = 4 elseif b >= 224 then len = 3 elseif b >= 192 then len = 2 end
    local b2 = i + 1 <= n and s:byte(i + 1) or nil
    local is_lower = (b == 0xD0 and b2 and b2 >= 0xB0 and b2 <= 0xBF) or
      (b == 0xD1 and b2 and b2 >= 0x80 and b2 <= 0x8F)
    -- первые два слова — имя («Ученик магов»), глагол ищем начиная с третьего
    if is_lower and prev == 0x20 and spaces >= 2 then return i end
    if b == 0x20 then spaces = spaces + 1 end
    prev = s:byte(i + len - 1)
    i = i + len
  end
end

function Bot.mob_key(line)
  local head = Bot.trim(Bot.line_head(line or ""))
  local full = Bot.trim(Bot.strip_mob_markers(line or ""))
  if head ~= full then return head end
  local at = Bot.first_lower_word(head)
  if at and at > 2 then
    return (Bot.trim(head:sub(1, at - 1)):gsub("[,;:]+$", ""))
  end
  return head
end

-- нижний регистр для русских букв: string.lower() в Lua трогает только ASCII.
-- UTF-8: А-П (D0 90..9F) → а-п (D0 B0..BF); Р-Я (D0 A0..AF) → р-я (D1 80..8F);
-- Ё (D0 81) → ё (D1 91). Остальные последовательности не меняем.
function Bot.fold(s)
  s = tostring(s or "")
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = s:byte(i)
    if b == 0xD0 and i + 1 <= n then
      local b2 = s:byte(i + 1)
      if b2 >= 0x90 and b2 <= 0x9F then
        out[#out + 1] = string.char(0xD0, b2 + 0x20)
      elseif b2 == 0x81 then
        out[#out + 1] = string.char(0xD1, 0x91)
      elseif b2 >= 0xA0 and b2 <= 0xAF then
        out[#out + 1] = string.char(0xD1, b2 - 0x20)
      else
        out[#out + 1] = s:sub(i, i + 1)
      end
      i = i + 2
    else
      out[#out + 1] = string.sub(s, i, i):lower()
      i = i + 1
    end
  end
  return table.concat(out)
end

-- защищено ли существо: игрок из assist_who или согрупник.
-- Имя игрока ищем только в «имени» строки (до глагола): упоминание игрока в
-- «... сражается с Съезо!» не значит, что само существо — игрок.
function Bot.is_protected(line)
  return Bot.assist_contains(Bot.line_head(line))
end

-- ===================== assist_who: игроки =====================
-- В профиле есть глобальная таблица assist_who: [имя] = имя — это ИГРОКИ
-- (в комнате они видны как «раса/титул + имя»: «Пещерный тролль Кофл» —
-- игрок Кофл). Их не бьём и считаем «в комнате игрок».

local function is_word_byte(b)
  if not b then return false end
  return b >= 128 or (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
end

-- входит ли слово в текст как отдельное (регистр русских букв не важен)
function Bot.has_word(text, word)
  text, word = Bot.fold(text), Bot.fold(word)
  if text == "" or word == "" then return false end
  local from = 1
  while true do
    local s, e = text:find(word, from, true)
    if not s then return false end
    local before = s > 1 and text:byte(s - 1) or nil
    local after = e < #text and text:byte(e + 1) or nil
    if not is_word_byte(before) and not is_word_byte(after) then return true end
    from = e + 1
  end
end

-- входит ли какое-то имя из assist_who в текст как отдельное слово
function Bot.assist_contains(text)
  local list = rawget(_G, "assist_who")
  if type(list) ~= "table" or text == nil then return false end
  text = tostring(text)
  if text == "" then return false end
  for raw_name in pairs(list) do
    local name = tostring(raw_name)
    if #name >= 2 then
      local from = 1
      while true do
        local s, e = text:find(name, from, true)
        if not s then break end
        local before = s > 1 and text:byte(s - 1) or nil
        local after = e < #text and text:byte(e + 1) or nil
        if not is_word_byte(before) and not is_word_byte(after) then return true end
        from = e + 1
      end
    end
  end
  return false
end

-- сколько имён сейчас в assist_who (для .бот цель)
function Bot.assist_count()
  local list = rawget(_G, "assist_who")
  if type(list) ~= "table" then return 0 end
  return Bot.count(list)
end

-- ===================== правила зоны: режим, цели, агрессоры =====================
-- Файл зоны:
--   mode = "all" | "list"        (по умолчанию all — бьём всё, кроме «не бить»)
--   kill  = { [«имя»] = true }   — цели в режиме list (ключ — Bot.mob_key)
--   aggro = { [«имя»] = true }   — агрессоры: бьём всегда, даже в list
--   noattack = { [vnume] = { [«имя»] = true } }
-- Имена храним как «имя до глагола» и сравниваем без регистра: короткое имя из
-- промпта («Маленький зайчик») находит строку «Маленький зайчик щиплет травку.».

Bot.rulesCache = Bot.rulesCache or {}
Bot.empty_rules = { mode = "all", kill = {}, aggro = {}, noattack = {} }

function Bot.zone_rules(zone)
  zone = zone or Bot.zone
  if not zone then return Bot.empty_rules end
  local cached = Bot.rulesCache[zone]
  if cached then return cached end
  local data = Bot.zones[zone]
  local R = {
    zone = zone,
    mode = (data and data.mode == "list") and "list" or "all",
    kill = (data and data.kill) or {},
    aggro = (data and data.aggro) or {},
    noattack = (data and data.noattack) or {},
  }
  Bot.rulesCache[zone] = R
  return R
end

function Bot.invalidate_rules(zone)
  zone = zone or Bot.zone
  if zone then Bot.rulesCache[zone] = nil end
end

function Bot.save_zone_rules(zone)
  zone = zone or Bot.zone
  local data = zone and Bot.zones[zone]
  if not data then return false end
  Bot.invalidate_rules(zone)
  return Bot.save_zone(zone, data)
end

-- есть ли имя в наборе зоны: точно или как отдельное слово в строке
function Bot.name_in(set, name)
  if type(set) ~= "table" or name == nil then return false end
  name = Bot.trim(tostring(name))
  if name == "" then return false end
  if set[name] then return true end
  for key, value in pairs(set) do
    if value then
      local stored = tostring(key)
      if stored == name or Bot.has_word(name, stored) or Bot.has_word(stored, name) then
        return true
      end
    end
  end
  return false
end

-- цель ли существо строки: в all — любое, в list — только kill ∪ aggro
function Bot.rule_target(line)
  local R = Bot.zone_rules()
  if R.mode ~= "list" then return true end
  local key = Bot.mob_key(line)
  if key == "" then return false end
  if Bot.name_in(R.kill, key) or Bot.name_in(R.aggro, key) then return true end
  -- добавки/агрессоры, известные только коротким именем из промпта
  if Bot.battle and Bot.target and Bot.target ~= "" and
     (Bot.has_word(key, Bot.target) or Bot.has_word(Bot.target, key)) then
    return true
  end
  return false
end

function Bot.rule_noattack(line, room)
  local R = Bot.zone_rules()
  local key = Bot.mob_key(line)
  local set = R.noattack[tostring(room or Bot.vnum())]
  if not set then return false end
  if set[key] or set[tostring(line)] then return true end
  for stored, value in pairs(set) do
    if value then
      -- в файле может лежать и полная строка, и «имя до глагола»
      local name = Bot.mob_key(stored)
      if name == key or Bot.has_word(key, name) or Bot.has_word(name, key) then
        return true
      end
    end
  end
  return false
end

-- «Маленький зайчик напал на вас!» → «Маленький зайчик»
Bot.aggro_markers = {
  " напал", " атаковал", " набросил", " бросил", " кинул", " рванул", " ударил",
}

function Bot.aggro_name(line)
  local s = Bot.trim(line or "")
  if #s < 8 then return nil end
  local low = Bot.fold(s)
  local cut
  for _, marker in ipairs(Bot.aggro_markers) do
    local at = low:find(Bot.fold(marker), 1, true)
    if at and at > 1 and (not cut or at < cut) then cut = at end
  end
  if not cut then return nil end
  -- событие должно быть про нас: после глагола встречается «вас»
  if not low:find("вас", cut, true) then return nil end
  local name = Bot.trim(s:sub(1, cut - 1))
  if name == "" or name == "Вы" or name == "вы" then return nil end
  return name
end

-- цель, помеченная вручную (.бот бить): в запись или в kill текущей зоны
function Bot.mark_kill(line)
  local key = Bot.mob_key(line)
  if key == "" then return false, "пусто" end
  if Bot.state == "record" and Bot.record.name then
    Bot.record.kill = Bot.record.kill or {}
    if Bot.record.kill[key] then return false, "уже" end
    Bot.record.kill[key] = true
    Bot.echo("<cyan>[запись]<reset> цель: <yellow>" .. key ..
      "<gray> (в списке " .. tostring(Bot.count(Bot.record.kill)) .. ")")
    return true, "record"
  end
  local zone = Bot.zone
  local data = zone and Bot.zones[zone]
  if not data then return false, "нет зоны" end
  if Bot.zone_rules(zone).mode ~= "list" then return false, "all" end
  data.kill = data.kill or {}
  if data.kill[key] then return false, "уже" end
  data.kill[key] = true
  Bot.save_zone_rules(zone)
  Bot.echo("<green>Цель зоны <cyan>" .. zone .. "<green>: <reset>" .. key ..
    "<gray> (всего " .. tostring(Bot.count(data.kill)) .. ")")
  return true, "zone"
end

function Bot.mark_aggro(name)
  local key = Bot.mob_key(name)
  if key == "" or Bot.is_protected(key) then return false end
  if Bot.state == "record" and Bot.record.name then
    if (Bot.record.mode or "all") ~= "list" then return false end
    Bot.record.aggro = Bot.record.aggro or {}
    if Bot.name_in(Bot.record.aggro, key) or Bot.name_in(Bot.record.kill, key) then
      return false
    end
    Bot.record.aggro[key] = true
    return true
  end
  local zone = Bot.zone
  local data = zone and Bot.zones[zone]
  if not data then return false end
  local R = Bot.zone_rules(zone)
  if R.mode ~= "list" then return false end
  if Bot.name_in(R.aggro, key) or Bot.name_in(R.kill, key) then return false end
  data.aggro = data.aggro or {}
  data.aggro[key] = true
  Bot.save_zone_rules(zone)
  Bot.echo("<gray>агрессор в <cyan>" .. zone .. "<gray>: <reset>" .. key ..
    "<gray> — бью всегда")
  return true
end

-- агрессор, известный только коротким именем из промпта/MSDP
function Bot.learn_aggro(name)
  name = Bot.trim(tostring(name or ""))
  if name == "" or Bot.is_protected(name) then return false end
  if Bot.state == "record" then
    if (Bot.record.mode or "all") ~= "list" then return false end
  else
    local R = Bot.zone_rules()
    if R.mode ~= "list" then return false end
    if Bot.name_in(R.kill, name) or Bot.name_in(R.aggro, name) then return false end
  end
  return Bot.mark_aggro(name)
end

function Bot.aggro_scan(line)
  local name = Bot.aggro_name(line)
  if not name then return false end
  Bot.aggroSeen = name
  return Bot.mark_aggro(name)
end

-- ===================== «не бить»: мирные и квестовые существа =====================
-- Сервер отвечает «Ваши убеждения не позволяют вам сделать этого» на атаку
-- мирного или квестового NPC (в jmc такие отсекались флагом [Мирный] из лора).
-- Запоминаем строку существа для комнаты и больше её не бьём — иначе бот жжёт
-- ману и пишет «не добил мобов». Файл <профиль>/bot/noattack.lua:
--   return { ["110056"] = { ["Захудалый старикашка сидит тут."] = true } }
Bot.noAttack = Bot.noAttack or {}

function Bot.noattack_path()
  return Bot.base_dir() .. "/noattack.lua"
end

function Bot.load_noattack()
  Bot.noAttack = Bot.noAttack or {}
  local path = Bot.noattack_path()
  if not Bot.file_exists(path) then return end
  local f = io.open(path, "rb")
  if not f then return end
  local src = f:read("*a") or ""
  f:close()
  local loader = loadstring or load
  local chunk = loader(src, "=bot/noattack.lua")
  local ok, data = false, nil
  if chunk then ok, data = pcall(chunk) end
  if not ok or type(data) ~= "table" then
    Bot.warn("<orange>noattack.lua не читается — список «не бить» пуст")
    return
  end
  for room, list in pairs(data) do
    if type(list) == "table" then
      local set = Bot.noAttack[tostring(room)] or {}
      for line, value in pairs(list) do
        if value then set[tostring(line)] = true end
      end
      Bot.noAttack[tostring(room)] = set
    end
  end
  Bot.dbg("[не бить] комнат в списке: " .. tostring(Bot.count(Bot.noAttack)))
end

function Bot.save_noattack()
  Bot.ensure_dir(Bot.base_dir())
  local f, err = io.open(Bot.noattack_path(), "wb")
  if not f then
    Bot.warn("<orange>не смог записать " .. Bot.noattack_path() .. ": " .. tostring(err))
    return false
  end
  f:write("-- существа, которых бот не бьёт: сервер ответил «убеждения не позволяют»\n")
  f:write("-- (мирные/квестовые NPC). Ключ — VNUM комнаты, значение — строка существа.\n")
  f:write("return {\n")
  local rooms = {}
  for room in pairs(Bot.noAttack) do rooms[#rooms + 1] = tostring(room) end
  table.sort(rooms)
  for _, room in ipairs(rooms) do
    local lines = {}
    for line in pairs(Bot.noAttack[room]) do lines[#lines + 1] = tostring(line) end
    table.sort(lines)
    if #lines > 0 then
      f:write("  [" .. string.format("%q", room) .. "] = {\n")
      for _, line in ipairs(lines) do
        f:write("    [" .. string.format("%q", line) .. "] = true,\n")
      end
      f:write("  },\n")
    end
  end
  f:write("}\n")
  f:close()
  return true
end

function Bot.is_noattack(line)
  local room = Bot.vnum()
  -- сначала правила зоны (после миграции/пометок при записи)
  if Bot.rule_noattack(line, room) then return true end
  local list = Bot.noAttack[room]
  if list == nil then return false end
  if list[tostring(line)] then return true end
  local key = Bot.mob_key(line)
  return key ~= "" and list[key] == true
end

-- принадлежит ли комната маршруту зоны (по шагам и клетке входа)
local function zone_owns_room(data, room)
  if not data or room == nil then return false end
  room = tostring(room)
  for _, step in ipairs(data.steps or {}) do
    if step.room and tostring(step.room) == room then return true end
  end
  local e = data.entry
  return e ~= nil and e.vnum ~= nil and tostring(e.vnum) == room
end

-- куда писать «не бить»: в запись, в файл зоны (если комната её) или глобально
function Bot.mark_noattack(room, line)
  room = tostring(room or Bot.vnum())
  line = Bot.trim(tostring(line or ""))
  if room == "" or line == "" then return false end
  local key = Bot.mob_key(line)
  if key == "" then return false end
  if Bot.state == "record" and Bot.record.name then
    Bot.record.noattack = Bot.record.noattack or {}
    local set = Bot.record.noattack[room] or {}
    Bot.record.noattack[room] = set
    if set[key] then return false end
    set[key] = true
    return true, "record"
  end
  local zone = Bot.zone
  local data = zone and Bot.zones[zone]
  if data and zone_owns_room(data, room) then
    data.noattack = data.noattack or {}
    local set = data.noattack[room] or {}
    data.noattack[room] = set
    if set[key] then return false end
    set[key] = true
    Bot.save_zone_rules(zone)
    return true, "zone"
  end
  Bot.noAttack[room] = Bot.noAttack[room] or {}
  if Bot.noAttack[room][line] then return false end
  Bot.noAttack[room][line] = true
  Bot.save_noattack()
  return true, "global"
end

function Bot.noattack_room_clear(room)
  room = tostring(room or Bot.vnum())
  local cleared = false
  local zone = Bot.zone
  local data = zone and Bot.zones[zone]
  if data and data.noattack and data.noattack[room] then
    data.noattack[room] = nil
    Bot.save_zone_rules(zone)
    cleared = true
  end
  if Bot.noAttack[room] then
    Bot.noAttack[room] = nil
    Bot.save_noattack()
    cleared = true
  end
  return cleared
end

-- перенос «не бить» из глобального noattack.lua в файл зоны (по её шагам)
function Bot.migrate_noattack(zone, data)
  if not (zone and data and Bot.noAttack) then return 0 end
  local moved, rooms = 0, {}
  for room, list in pairs(Bot.noAttack) do
    if type(list) == "table" and zone_owns_room(data, room) then
      for line in pairs(list) do
        local key = Bot.mob_key(line)
        if key ~= "" then
          data.noattack = data.noattack or {}
          local set = data.noattack[tostring(room)] or {}
          data.noattack[tostring(room)] = set
          if not set[key] then
            set[key] = true
            moved = moved + 1
          end
        end
      end
      rooms[#rooms + 1] = room
    end
  end
  if moved == 0 then return 0 end
  Bot.save_zone(zone, data)
  for _, room in ipairs(rooms) do Bot.noAttack[room] = nil end
  Bot.save_noattack()
  Bot.echo("<gray>noattack → зона <cyan>" .. zone .. "<gray>: перенесено существ " ..
    tostring(moved) .. " (комнат " .. tostring(#rooms) .. ")")
  return moved
end

-- сервер отказал в атаке: это мирное/квестовое существо — больше его не бьём
function Bot.on_attack_refused()
  -- Отказ — ответ на атаку, которую отправил бот. В простое/переходе бот не
  -- бьёт: ручная атака в игре не должна менять «не бить», писать файл зоны и
  -- помечать комнату пропущенной (C.skipRoom).
  if Bot.state ~= "walk" and Bot.state ~= "record" then return end
  local C = Bot.combat
  local mobs = (C and C.mobs and C.mobs()) or {}
  local first = mobs[1]
  if first then
    if Bot.mark_noattack(Bot.vnum(), first.name) then
      Bot.warn("<orange>Не бью (убеждения): <reset>" .. tostring(first.name))
    end
  elseif C then
    -- список существ неизвестен: пропускаем комнату, чтобы не долбить впустую
    C.skipRoom = Bot.vnum()
    Bot.warn("<orange>Атака запрещена, а списка существ нет — пропускаю комнату " ..
      tostring(Bot.vnum()))
  end
  if C then
    C.attempts = 0
    C.engagedAt = 0
    C.since = 0
  end
  if Bot.state == "walk" and Bot.walk and Bot.walk.pulse then
    return Bot.walk.pulse()
  end
end

-- экземпляр зоны уже существует: «… через 33 минуты 58 секунд» — не ждём
function Bot.on_zone_cooldown(name, when)
  name, when = tostring(name or ""), tostring(when or "")
  if Bot.state ~= "entry" then
    Bot.dbg("[зона] экземпляр «" .. name .. "» уже есть: " .. when)
    return
  end
  Bot.entryDeadline = 0
  Bot.warn("<orange>Экземпляр зоны «" .. name .. "» уже существует" ..
    (when ~= "" and (" (следующий через " .. when .. ")") or "") ..
    " — прохожу текущий")
  return Bot.walk_begin()
end

-- описание шага маршрута для вывода
function Bot.step_desc(step)
  if step.dir then return tostring(step.dir) end
  if step.cmd then return tostring(step.cmd) end
  if step.wait then return "пауза " .. tostring(step.wait) .. "с" end
  return "?"
end

function Bot.info(zone)
  Bot.echo("<green>[Бот: " .. tostring(Bot.state) .. "]")
  Bot.echo("<gray>  HP/MP/MV: <reset>" .. tostring(Bot.hp) .. "/" .. tostring(Bot.mp) ..
    "/" .. tostring(Bot.mv) .. "<gray>   опыт: <reset>" .. tostring(Bot.exp) ..
    "<gray>   монет: <reset>" .. tostring(Bot.money))
  Bot.echo("<gray>  комната: <cyan>" .. tostring(Bot.room.vnum) .. "<reset> " ..
    tostring(Bot.room.name) .. " <gray>выходы: <reset>" .. tostring(Bot.exits))
  if Bot.zone then
    Bot.echo("<gray>  зона: <cyan>" .. tostring(Bot.zone) .. "<gray> шаг <yellow>" ..
      tostring(Bot.i) .. "<gray>/<reset>" ..
      tostring(#((Bot.route or {}).steps or {})))
  end
  if Bot.zone then
    local R = Bot.zone_rules()
    Bot.echo("<gray>  режим: <reset>" .. (R.mode == "list" and "список" or "все") ..
      "<gray> целей <reset>" .. tostring(Bot.count(R.kill)) ..
      "<gray> агрессоров <reset>" .. tostring(Bot.count(R.aggro)) ..
      "<gray> не бью <reset>" .. tostring(Bot.count(R.noattack)))
  end
  if Bot.resume and Bot.resume.zone then
    Bot.echo("<gray>  продолжение: <cyan>" .. tostring(Bot.resume.zone) ..
      "<gray> шаг <reset>" .. tostring(Bot.resume.i))
  end
  if Bot.battle then Bot.echo("<red>  бой: " .. tostring(Bot.target)) end
  if Bot.state == "walk" and Bot.room_fight_wait() then
    local left = (Bot.roomFightUntil and Bot.roomFightUntil > 0) and
      Bot.secs_desc(Bot.roomFightUntil - Bot.now()) or "?"
    Bot.echo("<orange>  в комнате идёт бой — жду (до " .. left .. ", look раз в " ..
      tostring(Bot.config.groupFightProbe) .. "с)")
  end
  if Bot.paused then Bot.echo("<orange>  бот на паузе") end
  if zone then
    local data, err = Bot.zone_data(zone)
    if data then
      Bot.echo("<gray>  маршрут «" .. zone .. "»: <yellow>" .. tostring(#data.steps) ..
        "<gray> шагов")
      Bot.echo("<gray>    режим: <reset>" ..
        (data.mode == "list" and "список" or "все") ..
        "<gray>, целей " .. tostring(Bot.count(data.kill)) ..
        ", агрессоров " .. tostring(Bot.count(data.aggro)))
      local entry = data.entry or (data.transit and { vnum = data.transit.vnum })
      Bot.echo("<gray>    вход: <reset>" .. Bot.entry_desc(entry))
      if #data.steps > 0 then
        local first, last = data.steps[1], data.steps[#data.steps]
        Bot.echo("<gray>    первый: " .. Bot.step_desc(first) ..
          " (" .. tostring(first.room) .. ")")
        Bot.echo("<gray>    последний: " .. Bot.step_desc(last) ..
          " (" .. tostring(last.room) .. ")")
      end
    else
      Bot.warn("Маршрут «" .. zone .. "»: " .. tostring(err))
    end
  end
end

function Bot.command(cmd, arg)
  cmd = (tostring(cmd or "")):lower()
  arg = Bot.trim(arg or "")
  local args = Bot.split(arg)

  if cmd == "" or cmd == "?" or cmd == "помощь" then return Bot.help() end

  if cmd == "старт" then return Bot.start(args) end
  if cmd == "стоп" then return Bot.stop() end
  if cmd == "продолжить" then return Bot.resume_continue() end

  if cmd == "пауза" then
    local on = args[1] ~= "0"
    Bot.paused = on
    Bot.echo(on and "<orange>Пауза включена" or "<green>Пауза снята")
    if not on then
      if Bot.walk and Bot.walk.pulse then Bot.walk.pulse() end
      if Bot.circle_step then Bot.circle_step() end
    end
    return
  end

  if cmd == "ждать" then
    if Bot.state ~= "record" then
      Bot.warn("<gray>Шаг «ждать сообщение» пишется при записи: " ..
        "<yellow>.бот запись старт «зона»")
      return
    end
    return Bot.record_trigger(arg)
  end

  if cmd == "инфо" then return Bot.info(args[1]) end

  if cmd == "запись" then
    local sub = args[1]
    if sub == "старт" then
      if not args[2] then Bot.warn("Формат: <yellow>.бот запись старт «зона»") return end
      return Bot.record_start(args[2], args[3])
    elseif sub == "стоп" then
      return Bot.record_stop()
    elseif sub == "сброс" then
      return Bot.record_reset()
    elseif sub == "вход" then
      if args[2] == "+" then
        local diff = tonumber(args[4])
        if not args[3] or not diff then
          Bot.warn("Формат: <yellow>.бот запись вход + <направление> <сложность>")
          return
        end
        local entry = Bot.record.entry or {}
        entry.vnum = entry.vnum or Bot.vnum()
        entry.dir = Bot.dir_form(args[3])
        entry.maxdiff = diff
        Bot.record.entry = entry
        Bot.echo("<green>Вход в зону: <reset>" .. Bot.entry_desc(entry))
        return
      end
      Bot.echo("<gray>Вход в зону: <reset>" .. Bot.entry_desc(Bot.record.entry))
      return
    end
    Bot.echo("<gray>Запись: " .. tostring(Bot.record.name or "не ведётся") ..
      ", шагов " .. tostring(#Bot.record.steps) ..
      ", в очереди " .. tostring(#Bot.record.queue) ..
      ", отложено " .. tostring(#Bot.record.deferred) ..
      ", потеряно ходов " .. tostring(Bot.record.drops))
    Bot.echo("<gray>  вход: <reset>" .. Bot.entry_desc(Bot.record.entry))
    return
  end

  if cmd == "круг" then
    local L = Bot.loop or { list = {}, idx = 0, deleteAt = {} }
    Bot.loop = L
    L.deleteAt = L.deleteAt or {}
    if args[1] == "стоп" then
      L.list = {}
      L.idx = 0
      L.deleteAt = {}
      Bot.circleDelete = nil
      Bot.echo("<green>Круг остановлен")
      return
    end
    if #args == 0 then
      if #L.list == 0 then
        Bot.echo("Круг пуст. Пример: <yellow>.бот круг тоннель_бесов башня_магов")
        return
      end
      Bot.echo("<gray>Запрашиваю «обл»…")
      return Bot.instance_query("circle_info")
    end

    local mode
    if args[1] == "+" then
      mode = "add"
      table.remove(args, 1)
    elseif args[1] == "-" then
      mode = "del"
      table.remove(args, 1)
    end
    if #args == 0 then
      Bot.warn("Укажите зоны: <yellow>.бот круг " ..
        (mode == "add" and "+ " or mode == "del" and "- " or "") .. "«зона1» «зона2» ...")
      return
    end

    if mode == "add" then
      local have = {}
      for _, zone in ipairs(L.list) do have[zone] = true end
      for _, zone in ipairs(args) do
        if not have[zone] then
          L.list[#L.list + 1] = zone
          have[zone] = true
        end
      end
    elseif mode == "del" then
      local drop = {}
      for _, zone in ipairs(args) do
        drop[zone] = true
        L.deleteAt[zone] = nil
      end
      local keep = {}
      for _, zone in ipairs(L.list) do
        if not drop[zone] then keep[#keep + 1] = zone end
      end
      L.list = keep
      if L.idx > #L.list then L.idx = 0 end
    else
      L.list = Bot.copy_list(args)
      L.idx = 0
      L.deleteAt = {}
      Bot.circleDelete = nil
    end

    if #L.list == 0 then
      Bot.circleDelete = nil
      Bot.echo("<green>Круг пуст")
      return
    end
    Bot.echo("<green>Круг зон: <cyan>" .. table.concat(L.list, ", "))
    if not Bot.running() then return Bot.circle_step() end
    return
  end

  if cmd == "перезагрузить" or cmd == "reload" then
    local zone = args[1] or Bot.zone
    if not zone then
      Bot.warn("Укажите зону: <yellow>.бот перезагрузить «зона»")
      return
    end
    if Bot.zone == zone and Bot.running() then
      Bot.warn("Зона «" .. zone .. "» уже идёт — сначала <yellow>.бот стоп")
      return
    end
    local data, err = Bot.reload_zone(zone)
    if not data then
      Bot.warn("Зона «" .. tostring(zone) .. "»: " .. tostring(err))
      return
    end
    Bot.echo("<green>Зона <cyan>" .. zone .. "<green> перечитана: <yellow>" ..
      tostring(#data.steps) .. "<green> шагов, режим <reset>" ..
      (data.mode == "list" and "список" or "все") ..
      "\n<gray>вход: " .. Bot.entry_desc(data.entry))
    return
  end

  if cmd == "зоны" then
    return Bot.zones_list()
  end

  if cmd == "обл" then
    Bot.echo("<gray>Запрашиваю экземпляры зон…")
    return Bot.instance_query("show")
  end

  if cmd == "репоп" then
    Bot.warn("<orange>«.бот репоп» объединён с «.бот круг» — использую круг")
    -- старый fallback-период в минутах больше не нужен: таймеры берутся из «обл»
    if args[1] == "+" and tonumber(args[#args] or "") then
      table.remove(args, #args)
      arg = table.concat(args, " ")
    end
    return Bot.command("круг", arg)
  end

  if cmd == "маршрут" then
    local zone = args[1] or Bot.zone
    if not zone then Bot.warn("Укажите зону: <yellow>.бот маршрут «зона»") return end
    local data, err = Bot.zone_data(zone)
    if not data then Bot.warn("Маршрут «" .. zone .. "»: " .. tostring(err)) return end
    Bot.echo("<green>Маршрут <cyan>" .. zone .. "<green>: " ..
      tostring(#data.steps) .. " шагов")
    for i, step in ipairs(data.steps) do
      if i > 40 then
        Bot.echo("<gray>  ... ещё " .. tostring(#data.steps - 40))
        break
      end
      Bot.echo(string.format("<gray>%3d. <reset>%s<gray> -> <cyan>%s",
        i, Bot.step_desc(step), tostring(step.room)))
    end
    if data.final_steps and #data.final_steps > 0 then
      Bot.echo("<green>Финальные шаги после маршрута: <yellow>" ..
        tostring(#data.final_steps))
      for i, step in ipairs(data.final_steps) do
        Bot.echo(string.format("<gray>%3d. <reset>%s", i, Bot.step_desc(step)))
      end
    end
    return
  end

  if cmd == "цель" then
    if #Bot.mobs == 0 then
      Bot.echo("<gray>В комнате нет записанных существ — нужен свежий look (бот обновляет список после хода/look)")
      return
    end
    -- мобы — строки как есть; игроки — короткое имя (текст до глагола).
    -- index — позиция в комнате: номер цели считается по ней, а не по счётчику
    -- «атакуемых» (мирный моб впереди тоже занимает номер).
    local players, mobs = {}, {}
    for i, line in ipairs(Bot.mobs) do
      if Bot.is_protected(line) then
        players[#players + 1] = Bot.line_head(line)
      else
        mobs[#mobs + 1] = { line = line, index = i }
      end
    end
    local spared = 0
    for _, m in ipairs(mobs) do
      if Bot.is_noattack(m.line) then spared = spared + 1 end
    end
    local R = Bot.zone_rules()
    local targets = 0
    for _, m in ipairs(mobs) do
      if Bot.rule_target(m.line) then targets = targets + 1 end
    end
    local parts = {
      "мобов " .. tostring(#mobs),
      "игроков " .. tostring(#players),
      "group_count " .. tostring(tonumber(rawget(_G, "group_count")) or 1),
      "pet_count " .. tostring(tonumber(rawget(_G, "pet_count")) or 0),
      "источник " .. tostring(Bot.mobSourceUsed or "?"),
    }
    if spared > 0 then parts[#parts + 1] = "не бью " .. tostring(spared) end
    if R.mode == "list" then
      parts[#parts + 1] = "режим список, целей " .. tostring(targets)
    end
    if Bot.mobSourceUsed == "color" then
      parts[#parts + 1] = "предметов " .. tostring(Bot.itemsSeen or 0)
    end
    Bot.echo("<green>Существа <gray>(" .. table.concat(parts, ", ") .. ")")
    local first = Bot.combat and Bot.combat.mobs and Bot.combat.mobs()[1]
    Bot.echo("<gray>  атака: <reset>" ..
      Bot.attack_desc(first and Bot.target_number(first.index) or nil))
    if #players > 0 then
      Bot.echo("<gray>  игроки (не бьются):")
      for _, name in ipairs(players) do
        Bot.echo("<gray>    <orange>" .. tostring(name))
      end
    end
    if #mobs == 0 then
      Bot.echo("<gray>  мобов нет — драться не с кем")
      return
    end
    Bot.echo("<gray>  мобы (номер = group_count + pet_count + место в комнате):")
    for _, m in ipairs(mobs) do
      local mark = ""
      if Bot.is_noattack(m.line) then
        mark = " <orange>(не бью — убеждения)"
      elseif R.mode == "list" and not Bot.rule_target(m.line) then
        mark = " <gray>(мимо — не цель)"
      elseif R.mode == "list" then
        mark = " <green>(цель)"
      end
      Bot.echo(string.format("<gray>    <yellow>№%d<reset>. %s%s",
        Bot.target_number(m.index), tostring(m.line), mark))
    end
    return
  end

  if cmd == "небить" or cmd == "небей" then
    if args[1] == "сброс" or args[1] == "-" then
      if Bot.noattack_room_clear() then
        Bot.echo("<green>Комната " .. tostring(Bot.vnum()) .. ": список «не бить» очищен")
      else
        Bot.echo("<gray>В комнате " .. tostring(Bot.vnum()) .. " список «не бить» пуст")
      end
      return
    end
    local mobs = (Bot.combat and Bot.combat.mobs and Bot.combat.mobs()) or {}
    local first = mobs[1]
    if not first then
      Bot.warn("Нет целей: нужен свежий look, либо все существа уже в списке «не бить»")
      return
    end
    local _, scope = Bot.mark_noattack(Bot.vnum(), first.name)
    Bot.echo("<green>Не бью в " .. tostring(Bot.vnum()) .. ": <reset>" ..
      tostring(first.name))
    if scope == "zone" then
      Bot.echo("<gray>  сохранено в файле зоны: " .. Bot.zone_path(Bot.zone))
    elseif scope == "record" then
      Bot.echo("<gray>  попадёт в файл зоны при «запись стоп»")
    else
      Bot.echo("<gray>  файл: " .. Bot.noattack_path())
    end
    return
  end

  if cmd == "режим" then
    local function is_mode(word)
      return word == "все" or word == "all" or word == "список" or word == "list"
    end
    local zone, want = Bot.zone, nil
    local a1 = Bot.fold(args[1] or "")
    local a2 = Bot.fold(args[2] or "")
    if a1 == "" then
      if not zone then
        Bot.warn("Бот не в зоне: укажите зону: <yellow>.бот режим «зона» список")
        return
      end
      local data = Bot.zone_data(zone)
      if not data then
        Bot.warn("Зона «" .. tostring(zone) .. "» не читается")
        return
      end
      local R = Bot.zone_rules(zone)
      Bot.echo("<green>Зона <cyan>" .. zone .. "<green>: режим <reset>" ..
        (R.mode == "list" and "список" or "все") ..
        "<gray>, целей " .. tostring(Bot.count(R.kill)) ..
        ", агрессоров " .. tostring(Bot.count(R.aggro)) ..
        ", не бью " .. tostring(Bot.count(R.noattack)))
      Bot.echo("<gray>  сменить: <yellow>.бот режим все|список")
      return
    end
    if is_mode(a1) then
      want = a1
    else
      zone, want = args[1], a2
    end
    if not zone then
      Bot.warn("Бот не в зоне: укажите зону: <yellow>.бот режим «зона» список")
      return
    end
    if not is_mode(want) then
      Bot.warn("Формат: <yellow>.бот режим [зона] все|список")
      return
    end
    if Bot.zone == zone and Bot.running() then
      Bot.warn("Зона «" .. zone .. "» уже идёт — сначала <yellow>.бот стоп" ..
        "<orange>, иначе режим перезапишет маршрут")
      return
    end
    local data, err = Bot.reload_zone(zone)
    if not data then
      Bot.warn("Зона «" .. tostring(zone) .. "»: " .. tostring(err))
      return
    end
    data.mode = (want == "список" or want == "list") and "list" or "all"
    Bot.invalidate_rules(zone)
    local ok, save_err = Bot.save_zone(zone, data)
    if not ok then
      Bot.warn("Не сохранил: " .. tostring(save_err))
      return
    end
    Bot.echo("<green>Зона <cyan>" .. zone .. "<green>: режим <reset>" ..
      (data.mode == "list" and "список" or "все") .. "<gray> (сохранено)")
    if data.mode == "list" and Bot.count(data.kill) == 0 then
      Bot.warn("<orange>Список целей пуст: при проходе пометьте мобов <yellow>.бот бить")
    end
    return
  end

  if cmd == "атака" then
    local sub = args[1]
    local function rest_arg()
      local text = Bot.trim(arg:match("^%S+%s+(.*)$") or "")
      text = text:gsub('^"(.*)"$', "%1")
      return (text:gsub("^«(.*)»$", "%1"))
    end
    local function set_cfg(cfg)
      Bot.attack = cfg
      if Bot.save_attack() then
        Bot.echo("<green>Атака: <reset>" .. Bot.attack_desc())
      end
    end
    if sub == nil then
      Bot.echo("<green>Способ атаки: <reset>" .. Bot.attack_desc())
      Bot.echo("<gray>  .бот атака botkill              <reset>- дефолт: алиас botkill (sendWithClear(getAttack()))")
      Bot.echo("<gray>  .бот атака alias «имя»          <reset>- любой другой алиас профиля")
      Bot.echo("<gray>  .бот атака команда «шаблон»     <reset>- %n = номер первой цели")
      Bot.echo("<gray>  .бот атака lua «код»            <reset>- код на Lua, доступны Bot и target")
      Bot.echo("<gray>  .бот атака сброс                <reset>- вернуть botkill")
      Bot.echo("<gray>  файл: <reset>" .. Bot.attack_path())
      return
    end
    local mode = tostring(sub):lower()
    if mode == "-" or mode == "сброс" or mode == "дефолт" or mode == "botkill" then
      return set_cfg(Bot.attack_default())
    end
    if mode == "alias" or mode == "алиас" then
      local name = rest_arg()
      if name == "" then
        Bot.warn("Формат: <yellow>.бот атака alias «имя алиаса»")
        return
      end
      if type(rawget(_G, "exists")) == "function" and exists(name, "alias") == 0 then
        Bot.warn("<orange>Алиаса «" .. name .. "» в профиле нет — бот будет слать kill <номер>")
      end
      return set_cfg({ mode = "alias", alias = name })
    end
    if mode == "команда" or mode == "ком" or mode == "command" then
      local tmpl = rest_arg()
      if tmpl == "" then
        Bot.warn("Формат: <yellow>.бот атака команда «убить %n» <gray>(%n — номер первой цели)")
        return
      end
      return set_cfg({ mode = "command", template = tmpl })
    end
    if mode == "lua" then
      local code = rest_arg()
      if code == "" then
        Bot.warn("Формат: <yellow>.бот атака lua «код» <gray>(доступны Bot и target)")
        return
      end
      local loader = loadstring or load
      local fn, err = loader("local Bot, target = ...; " .. code, "=bot/attack.lua")
      if not fn then
        Bot.warn("<orange>Код не компилируется: " .. tostring(err))
        return
      end
      return set_cfg({ mode = "lua", code = code })
    end
    Bot.warn("Неизвестный способ «" .. mode .. "». Пример: <yellow>.бот атака команда kill %n")
    return
  end

  if cmd == "бить" then
    if not (Bot.combat and Bot.combat.manual) then
      Bot.warn("BotCombat не загружен: атаковать нечем")
      return
    end
    return Bot.combat.manual()
  end

  if cmd == "debug" then
    Bot.config.debug = not Bot.config.debug
    Bot.echo("debug: " .. tostring(Bot.config.debug))
    return
  end

  if cmd == "dry" then
    Bot.config.dry = not Bot.config.dry
    Bot.echo("dry-run: " .. tostring(Bot.config.dry))
    return
  end

  Bot.warn("Неизвестная команда «" .. cmd .. "». Справка: <yellow>.бот ?")
end

-- ===================== события и триггеры =====================

Bot.gen = (Bot.gen or 0) + 1
local gen = Bot.gen

-- при перезапуске скрипта снимаем триггеры/хендлеры прошлой загрузки
local function kill_trigger_id(id)
  if type(id) == "number" then
    if id > 0 then killTrigger(id) end
  elseif type(id) == "table" then
    for _, inner in ipairs(id) do kill_trigger_id(inner) end
  end
end

local function kill_old()
  for _, id in pairs(Bot.triggers) do kill_trigger_id(id) end
  Bot.triggers = {}
  for _, id in pairs(Bot.handlers) do
    if type(id) == "number" and id > 0 then killAnonymousEventHandler(id) end
  end
  Bot.handlers = {}
end
kill_old()

function Bot.arm_triggers()
  local T = Bot.triggers
  -- промпт и строки комнаты ловит ОДИН строчный триггер: tempPromptTrigger в этой
  -- сборке Mudlet не даёт строку (getCurrentLine() → «ERROR: invalid line number»),
  -- поэтому промпт разбирается по шаблону в Bot.is_prompt_line.
  T.prompt = nil
  T.text = tempRegexTrigger("^(.+)$",
    function() Bot.safe("в комнате", Bot.on_text_line, matches and matches[2]) end)
  -- цветовые триггеры не нужны: цвет каждой строки берём через getTextFormat()
  -- в строчном триггере; пустые списки оставлены для совместимости
  T.mob, T.item, T.player, T.group = {}, {}, {}, {}
  -- серверные сообщения (каждый колбэк через Bot.safe: ошибка не ломает бота)
  T.noMove = tempRegexTrigger("^Вы не можете идти в этом направлении",
    function() Bot.safe("отказ хода", Bot.on_blocked_move, "направление") end)
  T.needOpen = tempRegexTrigger("^Попробуйте сначала открыть (.+)\\.$",
    function()
      Bot.safe("дверь", Bot.on_blocked_move, "дверь",
        matches and matches[2] or nil)
    end)
  -- «Деревянная дверь заперта.» — запертую профильный триггер не отопрёт.
  -- Формы через |, а не [аыо]: rex/tempRegexTrigger тут без UTF-8, и класс
  -- из кириллических букв режется по байтам и не срабатывает.
  T.doorLocked = tempRegexTrigger("^(.+?) (заперт|заперта|заперты|заперто)\\.$",
    function()
      Bot.safe("заперто", Bot.on_blocked_move, "заперто",
        matches and matches[2] or nil)
    end)
  T.spawn = tempRegexTrigger("^Создан экземпляр зоны (.+)\\.$",
    function()
      Bot.safe("заселение", Bot.on_zone_spawn, matches and matches[2] or "")
    end)
  -- сервер отказал в сложности: «… сложности +2 вы должны 10 раз …»
  T.zoneDiff = tempRegexTrigger("^Для создания области зоны .+$",
    function()
      local line = matches and matches[1] or ""
      local diff, times = Bot.parse_zone_diff_refused(line)
      if diff then
        Bot.safe("сложность зоны", Bot.on_zone_diff_refused, diff, times)
      end
    end)
  -- экземпляр зоны уже есть: «… через 33 минуты 58 секунд» — не ждём entryWait
  T.zoneCooldown = tempRegexTrigger(
    "^Вы сможете создать новый экземпляр зоны '(.+)' через (.+)\\.$",
    function()
      Bot.safe("кулдаун", Bot.on_zone_cooldown,
        matches and matches[2] or "", matches and matches[3] or "")
    end)
  -- сервер запретил атаку: мирное/квестовое существо — запоминаем и больше не бьём
  T.refused = tempRegexTrigger("^Ваши убеждения не позволяют вам сделать этого",
    function() Bot.safe("отказ атаки", Bot.on_attack_refused) end)
end

function Bot.arm_events()
  local H = Bot.handlers
  H.room = registerAnonymousEventHandler("msdp.ROOM",
    function() Bot.safe("комната MSDP", Bot.on_msdp_room) end)
  H.send = registerAnonymousEventHandler("sysDataSendRequest",
    function(_, cmd) Bot.safe("запись хода", Bot.record_on_send, cmd) end)
  H.protocol = registerAnonymousEventHandler("sysProtocolEnabled",
    function(_, protocol) Bot.safe("MSDP", Bot.on_protocol, protocol) end)
  local vars = { "HEALTH", "HEALTH_MAX", "MANA", "MANA_MAX", "MOVEMENT", "MOVEMENT_MAX",
                 "EXPERIENCE", "MONEY", "OPPONENT_NAME" }
  for _, name in ipairs(vars) do
    local var = name
    H["msdp" .. var] = registerAnonymousEventHandler("msdp." .. var,
      function(_, value) Bot.safe("MSDP " .. var, Bot.on_msdp_var, var, value) end)
  end
end

function Bot.on_protocol(protocol)
  if protocol ~= "MSDP" then return end
  local vars = { "ROOM", "HEALTH", "HEALTH_MAX", "MANA", "MANA_MAX", "MOVEMENT",
                 "MOVEMENT_MAX", "EXPERIENCE", "MONEY", "OPPONENT_NAME" }
  for _, v in ipairs(vars) do sendMSDP("REPORT", v) end
  Bot.dbg("[msdp] подписка на переменные")
end

-- "Вы не можете идти в этом направлении" / "Попробуйте сначала открыть" / "… заперт."
-- Двери открывает профильный триггер (по переменной dir), бот только повторяет шаг.
function Bot.on_blocked_move(kind, door)
  kind = kind or "направление"
  door = door and Bot.trim(door) or nil
  -- «Калитка не заперта.» — это ответ на «отпер», а не запертая дверь
  if door and door:find("%sне$") then return end
  if Bot.state == "record" then
    if kind == "направление" then
      Bot.record_drop_last()
    else
      Bot.record_retry(kind, door)
    end
    return
  end
  if Bot.state ~= "walk" then return end
  if Bot.walk and Bot.walk.blocked then Bot.walk.blocked(kind, door) end
end

-- ===================== тик =====================

function Bot.schedule_tick(generation)
  generation = generation or Bot.gen
  Bot.timers.tick = tempTimer(1, function()
    if generation ~= Bot.gen then return end
    -- Тик пере-планируем ВСЕГДА: ошибка внутри (pulse/бой/панель/круг) раньше
    -- обрывала цепочку, и бот замирал до следующего промпта — то есть до Enter.
    Bot.safe("в тике", Bot.tick, generation)
    if generation == Bot.gen then Bot.schedule_tick(generation) end
  end)
end

function Bot.tick(generation)
  if generation ~= Bot.gen then return end
  Bot.record_expire()

  -- блок комнаты в ответ на look не пришёл — не ждём дольше lookWait
  if Bot.lookPending and Bot.now() >= Bot.lookPending then
    Bot.dbg("[room] блок комнаты после look не пришёл — продолжаю")
    Bot.lookPending = nil
  end

  if Bot.waitUntil ~= 0 and Bot.now() >= Bot.waitUntil then
    Bot.waitUntil = 0
    Bot.act_wait = nil
    if Bot.walk and Bot.walk.pulse then Bot.walk.pulse() end
  end

  if Bot.state == "transit" then
    if Bot.entryTarget and Bot.vnum() == Bot.entryTarget then
      Bot.entry_begin()
    elseif Bot.deadline > 0 and Bot.now() > Bot.deadline then
      Bot.fail("не добежал до клетки входа")
      return
    end
  elseif Bot.state == "entry" then
    if Bot.entryDeadline > 0 and Bot.now() > Bot.entryDeadline then
      Bot.entryDeadline = 0
      Bot.warn("<orange>«Создан экземпляр зоны» не пришёл — начинаю проход")
      Bot.walk_begin()
      return
    end
  end

  if Bot.state == "walk" and not Bot.paused then
    if Bot.combat and Bot.combat.check_timeout then Bot.combat.check_timeout() end
    if Bot.hp_critical() then
      Bot.fail("HP " .. tostring(Bot.hp) .. "/" .. tostring(Bot.hpMax) ..
        " ниже порога — останавливаюсь")
      return
    end
    if Bot.rest_tick() then
      -- отдыхаем: маршрут ждёт, пока не наберём выносливость
    elseif Bot.expect and Bot.deadline > 0 and Bot.now() > Bot.deadline then
      if Bot.walk and Bot.walk.timeout then Bot.walk.timeout() end
    elseif not Bot.expect and not Bot.waiting() and not Bot.battle then
      if Bot.room_fight_wait() then
        -- в комнате ещё дерутся (наш таргет пропал): обновляем её изредка
        Bot.room_fight_probe()
      elseif not Bot.lookPending then
        if Bot.walk and Bot.walk.pulse then Bot.walk.pulse() end
      end
    end
  end

  Bot.circle_counter = (Bot.circle_counter or 0) + 1
  if Bot.circle_counter >= (Bot.config.repopTick or 60) then
    Bot.circle_counter = 0
    Bot.circle_tick()
  end

  if Bot.panelUpdate then Bot.panelUpdate() end
end

-- ===================== инициализация =====================

function Bot.init()
  -- чистка API прошлых версий: скрипт перезапускается в живом профиле, а старые
  -- глобальные функции остаются в Lua-состоянии (лор и эвристика имён удалены)
  Bot.mob_name = nil
  Bot.load_lore = nil
  Bot.lore_path = nil
  Bot.loreCache = nil
  Bot.mob_verb_endings = nil
  Bot.mob_adverbs = nil
  Bot.looks_like_verb = nil
  Bot.neverAttack = nil
  Bot.load_never_attack = nil
  Bot.save_never_attack = nil
  Bot.never_attack_path = nil
  Bot.transit = nil
  Bot.transitTarget = nil
  Bot.load_transit = nil
  -- старый планировщик репопов объединён с кругом: чистим функции прошлых версий
  Bot.repop = nil
  Bot.repop_add = nil
  Bot.repop_del = nil
  Bot.repop_info = nil
  Bot.repop_tick = nil
  Bot.repop_start_ready = nil
  Bot.repop_apply_instances = nil
  Bot.repop_drop = nil
  Bot.loop_next = nil
  -- doorOpen заменён на doorRetryLimit/doorRetryDelay (двери открывает профиль)
  Bot.config.doorOpen = nil
  -- «ожидание look после боя» раньше было булевым afterLook (теперь Bot.lookPending)
  Bot.afterLook = nil
  -- кэши маршрутов/правил: скрипт перезапускается в живом Lua, файлы могли
  -- измениться руками — читаем заново
  Bot.zones = {}
  Bot.rulesCache = {}
  Bot.instances = {}
  Bot.instancesAt = 0
  Bot.instanceQuery = nil
  Bot.instance_probe_reset()
  -- старые настройки: "auto" больше не откатывается в текст — моб только красный
  if Bot.config.mobSource == "auto" then Bot.config.mobSource = "color" end
  Bot.probe_reset()
  Bot.arm_triggers()
  Bot.arm_events()
  Bot.ensure_dir(Bot.base_dir() .. "/zones")
  Bot.load_attack()
  Bot.load_noattack()
  -- подписка на MSDP: sysProtocolEnabled мог пройти задолго до загрузки скриптов
  if sendMSDP then Bot.on_protocol("MSDP") end
  -- и сразу читаем текущую комнату, чтобы VNUM/название были не пустыми
  Bot.on_msdp_room()
  Bot.schedule_tick(gen)
  Bot.echo("<green>загружен. Справка: <yellow>.бот ?")
  if not Bot.walk then
    Bot.warn("<orange>BotWalk не загружен: проход зон работать не будет")
  end
  if not Bot.combat then
    Bot.warn("<orange>BotCombat не загружен: бот не будет драться")
  end
  if Bot.panelUpdate then Bot.panelUpdate(true) end
end

tempTimer(0, function()
  if gen ~= Bot.gen then return end
  Bot.init()
end)
