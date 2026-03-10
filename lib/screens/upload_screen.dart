import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:video_player/video_player.dart';

import 'package:road_anomaly_detector/theme/app_theme.dart';
import 'package:road_anomaly_detector/services/model_service.dart';
import 'package:road_anomaly_detector/models/detection.dart';

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {

  bool _hasFile = false;
  bool _detecting = false;

  File? _selectedFile;
  bool _isVideo = false;

  VideoPlayerController? _videoController;

  List<Detection> _detections = [];

  final ModelService _modelService = ModelService();

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  // ───────── Pick Image / Video ─────────

  Future<void> _pickFile() async {

    final result = await FilePicker.platform.pickFiles(
      type: FileType.media,
    );

    if (result == null) return;

    final file = File(result.files.single.path!);

    final extension = result.files.single.extension?.toLowerCase();

    _isVideo = extension == "mp4" ||
        extension == "mov" ||
        extension == "avi";

    if (_isVideo) {

      _videoController = VideoPlayerController.file(file);

      await _videoController!.initialize();
      _videoController!.setLooping(true);
      _videoController!.play();
    }

    setState(() {

      _selectedFile = file;
      _hasFile = true;
      _detections.clear();
    });
  }

  // ───────── Image Detection ─────────

  Future<void> _detectImage() async {

    if (_selectedFile == null) return;

    setState(() => _detecting = true);

    try {

      final bytes = await _selectedFile!.readAsBytes();

      final img.Image? image = img.decodeImage(bytes);

      if (image == null) return;

      final detections =
      await _modelService.detectImage(image);

      setState(() {
        _detections = detections;
      });

    } catch (e) {

      debugPrint("Detection error: $e");
    }

    setState(() => _detecting = false);
  }

  Future<void> _detect() async {

    await _detectImage();
  }

  // ───────── Scale YOLO Boxes ─────────

  Rect _scaleBox(Rect box, Size imageSize) {

    const modelSize = 640;

    final scaleX = imageSize.width / modelSize;
    final scaleY = imageSize.height / modelSize;

    return Rect.fromLTWH(
      box.left * scaleX,
      box.top * scaleY,
      box.width * scaleX,
      box.height * scaleY,
    );
  }

  // ───────── UI ─────────

  @override
  Widget build(BuildContext context) {

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,

      appBar: AppBar(
        backgroundColor: AppColors.backgroundDark,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back,
              color: AppColors.slate400),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          "ROAD ANOMALY DETECTOR",
          style: TextStyle(
            color: AppColors.slateText,
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
        ),
      ),

      body: SingleChildScrollView(
        child: Column(
          children: [

            // ───── Upload Card ─────

            Padding(
              padding: const EdgeInsets.fromLTRB(
                  16, 32, 16, 0),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    vertical: 40, horizontal: 24),
                decoration: BoxDecoration(
                  color: AppColors.surfaceDark
                      .withOpacity(0.30),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: AppColors.borderDark,
                      width: 2),
                ),
                child: Column(
                  children: [

                    const Icon(
                      Icons.cloud_upload_outlined,
                      color: AppColors.primary,
                      size: 40,
                    ),

                    const SizedBox(height: 20),

                    Text(
                      _hasFile
                          ? "File Ready"
                          : "No Media Uploaded",
                      style: const TextStyle(
                        color: AppColors.slateText,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),

                    const SizedBox(height: 20),

                    if (!_hasFile)
                      ElevatedButton.icon(
                        onPressed: _pickFile,
                        icon: const Icon(
                            Icons.add_photo_alternate_outlined),
                        label: const Text(
                            "UPLOAD IMAGE OR VIDEO"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                          AppColors.primary,
                          foregroundColor:
                          AppColors.white,
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // ───── Preview Section ─────

            if (_hasFile) ...[

              const SizedBox(height: 24),

              Padding(
                padding:
                const EdgeInsets.all(16),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.surfaceDark,
                    borderRadius:
                    BorderRadius.circular(12),
                    border: Border.all(
                        color: AppColors.borderDark),
                  ),
                  child: Column(
                    children: [

                      SizedBox(
                        width: double.infinity,
                        height: 320,
                        child: LayoutBuilder(
                          builder:
                              (context, constraints) {

                            final imageSize = Size(
                              constraints.maxWidth,
                              constraints.maxHeight,
                            );

                            return Stack(
                              fit: StackFit.expand,
                              children: [

                                if (_isVideo &&
                                    _videoController != null)
                                  VideoPlayer(
                                      _videoController!),

                                if (!_isVideo &&
                                    _selectedFile != null)
                                  Image.file(
                                    _selectedFile!,
                                    fit: BoxFit.contain,
                                  ),

                                ..._detections.map((det) {

                                  final box =
                                  _scaleBox(
                                    det.boundingBox,
                                    imageSize,
                                  );

                                  return Positioned(
                                    left: box.left,
                                    top: box.top,
                                    width: box.width,
                                    height: box.height,
                                    child: Stack(
                                      clipBehavior: Clip.none,
                                      children: [

                                        Container(
                                          decoration:
                                          BoxDecoration(
                                            border: Border.all(
                                                color:
                                                Colors.green,
                                                width: 2),
                                          ),
                                        ),

                                        Positioned(
                                          top: -20,
                                          left: 0,
                                          child: Container(
                                            constraints:
                                            const BoxConstraints(
                                                minWidth: 80),
                                            padding:
                                            const EdgeInsets
                                                .symmetric(
                                                horizontal: 6,
                                                vertical: 2),
                                            color: Colors.green,
                                            child: Text(
                                              "${det.label} ${(det.confidence * 100).toStringAsFixed(1)}%",
                                              maxLines: 1,
                                              overflow:
                                              TextOverflow
                                                  .visible,
                                              style:
                                              const TextStyle(
                                                fontSize: 11,
                                                fontWeight:
                                                FontWeight
                                                    .bold,
                                                color:
                                                Colors.black,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                })
                              ],
                            );
                          },
                        ),
                      ),

                      const SizedBox(height: 16),

                      Row(
                        children: [

                          Expanded(
                            child:
                            ElevatedButton.icon(
                              onPressed: _detect,
                              icon: const Icon(
                                  Icons.visibility_outlined),
                              label: Text(
                                _detecting
                                    ? "DETECTING..."
                                    : "DETECT",
                              ),
                              style: ElevatedButton
                                  .styleFrom(
                                backgroundColor:
                                AppColors.primary,
                                foregroundColor:
                                AppColors.white,
                              ),
                            ),
                          ),

                          const SizedBox(width: 12),

                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _hasFile = false;
                                _selectedFile =
                                null;
                                _detections
                                    .clear();
                              });
                            },
                            child: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color:
                                AppColors.borderDark,
                                borderRadius:
                                BorderRadius
                                    .circular(8),
                              ),
                              child: const Icon(
                                Icons.delete_outline,
                                color:
                                AppColors.slate300,
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }
}