import 'package:live_translator_viewer/screens/session_selection_screen.dart';
import 'package:flutter/material.dart';
import 'screens/qr_scanner_screen.dart';
import 'screens/live_transcript_screen.dart';
import 'screens/silent_auth_screen.dart';
import 'route_observer.dart';
import 'theme_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadThemeMode();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, themeMode, _) => MaterialApp(
        title: 'Live Translator Viewer',
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
