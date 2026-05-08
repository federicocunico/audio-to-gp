/// Auto-setup service: downloads and configures uv, Python, FFmpeg on Windows.
///
/// Tools are stored in %APPDATA%\audio-to-gp\tools\.
/// Progress is reported via [Stream<SetupEvent>].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// ---------------------------------------------------------------------------
// Event types
// ---------------------------------------------------------------------------

enum SetupStage {
  uv,
  python,
  pythonDeps,
  ffmpeg,
  musescore,
  done,
}

class SetupEvent {
  const SetupEvent({
    required this.stage,
    required this.message,
    this.pct = 0,
    this.subPct, // 0–100 within the current stage; null = indeterminate
    this.isError = false,
    this.isDone = false,
  });

  final SetupStage stage;
  final String message;
  final int pct; // overall stage bucket (kept for back-compat)
  final int? subPct;
  final bool isError;
  final bool isDone;

  @override
  String toString() => '[${stage.name}] $message';
}

// ---------------------------------------------------------------------------
// ToolPaths — resolved tool locations
// ---------------------------------------------------------------------------

class ToolPaths {
  const ToolPaths({
    required this.uvExe,
    required this.pythonExe,
    required this.ffmpegExe,
    this.mscore4Exe,
    required this.workerPy,
    required this.toolsDir,
  });

  final String uvExe;
  final String pythonExe;
  final String ffmpegExe;
  final String? mscore4Exe; // optional — MuseScore not auto-installed
  final String workerPy; // extracted worker.py path
  final String toolsDir;

  bool get hasMuseScore => mscore4Exe != null && File(mscore4Exe!).existsSync();

  Map<String, dynamic> toJson() => {
        'uvExe': uvExe,
        'pythonExe': pythonExe,
        'ffmpegExe': ffmpegExe,
        if (mscore4Exe != null) 'mscore4Exe': mscore4Exe,
        'workerPy': workerPy,
        'toolsDir': toolsDir,
      };
}

// ---------------------------------------------------------------------------
// SetupService
// ---------------------------------------------------------------------------

class SetupService {
  SetupService._();
  static final SetupService instance = SetupService._();

  // Cached result after successful setup
  ToolPaths? _paths;
  ToolPaths? get paths => _paths;

  // ---- Download URLs -------------------------------------------------------

  static const _kUvUrl =
      'https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip';

  static const _kFfmpegUrl =
      'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/'
      'ffmpeg-master-latest-win64-gpl-shared.zip';

  static const _kMuseScoreDefaultPaths = [
    r'C:\Program Files\MuseScore 4\bin\MuseScore4.exe',
    r'C:\Program Files\MuseScore4\bin\MuseScore4.exe',
    r'C:\Program Files (x86)\MuseScore 4\bin\MuseScore4.exe',
  ];

  static const _kMuseScoreDownloadUrl =
      'https://musescore.org/en/download';

  // ---- Public API ----------------------------------------------------------

  /// Returns true if all required tools are already set up.

  /// Deletes the entire tools directory (Python venv, packages, uv, FFmpeg,
  /// worker script) and resets cached state.  Call this for "uninstall".
  Future<void> uninstall() async {
    final dir = await _toolsDir();
    final d = Directory(dir);
    if (d.existsSync()) await d.delete(recursive: true);
    _paths = null;
  }
  Future<bool> isSetupComplete() async {
    final manifest = await _readManifest();
    if (manifest == null) return false;
    final paths = _pathsFromManifest(manifest);
    if (paths == null) return false;
    // Verify the binaries still exist
    if (!File(paths.uvExe).existsSync()) return false;
    if (!File(paths.pythonExe).existsSync()) return false;
    if (!File(paths.ffmpegExe).existsSync()) return false;
    // Check the deps marker is current (v4 = setuptools pinned <71 for pkg_resources).
    // If stale, return false so setup() runs and reinstalls packages.
    final depsMarker = File(p.join(paths.toolsDir, '.deps_installed'));
    if (!depsMarker.existsSync()) return false;
    final markerContent = await depsMarker.readAsString();
    final cudaAvailable = await _hasCuda();
    final depsVariant = cudaAvailable ? 'cuda' : 'cpu';
    if (!markerContent.contains('v5') || !markerContent.contains(depsVariant)) {
      return false; // setup() will reinstall only the packages (uv/python/ffmpeg skipped)
    }
    if (!await _pythonDepsHealthy(paths.pythonExe)) {
      return false; // force setup() to repair a stale/broken venv
    }
    _paths = paths;
    return true;
  }

  /// Run full setup. Yields [SetupEvent]s for UI progress display.
  /// On success, [_paths] is populated and the last event has [isDone]=true.
  Stream<SetupEvent> setup({
    required String workerPySrc, // path to the bundled worker.py asset
    required String pyprojectTomlSrc, // path to bundled pyproject.toml asset
  }) async* {
    final toolsDir = await _toolsDir();
    await Directory(toolsDir).create(recursive: true);

    // Keep uv-managed Python inside the app's own tools directory so nothing
    // is scattered across the user's C: drive.
    final pythonInstallDir = p.join(toolsDir, 'python');
    final uvPythonEnv = {'UV_PYTHON_INSTALL_DIR': pythonInstallDir};

    // --- Step 1: uv ---
    final uvExe = p.join(toolsDir, 'uv', 'uv.exe');
    if (!File(uvExe).existsSync()) {
      yield SetupEvent(
        stage: SetupStage.uv,
        message: 'Downloading uv package manager…',
        pct: 0,
      );
      try {
        yield* _downloadAndExtract(
          url: _kUvUrl,
          destDir: p.join(toolsDir, 'uv'),
          stage: SetupStage.uv,
          label: 'uv',
        );
      } catch (e) {
        yield SetupEvent(
          stage: SetupStage.uv,
          message: 'Failed to download uv: $e',
          isError: true,
        );
        return;
      }
    } else {
      yield SetupEvent(stage: SetupStage.uv, message: 'uv already present.', pct: 100);
    }

    if (!File(uvExe).existsSync()) {
      yield SetupEvent(
        stage: SetupStage.uv,
        message: 'uv.exe not found after extraction.',
        isError: true,
      );
      return;
    }

    // --- Step 2: Python 3.11 via uv ---
    final venvDir = p.join(toolsDir, '.venv');
    final pythonExe = p.join(venvDir, 'Scripts', 'python.exe');

    if (!File(pythonExe).existsSync()) {
      yield SetupEvent(
        stage: SetupStage.python,
        message: 'Installing Python 3.11 via uv…',
        pct: 0,
      );
      try {
        yield* _runUv(uvExe, ['python', 'install', '3.11'], SetupStage.python,
            extraEnv: uvPythonEnv);
        yield* _runUv(
          uvExe,
          ['venv', '--python', '3.11', '--seed', venvDir],
          SetupStage.python,
          extraEnv: uvPythonEnv,
        );
      } catch (e) {
        yield SetupEvent(
          stage: SetupStage.python,
          message: 'Python setup failed: $e',
          isError: true,
        );
        return;
      }
    } else {
      yield SetupEvent(
        stage: SetupStage.python,
        message: 'Python venv already present.',
        pct: 100,
      );
    }

    // --- Step 3: Python deps ---
    // Copy pyproject.toml to tools dir and run uv pip install
    final pyprojectDest = p.join(toolsDir, 'pyproject.toml');
    await File(pyprojectTomlSrc).copy(pyprojectDest);

    // Copy worker.py to tools dir
    final workerDest = p.join(toolsDir, 'worker.py');
    await File(workerPySrc).copy(workerDest);

    // Check if we already installed deps (marker file)
    // The marker content encodes the install variant so that changing from
    // onnxruntime → onnxruntime-gpu (or vice-versa) forces a reinstall.
    final depsMarker = File(p.join(toolsDir, '.deps_installed'));
    final cudaAvailable = await _hasCuda();
    final depsVariant = cudaAvailable ? 'cuda' : 'cpu';
    // v4 marker: setuptools pinned <71 so pkg_resources is available.
    final markerContent =
        depsMarker.existsSync() ? await depsMarker.readAsString() : '';
    final markerOk =
        markerContent.contains('v5') && markerContent.contains(depsVariant);
    final depsHealthy = await _pythonDepsHealthy(pythonExe);
    if (!markerOk || !depsHealthy) {
      yield SetupEvent(
        stage: SetupStage.pythonDeps,
      message: !markerOk
        ? 'Installing Python dependencies (torch + demucs + basic-pitch)…'
        : 'Python environment looks stale — repairing dependencies…',
        pct: 0,
      );
      yield SetupEvent(
        stage: SetupStage.pythonDeps,
        message: 'This may take 10–20 minutes on first run (~3 GB download).',
        pct: 5,
      );
      try {
        // cudaAvailable / depsVariant already determined above the marker check.
        final torchIndexUrl = cudaAvailable
            ? 'https://download.pytorch.org/whl/cu121'
            : 'https://download.pytorch.org/whl/cpu';
        yield SetupEvent(
          stage: SetupStage.pythonDeps,
          message: cudaAvailable
              ? 'CUDA GPU detected — installing GPU-enabled PyTorch from $torchIndexUrl…'
              : 'No CUDA GPU detected — installing CPU-only PyTorch…',
          pct: 8,
        );

        // Step A: setuptools — installed first, isolated, so pkg_resources is
        // always present before any other package's dist-info is written.
        // A failed install of basic-pitch or onnxruntime cannot corrupt it.
        yield SetupEvent(
          stage: SetupStage.pythonDeps,
          message: 'Installing setuptools (pkg_resources)…',
          subPct: 10,
        );
        yield* _runUv(
          uvExe,
          [
            'pip', 'install', 'setuptools>=65,<71',
            '--python', pythonExe,
          ],
          SetupStage.pythonDeps,
          extraEnv: uvPythonEnv,
        );

        // Step B: torch + torchaudio from the correct index.
        // Using --index-url (not --extra-index-url) so uv fetches torch
        // exclusively from the PyTorch wheel server, avoiding the CPU build
        // on PyPI.
        yield* _runUv(
          uvExe,
          [
            'pip', 'install',
            'torch>=2.1,<2.4', 'torchaudio>=2.1,<2.4',
            '--index-url', torchIndexUrl,
            '--python', pythonExe,
          ],
          SetupStage.pythonDeps,
          extraEnv: uvPythonEnv,
        );

        // Step C: remaining deps from PyPI (torch + setuptools already installed).
        // basic-pitch is installed WITHOUT the [onnx] extra so we control
        // which onnxruntime variant (CPU vs GPU) gets installed in step D.
        yield* _runUv(
          uvExe,
          [
            'pip', 'install',
            'demucs', 'basic-pitch', 'soundfile>=0.12', 'PyGuitarPro>=0.11',
            '--python', pythonExe,
          ],
          SetupStage.pythonDeps,
          extraEnv: uvPythonEnv,
        );

        // Step D: onnxruntime — GPU build when CUDA is present so basic-pitch
        // can use CUDAExecutionProvider, CPU build otherwise.
        // onnxruntime-gpu and onnxruntime are mutually exclusive wheels;
        // installing the right one here avoids having both.
        final ortPackage =
            cudaAvailable ? 'onnxruntime-gpu' : 'onnxruntime';
        yield SetupEvent(
          stage: SetupStage.pythonDeps,
          message: 'Installing $ortPackage for basic-pitch inference…',
          subPct: 90,
        );
        yield* _runUv(
          uvExe,
          [
            'pip', 'install', ortPackage,
            '--python', pythonExe,
          ],
          SetupStage.pythonDeps,
          extraEnv: uvPythonEnv,
        );
        await depsMarker.writeAsString(
            '${DateTime.now().toIso8601String()} v5 variant=$depsVariant');
      } catch (e) {
        yield SetupEvent(
          stage: SetupStage.pythonDeps,
          message: 'Dependency install failed: $e',
          isError: true,
        );
        return;
      }
    } else {
      yield SetupEvent(
        stage: SetupStage.pythonDeps,
        message: 'Python dependencies already installed.',
        pct: 100,
      );
    }

    // --- Step 4: FFmpeg ---
    final ffmpegLocal = p.join(toolsDir, 'ffmpeg', 'bin', 'ffmpeg.exe');
    late final String ffmpegExe;

    if (File(ffmpegLocal).existsSync()) {
      ffmpegExe = ffmpegLocal;
      yield SetupEvent(
        stage: SetupStage.ffmpeg,
        message: 'FFmpeg already present.',
        pct: 100,
      );
    } else {
      final pathFfmpeg = await _findInPath('ffmpeg');
      if (pathFfmpeg != null) {
        ffmpegExe = pathFfmpeg;
        yield SetupEvent(
          stage: SetupStage.ffmpeg,
          message: 'FFmpeg found in PATH — skipping download.',
          pct: 100,
        );
      } else {
        yield SetupEvent(
          stage: SetupStage.ffmpeg,
          message: 'Downloading FFmpeg…',
          pct: 0,
        );
        try {
          yield* _downloadAndExtract(
            url: _kFfmpegUrl,
            destDir: p.join(toolsDir, 'ffmpeg_raw'),
            stage: SetupStage.ffmpeg,
            label: 'FFmpeg',
          );
          // The zip contains a top-level versioned folder; find and move it.
          await _flattenFfmpegDir(
            p.join(toolsDir, 'ffmpeg_raw'),
            p.join(toolsDir, 'ffmpeg'),
          );
        } catch (e) {
          yield SetupEvent(
            stage: SetupStage.ffmpeg,
            message: 'FFmpeg download failed: $e',
            isError: true,
          );
          return;
        }
        if (!File(ffmpegLocal).existsSync()) {
          yield SetupEvent(
            stage: SetupStage.ffmpeg,
            message: 'ffmpeg.exe not found after extraction.',
            isError: true,
          );
          return;
        }
        ffmpegExe = ffmpegLocal;
      }
    }

    // --- Step 5: MuseScore (detect only — optional) ---
    String? mscorePath;
    for (final candidate in _kMuseScoreDefaultPaths) {
      if (File(candidate).existsSync()) {
        mscorePath = candidate;
        break;
      }
    }
    if (mscorePath == null) {
      for (final name in ['MuseScore4', 'mscore4', 'MuseScore4.exe', 'mscore4.exe']) {
        final found = await _findInPath(name);
        if (found != null) {
          mscorePath = found;
          break;
        }
      }
    }

    yield SetupEvent(
      stage: SetupStage.musescore,
      message: mscorePath != null
          ? 'MuseScore 4 found at $mscorePath'
          : 'MuseScore 4 not found. Sheet export will be unavailable. '
              'Download from $_kMuseScoreDownloadUrl',
      pct: 100,
    );

    // --- Persist manifest ---
    final resolved = ToolPaths(
      uvExe: uvExe,
      pythonExe: pythonExe,
      ffmpegExe: ffmpegExe,
      mscore4Exe: mscorePath,
      workerPy: workerDest,
      toolsDir: toolsDir,
    );
    await _writeManifest(resolved);
    _paths = resolved;

    yield SetupEvent(
      stage: SetupStage.done,
      message: 'Setup complete.',
      pct: 100,
      isDone: true,
    );
  }

  // ---- Private helpers ----------------------------------------------------

  Future<String> _toolsDir() async {
    final appData = await getApplicationSupportDirectory();
    return p.join(appData.path, 'audio-to-gp', 'tools');
  }

  /// Download a zip file and extract it to [destDir].
  /// Emits subPct 0–49 during download, 50–100 during extraction.
  Stream<SetupEvent> _downloadAndExtract({
    required String url,
    required String destDir,
    required SetupStage stage,
    required String label,
  }) async* {
    yield SetupEvent(stage: stage, message: 'Connecting to $label download…', subPct: 0);

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode} for $url');
      }

      final totalBytes = response.contentLength ?? 0;
      var receivedBytes = 0;
      final buffer = BytesBuilder(copy: false);
      int lastSp = -1;

      await for (final chunk in response.stream) {
        buffer.add(chunk);
        receivedBytes += chunk.length;
        final rcvMB = (receivedBytes / 1048576).toStringAsFixed(1);

        if (totalBytes > 0) {
          // Known size — show percentage (mapped to 0–49 to leave room for extraction).
          final sp = (receivedBytes / totalBytes * 49).round().clamp(0, 49);
          if (sp != lastSp) {
            lastSp = sp;
            final totMB = (totalBytes / 1048576).toStringAsFixed(1);
            yield SetupEvent(
              stage: stage,
              message: 'Downloading $label — $rcvMB / $totMB MB',
              subPct: sp,
            );
          }
        } else {
          // Unknown size — emit every ~5 MB so the UI never appears frozen.
          final buckMB = (receivedBytes ~/ (5 * 1048576));
          if (buckMB != lastSp) {
            lastSp = buckMB;
            yield SetupEvent(
              stage: stage,
              message: 'Downloading $label — $rcvMB MB received…',
              subPct: null, // indeterminate
            );
          }
        }
      }

      yield SetupEvent(stage: stage, message: 'Extracting $label…', subPct: 60);
      final archive = ZipDecoder().decodeBytes(buffer.toBytes());
      await Directory(destDir).create(recursive: true);
      await extractArchiveToDisk(archive, destDir);
      yield SetupEvent(stage: stage, message: '$label ready.', subPct: 100);
    } finally {
      client.close();
    }
  }

  /// Returns true if nvidia-smi is available and exits successfully,
  /// indicating at least one CUDA-capable GPU is present.
  Future<bool> _hasCuda() async {
    try {
      final result = await Process.run('nvidia-smi', []);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Validate the minimum import set needed by worker.py runtime.
  Future<bool> _pythonDepsHealthy(String pythonExe) async {
    if (!File(pythonExe).existsSync()) return false;
    try {
      final result = await Process.run(
        pythonExe,
        [
          '-c',
          'import onnxruntime, basic_pitch, pretty_midi, guitarpro; print("ok")',
        ],
        environment: {
          ...Platform.environment,
          'PYTHONUTF8': '1',
        },
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Run a uv command and stream its output as [SetupEvent]s in real-time.
  ///
  /// Both stdout and stderr are interleaved via a polling loop so progress
  /// messages (which uv sends to stderr) appear without waiting for the
  /// process to finish.  Output is parsed to derive [SetupEvent.subPct]:
  ///   • "Resolved N packages" → 5 %
  ///   • Each "Downloading …"  → 5–80 % (proportional to package count)
  ///   • "Prepared …"          → 82 %
  ///   • "Installed …"         → 100 %
  Stream<SetupEvent> _runUv(
    String uvExe,
    List<String> args,
    SetupStage stage, {
    Map<String, String> extraEnv = const {},
  }) async* {
    final pending = <SetupEvent>[];
    var totalPkgs = 0;
    var donePkgs = 0;

    final process = await Process.start(
      uvExe,
      args,
      environment: {
        ...Platform.environment,
        'PYTHONUTF8': '1',
        // Suppress ANSI codes and spinner so output is clean plain text.
        'UV_NO_PROGRESS': '1',
        'NO_COLOR': '1',
        ...extraEnv,
      },
    );

    void onLine(String raw) {
      final line = raw.trim();
      if (line.isEmpty) return;
      int? subPct;

      final rm = RegExp(r'Resolved (\d+) packages?').firstMatch(line);
      if (rm != null) {
        totalPkgs = int.tryParse(rm.group(1)!) ?? 0;
        subPct = 5;
      }
      if (line.startsWith('Downloading ') && totalPkgs > 0) {
        donePkgs++;
        subPct = (5 + donePkgs / totalPkgs * 75).round().clamp(5, 80);
      }
      if (line.startsWith('Prepared ')) subPct = 82;
      if (line.startsWith('Installed ') || line.startsWith('Audited ')) subPct = 100;

      pending.add(SetupEvent(stage: stage, message: line, subPct: subPct));
    }

    final stdoutFuture = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(onLine);
    final stderrFuture = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach(onLine);

    final exitCompleter = Completer<int>();
    process.exitCode.then(exitCompleter.complete);

    while (!exitCompleter.isCompleted) {
      while (pending.isNotEmpty) yield pending.removeAt(0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await Future.wait([stdoutFuture, stderrFuture]);
    while (pending.isNotEmpty) yield pending.removeAt(0);

    final exitCode = await exitCompleter.future;
    if (exitCode != 0) {
      throw Exception('uv ${args.join(' ')} exited with $exitCode');
    }
  }

  /// Returns the full resolved path to [executable] if it exists on the
  /// system PATH (via `where.exe`), or null if not found.
  Future<String?> _findInPath(String executable) async {
    try {
      final result = await Process.run('where.exe', [executable]);
      if (result.exitCode != 0) return null;
      for (final line in (result.stdout as String).split('\n')) {
        final path = line.trim();
        if (path.isNotEmpty && File(path).existsSync()) return path;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// The FFmpeg zip contains a versioned subfolder; find it and rename to 'ffmpeg'.
  Future<void> _flattenFfmpegDir(String rawDir, String destDir) async {
    final entries = await Directory(rawDir).list().toList();
    for (final entry in entries) {
      if (entry is Directory &&
          p.basename(entry.path).toLowerCase().startsWith('ffmpeg')) {
        await entry.rename(destDir);
        return;
      }
    }
    // Fallback: just move rawDir to destDir
    await Directory(rawDir).rename(destDir);
  }

  // ---- Manifest persistence ------------------------------------------------

  Future<String> _manifestPath() async {
    final dir = await _toolsDir();
    return p.join(dir, 'tools_manifest.json');
  }

  Future<Map<String, dynamic>?> _readManifest() async {
    try {
      final path = await _manifestPath();
      final file = File(path);
      if (!file.existsSync()) return null;
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeManifest(ToolPaths paths) async {
    final path = await _manifestPath();
    await File(path).writeAsString(jsonEncode(paths.toJson()));
  }

  ToolPaths? _pathsFromManifest(Map<String, dynamic> m) {
    try {
      return ToolPaths(
        uvExe: m['uvExe'] as String,
        pythonExe: m['pythonExe'] as String,
        ffmpegExe: m['ffmpegExe'] as String,
        mscore4Exe: m['mscore4Exe'] as String?,
        workerPy: m['workerPy'] as String,
        toolsDir: m['toolsDir'] as String,
      );
    } catch (_) {
      return null;
    }
  }
}
