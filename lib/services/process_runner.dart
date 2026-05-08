/// Process runner — spawns subprocesses and streams their output.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A line of output from a subprocess.
class ProcessLine {
  const ProcessLine({
    required this.text,
    required this.isStderr,
  });
  final String text;
  final bool isStderr;
}

/// Run a subprocess and yield each output line.
/// Throws [ProcessException] if the exit code is non-zero.
Stream<ProcessLine> runProcess(
  String executable,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async* {
  final proc = await Process.start(
    executable,
    args,
    workingDirectory: workingDirectory,
    environment: {
      ...Platform.environment,
      if (environment != null) ...environment,
      'PYTHONUTF8': '1',
    },
  );

  // Stream lines as they arrive — merge stdout + stderr
  yield* _mergeStreams([
    proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .map((l) => ProcessLine(text: l, isStderr: false)),
    proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .map((l) => ProcessLine(text: l, isStderr: true)),
  ]);

  final exitCode = await proc.exitCode;
  if (exitCode != 0) {
    throw ProcessException(
      executable,
      args,
      'Process exited with code $exitCode',
      exitCode,
    );
  }
}

/// Merge multiple streams into one, yielding items as they arrive.
Stream<T> _mergeStreams<T>(List<Stream<T>> streams) async* {
  final controller = StreamController<T>();
  var pending = streams.length;

  for (final stream in streams) {
    stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: () {
        pending--;
        if (pending == 0) controller.close();
      },
    );
  }

  yield* controller.stream;
}
