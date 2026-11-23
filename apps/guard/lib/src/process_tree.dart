// L'albero del server visto dal guard: contenimento dei discendenti, elenco
// dei membri ancora vivi, kill dell'intero albero e controllo che il
// genitore (l'app) sia ancora vivo.
import 'dart:io';

import 'posix.dart' as px;
import 'windows.dart' as win;

/// Vivo = esiste e non è uno zombie, su qualunque sistema.
bool processAlive(int pid) => Platform.isWindows ? win.winAlive(pid) : px.posixAlive(pid);

abstract interface class ProcessTree {
  factory ProcessTree() => Platform.isWindows ? _WindowsTree() : _PosixTree();

  /// Da chiamare prima di avviare il server. Restituisce una diagnostica
  /// leggibile di quello che è riuscito ad attivare.
  Map<String, Object?> contain({required bool selfPdeathsig});

  /// Processi dell'albero ancora vivi, escluso il guard.
  List<int> members();

  /// Kill immediato (SIGKILL / TerminateProcess) di tutti i membri.
  void killAll();

  /// Registra il genitore; false se è già morto.
  bool watchParent(int? parentPid);

  bool parentAlive();
}

final class _PosixTree implements ProcessTree {
  final int _self = pid;
  bool _ownGroup = false;
  int _ppid0 = -1;

  @override
  Map<String, Object?> contain({required bool selfPdeathsig}) {
    // Process group proprio: il server (e il java figlio dello script) lo
    // eredita, così l'albero si colpisce anche dopo la morte di sh, e l'app
    // può fermare il gruppo se il guard muore.
    _ownGroup = px.setpgid(0, 0) == 0 && px.getpgrp() == _self;
    var subreaper = false, pdeath = false;
    if (Platform.isLinux) {
      // I nipoti rimasti orfani (sh morto, processi staccati con setsid)
      // vengono riattaccati al guard invece che a init/systemd.
      subreaper = px.prctl(px.prSetChildSubreaper, 1, 0, 0, 0) == 0;
      if (selfPdeathsig) {
        // Avviso immediato della morte dell'app. SIGUSR2 e non SIGTERM per
        // distinguerlo da un SIGTERM vero e scartare quello spurio (muore
        // solo il thread che ci ha creato: getppid non cambia).
        pdeath = px.prctl(px.prSetPdeathsig, px.sigusr2, 0, 0, 0) == 0;
      }
    }
    return {'ownGroup': _ownGroup, 'subreaper': subreaper, 'selfPdeathsig': pdeath};
  }

  @override
  List<int> members() {
    final kids = <int, List<int>>{};
    final live = <int>{};
    final result = <int>{};
    for (final r in px.listProcesses()) {
      if (r.zombie) continue;
      live.add(r.pid);
      (kids[r.ppid] ??= []).add(r.pid);
      if (_ownGroup && r.pgid == _self && r.pid != _self) result.add(r.pid);
    }
    // discendenti per ppid: con il subreaper comprende anche chi ha lasciato
    // il gruppo
    final todo = [...?kids[_self]];
    while (todo.isNotEmpty) {
      final p = todo.removeLast();
      if (result.add(p)) todo.addAll(kids[p] ?? const []);
    }
    result.remove(_self);
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
    // se l'app è morta prima che il guard partisse, getppid è già cambiato
    if (parentPid != null && parentPid != _ppid0) return false;
    return parentAlive();
  }

  // Quando il genitore muore getppid diventa 1 o il subreaper più vicino
  // (per esempio systemd --user): basta il confronto con il valore iniziale.
  @override
  bool parentAlive() => px.getppid() == _ppid0;
}

final class _WindowsTree implements ProcessTree {
  final int _self = pid;
  int _job = 0;
  int _parent = 0;

  @override
  Map<String, Object?> contain({required bool selfPdeathsig}) {
    _job = win.createKillOnCloseJobForSelf();
    return {'job': _job != 0};
  }

  @override
  List<int> members() {
    if (_job == 0) return const [];
    return win.jobPids(_job).where((p) => p != _self && win.winAlive(p)).toList();
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
    // non apribile = già morto (stesso utente, nessun problema di permessi)
    if (_parent == 0) return false;
    return parentAlive();
  }

  @override
  bool parentAlive() => _parent == 0 || win.waitForSingleObject(_parent, 0) != win.waitObject0;
}
