/// Pipeline service: orchestrates the full audio → GP5 pipeline.
///
/// Steps:
///   1+2: Python worker (demucs + basic-pitch) — subprocess
///   3:   Dart MIDI parser + GP5 writer         — in-process (no subprocess)
///
/// Runs both models sequentially, producing two GP5 files.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../models/pipeline_models.dart';
import 'midi_parser.dart';
import 'gp_writer.dart';
import 'setup_service.dart';

// ---------------------------------------------------------------------------
// Event types
// ---------------------------------------------------------------------------

enum PipelineStage { worker, gp, done }

class PipelineEvent {
  const PipelineEvent({
    required this.model,
    required this.stage,
    required this.step,
    required this.pct,
    required this.message,
    this.isError = false,
    this.isDone = false,
    this.result,
  });

  final String model;
  final PipelineStage stage;
  final int step; // 1=demucs, 2=basic-pitch, 3=GP
  final int pct;
  final String message;
  final bool isError;
  final bool isDone;
  final PipelineResult? result;

  @override
  String toString() => '[$model:step$step] $message';
}

// ---------------------------------------------------------------------------
// PipelineService
// ---------------------------------------------------------------------------

class PipelineService {
  PipelineService._();
  static final PipelineService instance = PipelineService._();

  /// Run the pipeline for a single model config.
  /// Yields [PipelineEvent]s for UI progress display.
  Stream<PipelineEvent> runModel(PipelineConfig config) async* {
    final paths = SetupService.instance.paths;
    if (paths == null) {
      yield PipelineEvent(
        model: config.model,
        stage: PipelineStage.worker,
        step: 0,
        pct: 0,
        message: 'Tools not set up. Run setup first.',
        isError: true,
      );
      return;
    }

    // ---- Steps 1 + 2: Python worker -----------------------------------------
    final stemsArg = config.stems.join(',');
    final proc = await Process.start(
      paths.pythonExe,
      [
        paths.workerPy,
        '--input', config.inputMp3,
        '--output-dir', config.outputDir,
        '--model', config.model,
        '--stems', stemsArg,
      ],
      environment: {
        ...Platform.environment,
        'PYTHONUTF8': '1',
        // Add FFmpeg and uv to PATH so demucs and basic-pitch can find them
        'PATH': '${p.dirname(paths.ffmpegExe)};${Platform.environment['PATH'] ?? ''}',
      },
    );

    Map<String, String>? midiFiles;
    String? workerError;

    // Read stdout as JSON lines
    final stdoutFuture = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
      try {
        final obj = jsonDecode(line) as Map<String, dynamic>;
        final type = obj['type'] as String;
        if (type == 'progress') {
          // Emitting inline is not possible here; collect for later yield
          // We use a side-channel list
          _pendingEvents.add(PipelineEvent(
            model: config.model,
            stage: PipelineStage.worker,
            step: obj['step'] as int? ?? 1,
            pct: obj['pct'] as int? ?? 0,
            message: obj['msg'] as String? ?? line,
          ));
        } else if (type == 'done') {
          midiFiles = Map<String, String>.from(obj['midi_files'] as Map);
        } else if (type == 'error') {
          workerError = obj['msg'] as String? ?? 'Unknown worker error';
        }
      } catch (_) {
        // Not JSON — treat as plain log line
        _pendingEvents.add(PipelineEvent(
          model: config.model,
          stage: PipelineStage.worker,
          step: 1,
          pct: 0,
          message: line,
        ));
      }
    });

    // Stream stderr as log lines
    final stderrFuture = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
      _pendingEvents.add(PipelineEvent(
        model: config.model,
        stage: PipelineStage.worker,
        step: 1,
        pct: 0,
        message: '[stderr] $line',
      ));
    });

    // Poll pending events while the process runs
    final exitCodeFuture = proc.exitCode;

    final exitCompleter = Completer<int>();
    exitCodeFuture.then(exitCompleter.complete);

    while (!exitCompleter.isCompleted) {
      // Drain pending events
      while (_pendingEvents.isNotEmpty) {
        yield _pendingEvents.removeAt(0);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // Drain any remaining
    await Future.wait([stdoutFuture, stderrFuture]);
    while (_pendingEvents.isNotEmpty) {
      yield _pendingEvents.removeAt(0);
    }

    final exitCode = await exitCodeFuture;

    if (exitCode != 0 || workerError != null) {
      final msg = workerError ?? 'Worker process exited with code $exitCode';
      yield PipelineEvent(
        model: config.model,
        stage: PipelineStage.worker,
        step: 2,
        pct: 0,
        message: msg,
        isError: true,
      );
      return;
    }

    if (midiFiles == null || midiFiles!.isEmpty) {
      yield PipelineEvent(
        model: config.model,
        stage: PipelineStage.worker,
        step: 2,
        pct: 0,
        message: 'Worker produced no MIDI files.',
        isError: true,
      );
      return;
    }

    yield PipelineEvent(
      model: config.model,
      stage: PipelineStage.worker,
      step: 2,
      pct: 100,
      message: 'Steps 1+2 complete — ${midiFiles!.length} MIDI files.',
    );

    // ---- Step 3: Dart MIDI parser + GP5 writer --------------------------------
    yield PipelineEvent(
      model: config.model,
      stage: PipelineStage.gp,
      step: 3,
      pct: 0,
      message: 'Parsing MIDI files and building Guitar Pro track…',
    );

    final stemDataList = <StemMidiData>[];

    for (final entry in midiFiles!.entries) {
      final stemName = entry.key;
      final midiPath = entry.value;

      try {
        final bytes = await File(midiPath).readAsBytes();
        final midi = parseMidi(Uint8List.fromList(bytes));
        stemDataList.add(StemMidiData(stemName: stemName, midi: midi));
        yield PipelineEvent(
          model: config.model,
          stage: PipelineStage.gp,
          step: 3,
          pct: 20,
          message: 'Parsed $stemName — ${midi.events.length} notes, bpm=${midi.bpm}',
        );
      } catch (e) {
        yield PipelineEvent(
          model: config.model,
          stage: PipelineStage.gp,
          step: 3,
          pct: 0,
          message: 'MIDI parse failed for $stemName: $e',
          isError: true,
        );
        return;
      }
    }

    // Sort stems in a musical order
    const stemOrder = ['bass', 'drums', 'guitar', 'piano', 'other', 'vocals'];
    stemDataList.sort((a, b) {
      final ai = stemOrder.indexOf(a.stemName);
      final bi = stemOrder.indexOf(b.stemName);
      final ai2 = ai == -1 ? 99 : ai;
      final bi2 = bi == -1 ? 99 : bi;
      return ai2.compareTo(bi2);
    });

    final trackName = p.basenameWithoutExtension(config.inputMp3);
    final gpDir = p.join(config.outputDir, 'guitar_pro');
    final gpPath = p.join(gpDir, '${trackName}_${config.model}.gp5');

    try {
      await writeGp5(stemDataList, gpPath, trackName);
    } catch (e) {
      yield PipelineEvent(
        model: config.model,
        stage: PipelineStage.gp,
        step: 3,
        pct: 0,
        message: 'GP5 write failed: $e',
        isError: true,
      );
      return;
    }

    final result = PipelineResult(
      model: config.model,
      trackName: trackName,
      midiFiles: midiFiles!,
      gp5Path: gpPath,
    );

    yield PipelineEvent(
      model: config.model,
      stage: PipelineStage.gp,
      step: 3,
      pct: 100,
      message: 'GP5 written: ${p.basename(gpPath)}',
      isDone: true,
      result: result,
    );
  }

  // Side-channel for events produced during async callbacks
  final _pendingEvents = <PipelineEvent>[];
}
