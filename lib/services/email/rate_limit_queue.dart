import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'email_provider.dart';

/// Rate-limited email queue for managing send limits
class RateLimitQueue {
  final EmailProvider _emailProvider;
  final int _maxEmailsPerMinute;
  
  final Queue<EmailMessage> _queue = Queue<EmailMessage>();
  final Queue<DateTime> _sendTimes = Queue<DateTime>();
  Timer? _processTimer;
  bool _isProcessing = false;

  RateLimitQueue({
    required EmailProvider emailProvider,
    required int maxEmailsPerMinute,
  }) : _emailProvider = emailProvider,
       _maxEmailsPerMinute = maxEmailsPerMinute {
    _startProcessing();
  }

  /// Enqueue an email message for sending
  Future<void> enqueue(EmailMessage message) async {
    _queue.add(message);
    
    if (kDebugMode) {
      print('📧 [RateLimit] Enqueued email to ${message.to}. Queue size: ${_queue.length}');
    }
    
    // Trigger immediate processing if not already running
    if (!_isProcessing) {
      _processQueue();
    }
  }

  /// Enqueue multiple emails
  Future<void> enqueueBulk(List<EmailMessage> messages) async {
    for (final message in messages) {
      _queue.add(message);
    }
    
    if (kDebugMode) {
      print('📧 [RateLimit] Enqueued ${messages.length} emails. Queue size: ${_queue.length}');
    }
    
    if (!_isProcessing) {
      _processQueue();
    }
  }

  /// Get current queue size
  int get queueSize => _queue.length;

  /// Get current rate limit status
  RateLimitStatus get status {
    final now = DateTime.now();
    final recentSends = _sendTimes.where(
      (time) => now.difference(time).inMinutes < 1,
    ).length;
    
    return RateLimitStatus(
      emailsInLastMinute: recentSends,
      maxPerMinute: _maxEmailsPerMinute,
      queueSize: _queue.length,
      canSendNow: recentSends < _maxEmailsPerMinute,
    );
  }

  void _startProcessing() {
    _processTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _processQueue();
    });
  }

  Future<void> _processQueue() async {
    if (_isProcessing || _queue.isEmpty) return;
    
    _isProcessing = true;
    
    try {
      await _processBatch();
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _processBatch() async {
    final now = DateTime.now();
    
    // Clean old send times (older than 1 minute)
    while (_sendTimes.isNotEmpty && 
           now.difference(_sendTimes.first).inMinutes >= 1) {
      _sendTimes.removeFirst();
    }
    
    // Calculate how many emails we can send now
    final recentSends = _sendTimes.length;
    final availableSlots = _maxEmailsPerMinute - recentSends;
    
    if (availableSlots <= 0) {
      if (kDebugMode) {
        print('📧 [RateLimit] Rate limit reached. Waiting...');
      }
      return;
    }
    
    // Process up to available slots
    final batchSize = availableSlots.clamp(1, _queue.length);
    final batch = <EmailMessage>[];
    
    for (int i = 0; i < batchSize && _queue.isNotEmpty; i++) {
      batch.add(_queue.removeFirst());
    }
    
    if (batch.isEmpty) return;
    
    if (kDebugMode) {
      print('📧 [RateLimit] Processing batch of ${batch.length} emails');
    }
    
    try {
      final result = await _emailProvider.sendBulk(messages: batch);
      
      // Record send times for rate limiting
      final sendTime = DateTime.now();
      for (int i = 0; i < result.totalSent; i++) {
        _sendTimes.add(sendTime);
      }
      
      if (kDebugMode) {
        print('📧 [RateLimit] Batch completed: ${result.totalSent} sent, ${result.totalFailed} failed');
        
        if (result.errors.isNotEmpty) {
          for (final error in result.errors) {
            print('❌ [RateLimit] Send error: ${error.recipient} - ${error.error}');
          }
        }
      }
      
    } catch (e) {
      if (kDebugMode) {
        print('❌ [RateLimit] Batch failed: $e');
      }
      
      // Re-queue failed messages with exponential backoff
      await _requeueWithBackoff(batch, e.toString());
    }
  }

  Future<void> _requeueWithBackoff(List<EmailMessage> messages, String error) async {
    // Simple retry logic - in production, you might want more sophisticated backoff
    await Future.delayed(const Duration(minutes: 1));
    
    if (kDebugMode) {
      print('📧 [RateLimit] Re-queuing ${messages.length} failed messages');
    }
    
    for (final message in messages) {
      _queue.add(message);
    }
  }

  /// Stop the rate limiter and clear the queue
  void dispose() {
    _processTimer?.cancel();
    _queue.clear();
    _sendTimes.clear();
  }
}

/// Status information about rate limiting
class RateLimitStatus {
  final int emailsInLastMinute;
  final int maxPerMinute;
  final int queueSize;
  final bool canSendNow;

  const RateLimitStatus({
    required this.emailsInLastMinute,
    required this.maxPerMinute,
    required this.queueSize,
    required this.canSendNow,
  });

  double get usagePercentage => maxPerMinute > 0 ? emailsInLastMinute / maxPerMinute : 0.0;
  
  bool get isNearLimit => usagePercentage >= 0.8;
  
  Duration? get estimatedWaitTime {
    if (canSendNow) return null;
    
    // Estimate based on current usage
    final remainingSlots = maxPerMinute - emailsInLastMinute;
    if (remainingSlots <= 0) {
      // Assume we need to wait for the oldest send to expire
      return const Duration(minutes: 1);
    }
    
    return null;
  }
}
