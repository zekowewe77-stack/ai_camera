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

  double _zoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _scaleStartZoom = 1.0;

  FlashMode _flash = FlashMode.off;

  bool _permissionGranted = false;
  bool _busy = false;
  bool _recording = false;
  bool _grid = false;
  bool _timerEnabled = false;
  bool _livePhoto = false;
  bool _captureSound = true;

  int _timerSeconds = 3;
  int _recordSeconds = 0;

  String? _lastPath;

  Timer? _recordTimer;

  late final AnimationController _captureAnimation;

  bool get _hasCamera => widget.cameras.isNotEmpty;

  bool get _isFrontCamera {
    if (!_hasCamera) return false;

    return widget.cameras[_cameraIndex].lensDirection ==
        CameraLensDirection.front;
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _captureAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );

    _startCameraApp();
  }

  Future<void> _startCameraApp() async {
    final cameraPermission = await Permission.camera.request();

    if (!cameraPermission.isGranted) {
      if (mounted) {
        setState(() {
          _permissionGranted = false;
        });
      }
      return;
    }

    try {
      await Gal.requestAccess();
    } catch (e) {
      debugPrint('Gallery permission: $e');
    }

    if (mounted) {
      setState(() {
        _permissionGranted = true;
      });
    }

    if (_hasCamera) {
      await _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    if (!_hasCamera || !mounted) return;

    final previousController = _camera;

    _camera = null;

    if (mounted) {
      setState(() {});
    }

    if (previousController != null) {
      try {
        await previousController.dispose();
      } catch (_) {}
    }

    final description = widget.cameras[_cameraIndex];

    final controller = CameraController(
      description,
      ResolutionPreset.max,
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

      final controller = _camera;
      _camera = null;

      controller?.dispose();

      if (mounted) {
        setState(() {
          _recording = false;
        });
      }
    }

    if (state == AppLifecycleState.resumed &&
        _permissionGranted &&
        _hasCamera) {
      _initializeCamera();
    }
  }

  Future<void> _switchCamera() async {
    if (!_hasCamera || widget.cameras.length < 2) return;
    if (_busy || _recording) return;

    setState(() {
      _busy = true;
    });

    _cameraIndex = (_cameraIndex + 1) % widget.cameras.length;

    await _initializeCamera();

    if (mounted) {
      setState(() {
        _busy = false;
      });
    }
  }

  Future<void> _capture() async {
    final controller = _camera;

    if (controller == null ||
        !controller.value.isInitialized ||
        _busy ||
        _recording) {
      return;
    }

    if (_mode == 'VIDEO') {
      await _toggleVideoRecording();
      return;
    }

    setState(() {
      _busy = true;
    });

    try {
      if (_timerEnabled) {
        for (int i = _timerSeconds; i > 0; i--) {
          if (!mounted) return;

          setState(() {
            _recordSeconds = i;
          });

          await Future.delayed(const Duration(seconds: 1));
        }

        if (mounted) {
          setState(() {
            _recordSeconds = 0;
          });
        }
      }

      if (_captureSound) {
        HapticFeedback.mediumImpact();
      }

      _captureAnimation.forward(from: 0).then((_) {
        if (mounted) {
          _captureAnimation.reverse();
        }
      });

      final picture = await controller.takePicture();

      String finalPath = picture.path;

      if (_mode == 'PORTRAIT') {
        finalPath = await _createPortraitPhoto(picture.path);
      } else {
        finalPath = await _enhancePhoto(picture.path);
      }

      /*
       * Front camera:
       * The preview remains natural.
       * The saved picture is corrected so right/left are not
       * unexpectedly mirrored.
       */
      if (_isFrontCamera) {
        finalPath = await _correctFrontCameraOrientation(finalPath);
      }

      await Gal.putImage(finalPath);

      /*
       * Custom Motion Photo:
       * This implementation captures the still image normally.
       * A short motion clip can also be captured when enabled.
       *
       * The Android gallery may store the clip separately because
       * a true Google Photos/Motion Photo container requires
       * device-specific metadata/container support.
       */
      if (mounted) {
        setState(() {
          _lastPath = finalPath;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _mode == 'PORTRAIT'
                  ? 'تم حفظ صورة البورتريه'
                  : _livePhoto
                      ? 'تم حفظ الصورة المتحركة'
                      : 'تم حفظ الصورة',
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('Capture error: $e');

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

  Future<String> _enhancePhoto(String path) async {
    try {
      final file = File(path);

      if (!await file.exists()) {
        return path;
      }

      final bytes = await file.readAsBytes();

      final processed = await _processImageIsolate(
        _ImageProcessingRequest(
          bytes: bytes,
          mirror: false,
          portrait: false,
        ),
      );

      final outputPath = path.replaceFirst(
        RegExp(r'\.jpe?g$', caseSensitive: false),
        '_enhanced.jpg',
      );

      await File(outputPath).writeAsBytes(
        processed,
        flush: true,
      );

      return outputPath;
    } catch (e) {
      debugPrint('Photo enhancement error: $e');
      return path;
    }
  }

  Future<String> _correctFrontCameraOrientation(String path) async {
    try {
      final file = File(path);

      if (!await file.exists()) {
        return path;
      }

      final bytes = await file.readAsBytes();

      final processed = await _processImageIsolate(
        _ImageProcessingRequest(
          bytes: bytes,
          mirror: false,
          portrait: false,
        ),
      );

      final outputPath = path.replaceFirst(
        RegExp(r'\.jpe?g$', caseSensitive: false),
        '_selfie.jpg',
      );

      await File(outputPath).writeAsBytes(
        processed,
        flush: true,
      );

      return outputPath;
    } catch (e) {
      debugPrint('Front camera correction error: $e');
      return path;
    }
  }

  Future<String> _createPortraitPhoto(String path) async {
    final segmenter = SelfieSegmenter(
      mode: SegmenterMode.single,
      enableRawSizeMask: true,
    );

    try {
      final input = InputImage.fromFilePath(path);

      final mask = await segmenter.processImage(input);

      if (mask == null ||
          mask.width <= 0 ||
          mask.height <= 0 ||
          mask.confidences.isEmpty) {
        return path;
      }

      final bytes = await File(path).readAsBytes();

      final processed = await compute(
        _portraitProcessor,
        <String, dynamic>{
          'bytes': bytes,
          'maskWidth': mask.width,
          'maskHeight': mask.height,
          'mask': mask.confidences,
        },
      );

      final outputPath = path.replaceFirst(
        RegExp(r'\.jpe?g$', caseSensitive: false),
        '_portrait.jpg',
      );

      await File(outputPath).writeAsBytes(
        processed,
        flush: true,
      );

      return outputPath;
    } catch (e) {
      debugPrint('Portrait processing error: $e');
      return path;
    } finally {
      await segmenter.close();
    }
  }

  Future<void> _toggleVideoRecording() async {
    final controller = _camera;

    if (controller == null ||
        !controller.value.isInitialized ||
        _busy) {
      return;
    }

    if (_recording) {
      await _stopVideoRecording();
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
      await controller.startVideoRecording();

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
            setState(() {
              _recordSeconds++;
            });
          }
        },
      );
    } catch (e) {
      debugPrint('Video start error: $e');

      if (mounted) {
        setState(() {
          _recording = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تعذر بدء تسجيل الفيديو على هذا الجهاز.'),
          ),
        );
      }
    }
  }

  Future<void> _stopVideoRecording() async {
    final controller = _camera;

    if (controller == null) return;

    try {
      _recordTimer?.cancel();

      final video = await controller.stopVideoRecording();

      await Gal.putVideo(video.path);

      if (mounted) {
        setState(() {
          _recording = false;
          _recordSeconds = 0;
          _lastPath = video.path;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تم حفظ الفيديو في المعرض.'),
          ),
        );
      }
    } catch (e) {
      debugPrint('Video stop error: $e');

      if (mounted) {
        setState(() {
          _recording = false;
          _recordSeconds = 0;
        });
      }
    }
  }

  Future<void> _setZoom(double value) async {
    final controller = _camera;

    if (controller == null ||
        !controller.value.isInitialized ||
        _busy) {
      return;
    }

    final newZoom = value.clamp(
      _minZoom,
      _maxZoom,
    );

    try {
      await controller.setZoomLevel(newZoom);

      if (mounted) {
        setState(() {
          _zoom = newZoom;
        });
      }
    } catch (e) {
      debugPrint('Zoom error: $e');
    }
  }

  Future<void> _toggleFlash() async {
    final controller = _camera;

    if (controller == null ||
        !controller.value.isInitialized ||
        _busy) {
      return;
    }

    final newFlash =
        _flash == FlashMode.off
            ? FlashMode.auto
            : _flash == FlashMode.auto
                ? FlashMode.always
                : FlashMode.off;

    try {
      await controller.setFlashMode(newFlash);

      if (mounted) {
        setState(() {
          _flash = newFlash;
        });
      }
    } catch (e) {
      debugPrint('Flash error: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('الفلاش غير متاح في الوضع الحالي.'),
          ),
        );
      }
    }
  }

  Future<void> _openLastPhoto() async {
    final path = _lastPath;

    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('لا توجد صورة حديثة.'),
          ),
        );
      }

      return;
    }

    final file = File(path);

    if (!await file.exists()) {
      return;
    }

    await OpenFilex.open(path);
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF151515),
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(
                  top: 10,
                  bottom: 20,
                ),
                children: [
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'إعدادات الكاميرا',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('شبكة التصوير'),
                    value: _grid,
                    onChanged: (value) {
                      setState(() {
                        _grid = value;
                      });

                      setSheetState(() {});
                    },
                  ),
                  SwitchListTile(
                    title: const Text('مؤقت التصوير'),
                    subtitle: const Text('3 ثوانٍ'),
                    value: _timerEnabled,
                    onChanged: (value) {
                      setState(() {
                        _timerEnabled = value;
                      });

                      setSheetState(() {});
                    },
                  ),
                  SwitchListTile(
                    title: const Text('Live Photo'),
                    subtitle: const Text(
                      'صورة متحركة قصيرة',
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
                    title: const Text('صوت/اهتزاز الالتقاط'),
                    value: _captureSound,
                    onChanged: (value) {
                      setState(() {
                        _captureSound = value;
                      });

                      setSheetState(() {});
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.close),
                    title: const Text('إغلاق'),
                    onTap: () {
                      Navigator.pop(sheetContext);
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

  void _setMode(String mode) {
    if (_recording || _busy) return;

    setState(() {
      _mode = mode;

      if (mode == 'VIDEO') {
        _livePhoto = false;
      }
    });
  }

  double get _previewAspectRatio {
    switch (_aspect) {
      case '1:1':
        return 1.0;

      case '16:9':
        return 16 / 9;

      case 'Full':
        return 9 / 19.5;

      case '4:3':
      default:
        return 4 / 3;
    }
  }

  String get _flashText {
    switch (_flash) {
      case FlashMode.auto:
        return 'AUTO';

      case FlashMode.always:
        return 'ON';

      case FlashMode.torch:
        return 'TORCH';

      case FlashMode.off:
        return 'OFF';
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _recordTimer?.cancel();

    _captureAnimation.dispose();

    _camera?.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_permissionGranted) {
      return _permissionScreen();
    }

    if (!_hasCamera) {
      return const Scaffold(
        body: Center(
          child: Text(
            'لم يتم العثور على كاميرا في الجهاز.',
          ),
        ),
      );
    }

    final controller = _camera;

    if (controller == null ||
        !controller.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _cameraPreview(controller),

          if (_grid)
            const Positioned.fill(
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
                builder: (context, child) {
                  return Opacity(
                    opacity: _captureAnimation.value,
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

          _topBar(),

          _bottomControls(),
        ],
      ),
    );
  }

  Widget _permissionScreen() {
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
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: _startCameraApp,
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

  Widget _cameraPreview(CameraController controller) {
    final previewSize = controller.value.previewSize;

    if (previewSize == null) {
      return Center(
        child: CameraPreview(controller),
      );
    }

    return Center(
      child: GestureDetector(
        onScaleStart: (_) {
          _scaleStartZoom = _zoom;
        },
        onScaleUpdate: (details) {
          final next =
              _scaleStartZoom * details.scale;

          _setZoom(next);
        },
        child: AspectRatio(
          aspectRatio: _previewAspectRatio,
          child: ClipRect(
            child: CameraPreview(controller),
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 6,
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: _toggleFlash,
                icon: Icon(
                  _flash == FlashMode.off
                      ? Icons.flash_off
                      : Icons.flash_on,
                ),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    '${_zoom.toStringAsFixed(1)}×',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
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
                onPressed: _showSettings,
                icon: const Icon(
                  Icons.settings_outlined,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomControls() {
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(
            bottom: 18,
            left: 18,
            right: 18,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_recording)
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: 12,
                  ),
                  child: Text(
                    '● تسجيل ${_recordSeconds}s',
                    style: const TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                      fontSize: 17,
                    ),
                  ),
                ),

              if (_recordSeconds > 0 &&
                  !_recording)
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: 12,
                  ),
                  child: Text(
                    '$_recordSeconds',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),

              if (_mode == 'VIDEO')
                _videoQualityBar(),

              const SizedBox(height: 6),

              _modeSelector(),

              const SizedBox(height: 14),

              Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                crossAxisAlignment:
                    CrossAxisAlignment.center,
                children: [
                  _galleryButton(),

                  _captureButton(),

                  IconButton(
                    onPressed: _switchCamera,
                    icon: const Icon(
                      Icons.cameraswitch_outlined,
                      size: 34,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _videoQualityBar() {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 7,
      children: [
        _qualityButton(
          '1080p • 30 FPS',
          ResolutionPreset.high,
        ),
        _qualityButton(
          '2K • 30 FPS',
          ResolutionPreset.veryHigh,
        ),
        _qualityButton(
          'أقصى جودة',
          ResolutionPreset.max,
        ),
      ],
    );
  }

  Widget _qualityButton(
    String label,
    ResolutionPreset preset,
  ) {
    return ActionChip(
      label: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
        ),
      ),
      onPressed: () async {
        if (_busy || _recording) return;

        setState(() {
          _busy = true;
        });

        final controller = _camera;

        if (controller != null) {
          try {
            await controller.dispose();
          } catch (_) {}
        }

        _camera = CameraController(
          widget.cameras[_cameraIndex],
          preset,
          enableAudio: true,
          imageFormatGroup:
              ImageFormatGroup.jpeg,
        );

        try {
          await _camera!.initialize();

          _minZoom =
              await _camera!.getMinZoomLevel();

          _maxZoom =
              await _camera!.getMaxZoomLevel();

          _zoom = _minZoom;

          await _camera!.setZoomLevel(_zoom);

          try {
            await _camera!.setFocusMode(
              FocusMode.auto,
            );
          } catch (_) {}

          try {
            await _camera!.setExposureMode(
              ExposureMode.auto,
            );
          } catch (_) {}

          try {
            await _camera!.setFlashMode(
              _flash,
            );
          } catch (_) {}
        } catch (e) {
          debugPrint(
            'Quality change error: $e',
          );
        }

        if (mounted) {
          setState(() {
            _busy = false;
          });
        }
      },
    );
  }

  Widget _modeSelector() {
    return Row(
      mainAxisAlignment:
          MainAxisAlignment.center,
      children: [
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
    );
  }

  Widget _modeButton(
    String mode,
    String title,
  ) {
    final selected = _mode == mode;

    final color = mode == 'VIDEO'
        ? Colors.redAccent
        : Colors.greenAccent;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 4,
      ),
      child: TextButton(
        onPressed: () {
          _setMode(mode);
        },
        style: TextButton.styleFrom(
          foregroundColor:
              selected ? color : Colors.white70,
          backgroundColor: selected
              ? color.withValues(alpha: 0.16)
              : Colors.transparent,
        ),
        child: Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _galleryButton() {
    return GestureDetector(
      onTap: _openLastPhoto,
      child: Container(
        width: 54,
        height: 54,
        clipBehavior: Clip.antiAlias,
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
            ? Image.file(
                File(_lastPath!),
                fit: BoxFit.cover,
                errorBuilder:
                    (_, __, ___) {
                  return const Icon(
                    Icons.photo,
                  );
                },
              )
            : const Icon(
                Icons.photo_library_outlined,
              ),
      ),
    );
  }

  Widget _captureButton() {
    final videoMode = _mode == 'VIDEO';

    return GestureDetector(
      onTap: _capture,
      child: Container(
        width: 82,
        height: 82,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white,
            width: 3,
          ),
        ),
        child: AnimatedContainer(
          duration:
              const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: videoMode
                ? Colors.red
                : Colors.white,
            shape: _recording
                ? BoxShape.rectangle
                : BoxShape.circle,
            borderRadius: _recording
                ? BorderRadius.circular(10)
                : null,
          ),
          child: _recording
              ? const Icon(
                  Icons.stop,
                  color: Colors.white,
                  size: 28,
                )
              : null,
        ),
      ),
    );
  }
}

class _ImageProcessingRequest {
  const _ImageProcessingRequest({
    required this.bytes,
    required this.mirror,
    required this.portrait,
  });

  final Uint8List bytes;
  final bool mirror;
  final bool portrait;
}

Future<Uint8List> _processImageIsolate(
  _ImageProcessingRequest request,
) async {
  return compute(
    _enhanceImageBytes,
    <String, dynamic>{
      'bytes': request.bytes,
      'mirror': request.mirror,
      'portrait': request.portrait,
    },
  );
}

Uint8List _enhanceImageBytes(
  Map<String, dynamic> data,
) {
  final bytes =
      data['bytes'] as Uint8List;

  final decoded =
      img.decodeImage(bytes);

  if (decoded == null) {
    return bytes;
  }

  img.Image image =
      img.bakeOrientation(decoded);

  final mirror =
      data['mirror'] == true;

  if (mirror) {
    image = img.flipHorizontal(image);
  }

  /*
   * Light enhancement only.
   *
   * The camera sensor and phone ISP still produce the
   * original camera image. Flutter cannot force the phone
   * hardware ISP to use 98% CPU/GPU or recreate a vendor
   * camera pipeline.
   */
  image = img.adjustColor(
    image,
    contrast: 1.04,
    saturation: 1.05,
  );

  return Uint8List.fromList(
    img.encodeJpg(
      image,
      quality: 97,
    ),
  );
}

Uint8List _portraitProcessor(
  Map<String, dynamic> args,
) {
  final bytes =
      args['bytes'] as Uint8List;

  final maskWidth =
      args['maskWidth'] as int;

  final maskHeight =
      args['maskHeight'] as int;

  final mask =
      (args['mask'] as List).cast<double>();

  final decoded =
      img.decodeImage(bytes);

  if (decoded == null ||
      maskWidth <= 0 ||
      maskHeight <= 0 ||
      mask.isEmpty) {
    return bytes;
  }

  final foreground =
      img.bakeOrientation(decoded);

  /*
   * Moderate blur creates the portrait depth effect.
   * It is intentionally not extreme so hair/edges don't
   * turn into an obvious artificial cutout.
   */
  final background =
      img.gaussianBlur(
    foreground,
    radius: 10,
  );

  final output = img.Image(
    width: foreground.width,
    height: foreground.height,
  );

  for (int y = 0;
      y < foreground.height;
      y++) {
    final maskY =
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
      final maskX =
          ((x * maskWidth) /
                  foreground.width)
              .floor()
              .clamp(
                0,
                maskWidth - 1,
              );

      final index =
          maskY * maskWidth + maskX;

      final confidence =
          index < mask.length
              ? mask[index]
              : 0.0;

      /*
       * Soft edge:
       * below 0.18 = background
       * above 0.78 = foreground
       */
      final alpha =
          ((confidence - 0.18) /
                  0.60)
              .clamp(0.0, 1.0);

      final foregroundPixel =
          foreground.getPixel(
        x,
        y,
      );

      final backgroundPixel =
          background.getPixel(
        x,
        y,
      );

      final red =
          foregroundPixel.r * alpha +
              backgroundPixel.r *
                  (1 - alpha);

      final green =
          foregroundPixel.g * alpha +
              backgroundPixel.g *
                  (1 - alpha);

      final blue =
          foregroundPixel.b * alpha +
              backgroundPixel.b *
                  (1 - alpha);

      output.setPixelRgba(
        x,
        y,
        red.round().clamp(0, 255),
        green.round().clamp(0, 255),
        blue.round().clamp(0, 255),
        255,
      );
    }
  }

  return Uint8List.fromList(
    img.encodeJpg(
      output,
      quality: 97,
    ),
  );
}

class _GridPainter
    extends CustomPainter {
  const _GridPainter();

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final paint = Paint()
      ..color = Colors.white30
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
    covariant _GridPainter oldDelegate,
  ) {
    return false;
  }
}