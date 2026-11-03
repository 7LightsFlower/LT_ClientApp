// language_names.dart
//
// Language code -> name table (copied from the subtitles project's
// assets/languages.json) and a resolver that turns the labels the KIT
// server uses into readable names. Pure Dart: no dart:html, no assets,
// works on web, Android, iOS and desktop.

/// ISO code -> English name.
const Map<String, String> languageNamesByCode = {
  'af': 'Afrikaans',
  'am': 'Amharic',
  'ar': 'Arabic',
  'as': 'Assamese',
  'az': 'Azerbaijani',
  'ba': 'Bashkir',
  'be': 'Belarusian',
  'bg': 'Bulgarian',
  'bn': 'Bangla',
  'bo': 'Tibetan',
  'br': 'Breton',
  'bs': 'Bosnian',
  'ca': 'Catalan',
  'cs': 'Czech',
  'cy': 'Welsh',
  'da': 'Danish',
  'de': 'German',
  'el': 'Greek',
  'en': 'English',
  'es': 'Spanish',
  'et': 'Estonian',
  'eu': 'Basque',
  'fa': 'Persian',
  'fi': 'Finnish',
  'fo': 'Faroese',
  'fr': 'French',
  'gl': 'Galician',
  'gu': 'Gujarati',
  'ha': 'Hausa',
  'haw': 'Hawaiian',
  'he': 'Hebrew',
  'hi': 'Hindi',
  'hr': 'Croatian',
  'ht': 'Haitian Creole',
  'hu': 'Hungarian',
  'hy': 'Armenian',
  'id': 'Indonesian',
  'is': 'Icelandic',
  'it': 'Italian',
  'ja': 'Japanese',
  'jw': 'Javanese',
  'ka': 'Georgian',
  'kk': 'Kazakh',
  'km': 'Khmer',
  'kn': 'Kannada',
  'ko': 'Korean',
  'la': 'Latin',
  'lb': 'Luxembourgish',
  'ln': 'Lingala',
  'lo': 'Lao',
  'lt': 'Lithuanian',
  'lv': 'Latvian',
  'mg': 'Malagasy',
  'mi': 'Māori',
  'mk': 'Macedonian',
  'ml': 'Malayalam',
  'mn': 'Mongolian',
  'mr': 'Marathi',
  'ms': 'Malay',
  'mt': 'Maltese',
  'my': 'Burmese',
  'ne': 'Nepali',
  'nl': 'Dutch',
  'nn': 'Norwegian Nynorsk',
  'no': 'Norwegian',
  'oc': 'Occitan',
  'pa': 'Punjabi',
  'pl': 'Polish',
  'ps': 'Pashto',
  'pt': 'Portuguese',
  'ro': 'Romanian',
  'ru': 'Russian',
  'sa': 'Sanskrit',
  'sd': 'Sindhi',
  'si': 'Sinhala',
  'sk': 'Slovak',
  'sl': 'Slovenian',
  'sn': 'Shona',
  'so': 'Somali',
  'sq': 'Albanian',
  'sr': 'Serbian',
  'su': 'Sundanese',
  'sv': 'Swedish',
  'sw': 'Swahili',
  'ta': 'Tamil',
  'te': 'Telugu',
  'tg': 'Tajik',
  'th': 'Thai',
  'tk': 'Turkmen',
  'tl': 'Filipino',
  'tr': 'Turkish',
  'tt': 'Tatar',
  'uk': 'Ukrainian',
  'ur': 'Urdu',
  'uz': 'Uzbek',
  'vi': 'Vietnamese',
  'yi': 'Yiddish',
  'yo': 'Yoruba',
  'yue': 'Cantonese',
  'zh': 'Chinese',
  'zh_tw': 'Chinese (Taiwan)',
};

final Map<String, String> _codesByLowerName = {
  for (final e in languageNamesByCode.entries) e.value.toLowerCase(): e.key,
};

/// Resolves any language label to a readable name; returns [raw] unchanged
/// when nothing matches.
///
///   "de"                         -> "German"
///   "German"                     -> "German"
///   "Translation (Language de)"  -> "German"
///   "Original ASR (English)"     -> "Transcript"
///   "textstructurer:0_de"        -> "German"
///   "summarizer:0_ru"            -> "Russian"
///   "mt:1"                       -> "mt:1"   (no code in it – see below)
///
/// Numbered senders like "mt:1" carry no language; map those first with the
/// session page's data, then pass the result through this function.
String resolveLanguageName(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return trimmed;
  final lower = trimmed.toLowerCase();

  if (lower.contains('original asr') || lower.startsWith('transcript')) {
    return 'Transcript';
  }

  // 1. Bare code or bare full name.
  final direct = languageNamesByCode[lower];
  if (direct != null) return direct;
  if (_codesByLowerName.containsKey(lower)) return trimmed;

  // 2. Whatever is inside parentheses.
  final paren = RegExp(r'\(([^)]+)\)').firstMatch(trimmed);
  if (paren != null) {
    var candidate = paren.group(1)!.trim();
    if (candidate.toLowerCase().startsWith('language ')) {
      candidate = candidate.substring('language '.length).trim();
    }
    final candLower = candidate.toLowerCase();
    final byCode = languageNamesByCode[candLower];
    if (byCode != null) return byCode;
    if (_codesByLowerName.containsKey(candLower)) return candidate;
  }

  // 3. A 2–3 letter code after a separator: "asr:de", "x_en", "0_zh_tw".
  for (final m in RegExp(r'[\s:\-_]([a-zA-Z]{2,3}(?:_tw)?)(?![a-zA-Z])')
      .allMatches(trimmed)) {
    final name = languageNamesByCode[m.group(1)!.toLowerCase()];
    if (name != null) return name;
  }

  // 4. A full language name anywhere in the label (whole words only, so
  //    e.g. "Malay" doesn't match inside "Malayalam").
  for (final entry in _codesByLowerName.entries) {
    if (RegExp('\\b${RegExp.escape(entry.key)}\\b').hasMatch(lower)) {
      return languageNamesByCode[entry.value]!;
    }
  }

  return trimmed;
}
