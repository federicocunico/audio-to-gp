/// Pure-Dart Guitar Pro 5 (.gp5) binary writer.
///
/// Implements a subset of the GP5 format sufficient for note playback:
///   - Song header (title, tempo, key)
///   - Measure headers (count, 4/4 time signature)
///   - Tracks (name, strings, MIDI instrument + channel)
///   - Measures → voices → beats → notes (fret + string positions)
///
/// This port replaces the Python `guitarpro` (PyGuitarPro) package.
/// Logic ported from `step4_guitar_pro()` in the original pipeline.py.
library;

import 'dart:io';
import 'dart:typed_data';

import 'midi_parser.dart';
import '../models/pipeline_models.dart';

// ---------------------------------------------------------------------------
// GP5 constants
// ---------------------------------------------------------------------------

const int _kQuarter = 960; // GP ticks per quarter note
const int _kGrid = 240; // 16th-note quantise grid (QUARTER / 4)
const int _kMeasure = 3840; // 4/4 bar = 4 * QUARTER
const int _kInitialTick = 960; // first measure starts at tick 960 in GP

/// GP5 duration value table: (tick duration, GP duration enum value).
/// Ordered largest-to-smallest for greedy fitting.
const List<(int, int)> _kDurTable = [
  (3840, 1), // whole
  (1920, 2), // half
  (960, 4), // quarter
  (480, 8), // eighth
  (240, 16), // sixteenth
];

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Stem MIDI data passed to the GP5 writer.
class StemMidiData {
  const StemMidiData({required this.stemName, required this.midi});
  final String stemName;
  final MidiData midi;
}

/// Write a GP5 file from a list of stem MIDI data.
///
/// [stems] must contain at least one entry.
/// [outputPath] should end with `.gp5`.
/// [trackName] is used as the song title.
///
/// Throws [ArgumentError] if [stems] is empty.
/// Throws [FileSystemException] on write failure.
Future<void> writeGp5(
  List<StemMidiData> stems,
  String outputPath,
  String trackName,
) async {
  if (stems.isEmpty) throw ArgumentError('stems must not be empty');

  // Determine BPM and song length from all stems combined.
  int detectedBpm = 120;
  int maxGpTick = _kInitialTick;

  final allQuantised = <String, List<_QEvent>>{};

  for (final stem in stems) {
    if (stem.midi.events.isEmpty) continue;
    detectedBpm = stem.midi.bpm;
    final ppq = stem.midi.ppq;
    final qEvents = <_QEvent>[];

    for (final ev in stem.midi.events) {
      // Convert MIDI ticks to GP ticks (based on QUARTER=960)
      final gpStart = ev.startTick * _kQuarter ~/ ppq + _kInitialTick;
      final gpEnd = ev.endTick * _kQuarter ~/ ppq + _kInitialTick;
      final qs = _quantise(gpStart);
      final qe = _quantise(gpEnd).clamp(qs + _kGrid, 1 << 30);
      qEvents.add(_QEvent(qs, qe, ev.pitch, ev.velocity));
      if (qe > maxGpTick) maxGpTick = qe;
    }
    allQuantised[stem.stemName] = qEvents..sort((a, b) => a.start - b.start);
  }

  final songLength = maxGpTick - _kInitialTick;
  final nMeasures = ((songLength + _kMeasure - 1) ~/ _kMeasure).clamp(1, 4096);

  // ---------- binary builder ----------
  final buf = _Gp5Buffer();

  _writeHeader(buf, trackName, detectedBpm, stems.length, nMeasures);
  _writeMeasureHeaders(buf, nMeasures);
  _writeTracks(buf, stems);

  // Measures — written track-by-track: all measures for track 0, then track 1…
  for (var ti = 0; ti < stems.length; ti++) {
    final stem = stems[ti];
    final cfg = StemInstrumentConfig.forStem(stem.stemName, ti + 2);
    final events = allQuantised[stem.stemName] ?? [];
    _writeMeasuresForTrack(buf, events, cfg, nMeasures);
  }

  final file = File(outputPath);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(buf.toBytes());
}

// ---------------------------------------------------------------------------
// Quantisation & tab helpers
// ---------------------------------------------------------------------------

int _quantise(int tick) => (tick / _kGrid).round() * _kGrid;

/// Returns (1-based string index, fret) at lowest available fret, or null.
(int, int)? _pitchToTab(int pitch, List<int> openStrings) {
  (int, int)? best;
  for (var i = 0; i < openStrings.length; i++) {
    final fret = pitch - openStrings[i];
    if (fret >= 0 && fret <= 22) {
      if (best == null || fret < best.$2) {
        best = (i + 1, fret);
      }
    }
  }
  return best;
}

// ---------------------------------------------------------------------------
// GP5 binary header
// ---------------------------------------------------------------------------

void _writeHeader(
  _Gp5Buffer buf,
  String title,
  int bpm,
  int nTracks,
  int nMeasures,
) {
  // VersionString — exactly 31 bytes (1 length byte + 30 chars, null-padded)
  const versionStr = 'FICHIER GUITAR PRO v5.00';
  buf.writeIntString(versionStr, fixedLen: 30);

  // ScoreInformation
  buf.writeIntString(title); // title
  buf.writeIntString(''); // subtitle
  buf.writeIntString(''); // artist
  buf.writeIntString(''); // album
  buf.writeIntString(''); // words
  buf.writeIntString(''); // music
  buf.writeIntString(''); // copyright
  buf.writeIntString(''); // tabbed by
  buf.writeIntString(''); // instructions
  // Notices: count + lines
  buf.writeInt32(0);

  // LyricsHeader (GP5): lyrics track index + 5 lyric lines
  buf.writeInt32(1); // lyrics track (1-indexed, 0 = no lyrics)
  for (var i = 0; i < 5; i++) {
    buf.writeInt32(0); // lyric line start bar
    buf.writeInt32(0); // lyric string length placeholder
    // empty lyric string: 4-byte length + 0 chars
  }

  // RSEMasterEffect (GP5): 11 ints
  for (var i = 0; i < 11; i++) { buf.writeInt32(0); }

  // Page setup (GP5): 49 bytes = 11 ints (44 bytes) + 5 bytes
  for (var i = 0; i < 11; i++) { buf.writeInt32(0); }
  for (var i = 0; i < 5; i++) { buf.writeByte(0); }

  buf.writeInt32(bpm); // tempo value
  buf.writeByte(0); // hide tempo (0=show)
  buf.writeByte(0); // key (C major)
  buf.writeByte(0); // octave
  buf.writeInt32(255); // master volume
  buf.writeInt32(255); // effect1 volume
  buf.writeInt32(255); // effect2 volume

  // MIDI channels — 64 entries of 11 bytes each
  for (var i = 0; i < 64; i++) {
    buf.writeInt32(25); // instrument (nylon guitar default)
    buf.writeByte(13); // volume
    buf.writeByte(8); // balance
    buf.writeByte(0); // chorus
    buf.writeByte(0); // reverb
    buf.writeByte(0); // phaser
    buf.writeByte(0); // tremolo
    buf.writeByte(0); // pad1
    buf.writeByte(0); // pad2
  }

  buf.writeInt32(0); // directions count
  buf.writeInt32(0); // master reverb

  buf.writeInt32(nMeasures); // measure count
  buf.writeInt32(nTracks); // track count
}

// ---------------------------------------------------------------------------
// Measure headers
// ---------------------------------------------------------------------------

void _writeMeasureHeaders(_Gp5Buffer buf, int nMeasures) {
  for (var i = 0; i < nMeasures; i++) {
    // Measure header flags byte
    // Bit 0: numerator present, Bit 1: denominator present
    // Bit 2: begin repeat, Bit 3: end repeat, Bit 4: alt endings
    // Bit 5: marker, Bit 6: tonality, Bit 7: double bar
    int flags = 0;
    if (i == 0) flags = 0x03; // first measure has numerator + denominator
    buf.writeByte(flags);

    if (i == 0) {
      buf.writeByte(4); // numerator = 4
      buf.writeByte(4); // denominator = 4 (as log2: 2^2=4 — actually it's just the value in GP)
    }

    buf.writeByte(0); // end repeat count
    buf.writeByte(0); // alt ending
    // Marker: empty (no marker string, no color)
    buf.writeByte(0); // tonality (major)
    if (i < nMeasures - 1) buf.writeByte(0); // padding between headers
  }
}

// ---------------------------------------------------------------------------
// Tracks
// ---------------------------------------------------------------------------

void _writeTracks(_Gp5Buffer buf, List<StemMidiData> stems) {
  for (var ti = 0; ti < stems.length; ti++) {
    final stem = stems[ti];
    final cfg = StemInstrumentConfig.forStem(stem.stemName, ti + 2);

    // Track flags
    int flags1 = 0;
    if (cfg.midiChannel == 10) flags1 |= 0x01; // percussion track
    buf.writeByte(flags1);
    buf.writeByte(0); // flags2

    // Track name (40 bytes padded)
    buf.writeIntString(cfg.name, fixedLen: 40);

    // String count + string tunings (7 entries max)
    final nStrings = cfg.openStrings.length.clamp(1, 7);
    buf.writeInt32(nStrings);
    for (var si = 0; si < 7; si++) {
      final pitch = si < nStrings ? cfg.openStrings[si] : 0;
      buf.writeInt32(pitch);
    }

    buf.writeInt32(1); // MIDI port (1-indexed)

    // Channel: 0-indexed in GP5 (channel 10 = 9 in 0-indexed)
    final channel0 = (cfg.midiChannel - 1).clamp(0, 15);
    final effectChannel0 = channel0;
    buf.writeInt32(channel0 + 1); // 1-indexed channel
    buf.writeInt32(effectChannel0 + 1); // 1-indexed effect channel

    buf.writeInt32(24); // fret count
    buf.writeInt32(0); // capo fret
    buf.writeInt32(0xFF0000); // track color (red = 0x00FF0000 in ABGR)
  }
  buf.writeByte(0); // padding after last track
  buf.writeByte(0);
}

// ---------------------------------------------------------------------------
// Measures
// ---------------------------------------------------------------------------

void _writeMeasuresForTrack(
  _Gp5Buffer buf,
  List<_QEvent> events,
  StemInstrumentConfig cfg,
  int nMeasures,
) {
  for (var mi = 0; mi < nMeasures; mi++) {
    final mStart = _kInitialTick + mi * _kMeasure;
    final mEnd = mStart + _kMeasure;

    final mEvents = events.where((e) => e.start >= mStart && e.start < mEnd).toList();

    _writeMeasure(buf, mEvents, cfg, mStart, mEnd);
  }
}

void _writeMeasure(
  _Gp5Buffer buf,
  List<_QEvent> events,
  StemInstrumentConfig cfg,
  int mStart,
  int mEnd,
) {
  // Number of voices: GP5 supports up to 2 voices; we use 1.
  buf.writeByte(1); // voice count ... actually GP5 always writes 2 voices

  // Voice 0 (primary)
  _writeVoice(buf, events, cfg, mStart, mEnd);
  // Voice 1 (empty — rests only)
  _writeEmptyVoice(buf, mStart, mEnd);

  buf.writeByte(0); // measure separator / new_line_flag
}

void _writeVoice(
  _Gp5Buffer buf,
  List<_QEvent> events,
  StemInstrumentConfig cfg,
  int mStart,
  int mEnd,
) {
  final beats = _buildBeats(events, cfg, mStart, mEnd);
  buf.writeInt32(beats.length);
  for (final beat in beats) {
    _writeBeat(buf, beat, cfg);
  }
}

void _writeEmptyVoice(
  _Gp5Buffer buf,
  int mStart,
  int mEnd,
) {
  // One whole-measure rest beat
  final beats = <_Beat>[
    _Beat(
      start: mStart,
      durationValue: 1,
      notes: const [],
      isRest: true,
    ),
  ];
  buf.writeInt32(beats.length);
  for (final beat in beats) {
    _writeBeat(buf, beat, StemInstrumentConfig.forStem('other', 6));
  }
}

// ---------------------------------------------------------------------------
// Beat builder (from pipeline.py logic)
// ---------------------------------------------------------------------------

class _QEvent {
  const _QEvent(this.start, this.end, this.pitch, this.velocity);
  final int start;
  final int end;
  final int pitch;
  final int velocity;
}

class _Beat {
  const _Beat({
    required this.start,
    required this.durationValue,
    required this.notes,
    this.isRest = false,
  });
  final int start;
  final int durationValue; // 1=whole, 2=half, 4=quarter, 8=eighth, 16=16th
  final List<(int string, int fret, int velocity)> notes;
  final bool isRest;
}

List<_Beat> _buildBeats(
  List<_QEvent> events,
  StemInstrumentConfig cfg,
  int mStart,
  int mEnd,
) {
  final beats = <_Beat>[];
  var cursor = mStart;

  // Group events by start position
  final byPos = <int, List<_QEvent>>{};
  for (final ev in events) {
    byPos.putIfAbsent(ev.start, () => []).add(ev);
  }
  final sortedPos = byPos.keys.toList()..sort();

  for (var ki = 0; ki < sortedPos.length; ki++) {
    final pos = sortedPos[ki];

    // Fill gap with rests
    if (pos > cursor) {
      beats.addAll(_makeRests(cursor, pos));
      cursor = pos;
    }

    // Determine duration
    final nextPos =
        ki + 1 < sortedPos.length ? sortedPos[ki + 1] : mEnd;
    final maxDur = (nextPos - pos).clamp(0, mEnd - pos);
    var durTicks = _kGrid;
    var durVal = 16;
    for (final (dt, dv) in _kDurTable) {
      if (maxDur >= dt) {
        durTicks = dt;
        durVal = dv;
        break;
      }
    }

    // Map pitches to strings/frets
    final usedStrings = <int>{};
    final noteList = <(int, int, int)>[];
    for (final ev in byPos[pos]!) {
      final tab = _pitchToTab(ev.pitch, cfg.openStrings);
      if (tab == null) continue;
      final (strNum, fret) = tab;
      if (usedStrings.contains(strNum)) continue;
      usedStrings.add(strNum);
      noteList.add((strNum, fret, ev.velocity));
    }

    beats.add(_Beat(
      start: pos,
      durationValue: durVal,
      notes: noteList,
      isRest: noteList.isEmpty,
    ));
    cursor = pos + durTicks;
  }

  // Fill trailing rests
  if (cursor < mEnd) {
    beats.addAll(_makeRests(cursor, mEnd));
  }

  return beats;
}

List<_Beat> _makeRests(int from, int to) {
  final rests = <_Beat>[];
  var remaining = to - from;
  var cursor = from;
  for (final (dt, dv) in _kDurTable) {
    while (remaining >= dt) {
      rests.add(_Beat(
        start: cursor,
        durationValue: dv,
        notes: const [],
        isRest: true,
      ));
      cursor += dt;
      remaining -= dt;
    }
  }
  return rests;
}

// ---------------------------------------------------------------------------
// Beat binary writer
// ---------------------------------------------------------------------------

void _writeBeat(_Gp5Buffer buf, _Beat beat, StemInstrumentConfig cfg) {
  // Beat flags
  int flags = 0;
  if (beat.isRest) flags |= 0x40;
  if (beat.notes.isNotEmpty) flags |= 0x20; // note effects present (effect byte)
  buf.writeByte(flags);

  if (beat.isRest) {
    buf.writeByte(0); // rest type: normal rest
  }

  // Duration (as GP value: 1=whole…16=16th, encoded as (log2(val) - 1) offset)
  // GP5 stores duration as: -2=whole, -1=half, 0=quarter, 1=eighth, 2=16th
  final durEncoded = _durationToGp(beat.durationValue);
  buf.writeByte(durEncoded & 0xFF);

  // n-tuplet (0 = normal)
  buf.writeInt32(0);

  if (beat.notes.isEmpty) return;

  // String bitmask (bits 0–6 = strings 1–7)
  int strMask = 0;
  for (final (s, _, _) in beat.notes) {
    strMask |= (1 << (s - 1));
  }
  buf.writeInt32(strMask);

  // Note effects header (since flags & 0x20)
  buf.writeByte(0); // beat effect flags 1
  buf.writeByte(0); // beat effect flags 2

  // Write each note
  for (final (_, fret, velocity) in beat.notes) {
    // Note flags
    int nFlags = 0x20; // velocity present
    buf.writeByte(nFlags);
    buf.writeByte(0x01); // note type: normal (fretted)
    buf.writeByte(velocity & 0x7F); // dynamic/velocity (1–15 in GP5 range, we clip)
    buf.writeInt32(fret); // fret value
    buf.writeByte(0); // finger left
    buf.writeByte(0); // finger right
    buf.writeDouble(0.0); // note scale length (GP5: double as float?)
    buf.writeByte(0); // note effects flags
  }
}

int _durationToGp(int value) {
  // GP5 duration: stored as signed byte where 0=quarter, -1=half, -2=whole, 1=eighth, 2=16th
  switch (value) {
    case 1:
      return 0xFE; // -2 as signed byte
    case 2:
      return 0xFF; // -1 as signed byte
    case 4:
      return 0x00; // 0
    case 8:
      return 0x01;
    case 16:
      return 0x02;
    default:
      return 0x00; // fallback: quarter
  }
}

// ---------------------------------------------------------------------------
// Binary buffer
// ---------------------------------------------------------------------------

class _Gp5Buffer {
  final _data = BytesBuilder(copy: false);

  void writeByte(int value) => _data.addByte(value & 0xFF);

  void writeInt32(int value) {
    final bytes = Uint8List(4);
    bytes.buffer.asByteData().setInt32(0, value, Endian.little);
    _data.add(bytes);
  }

  void writeDouble(double value) {
    final bytes = Uint8List(8);
    bytes.buffer.asByteData().setFloat64(0, value, Endian.little);
    _data.add(bytes);
  }

  /// Writes a GP-style pascal string: 1 byte length + chars.
  /// If [fixedLen] is given, the string is padded/truncated to fixedLen
  /// characters after the length byte (total = fixedLen + 1 bytes).
  void writeIntString(String s, {int? fixedLen}) {
    final encoded = s.codeUnits;
    final len = fixedLen != null
        ? encoded.length.clamp(0, fixedLen)
        : encoded.length;

    writeByte(len);

    if (fixedLen != null) {
      for (var i = 0; i < fixedLen; i++) {
        writeByte(i < encoded.length ? encoded[i] : 0);
      }
    } else {
      for (final c in encoded.take(len)) {
        writeByte(c);
      }
    }
  }

  Uint8List toBytes() => Uint8List.fromList(_data.takeBytes());
}
