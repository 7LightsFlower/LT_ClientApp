import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, kDebugMode;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/transcript_message.dart';
import '../cookie_utils.dart';
import '../language_names.dart';

// Conditional import: use dart:html on web, stub elsewhere
import 'package:asr_live_translator/web_stub.dart'
    if (dart.library.html) 'dart:html' as html;

class LiveTranscriptScreen extends StatefulWidget {
  final String resolvedUrl;
  final String? originalUrl;

  /// True when we arrive from the auth screen; prevents an auth redirect loop.
  final bool authAttempted;

  const LiveTranscriptScreen({
    super.key,
    required this.resolvedUrl,
    this.originalUrl,
    this.authAttempted = false,
  });

  @override
  State<LiveTranscriptScreen> createState() => _LiveTranscriptScreenState();
}

class _LiveTranscriptScreenState extends State<LiveTranscriptScreen> {
  String? _selectedLanguage;
  final Set<String> _availableLanguages = {};
  final Map<String, TranscriptMessage> _messagesMap = {};

  /// Language name per KIT sender ("mt:1" → "German"), asked from the
  /// server once per sender – see _lookupSenderLanguage.
  final Map<String, Future<String?>> _senderLookups = {};

  /// Set when KIT announces the end of the lecture ("controll": "END").
  bool _sessionEnded = false;

  WebSocketChannel? _channel;
  StreamSubscription? _sseSubscription;
  bool _isConnected = false;
  String? _errorMessage;
  bool _isConnecting = false;
  int _reconnectAttempts = 0;
  bool _reconnectScheduled = false;

  final ScrollController _scrollController = ScrollController();

  // Audio player for non-web (mobile/desktop)
  final AudioPlayer _audioPlayer = AudioPlayer();

  String? _playingKey;
  bool _isAudioPlaying = false;
  final Map<String, double> _progressMap = {};
  final Map<String, Duration> _durationMap = {};

  final http.Client _httpClient = http.Client();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  String? _sseSessionId;
  String? _baseUrl;
  String? _cookieString; // used for non-web fallback
  bool _redirectingToAuth = false;

  // ============================================================
  //  Convert raw PCM to WAV (for non-web)
  // ============================================================
  Uint8List _pcmToWav(Uint8List pcmData, {int sampleRate = 16000, int numChannels = 1, int bitsPerSample = 16}) {
    final int subChunk2Size = pcmData.length;
    final int chunkSize = 36 + subChunk2Size;
    final Uint8List wavBytes = Uint8List(44 + subChunk2Size);
    final ByteData data = ByteData.sublistView(wavBytes);
    int offset = 0;

    data.setUint32(offset, 0x46464952, Endian.little);
    offset += 4;
    data.setUint32(offset, chunkSize, Endian.little);
    offset += 4;
    data.setUint32(offset, 0x45564157, Endian.little);
    offset += 4;

    data.setUint32(offset, 0x20746d66, Endian.little);
    offset += 4;
    data.setUint32(offset, 16, Endian.little);
    offset += 4;
    data.setUint16(offset, 1, Endian.little);
    offset += 2;
    data.setUint16(offset, numChannels, Endian.little);
    offset += 2;
    data.setUint32(offset, sampleRate, Endian.little);
    offset += 4;
    final int byteRate = sampleRate * numChannels * (bitsPerSample ~/ 8);
    data.setUint32(offset, byteRate, Endian.little);
    offset += 4;
    data.setUint16(offset, numChannels * (bitsPerSample ~/ 8), Endian.little);
    offset += 2;
    data.setUint16(offset, bitsPerSample, Endian.little);
    offset += 2;

    data.setUint32(offset, 0x61746164, Endian.little);
    offset += 4;
    data.setUint32(offset, subChunk2Size, Endian.little);
    offset += 4;

    wavBytes.setRange(offset, offset + pcmData.length, pcmData);
    return wavBytes;
  }

  /// /webapi/stream/data answers with JSON that carries the audio as base64
  /// 16-bit PCM (a bare JSON string or an object with the data in a field).
  /// Falls back to raw PCM if the answer isn't JSON.
  ({Uint8List pcm, int? sampleRate}) _decodeAudioResponse(http.Response response) {
    final type = response.headers['content-type'] ?? '';
    if (!type.contains('json')) {
      return (pcm: response.bodyBytes, sampleRate: null);
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    String? b64;
    int? rate;
    if (decoded is String) {
      b64 = decoded;
    } else if (decoded is Map) {
      final known = decoded['b64_enc_pcm_s16le'] ?? decoded['data'] ?? decoded['audio'];
      if (known is String) b64 = known;
      // Otherwise the longest text value is the audio.
      b64 ??= decoded.values.whereType<String>().fold<String?>(
          null, (best, s) => best == null || s.length > best.length ? s : best);
      final r = decoded['sample_rate'] ?? decoded['sampleRate'] ?? decoded['sr'];
      if (r is num) rate = r.toInt();
    }
    if (b64 == null || b64.isEmpty) {
      throw const FormatException('No audio data found in the JSON answer');
    }
    if (b64.startsWith('data:') && b64.contains(',')) {
      b64 = b64.substring(b64.indexOf(',') + 1);
    }
    return (pcm: base64Decode(base64.normalize(b64.trim())), sampleRate: rate);
  }

  @override
  void initState() {
    super.initState();
    if (kDebugMode) debugPrint('🔗 SSE URL: ${widget.resolvedUrl}');
    _baseUrl = widget.originalUrl != null
        ? Uri.parse(widget.originalUrl!).origin
        : Uri.parse(widget.resolvedUrl).origin;
    debugPrint('🏠 Base URL: $_baseUrl');

    _initSession();
    _setupAudioListeners();
  }

  // ========== Close session ==========
  Future<void> _closeSession({bool showConfirmation = true}) async {
    if (showConfirmation) {
      final confirm = await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Leave session?'),
          content: const Text('You will be disconnected and return to the session list.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Stay')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Leave')),
          ],
        ),
      );
      if (confirm != true) return;
    }
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _reconnectScheduled = false;
    await _audioPlayer.stop();
    if (mounted) Navigator.pop(context);
  }

  /// The silent-auth screen uses webview_flutter, which only exists on
  /// Android, iOS and macOS. Elsewhere we skip it instead of crashing.
  bool get _webViewSupported {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return true;
      default:
        return false;
    }
  }

  /// Opens the WebView auth screen. Only called after the server has actually
  /// refused us (HTTP 401/403), and at most once per visit, so it can't loop.
  /// Returns true if we navigated away.
  bool _goToAuth() {
    if (!_webViewSupported ||
        widget.authAttempted ||
        widget.originalUrl == null ||
        _redirectingToAuth ||
        !mounted) {
      return false;
    }
    _redirectingToAuth = true;
    Navigator.pushReplacementNamed(
      context,
      '/auth',
      arguments: {'originalUrl': widget.originalUrl!, 'resolvedUrl': widget.resolvedUrl},
    );
    return true;
  }

  /// Stores cookies from a `Set-Cookie` header (name=value pairs only),
  /// merged with what we already have.
  Future<void> _storeSetCookie(String? setCookieHeader) async {
    final fresh = parseSetCookieHeader(setCookieHeader);
    if (fresh.isEmpty) return;
    _cookieString = mergeCookieHeaders(_cookieString, fresh);
    try {
      await _secureStorage.write(key: 'cookies', value: _cookieString);
    } catch (e) {
      debugPrint('⚠️ Could not persist cookies: $e');
    }
    debugPrint('🍪 Stored cookie: $_cookieString');
  }

  void _setupAudioListeners() {
    // For non-web player
    _audioPlayer.onPositionChanged.listen((Duration position) {
      if (!mounted || _playingKey == null) return;
      final duration = _durationMap[_playingKey];
      if (duration != null && duration.inMilliseconds > 0) {
        setState(() => _progressMap[_playingKey!] = position.inMilliseconds / duration.inMilliseconds);
      }
    });
    _audioPlayer.onDurationChanged.listen((Duration duration) {
      if (_playingKey != null && mounted) {
        setState(() => _durationMap[_playingKey!] = duration);
      }
    });
    _audioPlayer.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        if (_playingKey != null) _progressMap[_playingKey!] = 1.0;
        _playingKey = null;
        _isAudioPlaying = false;
      });
    });
    _audioPlayer.onPlayerStateChanged.listen((PlayerState state) {
      if (!mounted) return;
      setState(() {
        _isAudioPlaying = state == PlayerState.playing;
        if (state == PlayerState.completed || state == PlayerState.stopped) {
          _playingKey = null;
        }
      });
    });
  }

  Future<void> _initSession() async {
    // Reuse cookies from an earlier visit or from the auth screen.
    if (!kIsWeb) {
      try {
        final stored = await _secureStorage.read(key: 'cookies');
        if (stored != null && stored.isNotEmpty) _cookieString = stored;
      } catch (e) {
        debugPrint('⚠️ Could not read stored cookies: $e');
      }
    }

    final status = await _fetchSessionPage();
    if ((status == 401 || status == 403) && _goToAuth()) return;
    _connect(widget.resolvedUrl);
  }

  /// Loads the session page once: stores its cookies and returns its HTTP
  /// status (null if it failed), so a 401/403 can open the login screen.
  /// Language names are NOT in this page's HTML – the page asks the server
  /// per sender, and so does this app (see _lookupSenderLanguage).
  Future<int?> _fetchSessionPage() async {
    if (widget.originalUrl == null || !widget.originalUrl!.startsWith('http')) return null;
    try {
      final headers = _browserHeaders();
      if (!kIsWeb && _cookieString != null && _cookieString!.isNotEmpty) {
        headers['Cookie'] = _cookieString!;
      }
      final response = await _httpClient.get(
        Uri.parse(widget.originalUrl!),
        headers: headers,
      );
      if (!kIsWeb) await _storeSetCookie(response.headers['set-cookie']);
      return response.statusCode;
    } catch (e) {
      debugPrint('Could not load the session page: $e');
      return null;
    }
  }

  Map<String, String> _browserHeaders() {
    const accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8';
    if (kIsWeb) {
      // Browsers refuse to let scripts set User-Agent, Cookie, Referer,
      // Origin, Connection etc.; they add those themselves.
      return {'Accept': accept};
    }
    // No Accept-Encoding: Dart's HttpClient adds gzip itself and decodes it,
    // but it cannot decode brotli ("br"), which we used to advertise.
    return {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
      'Accept': accept,
      'Accept-Language': 'en-US,en;q=0.5',
      'Upgrade-Insecure-Requests': '1',
    };
  }

  // ========== Reconnect ==========
  /// [manual] is true when the user taps Retry: that starts a fresh round of
  /// attempts. Automatic reconnects keep counting so the limit can be reached.
  void _reconnect({bool manual = false}) {
    if (!mounted) return;
    _reconnectScheduled = false;
    if (manual) {
      _reconnectAttempts = 0;
      _sessionEnded = false;
    }
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _sseSubscription = null;
    setState(() {
      _messagesMap.clear();
      _selectedLanguage = null;
      _errorMessage = null;
      _isConnected = false;
      _isConnecting = true;
      _playingKey = null;
      _isAudioPlaying = false;
      _progressMap.clear();
      _durationMap.clear();
      _sseSessionId = null;
    });
    _connect(widget.resolvedUrl);
  }

  void _connect(String url) {
    if (!mounted) return;
    setState(() {
      _errorMessage = null;
      _isConnected = false;
      _isConnecting = true;
      _messagesMap.clear();
      _selectedLanguage = null;
      _playingKey = null;
      _isAudioPlaying = false;
      _progressMap.clear();
      _durationMap.clear();
      _sseSessionId = null;
    });
    if (url.startsWith('http://') || url.startsWith('https://')) {
      _connectSSE(url);
    } else {
      _connectWebSocket(url);
    }
  }

  void _scheduleReconnect() {
    if (_reconnectScheduled) return;
    if (_sessionEnded) {
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _errorMessage = 'The session has ended.';
        });
      }
      return;
    }
    if (_reconnectAttempts >= 3) {
      debugPrint('❌ Max reconnect attempts reached. Showing Retry button.');
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _errorMessage = 'Connection lost. Please tap Retry.';
        });
      }
      return;
    }
    _reconnectAttempts++;
    final delay = Duration(seconds: _reconnectAttempts * 2);
    debugPrint('🔄 Scheduling reconnect attempt $_reconnectAttempts in ${delay.inSeconds}s');
    _reconnectScheduled = true;
    Future.delayed(delay, () {
      _reconnectScheduled = false;
      if (mounted && !_isConnected) _reconnect();
    });
  }

  void _connectSSE(String url) {
    debugPrint('🔗 Connecting to SSE: $url');
    final headers = {
      ..._browserHeaders(),
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache',
    };
    if (!kIsWeb) {
      if (widget.originalUrl != null) {
        headers['Referer'] = widget.originalUrl!;
        headers['Origin'] = _baseUrl!;
      }
      if (_cookieString != null && _cookieString!.isNotEmpty) {
        headers['Cookie'] = _cookieString!;
      }
    }
    _httpClient.send(http.Request('GET', Uri.parse(url))..headers.addAll(headers))
        .then((response) {
      if ((response.statusCode == 401 || response.statusCode == 403) && _goToAuth()) {
        response.stream.listen(null).cancel(); // release the connection
        return;
      }
      if (response.statusCode != 200) throw Exception('Server returned HTTP ${response.statusCode}');
      final stream = response.stream.transform(utf8.decoder);
      String buffer = '';
      StreamSubscription<String> subscription;
      subscription = stream.listen((String chunk) {
        buffer += chunk;
        // Normalize CRLF / CR line endings to LF. A trailing \r is kept,
        // because it may be the first half of a \r\n split across chunks.
        buffer = buffer.replaceAll(RegExp(r'\r\n|\r(?!$)'), '\n');
        final events = buffer.split('\n\n');
        if (events.length > 1) {
          buffer = events.removeLast();
          for (final eventBlock in events) {
            _parseSSEEvent(eventBlock);
          }
        }
      }, onError: (error) {
        debugPrint('❌ SSE stream error: $error');
        if (!mounted) return;
        setState(() {
          _errorMessage = 'SSE error: $error';
          _isConnected = false;
          _isConnecting = false;
        });
        _scheduleReconnect();
      }, onDone: () {
        debugPrint('🔌 SSE disconnected');
        if (!mounted) return;
        setState(() {
          _isConnected = false;
          _isConnecting = false;
        });
        _scheduleReconnect();
      });
      _sseSubscription = subscription;
      if (!mounted) return;
      setState(() {
        _isConnected = true;
        _isConnecting = false;
      });
    }).catchError((error) {
      debugPrint('❌ Failed to connect SSE: $error');
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to connect: $error';
        _isConnected = false;
        _isConnecting = false;
      });
      _scheduleReconnect();
    });
  }

  void _parseSSEEvent(String eventBlock) {
    debugPrint('📦 Full SSE event block:\n$eventBlock');
    String eventName = '';
    final dataBuffer = StringBuffer();
    for (final line in eventBlock.split('\n')) {
      if (line.startsWith('event:')) {
        eventName = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataBuffer.writeln(line.substring(5).trim());
      }
    }
    final data = dataBuffer.toString().trim();
    if (data.isEmpty) return;
    try {
      final json = jsonDecode(data);
      if (json is! Map<String, dynamic>) return;
      // KIT can tag a message with its stream via the SSE event name.
      if (eventName.isNotEmpty && eventName != 'message') {
        json.putIfAbsent('_channel', () => eventName);
      }
      _handleMessage(json);
    } catch (e) {
      debugPrint('⚠️ Failed to parse SSE data: $e');
    }
  }

  Future<void> _connectWebSocket(String url) async {
    debugPrint('🔗 Connecting to WebSocket: $url');
    final WebSocketChannel channel;
    try {
      channel = WebSocketChannel.connect(Uri.parse(url));
      _channel = channel;
      // Wait for the handshake before reporting the connection as live.
      await channel.ready;
    } catch (e) {
      debugPrint('❌ Failed to connect WebSocket: $e');
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to connect: $e';
        _isConnected = false;
        _isConnecting = false;
      });
      _scheduleReconnect();
      return;
    }

    if (!mounted) {
      channel.sink.close();
      return;
    }

    channel.stream.listen(
      (data) async {
        try {
          final Map<String, dynamic> json = data is String ? jsonDecode(data) : data as Map<String, dynamic>;
          await _handleMessage(json);
        } catch (e) {
          debugPrint('⚠️ WebSocket parse error: $e');
        }
      },
      onError: (error) {
        debugPrint('❌ WebSocket error: $error');
        if (!mounted) return;
        setState(() {
          _errorMessage = 'WebSocket error: $error';
          _isConnected = false;
          _isConnecting = false;
        });
        _scheduleReconnect();
      },
      onDone: () {
        debugPrint('🔌 WebSocket disconnected');
        if (!mounted) return;
        setState(() {
          _isConnected = false;
          _isConnecting = false;
        });
        _scheduleReconnect();
      },
    );

    setState(() {
      _isConnected = true;
      _isConnecting = false;
    });
  }

  /// Asks the server which language a stream is, exactly like KIT's own
  /// session page does the first time it sees a sender:
  ///   POST /webapi/<session>/<number after the colon>/get_output_language_component
  ///   body: "{\"component\":\"mt:1\"}"   (JSON encoded twice)
  ///   answer: German                        (plain text)
  /// One request per sender; all its messages share the answer.
  Future<String?> _lookupSenderLanguage(String sender) {
    final parts = sender.split(':');
    final channel =
        Uri.tryParse(widget.resolvedUrl)?.queryParameters['channel'] ?? _sseSessionId;
    if (parts.length < 2 || parts[1].isEmpty || channel == null || _baseUrl == null) {
      return Future.value(null);
    }
    final url = '$_baseUrl/webapi/$channel/${parts[1]}/get_output_language_component';
    return _senderLookups.putIfAbsent(sender, () => _askServerForLanguage(sender, url));
  }

  Future<String?> _askServerForLanguage(String sender, String url) async {
    try {
      final headers = <String, String>{'Content-Type': 'application/json;charset=UTF-8'};
      if (!kIsWeb && _cookieString != null && _cookieString!.isNotEmpty) {
        headers['Cookie'] = _cookieString!;
      }
      final resp = await _httpClient
          .post(
            Uri.parse(url),
            headers: headers,
            body: jsonEncode(jsonEncode({'component': sender})),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        debugPrint('❌ Language lookup for $sender: HTTP ${resp.statusCode}');
        _forgetLookup(sender); // try again with its next message
        return null;
      }
      var name = resp.body.trim();
      if (name.startsWith('"')) {
        try {
          name = jsonDecode(name) as String;
        } catch (_) {}
      }
      debugPrint('🌐 $sender → $name');
      return name.isEmpty ? null : name;
    } catch (e) {
      debugPrint('❌ Language lookup for $sender failed: $e');
      _forgetLookup(sender); // try again with its next message
      return null;
    }
  }

  /// Drops a failed lookup so the sender's next message asks again.
  /// Deferred, because it may run while the lookup is being stored.
  void _forgetLookup(String sender) =>
      Future.microtask(() => _senderLookups.remove(sender));

  /// Display name for a message's stream: "Transcript", "German", …
  /// Falls back to a tidied sender name while the server can't be asked.
  Future<String> _languageFor(String sender) async {
    final fromServer = await _lookupSenderLanguage(sender);
    return resolveLanguageName(fromServer ?? sender);
  }

  /// Adds a language to the dropdown (not "… Audio" / "… Correction").
  void _registerLanguage(String language) {
    if (language.isEmpty || language.contains('Audio') || language.contains('Correction')) {
      return;
    }
    if (_availableLanguages.add(language) && mounted) {
    }
  }

  String _cleanTranscript(String raw) => raw.replaceAll(RegExp(r'<[^>]*>'), ' ');

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  /// True if the audio field is a URL/path rather than inline base64 data.
  /// Base64 never contains ? . : & _ - and real PCM payloads are long.
  bool _looksLikeAudioUrl(String value) {
    if (value.startsWith('http://') || value.startsWith('https://')) return true;
    if (RegExp(r'[?.:&_\-]').hasMatch(value)) return true;
    return value.startsWith('/') && value.length < 300;
  }

  // ========== MAIN MESSAGE HANDLER ==========
  Future<void> _handleMessage(Map<String, dynamic> json) async {
    // Data is flowing, so the connection is healthy: reset the retry budget.
    _reconnectAttempts = 0;

    debugPrint('📩 JSON keys: ${json.keys}');
    debugPrint('🔍 sender: "${json["sender"]}"');

    final session = json['session'] as String?;
    if (session != null && session.isNotEmpty) {
      _sseSessionId = session;
      debugPrint('📌 Captured session ID: $_sseSessionId');
    }

    final String sender = (json['sender'] ?? '').toString();
    final isUnstable = json['unstable'] == true;

    // KIT announces the end of the lecture per stream; the ASR one counts.
    if ((json['controll'] ?? json['control']) == 'END' && sender.startsWith('asr')) {
      _sessionEnded = true;
    }

    // Headings, paragraph breaks and summaries – not transcript lines.
    if (RegExp(r'^(textstructurer|summar|lip|saasr|notes)').hasMatch(sender)) {
      return;
    }
    final start = json['start']?.toString() ?? '';

    // ============================================================
    // TTS MESSAGE HANDLER
    // ============================================================
    if (sender.startsWith('tts:')) {
      final text = json['text'] as String?;
      if (text == null || text.trim().isEmpty) {
        debugPrint('⏭️ Skipping TTS with empty text');
        return;
      }
      final transcriptText = _cleanTranscript(text);

      // tts:N speaks the output of mt:N; the server names its language.
      final String language = await _languageFor(sender);
      _registerLanguage(language);

      // Audio fetching
      Uint8List? audioBytes;
      String? audioUrl;
      final audioField = (json['b64_enc_pcm_s16le'] as String?)?.trim();
      // KIT sends no rate for raw TTS PCM; 24 kHz is what its voices use
      // (same default as the Flask relay).
      final sampleRate = (json['sample_rate'] as num?)?.toInt() ?? 24000;
      if (audioField != null && audioField.isNotEmpty && !_looksLikeAudioUrl(audioField)) {
        // Inline audio: base64-encoded 16-bit little-endian PCM.
        try {
          final pcm = base64Decode(audioField);
          audioBytes = _pcmToWav(pcm, sampleRate: sampleRate);
          debugPrint('✅ Decoded inline audio: ${audioBytes.length} bytes');
        } catch (e) {
          debugPrint('❌ Could not decode inline audio: $e');
        }
      } else if (audioField != null && audioField.isNotEmpty) {
        // The message links audio under /ltapi/ (internal, needs a login).
        // KIT's public page fetches the same data under /webapi/ – no login.
        final path = audioField.replaceFirst('/ltapi/', '/webapi/');
        final fullUrl = path.startsWith('http') ? path : '$_baseUrl$path';
        debugPrint('🎵 Audio URL: $fullUrl');
        try {
          final headers = _browserHeaders();
          if (!kIsWeb) headers['Referer'] = widget.originalUrl ?? _baseUrl!;
          final response = await _httpClient
              .get(Uri.parse(fullUrl), headers: headers)
              .timeout(const Duration(seconds: 15));
          if (response.statusCode == 200) {
            final audio = _decodeAudioResponse(response);
            audioBytes = _pcmToWav(audio.pcm, sampleRate: audio.sampleRate ?? sampleRate);
            debugPrint('✅ Audio ready: ${audioBytes.length} bytes');
          } else {
            audioUrl = fullUrl; // fallback: web opens the link in a tab
            debugPrint('❌ Failed to fetch audio: HTTP ${response.statusCode}');
          }
        } catch (e) {
          audioUrl = fullUrl;
          debugPrint('❌ Error loading audio: $e');
        }
      }

      // Merge with existing transcript of same language and text
      String key = '';
      bool foundMatch = false;
      final trimmedText = transcriptText.trim();
      for (final entry in _messagesMap.entries) {
        final msg = entry.value;
        if (msg.language == language && msg.transcript.trim() == trimmedText) {
          // Found matching transcript → attach audio to it
          key = entry.key;
          // Create a new message with the same data plus the audio
          final updatedMsg = TranscriptMessage(
            transcript: msg.transcript,
            translations: msg.translations,
            timestamp: msg.timestamp,
            language: msg.language,
            isUnstable: msg.isUnstable,
            // Don't wipe audio we already have if this download failed.
            audioData: audioBytes ?? msg.audioData,
            audioUrl: audioUrl ?? msg.audioUrl,
          );
          _messagesMap[key] = updatedMsg;
          foundMatch = true;
          debugPrint('🔗 Attached TTS audio to existing transcript: $key');
          break;
        }
      }

      if (!foundMatch) {
        // No match → create a new message with the correct language
        key = 'tts_${json['message_id'] ?? DateTime.now().millisecondsSinceEpoch}';
        _messagesMap[key] = TranscriptMessage(
          transcript: transcriptText,
          translations: {},
          timestamp: DateTime.now(),
          language: language,
          isUnstable: false,
          audioData: audioBytes,
          audioUrl: audioUrl,
        );
        debugPrint('🆕 Created new TTS message with language: $language');
      }

      if (!mounted) return;
      setState(() {
        _isConnected = true;
        _isConnecting = false;
      });
      _scrollToBottom();
      return;
    }

    // ============================================================
    // NON-TTS MESSAGE
    // ============================================================
    String transcriptText = (json['text'] ?? json['seq'] ?? '').toString().trim();
    transcriptText = _cleanTranscript(transcriptText);
    if (transcriptText.isEmpty) {
      debugPrint('⏭️ Skipping message with empty text/seq');
      return;
    }

    final language = await _languageFor(sender);
    _registerLanguage(language);

    String key;
    if (start.isNotEmpty) {
      key = '$sender|$start';
    } else {
      final textPrefix = transcriptText.length > 20 ? transcriptText.substring(0, 20) : transcriptText;
      key = '$sender|$textPrefix';
    }

    _messagesMap[key] = TranscriptMessage(
      transcript: transcriptText,
      translations: {},
      timestamp: DateTime.now(),
      language: language,
      isUnstable: isUnstable,
      audioData: null,
      audioUrl: null,
    );

    if (!mounted) return;
    setState(() {
      _isConnected = true;
      _isConnecting = false;
    });
    _scrollToBottom();
  }

  // ========== PLAY / PAUSE (SIMPLIFIED) ==========
  Future<void> _playPause(String key, TranscriptMessage message) async {
    if (kIsWeb && message.audioData == null) {
      // Web with a server URL: simply open the audio URL in a new tab
      if (message.audioUrl == null) {
        debugPrint('⚠️ No audio URL for web');
        return;
      }
      html.window.open(message.audioUrl!, '_blank');
      return;
    }

    // Non-web: use audioplayers
    if (_playingKey == key) {
      if (_isAudioPlaying) {
        await _audioPlayer.pause();
        if (!mounted) return;
        setState(() => _isAudioPlaying = false);
      } else {
        await _audioPlayer.resume();
        if (!mounted) return;
        setState(() => _isAudioPlaying = true);
      }
      return;
    }

    await _audioPlayer.stop();
    if (!mounted) return;
    setState(() {
      _playingKey = null;
      _isAudioPlaying = false;
    });

    if (message.audioData == null) {
      debugPrint('⚠️ No audio data for non-web');
      return;
    }

    try {
      if (kIsWeb) {
        // Inline audio on web: play it as a data: URL in the browser.
        await _audioPlayer.setSourceUrl('data:audio/wav;base64,${base64Encode(message.audioData!)}');
      } else {
        await _audioPlayer.setSourceBytes(message.audioData!);
      }
      await _audioPlayer.resume();
      if (!mounted) return;
      setState(() {
        _playingKey = key;
        _isAudioPlaying = true;
        _progressMap[key] = 0.0;
      });
    } catch (e) {
      debugPrint('Error playing audio: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Audio playback error: $e')),
      );
    }
  }

  Future<void> _scanNewQR() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('session_url');
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _reconnectScheduled = false;
    await _audioPlayer.stop();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, '/scan');
  }

  @override
  void dispose() {
    _reconnectScheduled = false;
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _sseSubscription = null;
    _audioPlayer.dispose();
    _scrollController.dispose();
    _httpClient.close();
    super.dispose();
  }

  // ========== BUILD ==========
  @override
  Widget build(BuildContext context) {
    final sortedKeys = _messagesMap.keys.toList()
      ..sort((a, b) => _messagesMap[a]!.timestamp.compareTo(_messagesMap[b]!.timestamp));

    final filteredKeys = sortedKeys.where((key) {
      final msg = _messagesMap[key]!;
      return _selectedLanguage == null ||
          msg.language.toLowerCase() == _selectedLanguage!.toLowerCase();
    }).toList();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (!didPop) await _closeSession(showConfirmation: true);
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => _closeSession(showConfirmation: true),
            tooltip: 'Leave session',
          ),
          title: const Text('Live Transcript'),
          actions: [
            if (_availableLanguages.isNotEmpty)
              DropdownButton<String>(
                value: _selectedLanguage,
                hint: const Text('All'), // Show 'All' when nothing selected
                items: _availableLanguages.map((lang) {
                  return DropdownMenuItem<String>(
                    value: lang,
                    child: Text(lang),
                  );
                }).toList(),
                onChanged: (newLang) => setState(() => _selectedLanguage = newLang),
              ),
            // Manual cookie override (for non‑web debugging)
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Set Cookie'),
                    content: TextField(
                      onChanged: (value) {
                        _cookieString = value;
                      },
                      decoration: const InputDecoration(labelText: 'Cookie string'),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () {
                          Navigator.pop(context);
                        },
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                );
              },
              tooltip: 'Manually set cookie (non‑web)',
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                if (value == 'scan') _scanNewQR();
              },
              itemBuilder: (context) => [
                const PopupMenuItem<String>(
                  value: 'scan',
                  child: Row(
                    children: [
                      Icon(Icons.qr_code_scanner),
                      SizedBox(width: 8),
                      Text('Scan new QR'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: _isConnected ? Colors.green.shade100 : Colors.red.shade100,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        _isConnected ? Icons.wifi : (_isConnecting ? Icons.wifi_lock : Icons.wifi_off),
                        color: _isConnected ? Colors.green : (_isConnecting ? Colors.orange : Colors.red),
                      ),
                      const SizedBox(width: 8),
                      Text(_isConnected ? 'Live connection' : (_isConnecting ? 'Connecting...' : 'Disconnected')),
                      if (_selectedLanguage != null) ...[
                        const SizedBox(width: 12),
                        Chip(
                          label: Text('Filter: $_selectedLanguage'),
                          backgroundColor: Colors.blue.shade100,
                          deleteIcon: const Icon(Icons.close, size: 16),
                          onDeleted: () => setState(() => _selectedLanguage = null),
                        ),
                      ],
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!_isConnected && !_isConnecting)
                        TextButton(onPressed: () => _reconnect(manual: true), child: const Text('Retry')),
                      TextButton.icon(
                        onPressed: () => _closeSession(showConfirmation: true),
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('Close'),
                        style: TextButton.styleFrom(foregroundColor: Colors.red),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
              ),
            Expanded(
              child: filteredKeys.isEmpty
                  ? Center(
                child: Text(
                  _messagesMap.isEmpty ? 'Waiting for transcript...' : 'No messages in $_selectedLanguage',
                ),
              )
                  : ListView.builder(
                controller: _scrollController,
                itemCount: filteredKeys.length,
                itemBuilder: (context, index) {
                  final key = filteredKeys[index];
                  final message = _messagesMap[key]!;
                  // For web: show play button if audioUrl exists
                  final hasAudio = kIsWeb
                      ? (message.audioUrl != null || message.audioData != null)
                      : message.audioData != null;

                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Text(
                              message.transcript,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                color: message.isUnstable ? Colors.grey : null,
                              ),
                            ),
                          ),
                          if (hasAudio) ...[
                            const SizedBox(width: 8),
                            IconButton(
                              style: IconButton.styleFrom(
                                backgroundColor: _playingKey == key && _isAudioPlaying
                                    ? Colors.orange.shade100
                                    : Colors.blue.shade100,
                                foregroundColor: _playingKey == key && _isAudioPlaying
                                    ? Colors.orange.shade900
                                    : Colors.blue.shade900,
                                padding: const EdgeInsets.all(6),
                                minimumSize: const Size(36, 36),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              icon: Icon(
                                _playingKey == key && _isAudioPlaying ? Icons.pause : Icons.play_arrow,
                                size: 22,
                              ),
                              onPressed: () => _playPause(key, message),
                            ),
                            // Show progress only for non-web (since web just opens in new tab)
                            if (message.audioData != null) ...[
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 60,
                                child: LinearProgressIndicator(
                                  value: _progressMap[key] ?? 0.0,
                                  backgroundColor: Colors.grey[300],
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _durationMap[key] != null ? '${_durationMap[key]!.inSeconds}s' : '',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
