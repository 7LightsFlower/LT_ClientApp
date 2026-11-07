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
    this.sender,
    this.messageId,
    this.end,
    this.messageIds = const {},
  });

  /// End time (seconds), if KIT sent one.
  final double? end;

  /// Every message_id this text has had – KIT re-sends corrected text with a
  /// new id, while the spoken audio may still name the old one.
  final Set<int> messageIds;

  /// KIT stream ("mt:1") and its message_id – lets a spoken translation
  /// (tts:1, min/max_message_id) find the text it speaks.
  final String? sender;
  final int? messageId;

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

/// One received segment inside a paragraph (for highlighting what is
/// being spoken). [text] already carries its leading space.
class DocSpan {
  const DocSpan(this.text,
      {this.key = '', this.sender, this.messageId, this.messageIds = const {}, this.pending = false});
  final String text;

  /// The item's key in the document (stable across rebuilds).
  final String key;
  final Set<int> messageIds;
  final String? sender;
  final int? messageId;
  final bool pending;
}

/// One block of the rendered document.
class DocBlock {
  const DocBlock(this.kind, this.text, {this.pending = '', this.spans = const []});

  /// Paragraphs only: the segments it is made of, in order.
  final List<DocSpan> spans;

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

  /// Goes up with every change (lets callers cache what they computed).
  int revision = 0;
  double? _firstStart;
  double? _lastEnd;

  /// When the first message of this session arrived (for the export date).
  DateTime? firstSeen;

  /// Languages that have content, in order of appearance.
  List<String> get languages => _items.keys.toList();

  bool hasLanguage(String language) => _items.containsKey(language);

  void clear() {
    _items.clear();
    revision++;
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
    String? sender,
    int? messageId,
  }) {
    final lane = _items.putIfAbsent(language, () => {});
    final previous = lane[key];
    final ids = <int>{...?previous?.messageIds, if (messageId != null) messageId};
    lane[key] = LiveItem(
      start: start,
      end: end,
      kind: kind,
      text: text,
      unstable: unstable,
      speaker: speaker,
      sender: sender,
      messageId: messageId,
      messageIds: ids,
      order: previous?.order ?? _order++,
    );
    revision++;
    firstSeen ??= DateTime.now();
    // Duration of the talk, from the text segments' (absolute) times only.
    if (kind == 'text' && start > 1e6) {
      final e = (end != null && end > start) ? end : start;
      if (_firstStart == null || start < _firstStart!) _firstStart = start;
      if (_lastEnd == null || e > _lastEnd!) _lastEnd = e;
    }
  }

  /// Removes one item (KIT's "action": "remove", or a finished unstable tail).
  void remove(String language, String key) {
    if (_items[language]?.remove(key) != null) revision++;
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

    final keyOf = <LiveItem, String>{for (final e in lane.entries) e.value: e.key};
    final items = lane.values.toList()
      ..sort((a, b) {
        // Like KIT's page: text still being recognised is always the tail.
        if (a.unstable != b.unstable) return a.unstable ? 1 : -1;
        final c = a.start.compareTo(b.start);
        return c != 0 ? c : a.order.compareTo(b.order);
      });

    final globalSummaries = <String>[];
    final blocks = <DocBlock>[];
    final stable = <String>[];
    final pending = <String>[];
    final stableItems = <LiveItem>[];
    final pendingItems = <LiveItem>[];
    final lastBox = <String, String>{};
    var speaker = '';

    void flush() {
      if (stable.isEmpty && pending.isEmpty) return;
      // Spans with the same spacing as joinRunningText.
      final spans = <DocSpan>[];
      String last = '';
      void addSpans(List<String> texts, List<LiveItem> from, bool isPending) {
        for (var i = 0; i < texts.length; i++) {
          final t = texts[i].trim();
          if (t.isEmpty) continue;
          final space = last.isNotEmpty && !(_noSpace.hasMatch(last) && _noSpace.hasMatch(t[0]));
          spans.add(DocSpan(space ? ' $t' : t,
              key: keyOf[from[i]] ?? '',
              sender: from[i].sender,
              messageId: from[i].messageId,
              messageIds: from[i].messageIds,
              pending: isPending));
          last = t[t.length - 1];
        }
      }
      addSpans(stable, stableItems, false);
      addSpans(pending, pendingItems, true);
      blocks.add(DocBlock('para', joinRunningText(stable),
          pending: joinRunningText(pending), spans: spans));
      stable.clear();
      pending.clear();
      stableItems.clear();
      pendingItems.clear();
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
        pendingItems.add(item);
      } else {
        if (pending.isNotEmpty) {
          pending.clear();
          pendingItems.clear();
        }
        stable.add(text);
        stableItems.add(item);
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
