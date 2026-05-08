/// Results screen — live progress and output display.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/pipeline_models.dart';
import '../services/pipeline_service.dart';

class ResultsScreen extends StatefulWidget {
  const ResultsScreen({super.key, required this.configs});
  final List<PipelineConfig> configs;

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  // Per-model log + result
  final Map<String, List<PipelineEvent>> _logs = {};
  final Map<String, PipelineResult> _results = {};
  final Map<String, bool> _modelDone = {};
  final Map<String, bool> _modelError = {};
  bool _allDone = false;

  @override
  void initState() {
    super.initState();
    _runPipeline();
  }

  Future<void> _runPipeline() async {
    for (final config in widget.configs) {
      _logs[config.model] = [];
      _modelDone[config.model] = false;
      _modelError[config.model] = false;
    }

    // Run models sequentially to avoid VRAM exhaustion
    for (final config in widget.configs) {
      await for (final event in PipelineService.instance.runModel(config)) {
        if (!mounted) return;
        setState(() {
          _logs[config.model]!.add(event);
          if (event.isError) _modelError[config.model] = true;
          if (event.isDone) {
            _modelDone[config.model] = true;
            if (event.result != null) _results[config.model] = event.result!;
          }
        });
      }
    }

    if (mounted) {
      setState(() => _allDone = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16213E),
        title: const Text(
          'Pipeline Results',
          style: TextStyle(color: Colors.white),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // Overall status banner
          if (!_allDone)
            _StatusBanner(
              message: 'Pipeline running…',
              color: Colors.blue,
              icon: Icons.hourglass_top,
            )
          else if (_modelError.values.any((e) => e))
            _StatusBanner(
              message: 'Completed with errors.',
              color: Colors.orange,
              icon: Icons.warning_amber,
            )
          else
            _StatusBanner(
              message: 'All models completed successfully!',
              color: Colors.green,
              icon: Icons.check_circle,
            ),

          const SizedBox(height: 24),

          // Per-model sections
          for (final config in widget.configs) ...[
            _ModelResultCard(
              config: config,
              log: _logs[config.model] ?? [],
              result: _results[config.model],
              isDone: _modelDone[config.model] ?? false,
              hasError: _modelError[config.model] ?? false,
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.message,
    required this.color,
    required this.icon,
  });
  final String message;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Text(message, style: TextStyle(color: color, fontSize: 15)),
          ],
        ),
      );
}

class _ModelResultCard extends StatefulWidget {
  const _ModelResultCard({
    required this.config,
    required this.log,
    required this.result,
    required this.isDone,
    required this.hasError,
  });

  final PipelineConfig config;
  final List<PipelineEvent> log;
  final PipelineResult? result;
  final bool isDone;
  final bool hasError;

  @override
  State<_ModelResultCard> createState() => _ModelResultCardState();
}

class _ModelResultCardState extends State<_ModelResultCard> {
  bool _logExpanded = false;

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final Color statusColor = widget.hasError
        ? Colors.redAccent
        : widget.isDone
            ? Colors.greenAccent
            : Colors.blueAccent;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
          border: Border.all(color: statusColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                if (!widget.isDone && !widget.hasError)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    widget.hasError ? Icons.error_outline : Icons.check_circle,
                    color: statusColor,
                    size: 18,
                  ),
                const SizedBox(width: 10),
                Text(
                  widget.config.model,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${widget.config.stems.length} stems',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),

          // ── Live progress (while running) ─────────────────────────────
          if (!widget.isDone && !widget.hasError && widget.log.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: _PipelineProgress(log: widget.log),
            ),

          if (result != null) ...[
            // GP5 download button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _Gp5Button(gp5Path: result.gp5Path),
            ),
            const SizedBox(height: 12),

            // Stem MIDI list
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: result.midiFiles.entries.map((e) {
                  return Chip(
                    avatar: const Icon(Icons.piano, size: 14),
                    label: Text(e.key, style: const TextStyle(fontSize: 11)),
                    backgroundColor: Colors.white10,
                    labelStyle: const TextStyle(color: Colors.white70),
                    side: BorderSide(color: Colors.white12),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 8),
          ],

          // Log expander
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => setState(() => _logExpanded = !_logExpanded),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(
                          _logExpanded ? Icons.expand_less : Icons.expand_more,
                          color: Colors.white38,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Log (${widget.log.length} lines)',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.log.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.copy,
                      size: 14, color: Colors.white38),
                  tooltip: 'Copy logs to clipboard',
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  onPressed: () async {
                    final text =
                        widget.log.map((e) => e.message).join('\n');
                    await Clipboard.setData(ClipboardData(text: text));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Logs copied to clipboard'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
            ],
          ),

          if (_logExpanded)
            Container(
              height: 200,
              margin: const EdgeInsets.only(left: 12, right: 12, bottom: 12),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(6),
              ),
              child: _LogList(log: widget.log),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pipeline progress widget
// ---------------------------------------------------------------------------

class _PipelineProgress extends StatelessWidget {
  const _PipelineProgress({required this.log});
  final List<PipelineEvent> log;

  static const _stepLabels = {
    1: 'Separating stems (demucs)',
    2: 'Transcribing MIDI (basic-pitch)',
    3: 'Writing Guitar Pro file',
  };

  /// Maps step + pct to an overall 0.0–1.0 progress value.
  static double _overall(int step, int pct) {
    // Step 1: 0–60%, step 2: 60–90%, step 3: 90–100%
    if (step == 1) return pct * 0.60 / 100;
    if (step == 2) return 0.60 + pct * 0.30 / 100;
    if (step == 3) return 0.90 + pct * 0.10 / 100;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    if (log.isEmpty) return const SizedBox.shrink();
    final last = log.last;
    final stepLabel = _stepLabels[last.step] ?? 'Processing…';
    final overall = _overall(last.step, last.pct);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Step label + step-level percentage
        Row(
          children: [
            Text(
              'Step ${last.step}/3: $stepLabel',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const Spacer(),
            Text(
              '${last.pct}%',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Step-level bar (blue)
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: last.pct / 100,
            minHeight: 5,
            backgroundColor: Colors.white10,
            color: Colors.blueAccent,
          ),
        ),
        const SizedBox(height: 6),
        // Overall bar (purple)
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: overall,
            minHeight: 7,
            backgroundColor: Colors.white10,
            color: Colors.deepPurpleAccent,
          ),
        ),
        const SizedBox(height: 5),
        // Latest message
        Text(
          last.message,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 11,
            fontFamily: 'monospace',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _Gp5Button extends StatelessWidget {
  const _Gp5Button({required this.gp5Path});
  final String gp5Path;

  @override
  Widget build(BuildContext context) {
    final exists = File(gp5Path).existsSync();
    return ElevatedButton.icon(
      onPressed: exists
          ? () async {
              // Open the GP5 file using the system default application
              await Process.run('explorer', [gp5Path]);
            }
          : null,
      icon: const Icon(Icons.file_download, size: 16),
      label: Text(
        exists
            ? '🎸 Open ${p.basename(gp5Path)}'
            : 'GP5 not yet ready',
        style: const TextStyle(fontSize: 13),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.deepPurpleAccent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: Colors.white10,
        disabledForegroundColor: Colors.white38,
        minimumSize: const Size(double.infinity, 40),
      ),
    );
  }
}

class _LogList extends StatefulWidget {
  const _LogList({required this.log});
  final List<PipelineEvent> log;

  @override
  State<_LogList> createState() => _LogListState();
}

class _LogListState extends State<_LogList> {
  final _scrollController = ScrollController();

  @override
  void didUpdateWidget(_LogList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Auto-scroll to bottom when new lines arrive
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(8),
      itemCount: widget.log.length,
      itemBuilder: (_, i) {
        final ev = widget.log[i];
        final color = ev.isError
            ? Colors.redAccent
            : ev.isDone
                ? Colors.greenAccent
                : Colors.white60;
        return Text(
          ev.message,
          style: TextStyle(color: color, fontSize: 11, fontFamily: 'monospace'),
        );
      },
    );
  }
}
