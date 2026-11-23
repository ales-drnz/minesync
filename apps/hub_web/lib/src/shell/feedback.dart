// Riscontri comuni a tutte le pagine: notifiche a comparsa, copia negli
// appunti, testo degli errori, conferma digitando il nome.
import 'package:flutter/widgets.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../api/hub_api.dart';
import '../l10n/l10n.dart';
import '../state/hub_state.dart';

/// Accesso al controller delle notifiche a comparsa.
class ToastScope extends InheritedWidget {
  const ToastScope({super.key, required this.controller, required super.child});
  final MsToastController controller;

  static MsToastController of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ToastScope>()!.controller;

  @override
  bool updateShouldNotify(ToastScope old) => old.controller != controller;
}

/// Mostra una notifica a comparsa.
void toast(BuildContext context, String title, {String? text, MsToastTone tone = MsToastTone.ok}) =>
    ToastScope.of(context).show(MsToastData(title: title, text: text, tone: tone));

/// Notifica di errore per [e] (ApiError, hub offline o altro).
void toastError(BuildContext context, Object e) =>
    toast(context, errorText(context.s, e), tone: MsToastTone.err);

/// Copia [text] negli appunti e lo dice con una notifica.
Future<void> copyText(BuildContext context, String text) async {
  final s = context.s;
  final toasts = ToastScope.of(context);
  await HubStateScope.read(context).platform.copy(text);
  toasts.show(MsToastData(title: s.shell.copied, tone: MsToastTone.ok));
}

/// Testo per l'utente di un errore.
String errorText(WebStrings s, Object e) => switch (e) {
  ApiError() => s.common.apiError(e.code, e.details),
  HubOffline() => s.common.offlineError,
  _ => s.common.unexpected('$e'),
};

/// Conferma un'azione irreversibile facendo scrivere [name] (es. eliminare
/// un server). true se confermata.
Future<bool> confirmByName(
  BuildContext context, {
  required String title,
  required Widget body,
  required String name,
  required String confirmLabel,
  String? help,
}) {
  final s = context.s.common;
  return showMsTypeToConfirm(
    context: context,
    title: title,
    body: body,
    expected: name,
    promptBefore: s.typeBefore,
    promptAfter: s.typeAfter,
    cancelLabel: s.cancel,
    confirmLabel: confirmLabel,
    help: help,
  );
}
