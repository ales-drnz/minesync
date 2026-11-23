// Riempie un [MemoryCatalog] da Modrinth con quello che serve a
// un'operazione del risolutore: progetti, versioni per il target, versioni
// precise delle dipendenze, ricorsivamente. Asincrono (rete); il risolutore
// poi lavora sul catalogo senza rete.
import 'modrinth.dart';
import 'modrinth_models.dart';
import 'pack.dart';
import 'resolver.dart';

/// Caricatore del catalogo.
final class CatalogLoader {
  CatalogLoader(this.client, {MemoryCatalog? catalog, this.maxRounds = 8})
    : catalog = catalog ?? MemoryCatalog();

  final ModrinthClient client;
  final MemoryCatalog catalog;

  /// Livelli massimi di dipendenze seguiti.
  final int maxRounds;

  /// Per aggiungere [projectId] a [pack].
  Future<MemoryCatalog> forAdd(Pack pack, String projectId, {String? versionId}) async {
    final target = PackTarget.of(pack);
    await _installed(pack);
    await _projects([projectId], target);
    if (versionId != null) await _exact([versionId]);
    await _follow(target, [projectId]);
    return catalog;
  }

  /// Per controllare gli aggiornamenti di tutte le mod Modrinth di [pack].
  Future<MemoryCatalog> forUpdates(Pack pack) async {
    final target = PackTarget.of(pack);
    await _installed(pack);
    final ids = _modrinthIds(pack);
    await _projects(ids, target);
    await _follow(target, ids);
    return catalog;
  }

  /// Per portare [pack] su [target].
  Future<MemoryCatalog> forRetarget(Pack pack, PackTarget target) async {
    await _installed(pack);
    final ids = _modrinthIds(pack);
    await _projects(ids, target);
    await _follow(target, ids);
    return catalog;
  }

  List<String> _modrinthIds(Pack pack) => [
    for (final m in pack.mods)
      if (m.source == PackSource.modrinth && m.projectId != null) m.projectId!,
  ];

  /// Le versioni installate (servono per i conflitti e per il tipo di
  /// versione attuale) e i progetti del pack.
  Future<void> _installed(Pack pack) async {
    final vids = [
      for (final m in pack.mods)
        if (m.versionId != null && catalog.version(m.versionId!) == null) m.versionId!,
    ];
    await _exact(vids);
    final pids = [
      for (final m in pack.mods)
        if (m.projectId != null && catalog.project(m.projectId!) == null) m.projectId!,
    ];
    for (final p in await client.projects(pids)) {
      catalog.addProject(p);
    }
  }

  Future<void> _exact(Iterable<String> ids) async {
    final want = [
      for (final id in ids.toSet())
        if (catalog.version(id) == null) id,
    ];
    if (want.isEmpty) return;
    for (final v in await client.versionsByIds(want)) {
      catalog.addVersion(v, listed: false);
    }
  }

  Future<void> _projects(Iterable<String> ids, PackTarget target) async {
    final want = [
      for (final id in ids.toSet())
        if (!catalog.hasVersionsOf(id)) id,
    ];
    if (want.isEmpty) return;
    final missingProjects = [
      for (final id in want)
        if (catalog.project(id) == null) id,
    ];
    for (final p in await client.projects(missingProjects)) {
      catalog.addProject(p);
    }
    for (final id in want) {
      final vs = await client.versions(
        id,
        gameVersions: [target.mcVersion],
        loaders: compatibleLoaders(target.loader),
      );
      catalog.markLoaded(id);
      for (final v in vs) {
        catalog.addVersion(v);
      }
    }
  }

  /// Segue le dipendenze obbligatorie delle versioni migliori, livello per
  /// livello.
  Future<void> _follow(PackTarget target, Iterable<String> start) async {
    var frontier = start.toSet();
    final seen = <String>{...frontier};
    for (var round = 0; round < maxRounds && frontier.isNotEmpty; round++) {
      final depProjects = <String>{};
      final depVersions = <String>{};
      for (final pid in frontier) {
        final vs = catalog.versionsOf(pid) ?? const <MrVersion>[];
        final best = bestVersion(vs, target, maxType: MrVersionType.alpha);
        final candidates = [?best];
        for (final v in candidates) {
          for (final d in v.ofType(MrDependencyType.required)) {
            if (d.versionId != null) depVersions.add(d.versionId!);
            if (d.projectId != null) depProjects.add(d.projectId!);
          }
        }
      }
      await _exact(depVersions);
      for (final vid in depVersions) {
        final pid = catalog.version(vid)?.projectId;
        if (pid != null) depProjects.add(pid);
      }
      final next = depProjects.difference(seen);
      seen.addAll(next);
      await _projects(next, target);
      frontier = next;
    }
  }
}
