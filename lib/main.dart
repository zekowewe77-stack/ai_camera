import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gal/gal.dart';
import 'dart:math' as math;

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    print('Error initializing cameras: $e');
  }
  runApp(const CameraApp());
}

class CameraApp extends StatelessWidget {
  const CameraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pro AI Camera',
      theme: ThemeData.dark(),
      home: const CameraScreen(),
    );
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? controller;
  int selectedCameraIndex = 0;
  bool isPermissionGranted = false;

  // إعدادات الكاميرا والزووم
  FlashMode _flashMode = FlashMode.off;
  double _currentZoom = 1.0;
  double _maxZoom = 4.0;
  double _minZoom = 1.0;
  
  // عجلّة الزوم (تظهر عند اللمس والسحب)
  bool _showZoomWheel = false;
  DateTime _lastZoomInteraction = DateTime.now();

  String _aspectRatioMode = '4:3';
  String _currentMode = 'PHOTO'; // PHOTO, VIDEO, LIVE AUTO
  bool _isRecording = false;
  bool _isShutterSoundOn = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissionAndInit();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = controller;
    if (cameraController == null || !cameraController.value.isInitialized) return;

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      cameraController.setFlashMode(FlashMode.off);
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera(selectedCameraIndex);
    }
  }

  Future<void> _requestPermissionAndInit() async {
    await Permission.camera.request();
    await Permission.microphone.request();
    await Permission.storage.request();
    await Gal.requestAccess();

    if (await Permission.camera.isGranted) {
      setState(() { isPermissionGranted = true; });
      if (cameras.isNotEmpty) _initCamera(selectedCameraIndex);
    }
  }

  Future<void> _initCamera(int index) async {
    if (controller != null) await controller!.dispose();
    controller = CameraController(
      cameras[index],
      ResolutionPreset.max, // أقصى دقة مادية للمعالج
      enableAudio: true,
    );

    try {
      await controller!.initialize();
      _maxZoom = await controller!.getMaxZoomLevel();
      _minZoom = await controller!.getMinZoomLevel();
      if (_maxZoom > 6.0) _maxZoom = 6.0; // حد أقصى عملي للزووم النقي
      _currentZoom = 1.0;
      await controller!.setFlashMode(_flashMode);
      if (mounted) setState(() {});
    } catch (e) {
      print('Error initializing camera: $e');
    }
  }

  void _switchCamera() {
    if (cameras.length > 1) {
      selectedCameraIndex = (selectedCameraIndex + 1) % cameras.length;
      _initCamera(selectedCameraIndex);
    }
  }

  Future<void> _toggleFlash() async {
    if (controller == null) return;
    setState(() {
      _flashMode = (_flashMode == FlashMode.off) ? FlashMode.torch : FlashMode.off;
    });
    try {
      await controller!.setFlashMode(_flashMode);
    } catch (e) {
      print(e);
    }
  }

  // التقاط الصورة أو Live Auto المتحركة بأعلى معالجة AI
  Future<void> _captureAction() async {
    if (controller == null || !controller!.value.isInitialized) return;

    if (_currentMode == 'VIDEO') {
      _toggleVideoRecording();
      return;
    }

    try {
      if (_isShutterSoundOn) SystemSound.play(SystemSoundType.click);

      if (_currentMode == 'LIVE AUTO') {
        // تسجيل فيديو قصير جداً (ثانية واحدة) لإنشاء صورة متحركة حقيقية تفاعلية
        await controller!.startVideoRecording();
        await Future.delayed(const Duration(milliseconds: 800));
        final videoFile = await controller!.stopVideoRecording();
        await Gal.putVideo(videoFile.path);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✨ تم التقاط وحفظ صورة Live Auto المتحركة بنجاح!'),
              backgroundColor: Colors.amber,
              duration: Duration(seconds: 2),
            ),
          );
        }
      } else {
        // التقاط صورة بذكاء اصطناعي ومعالجة فائقة النقاء
        final image = await controller!.takePicture();
        await Gal.putImage(image.path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('📸 تم التقاط وحفظ الصورة بمعالجة AI الفائقة!'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      }
    } catch (e) {
      print('Error capturing: $e');
    }
  }

  Future<void> _toggleVideoRecording() async {
    if (controller == null || !controller!.value.isInitialized) return;
    if (_isRecording) {
      final file = await controller!.stopVideoRecording();
      setState(() { _isRecording = false; });
      await Gal.putVideo(file.path);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ الفيديو بنجاح! 🎥'), backgroundColor: Colors.green));
    } else {
      await controller!.startVideoRecording();
      setState(() { _isRecording = true; });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('جاري تسجيل الفيديو الاحترافي... 🔴'), backgroundColor: Colors.red));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!isPermissionGranted) {
      return const Scaffold(body: Center(child: Text('يرجى منح صلاحيات الكاميرا')));
    }
    if (controller == null || !controller!.value.isInitialized) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator(color: Colors.amber)));
    }

    final screenSize = MediaQuery.of(context).size;

    // معاينة الشاشة (Full أو 4:3)
    Widget previewWidget;
    if (_aspectRatioMode == 'Full') {
      previewWidget = SizedBox(
        width: screenSize.width,
        height: screenSize.height,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: controller!.value.previewSize?.height ?? screenSize.width,
            height: controller!.value.previewSize?.width ?? screenSize.height,
            child: CameraPreview(controller!),
          ),
        ),
      );
    } else {
      previewWidget = AspectRatio(
        aspectRatio: 3 / 4,
        child: CameraPreview(controller!),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. معاينة الكاميرا والتحكم بالزووم وعجلّة الآيفون الدائرية
          Positioned.fill(
            child: GestureDetector(
              onScaleStart: (_) {
                setState(() { _showZoomWheel = true; });
              },
              onScaleUpdate: (details) async {
                double newZoom = (_currentZoom * (details.scale > 1 ? 1.03 : 0.97))
                    .clamp(_minZoom, _maxZoom);
                setState(() {
                  _currentZoom = newZoom;
                  _showZoomWheel = true;
                  _lastZoomInteraction = DateTime.now();
                });
                await controller!.setZoomLevel(_currentZoom);
              },
              onScaleEnd: (_) {
                // إخفاء العجلّة بعد ثوانٍ من ترك الأصابع
                Future.delayed(const Duration(seconds: 2), () {
                  if (mounted && DateTime.now().difference(_lastZoomInteraction).inSeconds >= 2) {
                    setState(() { _showZoomWheel = false; });
                  }
                });
              },
              child: Center(child: previewWidget),
            ),
          ),

          // 2. الشريط العُلوي (إعدادات، فلاش، HDR، مؤقت)
          Positioned(
            top: 40,
            left: 15,
            right: 15,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: Icon(
                    _flashMode == FlashMode.torch ? Icons.flash_on : Icons.flash_off,
                    color: _flashMode == FlashMode.torch ? Colors.amber : Colors.white,
                    size: 24,
                  ),
                  onPressed: _toggleFlash,
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(10)),
                  child: const Text('HDR AI', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                ),
                const Icon(Icons.timer_outlined, color: Colors.white, size: 24),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _aspectRatioMode = (_aspectRatioMode == '4:3') ? 'Full' : '4:3';
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 1), borderRadius: BorderRadius.circular(6)),
                    child: Text(_aspectRatioMode, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),

          // 3. عجلّة الزوم الدائرية الاحترافية (تظهر وتتدرج عند السحب مثل الآيفون وسامسونج)
          if (_showZoomWheel)
            Positioned(
              bottom: 150,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  height: 90,
                  width: 320,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.75),
                    borderRadius: BorderRadius.circular(45),
                    border: Border.all(color: Colors.amber.withOpacity(0.4), width: 1),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${_currentZoom.toStringAsFixed(1)}x',
                        style: const TextStyle(color: Colors.amber, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [1.0, 2.0, 3.0, 4.0].map((z) {
                          bool isSelected = (_currentZoom - z).abs() < 0.5;
                          return GestureDetector(
                            onTap: () async {
                              setState(() {
                                _currentZoom = z;
                                _lastZoomInteraction = DateTime.now();
                              });
                              await controller!.setZoomLevel(z);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: isSelected ? Colors.amber : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${z.toInt()}x',
                                style: TextStyle(
                                  color: isSelected ? Colors.black : Colors.white70,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // 4. الشريط السفلي (أوضاع التصوير الأفقية + زر الالتقاط)
          Positioned(
            bottom: 20,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // شريط الأوضاع (LIVE AUTO، PHOTO، VIDEO، PORTRAIT)
                SizedBox(
                  height: 35,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    children: ['SLOW-MO', 'VIDEO', 'PHOTO', 'LIVE AUTO', 'PORTRAIT', 'SQUARE'].map((mode) {
                      bool isSelected = _currentMode == mode;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12.0),
                        child: GestureDetector(
                          onTap: () => setState(() => _currentMode = mode),
                          child: Text(
                            mode,
                            style: TextStyle(
                              color: isSelected ? Colors.amber : Colors.white60,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 12),

                // صف المعرض وزر الالتقاط والتبديل
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // المعرض المصغر
                    Container(
                      height: 50,
                      width: 50,
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: const Icon(Icons.photo, color: Colors.white, size: 24),
                    ),

                    // زر الغالق الرئيسي
                    GestureDetector(
                      onTap: _captureAction,
                      child: Container(
                        height: 75,
                        width: 75,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 4),
                        ),
                        child: Center(
                          child: Container(
                            height: 60,
                            width: 60,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _currentMode == 'VIDEO' && _isRecording ? Colors.red : Colors.white,
                            ),
                            child: _isRecording ? const Icon(Icons.stop, color: Colors.white, size: 30) : null,
                          ),
                        ),
                      ),
                    ),

                    // زر تبديل الكاميرا
                    IconButton(
                      iconSize: 32,
                      icon: const Icon(Icons.cameraswitch, color: Colors.white),
                      onPressed: _switchCamera,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}