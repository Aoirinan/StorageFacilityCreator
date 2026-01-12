import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';

class HomeButtonService {
  HomeButtonService._();

  static final HomeButtonService instance = HomeButtonService._();

  final ValueNotifier<bool> _visibleNotifier = ValueNotifier<bool>(true);
  int _hideCount = 0;

  ValueListenable<bool> get visibilityListenable => _visibleNotifier;

  void show() {
    if (_hideCount > 0) {
      _hideCount -= 1;
    }
    _updateVisibility();
  }

  void hide() {
    _hideCount += 1;
    _updateVisibility();
  }

  void _updateVisibility() {
    final shouldShow = _hideCount <= 0;
    if (_visibleNotifier.value == shouldShow) return;

    final binding = WidgetsBinding.instance;
    // If the widget tree is locked (e.g., during unmount), defer the update
    // to the next frame to avoid setState during build/unmount.
    if (binding.schedulerPhase == SchedulerPhase.idle ||
        binding.schedulerPhase == SchedulerPhase.postFrameCallbacks) {
      _visibleNotifier.value = shouldShow;
    } else {
      binding.addPostFrameCallback((_) {
        if (_visibleNotifier.value != shouldShow) {
          _visibleNotifier.value = shouldShow;
        }
      });
    }
  }
}

