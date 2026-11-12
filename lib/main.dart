import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ------------------------------------------------------------------ utilità
String two(int n) => n.toString().padLeft(2, '0');

String fmtDt(DateTime d) =>
    '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';

DateTime nowMinute() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day, n.hour, n.minute);
}

String fmtInterval(DateTime a, DateTime p) {
  final m = p.difference(a).inMinutes;
  return '${two(m ~/ 60)}:${two(m % 60)}';
}

// ------------------------------------------------------------------ modello
class Sosta {
  Sosta({
    required this.autista,
    required this.luogo,
    required this.arrivo,
    this.partenza,
  });

  final String autista;
  final String luogo;
  final DateTime arrivo;
  DateTime? partenza;

  String get intervallo =>
      partenza == null ? '' : fmtInterval(arrivo, partenza!);

  Map<String, dynamic> toJson() => {
        'autista': autista,
        'luogo': luogo,
        'arrivo': arrivo.toIso8601String(),
        'partenza': partenza?.toIso8601String(),
      };

  factory Sosta.fromJson(Map<String, dynamic> j) => Sosta(
        autista: j['autista'] as String,
        luogo: j['luogo'] as String,
        arrivo: DateTime.parse(j['arrivo'] as String),
        partenza: j['partenza'] == null
            ? null
            : DateTime.parse(j['partenza'] as String),
      );
}

// ------------------------------------------------------------------ storage
class Store {
  Store._(this._prefs, this._file, this.soste);

  final SharedPreferences _prefs;
  final File _file;
  final List<Sosta> soste;

  static Future<Store> load() async {
    final prefs = await SharedPreferences.getInstance();
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/soste.json');
    var soste = <Sosta>[];
    if (await file.exists()) {
      try {
        final data = jsonDecode(await file.readAsString()) as List<dynamic>;
        soste = data
            .map((e) => Sosta.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }
    return Store._(prefs, file, soste);
  }

  List<String> _list(String k) =>
      List<String>.of(_prefs.getStringList(k) ?? <String>[]);

  List<String> get autisti => _list('autisti');
  List<String> get luoghi => _list('luoghi');
  String get ultimoAutista => _prefs.getString('ultimo_autista') ?? '';

  Future<void> addItem(String kind, String nome) async {
    final n = nome.trim();
    final lista = _list(kind);
    if (n.isEmpty || lista.contains(n)) return;
    lista.add(n);
    lista.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    await _prefs.setStringList(kind, lista);
  }

  Future<void> removeItem(String kind, String nome) async {
    final lista = _list(kind)..remove(nome);
    await _prefs.setStringList(kind, lista);
    if (kind == 'autisti' && ultimoAutista == nome) {
      await _prefs.remove('ultimo_autista');
    }
  }

  Future<void> _persist() => _file
      .writeAsString(jsonEncode(soste.map((s) => s.toJson()).toList()));

  Future<void> addSosta(Sosta s) async {
    soste.add(s);
    await _persist();
    await _prefs.setString('ultimo_autista', s.autista);
  }

  Future<void> chiudi(Sosta s, DateTime partenza) async {
    s.partenza = partenza;
    await _persist();
  }

  // Elimina il record aggiunto più recentemente, senza modificare gli elenchi.
  Future<void> removeLastSosta() async {
    if (soste.isEmpty) return;
    soste.removeLast();
    await _persist();
  }

  // Elimina tutte le soste, mantenendo autisti e luoghi salvati nelle preferenze.
  Future<void> clearSoste() async {
    soste.clear();
    await _persist();
  }

  String _esc(String v) {
    if (v.contains(';') || v.contains('"') || v.contains('\n')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }

  /// CSV con separatore ';' (BOM UTF-8 per aprirlo bene in Excel).
  Uint8List csvBytes() {
    final b = StringBuffer(
        'autista;luogo;data_ora_arrivo;data_ora_partenza;intervallo_sosta\r\n');
    for (final s in soste) {
      final par = s.partenza == null ? '' : fmtDt(s.partenza!);
      b.write('${_esc(s.autista)};${_esc(s.luogo)};${fmtDt(s.arrivo)};'
          '$par;${s.intervallo}\r\n');
    }
    return Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(b.toString())]);
  }
}

// ------------------------------------------------------------------ widget comuni
Future<DateTime?> pickDateTime(BuildContext context, DateTime? initial) async {
  final base = initial ?? nowMinute();
  final d = await showDatePicker(
    context: context,
    initialDate: base,
    firstDate: DateTime(2020),
    lastDate: DateTime(2100),
  );
  if (d == null || !context.mounted) return null;
  final t = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(base),
    builder: (c, child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true),
      child: child!,
    ),
  );
  if (t == null) return null;
  return DateTime(d.year, d.month, d.day, t.hour, t.minute);
}

class DateTimeField extends StatelessWidget {
  const DateTimeField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.clearable = false,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool clearable;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.edit_calendar),
              label: Text(value == null ? 'Imposta' : fmtDt(value!)),
              onPressed: () async {
                final r = await pickDateTime(context, value);
                if (r != null) onChanged(r);
              },
            ),
            FilledButton.tonal(
              onPressed: () => onChanged(nowMinute()),
              child: const Text('Adesso'),
            ),
            if (clearable && value != null)
              IconButton(
                icon: const Icon(Icons.clear),
                tooltip: 'Svuota',
                onPressed: () => onChanged(null),
              ),
          ],
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ home
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.store});
  final Store store;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _autista;
  String? _luogo;
  DateTime? _arrivo;
  DateTime? _partenza;

  Store get store => widget.store;

  @override
  void initState() {
    super.initState();
    // L'ultimo autista usato viene proposto in automatico.
    if (store.autisti.contains(store.ultimoAutista)) {
      _autista = store.ultimoAutista;
    }
  }

  String? get _autistaValido => store.autisti.contains(_autista) ? _autista : null;
  String? get _luogoValido => store.luoghi.contains(_luogo) ? _luogo : null;

  void _msg(String t) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t)));
  }

  Widget _selettore({
    required String label,
    required String? valore,
    required List<String> voci,
    required ValueChanged<String> onSel,
  }) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        alignment: Alignment.centerLeft,
      ),
      onPressed: () async {
        if (voci.isEmpty) {
          _msg('Lista vuota: aggiungi voci in "Gestisci liste".');
          return;
        }
        final s = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: Text(label),
            children: [
              for (final v in voci)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, v),
                  child: Text(v),
                ),
            ],
          ),
        );
        if (s != null) onSel(s);
      },
      child: Text(valore == null ? 'Scegli $label' : '$label: $valore'),
    );
  }

  Future<void> _salva() async {
    final a = _autistaValido;
    final l = _luogoValido;
    if (a == null || l == null) {
      _msg('Scegli autista e luogo.');
      return;
    }
    if (_arrivo == null) {
      _msg("L'arrivo è obbligatorio.");
      return;
    }
    if (_partenza != null && _partenza!.isBefore(_arrivo!)) {
      _msg("La partenza è precedente all'arrivo.");
      return;
    }
    await store.addSosta(
        Sosta(autista: a, luogo: l, arrivo: _arrivo!, partenza: _partenza));
    setState(() {
      _arrivo = null;
      _partenza = null;
    });
    _msg('Sosta salvata.');
  }

  Future<void> _registraPartenza(Sosta s) async {
    var p = nowMinute();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Registra partenza'),
          content: DateTimeField(
            label: 'Partenza',
            value: p,
            onChanged: (v) {
              if (v != null) setD(() => p = v);
            },
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Annulla')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Conferma')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (p.isBefore(s.arrivo)) {
      _msg("La partenza è precedente all'arrivo.");
      return;
    }
    await store.chiudi(s, p);
    if (mounted) setState(() {});
  }

  Future<void> _confermaEliminaUltima() async {
    if (store.soste.isEmpty) {
      _msg('Non ci sono record da eliminare.');
      return;
    }
    final ultima = store.soste.last;
    final conferma = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminare l’ultimo record?'),
        content: Text(
          'Vuoi eliminare la sosta di ${ultima.autista} · ${ultima.luogo} '
          'del ${fmtDt(ultima.arrivo)}? L’operazione non può essere annullata.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.deepOrange),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Elimina record'),
          ),
        ],
      ),
    );
    if (conferma != true) return;
    await store.removeLastSosta();
    if (mounted) {
      setState(() {});
      _msg('Ultimo record eliminato.');
    }
  }

  Future<void> _confermaEliminaTutte() async {
    if (store.soste.isEmpty) {
      _msg('Non ci sono soste da eliminare.');
      return;
    }
    final conferma = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminare tutte le soste?'),
        content: const Text(
          'Saranno eliminate tutte le soste aperte e quelle nello storico. '
          'Gli elenchi Autisti e Luoghi resteranno invariati. '
          'L’operazione non può essere annullata.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Elimina tutte'),
          ),
        ],
      ),
    );
    if (conferma != true) return;
    await store.clearSoste();
    if (mounted) {
      setState(() {});
      _msg('Tutte le soste sono state eliminate.');
    }
  }

  Future<void> _esporta() async {
    if (store.soste.isEmpty) {
      _msg('Non ci sono ancora soste da esportare.');
      return;
    }
    final scelta = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('Salva file'),
              subtitle: const Text('Scegli la cartella (es. Download)'),
              onTap: () => Navigator.pop(ctx, 'salva'),
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('Condividi'),
              subtitle: const Text('WhatsApp, email, Drive...'),
              onTap: () => Navigator.pop(ctx, 'condividi'),
            ),
          ],
        ),
      ),
    );
    if (scelta == null) return;

    final n = DateTime.now();
    final nome = 'report_soste_${n.year}${two(n.month)}${two(n.day)}_'
        '${two(n.hour)}${two(n.minute)}.csv';
    final bytes = store.csvBytes();
    try {
      if (scelta == 'salva') {
        final path = await FilePicker.platform.saveFile(
          dialogTitle: 'Salva report',
          fileName: nome,
          bytes: bytes,
        );
        if (path != null) _msg('File salvato.');
      } else {
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/$nome');
        await f.writeAsBytes(bytes);
        await Share.shareXFiles([XFile(f.path, mimeType: 'text/csv')],
            subject: nome);
      }
    } catch (e) {
      _msg('Errore: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final aperte = store.soste.where((s) => s.partenza == null).toList();
    final titolo = Theme.of(context).textTheme.titleLarge;
    return Scaffold(
      appBar: AppBar(title: const Text('Soste Autisti')),
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              const DrawerHeader(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Text(
                    'Soste Autisti',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('Storico'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context)
                      .push(MaterialPageRoute(
                          builder: (_) => StoricoPage(store: store)))
                      .then((_) {
                    if (mounted) setState(() {});
                  });
                },
              ),
              ListTile(
                leading: const Icon(Icons.list_alt),
                title: const Text('Gestisci liste'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context)
                      .push(MaterialPageRoute(
                          builder: (_) => ListePage(store: store)))
                      .then((_) {
                    if (mounted) setState(() {});
                  });
                },
              ),
              ListTile(
                leading: const Icon(Icons.file_download),
                title: const Text('Esporta CSV'),
                onTap: () {
                  Navigator.pop(context);
                  _esporta();
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.deepOrange),
                title: const Text(
                  'Elimina ultimo record',
                  style: TextStyle(color: Colors.deepOrange),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _confermaEliminaUltima();
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text(
                  'Elimina tutti i dati',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _confermaEliminaTutte();
                },
              ),
            ],
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Registra sosta', style: titolo),
          const SizedBox(height: 12),
          _selettore(
            label: 'Autista',
            valore: _autistaValido,
            voci: store.autisti,
            onSel: (v) => setState(() => _autista = v),
          ),
          const SizedBox(height: 8),
          _selettore(
            label: 'Luogo',
            valore: _luogoValido,
            voci: store.luoghi,
            onSel: (v) => setState(() => _luogo = v),
          ),
          const SizedBox(height: 16),
          DateTimeField(
            label: 'Arrivo',
            value: _arrivo,
            onChanged: (v) => setState(() => _arrivo = v),
          ),
          const SizedBox(height: 12),
          DateTimeField(
            label: 'Partenza (opzionale)',
            value: _partenza,
            clearable: true,
            onChanged: (v) => setState(() => _partenza = v),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _salva, child: const Text('Salva')),
          const Divider(height: 32),
          Text('Soste aperte', style: titolo),
          const SizedBox(height: 8),
          if (aperte.isEmpty) const Text('Nessuna sosta aperta.'),
          for (final s in aperte)
            Card(
              child: ListTile(
                title: Text('${s.autista} · ${s.luogo}'),
                subtitle: Text('Arrivo: ${fmtDt(s.arrivo)}'),
                trailing: FilledButton.tonal(
                  onPressed: () => _registraPartenza(s),
                  child: const Text('Partenza'),
                ),
              ),
            ),
          const Divider(height: 32),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ storico
class StoricoPage extends StatelessWidget {
  const StoricoPage({super.key, required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) {
    final soste = store.soste.reversed.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Storico')),
      body: soste.isEmpty
          ? const Center(child: Text('Nessuna sosta registrata.'))
          : ListView.builder(
              itemCount: soste.length,
              itemBuilder: (_, i) {
                final s = soste[i];
                final par =
                    s.partenza == null ? 'in corso' : fmtDt(s.partenza!);
                final sosta = s.intervallo.isEmpty ? '-' : s.intervallo;
                return ListTile(
                  title: Text('${s.autista} · ${s.luogo}'),
                  subtitle: Text('${fmtDt(s.arrivo)} → $par\nSosta: $sosta'),
                  isThreeLine: true,
                );
              },
            ),
    );
  }
}

// ------------------------------------------------------------------ liste
class ListePage extends StatefulWidget {
  const ListePage({super.key, required this.store});
  final Store store;

  @override
  State<ListePage> createState() => _ListePageState();
}

class _ListePageState extends State<ListePage> {
  final _cAutista = TextEditingController();
  final _cLuogo = TextEditingController();

  @override
  void dispose() {
    _cAutista.dispose();
    _cLuogo.dispose();
    super.dispose();
  }

  List<Widget> _sezione(
    String kind,
    String titolo,
    TextEditingController c,
    List<String> voci,
  ) {
    return [
      Text(titolo, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: c,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nuovo elemento'),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () async {
              await widget.store.addItem(kind, c.text);
              c.clear();
              setState(() {});
            },
            child: const Text('Aggiungi'),
          ),
        ],
      ),
      for (final v in voci)
        ListTile(
          dense: true,
          title: Text(v),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await widget.store.removeItem(kind, v);
              setState(() {});
            },
          ),
        ),
      const SizedBox(height: 24),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gestisci liste')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ..._sezione('autisti', 'Autisti', _cAutista, widget.store.autisti),
          ..._sezione('luoghi', 'Luoghi', _cLuogo, widget.store.luoghi),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ app
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await Store.load();
  runApp(SosteApp(store: store));
}

class SosteApp extends StatelessWidget {
  const SosteApp({super.key, required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Soste Autisti',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      locale: const Locale('it', 'IT'),
      supportedLocales: const [Locale('it', 'IT')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: HomePage(store: store),
    );
  }
}
