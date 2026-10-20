import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gal/gal.dart';
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
  double _maxZoom = 8.0;
  
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
    
    ResolutionPreset preset = ResolutionPreset.veryHigh;
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
      if (_maxZoom < 5.0) _maxZoom = 8.0;
      
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

  double get _effectiveMaxZoom {
    if (_currentMode == 'PORTRAIT') {
      return _maxZoom < 2.0 ? _maxZoom : 2.0;
    } else if (_currentMode == 'VIDEO') {
      return _maxZoom > 10.0 ? 10.0 : _maxZoom;
    }
    return _maxZoom;
  }

  Future<void> _toggleFlash() async {
    if (controller == null) return;
    setState(() {
      _flashMode = (_flashMode == FlashMode.off) ? FlashMode.torch : FlashMode.off;
    });
    try {
      await controller!.setFlashMode(_flashMode);
    } catch (e) {
      debugPrint('$e');
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
      _lastFocusTime = DateTime.now();
      _showExpandedPanel = false;
    });

    try {
      await controller!.setFocusPoint(offset);
      await controller!.setExposurePoint(offset);
    } catch (e) {
      debugPrint('$e');
    }

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && DateTime.now().difference(_lastFocusTime).inSeconds >= 3) {
        setState(() { _showFocusBox = false; });
      }
    });
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
      debugPrint('$e');
    }
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

      if (_currentMode == 'NIGHT') {
        try {
          await controller!.setExposureOffset(_maxAvailableExposureOffset);
        } catch (_) {}
        
        await Future.delayed(const Duration(milliseconds: 1000));
        final image = await controller!.takePicture();
        await Gal.putImage(image.path);
        
        try {
          await controller!.setExposureOffset(0.0);
        } catch (_) {}
      } else {
        final image = await controller!.takePicture();
        await Gal.putImage(image.path);
      }

      if (mounted) {
        setState(() { _isProcessing = false; });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved to gallery successfully!'), duration: Duration(milliseconds: 600)),
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video saved successfully!'), duration: Duration(milliseconds: 600)),
        );
      }
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
    WidgetsBinding.instance.addObserver(this);
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
                  onTapDown: (details) => _onTapToFocus(details, constraints),
                  onVerticalDragStart: _onVerticalDragStart,
                  onVerticalDragUpdate: _onVerticalDragUpdate,
                  onScaleStart: (_) {
                    setState(() { _showZoomWheel = true; _showExpandedPanel = false; });
                  },
                  onScaleUpdate: (details) async {
                    double scaleFactor = details.scale > 1 ? 1.015 : 0.985;
                    double newZoom = (_currentZoom * scaleFactor).clamp(_minZoom, _effectiveMaxZoom);
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

              if (_isGridActive)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Column(
                      children: [
                        Expanded(child: Container(decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white30, width: 0.5))))),
                        Expanded(child: Container(decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white30, width: 0.5))))),
                        Expanded(child: Container()),
                      ],
                    ),
                  ),
                ),

              if (_countdownSeconds > 0)
                Positioned.fill(
                  child: Center(
                    child: Text(
                      '$_countdownSeconds',
                      style: const TextStyle(color: Colors.white, fontSize: 80, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),

              if (_showFocusBox && _isAiFocusEnabled)
                Positioned(
                  left: _focusPoint.dx - 80,
                  top: _focusPoint.dy - 100,
                  child: Container(
                    width: 160,
                    height: 200,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white, width: 2.0),
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),

              if (_currentMode == 'PORTRAIT')
                Positioned(
                  top: 100,
                  left: 30,
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        _showApertureSlider = !_showApertureSlider;
                        _showExpandedPanel = false;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black54,
                        border: Border.all(color: Colors.amber, width: 1.5),
                      ),
                      child: const Icon(Icons.blur_on, color: Colors.amber, size: 24),
                    ),
                  ),
                ),

              if (_currentMode == 'PORTRAIT' && _showApertureSlider)
                Positioned(
                  top: 160,
                  left: 20,
                  right: 20,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.amber.withOpacity(0.5)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Aperture: f${_selectedAperture.toStringAsFixed(1)}',
                          style: const TextStyle(color: Colors.amber, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: _apertureValues.map((val) {
                              bool isSelected = _selectedAperture == val;
                              return GestureDetector(
                                onTap: () => setState(() => _selectedAperture = val),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  margin: const EdgeInsets.symmetric(horizontal: 4),
                                  decoration: BoxDecoration(
                                    color: isSelected ? Colors.amber : Colors.grey[900],
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'f${val.toStringAsFixed(val == 11 || val == 16 ? 0 : 1)}',
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
                        ),
                      ],
                    ),
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
                      child: Text(
                        _currentMode == 'NIGHT' ? '🌙 Processing Night Mode...' : '✨ Capturing High Quality...',
                        style: const TextStyle(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),

              if (_currentMode == 'VIDEO')
                Positioned(
                  top: 105,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var res in ['1080p', '2K', '4K'])
                          GestureDetector(
                            onTap: () {
                              setState(() { _videoResolution = res; });
                              _initCamera(selectedCameraIndex);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(
                                color: _videoResolution == res ? Colors.redAccent : Colors.black54,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(res, style: TextStyle(color: _videoResolution == res ? Colors.white : Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                            ),
                          ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            color: Colors.grey[850],
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text('30fps', style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                ),

              if (_isRecording)
                Positioned(
                  top: 95,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        _formatVideoTime(_videoSeconds),
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                      ),
                    ),
                  ),
                ),

              if (_showFocusBox)
                Positioned(
                  right: 20,
                  top: _focusPoint.dy - 40,
                  child: Container(
                    height: 120,
                    width: 35,
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.amber.withOpacity(0.6)),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.wb_sunny, color: Colors.amber, size: 16),
                        Expanded(
                          child: RotatedBox(
                            quarterTurns: 3,
                            child: Slider(
                              value: _exposureOffset,
                              min: _minAvailableExposureOffset,
                              max: _maxAvailableExposureOffset,
                              activeColor: Colors.amber,
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

              if (_showExpandedPanel)
                Positioned(
                  top: 90,
                  left: 20,
                  right: 20,
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.92),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildPanelItem(
                              _isHdrActive ? Icons.hdr_on : Icons.hdr_off,
                              'HDR',
                              _isHdrActive,
                              () => setState(() => _isHdrActive = !_isHdrActive),
                            ),
                            _buildPanelItem(
                              _isTimerActive ? Icons.timer : Icons.timer_off,
                              'Timer',
                              _isTimerActive,
                              () => setState(() {
                                _isTimerActive = !_isTimerActive;
                              }),
                            ),
                            _buildPanelItem(
                              Icons.branding_watermark,
                              'Watermark',
                              _isWatermarkActive,
                              () => setState(() => _isWatermarkActive = !_isWatermarkActive),
                            ),
                            _buildPanelItem(
                              Icons.grid_on,
                              'Grid',
                              _isGridActive,
                              () => setState(() {
                                _isGridActive = !_isGridActive;
                              }),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildPanelItem(
                              Icons.center_focus_strong,
                              'AI Focus',
                              _isAiFocusEnabled,
                              () => setState(() => _isAiFocusEnabled = !_isAiFocusEnabled),
                            ),
                            _buildPanelItem(
                              Icons.settings,
                              'Settings',
                              false,
                              () {
                                setState(() => _showExpandedPanel = false);
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (context) => const SettingsScreen()),
                                );
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

              Positioned(
                top: 40,
                left: 15,
                right: 15,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.document_scanner_outlined, color: Colors.white, size: 22),
                      onPressed: () {},
                    ),
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
                        setState(() {
                          _showExpandedPanel = !_showExpandedPanel;
                          _showApertureSlider = false;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.grey[900],
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Icon(
                          _showExpandedPanel ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                          color: Colors.greenAccent,
                          size: 24,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white, width: 1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('50M', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedAspectRatio = _selectedAspectRatio == '4:3' ? '16:9' : '4:3';
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(_selectedAspectRatio, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
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
                            max: _effectiveMaxZoom,
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
                      if (_effectiveMaxZoom >= 2.0)
                        GestureDetector(
                          onTap: () async {
                            setState(() { _currentZoom = 2.0; });
                            await controller!.setZoomLevel(2.0);
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
                                  color: _currentMode == 'VIDEO' && _isRecording 
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

  Widget _buildPanelItem(IconData icon, String label, bool isActive, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isActive ? Colors.amber.withOpacity(0.2) : Colors.grey[850],
              shape: BoxShape.circle,
              border: Border.all(color: isActive ? Colors.amber : Colors.transparent),
            ),
            child: Icon(icon, color: isActive ? Colors.amber : Colors.white70, size: 22),
          ),
          const SizedBox(height: 6),
          Text(label, style: TextStyle(color: isActive ? Colors.amber : Colors.white70, fontSize: 11)),
        ],
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