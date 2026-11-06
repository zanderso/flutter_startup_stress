# flutter_plugin_startup_stress

`flutter_plugin_startup_stress` is an Android cold-startup benchmark app designed to stress Flutter's first-frame rendering pipeline alongside realistic async plugin initialization. Immediately upon `runApp()`, it renders a scene containing 14+ font styles across weights `w200`–`w900`, `vector_graphics` SVGs, decoded PNG textures, gradients, clips, elevation shadows, and color filters (requiring dozens of Impeller shader and pipeline variants) while concurrently initializing 13 common plugins (`sqflite`, `shared_preferences`, `path_provider`, `device_info_plus`, `package_info_plus`, `connectivity_plus`, `battery_plus`, `url_launcher`, `webview_flutter`, `video_player`, `image_picker`, `sensors_plus`, and `share_plus`).

---

## Gathering Cold-Startup Perfetto Traces with `tools.dart`

The repository includes a CLI helper at `tools/bin/tools.dart` that automates building the profile APK against a local Flutter engine checkout, installing it onto an attached Android device, and capturing cold-startup Perfetto traces and verification screenshots.

### Prerequisites

1. **Flutter checkout & local engine build**:
   Build the Android arm64 profile engine and matching host profile engine in your `flutter/flutter` checkout:
   ```bash
   ./engine/src/flutter/bin/et build -c android_profile_arm64 --no-rbe
   ./engine/src/flutter/bin/et build -c host_profile --no-rbe
   ```
   *(On Apple Silicon macOS hosts, build `host_profile_arm64` instead of `host_profile`.)*

2. **Attached Android device (`arm64`)**:
   Connect an Android device with USB debugging enabled. `tools.dart` locates `adb` automatically via `$ANDROID_HOME/platform-tools` or `$HOME/Android/Sdk/platform-tools` (or you can pass `--android-sdk`).

3. **Resolve tool & app dependencies**:
   From the root of `flutter_plugin_startup_stress`:
   ```bash
   flutter pub get
   ```

---

### Quickstart

Run all commands from the `flutter_plugin_startup_stress` root directory:

```bash
# 1. Build the profile APK using your local engine checkout
dart run tools/bin/tools.dart build \
  --flutter-bin=/path/to/flutter/bin/flutter \
  --local-engine-src-path=/path/to/flutter/engine/src \
  --local-engine=android_profile_arm64 \
  --local-engine-host=host_profile

# 2. Install the built profile APK onto the attached device
dart run tools/bin/tools.dart install

# 3. Cold-start the app, record a Perfetto trace + screenshot to data/, and uninstall
dart run tools/bin/tools.dart run baseline_run1
```

Once `run` finishes, inspect the trace in the [Perfetto UI](https://ui.perfetto.dev) by opening the generated file under `data/`:
* `data/flutter_startup_baseline_run1_<YYYYMMDD_HHMMSS>.perfetto-trace`
* `data/flutter_startup_baseline_run1_<YYYYMMDD_HHMMSS>.png`

---

### CLI Commands & Options

Global option available on all commands:
* `--android-sdk=<path>`: Path to the Android SDK root or `platform-tools` directory (overrides `$ANDROID_HOME` and `$HOME/Android/Sdk`).

#### 1. `build`

Builds `build/app/outputs/flutter-apk/app-profile.apk` in `--profile` mode against your local engine build.

```bash
dart run tools/bin/tools.dart build [arguments]
```

| Option | Description | Default |
| :--- | :--- | :--- |
| `--flutter-bin` | Path to the `flutter` CLI executable. | `<defaultFlutterRoot>/bin/flutter` |
| `--local-engine-src-path` | Path to the Flutter `engine/src` directory. | `<defaultFlutterRoot>/engine/src` |
| `--local-engine` | Target local engine configuration name. | `android_profile_arm64` |
| `--local-engine-host` | Host local engine configuration name (e.g. `host_profile` or `host_profile_arm64`). | `host_profile` |

#### 2. `install`

Installs the profile APK onto the connected Android device via `adb install -r`. Because `run` uninstalls the app at the end of each capture to guarantee a clean cold start, run `install` before each `run` invocation.

```bash
dart run tools/bin/tools.dart install [arguments]
```

| Option | Description | Default |
| :--- | :--- | :--- |
| `--apk` | Path to the APK to install. | `build/app/outputs/flutter-apk/app-profile.apk` |
| `-d`, `--device` | Android device serial passed to `adb -s` (required when multiple devices are attached). | *(single attached device)* |
| `--android-sdk` | Path to Android SDK or `platform-tools`. | `$ANDROID_HOME` or `$HOME/Android/Sdk` |

#### 3. `run`

Performs a clean cold-startup Perfetto trace capture and saves both the trace and a verification screenshot to `data/`.

Specifically, `run` executes the following steps in order:
1. Force-stops the app (`adb shell am force-stop`) so no warm process exists.
2. Starts an on-device `perfetto` session (`64 MiB` buffer) recording the `track_event` (Flutter/Impeller/Dart timeline slices) and `linux.ftrace` (`atrace_apps` for the package) data sources.
3. Waits 2 seconds for `traced` to activate, then cold-starts the activity via `adb shell am start -W -n ...` (printing Android's `LaunchState`, `TotalTime`, and `WaitTime`).
4. Waits for the trace session to complete (`--duration-ms`, default `10000` ms).
5. Pulls `/data/misc/perfetto-traces/flutter_startup.perfetto-trace` to `data/flutter_startup[_<suffix>]_<timestamp>.perfetto-trace`.
6. Captures an on-device screenshot (`adb exec-out screencap -p`) to `data/flutter_startup[_<suffix>]_<timestamp>.png`.
7. Force-stops and uninstalls the app from the device (unless `--wait-for-quit` / `-w` is specified).

```bash
dart run tools/bin/tools.dart run [suffix] [arguments]
```

| Option | Description | Default |
| :--- | :--- | :--- |
| `[suffix]` or `-s`, `--suffix` | Label inserted into the output trace and screenshot filenames (`flutter_startup_<suffix>_<timestamp>`). | *(none)* |
| `--duration-ms` | Duration of the Perfetto trace session in milliseconds. | `10000` |
| `-w`, `--wait-for-quit` | Keep the app running after saving the trace and screenshot; blocks and ignores all other input until `'q'` is pressed, then stops and uninstalls the app. | `false` |
| `-d`, `--device` | Android device serial passed to `adb -s`. | *(single attached device)* |
| `--package` | Android application package name to trace, launch, and uninstall. | `dev.flutter.flutter_startup_stress` |
| `--activity` | Activity name to launch. | `.MainActivity` |
| `--android-sdk` | Path to Android SDK or `platform-tools`. | `$ANDROID_HOME` or `$HOME/Android/Sdk` |

---

### Common Workflows

#### Keep the app open for interactive inspection (`--wait-for-quit` / `-w`)

To inspect the rendered UI on the device after the startup trace and screenshot have been saved, pass `-w` (or `--wait-for-quit`). The tool will block until you press `'q'` (ignoring any other keys) before force-stopping and uninstalling the app:

```bash
dart run tools/bin/tools.dart install
dart run tools/bin/tools.dart run -w manual_check
```

#### Collect multiple runs for A/B comparisons

Because `run` uninstalls the app after each trace, re-run `install` before each iteration so every run starts from an identical first-launch state (including fresh SQLite DB creation and `SharedPreferences` initialization):

```bash
dart run tools/bin/tools.dart build \
  --flutter-bin=/path/to/flutter/bin/flutter \
  --local-engine-src-path=/path/to/flutter/engine/src

for i in 1 2 3; do
  dart run tools/bin/tools.dart install
  dart run tools/bin/tools.dart run "candidate_run${i}"
done
```

#### Switching between Vulkan and OpenGL ES backends

In profile builds, the Impeller rendering backend is configured in `android/app/src/main/AndroidManifest.xml`:

* **Vulkan**:
  ```xml
  <meta-data
      android:name="io.flutter.embedding.android.ImpellerBackend"
      android:value="vulkan" />
  <meta-data
      android:name="io.flutter.embedding.android.EnableVulkanGPUTracing"
      android:value="true" />
  ```
* **OpenGL ES**:
  ```xml
  <meta-data
      android:name="io.flutter.embedding.android.ImpellerBackend"
      android:value="opengles" />
  <meta-data
      android:name="io.flutter.embedding.android.EnableOpenGLGPUTracing"
      android:value="true" />
  ```

Re-run `dart run tools/bin/tools.dart build` after changing `AndroidManifest.xml`.
