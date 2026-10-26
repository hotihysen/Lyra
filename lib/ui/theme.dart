import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class Accent {
  final String name;
  final Color color;
  final Color color2;
  const Accent(this.name, this.color, this.color2);
  LinearGradient get gradient =>
      LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [color, color2]);
}

const accents = <Accent>[
  Accent('Aurora', Color(0xFFA78BFA), Color(0xFFEC4899)),
  Accent('Koralle', Color(0xFFFF7A59), Color(0xFFFFB347)),
  Accent('Ozean', Color(0xFF60A5FA), Color(0xFF22D3EE)),
  Accent('Mint', Color(0xFF34D399), Color(0xFFA3E635)),
  Accent('Gold', Color(0xFFF5C451), Color(0xFFF08A3E)),
  Accent('Rosé', Color(0xFFF9A8D4), Color(0xFFC084FC)),
];

const kBg = Color(0xFF0E0E10);
const kSurface = Color(0xFF18181C);
const kSurface2 = Color(0xFF26262C);
const kMuted = Color(0xFFA7A7AE);

ThemeData buildTheme(Accent a) {
  final scheme = ColorScheme.fromSeed(seedColor: a.color, brightness: Brightness.dark).copyWith(
    primary: a.color,
    secondary: a.color2,
    onPrimary: Colors.black,
    surface: kBg,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBg,
    canvasColor: kBg,
  );
  return base.copyWith(
    textTheme: GoogleFonts.figtreeTextTheme(base.textTheme).apply(bodyColor: Colors.white, displayColor: Colors.white),
    appBarTheme: const AppBarTheme(
      backgroundColor: kBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 3,
      activeTrackColor: Colors.white,
      inactiveTrackColor: Colors.white24,
      thumbColor: Colors.white,
      overlayColor: Colors.white12,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: kSurface, surfaceTintColor: Colors.transparent),
    dialogTheme: const DialogThemeData(backgroundColor: kSurface2, surfaceTintColor: Colors.transparent),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: kSurface2,
      contentTextStyle: TextStyle(color: Colors.white),
    ),
    listTileTheme: const ListTileThemeData(iconColor: Colors.white),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: a.color),
  );
}

String fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

String fmtSeconds(int s) => fmtDuration(Duration(seconds: s));

String fmtLong(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h > 0) return '$h Std. $m Min.';
  return '$m Min.';
}

String fmtFans(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1).replaceAll('.', ',')} Mio.';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)}k';
  return '$n';
}
