import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
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
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

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
  String _qualityLabel = '1080p • 30 إطار';
  ResolutionPreset _videoPreset = ResolutionPreset.veryHigh;

  // إعدادات التقريب (Zoom)
  double _zoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _scaleStartZoom = 1.0;

  // إعدادات الإضاءة والتعريض (Exposure)
  double _exposure = 0.0;
  double _minExposure = -2.0;
  double _maxExposure = 2.0;

  // نقطة التركيز باللمس
  Offset? _focusPoint;
  Timer? _focusTimer;

  FlashMode _flash = FlashMode.off;

  bool _permission = false;
  bool _recording = false;
  bool _isProcessing = false;

  // الإعدادات الإضافية
  bool _grid = false;
  bool _hdr = true;
  bool _sound = true;
  bool _timerOn = false;
  bool _mirrorFront = true;

  final int _timerSeconds = 3;
  int _countdown = 0;
  int _recordSeconds = 0;

  String? _lastPath;
  bool _lastIsVideo = false;

  Timer? _recordTimer;
  late final AnimationController _flashAnimation;

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
      await old.dispose();
    }

    final camera = CameraController(
      cameras[_cameraIndex],
      _videoPreset,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    _camera = camera;

    try {
      await camera.initialize();
      await camera.lockCaptureOrientation(DeviceOrientation.portraitUp);

      _minZoom = await camera.getMinZoomLevel();
      _maxZoom = await camera.getMaxZoomLevel();
      _zoom = _minZoom;
      await camera.setZoomLevel(_zoom);

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
    } catch (e) {
      debugPrint('Camera initialization error: $e');
    }

    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_camera == null || !_camera!.value.isInitialized) return;

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
    if (cameras.length < 2 || _recording || _isProcessing) return;
    HapticFeedback.selectionClick();
    _cameraIndex = (_cameraIndex + 1) % cameras.length;
    await _initCamera();
  }

  Future<void> _setZoom(double targetZoom) async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;

    final clamped = targetZoom.clamp(_minZoom, _maxZoom);
    setState(() => _zoom = clamped);
    try {
      await camera.setZoomLevel(clamped);
    } catch (_) {}
  }

  Future<void> _onTapFocus(TapUpDetails details, BoxConstraints constraints) async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;

    final x = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
    final y = (details.localPosition.dy / constraints.maxHeight).clamp(0.0, 1.0);

    setState(() {
      _focusPoint = details.localPosition;
    });

    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _focusPoint = null);
    });

    try {
      await camera.setFocusPoint(Offset(x, y));
      await camera.setFocusMode(FocusMode.auto);
    } catch (_) {}

    try {
      await camera.setExposurePoint(Offset(x, y));
    } catch (_) {}
  }

  Future<void> _setExposure(double value) async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;

    setState(() => _exposure = value);
    try {
      await camera.setExposureOffset(value);
    } catch (_) {}
  }

  Future<void> _capture() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized || _isProcessing) {
      return;
    }

    if (_mode == 'VIDEO') {
      await _toggleRecording();
      return;
    }

    // المؤقت الذاتي
    if (_timerOn) {
      for (int i = _timerSeconds; i > 0; i--) {
        if (!mounted) return;
        setState(() => _countdown = i);
        if (_sound) SystemSound.play(SystemSoundType.click);
        await Future.delayed(const Duration(seconds: 1));
      }
      if (mounted) {
        setState(() => _countdown = 0);
      }
    }

    if (_sound) {
      SystemSound.play(SystemSoundType.click);
      HapticFeedback.mediumImpact();
    }

    _flashAnimation.forward(from: 0).then((_) {
      if (mounted) _flashAnimation.reverse();
    });

    setState(() => _isProcessing = true);

    try {
      // في الوضع الليلي نرفع الإضاءة قليلاً قبل الالتقاط إن أمكن
      if (_mode == 'NIGHT' && _exposure == 0.0 && _maxExposure > 0) {
        try {
          await camera.setExposureOffset((_maxExposure * 0.4).clamp(0.0, 2.0));
        } catch (_) {}
      }

      final shot = await camera.takePicture();

      // إعادة الإضاءة لطبيعتها بعد الالتقاط
      if (_mode == 'NIGHT' && _exposure == 0.0) {
        try {
          await camera.setExposureOffset(0.0);
        } catch (_) {}
      }

      final bytes = await File(shot.path).readAsBytes();
      Uint8List result = bytes;

      final isFront =
          cameras[_cameraIndex].lensDirection == CameraLensDirection.front;

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
          },
        );
      }

      await File(shot.path).writeAsBytes(result, flush: true);
      await Gal.putImage(shot.path);

      if (mounted) {
        setState(() {
          _lastPath = shot.path;
          _lastIsVideo = false;
        });
      }
    } catch (e) {
      debugPrint('Capture failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر التقاط الصورة؛ جرّب مرة أخرى')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _toggleRecording() async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;

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
            const SnackBar(content: Text('تم حفظ الفيديو في المعرض بنجاح')),
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

        _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) {
            setState(() => _recordSeconds++);
          }
        });
      }
    } catch (e) {
      debugPrint('Video recording error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر بدء الفيديو بهذه الجودة على هذا الهاتف'),
          ),
        );
      }
    }
  }

  Future<void> _setQuality(String label) async {
    if (_recording || _isProcessing) return;

    setState(() {
      _qualityLabel = label;
      _videoPreset = label.startsWith('2K')
          ? ResolutionPreset.max
          : ResolutionPreset.veryHigh;
    });

    await _initCamera();
  }

  Future<void> _openLast() async {
    final path = _lastPath;
    if (path == null || !await File(path).exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا توجد صورة أو فيديو بعد')),
        );
      }
      return;
    }
    await OpenFilex.open(path);
  }

  Future<void> _toggleFlash() async {
    final camera = _camera;
    if (camera == null) return;

    // التنقل بين أوضاع الفلاش الأربعة
    final modes = [
      FlashMode.off,
      FlashMode.auto,
      FlashMode.always,
      FlashMode.torch,
    ];
    final nextIndex = (modes.indexOf(_flash) + 1) % modes.length;
    _flash = modes[nextIndex];

    try {
      await camera.setFlashMode(_flash);
    } catch (_) {
      _flash = FlashMode.off;
    }

    if (mounted) setState(() {});
  }

  IconData get _flashIcon => switch (_flash) {
        FlashMode.off => Icons.flash_off,
        FlashMode.auto => Icons.flash_auto,
        FlashMode.always => Icons.flash_on,
        FlashMode.torch => Icons.highlight,
      };

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'إعدادات الكاميرا الاحترافية',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              SwitchListTile(
                title: const Text('المعالجة الذكية HDR (موازنة الشمس والظلال)'),
                value: _hdr,
                activeColor: Colors.greenAccent,
                onChanged: (v) {
                  setState(() => _hdr = v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('عكس صور الكاميرا الأمامية (مرآة)'),
                value: _mirrorFront,
                activeColor: Colors.greenAccent,
                onChanged: (v) {
                  setState(() => _mirrorFront = v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('صوت غالق الكاميرا'),
                value: _sound,
                activeColor: Colors.greenAccent,
                onChanged: (v) {
                  setState(() => _sound = v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('شبكة التقسيم الهندسي (Grid)'),
                value: _grid,
                activeColor: Colors.greenAccent,
                onChanged: (v) {
                  setState(() => _grid = v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('مؤقت ذاتي (3 ثوانٍ)'),
                value: _timerOn,
                activeColor: Colors.greenAccent,
                onChanged: (v) {
                  setState(() => _timerOn = v);
                  setSheet(() {});
                },
              ),
              const Divider(color: Colors.white24),
              ListTile(
                title: const Text('إغلاق الإعدادات', textAlign: TextAlign.center),
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
        'Full' => MediaQuery.of(context).size.width /
            MediaQuery.of(context).size.height,
        _ => 3 / 4,
      };

  String _formatDuration(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
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
              const Icon(Icons.camera_alt_outlined, size: 60, color: Colors.white54),
              const SizedBox(height: 16),
              const Text('يرجى السماح باستخدام الكاميرا والميكروفون'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _start,
                child: const Text('منح الصلاحية'),
              ),
            ],
          ),
        ),
      );
    }

    if (camera == null || !camera.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.greenAccent)),
      );
    }

    final previewSize = camera.value.previewSize!;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. معاينة الكاميرا مع دعم القص الحقيقي واللمس للتركيز
          Center(
            child: AspectRatio(
              aspectRatio: _aspectValue,
              child: ClipRect(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: (_) => _scaleStartZoom = _zoom,
                      onScaleUpdate: (d) => _setZoom(_scaleStartZoom * d.scale),
                      onTapUp: (details) => _onTapFocus(details, constraints),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          FittedBox(
                            fit: BoxFit.cover,
                            child: SizedBox(
                              width: previewSize.height,
                              height: previewSize.width,
                              child: CameraPreview(camera),
                            ),
                          ),
                          // شبكة التقسيم
                          if (_grid)
                            IgnorePointer(
                              child: CustomPaint(painter: _GridPainter()),
                            ),
                          // مربع التركيز باللمس
                          if (_focusPoint != null)
                            Positioned(
                              left: (_focusPoint!.dx - 35).clamp(
                                  0.0, constraints.maxWidth - 70),
                              top: (_focusPoint!.dy - 35).clamp(
                                  0.0, constraints.maxHeight - 70),
                              child: IgnorePointer(
                                child: Container(
                                  width: 70,
                                  height: 70,
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                        color: Colors.amberAccent, width: 1.8),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Center(
                                    child: Icon(Icons.wb_sunny_outlined,
                                        color: Colors.amberAccent, size: 18),
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

          // 2. تأثير الفلاش الأبيض عند الالتقاط
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

          // 3. شريط التحكم في الإضاءة (منع احتراق الشمس يدوياً)
          if (_minExposure != _maxExposure)
            Positioned(
              right: 12,
              top: MediaQuery.of(context).size.height * 0.28,
              bottom: MediaQuery.of(context).size.height * 0.35,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: [
                    const Icon(Icons.wb_sunny, color: Colors.amber, size: 18),
                    Expanded(
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6),
                          ),
                          child: Slider(
                            value: _exposure,
                            min: _minExposure,
                            max: _maxExposure,
                            activeColor: Colors.amber,
                            inactiveColor: Colors.white30,
                            onChanged: _setExposure,
                          ),
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => _setExposure(0.0),
                      child: Text(
                        _exposure == 0
                            ? '0'
                            : _exposure > 0
                                ? '+${_exposure.toStringAsFixed(1)}'
                                : _exposure.toStringAsFixed(1),
                        style: const TextStyle(
                            fontSize: 10, color: Colors.amberAccent),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 4. الشريط العلوي
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    onPressed: _toggleFlash,
                    icon: Icon(
                      _flashIcon,
                      color: _flash == FlashMode.off
                          ? Colors.white
                          : Colors.amberAccent,
                    ),
                  ),
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
                  if (_hdr && _mode != 'VIDEO')
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.greenAccent),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'AI HDR',
                        style: TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  IconButton(
                    onPressed: _showSettings,
                    icon: const Icon(Icons.tune, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),

          // 5. عداد تسجيل الفيديو
          if (_recording)
            Positioned(
              top: MediaQuery.of(context).padding.top + 70,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '● ${_formatDuration(_recordSeconds)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ),

          // 6. عداد المؤقت الذاتي وسط الشاشة
          if (_countdown > 0)
            Center(
              child: Text(
                '$_countdown',
                style: const TextStyle(
                  fontSize: 90,
                  fontWeight: FontWeight.bold,
                  color: Colors.white70,
                  shadows: [Shadow(blurRadius: 20, color: Colors.black)],
                ),
              ),
            ),

          // 7. الشريط السفلي وأدوات التحكم
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 16,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // أزرار التقريب السريع (1x, 2x, 3x)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final z in [1.0, 2.0, 3.0])
                      if (z <= _maxZoom)
                        GestureDetector(
                          onTap: () => _setZoom(z),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 5),
                            width: 36,
                            height: 36,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: (_zoom - z).abs() < 0.4
                                  ? Colors.white
                                  : Colors.black54,
                              border: Border.all(color: Colors.white38),
                            ),
                            child: Text(
                              '${z.toInt()}x',
                              style: TextStyle(
                                color: (_zoom - z).abs() < 0.4
                                    ? Colors.black
                                    : Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                  ],
                ),
                const SizedBox(height: 12),

                // أوضاع التصوير
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _modeButton('VIDEO', 'فيديو'),
                    _modeButton('PHOTO', 'صورة'),
                    _modeButton('PORTRAIT', 'بورتريه AI'),
                    _modeButton('NIGHT', 'ليلي'),
                  ],
                ),

                // خيارات جودة الفيديو
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

                const SizedBox(height: 16),

                // زر الالتقاط والمعرض وتبديل الكاميرا
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // معاينة آخر صورة أو فيديو
                    GestureDetector(
                      onTap: _openLast,
                      child: Container(
                        width: 52,
                        height: 52,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white70, width: 1.5),
                          color: Colors.black54,
                        ),
                        child: _lastPath != null &&
                                File(_lastPath!).existsSync()
                            ? (_lastIsVideo
                                ? const Icon(Icons.play_circle_fill,
                                    color: Colors.white, size: 30)
                                : Image.file(
                                    File(_lastPath!),
                                    fit: BoxFit.cover,
                                  ))
                            : const Icon(
                                Icons.photo_library_outlined,
                                color: Colors.white,
                              ),
                      ),
                    ),

                    // زر التصوير الرئيسي
                    GestureDetector(
                      onTap: _capture,
                      child: Container(
                        width: 78,
                        height: 78,
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _mode == 'VIDEO'
                                ? Colors.redAccent
                                : Colors.white,
                            width: 3.5,
                          ),
                        ),
                        child: Container(
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
                          child: _isProcessing
                              ? const Padding(
                                  padding: EdgeInsets.all(18),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    color: Colors.black,
                                  ),
                                )
                              : (_recording
                                  ? const Icon(
                                      Icons.stop,
                                      color: Colors.white,
                                      size: 32,
                                    )
                                  : null),
                        ),
                      ),
                    ),

                    // زر قلب الكاميرا
                    IconButton(
                      onPressed: _switchCamera,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                        padding: const EdgeInsets.all(12),
                      ),
                      icon: const Icon(
                        Icons.cameraswitch,
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
        key == 'VIDEO' && selected ? Colors.redAccent : Colors.greenAccent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        onTap: () {
          if (!_recording && !_isProcessing) {
            HapticFeedback.selectionClick();
            setState(() => _mode = key);
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? color.withOpacity(0.2) : Colors.black45,
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

  Widget _qualityChip(String label) {
    final selected = _qualityLabel == label;

    return GestureDetector(
      onTap: () => _setQuality(label),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? Colors.redAccent.withOpacity(0.2)
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

// دالة قص الأبعاد لتطابق ما يراه المستخدم على الشاشة
img.Image _cropToAspect(img.Image src, String aspect) {
  if (aspect == 'Full') return src;

  final targetRatio = switch (aspect) {
    '1:1' => 1.0,
    '16:9' => 9 / 16,
    _ => 3 / 4,
  };

  final currentRatio = src.width / src.height;
  int cropW = src.width;
  int cropH = src.height;

  if (currentRatio > targetRatio) {
    cropW = (src.height * targetRatio).round();
  } else {
    cropH = (src.width / targetRatio).round();
  }

  final x = ((src.width - cropW) / 2).round().clamp(0, src.width - 1);
  final y = ((src.height - cropH) / 2).round().clamp(0, src.height - 1);

  return img.copyCrop(src, x: x, y: y, width: cropW, height: cropH);
}

// معالجة الصور العادية والليلية و HDR
Uint8List _photoBytes(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;

  var processed = img.bakeOrientation(decoded);

  final flip = args['flip'] as bool;
  if (flip) {
    processed = img.flipHorizontal(processed);
  }

  final aspect = args['aspect'] as String;
  processed = _cropToAspect(processed, aspect);

  final zoom = (args['zoom'] as num).toDouble();
  final hdr = args['hdr'] as bool;
  final night = args['night'] as bool;

  processed = img.adjustColor(
    processed,
    contrast: night ? 1.12 : (hdr ? 1.07 : 1.02),
    brightness: night ? 1.08 : (hdr ? 0.97 : 1.0),
    saturation: hdr ? 1.08 : 1.02,
    gamma: night ? 0.88 : (hdr ? 0.96 : 1.0),
  );

  return Uint8List.fromList(
    img.encodeJpg(processed, quality: zoom > 4 ? 95 : 98),
  );
}

// معالجة وضع البورتريه بسرعة فائقة (تصغير الخلفية قبل التمويه ثم الدمج)
Uint8List _portraitBytes(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final mw = args['width'] as int;
  final mh = args['height'] as int;
  final mask = (args['mask'] as List).cast<double>();
  final aspect = args['aspect'] as String;
  final flip = args['flip'] as bool;
  final hdr = args['hdr'] as bool;

  final decoded = img.decodeImage(bytes);
  if (decoded == null || mw <= 0 || mh <= 0 || mask.isEmpty) {
    return bytes;
  }

  var fg = img.bakeOrientation(decoded);
  if (hdr) {
    fg = img.adjustColor(fg, contrast: 1.06, saturation: 1.06, brightness: 0.98);
  }

  // تسريع التمويه 10 أضعاف عن طريق تصغير نسخة الخلفية ثم تمويهها
  final smallW = math.max(1, fg.width ~/ 4);
  final smallH = math.max(1, fg.height ~/ 4);
  final smallBg = img.copyResize(fg, width: smallW, height: smallH);
  final blurredSmall = img.gaussianBlur(smallBg, radius: 6);

  final out = img.Image(width: fg.width, height: fg.height);

  for (var y = 0; y < fg.height; y++) {
    final my = ((y * mh) / fg.height).floor().clamp(0, mh - 1);
    final by = ((y * smallH) / fg.height).floor().clamp(0, smallH - 1);

    for (var x = 0; x < fg.width; x++) {
      final mx = ((x * mw) / fg.width).floor().clamp(0, mw - 1);
      final bx = ((x * smallW) / fg.width).floor().clamp(0, smallW - 1);

      final i = my * mw + mx;
      final confidence = (i < mask.length ? mask[i] : 0.0).clamp(0.0, 1.0);

      final f = fg.getPixel(x, y);
      final b = blurredSmall.getPixel(bx, by);

      final alpha = ((confidence - 0.25) / 0.5).clamp(0.0, 1.0);

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
  finalImg = _cropToAspect(finalImg, aspect);

  return Uint8List.fromList(img.encodeJpg(finalImg, quality: 96));
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
