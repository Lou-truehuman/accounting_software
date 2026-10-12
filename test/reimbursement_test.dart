import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ledger_book/models.dart';
import 'package:ledger_book/stats.dart';

/// 报销 / 分摊的「净额合并」口径验证。
///
/// 这是整个功能里风险最高的一段：口径写错不会报错、不会崩，
/// 只会让用户看到一组似是而非的数字。所以这里把每条规则都钉死。
///
/// 核心规则：
///   支出有效额 = 原金额 − 报销合计（配对双方都在区间内时）
///   报销收入   = 不计入总收入（已并入上面那个冲减）
void main() {
  final from = DateTime(2026, 9, 1);
  final to = DateTime(2026, 9, 30);

  /// 造一条支出
  BillRecord expense(int id, double amount, {String category = '餐饮'}) =>
      BillRecord(
        id: id,
        type: BillType.expense,
        amount: amount,
        category: category,
        date: DateTime(2026, 9, 10),
        createdAt: DateTime(2026, 9, 10, 12),
      );

  /// 造一笔报销收入，关联到单笔支出 [linkedId]
  BillRecord reimburse(int id, double amount, int linkedId) => BillRecord(
        id: id,
        type: BillType.income,
        amount: amount,
        category: '报销',
        date: DateTime(2026, 9, 12),
        createdAt: DateTime(2026, 9, 12, 9),
        linkedBillIds: [linkedId],
      );

  /// 造一笔报销收入，一次关联多笔支出（差旅报销掉机票+酒店这种场景）
  BillRecord reimburseMulti(int id, double amount, List<int> linkedIds) =>
      BillRecord(
        id: id,
        type: BillType.income,
        amount: amount,
        category: '报销',
        date: DateTime(2026, 9, 12),
        createdAt: DateTime(2026, 9, 12, 9),
        linkedBillIds: linkedIds,
      );

  /// 普通收入（与任何支出无关）
  BillRecord plainIncome(int id, double amount) => BillRecord(
        id: id,
        type: BillType.income,
        amount: amount,
        category: '工资',
        date: DateTime(2026, 9, 1),
        createdAt: DateTime(2026, 9, 1, 9),
      );

  StatsResult statsOf(List<BillRecord> records) => StatsResult(
        records: records,
        from: from,
        to: to,
        rangeLabel: '2026年9月',
      );

  group('净额合并：基本场景', () {
    test('消费 1000 报销 800 → 支出 200、收入 0', () {
      final s = statsOf([expense(1, 1000), reimburse(2, 800, 1)]);

      expect(s.totalExpense, 200, reason: '支出应按「消费 − 报销」的净额计');
      expect(s.totalIncome, 0, reason: '报销收入已并入支出冲减，不得再计入收入');
      expect(s.balance, -200, reason: '净额应为 −200，与“花了 1000 收回 800”一致');
      expect(s.totalReimbursed, 800);
      expect(s.reimbursedCount, 1);
    });

    test('报销金额等于消费金额 → 实际自付 0', () {
      final s = statsOf([expense(1, 300), reimburse(2, 300, 1)]);

      expect(s.totalExpense, 0, reason: '全额报销后实际自付为 0');
      expect(s.balance, 0);
    });

    test('分次报销：1000 分两次报 500 + 300 → 自付 200', () {
      final s = statsOf([
        expense(1, 1000),
        reimburse(2, 500, 1),
        reimburse(3, 300, 1),
      ]);

      expect(s.totalReimbursed, 800);
      expect(s.totalExpense, 200);
      expect(s.reimbursedCount, 1, reason: '两笔报销冲减的是同一笔支出');
    });

    test('朋友平摊：300 的饭局朋友转 150 → 自付 150', () {
      final s = statsOf([expense(1, 300, category: '聚会'), reimburse(2, 150, 1)]);

      expect(s.totalExpense, 150);
      expect(s.totalIncome, 0);
    });

    test('未关联的普通收入照常计入', () {
      final s = statsOf([
        expense(1, 1000),
        reimburse(2, 800, 1),
        plainIncome(3, 5000),
      ]);

      expect(s.totalIncome, 5000, reason: '只有报销收入被并入，普通收入不受影响');
      expect(s.totalExpense, 200);
      expect(s.balance, 4800);
    });

    test('支出无关联时口径与改造前完全一致', () {
      final s = statsOf([expense(1, 1000), plainIncome(2, 800)]);

      expect(s.totalExpense, 1000, reason: '没有报销就不该有任何扣减');
      expect(s.totalIncome, 800);
      expect(s.balance, -200);
    });
  });

  group('净额合并：跨期处理', () {
    test('报销不在区间内 → 支出按原额计，不做扣减', () {
      // 只有支出在区间里，报销被"留在"了区间外
      final s = statsOf([expense(1, 1000)]);

      expect(s.totalExpense, 1000,
          reason: '报销还没发生/不在本期，支出不该凭空减少');
      expect(s.totalReimbursed, 0);
    });

    test('支出不在区间内 → 报销收入按普通收入计', () {
      // 只有报销收入在区间里，被关联的支出在区间外
      final s = statsOf([reimburse(2, 800, 999)]);

      expect(s.totalIncome, 800,
          reason: '找不到可冲减的支出时，这笔钱不能凭空消失，应作为普通收入');
      expect(s.totalExpense, 0);
    });

    test('配对双方都在区间 → 合并生效', () {
      final s = statsOf([expense(1, 1000), reimburse(2, 800, 1)]);
      expect(s.totalExpense, 200);
      expect(s.totalIncome, 0);
    });
  });

  group('净额合并：一笔报销关联多笔支出', () {
    test('报销 1200 关联 1000+500 两笔 → 按比例分摊，自付合计 300', () {
      final s = statsOf([
        expense(1, 1000),
        expense(2, 500),
        reimburseMulti(3, 1200, [1, 2]),
      ]);

      // 1200 按支出金额占比分摊：1000/1500 → 800，500/1500 → 400
      expect(s.reimbursedOf(expense(1, 1000)), closeTo(800, 0.01));
      expect(s.reimbursedOf(expense(2, 500)), closeTo(400, 0.01));
      expect(s.totalExpense, closeTo(300, 0.01), reason: '1500 − 1200 = 300');
      expect(s.totalIncome, 0, reason: '未超支，报销本身不计收入');
      expect(s.balance, closeTo(-300, 0.01));
      expect(s.reimbursedCount, 2, reason: '两笔支出都被这笔报销冲减了');
    });

    test('报销等于多笔支出合计 → 全部自付为 0', () {
      final s = statsOf([
        expense(1, 1000),
        expense(2, 500),
        reimburseMulti(3, 1500, [1, 2]),
      ]);

      expect(s.totalExpense, 0);
      expect(s.totalIncome, 0);
      expect(s.balance, 0);
    });

    test('多笔中的一笔不在区间 → 只合并区间内的那笔', () {
      // 报销 1200 想关联 1 和 999，但 999 不在区间里
      final s = statsOf([
        expense(1, 1000),
        reimburseMulti(3, 1200, [1, 999]),
      ]);

      // 只与区间内的 1000 合并：1200 全摊给它仍超出，超出 200 计为净收入
      expect(s.totalExpense, 0);
      expect(s.totalIncome, closeTo(200, 0.01));
      expect(s.balance, closeTo(200, 0.01));
    });
  });

  group('净额合并：报销金额大于实际支出（核心新口径）', () {
    test('报销 2000 > 支出合计 1500 → 支出归零，净收入 500', () {
      final s = statsOf([
        expense(1, 1000),
        expense(2, 500),
        reimburseMulti(3, 2000, [1, 2]),
      ]);

      expect(s.totalExpense, 0, reason: '两笔消费被完全覆盖，净额归零');
      expect(s.totalIncome, closeTo(500, 0.01),
          reason: '超出部分 2000 − 1500 = 500 是实打实多收的钱，按净收入计');
      expect(s.balance, closeTo(500, 0.01));
    });

    test('单笔支出 1000、报销 1300 → 支出 0、净收入 300', () {
      final s = statsOf([expense(1, 1000), reimburse(2, 1300, 1)]);

      expect(s.totalExpense, 0);
      expect(s.totalIncome, closeTo(300, 0.01));
      expect(s.balance, closeTo(300, 0.01));
    });

    test('净资产守恒：超额报销关联与否，结余相同', () {
      final linked = statsOf([
        expense(1, 1000),
        expense(2, 500),
        reimburseMulti(3, 2000, [1, 2]),
      ]).balance;
      final unlinked = statsOf([
        expense(1, 1000),
        expense(2, 500),
        plainIncome(4, 2000),
      ]).balance;

      // 用 closeTo 而非精确相等：关联路径要走比例分摊（2000×1000/1500 之类），
      // 浮点会带上 1e-13 量级的尾差；展示层 formatMoney 统一两位小数，
      // 这点尾差在账面上看不见，但不足以撼动"口径一致"这个结论。
      expect(linked, closeTo(unlinked, 0.01),
          reason: '关联与否只是展示口径，净资产变动必须一致');
      expect(linked, closeTo(500, 0.01));
    });

    test('超额时支出净额绝不为负', () {
      final s = statsOf([
        expense(1, 100),
        expense(2, 100),
        expense(3, 100),
        reimburseMulti(4, 10000, [1, 2, 3]),
      ]);

      for (final r in s.records.where((r) => r.type == BillType.expense)) {
        expect(s.effectiveExpenseOf(r), greaterThanOrEqualTo(0),
            reason: '报销再夸张也不能把支出翻成负数');
      }
      expect(s.totalExpense, 0);
      expect(s.totalIncome, closeTo(9700, 0.01));
    });

    test('超额合并在各聚合维度都生效', () {
      final s = statsOf([
        expense(1, 1000, category: '差旅'),
        expense(2, 500, category: '交通'),
        reimburseMulti(3, 2000, [1, 2]),
      ]);

      // 支出分类：净额全为 0，但仍保留分类条目（口径与"未报销时一致"）
      final byCatExpense = s.byCategory(type: BillType.expense);
      expect(byCatExpense.fold<double>(0, (a, e) => a + e.expense), 0);

      // 收入分类：超额部分 500 出现在"报销"分类下
      final byCatIncome = s.byCategory(type: BillType.income);
      expect(byCatIncome.length, 1);
      expect(byCatIncome.first.label, '报销');
      expect(byCatIncome.first.income, closeTo(500, 0.01));

      // 按日：支出日净额 0，报销日收入 500
      final byDay = s.byDay();
      expect(byDay.firstWhere((e) => e.key == '20260910').expense, 0);
      expect(byDay.firstWhere((e) => e.key == '20260912').income,
          closeTo(500, 0.01));

      // 按月
      expect(s.byMonth().first.income, closeTo(500, 0.01));
      expect(s.byMonth().first.expense, 0);
    });
  });

  group('净额合并：多笔报销砸同一笔支出（分摊封顶）', () {
    test('两笔报销合计超过支出原额 → 压回原额，差额回流为净收入', () {
      final s = statsOf([
        expense(1, 1000),
        reimburse(2, 800, 1),
        reimburse(3, 700, 1),
      ]);

      expect(s.totalExpense, 0, reason: '封顶后支出被完全覆盖');
      expect(s.totalIncome, closeTo(500, 0.01),
          reason: '800+700−1000=500 的差额回流成净收入');
      expect(s.balance, closeTo(500, 0.01));
      // 分摊额合计必须恰好等于支出原额，不能超
      expect(s.reimbursedOf(expense(1, 1000)), closeTo(1000, 0.01));
    });

    test('混合场景：一笔多关联 + 一笔单关联，仍不出现负支出', () {
      final s = statsOf([
        expense(1, 1000),
        expense(2, 1000),
        reimburseMulti(3, 1500, [1, 2]), // 摊 750 / 750
        reimburse(4, 800, 1), // 再砸 800 到支出 1 → 合计 1550 > 1000
      ]);

      expect(s.effectiveExpenseOf(expense(1, 1000)), 0);
      expect(s.effectiveExpenseOf(expense(2, 1000)), closeTo(250, 0.01));
      expect(s.totalExpense, closeTo(250, 0.01));
      // 支出 1 超额的 550 回流给第 4 笔，成为净收入
      expect(s.totalIncome, closeTo(550, 0.01));
      expect(s.balance, closeTo(300, 0.01));
    });
  });

  group('净额合并：辅助方法', () {
    test('countedIncomeOf：普通收入全额、未超支报销为 0、超支报销为净额', () {
      final e = expense(1, 1000);
      final over = reimburse(2, 1300, 1);
      final under = reimburse(3, 400, 1);
      final plain = plainIncome(4, 5000);
      final s = statsOf([e, over, under, plain]);

      expect(s.countedIncomeOf(plain), 5000);
      // 支出 1 被 1300 + 400 两笔砸：合计 1700 > 1000，
      // 等比例压回 1000（各得 764.71 / 235.29），差额 700 回流成净收入
      expect(s.countedIncomeOf(over) + s.countedIncomeOf(under),
          closeTo(700, 0.01));
      expect(s.totalIncome, closeTo(5700, 0.01));
      expect(s.totalExpense, 0);
    });

    test('普通收入不受报销关联影响', () {
      final s = statsOf([
        expense(1, 1000),
        expense(2, 500),
        reimburseMulti(3, 2000, [1, 2]),
        plainIncome(4, 8000),
      ]);

      expect(s.totalIncome, closeTo(8500, 0.01));
      expect(s.totalExpense, 0);
      expect(s.balance, closeTo(8500, 0.01));
    });
  });

  group('净额合并：各聚合维度都要生效', () {
    late StatsResult s;
    setUp(() {
      s = statsOf([expense(1, 1000, category: '餐饮'), reimburse(2, 800, 1)]);
    });

    test('按分类聚合：支出分类取净额', () {
      final byCat = s.byCategory(type: BillType.expense);
      expect(byCat.length, 1);
      expect(byCat.first.label, '餐饮');
      expect(byCat.first.expense, 200, reason: '分类视图也必须用净额，否则与总数对不上');
    });

    test('按分类聚合：报销收入不出现在收入分类里', () {
      final byCat = s.byCategory(type: BillType.income);
      expect(byCat, isEmpty, reason: '报销收入已并入支出，不该再冒出一个“报销”分类');
    });

    test('按日聚合：支出日取净额、收入日不含报销', () {
      final byDay = s.byDay();
      // 注意 Slice.key 是 String，日期键为 YYYYMMDD 的字符串形式
      final sep10 = byDay.firstWhere((e) => e.key == '20260910');
      expect(sep10.expense, 200);

      final sep12 = byDay.firstWhere((e) => e.key == '20260912');
      expect(sep12.income, 0, reason: '报销当天不该再有收入');
    });

    test('按月聚合：同上', () {
      final byMonth = s.byMonth();
      expect(byMonth.length, 1);
      expect(byMonth.first.expense, 200);
      expect(byMonth.first.income, 0);
    });

    test('按星期聚合：同上', () {
      final byWd = s.byWeekday();
      final total = byWd.fold<double>(0, (a, e) => a + e.expense);
      final incTotal = byWd.fold<double>(0, (a, e) => a + e.income);
      expect(total, 200);
      expect(incTotal, 0);
    });
  });

  group('净额合并：派生指标', () {
    test('最大单笔支出按净额比较', () {
      // A 原额大但被全额报销，B 原额小但完全自付 → 最大支出应是 B
      final s = statsOf([
        expense(1, 5000, category: '差旅'),
        reimburse(2, 5000, 1),
        expense(3, 300, category: '餐饮'),
      ]);

      final max = s.maxExpense;
      expect(max, isNotNull);
      expect(max!.category, '餐饮',
          reason: '被全额报销的支出实际自付 0，不该算成最大支出');
      expect(s.effectiveExpenseOf(max), 300);
    });

    test('日均支出按净额总额推算，且分母只算有支出的天', () {
      final s = statsOf([expense(1, 1000), reimburse(2, 800, 1)]);

      expect(s.dayCount, 2, reason: '9/10 有支出、9/12 有报销，共 2 天有记账');
      expect(s.expenseDayCount, 1, reason: '只有 9/10 这天有支出');
      expect(s.avgDailyExpense, 200,
          reason: '分母用"有支出的天数"，否则报销到账那天会把日均冲淡');
    });

    test('净资产守恒：有无报销，结余相同', () {
      final withReimburse =
          statsOf([expense(1, 1000), reimburse(2, 800, 1)]).balance;
      // 同样的钱：花 1000、收到 800（当作普通收入）
      final withoutReimburse =
          statsOf([expense(1, 1000), plainIncome(2, 800)]).balance;

      expect(withReimburse, withoutReimburse,
          reason: '关联与否只是展示口径的差别，净资产的变动必须一致');
    });
  });

  group('辅助方法', () {
    test('reimbursedOf / effectiveExpenseOf / isMergedIncome', () {
      final e = expense(1, 1000);
      final i = reimburse(2, 800, 1);
      final s = statsOf([e, i]);

      expect(s.reimbursedOf(e), 800);
      expect(s.effectiveExpenseOf(e), 200);
      expect(s.isMergedIncome(i), isTrue);
      // 对收入调用这几个方法应安全返回
      expect(s.reimbursedOf(i), 0);
      expect(s.effectiveExpenseOf(i), 0);
    });

    test('没有 id 的记录不会被误配对', () {
      final noId = BillRecord(
        type: BillType.expense,
        amount: 1000,
        category: '餐饮',
        date: DateTime(2026, 9, 10),
        createdAt: DateTime(2026, 9, 10),
      );
      final s = statsOf([noId, reimburse(2, 800, 1)]);

      expect(s.totalExpense, 1000, reason: 'id 为空无法被关联，应按原额计');
    });
  });

  group('数据库层：v3 → v4 迁移', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    const billsTable = 'bills';
    const accountTable = 'accounts';

    Future<void> createV3(Database db) async {
      await db.execute('''
        CREATE TABLE $billsTable (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          type INTEGER NOT NULL,
          amount REAL NOT NULL,
          category TEXT NOT NULL,
          account TEXT NOT NULL DEFAULT '$kDefaultAccount',
          note TEXT NOT NULL DEFAULT '',
          date INTEGER NOT NULL,
          created_at INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE $accountTable (
          name TEXT PRIMARY KEY,
          icon INTEGER NOT NULL,
          sort_order INTEGER NOT NULL DEFAULT 0,
          initial_balance REAL NOT NULL DEFAULT 0
        )
      ''');
    }

    Future<void> upgradeToV4(Database db) async {
      // 与 lib/db.dart 的 _upgradeToV4 同构：先查 pragma 再补列
      final cols = await db.rawQuery('PRAGMA table_info($billsTable)');
      if (!cols.any((c) => (c['name'] as String?) == 'linked_bill_id')) {
        await db.execute(
            'ALTER TABLE $billsTable ADD COLUMN linked_bill_id INTEGER');
      }
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_bills_linked ON $billsTable (linked_bill_id)');
    }

    test('补上 linked_bill_id 列，老账单该列为空，账单不丢', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await createV3(db);

      await db.insert(billsTable, {
        'type': 0,
        'amount': 1000.0,
        'category': '餐饮',
        'note': '',
        'date': 20260910,
        'created_at': 1000,
        'account': kDefaultAccount,
      });

      await upgradeToV4(db);

      final rows = await db.query(billsTable);
      expect(rows.length, 1, reason: '迁移后账单不能丢');
      expect(rows.first['linked_bill_id'], isNull,
          reason: '老数据没有关联，应为 NULL，统计口径保持不变');

      await db.close();
    });

    test('升级脚本可重复执行（幂等）', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await createV3(db);

      await upgradeToV4(db);
      await upgradeToV4(db);
      await upgradeToV4(db);

      final cols = await db.rawQuery('PRAGMA table_info($billsTable)');
      final n = cols.where((c) => c['name'] == 'linked_bill_id').length;
      expect(n, 1, reason: '重复迁移不应把列加两遍');

      await db.close();
    });

    test('删除被报销的支出时，关联收入退化为普通收入而非一并删除', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await createV3(db);
      await upgradeToV4(db);

      final eid = await db.insert(billsTable, {
        'type': 0,
        'amount': 1000.0,
        'category': '餐饮',
        'note': '',
        'date': 20260910,
        'created_at': 1000,
        'account': kDefaultAccount,
      });
      final iid = await db.insert(billsTable, {
        'type': 1,
        'amount': 800.0,
        'category': '报销',
        'note': '',
        'date': 20260912,
        'created_at': 2000,
        'account': kDefaultAccount,
        'linked_bill_id': eid,
      });

      // 复刻 BillDatabase.delete 的两步：先解除关联，再删支出
      await db.update(billsTable, {'linked_bill_id': null},
          where: 'linked_bill_id = ?', whereArgs: [eid]);
      await db.delete(billsTable, where: 'id = ?', whereArgs: [eid]);

      final remains = await db.query(billsTable);
      expect(remains.length, 1, reason: '只应删掉那条支出');
      expect(remains.first['id'], iid);
      expect(remains.first['linked_bill_id'], isNull,
          reason: '报销收入应保留并解除关联，钱确实到账了，不能顺手抹掉');

      await db.close();
    });
  });

  group('数据库层：v4 → v5 迁移（单笔关联升级为多笔）', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    const billsTable = 'bills';
    const accountTable = 'accounts';

    /// v4 形态： bills 带 linked_bill_id 单笔关联列
    Future<void> createV4(Database db) async {
      await db.execute('''
        CREATE TABLE $billsTable (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          type INTEGER NOT NULL,
          amount REAL NOT NULL,
          category TEXT NOT NULL,
          account TEXT NOT NULL DEFAULT '$kDefaultAccount',
          note TEXT NOT NULL DEFAULT '',
          date INTEGER NOT NULL,
          created_at INTEGER NOT NULL,
          linked_bill_id INTEGER
        )
      ''');
      await db.execute('''
        CREATE TABLE $accountTable (
          name TEXT PRIMARY KEY,
          icon INTEGER NOT NULL,
          sort_order INTEGER NOT NULL DEFAULT 0,
          initial_balance REAL NOT NULL DEFAULT 0
        )
      ''');
    }

    /// 与 lib/db.dart 的 _upgradeToV5 同构：先查 pragma 再补列、再搬老数据
    Future<void> upgradeToV5(Database db) async {
      final cols = await db.rawQuery('PRAGMA table_info($billsTable)');
      if (!cols.any((c) => (c['name'] as String?) == 'linked_bill_ids')) {
        await db.execute(
            'ALTER TABLE $billsTable ADD COLUMN linked_bill_ids TEXT');
        final rows = await db.rawQuery(
            'SELECT id, linked_bill_id FROM $billsTable WHERE linked_bill_id IS NOT NULL');
        if (rows.isNotEmpty) {
          final batch = db.batch();
          for (final r in rows) {
            final lid = r['linked_bill_id'] as int?;
            if (lid == null) continue;
            batch.update(billsTable, {'linked_bill_ids': '[$lid]'},
                where: 'id = ?', whereArgs: [r['id']]);
          }
          await batch.commit(noResult: true);
        }
      }
    }

    /// 与 lib/db.dart 的 _idsLikeExpr 同构：逗号包裹做精确成员判断
    const idsLikeExpr =
        "',' || replace(replace(replace(linked_bill_ids, '[', ''), ']', ''), ' ', '') || ','";

    Future<int> insertBill(Database db, Map<String, Object?> row) =>
        db.insert(billsTable, row);

    test('单笔关联迁移为 JSON 数组，老账单不丢、口径不变', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await createV4(db);

      final eid = await insertBill(db, {
        'type': 0,
        'amount': 1000.0,
        'category': '餐饮',
        'note': '',
        'date': 20260910,
        'created_at': 1000,
        'account': kDefaultAccount,
      });
      await insertBill(db, {
        'type': 1,
        'amount': 800.0,
        'category': '报销',
        'note': '',
        'date': 20260912,
        'created_at': 2000,
        'account': kDefaultAccount,
        'linked_bill_id': eid,
      });

      await upgradeToV5(db);

      final rows = await db.query(billsTable, orderBy: 'id ASC');
      expect(rows.length, 2, reason: '迁移不能丢账单');
      expect(rows.first['linked_bill_ids'], isNull, reason: '支出没有关联');
      expect(rows.last['linked_bill_ids'], '[$eid]',
          reason: 'v4 的单笔关联原样搬成单元素数组，统计口径不变');

      await db.close();
    });

    test('升级脚本可重复执行（幂等）', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await createV4(db);
      final eid = await insertBill(db, {
        'type': 0, 'amount': 1000.0, 'category': '餐饮', 'note': '',
        'date': 20260910, 'created_at': 1000, 'account': kDefaultAccount,
      });
      await insertBill(db, {
        'type': 1, 'amount': 800.0, 'category': '报销', 'note': '',
        'date': 20260912, 'created_at': 2000, 'account': kDefaultAccount,
        'linked_bill_id': eid,
      });

      await upgradeToV5(db);
      await upgradeToV5(db);
      await upgradeToV5(db);

      final cols = await db.rawQuery('PRAGMA table_info($billsTable)');
      expect(cols.where((c) => c['name'] == 'linked_bill_ids').length, 1,
          reason: '重复迁移不应把列加两遍');
      final rows = await db.query(billsTable, orderBy: 'id ASC');
      expect(rows.last['linked_bill_ids'], '[$eid]', reason: '也不该重复搬数据');

      await db.close();
    });

    test('数组成员判断：查 id=1 不会误伤 id=13', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await createV4(db);
      await upgradeToV5(db);

      // 一笔报销同时关联 1 和 13
      await insertBill(db, {
        'type': 1, 'amount': 500.0, 'category': '报销', 'note': '',
        'date': 20260912, 'created_at': 2000, 'account': kDefaultAccount,
        'linked_bill_ids': '[1,13]',
      });

      final hit1 = await db.rawQuery(
        'SELECT id FROM $billsTable WHERE type = 1 AND linked_bill_ids IS NOT NULL '
        'AND $idsLikeExpr LIKE ?',
        ['%,1,%'],
      );
      final hit13 = await db.rawQuery(
        'SELECT id FROM $billsTable WHERE type = 1 AND linked_bill_ids IS NOT NULL '
        'AND $idsLikeExpr LIKE ?',
        ['%,13,%'],
      );

      expect(hit1.length, 1, reason: '查 1 应命中（1 确实在数组里）');
      expect(hit13.length, 1, reason: '查 13 应命中（13 确实在数组里）');
      // 反过来验证精确性：只含 13 的数组不能被查 1 命中
      await insertBill(db, {
        'type': 1, 'amount': 100.0, 'category': '报销', 'note': '',
        'date': 20260913, 'created_at': 3000, 'account': kDefaultAccount,
        'linked_bill_ids': '[13]',
      });
      final hit1Again = await db.rawQuery(
        'SELECT id FROM $billsTable WHERE type = 1 AND linked_bill_ids IS NOT NULL '
        'AND $idsLikeExpr LIKE ?',
        ['%,1,%'],
      );
      expect(hit1Again.length, 1,
          reason: '只有 [1,13] 那条该命中；[13] 不能被查 1 误伤');

      await db.close();
    });

    test('删除被关联的支出：只从数组里摘掉该 id，其余关联保留', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await createV4(db);
      await upgradeToV5(db);

      final e1 = await insertBill(db, {
        'type': 0, 'amount': 1000.0, 'category': '餐饮', 'note': '',
        'date': 20260910, 'created_at': 1000, 'account': kDefaultAccount,
      });
      final e2 = await insertBill(db, {
        'type': 0, 'amount': 500.0, 'category': '交通', 'note': '',
        'date': 20260911, 'created_at': 1100, 'account': kDefaultAccount,
      });
      final iid = await insertBill(db, {
        'type': 1, 'amount': 1500.0, 'category': '报销', 'note': '',
        'date': 20260912, 'created_at': 2000, 'account': kDefaultAccount,
        'linked_bill_ids': '[$e1,$e2]',
      });

      // 复刻 BillDatabase._detachExpenseInTxn 的两步：LIKE 定位 → 摘除 → 回写
      final hit = await db.rawQuery(
        'SELECT id, linked_bill_ids FROM $billsTable WHERE type = 1 '
        'AND linked_bill_ids IS NOT NULL AND $idsLikeExpr LIKE ?',
        ['%,$e1,%'],
      );
      expect(hit.length, 1, reason: '应定位到那条报销收入');
      final ids = BillRecord.decodeLinkedIds(hit.first['linked_bill_ids'])
        ..remove(e1);
      await db.update(billsTable, {'linked_bill_ids': BillRecord.encodeLinkedIds(ids)},
          where: 'id = ?', whereArgs: [iid]);
      await db.delete(billsTable, where: 'id = ?', whereArgs: [e1]);

      final income = (await db.query(billsTable, where: 'id = ?', whereArgs: [iid])).first;
      expect(income['linked_bill_ids'], '[$e2]',
          reason: '只摘掉被删的那笔，另一笔关联必须保留');
      final expenses = await db.query(billsTable, where: 'type = 0');
      expect(expenses.length, 1, reason: '只删掉那一笔支出');

      await db.close();
    });
  });

  group('模型层：linkedBillIds 编解码', () {
    test('空列表编码为 null，表示"没有关联"', () {
      expect(BillRecord.encodeLinkedIds(const []), isNull);
    });

    test('多笔 id 往返编码解码一致', () {
      const ids = [1, 3, 7];
      final encoded = BillRecord.encodeLinkedIds(ids);
      expect(encoded, '[1,3,7]');
      expect(BillRecord.decodeLinkedIds(encoded), ids);
    });

    test('脏输入容错：不抛异常，非法值回落为空列表', () {
      expect(BillRecord.decodeLinkedIds(null), isEmpty);
      expect(BillRecord.decodeLinkedIds(''), isEmpty);
      expect(BillRecord.decodeLinkedIds('null'), isEmpty);
      expect(BillRecord.decodeLinkedIds('[]'), isEmpty);
      expect(BillRecord.decodeLinkedIds('['), isEmpty);
      expect(BillRecord.decodeLinkedIds('[abc]'), isEmpty);
      expect(BillRecord.decodeLinkedIds('[1,x,3]'), [1, 3],
          reason: '数组里混进脏元素时，跳过它而不是整条作废');
      // 裸数字也认：万一库里被手写过 `42` 而不是 `[42]`，
      // 宽松解析能把关联救回来，比默默丢掉强
      expect(BillRecord.decodeLinkedIds(42), [42]);
      expect(BillRecord.decodeLinkedIds('42'), [42]);
    });

    test('fromMap 读 linked_bill_ids，并兜底旧的 linked_bill_id', () {
      final base = <String, Object?>{
        'id': 1,
        'type': 1,
        'amount': 800.0,
        'category': '报销',
        'account': kDefaultAccount,
        'note': '',
        'date': 20260912,
        'created_at': 1000,
      };

      final modern = BillRecord.fromMap({...base, 'linked_bill_ids': '[2,5]'});
      expect(modern.linkedBillIds, [2, 5]);

      final legacy = BillRecord.fromMap({...base, 'linked_bill_id': 9});
      expect(legacy.linkedBillIds, [9],
          reason: '漏迁移的快照靠旧列兜底，不能丢关联');

      final plain = BillRecord.fromMap(base);
      expect(plain.linkedBillIds, isEmpty);
      expect(plain.isReimbursement, isFalse);
    });

    test('toMap / fromMap 往返保持多笔关联', () {
      final r = BillRecord(
        id: 3,
        type: BillType.income,
        amount: 1200,
        category: '报销',
        date: DateTime(2026, 9, 12),
        createdAt: DateTime(2026, 9, 12, 9),
        linkedBillIds: const [1, 2],
      );
      expect(r.isReimbursement, isTrue);
      expect(BillRecord.fromMap(r.toMap()).linkedBillIds, [1, 2]);
    });

    test('copyWith 可改关联、可清除关联', () {
      final r = BillRecord(
        id: 3,
        type: BillType.income,
        amount: 1200,
        category: '报销',
        date: DateTime(2026, 9, 12),
        createdAt: DateTime(2026, 9, 12, 9),
        linkedBillIds: const [1, 2],
      );

      expect(r.copyWith(linkedBillIds: const [4]).linkedBillIds, [4]);
      expect(r.copyWith(clearLinked: true).linkedBillIds, isEmpty);
      expect(r.copyWith(amount: 999).linkedBillIds, [1, 2],
          reason: '改别的字段不该顺手改掉关联');
    });
  });
}
