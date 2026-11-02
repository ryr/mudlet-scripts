-- Создайте триггер с паттерном (Регулярное выражение):
-- ^\d+H \d+M \d+V \d+\.\d+%X \d+C( \[(?<char>[^:]+):.+\](\-\[(?<victim>[^:]+):.+\])? \[(?<target>[^:]+):.+\])? (Ч\d+ )?Вых:[СЮВЗv^\(\)]*>
-- Содержимое:
-- status_reached = true

-- Переменные состояния (сохраняются между вызовами триггеров и алиасов)
local last_call_key = nil

-- Метка времени (epoch), до которой вставка "очистить" отключена. 0 = очистка включена.
clearDisabledUntil = clearDisabledUntil or 0

-- Внутренняя функция для проверки уникальности (убирает дублирование кода)
local function isDuplicate(...)
  local count = select('#', ...)
  local key_parts = { "count:" .. count }
  for i = 1, count do
    key_parts[#key_parts + 1] = tostring(select(i, ...))
  end
  local current_call_key = table.concat(key_parts, "|")
  
  -- Проверяем: старые ли это аргументы при status_reached == false
  if current_call_key == last_call_key and not status_reached then
    return true -- Это дубликат, нужно выйти (return)
  end

  -- Обновляем состояние, если проверка пройдена
  status_reached = false
  last_call_key = current_call_key
  return false
end

-- Временно отключает добавление "очистить" на seconds секунд (по умолчанию 10).
-- Пример: disableClear() — выключить очистку на 10 секунд, disableClear(5) — на 5.
-- Очистка включается автоматически, как только getEpoch() >= clearDisabledUntil.
function disableClear(seconds)
  clearDisabledUntil = getEpoch() + (tonumber(seconds) or 10)
end

-- 1. Функция с условным добавлением "очистить"
function sendWithClear(...)
  if isDuplicate(...) then return end
  
  local args = {...}
  -- Проверяем анти-бота и временное отключение очистки
  if antiBotLastSent == 0 and getEpoch() >= clearDisabledUntil then
    table.insert(args, 1, "очистить")
  elseif antiBotLastSent ~= 0 then
    echo(" ----------------------------- [ ПРОВЕРКА НА БОТА !!! ]")
  end

  sendAll(unpack(args, 1, #args))
end

-- 2. Функция, которая отправляет ТОЛЬКО уникальные аргументы БЕЗ "очистить"
function sendUnique(...)
  if isDuplicate(...) then return end
  
  sendAll(...)
end
