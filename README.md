# 🏎️ McQueen — Robô Controlado por BLE

Sistema completo de controle do robô McQueen via Bluetooth Low Energy (BLE), integrando firmware ESP32-C3, aplicativo Flutter e ferramentas de diagnóstico Python.

## 📐 Arquitetura

```
┌──────────────┐       BLE        ┌──────────────────┐
│  Flutter App  │ ◄─────────────► │  ESP32-C3 (QT Py)│
│  (Android)    │   12345678-...  │  NimBLE + Servos  │
└──────────────┘                  └──────────────────┘
                                         │
┌──────────────┐    BLE / Serial  ┌──────┴───────────┐
│ Python Tools │ ◄──────────────► │ 2x Servos RC     │
│ (diagnóstico)│                  │ Buzzer + OLED    │
└──────────────┘                  └──────────────────┘
```

## 🔩 Hardware

| Componente | Detalhes |
|---|---|
| **Placa** | Adafruit QT Py ESP32-C3 (`COM12`, `303A:1001`) |
| **Motores** | 2x Servos de rotação contínua MG990S (`GM009605v4.3`) |
| **Buzzer** | Buzzer ativo de 2 terminais (GPIO 2) |
| **Display** | OLED I2C SSD1306 128x64 (`0x3C`, 4 pinos: GND, VDD, SCK, SDA) |
| **Alimentação** | Alimentação externa dedicada para servos com GND comum |

### Pinout (Configuração Oficial no Firmware v3.1.0)

| Função | Pino | GPIO | Observações |
|---|---|---|---|
| Servo Esquerdo | A1 | GPIO 3 | Sinal PWM 50Hz (1000–2000 µs) |
| Servo Direito | A3 | GPIO 0 | Sinal PWM 50Hz (1000–2000 µs, invertido por padrão) |
| Buzzer Ativo | — | GPIO 2 | Acionamento não-bloqueante HIGH/LOW (e suporte a TONE) |
| I2C SDA (OLED) | SDA | GPIO 5 | Display OLED SSD1306 (`0x3C`) |
| I2C SCL/SCK (OLED) | SCL | GPIO 6 | Display OLED SSD1306 (`0x3C`) |

> [!WARNING]
> **NÃO alimente os servos pelo pino 3.3V da placa!**
> Use fonte/bateria separada (4.8V–6V) com GND comum entre os servos e o ESP32-C3.

## 📡 Protocolo BLE

| Parâmetro | Valor |
|---|---|
| Nome BLE | `McQueen` |
| Service UUID | `12345678-1234-5678-1234-56789abcdef0` |
| RX Char UUID (App→ESP32) | `12345678-1234-5678-1234-56789abcdef1` |
| TX Char UUID (ESP32→App) | `12345678-1234-5678-1234-56789abcdef2` |

### Comandos

| Comando | Descrição |
|---|---|
| `FRENTE` ou `FRENTE:50` | Avança (com velocidade opcional 0-100) |
| `TRAS` ou `TRAS:50` | Recua |
| `ESQUERDA` ou `ESQUERDA:50` | Curva à esquerda |
| `DIREITA` ou `DIREITA:50` | Curva à direita |
| `PARAR` | Para imediatamente (prioridade máxima) |
| `VEL:1` | Velocidade Eco (45%) |
| `VEL:2` | Velocidade Normal (70%) |
| `VEL:3` | Velocidade Turbo (100%) |
| `VELOCIDADE:nn` | Velocidade livre (0-100) |
| `MOTOR:ESQ:n` | Apenas servo esquerdo (-100..100); o direito para |
| `MOTOR:DIR:n` | Apenas servo direito (-100..100); o esquerdo para |
| `BUZINA` | Buzina longa |
| `BIPE` | Bipe curto |
| `ALERTA` | 3 bipes rápidos |
| `PING` | Teste de comunicação → responde `PONG` |
| `STATUS` | Estado atual → `V:70\|M:0\|L:1500\|R:1500\|I:01` |
| `DIAG` | Diagnóstico BLE → `DIAG:ADV:1\|CONN:0\|READY:1\|LEN:...\|SRV:1` |
| `CAL:ESTOPL:1500` | Calibra neutro servo esquerdo (µs, salvo em NVS) |
| `CAL:ESTOPR:1500` | Calibra neutro servo direito (µs, salvo em NVS) |
| `CAL:INVERTEL` | Inverte sentido do servo esquerdo (salvo em NVS) |
| `CAL:INVERTED` | Inverte sentido do servo direito (salvo em NVS) |
| `CAL:VMIN:15` | Define velocidade mínima efetiva (0–95%, salvo em NVS) |
| `CAL:VMAX:90` | Define velocidade máxima segura (5–100%, salvo em NVS) |
| `CAL:RESET` | Restaura calibração para os padrões de fábrica |
| `EXPR:NORMAL` | Expressão OLED (`NORMAL`, `FELIZ`, `SURPRESO`, `SONOLENTO`, `CURIOSO`, `TRISTE`) |

Os comandos acima também podem ser enviados pela Serial USB (uma linha por
comando), útil para diagnóstico quando o BLE não está acessível.

O anúncio BLE usa apenas o nome `McQueen` no pacote principal. O app procura
pelo nome **ou** pelo Service UUID, então essa configuração é suficiente e
evita depender de scan response.

### Segurança

- ✅ Motores **param ao ligar** (sem movimento inesperado)
- ✅ Motores **param na desconexão BLE**
- ✅ **Timeout de 800ms**: motores param se não receber comandos
- ✅ App envia keepalive de movimento a cada 250ms
- ✅ Velocidade limitada a 0-100%
- ✅ Comandos inválidos são rejeitados sem provocar movimento

## 📁 Estrutura do Projeto

```
mcqueen/
├── lib/                        # Aplicativo Flutter
│   ├── main.dart
│   ├── core/
│   │   ├── ble_constants.dart     # UUIDs e comandos (ponto único)
│   │   ├── robot_service.dart     # Interface abstrata
│   │   ├── real_ble_service.dart  # Implementação BLE real
│   │   ├── demo_robot_service.dart # Simulação para UI
│   │   └── robot_manager.dart     # Alternância Demo ↔ Real
│   └── ui/
│       ├── control_page.dart      # Tela principal
│       └── widgets/
│           ├── direction_pad.dart     # D-Pad de controle
│           ├── speed_selector.dart    # Seletor de velocidade
│           ├── connection_button.dart # Botão conectar/desconectar
│           ├── connection_dialogs.dart # Pop-ups de conexão
│           ├── control_mode_switch.dart # Modo seguro/contínuo
│           ├── buzzer_section.dart     # Controles de buzina
│           ├── telemetry_bar.dart      # Bateria, RSSI, status
│           └── logs_bottom_sheet.dart  # Console de comandos
├── firmware/
│   └── mcqueen_firmware/
│       └── mcqueen_firmware.ino   # Firmware ESP32-C3 (NimBLE + Servo)
├── tools/
│   └── python/
│       ├── mcqueen_protocol.py    # Protocolo compartilhado e validação
│       ├── mcqueen_ble_test.py    # Diagnóstico/teste BLE
│       ├── mcqueen_serial_test.py # Monitor serial
│       ├── test_mcqueen_protocol.py # Testes host (sem hardware)
│       ├── requirements.txt       # Dependências Python
│       └── venv/                  # Ambiente virtual (não versionar)
├── test/
│   ├── robot_service_test.dart    # Testes unitários
│   └── widget_test.dart
├── pubspec.yaml
└── README.md
```

## 🚀 Configuração

### Firmware (ESP32-C3)

```powershell
# Via Arduino CLI (embutido na Arduino IDE)
$cli = "C:\Users\d0465\AppData\Local\Programs\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe"

# Compilar
& $cli compile --fqbn esp32:esp32:adafruit_qtpy_esp32c3 firmware\mcqueen_firmware

# Upload para COM12
& $cli upload --fqbn esp32:esp32:adafruit_qtpy_esp32c3 --port COM12 firmware\mcqueen_firmware

# Monitor serial
& $cli monitor --port COM12 --config baudrate=115200
```

Para isolar falhas de BLE/alimentação, compile temporariamente com
`#define ENABLE_SERVOS 0` no início de `mcqueen_firmware.ino`. Nessa build os
servos não recebem PWM; use apenas para diagnóstico e reverta para `1` antes
do uso normal.

### Aplicativo Flutter

```powershell
cd c:\Users\d0465\StudioProjects\mcqueen
flutter pub get
flutter analyze
flutter test
flutter run           # Com dispositivo Android conectado
```

### Ferramentas Python

```powershell
cd tools\python

# Criar venv (já criado)
python -m venv venv
.\venv\Scripts\activate

# Instalar dependências
pip install -r requirements.txt

# Testes host do protocolo (sem hardware)
python -m unittest test_mcqueen_protocol -v

# Diagnóstico BLE
python mcqueen_ble_test.py --scan --all
python mcqueen_ble_test.py --command PING --command STATUS --command DIAG
python mcqueen_ble_test.py --command FRENTE:30 --duration 2
python mcqueen_ble_test.py --interactive
python mcqueen_ble_test.py --calibrate

# Monitor serial
python mcqueen_serial_test.py --port COM12
python mcqueen_serial_test.py --list
python mcqueen_serial_test.py --send PING --send STATUS --send DIAG
python mcqueen_serial_test.py --send FRENTE:30 --duration 2
python mcqueen_serial_test.py --interactive
```

Notas das ferramentas:
- `--write-response` força WRITE com resposta; o padrão usa WRITE sem resposta.
- `--no-notify` conecta sem assinar o TX (útil se o GATT estiver instável).
- Movimentos recebem keepalive e são interrompidos com `PARAR` ao final.
- O script serial usa UTF-8 explicitamente para evitar problemas no console Windows.

## 🔍 Diagnóstico BLE

Sintomas observados durante o desenvolvimento:

- O sketch mínimo `McQueenProbe` (somente advertising) foi encontrado pelo
  Windows em `14:63:93:93:AD:DA`, com RSSI -30 dBm.
- O firmware completo reportava `DIAG:ADV:1`, mas não aparecia no scan do
  Windows nem do script Python.
- Durante os testes a placa deixou de enumerar USB (COM12/`VID_303A`).

Hipóteses ainda não confirmadas: alimentação/brownout ao acionar servos,
interação do servidor GATT com o advertising, `setMTU(185)` ou cabo/USB. O
firmware 2.2.0 remove o MTU fixo, adiciona watchdog de advertising, permite
build `ENABLE_SERVOS=0` e registra o payload anunciado no `DIAG`.

Passos sugeridos quando a placa voltar:

1. Alimentar a placa apenas por USB, sem servos/buzzer, e confirmar o scan.
2. Gravar a build `ENABLE_SERVOS=0` e comparar descoberta/conexão.
3. Se funcionar, ligar um servo por vez com fonte externa e GND comum.
4. Testar `--scan --all`, `--command DIAG` e `--write-response`.
5. Só então testar movimento real, com o robô apoiado.

## 🧪 Sequência de Testes

1. **Ligar** a placa (sem movimento dos servos)
2. **Monitor serial**: confirmar boot, versão e `[BLE] Anunciando`
3. **BLE scan**: verificar se "McQueen" aparece; comparar com `DIAG`
4. **Conectar** pelo app Flutter ou script Python
5. **PING**: deve responder `PONG`
6. **STATUS**: deve responder `V:70|M:0|L:1500|R:1500|I:01`
7. **DIAG**: confirmar `ADV:1`, `CONN:1`, `READY:1`
8. **PARAR**: confirmar que PARAR funciona
9. **FRENTE** em baixa velocidade (VEL:1)
10. **TRAS** em baixa velocidade
11. **Curvas**: ESQUERDA e DIREITA
12. **Calibração**: ajustar neutro se servos não param completamente
13. **Desconectar** e verificar parada automática

### Status de validação

Validado em bancada:
- Compilação do firmware 2.2.0 nas variantes normal e `ENABLE_SERVOS=0`.
- Na versão 2.1.0, antes da placa desaparecer: upload, boot serial e comandos
  `PING`, `STATUS`, `DIAG` e `PARAR`.
- `flutter analyze` sem problemas, testes Flutter passando e 19 testes host
  do protocolo Python passando.

Pendente de validação física:
- Descoberta/conexão BLE do firmware completo no Windows e no Android.
- Movimento real dos servos, calibração e autonomia da bateria.
- Build/execução do APK em dispositivo Android.

> [!WARNING]
> A placa de teste desapareceu da porta COM12/USB durante o diagnóstico BLE.
> Não há como confirmar agora se a falha é de advertising, GATT, alimentação
> ou cabo. As alterações de firmware desta versão são mitigatórias e ainda
> precisam ser verificadas com a placa reconectada.

## ⚡ Alimentação (pendente)

A bateria ainda não foi especificada. Opções recomendadas:

| Opção | Tensão | Notas |
|---|---|---|
| 4x AA NiMH | 4.8V | Simples, seguro para servos |
| LiPo 2S | 7.4V | Requer regulador para 5V/6V |
| LiPo 1S + boost | 3.7V→5V | Compacto, precisa de boost converter |
| Power bank USB | 5V | Via pino VBUS, adequado para prototipagem |

> [!IMPORTANT]
> - Servos: alimentar com 4.8V-6V separadamente
> - ESP32: alimentar pelo USB ou pino 5V
> - **GND comum** entre todas as fontes
> - Não conectar bateria >6V diretamente ao ESP32

## 📋 Dependências

### Firmware
- **Arduino Core ESP32** 3.3.12
- **NimBLE-Arduino** 2.5.2
- **ESP32Servo** 3.2.1

### Flutter
- **flutter_blue_plus** ^1.34.5
- **provider** ^6.1.2
- **google_fonts** ^6.2.1

### Python
- **bleak** >=0.22.0 (testado com 3.0.2)
- **pyserial** >=3.5 (testado com 3.5)
