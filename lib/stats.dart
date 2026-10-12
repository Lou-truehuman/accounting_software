import 'models.dart';

/// 统计周期维度
enum StatsGranularity { day, month, year, custom }

extension StatsGranularityX on StatsGranularity {
  String get label {
    switch (this) {
      case StatsGranularity.day:
        return '日';
      case StatsGranularity.month:
        return '月';
      case StatsGranularity.year:
        return '年';
      case StatsGranularity.custom:
        return '自定义';
    }
  }
}

/// 一个数据分组的聚合结果
class Slice {
  final String key; // 分组键（分类名 / 日期 / 月份）
  final String label; // 展示文案
  double expense = 0;
  double income = 0;
  int count = 0;

  Slice(this.key, this.label);

  double get net => income - expense;
  double get total => expense + income;
}

/// 一组账单的统计汇总
///
/// ## 报销 / 分摊的合并口径
///
/// 一笔报销（或朋友分摊转账）本质上是对某些支出的**冲减**，不是新增财富。
/// 一笔报销可以同时关联**多笔支出**（一趟差旅报销掉机票+酒店+打车）。
/// 当「支出」与「冲减它的收入」**同时落在当前统计区间内**时，两者合并记账：
///
/// - 报销合计 ≤ 关联支出合计：支出按**净额**计入（`支出合计 − 报销合计`，
///   即"实际自付"），报销收入本身**不计入总收入**（已并进上面的冲减，
///   再算一次就是重复）。
/// - 报销合计 > 关联支出合计：支出净额归零（被完全覆盖），
///   **超出部分 `报销 − 支出` 作为净收入计入**——钱确实多收了，
///   不能让它凭空消失。这正是"报销金额大于实际支出时合并记账"的语义。
///
/// 净资产变动两种情况下都守恒：
/// `支出 −1000 +1000 +800 = −200 = −(1000 − 800)`（报销不足）
/// `支出 −1000 +1300 = +300 = 1300 − 1000`（报销超出）
///
/// **跨期怎么处理**：只有配对双方都在区间内才合并。
/// 例如 9 月消费、10 月报销，查「9 月」时只看到支出原额（报销还没发生），
/// 查「9—10 月」才看到净额。这是唯一不会让金额凭空增减的语义——
/// 若不管收入在不在区间就扣减，用户查单月时会看到支出莫名少了一截，对不上账。
class StatsResult {
  final List<BillRecord> records;
  final DateTime from;
  final DateTime to;
  final String rangeLabel;

  /// 浮点比较容差：金额都是两位小数，1 分钱的千分之一足够抹平累加误差
  static const _eps = 0.005;

  StatsResult({
    required this.records,
    required this.from,
    required this.to,
    required this.rangeLabel,
  });

  /// 分摊结果是否已算过。懒计算并缓存：一次区间查询可能触发十几次聚合
  /// （分类/日/月/星期…），每次都重算一遍分摊会白白浪费。
  bool _allocationReady = false;

  /// 支出id → 被报销分摊到的金额（合计不超过该支出原额）
  final Map<int, double> _reimbursedByExpense = {};

  /// 收入id → 实际计入总收入的金额
  /// （普通收入=全额；已合并且报销超支的=超出部分；已合并未超支=0）
  final Map<int, double> _countedIncome = {};

  /// 真的合并上了至少一笔区间内支出的收入 id 集合
  final Set<int> _mergedIncomeIds = {};

  /// 一次性把"报销 → 支出"的分摊关系算清楚。
  ///
  /// 两步走：
  /// 1. 每笔报销收入按**关联支出的金额占比**，把自己的金额摊到各笔支出上；
  /// 2. 按支出**封顶**：多笔报销砸同一笔支出时，分摊合计可能超过原额，
  ///    等比例压回原额，差额回流成对应收入的净额。
  ///
  /// 第 2 步是必须的：没有它，"支出净额 = 原额 − 报销"会出现负数，
  /// 统计页就会冒出"-300 的支出"这种反直觉的数字。
  void _buildAllocation() {
    if (_allocationReady) return;
    _allocationReady = true;

    // 区间内的支出，按 id 建索引——只有区间内的支出才参与合并（跨期规则）
    final expenseById = <int, BillRecord>{};
    for (final r in records) {
      if (r.type == BillType.expense && r.id != null) {
        expenseById[r.id!] = r;
      }
    }

    // 第一遍：按比例分摊。结构：收入id -> (支出id -> 分摊额)
    final alloc = <int, Map<int, double>>{};
    for (final r in records) {
      if (r.type != BillType.income || r.id == null) continue;

      final targets = <BillRecord>[];
      for (final lid in r.linkedBillIds) {
        final e = expenseById[lid];
        if (e != null) targets.add(e);
      }
      // 没关联上任何区间内支出 → 这就是一笔普通收入，不参与合并
      if (targets.isEmpty) continue;

      final base = targets.fold<double>(0, (a, e) => a + e.amount);
      // 关联的支出原额合计为 0（异常数据），无从冲减，按普通收入计
      if (base <= 0) continue;

      _mergedIncomeIds.add(r.id!);
      final row = <int, double>{};
      for (final e in targets) {
        row[e.id!] = r.amount * e.amount / base;
      }
      alloc[r.id!] = row;
    }

    // 第二遍：按支出封顶 + 差额回流成收入净额
    final byExpense = <int, List<int>>{};
    for (final entry in alloc.entries) {
      for (final eid in entry.value.keys) {
        byExpense.putIfAbsent(eid, () => []).add(entry.key);
      }
    }
    final surplus = <int, double>{};
    for (final entry in byExpense.entries) {
      final e = expenseById[entry.key];
      if (e == null) continue;
      var sum = 0.0;
      for (final iid in entry.value) {
        sum += alloc[iid]![entry.key]!;
      }
      if (sum <= e.amount + _eps) continue; // 没超，不用管
      for (final iid in entry.value) {
        final a = alloc[iid]![entry.key]!;
        final capped = a * e.amount / sum; // 等比例压回原额
        alloc[iid]![entry.key] = capped;
        final overflow = a - capped;
        if (overflow > 0) surplus[iid] = (surplus[iid] ?? 0) + overflow;
      }
    }

    // 汇总成两张查询表
    for (final entry in alloc.entries) {
      entry.value.forEach((eid, v) {
        _reimbursedByExpense[eid] = (_reimbursedByExpense[eid] ?? 0) + v;
      });
    }
    for (final r in records) {
      if (r.type != BillType.income) continue;
      final id = r.id;
      if (id == null || !_mergedIncomeIds.contains(id)) {
        // 普通收入：全额计入
        _countedIncome[id ?? r.hashCode] = r.amount;
      } else {
        // 已合并：只计入超出被冲减支出的净额（通常为 0）
        _countedIncome[id] = surplus[id] ?? 0;
      }
    }
  }

  /// 这笔支出被报销的金额；若没有关联（或报销不在本区间）则为 0
  double reimbursedOf(BillRecord r) {
    _buildAllocation();
    if (r.type != BillType.expense || r.id == null) return 0;
    return _reimbursedByExpense[r.id!] ?? 0;
  }

  /// 这笔支出的净额，即"实际自付"
  double effectiveExpenseOf(BillRecord r) {
    if (r.type != BillType.expense) return 0;
    final v = r.amount - reimbursedOf(r);
    // 分摊封顶后理论上不会为负，这里兜住浮点尾差
    return v < 0 ? 0 : v;
  }

  /// 这条收入是否已被并入某笔支出（并入后不再全额计入总收入，避免重复计算）
  bool isMergedIncome(BillRecord r) {
    _buildAllocation();
    if (r.type != BillType.income || r.id == null) return false;
    return _mergedIncomeIds.contains(r.id!);
  }

  /// 这条收入实际计入总收入的金额。
  ///
  /// - 普通收入：全额
  /// - 已合并且报销未超支：0（已并进支出的冲减）
  /// - 已合并且报销超支：`报销 − 关联支出合计` 的净额
  double countedIncomeOf(BillRecord r) {
    _buildAllocation();
    if (r.type != BillType.income) return 0;
    if (r.id == null) return r.amount;
    return _countedIncome[r.id!] ?? r.amount;
  }

  /// 本区间内被报销的支出笔数
  int get reimbursedCount {
    _buildAllocation();
    return _reimbursedByExpense.values.where((v) => v > _eps).length;
  }

  /// 本区间内的报销总额（仅统计配对成功、且被封顶后的实际分摊额）
  double get totalReimbursed {
    _buildAllocation();
    return _reimbursedByExpense.values.fold<double>(0.0, (a, b) => a + b);
  }

  /// 总支出：已报销的部分按净额计
  double get totalExpense => records
      .where((r) => r.type == BillType.expense)
      .fold<double>(0.0, (s, r) => s + effectiveExpenseOf(r));

  /// 总收入：作为报销/分摊的收入不计全额（已并入支出的冲减），
  /// 但报销超过被冲减支出的部分要计进来——那确实是多收的钱。
  double get totalIncome => records
      .where((r) => r.type == BillType.income)
      .fold<double>(0.0, (s, r) => s + countedIncomeOf(r));

  /// 结余
  double get balance => totalIncome - totalExpense;

  int get recordCount => records.length;

  /// 有记账的天数（含只有收入的天），用于"本期有 N 天有记账"这类文案
  int get dayCount => records.map((r) => r.date).toSet().length;

  /// 有**支出**记账的天数。
  ///
  /// 日均支出用它作分母，而不是 [dayCount]：后者会把只有收入的日子
  /// （典型如"报销到账那天"）也当成一天，白白稀释日均支出。
  int get expenseDayCount => records
      .where((r) => r.type == BillType.expense)
      .map((r) => r.date)
      .toSet()
      .length;

  /// 日均支出（按有支出的天数计算，避免把没消费的日子算进来稀释）
  double get avgDailyExpense =>
      expenseDayCount == 0 ? 0 : totalExpense / expenseDayCount;

  /// 最大单笔支出
  ///
  /// 按**净额**比较而非原金额：一笔 1000 元但被全额报销的支出，
  /// 实际自付 0，不该被算成"最大的支出"。
  BillRecord? get maxExpense {
    final list = records.where((r) => r.type == BillType.expense).toList();
    if (list.isEmpty) return null;
    list.sort((a, b) =>
        effectiveExpenseOf(b).compareTo(effectiveExpenseOf(a)));
    return list.first;
  }

  /// 按分类聚合（默认支出维度）
  List<Slice> byCategory({BillType type = BillType.expense}) {
    _buildAllocation();
    final map = <String, Slice>{};
    for (final r in records) {
      if (r.type != type) continue;
      // 已并入支出且无净额的报销收入，不再出现在收入分类里，
      // 否则与支出净额重复；有净额（报销超支）的则照常出现在"报销"分类下
      if (type == BillType.income &&
          isMergedIncome(r) &&
          countedIncomeOf(r) <= _eps) {
        continue;
      }

      final s = map.putIfAbsent(r.category, () => Slice(r.category, r.category));
      if (type == BillType.expense) {
        s.expense += effectiveExpenseOf(r);
      } else {
        s.income += countedIncomeOf(r);
      }
      s.count++;
    }
    final list = map.values.toList();
    list.sort((a, b) => b.total.compareTo(a.total));
    return list;
  }

  /// 把一条记录按其有效金额累加进分组
  void _accumulate(Slice s, BillRecord r) {
    if (r.type == BillType.expense) {
      s.expense += effectiveExpenseOf(r);
      s.count++;
    } else {
      final counted = countedIncomeOf(r);
      // 已并入支出且无净额的，不重复计入收入
      if (isMergedIncome(r) && counted <= _eps) return;
      s.income += counted;
      s.count++;
    }
  }

  /// 按日期聚合（趋势图用），返回按时间升序排列
  List<Slice> byDay() {
    final map = <int, Slice>{};
    for (final r in records) {
      final k = BillRecord.dateToInt(r.date);
      final s = map.putIfAbsent(
          k, () => Slice('$k', '${r.date.month}/${r.date.day}'));
      _accumulate(s, r);
    }
    final list = map.values.toList()..sort((a, b) => a.key.compareTo(b.key));
    return list;
  }

  /// 按月份聚合（跨月查看时用），升序
  List<Slice> byMonth() {
    final map = <int, Slice>{};
    for (final r in records) {
      final k = r.monthKey;
      final s = map.putIfAbsent(k, () => Slice('$k', '${k ~/ 100}年${k % 100}月'));
      _accumulate(s, r);
    }
    final list = map.values.toList()..sort((a, b) => a.key.compareTo(b.key));
    return list;
  }

  /// 按年聚合，升序
  List<Slice> byYear() {
    final map = <int, Slice>{};
    for (final r in records) {
      final k = r.yearKey;
      final s = map.putIfAbsent(k, () => Slice('$k', '$k年'));
      _accumulate(s, r);
    }
    final list = map.values.toList()..sort((a, b) => a.key.compareTo(b.key));
    return list;
  }

  /// 按星期聚合，识别"哪天花钱最多"
  List<Slice> byWeekday() {
    const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final list = List.generate(7, (i) => Slice('$i', names[i]));
    for (final r in records) {
      final idx = r.date.weekday - 1; // DateTime.weekday: 1=周一
      _accumulate(list[idx], r);
    }
    return list;
  }

  /// 某一天的明细汇总，供日视图使用
  Map<String, List<BillRecord>> groupByDateDesc() {
    final map = <String, List<BillRecord>>{};
    for (final r in records) {
      final k = '${r.date.year}-${r.date.month.toString().padLeft(2, '0')}'
          '-${r.date.day.toString().padLeft(2, '0')}';
      map.putIfAbsent(k, () => []).add(r);
    }
    return map;
  }
}

/// 统计工具：根据维度算出起止日期
class StatsRange {
  static DateTime dayStart(DateTime d) => DateTime(d.year, d.month, d.day);
  static DateTime dayEnd(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime monthStart(int y, int m) => DateTime(y, m, 1);
  static DateTime monthEnd(int y, int m) =>
      DateTime(y, m + 1, 0); // 下个月第 0 天 = 本月最后一天

  static DateTime yearStart(int y) => DateTime(y, 1, 1);
  static DateTime yearEnd(int y) => DateTime(y, 12, 31);

  /// 预算周期：返回**包含 [anchor]** 的那个"起始日为 [startDay]"的月周期。
  ///
  /// 为什么要自定义起始日：很多人发薪日是月末或月初几号，按自然月算预算
  /// 会和生产周期错位。起始日 25 表示「每月 25 号 ~ 次月 24 号」为一个周期。
  ///
  /// [startDay] 被 clamp 到 1-28：31 号在 2 月不存在，若原样使用会抛
  /// "Invalid date found" 直接把分析页打白。28 是每个月都有的最大天数，
  /// 取它作为上限对用户是可解释的（选 28 以上按 28 处理）。
  static DateRange budgetPeriod(DateTime anchor, int startDay) {
    final sd = startDay.clamp(1, 28);
    final a = dayStart(anchor);

    final DateTime start;
    if (a.day >= sd) {
      start = DateTime(a.year, a.month, sd);
    } else {
      // 还没到本月起始日 → 属于上个月开启的那个周期
      start = DateTime(a.year, a.month - 1, sd);
    }
    // 结束日 = 下一周期起始日的前一天。用"下月第 0 天"技巧，
    // 天然处理大小月与闰年，不用自己判断这个月有几天。
    final end = DateTime(start.year, start.month + 1, sd)
        .subtract(const Duration(days: 1));
    return DateRange(start, end);
  }
}

/// 一个闭区间日期范围（起止都含）
class DateRange {
  final DateTime start;
  final DateTime end;

  const DateRange(this.start, this.end);

  bool contains(DateTime d) {
    final di = BillRecord.dateToInt(d);
    return di >= BillRecord.dateToInt(start) &&
        di <= BillRecord.dateToInt(end);
  }

  @override
  String toString() =>
      '${start.year}-${start.month}-${start.day} ~ ${end.year}-${end.month}-${end.day}';
}

/// 预算使用情况
class BudgetStatus {
  /// 月总预算
  final double budget;

  /// 本周期已用支出（**净额口径**，与统计页一致：已按报销冲减）
  final double used;

  /// 当前预算周期
  final DateRange period;

  /// 今天在周期内的第几天（1 起）
  final int dayIndex;

  const BudgetStatus({
    required this.budget,
    required this.used,
    required this.period,
    required this.dayIndex,
  });

  /// 剩余预算。负数表示已超支
  double get remaining => budget - used;

  bool get overspent => remaining < -0.005;

  /// 使用比例（0-1+，可超过 1 表示超支）
  double get ratio => budget <= 0 ? 0 : used / budget;

  /// 周期总天数。
  ///
  /// 必须用 [DateTime.difference] 算：数据库里的 date 是 yyyyMMdd 整数
  /// （20260919 − 20260820 = 99，不是 30 天），直接相减会得到一个
  /// 毫无意义的百位数，进度和"日均可用"全都会错。
  int get totalDays => period.end.difference(period.start).inDays + 1;

  /// 距周期结束还剩几天（含今天）
  int get daysLeft => totalDays - dayIndex + 1;

  /// 剩余额度平均到每一天可用多少；已超支或没天数了返回 0
  double get dailyAvailable =>
      daysLeft <= 0 || remaining <= 0 ? 0 : remaining / daysLeft;

  /// 由原始数值算出预算状态。抽成纯函数是为了能脱离数据库单测——
  /// 口径算错不会崩，只会让用户看到似是而非的数字，必须钉死。
  static BudgetStatus of({
    required double monthlyBudget,
    required int startDay,
    required double periodExpense,
    required DateTime today,
  }) {
    final period = StatsRange.budgetPeriod(today, startDay);
    final dayIndex =
        StatsRange.dayStart(today).difference(period.start).inDays + 1;
    return BudgetStatus(
      budget: monthlyBudget,
      used: periodExpense,
      period: period,
      dayIndex: dayIndex,
    );
  }
}

/// 金额格式化：¥1,234.50
String formatMoney(double v, {bool withSymbol = true}) {
  final neg = v < 0;
  final abs = v.abs();
  final s = abs.toStringAsFixed(2);
  final parts = s.split('.');
  final intPart = parts[0];
  final buf = StringBuffer();
  for (int i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
    buf.write(intPart[i]);
  }
  final out = '${buf.toString()}.${parts[1]}';
  return '${neg ? '-' : ''}${withSymbol ? '¥' : ''}$out';
}

/// 紧凑金额：用于图表轴标签，超过一万显示为"1.2万"
String compactMoney(double v) {
  final a = v.abs();
  if (a >= 10000) return '${(v / 10000).toStringAsFixed(1)}万';
  if (a >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
  if (a == a.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(1);
}
