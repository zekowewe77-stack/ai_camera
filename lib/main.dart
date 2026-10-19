import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';

List<CameraDescription> _cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // طلب صلاحيات الكاميرا والميكروفون
  await Permission.camera.request();
  await Permission.microphone.request();

  try {
    // اكتشاف كل العدسات المتوفرة في الموبايل
    _cameras = await availableCameras();
  } catch (e) {
    debugPrint('خطأ في استشعار الكاميرات: $e');
  }

  runApp(const CameraAIApp());
}

class CameraAIApp extends StatelessWidget {
  const CameraAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Camera AI',
      theme: ThemeData.dark(),
      home: const CameraHomeScreen(),
    );
  }
}

class CameraHomeScreen extends StatefulWidget {
  const CameraHomeScreen({super.key});

  @override
  State<CameraHomeScreen> createState() => _CameraHomeScreenState();
}

class _CameraHomeScreenState extends State<CameraHomeScreen> {
  CameraController? _controller;
  bool _isInitialized = false;
  int _selectedCameraIndex = 0;
  
  // حالة زر Live Photo
  bool _isLiveAutoOn = true;

  @override
  void initState() {
    super.initState();
    if (_cameras.isNotEmpty) {
      _initCamera(_selectedCameraIndex);
    }
  }

  Future<void> _initCamera(int cameraIndex) async {
    setState(() {
      _isInitialized = false;
    });

    _controller = CameraController(
      _cameras[cameraIndex],
      ResolutionPreset.max, // تفعيل أقصى دقة للمستشعر (50MP+)
      enableAudio: true,
    );

    try {
      await _controller!.initialize();
      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      debugPrint('خطأ في تهيئة الكاميرا: $e');
    }
  }

  void _toggleCamera() {
    if (_cameras.length > 1) {
      _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras.length;
      _initCamera(_selectedCameraIndex);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized || _controller == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.amber),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // عرض الكاميرا بالدقة الكاملة
            Positioned.fill(
              child: CameraPreview(_controller!),
            ),

            // الشريط العلوي للاعدادات وزر الـ Live Auto أقصى اليسار
            Positioned(
              top: 15,
              left: 15,
              right: 15,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // زر Live Auto حصرياً أقصى الشمال
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _isLiveAutoOn = !_isLiveAutoOn;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: _isLiveAutoOn ? Colors.amber : Colors.grey,
                          width: 1.5,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.circle,
                            size: 12,
                            color: _isLiveAutoOn ? Colors.amber : Colors.grey,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            'LIVE AUTO',
                            style: TextStyle(
                              color: _isLiveAutoOn ? Colors.amber : Colors.grey,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // مؤشر الدقة العالية
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.amber),
                    ),
                    child: const Text(
                      '50MP AI',
                      style: TextStyle(color: Colors.amber, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),

            // الشريط السفلي للتحكم والالتقاط
            Positioned(
              bottom: 30,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // معرض الصور (معاينة)
                      Container(
                        width: 45,
                        height: 45,
                        decoration: BoxDecoration(
                          color: Colors.grey[900],
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white24),
                        ),
                        child: const Icon(Icons.image, color: Colors.white),
                      ),

                      // زر الالتقاط الكبير
                      GestureDetector(
                        onTap: () async {
                          if (_controller!.value.isTakingPicture) return;
                          try {
                            final image = await _controller!.takePicture();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('تم التقاط الصورة: ${image.path}')),
                            );
                          } catch (e) {
                            debugPrint('خطأ في الالتقاط: $e');
                          }
                        },
                        child: Container(
                          width: 75,
                          height: 75,
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.amber, width: 3),
                          ),
                          child: Container(
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),

                      // زر تبديل الكاميرا/العدسات
                      IconButton(
                        icon: const Icon(Icons.flip_camera_android, color: Colors.white, size: 30),
                        onPressed: _toggleCamera,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}