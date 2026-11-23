// Piano di installazione lato server: scaricare, spostare, cancellare solo
// i file che il pack conosceva.
import 'package:ms_modpack/ms_modpack.dart';
import 'package:test/test.dart';

import 'support.dart';

LocalFile at(String path, PackMod m) => LocalFile(path: path, size: m.size, sha1: m.sha1);

void main() {
  final a1 = installed(v('aV1', 'aPr', '1.0'));
  final a2 = installed(v('aV2', 'aPr', '2.0', day: 5));
  final b = installed(v('bV1', 'bPr', '1.0'));
  final tweaks = manual('mods/tweaks.jar');

  test('server nuovo: scarica tutto; i manuali senza URL non si possono', () {
    final to = fabricPack([a1, b, tweaks]);
    final plan = planInstall(to: to, files: const []);
    expect([for (final d in plan.downloads) d.location], ['mods/aPr-1.0.jar', 'mods/bPr-1.0.jar']);
    expect(plan.unavailable.single.path, 'mods/tweaks.jar');
    expect(plan.downloadBytes, a1.size + b.size);
  });

  test('già a posto: niente da fare', () {
    final p = fabricPack([a1, b]);
    final plan = planInstall(from: p, to: p, files: [at(a1.location, a1), at(b.location, b)]);
    expect(plan.isEmpty, isTrue);
  });

  test('aggiornamento: scarica il nuovo, toglie il vecchio', () {
    final from = fabricPack([a1, b]);
    final to = fabricPack([a2, b]);
    final plan = planInstall(from: from, to: to, files: [at(a1.location, a1), at(b.location, b)]);
    expect(plan.downloads.single.mod.versionId, 'aV2');
    expect(plan.deletes, ['mods/aPr-1.0.jar']);
  });

  test('spegnere, riaccendere, cambiare lato: si sposta, non si riscarica', () {
    final from = fabricPack([a1, b]);
    final off = fabricPack([a1.copyWith(disabled: true), b.copyWith(side: PackSide.client)]);
    final plan = planInstall(from: from, to: off, files: [at(a1.location, a1), at(b.location, b)]);
    expect(plan.downloads, isEmpty);
    expect(plan.deletes, isEmpty);
    expect(
      [for (final m in plan.moves) (m.from, m.to)],
      [
        ('mods/bPr-1.0.jar', 'client-overrides/mods/bPr-1.0.jar'),
        ('mods/aPr-1.0.jar', 'mods/aPr-1.0.jar.disabled'),
      ],
    );
    final back = planInstall(
      from: off,
      to: from,
      files: [at('mods/aPr-1.0.jar.disabled', a1), at('client-overrides/mods/bPr-1.0.jar', b)],
    );
    expect([for (final m in back.moves) m.to], ['mods/aPr-1.0.jar', 'mods/bPr-1.0.jar']);
  });

  test('rimozione: solo se il file è ancora quello del pack', () {
    final from = fabricPack([a1, b]);
    final to = fabricPack([b]);
    final same = planInstall(from: from, to: to, files: [at(a1.location, a1), at(b.location, b)]);
    expect(same.deletes, ['mods/aPr-1.0.jar']);
    final replaced = planInstall(
      from: from,
      to: to,
      files: [
        LocalFile(path: a1.location, size: 9, sha1: 'e' * 40),
        at(b.location, b),
      ],
    );
    expect(replaced.deletes, isEmpty);
  });

  test('i jar sconosciuti non si toccano; un jar sconosciuto al posto giusto blocca', () {
    final to = fabricPack([a1]);
    final plan = planInstall(
      to: to,
      files: [
        const LocalFile(path: 'mods/other.jar', size: 3, sha1: 'aaa'),
        LocalFile(path: a1.location, size: 3, sha1: 'b' * 40),
      ],
    );
    expect(plan.deletes, isEmpty);
    expect(plan.downloads, isEmpty);
    expect(plan.unavailable.single.projectId, 'aPr');
  });

  test('un manuale messo dal lato sbagliato si sposta dove dice il pack', () {
    final m = manual('mods/x.jar', side: PackSide.client);
    final plan = planInstall(to: fabricPack([m]), files: [at('mods/x.jar', m)]);
    expect(
      [for (final mv in plan.moves) (mv.from, mv.to)],
      [('mods/x.jar', 'client-overrides/mods/x.jar')],
    );
    expect(plan.unavailable, isEmpty);
  });
}
