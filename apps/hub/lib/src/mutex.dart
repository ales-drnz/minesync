// Primitive di concorrenza dell'event loop: mutex asincrono e semaforo FIFO.
import 'dart:async';

/// Mutex asincrono: le sezioni critiche girano una alla volta, in ordine di
/// arrivo. Non è rientrante.
final class Mutex {
  Future<void> _tail = Future.value();

  Future<T> run<T>(FutureOr<T> Function() body) {
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return prev.then((_) async {
      try {
        return await body();
      } finally {
        done.complete();
      }
    });
  }
}

/// Semaforo contato con coda FIFO.
final class Semaphore {
  Semaphore(this.permits);
  final int permits;
  int _used = 0;
  final _queue = <Completer<void>>[];

  int get active => _used;
  int get queued => _queue.length;

  Future<void> acquire() {
    if (_used < permits) {
      _used++;
      return Future.value();
    }
    final c = Completer<void>();
    _queue.add(c);
    return c.future;
  }

  void release() {
    if (_queue.isNotEmpty) {
      // il posto passa al primo in coda: il contatore resta uguale
      _queue.removeAt(0).complete();
    } else {
      _used--;
    }
  }
}
