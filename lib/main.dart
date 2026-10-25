
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CameraApp());
}

class CameraApp extends StatelessWidget {
  const CameraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Camera Pro 2027',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00D9FF),
          secondary: Color(0xFF00D9FF),
        ),
      ),
      home: const CameraScreen(),
    );
  }
}

enum CameraMode { photo, portrait, video }

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;

  CameraMode _mode = CameraMode.photo;
  FlashMode _flash = FlashMode.off;
  ResolutionPreset _quality = ResolutionPreset.high;

  bool _busy = false;
  bool _recording = false;
  bool _livePhoto = false;
  bool _grid = false;
  bool _mirrorSavedSelfies = false;
  bool _sound = true;
  String _status = 'جاري تشغيل الكاميرا...';

  bool get _frontCamera =>
      _cameras.isNotEmpty &&
      _cameras[_cameraIndex].lensDirection == CameraLensDirection.front;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameraPermission = await Permission.camera.request();
      if (!cameraPermission.isGranted) {
        if (mounted) setState(() => _status = 'اسمح للتطبيق باستخدام الكاميرا');
        return;
      }

      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) setState(() => _status = 'لم يتم العثور على كاميرا');
        return;
      }

      _cameraIndex = _cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      if (_cameraIndex < 0) _cameraIndex = 0;

      await _openController();
    } catch (e) {
      if (mounted) setState(() => _status = 'تعذر تشغيل الكاميرا: $e');
    }
  }

  Future<void> _openController() async {
    final old = _controller;
    _controller = null;
    if (old != null) {
      await old.dispose();
    }

    final controller = CameraController(
      _cameras[_cameraIndex],
      _quality,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller.initialize();
      await controller.setFlashMode(_flash);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _status = 'جاهز للتصوير';
      });
    } catch (e) {
      await controller.dispose();
      if (mounted) setState(() => _status = 'خطأ في الكاميرا: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _controller = null;
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _openController();
    }
  }

  Future<void> _shutterFeedback() async {
    if (_sound) {
      await SystemSound.play(SystemSoundType.click);
    }
    await HapticFeedback.lightImpact();
  }

  Future<void> _takePhoto() async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _busy ||
        _recording) {
      return;
    }

    setState(() {
      _busy = true;
      _status = 'جاري التقاط الصورة...';
    });

    try {
      final shot = await controller.takePicture();
      await _shutterFeedback();

      final bytes = await File(shot.path).readAsBytes();
      final decoded = img.decodeImage(bytes);

      if (decoded == null) {
        await Gal.putImage(shot.path);
      } else {
        var output = img.bakeOrientation(decoded);

        // الكاميرا الأمامية غالبًا تحفظ الصورة غير معكوسة.
        // فعّل هذا الخيار فقط إذا أردت حفظ السيلفي كما يظهر في المعاينة.
        if (_frontCamera && _mirrorSavedSelfies) {
          output = img.flipHorizontal(output);
        }

        final corrected = img.encodeJpg(output, quality: 98);
        final file = File(
          '${Directory.systemTemp.path}/ai_camera_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        await file.writeAsBytes(corrected, flush: true);
        await Gal.putImage(file.path);
        await file.delete();
      }

      if (_livePhoto) {
        if (mounted) {
          setState(() => _status =
              'تم حفظ الصورة. Live Photo يحتاج تسجيل مقطع منفصل.');
        }
      } else if (mounted) {
        setState(() => _status = 'تم حفظ الصورة في المعرض');
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'فشل التصوير: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startVideo() async {
    final controller = _controller;
    if (controller == null || _busy || _recording) return;

    final permission = await Permission.microphone.request();
    if (!permission.isGranted) {
      if (mounted) {
        setState(() => _status = 'اسمح باستخدام الميكروفون لتسجيل الصوت');
      }
      return;
    }

    try {
      await controller.startVideoRecording();
      if (mounted) {
        setState(() {
          _recording = true;
          _status = 'جاري تسجيل الفيديو...';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'فشل بدء الفيديو: $e');
    }
  }

  Future<void> _stopVideo() async {
    final controller = _controller;
    if (controller == null || !_recording) return;

    try {
      final video = await controller.stopVideoRecording();
      await Gal.putVideo(video.path);
      if (mounted) {
        setState(() {
          _recording = false;
          _status = 'تم حفظ الفيديو في المعرض';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _recording = false;
          _status = 'فشل حفظ الفيديو: $e';
        });
      }
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _busy || _recording) return;
    setState(() => _busy = true);
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _openController();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null) return;

    final next = _flash == FlashMode.off
        ? FlashMode.auto
        : _flash == FlashMode.auto
            ? FlashMode.always
            : FlashMode.off;

    try {
      await controller.setFlashMode(next);
      if (mounted) setState(() => _flash = next);
    } catch (_) {
      if (mounted) setState(() => _status = 'الفلاش غير متاح في هذا الوضع');
    }
  }

  Future<void> _changeQuality() async {
    final options = <ResolutionPreset>[
      ResolutionPreset.medium,
      ResolutionPreset.high,
      ResolutionPreset.veryHigh,
      ResolutionPreset.max,
    ];

    final current = options.indexOf(_quality);
    final next = options[(current + 1) % options.length];

    setState(() {
      _quality = next;
      _busy = true;
    });
    await _openController();
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _topBar(),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (controller != null && controller.value.isInitialized)
                    ClipRect(
                      child: CameraPreview(controller),
                    )
                  else
                    const Center(child: CircularProgressIndicator()),

                  if (_grid) const _GridOverlay(),

                  if (_busy)
                    const Center(child: CircularProgressIndicator()),

                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        shadows: [Shadow(blurRadius: 8, color: Colors.black)],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _modeSelector(),
            _bottomControls(),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          IconButton(
            tooltip: 'الفلاش',
            onPressed: _toggleFlash,
            icon: Icon(
              _flash == FlashMode.off ? Icons.flash_off : Icons.flash_on,
              color: Colors.white,
            ),
          ),
          IconButton(
            tooltip: 'الشبكة',
            onPressed: () => setState(() => _grid = !_grid),
            icon: Icon(
              Icons.grid_on,
              color: _grid ? const Color(0xFF00D9FF) : Colors.white,
            ),
          ),
          if (_mode != CameraMode.video)
            Row(
              children: [
                const Text('Live', style: TextStyle(fontSize: 12)),
                Switch(
                  value: _livePhoto,
                  onChanged: (v) => setState(() => _livePhoto = v),
                ),
              ],
            ),
          IconButton(
            tooltip: 'جودة الكاميرا',
            onPressed: _changeQuality,
            icon: const Icon(Icons.hd, color: Colors.white),
          ),
          IconButton(
            tooltip: 'الإعدادات',
            onPressed: _showSettings,
            icon: const Icon(Icons.settings, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _modeSelector() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _modeButton('بورتريه', CameraMode.portrait),
          _modeButton('صورة', CameraMode.photo),
          _modeButton('فيديو', CameraMode.video),
        ],
      ),
    );
  }

  Widget _modeButton(String label, CameraMode mode) {
    final selected = _mode == mode;
    return TextButton(
      onPressed: _recording ? null : () => setState(() => _mode = mode),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? const Color(0xFF00D9FF) : Colors.white,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }

  Widget _bottomControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            tooltip: 'تبديل الكاميرا',
            onPressed: _switchCamera,
            icon: const Icon(Icons.flip_camera_android, size: 30),
          ),
          GestureDetector(
            onTap: _mode == CameraMode.video
                ? (_recording ? _stopVideo : _startVideo)
                : _takePhoto,
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 4),
              ),
              child: Center(
                child: Container(
                  width: _recording ? 30 : 60,
                  height: _recording ? 30 : 60,
                  decoration: BoxDecoration(
                    color: _recording
                        ? Colors.red
                        : _mode == CameraMode.video
                            ? Colors.red
                            : Colors.white,
                    shape: _recording ? BoxShape.rectangle : BoxShape.circle,
                    borderRadius:
                        _recording ? BorderRadius.circular(6) : null,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'عكس السيلفي المحفوظ',
            onPressed: () => setState(
              () => _mirrorSavedSelfies = !_mirrorSavedSelfies,
            ),
            icon: Icon(
              Icons.flip,
              color: _mirrorSavedSelfies
                  ? const Color(0xFF00D9FF)
                  : Colors.white,
              size: 30,
            ),
          ),
        ],
      ),
    );
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF202020),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'إعدادات الكاميرا',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                SwitchListTile(
                  title: const Text('صوت التقاط الصورة'),
                  value: _sound,
                  onChanged: (value) {
                    setState(() => _sound = value);
                    setSheetState(() {});
                  },
                ),
                SwitchListTile(
                  title: const Text('حفظ السيلفي معكوسًا مثل المعاينة'),
                  value: _mirrorSavedSelfies,
                  onChanged: (value) {
                    setState(() => _mirrorSavedSelfies = value);
                    setSheetState(() {});
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GridOverlay extends StatelessWidget {
  const _GridOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(painter: _GridPainter()),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white54
      ..strokeWidth = 0.7;

    for (var i = 1; i < 3; i++) {
      final x = size.width * i / 3;
      final y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
