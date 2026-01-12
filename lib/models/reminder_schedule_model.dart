import 'package:cloud_firestore/cloud_firestore.dart';

import 'reminder_model.dart';

class ReminderScheduleModel {
  final String id;
  final String facilityId;
  final String name;
  final ReminderType type;
  final List<ReminderChannel> channels;
  final ReminderSendMode sendMode;
  final int offsetDays;
  final String sendTime; // HH:mm
  final bool autoSend;
  final bool isActive;
  final String titleTemplate;
  final String messageTemplate;
  final String? lastRunDate; // yyyy-MM-dd
  final DateTime? lastRunAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String createdBy;

  const ReminderScheduleModel({
    required this.id,
    required this.facilityId,
    required this.name,
    required this.type,
    required this.channels,
    required this.sendMode,
    required this.offsetDays,
    required this.sendTime,
    required this.autoSend,
    required this.isActive,
    required this.titleTemplate,
    required this.messageTemplate,
    this.lastRunDate,
    this.lastRunAt,
    required this.createdAt,
    required this.updatedAt,
    required this.createdBy,
  });

  factory ReminderScheduleModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ReminderScheduleModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      name: data['name'] ?? 'Reminder Schedule',
      type: ReminderType.values.firstWhere(
        (value) => value.name == data['type'],
        orElse: () => ReminderType.custom,
      ),
      channels: (data['channels'] as List<dynamic>? ?? [])
          .map(
            (value) => ReminderChannel.values.firstWhere(
              (channel) => channel.name == value,
              orElse: () => ReminderChannel.email,
            ),
          )
          .toList(),
      sendMode: ReminderSendMode.values.firstWhere(
        (value) => value.name == data['sendMode'],
        orElse: () => ReminderSendMode.immediate,
      ),
      offsetDays: (data['offsetDays'] ?? 0) as int,
      sendTime: data['sendTime'] ?? '09:00',
      autoSend: data['autoSend'] ?? true,
      isActive: data['isActive'] ?? true,
      titleTemplate: data['titleTemplate'] ?? 'Reminder Notification',
      messageTemplate: data['messageTemplate'] ?? 'Hello {{tenantName}}, this is a reminder from {{facilityName}}.',
      lastRunDate: data['lastRunDate'] as String?,
      lastRunAt: (data['lastRunAt'] as Timestamp?)?.toDate(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      createdBy: data['createdBy'] ?? '',
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'name': name,
      'type': type.name,
      'channels': channels.map((e) => e.name).toList(),
      'sendMode': sendMode.name,
      'offsetDays': offsetDays,
      'sendTime': sendTime,
      'autoSend': autoSend,
      'isActive': isActive,
      'titleTemplate': titleTemplate,
      'messageTemplate': messageTemplate,
      'lastRunDate': lastRunDate,
      'lastRunAt': lastRunAt != null ? Timestamp.fromDate(lastRunAt!) : null,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'createdBy': createdBy,
    };
  }

  ReminderScheduleModel copyWith({
    String? id,
    String? facilityId,
    String? name,
    ReminderType? type,
    List<ReminderChannel>? channels,
    ReminderSendMode? sendMode,
    int? offsetDays,
    String? sendTime,
    bool? autoSend,
    bool? isActive,
    String? titleTemplate,
    String? messageTemplate,
    String? lastRunDate,
    DateTime? lastRunAt,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
  }) {
    return ReminderScheduleModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      name: name ?? this.name,
      type: type ?? this.type,
      channels: channels ?? this.channels,
      sendMode: sendMode ?? this.sendMode,
      offsetDays: offsetDays ?? this.offsetDays,
      sendTime: sendTime ?? this.sendTime,
      autoSend: autoSend ?? this.autoSend,
      isActive: isActive ?? this.isActive,
      titleTemplate: titleTemplate ?? this.titleTemplate,
      messageTemplate: messageTemplate ?? this.messageTemplate,
      lastRunDate: lastRunDate ?? this.lastRunDate,
      lastRunAt: lastRunAt ?? this.lastRunAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
    );
  }

  int get sendTimeMinutes {
    final parts = sendTime.split(':');
    if (parts.length != 2) return 9 * 60;
    final hour = int.tryParse(parts[0]) ?? 9;
    final minute = int.tryParse(parts[1]) ?? 0;
    return hour.clamp(0, 23) * 60 + minute.clamp(0, 59);
  }

  bool shouldRun(DateTime now) {
    if (!isActive) return false;
    final today = _formatDate(now);
    if (lastRunDate == today) return false;
    final minutesNow = now.hour * 60 + now.minute;
    return minutesNow >= sendTimeMinutes;
  }

  static String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}

