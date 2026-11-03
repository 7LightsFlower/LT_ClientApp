import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:developer' as developer;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../route_observer.dart';
import '../theme_controller.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;

// ========== SessionHistoryItem (with sessionId & languageMap) ==========
class SessionHistoryItem {
  final String url;
  String name;
  final DateTime firstConnected;
  DateTime lastConnected;
  final String? sessionId;
  final Map<String, String>? languageMap;

  SessionHistoryItem({
    required this.url,
    required this.name,
    required this.firstConnected,
    required this.lastConnected,
    this.sessionId,
    this.languageMap,
  });

  Map<String, dynamic> toJson() => {
        'url': url,
        'name': name,
        'firstConnected': firstConnected.toIso8601String(),
        'lastConnected': lastConnected.toIso8601String(),
        'sessionId': sessionId,
        'languageMap': languageMap != null ? jsonEncode(languageMap) : null,
      };

  factory SessionHistoryItem.fromJson(Map<String, dynamic> json) {
    Map<String, String>? langMap;
    final mapStr = json['languageMap'] as String?;
    if (mapStr != null) {
      try {
        final decoded = jsonDecode(mapStr) as Map<String, dynamic>;
        langMap = decoded.map((k, v) => MapEntry(k, v.toString()));
      } catch (_) {}
    }
    return SessionHistoryItem(
      url: json['url'] as String,
      name: json['name'] as String? ?? 'Session',
      firstConnected: DateTime.parse(json['firstConnected'] as String),
      lastConnected: DateTime.parse(json['lastConnected'] as String),
      sessionId: json['sessionId'] as String?,
      languageMap: langMap,
    );
  }

  static SessionHistoryItem? tryParse(String stored) {
    try {
      final map = jsonDecode(stored) as Map<String, dynamic>;
      if (!map.containsKey('name') || !map.containsKey('firstConnected')) {
        final url = map['url'] as String;
        final last = map['lastConnected'] != null
            ? DateTime.parse(map['lastConnected'] as String)
            : DateTime(2000, 1, 1);
        final first = map['firstConnected'] != null
            ? DateTime.parse(map['firstConnected'] as String)
            : last;
        final name = _formatDateForName(first);
        final sessionId = map['sessionId'] as String?;
        Map<String, String>? langMap;
        final mapStr = map['languageMap'] as String?;
        if (mapStr != null) {
          try {
            final decoded = jsonDecode(mapStr) as Map<String, dynamic>;
            langMap = decoded.map((k, v) => MapEntry(k, v.toString()));
          } catch (_) {}
        }
        return SessionHistoryItem(
          url: url,
          name: name,
          firstConnected: first,
          lastConnected: last,
          sessionId: sessionId,
          languageMap: langMap,
        );
      }
      return SessionHistoryItem.fromJson(map);
    } catch (_) {
      final trimmed = stored.trim();
      if (trimmed.isNotEmpty) {
        final now = DateTime.now();
        return SessionHistoryItem(
          url: trimmed,
          name: _formatDateForName(now),
          firstConnected: now,
          lastConnected: now,
          sessionId: null,
          languageMap: null,
        );
      }
      return null;
    }
  }

  static String _formatDateForName(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

// ========== Settings Keys ==========
const String _kThemeModeKey = kThemeModeKey;
const String _kKeepScreenOnKey = 'keep_screen_on';

// ========== Screen ==========
class SessionSelectionScreen extends StatefulWidget {
  const SessionSelectionScreen({super.key});

  @override
  State<SessionSelectionScreen> createState() =>
      _SessionSelectionScreenState();
}

class _SessionSelectionScreenState extends State<SessionSelectionScreen>
    with RouteAware {
  List<SessionHistoryItem> _history = [];
  bool _isLoading = true;
  final Set<int> _selectedIndices = {};
  String _themeMode = 'system';
  bool _keepScreenOn = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadSettings();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
    _loadHistory();
  }

  // ---------- Settings loading / saving ----------
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _themeMode = prefs.getString(_kThemeModeKey) ?? 'system';
      _keepScreenOn = prefs.getBool(_kKeepScreenOnKey) ?? false;
    });
    if (_keepScreenOn) {
      await WakelockPlus.enable();
    } else {
      await WakelockPlus.disable();
    }
  }

  Future<void> _saveThemeMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeModeKey, mode);
    themeModeNotifier.value = themeModeFromString(mode);
    if (mounted) setState(() => _themeMode = mode);
  }

  Future<void> _saveKeepScreenOn(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kKeepScreenOnKey, value);
    setState(() => _keepScreenOn = value);
    if (value) {
      await WakelockPlus.enable();
    } else {
      await WakelockPlus.disable();
    }
  }

  // ---------- History loading / saving ----------
  Future<void> _loadHistory() async {
    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    final storedList = prefs.getStringList('session_history') ?? [];
    final List<SessionHistoryItem> items = [];
    for (final entry in storedList) {
      final item = SessionHistoryItem.tryParse(entry);
      if (item != null) {
        items.add(item);
      }
    }
    items.sort((a, b) => b.lastConnected.compareTo(a.lastConnected));
    setState(() {
      _history = items;
      _isLoading = false;
      _selectedIndices.clear();
    });
  }

  Future<void> _saveHistory(List<SessionHistoryItem> newList) async {
    newList.sort((a, b) => b.lastConnected.compareTo(a.lastConnected));
    final prefs = await SharedPreferences.getInstance();
    final jsonList = newList.map((item) => jsonEncode(item.toJson())).toList();
    await prefs.setStringList('session_history', jsonList);
    setState(() {
      _history = newList;
      _selectedIndices.clear();
    });
  }

  // ---------- URL resolution (returns both resolved URL and sessionId) ----------
  Future<({String resolvedUrl, String sessionId})> _resolveUrl(String input) async {
    input = input.trim();

    if (input.startsWith('ws://') || input.startsWith('wss://')) {
      final uri = Uri.parse(input);
      final channel = uri.queryParameters['channel'];
      if (channel == null || channel.isEmpty) {
        throw Exception('Direct WebSocket URL missing channel.');
      }
      return (resolvedUrl: input, sessionId: channel);
    }

    if (!input.startsWith('http://') && !input.startsWith('https://')) {
      throw Exception('Invalid URL format.');
    }

    final response = await http.get(Uri.parse(input));
    final body = response.body;

    // Check for session‑over messages (even on HTTP 500)
    final lowerBody = body.toLowerCase();
    if (lowerBody.contains('session already over') ||
        lowerBody.contains('session is over') ||
        lowerBody.contains('session expired') ||
        lowerBody.contains('this session is closed') ||
        lowerBody.contains('no longer active')) {
      throw Exception('This session has already ended. Please scan a new QR code.');
    }

    if (response.statusCode != 200) {
      throw Exception('Server returned HTTP ${response.statusCode}');
    }

    final sessionIdRegex = RegExp(r'window\.sessionId\s*=\s*"([^"]+)"');
    final match = sessionIdRegex.firstMatch(body);
    if (match == null) {
      throw Exception('Could not find a valid session. The session may have expired.');
    }

    final sessionId = match.group(1)!;
    developer.log('Resolved session ID: $sessionId');

    final uri = Uri.parse(input);
    final resolvedUrl = '${uri.scheme}://${uri.host}/webapi/stream?channel=$sessionId';
    return (resolvedUrl: resolvedUrl, sessionId: sessionId);
  }

  // ---------- Fetch language map (can be called even after session ends) ----------
  Future<Map<String, String>> _fetchLanguageNameToIndexMap(String sessionUrl) async {
    try {
      final response = await http.get(Uri.parse(sessionUrl));
      if (response.statusCode != 200) {
        return {};
      }
      // KIT's session page declares its languages in inline JavaScript:
      //   lang_index["German"] = "8"
      // (The data-lang-index attribute the old code looked for is only
      // created later by the page's script, so it is never in this HTML.)
      final result = <String, String>{};
      final indexRe = RegExp(r'lang_index\["([^"]+)"\]\s*=\s*"(\d+)"');
      for (final m in indexRe.allMatches(response.body)) {
        final name = m.group(1)!;
        if (!name.contains('Audio') && !name.contains('Correction')) {
          result[name] = m.group(2)!;
        }
      }
      return result;
    } catch (e) {
      developer.log('Failed to fetch language map: $e');
      return {};
    }
  }

  // ---------- Connect to session (stores sessionId and languageMap) ----------
  Future<void> _connectToSession(String shortUrl) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    String resolvedUrl;
    String sessionId;
    try {
      if (shortUrl.contains('/stream?channel=')) {
        final uri = Uri.parse(shortUrl);
        final channel = uri.queryParameters['channel'];
        if (channel == null || channel.isEmpty) {
          throw Exception('Stream URL missing channel.');
        }
        resolvedUrl = shortUrl;
        sessionId = channel;
      } else {
        final result = await _resolveUrl(shortUrl);
        resolvedUrl = result.resolvedUrl;
        sessionId = result.sessionId;
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to resolve: $e'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    // Fetch language map while the session is still resolvable
    Map<String, String>? langMap;
    try {
      langMap = await _fetchLanguageNameToIndexMap(shortUrl);
      if (langMap.isEmpty) {
        langMap = null;
      }
    } catch (_) {
      langMap = null;
    }

    final now = DateTime.now();
    final index = _history.indexWhere((item) => item.url == shortUrl);
    List<SessionHistoryItem> newList;

    if (index != -1) {
      final existing = _history[index];
      final updated = SessionHistoryItem(
        url: shortUrl,
        name: existing.name,
        firstConnected: existing.firstConnected,
        lastConnected: now,
        sessionId: existing.sessionId ?? sessionId,
        languageMap: existing.languageMap ?? langMap,
      );
      newList = List<SessionHistoryItem>.from(_history);
      newList[index] = updated;
    } else {
      final defaultName = _formatDateForName(now);
      final newItem = SessionHistoryItem(
        url: shortUrl,
        name: defaultName,
        firstConnected: now,
        lastConnected: now,
        sessionId: sessionId,
        languageMap: langMap,
      );
      newList = List<SessionHistoryItem>.from(_history)..add(newItem);
    }

    await _saveHistory(newList);

    if (mounted) {
      Navigator.pop(context);
      Navigator.pushNamed(
        context,
        '/live',
        arguments: {
          'resolvedUrl': resolvedUrl,
          'originalUrl': shortUrl,
        },
      );
    }
  }

  String _formatDateForName(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  // ---------- Edit name ----------
  Future<void> _editName(int index) async {
    final item = _history[index];
    final controller = TextEditingController(text: item.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Session Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty) {
      final updated = SessionHistoryItem(
        url: item.url,
        name: newName,
        firstConnected: item.firstConnected,
        lastConnected: item.lastConnected,
        sessionId: item.sessionId,
        languageMap: item.languageMap,
      );
      final newList = List<SessionHistoryItem>.from(_history);
      newList[index] = updated;
      await _saveHistory(newList);
    }
  }

  // ---------- Delete ----------
  void _deleteSession(int index) {
    final newList = List<SessionHistoryItem>.from(_history);
    newList.removeAt(index);
    _saveHistory(newList);
  }

  void _toggleSelection(int index) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
      } else {
        _selectedIndices.add(index);
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIndices.isEmpty) {
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete selected sessions?'),
        content: Text('This will remove ${_selectedIndices.length} session(s).'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) {
      return;
    }
    final sorted = _selectedIndices.toList()..sort((a, b) => b.compareTo(a));
    final newList = List<SessionHistoryItem>.from(_history);
    for (var idx in sorted) {
      newList.removeAt(idx);
    }
    await _saveHistory(newList);
  }

  Future<void> _deleteAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all sessions?'),
        content: const Text('This will remove all saved sessions.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete All', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) {
      return;
    }
    await _saveHistory([]);
  }

  // ---------- Settings Dialog ----------
  Future<void> _showSettingsDialog() async {
    return showDialog(
      context: context,
      builder: (context) => _SettingsDialog(
        initialTheme: _themeMode,
        initialKeepOn: _keepScreenOn,
        onSave: (theme, keepOn) async {
          await _saveThemeMode(theme);
          await _saveKeepScreenOn(keepOn);
        },
      ),
    );
  }

  // ---------- Formatting for display ----------
  String _formatDateTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      return 'Today at ${_formatTime(dt)}';
    } else if (diff.inDays == 1) {
      return 'Yesterday at ${_formatTime(dt)}';
    } else {
      return '${dt.day}/${dt.month}/${dt.year} ${_formatTime(dt)}';
    }
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  // ---------- Extract session ID (uses stored ID first) ----------
  Future<String?> _extractSessionIdFromUrl(String url) async {
    try {
      final item = _history.firstWhere((item) => item.url == url);
      if (item.sessionId != null && item.sessionId!.isNotEmpty) {
        developer.log('Using stored sessionId: ${item.sessionId}');
        return item.sessionId;
      }
    } catch (_) {}

    // fallback: parse from URL
    try {
      final uri = Uri.parse(url);
      final channel = uri.queryParameters['channel'];
      if (channel != null && channel.isNotEmpty) {
        return channel;
      }
    } catch (_) {}

    // last resort: fetch (legacy)
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        return null;
      }
      final body = response.body;
      final sessionIdRegex = RegExp(r'window\.sessionId\s*=\s*"([^"]+)"');
      final match = sessionIdRegex.firstMatch(body);
      return match?.group(1);
    } catch (e) {
      developer.log('Error extracting session ID: $e');
      return null;
    }
  }

  // ---------- Share / PDF generation ----------
  Future<void> _showLanguageDialog(String sessionUrl) async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('PDF export is not available in the web version.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Try to get the stored language map from history first
    Map<String, String>? langMap;
    try {
      final item = _history.firstWhere((item) => item.url == sessionUrl);
      if (item.languageMap != null && item.languageMap!.isNotEmpty) {
        langMap = item.languageMap;
        developer.log('Using stored language map');
      }
    } catch (_) {}

    // If not stored, try to fetch it (may fail for ended sessions)
    if (langMap == null) {
      langMap = await _fetchLanguageNameToIndexMap(sessionUrl);
      if (langMap.isEmpty) {
        langMap = null;
      }
    }

    if (!mounted) {
      return;
    }

    if (langMap == null || langMap.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No text languages available for this session.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // We also need the sessionId – use stored or fallback
    final sessionId = await _extractSessionIdFromUrl(sessionUrl);
    if (!mounted) {
      return;
    }
    if (sessionId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not extract session ID.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final names = langMap.keys.toList()..sort((a, b) {
      if (a == 'Transcript') {
        return -1;
      }
      if (b == 'Transcript') {
        return 1;
      }
      return a.compareTo(b);
    });

    final selectedName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Language'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: names.length,
            itemBuilder: (context, index) {
              final name = names[index];
              return ListTile(
                title: Text(name),
                onTap: () => Navigator.pop(context, name),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (selectedName != null && mounted) {
      await _fetchAndSharePdf(sessionId, selectedName, sessionUrl); // <-- sessionUrl added
    }
  }

  // ====================================================================
  // PDF generation – with multi‑script font support & improved HTML parsing
  // ====================================================================

  /**Future<pw.Font> _loadFont() async {
    try {
      final data = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
      return pw.Font.ttf(data.buffer.asByteData());
    } catch (_) {
      return pw.Font.helvetica();
    }
  }**/

  /// Loads a font fallback chain covering Latin, CJK, Arabic, etc.
  Future<Map<String, pw.Font>> _loadAllFonts() async {
    final fonts = <String, pw.Font>{};
    final fontFiles = {
      'latin': 'NotoSans-Regular.ttf',
      'sc': 'NotoSansSC-Regular.ttf',
      'tc': 'NotoSansTC-Regular.ttf',
      'jp': 'NotoSansJP-Regular.ttf',
      'kr': 'NotoSansKR-Regular.ttf',
      'arabic': 'NotoSansArabic-Regular.ttf',
    };

    for (final entry in fontFiles.entries) {
      try {
        final data = await rootBundle.load('assets/fonts/${entry.value}');
        fonts[entry.key] = pw.Font.ttf(data.buffer.asByteData());
        if (kDebugMode) {
          print('✅ Loaded ${entry.key}');
        }
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ Failed ${entry.key}: $e');
        }
      }
    }
    return fonts;
  }

  /// Improved HTML parser that preserves inline spacing and punctuation
  List<pw.Widget> _parseHtmlToPdfWidgets(
    String html,
    pw.Font primaryFont,
    List<pw.Font> fallbackFonts,
  ) {
    final document = html_parser.parse(html);
    final body = document.body;
    if (body == null) return [];

    final List<pw.Widget> widgets = [];
    bool isFirst = true;

    void processNode(dom.Node node) {
      if (node is dom.Text) {
        final text = node.text;
        if (text.trim().isNotEmpty) {
          widgets.add(pw.Text(
            text,
            style: pw.TextStyle(
              fontSize: 12,
              font: primaryFont,
              fontFallback: fallbackFonts,
            ),
          ));
        }
      } else if (node is dom.Element) {
        switch (node.localName) {
          case 'br':
            widgets.add(pw.SizedBox(height: 4));
            break;
          case 'p':
          case 'div':
          case 'h1':
          case 'h2':
          case 'h3':
            if (!isFirst) {
              widgets.add(pw.SizedBox(height: 4));
            }
            isFirst = false;
            for (var child in node.nodes) {
              processNode(child);
            }
            break;
          case 'span':
          case 'b':
          case 'strong':
          case 'i':
          case 'em':
            for (var child in node.nodes) {
              processNode(child);
            }
            break;
          default:
            for (var child in node.nodes) {
              processNode(child);
            }
        }
      }
    }

    for (var child in body.nodes) {
      processNode(child);
    }

    // Fallback plain text
    if (widgets.isEmpty) {
      final fullText = body.text.trim();
      if (fullText.isNotEmpty) {
        widgets.add(pw.Text(
          fullText,
          style: pw.TextStyle(
            fontSize: 12,
            font: primaryFont,
            fontFallback: fallbackFonts,
          ),
        ));
      }
    }

    return widgets;
  }

  /// Replaces characters that are not allowed in file names on any platform.
  String _safeFileName(String input) {
    final cleaned = input.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_');
    return cleaned.isEmpty ? 'file' : cleaned;
  }

  Future<File> _generatePdfFromHtml(String html, String languageName, String sessionId) async {
    final fontMap = await _loadAllFonts();
    
    // Primary font: Latin (should contain basic glyphs)
    final primaryFont = fontMap['latin'] ?? pw.Font.helvetica();
    
    // Fallback fonts: all others that are loaded
    final fallbackFonts = fontMap.values
        .where((f) => f != primaryFont)
        .toList();

    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        header: (ctx) => pw.Column(
          children: [
            pw.Text(
              'Lecture Translation - $languageName',
              style: pw.TextStyle(
                fontSize: 20,
                fontWeight: pw.FontWeight.bold,
                font: primaryFont,
                fontFallback: fallbackFonts, // 👈 fallback fonts
              ),
            ),
            // ... other header text with same style
          ],
        ),
        build: (ctx) => _parseHtmlToPdfWidgets(html, primaryFont, fallbackFonts),
      ),
    );

    final directory = await getTemporaryDirectory();
    final shortId = sessionId.length > 8 ? sessionId.substring(0, 8) : sessionId;
    final fileName = 'lecture_${_safeFileName(shortId)}_${_safeFileName(languageName)}.pdf';
    final file = File('${directory.path}/$fileName');
    await file.writeAsBytes(await pdf.save());
    return file;
  }

  // ====================================================================
  // FIXED: Added sessionUrl parameter to build the endpoint dynamically
  // ====================================================================
  Future<void> _fetchAndSharePdf(String sessionId, String languageName, String sessionUrl) async {
    bool loadingDialogOpen = true;
    void closeLoadingDialog() {
      if (loadingDialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      loadingDialogOpen = false;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // Derive base URL from the session URL (the original short link)
      final Uri sessionUri = Uri.parse(sessionUrl);
      final String baseUrl = '${sessionUri.scheme}://${sessionUri.host}';
      
      final Uri uri = Uri.parse('$baseUrl/get_cached_text/$sessionId')
          .replace(queryParameters: {'window': languageName});
          
      final response = await http.get(uri);
      developer.log('📡 URL: ${uri.toString()}');
      developer.log('📄 Status: ${response.statusCode}');
      developer.log('📄 Body length: ${response.body.length}');

      if (response.statusCode != 200) {
        throw Exception('Failed to fetch text: HTTP ${response.statusCode}');
      }

      final htmlContent = response.body.trim();
      if (htmlContent.isEmpty) {
        closeLoadingDialog();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No cached text available for this language yet.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      if (kDebugMode) {
        print('📄 Raw HTML first 500 chars: ${htmlContent.substring(0, htmlContent.length > 500 ? 500 : htmlContent.length)}');
      }

      final pdfFile = await _generatePdfFromHtml(htmlContent, languageName, sessionId);

      closeLoadingDialog();
      if (mounted) {
        final action = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('PDF Ready'),
            content: const Text('What would you like to do with the PDF?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'share'),
                child: const Text('Share'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'save'),
                child: const Text('Save to Device'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'cancel'),
                child: const Text('Cancel'),
              ),
            ],
          ),
        );

        if (action == 'share') {
          await _sharePdf(pdfFile, languageName);
        } else if (action == 'save') {
          await _savePdfToDownloads(pdfFile, languageName);
        }
      }
    } catch (e) {
      // Only closes the loading dialog if it is still open – never the screen.
      closeLoadingDialog();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _sharePdf(File pdfFile, String languageName) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(pdfFile.path)],
        text: 'Lecture translation in $languageName',
        subject: 'Lecture Translation PDF',
      ),
    );
  }

  Future<void> _savePdfToDownloads(File pdfFile, String languageName) async {
    try {
      final downloadsDir = await getDownloadsDirectory();
      final fileName = 'lecture_${DateTime.now().millisecondsSinceEpoch}_${_safeFileName(languageName)}.pdf';
      if (downloadsDir != null) {
        await pdfFile.copy('${downloadsDir.path}/$fileName');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('PDF saved to Downloads folder')),
          );
        }
      } else {
        final tempDir = await getTemporaryDirectory();
        await pdfFile.copy('${tempDir.path}/$fileName');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('PDF saved to ${tempDir.path}')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save PDF: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ---------- Build ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.qr_code_scanner),
          onPressed: () => Navigator.pushNamed(context, '/scan'),
          tooltip: 'Scan New QR',
        ),
        title: _selectedIndices.isNotEmpty
            ? Text('${_selectedIndices.length} selected')
            : const Text('Select Session'),
        actions: [
          if (_selectedIndices.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _deleteSelected,
              tooltip: 'Delete selected',
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettingsDialog,
            tooltip: 'Settings',
          ),
        ],
        bottom: _selectedIndices.isNotEmpty
            ? PreferredSize(
                preferredSize: const Size.fromHeight(48.0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: _deleteSelected,
                        tooltip: 'Delete selected',
                      ),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert),
                        onSelected: (value) {
                          if (value == 'delete_all') {
                            _deleteAll();
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem<String>(
                            value: 'delete_all',
                            child: Text('Delete All'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _history.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  itemCount: _history.length,
                  itemBuilder: (context, index) {
                    final item = _history[index];
                    final isSelected = _selectedIndices.contains(index);
                    return ListTile(
                      leading: Checkbox(
                        value: isSelected,
                        onChanged: (_) => _toggleSelection(index),
                      ),
                      title: Text(
                        item.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.url, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                          Text(
                            'Last connected: ${_formatDateTime(item.lastConnected)}',
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.share, size: 20),
                            onPressed: () => _showLanguageDialog(item.url),
                            tooltip: 'Share as PDF',
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit, size: 20),
                            onPressed: () => _editName(index),
                            tooltip: 'Edit name',
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () => _deleteSession(index),
                            tooltip: 'Remove',
                          ),
                        ],
                      ),
                      onTap: () => _connectToSession(item.url),
                    );
                  },
                ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history, size: 80, color: Colors.grey),
          SizedBox(height: 16),
          Text('No previous sessions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          Text('Tap the QR scan icon in the top left to add a session.', style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}

// ========== Settings Dialog Widget (unchanged) ==========
class _SettingsDialog extends StatefulWidget {
  final String initialTheme;
  final bool initialKeepOn;
  final Future<void> Function(String theme, bool keepOn) onSave;

  const _SettingsDialog({
    required this.initialTheme,
    required this.initialKeepOn,
    required this.onSave,
  });

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late String _tempTheme;
  late bool _tempKeepOn;
  String _appVersion = 'loading...';

  @override
  void initState() {
    super.initState();
    _tempTheme = widget.initialTheme;
    _tempKeepOn = widget.initialKeepOn;
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _appVersion = info.version);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _appVersion = 'unknown');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Settings'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Theme', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'light', label: Text('Light')),
                ButtonSegment(value: 'dark', label: Text('Dark')),
                ButtonSegment(value: 'system', label: Text('System')),
              ],
              selected: {_tempTheme},
              onSelectionChanged: (Set<String> newSelection) {
                setState(() => _tempTheme = newSelection.first);
              },
            ),
            const SizedBox(height: 16),
            const Divider(),
            const Text('Device', style: TextStyle(fontWeight: FontWeight.bold)),
            SwitchListTile(
              title: const Text('Keep Screen On'),
              value: _tempKeepOn,
              onChanged: (value) => setState(() => _tempKeepOn = value),
            ),
            const Divider(),
            const SizedBox(height: 8),
            Center(
              child: Text('Version $_appVersion', style: const TextStyle(color: Colors.grey)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }

  Future<void> _save() async {
    await widget.onSave(_tempTheme, _tempKeepOn);
    if (mounted) {
      Navigator.pop(context);
    }
  }
}
