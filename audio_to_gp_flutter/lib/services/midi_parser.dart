/// Pure-Dart Standard MIDI File (SMF) parser.
///
/// Handles Format 0 (single track) and Format 1 (multi-track, merged).
/// Extracts note events and tempo from the binary .mid file.
library;

import 'dart:typed_data';

/// A single note-on / note-off pair resolved to absolute seconds-or-ticks.
class NoteEvent {
  const NoteEvent({
    required this.startTick,
    required this.endTick,
    required this.pitch,
    required this.velocity,
  });

  /// Absolute start position in MIDI ticks (from start of song).
  final int startTick;

  /// Absolute end position in MIDI ticks.
  final int endTick;

  /// MIDI pitch value (0–127).
  final int pitch;

  /// Note velocity (1–127).
  final int velocity;

  int get durationTicks => endTick - startTick;
}

/// Parsed MIDI data — tempo and all note events from all tracks merged.
class MidiData {
  const MidiData({
    required this.ppq,
    required this.bpm,
    required this.events,
  });

  /// Ticks per quarter note (from MThd header).
  final int ppq;

  /// Detected tempo in BPM (from set_tempo, or 120 if absent).
  final int bpm;

  /// All note events across all tracks, sorted by start tick.
  final List<NoteEvent> events;

  bool get isEmpty => events.isEmpty;
}

/// Parses a Standard MIDI File binary and returns [MidiData].
///
/// Throws [FormatException] if the file header is invalid.
MidiData parseMidi(Uint8List bytes) {
  final reader = _ByteReader(bytes);

  // --- MThd header ---
  final headerChunk = reader.readFourCC();
  if (headerChunk != 'MThd') {
    throw const FormatException('Not a MIDI file: missing MThd chunk');
  }
  final headerLen = reader.readUint32();
  if (headerLen < 6) throw const FormatException('MThd chunk too short');

  reader.readUint16(); // format
  final numTracks = reader.readUint16();
  final timeDivision = reader.readUint16();

  // Skip any extra header bytes
  if (headerLen > 6) reader.skip(headerLen - 6);

  if (timeDivision & 0x8000 != 0) {
    throw const FormatException(
      'SMPTE time code MIDI files are not supported.',
    );
  }
  final ppq = timeDivision; // ticks per quarter note

  // --- Read all MTrk chunks ---
  final allEvents = <_RawEvent>[];
  int tempoUs = 500000; // 120 BPM default

  for (var t = 0; t < numTracks; t++) {
    final trackChunk = reader.readFourCC();
    final trackLen = reader.readUint32();
    if (trackChunk != 'MTrk') {
      reader.skip(trackLen);
      continue;
    }

    final trackBytes = reader.readBytes(trackLen);
    final trackReader = _ByteReader(trackBytes);
    int absoluteTick = 0;
    int runningStatus = 0;

    while (trackReader.hasMore) {
      final delta = trackReader.readVarLen();
      absoluteTick += delta;

      final first = trackReader.peekByte();

      int status;
      if (first & 0x80 != 0) {
        status = trackReader.readByte();
        if (status != 0xF0 && status != 0xF7 && status != 0xFF) {
          runningStatus = status;
        }
      } else {
        // Running status — reuse last status byte
        status = runningStatus;
      }

      final type = status & 0xF0;
      final channel = status & 0x0F;

      if (status == 0xFF) {
        // Meta event
        final metaType = trackReader.readByte();
        final metaLen = trackReader.readVarLen();
        final metaData = trackReader.readBytes(metaLen);
        if (metaType == 0x51 && metaLen >= 3) {
          // Set Tempo
          tempoUs =
              (metaData[0] << 16) | (metaData[1] << 8) | metaData[2];
        }
      } else if (status == 0xF0 || status == 0xF7) {
        // SysEx — skip
        final sysexLen = trackReader.readVarLen();
        trackReader.skip(sysexLen);
      } else if (type == 0x90) {
        // Note On
        final pitch = trackReader.readByte();
        final velocity = trackReader.readByte();
        allEvents.add(_RawEvent(
          tick: absoluteTick,
          type: velocity > 0 ? _EventType.noteOn : _EventType.noteOff,
          channel: channel,
          a: pitch,
          b: velocity,
        ));
      } else if (type == 0x80) {
        // Note Off
        final pitch = trackReader.readByte();
        final velocity = trackReader.readByte();
        allEvents.add(_RawEvent(
          tick: absoluteTick,
          type: _EventType.noteOff,
          channel: channel,
          a: pitch,
          b: velocity,
        ));
      } else if (type == 0xA0 || type == 0xB0 || type == 0xE0) {
        // Aftertouch / CC / Pitch bend — 2 data bytes, skip
        trackReader.readByte();
        trackReader.readByte();
      } else if (type == 0xC0 || type == 0xD0) {
        // Program change / Channel pressure — 1 data byte, skip
        trackReader.readByte();
      } else {
        // Unknown — safe to break; avoid infinite loop on corrupt data
        break;
      }
    }
  }

  // --- Pair note-on / note-off events ---
  // Key: (channel, pitch) → (startTick, velocity)
  final active = <(int, int), (int, int)>{};
  final noteEvents = <NoteEvent>[];

  // Sort by tick so we process in order
  allEvents.sort((a, b) => a.tick.compareTo(b.tick));

  for (final ev in allEvents) {
    final key = (ev.channel, ev.a);
    if (ev.type == _EventType.noteOn) {
      active[key] = (ev.tick, ev.b);
    } else if (ev.type == _EventType.noteOff) {
      final start = active.remove(key);
      if (start != null && ev.tick > start.$1) {
        noteEvents.add(NoteEvent(
          startTick: start.$1,
          endTick: ev.tick,
          pitch: ev.a,
          velocity: start.$2,
        ));
      }
    }
  }

  // Close any still-open notes at the last tick
  if (allEvents.isNotEmpty) {
    final lastTick = allEvents.last.tick;
    for (final entry in active.entries) {
      final (startTick, velocity) = entry.value;
      if (lastTick > startTick) {
        noteEvents.add(NoteEvent(
          startTick: startTick,
          endTick: lastTick + ppq ~/ 4, // add a 16th note of duration
          pitch: entry.key.$2,
          velocity: velocity,
        ));
      }
    }
  }

  noteEvents.sort((a, b) => a.startTick.compareTo(b.startTick));

  final bpm = (60000000 / tempoUs).round().clamp(1, 300);
  return MidiData(ppq: ppq, bpm: bpm, events: noteEvents);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

enum _EventType { noteOn, noteOff }

class _RawEvent {
  const _RawEvent({
    required this.tick,
    required this.type,
    required this.channel,
    required this.a,
    required this.b,
  });
  final int tick;
  final _EventType type;
  final int channel;
  final int a; // pitch
  final int b; // velocity
}

class _ByteReader {
  _ByteReader(this._data) : _pos = 0;

  final Uint8List _data;
  int _pos;

  bool get hasMore => _pos < _data.length;

  int peekByte() => _data[_pos];

  int readByte() => _data[_pos++];

  int readUint16() {
    final v = (_data[_pos] << 8) | _data[_pos + 1];
    _pos += 2;
    return v;
  }

  int readUint32() {
    final v = (_data[_pos] << 24) |
        (_data[_pos + 1] << 16) |
        (_data[_pos + 2] << 8) |
        _data[_pos + 3];
    _pos += 4;
    return v;
  }

  String readFourCC() {
    final chars = [
      _data[_pos],
      _data[_pos + 1],
      _data[_pos + 2],
      _data[_pos + 3],
    ];
    _pos += 4;
    return String.fromCharCodes(chars);
  }

  Uint8List readBytes(int count) {
    final slice = Uint8List.sublistView(_data, _pos, _pos + count);
    _pos += count;
    return slice;
  }

  void skip(int count) => _pos += count;

  /// Read a MIDI variable-length quantity.
  int readVarLen() {
    int result = 0;
    for (var i = 0; i < 4; i++) {
      final byte = readByte();
      result = (result << 7) | (byte & 0x7F);
      if (byte & 0x80 == 0) break;
    }
    return result;
  }
}
