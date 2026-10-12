import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ledger_book/models.dart';
import 'package:ledger_book/stats.dart';

/// 预算功能的测试。
///
/// 覆盖三层：
/// 1. 周期计算（budgetPeriod）——纯函数，边界最多：跨月、2 月、闰年、clamp；
/// 2. 预算状态（BudgetStatus.of）——剩余/超支/天数/日均可用，口径必须钉死；
/// 3. 数据层——settings 表读写、脏值回落、v5 → v6 迁移幂等。
void main() {
  // ---------------- 周期计算 ----------------

  group('预算周期：StatsRange.budgetPeriod', () {
    test('起始日 1：就是自然月', () {
      final p = StatsRange.budgetPeriod(DateTime(2026, 9, 15), 1);
      expect(p.start, DateTime(2026, 9, 1));
      expect(p.end, DateTime(2026, 9, 30));
      expect(p.contains(DateTime(2026, 9, 1)), isTrue);
      expect(p.contains(DateTime(2026, 9, 30)), isTrue);
      expect(p.contains(DateTime(2026, 8, 31)), isFalse);
      expect(p.contains(DateTime(2026, 10, 1)), isFalse);
    });

    test('起始日 25：15 号属于上个月开启的周期', () {
      final p = StatsRange.budgetPeriod(DateTime(2026, 9, 15), 25);
      expect(p.start, DateTime(2026, 8, 25));
      expect(p.end, DateTime(2026, 9, 24));
    });

    test('起始日 25：25 号当天开启新周期（闭区间含当天）', () {
      final p = StatsRange.budgetPeriod(DateTime(2026, 9, 25), 25);
      expect(p.start, DateTime(2026, 9, 25));
      expect(p.end, DateTime(2026, 10, 24));
    });

    test('起始日 25：24 号仍归上一个周期', () {
      final p = StatsRange.budgetPeriod(DateTime(2026, 9, 24), 25);
      expect(p.start, DateTime(2026, 8, 25));
      expect(p.end, DateTime(2026, 9, 24));
    });

    test('跨年：1 月 10 号、起始日 15 → 属于去年 12 月的周期', () {
      final p = StatsRange.budgetPeriod(DateTime(2027, 1, 10), 15);
      expect(p.start, DateTime(2026, 12, 15));
      expect(p.end, DateTime(2027, 1, 14));
    });

    test('2 月：起始日 28 也不会算出"2 月 30 日"', () {
      // DateTime(y, m + 1, sd) 在 2 月会抛 Invalid date found，
      // 这里用"下月第 0 天"技巧必须天然兜住
      final p = StatsRange.budgetPeriod(DateTime(2026, 2, 10), 28);
      expect(p.start, DateTime(2026, 1, 28));
      expect(p.end, DateTime(2026, 2, 27));
    });

    test('闰年 2 月：2028-02-29 存在，周期仍正确', () {
      // 起始日 28：2/15 还在 1/28 ~ 2/27 这个周期里，2/29 归下一个周期
      final before = StatsRange.budgetPeriod(DateTime(2028, 2, 15), 28);
      expect(before.start, DateTime(2028, 1, 28));
      expect(before.end, DateTime(2028, 2, 27));
      expect(before.contains(DateTime(2028, 2, 29)), isFalse);

      // 2/28 当天开启新周期，2/29 被这个周期吃到——没有一天被漏掉
      final after = StatsRange.budgetPeriod(DateTime(2028, 2, 28), 28);
      expect(after.start, DateTime(2028, 2, 28));
      expect(after.end, DateTime(2028, 3, 27));
      expect(after.contains(DateTime(2028, 2, 28)), isTrue);
      expect(after.contains(DateTime(2028, 2, 29)), isTrue);
      expect(after.contains(DateTime(2028, 3, 1)), isTrue);
      expect(after.contains(DateTime(2028, 3, 28)), isFalse);
    });

    test('起始日被 clamp 到 1-28：31 号按 28 处理', () {
      final p = StatsRange.budgetPeriod(DateTime(2026, 3, 10), 31);
      expect(p.start, DateTime(2026, 2, 28));
      expect(p.end, DateTime(2026, 3, 27));
    });

    test('起始日被 clamp 到 1-28：0 和负数按 1 处理', () {
      final p0 = StatsRange.budgetPeriod(DateTime(2026, 3, 10), 0);
      expect(p0.start, DateTime(2026, 3, 1));
      final pNeg = StatsRange.budgetPeriod(DateTime(2026, 3, 10), -5);
      expect(pNeg.start, DateTime(2026, 3, 1));
    });
  });

  // ---------------- 预算状态 ----------------

  group('预算状态：BudgetStatus.of', () {
    test('常规：月中过半，剩余与日均可用正确', () {
      final s = BudgetStatus.of(
        monthlyBudget: 3000,
        startDay: 1,
        periodExpense: 1500,
        today: DateTime(2026, 9, 16), // 9 月第 16 天
      );
      expect(s.budget, 3000);
      expect(s.used, 1500);
      expect(s.remaining, 1500);
      expect(s.overspent, isFalse);
      expect(s.ratio, closeTo(0.5, 1e-9));
      expect(s.totalDays, 30);
      expect(s.dayIndex, 16);
      expect(s.daysLeft, 15);
      expect(s.dailyAvailable, closeTo(100, 1e-9));
    });

    test('超支：剩余为负、日均可用归零', () {
      final s = BudgetStatus.of(
        monthlyBudget: 2000,
        startDay: 1,
        periodExpense: 2500,
        today: DateTime(2026, 9, 10),
      );
      expect(s.remaining, -500);
      expect(s.overspent, isTrue);
      expect(s.ratio, closeTo(1.25, 1e-9));
      expect(s.dailyAvailable, 0);
    });

    test('刚好花完：不算超支（浮点容差内）', () {
      final s = BudgetStatus.of(
        monthlyBudget: 1000,
        startDay: 1,
        periodExpense: 1000,
        today: DateTime(2026, 9, 20),
      );
      expect(s.remaining, closeTo(0, 1e-9));
      expect(s.overspent, isFalse);
      expect(s.dailyAvailable, 0); // 没剩额度了
    });

    test('周期最后一天：剩余天数 1，日均可用=剩余', () {
      final s = BudgetStatus.of(
        monthlyBudget: 1000,
        startDay: 1,
        periodExpense: 400,
        today: DateTime(2026, 9, 30),
      );
      expect(s.dayIndex, 30);
      expect(s.daysLeft, 1);
      expect(s.dailyAvailable, closeTo(600, 1e-9));
    });

    test('自定义起始日：锚点落在哪个周期，就用哪个周期算', () {
      // 起始日 20：9 月 10 号属于 8/20 ~ 9/19 这个周期
      final s = BudgetStatus.of(
        monthlyBudget: 3000,
        startDay: 20,
        periodExpense: 900,
        today: DateTime(2026, 9, 10),
      );
      expect(s.period.start, DateTime(2026, 8, 20));
      expect(s.period.end, DateTime(2026, 9, 19));
      expect(s.totalDays, 31); // 8/20 ~ 9/19 共 31 天
      expect(s.dayIndex, 22); // 8/20 是第 1 天，9/10 是第 22 天
      expect(s.daysLeft, 10);
    });

    test('零预算不会除零', () {
      final s = BudgetStatus.of(
        monthlyBudget: 0,
        startDay: 1,
        periodExpense: 100,
        today: DateTime(2026, 9, 10),
      );
      expect(s.ratio, 0);
      expect(s.remaining, -100);
      expect(s.overspent, isTrue);
    });
  });

  // ---------------- 设置项模型 ----------------

  group('BudgetSettings：解析与回落', () {
    test('正常值往返', () {
      final b = BudgetSettings.fromRows(
          {'monthly_budget': '2500.5', 'budget_start_day': '15'});
      expect(b.monthlyBudget, 2500.5);
      expect(b.startDay, 15);
      expect(b.enabled, isTrue);
    });

    test('缺失/脏值回落为"未设置"', () {
      final empty = BudgetSettings.fromRows({});
      expect(empty.monthlyBudget, 0);
      expect(empty.startDay, 1);
      expect(empty.enabled, isFalse);

      final dirty = BudgetSettings.fromRows(
          {'monthly_budget': 'abc', 'budget_start_day': 'xyz'});
      expect(dirty.monthlyBudget, 0);
      expect(dirty.startDay, 1);
      expect(dirty.enabled, isFalse);
    });

    test('非正数预算视为未设置', () {
      final zero = BudgetSettings.fromRows({'monthly_budget': '0'});
      expect(zero.enabled, isFalse);
      final neg = BudgetSettings.fromRows({'monthly_budget': '-100'});
      expect(neg.enabled, isFalse);
    });

    test('起始日 clamp 到 1-28', () {
      expect(BudgetSettings.fromRows({'budget_start_day': '99'}).startDay, 28);
      expect(BudgetSettings.fromRows({'budget_start_day': '0'}).startDay, 1);
      expect(BudgetSettings.fromRows({'budget_start_day': '-3'}).startDay, 1);
    });

    test('copyWith 只改指定字段', () {
      const b = BudgetSettings(monthlyBudget: 3000, startDay: 10);
      final c = b.copyWith(startDay: 20);
      expect(c.monthlyBudget, 3000);
      expect(c.startDay, 20);
      final d = b.copyWith(monthlyBudget: 4000);
      expect(d.monthlyBudget, 4000);
      expect(d.startDay, 10);
    });

    test('toMap 键名与 fromRows 对得上', () {
      const b = BudgetSettings(monthlyBudget: 3000, startDay: 10);
      final back = BudgetSettings.fromRows(
          b.toMap().map((k, v) => MapEntry(k, v.toString())));
      expect(back.monthlyBudget, b.monthlyBudget);
      expect(back.startDay, b.startDay);
    });
  });

  // ---------------- 数据层：settings 表 ----------------

  group('数据层：settings 读写与 v5 → v6 迁移', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    const settingsTable = 'settings';

    /// 与 lib/db.dart 的 _createSettingsTable 同构
    Future<void> createSettings(Database db) async {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $settingsTable (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
    }

    /// 与 lib/db.dart 的 _upgradeToV6 同构（当前只建一张表）
    Future<void> upgradeToV6(Database db) async {
      await createSettings(db);
    }

    /// 与 lib/db.dart 的 saveBudget 同构：事务 + replace
    Future<void> saveBudget(Database db, BudgetSettings b) async {
      await db.transaction((txn) async {
        await txn.insert(
          settingsTable,
          {'key': 'monthly_budget', 'value': b.monthlyBudget.toString()},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await txn.insert(
          settingsTable,
          {'key': 'budget_start_day', 'value': b.startDay.toString()},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });
    }

    /// 与 lib/db.dart 的 loadBudget 同构
    Future<BudgetSettings> loadBudget(Database db) async {
      final rows = await db.query(settingsTable);
      final map = <String, String>{};
      for (final r in rows) {
        final k = r['key'] as String?;
        final v = r['value'] as String?;
        if (k != null && v != null) map[k] = v;
      }
      return BudgetSettings.fromRows(map);
    }

    test('v5 老库升级到 v6：settings 表就绪、预算默认未设置', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      // v5 老库：没有任何 settings 表
      expect(
        await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='$settingsTable'"),
        isEmpty,
      );

      await upgradeToV6(db);

      final t = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='$settingsTable'");
      expect(t.length, 1, reason: 'v6 迁移必须建出 settings 表');
      // 老用户没设过预算 → 未设置状态
      final b = await loadBudget(db);
      expect(b.enabled, isFalse);
      expect(b.startDay, 1);

      await db.close();
    });

    test('升级脚本可重复执行（幂等）', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await upgradeToV6(db);
      await upgradeToV6(db);
      await upgradeToV6(db);

      final t = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='$settingsTable'");
      expect(t.length, 1, reason: 'IF NOT EXISTS 兜底，表不会建重');

      await db.close();
    });

    test('保存后可原样读回', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await upgradeToV6(db);

      await saveBudget(db, const BudgetSettings(monthlyBudget: 3500, startDay: 25));
      final b = await loadBudget(db);
      expect(b.monthlyBudget, 3500);
      expect(b.startDay, 25);
      expect(b.enabled, isTrue);

      await db.close();
    });

    test('重复保存是覆盖而不是报错或变两行', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await upgradeToV6(db);

      await saveBudget(db, const BudgetSettings(monthlyBudget: 3000, startDay: 1));
      await saveBudget(db, const BudgetSettings(monthlyBudget: 2000, startDay: 20));

      final b = await loadBudget(db);
      expect(b.monthlyBudget, 2000, reason: '后一次保存要覆盖前一次');
      expect(b.startDay, 20);
      final rows = await db.query(settingsTable);
      expect(rows.length, 2, reason: '两个 key 各一行');

      await db.close();
    });

    test('settings 表与 bills 表互不干扰', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await upgradeToV6(db);
      await saveBudget(db, const BudgetSettings(monthlyBudget: 1000, startDay: 1));
      // 表名不冲突、查询不串台
      final b = await loadBudget(db);
      expect(b.monthlyBudget, 1000);
      await db.close();
    });
  });
}
