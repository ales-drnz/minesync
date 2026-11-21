// Pagina admin lunga: ~40 campi in sezioni, generati da una tabella di
// specifiche per tenere il codice corto. Ogni campo ha un'etichetta vera
// (labelText) che finisce nell'albero semantico.
import 'package:flutter/material.dart';

import 'theme.dart';

enum K { text, number, secret, multi, toggle, choice }

class F {
  const F(this.k, this.label,
      {this.help, this.initial = '', this.options = const [], this.min, this.max});
  final K k;
  final String label;
  final String? help;
  final String initial;
  final List<String> options;
  final int? min, max;
}

const sections = <String, List<F>>{
  'Generale': [
    F(K.text, 'Nome dell\'hub', initial: 'Hub di Valle'),
    F(K.multi, 'Descrizione', initial: 'Server di gruppo'),
    F(K.choice, 'Lingua', options: ['Italiano', 'English'], initial: 'Italiano'),
    F(K.choice, 'Fuso orario',
        options: ['Europe/Rome', 'Europe/London', 'UTC'], initial: 'Europe/Rome'),
    F(K.text, 'Indirizzo dell\'hub', help: 'nome DNS sulla rete privata',
        initial: 'hub.example.internal'),
    F(K.number, 'Porta HTTP', initial: '8080', min: 1, max: 65535),
    F(K.text, 'Cartella dati', initial: '/data'),
  ],
  'Accesso e membri': [
    F(K.text, 'URL del controller', initial: 'https://ztnet.example.internal'),
    F(K.secret, 'Token API del controller', initial: 'segreto'),
    F(K.text, 'Id della rete', initial: '0000000000000000'),
    F(K.number, 'Aggiorna l\'elenco dei membri ogni (min)',
        initial: '5', min: 1, max: 1440),
    F(K.text, 'Admin iniziali', help: 'nomi separati da virgola',
        initial: 'admin'),
    F(K.toggle, 'Consenti ai membri nuovi di entrare subito'),
    F(K.toggle, 'Richiedi conferma admin per i dispositivi nuovi',
        initial: '1'),
    F(K.toggle, 'Mostra gli IP nella pagina membri'),
  ],
  'Disco e pulizia': [
    F(K.number, 'Conserva sempre le ultime (generazioni)',
        initial: '10', min: 1, max: 1000),
    F(K.number, 'Conserva la storia per (giorni)',
        initial: '14', min: 1, max: 3650),
    F(K.number, 'Soglia disco quasi pieno (%)', initial: '85', min: 50, max: 99),
    F(K.choice, 'Pulizia automatica',
        options: ['Ogni notte', 'Ogni settimana', 'Mai'], initial: 'Ogni notte'),
    F(K.multi, 'Esclusioni predefinite',
        initial: 'cache/\ncrash-reports/\ndebug/\nbluemap/'),
    F(K.toggle, 'Comprimi le generazioni vecchie', initial: '1'),
    F(K.toggle, 'Verifica l\'integrità dopo ogni salvataggio', initial: '1'),
  ],
  'Avvisi': [
    F(K.secret, 'Token del bot'),
    F(K.text, 'Id della chat'),
    F(K.number, 'Avvisa se un server aperto non salva da (min)',
        initial: '30', min: 5, max: 1440),
    F(K.toggle, 'Annuncia server aperto', initial: '1'),
    F(K.toggle, 'Annuncia server chiuso', initial: '1'),
    F(K.toggle, 'Annuncia blocco stale', initial: '1'),
    F(K.toggle, 'Annuncia disco quasi pieno', initial: '1'),
    F(K.toggle, 'Annuncia nuovi membri'),
    F(K.multi, 'Modello del messaggio', initial: '{chi} ha aperto {server}'),
  ],
  'Sessione e rete': [
    F(K.number, 'Limite di banda in upload (KB/s, 0 = nessuno)',
        initial: '0', min: 0, max: 1000000),
    F(K.number, 'Limite di banda in download (KB/s, 0 = nessuno)',
        initial: '0', min: 0, max: 1000000),
    F(K.number, 'Timeout della sessione (s)', initial: '120', min: 10, max: 3600),
    F(K.number, 'Heartbeat (s)', initial: '15', min: 1, max: 300),
    F(K.choice, 'Compressione del trasferimento',
        options: ['Automatica', 'zstd', 'Nessuna'], initial: 'Automatica'),
  ],
  'Aggiornamenti': [
    F(K.choice, 'Canale', options: ['Stabile', 'Beta'], initial: 'Stabile'),
    F(K.toggle, 'Aggiorna automaticamente l\'hub'),
    F(K.text, 'Chiave pubblica di firma', initial: 'ed25519:…'),
    F(K.toggle, 'Offri l\'app desktop su /dl', initial: '1'),
  ],
};

class AdminPage extends StatefulWidget {
  const AdminPage({super.key});
  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  final _form = GlobalKey<FormState>();
  final _toggles = <String, bool>{};
  final _choices = <String, String>{};

  @override
  void initState() {
    super.initState();
    for (final f in sections.values.expand((e) => e)) {
      if (f.k == K.toggle) _toggles[f.label] = f.initial == '1';
      if (f.k == K.choice) _choices[f.label] = f.initial;
    }
  }

  Widget _field(F f) {
    switch (f.k) {
      case K.toggle:
        return SwitchListTile(
          title: Text(f.label),
          value: _toggles[f.label]!,
          onChanged: (v) => setState(() => _toggles[f.label] = v),
          contentPadding: EdgeInsets.zero,
        );
      case K.choice:
        return DropdownButtonFormField<String>(
          initialValue: _choices[f.label],
          decoration: InputDecoration(labelText: f.label, helperText: f.help),
          items: [
            for (final o in f.options) DropdownMenuItem(value: o, child: Text(o))
          ],
          onChanged: (v) => _choices[f.label] = v!,
        );
      case K.number:
        return TextFormField(
          initialValue: f.initial,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
              labelText: f.label,
              helperText: f.help ?? 'da ${f.min} a ${f.max}'),
          validator: (v) {
            final n = int.tryParse(v ?? '');
            if (n == null) return 'Serve un numero intero';
            if (n < f.min! || n > f.max!) {
              return 'Fuori intervallo (${f.min}–${f.max})';
            }
            return null;
          },
        );
      case K.secret:
      case K.text:
      case K.multi:
        return TextFormField(
          initialValue: f.initial,
          obscureText: f.k == K.secret,
          minLines: f.k == K.multi ? 2 : 1,
          maxLines: f.k == K.multi ? 6 : 1,
          style: f.k == K.multi ? monoSmall.copyWith(color: Ms.text) : null,
          decoration: InputDecoration(labelText: f.label, helperText: f.help),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = sections.values.fold<int>(0, (a, b) => a + b.length);
    return Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                        header: true,
                        child: const Text('Admin · Hub di Valle',
                            style: TextStyle(fontSize: 28))),
                    Text('$count impostazioni', style: monoSmall),
                    const SizedBox(height: 16),
                    for (final s in sections.entries) ...[
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Semantics(
                                    header: true,
                                    child: Text(s.key.toUpperCase(),
                                        style: silkTitle)),
                                const SizedBox(height: 12),
                                for (final f in s.value) ...[
                                  _field(f),
                                  const SizedBox(height: 12),
                                ],
                              ]),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                            shape: const RoundedRectangleBorder()),
                        onPressed: () {
                          final ok = _form.currentState!.validate();
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(ok
                                  ? 'Impostazioni salvate (finto)'
                                  : 'Controlla i campi evidenziati')));
                        },
                        child: const Text('Salva'),
                      ),
                    ),
                  ]),
            ),
          ),
        ],
      ),
    );
  }
}
