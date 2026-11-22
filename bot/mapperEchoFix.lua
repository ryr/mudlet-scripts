-- Создайте скрипт:
-- name: MapperEchoFix
-- body:
-- =====================================================================
-- MapperEchoFix — убирает getCurrentLine() из generic_mapper (Jor'Mox 2.x)
-- =====================================================================
-- В этой сборке Mudlet getCurrentLine() читает строку под курсором
-- пользователя (а не строку триггера) и возвращает литерал
-- «ERROR: invalid line number», если курсор вне буфера. Mapper зовёт её в
-- print_echoes()/map.echon() только чтобы решить, нужен ли перевод строки.
--
-- Подменяем глобальные map.echo/map.echon: последнюю строку читаем через
-- getLastLineNumber()+getLines(), не трогая курсор и не перезапуская скрипт
-- пакета (перезапуск заново регистрирует event-handler'ы и шлёт
-- mapperScriptLoaded, что даёт дубли у других скриптов).
-- Патч идемпотентный и восстанавливается на mapperScriptLoaded (после
-- обновления/перезагрузки пакета).
-- =====================================================================

MapperEchoFix = MapperEchoFix or {}
local F = MapperEchoFix

F.mapper_tag = "<112,229,0>(<73,149,0>mapper<112,229,0>): <255,255,255>"
F.debug_tag  = "<255,165,0>(<200,120,0>debug<255,165,0>): <255,255,255>"
F.err_tag    = "<255,0,0>(<178,34,34>error<255,0,0>): <255,255,255>"

-- последняя строка буфера без getCurrentLine(); getLines(from,to) — to не включается,
-- getLastLineNumber() — номер последней (обычно пустой) строки
function F.current_line()
  if type(getLastLineNumber) == "function" and type(getLines) == "function" then
    local ok, lines = pcall(function()
      local n = getLastLineNumber("main")
      return getLines("main", n, n + 1)
    end)
    if ok and type(lines) == "table" then
      return tostring(lines[1] or "")
    end
  end
  local ok, line = pcall(getCurrentLine)
  return ok and tostring(line or "") or ""
end

F.pending = F.pending or {}

function F.print_one(what, debug, err)
  moveCursorEnd("main")
  if F.current_line() ~= "" then echo("\n") end
  decho(F.mapper_tag)
  if debug then decho(F.debug_tag) end
  if err then decho(F.err_tag) end
  cecho(tostring(what or ""))
  echo("\n")
end

-- wait-очередь mapper'а (map.echo(..., true)): печатаем перед следующим
-- немедленным сообщением, как делал print_wait_echoes()
function F.flush()
  if #F.pending == 0 then return end
  local list = F.pending
  F.pending = {}
  for _, item in ipairs(list) do
    F.print_one(item[1], item[2], item[3])
  end
end

F.echo = function(what, debug, err, wait)
  -- как в оригинальном map.echo: debug-сообщения печатаются только при map debug
  if debug and not (map and map.configs and map.configs.debug) then return end
  what = tostring(what or "")
  if wait then
    F.pending[#F.pending + 1] = { what, debug, err }
    return
  end
  F.flush()
  F.print_one(what, debug, err)
end

F.echon = function(what)
  moveCursorEnd("main")
  if F.current_line() ~= "" then echo("\n") end
  decho(F.mapper_tag)
  cecho(tostring(what or ""))
end

function F.install()
  if type(map) ~= "table" or type(map.echo) ~= "function" then return false end
  if map.echo == F.echo and map.echon == F.echon then return true end
  map._echoFix = F
  map.echo = F.echo
  map.echon = F.echon
  return true
end

-- повторный запуск скрипта не должен плодить обработчики
if F.handlers then
  for _, id in ipairs(F.handlers) do pcall(killAnonymousEventHandler, id) end
end
F.handlers = {
  -- после обновления/перезагрузки пакета патч вернётся
  registerAnonymousEventHandler("mapperScriptLoaded", function() F.install() end),
  -- аналог print_wait_echoes(): отложенные сообщения печатаем на промпте
  registerAnonymousEventHandler("onPrompt", function() F.flush() end),
}
F.install()
