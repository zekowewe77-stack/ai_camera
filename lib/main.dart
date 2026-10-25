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

  String _qualityLabel = '1080p • 30 إطار';
  ResolutionPreset _videoPreset = ResolutionPreset.veryHigh;

  final int _fps = 30;

  double _zoom = 1;
  double _minZoom = 1;
  double _maxZoom = 1;
  double _scaleStartZoom = 1;

  FlashMode _flash = FlashMode.off;

  bool _permission = false;
  bool _busy = false;
  bool _recording = false;

  bool _grid = false;
  bool _hdr = true;
  bool _sound = true;
  bool _timerOn = false;

  int _timerSeconds = 3;
  int _recordSeconds = 0;

  String? _lastPath;

  Timer? _recordTimer;
  late final AnimationController _flashAnimation;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _flashAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
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
      await old.dispose();
    }

    final camera = CameraController(
      cameras[_cameraIndex],
      _videoPreset,
      enableAudio: true,
      fps: _fps,
      videoBitrate:
          _videoPreset == ResolutionPreset.max ? 20000000 : 12000000,
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

  Future<void> _capture() async {
    final camera = _camera;

    if (camera == null ||
        !camera.value.isInitialized ||
        _busy) {
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
    }

    setState(() => _busy = true);

    try {
      if (_sound) {
        SystemSound.play(SystemSoundType.click);
        HapticFeedback.lightImpact();
      }

      _flashAnimation.forward(from: 0).then((_) {
        if (mounted) {
          _flashAnimation.reverse();
        }
      });

      final shot = await camera.takePicture();
      final bytes = await File(shot.path).readAsBytes();

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
          },
        );
      }

      await File(shot.path).writeAsBytes(
        result,
        flush: true,
      );

      await Gal.putImage(shot.path);

      if (mounted) {
        setState(() => _lastPath = shot.path);
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

    if (camera == null ||
        !camera.value.isInitialized ||
        _busy) {
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

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('تم حفظ الفيديو في المعرض'),
            ),
          );
        }
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
    if (_recording) return;

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

    _flash = _flash == FlashMode.off
        ? FlashMode.torch
        : FlashMode.off;

    try {
      await camera.setFlashMode(_flash);
    } catch (_) {}

    if (mounted) {
      setState(() {});
    }
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
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text('يرجى السماح باستخدام الكاميرا'),
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
          Positioned.fill(
            child: GestureDetector(
              onScaleStart: (_) => _scaleStartZoom = _zoom,
              onScaleUpdate: (d) async {
                final next = (_scaleStartZoom * d.scale)
                    .clamp(_minZoom, _maxZoom);

                setState(() => _zoom = next);

                try {
                  await camera.setZoomLevel(next);
                } catch (_) {}
              },
              child: Center(
                child: AspectRatio(
                  aspectRatio: _aspectValue,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: front
                        ? Matrix4.rotationY(3.1415926)
                        : Matrix4.identity(),
                    child: CameraPreview(camera),
                  ),
                ),
              ),
            ),
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
          if (_grid)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _GridPainter()),
              ),
            ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x66000000),
                child: Center(
                  child: CircularProgressIndicator(
                    color: Colors.greenAccent,
                  ),
                ),
              ),
            ),
          Positioned(
            top: 38,
            left: 8,
            right: 8,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  onPressed: _toggleFlash,
                  icon: Icon(
                    _flash == FlashMode.off
                        ? Icons.flash_off
                        : Icons.flash_on,
                    color: Colors.white,
                  ),
                ),
                Text(
                  '${_zoom.toStringAsFixed(1)}× / ${_maxZoom.toStringAsFixed(1)}×',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  onPressed: _showSettings,
                  icon: const Icon(Icons.tune, color: Colors.white),
                ),
                IconButton(
                  onPressed: () => setState(() {
                    _aspect = _aspect == '4:3'
                        ? '16:9'
                        : _aspect == '16:9'
                            ? 'Full'
                            : '4:3';
                  }),
                  icon: Text(
                    _aspect,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
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
          Positioned(
            bottom: 25,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                const SizedBox(height: 12),
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
                      onTap: _capture,
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
                          child: _recording
                              ? const Icon(
                                  Icons.stop,
                                  color: Colors.white,
                                  size: 30,
                                )
                              : null,
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
        ],
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

Uint8List _photoBytes(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final decoded = img.decodeImage(bytes);

  if (decoded == null) return bytes;

  final oriented = img.bakeOrientation(decoded);

  final zoom = (args['zoom'] as num).toDouble();
  final hdr = args['hdr'] as bool;
  final night = args['night'] as bool;

  final fixed = img.adjustColor(
    oriented,
    contrast: night ? 1.08 : (hdr ? 1.05 : 1.01),
    brightness: night ? 1.04 : 1.01,
    saturation: hdr ? 1.04 : 1.01,
  );

  // تحسين معتدل حتى لا تتشوه الحروف والتفاصيل مع الزوم.
  return Uint8List.fromList(
    img.encodeJpg(
      fixed,
      quality: zoom > 4 ? 96 : 97,
    ),
  );
}

Uint8List _portraitBytes(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final mw = args['width'] as int;
  final mh = args['height'] as int;
  final mask = (args['mask'] as List).cast<double>();

  final decoded = img.decodeImage(bytes);

  if (decoded == null || mw <= 0 || mh <= 0 || mask.isEmpty) {
    return bytes;
  }

  final fg = img.bakeOrientation(decoded);
  final bg = img.gaussianBlur(fg, radius: 10);
  final out = img.Image(width: fg.width, height: fg.height);

  for (var y = 0; y < fg.height; y++) {
    final my = ((y * mh) / fg.height)
        .floor()
        .clamp(0, mh - 1);

    for (var x = 0; x < fg.width; x++) {
      final mx = ((x * mw) / fg.width)
          .floor()
          .clamp(0, mw - 1);

      final i = my * mw + mx;

      final a = (i < mask.length ? mask[i] : 0.0)
          .clamp(0.0, 1.0);

      final f = fg.getPixel(x, y);
      final b = bg.getPixel(x, y);

      final alpha = ((a - 0.25) / 0.5)
          .clamp(0.0, 1.0);

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

  return Uint8List.fromList(
    img.encodeJpg(out, quality: 96),
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