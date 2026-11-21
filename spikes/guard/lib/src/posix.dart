// Chiamate libc via FFI per Linux e macOS. Tutto è risolto in modo pigro
// (le variabili top-level di Dart sono lazy), quindi importare questo file
// su Windows non fa danni finché non si chiama niente.
import 'dart:ffi';
import 'dart:io';

final DynamicLibrary _libc = DynamicLibrary.process();

final int Function() getppid =
    _libc.lookupFunction<Int32 Function(), int Function()>('getppid');
final int Function() getpgrp =
    _libc.lookupFunction<Int32 Function(), int Function()>('getpgrp');
final int Function(int, int) setpgid = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'setpgid');
final int Function(int, int) kill = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'kill');

// prctl è variadica: la si dichiara come tale (conta su arm64).
final int Function(int, int, int, int, int) prctl = _libc.lookupFunction<
    Int32 Function(Int32, VarArgs<(UintPtr, UintPtr, UintPtr, UintPtr)>),
    int Function(int, int, int, int, int)>('prctl');

const int sigterm = 15;
const int sigkill = 9;
// Numeri di SIGUSR2: diversi tra Linux e macOS.
int get sigusr2 => Platform.isMacOS ? 31 : 12;

const int prSetPdeathsig = 1;
const int prSetChildSubreaper = 36;

/// Una riga della tabella dei processi.
class ProcRow {
  ProcRow(this.pid, this.ppid, this.pgid, this.zombie, [this.args = '']);
  final int pid, ppid, pgid;
  final bool zombie;
  final String args;
}

/// Elenco dei processi: /proc su Linux, `ps` su macOS.
List<ProcRow> listProcesses({bool withArgs = false}) {
  if (Platform.isLinux) return _listProc(withArgs);
  final r = Process.runSync('ps', [
    '-A',
    '-o',
    withArgs ? 'pid=,ppid=,pgid=,stat=,command=' : 'pid=,ppid=,pgid=,stat='
  ]);
  final out = <ProcRow>[];
  for (final line in (r.stdout as String).split('\n')) {
    final f = line.trim().split(RegExp(r'\s+'));
    if (f.length < 4) continue;
    final pid = int.tryParse(f[0]);
    if (pid == null) continue;
    out.add(ProcRow(pid, int.parse(f[1]), int.parse(f[2]), f[3].startsWith('Z'),
        withArgs ? f.sublist(4).join(' ') : ''));
  }
  return out;
}

List<ProcRow> _listProc(bool withArgs) {
  final out = <ProcRow>[];
  for (final e in Directory('/proc').listSync(followLinks: false)) {
    final pid = int.tryParse(e.path.substring(6));
    if (pid == null) continue;
    final row = readProcStat(pid, withArgs: withArgs);
    if (row != null) out.add(row);
  }
  return out;
}

/// Legge /proc/<pid>/stat (Linux). null se il processo non c'è più.
ProcRow? readProcStat(int pid, {bool withArgs = false}) {
  try {
    final s = File('/proc/$pid/stat').readAsStringSync();
    // il nome tra parentesi può contenere spazi: si parte dall'ultima ')'
    final f = s.substring(s.lastIndexOf(')') + 2).split(' ');
    var args = '';
    if (withArgs) {
      args = File('/proc/$pid/cmdline')
          .readAsStringSync()
          .replaceAll('\u0000', ' ');
    }
    return ProcRow(pid, int.parse(f[1]), int.parse(f[2]), f[0] == 'Z', args);
  } catch (_) {
    return null;
  }
}

/// Vivo = esiste e non è uno zombie.
bool posixAlive(int pid) {
  if (Platform.isLinux) {
    final r = readProcStat(pid);
    return r != null && !r.zombie;
  }
  final r = Process.runSync('ps', ['-o', 'stat=', '-p', '$pid']);
  final st = (r.stdout as String).trim();
  return st.isNotEmpty && !st.startsWith('Z');
}
