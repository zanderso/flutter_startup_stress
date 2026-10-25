import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

const String _defaultFlutterRoot = '/usr/local/google/home/zra/flutter/flutter';
const String _defaultFlutterBin = '$_defaultFlutterRoot/bin/flutter';
const String _defaultEngineSrcPath = '$_defaultFlutterRoot/engine/src';
const String _defaultLocalEngine = 'android_profile_arm64';
const String _defaultLocalEngineHost = 'host_profile';
const String _defaultAppPackage = 'dev.flutter.flutter_startup_stress';
const String _defaultMainActivity = '.MainActivity';
const String _deviceTracePath =
    '/data/misc/perfetto-traces/flutter_startup.perfetto-trace';

String _resolveProjectRoot() {
  // tools/bin/tools.dart -> tools/bin -> tools -> project root.
  final scriptFile = File.fromUri(Platform.script);
  return p.normalize(p.join(scriptFile.parent.path, '..', '..'));
}

String _resolveAdbExecutable(String? sdkOrPlatformToolsArg) {
  final String executableName = Platform.isWindows ? 'adb.exe' : 'adb';

  String? checkCandidateDir(String dir) {
    final inPlatformTools = File(p.join(dir, 'platform-tools', executableName));
    if (inPlatformTools.existsSync()) {
      return inPlatformTools.path;
    }
    final direct = File(p.join(dir, executableName));
    if (direct.existsSync()) {
      return direct.path;
    }
    return null;
  }

  if (sdkOrPlatformToolsArg != null && sdkOrPlatformToolsArg.isNotEmpty) {
    final candidateFile = File(sdkOrPlatformToolsArg);
    if (candidateFile.existsSync() &&
        FileSystemEntity.isFileSync(sdkOrPlatformToolsArg)) {
      return candidateFile.path;
    }
    final resolved = checkCandidateDir(sdkOrPlatformToolsArg);
    if (resolved != null) {
      return resolved;
    }
    throw StateError(
      'Could not find $executableName under "$sdkOrPlatformToolsArg" '
      '(checked "$sdkOrPlatformToolsArg/platform-tools/$executableName" and '
      '"$sdkOrPlatformToolsArg/$executableName").',
    );
  }

  final androidHome = Platform.environment['ANDROID_HOME'];
  if (androidHome != null && androidHome.isNotEmpty) {
    final resolved = checkCandidateDir(androidHome);
    if (resolved != null) {
      return resolved;
    }
  }

  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) {
    final resolved = checkCandidateDir(p.join(home, 'Android', 'Sdk'));
    if (resolved != null) {
      return resolved;
    }
  }

  throw StateError(
    'Could not locate $executableName. Checked \$ANDROID_HOME/platform-tools '
    'and \$HOME/Android/Sdk/platform-tools. Specify --android-sdk or set '
    'ANDROID_HOME.',
  );
}

Future<void> _runChecked(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  stdout.writeln('+ $executable ${arguments.join(' ')}');
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      'Exited with code $exitCode',
      exitCode,
    );
  }
}

List<String> _adbArgs(String? deviceSerial, List<String> commandArgs) {
  if (deviceSerial != null && deviceSerial.isNotEmpty) {
    return <String>['-s', deviceSerial, ...commandArgs];
  }
  return commandArgs;
}

class BuildCommand extends Command<int> {
  BuildCommand() {
    argParser
      ..addOption(
        'flutter-bin',
        defaultsTo: _defaultFlutterBin,
        help: 'Path to the flutter CLI binary.',
      )
      ..addOption(
        'local-engine-src-path',
        defaultsTo: _defaultEngineSrcPath,
        help: 'Path to the Flutter engine src directory.',
      )
      ..addOption(
        'local-engine',
        defaultsTo: _defaultLocalEngine,
        help: 'Name of the target local engine build configuration.',
      )
      ..addOption(
        'local-engine-host',
        defaultsTo: _defaultLocalEngineHost,
        help: 'Name of the host local engine build configuration.',
      );
  }

  @override
  String get name => 'build';

  @override
  String get description =>
      'Builds the release APK using the local Android arm64 release engine.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final flutterBin = args['flutter-bin'] as String;
    final engineSrcPath = args['local-engine-src-path'] as String;
    final localEngine = args['local-engine'] as String;
    final localEngineHost = args['local-engine-host'] as String;
    final projectRoot = _resolveProjectRoot();

    await _runChecked(flutterBin, <String>[
      'build',
      'apk',
      '--profile',
      '--local-engine-src-path=$engineSrcPath',
      '--local-engine=$localEngine',
      '--local-engine-host=$localEngineHost',
    ], workingDirectory: projectRoot);
    return 0;
  }
}

class InstallCommand extends Command<int> {
  InstallCommand() {
    argParser
      ..addOption(
        'android-sdk',
        help:
            'Path to the Android SDK (or platform-tools) directory. '
            'Defaults to \$ANDROID_HOME or \$HOME/Android/Sdk.',
      )
      ..addOption(
        'apk',
        help: 'Path to the APK to install (defaults to the release APK).',
      )
      ..addOption(
        'device',
        abbr: 'd',
        help: 'Optional Android device serial passed to adb -s.',
      );
  }

  @override
  String get name => 'install';

  @override
  String get description =>
      'Installs the built release APK onto the attached Android device via adb.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final projectRoot = _resolveProjectRoot();
    final sdkArg =
        (args['android-sdk'] as String?) ??
        (globalResults?['android-sdk'] as String?);
    final adb = _resolveAdbExecutable(sdkArg);
    final apkPath =
        (args['apk'] as String?) ??
        p.join(
          projectRoot,
          'build',
          'app',
          'outputs',
          'flutter-apk',
          'app-profile.apk',
        );
    final deviceSerial = args['device'] as String?;

    await _runChecked(
      adb,
      _adbArgs(deviceSerial, <String>['install', '-r', apkPath]),
      workingDirectory: projectRoot,
    );
    return 0;
  }
}

class RunCommand extends Command<int> {
  RunCommand() {
    argParser
      ..addOption(
        'android-sdk',
        help:
            'Path to the Android SDK (or platform-tools) directory. '
            'Defaults to \$ANDROID_HOME or \$HOME/Android/Sdk.',
      )
      ..addOption(
        'suffix',
        abbr: 's',
        help: 'Optional suffix to include in the saved trace filename.',
      )
      ..addOption(
        'duration-ms',
        defaultsTo: '10000',
        help: 'Duration of the Perfetto trace capture in milliseconds.',
      )
      ..addOption(
        'package',
        defaultsTo: _defaultAppPackage,
        help: 'Android application package name.',
      )
      ..addOption(
        'activity',
        defaultsTo: _defaultMainActivity,
        help: 'Android Activity name to launch.',
      )
      ..addOption(
        'device',
        abbr: 'd',
        help: 'Optional Android device serial passed to adb -s.',
      );
  }

  @override
  String get name => 'run';

  @override
  String get description =>
      'Captures a cold-startup Perfetto trace, saves it to data/, and uninstalls the app.';

  @override
  String get invocation =>
      '${runner!.executableName} $name [suffix] [arguments]';

  @override
  Future<int> run() async {
    final args = argResults!;
    final projectRoot = _resolveProjectRoot();
    final sdkArg =
        (args['android-sdk'] as String?) ??
        (globalResults?['android-sdk'] as String?);
    final adb = _resolveAdbExecutable(sdkArg);
    final deviceSerial = args['device'] as String?;
    final appPackage = args['package'] as String;
    final activity = args['activity'] as String;
    final durationMs = int.parse(args['duration-ms'] as String);

    String? suffix = args['suffix'] as String?;
    if ((suffix == null || suffix.isEmpty) && args.rest.isNotEmpty) {
      suffix = args.rest.first;
    }

    final component = activity.contains('/')
        ? activity
        : '$appPackage/$activity';

    // 1. Force-stop the app before starting the trace.
    await _runChecked(
      adb,
      _adbArgs(deviceSerial, <String>['shell', 'am', 'force-stop', appPackage]),
    );

    // 2. Start Perfetto on the device in the background and feed the config.
    final perfettoConfig =
        '''
buffers: {
  size_kb: 65536
  fill_policy: DISCARD
}
data_sources: {
  config {
    name: "track_event"
  }
}
data_sources: {
  config {
    name: "linux.ftrace"
    ftrace_config {
      atrace_apps: "$appPackage"
    }
  }
}
duration_ms: $durationMs
''';

    final perfettoArgs = _adbArgs(deviceSerial, <String>[
      'shell',
      'perfetto',
      '-c',
      '-',
      '--txt',
      '-o',
      _deviceTracePath,
    ]);
    stdout.writeln('+ $adb ${perfettoArgs.join(' ')}');
    final perfettoProcess = await Process.start(adb, perfettoArgs);
    final stderrFuture = perfettoProcess.stderr.transform(utf8.decoder).join();
    final stdoutFuture = perfettoProcess.stdout.transform(utf8.decoder).join();
    perfettoProcess.stdin.write(perfettoConfig);
    await perfettoProcess.stdin.close();

    // 3. Give traced a moment to activate the session, then cold-start the app.
    await Future<void>.delayed(const Duration(seconds: 2));
    await _runChecked(
      adb,
      _adbArgs(deviceSerial, <String>[
        'shell',
        'am',
        'start',
        '-W',
        '-n',
        component,
      ]),
    );

    // 4. Wait for the Perfetto trace capture to complete.
    final perfettoExit = await perfettoProcess.exitCode;
    final perfettoOut = await stdoutFuture;
    final perfettoErr = await stderrFuture;
    if (perfettoOut.trim().isNotEmpty) {
      stdout.writeln(perfettoOut.trim());
    }
    if (perfettoErr.trim().isNotEmpty) {
      stderr.writeln(perfettoErr.trim());
    }
    if (perfettoExit != 0) {
      throw ProcessException(
        adb,
        perfettoArgs,
        'perfetto exited with code $perfettoExit',
        perfettoExit,
      );
    }

    // 5. Copy the trace from the device to ~/flutter_startup_stress/data with
    //    the optional suffix and a timestamp suffix.
    final dataDir = Directory(p.join(projectRoot, 'data'));
    if (!dataDir.existsSync()) {
      dataDir.createSync(recursive: true);
    }

    final timestamp = _formatTimestamp(DateTime.now());
    final sanitizedSuffix = (suffix != null && suffix.trim().isNotEmpty)
        ? '_${suffix.trim()}'
        : '';
    final traceFileName =
        'flutter_startup${sanitizedSuffix}_$timestamp.perfetto-trace';
    final localTracePath = p.join(dataDir.path, traceFileName);

    await _runChecked(
      adb,
      _adbArgs(deviceSerial, <String>[
        'pull',
        _deviceTracePath,
        localTracePath,
      ]),
    );

    // 6. Uninstall the app from the device.
    await _runChecked(
      adb,
      _adbArgs(deviceSerial, <String>['uninstall', appPackage]),
    );

    stdout.writeln('Saved Perfetto trace to: $localTracePath');
    return 0;
  }

  static String _formatTimestamp(DateTime dt) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final y = dt.year.toString().padLeft(4, '0');
    final m = twoDigits(dt.month);
    final d = twoDigits(dt.day);
    final h = twoDigits(dt.hour);
    final min = twoDigits(dt.minute);
    final s = twoDigits(dt.second);
    return '$y$m${d}_$h$min$s';
  }
}

Future<void> main(List<String> arguments) async {
  final runner =
      CommandRunner<int>(
          'tools.dart',
          'CLI tool for building, installing, and profiling flutter_startup_stress.',
        )
        ..argParser.addOption(
          'android-sdk',
          help:
              'Path to the Android SDK (or platform-tools) directory. '
              'Defaults to \$ANDROID_HOME or \$HOME/Android/Sdk.',
        )
        ..addCommand(BuildCommand())
        ..addCommand(InstallCommand())
        ..addCommand(RunCommand());

  try {
    final exitCode = await runner.run(arguments) ?? 0;
    exit(exitCode);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64);
  }
}
