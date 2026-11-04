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
  });

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
    final body = theme.textTheme.bodyLarge?.copyWith(fontSize: 17, height: 1.45);
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
              Text(g, style: body?.copyWith(fontStyle: FontStyle.italic, color: purple, fontSize: 15)),
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
              style: body?.copyWith(fontSize: 15),
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
  });

  final String key;

  /// WAV bytes.
  final Uint8List audio;

  /// The text stream it speaks ("mt:1" for "tts:1").
  final String textSender;
  final String text;

  /// KIT's min/max_message_id: which messages of [textSender] it speaks.
  final int? minId;
  final int? maxId;

  bool speaks(DocSpan s) =>
      s.sender == textSender &&
      s.messageId != null &&
      minId != null &&
      s.messageId! >= minId! &&
      s.messageId! <= (maxId ?? minId!);
}

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
