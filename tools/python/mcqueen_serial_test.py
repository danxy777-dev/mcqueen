#!/usr/bin/env python3
"""
McQueen — Monitor Serial para diagnóstico do ESP32-C3.

Permite:
  - Verificar se a porta COM está acessível.
  - Ler mensagens de inicialização e diagnóstico do firmware.
  - Enviar comandos pela serial (modo debug).
  - Identificar se a porta está ocupada por outro processo.

Requisitos: pyserial (pip install pyserial)
"""

import argparse
import sys
import threading
import time

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    print("Erro: biblioteca 'pyserial' não encontrada.")
    print("Instale com: pip install pyserial")
    sys.exit(1)

try:
    from mcqueen_protocol import is_motor_command, is_movement_command, validate_command
except ImportError:
    print("Erro: mcqueen_protocol.py não encontrado no mesmo diretório.")
    sys.exit(1)


# Console do Windows (cp1252) não aceita emojis/box drawing por padrão.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            pass


# ─── Configuração padrão ──────────────────────────────────────────────────────
DEFAULT_PORT = "COM12"
DEFAULT_BAUD = 115200
ESP32_VID    = 0x303A   # Espressif VID
ESP32_PID    = 0x1001   # ESP32 USB-CDC PID


def list_serial_ports():
    """Lista todas as portas seriais disponíveis com detalhes."""
    ports = serial.tools.list_ports.comports()
    if not ports:
        print("❌ Nenhuma porta serial encontrada.")
        return []

    print(f"\n{'Porta':<10} {'Descrição':<40} {'VID:PID':<12} {'Serial':<20}")
    print("─" * 85)
    for p in sorted(ports, key=lambda x: x.device):
        vid_pid = f"{p.vid:04X}:{p.pid:04X}" if p.vid else "----:----"
        serial_num = p.serial_number or "—"
        is_esp = " ← ESP32" if (p.vid == ESP32_VID and p.pid == ESP32_PID) else ""
        print(f"{p.device:<10} {p.description:<40} {vid_pid:<12} {serial_num:<20}{is_esp}")

    return ports


def find_esp32_port():
    """Procura a porta do ESP32-C3 pelo VID/PID."""
    ports = serial.tools.list_ports.comports()
    for p in ports:
        if p.vid == ESP32_VID and p.pid == ESP32_PID:
            return p.device
    return None


def check_port_access(port: str, baud: int = DEFAULT_BAUD) -> bool:
    """Verifica se a porta pode ser aberta (não está ocupada)."""
    try:
        with serial.Serial(port, baud, timeout=0.1):
            return True
    except serial.SerialException as e:
        err = str(e).lower()
        if "access" in err or "denied" in err or "em uso" in err or "busy" in err:
            print(f"❌ Porta {port} está ocupada por outro processo.")
            print("   Possíveis causas:")
            print("   - Arduino IDE Serial Monitor aberto")
            print("   - Outro script Python usando a porta")
            print("   - Ferramenta de upload em execução")
            print()
            print("   Para liberar:")
            print("   1. Feche o Serial Monitor do Arduino IDE")
            print("   2. Ou verifique processos com: Get-Process | Where-Object { $_.MainWindowTitle -match 'Arduino' }")
        else:
            print(f"❌ Erro ao abrir {port}: {e}")
        return False


def _prefix_for(line: str) -> str:
    if "[ERR" in line or "ERR:" in line:
        return "❌"
    if "[WARN" in line:
        return "⚠️ "
    if "[BLE]" in line:
        return "📡"
    if "[MOTOR]" in line:
        return "⚙️ "
    if "[BUZZER]" in line:
        return "🔔"
    if "[INIT]" in line or "[McQueen]" in line:
        return "🚗"
    if "[SAFETY]" in line:
        return "🛡️ "
    if "[TX]" in line:
        return "📤"
    if "[CAL]" in line:
        return "🔧"
    if "[VEL]" in line:
        return "💨"
    return "  "


def _send_serial(ser, cmd: str) -> bool:
    ok, reason = validate_command(cmd)
    if not ok:
        print(f"  ERRO: comando rejeitado: {reason}")
        return False
    ser.write((cmd.strip() + "\n").encode("utf-8"))
    print(f"  → TX serial: {cmd.strip().upper()}")
    return True


def monitor_serial(
    port: str,
    baud: int,
    interactive: bool = False,
    duration: float = 0.0,
    commands: list[str] | None = None,
):
    """Monitora a porta serial, exibindo mensagens do ESP32.

    Comandos de movimento enviados por --send recebem reenvio periódico
    durante --duration e PARAR ao final (o firmware para sozinho em 800 ms).
    """
    print(f"\n📡 Conectando a {port} @ {baud} baud...")

    try:
        ser = serial.Serial(port, baud, timeout=0.5)
    except serial.SerialException as e:
        print(f"❌ Não foi possível abrir {port}: {e}")
        return

    # Limpa bytes antigos sem resetar a placa.
    time.sleep(0.2)
    ser.reset_input_buffer()

    print("✅ Conectado! Lendo mensagens...")
    print("   (Pressione Ctrl+C para sair)")
    print("─" * 60)

    running = True

    def read_loop():
        while running:
            try:
                line = ser.readline().decode("utf-8", errors="replace").rstrip()
                if line:
                    timestamp = time.strftime("%H:%M:%S")
                    print(f"  {timestamp} {_prefix_for(line)} {line}")
            except serial.SerialException:
                print("\n⚠️  Porta serial desconectada!")
                break
            except UnicodeDecodeError:
                pass

    reader = threading.Thread(target=read_loop, daemon=True)
    reader.start()

    # Aguarda eventual inicialização/boot da placa ao abrir a porta USB-CDC
    if commands:
        time.sleep(0.8)

    # Envio programado (não interativo).
    if commands:
        for cmd in commands:
            upper = cmd.strip().upper()
            is_move = is_movement_command(upper) or is_motor_command(upper)
            if is_move and duration > 0:
                print(f"\n▶ Movimento '{upper}' por {duration:.1f}s...")
                end = time.time() + duration
                while time.time() < end and running:
                    _send_serial(ser, upper)
                    time.sleep(0.3)
                _send_serial(ser, "PARAR")
                time.sleep(0.2)
            else:
                _send_serial(ser, upper)
                if is_move:
                    # Sem duração: movimento breve e parada automática.
                    time.sleep(0.6)
                    _send_serial(ser, "PARAR")
                time.sleep(0.25)

    if interactive:
        print()
        print("💬 Modo interativo ativo — digite comandos para enviar pela serial.")
        print("   Movimentos param sozinhos após 800 ms (timeout de segurança).")
        print("   Para movimento contínuo, use --send FRENTE --duration 5.")
        print("   Sair: quit / exit / q")
        print()

    start = time.time()
    commands_finished = time.time() if commands else None
    try:
        while running:
            if interactive:
                try:
                    cmd = input("serial> ")
                    if cmd.strip().lower() in ("quit", "exit", "q", "sair"):
                        break
                    if cmd.strip():
                        _send_serial(ser, cmd)
                except EOFError:
                    break
            else:
                if commands_finished is not None:
                    # Mantém o monitor por 1,5 s após os comandos programados.
                    if time.time() - commands_finished >= 1.5:
                        break
                elif duration > 0 and time.time() - start >= duration:
                    break
                time.sleep(0.1)
    except KeyboardInterrupt:
        pass
    finally:
        running = False
        try:
            if ser.is_open:
                _send_serial(ser, "PARAR")
                time.sleep(0.1)
                ser.close()
        except serial.SerialException:
            pass
        print("\n" + "─" * 60)
        print("📴 Monitor serial encerrado. Porta fechada.")


def reset_esp32(port: str, baud: int):
    """Envia sinal de reset via DTR/RTS (se suportado pela placa)."""
    print(f"🔄 Tentando reset do ESP32 via {port}...")
    try:
        ser = serial.Serial(port, baud, timeout=1)
        ser.dtr = False
        ser.rts = True
        time.sleep(0.1)
        ser.rts = False
        time.sleep(0.1)
        ser.dtr = True
        time.sleep(0.5)

        # Lê resposta por 3 segundos
        end = time.time() + 3
        while time.time() < end:
            if ser.in_waiting:
                line = ser.readline().decode("utf-8", errors="replace").rstrip()
                if line:
                    print(f"  {line}")
            else:
                time.sleep(0.05)

        ser.close()
        print("✅ Reset concluído.")
    except serial.SerialException as e:
        print(f"❌ Erro: {e}")


def main():
    parser = argparse.ArgumentParser(
        description="McQueen — Monitor Serial para ESP32-C3",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exemplos:
  python mcqueen_serial_test.py                        # Monitor contínuo COM12
  python mcqueen_serial_test.py --duration 6           # Captura o boot por 6 s
  python mcqueen_serial_test.py --send PING --send STATUS --send PARAR
  python mcqueen_serial_test.py --send FRENTE:30 --duration 2
  python mcqueen_serial_test.py --interactive          # Enviar comandos manualmente
  python mcqueen_serial_test.py --reset                # Reset via DTR/RTS
        """,
    )
    parser.add_argument("--port", "-p", default=DEFAULT_PORT, help=f"Porta serial (padrão: {DEFAULT_PORT})")
    parser.add_argument("--baud", "-b", type=int, default=DEFAULT_BAUD, help=f"Baud rate (padrão: {DEFAULT_BAUD})")
    parser.add_argument("--list", "-l", action="store_true", help="Listar portas seriais disponíveis")
    parser.add_argument("--interactive", "-i", action="store_true", help="Modo interativo (enviar comandos pela serial)")
    parser.add_argument("--send", "-s", action="append", default=[], help="comando a enviar pela serial (repetível)")
    parser.add_argument("--duration", "-d", type=float, default=0.0, help="duração do monitor/movimento (s)")
    parser.add_argument("--reset", "-r", action="store_true", help="Enviar reset para o ESP32")
    parser.add_argument("--find", "-f", action="store_true", help="Encontrar automaticamente o ESP32")

    args = parser.parse_args()

    print("╔══════════════════════════════════════════╗")
    print("║   McQueen — Monitor Serial (ESP32-C3)    ║")
    print("╚══════════════════════════════════════════╝")

    if args.list:
        list_serial_ports()
        return

    if args.find:
        port = find_esp32_port()
        if port:
            print(f"✅ ESP32-C3 encontrado em: {port}")
            args.port = port
        else:
            print("❌ ESP32-C3 não encontrado.")
            print("   Portas disponíveis:")
            list_serial_ports()
            return

    # Verifica acesso à porta
    print(f"\n🔍 Verificando porta {args.port}...")
    if not check_port_access(args.port, args.baud):
        return

    print(f"✅ Porta {args.port} acessível.")

    if args.reset:
        reset_esp32(args.port, args.baud)
        return

    monitor_serial(
        args.port,
        args.baud,
        interactive=args.interactive,
        duration=args.duration,
        commands=args.send,
    )


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\n👋 Interrompido pelo usuário.")
    except Exception as e:
        print(f"\n❌ Erro: {e}")
        sys.exit(1)

