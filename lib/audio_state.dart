// audio_state.dart
//
// What the speaker's microphone is doing – the same banner KIT's session
// page shows after the last output: "No audio yet", "Muted", "Silence",
// each with a running time. On top of KIT's page, music gets its own banner
// ("♪ Music") instead of counting as speech.
//
// The state comes from the ASR stream (asr:…):
//   controll START        → session started ("No audio yet" counts from here)
//   controll START_AUDIO  → audio flows (first start or after unmuting)
//   controll PAUSE        → mic muted
//   controll END          → session over (no banner)
//   signal speech_segment_start / _end → someone speaks / stopped
//   signal music_segment_start  / _end → music plays / stopped
//
// Joining in the middle of a state works because the ASR's history
// (get_previous_messages) contains all of these: replaying it with the
// server's arrival times (time_arrive_mediator) gives the state and when it
// began – e.g. "Muted 12:31" for a mic muted before the app was opened.

enum AudioBannerKind { noAudio, muted, silence, music }

class AudioBanner {
  const AudioBanner(this.kind, this.since);
  final AudioBannerKind kind;

  /// When the state began (local clock).
  final DateTime since;
}

class AudioState {
  /// Silence is shown only after this long (short pauses between sentences
  /// are not silence).
  static const silenceShowAfter = Duration(seconds: 3);

  final Map<String, bool> _inSpeech = {};
  final Map<String, bool> _inMusic = {};
  final Map<String, bool> _muted = {};
  bool _started = false;
  bool _ended = false;
  DateTime? _silenceSince;
  DateTime? _mutedSince;
  DateTime? _musicSince;
  DateTime? _sessionStarted;
  final DateTime _created = DateTime.now();

  /// Server time (seconds) of the newest message applied. History arrives
  /// later than the live stream; older history must not undo newer state.
  double _lastServerTime = 0;

  static bool _any(Map<String, bool> m) => m.values.any((v) => v);

  void reset() {
    _inSpeech.clear();
    _inMusic.clear();
    _muted.clear();
    _started = false;
    _ended = false;
    _silenceSince = _mutedSince = _musicSince = _sessionStarted = null;
    _lastServerTime = 0;
  }

  /// Applies one message (live or from history). Returns true if it was an
  /// audio-state message.
  bool apply(Map<String, dynamic> m, {bool fromHistory = false}) {
    final sender = m['sender'];
    if (sender is! String || !sender.startsWith('asr')) return false;
    final signal = m['signal'];
    final control = m['controll'] ?? m['control'];
    final speechStart = signal == 'speech_segment_start';
    final musicStart = signal == 'music_segment_start';
    final isSignal = speechStart ||
        musicStart ||
        signal == 'speech_segment_end' ||
        signal == 'music_segment_end';
    if (!isSignal &&
        control != 'START' &&
        control != 'PAUSE' &&
        control != 'START_AUDIO' &&
        control != 'END') {
      return false;
    }

    final t = m['time_arrive_mediator'];
    final serverTime = t is num ? t.toDouble() : double.tryParse('$t');
    var now = DateTime.now();
    if (fromHistory) {
      if (serverTime == null || serverTime < _lastServerTime) return true;
      final at = DateTime.fromMillisecondsSinceEpoch((serverTime * 1000).round());
      if (at.isBefore(now)) now = at;
    }
    if (serverTime != null && serverTime > _lastServerTime) _lastServerTime = serverTime;

    final wasMuted = _any(_muted);
    final hadMusic = _any(_inMusic);
    if (control == 'START') {
      _sessionStarted = now;
    } else if (control == 'END') {
      _inSpeech.clear();
      _inMusic.clear();
      _muted.clear();
      _ended = true;
      _silenceSince = null;
    } else if (control == 'PAUSE') {
      // Muting means audio was flowing before, even if we missed its start.
      _started = true;
      _ended = false;
      _muted[sender] = true;
      _inSpeech[sender] = false;
      _inMusic[sender] = false;
      _silenceSince = null; // the silence after unmuting counts afresh
    } else {
      // START_AUDIO or a voice/music signal: audio from this sender flows.
      _started = true;
      _ended = false;
      _muted[sender] = false;
      if (speechStart || musicStart) {
        if (speechStart) _inSpeech[sender] = true;
        if (musicStart) _inMusic[sender] = true;
        _silenceSince = null;
      } else {
        if (signal == 'speech_segment_end') _inSpeech[sender] = false;
        if (signal == 'music_segment_end') _inMusic[sender] = false;
        if (_any(_inSpeech) || _any(_inMusic)) {
          _silenceSince = null;
        } else if (isSignal || _silenceSince == null) {
          // A segment end starts a silence; START_AUDIO only if none is
          // running (speaker diarization repeats START_AUDIO).
          _silenceSince = now;
        }
      }
    }
    final isMuted = _any(_muted);
    if (isMuted && !wasMuted) _mutedSince = now; // a 2nd PAUSE keeps the start
    if (!isMuted) _mutedSince = null;
    final hasMusic = _any(_inMusic);
    if (hasMusic && !hadMusic) _musicSince = now;
    if (!hasMusic) _musicSince = null;
    return true;
  }

  /// What to show right now, or null for nothing (someone speaks, or the
  /// session is over).
  AudioBanner? get banner {
    if (_ended) return null;
    if (!_started) return AudioBanner(AudioBannerKind.noAudio, _sessionStarted ?? _created);
    if (_any(_muted)) return AudioBanner(AudioBannerKind.muted, _mutedSince ?? DateTime.now());
    if (_any(_inSpeech)) return null;
    if (_any(_inMusic)) return AudioBanner(AudioBannerKind.music, _musicSince ?? DateTime.now());
    final s = _silenceSince;
    if (s == null || DateTime.now().difference(s) < silenceShowAfter) return null;
    return AudioBanner(AudioBannerKind.silence, s);
  }
}

/// "m:ss" or "h:mm:ss", like KIT's banner.
String formatBannerTime(Duration d) {
  final sec = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = sec ~/ 3600, m = (sec % 3600) ~/ 60, s = sec % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// The banner's word in the window's language: KIT's own words for
/// silence / muted / no audio yet, plus one for music.
String bannerLabel(AudioBannerKind kind, String? language) {
  final words = _wordsFor(language);
  return switch (kind) {
    AudioBannerKind.silence => words[0],
    AudioBannerKind.muted => words[1],
    AudioBannerKind.noAudio => words[2],
    AudioBannerKind.music => words[3],
  };
}

List<String> _wordsFor(String? language) {
  if (language == null) return _bannerWords['English']!;
  final exact = _bannerWords[language];
  if (exact != null) return exact;
  // "German Summary", "Chinese (China)", "English/German" → first word
  final first = language.split(RegExp(r'[\s(/]')).first;
  return _bannerWords[first] ?? _bannerWords['English']!;
}

// [Silence, Muted, No audio yet] from KIT's page, plus Music.
const Map<String, List<String>> _bannerWords = {
  'English': ['Silence', 'Muted', 'No audio yet', 'Music'],
  'German': ['Stille', 'Stummgeschaltet', 'Noch kein Audio', 'Musik'],
  'French': ['Silence', 'Micro coupé', "Pas encore d'audio", 'Musique'],
  'Spanish': ['Silencio', 'Silenciado', 'Aún no hay audio', 'Música'],
  'Italian': ['Silenzio', 'Muto', 'Ancora nessun audio', 'Musica'],
  'Portuguese': ['Silêncio', 'Silenciado', 'Ainda sem áudio', 'Música'],
  'Dutch': ['Stilte', 'Gedempt', 'Nog geen audio', 'Muziek'],
  'Polish': ['Cisza', 'Wyciszono', 'Brak dźwięku', 'Muzyka'],
  'Czech': ['Ticho', 'Ztlumeno', 'Zatím bez zvuku', 'Hudba'],
  'Slovak': ['Ticho', 'Stlmené', 'Zatiaľ bez zvuku', 'Hudba'],
  'Slovenian': ['Tišina', 'Utišano', 'Še ni zvoka', 'Glasba'],
  'Croatian': ['Tišina', 'Utišano', 'Još nema zvuka', 'Glazba'],
  'Bosnian': ['Tišina', 'Utišano', 'Još nema zvuka', 'Muzika'],
  'Serbian': ['Тишина', 'Утишано', 'Још нема звука', 'Музика'],
  'Ukrainian': ['Тиша', 'Мікрофон вимкнено', 'Ще немає звуку', 'Музика'],
  'Russian': ['Тишина', 'Микрофон выключен', 'Звука пока нет', 'Музыка'],
  'Belarusian': ['Цішыня', 'Мікрафон выключаны', 'Гуку пакуль няма', 'Музыка'],
  'Bulgarian': ['Тишина', 'Заглушен', 'Все още няма звук', 'Музика'],
  'Macedonian': ['Тишина', 'Исклучен звук', 'Сè уште нема звук', 'Музика'],
  'Romanian': ['Liniște', 'Microfon dezactivat', 'Încă nu există sunet', 'Muzică'],
  'Hungarian': ['Csend', 'Némítva', 'Még nincs hang', 'Zene'],
  'Greek': ['Σιωπή', 'Σε σίγαση', 'Δεν υπάρχει ακόμη ήχος', 'Μουσική'],
  'Turkish': ['Sessizlik', 'Sessize alındı', 'Henüz ses yok', 'Müzik'],
  'Swedish': ['Tystnad', 'Ljud av', 'Inget ljud än', 'Musik'],
  'Norwegian': ['Stillhet', 'Dempet', 'Ingen lyd ennå', 'Musikk'],
  'Norwegian Bokmål': ['Stillhet', 'Dempet', 'Ingen lyd ennå', 'Musikk'],
  'Danish': ['Stilhed', 'Slået fra', 'Ingen lyd endnu', 'Musik'],
  'Finnish': ['Hiljaisuus', 'Mykistetty', 'Ei vielä ääntä', 'Musiikki'],
  'Estonian': ['Vaikus', 'Vaigistatud', 'Heli veel pole', 'Muusika'],
  'Latvian': ['Klusums', 'Skaņa izslēgta', 'Vēl nav skaņas', 'Mūzika'],
  'Lithuanian': ['Tyla', 'Nutildyta', 'Garso dar nėra', 'Muzika'],
  'Icelandic': ['Þögn', 'Slökkt á hljóði', 'Ekkert hljóð enn', 'Tónlist'],
  'Irish': ['Ciúnas', 'Balbhaithe', 'Gan fuaim fós', 'Ceol'],
  'Welsh': ['Distawrwydd', "Wedi'i dawelu", 'Dim sain eto', 'Cerddoriaeth'],
  'Catalan': ['Silenci', 'Silenciat', 'Encara no hi ha àudio', 'Música'],
  'Basque': ['Isiltasuna', 'Mututua', 'Oraindik ez dago audiorik', 'Musika'],
  'Galician': ['Silencio', 'Silenciado', 'Aínda non hai audio', 'Música'],
  'Albanian': ['Heshtje', 'I heshtur', 'Ende pa audio', 'Muzikë'],
  'Maltese': ['Skiet', 'Mutat', 'L-ebda awdjo għadu', 'Mużika'],
  'Arabic': ['صمت', 'مكتوم', 'لا يوجد صوت بعد', 'موسيقى'],
  'Hebrew': ['שקט', 'מושתק', 'אין עדיין שמע', 'מוזיקה'],
  'Persian': ['سکوت', 'بی‌صدا', 'هنوز صدایی نیست', 'موسیقی'],
  'Urdu': ['خاموشی', 'خاموش کردہ', 'ابھی آڈیو نہیں', 'موسیقی'],
  'Hindi': ['मौन', 'म्यूट', 'अभी तक कोई ऑडियो नहीं', 'संगीत'],
  'Bengali': ['নীরবতা', 'মিউট', 'এখনও কোনো অডিও নেই', 'সংগীত'],
  'Tamil': ['அமைதி', 'முடக்கப்பட்டது', 'இன்னும் ஒலி இல்லை', 'இசை'],
  'Telugu': ['నిశ్శబ్దం', 'మ్యూట్ చేయబడింది', 'ఇంకా ఆడియో లేదు', 'సంగీతం'],
  'Chinese': ['静默', '已静音', '尚无音频', '音乐'],
  'Japanese': ['無音', 'ミュート中', 'まだ音声がありません', '音楽'],
  'Korean': ['무음', '음소거됨', '아직 오디오 없음', '음악'],
  'Vietnamese': ['Im lặng', 'Đã tắt tiếng', 'Chưa có âm thanh', 'Âm nhạc'],
  'Thai': ['เงียบ', 'ปิดเสียงอยู่', 'ยังไม่มีเสียง', 'ดนตรี'],
  'Indonesian': ['Hening', 'Dibisukan', 'Belum ada audio', 'Musik'],
  'Malay': ['Senyap', 'Dibisukan', 'Belum ada audio', 'Muzik'],
  'Filipino': ['Katahimikan', 'Naka-mute', 'Wala pang audio', 'Musika'],
  'Georgian': ['სიჩუმე', 'დადუმებულია', 'ჯერ აუდიო არ არის', 'მუსიკა'],
  'Armenian': ['Լռություն', 'Ձայնն անջատված է', 'Դեռ ձայն չկա', 'Երաժշտություն'],
  'Azerbaijani': ['Sükut', 'Səssiz', 'Hələ səs yoxdur', 'Musiqi'],
  'Kazakh': ['Тыныштық', 'Дыбыс өшірілген', 'Әзірге дыбыс жоқ', 'Музыка'],
  'Swahili': ['Kimya', 'Imenyamazishwa', 'Bado hakuna sauti', 'Muziki'],
};
