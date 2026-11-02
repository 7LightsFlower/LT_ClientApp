import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preference key shared with the settings dialog.
const String kThemeModeKey = 'theme_mode';

/// App-wide theme mode. MyApp listens to it; the settings dialog updates it.
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.system);

ThemeMode themeModeFromString(String? value) {
  switch (value) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}

/// Reads the saved theme mode into [themeModeNotifier].
Future<void> loadThemeMode() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    themeModeNotifier.value = themeModeFromString(prefs.getString(kThemeModeKey));
  } catch (_) {
    // Keep the default (system) if preferences are unavailable.
  }
}
