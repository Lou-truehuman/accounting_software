import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common/utils/utils.dart' show firstIntValue;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ledger_book/db.dart';
import 'package:ledger_book/models.dart';

/// v2 → v3 迁移与「余额口径」的端到端验证。
///
/// v3 引入了两样东西：
///   1. accounts.initial_balance —— 期初余额
///   2. transfers 表            —— 账户间转账
///
/// 这两者的存在意义都是为了让**账户余额算得对**：
///   余额 = 期初 + 收入 + 转入 − 支出 − 转出
///
/// 最核心的一条不变量：**转账不计入收支**。
/// 它只是钱从左口袋到右口袋，若混进 bills 表，
/// 总支出/总收入/分类占比全都会被污染。这里用测试把这条钉死。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const billsTable = 'bills';
  const accountTable = 'accounts';
  const transferTable = 'transfers';

  /// 复刻 lib/db.dart 的 DDL，保证测试与生产同构
  Future<void> createV2(Database db) async {
    await db.execute('''
      CREATE TABLE $billsTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type INTEGER NOT NULL,
        amount REAL NOT NULL,
        category TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        date INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        account TEXT NOT NULL DEFAULT '$kDefaultAccount'
      )
    ''');
    await db.execute('CREATE INDEX idx_bills_date ON $billsTable (date)');
    await db.execute(
        'CREATE INDEX idx_bills_type_date ON $billsTable (type, date)');
    await db.execute(
        'CREATE INDEX idx_bills_account ON $billsTable (account)');
    await db.execute('''
      CREATE TABLE $accountTable (
        name TEXT PRIMARY KEY,
        icon INTEGER NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');
    // v2 没有 initial_balance 列，这正是 v3 要补的
    for (int i = 0; i < kBuiltinAccounts.length; i++) {
      final a = kBuiltinAccounts[i];
      await db.insert(
        accountTable,
        {'name': a.name, 'icon': a.icon.codePoint, 'sort_order': i},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  Future<void> upgradeToV3(Database db) async {
    // 与 lib/db.dart 的 _upgradeToV3 同构：先查 pragma 再补列
    final cols = await db.rawQuery('PRAGMA table_info($accountTable)');
    if (!cols.any((c) => (c['name'] as String?) == 'initial_balance')) {
      await db.execute(
          'ALTER TABLE $accountTable ADD COLUMN initial_balance REAL NOT NULL DEFAULT 0');
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $transferTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        from_account TEXT NOT NULL,
        to_account TEXT NOT NULL,
        amount REAL NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        date INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_transfers_date ON $transferTable (date)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_transfers_from ON $transferTable (from_account)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_transfers_to ON $transferTable (to_account)');
  }

  /// 按指定账户汇总（复刻 summaryByAccount 的核心口径）
  Future<AccountSummary> summaryOf(
    Database db,
    String account,
    DateTime from,
    DateTime to,
  ) async {
    final lo = BillRecord.dateToInt(from);
    final hi = BillRecord.dateToInt(to);

    final rows = await db.rawQuery('''
      SELECT SUM(CASE WHEN type = 0 THEN amount ELSE 0 END) AS exp,
             SUM(CASE WHEN type = 1 THEN amount ELSE 0 END) AS inc
      FROM $billsTable
      WHERE date >= ? AND date <= ? AND account = ?
    ''', [lo, hi, account]);

    final initRow = await db.query(accountTable,
        columns: ['initial_balance'], where: 'name = ?', whereArgs: [account]);
    final init = initRow.isEmpty
        ? 0.0
        : ((initRow.first['initial_balance'] as num?) ?? 0).toDouble();

    final outRow = await db.rawQuery(
        'SELECT SUM(amount) AS t FROM $transferTable '
        'WHERE date >= ? AND date <= ? AND from_account = ?',
        [lo, hi, account]);
    final inRow = await db.rawQuery(
        'SELECT SUM(amount) AS t FROM $transferTable '
        'WHERE date >= ? AND date <= ? AND to_account = ?',
        [lo, hi, account]);

    return AccountSummary(
      account: account,
      expense: ((rows.first['exp'] as num?) ?? 0).toDouble(),
      income: ((rows.first['inc'] as num?) ?? 0).toDouble(),
      initialBalance: init,
      transferIn: ((inRow.first['t'] as num?) ?? 0).toDouble(),
      transferOut: ((outRow.first['t'] as num?) ?? 0).toDouble(),
    );
  }

  group('v2 → v3 迁移', () {
    test('补上 initial_balance 列，老账户默认 0，账单不丢', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await createV2(db);

      // 塞几条 v2 时代的账单
      for (final r in [
        {'type': 0, 'amount': 25.5, 'category': '餐饮', 'date': 20260918},
        {'type': 1, 'amount': 8000.0, 'category': '工资', 'date': 20260910},
      ]) {
        await db.insert(billsTable, {
          'type': r['type'],
          'amount': r['amount'],
          'category': r['category'],
          'note': '',
          'date': r['date'],
          'created_at': 1000,
          'account': kDefaultAccount,
        });
      }

      final before = firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM $billsTable'))!;

      await upgradeToV3(db);

      final after = firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM $billsTable'))!;
      expect(after, before, reason: '迁移后账单行数必须不变');

      // 老账户的期初余额应为 0（新列默认值生效）
      final rows = await db.query(accountTable,
          columns: ['name', 'initial_balance']);
      expect(rows, isNotEmpty);
      for (final r in rows) {
        expect((r['initial_balance'] as num).toDouble(), 0.0,
            reason: '迁移后老账户期初余额应为 0，不能是 null');
      }

      // transfers 表已就绪
      final t = await db.rawQuery('PRAGMA table_info($transferTable)');
      expect(t.map((c) => c['name']), containsAll(
          ['id', 'from_account', 'to_account', 'amount', 'note', 'date', 'created_at']));

      await db.close();
    });

    test('升级脚本可重复执行而不报错（幂等）', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await createV2(db);

      await upgradeToV3(db);
      // 再跑一次，不能抛异常（ALTER TABLE 无 IF NOT EXISTS，靠 pragma 挡住）
      await upgradeToV3(db);
      await upgradeToV3(db);

      final cols = await db.rawQuery('PRAGMA table_info($accountTable)');
      final initCols =
          cols.where((c) => c['name'] == 'initial_balance').length;
      expect(initCols, 1, reason: '重复迁移不应把列加两遍');

      await db.close();
    });
  });

  group('余额口径', () {
    late Database db;
    final from = DateTime(2026, 1, 1);
    final to = DateTime(2026, 12, 31);

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await createV2(db);
      await upgradeToV3(db);
    });

    tearDown(() async => db.close());

    Future<void> addBill(String account, int type, double amount) =>
        db.insert(billsTable, {
          'type': type,
          'amount': amount,
          'category': type == 0 ? '餐饮' : '工资',
          'note': '',
          'date': 20260918,
          'created_at': 1000,
          'account': account,
        });

    Future<void> addTransfer(
            String fromAcc, String toAcc, double amount) =>
        db.insert(transferTable, {
          'from_account': fromAcc,
          'to_account': toAcc,
          'amount': amount,
          'note': '',
          'date': 20260918,
          'created_at': 1000,
        });

    test('余额 = 期初 + 收入 + 转入 − 支出 − 转出', () async {
      await db.update(accountTable, {'initial_balance': 1000.0},
          where: 'name = ?', whereArgs: ['现金']);
      await addBill('现金', BillType.expense.index, 200); // 支出 200
      await addBill('现金', BillType.income.index, 500); // 收入 500
      await addTransfer('微信', '现金', 300); // 转入 300
      await addTransfer('现金', '支付宝', 100); // 转出 100

      final s = await summaryOf(db, '现金', from, to);

      expect(s.initialBalance, 1000);
      expect(s.expense, 200);
      expect(s.income, 500);
      expect(s.transferIn, 300);
      expect(s.transferOut, 100);
      // 1000 + 500 + 300 − 200 − 100 = 1500
      expect(s.balance, 1500,
          reason: '余额口径算错，账户页显示的钱就不是真实可用金额');
    });

    test('转账不计入收支（这是转账必须单表存放的根本原因）', () async {
      await addTransfer('微信', '现金', 888);

      final cash = await summaryOf(db, '现金', from, to);

      expect(cash.income, 0, reason: '转入不是收入');
      expect(cash.expense, 0, reason: '转出不是支出');
      expect(cash.transferIn, 888);
      // 余额层面它确实增加了，但收支口径必须干净
      expect(cash.balance, 888);
    });

    test('一笔转账在两个账户上金额相等、方向相反', () async {
      await addTransfer('微信', '现金', 250);

      final wechat = await summaryOf(db, '微信', from, to);
      final cash = await summaryOf(db, '现金', from, to);

      expect(wechat.transferOut, 250);
      expect(wechat.transferIn, 0);
      expect(cash.transferIn, 250);
      expect(cash.transferOut, 0);

      // 两账户余额变动之和为 0：钱没凭空产生也没消失
      expect(cash.balance + wechat.balance, 0,
          reason: '转账应守恒，两账户余额变动合计必须为 0');
    });

    test('全部账户余额合计 = 各账户期初之和 + 总收入 − 总支出', () async {
      await db.update(accountTable, {'initial_balance': 1000.0},
          where: 'name = ?', whereArgs: ['现金']);
      await db.update(accountTable, {'initial_balance': 5000.0},
          where: 'name = ?', whereArgs: ['银行卡']);

      await addBill('现金', BillType.expense.index, 300);
      await addBill('银行卡', BillType.income.index, 2000);
      await addTransfer('银行卡', '现金', 800);

      final cash = await summaryOf(db, '现金', from, to);
      final card = await summaryOf(db, '银行卡', from, to);

      // 期初 6000 + 收入 2000 − 支出 300 = 7700
      // 注意转账合计为 0，不该影响总额
      expect(cash.balance + card.balance, 7700,
          reason: '转账在账户间一进一出，不应虚增总余额');
    });

    test('只设了期初余额、还没记账的账户也有余额', () async {
      await db.update(accountTable, {'initial_balance': 3000.0},
          where: 'name = ?', whereArgs: ['支付宝']);

      final s = await summaryOf(db, '支付宝', from, to);

      expect(s.expense, 0);
      expect(s.income, 0);
      expect(s.balance, 3000,
          reason: '有期初余额但无账单的账户必须能算出余额，不能显示为 0');
    });

    test('期初余额不受统计区间影响', () async {
      await db.update(accountTable, {'initial_balance': 1000.0},
          where: 'name = ?', whereArgs: ['现金']);

      // 换个完全不相交的区间，期初余额仍应原样带出
      final s = await summaryOf(
          db, '现金', DateTime(2020, 1, 1), DateTime(2020, 12, 31));

      expect(s.initialBalance, 1000,
          reason: '期初余额是存量起点值，不该随查询区间变化');
      expect(s.balance, 1000);
    });
  });

  group('账户增删改对转账的处理', () {
    late Database db;

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await createV2(db);
      await upgradeToV3(db);
    });

    tearDown(() async => db.close());

    test('改名账户应同步更新 transfers 的 from/to', () async {
      await db.insert(transferTable, {
        'from_account': '微信',
        'to_account': '现金',
        'amount': 100,
        'note': '',
        'date': 20260918,
        'created_at': 1000,
      });

      // 复刻 renameAccount 对 transfers 的处理
      await db.update(transferTable, {'from_account': '微信零钱'},
          where: 'from_account = ?', whereArgs: ['微信']);
      await db.update(transferTable, {'to_account': '微信零钱'},
          where: 'to_account = ?', whereArgs: ['微信']);

      final rows = await db.query(transferTable);
      expect(rows.first['from_account'], '微信零钱');
      expect(rows.first['to_account'], '现金');
    });

    test('账户有转账时不应被当作"无记录"而误删', () async {
      await db.insert(transferTable, {
        'from_account': '微信',
        'to_account': '现金',
        'amount': 100,
        'note': '',
        'date': 20260918,
        'created_at': 1000,
      });

      final n = firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM $transferTable '
          'WHERE from_account = ? OR to_account = ?',
          ['微信', '微信']))!;

      expect(n, 1,
          reason: '删除账户的拦截判断必须把转账也算进去，否则会留下悬空引用');
    });
  });
}
