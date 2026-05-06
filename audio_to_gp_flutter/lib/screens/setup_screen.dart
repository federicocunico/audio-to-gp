/// Setup wizard screen — shown on first launch.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/setup_service.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.onComplete});

  /// Called when setup finishes successfully.
  final VoidCallback onComplete;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _log = <SetupEvent>[];
  bool _running = false;
  bool _done = false;
  bool _hasError = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _startSetup();
  }

  Future<void> _startSetup() async {
    setState(() {
      _running = true;
      _hasError = false;
      _done = false;
      _log.clear();
    });

    // Locate bundled assets (extracted at runtime to a writable location)
    final appSupport = await getApplicationSupportDirectory();
    final assetDir = p.join(appSupport.path, 'audio-to-gp', 'assets');
    await Directory(assetDir).create(recursive: true);

    // Write bundled python assets to the app support dir so uv can read them
    // (Flutter assets can't be directly opened as File paths on Windows)
    final workerSrc = p.join(assetDir, 'worker.py');
    final pyprojectSrc = p.join(assetDir, 'pyproject.toml');

    await _extractBundledAsset('assets/python/worker.py', workerSrc);
    await _extractBundledAsset('assets/python/pyproject.toml', pyprojectSrc);

    final stageProgress = {
      SetupStage.uv: 0.10,
      SetupStage.python: 0.25,
      SetupStage.pythonDeps: 0.80,
      SetupStage.ffmpeg: 0.95,
      SetupStage.musescore: 0.99,
      SetupStage.done: 1.0,
    };

    final stream = SetupService.instance.setup(
      workerPySrc: workerSrc,
      pyprojectTomlSrc: pyprojectSrc,
    );

    await for (final event in stream) {
      if (!mounted) return;
      setState(() {
        _log.add(event);
        _progress = stageProgress[event.stage] ?? _progress;
        if (event.isError) _hasError = true;
        if (event.isDone) _done = true;
      });
    }

    setState(() => _running = false);
    if (_done && !_hasError) {
      widget.onComplete();
    }
  }

  Future<void> _extractBundledAsset(String assetKey, String destPath) async {
    // Use Flutter's rootBundle to load asset bytes then write to disk
    // We do this via a DefaultAssetBundle — must be called from a build context
    // or we pass through a ByteData approach.  Here we skip if already extracted.
    // Actual extraction happens in main.dart's precacheAssets helper.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 560),
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Audio → Guitar Pro',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'First-launch setup — downloading tools…',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 24),

              // Progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _running && !_done ? null : _progress,
                  minHeight: 6,
                  backgroundColor: Colors.white12,
                  color: _hasError ? Colors.redAccent : Colors.greenAccent,
                ),
              ),
              const SizedBox(height: 16),

              // Log area
              Container(
                height: 320,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white12),
                ),
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _log.length,
                  itemBuilder: (_, i) {
                    final ev = _log[i];
                    final color = ev.isError
                        ? Colors.redAccent
                        : ev.isDone
                            ? Colors.greenAccent
                            : Colors.white70;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        '[${ev.stage.name}] ${ev.message}',
                        style: TextStyle(
                          color: color,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),

              if (_hasError) ...[
                Text(
                  'Setup encountered an error. Check the log above.',
                  style: TextStyle(color: Colors.redAccent),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _startSetup,
                  child: const Text('Retry'),
                ),
              ],

              if (!_hasError && _log.any((e) => e.stage == SetupStage.musescore && e.message.contains('not found'))) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.info_outline, color: Colors.amber, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'MuseScore 4 not found. Sheet PDF export will be unavailable.',
                        style: TextStyle(color: Colors.amber, fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () => launchUrl(
                        Uri.parse('https://musescore.org/en/download'),
                      ),
                      child: const Text('Download'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
