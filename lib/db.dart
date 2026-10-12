import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// 账户 + 该账户的收支与余额汇总
///
/// [expense]/[income] 只统计账单；[transferIn]/[transferOut] 来自转账表。
/// 真实余额 = 期初 + 收入 + 转入 − 支出 − 转出。
class AccountSummary {
  final String account;
  final double expense;
  final double income;

  /// 期初余额
  final double initialBalance;

  /// 转入 / 转出合计
  final double transferIn;
  final double transferOut;

  const AccountSummary({
    required this.account,
    this.expense = 0,
    this.income = 0,
    this.initialBalance = 0,
    this.transferIn = 0,
    this.transferOut = 0,
  });

  /// 记账以来的净额（不含期初与转账）
  double get net => income - expense;

  /// 真实余额：这才是"钱包里现在有多少钱"
  double get balance =>
      initialBalance + income + transferIn - expense - transferOut;
}

/// 本地 SQLite 数据访问层
class BillDatabase {
  BillDatabase._();
  static final BillDatabase instance = BillDatabase._();

  static const _dbName = 'ledger_book.db';

  /// v1: bills(id, type, amount, category, note, date, created_at)
  /// v2: bills 增加 account 列；新增 accounts 表
  /// v3: accounts 增加 initial_balance 列；新增 transfers 表（账户间转账）
  /// v4: bills 增加 linked_bill_id 列（报销/分摊收入关联到被冲减的支出）
  /// v5: bills 增加 linked_bill_ids 列，关联从"单笔"升级为"多笔"
  ///     （JSON 数组字符串，如 `[1,3,7]`）。v4 的 linked_bill_id 列保留不删，
  ///     老库由 _upgradeToV5 把旧值搬进新列后彻底弃用。
  /// v6: 新增 settings 表（key-value），存放月总预算与预算周期起始日
  static const _dbVersion = 6;

  static const tableName = 'bills';
  static const accountTable = 'accounts';
  static const transferTable = 'transfers';

  /// 设置表：key-value 存全局配置（目前只有预算相关两项）。
  /// 用表而不是 SharedPreferences：项目的数据出口只有 SQLite 一处，
  /// 备份/迁移/测试都能走同一套基建，不会出现"偏好设置散落两处"。
  static const settingsTable = 'settings';
  static const _kMonthlyBudget = 'monthly_budget';
  static const _kBudgetStartDay = 'budget_start_day';

  /// linked_bill_ids 的 SQL 成员判断表达式。
  ///
  /// 把 `[1,3,7]` 规范化成 `,1,3,7,`，再用 `%,<id>,%` 匹配，做到**精确**命中：
  /// 查 id=3 时 `,1,3,7,` 命中，而 `,1,13,7,` 不命中。
  /// 绝不能直接 `LIKE '%3%'` —— 那会把 13、23、30 一起误伤， silently 改错账。
  /// 代价是该条件用不上索引（JSON 数组本身也没法建有效索引），
  /// 所以只用于"按单笔支出反查报销"这类低频路径，不放在列表主查询里。
  static const _idsLikeExpr =
      "',' || replace(replace(replace(linked_bill_ids, '[', ''), ']', ''), ' ', '') || ','";

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, _dbName);
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await _createBillsTable(db);
        await _createAccountsTable(db);
        await _createTransfersTable(db);
        await _createSettingsTable(db);
        // 首次使用即写入内置账户，避免用户面对空账户列表
        await _seedAccounts(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _upgradeToV2(db);
        }
        if (oldVersion < 3) {
          await _upgradeToV3(db);
        }
        if (oldVersion < 4) {
          await _upgradeToV4(db);
        }
        if (oldVersion < 5) {
          await _upgradeToV5(db);
        }
        if (oldVersion < 6) {
          await _upgradeToV6(db);
        }
      },
    );
  }

  // ---------------- 建表 ----------------

  Future<void> _createBillsTable(Database db) async {
    await db.execute('''
      CREATE TABLE $tableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type INTEGER NOT NULL,
        amount REAL NOT NULL,
        category TEXT NOT NULL,
        account TEXT NOT NULL DEFAULT '$kDefaultAccount',
        note TEXT NOT NULL DEFAULT '',
        date INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        linked_bill_ids TEXT
      )
    ''');
    // 日期、类型、账户是最常用的查询维度，建索引避免数据量大后变慢
    await db.execute('CREATE INDEX idx_bills_date ON $tableName (date)');
    await db.execute(
        'CREATE INDEX idx_bills_type_date ON $tableName (type, date)');
    await db.execute(
        'CREATE INDEX idx_bills_account ON $tableName (account)');
    // linked_bill_ids 是 JSON 数组，没法建有效索引；反查"谁报销了这笔支出"
    // 走 [_idsLikeExpr] 的逗号包裹精确匹配，见下方说明
  }

  Future<void> _createAccountsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $accountTable (
        name TEXT PRIMARY KEY,
        icon INTEGER NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        initial_balance REAL NOT NULL DEFAULT 0
      )
    ''');
  }

  Future<void> _createTransfersTable(Database db) async {
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
    // 转出/转入账户都是高频过滤维度
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_transfers_from ON $transferTable (from_account)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_transfers_to ON $transferTable (to_account)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_transfers_date ON $transferTable (date)');
  }

  Future<void> _createSettingsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $settingsTable (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  // ---------------- 迁移 ----------------

  /// v1 → v2：给 bills 补 account 列，新建 accounts 表。
  ///
  /// 写成幂等的：SQLite 的 `ALTER TABLE ADD COLUMN` 没有 `IF NOT EXISTS`，
  /// 一旦迁移中途失败被重跑，裸执行会以 "duplicate column name" 直接崩掉，
  /// 用户就卡在启动页了。所以先查 pragma 判断列是否已存在。
  Future<void> _upgradeToV2(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info($tableName)');
    final hasAccount = cols.any((c) => (c['name'] as String?) == 'account');

    if (!hasAccount) {
      // 默认值保证已有记录都归入"现金"，不丢数据
      await db.execute(
        "ALTER TABLE $tableName ADD COLUMN account TEXT NOT NULL DEFAULT '$kDefaultAccount'");
    }

    await _createAccountsTable(db);
    await _seedAccounts(db);
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_bills_account ON $tableName (account)');
  }

  /// v2 → v3：accounts 补 initial_balance 列，新建 transfers 表。
  ///
  /// 同样必须幂等 —— 理由见 [_upgradeToV2]。
  /// 老库补的列默认 0，即"不设期初余额"，账户余额口径与升级前完全一致，
  /// 不会因为这次升级让已有用户的数字凭空变化。
  Future<void> _upgradeToV3(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info($accountTable)');
    final hasInitial =
        cols.any((c) => (c['name'] as String?) == 'initial_balance');

    if (!hasInitial) {
      await db.execute(
          'ALTER TABLE $accountTable ADD COLUMN initial_balance REAL NOT NULL DEFAULT 0');
    }

    await _createTransfersTable(db);
  }

  /// v3 → v4：bills 补 linked_bill_id 列，支持"报销/分摊收入关联到支出"。
  ///
  /// 同样必须幂等 —— 理由见 [_upgradeToV2]。
  /// 老库补的列默认 NULL，即"没有关联"，所有既有账单的统计口径
  /// 与升级前完全一致，不会因为这次升级让已有用户的数字凭空变化。
  Future<void> _upgradeToV4(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info($tableName)');
    final hasLinked =
        cols.any((c) => (c['name'] as String?) == 'linked_bill_id');

    if (!hasLinked) {
      // 不加 NOT NULL DEFAULT：NULL 才表示"这条记录没有关联任何支出"
      await db.execute(
          'ALTER TABLE $tableName ADD COLUMN linked_bill_id INTEGER');
    }

    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_bills_linked ON $tableName (linked_bill_id)');
  }

  /// v4 → v5：bills 补 linked_bill_ids 列，报销关联从"单笔"升级为"多笔"。
  ///
  /// 同样必须幂等 —— 理由见 [_upgradeToV2]。
  /// 旧列 linked_bill_id **不删**：Android 低版本系统的 SQLite 不支持
  /// `ALTER TABLE DROP COLUMN`，删列要把整表重建再搬数据，风险远大于收益。
  /// 搬完数据后旧列就没人读了，留着不碍事。
  Future<void> _upgradeToV5(Database db) async {
    final cols = await db.rawQuery('PRAGMA table_info($tableName)');
    final hasNew = cols.any((c) => (c['name'] as String?) == 'linked_bill_ids');

    if (!hasNew) {
      await db.execute('ALTER TABLE $tableName ADD COLUMN linked_bill_ids TEXT');

      // 把 v4 的单笔关联原样搬成 JSON 数组：`linked_bill_id = 7` → `'[7]'`。
      // 搬完后统计口径与升级前完全一致，已有用户的数字不会凭空变化。
      final rows = await db.rawQuery(
          'SELECT id, linked_bill_id FROM $tableName WHERE linked_bill_id IS NOT NULL');
      if (rows.isNotEmpty) {
        final batch = db.batch();
        for (final r in rows) {
          final lid = r['linked_bill_id'] as int?;
          if (lid == null) continue;
          batch.update(
            tableName,
            {'linked_bill_ids': '[$lid]'},
            where: 'id = ?',
            whereArgs: [r['id']],
          );
        }
        await batch.commit(noResult: true);
      }
    }
  }

  /// v5 → v6：新建 settings 表，存放月总预算与预算周期起始日。
  ///
  /// 幂等理由同 [_upgradeToV2]。老库升级后表为空，
  /// 即"未设置预算"，分析页不展示预算卡——与升级前完全一致。
  Future<void> _upgradeToV6(Database db) async {
    await _createSettingsTable(db);
  }

  Future<void> _seedAccounts(Database db) async {
    final batch = db.batch();
    for (int i = 0; i < kBuiltinAccounts.length; i++) {
      final a = kBuiltinAccounts[i];
      batch.insert(
        accountTable,
        {
          'name': a.name,
          'icon': a.icon.codePoint,
          'sort_order': i,
          'initial_balance': a.initialBalance,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  // ---------------- 账户 ----------------

  Future<List<AccountDef>> loadAccounts() async {
    final db = await database;
    final rows = await db.query(accountTable,
        orderBy: 'sort_order ASC, name ASC');
    if (rows.isEmpty) {
      await _seedAccounts(db);
      final again = await db.query(accountTable,
          orderBy: 'sort_order ASC, name ASC');
      return again.map(_accountFromRow).toList();
    }
    return rows.map(_accountFromRow).toList();
  }

  AccountDef _accountFromRow(Map<String, Object?> r) => AccountDef(
        (r['name'] as String?) ?? kDefaultAccount,
        _iconFromCode((r['icon'] as num?)?.toInt()),
        initialBalance: ((r['initial_balance'] as num?) ?? 0).toDouble(),
      );

  /// 把 codePoint 还原成 IconData
  IconData _iconFromCode(int? code) {
    if (code == null) return kFallbackAccountIcon;
    for (final a in kBuiltinAccounts) {
      if (a.icon.codePoint == code) return a.icon;
    }
    for (final i in kAccountIconChoices) {
      if (i.codePoint == code) return i;
    }
    return kFallbackAccountIcon;
  }

  Future<void> addAccount(String name, IconData icon) async {
    final db = await database;
    final maxRow = await db.rawQuery(
        'SELECT MAX(sort_order) AS m FROM $accountTable');
    final next = ((maxRow.first['m'] as num?)?.toInt() ?? -1) + 1;
    await db.insert(
      accountTable,
      {'name': name, 'icon': icon.codePoint, 'sort_order': next},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateAccountIcon(String name, IconData icon) async {
    final db = await database;
    await db.update(accountTable, {'icon': icon.codePoint},
        where: 'name = ?', whereArgs: [name]);
  }

  /// 设置账户期初余额
  Future<void> updateAccountInitialBalance(String name, double value) async {
    final db = await database;
    await db.update(accountTable, {'initial_balance': value},
        where: 'name = ?', whereArgs: [name]);
  }

  /// 该账户下已有多少条账单，删除前用于提示
  Future<int> countByAccount(String account) async {
    final db = await database;
    final r = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM $tableName WHERE account = ?', [account]);
    return (r.first['c'] as num).toInt();
  }

  /// 该账户参与了多少笔转账（转出或转入），删除前用于提示
  Future<int> countTransfersByAccount(String account) async {
    final db = await database;
    final r = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM $transferTable WHERE from_account = ? OR to_account = ?',
      [account, account],
    );
    return (r.first['c'] as num).toInt();
  }

  /// 删除账户；若该账户已无账单且无转账才会真正删除，否则返回 false
  Future<bool> deleteAccount(String name, {bool deleteBills = false}) async {
    final db = await database;
    final used = await countByAccount(name);
    final linked = await countTransfersByAccount(name);
    if ((used > 0 || linked > 0) && !deleteBills) return false;

    if (deleteBills) {
      // 删账户时一并删掉其名下账单与转账，属于破坏性操作，调用方需二次确认
      await db.delete(tableName, where: 'account = ?', whereArgs: [name]);
      await db.delete(transferTable,
          where: 'from_account = ? OR to_account = ?',
          whereArgs: [name, name]);
    }
    await db.delete(accountTable, where: 'name = ?', whereArgs: [name]);
    return true;
  }

  /// 账户重命名：同时更新其名下所有账单与转账，保证历史数据不孤立
  Future<void> renameAccount(String oldName, String newName) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update(accountTable, {'name': newName},
          where: 'name = ?', whereArgs: [oldName]);
      await txn.update(tableName, {'account': newName},
          where: 'account = ?', whereArgs: [oldName]);
      await txn.update(transferTable, {'from_account': newName},
          where: 'from_account = ?', whereArgs: [oldName]);
      await txn.update(transferTable, {'to_account': newName},
          where: 'to_account = ?', whereArgs: [oldName]);
    });
  }

  /// 当前数据里出现过的账户名（含未被账户表记录的）
  Future<List<String>> accountsInUse() async {
    final db = await database;
    final rows = await db.rawQuery(
        'SELECT DISTINCT account FROM $tableName ORDER BY account ASC');
    return rows.map((e) => (e['account'] as String?) ?? kDefaultAccount).toList();
  }

  // ---------------- 预算 ----------------

  /// 读取预算设置。表为空或值为脏数据时返回"未设置"（monthlyBudget = 0）
  Future<BudgetSettings> loadBudget() async {
    final db = await database;
    final rows = await db.query(settingsTable);
    final map = <String, String>{};
    for (final r in rows) {
      final k = r['key'] as String?;
      final v = r['value'] as String?;
      if (k != null && v != null) map[k] = v;
    }
    return BudgetSettings.fromRows(map);
  }

  /// 保存预算设置。两条配置一起写，用事务避免只写进去一半
  Future<void> saveBudget(BudgetSettings b) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        settingsTable,
        {'key': _kMonthlyBudget, 'value': b.monthlyBudget.toString()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        settingsTable,
        {'key': _kBudgetStartDay, 'value': b.startDay.toString()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  // ---------------- 报销 / 分摊关联 ----------------

  /// 查询"报销了某笔支出"的所有收入记录（该支出在其关联数组里）
  Future<List<BillRecord>> queryIncomesLinkedTo(int billId) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT * FROM $tableName '
      'WHERE type = 1 AND linked_bill_ids IS NOT NULL '
      'AND $_idsLikeExpr LIKE ? '
      'ORDER BY date ASC, created_at ASC',
      ['%,$billId,%'],
    );
    return rows.map(BillRecord.fromMap).toList();
  }

  /// 批量查询：一批支出分别被报销了多少钱（原始关联金额合计）
  ///
  /// 返回 `支出id -> 报销合计`。用于选择器里提示"这笔消费已被报销多少"，
  /// 避免每条记录都单独查一次库（N+1）。
  ///
  /// 注意这里给的是**原始金额合计**，不是统计页那种按比例封顶后的分摊额：
  /// 本方法只服务于输入时的参考提示，精确分摊由 [StatsResult] 负责。
  /// JSON 数组没法在 SQL 里高效拆分，这里用一次 `type = 1` 的窄扫描换取
  /// 只发一条查询——收入行数远少于全部账单，个人账本完全无压力。
  ///
  /// [exceptIncomeId] 用于编辑时排除自己，否则"已报销"会把当前这条也算进去。
  Future<Map<int, double>> linkedIncomeTotals(
    Set<int> billIds, {
    int? exceptIncomeId,
  }) async {
    if (billIds.isEmpty) return {};
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT id, amount, linked_bill_ids FROM $tableName '
      'WHERE type = 1 AND linked_bill_ids IS NOT NULL',
    );
    final map = <int, double>{};
    for (final r in rows) {
      final iid = r['id'] as int?;
      if (iid == null || iid == exceptIncomeId) continue;
      final amount = ((r['amount'] as num?) ?? 0).toDouble();
      for (final eid in BillRecord.decodeLinkedIds(r['linked_bill_ids'])) {
        if (!billIds.contains(eid)) continue;
        map[eid] = (map[eid] ?? 0) + amount;
      }
    }
    return map;
  }

  /// 用于下拉选择的候选支出账单（按日期倒序）
  ///
  /// [excludeId] 用于编辑时排除自己。只返回支出类型。
  Future<List<BillRecord>> queryExpenseCandidates({
    String? account,
    int? excludeId,
    int limit = 200,
  }) async {
    final db = await database;
    final args = _accountArgs(account);
    final where = StringBuffer('type = 0');
    final whereArgs = <Object?>[];
    if (args != null) {
      where.write(' AND account = ?');
      whereArgs.add(args.first);
    }
    if (excludeId != null) {
      where.write(' AND id != ?');
      whereArgs.add(excludeId);
    }
    final rows = await db.query(
      tableName,
      where: where.toString(),
      whereArgs: whereArgs,
      orderBy: 'date DESC, created_at DESC',
      limit: limit,
    );
    return rows.map(BillRecord.fromMap).toList();
  }

  // ---------------- 增删改 ----------------

  Future<int> insert(BillRecord r) async {
    final db = await database;
    return db.insert(tableName, r.toMap());
  }

  Future<int> update(BillRecord r) async {
    final db = await database;
    return db.update(tableName, r.toMap(),
        where: 'id = ?', whereArgs: [r.id]);
  }

  /// 删除账单。
  ///
  /// 若删的是**被报销过的支出**，那些收入会失去一个冲减对象。
  /// 这里只把该 id 从它们的关联数组里摘掉——一笔报销往往同时关联多笔支出，
  /// 删掉其中一笔消费，不该让其余关联一起失效。摘掉后若还有其他关联就继续合并，
  /// 若无则退化成普通收入，而不是被一起删掉。
  /// 理由：钱确实到账了，删支出不该顺手抹掉这笔钱，
  /// 那会让用户的总收入凭空少一笔。UI 侧会在删除前提示这一点。
  Future<int> delete(int id) async {
    final db = await database;
    return db.transaction((txn) async {
      await _detachExpenseInTxn(txn, id);
      return txn.delete(tableName, where: 'id = ?', whereArgs: [id]);
    });
  }

  /// 事务内：把某笔支出从所有报销收入的关联数组里摘掉，返回受影响的收入条数。
  ///
  /// 只摘这一个 id 而不是整条置空：一笔报销往往同时关联多笔支出，
  /// 删掉其中一笔消费，不该让其余关联一起失效。
  Future<int> _detachExpenseInTxn(Transaction txn, int expenseId) async {
    final rows = await txn.rawQuery(
      'SELECT id, linked_bill_ids FROM $tableName '
      'WHERE type = 1 AND linked_bill_ids IS NOT NULL '
      'AND $_idsLikeExpr LIKE ?',
      ['%,$expenseId,%'],
    );
    for (final r in rows) {
      final ids = BillRecord.decodeLinkedIds(r['linked_bill_ids'])
        ..remove(expenseId);
      await txn.update(
        tableName,
        {'linked_bill_ids': BillRecord.encodeLinkedIds(ids)},
        where: 'id = ?',
        whereArgs: [r['id']],
      );
    }
    return rows.length;
  }

  /// 解除某笔支出的所有报销关联（把关联收入退化为普通收入）
  Future<int> unlinkIncomesFor(int billId) async {
    final db = await database;
    return db.transaction((txn) => _detachExpenseInTxn(txn, billId));
  }

  // ---------------- 查询 ----------------

  /// 组装 account 过滤条件；account 为 null 或 [kAllAccounts] 时不限账户
  List<Object?>? _accountArgs(String? account) {
    if (account == null || account == kAllAccounts) return null;
    return [account];
  }

  Future<List<BillRecord>> queryAll({String? account}) async {
    final db = await database;
    final args = _accountArgs(account);
    final rows = await db.query(
      tableName,
      where: args == null ? null : 'account = ?',
      whereArgs: args,
      orderBy: 'date DESC, created_at DESC',
    );
    return rows.map(BillRecord.fromMap).toList();
  }

  /// 按日期区间查询（含首尾），可按账户过滤
  Future<List<BillRecord>> queryBetween(
    DateTime from,
    DateTime to, {
    String? account,
  }) async {
    final db = await database;
    final lo = BillRecord.dateToInt(from);
    final hi = BillRecord.dateToInt(to);
    final args = _accountArgs(account);

    final where = args == null
        ? 'date >= ? AND date <= ?'
        : 'date >= ? AND date <= ? AND account = ?';
    final whereArgs = args == null ? [lo, hi] : [lo, hi, args.first];

    final rows = await db.query(
      tableName,
      where: where,
      whereArgs: whereArgs,
      orderBy: 'date DESC, created_at DESC',
    );
    return rows.map(BillRecord.fromMap).toList();
  }

  /// 按年月查询（month: 1-12）
  Future<List<BillRecord>> queryMonth(int year, int month,
      {String? account}) async {
    final lo = year * 10000 + month * 100 + 1;
    final hi = year * 10000 + month * 100 + 31;
    final db = await database;
    final args = _accountArgs(account);

    final where = args == null
        ? 'date >= ? AND date <= ?'
        : 'date >= ? AND date <= ? AND account = ?';
    final whereArgs = args == null ? [lo, hi] : [lo, hi, args.first];

    final rows = await db.query(
      tableName,
      where: where,
      whereArgs: whereArgs,
      orderBy: 'date DESC, created_at DESC',
    );
    return rows.map(BillRecord.fromMap).toList();
  }

  /// 按年查询
  Future<List<BillRecord>> queryYear(int year, {String? account}) async {
    final db = await database;
    final args = _accountArgs(account);

    final where = args == null
        ? 'date >= ? AND date <= ?'
        : 'date >= ? AND date <= ? AND account = ?';
    final whereArgs = args == null
        ? [year * 10000 + 101, year * 10000 + 1231]
        : [year * 10000 + 101, year * 10000 + 1231, args.first];

    final rows = await db.query(
      tableName,
      where: where,
      whereArgs: whereArgs,
      orderBy: 'date DESC, created_at DESC',
    );
    return rows.map(BillRecord.fromMap).toList();
  }

  Future<BillRecord?> findById(int id) async {
    final db = await database;
    final rows =
        await db.query(tableName, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return BillRecord.fromMap(rows.first);
  }

  /// 该月已有记录的日期集合，用于日历页标记"有账的日子"
  Future<Set<int>> daysWithRecords(int year, int month,
      {String? account}) async {
    final lo = year * 10000 + month * 100 + 1;
    final hi = year * 10000 + month * 100 + 31;
    final db = await database;
    final args = _accountArgs(account);

    final rows = await db.rawQuery(
      args == null
          ? 'SELECT DISTINCT date FROM $tableName WHERE date >= ? AND date <= ?'
          : 'SELECT DISTINCT date FROM $tableName WHERE date >= ? AND date <= ? AND account = ?',
      args == null ? [lo, hi] : [lo, hi, args.first],
    );
    return rows.map((e) => e['date'] as int).toSet();
  }

  /// 全部有记录的月份（YYYYMM），用于月份选择器
  Future<List<int>> monthsWithRecords({String? account}) async {
    final db = await database;
    final args = _accountArgs(account);
    final rows = await db.rawQuery(
      args == null
          ? 'SELECT DISTINCT date / 100 AS ym FROM $tableName ORDER BY ym DESC'
          : 'SELECT DISTINCT date / 100 AS ym FROM $tableName WHERE account = ? ORDER BY ym DESC',
      args,
    );
    return rows.map((e) => (e['ym'] as num).toInt()).toList();
  }

  Future<int> count({String? account}) async {
    final db = await database;
    final args = _accountArgs(account);
    final r = await db.rawQuery(
      args == null
          ? 'SELECT COUNT(*) AS c FROM $tableName'
          : 'SELECT COUNT(*) AS c FROM $tableName WHERE account = ?',
      args,
    );
    return (r.first['c'] as num).toInt();
  }

  /// 按账户汇总指定区间的收支，用于账户总览
  ///
  /// 汇总口径：
  /// - [AccountSummary.expense]/[income] 仅来自 [tableName]（账单表）
  /// - [AccountSummary.transferIn]/[transferOut] 来自 [transferTable]
  /// - [AccountSummary.initialBalance] 是账户的期初余额，**不受区间限制**
  ///   （它是一个存量的起点值，不该随时间区间变化）
  ///
  /// 这样 [AccountSummary.balance] 才是"这个钱包现在有多少钱"。
  Future<List<AccountSummary>> summaryByAccount(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final lo = BillRecord.dateToInt(from);
    final hi = BillRecord.dateToInt(to);

    final rows = await db.rawQuery('''
      SELECT account,
             SUM(CASE WHEN type = 0 THEN amount ELSE 0 END) AS exp,
             SUM(CASE WHEN type = 1 THEN amount ELSE 0 END) AS inc
      FROM $tableName
      WHERE date >= ? AND date <= ?
      GROUP BY account
    ''', [lo, hi]);

    // 转账按账户拆成转入/转出两组
    final transferMap = await transferTotalsByAccount(from, to);

    // 期初余额按账户取，注意这里不带日期条件
    final initRows = await db.query(accountTable, columns: ['name', 'initial_balance']);
    final initMap = <String, double>{
      for (final r in initRows)
        ((r['name'] as String?) ?? kDefaultAccount):
            ((r['initial_balance'] as num?) ?? 0).toDouble(),
    };

    final result = <String, AccountSummary>{};

    for (final r in rows) {
      final acc = (r['account'] as String?) ?? kDefaultAccount;
      final t = transferMap[acc];
      result[acc] = AccountSummary(
        account: acc,
        expense: ((r['exp'] as num?) ?? 0).toDouble(),
        income: ((r['inc'] as num?) ?? 0).toDouble(),
        initialBalance: initMap[acc] ?? 0,
        transferIn: t == null ? 0 : t[0],
        transferOut: t == null ? 0 : t[1],
      );
    }

    // 没有账单但有期初余额或转账的账户也要出现，
    // 否则"只设了期初余额、还没记账"的账户会在总览里凭空消失
    for (final a in initRows) {
      final acc = (a['name'] as String?) ?? kDefaultAccount;
      if (result.containsKey(acc)) continue;
      final t = transferMap[acc];
      final init = initMap[acc] ?? 0;
      if (init == 0 && t == null) continue;
      result[acc] = AccountSummary(
        account: acc,
        initialBalance: init,
        transferIn: t == null ? 0 : t[0],
        transferOut: t == null ? 0 : t[1],
      );
    }

    final list = result.values.toList()
      ..sort((a, b) => a.account.compareTo(b.account));
    return list;
  }

  Future<void> clearAll() async {
    final db = await database;
    await db.delete(tableName);
  }

  /// 批量插入
  Future<void> insertBatch(List<BillRecord> list) async {
    if (list.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final r in list) {
      batch.insert(tableName, r.toMap());
    }
    await batch.commit(noResult: true);
  }

  // ---------------- 转账 ----------------

  Future<int> insertTransfer(TransferRecord t) async {
    final db = await database;
    return db.insert(transferTable, t.toMap());
  }

  Future<int> updateTransfer(TransferRecord t) async {
    final db = await database;
    return db.update(transferTable, t.toMap(),
        where: 'id = ?', whereArgs: [t.id]);
  }

  Future<int> deleteTransfer(int id) async {
    final db = await database;
    return db.delete(transferTable, where: 'id = ?', whereArgs: [id]);
  }

  Future<TransferRecord?> findTransferById(int id) async {
    final db = await database;
    final rows = await db
        .query(transferTable, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return TransferRecord.fromMap(rows.first);
  }

  /// 按日期区间查询转账（含首尾）。
  /// 传了 account 时，只要该账户是转出方或转入方，这条转账就应被列出。
  Future<List<TransferRecord>> queryTransfersBetween(
    DateTime from,
    DateTime to, {
    String? account,
  }) async {
    final db = await database;
    final lo = BillRecord.dateToInt(from);
    final hi = BillRecord.dateToInt(to);
    final args = _accountArgs(account);

    final where = args == null
        ? 'date >= ? AND date <= ?'
        : 'date >= ? AND date <= ? AND (from_account = ? OR to_account = ?)';
    final whereArgs =
        args == null ? [lo, hi] : [lo, hi, args.first, args.first];

    final rows = await db.query(
      transferTable,
      where: where,
      whereArgs: whereArgs,
      orderBy: 'date DESC, created_at DESC',
    );
    return rows.map(TransferRecord.fromMap).toList();
  }

  /// 按账户统计指定区间的转入/转出合计
  Future<Map<String, List<double>>> transferTotalsByAccount(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final lo = BillRecord.dateToInt(from);
    final hi = BillRecord.dateToInt(to);

    final outRows = await db.rawQuery('''
      SELECT from_account AS acc, SUM(amount) AS total
      FROM $transferTable WHERE date >= ? AND date <= ?
      GROUP BY from_account
    ''', [lo, hi]);
    final inRows = await db.rawQuery('''
      SELECT to_account AS acc, SUM(amount) AS total
      FROM $transferTable WHERE date >= ? AND date <= ?
      GROUP BY to_account
    ''', [lo, hi]);

    final map = <String, List<double>>{};
    for (final r in outRows) {
      final acc = (r['acc'] as String?) ?? kDefaultAccount;
      final v = ((r['total'] as num?) ?? 0).toDouble();
      map.putIfAbsent(acc, () => [0, 0])[1] = v; // [转入, 转出]
    }
    for (final r in inRows) {
      final acc = (r['acc'] as String?) ?? kDefaultAccount;
      final v = ((r['total'] as num?) ?? 0).toDouble();
      map.putIfAbsent(acc, () => [0, 0])[0] = v;
    }
    return map;
  }
}
