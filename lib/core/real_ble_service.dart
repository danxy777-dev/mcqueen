// lib/core/real_ble_service.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

import '../models/ble_diagnostics.dart';
import '../models/mcqueen_settings.dart';
import '../models/motor_state.dart';
import '../models/robot_expression.dart';
import '../models/sound_item.dart';
import '../models/turn_signal_state.dart';
import 'ble_constants.dart';
import 'robot_service.dart';

/// Implementação real centralizada de conexão e controle BLE com o robô McQueen (ESP32-C3).
class RealBleService extends RobotService {
  RobotConnectionState _state = RobotConnectionState.disconnected;
  String? _lastStatus;
  String? _connectionError;
  bool _buzinaSent = false;
  String? _activeSoundLabel;
  Timer? _buzzerIndicatorTimer;
  bool _isSoundSequenceRunning = false;
  int _soundSequenceToken = 0;
  Completer<void>? _sequenceWaitCompleter;
  int _emergencyStopCount = 0;

  ControlMode _controlMode = ControlMode.holdToMove;
  int _speedPercent = SpeedLevel.medium.percent;
  int _battery = 0;
  bool _batteryAvailable = false;
  int _rssi = 0;
  bool _isManualDisconnect = false;
  MotorState _motorState = const MotorState();
  RobotExpression _expression = RobotExpression.normal;
  TurnSignalState _turnSignal = TurnSignalState.off;
  McQueenSettings _settings = const McQueenSettings();
  BleDiagnostics _diagnostics = const BleDiagnostics();

  final List<CommandLogEntry> _commandLogs = [];

  fbp.BluetoothDevice? _device;
  fbp.BluetoothCharacteristic? _rxChar;

  StreamSubscription<List<fbp.ScanResult>>? _scanSub;
  StreamSubscription<fbp.BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  Timer? _rssiTimer;
  Timer? _movementTimer;
  String? _activeMovement;
  bool _isWriting = false;
  bool _txNotifyEnabled = false;

  Completer<void>? _pingCompleter;
  Completer<String>? _diagCompleter;
  Completer<String>? _statusCompleter;
  Completer<CommandResult>? _soundAckCompleter;
  Completer<CommandResult>? _settingsAckCompleter;
  final List<({String cmd, bool log, Completer<bool> completer})> _writeQueue =
      [];

  final StreamController<ConnectionEvent> _connectionEvents =
      StreamController<ConnectionEvent>.broadcast();

  RealBleService() {
    _loadPersistedSettings();
  }

  Future<void> _loadPersistedSettings() async {
    final loaded = await McQueenSettingsStore.load();
    _settings = loaded;
    if (!isConnected) {
      _speedPercent = loaded.defaultSpeedPercent;
      _expression = loaded.baseExpression;
      _motorState = _motorState.copyWith(
        leftNeutralUs: loaded.leftNeutralUs,
        rightNeutralUs: loaded.rightNeutralUs,
        leftInverted: loaded.leftInverted,
        rightInverted: loaded.rightInverted,
      );
    }
    notifyListeners();
  }

  @override RobotConnectionState get connectionState => _state;
  @override String? get lastStatus => _lastStatus;
  @override String? get connectionError => _connectionError;
  @override Stream<ConnectionEvent> get connectionEvents => _connectionEvents.stream;
  @override bool get buzinaSent => _buzinaSent;
  @override String? get activeSoundLabel => _activeSoundLabel;
  @override bool get isSoundSequenceRunning => _isSoundSequenceRunning;
  @override bool get isDemo => false;
  @override ControlMode get controlMode => _controlMode;
  @override SpeedLevel get currentSpeed => SpeedLevel.fromPercent(_speedPercent);
  @override int get speedPercent => _speedPercent;
  @override bool get batteryAvailable => _batteryAvailable;
  @override int get batteryPercent => _battery;
  @override int get rssi => _rssi;
  @override List<CommandLogEntry> get commandLogs => List.unmodifiable(_commandLogs);
  @override BleDiagnostics get diagnostics => _diagnostics;
  @override MotorState get motorState => _motorState;
  @override RobotExpression get currentExpression => _expression;
  @override TurnSignalState get turnSignal => _turnSignal;
  @override String get setaEstado => switch (_turnSignal) {
        TurnSignalState.left => 'ESQUERDA',
        TurnSignalState.right => 'DIREITA',
        TurnSignalState.alert => 'ALERTA',
        TurnSignalState.auto => 'AUTO',
        TurnSignalState.off => 'OFF',
      };
  @override McQueenSettings get settings => _settings;
  @override int get emergencyStopCount => _emergencyStopCount;

  @override
  void setControlMode(ControlMode mode) {
    if (_controlMode == mode) return;
    _controlMode = mode;
    if (mode == ControlMode.holdToMove && _activeMovement != null) {
      _activeMovement = null;
      _stopKeepAlive();
      unawaited(_writeCommand(BleConstants.cmdParar));
    }
    notifyListeners();
  }

  @override
  Future<void> setSpeed(SpeedLevel speed) async {
    _speedPercent = speed.percent;
    notifyListeners();
    if (!isConnected) return;
    await _writeCommand(speed.bleCommand);
    if (_activeMovement != null) {
      await _sendActiveMovement(log: false);
    }
  }

  @override
  Future<void> setSpeedPercent(int percent) async {
    _speedPercent = BleConstants.clampPercent(percent);
    notifyListeners();
    if (!isConnected) return;
    await _writeCommand(BleConstants.speed(_speedPercent), log: true);
    if (_activeMovement != null) {
      await _sendActiveMovement(log: false);
    }
  }

  @override
  void clearLogs() {
    _commandLogs.clear();
    notifyListeners();
  }

  // ── Processo de Conexão BLE Real ─────────────────────────────────────────────
  @override
  Future<void> connect() async {
    // Evita múltiplas conexões simultâneas ou tentativas concorrentes
    if (_state == RobotConnectionState.connected ||
        _state == RobotConnectionState.scanning ||
        _state == RobotConnectionState.connecting ||
        _state == RobotConnectionState.validatingService) {
      return;
    }

    _isManualDisconnect = false;
    _connectionError = null;

    // 1. Verificar se o Bluetooth é suportado
    try {
      final isSupported = await fbp.FlutterBluePlus.isSupported;
      if (!isSupported) {
        _failConnection(
          title: 'Não foi possível conectar',
          message:
              'Não foi possível estabelecer uma conexão funcional com o ESP32 do McQueen. Verifique se o robô está ligado, se o Bluetooth está ativado e se a placa está anunciando o serviço BLE correto.',
          specificCause:
              'O dispositivo móvel não possui hardware Bluetooth Low Energy (BLE) disponível.',
        );
        return;
      }
    } catch (e) {
      debugPrint('[BLE] Aviso ao verificar suporte: $e');
    }

    // 2. Verificar se o Bluetooth está ligado e com permissões
    try {
      var adapterState = await fbp.FlutterBluePlus.adapterState
          .where((s) => s != fbp.BluetoothAdapterState.unknown)
          .first
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => fbp.BluetoothAdapterState.unknown,
          );
      if (adapterState != fbp.BluetoothAdapterState.on &&
          adapterState != fbp.BluetoothAdapterState.unauthorized) {
        try {
          await fbp.FlutterBluePlus.turnOn();
          adapterState = await fbp.FlutterBluePlus.adapterState
              .firstWhere(
                (s) => s == fbp.BluetoothAdapterState.on,
                orElse: () => fbp.BluetoothAdapterState.off,
              )
              .timeout(
                const Duration(seconds: 3),
                onTimeout: () => fbp.BluetoothAdapterState.off,
              );
        } catch (_) {}
      }

      if (adapterState == fbp.BluetoothAdapterState.unauthorized) {
        _failConnection(
          title: 'Não foi possível conectar',
          message:
              'Não foi possível estabelecer uma conexão funcional com o ESP32 do McQueen. Verifique se o robô está ligado, se o Bluetooth está ativado e se a placa está anunciando o serviço BLE correto.',
          specificCause:
              'Permissão de Bluetooth negada. Conceda permissão de "Dispositivos por perto" e "Localização" nas configurações do aplicativo.',
        );
        return;
      }

      if (adapterState != fbp.BluetoothAdapterState.on) {
        _failConnection(
          title: 'Não foi possível conectar',
          message:
              'Não foi possível estabelecer uma conexão funcional com o ESP32 do McQueen. Verifique se o robô está ligado, se o Bluetooth está ativado e se a placa está anunciando o serviço BLE correto.',
          specificCause:
              'O Bluetooth do celular está desativado. Ative o Bluetooth nas configurações ou atalho do sistema para continuar.',
        );
        return;
      }
    } catch (e) {
      _failConnection(
        title: 'Não foi possível conectar',
        message:
            'Não foi possível estabelecer uma conexão funcional com o ESP32 do McQueen. Verifique se o robô está ligado, se o Bluetooth está ativado e se a placa está anunciando o serviço BLE correto.',
        specificCause: 'Erro ao verificar estado do Bluetooth do celular: $e',
      );
      return;
    }

    // 3. Procurando McQueen
    _setState(RobotConnectionState.scanning);
    _recordLog('SCAN: Procurando dispositivo "${BleConstants.deviceName}"...',
        isOutgoing: false);

    fbp.BluetoothDevice? targetDevice;

    try {
      final sysDevices = <fbp.BluetoothDevice>[
        ...fbp.FlutterBluePlus.connectedDevices,
        ...(await fbp.FlutterBluePlus.systemDevices(
            [fbp.Guid(BleConstants.serviceUuid)])),
      ];
      for (final d in sysDevices) {
        final pName = d.platformName.trim().toLowerCase();
        final rId = d.remoteId.str.toUpperCase();
        if (pName == BleConstants.deviceName.toLowerCase() ||
            pName.contains('mcqueen') ||
            rId == '14:63:93:93:AD:DA') {
          _recordLog(
              'SCAN: Dispositivo "${BleConstants.deviceName}" já ativo no sistema ($rId).',
              isOutgoing: false);
          targetDevice = d;
          break;
        }
      }
    } catch (e) {
      debugPrint('[BLE] Aviso ao consultar systemDevices: $e');
    }

    if (targetDevice == null) {
      try {
        await fbp.FlutterBluePlus.stopScan();
      } catch (_) {}

      final completer = Completer<fbp.BluetoothDevice?>();

      _scanSub?.cancel();
      _scanSub = fbp.FlutterBluePlus.onScanResults.listen((results) {
        for (final r in results) {
          final advName = r.advertisementData.advName.trim();
          final platformName = r.device.platformName.trim();
          final rId = r.device.remoteId.str.toUpperCase();
          final targetLower = BleConstants.deviceName.toLowerCase();
          final matchesName = advName.toLowerCase() == targetLower ||
              platformName.toLowerCase() == targetLower ||
              advName.toLowerCase().contains('mcqueen') ||
              platformName.toLowerCase().contains('mcqueen') ||
              rId == '14:63:93:93:AD:DA';
          final matchesService = r.advertisementData.serviceUuids.any(
            (u) =>
                u.toString().toLowerCase() ==
                BleConstants.serviceUuid.toLowerCase(),
          );

          if ((matchesName || matchesService) && !completer.isCompleted) {
            _rssi = r.rssi;
            _recordLog(
                'SCAN: Dispositivo "${BleConstants.deviceName}" encontrado! [RSSI: ${r.rssi} dBm]',
                isOutgoing: false);
            _stopScan();
            completer.complete(r.device);
            return;
          }
        }
      }, onError: (e) {
        debugPrint('[BLE] Erro no scan: $e');
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      });

      try {
        await fbp.FlutterBluePlus.startScan(
          timeout: BleConstants.scanTimeout,
          androidUsesFineLocation: true,
        );
      } catch (e) {
        _stopScan();
        final errLower = e.toString().toLowerCase();
        final isPerm = errLower.contains('permission') ||
            errLower.contains('denied') ||
            errLower.contains('unauthorized');
        _failConnection(
          title: 'Não foi possível conectar',
          message:
              'Não foi possível estabelecer uma conexão funcional com o ESP32 do McQueen. Verifique se o robô está ligado, se o Bluetooth está ativado e se a placa está anunciando o serviço BLE correto.',
          specificCause: isPerm
              ? 'Permissão de Bluetooth negada pelo sistema operacional. Conceda acesso nas configurações do Android.'
              : 'Falha ao iniciar escaneamento BLE: $e',
        );
        return;
      }

      try {
        targetDevice = await completer.future.timeout(
          BleConstants.scanTimeout,
          onTimeout: () {
            _stopScan();
            return null;
          },
        );
      } catch (e) {
        _stopScan();
        _failConnection(
          title: 'Não foi possível conectar',
          message:
              'Não foi possível estabelecer uma conexão funcional com o ESP32 do McQueen. Verifique se o robô está ligado, se o Bluetooth está ativado e se a placa está anunciando o serviço BLE correto.',
          specificCause: 'Erro durante a busca BLE: $e',
        );
        return;
      }
    }

    if (targetDevice == null) {
      _failConnection(
        title: 'Não foi possível conectar',
        message:
            'Não foi possível estabelecer uma conexão funcional com o ESP32 do McQueen. Verifique se o robô está ligado, se o Bluetooth está ativado e se a placa está anunciando o serviço BLE correto.',
        specificCause:
            'O dispositivo "${BleConstants.deviceName}" não foi encontrado após 10 segundos de varredura. Certifique-se de que a placa ESP32-C3 está alimentada e anunciando BLE.',
      );
      return;
    }

    // 4. Conectando com a placa
    _setState(RobotConnectionState.connecting);
    _recordLog('CONEXAO: Estabelecendo conexão com ${targetDevice.remoteId}...',
        isOutgoing: false);
    _device = targetDevice;

    _connSub?.cancel();
    _connSub = null;

    try {
      await targetDevice.connect(
        timeout: BleConstants.connectTimeout,
        autoConnect: false,
      );
    } catch (e) {
      debugPrint('[BLE] Erro ao conectar: $e');
      await _cleanupConnection();
      _failConnection(
        title: 'Não foi possível conectar',
        message:
            'Não foi possível estabelecer uma conexão funcional com o ESP32 do McQueen. Verifique se o robô está ligado, se o Bluetooth está ativado e se a placa está anunciando o serviço BLE correto.',
        specificCause:
            'Conexão recusada ou expirou ao tentar parear com o ESP32-C3 ($e).',
      );
      return;
    }

    _connSub = targetDevice.connectionState.listen((s) {
      if (s == fbp.BluetoothConnectionState.disconnected &&
          (_state == RobotConnectionState.connected ||
              _state == RobotConnectionState.validatingService)) {
        _onDisconnected();
      }
    });

    // 5. Validando serviço BLE
    _setState(RobotConnectionState.validatingService);
    _recordLog('GATT: Descobrindo e validando serviços...', isOutgoing: false);

    List<fbp.BluetoothService> services = [];
    try {
      services = await targetDevice.discoverServices();
    } catch (e) {
      debugPrint('[BLE] Erro ao descobrir serviços: $e');
      await _cleanupConnection();
      _failConnection(
        title: 'Não foi possível conectar',
        message:
            'Não foi possível estabelecer uma conexão funcional com o ESP32 do McQueen. Verifique se o robô está ligado, se o Bluetooth está ativado e se a placa está anunciando o serviço BLE correto.',
        specificCause: 'Falha ao descobrir serviços GATT da placa ESP32: $e',
      );
      return;
    }

    fbp.BluetoothService? matchingService;
    for (final s in services) {
      if (s.uuid.toString().toLowerCase() ==
          BleConstants.serviceUuid.toLowerCase()) {
        matchingService = s;
        break;
      }
    }

    if (matchingService == null) {
      await _cleanupConnection();
      _failConnection(
        title: 'Não foi possível conectar',
        message:
            'Não foi possível estabelecer uma conexão funcional com o ESP32 do McQueen. Verifique se o robô está ligado, se o Bluetooth está ativado e se a placa está anunciando o serviço BLE correto.',
        specificCause:
            'Serviço BLE incompatível: o Service UUID esperado (${BleConstants.serviceUuid}) não foi encontrado na placa.',
      );
      return;
    }

    fbp.BluetoothCharacteristic? rxChar;
    fbp.BluetoothCharacteristic? txChar;

    for (final char in matchingService.characteristics) {
      final uuid = char.uuid.toString().toLowerCase();
      if (uuid == BleConstants.charRxUuid.toLowerCase()) {
        rxChar = char;
      }
      if (uuid == BleConstants.charTxUuid.toLowerCase()) {
        txChar = char;
      }
    }

    if (rxChar == null) {
      await _cleanupConnection();
      _failConnection(
        title: 'Não foi possível conectar',
        message:
            'Não foi possível estabelecer uma conexão funcional com o ESP32 do McQueen. Verifique se o robô está ligado, se o Bluetooth está ativado e se a placa está anunciando o serviço BLE correto.',
        specificCause:
            'Característica BLE de comunicação (${BleConstants.charRxUuid}) não foi encontrada no serviço.',
      );
      return;
    }

    final props = rxChar.properties;
    if (!props.write && !props.writeWithoutResponse) {
      await _cleanupConnection();
      _failConnection(
        title: 'Não foi possível conectar',
        message:
            'Não foi possível estabelecer uma conexão funcional com o ESP32 do McQueen. Verifique se o robô está ligado, se o Bluetooth está ativado e se a placa está anunciando o serviço BLE correto.',
        specificCause:
            'A característica de comunicação não possui permissão de escrita (WRITE ou WRITE_NR).',
      );
      return;
    }

    _rxChar = rxChar;

    _txNotifyEnabled = false;
    if (txChar != null && txChar.properties.notify) {
      try {
        await txChar.setNotifyValue(true);
        _notifySub?.cancel();
        _notifySub = txChar.onValueReceived.listen(_onNotification);
        _txNotifyEnabled = true;
      } catch (e) {
        debugPrint('[BLE] Aviso ao assinar notificações: $e');
      }
    }

    final resolvedName = targetDevice.platformName.trim().isNotEmpty
        ? targetDevice.platformName.trim()
        : BleConstants.deviceName;
    _diagnostics = _diagnostics.copyWith(
      deviceName: resolvedName,
      deviceId: targetDevice.remoteId.str,
      serviceValidated: true,
      rxCanWrite: props.write,
      rxCanWriteWithoutResponse: props.writeWithoutResponse,
      txNotifyEnabled: _txNotifyEnabled,
      clearError: true,
    );

    // 7. Teste de escrita + handshake PING/PONG
    final pingWatch = Stopwatch()..start();
    try {
      _recordLog('DIAG: Enviando comando de teste de comunicação (PING)...',
          isOutgoing: true);
      if (_txNotifyEnabled) {
        _pingCompleter = Completer<void>();
      }
      await rxChar.write(
        utf8.encode(BleConstants.cmdPing),
        withoutResponse: props.writeWithoutResponse,
      );
      _diagnostics = _diagnostics.copyWith(
        lastTxCommand: BleConstants.cmdPing,
        lastTxAt: DateTime.now(),
      );
      if (_pingCompleter != null) {
        try {
          await _pingCompleter!.future
              .timeout(const Duration(milliseconds: 900));
          pingWatch.stop();
          _diagnostics = _diagnostics.copyWith(
            lastPingLatencyMs: pingWatch.elapsedMilliseconds,
          );
          _recordLog(
              'DIAG: Handshake PING/PONG confirmado pelo ESP32 (${pingWatch.elapsedMilliseconds} ms).',
              isOutgoing: false);
        } catch (_) {
          _recordLog(
              'DIAG: Escrita BLE validada (sem retorno PONG no timeout).',
              isOutgoing: false);
        } finally {
          _pingCompleter = null;
        }
      } else {
        _recordLog('DIAG: Teste de escrita validado (TX NOTIFY inativo).',
            isOutgoing: false);
      }
    } catch (e) {
      _pingCompleter = null;
      debugPrint('[BLE] Erro no teste de escrita: $e');
      await _cleanupConnection();
      _failConnection(
        title: 'Não foi possível conectar',
        message:
            'Não foi possível estabelecer uma conexão funcional com o ESP32 do McQueen. Verifique se o robô está ligado, se o Bluetooth está ativado e se a placa está anunciando o serviço BLE correto.',
        specificCause:
            'Falha no teste de escrita de diagnóstico na característica BLE: $e',
      );
      return;
    }

    // 8. Conexão real estabelecida e validada
    _activeMovement = null;
    _motorState = _motorState.copyWith(
      leftSpeed: 0,
      rightSpeed: 0,
      direction: 'PARADO',
    );
    _turnSignal = TurnSignalState.off;
    _clearBuzzerActive();
    _setState(RobotConnectionState.connected);
    _setStatus('OK:CONECTADO');
    _recordLog('CONEXAO: Conexão BLE real estabelecida e pronta para comandos!',
        isOutgoing: false);

    if (_txNotifyEnabled) {
      unawaited(_writeCommand(BleConstants.cmdStatus, log: false));
    }

    _startRssiPolling();

    _connectionEvents.add(
      ConnectionSuccessEvent(
        deviceName: resolvedName,
        serviceUuid: BleConstants.serviceUuid,
        charUuid: BleConstants.charRxUuid,
      ),
    );
  }

  void _failConnection({
    required String title,
    required String message,
    required String specificCause,
  }) {
    _connectionError = specificCause;
    _diagnostics = _diagnostics.copyWith(
      lastError: specificCause,
      serviceValidated: false,
      txNotifyEnabled: false,
    );
    _recordLog('ERR: $specificCause', isOutgoing: false, isSuccess: false);
    _setState(RobotConnectionState.error);
    _connectionEvents.add(
      ConnectionFailureEvent(
        title: title,
        message: message,
        specificCause: specificCause,
      ),
    );
  }

  void _stopScan() {
    _scanSub?.cancel();
    _scanSub = null;
    fbp.FlutterBluePlus.stopScan();
  }

  void _startRssiPolling() {
    _rssiTimer?.cancel();
    _rssiTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (_device != null && isConnected) {
        try {
          _rssi = await _device!.readRssi();
          notifyListeners();
        } catch (_) {}
      }
    });
  }

  void _markBuzzerActive(String label, [int durationMs = 600]) {
    _buzzerIndicatorTimer?.cancel();
    _buzinaSent = true;
    _activeSoundLabel = label;
    notifyListeners();
    _buzzerIndicatorTimer = Timer(Duration(milliseconds: durationMs), () {
      _clearBuzzerActive();
      notifyListeners();
    });
  }

  void _clearBuzzerActive() {
    _buzzerIndicatorTimer?.cancel();
    _buzzerIndicatorTimer = null;
    _buzinaSent = false;
    _activeSoundLabel = null;
  }

  void _interruptRunningSoundSequence() {
    _soundSequenceToken++;
    _isSoundSequenceRunning = false;
    final wait = _sequenceWaitCompleter;
    _sequenceWaitCompleter = null;
    if (wait != null && !wait.isCompleted) {
      wait.complete();
    }
  }

  void _onNotification(List<int> value) {
    final text = utf8.decode(value, allowMalformed: true).trim();
    if (text.isEmpty) return;
    _lastStatus = text;
    final now = DateTime.now();
    _diagnostics = _diagnostics.copyWith(
      lastRxResponse: text,
      lastRxAt: now,
      lastError: text.startsWith('ERR:') ? text : null,
      clearError: !text.startsWith('ERR:'),
    );

    if (text == 'PONG') {
      if (_pingCompleter != null && !_pingCompleter!.isCompleted) {
        _pingCompleter!.complete();
      }
    } else if (text.startsWith('DIAG:')) {
      _parseDiagTelemetry(text);
      if (_diagCompleter != null && !_diagCompleter!.isCompleted) {
        _diagCompleter!.complete(text);
      }
    } else if (text.startsWith('BATT:')) {
      final val = int.tryParse(text.substring(5));
      if (val != null) {
        _battery = val.clamp(0, 100);
        _batteryAvailable = true;
      }
    } else if (text == 'SAFETY:TIMEOUT' || text == 'OK:PARAR') {
      _activeMovement = null;
      _stopKeepAlive();
      _motorState = _motorState.copyWith(
        leftSpeed: 0,
        rightSpeed: 0,
        direction: 'PARADO',
      );
    } else if (text.startsWith('OK:VEL:')) {
      final velVal = text.substring(7).trim().toUpperCase();
      switch (velVal) {
        case 'ECO':
          _speedPercent = SpeedLevel.eco.percent;
          break;
        case 'NORMAL':
          _speedPercent = SpeedLevel.normal.percent;
          break;
        case 'SPORT':
          _speedPercent = SpeedLevel.sport.percent;
          break;
        case 'TURBO':
          _speedPercent = SpeedLevel.turbo.percent;
          break;
        default:
          final parsed = int.tryParse(velVal);
          if (parsed != null) {
            final lastTx = (_diagnostics.lastTxCommand ?? '').trim().toUpperCase();
            if (parsed >= 1 &&
                parsed <= 4 &&
                !lastTx.startsWith(BleConstants.cmdSpeedPrefix)) {
              _speedPercent = SpeedLevel.values[parsed - 1].percent;
            } else {
              _speedPercent = parsed.clamp(0, 100);
            }
          }
      }
    } else if (text.startsWith('OK:EXPR:')) {
      _expression = RobotExpression.fromCode(text.substring(8));
    } else if (text.startsWith('OK:SETA:')) {
      if (text == 'OK:SETA:AUTO:ON') {
        _turnSignal = TurnSignalState.auto;
      } else if (text == 'OK:SETA:AUTO:OFF') {
        _turnSignal = TurnSignalState.off;
      } else {
        _turnSignal = TurnSignalState.fromCode(text.substring(8));
      }
    } else if (text.startsWith('OK:AUTO:')) {
      if (text == 'OK:AUTO:ON') {
        _settings = _settings.copyWith(autoReactionsEnabled: true);
      } else if (text == 'OK:AUTO:OFF') {
        _settings = _settings.copyWith(autoReactionsEnabled: false);
      } else if (text.startsWith('OK:AUTO:FREQ:')) {
        final sec = int.tryParse(text.substring(13));
        if (sec != null) {
          _settings = _settings.copyWith(reactionIntervalSeconds: sec);
        }
      }
      _completeSettingsAck(CommandResult(ok: true, response: text));
    } else if (text.startsWith('OK:CAL:')) {
      _parseCalibrationAck(text);
      _completeSettingsAck(CommandResult(ok: true, response: text));
    } else if (text == 'OK:SOM:MUTE:1') {
      _settings = _settings.copyWith(soundsEnabled: false);
      _interruptRunningSoundSequence();
      _clearBuzzerActive();
      _completeSettingsAck(CommandResult(ok: true, response: text));
    } else if (text == 'OK:SOM:MUTE:0') {
      _settings = _settings.copyWith(soundsEnabled: true);
      _completeSettingsAck(CommandResult(ok: true, response: text));
    } else if (text == 'OK:BUZZER:ATIVO') {
      _settings = _settings.copyWith(activeBuzzerMode: true);
      _completeSettingsAck(CommandResult(ok: true, response: text));
    } else if (text == 'OK:BUZZER:PASSIVO') {
      _settings = _settings.copyWith(activeBuzzerMode: false);
      _completeSettingsAck(CommandResult(ok: true, response: text));
    } else if (text == 'OK:BUZZER:OFF' || text == 'OK:BUZINA:DESLIGAR') {
      _clearBuzzerActive();
      if (_soundAckCompleter != null && !_soundAckCompleter!.isCompleted) {
        _soundAckCompleter!.complete(CommandResult(ok: true, response: text));
      }
    } else if (text == 'OK:BUZZER:MUTED') {
      _interruptRunningSoundSequence();
      _clearBuzzerActive();
      _settings = _settings.copyWith(soundsEnabled: false);
      if (_soundAckCompleter != null && !_soundAckCompleter!.isCompleted) {
        _soundAckCompleter!.complete(
          CommandResult(
            ok: false,
            response: text,
            error: 'Sons silenciados no ESP32 (MUTE ativo).',
          ),
        );
      }
    } else if (text == 'OK:BUZINA' ||
        text == 'OK:BUZINA:CURTA' ||
        text == 'OK:BUZINA:LONGA' ||
        text == 'OK:BUZINA:EMERGENCIA' ||
        text == 'OK:BIPE' ||
        text == 'OK:ALERTA' ||
        text.startsWith('OK:SOM:') ||
        text.startsWith('OK:MELODIA:') ||
        text == 'OK:BUZZER:TONE') {
      if (!(_isSoundSequenceRunning && text == 'OK:BUZZER:TONE')) {
        final durationMs =
            text == 'OK:BUZINA:LONGA' || text == 'OK:SOM:BUZ_LONGA'
                ? 650
                : (text.contains('EMERG') || text == 'OK:ALERTA' ? 750 : 500);
        _markBuzzerActive(text.substring(3), durationMs);
      }
      if (_soundAckCompleter != null && !_soundAckCompleter!.isCompleted) {
        _soundAckCompleter!.complete(CommandResult(ok: true, response: text));
      }
    } else if (text.startsWith('V:') && text.contains('|')) {
      _parseStatusTelemetry(text);
      _diagnostics = _diagnostics.copyWith(lastStatusSyncAt: now);
      if (_statusCompleter != null && !_statusCompleter!.isCompleted) {
        _statusCompleter!.complete(text);
      }
    } else if (text.startsWith('ERR:')) {
      if (_soundAckCompleter != null && !_soundAckCompleter!.isCompleted) {
        _soundAckCompleter!.complete(
          CommandResult(ok: false, response: text, error: text),
        );
      }
      _completeSettingsAck(
        CommandResult(ok: false, response: text, error: text),
      );
    }

    _recordLog('RX ← $text',
        isOutgoing: false, isSuccess: !text.startsWith('ERR:'));
    notifyListeners();
  }

  void _completeSettingsAck(CommandResult result) {
    if (_settingsAckCompleter != null && !_settingsAckCompleter!.isCompleted) {
      _settingsAckCompleter!.complete(result);
    }
  }

  void _parseCalibrationAck(String text) {
    if (text == 'OK:CAL:RESET') {
      _settings = const McQueenSettings();
      _motorState = MotorState(
        leftSpeed: _motorState.leftSpeed,
        rightSpeed: _motorState.rightSpeed,
        direction: _motorState.direction,
      );
      if (isConnected && _txNotifyEnabled) {
        unawaited(_writeCommand(BleConstants.cmdStatus, log: false));
      }
      return;
    }
    if (text == 'OK:CAL:LINV:ON' || text == 'OK:CAL:LINV:OFF') {
      final inv = text.endsWith(':ON');
      _settings = _settings.copyWith(leftInverted: inv);
      _motorState = _motorState.copyWith(leftInverted: inv);
      return;
    }
    if (text == 'OK:CAL:RINV:ON' || text == 'OK:CAL:RINV:OFF') {
      final inv = text.endsWith(':ON');
      _settings = _settings.copyWith(rightInverted: inv);
      _motorState = _motorState.copyWith(rightInverted: inv);
      return;
    }
    final parts = text.split(':');
    if (parts.length < 4) return;
    final key = parts[2];
    final val = int.tryParse(parts[3]);
    if (val == null) return;
    switch (key) {
      case 'LSTOP':
        _settings = _settings.copyWith(leftNeutralUs: val);
        _motorState = _motorState.copyWith(leftNeutralUs: val);
        break;
      case 'RSTOP':
        _settings = _settings.copyWith(rightNeutralUs: val);
        _motorState = _motorState.copyWith(rightNeutralUs: val);
        break;
      case 'VMIN':
        _settings = _settings.copyWith(minSpeedPercent: val);
        break;
      case 'VMAX':
        _settings = _settings.copyWith(maxSpeedPercent: val);
        break;
      case 'TRIML':
        _settings = _settings.copyWith(leftTrimPercent: val);
        break;
      case 'TRIMR':
        _settings = _settings.copyWith(rightTrimPercent: val);
        break;
    }
  }

  void _parseDiagTelemetry(String diagLine) {
    final payload = diagLine.substring(5);
    bool? adv, conn, ready, srv;
    int? len;
    for (final part in payload.split('|')) {
      final idx = part.indexOf(':');
      if (idx <= 0) continue;
      final k = part.substring(0, idx).trim().toUpperCase();
      final v = part.substring(idx + 1).trim();
      switch (k) {
        case 'ADV':
          adv = v == '1';
          break;
        case 'CONN':
          conn = v == '1';
          break;
        case 'READY':
          ready = v == '1';
          break;
        case 'LEN':
          len = int.tryParse(v);
          break;
        case 'SRV':
          srv = v == '1';
          break;
      }
    }
    _diagnostics = _diagnostics.copyWith(
      lastDiagRaw: diagLine,
      diagAdvertising: adv,
      diagConnected: conn,
      diagReady: ready,
      diagAdvPayloadBytes: len,
      diagServosEnabled: srv,
    );
  }

  void _parseStatusTelemetry(String statusLine) {
    final parts = statusLine.split('|');
    int? lStop, rStop, sl, sr, vMin, vMax, tl, tr;
    bool? invL, invR, autoEn, muted;

    for (final p in parts) {
      final idx = p.indexOf(':');
      if (idx <= 0) continue;
      final k = p.substring(0, idx);
      final v = p.substring(idx + 1);
      switch (k) {
        case 'V':
          final spd = int.tryParse(v);
          if (spd != null) _speedPercent = spd.clamp(0, 100);
          break;
        case 'L':
          lStop = int.tryParse(v);
          break;
        case 'R':
          rStop = int.tryParse(v);
          break;
        case 'I':
          if (v.length >= 2) {
            invL = v[0] == '1';
            invR = v[1] == '1';
          }
          break;
        case 'SL':
          sl = int.tryParse(v);
          break;
        case 'SR':
          sr = int.tryParse(v);
          break;
        case 'E':
          _expression = RobotExpression.fromCode(v);
          break;
        case 'S':
          _turnSignal = TurnSignalState.fromCode(v);
          break;
        case 'MU':
          muted = v == '1';
          break;
        case 'VMIN':
          vMin = int.tryParse(v);
          break;
        case 'VMAX':
          vMax = int.tryParse(v);
          break;
        case 'TL':
          tl = int.tryParse(v);
          break;
        case 'TR':
          tr = int.tryParse(v);
          break;
        case 'A':
          autoEn = v == '1';
          break;
      }
    }

    _motorState = _motorState.copyWith(
      leftSpeed: sl,
      rightSpeed: sr,
      leftNeutralUs: lStop,
      rightNeutralUs: rStop,
      leftInverted: invL,
      rightInverted: invR,
      direction: (sl == 0 && sr == 0) ? 'PARADO' : _motorState.direction,
    );

    _settings = _settings.copyWith(
      leftNeutralUs: lStop,
      rightNeutralUs: rStop,
      leftInverted: invL,
      rightInverted: invR,
      minSpeedPercent: vMin,
      maxSpeedPercent: vMax,
      leftTrimPercent: tl,
      rightTrimPercent: tr,
      autoReactionsEnabled: autoEn,
      soundsEnabled: muted != null ? !muted : null,
    );
  }

  // ── Desconexão e Limpeza ─────────────────────────────────────────────────────
  @override
  Future<void> disconnect() async {
    _isManualDisconnect = true;
    _recordLog('CONEXAO: Desconectando por solicitação do usuário...',
        isOutgoing: false);
    if (isConnected) {
      await _writeCommand(BleConstants.cmdParar, log: false);
    }
    await _cleanupConnection();
    _setState(RobotConnectionState.disconnected);
  }

  void _onDisconnected() {
    if (_isManualDisconnect) {
      _recordLog('CONEXAO: Desconectado com sucesso.', isOutgoing: false);
    } else if (_state == RobotConnectionState.connected) {
      _recordLog('CONEXAO: Queda inesperada de conexão BLE!',
          isOutgoing: false, isSuccess: false);
      _connectionEvents.add(
        const UnexpectedDisconnectEvent(
          message:
              'A conexão com o ESP32 do McQueen foi interrompida inesperadamente. Verifique se o robô foi desligado, se a bateria descarregou ou se saiu do alcance do Bluetooth.',
        ),
      );
    }
    _cleanupConnection();
    _setState(RobotConnectionState.disconnected);
  }

  Future<void> _cleanupConnection() async {
    _interruptRunningSoundSequence();
    _activeMovement = null;
    for (final entry in _writeQueue) {
      if (!entry.completer.isCompleted) {
        entry.completer.complete(false);
      }
    }
    _writeQueue.clear();
    _isWriting = false;
    _txNotifyEnabled = false;
    _pingCompleter = null;
    _diagCompleter = null;
    _statusCompleter = null;
    if (_soundAckCompleter != null && !_soundAckCompleter!.isCompleted) {
      _soundAckCompleter!.complete(
        const CommandResult(ok: false, error: 'Conexão BLE encerrada.'),
      );
    }
    _soundAckCompleter = null;
    if (_settingsAckCompleter != null && !_settingsAckCompleter!.isCompleted) {
      _settingsAckCompleter!.complete(
        const CommandResult(ok: false, error: 'Conexão BLE encerrada.'),
      );
    }
    _settingsAckCompleter = null;
    _motorState = _motorState.copyWith(
      leftSpeed: 0,
      rightSpeed: 0,
      direction: 'PARADO',
    );
    _turnSignal = TurnSignalState.off;
    _clearBuzzerActive();
    _stopKeepAlive();
    _rssiTimer?.cancel();
    _rssiTimer = null;
    final notifySub = _notifySub;
    final connSub = _connSub;
    final scanSub = _scanSub;
    final dev = _device;
    _notifySub = null;
    _connSub = null;
    _scanSub = null;
    _rxChar = null;
    _device = null;
    notifySub?.cancel();
    connSub?.cancel();
    scanSub?.cancel();
    _diagnostics = _diagnostics.copyWith(
      clearDevice: true,
      serviceValidated: false,
      rxCanWrite: false,
      rxCanWriteWithoutResponse: false,
      txNotifyEnabled: false,
    );
    try {
      await dev?.disconnect();
    } catch (_) {}
  }

  void _updateLocalMotorStateForDirection(String base, int effectiveSpeed) {
    final (l, r) = switch (base) {
      'FRENTE' => (effectiveSpeed, effectiveSpeed),
      'TRAS' => (-effectiveSpeed, -effectiveSpeed),
      'ESQUERDA' || 'ESQ' => (-effectiveSpeed, effectiveSpeed),
      'DIREITA' || 'DIR' => (effectiveSpeed, -effectiveSpeed),
      _ => (0, 0),
    };
    _motorState = _motorState.copyWith(
      leftSpeed: l,
      rightSpeed: r,
      direction: (l == 0 && r == 0) ? 'PARADO' : base,
    );
  }

  // ── Movimentação e Comandos ──────────────────────────────────────────────────
  @override
  Future<void> startMovement(String cmd) async {
    if (!isConnected) return;

    final base = cmd.split(':').first.toUpperCase();
    _activeMovement = base;

    await _sendActiveMovement();
    _movementTimer?.cancel();
    _movementTimer = Timer.periodic(BleConstants.movementRepeatInterval, (_) {
      if (!isConnected || _activeMovement == null) {
        _stopKeepAlive();
        return;
      }
      unawaited(_sendActiveMovement(log: false));
    });
  }

  @override
  Future<void> startMotorTest(String side, int speed) async {
    if (!isConnected) return;
    final normSide = side.trim().toUpperCase() == 'DIR' ? 'DIR' : 'ESQ';
    final clamped = speed.clamp(-100, 100);
    if (clamped == 0) {
      await stopJoystick();
      return;
    }
    _activeMovement = 'MOTOR:$normSide:$clamped';
    await _sendActiveMovement();
    _movementTimer?.cancel();
    _movementTimer = Timer.periodic(BleConstants.movementRepeatInterval, (_) {
      if (!isConnected || _activeMovement == null) {
        _stopKeepAlive();
        return;
      }
      unawaited(_sendActiveMovement(log: false));
    });
  }

  @override
  Future<void> stopMovement([String? sourceCmd]) async {
    if (_controlMode != ControlMode.holdToMove) {
      return;
    }
    if (sourceCmd != null && _activeMovement != null) {
      final releasedBase = sourceCmd.split(':').first.toUpperCase();
      if (_activeMovement != releasedBase) {
        return;
      }
    }
    _activeMovement = null;
    _stopKeepAlive();
    _motorState = _motorState.copyWith(
        leftSpeed: 0, rightSpeed: 0, direction: 'PARADO');
    notifyListeners();
    await _writeCommand(BleConstants.cmdParar);
  }

  @override
  Future<void> sendCommand(String cmd) async {
    if (!isConnected) return;
    final trimmed = cmd.trim();
    if (trimmed.isEmpty) return;

    if (BleConstants.isStopCommand(trimmed)) {
      await stopJoystick();
      return;
    }

    if (BleConstants.isMovementCommand(trimmed)) {
      final upper = trimmed.toUpperCase();
      if (upper.startsWith('DIFF:')) {
        await _writeCommand(trimmed);
        return;
      }
      if (upper.startsWith('MOTOR:')) {
        final parts = upper.split(':');
        if (parts.length == 3) {
          final side = parts[1];
          final spd = int.tryParse(parts[2]) ?? 0;
          await startMotorTest(side, spd);
          return;
        }
      }
      await startMovement(trimmed);
      return;
    }

    final upper = trimmed.toUpperCase();
    if (upper == BleConstants.cmdBuzinaDesligar ||
        upper == BleConstants.cmdMute ||
        upper == 'PARAR_BUZZER') {
      _interruptRunningSoundSequence();
      _clearBuzzerActive();
      notifyListeners();
    }

    await _writeCommand(trimmed);
  }

  Future<void> _sendActiveMovement({bool log = true}) async {
    final active = _activeMovement;
    if (active == null || !isConnected) return;
    if (active.startsWith('MOTOR:')) {
      final parts = active.split(':');
      if (parts.length == 3) {
        final side = parts[1];
        final spd = int.tryParse(parts[2]) ?? 0;
        _motorState = _motorState.copyWith(
          leftSpeed: side == 'ESQ' ? spd : 0,
          rightSpeed: side == 'DIR' ? spd : 0,
          direction: spd == 0 ? 'PARADO' : 'MOTOR_$side',
        );
        notifyListeners();
        await _writeCommand(
          side == 'ESQ'
              ? BleConstants.cmdMotorLeft(spd)
              : BleConstants.cmdMotorRight(spd),
          log: log,
        );
      }
      return;
    }
    final maxCap = _speedPercent.clamp(0, 100);
    final scaledSpeed =
        (_speedPercent * _settings.sensitivity).round().clamp(0, maxCap);
    _updateLocalMotorStateForDirection(active, scaledSpeed);
    notifyListeners();
    await _writeCommand(
      BleConstants.movement(active, scaledSpeed),
      log: log,
    );
  }

  @override
  Future<void> setExpression(RobotExpression expr) async {
    _settings = _settings.copyWith(baseExpression: expr);
    unawaited(McQueenSettingsStore.save(_settings));
    if (!isConnected) {
      _expression = expr;
      notifyListeners();
      return;
    }
    if (!_txNotifyEnabled) {
      _expression = expr;
      notifyListeners();
    }
    await _writeCommand(expr.command);
  }

  @override
  Future<void> setSpeedProfile(SpeedProfile profile) async {
    final speed = SpeedLevel.values.firstWhere(
      (l) => l.label.toLowerCase() == profile.name.toLowerCase(),
      orElse: () => SpeedLevel.normal,
    );
    _speedPercent = speed.percent;
    notifyListeners();
    if (!isConnected) return;
    await _writeCommand(profile.bleCommand);
    if (_activeMovement != null) {
      await _sendActiveMovement(log: false);
    }
  }

  @override
  Future<CommandResult> triggerSound(String soundCommand) =>
      _triggerSoundInternal(soundCommand, isSequenceStep: false);

  Future<CommandResult> _triggerSoundInternal(
    String soundCommand, {
    required bool isSequenceStep,
  }) async {
    if (!isConnected) {
      return const CommandResult(
        ok: false,
        error: 'McQueen não está conectado via BLE.',
      );
    }
    if (!isSequenceStep && _isSoundSequenceRunning) {
      _interruptRunningSoundSequence();
      _clearBuzzerActive();
      notifyListeners();
    }

    final upper = soundCommand.trim().toUpperCase();
    final allowWhenMuted = upper == BleConstants.cmdMute ||
        upper == BleConstants.cmdBuzinaDesligar ||
        upper == 'PARAR_BUZZER' ||
        upper.startsWith('SOM:MUTE:');
    if (!_settings.soundsEnabled && !allowWhenMuted) {
      const err = 'Sons silenciados nas configurações.';
      _recordLog('INFO: Som "$upper" bloqueado ($err)', isOutgoing: false);
      return const CommandResult(ok: false, error: err);
    }

    if (!_txNotifyEnabled) {
      final wrote = await _writeCommand(soundCommand);
      if (!wrote) {
        return const CommandResult(
          ok: false,
          error: 'Falha ao enviar comando sonoro via BLE.',
        );
      }
      return const CommandResult(
        ok: false,
        error:
            'Comando enviado, mas o canal TX (NOTIFY) está inativo para confirmar execução.',
      );
    }

    if (_soundAckCompleter != null && !_soundAckCompleter!.isCompleted) {
      _soundAckCompleter!.complete(
        const CommandResult(ok: false, error: 'Substituído por novo comando.'),
      );
    }
    final ackCompleter = Completer<CommandResult>();
    _soundAckCompleter = ackCompleter;

    final wrote = await _writeCommand(soundCommand);
    if (!wrote) {
      if (identical(_soundAckCompleter, ackCompleter)) {
        _soundAckCompleter = null;
      }
      return const CommandResult(
        ok: false,
        error: 'Falha ao escrever comando sonoro na característica BLE.',
      );
    }

    try {
      return await ackCompleter.future.timeout(
        const Duration(milliseconds: 1200),
        onTimeout: () => CommandResult(
          ok: false,
          error: 'ESP32 não respondeu ao comando "$upper".',
        ),
      );
    } finally {
      if (identical(_soundAckCompleter, ackCompleter)) {
        _soundAckCompleter = null;
      }
    }
  }

  Future<void> _waitCancelableSequenceDelay(int ms, int token) async {
    if (ms <= 0 || token != _soundSequenceToken || !isConnected) return;
    final wait = Completer<void>();
    _sequenceWaitCompleter = wait;
    final timer = Timer(Duration(milliseconds: ms), () {
      if (!wait.isCompleted) wait.complete();
    });
    try {
      await wait.future;
    } finally {
      timer.cancel();
      if (identical(_sequenceWaitCompleter, wait)) {
        _sequenceWaitCompleter = null;
      }
    }
  }

  @override
  Future<CommandResult> playTimedBeepSequence({
    required List<BeepStep> steps,
    required String label,
  }) async {
    if (!isConnected) {
      return const CommandResult(
        ok: false,
        error: 'McQueen não está conectado via BLE.',
      );
    }
    if (!_settings.soundsEnabled) {
      return const CommandResult(
        ok: false,
        error: 'Sons silenciados nas configurações.',
      );
    }
    if (steps.isEmpty) {
      return const CommandResult(ok: false, error: 'Sequência vazia.');
    }

    _interruptRunningSoundSequence();
    _buzzerIndicatorTimer?.cancel();
    _buzzerIndicatorTimer = null;

    final token = _soundSequenceToken;
    _isSoundSequenceRunning = true;
    _buzinaSent = true;
    _activeSoundLabel = label;
    notifyListeners();

    try {
      for (var i = 0; i < steps.length; i++) {
        if (token != _soundSequenceToken || !isConnected) {
          return const CommandResult(
            ok: false,
            error: 'Sequência interrompida.',
          );
        }
        final step = steps[i];
        final stepWatch = Stopwatch()..start();
        final res = await _triggerSoundInternal(
          BleConstants.toneCommand(2000, step.onMs),
          isSequenceStep: true,
        );
        if (!res.ok) return res;
        if (token != _soundSequenceToken || !isConnected) {
          return const CommandResult(
            ok: false,
            error: 'Sequência interrompida.',
          );
        }

        final totalStepMs = i + 1 < steps.length
            ? step.onMs + step.gapMs
            : step.onMs;
        final remainingMs =
            (totalStepMs - stepWatch.elapsedMilliseconds).clamp(0, 4000);
        await _waitCancelableSequenceDelay(remainingMs, token);
      }
      return const CommandResult(ok: true, response: 'OK:SEQUENCE');
    } finally {
      if (token == _soundSequenceToken) {
        _isSoundSequenceRunning = false;
        _clearBuzzerActive();
        notifyListeners();
      }
    }
  }

  @override
  Future<void> cancelSoundSequence() async {
    _interruptRunningSoundSequence();
    await stopBuzzer();
  }

  @override
  Future<CommandResult> testCommunication() async {
    if (!isConnected) {
      return const CommandResult(ok: false, error: 'Não conectado.');
    }
    if (!_txNotifyEnabled) {
      final wrote = await _writeCommand(BleConstants.cmdPing);
      return CommandResult(
        ok: false,
        error: wrote
            ? 'PING enviado, porém TX NOTIFY não está ativo para receber PONG.'
            : 'Falha ao enviar PING.',
      );
    }

    final sw = Stopwatch()..start();
    _pingCompleter = Completer<void>();
    final wrote = await _writeCommand(BleConstants.cmdPing);
    if (!wrote) {
      _pingCompleter = null;
      return const CommandResult(ok: false, error: 'Falha ao escrever PING.');
    }
    try {
      await _pingCompleter!.future.timeout(const Duration(milliseconds: 1500));
      sw.stop();
      final rtt = sw.elapsedMilliseconds;
      _diagnostics = _diagnostics.copyWith(lastPingLatencyMs: rtt);
      notifyListeners();
      return CommandResult(ok: true, response: 'PONG', latencyMs: rtt);
    } catch (_) {
      return const CommandResult(
        ok: false,
        error: 'Timeout aguardando PONG do ESP32.',
      );
    } finally {
      _pingCompleter = null;
    }
  }

  @override
  Future<CommandResult> requestDiagnostics() async {
    if (!isConnected) {
      return const CommandResult(ok: false, error: 'Não conectado.');
    }
    if (!_txNotifyEnabled) {
      return const CommandResult(
        ok: false,
        error: 'TX NOTIFY inativo — não é possível ler DIAG.',
      );
    }
    final completer = Completer<String>();
    _diagCompleter = completer;
    final wrote = await _writeCommand(BleConstants.cmdDiag);
    if (!wrote) {
      _diagCompleter = null;
      return const CommandResult(ok: false, error: 'Falha ao enviar DIAG.');
    }
    try {
      final reply =
          await completer.future.timeout(const Duration(milliseconds: 1500));
      return CommandResult(ok: true, response: reply);
    } catch (_) {
      return const CommandResult(
        ok: false,
        error: 'Timeout aguardando DIAG do ESP32.',
      );
    } finally {
      if (identical(_diagCompleter, completer)) _diagCompleter = null;
    }
  }

  @override
  Future<CommandResult> refreshStatus() async {
    if (!isConnected) {
      return const CommandResult(ok: false, error: 'Não conectado.');
    }
    if (!_txNotifyEnabled) {
      return const CommandResult(
        ok: false,
        error: 'TX NOTIFY inativo — não é possível ler STATUS.',
      );
    }
    final completer = Completer<String>();
    _statusCompleter = completer;
    final wrote = await _writeCommand(BleConstants.cmdStatus);
    if (!wrote) {
      _statusCompleter = null;
      return const CommandResult(ok: false, error: 'Falha ao enviar STATUS.');
    }
    try {
      final reply =
          await completer.future.timeout(const Duration(milliseconds: 1500));
      return CommandResult(ok: true, response: reply);
    } catch (_) {
      return const CommandResult(
        ok: false,
        error: 'Timeout aguardando STATUS do ESP32.',
      );
    } finally {
      if (identical(_statusCompleter, completer)) _statusCompleter = null;
    }
  }

  @override
  Future<CommandResult> updateSettings(
    McQueenSettings newSettings, {
    String? syncCommand,
    bool persist = true,
  }) async {
    _settings = newSettings;
    _motorState = _motorState.copyWith(
      leftNeutralUs: newSettings.leftNeutralUs,
      rightNeutralUs: newSettings.rightNeutralUs,
      leftInverted: newSettings.leftInverted,
      rightInverted: newSettings.rightInverted,
    );
    if (persist) {
      await McQueenSettingsStore.save(_settings);
    }
    notifyListeners();
    if (syncCommand == null || syncCommand.isEmpty) {
      return const CommandResult(ok: true);
    }
    if (!isConnected) {
      return const CommandResult(
        ok: false,
        error: 'McQueen não está conectado via BLE.',
      );
    }

    if (!_txNotifyEnabled) {
      final wrote = await _writeCommand(syncCommand);
      return CommandResult(
        ok: wrote,
        error: wrote ? null : 'Falha ao enviar "$syncCommand" via BLE.',
      );
    }

    if (_settingsAckCompleter != null && !_settingsAckCompleter!.isCompleted) {
      _settingsAckCompleter!.complete(
        const CommandResult(ok: false, error: 'Substituído por novo ajuste.'),
      );
    }
    final completer = Completer<CommandResult>();
    _settingsAckCompleter = completer;

    final wrote = await _writeCommand(syncCommand);
    if (!wrote) {
      if (identical(_settingsAckCompleter, completer)) {
        _settingsAckCompleter = null;
      }
      return CommandResult(
        ok: false,
        error: 'Falha ao enviar "$syncCommand" via BLE.',
      );
    }

    // Comandos sem ACK específico no firmware (ex.: AUTO:MASK) retornam após escrita se aplicável.
    try {
      return await completer.future.timeout(
        const Duration(milliseconds: 1200),
        onTimeout: () => CommandResult(
          ok: false,
          error: 'ESP32 não confirmou "$syncCommand" dentro do tempo limite.',
        ),
      );
    } finally {
      if (identical(_settingsAckCompleter, completer)) {
        _settingsAckCompleter = null;
      }
    }
  }

  @override
  Future<void> resetAllSettings() async {
    _settings = const McQueenSettings();
    _speedPercent = _settings.defaultSpeedPercent;
    _expression = _settings.baseExpression;
    _motorState = const MotorState();
    await McQueenSettingsStore.save(_settings);
    notifyListeners();
    if (isConnected) {
      await _writeCommand(BleConstants.cmdCalReset);
      if (_txNotifyEnabled) {
        await refreshStatus();
      }
    }
  }

  void _stopKeepAlive() {
    _movementTimer?.cancel();
    _movementTimer = null;
  }

  void _dropQueuedMatching(bool Function(String cmd) predicate) {
    for (final item in _writeQueue) {
      if (predicate(item.cmd) && !item.completer.isCompleted) {
        item.completer.complete(false);
      }
    }
    _writeQueue.removeWhere((e) => predicate(e.cmd));
  }

  Future<bool> _writeCommand(String cmd, {bool log = true}) {
    if (_rxChar == null || !isConnected) {
      debugPrint('[BLE] Não conectado. Comando "$cmd" ignorado.');
      return Future<bool>.value(false);
    }

    final completer = Completer<bool>();
    final upper = cmd.trim().toUpperCase();
    if (BleConstants.isStopCommand(cmd)) {
      _dropQueuedMatching(BleConstants.isMovementCommand);
      if (_writeQueue.isNotEmpty &&
          BleConstants.isStopCommand(_writeQueue.first.cmd)) {
        return _writeQueue.first.completer.future;
      }
      _writeQueue.insert(0, (cmd: cmd, log: log, completer: completer));
    } else if (BleConstants.isMovementCommand(cmd)) {
      _dropQueuedMatching(BleConstants.isMovementCommand);
      _writeQueue.add((cmd: cmd, log: log, completer: completer));
    } else if (upper.startsWith('SETA:')) {
      _dropQueuedMatching((c) => c.trim().toUpperCase().startsWith('SETA:'));
      _writeQueue.add((cmd: cmd, log: log, completer: completer));
    } else if (upper.startsWith('VEL:') ||
        upper.startsWith(BleConstants.cmdSpeedPrefix) ||
        upper.startsWith('SPEED_PROFILE:')) {
      _dropQueuedMatching((c) {
        final u = c.trim().toUpperCase();
        return u.startsWith('VEL:') ||
            u.startsWith(BleConstants.cmdSpeedPrefix) ||
            u.startsWith('SPEED_PROFILE:');
      });
      _writeQueue.add((cmd: cmd, log: log, completer: completer));
    } else {
      if (_writeQueue.length >= 8) {
        final idx = _writeQueue.indexWhere((e) => !BleConstants.isStopCommand(e.cmd));
        if (idx >= 0) {
          final dropped = _writeQueue.removeAt(idx);
          if (!dropped.completer.isCompleted) {
            dropped.completer.complete(false);
          }
        }
      }
      _writeQueue.add((cmd: cmd, log: log, completer: completer));
    }

    if (!_isWriting) {
      unawaited(_drainWriteQueue());
    }
    return completer.future;
  }

  Future<void> _drainWriteQueue() async {
    if (_isWriting) return;
    _isWriting = true;
    try {
      while (_writeQueue.isNotEmpty && _rxChar != null && isConnected) {
        final next = _writeQueue.removeAt(0);
        try {
          _diagnostics = _diagnostics.copyWith(
            lastTxCommand: next.cmd,
            lastTxAt: DateTime.now(),
          );
          if (next.log) {
            _recordLog('TX → ${next.cmd}', isOutgoing: true);
          }
          final withoutResponse = _rxChar!.properties.writeWithoutResponse;
          await _rxChar!.write(
            utf8.encode(next.cmd),
            withoutResponse: withoutResponse,
          );
          if (!next.completer.isCompleted) {
            next.completer.complete(true);
          }
        } catch (e) {
          debugPrint('[BLE] Erro ao enviar "${next.cmd}": $e');
          _diagnostics = _diagnostics.copyWith(lastError: e.toString());
          _recordLog('ERR: Falha ao enviar "${next.cmd}" ($e)',
              isOutgoing: true, isSuccess: false);
          if (!next.completer.isCompleted) {
            next.completer.complete(false);
          }
          final errStr = e.toString().toLowerCase();
          if (errStr.contains('disconnected') ||
              errStr.contains('not connected')) {
            _onDisconnected();
            break;
          }
        }
      }
    } finally {
      for (final remaining in _writeQueue) {
        if (!remaining.completer.isCompleted) {
          remaining.completer.complete(false);
        }
      }
      if (!isConnected) {
        _writeQueue.clear();
      }
      _isWriting = false;
    }
  }

  @override
  Future<CommandResult> sendBuzina() => triggerSound(BleConstants.cmdBuzina);

  @override
  Future<void> stopBuzzer() async {
    _interruptRunningSoundSequence();
    _clearBuzzerActive();
    notifyListeners();
    if (isConnected) {
      await _writeCommand(BleConstants.cmdBuzinaDesligar);
    }
  }

  @override
  Future<void> setTurnSignal(TurnSignalState signal) async {
    if (!isConnected) return;
    if (!_txNotifyEnabled) {
      _turnSignal = signal;
      notifyListeners();
    }
    await _writeCommand(signal.command);
  }

  @override
  Future<void> toggleAutoTurnSignals() async {
    if (!isConnected) return;
    await _writeCommand(BleConstants.cmdSetaAuto);
  }

  @override
  Future<void> joystickControl({required int left, required int right}) async {
    if (!isConnected) return;

    _activeMovement = null;
    _stopKeepAlive();

    final maxCap = _speedPercent.clamp(0, 100);
    final scaledLeft =
        (left * _settings.sensitivity).round().clamp(-maxCap, maxCap);
    final scaledRight =
        (right * _settings.sensitivity).round().clamp(-maxCap, maxCap);

    final dirLabel = _directionLabelFor(scaledLeft, scaledRight);
    _motorState = _motorState.copyWith(
      leftSpeed: scaledLeft,
      rightSpeed: scaledRight,
      direction: dirLabel,
    );
    notifyListeners();

    final packet = BleConstants.diff(scaledLeft, scaledRight);
    await _writeCommand(packet, log: packet == BleConstants.cmdParar);
  }

  String _directionLabelFor(int left, int right) {
    if (left == 0 && right == 0) return 'PARADO';
    if (left > 0 && right > 0) {
      if ((left - right).abs() <= 15) return 'FRENTE';
      return left > right ? 'DIREITA' : 'ESQUERDA';
    }
    if (left < 0 && right < 0) {
      if ((left - right).abs() <= 15) return 'TRAS';
      return left < right ? 'ESQUERDA' : 'DIREITA';
    }
    return left < right ? 'ESQUERDA' : 'DIREITA';
  }

  @override
  Future<void> stopJoystick() async {
    _activeMovement = null;
    _stopKeepAlive();
    _motorState = _motorState.copyWith(
        leftSpeed: 0, rightSpeed: 0, direction: 'PARADO');
    notifyListeners();
    if (isConnected) {
      await _writeCommand(BleConstants.cmdParar);
    }
  }

  @override
  Future<void> emergencyStop() async {
    _emergencyStopCount++;
    await stopJoystick();
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────
  void _recordLog(String msg,
      {required bool isOutgoing, bool isSuccess = true}) {
    _commandLogs.insert(
      0,
      CommandLogEntry(
        timestamp: DateTime.now(),
        message: msg,
        isOutgoing: isOutgoing,
        isSuccess: isSuccess,
      ),
    );
    if (_commandLogs.length > 80) {
      _commandLogs.removeLast();
    }
    notifyListeners();
  }

  void _setState(RobotConnectionState s) {
    _state = s;
    notifyListeners();
  }

  void _setStatus(String s) {
    _lastStatus = s;
    notifyListeners();
  }

  bool _isDisposed = false;

  @override
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _cleanupConnection();
    _connectionEvents.close();
    super.dispose();
  }
}
