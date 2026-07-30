import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:developer' as developer;

class QRScannerScreen extends StatefulWidget {
  const QRScannerScreen({super.key});

  @override
  State<QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<QRScannerScreen> {
  bool get _cameraSupported {
    if (kIsWeb) return true;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return true;
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return false;
      default:
        return false;
    }
  }

  late final MobileScannerController? scannerController =
      _cameraSupported ? MobileScannerController() : null;

  bool _isProcessing = false;

  @override
  void dispose() {
    scannerController?.dispose();
    super.dispose();
  }

  // ─── URL resolver ──────────────────────────────────────────────

  Future<String> _resolveUrl(String input) async {
    input = input.trim();

    if (input.startsWith('ws://') || input.startsWith('wss://')) {
      return input;
    }

    if (!input.startsWith('http://') && !input.startsWith('https://')) {
      throw Exception('Invalid URL format.');
    }

    final response = await http.get(Uri.parse(input));
    if (response.statusCode != 200) {
      throw Exception('Server returned HTTP ${response.statusCode}');
    }

    final body = response.body;
    final sessionIdRegex = RegExp(r'window\.sessionId\s*=\s*"([^"]+)"');
    final match = sessionIdRegex.firstMatch(body);
    if (match == null) {
      throw Exception('Could not find window.sessionId in the page.');
    }
    final sessionId = match.group(1)!;
    developer.log('Extracted session ID: $sessionId');

    final uri = Uri.parse(input);
    return '${uri.scheme}://${uri.host}/webapi/stream?channel=$sessionId';
  }

  // ─── History helper (uses same JSON format) ───────────────────

  Future<void> _addToHistory(String rawUrl) async {
    final prefs = await SharedPreferences.getInstance();
    final storedList = prefs.getStringList('session_history') ?? [];

    // Parse existing items
    List<Map<String, dynamic>> items = [];
    for (final entry in storedList) {
      try {
        final map = jsonDecode(entry) as Map<String, dynamic>;
        items.add(map);
      } catch (_) {
        // Old plain string – convert to new format with default date
        if (entry.trim().isNotEmpty) {
          items.add({
            'url': entry.trim(),
            'lastConnected': DateTime(2000, 1, 1).toIso8601String(),
          });
        }
      }
    }

    // Remove duplicate if exists
    items.removeWhere((map) => map['url'] == rawUrl);

    // Add new item with current timestamp
    items.insert(0, {
      'url': rawUrl,
      'lastConnected': DateTime.now().toIso8601String(),
    });

    // Keep only last 20
    if (items.length > 20) items = items.sublist(0, 20);

    // Serialize back to JSON strings
    final jsonList = items.map((map) => jsonEncode(map)).toList();
    await prefs.setStringList('session_history', jsonList);
  }

  // ─── Process scanned or manual input ──────────────────────────

  Future<void> _proceedWithUrl(String rawInput) async {
    if (rawInput.trim().isEmpty) return;

    setState(() => _isProcessing = true);

    if (scannerController != null) {
      await scannerController!.stop();
    }

    if (!mounted) return;
    // Show loading dialog – we guard later uses with mounted checks
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    String resolvedUrl;
    try {
      resolvedUrl = await _resolveUrl(rawInput);
    } catch (e) {
      // Only interact with UI if still mounted
      if (mounted) {
        Navigator.pop(context); // close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error resolving: $e'), backgroundColor: Colors.red),
        );
        await scannerController?.start();
        setState(() => _isProcessing = false);
      }
      return;
    }

    // Store the raw input (short link) in history
    await _addToHistory(rawInput);

    // Navigate away only if still mounted
    if (mounted) {
      Navigator.pop(context); // close loading dialog
      Navigator.pushReplacementNamed(
        context,
        '/live',
        arguments: {
          'resolvedUrl': resolvedUrl,
          'originalUrl': rawInput,   // the short link the user scanned/entered
        },
      );
    }
  }

  // ─── UI ─────────────────────────────────────────────────────────

  Widget _buildManualEntryScreen() {
    final TextEditingController textController = TextEditingController();

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.link, size: 80, color: Colors.blue),
          const SizedBox(height: 24),
          const Text(
            'Enter the WebSocket URL manually',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          const Text(
            'Camera is not available on this platform.\nPaste or type the URL below.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey),
          ),
          const SizedBox(height: 32),
          TextField(
            controller: textController,
            decoration: const InputDecoration(
              hintText: 'wss://example.com/ws  or  https://.../shorten/...',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.link),
            ),
            autofocus: true,
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () {
              final url = textController.text.trim();
              if (url.isNotEmpty) {
                _proceedWithUrl(url);
              }
            },
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Connect'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 50),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScannerUI() {
    // Ensure the controller is not null (it should be when _cameraSupported is true)
    final controller = scannerController;
    if (controller == null) {
      // Fallback: show manual entry if controller is null
      return _buildManualEntryScreen();
    }

    return Scaffold(
      body: MobileScanner(
        controller: controller,
        onDetect: _onScanComplete,
        errorBuilder: (context, error) {
          // This callback is called when the camera fails.
          // Show error and offer manual entry fallback.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Camera error: $error'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          });
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 60, color: Colors.red),
                const SizedBox(height: 16),
                Text(
                  'Camera error: $error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _showManualEntryDialog,
                  icon: const Icon(Icons.edit),
                  label: const Text('Enter URL manually'),
                ),
              ],
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showManualEntryDialog,
        icon: const Icon(Icons.edit),
        label: const Text('Enter URL manually'),
      ),
    );
  }

  Future<void> _onScanComplete(BarcodeCapture capture) async {
    if (_isProcessing) return;
    final String? rawValue = capture.barcodes.first.rawValue;
    if (rawValue == null) return;
    await _proceedWithUrl(rawValue);
  }

  void _showManualEntryDialog() {
    final TextEditingController textController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Enter WebSocket or HTTPS URL'),
        content: TextField(
          controller: textController,
          decoration: const InputDecoration(
            hintText: 'wss://example.com/ws  or  https://.../shorten/...',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          keyboardType: TextInputType.url,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final url = textController.text.trim();
              if (url.isNotEmpty) {
                Navigator.pop(context);
                _proceedWithUrl(url);
              }
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool useCamera = _cameraSupported;

    return Scaffold(
      appBar: AppBar(
        title: Text(useCamera ? 'Scan QR Code' : 'Enter URL'),
      ),
      body: useCamera
          ? _buildScannerUI()
          : _buildManualEntryScreen(),
      floatingActionButton: useCamera
          ? FloatingActionButton.extended(
              onPressed: _showManualEntryDialog,
              icon: const Icon(Icons.edit),
              label: const Text('Enter URL manually'),
            )
          : null,
    );
  }
}