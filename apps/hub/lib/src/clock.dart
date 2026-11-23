// Orologio dell'hub: ora di parete per i timestamp e orologio monotono per
// le scadenze (lock, push). I test usano [FakeClock] per viaggiare nel tempo.

/// Sorgente del tempo.
abstract interface class Clock {
  /// Ora di parete in millisecondi dall'epoch (UTC).
  int wallMs();

  /// Millisecondi monotoni: non tornano mai indietro, anche se l'ora di
  /// sistema cambia. Utili solo come differenze.
  int monoMs();

  /// Ora di parete come [DateTime] locale (per i giorni di calendario).
  DateTime now();
}

/// Orologio reale.
final class SystemClock implements Clock {
  SystemClock() : _sw = Stopwatch()..start();
  final Stopwatch _sw;

  @override
  int wallMs() => DateTime.now().millisecondsSinceEpoch;

  @override
  int monoMs() => _sw.elapsedMilliseconds;

  @override
  DateTime now() => DateTime.now();
}

/// Orologio manuale per i test: parte da [start] e avanza solo con
/// [advance]. [setWall] sposta solo l'ora di parete (orologio cambiato).
final class FakeClock implements Clock {
  FakeClock([DateTime? start]) : _wall = (start ?? DateTime.now()).millisecondsSinceEpoch;
  int _wall;
  int _mono = 0;

  void advance(Duration d) {
    _wall += d.inMilliseconds;
    _mono += d.inMilliseconds;
  }

  void setWall(DateTime t) => _wall = t.millisecondsSinceEpoch;

  @override
  int wallMs() => _wall;

  @override
  int monoMs() => _mono;

  @override
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(_wall);
}
