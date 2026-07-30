import 'package:asr_live_translator/screens/session_selection_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, kDebugMode;
import 'screens/qr_scanner_screen.dart';
import 'screens/live_transcript_screen.dart';
import 'screens/silent_auth_screen.dart';
import 'route_observer.dart';

import 'package:webview_flutter/webview_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Widget app;

  try {
    // ---- Firebase initialization ----
    if (kIsWeb) {
      const firebaseOptions = FirebaseOptions(
        apiKey: "AIzaSyDzSrmUy6SB2mSj0IZ3lOIJZ4de5fmps4w",
        authDomain: "lectureviewerapp.firebaseapp.com",
        projectId: "lectureviewerapp",
        storageBucket: "lectureviewerapp.firebasestorage.app",
        messagingSenderId: "844850086526",
        appId: "1:844850086526:web:916ab321abf65eaa818e2f",
        measurementId: "G-EJM5LW14VS",
      );
      await Firebase.initializeApp(options: firebaseOptions);
    } else if (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS) {
      await Firebase.initializeApp();
    } else {
      const firebaseOptions = FirebaseOptions(
        apiKey: "AIzaSyDzSrmUy6SB2mSj0IZ3lOIJZ4de5fmps4w",
        authDomain: "lectureviewerapp.firebaseapp.com",
        projectId: "lectureviewerapp",
        storageBucket: "lectureviewerapp.firebasestorage.app",
        messagingSenderId: "844850086526",
        appId: "1:844850086526:web:916ab321abf65eaa818e2f",
        measurementId: "G-EJM5LW14VS",
      );
      await Firebase.initializeApp(options: firebaseOptions);
    }

    app = const MyApp();
  } catch (e, stack) {
    if (kDebugMode) {
      print('🔥 Firebase init failed: $e');
      print(stack);
    }
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

  runApp(app);
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ASR Live Translator',
      theme: ThemeData(useMaterial3: true),
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
    );
  }
}
