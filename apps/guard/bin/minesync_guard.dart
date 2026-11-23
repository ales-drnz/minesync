// Binario del guard: avvia il server Minecraft come proprio figlio e fa da
// ponte con l'app (protocollo in lib/src/protocol.dart). La CI lo compila
// con `dart compile exe`.
import 'package:minesync_guard/src/guard.dart';

void main(List<String> argv) => runGuard(argv);
