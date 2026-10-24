-- Создайте триггеры:
-- name: Room Exits Catch
-- regex: ^\[ Exits: (?<exits>[NESWUD\(\)\s]+) \]$
-- regex: ^\[ Exits: (?<exits>None!) \]$
-- body: MudMapper.update_room(matches.exits)

-- name: Vision Fail Trigger
-- excact match: Здесь темно...
-- exact match: Вы последовали за кем-то.
-- body: MudMapper.on_vision_fail()

-- Создайте скрипт:
-- name: MudMapper
-- body:
-- =====================================================================
-- MudMapper — обёртка над generic_mapper, работающая от MSDP ROOM (VNUM)
-- =====================================================================
MudMapper = MudMapper or {}

-- любой вариант написания направления -> короткое английское
MudMapper.dir_map = {
  ["n"]="n", ["north"]="n", ["север"]="n", ["с"]="n",
  ["s"]="s", ["south"]="s", ["юг"]="s", ["ю"]="s",
  ["e"]="e", ["east"]="e", ["восток"]="e", ["в"]="e",
  ["w"]="w", ["west"]="w", ["запад"]="w", ["з"]="w",
  ["u"]="u", ["up"]="u", ["вверх"]="u", ["вв"]="u",
  ["d"]="d", ["down"]="d", ["вниз"]="d", ["вн"]="d",
}

-- обратные направления (для связывания комнат)
MudMapper.reverse_dir = { n="s", s="n", e="w", w="e", u="d", d="u" }

-- смещения координат по направлениям (north=+y, east=+x)
MudMapper.dir_offset = {
  n = {0, 1, 0}, s = {0, -1, 0}, e = {1, 0, 0}, w = {-1, 0, 0},
  u = {0, 0, 1}, d = {0, 0, -1},
}

-- направления, которые считаем «выходами»
MudMapper.exit_dirs = { n=true, e=true, s=true, w=true, u=true, d=true }

-- короткое направление -> числовой код Mudlet (для стабов)
MudMapper.stub_num = { n=1, e=4, s=6, w=5, u=9, d=10 }
-- числовой код Mudlet -> короткое направление
MudMapper.num_dir = { [1]="n", [4]="e", [6]="s", [5]="w", [9]="u", [10]="d" }

-- найти/создать зону по имени и вернуть её числовой ID (не двигая комнаты)
function MudMapper.area_id(name)
  local n = tostring(name or "sowmud")
  local areas = getAreaTable() or {}
  for k, v in pairs(areas) do
    if string.lower(tostring(k)) == string.lower(n) then
      return v
    end
  end
  return addAreaName(n)
end

-- является ли команда входом в портал (enter / войти, с аргументом или без)
function MudMapper.is_portal_cmd(cmd)
  if not cmd then return nil end
  local c = string.lower(string.trim(cmd))
  -- string.lower не трогает кириллицу — приводим первую «В» вручную
  c = c:gsub("^В", "в")
  if c == "войти" or c:match("^войти%s+%S") or c == "enter" or c:match("^enter%s+%S") then
    return string.trim(cmd)
  end
  return nil
end

-- разместить комнату в своей зоне (справа от самой правой комнаты зоны)
function MudMapper.place_in_area(room_id, area_id)
  local rooms = getAreaRooms(area_id) or {}
  local best, bx, by, bz
  for _, id in ipairs(rooms) do
    if id ~= room_id then
      local x, y, z = getRoomCoordinates(id)
      if not best or x > bx then
        best, bx, by, bz = id, x, y, z
      end
    end
  end
  local nx, ny, nz
  if best then
    nx, ny, nz = bx + 1, by, bz
    setRoomCoordinates(room_id, nx, ny, nz)
  else
    nx, ny, nz = 0, 0, 0
    setRoomCoordinates(room_id, 0, 0, 0)
  end
  MudMapper.dbg("[place] room=" .. tostring(room_id) .. " -> (" .. tostring(nx) .. "," .. tostring(ny) .. "," .. tostring(nz) .. ")" .. (best and (" справа от " .. tostring(best)) or " (зона пуста)"))
end

-- печать сообщений в стиле generic_mapper
MudMapper.tag = "<112,229,0>(<73,149,0>MudMapper<112,229,0>): <255,255,255>"
function MudMapper.echo(msg)
  decho(MudMapper.tag)
  cecho(msg)
  echo("\n")
end

-- отладочный вывод: печатается только при map.configs.debug (команда "map debug")
function MudMapper.dbg(msg)
  if map and map.configs and map.echo then
    map.echo("MudMapper: " .. tostring(msg), true)
  end
end

-- утилита: собрать "dir->target, dir->target" из таблицы выходов
function MudMapper.exits_desc(t)
  if type(t) ~= "table" then return "-" end
  local out = {}
  for dir, target in pairs(t) do
    out[#out+1] = tostring(dir) .. "->" .. tostring(target)
  end
  table.sort(out)
  if #out == 0 then return "-" end
  return table.concat(out, ", ")
end

-- подписка на MSDP-переменные
function MudMapper.on_protocol(event, protocol)
  if protocol == "MSDP" then
    for _, v in ipairs({"ROOM","HEALTH","MANA","MOVEMENT","LEVEL","EXPERIENCE","EXPERIENCE_MAX","MONEY"}) do
      sendMSDP("REPORT", v)
    end
  end
end

-- сигнал смены комнаты из MSDP
function MudMapper.on_msdp_room()
  MudMapper.update_room()
end

-- диагностика отправленных команд (видно, что попадает в move_queue generic_mapper)
function MudMapper.on_send(event, data)
  MudMapper.last_cmd = tostring(data)
  MudMapper.dbg("[send] " .. MudMapper.last_cmd)
end

-- нормализация направления
function MudMapper.normalize_dir(dir)
  if not dir then return nil end
  return MudMapper.dir_map[string.lower(string.trim(dir))]
end

-- приводим выходы произвольной комнаты в соответствие с её MSDP-выходами
function MudMapper.wire_room(room_id, msdp_exits, tag)
  if not room_id or type(msdp_exits) ~= "table" then return end
  tag = tag or "wire"

  MudMapper.dbg("[" .. tag .. "] room=" .. tostring(room_id) .. " msdp: " .. MudMapper.exits_desc(msdp_exits))

  -- направления, которые должны быть на комнате (по MSDP)
  local msdp_dirs = {}
  for d, _ in pairs(msdp_exits) do
    local s = MudMapper.normalize_dir(d)
    if s and MudMapper.exit_dirs[s] then msdp_dirs[s] = true end
  end

  -- чистка: убираем реальные выходы, которых нет в MSDP
  local existing = getRoomExits(room_id) or {}
  MudMapper.dbg("[" .. tag .. "] existing: " .. MudMapper.exits_desc(existing))
  for dir, _ in pairs(existing) do
    local s = MudMapper.normalize_dir(dir)
    if s and MudMapper.exit_dirs[s] and not msdp_dirs[s] then
      MudMapper.dbg("[" .. tag .. "] REMOVE " .. tostring(dir))
      setExit(room_id, -1, s)
    end
  end

  -- чистка: убираем стабы, которых нет в MSDP
  local stubs = getExitStubs(room_id)
  if type(stubs) == "table" then
    for _, num in pairs(stubs) do
      local s = MudMapper.num_dir[num]
      if s and not msdp_dirs[s] then
        MudMapper.dbg("[" .. tag .. "] REMOVE stub " .. tostring(s))
        setExitStub(room_id, num, false)
      end
    end
  end

  -- установка выходов из MSDP: реальный выход, если комната известна, иначе стаб
  for d, target in pairs(msdp_exits) do
    local short = MudMapper.normalize_dir(d)
    if short and MudMapper.exit_dirs[short] then
      local num = MudMapper.stub_num[short]
      local tid = getRoomIDbyHash(tostring(target))
      if tid and tid > 0 then
        MudMapper.dbg("[" .. tag .. "] SET " .. tostring(short) .. " -> " .. tostring(tid))
        setExit(room_id, tid, short)
        if num then setExitStub(room_id, num, false) end
      else
        MudMapper.dbg("[" .. tag .. "] stub " .. tostring(short) .. " -> " .. tostring(target) .. " (комната ещё не на карте)")
        if num then setExitStub(room_id, num, true) end
      end
    end
  end

  MudMapper.dbg("[" .. tag .. "] final: " .. MudMapper.exits_desc(getRoomExits(room_id)))
end

-- связываем выходы текущей комнаты с уже известными комнатами по VNUM
function MudMapper.wire_exits()
  if not map then return end
  if not map.mapping then return end
  local r = msdp.ROOM
  local cur = map.currentRoom
  if not r or not cur or type(r.EXITS) ~= "table" then return end
  -- защита: выходы вешаем только на комнату, чей хэш == текущему VNUM
  if getRoomHashByID(cur) ~= tostring(r.VNUM) then
    MudMapper.dbg("[wire] хэш комнаты не совпадает с VNUM — пропуск")
    return
  end
  MudMapper.wire_room(cur, r.EXITS, "wire")
end

-- восстанавливаем выходы ПРЕДЫДУЩЕЙ комнаты по сохранённому MSDP
-- (move_map/connect_rooms с протухшим направлением может затереть верный выход)
function MudMapper.restore_prev()
  if not map then return end
  if not map.mapping then return end
  local prev_vnum = MudMapper.prev_vnum
  if not prev_vnum or type(MudMapper.prev_exits) ~= "table" then return end
  local prev_id = getRoomIDbyHash(prev_vnum)
  if prev_id and prev_id > 0 and prev_id ~= map.currentRoom then
    MudMapper.wire_room(prev_id, MudMapper.prev_exits, "prev")
  end
end

-- парсим строку выходов "[ Exits: (S) W ]" и расставляем двери
function MudMapper.apply_doors(exits_text)
  if not map then return end
  if not map.mapping then return end
  local cur = map.currentRoom
  if not cur or not exits_text then return end
  if exits_text:lower():find("none") then
    MudMapper.dbg("[doors] выходов нет")
    return
  end

  local closed, seen = {}, {}
  for d in string.gmatch(exits_text, "%(([%a]+)%)") do
    local s = MudMapper.normalize_dir(d)
    if s then closed[s] = true end
  end
  for d in string.gmatch(exits_text, "[%a]+") do
    local s = MudMapper.normalize_dir(d)
    if s then seen[s] = true end
  end

  MudMapper.dbg("[doors] text=\"" .. tostring(exits_text) .. "\"")

  local doors = getDoors(cur) or {}
  for s in pairs(seen) do
    if closed[s] then
      if doors[s] ~= 2 then
        MudMapper.dbg("[doors] " .. tostring(s) .. " -> closed")
        map.set_door(s, "closed")
      end
    else
      if doors[s] and doors[s] >= 2 then
        MudMapper.dbg("[doors] " .. tostring(s) .. " -> open")
        map.set_door(s, "open")
      end
    end
  end
end

-- связываем текущую комнату с предыдущей и исправляем её координаты по MSDP
-- (чистку мусора выполняет restore_prev по сохранённому MSDP предыдущей комнаты)
function MudMapper.link_prev()
  if not map then return end
  if not map.mapping then return end
  local cur = map.currentRoom
  local prev_vnum = MudMapper.prev_vnum
  if not cur or not prev_vnum then return end

  local ex = msdp.ROOM and msdp.ROOM.EXITS
  local back_dir
  if type(ex) == "table" then
    for d, target in pairs(ex) do
      if tostring(target) == prev_vnum then
        back_dir = MudMapper.normalize_dir(d)
        break
      end
    end
  end
  if not back_dir then
    MudMapper.dbg("[link] cur=" .. tostring(cur) .. " prev_vnum=" .. tostring(prev_vnum) .. " — нет обратного выхода")
    local prev_id = getRoomIDbyHash(prev_vnum)
    if prev_id and prev_id > 0 and prev_id ~= cur then
      local cmd = MudMapper.is_portal_cmd(MudMapper.last_cmd)
      if cmd then
        addSpecialExit(prev_id, cur, cmd)
        local old = getRoomUserData(cur, "portals") or ""
        local back = tostring(prev_id) .. ":" .. cmd
        setRoomUserData(cur, "portals", old ~= "" and (old .. "," .. back) or back)
        MudMapper.dbg("[link] портал: " .. tostring(prev_vnum) .. " --'" .. cmd .. "'--> " .. tostring(cur))
        -- координаты ставим только для только что созданной комнаты
        if MudMapper.just_created == cur then
          if getRoomArea(prev_id) == getRoomArea(cur) then
            local px, py, pz = getRoomCoordinates(prev_id)
            setRoomCoordinates(cur, px + 1, py, pz)
            MudMapper.dbg("[link] портал в той же зоне: ставлю рядом (" .. tostring(px+1) .. "," .. tostring(py) .. "," .. tostring(pz) .. ")")
          else
            MudMapper.place_in_area(cur, getRoomArea(cur))
            MudMapper.dbg("[link] портал в другую зону: размещаю в своей зоне")
          end
        end
      end
    end
    return   -- телепорт/реколл (не портал) — не трогаем
  end

  local prev_id = getRoomIDbyHash(prev_vnum)
  MudMapper.dbg("[link] cur=" .. tostring(cur) .. " prev_vnum=" .. tostring(prev_vnum) .. " prev_id=" .. tostring(prev_id) .. " back_dir=" .. tostring(back_dir))

  if prev_id and prev_id > 0 and prev_id ~= cur then
    local fwd = MudMapper.reverse_dir[back_dir]
    MudMapper.dbg("[link] fwd=" .. tostring(fwd))

    if fwd then
      MudMapper.dbg("[link] setExit(prev=" .. tostring(prev_id) .. " -> cur=" .. tostring(cur) .. ", " .. tostring(fwd) .. ")")
      setExit(prev_id, cur, fwd)
    end
    MudMapper.dbg("[link] setExit(cur=" .. tostring(cur) .. " -> prev=" .. tostring(prev_id) .. ", " .. tostring(back_dir) .. ")")
    setExit(cur, prev_id, back_dir)

    -- исправляем координаты по направлению из MSDP
    local off = MudMapper.dir_offset[fwd]
    if off then
      local px, py, pz = getRoomCoordinates(prev_id)
      local cx, cy, cz = getRoomCoordinates(cur)
      MudMapper.dbg("[link] coords cur: (" .. tostring(cx) .. "," .. tostring(cy) .. "," .. tostring(cz) ..
        ") -> (" .. tostring(px+off[1]) .. "," .. tostring(py+off[2]) .. "," .. tostring(pz+off[3]) .. ")")
      setRoomCoordinates(cur, px + off[1], py + off[2], pz + off[3])
    end
  end
end

-- выравниваем позицию карты по VNUM и центрируем маркер игрока
function MudMapper.sync_position(vnum, r)
  MudMapper.just_created = nil
  -- самая первая комната: currentRoom может быть nil — создаём её в (0,0,0)
  if not map.currentRoom then
    if map.mapping then
      local id = getRoomIDbyHash(vnum)
      if not (id and id > 0) then
        id = createRoomID()
        addRoom(id)
        setRoomName(id, "[" .. vnum .. "] " .. (r.NAME or "Неизвестно"))
        setRoomIDbyHash(id, vnum)
        setRoomArea(id, MudMapper.area_id(r.AREA or "sowmud"))
        setRoomCoordinates(id, 0, 0, 0)
        MudMapper.just_created = id
        MudMapper.dbg("[sync] создаю первую комнату id=" .. tostring(id) .. " в (0,0,0)")
      end
      raiseEvent("sysManualLocationSetEvent", id)
    else
      MudMapper.dbg("[sync] currentRoom=nil и маппинг выключен — пропуск")
    end
    return
  end

  local cur_hash = getRoomHashByID(map.currentRoom)
  MudMapper.dbg("[sync] vnum=" .. tostring(vnum) .. " cur=" .. tostring(map.currentRoom) .. " cur_hash=" .. tostring(cur_hash))

  if cur_hash ~= vnum then
    local id = getRoomIDbyHash(vnum)
    if id and id > 0 then
      MudMapper.dbg("[sync] комната уже есть id=" .. tostring(id) .. " — переключаюсь")
      raiseEvent("sysManualLocationSetEvent", id)
    elseif map.mapping then
      id = createRoomID()
      addRoom(id)
      setRoomName(id, "[" .. vnum .. "] " .. (r.NAME or "Неизвестно"))
      setRoomIDbyHash(id, vnum)
      setRoomArea(id, MudMapper.area_id(r.AREA or "sowmud"))
      local x, y, z = getRoomCoordinates(map.currentRoom)
      MudMapper.dbg("[sync] создаю комнату id=" .. tostring(id) .. " в (" .. tostring(x+1) .. "," .. tostring(y) .. "," .. tostring(z) .. ")")
      setRoomCoordinates(id, x + 1, y, z)
      MudMapper.just_created = id
      raiseEvent("sysManualLocationSetEvent", id)
    else
      MudMapper.dbg("[sync] маппинг выключен — комнату не создаю")
      return   -- маппинг выключен: не создаём новые комнаты
    end
  end

  centerview(map.currentRoom)
end

-- главная функция: обрабатываем текущую комнату из MSDP
function MudMapper.update_room(exits_text)
  if not map then return end
  local r = msdp.ROOM
  if not r or not r.VNUM then
    MudMapper.dbg("[room] нет msdp.ROOM/VNUM")
    return
  end
  local vnum = tostring(r.VNUM)
  local area = r.AREA or "sowmud"

  MudMapper.dbg("[room] vnum=" .. vnum .. " area=" .. area .. " last_vnum=" .. tostring(MudMapper.last_vnum))

  if MudMapper.last_vnum == vnum and map.currentRoom then
    MudMapper.dbg("[room] та же комната " .. vnum .. " — только двери")
    MudMapper.apply_doors(exits_text)
    return
  end
  MudMapper.prev_vnum = MudMapper.last_vnum
  MudMapper.last_vnum = vnum
  MudMapper.dbg("[room] prev_vnum=" .. tostring(MudMapper.prev_vnum) .. " last_vnum=" .. tostring(MudMapper.last_vnum))

  map.prompt.hash = vnum
  map.prompt.room = "[" .. vnum .. "] " .. (r.NAME or "Неизвестно")

  MudMapper.dbg("[room] msdp exits: " .. MudMapper.exits_desc(r.EXITS))

  -- маппинг включается ТОЛЬКО вручную (start mapping)
  if map.mapping and area ~= MudMapper.current_area then
    MudMapper.dbg("[room] смена области: " .. tostring(MudMapper.current_area) .. " -> " .. area)
    MudMapper.current_area = area
    -- map.set_area НЕ зовём: он перебросил бы ТЕКУЩУЮ (старую) комнату в новую зону
    centerview(map.currentRoom)
  end

  MudMapper.sync_position(vnum, r)
  MudMapper.wire_exits()
  MudMapper.restore_prev()
  MudMapper.link_prev()
  MudMapper.apply_doors(exits_text)

  -- сохраняем MSDP-выходы текущей комнаты: на следующем ходу восстановим по ним предыдущую
  if type(r.EXITS) == "table" then
    MudMapper.prev_exits = {}
    for d, t in pairs(r.EXITS) do MudMapper.prev_exits[d] = t end
  else
    MudMapper.prev_exits = nil
  end
end

-- тёмная комната: MSDP всё равно отдаёт VNUM и выходы
function MudMapper.on_vision_fail()
  MudMapper.dbg("[event] onVisionFail")
  MudMapper.update_room()
end

-- speedwalk в комнату по VNUM (бонус)
function MudMapper.goto_vnum(vnum)
  local id = getRoomIDbyHash(tostring(vnum))
  if id and id > 0 then
    gotoRoom(id)
  else
    echo("Комната " .. tostring(vnum) .. " ещё не в карте\n")
  end
end

-- ===== Инициализация =====
function MudMapper.init()
  if not map then
    tempTimer(1, MudMapper.init)
    return
  end
  map.setConfigs("custom_name_search", false)
  map.setConfigs("mode", "normal")
  map.setConfigs("stretch_map", false)

  -- ЧИНИМ lang_dirs: восстанавливаем английские значения по умолчанию.
  local en = {
    n="n", ne="ne", nw="nw", e="e", w="w", s="s", se="se", sw="sw",
    u="u", d="d", ["in"]="in", out="out",
    north="north", northeast="northeast", east="east", west="west",
    south="south", southeast="southeast", southwest="southwest",
    northwest="northwest", up="up", down="down", l="l", look="look",
    ed="ed", eu="eu", eastdown="eastdown", eastup="eastup",
    nd="nd", nu="nu", northdown="northdown", northup="northup",
    sd="sd", su="su", southdown="southdown", southup="southup",
    wd="wd", wu="wu", westdown="westdown", westup="westup",
  }
  map.configs.lang_dirs = en

  -- пересобираем translate: английский (identity) + русский
  map.configs.translate = {}
  for k, v in pairs(en) do
    map.configs.translate[v] = k
  end

  -- добавляем русские направления
  local ru = {
    ["север"]="north", ["с"]="n",
    ["юг"]="south",    ["ю"]="s",
    ["восток"]="east", ["в"]="e",
    ["запад"]="west",  ["з"]="w",
    ["вверх"]="up",    ["вв"]="u",
    ["вниз"]="down",   ["вн"]="d",
  }
  for k, v in pairs(ru) do
    map.configs.translate[k] = v
  end

  MudMapper.echo("интеграция со Сферой Миров успешно настроена!")
  MudMapper.dbg("[init] stretch_map=false, mode=normal")
end

registerAnonymousEventHandler("sysProtocolEnabled", "MudMapper.on_protocol")
registerAnonymousEventHandler("msdp.ROOM", "MudMapper.on_msdp_room")
registerAnonymousEventHandler("sysDataSendRequest", "MudMapper.on_send")

tempTimer(1, MudMapper.init)
