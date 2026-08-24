import 'dart:io';

import 'package:flutter/material.dart';

/// 基础图片查看器：左右滑动切换、双指/双击缩放、点按隐藏界面
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.paths,
    this.initialIndex = 0,
  });

  final List<String> paths;
  final int initialIndex;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _ctl;
  late int _index;
  bool _chrome = true;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.paths.length - 1);
    _ctl = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  String _name(int i) =>
      widget.paths[i].substring(widget.paths[i].lastIndexOf('/') + 1);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _ctl,
            itemCount: widget.paths.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => _ZoomableImage(file: File(widget.paths[i])),
          ),
          // 顶栏（文件名 + 序号）
          AnimatedOpacity(
            opacity: _chrome ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: IgnorePointer(
              ignoring: !_chrome,
              child: Align(
                alignment: Alignment.topCenter,
                child: Material(
                  color: Colors.black54,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white),
                            onPressed: () => Navigator.pop(context),
                          ),
                          Expanded(
                            child: Text(
                              _name(_index),
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 15),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '${_index + 1} / ${widget.paths.length}',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单张图：双指缩放 + 双击在 1x/3x 间切换（以双击点为中心）
class _ZoomableImage extends StatefulWidget {
  const _ZoomableImage({required this.file});

  final File file;

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage> {
  final _trans = TransformationController();
  TapDownDetails? _doubleTapDetails;

  @override
  void dispose() {
    _trans.dispose();
    super.dispose();
  }

  void _onDoubleTap() {
    final pos = _doubleTapDetails?.localPosition ?? Offset.zero;
    if (_trans.value.isIdentity()) {
      const scale = 3.0;
      final m = Matrix4.identity();
      m.setEntry(0, 0, scale);
      m.setEntry(1, 1, scale);
      m.setEntry(0, 3, -pos.dx * (scale - 1));
      m.setEntry(1, 3, -pos.dy * (scale - 1));
      _trans.value = m;
    } else {
      _trans.value = Matrix4.identity();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: (d) => _doubleTapDetails = d,
      onDoubleTap: _onDoubleTap,
      onTap: () {
        // 通知外层切换工具栏显示
        final page = context.findAncestorStateOfType<_ImageViewerPageState>();
        page?.setState(() => page._chrome = !page._chrome);
      },
      child: InteractiveViewer(
        transformationController: _trans,
        maxScale: 12,
        minScale: 1,
        child: Center(
          child: Image.file(
            widget.file,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.broken_image, color: Colors.white38, size: 56),
                SizedBox(height: 8),
                Text('无法解码（可能无读取权限或格式不支持）',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
              ],
            ),
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
                // frame != null 表示已完成解码（异步加载完成也会走到这）
                (wasSynchronouslyLoaded || frame != null)
                    ? child
                    : const Center(child: CircularProgressIndicator()),
          ),
        ),
      ),
    );
  }
}
