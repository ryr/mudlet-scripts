# Makefile — mudlet-scripts
# Обёртки для установки бота и запуска инструментов вместо прямых вызовов
# python3 bot/tools/*.

# Установка бота (скрипты + алиасы + зоны bot/zones/):
#   make install                   # в активный профиль Mudlet (без --profile)
#   make install PROFILE=sowmud.ru # в конкретный профиль
#   make dry-run                   # план без изменений
#   make uninstall                 # отключить бота
#   make print-lua                 # показать Lua-код установки
#
# Проверка и диагностика:
#   make test                      # стенд botHarness.lua без Mudlet
#   make lua CMD='print(getProfileName())'   # Lua в живом профиле (MCP)
#   make list                      # список скриптов
#   make zones                     # список зон в bot/zones/
#
# Остальные скрипты (antibot.lua, mapper.lua, sendClear.lua, ...) ставятся
# вручную в редакторе Mudlet — инструкция в шапке каждого файла (make list).

PROFILE ?=

INSTALL := python3 bot/tools/install_bot.py
MCP     := python3 bot/tools/mudlet_mcp.py

PROFILE_ARG = $(if $(PROFILE),--profile $(PROFILE),)

.DEFAULT_GOAL := help

.PHONY: help install install-bot dry-run uninstall print-lua test lua list zones

help:
	@echo "mudlet-scripts — цели:"
	@echo "  make install [PROFILE=<имя>]   установить бота (скрипты+алиасы+зоны)"
	@echo "  make dry-run [PROFILE=<имя>]   план установки без изменений"
	@echo "  make uninstall [PROFILE=<имя>] отключить бота"
	@echo "  make print-lua                 показать Lua-код установки"
	@echo "  make test                      стенд botHarness.lua (без Mudlet)"
	@echo "  make lua CMD='<код>'           выполнить Lua в живом профиле (MCP)"
	@echo "  make list                      список скриптов"
	@echo "  make zones                     список зон в bot/zones/"
	@echo "  make help                      эта справка"
	@echo ""
	@echo "Профиль: PROFILE=$(PROFILE) (пусто = активный; пример: PROFILE=sowmud.ru)"

install: install-bot

install-bot:
	$(INSTALL) $(PROFILE_ARG)

dry-run:
	$(INSTALL) --dry-run $(PROFILE_ARG)

uninstall:
	$(INSTALL) --uninstall $(PROFILE_ARG)

print-lua:
	$(INSTALL) --dry-run --print-lua $(PROFILE_ARG)

test:
	lua bot/tests/botHarness.lua

lua:
	$(MCP) $(PROFILE_ARG) $(CMD)

zones:
	@ls -1 bot/zones/

list:
	@echo "Бот (make install):"
	@ls -1 bot/botCore.lua bot/botWalk.lua bot/botCombat.lua bot/botPanel.lua bot/mapperEchoFix.lua bot/aliases/*.lua bot/zones/*.lua
	@echo ""
	@echo "Остальные скрипты (ставятся вручную, инструкция в шапке файла):"
	@ls -1 antibot.lua mapper.lua mapperLabel.lua sendClear.lua groupEquipmentLook.lua init.lua autoAttack.lua autoAttackCaster.lua aliases/mudMapperPathfinder.lua aliases/mudMapperDt.lua triggers/*.lua
