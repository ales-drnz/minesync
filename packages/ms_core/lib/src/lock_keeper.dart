// Tiene vivo il lock con heartbeat periodici. Un 409 o un 404 space_gone
// annullano l'operazione in corso; gli errori di rete e i 5xx sono
// transitori e si riprovano al giro dopo.
import 'dart:async';

import 'package:ms_protocol/ms_protocol.dart';

import 'hub_client.dart';
import 'sync_errors.dart';

/// Classifica un errore dell'hub: è la perdita del lock?
bool isLockLoss(Object e) =>
    e is ApiError && (e.code == ErrorCode.lockLost || e.code == ErrorCode.locked);

/// Classifica un errore dell'hub: lo spazio è stato cancellato?
bool isSpaceGone(Object e) => e is ApiError && e.code == ErrorCode.spaceGone;

final class LockKeeper {
  LockKeeper(this.client, this.space, this.grant, {required this.cancel, LockInfo Function()? info})
    : _info = info ?? (() => const LockInfo());

  final HubClient client;
  final String space;
  final LockGrant grant;

  /// Annullato con il motivo se il lock si perde.
  final CancelToken cancel;
  final LockInfo Function() _info;

  Timer? _timer;
  bool _stopped = false;
  bool _beating = false;

  /// Battiti riusciti (per i test e la diagnostica).
  int beats = 0;

  void start() {
    _timer ??= Timer.periodic(Duration(milliseconds: grant.heartbeatMs), (_) => _beat());
  }

  Future<void> _beat() async {
    if (_stopped || _beating) return;
    _beating = true;
    try {
      await client.heartbeat(space, grant.token, _info());
      if (!_stopped) beats++;
    } on Object catch (e) {
      if (_stopped) return;
      if (isSpaceGone(e)) {
        cancel.cancel(SyncException(SyncErrorKind.spaceGone, message: 'space deleted', cause: e));
        stop();
      } else if (isLockLoss(e)) {
        cancel.cancel(SyncException(SyncErrorKind.lockLost, message: 'lock lost', cause: e));
        stop();
      }
      // altri errori: transitori, si riprova al prossimo battito
    } finally {
      _beating = false;
    }
  }

  /// Ferma i battiti. Idempotente; non è una perdita del lock.
  void stop() {
    _stopped = true;
    _timer?.cancel();
  }
}
