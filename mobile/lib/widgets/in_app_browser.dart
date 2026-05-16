import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/config/app_colors.dart';

/// Opens a URL in an in-app WebView.
class InAppBrowser extends StatefulWidget {
  final String url;
  final String? title;

  const InAppBrowser({super.key, required this.url, this.title});

  /// Push an in-app browser onto the navigator.
  static void open(BuildContext context, String url, {String? title}) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => InAppBrowser(url: url, title: title),
      ),
    );
  }

  @override
  State<InAppBrowser> createState() => _InAppBrowserState();
}

class _InAppBrowserState extends State<InAppBrowser> {
  late final WebViewController _controller;
  String? _title;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _title = widget.title;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _isLoading = true),
          onPageFinished: (_) async {
            setState(() => _isLoading = false);
            if (_title == null) {
              final pageTitle = await _controller.getTitle();
              if (pageTitle != null && pageTitle.isNotEmpty && mounted) {
                setState(() => _title = pageTitle);
              }
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_title != null)
              Text(
                _title!,
                style: const TextStyle(fontSize: 15),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            Text(
              Uri.parse(widget.url).host,
              style: TextStyle(
                fontSize: 12,
                color: colors.textTertiary,
              ),
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isLoading)
            LinearProgressIndicator(
              color: colors.accent,
              backgroundColor: Colors.transparent,
            ),
        ],
      ),
    );
  }
}
