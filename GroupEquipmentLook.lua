-- =====================================================================
-- GroupEquipmentLook for Mudlet 5+
-- Создайте триггер с паттерном (regex):
-- ^(.*)$
-- Содержимое:
-- local line = matches[1]
-- if line and line ~= "" and GroupEquipmentLook then
--   GroupEquipmentLook.onIncoming(line)
-- end
-- =====================================================================

GroupEquipmentLook = GroupEquipmentLook or {}
local G = GroupEquipmentLook

G.moduleName             = "look"
G.nextIsLine             = false
G.enableSayInGroup       = true
G.playersInGroup         = {}
G.playersInGroupFar      = {}
G.playerEquipmentCounter = 0
G.playerName             = ""
G.slotNumber             = 0
G.stuff                  = {}
G.lastPrintedEmpty       = false
G.debugGroup             = false

G.snapshot               = {}
G.checkMode              = false
G.checkQueue             = {}
G.checkCurrent           = nil
G.checkPendingGroup      = false

G.slotLabels = {
  [1]  = " <в дополнительном слоте>        ",
  [2]  = " <надето на голову>              ",
  [3]  = " <надето на шее>                 ",
  [4]  = " <надето на шее>                 ",
  [5]  = " <надето на теле>                ",
  [6]  = " <наброшено на плечи>            ",
  [7]  = " <надето на талии>               ",
  [8]  = " <надето на кисти рук>           ",
  [9]  = " <надето на руки>                ",
  [10] = " <надето на ноги>                ",
  [11] = " <используется как обувь>        ",
  [12] = " <надето на левое запястье>      ",
  [13] = " <надето на правое запястье>     ",
  [14] = " <надето на палец левой руки>    ",
  [15] = " <надето на палец правой руки>   ",
  [16] = " <используется как щит>          ",
  [17] = " <в правой руке>                 ",
  [18] = " <в левой руке>                  ",
  [19] = " <в обеих руках>                 ",
}

G.slotMissMessages = {
  [1]  = "доп",
  [2]  = "голова",
  [3]  = "шея",
  [4]  = "шея",
  [5]  = "тело",
  [6]  = "плечи",
  [7]  = "пояс",
  [8]  = "кисти",
  [9]  = "руки",
  [10] = "ноги",
  [11] = "обувь",
  [12] = "запястье",
  [13] = "запястье",
  [14] = "палец",
  [15] = "палец",
  [16] = "щит",
  [17] = "правая рука",
  [18] = "левая рука",
  [19] = "обе руки",
}


local function stripAnsi(s)
  if not s then return "" end
  s = s:gsub("\27%[[%d;]*m", "")
  s = s:gsub("\27%[[%d;]*[A-Za-z]", "")
  return s
end


local function extractItemName(sLine)
  local name = sLine:match("^ <[^>]+>%s+(.-)%s+%-%-%s*%[%s*%d+%s*%]%s*$")
  if name then return name end
  name = sLine:match("^ <[^>]+>%s+(.+)%s*$")
  return name
end


local function printEmptySlot(slot)
  local label = G.slotLabels[slot]
  if not label then return end

  if not G.lastPrintedEmpty then
    cecho("\n")
  end

  local suffix = ""
  local prev = G.snapshot[G.playerName]
  if prev and prev[slot] then
    suffix = ", <yellow>был " .. prev[slot] .. "<reset>"
  end

  cecho(label .. "[<firebrick>пусто" .. suffix .. "<reset>]\n")
  G.lastPrintedEmpty = true
end


-- Формирует текст для одного слота с учётом снимка
local function buildMissingMessage(name, slot)
  local msg = G.slotMissMessages[slot] or ("слот " .. slot)
  local prev = G.snapshot[name]
  if prev and prev[slot] then
    return msg .. " (" .. prev[slot] .. ")"
  end
  return msg
end


local function announceMissing(name, stuff)
  local has19 = stuff[19] -- двуруч
  local has16 = stuff[16] -- щит
  local has17 = stuff[17] -- правая
  local has18 = stuff[18] -- левая

  -- Считаем занятые слоты
  local total = 0
  for _ in pairs(stuff) do total = total + 1 end

  -- Игрок полностью голый — всегда сообщаем
  if total == 0 then
    send("ггово " .. name .. ": голый")
    return
  end

  -- Слоты 1-15
  for slot = 1, 15 do
    if not stuff[slot] then
      send("ггово " .. name .. ": " .. buildMissingMessage(name, slot))
    end
  end

  -- Руки/щит
  if not has19 then
    if not has16 then
      send("ггово " .. name .. ": " .. buildMissingMessage(name, 16))
    end
    if not has17 then
      send("ггово " .. name .. ": " .. buildMissingMessage(name, 17))
    end
    if not has18 then
      send("ггово " .. name .. ": " .. buildMissingMessage(name, 18))
    end
  end
end


-- =====================================================================
-- ИСХОДЯЩИЕ КОМАНДЫ
-- =====================================================================
function G.onInput(sTextLine)
  if not sTextLine or sTextLine == "" then return sTextLine end

  local cmd = sTextLine:match("^(%S+)")

  if cmd == "экиптест" then
    cecho("<yellow>[пгруп рядом]<reset>\n")
    return nil
  end

  if cmd == "чекстаф" then
    G.checkMode = true
    G.checkQueue = {}
    G.checkCurrent = nil
    G.checkPendingGroup = true
    G.playersInGroup = {}
    G.playersInGroupFar = {}

    send("гг Запускаю проверку стафа")
    send("пгруп рядом")
    return nil
  end

  return sTextLine
end


-- =====================================================================
-- ВХОДЯЩИЕ СТРОКИ
-- =====================================================================
function G.onIncoming(rawLine)
  local sLine = stripAnsi(rawLine or "")

  if G.debugGroup then
    if sLine:match("Рядом") or sLine:match("^%-%-%-%-") or G.nextIsLine then
      echo("[GRP] [" .. sLine .. "] nextIsLine=" .. tostring(G.nextIsLine)
      .. " inGroup=" .. #G.playersInGroup
      .. " checkMode=" .. tostring(G.checkMode)
      .. " queue=" .. #G.checkQueue .. "\n")
    end
  end

  -- 1. (Тип аккаунта: ...)
  if sLine:match("^%(Тип аккаунта: (мульт|уникальный|не определено)%)$") then
    return
  end

  -- 2. Строка состояния
  if sLine:match("^%d+H %d+M %d+V") then
    if G.nextIsLine then
      G.nextIsLine = false

      if G.checkPendingGroup then
        G.checkPendingGroup = false
        G.checkQueue = {}
        for _, nm in ipairs(G.playersInGroup) do
          table.insert(G.checkQueue, nm)
        end
        if #G.checkQueue > 0 then
          G.checkCurrent = table.remove(G.checkQueue, 1)
          send("look " .. G.checkCurrent)
        else
          send("гг Проверка стафа закончена")
          G.checkMode = false
        end
      end

      G.playersInGroup    = {}
      G.playersInGroupFar = {}
    end

    if G.playerName ~= "" then
      if G.checkMode then
        announceMissing(G.playerName, G.stuff)
      end

      -- Обновляем снимок: сохраняем СТАРЫЕ данные для пустых слотов
      local prevSnap = G.snapshot[G.playerName] or {}
      local newSnap = {}

      -- Копируем старый снимок
      for k, v in pairs(prevSnap) do newSnap[k] = v end

      -- Перезаписываем тем, что надето сейчас
      for k, v in pairs(G.stuff) do newSnap[k] = v end

      G.snapshot[G.playerName] = newSnap

      if G.checkMode and G.checkCurrent then
        if #G.checkQueue > 0 then
          G.checkCurrent = table.remove(G.checkQueue, 1)
          send("look " .. G.checkCurrent)
        else
          send("гг Проверка стафа закончена")
          G.checkMode = false
          G.checkCurrent = nil
        end
      end
    end

    G.stuff = {}
    G.playerName = ""
    G.playerEquipmentCounter = 0
    G.lastPrintedEmpty = false
    return
  end

  -- 3. Шапки блока экипировки
  local name1 = sLine:match("^([^%s]+) использует:$")
  if name1 then
    G.playerEquipmentCounter = 1
    G.playerName = name1
    G.stuff = {}
    G.lastPrintedEmpty = false
    return
  end

  local name2 = sLine:match("^([^%s]+) в превосходном состоянии%.$")
  if name2 then
    G.playerEquipmentCounter = 1
    G.playerName = name2
    G.stuff = {}
    G.lastPrintedEmpty = false
    return
  end

  -- 4. Определяем слот
  G.slotNumber = 0
  local slotTag = sLine:match("^ <([^>]+)>")
  if slotTag and G.playerEquipmentCounter > 0 then
    local slotMap = {
      ["надето на голову"]            = 2,
      ["надето на шее"]               = 3,
      ["надето на теле"]              = 5,
      ["наброшено на плечи"]          = 6,
      ["надето на талии"]             = 7,
      ["надето на кисти рук"]         = 8,
      ["надето на руки"]              = 9,
      ["надето на ноги"]              = 10,
      ["используется как обувь"]      = 11,
      ["надето на левое запястье"]    = 12,
      ["надето на правое запястье"]   = 13,
      ["надето на палец левой руки"]  = 14,
      ["надето на палец правой руки"] = 15,
      ["используется как щит"]        = 16,
      ["в правой руке"]               = 17,
      ["в левой руке"]                = 18,
      ["в обеих руках"]               = 19,
    }
    G.slotNumber = slotMap[slotTag] or 0

    if slotTag == "надето на шее" and G.stuff[3] then
      G.slotNumber = 4
    end

    if G.playerEquipmentCounter == 1 and G.slotNumber == 0 then
      G.slotNumber = 1
    end
  end

  -- 5. Совпадение — сохраняем имя предмета
  if G.slotNumber == G.playerEquipmentCounter and G.playerEquipmentCounter > 0 then
    local itemName = extractItemName(sLine) or true
    G.stuff[G.playerEquipmentCounter] = itemName
    G.playerEquipmentCounter = G.playerEquipmentCounter + 1
    G.lastPrintedEmpty = false
    return
  end

  -- 6. Пропущенные слоты
  if G.playerEquipmentCounter > 0 and G.playerEquipmentCounter < 19 then
    if sLine:match("^ <[^>]+>") then
      printEmptySlot(G.playerEquipmentCounter)
      G.playerEquipmentCounter = G.playerEquipmentCounter + 1
      G.onIncoming(rawLine)
      return
    end
  end

  -- 7. Таблица группы
  if sLine:match("^%s+Имя%s+Рядом%s*$") then
    G.nextIsLine = true
    G.enableSayInGroup = true
    return
  end

  if G.nextIsLine and sLine:match("^%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-$") then
    return
  end

  if G.nextIsLine then
    local mark, name, dist = sLine:match("^%s*(%*?)([^%s]+)%s+([^%s]+)%s*$")
    if name and dist and (dist == "Д" or dist == "Н") then
      G.nextIsLine = true
      if dist == "Д" and mark ~= "*" then
        table.insert(G.playersInGroup, name)
      else
        table.insert(G.playersInGroupFar, name)
      end
      return
    end
  end

  if G.nextIsLine and sLine:match("^%[<Enter> %- показать следующую страницу, <к> %- закончить показ%]$") then
    G.nextIsLine = true
    return
  end

  if G.nextIsLine and sLine == "" and not G.checkPendingGroup then
    G.nextIsLine = false
    G.playersInGroup    = {}
    G.playersInGroupFar = {}
    return
  end
end


-- =====================================================================
-- ПОДКЛЮЧЕНИЕ
-- =====================================================================

if GroupEquipmentLook_sendHandlerID then
  killAnonymousEventHandler(GroupEquipmentLook_sendHandlerID)
  GroupEquipmentLook_sendHandlerID = nil
end

GroupEquipmentLook_sendHandlerID = registerAnonymousEventHandler("sysDataSendRequest", function(_, cmd)
  local out = GroupEquipmentLook.onInput(cmd)
  if out == nil then
    denyCurrentSend()
  end
end)

cecho("<green>[GroupEquipmentLook]<reset> скрипт загружен.\n")
