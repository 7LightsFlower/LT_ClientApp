import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

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
            setState(() => _isLoading = false);
            await _checkCookies();
          },
          onWebResourceError: (WebResourceError error) {
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
      final cookies = await _controller.runJavaScriptReturningResult(
        'document.cookie',
      ) as String?;

      if (cookies != null && cookies.isNotEmpty) {
        await _secureStorage.write(key: 'cookies', value: cookies);
        debugPrint('🍪 Stored cookie: $cookies');

        if (mounted) {
          Navigator.pushReplacementNamed(
            context,
            '/live',
            arguments: {
              'resolvedUrl': widget.resolvedUrl,
              'originalUrl': widget.originalUrl,
            },
          );
        }
      } else {
        setState(() {
          _errorMessage = 'No cookies found. Please try again or log in manually.';
        });
      }
    } catch (e) {
      debugPrint('⚠️ Failed to read cookies: $e');
      setState(() {
        _errorMessage = 'Could not retrieve authentication cookies. Please try again.';
      });
    }
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
                  ElevatedButton(
                    onPressed: _retry,
                    child: const Text('Retry'),
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
