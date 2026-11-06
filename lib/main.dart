// Copyright 2026 The Flutter Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:developer' as developer;

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vector_graphics/vector_graphics_compat.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

class PluginStartupSnapshot {
  const PluginStartupSnapshot({
    required this.appVersion,
    required this.deviceModel,
    required this.androidSdkInt,
    required this.documentsDir,
    required this.cacheDir,
    required this.launchCount,
    required this.dbRowCount,
    required this.connectivitySummary,
    required this.batteryLevel,
    required this.canLaunchHttps,
    required this.initializedPluginCount,
  });

  final String appVersion;
  final String deviceModel;
  final int androidSdkInt;
  final String documentsDir;
  final String cacheDir;
  final int launchCount;
  final int dbRowCount;
  final String connectivitySummary;
  final int batteryLevel;
  final bool canLaunchHttps;
  final int initializedPluginCount;
}

Future<T> _traceAsync<T>(String name, Future<T> Function() action) async {
  final task = developer.TimelineTask()..start(name);
  try {
    return await action();
  } finally {
    task.finish();
  }
}

Future<PluginStartupSnapshot> _initializePluginsAtStartup() async {
  return _traceAsync('PluginStartupInit', () async {
    // Launch all independent platform-channel and I/O operations concurrently
    // via Future.wait instead of serializing unrelated awaits back-to-back.
    final prefsFuture = _traceAsync('PluginInit.SharedPreferences', () async {
      final instance = await SharedPreferences.getInstance();
      final nextCount = (instance.getInt('cold_start_count') ?? 0) + 1;
      await Future.wait(<Future<void>>[
        instance.setInt('cold_start_count', nextCount),
        instance.setString('last_boot_mode', 'impeller_profile'),
      ]);
      return instance;
    });

    final storageAndDbFuture = _traceAsync(
      'PluginInit.StorageAndSqflite',
      () async {
        final results = await Future.wait<Object>(<Future<Object>>[
          getApplicationDocumentsDirectory(),
          getTemporaryDirectory(),
        ]);
        final docsPath = (results[0] as dynamic).path as String;
        final tempPath = (results[1] as dynamic).path as String;

        final dbPath = p.join(docsPath, 'startup_telemetry.db');
        final db = await openDatabase(
          dbPath,
          version: 1,
          onCreate: (Database db, int version) async {
            await db.execute(
              'CREATE TABLE startup_events ('
              'id INTEGER PRIMARY KEY AUTOINCREMENT, '
              'timestamp_ms INTEGER NOT NULL, '
              'label TEXT NOT NULL'
              ')',
            );
          },
        );
        await db.insert('startup_events', <String, Object?>{
          'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
          'label': 'cold_start',
        });
        final rows = await db.rawQuery(
          'SELECT COUNT(*) AS count FROM startup_events',
        );
        await db.close();
        return (
          docs: docsPath,
          temp: tempPath,
          dbRowCount: (rows.first['count'] as int?) ?? 1,
        );
      },
    );

    final packageInfoFuture = _traceAsync(
      'PluginInit.PackageInfoPlus',
      PackageInfo.fromPlatform,
    );
    final androidInfoFuture = _traceAsync(
      'PluginInit.DeviceInfoPlus',
      () => DeviceInfoPlugin().androidInfo,
    );
    final connectivityFuture = _traceAsync(
      'PluginInit.ConnectivityPlus',
      () => Connectivity().checkConnectivity(),
    );
    final batteryFuture = _traceAsync('PluginInit.BatteryPlus', () async {
      try {
        return await Battery().batteryLevel;
      } catch (_) {
        return 100;
      }
    });
    final canLaunchFuture = _traceAsync(
      'PluginInit.UrlLauncher',
      () => canLaunchUrl(Uri.parse('https://flutter.dev')),
    );

    final prefs = await prefsFuture;
    final storageAndDb = await storageAndDbFuture;
    final packageInfo = await packageInfoFuture;
    final androidInfo = await androidInfoFuture;
    final connectivity = await connectivityFuture;
    final batteryLevel = await batteryFuture;
    final canLaunchHttps = await canLaunchFuture;

    // Retain all 13 plugin bindings against AOT tree-shaking without blocking
    // runApp() or synchronous frame-1 widget construction.
    final extraRefs = <Object?>[
      ImagePicker(),
      WebViewPlatform.instance,
      accelerometerEventStream(),
      SharePlus.instance,
      VideoPlayerController.networkUrl(
        Uri.parse(
          'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
        ),
      ),
    ];

    return PluginStartupSnapshot(
      appVersion: '${packageInfo.version}+${packageInfo.buildNumber}',
      deviceModel: androidInfo.model,
      androidSdkInt: androidInfo.version.sdkInt,
      documentsDir: storageAndDb.docs,
      cacheDir: storageAndDb.temp,
      launchCount: prefs.getInt('cold_start_count') ?? 1,
      dbRowCount: storageAndDb.dbRowCount,
      connectivitySummary:
          connectivity.isEmpty || connectivity.contains(ConnectivityResult.none)
          ? 'Offline'
          : connectivity.map((c) => c.name).join(','),
      batteryLevel: batteryLevel,
      canLaunchHttps: canLaunchHttps,
      initializedPluginCount: 8 + extraRefs.length,
    );
  });
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Follow Flutter startup best practices: call runApp() immediately without
  // awaiting non-blocking plugin initialization, and integrate async plugin
  // results reactively via FutureBuilder once the first frame is scheduled.
  runApp(const MainApp());
}

const BytesLoader _carSvgLoader = AssetBytesLoader('assets/car.svg.vec');
const BytesLoader _jupiterSvgLoader = AssetBytesLoader(
  'assets/jupiter.svg.vec',
);

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  late final Future<PluginStartupSnapshot> _startupSnapshotFuture;

  @override
  void initState() {
    super.initState();
    // Create the Future once in initState() (never inside build()) and kick off
    // async plugin initialization after the initial frame is scheduled so first
    // frame build/layout/paint/rasterization proceeds immediately.
    _startupSnapshotFuture = Future<PluginStartupSnapshot>.microtask(
      _initializePluginsAtStartup,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flutter Plugin Startup Stress',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
        useMaterial3: true,
      ),
      home: Scaffold(
        backgroundColor: const Color(0xFFF4F6FA),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0D1B2A),
          foregroundColor: Colors.white,
          elevation: 2,
          leadingWidth: 44,
          titleSpacing: 0,
          leading: const Icon(Icons.speed_rounded, size: 22),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Startup Stress Suite',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
              FutureBuilder<PluginStartupSnapshot>(
                future: _startupSnapshotFuture,
                builder:
                    (
                      BuildContext context,
                      AsyncSnapshot<PluginStartupSnapshot> snapshot,
                    ) {
                      final data = snapshot.data;
                      final subtitle = data != null
                          ? '${data.deviceModel} (API ${data.androidSdkInt}) • ${data.initializedPluginCount} plugins • #${data.launchCount}'
                          : 'Cold start • Initializing 13 plugins…';
                      return Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          color: Color(0xFFB0BEC5),
                        ),
                      );
                    },
              ),
            ],
          ),
          actions: <Widget>[
            FutureBuilder<PluginStartupSnapshot>(
              future: _startupSnapshotFuture,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<PluginStartupSnapshot> snapshot,
                  ) {
                    final ready = snapshot.hasData;
                    final accent = ready
                        ? const Color(0xFF69F0AE)
                        : const Color(0xFF90CAF9);
                    return Container(
                      margin: const EdgeInsets.symmetric(vertical: 12),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: accent.withValues(alpha: 0.8),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            ready
                                ? Icons.check_circle_rounded
                                : Icons.bolt_rounded,
                            size: 13,
                            color: accent,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            ready ? 'READY' : 'WARMING',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: accent,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
            ),
            IconButton(
              onPressed: () {
                setState(() {});
              },
              tooltip: 'Rebuild scene',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh_rounded, size: 20),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: <Widget>[
            _HeroBannerSection(startupSnapshotFuture: _startupSnapshotFuture),
            const SizedBox(height: 12),
            const _MetricsGridSection(),
            const SizedBox(height: 12),
            const _MediaGallerySection(),
            const SizedBox(height: 12),
            const _TypographyAndFeedSection(),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.white,
          selectedItemColor: const Color(0xFF1565C0),
          unselectedItemColor: const Color(0xFF607D8B),
          selectedLabelStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
          unselectedLabelStyle: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w400,
          ),
          items: const <BottomNavigationBarItem>[
            BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_rounded),
              label: 'Overview',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.timeline_rounded),
              label: 'Traces',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.memory_rounded),
              label: 'Shaders',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.layers_rounded),
              label: 'Atlas',
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroBannerSection extends StatelessWidget {
  const _HeroBannerSection({required this.startupSnapshotFuture});

  final Future<PluginStartupSnapshot> startupSnapshotFuture;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 3,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Image.asset(
              'assets/hero_banner.png',
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[
                    const Color(0xFF0A192F).withValues(alpha: 0.90),
                    const Color(0xFF112240).withValues(alpha: 0.78),
                    const Color(0xFF1D3557).withValues(alpha: 0.88),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2979FF),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'COLD START BENCHMARK • IMPELLER',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'First-Frame Pipeline Stress',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                              height: 1.12,
                            ),
                          ),
                          const SizedBox(height: 5),
                          const Text(
                            'Concurrent plugin channels, multi-weight glyph atlas & shader compilation',
                            style: TextStyle(
                              color: Color(0xFFCFD8DC),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w400,
                              fontStyle: FontStyle.italic,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      width: 92,
                      height: 64,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.20),
                        ),
                      ),
                      child: createCompatVectorGraphic(
                        loader: _carSvgLoader,
                        width: 80,
                        height: 52,
                        fit: BoxFit.contain,
                        strategy: RenderingStrategy.picture,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                FutureBuilder<PluginStartupSnapshot>(
                  future: startupSnapshotFuture,
                  builder:
                      (
                        BuildContext context,
                        AsyncSnapshot<PluginStartupSnapshot> snapshot,
                      ) {
                        final data = snapshot.data;
                        return Row(
                          children: <Widget>[
                            _HeroMetricPill(
                              label: 'PLUGINS',
                              value: data != null
                                  ? '${data.initializedPluginCount} Ready'
                                  : '13 Async',
                              delta: data != null
                                  ? 'v${data.appVersion}'
                                  : 'Pending',
                            ),
                            const SizedBox(width: 8),
                            _HeroMetricPill(
                              label: 'SQLITE LOG',
                              value: data != null
                                  ? '${data.dbRowCount} ${data.dbRowCount == 1 ? "Row" : "Rows"}'
                                  : 'Opening…',
                              delta: data != null
                                  ? 'Run #${data.launchCount}'
                                  : 'WAL',
                            ),
                            const SizedBox(width: 8),
                            _HeroMetricPill(
                              label: 'DEVICE IO',
                              value: data != null
                                  ? '${data.batteryLevel}% Batt'
                                  : 'Probing…',
                              delta: data != null
                                  ? data.connectivitySummary.toUpperCase()
                                  : 'IPC',
                            ),
                          ],
                        );
                      },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroMetricPill extends StatelessWidget {
  const _HeroMetricPill({
    required this.label,
    required this.value,
    required this.delta,
  });

  final String label;
  final String value;
  final String delta;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF90CAF9),
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              delta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF69F0AE),
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricsGridSection extends StatelessWidget {
  const _MetricsGridSection();

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: Card(
              elevation: 1,
              margin: EdgeInsets.zero,
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const Expanded(
                          child: Text(
                            'UI Complexity',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF455A64),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE3F2FD),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            '1.ui',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1565C0),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: <Widget>[
                        Text(
                          '14',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF0D1B2A),
                          ),
                        ),
                        SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            'Font Styles',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF607D8B),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: const LinearProgressIndicator(
                        value: 0.68,
                        minHeight: 6,
                        backgroundColor: Color(0xFFECEFF1),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Color(0xFF1E88E5),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Weights w200–w900, vector paths, clips & elevation shadows on frame 1.',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w300,
                        color: Color(0xFF546E7A),
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Card(
              elevation: 1,
              margin: EdgeInsets.zero,
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        const Expanded(
                          child: Text(
                            'Shader & SVG',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF455A64),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        ClipOval(
                          child: Container(
                            width: 26,
                            height: 26,
                            color: const Color(0xFFE0F2F1),
                            padding: const EdgeInsets.all(2),
                            child: createCompatVectorGraphic(
                              loader: _jupiterSvgLoader,
                              width: 22,
                              height: 22,
                              fit: BoxFit.contain,
                              strategy: RenderingStrategy.picture,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: <Widget>[
                        Text(
                          '25+',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF00695C),
                          ),
                        ),
                        SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            'PSO Variants',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF00897B),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: const LinearProgressIndicator(
                        value: 0.82,
                        minHeight: 6,
                        backgroundColor: Color(0xFFE0F2F1),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Color(0xFF00897B),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Exercises background pipeline warm-up overlapped with texture & glyph blits.',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w300,
                        color: Color(0xFF546E7A),
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaGallerySection extends StatelessWidget {
  const _MediaGallerySection();

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text(
                    'Asset & Texture Sampling',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF102A43),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE3F2FD),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    '4 PNG + 2 SVG',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1565C0),
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Row(
              children: <Widget>[
                Expanded(
                  child: _GalleryCard(
                    assetPath: 'assets/gallery_1.png',
                    title: 'Procedural Texture',
                    subtitle: 'RGBA8 • Bilinear',
                    tag: 'SAMPLER',
                  ),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: _GalleryCard(
                    assetPath: 'assets/gallery_2.png',
                    title: 'Glyph Atlas Backing',
                    subtitle: 'A8 + RGBA • Skia',
                    tag: 'ATLAS',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GalleryCard extends StatelessWidget {
  const _GalleryCard({
    required this.assetPath,
    required this.title,
    required this.subtitle,
    required this.tag,
  });

  final String assetPath;
  final String title;
  final String subtitle;
  final String tag;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Stack(
            children: <Widget>[
              SizedBox(
                height: 84,
                width: double.infinity,
                child: Image.asset(
                  assetPath,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.low,
                ),
              ),
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    tag,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1E293B),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TypographyAndFeedSection extends StatelessWidget {
  const _TypographyAndFeedSection();

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Multi-Weight Typography & Subsystems',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 6),
            const Text.rich(
              TextSpan(
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF334155),
                  height: 1.35,
                ),
                children: <InlineSpan>[
                  TextSpan(
                    text: 'Weight w200 Thin • ',
                    style: TextStyle(fontWeight: FontWeight.w200, fontSize: 12),
                  ),
                  TextSpan(
                    text: 'w300 Light • ',
                    style: TextStyle(fontWeight: FontWeight.w300, fontSize: 13),
                  ),
                  TextSpan(
                    text: 'w400 Regular • ',
                    style: TextStyle(fontWeight: FontWeight.w400, fontSize: 14),
                  ),
                  TextSpan(
                    text: 'w500 Medium • ',
                    style: TextStyle(fontWeight: FontWeight.w500, fontSize: 15),
                  ),
                  TextSpan(
                    text: 'w600 SemiBold • ',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                  TextSpan(
                    text: 'w700 Bold • ',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
                  ),
                  TextSpan(
                    text: 'w900 Black',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 19),
                  ),
                ],
              ),
            ),
            const Divider(height: 20),
            const _SubsystemRow(
              title: 'PlatformView::\u200BSetupImpellerContext',
              description: 'Initializes rendering backend context and warms default shader pipelines.',
              metric: 'STAGE 1',
              badge: 'CONTEXT',
              badgeColor: Color(0xFF2E7D32),
              avatarTint: Color(0x00000000),
              titleSize: 14.5,
              titleWeight: FontWeight.w700,
            ),
            const SizedBox(height: 12),
            const _SubsystemRow(
              title: 'Typographer::\u200BCreateGlyphAtlas',
              description: 'Rasterizes multi-size glyphs (9pt–28pt, w200–w900) and uploads to GPU atlas.',
              metric: 'STAGE 2',
              badge: 'ATLAS',
              badgeColor: Color(0xFF1565C0),
              avatarTint: Color(0x281565C0),
              titleSize: 14,
              titleWeight: FontWeight.w600,
            ),
            const SizedBox(height: 12),
            const _SubsystemRow(
              title: 'PipelineLibrary::\u200BGetPipeline',
              description: 'Compiles and links shader variants asynchronously off the UI thread.',
              metric: 'STAGE 3',
              badge: 'SHADERS',
              badgeColor: Color(0xFF6A1B9A),
              avatarTint: Color(0x286A1B9A),
              titleSize: 14,
              titleWeight: FontWeight.w500,
            ),
          ],
        ),
      ),
    );
  }
}

class _SubsystemRow extends StatelessWidget {
  const _SubsystemRow({
    required this.title,
    required this.description,
    required this.metric,
    required this.badge,
    required this.badgeColor,
    required this.avatarTint,
    required this.titleSize,
    required this.titleWeight,
  });

  final String title;
  final String description;
  final String metric;
  final String badge;
  final Color badgeColor;
  final Color avatarTint;
  final double titleSize;
  final FontWeight titleWeight;

  @override
  Widget build(BuildContext context) {
    Widget avatar = Image.asset('assets/avatar.png', fit: BoxFit.cover);
    if (avatarTint.a > 0) {
      avatar = ColorFiltered(
        colorFilter: ColorFilter.mode(avatarTint, BlendMode.srcATop),
        child: avatar,
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(19),
          child: SizedBox(width: 38, height: 38, child: avatar),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: titleWeight,
                  color: const Color(0xFF1E293B),
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                description,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: Color(0xFF475569),
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Text(
              metric,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: badgeColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                badge,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  color: badgeColor,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
