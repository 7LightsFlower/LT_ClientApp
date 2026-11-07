// live_document_view.dart
//
// Shows one language of a running session like the Session Output screen:
// global summary on top, headings, speakers, running paragraphs (text still
// being recognised in grey at the end) and chapter summaries.
//
// While the spoken translation plays, the segments being spoken are
// highlighted and scrolled into view; tapping a paragraph plays from there.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../live_document.dart';

class LiveDocumentView extends StatefulWidget {
  const LiveDocumentView({
    super.key,
    required this.content,
    required this.controller,
    this.emptyText = 'Waiting for transcript...',
    this.isSpoken,
    this.spokenToken,
    this.onParagraphTap,
    this.fontSize = 17,
  });

  /// Size of the running text (A− / A+).
  final double fontSize;

  final DocContent content;
  final ScrollController controller;
  final String emptyText;

  /// True for segments the audio player is speaking right now.
  final bool Function(DocSpan span)? isSpoken;

  /// Changes whenever another part starts playing (scrolls it into view).
  final Object? spokenToken;

  /// Tap on a paragraph (e.g. play the audio from there).
  final void Function(DocBlock paragraph)? onParagraphTap;

  @override
  State<LiveDocumentView> createState() => _LiveDocumentViewState();
}

class _LiveDocumentViewState extends State<LiveDocumentView> {
  final GlobalKey _spokenKey = GlobalKey();

  @override
  void didUpdateWidget(LiveDocumentView old) {
    super.didUpdateWidget(old);
    if (widget.spokenToken != null && widget.spokenToken != old.spokenToken) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _spokenKey.currentContext;
        if (ctx != null && mounted) {
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.3, // a little below the top
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.content;
    if (content.isEmpty) {
      return Center(child: Text(widget.emptyText));
    }
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final purple = dark ? const Color(0xFFCE93D8) : const Color(0xFF5B2C83);
    final blue = dark ? const Color(0xFF90CAF9) : const Color(0xFF1565C0);
    final green = dark ? const Color(0xFFA5D6A7) : const Color(0xFF2E7D32);
    final highlight = dark ? const Color(0x66FFD54F) : const Color(0xFFFFF59D);
    final body = theme.textTheme.bodyLarge?.copyWith(fontSize: widget.fontSize, height: 1.45);
    final pendingStyle = body?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.45));

    final children = <Widget>[];
    var spokenKeyUsed = false;

    if (content.globalSummaries.isNotEmpty) {
      children.add(Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: purple.withValues(alpha: 0.08),
          border: Border(left: BorderSide(color: purple, width: 3)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Global summary',
                style: theme.textTheme.labelLarge?.copyWith(color: purple, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            for (final g in content.globalSummaries)
              Text(g, style: body?.copyWith(fontStyle: FontStyle.italic, color: purple, fontSize: widget.fontSize - 2)),
          ],
        ),
      ));
    }

    for (final b in content.blocks) {
      switch (b.kind) {
        case 'heading':
          children.add(Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 6),
            child: Text(b.text, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          ));
        case 'speaker':
          children.add(Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 2),
            child: Text(b.text,
                style: theme.textTheme.labelMedium?.copyWith(color: blue, fontWeight: FontWeight.bold)),
          ));
        case 'para':
          final spoken = widget.isSpoken;
          final hasSpoken = spoken != null && b.spans.any(spoken);
          final spans = b.spans.isNotEmpty
              ? [
                  for (final s in b.spans)
                    TextSpan(
                      text: s.text,
                      style: s.pending
                          ? pendingStyle
                          : (spoken != null && spoken(s))
                              ? TextStyle(backgroundColor: highlight)
                              : null,
                    ),
                ]
              : [
                  TextSpan(text: b.text),
                  if (b.pending.isNotEmpty)
                    TextSpan(text: b.text.isEmpty ? b.pending : ' ${b.pending}', style: pendingStyle),
                ];
          Widget para = Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text.rich(TextSpan(style: body, children: spans)),
          );
          if (widget.onParagraphTap != null) {
            para = GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onParagraphTap!(b),
              child: para,
            );
          }
          if (hasSpoken && !spokenKeyUsed) {
            para = KeyedSubtree(key: _spokenKey, child: para);
            spokenKeyUsed = true;
          }
          children.add(para);
        default: // summary / notes / postedited
          final label = switch (b.kind) {
            'notes' => 'Notes',
            'postedited' => 'Post-edited',
            _ => 'Summary',
          };
          children.add(Container(
            margin: const EdgeInsets.only(left: 12, bottom: 12),
            padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: green, width: 3)),
            ),
            child: Text.rich(TextSpan(
              style: body?.copyWith(fontSize: widget.fontSize - 2),
              children: [
                TextSpan(text: '$label: ', style: TextStyle(color: green, fontWeight: FontWeight.bold)),
                TextSpan(text: b.text, style: const TextStyle(fontStyle: FontStyle.italic)),
              ],
            )),
          ));
      }
    }

    return SelectionArea(
      child: ListView(
        controller: widget.controller,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: children,
      ),
    );
  }
}

/// One spoken-translation piece of a language.
class TtsPart {
  TtsPart({
    required this.key,
    required this.audio,
    required this.textSender,
    required this.text,
    this.minId,
    this.maxId,
  }) : duration = wavDuration(audio);

  final String key;

  /// WAV bytes.
  final Uint8List audio;

  /// Length of [audio].
  final Duration duration;

  /// The text stream it speaks ("mt:1" for "tts:1").
  final String textSender;

  /// What it says.
  final String text;

  /// Which messages of [textSender] it speaks (KIT's message ids).
  final int? minId;
  final int? maxId;

  bool speaksId(DocSpan s) {
    if (s.sender != textSender || minId == null) return false;
    final hi = maxId ?? minId!;
    bool inRange(int id) => id >= minId! && id <= hi;
    return (s.messageId != null && inRange(s.messageId!)) || s.messageIds.any(inRange);
  }

  /// Same as [speaksId] (used when no document is at hand).
  bool speaks(DocSpan s) => speaksId(s);
}

/// Length of a PCM WAV (reads the header).
Duration wavDuration(Uint8List wav) {
  if (wav.length < 44) return Duration.zero;
  final h = ByteData.sublistView(wav);
  final channels = h.getUint16(22, Endian.little);
  final rate = h.getUint32(24, Endian.little);
  final bits = h.getUint16(34, Endian.little);
  final bytesPerSecond = rate * channels * (bits ~/ 8);
  if (bytesPerSecond <= 0) return Duration.zero;
  return Duration(microseconds: ((wav.length - 44) * 1000000 / bytesPerSecond).round());
}

/// The paragraph segments a spoken piece says, as span keys.
///
/// Matches the piece's text with the segments' text: KIT's message ids alone
/// miss text that was corrected or cut differently after the audio was made.
/// The ids only decide which place in the document is meant when the same
/// words occur more than once.
Set<String> spokenSpanKeys(DocContent content, TtsPart part) {
  final spans = <DocSpan>[
    for (final b in content.blocks)
      if (b.kind == 'para')
        for (final s in b.spans)
          if (!s.pending && s.sender == part.textSender) s,
  ];
  if (spans.isEmpty) return const {};
  final spoken = _words(part.text);
  final anchors = <int>[
    for (var i = 0; i < spans.length; i++)
      if (part.speaksId(spans[i])) i,
  ];

  // Segments whose words are (mostly) in the spoken text.
  final hit = List<bool>.filled(spans.length, false);
  final score = List<int>.filled(spans.length, 0);
  final hasWords = List<bool>.filled(spans.length, false);
  for (var i = 0; i < spans.length; i++) {
    final w = _words(spans[i].text);
    if (w.isEmpty) continue;
    hasWords[i] = true;
    final found = w.where(spoken.contains).length;
    score[i] = found;
    hit[i] = spoken.isNotEmpty && found / w.length >= 0.6;
  }

  // Runs of neighbouring matching segments; pick the best one.
  final runs = <List<int>>[];
  for (var i = 0; i < spans.length; i++) {
    if (!hit[i]) continue;
    if (runs.isNotEmpty) {
      // Neighbour if only word-less segments lie in between.
      var j = runs.last.last + 1;
      while (j < i && !hasWords[j]) {
        j++;
      }
      if (j == i) {
        runs.last.add(i);
        continue;
      }
    }
    runs.add([i]);
  }
  if (runs.isEmpty) {
    return {for (final i in anchors) spans[i].key};
  }
  int runScore(List<int> r) => r.fold(0, (a, i) => a + score[i]);
  int distance(List<int> r) {
    if (anchors.isEmpty) return 0;
    var best = 1 << 30;
    for (final a in anchors) {
      final d = a < r.first ? r.first - a : (a > r.last ? a - r.last : 0);
      if (d < best) best = d;
    }
    return best;
  }

  List<int> best = runs.first;
  for (final r in runs.skip(1)) {
    final dr = distance(r), db = distance(best);
    final sr = runScore(r), sb = runScore(best);
    // Closest to KIT's ids first, then most words; later wins a tie (live).
    if (dr < db || (dr == db && sr >= sb)) best = r;
  }
  return {for (final i in best) spans[i].key};
}

final RegExp _wordRe = RegExp(r'[\p{L}\p{N}]+', unicode: true);

Set<String> _words(String text) =>
    {for (final m in _wordRe.allMatches(text.toLowerCase())) m.group(0)!};

/// Player bar for the spoken translation of one language.
class TtsPlayerBar extends StatelessWidget {
  const TtsPlayerBar({
    super.key,
    required this.language,
    required this.count,
    required this.index,
    required this.playing,
    required this.waiting,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
  });

  final String language;
  final int count;

  /// Current part (0-based), or null before the first play.
  final int? index;
  final bool playing;

  /// Played everything so far; continues as soon as the next part arrives.
  final bool waiting;
  final VoidCallback onPlayPause;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = index == null
        ? 'Spoken $language · $count parts'
        : waiting
            ? 'Spoken $language · waiting for the next part…'
            : 'Spoken $language · part ${index! + 1} of $count';
    return Material(
      elevation: 3,
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous),
                tooltip: 'Previous part',
                onPressed: onPrevious,
              ),
              IconButton.filled(
                icon: Icon(playing || waiting ? Icons.pause : Icons.play_arrow),
                tooltip: playing || waiting ? 'Pause' : 'Play the spoken translation',
                onPressed: onPlayPause,
              ),
              IconButton(
                icon: const Icon(Icons.skip_next),
                tooltip: 'Next part',
                onPressed: onNext,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
