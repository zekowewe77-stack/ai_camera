import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
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
    debugPrint('Camera discovery error: $e');
  }

  runApp(CameraApp(cameras: cameras));
}

class CameraApp extends StatelessWidget {
  const CameraApp({
    super.key,
    required this.cameras,
  });

  final List<CameraDescription> cameras;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AI Camera Pro 2027',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.greenAccent,
          brightness: Brightness.dark,
        ),
      ),
      home: CameraScreen(cameras: cameras),
    );
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

  String _qualityLabel = '1080p / 30fps';

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
  bool _livePhoto = false;
  bool _sound = true;

  int _timerSeconds = 3;
  int _recordSeconds = 0;

  String? _lastPath;
  String? _lastMotionPath;

  Timer? _recordTimer;

  late final AnimationController _flashAnimation;

  bool get _frontCamera {
    if (widget.cameras.isEmpty) return false;

    return widget.cameras[_cameraIndex].lensDirection ==
        CameraLensDirection.front;
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _flashAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 110),
    );

    _startCamera();
  }

  Future<void> _startCamera() async {
    final permission = await Permission.camera.request();

    if (!permission.isGranted) {
      if (mounted) {
        setState(() {
          _permission = false;
        });
      }
      return;
    }

    try {
      await Gal.requestAccess();
    } catch (e) {
      debugPrint('Gallery permission error: $e');
    }

    if (mounted) {
      setState(() {
        _permission = true;
      });
    }

    if (widget.cameras.isNotEmpty) {
      await _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    if (!mounted || widget.cameras.isEmpty) return;

    final oldCamera = _camera;

    _camera = null;

    if (mounted) {
      setState(() {});
    }

    if (oldCamera != null) {
      try {
        await oldCamera.dispose();
      } catch (_) {}
    }

    final selectedCamera = widget.cameras[_cameraIndex];

    final controller = CameraController(
      selectedCamera,
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

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('Camera initialization error: $e');

      if (identical(_camera, controller)) {
        _camera = null;
      }

      try {
        await controller.dispose();
      } catch (_) {}

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تعذر تشغيل الكاميرا: $e',
            ),
          ),
        );
      }
    }
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

      if (mounted) {
        setState(() {
          _recording = false;
          _recordSeconds = 0;
        });
      }
    }

    if (state == AppLifecycleState.resumed &&
        _permission &&
        widget.cameras.isNotEmpty) {
      _initializeCamera();
    }
  }

  Future<void> _switchCamera() async {
    if (widget.cameras.length < 2 ||
        _busy ||
        _recording) {
      return;
    }

    setState(() {
      _busy = true;
    });

    _cameraIndex =
        (_cameraIndex + 1) % widget.cameras.length;

    await _initializeCamera();

    if (mounted) {
      setState(() {
        _busy = false;
      });
    }
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

    if (_recording) return;

    setState(() {
      _busy = true;
    });

    try {
      if (_timerOn) {
        for (int i = _timerSeconds; i > 0; i--) {
          if (!mounted) return;

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

      if (_sound) {
        HapticFeedback.mediumImpact();
      }

      _animateCapture();

      String? motionPath;

      if (_livePhoto) {
        motionPath =
            await _captureMotionClip(camera);
      }

      final XFile original =
          await camera.takePicture();

      String finalPath = original.path;

      /*
       * الكاميرا الأمامية:
       *
       * الـ preview يتم عكسه بصرياً للمستخدم،
       * لكن الصورة المحفوظة يتم قلبها أفقياً
       * حتى يكون الاتجاه الطبيعي محفوظاً:
       *
       * لو حركت رأسك يميناً تظهر يميناً في الصورة.
       */
      if (_frontCamera) {
        finalPath =
            await _makeNaturalFrontCameraImage(
          original.path,
        );
      }

      /*
       * البورتريه:
       * نحاول تطبيق عزل حقيقي باستخدام
       * ML Kit Selfie Segmentation.
       */
      if (_mode == 'PORTRAIT') {
        finalPath =
            await _makePortrait(finalPath);
      }

      /*
       * حفظ الصورة في المعرض.
       */
      await Gal.putImage(finalPath);

      /*
       * مقطع الحركة يتم حفظه كفيديو مساعد.
       *
       * ملاحظة:
       * هذا ليس Apple Live Photo الأصلي.
       * إنشاء Live Photo أصلي يحتاج صيغة/metadata
       * خاصة بالمنصة وليس مجرد JPG + MP4.
       */
      if (motionPath != null) {
        _lastMotionPath = motionPath;

        try {
          await Gal.putVideo(motionPath);
        } catch (e) {
          debugPrint(
            'Motion video gallery error: $e',
          );
        }
      }

      if (!mounted) return;

      setState(() {
        _lastPath = finalPath;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(milliseconds: 1300),
          content: Text(
            _mode == 'PORTRAIT'
                ? 'تم حفظ صورة البورتريه'
                : motionPath != null
                    ? 'تم حفظ الصورة والحركة'
                    : 'تم حفظ الصورة',
          ),
        ),
      );
    } catch (e) {
      debugPrint('Capture error: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'حدث خطأ أثناء التصوير. حاول مرة أخرى.',
            ),
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

  void _animateCapture() {
    _flashAnimation.forward(
      from: 0,
    ).then((_) {
      if (mounted) {
        _flashAnimation.reverse();
      }
    });
  }

  Future<String> _makeNaturalFrontCameraImage(
    String path,
  ) async {
    try {
      final bytes =
          await File(path).readAsBytes();

      final decoded =
          img.decodeImage(bytes);

      if (decoded == null) {
        return path;
      }

      /*
       * قلب أفقي فقط.
       * لا يوجد قلب رأسي.
       */
      final corrected =
          img.flipHorizontally(decoded);

      final encoded =
          img.encodeJpg(
        corrected,
        quality: 98,
      );

      final outputPath =
          path.replaceFirst(
        RegExp(
          r'\.jpe?g$',
          caseSensitive: false,
        ),
        '_natural.jpg',
      );

      await File(outputPath)
          .writeAsBytes(
        Uint8List.fromList(encoded),
        flush: true,
      );

      return outputPath;
    } catch (e) {
      debugPrint(
        'Front camera correction error: $e',
      );

      return path;
    }
  }

  Future<String?> _captureMotionClip(
    CameraController camera,
  ) async {
    try {
      if (!camera.value.isInitialized ||
          camera.value.isRecordingVideo) {
        return null;
      }

      await camera.startVideoRecording();

      await Future.delayed(
        const Duration(
          milliseconds: 1200,
        ),
      );

      if (!camera.value.isRecordingVideo) {
        return null;
      }

      final XFile clip =
          await camera.stopVideoRecording();

      return clip.path;
    } catch (e) {
      debugPrint(
        'Motion capture error: $e',
      );

      try {
        if (camera.value.isRecordingVideo) {
          await camera.stopVideoRecording();
        }
      } catch (_) {}

      return null;
    }
  }

  Future<String> _makePortrait(
    String originalPath,
  ) async {
    final segmenter =
        SelfieSegmenter(
      mode: SegmenterMode.single,
      enableRawSizeMask: true,
    );

    try {
      final input =
          InputImage.fromFilePath(
        originalPath,
      );

      final mask =
          await segmenter.processImage(
        input,
      );

      if (mask == null ||
          mask.width <= 0 ||
          mask.height <= 0 ||
          mask.confidences.isEmpty) {
        return originalPath;
      }

      final bytes =
          await File(originalPath)
              .readAsBytes();

      final processed =
          _processPortraitImage(
        bytes: bytes,
        maskWidth: mask.width,
        maskHeight: mask.height,
        confidences:
            mask.confidences,
      );

      final outputPath =
          originalPath.replaceFirst(
        RegExp(
          r'\.jpe?g$',
          caseSensitive: false,
        ),
        '_portrait.jpg',
      );

      await File(outputPath)
          .writeAsBytes(
        processed,
        flush: true,
      );

      return outputPath;
    } catch (e) {
      debugPrint(
        'Portrait error: $e',
      );

      return originalPath;
    } finally {
      await segmenter.close();
    }
  }

  Uint8List _processPortraitImage({
    required Uint8List bytes,
    required int maskWidth,
    required int maskHeight,
    required List<double> confidences,
  }) {
    final decoded =
        img.decodeImage(bytes);

    if (decoded == null ||
        maskWidth <= 0 ||
        maskHeight <= 0 ||
        confidences.isEmpty) {
      return bytes;
    }

    final foreground =
        img.bakeOrientation(decoded);

    /*
     * خلفية ضبابية قوية نسبياً.
     * الشخص يظل واضحاً والخلفية يتم تنعيمها.
     */
    final background =
        img.gaussianBlur(
      foreground,
      radius: 14,
    );

    final output =
        img.Image(
      width: foreground.width,
      height: foreground.height,
    );

    for (int y = 0;
        y < foreground.height;
        y++) {
      final int maskY =
          ((y * maskHeight) /
                  foreground.height)
              .floor()
              .clamp(
                0,
                maskHeight - 1,
              );

      for (int x = 0;
          x < foreground.width;
          x++) {
        final int maskX =
            ((x * maskWidth) /
                    foreground.width)
                .floor()
                .clamp(
                  0,
                  maskWidth - 1,
                );

        final int index =
            maskY * maskWidth +
                maskX;

        double confidence = 0.0;

        if (index >= 0 &&
            index <
                confidences.length) {
          confidence =
              confidences[index]
                  .clamp(0.0, 1.0);
        }

        /*
         * انتقال ناعم عند حواف الشخص
         * لتقليل القص الحاد.
         */
        final double alpha =
            ((confidence - 0.18) /
                    0.58)
                .clamp(0.0, 1.0);

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
                    bg.r * (1 - alpha))
                .round();

        final int g =
            (fg.g * alpha +
                    bg.g * (1 - alpha))
                .round();

        final int b =
            (fg.b * alpha +
                    bg.b * (1 - alpha))
                .round();

        output.setPixelRgba(
          x,
          y,
          r,
          g,
          b,
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
  }

  Future<void> _toggleRecording() async {
    final camera = _camera;

    if (camera == null ||
        !camera.value.isInitialized ||
        _busy) {
      return;
    }

    if (_recording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    final camera = _camera;

    if (camera == null ||
        !camera.value.isInitialized) {
      return;
    }

    final microphone =
        await Permission.microphone.request();

    if (!microphone.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content: Text(
              'اسمح بالميكروفون لتسجيل صوت الفيديو.',
            ),
          ),
        );
      }

      return;
    }

    try {
      await camera.startVideoRecording();

      if (!mounted) return;

      setState(() {
        _recording = true;
        _recordSeconds = 0;
      });

      _recordTimer =
          Timer.periodic(
        const Duration(seconds: 1),
        (_) {
          if (!mounted) return;

          setState(() {
            _recordSeconds++;
          });
        },
      );
    } catch (e) {
      debugPrint(
        'Start video error: $e',
      );

      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content: Text(
              'تعذر بدء تسجيل الفيديو.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    final camera = _camera;

    if (camera == null) return;

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

      await Gal.putVideo(
        video.path,
      );

      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content: Text(
              'تم حفظ الفيديو في المعرض',
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint(
        'Stop video error: $e',
      );

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
      case '720p / 30fps':
        preset =
            ResolutionPreset.medium;
        break;

      case '1080p / 30fps':
        preset =
            ResolutionPreset.high;
        break;

      case 'أعلى جودة متاحة':
        preset =
            ResolutionPreset.max;
        break;

      default:
        preset =
            ResolutionPreset.high;
    }

    setState(() {
      _busy = true;
      _qualityLabel = label;
      _videoPreset = preset;
    });

    await _initializeCamera();

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

    FlashMode next;

    switch (_flash) {
      case FlashMode.off:
        next = FlashMode.auto;
        break;

      case FlashMode.auto:
        next = FlashMode.torch;
        break;

      case FlashMode.torch:
        next = FlashMode.off;
        break;

      default:
        next = FlashMode.off;
    }

    try {
      await camera.setFlashMode(next);

      _flash = next;

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint(
        'Flash error: $e',
      );

      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content: Text(
              'الفلاش غير متاح في الوضع الحالي.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _openLast() async {
    final path = _lastPath;

    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content: Text(
              'لا توجد صورة أو فيديو حديث.',
            ),
          ),
        );
      }

      return;
    }

    final file =
        File(path);

    if (!await file.exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content: Text(
              'الملف غير موجود.',
            ),
          ),
        );
      }

      return;
    }

    await OpenFilex.open(
      path,
    );
  }

  Future<void> _changeAspect() async {
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
  }

  double get _aspectRatio {
    switch (_aspect) {
      case '16:9':
        return 9 / 16;

      case 'Full':
        return 9 / 19.5;

      case '1:1':
        return 1;

      case '4:3':
      default:
        return 3 / 4;
    }
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor:
          const Color(0xFF151515),
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (
            context,
            setSheet,
          ) {
            return SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    const SizedBox(
                      height: 10,
                    ),

                    Container(
                      width: 42,
                      height: 4,
                      decoration:
                          BoxDecoration(
                        color:
                            Colors.white30,
                        borderRadius:
                            BorderRadius.circular(
                          20,
                        ),
                      ),
                    ),

                    const Padding(
                      padding:
                          EdgeInsets.all(18),
                      child: Text(
                        'إعدادات الكاميرا',
                        style:
                            TextStyle(
                          fontSize: 21,
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                    ),

                    SwitchListTile(
                      title: const Text(
                        'شبكة التصوير',
                      ),
                      subtitle: const Text(
                        'إظهار شبكة 3 × 3',
                      ),
                      value: _grid,
                      onChanged: (
                        value,
                      ) {
                        setState(() {
                          _grid = value;
                        });

                        setSheet(() {});
                      },
                    ),

                    SwitchListTile(
                      title: const Text(
                        'المؤقت',
                      ),
                      subtitle: Text(
                        '$_timerSeconds ثوانٍ',
                      ),
                      value: _timerOn,
                      onChanged: (
                        value,
                      ) {
                        setState(() {
                          _timerOn = value;
                        });

                        setSheet(() {});
                      },
                    ),

                    ListTile(
                      title: const Text(
                        'مدة المؤقت',
                      ),
                      trailing: DropdownButton<int>(
                        value:
                            _timerSeconds,
                        dropdownColor:
                            const Color(
                          0xFF242424,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 3,
                            child: Text(
                              '3 ثوانٍ',
                            ),
                          ),
                          DropdownMenuItem(
                            value: 5,
                            child: Text(
                              '5 ثوانٍ',
                            ),
                          ),
                          DropdownMenuItem(
                            value: 10,
                            child: Text(
                              '10 ثوانٍ',
                            ),
                          ),
                        ],
                        onChanged: (
                          value,
                        ) {
                          if (value ==
                              null) {
                            return;
                          }

                          setState(() {
                            _timerSeconds =
                                value;
                          });

                          setSheet(() {});
                        },
                      ),
                    ),

                    SwitchListTile(
                      title: const Text(
                        'الصورة المتحركة',
                      ),
                      subtitle:
                          const Text(
                        'التقاط حركة قصيرة مع الصورة',
                      ),
                      value: _livePhoto,
                      onChanged: (
                        value,
                      ) {
                        setState(() {
                          _livePhoto =
                              value;
                        });

                        setSheet(() {});
                      },
                    ),

                    SwitchListTile(
                      title: const Text(
                        'صوت / اهتزاز الالتقاط',
                      ),
                      subtitle:
                          const Text(
                        'تأكيد الالتقاط بالاهتزاز',
                      ),
                      value: _sound,
                      onChanged: (
                        value,
                      ) {
                        setState(() {
                          _sound = value;
                        });

                        setSheet(() {});
                      },
                    ),

                    ListTile(
                      leading:
                          const Icon(
                        Icons.high_quality,
                      ),
                      title: const Text(
                        'جودة الفيديو',
                      ),
                      subtitle: Text(
                        _qualityLabel,
                      ),
                      onTap: () {
                        Navigator.pop(
                          sheetContext,
                        );

                        _showVideoQuality();
                      },
                    ),

                    ListTile(
                      leading:
                          const Icon(
                        Icons.aspect_ratio,
                      ),
                      title: const Text(
                        'أبعاد الصورة',
                      ),
                      subtitle:
                          Text(_aspect),
                      onTap: () {
                        Navigator.pop(
                          sheetContext,
                        );

                        _showAspectOptions();
                      },
                    ),

                    ListTile(
                      leading:
                          const Icon(
                        Icons.close,
                      ),
                      title: const Text(
                        'إغلاق',
                      ),
                      onTap: () {
                        Navigator.pop(
                          sheetContext,
                        );
                      },
                    ),

                    const SizedBox(
                      height: 12,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showVideoQuality() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor:
          const Color(0xFF151515),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize:
                MainAxisSize.min,
            children: [
              const Padding(
                padding:
                    EdgeInsets.all(18),
                child: Text(
                  'جودة الفيديو',
                  style:
                      TextStyle(
                    fontSize: 20,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),

              _qualityOption(
                '720p / 30fps',
              ),

              _qualityOption(
                '1080p / 30fps',
              ),

              _qualityOption(
                'أعلى جودة متاحة',
              ),

              const SizedBox(
                height: 15,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _qualityOption(
    String label,
  ) {
    return ListTile(
      title: Text(label),
      trailing:
          _qualityLabel == label
              ? const Icon(
                  Icons.check,
                  color:
                      Colors.greenAccent,
                )
              : null,
      onTap: () {
        Navigator.pop(context);
        _changeQuality(label);
      },
    );
  }

  void _showAspectOptions() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor:
          const Color(0xFF151515),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize:
                MainAxisSize.min,
            children: [
              const Padding(
                padding:
                    EdgeInsets.all(18),
                child: Text(
                  'أبعاد الصورة',
                  style:
                      TextStyle(
                    fontSize: 20,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),

              _aspectOption(
                '4:3',
              ),

              _aspectOption(
                '16:9',
              ),

              _aspectOption(
                'Full',
              ),

              _aspectOption(
                '1:1',
              ),

              const SizedBox(
                height: 15,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _aspectOption(
    String value,
  ) {
    return ListTile(
      title: Text(value),
      trailing:
          _aspect == value
              ? const Icon(
                  Icons.check,
                  color:
                      Colors.greenAccent,
                )
              : null,
      onTap: () {
        setState(() {
          _aspect = value;
        });

        Navigator.pop(context);
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance
        .removeObserver(this);

    _recordTimer?.cancel();

    _flashAnimation.dispose();

    _camera?.dispose();

    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    if (!_permission) {
      return Scaffold(
        backgroundColor:
            Colors.black,
        body: Center(
          child: Padding(
            padding:
                const EdgeInsets.all(24),
            child: Column(
              mainAxisSize:
                  MainAxisSize.min,
              children: [
                const Icon(
                  Icons.camera_alt,
                  size: 60,
                ),

                const SizedBox(
                  height: 18,
                ),

                const Text(
                  'يلزم السماح باستخدام الكاميرا',
                  textAlign:
                      TextAlign.center,
                  style:
                      TextStyle(
                    fontSize: 17,
                  ),
                ),

                const SizedBox(
                  height: 18,
                ),

                FilledButton(
                  onPressed:
                      _startCamera,
                  child:
                      const Text(
                    'السماح بالكاميرا',
                  ),
                ),

                TextButton(
                  onPressed:
                      openAppSettings,
                  child:
                      const Text(
                    'فتح إعدادات التطبيق',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final camera = _camera;

    if (camera == null ||
        !camera.value.isInitialized) {
      return const Scaffold(
        backgroundColor:
            Colors.black,
        body: Center(
          child:
              CircularProgressIndicator(
            color:
                Colors.greenAccent,
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor:
          Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: GestureDetector(
              onScaleStart: (_) {
                _scaleStartZoom =
                    _zoom;
              },

              onScaleUpdate:
                  (details) async {
                final next =
                    (_scaleStartZoom *
                            details.scale)
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
                  await camera
                      .setZoomLevel(
                    next,
                  );
                } catch (_) {}
              },

              child: AspectRatio(
                aspectRatio:
                    _aspectRatio,

                /*
                 * معاينة السيلفي طبيعية
                 * للمستخدم، بينما الصورة
                 * المحفوظة يتم تصحيحها أيضاً.
                 */
                child: _frontCamera
                    ? Transform(
                        alignment:
                            Alignment.center,
                        transform:
                            Matrix4
                                .identity()
                              ..scale(
                                -1.0,
                                1.0,
                              ),
                        child:
                            CameraPreview(
                          camera,
                        ),
                      )
                    : CameraPreview(
                        camera,
                      ),
              ),
            ),
          ),

          Positioned.fill(
            child: IgnorePointer(
              child:
                  AnimatedBuilder(
                animation:
                    _flashAnimation,
                builder:
                    (_, __) {
                  return Opacity(
                    opacity:
                        _flashAnimation
                            .value,
                    child:
                        const ColoredBox(
                      color:
                          Colors.white,
                    ),
                  );
                },
              ),
            ),
          ),

          if (_grid)
            Positioned.fill(
              child: IgnorePointer(
                child:
                    CustomPaint(
                  painter:
                      _GridPainter(),
                ),
              ),
            ),

          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color:
                    Color(0x55000000),
                child: Center(
                  child:
                      CircularProgressIndicator(
                    color:
                        Colors.greenAccent,
                  ),
                ),
              ),
            ),

          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed:
                            _toggleFlash,
                        icon: Icon(
                          _flash ==
                                  FlashMode.off
                              ? Icons.flash_off
                              : _flash ==
                                      FlashMode.auto
                                  ? Icons.flash_auto
                                  : Icons.flash_on,
                        ),
                      ),

                      const Spacer(),

                      Container(
                        padding:
                            const EdgeInsets
                                .symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        decoration:
                            BoxDecoration(
                          color:
                              Colors.black54,
                          borderRadius:
                              BorderRadius
                                  .circular(
                            20,
                          ),
                        ),
                        child: Text(
                          '${_zoom.toStringAsFixed(1)}×',
                          style:
                              const TextStyle(
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                      ),

                      const Spacer(),

                      IconButton(
                        onPressed:
                            _changeAspect,
                        icon: Text(
                          _aspect,
                          style:
                              const TextStyle(
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                      ),

                      IconButton(
                        onPressed:
                            _showSettings,
                        icon:
                            const Icon(
                          Icons.tune,
                        ),
                      ),
                    ],
                  ),
                ),

                if (_recording)
                  Container(
                    padding:
                        const EdgeInsets
                            .symmetric(
                      horizontal: 14,
                      vertical: 7,
                    ),
                    decoration:
                        BoxDecoration(
                      color:
                          Colors.red
                              .withOpacity(
                        .85,
                      ),
                      borderRadius:
                          BorderRadius
                              .circular(
                        20,
                      ),
                    ),
                    child: Text(
                      '● تسجيل $_recordSeconds ثانية',
                      style:
                          const TextStyle(
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  ),

                if (_recordSeconds >
                        0 &&
                    !_recording)
                  Text(
                    '$_recordSeconds',
                    style:
                        const TextStyle(
                      fontSize: 28,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),

                const Spacer(),

                if (_mode == 'VIDEO')
                  Padding(
                    padding:
                        const EdgeInsets
                            .only(
                      bottom: 12,
                    ),
                    child: Row(
                      mainAxisAlignment:
                          MainAxisAlignment
                              .center,
                      children: [
                        _videoChip(
                          '1080p / 30fps',
                        ),
                        _videoChip(
                          'أعلى جودة متاحة',
                        ),
                      ],
                    ),
                  ),

                Row(
                  mainAxisAlignment:
                      MainAxisAlignment
                          .center,
                  children: [
                    _modeButton(
                      'PHOTO',
                      'صورة',
                    ),
                    _modeButton(
                      'PORTRAIT',
                      'بورتريه',
                    ),
                    _modeButton(
                      'VIDEO',
                      'فيديو',
                    ),
                  ],
                ),

                const SizedBox(
                  height: 15,
                ),

                Padding(
                  padding:
                      const EdgeInsets
                          .fromLTRB(
                    22,
                    0,
                    22,
                    24,
                  ),
                  child: Row(
                    mainAxisAlignment:
                        MainAxisAlignment
                            .spaceBetween,
                    children: [
                      GestureDetector(
                        onTap:
                            _openLast,
                        child:
                            Container(
                          width: 55,
                          height: 55,
                          clipBehavior:
                              Clip.antiAlias,
                          decoration:
                              BoxDecoration(
                            color:
                                Colors.black54,
                            borderRadius:
                                BorderRadius
                                    .circular(
                              11,
                            ),
                            border:
                                Border.all(
                              color:
                                  Colors.white54,
                            ),
                          ),
                          child:
                              _lastPath !=
                                      null &&
                                  File(
                                    _lastPath!,
                                  ).existsSync()
                              ? Image.file(
                                  File(
                                    _lastPath!,
                                  ),
                                  fit: BoxFit
                                      .cover,
                                  errorBuilder:
                                      (
                                    _,
                                    __,
                                    ___,
                                  ) {
                                    return const Icon(
                                      Icons
                                          .photo,
                                    );
                                  },
                                )
                              : const Icon(
                                  Icons
                                      .photo_library_outlined,
                                ),
                        ),
                      ),

                      GestureDetector(
                        onTap:
                            _capture,
                        child:
                            Container(
                          width: 82,
                          height: 82,
                          padding:
                              const EdgeInsets
                                  .all(
                            5,
                          ),
                          decoration:
                              BoxDecoration(
                            shape:
                                BoxShape.circle,
                            border:
                                Border.all(
                              color:
                                  Colors.white,
                              width: 3,
                            ),
                          ),
                          child:
                              AnimatedContainer(
                            duration:
                                const Duration(
                              milliseconds:
                                  120,
                            ),
                            decoration:
                                BoxDecoration(
                              color:
                                  _mode ==
                                          'VIDEO'
                                      ? Colors
                                          .red
                                      : Colors
                                          .white,
                              shape:
                                  _recording
                                      ? BoxShape
                                          .rectangle
                                      : BoxShape
                                          .circle,
                              borderRadius:
                                  _recording
                                      ? BorderRadius
                                          .circular(
                                          9,
                                        )
                                      : null,
                            ),
                            child:
                                _recording
                                    ? const Icon(
                                        Icons
                                            .stop,
                                        color:
                                            Colors
                                                .white,
                                        size: 32,
                                      )
                                    : null,
                          ),
                        ),
                      ),

                      IconButton(
                        onPressed:
                            _switchCamera,
                        icon:
                            const Icon(
                          Icons
                              .cameraswitch,
                          size: 34,
                        ),
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

  Widget _modeButton(
    String key,
    String label,
  ) {
    final selected =
        _mode == key;

    final color =
        key == 'VIDEO'
            ? Colors.redAccent
            : Colors.greenAccent;

    return Padding(
      padding:
          const EdgeInsets.symmetric(
        horizontal: 5,
      ),
      child: TextButton(
        onPressed: () {
          if (_recording ||
              _busy) {
            return;
          }

          setState(() {
            _mode = key;
          });
        },
        style:
            TextButton.styleFrom(
          foregroundColor:
              selected
                  ? color
                  : Colors.white70,
          backgroundColor:
              selected
                  ? color.withOpacity(
                      .15,
                    )
                  : Colors.transparent,
          padding:
              const EdgeInsets
                  .symmetric(
            horizontal: 13,
            vertical: 8,
          ),
        ),
        child: Text(
          label,
          style:
              const TextStyle(
            fontWeight:
                FontWeight.bold,
            fontSize: 15,
          ),
        ),
      ),
    );
  }

  Widget _videoChip(
    String label,
  ) {
    final selected =
        _qualityLabel == label;

    return Padding(
      padding:
          const EdgeInsets.symmetric(
        horizontal: 3,
      ),
      child: ChoiceChip(
        label: Text(
          label,
          style:
              const TextStyle(
            fontSize: 11,
          ),
        ),
        selected: selected,
        onSelected: (_) {
          _changeQuality(
            label,
          );
        },
      ),
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
    final paint =
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