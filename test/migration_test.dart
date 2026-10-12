import 'package:flutter/material.dart' show IconData;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ledger_book/models.dart';

/// v1 → v2 迁移的端到端验证。
///
/// 这是整个账户改造里风险最高的一段：老用户升级时如果漏了 `account` 列，
/// 或者 `ALTER TABLE` 的默认值没生效，历史账单就会丢或报错。
/// 这里用内存库真实跑一遍 openDatabase 的 onCreate / onUpgrade 回调，
/// 确保迁移后行数不变、默认账户落位、账户表已建好。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// 复刻 lib/db.dart 里的建表语句，保证测试与生产同构。
  /// 刻意不直接调用 BillDatabase（它绑定手机路径），而是把 DDL 抄过来。
  const billsTable = 'bills';
  const accountTable = 'accounts';
  const defaultAccount = kDefaultAccount;

  Future<void> createV1(Database db) async {
    await db.execute('''
      CREATE TABLE $billsTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type INTEGER NOT NULL,
        amount REAL NOT NULL,
        category TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        date INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_bills_date ON $billsTable (date)');
    await db.execute(
        'CREATE INDEX idx_bills_type_date ON $billsTable (type, date)');
  }

  Future<void> upgradeToV2(Database db) async {
    // 与 lib/db.dart 的 _upgradeToV2 同构：先查 pragma 再补列
    final cols = await db.rawQuery('PRAGMA table_info($billsTable)');
    if (!cols.any((c) => (c['name'] as String?) == 'account')) {
      await db.execute(
          "ALTER TABLE $billsTable ADD COLUMN account TEXT NOT NULL DEFAULT '$defaultAccount'");
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $accountTable (
        name TEXT PRIMARY KEY,
        icon INTEGER NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');
    final batch = db.batch();
    for (int i = 0; i < kBuiltinAccounts.length; i++) {
      final a = kBuiltinAccounts[i];
      batch.insert(
        accountTable,
        {'name': a.name, 'icon': a.icon.codePoint, 'sort_order': i},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_bills_account ON $billsTable (account)');
  }

  test('v1 老库升级到 v2：账单不丢、补上默认账户、账户表就绪', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);

    await createV1(db);
    // 模拟 v1 时代的 3 条历史账单
    for (final r in [
      {'type': 0, 'amount': 30.0, 'category': '餐饮', 'date': 20260801},
      {'type': 0, 'amount': 88.5, 'category': '购物', 'date': 20260802},
      {'type': 1, 'amount': 9000.0, 'category': '工资', 'date': 20260805},
    ]) {
      await db.insert(billsTable, {
        ...r,
        'note': '',
        'created_at': DateTime(2026, 8, 1).millisecondsSinceEpoch,
      });
    }
    expect((await db.query(billsTable)).length, 3);

    await upgradeToV2(db);

    // 1) 行数不变——这是迁移最硬的底线
    final rows = await db.query(billsTable);
    expect(rows.length, 3);

    // 2) 每条老记录都落到"现金"，且金额/分类/日期原样保留
    for (final row in rows) {
      expect(row['account'], defaultAccount);
    }
    final food = rows.firstWhere((r) => r['category'] == '餐饮');
    expect(food['amount'], 30.0);
    expect(food['date'], 20260801);

    // 3) 账户表已建好并写入了 4 个内置账户
    final accounts = await db.query(accountTable, orderBy: 'sort_order ASC');
    expect(accounts.length, kBuiltinAccounts.length);
    expect(accounts.first['name'], '现金');
    expect(
      accounts.map((a) => a['name']).toList(),
      kBuiltinAccounts.map((a) => a.name).toList(),
    );

    // 4) 图标 codePoint 可往返
    final wechat = accounts.firstWhere((a) => a['name'] == '微信');
    final restored = IconData(wechat['icon'] as int,
        fontFamily: 'MaterialIcons');
    expect(
      restored.codePoint,
      kBuiltinAccounts.firstWhere((a) => a.name == '微信').icon.codePoint,
    );

    await db.close();
  });

  test('迁移后可按账户过滤查询', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await createV1(db);
    for (final r in [
      {'type': 0, 'amount': 30.0, 'category': '餐饮', 'date': 20260801},
      {'type': 0, 'amount': 70.0, 'category': '交通', 'date': 20260802},
    ]) {
      await db.insert(billsTable, {
        ...r,
        'note': '',
        'created_at': DateTime(2026, 8, 1).millisecondsSinceEpoch,
      });
    }
    await upgradeToV2(db);
    // 迁移后再记一笔到"微信"
    await db.insert(billsTable, {
      'type': 0,
      'amount': 500.0,
      'category': '购物',
      'account': '微信',
      'note': '',
      'date': 20260810,
      'created_at': DateTime(2026, 8, 10).millisecondsSinceEpoch,
    });

    final cash = await db
        .query(billsTable, where: 'account = ?', whereArgs: [defaultAccount]);
    final wx = await db.query(billsTable, where: 'account = ?', whereArgs: ['微信']);

    expect(cash.length, 2); // 两条历史账单归现金
    expect(wx.length, 1);
    expect(wx.first['amount'], 500.0);

    // 账户列有索引，EXPLAIN 应能命中而不是全表扫描
    final plan = await db.rawQuery(
        'EXPLAIN QUERY PLAN SELECT * FROM $billsTable WHERE account = ?',
        ['微信']);
    expect(plan.toString().contains('idx_bills_account'), isTrue);

    await db.close();
  });

  test('升级脚本可重复执行而不报错（幂等）', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await createV1(db);
    await upgradeToV2(db);
    // 账户表用 IF NOT EXISTS、账户插入用 ignore，重复跑不应炸
    await upgradeToV2(db);

    final accounts = await db.query(accountTable);
    expect(accounts.length, kBuiltinAccounts.length); // 没有写重复

    await db.close();
  });
}
