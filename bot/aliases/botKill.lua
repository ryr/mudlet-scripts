-- Создайте алиас:
-- name: botkill
-- regex: ^botkill$
-- body:
-- =====================================================================
-- botkill — удар по первой цели по НОМЕРУ: sendWithClear(getAttack()).
-- Номер считает профиль: getTargets() = group_count + pet_count + i
-- (в комнате я №1, дальше согрупники, петы, затем мобы до нас).
-- Bot._attackSent — подсказка боту (BotCore/BotCombat): ушла ли команда;
-- если строку убрать, бот будет считать, что команда отправлена.
-- =====================================================================

if type(getAttack) ~= "function" then
  cecho("<red>[Bot] нет getAttack() — атаковать нечем\n")
  return
end

local cmd = getAttack()
Bot = Bot or {}
Bot._attackSent = (cmd ~= nil and cmd ~= "")

if cmd == nil or cmd == "" then
  -- антибот или пустая ротация: sendWithClear("") отправил бы "очистить"
  cecho("<gray>[Bot] getAttack() пуст (антибот/нет ротации) — не отправляю\n")
  return
end

if type(sendWithClear) == "function" then
  sendWithClear(cmd)
else
  send(cmd)
end
