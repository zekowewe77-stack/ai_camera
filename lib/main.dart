import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera discovery error: $e');
  }

  runApp(const CameraApp());
}

class CameraApp extends StatelessWidget {
  const CameraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AI Camera Pro 2027',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        useMaterial3: true,
      ),
      home: const CameraScreen(),
    );
  }
}

class ImageProcessArgs {
  final Uint8List bytes;
  final bool hdr;
  final double zoom;

  const ImageProcessArgs({
    required this.bytes,
    required this.hdr,
    required this.zoom,
  });
}

/// معالجة الصورة خارج الـUI لتقليل التهنيج.
Uint8List _processImageInIsolate(
  ImageProcessArgs args,
) {
  try {
    img.Image? image =
        img.decodeImage(args.bytes);

    if (image == null) {
      return args.bytes;
    }

    // تصحيح تلقائي خفيف يحافظ على التفاصيل.
    if (args.hdr) {
      image = img.adjustColor(
        image,
        contrast: 1.08,
        brightness: 1.01,
        saturation: 1.05,
      );
    }

    // عند الزوم نزيد الوضوح والتباين بشكل محافظ.
    if (args.zoom > 1.5) {
      image = img.adjustColor(
        image,
        contrast: 1.10,
        brightness: 1.01,
        saturation: 1.04,
      );
    }

    // لا نقلب الصورة الأمامية هنا.
    // الـpreview فقط هو الذي يتم عمل mirror له.

    return Uint8List.fromList(
      img.encodeJpg(
        image,
        quality: 98,
      ),
    );
  } catch (_) {
    return args.bytes;
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() =>
      _CameraScreenState();
}

class _CameraScreenState
    extends State<CameraScreen>
    with
        WidgetsBindingObserver,
        SingleTickerProviderStateMixin {
  CameraController? controller;

  int selectedCameraIndex = 0;

  bool isPermissionGranted = false;

  FlashMode _flashMode =
      FlashMode.off;

  double _currentZoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;

  double _minExposure = -2.0;
  double _maxExposure = 2.0;
  double _exposure = 0.0;

  bool _showZoomWheel = false;
  DateTime _lastZoomInteraction =
      DateTime.now();

  String _currentMode = 'PHOTO';

  bool _isRecording = false;
  bool _isProcessing = false;

  int _countdownSeconds = 0;

  Timer? _videoTimer;
  int _videoSeconds = 0;

  bool _showExpandedPanel = false;

  // الإعدادات الأصلية.
  bool _isHdrActive = true;
  bool _isTimerActive = false;
  int _selectedTimerSeconds = 3;

  bool _isWatermarkActive = false;
  String _customWatermarkText =
      'AI Camera Pro 2027';

  bool _isGridActive = false;
  bool _isAiFocusEnabled = true;
  bool _isLocationActive = false;

  bool _shutterSound = true;
  bool _cloneShutterButton = false;
  bool _horizonLevel = false;
  bool _dirtyLensNotice = true;
  String _portraitFps = 'تلقائي';
  bool _qrScannerActive = true;

  // النسب المطلوبة.
  String _selectedAspectRatio =
      '4:3';

  late AnimationController
      _flashAnimController;

  Timer? _zoomHideTimer;

  bool get _isFrontCamera {
    if (cameras.isEmpty) {
      return false;
    }

    return cameras[
          selectedCameraIndex
        ].lensDirection ==
        CameraLensDirection.front;
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance
        .addObserver(this);

    _flashAnimController =
        AnimationController(
      vsync: this,
      duration:
          const Duration(
        milliseconds: 130,
      ),
    );

    _requestPermissionAndInit();
  }

  @override
  void didChangeAppLifecycleState(
    AppLifecycleState state,
  ) {
    if (state ==
            AppLifecycleState.inactive ||
        state ==
            AppLifecycleState.paused) {
      final oldController =
          controller;

      controller = null;

      oldController?.dispose();

      return;
    }

    if (state ==
        AppLifecycleState.resumed) {
      if (cameras.isNotEmpty) {
        _initCamera(
          selectedCameraIndex,
        );
      }
    }
  }

  Future<void>
      _requestPermissionAndInit() async {
    final cameraPermission =
        await Permission.camera
            .request();

    await Permission.microphone
        .request();

    try {
      await Gal.requestAccess();
    } catch (e) {
      debugPrint(
        'Gallery permission: $e',
      );
    }

    if (!cameraPermission
        .isGranted) {
      if (mounted) {
        setState(() {
          isPermissionGranted =
              false;
        });
      }

      return;
    }

    if (mounted) {
      setState(() {
        isPermissionGranted =
            true;
      });
    }

    if (cameras.isNotEmpty) {
      await _initCamera(
        selectedCameraIndex,
      );
    }
  }

  Future<void> _initCamera(
    int index,
  ) async {
    if (cameras.isEmpty) {
      return;
    }

    if (index < 0 ||
        index >= cameras.length) {
      index = 0;
    }

    final oldController =
        controller;

    controller = null;

    if (oldController != null) {
      try {
        await oldController
            .dispose();
      } catch (_) {}
    }

    if (mounted) {
      setState(() {});
    }

    final newController =
        CameraController(
      cameras[index],
      ResolutionPreset.max,
      enableAudio: true,
      imageFormatGroup:
          ImageFormatGroup.jpeg,
    );

    try {
      await newController
          .initialize();

      // التركيز التلقائي.
      try {
        await newController
            .setFocusMode(
          FocusMode.auto,
        );
      } catch (_) {}

      // التعريض التلقائي.
      try {
        await newController
            .setExposureMode(
          ExposureMode.auto,
        );
      } catch (_) {}

      final minZoom =
          await newController
              .getMinZoomLevel();

      final maxZoom =
          await newController
              .getMaxZoomLevel();

      final minExposure =
          await newController
              .getMinExposureOffset();

      final maxExposure =
          await newController
              .getMaxExposureOffset();

      _minZoom =
          minZoom.isFinite &&
                  minZoom > 0
              ? minZoom
              : 1.0;

      _maxZoom =
          maxZoom.isFinite &&
                  maxZoom >= _minZoom
              ? maxZoom
              : _minZoom;

      _minExposure =
          minExposure.isFinite
              ? minExposure
              : -2.0;

      _maxExposure =
          maxExposure.isFinite
              ? maxExposure
              : 2.0;

      _currentZoom =
          _minZoom;

      _exposure = 0.0;

      await newController
          .setZoomLevel(
        _currentZoom,
      );

      try {
        await newController
            .setExposureMode(
          ExposureMode.auto,
        );
      } catch (_) {}

      try {
        await newController
            .setFlashMode(
          _flashMode,
        );
      } catch (_) {}

      controller =
          newController;

      selectedCameraIndex =
          index;

      if (!mounted) {
        return;
      }

      setState(() {});
    } catch (e, stack) {
      debugPrint(
        'Camera initialization error: $e',
      );

      debugPrint(
        stack.toString(),
      );

      try {
        await newController
            .dispose();
      } catch (_) {}

      controller = null;

      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _switchCamera() async {
    if (_isProcessing ||
        _isRecording ||
        cameras.length < 2) {
      return;
    }

    final nextIndex =
        (selectedCameraIndex + 1) %
            cameras.length;

    await _initCamera(
      nextIndex,
    );
  }

  Future<void> _setZoom(
    double value,
  ) async {
    final cam = controller;

    if (cam == null ||
        !cam.value.isInitialized ||
        _isRecording) {
      return;
    }

    final zoom =
        value.clamp(
      _minZoom,
      _maxZoom,
    );

    try {
      await cam.setZoomLevel(
        zoom,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _currentZoom =
            zoom.toDouble();

        _showZoomWheel = true;

        _lastZoomInteraction =
            DateTime.now();
      });

      _zoomHideTimer?.cancel();

      _zoomHideTimer =
          Timer(
        const Duration(
          seconds: 2,
        ),
        () {
          if (!mounted) {
            return;
          }

          setState(() {
            _showZoomWheel = false;
          });
        },
      );
    } catch (e) {
      debugPrint(
        'Zoom error: $e',
      );
    }
  }

  Future<void> _setExposure(
    double value,
  ) async {
    final cam = controller;

    if (cam == null ||
        !cam.value.isInitialized) {
      return;
    }

    final exposure =
        value.clamp(
      _minExposure,
      _maxExposure,
    );

    try {
      await cam.setExposureOffset(
        exposure.toDouble(),
      );

      if (mounted) {
        setState(() {
          _exposure =
              exposure.toDouble();
        });
      }
    } catch (e) {
      debugPrint(
        'Exposure error: $e',
      );
    }
  }

  Future<void> _focusAt(
    Offset localPosition,
    Size size,
  ) async {
    final cam = controller;

    if (cam == null ||
        !cam.value.isInitialized) {
      return;
    }

    final dx =
        (localPosition.dx /
                size.width)
            .clamp(0.0, 1.0);

    final dy =
        (localPosition.dy /
                size.height)
            .clamp(0.0, 1.0);

    try {
      if (_isAiFocusEnabled) {
        await cam.setFocusPoint(
          Offset(
            dx,
            dy,
          ),
        );
      }

      await cam.setExposurePoint(
        Offset(
          dx,
          dy,
        ),
      );
    } catch (e) {
      debugPrint(
        'Focus/exposure point error: $e',
      );
    }
  }

  Future<String>
      _enhanceAndSharpenImage(
    String imagePath,
    bool isFront,
    double zoomLevel,
  ) async {
    try {
      final file =
          File(imagePath);

      if (!await file.exists()) {
        return imagePath;
      }

      final bytes =
          await file.readAsBytes();

      final processed =
          await Isolate.run<
              Uint8List>(
        () =>
            _processImageInIsolate(
          ImageProcessArgs(
            bytes: bytes,
            hdr: _isHdrActive,
            zoom: zoomLevel,
          ),
        ),
      );

      if (processed.isEmpty) {
        return imagePath;
      }

      await file.writeAsBytes(
        processed,
        flush: true,
      );

      return imagePath;
    } catch (e, stack) {
      debugPrint(
        'Image processing error: $e',
      );

      debugPrint(
        stack.toString(),
      );

      return imagePath;
    }
  }

  Future<void>
      _captureAction() async {
    final cam = controller;

    if (cam == null ||
        !cam.value.isInitialized ||
        _isProcessing) {
      return;
    }

    if (_currentMode ==
        'VIDEO') {
      await _toggleVideoRecording();
      return;
    }

    if (_isTimerActive) {
      if (mounted) {
        setState(() {
          _countdownSeconds =
              _selectedTimerSeconds;
        });
      }

      for (
        int i =
            _selectedTimerSeconds;
        i > 0;
        i--
      ) {
        await Future.delayed(
          const Duration(
            seconds: 1,
          ),
        );

        if (!mounted) {
          return;
        }

        setState(() {
          _countdownSeconds =
              i - 1;
        });
      }
    }

    try {
      if (_shutterSound) {
        SystemSound.play(
          SystemSoundType.click,
        );

        HapticFeedback
            .heavyImpact();
      }

      _flashAnimController
          .forward(
        from: 0,
      )
          .then(
        (_) =>
            _flashAnimController
                .reverse(),
      );

      if (mounted) {
        setState(() {
          _isProcessing = true;
          _showExpandedPanel =
              false;
          _showZoomWheel = false;
        });
      }

      final XFile image =
          await cam.takePicture();

      final bool isFront =
          _isFrontCamera;

      final String path =
          await _enhanceAndSharpenImage(
        image.path,
        isFront,
        _currentZoom,
      );

      final hasAccess =
          await Gal.requestAccess();

      if (!hasAccess) {
        throw Exception(
          'Gallery access denied',
        );
      }

      await Gal.putImage(
        path,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _isProcessing = false;
      });

      _showMessage(
        'تم حفظ الصورة بجودة عالية في المعرض',
      );
    } catch (e, stack) {
      debugPrint(
        'Capture error: $e',
      );

      debugPrint(
        stack.toString(),
      );

      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }

      _showMessage(
        'حدث خطأ أثناء التصوير',
      );
    }
  }

  Future<void>
      _toggleVideoRecording() async {
    final cam = controller;

    if (cam == null ||
        !cam.value.isInitialized) {
      return;
    }

    try {
      if (_isRecording) {
        _videoTimer?.cancel();

        final XFile video =
            await cam
                .stopVideoRecording();

        if (mounted) {
          setState(() {
            _isRecording = false;
            _videoSeconds = 0;
            _isProcessing = true;
          });
        }

        final hasAccess =
            await Gal.requestAccess();

        if (!hasAccess) {
          throw Exception(
            'Gallery access denied',
          );
        }

        await Gal.putVideo(
          video.path,
        );

        if (mounted) {
          setState(() {
            _isProcessing = false;
          });
        }

        _showMessage(
          'تم حفظ الفيديو في المعرض',
        );
      } else {
        await cam
            .startVideoRecording();

        if (!mounted) {
          return;
        }

        setState(() {
          _isRecording = true;
          _videoSeconds = 0;
        });

        _videoTimer?.cancel();

        _videoTimer =
            Timer.periodic(
          const Duration(
            seconds: 1,
          ),
          (timer) {
            if (!mounted ||
                !_isRecording) {
              timer.cancel();
              return;
            }

            setState(() {
              _videoSeconds++;
            });
          },
        );
      }
    } catch (e, stack) {
      debugPrint(
        'Video error: $e',
      );

      debugPrint(
        stack.toString(),
      );

      _videoTimer?.cancel();

      if (mounted) {
        setState(() {
          _isRecording = false;
          _isProcessing = false;
          _videoSeconds = 0;
        });
      }

      _showMessage(
        'حدث خطأ أثناء الفيديو',
      );
    }
  }

  Future<void> _openGallery() async {
    try {
      await Gal.open();
    } catch (e) {
      debugPrint(
        'Open gallery error: $e',
      );

      _showMessage(
        'تعذر فتح المعرض',
      );
    }
  }

  double _getAspectRatioValue() {
    switch (_selectedAspectRatio) {
      case '4:3':
        return 3 / 4;

      case '16:9':
        return 9 / 16;

      case '19.5:9':
        return 9 / 19.5;

      default:
        return 3 / 4;
    }
  }

  void _cycleAspectRatio() {
    setState(() {
      switch (_selectedAspectRatio) {
        case '4:3':
          _selectedAspectRatio =
              '16:9';
          break;

        case '16:9':
          _selectedAspectRatio =
              '19.5:9';
          break;

        default:
          _selectedAspectRatio =
              '4:3';
      }
    });
  }

  void _toggleFlash() async {
    final cam = controller;

    if (cam == null ||
        !cam.value.isInitialized) {
      return;
    }

    final next =
        _flashMode ==
                FlashMode.off
            ? FlashMode.torch
            : FlashMode.off;

    try {
      await cam.setFlashMode(
        next,
      );

      if (mounted) {
        setState(() {
          _flashMode = next;
        });
      }
    } catch (e) {
      debugPrint(
        'Flash error: $e',
      );
    }
  }

  void _showMessage(
    String message,
  ) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).hideCurrentSnackBar();

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content:
            Text(
          message,
          textDirection:
              TextDirection.rtl,
        ),
        behavior:
            SnackBarBehavior.floating,
      ),
    );
  }

  void _showWatermarkDialog() {
    final textController =
        TextEditingController(
      text:
          _customWatermarkText,
    );

    showDialog(
      context: context,
      builder:
          (context) =>
              AlertDialog(
        backgroundColor:
            Colors.grey[900],
        title:
            const Text(
          'إعدادات العلامة المائية المخصصة',
          style:
              TextStyle(
            color:
                Colors.white,
            fontSize:
                16,
          ),
        ),
        content:
            TextField(
          controller:
              textController,
          style:
              const TextStyle(
            color:
                Colors.white,
          ),
          decoration:
              const InputDecoration(
            hintText:
                'اكتب النص هنا...',
            hintStyle:
                TextStyle(
              color:
                  Colors.white54,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed:
                () =>
                    Navigator.pop(
              context,
            ),
            child:
                const Text(
              'إلغاء',
              style:
                  TextStyle(
                color:
                    Colors.redAccent,
              ),
            ),
          ),
          TextButton(
            onPressed:
                () {
              setState(() {
                _customWatermarkText =
                    textController
                        .text;

                _isWatermarkActive =
                    true;
              });

              Navigator.pop(
                context,
              );
            },
            child:
                const Text(
              'حفظ',
              style:
                  TextStyle(
                color:
                    Colors.greenAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showTimerDialog() {
    showDialog(
      context: context,
      builder:
          (context) =>
              AlertDialog(
        backgroundColor:
            Colors.grey[900],
        title:
            const Text(
          'اختر وقت المؤقت',
          style:
              TextStyle(
            color:
                Colors.white,
            fontSize:
                16,
          ),
        ),
        content:
            Column(
          mainAxisSize:
              MainAxisSize.min,
          children: [
            ListTile(
              title:
                  const Text(
                '3 ثواني',
                style:
                    TextStyle(
                  color:
                      Colors.white,
                ),
              ),
              onTap:
                  () {
                setState(() {
                  _selectedTimerSeconds =
                      3;

                  _isTimerActive =
                      true;
                });

                Navigator.pop(
                  context,
                );
              },
            ),
            ListTile(
              title:
                  const Text(
                '5 ثواني',
                style:
                    TextStyle(
                  color:
                      Colors.white,
                ),
              ),
              onTap:
                  () {
                setState(() {
                  _selectedTimerSeconds =
                      5;

                  _isTimerActive =
                      true;
                });

                Navigator.pop(
                  context,
                );
              },
            ),
            ListTile(
              title:
                  const Text(
                '10 ثواني',
                style:
                    TextStyle(
                  color:
                      Colors.white,
                ),
              ),
              onTap:
                  () {
                setState(() {
                  _selectedTimerSeconds =
                      10;

                  _isTimerActive =
                      true;
                });

                Navigator.pop(
                  context,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _formatVideoTime() {
    final minutes =
        _videoSeconds ~/ 60;

    final seconds =
        _videoSeconds % 60;

    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildMenuOption({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child:
          Column(
        mainAxisAlignment:
            MainAxisAlignment
                .center,
        children: [
          Icon(
            icon,
            color:
                isActive
                    ? Colors
                        .greenAccent
                    : Colors.white70,
            size: 22,
          ),
          const SizedBox(
            height: 4,
          ),
          Text(
            label,
            textAlign:
                TextAlign.center,
            style:
                TextStyle(
              color:
                  isActive
                      ? Colors
                          .greenAccent
                      : Colors.white70,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    if (!isPermissionGranted) {
      return const Scaffold(
        backgroundColor:
            Colors.black,
        body:
            Center(
          child:
              Text(
            'Please grant camera permissions',
            style:
                TextStyle(
              color:
                  Colors.white,
            ),
          ),
        ),
      );
    }

    final cam = controller;

    if (cam == null ||
        !cam.value.isInitialized) {
      return const Scaffold(
        backgroundColor:
            Colors.black,
        body:
            Center(
          child:
              CircularProgressIndicator(
            color:
                Colors.greenAccent,
          ),
        ),
      );
    }

    final isFront =
        _isFrontCamera;

    final preview =
        AspectRatio(
      aspectRatio:
          _getAspectRatioValue(),
      child:
          Transform(
        alignment:
            Alignment.center,
        transform:
            isFront
                ? Matrix4
                    .rotationY(
                    3.141592653589793,
                  )
                : Matrix4.identity(),
        child:
            CameraPreview(
          cam,
        ),
      ),
    );

    return Scaffold(
      backgroundColor:
          Colors.black,
      body:
          Stack(
        children: [
          Positioned.fill(
            child:
                GestureDetector(
              onTapDown:
                  (details) {
                _focusAt(
                  details
                      .localPosition,
                  MediaQuery.of(
                    context,
                  ).size,
                );
              },
              onScaleStart:
                  (_) {
                setState(() {
                  _showZoomWheel =
                      true;

                  _showExpandedPanel =
                      false;
                });
              },
              onScaleUpdate:
                  (details) {
                if (details.scale ==
                    1.0) {
                  return;
                }

                final factor =
                    details.scale;

                final newZoom =
                    _currentZoom *
                        factor;

                _setZoom(
                  newZoom,
                );
              },
              child:
                  Center(
                child:
                    preview,
              ),
            ),
          ),

          // وميض الالتقاط.
          Positioned.fill(
            child:
                IgnorePointer(
              child:
                  AnimatedBuilder(
                animation:
                    _flashAnimController,
                builder:
                    (
                  context,
                  child,
                ) {
                  return Opacity(
                    opacity:
                        _flashAnimController
                            .value,
                    child:
                        Container(
                      color:
                          Colors.white,
                    ),
                  );
                },
              ),
            ),
          ),

          if (_isGridActive)
            Positioned.fill(
              child:
                  IgnorePointer(
                child:
                    CustomPaint(
                  painter:
                      GridPainter(),
                ),
              ),
            ),

          if (_countdownSeconds >
              0)
            Positioned(
              top:
                  MediaQuery.of(
                        context,
                      ).size.height /
                      2 -
                  50,
              left: 0,
              right: 0,
              child:
                  Center(
                child:
                    Text(
                  '$_countdownSeconds',
                  style:
                      const TextStyle(
                    color:
                        Colors.greenAccent,
                    fontSize:
                        80,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),
            ),

          if (_isWatermarkActive ||
              _isLocationActive)
            Positioned(
              bottom: 140,
              left: 20,
              child:
                  Container(
                padding:
                    const EdgeInsets
                        .symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration:
                    BoxDecoration(
                  color:
                      Colors.black54,
                  borderRadius:
                      BorderRadius
                          .circular(
                    6,
                  ),
                ),
                child:
                    Column(
                  crossAxisAlignment:
                      CrossAxisAlignment
                          .start,
                  children: [
                    if (_isWatermarkActive)
                      Text(
                        _customWatermarkText,
                        style:
                            const TextStyle(
                          color:
                              Colors.white,
                          fontSize:
                              11,
                          fontWeight:
                              FontWeight
                                  .bold,
                        ),
                      ),
                    if (_isLocationActive)
                      const Text(
                        '📍 مصر، القاهرة',
                        style:
                            TextStyle(
                          color:
                              Colors.greenAccent,
                          fontSize:
                              9,
                        ),
                      ),
                  ],
                ),
              ),
            ),

          if (_isRecording)
            Positioned(
              top: 55,
              left: 0,
              right: 0,
              child:
                  Center(
                child:
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
                      0.9,
                    ),
                    borderRadius:
                        BorderRadius
                            .circular(
                      20,
                    ),
                  ),
                  child:
                      Text(
                    '● ${_formatVideoTime()}',
                    style:
                        const TextStyle(
                      color:
                          Colors.white,
                      fontSize:
                          12,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),

          if (_showZoomWheel)
            Positioned(
              bottom: 220,
              left: 0,
              right: 0,
              child:
                  Center(
                child:
                    Container(
                  height: 72,
                  width: 280,
                  padding:
                      const EdgeInsets
                          .symmetric(
                    horizontal: 12,
                  ),
                  decoration:
                      BoxDecoration(
                    color: Colors.black
                        .withOpacity(
                      0.88,
                    ),
                    borderRadius:
                        BorderRadius
                            .circular(
                      25,
                    ),
                    border:
                        Border.all(
                      color:
                          Colors.greenAccent
                              .withOpacity(
                        0.6,
                      ),
                    ),
                  ),
                  child:
                      Column(
                    mainAxisAlignment:
                        MainAxisAlignment
                            .center,
                    children: [
                      Text(
                        'زوم: ${_currentZoom.toStringAsFixed(1)}x  |  الحد: ${_maxZoom.toStringAsFixed(1)}x',
                        style:
                            const TextStyle(
                          color:
                              Colors.greenAccent,
                          fontSize:
                              11,
                          fontWeight:
                              FontWeight
                                  .bold,
                        ),
                      ),
                      Slider(
                        value:
                            _currentZoom
                                .clamp(
                          _minZoom,
                          _maxZoom,
                        ),
                        min:
                            _minZoom,
                        max:
                            _maxZoom,
                        activeColor:
                            Colors
                                .greenAccent,
                        inactiveColor:
                            Colors.white24,
                        onChanged:
                            _setZoom,
                      ),
                    ],
                  ),
                ),
              ),
            ),

          Positioned(
            top: 42,
            left: 12,
            right: 12,
            child:
                Row(
              mainAxisAlignment:
                  MainAxisAlignment
                      .spaceBetween,
              children: [
                IconButton(
                  icon:
                      Icon(
                    _flashMode ==
                            FlashMode
                                .torch
                        ? Icons
                            .flash_on
                        : Icons
                            .flash_off,
                    color:
                        Colors.white,
                    size: 22,
                  ),
                  onPressed:
                      _toggleFlash,
                ),

                GestureDetector(
                  onTap:
                      () {
                    setState(() {
                      _showExpandedPanel =
                          !_showExpandedPanel;
                    });
                  },
                  child:
                      Container(
                    padding:
                        const EdgeInsets
                            .all(
                      6,
                    ),
                    decoration:
                        const BoxDecoration(
                      color:
                          Colors.black54,
                      shape:
                          BoxShape.circle,
                    ),
                    child:
                        Icon(
                      _showExpandedPanel
                          ? Icons
                              .expand_less
                          : Icons
                              .expand_more,
                      color:
                          Colors.greenAccent,
                      size:
                          22,
                    ),
                  ),
                ),

                IconButton(
                  icon:
                      Icon(
                    _isAiFocusEnabled
                        ? Icons
                            .auto_awesome
                        : Icons
                            .auto_awesome_outlined,
                    color:
                        _isAiFocusEnabled
                            ? Colors
                                .greenAccent
                            : Colors
                                .white70,
                    size: 22,
                  ),
                  onPressed:
                      () {
                    setState(() {
                      _isAiFocusEnabled =
                          !_isAiFocusEnabled;
                    });
                  },
                ),

                IconButton(
                  icon:
                      Text(
                    _selectedAspectRatio,
                    style:
                        const TextStyle(
                      color:
                          Colors.white,
                      fontWeight:
                          FontWeight.bold,
                      fontSize:
                          12,
                    ),
                  ),
                  onPressed:
                      _cycleAspectRatio,
                ),
              ],
            ),
          ),

          if (_showExpandedPanel)
            Positioned(
              top: 100,
              left: 18,
              right: 18,
              child:
                  Container(
                padding:
                    const EdgeInsets
                        .all(
                  16,
                ),
                decoration:
                    BoxDecoration(
                  color:
                      const Color(
                    0xFF1E1E1E,
                  ).withOpacity(
                    0.96,
                  ),
                  borderRadius:
                      BorderRadius
                          .circular(
                    16,
                  ),
                  border:
                      Border.all(
                    color:
                        Colors.white24,
                    width:
                        1,
                  ),
                ),
                child:
                    GridView.count(
                  crossAxisCount:
                      4,
                  shrinkWrap:
                      true,
                  physics:
                      const NeverScrollableScrollPhysics(),
                  mainAxisSpacing:
                      12,
                  crossAxisSpacing:
                      12,
                  children: [
                    _buildMenuOption(
                      icon:
                          Icons.hdr_on,
                      label:
                          'HDR',
                      isActive:
                          _isHdrActive,
                      onTap:
                          () {
                        setState(() {
                          _isHdrActive =
                              !_isHdrActive;
                        });
                      },
                    ),

                    _buildMenuOption(
                      icon:
                          Icons.timer_outlined,
                      label:
                          'المؤقت',
                      isActive:
                          _isTimerActive,
                      onTap:
                          _showTimerDialog,
                    ),

                    _buildMenuOption(
                      icon:
                          Icons.branding_watermark_outlined,
                      label:
                          'علامة مائية',
                      isActive:
                          _isWatermarkActive,
                      onTap:
                          _showWatermarkDialog,
                    ),

                    _buildMenuOption(
                      icon:
                          Icons.grid_on,
                      label:
                          'الشبكة',
                      isActive:
                          _isGridActive,
                      onTap:
                          () {
                        setState(() {
                          _isGridActive =
                              !_isGridActive;
                        });
                      },
                    ),

                    _buildMenuOption(
                      icon:
                          Icons.center_focus_strong,
                      label:
                          'تركيز AI',
                      isActive:
                          _isAiFocusEnabled,
                      onTap:
                          () {
                        setState(() {
                          _isAiFocusEnabled =
                              !_isAiFocusEnabled;
                        });
                      },
                    ),

                    _buildMenuOption(
                      icon:
                          Icons.location_on,
                      label:
                          'الموقع',
                      isActive:
                          _isLocationActive,
                      onTap:
                          () {
                        setState(() {
                          _isLocationActive =
                              !_isLocationActive;
                        });
                      },
                    ),

                    _buildMenuOption(
                      icon:
                          Icons.settings_outlined,
                      label:
                          'الإعدادات',
                      isActive:
                          false,
                      onTap:
                          () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder:
                                (context) =>
                                    SettingsScreen(
                              shutterSound:
                                  _shutterSound,
                              cloneShutterButton:
                                  _cloneShutterButton,
                              horizonLevel:
                                  _horizonLevel,
                              dirtyLensNotice:
                                  _dirtyLensNotice,
                              portraitFps:
                                  _portraitFps,
                              qrScannerActive:
                                  _qrScannerActive,
                              onUpdate:
                                  (
                                sound,
                                clone,
                                horizon,
                                lens,
                                fps,
                                qr,
                              ) {
                                setState(() {
                                  _shutterSound =
                                      sound;
                                  _cloneShutterButton =
                                      clone;
                                  _horizonLevel =
                                      horizon;
                                  _dirtyLensNotice =
                                      lens;
                                  _portraitFps =
                                      fps;
                                  _qrScannerActive =
                                      qr;
                                });
                              },
                              onReset:
                                  () {
                                setState(() {
                                  _isHdrActive =
                                      true;
                                  _isTimerActive =
                                      false;
                                  _isWatermarkActive =
                                      false;
                                  _isGridActive =
                                      false;
                                  _isAiFocusEnabled =
                                      true;
                                  _isLocationActive =
                                      false;
                                  _shutterSound =
                                      true;
                                  _cloneShutterButton =
                                      false;
                                  _horizonLevel =
                                      false;
                                  _dirtyLensNotice =
                                      true;
                                  _portraitFps =
                                      'تلقائي';
                                  _qrScannerActive =
                                      true;
                                });
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),

          Positioned(
            bottom: 38,
            left: 0,
            right: 0,
            child:
                Column(
              mainAxisSize:
                  MainAxisSize.min,
              children: [
                SizedBox(
                  height: 30,
                  child:
                      Row(
                    mainAxisAlignment:
                        MainAxisAlignment
                            .center,
                    children: [
                      'VIDEO',
                      'PHOTO',
                      'PORTRAIT',
                      'NIGHT',
                    ].map(
                      (
                        mode,
                      ) {
                        final selected =
                            _currentMode ==
                                mode;

                        return Padding(
                          padding:
                              const EdgeInsets
                                  .symmetric(
                            horizontal:
                                11,
                          ),
                          child:
                              GestureDetector(
                            onTap:
                                _isRecording
                                    ? null
                                    : () {
                                        setState(() {
                                          _currentMode =
                                              mode;
                                        });
                                      },
                            child:
                                Text(
                              mode,
                              style:
                                  TextStyle(
                                color:
                                    selected
                                        ? Colors
                                            .greenAccent
                                        : Colors
                                            .white60,
                                fontWeight:
                                    FontWeight
                                        .bold,
                                fontSize:
                                    13,
                              ),
                            ),
                          ),
                        );
                      },
                    ).toList(),
                  ),
                ),

                const SizedBox(
                  height: 15,
                ),

                Row(
                  mainAxisAlignment:
                      MainAxisAlignment
                          .spaceEvenly,
                  children: [
                    GestureDetector(
                      onTap:
                          _openGallery,
                      child:
                          Container(
                        height: 45,
                        width: 45,
                        decoration:
                            BoxDecoration(
                          color:
                              Colors.grey[
                                  900],
                          borderRadius:
                              BorderRadius
                                  .circular(
                            10,
                          ),
                          border:
                              Border.all(
                            color:
                                Colors.white30,
                          ),
                        ),
                        child:
                            const Icon(
                          Icons
                              .photo,
                          color:
                              Colors.white,
                          size:
                              22,
                        ),
                      ),
                    ),

                    GestureDetector(
                      onTap:
                          _isProcessing
                              ? null
                              : _captureAction,
                      child:
                          Container(
                        height: 72,
                        width: 72,
                        decoration:
                            BoxDecoration(
                          shape:
                              BoxShape
                                  .circle,
                          border:
                              Border.all(
                            color:
                                Colors.white,
                            width:
                                3,
                          ),
                        ),
                        child:
                            Center(
                          child:
                              Container(
                            height:
                                60,
                            width:
                                60,
                            decoration:
                                BoxDecoration(
                              shape:
                                  BoxShape
                                      .circle,
                              color:
                                  _currentMode ==
                                              'VIDEO' &&
                                          _isRecording
                                      ? Colors
                                          .red
                                      : Colors
                                          .white,
                            ),
                            child:
                                _isRecording
                                    ? const Icon(
                                        Icons
                                            .stop,
                                        color:
                                            Colors.white,
                                        size:
                                            28,
                                      )
                                    : null,
                          ),
                        ),
                      ),
                    ),

                    IconButton(
                      iconSize:
                          28,
                      icon:
                          const Icon(
                        Icons
                            .cameraswitch_outlined,
                        color:
                            Colors.white,
                      ),
                      onPressed:
                          _isProcessing ||
                                  _isRecording
                              ? null
                              : _switchCamera,
                    ),
                  ],
                ),
              ],
            ),
          ),

          if (_isProcessing)
            Positioned.fill(
              child:
                  Container(
                color:
                    Colors.black
                        .withOpacity(
                  0.28,
                ),
                child:
                    const Center(
                  child:
                      Column(
                    mainAxisSize:
                        MainAxisSize
                            .min,
                    children: [
                      SizedBox(
                        width:
                            34,
                        height:
                            34,
                        child:
                            CircularProgressIndicator(
                          strokeWidth:
                              2.5,
                          color:
                              Colors.greenAccent,
                        ),
                      ),
                      SizedBox(
                        height:
                            12,
                      ),
                      Text(
                        'جاري حفظ ومعالجة الصورة...',
                        style:
                            TextStyle(
                          color:
                              Colors.white,
                          fontSize:
                              12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _videoTimer?.cancel();
    _zoomHideTimer?.cancel();

    WidgetsBinding.instance
        .removeObserver(this);

    _flashAnimController
        .dispose();

    controller?.dispose();

    super.dispose();
  }
}

class GridPainter
    extends CustomPainter {
  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final paint =
        Paint()
          ..color =
              Colors.white24
          ..strokeWidth =
              1.0;

    final thirdW =
        size.width / 3;

    final thirdH =
        size.height / 3;

    canvas.drawLine(
      Offset(
        thirdW,
        0,
      ),
      Offset(
        thirdW,
        size.height,
      ),
      paint,
    );

    canvas.drawLine(
      Offset(
        thirdW * 2,
        0,
      ),
      Offset(
        thirdW * 2,
        size.height,
      ),
      paint,
    );

    canvas.drawLine(
      Offset(
        0,
        thirdH,
      ),
      Offset(
        size.width,
        thirdH,
      ),
      paint,
    );

    canvas.drawLine(
      Offset(
        0,
        thirdH * 2,
      ),
      Offset(
        size.width,
        thirdH * 2,
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

class SettingsScreen
    extends StatefulWidget {
  final bool shutterSound;
  final bool cloneShutterButton;
  final bool horizonLevel;
  final bool dirtyLensNotice;
  final String portraitFps;
  final bool qrScannerActive;

  final Function(
    bool,
    bool,
    bool,
    bool,
    String,
    bool,
  ) onUpdate;

  final VoidCallback onReset;

  const SettingsScreen({
    super.key,
    required this.shutterSound,
    required this.cloneShutterButton,
    required this.horizonLevel,
    required this.dirtyLensNotice,
    required this.portraitFps,
    required this.qrScannerActive,
    required this.onUpdate,
    required this.onReset,
  });

  @override
  State<SettingsScreen>
      createState() =>
          _SettingsScreenState();
}

class _SettingsScreenState
    extends State<SettingsScreen> {
  late bool _sound;
  late bool _clone;
  late bool _horizon;
  late bool _lens;
  late String _fps;
  late bool _qr;

  @override
  void initState() {
    super.initState();

    _sound =
        widget.shutterSound;

    _clone =
        widget.cloneShutterButton;

    _horizon =
        widget.horizonLevel;

    _lens =
        widget.dirtyLensNotice;

    _fps =
        widget.portraitFps;

    _qr =
        widget.qrScannerActive;
  }

  void _updateParent() {
    widget.onUpdate(
      _sound,
      _clone,
      _horizon,
      _lens,
      _fps,
      _qr,
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    return Scaffold(
      backgroundColor:
          Colors.black,
      appBar:
          AppBar(
        backgroundColor:
            Colors.black,
        title:
            const Text(
          'الإعدادات',
          style:
              TextStyle(
            color:
                Colors.white,
          ),
        ),
        leading:
            IconButton(
          icon:
              const Icon(
            Icons.arrow_forward,
            color:
                Colors.greenAccent,
          ),
          onPressed:
              () =>
                  Navigator.pop(
            context,
          ),
        ),
      ),
      body:
          ListView(
        padding:
            const EdgeInsets.all(
          16,
        ),
        children: [
          SwitchListTile(
            title:
                const Text(
              'صوت الالتقاط',
            ),
            value:
                _sound,
            activeColor:
                Colors.greenAccent,
            onChanged:
                (value) {
              setState(() {
                _sound =
                    value;
              });

              _updateParent();
            },
          ),

          SwitchListTile(
            title:
                const Text(
              'استنساخ زر الالتقاط',
            ),
            value:
                _clone,
            activeColor:
                Colors.greenAccent,
            onChanged:
                (value) {
              setState(() {
                _clone =
                    value;
              });

              _updateParent();
            },
          ),

          SwitchListTile(
            title:
                const Text(
              'الموقع',
            ),
            value:
                true,
            activeColor:
                Colors.greenAccent,
            onChanged:
                (_) {},
          ),

          SwitchListTile(
            title:
                const Text(
              'المستوى الأفقي',
            ),
            value:
                _horizon,
            activeColor:
                Colors.greenAccent,
            onChanged:
                (value) {
              setState(() {
                _horizon =
                    value;
              });

              _updateParent();
            },
          ),

          ListTile(
            title:
                const Text(
              'طرق التصوير والإعدادات الإضافية',
            ),
            trailing:
                const Icon(
              Icons.arrow_back_ios,
              size: 14,
              color:
                  Colors.white54,
            ),
          ),

          ListTile(
            title:
                const Text(
              'محسن بورتريه AI',
            ),
            subtitle:
                Text(
              _fps,
              style:
                  const TextStyle(
                color:
                    Colors.greenAccent,
                fontSize:
                    12,
              ),
            ),
            trailing:
                const Icon(
              Icons.arrow_back_ios,
              size: 14,
              color:
                  Colors.white54,
            ),
            onTap:
                () {
              showDialog(
                context:
                    context,
                builder:
                    (context) =>
                        AlertDialog(
                  backgroundColor:
                      Colors.grey[
                          900],
                  title:
                      const Text(
                    'اختر جودة البورتريه',
                    style:
                        TextStyle(
                      color:
                          Colors.white,
                    ),
                  ),
                  content:
                      Column(
                    mainAxisSize:
                        MainAxisSize
                            .min,
                    children: [
                      ListTile(
                        title:
                            const Text(
                          'تلقائي',
                          style:
                              TextStyle(
                            color:
                                Colors.white,
                          ),
                        ),
                        onTap:
                            () {
                          setState(() {
                            _fps =
                                'تلقائي';
                          });

                          _updateParent();

                          Navigator.pop(
                            context,
                          );
                        },
                      ),
                      ListTile(
                        title:
                            const Text(
                          '50 فريم',
                          style:
                              TextStyle(
                            color:
                                Colors.white,
                          ),
                        ),
                        onTap:
                            () {
                          setState(() {
                            _fps =
                                '50 فريم';
                          });

                          _updateParent();

                          Navigator.pop(
                            context,
                          );
                        },
                      ),
                      ListTile(
                        title:
                            const Text(
                          '60 فريم',
                          style:
                              TextStyle(
                            color:
                                Colors.white,
                          ),
                        ),
                        onTap:
                            () {
                          setState(() {
                            _fps =
                                '60 فريم';
                          });

                          _updateParent();

                          Navigator.pop(
                            context,
                          );
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          ),

          SwitchListTile(
            title:
                const Text(
              'مسح رموز QR',
            ),
            value:
                _qr,
            activeColor:
                Colors.greenAccent,
            onChanged:
                (value) {
              setState(() {
                _qr =
                    value;
              });

              _updateParent();
            },
          ),

          SwitchListTile(
            title:
                const Text(
              'الإشعار بالعدسات المتسخة',
            ),
            value:
                _lens,
            activeColor:
                Colors.greenAccent,
            onChanged:
                (value) {
              setState(() {
                _lens =
                    value;
              });

              _updateParent();
            },
          ),

          const Divider(
            color:
                Colors.white24,
          ),

          ListTile(
            leading:
                const Icon(
              Icons.refresh,
              color:
                  Colors.redAccent,
            ),
            title:
                const Text(
              'استعادة الإعدادات الافتراضية',
              style:
                  TextStyle(
                color:
                    Colors.redAccent,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
            onTap:
                () {
              widget.onReset();

              setState(() {
                _sound = true;
                _clone = false;
                _horizon = false;
                _lens = true;
                _fps = 'تلقائي';
                _qr = true;
              });

              ScaffoldMessenger.of(
                context,
              ).showSnackBar(
                const SnackBar(
                  content:
                      Text(
                    'تمت استعادة الإعدادات الافتراضية بنجاح',
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}