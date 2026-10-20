import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'dart:async';
import 'dart:io';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera Error: $e');
  }
  runApp(const CameraApp());
}

class CameraApp extends StatelessWidget {
  const CameraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AI Camera Pro 2027',
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

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  CameraController? controller;
  int selectedCameraIndex = 0;
  bool isPermissionGranted = false;

  FlashMode _flashMode = FlashMode.off;
  double _currentZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 15.0;
  
  bool _showZoomWheel = false;
  DateTime _lastZoomInteraction = DateTime.now();

  String _currentMode = 'PHOTO';
  bool _isRecording = false;
  bool _isAiFocusEnabled = true;
  bool _isTimerActive = false;
  bool _isGridActive = false;
  bool _isProcessing = false;
  int _countdownSeconds = 0;

  Timer? _videoTimer;
  int _videoSeconds = 0;

  bool _showExpandedPanel = false;
  bool _isHdrActive = true;
  bool _isWatermarkActive = false;

  String _videoResolution = '1080p';
  String _selectedAspectRatio = '4:3';

  bool _showApertureSlider = false;
  double _selectedAperture = 4.0;
  final List<double> _apertureValues = [1.4, 2.0, 2.8, 4.0, 5.6, 8.0, 11.0, 16.0];
  
  bool _showFocusBox = false;
  Offset _focusPoint = Offset.zero;
  double _exposureOffset = 0.0;
  double _minAvailableExposureOffset = 0.0;
  double _maxAvailableExposureOffset = 0.0;
  double _dragStartY = 0.0;
  DateTime _lastFocusTime = DateTime.now();

  late AnimationController _flashAnimController;
  late Animation<double> _flashAnimation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    _flashAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _flashAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(_flashAnimController);

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
      if (mounted) setState(() { isPermissionGranted = true; });
      if (cameras.isNotEmpty) _initCamera(selectedCameraIndex);
    }
  }

  Future<void> _initCamera(int index) async {
    if (controller != null) await controller!.dispose();
    
    ResolutionPreset preset = ResolutionPreset.max;
    if (_videoResolution == '4K') {
      preset = ResolutionPreset.max;
    } else if (_videoResolution == '2K') {
      preset = ResolutionPreset.ultraHigh;
    }

    controller = CameraController(
      cameras[index],
      preset,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller!.initialize();
      _minZoom = await controller!.getMinZoomLevel();
      _maxZoom = await controller!.getMaxZoomLevel();
      if (_maxZoom < 15.0) _maxZoom = 15.0;
      
      _currentZoom = _minZoom;
      await controller!.setZoomLevel(_currentZoom);
      await controller!.setFlashMode(_flashMode);

      _minAvailableExposureOffset = await controller!.getMinExposureOffset();
      _maxAvailableExposureOffset = await controller!.getMaxExposureOffset();
      _exposureOffset = 0.0;

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Error initializing camera: $e');
    }
  }

  void _switchCamera() {
    if (cameras.length > 1) {
      selectedCameraIndex = (selectedCameraIndex + 1) % cameras.length;
      _initCamera(selectedCameraIndex);
    }
  }

  // خوارزمية معالجة الحِدة والوضوح الفائق للتغلب على الكاميرا الأصلية
  Future<String> _enhanceAndSharpenImage(String imagePath) async {
    try {
      final File imageFile = File(imagePath);
      final List<int> bytes = await imageFile.readAsBytes();
      img.Image? capturedImage = img.decodeJpg(Uint8List.fromList(bytes));

      if (capturedImage != null) {
        // مصفوفة الحِدة لإبراز النصوص والحواف عند الزوم 15x
        img.Image sharpenedImage = img.convolution(
          capturedImage,
          filter: [
             0, -1,  0,
            -1,  5, -1,
             0, -1,  0
          ],
          div: 1,
          offset: 0,
        );

        sharpenedImage = img.adjustColor(
          sharpenedImage,
          contrast: 1.15,
          saturation: 1.05,
        );

        final List<int> processedBytes = img.encodeJpg(sharpenedImage, quality: 100);
        await imageFile.writeAsBytes(processedBytes);
      }
    } catch (e) {
      debugPrint('Error sharpening image: $e');
    }
    return imagePath;
  }

  Future<void> _captureAction() async {
    if (controller == null || !controller!.value.isInitialized || _isProcessing) return;

    if (_currentMode == 'VIDEO') {
      _toggleVideoRecording();
      return;
    }

    if (_isTimerActive) {
      setState(() { _countdownSeconds = 3; });
      for (int i = 3; i > 0; i--) {
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) setState(() { _countdownSeconds = i - 1; });
      }
    }

    try {
      _flashAnimController.forward().then((_) => _flashAnimController.reverse());
      SystemSound.play(SystemSoundType.click);
      HapticFeedback.heavyImpact();

      setState(() { _isProcessing = true; _showExpandedPanel = false; });

      final image = await controller!.takePicture();
      final String enhancedPath = await _enhanceAndSharpenImage(image.path);
      await Gal.putImage(enhancedPath);

      if (mounted) {
        setState(() { _isProcessing = false; });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم التقاط ومعالجة الصورة بجودة فائقة!'), duration: Duration(milliseconds: 600)),
        );
      }
    } catch (e) {
      debugPrint('Error capturing: $e');
      if (mounted) setState(() { _isProcessing = false; });
    }
  }

  Future<void> _toggleVideoRecording() async {
    if (controller == null || !controller!.value.isInitialized) return;
    if (_isRecording) {
      _videoTimer?.cancel();
      final file = await controller!.stopVideoRecording();
      setState(() { 
        _isRecording = false; 
        _videoSeconds = 0;
      });
      await Gal.putVideo(file.path);
    } else {
      await controller!.startVideoRecording();
      setState(() { 
        _isRecording = true; 
        _videoSeconds = 0;
      });
      _videoTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() {
          _videoSeconds++;
        });
      });
    }
  }

  String _formatVideoTime(int seconds) {
    int minutes = seconds ~/ 60;
    int remainingSeconds = seconds % 60;
    String minStr = minutes.toString().padLeft(2, '0');
    String secStr = remainingSeconds.toString().padLeft(2, '0');
    return "00:$minStr:$secStr";
  }

  double _getAspectRatioValue() {
    switch (_selectedAspectRatio) {
      case '1:1':
        return 1.0;
      case '16:9':
        return 16.5 / 9;
      case 'Full':
        return 9 / 19.5;
      case '4:3':
      default:
        return 3 / 4;
    }
  }

  @override
  void dispose() {
    _videoTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _flashAnimController.dispose();
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

    bool isFrontCamera = cameras[selectedCameraIndex].lensDirection == CameraLensDirection.front;

    Widget previewWidget = AspectRatio(
      aspectRatio: _getAspectRatioValue(),
      child: Transform(
        alignment: Alignment.center,
        transform: isFrontCamera ? Matrix4.rotationY(0) : Matrix4.identity(),
        child: CameraPreview(controller!),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onScaleStart: (_) {
                    setState(() { _showZoomWheel = true; _showExpandedPanel = false; });
                  },
                  onScaleUpdate: (details) async {
                    double scaleFactor = details.scale > 1 ? 1.02 : 0.98;
                    double newZoom = (_currentZoom * scaleFactor).clamp(_minZoom, _maxZoom);
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

              if (_isProcessing)
                Positioned(
                  top: 130,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.amber, width: 1),
                      ),
                      child: const Text(
                        '✨ جاري معالجة وحِدة الـ AI للزوم...',
                        style: TextStyle(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),

              if (_showZoomWheel)
                Positioned(
                  bottom: 235,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      height: 70,
                      width: 270,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.85),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: Colors.amber.withOpacity(0.6), width: 1.2),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '${_currentZoom.toStringAsFixed(1)}x',
                            style: const TextStyle(color: Colors.amber, fontSize: 13, fontWeight: FontWeight.bold),
                          ),
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
                              await controller!.setZoomLevel(_currentZoom);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              Positioned(
                bottom: 60,
                left: 0,
                right: 0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 30,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: ['VIDEO', 'PHOTO', 'PORTRAIT', 'NIGHT'].map((mode) {
                          bool isSelected = _currentMode == mode;
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12.0),
                            child: GestureDetector(
                              onTap: () => setState(() {
                                _currentMode = mode;
                                if (mode != 'PORTRAIT') _showApertureSlider = false;
                                _showExpandedPanel = false;
                              }),
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
                        GestureDetector(
                          onTap: () {},
                          child: Container(
                            height: 48,
                            width: 48,
                            decoration: BoxDecoration(
                              color: Colors.grey[900],
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white30, width: 1.5),
                            ),
                            child: const Icon(Icons.photo, color: Colors.white, size: 24),
                          ),
                        ),
                        GestureDetector(
                          onTap: _captureAction,
                          child: Container(
                            height: 75,
                            width: 75,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3.5),
                            ),
                            child: Center(
                              child: Container(
                                height: 63,
                                width: 63,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _currentMode == 'VIDEO' && _isRecording ? Colors.red : Colors.white,
                                ),
                                child: _isRecording ? const Icon(Icons.stop, color: Colors.white, size: 30) : null,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          iconSize: 30,
                          icon: const Icon(Icons.cameraswitch_outlined, color: Colors.white),
                          onPressed: _switchCamera,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          ListTile(
            title: Text('Shutter Sound'),
            trailing: Icon(Icons.arrow_forward_ios, size: 14),
          ),
          ListTile(
            title: Text('Location Watermark'),
            trailing: Icon(Icons.arrow_forward_ios, size: 14),
          ),
          ListTile(
            title: Text('Grid Lines'),
            trailing: Icon(Icons.arrow_forward_ios, size: 14),
          ),
        ],
      ),
    );
  }
}