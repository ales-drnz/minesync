// Ricostruisce il figlio a intervalli regolari: durate dal vivo ("aperto
// da 1 h 14 min", "4 min fa") senza ricaricare niente dall'hub.
import 'dart:async';

import 'package:flutter/widgets.dart';

class Ticking extends StatefulWidget {
  const Ticking({super.key, required this.builder, this.every = const Duration(seconds: 30)});

  final WidgetBuilder builder;
  final Duration every;

  @override
  State<Ticking> createState() => _TickingState();
}

class _TickingState extends State<Ticking> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(widget.every, (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
