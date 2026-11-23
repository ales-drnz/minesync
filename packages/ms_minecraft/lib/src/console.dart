// Lettura della console del server: dalle righe di log ai fatti che guidano
// la sessione (avvio completato, giocatori, salvataggio, spegnimento).
//
// Regola di fondo: un fatto si riconosce SOLO come corpo di una riga di log
// di sistema, mai dal testo libero. La chat arriva sulla stessa console e i
// giocatori la controllano: "<Bob> Saved the game", "/say", "/me", oggetti
// rinominati nei messaggi di morte, mod di chat che riformattano i nomi.
// Un falso "salvato" farebbe partire lo snapshot a mondo ancora in scrittura,
// un falso "left the game" farebbe scattare l'arresto automatico a server
// pieno.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// Fatto riconosciuto in una riga di console.
sealed class ConsoleFact {
  const ConsoleFact();
}

/// Avvio completato ("Done (12.3s)! For help, type "help"").
final class ServerStarted extends ConsoleFact {
  const ServerStarted();

  @override
  bool operator ==(Object other) => other is ServerStarted;

  @override
  int get hashCode => (ServerStarted).hashCode;

  @override
  String toString() => 'ServerStarted()';
}

/// Un giocatore è entrato.
final class PlayerJoined extends ConsoleFact {
  const PlayerJoined(this.name);

  final String name;

  @override
  bool operator ==(Object other) => other is PlayerJoined && other.name == name;

  @override
  int get hashCode => Object.hash(PlayerJoined, name);

  @override
  String toString() => 'PlayerJoined($name)';
}

/// Un giocatore è uscito.
final class PlayerLeft extends ConsoleFact {
  const PlayerLeft(this.name);

  final String name;

  @override
  bool operator ==(Object other) => other is PlayerLeft && other.name == name;

  @override
  int get hashCode => Object.hash(PlayerLeft, name);

  @override
  String toString() => 'PlayerLeft($name)';
}

/// Il server conferma che il mondo è stato scritto su disco ("Saved the game").
final class SaveConfirmed extends ConsoleFact {
  const SaveConfirmed();

  @override
  bool operator ==(Object other) => other is SaveConfirmed;

  @override
  int get hashCode => (SaveConfirmed).hashCode;

  @override
  String toString() => 'SaveConfirmed()';
}

/// Salvataggio in corso: su un mondo grande arrivano righe per minuti, e
/// dicono che il server lavora invece di essersi piantato.
final class SavingStarted extends ConsoleFact {
  const SavingStarted();

  @override
  bool operator ==(Object other) => other is SavingStarted;

  @override
  int get hashCode => (SavingStarted).hashCode;

  @override
  String toString() => 'SavingStarted()';
}

/// Inizio dello spegnimento.
final class ServerStopping extends ConsoleFact {
  const ServerStopping();

  @override
  bool operator ==(Object other) => other is ServerStopping;

  @override
  int get hashCode => (ServerStopping).hashCode;

  @override
  String toString() => 'ServerStopping()';
}

/// Il server rifiuta di partire perché l'EULA non è accettata: senza questo
/// fatto l'uscita immediata sembrerebbe un crash.
final class EulaRequired extends ConsoleFact {
  const EulaRequired();

  @override
  bool operator ==(Object other) => other is EulaRequired;

  @override
  int get hashCode => (EulaRequired).hashCode;

  @override
  String toString() => 'EulaRequired()';
}

/// Riga di log scomposta: thread (null nel formato Paper, che non lo
/// stampa), livello e corpo del messaggio.
typedef _LogLine = ({String? thread, String level, String body});

// Formati delle righe di log in circolazione:
//
//   [12:00:00] [Server thread/INFO]: corpo                                vanilla, Fabric
//   [Server thread/INFO]: corpo                                           senza orario
//   [12:00:00] [Server thread/INFO] [minecraft/MinecraftServer]: corpo    Forge
//   [29Jan2024 12:00:00.123] [Server thread/INFO] [net.minecraft…/]: corpo NeoForge
//   [12:00:00] [Server thread/INFO] (Minecraft) corpo                     Fabric/Quilt
//   [12:00:00 INFO]: corpo                                                Paper/Spigot
//
// L'eventuale "> " davanti è il prompt della console jline.
final _threadFormat = RegExp(
  r'^(?:>\s*)*(?:\[[^\]\[]*\] )?\[([^\]\[/]+)/([A-Z]+)\]'
  r'(?: \[[A-Za-z0-9_.$/\-]*\]:| \([A-Za-z0-9_.$\- ]*\)|:) (.*)$',
);
final _paperFormat = RegExp(r'^(?:>\s*)*\[\d{1,2}:\d{2}:\d{2} ([A-Z]+)\]: (.*)$');

// Sequenze ANSI (colori di Paper e di jline): la chat non può contenere il
// carattere ESC, quindi toglierle non apre nessuna falsificazione.
final _ansi = RegExp('\x1B\\[[0-9;?]*[A-Za-z]');

const _serverThread = 'Server thread';

_LogLine? _split(String line) {
  var l = line;
  if (l.contains('\x1B')) l = l.replaceAll(_ansi, '');
  while (l.endsWith('\r') || l.endsWith('\n')) {
    l = l.substring(0, l.length - 1);
  }
  final m = _threadFormat.firstMatch(l);
  if (m != null) return (thread: m.group(1), level: m.group(2)!, body: m.group(3)!);
  final p = _paperFormat.firstMatch(l);
  if (p != null) return (thread: null, level: p.group(1)!, body: p.group(2)!);
  return null;
}

/// Corpi ESATTI con cui il server conferma il salvataggio (vanilla,
/// Forge/NeoForge, Paper/Spigot, Bukkit vecchi).
const _savedBodies = {
  'Saved the game',
  'Saved the game.',
  'All dimensions are saved',
  'ThreadedAnvilChunkStorage: All dimensions are saved',
  'Saved the world',
  'Saved the world.',
};

const _stoppingBodies = {'Stopping server', 'Stopping the server'};

// Nome del giocatore: nick Java ([A-Za-z0-9_], fino a 16) oppure Bedrock
// tramite Geyser/Floodgate, che antepone un punto. Niente spazi, parentesi,
// asterischi o separatori: sono proprio i caratteri con cui /say, /me e i
// mod di chat costruiscono le righe falsificate.
final _playerEvent = RegExp(r'^(\.?[A-Za-z0-9_]{1,16}) (joined|left) the game$');

final _done = RegExp(r'^Done \(\d+(?:[.,]\d+)?m?s\)!(?: |$)');

final _saving = RegExp(
  r'^(?:Saving chunks for level |Saving the game|Saving players$|Saving worlds$'
  r'|ThreadedAnvilChunkStorage(?: \([^)]*\))?: All chunks are saved$)',
);

/// Riconosce il fatto contenuto in una riga di console, o null per la chat
/// e per tutto il resto. Pura e senza stato: la regola del flush in attesa
/// (B-SESSION-15) la applica [ConsoleTracker].
ConsoleFact? parseConsoleLine(String line) {
  final log = _split(line);
  if (log == null) return null;
  final body = log.body;
  final thread = log.thread;

  // EULA: in quasi tutte le versioni la stampa il thread "main", prima che
  // il thread del server esista. Il corpo deve comunque aprire la riga.
  if ((log.level == 'INFO' || log.level == 'WARN') &&
      body.startsWith('You need to agree to the EULA in order to run the server')) {
    return const EulaRequired();
  }

  if (log.level != 'INFO') return null;
  if (thread != null && thread != _serverThread) return null;
  // La chat 1.19+ non firmata e la chat classica: mai fatti di sistema.
  if (body.startsWith('<') || body.startsWith('[Not Secure]')) return null;

  final trimmed = body.trimRight();
  if (_savedBodies.contains(trimmed)) return const SaveConfirmed();
  if (_stoppingBodies.contains(trimmed)) return const ServerStopping();
  if (_done.hasMatch(body)) return const ServerStarted();
  if (_saving.hasMatch(trimmed)) return const SavingStarted();
  final p = _playerEvent.firstMatch(trimmed);
  if (p != null) {
    final name = p.group(1)!;
    return p.group(2) == 'joined' ? PlayerJoined(name) : PlayerLeft(name);
  }
  return null;
}

/// Lunghezza oltre la quale una riga di console viene troncata.
const int maxConsoleLine = 64 * 1024;

/// Suffisso aggiunto alle righe troncate.
const String truncatedMarker = ' […]';

/// Tronca una riga più lunga di [maxConsoleLine] unità (B-SESSION-16).
/// Righe chilometriche le producono davvero i dump del classpath di
/// ModLauncher e certi mod che stampano un NBT intero.
String truncateConsoleLine(String line) {
  if (line.length <= maxConsoleLine) return line;
  var end = maxConsoleLine;
  // non spezzare una coppia surrogata
  final last = line.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return line.substring(0, end) + truncatedMarker;
}

/// Spezza lo stdout/stderr del server in righe, con memoria limitata: una
/// riga oltre [maxBytes] byte viene troncata e la lettura continua, così la
/// pipe resta drenata e la riga successiva arriva intatta (B-SESSION-16).
/// Smettere di leggere bloccherebbe java sulla write, a server congelato
/// senza un messaggio d'errore. I byte non UTF-8 (console Windows) non
/// interrompono nulla: diventano U+FFFD.
final class ConsoleLineSplitter extends StreamTransformerBase<List<int>, String> {
  const ConsoleLineSplitter({this.maxBytes = maxConsoleLine});

  final int maxBytes;

  @override
  Stream<String> bind(Stream<List<int>> stream) {
    return Stream<String>.eventTransformed(stream, (sink) => _SplitterSink(sink, maxBytes));
  }
}

final class _SplitterSink implements EventSink<List<int>> {
  _SplitterSink(this._out, this._max);

  final EventSink<String> _out;
  final int _max;
  final BytesBuilder _buf = BytesBuilder(copy: true);
  bool _truncated = false;

  @override
  void add(List<int> data) {
    var start = 0;
    for (var i = 0; i < data.length; i++) {
      if (data[i] != 0x0A) continue;
      _append(data, start, i);
      _emit();
      start = i + 1;
    }
    _append(data, start, data.length);
  }

  void _append(List<int> data, int start, int end) {
    if (start >= end) return;
    final room = _max - _buf.length;
    if (room <= 0) {
      _truncated = true;
      return;
    }
    if (end - start > room) {
      _truncated = true;
      end = start + room;
    }
    _buf.add(data.sublist(start, end));
  }

  void _emit() {
    var line = utf8.decode(_buf.takeBytes(), allowMalformed: true);
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    if (_truncated) line += truncatedMarker;
    _truncated = false;
    _out.add(line);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _out.addError(error, stackTrace);

  @override
  void close() {
    // ultima riga senza newline finale
    if (_buf.length > 0 || _truncated) _emit();
    _out.close();
  }
}

/// Coda dei fatti della console con la regola della conferma di
/// salvataggio: [SaveConfirmed] diventa un fatto solo mentre c'è un
/// `save-all flush` in attesa, e una volta sola per flush (B-SESSION-15).
/// I fatti restano in coda anche se nessuno legge le righe e si svuotano
/// con [drain] (B-SESSION-17): perdere "Done" fra le decine di migliaia di
/// righe dell'avvio di un modpack voleva dire non avere più un autosave.
final class ConsoleTracker {
  final List<ConsoleFact> _queue = [];
  bool _savePending = false;

  /// C'è un `save-all flush` di cui si aspetta la conferma.
  bool get savePending => _savePending;

  /// Da chiamare subito dopo aver inviato `save-all flush`.
  void expectSave() => _savePending = true;

  /// Classifica [line], accoda e restituisce il fatto (null se non conta).
  ConsoleFact? feed(String line) {
    final fact = parseConsoleLine(line);
    if (fact == null) return null;
    if (fact is SaveConfirmed) {
      if (!_savePending) return null;
      _savePending = false;
    }
    _queue.add(fact);
    return fact;
  }

  /// Restituisce i fatti accumulati e svuota la coda.
  List<ConsoleFact> drain() {
    final out = List<ConsoleFact>.of(_queue);
    _queue.clear();
    return out;
  }
}
