import 'package:flutter_test/flutter_test.dart';

import 'package:live_translator_viewer/cookie_utils.dart';

void main() {
  group('parseSetCookieHeader', () {
    test('keeps only name=value pairs and drops attributes', () {
      expect(
        parseSetCookieHeader('session=abc123; Path=/; HttpOnly; Secure'),
        {'session': 'abc123'},
      );
    });

    test('splits multiple cookies joined by package:http', () {
      const header = 'session=abc; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT; HttpOnly, '
          'lang=de; Path=/, csrftoken=xyz; SameSite=Lax';
      expect(parseSetCookieHeader(header), {
        'session': 'abc',
        'lang': 'de',
        'csrftoken': 'xyz',
      });
    });

    test('handles empty input', () {
      expect(parseSetCookieHeader(null), isEmpty);
      expect(parseSetCookieHeader(''), isEmpty);
    });
  });

  group('mergeCookieHeaders', () {
    test('newer values win and others are kept', () {
      expect(
        mergeCookieHeaders('a=1; b=2', {'b': '3', 'c': '4'}),
        'a=1; b=3; c=4',
      );
    });

    test('works without existing cookies', () {
      expect(mergeCookieHeaders(null, {'a': '1'}), 'a=1');
    });
  });

  group('normalizeJsStringResult', () {
    test('unwraps Android JSON-quoted strings', () {
      expect(normalizeJsStringResult('"a=1; b=2"'), 'a=1; b=2');
    });

    test('keeps iOS plain strings', () {
      expect(normalizeJsStringResult('a=1; b=2'), 'a=1; b=2');
    });

    test('treats null and empty results as empty', () {
      expect(normalizeJsStringResult(null), '');
      expect(normalizeJsStringResult('null'), '');
      expect(normalizeJsStringResult('""'), '');
    });
  });
}
