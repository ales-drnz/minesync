// Piano di installazione lato server: dal pack di prima e da quello nuovo,
// guardando i file davvero presenti, cosa scaricare, spostare (accendere,
// spegnere, cambiare lato) e cancellare. Si cancellano solo file che il pack
// di prima conosceva con lo stesso hash: un jar sconosciuto o sostituito a
// mano non si tocca mai.
import 'package:ms_protocol/ms_protocol.dart' show caseFoldKey, comparePaths;

import 'pack.dart';

/// Un file da scaricare.
final class InstallDownload {
  const InstallDownload(this.mod, this.location);
  final PackMod mod;

  /// Dove va nella cartella del server ([PackMod.diskLocation]).
  final String location;
}

/// Uno spostamento (rinomina) dentro la cartella del server.
final class InstallMove {
  const InstallMove(this.from, this.to, this.mod);
  final String from;
  final String to;
  final PackMod mod;
}

/// Il piano.
final class InstallPlan {
  const InstallPlan({
    required this.pack,
    this.downloads = const [],
    this.moves = const [],
    this.deletes = const [],
    this.unavailable = const [],
  });

  /// Il pack che si sta installando.
  final Pack pack;
  final List<InstallDownload> downloads;
  final List<InstallMove> moves;

  /// File da togliere (percorsi della cartella del server).
  final List<String> deletes;

  /// Mod che mancano e non hanno un URL (manuali, CurseForge a mano), o il
  /// cui posto è occupato da un jar sconosciuto: l'admin deve intervenire.
  final List<PackMod> unavailable;

  bool get isEmpty => downloads.isEmpty && moves.isEmpty && deletes.isEmpty;

  /// Byte da scaricare.
  int get downloadBytes => downloads.fold(0, (a, d) => a + d.mod.size);
}

/// Pianifica il passaggio da [from] (null: server nuovo o senza pack) a [to]
/// con i file [files] presenti (servono almeno le posizioni delle mod, con
/// SHA-1).
InstallPlan planInstall({Pack? from, required Pack to, required Iterable<LocalFile> files}) {
  final local = <String, LocalFile>{for (final f in files) caseFoldKey(f.path): f};
  final bySha = <String, List<LocalFile>>{};
  for (final f in local.values) {
    (bySha[f.sha1] ??= []).add(f);
  }
  final downloads = <InstallDownload>[];
  final moves = <InstallMove>[];
  final unavailable = <PackMod>[];
  final keep = <String>{}; // posizioni occupate dal pack nuovo
  final consumed = <String>{}; // file spostati altrove
  for (final m in to.mods) {
    keep.add(caseFoldKey(m.diskLocation));
  }
  for (final m in to.mods) {
    final dest = m.diskLocation;
    final here = local[caseFoldKey(dest)];
    if (here != null && here.sha1 == m.sha1) continue;
    // lo stesso file altrove, in una posizione del pack di prima che il
    // nuovo non usa: si sposta invece di riscaricarlo
    final old = from?.byKey(m.key);
    final candidates = <String>[
      if (old != null) ...[old.diskLocation, old.location, '${old.location}$disabledSuffix'],
      // anche dall'altro lato (un jar a mano messo nella cartella sbagliata)
      for (final l in [m.path, '$clientOverridesDir/${m.path}']) ...[l, '$l$disabledSuffix'],
    ];
    LocalFile? src;
    for (final c in candidates) {
      final f = local[caseFoldKey(c)];
      if (f != null &&
          f.sha1 == m.sha1 &&
          !keep.contains(caseFoldKey(c)) &&
          !consumed.contains(caseFoldKey(c))) {
        src = f;
        break;
      }
    }
    if (src != null && here == null) {
      consumed.add(caseFoldKey(src.path));
      moves.add(InstallMove(src.path, dest, m));
      continue;
    }
    if (m.downloads.isEmpty) {
      unavailable.add(m);
      continue;
    }
    downloads.add(InstallDownload(m, dest));
  }
  // file del pack di prima che il nuovo non vuole più
  final deletes = <String>{};
  if (from != null) {
    for (final m in from.mods) {
      for (final loc in {m.diskLocation, m.location, '${m.location}$disabledSuffix'}) {
        final k = caseFoldKey(loc);
        final f = local[k];
        if (f == null || f.sha1 != m.sha1) continue;
        if (keep.contains(k) || consumed.contains(k)) continue;
        deletes.add(f.path);
      }
    }
  }
  // un download sopra un file presente (con un altro hash) lo sostituisce:
  // solo se quel file era del pack di prima, altrimenti è un jar a mano
  // che si sposta da parte
  for (final d in downloads.toList()) {
    final f = local[caseFoldKey(d.location)];
    if (f == null) continue;
    final wasOurs =
        from?.mods.any(
          (m) => caseFoldKey(m.diskLocation) == caseFoldKey(f.path) && m.sha1 == f.sha1,
        ) ??
        false;
    if (wasOurs) {
      deletes.add(f.path);
    } else {
      // conflitto con un jar sconosciuto: non lo si sovrascrive
      downloads.remove(d);
      unavailable.add(d.mod);
    }
  }
  final del = deletes.toList()..sort(comparePaths);
  downloads.sort((a, b) => comparePaths(a.location, b.location));
  moves.sort((a, b) => comparePaths(a.to, b.to));
  return InstallPlan(
    pack: to,
    downloads: downloads,
    moves: moves,
    deletes: del,
    unavailable: unavailable,
  );
}
