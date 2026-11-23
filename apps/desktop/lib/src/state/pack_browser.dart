// Catalogo dei modpack di Modrinth nella procedura «Nuovo server», sul
// modello della scheda Modrinth di Prism Launcher: elenco subito all'apertura
// (i più scaricati), ricerca mentre si scrive (con una pausa di 300 ms),
// ordinamento, filtri per loader e versione di Minecraft, pagine con offset
// («Carica altri» o scorrimento), dettagli del modpack scelto con le sue
// versioni. Le icone passano dal trasporto del modpack (mai la rete vera nei
// test) e restano in cache in memoria e, se c'è, su disco.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ms_modpack/ms_modpack.dart';
import 'package:path/path.dart' as p;

/// Ordinamento del catalogo.
enum PackSort {
  downloads(MrSearchIndex.downloads),
  relevance(MrSearchIndex.relevance),
  newest(MrSearchIndex.newest),
  updated(MrSearchIndex.updated);

  const PackSort(this.mr);
  final MrSearchIndex mr;
}

/// Loader che si possono filtrare (quelli dei server MineSync).
const packLoaders = [Loader.fabric, Loader.quilt, Loader.neoforge, Loader.forge];

/// Il loader di un risultato, dalle sue categorie.
Loader? hitLoader(MrSearchHit h) {
  for (final l in packLoaders) {
    if (h.categories.contains(mrLoader(l))) return l;
  }
  return null;
}

/// Tutti i loader di un risultato.
List<Loader> hitLoaders(MrSearchHit h) => [
  for (final l in packLoaders)
    if (h.categories.contains(mrLoader(l))) l,
];

/// Confronto tra versioni di Minecraft (`1.21.1` > `1.20.6`, `26.1` >
/// `1.21.11`); i pezzi non numerici contano zero.
int compareMc(String a, String b) {
  final x = a.split(RegExp('[.-]')), y = b.split(RegExp('[.-]'));
  for (var i = 0; i < x.length || i < y.length; i++) {
    final p = i < x.length ? int.tryParse(x[i]) ?? 0 : 0;
    final q = i < y.length ? int.tryParse(y[i]) ?? 0 : 0;
    if (p != q) return p.compareTo(q);
  }
  return 0;
}

/// L'ultima versione di Minecraft fra [versions] (null se vuota).
String? latestMc(Iterable<String> versions) {
  String? best;
  for (final v in versions) {
    if (best == null || compareMc(v, best) > 0) best = v;
  }
  return best;
}

/// Icone dei progetti: memoria (LRU) e, con [dir], disco. Una sola
/// richiesta per URL anche se più righe la chiedono insieme. Solo https,
/// al più [maxBytes].
final class IconCache {
  IconCache(this.transport, {required this.userAgent, this.dir, this.maxEntries = 300});

  final HttpTransport transport;
  final String userAgent;

  /// Cartella della cache su disco (null: solo memoria).
  final String? dir;
  final int maxEntries;
  static const maxBytes = 1 << 20;

  final _mem = <String, Uint8List>{};
  final _failed = <String>{};
  final _pending = <String, Future<Uint8List?>>{};

  /// L'icona già in memoria, se c'è.
  Uint8List? peek(String url) => _mem[url];

  /// Vero se l'icona non si è potuta avere (si mostra il disegno di riserva).
  bool failed(String url) => _failed.contains(url);

  /// Segna l'icona come non leggibile (immagine rotta).
  void markFailed(String url) {
    _failed.add(url);
    _mem.remove(url);
  }

  Future<Uint8List?> load(String url) {
    final hit = _mem[url];
    if (hit != null) return SynchronousFuture(hit);
    if (_failed.contains(url)) return SynchronousFuture(null);
    // il callback non deve restituire il future stesso (aspetterebbe sé stesso)
    return _pending[url] ??= _fetch(url).whenComplete(() {
      _pending.remove(url);
    });
  }

  /// Nome del file: FNV-1a a 64 bit dell'URL (stabile fra un avvio e
  /// l'altro).
  String _file(String url) {
    var h = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final c in url.codeUnits) {
      h = ((h ^ BigInt.from(c)) * prime) & mask;
    }
    return p.join(dir!, '${h.toRadixString(16).padLeft(16, '0')}.img');
  }

  Future<Uint8List?> _fetch(String url) async {
    final u = Uri.tryParse(url);
    if (u == null || u.scheme != 'https' || u.host.isEmpty) {
      _failed.add(url);
      return null;
    }
    try {
      if (dir != null) {
        final f = File(_file(url));
        if (f.existsSync()) return _put(url, await f.readAsBytes());
      }
      final res = await transport.send(HttpReq('GET', u, headers: {'User-Agent': userAgent}));
      if (!res.ok) {
        await res.drain();
        _failed.add(url);
        return null;
      }
      final b = await res.readAll(max: maxBytes);
      if (b.isEmpty) {
        _failed.add(url);
        return null;
      }
      if (dir != null) {
        try {
          await Directory(dir!).create(recursive: true);
          await File(_file(url)).writeAsBytes(b, flush: true);
        } on FileSystemException {
          // la cache su disco è un di più
        }
      }
      return _put(url, b);
    } on Object {
      _failed.add(url);
      return null;
    }
  }

  Uint8List _put(String url, Uint8List b) {
    _mem.remove(url);
    _mem[url] = b;
    while (_mem.length > maxEntries) {
      _mem.remove(_mem.keys.first);
    }
    return b;
  }
}

/// Il catalogo con i dettagli del modpack scelto.
final class PackBrowser extends ChangeNotifier {
  PackBrowser(
    this.modrinth, {
    this.debounce = const Duration(milliseconds: 300),
    this.pageSize = 20,
  });

  final ModrinthClient modrinth;

  /// Pausa dopo l'ultimo tasto prima di cercare.
  final Duration debounce;
  final int pageSize;
  bool _disposed = false;

  // --- elenco -------------------------------------------------------------------

  String query = '';
  PackSort sort = PackSort.downloads;
  Loader? loader;
  String? mcVersion;

  /// Versioni di Minecraft per il filtro (solo release, dalla più nuova).
  List<String>? mcVersions;

  bool started = false;
  List<MrSearchHit> hits = const [];
  int total = 0;

  /// Prima pagina in caricamento (scheletri al posto delle righe).
  bool loading = false;
  bool loadingMore = false;

  /// Errore della prima pagina (Modrinth non risponde): stato d'errore con
  /// «Riprova».
  Object? error;

  /// Errore di una pagina successiva: le righe restano, «Riprova» in fondo.
  Object? moreError;
  int _gen = 0;
  Timer? _timer;

  bool get hasMore => hits.length < total;

  /// Prima apertura: carica i più scaricati e le versioni del gioco.
  void open() {
    if (started) return;
    started = true;
    unawaited(reload());
    unawaited(loadMcVersions());
  }

  Future<void> loadMcVersions() async {
    try {
      final all = await modrinth.gameVersions();
      mcVersions = [
        for (final v in all)
          if (v.versionType == 'release') v.version,
      ]..sort((a, b) => compareMc(b, a));
    } on Object {
      mcVersions = const [];
    }
    _notify();
  }

  /// Il testo della ricerca: si cerca dopo [debounce] dall'ultimo tasto.
  void setQuery(String q) {
    if (q.trim() == query) return;
    query = q.trim();
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(reload()));
  }

  /// Cerca subito (Invio nel campo).
  void searchNow(String q) {
    _timer?.cancel();
    query = q.trim();
    unawaited(reload());
  }

  void setSort(PackSort s) {
    if (s == sort) return;
    sort = s;
    unawaited(reload());
  }

  void setLoader(Loader? l) {
    if (l == loader) return;
    loader = l;
    unawaited(reload());
  }

  void setMcVersion(String? v) {
    if (v == mcVersion) return;
    mcVersion = v;
    unawaited(reload());
  }

  /// Ricomincia dalla prima pagina con la ricerca e i filtri attuali.
  Future<void> reload() async {
    _timer?.cancel();
    final gen = ++_gen;
    hits = const [];
    total = 0;
    loading = true;
    loadingMore = false;
    error = null;
    moreError = null;
    _notify();
    try {
      final r = await _search(0);
      if (gen != _gen) return;
      hits = r.hits;
      total = r.total;
    } on Object catch (e) {
      if (gen != _gen) return;
      error = e;
    }
    loading = false;
    _notify();
  }

  /// La pagina dopo.
  Future<void> loadMore() async {
    if (loading || loadingMore || !hasMore || error != null) return;
    final gen = _gen;
    loadingMore = true;
    moreError = null;
    _notify();
    try {
      final r = await _search(hits.length);
      if (gen != _gen) return;
      final seen = {for (final h in hits) h.projectId};
      hits = [
        ...hits,
        for (final h in r.hits)
          if (!seen.contains(h.projectId)) h,
      ];
      // pagina vuota: niente altro (anche se il totale diceva di più)
      total = r.hits.isEmpty ? hits.length : r.total;
    } on Object catch (e) {
      if (gen != _gen) return;
      moreError = e;
    }
    loadingMore = false;
    _notify();
  }

  Future<MrSearchResult> _search(int offset) => modrinth.search(
    query: query,
    projectType: 'modpack',
    loader: loader,
    gameVersion: mcVersion,
    // la rilevanza senza testo è un ordine a caso: meglio i più scaricati
    index: query.isEmpty && sort == PackSort.relevance ? MrSearchIndex.downloads : sort.mr,
    offset: offset,
    limit: pageSize,
  );

  // --- dettagli --------------------------------------------------------------------

  MrSearchHit? selected;
  MrProject? project;
  Object? projectError;
  List<MrVersion>? versions;
  Object? versionsError;

  /// Mostra anche le beta (e le alpha) nell'elenco delle versioni.
  bool showBeta = false;
  MrVersion? version;
  int _selGen = 0;

  bool get detailsLoading => selected != null && (project == null || versions == null);

  /// Le versioni da mostrare, dalla più nuova.
  List<MrVersion> get visibleVersions => [
    for (final v in versions ?? const <MrVersion>[])
      if (showBeta || v.versionType == MrVersionType.release || v.id == version?.id) v,
  ];

  /// Compatibile con i filtri attivi (loader e versione del gioco).
  bool fitsFilters(MrVersion v) =>
      (loader == null || v.loaders.contains(mrLoader(loader!))) &&
      (mcVersion == null || v.gameVersions.contains(mcVersion));

  Future<void> select(MrSearchHit h) async {
    if (selected?.projectId == h.projectId && projectError == null && versionsError == null) {
      return;
    }
    final gen = ++_selGen;
    selected = h;
    project = null;
    projectError = null;
    versions = null;
    versionsError = null;
    version = null;
    _notify();
    await Future.wait([
      modrinth
          .project(h.projectId)
          .then((p) {
            if (gen == _selGen) project = p;
          })
          .catchError((Object e) {
            if (gen == _selGen) projectError = e;
          }),
      modrinth
          .versions(h.projectId)
          .then((vs) {
            if (gen != _selGen) return;
            final l = vs.toList()..sort(newestFirst);
            versions = l;
            version = defaultVersion(l);
            if (version != null && version!.versionType != MrVersionType.release) {
              showBeta = true;
            }
          })
          .catchError((Object e) {
            if (gen == _selGen) {
              versions = const [];
              versionsError = e;
            }
          }),
    ]);
    if (gen == _selGen) _notify();
  }

  /// La versione proposta: l'ultima release compatibile con i filtri, poi
  /// l'ultima release, poi l'ultima in assoluto ([vs] dalla più nuova).
  MrVersion? defaultVersion(List<MrVersion> vs) =>
      vs.where((v) => v.versionType == MrVersionType.release && fitsFilters(v)).firstOrNull ??
      vs.where((v) => v.versionType == MrVersionType.release).firstOrNull ??
      vs.where(fitsFilters).firstOrNull ??
      vs.firstOrNull;

  /// Riprova i dettagli del modpack scelto.
  Future<void> retryDetails() async {
    final h = selected;
    if (h == null) return;
    selected = null;
    await select(h);
  }

  void setShowBeta(bool v) {
    showBeta = v;
    final cur = version;
    if (!v && cur != null && cur.versionType != MrVersionType.release) {
      version = defaultVersion(versions ?? const []) ?? cur;
    }
    _notify();
  }

  void chooseVersion(MrVersion v) {
    version = v;
    _notify();
  }

  void clearSelection() {
    _selGen++;
    selected = null;
    project = null;
    versions = null;
    version = null;
    projectError = null;
    versionsError = null;
    _notify();
  }

  /// Imposta lo stato senza rete, per i test e le anteprime.
  @visibleForTesting
  void debugSet({
    List<MrSearchHit>? hits,
    int? total,
    bool? loading,
    Object? error,
    List<String>? mcVersions,
    MrSearchHit? selected,
    MrProject? project,
    List<MrVersion>? versions,
    MrVersion? version,
  }) {
    started = true;
    if (hits != null) this.hits = hits;
    if (total != null) this.total = total;
    if (loading != null) this.loading = loading;
    if (error != null) this.error = error;
    if (mcVersions != null) this.mcVersions = mcVersions;
    if (selected != null) this.selected = selected;
    if (project != null) this.project = project;
    if (versions != null) this.versions = versions;
    if (version != null) this.version = version;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
