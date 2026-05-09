/// Unit tests for the pure-Dart GP5 writer.
///
/// Run with: flutter test test/unit/gp_writer_test.dart
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:audio_to_gp_flutter/services/gp_writer.dart';
import 'package:audio_to_gp_flutter/services/midi_parser.dart';

void main() {
  late Directory tmpDir;

  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('gp_writer_test_');
  });

  tearDownAll(() async {
    await tmpDir.delete(recursive: true);
  });

  group('writeGp5 — synthetic data', () {
    test('throws ArgumentError for empty stems list', () async {
      await expectLater(
        writeGp5([], '${tmpDir.path}/empty.gp5', 'test'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('writes a non-empty file for single stem with notes', () async {
      final midi = _syntheticMidi(bpm: 120, noteCount: 8);
      final stems = [StemMidiData(stemName: 'bass', midi: midi)];
      final outPath = '${tmpDir.path}/single_stem.gp5';

      await writeGp5(stems, outPath, 'test_song');

      final file = File(outPath);
      expect(file.existsSync(), isTrue, reason: 'GP5 file must be created');
      expect(
        file.lengthSync(),
        greaterThan(100),
        reason: 'GP5 file must contain real data',
      );
    });

    test('writes a file starting with FICHIER GUITAR PRO v5 signature', () async {
      final midi = _syntheticMidi(bpm: 120, noteCount: 4);
      final stems = [StemMidiData(stemName: 'guitar', midi: midi)];
      final outPath = '${tmpDir.path}/signature.gp5';

      await writeGp5(stems, outPath, 'sig_test');

      final bytes = await File(outPath).readAsBytes();
      // First byte is the string length byte; then the version string starts.
      // The IntString length byte = 24 (len of 'FICHIER GUITAR PRO v5.00')
      expect(bytes[0], equals(24), reason: 'Version string length byte');
      final versionStr = String.fromCharCodes(bytes.sublist(1, 25));
      expect(versionStr, equals('FICHIER GUITAR PRO v5.00'));
    });

    test('writes a file for 6 stems (htdemucs_6s scenario)', () async {
      final stemNames = ['bass', 'drums', 'guitar', 'piano', 'other', 'vocals'];
      final stems = stemNames.map((name) {
        final midi = _syntheticMidi(bpm: 90, noteCount: 6);
        return StemMidiData(stemName: name, midi: midi);
      }).toList();

      final outPath = '${tmpDir.path}/six_stems.gp5';
      await writeGp5(stems, outPath, 'six_stems_song');

      final file = File(outPath);
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), greaterThan(500));
    });

    test('handles stems with zero notes gracefully', () async {
      final emptyMidi = MidiData(ppq: 480, bpm: 120, events: const []);
      final stems = [
        StemMidiData(stemName: 'vocals', midi: emptyMidi),
        StemMidiData(stemName: 'bass', midi: _syntheticMidi(bpm: 120, noteCount: 4)),
      ];
      final outPath = '${tmpDir.path}/empty_stem.gp5';

      await expectLater(
        writeGp5(stems, outPath, 'empty_stem_test'),
        completes,
      );
      expect(File(outPath).existsSync(), isTrue);
    });
  });
}

// ---------------------------------------------------------------------------
// Synthetic MIDI data builder
// ---------------------------------------------------------------------------

MidiData _syntheticMidi({required int bpm, required int noteCount}) {
  const ppq = 480;
  final events = <NoteEvent>[];

  for (var i = 0; i < noteCount; i++) {
    final startTick = i * ppq; // quarter-note spacing
    final endTick = startTick + ppq - 10;
    events.add(NoteEvent(
      startTick: startTick,
      endTick: endTick,
      pitch: 40 + (i % 20), // pitches 40–59
      velocity: 80,
    ));
  }

  return MidiData(ppq: ppq, bpm: bpm, events: events);
}
