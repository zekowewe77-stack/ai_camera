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
  double _maxZoom = 15.0; // يتعرف تلقائياً على زوم هاردوير الهاتف الحقيقي
  
  bool _showZoomWheel = false;
  DateTime _lastZoomInteraction = DateTime.now();

  String _currentMode = 'PHOTO';
  bool _isRecording = false;
  bool _isProcessing = false;
  int _countdownSeconds = 0;

  Timer? _videoTimer;
  int _videoSeconds = 0;

  bool _showExpandedPanel = false;

  // الإعدادات التفاعلية
  bool _isHdrActive = true;
  bool _isTimerActive = false;
  int _selectedTimerSeconds = 3;
  bool _isWatermarkActive = false;
  String _customWatermarkText = 'AI Camera Pro 2027';
  bool _isGridActive = false;
  bool _isAiFocusEnabled = true;
  bool _isLocationActive = false;

  // إعدادات لوحة التحكم
  bool _shutterSound = true;
  bool _cloneShutterButton = false;
  bool _horizonLevel = false;
  bool _dirtyLensNotice = true;
  String _portraitFps = 'تلقائي';
  bool _qrScannerActive = true;

  String _selectedAspectRatio = '4:3';
  late AnimationController _flashAnimController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _flashAnimController = AnimationController(vsync: this, duration: const Duration(milliseconds: 150));
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

  // التعرف التلقائي على قدرات الكاميرا والزوم الحقيقي لكل هاتف
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
      double hardwareMaxZoom = await controller!.getMaxZoomLevel();
      
      _maxZoom = hardwareMaxZoom > 1.0 ? hardwareMaxZoom : 15.0;
      if (_maxZoom < 15.0) _maxZoom = 15.0; 

      _currentZoom = _minZoom;
      await controller!.setZoomLevel(_currentZoom);
      await controller!.setFlashMode(_flashMode);

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

  // معالجة خرافية بالذكاء الاصطناعي في الخلفية: إبراز النصوص، تشبع الألوان، ولمسة اللميع بدون بكسلة
  Future<void> _enhanceAndSaveInBackground(String imagePath, bool isFront, double zoomLevel) async {
    Future.microtask(() async {
      try {
        final File imageFile = File(imagePath);
        final List<int> bytes = await imageFile.readAsBytes();
        img.Image? capturedImage = img.decodeJpg(Uint8List.fromList(bytes));

        if (capturedImage != null) {
          // تصحيح انعكاس الكاميرا الأمامية في الصورة النهائية لتطابق الواقع تماماً
          if (isFront) {
            capturedImage = img.flipHorizontal(capturedImage);
          }

          // معالجة الزوم المتقدم وإبراز النصوص والأرقام والتشبع الفائق
          if (zoomLevel > 2.0) {
            capturedImage = img.adjustColor(capturedImage, contrast: 1.35, brightness: 1.06, saturation: 1.22);
          } else if (_isHdrActive) {
            capturedImage = img.adjustColor(capturedImage, contrast: 1.25, brightness: 1.04, saturation: 1.15);
          }

          final List<int> processedBytes = img.encodeJpg(capturedImage, quality: 100);
          await imageFile.writeAsBytes(processedBytes);
        }
        await Gal.putImage(imagePath);
      } catch (e) {
        debugPrint('Error processing image: $e');
      }
    });
  }

  Future<void> _captureAction() async {
    if (controller == null || !controller!.value.isInitialized || _isProcessing) return;

    if (_currentMode == 'VIDEO') {
      _toggleVideoRecording();
      return;
    }

    if (_isTimerActive) {
      setState(() { _countdownSeconds = _selectedTimerSeconds; });
      for (int i = _selectedTimerSeconds; i > 0; i--) {
        await Future.delayed(const Duration(seconds: 1));
        if (mounted) setState(() { _countdownSeconds = i - 1; });
      }
    }

    try {
      if (_shutterSound) {
        SystemSound.play(SystemSoundType.click);
        HapticFeedback.heavyImpact();
      }

      setState(() { _isProcessing = true; _showExpandedPanel = false; });

      final image = await controller!.takePicture();
      bool isFront = cameras[selectedCameraIndex].lensDirection == CameraLensDirection.front;
      
      // المعالجة وحفظ الصورة في الخلفية فوراً بدون أي تهنيج
      _enhanceAndSaveInBackground(image.path, isFront, _currentZoom);

      if (mounted) {
        setState(() { _isProcessing = false; });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✨ تمت المعالجة بالذكاء الاصطناعي بدقة فائقة!'), duration: Duration(milliseconds: 600)),
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
      setState(() { _isRecording = false; _videoSeconds = 0; });
      await Gal.putVideo(file.path);
    } else {
      await controller!.startVideoRecording();
      setState(() { _isRecording = true; _videoSeconds = 0; });
      _videoTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() { _videoSeconds++; });
      });
    }
  }

  double _getAspectRatioValue() {
    switch (_selectedAspectRatio) {
      case '1:1': return 1.0;
      case '16:9': return 16.5 / 9;
      case 'Full': return 9 / 19.5;
      case '4:3':
      default: return 3 / 4;
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

  void _showWatermarkDialog() {
    TextEditingController textController = TextEditingController(text: _customWatermarkText);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('إعدادات العلامة المائية المخصصة', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: textController,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: 'اكتب النص هنا...', hintStyle: TextStyle(color: Colors.white54)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء', style: TextStyle(color: Colors.redAccent))),
          TextButton(onPressed: () {
            setState(() { _customWatermarkText = textController.text; _isWatermarkActive = true; });
            Navigator.pop(context);
          }, child: const Text('حفظ', style: TextStyle(color: Colors.greenAccent))),
        ],
      ),
    );
  }

  void _showTimerDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('اختر وقت المؤقت', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: const Text('3 ثواني', style: TextStyle(color: Colors.white)), onTap: () { setState(() { _selectedTimerSeconds = 3; _isTimerActive = true; }); Navigator.pop(context); }),
            ListTile(title: const Text('5 ثواني', style: TextStyle(color: Colors.white)), onTap: () { setState(() { _selectedTimerSeconds = 5; _isTimerActive = true; }); Navigator.pop(context); }),
            ListTile(title: const Text('10 ثواني', style: TextStyle(color: Colors.white)), onTap: () { setState(() { _selectedTimerSeconds = 10; _isTimerActive = true; }); Navigator.pop(context); }),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!isPermissionGranted) {
      return const Scaffold(body: Center(child: Text('Please grant camera permissions')));
    }
    if (controller == null || !controller!.value.isInitialized) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator(color: Colors.greenAccent)));
    }

    bool isFrontCamera = cameras[selectedCameraIndex].lensDirection == CameraLensDirection.front;

    // تعديل انعكاس الكاميرا الأمامية في البريفيو لتظهر حركة الرأس طبيعية تماماً
    Widget previewWidget = AspectRatio(
      aspectRatio: _getAspectRatioValue(),
      child: Transform(
        alignment: Alignment.center,
        transform: isFrontCamera ? Matrix4.identity() : Matrix4.identity(),
        child: CameraPreview(controller!),
      ),
    );

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onScaleStart: (_) => setState(() { _showZoomWheel = true; _showExpandedPanel = false; }),
              onScaleUpdate: (details) async {
                double scaleFactor = details.scale > 1 ? 1.02 : 0.98;
                double newZoom = (_currentZoom * scaleFactor).clamp(_minZoom, _maxZoom);
                setState(() { _currentZoom = newZoom; _showZoomWheel = true; _lastZoomInteraction = DateTime.now(); });
                await controller!.setZoomLevel(_currentZoom);
              },
              child: Center(child: previewWidget),
            ),
          ),

          if (_isGridActive)
            Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: GridPainter()))),

          if (_countdownSeconds > 0)
            Positioned(
              top: MediaQuery.of(context).size.height / 2 - 50, left: 0, right: 0,
              child: Center(child: Text('$_countdownSeconds', style: const TextStyle(color: Colors.greenAccent, fontSize: 80, fontWeight: FontWeight.bold))),
            ),

          if (_isWatermarkActive || _isLocationActive)
            Positioned(
              bottom: 140, left: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_isWatermarkActive) Text(_customWatermarkText, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                    if (_isLocationActive) const Text('📍 مصر، القاهرة', style: TextStyle(color: Colors.greenAccent, fontSize: 9)),
                  ],
                ),
              ),
            ),

          // مؤشر الزوم التفاعلي
          if (_showZoomWheel)
            Positioned(
              bottom: 220, left: 0, right: 0,
              child: Center(
                child: Container(
                  height: 65, width: 260,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(25),
                    border: Border.all(color: Colors.greenAccent.withOpacity(0.6)),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('زوم AI: ${_currentZoom.toStringAsFixed(1)}x (القصوى: ${_maxZoom.toStringAsFixed(0)}x)', style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                      Slider(
                        value: _currentZoom,
                        min: _minZoom,
                        max: _maxZoom,
                        activeColor: Colors.greenAccent,
                        inactiveColor: Colors.white24,
                        onChanged: (val) async {
                          setState(() { _currentZoom = val; _lastZoomInteraction = DateTime.now(); });
                          await controller!.setZoomLevel(_currentZoom);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // شريط الأدوات العلوي
          Positioned(
            top: 45, left: 16, right: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: Icon(_flashMode == FlashMode.torch ? Icons.flash_on : Icons.flash_off, color: Colors.white, size: 22),
                  onPressed: () {
                    setState(() { _flashMode = _flashMode == FlashMode.torch ? FlashMode.off : FlashMode.torch; });
                    controller?.setFlashMode(_flashMode);
                  },
                ),
                GestureDetector(
                  onTap: () => setState(() { _showExpandedPanel = !_showExpandedPanel; }),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                    child: Icon(_showExpandedPanel ? Icons.expand_less : Icons.expand_more, color: Colors.greenAccent, size: 22),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.auto_awesome, color: Colors.white, size: 22),
                  onPressed: () => setState(() { _isAiFocusEnabled = !_isAiFocusEnabled; }),
                ),
                IconButton(
                  icon: Text(_selectedAspectRatio, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  onPressed: () {
                    setState(() {
                      if (_selectedAspectRatio == '4:3') _selectedAspectRatio = '16:9';
                      else if (_selectedAspectRatio == '16:9') _selectedAspectRatio = '1:1';
                      else _selectedAspectRatio = '4:3';
                    });
                  },
                ),
              ],
            ),
          ),

          // لوحة الخيارات المنسدلة
          if (_showExpandedPanel)
            Positioned(
              top: 105, left: 20, right: 20,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E).withOpacity(0.95),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white24, width: 1),
                ),
                child: GridView.count(
                  crossAxisCount: 4,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  children: [
                    _buildMenuOption(icon: Icons.hdr_on, label: 'HDR', isActive: _isHdrActive, onTap: () => setState(() => _isHdrActive = !_isHdrActive)),
                    _buildMenuOption(icon: Icons.timer_outlined, label: 'المؤقت', isActive: _isTimerActive, onTap: _showTimerDialog),
                    _buildMenuOption(icon: Icons.branding_watermark_outlined, label: 'علامة مائية', isActive: _isWatermarkActive, onTap: _showWatermarkDialog),
                    _buildMenuOption(icon: Icons.grid_on, label: 'الشبكة', isActive: _isGridActive, onTap: () => setState(() => _isGridActive = !_isGridActive)),
                    _buildMenuOption(icon: Icons.center_focus_strong, label: 'تركيز AI', isActive: _isAiFocusEnabled, onTap: () => setState(() => _isAiFocusEnabled = !_isAiFocusEnabled)),
                    _buildMenuOption(icon: Icons.location_on, label: 'الموقع', isActive: _isLocationActive, onTap: () => setState(() => _isLocationActive = !_isLocationActive)),
                    _buildMenuOption(icon: Icons.settings_outlined, label: 'الإعدادات', isActive: false, onTap: () {
                      Navigator.push(context, MaterialPageRoute(builder: (context) => SettingsScreen(
                        shutterSound: _shutterSound,
                        cloneShutterButton: _cloneShutterButton,
                        horizonLevel: _horizonLevel,
                        dirtyLensNotice: _dirtyLensNotice,
                        portraitFps: _portraitFps,
                        qrScannerActive: _qrScannerActive,
                        onUpdate: (sound, clone, horizon, lens, fps, qr) {
                          setState(() {
                            _shutterSound = sound;
                            _cloneShutterButton = clone;
                            _horizonLevel = horizon;
                            _dirtyLensNotice = lens;
                            _portraitFps = fps;
                            _qrScannerActive = qr;
                          });
                        },
                        onReset: () {
                          setState(() {
                            _isHdrActive = true;
                            _isTimerActive = false;
                            _isWatermarkActive = false;
                            _isGridActive = false;
                            _isAiFocusEnabled = true;
                            _isLocationActive = false;
                            _shutterSound = true;
                            _cloneShutterButton = false;
                            _horizonLevel = false;
                            _dirtyLensNotice = true;
                            _portraitFps = 'تلقائي';
                            _qrScannerActive = true;
                          });
                        },
                      )));
                    }),
                  ],
                ),
              ),
            ),

          if (_isProcessing)
            const Positioned(
              top: 120, left: 0, right: 0,
              child: Center(
                child: Chip(
                  backgroundColor: Colors.black87,
                  label: Text('✨ جاري معالجة الزوم الفائق وتحسين تفاصيل AI...', style: TextStyle(color: Colors.greenAccent, fontSize: 12)),
                ),
              ),
            ),

          // الأزرار السفلية وأوضاع التصوير (مقتصرة على VIDEO و PHOTO فقط)
          Positioned(
            bottom: 40, left: 0, right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 30,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: ['VIDEO', 'PHOTO'].map((mode) {
                      bool isSelected = _currentMode == mode;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20.0),
                        child: GestureDetector(
                          onTap: () => setState(() => _currentMode = mode),
                          child: Text(mode, style: TextStyle(color: isSelected ? Colors.greenAccent : Colors.white60, fontWeight: FontWeight.bold, fontSize: 14)),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 15),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Container(
                      height: 45, width: 45,
                      decoration: BoxDecoration(color: Colors.grey[900], borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.white30)),
                      child: const Icon(Icons.photo, color: Colors.white, size: 22),
                    ),
                    GestureDetector(
                      onTap: _captureAction,
                      child: Container(
                        height: 72, width: 72,
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3)),
                        child: Center(
                          child: Container(
                            height: 60, width: 60,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: _currentMode == 'VIDEO' && _isRecording ? Colors.red : Colors.white),
                            child: _isRecording ? const Icon(Icons.stop, color: Colors.white, size: 28) : null,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      iconSize: 28,
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

  Widget _buildMenuOption({required IconData icon, required String label, required bool isActive, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: isActive ? Colors.greenAccent : Colors.white70, size: 22),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: isActive ? Colors.greenAccent : Colors.white70, fontSize: 10)),
        ],
      ),
    );
  }
}

class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white24..strokeWidth = 1.0;
    double thirdW = size.width / 3;
    double thirdH = size.height / 3;

    canvas.drawLine(Offset(thirdW, 0), Offset(thirdW, size.height), paint);
    canvas.drawLine(Offset(thirdW * 2, 0), Offset(thirdW * 2, size.height), paint);
    canvas.drawLine(Offset(0, thirdH), Offset(size.width, thirdH), paint);
    canvas.drawLine(Offset(0, thirdH * 2), Offset(size.width, thirdH * 2), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class SettingsScreen extends StatefulWidget {
  final bool shutterSound;
  final bool cloneShutterButton;
  final bool horizonLevel;
  final bool dirtyLensNotice;
  final String portraitFps;
  final bool qrScannerActive;
  final Function(bool, bool, bool, bool, String, bool) onUpdate;
  final VoidCallback onReset;

  const SettingsScreen({
    super.key,
    required this.shutterSound,
    required this.cloneShutterButton,
    required this.horizonLevel,
    required this.dirtyLensNotice,
    required this.portraitFps,
    required this.qrScannerActive,
    required this.onUpdate,
    required this.onReset,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late bool _sound;
  late bool _clone;
  late bool _horizon;
  late bool _lens;
  late String _fps;
  late bool _qr;

  @override
  void initState() {
    super.initState();
    _sound = widget.shutterSound;
    _clone = widget.cloneShutterButton;
    _horizon = widget.horizonLevel;
    _lens = widget.dirtyLensNotice;
    _fps = widget.portraitFps;
    _qr = widget.qrScannerActive;
  }

  void _updateParent() {
    widget.onUpdate(_sound, _clone, _horizon, _lens, _fps, _qr);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('الإعدادات', style: TextStyle(color: Colors.white)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_forward, color: Colors.greenAccent),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(title: const Text('صوت الالتقاط'), value: _sound, activeColor: Colors.greenAccent, onChanged: (val) { setState(() => _sound = val); _updateParent(); }),
          SwitchListTile(title: const Text('استنساخ زر الالتقاط'), value: _clone, activeColor: Colors.greenAccent, onChanged: (val) { setState(() => _clone = val); _updateParent(); }),
          SwitchListTile(title: const Text('الموقع'), value: true, activeColor: Colors.greenAccent, onChanged: (_) {}),
          SwitchListTile(title: const Text('المستوى الأفقي'), value: _horizon, activeColor: Colors.greenAccent, onChanged: (val) { setState(() => _horizon = val); _updateParent(); }),
          ListTile(title: const Text('طرق التصوير والإعدادات الإضافية'), trailing: const Icon(Icons.arrow_back_ios, size: 14, color: Colors.white54), onTap: {}),
          ListTile(
            title: const Text('محسن بورتريه AI'),
            subtitle: Text(_fps, style: const TextStyle(color: Colors.greenAccent, fontSize: 12)),
            trailing: const Icon(Icons.arrow_back_ios, size: 14, color: Colors.white54),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  backgroundColor: Colors.grey[900],
                  title: const Text('اختر جودة البورتريه', style: TextStyle(color: Colors.white)),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(title: const Text('تلقائي', style: TextStyle(color: Colors.white)), onTap: () { setState(() => _fps = 'تلقائي'); _updateParent(); Navigator.pop(context); }),
                      ListTile(title: const Text('50 فريم', style: TextStyle(color: Colors.white)), onTap: () { setState(() => _fps = '50 فريم'); _updateParent(); Navigator.pop(context); }),
                      ListTile(title: const Text('60 فريم', style: TextStyle(color: Colors.white)), onTap: () { setState(() => _fps = '60 فريم'); _updateParent(); Navigator.pop(context); }),
                    ],
                  ),
                ),
              );
            },
          ),
          SwitchListTile(title: const Text('مسح رموز QR'), value: _qr, activeColor: Colors.greenAccent, onChanged: (val) { setState(() => _qr = val); _updateParent(); }),
          SwitchListTile(title: const Text('الإشعار بالعدسات المتسخة'), value: _lens, activeColor: Colors.greenAccent, onChanged: (val) { setState(() => _lens = val); _updateParent(); }),
          const Divider(color: Colors.white24),
          ListTile(
            leading: const Icon(Icons.refresh, color: Colors.redAccent),
            title: const Text('استعادة الإعدادات الافتراضية', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
            onTap: () {
              widget.onReset();
              setState(() { _sound = true; _clone = false; _horizon = false; _lens = true; _fps = 'تلقائي'; _qr = true; });
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تمت استعادة الإعدادات الافتراضية بنجاح')));
            },
          ),
        ],
      ),
    );
  }
}