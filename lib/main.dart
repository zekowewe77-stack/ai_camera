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

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  CameraController? controller;

  int selectedCameraIndex = 0;

  bool isCameraReady = false;
  bool isProcessing = false;

  bool mirrorFrontCamera = true;
  bool enhancementEnabled = true;

  double currentZoom = 1.0;
  double minZoom = 1.0;
  double maxZoom = 1.0;

  double startZoom = 1.0;

  FlashMode flashMode = FlashMode.off;

  String lastResolution = '';
  double lastMegapixels = 0;

  late AnimationController flashAnimation;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    flashAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
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
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await newController.initialize();

      final hardwareMinZoom =
          await newController.getMinZoomLevel();

      final hardwareMaxZoom =
          await newController.getMaxZoomLevel();

      minZoom = hardwareMinZoom;
      maxZoom = hardwareMaxZoom;
      currentZoom = minZoom;

      await newController.setZoomLevel(currentZoom);

      await newController.setFlashMode(flashMode);

      controller = newController;

      if (mounted) {
        setState(() {
          isCameraReady = true;
        });
      }
    } catch (e) {
      debugPrint('Camera initialization error: $e');

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

  @override
  void didChangeAppLifecycleState(
    AppLifecycleState state,
  ) {
    if (state == AppLifecycleState.resumed) {
      initializeCamera();
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      final c = controller;

      controller = null;

      if (c != null) {
        c.dispose();
      }

      if (mounted) {
        setState(() {
          isCameraReady = false;
        });
      }
    }
  }

  Future<void> switchCamera() async {
    if (cameras.length < 2 || isProcessing) {
      return;
    }

    selectedCameraIndex =
        (selectedCameraIndex + 1) % cameras.length;

    await initializeCamera();
  }

  Future<void> changeZoom(double value) async {
    final c = controller;

    if (c == null || !c.value.isInitialized) {
      return;
    }

    final zoom = value.clamp(
      minZoom,
      maxZoom,
    );

    try {
      await c.setZoomLevel(
        zoom.toDouble(),
      );

      if (mounted) {
        setState(() {
          currentZoom = zoom.toDouble();
        });
      }
    } catch (e) {
      debugPrint('Zoom error: $e');
    }
  }

  Future<void> capturePhoto() async {
    final c = controller;

    if (c == null ||
        !c.value.isInitialized ||
        isProcessing) {
      return;
    }

    try {
      setState(() {
        isProcessing = true;
      });

      HapticFeedback.mediumImpact();

      flashAnimation.forward(from: 0).then((_) {
        if (mounted) {
          flashAnimation.reverse();
        }
      });

      final XFile photo = await c.takePicture();

      final String inputPath = photo.path;

      final String outputPath = p.join(
        File(inputPath).parent.path,
        'AI_CAMERA_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );

      final Uint8List bytes =
          await File(inputPath).readAsBytes();

      final Map<String, dynamic> processingData = {
        'bytes': bytes,
        'outputPath': outputPath,
        'mirrorFront':
            isFrontCamera && mirrorFrontCamera,
        'enhance': enhancementEnabled,
        'zoom': currentZoom,
      };

      final ProcessedImageResult? result =
          await Isolate.run(
        () => processImage(processingData),
      );

      if (result == null) {
        throw Exception(
          'Could not process image',
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

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تم حفظ الصورة • '
              '${result.width}×${result.height} • '
              '${result.megapixels.toStringAsFixed(1)} MP',
            ),
            duration: const Duration(
              seconds: 2,
            ),
          ),
        );
      }

      try {
        await File(inputPath).delete();
      } catch (_) {}

      try {
        await File(outputPath).delete();
      } catch (_) {}
    } catch (e, stackTrace) {
      debugPrint('Capture error: $e');
      debugPrint(stackTrace.toString());

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
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
        });
      }
    }
  }

  Future<void> openGallery() async {
    try {
      await Gal.open();
    } catch (e) {
      debugPrint('Gallery error: $e');
    }
  }

  Widget buildCameraPreview() {
    final c = controller;

    if (c == null || !c.value.isInitialized) {
      return const SizedBox();
    }

    Widget preview = CameraPreview(c);

    if (isFrontCamera && mirrorFrontCamera) {
      preview = Transform(
        alignment: Alignment.center,
        transform: Matrix4.rotationY(
          3.141592653589793,
        ),
        child: preview,
      );
    }

    return Center(
      child: AspectRatio(
        aspectRatio: c.value.aspectRatio,
        child: preview,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (cameras.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Text(
            'لم يتم العثور على كاميرا',
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (isCameraReady)
            buildCameraPreview(),

          if (!isCameraReady)
            const Center(
              child: CircularProgressIndicator(),
            ),

          // المعلومات العلوية
          Positioned(
            top: 45,
            left: 15,
            right: 15,
            child: Row(
              mainAxisAlignment:
                  MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: Icon(
                    flashMode == FlashMode.torch
                        ? Icons.flash_on
                        : Icons.flash_off,
                  ),
                  onPressed: () async {
                    final c = controller;

                    if (c == null) {
                      return;
                    }

                    final nextMode =
                        flashMode == FlashMode.torch
                            ? FlashMode.off
                            : FlashMode.torch;

                    try {
                      await c.setFlashMode(
                        nextMode,
                      );

                      if (mounted) {
                        setState(() {
                          flashMode = nextMode;
                        });
                      }
                    } catch (e) {
                      debugPrint(
                        'Flash error: $e',
                      );
                    }
                  },
                ),

                Container(
                  padding:
                      const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius:
                        BorderRadius.circular(18),
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
                        lastResolution.isEmpty
                            ? 'Camera'
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
                        : Icons
                            .auto_awesome_outlined,
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
          ),

          // Zoom
          Positioned(
            left: 20,
            right: 20,
            bottom: 165,
            child: Column(
              children: [
                Text(
                  '${currentZoom.toStringAsFixed(1)}×',
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 18,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),

                Slider(
                  value: currentZoom.clamp(
                    minZoom,
                    maxZoom,
                  ),
                  min: minZoom,
                  max: maxZoom,
                  onChanged: changeZoom,
                ),

                Text(
                  'أقصى Zoom حقيقي: '
                  '${maxZoom.toStringAsFixed(1)}×',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),

          // Pinch Zoom
          Positioned.fill(
            child: GestureDetector(
              onScaleStart: (_) {
                startZoom = currentZoom;
              },
              onScaleUpdate: (details) {
                changeZoom(
                  startZoom * details.scale,
                );
              },
              child: const SizedBox(),
            ),
          ),

          // زر التصوير
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment:
                  MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  iconSize: 30,
                  icon: const Icon(
                    Icons.photo_library_outlined,
                  ),
                  onPressed:
                      isProcessing
                          ? null
                          : openGallery,
                ),

                GestureDetector(
                  onTap:
                      isProcessing
                          ? null
                          : capturePhoto,
                  child: Container(
                    width: 78,
                    height: 78,
                    decoration:
                        BoxDecoration(
                      shape:
                          BoxShape.circle,
                      border:
                          Border.all(
                        color: Colors.white,
                        width: 3,
                      ),
                    ),
                    child: Center(
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration:
                            const BoxDecoration(
                          shape:
                              BoxShape.circle,
                          color: Colors.white,
                        ),
                        child:
                            isProcessing
                                ? const Padding(
                                    padding:
                                        EdgeInsets.all(
                                      18,
                                    ),
                                    child:
                                        CircularProgressIndicator(
                                      strokeWidth:
                                          2,
                                      color:
                                          Colors.black,
                                    ),
                                  )
                                : null,
                      ),
                    ),
                  ),
                ),

                IconButton(
                  iconSize: 30,
                  icon: const Icon(
                    Icons
                        .cameraswitch_outlined,
                  ),
                  onPressed:
                      isProcessing
                          ? null
                          : switchCamera,
                ),
              ],
            ),
          ),

          // تأثير الفلاش
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: flashAnimation,
                builder:
                    (context, child) {
                  return Opacity(
                    opacity:
                        flashAnimation.value *
                            0.75,
                    child: Container(
                      color: Colors.white,
                    ),
                  );
                },
              ),
            ),
          ),

          if (isProcessing)
            const Positioned(
              bottom: 130,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  'جاري تجهيز الصورة...',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight:
                        FontWeight.bold,
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
    WidgetsBinding.instance
        .removeObserver(this);

    flashAnimation.dispose();

    controller?.dispose();

    super.dispose();
  }
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

ProcessedImageResult? processImage(
  Map<String, dynamic> data,
) {
  try {
    final Uint8List bytes =
        data['bytes'] as Uint8List;

    final String outputPath =
        data['outputPath'] as String;

    final bool mirrorFront =
        data['mirrorFront'] as bool;

    final bool enhance =
        data['enhance'] as bool;

    final double zoom =
        data['zoom'] as double;

    img.Image? image =
        img.decodeJpg(bytes);

    if (image == null) {
      return null;
    }

    // تصحيح Orientation
    image = img.bakeOrientation(image);

    // عكس السيلفي فقط إذا كان Preview معكوسًا
    if (mirrorFront) {
      image = img.flipHorizontal(image);
    }

    if (enhance) {
      // تحسين ألوان خفيف بدون مبالغة
      image = img.adjustColor(
        image,
        brightness: 1.01,
        contrast: 1.06,
        saturation: 1.08,
      );

      // Sharpen خفيف
      image = img.convolution(
        image,
        filter: const [
          0, -1, 0,
          -1, 5, -1,
          0, -1, 0,
        ],
        amount:
            zoom >= 2.0
                ? 0.45
                : 0.30,
      );
    }

    final List<int> outputBytes =
        img.encodeJpg(
      image,
      quality: 98,
    );

    File(outputPath).writeAsBytesSync(
      outputBytes,
      flush: true,
    );

    return ProcessedImageResult(
      path: outputPath,
      width: image.width,
      height: image.height,
    );
  } catch (e) {
    debugPrint(
      'Background image processing error: $e',
    );

    return null;
  }
}