import 'dart:convert' show base64Decode, utf8;
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:charset_converter/charset_converter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/engine_api.dart';

/// 文本预览：等宽字体逐行渲染，支持文内搜索（高亮 + 上/下一个跳转）
class TextPreviewPage extends StatefulWidget {
  const TextPreviewPage({super.key, required this.path});

  /// 真实路径（压缩包内文件请先解压再传解压后的路径）
  final String path;

  @override
  State<TextPreviewPage> createState() => _TextPreviewPageState();
}

class _TextPreviewPageState extends State<TextPreviewPage> {
  final _api = EngineApi();
  String _text = '';
  bool _loading = true;
  String? _error;
  bool _truncated = false;
  bool _binary = false;

  List<String> _lines = const [];

  // 文内搜索
  bool _searchMode = false;
  final _searchCtl = TextEditingController();
  final _scrollCtl = ScrollController();
  List<(int, int, int)> _matches = const []; // (line, start, end)
  int _currentMatch = -1;

  static const _mono = TextStyle(fontSize: 12.5, height: 1.35);

  String get _name => widget.path.substring(widget.path.lastIndexOf('/') + 1);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  static const _maxBytes = 4 << 20;

  Future<void> _load() async {
    // 读取原始字节（本地直读优先，失败走引擎 root 通道），编码检测与解码统一在本端
    Uint8List? raw;
    var truncated = false;
    try {
      final f = io.File(widget.path);
      if (await f.exists()) {
        final raf = await f.open();
        try {
          final len = await raf.length();
          final n = len > _maxBytes ? _maxBytes : len;
          raw = await raf.read(n);
          truncated = len > n;
        } finally {
          await raf.close();
        }
      }
    } catch (_) {
      raw = null;
    }
    raw ??= await _readViaEngine();
    if (!mounted) return;
    if (raw == null) {
      setState(() {
        _loading = false;
        _error = '无法读取文件（无权限或文件不存在）';
      });
      return;
    }
    _raw = raw;
    _truncatedRaw = truncated;
    // 自动检测：严格 UTF-8 → GBK → Big5，失败则容错 UTF-8
    _enc = await _detectEnc(raw);
    await _applyEnc(_enc);
  }

  Uint8List? _raw;
  bool _truncatedRaw = false;
  String _enc = 'UTF-8';

  static const _encList = ['UTF-8', 'GBK', 'Big5', 'UTF-16LE', 'Shift_JIS'];

  Future<String> _detectEnc(Uint8List raw) async {
    try {
      utf8.decode(raw, allowMalformed: false);
      return 'UTF-8';
    } catch (_) {}
    for (final enc in const ['GBK', 'Big5']) {
      try {
        final s = await CharsetConverter.decode(enc, raw);
        if (!s.contains('�')) return enc;
      } catch (_) {}
    }
    return 'UTF-8'; // 容错解码（乱码可手切）
  }

  /// 用指定编码解码并刷新视图（预览即所见）
  Future<void> _applyEnc(String enc) async {
    final raw = _raw;
    if (raw == null) return;
    String text;
    if (enc == 'UTF-8') {
      text = utf8.decode(raw, allowMalformed: true);
    } else {
      try {
        text = await CharsetConverter.decode(enc, raw);
      } catch (_) {
        if (mounted) {
          setState(() => _error = '以 $enc 解码失败');
        }
        return;
      }
    }
    if (!mounted) return;
    final probe = text.length > 8192 ? text.substring(0, 8192) : text;
    final binary = probe.contains('\u0000');
    setState(() {
      _loading = false;
      _error = null;
      _enc = enc;
      _binary = binary;
      _truncated = _truncatedRaw && !binary;
      _text = binary ? '' : text;
      _lines = binary ? const [] : _splitLines(text);
      _matches = const [];
      _currentMatch = -1;
      if (!binary) {
        var longest = '';
        for (final l in _lines) {
          if (l.length > longest.length) longest = l;
        }
        final tp = TextPainter(
          text: TextSpan(text: longest, style: _mono),
          textDirection: TextDirection.ltr,
        )..layout();
        _maxLineWidth = tp.width;
      }
    });
  }

  Future<Uint8List?> _readViaEngine() async {
    try {
      final r = await _api.readText(widget.path);
      if (r['ok'] == true && r['b64'] is String) {
        return base64Decode(r['b64'] as String);
      }
    } catch (_) {}
    return null;
  }

  static List<String> _splitLines(String text) {
    final lines = <String>[];
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        var end = i;
        if (end > start && text.codeUnitAt(end - 1) == 0x0D) end--;
        lines.add(text.substring(start, end));
        start = i + 1;
      }
    }
    lines.add(text.substring(start));
    return lines;
  }

  void _runSearch(String q) {
    setState(() {
      _matches = const [];
      _currentMatch = -1;
      if (q.isEmpty) return;
      final needle = q.toLowerCase();
      final found = <(int, int, int)>[];
      for (var li = 0; li < _lines.length && found.length < 5000; li++) {
        final l = _lines[li].toLowerCase();
        var from = 0;
        while (true) {
          final i = l.indexOf(needle, from);
          if (i < 0) break;
          found.add((li, i, i + q.length));
          from = i + q.length;
        }
      }
      _matches = found;
      if (_matches.isNotEmpty) _currentMatch = 0;
    });
    _scrollToCurrent();
  }

  void _jumpMatch(int delta) {
    if (_matches.isEmpty) return;
    setState(() {
      _currentMatch =
          (_currentMatch + delta + _matches.length) % _matches.length;
    });
    _scrollToCurrent();
  }

  void _scrollToCurrent() {
    if (_currentMatch < 0 || _currentMatch >= _matches.length) return;
    final ctx = _matchKeys[_matches[_currentMatch].$1]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, alignment: 0.3, duration: const Duration(milliseconds: 200));
    }
  }

  // 行号 → GlobalKey（只给含匹配的行挂 key）
  final _matchKeys = <int, GlobalKey>{};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_name, overflow: TextOverflow.ellipsis),
        actions: [
          // 编码切换（所见即所得预览）
          PopupMenuButton<String>(
            tooltip: '文本编码',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Center(
                child: Text(
                  _enc,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
            onSelected: (enc) {
              if (enc == 'AUTO') {
                if (_raw != null) {
                  _detectEnc(_raw!).then(_applyEnc);
                }
              } else {
                _applyEnc(enc);
              }
            },
            itemBuilder: (_) => [
              for (final e in _encList)
                PopupMenuItem(
                  value: e,
                  child: Row(
                    children: [
                      if (e == _enc)
                        const Icon(Icons.check, size: 16)
                      else
                        const SizedBox(width: 16),
                      const SizedBox(width: 8),
                      Text(e),
                    ],
                  ),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'AUTO',
                child: Row(
                  children: [
                    SizedBox(width: 16),
                    SizedBox(width: 8),
                    Text('重新自动检测'),
                  ],
                ),
              ),
            ],
          ),
          IconButton(
            tooltip: '文内搜索',
            icon: const Icon(Icons.search),
            onPressed: () {
              setState(() => _searchMode = !_searchMode);
              if (_searchMode) _runSearch(_searchCtl.text);
            },
          ),
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_all),
            onPressed: _text.isEmpty
                ? null
                : () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await Clipboard.setData(ClipboardData(text: _text));
                    messenger.showSnackBar(const SnackBar(
                      content: Text('已复制全部文本'),
                      duration: Duration(seconds: 1),
                    ));
                  },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_searchMode) _buildSearchBar(theme),
          if (_truncated)
            Material(
              color: theme.colorScheme.errorContainer,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: SizedBox(
                  width: double.infinity,
                  child: Text('文件较大，仅加载前 4 MB', style: TextStyle(fontSize: 12)),
                ),
              ),
            ),
          Expanded(child: _buildBody(theme)),
        ],
      ),
    );
  }

  Widget _buildSearchBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtl,
              autofocus: true,
              onChanged: (q) => _runSearch(q),
              decoration: const InputDecoration(
                hintText: '在文件内搜索…',
                prefixIcon: Icon(Icons.find_in_page),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _matches.isEmpty
                ? '0'
                : '${_currentMatch + 1}/${_matches.length}',
            style: theme.textTheme.bodySmall,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up),
            onPressed: _matches.isEmpty ? null : () => _jumpMatch(-1),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down),
            onPressed: _matches.isEmpty ? null : () => _jumpMatch(1),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Text(_error!, style: theme.textTheme.bodySmall));
    }
    if (_binary) {
      return Center(
        child: Text('二进制文件，不支持文本预览',
            style: theme.textTheme.bodySmall),
      );
    }
    _matchKeys.clear();
    final matchLines = <int>{for (final m in _matches) m.$1};

    // 整文档联动的横向滑动：外层横向滚动（宽度=最长行）包住纵向列表。
    // 之前 Transform 平移方案超出视口的字形不参与布局，划过去是空白。
    final contentW =
        math.max(MediaQuery.sizeOf(context).width, _maxLineWidth + 24);

    return SelectionArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: contentW,
            height: constraints.maxHeight,
            child: ListView.builder(
              controller: _scrollCtl,
              itemCount: _lines.length,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemBuilder: (context, i) {
                if (matchLines.contains(i)) {
                  final key = _matchKeys.putIfAbsent(i, () => GlobalKey());
                  final ms = [
                    for (final m in _matches)
                      if (m.$1 == i) m,
                  ];
                  final spans = <InlineSpan>[];
                  var pos = 0;
                  for (final (li, s, e) in ms) {
                    if (s > pos) {
                      spans.add(TextSpan(text: _lines[i].substring(pos, s)));
                    }
                    final isCurrent = _matches[_currentMatch] == (li, s, e);
                    spans.add(TextSpan(
                      text: _lines[i].substring(s, e),
                      style: TextStyle(
                        backgroundColor: isCurrent
                            ? theme.colorScheme.primary.withValues(alpha: 0.55)
                            : theme.colorScheme.tertiaryContainer,
                      ),
                    ));
                    pos = e;
                  }
                  if (pos < _lines[i].length) {
                    spans.add(TextSpan(text: _lines[i].substring(pos)));
                  }
                  return _lineWidget(i, spans, key: key);
                }
                return _lineWidget(i, null);
              },
            ),
          ),
        ),
      ),
    );
  }

  double _maxLineWidth = 0;

  Widget _lineWidget(int i, List<InlineSpan>? spans, {Key? key}) {
    final line = _lines[i].isEmpty ? ' ' : _lines[i];
    final text = spans == null
        ? Text(line, style: _mono, softWrap: false)
        : Text.rich(TextSpan(style: _mono, children: spans), softWrap: false);
    return SizedBox(
      key: key,
      height: 18,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: text,
      ),
    );
  }
}
