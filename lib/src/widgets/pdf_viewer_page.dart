import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pdfx/pdfx.dart';
import 'package:url_launcher/url_launcher.dart';

/// Встроенный просмотр PDF (чеки и документы из Telegram): файл скачивается
/// из нашего Storage и листается прямо в приложении с пинч-зумом.
/// Если файл не PDF или не отрисовался — кнопка «Открыть в браузере».
class PdfViewerPage extends StatefulWidget {
  const PdfViewerPage({super.key, required this.url, this.title});

  final String url;
  final String? title;

  static Future<void> open(BuildContext context, {required String url, String? title}) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PdfViewerPage(url: url, title: title)),
    );
  }

  @override
  State<PdfViewerPage> createState() => _PdfViewerPageState();
}

class _PdfViewerPageState extends State<PdfViewerPage> {
  PdfControllerPinch? _controller;
  String? _error;
  int _page = 1;
  int _pages = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await http.get(Uri.parse(widget.url)).timeout(const Duration(seconds: 45));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final controller = PdfControllerPinch(document: PdfDocument.openData(res.bodyBytes));
      if (!mounted) return;
      setState(() => _controller = controller);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _openExternal() async {
    try {
      await launchUrl(Uri.parse(widget.url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF20262B),
      appBar: AppBar(
        title: Text(
          (widget.title ?? '').trim().isNotEmpty ? widget.title!.trim() : 'Документ',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        actions: [
          if (_pages > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text('$_page / $_pages', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.open_in_browser_rounded),
            tooltip: 'Открыть в браузере',
            onPressed: _openExternal,
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.picture_as_pdf_rounded, size: 48, color: Colors.white38),
                  const SizedBox(height: 14),
                  const Text('Не удалось показать документ',
                      style: TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(_error!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _openExternal,
                    icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                    label: const Text('Открыть в браузере'),
                  ),
                ]),
              ),
            )
          : _controller == null
              ? const Center(child: CircularProgressIndicator(color: Colors.white70))
              : PdfViewPinch(
                  controller: _controller!,
                  onDocumentLoaded: (doc) {
                    if (mounted) setState(() => _pages = doc.pagesCount);
                  },
                  onPageChanged: (page) {
                    if (mounted) setState(() => _page = page);
                  },
                ),
    );
  }
}
