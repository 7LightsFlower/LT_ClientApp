import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asr_live_translator/screens/session_selection_screen.dart';
import 'package:asr_live_translator/theme_controller.dart';

// These tests avoid Firebase and platform plugins so they run with a plain
// `flutter test` on any machine.
void main() {
  group('SessionHistoryItem', () {
    test('round-trips through JSON', () {
      final item = SessionHistoryItem(
        url: 'https://example.com/s/abc',
        name: 'Lecture 1',
        firstConnected: DateTime(2026, 10, 1, 9, 0),
        lastConnected: DateTime(2026, 10, 1, 10, 30),
        sessionId: 'session123',
        languageMap: {'English': '0', 'German': '1'},
      );

      final parsed = SessionHistoryItem.tryParse(jsonEncode(item.toJson()))!;

      expect(parsed.url, item.url);
      expect(parsed.name, 'Lecture 1');
      expect(parsed.firstConnected, item.firstConnected);
      expect(parsed.lastConnected, item.lastConnected);
      expect(parsed.sessionId, 'session123');
      expect(parsed.languageMap, {'English': '0', 'German': '1'});
    });

    test('parses legacy entries written by the QR scanner', () {
      final legacy = jsonEncode({
        'url': 'https://example.com/s/xyz',
        'lastConnected': DateTime(2026, 9, 15, 14, 5).toIso8601String(),
      });

      final parsed = SessionHistoryItem.tryParse(legacy)!;

      expect(parsed.url, 'https://example.com/s/xyz');
      expect(parsed.name, '2026-09-15 14:05');
      expect(parsed.firstConnected, parsed.lastConnected);
      expect(parsed.sessionId, isNull);
    });

    test('parses very old plain-string entries', () {
      final parsed = SessionHistoryItem.tryParse('  https://example.com/old  ')!;
      expect(parsed.url, 'https://example.com/old');
    });

    test('returns null for empty input', () {
      expect(SessionHistoryItem.tryParse('   '), isNull);
    });
  });

  group('themeModeFromString', () {
    test('maps stored values to ThemeMode', () {
      expect(themeModeFromString('light'), ThemeMode.light);
      expect(themeModeFromString('dark'), ThemeMode.dark);
      expect(themeModeFromString('system'), ThemeMode.system);
      expect(themeModeFromString(null), ThemeMode.system);
    });
  });
}
