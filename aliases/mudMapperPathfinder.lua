-- ^(?<cmd>гмуть|муть)\s*(?<location>.*)$

-- муть  — одиночный забег: в портале шлёт "куп 1" (1000 монет)
-- гмуть — группой:           в портале шлёт "куп 2" (10000 монет)

-- lua addSpecialExit(1979, 147, "куп 1") -- задает спец команду для перемещения
-- lua display(getSpecialExits(1979)) -- проверяем существование спец выходов
-- lua removeSpecialExit(1979, "куп 1") -- удалить конкретную спец команду
-- lua clearSpecialExits(1979) -- удалить все команды для комнаты


-- Упорядоченный список путей с секциями: порядок в выводе = порядок здесь.
local path_sections = {
  {
    title = "Склады",
    entries = {
      { key = "арсклад",  vnum = 125077, name = "Склад Артуанель" },
      { key = "гасклад",  vnum = 450465, name = "Склад Галена" },
      { key = "геосклад", vnum = 115092, name = "Склад Геоланта" },
      { key = "элсклад",  vnum = 100076, name = "Склад Элендора" },
      { key = "эрсклад",  vnum = 141167, name = "Склад Эрдера" },
    },
  },
  {
    title = "Квесты",
    entries = {
      { key = "дно",   vnum = 25001,  name = "Чувствующий астрал" },
      { key = "маска", vnum = 156001, name = "Лекарь в маске" },
    },
  },
  {
    title = "Зоны",
    entries = {
      { key = "зал", vnum = 451007, name = "Галерея славы" },
    },
  },
  {
    title = "Порталы городов",
    entries = {
      { key = "арту",    vnum = 125028, name = "Город Артуанель" },
      { key = "видрир",  vnum = 499096, name = "Город Видрир" },
      { key = "гален",   vnum = 450842, name = "Гален" },
      { key = "гео",     vnum = 115144, name = "Город Геолант" },
      { key = "огис",    vnum = 180147, name = "Город Огис" },
      { key = "ривен",   vnum = 500001, name = "Ривенделл" },
      { key = "стэдвик", vnum = 12248,  name = "Город Стэдвик" },
      { key = "фелонад", vnum = 198065, name = "Город Фелонад" },
      { key = "шиар",    vnum = 99383,  name = "Город Шиар" },
      { key = "элен",    vnum = 100014, name = "Город Элендор" },
      { key = "эрдер",   vnum = 141039, name = "Город Эрдер" },
    },
  },
}

-- Плоский индекс для поиска по ключу (навигация работает как раньше).
local path_map = {}
for _, section in ipairs(path_sections) do
  for _, e in ipairs(section.entries) do
    path_map[e.key] = e
  end
end

-- гмуть = группой ("куп 2", 10000 монет), муть = соло ("куп 1", 1000 монет)
local portal_cmd = (matches.cmd == "гмуть") and "куп 2" or "куп 1"

local loc = matches.location
if loc then loc = string.trim(loc) end

if loc and loc ~= "" then
  local p = path_map[loc]
  if p then
    send("гг Бежим в локацию \"" .. p.name .. "\"")
    MudMapper.goto_vnum(p.vnum, portal_cmd)
  else
    cecho("<yellow>Локация не найдена:<reset> <cyan>" .. loc .. "<reset> (введите <yellow>муть<reset> для списка)\n")
  end
else
  cecho("<yellow>Доступные пути (муть — соло, гмуть — группой; пример: муть гасклад):<reset>\n")
  for _, section in ipairs(path_sections) do
    cecho("<green>" .. section.title .. ":<reset>\n")
    for _, e in ipairs(section.entries) do
      cecho("  <cyan>" .. e.key .. "<reset> — " .. e.name .. " <dim_gray>[" .. e.vnum .. "]<reset>\n")
    end
  end
end
