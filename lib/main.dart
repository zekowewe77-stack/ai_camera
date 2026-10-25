
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
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00D9FF),
          brightness: Brightness.dark,
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
  bool _grid = false;
  bool _sound = true;
  bool _mirrorSelfie = false;
  bool _livePhoto = false;

  String _status = 'جاري تشغيل الكاميرا';

  bool get _isFrontCamera =>
      _cameras.isNotEmpty &&
      _cameras[_cameraIndex].lensDirection ==
          CameraLensDirection.front;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      final permission = await Permission.camera.request();

      if (!permission.isGranted) {
        _setStatus('يجب السماح باستخدام الكاميرا');
        return;
      }

      _cameras = await availableCameras();

      if (_cameras.isEmpty) {
        _setStatus('لم يتم العثور على كاميرا');
        return;
      }

      final backIndex = _cameras.indexWhere(
        (camera) =>
            camera.lensDirection == CameraLensDirection.back,
      );

      _cameraIndex = backIndex >= 0 ? backIndex : 0;

      await _createController();
    } catch (error) {
      _setStatus('خطأ في تشغيل الكاميرا: $error');
    }
  }

  Future<void> _createController() async {
    if (_cameras.isEmpty) return;

    final previous = _controller;
    _controller = null;

    if (previous != null) {
      await previous.dispose();
    }

    final controller = CameraController(
      _cameras[_cameraIndex],
      _quality,
      enableAudio: true,
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
        _status = 'الكاميرا جاهزة';
      });
    } catch (error) {
      await controller.dispose();
      _setStatus('تعذر تهيئة الكاميرا: $error');
    }
  }

  void _setStatus(String message) {
    if (!mounted) return;
    setState(() => _status = message);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      final old = _controller;
      _controller = null;
      old?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      if (!_recording && !_busy && _cameras.isNotEmpty) {
        _createController();
      }
    }
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
      final bytes = await File(shot.path).readAsBytes();
      final decoded = img.decodeImage(bytes);

      if (decoded == null) {
        await Gal.putImage(shot.path);
      } else {
        var corrected = img.bakeOrientation(decoded);

        if (_isFrontCamera && _mirrorSelfie) {
          corrected = img.flipHorizontal(corrected);
        }

        final output = img.encodeJpg(corrected, quality: 95);
        final tempFile = File(
          '${Directory.systemTemp.path}/ai_camera_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );

        await tempFile.writeAsBytes(output, flush: true);

        try {
          await Gal.putImage(tempFile.path);
        } finally {
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        }
      }

      await _shutterFeedback();
      _setStatus('تم حفظ الصورة في المعرض');
    } catch (error) {
      _setStatus('فشل التقاط الصورة: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shutterFeedback() async {
    if (_sound) {
      await SystemSound.play(SystemSoundType.click);
    }
    await HapticFeedback.lightImpact();
  }

  Future<void> _startVideo() async {
    final controller = _controller;

    if (controller == null ||
        !controller.value.isInitialized ||
        _busy ||
        _recording) {
      return;
    }

    final microphonePermission =
        await Permission.microphone.request();

    if (!microphonePermission.isGranted) {
      _setStatus('اسمح باستخدام الميكروفون لتسجيل الصوت');
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
    } catch (error) {
      _setStatus('فشل بدء التسجيل: $error');
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
    } catch (error) {
      if (mounted) {
        setState(() {
          _recording = false;
          _status = 'فشل حفظ الفيديو: $error';
        });
      }
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _busy || _recording) return;

    setState(() => _busy = true);

    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _createController();

    if (mounted) setState(() => _busy = false);
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null || _busy) return;

    final next = _flash == FlashMode.off
        ? FlashMode.auto
        : _flash == FlashMode.auto
            ? FlashMode.always
            : FlashMode.off;

    try {
      await controller.setFlashMode(next);
      if (mounted) setState(() => _flash = next);
    } catch (error) {
      _setStatus('الفلاش غير متاح: $error');
    }
  }

  Future<void> _changeQuality() async {
    if (_busy || _recording) return;

    final presets = <ResolutionPreset>[
      ResolutionPreset.medium,
      ResolutionPreset.high,
      ResolutionPreset.veryHigh,
      ResolutionPreset.max,
    ];

    final index = presets.indexOf(_quality);
    _quality = presets[(index + 1) % presets.length];

    setState(() => _busy = true);
    await _createController();

    if (mounted) setState(() => _busy = false);
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF202020),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, updateSheet) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'إعدادات الكاميرا',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('صوت التصوير'),
                    value: _sound,
                    onChanged: (value) {
                      setState(() => _sound = value);
                      updateSheet(() {});
                    },
                  ),
                  SwitchListTile(
                    title: const Text('عكس السيلفي عند الحفظ'),
                    value: _mirrorSelfie,
                    onChanged: (value) {
                      setState(() => _mirrorSelfie = value);
                      updateSheet(() {});
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
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
            _buildTopBar(),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (controller != null &&
                      controller.value.isInitialized)
                    CameraPreview(controller)
                  else
                    const Center(
                      child: CircularProgressIndicator(),
                    ),
                  if (_grid)
                    const IgnorePointer(
                      child: CustomPaint(
                        painter: _GridPainter(),
                      ),
                    ),
                  if (_busy)
                    const Center(
                      child: CircularProgressIndicator(),
                    ),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            blurRadius: 8,
                            color: Colors.black,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _buildModes(),
            _buildControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        IconButton(
          onPressed: _toggleFlash,
          icon: Icon(
            _flash == FlashMode.off
                ? Icons.flash_off
                : Icons.flash_on,
          ),
        ),
        IconButton(
          onPressed: () => setState(() => _grid = !_grid),
          icon: Icon(
            Icons.grid_on,
            color: _grid
                ? const Color(0xFF00D9FF)
                : Colors.white,
          ),
        ),
        if (_mode != CameraMode.video)
          Row(
            children: [
              const Text('Live'),
              Switch(
                value: _livePhoto,
                onChanged: (value) {
                  setState(() => _livePhoto = value);
                  _setStatus(
                    value
                        ? 'Live Photo غير مكتمل في هذه النسخة'
                        : 'تم إيقاف Live Photo',
                  );
                },
              ),
            ],
          ),
        IconButton(
          onPressed: _changeQuality,
          icon: const Icon(Icons.hd),
        ),
        IconButton(
          onPressed: _showSettings,
          icon: const Icon(Icons.settings),
        ),
      ],
    );
  }

  Widget _buildModes() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
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
    return TextButton(
      onPressed: _recording
          ? null
          : () => setState(() => _mode = mode),
      child: Text(
        label,
        style: TextStyle(
          color: _mode == mode
              ? const Color(0xFF00D9FF)
              : Colors.white,
          fontWeight: _mode == mode
              ? FontWeight.bold
              : FontWeight.normal,
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            onPressed: _switchCamera,
            icon: const Icon(
              Icons.flip_camera_android,
              size: 30,
            ),
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
                border: Border.all(
                  color: Colors.white,
                  width: 4,
                ),
              ),
              child: Center(
                child: Container(
                  width: _recording ? 28 : 60,
                  height: _recording ? 28 : 60,
                  decoration: BoxDecoration(
                    color: _recording ||
                            _mode == CameraMode.video
                        ? Colors.red
                        : Colors.white,
                    shape: _recording
                        ? BoxShape.rectangle
                        : BoxShape.circle,
                    borderRadius: _recording
                        ? BorderRadius.circular(5)
                        : null,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: () {
              setState(() => _mirrorSelfie = !_mirrorSelfie);
            },
            icon: Icon(
              Icons.flip,
              size: 30,
              color: _mirrorSelfie
                  ? const Color(0xFF00D9FF)
                  : Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  const _GridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white54
      ..strokeWidth = 0.7;

    for (int i = 1; i < 3; i++) {
      final x = size.width * i / 3;
      final y = size.height * i / 3;

      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        paint,
      );

      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
