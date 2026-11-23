// Storia di uno spazio: differenze di una generazione con la precedente,
// file danneggiati con la loro ultima versione integra, ripristino di un
// singolo file.
import 'json.dart';
import 'models.dart';

/// Righe per gruppo restituite di default da `GET .../diff`.
const int diffDefaultLimit = 120;

/// Un file nelle differenze.
final class DiffEntry {
  const DiffEntry({required this.path, required this.size, this.prevSize});

  factory DiffEntry.fromJson(Object? j) {
    final m = obj(j, 'entry');
    return DiffEntry(
      path: str(m, 'path'),
      size: integer(m, 'size'),
      prevSize: optInt(m, 'prevSize'),
    );
  }

  final String path;

  /// Dimensione nella generazione (per i rimossi: nella precedente).
  final int size;

  /// Solo per i modificati: dimensione nella precedente.
  final int? prevSize;

  Map<String, Object?> toJson() => {
    'path': path,
    'size': size,
    if (prevSize != null) 'prevSize': prevSize,
  };
}

/// Un gruppo delle differenze: il totale e al più `limit` righe, in ordine
/// di percorso.
final class DiffSection {
  const DiffSection({required this.total, required this.items});

  factory DiffSection.fromJson(Object? j) {
    final m = obj(j, 'section');
    return DiffSection(total: integer(m, 'total'), items: listOf(m, 'items', DiffEntry.fromJson));
  }

  static const DiffSection empty = DiffSection(total: 0, items: []);

  final int total;
  final List<DiffEntry> items;

  bool get truncated => items.length < total;

  Map<String, Object?> toJson() => {
    'total': total,
    'items': [for (final e in items) e.toJson()],
  };
}

/// Un file danneggiato e l'ultima generazione precedente in cui c'era
/// integro (la sorgente «auto» di restore-file, B-GEN-12).
final class DamagedReport {
  const DamagedReport({required this.file, this.lastIntact});

  factory DamagedReport.fromJson(Object? j) {
    final m = obj(j, 'damaged');
    return DamagedReport(file: DamagedFile.fromJson(m), lastIntact: optInt(m, 'lastIntact'));
  }

  final DamagedFile file;

  /// null se nessuna generazione conservata lo ha integro.
  final int? lastIntact;

  Map<String, Object?> toJson() => {
    ...file.toJson(),
    if (lastIntact != null) 'lastIntact': lastIntact,
  };
}

/// `GET /spaces/{id}/generations/{n}/diff`.
final class GenerationChanges {
  const GenerationChanges({
    required this.n,
    required this.parent,
    required this.added,
    required this.changed,
    required this.removed,
    this.damaged = const [],
  });

  factory GenerationChanges.fromJson(Object? j) {
    final m = obj(j, 'diff');
    return GenerationChanges(
      n: integer(m, 'n'),
      parent: integer(m, 'parent'),
      added: DiffSection.fromJson(m['added']),
      changed: DiffSection.fromJson(m['changed']),
      removed: DiffSection.fromJson(m['removed']),
      damaged: optListOf(m, 'damaged', DamagedReport.fromJson),
    );
  }

  final int n;

  /// Generazione di confronto (0 = vuota). Se la precedente è stata
  /// eliminata, è la più recente conservata prima di [n].
  final int parent;
  final DiffSection added;
  final DiffSection changed;
  final DiffSection removed;
  final List<DamagedReport> damaged;

  Map<String, Object?> toJson() => {
    'n': n,
    'parent': parent,
    'added': added.toJson(),
    'changed': changed.toJson(),
    'removed': removed.toJson(),
    if (damaged.isNotEmpty) 'damaged': [for (final d in damaged) d.toJson()],
  };
}

/// `POST /spaces/{id}/restore-file`.
final class RestoreFileRequest {
  const RestoreFileRequest({required this.path, this.from = 0, this.message = ''});

  factory RestoreFileRequest.fromJson(Object? j) {
    final m = obj(j, 'restoreFile');
    return RestoreFileRequest(
      path: str(m, 'path'),
      from: optInt(m, 'from') ?? 0,
      message: optStr(m, 'message') ?? '',
    );
  }

  final String path;

  /// Generazione sorgente; 0 = «auto»: la più recente prima della HEAD in
  /// cui il file c'è e non è segnato danneggiato.
  final int from;
  final String message;

  Map<String, Object?> toJson() => {
    'path': path,
    if (from != 0) 'from': from,
    if (message.isNotEmpty) 'message': message,
  };
}
