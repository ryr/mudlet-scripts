-- Создайте скрипт:
-- name: MapperLabel
-- body:
-- =====================================================================
-- MapperLabel — кликабельная плашка-переключатель маппинга generic_mapper
-- =====================================================================
-- Управляет флагом map.mapping (тем же, что включает/выключает обычный
-- "mapping mode" generic_mapper: создание новых комнат по ходу движения).
-- Плашка ставится справа от плашки BOT и меняет цвет/текст по состоянию.
--
-- Требования: пакет generic_mapper (глобальный объект map).
-- Установка: отдельный скрипт Mudlet, имя скрипта любое (например MapperLabel),
-- в тело скрипта вставляется всё, что ниже. Порядок загрузки с MudMapper
-- не важен: плашка сама ждёт появления map.

-- Создаем плашку для маппинга (generic_mapper), справа от BOT.
-- BOT-плашка занимает x = -540..-480, поэтому тут отступ ~15px.
mapperLabel = Geyser.Label:new({
  name = "mapperLabel",
  x = "-465px",
  y = "10px",
  width = "75px",
  height = "30px",
})

-- кэш последнего отрисованного состояния (чтобы не перерисовывать без нужды)
mapperLabelLastState = nil

-- Запись состояния маппинга.
-- В generic_mapper поле map.mapping защищено метатаблицей, поэтому пишем
-- через map.set("mapping", ...) — так же, как MudMapper.set_mapping().
function setMapperState(on)
  if not map then return false end
  if map.set then
    map.set("mapping", on)
  else
    map.mapping = on   -- fallback, если generic_mapper ещё не настроил метатаблицу
  end
  return true
end

-- Функция для обновления текста и цвета
function updateMapperLabel()
  if not mapperLabel then return end

  local on = map and (map.mapping == true)
  if on == mapperLabelLastState then return end   -- состояние не менялось — ничего не делаем
  mapperLabelLastState = on

  if on then
    mapperLabel:echo("<center><font color='black'><b>MAP: ON</b></font></center>")
    mapperLabel:setStyleSheet([[
      background-color: rgb(0, 160, 255);
      border: 2px solid darkblue;
      border-radius: 5px;
    ]])
  else
    mapperLabel:echo("<center><font color='white'><b>MAP: OFF</b></font></center>")
    mapperLabel:setStyleSheet([[
      background-color: rgb(120, 120, 120);
      border: 2px solid #444444;
      border-radius: 5px;
    ]])
  end
end

-- Функция переключения
function toggleMapper()
  if not map then return end
  setMapperState(not (map.mapping == true))
  updateMapperLabel()
end

-- Привязываем клик к функции
mapperLabel:setClickCallback("toggleMapper")

-- Фоновый опрос: плашка отражает ЛЮБОЕ изменение map.mapping —
-- клик по плашке, спидвок, а также ручные "start mapping"/"stop mapping"
-- generic_mapper. Пока map ещё не загружен, updateMapperLabel() просто
-- ничего не рисует и ждёт.
-- Поколение (mapperLabelPollGen) не даёт размножиться цепочкам таймеров
-- при перезапуске скрипта в Mudlet.
mapperLabelPollGen = (mapperLabelPollGen or 0) + 1
local mapperLabelPollGeneration = mapperLabelPollGen
local function mapperLabelPoll()
  if mapperLabelPollGeneration ~= mapperLabelPollGen then return end
  updateMapperLabel()
  tempTimer(0.5, mapperLabelPoll)
end
tempTimer(0.5, mapperLabelPoll)

-- отрисовать актуальное состояние сразу, если map уже доступен
updateMapperLabel()

-- Программные переключения маппинга (временное выключение на время спидвока
-- в MudMapper.start_walk/end_walk) обновляют плашку мгновенно: mapper.lua
-- вызывает updateMapperLabel(), если она определена.
