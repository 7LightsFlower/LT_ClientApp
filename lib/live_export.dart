// live_export.dart
//
// TXT / DOCX / RTF / PDF exports of a live document, in the same layout as
// the GetAllSubtitled backend's transcript_export.py ("looks like Session
// Output"), but built in the app from what was received – no server needed.
//
//     <Session name>
//     Language · Date · Duration · Exported …
//     Global summary · Headings · Speakers · Paragraphs · Summaries
//
// File name: just the language ("German.docx"); the original is
// "Transcript.docx". The session name is inside the file, as its title.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'live_document.dart';

enum ExportFormat { txt, docx, rtf, pdf }

extension ExportFormatInfo on ExportFormat {
  String get ext => name;
  String get label => name.toUpperCase();
  String get mimeType => switch (this) {
        ExportFormat.txt => 'text/plain',
        ExportFormat.docx =>
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        ExportFormat.rtf => 'application/rtf',
        ExportFormat.pdf => 'application/pdf',
      };
}

const Map<String, String> _labels = {
  'summary': 'Summary',
  'notes': 'Notes',
  'postedited': 'Post-edited',
};

/// "German.docx"; "Transcript.docx" for the original.
String exportFileName(String language, ExportFormat format) {
  final lang = language.trim();
  final low = lang.toLowerCase();
  String base;
  if (lang.isEmpty || low.contains('original') || low.contains('asr') || low.startsWith('transcript')) {
    base = 'Transcript';
  } else {
    base = lang.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (base.length > 80) base = base.substring(0, 80);
    if (base.isEmpty) base = 'Transcript';
  }
  return '$base.${format.ext}';
}

/// "German · 2026-11-04 · 42:17 · Exported 2026-11-04 10:31"
String exportMetaLine(String language, LiveDocument doc) {
  String two(int v) => v.toString().padLeft(2, '0');
  String date(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';
  final parts = <String>[];
  if (language.trim().isNotEmpty) parts.add(language.trim());
  if (doc.firstSeen != null) parts.add(date(doc.firstSeen!));
  final dur = doc.duration;
  if (dur != null && dur.inSeconds > 0) {
    final h = dur.inHours, m = dur.inMinutes % 60, s = dur.inSeconds % 60;
    parts.add(h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}');
  }
  final now = DateTime.now();
  parts.add('Exported ${date(now)} ${two(now.hour)}:${two(now.minute)}');
  return parts.join(' · ');
}

/// The file contents for [format].
Future<Uint8List> buildExport(
  ExportFormat format, {
  required String title,
  required String meta,
  required DocContent content,
}) async {
  switch (format) {
    case ExportFormat.txt:
      return toTxt(title, meta, content);
    case ExportFormat.rtf:
      return toRtf(title, meta, content);
    case ExportFormat.docx:
      return toDocx(title, meta, content);
    case ExportFormat.pdf:
      return toPdf(title, meta, content);
  }
}

// ── TXT ──────────────────────────────────────────────────────────────────

Uint8List toTxt(String title, String meta, DocContent c) {
  final out = <String>[title, meta, '=' * title.length.clamp(20, 80).toInt(), ''];
  if (c.globalSummaries.isNotEmpty) {
    out.addAll(['GLOBAL SUMMARY', '']);
    for (final g in c.globalSummaries) {
      out.addAll([g, '']);
    }
    out.addAll(['-' * 40, '']);
  }
  for (final b in c.blocks) {
    switch (b.kind) {
      case 'heading':
        out.addAll(['', b.text.toUpperCase(), '']);
      case 'speaker':
        out.add('[${b.text}]');
      case 'para':
        if (b.text.isNotEmpty) out.addAll([b.text, '']);
      default:
        out.addAll(['    ${_labels[b.kind] ?? b.kind}: ${b.text}', '']);
    }
  }
  final text = '${out.join('\n').trimRight()}\n';
  return Uint8List.fromList(utf8.encode(text));
}

// ── RTF ──────────────────────────────────────────────────────────────────

String _rtf(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == '\\' || ch == '{' || ch == '}') {
      out.write('\\$ch');
    } else if (ch == '\n') {
      out.write('\\line ');
    } else if (rune < 128) {
      out.write(ch);
    } else if (rune <= 0xFFFF) {
      out.write('\\u${rune > 32767 ? rune - 65536 : rune}?');
    } else {
      // outside the BMP (emoji): UTF-16 surrogate pair
      final c = rune - 0x10000;
      for (final u in [0xD800 + (c >> 10), 0xDC00 + (c & 0x3FF)]) {
        out.write('\\u${u - 65536}?');
      }
    }
  }
  return out.toString();
}

Uint8List toRtf(String title, String meta, DocContent c) {
  final rtf = <String>[
    r'{\rtf1\ansi\ansicpg1252\deff0\uc1',
    r'{\fonttbl{\f0\fswiss Arial;}}',
    r'{\colortbl;\red102\green102\blue102;\red91\green44\blue131;'
        r'\red21\green101\blue192;\red46\green125\blue50;}',
    r'\f0\fs22',
    '{\\pard\\sa120\\b\\fs36 ${_rtf(title)}\\par}',
    '{\\pard\\sa240\\cf1\\fs18 ${_rtf(meta)}\\par}',
  ];
  if (c.globalSummaries.isNotEmpty) {
    rtf.add(r'{\pard\sa80\b\fs26 Global Summary\par}');
    for (final g in c.globalSummaries) {
      rtf.add('{\\pard\\sa160\\i\\cf2 ${_rtf(g)}\\par}');
    }
  }
  for (final b in c.blocks) {
    switch (b.kind) {
      case 'heading':
        rtf.add('{\\pard\\sb240\\sa120\\b\\fs26 ${_rtf(b.text)}\\par}');
      case 'speaker':
        rtf.add('{\\pard\\sb160\\b\\fs18\\cf3 ${_rtf(b.text)}\\par}');
      case 'para':
        if (b.text.isNotEmpty) {
          rtf.add('{\\pard\\sa160\\sl276\\slmult1 ${_rtf(b.text)}\\par}');
        }
      default:
        rtf.add('{\\pard\\li360\\sa160{\\b\\cf4 ${_rtf('${_labels[b.kind] ?? b.kind}: ')}}'
            '{\\i ${_rtf(b.text)}}\\par}');
    }
  }
  rtf.add('}');
  return Uint8List.fromList(ascii.encode(rtf.join('\n')));
}

// ── DOCX (WordprocessingML in a ZIP, written by hand – no extra package) ──

String _xml(String s) => s
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// One run. [size] in points.
String _run(String text, {bool bold = false, bool italic = false, String? color, double? size}) {
  final props = StringBuffer();
  if (bold) props.write('<w:b/>');
  if (italic) props.write('<w:i/>');
  if (color != null) props.write('<w:color w:val="$color"/>');
  if (size != null) {
    final half = (size * 2).round();
    props.write('<w:sz w:val="$half"/><w:szCs w:val="$half"/>');
  }
  final rPr = props.isEmpty ? '' : '<w:rPr>$props</w:rPr>';
  return '<w:r>$rPr<w:t xml:space="preserve">${_xml(text)}</w:t></w:r>';
}

/// One paragraph. Spacing in points.
String _para(String runs, {double before = 0, double after = 8, double indent = 0, double? lineSpacing}) {
  final spacing = StringBuffer('<w:spacing w:before="${(before * 20).round()}" w:after="${(after * 20).round()}"');
  if (lineSpacing != null) spacing.write(' w:line="${(lineSpacing * 240).round()}" w:lineRule="auto"');
  spacing.write('/>');
  final ind = indent > 0 ? '<w:ind w:left="${(indent * 20).round()}"/>' : '';
  return '<w:p><w:pPr>$spacing$ind</w:pPr>$runs</w:p>';
}

Uint8List toDocx(String title, String meta, DocContent c) {
  final body = StringBuffer()
    ..write(_para(_run(title, bold: true, size: 20), after: 4))
    ..write(_para(_run(meta, color: '666666', size: 9), after: 14));

  if (c.globalSummaries.isNotEmpty) {
    body.write(_para(_run('Global Summary', bold: true, size: 13), before: 6, after: 4));
    for (final g in c.globalSummaries) {
      body.write(_para(_run(g, italic: true, color: '5B2C83'), after: 10)); // purple, as on screen
    }
  }
  for (final b in c.blocks) {
    switch (b.kind) {
      case 'heading':
        body.write(_para(_run(b.text, bold: true, size: 13), before: 12, after: 6));
      case 'speaker':
        body.write(_para(_run(b.text, bold: true, size: 9, color: '1565C0'), before: 10, after: 0)); // speaker blue
      case 'para':
        if (b.text.isNotEmpty) body.write(_para(_run(b.text), after: 8, lineSpacing: 1.2));
      default:
        body.write(_para(
          _run('${_labels[b.kind] ?? b.kind}: ', bold: true, color: '2E7D32') + // summary green
              _run(b.text, italic: true),
          indent: 18,
          after: 8,
        ));
    }
  }

  const contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '</Types>';
  const rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
      'Target="word/document.xml"/>'
      '</Relationships>';
  final document = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>$body'
      '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
      '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="709" w:footer="709" w:gutter="0"/>'
      '</w:sectPr></w:body></w:document>';

  return _zipStored({
    '[Content_Types].xml': utf8.encode(contentTypes),
    '_rels/.rels': utf8.encode(rels),
    'word/document.xml': utf8.encode(document),
  });
}

// Minimal ZIP writer (entries stored uncompressed – valid for DOCX).
final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
  }
  return c;
});

int _crc32(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

Uint8List _zipStored(Map<String, List<int>> files) {
  const le = Endian.little;
  final out = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  var offset = 0;
  for (final entry in files.entries) {
    final name = utf8.encode(entry.key);
    final data = entry.value;
    final crc = _crc32(data);

    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, le) // local file header
      ..setUint16(4, 20, le) // version needed
      ..setUint16(6, 0x0800, le) // UTF-8 names
      ..setUint16(8, 0, le) // stored
      ..setUint16(10, 0, le) // time
      ..setUint16(12, 0x21, le) // date 1980-01-01
      ..setUint32(14, crc, le)
      ..setUint32(18, data.length, le)
      ..setUint32(22, data.length, le)
      ..setUint16(26, name.length, le)
      ..setUint16(28, 0, le);
    out
      ..add(local.buffer.asUint8List())
      ..add(name)
      ..add(data);

    final dir = ByteData(46)
      ..setUint32(0, 0x02014b50, le) // central directory header
      ..setUint16(4, 20, le) // version made by
      ..setUint16(6, 20, le) // version needed
      ..setUint16(8, 0x0800, le)
      ..setUint16(10, 0, le)
      ..setUint16(12, 0, le)
      ..setUint16(14, 0x21, le)
      ..setUint32(16, crc, le)
      ..setUint32(20, data.length, le)
      ..setUint32(24, data.length, le)
      ..setUint16(28, name.length, le)
      ..setUint16(30, 0, le) // extra
      ..setUint16(32, 0, le) // comment
      ..setUint16(34, 0, le) // disk
      ..setUint16(36, 0, le) // internal attributes
      ..setUint32(38, 0, le) // external attributes
      ..setUint32(42, offset, le);
    central
      ..add(dir.buffer.asUint8List())
      ..add(name);

    offset += 30 + name.length + data.length;
  }
  final dirBytes = central.toBytes();
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, le) // end of central directory
    ..setUint16(4, 0, le)
    ..setUint16(6, 0, le)
    ..setUint16(8, files.length, le)
    ..setUint16(10, files.length, le)
    ..setUint32(12, dirBytes.length, le)
    ..setUint32(16, offset, le)
    ..setUint16(20, 0, le);
  out
    ..add(dirBytes)
    ..add(end.buffer.asUint8List());
  return out.toBytes();
}

// ── PDF (Noto fonts from assets/fonts: Latin, CJK, Arabic …) ──────────────

Future<List<pw.Font>> _loadFonts() async {
  const files = [
    'NotoSans-Regular.ttf',
    'NotoSansSC-Regular.ttf',
    'NotoSansTC-Regular.ttf',
    'NotoSansJP-Regular.ttf',
    'NotoSansKR-Regular.ttf',
    'NotoSansArabic-Regular.ttf',
  ];
  final fonts = <pw.Font>[];
  for (final f in files) {
    try {
      final data = await rootBundle.load('assets/fonts/$f');
      fonts.add(pw.Font.ttf(data));
    } catch (_) {
      // a missing font only means fewer scripts are covered
    }
  }
  return fonts;
}

Future<Uint8List> toPdf(String title, String meta, DocContent c) async {
  final fonts = await _loadFonts();
  final base = fonts.isNotEmpty ? fonts.first : pw.Font.helvetica();
  final fallback = fonts.length > 1 ? fonts.sublist(1) : <pw.Font>[];

  pw.TextStyle style({double size = 11, bool bold = false, bool italic = false, PdfColor? color}) =>
      pw.TextStyle(
        font: base,
        fontFallback: fallback,
        fontSize: size,
        // Only the Regular Noto fonts are bundled (see pubspec assets), so
        // colour and size carry most of the emphasis.
        fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        fontStyle: italic ? pw.FontStyle.italic : pw.FontStyle.normal,
        color: color,
        lineSpacing: 2,
      );

  const purple = PdfColor.fromInt(0xFF5B2C83);
  const blue = PdfColor.fromInt(0xFF1565C0);
  const green = PdfColor.fromInt(0xFF2E7D32);
  const grey = PdfColor.fromInt(0xFF666666);

  final widgets = <pw.Widget>[
    pw.Text(title, style: style(size: 20, bold: true)),
    pw.SizedBox(height: 4),
    pw.Text(meta, style: style(size: 9, color: grey)),
    pw.SizedBox(height: 14),
  ];
  if (c.globalSummaries.isNotEmpty) {
    widgets.add(pw.Text('Global Summary', style: style(size: 13, bold: true)));
    widgets.add(pw.SizedBox(height: 4));
    for (final g in c.globalSummaries) {
      widgets.add(pw.Text(g, style: style(italic: true, color: purple)));
      widgets.add(pw.SizedBox(height: 10));
    }
  }
  for (final b in c.blocks) {
    switch (b.kind) {
      case 'heading':
        widgets.add(pw.Padding(
          padding: const pw.EdgeInsets.only(top: 12, bottom: 6),
          child: pw.Text(b.text, style: style(size: 13, bold: true)),
        ));
      case 'speaker':
        widgets.add(pw.Padding(
          padding: const pw.EdgeInsets.only(top: 10),
          child: pw.Text(b.text, style: style(size: 9, bold: true, color: blue)),
        ));
      case 'para':
        if (b.text.isNotEmpty) {
          widgets.add(pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 8),
            child: pw.Text(b.text, style: style()),
          ));
        }
      default:
        widgets.add(pw.Padding(
          padding: const pw.EdgeInsets.only(left: 18, bottom: 8),
          child: pw.RichText(
            text: pw.TextSpan(children: [
              pw.TextSpan(text: '${_labels[b.kind] ?? b.kind}: ', style: style(bold: true, color: green)),
              pw.TextSpan(text: b.text, style: style(italic: true)),
            ]),
          ),
        ));
    }
  }

  final pdf = pw.Document();
  pdf.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(40),
    build: (_) => widgets,
  ));
  return pdf.save();
}
