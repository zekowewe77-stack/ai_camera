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

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('$e');
  }

  runApp(const CameraApp());
}

class CameraApp extends StatelessWidget {
  const CameraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'كاميرا AI Pro',
      theme: ThemeData.dark(useMaterial3: true),
      home: const CameraScreen(),
    );
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  CameraController? _camera;

  int _cameraIndex = 0;

  String _mode = 'PHOTO';
  String _aspect = '4:3';
  String _style = 'AI'; // AI, VIVID, WARM, COOL, BW

  String _qualityLabel = '1080p • 30 إطار';
  ResolutionPreset _videoPreset = ResolutionPreset.veryHigh;

  final int _fps = 30;

  double _zoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _scaleStartZoom = 1.0;

  double _exposure = 0.0;
  double _minExposure = -2.0;
  double _maxExposure = 2.0;

  Offset? _focusPoint;
  Timer? _focusTimer;

  FlashMode _flash = FlashMode.off;

  bool _permission = false;
  bool _busy = false;
  bool _recording = false;

  // الميزات الاحترافية
  bool _livePhoto = false;
  bool _liveCapturing = false;
  bool _grid = false;
  bool _hdr = true;
  bool _sound = true;
  bool _timerOn = false;
  bool _mirrorFront = true;
  bool _showStyles = false;

  final int _timerSeconds = 3;
  int _recordSeconds = 0;

  String? _lastPath;
  String? _lastThumbPath;
  bool _lastIsVideo = false;

  Timer? _recordTimer;
  late final AnimationController _flashAnimation;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _flashAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 110),
    );

    _start();
  }

  Future<void> _start() async {
    await Permission.camera.request();
    await Permission.microphone.request();
    await Gal.requestAccess();

    if (!await Permission.camera.isGranted) return;

    if (mounted) {
      setState(() => _permission = true);
    }

    if (cameras.isNotEmpty) {
      await _initCamera();
    }
  }

  Future<void> _initCamera() async {
    if (cameras.isEmpty || !mounted) return;

    final old = _camera;
    _camera = null;
    if (mounted) setState(() {});

    if (old != null) {
      try {
        await old.dispose();
      } catch (_) {}
    }

    CameraController camera = CameraController(
      cameras[_cameraIndex],
      _videoPreset,
      enableAudio: true,
      fps: _fps,
      videoBitrate:
          _videoPreset == ResolutionPreset.max ? 20000000 : 12000000,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await camera.initialize();
    } catch (_) {
      // حماية تلقائية: إذا لم يدعم الهاتف الجودة العالية على هذه العدسة يفتح بأعلى جودة متاحة دون انهيار
      try {
        await camera.dispose();
      } catch (_) {}

      camera = CameraController(
        cameras[_cameraIndex],
        ResolutionPreset.high,
        enableAudio: true,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      try {
        await camera.initialize();
      } catch (e) {
        debugPrint('Camera fallback error: $e');
        return;
      }
    }

    _camera = camera;

    try {
      _minZoom = await camera.getMinZoomLevel();
      _maxZoom = await camera.getMaxZoomLevel();
      _zoom = _minZoom;
      await camera.setZoomLevel(_zoom);
    } catch (_) {}

    try {
      _minExposure = await camera.getMinExposureOffset();
      _maxExposure = await camera.getMaxExposureOffset();
      _exposure = 0.0;
    } catch (_) {}

    try {
      await camera.setFocusMode(FocusMode.auto);
    } catch (_) {}

    try {
      await camera.setExposureMode(ExposureMode.auto);
    } catch (_) {}

    try {
      await camera.setFlashMode(_flash);
    } catch (_) {
      _flash = FlashMode.off;
    }

    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      final old = _camera;
      _camera = null;
      old?.dispose();
    } else if (state == AppLifecycleState.resumed &&
        _permission &&
        cameras.isNotEmpty) {
      _initCamera();
    }
  }

  Future<void> _switchCamera() async {
    if (cameras.length < 2 || _recording || _busy) return;
    HapticFeedback.selectionClick();
    _cameraIndex = (_cameraIndex + 1) % cameras.length;
    await _initCamera();
  }

  Future<void> _setZoom(double value) async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;

    final next = value.clamp(_minZoom, _maxZoom);
    setState(() => _zoom = next);

    try {
      await camera.setZoomLevel(next);
    } catch (_) {}
  }

  Future<void> _setExposure(double value) async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;

    final next = value.clamp(_minExposure, _maxExposure);
    setState(() => _exposure = next);

    try {
      await camera.setExposureOffset(next);
    } catch (_) {}
  }

  Future<void> _onTapFocus(
    TapUpDetails details,
    BoxConstraints constraints,
  ) async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;

    final nx =
        (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
    final ny =
        (details.localPosition.dy / constraints.maxHeight).clamp(0.0, 1.0);

    setState(() => _focusPoint = details.localPosition);

    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _focusPoint = null);
      }
    });

    try {
      await camera.setFocusPoint(Offset(nx, ny));
      await camera.setFocusMode(FocusMode.auto);
    } catch (_) {}

    try {
      await camera.setExposurePoint(Offset(nx, ny));
    } catch (_) {}
  }

  Future<void> _capture() async {
    final camera = _camera;

    if (camera == null || !camera.value.isInitialized || _busy) {
      return;
    }

    if (_mode == 'VIDEO') {
      await _toggleRecording();
      return;
    }

    if (_timerOn) {
      for (int i = _timerSeconds; i > 0; i--) {
        if (!mounted) return;
        setState(() => _recordSeconds = i);
        if (_sound) SystemSound.play(SystemSoundType.click);
        await Future.delayed(const Duration(seconds: 1));
      }

      if (mounted) {
        setState(() => _recordSeconds = 0);
      }
    }

    setState(() => _busy = true);

    try {
      if (_sound) {
        SystemSound.play(SystemSoundType.click);
        HapticFeedback.mediumImpact();
      }

      _flashAnimation.forward(from: 0).then((_) {
        if (mounted) {
          _flashAnimation.reverse();
        }
      });

      final shot = await camera.takePicture();
      final bytes = await File(shot.path).readAsBytes();

      final isFront =
          cameras[_cameraIndex].lensDirection == CameraLensDirection.front;

      Uint8List result = bytes;

      if (_mode == 'PORTRAIT') {
        final segmenter = SelfieSegmenter(
          mode: SegmenterMode.single,
          enableRawSizeMask: true,
        );

        try {
          final mask = await segmenter.processImage(
            InputImage.fromFilePath(shot.path),
          );

          if (mask != null) {
            result = await compute(
              _portraitBytes,
              <String, dynamic>{
                'bytes': bytes,
                'width': mask.width,
                'height': mask.height,
                'mask': mask.confidences,
                'aspect': _aspect,
                'flip': isFront && _mirrorFront,
                'hdr': _hdr,
                'style': _style,
              },
            );
          }
        } finally {
          await segmenter.close();
        }
      } else {
        result = await compute(
          _photoBytes,
          <String, dynamic>{
            'bytes': bytes,
            'hdr': _hdr,
            'zoom': _zoom,
            'night': _mode == 'NIGHT',
            'aspect': _aspect,
            'flip': isFront && _mirrorFront,
            'style': _style,
          },
        );
      }

      await File(shot.path).writeAsBytes(result, flush: true);
      await Gal.putImage(shot.path);

      if (mounted) {
        setState(() {
          _lastPath = shot.path;
          _lastThumbPath = shot.path;
          _lastIsVideo = false;
        });
      }

      // خاصية Live Photo مثل الآيفون: تسجيل لحظة حية مع الصورة
      if (_livePhoto && _mode == 'PHOTO') {
        if (mounted) {
          setState(() {
            _busy = false;
            _liveCapturing = true;
          });
        }
        try {
          await camera.startVideoRecording();
          await Future.delayed(const Duration(milliseconds: 1600));
          final liveClip = await camera.stopVideoRecording();
          await Gal.putVideo(liveClip.path);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                duration: Duration(seconds: 2),
                content: Text('تم حفظ الصورة الحية (Live Photo) في المعرض ✨'),
              ),
            );
          }
        } catch (_) {
          // في حال لم يدعم الهاتف التسجيل الفوري نكتفي بالصورة المحفوظة
        } finally {
          if (mounted) {
            setState(() => _liveCapturing = false);
          }
        }
      }
    } catch (e) {
      debugPrint('Capture failed: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر التقاط الصورة؛ جرّب مرة أخرى'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _toggleRecording() async {
    final camera = _camera;

    if (camera == null || !camera.value.isInitialized || _busy) {
      return;
    }

    try {
      if (_recording) {
        _recordTimer?.cancel();

        final video = await camera.stopVideoRecording();
        HapticFeedback.heavyImpact();

        if (mounted) {
          setState(() {
            _recording = false;
            _recordSeconds = 0;
            _lastPath = video.path;
            _lastIsVideo = true;
          });
        }

        await Gal.putVideo(video.path);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('تم حفظ الفيديو في المعرض بنجاح'),
            ),
          );
        }
      } else {
        HapticFeedback.mediumImpact();
        await camera.startVideoRecording();

        if (mounted) {
          setState(() {
            _recording = true;
            _recordSeconds = 0;
          });
        }

        _recordTimer = Timer.periodic(
          const Duration(seconds: 1),
          (_) {
            if (mounted) {
              setState(() => _recordSeconds++);
            }
          },
        );
      }
    } catch (e) {
      debugPrint('Video recording: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'تعذر بدء الفيديو بهذه الجودة على هذا الهاتف',
            ),
          ),
        );
      }
    }
  }

  Future<void> _setQuality(String label) async {
    if (_recording || _busy) return;

    setState(() {
      _qualityLabel = label;
      _videoPreset = label.startsWith('2K')
          ? ResolutionPreset.max
          : ResolutionPreset.veryHigh;
      _busy = true;
    });

    await _initCamera();

    if (mounted) {
      setState(() => _busy = false);
    }
  }

  Future<void> _openLast() async {
    final path = _lastPath;

    if (path == null || !await File(path).exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('لا توجد صورة أو فيديو بعد'),
          ),
        );
      }
      return;
    }

    await OpenFilex.open(path);
  }

  Future<void> _toggleFlash() async {
    final camera = _camera;
    if (camera == null) return;

    final modes = [
      FlashMode.off,
      FlashMode.auto,
      FlashMode.always,
      FlashMode.torch,
    ];
    final nextIdx = (modes.indexOf(_flash) + 1) % modes.length;
    _flash = modes[nextIdx];

    try {
      await camera.setFlashMode(_flash);
    } catch (_) {
      _flash = FlashMode.off;
    }

    if (mounted) {
      setState(() {});
    }
  }

  IconData get _flashIcon => switch (_flash) {
        FlashMode.off => Icons.flash_off_rounded,
        FlashMode.auto => Icons.flash_auto_rounded,
        FlashMode.always => Icons.flash_on_rounded,
        FlashMode.torch => Icons.highlight_rounded,
      };

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CustomPaint(
                    size: const Size(28, 28),
                    painter: _ProLensLogoPainter(),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'إعدادات كاميرا AI Pro',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('موازنة الإضاءة الذكية (Smart AI HDR)'),
                subtitle: const Text('منع احتراق الشمس وتفتيح الظلال تلقائياً'),
                value: _hdr,
                onChanged: (v) {
                  setState(() => _hdr = v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('صورة حية (Live Photo)'),
                subtitle: const Text('تسجيل لحظة متحركة مع الصورة مثل الآيفون'),
                value: _livePhoto,
                onChanged: (v) {
                  setState(() => _livePhoto = v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('مرآة الكاميرا الأمامية'),
                value: _mirrorFront,
                onChanged: (v) {
                  setState(() => _mirrorFront = v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('صوت غالق الكاميرا'),
                value: _sound,
                onChanged: (v) {
                  setState(() => _sound = v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('شبكة التقسيم الهندسي'),
                value: _grid,
                onChanged: (v) {
                  setState(() => _grid = v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('مؤقت ذاتي (3 ثوانٍ)'),
                value: _timerOn,
                onChanged: (v) {
                  setState(() => _timerOn = v);
                  setSheet(() {});
                },
              ),
              ListTile(
                title: const Text('إغلاق الإعدادات', textAlign: TextAlign.center),
                leading: const Icon(Icons.close),
                onTap: () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double get _aspectValue => switch (_aspect) {
        '1:1' => 1.0,
        '16:9' => 9 / 16,
        'Full' => 9 / 19.5,
        _ => 3 / 4,
      };

  String _formatTime(int sec) {
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordTimer?.cancel();
    _focusTimer?.cancel();
    _flashAnimation.dispose();
    _camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;

    if (!_permission) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(
                size: const Size(72, 72),
                painter: _ProLensLogoPainter(),
              ),
              const SizedBox(height: 20),
              const Text(
                'يرجى السماح باستخدام الكاميرا والميكروفون',
                style: TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 14),
              ElevatedButton(
                onPressed: _start,
                child: const Text('تفعيل الصلاحيات'),
              ),
            ],
          ),
        ),
      );
    }

    if (camera == null || !camera.value.isInitialized) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(
                size: const Size(64, 64),
                painter: _ProLensLogoPainter(),
              ),
              const SizedBox(height: 20),
              const CircularProgressIndicator(color: Colors.amberAccent),
            ],
          ),
        ),
      );
    }

    final previewSize = camera.value.previewSize;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. شاشة عرض الكاميرا الاحترافية بدون مط أو تشويه
          Positioned.fill(
            child: Center(
              child: AspectRatio(
                aspectRatio: _aspectValue,
                child: ClipRect(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onScaleStart: (_) => _scaleStartZoom = _zoom,
                        onScaleUpdate: (d) =>
                            _setZoom(_scaleStartZoom * d.scale),
                        onTapUp: (d) => _onTapFocus(d, constraints),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (previewSize != null)
                              FittedBox(
                                fit: BoxFit.cover,
                                child: SizedBox(
                                  width: previewSize.height,
                                  height: previewSize.width,
                                  child: CameraPreview(camera),
                                ),
                              )
                            else
                              CameraPreview(camera),
                            if (_grid)
                              IgnorePointer(
                                child: CustomPaint(painter: _GridPainter()),
                              ),
                            if (_focusPoint != null)
                              Positioned(
                                left: (_focusPoint!.dx - 36).clamp(
                                  0.0,
                                  constraints.maxWidth - 72,
                                ),
                                top: (_focusPoint!.dy - 36).clamp(
                                  0.0,
                                  constraints.maxHeight - 72,
                                ),
                                child: IgnorePointer(
                                  child: Container(
                                    width: 72,
                                    height: 72,
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: Colors.amberAccent,
                                        width: 1.8,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: const Center(
                                      child: Icon(
                                        Icons.wb_sunny_outlined,
                                        color: Colors.amberAccent,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),

          // 2. وميض الالتقاط
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _flashAnimation,
                builder: (_, __) => Opacity(
                  opacity: _flashAnimation.value,
                  child: Container(color: Colors.white),
                ),
              ),
            ),
          ),

          // 3. شريط موازنة الإضاءة والشمس اليدوي على الجانب
          if (_minExposure < _maxExposure)
            Positioned(
              right: 10,
              top: MediaQuery.of(context).size.height * 0.27,
              bottom: MediaQuery.of(context).size.height * 0.36,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  children: [
                    const Icon(
                      Icons.wb_sunny_rounded,
                      color: Colors.amberAccent,
                      size: 17,
                    ),
                    Expanded(
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: Slider(
                          value: _exposure,
                          min: _minExposure,
                          max: _maxExposure,
                          activeColor: Colors.amberAccent,
                          inactiveColor: Colors.white24,
                          onChanged: _setExposure,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => _setExposure(0.0),
                      child: Text(
                        _exposure == 0
                            ? 'AI'
                            : _exposure > 0
                                ? '+${_exposure.toStringAsFixed(1)}'
                                : _exposure.toStringAsFixed(1),
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.amberAccent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 4. شاشة الانتظار أثناء المعالجة الذكية
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x55000000),
                child: Center(
                  child: CircularProgressIndicator(
                    color: Colors.amberAccent,
                  ),
                ),
              ),
            ),

          // 5. الشريط العلوي الاحترافي (مثل الآيفون)
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xAA121212),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // زر الفلاش
                  IconButton(
                    onPressed: _toggleFlash,
                    icon: Icon(
                      _flashIcon,
                      color: _flash == FlashMode.off
                          ? Colors.white
                          : Colors.amberAccent,
                    ),
                  ),

                  // زر اللايف فوتو (Live Photo) مثل الآيفون
                  IconButton(
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      setState(() => _livePhoto = !_livePhoto);
                    },
                    icon: Icon(
                      _livePhoto
                          ? Icons.motion_photos_on_rounded
                          : Icons.motion_photos_off_rounded,
                      color: _livePhoto ? Colors.amberAccent : Colors.white70,
                    ),
                  ),

                  // زر الفلاتر الاحترافية (Styles)
                  IconButton(
                    onPressed: () => setState(() => _showStyles = !_showStyles),
                    icon: Icon(
                      Icons.Auto_awesome_rounded,
                      color: _style != 'AI' ? Colors.amberAccent : Colors.white,
                    ),
                  ),

                  // زر أبعاد الصورة
                  TextButton(
                    onPressed: () => setState(() {
                      _aspect = switch (_aspect) {
                        '4:3' => '16:9',
                        '16:9' => '1:1',
                        '1:1' => 'Full',
                        _ => '4:3',
                      };
                    }),
                    child: Text(
                      _aspect,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),

                  // زر الإعدادات
                  IconButton(
                    onPressed: _showSettings,
                    icon: const Icon(Icons.tune_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),

          // 6. شارة LIVE أو عداد التسجيل في الأعلى
          if (_liveCapturing || _recording || _recordSeconds > 0)
            Positioned(
              top: MediaQuery.of(context).padding.top + 68,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: _liveCapturing
                        ? Colors.amberAccent
                        : Colors.redAccent.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _liveCapturing
                        ? '● LIVE'
                        : (_mode == 'VIDEO' && _recording
                            ? '● REC  ${_formatTime(_recordSeconds)}'
                            : '$_recordSeconds'),
                    style: TextStyle(
                      color: _liveCapturing ? Colors.black : Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ),

          // 7. الشريط السفلي الاحترافي
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 14,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // شريط الأنماط اللونية (Photographic Styles)
                if (_showStyles)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _styleChip('AI', 'طبيعي ذكي'),
                          _styleChip('VIVID', 'حيوي مشبع'),
                          _styleChip('WARM', 'دافئ ذهبي'),
                          _styleChip('COOL', 'بارد سينمائي'),
                          _styleChip('BW', 'أبيض وأسود'),
                        ],
                      ),
                    ),
                  ),

                // أزرار الزوم السريع (1x, 2x, 3x, 5x)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final z in [1.0, 2.0, 3.0, 5.0])
                      if (z <= _maxZoom)
                        GestureDetector(
                          onTap: () => _setZoom(z),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            width: 36,
                            height: 36,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: (_zoom - z).abs() < 0.35
                                  ? Colors.amberAccent
                                  : Colors.black54,
                              border: Border.all(color: Colors.white30),
                            ),
                            child: Text(
                              '${z.toInt()}x',
                              style: TextStyle(
                                color: (_zoom - z).abs() < 0.35
                                    ? Colors.black
                                    : Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ),
                  ],
                ),

                const SizedBox(height: 10),

                // أوضاع الكاميرا
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _modeButton('VIDEO', 'فيديو'),
                    _modeButton('PHOTO', 'صورة'),
                    _modeButton('PORTRAIT', 'بورتريه'),
                    _modeButton('NIGHT', 'ليلي AI'),
                  ],
                ),

                if (_mode == 'VIDEO')
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _qualityChip('1080p • 30 إطار'),
                        const SizedBox(width: 8),
                        _qualityChip('2K • 30 إطار'),
                      ],
                    ),
                  ),

                const SizedBox(height: 14),

                // صف زر الالتقاط والمعرض وقلب الكاميرا
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // زر فتح آخر صورة أو فيديو (محمي من انهيار ملفات الفيديو)
                    GestureDetector(
                      onTap: _openLast,
                      child: Container(
                        width: 52,
                        height: 52,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white60, width: 1.5),
                          color: Colors.black54,
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (_lastThumbPath != null &&
                                File(_lastThumbPath!).existsSync())
                              Image.file(
                                File(_lastThumbPath!),
                                fit: BoxFit.cover,
                              )
                            else
                              const Icon(
                                Icons.photo_library_outlined,
                                color: Colors.white,
                              ),
                            if (_lastIsVideo)
                              Container(
                                color: Colors.black45,
                                child: const Icon(
                                  Icons.play_circle_fill_rounded,
                                  color: Colors.white,
                                  size: 28,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),

                    // زر التصوير الاحترافي بتصميم الآيفون
                    GestureDetector(
                      onTap: _capture,
                      child: Container(
                        width: 80,
                        height: 80,
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _mode == 'VIDEO'
                                ? Colors.redAccent
                                : (_livePhoto
                                    ? Colors.amberAccent
                                    : Colors.white),
                            width: 3.5,
                          ),
                        ),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          decoration: BoxDecoration(
                            color: _mode == 'VIDEO'
                                ? Colors.redAccent
                                : Colors.white,
                            shape: _mode == 'VIDEO' && _recording
                                ? BoxShape.rectangle
                                : BoxShape.circle,
                            borderRadius: _mode == 'VIDEO' && _recording
                                ? BorderRadius.circular(10)
                                : null,
                          ),
                          child: _recording
                              ? const Icon(
                                  Icons.stop_rounded,
                                  color: Colors.white,
                                  size: 34,
                                )
                              : null,
                        ),
                      ),
                    ),

                    // زر تبديل الكاميرا
                    IconButton(
                      onPressed: _switchCamera,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                        padding: const EdgeInsets.all(13),
                      ),
                      icon: const Icon(
                        Icons.cameraswitch_rounded,
                        size: 28,
                        color: Colors.white,
                      ),
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

  Widget _modeButton(String key, String label) {
    final selected = _mode == key;

    final color =
        key == 'VIDEO' && selected ? Colors.redAccent : Colors.amberAccent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        onTap: () {
          if (!_recording && !_busy) {
            HapticFeedback.selectionClick();
            setState(() => _mode = key);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 7,
          ),
          decoration: BoxDecoration(
            color: selected ? color.withOpacity(0.18) : Colors.black45,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? color : Colors.transparent,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? color : Colors.white70,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  Widget _styleChip(String key, String label) {
    final selected = _style == key;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        onTap: () => setState(() => _style = key),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? Colors.amberAccent.withOpacity(0.22)
                : Colors.black54,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? Colors.amberAccent : Colors.white24,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.amberAccent : Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  Widget _qualityChip(String label) {
    final selected = _qualityLabel == label;

    return GestureDetector(
      onTap: () => _setQuality(label),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 7,
        ),
        decoration: BoxDecoration(
          color: selected
              ? Colors.redAccent.withOpacity(0.18)
              : Colors.black54,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? Colors.redAccent : Colors.white24,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.redAccent : Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

// قص الصورة لتطابق الأبعاد المختارة على الشاشة
img.Image _cropAspect(img.Image src, String aspect) {
  if (aspect == 'Full') return src;

  final target = switch (aspect) {
    '1:1' => 1.0,
    '16:9' => 9 / 16,
    _ => 3 / 4,
  };

  final ratio = src.width / src.height;
  var w = src.width;
  var h = src.height;

  if (ratio > target) {
    w = (src.height * target).round();
  } else {
    h = (src.width / target).round();
  }

  final x = ((src.width - w) ~/ 2).clamp(0, src.width - 1);
  final y = ((src.height - h) ~/ 2).clamp(0, src.height - 1);

  return img.copyCrop(src, x: x, y: y, width: w, height: h);
}

// تطبيق الفلتر الاحترافي والذكاء الاصطناعي للإضاءة
img.Image _applySmartAI(
  img.Image image, {
  required bool hdr,
  required bool night,
  required String style,
}) {
  // قياس إضاءة الصورة الحقيقية (حساس الشمس والظلام)
  double totalLum = 0;
  int brightPixels = 0;
  int samples = 0;

  for (int y = 0; y < image.height; y += 16) {
    for (int x = 0; x < image.width; x += 16) {
      final p = image.getPixel(x, y);
      final lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      totalLum += lum;
      if (lum > 225) brightPixels++;
      samples++;
    }
  }

  final avgLum = samples > 0 ? totalLum / samples : 128.0;
  final harshSun = samples > 0 && (brightPixels / samples) > 0.16;
  final isLowLight = night || avgLum < 85;

  double brightness = 1.0;
  double contrast = 1.04;
  double saturation = 1.05;
  double gamma = 1.0;

  if (harshSun) {
    // حماية الصورة من احتراق الشمس القوية
    brightness = 0.95;
    contrast = 1.07;
    saturation = 1.08;
    gamma = 1.06;
  } else if (isLowLight) {
    // تفتيح ذكي للأماكن المظلمة والليل
    brightness = 1.08;
    contrast = 1.11;
    saturation = 1.06;
    gamma = 0.85;
  } else if (hdr) {
    brightness = 1.01;
    contrast = 1.06;
    saturation = 1.08;
    gamma = 0.96;
  }

  if (style == 'VIVID') {
    saturation *= 1.18;
    contrast *= 1.05;
  } else if (style == 'WARM') {
    saturation *= 1.10;
    gamma *= 0.95;
  } else if (style == 'COOL') {
    contrast *= 1.06;
    saturation *= 0.94;
  } else if (style == 'BW') {
    saturation = 0.0;
    contrast *= 1.15;
  }

  return img.adjustColor(
    image,
    brightness: brightness,
    contrast: contrast,
    saturation: saturation,
    gamma: gamma,
  );
}

Uint8List _photoBytes(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final decoded = img.decodeImage(bytes);

  if (decoded == null) return bytes;

  var oriented = img.bakeOrientation(decoded);

  final flip = args['flip'] as bool;
  if (flip) {
    oriented = img.flipHorizontal(oriented);
  }

  final aspect = args['aspect'] as String;
  oriented = _cropAspect(oriented, aspect);

  final zoom = (args['zoom'] as num).toDouble();
  final hdr = args['hdr'] as bool;
  final night = args['night'] as bool;
  final style = args['style'] as String;

  final fixed = _applySmartAI(
    oriented,
    hdr: hdr,
    night: night,
    style: style,
  );

  return Uint8List.fromList(
    img.encodeJpg(
      fixed,
      quality: zoom > 4 ? 96 : 98,
    ),
  );
}

Uint8List _portraitBytes(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final mw = args['width'] as int;
  final mh = args['height'] as int;
  final mask = (args['mask'] as List).cast<double>();
  final aspect = args['aspect'] as String;
  final flip = args['flip'] as bool;
  final hdr = args['hdr'] as bool;
  final style = args['style'] as String;

  final decoded = img.decodeImage(bytes);

  if (decoded == null || mw <= 0 || mh <= 0 || mask.isEmpty) {
    return bytes;
  }

  var fg = img.bakeOrientation(decoded);
  fg = _applySmartAI(fg, hdr: hdr, night: false, style: style);

  // تسريع البورتريه 15 ضعفاً عبر تصغير الخلفية قبل التمويه لمنع تعليق الهاتف
  final sw = (fg.width ~/ 4).clamp(1, fg.width);
  final sh = (fg.height ~/ 4).clamp(1, fg.height);
  final smallBg = img.copyResize(fg, width: sw, height: sh);
  final bg = img.gaussianBlur(smallBg, radius: 6);

  final out = img.Image(width: fg.width, height: fg.height);

  for (var y = 0; y < fg.height; y++) {
    final my = ((y * mh) / fg.height).floor().clamp(0, mh - 1);
    final by = ((y * sh) / fg.height).floor().clamp(0, sh - 1);

    for (var x = 0; x < fg.width; x++) {
      final mx = ((x * mw) / fg.width).floor().clamp(0, mw - 1);
      final bx = ((x * sw) / fg.width).floor().clamp(0, sw - 1);

      final i = my * mw + mx;
      final a = (i < mask.length ? mask[i] : 0.0).clamp(0.0, 1.0);

      final f = fg.getPixel(x, y);
      final b = bg.getPixel(bx, by);

      final alpha = ((a - 0.25) / 0.5).clamp(0.0, 1.0);

      out.setPixelRgba(
        x,
        y,
        (f.r * alpha + b.r * (1 - alpha)).round(),
        (f.g * alpha + b.g * (1 - alpha)).round(),
        (f.b * alpha + b.b * (1 - alpha)).round(),
        255,
      );
    }
  }

  var finalImg = flip ? img.flipHorizontal(out) : out;
  finalImg = _cropAspect(finalImg, aspect);

  return Uint8List.fromList(
    img.encodeJpg(finalImg, quality: 96),
  );
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white30
      ..strokeWidth = 1;

    canvas.drawLine(
      Offset(size.width / 3, 0),
      Offset(size.width / 3, size.height),
      p,
    );

    canvas.drawLine(
      Offset(size.width * 2 / 3, 0),
      Offset(size.width * 2 / 3, size.height),
      p,
    );

    canvas.drawLine(
      Offset(0, size.height / 3),
      Offset(size.width, size.height / 3),
      p,
    );

    canvas.drawLine(
      Offset(0, size.height * 2 / 3),
      Offset(size.width, size.height * 2 / 3),
      p,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// أيقونة عدسة احترافية مرسومة برمجياً داخل التطبيق
class _ProLensLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    final ringPaint = Paint()
      ..color = Colors.amberAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    final bodyPaint = Paint()
      ..color = const Color(0xFF222222)
      ..style = PaintingStyle.fill;

    final glassPaint = Paint()
      ..color = const Color(0xFF0D47A1)
      ..style = PaintingStyle.fill;

    finaldotPaint = Paint()
      ..color = Colors.white70
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, r, bodyPaint);
    canvas.drawCircle(center, r - 1.5, ringPaint);
    canvas.drawCircle(center, r * 0.58, glassPaint);
    canvas.drawCircle(
      Offset(center.dx - r * 0.2, center.dy - r * 0.2),
      r * 0.14,
      finaldotPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
