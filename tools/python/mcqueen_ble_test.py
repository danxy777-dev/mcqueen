#!/usr/bin/env python3
"""McQueen — Ferramenta de teste e diagnóstico BLE via Bleak.

Recursos:
  - Escanear dispositivos e localizar o McQueen pelo nome ou Service UUID.
  - Conectar e validar o serviço/características esperados.
  - Enviar comandos de movimento, velocidade, buzzer e diagnóstico.
  - Modo interativo com keepalive automático dos movimentos.
  - Modo de calibração explícito (nunca move motores automaticamente).
  - Teste não interativo: --command PING --command STATUS --command PARAR

Exemplos:
  python mcqueen_ble_test.py --scan
  python mcqueen_ble_test.py --command PING --command STATUS --command PARAR
  python mcqueen_ble_test.py --command FRENTE:30 --duration 2
  python mcqueen_ble_test.py --interactive
  python mcqueen_ble_test.py --calibrate

Requisitos: bleak >= 0.22 (testado com 3.0.2).
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import sys
from typing import Optional

try:
    from bleak import BleakClient, BleakScanner
    from bleak.exc import BleakError
    from bleak.backends.device import BLEDevice
    from bleak.backends.scanner import AdvertisementData
except ImportError:
    print("Erro: biblioteca 'bleak' não encontrada.")
    print("Ative o venv e instale com: pip install -r requirements.txt")
    sys.exit(1)

from mcqueen_protocol import (
    CHAR_RX_UUID,
    CHAR_TX_UUID,
    DEVICE_NAME,
    KEEPALIVE_INTERVAL,
    SERVICE_UUID,
    is_movement_command,
    is_motor_command,
    matches_device,
    parse_status,
    validate_command,
)

for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            pass


class McQueenBle:
    def __init__(self, client: BleakClient, use_response: bool = False) -> None:
        self.client = client
        self.use_response = use_response
        self.keepalive_task: Optional[asyncio.Task] = None
        self.active_movement: Optional[str] = None
        self.last_notification: Optional[str] = None

    def on_notification(self, _sender, data: bytearray) -> None:
        text = data.decode("utf-8", errors="replace")
        self.last_notification = text
        print(f"  <- RX: {text}")
        if text.startswith("V:") or text.startswith("M:"):
            parsed = parse_status(text)
            if parsed:
                print(f"     status: {parsed}")

    async def write(self, cmd: str, *, log: bool = True) -> bool:
        ok, reason = validate_command(cmd)
        if not ok:
            print(f"  ERRO: comando rejeitado localmente: {reason}")
            return False
        try:
            await self.client.write_gatt_char(
                CHAR_RX_UUID,
                cmd.encode("utf-8"),
                response=self.use_response,
            )
            if log:
                print(f"  -> TX: {cmd}")
            return True
        except BleakError as exc:
            print(f"  ERRO ao enviar '{cmd}': {exc}")
            return False
        except Exception as exc:  # noqa: BLE001 - diagnóstico explícito
            print(f"  ERRO inesperado ao enviar '{cmd}': {exc}")
            return False

    async def start_movement(self, cmd: str) -> None:
        await self.stop_movement(send_stop=False)
        self.active_movement = cmd
        if await self.write(cmd):
            self.keepalive_task = asyncio.create_task(self._keepalive_loop(cmd))

    async def _keepalive_loop(self, cmd: str) -> None:
        try:
            while True:
                await asyncio.sleep(KEEPALIVE_INTERVAL)
                if not self.client.is_connected:
                    return
                await self.write(cmd, log=False)
        except asyncio.CancelledError:
            return

    async def stop_movement(self, *, send_stop: bool = True) -> None:
        if self.keepalive_task is not None:
            self.keepalive_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self.keepalive_task
            self.keepalive_task = None
        self.active_movement = None
        if send_stop and self.client.is_connected:
            await self.write("PARAR")

    async def send(self, cmd: str) -> None:
        upper = cmd.strip().upper()
        if upper == "PARAR":
            await self.stop_movement(send_stop=True)
            return
        if is_movement_command(upper) or is_motor_command(upper):
            await self.start_movement(upper)
            return
        await self.write(upper)


def _print_scan_line(device: BLEDevice, adv: AdvertisementData) -> None:
    name = adv.local_name or device.name or "(sem nome)"
    uuids = ",".join(adv.service_uuids) if adv.service_uuids else "-"
    print(f"  {device.address:<24} {name:<20} RSSI={adv.rssi:>4} dBm  UUIDs={uuids}")


async def scan_for_mcqueen(
    device_name: str,
    timeout: float,
    show_all: bool = False,
) -> Optional[BLEDevice]:
    print(f"\nProcurando '{device_name}' por até {timeout:.0f}s...")
    target_srv = SERVICE_UUID if device_name == DEVICE_NAME else ""

    if not show_all:
        matched_adv: Optional[AdvertisementData] = None

        def _filter(dev: BLEDevice, adv: AdvertisementData) -> bool:
            nonlocal matched_adv
            if matches_device(
                dev.name,
                adv.local_name,
                adv.service_uuids,
                target_name=device_name,
                target_service=target_srv,
            ):
                matched_adv = adv
                return True
            return False

        found = await BleakScanner.find_device_by_filter(_filter, timeout=timeout)
        if found is not None and matched_adv is not None:
            _print_scan_line(found, matched_adv)
            return found
    else:
        results = await BleakScanner.discover(timeout=timeout, return_adv=True)
        found = None
        for device, adv in results.values():
            is_target = matches_device(
                device.name,
                adv.local_name,
                adv.service_uuids,
                target_name=device_name,
                target_service=target_srv,
            )
            _print_scan_line(device, adv)
            if is_target and found is None:
                found = device
        if found is not None:
            return found

    print(f"Dispositivo '{device_name}' não encontrado.")
    print("Verifique se o ESP32-C3 está ligado e anunciando BLE.")
    return None


def validate_services(client: BleakClient) -> bool:
    print("\nValidando serviços GATT...")
    services = list(client.services)
    target = next(
        (s for s in services if str(s.uuid).lower() == SERVICE_UUID.lower()),
        None,
    )
    if target is None:
        print(f"ERRO: serviço {SERVICE_UUID} não encontrado.")
        for service in services:
            print(f"  - {service.uuid}: {service.description}")
        return False

    print(f"OK: serviço encontrado: {target.uuid}")
    rx_found = False
    tx_found = False
    for char in target.characteristics:
        uuid = str(char.uuid).lower()
        props = ",".join(char.properties)
        if uuid == CHAR_RX_UUID.lower():
            rx_found = True
            print(f"OK: RX {char.uuid} [{props}]")
        elif uuid == CHAR_TX_UUID.lower():
            tx_found = True
            print(f"OK: TX {char.uuid} [{props}]")
        else:
            print(f"   outra characteristic: {char.uuid} [{props}]")

    if not rx_found:
        print(f"ERRO: característica RX {CHAR_RX_UUID} não encontrada.")
        return False
    if not tx_found:
        print("AVISO: característica TX não encontrada (sem notificações).")
    return True


async def connect(address_or_device, timeout: float) -> Optional[BleakClient]:
    for attempt in range(1, 3):
        target = address_or_device
        if attempt > 1 and hasattr(address_or_device, "address"):
            refreshed = await BleakScanner.find_device_by_address(
                address_or_device.address, timeout=4.0
            )
            if refreshed is not None:
                target = refreshed
        client = BleakClient(target, timeout=timeout)
        try:
            label = f" (tentativa {attempt}/2)" if attempt > 1 else ""
            print(f"\nConectando a {target}{label}...")
            await client.connect()
            print("Conectado.")
            return client
        except Exception as exc:  # noqa: BLE001
            detail = str(exc).strip() or repr(exc)
            print(f"ERRO ao conectar: {detail}")
            if attempt < 2:
                await asyncio.sleep(0.5)
    return None


async def interactive_mode(link: McQueenBle) -> None:
    print("\n" + "=" * 60)
    print("  McQueen — Modo Interativo BLE")
    print("=" * 60)
    print("Movimento: FRENTE[:n] TRAS[:n] ESQUERDA[:n] DIREITA[:n] PARAR")
    print("Individual: MOTOR:ESQ:20  MOTOR:DIR:-20")
    print("Velocidade: VEL:1 VEL:2 VEL:3 VELOCIDADE:n (0-100)")
    print("Buzzer: BUZINA BIPE ALERTA | Diagnóstico: PING STATUS")
    print("Calibração: CAL:ESTOPL:1500 CAL:ESTOPR:1500 CAL:INVERTEL CAL:INVERTED")
    print("Sair: quit / exit / q")
    print("Movimentos recebem keepalive automático até PARAR.\n")

    while link.client.is_connected:
        try:
            cmd = (await asyncio.to_thread(input, "mcqueen> ")).strip()
        except (EOFError, KeyboardInterrupt):
            print("\nEncerrando...")
            break

        if not cmd:
            continue
        if cmd.lower() in ("quit", "exit", "q", "sair"):
            break
        if cmd.upper() == "HELP":
            print("Use FRENTE:30, MOTOR:ESQ:20, STATUS, PARAR, etc.")
            continue
        await link.send(cmd)
        await asyncio.sleep(0.1)

    await link.stop_movement(send_stop=True)


async def calibration_mode(link: McQueenBle) -> None:
    print("\n" + "=" * 60)
    print("  McQueen — Modo de Calibração de Servos")
    print("=" * 60)
    print("ATENÇÃO: nenhum motor gira automaticamente. Você tem controle total.")
    print("Mantenha o robô apoiado e confirme a alimentação externa dos servos.")
    print("Comandos disponíveis:")
    print("  1. Pulso de parada (µs): CAL:ESTOPL:1500 | CAL:ESTOPR:1500 (1000-2000)")
    print("  2. Sentido de rotação  : CAL:INVERTEL    | CAL:INVERTED")
    print("  3. Velocidade mínima % : CAL:VMIN:15     (0-95)")
    print("  4. Velocidade máxima % : CAL:VMAX:90     (5-100)")
    print("  5. Restaurar padrões   : CAL:RESET")
    print("  6. Teste individual    : MOTOR:ESQ:15    | MOTOR:DIR:15 | PARAR")
    print("  7. Consultar estado    : STATUS")
    print("Digite PARAR para interromper imediatamente. Sair: quit / exit / q.\n")

    while link.client.is_connected:
        try:
            cmd = (await asyncio.to_thread(input, "cal> ")).strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not cmd:
            continue
        if cmd.lower() in ("quit", "exit", "q", "sair"):
            break
        await link.send(cmd)
        await asyncio.sleep(0.15)

    await link.stop_movement(send_stop=True)


async def run_commands(link: McQueenBle, commands: list[str], duration: float) -> None:
    for command in commands:
        ok, reason = validate_command(command)
        if not ok:
            print(f"Ignorando '{command}': {reason}")
            continue

        cmd = command.strip().upper()
        if is_movement_command(cmd) or is_motor_command(cmd):
            await link.start_movement(cmd)
            seconds = duration if duration > 0 else 1.0
            print(f"Movimento ativo por {seconds:.1f}s (keepalive)...")
            await asyncio.sleep(seconds)
            await link.stop_movement(send_stop=True)
        else:
            await link.write(cmd)
            await asyncio.sleep(0.35)

    if link.keepalive_task is not None:
        await link.stop_movement(send_stop=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="McQueen — diagnóstico e testes BLE",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--scan", action="store_true", help="apenas escanear e sair")
    parser.add_argument("--all", action="store_true", help="mostrar todos os dispositivos no scan")
    parser.add_argument("--device", default=DEVICE_NAME, help=f"nome BLE (padrão: {DEVICE_NAME})")
    parser.add_argument("--address", help="endereço BLE (pula o scan)")
    parser.add_argument("--timeout", type=float, default=10.0, help="timeout do scan/conexão (s)")
    parser.add_argument("--command", "-c", action="append", default=[], help="comando a enviar (repetível)")
    parser.add_argument("--duration", type=float, default=0.0, help="segundos de movimento antes de PARAR")
    parser.add_argument("--interactive", action="store_true", help="abrir CLI interativa")
    parser.add_argument("--calibrate", action="store_true", help="abrir modo de calibração")
    parser.add_argument("--expression", action="store_true", help="testar expressões no display OLED")
    parser.add_argument("--sound", action="store_true", help="testar som no buzzer")
    parser.add_argument("--move", action="store_true", help="testar sequência segura de movimento das rodas")
    parser.add_argument("--write-response", action="store_true", help="usar WRITE com resposta")
    parser.add_argument("--no-notify", action="store_true", help="não assinar notificações TX")
    return parser


async def async_main(args: argparse.Namespace) -> int:
    print("=" * 60)
    print("  McQueen — Diagnóstico BLE (Python)")
    print("=" * 60)

    if args.scan:
        await scan_for_mcqueen(args.device, args.timeout, show_all=True)
        return 0

    target = args.address
    if target is None:
        device = await scan_for_mcqueen(args.device, args.timeout, show_all=args.all)
        if device is None:
            return 1
        target = device

    client = await connect(target, args.timeout)
    if client is None:
        return 1

    link = McQueenBle(client, use_response=args.write_response)
    exit_code = 0
    try:
        if not validate_services(client):
            print("Serviço BLE incompatível. O firmware correto está gravado?")
            return 2

        if not args.no_notify:
            try:
                await client.start_notify(CHAR_TX_UUID, link.on_notification)
                print("Notificações TX ativas.")
            except Exception as exc:  # noqa: BLE001
                print(f"AVISO: notificações TX indisponíveis: {exc}")

        await link.write("PING")
        await asyncio.sleep(0.3)

        preset_commands: list[str] = []
        if args.expression:
            preset_commands.extend(["EXPR:FELIZ", "EXPR:SURPRESO", "EXPR:CURIOSO", "EXPR:NORMAL"])
        if args.sound:
            preset_commands.extend(["BIPE", "BUZINA"])
        if args.move:
            preset_commands.extend(["FRENTE:40", "TRAS:40", "ESQUERDA:40", "DIREITA:40", "PARAR"])

        all_commands = preset_commands + list(args.command)

        if all_commands:
            await run_commands(link, all_commands, args.duration)
        if args.interactive:
            await interactive_mode(link)
        elif args.calibrate:
            await calibration_mode(link)
        elif not all_commands:
            print("\nNenhum comando/modo informado. Executando teste seguro:")
            await link.write("PING")
            await asyncio.sleep(0.3)
            await link.write("STATUS")
            await asyncio.sleep(0.3)
            await link.write("PARAR")
            await asyncio.sleep(0.2)
    except KeyboardInterrupt:
        print("\nInterrompido pelo usuário.")
        exit_code = 130
    finally:
        if client.is_connected:
            with contextlib.suppress(Exception):
                await link.stop_movement(send_stop=True)
            with contextlib.suppress(Exception):
                await client.stop_notify(CHAR_TX_UUID)
            with contextlib.suppress(Exception):
                await client.disconnect()
        print("Desconectado.")

    return exit_code


def main() -> int:
    args = build_parser().parse_args()
    try:
        return asyncio.run(async_main(args))
    except KeyboardInterrupt:
        print("\nInterrompido pelo usuário.")
        return 130
    except Exception as exc:  # noqa: BLE001
        print(f"\nERRO: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
