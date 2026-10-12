import 'package:flutter/material.dart';

import '../account_store.dart';
import '../db.dart';
import '../models.dart';
import '../stats.dart';
import '../theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';
import 'add_bill.dart';

/// 日历视图：按天查看消费分布，直观看清"哪天花得多"
class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => CalendarPageState();
}

class CalendarPageState extends State<CalendarPage> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _selected = StatsRange.dayStart(DateTime.now());

  List<BillRecord> _monthRecords = [];
  Set<int> _daysWithRecords = {};
  bool _loading = true;

  /// 当月统计结果（净额口径）。
  /// 日历页是月视图，所以"报销配对"的识别范围就是当月。
  StatsResult _stats = StatsResult(
    records: const [],
    from: DateTime(2000, 1, 1),
    to: DateTime(2000, 1, 1),
    rangeLabel: '',
  );

  /// 当前账户筛选：kAllAccounts 表示不过滤
  String _accountFilter = kAllAccounts;
  List<AccountDef> _accounts = const [];

  @override
  void initState() {
    super.initState();
    _loadAccountsThenReload();
  }

  Future<void> _loadAccountsThenReload() async {
    final list = await AccountStore.instance.load();
    if (!mounted) return;
    setState(() => _accounts = list);
    await reload();
  }

  /// 账户列表变化后由外部调用
  Future<void> syncAccounts() async {
    final list = await AccountStore.instance.load(force: true);
    if (!mounted) return;
    setState(() {
      _accounts = list;
      if (_accountFilter != kAllAccounts &&
          !list.any((a) => a.name == _accountFilter)) {
        _accountFilter = kAllAccounts;
      }
    });
    await reload();
  }

  Future<void> reload() async {
    if (!mounted) return;
    setState(() => _loading = true);

    try {
      final list = await BillDatabase.instance
          .queryMonth(_month.year, _month.month, account: _accountFilter);
      final days = await BillDatabase.instance
          .daysWithRecords(_month.year, _month.month, account: _accountFilter);

      if (!mounted) return;
      setState(() {
        _monthRecords = list;
        _daysWithRecords = days;
        _stats = StatsResult(
          records: list,
          from: StatsRange.monthStart(_month.year, _month.month),
          to: StatsRange.monthEnd(_month.year, _month.month),
          rangeLabel: '${_month.year}年${_month.month}月',
        );
        _loading = false;
      });
    } catch (_) {
      // 查询失败时退出 loading，避免一直转圈被误认为白屏
      if (!mounted) return;
      setState(() {
        _monthRecords = [];
        _daysWithRecords = {};
        _stats = StatsResult(
          records: const [],
          from: StatsRange.monthStart(_month.year, _month.month),
          to: StatsRange.monthEnd(_month.year, _month.month),
          rangeLabel: '${_month.year}年${_month.month}月',
        );
        _loading = false;
      });
    }
  }

  void _shiftMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta, 1);
      _selected = DateTime(_month.year, _month.month, 1);
    });
    reload();
  }

  /// 当日支出合计（净额：已报销的部分扣除掉，与整体口径一致）
  double _expenseOfDay(int day) {
    final key = _month.year * 10000 + _month.month * 100 + day;
    return _monthRecords
        .where((r) =>
            r.type == BillType.expense && BillRecord.dateToInt(r.date) == key)
        .fold<double>(0.0, (s, r) => s + _stats.effectiveExpenseOf(r));
  }

  List<BillRecord> _recordsOfDay(int day) {
    final key = _month.year * 10000 + _month.month * 100 + day;
    return _monthRecords
        .where((r) => BillRecord.dateToInt(r.date) == key)
        .toList();
  }

  Future<void> _addOnSelected() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AddBillPage(
          initialDate: _selected,
          initialAccount:
              _accountFilter == kAllAccounts ? null : _accountFilter,
        ),
      ),
    );
    if (ok == true) reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(strokeWidth: 2))
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                    child: Column(
                      children: [
                        _buildCalendarCard(),
                        const SizedBox(height: 12),
                        _buildMonthTrendCard(),
                        const SizedBox(height: 12),
                        _buildDayDetail(),
                      ],
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addOnSelected,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 4,
        tooltip: '补记这天',
        child: const Icon(Icons.add, size: 26),
      ),
    );
  }

  /// 头部：大标题 + 月度汇总 + 翻月 + 账户筛选
  Widget _buildHeader() {
    // 走 _stats 的净额口径：已报销的支出按净额计、报销收入不重复计入
    final monthExpense = _stats.totalExpense;
    final monthIncome = _stats.totalIncome;
    final daysWithRec = _daysWithRecords.length;

    return Container(
      color: AppColors.background,
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 12),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: Row(
              children: [
                const Text(
                  '日历',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                Tooltip(
                  message: '补记这天',
                  child: Material(
                    color: AppColors.fill,
                    borderRadius: BorderRadius.circular(11),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(11),
                      onTap: _addOnSelected,
                      child: const SizedBox(
                        width: 38,
                        height: 38,
                        child: Icon(Icons.add,
                            size: 21, color: AppColors.textPrimary),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 月度汇总卡
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              decoration: BoxDecoration(
                gradient: AppColors.brandGradient,
                borderRadius: BorderRadius.circular(20),
                boxShadow: AppShape.brandShadow,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$_monthLabel 支出',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withOpacity(0.75),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  FittedBox(
                    child: Text(
                      formatMoney(monthExpense),
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Row(
                      children: [
                        _cardStat('收入', formatMoney(monthIncome)),
                        Container(
                            width: 1,
                            height: 26,
                            color: Colors.white.withOpacity(0.22)),
                        _cardStat('记账天数', '$daysWithRec 天'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 翻月
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: PeriodSwitcher(
              label: _monthLabel,
              onPrev: () => _shiftMonth(-1),
              onNext: () => _shiftMonth(1),
              onTapCenter: _pickMonth,
            ),
          ),
          const SizedBox(height: 10),

          if (_accounts.length > 1) ...[
            FilterChipBar(
              selected: _accountFilter,
              onChanged: (v) {
                setState(() => _accountFilter = v);
                reload();
              },
              items: [
                const FilterChipItem(
                    value: kAllAccounts,
                    label: '全部账户',
                    icon: Icons.apps),
                ..._accounts.map((a) => FilterChipItem(
                    value: a.name, label: a.name, icon: a.icon)),
              ],
            ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }

  String get _monthLabel => '${_month.year}年${_month.month}月';

  Future<void> _pickMonth() async {
    final months = List.generate(12, (i) => i + 1);
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 10),
              decoration: BoxDecoration(
                color: AppColors.fillStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text('选择月份（${_month.year}年）',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.7,
                ),
                itemCount: 12,
                itemBuilder: (c, i) {
                  final m = months[i];
                  final isSel = m == _month.month;
                  return InkWell(
                    onTap: () => Navigator.pop(ctx, m),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isSel ? AppColors.primary : AppColors.fill,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$m月',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              isSel ? FontWeight.w700 : FontWeight.w500,
                          color: isSel
                              ? Colors.white
                              : AppColors.textPrimary,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked != null) {
      setState(() {
        _month = DateTime(_month.year, picked, 1);
        _selected = DateTime(_month.year, picked, 1);
      });
      reload();
    }
  }

  Widget _cardStat(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 10.5, color: Colors.white.withOpacity(0.7))),
          const SizedBox(height: 3),
          FittedBox(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -------- 日历 --------

  Widget _buildCalendarCard() {
    final firstDay = DateTime(_month.year, _month.month, 1);
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final leading = firstDay.weekday - 1;

    final monthMax = _daysWithRecords.isEmpty
        ? 0.0
        : List.generate(daysInMonth, (i) => _expenseOfDay(i + 1))
            .fold<double>(0.0, (a, b) => a > b ? a : b);

    final today = StatsRange.dayStart(DateTime.now());

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 14),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: AppShape.card,
        boxShadow: AppShape.softShadow,
      ),
      child: Column(
        children: [
          // 星期表头
          Row(
            children: const ['一', '二', '三', '四', '五', '六', '日']
                .map((w) => Expanded(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            w,
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.textTertiary,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 4),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: leading + daysInMonth,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              childAspectRatio: 0.84,
            ),
            itemBuilder: (ctx, idx) {
              if (idx < leading) return const SizedBox.shrink();
              final day = idx - leading + 1;

              final isSelected = _selected.year == _month.year &&
                  _selected.month == _month.month &&
                  _selected.day == day;
              final isToday = today.year == _month.year &&
                  today.month == _month.month &&
                  today.day == day;
              final exp = _expenseOfDay(day);
              final hasRecord = _daysWithRecords
                  .contains(_month.year * 10000 + _month.month * 100 + day);

              // 背景深浅：支出越高颜色越深
              final intensity = monthMax <= 0
                  ? 0.0
                  : (exp / monthMax).clamp(0.0, 1.0).toDouble();

              return GestureDetector(
                onTap: () => setState(
                    () => _selected = DateTime(_month.year, _month.month, day)),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppColors.primary
                        : hasRecord
                            ? AppColors.primary
                                .withOpacity(0.07 + intensity * 0.22)
                            : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    border: isToday && !isSelected
                        ? Border.all(color: AppColors.primary, width: 1.3)
                        : null,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '$day',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSelected || isToday
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: isSelected
                              ? Colors.white
                              : hasRecord
                                  ? AppColors.textPrimary
                                  : AppColors.textTertiary,
                        ),
                      ),
                      const SizedBox(height: 1),
                      if (exp > 0)
                        Text(
                          compactMoney(exp),
                          style: TextStyle(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w600,
                            color: isSelected
                                ? Colors.white70
                                : AppColors.primary,
                          ),
                        )
                      else
                        const SizedBox(height: 11),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 当月每日支出迷你趋势
  Widget _buildMonthTrendCard() {
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final slices = <Slice>[];
    for (int d = 1; d <= daysInMonth; d++) {
      final s = Slice('$d', '$d');
      s.expense = _expenseOfDay(d);
      slices.add(s);
    }

    return SectionCard(
      title: '每日支出走势',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 12, 12),
        child: TrendChart(slices: slices, height: 110),
      ),
    );
  }

  /// 选中日期的明细
  Widget _buildDayDetail() {
    final records = _recordsOfDay(_selected.day);
    // 同样按净额口径，保证"格子里的数字"与"下方明细合计"对得上
    final exp = records
        .where((r) => r.type == BillType.expense)
        .fold<double>(0.0, (s, r) => s + _stats.effectiveExpenseOf(r));
    final inc = records
        .where((r) => r.type == BillType.income && !_stats.isMergedIncome(r))
        .fold<double>(0.0, (s, r) => s + r.amount);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: AppShape.card,
        boxShadow: AppShape.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 15, 16, 12),
            child: Row(
              children: [
                Text(
                  '${_selected.month}月${_selected.day}日',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.fill,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    '${records.length} 笔',
                    style: const TextStyle(
                        fontSize: 10.5, color: AppColors.textSecondary),
                  ),
                ),
                const Spacer(),
                if (exp > 0)
                  Text(
                    '-${formatMoney(exp)}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.expense,
                    ),
                  ),
                if (exp > 0 && inc > 0) const SizedBox(width: 8),
                if (inc > 0)
                  Text(
                    '+${formatMoney(inc)}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.income,
                    ),
                  ),
              ],
            ),
          ),
          if (records.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 26),
              child: Center(
                child: Column(
                  children: [
                    const Icon(Icons.event_busy_outlined,
                        size: 34, color: AppColors.textTertiary),
                    const SizedBox(height: 10),
                    Text(
                      _accountFilter == kAllAccounts
                          ? '这天还没有记账'
                          : '这天在「$_accountFilter」还没有记账',
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 14),
                    TextButton.icon(
                      onPressed: _addOnSelected,
                      icon: const Icon(Icons.add, size: 17),
                      label: const Text('补记一笔'),
                      style: TextButton.styleFrom(
                          primary: AppColors.primary),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            const Divider(height: 1, indent: 16, endIndent: 16),
            ...records.map(_buildDayRecordTile),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  Widget _buildDayRecordTile(BillRecord r) {
    final isExpense = r.type == BillType.expense;
    final color = isExpense ? AppColors.expense : AppColors.income;
    // 只在"全部账户"视图下标注账户名，筛了某账户时属冗余信息
    final showAccount = _accountFilter == kAllAccounts;

    return InkWell(
      onTap: () async {
        final res = await Navigator.of(context).push<dynamic>(
          MaterialPageRoute(builder: (_) => AddBillPage(editing: r)),
        );
        if (res == true || res == 'deleted') reload();
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withOpacity(0.10),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(iconForCategory(r.category, r.type),
                  size: 18, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.category,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if (showAccount || r.note.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      [
                        if (showAccount) r.account,
                        if (r.note.isNotEmpty) r.note,
                      ].join(' · '),
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.textTertiary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            Text(
              '${isExpense ? '-' : '+'}${formatMoney(r.amount)}',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
