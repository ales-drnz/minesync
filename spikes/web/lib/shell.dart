// Intestazione con navigazione: link veri (<a href>) tramite url_launcher/Link,
// così tasto centrale / "apri in nuova scheda" funzionano.
import 'package:flutter/material.dart';
import 'package:url_launcher/link.dart';

import 'theme.dart';

class HubShell extends StatelessWidget {
  const HubShell({super.key, required this.location, required this.child});
  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 640;
    return Scaffold(
      body: Column(
        children: [
          Container(
            color: Ms.bg2,
            padding: EdgeInsets.symmetric(
                horizontal: narrow ? 12 : 24, vertical: 10),
            child: Row(
              children: [
                Semantics(
                  header: true,
                  child: const Text('MINESYNC',
                      style: TextStyle(
                          fontFamily: Ms.silk,
                          fontSize: 18,
                          color: Ms.accent,
                          fontWeight: FontWeight.w700)),
                ),
                if (!narrow) ...[
                  const SizedBox(width: 12),
                  const Text('Hub di Valle', style: TextStyle(color: Ms.text2)),
                ],
                const Spacer(),
                _NavLink('/', 'Panoramica', location == '/'),
                _NavLink('/admin', 'Admin', location == '/admin'),
                if (!narrow) ...[
                  const SizedBox(width: 12),
                  const _LiveDot(),
                ],
              ],
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _NavLink extends StatelessWidget {
  const _NavLink(this.path, this.label, this.active);
  final String path;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Link(
      uri: Uri.parse(path),
      builder: (context, follow) => TextButton(
        onPressed: follow,
        style: TextButton.styleFrom(
          foregroundColor: active ? Ms.accent : Ms.text,
          shape: const RoundedRectangleBorder(),
        ),
        child: Text(label,
            style: TextStyle(
                fontFamily: Ms.silk,
                fontSize: 13,
                decoration: active ? TextDecoration.underline : null)),
      ),
    );
  }
}

class _LiveDot extends StatelessWidget {
  const _LiveDot();
  @override
  Widget build(BuildContext context) => const Row(children: [
        Icon(Icons.circle, size: 10, color: Ms.ok),
        SizedBox(width: 6),
        Text('Dal vivo', style: monoSmall),
      ]);
}
