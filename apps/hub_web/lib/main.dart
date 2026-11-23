// Avvio della web UI dell'hub: URL senza `#`, trasporto e servizi del
// browser, stato e app. Solo per il web (importa package:web): i test
// montano HubWebApp con un HubApi finto.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'src/api/browser_transport.dart';
import 'src/api/http_hub_api.dart';
import 'src/app.dart';
import 'src/platform/browser_platform.dart';
import 'src/state/hub_state.dart';

void main() {
  usePathUrlStrategy();
  final platform = BrowserPlatform();
  final state = HubState(
    HubDeps(api: HttpHubApi(BrowserTransport(), platform.origin), platform: platform),
  );
  runApp(HubWebApp(state: state));
  unawaited(state.start());
}
