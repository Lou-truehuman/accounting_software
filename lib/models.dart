import 'package:flutter/material.dart';

/// 账单类型：支出 / 收入
enum BillType {
  expense, // 支出
  income, // 收入
}

extension BillTypeX on BillType {
  /// 存入数据库的整型值
  int get value => this == BillType.expense ? 0 : 1;

  String get label => this == BillType.expense ? '支出' : '收入';

  static BillType fromValue(int v) => v == 0 ? BillType.expense : BillType.income;
}

/// 一条账单记录
class BillRecord {
  final int? id;
  final BillType type;
  final double amount; // 金额，始终存正数，方向由 type 决定
  final String category; // 分类名称
  final String account; // 账户名称，如"微信""支付宝""招行储蓄卡"
  final String note; // 备注
  final DateTime date; // 消费发生日期（仅日期部分有意义）
  final DateTime createdAt;

  /// 报销/分摊关联：这笔收入冲减了哪些**支出**账单的 id（可多笔）。
  ///
  /// 只有收入记录会带上它，含义是"这笔收入是对这些支出的报销或分摊"。
  ///
  /// 为什么存在收入侧而不是支出侧：
  /// 真实场景两个方向都会出现——一笔支出可能被**分次报销**（先报一半再报一半），
  /// 一笔报销也可能一次覆盖**多笔支出**（一趟差旅报销掉机票+酒店+打车）。
  /// 关联放在收入侧天然是"一对多 / 多对多"的枢纽，反过来就拗了。
  final List<int> linkedBillIds;

  const BillRecord({
    this.id,
    required this.type,
    required this.amount,
    required this.category,
    this.account = kDefaultAccount,
    this.note = '',
    required this.date,
    required this.createdAt,
    this.linkedBillIds = const [],
  });

  /// 带方向的金额：支出为负，收入为正
  double get signedAmount =>
      type == BillType.expense ? -amount.abs() : amount.abs();

  /// 是否为"报销/分摊"类收入（已关联到至少一笔支出）
  bool get isReimbursement =>
      type == BillType.income && linkedBillIds.isNotEmpty;

  /// 把关联 id 列表编码成 JSON 数组字符串存库；空列表编码为 null
  /// （null 才表示"没有关联"，与"关联了一个空集合"区分开）。
  ///
  /// 手写而不用 dart:convert：老库里可能出现 `[`、`null` 之类的脏值，
  /// 容错解析比抛异常更重要；且格式固定为无空格，便于 SQL 做成员判断。
  static String? encodeLinkedIds(List<int> ids) {
    if (ids.isEmpty) return null;
    return '[${ids.join(',')}]';
  }

  /// [encodeLinkedIds] 的逆操作。任何脏输入都容错回落到空列表，
  /// 保证一条记录再异常也不会让整个列表页崩掉。
  static List<int> decodeLinkedIds(Object? raw) {
    if (raw == null) return const [];
    if (raw is List) {
      return raw.whereType<num>().map((e) => e.toInt()).toList();
    }
    final s = raw.toString().trim();
    if (s.isEmpty || s == 'null' || s == '[]') return const [];
    final body = s.replaceAll('[', '').replaceAll(']', '').trim();
    if (body.isEmpty) return const [];
    final out = <int>[];
    for (final part in body.split(',')) {
      final v = int.tryParse(part.trim());
      if (v != null) out.add(v);
    }
    return out;
  }

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'type': type.value,
        'amount': amount,
        'category': category,
        'account': account,
        'note': note,
        'date': dateToInt(date),
        'created_at': createdAt.millisecondsSinceEpoch,
        'linked_bill_ids': encodeLinkedIds(linkedBillIds),
      };

  static BillRecord fromMap(Map<String, Object?> m) {
    var linked = decodeLinkedIds(m['linked_bill_ids']);
    // 兜底：v4 老库或漏迁移的快照里可能只有旧的单笔关联列
    if (linked.isEmpty) {
      final legacy = m['linked_bill_id'] as int?;
      if (legacy != null) linked = [legacy];
    }
    return BillRecord(
      id: m['id'] as int?,
      type: BillTypeX.fromValue(m['type'] as int),
      amount: (m['amount'] as num).toDouble(),
      category: (m['category'] as String?) ?? '其他',
      // 老数据没有 account 列时回落到默认账户，保证升级后不丢记录
      account: (m['account'] as String?) ?? kDefaultAccount,
      note: (m['note'] as String?) ?? '',
      date: intToDate(m['date'] as int),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          (m['created_at'] as int?) ?? 0),
      linkedBillIds: linked,
    );
  }

  /// 注意 [linkedBillIds] 无法用 `?? this.linkedBillIds` 表达"清除关联"，
  /// 因为传 null 与不传在 Dart 里无法区分。要解除关联请用 [clearLinked]。
  BillRecord copyWith({
    int? id,
    BillType? type,
    double? amount,
    String? category,
    String? account,
    String? note,
    DateTime? date,
    DateTime? createdAt,
    List<int>? linkedBillIds,
    bool clearLinked = false,
  }) =>
      BillRecord(
        id: id ?? this.id,
        type: type ?? this.type,
        amount: amount ?? this.amount,
        category: category ?? this.category,
        account: account ?? this.account,
        note: note ?? this.note,
        date: date ?? this.date,
        createdAt: createdAt ?? this.createdAt,
        linkedBillIds: clearLinked
            ? const []
            : (linkedBillIds ?? this.linkedBillIds),
      );

  // ---------- 日期与整数的互转（YYYYMMDD）----------
  // 用 YYYYMMDD 整数存储日期，便于 SQL 按日/月/年直接做范围查询与分组

  static int dateToInt(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

  static DateTime intToDate(int v) =>
      DateTime(v ~/ 10000, (v ~/ 100) % 100, v % 100);

  /// 该记录所属月份键，如 202609
  int get monthKey => date.year * 100 + date.month;

  /// 该记录所属年份
  int get yearKey => date.year;
}

/// 分类定义
class CategoryDef {
  final String name;
  final IconData icon;
  final BillType type;

  const CategoryDef(this.name, this.icon, this.type);
}

/// 支出分类
const List<CategoryDef> kExpenseCategories = [
  CategoryDef('餐饮', Icons.restaurant, BillType.expense),
  CategoryDef('购物', Icons.shopping_bag, BillType.expense),
  CategoryDef('交通', Icons.directions_bus, BillType.expense),
  CategoryDef('居住', Icons.home, BillType.expense),
  CategoryDef('水电通讯', Icons.bolt, BillType.expense),
  CategoryDef('医疗', Icons.local_hospital, BillType.expense),
  CategoryDef('教育', Icons.school, BillType.expense),
  CategoryDef('娱乐', Icons.movie, BillType.expense),
  CategoryDef('人情往来', Icons.card_giftcard, BillType.expense),
  CategoryDef('宠物', Icons.pets, BillType.expense),
  CategoryDef('运动健身', Icons.fitness_center, BillType.expense),
  CategoryDef('旅行', Icons.flight_takeoff, BillType.expense),
  CategoryDef('其他', Icons.more_horiz, BillType.expense),
];

/// 收入分类
const List<CategoryDef> kIncomeCategories = [
  CategoryDef('工资', Icons.account_balance_wallet, BillType.income),
  CategoryDef('奖金', Icons.emoji_events, BillType.income),
  CategoryDef('兼职', Icons.work_outline, BillType.income),
  CategoryDef('投资收益', Icons.trending_up, BillType.income),
  CategoryDef('红包', Icons.redeem, BillType.income),
  CategoryDef('报销', Icons.receipt_long, BillType.income),
  CategoryDef('其他', Icons.more_horiz, BillType.income),
];

List<CategoryDef> categoriesOf(BillType t) =>
    t == BillType.expense ? kExpenseCategories : kIncomeCategories;

IconData iconForCategory(String name, BillType type) {
  for (final c in categoriesOf(type)) {
    if (c.name == name) return c.icon;
  }
  return Icons.more_horiz;
}

// ---------------------------------------------------------------------------
// 账户
// ---------------------------------------------------------------------------

/// 账户定义：名称 + 图标 + 是否为默认账户
class AccountDef {
  final String name;
  final IconData icon;

  /// 期初余额：开始记账之前，这个账户里已有的钱。
  /// 有了它，"账户余额"才能对上钱包真实数字，而不只是记账以来的净额。
  final double initialBalance;

  const AccountDef(this.name, this.icon, {this.initialBalance = 0});

  AccountDef copyWith({String? name, IconData? icon, double? initialBalance}) =>
      AccountDef(
        name ?? this.name,
        icon ?? this.icon,
        initialBalance: initialBalance ?? this.initialBalance,
      );
}

/// 账户间转账
///
/// 转账不是收入也不是支出，它只改变钱在账户之间的分布，不改变总资产。
/// 因此它单独存一张表，绝不写进 bills —— 否则统计口径会被污染
/// （"银行卡→微信充值"会被算成支出，导致月度支出虚高）。
class TransferRecord {
  final int? id;
  final String fromAccount; // 转出账户
  final String toAccount; // 转入账户
  final double amount; // 始终存正数
  final String note;
  final DateTime date;
  final DateTime createdAt;

  const TransferRecord({
    this.id,
    required this.fromAccount,
    required this.toAccount,
    required this.amount,
    this.note = '',
    required this.date,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'from_account': fromAccount,
        'to_account': toAccount,
        'amount': amount,
        'note': note,
        'date': BillRecord.dateToInt(date),
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  static TransferRecord fromMap(Map<String, Object?> m) => TransferRecord(
        id: m['id'] as int?,
        fromAccount: (m['from_account'] as String?) ?? kDefaultAccount,
        toAccount: (m['to_account'] as String?) ?? kDefaultAccount,
        amount: ((m['amount'] as num?) ?? 0).toDouble(),
        note: (m['note'] as String?) ?? '',
        date: BillRecord.intToDate((m['date'] as int?) ?? 0),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            (m['created_at'] as int?) ?? 0),
      );

  TransferRecord copyWith({
    int? id,
    String? fromAccount,
    String? toAccount,
    double? amount,
    String? note,
    DateTime? date,
    DateTime? createdAt,
  }) =>
      TransferRecord(
        id: id ?? this.id,
        fromAccount: fromAccount ?? this.fromAccount,
        toAccount: toAccount ?? this.toAccount,
        amount: amount ?? this.amount,
        note: note ?? this.note,
        date: date ?? this.date,
        createdAt: createdAt ?? this.createdAt,
      );
}

/// 预算设置：月总预算 + 预算周期起始日
///
/// 预算周期**不一定是自然月**——很多人发薪日是月末或月初几号，
/// 按自然月算预算会和生产周期错位。因此允许自定义起始日，
/// 例如起始日 25 表示「每月 25 号 ~ 次月 24 号」为一个预算周期。
class BudgetSettings {
  /// 月总预算（元）。<=0 视为"未设置"，分析页不展示预算卡
  final double monthlyBudget;

  /// 预算周期起始日，1-28（>28 的天数并非每月都有，会被 clamp）
  final int startDay;

  const BudgetSettings({this.monthlyBudget = 0, this.startDay = 1});

  /// 是否已设置有效预算
  bool get enabled => monthlyBudget > 0;

  BudgetSettings copyWith({double? monthlyBudget, int? startDay}) =>
      BudgetSettings(
        monthlyBudget: monthlyBudget ?? this.monthlyBudget,
        startDay: startDay ?? this.startDay,
      );

  Map<String, Object?> toMap() => {
        'monthly_budget': monthlyBudget,
        'budget_start_day': startDay,
      };

  /// 从 settings 表的 key-value 行还原；任何缺失/脏值都回落到"未设置"
  static BudgetSettings fromRows(Map<String, String> rows) {
    final budget = double.tryParse(rows['monthly_budget'] ?? '') ?? 0;
    final day = int.tryParse(rows['budget_start_day'] ?? '') ?? 1;
    return BudgetSettings(
      monthlyBudget: budget.isFinite && budget > 0 ? budget : 0,
      startDay: day.clamp(1, 28),
    );
  }
}

/// 默认账户：未指定账户的记账与老数据都归到这里
const String kDefaultAccount = '现金';
/// "全部账户"的哨兵值，仅用于筛选，不会写进数据库
const String kAllAccounts = '__ALL__';

/// 内置账户（首次启动写入账户表，用户可在此基础上增删）
const List<AccountDef> kBuiltinAccounts = [
  AccountDef('现金', Icons.payments),
  AccountDef('微信', Icons.chat_bubble),
  AccountDef('支付宝', Icons.account_balance_wallet),
  AccountDef('银行卡', Icons.credit_card),
];

/// 未知账户名兜底图标
const IconData kFallbackAccountIcon = Icons.account_balance_wallet;

IconData iconForAccount(String name, {IconData? fromList}) {
  if (fromList != null) return fromList;
  for (final a in kBuiltinAccounts) {
    if (a.name == name) return a.icon;
  }
  return kFallbackAccountIcon;
}

/// 可选账户图标（新建/编辑账户时挑选）
const List<IconData> kAccountIconChoices = [
  Icons.payments,
  Icons.chat_bubble,
  Icons.account_balance_wallet,
  Icons.credit_card,
  Icons.savings,
  Icons.account_balance,
  Icons.phone_android,
  Icons.storefront,
  Icons.card_giftcard,
  Icons.currency_exchange,
  Icons.trending_up,
  Icons.more_horiz,
];
