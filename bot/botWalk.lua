-- Создайте скрипт:
-- name: BotWalk
-- body:
-- =====================================================================
-- BotWalk — пошаговый проход маршрута зоны (гибридная навигация)
-- =====================================================================
-- Один шаг маршрута = одна команда + ack по msdp.ROOM.VNUM.
-- Если VNUM после хода не совпал с ожидаемым (телепорт, сбили, дверь),
-- включается recovery: мягкий ресинк по маршруту, затем generic_mapper
-- (getPath) — и всё это тем же пошаговым циклом, с добиванием мобов.
--
-- Зависимости: BotCore (глобал Bot), BotCombat (botkill), mapper.lua.
-- =====================================================================

Bot = Bot or {}
Bot.walk = Bot.walk or {}
local W = Bot.walk

local function fmt(...)
  return string.format(...)
end

-- ===================== старт / выравнивание =====================

-- на старте пропускаем шаги, в комнате которых уже стоим
function W.resync()
  if not Bot.route then return end
  local vnum = Bot.vnum()
  if vnum == "" then return end
  while Bot.i <= #Bot.route.steps do
    local step = Bot.route.steps[Bot.i]
    if step.dir and step.room and tostring(step.room) == vnum then
      Bot.i = Bot.i + 1
    else
      break
    end
  end
end

-- «Окованный сундук заперт.» — это контейнер, а не выход: триггер профиля
-- ловит любое «… заперт.», и без этого фильтра бот принимал ответ на «оов сун»
-- за заблокированный ход.
Bot.container_words = Bot.container_words or {
  "сундук", "сундуч", "ларец", "ящик", "сейф", "шкаф", "контейнер",
}

function Bot.is_container_name(name)
  local s = Bot.fold(name or "")
  for _, word in ipairs(Bot.container_words) do
    if s:find(word, 1, true) then return true end
  end
  return false
end

-- «Вы замерли на месте, не в силах шевельнуться!» — ход не проходит, но это
-- не дверь и не ошибка маршрута. Пока персонаж замер, повторяем движение и
-- НЕ расходуем doorAttempts/recover: иначе после пяти повторов бот уходил в
-- recovery и падал с «не довёл до комнаты».
-- Паттерн адресован ИГРОКУ («Вы …») и сверяется С НАЧАЛА строки: строки мобов
-- («…муравей замер на месте…») не должны включать «замер».
Bot.hold_patterns = {
  "Вы замерли на месте",   -- «Вы замерли на месте, не в силах шевельнуться!»
}

function W.hold_line(line)
  local s = Bot.fold(Bot.trim(line or ""))
  for _, pattern in ipairs(Bot.hold_patterns) do
    local p = Bot.fold(pattern)
    if p ~= "" and s:sub(1, #p) == p then   -- строка НАЧИНАЕТСЯ с фразы
      if Bot.state == "walk" then
        Bot.hold = true
        if not Bot.holdWarned then
          Bot.holdWarned = true
          Bot.warn("<orange>Замер: не могу двигаться — повторяю ход без счёта попыток")
        end
      end
      return true
    end
  end
  return false
end

function W.begin()
  Bot.expect = nil
  Bot.awaiting = false
  Bot.deadline = 0
  Bot.walk_repair = nil
  Bot.jump = nil
  Bot.jumpCounts = {}
  Bot.lastRoomVnum = Bot.vnum()
  Bot.recover = { step = 0, count = 0, fails = 0 }
  Bot.doorAttempts = 0
  Bot.act_retry = 0
  Bot.act_wait = nil
  Bot.trigger = nil
  Bot.hold = nil
  Bot.holdWarned = nil
  Bot.final_i = nil
  W.resync()
  Bot.dbg("[walk] старт с шага " .. tostring(Bot.i) .. " из " ..
    tostring(#(Bot.route and Bot.route.steps or {})))
  W.pulse()
end

-- ===================== основной цикл =====================

function W.pulse()
  if Bot.state ~= "walk" or Bot.paused then return end
  if Bot.expect or Bot.awaiting or Bot.waiting() or Bot.in_battle() then return end
  -- ждём блок комнаты в ответ на look (после боя / обновления комнаты)
  if Bot.lookPending and Bot.now() < Bot.lookPending then return end
  if not Bot.route then return end

  -- безопасность и выносливость важнее любых шагов и recovery
  if Bot.hp_critical() then
    return Bot.fail("HP " .. tostring(Bot.hp) .. "/" .. tostring(Bot.hpMax) ..
      " ниже порога — останавливаюсь")
  end
  -- kill отправлен, ждём боевой промпт — шаг не двигаем
  if Bot.combat and Bot.combat.pending and Bot.combat.pending() then return end
  if Bot.rest_tick() then return end
  if Bot.needs_rest() then return Bot.rest_start() end

  if Bot.walk_repair then return W.repair_step() end

  while true do
    -- финальные действия (после возврата в город) не должны уходить в бой
    if Bot.i > #Bot.route.steps and Bot.route.final_steps and
      #Bot.route.final_steps > 0 then
      -- но и в бою (своём или группы) финальные действия не делаем
      if Bot.room_fight_wait() then return end
      return W.final_pulse()
    end
    -- сначала бой: на входе в клетку botkill запускает бой, даже если моб не агро
    if Bot.combat and Bot.combat.should_fight and Bot.combat.should_fight() then
      return Bot.combat.engage()
    end
    -- бой в комнате уже идёт (наш таргет пропал, партнёры добивают) — не уходим
    if Bot.room_fight_wait() then return end
    if Bot.i > #Bot.route.steps then
      return Bot.finish_zone("маршрут пройден")
    end

    local step = Bot.route.steps[Bot.i]
    if step.cmd then
      -- Действие выполняется в step.room. Если мы ещё не там (предыдущий перенос
      -- опоздал или не сработал) — ждём, пока комната не совпадёт: действовать
      -- в чужой комнате нельзя.
      if step.room and Bot.vnum() ~= "" and Bot.vnum() ~= tostring(step.room) then
        Bot.act_retry = (Bot.act_retry or 0) + 1
        local limit = tonumber(Bot.config.actRoomLimit) or 5
        if Bot.act_retry > limit then
          return Bot.fail("действие «" .. step.cmd .. "» не в комнате " ..
            tostring(step.room) .. " (сейчас " .. Bot.vnum() .. ")")
        end
        Bot.act_wait = true
        Bot.dbg("[act] ждём комнату " .. tostring(step.room) .. " (сейчас " ..
          Bot.vnum() .. ", " .. tostring(Bot.act_retry) .. "/" .. tostring(limit) .. ")")
        Bot.wait(Bot.config.waitAfterAct or 1)
        return
      end
      Bot.act_retry = 0
      Bot.act_wait = nil
      Bot.i = Bot.i + 1
      Bot.dbg("[act] " .. step.cmd)
      Bot.run_action(step.cmd)
      Bot.act_wait = true
      if Bot.config.waitAfterAct > 0 then Bot.wait(Bot.config.waitAfterAct) end
      if Bot.waiting() or Bot.in_battle() or Bot.paused then return end
    elseif step.trigger then
      -- ждём от сервера строку-синхронизацию (например, «мост опустился»)
      if not Bot.trigger or Bot.trigger.step ~= Bot.i then
        local timeout = tonumber(step.timeout) or tonumber(Bot.config.triggerTimeout) or 10
        Bot.trigger = {
          text = Bot.fold(step.trigger),
          step = Bot.i,
          deadline = Bot.now() + timeout,
        }
        Bot.dbg("[trigger] жду сообщение: " .. tostring(step.trigger) ..
          " (шаг " .. tostring(Bot.i) .. ", таймаут " .. tostring(timeout) .. "с)")
      end
      if Bot.now() > (Bot.trigger.deadline or 0) then
        local text = tostring(step.trigger)
        Bot.trigger = nil
        return Bot.fail("не дождался сообщения «" .. text .. "» (шаг " ..
          tostring(Bot.i) .. ")")
      end
      return
    elseif step.wait then
      Bot.i = Bot.i + 1
      local sec = tonumber(step.wait) or 1
      Bot.dbg("[wait] пауза " .. tostring(sec) .. "с (комната " .. tostring(step.room) .. ")")
      Bot.wait(sec)
      return
    elseif not step.dir then
      Bot.i = Bot.i + 1
    elseif step.room and Bot.vnum() == tostring(step.room) then
      -- уже стоим там, куда ведёт шаг (рестарт/возврат)
      Bot.i = Bot.i + 1
    else
      return W.move(step)
    end
  end
end

-- проверка входящей строки на ожидаемое сообщение (шаг trigger)
function W.trigger_line(line)
  local wm = Bot.trigger
  if not wm then return false end
  if Bot.fold(line or ""):find(wm.text, 1, true) then
    Bot.trigger = nil
    Bot.echo("<green>[ждём] пришло: <reset>" .. tostring(line))
    if wm.final then
      if Bot.final_i == wm.step then Bot.final_i = Bot.final_i + 1 end
    elseif Bot.i == wm.step then
      Bot.i = Bot.i + 1
    end
    Bot.dbg("[trigger] сообщение пришло, продолжаю с шага " .. tostring(Bot.i))
    Bot.later(0.1, "пульс", W.pulse)
    return true
  end
  return false
end

-- финальные действия после маршрута. После «сл.воз» игрок может оказаться в
-- случайной комнате города, поэтому room/dir здесь не проверяем и не воюем.
-- Поддерживаются cmd / wait / trigger; всё выполняется до finish_zone и круга.
function W.final_pulse()
  if Bot.state ~= "walk" or Bot.paused then return end
  local fs = Bot.route and Bot.route.final_steps
  if not fs or #fs == 0 then
    Bot.final_i = nil
    return Bot.finish_zone("маршрут пройден")
  end
  if Bot.final_i == nil then Bot.final_i = 1 end

  while Bot.final_i <= #fs do
    local step = fs[Bot.final_i]
    if step.cmd then
      Bot.final_i = Bot.final_i + 1
      Bot.dbg("[final] " .. tostring(step.cmd))
      Bot.run_action(step.cmd)
      Bot.act_wait = true
      if (Bot.config.waitAfterAct or 0) > 0 then Bot.wait(Bot.config.waitAfterAct) end
      if Bot.waiting() or Bot.in_battle() or Bot.paused then return end
    elseif step.trigger then
      if not Bot.trigger or not Bot.trigger.final or Bot.trigger.step ~= Bot.final_i then
        local timeout = tonumber(step.timeout) or tonumber(Bot.config.triggerTimeout) or 10
        Bot.trigger = {
          text = Bot.fold(step.trigger),
          step = Bot.final_i,
          deadline = Bot.now() + timeout,
          final = true,
        }
        Bot.dbg("[final] жду сообщение: " .. tostring(step.trigger) ..
          " (шаг " .. tostring(Bot.final_i) .. ", таймаут " .. tostring(timeout) .. "с)")
      end
      if Bot.now() > (Bot.trigger.deadline or 0) then
        local text = tostring(step.trigger)
        Bot.trigger = nil
        return Bot.fail("не дождался сообщения «" .. text .. "» (финал, шаг " ..
          tostring(Bot.final_i) .. ")")
      end
      return
    elseif step.wait then
      Bot.final_i = Bot.final_i + 1
      local sec = tonumber(step.wait) or 1
      Bot.dbg("[final] пауза " .. tostring(sec) .. "с")
      Bot.wait(sec)
      return
    else
      Bot.warn("<orange>final_steps: шаг " .. tostring(Bot.final_i) ..
        " пропущен (поддерживаются cmd/wait/trigger)")
      Bot.final_i = Bot.final_i + 1
    end
  end

  Bot.final_i = nil
  return Bot.finish_zone("маршрут пройден")
end

-- ближайший шаг, чья комната — vnum: сначала вперёд от текущего, потом назад;
-- приоритет ходам (dir), затем действиям. Нужен, когда выход внезапно ведёт в
-- комнату, которая в маршруте есть, но в другом месте (динамический выход).
function W.find_route_room(vnum)
  vnum = tostring(vnum)
  local steps = Bot.route and Bot.route.steps
  if not steps then return nil end
  local function scan(from, to, step_by, dir_only)
    local j = from
    while (step_by > 0 and j <= to) or (step_by < 0 and j >= to) do
      local st = steps[j]
      if st and st.room and tostring(st.room) == vnum and (not dir_only or st.dir) then
        return j
      end
      j = j + step_by
    end
  end
  return scan(Bot.i, #steps, 1, true)
    or scan(Bot.i - 1, 1, -1, true)
    or scan(Bot.i, #steps, 1, false)
    or scan(Bot.i - 1, 1, -1, false)
end

function W.move(step, retry)
  if not step or not step.dir then return end
  -- в бою и пока ждём боевой промпт после атаки не двигаемся (ход отложим)
  if Bot.in_battle() or (Bot.combat and Bot.combat.pending and Bot.combat.pending()) then
    Bot.dbg("[move] бой/ожидание боя — ход «" .. tostring(step.dir) .. "» отложен")
    -- старый expect/deadline мог остаться от хода, который не отправился из-за
    -- боя. Иначе после боя pulse навсегда упирается в expect и бот стоит.
    Bot.expect = nil
    Bot.awaiting = false
    Bot.deadline = 0
    return
  end
  -- незавершённая сверка относится только к своему шагу
  if Bot.jump and Bot.jump.step ~= Bot.i then Bot.jump = nil end

  -- предпроверка по msdp.ROOM.EXITS: выход есть? ведёт туда, куда ждём?
  local expect_room = step.room and tostring(step.room) or nil
  local short = Bot.dir_short_of(step.dir)
  if short and Bot.exit_table() then
    local target = Bot.exit_vnum(short)
    if not target then
      -- MSDP выход не сообщает (скрытый/невидимый) — не блокируем, но предупреждаем:
      -- окончательное решение остаётся за сервером ("Вы не можете идти…")
      if not retry then
        Bot.warn("<gray>MSDP не показывает выход «" .. step.dir ..
          "» — пробую всё равно")
      end
    elseif step.room and target ~= tostring(step.room) then
      -- выход ведёт в другой VNUM. Если он есть в маршруте — идём туда и
      -- продолжаем с места, где этот VNUM в маршруте; если нет — стоп.
      local idx = W.find_route_room(target)
      if not idx then
        return Bot.fail("маршрут устарел: «" .. step.dir .. "» ведёт в " ..
          target .. ", а в маршруте " .. tostring(step.room) ..
          "; комнаты " .. target .. " в маршруте нет")
      end
      local already = Bot.jump and Bot.jump.step == Bot.i and
        tostring(Bot.jump.expect) == tostring(target)
      if not already then
        local key = tostring(Bot.vnum()) .. "|" .. tostring(step.dir) .. "|" .. tostring(target)
        Bot.jumpCounts = Bot.jumpCounts or {}
        local tries = (Bot.jumpCounts[key] or 0) + 1
        Bot.jumpCounts[key] = tries
        local limit = tonumber(Bot.config.dynamicResyncLimit) or 3
        if tries > limit then
          return Bot.fail("динамический выход «" .. step.dir .. "» в " ..
            tostring(Bot.vnum()) .. " снова ведёт в " .. target ..
            " — сверка по маршруту зациклилась (лимит " .. tostring(limit) .. ")")
        end
        Bot.warn("<orange>Выход «" .. step.dir .. "» ведёт в " .. target ..
          " (ждали " .. tostring(step.room) .. ") — в маршруте это шаг " ..
          tostring(idx) .. ", продолжу с шага " .. tostring(idx + 1) ..
          " (" .. tostring(tries) .. "/" .. tostring(limit) .. ")")
        Bot.jump = { expect = tostring(target), resume = idx + 1, step = Bot.i }
      end
      expect_room = tostring(target)
    else
      Bot.jump = nil
    end
  end

  Bot.recover.step = Bot.i
  Bot.sentDir = step.dir
  if expect_room then
    Bot.expect = expect_room
    Bot.awaiting = false
  else
    Bot.expect = nil
    Bot.awaiting = true   -- маршрут без VNUM: ждём любую смену комнаты
  end
  Bot.deadline = Bot.now() + Bot.config.waitAfterMove
  if not retry then Bot.doorAttempts = 0 end
  Bot.dbg(fmt("[move] %s -> %s (шаг %d/%d)", step.dir,
    tostring(step.room or "?"), Bot.i, #Bot.route.steps))
  if not Bot.send(step.dir) then
    Bot.expect = nil
    Bot.awaiting = false
    Bot.deadline = 0
  end
end

-- ===================== события комнаты =====================

function W.on_room(vnum)
  if Bot.state == "transit" then
    if Bot.entryTarget and vnum == Bot.entryTarget then
      Bot.echo("<green>На клетке входа")
      Bot.entry_begin()
    end
    return
  end
  if Bot.state ~= "walk" then return end
  if not Bot.route then return end

  -- успешное перемещение (любой путь: ack, ресинк, recovery) сбрасывает
  -- счётчик попыток двери, чтобы следующая дверь начинала с нуля
  local changed = Bot.lastRoomVnum ~= vnum
  if changed then
    Bot.lastRoomVnum = vnum
    Bot.doorAttempts = 0
    -- бой принадлежал комнате, из которой ушли: свежий блок выставит заново
    Bot.set_room_fight(false)
    if Bot.hold then
      Bot.hold = nil
      Bot.holdWarned = nil
      Bot.warn("<green>Движение восстановилось")
    end
  end

  -- recovery-путь: VNUM заранее неизвестен, идём по карте
  if Bot.walk_repair then return W.on_room_repair(vnum) end

  -- Действие (cmd) могло перенести в другую комнату (портал/вход). Если комната
  -- сменилась во время паузы после действия (или пока ждали комнату действия) —
  -- продолжаем сразу, не дожидаясь остатка waitAfterAct.
  if changed and Bot.act_wait and Bot.waiting() and
    not Bot.expect and not Bot.awaiting then
    Bot.act_wait = nil
    Bot.waitUntil = 0
    Bot.deadline = 0
    return Bot.later(0.1, "пульс", W.pulse)
  end

  if Bot.expect then
    if vnum == Bot.expect then
      Bot.expect = nil
      Bot.deadline = 0
      local jump = Bot.jump
      if jump and jump.step == Bot.i and tostring(jump.expect) == tostring(vnum) then
        Bot.i = jump.resume
        Bot.warn("<orange>Сверка по маршруту: " .. tostring(vnum) ..
          ", продолжаю с шага " .. tostring(Bot.i))
      else
        Bot.i = Bot.i + 1
      end
      Bot.jump = nil
      Bot.recover.count = 0
      Bot.recover.fails = 0
      Bot.doorAttempts = 0
      if Bot.config.lookEveryCell then Bot.send("look краткий") end
      return Bot.later(0.1, "пульс", W.pulse)
    end
    return W.desync(vnum)
  end

  if Bot.awaiting then
    Bot.awaiting = false
    Bot.deadline = 0
    Bot.jump = nil
    Bot.i = Bot.i + 1
    Bot.recover.fails = 0
    if Bot.config.lookEveryCell then Bot.send("look краткий") end
    return Bot.later(0.1, "пульс", W.pulse)
  end

  -- без ожидания: бот не двигался, но комнату сменили извне. Пропускаем только
  -- ходы (dir), у которых room — целевая комната; у действий (cmd) и пауз (wait)
  -- room — комната, где действие выполняется, поэтому их не перескакиваем (иначе
  -- два «войти» подряд: после первого портал меняет комнату, и бот пропускал
  -- второй «войти», переходя сразу к следующему действию).
  if Bot.i <= #Bot.route.steps then
    local step = Bot.route.steps[Bot.i]
    if step.dir and step.room and tostring(step.room) == Bot.vnum() then
      Bot.i = Bot.i + 1
      return Bot.later(0.1, "пульс", W.pulse)
    end
  end
end

-- ===================== десинк и recovery =====================

-- ближайший шаг впереди, ведущий в комнату vnum
function W.find_forward(vnum, from)
  if not Bot.route then return nil end
  for i = from, #Bot.route.steps do
    local step = Bot.route.steps[i]
    if step.dir and step.room and tostring(step.room) == tostring(vnum) then
      return i
    end
  end
  return nil
end

-- можно ли перепрыгнуть шаги from..to-1 (там только ходы, без действий)
function W.safe_skip(from, to)
  if to < from or to - from > 200 then return false end
  for i = from, to - 1 do
    local step = Bot.route.steps[i]
    if not step.dir then return false end
  end
  return true
end

function W.desync(vnum)
  local expect = Bot.expect
  Bot.jump = nil
  Bot.dbg(fmt("[desync] ждал %s, пришёл %s (шаг %d)", tostring(expect),
    tostring(vnum), Bot.i))

  local idx = W.find_forward(vnum, Bot.i)
  if idx and W.safe_skip(Bot.i, idx) then
    Bot.expect = nil
    Bot.deadline = 0
    Bot.i = idx + 1
    Bot.recover.count = 0
    Bot.warn("<orange>Ресинк по VNUM " .. tostring(vnum) ..
      ", пропущено шагов: " .. tostring(idx - Bot.recover.step))
    return Bot.later(0.1, "пульс", W.pulse)
  end

  return W.recover(expect)
end

-- позиция карты совпадает с живым VNUM (иначе getPath построит путь из чужой комнаты)
function W.map_sync()
  if not (map and map.currentRoom and map.currentRoom > 0) then return false end
  if not getRoomHashByID then return false end
  return tostring(getRoomHashByID(map.currentRoom)) == tostring(Bot.vnum())
end

-- путь по карте к комнате vnum (generic_mapper)
function W.path_to(vnum)
  if not (map and getPath and getRoomIDbyHash and map.currentRoom) then return nil end
  if not vnum or tostring(vnum) == "" then return nil end
  local id = getRoomIDbyHash(tostring(vnum))
  if not (id and id > 0) then return nil end
  if not map.currentRoom or map.currentRoom <= 0 then return nil end
  if not W.map_sync() then
    Bot.dbg("[recover] карта не синхронна: currentRoom=" .. tostring(map.currentRoom) ..
      " hash=" .. tostring(getRoomHashByID(map.currentRoom)) ..
      " vnum=" .. tostring(Bot.vnum()))
    return nil, "desync"
  end
  getPath(map.currentRoom, id)
  if not speedWalkDir or #speedWalkDir == 0 then return nil end
  local dirs = {}
  for i = 1, #speedWalkDir do dirs[i] = speedWalkDir[i] end
  return dirs
end

function W.recover(target)
  Bot.expect = nil
  Bot.awaiting = false
  Bot.deadline = 0
  Bot.jump = nil
  Bot.recover.count = Bot.recover.count + 1

  if not target or tostring(target) == "" then
    Bot.recover.fails = Bot.recover.fails + 1
    if Bot.recover.fails > Bot.config.moveFailLimit then
      return Bot.fail("не знаю, куда идти (нет VNUM маршрута)")
    end
    return Bot.later(0.5, "пульс", W.pulse)
  end

  if Bot.recover.count > Bot.config.recoverLimit then
    return Bot.fail("recovery исчерпан для комнаты " .. tostring(target))
  end

  local dirs, reason = W.path_to(target)
  if not dirs then
    if reason == "desync" then
      return Bot.fail("карта стоит на " .. tostring(getRoomHashByID(map.currentRoom)) ..
        ", а вы в " .. tostring(Bot.vnum()) ..
        " — включи mapping (или промепь комнату), иначе recovery невозможен")
    end
    return Bot.fail("нет пути к комнате " .. tostring(target) ..
      " (карта не промеплена?)")
  end
  Bot.walk_repair = { dirs = dirs, target = tostring(target), last = nil }
  Bot.warn("<orange>Recovery: иду по карте к " .. tostring(target) ..
    " (" .. tostring(#dirs) .. " шагов)")
  return W.repair_step()
end

function W.repair_step()
  local rep = Bot.walk_repair
  if not rep then return W.pulse() end
  if Bot.in_battle() then return end   -- в бою не двигаемся (recovery отложим)

  if #rep.dirs == 0 then
    Bot.walk_repair = nil
    Bot.deadline = 0
    local vnum = Bot.vnum()
    if vnum == rep.target then
      Bot.warn("<green>Recovery: на месте (" .. tostring(vnum) .. ")")
      W.resync()
      return Bot.later(0.1, "пульс", W.pulse)
    end
    Bot.recover.count = Bot.recover.count + 1
    if Bot.recover.count > Bot.config.recoverLimit then
      return Bot.fail("recovery не довёл до " .. rep.target ..
        " (стою в " .. tostring(vnum) .. ")")
    end
    local more, reason = W.path_to(rep.target)
    if not more then
      if reason == "desync" then
        return Bot.fail("recovery прерван: карта рассинхронизирована с msdp.ROOM.VNUM")
      end
      return Bot.fail("recovery: пути к " .. rep.target .. " больше нет")
    end
    Bot.walk_repair = { dirs = more, target = rep.target }
    return W.repair_step()
  end

  local dir = table.remove(rep.dirs, 1)
  rep.last = dir
  Bot.deadline = Bot.now() + Bot.config.waitAfterMove
  Bot.dbg("[repair] " .. tostring(dir) .. " (осталось " .. tostring(#rep.dirs) .. ")")
  if not Bot.send(dir) then Bot.deadline = 0 end
end

function W.on_room_repair(vnum)
  local rep = Bot.walk_repair
  if not rep then return end
  Bot.deadline = 0
  Bot.doorAttempts = 0
  if #rep.dirs == 0 then
    Bot.walk_repair = nil
    if vnum == rep.target then
      Bot.warn("<green>Recovery: на месте (" .. tostring(vnum) .. ")")
      W.resync()
      return Bot.later(0.1, "пульс", W.pulse)
    end
    return W.recover(rep.target)
  end
  return Bot.later(0.1, "повтор шага", W.repair_step)
end

-- ===================== запрет хода и таймауты =====================

-- сервер: "Вы не можете идти...", "Попробуйте сначала открыть ...", "… заперт."
-- Двери открывает профильный триггер (он смотрит на глобальную переменную dir,
-- которую выставляет Bot.send), бот только повторяет шаг. Команд открытия не
-- шлём и в recovery из-за двери не уходим: getPath упирается в закрытую дверь,
-- и бот вставал с «нет пути» вместо того, чтобы пройти дальше.
function W.blocked(kind, door)
  if Bot.state ~= "walk" then return end

  kind = kind or "направление"
  local step = Bot.route and Bot.route.steps[Bot.i]
  local is_door = (kind == "дверь" or kind == "заперто")

  -- «… заперт.» бывает и про контейнер (ответ на «оов сун»), а не про выход.
  -- Такое сообщение не должно ни ретраить ход, ни останавливать бота.
  if is_door then
    if not step or not step.dir then
      Bot.dbg("[door] «" .. tostring(door or "?") .. "» при шаге без хода (" ..
        tostring(step and step.cmd or "?") .. ") — не дверь, пропускаю")
      return
    end
    if not (Bot.expect or Bot.awaiting) then
      Bot.dbg("[door] «" .. tostring(door or "?") ..
        "» без ожидания хода — не дверь, пропускаю")
      return
    end
    if Bot.is_container_name and Bot.is_container_name(door) then
      Bot.dbg("[door] «" .. tostring(door or "?") ..
        "» — контейнер, не дверь, пропускаю")
      return
    end
  end

  -- замер: сервер может ответить и обычным отказом хода; это не повод
  -- расходовать лимит — повторяем, пока персонаж не освободится
  if Bot.hold and step and step.dir then
    Bot.deadline = 0
    return Bot.later(Bot.config.holdRetryDelay or 1.0, "замер", function()
      if Bot.state == "walk" and Bot.hold and Bot.route and
        Bot.route.steps[Bot.i] == step then
        W.move(step, true)
      end
    end)
  end

  local limit = is_door and (Bot.config.doorRetryLimit or 5) or 1

  if step and step.dir and Bot.doorAttempts < limit then
    Bot.doorAttempts = Bot.doorAttempts + 1
    -- ожидание шага оставляем: иначе tick вызовет pulse и отправит ход второй раз
    Bot.deadline = 0
    Bot.warn("<orange>" ..
      (is_door and ("Дверь «" .. tostring(door or "?") .. "» закрыта")
        or ("Ход «" .. step.dir .. "» отклонён")) ..
      " — повторяю «" .. step.dir .. "» (" .. tostring(Bot.doorAttempts) ..
      "/" .. tostring(limit) .. ")")
    return Bot.later(Bot.config.doorRetryDelay or 0.4, "повтор хода", function()
      if Bot.state == "walk" then W.move(step, true) end
    end)
  end

  Bot.expect = nil
  Bot.awaiting = false
  Bot.deadline = 0

  if is_door then
    return Bot.fail("дверь «" .. tostring(door or "?") .. "» не открылась (шаг " ..
      tostring(Bot.i) .. "/" ..
      tostring(#(Bot.route and Bot.route.steps or {})) .. ", " ..
      tostring(step and (step.dir or step.cmd) or "?") .. ")")
  end
  return Bot.fail("не прохожу «" .. tostring(step and step.dir) .. "» (" .. kind .. ")")
end

-- молчание сервера после хода
function W.timeout()
  if Bot.state ~= "walk" then return end

  -- пока персонаж замер, сервер не присылает новую комнату: повторяем ход
  -- без увеличения doorAttempts/recover и без recovery
  if Bot.hold then
    local rep = Bot.walk_repair
    local step = Bot.route and Bot.route.steps[Bot.i]
    if rep then
      Bot.deadline = 0
      return Bot.later(Bot.config.holdRetryDelay or 1.0, "замер", function()
        if Bot.state ~= "walk" or not Bot.hold then return end
        if Bot.walk_repair ~= rep then return end
        if rep.last then
          Bot.deadline = Bot.now() + (Bot.config.waitAfterMove or 3)
          Bot.send(rep.last)
        else
          W.repair_step()
        end
      end)
    elseif step and step.dir then
      Bot.deadline = 0
      return Bot.later(Bot.config.holdRetryDelay or 1.0, "замер", function()
        if Bot.state ~= "walk" or not Bot.hold then return end
        if Bot.route and Bot.route.steps[Bot.i] == step then
          W.move(step, true)
        end
      end)
    end
  end

  local rep = Bot.walk_repair
  if rep then
    Bot.doorAttempts = Bot.doorAttempts + 1
    if Bot.doorAttempts > 2 then
      Bot.walk_repair = nil
      Bot.recover.fails = Bot.recover.fails + 1
      if Bot.recover.fails > Bot.config.moveFailLimit then
        return Bot.fail("recovery: ходы не проходят")
      end
      return W.recover(rep.target)
    end
    if rep.last then
      -- дверь открывает профильный триггер по переменной dir, мы только повторяем
      Bot.deadline = Bot.now() + Bot.config.waitAfterMove
      return Bot.later(Bot.config.doorRetryDelay or 0.4, "повтор хода", function()
        if Bot.state == "walk" and Bot.walk_repair == rep then Bot.send(rep.last) end
      end)
    end
    Bot.deadline = 0
    return W.repair_step()
  end

  local step = Bot.route and Bot.route.steps[Bot.i]
  if step and step.dir and Bot.doorAttempts < (Bot.config.doorRetryLimit or 3) then
    Bot.doorAttempts = Bot.doorAttempts + 1
    Bot.warn("<orange>Нет ответа на «" .. step.dir .. "» — повтор (" ..
      tostring(Bot.doorAttempts) .. "/" ..
      tostring(Bot.config.doorRetryLimit or 3) .. ")")
    -- ожидание шага оставляем, deadline = 0: tick не должен звать pulse
    Bot.deadline = 0
    return Bot.later(Bot.config.doorRetryDelay or 0.4, "повтор хода", function()
      if Bot.state == "walk" then W.move(step, true) end
    end)
  end

  Bot.recover.fails = Bot.recover.fails + 1
  if Bot.recover.fails > Bot.config.moveFailLimit then
    return Bot.fail("ход «" .. tostring(step and step.dir) .. "» не проходит")
  end
  W.recover(step and step.room or nil)
end

-- после боя: продолжаем с того же шага
function W.resume()
  if Bot.state ~= "walk" then return end
  Bot.expect = nil
  Bot.awaiting = false
  Bot.deadline = 0
  return W.pulse()
end
