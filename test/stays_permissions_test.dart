import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/feature_flag_model.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/providers/feature_flag_provider.dart';
import 'package:sfcapp/providers/stays_providers.dart';
import 'package:sfcapp/services/permission_service.dart';

const _staysPermissions = {
  PermissionType.viewStays,
  PermissionType.manageStays,
  PermissionType.manageStayChannels,
  PermissionType.manageStayMoney,
  PermissionType.manageStaySettings,
  PermissionType.workStayTasks,
};

Set<PermissionType> _staysFor(RoleType type) =>
    PermissionService.getRoleByType(type)!.permissions.where((p) => p.isStaysPermission).toSet();

FeatureFlagModel _flag(bool enabled) => FeatureFlagModel(
      key: 'shortTermRentals',
      label: 'Stays',
      description: '',
      enabled: enabled,
      riskLevel: FlagRiskLevel.high,
    );

void main() {
  group('Stays permissions per role (spec §7.7)', () {
    test('owners and managers get all six', () {
      expect(_staysFor(RoleType.owner), _staysPermissions);
      expect(_staysFor(RoleType.manager), _staysPermissions);
    });

    test('employees view stays and work turnovers, and nothing else', () {
      expect(_staysFor(RoleType.employee), {PermissionType.viewStays, PermissionType.workStayTasks});
    });

    test('viewers only view', () {
      expect(_staysFor(RoleType.viewer), {PermissionType.viewStays});
    });

    test('no money, channel or settings permission for employees or viewers', () {
      for (final type in [RoleType.employee, RoleType.viewer]) {
        final permissions = PermissionService.getRoleByType(type)!.permissions;
        for (final p in [
          PermissionType.manageStays,
          PermissionType.manageStayChannels,
          PermissionType.manageStayMoney,
          PermissionType.manageStaySettings,
        ]) {
          expect(permissions, isNot(contains(p)), reason: '$type must not have $p');
        }
      }
    });

    test('each has a display name, and only these six are Stays permissions', () {
      for (final p in _staysPermissions) {
        expect(p.displayName, isNotEmpty);
      }
      expect(PermissionType.values.where((p) => p.isStaysPermission).toSet(), _staysPermissions);
    });
  });

  group('the shortTermRentals flag', () {
    test('ships off, so the Roles tab and every other screen look as before', () {
      final flag = kDefaultFeatureFlags.singleWhere((f) => f.key == staysFeatureFlagKey);
      expect(flag.enabled, isFalse);
    });

    ProviderContainer container(AsyncValue<List<FeatureFlagModel>> flags) {
      final c = ProviderContainer(overrides: [
        featureFlagsProvider.overrideWith((ref) {
          return switch (flags) {
            AsyncData(:final value) => Stream.value(value),
            AsyncError(:final error) => Stream.error(error),
            _ => const Stream.empty(),
          };
        }),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    Future<bool> allowedAfterLoad(ProviderContainer c) async {
      c.listen(featureFlagsProvider, (_, __) {});
      await Future<void>.delayed(Duration.zero);
      return c.read(staysUiAllowedProvider);
    }

    test('is off while the flags load: never fail-open like featureFlagEnabledProvider', () {
      final c = container(const AsyncLoading());
      c.listen(featureFlagsProvider, (_, __) {});
      expect(c.read(staysUiStateProvider), StaysUiState.loading);
      expect(c.read(staysUiAllowedProvider), isFalse);
      // The generic helper would have said "on" here.
      expect(c.read(featureFlagEnabledProvider(staysFeatureFlagKey)), isTrue);
    });

    test('is off when the flags fail to load, are missing, or say false', () async {
      expect(await allowedAfterLoad(container(AsyncError(StateError('offline'), StackTrace.empty))), isFalse);
      expect(await allowedAfterLoad(container(const AsyncData([]))), isFalse);
      expect(await allowedAfterLoad(container(AsyncData([_flag(false)]))), isFalse);
    });

    test('is on only once loaded and explicitly true', () async {
      expect(await allowedAfterLoad(container(AsyncData([_flag(true)]))), isTrue);
    });
  });

  group('stayPermissionProvider', () {
    ProviderContainer container(Future<bool> Function(String facilityId, PermissionType permission) resolve) {
      final c = ProviderContainer(overrides: [stayPermissionResolverProvider.overrideWithValue(resolve)]);
      addTearDown(c.dispose);
      return c;
    }

    test('checks the one facility it is given', () async {
      final asked = <String>[];
      final c = container((facilityId, permission) async {
        asked.add('$facilityId:${permission.name}');
        return facilityId == 'f1';
      });
      expect(await c.read(stayPermissionProvider(('f1', PermissionType.manageStayMoney)).future), isTrue);
      expect(await c.read(stayPermissionProvider(('f2', PermissionType.manageStayMoney)).future), isFalse);
      expect(asked, ['f1:manageStayMoney', 'f2:manageStayMoney']);
    });

    test('no facility, or "all", is a no without asking', () async {
      var asked = false;
      final c = container((_, __) async {
        asked = true;
        return true;
      });
      expect(await c.read(stayPermissionProvider(('', PermissionType.viewStays)).future), isFalse);
      expect(await c.read(stayPermissionProvider(('all', PermissionType.viewStays)).future), isFalse);
      expect(asked, isFalse);
    });

    test('a failed check is a no', () async {
      final c = container((_, __) async => throw StateError('offline'));
      expect(await c.read(stayPermissionProvider(('f1', PermissionType.viewStays)).future), isFalse);
    });
  });
}
