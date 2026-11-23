// Pulizia delle cartelle temporanee dei test.
import 'dart:io';

/// Cancella [dir] e quello che contiene. Su Windows un processo appena
/// chiuso (hub, guard, server finto) può tenere aperto un file ancora per
/// qualche istante: si riprova un po' e poi si lascia stare, perché una
/// cartella temporanea rimasta non è un errore del test.
Future<void> deleteQuietly(Directory dir) async {
  for (var i = 0; i < 10; i++) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
}
