// live_document.dart
//
// Builds the "Session Output" layout of the GetAllSubtitled backend
// (lib/backend/transcript_export.py → build_blocks) on the fly, from the
// messages of a running KIT session:
//
//     Global summary (once, at the top)
//     Heading
//     Speaker
//     Running text, one paragraph per speaker / paragraph break …
//         Summary: …            (chapter summaries where they occur)
//
// Everything is kept per language. KIT sends the structure separately from
// the text: headings / paragraph breaks come from "textstructurer:…_<lang>",
// summaries from "summarizer:…_<lang>", each with a start time. Sorting all
// items of a language by start time puts every heading, break and summary at
// the right place, even though they arrive later than the text they belong to.

/// One piece of a language's document: a text segment or a structure marker.
class LiveItem {
  LiveItem({
    required this.start,
    required this.kind,
    required this.text,
    required this.order,
    this.unstable = false,
    this.speaker,
  });

  /// Start time in KIT's clock (seconds). Decides the position.
  final double start;

  /// 'text' for transcript/translation segments, otherwise KIT's markup:
  /// 'heading', 'paragraphBreak', 'summary', 'global_summary', 'notes',
  /// 'postedited', 'chapterBreak' …
  final String kind;
  final String text;

  /// Arrival order – keeps items with the same start time in sequence.
  final int order;

  /// Still being recognised; shown greyed, left out of exports.
  final bool unstable;
  final String? speaker;
}

/// One block of the rendered document.
class DocBlock {
  const DocBlock(this.kind, this.text, {this.pending = ''});

  /// 'heading', 'speaker', 'para', 'summary', 'notes' or 'postedited'.
  final String kind;

  /// Final text.
  final String text;

  /// Unstable text at the end of a paragraph (live view only).
  final String pending;
}

class DocContent {
  const DocContent(this.globalSummaries, this.blocks);
  final List<String> globalSummaries;
  final List<DocBlock> blocks;
  bool get isEmpty => globalSummaries.isEmpty && blocks.isEmpty;
}

class LiveDocument {
  final Map<String, Map<String, LiveItem>> _items = {};
  int _order = 0;
  double? _firstStart;
  double? _lastEnd;

  /// When the first message of this session arrived (for the export date).
  DateTime? firstSeen;

  /// Languages that have content, in order of appearance.
  List<String> get languages => _items.keys.toList();

  bool hasLanguage(String language) => _items.containsKey(language);

  void clear() {
    _items.clear();
    _order = 0;
    _firstStart = null;
    _lastEnd = null;
    firstSeen = null;
  }

  /// Adds or replaces (same [key]) one item of [language].
  void upsert(
    String language,
    String key, {
    required double start,
    required String kind,
    required String text,
    bool unstable = false,
    String? speaker,
    double? end,
  }) {
    final lane = _items.putIfAbsent(language, () => {});
    final previous = lane[key];
    lane[key] = LiveItem(
      start: start,
      kind: kind,
      text: text,
      unstable: unstable,
      speaker: speaker,
      order: previous?.order ?? _order++,
    );
    firstSeen ??= DateTime.now();
    // Duration of the talk, from the text segments' (absolute) times only.
    if (kind == 'text' && start > 1e6) {
      final e = (end != null && end > start) ? end : start;
      if (_firstStart == null || start < _firstStart!) _firstStart = start;
      if (_lastEnd == null || e > _lastEnd!) _lastEnd = e;
    }
  }

  /// Length of the talk so far, or null if unknown.
  Duration? get duration {
    if (_firstStart == null || _lastEnd == null) return null;
    final seconds = _lastEnd! - _firstStart!;
    if (seconds <= 0) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// The document of one language, in the Session Output layout.
  DocContent build(String language) {
    final lane = _items[language];
    if (lane == null || lane.isEmpty) return const DocContent([], []);

    final items = lane.values.toList()
      ..sort((a, b) {
        final c = a.start.compareTo(b.start);
        return c != 0 ? c : a.order.compareTo(b.order);
      });

    final globalSummaries = <String>[];
    final blocks = <DocBlock>[];
    final stable = <String>[];
    final pending = <String>[];
    final lastBox = <String, String>{};
    var speaker = '';

    void flush() {
      if (stable.isEmpty && pending.isEmpty) return;
      blocks.add(DocBlock('para', joinRunningText(stable),
          pending: joinRunningText(pending)));
      stable.clear();
      pending.clear();
    }

    for (final item in items) {
      final raw = item.text;
      final text = cleanMarkupText(raw);
      final kind = item.kind;

      if (kind == 'paragraphBreak' ||
          (kind == 'text' && raw.toLowerCase().contains('<br') && text.isEmpty)) {
        flush();
        continue;
      }
      if (text.isEmpty) continue;

      if (kind == 'global_summary') {
        if (!globalSummaries.contains(text)) globalSummaries.add(text);
        continue;
      }
      if (kind == 'summary' || kind == 'notes' || kind == 'postedited') {
        flush();
        if (lastBox[kind] != text) {
          // KIT repeats them
          blocks.add(DocBlock(kind, text));
          lastBox[kind] = text;
        }
        continue;
      }
      if (kind == 'heading') {
        flush();
        blocks.add(DocBlock('heading', text));
        continue;
      }
      if (kind != 'text') {
        // chapterBreak and other markers without text to show
        flush();
        continue;
      }

      final name = item.speaker ?? '';
      if (name.isNotEmpty && name != speaker) {
        flush();
        speaker = name;
        blocks.add(DocBlock('speaker', name));
      }
      // Unstable text only at the very end of a paragraph; a stable segment
      // after it means it was replaced – drop what was pending.
      if (item.unstable) {
        pending.add(text);
      } else {
        if (pending.isNotEmpty) pending.clear();
        stable.add(text);
      }
    }
    flush();
    // The global summary of the newest version only (KIT updates it).
    final gs = globalSummaries.isEmpty ? <String>[] : [globalSummaries.last];
    return DocContent(gs, blocks);
  }
}

// ── text helpers (same rules as transcript_export.py) ──────────────────────

final RegExp _noSpace = RegExp('[　-鿿豈-﫿＀-￯฀-๿]');

/// Running text: a space between segments, none inside CJK / Thai.
String joinRunningText(List<String> parts) {
  final out = StringBuffer();
  String last = '';
  for (var p in parts) {
    p = p.trim();
    if (p.isEmpty) continue;
    if (out.isNotEmpty && !(_noSpace.hasMatch(last) && _noSpace.hasMatch(p[0]))) {
      out.write(' ');
    }
    out.write(p);
    last = p[p.length - 1];
  }
  return out.toString();
}

/// Removes KIT's HTML (<br />, <b> …) from a segment.
String cleanMarkupText(String text) {
  final noBr = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ');
  return noBr.replaceAll(RegExp(r'<[^>]+>'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
}
