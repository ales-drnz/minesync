// Una sola istanza dell'app per utente. La prima prende un lock esclusivo su
// instance.lock nella cartella di configurazione (lo tiene finché vive: il
// sistema lo rilascia anche se il processo muore) e ascolta su 127.0.0.1 a una
// porta scelta dal sistema, scritta con un token casuale in instance.json.
// Una seconda istanza non ottiene il lock, legge porta e token, chiede
// "mostrati" alla prima ed esce.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Prova a prendere il lock di [path]; null se lo tiene un altro processo.
typedef InstanceLocker = Future<RandomAccessFile?> Function(String path);

Future<RandomAccessFile?> _fileLock(String path) async {
  final raf = await File(path).open(mode: FileMode.append);
  try {
    await raf.lock(FileLock.exclusive);
    return raf;
  } on FileSystemException {
    await raf.close();
    return null;
  }
}

/// Esito dell'avvio: istanza principale, oppure secondaria (ha già chiesto
/// alla principale di mostrarsi, o non è riuscita a raggiungerla).
sealed class InstanceRole {
  const InstanceRole();
}

final class PrimaryInstance extends InstanceRole {
  PrimaryInstance._(this._lock, this._server, this._info);

  final RandomAccessFile _lock;
  final ServerSocket _server;
  final File _info;
  final _show = StreamController<void>.broadcast();

  /// Un'altra istanza ha chiesto di mostrare la finestra.
  Stream<void> get showRequests => _show.stream;

  int get port => _server.port;

  Future<void> dispose() async {
    await _server.close();
    try {
      await _info.delete();
    } on FileSystemException {
      // già sparito
    }
    await _lock.close();
    await _show.close();
  }
}

final class SecondaryInstance extends InstanceRole {
  const SecondaryInstance({required this.signaled});

  /// true se la principale ha confermato la richiesta.
  final bool signaled;
}

const _hello = 'minesync-show';

abstract final class SingleInstance {
  /// Decide il ruolo di questo processo usando i file in [dir].
  static Future<InstanceRole> acquire(
    String dir, {
    InstanceLocker lock = _fileLock,
    Duration wait = const Duration(seconds: 5),
  }) async {
    await Directory(dir).create(recursive: true);
    final sep = Platform.pathSeparator;
    final info = File('$dir${sep}instance.json');
    final raf = await lock('$dir${sep}instance.lock');
    if (raf != null) return _becomePrimary(raf, info);
    // La principale potrebbe essere appena partita e non aver ancora scritto
    // la porta: si riprova per qualche secondo.
    final deadline = DateTime.now().add(wait);
    while (true) {
      if (await _signal(info)) return const SecondaryInstance(signaled: true);
      if (DateTime.now().isAfter(deadline)) return const SecondaryInstance(signaled: false);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  static Future<PrimaryInstance> _becomePrimary(RandomAccessFile raf, File info) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final rnd = Random.secure();
    final token = List.generate(16, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
    final me = PrimaryInstance._(raf, server, info);
    final tmp = File('${info.path}.tmp');
    await tmp.writeAsString(jsonEncode({'port': server.port, 'token': token.join()}), flush: true);
    await tmp.rename(info.path);
    server.listen((s) => _serve(s, '$_hello ${token.join()}', me._show));
    return me;
  }

  static void _serve(Socket s, String expected, StreamController<void> show) {
    s
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 2))
        .then((line) {
          if (line == expected) {
            if (!show.isClosed) show.add(null);
            s.write('ok\n');
          }
        })
        .catchError((Object _) {})
        .whenComplete(() async {
          try {
            await s.flush();
          } on Object {
            // client già andato
          }
          s.destroy();
        });
  }

  static Future<bool> _signal(File info) async {
    final int port;
    final String token;
    try {
      final j = jsonDecode(await info.readAsString()) as Map<String, Object?>;
      port = j['port']! as int;
      token = j['token']! as String;
    } on Object {
      return false; // non ancora scritto, o illeggibile
    }
    Socket? s;
    try {
      s = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 1),
      );
      s.write('$_hello $token\n');
      await s.flush();
      final reply = await s
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 2));
      return reply == 'ok';
    } on Object {
      return false;
    } finally {
      s?.destroy();
    }
  }
}
