import 'package:flutter_test/flutter_test.dart';

import 'package:viewfile/utils/format.dart';
import 'package:viewfile/utils/index_bootstrap.dart';

void main() {
  test('fmtSize 基本换算', () {
    expect(fmtSize(0), '0 B');
    expect(fmtSize(2048), '2.0 KB');
    expect(fmtSize(5 * 1024 * 1024), '5.0 MB');
  });

  test('fmtDate 毫秒时间戳格式化', () {
    // 2026-08-20 15:59:30 本地时区下的毫秒值由自身反推，保证一致性
    final d = DateTime(2026, 8, 20, 15, 59, 30);
    expect(fmtDate(d.millisecondsSinceEpoch), startsWith('2026-08-20 15:59'));
    expect(fmtDate(0), '—');
  });

  test('describe 按扩展名分类', () {
    expect(describe('a.jpg', false).$1, '图片');
    expect(describe('app.apk', false).$1, '安装包');
    expect(describe('x', true).$1, '文件夹');
    expect(describe('unknown.zzz', false).$1, '文件');
  });

  test('索引载入结果区分普通空库与内存保护重置', () {
    expect(classifyIndexLoad(-1), IndexLoadDisposition.rebuildCompact);
    expect(classifyIndexLoad(0), IndexLoadDisposition.rebuildConfigured);
    expect(classifyIndexLoad(42), IndexLoadDisposition.ready);
  });
}
