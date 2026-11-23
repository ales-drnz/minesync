// Dialoghi di conferma dell'area Admin (ruoli, pulizia, token).
import 'package:flutter/widgets.dart';
import 'package:ms_ui/ms_ui.dart';

import '../../l10n/l10n.dart';

/// Chiede conferma; true se confermato.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required Widget body,
  required String confirmLabel,
  MsIconData icon = MsIcons.warn,
  bool danger = false,
}) async {
  final s = context.s.common;
  final r = await showMsDialog<bool>(
    context: context,
    builder: (context) => MsDialog(
      title: title,
      icon: MsIcon(icon),
      tone: danger ? MsDialogTone.danger : MsDialogTone.normal,
      onDismiss: () => Navigator.of(context).pop(false),
      body: body,
      actions: [
        MsButton(label: s.cancel, onPressed: () => Navigator.of(context).pop(false)),
        MsButton(
          label: confirmLabel,
          variant: danger ? MsButtonVariant.danger : MsButtonVariant.primary,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );
  return r ?? false;
}
