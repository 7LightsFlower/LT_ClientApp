import 'package:asr_live_translator/screens/session_selection_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, kDebugMode;
import 'screens/qr_scanner_screen.dart';
import 'screens/live_transcript_screen.dart';
import 'screens/silent_auth_screen.dart';
import 'route_observer.dart';
import 'theme_controller.dart';

const _firebaseWebOptions = FirebaseOptions(
  apiKey: "AIzaSyDzSrmUy6SB2mSj0IZ3lOIJZ4de5fmps4w",
  authDomain: "lectureviewerapp.firebaseapp.com",
  projectId: "lectureviewerapp",
  storageBucket: "lectureviewerapp.firebasestorage.app",
  messagingSenderId: "844850086526",
  appId: "1:844850086526:web:916ab321abf65eaa818e2f",
  measurementId: "G-EJM5LW14VS",
);

bool get _isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await loadThemeMode();

  Widget app;

  try {
    // ---- Firebase initialization ----
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      // FlutterFire has no Linux implementation – run without Firebase.
      if (kDebugMode) debugPrint('ℹ️ Firebase is not supported on Linux; continuing without it.');
    } else if (kIsWeb) {
      await Firebase.initializeApp(options: _firebaseWebOptions);
    } else if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      await Firebase.initializeApp();
    } else {
      await Firebase.initializeApp(options: _firebaseWebOptions);
    }

    app = const MyApp();
  } catch (e, stack) {
    if (kDebugMode) {
      debugPrint('🔥 Firebase init failed: $e');
      debugPrint('$stack');
    }
    if (_isDesktop) {
      // Firebase is optional on desktop (transcripts just aren't saved).
      app = const MyApp();
    } else {
      app = MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 60),
                  const SizedBox(height: 16),
                  const Text(
                    'App Initialization Error',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$e',
                    style: const TextStyle(color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
  }

  runApp(app);
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, themeMode, _) => MaterialApp(
        title: 'ASR Live Translator',
        theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
        darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        themeMode: themeMode,
        initialRoute: '/',
        navigatorObservers: [routeObserver],
        routes: {
          '/': (context) => const SessionSelectionScreen(),
          '/scan': (context) => const QRScannerScreen(),
          '/live': (context) {
            final args = ModalRoute.of(context)!.settings.arguments;
            if (args is Map<String, dynamic>) {
              return LiveTranscriptScreen(
                resolvedUrl: args['resolvedUrl'] as String,
                originalUrl: args['originalUrl'] as String?,
                authAttempted: args['authAttempted'] == true,
              );
            } else if (args is String) {
              return LiveTranscriptScreen(
                resolvedUrl: args,
                originalUrl: null,
              );
            } else {
              return const Scaffold(
                body: Center(
                  child: Text('Invalid navigation arguments'),
                ),
              );
            }
          },
          '/auth': (context) {
            final args = ModalRoute.of(context)!.settings.arguments;
            if (args is Map<String, dynamic>) {
              return SilentAuthScreen(
                originalUrl: args['originalUrl'] as String,
                resolvedUrl: args['resolvedUrl'] as String,
              );
            } else {
              return const Scaffold(
                body: Center(
                  child: Text('Missing authentication parameters'),
                ),
              );
            }
          },
        },
      ),
    );
  }
}
