import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  List<CameraDescription> cameras = [];

  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera discovery error: $e');
  }

  runApp(
    AICameraApp(cameras: cameras),
  );
}

class AICameraApp extends StatelessWidget {
  final List<CameraDescription> cameras;

  const AICameraApp({
    super.key,
    required this.cameras,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AI Camera Pro',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        useMaterial3: true,
      ),
      home: CameraPage(cameras: cameras),
    );
  }
}

enum CameraMode {
  photo,
  video,
  portrait,
}

class CameraPage extends StatefulWidget {
  final List<CameraDescription> cameras;

  const CameraPage({
    super.key,
    required this.cameras,
  });

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  CameraController? _controller;

  int _cameraIndex = 0;

  CameraMode _mode = CameraMode.photo;

  bool _initializing = true;
  bool _busy = false;
  bool _recording = false;
  bool _grid = false;

  FlashMode _flashMode = FlashMode.off;

  double _zoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;

  double _exposure = 0.0;

  Timer? _recordTimer;
  int _recordSeconds = 0;

  double _zoomStart = 1.0;

  late final AnimationController _captureAnimation;

  CameraController? get camera => _controller;

  bool get isReady =>
      camera != null &&
      camera!.value.isInitialized;

  bool get isFrontCamera {
    if (widget.cameras.isEmpty) {
      return false;
    }

    return widget
            .cameras[_cameraIndex]
            .lensDirection ==
        CameraLensDirection.front;
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _captureAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      lowerBound: 0,
      upperBound: 1,
    );

    _initialize();
  }

  Future<void> _initialize() async {
    final cameraPermission =
        await Permission.camera.request();

    if (!cameraPermission.isGranted) {
      if (mounted) {
        setState(() {
          _initializing = false;
        });
      }

      _message(
        'يجب السماح للتطبيق باستخدام الكاميرا',
      );

      return;
    }

    await Permission.microphone.request();

    try {
      await Gal.requestAccess();
    } catch (e) {
      debugPrint(
        'Gallery permission error: $e',
      );
    }

    if (widget.cameras.isEmpty) {
      if (mounted) {
        setState(() {
          _initializing = false;
        });
      }

      _message(
        'لم يتم العثور على كاميرا في الجهاز',
      );

      return;
    }

    await _setupCamera(_cameraIndex);
  }

  Future<void> _setupCamera(int index) async {
    if (widget.cameras.isEmpty) {
      return;
    }

    if (index < 0 ||
        index >= widget.cameras.length) {
      index = 0;
    }

    if (mounted) {
      setState(() {
        _initializing = true;
      });
    }

    final oldController = _controller;

    _controller = null;

    if (oldController != null) {
      try {
        await oldController.dispose();
      } catch (_) {}
    }

    final description =
        widget.cameras[index];

    final newController = CameraController(
      description,
      ResolutionPreset.max,
      enableAudio: true,
      imageFormatGroup:
          ImageFormatGroup.jpeg,
    );

    try {
      await newController.initialize();

      try {
        await newController.setFocusMode(
          FocusMode.auto,
        );
      } catch (_) {}

      try {
        await newController.setExposureMode(
          ExposureMode.auto,
        );
      } catch (_) {}

      try {
        await newController.setFlashMode(
          _flashMode,
        );
      } catch (_) {}

      final minZoom =
          await newController.getMinZoomLevel();

      final maxZoom =
          await newController.getMaxZoomLevel();

      _controller = newController;
      _cameraIndex = index;

      _minZoom =
          minZoom.isFinite && minZoom > 0
              ? minZoom
              : 1.0;

      _maxZoom =
          maxZoom.isFinite &&
                  maxZoom >= _minZoom
              ? maxZoom
              : _minZoom;

      _zoom = _minZoom;

      await newController.setZoomLevel(
        _zoom,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _initializing = false;
      });
    } catch (e, stack) {
      debugPrint(
        'Camera setup error: $e',
      );

      debugPrint(
        stack.toString(),
      );

      try {
        await newController.dispose();
      } catch (_) {}

      _controller = null;

      if (mounted) {
        setState(() {
          _initializing = false;
        });
      }

      _message(
        'حدث خطأ أثناء تشغيل الكاميرا',
      );
    }
  }

  @override
  void didChangeAppLifecycleState(
    AppLifecycleState state,
  ) {
    if (state ==
            AppLifecycleState.inactive ||
        state ==
            AppLifecycleState.paused) {
      final oldController = _controller;

      _controller = null;

      oldController?.dispose();
    }

    if (state ==
        AppLifecycleState.resumed) {
      if (widget.cameras.isNotEmpty) {
        _setupCamera(_cameraIndex);
      }
    }
  }

  Future<void> _switchCamera() async {
    if (_busy || _recording) {
      return;
    }

    if (widget.cameras.length < 2) {
      _message(
        'الجهاز لا يحتوي على كاميرا ثانية',
      );

      return;
    }

    final nextIndex =
        (_cameraIndex + 1) %
            widget.cameras.length;

    await _setupCamera(nextIndex);
  }

  Future<void> _changeZoom(
    double value,
  ) async {
    final controller = camera;

    if (controller == null ||
        !controller.value.isInitialized ||
        _recording) {
      return;
    }

    final zoom =
        value.clamp(
      _minZoom,
      _maxZoom,
    );

    try {
      await controller.setZoomLevel(
        zoom,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _zoom = zoom;
      });
    } catch (e) {
      debugPrint(
        'Zoom error: $e',
      );
    }
  }

  Future<void> _changeExposure(
    double value,
  ) async {
    final controller = camera;

    if (controller == null ||
        !controller.value.isInitialized) {
      return;
    }

    try {
      final min =
          await controller
              .getMinExposureOffset();

      final max =
          await controller
              .getMaxExposureOffset();

      final exposure =
          value.clamp(
        min,
        max,
      );

      await controller.setExposureOffset(
        exposure,
      );

      if (mounted) {
        setState(() {
          _exposure = exposure;
        });
      }
    } catch (e) {
      debugPrint(
        'Exposure error: $e',
      );
    }
  }

  Future<void> _toggleFlash() async {
    final controller = camera;

    if (controller == null ||
        !controller.value.isInitialized) {
      return;
    }

    final nextFlash =
        _flashMode == FlashMode.off
            ? FlashMode.torch
            : FlashMode.off;

    try {
      await controller.setFlashMode(
        nextFlash,
      );

      if (mounted) {
        setState(() {
          _flashMode = nextFlash;
        });
      }
    } catch (e) {
      debugPrint(
        'Flash error: $e',
      );
    }
  }

  Future<bool> _requestGalleryAccess() async {
    try {
      return await Gal.requestAccess();
    } catch (e) {
      debugPrint(
        'Gallery access error: $e',
      );

      return false;
    }
  }

  Future<void> _takePhoto() async {
    final controller = camera;

    if (controller == null ||
        !controller.value.isInitialized ||
        _busy ||
        _recording) {
      return;
    }

    setState(() {
      _busy = true;
    });

    try {
      HapticFeedback.mediumImpact();

      await _captureAnimation.forward(
        from: 0,
      );

      await _captureAnimation.reverse();

      final XFile image =
          await controller.takePicture();

      final imageFile =
          File(image.path);

      if (!await imageFile.exists()) {
        throw Exception(
          'ملف الصورة غير موجود',
        );
      }

      final length =
          await imageFile.length();

      if (length <= 0) {
        throw Exception(
          'ملف الصورة فارغ',
        );
      }

      final access =
          await _requestGalleryAccess();

      if (!access) {
        throw Exception(
          'لم يتم السماح بحفظ الصور',
        );
      }

      await Gal.putImage(
        image.path,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _busy = false;
      });

      _message(
        'تم حفظ الصورة في المعرض',
      );
    } catch (e, stack) {
      debugPrint(
        'Take photo error: $e',
      );

      debugPrint(
        stack.toString(),
      );

      if (mounted) {
        setState(() {
          _busy = false;
        });
      }

      _message(
        'فشل التصوير: $e',
      );
    }
  }

  Future<void> _startRecording() async {
    final controller = camera;

    if (controller == null ||
        !controller.value.isInitialized ||
        _busy ||
        _recording) {
      return;
    }

    try {
      await controller.startVideoRecording();

      if (!mounted) {
        return;
      }

      _recordTimer?.cancel();

      setState(() {
        _recording = true;
        _recordSeconds = 0;
      });

      _recordTimer =
          Timer.periodic(
        const Duration(seconds: 1),
        (_) {
          if (!mounted ||
              !_recording) {
            return;
          }

          setState(() {
            _recordSeconds++;
          });
        },
      );
    } catch (e, stack) {
      debugPrint(
        'Start recording error: $e',
      );

      debugPrint(
        stack.toString(),
      );

      _message(
        'فشل بدء تسجيل الفيديو',
      );
    }
  }

  Future<void> _stopRecording() async {
    final controller = camera;

    if (controller == null ||
        !controller.value.isInitialized ||
        !_recording) {
      return;
    }

    try {
      _recordTimer?.cancel();

      final XFile video =
          await controller.stopVideoRecording();

      if (!mounted) {
        return;
      }

      setState(() {
        _recording = false;
        _recordSeconds = 0;
        _busy = true;
      });

      final access =
          await _requestGalleryAccess();

      if (!access) {
        throw Exception(
          'لم يتم السماح بحفظ الفيديو',
        );
      }

      await Gal.putVideo(
        video.path,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _busy = false;
      });

      _message(
        'تم حفظ الفيديو في المعرض',
      );
    } catch (e, stack) {
      debugPrint(
        'Stop recording error: $e',
      );

      debugPrint(
        stack.toString(),
      );

      if (mounted) {
        setState(() {
          _recording = false;
          _recordSeconds = 0;
          _busy = false;
        });
      }

      _message(
        'فشل حفظ الفيديو',
      );
    }
  }

  Future<void> _capture() async {
    if (_mode ==
        CameraMode.video) {
      if (_recording) {
        await _stopRecording();
      } else {
        await _startRecording();
      }

      return;
    }

    await _takePhoto();
  }

  Future<void> _focus(
    Offset position,
    Size size,
  ) async {
    final controller = camera;

    if (controller == null ||
        !controller.value.isInitialized) {
      return;
    }

    final x =
        (position.dx / size.width)
            .clamp(0.0, 1.0);

    final y =
        (position.dy / size.height)
            .clamp(0.0, 1.0);

    try {
      await controller.setFocusPoint(
        Offset(x, y),
      );

      await controller.setExposurePoint(
        Offset(x, y),
      );
    } catch (_) {}
  }

  Future<void> _openGallery() async {
    try {
      await Gal.open();
    } catch (e) {
      _message(
        'تعذر فتح المعرض',
      );
    }
  }

  void _message(String text) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
        .hideCurrentSnackBar();

    ScaffoldMessenger.of(context)
        .showSnackBar(
      SnackBar(
        behavior:
            SnackBarBehavior.floating,
        duration:
            const Duration(seconds: 2),
        content:
            Text(
          text,
          textDirection:
              TextDirection.rtl,
        ),
      ),
    );
  }

  String _modeName() {
    switch (_mode) {
      case CameraMode.photo:
        return 'PHOTO';

      case CameraMode.video:
        return 'VIDEO';

      case CameraMode.portrait:
        return 'PORTRAIT';
    }
  }

  String _recordTime() {
    final minutes =
        _recordSeconds ~/ 60;

    final seconds =
        _recordSeconds % 60;

    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _preview() {
    final controller = camera;

    if (controller == null ||
        !controller.value.isInitialized) {
      return const SizedBox();
    }

    return LayoutBuilder(
      builder: (
        context,
        constraints,
      ) {
        final previewSize =
            controller.value.previewSize;

        if (previewSize == null) {
          return CameraPreview(
            controller,
          );
        }

        final previewWidth =
            previewSize.height;

        final previewHeight =
            previewSize.width;

        final previewRatio =
            previewWidth /
                previewHeight;

        final screenRatio =
            constraints.maxWidth /
                constraints.maxHeight;

        double scale =
            previewRatio /
                screenRatio;

        if (scale < 1) {
          scale = 1 / scale;
        }

        final size =
            Size(
          constraints.maxWidth,
          constraints.maxHeight,
        );

        return GestureDetector(
          behavior:
              HitTestBehavior.opaque,
          onTapDown:
              (details) {
            _focus(
              details.localPosition,
              size,
            );
          },
          onScaleStart:
              (_) {
            _zoomStart = _zoom;
          },
          onScaleUpdate:
              (details) {
            if (details.scale == 1) {
              return;
            }

            _changeZoom(
              _zoomStart *
                  details.scale,
            );
          },
          child:
              ClipRect(
            child:
                Transform.scale(
              scale: scale,
              child:
                  Center(
                child:
                    SizedBox(
                  width:
                      previewWidth,
                  height:
                      previewHeight,
                  child:
                      CameraPreview(
                    controller,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _topBar() {
    return SafeArea(
      bottom: false,
      child:
          Padding(
        padding:
            const EdgeInsets.fromLTRB(
          16,
          10,
          16,
          0,
        ),
        child:
            Row(
          children: [
            _roundButton(
              Icons.flash_off,
              _flashMode !=
                  FlashMode.off,
              _toggleFlash,
            ),
            const Spacer(),
            Column(
              children: [
                const Text(
                  'AI CAMERA',
                  style:
                      TextStyle(
                    color:
                        Colors.white,
                    fontSize:
                        17,
                    fontWeight:
                        FontWeight.w800,
                    letterSpacing:
                        2.2,
                  ),
                ),
                Text(
                  _modeName(),
                  style:
                      const TextStyle(
                    color:
                        Colors.greenAccent,
                    fontSize:
                        9,
                    fontWeight:
                        FontWeight.bold,
                    letterSpacing:
                        2,
                  ),
                ),
              ],
            ),
            const Spacer(),
            _roundButton(
              Icons.grid_3x3,
              _grid,
              () {
                setState(() {
                  _grid = !_grid;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _roundButton(
    IconData icon,
    bool active,
    VoidCallback action,
  ) {
    return Material(
      color:
          Colors.black.withOpacity(
        0.45,
      ),
      shape:
          const CircleBorder(),
      child:
          InkWell(
        customBorder:
            const CircleBorder(),
        onTap:
            action,
        child:
            Padding(
          padding:
              const EdgeInsets.all(
            12,
          ),
          child:
              Icon(
            icon,
            color:
                active
                    ? Colors.greenAccent
                    : Colors.white,
            size:
                21,
          ),
        ),
      ),
    );
  }

  Widget _gridOverlay() {
    if (!_grid) {
      return const SizedBox();
    }

    return IgnorePointer(
      child:
          CustomPaint(
        painter:
            GridPainter(),
        child:
            const SizedBox.expand(),
      ),
    );
  }

  Widget _modeSelector() {
    return Container(
      margin:
          const EdgeInsets.symmetric(
        horizontal: 22,
      ),
      padding:
          const EdgeInsets.all(
        5,
      ),
      decoration:
          BoxDecoration(
        color:
            Colors.black.withOpacity(
          0.75,
        ),
        borderRadius:
            BorderRadius.circular(
          25,
        ),
        border:
            Border.all(
          color:
              Colors.white12,
        ),
      ),
      child:
          Row(
        children: [
          _modeButton(
            CameraMode.video,
            'VIDEO',
          ),
          _modeButton(
            CameraMode.photo,
            'PHOTO',
          ),
          _modeButton(
            CameraMode.portrait,
            'PORTRAIT',
          ),
        ],
      ),
    );
  }

  Widget _modeButton(
    CameraMode mode,
    String title,
  ) {
    final selected =
        _mode == mode;

    return Expanded(
      child:
          GestureDetector(
        onTap:
            _recording || _busy
                ? null
                : () {
                    setState(() {
                      _mode = mode;
                    });
                  },
        child:
            AnimatedContainer(
          duration:
              const Duration(
            milliseconds: 160,
          ),
          padding:
              const EdgeInsets.symmetric(
            vertical: 10,
          ),
          decoration:
              BoxDecoration(
            color:
                selected
                    ? Colors.greenAccent
                        .withOpacity(
                        0.15,
                      )
                    : Colors.transparent,
            borderRadius:
                BorderRadius.circular(
              20,
            ),
          ),
          child:
              Text(
            title,
            textAlign:
                TextAlign.center,
            style:
                TextStyle(
              color:
                  selected
                      ? Colors.greenAccent
                      : Colors.white60,
              fontSize:
                  10,
              fontWeight:
                  FontWeight.w800,
              letterSpacing:
                  1.1,
            ),
          ),
        ),
      ),
    );
  }

  Widget _zoomSlider() {
    if (_maxZoom <= _minZoom) {
      return const SizedBox();
    }

    return Padding(
      padding:
          const EdgeInsets.symmetric(
        horizontal: 38,
      ),
      child:
          Row(
        children: [
          const Icon(
            Icons.zoom_out,
            color:
                Colors.white70,
            size:
                17,
          ),
          Expanded(
            child:
                Slider(
              value:
                  _zoom.clamp(
                _minZoom,
                _maxZoom,
              ),
              min:
                  _minZoom,
              max:
                  _maxZoom,
              activeColor:
                  Colors.greenAccent,
              inactiveColor:
                  Colors.white24,
              onChanged:
                  _changeZoom,
            ),
          ),
          Text(
            '${_zoom.toStringAsFixed(1)}x',
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
        ],
      ),
    );
  }

  Widget _exposureSlider() {
    return Padding(
      padding:
          const EdgeInsets.symmetric(
        horizontal: 65,
      ),
      child:
          Row(
        children: [
          const Icon(
            Icons.exposure,
            color:
                Colors.white60,
            size:
                16,
          ),
          Expanded(
            child:
                Slider(
              value:
                  _exposure.clamp(
                -2.0,
                2.0,
              ),
              min:
                  -2,
              max:
                  2,
              divisions:
                  20,
              activeColor:
                  Colors.white,
              inactiveColor:
                  Colors.white24,
              onChanged:
                  _changeExposure,
            ),
          ),
        ],
      ),
    );
  }

  Widget _captureButton() {
    final isVideo =
        _mode ==
            CameraMode.video;

    return GestureDetector(
      onTap:
          _busy
              ? null
              : _capture,
      child:
          AnimatedBuilder(
        animation:
            _captureAnimation,
        builder:
            (context, child) {
          final scale =
              1 -
                  (_captureAnimation
                          .value *
                      0.08);

          return Transform.scale(
            scale:
                scale,
            child:
                Container(
              width:
                  82,
              height:
                  82,
              padding:
                  const EdgeInsets.all(
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
                  width:
                      3,
                ),
              ),
              child:
                  Container(
                decoration:
                    BoxDecoration(
                  shape:
                      BoxShape.circle,
                  color:
                      isVideo &&
                              _recording
                          ? Colors.red
                          : Colors.white,
                ),
                child:
                    isVideo &&
                            _recording
                        ? const Icon(
                            Icons.stop,
                            color:
                                Colors.white,
                            size:
                                28,
                          )
                        : null,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _bottomBar() {
    return SafeArea(
      top: false,
      child:
          Padding(
        padding:
            const EdgeInsets.fromLTRB(
          18,
          0,
          18,
          15,
        ),
        child:
            Column(
          children: [
            _modeSelector(),

            const SizedBox(
              height:
                  8,
            ),

            _zoomSlider(),

            _exposureSlider(),

            const SizedBox(
              height:
                  5,
            ),

            Row(
              mainAxisAlignment:
                  MainAxisAlignment
                      .spaceBetween,
              crossAxisAlignment:
                  CrossAxisAlignment.center,
              children: [
                _bottomButton(
                  Icons.photo_library_outlined,
                  _busy
                      ? null
                      : _openGallery,
                ),
                _captureButton(),
                _bottomButton(
                  Icons.cameraswitch_rounded,
                  _busy ||
                          _recording
                      ? null
                      : _switchCamera,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomButton(
    IconData icon,
    VoidCallback? action,
  ) {
    return GestureDetector(
      onTap:
          action,
      child:
          Container(
        width:
            52,
        height:
            52,
        decoration:
            BoxDecoration(
          shape:
              BoxShape.circle,
          color:
              Colors.black.withOpacity(
            0.55,
          ),
          border:
              Border.all(
            color:
                Colors.white24,
          ),
        ),
        child:
            Icon(
          icon,
          color:
              action == null
                  ? Colors.white24
                  : Colors.white,
          size:
              23,
        ),
      ),
    );
  }

  Widget _recordingBadge() {
    if (!_recording) {
      return const SizedBox();
    }

    return SafeArea(
      child:
          Align(
        alignment:
            Alignment.topCenter,
        child:
            Container(
          margin:
              const EdgeInsets.only(
            top: 65,
          ),
          padding:
              const EdgeInsets.symmetric(
            horizontal: 13,
            vertical: 7,
          ),
          decoration:
              BoxDecoration(
            color:
                Colors.red.withOpacity(
              0.9,
            ),
            borderRadius:
                BorderRadius.circular(
              18,
            ),
          ),
          child:
              Text(
            '● ${_recordTime()}',
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
    );
  }

  Widget _busyOverlay() {
    if (!_busy) {
      return const SizedBox();
    }

    return Container(
      color:
          Colors.black.withOpacity(
        0.18,
      ),
      child:
          const Center(
        child:
            SizedBox(
          width:
              36,
          height:
              36,
          child:
              CircularProgressIndicator(
            strokeWidth:
                2.5,
            color:
                Colors.greenAccent,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    if (_initializing ||
        !isReady) {
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

    return Scaffold(
      backgroundColor:
          Colors.black,
      body:
          Stack(
        fit:
            StackFit.expand,
        children: [
          _preview(),

          _gridOverlay(),

          _topBar(),

          _recordingBadge(),

          if (_mode ==
              CameraMode.portrait)
            const Positioned(
              top: 108,
              left: 0,
              right: 0,
              child:
                  Center(
                child:
                    Text(
                  'PORTRAIT',
                  style:
                      TextStyle(
                    color:
                        Colors.greenAccent,
                    fontSize:
                        10,
                    fontWeight:
                        FontWeight.bold,
                    letterSpacing:
                        2,
                  ),
                ),
              ),
            ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child:
                Container(
              height:
                  285,
              decoration:
                  const BoxDecoration(
                gradient:
                    LinearGradient(
                  begin:
                      Alignment.topCenter,
                  end:
                      Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Color(
                      0xE6000000,
                    ),
                  ],
                ),
              ),
            ),
          ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child:
                _bottomBar(),
          ),

          _busyOverlay(),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _recordTimer?.cancel();

    WidgetsBinding.instance
        .removeObserver(this);

    _captureAnimation.dispose();

    final oldController =
        _controller;

    _controller = null;

    oldController?.dispose();

    super.dispose();
  }
}

class GridPainter extends CustomPainter {
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
              0.8;

    final thirdWidth =
        size.width / 3;

    final thirdHeight =
        size.height / 3;

    canvas.drawLine(
      Offset(
        thirdWidth,
        0,
      ),
      Offset(
        thirdWidth,
        size.height,
      ),
      paint,
    );

    canvas.drawLine(
      Offset(
        thirdWidth * 2,
        0,
      ),
      Offset(
        thirdWidth * 2,
        size.height,
      ),
      paint,
    );

    canvas.drawLine(
      Offset(
        0,
        thirdHeight,
      ),
      Offset(
        size.width,
        thirdHeight,
      ),
      paint,
    );

    canvas.drawLine(
      Offset(
        0,
        thirdHeight * 2,
      ),
      Offset(
        size.width,
        thirdHeight * 2,
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