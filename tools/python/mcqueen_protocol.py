#!/usr/bin/env python3
"""Protocolo compartilhado entre firmware, Flutter e ferramentas Python.

Mantenha os UUIDs e comandos sincronizados com:
  - firmware/mcqueen_firmware/mcqueen_firmware.ino
  - lib/core/ble_constants.dart
"""

from __future__ import annotations

import json
import re

DEVICE_NAME = "McQueen"
SERVICE_UUID = "12345678-1234-5678-1234-56789abcdef0"
CHAR_RX_UUID = "12345678-1234-5678-1234-56789abcdef1"  # PC/App -> ESP32
CHAR_TX_UUID = "12345678-1234-5678-1234-56789abcdef2"  # ESP32 -> PC/App

MOVEMENTS = {"FRENTE", "TRAS", "ESQUERDA", "DIREITA", "ESQ", "DIR"}
MOTOR_SIDES = {"ESQ", "DIR"}
SPEED_PRESETS = {"VEL:1", "VEL:2", "VEL:3", "VEL:4"}
EXPRESSIONS = {
    "NORMAL", "FELIZ", "SURPRESO", "SONOLENTO", "CURIOSO", "TRISTE",
    "BRAVO", "APAIXONADO", "DESCONFIADO", "ANIMADO", "ASSUSTADO", "PISCANDO",
}
SIMPLE_COMMANDS = {
    "PARAR", "STOP", "PING", "STATUS", "STATUS:JSON", "DIAG",
    "BUZINA", "BUZINA:CURTA", "BUZINA:LONGA", "BUZINA:EMERGENCIA", "BUZINA:DESLIGAR",
    "BIPE", "ALERTA", "MUTE", "PARAR_BUZZER",
    "SOM:MUTE:0", "SOM:MUTE:1", "BUZZER:ATIVO", "BUZZER:PASSIVO",
    "CAL:INVERTEL", "CAL:INVERTED", "CAL:RESET",
    "SETA:ESQUERDA", "SETA:DIREITA", "SETA:ALERTA", "SETA:AUTO", "SETA:DESLIGAR",
    "LED:ESQ:ON", "LED:ESQ:OFF", "LED:DIR:ON", "LED:DIR:OFF",
    "LED:AMBOS:ON", "LED:OFF", "LED:STATUS",
}

KEEPALIVE_INTERVAL = 0.25  # segundos (firmware tolera 800 ms sem comandos)
MAX_SPEED = 100
MAX_SERVO_US = 2000
MIN_SERVO_US = 1000

_INT_RE = re.compile(r"^-?\d{1,5}$")


def clamp_percent(value: int) -> int:
    return max(0, min(MAX_SPEED, int(value)))


def is_strict_int(text: str) -> bool:
    return bool(_INT_RE.match(text))


def movement_command(direction: str, speed: int | None = None) -> str:
    """Monta FRENTE/TRAS/ESQUERDA/DIREITA com velocidade opcional 0..100."""
    direction = direction.strip().upper()
    if direction not in MOVEMENTS:
        raise ValueError(f"direção inválida: {direction!r}")
    if speed is None:
        return direction
    return f"{direction}:{clamp_percent(speed)}"


def diff_command(left: int, right: int) -> str:
    """Monta DIFF:left:right com velocidades entre -100 e 100."""
    left = int(left)
    right = int(right)
    if not (-MAX_SPEED <= left <= MAX_SPEED and -MAX_SPEED <= right <= MAX_SPEED):
        raise ValueError("velocidades diferenciais devem estar entre -100 e 100")
    return f"DIFF:{left}:{right}"


def expression_command(expr: str) -> str:
    """Monta EXPR:NOME para controle das expressões OLED."""
    expr = expr.strip().upper()
    if expr not in EXPRESSIONS:
        raise ValueError(f"expressão inválida: {expr!r}")
    return f"EXPR:{expr}"


def speed_command(percent: int) -> str:
    return f"VELOCIDADE:{clamp_percent(percent)}"


def motor_command(side: str, value: int) -> str:
    """Controle individual. value: -100..100; o outro servo para."""
    side = side.strip().upper()
    if side not in MOTOR_SIDES:
        raise ValueError(f"lado inválido: {side!r}")
    value = int(value)
    if not -MAX_SPEED <= value <= MAX_SPEED:
        raise ValueError("valor do motor deve estar entre -100 e 100")
    return f"MOTOR:{side}:{value}"


def calibration_stop_command(side: str, microseconds: int) -> str:
    side = side.strip().upper()
    if side not in MOTOR_SIDES:
        raise ValueError(f"lado inválido: {side!r}")
    microseconds = int(microseconds)
    if not MIN_SERVO_US <= microseconds <= MAX_SERVO_US:
        raise ValueError(f"neutro deve estar entre {MIN_SERVO_US} e {MAX_SERVO_US} µs")
    prefix = "CAL:ESTOPL" if side == "ESQ" else "CAL:ESTOPR"
    return f"{prefix}:{microseconds}"


def calibration_vmin_command(percent: int) -> str:
    percent = int(percent)
    if not 0 <= percent <= 95:
        raise ValueError("velocidade mínima deve estar entre 0 e 95%")
    return f"CAL:VMIN:{percent}"


def calibration_vmax_command(percent: int) -> str:
    percent = int(percent)
    if not 5 <= percent <= MAX_SPEED:
        raise ValueError(f"velocidade máxima deve estar entre 5 e {MAX_SPEED}%")
    return f"CAL:VMAX:{percent}"


def matches_device(
    device_name: str | None,
    adv_name: str | None,
    service_uuids: list[str] | tuple[str, ...] | None,
    *,
    target_name: str = DEVICE_NAME,
    target_service: str = SERVICE_UUID,
) -> bool:
    """Retorna True se o anúncio casar pelo nome OU pelo service UUID."""
    wanted_name = target_name.strip().casefold()
    for name in (device_name, adv_name):
        if name and name.strip().casefold() == wanted_name:
            return True

    wanted_service = target_service.strip().casefold()
    for uuid in service_uuids or ():
        if str(uuid).strip().casefold() == wanted_service:
            return True
    return False


def is_movement_command(cmd: str) -> bool:
    s = cmd.strip()
    if s.startswith("{"):
        try:
            obj = json.loads(s)
            c = str(obj.get("cmd") or obj.get("c") or "").upper()
            return c in ("MOVE", "DIFF")
        except Exception:
            return False
    base = s.upper().split(":", 1)[0]
    return base in MOVEMENTS or base == "DIFF"


def is_motor_command(cmd: str) -> bool:
    return cmd.strip().upper().startswith("MOTOR:")


def validate_command(cmd: str) -> tuple[bool, str]:
    """Valida um comando antes de enviá-lo. Retorna (ok, motivo)."""
    text = cmd.strip()
    if not text:
        return False, "comando vazio"

    if text.startswith("{"):
        if len(text) > 180:
            return False, "JSON muito longo (máx. 180 bytes)"
        try:
            obj = json.loads(text)
        except Exception as exc:
            return False, f"JSON inválido: {exc}"
        if not isinstance(obj, dict):
            return False, "JSON deve ser um objeto"
        c = str(obj.get("cmd") or obj.get("c") or "").strip().upper()
        if not c:
            return False, "JSON sem campo 'cmd'"
        return True, ""

    if len(text) > 40:
        return False, "comando muito longo (máx. 40 bytes)"

    upper = text.upper()
    if upper in SIMPLE_COMMANDS or upper in SPEED_PRESETS:
        return True, ""

    if upper.startswith("VELOCIDADE:"):
        value = upper.split(":", 1)[1]
        if is_strict_int(value) and 0 <= int(value) <= MAX_SPEED:
            return True, ""
        return False, "velocidade deve ser um inteiro entre 0 e 100"

    if upper.startswith("DIFF:"):
        parts = upper.split(":")
        if len(parts) != 3:
            return False, "formato esperado: DIFF:esq:dir"
        _, left_s, right_s = parts
        if (
            is_strict_int(left_s)
            and is_strict_int(right_s)
            and -MAX_SPEED <= int(left_s) <= MAX_SPEED
            and -MAX_SPEED <= int(right_s) <= MAX_SPEED
        ):
            return True, ""
        return False, "valores de DIFF devem estar entre -100 e 100"

    if upper.startswith("EXPR:") or upper.startswith("EXPRESSAO:"):
        expr = upper.split(":", 1)[1]
        if expr in EXPRESSIONS:
            return True, ""
        return False, f"expressão deve ser uma de {sorted(EXPRESSIONS)}"

    if upper.startswith("TONE:"):
        parts = upper.split(":")
        if len(parts) == 2 and is_strict_int(parts[1]) and 100 <= int(parts[1]) <= 10000:
            return True, ""
        if (
            len(parts) == 3
            and is_strict_int(parts[1])
            and is_strict_int(parts[2])
            and 100 <= int(parts[1]) <= 10000
            and 20 <= int(parts[2]) <= 3000
        ):
            return True, ""
        return False, "formato esperado: TONE:freq[:ms]"

    if upper.startswith("MOTOR:"):
        parts = upper.split(":")
        if len(parts) != 3:
            return False, "formato esperado: MOTOR:ESQ:n ou MOTOR:DIR:n"
        _, side, value = parts
        if side not in MOTOR_SIDES:
            return False, "lado deve ser ESQ ou DIR"
        if not is_strict_int(value) or not -MAX_SPEED <= int(value) <= MAX_SPEED:
            return False, "valor do motor deve ser um inteiro entre -100 e 100"
        return True, ""

    if upper.startswith("CAL:ESTOPL:") or upper.startswith("CAL:ESTOPR:"):
        value = upper.rsplit(":", 1)[-1]
        if is_strict_int(value) and MIN_SERVO_US <= int(value) <= MAX_SERVO_US:
            return True, ""
        return False, f"neutro deve estar entre {MIN_SERVO_US} e {MAX_SERVO_US} µs"

    if upper.startswith("CAL:VMIN:"):
        value = upper.rsplit(":", 1)[-1]
        if is_strict_int(value) and 0 <= int(value) <= 95:
            return True, ""
        return False, "velocidade mínima deve estar entre 0 e 95"

    if upper.startswith("CAL:VMAX:"):
        value = upper.rsplit(":", 1)[-1]
        if is_strict_int(value) and 5 <= int(value) <= MAX_SPEED:
            return True, ""
        return False, f"velocidade máxima deve estar entre 5 e {MAX_SPEED}"

    if upper.startswith("SETA:"):
        valid_setas = {"ESQUERDA", "DIREITA", "ALERTA", "AUTO", "DESLIGAR"}
        seta_cmd = upper.split(":", 1)[1]
        if seta_cmd in valid_setas:
            return True, ""
        return False, f"comando de seta deve ser um de {sorted(valid_setas)}"

    if upper in MOVEMENTS:
        return True, ""

    base, sep, value = upper.partition(":")
    if base in MOVEMENTS:
        if sep and is_strict_int(value) and 0 <= int(value) <= MAX_SPEED:
            return True, ""
        return False, "velocidade inline deve ser um inteiro entre 0 e 100"

    return False, "comando desconhecido"


def parse_status(text: str) -> dict[str, int]:
    """Converte 'V:70|M:0|L:1500|R:1500|I:01...' em um dicionário de inteiros."""
    status: dict[str, int] = {}
    for item in text.strip().split("|"):
        key, sep, value = item.partition(":")
        if not sep:
            continue
        try:
            status[key.strip().upper()] = int(value)
        except ValueError:
            continue
    return status
