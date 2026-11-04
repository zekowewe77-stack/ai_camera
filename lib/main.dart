
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
      title: 'AI Camera Pro Ultra',
      theme: ThemeData.dark(useMaterial3: true),
      home: const CameraScreen(),
    );
  }
}

class CapturedItem {
  final String path;
  final String? liveVideoPath;
  final bool isVideo;
  final String mode;
  final DateTime time;

  CapturedItem({
    required this.path,
    this.liveVideoPath,
    required this.isVideo,
    required this.mode,
    required this.time,
  });
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

  String _mode = 'PHOTO'; // VIDEO, PHOTO, PORTRAIT, NIGHT, PRO
  String _aspect = '4:3';
  String _style = 'AI'; // AI, VIVID, WARM, COOL, CINEMA, BW
  String _gridType = 'OFF'; // OFF, 3x3, GOLDEN, CROSS

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

  // فتحة العدسة في وضع البورتريه (درجة العزل)
  double _aperture = 2.0; // f/1.4 to f/5.6

  Offset? _focusPoint;
  bool _aeAfLocked = false;
  Timer? _focusTimer;

  FlashMode _flash = FlashMode.off;

  bool _permission = false;
  bool _busy = false;
  bool _recording = false;

  // الميزات الاحترافية
  bool _livePhoto = false;
  bool _liveCapturing = false;
  bool _screenFlashOverlay = false;
  bool _hdr = true;
  bool _beauty = true;
  bool _vignette = false;
  bool _sound = true;
  bool _mirrorFront = true;
  bool _showStyles = false;

  int _timerSeconds = 0; // 0 = إيقاف, 3 = 3ث, 10 = 10ث
  int _recordSeconds = 0;

  final List<CapturedItem> _history = [];

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
    _aeAfLocked = false;

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
    BoxConstraints constraints, {
    bool lock = false,
  }) async {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;

    final nx =
        (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
    final ny =
        (details.localPosition.dy / constraints.maxHeight).clamp(0.0, 1.0);

    HapticFeedback.selectionClick();

    setState(() {
      _focusPoint = details.localPosition;
      _aeAfLocked = lock;
    });

    _focusTimer?.cancel();
    if (!lock) {
      _focusTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && !_aeAfLocked) {
          setState(() => _focusPoint = null);
        }
      });
    }

    try {
      await camera.setFocusPoint(Offset(nx, ny));
      await camera.setFocusMode(lock ? FocusMode.locked : FocusMode.auto);
    } catch (_) {}

    try {
      await camera.setExposurePoint(Offset(nx, ny));
      await camera.setExposureMode(
        lock ? ExposureMode.locked : ExposureMode.auto,
      );
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

    if (_timerSeconds > 0) {
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

    final isFront =
        cameras[_cameraIndex].lensDirection == CameraLensDirection.front;

    try {
      // فلاش الشاشة الأمامي للسيلفي الليلي (Retina Flash)
      if (isFront && _flash != FlashMode.off) {
        setState(() => _screenFlashOverlay = true);
        await Future.delayed(const Duration(milliseconds: 300));
      }

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

      if (_screenFlashOverlay && mounted) {
        setState(() => _screenFlashOverlay = false);
      }

      final bytes = await File(shot.path).readAsBytes();
      Uint8List result = bytes;

      // حساب نصف قطر العزل بناءً على فتحة العدسة المختارة f-stop
      final blurStrength = ((6.5 - _aperture) * 2.2).round().clamp(3, 12);

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
                'beauty': _beauty,
                'vignette': _vignette,
                'style': _style,
                'blur': blurStrength,
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
            'beauty': _beauty && isFront,
            'vignette': _vignette,
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

      String? liveClipPath;

      // خاصية Live Photo مثل الآيفون
      if (_livePhoto && _mode == 'PHOTO') {
        if (mounted) {
          setState(() {
            _busy = false;
            _liveCapturing = true;
          });
        }
        try {
          await camera.startVideoRecording();
          await Future.delayed(const Duration(milliseconds: 1500));
          final liveClip = await camera.stopVideoRecording();
          liveClipPath = liveClip.path;
          await Gal.putVideo(liveClip.path);
        } catch (_) {
        } finally {
          if (mounted) {
            setState(() => _liveCapturing = false);
          }
        }
      }

      if (mounted) {
        setState(() {
          _history.insert(
            0,
            CapturedItem(
              path: shot.path,
              liveVideoPath: liveClipPath,
              isVideo: false,
              mode: _livePhoto ? 'LIVE PHOTO' : _mode,
              time: DateTime.now(),
            ),
          );
        });
      }
    } catch (e) {
      debugPrint('Capture failed: $e');

      if (mounted) {
        setState(() => _screenFlashOverlay = false);
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

        await Gal.putVideo(video.path);

        if (mounted) {
          setState(() {
            _recording = false;
            _recordSeconds = 0;
            _history.insert(
              0,
              CapturedItem(
                path: video.path,
                isVideo: true,
                mode: 'VIDEO $_qualityLabel',
                time: DateTime.now(),
              ),
            );
          });

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

  void _openGalleryStudio() {
    if (_history.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('لا توجد صور أو فيديوهات ملتقطة بعد'),
        ),
      );
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black,
      builder: (ctx) => _InAppGalleryViewer(
        items: _history,
        onDelete: (item) {
          setState(() => _history.remove(item));
        },
      ),
    );
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
    } catch (_) {}

    if (mounted) {
      setState(() {});
    }
  }

  IconData get _flashIcon => switch (_flash) {
        FlashMode.off => Icons.flash_off,
        FlashMode.auto => Icons.flash_auto,
        FlashMode.always => Icons.flash_on,
        FlashMode.torch => Icons.highlight,
      };

  void _cycleTimer() {
    HapticFeedback.selectionClick();
    setState(() {
      _timerSeconds = switch (_timerSeconds) {
        0 => 3,
        3 => 10,
        _ => 0,
      };
    });
  }

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
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CustomPaint(
                    size: const Size(28, 28),
                    painter: _ProLensLogoPainter(),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'إعدادات الاستوديو الاحترافي AI Pro',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('موازنة الإضاءة الذكية (Smart HDR+)'),
                subtitle: const Text('منع احتراق الشمس وتفتيح الظلال تلقائياً'),
                value: _hdr,
                onChanged: (v) {
                  setState(() => _hdr = v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('تجميل وتنعيم البشرة الذكي (AI Beauty)'),
                subtitle: const Text('تنعيم طبيعي للبشرة في السيلفي والبورتريه'),
                value: _beauty,
                onChanged: (v) {
                  setState(() => _beauty = v);
                  setSheet(() {});
                },
              ),
              SwitchListTile(
                title: const Text('تأثير التركيز السينمائي (Cinema Vignette)'),
                subtitle: const Text('تغميق خفيف لأطراف الصورة لإبراز الهدف'),
                value: _vignette,
                onChanged: (v) {
                  setState(() => _vignette = v);
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
              ListTile(
                title: const Text('نوع الشبكة الهندسية (Grid)'),
                trailing: DropdownButton<String>(
                  value: _gridType,
                  dropdownColor: const Color(0xFF222222),
                  items: const [
                    DropdownMenuItem(value: 'OFF', child: Text('إيقاف')),
                    DropdownMenuItem(value: '3x3', child: Text('أثلاث 3×3')),
                    DropdownMenuItem(
                      value: 'GOLDEN',
                      child: Text('النسبة الذهبية'),
                    ),
                    DropdownMenuItem(
                      value: 'CROSS',
                      child: Text('ميزان المركزي +'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _gridType = v);
                      setSheet(() {});
                    }
                  },
                ),
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

  String get _aiSceneStatus {
    if (_aeAfLocked) return '🔒 AE/AF LOCKED';
    if (_mode == 'PORTRAIT') {
      return 'بورتريه استوديو • f/${_aperture.toStringAsFixed(1)}';
    }
    if (_mode == 'NIGHT') return '🌙 رؤية ليلية فائقة AI';
    if (_exposure < -0.5) return '☀️ حماية الإضاءة العالية';
    if (_hdr) return '✨ AI HDR+ نشط';
    return 'كاميرا AI Pro';
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
                size: const Size(76, 76),
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
                size: const Size(68, 68),
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
    final latestItem = _history.isNotEmpty ? _history.first : null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. شاشة عرض الكاميرا مع دعم اللمس للتركيز والضغط المطول لقفل الإضاءة
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
                        onTapUp: (d) =>
                            _onTapFocus(d, constraints, lock: false),
                        onLongPressStart: (d) => _onTapFocus(
                          TapUpDetails(
                            kind: PointerDeviceKind.touch,
                            localPosition: d.localPosition,
                            globalPosition: d.globalPosition,
                          ),
                          constraints,
                          lock: true,
                        ),
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
                            if (_gridType != 'OFF')
                              IgnorePointer(
                                child: CustomPaint(
                                  painter: _GridPainter(_gridType),
                                ),
                              ),
                            if (_focusPoint != null)
                              Positioned(
                                left: (_focusPoint!.dx - 38).clamp(
                                  0.0,
                                  constraints.maxWidth - 76,
                                ),
                                top: (_focusPoint!.dy - 38).clamp(
                                  0.0,
                                  constraints.maxHeight - 76,
                                ),
                                child: IgnorePointer(
                                  child: Container(
                                    width: 76,
                                    height: 76,
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: _aeAfLocked
                                            ? Colors.orangeAccent
                                            : Colors.amberAccent,
                                        width: 1.8,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Center(
                                      child: Icon(
                                        _aeAfLocked
                                            ? Icons.lock
                                            : Icons.wb_sunny,
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

          // 2. فلاش الشاشة الأمامي للسيلفي الليلي + وميض الالتقاط
          if (_screenFlashOverlay)
            Positioned.fill(
              child: Container(color: const Color(0xFFFFF8E7)),
            ),

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

          // 3. شريط موازنة الإضاءة والشمس اليدوي على الجانب الأيمن
          if (_minExposure < _maxExposure)
            Positioned(
              right: 10,
              top: MediaQuery.of(context).size.height * 0.26,
              bottom: MediaQuery.of(context).size.height * 0.37,
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
                      Icons.wb_sunny,
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
                            ? 'EV'
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

          // 5. الشريط العلوي الاحترافي
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xBB101010),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    onPressed: _toggleFlash,
    
