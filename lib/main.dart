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

// ═══════════════════════════════════════════
//  GLOBALS
// ═══════════════════════════════════════════
List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.black,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Cameras: $e');
  }

  runApp(const CameraApp());
}

// ═══════════════════════════════════════════
//  APP
// ═══════════════════════════════════════════
class CameraApp extends StatelessWidget {
  const CameraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'كاميرا AI Pro',
      theme: ThemeData(
        dark: true,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E676),
          brightness: Brightness.dark,
        ),
      ),
      home: const CameraScreen(),
    );
  }
}

// ═══════════════════════════════════════════
//  MODES
// ═══════════════════════════════════════════
enum CamMode { photo, video, portrait, night, live, burst }

String _modeLabel(CamMode m) => switch (m) {
      CamMode.photo => 'صورة',
      CamMode.video => 'فيديو',
      CamMode.portrait => 'بورتريه',
      CamMode.night => 'ليل',
      CamMode.live => 'لايف',
      CamMode.burst => 'برست',
    };

// ═══════════════════════════════════════════
//  FILTERS
// ═══════════════════════════════════════════
enum CamFilter { normal, warm, cool, vintage, bw, vivid }

String _filterLabel(CamFilter f) => switch (f) {
      CamFilter.normal => 'عادي',
      CamFilter.warm => 'دافئ',
      CamFilter.cool => 'بارد',
      CamFilter.vintage => 'فينتاج',
      CamFilter.bw => 'أبيض وأسود',
      CamFilter.vivid => 'نابض',
    };

// ═══════════════════════════════════════════
//  CAMERA SCREEN
// ═══════════════════════════════════════════
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  // ── Camera ──
  CameraController? _camera;
  int _cameraIndex = 0;
  ResolutionPreset _videoPreset = ResolutionPreset.veryHigh;
  String _qualityLabel = '1080p';

  // ── Mode ──
  CamMode _mode = CamMode.photo;
  CamFilter _filter = CamFilter.normal;
  bool _beauty = false;

  // ── Aspect ──
  String _aspect = '4:3';

  // ── Zoom ──
  double _zoom = 1;
  double _minZoom = 1;
  double _maxZoom = 1;
  double _scaleStartZoom = 1;

  // ── Exposure ─
  double _exposure = 0;
  double _minExposure = 0;
  double _maxExposure = 0;

  // ── Flash ──
  FlashMode _flash = FlashMode.off;

  // ── State ─
  bool _permission = false;
  bool _busy = false;
  bool _recording = false;
  bool _liveRecording = false;
  bool _grid = false;
  bool _hdr = true;
  bool _sound = true;
  bool _timerOn = false;
  bool _mirrorFront = true;

  int _timerSeconds = 3;
  int _recordSeconds = 0;

  String? _lastPhotoPath;
  String? _lastVideoPath;

  // ── Focus ──
  Offset? _focusPos;
  final GlobalKey _previewKey = GlobalKey();

  // ── Timers / Controllers ──
  Timer? _recordTimer;
  Timer? _liveTimer;
  late final AnimationController _flashAnim;
  late final AnimationController _focusAnim;
  late final AnimationController _shutterAnim;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _flashAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _focusAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _shutterAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );

    _start();
  }

  // ── Permissions & Init ──
  Future<void> _start() async {
    await Permission.camera.request();
    await Permission.microphone.request();
    await Gal.requestAccess();

    if (!await Permission.camera.isGranted) {
      _snack('يرجى السماح بالوصول للكاميرا');
      return;
    }

    if (mounted) setState(() => _permission = true);

    if (cameras.isNotEmpty) await _initCamera();
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

    final cam = CameraController(
      cameras[_cameraIndex],
      _videoPreset,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    _camera = cam;

    try {
      await cam.initialize();
      _minZoom = await cam.getMinZoomLevel();
      _maxZoom = await cam.getMaxZoomLevel();
      _zoom = _minZoom;
      await cam.setZoomLevel(_zoom);

      try {
        _minExposure = await cam.getMinExposureOffset();
        _maxExposure = await cam.getMaxExposureOffset();
        _exposure = 0;
      } catch (_) {
        _minExposure = 0;
        _maxExposure = 0;
      }

      try {
        await cam.setFocusMode(FocusMode.auto);
      } catch (_) {}
      try {
        await cam.setExposureMode(ExposureMode.auto);
      } catch (_) {}
      try {
        await cam.setFlashMode(_flash);
      } catch (_) {}
    } catch (e) {
      debugPrint('Cam init: $e');
    }

    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.inactive || s == AppLifecycleState.paused) {
      final old = _camera;
      _camera = null;
      old?.dispose();
    } else if (s == AppLifecycleState.resumed &&
        _permission &&
        cameras.isNotEmpty) {
      _initCamera();
    }
  }

  // ── Switch Camera ──
  Future<void> _switchCamera() async {
    if (cameras.length < 2 || _recording || _busy) return;
    HapticFeedback.mediumImpact();
    _cameraIndex = (_cameraIndex + 1) % cameras.length;
    await _initCamera();
  }

  // ── Flash ──
  Future<void> _cycleFlash() async {
    final cam = _camera;
    if (cam == null) return;
    HapticFeedback.selectionClick();

    setState(() {
      _flash = _flash == FlashMode.off
          ? FlashMode.auto
          : _flash == FlashMode.auto
              ? FlashMode.torch
              : FlashMode.off;
    });
    try {
      await cam.setFlashMode(_flash);
    } catch (_) {}
  }

  // ── Zoom ──
  Future<void> _setZoom(double z) async {
    final cam = _camera;
    if (cam == null) return;
    final v = _cl(z, _minZoom, _maxZoom);
    setState(() => _zoom = v);
    try {
      await cam.setZoomLevel(v);
    } catch (_) {}
  }

  // ── Exposure ──
  Future<void> _setExposure(double v) async {
    final cam = _camera;
    if (cam == null) return;
    setState(() => _exposure = v);
    try {
      await cam.setExposureOffset(v);
    } catch (_) {}
  }

  // ── Tap to Focus ──
  Future<void> _handleTap(TapUpDetails d) async {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) return;

    HapticFeedback.selectionClick();

    final box =
        _previewKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.size.width > 0) {
      final local = box.globalToLocal(d.globalPosition);
      final nx = _cl(local.dx / box.size.width, 0.0, 1.0);
      final ny = _cl(local.dy / box.size.height, 0.0, 1.0);

      try {
        await cam.setFocusPoint(Offset(nx, ny));
        await cam.setExposurePoint(Offset(nx, ny));
        await cam.setFocusMode(FocusMode.auto);
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() => _focusPos = d.globalPosition);
    _focusAnim.forward(from: 0).then((_) async {
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) _focusAnim.reverse();
    });
  }

  // ── Quality ──
  Future<void> _setQuality(String label) async {
    if (_recording || _busy) return;
    HapticFeedback.selectionClick();
    setState(() {
      _qualityLabel = label;
      _videoPreset = label == '4K'
          ? ResolutionPreset.max
          : label == '2K'
              ? ResolutionPreset.high
              : ResolutionPreset.veryHigh;
    });
    await _initCamera();
  }

  // ── Open Last ──
  Future<void> _openLast() async {
    final path = _lastPhotoPath ?? _lastVideoPath;
    if (path == null || !await File(path).exists()) {
      _snack('لا توجد صورة بعد');
      return;
    }
    await OpenFilex.open(path);
  }

  // ── Long-press last (play live video) ──
  Future<void> _playLastLive() async {
    final v = _lastVideoPath;
    if (v == null || !await File(v).exists()) {
      _snack('لا يوجد فيديو');
      return;
    }
    await OpenFilex.open(v);
  }

  // ═══════════════════════════════════════════
  //  CAPTURE
  // ═══════════════════════════════════════════
  Future<void> _capture() async {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized || _busy) return;

    switch (_mode) {
      case CamMode.video:
        await _toggleRecording();
        return;
      case CamMode.live:
        await _captureLive();
        return;
      case CamMode.burst:
        await _captureBurst();
        return;
      default:
        await _capturePhoto();
    }
  }

  Future<void> _capturePhoto() async {
    var cam = _camera;
    if (cam == null || !cam.value.isInitialized) return;

    // Timer
    if (_timerOn) {
      for (int i = _timerSeconds; i > 0; i--) {
        if (!mounted) return;
        setState(() => _recordSeconds = i);
        HapticFeedback.selectionClick();
        await Future.delayed(const Duration(seconds: 1));
      }
      if (mounted) setState(() => _recordSeconds = 0);
      cam = _camera;
      if (cam == null || !cam.value.isInitialized) return;
    }

    setState(() => _busy = true);

    if (_sound) {
      SystemSound.play(SystemSoundType.click);
      HapticFeedback.mediumImpact();
    }
    _flashAnim.forward(from: 0).then((_) {
      if (mounted) _flashAnim.reverse();
    });

    try {
      final shot = await cam.takePicture();
      final bytes = await File(shot.path).readAsBytes();

      final front = cameras[_cameraIndex].lensDirection ==
          CameraLensDirection.front;
      final mirror = front && _mirrorFront;

      final result = await compute(
        _processPhoto,
        <String, dynamic>{
          'bytes': bytes,
          'mode': _mode.index,
          'filter': _filter.index,
          'hdr': _hdr,
          'beauty': _beauty,
          'mirror': mirror,
        },
      );

      await File(shot.path).writeAsBytes(result, flush: true);
      await Gal.putImage(shot.path);

      if (mounted) {
        setState(() {
          _lastPhotoPath = shot.path;
          _lastVideoPath = null;
        });
      }
    } catch (e) {
      debugPrint('Photo: $e');
      _snack('تعذر التقاط الصورة');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Burst (3 shots) ──
  Future<void> _captureBurst() async {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) return;

    setState(() => _busy = true);
    HapticFeedback.mediumImpact();

    final paths = <String>[];

    for (int i = 0; i < 3; i++) {
      try {
        final shot = await cam.takePicture();
        paths.add(shot.path);
        await Future.delayed(const Duration(milliseconds: 300));
      } catch (_) {}
    }

    if (paths.isNotEmpty) {
      final bytes = await File(paths.last).readAsBytes();
      final front = cameras[_cameraIndex].lensDirection ==
          CameraLensDirection.front;
      final mirror = front && _mirrorFront;

      final result = await compute(
        _processPhoto,
        <String, dynamic>{
          'bytes': bytes,
          'mode': 0,
          'filter': _filter.index,
          'hdr': _hdr,
          'beauty': false,
          'mirror': mirror,
        },
      );
      await File(paths.last).writeAsBytes(result, flush: true);
      await Gal.putImage(paths.last);

      if (mounted) setState(() => _lastPhotoPath = paths.last);
    }

    if (mounted) {
      setState(() => _busy = false);
      _snack('تم التقاط ${paths.length} صور');
    }
  }

  // ── LIVE Photo ──
  Future<void> _captureLive() async {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) return;

    setState(() {
      _busy = true;
      _liveRecording = true;
    });

    HapticFeedback.mediumImpact();

    try {
      // Start video
      await cam.startVideoRecording();

      // Wait 1.5s then take photo
      await Future.delayed(const Duration(milliseconds: 1500));

      String? photoPath;
      if (_camera != null && _camera!.value.isInitialized) {
        final shot = await _camera!.takePicture();
        photoPath = shot.path;

        final bytes = await File(shot.path).readAsBytes();
        final front = cameras[_cameraIndex].lensDirection ==
            CameraLensDirection.front;
        final mirror = front && _mirrorFront;

        final result = await compute(
          _processPhoto,
          <String, dynamic>{
            'bytes': bytes,
            'mode': 0,
            'filter': _filter.index,
            'hdr': _hdr,
            'beauty': _beauty,
            'mirror': mirror,
          },
        );
        await File(shot.path).writeAsBytes(result, flush: true);
        await Gal.putImage(shot.path);
      }

      // Wait 0.5s more then stop
      await Future.delayed(const Duration(milliseconds: 500));

      String? videoPath;
      if (_camera != null && _camera!.value.isInitialized) {
        final video = await _camera!.stopVideoRecording();
        videoPath = video.path;
        await Gal.putVideo(video.path);
      }

      if (mounted) {
        setState(() {
          _lastPhotoPath = photoPath;
          _lastVideoPath = videoPath;
        });
        _snack('تم حفظ اللايف فوتو');
      }
    } catch (e) {
      debugPrint('Live: $e');
      _snack('تعذر تسجيل اللايف فوتو');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _liveRecording = false;
        });
      }
    }
  }

  // ── Video Recording ──
  Future<void> _toggleRecording() async {
    final cam = _camera;
    if (cam == null || !cam.value.isInitialized) return;

    try {
      if (_recording) {
        _recordTimer?.cancel();
        final video = await cam.stopVideoRecording();

        if (mounted) {
          setState(() {
            _recording = false;
            _recordSeconds = 0;
            _lastVideoPath = video.path;
          });
        }
        await Gal.putVideo(video.path);
        _snack('تم حفظ الفيديو');
      } else {
        await cam.startVideoRecording();
        if (mounted) {
          setState(() {
            _recording = true;
            _recordSeconds = 0;
          });
        }
        _recordTimer = Timer.periodic(
          const Duration(seconds: 1),
          (_) {
            if (mounted) setState(() => _recordSeconds++);
          },
        );
      }
    } catch (e) {
      debugPrint('Video: $e');
      _snack('تعذر بدء الفيديو');
    }
  }

  // ── Settings Sheet ──
  void _showSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: DraggableScrollableSheet(
            initialChildSize: 0.6,
            minChildSize: 0.4,
            maxChildSize: 0.9,
            expand: false,
            builder: (ctx, scrollCtrl) => ListView(
              controller: scrollCtrl,
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '⚙️ إعدادات الكاميرا',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                _switch('تحسين الألوان (HDR)', _hdr, (v) {
                  setState(() => _hdr = v);
                  setSheet(() {});
                }),
                _switch('صوت التصوير', _sound, (v) {
                  setState(() => _sound = v);
                  setSheet(() {});
                }),
                _switch('شبكة التقسيم', _grid, (v) {
                  setState(() => _grid = v);
                  setSheet(() {});
                }),
                _switch('مؤقت 3 ثوانٍ', _timerOn, (v) {
                  setState(() => _timerOn = v);
                  setSheet(() {});
                }),
                _switch('تنعيم البشرة (Beauty)', _beauty, (v) {
                  setState(() => _beauty = v);
                  setSheet(() {});
                }),
                _switch('حفظ السيلفي بمعاينة', _mirrorFront, (v) {
                  setState(() => _mirrorFront = v);
                  setSheet(() {});
                }),
                const Divider(color: Colors.white12),
                const Text(
                  'المؤقت',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Row(
                  children: [
                    _chip('3s', _timerSeconds == 3, () {
                      setState(() => _timerSeconds = 3);
                      setSheet(() {});
                    }),
                    const SizedBox(width: 8),
                    _chip('10s', _timerSeconds == 10, () {
                      setState(() => _timerSeconds = 10);
                      setSheet(() {});
                    }),
                  ],
                ),
                const SizedBox(height: 12),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text(
                      'إغلاق',
                      style: TextStyle(color: Colors.greenAccent),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _switch(String label, bool val, void Function(bool) cb) {
    return SwitchListTile(
      title: Text(label),
      value: val,
      activeColor: Colors.greenAccent,
      onChanged: cb,
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? Colors.greenAccent : Colors.white10,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.black : Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  // ── Helpers ──
  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF2A2A3E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  double get _aspectValue => switch (_aspect) {
        '1:1' => 1.0,
        '16:9' => 9 / 16,
        _ => 3 / 4,
      };

  List<double> _zoomChips() {
    final chips = <double>[1.0];
    if (_maxZoom >= 2.1) chips.add(2.0);
    if (_maxZoom >= 4.6) chips.add(5.0);
    final mx = double.parse(_maxZoom.toStringAsFixed(1));
    if (mx > 5.1) chips.add(mx);
    chips.sort();
    return chips;
  }

  IconData _flashIcon() => switch (_flash) {
        FlashMode.auto => Icons.flash_auto,
        FlashMode.torch || FlashMode.always => Icons.flash_on,
        _ => Icons.flash_off,
      };

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordTimer?.cancel();
    _liveTimer?.cancel();
    _flashAnim.dispose();
    _focusAnim.dispose();
    _shutterAnim.dispose();
    _camera?.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final cam = _camera;

    if (!_permission) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.camera_off, size: 64, color: Colors.white38),
              SizedBox(height: 16),
              Text(
                'يرجى السماح باستخدام الكاميرا',
                style: TextStyle(fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    if (cameras.isEmpty) {
      return const Scaffold(
        body: Center(
          child: Text('لا توجد كاميرا متاحة'),
        ),
      );
    }

    if (cam == null || !cam.value.isInitialized) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Colors.greenAccent),
        ),
      );
    }

    final front =
        cameras[_cameraIndex].lensDirection == CameraLensDirection.front;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Preview ──
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: (_) => _scaleStartZoom = _zoom,
            onScaleUpdate: (d) {
              final next = _cl(_scaleStartZoom * d.scale, _minZoom, _maxZoom);
              if ((next - _zoom).abs() < 0.02) return;
              setState(() => _zoom = next);
              cam.setZoomLevel(next).catchError((_) {});
            },
            onTapUp: _handleTap,
            child: Center(
              child: AspectRatio(
                aspectRatio: _aspectValue,
                child: Transform(
                  alignment: Alignment.center,
                  transform: front
                      ? Matrix4.rotationY(math.pi)
                      : Matrix4.identity(),
                  child: CameraPreview(cam, key: _previewKey),
                ),
              ),
            ),
          ),

          // ── Flash overlay ──
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _flashAnim,
              builder: (_, __) => Opacity(
                opacity: _flashAnim.value,
                child: Container(color: Colors.white),
              ),
            ),
          ),

          // ── Grid ─
          if (_grid)
            IgnorePointer(
              child: CustomPaint(painter: _GridPainter()),
            ),

          // ── Focus indicator ──
          if (_focusPos != null)
            IgnorePointer(
              child: AnimatedBuilder(
                animation: _focusAnim,
                builder: (_, __) {
                  final v = Curves.easeOut.transform(_focusAnim.value);
                  return Positioned(
                    left: _focusPos!.dx - 36,
                    top: _focusPos!.dy - 36,
                    child: Opacity(
                      opacity: _cl(v, 0.0, 1.0),
                      child: Transform.scale(
                        scale: 1.5 - 0.5 * v,
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.yellowAccent,
                              width: 2.5,
                            ),
                          ),
                          child: Center(
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.yellowAccent,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

          // ── Top bar ──
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            right: 12,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Flash
                _topBtn(
                  icon: _flashIcon(),
                  color: _flash == FlashMode.off
                      ? Colors.white
                      : Colors.yellowAccent,
                  onTap: _cycleFlash,
                ),
                // Zoom text
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    '${_zoom.toStringAsFixed(1)}×',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                // Settings
                _topBtn(
                  icon: Icons.tune,
                  color: Colors.white,
                  onTap: _showSettings,
                ),
                // Aspect
                _topBtn(
                  icon: null,
                  text: _aspect,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _aspect = switch (_aspect) {
                        '4:3' => '16:9',
                        '16:9' => '1:1',
                        _ => '4:3',
                      };
                    });
                  },
                ),
              ],
            ),
          ),

          // ── Recording indicator ──
          if (_recording || _recordSeconds > 0 || _liveRecording)
            Positioned(
              top: MediaQuery.of(context).padding.top + 52,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black70,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    _liveRecording
                        ? '● لايف فوتو'
                        : _mode == CamMode.video && _recording
                            ? '● ${_recordSeconds}s'
                            : '$_recordSeconds',
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ),

          // ── Exposure slider (right side) ──
          if (_maxExposure > _minExposure)
            Positioned(
              right: 4,
              top: MediaQuery.of(context).padding.top + 90,
              bottom: 320,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.brightness_6,
                        color: Colors.white70,
                        size: 18,
                      ),
                      SizedBox(
                        height: 140,
                        width: 44,
                        child: RotatedBox(
                          quarterTurns: -1,
                          child: SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 3,
                              thumbShape:
                                  const RoundSliderThumbShape(
                                enabledThumbRadius: 8,
                              ),
                              overlayShape:
                                  const RoundSliderOverlayShape(
                                overlayRadius: 14,
                              ),
                            ),
                            child: Slider(
                              value: _cl(_exposure, _minExposure, _maxExposure),
                              min: _minExposure,
                              max: _maxExposure,
                              divisions: 8,
                              activeColor: Colors.yellowAccent,
                              inactiveColor: Colors.white24,
                              onChanged: _setExposure,
                            ),
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => _setExposure(0),
                        child: const Icon(
                          Icons.refresh,
                          color: Colors.white54,
                          size: 18,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ── Bottom controls ──
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 12,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Zoom chips
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final z in _zoomChips())
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: _zoomChip(z),
                      ),
                  ],
                ),
                const SizedBox(height: 10),

                // Mode buttons
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (final m in CamMode.values)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: _modeBtn(m),
                        ),
                    ],
                  ),
                ),

                // Filter row (photo/portrait/night)
                if (_mode == CamMode.photo ||
                    _mode == CamMode.portrait ||
                    _mode == CamMode.night)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (final f in CamFilter.values)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 3),
                              child: _filterChip(f),
                            ),
                        ],
                      ),
                    ),
                  ),

                // Video quality
                if (_mode == CamMode.video)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _qualityChip('1080p'),
                        const SizedBox(width: 6),
                        _qualityChip('2K'),
                        const SizedBox(width: 6),
                        _qualityChip('4K'),
                      ],
                    ),
                  ),

                const SizedBox(height: 14),

                // Main buttons row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Gallery / Last
                    GestureDetector(
                      onTap: _openLast,
                      onLongPress: _playLastLive,
                      child: Container(
                        width: 50,
                        height: 50,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white54,
                            width: 1.5,
                          ),
                          color: Colors.black54,
                        ),
                        child: _lastPhotoPath != null &&
                                File(_lastPhotoPath!).existsSync()
                            ? Stack(
                                fit: StackFit.expand,
                                children: [
                                  Image.file(
                                    File(_lastPhotoPath!),
                                    fit: BoxFit.cover,
                                  ),
                                  if (_lastVideoPath != null)
                                    Positioned(
                                      top: 2,
                                      left: 2,
                                      child: Container(
                                        padding: const EdgeInsets.all(2),
                                        decoration: BoxDecoration(
                                          color: Colors.black87,
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: const Icon(
                                          Icons.play_circle,
                                          size: 12,
                                          color: Colors.greenAccent,
                                        ),
                                      ),
                                    ),
                                ],
                              )
                            : const Icon(
                                Icons.photo_library,
                                color: Colors.white70,
                                size: 24,
                              ),
                      ),
                    ),

                    // Shutter
                    GestureDetector(
                      onTap: _busy ? null : _capture,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 76,
                        height: 76,
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _recording
                                ? Colors.redAccent
                                : Colors.white,
                            width: 3,
                          ),
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            color: _mode == CamMode.video
                                ? Colors.redAccent
                                : _mode == CamMode.live
                                    ? Colors.purpleAccent
                                    : Colors.white,
                            shape: _mode == CamMode.video && _recording
                                ? BoxShape.rectangle
                                : BoxShape.circle,
                            borderRadius:
                                _mode == CamMode.video && _recording
                                    ? BorderRadius.circular(10)
                                    : null,
                          ),
                          child: _busy
                              ? const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.black,
                                  ),
                                )
                              : _recording
                                  ? const Icon(
                                      Icons.stop,
                                      color: Colors.white,
                                      size: 32,
                                    )
                                  : null,
                        ),
                      ),
                    ),

                    // Switch camera
                    GestureDetector(
                      onTap: _switchCamera,
                      child: Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black54,
                          border: Border.all(color: Colors.white54, width: 1.5),
                        ),
                        child: const Icon(
                          Icons.cameraswitch,
                          color: Colors.white,
                          size: 26,
                        ),
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

  // ── Small widgets ──
  Widget _topBtn({
    IconData? icon,
    String? text,
    Color color = Colors.white,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.black45,
          shape: BoxShape.circle,
        ),
        child: icon != null
            ? Icon(icon, color: color, size: 22)
            : Text(
                text!,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
      ),
    );
  }

  Widget _zoomChip(double z) {
    final active = (_zoom - z).abs() < 0.15;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        _setZoom(z);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? Colors.white : Colors.black54,
          border: Border.all(
            color: active ? Colors.white : Colors.white24,
            width: 1.5,
          ),
        ),
        child: Text(
          z == z.roundToDouble() ? '${z.round()}×' : '${z.toStringAsFixed(1)}×',
          style: TextStyle(
            color: active ? Colors.black : Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _modeBtn(CamMode m) {
    final sel = _mode == m;
    final color = m == CamMode.video
        ? Colors.redAccent
        : m == CamMode.live
            ? Colors.purpleAccent
            : m == CamMode.night
                ? Colors.blueAccent
                : Colors.greenAccent;

    return GestureDetector(
      onTap: () {
        if (_recording) return;
        HapticFeedback.selectionClick();
        setState(() => _mode = m);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: sel ? color.withOpacity(0.2) : Colors.black45,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: sel ? color : Colors.transparent),
        ),
        child: Text(
          _modeLabel(m),
          style: TextStyle(
            color: sel ? color : Colors.white70,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _filterChip(CamFilter f) {
    final sel = _filter == f;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _filter = f);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: sel ? Colors.white : Colors.black45,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          _filterLabel(f),
          style: TextStyle(
            color: sel ? Colors.black : Colors.white70,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _qualityChip(String label) {
    final sel = _qualityLabel == label;
    return GestureDetector(
      onTap: () => _setQuality(label),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: sel ? Colors.redAccent.withOpacity(0.2) : Colors.black54,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: sel ? Colors.redAccent : Colors.white24),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: sel ? Colors.redAccent : Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════
//  IMAGE PROCESSING (in isolate)
// ═══════════════════════════════════════════

Uint8List _processPhoto(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final mode = args['mode'] as int;
  final filterIdx = args['filter'] as int;
  final hdr = args['hdr'] as bool;
  final beauty = args['beauty'] as bool;
  final mirror = args['mirror'] == true;

  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;

  var photo = img.bakeOrientation(decoded);
  if (mirror) photo = img.flipHorizontal(photo);

  // ── Light detection ──
  final sw = 96;
  final sh = (photo.height * sw / photo.width).round().clamp(1, 9999);
  final sample = img.copyResize(photo, width: sw, height: sh);

  double sum = 0;
  final total = sw * sh;
  for (var y = 0; y < sh; y++) {
    for (var x = 0; x < sw; x++) {
      final p = sample.getPixel(x, y);
      sum += 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b;
    }
  }
  final mean = total > 0 ? sum / total : 128.0;

  // ── Auto brightness ──
  double brightness = 1.0;
  if (mean > 180) {
    brightness = 0.86;
  } else if (mean > 155) {
    brightness = 0.94;
  } else if (mean < 50) {
    brightness = 1.5;
  } else if (mean < 80) {
    brightness = 1.3;
  } else if (mean < 105) {
    brightness = 1.12;
  }

  // ── Mode adjustments ──
  double contrast = hdr ? 1.08 : 1.04;
  double saturation = hdr ? 1.10 : 1.05;
  double gamma = 1.0;

  if (mode == 3) {
    // Night
    if (brightness < 1.35) brightness = 1.35;
    if (brightness > 1.65) brightness = 1.65;
    contrast = 1.06;
    saturation = 1.18;
    gamma = 0.92;
  }

  if (mode == 2) {
    // Portrait - slightly softer
    contrast = 1.04;
    saturation = 1.06;
  }

  // ── Apply color adjustments ──
  photo = img.adjustColor(
    photo,
    brightness: brightness,
    contrast: contrast,
    saturation: saturation,
    gamma: gamma,
  );

  // ── Beauty (skin smoothing) ──
  if (beauty) {
    final blurred = img.gaussianBlur(photo, radius: 3);
    final out = img.Image(width: photo.width, height: photo.height);
    for (var y = 0; y < photo.height; y++) {
      for (var x = 0; x < photo.width; x++) {
        final f = photo.getPixel(x, y);
        final b = blurred.getPixel(x, y);
        out.setPixelRgba(
          x,
          y,
          (f.r * 0.6 + b.r * 0.4).round(),
          (f.g * 0.6 + b.g * 0.4).round(),
          (f.b * 0.6 + b.b * 0.4).round(),
          255,
        );
      }
    }
    photo = out;
  }

  // ── Filter ──
  photo = _applyFilter(photo, filterIdx);

  return Uint8List.fromList(img.encodeJpg(photo, quality: 95));
}

img.Image _applyFilter(img.Image img, int idx) {
  switch (idx) {
    case 1: // Warm
      return _colorMatrix(img, [
        1.1, 0.05, 0, 0,
        0.02, 1.0, 0, 0,
        0, 0, 0.9, 0,
      ]);
    case 2: // Cool
      return _colorMatrix(img, [
        0.9, 0, 0.05, 0,
        0, 1.0, 0, 0,
        0, 0, 1.1, 0,
      ]);
    case 3: // Vintage
      return _colorMatrix(img, [
        0.9, 0.1, 0.05, 0,
        0.05, 0.9, 0.05, 0,
        0, 0, 0.8, 0,
      ]);
    case 4: // B&W
      return _colorMatrix(img, [
        0.299, 0.587, 0.114, 0,
        0.299, 0.587, 0.114, 0,
        0.299, 0.587, 0.114, 0,
      ]);
    case 5: // Vivid
      return _colorMatrix(img, [
        1.15, 0, 0, 0,
        0, 1.15, 0, 0,
        0, 0, 1.15, 0,
      ]);
    default:
      return img;
  }
}

img.Image _colorMatrix(img.Image src, List<double> m) {
  final out = img.Image(width: src.width, height: src.height);
  for (var y = 0; y < src.height; y++) {
    for (var x = 0; x < src.width; x++) {
      final p = src.getPixel(x, y);
      final r = _cl(
        m[0] * p.r + m[1] * p.g + m[2] * p.b + m[3],
        0,
        255,
      ).round();
      final g = _cl(
        m[4] * p.r + m[5] * p.g + m[6] * p.b + m[7],
        0,
        255,
      ).round();
      final b = _cl(
        m[8] * p.r + m[9] * p.g + m[10] * p.b + m[11],
        0,
        255,
      ).round();
      out.setPixelRgba(x, y, r, g, b, 255);
    }
  }
  return out;
}

// ── Portrait processing ──
Uint8List _processPortrait(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final mw = args['width'] as int;
  final mh = args['height'] as int;
  final mask = (args['mask'] as List).cast<double>();
  final mirror = args['mirror'] == true;
  final filterIdx = args['filter'] as int;
  final beauty = args['beauty'] as bool;

  final decoded = img.decodeImage(bytes);
  if (decoded == null || mw <= 0 || mh <= 0 || mask.isEmpty) return bytes;

  var fg = img.bakeOrientation(decoded);
  final w = fg.width;
  final h = fg.height;
  if (w <= 0 || h <= 0) return bytes;

  // Alpha map
  final alpha = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    final my = _ci((y * mh) ~/ h, 0, mh - 1);
    for (var x = 0; x < w; x++) {
      final mx = _ci((x * mw) ~/ w, 0, mw - 1);
      final i = my * mw + mx;
      double a = i < mask.length ? mask[i] : 0.0;
      a = _cl(a, 0.0, 1.0);
      a = _cl((a - 0.3) / 0.4, 0.0, 1.0);
      a = a * a * (3 - 2 * a); // smoothstep
      alpha[y * w + x] = a;
    }
  }

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

  // Smooth edges
  _boxBlurAlpha(alpha, w, h);

  // Bokeh background (fast)
  final sw = (w / 6).round().clamp(8, 9999);
  final sh = (h * sw / w).round().clamp(8, 9999);
  final bg = img.copyResize(
    img.gaussianBlur(
      img.copyResize(fg, width: sw, height: sh),
      radius: 6,
    ),
    width: w,
    height: h,
  );

  // Composite
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

  // Beauty on foreground
  if (beauty) {
    final blurred = img.gaussianBlur(out, radius: 2);
    final final2 = img.Image(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final a = alpha[y * w + x];
        if (a > 0.5) {
          final f = out.getPixel(x, y);
          final b = blurred.getPixel(x, y);
          final2.setPixelRgba(
            x,
            y,
            (f.r * 0.6 + b.r * 0.4).round(),
            (f.g * 0.6 + b.g * 0.4).round(),
            (f.b * 0.6 + b.b * 0.4).round(),
            255,
          );
        } else {
          final2.setPixel(x, y, out.getPixel(x, y));
        }
      }
    }
    return Uint8List.fromList(img.encodeJpg(final2, quality: 95));
  }

  return Uint8List.fromList(img.encodeJpg(out, quality: 95));
}

void _boxBlurAlpha(Float32List a, int w, int h) {
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

double _cl(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);
int _ci(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

// ═══════════════════════════════════════════
//  GRID PAINTER
// ═══════════════════════════════════════════
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white24
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
  bool shouldRepaint(covariant CustomPainter old) => false;
}
