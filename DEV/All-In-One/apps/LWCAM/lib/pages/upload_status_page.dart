import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/upload_contoller.dart';
import '../theme/app_colors.dart';

// Model inside page
class UploadStatus {
  String filename;
  // Mutable: filled in asynchronously after queueing (a synchronous
  // lengthSync per file blocked the UI isolate on large batches).
  String size;
  var progress = 0.0.obs;
  // Theme-resolved "in progress" color; instances are only created after
  // runApp, so Get.theme is safe here (literal fallback just in case).
  var color = (Get.theme.extension<LifewoodColors>()?.info ??
          const Color(0xFF2A7F8E))
      .obs;
  var icon = Rx<IconData>(Icons.hourglass_bottom);
  var errorMsg = "".obs;
  var showError = false.obs;

  UploadStatus({required this.filename, required this.size});
}

class UploadStatusPage extends StatefulWidget {
  const UploadStatusPage({super.key});

  @override
  State<UploadStatusPage> createState() => _UploadStatusPageState();
}

class _UploadStatusPageState extends State<UploadStatusPage> {
  final UploadController c = Get.find<UploadController>();
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Widget buildUploadCard(UploadStatus upload) {
    final cs = Theme.of(context).colorScheme;
    final lw = LifewoodColors.of(context);
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.insert_drive_file,
                size: 44, color: cs.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    upload.filename,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Obx(
                    () => LinearProgressIndicator(
                      value: upload.progress.value,
                      minHeight: 10,
                      borderRadius: BorderRadius.circular(5),
                      backgroundColor: cs.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        upload.color.value,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Obx(
                    () => Row(
                      children: [
                        Text(
                          upload.progress.value == 1.0
                              ? '100%'
                              : '${(upload.progress.value * 100).round()}%',
                          style: TextStyle(
                            color: upload.color.value,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          upload.size,
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Obx(() {
                    if (upload.progress.value == 1.0) {
                      return Text(
                        'Completed',
                        style: TextStyle(
                          color: lw.success,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      );
                    } else if (upload.showError.value) {
                      return GestureDetector(
                        onTap: () {
                          final index = c.uploads.indexOf(upload);
                          c.retryUpload(index); // retry failed file
                        },
                        child: Text(
                          upload.errorMsg.value,
                          style: TextStyle(
                            color: cs.error,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      );
                    }
                    return Container();
                  }),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Obx(
              () =>
                  Icon(upload.icon.value, color: upload.color.value, size: 36),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Upload Status",
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Get.back(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              Expanded(
                child: Obx(() {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _scrollToLatest();
                  });
                  return ListView.builder(
                    controller: _scrollController,
                    itemCount: c.uploads.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10.0),
                      child: buildUploadCard(c.uploads[index]),
                    ),
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
