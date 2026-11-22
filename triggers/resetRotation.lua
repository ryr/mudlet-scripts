-- regex: ^Вы последовали за .+\.

if is_spell_rotating then
  is_spell_rotating = false
  spellRotator.reset()
  sendClear()
end
