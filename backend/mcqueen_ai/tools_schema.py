"""Definições de ferramentas (function calling) e validação estrita de parâmetros."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


ALLOWED_DIRECTIONS = {"forward", "backward", "left", "right"}
ALLOWED_SPEED_MODES = {"eco", "normal", "sport", "turbo"}
ALLOWED_INDICATORS = {"left", "right", "hazard", "auto", "off"}
ALLOWED_HORN_STYLES = {"normal", "short", "long", "emergency"}
ALLOWED_SOUND_EFFECTS = {"beep", "confirm", "init", "error", "laugh", "sos"}
ALLOWED_EXPRESSIONS = {
    "NORMAL",
    "FELIZ",
    "BRAVO",
    "TRISTE",
    "SURPRESO",
    "CURIOSO",
    "SONOLENTO",
    "ANIMADO",
    "CONFUSO",
    "ASSUSTADO",
    "APAIXONADO",
    "PISCANDO",
}

MIN_MOVE_DURATION_MS = 200
MAX_MOVE_DURATION_MS = 2500
DEFAULT_MOVE_DURATION_MS = 900
MIN_MOVE_SPEED_PCT = 15
MAX_MOVE_SPEED_PCT = 100


ROBOT_TOOLS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "move_robot",
            "description": (
                "Movimenta o McQueen em uma direção com pulso temporizado seguro "
                "(200 a 2500 ms). Para movimentos contínuos, aplique 2500 ms."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "direction": {
                        "type": "string",
                        "enum": sorted(ALLOWED_DIRECTIONS),
                        "description": "Direção: forward (frente), backward (ré), left (esquerda), right (direita).",
                    },
                    "speed_percent": {
                        "type": "integer",
                        "minimum": MIN_MOVE_SPEED_PCT,
                        "maximum": MAX_MOVE_SPEED_PCT,
                        "description": "Velocidade opcional (15..100%). Omita para usar a velocidade atual.",
                    },
                    "duration_ms": {
                        "type": "integer",
                        "minimum": MIN_MOVE_DURATION_MS,
                        "maximum": MAX_MOVE_DURATION_MS,
                        "description": "Duração do movimento em ms (200..2500).",
                    },
                },
                "required": ["direction"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "stop_robot",
            "description": "Para imediatamente todos os motores do McQueen (prioridade máxima PARAR).",
            "parameters": {
                "type": "object",
                "properties": {
                    "reason": {
                        "type": "string",
                        "description": "Motivo opcional da parada.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_speed_mode",
            "description": "Altera o perfil de velocidade: eco (30%), normal (60%), sport (85%) ou turbo (100%).",
            "parameters": {
                "type": "object",
                "properties": {
                    "mode": {
                        "type": "string",
                        "enum": sorted(ALLOWED_SPEED_MODES),
                    },
                },
                "required": ["mode"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_indicator",
            "description": "Controla os LEDs indicadores (setas esquerda, direita, pisca-alerta, auto ou desligar).",
            "parameters": {
                "type": "object",
                "properties": {
                    "mode": {
                        "type": "string",
                        "enum": sorted(ALLOWED_INDICATORS),
                    },
                },
                "required": ["mode"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "activate_horn",
            "description": "Aciona a buzina física no buzzer ativo GPIO 2.",
            "parameters": {
                "type": "object",
                "properties": {
                    "style": {
                        "type": "string",
                        "enum": sorted(ALLOWED_HORN_STYLES),
                        "description": "Estilo da buzina: normal, short, long ou emergency.",
                    },
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "play_sound_effect",
            "description": (
                "Reproduz um efeito sonoro compatível com o buzzer ativo (GPIO 2): "
                "beep, confirm, init, error, laugh ou sos."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "effect": {
                        "type": "string",
                        "enum": sorted(ALLOWED_SOUND_EFFECTS),
                    },
                },
                "required": ["effect"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_face_expression",
            "description": "Muda a expressão animada no display OLED 128x64 do McQueen.",
            "parameters": {
                "type": "object",
                "properties": {
                    "expression": {
                        "type": "string",
                        "enum": sorted(ALLOWED_EXPRESSIONS),
                    },
                },
                "required": ["expression"],
            },
        },
    },
]


@dataclass(frozen=True)
class ValidatedIntent:
    tool: str
    arguments: dict[str, Any]
    blocked: bool = False
    block_reason: str | None = None

    def to_api_dict(self) -> dict[str, Any]:
        return {
            "tool": self.tool,
            "arguments": self.arguments,
        }


def _clamp_int(val: Any, minimum: int, maximum: int, default: int) -> int:
    try:
        parsed = int(val)
    except (TypeError, ValueError):
        return default
    return max(minimum, min(maximum, parsed))


def validate_tool_call(
    tool_name: str,
    raw_args: dict[str, Any],
    robot_state: dict[str, Any],
) -> ValidatedIntent:
    """Valida nome de ferramenta, saneia parâmetros e aplica bloqueios de segurança."""
    ble_connected = bool(robot_state.get("ble_connected", False))
    sounds_enabled = bool(robot_state.get("sounds_enabled", True))
    name = tool_name.strip()

    if name not in {
        "move_robot",
        "stop_robot",
        "set_speed_mode",
        "set_indicator",
        "activate_horn",
        "play_sound_effect",
        "set_face_expression",
    }:
        return ValidatedIntent(
            tool=name,
            arguments={},
            blocked=True,
            block_reason=f"Ferramenta não permitida: {name}",
        )

    if not ble_connected:
        return ValidatedIntent(
            tool=name,
            arguments={},
            blocked=True,
            block_reason="ESP32 do McQueen está desconectado do controle BLE.",
        )

    if name == "stop_robot":
        return ValidatedIntent(tool="stop_robot", arguments={})

    if name == "move_robot":
        direction = str(raw_args.get("direction", "")).strip().lower()
        if direction not in ALLOWED_DIRECTIONS:
            return ValidatedIntent(
                tool=name,
                arguments={},
                blocked=True,
                block_reason=f"Direção inválida: {direction}",
            )
        duration_ms = _clamp_int(
            raw_args.get("duration_ms"),
            MIN_MOVE_DURATION_MS,
            MAX_MOVE_DURATION_MS,
            DEFAULT_MOVE_DURATION_MS,
        )
        args: dict[str, Any] = {
            "direction": direction,
            "duration_ms": duration_ms,
        }
        if raw_args.get("speed_percent") is not None:
            args["speed_percent"] = _clamp_int(
                raw_args.get("speed_percent"),
                MIN_MOVE_SPEED_PCT,
                MAX_MOVE_SPEED_PCT,
                int(robot_state.get("speed_percent", 60)),
            )
        return ValidatedIntent(tool="move_robot", arguments=args)

    if name == "set_speed_mode":
        mode = str(raw_args.get("mode", "")).strip().lower()
        if mode not in ALLOWED_SPEED_MODES:
            return ValidatedIntent(
                tool=name,
                arguments={},
                blocked=True,
                block_reason=f"Modo de velocidade inválido: {mode}",
            )
        return ValidatedIntent(tool="set_speed_mode", arguments={"mode": mode})

    if name == "set_indicator":
        mode = str(raw_args.get("mode", "")).strip().lower()
        if mode not in ALLOWED_INDICATORS:
            return ValidatedIntent(
                tool=name,
                arguments={},
                blocked=True,
                block_reason=f"Indicador inválido: {mode}",
            )
        return ValidatedIntent(tool="set_indicator", arguments={"mode": mode})

    if name == "activate_horn":
        if not sounds_enabled:
            return ValidatedIntent(
                tool=name,
                arguments={},
                blocked=True,
                block_reason="Buzzer silenciado (MUTE ativo no robô).",
            )
        style = str(raw_args.get("style", "normal")).strip().lower()
        if style not in ALLOWED_HORN_STYLES:
            style = "normal"
        return ValidatedIntent(tool="activate_horn", arguments={"style": style})

    if name == "play_sound_effect":
        if not sounds_enabled:
            return ValidatedIntent(
                tool=name,
                arguments={},
                blocked=True,
                block_reason="Sons silenciados (MUTE ativo no robô).",
            )
        effect = str(raw_args.get("effect", "")).strip().lower()
        if effect not in ALLOWED_SOUND_EFFECTS:
            return ValidatedIntent(
                tool=name,
                arguments={},
                blocked=True,
                block_reason=f"Efeito sonoro incompatível ou desconhecido: {effect}",
            )
        return ValidatedIntent(tool="play_sound_effect", arguments={"effect": effect})

    if name == "set_face_expression":
        expr = str(raw_args.get("expression", "")).strip().upper()
        if expr not in ALLOWED_EXPRESSIONS:
            return ValidatedIntent(
                tool=name,
                arguments={},
                blocked=True,
                block_reason=f"Expressão OLED desconhecida: {expr}",
            )
        return ValidatedIntent(
            tool="set_face_expression",
            arguments={"expression": expr},
        )

    return ValidatedIntent(tool=name, arguments={}, blocked=True, block_reason="Erro interno.")
