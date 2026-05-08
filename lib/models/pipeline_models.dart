/// Data models for the pipeline configuration and results.
library;

/// Which demucs model to use and which stems to include.
class PipelineConfig {
  const PipelineConfig({
    required this.inputMp3,
    required this.outputDir,
    required this.model,
    required this.stems,
  });

  final String inputMp3;
  final String outputDir;
  final String model;
  final List<String> stems;

  Map<String, dynamic> toJson() => {
        'inputMp3': inputMp3,
        'outputDir': outputDir,
        'model': model,
        'stems': stems,
      };
}

/// Stem models that demucs can produce per model.
const Map<String, List<String>> kModelStems = {
  'htdemucs': ['bass', 'drums', 'other', 'vocals'],
  'htdemucs_6s': ['bass', 'drums', 'other', 'vocals', 'guitar', 'piano'],
  'htdemucs_ft': ['bass', 'drums', 'other', 'vocals'],
  'mdx_extra': ['bass', 'drums', 'other', 'vocals'],
  'mdx_extra_q': ['bass', 'drums', 'other', 'vocals'],
};

/// Per-stem instrument config (General MIDI program numbers).
class StemInstrumentConfig {
  const StemInstrumentConfig({
    required this.name,
    required this.instrument,
    required this.openStrings,
    required this.midiChannel,
  });

  final String name;
  final int instrument;
  final List<int> openStrings; // MIDI pitches of open strings (highest first)
  final int midiChannel;

  /// Default "piano voicing" strings covering full piano range A0(21)–E6(87).
  static const List<int> pianoStrings = [87, 72, 57, 43, 28, 21];

  static const Map<String, StemInstrumentConfig> defaults = {
    'bass': StemInstrumentConfig(
      name: 'Bass',
      instrument: 33,
      openStrings: [43, 38, 33, 28], // G D A E (4-string)
      midiChannel: 2,
    ),
    'guitar': StemInstrumentConfig(
      name: 'Guitar',
      instrument: 25,
      openStrings: [64, 59, 55, 50, 45, 40], // e B G D A E
      midiChannel: 3,
    ),
    'vocals': StemInstrumentConfig(
      name: 'Vocals',
      instrument: 73,
      openStrings: pianoStrings,
      midiChannel: 4,
    ),
    'piano': StemInstrumentConfig(
      name: 'Piano',
      instrument: 0,
      openStrings: pianoStrings,
      midiChannel: 5,
    ),
    'other': StemInstrumentConfig(
      name: 'Other',
      instrument: 0,
      openStrings: pianoStrings,
      midiChannel: 6,
    ),
    'drums': StemInstrumentConfig(
      name: 'Drums',
      instrument: 0,
      openStrings: [57, 49, 45, 42, 38, 36], // typical drum kit pitches
      midiChannel: 10, // MIDI channel 10 = percussion
    ),
  };

  /// Returns the config for a given stem name, or a piano-voicing default.
  static StemInstrumentConfig forStem(String stemName, int fallbackChannel) {
    final cfg = defaults[stemName.toLowerCase()];
    if (cfg != null) return cfg;
    return StemInstrumentConfig(
      name: stemName[0].toUpperCase() + stemName.substring(1),
      instrument: 0,
      openStrings: pianoStrings,
      midiChannel: fallbackChannel,
    );
  }
}

/// Final pipeline result for a single model run.
class PipelineResult {
  const PipelineResult({
    required this.model,
    required this.trackName,
    required this.midiFiles,
    required this.gp5Path,
    this.error,
  });

  final String model;
  final String trackName;

  /// stem name → absolute MIDI file path
  final Map<String, String> midiFiles;

  /// Absolute path to the written .gp5 file (empty string if failed).
  final String gp5Path;

  final String? error;

  bool get succeeded => error == null && gp5Path.isNotEmpty;
}
