/**
 * McQueen Robot Firmware — Adafruit QT Py ESP32-C3 (McQueen 2.0)
 *
 * Módulos integrados:
 *   1. BLE (NimBLE-Arduino): Servidor GATT com características RX (WRITE/WRITE_NR)
 *      e TX (NOTIFY/READ), suportando protocolo JSON estruturado e comandos de texto.
 *   2. Servos de Rotação Contínua: Controle independente e diferencial proporcional,
 *      perfis de velocidade (Lento, Normal, Esportivo, Máximo), calibração individual
 *      de ponto neutro (µs), inversão de sentido, faixa VMIN/VMAX e compensação (Trim L/R).
 *   3. Central de Sons (GPIO 2 + GPIO 1/A2): Sequenciador não-bloqueante multi-etapas
 *      via esp_timer (compatível com Buzzer Ativo DC por cadência rítmica e Buzzer Passivo
 *      por frequência real), com 5 buzinas, 9 efeitos e 3 melodias 8-bit originais.
 *   4. Display OLED I2C 128x64 (SDA=GPIO 5, SCL=GPIO 6): 12 expressões animadas
 *      (Normal, Feliz, Bravo, Triste, Surpreso, Curioso, Sonolento, Animado,
 *      Confuso, Assustado, Apaixonado, Piscando) + Sistema de Reações Automáticas Idle.
 *
 * Hardware & Pinagem (Adafruit QT Py ESP32-C3):
 *   - Servo esquerdo : GPIO 3 (sinal PWM 100Hz)
 *   - Servo direito  : GPIO 0 (sinal PWM 100Hz)
 *   - Buzzer         : GPIO 2 (espelhado em GPIO 1 / A2)
 *   - SDA do display : GPIO 5 (I2C)
 *   - SCK/SCL display: GPIO 6 (I2C)
 *   - Seta esquerda  : GPIO 7 (LED + resistor 220 Ω -> GND)
 *   - Seta direita   : GPIO 9 (LED + resistor 220 Ω -> GND; pino BOOT/strapping)
 *
 * Setas (v4.3.0):
 *   - SETA:ESQUERDA | SETA:DIREITA | SETA:ALERTA | SETA:AUTO | SETA:DESLIGAR
 *   - Diagnóstico individual de LED: LED:ESQ:ON/OFF | LED:DIR:ON/OFF | LED:AMBOS:ON | LED:OFF | LED:STATUS
 *   - Pisca a cada 500 ms via millis() (sem delay), aplicado no loop().
 *   - Desconexão BLE apaga as setas imediatamente; conexão nova começa apagada.
 *   - Comandos de seta não alteram motores nem o watchdog dos servos.
 *
 * Segurança:
 *   - Inicialização nunca movimenta o robô sozinha (servos iniciam no neutro parado).
 *   - Desconexão BLE para imediatamente os dois motores.
 *   - Timeout automático adaptativo (600–800 ms) para os motores se o app parar de enviar.
 *   - Reconexão mantém os motores parados até novo comando explícito.
 *   - Botão/comando PARAR tem prioridade máxima.
 *   - Reações automáticas nunca rodam com motores em movimento e não usam delay().
 *
 * Versão: 4.3.0
 */

#include <Arduino.h>
#include <Preferences.h>
#include <Wire.h>
#include <esp_timer.h>
#include <driver/gpio.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <NimBLEDevice.h>
#include <ESP32Servo.h>

// ─── Opções de Compilação ─────────────────────────────────────────────────────
#ifndef ENABLE_SERVOS
  #define ENABLE_SERVOS 1
#endif

#ifndef ENABLE_OLED
  #define ENABLE_OLED 1
#endif

#ifndef BLE_TX_POWER_DBM
  #define BLE_TX_POWER_DBM 3
#endif

#ifndef BLE_ADV_INTERVAL
  #define BLE_ADV_INTERVAL 100
#endif

// ─── Identificadores BLE ──────────────────────────────────────────────────────
#define FIRMWARE_VERSION      "4.3.0"
#define BLE_DEVICE_NAME       "McQueen"
#define SERVICE_UUID          "12345678-1234-5678-1234-56789abcdef0"
#define CHAR_RX_UUID          "12345678-1234-5678-1234-56789abcdef1"  // App → ESP32
#define CHAR_TX_UUID          "12345678-1234-5678-1234-56789abcdef2"  // ESP32 → App
#define MAX_COMMAND_LENGTH    180

// ─── Pinagem do Hardware McQueen ──────────────────────────────────────────────
#define SERVO_LEFT_PIN        3   // GPIO 3 — Servo esquerdo
#define SERVO_RIGHT_PIN       0   // GPIO 0 — Servo direito
#define BUZZER_PIN            2   // GPIO 2 — Buzzer (pino padrão)
#define BUZZER_ALT_PIN        1   // GPIO 1 — Pino A2 da Adafruit QT Py ESP32-C3 (espelhado)
#define I2C_SDA_PIN           5   // GPIO 5 — SDA do display OLED
#define I2C_SCL_PIN           6   // GPIO 6 — SCK/SCL do display OLED
#define SETA_ESQ_PIN          7   // GPIO 7 — LED da seta esquerda (resistor 220 Ω)
#define SETA_DIR_PIN          9  // GPIO 9 — LED da seta direita (resistor 220 Ω)

// ─── Configuração das Setas ───────────────────────────────────────────────────
// 1 = LED acende com nível ALTO (GPIO → 220 Ω → LED → GND).
// 0 = LED acende com nível BAIXO (3V3 → LED → 220 Ω → GPIO).
#ifndef SETA_ATIVA_EM_NIVEL_ALTO
  #define SETA_ATIVA_EM_NIVEL_ALTO 1
#endif
#define SETA_INTERVALO_MS     500  // Meio período do pisca (aceso 500 ms / apagado 500 ms)

// ─── Estado das Setas (v3.3.0) ─────────────────────────────────────────────────
enum SetaEstado {
  SETA_DESLIGADA = 0,
  SETA_ESQUERDA,
  SETA_DIREITA,
  SETA_ALERTA,
  SETA_AUTO
};

SetaEstado currentSetaEstado = SETA_DESLIGADA;
bool setaLedState = false;           // Estado atual do LED (aceso/apagado)
uint32_t lastSetaToggleMs = 0;       // Última alternância do pisca
bool setaLeftActive = false;         // Seta esquerda ativa no ciclo de pisca
bool setaRightActive = false;        // Seta direita ativa no ciclo de pisca
bool setaLeftPinHigh = false;        // Estado físico comandado no GPIO 7
bool setaRightPinHigh = false;       // Estado físico comandado no GPIO 9
bool autoSetasEnabled = false;       // true habilita setas automáticas nas curvas/parada

// ─── Configuração Otimizada dos Servos MG990S ──────────────────────────────────
// MG990S: 50Hz padrão, mas suporta até 333Hz. Usamos 100Hz para resposta mais suave.
// Faixa de pulso otimizada para MG990S: 1000-2000µs (neutro em 1500µs)
#define SERVO_PWM_FREQ_HZ       100   // 100Hz para resposta mais suave (MG990S suporta até 333Hz)
#define SERVO_MIN_US            1000  // Pulso mínimo (µs)
#define SERVO_MAX_US            2000  // Pulso máximo (µs)
#define SERVO_CENTER_US         1500  // Ponto neutro (µs)
#define SERVO_RANGE_US          500   // Variação máxima a partir do centro (±500µs)

#define SERVO_MIN_MAX_US        2000  // Limite máximo absoluto
#define CAL_MIN_US              1000
#define CAL_MAX_US              2000

// ─── Perfis de Velocidade (McQueen 4.0) ───────────────────────────────────────
enum SpeedProfile {
  SPEED_ECO      = 0,  // 30% - Economia, controle preciso
  SPEED_NORMAL   = 1,  // 60% - Uso diário equilibrado
  SPEED_SPORT    = 2,  // 85% - Aceleração e velocidade elevadas
  SPEED_TURBO    = 3   // 100% - Máxima velocidade segura
};

const uint8_t SPEED_PROFILE_PCT[4] = {30, 60, 85, 100};

// ─── Configuração do Display OLED ─────────────────────────────────────────────
#define SCREEN_WIDTH          128
#define SCREEN_HEIGHT         64
#define OLED_I2C_ADDRESS      0x3C

#if ENABLE_OLED
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);
bool oledReady = false;
#endif

// ─── 12 Expressões do Display OLED (McQueen 2.0) ──────────────────────────────
enum RobotExpression {
  EXPR_NORMAL = 0,
  EXPR_FELIZ,
  EXPR_BRAVO,
  EXPR_TRISTE,
  EXPR_SURPRESO,
  EXPR_CURIOSO,
  EXPR_SONOLENTO,
  EXPR_ANIMADO,
  EXPR_CONFUSO,
  EXPR_ASSUSTADO,
  EXPR_APAIXONADO,
  EXPR_PISCANDO,
  EXPR_COUNT
};

RobotExpression currentExpression = EXPR_NORMAL;
RobotExpression baseExpression    = EXPR_NORMAL;

// ─── Sistema de Reações Automáticas (Idle Behavior) ───────────────────────────
bool     autoReactionsEnabled   = true;
uint32_t autoReactionIntervalMs = 8000;   // Padrão: a cada 8s parado
uint16_t allowedReactionsMask   = 0x0FFF; // Todas as 12 expressões habilitadas
bool     inTempReaction         = false;
uint32_t tempReactionStartMs    = 0;
uint32_t tempReactionDurationMs = 2400;
uint32_t lastActivityMs         = 0;
uint32_t lastAutoReactionMs     = 0;
bool     isSleepyIdle           = false;

const char* expressionToString(RobotExpression expr) {
  switch (expr) {
    case EXPR_NORMAL:     return "NORMAL";
    case EXPR_FELIZ:      return "FELIZ";
    case EXPR_BRAVO:      return "BRAVO";
    case EXPR_TRISTE:     return "TRISTE";
    case EXPR_SURPRESO:   return "SURPRESO";
    case EXPR_CURIOSO:    return "CURIOSO";
    case EXPR_SONOLENTO:  return "SONOLENTO";
    case EXPR_ANIMADO:    return "ANIMADO";
    case EXPR_CONFUSO:    return "CONFUSO";
    case EXPR_ASSUSTADO:  return "ASSUSTADO";
    case EXPR_APAIXONADO: return "APAIXONADO";
    case EXPR_PISCANDO:   return "PISCANDO";
    default:              return "NORMAL";
  }
}

bool parseExpression(const String& name, RobotExpression& out) {
  String up = name;
  up.trim();
  up.toUpperCase();
  if (up == "NORMAL" || up == "NEUTRO" || up == "0") {
    out = EXPR_NORMAL;
    return true;
  }
  if (up == "FELIZ" || up == "HAPPY" || up == "1") {
    out = EXPR_FELIZ;
    return true;
  }
  if (up == "BRAVO" || up == "ANGRY" || up == "RAIVA" || up == "2") {
    out = EXPR_BRAVO;
    return true;
  }
  if (up == "TRISTE" || up == "SAD" || up == "3") {
    out = EXPR_TRISTE;
    return true;
  }
  if (up == "SURPRESO" || up == "SURPRESA" || up == "SURPRISED" || up == "4") {
    out = EXPR_SURPRESO;
    return true;
  }
  if (up == "CURIOSO" || up == "CURIOUS" || up == "DESCONFIADO" || up == "5") {
    out = EXPR_CURIOSO;
    return true;
  }
  if (up == "SONOLENTO" || up == "SLEEPY" || up == "DORMIR" || up == "6") {
    out = EXPR_SONOLENTO;
    return true;
  }
  if (up == "ANIMADO" || up == "EXCITED" || up == "EMPOLGADO" || up == "7") {
    out = EXPR_ANIMADO;
    return true;
  }
  if (up == "CONFUSO" || up == "CONFUSED" || up == "DUVIDA" || up == "8") {
    out = EXPR_CONFUSO;
    return true;
  }
  if (up == "ASSUSTADO" || up == "SCARED" || up == "MEDO" || up == "9") {
    out = EXPR_ASSUSTADO;
    return true;
  }
  if (up == "APAIXONADO" || up == "LOVE" || up == "CORACAO" || up == "10") {
    out = EXPR_APAIXONADO;
    return true;
  }
  if (up == "PISCANDO" || up == "WINK" || up == "PISCAR" || up == "11") {
    out = EXPR_PISCANDO;
    return true;
  }
  return false;
}

// Variáveis da animação dos olhos (128x64)
int olhoL_X = 38;
int olhoR_X = 90;
int olhoY = 34;
int olhoLargura = 32;
int olhoAltura = 40;
int pupilaOffsetX = 0;
int pupilaOffsetY = 0;
bool piscando = false;
unsigned long ultimaPiscada = 0;
unsigned long duracaoPiscada = 0;
unsigned long ultimoFrameOled = 0;

// ─── Calibração e Estado dos Servos de Rotação Contínua ───────────────────────
int  servoLeftStop     = 1500;  // µs — ponto neutro calibrado do servo esquerdo
int  servoRightStop    = 1500;  // µs — ponto neutro calibrado do servo direito
bool servoLeftInvert   = false; // Inverte sentido de rotação do servo esquerdo
bool servoRightInvert  = true;  // Inverte sentido do direito (montagem espelhada)
int  minSpeedPercent   = 0;     // %  — velocidade mínima efetiva (compensação de zona morta, 0..95)
int  maxSpeedPercent   = 100;   // %  — velocidade máxima efetiva segura (5..100)
int  servoLeftTrim     = 0;     // %  — compensação fina lado esquerdo (-50..+50)
int  servoRightTrim    = 0;     // %  — compensação fina lado direito (-50..+50)

int  currentLeftSpeed  = 0;     // -100..+100 (%)
int  currentRightSpeed = 0;     // -100..+100 (%)
int  currentLeftUs     = 1500;  // Pulso atual enviado ao servo esquerdo (µs)
int  currentRightUs    = 1500;  // Pulso atual enviado ao servo direito (µs)
String currentDirection = "PARADO";
Preferences calPrefs;

#define SERVO_MIN_US      1000
#define SERVO_MAX_US      2000
#define SERVO_RANGE_US    500
#define CAL_MIN_US        1000
#define CAL_MAX_US        2000

// ─── Velocidade ───────────────────────────────────────────────────────────────
#define MAX_SPEED_PERCENT 100
int speedPercent = SPEED_PROFILE_PCT[SPEED_NORMAL]; // Padrão: Normal (60%)

// ─── Timeout de Segurança ─────────────────────────────────────────────────────
#define SAFETY_TIMEOUT_MS 800
uint32_t lastMoveCommandTime = 0;
bool     motorsRunning       = false;

enum DriveSource {
  DRIVE_NONE = 0,
  DRIVE_DISCRETE_DIR,
  DRIVE_DIFF,
  DRIVE_MOTOR_SINGLE
};
DriveSource activeDriveSource = DRIVE_NONE;
String      activeDiscreteDir = "";

// ─── Sequenciador Não-Bloqueante da Central de Sons (GPIO 2 + GPIO 1/A2) ──────
struct ToneStep {
  uint16_t freq;   // Frequência em Hz (para modo passivo / híbrido)
  uint16_t onMs;   // Tempo ligado em ms
  uint16_t gapMs;  // Pausa silenciosa após a nota em ms
};

// Sequências de Buzinas
static const ToneStep SEQ_BUZ_PRINCIPAL[] = {
  { 520, 190, 55 },
  { 660, 240, 0  }
};
static const ToneStep SEQ_BUZ_CURTA[] = {
  { 1850, 110, 0 }
};
static const ToneStep SEQ_BUZ_LONGA[] = {
  { 580, 520, 0 }
};
static const ToneStep SEQ_BUZ_EMERG[] = {
  { 950,  110, 35 },
  { 1650, 110, 35 },
  { 950,  110, 35 },
  { 1650, 110, 35 },
  { 2200, 140, 0  }
};
static const ToneStep SEQ_BUZ_DIV[] = {
  { 523, 130, 45 }, // C5
  { 392, 90,  35 }, // G4
  { 392, 90,  45 }, // G4
  { 440, 150, 55 }, // A4
  { 392, 150, 160}, // G4 (pausa)
  { 494, 130, 50 }, // B4
  { 523, 200, 0  }  // C5
};

// Sequências de Efeitos
static const ToneStep SEQ_SOM_INIT[] = {
  { 523,  80,  30 },
  { 659,  80,  30 },
  { 784,  90,  30 },
  { 1047, 160, 0  }
};
static const ToneStep SEQ_SOM_BLE_CONN[] = {
  { 880,  75,  35 },
  { 1319, 130, 0  }
};
static const ToneStep SEQ_SOM_BLE_DISC[] = {
  { 1175, 85,  40 },
  { 659,  150, 0  }
};
static const ToneStep SEQ_SOM_COMEMORACAO[] = {
  { 587,  80,  30 },
  { 784,  80,  30 },
  { 988,  80,  30 },
  { 1175, 180, 0  }
};
static const ToneStep SEQ_SOM_ERRO[] = {
  { 330, 160, 60 },
  { 247, 260, 0  }
};
static const ToneStep SEQ_SOM_SURPRESA[] = {
  { 600,  55,  20 },
  { 1200, 55,  20 },
  { 2100, 140, 0  }
};
static const ToneStep SEQ_SOM_RISADA[] = {
  { 1400, 65, 45 },
  { 1250, 65, 45 },
  { 1400, 65, 45 },
  { 1100, 65, 45 },
  { 1500, 95, 0  }
};
static const ToneStep SEQ_SOM_ARCADE[] = {
  { 988,  70,  20 },
  { 1319, 210, 0  }
};
static const ToneStep SEQ_SOM_FUTURISTA[] = {
  { 1800, 45, 20 },
  { 2400, 45, 20 },
  { 1500, 45, 20 },
  { 2800, 65, 25 },
  { 2000, 90, 0  }
};

// Melodias Originais 8-bit
static const ToneStep SEQ_MELODIA_INIT[] = {
  { 523, 100, 30 }, // C5
  { 659, 100, 30 }, // E5
  { 784, 100, 30 }, // G5
  { 659, 100, 30 }, // E5
  { 880, 140, 40 }, // A5
  { 784, 120, 40 }, // G5
  { 1047,220, 0  }  // C6
};
static const ToneStep SEQ_MELODIA_COMEMORACAO[] = {
  { 659, 95,  30 },
  { 659, 95,  30 },
  { 784, 110, 35 },
  { 659, 95,  30 },
  { 880, 130, 40 },
  { 784, 140, 50 },
  { 988, 110, 35 },
  { 1047,230, 0  }
};
static const ToneStep SEQ_MELODIA_VITORIA[] = {
  { 523, 90,  25 },
  { 523, 90,  25 },
  { 523, 90,  35 },
  { 523, 190, 45 },
  { 415, 170, 40 },
  { 466, 170, 40 },
  { 523, 120, 35 },
  { 466, 80,  25 },
  { 523, 280, 0  }
};

static ToneStep customSingleStep = { 1000, 180, 0 };

bool            buzzerActiveMode  = true;  // true = Híbrido Ativo DC + Passivo, false = Passivo Puro
bool            buzzerMuted       = false; // true = Silenciado (MUTE)
const ToneStep* currentSeq        = nullptr;
uint8_t         currentSeqLen     = 0;
uint8_t         currentSeqIdx     = 0;
bool            inStepGap         = false;
bool            buzzerPhaseWave   = false;
uint32_t        stepStartMs       = 0;

// ─── Estado BLE e Objetos Globais ─────────────────────────────────────────────
NimBLEServer*         pServer         = nullptr;
NimBLECharacteristic* pTxChar         = nullptr;
bool                  deviceConnected = false;
bool                  wasConnected    = false;
bool                  bleReady        = false;

Servo servoLeft;
Servo servoRight;
String serialBuffer;

// ─── Declarações Antecipadas ──────────────────────────────────────────────────
void loadCalibration();
void saveCalibration();
void resetCalibration();
void handleCommand(const String& raw);
void handleJsonCommand(const String& json);
void stopMotors();
void setMotors(int leftSpeed, int rightSpeed, const char* dirLabel = nullptr);
void applySpeedPercentChange(int newPercent, const char* ackReply);
void markMoveActivity();
void recordUserInteraction(bool isMovementStart);
void triggerTempReaction(RobotExpression expr, uint32_t durationMs);
void updateIdleReactions();
void buzzerStartSignal(unsigned int freq = 0);
void buzzerStopTone();
void startSoundSequence(const ToneStep* seq, uint8_t count, const char* label);
void scheduleBuzzerBuzina();
void scheduleBuzzerBipe();
void scheduleBuzzerLonga();
void scheduleBuzzerAlerta();
void scheduleBuzzerCustom(unsigned int freq, uint32_t durationMs);
void ackBuzzerTrigger(const char* okReply);
void updateBuzzer();
void sendBleStatus(const char* msg);
void sendJsonAck(const char* cmdName, bool ok, const char* errCode = nullptr);
void checkSafetyTimeout();
void initDisplay();
void updateDisplay();
void desenharCoracao(int cx, int cy, int r, uint16_t color);
void desenharOlho(int x, int y, int offsetX, int offsetY, bool isLeft);
void desenharBocaExtras();
void desenharRosto();
void processSerialInput();
uint8_t setaLevel(bool active);
void writeSetaPins(bool leftOn, bool rightOn);
const char* setaStateToString(SetaEstado state);
void desligarSetas();
void applySetaMode(SetaEstado mode);
void syncAutoSetasComMovimento(const char* dir);
void updateSetas();

// ─── Callbacks NimBLE ─────────────────────────────────────────────────────────
class McQueenServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo) override {
    deviceConnected = true;
    stopMotors(); // Garante motores parados ao conectar/reconectar
    autoSetasEnabled = false;
    desligarSetas(); // Garante setas desligadas na nova conexão
    Serial.println("[BLE] Dispositivo conectado.");
    Serial.printf("[BLE] Endereço cliente: %s\n", connInfo.getAddress().toString().c_str());
    startSoundSequence(SEQ_SOM_BLE_CONN, sizeof(SEQ_SOM_BLE_CONN) / sizeof(ToneStep), "BLE_CONN");
    if (autoReactionsEnabled) {
      triggerTempReaction(EXPR_FELIZ, 1800);
    }
  }

  void onDisconnect(NimBLEServer* pServer, NimBLEConnInfo& connInfo, int reason) override {
    deviceConnected = false;
    Serial.printf("[BLE] Dispositivo desconectado (reason: %d).\n", reason);
    stopMotors(); // Parada imediata obrigatória na desconexão
    buzzerStopTone();
    currentSeq = nullptr;
    autoSetasEnabled = false;
    desligarSetas(); // Desliga as setas imediatamente na desconexão
  }
};

class McQueenRxCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pCharacteristic, NimBLEConnInfo& connInfo) override {
    std::string raw = pCharacteristic->getValue();
    if (raw.empty()) return;

    if (raw.size() > MAX_COMMAND_LENGTH) {
      Serial.printf("[WARN] Comando muito longo (%u bytes) — rejeitado.\n",
                    (unsigned)raw.size());
      sendBleStatus("ERR:LEN");
      return;
    }

    String cmd = String(raw.c_str());
    cmd.trim();
    if (cmd.length() == 0) return;

    Serial.printf("[BLE] Comando recebido: %s\n", cmd.c_str());
    handleCommand(cmd);
  }
};

static McQueenServerCallbacks serverCallbacks;
static McQueenRxCallbacks     rxCallbacks;

// ─── Setup ────────────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  // Evita que Serial.printf bloqueie por até 2s quando nenhum monitor serial está aberto
  Serial.setTxTimeoutMs(0);
  delay(400);
  Serial.println();
  Serial.println("╔════════════════════════════════════════════════════╗");
  Serial.println("║     McQueen Robot v4.3.0 — QT Py ESP32-C3 (2.0)    ║");
  Serial.println("║  NimBLE + Servos RC + 12 Expressões OLED + Sons    ║");
  Serial.println("╚════════════════════════════════════════════════════╝");
  Serial.printf("[INIT] Firmware: %s\n", FIRMWARE_VERSION);

  randomSeed(esp_random());
  lastActivityMs = millis();
  lastAutoReactionMs = millis();

  // ── 0. Carrega calibração e preferências persistidas na NVS ──
  loadCalibration();

  // ── 1. Configura Buzzer no GPIO 2 e GPIO 1/A2 ──
  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);
  pinMode(BUZZER_ALT_PIN, OUTPUT);
  digitalWrite(BUZZER_ALT_PIN, LOW);
  Serial.printf("[INIT] Buzzer configurado em GPIO%d e GPIO%d/A2 (modo=%s, mute=%d)\n",
                BUZZER_PIN, BUZZER_ALT_PIN,
                buzzerActiveMode ? "Hibrido/Ativo" : "Passivo",
                buzzerMuted ? 1 : 0);

  // ── 1B. Configura Setas (GPIO 7 e GPIO 9) ──
  gpio_reset_pin((gpio_num_t)SETA_ESQ_PIN);
  gpio_reset_pin((gpio_num_t)SETA_DIR_PIN);
  pinMode(SETA_ESQ_PIN, OUTPUT);
  pinMode(SETA_DIR_PIN, OUTPUT);
  autoSetasEnabled = false;
  desligarSetas();
  Serial.printf("[INIT] Setas: GPIO%d (esq), GPIO%d (dir) — nível ativo: %s\n",
                SETA_ESQ_PIN, SETA_DIR_PIN,
                SETA_ATIVA_EM_NIVEL_ALTO ? "ALTO" : "BAIXO");

  // ── 2. Configura Servos de Rotação Contínua (Timer 0 LEDC) ──
#if ENABLE_SERVOS
  ESP32PWM::allocateTimer(0);
  servoLeft.setPeriodHertz(SERVO_PWM_FREQ_HZ);
  servoRight.setPeriodHertz(SERVO_PWM_FREQ_HZ);
  servoLeft.attach(SERVO_LEFT_PIN, SERVO_MIN_US, SERVO_MAX_US);
  servoRight.attach(SERVO_RIGHT_PIN, SERVO_MIN_US, SERVO_MAX_US);
  stopMotors(); // Garante parado na inicialização
  Serial.printf("[INIT] Servo esquerdo: GPIO%d (neutro: %dµs, inv: %s, trim: %d%%, freq: %dHz)\n",
                SERVO_LEFT_PIN, servoLeftStop, servoLeftInvert ? "sim" : "não", servoLeftTrim, SERVO_PWM_FREQ_HZ);
  Serial.printf("[INIT] Servo direito:  GPIO%d (neutro: %dµs, inv: %s, trim: %d%%, freq: %dHz)\n",
                SERVO_RIGHT_PIN, servoRightStop, servoRightInvert ? "sim" : "não", servoRightTrim, SERVO_PWM_FREQ_HZ);
#else
  stopMotors();
  Serial.println("[INIT] ENABLE_SERVOS=0 — servos desativados.");
#endif

  Serial.printf("[INIT] Velocidade padrão: %d%% (limites: min=%d%%, máx=%d%%)\n",
                speedPercent, minSpeedPercent, maxSpeedPercent);
  Serial.printf("[INIT] Timeout de segurança: %d ms\n", SAFETY_TIMEOUT_MS);

  // ── 3. Inicializa Display OLED (não-bloqueante se ausente) ──
  initDisplay();

  // ── 4. Inicializa NimBLE ──
  Serial.println("[BLE] Inicializando NimBLE...");
  if (!NimBLEDevice::init(BLE_DEVICE_NAME)) {
    Serial.println("[ERR] Falha ao inicializar NimBLE.");
    return;
  }

  NimBLEDevice::setPower(BLE_TX_POWER_DBM);
  NimBLEDevice::setMTU(185);

  pServer = NimBLEDevice::createServer();
  if (pServer == nullptr) {
    Serial.println("[ERR] Falha ao criar servidor BLE.");
    return;
  }
  pServer->setCallbacks(&serverCallbacks);

  NimBLEService* pService = pServer->createService(SERVICE_UUID);
  if (pService == nullptr) {
    Serial.println("[ERR] Falha ao criar serviço BLE.");
    return;
  }

  // Característica RX (App → ESP32): WRITE e WRITE_NR
  NimBLECharacteristic* pRxChar = pService->createCharacteristic(
    CHAR_RX_UUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR
  );
  if (pRxChar == nullptr) {
    Serial.println("[ERR] Falha ao criar característica RX.");
    return;
  }
  pRxChar->setCallbacks(&rxCallbacks);

  // Característica TX (ESP32 → App): NOTIFY e READ
  pTxChar = pService->createCharacteristic(
    CHAR_TX_UUID,
    NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ
  );
  if (pTxChar != nullptr) {
    pTxChar->setValue("OK:BOOT");
  }

  if (!pServer->start()) {
    Serial.println("[ERR] Falha ao iniciar servidor BLE.");
    return;
  }

  NimBLEAdvertising* pAdvertising = NimBLEDevice::getAdvertising();
  if (pAdvertising == nullptr) {
    Serial.println("[ERR] Falha ao obter objeto de advertising BLE.");
    return;
  }

  NimBLEAdvertisementData advData;
  advData.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  advData.setName(BLE_DEVICE_NAME);
  advData.addServiceUUID(SERVICE_UUID);

  NimBLEAdvertisementData scanRespData;
  scanRespData.setName(BLE_DEVICE_NAME);

  pAdvertising->setAdvertisementData(advData);
  pAdvertising->setScanResponseData(scanRespData);
  pAdvertising->enableScanResponse(true);
  pAdvertising->setAdvertisingInterval(BLE_ADV_INTERVAL);

  if (!pAdvertising->start()) {
    Serial.println("[ERR] Falha ao iniciar advertising BLE.");
    return;
  }

  bleReady = true;

  Serial.printf("[BLE] Endereço MAC: %s\n", NimBLEDevice::getAddress().toString().c_str());
  Serial.printf("[BLE] Nome: %s\n", BLE_DEVICE_NAME);
  Serial.printf("[BLE] Serviço: %s\n", SERVICE_UUID);
  Serial.printf("[BLE] RX Char: %s (WRITE | WRITE_NR)\n", CHAR_RX_UUID);
  Serial.printf("[BLE] TX Char: %s (NOTIFY | READ)\n", CHAR_TX_UUID);
  Serial.printf("[BLE] Payload anúncio: %u bytes | Ativo: %s\n",
                (unsigned)advData.getPayload().size(),
                pAdvertising->isAdvertising() ? "SIM" : "NAO");
  Serial.println("[BLE] Anunciando — aguardando conexão...");
  Serial.println();

  // Bipe curto de inicialização concluída
  scheduleBuzzerBipe();
}

// ─── Loop Principal ───────────────────────────────────────────────────────────
void loop() {
  processSerialInput();

  if (bleReady) {
    // Reinicia anúncio após desconexão
    if (!deviceConnected && wasConnected) {
      delay(150);
      NimBLEDevice::startAdvertising();
      wasConnected = false;
      Serial.println("[BLE] Aguardando nova conexão...");
    }
    if (deviceConnected && !wasConnected) {
      wasConnected = true;
    }

    // Watchdog de advertising a cada 5s quando desconectado
    static uint32_t lastAdvCheck = 0;
    if (!deviceConnected && (millis() - lastAdvCheck > 5000)) {
      lastAdvCheck = millis();
      NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
      if (adv != nullptr && !adv->isAdvertising()) {
        Serial.println("[BLE] Advertising inativo — reiniciando...");
        adv->start();
      }
    }
  }

  // Verifica timeout de segurança dos motores (adaptativo)
  checkSafetyTimeout();

  // Atualiza setas (pisca não-bloqueante)
  updateSetas();

  // Atualiza reações automáticas quando parado, sequenciador de som e OLED
  updateIdleReactions();
  updateBuzzer();
  updateDisplay();

  // Cede tempo de CPU na ESP32-C3 (single-core) para a pilha BLE e USB-CDC
  delay(10);
}

// ─── Segurança e Timeout Adaptativo ──────────────────────────────────────────────
// Timeout de segurança adaptativo (tolerante a jitter BLE/I2C e seguro <= 800 ms)
uint16_t getSafetyTimeoutMs() {
  if (speedPercent >= 95) return 600; // TURBO
  if (speedPercent >= 75) return 650; // SPORT
  if (speedPercent >= 50) return 750; // NORMAL
  return 800;                         // ECO
}

void checkSafetyTimeout() {
  uint16_t timeoutMs = getSafetyTimeoutMs();
  if (motorsRunning && (millis() - lastMoveCommandTime > timeoutMs)) {
    Serial.printf("[SAFETY] Timeout (%dms sem comando) — parando motores automaticamente.\n", timeoutMs);
    stopMotors();
    syncAutoSetasComMovimento("PARADO");
    sendBleStatus("SAFETY:TIMEOUT");
  }
}

// ─── Controle e Atualização das Setas (Pisca não-bloqueante) ──────────────────
uint8_t setaLevel(bool active) {
  return (active == (SETA_ATIVA_EM_NIVEL_ALTO != 0)) ? HIGH : LOW;
}

void writeSetaPins(bool leftOn, bool rightOn) {
  digitalWrite(SETA_ESQ_PIN, setaLevel(leftOn));
  digitalWrite(SETA_DIR_PIN, setaLevel(rightOn));
  setaLeftPinHigh = leftOn;
  setaRightPinHigh = rightOn;
}

void applyDirectLedTest(bool leftOn, bool rightOn, const char* ackReply) {
  autoSetasEnabled = false;
  currentSetaEstado = SETA_DESLIGADA;
  setaLeftActive = false;
  setaRightActive = false;
  setaLedState = false;
  writeSetaPins(leftOn, rightOn);
  Serial.printf("[LED] Teste direto | ESQ(GPIO%d)=%d DIR(GPIO%d)=%d\n",
                SETA_ESQ_PIN, leftOn ? 1 : 0, SETA_DIR_PIN, rightOn ? 1 : 0);
  sendBleStatus(ackReply);
}

const char* setaStateToString(SetaEstado state) {
  switch (state) {
    case SETA_ESQUERDA: return "ESQ";
    case SETA_DIREITA:  return "DIR";
    case SETA_ALERTA:   return "ALR";
    case SETA_AUTO:     return "AUTO";
    default:            return "OFF";
  }
}

void desligarSetas() {
  currentSetaEstado = SETA_DESLIGADA;
  setaLeftActive    = false;
  setaRightActive   = false;
  setaLedState      = false;
  writeSetaPins(false, false);
  Serial.printf("[SETA] Desligadas | GPIO%d=%d GPIO%d=%d\n",
                SETA_ESQ_PIN, (int)setaLevel(false),
                SETA_DIR_PIN, (int)setaLevel(false));
}

void applySetaMode(SetaEstado mode) {
  if (mode == SETA_DESLIGADA) {
    desligarSetas();
    return;
  }
  if (mode == SETA_AUTO) {
    currentSetaEstado = SETA_AUTO;
    setaLeftActive    = false;
    setaRightActive   = false;
    setaLedState      = false;
    writeSetaPins(false, false);
    Serial.println("[SETA] Modo AUTO habilitado.");
    syncAutoSetasComMovimento(currentDirection.c_str());
    return;
  }
  currentSetaEstado = mode;
  setaLeftActive    = (mode == SETA_ESQUERDA || mode == SETA_ALERTA);
  setaRightActive   = (mode == SETA_DIREITA  || mode == SETA_ALERTA);
  // Inicia aceso imediatamente para feedback visual instantâneo no comando
  setaLedState      = true;
  lastSetaToggleMs  = millis();
  writeSetaPins(setaLeftActive, setaRightActive);
  Serial.printf("[SETA] Modo=%s | ESQ(GPIO%d)=%d DIR(GPIO%d)=%d\n",
                setaStateToString(mode),
                SETA_ESQ_PIN, setaLeftActive ? 1 : 0,
                SETA_DIR_PIN, setaRightActive ? 1 : 0);
}

void syncAutoSetasComMovimento(const char* dir) {
  if (!autoSetasEnabled || currentSetaEstado == SETA_ALERTA) return;
  currentSetaEstado = SETA_AUTO;

  if (strcmp(dir, "ESQUERDA") == 0) {
    if (!setaLeftActive || setaRightActive) {
      setaLeftActive = true;
      setaRightActive = false;
      setaLedState = true;
      lastSetaToggleMs = millis();
      writeSetaPins(true, false);
    }
  } else if (strcmp(dir, "DIREITA") == 0) {
    if (!setaRightActive || setaLeftActive) {
      setaLeftActive = false;
      setaRightActive = true;
      setaLedState = true;
      lastSetaToggleMs = millis();
      writeSetaPins(false, true);
    }
  } else {
    if (setaLeftActive || setaRightActive || setaLedState) {
      setaLeftActive = false;
      setaRightActive = false;
      setaLedState = false;
      writeSetaPins(false, false);
    }
  }
}

void updateSetas() {
  uint32_t now = millis();

  // Se nenhuma seta ativa, nada a fazer
  if (currentSetaEstado == SETA_DESLIGADA || (!setaLeftActive && !setaRightActive)) {
    return;
  }

  // Verifica se é hora de alternar o LED (500 ms)
  if (now - lastSetaToggleMs >= SETA_INTERVALO_MS) {
    lastSetaToggleMs = now;
    setaLedState = !setaLedState;

    // Aplica o estado aos LEDs ativos (inativo permanece apagado)
    writeSetaPins(setaLeftActive && setaLedState, setaRightActive && setaLedState);
  }
}

void markMoveActivity() {
  uint32_t now = millis();
  lastMoveCommandTime = now;
  lastActivityMs = now;
  lastAutoReactionMs = now;
  isSleepyIdle = false;
}

// ─── Reações Automáticas Quando Parado (Idle Reactions) ───────────────────────
void triggerTempReaction(RobotExpression expr, uint32_t durationMs) {
  currentExpression = expr;
  inTempReaction = true;
  tempReactionStartMs = millis();
  tempReactionDurationMs = durationMs;
  piscando = false;
}

void recordUserInteraction(bool isMovementStart) {
  uint32_t now = millis();
  lastActivityMs = now;
  lastAutoReactionMs = now;
  if (isSleepyIdle) {
    isSleepyIdle = false;
    currentExpression = baseExpression;
  }
  if (!autoReactionsEnabled) return;

  if (isMovementStart) {
    // Demonstra surpresa ou animação ao iniciar uma nova ação a partir do repouso
    RobotExpression startExpr = (random(0, 2) == 0) ? EXPR_SURPRESO : EXPR_ANIMADO;
    if (allowedReactionsMask & (1 << startExpr)) {
      triggerTempReaction(startExpr, 1000);
    }
  }
}

void updateIdleReactions() {
  uint32_t now = millis();

  // Se uma reação temporária expirou, retorna à expressão base configurada
  if (inTempReaction && (now - tempReactionStartMs >= tempReactionDurationMs)) {
    inTempReaction = false;
    currentExpression = isSleepyIdle ? EXPR_SONOLENTO : baseExpression;
  }

  // NUNCA executa reações automáticas de ócio durante a movimentação
  if (motorsRunning || !autoReactionsEnabled) {
    return;
  }

  // Após muito tempo parado (35s sem atividade), faz expressão sonolenta
  if (!isSleepyIdle && (now - lastActivityMs > 35000)) {
    if (allowedReactionsMask & (1 << EXPR_SONOLENTO)) {
      isSleepyIdle = true;
      inTempReaction = false;
      currentExpression = EXPR_SONOLENTO;
      Serial.println("[IDLE] Muito tempo parado — expressão SONOLENTO.");
    }
    lastAutoReactionMs = now;
    return;
  }

  // Seleciona reação aleatória respeitando o intervalo configurável
  if (!inTempReaction && !isSleepyIdle && (now - lastAutoReactionMs >= autoReactionIntervalMs)) {
    lastAutoReactionMs = now;

    // Lista de expressões candidatas para vida própria quando parado
    static const RobotExpression candidates[] = {
      EXPR_CURIOSO,
      EXPR_PISCANDO,
      EXPR_FELIZ,
      EXPR_SURPRESO,
      EXPR_CONFUSO,
      EXPR_ANIMADO,
      EXPR_SONOLENTO
    };
    uint8_t validCount = 0;
    RobotExpression validList[7];
    for (uint8_t i = 0; i < 7; i++) {
      RobotExpression c = candidates[i];
      if ((allowedReactionsMask & (1 << c)) && c != baseExpression) {
        validList[validCount++] = c;
      }
    }

    if (validCount > 0) {
      RobotExpression chosen = validList[random(0, validCount)];
      uint32_t dur = (uint32_t)random(2000, 3100);
      triggerTempReaction(chosen, dur);
      Serial.printf("[IDLE] Reação automática: %s (%lu ms)\n",
                    expressionToString(chosen), (unsigned long)dur);
    }
  }
}

// ─── Utilitários de Parsing ───────────────────────────────────────────────────
bool parseStrictInt(const String& text, long& out) {
  String s = text;
  s.trim();
  if (s.length() == 0 || s.length() > 6) return false;

  uint8_t start = 0;
  if (s[0] == '-') {
    if (s.length() == 1) return false;
    start = 1;
  }
  for (uint8_t i = start; i < s.length(); i++) {
    if (!isDigit(s[i])) return false;
  }
  out = s.toInt();
  return true;
}

bool extractJsonString(const String& json, const char* key, String& out) {
  String pattern = String("\"") + key + "\"";
  int keyPos = json.indexOf(pattern);
  if (keyPos < 0) return false;
  int colonPos = json.indexOf(':', keyPos + pattern.length());
  if (colonPos < 0) return false;
  int firstQuote = json.indexOf('"', colonPos + 1);
  if (firstQuote < 0) return false;
  int secondQuote = json.indexOf('"', firstQuote + 1);
  if (secondQuote < 0) return false;
  out = json.substring(firstQuote + 1, secondQuote);
  return true;
}

bool extractJsonInt(const String& json, const char* key, long& out) {
  String pattern = String("\"") + key + "\"";
  int keyPos = json.indexOf(pattern);
  if (keyPos < 0) return false;
  int colonPos = json.indexOf(':', keyPos + pattern.length());
  if (colonPos < 0) return false;
  int start = colonPos + 1;
  while (start < (int)json.length() && (json[start] == ' ' || json[start] == '\t')) {
    start++;
  }
  int end = start;
  if (end < (int)json.length() && json[end] == '-') end++;
  while (end < (int)json.length() && isDigit(json[end])) {
    end++;
  }
  if (end == start) return false;
  return parseStrictInt(json.substring(start, end), out);
}

bool isMovementCommand(const String& base) {
  return base == "FRENTE" || base == "TRAS" ||
         base == "ESQUERDA" || base == "DIREITA" ||
         base == "ESQ" || base == "DIR";
}

// ─── Parser de Comandos JSON Estruturados ─────────────────────────────────────
void handleJsonCommand(const String& json) {
  String cmd;
  if (!extractJsonString(json, "cmd", cmd) && !extractJsonString(json, "c", cmd)) {
    Serial.printf("[WARN] JSON sem campo 'cmd': %s\n", json.c_str());
    sendJsonAck("UNKNOWN", false, "ERR:JSON_CMD");
    return;
  }
  cmd.trim();
  cmd.toUpperCase();

  if (cmd == "PING") {
    sendBleStatus("PONG");
    return;
  }

  if (cmd == "STOP" || cmd == "PARAR") {
    stopMotors();
    syncAutoSetasComMovimento("PARADO");
    sendBleStatus("OK:PARAR");
    return;
  }

  if (cmd == "STATUS") {
    sendJsonAck("STATUS", true);
    return;
  }

  if (cmd == "SPEED" || cmd == "VEL") {
    long val = 0;
    String profile = "";
    if (extractJsonString(json, "profile", profile) || extractJsonString(json, "p", profile)) {
      profile.trim();
      profile.toUpperCase();
      if (profile == "ECO") val = SPEED_PROFILE_PCT[0];
      else if (profile == "NORMAL") val = SPEED_PROFILE_PCT[1];
      else if (profile == "SPORT") val = SPEED_PROFILE_PCT[2];
      else if (profile == "TURBO") val = SPEED_PROFILE_PCT[3];
      else val = -1;
    } else if (!extractJsonInt(json, "value", val) && !extractJsonInt(json, "v", val)) {
      sendJsonAck("SPEED", false, "ERR:VEL");
      return;
    }
    if (val < 0 || val > MAX_SPEED_PERCENT) {
      sendJsonAck("SPEED", false, "ERR:VEL");
      return;
    }
    char buf[32];
    snprintf(buf, sizeof(buf), "OK:VEL:%ld", val);
    applySpeedPercentChange((int)val, buf);
    return;
  }

  if (cmd == "MOVE" || cmd == "DIFF") {
    long left = 0, right = 0;
    bool hasLeft = extractJsonInt(json, "left", left) || extractJsonInt(json, "l", left);
    bool hasRight = extractJsonInt(json, "right", right) || extractJsonInt(json, "r", right);

    if (hasLeft && hasRight) {
      if (left < -100 || left > 100 || right < -100 || right > 100) {
        sendJsonAck("MOVE", false, "ERR:PARAM");
        return;
      }
      String dir;
      if (!extractJsonString(json, "dir", dir)) {
        if (left == 0 && right == 0) dir = "PARADO";
        else if (left > 0 && right > 0 && abs(left - right) <= 15) dir = "FRENTE";
        else if (left < 0 && right < 0 && abs(left - right) <= 15) dir = "TRAS";
        else if (left < right) dir = "ESQUERDA";
        else dir = "DIREITA";
      }
      if (left == 0 && right == 0) {
        stopMotors();
        sendBleStatus("OK:PARAR");
      } else {
        bool wasStopped = !motorsRunning;
        setMotors((int)left, (int)right, dir.c_str());
        markMoveActivity();
        recordUserInteraction(wasStopped);
        char buf[40];
        snprintf(buf, sizeof(buf), "OK:DIFF:%d:%d", (int)left, (int)right);
        sendBleStatus(buf);
      }
      return;
    }

    String dir;
    if (extractJsonString(json, "dir", dir)) {
      long spd = speedPercent;
      if (extractJsonInt(json, "speed", spd) || extractJsonInt(json, "v", spd)) {
        if (spd < 0 || spd > MAX_SPEED_PERCENT) {
          sendJsonAck("MOVE", false, "ERR:PARAM");
          return;
        }
      }
      String subCmd = dir + ":" + String(spd);
      handleCommand(subCmd);
      return;
    }

    sendJsonAck("MOVE", false, "ERR:PARAM");
    return;
  }

  if (cmd == "EXPR" || cmd == "DISPLAY" || cmd == "OLHOS") {
    String exprStr;
    if (!extractJsonString(json, "value", exprStr) && !extractJsonString(json, "v", exprStr)) {
      sendJsonAck("EXPR", false, "ERR:EXPR");
      return;
    }
    RobotExpression newExpr;
    if (!parseExpression(exprStr, newExpr)) {
      sendJsonAck("EXPR", false, "ERR:EXPR");
      return;
    }
    baseExpression = newExpr;
    currentExpression = newExpr;
    inTempReaction = false;
    isSleepyIdle = false;
    lastActivityMs = millis();
    lastAutoReactionMs = millis();
    piscando = false;
    saveCalibration();
    Serial.printf("[OLED] Expressão alterada para: %s\n", expressionToString(currentExpression));
    char buf[32];
    snprintf(buf, sizeof(buf), "OK:EXPR:%s", expressionToString(currentExpression));
    sendBleStatus(buf);
    return;
  }

  if (cmd == "BUZZER") {
    String mode;
    if (!extractJsonString(json, "mode", mode) && !extractJsonString(json, "value", mode)) {
      mode = "BIPE";
    }
    mode.trim();
    mode.toUpperCase();
    if (mode == "BUZINA") {
      scheduleBuzzerBuzina();
      ackBuzzerTrigger("OK:BUZINA");
    } else if (mode == "CURTA" || mode == "BIPE") {
      scheduleBuzzerBipe();
      ackBuzzerTrigger(mode == "CURTA" ? "OK:BUZINA:CURTA" : "OK:BIPE");
    } else if (mode == "LONGA") {
      scheduleBuzzerLonga();
      ackBuzzerTrigger("OK:BUZINA:LONGA");
    } else if (mode == "EMERGENCIA" || mode == "ALERTA") {
      scheduleBuzzerAlerta();
      ackBuzzerTrigger(mode == "EMERGENCIA" ? "OK:BUZINA:EMERGENCIA" : "OK:ALERTA");
    } else if (mode == "DESLIGAR" || mode == "OFF" || mode == "MUTE" || mode == "PARAR") {
      buzzerStopTone();
      currentSeq = nullptr;
      sendBleStatus(mode == "DESLIGAR" ? "OK:BUZINA:DESLIGAR" : "OK:BUZZER:OFF");
    } else if (mode == "TONE") {
      long freq = 1000, ms = 150;
      extractJsonInt(json, "freq", freq);
      extractJsonInt(json, "ms", ms);
      freq = constrain(freq, 100, 10000);
      ms = constrain(ms, 20, 3000);
      scheduleBuzzerCustom((unsigned int)freq, (uint32_t)ms);
      ackBuzzerTrigger("OK:BUZZER:TONE");
    } else {
      sendJsonAck("BUZZER", false, "ERR:BUZZER");
    }
    return;
  }

  if (cmd == "SETA") {
    String mode;
    if (!extractJsonString(json, "mode", mode) && !extractJsonString(json, "value", mode)) {
      sendJsonAck("SETA", false, "ERR:SETA");
      return;
    }
    mode.trim();
    mode.toUpperCase();
    if (mode == "ESQUERDA" || mode == "ESQ") {
      applySetaMode(SETA_ESQUERDA);
      sendBleStatus("OK:SETA:ESQUERDA");
    } else if (mode == "DIREITA" || mode == "DIR") {
      applySetaMode(SETA_DIREITA);
      sendBleStatus("OK:SETA:DIREITA");
    } else if (mode == "ALERTA" || mode == "PISCA") {
      applySetaMode(SETA_ALERTA);
      sendBleStatus("OK:SETA:ALERTA");
    } else if (mode == "DESLIGAR" || mode == "OFF") {
      applySetaMode(SETA_DESLIGADA);
      sendBleStatus("OK:SETA:DESLIGAR");
    } else {
      sendJsonAck("SETA", false, "ERR:SETA");
    }
    return;
  }

  if (cmd == "CAL") {
    long lStop = 0, rStop = 0, invL = -1, invR = -1, vMin = -1, vMax = -1, tL = -999, tR = -999;
    if (extractJsonInt(json, "leftStop", lStop) && lStop >= CAL_MIN_US && lStop <= CAL_MAX_US) {
      servoLeftStop = (int)lStop;
    }
    if (extractJsonInt(json, "rightStop", rStop) && rStop >= CAL_MIN_US && rStop <= CAL_MAX_US) {
      servoRightStop = (int)rStop;
    }
    if (extractJsonInt(json, "invertLeft", invL)) {
      servoLeftInvert = (invL != 0);
    }
    if (extractJsonInt(json, "invertRight", invR)) {
      servoRightInvert = (invR != 0);
    }
    if (extractJsonInt(json, "minSpeed", vMin) && vMin >= 0 && vMin <= 95 && vMin < maxSpeedPercent) {
      minSpeedPercent = (int)vMin;
    }
    if (extractJsonInt(json, "maxSpeed", vMax) && vMax >= 5 && vMax <= MAX_SPEED_PERCENT && vMax > minSpeedPercent) {
      maxSpeedPercent = (int)vMax;
    }
    if (extractJsonInt(json, "trimLeft", tL) && tL >= -50 && tL <= 50) {
      servoLeftTrim = (int)tL;
    }
    if (extractJsonInt(json, "trimRight", tR) && tR >= -50 && tR <= 50) {
      servoRightTrim = (int)tR;
    }
    saveCalibration();
    stopMotors();
    sendJsonAck("CAL", true);
    return;
  }

  sendJsonAck(cmd.c_str(), false, "ERR:CMD");
}

// ─── Persistência de Calibração e Preferências em NVS (Preferences) ───────────
void loadCalibration() {
  if (!calPrefs.begin("mcqueen", true)) {
    Serial.println("[CAL] NVS não inicializada — usando padrões de fábrica.");
    return;
  }
  servoLeftStop          = constrain(calPrefs.getInt("lStop", 1500), CAL_MIN_US, CAL_MAX_US);
  servoRightStop         = constrain(calPrefs.getInt("rStop", 1500), CAL_MIN_US, CAL_MAX_US);
  servoLeftInvert        = calPrefs.getBool("lInv", false);
  servoRightInvert       = calPrefs.getBool("rInv", true);
  minSpeedPercent        = constrain(calPrefs.getInt("vMin", 0), 0, 95);
  maxSpeedPercent        = constrain(calPrefs.getInt("vMax", 100), 5, MAX_SPEED_PERCENT);
  if (minSpeedPercent >= maxSpeedPercent) {
    minSpeedPercent = 0;
    maxSpeedPercent = 100;
  }
  servoLeftTrim          = constrain(calPrefs.getInt("lTrim", 0), -50, 50);
  servoRightTrim         = constrain(calPrefs.getInt("rTrim", 0), -50, 50);
  buzzerActiveMode       = calPrefs.getBool("buzAct", true);
  buzzerMuted            = calPrefs.getBool("buzMute", false);
  autoReactionsEnabled   = calPrefs.getBool("autoEn", true);
  autoReactionIntervalMs = constrain(calPrefs.getUInt("autoMs", 8000), 3000u, 60000u);
  int savedBase          = constrain(calPrefs.getInt("baseEx", 0), 0, (int)EXPR_COUNT - 1);
  baseExpression         = (RobotExpression)savedBase;
  currentExpression      = baseExpression;
  calPrefs.end();
  Serial.printf("[CAL] Carregado NVS: L=%dµs R=%dµs invL=%d invR=%d vMin=%d%% vMax=%d%% trimL=%d%% trimR=%d%% auto=%d(%lums)\n",
                servoLeftStop, servoRightStop,
                servoLeftInvert ? 1 : 0, servoRightInvert ? 1 : 0,
                minSpeedPercent, maxSpeedPercent,
                servoLeftTrim, servoRightTrim,
                autoReactionsEnabled ? 1 : 0, (unsigned long)autoReactionIntervalMs);
}

void saveCalibration() {
  if (!calPrefs.begin("mcqueen", false)) return;
  calPrefs.putInt("lStop", servoLeftStop);
  calPrefs.putInt("rStop", servoRightStop);
  calPrefs.putBool("lInv", servoLeftInvert);
  calPrefs.putBool("rInv", servoRightInvert);
  calPrefs.putInt("vMin", minSpeedPercent);
  calPrefs.putInt("vMax", maxSpeedPercent);
  calPrefs.putInt("lTrim", servoLeftTrim);
  calPrefs.putInt("rTrim", servoRightTrim);
  calPrefs.putBool("buzAct", buzzerActiveMode);
  calPrefs.putBool("buzMute", buzzerMuted);
  calPrefs.putBool("autoEn", autoReactionsEnabled);
  calPrefs.putUInt("autoMs", autoReactionIntervalMs);
  calPrefs.putInt("baseEx", (int)baseExpression);
  calPrefs.end();
}

void resetCalibration() {
  servoLeftStop          = 1500;
  servoRightStop         = 1500;
  servoLeftInvert        = false;
  servoRightInvert       = true;
  minSpeedPercent        = 0;
  maxSpeedPercent        = 100;
  servoLeftTrim          = 0;
  servoRightTrim         = 0;
  buzzerActiveMode       = true;
  buzzerMuted            = false;
  autoReactionsEnabled   = true;
  autoReactionIntervalMs = 8000;
  baseExpression         = EXPR_NORMAL;
  currentExpression      = EXPR_NORMAL;
  saveCalibration();
}

// ─── Parser Principal de Comandos (JSON + Texto) ──────────────────────────────
void handleCommand(const String& raw) {
  String trimmed = raw;
  trimmed.trim();
  if (trimmed.length() == 0) return;

  // Se for mensagem JSON estruturada
  if (trimmed.startsWith("{")) {
    handleJsonCommand(trimmed);
    return;
  }

  String cmd = trimmed;
  cmd.toUpperCase();

  // ── 1. PARAR — prioridade máxima ──
  if (cmd == "PARAR" || cmd == "STOP") {
    stopMotors();
    syncAutoSetasComMovimento("PARADO");
    sendBleStatus("OK:PARAR");
    return;
  }

  // ── 2. Perfis de Velocidade (McQueen 4.0: ECO, Normal, Sport, Turbo) ──
  if (cmd == "VEL:1" || cmd == "VEL:ECO" || cmd == "SPEED_PROFILE:ECO") {
    applySpeedPercentChange(SPEED_PROFILE_PCT[SPEED_ECO], "OK:VEL:ECO");
    return;
  }
  if (cmd == "VEL:2" || cmd == "VEL:NORMAL" || cmd == "SPEED_PROFILE:NORMAL") {
    applySpeedPercentChange(SPEED_PROFILE_PCT[SPEED_NORMAL], "OK:VEL:NORMAL");
    return;
  }
  if (cmd == "VEL:3" || cmd == "VEL:SPORT" || cmd == "SPEED_PROFILE:SPORT") {
    applySpeedPercentChange(SPEED_PROFILE_PCT[SPEED_SPORT], "OK:VEL:SPORT");
    return;
  }
  if (cmd == "VEL:4" || cmd == "VEL:TURBO" || cmd == "SPEED_PROFILE:TURBO") {
    applySpeedPercentChange(SPEED_PROFILE_PCT[SPEED_TURBO], "OK:VEL:TURBO");
    return;
  }

  // ── 3. Velocidade livre: VELOCIDADE:nn ──
  if (cmd.startsWith("VELOCIDADE:")) {
    long val = 0;
    if (!parseStrictInt(cmd.substring(11), val) || val < 0 || val > MAX_SPEED_PERCENT) {
      Serial.printf("[WARN] Velocidade inválida: %s\n", cmd.c_str());
      sendBleStatus("ERR:VEL");
      return;
    }
    char buf[24];
    snprintf(buf, sizeof(buf), "OK:VEL:%ld", val);
    applySpeedPercentChange((int)val, buf);
    return;
  }

  // ── 4. Controle Diferencial Proporcional: DIFF:esq:dir (-100..100) ──
  if (cmd.startsWith("DIFF:")) {
    int secondColon = cmd.indexOf(':', 5);
    if (secondColon < 0) {
      sendBleStatus("ERR:DIFF");
      return;
    }
    long leftVal = 0, rightVal = 0;
    if (!parseStrictInt(cmd.substring(5, secondColon), leftVal) ||
        !parseStrictInt(cmd.substring(secondColon + 1), rightVal) ||
        leftVal < -100 || leftVal > 100 || rightVal < -100 || rightVal > 100) {
      Serial.printf("[WARN] Comando DIFF inválido: %s\n", cmd.c_str());
      sendBleStatus("ERR:DIFF");
      return;
    }
    if (leftVal == 0 && rightVal == 0) {
      stopMotors();
      syncAutoSetasComMovimento("PARADO");
      sendBleStatus("OK:PARAR");
      return;
    }
    const char* dirLabel = "DIFERENCIAL";
    if (leftVal > 0 && rightVal > 0 && abs(leftVal - rightVal) <= 15) dirLabel = "FRENTE";
    else if (leftVal < 0 && rightVal < 0 && abs(leftVal - rightVal) <= 15) dirLabel = "TRAS";
    else if (leftVal < rightVal) dirLabel = "ESQUERDA";
    else if (leftVal > rightVal) dirLabel = "DIREITA";

    bool wasStopped = !motorsRunning;
    activeDriveSource = DRIVE_DIFF;
    activeDiscreteDir = "";
    setMotors((int)leftVal, (int)rightVal, dirLabel);
    syncAutoSetasComMovimento(dirLabel);
    markMoveActivity();
    recordUserInteraction(wasStopped);
    char buf[36];
    snprintf(buf, sizeof(buf), "OK:DIFF:%d:%d", (int)leftVal, (int)rightVal);
    sendBleStatus(buf);
    return;
  }

  // ── 5. Controle individual de servo: MOTOR:ESQ:n / MOTOR:DIR:n ──
  if (cmd.startsWith("MOTOR:")) {
    int secondColon = cmd.indexOf(':', 6);
    if (secondColon < 0) {
      sendBleStatus("ERR:CMD");
      return;
    }
    String side = cmd.substring(6, secondColon);
    long val = 0;
    if (!parseStrictInt(cmd.substring(secondColon + 1), val) ||
        val < -100 || val > 100 || (side != "ESQ" && side != "DIR")) {
      Serial.printf("[WARN] Comando MOTOR inválido: %s\n", cmd.c_str());
      sendBleStatus("ERR:MOTOR");
      return;
    }

    activeDriveSource = DRIVE_MOTOR_SINGLE;
    activeDiscreteDir = "";
    if (side == "ESQ") {
      setMotors((int)val, 0, "MOTOR_ESQ");
      Serial.printf("[MOTOR] Individual ESQ: %d%% (DIR parado)\n", (int)val);
      sendBleStatus("OK:MOTOR:ESQ");
    } else {
      setMotors(0, (int)val, "MOTOR_DIR");
      Serial.printf("[MOTOR] Individual DIR: %d%% (ESQ parado)\n", (int)val);
      sendBleStatus("OK:MOTOR:DIR");
    }
    markMoveActivity();
    return;
  }

  // ── 6. Expressões do Display OLED: EXPR:NOME ──
  if (cmd.startsWith("EXPR:") || cmd.startsWith("EXPRESSAO:")) {
    int colonPos = cmd.indexOf(':');
    String exprName = cmd.substring(colonPos + 1);
    RobotExpression newExpr;
    if (!parseExpression(exprName, newExpr)) {
      Serial.printf("[WARN] Expressão inválida: %s\n", cmd.c_str());
      sendBleStatus("ERR:EXPR");
      return;
    }
    baseExpression = newExpr;
    currentExpression = newExpr;
    inTempReaction = false;
    isSleepyIdle = false;
    lastActivityMs = millis();
    lastAutoReactionMs = millis();
    piscando = false;
    saveCalibration();
    Serial.printf("[OLED] Expressão definida: %s\n", expressionToString(currentExpression));
    char buf[32];
    snprintf(buf, sizeof(buf), "OK:EXPR:%s", expressionToString(currentExpression));
    sendBleStatus(buf);
    return;
  }

  // ── 6B. Configuração de Reações Automáticas: AUTO:ON, AUTO:OFF, AUTO:FREQ:s ──
  if (cmd == "AUTO:ON") {
    autoReactionsEnabled = true;
    lastAutoReactionMs = millis();
    saveCalibration();
    sendBleStatus("OK:AUTO:ON");
    return;
  }
  if (cmd == "AUTO:OFF") {
    autoReactionsEnabled = false;
    inTempReaction = false;
    isSleepyIdle = false;
    currentExpression = baseExpression;
    saveCalibration();
    sendBleStatus("OK:AUTO:OFF");
    return;
  }
  if (cmd.startsWith("AUTO:FREQ:")) {
    long sec = 0;
    if (parseStrictInt(cmd.substring(10), sec) && sec >= 3 && sec <= 120) {
      autoReactionIntervalMs = (uint32_t)sec * 1000u;
      lastAutoReactionMs = millis();
      saveCalibration();
      char buf[32];
      snprintf(buf, sizeof(buf), "OK:AUTO:FREQ:%ld", sec);
      sendBleStatus(buf);
    } else {
      sendBleStatus("ERR:AUTO:FREQ");
    }
    return;
  }
  if (cmd.startsWith("AUTO:MASK:")) {
    long mask = 0;
    if (parseStrictInt(cmd.substring(10), mask) && mask >= 0 && mask <= 0xFFFF) {
      allowedReactionsMask = (uint16_t)mask;
      sendBleStatus("OK:AUTO:MASK");
    } else {
      sendBleStatus("ERR:AUTO:MASK");
    }
    return;
  }

  // ── 7. Movimento direcional com velocidade inline opcional ──
  String baseCmd = cmd;
  int moveSpeed = speedPercent;
  int colonIdx = cmd.indexOf(':');
  if (colonIdx > 0) {
    String prefix = cmd.substring(0, colonIdx);
    if (isMovementCommand(prefix)) {
      long val = 0;
      if (!parseStrictInt(cmd.substring(colonIdx + 1), val) ||
          val < 0 || val > MAX_SPEED_PERCENT) {
        Serial.printf("[WARN] Velocidade inline inválida: %s\n", cmd.c_str());
        sendBleStatus("ERR:PARAM");
        return;
      }
      moveSpeed = (int)val;
      baseCmd = prefix;
    }
  }

  if (baseCmd == "FRENTE") {
    bool wasStopped = !motorsRunning;
    activeDriveSource = DRIVE_DISCRETE_DIR;
    activeDiscreteDir = "FRENTE";
    setMotors(moveSpeed, moveSpeed, "FRENTE");
    syncAutoSetasComMovimento("FRENTE");
    markMoveActivity();
    recordUserInteraction(wasStopped);
    sendBleStatus("OK:FRENTE");
    return;
  }
  if (baseCmd == "TRAS") {
    bool wasStopped = !motorsRunning;
    activeDriveSource = DRIVE_DISCRETE_DIR;
    activeDiscreteDir = "TRAS";
    setMotors(-moveSpeed, -moveSpeed, "TRAS");
    syncAutoSetasComMovimento("TRAS");
    markMoveActivity();
    recordUserInteraction(wasStopped);
    sendBleStatus("OK:TRAS");
    return;
  }
  if (baseCmd == "ESQUERDA" || baseCmd == "ESQ") {
    bool wasStopped = !motorsRunning;
    activeDriveSource = DRIVE_DISCRETE_DIR;
    activeDiscreteDir = "ESQUERDA";
    setMotors(-moveSpeed, moveSpeed, "ESQUERDA");
    syncAutoSetasComMovimento("ESQUERDA");
    markMoveActivity();
    recordUserInteraction(wasStopped);
    sendBleStatus("OK:ESQUERDA");
    return;
  }
  if (baseCmd == "DIREITA" || baseCmd == "DIR") {
    bool wasStopped = !motorsRunning;
    activeDriveSource = DRIVE_DISCRETE_DIR;
    activeDiscreteDir = "DIREITA";
    setMotors(moveSpeed, -moveSpeed, "DIREITA");
    syncAutoSetasComMovimento("DIREITA");
    markMoveActivity();
    recordUserInteraction(wasStopped);
    sendBleStatus("OK:DIREITA");
    return;
  }

  // ── 8. Diagnóstico e Telemetria ──
  if (cmd == "PING") {
    sendBleStatus("PONG");
    return;
  }
  if (cmd == "DIAG") {
    NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
    bool advertising = (adv != nullptr) && adv->isAdvertising();
    uint16_t advLen = (adv != nullptr) ? (uint16_t)adv->getAdvertisementData().getPayload().size() : 0;
    char txBuf[80];
    snprintf(txBuf, sizeof(txBuf), "DIAG:ADV:%d|CONN:%d|READY:%d|LEN:%u|SRV:%d",
             advertising ? 1 : 0, deviceConnected ? 1 : 0, bleReady ? 1 : 0,
             (unsigned)advLen, ENABLE_SERVOS);
    Serial.printf("[DIAG] %s heap=%u addr=%s oled=%d\n",
                  txBuf, (unsigned)ESP.getFreeHeap(),
                  NimBLEDevice::getAddress().toString().c_str(),
#if ENABLE_OLED
                  oledReady ? 1 : 0
#else
                  0
#endif
    );
    sendBleStatus(txBuf);
    return;
  }
  if (cmd == "STATUS") {
    char buf[180];
    snprintf(buf, sizeof(buf),
             "V:%d|M:%d|L:%d|R:%d|I:%d%d|SL:%d|SR:%d|E:%s|B:%d|VMIN:%d|VMAX:%d|TL:%d|TR:%d|A:%d|MU:%d|S:%s",
             speedPercent,
             motorsRunning ? 1 : 0,
             servoLeftStop,
             servoRightStop,
             servoLeftInvert ? 1 : 0,
             servoRightInvert ? 1 : 0,
             currentLeftSpeed,
             currentRightSpeed,
             expressionToString(currentExpression),
             (currentSeq != nullptr) ? 1 : 0,
             minSpeedPercent,
             maxSpeedPercent,
             servoLeftTrim,
             servoRightTrim,
             autoReactionsEnabled ? 1 : 0,
             buzzerMuted ? 1 : 0,
             setaStateToString(currentSetaEstado));
    Serial.printf("[STATUS] LU=%dµs RU=%dµs SETA_PINS=(L:%d,R:%d)\n",
                  currentLeftUs, currentRightUs,
                  setaLeftPinHigh ? 1 : 0, setaRightPinHigh ? 1 : 0);
    sendBleStatus(buf);
    return;
  }
  if (cmd == "STATUS:JSON") {
    sendJsonAck("STATUS", true);
    return;
  }

  // ── 9. Central de Sons (Buzinas, Efeitos e Cadências — Buzzer Ativo DC / Passivo) ──
  if (cmd == "BUZINA" || cmd == "SOM:BUZ_PRINCIPAL") {
    scheduleBuzzerBuzina();
    ackBuzzerTrigger("OK:BUZINA");
    return;
  }
  if (cmd == "BUZINA:CURTA" || cmd == "BIPE" || cmd == "SOM:BUZ_CURTA") {
    scheduleBuzzerBipe();
    ackBuzzerTrigger(cmd == "BUZINA:CURTA" ? "OK:BUZINA:CURTA" : "OK:BIPE");
    return;
  }
  if (cmd == "BUZINA:LONGA" || cmd == "SOM:BUZ_LONGA") {
    scheduleBuzzerLonga();
    ackBuzzerTrigger(cmd == "BUZINA:LONGA" ? "OK:BUZINA:LONGA" : "OK:SOM:BUZ_LONGA");
    return;
  }
  if (cmd == "BUZINA:EMERGENCIA" || cmd == "ALERTA" || cmd == "SOM:BUZ_EMERG") {
    scheduleBuzzerAlerta();
    ackBuzzerTrigger(cmd == "BUZINA:EMERGENCIA" ? "OK:BUZINA:EMERGENCIA" : "OK:ALERTA");
    return;
  }
  if (cmd == "SOM:BUZ_DIV") {
    startSoundSequence(SEQ_BUZ_DIV, sizeof(SEQ_BUZ_DIV) / sizeof(ToneStep), "BUZ_DIV");
    if (autoReactionsEnabled && !motorsRunning) triggerTempReaction(EXPR_ANIMADO, 2000);
    sendBleStatus("OK:SOM:BUZ_DIV");
    return;
  }
  if (cmd == "SOM:INIT") {
    startSoundSequence(SEQ_SOM_INIT, sizeof(SEQ_SOM_INIT) / sizeof(ToneStep), "SOM_INIT");
    sendBleStatus("OK:SOM:INIT");
    return;
  }
  if (cmd == "SOM:BLE_CONN") {
    startSoundSequence(SEQ_SOM_BLE_CONN, sizeof(SEQ_SOM_BLE_CONN) / sizeof(ToneStep), "BLE_CONN");
    sendBleStatus("OK:SOM:BLE_CONN");
    return;
  }
  if (cmd == "SOM:BLE_DISC") {
    startSoundSequence(SEQ_SOM_BLE_DISC, sizeof(SEQ_SOM_BLE_DISC) / sizeof(ToneStep), "BLE_DISC");
    sendBleStatus("OK:SOM:BLE_DISC");
    return;
  }
  if (cmd == "SOM:COMEMORACAO") {
    startSoundSequence(SEQ_SOM_COMEMORACAO, sizeof(SEQ_SOM_COMEMORACAO) / sizeof(ToneStep), "COMEMORACAO");
    if (autoReactionsEnabled && !motorsRunning) triggerTempReaction(EXPR_FELIZ, 2200);
    sendBleStatus("OK:SOM:COMEMORACAO");
    return;
  }
  if (cmd == "SOM:ERRO") {
    startSoundSequence(SEQ_SOM_ERRO, sizeof(SEQ_SOM_ERRO) / sizeof(ToneStep), "ERRO");
    if (autoReactionsEnabled && !motorsRunning) triggerTempReaction(EXPR_TRISTE, 2000);
    sendBleStatus("OK:SOM:ERRO");
    return;
  }
  if (cmd == "SOM:SURPRESA") {
    startSoundSequence(SEQ_SOM_SURPRESA, sizeof(SEQ_SOM_SURPRESA) / sizeof(ToneStep), "SURPRESA");
    if (autoReactionsEnabled && !motorsRunning) triggerTempReaction(EXPR_SURPRESO, 1800);
    sendBleStatus("OK:SOM:SURPRESA");
    return;
  }
  if (cmd == "SOM:RISADA") {
    startSoundSequence(SEQ_SOM_RISADA, sizeof(SEQ_SOM_RISADA) / sizeof(ToneStep), "RISADA");
    if (autoReactionsEnabled && !motorsRunning) triggerTempReaction(EXPR_PISCANDO, 2200);
    sendBleStatus("OK:SOM:RISADA");
    return;
  }
  if (cmd == "SOM:ARCADE") {
    startSoundSequence(SEQ_SOM_ARCADE, sizeof(SEQ_SOM_ARCADE) / sizeof(ToneStep), "ARCADE");
    sendBleStatus("OK:SOM:ARCADE");
    return;
  }
  if (cmd == "SOM:FUTURISTA") {
    startSoundSequence(SEQ_SOM_FUTURISTA, sizeof(SEQ_SOM_FUTURISTA) / sizeof(ToneStep), "FUTURISTA");
    if (autoReactionsEnabled && !motorsRunning) triggerTempReaction(EXPR_CURIOSO, 2000);
    sendBleStatus("OK:SOM:FUTURISTA");
    return;
  }
  if (cmd == "MELODIA:INIT") {
    startSoundSequence(SEQ_MELODIA_INIT, sizeof(SEQ_MELODIA_INIT) / sizeof(ToneStep), "MELODIA_INIT");
    if (autoReactionsEnabled && !motorsRunning) triggerTempReaction(EXPR_ANIMADO, 2500);
    sendBleStatus("OK:MELODIA:INIT");
    return;
  }
  if (cmd == "MELODIA:COMEMORACAO") {
    startSoundSequence(SEQ_MELODIA_COMEMORACAO, sizeof(SEQ_MELODIA_COMEMORACAO) / sizeof(ToneStep), "MELODIA_COMEMORACAO");
    if (autoReactionsEnabled && !motorsRunning) triggerTempReaction(EXPR_FELIZ, 2800);
    sendBleStatus("OK:MELODIA:COMEMORACAO");
    return;
  }
  if (cmd == "MELODIA:VITORIA") {
    startSoundSequence(SEQ_MELODIA_VITORIA, sizeof(SEQ_MELODIA_VITORIA) / sizeof(ToneStep), "MELODIA_VITORIA");
    if (autoReactionsEnabled && !motorsRunning) triggerTempReaction(EXPR_APAIXONADO, 3000);
    sendBleStatus("OK:MELODIA:VITORIA");
    return;
  }
  if (cmd == "BUZINA:DESLIGAR" || cmd == "MUTE" || cmd == "PARAR_BUZZER") {
    buzzerStopTone();
    currentSeq = nullptr;
    sendBleStatus(cmd == "BUZINA:DESLIGAR" ? "OK:BUZINA:DESLIGAR" : "OK:BUZZER:OFF");
    return;
  }
  if (cmd == "SOM:MUTE:1") {
    buzzerMuted = true;
    buzzerStopTone();
    currentSeq = nullptr;
    saveCalibration();
    sendBleStatus("OK:SOM:MUTE:1");
    return;
  }
  if (cmd == "SOM:MUTE:0") {
    buzzerMuted = false;
    saveCalibration();
    sendBleStatus("OK:SOM:MUTE:0");
    return;
  }
  if (cmd == "BUZZER:ATIVO") {
    buzzerStopTone();
    buzzerActiveMode = true;
    saveCalibration();
    sendBleStatus("OK:BUZZER:ATIVO");
    return;
  }
  if (cmd == "BUZZER:PASSIVO") {
    buzzerStopTone();
    buzzerActiveMode = false;
    saveCalibration();
    sendBleStatus("OK:BUZZER:PASSIVO");
    return;
  }

  // ── 9B. Setas (v4.3.0) & Diagnóstico direto de LEDs ──
  if (cmd == "SETA:ESQUERDA") {
    autoSetasEnabled = false;
    applySetaMode(SETA_ESQUERDA);
    sendBleStatus("OK:SETA:ESQUERDA");
    return;
  }
  if (cmd == "SETA:DIREITA") {
    autoSetasEnabled = false;
    applySetaMode(SETA_DIREITA);
    sendBleStatus("OK:SETA:DIREITA");
    return;
  }
  if (cmd == "SETA:ALERTA") {
    autoSetasEnabled = false;
    applySetaMode(SETA_ALERTA);
    sendBleStatus("OK:SETA:ALERTA");
    return;
  }
  if (cmd == "SETA:DESLIGAR") {
    autoSetasEnabled = false;
    applySetaMode(SETA_DESLIGADA);
    sendBleStatus("OK:SETA:DESLIGAR");
    return;
  }
  if (cmd == "SETA:AUTO") {
    autoSetasEnabled = !autoSetasEnabled;
    if (autoSetasEnabled) {
      applySetaMode(SETA_AUTO);
      sendBleStatus("OK:SETA:AUTO:ON");
    } else {
      applySetaMode(SETA_DESLIGADA);
      sendBleStatus("OK:SETA:AUTO:OFF");
    }
    return;
  }
  if (cmd == "LED:ESQ:ON") {
    applyDirectLedTest(true, setaRightPinHigh, "OK:LED:ESQ:ON");
    return;
  }
  if (cmd == "LED:ESQ:OFF") {
    applyDirectLedTest(false, setaRightPinHigh, "OK:LED:ESQ:OFF");
    return;
  }
  if (cmd == "LED:DIR:ON") {
    applyDirectLedTest(setaLeftPinHigh, true, "OK:LED:DIR:ON");
    return;
  }
  if (cmd == "LED:DIR:OFF") {
    applyDirectLedTest(setaLeftPinHigh, false, "OK:LED:DIR:OFF");
    return;
  }
  if (cmd == "LED:AMBOS:ON") {
    applyDirectLedTest(true, true, "OK:LED:AMBOS:ON");
    return;
  }
  if (cmd == "LED:OFF") {
    applyDirectLedTest(false, false, "OK:LED:OFF");
    return;
  }
  if (cmd == "LED:STATUS") {
    char buf[48];
    snprintf(buf, sizeof(buf), "LED:ESQ:%d|DIR:%d|MODO:%s",
             setaLeftPinHigh ? 1 : 0,
             setaRightPinHigh ? 1 : 0,
             setaStateToString(currentSetaEstado));
    sendBleStatus(buf);
    return;
  }

  if (cmd.startsWith("TONE:")) {
    int secondColon = cmd.indexOf(':', 5);
    long freq = 1000, ms = 200;
    if (secondColon > 0) {
      if (!parseStrictInt(cmd.substring(5, secondColon), freq) ||
          !parseStrictInt(cmd.substring(secondColon + 1), ms)) {
        sendBleStatus("ERR:TONE");
        return;
      }
    } else {
      if (!parseStrictInt(cmd.substring(5), freq)) {
        sendBleStatus("ERR:TONE");
        return;
      }
    }
    freq = constrain(freq, 100, 10000);
    ms = constrain(ms, 20, 3000);
    scheduleBuzzerCustom((unsigned int)freq, (uint32_t)ms);
    sendBleStatus("OK:BUZZER:TONE");
    return;
  }

  // ── 10. Calibração dos Servos (Pulso de Parada, Sentido, Vel. Mín/Máx, Trim) ──
  if (cmd.startsWith("CAL:ESTOPL:")) {
    long val = 0;
    if (parseStrictInt(cmd.substring(11), val) &&
        val >= CAL_MIN_US && val <= CAL_MAX_US) {
      servoLeftStop = (int)val;
      saveCalibration();
      stopMotors();
      Serial.printf("[CAL] Servo esquerdo neutro: %dµs\n", servoLeftStop);
      char buf[32];
      snprintf(buf, sizeof(buf), "OK:CAL:LSTOP:%d", servoLeftStop);
      sendBleStatus(buf);
    } else {
      sendBleStatus("ERR:CAL:RANGE");
    }
    return;
  }
  if (cmd.startsWith("CAL:ESTOPR:")) {
    long val = 0;
    if (parseStrictInt(cmd.substring(11), val) &&
        val >= CAL_MIN_US && val <= CAL_MAX_US) {
      servoRightStop = (int)val;
      saveCalibration();
      stopMotors();
      Serial.printf("[CAL] Servo direito neutro: %dµs\n", servoRightStop);
      char buf[32];
      snprintf(buf, sizeof(buf), "OK:CAL:RSTOP:%d", servoRightStop);
      sendBleStatus(buf);
    } else {
      sendBleStatus("ERR:CAL:RANGE");
    }
    return;
  }
  if (cmd == "CAL:INVERTEL") {
    servoLeftInvert = !servoLeftInvert;
    saveCalibration();
    Serial.printf("[CAL] Servo esquerdo invertido: %s\n", servoLeftInvert ? "sim" : "não");
    sendBleStatus(servoLeftInvert ? "OK:CAL:LINV:ON" : "OK:CAL:LINV:OFF");
    return;
  }
  if (cmd == "CAL:INVERTED") {
    servoRightInvert = !servoRightInvert;
    saveCalibration();
    Serial.printf("[CAL] Servo direito invertido: %s\n", servoRightInvert ? "sim" : "não");
    sendBleStatus(servoRightInvert ? "OK:CAL:RINV:ON" : "OK:CAL:RINV:OFF");
    return;
  }
  if (cmd.startsWith("CAL:VMIN:")) {
    long val = 0;
    if (parseStrictInt(cmd.substring(9), val) &&
        val >= 0 && val <= 95 && val < maxSpeedPercent) {
      minSpeedPercent = (int)val;
      saveCalibration();
      Serial.printf("[CAL] Velocidade mínima: %d%%\n", minSpeedPercent);
      char buf[32];
      snprintf(buf, sizeof(buf), "OK:CAL:VMIN:%d", minSpeedPercent);
      sendBleStatus(buf);
    } else {
      sendBleStatus("ERR:CAL:RANGE");
    }
    return;
  }
  if (cmd.startsWith("CAL:VMAX:")) {
    long val = 0;
    if (parseStrictInt(cmd.substring(9), val) &&
        val >= 5 && val <= MAX_SPEED_PERCENT && val > minSpeedPercent) {
      maxSpeedPercent = (int)val;
      saveCalibration();
      Serial.printf("[CAL] Velocidade máxima: %d%%\n", maxSpeedPercent);
      char buf[32];
      snprintf(buf, sizeof(buf), "OK:CAL:VMAX:%d", maxSpeedPercent);
      sendBleStatus(buf);
    } else {
      sendBleStatus("ERR:CAL:RANGE");
    }
    return;
  }
  if (cmd.startsWith("CAL:TRIML:")) {
    long val = 0;
    if (parseStrictInt(cmd.substring(10), val) && val >= -50 && val <= 50) {
      servoLeftTrim = (int)val;
      saveCalibration();
      char buf[32];
      snprintf(buf, sizeof(buf), "OK:CAL:TRIML:%d", servoLeftTrim);
      sendBleStatus(buf);
    } else {
      sendBleStatus("ERR:CAL:RANGE");
    }
    return;
  }
  if (cmd.startsWith("CAL:TRIMR:")) {
    long val = 0;
    if (parseStrictInt(cmd.substring(10), val) && val >= -50 && val <= 50) {
      servoRightTrim = (int)val;
      saveCalibration();
      char buf[32];
      snprintf(buf, sizeof(buf), "OK:CAL:TRIMR:%d", servoRightTrim);
      sendBleStatus(buf);
    } else {
      sendBleStatus("ERR:CAL:RANGE");
    }
    return;
  }
  if (cmd == "CAL:RESET") {
    resetCalibration();
    stopMotors();
    Serial.println("[CAL] Calibração restaurada para os padrões de fábrica.");
    sendBleStatus("OK:CAL:RESET");
    return;
  }

  // ── Comando desconhecido ──
  Serial.printf("[WARN] Comando desconhecido: %s\n", cmd.c_str());
  sendBleStatus("ERR:CMD");
}

// ─── Controle dos Servos de Rotação Contínua ──────────────────────────────────
int applyCalibratedSpeedLimits(int requestedSpeed, int sideTrimPercent) {
  if (requestedSpeed == 0) return 0;
  int sign = (requestedSpeed < 0) ? -1 : 1;
  int mag  = constrain(abs(requestedSpeed), 1, MAX_SPEED_PERCENT);
  int effectiveMin = max(1, minSpeedPercent);
  int effectiveMax = constrain(maxSpeedPercent, effectiveMin, MAX_SPEED_PERCENT);
  int scaledMag = map(mag, 1, 100, effectiveMin, effectiveMax);
  // Aplica compensação de equilíbrio entre os lados (trim -50..+50%)
  scaledMag = (scaledMag * (100 + sideTrimPercent)) / 100;
  scaledMag = constrain(scaledMag, 1, MAX_SPEED_PERCENT);
  return sign * scaledMag;
}

void setMotors(int leftSpeed, int rightSpeed, const char* dirLabel) {
  int leftDir  = servoLeftInvert  ? -1 : 1;
  int rightDir = servoRightInvert ? -1 : 1;

  leftSpeed  = applyCalibratedSpeedLimits(leftSpeed, servoLeftTrim);
  rightSpeed = applyCalibratedSpeedLimits(rightSpeed, servoRightTrim);

  int leftDelta  = map(leftSpeed  * leftDir,  -100, 100, -SERVO_RANGE_US, SERVO_RANGE_US);
  int rightDelta = map(rightSpeed * rightDir, -100, 100, -SERVO_RANGE_US, SERVO_RANGE_US);

  int leftUs  = (leftSpeed == 0)  ? servoLeftStop  : constrain(servoLeftStop  + leftDelta,  SERVO_MIN_US, SERVO_MAX_US);
  int rightUs = (rightSpeed == 0) ? servoRightStop : constrain(servoRightStop + rightDelta, SERVO_MIN_US, SERVO_MAX_US);

#if ENABLE_SERVOS
  servoLeft.writeMicroseconds(leftUs);
  servoRight.writeMicroseconds(rightUs);
#endif

  currentLeftSpeed  = leftSpeed;
  currentRightSpeed = rightSpeed;
  currentLeftUs     = leftUs;
  currentRightUs    = rightUs;
  motorsRunning     = (leftSpeed != 0 || rightSpeed != 0);
  if (dirLabel != nullptr) {
    currentDirection = String(dirLabel);
  } else if (!motorsRunning) {
    currentDirection = "PARADO";
  }

  Serial.printf("[MOTOR] Dir:%s | L(GPIO%d):%dµs(%d%%) | R(GPIO%d):%dµs(%d%%)\n",
                currentDirection.c_str(),
                SERVO_LEFT_PIN, leftUs, leftSpeed,
                SERVO_RIGHT_PIN, rightUs, rightSpeed);
}

void stopMotors() {
#if ENABLE_SERVOS
  servoLeft.writeMicroseconds(servoLeftStop);
  servoRight.writeMicroseconds(servoRightStop);
#endif
  currentLeftSpeed  = 0;
  currentRightSpeed = 0;
  currentLeftUs     = servoLeftStop;
  currentRightUs    = servoRightStop;
  motorsRunning     = false;
  activeDriveSource = DRIVE_NONE;
  activeDiscreteDir = "";
  currentDirection  = "PARADO";
  lastActivityMs    = millis();
  Serial.printf("[MOTOR] Parado (neutro L:%dµs R:%dµs).\n", servoLeftStop, servoRightStop);
}

void applySpeedPercentChange(int newPercent, const char* ackReply) {
  speedPercent = constrain(newPercent, 0, MAX_SPEED_PERCENT);
  Serial.printf("[VEL] Velocidade ativa: %d%%\n", speedPercent);

  // Atualiza imediatamente motores em movimento discreto sem enviar PARAR
  if (motorsRunning) {
    lastMoveCommandTime = millis();
    if (activeDriveSource == DRIVE_DISCRETE_DIR && activeDiscreteDir.length() > 0) {
      if (activeDiscreteDir == "FRENTE") {
        setMotors(speedPercent, speedPercent, "FRENTE");
      } else if (activeDiscreteDir == "TRAS") {
        setMotors(-speedPercent, -speedPercent, "TRAS");
      } else if (activeDiscreteDir == "ESQUERDA") {
        setMotors(-speedPercent, speedPercent, "ESQUERDA");
      } else if (activeDiscreteDir == "DIREITA") {
        setMotors(speedPercent, -speedPercent, "DIREITA");
      }
    }
  }

  sendBleStatus(ackReply);
}

// ─── Sequenciador da Central de Sons (GPIO 2 + GPIO 1/A2 via esp_timer) ───────
static esp_timer_handle_t buzzerHwTimer   = nullptr;
static volatile bool      buzzerPinToggle = false;

static void IRAM_ATTR onBuzzerTimerTick(void* /*arg*/) {
  buzzerPinToggle = !buzzerPinToggle;
  digitalWrite(BUZZER_PIN, buzzerPinToggle ? HIGH : LOW);
  digitalWrite(BUZZER_ALT_PIN, buzzerPinToggle ? HIGH : LOW);
}

static void ensureBuzzerTimerCreated() {
  if (buzzerHwTimer != nullptr) return;
  esp_timer_create_args_t args = {};
  args.callback = &onBuzzerTimerTick;
  args.name = "mcqueen_buz";
  esp_timer_create(&args, &buzzerHwTimer);
}

static void buzzerStartDC() {
  ensureBuzzerTimerCreated();
  if (buzzerHwTimer != nullptr) {
    esp_timer_stop(buzzerHwTimer);
  }
  pinMode(BUZZER_PIN, OUTPUT);
  pinMode(BUZZER_ALT_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, HIGH);
  digitalWrite(BUZZER_ALT_PIN, HIGH);
}

static void buzzerStartWave(unsigned int freq) {
  ensureBuzzerTimerCreated();
  if (buzzerHwTimer != nullptr) {
    esp_timer_stop(buzzerHwTimer);
  }
  pinMode(BUZZER_PIN, OUTPUT);
  pinMode(BUZZER_ALT_PIN, OUTPUT);
  unsigned int safeFreq = constrain(freq > 0 ? freq : 1850u, 150u, 8000u);
  uint64_t halfPeriodUs = 500000ULL / safeFreq;
  if (halfPeriodUs < 60) halfPeriodUs = 60;
  buzzerPinToggle = false;
  if (buzzerHwTimer != nullptr) {
    esp_timer_start_periodic(buzzerHwTimer, halfPeriodUs);
  }
}

void buzzerStartSignal(unsigned int freq) {
  if (freq == 0) {
    buzzerStartDC();
  } else {
    buzzerStartWave(freq);
  }
}

void buzzerStopTone() {
  if (buzzerHwTimer != nullptr) {
    esp_timer_stop(buzzerHwTimer);
  }
  pinMode(BUZZER_PIN, OUTPUT);
  pinMode(BUZZER_ALT_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);
  digitalWrite(BUZZER_ALT_PIN, LOW);
  buzzerPhaseWave = false;
}

static void beginCurrentStepTone() {
  if (currentSeq == nullptr || currentSeqIdx >= currentSeqLen) return;
  const ToneStep& step = currentSeq[currentSeqIdx];
  inStepGap = false;
  stepStartMs = millis();
  if (buzzerActiveMode) {
    // Buzzer Ativo 5V: pulso DC HIGH limpo e contínuo durante todo o passo
    // (evita alternância em onda quadrada que enfraquece/corta osciladores internos).
    buzzerPhaseWave = false;
    buzzerStartDC();
  } else {
    // Modo Passivo Puro: onda quadrada na frequência exata da nota
    buzzerPhaseWave = true;
    buzzerStartWave(step.freq);
  }
}

void startSoundSequence(const ToneStep* seq, uint8_t count, const char* label) {
  buzzerStopTone();
  if (buzzerMuted || seq == nullptr || count == 0) {
    currentSeq = nullptr;
    Serial.printf("[BUZZER] Som '%s' ignorado (mute=%d).\n", label, buzzerMuted ? 1 : 0);
    return;
  }
  currentSeq = seq;
  currentSeqLen = count;
  currentSeqIdx = 0;
  beginCurrentStepTone();
  Serial.printf("[BUZZER] Sequência '%s' iniciada (%u notas).\n", label, (unsigned)count);
}

void ackBuzzerTrigger(const char* okReply) {
  sendBleStatus(buzzerMuted ? "OK:BUZZER:MUTED" : okReply);
}

void scheduleBuzzerBuzina() {
  startSoundSequence(SEQ_BUZ_PRINCIPAL, sizeof(SEQ_BUZ_PRINCIPAL) / sizeof(ToneStep), "BUZINA");
}

void scheduleBuzzerBipe() {
  startSoundSequence(SEQ_BUZ_CURTA, sizeof(SEQ_BUZ_CURTA) / sizeof(ToneStep), "BIPE");
}

void scheduleBuzzerLonga() {
  startSoundSequence(SEQ_BUZ_LONGA, sizeof(SEQ_BUZ_LONGA) / sizeof(ToneStep), "BUZ_LONGA");
}

void scheduleBuzzerAlerta() {
  startSoundSequence(SEQ_BUZ_EMERG, sizeof(SEQ_BUZ_EMERG) / sizeof(ToneStep), "ALERTA");
}

void scheduleBuzzerCustom(unsigned int freq, uint32_t durationMs) {
  customSingleStep.freq = (uint16_t)constrain(freq, 150u, 8000u);
  customSingleStep.onMs = (uint16_t)constrain(durationMs, 20u, 3000u);
  customSingleStep.gapMs = 0;
  startSoundSequence(&customSingleStep, 1, "TONE");
}

void updateBuzzer() {
  if (currentSeq == nullptr) return;

  uint32_t now = millis();
  uint32_t elapsed = now - stepStartMs;
  const ToneStep& step = currentSeq[currentSeqIdx];

  if (!inStepGap) {
    if (elapsed >= step.onMs) {
      buzzerStopTone();
      if (step.gapMs > 0 && (currentSeqIdx + 1 < currentSeqLen)) {
        inStepGap = true;
        stepStartMs = now;
      } else {
        currentSeqIdx++;
        if (currentSeqIdx >= currentSeqLen) {
          currentSeq = nullptr;
        } else {
          beginCurrentStepTone();
        }
      }
    }
  } else {
    if (elapsed >= step.gapMs) {
      currentSeqIdx++;
      if (currentSeqIdx >= currentSeqLen) {
        buzzerStopTone();
        currentSeq = nullptr;
      } else {
        beginCurrentStepTone();
      }
    }
  }
}

// ─── Display OLED 128x64: 12 Expressões Animadas + Indicadores HUD ────────────
void initDisplay() {
#if ENABLE_OLED
  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  Wire.setTimeOut(40);
  delay(35);

  Wire.beginTransmission(OLED_I2C_ADDRESS);
  uint8_t i2cErr = Wire.endTransmission();
  if (i2cErr != 0) {
    Serial.printf("[OLED] Display não respondeu em 0x%02X (SDA=GPIO%d, SCL=GPIO%d, err=%u) — continuando sem bloquear.\n",
                  OLED_I2C_ADDRESS, I2C_SDA_PIN, I2C_SCL_PIN, i2cErr);
    oledReady = false;
    return;
  }

  if (!display.begin(SSD1306_SWITCHCAPVCC, OLED_I2C_ADDRESS)) {
    Serial.printf("[OLED] Falha em display.begin(0x%02X) — continuando sem bloquear.\n",
                  OLED_I2C_ADDRESS);
    oledReady = false;
    return;
  }

  oledReady = true;
  display.clearDisplay();
  display.display();
  desenharRosto();
  Serial.printf("[OLED] Display inicializado em 0x%02X (SDA=GPIO%d, SCL=GPIO%d) — 12 expressões ativas.\n",
                OLED_I2C_ADDRESS, I2C_SDA_PIN, I2C_SCL_PIN);
#else
  Serial.println("[OLED] Desativado em tempo de compilação.");
#endif
}

void desenharCoracao(int cx, int cy, int r, uint16_t color) {
#if ENABLE_OLED
  int lobeOffset = (r * 3) / 5;
  int lobeRadius = (r * 3) / 5;
  display.fillCircle(cx - lobeOffset, cy - lobeOffset / 2, lobeRadius, color);
  display.fillCircle(cx + lobeOffset, cy - lobeOffset / 2, lobeRadius, color);
  display.fillTriangle(
    cx - r - 1, cy - 1,
    cx + r + 1, cy - 1,
    cx, cy + r + 2,
    color
  );
#endif
}

void desenharOlho(int x, int y, int offsetX, int offsetY, bool isLeft) {
#if ENABLE_OLED
  if (piscando && currentExpression != EXPR_PISCANDO) {
    display.drawLine(x - 15, y, x + 15, y, SSD1306_WHITE);
    display.drawLine(x - 12, y + 2, x + 12, y + 2, SSD1306_WHITE);
    return;
  }

  switch (currentExpression) {
    case EXPR_NORMAL: {
      display.fillRoundRect(x - olhoLargura / 2, y - olhoAltura / 2, olhoLargura, olhoAltura, 12, SSD1306_WHITE);
      display.fillCircle(x + offsetX, y + offsetY, 9, SSD1306_BLACK);
      display.fillCircle(x + offsetX - 3, y + offsetY - 3, 3, SSD1306_WHITE);
      break;
    }

    case EXPR_FELIZ: {
      int bounce = ((millis() / 350) % 2 == 0) ? -1 : 1;
      display.fillRoundRect(x - olhoLargura / 2, y - olhoAltura / 2 + bounce, olhoLargura, olhoAltura, 12, SSD1306_WHITE);
      display.fillCircle(x + offsetX, y - 3 + bounce, 8, SSD1306_BLACK);
      display.fillCircle(x + offsetX - 3, y - 6 + bounce, 3, SSD1306_WHITE);
      // Corte inferior curvo formando o sorriso dos olhos
      display.fillCircle(x, y + 19 + bounce, 19, SSD1306_BLACK);
      break;
    }

    case EXPR_BRAVO: {
      // Baseado no desenharRostoBravo original + pupilas intensas e sobrancelhas franzidas
      display.fillRoundRect(x - olhoLargura / 2, y - olhoAltura / 2, olhoLargura, olhoAltura, 10, SSD1306_WHITE);
      display.fillCircle(x + (offsetX / 2), y + 2, 8, SSD1306_BLACK);
      display.fillCircle(x + (offsetX / 2) - 2, y - 1, 2, SSD1306_WHITE);
      // Corte diagonal superior (sobrancelha brava inclinada para o centro)
      if (isLeft) {
        display.fillTriangle(
          x - olhoLargura / 2 - 2, y - olhoAltura / 2 - 2,
          x + olhoLargura / 2 + 2, y - olhoAltura / 2 - 2,
          x + olhoLargura / 2 + 2, y - 2,
          SSD1306_BLACK
        );
        display.drawLine(x - 15, y - 19, x + 15, y - 5, SSD1306_WHITE);
        display.drawLine(x - 15, y - 18, x + 15, y - 4, SSD1306_WHITE);
      } else {
        display.fillTriangle(
          x - olhoLargura / 2 - 2, y - olhoAltura / 2 - 2,
          x + olhoLargura / 2 + 2, y - olhoAltura / 2 - 2,
          x - olhoLargura / 2 - 2, y - 2,
          SSD1306_BLACK
        );
        display.drawLine(x - 15, y - 5, x + 15, y - 19, SSD1306_WHITE);
        display.drawLine(x - 15, y - 4, x + 15, y - 18, SSD1306_WHITE);
      }
      break;
    }

    case EXPR_TRISTE: {
      display.fillRoundRect(x - olhoLargura / 2, y - olhoAltura / 2, olhoLargura, olhoAltura, 12, SSD1306_WHITE);
      display.fillCircle(x + (offsetX / 2), y + 6, 9, SSD1306_BLACK);
      display.fillCircle(x + (offsetX / 2) - 3, y + 3, 3, SSD1306_WHITE);
      if (isLeft) {
        display.fillTriangle(
          x - olhoLargura / 2 - 2, y - olhoAltura / 2 - 2,
          x + olhoLargura / 2 + 2, y - olhoAltura / 2 - 2,
          x - olhoLargura / 2 - 2, y,
          SSD1306_BLACK
        );
      } else {
        display.fillTriangle(
          x - olhoLargura / 2 - 2, y - olhoAltura / 2 - 2,
          x + olhoLargura / 2 + 2, y - olhoAltura / 2 - 2,
          x + olhoLargura / 2 + 2, y,
          SSD1306_BLACK
        );
      }
      break;
    }

    case EXPR_SURPRESO: {
      int w = 36;
      int h = 44;
      display.fillRoundRect(x - w / 2, y - h / 2, w, h, 16, SSD1306_WHITE);
      display.fillCircle(x + (offsetX / 2), y + (offsetY / 2), 6, SSD1306_BLACK);
      display.fillCircle(x + (offsetX / 2) - 2, y + (offsetY / 2) - 2, 2, SSD1306_WHITE);
      // Sobrancelha erguida no topo
      display.drawLine(x - 12, y - 24, x + 12, y - 24, SSD1306_WHITE);
      break;
    }

    case EXPR_CURIOSO: {
      int h = isLeft ? 26 : 44;
      int yCenter = isLeft ? (y + 3) : (y - 1);
      display.fillRoundRect(x - olhoLargura / 2, yCenter - h / 2, olhoLargura, h, 10, SSD1306_WHITE);
      int px = (offsetX == 0) ? 4 : offsetX;
      display.fillCircle(x + px, yCenter, 8, SSD1306_BLACK);
      display.fillCircle(x + px - 3, yCenter - 3, 3, SSD1306_WHITE);
      if (!isLeft) {
        display.drawLine(x - 13, y - 25, x + 13, y - 22, SSD1306_WHITE);
      }
      break;
    }

    case EXPR_SONOLENTO: {
      int breath = ((millis() / 900) % 2 == 0) ? 0 : 2;
      display.fillRoundRect(x - olhoLargura / 2, y - olhoAltura / 2, olhoLargura, olhoAltura, 12, SSD1306_WHITE);
      display.fillCircle(x + (offsetX / 3), y + 6, 8, SSD1306_BLACK);
      // Pálpebra superior pesada
      display.fillRect(x - olhoLargura / 2 - 1, y - olhoAltura / 2 - 1, olhoLargura + 2, 21 + breath, SSD1306_BLACK);
      display.drawLine(x - olhoLargura / 2, y + 1 + breath, x + olhoLargura / 2, y + 1 + breath, SSD1306_WHITE);
      break;
    }

    case EXPR_ANIMADO: {
      int pulse = ((millis() / 160) % 2 == 0) ? 1 : -1;
      int w = 34 + pulse;
      int h = 42 + pulse;
      display.fillRoundRect(x - w / 2, y - h / 2, w, h, 13, SSD1306_WHITE);
      display.fillCircle(x + offsetX, y + offsetY, 9, SSD1306_BLACK);
      // Brilho duplo cintilante nos olhos
      display.fillCircle(x + offsetX - 3, y + offsetY - 3, 3, SSD1306_WHITE);
      display.fillCircle(x + offsetX + 3, y + offsetY + 3, 2, SSD1306_WHITE);
      display.fillCircle(x, y + 23, 14, SSD1306_BLACK);
      break;
    }

    case EXPR_CONFUSO: {
      int h = isLeft ? 40 : 28;
      int yOff = isLeft ? -3 : 4;
      display.fillRoundRect(x - olhoLargura / 2, y - h / 2 + yOff, olhoLargura, h, 10, SSD1306_WHITE);
      int pDir = isLeft ? -3 : 4;
      display.fillCircle(x + pDir, y + yOff, 7, SSD1306_BLACK);
      display.fillCircle(x + pDir - 2, y + yOff - 2, 2, SSD1306_WHITE);
      if (isLeft) {
        display.drawLine(x - 14, y - 24, x + 14, y - 20, SSD1306_WHITE);
      } else {
        display.drawLine(x - 14, y - 14, x + 14, y - 18, SSD1306_WHITE);
      }
      break;
    }

    case EXPR_ASSUSTADO: {
      int jitterX = ((millis() / 60) % 2 == 0) ? -1 : 1;
      int jitterY = ((millis() / 90) % 2 == 0) ? -1 : 1;
      display.fillRoundRect(x - 15 + jitterX, y - 20 + jitterY, 30, 40, 12, SSD1306_WHITE);
      // Pupila bem pequena e trêmula
      display.fillCircle(x + jitterX * 2, y + jitterY, 4, SSD1306_BLACK);
      // Sobrancelhas arqueadas de susto
      if (isLeft) {
        display.drawLine(x - 14, y - 18, x + 12, y - 24, SSD1306_WHITE);
      } else {
        display.drawLine(x - 12, y - 24, x + 14, y - 18, SSD1306_WHITE);
      }
      break;
    }

    case EXPR_APAIXONADO: {
      int beat = ((millis() / 250) % 2 == 0) ? 14 : 16;
      desenharCoracao(x, y - 1, beat, SSD1306_WHITE);
      break;
    }

    case EXPR_PISCANDO: {
      bool winkRight = ((millis() / 1800) % 2 == 0);
      bool thisEyeWinks = winkRight ? !isLeft : isLeft;
      if (thisEyeWinks) {
        // Olho fechado em arco alegre (> ou <)
        if (isLeft) {
          display.drawLine(x - 12, y - 6, x + 10, y, SSD1306_WHITE);
          display.drawLine(x - 12, y + 6, x + 10, y, SSD1306_WHITE);
          display.drawLine(x - 12, y - 5, x + 10, y + 1, SSD1306_WHITE);
        } else {
          display.drawLine(x + 12, y - 6, x - 10, y, SSD1306_WHITE);
          display.drawLine(x + 12, y + 6, x - 10, y, SSD1306_WHITE);
          display.drawLine(x + 12, y - 5, x - 10, y + 1, SSD1306_WHITE);
        }
      } else {
        display.fillRoundRect(x - olhoLargura / 2, y - olhoAltura / 2, olhoLargura, olhoAltura, 12, SSD1306_WHITE);
        display.fillCircle(x + offsetX, y, 8, SSD1306_BLACK);
        display.fillCircle(x + offsetX - 3, y - 3, 3, SSD1306_WHITE);
      }
      break;
    }

    default:
      break;
  }
#endif
}

void desenharBocaExtras() {
#if ENABLE_OLED
  unsigned long t = millis();
  switch (currentExpression) {
    case EXPR_FELIZ:
    case EXPR_ANIMADO:
    case EXPR_APAIXONADO: {
      // Sorriso central na parte inferior
      display.drawLine(54, 58, 60, 62, SSD1306_WHITE);
      display.drawLine(60, 62, 68, 62, SSD1306_WHITE);
      display.drawLine(68, 62, 74, 58, SSD1306_WHITE);
      break;
    }
    case EXPR_BRAVO: {
      // Boca brava angular (preservada do sketch_sep15a.ino)
      display.drawLine(48, 60, 58, 55, SSD1306_WHITE);
      display.drawLine(58, 55, 70, 55, SSD1306_WHITE);
      display.drawLine(70, 55, 80, 60, SSD1306_WHITE);
      break;
    }
    case EXPR_TRISTE: {
      // Boca curvada para baixo + lágrima animada
      display.drawLine(54, 61, 60, 57, SSD1306_WHITE);
      display.drawLine(60, 57, 68, 57, SSD1306_WHITE);
      display.drawLine(68, 57, 74, 61, SSD1306_WHITE);
      int tearY = 46 + (int)((t / 120) % 14);
      display.fillCircle(olhoR_X + 12, tearY, 2, SSD1306_WHITE);
      break;
    }
    case EXPR_SURPRESO: {
      // Boca em "O"
      display.drawCircle(64, 58, 4, SSD1306_WHITE);
      break;
    }
    case EXPR_SONOLENTO: {
      // "Zzz" flutuante no canto direito
      display.setTextSize(1);
      display.setTextColor(SSD1306_WHITE);
      int phase = (t / 500) % 3;
      if (phase >= 0) {
        display.setCursor(110, 26);
        display.print("z");
      }
      if (phase >= 1) {
        display.setCursor(116, 18);
        display.print("Z");
      }
      if (phase >= 2) {
        display.setCursor(121, 10);
        display.print("Z");
      }
      break;
    }
    case EXPR_CONFUSO: {
      // Boca ondulada torta + "?"
      display.drawLine(52, 59, 60, 56, SSD1306_WHITE);
      display.drawLine(60, 56, 67, 60, SSD1306_WHITE);
      display.drawLine(67, 60, 75, 57, SSD1306_WHITE);
      display.setTextSize(1);
      display.setCursor(62, 10);
      display.print("?");
      break;
    }
    case EXPR_ASSUSTADO: {
      // Boca aberta trêmula em ziguezague
      display.drawRoundRect(56, 55, 16, 7, 2, SSD1306_WHITE);
      break;
    }
    case EXPR_PISCANDO: {
      // Sorriso de canto
      display.drawLine(58, 59, 68, 59, SSD1306_WHITE);
      display.drawLine(68, 59, 75, 55, SSD1306_WHITE);
      break;
    }
    default:
      break;
  }
#endif
}

void desenharIndicadoresHud() {
#if ENABLE_OLED
  display.setTextSize(1);
  display.setTextColor(SSD1306_WHITE);

  // Canto superior esquerdo: estado da conexão BLE
  display.setCursor(2, 0);
  if (deviceConnected) {
    display.print("BLE:OK");
  } else {
    bool blinkDot = ((millis() / 600) % 2) == 0;
    display.print(blinkDot ? "BLE:." : "BLE: ");
  }

  // Canto superior direito: direção abreviada + velocidade
  const char* dirShort = "PAR";
  if (currentDirection == "FRENTE")        dirShort = "FRT";
  else if (currentDirection == "TRAS")     dirShort = "TRS";
  else if (currentDirection == "ESQUERDA") dirShort = "ESQ";
  else if (currentDirection == "DIREITA")  dirShort = "DIR";
  else if (motorsRunning)                  dirShort = "MOV";

  char hudRight[16];
  snprintf(hudRight, sizeof(hudRight), "%s %d%%", dirShort, speedPercent);
  int16_t xPos = SCREEN_WIDTH - (int16_t)(strlen(hudRight) * 6) - 2;
  if (xPos < 46) xPos = 46;
  display.setCursor(xPos, 0);
  display.print(hudRight);
#endif
}

void desenharRosto() {
#if ENABLE_OLED
  if (!oledReady) return;
  display.clearDisplay();
  desenharIndicadoresHud();
  desenharOlho(olhoL_X, olhoY, pupilaOffsetX, pupilaOffsetY, true);
  desenharOlho(olhoR_X, olhoY, pupilaOffsetX, pupilaOffsetY, false);
  desenharBocaExtras();
  display.display();
#endif
}

void updateDisplay() {
#if ENABLE_OLED
  if (!oledReady) return;

  unsigned long agora = millis();
  if (agora - ultimoFrameOled < 40) return; // Atualiza a ~25 FPS sem bloquear o loop
  ultimoFrameOled = agora;

  if (motorsRunning) {
    if (currentDirection == "ESQUERDA") {
      pupilaOffsetX = -6;
      pupilaOffsetY = 0;
    } else if (currentDirection == "DIREITA") {
      pupilaOffsetX = 6;
      pupilaOffsetY = 0;
    } else if (currentDirection == "FRENTE") {
      pupilaOffsetX = 0;
      pupilaOffsetY = -3;
    } else if (currentDirection == "TRAS") {
      pupilaOffsetX = 0;
      pupilaOffsetY = 4;
    } else {
      pupilaOffsetX = 0;
      pupilaOffsetY = 0;
    }
  } else {
    int movimento = (agora / 1400) % 5;
    switch (movimento) {
      case 0:
        pupilaOffsetX = 0;
        pupilaOffsetY = 0;
        break;
      case 1:
        pupilaOffsetX = 5;
        pupilaOffsetY = 0;
        break;
      case 2:
        pupilaOffsetX = -5;
        pupilaOffsetY = 0;
        break;
      case 3:
        pupilaOffsetX = 0;
        pupilaOffsetY = -4;
        break;
      case 4:
        pupilaOffsetX = 0;
        pupilaOffsetY = 2;
        break;
    }
  }

  // Piscar automaticamente (intervalo 3400ms, duração 170ms ou 350ms se sonolento)
  unsigned long blinkDuration = (currentExpression == EXPR_SONOLENTO) ? 350 : 170;
  if (!piscando && agora - ultimaPiscada > 3400) {
    piscando = true;
    duracaoPiscada = agora;
    ultimaPiscada = agora;
  }

  if (piscando && agora - duracaoPiscada > blinkDuration) {
    piscando = false;
  }

  desenharRosto();
#endif
}

// ─── Entrada de Comandos pela Serial USB ──────────────────────────────────────
void processSerialInput() {
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == '\r') continue;

    if (c == '\n') {
      serialBuffer.trim();
      if (serialBuffer.length() > 0) {
        Serial.printf("[SER] Comando recebido: %s\n", serialBuffer.c_str());
        handleCommand(serialBuffer);
      }
      serialBuffer = "";
      continue;
    }

    if (serialBuffer.length() < MAX_COMMAND_LENGTH) {
      serialBuffer += c;
    } else {
      serialBuffer = "";
      Serial.println("[WARN] Linha serial muito longa — descartada.");
    }
  }
}

// ─── Comunicação BLE TX (ESP32 → App) ─────────────────────────────────────────
void sendBleStatus(const char* msg) {
  Serial.printf("[TX] %s\n", msg);
  if (pTxChar == nullptr) return;
  pTxChar->setValue(msg);
  if (deviceConnected) {
    pTxChar->notify();
  }
}

void sendJsonAck(const char* cmdName, bool ok, const char* errCode) {
  char jsonBuf[220];
  if (ok) {
    snprintf(jsonBuf, sizeof(jsonBuf),
             "{\"ack\":\"%s\",\"ok\":true,\"v\":%d,\"m\":%d,\"l\":%d,\"r\":%d,\"dir\":\"%s\",\"expr\":\"%s\",\"buz\":%d,\"mute\":%d,\"seta\":\"%s\",\"vmin\":%d,\"vmax\":%d}",
             cmdName,
             speedPercent,
             motorsRunning ? 1 : 0,
             currentLeftSpeed,
             currentRightSpeed,
             currentDirection.c_str(),
             expressionToString(currentExpression),
             (currentSeq != nullptr) ? 1 : 0,
             buzzerMuted ? 1 : 0,
             setaStateToString(currentSetaEstado),
             minSpeedPercent,
             maxSpeedPercent);
  } else {
    snprintf(jsonBuf, sizeof(jsonBuf),
             "{\"ack\":\"%s\",\"ok\":false,\"err\":\"%s\"}",
             cmdName,
             errCode != nullptr ? errCode : "ERR:CMD");
  }
  sendBleStatus(jsonBuf);
}
