// Confine tra la sessione e il server Minecraft: il processo (avviato dal
// guard nel prodotto, finto nei test) e il riconoscimento delle righe della
// console. La sessione dipende solo da queste interfacce.

/// Una riga della console del server.
final class ServerLine {
  const ServerLine(this.text, {this.stderr = false, required this.at});
  final String text;
  final bool stderr;
  final DateTime at;
}

/// Come è finito il processo del server.
final class ServerEnd {
  const ServerEnd({this.exitCode, this.reason = 'exited'});
  final int? exitCode;
  final String reason;
}

/// Il processo del server in esecuzione.
abstract interface class ServerProcess {
  /// Ogni riga, in ordine.
  Stream<ServerLine> get lines;

  /// Invia un comando sulla console.
  Future<void> send(String command);

  /// Arresto pulito: `stop` sulla console, uccisione dopo la tolleranza.
  Future<void> stop();

  /// Uccisione immediata dell'intero albero di processi.
  Future<void> kill();

  Future<ServerEnd> get exit;
  bool get running;
}

/// Avvia il server (una volta per avvio e per ogni riavvio dopo un crash).
typedef ServerLauncher = Future<ServerProcess> Function();

/// Fatti riconosciuti nelle righe della console.
sealed class ServerFact {
  const ServerFact();
}

final class FactStarted extends ServerFact {
  const FactStarted();
}

final class FactJoined extends ServerFact {
  const FactJoined(this.name);
  final String name;
}

final class FactLeft extends ServerFact {
  const FactLeft(this.name);
  final String name;
}

/// "Saved the game": il salvataggio chiesto con `save-all flush` è finito.
final class FactSaved extends ServerFact {
  const FactSaved();
}

final class FactStopping extends ServerFact {
  const FactStopping();
}

/// Riconosce i fatti di una riga; null per tutto il resto (chat compresa).
typedef LineParser = ServerFact? Function(String line);
