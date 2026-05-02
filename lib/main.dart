
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NezhaDriveApp());
}

class NezhaDriveApp extends StatelessWidget {
  const NezhaDriveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '導航管家 Pro V9',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF07111F),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF8A00),
          brightness: Brightness.dark,
        ),
      ),
      home: const NezhaDeviceHomePage(),
    );
  }
}

enum NezhaMood { normal, happy, thinking, warning, tired }

class NezhaDeviceHomePage extends StatefulWidget {
  const NezhaDeviceHomePage({super.key});

  @override
  State<NezhaDeviceHomePage> createState() => _NezhaDeviceHomePageState();
}

class _NezhaDeviceHomePageState extends State<NezhaDeviceHomePage>
    with TickerProviderStateMixin {
  late AnimationController floatController;

  final FlutterTts tts = FlutterTts();
  final stt.SpeechToText speech = stt.SpeechToText();

  StreamSubscription<Position>? gpsSub;
  StreamSubscription<AccelerometerEvent>? accelSub;

  CameraController? cameraController;
  List<CameraDescription> cameras = [];

  int pageIndex = 0;
  bool recording = false;
  bool tripStarted = false;
  bool speechReady = false;
  bool listening = false;

  Position? currentPosition;
  double currentSpeedKmh = 0;
  double lastShockValue = 0;

  NezhaMood mood = NezhaMood.normal;

  final List<Map<String, String>> messages = [
    {"role": "ai", "text": "真機功能版已啟動，我可以定位、錄影、語音提醒與監測急煞。"},
  ];

  final TextEditingController aiController = TextEditingController();

  @override
  void initState() {
    super.initState();
    floatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    initDeviceFeatures();
  }

  Future<void> initDeviceFeatures() async {
    await requestPermissions();
    await initTts();
    await initSpeech();
    await initCamera();
    await startGps();
    startSensorMonitor();
    speak("哪吒安全駕駛管家已啟動。");
  }

  Future<void> requestPermissions() async {
    await [
      Permission.location,
      Permission.camera,
      Permission.microphone,
      Permission.storage,
    ].request();
  }

  Future<void> initTts() async {
    await tts.setLanguage("zh-TW");
    await tts.setSpeechRate(0.48);
    await tts.setPitch(1.12);
    await tts.setVolume(1.0);
  }

  Future<void> speak(String text) async {
    await tts.stop();
    await tts.speak(text);
  }

  Future<void> initSpeech() async {
    speechReady = await speech.initialize(
      onStatus: (status) {
        if (status == "done" || status == "notListening") {
          if (mounted) setState(() => listening = false);
        }
      },
      onError: (error) {
        if (mounted) {
          setState(() {
            listening = false;
            messages.add({"role": "ai", "text": "語音辨識暫時失敗，請改用打字輸入。"});
          });
        }
      },
    );
    if (mounted) setState(() {});
  }

  Future<void> initCamera() async {
    try {
      cameras = await availableCameras();
      if (cameras.isEmpty) return;
      cameraController = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: true,
      );
      await cameraController!.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      messages.add({"role": "ai", "text": "相機初始化失敗，請確認權限。"});
    }
  }

  Future<void> startGps() async {
    bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      setState(() {
        messages.add({"role": "ai", "text": "GPS尚未開啟，請先開啟定位服務。"});
      });
      speak("GPS尚未開啟，請先開啟定位服務。");
      return;
    }

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever ||
        perm == LocationPermission.denied) {
      setState(() {
        messages.add({"role": "ai", "text": "定位權限未開啟，無法啟動真GPS功能。"});
      });
      return;
    }

    gpsSub?.cancel();
    gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3,
      ),
    ).listen((pos) {
      setState(() {
        currentPosition = pos;
        currentSpeedKmh = math.max(0, pos.speed * 3.6);
      });

      if (tripStarted && currentSpeedKmh > 0) {
        maybeDrivingHint();
      }
    });
  }

  DateTime lastDrivingHint = DateTime.fromMillisecondsSinceEpoch(0);
  void maybeDrivingHint() {
    final now = DateTime.now();
    if (now.difference(lastDrivingHint).inSeconds < 25) return;
    lastDrivingHint = now;

    if (currentSpeedKmh > 75) {
      setState(() {
        mood = NezhaMood.warning;
        messages.add({"role": "ai", "text": "哪吒提醒：目前速度偏快，請注意安全。"});
      });
      speak("哪吒提醒，目前速度偏快，請注意安全。");
    }
  }

  void startSensorMonitor() {
    accelSub?.cancel();
    accelSub = accelerometerEventStream().listen((event) {
      final force = math.sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );
      final delta = (force - lastShockValue).abs();
      lastShockValue = force;

      if (tripStarted && delta > 18) {
        onShockDetected(delta);
      }
    });
  }

  DateTime lastShockTime = DateTime.fromMillisecondsSinceEpoch(0);
  void onShockDetected(double delta) {
    final now = DateTime.now();
    if (now.difference(lastShockTime).inSeconds < 8) return;
    lastShockTime = now;

    setState(() {
      mood = NezhaMood.warning;
      messages.add({
        "role": "ai",
        "text": "偵測到急煞或強烈震動，我已標記此時間點，建議保留影片。"
      });
    });
    speak("偵測到急煞或強烈震動，我已標記此時間點，建議保留影片。");
  }

  Future<void> startRecording() async {
    if (cameraController == null || !cameraController!.value.isInitialized) {
      await initCamera();
    }
    if (cameraController == null || !cameraController!.value.isInitialized) {
      speak("相機尚未準備好。");
      return;
    }

    if (cameraController!.value.isRecordingVideo) return;

    try {
      await cameraController!.startVideoRecording();
      setState(() {
        recording = true;
        messages.add({"role": "ai", "text": "行車紀錄已開始錄影。"});
      });
      speak("行車紀錄已開始錄影。");
    } catch (e) {
      setState(() {
        messages.add({"role": "ai", "text": "錄影啟動失敗，請確認相機與麥克風權限。"});
      });
    }
  }

  Future<void> stopRecording({bool locked = false}) async {
    if (cameraController == null ||
        !cameraController!.value.isRecordingVideo) return;

    try {
      final XFile file = await cameraController!.stopVideoRecording();
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory(p.join(dir.path, locked ? "locked_videos" : "videos"));
      if (!await folder.exists()) await folder.create(recursive: true);

      final newPath = p.join(
        folder.path,
        "${locked ? "LOCKED" : "REC"}_${DateTime.now().millisecondsSinceEpoch}.mp4",
      );
      await File(file.path).copy(newPath);

      setState(() {
        recording = false;
        messages.add({
          "role": "ai",
          "text": locked ? "重要影片已鎖定保存。" : "錄影已停止並儲存。"
        });
      });
      speak(locked ? "重要影片已鎖定保存。" : "錄影已停止並儲存。");
    } catch (e) {
      setState(() {
        recording = false;
        messages.add({"role": "ai", "text": "錄影停止時發生錯誤。"});
      });
    }
  }

  Future<void> startTrip() async {
    setState(() {
      tripStarted = true;
      mood = NezhaMood.happy;
      messages.add({"role": "ai", "text": "行程開始，我會同步定位、錄影與安全監控。"});
    });
    speak("行程開始，我會同步定位、錄影與安全監控。");
    await startGps();
    await startRecording();
  }

  Future<void> stopTrip() async {
    setState(() {
      tripStarted = false;
      mood = NezhaMood.normal;
      messages.add({"role": "ai", "text": "行程已結束。"});
    });
    await stopRecording();
    speak("行程已結束。");
  }

  void toggleListening() async {
    if (!speechReady) {
      await initSpeech();
    }
    if (!speechReady) {
      speak("語音辨識尚未準備好。");
      return;
    }

    if (listening) {
      await speech.stop();
      setState(() => listening = false);
      return;
    }

    setState(() => listening = true);
    await speech.listen(
      localeId: "zh_TW",
      onResult: (result) {
        if (result.finalResult) {
          aiController.text = result.recognizedWords;
          askAi();
        }
      },
    );
  }

  void askAi() {
    final text = aiController.text.trim();
    if (text.isEmpty) return;
    setState(() {
      messages.add({"role": "user", "text": text});
      mood = NezhaMood.thinking;
    });
    aiController.clear();

    Future.delayed(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      String answer;
      if (text.contains("定位") || text.contains("在哪")) {
        if (currentPosition == null) {
          answer = "目前還沒有取得GPS定位，請確認定位權限與GPS開關。";
        } else {
          answer =
              "目前定位已取得，速度約 ${currentSpeedKmh.toStringAsFixed(0)} 公里。";
        }
      } else if (text.contains("錄影")) {
        answer = recording ? "目前正在錄影，我會保留重要片段。" : "目前尚未錄影，你可以按一鍵錄影。";
      } else if (text.contains("停車")) {
        answer = "建議先找目的地附近 100 到 300 公尺的停車點，不要硬停門口。";
      } else if (text.contains("入口")) {
        answer = "建議把實際入口記錄下來，下次會優先提醒入口。";
      } else if (text.contains("累") || text.contains("疲勞")) {
        answer = "如果已連續開車很久，建議找安全地點休息一下。";
      } else {
        answer = "我會幫你注意定位、錄影、急煞、入口與停車安全。";
      }

      setState(() {
        mood = NezhaMood.normal;
        messages.add({"role": "ai", "text": answer});
      });
      speak(answer);
    });
  }

  @override
  void dispose() {
    gpsSub?.cancel();
    accelSub?.cancel();
    cameraController?.dispose();
    tts.stop();
    floatController.dispose();
    aiController.dispose();
    super.dispose();
  }

  String get moodFace {
    switch (mood) {
      case NezhaMood.normal:
        return "😊";
      case NezhaMood.happy:
        return "😄";
      case NezhaMood.thinking:
        return "🤔";
      case NezhaMood.warning:
        return "😠";
      case NezhaMood.tired:
        return "😴";
    }
  }

  String get moodText {
    switch (mood) {
      case NezhaMood.normal:
        return "前方狀況正常，我幫你看著。";
      case NezhaMood.happy:
        return "行程啟動，我正在監控安全狀態。";
      case NezhaMood.thinking:
        return "我正在分析你的問題。";
      case NezhaMood.warning:
        return "注意！剛剛有急煞或風險訊號。";
      case NezhaMood.tired:
        return "你開太久了，建議休息。";
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      buildHome(),
      buildAi(),
      buildRecorder(),
      buildGps(),
      buildSafety(),
    ];
    return Scaffold(
      body: SafeArea(child: pages[pageIndex]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: pageIndex,
        backgroundColor: const Color(0xEE07111F),
        onDestinationSelected: (i) => setState(() => pageIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: "首頁"),
          NavigationDestination(icon: Icon(Icons.smart_toy), label: "AI"),
          NavigationDestination(icon: Icon(Icons.videocam), label: "錄影"),
          NavigationDestination(icon: Icon(Icons.gps_fixed), label: "定位"),
          NavigationDestination(icon: Icon(Icons.shield), label: "安全"),
        ],
      ),
    );
  }

  Widget shell({required Widget child}) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(-0.9, -1.0),
          radius: 1.3,
          colors: [Color(0xFF174166), Color(0xFF07111F), Color(0xFF030812)],
        ),
      ),
      child: child,
    );
  }

  Widget buildHome() {
    return shell(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          buildHeader(),
          const SizedBox(height: 12),
          buildNezhaHero(),
          const SizedBox(height: 14),
          glassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("真機安全駕駛管家",
                    style:
                        TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                const SizedBox(height: 6),
                Text(moodText, style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                        child: primaryButton(
                            tripStarted ? "結束行程" : "開始行程",
                            tripStarted ? stopTrip : startTrip)),
                    const SizedBox(width: 10),
                    Expanded(
                        child: secondaryButton(
                            recording ? "停止錄影" : "一鍵錄影",
                            recording ? stopRecording : startRecording)),
                  ],
                )
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                  child: statCard("GPS",
                      currentPosition == null ? "等待定位" : "已定位",
                      currentPosition == null
                          ? Colors.white70
                          : Colors.greenAccent)),
              const SizedBox(width: 10),
              Expanded(
                  child: statCard(
                      "速度",
                      "${currentSpeedKmh.toStringAsFixed(0)} km/h",
                      currentSpeedKmh > 75 ? Colors.orange : Colors.white70)),
            ],
          ),
        ],
      ),
    );
  }

  Widget buildHeader() {
    return Row(
      children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [Color(0xFFFF9F1C), Color(0xFFFF4D6D)]),
            borderRadius: BorderRadius.circular(18),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x55FF9F1C),
                  blurRadius: 24,
                  offset: Offset(0, 8))
            ],
          ),
          child: const Center(child: Text("🔥", style: TextStyle(fontSize: 28))),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("導航管家 Pro V9.1",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
              Text("哪吒AI安全駕駛管家｜真機功能版",
                  style: TextStyle(color: Colors.white60, fontSize: 13)),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.greenAccent.withOpacity(.12),
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: Colors.greenAccent.withOpacity(.35)),
          ),
          child: const Text("BOSS", style: TextStyle(color: Colors.greenAccent)),
        )
      ],
    );
  }

  Widget buildNezhaHero() {
    return AnimatedBuilder(
      animation: floatController,
      builder: (context, _) {
        final y = math.sin(floatController.value * math.pi) * 10;
        return Container(
          height: 260,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: const LinearGradient(
              colors: [Color(0x332DD4FF), Color(0x33FF9F1C), Color(0x227A5CFF)],
            ),
            border: Border.all(color: Colors.white.withOpacity(.13)),
          ),
          child: Stack(
            children: [
              Positioned.fill(child: CustomPaint(painter: GameGridPainter())),
              Positioned(
                left: 38,
                right: 38,
                top: 130,
                child: Container(
                  height: 9,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [
                      Color(0xFFFFE066),
                      Color(0xFFFF9F1C),
                      Color(0xFF00D4FF)
                    ]),
                    borderRadius: BorderRadius.circular(99),
                    boxShadow: const [
                      BoxShadow(color: Color(0x99FFE066), blurRadius: 18)
                    ],
                  ),
                ),
              ),
              const Positioned(
                  left: 55,
                  top: 150,
                  child: Text("🏠", style: TextStyle(fontSize: 30))),
              const Positioned(
                  right: 62,
                  top: 68,
                  child: Text("🚨", style: TextStyle(fontSize: 34))),
              const Positioned(
                  right: 95,
                  bottom: 45,
                  child: Text("📸", style: TextStyle(fontSize: 30))),
              Positioned(
                left: 98,
                top: 76 + y,
                child: Text("👦🏻🔥 $moodFace",
                    style: const TextStyle(
                      fontSize: 76,
                      shadows: [
                        Shadow(color: Color(0xFFFF9F1C), blurRadius: 20)
                      ],
                    )),
              ),
              Positioned(
                right: 18,
                top: 18,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: recording
                        ? Colors.redAccent.withOpacity(.25)
                        : Colors.white.withOpacity(.08),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(recording ? "🔴 REC" : "REC OFF"),
                ),
              )
            ],
          ),
        );
      },
    );
  }

  Widget buildAi() {
    return shell(
      child: Column(
        children: [
          Padding(padding: const EdgeInsets.all(16), child: buildHeader()),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final m = messages[index];
                final isAi = m["role"] == "ai";
                return Align(
                  alignment:
                      isAi ? Alignment.centerLeft : Alignment.centerRight,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    constraints: const BoxConstraints(maxWidth: 315),
                    decoration: BoxDecoration(
                      color: isAi
                          ? Colors.orange.withOpacity(.15)
                          : Colors.blue.withOpacity(.18),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white.withOpacity(.10)),
                    ),
                    child: Text(
                      isAi ? "哪吒：${m["text"]}" : m["text"]!,
                      style: const TextStyle(height: 1.35),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            color: const Color(0xEE07111F),
            child: Row(
              children: [
                IconButton.filled(
                  onPressed: toggleListening,
                  icon: Icon(listening ? Icons.stop : Icons.mic),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: aiController,
                    decoration: InputDecoration(
                      hintText: listening
                          ? "正在聽你說話..."
                          : "問哪吒：現在定位？幫我錄影...",
                      filled: true,
                      fillColor: Colors.white.withOpacity(.08),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(18),
                          borderSide: BorderSide.none),
                    ),
                    onSubmitted: (_) => askAi(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                    onPressed: askAi, icon: const Icon(Icons.send)),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget buildRecorder() {
    return shell(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          buildHeader(),
          const SizedBox(height: 14),
          if (cameraController != null &&
              cameraController!.value.isInitialized)
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: AspectRatio(
                aspectRatio: cameraController!.value.aspectRatio,
                child: CameraPreview(cameraController!),
              ),
            )
          else
            glassCard(
              child: const Text("相機尚未準備好，請確認權限。",
                  style: TextStyle(color: Colors.white70)),
            ),
          const SizedBox(height: 14),
          glassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(recording ? "🔴 REC 錄影中" : "⚪ 行車紀錄待命",
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w900)),
                const SizedBox(height: 8),
                const Text("真機錄影已接入。預設中等畫質；影片可鎖定保存。",
                    style: TextStyle(color: Colors.white70, height: 1.4)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                        child: primaryButton(recording ? "停止錄影" : "開始錄影",
                            recording ? stopRecording : startRecording)),
                    const SizedBox(width: 10),
                    Expanded(
                        child: secondaryButton("鎖定片段", () {
                      if (recording) {
                        stopRecording(locked: true);
                      } else {
                        speak("目前沒有正在錄影的片段。");
                      }
                    })),
                  ],
                )
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildGps() {
    return shell(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          buildHeader(),
          const SizedBox(height: 14),
          glassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("GPS 真定位",
                    style:
                        TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
                const SizedBox(height: 10),
                Text(
                  currentPosition == null
                      ? "尚未取得定位"
                      : "緯度：${currentPosition!.latitude.toStringAsFixed(6)}\n經度：${currentPosition!.longitude.toStringAsFixed(6)}\n速度：${currentSpeedKmh.toStringAsFixed(1)} km/h\n精準度：${currentPosition!.accuracy.toStringAsFixed(1)} m",
                  style: const TextStyle(color: Colors.white70, height: 1.55),
                ),
                const SizedBox(height: 12),
                primaryButton("重新啟動定位", startGps),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildSafety() {
    return shell(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          buildHeader(),
          const SizedBox(height: 14),
          safetyCard("⚠️ 急煞/震動偵測",
              "目前震動值：${lastShockValue.toStringAsFixed(1)}。偵測強烈變化時會提醒並建議鎖定影片。",
              Colors.orange),
          safetyCard("📸 測速提醒", "可手動新增測速點，之後可接政府資料。", Colors.yellow),
          safetyCard("😴 疲勞提醒", "後續會依連續駕駛時間提醒休息。", Colors.lightBlueAccent),
          safetyCard("🛡️ 入口/停車安全", "抵達前提醒入口、停車點與備註。", Colors.greenAccent),
        ],
      ),
    );
  }

  Widget safetyCard(String title, String text, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: glassCard(
        child: Row(
          children: [
            Container(
                width: 6,
                height: 70,
                decoration: BoxDecoration(
                    color: color, borderRadius: BorderRadius.circular(99))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 4),
                    Text(text, style: const TextStyle(color: Colors.white70)),
                  ]),
            )
          ],
        ),
      ),
    );
  }

  Widget statCard(String title, String value, Color color) {
    return glassCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Colors.white60)),
        const SizedBox(height: 8),
        Text(value,
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.w900, color: color)),
      ]),
    );
  }

  Widget glassCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xBB13273E),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(.12)),
        boxShadow: const [
          BoxShadow(
              color: Color(0x33000000),
              blurRadius: 28,
              offset: Offset(0, 14))
        ],
      ),
      child: child,
    );
  }

  Widget primaryButton(String text, VoidCallback onTap) {
    return FilledButton(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
        backgroundColor: const Color(0xFFFF7A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w900)),
    );
  }

  Widget secondaryButton(String text, VoidCallback onTap) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
        side: BorderSide(color: Colors.white.withOpacity(.18)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: Text(text),
    );
  }
}

class GameGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(.055)
      ..strokeWidth = 1;

    for (double x = -80; x < size.width + 120; x += 42) {
      canvas.drawLine(Offset(x, size.height), Offset(x + 140, 0), gridPaint);
    }
    for (double y = 0; y < size.height + 80; y += 42) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y - 80), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
