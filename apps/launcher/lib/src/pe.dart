// Sottosistema di un eseguibile Windows (PE). `dart compile exe` produce
// sempre un programma da console: avviato da un collegamento aprirebbe una
// finestra nera accanto all'app. Il launcher distribuito viene marcato come
// programma GUI cambiando un campo dell'header (la firma Authenticode si
// applica dopo).
import 'dart:typed_data';

const peSubsystemGui = 2;
const peSubsystemConsole = 3;

/// Offset del campo Subsystem nell'header opzionale (uguale per PE32 e PE32+).
int _subsystemOffset(Uint8List exe) {
  if (exe.length < 0x40 || exe[0] != 0x4d || exe[1] != 0x5a) {
    throw const FormatException('non è un eseguibile Windows (manca MZ)');
  }
  final pe = ByteData.sublistView(exe).getUint32(0x3c, Endian.little);
  if (pe + 24 + 70 > exe.length ||
      exe[pe] != 0x50 ||
      exe[pe + 1] != 0x45 ||
      exe[pe + 2] != 0 ||
      exe[pe + 3] != 0) {
    throw const FormatException('header PE non valido');
  }
  final magic = ByteData.sublistView(exe).getUint16(pe + 24, Endian.little);
  if (magic != 0x10b && magic != 0x20b) throw const FormatException('header opzionale');
  return pe + 24 + 68;
}

/// Sottosistema dichiarato da [exe].
int peSubsystem(Uint8List exe) =>
    ByteData.sublistView(exe).getUint16(_subsystemOffset(exe), Endian.little);

/// Imposta il sottosistema di [exe] (modifica i byte sul posto).
void setPeSubsystem(Uint8List exe, int subsystem) =>
    ByteData.sublistView(exe).setUint16(_subsystemOffset(exe), subsystem, Endian.little);
