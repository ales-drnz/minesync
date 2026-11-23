// Stato locale di un server su questo PC: cartella collegata, versione da
// cui parte la copia locale, server Minecraft trovato nella cartella, Java,
// spazio libero; e le azioni di sincronizzazione (scarica, carica,
// verifica) con l'avanzamento. Le schermate leggono questo oggetto e ne
// chiamano i metodi: niente IO e niente hub direttamente dai widget.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:ms_protocol/ms_protocol.dart';

import 'app_state.dart';

/// Versione dell'app nelle informazioni del lock.
const desktopClient = 'minesync-desktop/0.1.0';

// --- sonde sul PC -----------------------------------------------------------------

/// Cosa c'è in una cartella locale.
final class LocalScan {
  const LocalScan({this.exists = false, this.layout, this.mods = 0, this.disk});

  /// La cartella esiste.
  final bool exists;

  /// Server Minecraft trovato (null se la cartella non c'è).
  final ServerLayout? layout;

  /// Numero di mod (jar in `mods/`).
  final int mods;

  /// Spazio del disco che contiene la cartella (o la sua prima antenata
  /// esistente).
  final DiskSpace? disk;
}

/// Letture del PC (file system, Java, file manager), fuori dal thread
/// dell'interfaccia. Sostituibile nei test.
class LocalProbe {
  const LocalProbe();

  /// Fotografa la cartella [folder] in un isolate.
  Future<LocalScan> scan(String folder) => Isolate.run(() => scanFolder(folder));

  /// Spazio del disco che ospiterà [path].
  Future<DiskSpace?> disk(String path) => Isolate.run(() => diskOf(path));

  /// Runtime Java installati (e quelli dentro [serverRoot]).
  Future<List<JavaRuntime>> java({String? serverRoot}) =>
      Isolate.run(() => findJavaRuntimes(serverRoot: serverRoot));

  /// Apre [folder] nel file manager del sistema.
  Future<void> openFolder(String folder) async {
    final (cmd, args) = Platform.isWindows
        ? ('explorer', [folder])
        : Platform.isMacOS
        ? ('open', [folder])
        : ('xdg-open', [folder]);
    await Process.start(cmd, args, mode: ProcessStartMode.detached);
  }

  /// Lettura sincrona di [folder] (gira dentro l'isolate).
  static LocalScan scanFolder(String folder) {
    final exists = Directory(folder).existsSync();
    if (!exists) return LocalScan(disk: diskOf(folder));
    final layout = detectServer(folder);
    var mods = 0;
    final modsDir = Directory('${layout.workDir}${Platform.pathSeparator}mods');
    if (modsDir.existsSync()) {
      for (final e in modsDir.listSync(followLinks: false)) {
        if (e is File && e.path.toLowerCase().endsWith('.jar')) mods++;
      }
    }
    return LocalScan(exists: true, layout: layout, mods: mods, disk: diskOf(folder));
  }

  /// Spazio del volume di [path], risalendo alla prima cartella esistente.
  static DiskSpace? diskOf(String path) {
    var d = Directory(path).absolute;
    for (var i = 0; i < 64 && !d.existsSync(); i++) {
      final up = d.parent;
      if (up.path == d.path) break;
      d = up;
    }
    try {
      return diskSpace(d.path);
    } on Object {
      return null;
    }
  }
}

// --- avanzamento e risultati --------------------------------------------------------

/// Operazione su una copia locale.
enum SpaceOp { pull, push, verify }

/// Avanzamento di un'operazione in corso.
@immutable
final class Transfer {
  const Transfer({
    required this.op,
    required this.phase,
    this.done = 0,
    this.total = 0,
    this.files = 0,
    this.totalFiles = 0,
    this.bytesPerSecond,
    this.background = false,
    this.target,
  });

  final SpaceOp op;

  /// `start`, `scan`, `download`, `upload`, `commit`, `verify`.
  final String phase;
  final int done;
  final int total;
  final int files;
  final int totalFiles;

  /// Velocità media recente, null finché non si sa.
  final double? bytesPerSecond;

  /// Pre-scarico automatico (nessuno lo sta aspettando).
  final bool background;

  /// Versione verso cui si scarica, se nota.
  final int? target;

  /// Frazione completata (0..1), null se indeterminata.
  double? get fraction => total > 0 ? (done / total).clamp(0.0, 1.0) : null;

  /// Tempo che manca, se si può stimare.
  Duration? get eta {
    final v = bytesPerSecond;
    if (v == null || v <= 0 || total <= 0) return null;
    return Duration(milliseconds: ((total - done).clamp(0, total) / v * 1000).round());
  }
}

/// Esito dell'ultima operazione, da mostrare finché l'utente non lo chiude.
sealed class SpaceOutcome {
  const SpaceOutcome();
}

final class PullDone extends SpaceOutcome {
  const PullDone(this.result, {this.background = false});
  final PullResult result;
  final bool background;
}

final class PushDone extends SpaceOutcome {
  const PushDone(this.result);
  final PushResult result;
}

final class VerifyDone extends SpaceOutcome {
  const VerifyDone(this.files, this.diff);

  /// File controllati.
  final int files;

  /// Differenze dall'ultima sincronizzazione (vuote se è tutto a posto).
  final ManifestDiff diff;
}

final class OpFailed extends SpaceOutcome {
  const OpFailed(this.op, this.error, {this.background = false});
  final SpaceOp op;

  /// [SyncException], [HubUnreachable], [ApiError] o altro.
  final Object error;
  final bool background;
}

/// Cosa manca alla copia locale per arrivare alla testa dell'hub.
@immutable
final class PendingDownload {
  const PendingDownload({
    required this.from,
    required this.to,
    required this.files,
    required this.bytes,
  });

  /// Versione locale (0 = mai sincronizzata).
  final int from;
  final int to;
  final int files;
  final int bytes;
}

/// Differenze di una versione rispetto a quella da cui parte.
@immutable
final class GenerationDiff {
  const GenerationDiff({
    required this.n,
    required this.parent,
    required this.files,
    required this.size,
    required this.added,
    required this.changed,
    required this.removed,
  });

  final int n;
  final int parent;
  final int files;
  final int size;

  /// Percorso → dimensione (per i rimossi, quella che avevano).
  final List<(String, int)> added;
  final List<(String, int)> changed;
  final List<(String, int)> removed;
}

// --- stato di un server -----------------------------------------------------------

final class SpaceState extends ChangeNotifier {
  SpaceState(this.app, this.id);

  final AppState app;

  /// Id dello spazio.
  final String id;

  bool _disposed = false;
  bool _loaded = false;
  bool _loading = false;

  /// Le informazioni locali sono state lette almeno una volta.
  bool get loaded => _loaded;

  /// Cartella collegata, o null.
  String? get folder => app.folderOf(id);
  bool get linked => folder != null;

  /// Cartella proposta se non è collegata.
  String get suggestedFolder => app.defaultFolderFor(id);

  SpaceSummary? get summary => app.space(id);

  int? _baseN;

  /// Versione da cui parte la copia locale (null = mai sincronizzata).
  int? get baseN => _baseN;

  LocalScan _scan = const LocalScan();
  LocalScan get scan => _scan;
  ServerLayout? get layout => _scan.layout;

  PendingDownload? _pending;

  /// Cosa manca per arrivare alla testa (null se aggiornata o non si sa).
  PendingDownload? get pending => _pending;

  /// La copia locale è alla testa dell'hub.
  bool get upToDate {
    final head = summary?.headN ?? 0;
    return linked && (_baseN ?? 0) == head && (_baseN != null || head == 0);
  }

  // --- Java -----------------------------------------------------------------------

  List<JavaRuntime>? _javas;
  bool _javaLoading = false;

  /// Runtime trovati (null finché la ricerca non è finita).
  List<JavaRuntime>? get javas => _javas;
  bool get javaLoading => _javaLoading;

  /// Major richiesto dal server (0 = non si sa).
  int get requiredJava => layout?.requiredJavaMajor ?? 0;

  /// Runtime scelto: quello impostato per questo server, altrimenti il
  /// migliore trovato.
  JavaRuntime? get java {
    final list = _javas;
    if (list == null) return null;
    final chosen = app.config.prefs[ServerPrefs.key(id, 'java')] as String?;
    if (chosen != null) {
      for (final j in list) {
        if (j.path == chosen) return j;
      }
    }
    return pickJava(list, requiredJava);
  }

  /// Il runtime scelto è più vecchio di quello richiesto.
  bool get javaTooOld {
    final j = java;
    return j != null && requiredJava > 0 && j.major > 0 && j.major < requiredJava;
  }

  /// Un runtime adatto, se quello scelto non lo è.
  JavaRuntime? get betterJava {
    if (!javaTooOld) return null;
    final best = pickJava(_javas ?? const [], requiredJava);
    return best != null && best.major >= requiredJava ? best : null;
  }

  /// Usa [j] per questo server (null: il migliore trovato), anche nella
  /// sessione in corso.
  Future<void> useJava(JavaRuntime? j) async {
    final saved = app.setServerPref(id, 'java', j?.path);
    _notify();
    await saved;
  }

  /// Cerca Java (una volta; [force] per ripetere).
  Future<void> ensureJava({bool force = false}) async {
    if (_javaLoading || (_javas != null && !force)) return;
    _javaLoading = true;
    _notify();
    try {
      _javas = await app.localProbe.java(serverRoot: layout?.workDir);
    } on Object {
      _javas = const [];
    } finally {
      _javaLoading = false;
      _notify();
    }
  }

  // --- lettura dello stato locale ---------------------------------------------------

  /// Legge lo stato locale una volta.
  void ensureLoaded() {
    if (_loaded || _loading) return;
    unawaited(refresh());
  }

  /// Rilegge base, cartella e cosa manca rispetto all'hub.
  Future<void> refresh() async {
    _loading = true;
    try {
      final f = folder ?? suggestedFolder;
      _baseN = linked ? LocalState(f).loadBase(id)?.n : null;
      _scan = await app.localProbe.scan(f);
      _loaded = true;
      _notify();
      await _computePending();
    } on Object {
      _loaded = true;
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// Confronta la base locale con la testa dell'hub.
  Future<void> _computePending() async {
    final head = summary?.head;
    final c = app.client;
    if (!linked || head == null || c == null || _baseN == head.n) {
      _pending = null;
      return;
    }
    final base = LocalState(folder!).loadBase(id);
    final g = await c.generation(id, n: head.n);
    final diff = ManifestDiff(base?.manifest ?? Manifest.empty, g.manifest);
    var bytes = 0;
    for (final p in [...diff.added, ...diff.changed]) {
      bytes += g.manifest[p]!.size;
    }
    _pending = PendingDownload(
      from: base?.n ?? 0,
      to: head.n,
      files: diff.added.length + diff.changed.length,
      bytes: bytes,
    );
  }

  /// Collega il server a [path] (creata se manca) e rilegge lo stato.
  Future<void> linkTo(String path) async {
    final abs = Directory(path).absolute.path;
    Directory(abs).createSync(recursive: true);
    await app.link(id, abs);
    await refresh();
  }

  Future<void> openFolder() async {
    final f = folder;
    if (f != null) await app.localProbe.openFolder(f);
  }

  // --- azioni ---------------------------------------------------------------------

  Transfer? _transfer;
  CancelToken? _cancel;
  Future<void>? _running;

  /// Operazione in corso, o null.
  Transfer? get transfer => _transfer;
  bool get busy => _transfer != null;

  SpaceOutcome? _outcome;

  /// Esito dell'ultima operazione (null dopo [clearOutcome]).
  SpaceOutcome? get outcome => _outcome;

  void clearOutcome() {
    _outcome = null;
    _notify();
  }

  /// Annulla l'operazione in corso (no-op se non ce n'è).
  void cancel() => _cancel?.cancel();

  /// Annulla l'eventuale pre-scarico e aspetta che finisca: da chiamare prima
  /// di usare la cartella per altro (es. avviare una sessione).
  Future<void> settle() async {
    if (_transfer?.background ?? false) cancel();
    await _running;
  }

  /// Scarica la testa dell'hub. Con [discardLocal] le modifiche locali mai
  /// caricate vengono prima copiate in un backup. Restituisce null se
  /// fallisce (l'errore è in [outcome]).
  Future<PullResult?> pull({bool discardLocal = false, bool background = false}) =>
      _run(SpaceOp.pull, background: background, (engine, ct) async {
        final r = await engine.pull(discardLocal: discardLocal, cancel: ct);
        _baseN = r.n;
        _pending = null;
        _outcome = PullDone(r, background: background);
        return r;
      });

  /// Carica la copia locale come nuova versione, prendendo il lock per il
  /// tempo del caricamento.
  Future<PushResult?> push({String message = '', bool confirmMassDelete = false}) =>
      _run(SpaceOp.push, (engine, ct) async {
        final c = app.client!;
        final lock = await c.acquireLock(id, const LockInfo(client: desktopClient, action: 'push'));
        try {
          final r = await engine.push(
            lock: lock,
            message: message,
            confirmMassDelete: confirmMassDelete,
            cancel: ct,
          );
          _baseN = r.generation?.n ?? _baseN;
          _outcome = PushDone(r);
          return r;
        } finally {
          try {
            await c.releaseLock(id, lock.token);
          } on Object {
            // il lock scade comunque da solo
          }
        }
      });

  /// Rilegge tutti i file (senza cache) e li confronta con l'ultima
  /// sincronizzazione.
  Future<VerifyDone?> verify() => _run(SpaceOp.verify, (engine, ct) async {
    final c = app.client!;
    final d = await c.space(id);
    ct.check();
    final base = LocalState(folder!).loadBase(id);
    final scan = await scanTree(folder!, Exclusions(d.exclusions));
    ct.check();
    final r = VerifyDone(
      scan.manifest.length,
      ManifestDiff(base?.manifest ?? Manifest.empty, scan.manifest),
    );
    _outcome = r;
    return r;
  });

  Future<T?> _run<T>(
    SpaceOp op,
    Future<T> Function(SyncEngine engine, CancelToken ct) body, {
    bool background = false,
  }) async {
    final c = app.client;
    final f = folder;
    if (busy || c == null || f == null) return null;
    final ct = _cancel = CancelToken();
    final samples = <(int, int)>[];
    final target = op == SpaceOp.pull ? summary?.headN : null;
    _transfer = Transfer(op: op, phase: 'start', background: background, target: target);
    _outcome = null;
    _notify();
    final engine = SyncEngine(
      c,
      id,
      f,
      onProgress: (p) {
        final now = DateTime.now().millisecondsSinceEpoch;
        samples.add((now, p.done));
        while (samples.length > 2 && now - samples.first.$1 > 3000) {
          samples.removeAt(0);
        }
        double? speed;
        if (samples.length > 1) {
          final dt = samples.last.$1 - samples.first.$1;
          if (dt >= 250) speed = (samples.last.$2 - samples.first.$2) / dt * 1000;
        }
        _transfer = Transfer(
          op: op,
          phase: p.phase,
          done: p.done,
          total: p.total,
          files: p.files,
          totalFiles: p.totalFiles,
          bytesPerSecond: speed,
          background: background,
          target: target,
        );
        _notify();
      },
    );
    final done = Completer<void>();
    _running = done.future;
    try {
      return await body(engine, ct);
    } on Object catch (e) {
      _outcome = OpFailed(op, e, background: background);
      return null;
    } finally {
      _transfer = null;
      _cancel = null;
      done.complete();
      _running = null;
      if (!_disposed) {
        _scan = await app.localProbe.scan(f).catchError((Object _) => _scan);
      }
      _notify();
    }
  }

  // --- storia ---------------------------------------------------------------------

  final _history = <GenerationSummary>[];
  bool _historyLoading = false;
  bool _historyEnd = false;
  Object? _historyError;
  final _diffs = <int, Future<GenerationDiff>>{};

  /// Versioni caricate, dalla più nuova.
  List<GenerationSummary> get history => List.unmodifiable(_history);
  bool get historyLoading => _historyLoading;

  /// Non ci sono versioni più vecchie da caricare.
  bool get historyEnd => _historyEnd;
  Object? get historyError => _historyError;

  /// Carica la prima pagina della storia (o, con [more], la successiva).
  Future<void> loadHistory({bool more = false, int page = 50}) async {
    final c = app.client;
    if (c == null || _historyLoading) return;
    _historyLoading = true;
    _historyError = null;
    _notify();
    try {
      final before = more && _history.isNotEmpty ? _history.last.n : null;
      final list = await c.generations(id, before: before, limit: page);
      if (!more) _history.clear();
      _history.addAll(list);
      _historyEnd = list.length < page;
    } on Object catch (e) {
      _historyError = e;
    } finally {
      _historyLoading = false;
      _notify();
    }
  }

  /// Differenze della versione [n] rispetto a quella da cui parte.
  Future<GenerationDiff> diff(int n) {
    final known = _diffs[n];
    if (known != null) return known;
    final f = _diffs[n] = _loadDiff(n);
    // un errore non resta in memoria: la prossima volta si riprova
    unawaited(
      f.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_diffs[n], f)) _diffs.remove(n);
        },
      ),
    );
    return f;
  }

  Future<GenerationDiff> _loadDiff(int n) async {
    final c = app.client!;
    final g = await c.generation(id, n: n);
    final parentN = g.summary.parent;
    final Manifest from = parentN <= 0
        ? Manifest.empty
        : (await c.generation(id, n: parentN)).manifest;
    final d = ManifestDiff(from, g.manifest);
    List<(String, int)> sized(List<String> paths, Manifest m) => [
      for (final p in paths) (p, m[p]?.size ?? 0),
    ];
    return GenerationDiff(
      n: n,
      parent: parentN,
      files: g.manifest.length,
      size: g.summary.stats.size,
      added: sized(d.added, g.manifest),
      changed: sized(d.changed, g.manifest),
      removed: sized(d.removed, from),
    );
  }

  /// Dimentica la storia letta (es. dopo un ripristino).
  void invalidateHistory() {
    _history.clear();
    _historyEnd = false;
    _notify();
  }

  // --- test -----------------------------------------------------------------------

  /// Imposta lo stato senza IO, per i test e le anteprime.
  @visibleForTesting
  void debugSet({
    int? baseN,
    LocalScan? scan,
    List<JavaRuntime>? javas,
    PendingDownload? pending,
    Transfer? transfer,
    SpaceOutcome? outcome,
    List<GenerationSummary>? history,
    bool? historyEnd,
    Map<int, GenerationDiff>? diffs,
  }) {
    _loaded = true;
    if (baseN != null) _baseN = baseN;
    if (scan != null) _scan = scan;
    if (javas != null) _javas = javas;
    if (pending != null) _pending = pending;
    if (transfer != null) _transfer = transfer;
    if (outcome != null) _outcome = outcome;
    if (history != null) {
      _history
        ..clear()
        ..addAll(history);
    }
    if (historyEnd != null) _historyEnd = historyEnd;
    diffs?.forEach((k, v) => _diffs[k] = SynchronousFuture(v));
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    super.dispose();
  }
}
