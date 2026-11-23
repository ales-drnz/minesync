// Collegamento al riconoscimento della console di ms_minecraft.
import 'package:ms_minecraft/ms_minecraft.dart';

import 'server_process.dart';

/// Parser della sessione basato sul riconoscimento vero della console
/// (resistente a chat, /say e /me).
ServerFact? minecraftParse(String line) => switch (parseConsoleLine(line)) {
  ServerStarted() => const FactStarted(),
  PlayerJoined(:final name) => FactJoined(name),
  PlayerLeft(:final name) => FactLeft(name),
  SaveConfirmed() => const FactSaved(),
  ServerStopping() => const FactStopping(),
  _ => null,
};
