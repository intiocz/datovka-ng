import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../data/models.dart';
import '../theme.dart';
import 'app_scope.dart';

bool isPdf(Attachment a) => a.name.toLowerCase().endsWith('.pdf');

/// Shows a PDF attachment inside the app.
Future<void> showPdf(BuildContext context, Message m, Attachment a) async {
  final s = AppScope.of(context);
  final path = s.attachmentFile(m, a);
  if (path == null || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => AppScope(
        state: s,
        child: _PdfPage(message: m, attachment: a, path: path),
      ),
    ),
  );
}

class _PdfPage extends StatelessWidget {
  final Message message;
  final Attachment attachment;
  final String path;

  const _PdfPage({
    required this.message,
    required this.attachment,
    required this.path,
  });

  @override
  Widget build(BuildContext context) {
    final t = Tokens.of(context);
    final text = Theme.of(context).textTheme;
    final s = AppScope.of(context);
    return Scaffold(
      backgroundColor: t.paper,
      appBar: AppBar(
        backgroundColor: t.surface,
        surfaceTintColor: Colors.transparent,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(attachment.name, style: text.titleMedium),
            Text(
              message.subject,
              style: text.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () => s.openAttachment(message, attachment),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Otevřít v jiné aplikaci'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: PdfViewer.file(
        path,
        params: PdfViewerParams(
          backgroundColor: t.paper,
          margin: 16,
          loadingBannerBuilder: (context, bytesDownloaded, totalBytes) =>
              const Center(child: CircularProgressIndicator()),
          errorBannerBuilder: (context, error, stackTrace, documentRef) =>
              Center(
                child: Text(
                  'PDF se nepodařilo zobrazit: $error',
                  style: text.bodySmall,
                ),
              ),
        ),
      ),
    );
  }
}
