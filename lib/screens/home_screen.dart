/// Home screen — MP3 file picker + pipeline configuration.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/pipeline_models.dart';
import '../services/setup_service.dart';
import 'results_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _mp3Path;
  String _outputDir = '';
  bool _runHtdemucsFt = true;
  bool _runHtdemucs6s = true;
  bool _includeDrums = true;
  bool _uninstalling = false;
  @override
  void initState() {
    super.initState();
    _initOutputDir();
  }

  Future<void> _initOutputDir() async {
    final tools = SetupService.instance.paths;
    if (tools != null) {
      setState(() {
        _outputDir = p.join(p.dirname(tools.toolsDir), '..', 'output');
      });
    }
  }

  Future<void> _confirmUninstall() async {
    final toolsDir = SetupService.instance.paths?.toolsDir ?? '(not found)';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: const Text(
          'Uninstall dependencies?',
          style: TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This will permanently delete all downloaded tools and Python '
              'packages installed by this app:',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                toolsDir,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'The app will close afterwards. You can reinstall on next launch.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
            ),
            child: const Text('Uninstall'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    setState(() => _uninstalling = true);
    await SetupService.instance.uninstall();

    if (!mounted) exit(0);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16213E),
        title: const Text(
          'Uninstall complete',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'All tools and packages have been removed.\n\n'
          'The app will now close. Re-opening it will start the setup wizard again.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => exit(0),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
            ),
            child: const Text('Close app'),
          ),
        ],
      ),
    );
    exit(0);
  }

  Future<void> _pickMp3() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3'],
      dialogTitle: 'Select MP3 file',
    );
    if (result != null && result.files.single.path != null) {
      setState(() {
        _mp3Path = result.files.single.path!;
        // Default output dir next to the MP3
        _outputDir = p.join(p.dirname(_mp3Path!), 'audio_to_gp_output');
      });
    }
  }

  Future<void> _pickOutputDir() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select output directory',
    );
    if (dir != null) setState(() => _outputDir = dir);
  }

  void _runPipeline() {
    if (_mp3Path == null || _outputDir.isEmpty) return;

    final models = <String>[];
    if (_runHtdemucsFt) models.add('htdemucs_ft');
    if (_runHtdemucs6s) models.add('htdemucs_6s');
    if (models.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least one model.')),
      );
      return;
    }

    final configs = models.map((model) {
      final available = kModelStems[model] ?? [];
      final stems = _includeDrums
          ? available
          : available.where((s) => s != 'drums').toList();
      return PipelineConfig(
        inputMp3: _mp3Path!,
        outputDir: _outputDir,
        model: model,
        stems: stems,
      );
    }).toList();

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ResultsScreen(configs: configs),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasMuseScore = SetupService.instance.paths?.hasMuseScore ?? false;

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16213E),
        title: const Text(
          '🎵 Audio → Guitar Pro',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          if (_uninstalling)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.redAccent,
                  ),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.delete_forever, color: Colors.redAccent),
              tooltip: 'Uninstall — remove downloaded tools & Python packages',
              onPressed: _confirmUninstall,
            ),
          if (!hasMuseScore && !_uninstalling)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Tooltip(
                message: 'MuseScore 4 not found — sheet PDF export unavailable',
                child: Icon(Icons.warning_amber, color: Colors.amber),
              ),
            ),
        ],
      ),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 600),
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── MP3 file picker ──────────────────────────────────────────
              _SectionHeader('Input'),
              const SizedBox(height: 8),
              _FileTile(
                label: _mp3Path != null ? p.basename(_mp3Path!) : 'No file selected',
                subtitle: _mp3Path ?? 'Tap to browse for an MP3 file',
                icon: Icons.audio_file,
                onTap: _pickMp3,
              ),
              const SizedBox(height: 24),

              // ── Output directory ─────────────────────────────────────────
              _SectionHeader('Output Directory'),
              const SizedBox(height: 8),
              _FileTile(
                label: _outputDir.isNotEmpty ? p.basename(_outputDir) : 'Not set',
                subtitle: _outputDir.isNotEmpty ? _outputDir : 'Tap to choose',
                icon: Icons.folder_open,
                onTap: _pickOutputDir,
              ),
              const SizedBox(height: 24),

              // ── Models ───────────────────────────────────────────────────
              _SectionHeader('Models'),
              const SizedBox(height: 8),
              _ModelCheckbox(
                label: 'htdemucs_ft',
                subtitle: '4 stems — bass, drums, other, vocals (fine-tuned, higher quality)',
                value: _runHtdemucsFt,
                onChanged: (v) => setState(() => _runHtdemucsFt = v!),
              ),
              _ModelCheckbox(
                label: 'htdemucs_6s',
                subtitle: '6 stems — bass, drums, other, vocals, guitar, piano',
                value: _runHtdemucs6s,
                onChanged: (v) => setState(() => _runHtdemucs6s = v!),
              ),
              const SizedBox(height: 16),

              // ── Options ──────────────────────────────────────────────────
              _SectionHeader('Options'),
              SwitchListTile(
                title: const Text(
                  'Include drums track in GP5',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  'basic-pitch is pitch-based; drums MIDI will be approximate.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                value: _includeDrums,
                onChanged: (v) => setState(() => _includeDrums = v),
                activeThumbColor: Colors.greenAccent,
              ),
              const SizedBox(height: 32),

              // ── Run button ───────────────────────────────────────────────
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: (_mp3Path != null &&
                          _outputDir.isNotEmpty &&
                          (_runHtdemucsFt || _runHtdemucs6s))
                      ? _runPipeline
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text(
                    'Run Pipeline',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent,
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: Colors.white12,
                    disabledForegroundColor: Colors.white38,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helper widgets
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Text(
        title,
        style: const TextStyle(
          color: Colors.white60,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      );
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            children: [
              Icon(icon, color: Colors.white54, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(color: Colors.white, fontSize: 14)),
                    Text(subtitle,
                        style:
                            const TextStyle(color: Colors.white38, fontSize: 11),
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
            ],
          ),
        ),
      );
}

class _ModelCheckbox extends StatelessWidget {
  const _ModelCheckbox({
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
        title: Text(label, style: const TextStyle(color: Colors.white)),
        subtitle: Text(subtitle,
            style: const TextStyle(color: Colors.white54, fontSize: 11)),
        value: value,
        onChanged: onChanged,
        activeColor: Colors.greenAccent,
        checkColor: Colors.black,
        contentPadding: EdgeInsets.zero,
      );
}
