import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'audio/handler.dart';
import 'data/store.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

late final LyraAudioHandler audio;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Store.instance.init();
  audio = await AudioService.init(
    builder: () => LyraAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'ch.hysen.lyra.playback',
      androidNotificationChannelName: 'Wiedergabe',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidNotificationIcon: 'drawable/ic_stat_lyra',
    ),
  );
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF000000),
  ));
  runApp(const LyraApp());
}

class LyraApp extends StatelessWidget {
  const LyraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: Store.instance.accentIndex,
      builder: (context, i, _) => MaterialApp(
        title: 'Lyra',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(accents[i.clamp(0, accents.length - 1)]),
        home: Shell(key: shellKey),
      ),
    );
  }
}
