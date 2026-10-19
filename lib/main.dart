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

  FlashMode _flashMode = FlashMode.off;
  double _currentZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 5.0;
  
  bool _showZoomWheel = false;
  DateTime _lastZoomInteraction = DateTime.now();

  String _currentMode = 'PHOTO';
  bool _isRecording = false;
  bool _isLiveEnabled = true;
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

  Future<void> _captureAction() async {
    if (controller == null || !controller!.value.isInitialized) return;

    if (_currentMode == 'VIDEO' || _currentMode == 'SLO-MO') {
      _toggleVideoRecording();
      return;
    }

    try {
      if (_isShutterSoundOn) SystemSound.play(SystemSoundType.click);

      final image = await controller!.takePicture();
      await Gal.putImage(image.path);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isLiveEnabled ? '✨ Live Photo Captured & Saved' : '📸 Pro Photo Captured'),
            backgroundColor: _isLiveEnabled ? Colors.amber[800] : Colors.black87,
            duration: const Duration(milliseconds: 1000),
          ),
        );
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

    // التحقق هل الكاميرا الحالية أمامية لعكس الصورة وظبطها بالشكل الصحيح
    bool isFrontCamera = cameras[selectedCameraIndex].lensDirection == CameraLensDirection.front;

    Widget previewWidget = AspectRatio(
      aspectRatio: 3 / 4,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.center,
          child: FittedBox(
            fit: BoxFit.fitHeight,
            child: SizedBox(
              width: controller!.value.previewSize?.height ?? 720,
              height: controller!.value.previewSize?.width ?? 1280,
              child: Transform(
                alignment: Alignment.center,
                transform: isFrontCamera ? Matrix4.rotationY(3.14159) : Matrix4.identity(),
                child: CameraPreview(controller!),
              ),
            ),
          ),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
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

          // الشريط العلوي
          Positioned(
            top: 45,
            left: 20,
            right: 20,
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

          // عجلة الزووم الدائرية
          if (_showZoomWheel)
            Positioned(
              bottom: 215,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  height: 75,
                  width: 280,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(35),
                    border: Border.all(color: Colors.amber.withOpacity(0.6), width: 1.2),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${_currentZoom.toStringAsFixed(1)}x',
                        style: const TextStyle(color: Colors.amber, fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Slider(
                        value: _currentZoom,
                        min: _minZoom,
                        max: _maxZoom,
                        activeColor: Colors.amber,
                        inactiveColor: Colors.white24,
                        onChanged: (val) async {
                          setState(() {
                            _currentZoom = val;
                            _lastZoomInteraction = DateTime.now();
                          });
                          await controller!.setZoomLevel(val);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // أزرار التكبير الثابتة (مفصولة ومنظمة تماماً)
          Positioned(
            bottom: 175,
            left: 0,
            right: 0,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [0.5, 1.0, 2.0].map((zoomVal) {
                  bool isSel = (_currentZoom - zoomVal).abs() < 0.3;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6.0),
                    child: GestureDetector(
                      onTap: () async {
                        setState(() { _currentZoom = zoomVal; });
                        await controller!.setZoomLevel(zoomVal);
                      },
                      child: Container(
                        height: 32,
                        width: 32,
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

          // الشريط السفلي (شريط الأوضاع وأزرار الالتقاط)
          Positioned(
            bottom: 20,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 30,
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

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Container(
                      height: 48,
                      width: 48,
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white30, width: 1.5),
                      ),
                      child: const Icon(Icons.photo, color: Colors.white, size: 24),
                    ),

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