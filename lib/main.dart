import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'screens/home_screen.dart';
import 'screens/setup_screen.dart';
import 'services/setup_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AudioToGpApp());
}

class AudioToGpApp extends StatelessWidget {
  const AudioToGpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audio → Guitar Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.dark(
          primary: Colors.greenAccent,
          secondary: Colors.deepPurpleAccent,
        ),
        scaffoldBackgroundColor: const Color(0xFF1A1A2E),
        cardColor: const Color(0xFF16213E),
        dividerColor: Colors.white12,
      ),
      home: const _AppRouter(),
    );
  }
}

/// Decides whether to show SetupScreen or HomeScreen.
class _AppRouter extends StatefulWidget {
  const _AppRouter();

  @override
  State<_AppRouter> createState() => _AppRouterState();
}

class _AppRouterState extends State<_AppRouter> {
  bool _checking = true;
  bool _needsSetup = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    // Pre-extract bundled Python assets so SetupService can copy them
    await _precacheAssets();

    final complete = await SetupService.instance.isSetupComplete();
    if (complete) {
      // Always refresh worker.py from the bundle so code updates take effect
      // without requiring a full reinstall.
      await _refreshWorker();
    }
    if (mounted) {
      setState(() {
        _needsSetup = !complete;
        _checking = false;
      });
    }
  }

  /// Copy worker.py from the app-support staging dir to the tools dir,
  /// but only when the source is newer or has a different size.
  Future<void> _refreshWorker() async {
    final paths = SetupService.instance.paths;
    if (paths == null) return;
    try {
      final appSupport = await getApplicationSupportDirectory();
      final src = File(
          p.join(appSupport.path, 'audio-to-gp', 'assets', 'worker.py'));
      if (!src.existsSync()) return;
      final dst = File(paths.workerPy);
      if (!dst.existsSync() ||
          src.lengthSync() != dst.lengthSync() ||
          src.lastModifiedSync().isAfter(dst.lastModifiedSync())) {
        await src.copy(paths.workerPy);
        debugPrint('worker.py refreshed from bundle');
      }
    } catch (e) {
      debugPrint('Worker refresh warning: $e');
    }
  }

  /// Extract Flutter asset bytes to the app-support staging dir.
  /// Files are only written when their content has changed, which preserves
  /// the modification time so _refreshWorker() can detect updates correctly.
  Future<void> _precacheAssets() async {
    try {
      final appSupport = await getApplicationSupportDirectory();
      final assetDir = p.join(appSupport.path, 'audio-to-gp', 'assets');
      await Directory(assetDir).create(recursive: true);

      for (final assetKey in [
        'assets/python/worker.py',
        'assets/python/pyproject.toml',
      ]) {
        final destFile = File(p.join(assetDir, p.basename(assetKey)));
        final data = await rootBundle.load(assetKey);
        final newBytes =
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        // Only write when content differs so mtime reflects a real update.
        if (!destFile.existsSync() ||
            !_bytesEqual(newBytes, await destFile.readAsBytes())) {
          await destFile.writeAsBytes(newBytes);
        }
      }
    } catch (e) {
      debugPrint('Asset precache warning: $e');
    }
  }

  /// Byte-level equality check used to avoid unnecessary asset writes.
  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_needsSetup) {
      return SetupScreen(
        onComplete: () => setState(() => _needsSetup = false),
      );
    }

    return const HomeScreen();
  }
}


