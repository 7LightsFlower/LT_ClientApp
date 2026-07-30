// web_stub.dart – dummy implementations for non‑web platforms
class AudioElement {
  void pause() {}
  Future<void> play() async {}
  set src(String _) {}           // no return type
  set autoplay(bool _) {}        // no return type
  Stream<dynamic> get onError => const Stream.empty();  // const
  Stream<void> get onEnded => const Stream.empty();     // const
  Stream<void> get onTimeUpdate => const Stream.empty();// const
  bool get paused => true;
  double get duration => 0;
  double get currentTime => 0;
}

class Blob {
  Blob(List<dynamic> parts, {String type = ''});
}

class Url {
  static String createObjectUrl(Blob blob) => '';
  static void revokeObjectUrl(String url) {}
}

class Window {
  void open(String url, String target) {}
}

final Window window = Window();