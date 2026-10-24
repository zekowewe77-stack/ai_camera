import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

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
  CameraController? controller;

  int selectedCameraIndex = 0;

  bool isCameraReady = false;
  bool isProcessing = false;
  bool isRecording = false;

  FlashMode flashMode = FlashMode.off;

  double currentZoom = 1.0;
  double minZoom = 1.0;
  double maxZoom = 1.0;

  double startZoom = 1.0;

  String currentMode = 'PHOTO';

  bool showExpandedPanel = false;
  bool showZoomPanel = false;

  bool hdrActive = true;
  bool timerActive = false;
  int timerSeconds = 3;

  bool watermarkActive = false;
  String watermarkText = 'AI Camera Pro 2027';

  bool gridActive = false;
  bool aiFocusEnabled = true;
  bool locationActive = false;

  bool shutterSound = true;
  bool cloneShutterButton = false;
  bool horizonLevel = false;
  bool dirtyLensNotice = true;
  bool qrScannerActive = true;

  String portraitFps = 'تلقائي';

  String selectedAspectRatio = '4:3';

  int countdownSeconds = 0;

  Timer? videoTimer;
  int videoSeconds = 0;

  DateTime lastZoomInteraction = DateTime.now();

  String lastResolution = '';
  double lastMegapixels = 0;

  late AnimationController flashAnimation;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    flashAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 130),
    );

    initializeCamera();
  }

  bool get isFrontCamera {
    if (cameras.isEmpty) {
      return false;
    }

    return cameras[selectedCameraIndex].lensDirection ==
        CameraLensDirection.front;
  }

  @override
  void didChangeAppLifecycleState(
    AppLifecycleState state,
  ) {
    if (state == AppLifecycleState.resumed) {
      initializeCamera();
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      final oldController = controller;

      controller = null;

      if (oldController != null) {
        oldController.dispose();
      }

      if (mounted) {
        setState(() {
          isCameraReady = false;
        });
      }
    }
  }

  Future<void> initializeCamera() async {
    if (cameras.isEmpty) {
      return;
    }

    if (selectedCameraIndex >= cameras.length) {
      selectedCameraIndex = 0;
    }

    if (mounted) {
      setState(() {
        isCameraReady = false;
      });
    }

    final oldController = controller;
    controller = null;

    if (oldController != null) {
      try {
        await oldController.dispose();
      } catch (_) {}
    }

    final newController = CameraController(
      cameras[selectedCameraIndex],
      ResolutionPreset.max,
      enableAudio: true,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await newController.initialize();

      minZoom =
          await newController.getMinZoomLevel();

      maxZoom =
          await newController.getMaxZoomLevel();

      if (maxZoom < minZoom) {
        maxZoom = minZoom;
      }

      currentZoom =
          minZoom.clamp(minZoom, maxZoom);

      await newController.setZoomLevel(
        currentZoom,
      );

      try {
        await newController.setFlashMode(
          flashMode,
        );
      } catch (_) {}

      controller = newController;

      if (mounted) {
        setState(() {
          isCameraReady = true;
        });
      }
    } catch (e) {
      debugPrint(
        'Camera initialization error: $e',
      );

      try {
        await newController.dispose();
      } catch (_) {}

      if (mounted) {
        setState(() {
          isCameraReady = false;
        });
      }
    }
  }

  Future<void> switchCamera() async {
    if (cameras.length < 2 ||
        isProcessing ||
        isRecording) {
      return;
    }

    selectedCameraIndex =
        (selectedCameraIndex + 1) % cameras.length;

    await initializeCamera();
  }

  Future<void> setZoom(
    double value,
  ) async {
    final c = controller;

    if (c == null ||
        !c.value.isInitialized) {
      return;
    }

    final double zoom =
        value.clamp(minZoom, maxZoom);

    try {
      await c.setZoomLevel(zoom);

      if (mounted) {
        setState(() {
          currentZoom = zoom;
          showZoomPanel = true;
          lastZoomInteraction =
              DateTime.now();
        });
      }
    } catch (e) {
      debugPrint(
        'Zoom error: $e',
      );
    }
  }

  Future<void> toggleFlash() async {
    final c = controller;

    if (c == null ||
        !c.value.isInitialized) {
      return;
    }

    final FlashMode next =
        flashMode == FlashMode.torch
            ? FlashMode.off
            : FlashMode.torch;

    try {
      await c.setFlashMode(next);

      if (mounted) {
        setState(() {
          flashMode = next;
        });
      }
    } catch (e) {
      debugPrint(
        'Flash error: $e',
      );
    }
  }

  Future<bool> requestGalleryAccess() async {
    try {
      final bool hasAccess =
          await Gal.hasAccess();

      if (hasAccess) {
        return true;
      }

      return await Gal.requestAccess();
    } catch (e) {
      debugPrint(
        'Gallery permission error: $e',
      );

      return false;
    }
  }

  Future<void> capturePhoto() async {
    final c = controller;

    if (c == null ||
        !c.value.isInitialized ||
        isProcessing ||
        isRecording) {
      return;
    }

    if (currentMode == 'VIDEO') {
      await toggleVideoRecording();
      return;
    }

    if (timerActive) {
      if (mounted) {
        setState(() {
          countdownSeconds = timerSeconds;
        });
      }

      for (
        int i = timerSeconds;
        i > 0;
        i--
      ) {
        await Future.delayed(
          const Duration(seconds: 1),
        );

        if (!mounted) {
          return;
        }

        setState(() {
          countdownSeconds = i - 1;
        });
      }
    }

    try {
      if (mounted) {
        setState(() {
          isProcessing = true;
          showExpandedPanel = false;
          showZoomPanel = false;
        });
      }

      if (shutterSound) {
        try {
          SystemSound.play(
            SystemSoundType.click,
          );
        } catch (_) {}

        HapticFeedback.mediumImpact();
      }

      flashAnimation.forward(
        from: 0,
      );

      Future.delayed(
        const Duration(
          milliseconds: 100,
        ),
        () {
          if (mounted) {
            flashAnimation.reverse();
          }
        },
      );

      final XFile photo =
          await c.takePicture();

      final bool front =
          isFrontCamera;

      final String outputPath = p.join(
        File(photo.path).parent.path,
        'AI_CAMERA_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );

      final Uint8List inputBytes =
          await File(photo.path).readAsBytes();

      final ImageProcessRequest request =
          ImageProcessRequest(
        inputBytes: inputBytes,
        outputPath: outputPath,
        mirrorFront: false,
        enhance: hdrActive,
        zoom: currentZoom,
        addWatermark: watermarkActive,
        watermarkText: watermarkText,
      );

      final ImageProcessResult? result =
          await Isolate.run(
        () => processImageInBackground(
          request,
        ),
      );

      if (result == null) {
        throw Exception(
          'تعذر تجهيز الصورة',
        );
      }

      final bool galleryAccess =
          await requestGalleryAccess();

      if (!galleryAccess) {
        throw Exception(
          'لم يتم السماح للتطبيق بحفظ الصور في المعرض',
        );
      }

      await Gal.putImage(
        result.path,
      );

      if (mounted) {
        setState(() {
          lastResolution =
              '${result.width} × ${result.height}';

          lastMegapixels =
              result.megapixels;
        });

        ScaffoldMessenger.of(context)
            .showSnackBar(
          SnackBar(
            duration:
                const Duration(seconds: 2),
            content: Text(
              'تم حفظ الصورة • '
              '${result.width}×${result.height} • '
              '${result.megapixels.toStringAsFixed(1)} MP',
            ),
          ),
        );
      }

      try {
        await File(photo.path).delete();
      } catch (_) {}

      try {
        await File(result.path).delete();
      } catch (_) {}
    } catch (e, stackTrace) {
      debugPrint(
        'Capture error: $e',
      );

      debugPrint(
        stackTrace.toString(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          SnackBar(
            duration:
                const Duration(seconds: 3),
            content: Text(
              'خطأ في التصوير: $e',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          isProcessing = false;
          countdownSeconds = 0;
        });
      }
    }
  }

  Future<void> toggleVideoRecording() async {
    final c = controller;

    if (c == null ||
        !c.value.isInitialized) {
      return;
    }

    if (isProcessing) {
      return;
    }

    try {
      if (isRecording) {
        videoTimer?.cancel();

        final XFile video =
            await c.stopVideoRecording();

        if (mounted) {
          setState(() {
            isRecording = false;
            videoSeconds = 0;
          });
        }

        final bool access =
            await requestGalleryAccess();

        if (!access) {
          throw Exception(
            'لم يتم السماح بحفظ الفيديو',
          );
        }

        await Gal.putVideo(
          video.path,
        );

        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(
            const SnackBar(
              content:
                  Text('تم حفظ الفيديو في المعرض'),
            ),
          );
        }
      } else {
        await c.startVideoRecording();

        if (mounted) {
          setState(() {
            isRecording = true;
            videoSeconds = 0;
          });
        }

        videoTimer = Timer.periodic(
          const Duration(seconds: 1),
          (_) {
            if (mounted &&
                isRecording) {
              setState(() {
                videoSeconds++;
              });
            }
          },
        );
      }
    } catch (e) {
      debugPrint(
        'Video error: $e',
      );

      videoTimer?.cancel();

      if (mounted) {
        setState(() {
          isRecording = false;
          videoSeconds = 0;
        });

        ScaffoldMessenger.of(context)
            .showSnackBar(
          SnackBar(
            content: Text(
              'خطأ في الفيديو: $e',
            ),
          ),
        );
      }
    }
  }

  Future<void> openGallery() async {
    try {
      await Gal.open();
    } catch (e) {
      debugPrint(
        'Gallery open error: $e',
      );

      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(
          SnackBar(
            content: Text(
              'تعذر فتح المعرض: $e',
            ),
          ),
        );
      }
    }
  }

  void changeMode(
    String mode,
  ) {
    if (isRecording ||
        isProcessing) {
      return;
    }

    setState(() {
      currentMode = mode;
    });
  }

  void showWatermarkDialog() {
    final TextEditingController textController =
        TextEditingController(
      text: watermarkText,
    );

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor:
              const Color(0xFF202020),
          title: const Text(
            'العلامة المائية',
            style: TextStyle(
              color: Colors.white,
            ),
          ),
          content: TextField(
            controller: textController,
            style: const TextStyle(
              color: Colors.white,
            ),
            decoration:
                const InputDecoration(
              hintText:
                  'اكتب النص هنا...',
              hintStyle:
                  TextStyle(
                color: Colors.white54,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(
                  dialogContext,
                );
              },
              child: const Text(
                'إلغاء',
                style: TextStyle(
                  color: Colors.redAccent,
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                final String text =
                    textController.text
                        .trim();

                setState(() {
                  watermarkText =
                      text.isEmpty
                          ? 'AI Camera Pro 2027'
                          : text;

                  watermarkActive =
                      true;
                });

                Navigator.pop(
                  dialogContext,
                );
              },
              child: const Text(
                'حفظ',
                style: TextStyle(
                  color:
                      Colors.greenAccent,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void showTimerDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor:
              const Color(0xFF202020),
          title: const Text(
            'المؤقت',
            style: TextStyle(
              color: Colors.white,
            ),
          ),
          content: Column(
            mainAxisSize:
                MainAxisSize.min,
            children: [
              timerOption(
                dialogContext,
                3,
              ),
              timerOption(
                dialogContext,
                5,
              ),
              timerOption(
                dialogContext,
                10,
              ),
              ListTile(
                title: const Text(
                  'إيقاف المؤقت',
                  style: TextStyle(
                    color: Colors.white,
                  ),
                ),
                onTap: () {
                  setState(() {
                    timerActive =
                        false;
                  });

                  Navigator.pop(
                    dialogContext,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget timerOption(
    BuildContext dialogContext,
    int seconds,
  ) {
    return ListTile(
      title: Text(
        '$seconds ثواني',
        style:
            const TextStyle(
          color: Colors.white,
        ),
      ),
      trailing:
          timerActive &&
                  timerSeconds ==
                      seconds
              ? const Icon(
                  Icons.check,
                  color:
                      Colors.greenAccent,
                )
              : null,
      onTap: () {
        setState(() {
          timerSeconds =
              seconds;
          timerActive = true;
        });

        Navigator.pop(
          dialogContext,
        );
      },
    );
  }

  double get selectedAspectRatio {
    switch (selectedAspectRatioName) {
      case '16:9':
        return 16 / 9;

      case '1:1':
        return 1;

      case 'Full':
        return MediaQuery.of(context)
                .size
                .width /
            MediaQuery.of(context)
                .size
                .height;

      case '4:3':
      default:
        return 4 / 3;
    }
  }

  String get selectedAspectRatioName =>
      selectedAspectRatio;

  void cycleAspectRatio() {
    setState(() {
      if (selectedAspectRatio ==
          '4:3') {
        selectedAspectRatio =
            '16:9';
      } else if (selectedAspectRatio ==
          '16:9') {
        selectedAspectRatio =
            '1:1';
      } else {
        selectedAspectRatio =
            '4:3';
      }
    });
  }

  Widget buildCameraPreview() {
    final c = controller;

    if (c == null ||
        !c.value.isInitialized) {
      return const SizedBox();
    }

    final Size screen =
        MediaQuery.of(context)
            .size;

    final double screenRatio =
        screen.width /
            screen.height;

    final double cameraRatio =
        c.value.aspectRatio;

    double scale =
        cameraRatio /
            screenRatio;

    if (scale < 1) {
      scale = 1 / scale;
    }

    Widget preview =
        CameraPreview(c);

    // لا نعكس الكاميرا الأمامية.
    // هذا يمنع مشكلة أن حركة الرأس يمين
    // تظهر في الصورة كأنها شمال.
    preview = Center(
      child: Transform.scale(
        scale: scale,
        child: preview,
      ),
    );

    if (selectedAspectRatio ==
        '1:1') {
      preview = Center(
        child: AspectRatio(
          aspectRatio: 1,
          child:
              ClipRect(
            child: preview,
          ),
        ),
      );
    }

    return ClipRect(
      child: SizedBox.expand(
        child: preview,
      ),
    );
  }

  Widget buildTopBar() {
    return Positioned(
      top: 38,
      left: 12,
      right: 12,
      child: SafeArea(
        bottom: false,
        child: Row(
          mainAxisAlignment:
              MainAxisAlignment
                  .spaceBetween,
          children: [
            IconButton(
              icon: Icon(
                flashMode ==
                        FlashMode.torch
                    ? Icons.flash_on
                    : Icons.flash_off,
                color:
                    Colors.white,
              ),
              onPressed:
                  toggleFlash,
            ),

            GestureDetector(
              onTap: () {
                setState(() {
                  showExpandedPanel =
                      !showExpandedPanel;
                });
              },
              child:
                  Container(
                padding:
                    const EdgeInsets
                        .all(7),
                decoration:
                    BoxDecoration(
                  color: Colors
                      .black
                      .withOpacity(
                    0.50,
                  ),
                  shape:
                      BoxShape.circle,
                ),
                child:
                    Icon(
                  showExpandedPanel
                      ? Icons
                          .expand_less
                      : Icons
                          .expand_more,
                  color:
                      Colors
                          .greenAccent,
                  size: 23,
                ),
              ),
            ),

            GestureDetector(
              onTap: () {
                setState(() {
                  aiFocusEnabled =
                      !aiFocusEnabled;
                });
              },
              child:
                  Icon(
                aiFocusEnabled
                    ? Icons
                        .auto_awesome
                    : Icons
                        .auto_awesome_outlined,
                color:
                    aiFocusEnabled
                        ? Colors
                            .greenAccent
                        : Colors.white,
                size: 24,
              ),
            ),

            GestureDetector(
              onTap:
                  cycleAspectRatio,
              child:
                  Container(
                padding:
                    const EdgeInsets
                        .symmetric(
                  horizontal: 7,
                  vertical: 4,
                ),
                decoration:
                    BoxDecoration(
                  color: Colors
                      .black
                      .withOpacity(
                    0.45,
                  ),
                  borderRadius:
                      BorderRadius
                          .circular(
                    6,
                  ),
                ),
                child:
                    Text(
                  selectedAspectRatio,
                  style:
                      const TextStyle(
                    color:
                        Colors.white,
                    fontWeight:
                        FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildExpandedPanel() {
    if (!showExpandedPanel) {
      return const SizedBox();
    }

    return Positioned(
      top: 95,
      left: 16,
      right: 16,
      child: Container(
        padding:
            const EdgeInsets.all(14),
        decoration:
            BoxDecoration(
          color:
              const Color(0xFF171717)
                  .withOpacity(
            0.96,
          ),
          borderRadius:
              BorderRadius.circular(
            18,
          ),
          border:
              Border.all(
            color:
                Colors.white24,
          ),
          boxShadow: const [
            BoxShadow(
              color:
                  Colors.black54,
              blurRadius:
                  20,
            ),
          ],
        ),
        child:
            GridView.count(
          crossAxisCount: 4,
          shrinkWrap: true,
          physics:
              const NeverScrollableScrollPhysics(),
          mainAxisSpacing:
              14,
          crossAxisSpacing:
              10,
          children: [
            buildMenuOption(
              Icons.hdr_on,
              'HDR',
              hdrActive,
              () {
                setState(() {
                  hdrActive =
                      !hdrActive;
                });
              },
            ),

            buildMenuOption(
              Icons.timer_outlined,
              'المؤقت',
              timerActive,
              showTimerDialog,
            ),

            buildMenuOption(
              Icons
                  .branding_watermark_outlined,
              'علامة مائية',
              watermarkActive,
              showWatermarkDialog,
            ),

            buildMenuOption(
              Icons.grid_on,
              'الشبكة',
              gridActive,
              () {
                setState(() {
                  gridActive =
                      !gridActive;
                });
              },
            ),

            buildMenuOption(
              Icons
                  .center_focus_strong,
              'تركيز AI',
              aiFocusEnabled,
              () {
                setState(() {
                  aiFocusEnabled =
                      !aiFocusEnabled;
                });
              },
            ),

            buildMenuOption(
              Icons.location_on,
              'الموقع',
              locationActive,
              () {
                setState(() {
                  locationActive =
                      !locationActive;
                });
              },
            ),

            buildMenuOption(
              Icons.settings_outlined,
              'الإعدادات',
              false,
              openSettings,
            ),

            buildMenuOption(
              Icons.tune,
              'تحسين الصورة',
              hdrActive,
              () {
                setState(() {
                  hdrActive =
                      !hdrActive;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget buildMenuOption(
    IconData icon,
    String label,
    bool active,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child:
          Container(
        decoration:
            BoxDecoration(
          color:
              Colors.white
                  .withOpacity(
            0.035,
          ),
          borderRadius:
              BorderRadius.circular(
            12,
          ),
        ),
        child:
            Column(
          mainAxisAlignment:
              MainAxisAlignment
                  .center,
          children: [
            Icon(
              icon,
              color:
                  active
                      ? Colors
                          .greenAccent
                      : Colors
                          .white70,
              size: 23,
            ),
            const SizedBox(
              height: 5,
            ),
            Text(
              label,
              textAlign:
                  TextAlign.center,
              style:
                  TextStyle(
                color:
                    active
                        ? Colors
                            .greenAccent
                        : Colors
                            .white70,
                fontSize: 9,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildZoomPanel() {
    if (!showZoomPanel) {
      return const SizedBox();
    }

    return Positioned(
      left: 25,
      right: 25,
      bottom: 205,
      child:
          Container(
        padding:
            const EdgeInsets
                .symmetric(
          horizontal: 15,
          vertical: 7,
        ),
        decoration:
            BoxDecoration(
          color:
              Colors.black
                  .withOpacity(
            0.82,
          ),
          borderRadius:
              BorderRadius.circular(
            22,
          ),
          border:
              Border.all(
            color:
                Colors.greenAccent
                    .withOpacity(
              0.5,
            ),
          ),
        ),
        child:
            Column(
          mainAxisSize:
              MainAxisSize.min,
          children: [
            Text(
              '${currentZoom.toStringAsFixed(1)}×',
              style:
                  const TextStyle(
                color:
                    Colors.greenAccent,
                fontSize: 17,
                fontWeight:
                    FontWeight.bold,
              ),
            ),

            Slider(
              value:
                  currentZoom.clamp(
                minZoom,
                maxZoom,
              ),
              min:
                  minZoom,
              max:
                  maxZoom,
              activeColor:
                  Colors.greenAccent,
              inactiveColor:
                  Colors.white24,
              onChanged:
                  setZoom,
            ),

            Text(
              'Hardware Zoom • '
              '${maxZoom.toStringAsFixed(1)}×',
              style:
                  const TextStyle(
                color:
                    Colors.white54,
                fontSize: 9,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildModeSelector() {
    const modes = [
      'VIDEO',
      'PHOTO',
      'PORTRAIT',
      'NIGHT',
    ];

    return SizedBox(
      height: 32,
      child:
          Row(
        mainAxisAlignment:
            MainAxisAlignment
                .center,
        children:
            modes.map(
          (mode) {
            final bool active =
                currentMode ==
                    mode;

            return GestureDetector(
              onTap: () =>
                  changeMode(
                mode,
              ),
              child:
                  Padding(
                padding:
                    const EdgeInsets
                        .symmetric(
                  horizontal: 11,
                ),
                child:
                    Text(
                  mode,
                  style:
                      TextStyle(
                    color:
                        active
                            ? Colors
                                .greenAccent
                            : Colors
                                .white60,
                    fontWeight:
                        FontWeight
                            .bold,
                    fontSize:
                        12,
                  ),
                ),
              ),
            );
          },
        ).toList(),
      ),
    );
  }

  Widget buildBottomControls() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 20,
      child:
          SafeArea(
        top: false,
        child:
            Column(
          mainAxisSize:
              MainAxisSize.min,
          children: [
            buildModeSelector(),

            const SizedBox(
              height: 12,
            ),

            Row(
              mainAxisAlignment:
                  MainAxisAlignment
                      .spaceEvenly,
              children: [
                GestureDetector(
                  onTap:
                      isProcessing
                          ? null
                          : openGallery,
                  child:
                      Container(
                    width: 47,
                    height: 47,
                    decoration:
                        BoxDecoration(
                      color:
                          Colors
                              .black
                              .withOpacity(
                        0.62,
                      ),
                      borderRadius:
                          BorderRadius
                              .circular(
                        11,
                      ),
                      border:
                          Border.all(
                        color:
                            Colors
                                .white24,
                      ),
                    ),
                    child:
                        const Icon(
                      Icons
                          .photo_library_outlined,
                      color:
                          Colors.white,
                      size: 23,
                    ),
                  ),
                ),

                GestureDetector(
                  onTap:
                      isProcessing
                          ? null
                          : capturePhoto,
                  child:
                      Container(
                    width: 78,
                    height: 78,
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
                        Center(
                      child:
                          Container(
                        width: 64,
                        height: 64,
                        decoration:
                            BoxDecoration(
                          shape:
                              BoxShape.circle,
                          color:
                              currentMode ==
                                          'VIDEO' &&
                                      isRecording
                                  ? Colors
                                      .red
                                  : Colors
                                      .white,
                        ),
                        child:
                            isProcessing
                                ? const Padding(
                                    padding:
                                        EdgeInsets.all(
                                      19,
                                    ),
                                    child:
                                        CircularProgressIndicator(
                                      strokeWidth:
                                          2.5,
                                      color:
                                          Colors.black,
                                    ),
                                  )
                                : isRecording
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

                GestureDetector(
                  onTap:
                      isProcessing
                          ? null
                          : switchCamera,
                  child:
                      Container(
                    width: 47,
                    height: 47,
                    decoration:
                        BoxDecoration(
                      color:
                          Colors
                              .black
                              .withOpacity(
                        0.62,
                      ),
                      shape:
                          BoxShape.circle,
                      border:
                          Border.all(
                        color:
                            Colors
                                .white24,
                      ),
                    ),
                    child:
                        const Icon(
                      Icons
                          .cameraswitch_outlined,
                      color:
                          Colors.white,
                      size: 25,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget buildOverlayInfo() {
    if (lastResolution.isEmpty) {
      return const SizedBox();
    }

    return Positioned(
      top: 92,
      left: 15,
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
              Colors.black
                  .withOpacity(
            0.42,
          ),
          borderRadius:
              BorderRadius.circular(
            8,
          ),
        ),
        child:
            Text(
          '$lastResolution • '
          '${lastMegapixels.toStringAsFixed(1)} MP',
          style:
              const TextStyle(
            color:
                Colors.greenAccent,
            fontSize: 9,
          ),
        ),
      ),
    );
  }

  Widget buildWatermark() {
    if (!watermarkActive &&
        !locationActive) {
      return const SizedBox();
    }

    return Positioned(
      left: 18,
      bottom: 145,
      child:
          Container(
        padding:
            const EdgeInsets
                .symmetric(
          horizontal: 9,
          vertical: 5,
        ),
        decoration:
            BoxDecoration(
          color:
              Colors.black
                  .withOpacity(
            0.45,
          ),
          borderRadius:
              BorderRadius.circular(
            7,
          ),
        ),
        child:
            Column(
          crossAxisAlignment:
              CrossAxisAlignment
                  .start,
          children: [
            if (watermarkActive)
              Text(
                watermarkText,
                style:
                    const TextStyle(
                  color:
                      Colors.white,
                  fontSize: 10,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),

            if (locationActive)
              const Text(
                '📍 مصر',
                style:
                    TextStyle(
                  color:
                      Colors.greenAccent,
                  fontSize: 9,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget buildGrid() {
    if (!gridActive) {
      return const SizedBox();
    }

    return Positioned.fill(
      child:
          IgnorePointer(
        child:
            CustomPaint(
          painter:
              GridPainter(),
        ),
      ),
    );
  }

  Widget buildCountdown() {
    if (countdownSeconds <= 0) {
      return const SizedBox();
    }

    return Positioned.fill(
      child:
          IgnorePointer(
        child:
            Center(
          child:
              Container(
            padding:
                const EdgeInsets
                    .all(
              20,
            ),
            decoration:
                const BoxDecoration(
              color:
                  Colors.black54,
              shape:
                  BoxShape.circle,
            ),
            child:
                Text(
              '$countdownSeconds',
              style:
                  const TextStyle(
                color:
                    Colors.greenAccent,
                fontSize: 72,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget buildRecordingIndicator() {
    if (!isRecording) {
      return const SizedBox();
    }

    final int minutes =
        videoSeconds ~/ 60;

    final int seconds =
        videoSeconds % 60;

    final String time =
        '$minutes:${seconds.toString().padLeft(2, '0')}';

    return Positioned(
      top: 85,
      left: 0,
      right: 0,
      child:
          Center(
        child:
            Container(
          padding:
              const EdgeInsets
                  .symmetric(
            horizontal: 13,
            vertical: 6,
          ),
          decoration:
              BoxDecoration(
            color:
                Colors.red
                    .withOpacity(
              0.85,
            ),
            borderRadius:
                BorderRadius.circular(
              20,
            ),
          ),
          child:
              Row(
            mainAxisSize:
                MainAxisSize.min,
            children: [
              const Icon(
                Icons
                    .fiber_manual_record,
                color:
                    Colors.white,
                size: 10,
              ),
              const SizedBox(
                width: 6,
              ),
              Text(
                time,
                style:
                    const TextStyle(
                  color:
                      Colors.white,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => SettingsScreen(
          shutterSound:
              shutterSound,
          cloneShutterButton:
              cloneShutterButton,
          horizonLevel:
              horizonLevel,
          dirtyLensNotice:
              dirtyLensNotice,
          portraitFps:
              portraitFps,
          qrScannerActive:
              qrScannerActive,
          onUpdate: (
            sound,
            clone,
            horizon,
            lens,
            fps,
            qr,
          ) {
            setState(() {
              shutterSound =
                  sound;
              cloneShutterButton =
                  clone;
              horizonLevel =
                  horizon;
              dirtyLensNotice =
                  lens;
              portraitFps =
                  fps;
              qrScannerActive =
                  qr;
            });
          },
          onReset: resetSettings,
        ),
      ),
    );
  }

  void resetSettings() {
    setState(() {
      hdrActive = true;
      timerActive = false;
      timerSeconds = 3;

      watermarkActive =
          false;

      gridActive = false;

      aiFocusEnabled =
          true;

      locationActive =
          false;

      shutterSound = true;

      cloneShutterButton =
          false;

      horizonLevel = false;

      dirtyLensNotice =
          true;

      portraitFps =
          'تلقائي';

      qrScannerActive =
          true;
    });
  }

  @override
  Widget build(
    BuildContext context,
  ) {
    if (cameras.isEmpty) {
      return const Scaffold(
        backgroundColor:
            Colors.black,
        body: Center(
          child: Text(
            'لم يتم العثور على كاميرا',
            style: TextStyle(
              color: Colors.white,
            ),
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
          if (isCameraReady)
            GestureDetector(
              onScaleStart:
                  (_) {
                startZoom =
                    currentZoom;

                setState(() {
                  showZoomPanel =
                      true;

                  showExpandedPanel =
                      false;
                });
              },
              onScaleUpdate:
                  (details) {
                if (details.scale ==
                    1) {
                  return;
                }

                final double next =
                    startZoom *
                        details.scale;

                setZoom(next);
              },
              child:
                  buildCameraPreview(),
            ),

          if (!isCameraReady)
            const Center(
              child:
                  CircularProgressIndicator(
                color:
                    Colors.greenAccent,
              ),
            ),

          buildGrid(),

          buildCountdown(),

          buildWatermark(),

          buildOverlayInfo(),

          buildRecordingIndicator(),

          buildTopBar(),

          buildExpandedPanel(),

          buildZoomPanel(),

          buildBottomControls(),

          if (isProcessing)
            Positioned(
              left: 0,
              right: 0,
              bottom: 155,
              child:
                  Center(
                child:
                    Container(
                  padding:
                      const EdgeInsets
                          .symmetric(
                    horizontal: 13,
                    vertical: 7,
                  ),
                  decoration:
                      BoxDecoration(
                    color:
                        Colors.black
                            .withOpacity(
                      0.70,
                    ),
                    borderRadius:
                        BorderRadius
                            .circular(
                      20,
                    ),
                  ),
                  child:
                      const Text(
                    'جاري حفظ الصورة...',
                    style:
                        TextStyle(
                      color:
                          Colors.white,
                      fontSize:
                          11,
                    ),
                  ),
                ),
              ),
            ),

          if (lastResolution.isNotEmpty)
            Positioned(
              right: 12,
              top: 92,
              child:
                  GestureDetector(
                onTap: () {
                  setState(() {
                    lastResolution =
                        '';
                    lastMegapixels =
                        0;
                  });
                },
                child:
                    const Icon(
                  Icons
                      .check_circle,
                  color:
                      Colors.greenAccent,
                  size: 17,
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    videoTimer?.cancel();

    WidgetsBinding.instance
        .removeObserver(this);

    flashAnimation.dispose();

    final c = controller;

    controller = null;

    if (c != null) {
      c.dispose();
    }

    super.dispose();
  }
}

class ImageProcessRequest {
  final Uint8List inputBytes;
  final String outputPath;
  final bool mirrorFront;
  final bool enhance;
  final double zoom;
  final bool addWatermark;
  final String watermarkText;

  const ImageProcessRequest({
    required this.inputBytes,
    required this.outputPath,
    required this.mirrorFront,
    required this.enhance,
    required this.zoom,
    required this.addWatermark,
    required this.watermarkText,
  });
}

class ImageProcessResult {
  final String path;
  final int width;
  final int height;

  const ImageProcessResult({
    required this.path,
    required this.width,
    required this.height,
  });

  double get megapixels =>
      (width * height) / 1000000;
}

ImageProcessResult?
    processImageInBackground(
  ImageProcessRequest request,
) {
  try {
    img.Image? image =
        img.decodeJpg(
      request.inputBytes,
    );

    if (image == null) {
      return null;
    }

    // تصحيح اتجاه الصورة من Metadata
    image =
        img.bakeOrientation(
      image,
    );

    // مهم:
    // لا نعكس الصورة الأمامية.
    //
    // الكاميرا في النسخة القديمة كانت
    // تقلب الـPreview ثم تقلب الصورة
    // مرة أخرى، وده سبب مشكلة اتجاه الرأس.
    //
    // الآن الصورة النهائية تظل بنفس
    // اتجاه الحركة الطبيعي.
    if (request.mirrorFront) {
      // متعمد تركها بدون flip.
    }

    if (request.enhance) {
      final double contrast =
          request.zoom >= 2.0
              ? 1.10
              : 1.07;

      final double saturation =
          request.zoom >= 2.0
              ? 1.08
              : 1.05;

      final double brightness =
          1.01;

      image =
          img.adjustColor(
        image,
        brightness:
            brightness,
        contrast:
            contrast,
        saturation:
            saturation,
      );

      // Sharpen محسوب وليس مبالغًا فيه
      final double sharpenAmount =
          request.zoom >= 3.0
              ? 0.35
              : 0.25;

      image =
          img.convolution(
        image,
        filter:
            const [
          0,
          -1,
          0,
          -1,
          5,
          -1,
          0,
          -1,
          0,
        ],
        amount:
            sharpenAmount,
      );
    }

    // العلامة المائية
    if (request.addWatermark &&
        request.watermarkText
            .trim()
            .isNotEmpty) {
      image =
          addSimpleWatermark(
        image,
        request.watermarkText,
      );
    }

    final List<int>
        encoded =
        img.encodeJpg(
      image,
      quality: 98,
    );

    final File output =
        File(
      request.outputPath,
    );

    output.writeAsBytesSync(
      encoded,
      flush: true,
    );

    return ImageProcessResult(
      path:
          output.path,
      width:
          image.width,
      height:
          image.height,
    );
  } catch (e) {
    debugPrint(
      'Image processing error: $e',
    );

    return null;
  }
}

img.Image addSimpleWatermark(
  img.Image source,
  String text,
) {
  try {
    final img.Image result =
        img.Image.from(
      source,
    );

    final int padding =
        (result.width * 0.025)
            .round()
            .clamp(
              8,
              40,
            );

    final int fontSize =
        (result.width * 0.018)
            .round()
            .clamp(
              12,
              32,
            );

    img.drawString(
      result,
      text,
      font:
          img.arial24,
      x: padding,
      y:
          result.height -
              padding -
              fontSize,
      color:
          img.ColorRgb8(
        255,
        255,
        255,
      ),
    );

    return result;
  } catch (_) {
    return source;
  }
}

class GridPainter
    extends CustomPainter {
  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final Paint paint =
        Paint()
          ..color =
              Colors.white24
          ..strokeWidth = 1;

    final double thirdWidth =
        size.width / 3;

    final double thirdHeight =
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
    extends State<
        SettingsScreen> {
  late bool sound;
  late bool clone;
  late bool horizon;
  late bool lens;
  late String fps;
  late bool qr;

  @override
  void initState() {
    super.initState();

    sound =
        widget.shutterSound;

    clone =
        widget.cloneShutterButton;

    horizon =
        widget.horizonLevel;

    lens =
        widget.dirtyLensNotice;

    fps =
        widget.portraitFps;

    qr =
        widget.qrScannerActive;
  }

  void updateParent() {
    widget.onUpdate(
      sound,
      clone,
      horizon,
      lens,
      fps,
      qr,
    );
  }

  void choosePortraitFps() {
    showDialog(
      context: context,
      builder:
          (dialogContext) {
        return AlertDialog(
          backgroundColor:
              const Color(
            0xFF202020,
          ),
          title:
              const Text(
            'محسن بورتريه AI',
            style:
                TextStyle(
              color:
                  Colors.white,
            ),
          ),
          content:
              Column(
            mainAxisSize:
                MainAxisSize.min,
            children: [
              fpsOption(
                dialogContext,
                'تلقائي',
              ),
              fpsOption(
                dialogContext,
                '50 فريم',
              ),
              fpsOption(
                dialogContext,
                '60 فريم',
              ),
            ],
          ),
        );
      },
    );
  }

  Widget fpsOption(
    BuildContext dialogContext,
    String value,
  ) {
    return ListTile(
      title:
          Text(
        value,
        style:
            const TextStyle(
          color:
              Colors.white,
        ),
      ),
      trailing:
          fps == value
              ? const Icon(
                  Icons.check,
                  color:
                      Colors.greenAccent,
                )
              : null,
      onTap: () {
        setState(() {
          fps =
              value;
        });

        updateParent();

        Navigator.pop(
          dialogContext,
        );
      },
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
              () {
            Navigator.pop(
              context,
            );
          },
        ),
      ),
      body:
          ListView(
        padding:
            const EdgeInsets.all(
          14,
        ),
        children: [
          const Padding(
            padding:
                EdgeInsets.only(
              bottom: 8,
            ),
            child:
                Text(
              'إعدادات التصوير',
              style:
                  TextStyle(
                color:
                    Colors.greenAccent,
                fontSize:
                    16,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ),

          SwitchListTile(
            title:
                const Text(
              'صوت الالتقاط',
              style:
                  TextStyle(
                color:
                    Colors.white,
              ),
            ),
            value:
                sound,
            activeColor:
                Colors.greenAccent,
            onChanged:
                (value) {
              setState(() {
                sound =
                    value;
              });

              updateParent();
            },
          ),

          SwitchListTile(
            title:
                const Text(
              'استنساخ زر الالتقاط',
              style:
                  TextStyle(
                color:
                    Colors.white,
              ),
            ),
            value:
                clone,
            activeColor:
                Colors.greenAccent,
            onChanged:
                (value) {
              setState(() {
                clone =
                    value;
              });

              updateParent();
            },
          ),

          SwitchListTile(
            title:
                const Text(
              'المستوى الأفقي',
              style:
                  TextStyle(
                color:
                    Colors.white,
              ),
            ),
            value:
                horizon,
            activeColor:
                Colors.greenAccent,
            onChanged:
                (value) {
              setState(() {
                horizon =
                    value;
              });

              updateParent();
            },
          ),

          ListTile(
            title:
                const Text(
              'محسن بورتريه AI',
              style:
                  TextStyle(
                color:
                    Colors.white,
              ),
            ),
            subtitle:
                Text(
              fps,
              style:
                  const TextStyle(
                color:
                    Colors.greenAccent,
              ),
            ),
            trailing:
                const Icon(
              Icons
                  .arrow_back_ios,
              size: 14,
              color:
                  Colors.white54,
            ),
            onTap:
                choosePortraitFps,
          ),

          SwitchListTile(
            title:
                const Text(
              'مسح رموز QR',
              style:
                  TextStyle(
                color:
                    Colors.white,
              ),
            ),
            value:
                qr,
            activeColor:
                Colors.greenAccent,
            onChanged:
                (value) {
              setState(() {
                qr =
                    value;
              });

              updateParent();
            },
          ),

          SwitchListTile(
            title:
                const Text(
              'الإشعار بالعدسات المتسخة',
              style:
                  TextStyle(
                color:
                    Colors.white,
              ),
            ),
            value:
                lens,
            activeColor:
                Colors.greenAccent,
            onChanged:
                (value) {
              setState(() {
                lens =
                    value;
              });

              updateParent();
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
                sound =
                    true;
                clone =
                    false;
                horizon =
                    false;
                lens =
                    true;
                fps =
                    'تلقائي';
                qr =
                    true;
              });

              ScaffoldMessenger
                  .of(context)
                  .showSnackBar(
                const SnackBar(
                  content:
                      Text(
                    'تمت استعادة الإعدادات الافتراضية',
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