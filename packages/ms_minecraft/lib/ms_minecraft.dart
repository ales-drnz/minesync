/// Integrazione con il server Minecraft: lettura della console, rilevamento
/// della cartella server, ricerca e scelta di Java, comando di avvio,
/// server.properties ed eula.txt, metadati del mondo (NBT di level.dat,
/// giocatori, mod e loro jar). Non avvia né supervisiona processi.
library;

export 'src/console.dart';
export 'src/detect.dart';
export 'src/java.dart';
export 'src/launch.dart';
export 'src/level.dart';
export 'src/mods.dart';
export 'src/nbt.dart';
export 'src/players.dart';
export 'src/properties.dart';
export 'src/world_meta.dart';
export 'src/zip.dart';
