-- Создайте скрипт:
-- name: BotCombat
-- body:
-- =====================================================================
-- BotCombat — бой на клетке: атака мобов ПО НОМЕРУ (botkill)
-- =====================================================================
-- Существа в комнате нумеруются по порядку входа: я №1, дальше согрупники,
-- петы, и только потом мобы, которые были здесь до нас. Поэтому первый
-- «до-наш» моб — group_count + pet_count + 1: ровно это считает getTargets()
-- в autoAttack.lua, и ровно это делает алиас botkill
-- (sendWithClear(getAttack())).
--
-- Значит, имена мобов боту не нужны. Он решает только одно: есть ли в
-- комнате существо, которое не игрок. Игроки отличаются от мобов лишь по
-- assist_who (игроки и согрупники) — цвет у всех
-- красный, мобы и игроки неразличимы.
--
-- Тип зоны (mode в файле зоны):
--   all  — бить всё, что не игрок и не в noattack (по умолчанию);
--   list — бить только kill и aggro (агрессоры учатся по «напал на вас»).
-- Новую цель в list-зоне добавляет .бот бить: ручная атака запоминает имя.
--
-- Способ атаки настраивается (.бот атака): botkill | alias | command | lua,
-- см. раздел «способ атаки» в BotCore.
--
-- Зависимости: BotCore.
-- =====================================================================

Bot = Bot or {}
Bot.combat = Bot.combat or {}

local C = Bot.combat

-- существа комнаты: { index, line, name, player }
-- name = строка как есть (по ней не бьём: цель считается номером через botkill)
function C.creatures()
  local out = {}
  for i, line in ipairs(Bot.mobs or {}) do
    local player = (Bot.is_protected and Bot.is_protected(line)) and true or false
    if player then Bot.playerInRoom = true end
    out[#out + 1] = { index = i, line = line, name = line, player = player }
  end
  return out
end

-- только игроки (assist_who / «не бить»)
function C.players()
  local out = {}
  for _, c in ipairs(C.creatures()) do
    if c.player then out[#out + 1] = c end
  end
  return out
end

-- все враждебные существа комнаты: не игрок и не в списке «не бить»
function C.attackable()
  local out = {}
  for _, c in ipairs(C.creatures()) do
    if not c.player and not (Bot.is_noattack and Bot.is_noattack(c.name)) then
      out[#out + 1] = c
    end
  end
  return out
end

-- цели по правилам зоны: в list-зоне бьём только kill ∪ aggro (остальные — мимо)
function C.mobs()
  local out = {}
  local rules = Bot.zone_rules and Bot.zone_rules() or nil
  for _, c in ipairs(C.attackable()) do
    if not rules or rules.mode ~= "list" or
       not Bot.rule_target or Bot.rule_target(c.name) then
      out[#out + 1] = c
    end
  end
  return out
end

-- сколько существ в комнате всего (без игроков) — для диагностики
function C.mob_total()
  local n = 0
  for _, c in ipairs(C.creatures()) do
    if not c.player then n = n + 1 end
  end
  return n
end

-- номер k-го моба в игре (k = 1 — первый моб, который был тут до нас)
function C.target_number(k)
  return Bot.target_number(k)
end

-- сброс попыток при смене комнаты
function C.sync_room()
  local vnum = Bot.vnum()
  if C.room ~= vnum then
    C.room = vnum
    C.attempts = 0
    C.skipRoom = nil
    C.refreshed = nil
    C.attacked = false
  end
end

function C.should_fight()
  if Bot.paused or Bot.in_battle() then return false end
  C.sync_room()
  if C.skipRoom and C.skipRoom == C.room then return false end
  -- один botkill на комнату: количество мобов не повод бить ещё раз
  if C.attacked then
    Bot.dbg("[combat] в комнате уже били — второй раз не бьём")
    return false
  end
  if C.pending() then return false end
  local mobs = C.mobs()
  if #mobs == 0 then return false end
  -- опциональный предохранитель; в группе он не нужен: botkill пропускает
  -- согрупников по group_count, поэтому по умолчанию выключен
  if Bot.config.skipFightWithPlayer and Bot.playerInRoom then return false end
  return true
end

-- команда атаки отправлена, боевой промпт ещё не пришёл: маршрут должен ждать
function C.pending()
  if Bot.in_battle() then return false end
  if not C.engagedAt then return false end
  return (Bot.now() - C.engagedAt) < (Bot.config.combatGrace or 2)
end

-- одна атака текущим способом (.бот атака); true — команда ушла
-- first — конкретное существо (ручная атака), иначе первая цель зоны
function C.attack(first)
  if Bot.paused then return false end
  local targets = C.mobs()
  first = first or targets[1]
  if not first then return false end
  -- номер цели — по месту существа в комнате: мирный моб перед ним тоже его занимает
  local n = Bot.target_number(first.index)
  local sent, what = Bot.attack_do(n)
  if not sent then return false end
  C.target = "№" .. tostring(n)
  C.lastCmd = what
  C.since = Bot.now()
  C.engagedAt = Bot.now()
  C.warned = false
  C.attacked = true
  if Bot.stats then Bot.stats.kills = (Bot.stats.kills or 0) + 1 end
  Bot.echo("<red>Бой:<reset> " .. tostring(what) .. "<gray> (№" .. tostring(n) ..
    ", целей " .. tostring(#targets) .. " из " .. tostring(#C.attackable()) .. ")")
  return true
end

function C.engage()
  if Bot.paused or Bot.in_battle() then return end
  C.sync_room()
  if C.attacked then return end

  if #C.mobs() == 0 then return end

  -- в комнате уже идёт бой (наш таргет пропал, партнёры дерутся): повторно не
  -- бьём — первый botkill ушёл при входе, дальше ассистит профиль («пом»)
  if (C.attempts or 0) > 0 and Bot.room_fight_wait and Bot.room_fight_wait() then
    C.attempts = 0
    Bot.dbg("[combat] в комнате идёт бой — повторную атаку не шлём")
    return false
  end

  -- цели могли умереть, а список устарел (тогда летят удары «в пустоту»):
  -- перед повторной попыткой один раз обновляем комнату
  if (C.attempts or 0) > 0 and not Bot.battle and not C.refreshed then
    C.refreshed = true
    Bot.dbg("[combat] боя нет — обновляю комнату (look краткий)")
    Bot.send("look краткий")
    return true
  end

  C.attempts = (C.attempts or 0) + 1
  if C.attempts > 3 then
    C.skipRoom = C.room
    Bot.warn("<orange>Не добил мобов в " .. tostring(C.room) ..
      " — иду дальше, вернусь на обратном пути")
    return Bot.walk and Bot.walk.pulse and Bot.walk.pulse()
  end

  if not C.attack() then
    -- способ атаки ничего не отправил (антибот, пустой getAttack, ошибка lua):
    -- попытку не тратим, но и не спамим — ждём следующий промпт
    C.attempts = math.max(0, (C.attempts or 1) - 1)
    C.engagedAt = Bot.now()
    Bot.dbg("[combat] атака не отправлена, жду промпт")
    return false
  end
  return true
end

-- ручная атака: ".бот бить" (вне маршрута, не ждёт условий прохода).
-- В list-зоне (и при записи) выбранное существо запоминается как цель зоны.
function C.manual()
  if Bot.paused then
    Bot.warn("<orange>Бот на паузе. Снять: .бот пауза 0")
    return false
  end
  local mobs = C.attackable()
  if #mobs == 0 then
    Bot.warn("Нет целей: в комнате только игроки / список «не бить» (нужен свежий look)")
    return false
  end
  C.sync_room()
  local first = mobs[1]
  if Bot.mark_kill then Bot.mark_kill(first.name) end
  return C.attack(first)
end

-- предупреждение о затянувшемся бое (вызывается из Bot.tick через Bot.walk)
function C.check_timeout()
  if not Bot.in_battle() then return end
  if not C.since or C.since == 0 then C.since = Bot.now() return end
  if C.warned then return end
  if Bot.now() - C.since > (Bot.config.combatTimeout or 180) then
    C.warned = true
    Bot.warn("<orange>Бой идёт дольше " .. tostring(Bot.config.combatTimeout) ..
      "с: " .. tostring(Bot.target))
  end
end

