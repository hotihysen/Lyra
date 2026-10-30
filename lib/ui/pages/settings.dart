import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/server.dart';

import '../../data/store.dart';
import '../../data/updater.dart';
import '../update_ui.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import 'player.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Text(t, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(title: const Text('Einstellungen', style: TextStyle(fontWeight: FontWeight.w800))),
      body: storeBuilder((context, s) {
        final accent = Theme.of(context).colorScheme.primary;
        final mb = (s.downloadsBytes() / (1024 * 1024)).toStringAsFixed(0);
        return ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            _h('App'),
            if (!Platform.isAndroid) ...[
              ListTile(
                title: Text('Lyra ${Updater.version}'),
                subtitle: ValueListenableBuilder<UpdateInfo?>(
                  valueListenable: Updater.available,
                  builder: (c, u, _) => Text(
                      u == null ? 'Tippe, um nach Updates zu suchen (Installation über SideStore)' : 'Update auf ${u.version} in SideStore verfügbar',
                      style: TextStyle(color: u == null ? kMuted : accent)),
                ),
                trailing: const Icon(Icons.system_update_rounded),
                onTap: () => checkForUpdate(context),
              ),
              SwitchListTile(
                title: const Text('Beim Start nach Updates suchen'),
                subtitle: const Text('Zeigt einen Hinweis, wenn in SideStore eine neue Version bereitliegt',
                    style: TextStyle(color: kMuted)),
                value: s.autoUpdate,
                activeColor: accent,
                onChanged: s.setAutoUpdate,
              ),
            ],
            if (Platform.isAndroid) ...[
            ListTile(
              title: Text('Lyra ${Updater.version}'),
              subtitle: ValueListenableBuilder<UpdateInfo?>(
                valueListenable: Updater.available,
                builder: (c, u, _) => Text(u == null ? 'Tippe, um nach Updates zu suchen' : 'Update auf ${u.version} verfügbar',
                    style: TextStyle(color: u == null ? kMuted : accent)),
              ),
              trailing: const Icon(Icons.system_update_rounded),
              onTap: () => checkForUpdate(context),
            ),
            SwitchListTile(
              title: const Text('Beim Start nach Updates suchen'),
              subtitle: const Text('Fragt nach, bevor ein Update geladen wird', style: TextStyle(color: kMuted)),
              value: s.autoUpdate,
              activeColor: accent,
              onChanged: s.setAutoUpdate,
            ),
            ListTile(
              title: const Text('Update-Test'),
              subtitle: const Text('Update-Logik ausprobieren, auch ohne neue Version', style: TextStyle(color: kMuted)),
              trailing: const Icon(Icons.science_outlined),
              onTap: () => openPage(const UpdateTestPage()),
            ),
            ],
            ListTile(
              title: const Text('Eigener Server'),
              subtitle: Text(
                  LyraServer.configured
                      ? LyraServer.current!.base.host
                      : Platform.isAndroid
                          ? 'Optional, als Reserve für die Wiedergabe'
                          : 'Nötig für Wiedergabe und Downloads',
                  style: TextStyle(color: LyraServer.configured ? kMuted : accent)),
              trailing: const Icon(Icons.dns_outlined),
              onTap: () => showServerDialog(context),
            ),
            ListTile(
              title: const Text('Wiedergabe-Diagnose'),
              subtitle: const Text('Prüft, ob YouTube-Audio auf diesem Gerät abrufbar ist', style: TextStyle(color: kMuted)),
              trailing: const Icon(Icons.troubleshoot_rounded),
              onTap: () => openPage(const DiagnosePage()),
            ),
            _h('Design'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 12,
                children: [
                  for (var i = 0; i < accents.length; i++)
                    GestureDetector(
                      onTap: () => s.setAccent(i),
                      child: SizedBox(
                        width: 72,
                        child: Column(
                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                gradient: accents[i].gradient,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: s.accentIndex.value == i ? Colors.white : Colors.transparent,
                                  width: 3,
                                ),
                              ),
                              child: s.accentIndex.value == i
                                  ? const Icon(Icons.check_rounded, color: Colors.white)
                                  : null,
                            ),
                            const SizedBox(height: 6),
                            Text(accents[i].name, style: const TextStyle(fontSize: 12.5)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            _h('Wiedergabe'),
            ListTile(
              title: const Text('Crossfade'),
              subtitle: Text(s.crossfade == 0 ? 'Aus' : '${s.crossfade} Sekunden Überblendung zwischen Songs',
                  style: const TextStyle(color: kMuted)),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: accent,
                thumbColor: accent,
                overlayColor: accent.withValues(alpha: 0.15),
              ),
              child: Slider(
                value: s.crossfade.toDouble(),
                min: 0,
                max: 12,
                divisions: 12,
                label: s.crossfade == 0 ? 'Aus' : '${s.crossfade} s',
                onChanged: (v) => s.setCrossfade(v.round()),
              ),
            ),
            ListTile(
              title: const Text('Wiedergabegeschwindigkeit'),
              subtitle: const Text('Vor allem für Hörbücher', style: TextStyle(color: kMuted)),
              trailing: const Icon(Icons.speed_rounded),
              onTap: () => showSpeedSheet(context),
            ),
            ListTile(
              title: const Text('Sleep-Timer'),
              trailing: const Icon(Icons.bedtime_outlined),
              onTap: () => showSleepSheet(context),
            ),
            _h('Speicher'),
            ListTile(
              title: const Text('Downloads'),
              subtitle: Text('${s.downloads.length} Dateien · $mb MB', style: const TextStyle(color: kMuted)),
              trailing: TextButton(
                onPressed: s.downloads.isEmpty
                    ? null
                    : () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('Alle Downloads löschen?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
                              TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Löschen')),
                            ],
                          ),
                        );
                        if (ok == true) s.clearDownloads();
                      },
                child: const Text('Alle löschen'),
              ),
            ),
            ListTile(
              title: const Text('Song-Zuordnungen zurücksetzen'),
              subtitle: Text('${s.ytIds.length} gespeichert · hilft, wenn ein Song falsch erkannt wurde',
                  style: const TextStyle(color: kMuted)),
              trailing: const Icon(Icons.restart_alt_rounded),
              onTap: () {
                s.clearYt();
                toast(context, 'Zuordnungen zurückgesetzt');
              },
            ),
            _h('Über Lyra'),
            const ListTile(
              title: Text('Lyra'),
              subtitle: Text(
                'Privates Lernprojekt.\nKatalog und Wiedergabe: YouTube Music · Songtexte: LRCLIB · Hörbücher: LibriVox (gemeinfrei)',
                style: TextStyle(color: kMuted, height: 1.4),
              ),
            ),
          ],
        );
      }),
    );
  }
}

/// Server-Link einfügen, testen und speichern.
Future<void> showServerDialog(BuildContext context) async {
  final ctrl = TextEditingController(text: Store.instance.serverLink ?? '');
  String? status;
  var busy = false;
  await showDialog(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: const Text('Eigener Server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Server-Link einfügen, den du erhalten hast:', style: TextStyle(color: kMuted)),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                hintText: 'https://lyra.beispiel.ch/?k=…',
                suffixIcon: IconButton(
                  tooltip: 'Einfügen',
                  icon: const Icon(Icons.content_paste_rounded),
                  onPressed: () async {
                    final d = await Clipboard.getData('text/plain');
                    if (d?.text != null) ctrl.text = d!.text!.trim();
                  },
                ),
              ),
            ),
            if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
            if (status != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(status!)),
          ],
        ),
        actions: [
          if (Store.instance.serverLink != null)
            TextButton(
              onPressed: () {
                Store.instance.setServerLink(null);
                Navigator.pop(c);
              },
              child: const Text('Entfernen'),
            ),
          TextButton(
            onPressed: busy
                ? null
                : () async {
                    set(() => busy = true);
                    final r = await LyraServer.test(ctrl.text);
                    set(() {
                      busy = false;
                      status = r;
                    });
                  },
            child: const Text('Testen'),
          ),
          FilledButton(
            onPressed: () {
              if (LyraServer.parse(ctrl.text) == null) {
                set(() => status = 'Kein gültiger Server-Link (Format: https://adresse/?k=SCHLÜSSEL)');
                return;
              }
              Store.instance.setServerLink(ctrl.text);
              Navigator.pop(c);
            },
            child: const Text('Speichern'),
          ),
        ],
      ),
    ),
  );
}
