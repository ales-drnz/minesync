// Formati: semver, firma del manifest, tar, stato dell'installazione,
// disposizione per sistema, header PE.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:minesync_launcher/minesync_launcher.dart';
import 'package:minesync_launcher/src/tar.dart';
import 'package:minesync_launcher/update.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Manifest _m(String v, {String platform = 'linux-x64'}) => Manifest(
  version: v,
  platform: platform,
  kind: PackageKind.archive,
  archiveName: 'a.tar.gz',
  archiveSize: 10,
  archiveSha256: '0' * 64,
  entrypoint: 'minesync_desktop',
);

void main() {
  group('semver', () {
    test('solo versioni strettamente più nuove', () {
      expect(isNewer('0.1.1', '0.1.0'), isTrue);
      expect(isNewer('0.2.0', '0.1.9'), isTrue);
      expect(isNewer('1.0.0', '1.0.0-rc.2'), isTrue);
      expect(isNewer('1.0.0-rc.10', '1.0.0-rc.2'), isTrue);
      expect(isNewer('0.1.0', '0.1.0'), isFalse);
      expect(isNewer('0.0.9', '0.1.0'), isFalse);
      expect(isNewer('1.0.0-rc.1', '1.0.0'), isFalse);
    });

    test('ciò che non è semver non si aggiorna mai', () {
      expect(isNewer('0.2.0', 'dev'), isFalse);
      expect(isNewer('latest', '0.1.0'), isFalse);
      expect(isNewer('01.0.0', '0.1.0'), isFalse);
      expect(isNewer('1.0.0+build', '0.1.0'), isFalse);
    });
  });

  group('firma del manifest', () {
    late String seed, pub;
    setUpAll(() async => (seed, pub) = await generateKeyPair());

    test('firma valida: manifest letto', () async {
      final b = _m('0.1.1').encode();
      final m = await verifyManifest(b, await signBytes(b, seed), pub);
      expect(m.version, '0.1.1');
    });

    test('byte modificati dopo la firma: rifiutato', () async {
      final b = _m('0.1.1').encode();
      final sig = await signBytes(b, seed);
      final t = Uint8List.fromList(utf8.encode(utf8.decode(b).replaceFirst('0.1.1', '0.1.2')));
      expect(() => verifyManifest(t, sig, pub), throwsA(isA<SignatureException>()));
    });

    test('altra chiave, firma non base64 o di lunghezza sbagliata: rifiutato', () async {
      final b = _m('0.1.1').encode();
      final (other, _) = await generateKeyPair();
      expect(
        () async => verifyManifest(b, await signBytes(b, other), pub),
        throwsA(isA<SignatureException>()),
      );
      expect(() => verifyManifest(b, 'no!!', pub), throwsA(isA<SignatureException>()));
      expect(
        () => verifyManifest(b, base64.encode([1, 2]), pub),
        throwsA(isA<SignatureException>()),
      );
      expect(
        () async => verifyManifest(b, await signBytes(b, seed), ''),
        throwsA(isA<SignatureException>()),
      );
    });

    test('firmato ma di un\'altra app: rifiutato', () async {
      final j = _m('0.1.1').toJson()..['app'] = 'altro';
      final b = Uint8List.fromList(utf8.encode(jsonEncode(j)));
      expect(
        () async => verifyManifest(b, await signBytes(b, seed), pub),
        throwsA(isA<SignatureException>()),
      );
    });
  });

  group('tar', () {
    test('andata e ritorno con nomi lunghi (PAX) e symlink', () async {
      final long = '${'d' * 80}/${'f' * 60}.txt';
      final tar = buildTar([
        TarEntryIn.file('a.txt', Uint8List.fromList([1, 2, 3]), mode: 493),
        TarEntryIn.file(long, Uint8List.fromList(List.filled(1000, 7))),
        TarEntryIn.link('lib/x.so.1', 'x.so'),
      ]);
      final r = TarReader(Stream.value(tar));
      final got = <String, (TarType, int, String?)>{};
      while (true) {
        final h = await r.next();
        if (h == null) break;
        var n = 0;
        if (h.type == TarType.file) await r.readData(h, (c) => n += c.length);
        got[h.path] = (h.type, n, h.linkTarget);
      }
      expect(got['a.txt'], (TarType.file, 3, null));
      expect(got[long], (TarType.file, 1000, null));
      expect(got['lib/x.so.1'], (TarType.symlink, 0, 'x.so'));
    });

    Uint8List withType(int type) {
      final b = buildTar([TarEntryIn.file('a', Uint8List(1))])..[156] = type;
      var sum = 0;
      for (var i = 0; i < 512; i++) {
        sum += (i >= 148 && i < 156) ? 0x20 : b[i];
      }
      b.setRange(148, 156, ascii.encode('${sum.toRadixString(8).padLeft(6, '0')}\x00 '));
      return b;
    }

    test('hardlink, device e fifo rifiutati', () async {
      expect(await TarReader(Stream.value(withType(0x30))).next(), isNotNull);
      for (final t in ['1', '3', '4', '6']) {
        expect(
          () => TarReader(Stream.value(withType(t.codeUnitAt(0)))).next(),
          throwsA(isA<TarFormatException>()),
          reason: 'tipo $t',
        );
      }
    });

    test('checksum dell\'header controllato', () async {
      final b = buildTar([TarEntryIn.file('a', Uint8List(1))])..[0] = 0x62;
      expect(() => TarReader(Stream.value(b)).next(), throwsA(isA<TarFormatException>()));
    });
  });

  group('installazione', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('ms_inst'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('state.json illeggibile vale come stato vuoto', () async {
      final inst = Install(tmp.path);
      await File(inst.statePath).writeAsString('{rotto');
      expect((await inst.readState()).current, isNull);
      await File(inst.statePath).writeAsString('{"current": 3}');
      expect((await inst.readState()).current, isNull);
    });

    test('versioni installate: solo cartelle complete, dalla più nuova', () async {
      final inst = Install(tmp.path);
      for (final v in ['0.1.0', '0.10.0', '0.2.0', '0.3.0.partial', '0.4.0']) {
        final d = Directory(inst.versionDir(v))..createSync(recursive: true);
        if (v != '0.4.0') {
          File(p.join(d.path, versionManifestName)).writeAsStringSync(jsonEncode({'version': v}));
        }
      }
      expect(await inst.installedVersions(), ['0.10.0', '0.2.0', '0.1.0']);
    });

    test('pulizia: tiene current, previous e pending', () async {
      final inst = Install(tmp.path);
      for (final v in ['0.1.0', '0.2.0', '0.3.0', '0.4.0', '0.5.0.partial']) {
        Directory(inst.versionDir(v)).createSync(recursive: true);
      }
      Directory(inst.runDir).createSync();
      File(inst.healthFile('0.1.0')).writeAsStringSync('0.1.0');
      File(inst.healthFile('0.3.0')).writeAsStringSync('0.3.0');
      final removed = await inst.cleanup(
        InstallState(current: '0.3.0', previous: '0.2.0', pending: '0.4.0'),
      );
      expect(removed.toSet(), {'0.1.0', '0.5.0.partial'});
      expect(File(inst.healthFile('0.1.0')).existsSync(), isFalse);
      expect(File(inst.healthFile('0.3.0')).existsSync(), isTrue);
    });
  });

  group('disposizione', () {
    test('Windows e Linux portabile: radice = cartella del launcher', () {
      final self = p.join('opt', 'MineSync', 'minesync-launcher');
      final l = LauncherLayout.detect(const {}, self, macOS: false, linux: true);
      expect(l.root, p.join('opt', 'MineSync'));
      expect(l.selfUpdate, isTrue);
    });

    test('macOS: MineSync.app fa da launcher, versioni in Application Support', () {
      final self = p.join('Applications', 'MineSync.app', 'Contents', 'MacOS', 'MineSync');
      final l = LauncherLayout.detect(const {'HOME': 'h'}, self, macOS: true, linux: false);
      expect(l.root, p.join('h', 'Library', 'Application Support', 'MineSync'));
      expect(
        l.bootstrapDir,
        p.join('Applications', 'MineSync.app', 'Contents', 'Resources', 'bootstrap'),
      );
      expect(l.selfUpdate, isFalse);
    });

    test('AppImage: versioni in XDG_DATA_HOME, partenza dentro l\'immagine', () {
      final env = {'HOME': 'h', 'APPIMAGE': 'x.AppImage', 'APPDIR': 'mnt'};
      final l = LauncherLayout.detect(env, p.join('mnt', 'launcher'), macOS: false, linux: true);
      expect(l.root, p.join('h', '.local', 'share', 'MineSync'));
      expect(l.bootstrapDir, p.join('mnt', 'bootstrap'));
      expect(l.selfUpdate, isFalse);
    });
  });

  group('PE', () {
    Uint8List fakePe({int magic = 0x20b}) {
      final b = Uint8List(512);
      b[0] = 0x4d;
      b[1] = 0x5a;
      final d = ByteData.sublistView(b)..setUint32(0x3c, 0x80, Endian.little);
      b.setRange(0x80, 0x84, [0x50, 0x45, 0, 0]);
      d
        ..setUint16(0x80 + 24, magic, Endian.little)
        ..setUint16(0x80 + 24 + 68, peSubsystemConsole, Endian.little);
      return b;
    }

    test('da console a GUI', () {
      for (final magic in [0x10b, 0x20b]) {
        final b = fakePe(magic: magic);
        expect(peSubsystem(b), peSubsystemConsole);
        setPeSubsystem(b, peSubsystemGui);
        expect(peSubsystem(b), peSubsystemGui);
      }
    });

    test('file che non sono PE rifiutati', () {
      expect(() => peSubsystem(Uint8List(512)), throwsFormatException);
      expect(() => peSubsystem(fakePe(magic: 0x1234)), throwsFormatException);
    });
  });
}
