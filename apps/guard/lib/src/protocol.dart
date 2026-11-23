// Protocollo tra l'app e il guard: una riga JSON per messaggio, in UTF-8, sui
// pipe standard del guard. Il campo "t" dice il tipo.
//
// App → guard (stdin del guard):
//   {"t":"cmd","l":"say ciao","id":7,"ttl":5000}
//       riga per la console del server. "id" (facoltativo) chiede un esito
//       ack/nack; "ttl" (ms, facoltativo) scarta il comando se non è ancora
//       partito dopo tanto tempo dalla ricezione.
//   {"t":"stop"}   arresto pulito: "stop" sulla console, kill dopo la grazia
//   {"t":"kill"}   kill immediato dell'albero
//   Una riga che non è JSON va alla console così com'è.
//
// Guard → app (stdout del guard):
//   {"t":"started","pid":N,"guard":N,"contain":{...}}  server avviato
//   {"t":"o","l":"...","ts":MS}   riga dello stdout del server (ts: ms epoch)
//   {"t":"e","l":"...","ts":MS}   riga dello stderr del server
//   {"t":"ack","id":N}            comando scritto nello stdin del server
//   {"t":"nack","id":N,"why":"timeout"|"closed"|"full"}
//   {"t":"state","s":"stopping","trigger":"..."}
//   {"t":"diag","m":"..."}        diagnostica in chiaro
//   {"t":"exit","code":N|null,"reason":"...","trigger":"..."|null,"forced":bool}
//       ultimo messaggio: il server e tutto il suo albero sono finiti.
//       reason: exited | stopped | killed | start-failed | parent-dead-at-start
//
// Trigger dell'arresto: app, app-kill, stdin-eof, stdin-error, parent-dead,
// pdeathsig, sigterm.

/// Tipi dei messaggi app → guard.
abstract final class AppMsg {
  static const cmd = 'cmd';
  static const stop = 'stop';
  static const kill = 'kill';
}

/// Tipi dei messaggi guard → app.
abstract final class GuardMsg {
  static const started = 'started';
  static const out = 'o';
  static const err = 'e';
  static const ack = 'ack';
  static const nack = 'nack';
  static const state = 'state';
  static const diag = 'diag';
  static const exit = 'exit';
}

/// Valori di "reason" nel messaggio exit.
abstract final class ExitReason {
  /// Il server è uscito da solo (crash, o "stop" scritto come comando).
  static const exited = 'exited';

  /// Arresto chiesto e server uscito entro la grazia.
  static const stopped = 'stopped';

  /// Albero ucciso: kill esplicito o grazia scaduta.
  static const killed = 'killed';

  /// Il guard non è riuscito ad avviare il server.
  static const startFailed = 'start-failed';

  /// L'app era già morta quando il guard è partito: niente avviato.
  static const parentDeadAtStart = 'parent-dead-at-start';
}

/// Exit code del processo guard.
abstract final class GuardExitCode {
  static const ok = 0;
  static const startFailed = 2;
  static const parentDead = 3;
  static const usage = 64;
}
