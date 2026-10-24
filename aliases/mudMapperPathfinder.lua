-- ^муть (?<location>.+)$

-- lua addSpecialExit(1979, 147, "куп 1") -- задает спец команду для перемещения
-- lua display(getSpecialExits(1979)) -- проверяем существование спец выходов
-- lua removeSpecialExit(1979, "куп 1") -- удалить конкретную спец команду
-- lua clearSpecialExits(1979) -- удалить все команды для комнаты


local path_map = {
  ["гасклад"] = { vnum = 450465, name = "Склад Галена" },
  ["элсклад"] = { vnum = 100076, name = "Склад Элендора" },
  ["маска"] = { vnum = 156001, name = "Лекарь в маске"},
}

if matches.location and path_map[matches.location] then
  send("гг Бежим в локацию \"" .. path_map[matches.location].name  .. "\"")
  MudMapper.goto_vnum(path_map[matches.location].vnum)
else
  cecho("Локация не найдена")
end
