import 'dart:math' as math;

/// Process-wide allocator used by every HomePage instance.
///
/// Wall clock makes ids survive widget recreation; last+1 keeps them strictly
/// monotonic when the clock repeats or moves backwards.
class WatcherLifecycleIntentAllocator {
  WatcherLifecycleIntentAllocator({int initial = 0}) : _last = initial;

  int _last;

  int next({int? clockMicros}) {
    final now = clockMicros ?? DateTime.now().microsecondsSinceEpoch;
    _last = math.max(now, _last + 1);
    return _last;
  }
}

final WatcherLifecycleIntentAllocator watcherLifecycleIntents =
    WatcherLifecycleIntentAllocator();
