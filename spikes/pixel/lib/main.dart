// App dimostrativa: la galleria pixel alla scala ricavata dal dpr reale.
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'gallery.dart';
import 'ms/icons.dart';
import 'ms/tokens.dart';
import 'pixel/grid.dart';

void main() => runApp(const PixelApp());

class PixelApp extends StatefulWidget {
  const PixelApp({super.key, this.consoleController, this.consoleHeight = 240});
  final ScrollController? consoleController;
  final double consoleHeight;
  @override
  State<PixelApp> createState() => _PixelAppState();
}

class _PixelAppState extends State<PixelApp> {
  Map<String, ui.Image>? _raster;

  @override
  void initState() {
    super.initState();
    loadRasterIcons().then((m) => setState(() => _raster = m));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Ms.bg,
        child: PixelScope(
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Gallery(
                  raster: _raster,
                  consoleController: widget.consoleController,
                  consoleHeight: widget.consoleHeight),
            ),
          ),
        ),
      ),
    );
  }
}

Future<Map<String, ui.Image>> loadRasterIcons() async => {
      for (final e in MsIcons.all.entries)
        e.key: await MsIcons.toImage(e.value, e.key == 'globe' ? Ms.info : Ms.text),
    };
