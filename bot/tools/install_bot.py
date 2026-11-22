#!/usr/bin/env python3
"""Установка/снятие бота в профиле Mudlet через MCP (permScript/permAlias).

Создаёт в профиле:
    Scripts: группа zoneBot — botCore, botWalk, botCombat, botPanel, mapperEchoFix
    Aliases: группа zoneBot — botCommand (.бот ...), botTrig (.триг ...), botWait (.пауза ...), botKill

Ставит записанные зоны из <repo>/bot/zones/*.lua в <профиль>/bot/zones:
    - если цели нет или файл репозитория свежее — копирует;
    - старый файл профиля бэкапит в bot/zones/backup/<имя>.<дата>.bak;
    - если файл в профиле свежее (перезаписан в игре) — не трогает.

Примеры:
    python3 tools/install_bot.py --dry-run          # показать план
    python3 tools/install_bot.py                    # установить в активный профиль
    python3 tools/install_bot.py --profile sowmud.ru
    python3 tools/install_bot.py --uninstall        # отключить элементы по именам

Установка идёт одной Lua-командой в живой Mudlet: код скриптов встраивается
в вызов permScript. Снятие — disableScript/disableAlias по именам (Mudlet не
умеет удалять элементы из Lua, отключённые можно удалить в редакторе).
"""
import argparse
import os
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mudlet_mcp import DEFAULT_DISCOVERY, call_lua  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ZONES = os.path.join(REPO, "zones")

SCRIPTS = [
    ("botCore", "botCore.lua"),
    ("botWalk", "botWalk.lua"),
    ("botCombat", "botCombat.lua"),
    ("botPanel", "botPanel.lua"),
    # патч generic_mapper: убирает getCurrentLine() из map.echo/map.echon
    ("mapperEchoFix", "mapperEchoFix.lua"),
]

ALIASES = [
    # имя, файл, regex (см. первую строку "alias" в файле)
    ("botCommand", "aliases/bot.lua", r"^\.бот\s*(?<cmd>\S*)\s*(?<arg>.*)$"),
    ("botTrig", "aliases/botTrig.lua", r"^\.триг\s+(?<cmd>.+)$"),
    ("botWait", "aliases/botWait.lua", r"^\.пауза\s+(?<sec>[0-9]+(?:[.,][0-9]+)?)$"),
    # атака по номеру цели; имя элемента = самой команде, чтобы exists("botKill")
    # видел его; если у вас уже есть свой алиас botKill — он не перезапишется
    ("botKill", "aliases/botKill.lua", r"^botkill$"),
]

LONG_BRACKETS = ["[==[", "[===[", "[====[", "[=====["]


def lua_long_string(code):
    """Оборачивает код в длинные скобки, которых нет внутри самого кода."""
    for opening in LONG_BRACKETS:
        closing = "]" + "=" * (len(opening) - 2) + "]"
        if opening not in code and closing not in code:
            return opening + code + closing
    raise SystemExit("не смог подобрать длинные скобки для встраивания кода")


def read(path):
    with open(os.path.join(REPO, path), "r", encoding="utf-8") as handle:
        return handle.read()


SCRIPT_GROUP = "zoneBot"
ALIAS_GROUP = "zoneBot"


def build_install_lua():
    """Скрипты и алиасы кладём в одноимённые группы zoneBot.

    Mudlet создаёт permScript/permGroup("script") выключенными, поэтому после
    создания каждый скрипт (и группа) включается enableScript(); для алиасов
    permAlias сразу активен, группа алиасов создаётся включённой.
    """
    lines = [
        "local SCRIPT_GROUP = %s" % lua_string(SCRIPT_GROUP),
        "local ALIAS_GROUP = %s" % lua_string(ALIAS_GROUP),
        "local function ensure_group(name, itemtype)",
        "  if exists(name, itemtype) == 0 then",
        "    local ok, err = permGroup(name, itemtype, \"\")",
        "    if not ok then",
        "      print(string.format(\"группа %s (%s): ОШИБКА %s\", name, itemtype, tostring(err)))",
        "      return false",
        "    end",
        "    print(string.format(\"группа %s (%s): создана\", name, itemtype))",
        "  else",
        "    print(string.format(\"группа %s (%s): уже есть\", name, itemtype))",
        "  end",
        "  if itemtype == \"script\" then enableScript(name) else enableAlias(name) end",
        "  return true",
        "end",
        "if not ensure_group(SCRIPT_GROUP, \"script\") then return end",
    ]
    for name, path in SCRIPTS:
        code = read(path)
        lines += [
            "do",
            "  local ok, err = pcall(function()",
            "    if exists(%s, \"script\") > 0 then" % lua_string(name),
            "      setScript(%s, %s)" % (lua_string(name), lua_long_string(code)),
            "      print(\"script %s: обновлён\")" % name,
            "    else",
            "      permScript(%s, SCRIPT_GROUP, %s)" % (lua_string(name), lua_long_string(code)),
            "      print(\"script %s: создан\")" % name,
            "    end",
            "    enableScript(%s)" % lua_string(name),
            "  end)",
            "  if not ok then print(string.format(\"script %s: ОШИБКА %%s\", tostring(err))) end" % name,
            "end",
        ]
    lines.append("if not ensure_group(ALIAS_GROUP, \"alias\") then return end")
    for name, path, regex in ALIASES:
        code = read(path)
        lines += [
            "do",
            "  if exists(%s, \"alias\") > 0 then" % lua_string(name),
            "    print(\"alias %s: уже есть — пропущен (в этой сборке Mudlet Lua не меняет код существующих алиасов; правьте в редакторе)\")" % name,
            "  else",
            "    local ok, err = pcall(permAlias, %s, ALIAS_GROUP, %s, %s)"
            % (lua_string(name), lua_long_string(regex), lua_long_string(code)),
            "    if ok then",
            "      print(\"alias %s: создан\")" % name,
            "    else",
            "      print(string.format(\"alias %s: ОШИБКА %%s\", tostring(err)))" % name,
            "    end",
            "  end",
            "end",
        ]
    lines.append("print(\"Готово. Скрипты и алиасы — в группах zoneBot. Проверка: .бот ?\")")
    return "\n".join(lines)


def build_uninstall_lua():
    lines = [
        "local SCRIPT_GROUP = %s" % lua_string(SCRIPT_GROUP),
        "local ALIAS_GROUP = %s" % lua_string(ALIAS_GROUP),
        "do local ok, err = pcall(disableScript, SCRIPT_GROUP); "
        "print(string.format(\"group script %s: %s\", SCRIPT_GROUP, tostring(ok and \"off\" or err))) end",
        "do local ok, err = pcall(disableAlias, ALIAS_GROUP); "
        "print(string.format(\"group alias %s: %s\", ALIAS_GROUP, tostring(ok and \"off\" or err))) end",
    ]
    for name, _ in SCRIPTS:
        lines.append("do local ok, err = pcall(disableScript, %s); "
                     "print(string.format(\"script %%s: %%s\", %s, tostring(ok and \"off\" or err))) end"
                     % (lua_string(name), lua_string(name)))
    for name, _, _ in ALIASES:
        lines.append("do local ok, err = pcall(disableAlias, %s); "
                     "print(string.format(\"alias %%s: %%s\", %s, tostring(ok and \"off\" or err))) end"
                     % (lua_string(name), lua_string(name)))
    lines.append("print(\"Бот отключён (элементы остались в профиле, включить: enableScript/enableAlias). \" .."
                 "\"Группы «Бот» не трогались: ботовские элементы в них отключены по именам.\")")
    return "\n".join(lines)


def lua_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def zone_home(profile, discovery):
    """Каталог профиля по версии самого Mudlet (getMudletHomeDir) — тот же, что у бота."""
    text, payload = call_lua("return getMudletHomeDir()", profile, discovery)
    if "error" in payload:
        raise SystemExit("не смог определить каталог профиля: %s" % text)
    path = text.strip()
    if not path:
        raise SystemExit("Mudlet вернул пустой getMudletHomeDir()")
    return path


def fallback_home(profile):
    """Запасной путь для --dry-run без запущенного Mudlet: ~/.config/mudlet/profiles/<профиль>."""
    if not profile:
        return None
    candidate = os.path.join(os.path.expanduser("~/.config/mudlet/profiles"), profile)
    return candidate if os.path.isdir(candidate) else None


def resolve_zone_home(profile, discovery, strict):
    try:
        return zone_home(profile, discovery)
    except SystemExit:
        if strict:
            raise
    return fallback_home(profile)


def local_zones():
    """Имена *.lua из репозитория bot/zones (без подпапок и бэкапов)."""
    if not os.path.isdir(ZONES):
        return []
    return sorted(
        name for name in os.listdir(ZONES)
        if name.endswith(".lua") and os.path.isfile(os.path.join(ZONES, name))
    )


def zone_plan(target_dir):
    """План синхронизации: (действие, имя, mtime источника, mtime цели)."""
    plan = []
    for name in local_zones():
        src_mtime = os.path.getmtime(os.path.join(ZONES, name))
        dst = os.path.join(target_dir, name)
        if not os.path.exists(dst):
            plan.append(("copy", name, src_mtime, None))
        else:
            dst_mtime = os.path.getmtime(dst)
            action = "update" if src_mtime > dst_mtime else "skip"
            plan.append((action, name, src_mtime, dst_mtime))
    return plan


def format_time(timestamp):
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(timestamp))


def backup_name(name, timestamp):
    stamp = time.strftime("%Y-%m-%d-%H-%M-%S", time.localtime(timestamp))
    return "%s.%s.bak" % (name, stamp)


def print_zone_plan(target_dir):
    print("  зоны    -> %s" % target_dir)
    plan = zone_plan(target_dir)
    if not plan:
        print("    в bot/zones/ нет .lua-файлов — нечего ставить")
        return
    for action, name, src_mtime, dst_mtime in plan:
        if action == "copy":
            print("    зона  %-24s создать (%s)" % (name, format_time(src_mtime)))
        elif action == "update":
            print("    зона  %-24s обновить (%s), старый -> backup/%s"
                  % (name, format_time(src_mtime), backup_name(name, dst_mtime)))
        else:
            print("    зона  %-24s пропустить (в профиле не старее: %s)"
                  % (name, format_time(dst_mtime)))


def apply_zone_plan(target_dir, plan):
    """Копирует свежие зоны, старые файлы профиля бэкапит в backup/<имя>.<дата>.bak."""
    backup_dir = os.path.join(target_dir, "backup")
    for action, name, src_mtime, dst_mtime in plan:
        src = os.path.join(ZONES, name)
        dst = os.path.join(target_dir, name)
        if action == "copy":
            shutil.copy2(src, dst)
            print("  зона  %-24s создана (%s)" % (name, format_time(src_mtime)))
        elif action == "update":
            os.makedirs(backup_dir, exist_ok=True)
            backup = os.path.join(backup_dir, backup_name(name, dst_mtime))
            shutil.copy2(dst, backup)
            shutil.copy2(src, dst)
            print("  зона  %-24s обновлена, старый -> backup/%s"
                  % (name, os.path.basename(backup)))
        else:
            print("  зона  %-24s пропущена (в профиле не старее: %s)"
                  % (name, format_time(dst_mtime)))


def sync_zones(profile, discovery, dry_run):
    """Ставит свежие зоны из repo bot/zones в <профиль>/bot/zones; старые бэкапит."""
    home = resolve_zone_home(profile, discovery, strict=not dry_run)
    if not home:
        if dry_run:
            print("  зоны    : каталог профиля не определён (Mudlet не запущен?)")
            return
        raise SystemExit("не смог определить каталог профиля для зон")
    target = os.path.join(home, "bot", "zones")
    if dry_run:
        print_zone_plan(target)
        return
    os.makedirs(target, exist_ok=True)
    print("Зоны -> %s" % target)
    apply_zone_plan(target, zone_plan(target))


def main(argv=None):
    parser = argparse.ArgumentParser(description="Установка бота в Mudlet через MCP")
    parser.add_argument("--profile", help="имя профиля (по умолчанию активный)")
    parser.add_argument("--discovery", default=DEFAULT_DISCOVERY)
    parser.add_argument("--dry-run", action="store_true", help="только показать план")
    parser.add_argument("--print-lua", action="store_true", help="напечатать Lua-код установки")
    parser.add_argument("--uninstall", action="store_true", help="отключить элементы бота")
    args = parser.parse_args(argv)

    code = build_uninstall_lua() if args.uninstall else build_install_lua()

    if args.dry_run:
        action = "снять" if args.uninstall else "установить"
        print("План: %s в профиле %s" % (action, args.profile or "(активный)"))
        if SCRIPT_GROUP == ALIAS_GROUP:
            print("  группа  %-10s (scripts + aliases)" % SCRIPT_GROUP)
        else:
            print("  группа  %-10s (scripts)" % SCRIPT_GROUP)
            print("  группа  %-10s (aliases)" % ALIAS_GROUP)
        for name, path in SCRIPTS:
            full = os.path.join(REPO, path)
            print("  script  %-10s <- %s (%d байт)" % (name, path, os.path.getsize(full)))
        for name, path, _ in ALIASES:
            full = os.path.join(REPO, path)
            print("  alias   %-10s <- %s (%d байт)" % (name, path, os.path.getsize(full)))
        if not args.uninstall:
            sync_zones(args.profile, args.discovery, dry_run=True)
        print("  Lua-код: %d байт (показать: --print-lua)" % len(code.encode("utf-8")))
        if args.print_lua:
            print()
            print(code)
        return 0

    if not args.uninstall:
        sync_zones(args.profile, args.discovery, dry_run=False)

    text, payload = call_lua(code, args.profile, args.discovery)
    print(text)
    return 0 if "error" not in payload else 1


if __name__ == "__main__":
    sys.exit(main())
