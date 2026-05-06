/// End-to-end integration tests for the Audio → Guitar Pro pipeline.
///
/// Requirements:
///   - Place `coronaria-che-esplode.mp3` in `test/fixtures/` before running.
///   - Tools must be set up (SetupService.instance.isSetupComplete() == true),
///     OR set the env vars AUDIO_TO_GP_TOOLS_DIR, PYTHON_EXE, UV_EXE, FFMPEG_EXE
///     to point to an existing install.
///   - Tests run sequentially (demucs is GPU-heavy; parallel would exhaust VRAM).
///
/// Run with:
///   flutter test test/integration/pipeline_e2e_test.dart --timeout=none
///
/// NOTE: These tests spawn the full demucs + basic-pitch pipeline. Each model
///       run takes 5–20 minutes on CPU, ~2–5 min on GPU.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:audio_to_gp_flutter/models/pipeline_models.dart';
import 'package:audio_to_gp_flutter/services/midi_parser.dart';
import 'package:audio_to_gp_flutter/services/gp_writer.dart';
import 'package:audio_to_gp_flutter/services/setup_service.dart';
import 'package:audio_to_gp_flutter/services/pipeline_service.dart';

// ---------------------------------------------------------------------------
// Shared test fixtures
// ---------------------------------------------------------------------------

const _kFixtureMp3 = 'test/fixtures/coronaria-che-esplode.mp3';
final _kOutputDir = p.join(
  Directory.systemTemp.path,
  'audio_to_gp_e2e_${DateTime.now().millisecondsSinceEpoch}',
);

void main() {
  late bool mp3Available;
  late bool toolsReady;

  setUpAll(() async {
    mp3Available = File(_kFixtureMp3).existsSync();
    toolsReady = await SetupService.instance.isSetupComplete();

    if (mp3Available && toolsReady) {
      await Directory(_kOutputDir).create(recursive: true);
    }
  });

  tearDownAll(() async {
    // Leave output dir in place — the caller may want to inspect the GP5 files.
    // Uncomment to clean up:
    // if (Directory(_kOutputDir).existsSync()) {
    //   await Directory(_kOutputDir).delete(recursive: true);
    // }
  });

  // ---------------------------------------------------------------------------
  // Model: htdemucs_ft — 4 stems
  // ---------------------------------------------------------------------------

  group('htdemucs_ft (4 stems)', () {
    const model = 'htdemucs_ft';
    const expectedStems = ['bass', 'drums', 'other', 'vocals'];
    late PipelineResult? result;

    setUpAll(() async {
      if (!mp3Available || !toolsReady) return;

      final config = PipelineConfig(
        inputMp3: File(_kFixtureMp3).absolute.path,
        outputDir: _kOutputDir,
        model: model,
        stems: expectedStems,
      );

      PipelineResult? lastResult;
      await for (final event in PipelineService.instance.runModel(config)) {
        // ignore: avoid_print
        print('[${event.model}] ${event.message}');
        if (event.result != null) lastResult = event.result;
      }
      result = lastResult;
    });

    test('mp3 fixture and tools are available', () {
      expect(mp3Available, isTrue,
          reason: 'Place coronaria-che-esplode.mp3 in test/fixtures/');
      expect(toolsReady, isTrue,
          reason: 'Run setup first (SetupService.instance.setup(…))');
    });

    test('pipeline produces a result', () {
      if (!mp3Available || !toolsReady) {
        markTestSkipped('Prerequisites not met');
        return;
      }
      expect(result, isNotNull, reason: 'Pipeline must return a PipelineResult');
    });

    test('MIDI files exist for all 4 stems', () {
      if (!mp3Available || !toolsReady || result == null) {
        markTestSkipped('Prerequisites not met');
        return;
      }

      expect(result!.midiFiles.length, equals(4),
          reason: 'htdemucs_ft should produce exactly 4 MIDI files');

      for (final stemName in expectedStems) {
        expect(result!.midiFiles.containsKey(stemName), isTrue,
            reason: 'Missing MIDI for stem: $stemName');
        expect(
          File(result!.midiFiles[stemName]!).existsSync(),
          isTrue,
          reason: 'MIDI file not found on disk for $stemName',
        );
      }
    });

    test('GP5 file exists and is non-empty', () {
      if (!mp3Available || !toolsReady || result == null) {
        markTestSkipped('Prerequisites not met');
        return;
      }

      final gp5 = File(result!.gp5Path);
      expect(gp5.existsSync(), isTrue,
          reason: 'GP5 file must be written: ${result!.gp5Path}');
      expect(gp5.lengthSync(), greaterThan(200),
          reason: 'GP5 file must have meaningful size');
    });

    test('GP5 filename contains model name', () {
      if (!mp3Available || !toolsReady || result == null) {
        markTestSkipped('Prerequisites not met');
        return;
      }
      expect(p.basename(result!.gp5Path), contains(model));
    });

    test('GP5 file starts with FICHIER GUITAR PRO v5 signature', () {
      if (!mp3Available || !toolsReady || result == null) {
        markTestSkipped('Prerequisites not met');
        return;
      }
      final bytes = File(result!.gp5Path).readAsBytesSync();
      expect(bytes[0], equals(24)); // length of version string
      final versionStr = String.fromCharCodes(bytes.sublist(1, 25));
      expect(versionStr, equals('FICHIER GUITAR PRO v5.00'));
    });

    test('each MIDI file is parseable and has note events', () async {
      if (!mp3Available || !toolsReady || result == null) {
        markTestSkipped('Prerequisites not met');
        return;
      }

      for (final entry in result!.midiFiles.entries) {
        final bytes = await File(entry.value).readAsBytes();
        final midi = parseMidi(Uint8List.fromList(bytes));
        expect(midi.ppq, greaterThan(0),
            reason: '${entry.key}: ppq must be > 0');
        expect(midi.events, isNotEmpty,
            reason: '${entry.key}: must have note events');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Model: htdemucs_6s — 6 stems
  // ---------------------------------------------------------------------------

  group('htdemucs_6s (6 stems)', () {
    const model = 'htdemucs_6s';
    const expectedStems = ['bass', 'drums', 'other', 'vocals', 'guitar', 'piano'];
    late PipelineResult? result;

    setUpAll(() async {
      if (!mp3Available || !toolsReady) return;

      final config = PipelineConfig(
        inputMp3: File(_kFixtureMp3).absolute.path,
        outputDir: _kOutputDir,
        model: model,
        stems: expectedStems,
      );

      PipelineResult? lastResult;
      await for (final event in PipelineService.instance.runModel(config)) {
        // ignore: avoid_print
        print('[${event.model}] ${event.message}');
        if (event.result != null) lastResult = event.result;
      }
      result = lastResult;
    });

    test('mp3 fixture and tools are available', () {
      expect(mp3Available, isTrue,
          reason: 'Place coronaria-che-esplode.mp3 in test/fixtures/');
      expect(toolsReady, isTrue,
          reason: 'Run setup first');
    });

    test('pipeline produces a result', () {
      if (!mp3Available || !toolsReady) {
        markTestSkipped('Prerequisites not met');
        return;
      }
      expect(result, isNotNull);
    });

    test('MIDI files exist for all 6 stems', () {
      if (!mp3Available || !toolsReady || result == null) {
        markTestSkipped('Prerequisites not met');
        return;
      }

      expect(result!.midiFiles.length, equals(6),
          reason: 'htdemucs_6s should produce exactly 6 MIDI files');

      for (final stemName in expectedStems) {
        expect(result!.midiFiles.containsKey(stemName), isTrue,
            reason: 'Missing MIDI for stem: $stemName');
        expect(
          File(result!.midiFiles[stemName]!).existsSync(),
          isTrue,
          reason: 'MIDI file not found for $stemName',
        );
      }
    });

    test('GP5 file exists, non-empty, and contains model name', () {
      if (!mp3Available || !toolsReady || result == null) {
        markTestSkipped('Prerequisites not met');
        return;
      }

      final gp5 = File(result!.gp5Path);
      expect(gp5.existsSync(), isTrue);
      expect(gp5.lengthSync(), greaterThan(200));
      expect(p.basename(result!.gp5Path), contains(model));
    });

    test('GP5 has valid signature', () {
      if (!mp3Available || !toolsReady || result == null) {
        markTestSkipped('Prerequisites not met');
        return;
      }

      final bytes = File(result!.gp5Path).readAsBytesSync();
      expect(bytes[0], equals(24));
      final versionStr = String.fromCharCodes(bytes.sublist(1, 25));
      expect(versionStr, equals('FICHIER GUITAR PRO v5.00'));
    });

    test('guitar and piano stems are present in MIDI output', () {
      if (!mp3Available || !toolsReady || result == null) {
        markTestSkipped('Prerequisites not met');
        return;
      }

      expect(result!.midiFiles.containsKey('guitar'), isTrue,
          reason: 'htdemucs_6s must produce guitar stem');
      expect(result!.midiFiles.containsKey('piano'), isTrue,
          reason: 'htdemucs_6s must produce piano stem');
    });

    test('two GP5 files exist with different sizes (models differ)', () {
      if (!mp3Available || !toolsReady || result == null) {
        markTestSkipped('Prerequisites not met');
        return;
      }

      // Locate the htdemucs_ft GP5 that was produced in the previous group
      final gpDir = p.join(_kOutputDir, 'guitar_pro');
      final trackName = p.basenameWithoutExtension(_kFixtureMp3);
      final ft5 = File(p.join(gpDir, '${trackName}_htdemucs_ft.gp5'));
      final s6 = File(p.join(gpDir, '${trackName}_htdemucs_6s.gp5'));

      expect(ft5.existsSync(), isTrue, reason: 'htdemucs_ft GP5 should exist');
      expect(s6.existsSync(), isTrue, reason: 'htdemucs_6s GP5 should exist');
      // 6-stem file should be larger than 4-stem file
      expect(s6.lengthSync(), greaterThan(ft5.lengthSync()),
          reason: 'htdemucs_6s GP5 should be larger (more tracks)');
    });
  });
}
