// Panoramica: 6 card (3 stato + 3 server) e feed eventi dal vivo (SSE).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/link.dart';

import 'sse.dart';
import 'theme.dart';

class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const _Banner(),
          const SizedBox(height: 16),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: const [
              _StatCard('SERVER APERTI ORA', '1 di 3', 'Isola · in gioco'),
              _StatCard('GIOCATORI ORA', '3', 'Sara, Luca, Teo'),
              _StatCard('DISCO HUB', '91 %', 'liberi 180 GB su 2 TB',
                  warn: true),
              _ServerCard('isola', 'Isola',
                  'Minecraft 1.21.1 · Fabric · 42 mod', 'In gioco', Ms.info),
              _ServerCard('valle', 'Valle', 'Minecraft 1.21.1 · vanilla',
                  'Libero', Ms.ok),
              _ServerCard('atm10', 'ATM 10',
                  'Minecraft 1.21.1 · NeoForge · 214 mod', 'Stale', Ms.warn),
            ],
          ),
          const SizedBox(height: 24),
          const _Feed(),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: Ms.warnBg, border: Border.all(color: Ms.warn, width: 2)),
        child: const Row(children: [
          Icon(Icons.warning_amber, color: Ms.warn),
          SizedBox(width: 10),
          Expanded(
              child: Text(
                  "Disco dell'hub quasi pieno: la pulizia automatica "
                  'libererà circa 3,1 GB stanotte.')),
        ]),
      );
}

class _CardFrame extends StatelessWidget {
  const _CardFrame({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 300,
        child: Card(
            child: Padding(padding: const EdgeInsets.all(16), child: child)),
      );
}

class _StatCard extends StatelessWidget {
  const _StatCard(this.title, this.value, this.sub, {this.warn = false});
  final String title, value, sub;
  final bool warn;
  @override
  Widget build(BuildContext context) => _CardFrame(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: silkTitle),
          const SizedBox(height: 8),
          Text(value,
              style: TextStyle(
                  fontSize: 32, color: warn ? Ms.warn : Ms.text, height: 1)),
          const SizedBox(height: 6),
          Text(sub, style: const TextStyle(color: Ms.text2)),
        ]),
      );
}

class _ServerCard extends StatelessWidget {
  const _ServerCard(this.id, this.name, this.desc, this.state, this.color);
  final String id, name, desc, state;
  final Color color;
  @override
  Widget build(BuildContext context) => _CardFrame(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(name, style: const TextStyle(fontSize: 22)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              color: color,
              child: Text(state,
                  style: const TextStyle(
                      fontFamily: Ms.silk, fontSize: 11, color: Ms.bg)),
            ),
          ]),
          const SizedBox(height: 6),
          Text(desc, style: monoSmall),
          const SizedBox(height: 12),
          // Link vero verso la scheda del server (testa anche "indietro").
          Link(
            uri: Uri.parse('/server/$id'),
            builder: (context, follow) => OutlinedButton(
              onPressed: follow,
              style: OutlinedButton.styleFrom(
                  shape: const RoundedRectangleBorder()),
              child: Text('Apri $name'),
            ),
          ),
        ]),
      );
}

class _Feed extends StatefulWidget {
  const _Feed();
  @override
  State<_Feed> createState() => _FeedState();
}

class _FeedState extends State<_Feed> {
  final _events = <HubEvent>[];
  StreamSubscription<HubEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = hubEvents('/api/events').listen((e) {
      setState(() {
        _events.insert(0, e);
        if (_events.length > 50) _events.removeLast();
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Semantics(
                header: true,
                child: const Text('ATTIVITÀ', style: silkTitle)),
            const SizedBox(width: 10),
            Text('${_events.length} eventi · dal vivo', style: monoSmall),
          ]),
          const SizedBox(height: 10),
          if (_events.isEmpty)
            const Text('In attesa di eventi…', style: TextStyle(color: Ms.text3)),
          for (final e in _events)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                SizedBox(
                    width: 64,
                    child: Text(
                        '${e.at.hour.toString().padLeft(2, '0')}:'
                        '${e.at.minute.toString().padLeft(2, '0')}:'
                        '${e.at.second.toString().padLeft(2, '0')}',
                        style: monoSmall)),
                SizedBox(
                    width: 90,
                    child: Text(e.kind.toUpperCase(),
                        style: const TextStyle(
                            fontFamily: Ms.silk,
                            fontSize: 11,
                            color: Ms.info))),
                Expanded(child: Text('${e.who} · ${e.what}')),
              ]),
            ),
        ]),
      ),
    );
  }
}

class ServerPage extends StatelessWidget {
  const ServerPage({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context) => SelectionArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Text('Server · $id', style: const TextStyle(fontSize: 28)),
          const SizedBox(height: 12),
          const Text('Scheda di prova: usa il tasto indietro del browser.'),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
                onPressed: () => context.go('/'),
                child: const Text('Torna alla panoramica')),
          ),
        ]),
      );
}
