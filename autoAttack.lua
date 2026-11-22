target_table = {}
target_count = target_count or 3

function getAttack()
  if antiBotLastSent ~= 0 then
    return ""
  end

  if is_necr then
    return necrAttack()
  elseif is_ranger then
    return rangerAttack()
  end

  return ""
end

function necrAttack()
  is_spell_rotating = true
  return "колд " .. spellRotator.current()
end

function rangerAttack()
  return "отступ;" .. targetShot("метк")
end

function targetShot(attack)
  local incoming_targets = ""
  for i = 1, target_count do
    incoming_targets = incoming_targets .. " " .. i
  end

  return attack .. getTargets() .. ";" .. attack .. incoming_targets
end

function setTargets(args_str)
  local index = 1
  for word in args_str:gmatch("%S+") do
    if index > 3 then break end

    target_table[index] = word
    index = index + 1
  end

  send("гг Заданы цели:" .. getTargets())
end

function getTargets()
  local targets = ""

  -- Проверяем, пуста ли таблица (нет первого элемента)
  if target_table[1] == nil then
    for i = 1, target_count do
      local default_target = group_count + pet_count + i
      targets = targets .. " " .. default_target
    end
  else
    -- Если цели есть, собираем их как обычно
    for i, v in ipairs(target_table) do
      targets = targets .. " " .. v
    end
  end

  return targets
end
