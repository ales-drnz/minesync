// Modello del pacchetto per i giocatori: andata e ritorno e
// decodifica stretta.
import 'dart:convert';

import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('ClientPack completo: andata e ritorno', () {
    const p = ClientPack(
      n: 129,
      available: true,
      name: 'Survival',
      mcVersion: '1.21.1',
      loader: Loader.fabric,
      loaderVersion: '0.16.14',
      mods: 38,
      required: 27,
      optional: 4,
      serverOnly: 7,
      manual: 1,
      disabled: 1,
      missing: [
        PackMissingMod(
          file: 'towers.jar',
          source: 'curseforge',
          name: 'Ancient Towers',
          pageUrl: 'https://www.curseforge.com/minecraft/mc-mods/towers',
        ),
      ],
      fileName: 'Survival-129.mrpack',
      size: 31000,
      modsZipName: 'Survival-129-mods.zip',
      modsZipSize: 148000000,
    );
    final j = jsonDecode(jsonEncode(p.toJson()));
    expect(ClientPack.fromJson(j).toJson(), p.toJson());
    expect(ClientPack.fromJson(j).missing.single.name, 'Ancient Towers');
  });

  test('senza pacchetto: solo n e available', () {
    const p = ClientPack(n: 4, available: false);
    expect(p.toJson(), {'n': 4, 'available': false});
    expect(ClientPack.fromJson({'n': 4, 'available': false}).mods, 0);
  });

  test('decodifica stretta', () {
    expect(() => ClientPack.fromJson({'n': 1}), throwsFormatException);
    expect(
      () => ClientPack.fromJson({'n': 1, 'available': true, 'loader': 'x'}),
      throwsFormatException,
    );
    expect(
      () => ClientPack.fromJson({
        'n': 1,
        'available': true,
        'missing': [
          {'file': 1},
        ],
      }),
      throwsFormatException,
    );
  });
}
