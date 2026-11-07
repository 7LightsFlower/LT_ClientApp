// session_qr_dialog.dart
//
// Shows the session link as a large QR code, so people in the room can scan
// it with this app (or any camera app), and lets you share the QR code as an
// image, share the link as text, or copy it.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart';
import 'package:share_plus/share_plus.dart';

Future<void> showSessionQrDialog(
  BuildContext context, {
  required String link,
  required String title,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _SessionQrDialog(link: link, title: title),
  );
}

class _SessionQrDialog extends StatefulWidget {
  const _SessionQrDialog({required this.link, required this.title});
  final String link;
  final String title;

  @override
  State<_SessionQrDialog> createState() => _SessionQrDialogState();
}

class _SessionQrDialogState extends State<_SessionQrDialog> {
  final GlobalKey _qrKey = GlobalKey();
  bool _busy = false;

  /// The QR code (white card with title) as PNG bytes.
  Future<Uint8List?> _qrPng() async {
    final boundary = _qrKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  Future<void> _shareImage() async {
    setState(() => _busy = true);
    try {
      final png = await _qrPng();
      if (png == null) return;
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(png, mimeType: 'image/png', name: 'session_qr.png')],
        fileNameOverrides: const ['session_qr.png'],
        text: '${widget.title}\n${widget.link}',
        subject: widget.title,
      ));
    } catch (e) {
      _snack('Sharing failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareLink() async {
    try {
      await SharePlus.instance.share(ShareParams(
        text: '${widget.title}\n${widget.link}',
        subject: widget.title,
      ));
    } catch (e) {
      _snack('Sharing failed: $e');
    }
  }

  Future<void> _copyLink() async {
    await Clipboard.setData(ClipboardData(text: widget.link));
    _snack('Link copied');
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final qrSize = (size.shortestSide * 0.62).clamp(180.0, 340.0);

    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Always black on white – also in dark mode – so it scans well.
            RepaintBoundary(
              key: _qrKey,
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: qrSize,
                      height: qrSize,
                      child: CustomPaint(painter: _QrPainter(widget.link)),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: qrSize,
                      child: Text(
                        widget.title,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.black, fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(
              widget.link,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _shareImage,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Share QR'),
            ),
            OutlinedButton.icon(
              onPressed: _shareLink,
              icon: const Icon(Icons.ios_share),
              label: const Text('Share link'),
            ),
            TextButton.icon(
              onPressed: _copyLink,
              icon: const Icon(Icons.copy),
              label: const Text('Copy'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Draws a QR code with the `qr` package (black modules, quiet zone left to
/// the white container around it).
class _QrPainter extends CustomPainter {
  _QrPainter(this.data)
      : _image = QrImage(QrCode.fromData(
          data: data,
          errorCorrectLevel: QrErrorCorrectLevel.M,
        ));

  final String data;
  final QrImage _image;

  @override
  void paint(Canvas canvas, Size size) {
    final n = _image.moduleCount;
    final cell = size.shortestSide / n;
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (_image.isDark(y, x)) {
          // A hair larger than the cell, so no gaps appear between modules.
          canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell + 0.5, cell + 0.5), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.data != data;
}
