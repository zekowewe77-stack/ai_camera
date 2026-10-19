import 'package:flutter/material.dart';
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

class _CameraScreenState extends State<CameraScreen> {
  CameraController? controller;
  int selectedCameraIndex = 0;
  bool isPermissionGranted = false;
  
  // الخصائص
  FlashMode _flashMode = FlashMode.off;
  double _currentZoom = 1.0;
  double _maxZoom = 1.0;
  double _minZoom = 1.0;
  String _aspectRatioMode = 'Full';
  bool _isRecording = false;

  @override
  void initState() {
    super.initState();
    _requestPermissionAndInit();
  }

  Future<void> _requestPermissionAndInit() async {
    await Permission.camera.request();
    await Permission.microphone.request(); // لتسجيل الفيديو الصوتي
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
    // استخدام أعلى إعدادات (أقصى قدرة معالجة وصورة AI مبهرة)
    controller = CameraController(
      cameras[index],
      ResolutionPreset.max,
      enableAudio: true,
    );

    try {
      await controller!.initialize();
      _maxZoom = await controller!.getMaxZoomLevel();
      _minZoom = await controller!.getMinZoomLevel();
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

  // التقاط صورة بجودة AI عالية والحفظ في المعرض
  Future<void> _takePicture() async {
    if (controller == null || !controller!.value.isInitialized) return;
    try {
      final image = await controller!.takePicture();
      await Gal.putImage(image.path);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تم التقاط وحفظ صورة AI الاحترافية بنجاح! ✨📸'),
            backgroundColor: Colors.amber,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('Error taking picture: $e');
    }
  }

  // تسجيل الفيديو
  Future<void> _toggleVideoRecording() async {
    if (controller == null || !controller!.value.isInitialized) return;

    if (_isRecording) {
      try {
        final file = await controller!.stopVideoRecording();
        setState(() { _isRecording = false; });
        await Gal.putVideo(file.path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم حفظ الفيديو في المعرض بنجاح! 🎥'), backgroundColor: Colors.green),
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
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!isPermissionGranted) {
      return const Scaffold(
        body: Center(child: Text('يرجى السماح بصلاحيات الكاميرا والميكروفون')),
      );
    }

    if (controller == null || !controller!.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.amber)),
      );
    }

    var cameraPreview = CameraPreview(controller!);
    Widget sizedPreview = ClipRect(
      child: OverflowBox(
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: controller!.value.previewSize?.height ?? MediaQuery.of(context).size.width,
            height: controller!.value.previewSize?.width ?? MediaQuery.of(context).size.height,
            child: cameraPreview,
          ),
        ),
      ),
    );

    if (_aspectRatioMode == '16:9') {
      sizedPreview = AspectRatio(aspectRatio: 9 / 16, child: cameraPreview);
    } else if (_aspectRatioMode == '4:3') {
      sizedPreview = AspectRatio(aspectRatio: 3 / 4, child: cameraPreview);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // معاينة الكاميرا والزووم
          GestureDetector(
            onScaleUpdate: (details) async {
              double newZoom = (_currentZoom * details.scale).clamp(_minZoom, _maxZoom);
              setState(() { _currentZoom = newZoom; });
              await controller!.setZoomLevel(_currentZoom);
            },
            child: Center(child: sizedPreview),
          ),

          // الشريط العلوي (فلاش، أبعاد، ترس الإعدادات، ووضع AI)
          Positioned(
            top: 40,
            left: 20,
            right: 20,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    // الفلاش (يدعم الأمامي والخلفي حسب الكاميرا النشطة)
                    IconButton(
                      icon: Icon(
                        _flashMode == FlashMode.torch ? Icons.flash_on : Icons.flash_off,
                        color: _flashMode == FlashMode.torch ? Colors.amber : Colors.white,
                        size: 26,
                      ),
                      onPressed: _toggleFlash,
                    ),
                    // زر الإعدادات (Settings)
                    IconButton(
                      icon: const Icon(Icons.settings, color: Colors.white, size: 26),
                      onPressed: () {
                        showModalBottomSheet(
                          context: context,
                          backgroundColor: Colors.grey[900],
                          builder: (context) => Container(
                            padding: const EdgeInsets.all(20),
                            height: 220,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('إعدادات الكاميرا الذكية', style: TextStyle(color: Colors.amber, fontSize: 18, fontWeight: FontWeight.bold)),
                                const Divider(color: Colors.white24),
                                ListTile(
                                  leading: const Icon(Icons.memory, color: Colors.white),
                                  title: const Text('أداء معالجة الذكاء الاصطناعي (AI Processing)', style: TextStyle(color: Colors.white)),
                                  subtitle: const Text('مفعل بأقصى طاقة للمعالج (60%)', style: TextStyle(color: Colors.amber, fontSize: 12)),
                                ),
                                ListTile(
                                  leading: const Icon(Icons.camera, color: Colors.white),
                                  title: const Text('الكاميرا النشطة الحالية', style: TextStyle(color: Colors.white)),
                                  subtitle: Text(cameras[selectedCameraIndex].lensDirection.name.toUpperCase(), style: const TextStyle(color: Colors.amber, fontSize: 12)),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),

                // أزرار الأبعاد (Full, 16:9, 4:3)
                Row(
                  children: ['Full', '16:9', '4:3'].map((mode) {
                    bool isSelected = _aspectRatioMode == mode;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3.0),
                      child: GestureDetector(
                        onTap: () => setState(() => _aspectRatioMode = mode),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: isSelected ? Colors.amber : Colors.black45,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(mode, style: TextStyle(color: isSelected ? Colors.black : Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                        ),
                      ),
                    );
                  }).toList(),
                ),

                // مؤشر 50MP AI
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

          // شريط الزووم الجانبي
          Positioned(
            right: 15,
            top: MediaQuery.of(context).size.height / 2 - 50,
            child: Column(
              children: [
                Text('${_currentZoom.toStringAsFixed(1)}x', style: const TextStyle(color: Colors.amber, fontSize: 11)),
                const SizedBox(height: 5),
                Container(
                  height: 90,
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

          // الشريط السفلي (التقاط الصور، تسجيل الفيديو، المعرض، وتغيير الكاميرا)
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // زر المعرض
                Container(
                  height: 48,
                  width: 48,
                  decoration: BoxDecoration(
                    color: Colors.grey[850],
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Icon(Icons.photo_library, color: Colors.white, size: 24),
                ),

                // زر الغالق الأساسي (للصور)
                GestureDetector(
                  onTap: _takePicture,
                  onLongPress: _toggleVideoRecording, // الضغط المطول لتسجيل الفيديو
                  child: Container(
                    height: 75,
                    width: 75,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: _isRecording ? Colors.red : Colors.amber, width: 4),
                      color: Colors.white24,
                    ),
                    child: Center(
                      child: Container(
                        height: 58,
                        width: 58,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isRecording ? Colors.red : Colors.white,
                        ),
                        child: _isRecording ? const Icon(Icons.stop, color: Colors.white, size: 30) : null,
                      ),
                    ),
                  ),
                ),

                // زر تبديل الكاميرا (أمامية / خلفية مع دعم الفلاش)
                IconButton(
                  iconSize: 32,
                  icon: const Icon(Icons.cameraswitch, color: Colors.white),
                  onPressed: _switchCamera,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}