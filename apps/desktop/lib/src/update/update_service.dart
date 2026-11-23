// Aggiornamento silenzioso e firmato dall'hub. Funziona solo quando l'app è
// avviata dal launcher (che passa MINESYNC_ROOT e MINESYNC_VERSION) e la
// build incorpora la chiave pubblica di firma:
//   flutter build <os> --dart-define=MINESYNC_UPDATE_PUBKEY=<base64 di 32 byte>
// Altrimenti (sviluppo, build senza chiave) non fa niente.
//
// Il manifest si legge da <hub>/dl/update/<platform>/manifest.json con la
// firma in manifest.json.sig; la firma si verifica prima di scaricare
// altro. La versione nuova viene estratta accanto alle altre e segnata
// "pending"; parte al riavvio (exit 75 → il launcher la avvia in prova).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:minesync_launcher/update.dart';

import '../platform/platform.dart';

/// Chiave pubblica ed25519 (base64) incorporata in compilazione.
const updatePublicKey = String.fromEnvironment('MINESYNC_UPDATE_PUBKEY');

final class HubUpdateService extends ChangeNotifier implements UpdateService {
  HubUpdateService({
    required Map<String, String> env,
    this.pubKey = updatePublicKey,
    String? platform,
    void Function(int code)? exit,
    void Function(String)? log,
  }) : root = env['MINESYNC_ROOT'],
       version = env['MINESYNC_VERSION'],
       platform = platform ?? currentPlatform(),
       _exit = exit ?? _exitProcess,
       _log = log ?? ((s) => debugPrint('[update] $s'));

  /// Cartella dell'installazione gestita dal launcher, o null.
  final String? root;

  /// Versione in esecuzione (dal launcher), o null.
  final String? version;
  final String pubKey;
  final String platform;
  final void Function(int) _exit;
  final void Function(String) _log;

  static void _exitProcess(int code) => exit(code);

  /// Se gli aggiornamenti sono possibili per questa esecuzione.
  bool get managed =>
      root != null && version != null && pubKey.isNotEmpty && SemVer.tryParse(version!) != null;

  String? _ready;
  @override
  String? get ready => _ready;

  /// Ultimo errore (firma, hash, rete), per la diagnostica.
  Object? lastError;

  Future<void>? _running;

  /// Chiamato prima di uscire per il riavvio (si toglie l'icona dalla barra
  /// di sistema, che su Windows altrimenti resta come fantasma).
  Future<void> Function()? beforeRestart;

  @override
  Future<void> check(Uri hub) {
    if (!managed) return Future.value();
    // Un controllo alla volta: se ne arriva un altro mentre scarica, aspetta.
    return _running ??= _check(hub).whenComplete(() => _running = null);
  }

  Future<void> _check(Uri hub) async {
    final inst = Install(root!);
    try {
      // Già pronta da un controllo precedente (anche di un'esecuzione prima).
      final pend = (await inst.readState()).pending;
      if (pend != null && isNewer(pend, version!)) return _setReady(pend);
      final dir = hub.path.endsWith('/') ? hub : hub.replace(path: '${hub.path}/');
      final base = dir.resolve('dl/');
      final (outcome, v) = await Stager(
        inst,
        version!,
        pubKey,
        platform: platform,
        log: _log,
      ).checkAndStage(base);
      lastError = null;
      if (outcome == UpdateOutcome.staged || outcome == UpdateOutcome.alreadyStaged) {
        _setReady(v);
      }
    } on Object catch (e) {
      // Silenzioso: nessun aggiornamento è meglio di un errore in faccia.
      lastError = e;
      _log('controllo non riuscito: $e');
    }
  }

  void _setReady(String v) {
    if (_ready == v) return;
    _ready = v;
    _log('$v pronta per il riavvio');
    notifyListeners();
  }

  /// Esce col codice che chiede al launcher di riavviare nella versione
  /// nuova. Chi chiama controlla prima che non ci sia una sessione in corso.
  @override
  Future<void> restart() async {
    if (_ready == null) return;
    try {
      await beforeRestart?.call();
    } on Object catch (e) {
      _log('pulizia prima del riavvio: $e');
    }
    _exit(exitRestart);
  }
}

/// Scrive il marker "partita bene" per il launcher: va chiamato dopo il
/// primo frame disegnato. Non dipende dall'hub: chi è offline non deve
/// tornare alla versione di prima.
Future<void> markHealthy(Map<String, String> env) async {
  final path = env['MINESYNC_HEALTH_FILE'];
  final v = env['MINESYNC_VERSION'];
  if (path == null || v == null) return;
  final f = File(path);
  await f.parent.create(recursive: true);
  final tmp = File('$path.tmp');
  await tmp.writeAsString(v, flush: true);
  await tmp.rename(path);
}
