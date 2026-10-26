import 'package:flutter/material.dart';

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
                'Privates Lernprojekt.\nKatalog: Deezer · Wiedergabe: YouTube · Songtexte: LRCLIB · Hörbücher: LibriVox (gemeinfrei)',
                style: TextStyle(color: kMuted, height: 1.4),
              ),
            ),
          ],
        );
      }),
    );
  }
}
