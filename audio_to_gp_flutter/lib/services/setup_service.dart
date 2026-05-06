/// Auto-setup service: downloads and configures uv, Python, FFmpeg on Windows.
///
/// Tools are stored in %APPDATA%\audio-to-gp\tools\.
/// Progress is reported via [Stream<SetupEvent>].
library;

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
    this.isError = false,
    this.isDone = false,
  });

  final SetupStage stage;
  final String message;
  final int pct; // 0–100
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
  Future<bool> isSetupComplete() async {
    final manifest = await _readManifest();
    if (manifest == null) return false;
    final paths = _pathsFromManifest(manifest);
    if (paths == null) return false;
    // Verify the binaries still exist
    if (!File(paths.uvExe).existsSync()) return false;
    if (!File(paths.pythonExe).existsSync()) return false;
    if (!File(paths.ffmpegExe).existsSync()) return false;
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
        yield* _runUv(uvExe, ['python', 'install', '3.11'], SetupStage.python);
        yield* _runUv(
          uvExe,
          ['venv', '--python', '3.11', venvDir],
          SetupStage.python,
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
    final depsMarker = File(p.join(toolsDir, '.deps_installed'));
    if (!depsMarker.existsSync()) {
      yield SetupEvent(
        stage: SetupStage.pythonDeps,
        message: 'Installing Python dependencies (torch + demucs + basic-pitch)…',
        pct: 0,
      );
      yield SetupEvent(
        stage: SetupStage.pythonDeps,
        message: 'This may take 10–20 minutes on first run (~3 GB download).',
        pct: 5,
      );
      try {
        yield* _runUv(
          uvExe,
          ['pip', 'install', '--project', toolsDir, '--python', pythonExe, '-r', pyprojectDest],
          SetupStage.pythonDeps,
        );
        await depsMarker.writeAsString(DateTime.now().toIso8601String());
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
    final ffmpegExe = p.join(toolsDir, 'ffmpeg', 'bin', 'ffmpeg.exe');
    if (!File(ffmpegExe).existsSync()) {
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
    } else {
      yield SetupEvent(
        stage: SetupStage.ffmpeg,
        message: 'FFmpeg already present.',
        pct: 100,
      );
    }

    if (!File(ffmpegExe).existsSync()) {
      yield SetupEvent(
        stage: SetupStage.ffmpeg,
        message: 'ffmpeg.exe not found after extraction.',
        isError: true,
      );
      return;
    }

    // --- Step 5: MuseScore (detect only — optional) ---
    String? mscorePath;
    for (final candidate in _kMuseScoreDefaultPaths) {
      if (File(candidate).existsSync()) {
        mscorePath = candidate;
        break;
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
  Stream<SetupEvent> _downloadAndExtract({
    required String url,
    required String destDir,
    required SetupStage stage,
    required String label,
  }) async* {
    yield SetupEvent(stage: stage, message: 'Downloading $label…', pct: 10);

    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode} for $url');
    }

    yield SetupEvent(stage: stage, message: 'Extracting $label…', pct: 60);

    final archive = ZipDecoder().decodeBytes(response.bodyBytes);
    await Directory(destDir).create(recursive: true);
    await extractArchiveToDisk(archive, destDir);

    yield SetupEvent(stage: stage, message: '$label extracted.', pct: 100);
  }

  /// Run a uv command and stream its output as SetupEvents.
  Stream<SetupEvent> _runUv(
    String uvExe,
    List<String> args,
    SetupStage stage,
  ) async* {
    final process = await Process.start(
      uvExe,
      args,
      environment: {
        ...Platform.environment,
        'PYTHONUTF8': '1',
      },
    );

    await for (final line in process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      yield SetupEvent(stage: stage, message: line);
    }
    await for (final line in process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      yield SetupEvent(stage: stage, message: line);
    }

    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw Exception('uv ${args.join(' ')} exited with $exitCode');
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
