// Tool di rilascio dell'app desktop. La chiave privata non sta nel
// repository: la tiene chi firma i rilasci (seme ed25519 di 32 byte in
// base64, firma in base64).
//
//   minesync_release keygen --out <dir>          -> signing.key (0600), signing.pub
//   minesync_release pack --key <signing.key> --version 0.1.1 --platform linux-x64 \
//        --entry minesync_desktop [--launcher minesync-launcher] --src <bundle> --out <dl>
//                                                -> <dl>/update/<platform>/{tar.gz, manifest.json, .sig}
//   minesync_release sign --key <signing.key> <file>   -> <file>.sig
//   minesync_release gui-subsystem <exe>         launcher Windows senza console
import 'dart:io';

import 'package:minesync_launcher/minesync_launcher.dart';
import 'package:minesync_launcher/update.dart';
import 'package:path/path.dart' as p;

Never _usage() {
  stderr.writeln('uso: minesync_release keygen|pack|sign|gui-subsystem ... (vedi sorgente)');
  exit(64);
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) _usage();
  String opt(String k) {
    final i = args.indexOf(k);
    if (i < 0 || i + 1 >= args.length) _usage();
    return args[i + 1];
  }

  String? optional(String k) {
    final i = args.indexOf(k);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  Future<String> key() async => (await File(opt('--key')).readAsString()).trim();

  switch (args[0]) {
    case 'keygen':
      final out = opt('--out');
      await Directory(out).create(recursive: true);
      final (seed, pub) = await generateKeyPair();
      final keyPath = p.join(out, 'signing.key');
      await File(keyPath).writeAsString('$seed\n');
      if (!Platform.isWindows) await Process.run('chmod', ['600', keyPath]);
      await File(p.join(out, 'signing.pub')).writeAsString('$pub\n');
      stdout.writeln(pub);
    case 'sign':
      final f = args.last;
      final sig = await signBytes(await File(f).readAsBytes(), await key());
      await File('$f.sig').writeAsString('$sig\n');
    case 'pack':
      final m = await packRelease(
        seedB64: await key(),
        version: opt('--version'),
        platform: opt('--platform'),
        entrypoint: opt('--entry'),
        launcher: optional('--launcher'),
        src: opt('--src'),
        out: opt('--out'),
      );
      stdout.writeln('${m.version} (${m.platform}): ${m.archiveName}, ${m.files.length} file');
    case 'gui-subsystem':
      final f = File(args.last);
      final b = await f.readAsBytes();
      setPeSubsystem(b, peSubsystemGui);
      await f.writeAsBytes(b, flush: true);
    default:
      _usage();
  }
}
