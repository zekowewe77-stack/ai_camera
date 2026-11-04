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

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

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
    with WidgetsBindingObserver, TickerProviderStateMixin {
  CameraController? _camera;

  int _cameraIndex = 0;

  String _mode = 'PHOTO';
  String _aspect = '4:3';

  String _qualityLabel = '1080p • 30 إطار';
  ResolutionPreset _videoPreset = ResolutionPreset.veryHigh;

  double _zoom = 1;
  double _minZoom = 1;
  double _maxZoom = 1;
  double _scaleStartZoom = 1;

  double _minExposure = 0;
  double _maxExposure = 0;
  double _exposure = 0;

  FlashMode _flash = FlashMode.off;

  bool _permission = false;
  bool _recording = false;
  bool _processing = false;

  bool _grid = false;
  bool _hdr = true;
  bool _sound = true;
  bool _timerOn = false;
  bool _mirrorFront = true;

  int _timerSeconds = 3;
  int _recordSeconds = 0;

  String? _lastPath;
  Offset? _focusPos;

  Timer? _recordTimer;

  final GlobalKey _previewKey = GlobalKey();

  late final AnimationController _flashAnimation;
  late final AnimationController _focusAnimation;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _flashAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );

    _focusAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
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

    if (old != null) {
      try {
        await old.dispose();
      } catch (_) {}
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

      _minZoom = await camera.getMinZoomLevel();
      _maxZoom = await camera.getMaxZoomLevel();

      _zoom = _minZoom;
      await camera.setZoomLevel(_zoom);

      try {
        _minExposure = await camera.getMinExposureOffset();
        _maxExposure = await camera.getMaxExposureOffset();
        _exposure = 0;
        await camera.setExposureOffset(0);
      } catch (_) {
        _minExposure = 0;
        _maxExposure = 0;
      }

      try {
        await camera.setFocusMode(FocusMode.auto);
      } catch (_) {}

      try {
        await camera.setExposureMode(ExposureMode.auto);
      } catch (_) {}

      try {
        await camera.setFlashMode(_flash);
      } catch (_) {}
    } catch (e) {
      debugPrint('Camera initialization: $e');
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
    if (cameras.length < 2 || _recording) return;

    _cameraIndex = (_cameraIndex + 1) % cameras.length;
    await _initCamera();
  }

  // لمس أي مكان على الشاشة = تركيز + ضبط إضاءة على النقطة دي
  Future<void> _handleTap(TapUpDetails d) async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;

    final box = _previewKey.currentContext?.findRenderObject() as RenderBox?;

    if (box != null && box.size.width > 0 && box.size.height > 0) {
      final local = box.globalToLocal(d.globalPosition);

      final nx = _clampDouble(local.dx / box.size.width, 0.0, 1.0);
      final ny = _clampDouble(local.dy / box.size.height, 0.0, 1.0);

      try {
        await camera.setFocusPoint(Offset(nx, ny));
        await camera.setExposurePoint(Offset(nx, ny));
        await camera.setFocusMode(FocusMode.auto);
      } catch (_) {}
    }

    if (!mounted) return;

    setState(() => _focusPos = d.globalPosition);
    _focusAnimation.forward(from: 0).then((_) async {
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) _focusAnimation.reverse();
    });
  }

  Future<void> _cycleFlash() async {
    final camera = _camera;
    if (camera == null) return;

    setState(() {
      _flash = _flash == FlashMode.off
          ? FlashMode.auto
          : _flash == FlashMode.auto
              ? FlashMode.torch
              : FlashMode.off;
    });

    try {
      await camera.setFlashMode(_flash);
    } catch (_) {}
  }

  Future<void> _setZoom(double z) async {
    final camera = _camera;
    if (camera == null) return;

    final v = _clampDouble(z, _minZoom, _maxZoom);

    setState(() => _zoom = v);

    try {
      await camera.setZoomLevel(v);
    } catch (_) {}
  }

  Future<void> _setExposure(double v) async {
    final camera = _camera;
    if (camera == null) return;

    setState(() => _exposure = v);

    try {
      await camera.setExposureOffset(v);
    } catch (_) {}
  }

  List<double> _zoomChips() {
    final chips = <double>[1.0];
    if (_maxZoom >= 2.1) chips.add(2.0);
    if (_maxZoom >= 4.6) chips.add(5.0);

    final maxR = double.parse(_maxZoom.toStringAsFixed(1));
    if (!chips.contains(maxR)) chips.add(maxR);

    chips.sort();
    return chips;
  }

  Future<void> _capture() async {
    var camera = _camera;

    if (camera == null || !camera.value.isInitialized || _processing) {
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

        await Future.delayed(const Duration(seconds: 1));
      }

      if (mounted) {
        setState(() => _recordSeconds = 0);
      }

      camera = _camera;
      if (camera == null || !camera.value.isInitialized) return;
    }

    if (_sound) {
      SystemSound.play(SystemSoundType.click);
      HapticFeedback.lightImpact();
    }

    _flashAnimation.forward(from: 0).then((_) {
      if (mounted) _flashAnimation.reverse();
    });

    setState(() => _processing = true);

    try {
      final shot = await camera.takePicture();
      final bytes = await File(shot.path).readAsBytes();

      final front = cameras[_cameraIndex].lensDirection ==
          CameraLensDirection.front;
      final mirror = front && _mirrorFront;

      Uint8List result;

      if (_mode == 'PORTRAIT') {
        final segmenter = SelfieSegmenter(
          mode: SegmenterMode.single,
          enableRawSizeMask: false,
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
                'mirror': mirror,
              },
            );
          } else {
            result = await compute(
              _photoBytes,
              <String, dynamic>{
                'bytes': bytes,
                'hdr': _hdr,
                'night': false,
                'mirror': mirror,
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
            'night': _mode == 'NIGHT',
            'mirror': mirror,
          },
        );
      }

      await File(shot.path).writeAsBytes(result, flush: true);
      await Gal.putImage(shot.path);

      if (mounted) {
        setState(() => _lastPath = shot.path);
      }
    } catch (e) {
      debugPrint('Capture failed: $e');
      _snack('تعذر التقاط الصورة؛ جرّب مرة أخرى');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _toggleRecording() async {
    final camera = _camera;

    if (camera == null || !camera.value.isInitialized) {
      return;
    }

    try {
      if (_recording) {
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
        _snack('تم حفظ الفيديو في المعرض');
      } else {
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
      _snack('تعذر بدء الفيديو بهذه الجودة على هذا الهاتف');
    }
  }

  Future<void> _setQuality(String label) async {
    if (_recording || _processing) return;

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
      _snack('لا توجد صورة أو فيديو بعد');
      return;
    }

    await OpenFilex.open(path);
  }

  void _snack(String msg) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF171717),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'إعدادات الكاميرا',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              SwitchListTile(
                title: const Text('تحسين الألوان والإضاءة'),
                value: _hdr,
                onChanged: (v) {
                  setState(() => _hdr = v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('صوت التصوير'),
                value: _sound,
                onChanged: (v) {
                  setState(() => _sound = v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('شبكة تقسيم الصورة'),
                value: _grid,
                onChanged: (v) {
                  setState(() => _grid = v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('مؤقت 3 ثوانٍ'),
                value: _timerOn,
                onChanged: (v) {
                  setState(() => _timerOn = v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('حفظ السيلفي بنفس اتجاه المعاينة'),
                value: _mirrorFront,
                onChanged: (v) {
                  setState(() => _mirrorFront = v);
                  setSheet(() {});
                },
              ),
              ListTile(
                title: const Text('إغلاق الإعدادات'),
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
        '1:1' => 1,
        '16:9' => 9 / 16,
        'Full' => 9 / 19.5,
        _ => 3 / 4,
      };

  IconData _flashIcon(FlashMode m) {
    switch (m) {
      case FlashMode.auto:
        return Icons.flash_auto;
      case FlashMode.torch:
      case FlashMode.always:
        return Icons.flash_on;
      case FlashMode.off:
        return Icons.flash_off;
    }
  }

  String _zoomLabel(double z) => z == z.roundToDouble()
      ? '${z.round()}×'
      : '${z.toStringAsFixed(1)}×';

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordTimer?.cancel();
    _flashAnimation.dispose();
    _focusAnimation.dispose();
    _camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;

    if (!_permission) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text('يرجى السماح باستخدام الكاميرا'),
        ),
      );
    }

    if (cameras.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text('لا توجد كاميرا متاحة على هذا الجهاز'),
        ),
      );
    }

    if (camera == null || !camera.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    final front = cameras[_cameraIndex].lensDirection ==
        CameraLensDirection.front;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ===== المعاينة =====
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: (_) => _scaleStartZoom = _zoom,
              onScaleUpdate: (d) async {
                final next = _clampDouble(
                  _scaleStartZoom * d.scale,
                  _minZoom,
                  _maxZoom,
                );

                if ((next - _zoom).abs() < 0.01) return;

                setState(() => _zoom = next);

                try {
                  await camera.setZoomLevel(next);
                } catch (_) {}
              },
              onTapUp: _handleTap,
              child: Center(
                child: AspectRatio(
                  aspectRatio: _aspectValue,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: front
                        ? Matrix4.rotationY(3.1415926)
                        : Matrix4.identity(),
                    child: CameraPreview(camera, key: _previewKey),
                  ),
                ),
              ),
            ),
          ),

          // ===== وميض التصوير =====
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

          // ===== الشبكة =====
          if (_grid)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _GridPainter()),
              ),
            ),

          // ===== دائرة التركيز عند اللمس =====
          if (_focusPos != null)
            Positioned(
              left: _focusPos!.dx - 36,
              top: _focusPos!.dy - 36,
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _focusAnimation,
                  builder: (_, __) {
                    final v = Curves.easeOut.transform(
                      _focusAnimation.value,
                    );

                    return Opacity(
                      opacity: _clampDouble(v, 0.0, 1.0),
                      child: Transform.scale(
                        scale: 1.6 - 0.6 * v,
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.yellowAccent,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),

          // ===== الشريط العلوي =====
          Positioned(
            top: 38,
            left: 8,
            right: 8,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  onPressed: _cycleFlash,
                  icon: Icon(
                    _flashIcon(_flash),
                    color: _flash == FlashMode.off
                        ? Colors.white
                        : Colors.yellowAccent,
                  ),
                ),
                Text(
                  '${_zoom.toStringAsFixed(1)}× / ${_maxZoom.toStringAsFixed(1)}×',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                IconButton(
                  onPressed: _showSettings,
                  icon: const Icon(Icons.tune, color: Colors.white),
                ),
                IconButton(
                  onPressed: () => setState(() {
                    _aspect = switch (_aspect) {
                      '4:3' => '16:9',
                      '16:9' => '1:1',
                      '1:1' => 'Full',
                      _ => '4:3',
                    };
                  }),
                  icon: Text(
                    _aspect,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ===== عداد التسجيل / المؤقت =====
          if (_recording || _recordSeconds > 0)
            Positioned(
              top: 92,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  _mode == 'VIDEO' && _recording
                      ? '● تسجيل  ${_recordSeconds}s'
                      : '$_recordSeconds',
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 17,
                  ),
                ),
              ),
            ),

          // ===== شريط الإضاءة (Exposure) =====
          if (_maxExposure > _minExposure)
            Positioned(
              right: 4,
              top: 110,
              bottom: 300,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black38,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.brightness_6_outlined,
                        color: Colors.white70,
                        size: 20,
                      ),
                      SizedBox(
                        height: 150,
                        width: 44,
                        child: RotatedBox(
                          quarterTurns: -1,
                          child: Slider(
                            value: _clampDouble(
                              _exposure,
                              _minExposure,
                              _maxExposure,
                            ),
                            min: _minExposure,
                            max: _maxExposure,
                            divisions: 8,
                            activeColor: Colors.yellowAccent,
                            inactiveColor: Colors.white24,
                            onChanged: _setExposure,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => _setExposure(0),
                        child: const Icon(
                          Icons.restart_alt,
                          color: Colors.white70,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ===== أزرار التحكم السفلية =====
          Positioned(
            bottom: 24,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final z in _zoomChips())
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        child: _zoomChip(z),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _modeButton('VIDEO', 'فيديو'),
                    _modeButton('PHOTO', 'صورة'),
                    _modeButton('PORTRAIT', 'بورتريه'),
                    _modeButton('NIGHT', 'ليل'),
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    GestureDetector(
                      onTap: _openLast,
                      child: Container(
                        width: 48,
                        height: 48,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: Colors.white54),
                          color: Colors.black54,
                        ),
                        child: _lastPath != null &&
                                File(_lastPath!).existsSync()
                            ? Image.file(
                                File(_lastPath!),
                                fit: BoxFit.cover,
                              )
                            : const Icon(
                                Icons.photo_library_outlined,
                                color: Colors.white,
                              ),
                      ),
                    ),
                    GestureDetector(
                      onTap: _processing ? null : _capture,
                      child: Opacity(
                        opacity: _processing ? 0.7 : 1,
                        child: Container(
                          width: 74,
                          height: 74,
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white,
                              width: 3,
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
                              borderRadius:
                                  _mode == 'VIDEO' && _recording
                                      ? BorderRadius.circular(8)
                                      : null,
                            ),
                            child: _processing
                                ? const Padding(
                                    padding: EdgeInsets.all(14),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.black,
                                    ),
                                  )
                                : (_recording
                                    ? const Icon(
                                        Icons.stop,
                                        color: Colors.white,
                                        size: 30,
                                      )
                                    : null),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _switchCamera,
                      icon: const Icon(
                        Icons.cameraswitch,
                        size: 30,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ===== معالجة الصورة =====
          if (_processing)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black26,
                  child: const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _zoomChip(double z) {
    final active = (_zoom - z).abs() < 0.15;

    return GestureDetector(
      onTap: () => _setZoom(z),
      child: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? Colors.white : Colors.black45,
        ),
        child: Text(
          _zoomLabel(z),
          style: TextStyle(
            color: active ? Colors.black : Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _modeButton(String key, String label) {
    final selected = _mode == key;

    final color = key == 'VIDEO' && selected
        ? Colors.redAccent
        : Colors.greenAccent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        onTap: () {
          if (!_recording) {
            setState(() => _mode = key);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 7,
          ),
          decoration: BoxDecoration(
            color: selected ? color.withOpacity(0.18) : Colors.transparent,
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

// ===== معالجة الصور العادية (ذكية مع الإضاءة) =====
Uint8List _photoBytes(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final decoded = img.decodeImage(bytes);

  if (decoded == null) return bytes;

  var photo = img.bakeOrientation(decoded);

  if (args['mirror'] == true) {
    photo = img.flipHorizontal(photo);
  }

  final hdr = args['hdr'] as bool;
  final night = args['night'] as bool;

  // قياس متوسط إضاءة المشهد من نسخة مصغّرة (سريع جدًا)
  final sampleW = 96;
  final sampleH = (photo.height * sampleW / photo.width).round();
  final sample = img.copyResize(photo, width: sampleW, height: sampleH);

  double sum = 0;
  final total = sample.width * sample.height;

  for (var y = 0; y < sample.height; y++) {
    for (var x = 0; x < sample.width; x++) {
      final p = sample.getPixel(x, y);
      sum += 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b;
    }
  }

  final mean = total > 0 ? sum / total : 128.0;

  // ضبط السطوع تلقائيًا حسب ظروف الإضاءة (منع احتراق الشمس / رفع الظلام)
  double brightness = 1.0;
  if (mean > 175) {
    brightness = 0.88;
  } else if (mean > 150) {
    brightness = 0.95;
  } else if (mean < 55) {
    brightness = 1.45;
  } else if (mean < 85) {
    brightness = 1.25;
  } else if (mean < 110) {
    brightness = 1.10;
  }

  if (night) {
    if (brightness < 1.30) brightness = 1.30;
    if (brightness > 1.60) brightness = 1.60;
  }

  final fixed = img.adjustColor(
    photo,
    brightness: brightness,
    contrast: night ? 1.05 : (hdr ? 1.08 : 1.04),
    saturation: night ? 1.15 : (hdr ? 1.10 : 1.05),
    gamma: night ? 0.95 : 1.0,
  );

  return Uint8List.fromList(img.encodeJpg(fixed, quality: 95));
}

// ===== معالجة وضع البورتريه =====
Uint8List _portraitBytes(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final mw = args['width'] as int;
  final mh = args['height'] as int;
  final mask = (args['mask'] as List).cast<double>();
  final mirror = args['mirror'] == true;

  final decoded = img.decodeImage(bytes);
  if (decoded == null || mw <= 0 || mh <= 0 || mask.isEmpty) {
    return bytes;
  }

  var fg = img.bakeOrientation(decoded);
  final w = fg.width;
  final h = fg.height;

  if (w <= 0 || h <= 0) return bytes;

  // خريطة الشفافية من الماسك
  final alpha = Float32List(w * h);

  for (var y = 0; y < h; y++) {
    final my = clampInt((y * mh) ~/ h, 0, mh - 1);

    for (var x = 0; x < w; x++) {
      final mx = clampInt((x * mw) ~/ w, 0, mw - 1);

      final idx = my * mw + mx;

      double a = idx < mask.length ? mask[idx] : 0.0;
      a = clampDouble(a, 0.0, 1.0);

      // قطع الهالة الزائدة حول الشخص + تنعيم S-Curve
      a = clampDouble((a - 0.3) / 0.4, 0.0, 1.0);
      a = a * a * (3 - 2 * a);

      alpha[y * w + x] = a;
    }
  }

  // عكس الماسك مع الصورة للكاميرا الأمامية
  if (mirror) {
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w ~/ 2; x++) {
        final i1 = y * w + x;
        final i2 = y * w + (w - 1 - x);
        final t = alpha[i1];
        alpha[i1] = alpha[i2];
        alpha[i2] = t;
      }
    }
    fg = img.flipHorizontal(fg);
  }

  // تنعيم الحواف
  boxBlurAlpha(alpha, w, h);

  // خلفية بوكيه سريعة: تصغير ← تمويه ← تكبير
  var smallW = (w / 6).round();
  if (smallW < 8) smallW = w;
  final smallH = (h * smallW / w).round();

  final bg = img.copyResize(
    img.gaussianBlur(
      img.copyResize(fg, width: smallW, height: smallH),
      radius: 6,
    ),
    width: w,
    height: h,
    interpolation: img.Interpolation.cubic,
  );

  final out = img.Image(width: w, height: h);

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final a = alpha[y * w + x];
      final f = fg.getPixel(x, y);
      final b = bg.getPixel(x, y);

      out.setPixelRgba(
        x,
        y,
        (f.r * a + b.r * (1 - a)).round(),
        (f.g * a + b.g * (1 - a)).round(),
        (f.b * a + b.b * (1 - a)).round(),
        255,
      );
    }
  }

  return Uint8List.fromList(img.encodeJpg(out, quality: 95));
}

void boxBlurAlpha(Float32List a, int w, int h) {
  final tmp = Float32List(a.length);

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      double s = 0;
      int n = 0;

      for (var dy = -1; dy <= 1; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= h) continue;

        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx;
          if (xx < 0 || xx >= w) continue;

          s += a[yy * w + xx];
          n++;
        }
      }

      tmp[y * w + x] = s / n;
    }
  }

  a.setAll(0, tmp);
}

double clampDouble(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

int clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

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
