// Stato del modpack di un server su questo PC: il pack della copia locale
// (minesync-pack.json, o riconosciuto dai jar al primo uso), le modifiche
// preparate e non ancora applicate, aggiornamenti, ricerca su Modrinth,
// cambio di versione o loader con il controllo di compatibilità, e
// l'applicazione: tutto scaricato e verificato prima di toccare la cartella,
// poi il caricamento normale sull'hub (nuova generazione, si torna indietro
// dalla Storia). Rifiutata mentre qualcuno gioca: si può mettere in coda.
// Anche il pacchetto per i giocatori (facoltative scelte su questo PC,
// .mrpack, Prism, profilo del launcher ufficiale).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ms_minecraft/ms_minecraft.dart' show pickJava, requiredJava;
import 'package:ms_modpack/io.dart';
import 'package:ms_modpack/ms_modpack.dart';
import 'package:ms_modpack/ms_modpack.dart' as mp show checkUpdates;
import 'package:ms_protocol/ms_protocol.dart';
import 'package:path/path.dart' as p;

import '../l10n/l10n.dart';
import 'app_state.dart';
import 'launcher_profile.dart';
import 'space_state.dart';

/// A che punto è la lettura del pack.
enum PackPhase {
  /// Non ancora letto.
  idle,
  loading,

  /// Il server non ha una cartella su questo PC.
  noFolder,

  /// Nessun pack e versione di Minecraft o loader non riconoscibili.
  noVersion,

  /// Riconoscimento dei jar su Modrinth in corso.
  recognizing,
  ready,

  /// Lettura fallita ([ModpackController.loadError]).
  error,
}

/// Un risultato della ricerca su Modrinth.
@immutable
final class SearchHitView {
  const SearchHitView(
    this.hit, {
    required this.fits,
    this.loaders = const [],
    this.installed = false,
  });

  final MrSearchHit hit;

  /// Gira sulla versione di Minecraft e sul loader del server.
  final bool fits;

  /// Loader per cui esiste (per spiegare perché non va).
  final List<String> loaders;
  final bool installed;
}

/// Esito dell'applicazione delle modifiche.
sealed class ApplyState {
  const ApplyState();
}

final class ApplyIdle extends ApplyState {
  const ApplyIdle();
}

/// In attesa che il server si liberi.
final class ApplyQueued extends ApplyState {
  const ApplyQueued(this.holder);
  final String holder;
}

final class Applying extends ApplyState {
  const Applying(this.step, {this.done = 0, this.total = 0, this.current});

  /// `pull`, `install`, `download`, `push`.
  final String step;
  final int done;
  final int total;

  /// Mod in download.
  final String? current;
}

final class ApplyDone extends ApplyState {
  const ApplyDone(this.n, this.changes);

  /// Generazione creata (null se non c'era niente da caricare).
  final int? n;
  final int changes;
}

final class ApplyFailed extends ApplyState {
  const ApplyFailed(this.reason, [this.error, this.mods = const []]);

  /// `locked`, `pull`, `java`, `install`, `unavailable`, `download`,
  /// `modrinth`, `push`.
  final String reason;
  final Object? error;

  /// Mod che non si possono installare (`unavailable`).
  final List<PackMod> mods;
}

/// Dove è pronto il pacchetto per i giocatori su questo PC.
@immutable
final class ClientInstall {
  const ClientInstall({required this.target, required this.n, this.path});

  /// `prism`, `launcher` o `file`.
  final String target;

  /// Generazione da cui è stato preparato.
  final int n;

  /// File esportato o cartella di gioco.
  final String? path;

  Map<String, Object?> toJson() => {'target': target, 'n': n, 'path': ?path};

  static ClientInstall? fromJson(Object? j) {
    if (j is! Map<String, Object?>) return null;
    final t = j['target'], n = j['n'];
    if (t is! String || n is! int) return null;
    return ClientInstall(target: t, n: n, path: j['path'] as String?);
  }
}

final class ModpackController extends ChangeNotifier {
  ModpackController(this.app, this.id) {
    app.addListener(_onApp);
  }

  final AppState app;
  final String id;

  SpaceState get space => app.spaceState(id);
  ModpackEnv get env => app.modpackEnv;
  SpaceSummary? get summary => app.space(id);
  String? get root => space.folder;

  bool _disposed = false;

  // --- pack ---------------------------------------------------------------------

  PackPhase _phase = PackPhase.idle;
  PackPhase get phase => _phase;
  Object? _loadError;
  Object? get loadError => _loadError;

  Pack? _base;
  Pack? _draft;

  /// Il pack com'è nella copia locale (o come è stato riconosciuto).
  Pack? get base => _base;

  /// Il pack con le modifiche preparate.
  Pack? get draft => _draft;

  /// Il file minesync-pack.json non c'è ancora: si scrive applicando.
  bool _baseIsNew = false;
  bool get packIsNew => _baseIsNew;

  /// Le modifiche preparate (vuote se non ce ne sono).
  PackDiff? get changes {
    final b = _base, d = _draft;
    return b == null || d == null ? null : PackDiff(b, d);
  }

  /// Quante modifiche (una per mod, più versione/loader).
  int get changeCount {
    final c = changes;
    if (c == null) return 0;
    return (c.mcVersion != null || c.loader != null ? 1 : 0) +
        c.added.length +
        c.removed.length +
        c.updated.length +
        c.toggled.length +
        c.changed.length +
        (c.sharedChanged ? 1 : 0) +
        (_baseIsNew && (_draft?.mods.isNotEmpty ?? false) ? 1 : 0);
  }

  bool get dirty => changeCount > 0;

  /// Legge il pack della copia locale; senza file lo ricostruisce dai jar.
  Future<void> load({bool force = false}) async {
    if (!force && (_phase == PackPhase.loading || _phase == PackPhase.recognizing)) return;
    if (!force && _phase == PackPhase.ready) return;
    final r = root;
    if (r == null) {
      _set(PackPhase.noFolder);
      return;
    }
    _set(PackPhase.loading);
    try {
      final onDisk = await readPackFile(r);
      if (onDisk != null) {
        _base = onDisk;
        _baseIsNew = false;
        if (force || _draft == null || _draft!.mcVersion != onDisk.mcVersion) _draft = onDisk;
        _set(PackPhase.ready);
        unawaited(_checkWatch());
        return;
      }
      await _recognize(r);
    } on Object catch (e) {
      _loadError = e;
      _set(PackPhase.error);
    }
  }

  /// Primo uso: i jar della cartella diventano il pack. Quelli che Modrinth
  /// riconosce per SHA-1 diventano mod Modrinth; gli altri voci a mano, lato
  /// server di default (client se stanno in client-overrides/mods/).
  Future<void> _recognize(String r) async {
    final l = space.layout;
    final mc = l?.mcVersion;
    final loader = _loaderOf(l?.loader);
    final files = await env.scanMods(r);
    if (mc == null || loader == null || (loader != Loader.vanilla && l?.loaderVersion == null)) {
      if (files.isEmpty && mc != null) {
        // vanilla senza mod: niente da riconoscere
        _base = _draft = Pack(name: summary?.name, mcVersion: mc, loader: Loader.vanilla);
        _baseIsNew = true;
        _set(PackPhase.ready);
        return;
      }
      _set(PackPhase.noVersion);
      return;
    }
    _set(PackPhase.recognizing);
    final mods = <PackMod>[];
    if (files.isNotEmpty) {
      final Map<String, MrVersion> known;
      final Map<String, MrProject> projects;
      try {
        known = await env.modrinth.versionFiles(files.map((f) => f.sha1));
        final ps = await env.modrinth.projects(known.values.map((v) => v.projectId));
        projects = {for (final p in ps) p.id: p};
        _modrinthOk();
      } on ModrinthUnavailable catch (e) {
        _modrinthFailed();
        _loadError = e;
        _set(PackPhase.error);
        return;
      }
      final seen = <String>{};
      for (final f in files) {
        final v = known[f.sha1];
        final base = manualEntry(f);
        if (v == null || !seen.add(v.projectId)) {
          mods.add(base);
          continue;
        }
        final file = v.files.where((x) => x.sha1 == f.sha1).firstOrNull ?? v.primaryFile;
        if (file == null) {
          mods.add(base);
          continue;
        }
        final pr = projects[v.projectId];
        final (side, optional) = pr?.side ?? (PackSide.both, false);
        // un jar in client-overrides/ resta solo client
        final s = base.side == PackSide.client ? PackSide.client : side;
        mods.add(
          base.copyWith(
            name: pr?.title,
            side: s,
            optional: optional,
            source: PackSource.modrinth,
            projectId: v.projectId,
            versionId: v.id,
            versionNumber: v.versionNumber,
            downloads: [file.url],
            requires: requiredProjects(v, null),
          ),
        );
      }
    }
    final pack = Pack(
      name: summary?.name,
      mcVersion: mc,
      loader: loader,
      loaderVersion: loader == Loader.vanilla ? null : l!.loaderVersion,
      mods: mods,
    );
    _base = _draft = pack;
    _baseIsNew = true;
    _set(PackPhase.ready);
  }

  static Loader? _loaderOf(String? s) {
    if (s == null) return null;
    try {
      final l = Loader.parse(s);
      return l == Loader.paper ? null : l;
    } on Object {
      return null;
    }
  }

  // --- modifiche --------------------------------------------------------------------

  void _edit(Pack Function(Pack d) f) {
    final d = _draft;
    if (d == null) return;
    _draft = f(d);
    if (_apply is ApplyDone || _apply is ApplyFailed) _apply = const ApplyIdle();
    _notify();
  }

  /// Accende o spegne una mod.
  void toggle(String key) => _edit((d) {
    final m = d.byKey(key);
    return m == null ? d : d.withMods([m.copyWith(disabled: !m.disabled)]);
  });

  /// Cambia il lato di una mod (le aggiunte a mano soprattutto).
  void setSide(String key, PackSide side) => _edit((d) {
    final m = d.byKey(key);
    return m == null ? d : d.withMods([m.copyWith(side: side)]);
  });

  void setOptional(String key, bool optional) => _edit((d) {
    final m = d.byKey(key);
    return m == null ? d : d.withMods([m.copyWith(optional: optional)]);
  });

  void setPinned(String key, bool pinned) => _edit((d) {
    final m = d.byKey(key);
    return m == null ? d : d.withMods([m.copyWith(pinned: pinned)]);
  });

  /// Chi se ne va togliendo [key] (dipendenti e dipendenze rimaste orfane).
  RemovePlan? planRemoval(String key) {
    final d = _draft;
    return d == null || d.byKey(key) == null ? null : planRemove(d, key);
  }

  void remove(RemovePlan plan) => _edit((d) => plan.apply(d));

  /// Annulla tutte le modifiche preparate.
  void discard() {
    _draft = _base;
    _queued = false;
    _apply = const ApplyIdle();
    _notify();
  }

  /// Come era la mod prima delle modifiche (null se è nuova).
  PackMod? before(String key) => _base?.byKey(key);

  // --- Modrinth: disponibilità --------------------------------------------------------

  bool _modrinthDown = false;
  DateTime? _lastAttempt;
  Timer? _retry;

  /// Modrinth non ha risposto all'ultima richiesta.
  bool get modrinthDown => _modrinthDown;
  DateTime? get lastAttempt => _lastAttempt;

  void _modrinthOk() {
    _modrinthDown = false;
    _lastAttempt = DateTime.now();
    _retry?.cancel();
    _retry = null;
  }

  void _modrinthFailed() {
    _modrinthDown = true;
    _lastAttempt = DateTime.now();
    _retry?.cancel();
    if (!_disposed) _retry = Timer(env.retryEvery, () => unawaited(retryModrinth()));
  }

  /// Riprova adesso: aggiornamenti, ricerca e, se serve, il riconoscimento.
  Future<void> retryModrinth() async {
    _retry?.cancel();
    _retry = null;
    if (_phase == PackPhase.error && _base == null) {
      await load(force: true);
      return;
    }
    await checkUpdates();
    if (_query.isNotEmpty) await search(_query);
  }

  // --- aggiornamenti --------------------------------------------------------------------

  List<UpdateCheck> _updates = const [];
  DateTime? _updatesAt;
  bool _updatesLoading = false;

  /// Controlli delle mod Modrinth (vuoti finché non si controlla).
  List<UpdateCheck> get updates => _updates;
  DateTime? get updatesAt => _updatesAt;
  bool get updatesLoading => _updatesLoading;

  /// Aggiornamenti disponibili o bloccati (quelli da mostrare).
  List<UpdateCheck> get pendingUpdates => [
    for (final u in _updates)
      if (u.status == UpdateStatus.available || u.status == UpdateStatus.blocked) u,
  ];

  /// L'aggiornamento di [key] è già nelle modifiche.
  bool updateQueued(String key) {
    final b = _base?.byKey(key), d = _draft?.byKey(key);
    return b != null && d != null && b.versionId != d.versionId;
  }

  Future<void> checkUpdates() async {
    final d = _draft;
    if (d == null || _updatesLoading) return;
    if (!d.mods.any((m) => m.source == PackSource.modrinth)) {
      _updates = const [];
      _updatesAt = DateTime.now();
      _notify();
      return;
    }
    _updatesLoading = true;
    _notify();
    try {
      final base = _base ?? d;
      final cat = await CatalogLoader(env.modrinth).forUpdates(base);
      _updates = mp.checkUpdates(base, cat);
      _updatesAt = DateTime.now();
      _modrinthOk();
    } on ModrinthUnavailable {
      _modrinthFailed();
    } on Object {
      _modrinthFailed();
    } finally {
      _updatesLoading = false;
      _notify();
    }
  }

  /// Mette nelle modifiche l'aggiornamento di [key].
  void update(String key) {
    final u = _updates.where((u) => u.mod.key == key).firstOrNull;
    if (u == null || u.status != UpdateStatus.available) return;
    _edit((d) => applyUpdates(d, [u], includePinned: true));
  }

  /// "Aggiorna tutte": salta le bloccate e quelle fissate.
  void updateAll() => _edit((d) => applyUpdates(d, pendingUpdates));

  // --- ricerca --------------------------------------------------------------------

  String _query = '';
  bool _onlyCompatible = true;
  MrSearchIndex _sort = MrSearchIndex.relevance;
  List<SearchHitView> _results = const [];
  bool _searching = false;
  Object? _searchError;
  int _searchSeq = 0;

  String get query => _query;
  bool get onlyCompatible => _onlyCompatible;
  MrSearchIndex get sort => _sort;
  List<SearchHitView> get results => _results;
  bool get searching => _searching;
  Object? get searchError => _searchError;

  set onlyCompatible(bool v) {
    _onlyCompatible = v;
    _notify();
    if (_query.isNotEmpty) unawaited(search(_query));
  }

  set sort(MrSearchIndex v) {
    _sort = v;
    _notify();
    if (_query.isNotEmpty) unawaited(search(_query));
  }

  /// Cerca su Modrinth. Con «solo compatibili» filtra Modrinth per versione e
  /// loader; altrimenti mostra tutto e dice perché una mod non va.
  Future<void> search(String q) async {
    final d = _draft;
    _query = q.trim();
    if (d == null || _query.isEmpty) {
      _results = const [];
      _notify();
      return;
    }
    final seq = ++_searchSeq;
    _searching = true;
    _searchError = null;
    _notify();
    try {
      final r = await env.modrinth.search(
        query: _query,
        gameVersion: _onlyCompatible ? d.mcVersion : null,
        loader: _onlyCompatible && d.loader != Loader.vanilla ? d.loader : null,
        index: _sort,
      );
      if (seq != _searchSeq) return;
      final ok = compatibleLoaders(d.loader).toSet();
      _results = [
        for (final h in r.hits)
          SearchHitView(
            h,
            fits:
                h.gameVersions.contains(d.mcVersion) &&
                (d.loader == Loader.vanilla || h.categories.any(ok.contains)),
            loaders: [
              for (final c in h.categories)
                if (_mrLoaders.contains(c)) c,
            ],
            installed: d.byProject(h.projectId) != null,
          ),
      ];
      _modrinthOk();
    } on ModrinthUnavailable catch (e) {
      if (seq != _searchSeq) return;
      _searchError = e;
      _results = const [];
      _modrinthFailed();
    } on Object catch (e) {
      if (seq != _searchSeq) return;
      _searchError = e;
      _results = const [];
    } finally {
      if (seq == _searchSeq) {
        _searching = false;
        _notify();
      }
    }
  }

  static const _mrLoaders = {'fabric', 'quilt', 'forge', 'neoforge'};

  /// Il piano per aggiungere [projectId] (con le dipendenze).
  Future<AddPlan> planAddition(String projectId, {String? versionId}) async {
    final d = _draft!;
    try {
      final cat = await CatalogLoader(env.modrinth).forAdd(d, projectId, versionId: versionId);
      _modrinthOk();
      return planAdd(d, cat, projectId, versionId: versionId);
    } on ModrinthUnavailable {
      _modrinthFailed();
      rethrow;
    }
  }

  /// Le versioni di [projectId] che girano sul server (per «Scegli un'altra
  /// versione…»), dalla più nuova.
  Future<List<MrVersion>> versionsFor(String projectId) async {
    final d = _draft!;
    final all = await env.modrinth.versions(
      projectId,
      gameVersions: [d.mcVersion],
      loaders: d.loader == Loader.vanilla ? null : compatibleLoaders(d.loader),
    );
    return all..sort(newestFirst);
  }

  /// Mette la mod e le dipendenze nelle modifiche.
  void add(AddPlan plan) {
    if (!plan.ok) return;
    _edit(plan.apply);
    _results = [
      for (final r in _results)
        r.hit.projectId == plan.projectId
            ? SearchHitView(r.hit, fits: r.fits, loaders: r.loaders, installed: true)
            : r,
    ];
    _notify();
  }

  /// Aggiunge un jar scelto a mano (resta così com'è, mai aggiornato).
  Future<PackMod?> addJar(String path, {PackSide side = PackSide.server}) async {
    final d = _draft, r = root;
    if (d == null || r == null) return null;
    final name = p.basename(path);
    final rel = side == PackSide.client ? '$clientOverridesDir/mods/$name' : 'mods/$name';
    final dest = insideRoot(r, rel);
    final f = File(path);
    if (!f.existsSync()) throw FileSystemException('non trovato', path);
    final hashed = await hashFile(path, relPath: rel);
    final m = manualEntry(hashed, side: side);
    if (p.normalize(f.absolute.path) != p.normalize(File(dest).absolute.path)) {
      await Directory(p.dirname(dest)).create(recursive: true);
      await f.copy(dest);
    }
    // il file è già al suo posto: per il pack nuovo non c'è niente da
    // scaricare, ma il pack di partenza non lo conosce
    _edit((d) => d.withMods([m]));
    return m;
  }

  // --- versione e loader --------------------------------------------------------------

  /// Controlla ogni mod per [mcVersion] e [loader] prima di cambiarli.
  Future<CompatReport> checkRetarget(String mcVersion, Loader loader, String? loaderVersion) async {
    final d = _draft!;
    final target = PackTarget(mcVersion, loader);
    try {
      final cat = await CatalogLoader(env.modrinth).forRetarget(d, target);
      _modrinthOk();
      return planRetarget(
        d,
        cat,
        mcVersion: mcVersion,
        loader: loader,
        loaderVersion: loader == Loader.vanilla ? null : loaderVersion,
      );
    } on ModrinthUnavailable {
      _modrinthFailed();
      rethrow;
    }
  }

  /// Mette il cambio nelle modifiche: le pronte portate alla versione nuova,
  /// le bloccate tolte.
  void retarget(CompatReport report, {bool keepManual = true}) {
    _edit((_) => report.apply(keepManual: keepManual));
    unawaitedClearWatch();
  }

  /// Versioni del loader per [mcVersion] (stabili prima).
  Future<List<(String, bool)>> loaderVersions(Loader loader, String mcVersion) =>
      env.installer().loaderVersions(loader, mcVersion);

  /// Versioni di Minecraft (solo release se [releasesOnly]).
  Future<List<String>> minecraftVersions({bool releasesOnly = true}) async => [
    for (final v in await env.installer().mojangVersions())
      if (!releasesOnly || v.type == 'release') v.id,
  ];

  /// "Avvisami quando sono pronte": ricontrolla a ogni apertura.
  String? get watch => app.config.prefs['modpack.watch.$id'] as String?;

  /// Il controllo salvato ora non ha più mod bloccate.
  bool _watchReady = false;
  bool get watchReady => _watchReady;

  Future<void> setWatch(String mcVersion, Loader loader, String? loaderVersion) =>
      app.setPref('modpack.watch.$id', [mcVersion, loader.name, ?loaderVersion].join('|'));

  void unawaitedClearWatch() {
    _watchReady = false;
    if (watch != null) unawaited(app.setPref('modpack.watch.$id', null));
  }

  Future<void> _checkWatch() async {
    final w = watch;
    if (w == null || _draft == null) return;
    final f = w.split('|');
    final loader = _loaderOf(f.length > 1 ? f[1] : null);
    if (loader == null) return;
    try {
      final r = await checkRetarget(f[0], loader, f.length > 2 ? f[2] : null);
      if (r.blocked.isEmpty && !_watchReady) {
        _watchReady = true;
        _notify();
        await app.deps.platform.notifications.show(
          title: summary?.name ?? id,
          body: AppStrings(app.lang).modpack.watchReadyNotice(f[0]),
        );
      }
    } on Object {
      // si riprova alla prossima apertura
    }
  }

  // --- applicazione ----------------------------------------------------------------------

  ApplyState _apply = const ApplyIdle();
  ApplyState get applyState => _apply;
  bool _queued = false;

  /// Le modifiche aspettano che il server si liberi.
  bool get queued => _queued;

  /// Chi tiene il server, se qualcuno ci gioca (lock vivo, anche il mio).
  String? get holder {
    final l = summary?.lock;
    return l == null || l.stale ? null : l.name;
  }

  bool get locked => holder != null;
  bool get applying => _apply is Applying;

  /// Applica quando il server si libera (avvisando prima).
  void queueApply(bool on) {
    _queued = on && dirty;
    _apply = _queued ? ApplyQueued(holder ?? '') : const ApplyIdle();
    _notify();
    if (_queued && !locked) unawaited(apply());
  }

  void _onApp() {
    if (_queued && !locked && !applying && app.connection == Connection.online) {
      _queued = false;
      unawaited(() async {
        await app.deps.platform.notifications.show(
          title: summary?.name ?? id,
          body: AppStrings(app.lang).modpack.queuedNotice,
        );
        await apply();
      }());
    }
    _notify();
  }

  /// Applica le modifiche: copia locale alla testa, server nuovo se cambia
  /// versione o loader, mod scaricate e verificate (se qualcosa fallisce la
  /// cartella non cambia), pack scritto, caricamento sull'hub.
  Future<ApplyState> apply() async {
    final r = root, d = _draft, b = _base;
    if (r == null || d == null || b == null || applying) return _apply;
    if (locked) return _done(ApplyFailed('locked', holder));
    final count = changeCount;
    final diff = PackDiff(b, d);

    // 0. il pack sul disco è cambiato da quando è stato letto (es. pre-scarico)
    if (!_baseIsNew) {
      final now = await readPackFile(r);
      if (now != null && now != b) {
        _base = now;
        _draft = now;
        return _done(const ApplyFailed('changedMeanwhile'));
      }
    }

    // 1. la copia locale deve essere alla testa, o il caricamento fallisce
    if (!space.upToDate && (summary?.headN ?? 0) > 0) {
      _set2(const Applying('pull'));
      final pulled = await space.pull();
      if (pulled == null) return _done(ApplyFailed('pull', _outcomeError()));
      final now = await readPackFile(r);
      if (now != null && now != b) {
        // qualcun altro ha cambiato le mod: si rifà il conto sulla nuova base
        _base = now;
        _draft = now;
        return _done(const ApplyFailed('changedMeanwhile'));
      }
    }

    // 2. server nuovo se cambiano versione o loader
    if (diff.mcVersion != null || diff.loader != null) {
      final need = requiredJava(d.mcVersion);
      await space.ensureJava();
      final java = pickJava(space.javas ?? const [], need);
      if (java == null || (need > 0 && java.major > 0 && java.major < need)) {
        return _done(ApplyFailed('java', need));
      }
      _set2(const Applying('install'));
      try {
        await env.installer().install(
          ServerInstallRequest(
            dir: r,
            mcVersion: d.mcVersion,
            loader: d.loader,
            loaderVersion: d.loaderVersion,
            javaPath: java.path,
          ),
        );
      } on Object catch (e) {
        return _done(ApplyFailed('install', e));
      }
    }

    // 3. mod: tutto scaricato e verificato prima di toccare la cartella
    try {
      final files = await env.scanMods(r);
      final plan = planInstall(from: _baseIsNew ? null : b, to: d, files: files);
      if (plan.unavailable.isNotEmpty) {
        return _done(ApplyFailed('unavailable', null, plan.unavailable));
      }
      final total = plan.downloadBytes;
      var done = 0;
      final got = <String, int>{};
      _set2(Applying('download', total: total));
      await applyInstallPlan(
        r,
        plan,
        env.downloader,
        onProgress: (dl, received, _) {
          got[dl.location] = received;
          done = got.values.fold(0, (a, x) => a + x);
          _set2(
            Applying('download', done: done, total: total, current: dl.mod.name ?? dl.mod.file),
          );
        },
      );
    } on Object catch (e) {
      return _done(ApplyFailed('download', e));
    }
    _base = d;
    _baseIsNew = false;

    // 4. caricamento normale (nuova generazione)
    _set2(const Applying('push'));
    final pushed = await space.push(message: AppStrings(app.lang).modpack.pushMessage(count));
    if (pushed == null) return _done(ApplyFailed('push', _outcomeError()));
    _updates = const [];
    // la testa nuova subito, senza aspettare l'evento dell'hub
    await app.refreshSpaces().catchError((Object _) {});
    return _done(ApplyDone(pushed.generation?.n, count));
  }

  Object? _outcomeError() => switch (space.outcome) {
    OpFailed(:final error) => error,
    _ => null,
  };

  ApplyState _done(ApplyState s) {
    _apply = s;
    _notify();
    return s;
  }

  void _set2(ApplyState s) {
    _apply = s;
    _notify();
  }

  /// Chiude l'esito mostrato.
  void clearApply() {
    if (_apply is ApplyDone || _apply is ApplyFailed) _apply = const ApplyIdle();
    _notify();
  }

  // --- pacchetto per i giocatori ---------------------------------------------------------

  /// Facoltative scelte su questo PC (chiavi delle mod).
  Set<String> get chosenOptional {
    final v = app.config.prefs['modpack.optional.$id'];
    if (v is List) return {...v.whereType<String>()};
    // di default: tutte le facoltative
    return {
      for (final m in _base?.mods ?? const <PackMod>[])
        if (m.optional) m.key,
    };
  }

  Future<void> chooseOptional(String key, bool on) async {
    final s = chosenOptional;
    on ? s.add(key) : s.remove(key);
    await app.setPref('modpack.optional.$id', s.toList()..sort());
    _notify();
  }

  /// Dove è stato preparato il pacchetto l'ultima volta.
  ClientInstall? get clientInstall =>
      ClientInstall.fromJson(app.config.prefs['modpack.client.$id']);

  /// Il pack com'era quando è stato preparato (per dire cosa è cambiato).
  Pack? get clientSnapshot {
    try {
      final f = File(_snapshotPath);
      return f.existsSync() ? Pack.decode(f.readAsStringSync()) : null;
    } on Object {
      return null;
    }
  }

  String get _snapshotPath => p.join(app.deps.configDir, 'modpack', '$id.client.json');

  bool? _prismChecked;
  String? _prism;

  /// Prism Launcher su questo PC (null finché non si è cercato).
  bool? get prismFound => _prismChecked;
  String? get prismPath => _prism;

  /// Cartella del launcher ufficiale, se c'è.
  String? get launcherDir => env.tools.officialLauncher();

  Future<void> findPrism() async {
    _prism = await env.tools.prism();
    _prismChecked = _prism != null;
    _notify();
  }

  String? _clientBusy;
  Object? _clientError;
  String? _exported;

  /// Operazione in corso sul pacchetto: `export`, `prism`, `launcher`.
  String? get clientBusy => _clientBusy;
  Object? get clientError => _clientError;

  /// Ultimo file esportato.
  String? get exported => _exported;

  /// Nome del file `.mrpack` per la generazione [n].
  String mrpackName(int n) {
    final name = (_base?.name ?? summary?.name ?? id).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '$name-$n.mrpack';
  }

  /// La copia locale è alla testa: si può preparare il pacchetto da lei.
  bool get clientReady => space.upToDate && _base != null && !_baseIsNew;

  /// Esporta il `.mrpack` (con le facoltative scelte qui) nella cartella
  /// Download. Restituisce il percorso.
  Future<String?> exportMrpack({String target = 'file'}) async {
    final r = root, b = _base;
    final n = space.baseN ?? 0;
    if (r == null || b == null || _clientBusy != null) return null;
    _clientBusy = target == 'prism' ? 'prism' : 'export';
    _clientError = null;
    _notify();
    try {
      final out = p.join(env.tools.downloads(), mrpackName(n));
      await exportClientMrpack(
        r,
        b,
        out,
        versionId: '$n',
        name: b.name ?? summary?.name,
        chosenOptional: chosenOptional,
      );
      _exported = out;
      if (target == 'prism') {
        final exe = _prism ?? await env.tools.prism();
        if (exe == null) throw const LauncherProfileError('noPrism');
        await env.tools.openInPrism(exe, out);
      }
      await _remember(target, n, out, b);
      return out;
    } on Object catch (e) {
      _clientError = e;
      return null;
    } finally {
      _clientBusy = null;
      _notify();
    }
  }

  /// Crea (o aggiorna) il profilo nel launcher ufficiale.
  Future<LauncherProfileResult?> createProfile() async {
    final r = root, b = _base, dir = launcherDir;
    final n = space.baseN ?? 0;
    if (r == null || b == null || dir == null || _clientBusy != null) return null;
    _clientBusy = 'launcher';
    _clientError = null;
    _notify();
    try {
      final plan = planClientPack(
        b,
        await listServerFiles(r),
        versionId: '$n',
        name: b.name,
        chosenOptional: chosenOptional,
      );
      final res = await createLauncherProfile(
        launcherDir: dir,
        spaceId: id,
        displayName: summary?.name ?? id,
        plan: plan,
        serverRoot: r,
        dl: env.downloader,
        now: app.now(),
      );
      await _remember('launcher', n, res.gameDir, b);
      return res;
    } on Object catch (e) {
      _clientError = e;
      return null;
    } finally {
      _clientBusy = null;
      _notify();
    }
  }

  Future<void> _remember(String target, int n, String path, Pack pack) async {
    await app.setPref(
      'modpack.client.$id',
      ClientInstall(target: target, n: n, path: path).toJson(),
    );
    await writeFileAtomic(_snapshotPath, pack.encodeBytes());
  }

  Future<void> openUrl(String url) => env.tools.openUrl(url);

  // --- test ---------------------------------------------------------------------------

  /// Imposta lo stato senza IO, per i test e le anteprime.
  @visibleForTesting
  void debugSet({
    PackPhase? phase,
    Pack? base,
    Pack? draft,
    bool? packIsNew,
    List<UpdateCheck>? updates,
    DateTime? updatesAt,
    bool? modrinthDown,
    DateTime? lastAttempt,
    String? query,
    List<SearchHitView>? results,
    bool? onlyCompatible,
    Object? searchError,
    ApplyState? applyState,
    bool? queued,
    bool? prismFound,
    String? exported,
  }) {
    if (phase != null) _phase = phase;
    if (base != null) _base = base;
    if (draft != null) _draft = draft;
    if (base != null && draft == null) _draft ??= base;
    if (packIsNew != null) _baseIsNew = packIsNew;
    if (updates != null) _updates = updates;
    if (updatesAt != null) _updatesAt = updatesAt;
    if (modrinthDown != null) _modrinthDown = modrinthDown;
    if (lastAttempt != null) _lastAttempt = lastAttempt;
    if (query != null) _query = query;
    if (results != null) _results = results;
    if (onlyCompatible != null) _onlyCompatible = onlyCompatible;
    if (searchError != null) _searchError = searchError;
    if (applyState != null) _apply = applyState;
    if (queued != null) _queued = queued;
    if (prismFound != null) {
      _prismChecked = prismFound;
      _prism = prismFound ? '/usr/bin/prismlauncher' : null;
    }
    if (exported != null) _exported = exported;
    _notify();
  }

  // --- icone delle mod -----------------------------------------------------------

  final _icons = <String, String?>{};
  bool _iconsLoading = false;

  /// URL dell'icona del progetto Modrinth [projectId], se già letta.
  String? iconUrlOf(String? projectId) => projectId == null ? null : _icons[projectId];

  /// Legge da Modrinth le icone delle mod che non ha ancora (a blocchi di
  /// 100, una volta per progetto; le risposte restano nella cache su disco).
  Future<void> loadIcons() async {
    final d = _draft ?? _base;
    if (_iconsLoading || d == null) return;
    final ids = {
      for (final m in d.mods)
        if (m.projectId != null && !_icons.containsKey(m.projectId)) m.projectId!,
    }.toList();
    if (ids.isEmpty) return;
    _iconsLoading = true;
    try {
      for (var i = 0; i < ids.length; i += 100) {
        final chunk = ids.sublist(i, i + 100 > ids.length ? ids.length : i + 100);
        for (final id in chunk) {
          _icons[id] = null;
        }
        for (final p in await env.modrinth.projects(chunk)) {
          _icons[p.id] = p.iconUrl;
        }
      }
    } on Object {
      // senza Modrinth restano i segnaposto
    } finally {
      _iconsLoading = false;
      _notify();
    }
  }

  void _set(PackPhase ph) {
    _phase = ph;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    app.removeListener(_onApp);
    super.dispose();
  }
}
