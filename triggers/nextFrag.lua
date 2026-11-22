-- regex: ^Вы произнесли магические слова '(?<spell>.+)'( \( сила \d+% \))?\.\.\.

if auto_assist and spellRotator.hasKey(matches.spell) then
  spellRotator.next()
  send(getAttack())
end
