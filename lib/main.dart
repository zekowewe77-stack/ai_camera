
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';
import 'package:image/image.dart' as img;
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  List<CameraDescription> available = [];
  try {
    available = await availableCameras();
  } catch (e) {
    debugPrint('Camera discovery failed: $e');
  }

  runApp(CameraApp(cameras: available));
}

class CameraApp extends StatelessWidget {
  const CameraApp({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AI Camera Pro',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.greenAccent,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: Colors.black,
        useMaterial3: true,
      ),
      home: CameraScreen(cameras: cameras),
    );
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.cameras});

  final List<CameraDescription> cameras;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  CameraController? _camera;
  int _cameraIndex = 0;

  String _mode = 'PHOTO';
  String _aspect = '4:3';

  ResolutionPreset _videoPreset = ResolutionPreset.high;
  String _qualityLabel = 'جودة عالية';

  double _zoom = 1;
  double _minZoom = 1;
  double _maxZoom = 1;
  double _scaleStartZoom = 1;

  FlashMode _flash = FlashMode.off;

  bool _permission = false;
  bool _busy = false;
  bool _recording = false;
  bool _grid = false;
  bool _timerOn = false;
  bool _livePhoto = false;
  bool _sound = true;

  int _timerSeconds = 3;
  int _recordSeconds = 0;

  String? _lastPath;
  String? _lastMotionPath;

  Timer? _recordTimer;
  late final AnimationController _flashAnimation;

  bool get _frontCamera =>
      widget.cameras.isNotEmpty &&
      widget.cameras[_cameraIndex].lensDirection ==
          CameraLensDirection.front;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _flashAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );

    _start();
  }

  Future<void> _start() async {
    final cameraPermission = await Permission.camera.request();

    if (!cameraPermission.isGranted) {
      if (mounted) setState(() => _permission = false);
      return;
    }

    // Gal requests the appropriate gallery access for the platform.
    try {
      await Gal.requestAccess();
    } catch (e) {
      debugPrint('Gallery permission: $e');
    }

    // Microphone is requested only when the user starts video recording.
    if (mounted) setState(() => _permission = true);

    if (widget.cameras.isNotEmpty) {
      await _initCamera();
    }
  }

  Future<void> _initCamera() async {
    if (!mounted || widget.cameras.isEmpty) return;

    final old = _camera;
    _camera = null;
    if (mounted) setState(() {});

    if (old != null) {
      try {
        await old.dispose();
      } catch (_) {}
    }

    final controller = CameraController(
      widget.cameras[_cameraIndex],
      _videoPreset,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    _camera = controller;

    try {
      await controller.initialize();

      _minZoom = await controller.getMinZoomLevel();
      _maxZoom = await controller.getMaxZoomLevel();
      _zoom = _minZoom;

      await controller.setZoomLevel(_zoom);

      try {
        await controller.setFocusMode(FocusMode.auto);
      } catch (_) {}

      try {
        await controller.setExposureMode(ExposureMode.auto);
      } catch (_) {}

      try {
        await controller.setFlashMode(_flash);
      } catch (_) {}
    } catch (e) {
      debugPrint('Camera initialization failed: $e');
      if (identical(_camera, controller)) _camera = null;
      try {
        await controller.dispose();
      } catch (_) {}
    }

    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _recordTimer?.cancel();

      final old = _camera;
      _camera = null;

      if (old != null) {
        old.dispose();
      }

      if (mounted) setState(() => _recording = false);
    } else if (state == AppLifecycleState.resumed &&
        _permission &&
        widget.cameras.isNotEmpty) {
      _initCamera();
    }
  }

  Future<void> _switchCamera() async {
    if (widget.cameras.length < 2 || _recording || _busy) return;

    setState(() => _busy = true);
    _cameraIndex = (_cameraIndex + 1) % widget.cameras.length;
    await _initCamera();

    if (mounted) setState(() => _busy = false);
  }

  Future<void> _capture() async {
    final camera = _camera;

    if (camera == null ||
        !camera.value.isInitialized ||
        _busy ||
        _recording) {
      return;
    }

    if (_mode == 'VIDEO') {
      await _toggleRecording();
      return;
    }

    setState(() => _busy = true);

    try {
      if (_timerOn) {
        for (int i = _timerSeconds; i > 0; i--) {
          if (!mounted) return;
          setState(() => _recordSeconds = i);
          await Future.delayed(const Duration(seconds: 1));
        }
        if (mounted) setState(() => _recordSeconds = 0);
      }

      if (_sound) {
        HapticFeedback.lightImpact();
      }

      _flashAnimation.forward(from: 0).then((_) {
        if (mounted) _flashAnimation.reverse();
      });

      // Motion photo: capture a short video clip, then the still image.
      // This is a custom motion-photo pair, not Apple's native Live Photo format.
      String? motionPath;
      if (_livePhoto && _mode != 'PORTRAIT') {
        motionPath = await _captureMotionClip(camera);
      }

      final shot = await camera.takePicture();
      String finalPath = shot.path;

      if (_mode == 'PORTRAIT') {
        finalPath = await _makePortrait(shot.path);
      }

      // Keep the original JPEG bytes for normal/night photos.
      // Portrait processing creates a separate processed file.
      await Gal.putImage(finalPath);

      if (motionPath != null) {
        try {
          await Gal.putVideo(motionPath);
        } catch (e) {
          debugPrint('Could not save motion clip: $e');
        }
      }

      if (mounted) {
        setState(() {
          _lastPath = finalPath;
          _lastMotionPath = motionPath;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 2),
            content: Text(
              motionPath != null
                  ? 'تم حفظ الصورة ومقطع الحركة'
                  : _mode == 'PORTRAIT'
                      ? 'تم حفظ صورة البورتريه'
                      : 'تم حفظ الصورة',
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Capture failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر التصوير. جرّب مرة أخرى.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _recordSeconds = 0;
        });
      }
    }
  }

  Future<String?> _captureMotionClip(CameraController camera) async {
    try {
      if (!camera.value.isInitialized ||
          camera.value.isRecordingVideo) {
        return null;
      }

      await camera.startVideoRecording();
      await Future.delayed(const Duration(milliseconds: 1500));

      if (!camera.value.isRecordingVideo) return null;

      final clip = await camera.stopVideoRecording();
      return clip.path;
    } catch (e) {
      debugPrint('Motion clip failed: $e');
      // If a device cannot record this short clip, still take the photo.
      try {
        if (camera.value.isRecordingVideo) {
          await camera.stopVideoRecording();
        }
      } catch (_) {}
      return null;
    }
  }

  Future<String> _makePortrait(String originalPath) async {
    final segmenter = SelfieSegmenter(
      mode: SegmenterMode.single,
      enableRawSizeMask: true,
    );

    try {
      final input = InputImage.fromFilePath(originalPath);
      final mask = await segmenter.processImage(input);

      if (mask == null ||
          mask.width <= 0 ||
          mask.height <= 0 ||
          mask.confidences.isEmpty) {
        return originalPath;
      }

      final originalBytes = await File(originalPath).readAsBytes();

      final result = await compute(
        _portraitBytes,
        <String, dynamic>{
          'bytes': originalBytes,
          'width': mask.width,
          'height': mask.height,
          'mask': mask.confidences,
        },
      );

      final outputPath = originalPath.replaceFirst(
        RegExp(r'\.jpe?g$', caseSensitive: false),
        '_portrait.jpg',
      );

      await File(outputPath).writeAsBytes(result, flush: true);
      return outputPath;
    } catch (e) {
      debugPrint('Portrait processing failed: $e');
      return originalPath;
    } finally {
      await segmenter.close();
    }
  }

  Future<void> _toggleRecording() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized || _busy) return;

    if (_recording) {
      try {
        _recordTimer?.cancel();
        final video = await camera.stopVideoRecording();

        if (mounted) {
          setState(() {
            _recording = false;
            _recordSeconds = 0;
            _lastPath = video.path;
          });
        }

        await Gal.putVideo(video.path);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم حفظ الفيديو في المعرض')),
          );
        }
      } catch (e) {
        debugPrint('Stop recording failed: $e');
        if (mounted) {
          setState(() => _recording = false);
        }
      }
      return;
    }

    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('اسمح باستخدام الميكروفون لتسجيل صوت الفيديو'),
          ),
        );
      }
      return;
    }

    try {
      await camera.startVideoRecording();

      if (mounted) {
        setState(() {
          _recording = true;
          _recordSeconds = 0;
        });
      }

      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordSeconds++);
      });
    } catch (e) {
      debugPrint('Start recording failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر بدء الفيديو بهذه الإعدادات على الجهاز'),
          ),
        );
      }
    }
  }

  Future<void> _changeQuality(String label) async {
    if (_recording || _busy) return;

    setState(() {
      _busy = true;
      _qualityLabel = label;
      _videoPreset = switch (label) {
        'جودة اقتصادية' => ResolutionPreset.medium,
        'أعلى جودة متاحة' => ResolutionPreset.max,
        _ => ResolutionPreset.high,
      };
    });

    await _initCamera();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _toggleFlash() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;

    final next = _flash == FlashMode.off
        ? FlashMode.torch
        : FlashMode.off;

    try {
      await camera.setFlashMode(next);
      _flash = next;
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Flash unavailable: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الفلاش غير متاح في الوضع الحالي')),
        );
      }
    }
  }

  Future<void> _openLast() async {
    final path = _lastPath;

    if (path == null || !await File(path).exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا توجد لقطة حديثة')),
        );
      }
      return;
    }

    await OpenFilex.open(path);
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF171717),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'إعدادات الكاميرا',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
                ),
              ),
              SwitchListTile(
                title: const Text('شبكة تقسيم الصورة'),
                value: _grid,
                onChanged: (value) {
                  setState(() => _grid = value);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('مؤقت 3 ثوانٍ'),
                value: _timerOn,
                onChanged: (value) {
                  setState(() => _timerOn = value);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('Live Photo (صورة + حركة قصيرة)'),
                subtitle: const Text(
                  'يحفظ صورة ومقطع فيديو منفصلين',
                ),
                value: _livePhoto,
                onChanged: (value) {
                  setState(() => _livePhoto = value);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('اهتزاز عند التصوير'),
                value: _sound,
                onChanged: (value) {
                  setState(() => _sound = value);
                  setSheet(() {});
                },
              ),
              ListTile(
                leading: const Icon(Icons.close),
                title: const Text('إغلاق'),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double get _aspectValue => switch (_aspect) {
        '1:1' => 1,
        '16:9' => 9 / 16,
        'Full' => 9 / 19.5,
        _ => 3 / 4,
      };

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordTimer?.cancel();
    _flashAnimation.dispose();
    _camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;

    if (!_permission) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.camera_alt_outlined, size: 54),
              const SizedBox(height: 12),
              const Text('يلزم السماح باستخدام الكاميرا'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _start,
                child: const Text('طلب الصلاحية مرة أخرى'),
              ),
              TextButton(
                onPressed: openAppSettings,
                child: const Text('فتح إعدادات التطبيق'),
              ),
            ],
          ),
        ),
      );
    }

    if (camera == null || !camera.value.isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: GestureDetector(
              onScaleStart: (_) => _scaleStartZoom = _zoom,
              onScaleUpdate: (details) async {
                final next = (_scaleStartZoom * details.scale)
                    .clamp(_minZoom, _maxZoom)
                    .toDouble();

                setState(() => _zoom = next);
                try {
                  await camera.setZoomLevel(next);
                } catch (_) {}
              },
              child: AspectRatio(
                aspectRatio: _aspectValue,
                child: CameraPreview(camera),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _flashAnimation,
                builder: (_, __) => Opacity(
                  opacity: _flashAnimation.value,
                  child: const ColoredBox(color: Colors.white),
                ),
              ),
            ),
          ),
          if (_grid)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _GridPainter()),
              ),
            ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x55000000),
                child: Center(
                  child: CircularProgressIndicator(
                    color: Colors.greenAccent,
                  ),
                ),
              ),
            ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        onPressed: _toggleFlash,
                        icon: Icon(
                          _flash == FlashMode.off
                              ? Icons.flash_off
                              : Icons.flash_on,
                        ),
                      ),
                      Text(
                        '${_zoom.toStringAsFixed(1)}×',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        onPressed: () {
                          setState(() {
                            _aspect = switch (_aspect) {
                              '4:3' => '16:9',
                              '16:9' => 'Full',
                              'Full' => '1:1',
                              _ => '4:3',
                            };
                          });
                        },
                        icon: Text(
                          _aspect,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(
                        onPressed: _showSettings,
                        icon: const Icon(Icons.tune),
                      ),
                    ],
                  ),
                ),
                if (_recording || _recordSeconds > 0)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _recording
                          ? '● تسجيل ${_recordSeconds}s'
                          : '$_recordSeconds',
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ),
                const Spacer(),
                if (_mode == 'VIDEO')
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 6,
                      children: [
                        _qualityChip('جودة اقتصادية'),
                        _qualityChip('جودة عالية'),
                        _qualityChip('أعلى جودة متاحة'),
                      ],
                    ),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _modeButton('NIGHT', 'ليل'),
                    _modeButton('PORTRAIT', 'بورتريه'),
                    _modeButton('PHOTO', 'صورة'),
                    _modeButton('VIDEO', 'فيديو'),
                  ],
                ),
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      GestureDetector(
                        onTap: _openLast,
                        child: Container(
                          width: 52,
                          height: 52,
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.white54),
                            color: Colors.black54,
                          ),
                          child: _lastPath != null &&
                                  File(_lastPath!).existsSync()
                              ? Image.file(
                                  File(_lastPath!),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) =>
                                      const Icon(Icons.photo),
                                )
                              : const Icon(Icons.photo_library_outlined),
                        ),
                      ),
                      GestureDetector(
                        onTap: _capture,
                        child: Container(
                          width: 78,
                          height: 78,
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                          ),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 100),
                            decoration: BoxDecoration(
                              color: _mode == 'VIDEO'
                                  ? Colors.redAccent
                                  : Colors.white,
                              shape: _mode == 'VIDEO' && _recording
                                  ? BoxShape.rectangle
                                  : BoxShape.circle,
                              borderRadius: _mode == 'VIDEO' && _recording
                                  ? BorderRadius.circular(8)
                                  : null,
                            ),
                            child: _recording
                                ? const Icon(Icons.stop, color: Colors.white)
                                : null,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _switchCamera,
                        icon: const Icon(Icons.cameraswitch, size: 32),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeButton(String key, String label) {
    final selected = _mode == key;
    final selectedColor =
        key == 'VIDEO' ? Colors.redAccent : Colors.greenAccent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: TextButton(
        onPressed: () {
          if (!_recording && !_busy) setState(() => _mode = key);
        },
        style: TextButton.styleFrom(
          foregroundColor: selected ? selectedColor : Colors.white70,
          backgroundColor:
              selected ? selectedColor.withOpacity(0.16) : Colors.transparent,
        ),
        child: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _qualityChip(String label) {
    final selected = _qualityLabel == label;

    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      selected: selected,
      onSelected: (_) => _changeQuality(label),
    );
  }
}

Uint8List _portraitBytes(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final maskWidth = args['width'] as int;
  final maskHeight = args['height'] as int;
  final mask = (args['mask'] as List).cast<double>();

  final decoded = img.decodeImage(bytes);
  if (decoded == null ||
      maskWidth <= 0 ||
      maskHeight <= 0 ||
      mask.isEmpty) {
    return bytes;
  }

  final foreground = img.bakeOrientation(decoded);
  final background = img.gaussianBlur(foreground, radius: 12);
  final output = img.Image(
    width: foreground.width,
    height: foreground.height,
  );

  for (int y = 0; y < foreground.height; y++) {
    final my = ((y * maskHeight) / foreground.height)
        .floor()
        .clamp(0, maskHeight - 1);

    for (int x = 0; x < foreground.width; x++) {
      final mx = ((x * maskWidth) / foreground.width)
          .floor()
          .clamp(0, maskWidth - 1);

      final index = my * maskWidth + mx;
      final confidence =
          (index < mask.length ? mask[index] : 0.0).clamp(0.0, 1.0);

      // Soft transition reduces harsh cutout edges.
      final alpha = ((confidence - 0.20) / 0.60).clamp(0.0, 1.0);

      final fg = foreground.getPixel(x, y);
      final bg = background.getPixel(x, y);

      output.setPixelRgba(
        x,
        y,
        (fg.r * alpha + bg.r * (1 - alpha)).round(),
        (fg.g * alpha + bg.g * (1 - alpha)).round(),
        (fg.b * alpha + bg.b * (1 - alpha)).round(),
        255,
      );
    }
  }

  return Uint8List.fromList(img.encodeJpg(output, quality: 96));
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white30
      ..strokeWidth = 1;

    canvas.drawLine(
      Offset(size.width / 3, 0),
      Offset(size.width / 3, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(size.width * 2 / 3, 0),
      Offset(size.width * 2 / 3, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height / 3),
      Offset(size.width, size.height / 3),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height * 2 / 3),
      Offset(size.width, size.height * 2 / 3),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
