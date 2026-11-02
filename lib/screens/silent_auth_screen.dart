import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../cookie_utils.dart';

class SilentAuthScreen extends StatefulWidget {
  final String originalUrl;
  final String resolvedUrl;

  const SilentAuthScreen({
    super.key,
    required this.originalUrl,
    required this.resolvedUrl,
  });

  @override
  State<SilentAuthScreen> createState() => _SilentAuthScreenState();
}

class _SilentAuthScreenState extends State<SilentAuthScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  String? _errorMessage;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  /// Set once we navigate away, so later onPageFinished calls (redirects,
  /// iframes) can't push the live screen a second time.
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _initializeWebView();
  }

  void _initializeWebView() {
    var controller = WebViewController()
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) async {
            if (!mounted || _done) return;
            setState(() => _isLoading = false);
            await _checkCookies();
          },
          onWebResourceError: (WebResourceError error) {
            // Ignore failing sub-resources (images, trackers, ...).
            if (error.isForMainFrame == false) return;
            if (!mounted || _done) return;
            setState(() {
              _isLoading = false;
              _errorMessage = 'Failed to load page: ${error.description}';
            });
          },
        ),
      );

    // ✅ Only call on native platforms – web doesn't need this
    if (!kIsWeb) {
      controller = controller..setJavaScriptMode(JavaScriptMode.unrestricted);
    }

    _controller = controller..loadRequest(Uri.parse(widget.originalUrl));
  }

  Future<void> _checkCookies() async {
    try {
      final result = await _controller.runJavaScriptReturningResult('document.cookie');
      // Android returns a JSON-quoted string; iOS/macOS return it plain.
      final cookies = normalizeJsStringResult(result);
      if (!mounted || _done) return;

      if (cookies.isNotEmpty) {
        final existing = await _secureStorage.read(key: 'cookies');
        final merged = mergeCookieHeaders(existing, parseCookieHeader(cookies));
        await _secureStorage.write(key: 'cookies', value: merged);
        debugPrint('🍪 Stored cookie: $merged');
        _goToLive();
      } else {
        // document.cookie cannot see HttpOnly cookies, which is how most
        // servers mark session cookies.
        setState(() {
          _errorMessage = 'No readable cookies found. The server may use HttpOnly '
              'cookies, which the app cannot read. You can continue without them.';
        });
      }
    } catch (e) {
      debugPrint('⚠️ Failed to read cookies: $e');
      if (!mounted || _done) return;
      setState(() {
        _errorMessage = 'Could not retrieve authentication cookies. Please try again.';
      });
    }
  }

  void _goToLive() {
    if (_done || !mounted) return;
    _done = true;
    Navigator.pushReplacementNamed(
      context,
      '/live',
      arguments: {
        'resolvedUrl': widget.resolvedUrl,
        'originalUrl': widget.originalUrl,
        // Tells the live screen not to send us back here (prevents loops).
        'authAttempted': true,
      },
    );
  }

  void _retry() {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    _controller.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Authenticating…'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _retry,
            tooltip: 'Retry',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isLoading) const LinearProgressIndicator(),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    alignment: WrapAlignment.center,
                    children: [
                      ElevatedButton(
                        onPressed: _retry,
                        child: const Text('Retry'),
                      ),
                      OutlinedButton(
                        onPressed: _goToLive,
                        child: const Text('Continue anyway'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Expanded(
            child: WebViewWidget(controller: _controller),
          ),
        ],
      ),
    );
  }
}
