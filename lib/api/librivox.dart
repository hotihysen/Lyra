import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/models.dart';

/// Gemeinfreie Hörbücher von LibriVox.
class LibriVox {
  static Future<List<Book>> search(String q) => _fetch({'title': q});

  static Future<List<Book>> byAuthor(String lastName) => _fetch({'author': lastName});

  static Future<List<Book>> recent() {
    final since = DateTime.now().subtract(const Duration(days: 150)).millisecondsSinceEpoch ~/ 1000;
    return _fetch({'since': '$since'});
  }

  static Future<List<Book>> _fetch(Map<String, String> params) async {
    final uri = Uri.https('librivox.org', '/api/feed/audiobooks/', {
      ...params,
      'format': 'json',
      'extended': '1',
      'limit': '30',
    });
    final r = await http.get(uri).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) return const [];
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map || j['books'] is! List) return const [];
    return (j['books'] as List)
        .map((b) => Book.fromLibriVox(b as Map))
        .where((b) => b.chapters.isNotEmpty)
        .toList();
  }
}
