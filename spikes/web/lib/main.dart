// Spike usa-e-getta: web UI dell'hub MineSync in Flutter web.
// Scopo: misurare peso, tempo al primo rendering, routing, accessibilità.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:web/web.dart' as web;

import 'router.dart';
import 'theme.dart';

void main() {
  // URL veri (/admin) invece di /#/admin.
  usePathUrlStrategy();
  WidgetsFlutterBinding.ensureInitialized();
  // ?a11y=1 forza l'albero semantico subito (per i test di accessibilità e
  // di Ctrl+F); di default Flutter lo attiva solo su richiesta dello screen
  // reader o col pulsante nascosto "Enable accessibility".
  if (Uri.base.queryParameters['a11y'] == '1') {
    SemanticsBinding.instance.ensureSemantics();
  }
  runApp(const HubApp());
  // Gancio di debug per le misure di tastiera: descrive il widget a fuoco
  // in un attributo del <body> (la build di prodotto non lo avrebbe).
  FocusManager.instance.addListener(() {
    web.document.body?.setAttribute('data-focus', describeFocus());
  });
  // Segnale per le misure: primo frame disegnato.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    web.window.performance.mark('flutter-first-frame');
    web.document.body?.setAttribute('data-first-frame', '1');
  });
}

class HubApp extends StatelessWidget {
  const HubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'MineSync Hub',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      routerConfig: router,
    );
  }
}

String describeFocus() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return '';
  final tf = ctx.findAncestorWidgetOfExactType<TextField>();
  if (tf != null) return 'campo: ${tf.decoration?.labelText}';
  final dd = ctx.findAncestorWidgetOfExactType<DropdownButtonFormField<String>>();
  if (dd != null) return 'scelta';
  final sw = ctx.findAncestorWidgetOfExactType<SwitchListTile>();
  if (sw != null) return 'interruttore: ${(sw.title as Text?)?.data}';
  final fb = ctx.findAncestorWidgetOfExactType<FilledButton>();
  if (fb != null) return 'pulsante: Salva';
  final tb = ctx.findAncestorWidgetOfExactType<TextButton>();
  if (tb != null) return 'link: ${(tb.child as Text?)?.data}';
  final ob = ctx.findAncestorWidgetOfExactType<OutlinedButton>();
  if (ob != null) return 'link: ${(ob.child as Text?)?.data}';
  return ctx.widget.runtimeType.toString();
}
