// Chiamate kernel32 via FFI (solo Windows, risolte in modo pigro).
// Scritte a mano con dart:ffi + package:ffi (BSD-3) per non dipendere da
// package:win32: servono poche funzioni e due strutture a offset fissi.
//
// NON VERIFICATO localmente (nessuna macchina Windows): lo esercita run.ps1
// in CI.
import 'dart:ffi';

import 'package:ffi/ffi.dart';

final DynamicLibrary _k32 = DynamicLibrary.open('kernel32.dll');

final int Function(Pointer<Void>, Pointer<Utf16>) _createJobObject =
    _k32.lookupFunction<IntPtr Function(Pointer<Void>, Pointer<Utf16>),
        int Function(Pointer<Void>, Pointer<Utf16>)>('CreateJobObjectW');
final int Function(int, int, Pointer<Void>, int) _setInformationJobObject =
    _k32.lookupFunction<Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32),
        int Function(int, int, Pointer<Void>, int)>('SetInformationJobObject');
final int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)
    _queryInformationJobObject = _k32.lookupFunction<
        Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
        int Function(int, int, Pointer<Void>, int,
            Pointer<Uint32>)>('QueryInformationJobObject');
final int Function(int, int) _assignProcessToJobObject =
    _k32.lookupFunction<Int32 Function(IntPtr, IntPtr), int Function(int, int)>(
        'AssignProcessToJobObject');
final int Function() _getCurrentProcess =
    _k32.lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
final int Function() getCurrentProcessId =
    _k32.lookupFunction<Uint32 Function(), int Function()>(
        'GetCurrentProcessId');
final int Function(int, int, int) openProcess = _k32.lookupFunction<
    IntPtr Function(Uint32, Int32, Uint32),
    int Function(int, int, int)>('OpenProcess');
final int Function(int, int) waitForSingleObject = _k32.lookupFunction<
    Uint32 Function(IntPtr, Uint32), int Function(int, int)>(
    'WaitForSingleObject');
final int Function(int, int) terminateProcess = _k32.lookupFunction<
    Int32 Function(IntPtr, Uint32), int Function(int, int)>('TerminateProcess');
final int Function(int) closeHandle =
    _k32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'CloseHandle');

const int synchronize = 0x00100000;
const int processTerminate = 0x0001;
const int waitObject0 = 0;

const int _jobObjectBasicProcessIdList = 3;
const int _jobObjectExtendedLimitInformation = 9;
const int _killOnJobClose = 0x2000;
const int _breakawayOk = 0x0800;

/// Crea un job kill-on-close e ci mette il processo corrente: i figli lo
/// ereditano, e quando l'ultimo handle del job si chiude (cioè quando muore
/// il guard, in qualunque modo) il kernel termina tutto l'albero.
/// Ritorna l'handle (da NON chiudere mai) o 0 in caso di errore.
int createKillOnCloseJobForSelf() {
  final job = _createJobObject(nullptr, nullptr);
  if (job == 0) return 0;
  // JOBOBJECT_EXTENDED_LIMIT_INFORMATION su 64 bit: 144 byte,
  // BasicLimitInformation.LimitFlags all'offset 16.
  final info = calloc<Uint8>(144);
  try {
    (info + 16).cast<Uint32>().value = _killOnJobClose | _breakawayOk;
    if (_setInformationJobObject(
            job, _jobObjectExtendedLimitInformation, info.cast(), 144) ==
        0) {
      closeHandle(job);
      return 0;
    }
  } finally {
    calloc.free(info);
  }
  if (_assignProcessToJobObject(job, _getCurrentProcess()) == 0) {
    closeHandle(job);
    return 0;
  }
  return job;
}

/// PID dei processi nel job (incluso il chiamante).
List<int> jobPids(int job) {
  // JOBOBJECT_BASIC_PROCESS_ID_LIST: 2 DWORD + array di ULONG_PTR da 8 byte.
  const cap = 1024;
  const size = 8 + 8 * cap;
  final buf = calloc<Uint8>(size);
  try {
    if (_queryInformationJobObject(
            job, _jobObjectBasicProcessIdList, buf.cast(), size, nullptr) ==
        0) {
      return const [];
    }
    final n = (buf + 4).cast<Uint32>().value;
    final ids = (buf + 8).cast<Uint64>();
    return [for (var i = 0; i < n; i++) ids[i]];
  } finally {
    calloc.free(buf);
  }
}

/// Vivo = apribile e non ancora segnalato.
bool winAlive(int pid) {
  final h = openProcess(synchronize, 0, pid);
  if (h == 0) return false;
  try {
    return waitForSingleObject(h, 0) != waitObject0;
  } finally {
    closeHandle(h);
  }
}

void winTerminate(int pid) {
  final h = openProcess(processTerminate, 0, pid);
  if (h == 0) return;
  terminateProcess(h, 1);
  closeHandle(h);
}
