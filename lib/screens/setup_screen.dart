/// Setup wizard screen — shown on first launch.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/setup_service.dart';

// ---------------------------------------------------------------------------
// Stage metadata
// ---------------------------------------------------------------------------

const _kStageOrder = [
  SetupStage.uv,
  SetupStage.python,
  SetupStage.pythonDeps,
  SetupStage.ffmpeg,
  SetupStage.musescore,
  SetupStage.done,
];

const _kStageLabel = {
  SetupStage.uv: 'uv',
  SetupStage.python: 'Python',
  SetupStage.pythonDeps: 'Packages',
  SetupStage.ffmpeg: 'FFmpeg',
  SetupStage.musescore: 'MuseScore',
  SetupStage.done: 'Done',
};

// Overall progress range that each stage occupies (0.0–1.0).
const _kStageStart = {
  SetupStage.uv: 0.00,
  SetupStage.python: 0.10,
  SetupStage.pythonDeps: 0.25,
  SetupStage.ffmpeg: 0.80,
  SetupStage.musescore: 0.95,
  SetupStage.done: 1.00,
};
const _kStageEnd = {
  SetupStage.uv: 0.10,
  SetupStage.python: 0.25,
  SetupStage.pythonDeps: 0.80,
  SetupStage.ffmpeg: 0.95,
  SetupStage.musescore: 1.00,
  SetupStage.done: 1.00,
};

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.onComplete});

  /// Called when setup finishes successfully.
  final VoidCallback onComplete;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _log = <SetupEvent>[];
  final _scrollController = ScrollController();

  bool _running = false;
  bool _done = false;
  bool _hasError = false;
  bool _logExpanded = false;

  double _progress = 0; // 0.0–1.0 overall
  int? _subPct; // 0–100 within current stage
  SetupStage _currentStage = SetupStage.uv;
  final _stagesDone = <SetupStage>{};
  String _currentActivity = 'Starting…';

  @override
  void initState() {
    super.initState();
    _startSetup();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _startSetup() async {
    setState(() {
      _running = true;
      _hasError = false;
      _done = false;
      _log.clear();
      _progress = 0;
      _subPct = null;
      _currentStage = SetupStage.uv;
      _stagesDone.clear();
      _currentActivity = 'Starting…';
    });

    final appSupport = await getApplicationSupportDirectory();
    final assetDir = p.join(appSupport.path, 'audio-to-gp', 'assets');
    await Directory(assetDir).create(recursive: true);

    final workerSrc = p.join(assetDir, 'worker.py');
    final pyprojectSrc = p.join(assetDir, 'pyproject.toml');
    await _extractBundledAsset('assets/python/worker.py', workerSrc);
    await _extractBundledAsset('assets/python/pyproject.toml', pyprojectSrc);

    SetupStage? prevStage;

    await for (final event in SetupService.instance.setup(
      workerPySrc: workerSrc,
      pyprojectTomlSrc: pyprojectSrc,
    )) {
      if (!mounted) return;
      setState(() {
        _log.add(event);

        // Mark previous stage done when stage changes
        if (prevStage != null && prevStage != event.stage) {
          _stagesDone.add(prevStage!);
        }
        prevStage = event.stage;
        _currentStage = event.stage;

        if (event.message.trim().isNotEmpty) {
          _currentActivity = event.message.trim();
        }

        // Interpolate overall progress from subPct within stage range
        if (event.subPct != null) {
          final start = _kStageStart[event.stage]!;
          final end = _kStageEnd[event.stage]!;
          final computed = start + (end - start) * event.subPct! / 100;
          _progress = math.max(_progress, computed);
          _subPct = event.subPct;
        } else {
          // Advance at least to the start of the current stage
          _progress = math.max(_progress, _kStageStart[event.stage]!);
        }

        if (event.isError) _hasError = true;
        if (event.isDone) {
          _done = true;
          _stagesDone.add(SetupStage.done);
          _progress = 1.0;
          _subPct = 100;
        }
      });

      // Auto-scroll log when expanded
      if (_logExpanded) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
            );
          }
        });
      }
    }

    setState(() => _running = false);
    if (_done && !_hasError) widget.onComplete();
  }

  Future<void> _extractBundledAsset(String assetKey, String destPath) async {
    // Actual extraction happens via main.dart's precacheAssets helper.
  }

  @override
  Widget build(BuildContext context) {
    final pct = (_progress * 100).round();
    final indeterminate = _running && !_done && _subPct == null && _log.isEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 580),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Title ─────────────────────────────────────────────────
                  const Text(
                    'Audio → Guitar Pro',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'First-launch setup — downloading tools & packages',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  const SizedBox(height: 28),

                  // ── Stage stepper ─────────────────────────────────────────
                  _StageStepper(
                    stages: _kStageOrder,
                    labels: _kStageLabel,
                    currentStage: _currentStage,
                    doneStages: _stagesDone,
                    hasError: _hasError,
                  ),
                  const SizedBox(height: 24),

                  // ── Overall progress ──────────────────────────────────────
                  Row(
                    children: [
                      const Text(
                        'Overall',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      const Spacer(),
                      Text(
                        indeterminate ? '…' : '$pct%',
                        style: TextStyle(
                          color: _hasError ? Colors.redAccent : Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: LinearProgressIndicator(
                      value: indeterminate ? null : _progress,
                      minHeight: 10,
                      backgroundColor: Colors.white12,
                      color: _hasError
                          ? Colors.redAccent
                          : const Color(0xFF4CAF50),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Activity box ──────────────────────────────────────────
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_running && !_done && !_hasError)
                              Padding(
                                padding: const EdgeInsets.only(top: 1, right: 8),
                                child: const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white38,
                                  ),
                                ),
                              )
                            else if (_done)
                              const Padding(
                                padding: EdgeInsets.only(top: 1, right: 8),
                                child: Icon(
                                  Icons.check_circle_rounded,
                                  color: Color(0xFF4CAF50),
                                  size: 14,
                                ),
                              )
                            else if (_hasError)
                              const Padding(
                                padding: EdgeInsets.only(top: 1, right: 8),
                                child: Icon(
                                  Icons.error_outline,
                                  color: Colors.redAccent,
                                  size: 14,
                                ),
                              ),
                            Expanded(
                              child: Text(
                                _currentActivity,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),

                        // Sub-progress bar (within-stage detail)
                        if (_subPct != null && !_done) ...[
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(3),
                                  child: LinearProgressIndicator(
                                    value: _subPct! / 100,
                                    minHeight: 5,
                                    backgroundColor: Colors.white10,
                                    color: Colors.blueAccent,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '$_subPct%',
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── Log expander ──────────────────────────────────────────
                  InkWell(
                    onTap: () => setState(() => _logExpanded = !_logExpanded),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 6,
                        horizontal: 4,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _logExpanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                            color: Colors.white38,
                            size: 16,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${_logExpanded ? "Hide" : "Show"} log'
                            ' (${_log.length} lines)',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeInOut,
                    child: _logExpanded
                        ? Container(
                            height: 200,
                            margin: const EdgeInsets.only(top: 4),
                            decoration: BoxDecoration(
                              color: Colors.black26,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: ListView.builder(
                              controller: _scrollController,
                              padding: const EdgeInsets.all(10),
                              itemCount: _log.length,
                              itemBuilder: (_, i) {
                                final ev = _log[i];
                                final color = ev.isError
                                    ? Colors.redAccent
                                    : ev.isDone
                                        ? const Color(0xFF4CAF50)
                                        : Colors.white54;
                                return Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 1),
                                  child: Text(
                                    '[${ev.stage.name}] ${ev.message}',
                                    style: TextStyle(
                                      color: color,
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                );
                              },
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),

                  // ── Error banner ──────────────────────────────────────────
                  if (_hasError) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.redAccent.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.error_outline,
                            color: Colors.redAccent,
                            size: 18,
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'Setup encountered an error. Check the log above.',
                              style: TextStyle(
                                color: Colors.redAccent,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          ElevatedButton(
                            onPressed: _startSetup,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent,
                            ),
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // ── MuseScore warning ─────────────────────────────────────
                  if (!_hasError &&
                      _log.any((e) =>
                          e.stage == SetupStage.musescore &&
                          e.message.contains('not found'))) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Icon(
                          Icons.info_outline,
                          color: Colors.amber,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'MuseScore 4 not found — sheet PDF export unavailable.',
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
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stage stepper
// ---------------------------------------------------------------------------

class _StageStepper extends StatelessWidget {
  const _StageStepper({
    required this.stages,
    required this.labels,
    required this.currentStage,
    required this.doneStages,
    required this.hasError,
  });

  final List<SetupStage> stages;
  final Map<SetupStage, String> labels;
  final SetupStage currentStage;
  final Set<SetupStage> doneStages;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (int i = 0; i < stages.length; i++) ...[
          _StageChip(
            label: labels[stages[i]] ?? stages[i].name,
            isDone: doneStages.contains(stages[i]),
            isActive: stages[i] == currentStage &&
                !doneStages.contains(stages[i]),
            isError: hasError &&
                stages[i] == currentStage &&
                !doneStages.contains(stages[i]),
          ),
          if (i < stages.length - 1)
            Expanded(
              child: Container(
                height: 1,
                // shift the connector up to align with the icon center (~9 px)
                margin: const EdgeInsets.only(bottom: 14),
                color: Colors.white12,
              ),
            ),
        ],
      ],
    );
  }
}

class _StageChip extends StatelessWidget {
  const _StageChip({
    required this.label,
    required this.isDone,
    required this.isActive,
    required this.isError,
  });

  final String label;
  final bool isDone;
  final bool isActive;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError
        ? Colors.redAccent
        : isDone
            ? const Color(0xFF4CAF50)
            : isActive
                ? Colors.blueAccent
                : Colors.white24;

    Widget icon;
    if (isDone) {
      icon = Icon(Icons.check_circle_rounded, color: color, size: 18);
    } else if (isError) {
      icon = Icon(Icons.cancel_rounded, color: color, size: 18);
    } else if (isActive) {
      icon = SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2.5, color: color),
      );
    } else {
      icon = Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon,
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }
}
