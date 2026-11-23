// Risolutore del modpack: aggiungere una mod con le dipendenze obbligatorie,
// aggiornare (una o tutte) con il motivo quando non si può, togliere con chi
// ne dipende, cambiare versione di Minecraft o loader con un rapporto mod per
// mod. Puro e deterministico: lavora su un [ModCatalog] già caricato (lo
// riempie [CatalogLoader] con il client Modrinth), mai sulla rete.
import 'package:ms_protocol/ms_protocol.dart' show Loader;

import 'modrinth.dart';
import 'modrinth_models.dart';
import 'pack.dart';

/// Dove deve funzionare una mod: versione di Minecraft e loader.
final class PackTarget {
  const PackTarget(this.mcVersion, this.loader);

  factory PackTarget.of(Pack p) => PackTarget(p.mcVersion, p.loader);

  final String mcVersion;
  final Loader loader;

  /// La versione [v] gira qui: elenca [mcVersion] e un loader compatibile
  /// (Quilt accetta anche Fabric; vanilla solo `minecraft`, cioè resource
  /// pack e datapack).
  bool fits(MrVersion v) =>
      v.gameVersions.contains(mcVersion) && v.loaders.any(compatibleLoaders(loader).contains);

  @override
  bool operator ==(Object other) =>
      other is PackTarget && other.mcVersion == mcVersion && other.loader == loader;

  @override
  int get hashCode => Object.hash(mcVersion, loader);

  @override
  String toString() => '${loader.name} $mcVersion';
}

/// Dati di Modrinth già caricati.
abstract interface class ModCatalog {
  MrProject? project(String id);

  /// Versioni note di un progetto (anche già filtrate); null se non caricate.
  List<MrVersion>? versionsOf(String projectId);
  MrVersion? version(String versionId);
}

/// Catalogo in memoria.
final class MemoryCatalog implements ModCatalog {
  MemoryCatalog({
    Iterable<MrProject> projects = const [],
    Iterable<MrVersion> versions = const [],
  }) {
    projects.forEach(addProject);
    for (final v in versions) {
      addVersion(v);
    }
  }

  final _projects = <String, MrProject>{};
  final _versions = <String, MrVersion>{};
  final _byProject = <String, Map<String, MrVersion>>{};

  void addProject(MrProject p) => _projects[p.id] = p;

  /// Aggiunge una versione; con [listed] (default) conta tra le versioni del
  /// progetto, altrimenti è nota solo per id (una dipendenza precisa).
  void addVersion(MrVersion v, {bool listed = true}) {
    _versions[v.id] = v;
    if (listed) (_byProject[v.projectId] ??= {})[v.id] = v;
  }

  /// Segna le versioni di [projectId] come caricate (anche se nessuna).
  void markLoaded(String projectId) => _byProject[projectId] ??= {};

  bool hasVersionsOf(String projectId) => _byProject.containsKey(projectId);

  @override
  MrProject? project(String id) => _projects[id];

  @override
  List<MrVersion>? versionsOf(String projectId) => _byProject[projectId]?.values.toList();

  @override
  MrVersion? version(String versionId) => _versions[versionId];
}

/// Ordine delle versioni: più recente prima (data di pubblicazione), poi
/// `featured`, poi id (per essere deterministici).
int newestFirst(MrVersion a, MrVersion b) {
  final d = b.datePublished.compareTo(a.datePublished);
  if (d != 0) return d;
  if (a.featured != b.featured) return a.featured ? -1 : 1;
  return a.id.compareTo(b.id);
}

/// La versione migliore per [target]: la release più recente; se non ce ne
/// sono e [maxType] lo permette, la beta più recente, poi l'alpha. Null se
/// nessuna va bene.
MrVersion? bestVersion(
  Iterable<MrVersion> versions,
  PackTarget target, {
  MrVersionType maxType = MrVersionType.release,
}) {
  final fit = versions.where(target.fits).toList()..sort(newestFirst);
  for (final t in MrVersionType.values) {
    if (t.index > maxType.index) break;
    final v = fit.where((v) => v.versionType == t).firstOrNull;
    if (v != null) return v;
  }
  return null;
}

/// Perché un'operazione non si può fare.
enum BlockReason {
  /// Il progetto non ha versioni per la versione di Minecraft e il loader.
  noCompatibleVersion,

  /// Ci sono solo beta o alpha (MineSync non le sceglie da solo).
  onlyPrerelease,

  /// Una dipendenza obbligatoria non esiste per la versione e il loader.
  dependencyUnavailable,

  /// La dipendenza chiede una versione precisa che non gira qui
  /// ([Blocker.gameVersions] dice dove gira).
  dependencyIncompatible,

  /// Una dipendenza obbligatoria resta bloccata.
  dependencyBlocked,

  /// Incompatibile con una mod installata (o viceversa).
  conflict,

  /// Già nel pack.
  alreadyInstalled,

  /// I dati di Modrinth non sono stati caricati (rete): riprovare.
  notLoaded,
}

/// Un impedimento, con i dati per spiegarlo.
final class Blocker {
  const Blocker(
    this.reason, {
    required this.projectId,
    this.otherProjectId,
    this.versionId,
    this.versionNumber,
    this.gameVersions = const [],
  });

  final BlockReason reason;

  /// Il progetto che non si può installare o aggiornare.
  final String projectId;

  /// La dipendenza o la mod in conflitto, se c'entra.
  final String? otherProjectId;

  /// La versione richiesta (dipendenza precisa) o scelta.
  final String? versionId;
  final String? versionNumber;

  /// Dove gira la versione richiesta ([BlockReason.dependencyIncompatible]).
  final List<String> gameVersions;

  @override
  String toString() =>
      'Blocker(${reason.name}, $projectId${otherProjectId == null ? '' : ' ← $otherProjectId'})';
}

/// Cartella dell'istanza per un tipo di progetto Modrinth.
String folderFor(String projectType) => switch (projectType) {
  'resourcepack' => 'resourcepacks',
  'shader' => 'shaderpacks',
  _ => 'mods',
};

/// La voce del pack per la versione [v] del progetto [p] (lato da
/// `client_side`/`server_side`, se il progetto è noto).
PackMod modFromVersion(
  MrVersion v, {
  MrProject? project,
  ModCatalog? catalog,
  bool auto = false,
  PackMod? previous,
}) {
  final f = v.primaryFile;
  if (f == null) throw FormatException('versione ${v.id} senza file');
  final (side, optional) = project?.side ?? (PackSide.both, false);
  return PackMod(
    path: '${folderFor(project?.projectType ?? 'mod')}/${f.filename}',
    name: project?.title ?? previous?.name,
    sha1: f.sha1,
    sha512: f.sha512,
    size: f.size,
    // un lato scelto dall'admin resta
    side: previous?.side ?? side,
    optional: previous?.optional ?? optional,
    source: PackSource.modrinth,
    pinned: previous?.pinned ?? false,
    disabled: previous?.disabled ?? false,
    auto: previous?.auto ?? auto,
    downloads: [f.url],
    projectId: v.projectId,
    versionId: v.id,
    versionNumber: v.versionNumber,
    requires: requiredProjects(v, catalog),
  );
}

/// Progetti richiesti da [v] (le dipendenze per sola versione si risolvono
/// con il catalogo).
List<String> requiredProjects(MrVersion v, ModCatalog? catalog) => {
  for (final d in v.ofType(MrDependencyType.required))
    if (d.projectId ?? catalog?.version(d.versionId ?? '')?.projectId case final p?)
      if (p != v.projectId) p,
}.toList()..sort();

String? _depProject(MrDependency d, ModCatalog cat) =>
    d.projectId ?? (d.versionId == null ? null : cat.version(d.versionId!)?.projectId);

// ---------------------------------------------------------------- aggiungere

/// Piano per aggiungere una mod.
final class AddPlan {
  const AddPlan({
    required this.projectId,
    this.mod,
    this.dependencies = const [],
    this.satisfied = const [],
    this.blockers = const [],
    this.suggested = const [],
  });

  final String projectId;

  /// La mod scelta (null se non c'è una versione adatta).
  final PackMod? mod;

  /// Dipendenze obbligatorie da aggiungere insieme (`auto`).
  final List<PackMod> dependencies;

  /// Dipendenze obbligatorie già nel pack.
  final List<PackMod> satisfied;
  final List<Blocker> blockers;

  /// Dipendenze facoltative non installate (id dei progetti).
  final List<String> suggested;

  bool get ok => mod != null && blockers.isEmpty;

  /// Il pack con la mod e le dipendenze. [StateError] se il piano è bloccato.
  Pack apply(Pack p) {
    if (!ok) throw StateError('piano bloccato: $blockers');
    return p.withMods([mod!, ...dependencies]);
  }
}

/// Aggiunge [projectId] (alla versione [versionId], o alla migliore per il
/// pack) con le dipendenze obbligatorie, ricorsivamente. Una dipendenza già
/// nel pack va bene anche se la versione precisa richiesta è un'altra: è la
/// regola dei launcher (le versioni precise di Modrinth sono spesso troppo
/// strette); il resto deve girare sulla versione e il loader del pack.
AddPlan planAdd(
  Pack pack,
  ModCatalog cat,
  String projectId, {
  String? versionId,
  MrVersionType maxType = MrVersionType.release,
}) {
  final target = PackTarget.of(pack);
  if (pack.byProject(projectId) != null) {
    return AddPlan(
      projectId: projectId,
      blockers: [Blocker(BlockReason.alreadyInstalled, projectId: projectId)],
    );
  }
  final MrVersion? root;
  final blockers = <Blocker>[];
  if (versionId != null) {
    root = cat.version(versionId);
    if (root == null) {
      return AddPlan(
        projectId: projectId,
        blockers: [Blocker(BlockReason.notLoaded, projectId: projectId, versionId: versionId)],
      );
    }
    if (!target.fits(root)) {
      return AddPlan(
        projectId: projectId,
        blockers: [
          Blocker(
            BlockReason.noCompatibleVersion,
            projectId: projectId,
            versionId: root.id,
            versionNumber: root.versionNumber,
            gameVersions: root.gameVersions,
          ),
        ],
      );
    }
  } else {
    final all = cat.versionsOf(projectId);
    if (all == null) {
      return AddPlan(
        projectId: projectId,
        blockers: [Blocker(BlockReason.notLoaded, projectId: projectId)],
      );
    }
    root = bestVersion(all, target, maxType: maxType);
    if (root == null) {
      final pre = bestVersion(all, target, maxType: MrVersionType.alpha);
      return AddPlan(
        projectId: projectId,
        blockers: [
          Blocker(
            pre == null ? BlockReason.noCompatibleVersion : BlockReason.onlyPrerelease,
            projectId: projectId,
            versionId: pre?.id,
            versionNumber: pre?.versionNumber,
          ),
        ],
      );
    }
  }
  final mod = modFromVersion(root, project: cat.project(projectId), catalog: cat);
  final deps = <String, PackMod>{};
  final satisfied = <String, PackMod>{};
  final chosen = <String, MrVersion>{projectId: root};
  final queue = [root];
  while (queue.isNotEmpty) {
    final v = queue.removeAt(0);
    for (final d in v.ofType(MrDependencyType.required)) {
      final dp = _depProject(d, cat);
      if (dp == null) {
        if (d.versionId != null) {
          blockers.add(
            Blocker(BlockReason.notLoaded, projectId: v.projectId, versionId: d.versionId),
          );
        }
        continue; // dipendenza esterna senza progetto: non risolvibile
      }
      if (dp == v.projectId || chosen.containsKey(dp)) continue;
      final installed = pack.byProject(dp);
      if (installed != null) {
        satisfied[dp] = installed;
        continue;
      }
      final r = _pickDependency(d, dp, v.projectId, cat, target, maxType);
      if (r.$2 != null) {
        blockers.add(r.$2!);
        continue;
      }
      final dv = r.$1!;
      chosen[dp] = dv;
      deps[dp] = modFromVersion(dv, project: cat.project(dp), catalog: cat, auto: true);
      queue.add(dv);
    }
  }
  blockers.addAll(_conflicts(pack, cat, chosen.values));
  final suggested = {
    for (final d in root.ofType(MrDependencyType.optional))
      if (_depProject(d, cat) case final p?
          when pack.byProject(p) == null && !chosen.containsKey(p))
        p,
  }.toList()..sort();
  final depList = deps.values.toList()..sort((a, b) => a.path.compareTo(b.path));
  final satList = satisfied.values.toList()..sort((a, b) => a.path.compareTo(b.path));
  return AddPlan(
    projectId: projectId,
    mod: mod,
    dependencies: depList,
    satisfied: satList,
    blockers: blockers,
    suggested: suggested,
  );
}

/// La versione di una dipendenza: quella precisa se indicata (e deve girare
/// qui), altrimenti la migliore per il target.
(MrVersion?, Blocker?) _pickDependency(
  MrDependency d,
  String depProject,
  String forProject,
  ModCatalog cat,
  PackTarget target,
  MrVersionType maxType,
) {
  if (d.versionId != null) {
    final exact = cat.version(d.versionId!);
    if (exact == null) {
      return (
        null,
        Blocker(
          BlockReason.notLoaded,
          projectId: forProject,
          otherProjectId: depProject,
          versionId: d.versionId,
        ),
      );
    }
    if (target.fits(exact)) return (exact, null);
    return (
      null,
      Blocker(
        BlockReason.dependencyIncompatible,
        projectId: forProject,
        otherProjectId: depProject,
        versionId: exact.id,
        versionNumber: exact.versionNumber,
        gameVersions: exact.gameVersions,
      ),
    );
  }
  final all = cat.versionsOf(depProject);
  if (all == null) {
    return (
      null,
      Blocker(BlockReason.notLoaded, projectId: forProject, otherProjectId: depProject),
    );
  }
  final best = bestVersion(all, target, maxType: maxType);
  if (best != null) return (best, null);
  return (
    null,
    Blocker(BlockReason.dependencyUnavailable, projectId: forProject, otherProjectId: depProject),
  );
}

/// Conflitti tra le versioni [incoming] e le mod del pack, nei due sensi
/// (le versioni installate si guardano solo se sono nel catalogo).
List<Blocker> _conflicts(Pack pack, ModCatalog cat, Iterable<MrVersion> incoming) {
  final inc = {for (final v in incoming) v.projectId: v};
  final present = {
    for (final m in pack.mods)
      if (m.projectId != null && !inc.containsKey(m.projectId)) m.projectId!: m,
  };
  final out = <Blocker>[];
  for (final v in inc.values) {
    for (final d in v.ofType(MrDependencyType.incompatible)) {
      final p = _depProject(d, cat);
      if (p != null && present.containsKey(p)) {
        out.add(Blocker(BlockReason.conflict, projectId: v.projectId, otherProjectId: p));
      }
    }
  }
  for (final m in present.values) {
    final mv = m.versionId == null ? null : cat.version(m.versionId!);
    if (mv == null) continue;
    for (final d in mv.ofType(MrDependencyType.incompatible)) {
      final p = _depProject(d, cat);
      if (p != null && inc.containsKey(p)) {
        out.add(Blocker(BlockReason.conflict, projectId: p, otherProjectId: m.projectId));
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------- aggiornare

/// Stato dell'aggiornamento di una mod.
enum UpdateStatus {
  upToDate,
  available,
  blocked,

  /// Bloccata dall'admin: c'è una versione nuova ma «aggiorna tutte» la salta.
  pinned,

  /// Non è una mod Modrinth (manuale o CurseForge): MineSync non la aggiorna.
  notTracked,

  /// Versioni non caricate (rete).
  unknown,
}

/// Il controllo di una mod.
final class UpdateCheck {
  const UpdateCheck({
    required this.mod,
    required this.status,
    this.latest,
    this.updated,
    this.alsoAdd = const [],
    this.alsoUpdate = const [],
    this.blockers = const [],
  });

  final PackMod mod;
  final UpdateStatus status;

  /// La versione proposta (anche per [UpdateStatus.blocked] e
  /// [UpdateStatus.pinned]).
  final MrVersion? latest;

  /// La voce nuova (con lato, facoltativa e stato della vecchia).
  final PackMod? updated;

  /// Dipendenze nuove da aggiungere.
  final List<PackMod> alsoAdd;

  /// Dipendenze installate da portare alla versione richiesta.
  final List<PackMod> alsoUpdate;
  final List<Blocker> blockers;
}

/// Controlla l'aggiornamento di [mod]. Se la versione attuale è una release
/// si propongono solo release; se è una beta, anche beta (mai alpha da una
/// beta, a meno che l'attuale sia alpha).
UpdateCheck checkUpdate(Pack pack, ModCatalog cat, PackMod mod) {
  final pid = mod.projectId;
  if (mod.source != PackSource.modrinth || pid == null) {
    return UpdateCheck(mod: mod, status: UpdateStatus.notTracked);
  }
  final all = cat.versionsOf(pid);
  if (all == null) return UpdateCheck(mod: mod, status: UpdateStatus.unknown);
  final target = PackTarget.of(pack);
  final current = cat.version(mod.versionId!);
  final maxType = current?.versionType ?? MrVersionType.release;
  final best = bestVersion(all, target, maxType: maxType);
  if (best == null ||
      best.id == mod.versionId ||
      best.primaryFile?.sha1 == mod.sha1 ||
      (current != null && newestFirst(best, current) >= 0)) {
    return UpdateCheck(mod: mod, status: UpdateStatus.upToDate, latest: best);
  }
  final updated = modFromVersion(best, project: cat.project(pid), catalog: cat, previous: mod);
  final blockers = <Blocker>[];
  final add = <String, PackMod>{};
  final upd = <String, PackMod>{};
  final chosen = <String, MrVersion>{pid: best};
  final queue = [best];
  while (queue.isNotEmpty) {
    final v = queue.removeAt(0);
    for (final d in v.ofType(MrDependencyType.required)) {
      final dp = _depProject(d, cat);
      if (dp == null || dp == v.projectId || chosen.containsKey(dp)) continue;
      final installed = pack.byProject(dp);
      if (installed != null) {
        // versione precisa diversa da quella installata: si porta lì se
        // gira qui, altrimenti l'aggiornamento è bloccato
        if (d.versionId != null && d.versionId != installed.versionId) {
          final exact = cat.version(d.versionId!);
          if (exact == null) {
            blockers.add(
              Blocker(
                BlockReason.notLoaded,
                projectId: pid,
                otherProjectId: dp,
                versionId: d.versionId,
              ),
            );
          } else if (!target.fits(exact)) {
            blockers.add(
              Blocker(
                BlockReason.dependencyIncompatible,
                projectId: pid,
                otherProjectId: dp,
                versionId: exact.id,
                versionNumber: exact.versionNumber,
                gameVersions: exact.gameVersions,
              ),
            );
          } else {
            final inst = installed.versionId == null ? null : cat.version(installed.versionId!);
            // solo in avanti: una dipendenza più vecchia di quella installata
            // si accetta così com'è
            if (inst == null || newestFirst(exact, inst) < 0) {
              chosen[dp] = exact;
              upd[dp] = modFromVersion(
                exact,
                project: cat.project(dp),
                catalog: cat,
                previous: installed,
              );
              queue.add(exact);
            }
          }
        }
        continue;
      }
      final r = _pickDependency(d, dp, pid, cat, target, MrVersionType.release);
      if (r.$2 != null) {
        blockers.add(r.$2!);
        continue;
      }
      chosen[dp] = r.$1!;
      add[dp] = modFromVersion(r.$1!, project: cat.project(dp), catalog: cat, auto: true);
      queue.add(r.$1!);
    }
  }
  // la mod stessa non è in conflitto con la sua versione vecchia
  blockers.addAll(_conflicts(pack.withoutKeys([mod.key]), cat, chosen.values));
  final status = blockers.isNotEmpty
      ? UpdateStatus.blocked
      : (mod.pinned ? UpdateStatus.pinned : UpdateStatus.available);
  return UpdateCheck(
    mod: mod,
    status: status,
    latest: best,
    updated: updated,
    alsoAdd: add.values.toList()..sort((a, b) => a.path.compareTo(b.path)),
    alsoUpdate: upd.values.toList()..sort((a, b) => a.path.compareTo(b.path)),
    blockers: blockers,
  );
}

/// Controlla tutte le mod del pack, in ordine di percorso.
List<UpdateCheck> checkUpdates(Pack pack, ModCatalog cat) => [
  for (final m in pack.mods) checkUpdate(pack, cat, m),
];

/// Applica i controlli [checks] con stato [UpdateStatus.available] (e
/// [UpdateStatus.pinned] solo con [includePinned]: l'admin ha chiesto
/// quella mod esplicitamente).
Pack applyUpdates(Pack pack, Iterable<UpdateCheck> checks, {bool includePinned = false}) {
  final put = <PackMod>[];
  final drop = <String>[];
  for (final c in checks) {
    final ok =
        c.status == UpdateStatus.available || (includePinned && c.status == UpdateStatus.pinned);
    if (!ok || c.updated == null) continue;
    drop.add(c.mod.key);
    put
      ..add(c.updated!)
      ..addAll(c.alsoAdd)
      ..addAll(c.alsoUpdate);
  }
  // un'altra mod nel frattempo può aver già messo la stessa dipendenza
  return pack.withoutKeys(drop).withMods(put);
}

// ---------------------------------------------------------------- togliere

/// Piano per togliere una mod.
final class RemovePlan {
  const RemovePlan({required this.target, this.dependents = const [], this.orphans = const []});

  final PackMod target;

  /// Mod che la richiedono (anche indirettamente): vanno tolte con lei.
  final List<PackMod> dependents;

  /// Dipendenze aggiunte da MineSync (`auto`) che nessuno chiede più.
  final List<PackMod> orphans;

  List<PackMod> get all => [target, ...dependents, ...orphans];

  /// Il pack senza la mod e chi ne dipende; [withOrphans] toglie anche le
  /// dipendenze rimaste orfane.
  Pack apply(Pack p, {bool withOrphans = true}) => p.withoutKeys([
    target.key,
    ...dependents.map((m) => m.key),
    if (withOrphans) ...orphans.map((m) => m.key),
  ]);
}

/// Toglie la mod con chiave [key] ([PackMod.key]). [ArgumentError] se non c'è.
RemovePlan planRemove(Pack pack, String key) {
  final target = pack.byKey(key);
  if (target == null) throw ArgumentError.value(key, 'key', 'mod non nel pack');
  final gone = <String>{target.key};
  final goneProjects = <String>{?target.projectId};
  var changed = true;
  while (changed) {
    changed = false;
    for (final m in pack.mods) {
      if (gone.contains(m.key)) continue;
      if (m.requires.any(goneProjects.contains)) {
        gone.add(m.key);
        if (m.projectId != null) goneProjects.add(m.projectId!);
        changed = true;
      }
    }
  }
  final dependents = [
    for (final m in pack.mods)
      if (gone.contains(m.key) && m.key != target.key) m,
  ];
  // orfane: auto e nessuna mod rimasta le chiede
  final orphans = <PackMod>[];
  changed = true;
  final removed = {...gone};
  while (changed) {
    changed = false;
    final needed = {
      for (final m in pack.mods)
        if (!removed.contains(m.key)) ...m.requires,
    };
    for (final m in pack.mods) {
      if (removed.contains(m.key) || !m.auto || m.projectId == null) continue;
      if (!needed.contains(m.projectId)) {
        orphans.add(m);
        removed.add(m.key);
        changed = true;
      }
    }
  }
  orphans.sort((a, b) => a.path.compareTo(b.path));
  return RemovePlan(target: target, dependents: dependents, orphans: orphans);
}

// ---------------------------------------------------------------- cambiare versione

/// Stato di una mod nel cambio di versione o loader.
enum CompatStatus {
  /// C'è una versione per il nuovo target ([ModCompat.next]).
  ready,

  /// Non c'è: va tolta (o si rinuncia al cambio).
  blocked,

  /// Aggiunta a mano o da CurseForge: MineSync non sa se va, la si tiene.
  manual,
}

/// Il rapporto di una mod.
final class ModCompat {
  const ModCompat({required this.mod, required this.status, this.next, this.blockers = const []});

  final PackMod mod;
  final CompatStatus status;

  /// La voce per il nuovo target (anche uguale alla vecchia).
  final PackMod? next;
  final List<Blocker> blockers;

  /// Resta alla stessa versione (gira già sul nuovo target).
  bool get unchanged => next != null && next!.versionId == mod.versionId;
}

/// Il rapporto completo prima di cambiare versione di Minecraft o loader.
final class CompatReport {
  const CompatReport({
    required this.from,
    required this.target,
    required this.loaderVersion,
    required this.entries,
    this.alsoAdd = const [],
  });

  final Pack from;
  final PackTarget target;
  final String? loaderVersion;

  /// Una voce per mod del pack, in ordine di percorso.
  final List<ModCompat> entries;

  /// Dipendenze nuove che le versioni scelte chiedono.
  final List<PackMod> alsoAdd;

  Iterable<ModCompat> get ready => entries.where((e) => e.status == CompatStatus.ready);
  Iterable<ModCompat> get blocked => entries.where((e) => e.status == CompatStatus.blocked);
  Iterable<ModCompat> get manual => entries.where((e) => e.status == CompatStatus.manual);

  /// Il pack sul nuovo target: le pronte alla versione nuova più le
  /// dipendenze nuove; le bloccate tolte; le manuali tenute (con
  /// [keepManual]) o tolte.
  Pack apply({bool keepManual = true}) => Pack(
    name: from.name,
    mcVersion: target.mcVersion,
    loader: target.loader,
    loaderVersion: target.loader == Loader.vanilla ? null : loaderVersion,
    shared: from.shared,
    updatedAt: from.updatedAt,
    mods: [
      for (final e in entries)
        if (e.status == CompatStatus.ready)
          e.next!
        else if (e.status == CompatStatus.manual && keepManual)
          e.mod,
      ...alsoAdd,
    ],
  );
}

/// Controlla ogni mod di [pack] per [mcVersion] e [loader] prima di
/// cambiarli. Solo release, a meno che la versione attuale sia già una
/// beta/alpha ([BlockReason.onlyPrerelease] altrimenti). Se una mod pronta
/// chiede una dipendenza che resta bloccata, si blocca anche lei.
CompatReport planRetarget(
  Pack pack,
  ModCatalog cat, {
  required String mcVersion,
  required Loader loader,
  String? loaderVersion,
}) {
  final target = PackTarget(mcVersion, loader);
  final chosen = <String, MrVersion>{};
  final blockers = <String, List<Blocker>>{};
  for (final m in pack.mods) {
    final pid = m.projectId;
    if (m.source != PackSource.modrinth || pid == null) continue;
    final all = cat.versionsOf(pid);
    if (all == null) {
      blockers[m.key] = [Blocker(BlockReason.notLoaded, projectId: pid)];
      continue;
    }
    final current = cat.version(m.versionId!);
    final maxType = current?.versionType ?? MrVersionType.release;
    // la versione attuale va ancora bene: si tiene
    final keep = current != null && target.fits(current) ? current : null;
    final best = keep ?? bestVersion(all, target, maxType: maxType);
    if (best == null) {
      final pre = bestVersion(all, target, maxType: MrVersionType.alpha);
      blockers[m.key] = [
        Blocker(
          pre == null ? BlockReason.noCompatibleVersion : BlockReason.onlyPrerelease,
          projectId: pid,
          versionId: pre?.id,
          versionNumber: pre?.versionNumber,
        ),
      ];
      continue;
    }
    chosen[pid] = best;
  }
  // dipendenze: nel pack (seguono il loro destino) o nuove
  final add = <String, PackMod>{};
  var changed = true;
  while (changed) {
    changed = false;
    for (final m in pack.mods) {
      final pid = m.projectId;
      final v = pid == null ? null : chosen[pid];
      if (v == null) continue;
      for (final d in v.ofType(MrDependencyType.required)) {
        final dp = _depProject(d, cat);
        if (dp == null || dp == pid) continue;
        final dep = pack.byProject(dp);
        if (dep != null) {
          if (blockers.containsKey(dep.key)) {
            blockers[m.key] = [
              Blocker(BlockReason.dependencyBlocked, projectId: pid!, otherProjectId: dp),
            ];
            chosen.remove(pid);
            changed = true;
            break;
          }
          continue;
        }
        if (add.containsKey(dp)) continue;
        final r = _pickDependency(d, dp, pid!, cat, target, MrVersionType.release);
        if (r.$2 != null) {
          blockers[m.key] = [r.$2!];
          chosen.remove(pid);
          changed = true;
          break;
        }
        add[dp] = modFromVersion(r.$1!, project: cat.project(dp), catalog: cat, auto: true);
      }
    }
  }
  // dipendenze nuove di chi poi è stato bloccato: si tolgono
  final stillNeeded = {for (final v in chosen.values) ...requiredProjects(v, cat)};
  add.removeWhere((k, _) => !stillNeeded.contains(k));
  final entries = <ModCompat>[
    for (final m in pack.mods)
      if (m.source != PackSource.modrinth || m.projectId == null)
        ModCompat(mod: m, status: CompatStatus.manual)
      else if (chosen[m.projectId] case final v?)
        ModCompat(
          mod: m,
          status: CompatStatus.ready,
          next: v.id == m.versionId
              ? m
              : modFromVersion(v, project: cat.project(m.projectId!), catalog: cat, previous: m),
        )
      else
        ModCompat(mod: m, status: CompatStatus.blocked, blockers: blockers[m.key] ?? const []),
  ];
  return CompatReport(
    from: pack,
    target: target,
    loaderVersion: loaderVersion,
    entries: entries,
    alsoAdd: add.values.toList()..sort((a, b) => a.path.compareTo(b.path)),
  );
}
