import 'package:flutter_test/flutter_test.dart';
import 'package:viewfile/utils/watcher_lifecycle.dart';

void main() {
  test(
    'watcher lifecycle ids stay monotonic across equal and rollback clocks',
    () {
      final allocator = WatcherLifecycleIntentAllocator(initial: 99);
      expect(allocator.next(clockMicros: 100), 100);
      expect(allocator.next(clockMicros: 100), 101);
      expect(allocator.next(clockMicros: 50), 102);
      expect(allocator.next(clockMicros: 1000), 1000);
    },
  );
}
