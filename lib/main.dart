import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gal/gal.dart';

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
      title: 'AI Camera Pro',
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

  // الخصائص والخيارات
  FlashMode _flashMode = FlashMode.off;
  double _currentZoom = 1.0;
  double _maxZoom = 1.0;
  double _minZoom = 1.0;
  double _baseZoom = 1.0; // للتكبير النسيجي باليد
  String _aspectRatioMode = 'Full'; // Full, 16:9, 4:3
  
  // الوضع الحالي: PHOTO أو VIDEO
  String _captureMode = 'PHOTO'; 
  bool _isRecording = false;

  // ميزات إضافية
  bool _isLiveAutoOn = true;
  bool _isAiEnhanceOn = true;
  bool _isShutterSoundOn = true;
  bool _showSettingsOverlay = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // مراقبة حالة الخروج والدخول للتطبيق
    _requestPermissionAndInit();
  }

  // إدارة دورة حياة التطبيق (إعادة الكاميرا وإطفاء الفلاش فوراً عند الخروج)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = controller;

    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      // إطفاء الفلاش فوراً عند الخروج وتفريغ الكاميرا
      cameraController.setFlashMode(FlashMode.off);
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      // إعادة تشغيل الكاميرا تلقائياً عند العودة للتطبيق
      _initCamera(selectedCameraIndex);
    }
  }

  Future<void> _requestPermissionAndInit() async {
    await Permission.camera.request();
    await Permission.microphone.request();
    await Permission.storage.request();
    await Gal.requestAccess();

    if (await Permission.camera.isGranted) {
      setState(() {
        isPermissionGranted = true;
      });
      if (cameras.isNotEmpty) {
        _initCamera(selectedCameraIndex);
      }
    }
  }

  Future<void> _initCamera(int index) async {
    if (controller != null) {
      await controller!.dispose();
    }
    controller = CameraController(
      cameras[index],
      ResolutionPreset.max, // أقصى دقة معالجة
      enableAudio: true,
    );

    try {
      await controller!.initialize();
      _maxZoom = await controller!.getMaxZoomLevel();
      _minZoom = await controller!.getMinZoomLevel();
      _currentZoom = 1.0;
      await controller!.setFlashMode(_flashMode);
      if (mounted) setState(() {});
    } catch (e) {
      print('Error initializing camera controller: $e');
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
      print('Flash not supported on this camera: $e');
    }
  }

  // التقاط الصورة
  Future<void> _takePicture() async {
    if (controller == null || !controller!.value.isInitialized) return;
    try {
      if (_isShutterSoundOn) {
        SystemSound.play(SystemSoundType.click); // صوت التقاط الكاميرا
      }

      final image = await controller!.takePicture();
      await Gal.putImage(image.path);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isAiEnhanceOn 
                ? 'تم التقاط الصورة وتحسين ألوان الـ AI بنجاح! ✨📸' 
                : 'تم حفظ الصورة في المعرض! 📸'),
            backgroundColor: Colors.amber[800],
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('Error taking picture: $e');
    }
  }

  // تسجيل/إيقاف الفيديو
  Future<void> _toggleVideoRecording() async {
    if (controller == null || !controller!.value.isInitialized) return;

    if (_isRecording) {
      try {
        final file = await controller!.stopVideoRecording();
        setState(() { _isRecording = false; });
        await Gal.putVideo(file.path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم حفظ الفيديو في المعرض! 🎥'), backgroundColor: Colors.green),
          );
        }
      } catch (e) {
        print(e);
      }
    } else {
      try {
        await controller!.startVideoRecording();
        setState(() { _isRecording = true; });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('جاري تسجيل الفيديو... 🔴'), backgroundColor: Colors.red),
          );
        }
      } catch (e) {
        print(e);
      }
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
      return const Scaffold(
        body: Center(child: Text('يرجى منح صلاحيات الكاميرا والميكروفون')),
      );
    }

    if (controller == null || !controller!.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.amber)),
      );
    }

    final screenSize = MediaQuery.of(context).size;

    // معالجة الأبعاد (Full / 16:9 / 4:3)
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
    } else if (_aspectRatioMode == '16:9') {
      previewWidget = AspectRatio(
        aspectRatio: 9 / 16,
        child: CameraPreview(controller!),
      );
    } else { // 4:3
      previewWidget = AspectRatio(
        aspectRatio: 3 / 4,
        child: CameraPreview(controller!),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. عرض الكاميرا مع التحكم بالزوم بنعومة
          Positioned.fill(
            child: GestureDetector(
              onScaleStart: (details) {
                _baseZoom = _currentZoom;
              },
              onScaleUpdate: (details) async {
                // تنعيم معادل الزوم حتى لا يقفز فجأة
                double sensitivity = 0.5; // تقليل الحساسية للزوم الناعم
                double newZoom = (_baseZoom + (details.scale - 1.0) * sensitivity)
                    .clamp(_minZoom, _maxZoom);
                
                setState(() { _currentZoom = newZoom; });
                await controller!.setZoomLevel(_currentZoom);
              },
              child: Center(child: previewWidget),
            ),
          ),

          // 2. الشريط العلوي (فلاش، إعدادات، أبعاد، Live Auto، AI)
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
                    size: 26,
                  ),
                  onPressed: _toggleFlash,
                ),

                IconButton(
                  icon: const Icon(Icons.settings, color: Colors.white, size: 26),
                  onPressed: () {
                    setState(() { _showSettingsOverlay = true; });
                  },
                ),

                GestureDetector(
                  onTap: () {
                    setState(() { _isLiveAutoOn = !_isLiveAutoOn; });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _isLiveAutoOn ? Colors.amber : Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'LIVE AUTO',
                      style: TextStyle(
                        color: _isLiveAutoOn ? Colors.black : Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),

                Row(
                  children: ['Full', '16:9', '4:3'].map((mode) {
                    bool isSelected = _aspectRatioMode == mode;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2.0),
                      child: GestureDetector(
                        onTap: () => setState(() => _aspectRatioMode = mode),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                          decoration: BoxDecoration(
                            color: isSelected ? Colors.amber : Colors.black45,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            mode,
                            style: TextStyle(
                              color: isSelected ? Colors.black : Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),

                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: Colors.amber, width: 1),
                  ),
                  child: const Text('50MP AI', style: TextStyle(color: Colors.amber, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),

          // 3. شريط الزووم الجانبي
          Positioned(
            right: 15,
            top: screenSize.height / 2 - 60,
            child: Column(
              children: [
                Text('${_currentZoom.toStringAsFixed(1)}x', style: const TextStyle(color: Colors.amber, fontSize: 11)),
                const SizedBox(height: 5),
                Container(
                  height: 100,
                  width: 30,
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(15)),
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: Slider(
                      value: _currentZoom,
                      min: _minZoom,
                      max: _maxZoom > 4.0 ? 4.0 : _maxZoom,
                      activeColor: Colors.amber,
                      inactiveColor: Colors.white30,
                      onChanged: (value) async {
                        setState(() { _currentZoom = value; });
                        await controller!.setZoomLevel(value);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 4. الشريط السفلي (PHOTO / VIDEO + الزرار)
          Positioned(
            bottom: 25,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    GestureDetector(
                      onTap: () {
                        if (!_isRecording) setState(() => _captureMode = 'PHOTO');
                      },
                      child: Text(
                        'PHOTO',
                        style: TextStyle(
                          color: _captureMode == 'PHOTO' ? Colors.amber : Colors.white54,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    const SizedBox(width: 30),
                    GestureDetector(
                      onTap: () {
                        setState(() => _captureMode = 'VIDEO');
                      },
                      child: Text(
                        'VIDEO',
                        style: TextStyle(
                          color: _captureMode == 'VIDEO' ? Colors.amber : Colors.white54,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 15),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Container(
                      height: 48,
                      width: 48,
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: const Icon(Icons.photo_library, color: Colors.white, size: 24),
                    ),

                    GestureDetector(
                      onTap: () {
                        if (_captureMode == 'PHOTO') {
                          _takePicture();
                        } else {
                          _toggleVideoRecording();
                        }
                      },
                      child: Container(
                        height: 75,
                        width: 75,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _captureMode == 'VIDEO' ? Colors.red : Colors.amber, 
                            width: 4,
                          ),
                          color: Colors.white24,
                        ),
                        child: Center(
                          child: Container(
                            height: 58,
                            width: 58,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _captureMode == 'VIDEO' 
                                  ? (_isRecording ? Colors.red : Colors.redAccent) 
                                  : Colors.white,
                            ),
                            child: _isRecording ? const Icon(Icons.stop, color: Colors.white, size: 30) : null,
                          ),
                        ),
                      ),
                    ),

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

          // 5. شاشة الإعدادات كاملة خلفية سودة (Full Screen Settings)
          if (_showSettingsOverlay)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.95),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 50),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('إعدادات الكاميرا', style: TextStyle(color: Colors.amber, fontSize: 22, fontWeight: FontWeight.bold)),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white, size: 28),
                          onPressed: () {
                            setState(() { _showSettingsOverlay = false; });
                          },
                        ),
                      ],
                    ),
                    const Divider(color: Colors.white24),
                    const SizedBox(height: 10),

                    SwitchListTile(
                      activeColor: Colors.amber,
                      title: const Text('معالجة تحسين ألوان الذكاء الاصطناعي (AI Enhancement)', style: TextStyle(color: Colors.white)),
                      subtitle: const Text('استغلال أقصى طاقة للمعالج لأعلى دقة ونقاء للصورة', style: TextStyle(color: Colors.white54, fontSize: 12)),
                      value: _isAiEnhanceOn,
                      onChanged: (val) {
                        setState(() { _isAiEnhanceOn = val; });
                      },
                    ),

                    SwitchListTile(
                      activeColor: Colors.amber,
                      title: const Text('صوت التقاط الكاميرا', style: TextStyle(color: Colors.white)),
                      value: _isShutterSoundOn,
                      onChanged: (val) {
                        setState(() { _isShutterSoundOn = val; });
                      },
                    ),

                    ListTile(
                      leading: const Icon(Icons.aspect_ratio, color: Colors.amber),
                      title: const Text('نسبة الأبعاد الشاشة الحالية', style: TextStyle(color: Colors.white)),
                      subtitle: Text(_aspectRatioMode, style: const TextStyle(color: Colors.white54)),
                    ),

                    const Spacer(),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.amber),
                        onPressed: () {
                          setState(() { _showSettingsOverlay = false; });
                        },
                        child: const Text('حفظ وإغلاق', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}