/// Begrenztes, kopierbares Wiedergabeprotokoll. Adressen und Schlüssel werden entfernt.
class PlayLog {
  PlayLog({this.max = 400, List<String>? initial, this.persist}) : lines = List.of(initial ?? const []) {
    _trim();
  }

  final int max;
  final List<String> lines;
  final void Function(List<String>)? persist;
  int _pending = 0;

  static final _url = RegExp(r'https?://\S+');
  static final _key = RegExp(r'([?&#](k|key|token|sig|signature)=)[^\s&]+', caseSensitive: false);

  static String sanitize(String s) =>
      s.replaceAll(_url, '[Adresse]').replaceAllMapped(_key, (m) => '${m.group(1)}[…]');

  void add(String msg) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    lines.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)} ${sanitize(msg)}');
    _trim();
    // Gebündelt speichern
    if (++_pending >= 10) flush();
  }

  void flush() {
    if (_pending == 0) return;
    _pending = 0;
    try {
      persist?.call(List.of(lines));
    } catch (_) {}
  }

  void clear() {
    lines.clear();
    _pending = 1;
    flush();
  }

  void _trim() {
    if (lines.length > max) lines.removeRange(0, lines.length - max);
  }

  String get text => lines.join('\n');
}
