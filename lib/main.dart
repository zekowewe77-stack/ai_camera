import 'dart:async';
import 'dart:io';

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
      title: 'AI Camera Pro',
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

class ProcessedImageResult {
  final String path;
  final int width;
  final int height;

  const ProcessedImageResult({
    required this.path,
    required this.width,
    required this.height,
  });

  double get megapixels =>
      (width * height) / 1000000.0;
}

/// معالجة الصورة في background isolate
Future<ProcessedImageResult?> processImageInBackground(
  Map<String, dynamic> data,
) async {
  try {
    final String inputPath =
        data['inputPath'] as String;

    final String outputPath =
        data['outputPath'] as String;

    final bool mirrorFront =
        data['mirrorFront'] as bool;

    final bool enhance =
        data['enhance'] as bool;

    final double zoom =
        data['zoom'] as double;

    final File inputFile =
        File(inputPath);

    final List<int> bytes =
        await inputFile.readAsBytes();

    img.Image? image =
        img.decodeJpg(
      bytes,
    );

    if (image == null) {
      return null;
    }

    // تصحيح اتجاه الصورة حسب بيانات EXIF
    image = img.bakeOrientation(
      image,
    );

    // جعل السيلفي النهائي مطابقًا للـPreview
    if (mirrorFront) {
      image = img.flipHorizontal(
        image,
      );
    }

    if (enhance) {
      // تحسين ألوان طبيعي
      image = img.adjustColor(
        image,
        brightness: 1.01,
        contrast: 1.07,
        saturation: 1.08,
      );

      // زيادة حدة محسوبة
      final double sharpenAmount =
          zoom >= 2.0
              ? 0.50
              : 0.32;

      image = img.convolution(
        image,
        filter: const [
          0, -1, 0,
          -1, 5, -1,
          0, -1, 0,
        ],
        amount: sharpenAmount,
      );
    }

    // الحفاظ على أعلى جودة ممكنة عند إعادة الحفظ
    final int quality =
        image.width * image.height >= 12000000
            ? 98
            : 97;

    final List<int> outputBytes =
        img.encodeJpg(
      image,
      quality: quality,
    );

    await File(outputPath)
        .writeAsBytes(
      outputBytes,
      flush: true,
    );

    return ProcessedImageResult(
      path: outputPath,
      width: image.width,
      height: image.height,
    );
  } catch (e, stackTrace) {
    debugPrint(
      'Image processing error: $e',
    );

    debugPrint(
      stackTrace.toString(),
    );

    return null;
  }
}

class _CameraScreenState
    extends State<CameraScreen>
    with
        WidgetsBindingObserver,
        SingleTickerProviderStateMixin {

  CameraController? controller;

  int selectedCameraIndex = 0;

  bool isCameraReady = false;
  bool isProcessing = false;
  bool isRecording = false;

  FlashMode flashMode =
      FlashMode.off;

  // Hardware Zoom الحقيقي
  double currentZoom = 1.0;
  double minZoom = 1.0;
  double maxZoom = 1.0;

  double gestureStartZoom = 1.0;

  bool showZoomPanel = false;

  bool enhancementEnabled = true;

  bool mirrorFrontCamera = true;

  bool gridEnabled = false;

  bool hdrEnabled = true;

  String currentMode = 'PHOTO';

  Timer? videoTimer;

  int videoSeconds = 0;

  String lastResolution = '';

  double lastMegapixels = 0;

  late AnimationController
      flashAnimation;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance
        .addObserver(this);

    flashAnimation =
        AnimationController(
      vsync: this,
      duration:
          const Duration(
        milliseconds: 120,
      ),
    );

    requestPermissionAndInitialize();
  }

  Future<void>
      requestPermissionAndInitialize() async {

    await PermissionHelper.request();

    if (!mounted) return;

    if (cameras.isNotEmpty) {
      await initializeCamera(
        selectedCameraIndex,
      );
    }
  }

  @override
  void didChangeAppLifecycleState(
    AppLifecycleState state,
  ) {
    final CameraController? c =
        controller;

    if (state ==
            AppLifecycleState.inactive ||
        state ==
            AppLifecycleState.paused) {

      if (c != null &&
          c.value.isInitialized) {
        c.dispose();
      }

      controller = null;

      if (mounted) {
        setState(() {
          isCameraReady = false;
        });
      }

      return;
    }

    if (state ==
        AppLifecycleState.resumed) {
      initializeCamera(
        selectedCameraIndex,
      );
    }
  }

  Future<void> initializeCamera(
    int index,
  ) async {
    if (cameras.isEmpty) {
      return;
    }

    if (index < 0 ||
        index >= cameras.length) {
      return;
    }

    if (mounted) {
      setState(() {
        isCameraReady = false;
      });
    }

    final CameraController?
        oldController = controller;

    controller = null;

    if (oldController != null) {
      try {
        await oldController.dispose();
      } catch (_) {}
    }

    final CameraController newController =
        CameraController(
      cameras[index],

      // أعلى Resolution حقيقية يدعمها الجهاز
      ResolutionPreset.max,

      enableAudio: true,

      imageFormatGroup:
          ImageFormatGroup.jpeg,
    );

    try {
      await newController
          .initialize();

      final double hardwareMinZoom =
          await newController
              .getMinZoomLevel();

      final double hardwareMaxZoom =
          await newController
              .getMaxZoomLevel();

      controller =
          newController;

      minZoom =
          hardwareMinZoom;

      // لا نفرض 15x أو أي رقم مصطنع
      maxZoom =
          hardwareMaxZoom;

      currentZoom =
          minZoom;

      await newController
          .setZoomLevel(
        currentZoom,
      );

      await newController
          .setFlashMode(
        flashMode,
      );

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
        await newController
            .dispose();
      } catch (_) {}

      if (mounted) {
        setState(() {
          isCameraReady = false;
        });
      }
    }
  }

  bool get isFrontCamera {
    if (cameras.isEmpty) {
      return false;
    }

    return cameras[
          selectedCameraIndex
        ].lensDirection ==
        CameraLensDirection.front;
  }

  String get currentCameraName {
    if (cameras.isEmpty) {
      return 'Camera';
    }

    return cameras[
      selectedCameraIndex
    ].name;
  }

  Future<void> switchCamera() async {
    if (cameras.length < 2) {
      return;
    }

    if (isProcessing ||
        isRecording) {
      return;
    }

    selectedCameraIndex =
        (selectedCameraIndex + 1) %
            cameras.length;

    await initializeCamera(
      selectedCameraIndex,
    );
  }

  Future<void> setZoom(
    double value,
  ) async {
    final CameraController? c =
        controller;

    if (c == null ||
        !c.value.isInitialized) {
      return;
    }

    final double zoom =
        value.clamp(
      minZoom,
      maxZoom,
    ).toDouble();

    setState(() {
      currentZoom = zoom;
      showZoomPanel = true;
    });

    try {
      await c.setZoomLevel(
        zoom,
      );
    } catch (e) {
      debugPrint(
        'Zoom error: $e',
      );
    }
  }

  Future<void> captureAction() async {
    final CameraController? c =
        controller;

    if (c == null ||
        !c.value.isInitialized ||
        isProcessing) {
      return;
    }

    if (currentMode == 'VIDEO') {
      await toggleVideoRecording();
      return;
    }

    await capturePhoto();
  }

  Future<void> capturePhoto() async {
    final CameraController? c =
        controller;

    if (c == null ||
        !c.value.isInitialized ||
        isProcessing) {
      return;
    }

    try {
      setState(() {
        isProcessing = true;
        showZoomPanel = false;
      });

      // تأثير الالتقاط
      flashAnimation
          .forward(
        from: 0,
      )
          .then((_) {
        if (mounted) {
          flashAnimation.reverse();
        }
      });

      SystemSound.play(
        SystemSoundType.click,
      );

      HapticFeedback
          .mediumImpact();

      // التقاط الصورة الأصلية
      final XFile photo =
          await c.takePicture();

      final String inputPath =
          photo.path;

      final String outputPath =
          p.join(
        File(inputPath)
            .parent
            .path,
        'AI_CAMERA_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );

      final bool front =
          isFrontCamera;

      final bool enhance =
          enhancementEnabled ||
          hdrEnabled;

      final double zoom =
          currentZoom;

      // تجهيز البيانات قبل تشغيل الـisolate
      final Map<String, dynamic>
          arguments = {
        'inputPath':
            inputPath,
        'outputPath':
            outputPath,
        'mirrorFront':
            front &&
                mirrorFrontCamera,
        'enhance':
            enhance,
        'zoom':
            zoom,
      };

      // معالجة الصورة بعيدًا عن UI
      final ProcessedImageResult?
          result =
          await Isolate.run(
        () =>
            processImageInBackground(
          arguments,
        ),
      );

      if (result == null) {
        throw Exception(
          'Failed to process image',
        );
      }

      // حفظ الصورة في معرض الهاتف
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

        ScaffoldMessenger.of(
          context,
        )
            .showSnackBar(
          SnackBar(
            content: Text(
              'تم حفظ الصورة • '
              '${result.width}×${result.height} • '
              '${result.megapixels.toStringAsFixed(1)} MP',
            ),
            duration:
                const Duration(
              seconds: 2,
            ),
          ),
        );
      }

      // حذف الملفات المؤقتة
      try {
        await File(
          inputPath,
        ).delete();
      } catch (_) {}

      try {
        await File(
          outputPath,
        ).delete();
      } catch (_) {}
    } catch (e, stackTrace) {
      debugPrint(
        'Capture error: $e',
      );

      debugPrint(
        stackTrace.toString(),
      );

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        )
            .showSnackBar(
          SnackBar(
            content: Text(
              'حصل خطأ أثناء التصوير: $e',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          isProcessing = false;
        });
      }
    }
  }

  Future<void>
      toggleVideoRecording() async {

    final CameraController? c =
        controller;

    if (c == null ||
        !c.value.isInitialized ||
        isProcessing) {
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

        await Gal.putVideo(
          video.path,
        );

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          )
              .showSnackBar(
            const SnackBar(
              content: Text(
                'تم حفظ الفيديو في المعرض',
              ),
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

        videoTimer =
            Timer.periodic(
          const Duration(
            seconds: 1,
          ),
          (_) {
            if (!mounted) {
              return;
            }

            setState(() {
              videoSeconds++;
            });
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
      }
    }
  }

  Future<void> openGallery() async {
    try {
      await Gal.open();
    } catch (e) {
      debugPrint(
        'Gallery error: $e',
      );
    }
  }

  Widget buildPreview() {
    final CameraController? c =
        controller;

    if (c == null ||
        !c.value.isInitialized) {
      return const SizedBox();
    }

    Widget preview =
        CameraPreview(c);

    // Mirror للكاميرا الأمامية
    if (isFrontCamera &&
        mirrorFrontCamera) {
      preview = Transform(
        alignment:
            Alignment.center,
        transform:
            Matrix4.rotationY(
          3.141592653589793,
        ),
        child: preview,
      );
    }

    return Center(
      child: AspectRatio(
        aspectRatio:
            c.value.aspectRatio,
        child: preview,
      ),
    );
  }

  Widget buildTopBar() {
    return Positioned(
      top: 45,
      left: 15,
      right: 15,
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
            ),
            onPressed: () async {
              final CameraController?
                  c =
                  controller;

              if (c == null) {
                return;
              }

              setState(() {
                flashMode =
                    flashMode ==
                            FlashMode.torch
                        ? FlashMode.off
                        : FlashMode.torch;
              });

              try {
                await c.setFlashMode(
                  flashMode,
                );
              } catch (e) {
                debugPrint(
                  'Flash error: $e',
                );
              }
            },
          ),

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
                  BorderRadius.circular(
                18,
              ),
            ),
            child: Column(
              children: [
                Text(
                  isFrontCamera
                      ? 'FRONT'
                      : 'REAR',
                  style:
                      const TextStyle(
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),

                Text(
                  lastResolution
                          .isEmpty
                      ? currentCameraName
                      : '$lastResolution • '
                        '${lastMegapixels.toStringAsFixed(1)} MP',
                  style:
                      const TextStyle(
                    color:
                        Colors.greenAccent,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),

          IconButton(
            icon: Icon(
              enhancementEnabled
                  ? Icons.auto_awesome
                  : Icons.auto_awesome_outlined,
            ),
            color:
                enhancementEnabled
                    ? Colors.greenAccent
                    : Colors.white,
            onPressed: () {
              setState(() {
                enhancementEnabled =
                    !enhancementEnabled;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget buildZoomPanel() {
    if (!showZoomPanel) {
      return const SizedBox();
    }

    return Positioned(
      left: 18,
      right: 18,
      bottom: 185,
      child: Container(
        padding:
            const EdgeInsets.symmetric(
          horizontal: 15,
          vertical: 10,
        ),
        decoration:
            BoxDecoration(
          color:
              Colors.black.withOpacity(
            0.88,
          ),
          borderRadius:
              BorderRadius.circular(
            22,
          ),
          border:
              Border.all(
            color:
                Colors.white24,
          ),
        ),
        child: Column(
          children: [
            Text(
              '${currentZoom.toStringAsFixed(1)}×',
              style:
                  const TextStyle(
                color:
                    Colors.greenAccent,
                fontSize: 18,
                fontWeight:
                    FontWeight.bold,
              ),
            ),

            Slider(
              value: currentZoom
                  .clamp(
                minZoom,
                maxZoom,
              ),
              min: minZoom,
              max: maxZoom,
              onChanged:
                  setZoom,
            ),

            Text(
              'Hardware Max: '
              '${maxZoom.toStringAsFixed(1)}×',
              style:
                  const TextStyle(
                color:
                    Colors.white60,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildBottomControls() {
    return Positioned(
      bottom: 30,
      left: 0,
      right: 0,
      child: Column(
        mainAxisSize:
            MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment:
                MainAxisAlignment
                    .center,
            children: [
              for (final mode in [
                'VIDEO',
                'PHOTO',
                'PORTRAIT',
                'NIGHT',
              ])
                Padding(
                  padding:
                      const EdgeInsets
                          .symmetric(
                    horizontal: 9,
                  ),
                  child:
                      GestureDetector(
                    onTap:
                        isProcessing ||
                                isRecording
                            ? null
                            : () {
                                setState(() {
                                  currentMode =
                                      mode;
                                });
                              },
                    child: Text(
                      mode,
                      style:
                          TextStyle(
                        color:
                            currentMode ==
                                    mode
                                ? Colors
                                    .greenAccent
                                : Colors
                                    .white60,
                        fontWeight:
                            FontWeight
                                .bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(
            height: 15,
          ),

          Row(
            mainAxisAlignment:
                MainAxisAlignment
                    .spaceEvenly,
            children: [
              // Gallery
              IconButton(
                iconSize: 30,
                icon:
                    const Icon(
                  Icons
                      .photo_library_outlined,
                ),
                onPressed:
                    isProcessing
                        ? null
                        : openGallery,
              ),

              // Shutter
              GestureDetector(
                onTap:
                    isProcessing
                        ? null
                        : captureAction,
                child:
                    Stack(
                  alignment:
                      Alignment.center,
                  children: [
                    Container(
                      width: 78,
                      height: 78,
                      decoration:
                          BoxDecoration(
                        shape:
                            BoxShape
                                .circle,
                        border:
                            Border.all(
                          color:
                              Colors.white,
                          width: 3,
                        ),
                      ),
                    ),

                    Container(
                      width: 64,
                      height: 64,
                      decoration:
                          BoxDecoration(
                        shape:
                            BoxShape
                                .circle,
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
                                        2,
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
                                    )
                                  : null,
                    ),
                  ],
                ),
              ),

              // Switch Camera
              IconButton(
                iconSize: 30,
                icon:
                    const Icon(
                  Icons
                      .cameraswitch_outlined,
                ),
                onPressed:
                    isProcessing ||
                            isRecording
                        ? null
                        : switchCamera,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget buildGrid() {
    if (!gridEnabled) {
      return const SizedBox();
    }

    return IgnorePointer(
      child: CustomPaint(
        painter:
            GridPainter(),
        size:
            Size.infinite,
      ),
    );
  }

  @override
  Widget build(
      BuildContext context) {

    if (cameras.isEmpty) {
      return const Scaffold(
        backgroundColor:
            Colors.black,
        body: Center(
          child: Text(
            'لم يتم العثور على كاميرا',
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
            buildPreview(),

          if (!isCameraReady)
            const Center(
              child:
                  CircularProgressIndicator(),
            ),

          buildGrid(),

          buildTopBar(),

          buildZoomPanel(),

          // Pinch Zoom
          Positioned.fill(
            child:
                GestureDetector(
              onScaleStart:
                  (_) {
                gestureStartZoom =
                    currentZoom;
              },

              onScaleUpdate:
                  (details) {
                final double
                    newZoom =
                    gestureStartZoom *
                        details.scale;

                setZoom(
                  newZoom,
                );
              },

              child:
                  const SizedBox(),
            ),
          ),

          // تأثير الالتقاط
          Positioned.fill(
            child:
                IgnorePointer(
              child:
                  AnimatedBuilder(
                animation:
                    flashAnimation,
                builder:
                    (
                  context,
                  child,
                ) {
                  return Opacity(
                    opacity:
                        flashAnimation
                            .value *
                            0.8,
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

          if (isProcessing)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 160,
              child:
                  Center(
                child: Text(
                  'جاري تحسين الصورة...',
                  style:
                      TextStyle(
                    color:
                        Colors.white,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),
            ),

          buildBottomControls(),
        ],
      ),
    );
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
    covariant GridPainter oldDelegate,
  ) {
    return false;
  }
}

/// مساعد بسيط للصلاحيات.
/// الكاميرا والمايك يتم طلبهما هنا.
class PermissionHelper {
  static Future<void> request() async {
    // يتم الاعتماد على camera plugin في طلب صلاحية الكاميرا.
    // هذه الدالة موجودة بشكل منفصل حتى يظل main.dart مرتبًا.
  }
}