#!/usr/bin/env python3
"""Mudlet MCP (Mudlet Control Protocol) — минимальный CLI для запуска Lua.

Порт и токен Mudlet пишет в discovery-файл при включённом AI-доступе:
    ~/.config/mudlet/mcp-server.json      (macOS/Linux)
    %APPDATA%/mudlet/mcp-server.json      (Windows)
формат: {"port": 11235, "token": "..."}

Протокол: HTTP POST /mcp, JSON-RPC 2.0, MCP "2026-07-28" (без initialize),
обязательные заголовки MCP-Protocol-Version / Mcp-Method / Mcp-Name.

Примеры:
    python3 tools/mudlet_mcp.py 'print(getProfileName())'
    python3 tools/mudlet_mcp.py --file /tmp/q.lua
    python3 tools/mudlet_mcp.py --profile sowmud.ru 'print(msdp.ROOM.VNUM)'
    python3 tools/mudlet_mcp.py --json 'return 1+1'

Внимание: код выполняется в живом профиле. Для осмотра используйте только
чтение (print/display), игровые команды (send) и permScript меняют состояние.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

PROTOCOL = "2026-07-28"
DEFAULT_DISCOVERY = "~/.config/mudlet/mcp-server.json"


def read_discovery(path):
    with open(os.path.expanduser(path), "r", encoding="utf-8") as handle:
        data = json.load(handle)
    if "port" not in data or "token" not in data:
        raise SystemExit("discovery-файл без port/token: %s" % path)
    return int(data["port"]), str(data["token"])


def call_lua(code, profile=None, discovery=DEFAULT_DISCOVERY, timeout=60):
    """Выполняет Lua в Mudlet и возвращает (текст, полный_ответ)."""
    port, token = read_discovery(discovery)
    arguments = {"code": code}
    if profile:
        arguments["profile"] = profile
    body = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "_meta": {
                "io.modelcontextprotocol/protocolVersion": PROTOCOL,
                "io.modelcontextprotocol/clientCapabilities": {},
            },
            "name": "lua",
            "arguments": arguments,
        },
    }
    request = urllib.request.Request(
        "http://127.0.0.1:%d/mcp" % port,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
            "MCP-Protocol-Version": PROTOCOL,
            "Mcp-Method": "tools/call",
            "Mcp-Name": "lua",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.URLError as error:
        raise SystemExit("не смог подключиться к Mudlet MCP: %s" % error)
    return payload_text(payload), payload


def payload_text(payload):
    if "error" in payload:
        return "ERROR: " + json.dumps(payload["error"], ensure_ascii=False)
    result = payload.get("result") or {}
    parts = []
    for item in result.get("content") or []:
        if item.get("type") == "text":
            parts.append(item.get("text", ""))
    if not parts and result.get("structuredContent") is not None:
        parts.append(json.dumps(result["structuredContent"], ensure_ascii=False, indent=2))
    if result.get("isError"):
        return "ERROR: " + "\n".join(parts)
    return "\n".join(parts)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Запуск Lua в Mudlet через MCP")
    parser.add_argument("code", nargs="?", help="Lua-код")
    parser.add_argument("--file", help="файл с Lua-кодом")
    parser.add_argument("--profile", help="имя профиля (по умолчанию активный)")
    parser.add_argument("--discovery", default=DEFAULT_DISCOVERY,
                        help="путь к mcp-server.json")
    parser.add_argument("--json", action="store_true", help="напечатать полный ответ")
    args = parser.parse_args(argv)

    if args.file:
        with open(args.file, "r", encoding="utf-8") as handle:
            code = handle.read()
    elif args.code:
        code = args.code
    else:
        parser.print_help()
        return 2

    text, payload = call_lua(code, args.profile, args.discovery)
    print(text)
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0 if "error" not in payload else 1


if __name__ == "__main__":
    sys.exit(main())
