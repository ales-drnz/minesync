/// Supervisione del server Minecraft: il server parte sotto il guard
/// (`bin/minesync_guard.dart`) e non sopravvive mai all'app. Questa libreria
/// è il lato app: [GuardClient] avvia il guard e parla con lui.
library;

export 'src/client.dart';
