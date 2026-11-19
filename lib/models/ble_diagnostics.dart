// lib/models/ble_diagnostics.dart
import '../core/ble_constants.dart';

/// Instantâneo imutável do estado técnico de comunicação BLE para diagnóstico.
class BleDiagnostics {
  final String? deviceName;
  final String? deviceId;
  final String serviceUuid;
  final String rxCharUuid;
  final String txCharUuid;
  final bool serviceValidated;
  final bool rxCanWrite;
  final bool rxCanWriteWithoutResponse;
  final bool txNotifyEnabled;
  final String? lastTxCommand;
  final DateTime? lastTxAt;
  final String? lastRxResponse;
  final DateTime? lastRxAt;
  final String? lastError;
  final int? lastPingLatencyMs;
  final String? lastDiagRaw;
  final bool? diagAdvertising;
  final bool? diagConnected;
  final bool? diagReady;
  final int? diagAdvPayloadBytes;
  final bool? diagServosEnabled;
  final DateTime? lastStatusSyncAt;

  const BleDiagnostics({
    this.deviceName,
    this.deviceId,
    this.serviceUuid = BleConstants.serviceUuid,
    this.rxCharUuid = BleConstants.charRxUuid,
    this.txCharUuid = BleConstants.charTxUuid,
    this.serviceValidated = false,
    this.rxCanWrite = false,
    this.rxCanWriteWithoutResponse = false,
    this.txNotifyEnabled = false,
    this.lastTxCommand,
    this.lastTxAt,
    this.lastRxResponse,
    this.lastRxAt,
    this.lastError,
    this.lastPingLatencyMs,
    this.lastDiagRaw,
    this.diagAdvertising,
    this.diagConnected,
    this.diagReady,
    this.diagAdvPayloadBytes,
    this.diagServosEnabled,
    this.lastStatusSyncAt,
  });

  String get rxWriteModeLabel {
    if (!rxCanWrite && !rxCanWriteWithoutResponse) return 'Indisponível';
    final modes = <String>[];
    if (rxCanWriteWithoutResponse) modes.add('WRITE_NR');
    if (rxCanWrite) modes.add('WRITE');
    return modes.join(' | ');
  }

  BleDiagnostics copyWith({
    String? deviceName,
    bool clearDevice = false,
    String? deviceId,
    String? serviceUuid,
    String? rxCharUuid,
    String? txCharUuid,
    bool? serviceValidated,
    bool? rxCanWrite,
    bool? rxCanWriteWithoutResponse,
    bool? txNotifyEnabled,
    String? lastTxCommand,
    DateTime? lastTxAt,
    String? lastRxResponse,
    DateTime? lastRxAt,
    String? lastError,
    bool clearError = false,
    int? lastPingLatencyMs,
    String? lastDiagRaw,
    bool? diagAdvertising,
    bool? diagConnected,
    bool? diagReady,
    int? diagAdvPayloadBytes,
    bool? diagServosEnabled,
    DateTime? lastStatusSyncAt,
  }) {
    return BleDiagnostics(
      deviceName: clearDevice ? null : (deviceName ?? this.deviceName),
      deviceId: clearDevice ? null : (deviceId ?? this.deviceId),
      serviceUuid: serviceUuid ?? this.serviceUuid,
      rxCharUuid: rxCharUuid ?? this.rxCharUuid,
      txCharUuid: txCharUuid ?? this.txCharUuid,
      serviceValidated: serviceValidated ?? this.serviceValidated,
      rxCanWrite: rxCanWrite ?? this.rxCanWrite,
      rxCanWriteWithoutResponse:
          rxCanWriteWithoutResponse ?? this.rxCanWriteWithoutResponse,
      txNotifyEnabled: txNotifyEnabled ?? this.txNotifyEnabled,
      lastTxCommand: lastTxCommand ?? this.lastTxCommand,
      lastTxAt: lastTxAt ?? this.lastTxAt,
      lastRxResponse: lastRxResponse ?? this.lastRxResponse,
      lastRxAt: lastRxAt ?? this.lastRxAt,
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastPingLatencyMs: lastPingLatencyMs ?? this.lastPingLatencyMs,
      lastDiagRaw: lastDiagRaw ?? this.lastDiagRaw,
      diagAdvertising: diagAdvertising ?? this.diagAdvertising,
      diagConnected: diagConnected ?? this.diagConnected,
      diagReady: diagReady ?? this.diagReady,
      diagAdvPayloadBytes: diagAdvPayloadBytes ?? this.diagAdvPayloadBytes,
      diagServosEnabled: diagServosEnabled ?? this.diagServosEnabled,
      lastStatusSyncAt: lastStatusSyncAt ?? this.lastStatusSyncAt,
    );
  }
}
