// Errori del motore di sincronizzazione: ognuno ha un tipo che le interfacce
// traducono, e i dati che servono a spiegarlo all'utente.
import 'dart:async';

/// Tipo di errore del sync.
enum SyncErrorKind {
  /// Ci sono modifiche locali mai caricate: il pull le sovrascriverebbe.
  dirtyLocal,

  /// La copia locale non parte dalla testa dell'hub: serve prima un pull.
  staleBase,

  /// Il push cancellerebbe troppi file (o tutto, da una cartella vuota).
  massDelete,

  /// L'hub è vuoto e la cartella locale no: si carica, non si scarica.
  emptyRemote,

  /// Il lock non è più nostro.
  lockLost,

  /// Lo spazio è stato cancellato sull'hub.
  spaceGone,

  /// Il manifest ricevuto contiene percorsi o hash non validi.
  badManifest,

  /// Un blob scaricato non corrisponde al suo hash.
  corruptDownload,

  /// L'hub ha rifiutato un blob caricato (il file è cambiato durante il push).
  blobRejected,

  /// Spazio insufficiente sul disco locale.
  localDiskFull,

  /// Spazio insufficiente sull'hub.
  hubDiskFull,

  /// Un collegamento a una cartella non si può sincronizzare.
  dirSymlink,

  /// Spazio insufficiente per l'outbox dell'istantanea.
  outboxNoSpace,

  /// L'istantanea non corrisponde più ai file (cambiati durante la copia, o
  /// un blob richiesto non c'è più com'era).
  snapshotStale,

  /// Operazione annullata da chi l'ha chiesta.
  cancelled,
}

/// Errore del sync.
final class SyncException implements Exception {
  const SyncException(
    this.kind, {
    this.message = '',
    this.diverged = false,
    this.changed = const [],
    this.removed = const [],
    this.base,
    this.head,
    this.path,
    this.cause,
  });

  final SyncErrorKind kind;
  final String message;

  /// Per [SyncErrorKind.dirtyLocal]: qualcun altro ha caricato dopo la nostra
  /// base (serve scegliere), altrimenti basta caricare prima di scaricare.
  final bool diverged;
  final List<String> changed;
  final List<String> removed;
  final int? base;
  final int? head;
  final String? path;
  final Object? cause;

  @override
  String toString() => 'SyncException(${kind.name}): $message';
}

/// Segnale di annullamento cooperativo.
final class CancelToken {
  bool _cancelled = false;
  SyncException? _reason;
  final _listeners = <void Function()>[];
  Completer<Object>? _done;

  /// Si completa con il motivo quando l'operazione viene annullata.
  Future<Object> get whenCancelled {
    final c = _done ??= Completer<Object>();
    if (_cancelled && !c.isCompleted) {
      c.complete(_reason ?? const SyncException(SyncErrorKind.cancelled));
    }
    return c.future;
  }

  bool get isCancelled => _cancelled;

  /// Motivo, se l'annullamento viene da un errore (es. lock perso).
  SyncException? get reason => _reason;

  void cancel([SyncException? reason]) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    final d = _done;
    if (d != null && !d.isCompleted) {
      d.complete(reason ?? const SyncException(SyncErrorKind.cancelled));
    }
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void onCancel(void Function() f) => _cancelled ? f() : _listeners.add(f);

  /// Lancia se annullato.
  void check() {
    if (_cancelled) throw _reason ?? const SyncException(SyncErrorKind.cancelled);
  }
}
