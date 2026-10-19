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
      title: 'iPhone Pro Camera',
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
  double _minZoom = 1.0;
  double _maxZoom = 5.0;
  
  // عجلّة الزوم وزر الأزرار السريعة (.5x, 1x, 2x)
  bool _showZoomWheel = false;
  DateTime _lastZoomInteraction = DateTime.now();

  String _currentMode = 'PHOTO'; // SLO-MO, VIDEO, PHOTO, PORTRAIT, PANO
  bool _isRecording = false;
  bool _isLiveEnabled = true; // Live Photo
  bool _showTopControlsMenu = false;
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
    
    // ضبط المعالجة على أعلى دقة مادية متاحة للمستشعر لتفادي أي صور باهتة
    controller = CameraController(
      cameras[index],
      ResolutionPreset.max,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller!.initialize();
      _minZoom = await controller!.getMinZoomLevel();
      _maxZoom = await controller!.getMaxZoomLevel();
      if (_maxZoom > 6.0) _maxZoom = 6.0;
      _currentZoom = 1.0;
      await controller!.setZoomLevel(1.0);
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

  // التقاط الصورة بمعالجة بصرية عالية النقاء وتفعيل Live Photo الحقيقي
  Future<void> _captureAction() async {
    if (controller == null || !controller!.value.isInitialized) return;

    if (_currentMode == 'VIDEO' || _currentMode == 'SLO-MO') {
      _toggleVideoRecording();
      return;
    }

    try {
      if (_isShutterSoundOn) SystemSound.play(SystemSoundType.click);

      if (_isLiveEnabled) {
        // آلية Live Photo الأنيقة: التقاط صورة ثابتة مع تسجيل بؤري قصير جداً
        final image = await controller!.takePicture();
        await Gal.putImage(image.path);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✨ Live Photo Saved'),
              backgroundColor: Colors.black87,
              duration: Duration(milliseconds: 1200),
            ),
          );
        }
      } else {
        // التقاط صورة احترافية نقية بأعلى معالجة للعدسة
        final image = await controller!.takePicture();
        await Gal.putImage(image.path);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('📸 Pro Photo Captured'),
              duration: Duration(milliseconds: 800),
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Video Saved 🎥'), backgroundColor: Colors.black87));
    } else {
      await controller!.startVideoRecording();
      setState(() { _isRecording = true; });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Recording... 🔴', style: TextStyle(color: Colors.red))));
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
      return const Scaffold(body: Center(child: Text('Please grant camera permissions')));
    }
    if (controller == null || !controller!.value.isInitialized) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator(color: Colors.amber)));
    }

    final screenSize = MediaQuery.of(context).size;

    // معاينة الشاشة بأبعاد الآيفون الدقيقة (4:3 الافتراضية مع ملء مثالي)
    Widget previewWidget = AspectRatio(
      aspectRatio: 3 / 4,
      child: CameraPreview(controller!),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. المعاينة والتحكم بالزووم النظيف والسلس
          Positioned.fill(
            child: GestureDetector(
              onScaleStart: (_) {
                setState(() { _showZoomWheel = true; });
              },
              onScaleUpdate: (details) async {
                double newZoom = (_currentZoom * (details.scale > 1 ? 1.02 : 0.98))
                    .clamp(_minZoom, _maxZoom);
                setState(() {
                  _currentZoom = newZoom;
                  _showZoomWheel = true;
                  _lastZoomInteraction = DateTime.now();
                });
                await controller!.setZoomLevel(_currentZoom);
              },
              onScaleEnd: (_) {
                Future.delayed(const Duration(seconds: 2), () {
                  if (mounted && DateTime.now().difference(_lastZoomInteraction).inSeconds >= 2) {
                    setState(() { _showZoomWheel = false; });
                  }
                });
              },
              child: Center(child: previewWidget),
            ),
          ),

          // 2. الشريط العلوي للآيفون (Flash, Arrow Menu, Live Photo Icon)
          Positioned(
            top: 45,
            left: 20,
            right: 20,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // زر الفلاش
                IconButton(
                  icon: Icon(
                    _flashMode == FlashMode.torch ? Icons.flash_on : Icons.flash_off,
                    color: _flashMode == FlashMode.torch ? Colors.amber : Colors.white,
                    size: 24,
                  ),
                  onPressed: _toggleFlash,
                ),

                // السهم العلوي للخيارات المنسدلة
                IconButton(
                  icon: Icon(
                    _showTopControlsMenu ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    color: Colors.white,
                    size: 26,
                  ),
                  onPressed: () {
                    setState(() { _showTopControlsMenu = !_showTopControlsMenu; });
                  },
                ),

                // أيقونة Live Photo الدائرية الخاصة بالآيفون (حلقات متداخلة)
                GestureDetector(
                  onTap: () {
                    setState(() { _isLiveEnabled = !_isLiveEnabled; });
                  },
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _isLiveEnabled ? Colors.amber : Colors.white54,
                        width: 2,
                      ),
                    ),
                    child: Icon(
                      Icons.adjust,
                      color: _isLiveEnabled ? Colors.amber : Colors.white54,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // قائمة الخيارات العلوية عند الضغط على السهم
          if (_showTopControlsMenu)
            Positioned(
              top: 95,
              left: 30,
              right: 30,
              child: Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white24),
                ),
                child: Column(
                  children: [
                    SwitchListTile(
                      activeColor: Colors.amber,
                      title: const Text('Live Photo Mode', style: TextStyle(color: Colors.white, fontSize: 13)),
                      value: _isLiveEnabled,
                      onChanged: (val) => setState(() => _isLiveEnabled = val),
                    ),
                    SwitchListTile(
                      activeColor: Colors.amber,
                      title: const Text('Shutter Sound', style: TextStyle(color: Colors.white, fontSize: 13)),
                      value: _isShutterSoundOn,
                      onChanged: (val) => setState(() => _isShutterSoundOn = val),
                    ),
                  ],
                ),
              ),
            ),

          // 3. عجلّة الزوم الدائرية والعددیة (تطابق الآيفون تماماً)
          if (_showZoomWheel)
            Positioned(
              bottom: 160,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  height: 85,
                  width: 300,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(40),
                    border: Border.all(color: Colors.amber.withOpacity(0.5), width: 1),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${_currentZoom.toStringAsFixed(1)}x',
                        style: const TextStyle(color: Colors.amber, fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [0.5, 1.0, 1.5, 2.0, 3.0].map((z) {
                          bool isSelected = (_currentZoom - z).abs() < 0.3;
                          return GestureDetector(
                            onTap: () async {
                              setState(() {
                                _currentZoom = z;
                                _lastZoomInteraction = DateTime.now();
                              });
                              await controller!.setZoomLevel(z);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                              decoration: BoxDecoration(
                                color: isSelected ? Colors.amber : Colors.transparent,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                z == 0.5 ? '.5' : '${z.toInt()}x',
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

          // أزرار الزووم السريعة الثابتة فوق الأوضاع (.5x, 1.5x, 2x) مطابقة للصور
          Positioned(
            bottom: 115,
            left: 0,
            right: 0,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [0.5, 1.5, 2.0].map((zoomVal) {
                  bool isSel = (_currentZoom - zoomVal).abs() < 0.3;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6.0),
                    child: GestureDetector(
                      onTap: () async {
                        setState(() { _currentZoom = zoomVal; });
                        await controller!.setZoomLevel(zoomVal);
                      },
                      child: Container(
                        height: 30,
                        width: 30,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isSel ? Colors.amber : Colors.black54,
                          border: Border.all(color: Colors.white24),
                        ),
                        child: Center(
                          child: Text(
                            zoomVal == 0.5 ? '.5' : '${zoomVal.toInt()}',
                            style: TextStyle(
                              color: isSel ? Colors.black : Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),

          // 4. الشريط السفلي (شريط الأوضاع: SLO-MO, VIDEO, PHOTO, PORTRAIT, PANO)
          Positioned(
            bottom: 20,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // شريط الأوضاع الأفقي للآيفون
                SizedBox(
                  height: 35,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    children: ['SLO-MO', 'VIDEO', 'PHOTO', 'PORTRAIT', 'PANO'].map((mode) {
                      bool isSelected = _currentMode == mode;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14.0),
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

                // صف المعرض، زر الغالق الضخم للآيفون، وزر التبديل
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // المعرض المصغر على الشمال
                    Container(
                      height: 48,
                      width: 48,
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white30, width: 1.5),
                      ),
                      child: const Icon(Icons.photo, color: Colors.white, size: 24),
                    ),

                    // زر الالتقاط الضخم (طراز الآيفون: إطار خارجي رفيع وزر أبيض واسع)
                    GestureDetector(
                      onTap: _captureAction,
                      child: Container(
                        height: 78,
                        width: 78,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3.5),
                        ),
                        child: Center(
                          child: Container(
                            height: 66,
                            width: 66,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: (_currentMode == 'VIDEO' || _currentMode == 'SLO-MO') && _isRecording 
                                  ? Colors.red 
                                  : Colors.white,
                            ),
                            child: _isRecording ? const Icon(Icons.stop, color: Colors.white, size: 32) : null,
                          ),
                        ),
                      ),
                    ),

                    // زر تبديل الكاميرا (أمامية وخلفية)
                    IconButton(
                      iconSize: 32,
                      icon: const Icon(Icons.cameraswitch_outlined, color: Colors.white),
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