import 'dart:async';

class SetupRetryController {
  SetupRetryController({
    this.maxAttempts = 3,
    Duration Function(int attempt)? delayForAttempt,
  }) : _delayForAttempt = delayForAttempt ?? _defaultDelayForAttempt;

  final int maxAttempts;
  final Duration Function(int attempt) _delayForAttempt;
  Timer? _timer;
  int _attempts = 0;

  bool get canRetry => _attempts < maxAttempts;

  void reset() {
    _timer?.cancel();
    _attempts = 0;
  }

  void cancel() {
    _timer?.cancel();
  }

  void schedule({
    required void Function() onRetry,
    void Function()? onExhausted,
  }) {
    if (!canRetry) {
      onExhausted?.call();
      return;
    }

    _timer?.cancel();
    final retryDelay = _delayForAttempt(_attempts);
    _attempts += 1;
    _timer = Timer(retryDelay, onRetry);
  }

  static Duration _defaultDelayForAttempt(int attempt) {
    return Duration(seconds: 1 << attempt); // 1s, 2s, 4s
  }
}
