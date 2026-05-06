/// Unit tests for the pure-Dart MIDI parser.
///
/// Uses the existing fixture produced by the pipeline:
///   output/midi/coronaria-che-esplode/bass/bass_basic_pitch.mid
///
/// Run with: flutter test test/unit/midi_parser_test.dart
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:audio_to_gp_flutter/services/midi_parser.dart';

void main() {
  // Path to the MIDI fixture produced by the previous pipeline run.
  // Adjust if the workspace output directory is different.
  const fixturePath = '../output/midi/coronaria-che-esplode/bass/bass_basic_pitch.mid';

  group('parseMidi — real fixture', () {
    test('parses bass_basic_pitch.mid without throwing', () async {
      final file = File(fixturePath);
      if (!file.existsSync()) {
        markTestSkipped('Fixture not found at $fixturePath — run the pipeline first.');
        return;
      }

      final bytes = await file.readAsBytes();
      final midi = parseMidi(Uint8List.fromList(bytes));

      expect(midi.ppq, greaterThan(0), reason: 'ppq must be positive');
      expect(midi.bpm, greaterThan(0), reason: 'bpm must be positive');
      expect(midi.events, isNotEmpty, reason: 'Real MIDI must have note events');
    });

    test('all note events have valid pitch and velocity', () async {
      final file = File(fixturePath);
      if (!file.existsSync()) {
        markTestSkipped('Fixture not found.');
        return;
      }

      final bytes = await file.readAsBytes();
      final midi = parseMidi(Uint8List.fromList(bytes));

      for (final ev in midi.events) {
        expect(ev.pitch, inInclusiveRange(0, 127));
        expect(ev.velocity, inInclusiveRange(1, 127));
        expect(ev.endTick, greaterThan(ev.startTick));
      }
    });

    test('events are sorted by startTick', () async {
      final file = File(fixturePath);
      if (!file.existsSync()) {
        markTestSkipped('Fixture not found.');
        return;
      }

      final bytes = await file.readAsBytes();
      final midi = parseMidi(Uint8List.fromList(bytes));

      for (var i = 1; i < midi.events.length; i++) {
        expect(
          midi.events[i].startTick,
          greaterThanOrEqualTo(midi.events[i - 1].startTick),
          reason: 'Events must be sorted by startTick',
        );
      }
    });
  });

  group('parseMidi — synthetic data', () {
    test('rejects non-MIDI bytes', () {
      expect(
        () => parseMidi(Uint8List.fromList([0x00, 0x01, 0x02, 0x03])),
        throwsA(isA<FormatException>()),
      );
    });

    test('parses minimal valid MIDI file (Format 0, 1 note)', () {
      final bytes = _buildMinimalMidi(
        ppq: 480,
        noteOn: (tick: 0, pitch: 60, velocity: 80),
        noteOff: (tick: 480, pitch: 60),
      );
      final midi = parseMidi(bytes);

      expect(midi.ppq, equals(480));
      expect(midi.bpm, equals(120));
      expect(midi.events.length, equals(1));
      expect(midi.events[0].pitch, equals(60));
      expect(midi.events[0].velocity, equals(80));
    });

    test('detects BPM from set_tempo meta event', () {
      // 100 BPM → 600000 microseconds per beat
      final bytes = _buildMinimalMidiWithTempo(ppq: 480, tempoUs: 600000);
      final midi = parseMidi(bytes);
      expect(midi.bpm, equals(100));
    });
  });
}

// ---------------------------------------------------------------------------
// Minimal SMF builder helpers
// ---------------------------------------------------------------------------

typedef _NoteOn = ({int tick, int pitch, int velocity});
typedef _NoteOff = ({int tick, int pitch});

Uint8List _buildMinimalMidi({
  required int ppq,
  required _NoteOn noteOn,
  required _NoteOff noteOff,
}) {
  // Format 0, 1 track
  final track = <int>[
    // delta=0, note_on ch0, pitch, velocity
    0x00, 0x90, noteOn.pitch, noteOn.velocity,
    // delta=noteOff.tick (assume < 128), note_off ch0, pitch, 0
    noteOff.tick & 0x7F, 0x80, noteOff.pitch, 0x00,
    // end of track
    0x00, 0xFF, 0x2F, 0x00,
  ];

  return _assembleMidi(ppq: ppq, tracks: [track]);
}

Uint8List _buildMinimalMidiWithTempo({
  required int ppq,
  required int tempoUs,
}) {
  final track = <int>[
    // set_tempo at delta=0
    0x00, 0xFF, 0x51, 0x03,
    (tempoUs >> 16) & 0xFF,
    (tempoUs >> 8) & 0xFF,
    tempoUs & 0xFF,
    // one note
    0x00, 0x90, 60, 80,
    0x78, 0x80, 60, 0x00, // delta=120
    0x00, 0xFF, 0x2F, 0x00,
  ];
  return _assembleMidi(ppq: ppq, tracks: [track]);
}

Uint8List _assembleMidi({required int ppq, required List<List<int>> tracks}) {
  final buf = <int>[];

  // MThd
  buf.addAll([0x4D, 0x54, 0x68, 0x64]); // 'MThd'
  buf.addAll([0x00, 0x00, 0x00, 0x06]); // chunk length = 6
  buf.addAll([0x00, 0x00]); // format 0
  buf.addAll([0x00, 0x01]); // 1 track
  buf.add((ppq >> 8) & 0xFF);
  buf.add(ppq & 0xFF);

  for (final track in tracks) {
    buf.addAll([0x4D, 0x54, 0x72, 0x6B]); // 'MTrk'
    final len = track.length;
    buf.addAll([
      (len >> 24) & 0xFF,
      (len >> 16) & 0xFF,
      (len >> 8) & 0xFF,
      len & 0xFF,
    ]);
    buf.addAll(track);
  }

  return Uint8List.fromList(buf);
}
