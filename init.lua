is_necr = is_necr or false
is_ranger = is_ranger or false

-- контейнер для ингридиентов
bag = bag or "ххх"

-- кол-во игроков/петов в группе
group_count = group_count or 1
pet_count = pet_count or 0

-- ингредиент для посоха
staff_ingr = staff_ingr or "ххх"
-- признак зарядки посоха
is_staff_loading = false
-- признак проверки уже заряженного посоха
staff_affect_checked = false

pet_ingr = ""
if is_necr then
  pet_ingr = staff_ingr
end

-- ротация заклинаний
default_necr_rotation = {
  { num = 1, key = "доминирование",    value = "доминирование" },
  { num = 2, key = "оковы тьмы",       value = "оковы.тьмы" },
  { num = 3, key = "облако яда",       value = "облако.яда" },
  { num = 4, key = "оковы безмолвия",  value = "оковы.безмолвия" },
  { num = 5, key = "массовый вред",    value = "масс.вред" },
}

-- текущая ротация заклов
spell_rotation_list = default_necr_rotation
spellRotator = createRotator(spell_rotation_list)
-- признак того идет сейчас ротация или нет
is_spell_rotating = is_spell_rotating or false

-- признак окончания текстового блока (вывод статусной строки)
status_reached = false

cecho("<green>[Init]<reset> скрипт загружен.\n")
