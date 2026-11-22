-- Стенд: заглушки Mudlet API + прогон BotCore/BotWalk/BotCombat/BotPanel.
-- Нужен только Lua 5.1+ (проверяет логику, а не GUI):
--   lua tests/botHarness.lua
-- Возвращает 0 при успехе; при ошибке печатает FAIL и выходит с кодом 1.

local HERE = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local BASE = HERE .. "/../"
local HOME = "/tmp/bot-harness-home"

os.execute("rm -rf '" .. HOME .. "'")
os.execute("mkdir -p '" .. HOME .. "/bot/zones'")

local NOW = 1000
local timers, nextId = {}, 1
local sent = {}
local errors = 0

local function fail(msg)
  errors = errors + 1
  io.write("FAIL: ", msg, "\n")
end

local function check(cond, msg)
  if cond then io.write("ok: ", msg, "\n") else fail(msg) end
end

-- ===== Mudlet API =====
function getEpoch() return NOW end
function cecho(t) io.write(t) end
function decho(t) io.write(t) end
function echo(t) io.write(t) end
function send(cmd) sent[#sent + 1] = cmd end

-- боевая часть профиля: бот жмёт алиас botkill (sendWithClear(getAttack())),
-- а номер цели профиль считает от group_count/pet_count
local expanded = {}
local attack_cmd = "колд доминирование"
local alias_known = { botkill = true, ["бой"] = true }
group_count, pet_count = 1, 0
function getAttack() return attack_cmd end
function sendWithClear(cmd)
  if cmd == nil or cmd == "" then return end
  sent[#sent + 1] = "clear:" .. tostring(cmd)
end
function exists(name, kind)
  if kind == "alias" and alias_known[name] then return 1 end
  return 0
end
function expandAlias(name)
  expanded[#expanded + 1] = name
  if name == "botkill" then
    local cmd = getAttack()
    Bot = Bot or {}
    Bot._attackSent = (cmd ~= nil and cmd ~= "")
    if Bot._attackSent then sendWithClear(cmd) end
  end
end
function tempTimer(sec, fn)
  local id = nextId; nextId = nextId + 1
  timers[id] = { at = NOW + (tonumber(sec) or 0), fn = fn }
  return id
end
function killTimer(id) timers[id] = nil end
function tempPromptTrigger() return 0 end
function tempColorTrigger() return 0 end
function tempRegexTrigger() return 0 end
function killTrigger() end
function registerAnonymousEventHandler() return 0 end
function killAnonymousEventHandler() end
function getMudletHomeDir() return HOME end
function sendMSDP() end
function getCurrentLine() return currentLine or "" end
-- цвет текущей строки: Mudlet отдаёт его в getTextFormat().foreground = {r,g,b};
-- getFgColor() вне выделения здесь бесполезен (всегда 255), поэтому не используется
local fgColor = nil
function getFgColor() return fgColor end
local function setFg(v) fgColor = v end
local textFormat = nil
function getTextFormat() return textFormat end
-- выделение нужно getTextFormat(): без него Mudlet ругается «no character under cursor»
local selectedLine = nil
function selectCurrentLine() selectedLine = currentLine return true end
function deselect() selectedLine = nil end
-- цвет в этой сборке Mudlet читаем по выделению capture-группы триггера
local selectedCapture = nil
function selectCaptureGroup(n) selectedCapture = n return 1 end
local function setFmt(r, g, b)
  if r == nil then
    textFormat = nil
  else
    textFormat = { foreground = { r, g, b } }
  end
end

local function run_timers(target)
  while true do
    local bestId, best
    for id, t in pairs(timers) do
      if t.at <= target and (not best or t.at < best.at) then bestId, best = id, t end
    end
    if not best then break end
    timers[bestId] = nil
    NOW = best.at
    local ok, err = pcall(best.fn)
    if not ok then fail("таймер упал: " .. tostring(err)) end
  end
  NOW = target
end
function advance(sec) run_timers(NOW + sec) end

msdp = { ROOM = {} }
map = { currentRoom = 0 }
getRoomIDbyHash = function() return -1 end
getRoomHashByID = function() return "" end
currentLine = ""
matches = {}
speedWalkDir = {}
-- mudlet API для MapperEchoFix: последняя строка буфера через getLines
function getLastLineNumber() return 0 end
function getLines() return { currentLine or "" } end
function moveCursorEnd() end

-- MudMapper: бег к клетке входа (то, что делает «гмуть», но по VNUM и с «куп 2»)
local mudGoto = nil
MudMapper = {
  goto_vnum = function(vnum, portal)
    mudGoto = { vnum = tostring(vnum), portal = portal }
  end,
}

-- заглушка Geyser.Label
Geyser = { Label = {} }
function Geyser.Label:new(args)
  local label = { name = args and args.name }
  function label:echo() end
  function label:setStyleSheet() end
  function label:setClickCallback() end
  return label
end

-- ===== загрузка скриптов =====
local base = BASE
dofile(base .. "botCore.lua")
dofile(base .. "botWalk.lua")
dofile(base .. "botCombat.lua")
dofile(base .. "botPanel.lua")
dofile(base .. "mapperEchoFix.lua")

advance(0.5)
check(Bot ~= nil and Bot.state == "idle", "BotCore загружен, состояние idle")
check(Bot.walk ~= nil, "BotWalk подключён")
check(Bot.combat ~= nil, "BotCombat подключён")
check(Bot.config.mobSource == "color", "по умолчанию мобы только по цвету")
check(Bot.config.doorRetryLimit == 5, "двери: лимит повторов по умолчанию 5")

-- ===== помощники имитации вывода сервера =====
local function feed(line)
  currentLine = line
  Bot.on_text_line()
end

local function room_block(title, content)
  feed(title)
  feed("[ Exits: N E S W ]")
  for _, line in ipairs(content or {}) do feed(line) end
end

-- строки промптов как их присылает сервер
local PEACE = "500H 100M 300V 91.6636%X 465681C Вых:св> "
local BATTLE = "450H 100M 300V 91.6636%X 465681C [Варвар:450] [Равнинный тролль:36] Вых:св> "
local PEACE_LOW = "400H 100M 300V 91.6636%X 465681C Вых:св> "

local function prompt(line)
  currentLine = line
  Bot.on_prompt(line)
end

-- ===== 0. разбор промпта =====
local p = Bot.parse_prompt(BATTLE)
check(p.battle == true and p.target == "Равнинный тролль", "промпт: бой и цель")
check(p.hp == 450 and p.mp == 100 and p.mv == 300, "промпт: HP/MP/MV")
check(p.exits == "св", "промпт: выходы")
local p2 = Bot.parse_prompt(PEACE)
check(p2.battle == false and p2.target == "", "промпт: мирный без цели")
local p3 = Bot.parse_prompt("556H 205M 160V 672MX 1309C [Варвар:100]-[Гоблин:20] [тролль:36] Ч12 Вых:сю> ")
check(p3.battle == true and p3.target == "тролль", "промпт: жертва в скобках и Ч12")

-- ===== 1. блок комнаты и запись маршрута =====
-- этот блок проверяет разбор текста, поэтому текстовый режим включаем явно
Bot.config.mobSource = "text"
msdp.ROOM = { VNUM = 100, NAME = "Старт", EXITS = {} }
Bot.on_msdp_room()
room_block("Старт", { "Острый гарпун лежит тут." })
check(Bot.block.open == true and Bot.block.title == "Старт",
  "блок комнаты открыт по строке выходов, заголовок верный")
prompt(PEACE)
check(#Bot.mobs == 1 and Bot.block.open == false, "блок закрыт, содержимое сохранено")
feed("Маленький зайчик припрыгал с севера.")
check(#Bot.block.lines == 0 and #Bot.mobs == 1,
  "событие между блоками не попало в цели")

Bot.command("запись", "старт testzone")
check(Bot.state == "record", "запись включена")

Bot.record_on_send("юг")
msdp.ROOM = { VNUM = 101, NAME = "Зал", EXITS = {} }
Bot.on_msdp_room()
Bot.record_on_send("восток")
msdp.ROOM = { VNUM = 102, NAME = "Ниша", EXITS = {} }
Bot.on_msdp_room()
Bot.record_action("кзаб :Барб2 все;од все")
Bot.record_on_send("север")
advance(5)
Bot.command("запись", "стоп")

local route, err = Bot.load_zone("testzone")
check(route ~= nil, "маршрут прочитан с диска" .. (err and (" (" .. err .. ")") or ""))
check(route and #route.steps == 3, "в маршруте 3 шага (2 хода + действие)")
check(route and route.steps[1].dir == "юг" and tostring(route.steps[1].room) == "101",
  "первый шаг: юг -> 101")
check(route and route.steps[3].cmd == "кзаб :Барб2 все;од все",
  "действие сохранено как cmd")

-- ===== 2. «имя» строки: до глагола-маркера (для игроков и подписей) =====
check(Bot.line_head("Равнинный тролль стоит тут.") == "Равнинный тролль",
  "line_head: имя до « стоит»")
check(Bot.line_head("Маленький зайчик щиплет здесь травку.") == "Маленький зайчик",
  "line_head: имя до « щиплет»")
check(Bot.line_head("Фаэри Мералион летает здесь. (невидим)") == "Фаэри Мералион",
  "line_head: суффикс «(невидим)» срезается")
check(Bot.line_head("Рохмар Каменный Кулак стоит здесь, сражается с Съезо!")
  == "Рохмар Каменный Кулак", "line_head: хвост «сражается с …» отрезан")
check(Bot.line_head("Королевский боевой маг, предано служит королю.")
  == "Королевский боевой маг, предано", "line_head: обрезка на глаголе «служит»")

-- ===== 3. проход маршрута с мобом =====
Bot.route = { steps = {
  { dir = "юг", room = 101 },
  { dir = "восток", room = 102 },
  { cmd = "кзаб :Барб2 все;од все", room = 102 },
} }
Bot.zone = "testzone"
Bot.i = 1
Bot.state = "walk"
Bot.expect, Bot.awaiting = nil, false
Bot.recover = { step = 0, count = 0, fails = 0 }
Bot.deadline, Bot.waitUntil = 0, 0
Bot.paused, Bot.battle = false, false
-- чистое состояние боя: мобов в «текущей» комнате нет
Bot.mobs = {}
Bot.playerInRoom = false
Bot.combat.attempts = 0
Bot.combat.skipRoom = nil
Bot.combat.engagedAt = 0
msdp.ROOM = { VNUM = 100, NAME = "Старт", EXITS = {} }
Bot.on_msdp_room()

sent = {}
Bot.walk.pulse()
check(sent[#sent] == "юг", "первый ход: юг (получено: " .. tostring(sent[#sent]) .. ")")
check(Bot.expect == "101", "ожидаем VNUM 101")

msdp.ROOM = { VNUM = 101, NAME = "Зал", EXITS = {} }
Bot.on_msdp_room()
local mobs_before = #Bot.mobs
room_block("Зал", { "Равнинный тролль стоит тут." })
check(#Bot.mobs == mobs_before, "до промпта цели ещё не обновлены")
prompt(PEACE)
check(Bot.i == 2, "шаг сдвинут после ack")
check(#Bot.mobs == 1, "после промпта блок закрыт, цель одна")
advance(0.5)
check(expanded[#expanded] == "botkill", "на клетке атака через алиас botkill (получено: " ..
  tostring(expanded[#expanded]) .. ")")
check(sent[#sent] == "clear:" .. attack_cmd,
  "алиас ушёл через sendWithClear (получено: " .. tostring(sent[#sent]) .. ")")

prompt(BATTLE)
check(Bot.battle == true, "бой начался (боевой промпт)")

prompt(PEACE_LOW)
check(Bot.battle == false, "бой закончился")
check(sent[#sent] == "look краткий", "после боя шлём look краткий")
check(Bot.i == 2, "после боя шаг не сдвинулся сам")

Bot.combat.engagedAt = 0   -- бой закончился, грейс-период снят
-- тик в окне ожидания look не должен отправлять ход: иначе ответ look приходит
-- при выставленном expect → desync/recovery и дубль хода
local sent_look_wait = #sent
Bot.tick(Bot.gen)
check(#sent == sent_look_wait,
  "ожидание look: тик не шлёт ход (получено: " .. tostring(sent[#sent]) .. ")")
check(Bot.expect == nil and Bot.lookPending ~= nil,
  "ожидание look: тик не ставит expect, флаг жив")

room_block("Зал", {})
prompt(PEACE)   -- ответ на look: комната пуста
check(sent[#sent] == "восток", "после look продолжаем маршрут (получено: " ..
  tostring(sent[#sent]) .. ")")

msdp.ROOM = { VNUM = 102, NAME = "Ниша", EXITS = {} }
Bot.on_msdp_room()
advance(0.5)
check(expanded[#expanded] == "кзаб :Барб2 все;од все",
  "действие в комнате 102 — как ввод из командной строки (получено: " ..
  tostring(expanded[#expanded]) .. ")")

-- ===== 3б. два действия подряд, первое меняет комнату (регрессия «войти») =====
-- room у действия — комната, где оно выполняется, а не куда ведёт. Смена комнаты
-- (портал) не должна перескакивать следующее действие.
Bot.route = { steps = {
  { dir = "запад", room = 166071 },
  { cmd = "войти", room = 166071 },
  { cmd = "войти", room = 166075 },
  { cmd = "оторвать лепесток", room = 166073 },
} }
Bot.zone = "testzone"
Bot.i = 1
Bot.state = "walk"
Bot.expect, Bot.awaiting = nil, false
Bot.recover = { step = 0, count = 0, fails = 0 }
Bot.deadline, Bot.waitUntil = 0, 0
Bot.paused, Bot.battle = false, false
Bot.mobs, Bot.segment.lines = {}, {}
Bot.walk_repair, Bot.jump = nil, nil
Bot.jumpCounts = {}
Bot.doorAttempts = 0
Bot.hold = nil
Bot.combat.engagedAt = 0
msdp.ROOM = { VNUM = 101046, NAME = "Дорога в гору", EXITS = {} }
Bot.on_msdp_room()

sent = {}
expanded = {}
Bot.walk.pulse()
check(sent[#sent] == "запад", "войти-регрессия: первый ход запад (получено: " ..
  tostring(sent[#sent]) .. ")")

msdp.ROOM = { VNUM = 166071, NAME = "Бездна мира", EXITS = {} }
Bot.on_msdp_room()
advance(0.5)
check(expanded[#expanded] == "войти", "войти-регрессия: первое действие войти (получено: " ..
  tostring(expanded[#expanded]) .. ")")
check(Bot.waiting() == true, "войти-регрессия: бот ждёт смену комнаты после первого войти")

-- «войти» телепортировало в комнату следующего действия — его не пропускаем
msdp.ROOM = { VNUM = 166075, NAME = "Темное облако", EXITS = {} }
Bot.on_msdp_room()
check(Bot.i == 3, "войти-регрессия: второе войти не пропущено (Bot.i=" ..
  tostring(Bot.i) .. ", ждали 3)")

-- перенос подтверждён сменой комнаты — бот сразу продолжает (не ждёт остаток паузы)
advance(0.2)
check(#expanded == 2 and expanded[2] == "войти",
  "войти-регрессия: второе войти выполнено (действий: " .. tostring(#expanded) .. ")")

-- ===== 3в. действие в чужой комнате: ждём комнату (регрессия late-перенос) =====
Bot.route = { steps = {
  { cmd = "войти", room = 166075 },
  { cmd = "оторвать лепесток", room = 166073 },
} }
Bot.zone = "testzone"
Bot.i = 1
Bot.state = "walk"
Bot.expect, Bot.awaiting = nil, false
Bot.recover = { step = 0, count = 0, fails = 0 }
Bot.deadline, Bot.waitUntil = 0, 0
Bot.paused, Bot.battle = false, false
Bot.mobs, Bot.segment.lines = {}, {}
Bot.walk_repair, Bot.jump = nil, nil
Bot.jumpCounts = {}
Bot.doorAttempts = 0
Bot.act_retry = 0
Bot.act_wait = nil
Bot.hold = nil
Bot.combat.engagedAt = 0
-- перенос ещё не завершился: бот стоит в старой комнате
msdp.ROOM = { VNUM = 166071, NAME = "Бездна мира", EXITS = {} }
Bot.on_msdp_room()

sent = {}
expanded = {}
Bot.walk.pulse()
check(#expanded == 0, "late-перенос: действие не выполнено в чужой комнате (действий: " ..
  tostring(#expanded) .. ")")
check(Bot.act_retry == 1, "late-перенос: одна попытка дождаться комнаты (получено " ..
  tostring(Bot.act_retry) .. ")")

-- комната наконец сменилась на нужную — бот выполняет действие
msdp.ROOM = { VNUM = 166075, NAME = "Темное облако", EXITS = {} }
Bot.on_msdp_room()
advance(0.2)
check(expanded[#expanded] == "войти", "late-перенос: действие после прихода в комнату (получено: " ..
  tostring(expanded[#expanded]) .. ")")

-- ===== 4. десинк и recovery по карте =====
Bot.route = { steps = {
  { dir = "юг", room = 201 },
  { dir = "юг", room = 202 },
} }
Bot.i = 1
Bot.state = "walk"
Bot.expect, Bot.awaiting = nil, false
Bot.recover = { step = 0, count = 0, fails = 0 }
Bot.deadline, Bot.waitUntil = 0, 0
Bot.paused, Bot.battle = false, false
Bot.mobs, Bot.segment.lines = {}, {}
msdp.ROOM = { VNUM = 200, NAME = "Площадка", EXITS = {} }
Bot.on_msdp_room()
map.currentRoom = 200
getRoomIDbyHash = function(h) return tonumber(h) end
getRoomHashByID = function() return tostring(msdp.ROOM and msdp.ROOM.VNUM or "") end
getPath = function() speedWalkDir = { "север", "север" } end
Bot.combat.engagedAt = 0

sent = {}
Bot.walk.pulse()
check(sent[#sent] == "юг", "ход к 201 отправлен")
msdp.ROOM = { VNUM = 999, NAME = "Куда-то", EXITS = {} }
Bot.on_msdp_room()
check(Bot.walk_repair ~= nil, "включился recovery по карте")
check(sent[#sent] == "север",
  "recovery идёт по пути карты (получено: " .. tostring(sent[#sent]) .. ")")

msdp.ROOM = { VNUM = 201, NAME = "Зал", EXITS = {} }
Bot.on_msdp_room()
advance(0.5)
check(Bot.walk_repair == nil or #Bot.walk_repair.dirs == 0,
  "recovery: путь отправлен, ждём прибытия")
msdp.ROOM = { VNUM = 201, NAME = "Зал", EXITS = {} }
Bot.on_msdp_room()
advance(0.5)
check(Bot.walk_repair == nil, "recovery завершён, маршрут выровнен")

-- ===== 5. круг =====
Bot.state = "idle"
Bot.command("круг", "z1 z2")
check(#Bot.loop.list == 2, "круг задан")
Bot.command("круг", "+ z2 z3")
check(#Bot.loop.list == 3 and Bot.loop.list[3] == "z3", "круг: зона добавлена")
Bot.command("круг", "- z1")
check(#Bot.loop.list == 2 and Bot.loop.list[1] == "z2", "круг: зона убрана")
sent = {}
Bot.instanceQuery = nil
Bot.command("круг", "")
check(sent[#sent] == "обл" and Bot.instanceQuery == "circle_info",
  "круг: статус спрашивает «обл»")
Bot.instanceQuery = nil
Bot.command("круг", "стоп")
check(#Bot.loop.list == 0, "круг остановлен")
Bot.instanceQuery = nil
Bot.command("репоп", "+ testzone 30")
check(#Bot.loop.list == 1 and Bot.loop.list[1] == "testzone",
  "репоп: перенаправлен в круг (минуты отброшены)")
Bot.instanceQuery = nil
Bot.command("круг", "стоп")

-- ===== 6. анти-бот и пауза =====
antiBotLastSent = 5
sent = {}
Bot.paused = false
Bot.send("север")
check(#sent == 0 and Bot.paused == true, "анти-бот ставит бота на паузу")
antiBotLastSent = 0
Bot.command("пауза", "0")
check(Bot.paused == false, "пауза снимается")

-- ===== 7. закрытая дверь: триггер профиля открывает, бот повторяет шаг =====
-- Двери открывает профильный триггер (он смотрит на глобальную dir), поэтому
-- бот не шлёт «открыть дверь», а просто повторяет тот же шаг.
Bot.route = { steps = { { dir = "север", room = 301 } } }
Bot.i = 1
Bot.state = "walk"
Bot.expect, Bot.awaiting = nil, false
Bot.recover = { step = 0, count = 0, fails = 0 }
Bot.deadline, Bot.waitUntil = 0, 0
Bot.paused, Bot.battle = false, false
Bot.mobs, Bot.segment.lines = {}, {}
Bot.doorAttempts = 0
Bot.walk_repair = nil
Bot.lastFail = ""
msdp.ROOM = { VNUM = 300, NAME = "Дверь", EXITS = {} }
Bot.on_msdp_room()
map.currentRoom = 300
dir = nil
sent = {}
Bot.walk.pulse()
check(sent[#sent] == "север", "дверь: ход отправлен")
check(dir == "север", "дверь: профильному триггеру выставлена dir = «север» (получено " ..
  tostring(dir) .. ")")
Bot.on_blocked_move("дверь", "деревянную дверь")
check(#sent == 1, "дверь: своих команд открытия не шлём — это делает триггер профиля")
check(Bot.doorAttempts == 1, "дверь: одна попытка повтора")
advance(0.5)   -- ждём tempTimer повтора
check(sent[#sent] == "север", "дверь: шаг повторён тем же ходом")
Bot.on_blocked_move("дверь", "деревянную дверь")
advance(0.5)
check(Bot.doorAttempts == 2, "дверь: вторая попытка")
Bot.on_blocked_move("дверь", "деревянную дверь")
advance(0.5)
check(Bot.doorAttempts == 3, "дверь: третья попытка")
Bot.on_blocked_move("дверь", "деревянную дверь")
advance(0.5)
check(Bot.doorAttempts == 4, "дверь: четвёртая попытка")
Bot.on_blocked_move("дверь", "деревянную дверь")
advance(0.5)
check(Bot.doorAttempts == 5, "дверь: пятая попытка")
Bot.on_blocked_move("дверь", "деревянную дверь")
check(Bot.state == "idle", "дверь: лимит 5 повторов — останов")
check(Bot.walk_repair == nil, "дверь: в recovery по карте не уходим")
check(tostring(Bot.lastFail):find("дверь") ~= nil,
  "дверь: причина остановки — дверь (получено: " .. tostring(Bot.lastFail) .. ")")

-- запертая дверь: профильный триггер и отпирает, и открывает — бот только повторяет
Bot.route = { steps = { { dir = "запад", room = 302 } } }
Bot.i = 1
Bot.state = "walk"
Bot.expect, Bot.awaiting = nil, false
Bot.doorAttempts = 0
Bot.deadline, Bot.waitUntil = 0, 0
Bot.paused, Bot.battle = false, false
Bot.mobs = {}
sent = {}
Bot.walk.pulse()
sent = {}
Bot.on_blocked_move("заперто", "деревянную дверь")
check(#sent == 0, "заперто: своих команд бот не шлёт — отпирает триггер профиля")
advance(0.5)
check(sent[#sent] == "запад", "заперто: шаг повторён")

-- «заперт» от контейнера на шаге-действии — не дверь и не повод останавливаться
Bot.route = { steps = { { cmd = "оов 1.сун", room = 304 } } }
Bot.i = 1
Bot.state = "walk"
Bot.expect, Bot.awaiting = nil, false
Bot.doorAttempts = 0
Bot.walk_repair = nil
Bot.lastFail = ""
sent = {}
Bot.on_blocked_move("заперто", "Окованный сундук")
check(Bot.state == "walk" and Bot.doorAttempts == 0 and #sent == 0,
  "контейнер: «заперт» на шаге-действии игнорируется")

-- тот же «заперт» при ожидании хода — тоже контейнер, не дверь
Bot.route = { steps = { { dir = "запад", room = 305 } } }
Bot.i = 1
Bot.state = "walk"
Bot.expect, Bot.awaiting = "305", false
Bot.doorAttempts = 0
Bot.deadline = 0
sent = {}
Bot.on_blocked_move("заперто", "Окованный сундук")
check(Bot.doorAttempts == 0 and Bot.state == "walk" and #sent == 0,
  "контейнер: не считается дверью и не ретраит ход")

-- успешная смена комнаты сбрасывает попытки двери
Bot.route = { steps = { { dir = "юг", room = 306 } } }
Bot.i = 2
Bot.state = "walk"
Bot.expect, Bot.awaiting = nil, false
Bot.doorAttempts = 3
Bot.walk_repair = nil
msdp.ROOM = { VNUM = 306, NAME = "Комната", EXITS = {} }
Bot.on_msdp_room()
check(Bot.doorAttempts == 0, "смена комнаты сбрасывает попытки двери")

-- «Вы не можете идти в этом направлении» — это не дверь: один повтор и стоп
Bot.route = { steps = { { dir = "юг", room = 303 } } }
Bot.i = 1
Bot.state = "walk"
Bot.expect, Bot.awaiting = nil, false
Bot.doorAttempts = 0
Bot.deadline, Bot.waitUntil = 0, 0
Bot.paused, Bot.battle = false, false
Bot.mobs = {}
Bot.lastFail = ""
sent = {}
Bot.walk.pulse()
Bot.on_blocked_move("направление")
advance(0.5)
check(sent[#sent] == "юг", "нет выхода: шаг повторён один раз")
Bot.on_blocked_move("направление")
check(Bot.state == "idle" and Bot.walk_repair == nil,
  "нет выхода: после повтора останавливаемся, а не уходим в карту")

-- запись: дверь не выбрасывает ход, триггер откроет, бот повторит
Bot.command("запись", "старт doortest")
msdp.ROOM = { VNUM = 500, NAME = "Дверь", EXITS = {} }
Bot.on_msdp_room()
Bot.record_on_send("север")
check(#Bot.record.queue == 1, "запись: ход в очереди")
Bot.on_blocked_move("дверь", "деревянную дверь")
check(#Bot.record.queue == 1, "запись: дверь не выбрасывает ход")
advance(0.5)
check(#Bot.record.queue == 1, "запись: повтор не добавил второй ход")
msdp.ROOM = { VNUM = 501, NAME = "За дверью", EXITS = {} }
Bot.on_msdp_room()
check(#Bot.record.steps == 1 and Bot.record.steps[1].dir == "север" and
  tostring(Bot.record.steps[1].room) == "501",
  "запись: ход после двери записан один раз (шагов: " ..
  tostring(#Bot.record.steps) .. ")")
Bot.command("запись", "сброс")

-- ===== 7b. боевые строки — не существа =====
Bot.state = "idle"
Bot.config.mobSource = "auto"
Bot.playerInRoom = false
Bot.block.open = true
Bot.block.title = "Утренний коридор"
Bot.block.lines = {}
Bot.block.color_lines = {}
Bot.block.item_lines = {}
Bot.block.items = 0
Bot.block.has_color = false
Bot.mobs = {}
setFmt(255, 0, 0)
feed("Смотритель проходит тут в поисках нарушителей покоя.")
feed("Смотритель проходит тут в поисках нарушителей покоя.")
feed("Смотритель ударил вас ногой!  ...[14]")
check(Bot.block.open == false, "боевая строка с уроном закрывает блок комнаты")
setFmt(nil)
check(#Bot.mobs == 2, "строка урона не стала мобом (мобов " .. #Bot.mobs .. ")")
check(Bot.is_action_line("Смотритель ударил вас ногой!  ...[14]"), "урон — действие")
check(Bot.is_action_line("Смотритель попытался рубануть вас, но промахнулся."),
  "«попытался … промахнулся» — действие")
check(Bot.is_action_line("Вы полетели на землю от мощного удара! ...[14]"),
  "строка «Вы …» — действие")
check(Bot.is_action_line("Смотритель забился в судорогах.  ...[8] ------------- [ POISON ]"),
  "яд — действие")
check(not Bot.is_action_line("Олень перебирает здесь копытами."),
  "описание моба — не действие")
check(not Bot.is_action_line("Травник бормочет какие-то слова."),
  "заклинание в описании — не действие")
check(not Bot.is_action_line("Личный телохранитель короля стоит здесь, сражается с Съезо!"),
  "«сражается с …» — не действие")

-- ===== 7c. «не бить»: отказ сервера и номер цели =====
Bot.noAttack = {}
Bot.state = "walk"
Bot.route = { steps = { { dir = "юг", room = 401 } } }
Bot.i = 1
Bot.expect, Bot.awaiting = nil, false
Bot.paused, Bot.battle = false, false
Bot.deadline, Bot.waitUntil = 0, 0
Bot.doorAttempts = 0
Bot.walk_repair = nil
Bot.config.restBelow = 0
Bot.config.lowHpPercent = 0
Bot.hp, Bot.hpMax = 1000, 1000
Bot.mv, Bot.mvMax = 1800, 2000
msdp.ROOM = { VNUM = 400, NAME = "Квест", EXITS = {} }
Bot.on_msdp_room()
Bot.mobs = { "Захудалый старикашка сидит тут.",
             "Маленький зайчик щиплет здесь травку." }
Bot.playerInRoom = false
Bot.combat.skipRoom = nil
Bot.combat.attempts = 0
Bot.combat.engagedAt = 0
Bot.combat.target = nil
group_count, pet_count = 1, 0
expanded = {}
Bot.on_attack_refused()
check(Bot.noAttack["400"] ~= nil and
  Bot.noAttack["400"]["Захудалый старикашка сидит тут."] == true,
  "отказ: существо записано в «не бить»")
check(#Bot.combat.mobs() == 1, "отказ: в целях остался только зайчик (мобов " ..
  #Bot.combat.mobs() .. ")")
check(Bot.combat.target == "№3", "номер цели учитывает мирного впереди (получено " ..
  tostring(Bot.combat.target) .. ")")
local noattack_file = io.open(Bot.noattack_path(), "rb")
check(noattack_file ~= nil, "файл noattack.lua создан")
if noattack_file then noattack_file:close() end
Bot.noAttack = {}
Bot.load_noattack()
check(Bot.is_noattack("Захудалый старикашка сидит тут.") == true,
  "список «не бить» читается из файла")
Bot.noattack_room_clear("400")
check(Bot.is_noattack("Захудалый старикашка сидит тут.") == false,
  "сброс комнаты очищает список")
Bot.mobs = {}

-- ===== 7c-2. отказ сервера без бота: правила не меняем =====
Bot.state, Bot.zone = "idle", nil
Bot.noAttack = {}
Bot.mobs = { "Захудалый старикашка сидит тут." }
Bot.combat.skipRoom = nil
Bot.combat.attempts = 3
Bot.combat.engagedAt = 0
Bot.on_attack_refused()
check(next(Bot.noAttack) == nil, "простой: отказ не пишет «не бить»")
check(Bot.combat.skipRoom == nil, "простой: комната не пропускается")
check(Bot.combat.attempts == 3, "простой: счётчики боя не трогаются")

Bot.mobs = {}
Bot.on_attack_refused()
check(Bot.combat.skipRoom == nil, "простой без списка существ: комната не пропускается")

-- запись: отказ по-прежнему попадает в record.noattack
Bot.state = "record"
Bot.record.name = "testzone"
Bot.record.noattack = {}
Bot.mobs = { "Захудалый старикашка сидит тут." }
Bot.on_attack_refused()
check(Bot.record.noattack["400"] and
  Bot.record.noattack["400"]["Захудалый старикашка"] == true,
  "запись: отказ запоминается в record.noattack")
Bot.record.name, Bot.record.noattack = nil, {}
Bot.mobs = {}
Bot.state = "walk"

-- ===== 7d. экземпляр зоны уже есть — не ждём entryWait =====
Bot.route = { steps = { { dir = "север", room = 401 } } }
Bot.i = 1
Bot.state = "entry"
Bot.entry = { vnum = "400", dir = "север", maxdiff = 2, title = "Тест" }
Bot.entryDone = true
Bot.entryDeadline = Bot.now() + 5
Bot.paused, Bot.battle = false, false
Bot.deadline, Bot.waitUntil = 0, 0
Bot.mobs = {}
Bot.combat.engagedAt = 0
Bot.combat.skipRoom = nil
sent = {}
Bot.on_zone_cooldown("Башня магов", "33 минуты 58 секунд")
check(Bot.state == "walk", "кулдаун: сразу начинаем проход (состояние " ..
  tostring(Bot.state) .. ")")
check(Bot.entryDeadline == 0, "кулдаун: таймер ожидания сброшен")
Bot.state, Bot.route = "idle", nil

-- ===== 23b. сервер отказал в сложности: +3 → +2 → +1 → обычная → стоп =====
local zd, zt = Bot.parse_zone_diff_refused(
  "Для создания области зоны 'Башня магов' сложности +3 вы должны 10 раз выполнить задание в области сложности +2.")
check(zd == 3 and zt == 10, "сложность: отказ разобран (получено " ..
  tostring(zd) .. "/" .. tostring(zt) .. ")")
local zd2, zt2 = Bot.parse_zone_diff_refused(
  "Для создания области зоны 'Башня магов' сложности +1 вы должны еще 4 раза выполнить задание в области обычной сложности.")
check(zd2 == 1 and zt2 == 4, "сложность: «еще 4 раза» разобрано (получено " ..
  tostring(zd2) .. "/" .. tostring(zt2) .. ")")
local zd0 = Bot.parse_zone_diff_refused(
  "Для создания области зоны 'Башня магов' обычной сложности вы должны 2 раза выполнить задание.")
check(zd0 == 0, "сложность: обычная сложность разобрана (получено " ..
  tostring(zd0) .. ")")
check(Bot.diff_arg(0) == "" and Bot.diff_arg(nil) == "",
  "сложность: 0 = без +N")
Bot.state = "entry"
Bot.entry = { dir = "запад", maxdiff = 3, num = 110, title = "Башня магов" }
Bot.entryDone = true
Bot.entryTryDiff = 3
Bot.entryTried = { [3] = true }
Bot.entryDeadline = 0
Bot.paused = false
Bot.lastFail = ""
sent = {}
Bot.on_zone_diff_refused(3, 10)
check(sent[#sent] == "гг !обл созда запад +2" and Bot.entryTryDiff == 2,
  "сложность: +3 недоступна — пробуем +2 (получено " ..
  tostring(sent[#sent]) .. ")")
Bot.on_zone_diff_refused(2, 10)
check(sent[#sent] == "гг !обл созда запад +1" and Bot.entryTryDiff == 1,
  "сложность: +2 недоступна — пробуем +1")
Bot.on_zone_diff_refused(1, 4)
check(sent[#sent] == "гг !обл созда запад" and Bot.entryTryDiff == 0,
  "сложность: +1 недоступна — пробуем обычную без +N (получено " ..
  tostring(sent[#sent]) .. ")")
Bot.on_zone_diff_refused(0, 4)
check(Bot.state == "idle" and tostring(Bot.lastFail):find("обычная сложность") ~= nil,
  "сложность: обычная недоступна — стоп (получено: " .. tostring(Bot.lastFail) .. ")")

-- entry_begin при maxdiff=0 шлёт команду без +N
Bot.state, Bot.entry, Bot.entryDone = "idle", { dir = "запад", maxdiff = 0, num = 1, title = "Тест" }, false
Bot.entryTryDiff, Bot.entryTried, Bot.entryDeadline = nil, nil, 0
sent = {}
Bot.entry_begin()
check(sent[#sent] == "гг !обл созда запад",
  "старт: обычная сложность — без +N (получено " .. tostring(sent[#sent]) .. ")")
Bot.state, Bot.entry, Bot.entryDone, Bot.entryDeadline = "idle", nil, false, 0

-- вне entry отказ игнорируется
Bot.state = "idle"
Bot.entry = { dir = "запад", maxdiff = 3 }
sent = {}
Bot.on_zone_diff_refused(3, 10)
check(#sent == 0, "сложность: вне entry не трогаем")
Bot.entry, Bot.entryTryDiff, Bot.entryTried = nil, nil, nil

-- ===== 7e. действия из маршрута — как ввод из командной строки =====
expanded = {}
sent = {}
check(Bot.run_action("оов шкаф") == true, "действие: отправлено")
check(expanded[#expanded] == "оов шкаф",
  "действие раскрывается через expandAlias (получено: " ..
  tostring(expanded[#expanded]) .. ")")
check(#sent == 0, "действие не уходит напрямую в send")
Bot.config.expandActions = false
expanded = {}
sent = {}
Bot.run_action("оов шкаф")
check(#expanded == 0 and sent[#sent] == "оов шкаф",
  "expandActions=false — прямой send")
Bot.config.expandActions = true
expanded = {}
sent = {}
dir = nil
Bot.run_action("север")
check(#expanded == 0 and sent[#sent] == "север", "ход алиасом не раскрывается")
check(dir == "север", "ход по-прежнему выставляет dir для триггера двери")

-- шаг-действие в маршруте идёт через run_action
Bot.route = { steps = { { cmd = "оов шкаф", room = 700 } } }
Bot.i = 1
Bot.state = "walk"
Bot.expect, Bot.awaiting = nil, false
Bot.deadline, Bot.waitUntil = 0, 0
Bot.paused, Bot.battle = false, false
Bot.mobs = {}
Bot.doorAttempts = 0
Bot.walk_repair = nil
msdp.ROOM = { VNUM = 700, NAME = "Шкаф", EXITS = {} }
Bot.act_retry = 0
Bot.act_wait = nil
expanded = {}
sent = {}
Bot.walk.pulse()
check(expanded[#expanded] == "оов шкаф", "шаг-действие выполняется через алиасы")
Bot.state, Bot.route = "idle", nil

-- ===== 7f. ошибка в тике не останавливает бота =====
local realPanel = Bot.panelUpdate
Bot.lastError = ""
Bot.panelUpdate = function() error("тестовая ошибка из панели") end
local beforeTick = Bot.timers.tick
advance(1.5)
check(tostring(Bot.lastError):find("тестовая ошибка") ~= nil,
  "ошибка в тике видна в логе (получено: " .. tostring(Bot.lastError) .. ")")
check(Bot.timers.tick ~= beforeTick, "тик пере-планирован после ошибки")
Bot.panelUpdate = realPanel
Bot.lastError = ""

-- ===== 7g. ошибка колбэка Bot.later видна и не ломает бота =====
Bot.lastError = ""
Bot.later(0.1, "тест", function() error("бум в колбэке") end)
advance(0.2)
check(tostring(Bot.lastError):find("бум в колбэке") ~= nil,
  "ошибка колбэка попала в лог (получено: " .. tostring(Bot.lastError) .. ")")
Bot.lastError = ""

-- ===== 7h. бой: перед второй попыткой обновляем комнату =====
msdp.ROOM = { VNUM = 400, NAME = "Квест", EXITS = {} }
Bot.on_msdp_room()
Bot.noAttack = {}
Bot.mobs = { "Равнинный тролль стоит тут." }
Bot.playerInRoom = false
Bot.state = "walk"
Bot.route = { steps = { { dir = "юг", room = 401 } } }
Bot.i = 1
Bot.expect, Bot.awaiting = nil, false
Bot.deadline, Bot.waitUntil = 0, 0
Bot.paused, Bot.battle = false, false
Bot.doorAttempts = 0
Bot.walk_repair = nil
Bot.combat.room = "400"
Bot.combat.attempts = 1
Bot.combat.refreshed = nil
Bot.combat.skipRoom = nil
Bot.combat.engagedAt = 0
Bot.combat.attacked = nil
Bot.attack = Bot.attack_default()
sent = {}
Bot.combat.engage()
check(sent[#sent] == "look краткий",
  "бой: вместо слепого удара обновляем комнату (получено: " ..
  tostring(sent[#sent]) .. ")")
Bot.mobs = {}
Bot.combat.engagedAt = 0
sent = {}
check(Bot.combat.engage() == nil, "бой: свежая комната без мобов — не бьём")
Bot.state, Bot.route = "idle", nil

-- ===== 7i. один botkill на комнату, а не по числу мобов =====
Bot.state = "walk"
Bot.zone = nil
Bot.route = { steps = { { dir = "юг", room = 402 } } }
Bot.i = 1
Bot.expect, Bot.awaiting = nil, false
Bot.paused, Bot.battle = false, false
Bot.deadline, Bot.waitUntil = 0, 0
Bot.combat.room = nil
Bot.combat.attacked = nil
Bot.combat.attempts = 0
Bot.combat.refreshed = nil
Bot.combat.skipRoom = nil
Bot.combat.engagedAt = 0
Bot.config.skipFightWithPlayer = false
Bot.attack = Bot.attack_default()
Bot.mobs = {
  "Равнинный тролль стоит тут.",
  "Маленький зайчик щиплет здесь травку.",
  "Олень перебирает здесь копытами.",
}
Bot.playerInRoom = false
msdp.ROOM = { VNUM = 402, NAME = "Зал", EXITS = {} }
Bot.on_msdp_room()
sent = {}
Bot.combat.engage()
check(sent[#sent] == "clear:" .. attack_cmd, "один botkill: атака отправлена")
check(Bot.combat.attacked == true, "один botkill: комната помечена")
-- бой закончился, а список мобов ещё старый: второй раз не бьём
Bot.battle, Bot.combat.engagedAt = false, 0
sent = {}
check(Bot.combat.should_fight() == false,
  "один botkill: в той же комнате больше не бьём")
Bot.combat.engage()
check(#sent == 0, "один botkill: повторный engage ничего не шлёт")
-- в другой комнате снова можно
msdp.ROOM = { VNUM = 403, NAME = "Другая", EXITS = {} }
Bot.on_msdp_room()
check(Bot.combat.should_fight() == true,
  "один botkill: в другой комнате бой снова разрешён")
Bot.mobs = {}
Bot.state, Bot.route = "idle", nil

-- ===== 8. блок: дубли мобов, служебные строки, события вне блока =====
Bot.state = "walk"
Bot.config.mobSource = "text"
Bot.mobs, Bot.segment.lines = {}, {}
Bot.block.open, Bot.block.lines = false, {}
feed("Олень ускакал на юг.")                 -- событие вне блока
check(#Bot.block.lines == 0, "событие вне блока не цель")
room_block("Тропинка в саду", {
  "Олень перебирает здесь копытами.",
  "Олень перебирает здесь копытами.",        -- два одинаковых моба
  "[Зона, на север: Затерянный остров, ур. 15-25]",
  "(mapper): Adding open door to the west",
  "+---+   +---+",
  "Маленький зайчик щиплет здесь травку.",
})
prompt(PEACE)
check(#Bot.mobs == 3, "в цели попали только строки содержимого (получено " ..
  tostring(#Bot.mobs) .. ")")
check(Bot.mobs[1] == Bot.mobs[2], "одинаковые строки мобов не схлопнулись")
check(Bot.block.open == false, "блок закрыт промптом")

-- ===== 9. отдых по выносливости =====
Bot.route = { steps = { { dir = "юг", room = 250 }, { dir = "юг", room = 251 } } }
Bot.i = 1
Bot.state = "walk"
Bot.expect, Bot.awaiting = nil, false
Bot.deadline, Bot.waitUntil = 0, 0
Bot.paused, Bot.battle = false, false
Bot.mobs, Bot.segment.lines = {}, {}
Bot.combat.engagedAt = 0
Bot.walk_repair = nil
Bot.config.restBelow = 500
Bot.config.restAbove = 0.85
Bot.mv, Bot.mvMax = 120, 2000
Bot.rest.active = false
sent = {}
Bot.walk.pulse()
check(sent[#sent] == "отдых", "при низкой выносливости шлём отдых (получено: " ..
  tostring(sent[#sent]) .. ")")
check(Bot.rest.active == true, "режим отдыха включён")
Bot.mv = 1800
check(Bot.rest_tick() == false, "отдых закончился при достижении цели")
check(sent[#sent] == "встать", "после отдыха встаём")
Bot.config.restBelow = 0

-- ===== 10. стоп по низкому HP =====
Bot.config.lowHpPercent = 0.3
Bot.hp, Bot.hpMax = 100, 1000
Bot.route = { steps = { { dir = "юг", room = 250 } } }
Bot.i = 1
Bot.state = "walk"
Bot.expect, Bot.awaiting = nil, false
Bot.waitUntil, Bot.deadline, Bot.battle = 0, 0, false
Bot.paused = false
Bot.mobs, Bot.segment.lines = {}, {}
Bot.combat.engagedAt = 0
Bot.rest.active = false
Bot.walk_repair = nil
sent = {}
Bot.walk.pulse()
check(Bot.state == "idle", "при низком HP бот останавливается")
check(Bot.lastFail:find("HP") ~= nil, "причина остановки — HP")
Bot.config.lowHpPercent = 0
Bot.hp, Bot.hpMax = 1000, 1000

-- ===== 11. рассинхрон карты: recovery не строится =====
Bot.route = { steps = { { dir = "юг", room = 401 } } }
Bot.i = 1
Bot.state = "walk"
Bot.expect, Bot.awaiting = nil, false
Bot.recover = { step = 0, count = 0, fails = 0 }
Bot.deadline, Bot.waitUntil = 0, 0
Bot.paused, Bot.battle = false, false
Bot.mobs, Bot.segment.lines = {}, {}
Bot.lastFail = ""
msdp.ROOM = { VNUM = 400, NAME = "Старт", EXITS = {} }
Bot.on_msdp_room()
map.currentRoom = 400
getRoomIDbyHash = function(h) return tonumber(h) end
getPath = function() speedWalkDir = { "север" } end
getRoomHashByID = function() return "999" end   -- карта стоит не там, где игрок
sent = {}
Bot.walk.pulse()
msdp.ROOM = { VNUM = 777, NAME = "Куда-то", EXITS = {} }
Bot.on_msdp_room()
check(Bot.state == "idle", "при рассинхроне карты бот останавливается")
check(Bot.lastFail:find("карта стоит") ~= nil,
  "сообщение про рассинхрон карты (получено: " .. tostring(Bot.lastFail) .. ")")

-- ===== 12. msdp.ROOM.EXITS как предпроверка хода =====
local function try_move(exits, dir, room)
  Bot.route = { steps = { { dir = dir, room = room } } }
  Bot.i = 1
  Bot.state = "walk"
  Bot.expect, Bot.awaiting = nil, false
  Bot.recover = { step = 0, count = 0, fails = 0 }
  Bot.deadline, Bot.waitUntil = 0, 0
  Bot.paused, Bot.battle = false, false
  Bot.mobs, Bot.segment.lines = {}, {}
  Bot.block.open, Bot.block.lines = false, {}
  Bot.combat.engagedAt = 0
  Bot.rest.active, Bot.walk_repair = false, nil
  Bot.config.restBelow, Bot.config.lowHpPercent = 0, 0
  Bot.lastFail = ""
  msdp.ROOM = { VNUM = 500, NAME = "Площадка", EXITS = exits }
  Bot.on_msdp_room()
  sent = {}
  Bot.walk.pulse()
  return sent[#sent]
end

check(try_move({ N = 501, S = 500 }, "север", 501) == "север",
  "EXITS: выход совпал с VNUM маршрута — идём")
check(Bot.expect == "501", "EXITS: ждём VNUM из маршрута")

try_move({ N = 999 }, "север", 501)
check(Bot.state == "idle" and tostring(Bot.lastFail):find("маршрут устарел") ~= nil,
  "EXITS: выход ведёт в другой VNUM — маршрут устарел (получено: " ..
  tostring(Bot.lastFail) .. ")")

check(try_move({ E = 505 }, "север", 501) == "север",
  "EXITS: выход не показан — пробуем всё равно")

-- ===== 12b. динамический выход: VNUM есть в маршруте — продолжаем с него =====
local djump = {
  steps = {
    { dir = "запад", room = 160017 },
    { dir = "запад", room = 160016 },
    { dir = "восток", room = 160017 },
    { dir = "восток", room = 160002 },
    { dir = "юг", room = 160016 },
    { dir = "восток", room = 160023 },
  },
}
local function dyn_move(i, vnum, exits)
  Bot.route = djump
  Bot.i = i
  Bot.state = "walk"
  Bot.expect, Bot.awaiting = nil, false
  Bot.recover = { step = 0, count = 0, fails = 0 }
  Bot.deadline, Bot.waitUntil = 0, 0
  Bot.paused, Bot.battle = false, false
  Bot.mobs = {}
  Bot.walk_repair, Bot.jump = nil, nil
  Bot.doorAttempts = 0
  Bot.combat.engagedAt = 0
  Bot.config.restBelow, Bot.config.lowHpPercent = 0, 0
  Bot.config.dynamicResyncLimit = 3
  Bot.lastFail = ""
  msdp.ROOM = { VNUM = vnum, NAME = "Комната", EXITS = exits or {} }
  Bot.on_msdp_room()
  sent = {}
  Bot.walk.pulse()
end

dyn_move(6, 160016, { ["восток"] = 160017 })
check(sent[#sent] == "восток", "динамический выход: ход всё равно отправлен")
check(Bot.expect == "160017", "динамический выход: ждём фактический VNUM")
check(Bot.jump ~= nil and Bot.jump.resume == 4,
  "динамический выход: сверка на шаг 4 (получено " ..
  tostring(Bot.jump and Bot.jump.resume) .. ")")
msdp.ROOM = { VNUM = 160017, NAME = "Комната", EXITS = {} }
Bot.on_msdp_room()
check(Bot.i == 4, "динамический выход: продолжаем с шага 4 (получено " ..
  tostring(Bot.i) .. ")")
check(Bot.jump == nil, "динамический выход: сверка сброшена")

-- тот же VNUM вне маршрута — стоп
dyn_move(6, 160016, { ["восток"] = 160099 })
check(Bot.state == "idle" and Bot.lastFail:find("160099") ~= nil,
  "динамический выход: VNUM нет в маршруте — стоп (получено: " ..
  tostring(Bot.lastFail) .. ")")

-- повторные сверки в тот же VNUM — стоп по лимиту
Bot.jumpCounts = {}
for n = 1, 3 do
  dyn_move(6, 160016, { ["восток"] = 160017 })
  check(Bot.state == "walk", "динамический выход: сверка " .. n .. "/3")
end
dyn_move(6, 160016, { ["восток"] = 160017 })
check(Bot.state == "idle" and Bot.lastFail:find("зациклилась") ~= nil,
  "динамический выход: после лимита — стоп (получено: " ..
  tostring(Bot.lastFail) .. ")")
Bot.jumpCounts, Bot.state = nil, "idle"

-- ===== 13. запись: очередь ходов, отложенные шаги, пауза =====
Bot.state = "idle"
Bot.config.waitAfterMove = 3
Bot.command("запись", "старт qzone")
check(Bot.state == "record", "запись qzone начата")

-- быстрый ввод: два хода до подтверждений
Bot.record_on_send("юг")
Bot.record_on_send("восток")
check(#Bot.record.queue == 2, "два хода в очереди (получено " ..
  tostring(#Bot.record.queue) .. ")")

-- действие, набранное до подтверждения ходов, откладывается
Bot.record_action("кзаб все")
check(#Bot.record.deferred == 1 and #Bot.record.steps == 0,
  "действие отложено до подтверждения ходов")

msdp.ROOM = { VNUM = 601, NAME = "A", EXITS = {} }
Bot.on_msdp_room()
check(#Bot.record.steps == 1 and Bot.record.steps[1].room == "601" and
  #Bot.record.queue == 1, "первый ход подтверждён, второй ждёт")
check(#Bot.record.deferred == 1, "действие ещё отложено")

msdp.ROOM = { VNUM = 602, NAME = "B", EXITS = {} }
Bot.on_msdp_room()
check(#Bot.record.steps == 3, "после очереди добавлено отложенное действие")
check(Bot.record.steps[3].cmd == "кзаб все" and Bot.record.steps[3].room == "602",
  "действие привязано к комнате 602")

Bot.record_wait(3)
check(#Bot.record.steps == 4 and Bot.record.steps[4].wait == 3,
  "пауза записана шагом { wait = 3 }")

Bot.command("запись", "стоп")
local qroute = Bot.load_zone("qzone")
check(qroute ~= nil and #qroute.steps == 4, "маршрут с паузой сохранён")
check(qroute ~= nil and qroute.steps[4].wait == 3, "wait сохранился в файле")

-- выполнение паузы при проходе
Bot.route, Bot.i = qroute, 4
Bot.state = "walk"
Bot.expect, Bot.awaiting = nil, false
Bot.deadline, Bot.waitUntil = 0, 0
Bot.paused, Bot.battle = false, false
Bot.mobs, Bot.segment.lines = {}, {}
Bot.combat.engagedAt = 0
Bot.walk_repair = nil
Bot.queue = {}
sent = {}
Bot.walk.pulse()
check(Bot.waiting() == true and #sent == 0,
  "шаг wait ставит паузу и не отправляет команд")
advance(3.5)
check(Bot.waiting() == false, "пауза завершилась по времени")

-- просроченный ход выбрасывается, следующее действие пишется уже в текущую комнату
Bot.state = "idle"
Bot.command("запись", "старт q2")
Bot.record_on_send("север")
advance(5)
Bot.record_expire()
check(#Bot.record.queue == 0 and Bot.record.drops == 1,
  "просроченный ход выброшен (drops=" .. tostring(Bot.record.drops) .. ")")
Bot.record_action("после")
check(#Bot.record.steps == 1 and Bot.record.steps[1].cmd == "после",
  "действие после сброса очереди записано сразу")
Bot.command("запись", "сброс")

-- ===== 14. стоп записи при неподтверждённом ходе =====
Bot.state = "idle"
Bot.command("запись", "старт q3")
Bot.record_on_send("запад")
Bot.record_wait(2)                 -- отложится: ход ещё в очереди
Bot.command("запись", "стоп")      -- не ждём подтверждения
local q3 = Bot.load_zone("q3")
check(q3 ~= nil and #q3.steps == 1, "при стопе неподтверждённый ход выброшен")
check(q3 ~= nil and q3.steps[1].wait == 2, "отложенная пауза зафиксирована")
check(Bot.record.drops >= 1, "потерянный ход посчитан")

-- ===== 15. способ атаки: по умолчанию botkill, меняется .бот атака =====
Bot.attack = Bot.attack_default()
check(Bot.attack.mode == "botkill" and Bot.attack.alias == "botkill",
  "атака по умолчанию — botkill")

-- номер цели: я №1, дальше согрупники и петы
group_count, pet_count = 1, 0
check(Bot.target_number(1) == 2, "один в комнате: первый моб — №2 (получено " ..
  tostring(Bot.target_number(1)) .. ")")
group_count, pet_count = 14, 0
check(Bot.target_number(1) == 15, "группа 14: первый моб — №15")
check(Bot.target_number(3) == 17, "третий моб — №17")
group_count, pet_count = 14, 2
check(Bot.target_number(1) == 17, "петы тоже сдвигают номер (14+2+1)")
group_count, pet_count = 1, 0

-- режим command: шаблон с %n
Bot.command("атака", "команда kill %n")
check(Bot.attack.mode == "command" and Bot.attack.template == "kill %n",
  "режим command сохранён")
local attack_file = io.open(Bot.attack_path(), "rb")
check(attack_file ~= nil, "файл attack.lua создан")
if attack_file then
  local text = attack_file:read("*a")
  attack_file:close()
  check(text:find('mode = "command"') ~= nil and text:find("kill %%n") ~= nil,
    "режим записан в файл")
end
sent = {}
check(Bot.attack_do() == true, "атака command отправлена")
check(sent[#sent] == "clear:kill 2", "шаблон подставил номер (получено " ..
  tostring(sent[#sent]) .. ")")

group_count = 13
sent = {}
Bot.attack_do()
check(sent[#sent] == "clear:kill 14", "в группе 13 номер цели — 14 (получено " ..
  tostring(sent[#sent]) .. ")")
group_count = 1

Bot.attack = Bot.attack_default()
Bot.load_attack()
check(Bot.attack.mode == "command" and Bot.attack.template == "kill %n",
  "режим перечитан из файла")

-- режим alias: свой алиас профиля
Bot.command("атака", "alias бой")
check(Bot.attack.mode == "alias" and Bot.attack.alias == "бой", "режим alias сохранён")
expanded = {}
Bot.attack_do()
check(expanded[#expanded] == "бой", "alias зовёт expandAlias (получено " ..
  tostring(expanded[#expanded]) .. ")")

-- алиаса нет: запасной kill <номер>
Bot.attack = { mode = "alias", alias = "неттакого" }
sent = {}
Bot.attack_do()
check(sent[#sent] == "clear:kill 2", "нет алиаса — шлём kill <номер> (получено " ..
  tostring(sent[#sent]) .. ")")

-- режим lua: код выполняется, target — номер цели
lua_target = nil
Bot.command("атака", "lua lua_target = target")
check(Bot.attack.mode == "lua" and Bot.attack.code == "lua_target = target",
  "режим lua сохранён")
Bot.attack_do()
check(lua_target == 2, "lua: target = номер цели (получено " .. tostring(lua_target) .. ")")

local bad_code = Bot.attack.code
Bot.command("атака", "lua это не lua")
check(Bot.attack.code == bad_code, "некомпилируемый код отклонён")

-- алиас сообщил, что ничего не отправил (пустой getAttack/антибот)
Bot.attack = Bot.attack_default()
local real_expand = expandAlias
expandAlias = function(name)
  expanded[#expanded + 1] = name
  Bot._attackSent = false
end
check(Bot.attack_do() == false, "алиас не отправил — attack_do вернул false")
expandAlias = real_expand

-- антибот: атаку не отправляем и ставим паузу
Bot.attack = Bot.attack_default()
antiBotLastSent = 5
expanded = {}
check(Bot.attack_do() == false, "антибот: атака не отправлена")
check(Bot.paused == true and #expanded == 0, "антибот: бот на паузе, алиас не звали")
antiBotLastSent = 0
Bot.paused = false

-- пауза бота: атаку не отправляем
Bot.paused = true
expanded = {}
check(Bot.attack_do() == false and #expanded == 0, "пауза: атака не отправляется")
Bot.paused = false

-- .бот бить — ручная атака текущим способом
Bot.mobs = { "Равнинный тролль стоит тут." }
assist_who = nil
Bot.playerInRoom = false
expanded = {}
check(Bot.combat.manual() == true, "бить: атака отправлена")
check(expanded[#expanded] == "botkill", "бить: зовёт настроенный способ атаки")
Bot.mobs = {}

-- сброс к дефолту
Bot.command("атака", "сброс")
check(Bot.attack.mode == "botkill" and Bot.attack.alias == "botkill", "сброс на botkill")
Bot.attack = Bot.attack_default()
Bot.load_attack()
check(Bot.attack.mode == "botkill" and Bot.attack.alias == "botkill",
  "дефолт перечитан из файла")

-- ===== 16. .бот цель: имена, игроки и номера для боя =====
Bot.zone = nil
Bot.mobs = { "Равнинный тролль стоит тут.", "Маленький зайчик щиплет здесь травку." }
Bot.loreCache = {}
Bot.attack = Bot.attack_default()
group_count, pet_count = 1, 0
local out = {}
local real_echo = Bot.echo
local function capture(fn)
  out = {}
  Bot.echo = function(msg) out[#out + 1] = tostring(msg) end
  fn()
  Bot.echo = real_echo
end
local function has(needle)
  for _, line in ipairs(out) do
    if line:find(needle, 1, true) then return true end
  end
  return false
end
capture(function() Bot.command("цель", "") end)
check(#out >= 4, "цель: заголовок, атака и мобы (получено " .. tostring(#out) .. ")")
check(has("мобов 2") and has("group_count 1"), "цель: заголовок с числами")
check(has("атака:") and has("botkill"), "цель: способ атаки")
check(not has("лор "), "цель: лор больше не упоминается")
check(has("№2") and has("Равнинный тролль стоит тут."),
  "цель: первый моб — строка как есть, №2 (group_count+pet_count+k)")
check(has("№3") and has("Маленький зайчик щиплет здесь травку."),
  "цель: второй моб — строка как есть, №3")

-- игроки — короткое имя (до глагола), мобы — строка с суффиксами
assist_who = { ["Мералион"] = "Мералион" }
Bot.mobs = {
  "Фаэри Мералион летает здесь. (невидим)",
  "Стражник стоит здесь. ...огненный щит",
}
capture(function() Bot.command("цель", "") end)
check(has("игроки (не бьются)") and has("Фаэри Мералион"), "цель: игрок коротко")
check(not has("Фаэри Мералион летает"), "цель: у игрока нет хвоста действия")
check(has("№3") and has("Стражник стоит здесь. ...огненный щит"),
  "цель: моб показан как есть, с суффиксом (игрок в комнате занимает своё место)")
assist_who = nil

group_count = 13
capture(function() Bot.command("цель", "") end)
check(has("group_count 13"), "цель: group_count берётся из профиля")
check(has("№14"), "цель: в группе 13 первый моб — №14")
group_count, pet_count = 1, 0

-- ===== 17. источник мобов: только красные строки =====
Bot.config.mobSource = "color"
Bot.block.open = true
Bot.block.lines = { "Вы находитесь в главном холле башни." }
Bot.block.color_lines = { "Хмурого вида тип стоит тут." }
Bot.commit_packet()
check(#Bot.mobs == 1 and Bot.mobs[1] == "Хмурого вида тип стоит тут.",
  "цвет: описание комнаты не попало в цели")
check(Bot.mobSourceUsed == "color", "источник — цвет")

-- не красная строка (событие/проза) — не моб, боя нет
Bot.block.open = true
Bot.block.lines = { "Руна на стене вспыхнула, указывая на восток." }
Bot.block.color_lines = {}
Bot.commit_packet()
check(#Bot.mobs == 0 and Bot.mobSourceUsed == "color",
  "не красная строка — не моб (цвет-only)")
Bot.playerInRoom = false
Bot.combat.engagedAt = 0
Bot.combat.skipRoom = nil
Bot.paused, Bot.battle = false, false
check(Bot.combat.should_fight() == false, "не красный моб — боя нет")

-- предметы (жёлтые) считаем, но в цели не берём
Bot.block.open = true
Bot.block.lines = { "Вы находитесь в зале." }
Bot.block.color_lines = { "Хмурого вида тип стоит тут." }
Bot.block.items = 0
currentLine = "Острый гарпун лежит тут."
Bot.on_room_line("item")
check(Bot.block.items == 1, "предмет посчитан отдельно")
Bot.commit_packet()
check(#Bot.mobs == 1 and Bot.mobs[1] == "Хмурого вида тип стоит тут.",
  "предмет не попал в цели")
check(Bot.itemsSeen == 1, "itemsSeen запомнен")

Bot.config.mobSource = "text"
Bot.block.open = true
Bot.block.lines = { "Олень перебирает здесь копытами." }
Bot.block.color_lines = { "Хмурого вида тип стоит тут." }
Bot.commit_packet()
check(Bot.mobSourceUsed == "text" and Bot.mobs[1] == "Олень перебирает здесь копытами.",
  "принудительно text: берём текстовые строки")
Bot.config.mobSource = "color"

-- ===== 18. текстовый фильтр описания комнаты (цветов нет) =====
local desc = {
  "Тонкая деревянная перегородка отделяет вас от огромного склада на севере, в",
  "котором хранится множество интересных вещей. Здесь можно встретить кладовщика,",
  "постоянно занятого сортировкой имущества. На перегородке стоит маленький звонок,",
  "с помощью которого можно вызвать кладовщика из глубин склада.",
}
local real_mobs = {
  "Малыш Делг стоит здесь.",
  "Фаэри Арлиша летает здесь.",
  "Пещерный тролль Кофл стоит здесь.",
  "Человек Сателайза стоит здесь.",
  "Матушка Элсэри, море из нарисованных слез стоит здесь.",
  "Усатый кладовщик раскладывает какое-то имущество.",
}
Bot.zone = nil
Bot.config.mobSource = "text"
Bot.block.open = true
Bot.block.color_lines = {}
Bot.block.lines = {}
for _, line in ipairs(desc) do Bot.block.lines[#Bot.block.lines + 1] = line end
for _, line in ipairs(real_mobs) do Bot.block.lines[#Bot.block.lines + 1] = line end
Bot.commit_packet()
check(#Bot.mobs == #real_mobs, "описание отфильтровано, мобов " .. tostring(#Bot.mobs))
check(Bot.mobSourceUsed == "text", "источник — текст")
for i = 1, #real_mobs do
  check(Bot.mobs[i] == real_mobs[i], "моб " .. i .. " на месте: " .. tostring(Bot.mobs[i]))
end
check(Bot.looks_like_mob("Острый гарпун лежит тут.") == true,
  "предмет выглядит как моб (отсеет лор)")
check(Bot.looks_like_mob("с помощью которого можно вызвать кладовщика.") == false,
  "продолжение описания со строчной — не моб")
check(Bot.looks_like_mob("Вы находитесь в главном холле башни.") == false,
  "строка «Вы …» — не моб")

-- ===== 19. игроки того же цвета, что мобы: только assist_who =====
assist_who = { ["Вася"] = "Вася" }
check(Bot.is_protected("Вася стоит тут.") == true, "is_protected по assist_who")
check(Bot.is_protected("Землекоп занят тут своей работой.") == false, "моб не защищён")

Bot.zone = nil
Bot.config.mobSource = "auto"
Bot.playerInRoom = false
Bot.block.open = true
Bot.block.lines = {}
Bot.block.color_lines = { "Землекоп занят тут своей работой.", "Вася стоит тут." }
Bot.commit_packet()
check(Bot.playerInRoom == true, "игрок в комнате отмечен")
local creatures = Bot.combat.creatures()
check(#creatures == 2, "в комнате два существа")
local players = Bot.combat.players()
local plain_mobs = Bot.combat.mobs()
check(#players == 1 and players[1].name == "Вася стоит тут.",
  "игрок из assist_who отмечен как игрок")
check(#plain_mobs == 1 and plain_mobs[1].name == "Землекоп занят тут своей работой.",
  "моб не игрок")
check(Bot.target_number(1) == 2, "номер моба считается от group_count")
Bot.battle = false
Bot.combat.engagedAt = 0
Bot.combat.skipRoom = nil
Bot.combat.attacked = nil
check(Bot.combat.should_fight() == true, "в комнате есть моб — бой разрешён")

capture(function() Bot.command("цель", "") end)
check(has("игроки (не бьются)") and has("Вася"), "цель: игрок в разделе «не бьются»")
assist_who = nil

-- ===== 20. assist_who: свои (группа и петы) не бьются =====
assist_who = { ["Мералион"] = "Мералион", ["Элсэри"] = "Элсэри" }
check(Bot.assist_contains("Фаэри Мералион летает здесь.") == true,
  "assist: имя как отдельное слово")
check(Bot.assist_contains("Мералиончик летает здесь.") == false,
  "assist: часть слова не считается")
check(Bot.assist_contains("Матушка Элсэри, море из нарисованных слез стоит здесь.") == true,
  "assist: имя в середине строки")
check(Bot.is_protected("Фаэри Мералион") == true, "assist: защищён по имени")
check(Bot.assist_count() == 2, "assist: счётчик имён")

Bot.config.mobSource = "auto"
Bot.playerInRoom = false
Bot.block.open = true
Bot.block.lines = {}
Bot.block.color_lines = { "Фаэри Мералион летает здесь.", "Землекоп занят тут своей работой." }
Bot.commit_packet()
check(Bot.playerInRoom == true, "assist: в комнате свой — игрок отмечен")
local assist_mobs = Bot.combat.mobs()
check(#assist_mobs == 1 and assist_mobs[1].name == "Землекоп занят тут своей работой.",
  "assist: свой не попал в мобы")
check(#Bot.combat.players() == 1, "assist: свой — игрок")

-- в группе бой разрешён: согрупники пропускаются по group_count
group_count = 14
Bot.playerInRoom = false
Bot.block.open = true
Bot.block.lines = {}
Bot.block.color_lines = { "Фаэри Мералион летает здесь.", "Землекоп занят тут своей работой." }
Bot.commit_packet()
Bot.battle = false
Bot.combat.engagedAt = 0
Bot.combat.skipRoom = nil
Bot.combat.attacked = nil
check(Bot.combat.should_fight() == true,
  "в группе бой разрешён (skipFightWithPlayer=false)")
check(Bot.target_number(1) == 15, "первый моб в группе 14 — №15")

Bot.config.skipFightWithPlayer = true
check(Bot.combat.should_fight() == false, "skipFightWithPlayer=true блокирует бой")
Bot.config.skipFightWithPlayer = false
group_count = 1
assist_who = nil

-- ===== 21. цвет строки: моб/предмет/проза (getTextFormat → {r,g,b}) =====
check(Bot.color_kind(255, 0, 0) == "mob", "цвет: чистый красный — моб")
check(Bot.color_kind(255, 85, 85) == "mob", "цвет: светлый красный — моб")
check(Bot.color_kind(255, 255, 0) == "item", "цвет: чистый жёлтый — предмет")
check(Bot.color_kind(255, 255, 128) == "item", "цвет: светлый жёлтый — предмет")
check(Bot.color_kind(192, 192, 192) == nil, "цвет: серая проза — не моб")
check(Bot.color_kind(128, 255, 255) == nil, "цвет: светлый циан (заголовок) — не моб")
check(Bot.color_kind(0, 128, 0) == nil, "цвет: зелёный (промпт) — не моб")
check(Bot.color_kind({ 255, 0, 0 }) == "mob", "цвет: таблица {r,g,b} — моб")
check(Bot.color_kind(255) == "mob", "цвет: целое 0xBBGGRR (совместимость)")
check(Bot.color_kind(nil) == nil, "цвет: нет цвета — не моб")

-- цвет берётся из getTextFormat().foreground
setFmt(192, 192, 192)
local lr, lg, lb = Bot.line_rgb()
check(lr == 192 and lg == 192 and lb == 192, "line_rgb: серый из getTextFormat")
setFmt(nil)
check(Bot.line_rgb() == nil, "line_rgb: нет формата — nil")

Bot.config.mobSource = "auto"
Bot.zone = nil
Bot.loreCache = {}
Bot.playerInRoom = false
Bot.block.open = true
Bot.block.title = "Пещера"
Bot.block.lines = {}
Bot.block.color_lines = {}
Bot.block.item_lines = {}
Bot.block.items = 0
setFmt(128, 255, 255)
feed("Пещера")
setFmt(192, 192, 192)
feed("исписаны непонятными рунами. Врата в царство мертвых призвать охранять огромный")
setFmt(255, 0, 0)
feed("Землекоп занят тут своей работой.")
setFmt(255, 255, 0)
feed("Острый гарпун лежит тут.")
setFmt(nil)
Bot.commit_packet()
check(#Bot.mobs == 1 and Bot.mobs[1] == "Землекоп занят тут своей работой.",
  "цвет: в мобы попала только красная строка")
check(Bot.mobSourceUsed == "color", "цвет: источник — цвет")
check(Bot.itemsSeen == 1, "цвет: жёлтая строка посчитана предметом")

-- текстовый резерв: заголовок и предметы мобами не становятся
Bot.config.mobSource = "text"
Bot.block.open = true
Bot.block.title = "Пещера"
Bot.block.lines = {}
Bot.block.color_lines = {}
Bot.block.item_lines = {}
Bot.block.items = 0
setFmt(128, 255, 255)
feed("Пещера")
setFmt(192, 192, 192)
feed("исписаны непонятными рунами. Врата в царство мертвых призвать охранять огромный")
setFmt(255, 255, 0)
feed("Труп Гарма лежит тут.")
setFmt(nil)
Bot.commit_packet()
check(#Bot.mobs == 0, "text: заголовок и предмет не стали мобами")
Bot.config.mobSource = "auto"

-- строки ошибок Mudlet не становятся мобами
Bot.block.open = true
Bot.block.lines = {}
Bot.block.color_lines = {}
Bot.block.item_lines = {}
Bot.block.items = 0
feed("ERROR: invalid line number")
feed("Lua: getTextFormat: no character under cursor or selection in window 'main'")
Bot.commit_packet()
check(#Bot.mobs == 0, "строки «ERROR: …» и «Lua: …» от Mudlet игнорируются")

-- продолжение описания моба («...») не становится отдельной целью
Bot.config.mobSource = "auto"
Bot.block.open = true
Bot.block.title = "Пещера"
Bot.block.lines = {}
Bot.block.color_lines = { "Безликая душа блуждает царством мертвых.", "...светится розовым сиянием." }
Bot.block.item_lines = {}
Bot.block.items = 0
setFmt(nil)
Bot.commit_packet()
check(#Bot.mobs == 1 and Bot.mobs[1] == "Безликая душа блуждает царством мертвых.",
  "цвет: строка-продолжение «...» не цель")

-- промпт приходит как обычная строка и обновляет HP/бой (prompt-триггер не нужен)
Bot.mobs = {}
Bot.battle = false
feed("1234H 567M 890V 50.0000%X 1000C Вых:СЮ> ")
check(Bot.hp == 1234 and Bot.mp == 567 and Bot.mv == 890, "промпт из строки: HP/MP/MV")
feed("1000H 500M 800V 50.0000%X 1000C [Варвар:1000] [Равнинный тролль:36] Вых:СЮ> ")
check(Bot.battle == true and Bot.target == "Равнинный тролль", "промпт из строки: бой и цель")
check(#Bot.mobs == 0, "строка промпта не попала в мобы")

-- ===== 22. тронный зал: игрок в «сражается с …», конец блока =====
assist_who = { ["Съезо"] = "Съезо", ["Мряка"] = "Мряка" }
check(Bot.line_head("Личный телохранитель короля стоит здесь, сражается с Съезо!")
  == "Личный телохранитель короля", "line_head: имя до глагола")
check(Bot.is_protected("Личный телохранитель короля стоит здесь, сражается с Съезо!") == false,
  "упоминание игрока в «сражается с …» не делает моба игроком")
check(Bot.is_protected("Коррупция Съезо сидит здесь, сражается с личным телохранителем короля!")
  == true, "сам игрок по-прежнему защищён")

Bot.zone = nil
Bot.loreCache = {}
Bot.config.mobSource = "auto"
Bot.block.open = true
Bot.block.title = "Тронный зал"
Bot.block.lines = {}
Bot.block.color_lines = {}
Bot.block.item_lines = {}
Bot.block.items = 0
Bot.block.has_color = false
Bot.playerInRoom = false
setFmt(255, 0, 0)
feed("Коррупция Съезо сидит здесь, сражается с личным телохранителем короля!")
feed("Личный телохранитель короля стоит здесь, сражается с Съезо!")
feed("Рохмар Каменный Кулак стоит здесь, сражается с Съезо!")
setFmt(192, 192, 192)
feed("Личный телохранитель короля попытался огреть Денара, но он уклонился.")
setFmt(255, 0, 0)
feed("Вы полетели на землю от мощного удара личного телохранителя короля! ...[14]")
setFmt(nil)
check(Bot.block.open == false, "тронный зал: блок закрыт на нецветной строке")
check(#Bot.mobs == 3, "тронный зал: в блоке 3 красные строки (получено " .. #Bot.mobs .. ")")
local throne_mobs = Bot.combat.mobs()
check(#throne_mobs == 2 and
  throne_mobs[1].name == "Личный телохранитель короля стоит здесь, сражается с Съезо!" and
  throne_mobs[2].name == "Рохмар Каменный Кулак стоит здесь, сражается с Съезо!",
  "тронный зал: мобы без игроков")
check(#Bot.combat.players() == 1, "тронный зал: игрок Съезо распознан")
assist_who = nil
Bot.set_room_fight(false)   -- в блоке были «сражается …»: состояние комнаты сбрасываем

-- ===== 23. вход в зону: «обл и», клетка входа, «гг !обл созда» =====
local realGetRoom = getRoomIDbyHash
getRoomIDbyHash = function(h)
  if tostring(h) == "100051" then return 1716 end
  return realGetRoom(h)
end
Bot.mobs = {}
Bot.battle = false
Bot.paused = false

-- разбор ответа «обл и»
Bot.record.name = "фрегат"
Bot.record.entry = { vnum = "100051" }
Bot.probe_reset()
feed("Наличие смежных зон:")
feed("       На юге: [472] Королевский фрегат")
feed("               Сложность макс: 2, текущая: 0, прохождений: 0")
feed("")
check(Bot.record.entry.dir == "юг" and Bot.record.entry.maxdiff == 2 and
  Bot.record.entry.num == 472 and Bot.record.entry.title == "Королевский фрегат",
  "обл и: направление, [номер], название и сложность")
check(Bot.probe.open == false, "обл и: блок закрыт пустой строкой")

-- несколько смежных зон: выбираем по имени записи, сложность — из своей строки
Bot.record.entry = { vnum = "100051" }
Bot.probe_reset()
feed("Наличие смежных зон:")
feed("       На севере: [500] Снежные пещеры")
feed("               Сложность макс: 5, текущая: 1, прохождений: 2")
feed("       На юге: [472] Королевский фрегат")
feed("               Сложность макс: 3, текущая: 0, прохождений: 0")
feed("")
check(Bot.record.entry.dir == "юг" and Bot.record.entry.maxdiff == 3 and
  Bot.record.entry.num == 472, "обл и: несколько зон — выбрана по имени записи")

-- резерв: строка «[Зона, на восток: …]» в блоке комнаты
Bot.zoneHint = nil
feed("[Зона, на восток: Пиратский остров, ур. 40-45]")
check(Bot.zoneHint and Bot.zoneHint.dir == "восток" and
  Bot.zoneHint.title == "Пиратский остров", "подсказка направления из «[Зона, …]»")

-- запись: клетка входа — текущая комната, бот сам спрашивает «обл и»
Bot.record.name = nil
Bot.record.entry = nil
Bot.state = "idle"
msdp.ROOM = { VNUM = 100051, NAME = "Корабельный причал", EXITS = {} }
Bot.on_msdp_room()
sent = {}
Bot.command("запись", "старт фрегат")
check(Bot.record.entry ~= nil and Bot.record.entry.vnum == "100051",
  "запись: клетка входа запомнена")
check(sent[#sent] == "обл и", "запись: бот сам спросил «обл и» (получено " ..
  tostring(sent[#sent]) .. ")")
Bot.command("запись", "вход + юг 2")
check(Bot.record.entry.dir == "юг" and Bot.record.entry.maxdiff == 2,
  "запись: вход задан вручную")
Bot.command("запись", "стоп")
local saved = Bot.load_zone("фрегат")
check(saved ~= nil and saved.entry ~= nil and saved.entry.vnum == "100051" and
  saved.entry.dir == "юг" and saved.entry.maxdiff == 2,
  "запись: entry сохранён в файл маршрута")

-- для запуска нужен непустой маршрут
Bot.save_zone("фрегат", {
  entry = saved.entry,
  steps = { { dir = "юг", room = 472001 } },
})
Bot.zones["фрегат"] = nil

-- запуск: уже на клетке входа → сразу «гг !обл созда»
msdp.ROOM = { VNUM = 100051, NAME = "Корабельный причал", EXITS = {} }
Bot.on_msdp_room()
sent = {}
Bot.begin_zone("фрегат")
check(Bot.state == "entry", "старт: фаза entry (уже на клетке входа)")
check(sent[#sent] == "гг !обл созда юг +2", "старт: «!обл созда» отправлен (получено " ..
  tostring(sent[#sent]) .. ")")
check(Bot.entryTryDiff == 2, "старт: первая попытка сложности +2")
check(Bot.diff_arg(3) == "+3" and Bot.diff_arg("+3") == "+3" and
  Bot.diff_arg(-1) == "-1", "сложность в «!обл созда» — со знаком +")
Bot.save_zone("difftest", {
  entry = { vnum = "1", dir = "юг", maxdiff = "+3" },
  steps = { { dir = "юг", room = 2 } },
})
Bot.zones["difftest"] = nil
local difftest = Bot.load_zone("difftest")
check(difftest and difftest.entry.maxdiff == 3, "файл: «+3» читается как число 3")
Bot.on_zone_spawn("Королевский фрегат")
check(Bot.state == "walk", "старт: по «Создан экземпляр зоны» начинается проход")

-- запуск с другой клетки → бег через MudMapper (куп 2), затем «!обл созда»
Bot.zones["фрегат"] = nil
msdp.ROOM = { VNUM = 500000, NAME = "Склад", EXITS = {} }
Bot.on_msdp_room()
mudGoto = nil
sent = {}
Bot.begin_zone("фрегат")
check(Bot.state == "transit" and mudGoto ~= nil and mudGoto.vnum == "100051" and
  mudGoto.portal == "куп 2", "старт: бег к клетке входа (MudMapper, куп 2)")
msdp.ROOM = { VNUM = 100051, NAME = "Корабельный причал", EXITS = {} }
Bot.on_msdp_room()
check(Bot.state == "entry" and sent[#sent] == "гг !обл созда юг +2",
  "старт: на клетке входа — «!обл созда» (state=" .. tostring(Bot.state) ..
  ", sent=" .. table.concat(sent, " | ") .. ")")

-- таймаут ожидания создания зоны: всё равно начинаем проход
Bot.config.entryWait = -1
Bot.zones["фрегат"] = nil
Bot.begin_zone("фрегат")
check(Bot.state == "entry", "старт: ждём создания зоны")
Bot.tick(Bot.gen)
check(Bot.state == "walk", "старт: таймаут «Создан экземпляр зоны» — идём дальше")
Bot.config.entryWait = 5

-- старый маршрут с transit = { vnum, portal }: только бег, без «!обл созда»
local legacy = io.open(Bot.zone_path("legacy"), "wb")
legacy:write('return { transit = { vnum = "100051", portal = "куп 1" }, ' ..
  'steps = { { dir = "юг", room = 1 } } }\n')
legacy:close()
Bot.zones["legacy"] = nil
msdp.ROOM = { VNUM = 500000, NAME = "Склад", EXITS = {} }
Bot.on_msdp_room()
mudGoto = nil
sent = {}
Bot.begin_zone("legacy")
check(Bot.state == "transit" and mudGoto ~= nil and mudGoto.vnum == "100051",
  "старый transit: бег к клетке входа")
msdp.ROOM = { VNUM = 100051, NAME = "Корабельный причал", EXITS = {} }
Bot.on_msdp_room()
local oblSent = false
for _, cmd in ipairs(sent) do
  if cmd:find("гг !обл созда", 1, true) then oblSent = true end
end
check(Bot.state == "walk" and not oblSent, "старый transit: без «!обл созда», сразу проход (state=" ..
  tostring(Bot.state) .. ", sent=" .. table.concat(sent, " | ") .. ")")

-- маршрут без entry: сразу проход
Bot.save_zone("plain", { steps = { { dir = "юг", room = 1 } } })
Bot.zones["plain"] = nil
msdp.ROOM = { VNUM = 500000, NAME = "Склад", EXITS = {} }
Bot.on_msdp_room()
sent = {}
Bot.begin_zone("plain")
check(Bot.state == "walk", "маршрут без entry: сразу проход")

-- ===== 24. два типа зон: all/list, цели, агрессоры, миграция «не бить» =====
Bot.state = "idle"
Bot.record_reset()
Bot.record.entry = nil
Bot.zone = nil
msdp.ROOM = { VNUM = 600, NAME = "Зал", EXITS = {} }
Bot.on_msdp_room()
Bot.target = ""
Bot.battle = false

-- all: любое существо — цель
Bot.save_zone("zonemix", {
  mode = "all",
  steps = { { dir = "юг", room = 600 }, { dir = "восток", room = 601 } },
})
Bot.zones["zonemix"] = nil
local mix = Bot.load_zone("zonemix")
Bot.zone = "zonemix"
check(mix ~= nil and mix.mode == "all", "all: режим по умолчанию")
check(Bot.rule_target("Равнинный тролль стоит тут.") == true, "all: любое существо — цель")

-- list: бьём только kill ∪ aggro
mix.mode = "list"
mix.kill = { ["Ученик магов"] = true }
Bot.invalidate_rules("zonemix")
check(Bot.rule_target("Ученик магов бормочет заклинание.") == true, "list: цель бьётся")
check(Bot.rule_target("Равнинный тролль стоит тут.") == false, "list: не цель — мимо")
Bot.mobs = { "Ученик магов бормочет заклинание.", "Равнинный тролль стоит тут." }
local list_targets = Bot.combat.mobs()
check(#list_targets == 1 and list_targets[1].name == "Ученик магов бормочет заклинание.",
  "list: в авто-целях только список (получено " .. tostring(#list_targets) .. ")")
Bot.mobs = { "Равнинный тролль стоит тут." }
check(#Bot.combat.mobs() == 0, "list: чужой моб не атакуется")

-- агрессор: «напала на вас» учится и бьётся всегда
check(Bot.aggro_scan("Пещерная тварь напала на вас!") == true,
  "aggro: строка «напала на вас» выучена")
check(mix.aggro["Пещерная тварь"] == true, "aggro: записан в файл зоны")
Bot.mobs = { "Пещерная тварь стоит здесь." }
check(#Bot.combat.mobs() == 1, "aggro: агрессор бьётся и в режиме list")
check(Bot.aggro_scan("Вы ударили противника.") == false, "aggro: «Вы …» не агрессор")

-- номер цели: не-цель впереди занимает своё место в комнате
group_count, pet_count = 1, 0
Bot.attack = Bot.attack_default()
Bot.combat.attempts, Bot.combat.engagedAt, Bot.combat.skipRoom = 0, 0, nil
Bot.mobs = { "Равнинный тролль стоит тут.", "Пещерная тварь стоит здесь." }
expanded, sent = {}, {}
Bot.combat.attack()
check(Bot.combat.target == "№3", "list: цель №3 (второй моб при group_count 1), получено " ..
  tostring(Bot.combat.target))

-- регистр и короткое имя из промпта: «Маленький зайчик» ↔ «зайчик»
mix.kill = { ["Маленький зайчик"] = true }
Bot.invalidate_rules("zonemix")
Bot.save_zone_rules("zonemix")
Bot.mobs = { "Маленький зайчик щиплет здесь травку." }
check(Bot.rule_target("Маленький зайчик щиплет здесь травку.") == true,
  "list: имя цели найдено по «имени до глагола»")
Bot.target = "зайчик"
check(Bot.rule_target("Маленький зайчик щиплет здесь травку.") == true,
  "list: короткое имя из промпта тоже цель")
Bot.target = ""

-- файл: mode/kill/aggro/noattack сохраняются и читаются
Bot.zones["zonemix"] = nil
local saved = Bot.load_zone("zonemix")
check(saved.mode == "list" and saved.kill["Маленький зайчик"] == true and
  saved.aggro["Пещерная тварь"] == true, "файл зоны: mode/kill/aggro на диске")
check(type(saved.noattack) == "table", "старый файл без noattack читается")

-- .бот бить при записи: цель попадает в record.kill и в файл зоны
Bot.zone = nil
Bot.state = "idle"
Bot.command("запись", "старт listzone список")
check(Bot.record.mode == "list", "запись: тип «список» принят")
Bot.mobs = { "Ученик магов бормочет заклинание." }
Bot.combat.manual()
check(Bot.record.kill["Ученик магов"] == true, "бить при записи: цель в record.kill")
Bot.mark_noattack("610", "Захудалый старикашка сидит тут.")
Bot.record_on_send("юг")
msdp.ROOM = { VNUM = 610, NAME = "Зал", EXITS = {} }
Bot.on_msdp_room()
Bot.record.entry = { vnum = "600", dir = "юг", maxdiff = 1 }
Bot.command("запись", "стоп")
Bot.zones["listzone"] = nil
local lz = Bot.load_zone("listzone")
check(lz ~= nil and lz.mode == "list", "запись: режим «список» сохранён")
check(lz and lz.kill["Ученик магов"] == true, "запись: цель сохранена в kill зоны")
check(lz and lz.noattack["610"] and lz.noattack["610"]["Захудалый старикашка"] == true,
  "запись: «не бить» сохранено в зоне")

-- повторная запись того же маршрута не теряет накопленные списки
Bot.zone = nil
Bot.state = "idle"
Bot.command("запись", "старт listzone список")
Bot.record.kill = { ["Второй ученик"] = true }
Bot.record.aggro = { ["Пещерная тварь"] = true }
Bot.record.entry = { vnum = "600", dir = "юг", maxdiff = 1 }
Bot.command("запись", "стоп")
Bot.zones["listzone"] = nil
local lz2 = Bot.load_zone("listzone")
check(lz2 and lz2.kill["Ученик магов"] and lz2.kill["Второй ученик"],
  "перезапись: старые и новые цели слились")
check(lz2 and lz2.aggro["Пещерная тварь"] and lz2.noattack["610"],
  "перезапись: агрессоры и «не бить» сохранились")

-- ключи имён: регистр, «имя до глагола», незнакомый глагол
check(Bot.fold("Пещерная ТВАРЬ") == "пещерная тварь", "fold: русский регистр")
check(Bot.has_word("Маленький зайчик щиплет травку.", "зайчик") == true,
  "has_word: короткое имя как отдельное слово")
check(Bot.mob_key("Захудалый старикашка сидит тут.") == "Захудалый старикашка",
  "mob_key: имя до известного глагола")
check(Bot.mob_key("Ученик магов бормочет заклинание.") == "Ученик магов",
  "mob_key: незнакомый глагол — режем по строчному слову с 3-го")
check(Bot.mob_key("Пещерная тварь") == "Пещерная тварь",
  "mob_key: два слова имени не режутся")

-- миграция noattack.lua → зона
Bot.noAttack = { ["620"] = { ["Захудалый старикашка сидит тут."] = true } }
Bot.save_noattack()
Bot.save_zone("migzone", { mode = "list", steps = { { dir = "юг", room = 620 } } })
Bot.zones["migzone"] = nil
local mg = Bot.load_zone("migzone")
check(mg and mg.noattack["620"] and mg.noattack["620"]["Захудалый старикашка"] == true,
  "миграция: «не бить» переехало в файл зоны")
check(Bot.noAttack["620"] == nil, "миграция: комната убрана из глобального списка")
Bot.load_noattack()
check(Bot.noAttack["620"] == nil, "миграция: noattack.lua очищен на диске")

-- .бот режим переключает тип уже записанной зоны
Bot.zone = nil
Bot.command("режим", "zonemix все")
Bot.zones["zonemix"] = nil
check(Bot.load_zone("zonemix").mode == "all", "режим: all сохранён")
Bot.command("режим", "zonemix список")
Bot.zones["zonemix"] = nil
check(Bot.load_zone("zonemix").mode == "list", "режим: список сохранён")

-- .бот цель помечает цели и «мимо»
Bot.zone = "zonemix"
Bot.mobs = { "Равнинный тролль стоит тут.", "Пещерная тварь стоит здесь." }
capture(function() Bot.command("цель", "") end)
check(has("режим список, целей 1"), "цель: в list показано число целей")
check(has("(мимо — не цель)") and has("(цель)"), "цель: пометки «мимо» и «цель»")

Bot.mobs = {}
Bot.zone = nil
Bot.noAttack = {}
Bot.save_noattack()

-- ===== 25. строка триггера из matches[2], цвет по capture-группе =====
Bot.block.open = true
Bot.block.lines = {}
currentLine = "СОВСЕМ ДРУГАЯ СТРОКА"
Bot.on_text_line("Стражник стоит здесь.")
check(Bot.block.lines[1] == "Стражник стоит здесь.",
  "строка триггера берётся из аргумента, а не из getCurrentLine")
Bot.block.open, Bot.block.lines = false, {}
Bot.segment.lines = {}
Bot.on_text_line("ERROR: invalid line number")
check(#Bot.segment.lines == 0, "служебная строка Mudlet пропускается")

setFmt(255, 0, 0)
local cr, cg = Bot.line_rgb(2)
check(cr == 255 and cg == 0 and selectedCapture == 2,
  "line_rgb: цвет по selectCaptureGroup(2)")
local realCapture = selectCaptureGroup
selectCaptureGroup = function() return -1 end
setFmt(0, 255, 0)
local fr, fg2 = Bot.line_rgb(2)
check(fr == 0 and fg2 == 255, "line_rgb: fallback на selectCurrentLine без capture")
selectCaptureGroup = realCapture
setFmt(nil)
currentLine = ""

-- ===== 26. MapperEchoFix: map.echo/map.echon без getCurrentLine =====
map.echo = function() end
map.echon = function() end
dofile(BASE .. "mapperEchoFix.lua")
check(map.echo == MapperEchoFix.echo and map.echon == MapperEchoFix.echon,
  "MapperEchoFix: map.echo/map.echon подменены")
currentLine = "непустая"
check(MapperEchoFix.current_line() == "непустая",
  "MapperEchoFix: последняя строка читается через getLines")
local out = {}
local realDecho, realCecho, realEcho = decho, cecho, echo
decho = function(s) out[#out + 1] = tostring(s) end
cecho = function(s) out[#out + 1] = tostring(s) end
echo = function(s) out[#out + 1] = tostring(s) end
MapperEchoFix.print_one("тест")
decho, cecho, echo = realDecho, realCecho, realEcho
check(table.concat(out, ""):find("тест", 1, true) ~= nil,
  "MapperEchoFix: сообщение выводится без getCurrentLine")
currentLine = ""

-- debug-сообщения map.echo печатаются только при включённом map debug
local function capture_echo(fn)
  local buf = {}
  decho = function(s) buf[#buf + 1] = tostring(s) end
  cecho = function(s) buf[#buf + 1] = tostring(s) end
  echo = function(s) buf[#buf + 1] = tostring(s) end
  fn()
  decho, cecho, echo = realDecho, realCecho, realEcho
  return table.concat(buf, "")
end
map.configs = { debug = false }
local dbg_out = capture_echo(function() MapperEchoFix.echo("MudMapper: тест", true) end)
check(dbg_out == "", "MapperEchoFix: debug молчит при map debug off")
map.configs.debug = true
dbg_out = capture_echo(function() MapperEchoFix.echo("MudMapper: тест", true) end)
check(dbg_out:find("MudMapper: тест", 1, true) ~= nil,
  "MapperEchoFix: debug печатается при map debug on")
local plain_out = capture_echo(function() MapperEchoFix.echo("обычное", false) end)
check(plain_out:find("обычное", 1, true) ~= nil,
  "MapperEchoFix: обычные сообщения печатаются всегда")
map.configs.debug = false

-- ===== 27. .бот продолжить: остановка запоминает шаг =====
Bot.config.mobSource = "color"
Bot.state = "idle"
Bot.paused = false
Bot.resume = nil
Bot.hp, Bot.hpMax = 1000, 1000
Bot.mv, Bot.mvMax = 1800, 2000
Bot.config.restBelow = 0
Bot.config.lowHpPercent = 0
Bot.config.lookEveryCell = false
Bot.entryDone = false
Bot.save_zone("resumezone", {
  entry = { vnum = "700", dir = "юг", maxdiff = 1 },
  steps = {
    { dir = "юг", room = 701 },
    { dir = "восток", room = 702 },
    { dir = "север", room = 703 },
  },
})
Bot.zones["resumezone"] = nil
local rdata = Bot.load_zone("resumezone")
Bot.route, Bot.zone = rdata, "resumezone"
Bot.entry = rdata.entry
Bot.i = 2
msdp.ROOM = { VNUM = 701, NAME = "Зал", EXITS = {} }
Bot.on_msdp_room()
Bot.stop("тест")
check(Bot.resume ~= nil and Bot.resume.zone == "resumezone" and Bot.resume.i == 2,
  "стоп: точка продолжения сохранена")
check(Bot.route == nil and Bot.i == 0, "стоп: маршрут и шаг очищены")

sent = {}
Bot.mobs, Bot.battle, Bot.paused = {}, false, false
Bot.combat.engagedAt, Bot.combat.skipRoom = 0, nil
Bot.command("продолжить", "")
check(Bot.state == "walk" and Bot.i == 2, "продолжить: state=walk, шаг 2 (получено " ..
  tostring(Bot.i) .. ")")
check(Bot.entryDone == true, "продолжить: экземпляр зоны не создаём")
check(sent[#sent] == "восток", "продолжить: сразу идём шаг 2 (получено " ..
  tostring(sent[#sent]) .. ")")
Bot.state, Bot.resume = "idle", nil

-- стоим уже в комнате шага i → продолжаем со следующего
Bot.route, Bot.zone = rdata, "resumezone"
Bot.entry, Bot.i = rdata.entry, 2
msdp.ROOM = { VNUM = 702, NAME = "Ниша", EXITS = {} }
Bot.on_msdp_room()
Bot.stop("тест")
sent = {}
Bot.mobs, Bot.battle, Bot.paused = {}, false, false
Bot.combat.engagedAt, Bot.combat.skipRoom = 0, nil
Bot.command("продолжить", "")
check(Bot.state == "walk" and Bot.i == 3, "продолжить: уже в комнате шага — идём дальше")
Bot.state, Bot.resume = "idle", nil

-- чужая комната: продолжение отменяется, точка сохраняется
Bot.route, Bot.zone = rdata, "resumezone"
Bot.entry, Bot.i = rdata.entry, 2
msdp.ROOM = { VNUM = 999, NAME = "Куда-то", EXITS = {} }
Bot.on_msdp_room()
Bot.stop("тест")
Bot.command("продолжить", "")
check(Bot.state ~= "walk" and Bot.resume ~= nil,
  "продолжить: чужой VNUM — отмена, точка сохранена")

-- нового запуска/финиша точка не переживает
Bot.start({ "неттакой" })
check(Bot.resume == nil, "старт: точка продолжения очищена")
Bot.resume = { zone = "resumezone", i = 1 }
Bot.route, Bot.zone, Bot.i = rdata, "resumezone", 2
Bot.state, Bot.stats = "walk", nil
Bot.finish_zone("тест")
check(Bot.resume == nil, "конец зоны: точка продолжения очищена")
Bot.state = "idle"

-- ===== 28. «обл»: экземпляры зон и круг =====
Bot.instance_probe_reset()
Bot.instances = {}
Bot.instanceQuery = nil
check(Bot.instance_probe_line("Ваши экземпляры зон:") == true,
  "обл: блок открыт")
Bot.instance_probe_line(" Статус  Номер  Название    Лидер      Репоп  Таймер")
Bot.instance_probe_line(" активен  138   Муравейник  Барг         60   1 минута 29 секунд")
Bot.instance_probe_line(" активен  466   Хельхейм    Элронг      180   удалите вручную")
Bot.instance_probe_line("Использование:")
local mi = Bot.instances["муравейник"]
check(mi ~= nil, "обл: Муравейник разобран")
check(mi and mi.seconds == 89 and mi.repop == 60,
  "обл: 1м29с и период 60 (получено " .. tostring(mi and mi.seconds) .. "/" ..
  tostring(mi and mi.repop) .. ")")
check(Bot.instances["хельхейм"] and Bot.instances["хельхейм"].manual == true,
  "обл: «удалите вручную»")

-- имена: «Башня магов» ↔ файл башня_магов
Bot.instances["башня магов"] = { name = "Башня магов", seconds = 5 }
Bot.zones["башня_магов"] = { entry = { title = "Башня магов" }, steps = {} }
check(Bot.instance_for("башня_магов") ~= nil, "обл: имя с _ и пробелом совпадает")
Bot.zones["башня_магов"] = nil

-- .бот обл отправляет «обл»
sent = {}
Bot.instanceQuery = nil
Bot.paused = false
antiBotLastSent = 0
Bot.command("обл", "")
check(sent[#sent] == "обл" and Bot.instanceQuery == "show", "обл: команда отправлена")
Bot.instanceQuery = nil

-- круг: активную зону пропускаем, свободную запускаем
local started
local realBegin = Bot.begin_zone
Bot.begin_zone = function(z) started = z end
Bot.state = "idle"
Bot.paused = false
antiBotLastSent = 0
Bot.instanceQuery = nil
Bot.loop = { list = { "муравейник", "тоннель_бесов" }, idx = 0, deleteAt = {} }
Bot.instances = { ["муравейник"] = { seconds = 89, manual = false } }
Bot.instancesAt = Bot.now()
started = nil
local circle_started = Bot.circle_step()
check(circle_started == true and started == "тоннель_бесов" and Bot.loop.idx == 2,
  "круг: активную зону пропустил, свободную запустил")

-- все зоны заняты — ждём
Bot.loop = { list = { "муравейник" }, idx = 0, deleteAt = {} }
Bot.instances = { ["муравейник"] = { seconds = 89 } }
Bot.instancesAt = Bot.now()
started = nil
local circle_wait = Bot.circle_step()
check(circle_wait == false and started == nil, "круг: все зоны заняты — ждём (очередь идёт)")

-- «удалите вручную» — сначала обл удалить <направление>
Bot.loop = { list = { "хельхейм" }, idx = 0, deleteAt = {} }
Bot.instances = { ["хельхейм"] = { manual = true } }
Bot.instancesAt = Bot.now()
Bot.zones["хельхейм"] = { entry = { dir = "запад" }, steps = {} }
sent = {}
started = nil
local circle_deleted = Bot.circle_step()
check(sent[#sent] == "обл удалить запад" and Bot.circleDelete ~= nil and
  started == nil and circle_deleted == false,
  "круг: «удалите вручную» — удаляем и ждём проверку")
Bot.circleDelete = nil
Bot.instanceQuery = nil

-- после удаления зоны нет в «обл» — стартуем её
Bot.instances = {}
Bot.instancesAt = Bot.now()
Bot.loop.idx = 0
started = nil
Bot.circle_step()
check(started == "хельхейм", "круг: после удаления зона свободна — идём")

-- «обл» не ответил — идём без проверки кулдаунов
Bot.loop = { list = { "a", "b" }, idx = 1, deleteAt = {} }
started = nil
Bot.circle_fallback()
check(started == "b", "круг: нет ответа «обл» — идём в следующую зону")

-- тик круга сам запрашивает «обл»
Bot.loop = { list = { "a" }, idx = 0, deleteAt = {} }
Bot.state = "idle"
Bot.instanceQuery = nil
sent = {}
Bot.circle_tick()
check(sent[#sent] == "обл" and Bot.instanceQuery == "circle",
  "круг: тик спрашивает «обл»")
Bot.instanceQuery = nil

Bot.begin_zone = realBegin
Bot.zones["хельхейм"] = nil
Bot.instanceQuery = nil
Bot.circleDelete = nil
Bot.state = "idle"

-- ===== 29. старт/перезагрузка перечитывают файл зоны =====
Bot.save_zone("reloadzone", { steps = { { dir = "юг", room = 800 } } })
Bot.zones["reloadzone"] = { steps = {
  { dir = "юг", room = 801 }, { dir = "юг", room = 802 }, { dir = "юг", room = 803 },
} }
Bot.save_zone("reloadzone", { steps = {
  { dir = "восток", room = 810 }, { dir = "юг", room = 811 },
} })
local rl = Bot.reload_zone("reloadzone")
check(rl and #rl.steps == 2 and rl.steps[1].dir == "восток",
  "reload: файл перечитан, кэш заменён (шагов " .. tostring(rl and #rl.steps) .. ")")

-- .бот старт тоже берёт свежий файл, а не кэш
Bot.zones["reloadzone"] = { steps = { { dir = "юг", room = 801 } } }
Bot.state, Bot.paused = "idle", false
Bot.queue, Bot.resume = {}, nil
Bot.entryDone = false
Bot.hp, Bot.hpMax = 1000, 1000
Bot.mv, Bot.mvMax = 1800, 2000
Bot.config.restBelow, Bot.config.lowHpPercent = 0, 0
Bot.combat.engagedAt, Bot.combat.skipRoom, Bot.combat.attacked = 0, nil, nil
Bot.mobs, Bot.battle = {}, false
msdp.ROOM = { VNUM = 800, NAME = "Старт", EXITS = {} }
Bot.on_msdp_room()
sent = {}
Bot.begin_zone("reloadzone")
check(Bot.route and #Bot.route.steps == 2 and Bot.route.steps[1].dir == "восток",
  "старт: маршрут взят из свежего файла (шагов " ..
  tostring(Bot.route and #Bot.route.steps) .. ")")
Bot.state, Bot.route, Bot.i = "idle", nil, 0
Bot.resume = nil

-- .бот перезагрузить «зона»
Bot.zones["reloadzone"] = { steps = { { dir = "юг", room = 801 } } }
Bot.command("перезагрузить", "reloadzone")
check(Bot.zones["reloadzone"] and #Bot.zones["reloadzone"].steps == 2,
  "перезагрузить: кэш зоны обновлён")
Bot.zones["reloadzone"] = nil

-- ===== 30. .бот зоны: локальный список маршрутов =====
Bot.save_zone("listzone", {
  entry = { vnum = "1", dir = "запад", num = 7, title = "Тестовая зона", maxdiff = 2 },
  mode = "list",
  kill = { ["Моб"] = true },
  aggro = { ["Агрессор"] = true },
  steps = { { dir = "запад", room = 2 }, { cmd = "г помогу", room = 2 } },
})
Bot.zones["listzone"] = nil
local ignore = io.open(Bot.base_dir() .. "/zones/ignore.txt", "wb")
ignore:write("not lua\n")
ignore:close()
local broken = io.open(Bot.zone_path("brokenzone"), "wb")
broken:write("this is not lua\n")
broken:close()

Bot.loop = { list = { "listzone" }, idx = 0, deleteAt = {} }
Bot.zone, Bot.resume = nil, nil
Bot.state, Bot.paused = "idle", false
local files = Bot.zone_files()
local has_list, has_broken, has_ignore = false, false, false
for _, name in ipairs(files or {}) do
  if name == "listzone" then has_list = true end
  if name == "brokenzone" then has_broken = true end
  if name == "ignore" or name == "ignore.txt" then has_ignore = true end
end
check(has_list and has_broken and not has_ignore,
  "зоны: список файлов (lua есть, посторонние нет)")
check(Bot.zones["listzone"] == nil, "зоны: zone_files не заполняет кэш")
local lz = Bot.read_zone("listzone")
check(lz and #lz.steps == 2 and lz.mode == "list" and lz.entry.title == "Тестовая зона",
  "зоны: read_zone читает метаданные без кэша")
check(Bot.zones["listzone"] == nil, "зоны: read_zone не заполняет кэш")

local out = {}
local realEcho = Bot.echo
Bot.echo = function(msg) out[#out + 1] = tostring(msg) end
sent = {}
Bot.instanceQuery = nil
local ok_list, err_list = pcall(Bot.command, "зоны", "")
Bot.echo = realEcho
local text = table.concat(out, "\n")
check(ok_list, "зоны: команда без ошибок (" .. tostring(err_list) .. ")")
check(text:find("listzone", 1, true) ~= nil and text:find("Тестовая зона", 1, true) ~= nil,
  "зоны: вывод содержит имя и вход")
check(text:find("шагов", 1, true) ~= nil and text:find("целей", 1, true) ~= nil,
  "зоны: вывод содержит шаги и цели")
check(text:find("не читается", 1, true) ~= nil, "зоны: битый файл не ломает список")
check(text:find("[в круге]", 1, true) ~= nil, "зоны: отметка «в круге»")
check(#sent == 0 and Bot.instanceQuery == nil, "зоны: не отправляет «обл» на сервер")

sent = {}
Bot.instanceQuery = nil
antiBotLastSent = 0
Bot.command("обл", "")
check(sent[#sent] == "обл" and Bot.instanceQuery == "show",
  "обл: команда по-прежнему запрашивает экземпляры зон")
Bot.instanceQuery = nil

-- ===== 31. замер: повтор хода без счёта попыток =====
timers = {}
Bot.config.holdRetryDelay = 0.1
Bot.state, Bot.paused = "walk", false
Bot.route = { steps = { { dir = "запад", room = 305 } } }
Bot.i, Bot.deadline = 1, 0
Bot.expect, Bot.awaiting = "305", false
Bot.walk_repair = nil
Bot.doorAttempts = 5
Bot.recover = { step = 0, count = 0, fails = 0 }
Bot.hold, Bot.holdWarned = nil, nil
Bot.lastRoomVnum, Bot.room.vnum = "304", "304"
Bot.battle, Bot.mobs = false, {}
Bot.hp, Bot.hpMax = 1000, 1000
Bot.mv, Bot.mvMax = 1800, 2000
Bot.config.restBelow, Bot.config.lowHpPercent = 0, 0
msdp.ROOM = { VNUM = "304", NAME = "Паутина", EXITS = { w = 305 } }
Bot.block.open, Bot.segment.lines, Bot.mobs = false, {}, {}
sent = {}
Bot.on_text_line("Вы замерли на месте, не в силах шевельнуться!")
check(Bot.hold == true, "замер: состояние распознано")
check(#Bot.segment.lines == 0 and #Bot.mobs == 0,
  "замер: строка не попала в содержимое комнаты")
check(Bot.doorAttempts == 5, "замер: счётчик попыток не увеличен")
check(Bot.recover.count == 0 and Bot.recover.fails == 0,
  "замер: recovery не тронут")
check(#sent == 0, "замер: команда сразу не отправляется")

Bot.walk.timeout()
check(#sent == 0, "замер: повтор отложен, без recovery")
check(Bot.state == "walk" and Bot.doorAttempts == 5,
  "замер: timeout не увеличил счётчик и не остановил бота")
advance(0.2)
check(sent[#sent] == "запад", "замер: ход повторён")
check(Bot.doorAttempts == 5 and Bot.state == "walk",
  "замер: повтор не израсходовал лимит")

Bot.walk.timeout()
advance(0.2)
check(sent[#sent] == "запад" and Bot.doorAttempts == 5,
  "замер: повтор продолжается без счёта")

-- освободились: смена комнаты снимает замер и обычные счётчики
Bot.expect = "305"
msdp.ROOM = { VNUM = "305", NAME = "Выбрались", EXITS = {} }
Bot.on_msdp_room()
check(Bot.hold == nil and Bot.holdWarned == nil,
  "замер: смена комнаты сняла состояние")
check(Bot.doorAttempts == 0 and Bot.i == 2,
  "замер: после освобождения шаг и счётчики обычные")

-- отказ хода во время замирания — тоже без счёта попыток
timers = {}
Bot.state, Bot.paused = "walk", false
Bot.route = { steps = { { dir = "запад", room = 305 } } }
Bot.i, Bot.deadline = 1, 0
Bot.expect, Bot.awaiting = "305", false
Bot.walk_repair = nil
Bot.doorAttempts = 5
Bot.recover = { step = 0, count = 0, fails = 0 }
Bot.hold, Bot.holdWarned = true, true
Bot.lastRoomVnum = "304"
sent = {}
Bot.on_blocked_move("направление")
check(Bot.state == "walk" and Bot.doorAttempts == 5,
  "замер: отказ хода не увеличил счётчик")
advance(0.2)
check(sent[#sent] == "запад", "замер: отказ хода тоже повторяет движение")

-- recovery во время замирания: повторяем последний ход без счётчика
timers = {}
Bot.state = "walk"
Bot.route = { steps = { { dir = "запад", room = 305 } } }
Bot.i, Bot.deadline = 1, 0
Bot.expect, Bot.awaiting = nil, false
Bot.doorAttempts = 5
Bot.recover = { step = 0, count = 0, fails = 0 }
Bot.walk_repair = { dirs = { "запад" }, target = "305", last = "запад" }
Bot.hold, Bot.holdWarned = true, true
sent = {}
Bot.walk.timeout()
advance(0.2)
check(sent[#sent] == "запад" and Bot.doorAttempts == 5 and
  Bot.walk_repair ~= nil, "замер: recovery повторяет ход без счёта")

Bot.walk_repair = nil
Bot.hold, Bot.holdWarned = nil, nil
Bot.state, Bot.route, Bot.i = "idle", nil, 0

-- ===== 32. ход, отложенный из-за боя, не оставляет expect =====
timers = {}
Bot.state, Bot.paused = "walk", false
Bot.route = { steps = { { dir = "запад", room = 305 } } }
Bot.i, Bot.expect, Bot.awaiting = 1, "305", false
Bot.deadline, Bot.waitUntil = 0, 0
Bot.walk_repair = nil
Bot.battle, Bot.mobs = true, {}
Bot.combat.attacked, Bot.combat.engagedAt = true, 0
Bot.lastRoomVnum, Bot.room.vnum = "304", "304"
Bot.hold, Bot.holdWarned = nil, nil
msdp.ROOM = { VNUM = "304", NAME = "Паутина", EXITS = { w = 305 } }
local held_step = Bot.route.steps[Bot.i]
sent = {}
Bot.walk.move(held_step)
check(Bot.expect == nil and Bot.deadline == 0 and #sent == 0,
  "бой: отложенный ход снимает старый expect")
Bot.battle = false
Bot.walk.pulse()
check(sent[#sent] == "запад" and Bot.expect == "305",
  "бой: после боя pulse снова отправляет ход")
Bot.state, Bot.route, Bot.i = "idle", nil, 0
Bot.expect, Bot.awaiting, Bot.deadline = nil, false, 0
Bot.battle = false
Bot.config.holdRetryDelay = 1.0
Bot.recover = { step = 0, count = 0, fails = 0 }

-- ===== 33. final_steps: после маршрута, без проверки комнаты =====
Bot.save_zone("finalzone", {
  steps = { { dir = "юг", room = 900 } },
  final_steps = {
    { cmd = "гг !путь склад", room = 123 },
    { wait = 0.1 },
    { trigger = "готово" },
  },
})
local fz = Bot.read_zone("finalzone")
check(fz and #fz.final_steps == 3 and fz.final_steps[1].cmd == "гг !путь склад",
  "final: массив прочитан из файла")

local real_expand, real_act = Bot.config.expandActions, Bot.config.waitAfterAct
Bot.config.expandActions, Bot.config.waitAfterAct = false, 0
Bot.state, Bot.paused = "walk", false
Bot.zone = "finalzone"
Bot.route = fz
Bot.i = #fz.steps + 1
Bot.final_i = nil
Bot.expect, Bot.awaiting = nil, false
Bot.deadline, Bot.waitUntil = 0, 0
Bot.battle, Bot.mobs = false, {}
Bot.combat.attacked, Bot.combat.engagedAt = true, 0
Bot.walk_repair, Bot.trigger = nil, nil
Bot.hold, Bot.holdWarned = nil, nil
Bot.stats = { zone = "finalzone", t0 = Bot.now(), money0 = Bot.money, kills = 0 }
Bot.queue, Bot.loop = {}, { list = {}, idx = 0, deleteAt = {} }
Bot.lastRoomVnum, Bot.room.vnum = "999", "999"
sent = {}
Bot.walk.pulse()
check(sent[#sent] == "гг !путь склад" and Bot.final_i == 3 and Bot.waiting(),
  "final: команда выполнена без проверки room, затем пауза")
Bot.waitUntil = 0
Bot.walk.pulse()
check(Bot.trigger and Bot.trigger.final and Bot.final_i == 3,
  "final: trigger ждёт сообщение")
Bot.walk.trigger_line("готово")
check(Bot.final_i == 4, "final: trigger сдвинул финальный шаг")
Bot.walk.pulse()
check(Bot.state == "idle" and Bot.route == nil and Bot.final_i == nil,
  "final: после финальных действий зона завершена")
Bot.config.expandActions, Bot.config.waitAfterAct = real_expand, real_act
Bot.zones["finalzone"] = nil

-- уборка
getRoomIDbyHash = realGetRoom
Bot.record.name = nil
Bot.record.entry = nil
Bot.stop()
Bot.state = "idle"

-- эвристика имён и лор удалены (цели считаются номером, а не именем)
check(Bot.mob_name == nil and Bot.load_lore == nil, "mob_name и лор удалены")
check(Bot.is_continuation_line("...светится розовым сиянием.") == true,
  "is_continuation_line: «...» — продолжение")
check(Bot.is_continuation_line("Безликая душа блуждает царством мертвых.") == false,
  "is_continuation_line: имя с заглавной — не продолжение")

-- ===== trigger: шаг «ждать сообщение» =====
-- В конце, чтобы сдвиг времени не влиял на чувствительный к тику recovery-тест
local function trigger_setup()
  Bot.route = { steps = {
    { trigger = "мост со скрипом опустился", room = 166076, timeout = 5 },
    { cmd = "войти", room = 166076 },
  } }
  Bot.zone = "testzone"
  Bot.i = 1
  Bot.state = "walk"
  Bot.expect, Bot.awaiting = nil, false
  Bot.recover = { step = 0, count = 0, fails = 0 }
  Bot.deadline, Bot.waitUntil = 0, 0
  Bot.paused, Bot.battle = false, false
  Bot.mobs, Bot.segment.lines = {}, {}
  Bot.walk_repair, Bot.jump = nil, nil
  Bot.jumpCounts = {}
  Bot.doorAttempts = 0
  Bot.act_retry = 0
  Bot.act_wait = nil
  Bot.trigger = nil
  Bot.hold = nil
  Bot.combat.engagedAt = 0
  Bot.lastFail = ""
  msdp.ROOM = { VNUM = 166076, NAME = "Перед мостом", EXITS = {} }
  Bot.on_msdp_room()
end

trigger_setup()
expanded = {}
Bot.walk.pulse()
check(Bot.trigger ~= nil, "trigger: ожидание сообщения включено")
check(Bot.i == 1, "trigger: шаг не сдвинут без сообщения (Bot.i=" .. tostring(Bot.i) .. ")")

feed("Огромный подвесной мост со скрипом опустился на этот берег.")
check(Bot.trigger == nil and Bot.i == 2,
  "trigger: сообщение пришло — шаг сдвинут (Bot.i=" .. tostring(Bot.i) .. ")")
advance(0.2)
check(expanded[#expanded] == "войти",
  "trigger: после сообщения выполняем следующий шаг (получено: " ..
  tostring(expanded[#expanded]) .. ")")

-- таймаут: сообщение не пришло (форсируем дедлайн, не сдвигая общее время)
trigger_setup()
Bot.walk.pulse()
Bot.trigger.deadline = Bot.now() - 1
Bot.walk.pulse()
check(Bot.state == "idle" and tostring(Bot.lastFail):find("не дождался") ~= nil,
  "trigger: таймаут — останов (получено: " .. tostring(Bot.lastFail) .. ")")

-- ===== ход в бою не шлётся (регрессия «восток во время боя») =====
Bot.state = "walk"
Bot.route = { steps = { { dir = "восток", room = 500 } } }
Bot.i = 1
Bot.expect, Bot.awaiting = nil, false
Bot.deadline, Bot.waitUntil = 0, 0
Bot.paused, Bot.battle = false, false
Bot.walk_repair, Bot.jump = nil, nil
Bot.combat.engagedAt = 0
Bot.combat.attacked = nil
msdp.ROOM = { VNUM = 499, NAME = "Комната", EXITS = {} }
Bot.on_msdp_room()
sent = {}
Bot.battle = true
Bot.walk.move(Bot.route.steps[1])
check(#sent == 0 and Bot.expect == nil,
  "ход в бою не отправлен (получено: " .. tostring(sent[#sent]) .. ")")
Bot.battle = false
Bot.combat.engagedAt = Bot.now()
Bot.walk.move(Bot.route.steps[1])
check(#sent == 0, "ход во время ожидания боя не отправлен")
Bot.combat.engagedAt = 0
Bot.walk.move(Bot.route.steps[1])
check(sent[#sent] == "восток", "после боя ход отправлен (получено: " ..
  tostring(sent[#sent]) .. ")")
Bot.state = "idle"

-- ===== панель: выходы (VNUM или «-») =====
msdp.ROOM = { VNUM = 100, EXITS = { ["север"] = 101, ["e"] = 102, ["вниз"] = 104 } }
Bot.on_msdp_room()
local pex = Bot.panel_exits()
local function exv(label)
  for _, e in ipairs(pex) do
    if e:sub(1, #label + 1) == label .. ":" then return e:sub(#label + 2) end
  end
  return nil
end
check(exv("N") == "000101", "панель: север = 6 цифр (получено «" .. tostring(exv("N")) .. "»)")
check(exv("E") == "000102", "панель: восток = 6 цифр (получено «" .. tostring(exv("E")) .. "»)")
check(exv("D") == "000104", "панель: вниз = 6 цифр (получено «" .. tostring(exv("D")) .. "»)")
local up = exv("U")
check(up ~= nil and up:find("^[%- ]+$") ~= nil and up:find("%-") ~= nil,
  "панель: нет вверх — прочерк (получено «" .. tostring(up) .. "»)")

-- ===== замер: строка моба не включает «замер» у игрока =====
Bot.state = "walk"
Bot.hold, Bot.holdWarned = nil, nil
Bot.on_text_line("Золотистый ядовитый муравей замер на месте, не в силах шевельнуться!")
check(Bot.hold == nil, "замер: строка моба НЕ включает замер (получено " ..
  tostring(Bot.hold) .. ")")
Bot.hold, Bot.holdWarned = nil, nil
Bot.on_text_line("Вы замерли на месте, не в силах шевельнуться!")
check(Bot.hold == true, "замер: строка игрока включает замер")
Bot.hold, Bot.holdWarned = nil, nil
Bot.state = "idle"

-- ===== 33. look после боя не пришёл: по lookWait продолжаем =====
timers = {}
Bot.state, Bot.paused = "walk", false
Bot.zone, Bot.route = "testzone", { steps = { { dir = "восток", room = 102 } } }
Bot.i, Bot.expect, Bot.awaiting = 1, nil, false
Bot.deadline, Bot.waitUntil = 0, 0
Bot.walk_repair, Bot.jump = nil, nil
Bot.recover = { step = 0, count = 0, fails = 0 }
Bot.doorAttempts, Bot.hold = 0, nil
Bot.combat.attacked, Bot.combat.engagedAt, Bot.combat.room = true, 0, "101"
Bot.mobs = {}
Bot.battle = false
Bot.hp, Bot.hpMax, Bot.mv, Bot.mvMax = 1000, 1000, 1000, 1000
Bot.config.restBelow, Bot.config.restAbove, Bot.config.lowHpPercent = 0, 0, 0
Bot.set_room_fight(false)
msdp.ROOM = { VNUM = "101", NAME = "Зал", EXITS = { e = 102 } }
Bot.room.vnum, Bot.lastRoomVnum = "101", "101"
sent = {}
Bot.lookPending = Bot.now() - 1     -- срок ожидания look истёк
Bot.tick(Bot.gen)
check(Bot.lookPending == nil, "look потерялся: ожидание снято по lookWait")
check(sent[#sent] == "восток", "look потерялся: маршрут продолжается (получено: " ..
  tostring(sent[#sent]) .. ")")

-- ===== 34. бой в комнате (группа): не уходим, пока кто-то сражается =====
local oldFight = {
  mobSource = Bot.config.mobSource,
  any = Bot.config.groupFightAny,
  wait = Bot.config.groupFightWait,
  probe = Bot.config.groupFightProbe,
  idle = Bot.config.groupFightIdle,
  timeout = Bot.config.groupFightTimeout,
  attack = Bot.attack,
}
timers = {}
assist_who = nil
group_count, pet_count = "15", 0    -- как в живом профиле: строкой
Bot.config.mobSource = "text"
Bot.config.groupFightWait, Bot.config.groupFightAny = true, true
Bot.config.groupFightProbe, Bot.config.groupFightIdle = 10, 5
Bot.config.groupFightTimeout = 300
Bot.attack = Bot.attack_default()
Bot.state, Bot.paused = "walk", false
Bot.zone = "testzone"
Bot.route = { steps = { { dir = "восток", room = 102 } } }
Bot.i, Bot.expect, Bot.awaiting = 1, nil, false
Bot.deadline, Bot.waitUntil, Bot.lookPending = 0, 0, nil
Bot.walk_repair, Bot.jump = nil, nil
Bot.recover = { step = 0, count = 0, fails = 0 }
Bot.doorAttempts, Bot.hold = 0, nil
Bot.combat.attacked, Bot.combat.engagedAt, Bot.combat.room = true, 0, "101"
Bot.combat.attempts, Bot.combat.refreshed, Bot.combat.skipRoom = 0, nil, nil
Bot.mobs = {}
Bot.battle = false
Bot.hp, Bot.hpMax, Bot.mv, Bot.mvMax = 1000, 1000, 1000, 1000
Bot.config.restBelow, Bot.config.restAbove, Bot.config.lowHpPercent = 0, 0, 0
Bot.set_room_fight(false)
msdp.ROOM = { VNUM = "101", NAME = "Ледяная пещера", EXITS = { e = 102 } }
Bot.room.vnum, Bot.room.name, Bot.lastRoomVnum = "101", "Ледяная пещера", "101"
Bot.segment.lines = {}
sent = {}

room_block("Ледяная пещера", {
  "Земляной страж стоит здесь, сражается с Тэйросом!",
  "Безмолвный Король Тэйрос сидит здесь, сражается с земляным стражем!",
})
prompt(PEACE)
check(Bot.roomFight == true, "бой в комнате распознан по «сражается»")
check(#sent == 0, "бой в комнате: ход не отправлен (получено: " ..
  tostring(sent[#sent]) .. ")")

-- после смерти моба профиль шлёт «встат/пом»; сервер отвечает, что помогать некому
Bot.on_text_line("Кому именно вы хотите помочь?")
check(Bot.roomFight == nil, "«пом» без цели: бой в комнате снят")
check(sent[#sent] == "look краткий", "после «пом» обновляем комнату (получено: " ..
  tostring(sent[#sent]) .. ")")
check(#Bot.segment.lines == 0, "«Кому именно…» не попало в содержимое комнаты")

room_block("Ледяная пещера", {})
prompt(PEACE)   -- ответ на look: комната пуста
check(sent[#sent] == "восток", "после боя группы маршрут продолжается (получено: " ..
  tostring(sent[#sent]) .. ")")
check(Bot.expect == "102", "после боя группы ожидаем VNUM 102")

-- fallback: «пом» без цели не приходит — перепроверяем look'ом
Bot.state = "walk"
Bot.i, Bot.expect, Bot.awaiting = 1, nil, false
Bot.deadline, Bot.lookPending = 0, nil
Bot.combat.attacked, Bot.combat.room = true, "101"
Bot.set_room_fight(true)
Bot.fightNoiseAt, Bot.roomFightProbeAt = 0, 0
sent = {}
Bot.tick(Bot.gen)
check(sent[#sent] == "look краткий", "fallback: пока бой идёт — look (получено: " ..
  tostring(sent[#sent]) .. ")")
sent = {}
Bot.tick(Bot.gen)
check(#sent == 0, "fallback: чаще groupFightProbe look не шлём")
Bot.lookPending = nil
Bot.roomFightProbeAt = 0
Bot.fightNoiseAt = Bot.now()
Bot.tick(Bot.gen)
check(#sent == 0, "fallback: пока комната шумит, look не шлём")

-- свежий блок без «сражается» снимает ожидание
Bot.lookPending = nil
Bot.set_room_fight(true)
room_block("Ледяная пещера", {})
prompt(PEACE)
check(Bot.roomFight == nil, "свежий блок без «сражается» снял бой")

-- «X вступил в бой на стороне Y» вне блока тоже взводит ожидание
Bot.set_room_fight(false)
Bot.on_text_line("Кейб вступил в бой на стороне Аниен.")
check(Bot.roomFight == true, "«вступил в бой» партнёра: ждём бой")
Bot.set_room_fight(false)
Bot.on_text_line("Вы вступили в бой на стороне Аниен.")
check(Bot.roomFight == nil, "свой «вступил в бой» ожидание не взводит (это Bot.battle)")

-- таймаут: бой «идёт» дольше groupFightTimeout — маршрут продолжается
Bot.state = "walk"
Bot.i, Bot.expect, Bot.awaiting = 1, nil, false
Bot.deadline, Bot.lookPending = 0, nil
Bot.set_room_fight(true)
Bot.roomFightUntil = Bot.now() - 1
Bot.roomFightWarned = nil
sent = {}
Bot.walk.pulse()
check(sent[#sent] == "восток", "таймаут боя в комнате: идём дальше (получено: " ..
  tostring(sent[#sent]) .. ")")
check(Bot.roomFightWarned == true, "таймаут боя в комнате: предупредили")

-- боткилл при входе в клетку не блокируется ожиданием боя
Bot.i, Bot.expect, Bot.awaiting = 1, nil, false
Bot.deadline, Bot.lookPending = 0, nil
Bot.combat.attacked, Bot.combat.attempts, Bot.combat.refreshed = false, 0, nil
Bot.combat.engagedAt = 0
Bot.mobs = { "Земляной страж стоит здесь, сражается с Тэйросом!" }
Bot.set_room_fight(true)
sent = {}
expanded = {}
Bot.walk.pulse()
check(expanded[#expanded] == "botkill",
  "вход в клетку в бою: botkill всё равно отправлен (получено: " ..
  tostring(expanded[#expanded]) .. ")")

-- смена комнаты сбрасывает ожидание боя
Bot.state, Bot.i, Bot.expect, Bot.awaiting = "walk", 2, nil, false
Bot.lastRoomVnum = "101"
Bot.set_room_fight(true)
msdp.ROOM = { VNUM = "102", NAME = "Ниша", EXITS = {} }
Bot.on_msdp_room()
check(Bot.roomFight == nil, "смена комнаты сбросила бой в комнате")

Bot.state, Bot.route, Bot.i = "idle", nil, 0
Bot.expect, Bot.awaiting, Bot.deadline, Bot.lookPending = nil, false, 0, nil
Bot.set_room_fight(false)
assist_who = nil
group_count, pet_count = 1, 0
Bot.config.mobSource = oldFight.mobSource
Bot.config.groupFightWait, Bot.config.groupFightAny = oldFight.wait, oldFight.any
Bot.config.groupFightProbe, Bot.config.groupFightIdle = oldFight.probe, oldFight.idle
Bot.config.groupFightTimeout = oldFight.timeout
Bot.attack = oldFight.attack

-- ===== 35. «в группе?»: group_count > 1 или свой игрок в комнате =====
group_count, pet_count = 1, 0
assist_who = nil
Bot.state, Bot.paused = "walk", false
Bot.zone = "testzone"
Bot.route = { steps = { { dir = "восток", room = 102 } } }
Bot.i, Bot.expect, Bot.awaiting = 1, nil, false
Bot.deadline, Bot.lookPending = 0, nil
Bot.combat.attacked, Bot.combat.engagedAt, Bot.combat.room = true, 0, "101"
Bot.mobs = {}
Bot.playerInRoom = false
Bot.battle = false
Bot.hp, Bot.hpMax, Bot.mv, Bot.mvMax = 1000, 1000, 1000, 1000
Bot.config.restBelow, Bot.config.restAbove, Bot.config.lowHpPercent = 0, 0, 0
Bot.config.groupFightWait, Bot.config.groupFightAny = true, true
Bot.config.groupFightRequireGroup = true
Bot.config.groupFightProbe, Bot.config.groupFightIdle = 10, 5
msdp.ROOM = { VNUM = "101", NAME = "Зал", EXITS = { e = 102 } }
Bot.room.vnum, Bot.lastRoomVnum = "101", "101"
Bot.set_room_fight(true)
Bot.fightNoiseAt, Bot.roomFightProbeAt = 0, 0
sent = {}
Bot.tick(Bot.gen)
check(Bot.in_group() == false, "соло: Bot.in_group() == false")
check(sent[#sent] == "восток", "соло: бой в комнате не ждём (получено: " ..
  tostring(sent[#sent]) .. ")")
check(Bot.room_fight_wait() == false, "соло: room_fight_wait() == false")

-- свой игрок из assist_who в комнате — уже считаем «в группе»
local oldMobSource35 = Bot.config.mobSource
Bot.config.mobSource = "text"
assist_who = { ["Тэйрос"] = "Тэйрос" }
Bot.i, Bot.expect, Bot.awaiting = 1, nil, false
Bot.deadline, Bot.lookPending = 0, nil
Bot.playerInRoom = false
Bot.mobs = {}
Bot.set_room_fight(false)
room_block("Зал", { "Безмолвный Король Тэйрос сидит здесь, сражается с земляным стражем!" })
prompt(PEACE)
check(Bot.playerInRoom == true and Bot.in_group() == true,
  "свой в комнате: in_group() == true")
check(Bot.roomFight == true and Bot.room_fight_wait() == true,
  "свой в комнате: бой в комнате ждём")
sent = {}
Bot.walk.pulse()
check(#sent == 0, "свой в комнате: ход не отправлен (получено: " ..
  tostring(sent[#sent]) .. ")")

-- groupFightRequireGroup = false — ждём бой и соло
assist_who = nil
Bot.playerInRoom = false
Bot.mobs = {}
Bot.config.groupFightRequireGroup = false
Bot.i, Bot.expect, Bot.awaiting = 1, nil, false
Bot.deadline = 0
Bot.set_room_fight(true)
sent = {}
Bot.walk.pulse()
check(#sent == 0, "groupFightRequireGroup=false: соло тоже ждёт бой")

-- nil group_count не ломает проверку
group_count = nil
Bot.config.groupFightRequireGroup = true
Bot.set_room_fight(false)
check(Bot.in_group() == false, "group_count=nil: in_group() == false")

group_count, pet_count = 1, 0
assist_who = nil
Bot.config.mobSource = oldMobSource35
Bot.config.groupFightRequireGroup = true
Bot.state, Bot.route, Bot.i = "idle", nil, 0
Bot.expect, Bot.awaiting, Bot.deadline, Bot.lookPending = nil, false, 0, nil
Bot.playerInRoom = false
Bot.set_room_fight(false)

io.write("\nИтог: ", errors == 0 and "все проверки пройдены" or (errors .. " ошибок"), "\n")
os.exit(errors == 0 and 0 or 1)

