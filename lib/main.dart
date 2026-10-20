import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gal/gal.dart';
import 'package:open_file/open_file.dart';
import 'dart:io';

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

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  CameraController? controller;
  int selectedCameraIndex = 0;
  bool isPermissionGranted = false;

  FlashMode _flashMode = FlashMode.off;
  double _currentZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 8.0;
  
  bool _showZoomWheel = false;
  DateTime _lastZoomInteraction = DateTime.now();

  String _currentMode = 'PHOTO';
  bool _isRecording = false;
  bool _isLiveEnabled = true;
  bool _isHdrPlusEnabled = false;
  bool _isTimerActive = false;
  bool _isFilterActive = false;
  bool _showTopControlsMenu = false;
  bool _isShutterSoundOn = true;
  bool _isProcessing = false; // مؤشر جاري المعالجة السريع
  String? _lastCapturedPath; // مسار آخر صورة للفتح السريع من المعرض

  String _selectedAspectRatio = '4:3';
  
  bool _showFocusBox = false;
  Offset _focusPoint = Offset.zero;
  double _exposureOffset = 0.0;
  double _minAvailableExposureOffset = 0.0;
  double _maxAvailableExposureOffset = 0.0;
  double _dragStartY = 0.0;

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
      if (_maxZoom < 5.0) _maxZoom = 8.0;
      
      _currentZoom = _minZoom;
      await controller!.setZoomLevel(_currentZoom);
      await controller!.setFlashMode(_flashMode);

      _minAvailableExposureOffset = await controller!.getMinExposureOffset();
      _maxAvailableExposureOffset = await controller!.getMaxExposureOffset();
      _exposureOffset = 0.0;

      if (mounted) setState(() {});
    } catch (e) {
      print('Error initializing cameras: $e');
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

  Future<void> _onTapToFocus(TapDownDetails details, BoxConstraints constraints) async {
    if (controller == null || !controller!.value.isInitialized) return;

    final offset = Offset(
      details.localPosition.dx / constraints.maxWidth,
      details.localPosition.dy / constraints.maxHeight,
    );

    setState(() {
      _showFocusBox = true;
      _focusPoint = details.localPosition;
    });

    try {
      await controller!.setFocusPoint(offset);
      await controller!.setExposurePoint(offset);
    } catch (e) {
      print(e);
    }
  }

  void _onVerticalDragStart(DragStartDetails details) {
    _dragStartY = details.localPosition.dy;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) async {
    if (controller == null || !controller!.value.isInitialized) return;
    double delta = _dragStartY - details.localPosition.dy;
    double sensitivity = 150.0;
    double newOffset = (_exposureOffset + (delta / sensitivity) * (_maxAvailableExposureOffset - _minAvailableExposureOffset))
        .clamp(_minAvailableExposureOffset, _maxAvailableExposureOffset);

    setState(() {
      _exposureOffset = newOffset;
      _dragStartY = details.localPosition.dy;
    });

    try {
      await controller!.setExposureOffset(_exposureOffset);
    } catch (e) {
      print(e);
    }
  }

  // التقاط فوري بدون أي تعليق، والمعالجة تتم بسلاسة
  Future<void> _captureAction() async {
    if (controller == null || !controller!.value.isInitialized || _isProcessing) return;

    if (_currentMode == 'VIDEO' || _currentMode == 'SLO-MO') {
      _toggleVideoRecording();
      return;
    }

    try {
      _flashAnimController.forward().then((_) => _flashAnimController.reverse());
      
      if (_isShutterSoundOn) {
        SystemSound.play(SystemSoundType.click);
        HapticFeedback.heavyImpact();
      }

      setState(() { _isProcessing = true; });

      // التقاط الصورة الفورية فوراً لتظهر في ساعتها
      final image = await controller!.takePicture();
      await Gal.putImage(image.path);
      
      setState(() {
        _lastCapturedPath = image.path;
        _isProcessing = false;
      });

      // إذا كانت الصورة الحية مفعلة، نقوم بمعالجتها في الخلفية بدون تجميد الكاميرا
      if (_isLiveEnabled) {
        Future.microtask(() async {
          try {
            await controller!.startVideoRecording();
            await Future.delayed(const Duration(milliseconds: 800));
            final liveVideo = await controller!.stopVideoRecording();
            
            File imgFile = File(image.path);
            File vidFile = File(liveVideo.path);
            
            if (await imgFile.exists() && await vidFile.exists()) {
              List<int> imageBytes = await imgFile.readAsBytes();
              List<int> videoBytes = await vidFile.readAsBytes();

              List<int> motionPhotoBytes = []
                ..addAll(imageBytes)
                ..addAll(videoBytes);

              String motionPath = image.path.replaceAll('.jpg', '_live.jpg');
              File motionFile = File(motionPath);
              await motionFile.writeAsBytes(motionPhotoBytes);

              await Gal.putImage(motionFile.path);
              setState(() { _lastCapturedPath = motionFile.path; });
            }
          } catch (_) {}
        });
      }
    } catch (e) {
      print('Error capturing: $e');
      setState(() { _isProcessing = false; });
    }
  }

  Future<void> _toggleVideoRecording() async {
    if (controller == null || !controller!.value.isInitialized) return;
    if (_isRecording) {
      final file = await controller!.stopVideoRecording();
      setState(() { _isRecording = false; });
      await Gal.putVideo(file.path);
      setState(() { _lastCapturedPath = file.path; });
    } else {
      await controller!.startVideoRecording();
      setState(() { _isRecording = true; });
    }
  }

  // فتح آخر صورة تم التقاطها بضغطة واحدة من زر المعرض على الشمال
  Future<void> _openLastGalleryItem() async {
    if (_lastCapturedPath != null && await File(_lastCapturedPath!).exists()) {
      await OpenFile.open(_lastCapturedPath!);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('التقط صورة أولاً لفتحها!'), duration: Duration(milliseconds: 600)),
      );
    }
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
      child: ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
            1.1, 0, 0, 0, 10,
            0, 1.1, 0, 0, 10,
            0, 0, 1.1, 0, 10,
            0, 0, 0, 1, 0,
        ]),
        child: Transform(
          alignment: Alignment.center,
          transform: isFrontCamera ? Matrix4.rotationY(0) : Matrix4.identity(),
          child: CameraPreview(controller!),
        ),
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
                  onTapDown: (details) => _onTapToFocus(details, constraints),
                  onVerticalDragStart: _onVerticalDragStart,
                  onVerticalDragUpdate: _onVerticalDragUpdate,
                  onScaleStart: (_) {
                    setState(() { _showZoomWheel = true; });
                  },
                  onScaleUpdate: (details) async {
                    double scaleFactor = details.scale > 1 ? 1.015 : 0.985;
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

              // مؤشر جاري المعالجة الاحترافي
              if (_isProcessing)
                Positioned(
                  top: 130,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.amber.withOpacity(0.5)),
                      ),
                      child: const Text(
                        'جاري المعالجة...',
                        style: TextStyle(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),

              if (_showFocusBox)
                Positioned(
                  left: _focusPoint.dx - 35,
                  top: _focusPoint.dy - 35,
                  child: Row(
                    children: [
                      Container(
                        height: 70,
                        width: 70,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.greenAccent, width: 1.5),
                        ),
                        child: const Center(
                          child: Icon(Icons.wb_sunny_outlined, color: Colors.greenAccent, size: 20),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 90,
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: Slider(
                            value: _exposureOffset,
                            min: _minAvailableExposureOffset,
                            max: _maxAvailableExposureOffset,
                            activeColor: Colors.greenAccent,
                            inactiveColor: Colors.white24,
                            onChanged: (val) async {
                              setState(() { _exposureOffset = val; });
                              await controller!.setExposureOffset(val);
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              AnimatedBuilder(
                animation: _flashAnimation,
                builder: (context, child) {
                  return IgnorePointer(
                    child: Container(
                      color: Colors.white.withOpacity(_flashAnimation.value),
                    ),
                  );
                },
              ),

              // الشريط العلوي
              Positioned(
                top: 40,
                left: 15,
                right: 15,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    IconButton(
                      icon: Icon(
                        _flashMode == FlashMode.torch ? Icons.flash_on : Icons.flash_off,
                        color: _flashMode == FlashMode.torch ? Colors.amber : Colors.white,
                        size: 22,
                      ),
                      onPressed: _toggleFlash,
                    ),
                    GestureDetector(
                      onTap: () {
                        setState(() { _isHdrPlusEnabled = !_isHdrPlusEnabled; });
                      },
                      child: Text(
                        'HDR+',
                        style: TextStyle(
                          color: _isHdrPlusEnabled ? Colors.amber : Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        setState(() { _isLiveEnabled = !_isLiveEnabled; });
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(_isLiveEnabled ? '✨ Live Motion Photo: ON' : 'Live Photo: OFF'),
                            duration: const Duration(milliseconds: 500),
                            backgroundColor: Colors.amber[800],
                          ),
                        );
                      },
                      child: Icon(
                        _isLiveEnabled ? Icons.motion_photos_on : Icons.motion_photos_off,
                        color: _isLiveEnabled ? Colors.amber : Colors.white70,
                        size: 24,
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        setState(() { _isTimerActive = !_isTimerActive; });
                      },
                      child: Icon(
                        Icons.timer_outlined,
                        color: _isTimerActive ? Colors.amber : Colors.white70,
                        size: 22,
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        setState(() { _isFilterActive = !_isFilterActive; });
                      },
                      child: Icon(
                        Icons.filter_vintage_outlined,
                        color: _isFilterActive ? Colors.amber : Colors.white70,
                        size: 22,
                      ),
                    ),
                  ],
                ),
              ),

              // سهم القائمة المنسدلة
              Positioned(
                top: 78,
                left: 0,
                right: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: () {
                      setState(() { _showTopControlsMenu = !_showTopControlsMenu; });
                    },
                    child: Icon(
                      _showTopControlsMenu ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                ),
              ),

              if (_showTopControlsMenu)
                Positioned(
                  top: 110,
                  left: 25,
                  right: 25,
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.amber.withOpacity(0.4)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SwitchListTile(
                          activeColor: Colors.amber,
                          title: const Text('صوت ضغطة الكاميرا (Shutter)', style: TextStyle(color: Colors.white, fontSize: 13)),
                          value: _isShutterSoundOn,
                          onChanged: (val) => setState(() => _isShutterSoundOn = val),
                        ),
                        const Divider(color: Colors.white24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('أبعاد الإطار:', style: TextStyle(color: Colors.white, fontSize: 13)),
                            DropdownButton<String>(
                              dropdownColor: Colors.grey[900],
                              value: _selectedAspectRatio,
                              items: ['4:3', '16:9', '1:1', 'Full'].map((ratio) {
                                return DropdownMenuItem(
                                  value: ratio,
                                  child: Text(ratio, style: const TextStyle(color: Colors.amber, fontSize: 13)),
                                );
                              }).toList(),
                              onChanged: (val) {
                                if (val != null) setState(() => _selectedAspectRatio = val);
                              },
                            ),
                          ],
                        ),
                      ],
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
                              await controller!.setZoomLevel(val);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              Positioned(
                bottom: 195,
                left: 0,
                right: 0,
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: () async {
                          setState(() { _currentZoom = _minZoom; });
                          await controller!.setZoomLevel(_minZoom);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(15),
                            color: (_currentZoom - _minZoom).abs() < 0.3 ? Colors.amber : Colors.black54,
                            border: Border.all(color: Colors.white24),
                          ),
                          child: Text(
                            _minZoom < 1.0 ? '.5x' : '1x',
                            style: TextStyle(
                              color: (_currentZoom - _minZoom).abs() < 0.3 ? Colors.black : Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () async {
                          double targetZoom = _maxZoom >= 2.0 ? 2.0 : _maxZoom;
                          setState(() { _currentZoom = targetZoom; });
                          await controller!.setZoomLevel(targetZoom);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(15),
                            color: (_currentZoom - 2.0).abs() < 0.3 ? Colors.amber : Colors.black54,
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const Text(
                            '2x',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // الشريط السفلي (مع تفعيل زر المعرض الأيسر لفتح آخر صورة فوراً)
              Positioned(
                bottom: 60,
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
                        // زر المعرض على الشمال لفتح آخر صورة فوراً بضغطة واحدة
                        GestureDetector(
                          onTap: _openLastGalleryItem,
                          child: Container(
                            height: 48,
                            width: 48,
                            decoration: BoxDecoration(
                              color: Colors.grey[900],
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white30, width: 1.5),
                              image: _lastCapturedPath != null && File(_lastCapturedPath!).existsSync()
                                  ? DecorationImage(
                                      image: FileImage(File(_lastCapturedPath!)),
                                      fit: BoxFit.cover,
                                    )
                                  : null,
                            ),
                            child: _lastCapturedPath == null
                                ? const Icon(Icons.photo, color: Colors.white, size: 24)
                                : null,
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
                                  color: (_currentMode == 'VIDEO' || _currentMode == 'SLO-MO') && _isRecording 
                                      ? Colors.red 
                                      : Colors.white,
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