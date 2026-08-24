import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// 内置视频/音频播放器：ExoPlayer(media3) 解码，播不了可回退系统播放器
class MediaViewerPage extends StatefulWidget {
  const MediaViewerPage({super.key, required this.path, this.onExternal});

  final String path;
  /// 返回 'external' 表示需要调用方回退系统打开
  final void Function()? onExternal;

  @override
  State<MediaViewerPage> createState() => _MediaViewerPageState();
}

class _MediaViewerPageState extends State<MediaViewerPage> {
  VideoPlayerController? _ctl;
  bool _initialized = false;
  String? _error;
  bool _showControls = true;

  String get _name => widget.path.substring(widget.path.lastIndexOf('/') + 1);
  bool get _isAudio {
    final ext = _name.contains('.')
        ? _name.substring(_name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    return ['mp3', 'flac', 'wav', 'ogg', 'm4a', 'aac', 'opus', 'amr', 'wma']
        .contains(ext);
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final ctl = VideoPlayerController.file(File(widget.path));
    try {
      await ctl.initialize();
      if (!mounted) {
        await ctl.dispose();
        return;
      }
      setState(() => _initialized = true);
      _ctl = ctl;
      await ctl.play();
      ctl.addListener(_onTick);
    } catch (_) {
      await ctl.dispose();
      if (mounted) setState(() => _error = '无法播放（解码失败或无读取权限）');
    }
  }

  void _onTick() {
    if (!mounted) return;
    // 控制条进度需要跟随播放位置刷新
    setState(() {});
  }

  @override
  void dispose() {
    _ctl?.removeListener(_onTick);
    _ctl?.dispose();
    super.dispose();
  }

  void _toggle() {
    final c = _ctl;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
    setState(() {});
  }

  void _seek(double v) {
    final c = _ctl;
    if (c == null || !c.value.isInitialized) return;
    c.seekTo(Duration(milliseconds: (v * c.value.duration.inMilliseconds).round()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = _ctl;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        title: Text(_name,
            style: const TextStyle(fontSize: 15),
            overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '用其他应用打开',
            icon: const Icon(Icons.open_in_new),
            onPressed: () {
              widget.onExternal?.call();
              Navigator.pop(context, 'external');
            },
          ),
        ],
      ),
      body: GestureDetector(
        onTap: () => setState(() => _showControls = !_showControls),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_error != null)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, color: Colors.white38, size: 56),
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: const TextStyle(color: Colors.white54, fontSize: 13)),
                ],
              )
            else if (!_initialized)
              const CircularProgressIndicator()
            else if (_isAudio)
              const Icon(Icons.music_note, color: Colors.white24, size: 120)
            else
              Center(child: VideoPlayer(c!)),
            // 控制层
            if (_initialized && _showControls)
              Align(
                alignment: Alignment.bottomCenter,
                child: _buildControls(theme, c!),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls(ThemeData theme, VideoPlayerController c) {
    final pos = c.value.position;
    final dur = c.value.duration;
    return Material(
      color: Colors.black54,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const SizedBox(width: 16),
                Text(_fmtDur(pos), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                Expanded(
                  child: Slider(
                    value: dur.inMilliseconds > 0
                        ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                        : 0,
                    onChanged: _seek,
                  ),
                ),
                Text(_fmtDur(dur), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                IconButton(
                  icon: Icon(
                    c.value.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 32,
                  ),
                  onPressed: _toggle,
                ),
                const SizedBox(width: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtDur(Duration d) {
    var s = d.inSeconds;
    final h = s ~/ 3600;
    s %= 3600;
    final m = s ~/ 60;
    s %= 60;
    return h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}
