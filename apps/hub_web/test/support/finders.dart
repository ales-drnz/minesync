// Ricerca dei testi del design system nei test: MsText (anche con parti in
// grassetto), pulsanti, eyebrow e codice, per testo esatto o parziale.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

String? _textOf(Widget w) => switch (w) {
  MsText(:final spans?) => spans.map((s) => s.text).join(),
  MsText(:final text) => text,
  MsButton(:final label?) => label,
  MsEyebrow(:final text) || MsCode(:final text) => text,
  MsFieldError(:final message) => message,
  MsDialog(:final title) => title,
  MsSwitch(:final label?) => label,
  _ => null,
};

/// Widget del design system con il testo [text] (stringa esatta o RegExp).
Finder msText(Pattern text) => find.byWidgetPredicate((w) {
  final t = _textOf(w);
  if (t == null) return false;
  return text is String ? t == text : text.allMatches(t).isNotEmpty;
}, description: 'testo "$text"');

/// Widget del design system il cui testo contiene [part].
Finder msTextContaining(String part) => msText(RegExp(RegExp.escape(part)));

/// Pulsante con l'etichetta [label].
Finder msButton(String label) => find.byWidgetPredicate(
  (w) => w is MsButton && w.label == label,
  description: 'pulsante "$label"',
);
