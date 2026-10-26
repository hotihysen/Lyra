import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/youtube.dart';
import '../data/updater.dart';
import 'theme.dart';
import 'widgets.dart';

bool _dialogShown = false;

/// Einmal pro App-Start: Hinweis, wenn eine neue Version bereitliegt.
Future<void> showUpdateDialogOnce(BuildContext context, UpdateInfo info) async {
  if (_dialogShown) return;
  _dialogShown = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Neue Version verfügbar'),
      content: Text('Lyra ${info.version} ist bereit (du hast ${Updater.version}).'
          '${info.size > 0 ? '\nGrösse: ${(info.size / 1048576).toStringAsFixed(0)} MB' : ''}'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Später')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Aktualisieren')),
      ],
    ),
  );
  if (ok == true && context.mounted) await runUpdate(context, info);
}

/// Lädt die APK mit Fortschrittsanzeige und öffnet den Installer.
Future<void> runUpdate(BuildContext context, UpdateInfo info, {InstallMode mode = InstallMode.auto}) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      title: Text('Lyra ${info.version} wird geladen'),
      content: ValueListenableBuilder<double?>(
        valueListenable: Updater.progress,
        builder: (c, p, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: p),
            const SizedBox(height: 10),
            Text(p == null ? 'Vorbereiten …' : '${(p * 100).round()} %', style: const TextStyle(color: kMuted)),
          ],
        ),
      ),
    ),
  );
  try {
    await Updater.install(info, mode: mode);
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  } catch (e) {
    Updater.log.value = [...Updater.log.value, 'FEHLER: ${e is PlatformException ? (e.message ?? e.code) : e.toString().replaceFirst('Exception: ', '')}'];
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    final msg = e is PlatformException ? (e.message ?? e.code) : e.toString().replaceFirst('Exception: ', '');
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Update nicht möglich'),
        content: Text(msg),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
  }
}

/// Manuelle Prüfung aus den Einstellungen.
Future<void> checkForUpdate(BuildContext context) async {
  toast(context, 'Suche nach Updates …');
  try {
    final info = await Updater.check();
    if (!context.mounted) return;
    if (info == null) {
      toast(context, 'Lyra ist aktuell (${Updater.version})');
    } else {
      _dialogShown = false;
      await showUpdateDialogOnce(context, info);
    }
  } catch (e) {
    if (context.mounted) toast(context, e.toString().replaceFirst('Exception: ', ''));
  }
}

/// Testet auf diesem Gerät, welche YouTube-Abrufwege funktionieren.
class DiagnosePage extends StatefulWidget {
  const DiagnosePage({super.key});
  @override
  State<DiagnosePage> createState() => _DiagnosePageState();
}

class _DiagnosePageState extends State<DiagnosePage> {
  final _lines = <String>[];
  bool _running = false;

  Future<void> _run() async {
    setState(() {
      _lines.clear();
      _running = true;
    });
    _lines.add('Lyra ${Updater.version}');
    await YT.diagnose((l) {
      if (mounted) setState(() => _lines.add(l));
    });
    if (YT.lastError.isNotEmpty) {
      _lines.add('');
      _lines.add('Letzter Wiedergabefehler:');
      _lines.addAll(YT.lastError.split('\n'));
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: const Text('Wiedergabe-Diagnose', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          if (_lines.isNotEmpty && !_running)
            IconButton(
              icon: const Icon(Icons.copy_rounded),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _lines.join('\n')));
                toast(context, 'Kopiert');
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Prüft, welche Abrufwege YouTube auf deinem Gerät und in deinem Netz zulässt. '
            'Dauert etwa eine Minute. Danach kannst du das Ergebnis kopieren.',
            style: TextStyle(color: kMuted, height: 1.4),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow_rounded),
            label: Text(_running ? 'Läuft …' : 'Diagnose starten'),
          ),
          const SizedBox(height: 20),
          for (final l in _lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: SelectableText(
                l,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  color: l.contains('FEHLER') ? const Color(0xFFFF8A80) : (l.contains('ok') ? const Color(0xFFB9F6CA) : Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}


/// Testseite: Update-Logik jederzeit ausprobieren, Schritt für Schritt protokolliert.
class UpdateTestPage extends StatefulWidget {
  const UpdateTestPage({super.key});
  @override
  State<UpdateTestPage> createState() => _UpdateTestPageState();
}

class _UpdateTestPageState extends State<UpdateTestPage> {
  UpdateInfo? _latest;
  String? _error;
  bool _loading = true;
  InstallMode _mode = InstallMode.auto;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final l = await Updater.fetchLatest();
      if (mounted) setState(() => _latest = l);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final l = _latest;
    final newer = l != null && l.build > Updater.build;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: const Text('Update-Test', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_rounded),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: Updater.log.value.join('\n')));
              toast(context, 'Protokoll kopiert');
            },
          ),
          IconButton(icon: const Icon(Icons.delete_outline_rounded), onPressed: Updater.clearLog),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _row('Installiert', Updater.version),
          _row('Neuestes Release', _loading ? 'wird geladen …' : (l?.version ?? '–')),
          if (_error != null) _row('Fehler', _error!),
          if (l != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 12),
              child: Text(
                newer ? 'Ein neueres Release ist verfügbar: echtes Update.' : 'Du bist aktuell: die gleiche Version wird neu installiert (zum Testen).',
                style: TextStyle(color: newer ? accent : kMuted),
              ),
            ),
          const SizedBox(height: 8),
          const Text('Installationsweg', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          for (final m in InstallMode.values)
            RadioListTile<InstallMode>(
              value: m,
              groupValue: _mode,
              activeColor: accent,
              contentPadding: EdgeInsets.zero,
              title: Text(m.label),
              subtitle: Text(
                switch (m) {
                  InstallMode.auto => 'Sitzung, nach 10 s ohne Dialog klassischer Installer',
                  InstallMode.session => 'Nur Installationssitzung, ab dem 2. Mal ohne Rückfrage',
                  InstallMode.classic => 'Android-Dialog «App aktualisieren» direkt',
                },
                style: const TextStyle(color: kMuted, fontSize: 12.5),
              ),
              onChanged: (v) => setState(() => _mode = v!),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: l == null ? null : () => runUpdate(context, l, mode: _mode),
                  icon: const Icon(Icons.system_update_rounded),
                  label: Text(newer ? 'Update installieren' : 'Erneut installieren'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh_rounded)),
            ],
          ),
          const SizedBox(height: 20),
          const Text('Protokoll', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 8),
          ValueListenableBuilder<List<String>>(
            valueListenable: Updater.log,
            builder: (c, lines, _) => lines.isEmpty
                ? const Text('Noch keine Einträge.', style: TextStyle(color: kMuted))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final line in lines)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: SelectableText(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 140, child: Text(k, style: const TextStyle(color: kMuted))),
            Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600))),
          ],
        ),
      );
}
