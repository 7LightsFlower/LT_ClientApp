import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io' show File;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, kDebugMode;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import '../models/transcript_message.dart';
import '../cookie_utils.dart';
import '../language_names.dart';
import '../live_document.dart';
import '../live_export.dart';
import '../widgets/live_document_view.dart';
import '../widgets/session_qr_dialog.dart';
import 'session_selection_screen.dart' show SessionHistoryItem;
import 'package:share_plus/share_plus.dart';

// Conditional import: use dart:html on web, stub elsewhere
import '../web_stub.dart'
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

  /// Which stream should provide a language's text: the translation
  /// ("mt:6") or recognition ("asr:…") streams, before any other stream the
  /// server maps to the same language.
  static int _senderRank(String sender) {
    if (RegExp(r'^mt:\d+$').hasMatch(sender)) return 3;
    if (sender.startsWith('asr')) return 2;
    return 1;
  }

  /// Last message_id seen per stream (gap detection, like KIT's page).
  final Map<String, int> _senderIds = {};

  /// Set when KIT announces the end of the lecture ("controll": "END").
  bool _sessionEnded = false;

  /// Everything received, per language, in the Session Output layout
  /// (headings, paragraphs, summaries) – see live_document.dart.
  final LiveDocument _doc = LiveDocument();

  /// true: document view (like Session Output); false: one line per segment
  /// with the TTS play buttons.
  final bool _documentView = true;

  /// Title of exports: the session's name from the history list.
  String _sessionTitle = 'Live session';

  // ── Spoken translation in the document view: one player per language ──
  /// TTS parts per language, in arrival order.
  final Map<String, List<TtsPart>> _ttsParts = {};
  final AudioPlayer _ttsPlayer = AudioPlayer();
  StreamSubscription? _ttsCompleteSub;
  String? _ttsLanguage;
  int? _ttsIndex;
  bool _ttsPlaying = false;

  /// The current part has played to the end.
  bool _ttsPartFinished = false;

  /// Played everything received; continues with the next part on arrival.
  bool _ttsWaiting = false;

  /// Position in the part being played.
  Duration _ttsPosition = Duration.zero;

  /// While the user drags the progress slider (ms on the whole timeline).
  double? _seekDrag;

  /// Highlight cache: which segments the playing piece says.
  String? _spokenCacheId;
  Set<String> _spokenCache = const {};

  /// Settings panel under the top bar (audio, language, A−/A+), foldable.
  bool _panelOpen = true;

  /// Size of the running text, remembered between sessions.
  double _fontSize = 17;
  static const String _fontSizePref = 'live_font_size';

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

  /// Loads WAV bytes into [player] in a way every platform accepts.
  /// iOS/macOS (AVPlayer) must be told the format and is most reliable with
  /// a real .wav file; the web plays a data: URL.
  Future<void> _setWavSource(AudioPlayer player, Uint8List wav, String id) async {
    if (kIsWeb) {
      await player.setSourceUrl('data:audio/wav;base64,${base64Encode(wav)}');
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/tts_${id.hashCode.toUnsigned(32)}.wav');
      if (!await file.exists()) await file.writeAsBytes(wav, flush: true);
      await player.setSourceDeviceFile(file.path, mimeType: 'audio/wav');
      return;
    }
    await player.setSourceBytes(wav, mimeType: 'audio/wav');
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
    _loadSessionTitle();
    _ttsCompleteSub = _ttsPlayer.onPlayerComplete.listen((_) {
      _ttsPartFinished = true;
      _ttsNext(auto: true);
    });
    _ttsPlayer.onPositionChanged.listen((p) {
      if (mounted) setState(() => _ttsPosition = p);
    });
    _loadFontSize();
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
      _doc.clear();
      _senderIds.clear();
      _ttsParts.clear();
      _selectedLanguage = null;
      _playingKey = null;
      _isAudioPlaying = false;
      _progressMap.clear();
      _durationMap.clear();
      _sseSessionId = null;
    });
    _stopTts();
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
      setState(() {}); // show the new language in the dropdown
    }
  }

  String _cleanTranscript(String raw) => raw.replaceAll(RegExp(r'<[^>]*>'), ' ');

  void _scrollToBottom() {
    // Only follow the text while the reader is at the end; don't pull them
    // away when they have scrolled up to read something.
    if (_scrollController.hasClients) {
      final pos = _scrollController.position;
      if (pos.maxScrollExtent - pos.pixels > 400) return;
    }
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

  // ========== DOCUMENT VIEW (Session Output layout) ==========

  static double? _toDouble(Object? v) =>
      v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');

  static double _nowSeconds() => DateTime.now().millisecondsSinceEpoch / 1000.0;

  static int? _toInt(Object? v) => v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');

  // ── Spoken translation player (document view) ──

  List<TtsPart> _partsFor(String? language) =>
      language == null ? const [] : (_ttsParts[language] ?? const []);

  /// The part being played (or paused in), if any.
  TtsPart? get _currentTtsPart {
    final parts = _partsFor(_ttsLanguage);
    final i = _ttsIndex;
    if (i == null || i < 0 || i >= parts.length || _ttsPartFinished) return null;
    return parts[i];
  }

  /// Sample rate of the session's spoken pieces (KIT: 16 kHz).
  int _ttsSampleRate = 16000;

  /// Downloads running per piece, so a piece is fetched only once.
  final Map<String, Future<Uint8List?>> _ttsLoads = {};

  /// Counts play requests: a slow download must not start an older request.
  int _ttsPlayRequest = 0;

  /// The audio of a piece, downloaded on first use.
  Future<Uint8List?> _loadTtsAudio(TtsPart part) {
    final ready = part.audio;
    if (ready != null) return Future.value(ready);
    final url = part.audioUrl;
    if (url == null || part.failed) return Future.value(null);
    return _ttsLoads.putIfAbsent(part.key, () async {
      try {
        final headers = _browserHeaders();
        if (!kIsWeb) headers['Referer'] = widget.originalUrl ?? _baseUrl!;
        final response =
            await _httpClient.get(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) {
          debugPrint('❌ Audio $url: HTTP ${response.statusCode}');
          part.failed = true;
          return null;
        }
        final audio = _decodeAudioResponse(response);
        final wav = _pcmToWav(audio.pcm, sampleRate: audio.sampleRate ?? _ttsSampleRate);
        part.audio = wav;
        if (mounted) setState(() {}); // the real length replaces the estimate
        return wav;
      } catch (e) {
        debugPrint('❌ Audio $url: $e');
        part.failed = true;
        return null;
      } finally {
        _ttsLoads.remove(part.key);
      }
    });
  }

  Future<void> _playTtsAt(String language, int index, {Duration offset = Duration.zero}) async {
    final parts = _partsFor(language);
    if (index < 0 || index >= parts.length) return;
    final request = ++_ttsPlayRequest;
    try {
      await _audioPlayer.stop(); // the per-segment player of the list view
      final part = parts[index];
      if (part.audio == null && mounted) {
        // Show where we are while the piece downloads.
        setState(() {
          _ttsLanguage = language;
          _ttsIndex = index;
          _ttsPlaying = true;
          _ttsWaiting = false;
          _ttsPartFinished = false;
          _ttsPosition = Duration.zero;
        });
      }
      final wav = await _loadTtsAudio(part);
      if (request != _ttsPlayRequest || !mounted) return; // something else was asked for meanwhile
      if (wav == null) {
        // Could not be loaded: go on with the next piece.
        _ttsIndex = parts.indexOf(part);
        _ttsNext(auto: true);
        return;
      }
      await _ttsPlayer.stop();
      await _setWavSource(_ttsPlayer, wav, part.key);
      if (!mounted || request != _ttsPlayRequest) return;
      index = parts.indexOf(part); // pieces may have been inserted meanwhile
      setState(() {
        _ttsLanguage = language;
        _ttsIndex = index;
        _ttsPlaying = true;
        _ttsWaiting = false;
        _ttsPartFinished = false;
        _ttsPosition = Duration.zero;
      });
      await _ttsPlayer.resume();
      if (offset > Duration.zero) {
        await _ttsPlayer.seek(offset);
        if (mounted) setState(() => _ttsPosition = offset);
      }
      // Fetch the next piece while this one plays: no gap in between.
      if (index + 1 < parts.length) _loadTtsAudio(parts[index + 1]);
    } catch (e) {
      debugPrint('❌ TTS playback: $e');
      if (!mounted) return;
      setState(() => _ttsPlaying = false);
    }
  }

  /// Next part; at the end of what was received, wait for the next one
  /// (only when called automatically at the end of a part).
  void _ttsNext({bool auto = false}) {
    final lang = _ttsLanguage;
    final parts = _partsFor(lang);
    final next = (_ttsIndex ?? -1) + 1;
    if (lang != null && next < parts.length) {
      _playTtsAt(lang, next);
      return;
    }
    if (!mounted) return;
    setState(() {
      _ttsPlaying = false;
      _ttsWaiting = auto && !_sessionEnded;
    });
  }

  /// Play / pause. The first play starts with the newest part (live).
  Future<void> _ttsPlayPause(String language) async {
    if (_ttsPlaying) {
      _ttsPlayRequest++; // also cancels a piece that is still downloading
      await _ttsPlayer.pause();
      if (mounted) setState(() => _ttsPlaying = false);
      return;
    }
    if (_ttsWaiting) {
      setState(() => _ttsWaiting = false);
      return;
    }
    final parts = _partsFor(language);
    if (parts.isEmpty) return;
    if (_ttsLanguage == language && _ttsIndex != null) {
      if (_ttsPartFinished) {
        _ttsNext(auto: true); // next part, or wait for it
      } else {
        await _ttsPlayer.resume();
        if (mounted) setState(() => _ttsPlaying = true);
      }
      return;
    }
    _playTtsAt(language, parts.length - 1);
  }

  void _stopTts() {
    _ttsPlayRequest++; // a download still running must not start playing
    _ttsPlayer.stop();
    _ttsLanguage = null;
    _ttsIndex = null;
    _ttsPlaying = false;
    _ttsWaiting = false;
    _ttsPartFinished = false;
  }

  /// The original transcript has no spoken version.
  bool _isOriginal(String? language) =>
      language == null || language.toLowerCase().startsWith('transcript');

  bool get _audioOn => _ttsPlaying || _ttsWaiting;

  /// Speaker button in the top bar: audio on (live) / off.
  Future<void> _toggleAudio() async {
    final lang = _documentLanguage();
    if (lang == null || _isOriginal(lang)) return;
    if (_audioOn) {
      _ttsPlayRequest++; // also cancels a piece that is still downloading
      await _ttsPlayer.pause();
      if (mounted) {
        setState(() {
          _ttsPlaying = false;
          _ttsWaiting = false;
        });
      }
      return;
    }
    if (_partsFor(lang).isEmpty) {
      // Starts by itself as soon as the first piece arrives.
      setState(() {
        _ttsLanguage = lang;
        _ttsIndex = null;
        _ttsWaiting = true;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Waiting for audio. Play will be available once translation audio is buffered.'),
          duration: Duration(seconds: 3),
        ));
      return;
    }
    await _ttsPlayPause(lang);
  }

  Future<void> _loadFontSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getDouble(_fontSizePref);
      if (v != null && mounted) setState(() => _fontSize = v);
    } catch (_) {}
  }

  Future<void> _changeFontSize(double delta) async {
    final v = (_fontSize + delta).clamp(12.0, 34.0);
    setState(() => _fontSize = v);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_fontSizePref, v);
    } catch (_) {}
  }

  static String _mmss(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  /// Tap on a paragraph: play the first part that speaks it.
  void _onParagraphTap(DocBlock paragraph) {
    final lang = _documentLanguage();
    if (lang == null) return;
    final parts = _partsFor(lang);
    var i = parts.indexWhere((p) => paragraph.spans.any(p.speaksId));
    if (i < 0) {
      // Not found by id: by text.
      final content = _docFor(lang);
      final keys = {for (final s in paragraph.spans) s.key};
      i = parts.indexWhere((p) => spokenSpanKeys(content, p).any(keys.contains));
    }
    if (i >= 0) _playTtsAt(lang, i);
  }

  /// The document of a language, built again only when something changed
  /// (long sessions: building on every player tick would be slow).
  String? _docCacheId;
  DocContent _docCache = const DocContent([], []);
  DocContent _docFor(String language) {
    final id = '$language#${_doc.revision}';
    if (id != _docCacheId) {
      _docCacheId = id;
      _docCache = _doc.build(language);
    }
    return _docCache;
  }

  /// Segments the playing piece says (cached per piece and document change).
  Set<String> _spokenKeys(DocContent content, TtsPart part) {
    final id = '${part.key}#${_doc.revision}';
    if (id != _spokenCacheId) {
      _spokenCacheId = id;
      _spokenCache = spokenSpanKeys(content, part);
    }
    return _spokenCache;
  }

  // ── One timeline for all pieces of a language ──

  static Duration _sumDurations(Iterable<TtsPart> parts) =>
      parts.fold(Duration.zero, (a, p) => a + p.duration);

  /// Everything received so far, end to end.
  Duration _timelineLength(List<TtsPart> parts) => _sumDurations(parts);

  /// Where playback is on that timeline.
  Duration _timelinePosition(String? language, List<TtsPart> parts) {
    final i = _ttsIndex;
    if (language == null || _ttsLanguage != language || i == null || parts.isEmpty) {
      return Duration.zero;
    }
    final idx = i.clamp(0, parts.length - 1);
    final before = _sumDurations(parts.take(idx));
    if (_ttsPartFinished || _ttsWaiting) return before + parts[idx].duration;
    final pos = _ttsPosition > parts[idx].duration ? parts[idx].duration : _ttsPosition;
    return before + pos;
  }

  /// Jump to a point of the timeline: the piece there, from the right offset.
  void _seekTimeline(String language, List<TtsPart> parts, Duration to) {
    var rest = to;
    for (var i = 0; i < parts.length; i++) {
      final d = parts[i].duration;
      if (rest < d || i == parts.length - 1) {
        final offset = rest > d ? d : rest;
        if (_ttsLanguage == language && _ttsIndex == i && !_ttsPartFinished && !_ttsWaiting) {
          _ttsPlayer.seek(offset);
          if (!_ttsPlaying) {
            _ttsPlayer.resume();
            setState(() => _ttsPlaying = true);
          }
        } else {
          _playTtsAt(language, i, offset: offset);
        }
        return;
      }
      rest -= d;
    }
  }

  /// Speaker name, if KIT sends one ("speakerName": "…:Alice" or "Alice").
  static String? _speakerOf(Map<String, dynamic> json) {
    final raw = json['speakerName'] ?? json['speaker_name'];
    if (raw is! String || raw.trim().isEmpty) return null;
    final name = raw.split(':').last.trim();
    return name.isEmpty ? null : name;
  }

  /// Language of a structure stream: "textstructurer:0_de" → German,
  /// "…_mult57" (the multilingual one) → the original transcript's language.
  Future<String> _structureLanguage(String sender) async {
    final suffix = sender.contains('_') ? sender.substring(sender.lastIndexOf('_') + 1) : '';
    if (suffix.toLowerCase().startsWith('mult')) return _languageFor('asr:0');
    final byCode = languageNamesByCode[suffix.toLowerCase()];
    return byCode ?? resolveLanguageName(sender);
  }

  /// textstructurer / summarizer / notes: headings, paragraph breaks and
  /// summaries, placed by their start time into that language's document.
  Future<void> _handleStructureMessage(String sender, Map<String, dynamic> json) async {
    final markup = json['markup']?.toString();
    final text = (json['seq'] ?? json['text'] ?? '').toString();
    final action = (json['action'] ?? 'add').toString();
    if (markup == null) return;
    final language = await _structureLanguage(sender);
    // A global summary is updated, not added: one per stream. Everything else
    // is identified by start + end, as on KIT's page ("replace" / "remove").
    final key = markup == 'global_summary'
        ? '$sender|global_summary'
        : '$sender|$markup|${_timeKey(json['start'])}|${_timeKey(json['end'])}';
    if (action == 'remove') {
      _doc.remove(language, key);
      if (mounted) setState(() {});
      return;
    }
    if (text.trim().isEmpty && markup != 'paragraphBreak') return;
    _doc.upsert(
      language,
      key,
      start: markup == 'global_summary' ? 0.0 : (_toDouble(json['start']) ?? _nowSeconds()),
      kind: markup,
      text: text,
    );
    if (!mounted) return;
    setState(() {});
    if (_documentView) _scrollToBottom();
  }

  /// The language shown in the document view.
  String? _documentLanguage() {
    if (_selectedLanguage != null) return _selectedLanguage;
    final langs = _doc.languages;
    if (langs.isEmpty) return null;
    return langs.firstWhere((l) => l.toLowerCase().startsWith('transcript'), orElse: () => langs.first);
  }

  Future<void> _loadSessionTitle() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final entry in prefs.getStringList('session_history') ?? const <String>[]) {
        final item = SessionHistoryItem.tryParse(entry);
        if (item != null && item.url == widget.originalUrl && item.name.trim().isNotEmpty) {
          if (mounted) setState(() => _sessionTitle = item.name.trim());
          return;
        }
      }
    } catch (e) {
      debugPrint('Could not read the session name: $e');
    }
  }

  /// Export sheet: language + format, then share / save the file.
  Future<void> _showExportSheet() async {
    final languages = _doc.languages;
    if (languages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing to export yet.')),
      );
      return;
    }
    var language = _documentLanguage() ?? languages.first;
    var format = ExportFormat.docx;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Export transcript', style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: language,
                decoration: const InputDecoration(labelText: 'Language', border: OutlineInputBorder()),
                items: [for (final l in languages) DropdownMenuItem(value: l, child: Text(l))],
                onChanged: (v) => setSheet(() => language = v ?? language),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final f in ExportFormat.values)
                    ChoiceChip(
                      label: Text(f.label),
                      selected: format == f,
                      onSelected: (_) => setSheet(() => format = f),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'File: ${exportFileName(language, format)} · what was received so far',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Export'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _export(language, format);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _export(String language, ExportFormat format) async {
    try {
      final bytes = await buildExport(
        format,
        title: _sessionTitle,
        meta: exportMetaLine(language, _doc),
        content: _doc.build(language),
      );
      final name = exportFileName(language, format);
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(bytes, mimeType: format.mimeType, name: name)],
        fileNameOverrides: [name],
        subject: '$_sessionTitle – $language',
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.red),
      );
    }
  }

  // ========== MAIN MESSAGE HANDLER ==========
  /// A time as a key part. KIT compares times as numbers ("12.50" == 12.5),
  /// so "replace" / "remove" must find the piece however the time is written.
  static String _timeKey(Object? v) => _toDouble(v)?.toString() ?? '${v ?? ''}';

  /// KIT's page fetches the messages the stream skipped (corrections and
  /// removals among them) whenever a stream's message_id jumps. Same here.
  Future<void> _fetchSkipped(String sender, int from, int to) async {
    final channel =
        Uri.tryParse(widget.resolvedUrl)?.queryParameters['channel'] ?? _sseSessionId;
    if (channel == null || _baseUrl == null || from > to) return;
    try {
      final headers = <String, String>{'Content-Type': 'application/json;charset=UTF-8'};
      if (!kIsWeb && _cookieString != null && _cookieString!.isNotEmpty) {
        headers['Cookie'] = _cookieString!;
      }
      final resp = await _httpClient
          .post(
            Uri.parse('$_baseUrl/webapi/$channel/get_previous_messages'),
            headers: headers,
            body: jsonEncode(jsonEncode({'component': sender, 'begin': from, 'end': to})),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        debugPrint('❌ Skipped messages of $sender: HTTP ${resp.statusCode}');
        return;
      }
      final list = jsonDecode(utf8.decode(resp.bodyBytes));
      if (list is! List) return;
      debugPrint('↩️ $sender: fetched ${list.length} skipped messages ($from–$to)');
      for (final item in list) {
        final m = item is String ? jsonDecode(item) : item;
        if (m is Map<String, dynamic> && m['unstable'] != true) {
          await _handleMessage(m, skipped: true);
        }
      }
    } catch (e) {
      debugPrint('❌ Skipped messages of $sender: $e');
    }
  }

  Future<void> _handleMessage(Map<String, dynamic> json, {bool skipped = false}) async {
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

    // A gap in a text stream's message ids: fetch what was skipped first.
    final messageId = _toInt(json['message_id']);
    if (!skipped && messageId != null && sender.isNotEmpty && !RegExp(r'^(tts|lip)').hasMatch(sender)) {
      final last = _senderIds[sender];
      if (last == null || messageId > last + 1) {
        _senderIds[sender] = messageId;
        await _fetchSkipped(sender, (last ?? -1) + 1, messageId - 1);
      } else if (messageId > last) {
        _senderIds[sender] = messageId;
      }
    }

    // Headings, paragraph breaks, summaries, notes → the document view.
    if (RegExp(r'^(textstructurer|summar|notes)').hasMatch(sender)) {
      await _handleStructureMessage(sender, json);
      return;
    }
    if (RegExp(r'^(lip|saasr)').hasMatch(sender)) return;
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

      // Audio: inline audio is decoded right away; linked audio is only
      // downloaded when it is about to be played (long sessions replay every
      // piece – downloading them all would take minutes).
      Uint8List? audioBytes;
      String? audioUrl;
      final audioField = (json['b64_enc_pcm_s16le'] as String?)?.trim();
      // KIT sends no rate for raw TTS PCM. Its voices are 16 kHz: at that rate
      // the pieces have a natural speaking pace (24 kHz played 1.5× too fast).
      final sampleRate = (json['sample_rate'] as num?)?.toInt() ?? 16000;
      _ttsSampleRate = sampleRate;
      if (audioField != null && audioField.isNotEmpty && !_looksLikeAudioUrl(audioField)) {
        // Inline audio: base64-encoded 16-bit little-endian PCM.
        try {
          audioBytes = _pcmToWav(base64Decode(audioField), sampleRate: sampleRate);
        } catch (e) {
          debugPrint('❌ Could not decode inline audio: $e');
        }
      } else if (audioField != null && audioField.isNotEmpty) {
        // The message links audio under /ltapi/ (internal, needs a login).
        // KIT's public page fetches the same data under /webapi/ – no login.
        final path = audioField.replaceFirst('/ltapi/', '/webapi/');
        audioUrl = path.startsWith('http') ? path : '$_baseUrl$path';
      }

      // The language's player: keep the part, continue if it was waiting.
      if (audioBytes != null || audioUrl != null) {
        final parts = _ttsParts.putIfAbsent(language, () => []);
        final textSender = sender.replaceFirst('tts', 'mt'); // tts:N speaks mt:N
        _doc.preferSender(language.replaceFirst(RegExp(r'\s*Audio$'), ''), textSender); // show the text it reads
        final maxId = _toInt(json['max_message_id']);
        var minId = _toInt(json['min_message_id']);
        // KIT names only the LAST text message of a piece (min = max), but a
        // piece speaks everything since the previous piece: start right after
        // the previous piece's last message, so every sentence gets highlighted.
        if (maxId != null) {
          int? prevMax;
          for (final p in parts) {
            final m = p.maxId;
            if (p.textSender == textSender && m != null && m < maxId && (prevMax == null || m > prevMax)) {
              prevMax = m;
            }
          }
          if (prevMax != null && prevMax + 1 <= maxId) minId = prevMax + 1;
        }
        debugPrint('🔊 $sender id=${json['message_id']} '
            'min=${json['min_message_id']} max=${json['max_message_id']}: $transcriptText');
        final part = TtsPart(
          key: '$sender|${json['message_id']}|$maxId',
          audio: audioBytes,
          audioUrl: audioUrl,
          textSender: textSender,
          text: transcriptText,
          minId: minId,
          maxId: maxId,
        );
        // Downloads can finish out of order: keep the pieces in text order.
        var at = parts.length;
        if (maxId != null) {
          while (at > 0 && (parts[at - 1].maxId ?? -1) > maxId) {
            at--;
          }
        }
        parts.insert(at, part);
        if (_ttsLanguage == language && _ttsIndex != null && at <= _ttsIndex!) {
          _ttsIndex = _ttsIndex! + 1; // the piece playing moved one place down
        }
        if (_ttsWaiting && _ttsLanguage == language) {
          _ttsNext(auto: true); // continue with the next piece in order
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
            audioData: msg.audioData,
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
          audioData: null,
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
    // Sentence regrouping for speakers / summaries – KIT's page never shows it.
    if (json.containsKey('refined_sentence_cluster')) return;

    String transcriptText = (json['text'] ?? json['seq'] ?? '').toString().trim();
    transcriptText = _cleanTranscript(transcriptText);
    // Same rules as KIT's own page:
    //  • stable text is identified by start + end; "action" can be "add"
    //    (default), "replace" (new text for that start + end) or "remove";
    //  • unstable text is ONE grey tail per stream, overwritten by every
    //    unstable message and dropped when the next stable one arrives.
    final action = (json['action'] ?? 'add').toString();
    if (transcriptText.isEmpty && action == 'add' && !isUnstable) {
      debugPrint('⏭️ Skipping message with empty text/seq');
      return;
    }

    final language = await _languageFor(sender);
    _registerLanguage(language);

    // Two streams in one language would show every sentence twice: all are
    // kept, the document shows one (see LiveDocument.offerSender).
    _doc.offerSender(language, sender, _senderRank(sender));
    debugPrint('📝 $sender id=${json['message_id']} start=${json['start']} end=${json['end']} '
        '$action${isUnstable ? ' UNSTABLE' : ''}: $transcriptText');

    final unstableKey = '$sender|unstable';
    if (!isUnstable) _doc.remove(language, unstableKey);

    String key;
    if (isUnstable) {
      key = unstableKey;
    } else if (start.isNotEmpty) {
      key = '$sender|${_timeKey(json['start'])}|${_timeKey(json['end'])}';
    } else {
      final textPrefix = transcriptText.length > 20 ? transcriptText.substring(0, 20) : transcriptText;
      key = '$sender|$textPrefix';
    }

    if (action == 'remove' || (isUnstable && transcriptText.isEmpty)) {
      _doc.remove(language, key);
      _messagesMap.remove(key);
      if (mounted) setState(() {});
      return;
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
    _doc.upsert(
      language,
      key,
      start: _toDouble(json['start']) ?? _nowSeconds(),
      end: _toDouble(json['end']),
      kind: 'text',
      text: transcriptText,
      unstable: isUnstable,
      speaker: _speakerOf(json),
      sender: sender,
      messageId: _toInt(json['message_id']),
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

    if (_ttsPlaying) {
      _ttsPlayRequest++; // also cancels a piece that is still downloading
      await _ttsPlayer.pause();
      if (mounted) setState(() => _ttsPlaying = false);
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
      await _setWavSource(_audioPlayer, message.audioData!, key);
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

  @override
  void dispose() {
    _reconnectScheduled = false;
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _sseSubscription = null;
    _audioPlayer.dispose();
    _ttsCompleteSub?.cancel();
    _ttsPlayer.dispose();
    _scrollController.dispose();
    _httpClient.close();
    super.dispose();
  }

  /// Foldable panel: audio progress (languages with speech), language, A−/A+.
  Widget _buildPanel(String? docLanguage, List<TtsPart> docParts) {
    final theme = Theme.of(context);
    final languages = <String>{..._availableLanguages, ..._doc.languages}.toList();
    final showAudio = !_isOriginal(docLanguage) && (docParts.isNotEmpty || _audioOn);
    // One growing timeline: the pieces already played stay on it.
    final total = _timelineLength(docParts).inMilliseconds.toDouble();
    final played = _timelinePosition(docLanguage, docParts).inMilliseconds.toDouble();
    final pos = (_seekDrag ?? played).clamp(0.0, total > 0 ? total : 0.0);

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showAudio)
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: total > 0 ? pos / total : 0,
                      onChanged: total > 0 && docLanguage != null
                          ? (v) => setState(() => _seekDrag = v * total)
                          : null,
                      onChangeEnd: total > 0 && docLanguage != null
                          ? (v) {
                              setState(() => _seekDrag = null);
                              _seekTimeline(docLanguage, docParts,
                                  Duration(milliseconds: (v * total).round()));
                            }
                          : null,
                    ),
                  ),
                  Text(
                    '${_mmss(Duration(milliseconds: pos.round()))} / '
                    '${_mmss(Duration(milliseconds: total.round()))}',
                    style: theme.textTheme.titleSmall,
                  ),
                ],
              ),
            if (languages.isNotEmpty && docLanguage != null)
              InputDecorator(
                decoration: const InputDecoration(labelText: 'Language'),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: docLanguage,
                    isExpanded: true,
                    isDense: true,
                    style: theme.textTheme.titleLarge,
                    items: [
                      for (final l in languages) DropdownMenuItem(value: l, child: Text(l)),
                    ],
                    onChanged: (l) => setState(() {
                      if (l != docLanguage) _stopTts();
                      _selectedLanguage = l;
                    }),
                  ),
                ),
              ),
            Row(
              children: [
                TextButton(
                  onPressed: _fontSize > 12 ? () => _changeFontSize(-2) : null,
                  child: const Text('A−', style: TextStyle(fontSize: 18)),
                ),
                TextButton(
                  onPressed: _fontSize < 34 ? () => _changeFontSize(2) : null,
                  child: const Text('A+', style: TextStyle(fontSize: 18)),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.ios_share),
                  tooltip: 'Export transcript (TXT, DOCX, RTF, PDF)',
                  onPressed: _showExportSheet,
                ),
              ],
            ),
          ],
        ),
      ),
    );
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

    final docLanguage = _documentView ? _documentLanguage() : null;
    final spokenPart = (_documentView && _ttsLanguage == docLanguage) ? _currentTtsPart : null;
    final docParts = _partsFor(docLanguage);
    final docContent = docLanguage == null ? const DocContent([], []) : _docFor(docLanguage);
    final spokenKeys = spokenPart == null ? null : _spokenKeys(docContent, spokenPart);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (!didPop) await _closeSession(showConfirmation: true);
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new),
            onPressed: () => _closeSession(showConfirmation: true),
            tooltip: 'Leave session',
          ),
          title: Text(_sessionTitle, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              icon: const Icon(Icons.qr_code_2),
              tooltip: 'Show QR code to share this session',
              onPressed: () => showSessionQrDialog(
                context,
                link: widget.originalUrl ?? widget.resolvedUrl,
                title: _sessionTitle,
              ),
            ),
            IconButton(
              icon: Icon(_audioOn ? Icons.volume_up : Icons.volume_off),
              tooltip: _isOriginal(docLanguage)
                  ? 'The original has no spoken version'
                  : (_audioOn ? 'Audio off' : 'Listen to the spoken translation'),
              onPressed: _isOriginal(docLanguage) ? null : _toggleAudio,
            ),
            IconButton(
              icon: Icon(_panelOpen ? Icons.expand_less : Icons.expand_more),
              tooltip: _panelOpen ? 'Hide settings' : 'Show settings',
              onPressed: () => setState(() => _panelOpen = !_panelOpen),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_panelOpen) _buildPanel(docLanguage, docParts),
            // Only shown when something is wrong; a live connection needs no bar.
            if (!_isConnected || _errorMessage != null)
              Container(
                width: double.infinity,
                color: _isConnecting
                    ? Theme.of(context).colorScheme.surfaceContainerHighest
                    : Theme.of(context).colorScheme.errorContainer,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    if (_isConnecting)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      const Icon(Icons.wifi_off, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _isConnecting ? 'Connecting…' : (_errorMessage ?? 'Disconnected'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!_isConnected && !_isConnecting)
                      TextButton(
                        onPressed: () => _reconnect(manual: true),
                        child: const Text('Retry'),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: _documentView
                  ? LiveDocumentView(
                      content: docContent,
                      controller: _scrollController,
                      isSpoken: spokenKeys == null ? null : (s) => spokenKeys.contains(s.key),
                      spokenToken: spokenPart?.key,
                      onParagraphTap: _partsFor(docLanguage).isEmpty ? null : _onParagraphTap,
                      fontSize: _fontSize,
                    )
                  : filteredKeys.isEmpty
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
