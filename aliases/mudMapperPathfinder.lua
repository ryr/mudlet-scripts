-- ^муть\s*(?<location>.*)$

-- lua addSpecialExit(1979, 147, "куп 1") -- задает спец команду для перемещения
-- lua display(getSpecialExits(1979)) -- проверяем существование спец выходов
-- lua removeSpecialExit(1979, "куп 1") -- удалить конкретную спец команду
-- lua clearSpecialExits(1979) -- удалить все команды для комнаты


-- Упорядоченный список путей с секциями: порядок в выводе = порядок здесь.
local path_sections = {
  {
    title = "Склады",
    entries = {
      { key = "гасклад",  vnum = 450465, name = "Склад Галена" },
      { key = "элсклад",  vnum = 100076, name = "Склад Элендора" },
      { key = "геосклад", vnum = 115092, name = "Склад Геоланта" },
      { key = "арсклад",  vnum = 125077, name = "Склад Артуанель" },
    },
  },
  {
    title = "Квесты",
    entries = {
      { key = "маска", vnum = 156001, name = "Лекарь в маске" },
      { key = "дно",   vnum = 25001,  name = "Чувствующий астрал" },
    },
  },
  {
    title = "Порталы городов",
    entries = {
      { key = "элен",    vnum = 100014, name = "Город Элендор" },
      { key = "гео",     vnum = 115144, name = "Город Геолант" },
      { key = "шиар",    vnum = 99383,  name = "Город Шиар" },
      { key = "арту",    vnum = 125028, name = "Город Артуанель" },
      { key = "стэдвик", vnum = 12248,  name = "Город Стэдвик" },
      { key = "видрир",  vnum = 499096, name = "Город Видрир" },
      { key = "ривен",   vnum = 500001, name = "Ривенделл" },
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

local loc = matches.location
if loc then loc = string.trim(loc) end

if loc and loc ~= "" then
  local p = path_map[loc]
  if p then
    send("гг Бежим в локацию \"" .. p.name .. "\"")
    MudMapper.goto_vnum(p.vnum)
  else
    cecho("<yellow>Локация не найдена:<reset> <cyan>" .. loc .. "<reset> (введите <yellow>муть<reset> для списка)\n")
  end
else
  cecho("<yellow>Доступные пути (пример: муть гасклад):<reset>\n")
  for _, section in ipairs(path_sections) do
    cecho("<green>" .. section.title .. ":<reset>\n")
    for _, e in ipairs(section.entries) do
      cecho("  <cyan>" .. e.key .. "<reset> — " .. e.name .. " <dim_gray>[" .. e.vnum .. "]<reset>\n")
    end
  end
end
