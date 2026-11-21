// Astrazione "albero del server" usata dal guard: contenimento dei processi
// discendenti, elenco dei membri ancora vivi, kill dell'intero albero e
// controllo che il genitore (l'app) sia vivo.
import 'dart:io';

import 'src/posix.dart' as px;
import 'src/windows.dart' as win;

export 'src/posix.dart' show posixAlive, listProcesses, ProcRow;
export 'src/windows.dart' show winAlive;

abstract class ServerTree {
  factory ServerTree() => Platform.isWindows ? _WinTree() : _PosixTree();

  /// Da chiamare PRIMA di avviare il server. Ritorna diagnostica leggibile.
  Map<String, Object?> contain({required bool selfPdeathsig});

  /// Processi dell'albero ancora vivi, escluso il guard.
  List<int> members();

  /// SIGKILL / TerminateProcess a tutti i membri.
  void killAll();

  /// Registra il genitore; false se è già morto.
  bool watchParent(int? parentPid);
  bool parentAlive();
}

bool isAlive(int pid) => Platform.isWindows ? win.winAlive(pid) : px.posixAlive(pid);

class _PosixTree implements ServerTree {
  final int self = pid;
  bool ownGroup = false;
  int _ppid0 = -1;

  @override
  Map<String, Object?> contain({required bool selfPdeathsig}) {
    // Process group proprio: il server (e java figlio dello script) lo
    // eredita, così l'albero si colpisce anche dopo la morte di sh.
    ownGroup = px.setpgid(0, 0) == 0 && px.getpgrp() == self;
    var subreaper = false, pdeath = false;
    if (Platform.isLinux) {
      // I nipoti rimasti orfani (sh morto, processi staccati con setsid)
      // vengono riattaccati al guard invece che a init/systemd.
      subreaper = px.prctl(px.prSetChildSubreaper, 1, 0, 0, 0) == 0;
      if (selfPdeathsig) {
        // Notifica istantanea della morte dell'app. Si usa SIGUSR2 e non
        // SIGTERM per distinguerla da un SIGTERM "vero" e scartare quella
        // spuria (morte del solo thread che ci ha creato: getppid invariato).
        pdeath = px.prctl(px.prSetPdeathsig, px.sigusr2, 0, 0, 0) == 0;
      }
    }
    return {
      'ownGroup': ownGroup,
      'subreaper': subreaper,
      'selfPdeathsig': pdeath
    };
  }

  @override
  List<int> members() {
    final rows = px.listProcesses();
    final kids = <int, List<int>>{};
    final live = <int>{};
    final result = <int>{};
    for (final r in rows) {
      if (r.zombie) continue;
      live.add(r.pid);
      (kids[r.ppid] ??= []).add(r.pid);
      if (ownGroup && r.pgid == self && r.pid != self) result.add(r.pid);
    }
    // discendenti per ppid (con il subreaper include chi ha lasciato il gruppo)
    final todo = [...?kids[self]];
    while (todo.isNotEmpty) {
      final p = todo.removeLast();
      result.add(p);
      todo.addAll(kids[p] ?? const []);
    }
    result.remove(self);
    return result.where(live.contains).toList();
  }

  @override
  void killAll() {
    for (final p in members()) {
      px.kill(p, px.sigkill);
    }
  }

  @override
  bool watchParent(int? parentPid) {
    _ppid0 = px.getppid();
    // l'app è morta prima che il guard partisse: getppid è già cambiato
    if (parentPid != null && parentPid != _ppid0) return false;
    return parentAlive();
  }

  // Con un genitore morto getppid diventa 1 o il subreaper più vicino
  // (es. systemd --user): basta il confronto col valore iniziale.
  @override
  bool parentAlive() => px.getppid() == _ppid0;
}

class _WinTree implements ServerTree {
  final int self = pid;
  int job = 0;
  int _parent = 0;

  @override
  Map<String, Object?> contain({required bool selfPdeathsig}) {
    job = win.createKillOnCloseJobForSelf();
    return {'job': job != 0};
  }

  @override
  List<int> members() {
    if (job == 0) return const [];
    return win.jobPids(job).where((p) => p != self && win.winAlive(p)).toList();
  }

  @override
  void killAll() {
    for (final p in members()) {
      win.winTerminate(p);
    }
  }

  @override
  bool watchParent(int? parentPid) {
    if (parentPid == null) return true;
    _parent = win.openProcess(win.synchronize, 0, parentPid);
    // non apribile = già morto (stesso utente: niente problemi di permessi)
    if (_parent == 0) return false;
    return parentAlive();
  }

  @override
  bool parentAlive() =>
      _parent == 0 || win.waitForSingleObject(_parent, 0) != win.waitObject0;
}
