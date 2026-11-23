// Limite di banda degli upload: secchiello di gettoni con un piccolo burst
// iniziale, applicato allo stream dei byte.
import 'dart:async';

/// Restituisce [s] limitato a [bytesPerSecond] (0 o meno = nessun limite).
Stream<List<int>> throttle(
  Stream<List<int>> s,
  int bytesPerSecond, {
  Duration burst = const Duration(milliseconds: 250),
}) {
  if (bytesPerSecond <= 0) return s;
  final sw = Stopwatch()..start();
  final burstBytes = bytesPerSecond * burst.inMicroseconds ~/ 1000000;
  var sent = 0;
  return s.asyncMap((chunk) async {
    sent += chunk.length;
    final due = Duration(microseconds: (sent - burstBytes) * 1000000 ~/ bytesPerSecond);
    final wait = due - sw.elapsed;
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    return chunk;
  });
}
