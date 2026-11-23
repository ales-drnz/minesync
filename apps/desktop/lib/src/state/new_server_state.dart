// Procedura «Nuovo server» (admin): da zero (versione di Minecraft, loader,
// memoria, Java, mod consigliate), da un modpack (.mrpack sul PC o trovato
// su Modrinth) o da una cartella esistente. Finché non si accetta l'EULA
// sull'hub non succede niente; poi tutto si prepara in una cartella
// temporanea sul PC e solo alla fine si crea il server sull'hub e si fa il
// primo caricamento. Un passo fallito si riprova da dove si è fermato.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:ms_modpack/io.dart';
import 'package:ms_modpack/ms_modpack.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:path/path.dart' as p;

import 'app_state.dart';
import 'space_state.dart';

/// Da dove parte il server.
enum NsOrigin { scratch, modpack, folder }

/// Da dove viene il modpack: il catalogo di Modrinth o un file sul PC.
enum NsPackSource { browse, file }

/// Passi della procedura.
enum NsStep { origin, version, modpack, folder, mods, eula, create }

/// Passi della creazione, ognuno con il suo esito.
enum NsTask { server, mods, files, hub, push }

enum NsTaskState { pending, running, done, failed }

/// Una mod consigliata per un server nuovo.
@immutable
final class RecommendedMod {
  const RecommendedMod(this.slug, this.name, this.side, this.loaders);
  final String slug;
  final String name;
  final PackSide side;
  final Set<Loader> loaders;
}

/// Mod consigliate (slug di Modrinth), per loader.
const recommendedMods = [
  RecommendedMod('lithium', 'Lithium', PackSide.both, {
    Loader.fabric,
    Loader.quilt,
    Loader.neoforge,
  }),
  RecommendedMod('ferrite-core', 'FerriteCore', PackSide.both, {
    Loader.fabric,
    Loader.quilt,
    Loader.neoforge,
    Loader.forge,
  }),
  RecommendedMod('krypton', 'Krypton', PackSide.server, {Loader.fabric}),
  RecommendedMod('chunky', 'Chunky', PackSide.server, {
    Loader.fabric,
    Loader.quilt,
    Loader.neoforge,
    Loader.forge,
  }),
  RecommendedMod('spark', 'spark', PackSide.both, {
    Loader.fabric,
    Loader.quilt,
    Loader.neoforge,
    Loader.forge,
  }),
];

/// Fabric API: quasi tutte le mod Fabric la chiedono, si mette sempre.
const fabricApiSlug = 'fabric-api';

/// Lunghezza massima del nome di un server (caratteri).
const nsMaxName = 40;

final class NewServerController extends ChangeNotifier {
  NewServerController(this.app);

  final AppState app;
  bool _disposed = false;

  ModpackEnv get env => app.modpackEnv;

  // --- passo 1 -------------------------------------------------------------------

  String name = '';
  NsOrigin origin = NsOrigin.scratch;
  NsStep _step = NsStep.origin;
  NsStep get step => _step;

  void setOrigin(NsOrigin o) {
    origin = o;
    _notify();
  }

  void setName(String v) {
    name = v;
    _notify();
  }

  String? get nameError {
    final n = name.trim();
    if (n.isEmpty) return 'empty';
    if (n.runes.length > nsMaxName) return 'long';
    return null;
  }

  /// I passi mostrati nell'indicatore in alto: sempre da «Origine» a
  /// «EULA», fissi per ogni strada (la creazione è l'avanzamento dopo
  /// «Accetto e creo», non un passo). Quelli che la strada salta restano
  /// visibili come saltati, vedi [skipped].
  List<NsStep> get steps => switch (origin) {
    NsOrigin.scratch => const [NsStep.origin, NsStep.version, NsStep.mods, NsStep.eula],
    NsOrigin.modpack => const [NsStep.origin, NsStep.modpack, NsStep.eula],
    NsOrigin.folder => const [NsStep.origin, NsStep.folder, NsStep.eula],
  };

  /// Passo che la strada scelta salta: le mod con Vanilla, l'EULA per una
  /// cartella generica.
  bool skipped(NsStep s) => switch (s) {
    NsStep.mods => loader == Loader.vanilla,
    NsStep.eula => origin == NsOrigin.folder && profile != Profile.minecraft,
    _ => false,
  };

  /// Il percorso di Avanti e Indietro: i passi non saltati, poi la creazione.
  List<NsStep> get _path => [
    for (final s in steps)
      if (!skipped(s)) s,
    NsStep.create,
  ];

  void go(NsStep s) {
    _step = s;
    _notify();
    if (s == NsStep.version) unawaited(_prepareVersion());
    if (s == NsStep.modpack && packSource == NsPackSource.browse) browser.open();
  }

  /// Il passo dopo; se è la creazione (cartella generica, senza EULA) la
  /// avvia.
  void next() {
    final l = _path;
    final i = l.indexOf(_step);
    if (i < 0 || i >= l.length - 1) return;
    if (l[i + 1] == NsStep.create) {
      unawaited(acceptAndCreate());
    } else {
      go(l[i + 1]);
    }
  }

  void back() {
    final l = _path;
    final i = l.indexOf(_step);
    if (i > 0 && _step != NsStep.create) go(l[i - 1]);
  }

  // --- da zero ---------------------------------------------------------------------

  List<String>? _mcVersions;
  bool releasesOnly = true;
  String? mc;
  Loader loader = Loader.fabric;
  List<(String, bool)>? _loaderVersions;
  String? loaderVersion;
  int memoryGb = 6;
  Object? versionError;

  List<String>? get mcVersions => _mcVersions;
  List<(String, bool)>? get loaderVersionList => _loaderVersions;

  Future<void> _prepareVersion() async {
    if (_mcVersions == null) await loadMcVersions();
    if (_javas == null) await findJava();
  }

  Future<void> loadMcVersions() async {
    try {
      final all = await env.installer().mojangVersions();
      _mcVersions = [
        for (final v in all)
          if (!releasesOnly || v.type == 'release') v.id,
      ];
      versionError = null;
      mc ??= _mcVersions!.contains('1.21.1') ? '1.21.1' : _mcVersions!.firstOrNull;
    } on Object catch (e) {
      _mcVersions = const [];
      versionError = e;
    }
    _notify();
    await loadLoaderVersions();
  }

  void setMc(String v) {
    mc = v;
    _notify();
    unawaited(loadLoaderVersions());
  }

  void setLoader(Loader l) {
    loader = l;
    chosenMods.removeWhere(
      (s) => !recommendedMods.any((m) => m.slug == s && m.loaders.contains(l)),
    );
    _notify();
    unawaited(loadLoaderVersions());
  }

  Future<void> loadLoaderVersions() async {
    final v = mc;
    if (v == null || loader == Loader.vanilla) {
      _loaderVersions = const [];
      loaderVersion = null;
      _notify();
      return;
    }
    _loaderVersions = null;
    _notify();
    try {
      final l = await env.installer().loaderVersions(loader, v);
      _loaderVersions = l;
      loaderVersion = (l.where((e) => e.$2).firstOrNull ?? l.firstOrNull)?.$1;
    } on Object catch (e) {
      _loaderVersions = const [];
      loaderVersion = null;
      versionError = e;
    }
    _notify();
  }

  // --- Java ------------------------------------------------------------------------

  List<JavaRuntime>? _javas;
  bool _javaLoading = false;
  List<JavaRuntime>? get javas => _javas;
  bool get javaLoading => _javaLoading;

  /// Versione di Minecraft del server da creare.
  String? get targetMc => switch (origin) {
    NsOrigin.scratch => mc,
    NsOrigin.modpack => imported?.pack.mcVersion,
    NsOrigin.folder => folderLayout?.mcVersion,
  };

  int get javaNeeded => requiredJava(targetMc);

  JavaRuntime? get java => pickJava(_javas ?? const [], javaNeeded);

  /// Java adatto trovato (vero anche se non si sa cosa serve).
  bool get javaOk {
    final j = java;
    return j != null && (javaNeeded == 0 || j.major == 0 || j.major >= javaNeeded);
  }

  Future<void> findJava() async {
    if (_javaLoading) return;
    _javaLoading = true;
    _notify();
    try {
      _javas = await app.localProbe.java();
    } on Object {
      _javas = const [];
    } finally {
      _javaLoading = false;
      _notify();
    }
  }

  // --- mod consigliate ---------------------------------------------------------------

  final chosenMods = <String>{};

  List<RecommendedMod> get recommended => [
    for (final m in recommendedMods)
      if (m.loaders.contains(loader)) m,
  ];

  void toggleMod(String slug, bool on) {
    on ? chosenMods.add(slug) : chosenMods.remove(slug);
    _notify();
  }

  // --- da un modpack -------------------------------------------------------------------

  /// Catalogo dei modpack di Modrinth (si carica aprendo il passo).
  late final PackBrowser browser = PackBrowser(env.modrinth);

  /// Sfoglia Modrinth o «Ho già un file .mrpack».
  NsPackSource packSource = NsPackSource.browse;

  String mrpackPath = '';

  /// Il `.mrpack` letto così com'è.
  MrpackImport? imported;

  /// Divisione fra server e giocatori di [imported].
  ServerSplit? split;

  /// Mod di lato sconosciuto che l'admin toglie dal server (chiavi
  /// [PackMod.key]); di base restano sul server.
  final excludedUnknown = <String>{};
  Object? importError;
  bool importing = false;

  /// Avanzamento del download del `.mrpack`: byte ricevuti e totali (0 se
  /// non noti), null prima del primo dato. A parte dal resto dello stato:
  /// aggiorna solo la barra, non tutto il wizard.
  final packProgress = ValueNotifier<(int, int)?>(null);

  /// Il modpack scelto dal catalogo (null se dal file).
  MrSearchHit? packChosen;

  /// La versione scelta del modpack (null se dal file).
  MrVersion? packVersion;

  /// Il modpack è pubblicato solo per i giocatori (Modrinth: il server non
  /// è supportato): si costruisce il server togliendo le mod solo client.
  bool get packClientOnly => packChosen?.serverSide == MrEnv.unsupported;

  /// L'import da installare sul server (con le mod solo client da parte).
  MrpackImport? get serverImport => split?.apply(excluded: excludedUnknown) ?? imported;

  void setPackSource(NsPackSource s) {
    packSource = s;
    if (s == NsPackSource.browse) browser.open();
    _notify();
  }

  /// Tiene sul server ([on]) o lascia ai giocatori una mod di lato
  /// sconosciuto.
  void keepUnknownOnServer(String key, bool on) {
    on ? excludedUnknown.remove(key) : excludedUnknown.add(key);
    _notify();
  }

  /// Torna al catalogo (o al file) per scegliere un altro modpack.
  void changePack() {
    imported = null;
    split = null;
    excludedUnknown.clear();
    importError = null;
    packChosen = null;
    packVersion = null;
    _notify();
  }

  Future<void> openMrpack() async {
    final path = mrpackPath.trim();
    if (path.isEmpty) return;
    importing = true;
    importError = null;
    _notify();
    try {
      final imp = await readMrpackFile(path, name: name.trim().isEmpty ? null : name.trim());
      await _setImport(imp);
      packChosen = null;
      packVersion = null;
      if (name.trim().isEmpty) name = imp.index.name;
      unawaited(findJava());
    } on Object catch (e) {
      imported = null;
      split = null;
      importError = e;
    } finally {
      importing = false;
      _notify();
    }
  }

  Future<void> _setImport(MrpackImport imp) async {
    final sp = await resolveServerSplit(imp, env.modrinth);
    imported = imp;
    split = sp;
    excludedUnknown.clear();
  }

  /// Scarica il `.mrpack` della versione scelta nel catalogo e lo apre.
  Future<void> usePack() async {
    final h = browser.selected, v = browser.version;
    if (h == null || v == null || importing) return;
    importing = true;
    importError = null;
    packProgress.value = null;
    _notify();
    try {
      final f =
          v.files.where((f) => f.primary && f.filename.endsWith('.mrpack')).firstOrNull ??
          v.files.where((f) => f.filename.endsWith('.mrpack')).firstOrNull ??
          v.primaryFile;
      if (f == null) throw const MrpackError('noIndex');
      final dir = await Directory(app.worldsDir).create(recursive: true);
      final dest = p.join(dir.path, '.minesync-${h.slug}-${v.id}.mrpack');
      await env.downloader.download(
        [f.url],
        dest,
        sha1: f.sha1,
        sha512: f.sha512,
        size: f.size,
        onProgress: (r, t) {
          packProgress.value = (r, t ?? f.size);
        },
      );
      final MrpackImport imp;
      try {
        imp = await readMrpackFile(dest, name: name.trim().isEmpty ? h.title : name.trim());
      } finally {
        await File(dest).delete().catchError((Object _) => File(dest));
      }
      await _setImport(imp);
      packChosen = h;
      packVersion = v;
      if (name.trim().isEmpty) name = h.title;
      unawaited(findJava());
    } on Object catch (e) {
      imported = null;
      split = null;
      importError = e;
    } finally {
      importing = false;
      packProgress.value = null;
      _notify();
    }
  }

  // --- da una cartella ---------------------------------------------------------------

  String folderPath = '';
  ServerLayout? folderLayout;
  Object? folderError;
  Profile profile = Profile.minecraft;
  int folderMods = 0;

  Future<void> checkFolder() async {
    final path = folderPath.trim();
    if (path.isEmpty) return;
    try {
      if (!Directory(path).existsSync()) throw FileSystemException('non trovata', path);
      final scan = await app.localProbe.scan(path);
      folderLayout = scan.layout;
      folderMods = scan.mods;
      folderError = null;
      // senza un nome si propone quello della cartella
      if (name.trim().isEmpty) {
        name = String.fromCharCodes(p.basename(p.normalize(path)).runes.take(nsMaxName));
      }
    } on Object catch (e) {
      folderLayout = null;
      folderError = e;
    }
    _notify();
  }

  void setProfile(Profile v) {
    profile = v;
    _notify();
  }

  // --- creazione ------------------------------------------------------------------

  final tasks = <NsTask, NsTaskState>{};
  NsTask? failed;
  Object? error;
  String? _tmp;
  SpaceSummary? created;
  int? firstGeneration;
  String? folder;

  /// Avanzamento del download in corso (0..1, null se indeterminato).
  double? progress;
  String? progressLabel;

  List<NsTask> get taskList => switch (origin) {
    NsOrigin.scratch => [
      NsTask.server,
      if (loader != Loader.vanilla) NsTask.mods,
      NsTask.hub,
      NsTask.push,
    ],
    NsOrigin.modpack => [NsTask.server, NsTask.mods, NsTask.hub, NsTask.push],
    NsOrigin.folder => [NsTask.files, NsTask.hub, NsTask.push],
  };

  bool get creating => tasks.values.contains(NsTaskState.running);
  bool get done => created != null && tasks[NsTask.push] == NsTaskState.done;

  /// Accetta l'EULA (con il clic dell'utente) e crea il server.
  Future<void> acceptAndCreate() async {
    go(NsStep.create);
    await create();
  }

  /// Crea (o riprende dal passo fallito).
  Future<void> create() async {
    if (creating) return;
    failed = null;
    error = null;
    _tmp ??= p.join(app.worldsDir, '.minesync-new-${app.now().millisecondsSinceEpoch}');
    for (final t in taskList) {
      tasks.putIfAbsent(t, () => NsTaskState.pending);
    }
    _notify();
    for (final t in taskList) {
      if (tasks[t] == NsTaskState.done) continue;
      tasks[t] = NsTaskState.running;
      _notify();
      try {
        await _run(t);
        tasks[t] = NsTaskState.done;
        progress = null;
        progressLabel = null;
      } on Object catch (e) {
        tasks[t] = NsTaskState.failed;
        failed = t;
        error = e;
        _notify();
        return;
      }
      _notify();
    }
  }

  Future<void> _run(NsTask t) async {
    final tmp = _tmp!;
    switch (t) {
      case NsTask.server:
        final (mcv, l, lv) = origin == NsOrigin.modpack
            ? (imported!.pack.mcVersion, imported!.pack.loader, imported!.pack.loaderVersion)
            : (mc!, loader, loaderVersion);
        final j = java;
        if (!javaOk) throw InstallFailed('java', 'Java ${requiredJava(mcv)}');
        await env.installer().install(
          ServerInstallRequest(
            dir: tmp,
            mcVersion: mcv,
            loader: l,
            loaderVersion: l == Loader.vanilla ? null : lv,
            javaPath: j?.path,
            acceptEula: true,
          ),
        );
      case NsTask.mods:
        final Pack pack;
        if (origin == NsOrigin.modpack) {
          // le mod solo per i giocatori vanno in client-overrides/
          final imp = serverImport!;
          await writeImportFiles(tmp, imp);
          pack = imp.pack;
        } else {
          var pk = Pack(
            name: name.trim(),
            mcVersion: mc!,
            loader: loader,
            loaderVersion: loaderVersion,
          );
          final slugs = [if (loader == Loader.fabric) fabricApiSlug, ...chosenMods];
          for (final slug in slugs) {
            final pr = await env.modrinth.project(slug);
            if (pk.byProject(pr.id) != null) continue;
            final cat = await CatalogLoader(env.modrinth).forAdd(pk, pr.id);
            final plan = planAdd(pk, cat, pr.id);
            if (plan.ok) pk = plan.apply(pk);
          }
          pack = pk;
        }
        final plan = planInstall(to: pack, files: await env.scanMods(tmp));
        final total = plan.downloadBytes;
        final got = <String, int>{};
        await applyInstallPlan(
          tmp,
          plan,
          env.downloader,
          onProgress: (d, r, _) {
            got[d.location] = r;
            final n = got.values.fold(0, (a, x) => a + x);
            progress = total > 0 ? (n / total).clamp(0.0, 1.0) : null;
            progressLabel = d.mod.name ?? d.mod.file;
            _notify();
          },
        );
      case NsTask.files:
        if (!Directory(tmp).existsSync()) {
          await _copyDir(Directory(folderPath.trim()), Directory('$tmp.part'));
          await Directory('$tmp.part').rename(tmp);
        }
        if (profile == Profile.minecraft) await acceptEula(tmp);
      case NsTask.hub:
        final sp = created ??= await app.createSpace(name.trim(), profile);
        final dest = app.defaultFolderFor(sp.id);
        if (Directory(tmp).existsSync()) {
          if (Directory(dest).existsSync()) {
            throw FileSystemException('esiste già', dest);
          }
          await Directory(p.dirname(dest)).create(recursive: true);
          await Directory(tmp).rename(dest);
        }
        folder = dest;
        await app.spaceState(sp.id).linkTo(dest);
        if (origin != NsOrigin.folder) {
          await app.setPref(ServerPrefs.key(sp.id, 'xmx'), memoryGb * 1024);
        }
      case NsTask.push:
        final ss = app.spaceState(created!.id);
        final r = await ss.push(message: 'MineSync: ${name.trim()}');
        if (r == null) {
          throw switch (ss.outcome) {
            OpFailed(:final error) => error,
            _ => StateError('push'),
          };
        }
        firstGeneration = r.generation?.n;
    }
  }

  static Future<void> _copyDir(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final e in from.list(followLinks: false)) {
      final name = p.basename(e.path);
      if (name.startsWith('.minesync')) continue;
      final dest = p.join(to.path, name);
      if (e is Directory) {
        await _copyDir(e, Directory(dest));
      } else if (e is File) {
        await e.copy(dest);
      }
    }
  }

  /// Toglie la cartella temporanea se la creazione non è arrivata all'hub.
  Future<void> abandon() async {
    final t = _tmp;
    if (t == null || created != null) return;
    for (final d in [t, '$t.part']) {
      final dir = Directory(d);
      if (dir.existsSync()) await dir.delete(recursive: true).catchError((Object _) => dir);
    }
  }

  /// Imposta lo stato senza IO, per i test e le anteprime.
  @visibleForTesting
  void debugSet({
    NsStep? step,
    List<String>? mcVersions,
    List<(String, bool)>? loaderVersions,
    List<JavaRuntime>? javas,
    Map<NsTask, NsTaskState>? tasks,
    NsTask? failed,
    Object? error,
    SpaceSummary? created,
    int? firstGeneration,
    double? progress,
    String? progressLabel,
    MrpackImport? imported,
    ServerSplit? split,
    MrSearchHit? packChosen,
    MrVersion? packVersion,
    NsPackSource? packSource,
    bool? importing,
    ServerLayout? folderLayout,
  }) {
    if (step != null) _step = step;
    if (mcVersions != null) _mcVersions = mcVersions;
    if (loaderVersions != null) _loaderVersions = loaderVersions;
    if (javas != null) _javas = javas;
    if (tasks != null) {
      this.tasks
        ..clear()
        ..addAll(tasks);
    }
    if (failed != null) this.failed = failed;
    if (error != null) this.error = error;
    if (created != null) this.created = created;
    if (firstGeneration != null) this.firstGeneration = firstGeneration;
    if (progress != null) this.progress = progress;
    if (progressLabel != null) this.progressLabel = progressLabel;
    if (imported != null) this.imported = imported;
    if (split != null) this.split = split;
    if (packChosen != null) this.packChosen = packChosen;
    if (packVersion != null) this.packVersion = packVersion;
    if (packSource != null) this.packSource = packSource;
    if (importing != null) this.importing = importing;
    if (folderLayout != null) this.folderLayout = folderLayout;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    browser.dispose();
    packProgress.dispose();
    super.dispose();
  }
}
