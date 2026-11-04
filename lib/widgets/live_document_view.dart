// live_document_view.dart
//
// Shows one language of a running session like the Session Output screen:
// global summary on top, headings, speakers, running paragraphs (text still
// being recognised in grey at the end) and chapter summaries.

import 'package:flutter/material.dart';

import '../live_document.dart';

class LiveDocumentView extends StatelessWidget {
  const LiveDocumentView({
    super.key,
    required this.content,
    required this.controller,
    this.emptyText = 'Waiting for transcript...',
  });

  final DocContent content;
  final ScrollController controller;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    if (content.isEmpty) {
      return Center(child: Text(emptyText));
    }
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final purple = dark ? const Color(0xFFCE93D8) : const Color(0xFF5B2C83);
    final blue = dark ? const Color(0xFF90CAF9) : const Color(0xFF1565C0);
    final green = dark ? const Color(0xFFA5D6A7) : const Color(0xFF2E7D32);
    final body = theme.textTheme.bodyLarge?.copyWith(fontSize: 17, height: 1.45);
    final pendingStyle = body?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.45));

    final children = <Widget>[];

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
          children.add(Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text.rich(TextSpan(
              style: body,
              children: [
                TextSpan(text: b.text),
                if (b.pending.isNotEmpty)
                  TextSpan(text: b.text.isEmpty ? b.pending : ' ${b.pending}', style: pendingStyle),
              ],
            )),
          ));
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
                TextSpan(
                    text: '$label: ', style: TextStyle(color: green, fontWeight: FontWeight.bold)),
                TextSpan(text: b.text, style: const TextStyle(fontStyle: FontStyle.italic)),
              ],
            )),
          ));
      }
    }

    return SelectionArea(
      child: ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: children,
      ),
    );
  }
}
