import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, kDebugMode;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/transcript_message.dart';

// Conditional import: use dart:html on web, stub elsewhere
import 'package:asr_live_translator/web_stub.dart'
    if (dart.library.html) 'dart:html' as html;

class LiveTranscriptScreen extends StatefulWidget {
  final String resolvedUrl;
  final String? originalUrl;

  const LiveTranscriptScreen({
    super.key,
    required this.resolvedUrl,
    this.originalUrl,
  });

  @override
  State<LiveTranscriptScreen> createState() => _LiveTranscriptScreenState();
}

class _LiveTranscriptScreenState extends State<LiveTranscriptScreen> {
  String? _selectedLanguage;
  final Set<String> _availableLanguages = {};
  final Map<String, TranscriptMessage> _messagesMap = {};
  bool _defaultFilterSet = false;

  Map<String, String>? _senderToLanguage;

  WebSocketChannel? _channel;
  StreamSubscription? _sseSubscription;
  bool _isConnected = false;
  String? _errorMessage;
  bool _isConnecting = false;
  int _reconnectAttempts = 0;
  bool _reconnectScheduled = false;

  CollectionReference? _transcriptsRef;
  String _sessionId = '';

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

  bool get _isDesktop {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return true;
      default:
        return false;
    }
  }

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

  @override
  void initState() {
    super.initState();
    _checkAuth();
    if (kDebugMode) print('🔗 SSE URL: ${widget.resolvedUrl}');
    _baseUrl = widget.originalUrl != null
        ? Uri.parse(widget.originalUrl!).origin
        : Uri.parse(widget.resolvedUrl).origin;
    debugPrint('🏠 Base URL: $_baseUrl');

    _initFirebaseAndSession();
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

  Future<void> _checkAuth() async {
    if (kIsWeb) return;
    final cookies = await _secureStorage.read(key: 'cookies');
    if (cookies == null || cookies.isEmpty) {
      if (mounted && widget.originalUrl != null) {
        Navigator.pushReplacementNamed(
          context,
          '/auth',
          arguments: {'originalUrl': widget.originalUrl!, 'resolvedUrl': widget.resolvedUrl},
        );
      }
    }
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

  Future<void> _initFirebaseAndSession() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) await FirebaseAuth.instance.signInAnonymously();
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        final prefs = await SharedPreferences.getInstance();
        _sessionId = prefs.getString('session_id_${widget.resolvedUrl}') ??
            DateTime.now().millisecondsSinceEpoch.toString();
        await prefs.setString('session_id_${widget.resolvedUrl}', _sessionId);
        _transcriptsRef = FirebaseFirestore.instance
            .collection('users')
            .doc(currentUser.uid)
            .collection('sessions')
            .doc(_sessionId)
            .collection('transcripts');
      }
    } catch (e) {
      if (_isDesktop) {
        debugPrint('⚠️ Firebase not configured on desktop. Continuing without it.');
      } else {
        debugPrint('Firebase error: $e');
        if (mounted) setState(() => _errorMessage = 'Firebase error: $e (will still try to connect)');
      }
      _sessionId = 'temp_${DateTime.now().millisecondsSinceEpoch}';
    }
    await _fetchLanguageMapping();
    _connect(widget.resolvedUrl);
  }

  Future<void> _fetchLanguageMapping() async {
    if (widget.originalUrl == null || !widget.originalUrl!.startsWith('http')) return;
    try {
      final response = await _httpClient.get(
        Uri.parse(widget.originalUrl!),
        headers: _browserHeaders(),
      );
      if (response.statusCode != 200) return;

      final setCookie = response.headers['set-cookie'];
      if (setCookie != null && setCookie.isNotEmpty) {
        _cookieString = setCookie;
        await _secureStorage.write(key: 'cookies', value: setCookie);
        debugPrint('🍪 Stored cookie: $_cookieString');
      }

      final body = response.body;
      final senderRegex = RegExp(r'data-sender="([^"]+)"');
      final senderMatch = senderRegex.firstMatch(body);
      if (senderMatch != null) {
        final raw = senderMatch.group(1)!.replaceAll('&quot;', '"');
        final Map<String, dynamic> map = jsonDecode(raw);
        _senderToLanguage = map.map((k, v) => MapEntry(k, v.toString()));
      }
      final langNameRegex = RegExp(r'data-lang-name="([^"]+)"');
      final langNameMatch = langNameRegex.firstMatch(body);
      if (langNameMatch != null) {
        final raw = langNameMatch.group(1)!.replaceAll('&quot;', '"');
        final Map<String, dynamic> map = jsonDecode(raw);
        for (final entry in map.entries) {
          final name = entry.value.toString();
          if (!name.contains('Audio') && !name.contains('Correction')) {
            _availableLanguages.add(name);
          }
        }
        if (!_defaultFilterSet && _availableLanguages.isNotEmpty) {
          if (mounted) {
            setState(() {
              _selectedLanguage = null;
              _defaultFilterSet = true;
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Could not fetch language mapping: $e');
    }
  }

  Map<String, String> _browserHeaders() {
    return {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
      'Accept-Language': 'en-US,en;q=0.5',
      'Accept-Encoding': 'gzip, deflate, br',
      'Connection': 'keep-alive',
      'Upgrade-Insecure-Requests': '1',
    };
  }

  // ========== Reconnect ==========
  void _reconnect() {
    _reconnectScheduled = false;
    _reconnectAttempts = 0;
    _channel?.sink.close();
    _sseSubscription?.cancel();
    _sseSubscription = null;
    setState(() {
      _messagesMap.clear();
      _selectedLanguage = null;
      _defaultFilterSet = false;
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
      _defaultFilterSet = false;
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
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
      ..._browserHeaders(),
    };
    if (widget.originalUrl != null) {
      headers['Referer'] = widget.originalUrl!;
      headers['Origin'] = _baseUrl!;
    }
    if (_cookieString != null && _cookieString!.isNotEmpty) {
      headers['Cookie'] = _cookieString!;
    }
    _httpClient.send(http.Request('GET', Uri.parse(url))..headers.addAll(headers))
        .then((response) {
      if (response.statusCode != 200) throw Exception('Server returned HTTP ${response.statusCode}');
      final stream = response.stream.transform(utf8.decoder);
      String buffer = '';
      StreamSubscription<String> subscription;
      subscription = stream.listen((String chunk) {
        buffer += chunk;
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
        _reconnectAttempts = 0;
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
    final lines = eventBlock.split('\n');
    StringBuffer dataBuffer = StringBuffer();
    for (final line in lines) {
      if (line.startsWith('data:')) {
        dataBuffer.writeln(line.substring(5).trim());
      }
    }
    final data = dataBuffer.toString().trim();
    if (data.isEmpty) return;
    try {
      final json = jsonDecode(data);
      _handleMessage(json);
    } catch (e) {
      debugPrint('⚠️ Failed to parse SSE data: $e');
    }
  }

  void _connectWebSocket(String url) {
    debugPrint('🔗 Connecting to WebSocket: $url');
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      _channel!.stream.listen(
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
        _reconnectAttempts = 0;
      });
    } catch (e) {
      debugPrint('❌ Failed to connect WebSocket: $e');
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to connect: $e';
        _isConnected = false;
        _isConnecting = false;
      });
      _scheduleReconnect();
    }
  }

  String _extractLanguageFromSender(String sender) {
    if (_senderToLanguage != null && _senderToLanguage!.containsKey(sender)) {
      return _senderToLanguage![sender]!;
    }
    return sender;
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

  // ========== MAIN MESSAGE HANDLER ==========
  Future<void> _handleMessage(Map<String, dynamic> json) async {
    debugPrint('📩 JSON keys: ${json.keys}');
    debugPrint('🔍 sender: "${json["sender"]}"');

    final session = json['session'] as String?;
    if (session != null && session.isNotEmpty) {
      _sseSessionId = session;
      debugPrint('📌 Captured session ID: $_sseSessionId');
    }

    final sender = json['sender'] ?? '';
    final isUnstable = json['unstable'] == true;
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

      // Extract language from sender
      final langKey = sender.substring(4); // remove 'tts:'
      String language;
      if (_senderToLanguage != null && _senderToLanguage!.containsKey(langKey)) {
        language = _senderToLanguage![langKey]!;
      } else {
        language = langKey; // fallback: use the stripped string as language name
      }

      // Add language to available set
      if (!language.contains('Audio') && !language.contains('Correction')) {
        _availableLanguages.add(language);
      }
      if (!_defaultFilterSet && !language.contains('Audio') && !language.contains('Correction')) {
        if (mounted) {
          setState(() {
            _selectedLanguage = null;
            _defaultFilterSet = true;
          });
        }
      }

      // Audio fetching
      Uint8List? audioBytes;
      String? audioUrl;
      final audioUrlPath = json['b64_enc_pcm_s16le'] as String?;
      if (audioUrlPath != null) {
        try {
          String fullUrl = audioUrlPath.startsWith('http')
              ? audioUrlPath
              : '$_baseUrl$audioUrlPath';
          final uri = Uri.parse(fullUrl);
          final params = Map<String, String>.from(uri.queryParameters);
          if (_sseSessionId != null) {
            params['session'] = _sseSessionId!;
            params['sid'] = _sseSessionId!;
            params['channel'] = _sseSessionId!;
            params['token'] = _sseSessionId!;
            params['stream'] = _sseSessionId!;
          }
          fullUrl = uri.replace(queryParameters: params).toString();
          debugPrint('🎵 Audio URL: $fullUrl');

          if (kIsWeb) {
            audioUrl = fullUrl;
          } else {
            // Non‑web: download and convert to WAV
            final headers = {
              ..._browserHeaders(),
              'Referer': _baseUrl!,
              'Origin': _baseUrl!,
            };
            String? cookieToSend = _cookieString;
            if (cookieToSend == null || cookieToSend.isEmpty) {
              cookieToSend = await _secureStorage.read(key: 'cookies');
            }
            if (cookieToSend != null && cookieToSend.isNotEmpty) {
              headers['Cookie'] = cookieToSend;
            } else if (_sseSessionId != null) {
              headers['Cookie'] = 'session=$_sseSessionId;';
            }

            final response = await _httpClient.get(
              Uri.parse(fullUrl),
              headers: headers,
            ).timeout(const Duration(seconds: 15));

            if (response.statusCode == 200) {
              final wavBytes = _pcmToWav(response.bodyBytes, sampleRate: 16000);
              audioBytes = wavBytes;
              debugPrint('✅ Downloaded & converted audio: ${audioBytes.length} bytes');
            } else {
              debugPrint('❌ Failed to fetch audio: HTTP ${response.statusCode}');
            }
          }
        } catch (e) {
          debugPrint('❌ Error processing audio: $e');
        }
      }

      // Merge with existing transcript of same language and text
      String key;
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
            audioData: audioBytes,
            audioUrl: audioUrl,
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

      // Save to Firestore (optional)
      if (_transcriptsRef != null) {
        try {
          await _transcriptsRef!.add({
            'transcript': transcriptText,
            'translations': {},
            'timestamp': Timestamp.fromDate(DateTime.now()),
            'language': language,
            'isUnstable': false,
          });
        } catch (e) {
          debugPrint('⚠️ Could not save to Firestore: $e');
        }
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

    final language = _extractLanguageFromSender(sender);
    if (!language.contains('Audio') && !language.contains('Correction')) {
      _availableLanguages.add(language);
    }
    if (!_defaultFilterSet && !language.contains('Audio') && !language.contains('Correction')) {
      if (mounted) {
        setState(() {
          _selectedLanguage = null;
          _defaultFilterSet = true;
        });
      }
    }

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

    if (_transcriptsRef != null) {
      try {
        await _transcriptsRef!.add({
          'transcript': transcriptText,
          'translations': {},
          'timestamp': Timestamp.fromDate(DateTime.now()),
          'language': language,
          'isUnstable': isUnstable,
        });
      } catch (e) {
        debugPrint('⚠️ Could not save to Firestore: $e');
      }
    }

    if (!mounted) return;
    setState(() {
      _isConnected = true;
      _isConnecting = false;
    });
    _scrollToBottom();
  }

  // ========== PLAY / PAUSE (SIMPLIFIED) ==========
  Future<void> _playPause(String key, TranscriptMessage message) async {
    if (kIsWeb) {
      // Web: simply open the audio URL in a new tab
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
      await _audioPlayer.setSourceBytes(message.audioData!);
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
    await prefs.remove('session_id_${widget.resolvedUrl}');
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
                hint: const Text('All'),
                items: [
                  const DropdownMenuItem<String>(value: null, child: Text('All (transcript)')),
                  ..._availableLanguages.map((lang) => DropdownMenuItem<String>(
                    value: lang,
                    child: Text(lang),
                  )),
                ],
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
                        TextButton(onPressed: _reconnect, child: const Text('Retry')),
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
                      ? message.audioUrl != null
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
                                color: message.isUnstable ? Colors.grey : Colors.black,
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
                            if (!kIsWeb && message.audioData != null) ...[
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