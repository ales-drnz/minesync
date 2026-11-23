// Chiamate della libc via FFI per Linux e macOS, e tabella dei processi.
// Le variabili top-level di Dart sono pigre: importare questo file su Windows
// non fa danni finché non si chiama niente.
import 'dart:ffi';
import 'dart:io';

final DynamicLibrary _libc = DynamicLibrary.process();

final int Function() getppid = _libc.lookupFunction<Int32 Function(), int Function()>('getppid');
final int Function() getpgrp = _libc.lookupFunction<Int32 Function(), int Function()>('getpgrp');
final int Function(int, int) setpgid = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('setpgid');
final int Function(int, int) kill = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('kill');

// prctl è variadica e va dichiarata come tale (su arm64 la convenzione di
// chiamata è diversa da quella di una funzione normale).
final int Function(int, int, int, int, int) prctl = _libc
    .lookupFunction<
      Int32 Function(Int32, VarArgs<(UintPtr, UintPtr, UintPtr, UintPtr)>),
      int Function(int, int, int, int, int)
    >('prctl');

const int sigterm = 15;
const int sigkill = 9;

/// SIGUSR2: il numero cambia tra Linux e macOS.
int get sigusr2 => Platform.isMacOS ? 31 : 12;

const int prSetPdeathsig = 1;
const int prSetChildSubreaper = 36;

/// Una riga della tabella dei processi.
final class ProcRow {
  const ProcRow(this.pid, this.ppid, this.pgid, this.zombie, [this.args = '']);
  final int pid;
  final int ppid;
  final int pgid;
  final bool zombie;

  /// Riga di comando (solo se richiesta).
  final String args;
}

/// Tabella dei processi: /proc su Linux, `ps` su macOS.
List<ProcRow> listProcesses({bool withArgs = false}) {
  if (Platform.isLinux) return _listProc(withArgs);
  // `ucomm` (nome dell'eseguibile, senza spazi) serve a riconoscere il `ps`
  // lanciato qui: è nostro figlio e sta nel nostro gruppo, e senza scartarlo
  // il guard vedrebbe sempre un membro vivo e non finirebbe mai.
  final r = Process.runSync('ps', [
    '-A',
    '-o',
    withArgs ? 'pid=,ppid=,pgid=,stat=,ucomm=,command=' : 'pid=,ppid=,pgid=,stat=,ucomm=',
  ]);
  final self = pid;
  final out = <ProcRow>[];
  for (final line in (r.stdout as String).split('\n')) {
    final f = line.trim().split(RegExp(r'\s+'));
    if (f.length < 5) continue;
    final p = int.tryParse(f[0]);
    final ppid = int.tryParse(f[1]);
    final pgid = int.tryParse(f[2]);
    if (p == null || ppid == null || pgid == null) continue;
    if (ppid == self && f[4] == 'ps') continue;
    out.add(ProcRow(p, ppid, pgid, f[3].startsWith('Z'), withArgs ? f.sublist(5).join(' ') : ''));
  }
  return out;
}

List<ProcRow> _listProc(bool withArgs) {
  final out = <ProcRow>[];
  for (final e in Directory('/proc').listSync(followLinks: false)) {
    final p = int.tryParse(e.path.substring(6));
    if (p == null) continue;
    final row = readProcStat(p, withArgs: withArgs);
    if (row != null) out.add(row);
  }
  return out;
}

/// Legge `/proc/<pid>/stat` (solo Linux); null se il processo non c'è più.
ProcRow? readProcStat(int p, {bool withArgs = false}) {
  try {
    final s = File('/proc/$p/stat').readAsStringSync();
    // il nome tra parentesi può contenere spazi: si parte dall'ultima ')'
    final f = s.substring(s.lastIndexOf(')') + 2).split(' ');
    var args = '';
    if (withArgs) {
      args = File('/proc/$p/cmdline').readAsStringSync().replaceAll('\u0000', ' ');
    }
    return ProcRow(p, int.parse(f[1]), int.parse(f[2]), f[0] == 'Z', args);
  } on Object {
    return null;
  }
}

/// Vivo = esiste e non è uno zombie.
bool posixAlive(int p) {
  if (Platform.isLinux) {
    final r = readProcStat(p);
    return r != null && !r.zombie;
  }
  final r = Process.runSync('ps', ['-o', 'stat=', '-p', '$p']);
  final st = (r.stdout as String).trim();
  return st.isNotEmpty && !st.startsWith('Z');
}

/// Membri vivi (non zombie) del process group [pgid].
List<int> groupMembers(int pgid) => [
  for (final r in listProcesses())
    if (r.pgid == pgid && !r.zombie) r.pid,
];
