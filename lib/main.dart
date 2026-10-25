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

  List<CameraDescription> cameras = <CameraDescription>[];

  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera discovery failed: $e');
  }

  runApp(MyApp(cameras: cameras));
}

/// التطبيق الرئيسي.
/// وجود MyApp أيضًا يحل مشكلة الاختبار القديم الذي كان يبحث عن MyApp.
class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    this.cameras = const <CameraDescription>[],
  });

  final List<CameraDescription> cameras;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AI Camera Pro 2027',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.greenAccent,
          brightness: Brightness.dark,
        ),
      ),
      home: CameraScreen(cameras: cameras),
    );
  }
}

/// Alias بسيط لو كان عندك أي جزء قديم يستخدم CameraApp.
class CameraApp extends StatelessWidget {
  const CameraApp({
    super.key,
    required this.cameras,
  });

  final List<CameraDescription> cameras;

  @override
  Widget build(BuildContext context) {
    return MyApp(cameras: cameras);
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({
    super.key,
    required this.cameras,
  });

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

  double _zoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _scaleStartZoom = 1.0;

  FlashMode _flash = FlashMode.off;

  bool _permission = false;
  bool _busy = false;
  bool _recording = false;

  bool _grid = false;
  bool _timerOn = false;

  /// Motion Photo / Live Photo-like mode.
  ///
  /// Flutter camera + Gal لا يقدمان هنا صيغة Live Photo الأصلية
  /// الخاصة بالنظام مثل Apple Live Photo.
  ///
  /// لذلك التطبيق يحفظ صورة + مقطع حركة قصير كـ Motion Photo pair.
  bool _livePhoto = false;

  bool _sound = true;

  bool _autoExposure = true;
  bool _autoFocus = true;

  int _timerSeconds = 3;
  int _recordSeconds = 0;

  String? _lastPath;
  String? _lastMotionPath;

  Timer? _recordTimer;

  late final AnimationController _captureAnimation;

  bool get _frontCamera {
    if (widget.cameras.isEmpty) {
      return false;
    }

    return widget.cameras[_cameraIndex].lensDirection ==
        CameraLensDirection.front;
  }

  bool get _cameraReady {
    final camera = _camera;

    return camera != null &&
        camera.value.isInitialized &&
        !camera.value.hasError;
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _captureAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 110),
      lowerBound: 0,
      upperBound: 1,
    );

    _start();
  }

  Future<void> _start() async {
    final cameraPermission = await Permission.camera.request();

    if (!cameraPermission.isGranted) {
      if (!mounted) {
        return;
      }

      setState(() {
        _permission = false;
      });

      return;
    }

    try {
      await Gal.requestAccess();
    } catch (e) {
      debugPrint('Gallery permission request failed: $e');
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _permission = true;
    });

    if (widget.cameras.isEmpty) {
      return;
    }

    await _initCamera();
  }

  Future<void> _initCamera() async {
    if (!mounted || widget.cameras.isEmpty) {
      return;
    }

    final oldController = _camera;

    _camera = null;

    if (mounted) {
      setState(() {});
    }

    if (oldController != null) {
      try {
        await oldController.dispose();
      } catch (_) {}
    }

    final selectedCamera = widget.cameras[_cameraIndex];

    CameraController controller;

    try {
      controller = CameraController(
        selectedCamera,
        _videoPreset,
        enableAudio: true,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
    } catch (e) {
      debugPrint('CameraController creation failed: $e');
      return;
    }

    _camera = controller;

    try {
      await controller.initialize();

      _minZoom = await controller.getMinZoomLevel();
      _maxZoom = await controller.getMaxZoomLevel();

      _zoom = _minZoom;

      await controller.setZoomLevel(_zoom);

      if (_autoFocus) {
        try {
          await controller.setFocusMode(FocusMode.auto);
        } catch (e) {
          debugPrint('Auto focus unavailable: $e');
        }
      } else {
        try {
          await controller.setFocusMode(FocusMode.locked);
        } catch (e) {
          debugPrint('Locked focus unavailable: $e');
        }
      }

      if (_autoExposure) {
        try {
          await controller.setExposureMode(ExposureMode.auto);
        } catch (e) {
          debugPrint('Auto exposure unavailable: $e');
        }
      } else {
        try {
          await controller.setExposureMode(ExposureMode.locked);
        } catch (e) {
          debugPrint('Locked exposure unavailable: $e');
        }
      }

      try {
        await controller.setFlashMode(_flash);
      } catch (e) {
        debugPrint('Flash mode unavailable: $e');
      }
    } catch (e) {
      debugPrint('Camera initialization failed: $e');

      if (identical(_camera, controller)) {
        _camera = null;
      }

      try {
        await controller.dispose();
      } catch (_) {}
    }

    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _recordTimer?.cancel();

      final oldController = _camera;

      _camera = null;

      if (oldController != null) {
        oldController.dispose();
      }

      if (mounted) {
        setState(() {
          _recording = false;
          _recordSeconds = 0;
        });
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_permission && widget.cameras.isNotEmpty) {
        _initCamera();
      }
    }
  }

  Future<void> _switchCamera() async {
    if (widget.cameras.length < 2) {
      return;
    }

    if (_recording || _busy) {
      return;
    }

    setState(() {
      _busy = true;
    });

    _cameraIndex = (_cameraIndex + 1) % widget.cameras.length;

    await _initCamera();

    if (mounted) {
      setState(() {
        _busy = false;
      });
    }
  }

  Future<void> _capture() async {
    final camera = _camera;

    if (camera == null) {
      return;
    }

    if (!camera.value.isInitialized) {
      return;
    }

    if (_busy) {
      return;
    }

    if (_recording) {
      return;
    }

    if (_mode == 'VIDEO') {
      await _toggleRecording();
      return;
    }

    setState(() {
      _busy = true;
    });

    try {
      if (_timerOn) {
        for (int i = _timerSeconds; i > 0; i--) {
          if (!mounted) {
            return;
          }

          setState(() {
            _recordSeconds = i;
          });

          await Future.delayed(
            const Duration(seconds: 1),
          );
        }

        if (mounted) {
          setState(() {
            _recordSeconds = 0;
          });
        }
      }

      await _playShutterFeedback();

      _captureAnimation.forward(from: 0).then((_) {
        if (mounted) {
          _captureAnimation.reverse();
        }
      });

      String? motionPath;

      if (_livePhoto) {
        motionPath = await _captureMotionClip(camera);
      }

      final XFile shot = await camera.takePicture();

      String finalPath = shot.path;

      if (_mode == 'PORTRAIT') {
        finalPath = await _makePortrait(shot.path);
      } else {
        finalPath = await _processNormalPhoto(
          shot.path,
          isFrontCamera: _frontCamera,
        );
      }

      try {
        await Gal.putImage(finalPath);
      } catch (e) {
        debugPrint('Gallery image save failed: $e');
      }

      if (motionPath != null) {
        try {
          await Gal.putVideo(motionPath);
        } catch (e) {
          debugPrint('Motion video save failed: $e');
        }
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _lastPath = finalPath;
        _lastMotionPath = motionPath;
      });

      String message;

      if (_mode == 'PORTRAIT') {
        message = 'تم حفظ صورة البورتريه';
      } else if (motionPath != null) {
        message = 'تم حفظ الصورة والحركة';
      } else {
        message = 'تم حفظ الصورة';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(message),
        ),
      );
    } catch (e) {
      debugPrint('Capture failed: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر التصوير. حاول مرة أخرى.'),
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

  Future<void> _playShutterFeedback() async {
    if (!_sound) {
      return;
    }

    try {
      await SystemSound.play(
        SystemSoundType.click,
      );
    } catch (e) {
      debugPrint('System shutter sound unavailable: $e');
    }

    try {
      await HapticFeedback.lightImpact();
    } catch (_) {}
  }

  Future<String?> _captureMotionClip(
    CameraController camera,
  ) async {
    try {
      if (!camera.value.isInitialized) {
        return null;
      }

      if (camera.value.isRecordingVideo) {
        return null;
      }

      await camera.startVideoRecording();

      await Future.delayed(
        const Duration(milliseconds: 1200),
      );

      if (!camera.value.isRecordingVideo) {
        return null;
      }

      final XFile clip = await camera.stopVideoRecording();

      return clip.path;
    } catch (e) {
      debugPrint('Motion clip failed: $e');

      try {
        if (camera.value.isRecordingVideo) {
          await camera.stopVideoRecording();
        }
      } catch (_) {}

      return null;
    }
  }

  Future<String> _processNormalPhoto(
    String originalPath, {
    required bool isFrontCamera,
  }) async {
    try {
      final file = File(originalPath);

      if (!await file.exists()) {
        return originalPath;
      }

      final bytes = await file.readAsBytes();

      final processed = await compute(
        _processNormalPhotoBytes,
        bytes,
      );

      if (processed.isEmpty) {
        return originalPath;
      }

      final outputPath = originalPath.replaceFirst(
        RegExp(
          r'\.jpe?g$',
          caseSensitive: false,
        ),
        '_processed.jpg',
      );

      await File(outputPath).writeAsBytes(
        processed,
        flush: true,
      );

      return outputPath;
    } catch (e) {
      debugPrint('Normal photo processing failed: $e');
      return originalPath;
    }
  }

  Future<String> _makePortrait(
    String originalPath,
  ) async {
    final segmenter = SelfieSegmenter(
      mode: SegmenterMode.single,
      enableRawSizeMask: true,
    );

    try {
      final input = InputImage.fromFilePath(
        originalPath,
      );

      final mask = await segmenter.processImage(
        input,
      );

      if (mask == null) {
        debugPrint('Portrait mask is null');
        return originalPath;
      }

      if (mask.width <= 0 || mask.height <= 0) {
        debugPrint('Invalid portrait mask size');
        return originalPath;
      }

      if (mask.confidences.isEmpty) {
        debugPrint('Portrait mask has no confidence data');
        return originalPath;
      }

      final originalBytes = await File(
        originalPath,
      ).readAsBytes();

      /// مهم:
      /// نرسل Uint8List وليس List<int>.
      final Uint8List safeBytes =
          Uint8List.fromList(originalBytes);

      final List<double> confidenceMask =
          List<double>.from(
        mask.confidences,
      );

      final Uint8List result = await compute(
        _portraitBytes,
        <String, dynamic>{
          'bytes': safeBytes,
          'width': mask.width,
          'height': mask.height,
          'mask': confidenceMask,
        },
      );

      if (result.isEmpty) {
        return originalPath;
      }

      final outputPath = originalPath.replaceFirst(
        RegExp(
          r'\.jpe?g$',
          caseSensitive: false,
        ),
        '_portrait.jpg',
      );

      await File(outputPath).writeAsBytes(
        result,
        flush: true,
      );

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

    if (camera == null) {
      return;
    }

    if (!camera.value.isInitialized) {
      return;
    }

    if (_busy) {
      return;
    }

    if (_recording) {
      await _stopRecording();
      return;
    }

    final microphonePermission =
        await Permission.microphone.request();

    if (!microphonePermission.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'اسمح باستخدام الميكروفون لتسجيل الفيديو بالصوت.',
            ),
          ),
        );
      }

      return;
    }

    try {
      await camera.startVideoRecording();

      if (!mounted) {
        return;
      }

      setState(() {
        _recording = true;
        _recordSeconds = 0;
      });

      _recordTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) {
          if (!mounted) {
            return;
          }

          setState(() {
            _recordSeconds++;
          });
        },
      );
    } catch (e) {
      debugPrint('Start recording failed: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'تعذر بدء الفيديو بهذه الجودة على الجهاز.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    final camera = _camera;

    if (camera == null) {
      return;
    }

    try {
      _recordTimer?.cancel();

      final XFile video =
          await camera.stopVideoRecording();

      if (mounted) {
        setState(() {
          _recording = false;
          _recordSeconds = 0;
          _lastPath = video.path;
        });
      }

      try {
        await Gal.putVideo(
          video.path,
        );
      } catch (e) {
        debugPrint('Video gallery save failed: $e');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'تم حفظ الفيديو في المعرض',
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Stop recording failed: $e');

      if (mounted) {
        setState(() {
          _recording = false;
          _recordSeconds = 0;
        });
      }
    }
  }

  Future<void> _changeQuality(
    String label,
  ) async {
    if (_recording || _busy) {
      return;
    }

    ResolutionPreset preset;

    switch (label) {
      case 'جودة اقتصادية':
        preset = ResolutionPreset.medium;
        break;

      case '1080p':
        preset = ResolutionPreset.high;
        break;

      case '2K':
        preset = ResolutionPreset.veryHigh;
        break;

      case 'أقصى جودة':
        preset = ResolutionPreset.max;
        break;

      default:
        preset = ResolutionPreset.high;
    }

    setState(() {
      _busy = true;
      _qualityLabel = label;
      _videoPreset = preset;
    });

    await _initCamera();

    if (mounted) {
      setState(() {
        _busy = false;
      });
    }
  }

  Future<void> _toggleFlash() async {
    final camera = _camera;

    if (camera == null ||
        !camera.value.isInitialized) {
      return;
    }

    FlashMode nextMode;

    switch (_flash) {
      case FlashMode.off:
        nextMode = FlashMode.auto;
        break;

      case FlashMode.auto:
        nextMode = FlashMode.always;
        break;

      case FlashMode.always:
        nextMode = FlashMode.torch;
        break;

      case FlashMode.torch:
        nextMode = FlashMode.off;
        break;
    }

    try {
      await camera.setFlashMode(
        nextMode,
      );

      _flash = nextMode;

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('Flash unavailable: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'الفلاش غير متاح في الوضع الحالي.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _setFocusAndExposureFromTap(
    Offset localPosition,
    Size previewSize,
  ) async {
    final camera = _camera;

    if (camera == null ||
        !camera.value.isInitialized) {
      return;
    }

    try {
      final double dx =
          (localPosition.dx / previewSize.width)
              .clamp(0.0, 1.0);

      final double dy =
          (localPosition.dy / previewSize.height)
              .clamp(0.0, 1.0);

      final Offset point = Offset(
        dx,
        dy,
      );

      try {
        await camera.setFocusPoint(point);
      } catch (e) {
        debugPrint('Focus point unavailable: $e');
      }

      try {
        await camera.setExposurePoint(point);
      } catch (e) {
        debugPrint('Exposure point unavailable: $e');
      }
    } catch (e) {
      debugPrint('Tap focus failed: $e');
    }
  }

  Future<void> _openLast() async {
    final path = _lastPath;

    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'لا توجد صورة أو فيديو حديث.',
            ),
          ),
        );
      }

      return;
    }

    final file = File(path);

    if (!await file.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'الملف الأخير غير موجود.',
            ),
          ),
        );
      }

      return;
    }

    await OpenFilex.open(path);
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(
        0xFF171717,
      ),
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (
            context,
            setSheetState,
          ) {
            return SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 8),

                    Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius:
                            BorderRadius.circular(10),
                      ),
                    ),

                    const SizedBox(height: 12),

                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'إعدادات الكاميرا',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),

                    SwitchListTile(
                      title: const Text(
                        'شبكة تقسيم الصورة',
                      ),
                      subtitle: const Text(
                        'إظهار شبكة 3 × 3',
                      ),
                      value: _grid,
                      onChanged: (value) {
                        setState(() {
                          _grid = value;
                        });

                        setSheetState(() {});
                      },
                    ),

                    SwitchListTile(
                      title: const Text(
                        'مؤقت التصوير',
                      ),
                      subtitle: Text(
                        '$_timerSeconds ثوانٍ',
                      ),
                      value: _timerOn,
                      onChanged: (value) {
                        setState(() {
                          _timerOn = value;
                        });

                        setSheetState(() {});
                      },
                    ),

                    SwitchListTile(
                      title: const Text(
                        'Motion Photo',
                      ),
                      subtitle: const Text(
                        'صورة مع مقطع حركة قصير',
                      ),
                      value: _livePhoto,
                      onChanged: (value) {
                        if (_mode == 'VIDEO') {
                          return;
                        }

                        setState(() {
                          _livePhoto = value;
                        });

                        setSheetState(() {});
                      },
                    ),

                    SwitchListTile(
                      title: const Text(
                        'صوت التقاط الصورة',
                      ),
                      subtitle: const Text(
                        'صوت + اهتزاز عند الالتقاط',
                      ),
                      value: _sound,
                      onChanged: (value) {
                        setState(() {
                          _sound = value;
                        });

                        setSheetState(() {});
                      },
                    ),

                    SwitchListTile(
                      title: const Text(
                        'تركيز تلقائي',
                      ),
                      value: _autoFocus,
                      onChanged: (value) async {
                        setState(() {
                          _autoFocus = value;
                        });

                        setSheetState(() {});

                        final camera = _camera;

                        if (camera == null ||
                            !camera.value.isInitialized) {
                          return;
                        }

                        try {
                          await camera.setFocusMode(
                            value
                                ? FocusMode.auto
                                : FocusMode.locked,
                          );
                        } catch (e) {
                          debugPrint(
                            'Focus setting failed: $e',
                          );
                        }
                      },
                    ),

                    SwitchListTile(
                      title: const Text(
                        'إضاءة تلقائية',
                      ),
                      subtitle: const Text(
                        'التعرض التلقائي حسب الإضاءة',
                      ),
                      value: _autoExposure,
                      onChanged: (value) async {
                        setState(() {
                          _autoExposure = value;
                        });

                        setSheetState(() {});

                        final camera = _camera;

                        if (camera == null ||
                            !camera.value.isInitialized) {
                          return;
                        }

                        try {
                          await camera.setExposureMode(
                            value
                                ? ExposureMode.auto
                                : ExposureMode.locked,
                          );
                        } catch (e) {
                          debugPrint(
                            'Exposure setting failed: $e',
                          );
                        }
                      },
                    ),

                    ListTile(
                      leading: const Icon(
                        Icons.timer_outlined,
                      ),
                      title: const Text(
                        'مدة المؤقت',
                      ),
                      trailing: DropdownButton<int>(
                        value: _timerSeconds,
                        dropdownColor:
                            const Color(0xFF252525),
                        items: const [
                          DropdownMenuItem(
                            value: 3,
                            child: Text('3 ثوانٍ'),
                          ),
                          DropdownMenuItem(
                            value: 5,
                            child: Text('5 ثوانٍ'),
                          ),
                          DropdownMenuItem(
                            value: 10,
                            child: Text('10 ثوانٍ'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }

                          setState(() {
                            _timerSeconds = value;
                          });

                          setSheetState(() {});
                        },
                      ),
                    ),

                    ListTile(
                      leading: const Icon(
                        Icons.info_outline,
                      ),
                      title: const Text(
                        'ملاحظة عن Motion Photo',
                      ),
                      subtitle: const Text(
                        'يتم حفظ الصورة ومقطع الحركة باستخدام أدوات Flutter المتاحة. هذا ليس تنسيق Apple Live Photo الأصلي.',
                      ),
                    ),

                    ListTile(
                      leading: const Icon(
                        Icons.close,
                      ),
                      title: const Text(
                        'إغلاق',
                      ),
                      onTap: () {
                        Navigator.of(
                          sheetContext,
                        ).pop();
                      },
                    ),

                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  double get _aspectValue {
    switch (_aspect) {
      case '1:1':
        return 1.0;

      case '16:9':
        return 9 / 16;

      case 'Full':
        return 9 / 19.5;

      case '4:3':
      default:
        return 3 / 4;
    }
  }

  String get _flashLabel {
    switch (_flash) {
      case FlashMode.off:
        return 'إيقاف';

      case FlashMode.auto:
        return 'تلقائي';

      case FlashMode.always:
        return 'تشغيل';

      case FlashMode.torch:
        return 'كشاف';
    }
  }

  IconData get _flashIcon {
    switch (_flash) {
      case FlashMode.off:
        return Icons.flash_off;

      case FlashMode.auto:
        return Icons.flash_auto;

      case FlashMode.always:
        return Icons.flash_on;

      case FlashMode.torch:
        return Icons.highlight;
    }
  }

  String get _modeArabic {
    switch (_mode) {
      case 'VIDEO':
        return 'فيديو';

      case 'PORTRAIT':
        return 'بورتريه';

      case 'NIGHT':
        return 'ليل';

      case 'PHOTO':
      default:
        return 'صورة';
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(
      this,
    );

    _recordTimer?.cancel();

    _captureAnimation.dispose();

    final camera = _camera;

    _camera = null;

    camera?.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_permission) {
      return _buildPermissionScreen();
    }

    if (widget.cameras.isEmpty) {
      return _buildNoCameraScreen();
    }

    final camera = _camera;

    if (camera == null ||
        !camera.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(
            color: Colors.greenAccent,
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildCameraPreview(camera),

          if (_grid)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _GridPainter(),
                ),
              ),
            ),

          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _captureAnimation,
                builder: (
                  context,
                  child,
                ) {
                  return Opacity(
                    opacity:
                        _captureAnimation.value *
                        0.55,
                    child: const ColoredBox(
                      color: Colors.white,
                    ),
                  );
                },
              ),
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
                _buildTopBar(),

                if (_recording)
                  _buildRecordingIndicator(),

                if (_recordSeconds > 0 &&
                    !_recording)
                  _buildTimerIndicator(),

                const Spacer(),

                if (_mode == 'VIDEO')
                  _buildVideoQualitySelector(),

                _buildModeSelector(),

                const SizedBox(height: 12),

                _buildBottomControls(),

                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.camera_alt_outlined,
                size: 64,
              ),

              const SizedBox(height: 18),

              const Text(
                'يلزم السماح باستخدام الكاميرا',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 18),

              FilledButton(
                onPressed: _start,
                child: const Text(
                  'السماح بالكاميرا',
                ),
              ),

              TextButton(
                onPressed: openAppSettings,
                child: const Text(
                  'فتح إعدادات التطبيق',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNoCameraScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.no_photography_outlined,
              size: 64,
            ),
            const SizedBox(height: 16),
            const Text(
              'لم يتم العثور على كاميرا.',
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _start,
              child: const Text(
                'إعادة المحاولة',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraPreview(
    CameraController camera,
  ) {
    return Center(
      child: GestureDetector(
        onScaleStart: (_) {
          _scaleStartZoom = _zoom;
        },
        onScaleUpdate: (details) async {
          final double next =
              (_scaleStartZoom * details.scale)
                  .clamp(
                    _minZoom,
                    _maxZoom,
                  )
                  .toDouble();

          if (mounted) {
            setState(() {
              _zoom = next;
            });
          }

          try {
            await camera.setZoomLevel(
              next,
            );
          } catch (e) {
            debugPrint(
              'Zoom update failed: $e',
            );
          }
        },
        onTapUp: (details) async {
          final RenderBox? box =
              context.findRenderObject()
                  as RenderBox?;

          if (box == null) {
            return;
          }

          await _setFocusAndExposureFromTap(
            details.localPosition,
            box.size,
          );
        },
        child: AspectRatio(
          aspectRatio: _aspectValue,
          child: CameraPreview(camera),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: 5,
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'الفلاش',
            onPressed: _toggleFlash,
            icon: Icon(
              _flashIcon,
            ),
          ),

          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _modeArabic,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '${_zoom.toStringAsFixed(1)}×',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
          ),

          TextButton(
            onPressed: _busy || _recording
                ? null
                : () {
                    setState(() {
                      switch (_aspect) {
                        case '4:3':
                          _aspect = '16:9';
                          break;

                        case '16:9':
                          _aspect = 'Full';
                          break;

                        case 'Full':
                          _aspect = '1:1';
                          break;

                        default:
                          _aspect = '4:3';
                      }
                    });
                  },
            child: Text(
              _aspect,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          IconButton(
            tooltip: 'الإعدادات',
            onPressed: _showSettings,
            icon: const Icon(
              Icons.tune,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(
        top: 6,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius:
              BorderRadius.circular(20),
        ),
        child: Text(
          '● تسجيل ${_recordSeconds}s',
          style: const TextStyle(
            color: Colors.redAccent,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildTimerIndicator() {
    return Padding(
      padding: const EdgeInsets.only(
        top: 8,
      ),
      child: Text(
        '$_recordSeconds',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 30,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildVideoQualitySelector() {
    return Padding(
      padding: const EdgeInsets.only(
        bottom: 10,
        left: 8,
        right: 8,
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 6,
        runSpacing: 6,
        children: [
          _qualityChip(
            '1080p',
          ),
          _qualityChip(
            '2K',
          ),
          _qualityChip(
            'أقصى جودة',
          ),
        ],
      ),
    );
  }

  Widget _buildModeSelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
      ),
      child: Row(
        mainAxisAlignment:
            MainAxisAlignment.center,
        children: [
          _modeButton(
            'NIGHT',
            'ليل',
          ),
          _modeButton(
            'PORTRAIT',
            'بورتريه',
          ),
          _modeButton(
            'PHOTO',
            'صورة',
          ),
          _modeButton(
            'VIDEO',
            'فيديو',
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        18,
        0,
        18,
        14,
      ),
      child: Row(
        mainAxisAlignment:
            MainAxisAlignment.spaceBetween,
        crossAxisAlignment:
            CrossAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: _openLast,
            child: Container(
              width: 54,
              height: 54,
              clipBehavior:
                  Clip.antiAlias,
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius:
                    BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white54,
                ),
              ),
              child: _lastPath != null &&
                      File(_lastPath!)
                          .existsSync()
                  ? _buildLastPreview()
                  : const Icon(
                      Icons.photo_library_outlined,
                    ),
            ),
          ),

          GestureDetector(
            onTap: _capture,
            child: Container(
              width: 82,
              height: 82,
              padding:
                  const EdgeInsets.all(5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white,
                  width: 3,
                ),
              ),
              child: AnimatedContainer(
                duration: const Duration(
                  milliseconds: 120,
                ),
                decoration: BoxDecoration(
                  color: _mode == 'VIDEO'
                      ? Colors.red
                      : Colors.white,
                  shape: _recording
                      ? BoxShape.rectangle
                      : BoxShape.circle,
                  borderRadius: _recording
                      ? BorderRadius.circular(
                          10,
                        )
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
            tooltip: 'تبديل الكاميرا',
            onPressed: _switchCamera,
            icon: const Icon(
              Icons.cameraswitch_outlined,
              size: 34,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLastPreview() {
    final path = _lastPath;

    if (path == null) {
      return const Icon(
        Icons.photo,
      );
    }

    final lower =
        path.toLowerCase();

    if (lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.avi')) {
      return const Center(
        child: Icon(
          Icons.play_arrow,
          size: 28,
        ),
      );
    }

    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (
        context,
        error,
        stackTrace,
      ) {
        return const Icon(
          Icons.photo,
        );
      },
    );
  }

  Widget _modeButton(
    String key,
    String label,
  ) {
    final bool selected =
        _mode == key;

    final Color selectedColor =
        key == 'VIDEO'
            ? Colors.redAccent
            : Colors.greenAccent;

    return Padding(
      padding:
          const EdgeInsets.symmetric(
        horizontal: 3,
      ),
      child: TextButton(
        onPressed: () {
          if (_recording || _busy) {
            return;
          }

          setState(() {
            _mode = key;
          });
        },
        style: TextButton.styleFrom(
          foregroundColor:
              selected
                  ? selectedColor
                  : Colors.white70,
          backgroundColor:
              selected
                  ? selectedColor.withValues(
                      alpha: 0.16,
                    )
                  : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(20),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _qualityChip(
    String label,
  ) {
    final bool selected =
        _qualityLabel == label;

    return ChoiceChip(
      label: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
        ),
      ),
      selected: selected,
      onSelected: (_) {
        _changeQuality(label);
      },
    );
  }
}

/// معالجة الصورة العادية في Isolate.
///
/// لا يوجد هنا أي flip للصورة الأمامية.
/// الاتجاه الطبيعي يتم احترامه من EXIF.
Uint8List _processNormalPhotoBytes(
  Uint8List bytes,
) {
  try {
    final decoded =
        img.decodeImage(bytes);

    if (decoded == null) {
      return bytes;
    }

    final oriented =
        img.bakeOrientation(
      decoded,
    );

    /// تحسين خفيف ومحافظ على التفاصيل.
    /// لا نريد ضغط الصورة أو تشويه الوجه.
    final output =
        img.encodeJpg(
      oriented,
      quality: 98,
    );

    return Uint8List.fromList(
      output,
    );
  } catch (_) {
    return bytes;
  }
}

/// معالجة البورتريه.
///
/// يستخدم قناع ML Kit لعزل الشخص وتغبيش الخلفية.
/// لا يتم قلب الصورة يدويًا.
Uint8List _portraitBytes(
  Map<String, dynamic> args,
) {
  try {
    final dynamic rawBytes =
        args['bytes'];

    final Uint8List bytes =
        rawBytes is Uint8List
            ? rawBytes
            : Uint8List.fromList(
                (rawBytes as List)
                    .cast<int>(),
              );

    final int maskWidth =
        args['width'] as int;

    final int maskHeight =
        args['height'] as int;

    final List<double> mask =
        List<double>.from(
      args['mask'] as List,
    );

    if (bytes.isEmpty ||
        maskWidth <= 0 ||
        maskHeight <= 0 ||
        mask.isEmpty) {
      return bytes;
    }

    final decoded =
        img.decodeImage(bytes);

    if (decoded == null) {
      return bytes;
    }

    /// احترام اتجاه الصورة من EXIF.
    final foreground =
        img.bakeOrientation(
      decoded,
    );

    /// خلفية ناعمة.
    final background =
        img.gaussianBlur(
      foreground,
      radius: 12,
    );

    final output = img.Image(
      width: foreground.width,
      height: foreground.height,
      numChannels: 4,
    );

    for (
      int y = 0;
      y < foreground.height;
      y++
    ) {
      final int my =
          ((y * maskHeight) /
                  foreground.height)
              .floor()
              .clamp(
                0,
                maskHeight - 1,
              );

      for (
        int x = 0;
        x < foreground.width;
        x++
      ) {
        final int mx =
            ((x * maskWidth) /
                    foreground.width)
                .floor()
                .clamp(
                  0,
                  maskWidth - 1,
                );

        final int index =
            my * maskWidth + mx;

        double confidence = 0;

        if (index >= 0 &&
            index < mask.length) {
          confidence =
              mask[index].clamp(
            0.0,
            1.0,
          );
        }

        /// منطقة انتقال ناعمة.
        final double alpha =
            ((confidence - 0.18) /
                    0.64)
                .clamp(
          0.0,
          1.0,
        );

        final fg =
            foreground.getPixel(
          x,
          y,
        );

        final bg =
            background.getPixel(
          x,
          y,
        );

        final int r =
            (fg.r * alpha +
                    bg.r *
                        (1 - alpha))
                .round();

        final int g =
            (fg.g * alpha +
                    bg.g *
                        (1 - alpha))
                .round();

        final int b =
            (fg.b * alpha +
                    bg.b *
                        (1 - alpha))
                .round();

        output.setPixelRgba(
          x,
          y,
          r.clamp(0, 255),
          g.clamp(0, 255),
          b.clamp(0, 255),
          255,
        );
      }
    }

    final encoded =
        img.encodeJpg(
      output,
      quality: 98,
    );

    return Uint8List.fromList(
      encoded,
    );
  } catch (_) {
    final dynamic rawBytes =
        args['bytes'];

    if (rawBytes is Uint8List) {
      return rawBytes;
    }

    return Uint8List.fromList(
      (rawBytes as List)
          .cast<int>(),
    );
  }
}

class _GridPainter
    extends CustomPainter {
  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final Paint paint =
        Paint()
          ..color =
              Colors.white30
          ..strokeWidth = 1;

    canvas.drawLine(
      Offset(
        size.width / 3,
        0,
      ),
      Offset(
        size.width / 3,
        size.height,
      ),
      paint,
    );

    canvas.drawLine(
      Offset(
        size.width * 2 / 3,
        0,
      ),
      Offset(
        size.width * 2 / 3,
        size.height,
      ),
      paint,
    );

    canvas.drawLine(
      Offset(
        0,
        size.height / 3,
      ),
      Offset(
        size.width,
        size.height / 3,
      ),
      paint,
    );

    canvas.drawLine(
      Offset(
        0,
        size.height * 2 / 3,
      ),
      Offset(
        size.width,
        size.height * 2 / 3,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(
    covariant CustomPainter oldDelegate,
  ) {
    return false;
  }
}