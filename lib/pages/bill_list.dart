import 'package:flutter/material.dart';

import '../account_store.dart';
import '../db.dart';
import '../models.dart';
import '../stats.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'add_bill.dart';

/// 账单列表页：支持按日 / 月 / 年 三种浏览维度，并可按账户筛选
class BillListPage extends StatefulWidget {
  const BillListPage({super.key});

  @override
  State<BillListPage> createState() => BillListPageState();
}

class BillListPageState extends State<BillListPage> {
  StatsGranularity _granularity = StatsGranularity.month;

  DateTime _anchor = StatsRange.dayStart(DateTime.now());

  /// 账户筛选，默认"全部账户"
  String _accountFilter = kAllAccounts;
  List<AccountDef> _accounts = [];

  /// 折叠状态：key -> 是否展开。默认全部展开
  final Set<String> _collapsed = {};

  List<BillRecord> _records = [];
  bool _loading = true;

  /// 当前区间的统计结果。
  ///
  /// 在 [reload] 里预计算并缓存，而不是每次 build 现算：
  /// 它内部要扫一遍 records 建立"报销配对"索引，
  /// 而这个页面一次 build 会多次读取 totalExpense/totalIncome。
  StatsResult _stats = StatsResult(
    records: const [],
    from: DateTime(2000, 1, 1),
    to: DateTime(2000, 1, 1),
    rangeLabel: '',
  );

  @override
  void initState() {
    super.initState();
    _loadAccountsThenReload();
  }

  Future<void> _loadAccountsThenReload() async {
    final list = await AccountStore.instance.load();
    if (!mounted) return;
    setState(() {
      _accounts = list;
      // 账户被删除后，筛选项要回落到"全部"
      if (_accountFilter != kAllAccounts &&
          list.every((a) => a.name != _accountFilter)) {
        _accountFilter = kAllAccounts;
      }
    });
    reload();
  }

  /// 供外部（Tab 切换、新增后）调用
  Future<void> reload() async {
    if (!mounted) return;
    setState(() => _loading = true);

    try {
      final range = _currentRange();
      final list = await BillDatabase.instance.queryBetween(
        range[0],
        range[1],
        account: _accountFilter,
      );
      if (!mounted) return;
      setState(() {
        _records = list;
        _stats = StatsResult(
          records: list,
          from: range[0],
          to: range[1],
          rangeLabel: _rangeLabel,
        );
        _loading = false;
      });
    } catch (_) {
      // 查询失败时也必须退出 loading，否则页面会一直停在一个转圈上，
      // 看起来就是一片空白。这里降级为空列表，用户至少能看到空状态并重试。
      if (!mounted) return;
      final range = _currentRange();
      setState(() {
        _records = [];
        _stats = StatsResult(
          records: const [],
          from: range[0],
          to: range[1],
          rangeLabel: _rangeLabel,
        );
        _loading = false;
      });
    }
  }

  List<DateTime> _currentRange() {
    switch (_granularity) {
      case StatsGranularity.day:
        return [StatsRange.dayStart(_anchor), StatsRange.dayEnd(_anchor)];
      case StatsGranularity.month:
        return [
          StatsRange.monthStart(_anchor.year, _anchor.month),
          StatsRange.monthEnd(_anchor.year, _anchor.month),
        ];
      case StatsGranularity.year:
        return [
          StatsRange.yearStart(_anchor.year),
          StatsRange.yearEnd(_anchor.year),
        ];
      case StatsGranularity.custom:
        return [StatsRange.dayStart(_anchor), StatsRange.dayEnd(_anchor)];
    }
  }

  String get _rangeLabel {
    switch (_granularity) {
      case StatsGranularity.day:
        return '${_anchor.year}年${_anchor.month}月${_anchor.day}日';
      case StatsGranularity.month:
        return '${_anchor.year}年${_anchor.month}月';
      case StatsGranularity.year:
        return '${_anchor.year}年';
      case StatsGranularity.custom:
        return '';
    }
  }

  void _shift(int delta) {
    setState(() {
      switch (_granularity) {
        case StatsGranularity.day:
          _anchor = _anchor.add(Duration(days: delta));
          break;
        case StatsGranularity.month:
          _anchor = DateTime(_anchor.year, _anchor.month + delta, 1);
          break;
        case StatsGranularity.year:
          _anchor = DateTime(_anchor.year + delta, _anchor.month, 1);
          break;
        case StatsGranularity.custom:
          break;
      }
      _collapsed.clear();
    });
    reload();
  }

  bool get _isCurrentPeriod {
    final now = DateTime.now();
    switch (_granularity) {
      case StatsGranularity.day:
        return _anchor.year == now.year &&
            _anchor.month == now.month &&
            _anchor.day == now.day;
      case StatsGranularity.month:
        return _anchor.year == now.year && _anchor.month == now.month;
      case StatsGranularity.year:
        return _anchor.year == now.year;
      case StatsGranularity.custom:
        return true;
    }
  }

  Future<void> _pickMonthOrYear() async {
    if (_granularity == StatsGranularity.year) {
      final years = List.generate(21, (i) => 2015 + i);
      // 定位到当前年份，避免每次打开都停在列表顶端手动翻找
      final nowYear = DateTime.now().year;
      final curIdx = years.indexOf(nowYear);
      final picked = await _showPicker(
        '选择年份',
        years.map((y) => '$y年').toList(),
        initialIndex: curIdx < 0 ? 0 : curIdx,
        highlightCurrent: curIdx < 0 ? -1 : curIdx,
      );
      if (picked != null) {
        setState(() => _anchor = DateTime(years[picked], _anchor.month, 1));
        reload();
      }
    } else {
      final now = DateTime.now();
      final months = List.generate(12, (i) => i + 1);
      final picked = await _showPicker(
        '选择月份（${_anchor.year}年）',
        months.map((m) => '$m月').toList(),
        initialIndex: _anchor.month - 1,
        highlightCurrent: _anchor.year == now.year ? now.month - 1 : -1,
      );
      if (picked != null) {
        setState(() => _anchor = DateTime(_anchor.year, months[picked], 1));
        reload();
      }
    }
  }

  Future<int?> _showPicker(
    String title,
    List<String> items, {
    int initialIndex = 0,
    int highlightCurrent = -1,
  }) {
    return showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
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
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            const Divider(height: 1),
            SizedBox(
              height: 320,
              child: GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.7,
                ),
                itemCount: items.length,
                itemBuilder: (c, i) {
                  final isCurrent = i == highlightCurrent;
                  final isSelected = i == initialIndex;
                  return InkWell(
                    onTap: () => Navigator.pop(ctx, i),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppColors.primary
                            : AppColors.fill,
                        borderRadius: BorderRadius.circular(10),
                        border: isCurrent && !isSelected
                            ? Border.all(
                                color: AppColors.primary, width: 1.2)
                            : null,
                      ),
                      child: Text(
                        items[i],
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: isSelected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: isSelected
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
  }

  Future<void> _openAdd() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AddBillPage(
          initialDate: _anchor,
          // 当前正筛某个账户时，新记账默认落到该账户，减少一次选择
          initialAccount:
              _accountFilter == kAllAccounts ? null : _accountFilter,
        ),
      ),
    );
    if (ok == true) reload();
  }

  /// 空状态提示：区分"该账户无记录"与"该周期无记录"
  String get _emptyMessage {
    if (_accountFilter != kAllAccounts) {
      return '$_rangeLabel 的「$_accountFilter」\n还没有任何记录';
    }
    return '$_rangeLabel 还没有记账记录\n点右下角 + 开始记第一笔';
  }

  /// 账户筛选条
  Widget _buildAccountFilterBar() {
    return FilterChipBar(
      selected: _accountFilter,
      onChanged: (v) {
        setState(() {
          _accountFilter = v;
          _collapsed.clear();
        });
        reload();
      },
      items: [
        const FilterChipItem(
            value: kAllAccounts, label: '全部账户', icon: Icons.apps),
        ..._accounts.map((a) =>
            FilterChipItem(value: a.name, label: a.name, icon: a.icon)),
      ],
    );
  }

  Future<void> _openEdit(BillRecord r) async {
    final res = await Navigator.of(context).push<dynamic>(
      MaterialPageRoute(builder: (_) => AddBillPage(editing: r)),
    );
    if (res == true || res == 'deleted') reload();
  }

  @override
  Widget build(BuildContext context) {
    // 头部整体作为可滚动内容的一部分，而不是固定占用 Column 高度。
    // 之前头部固定在 Column 里、列表用 Expanded 抢剩余空间，
    // 一旦头部高度超过屏高（小屏 / 大字体 / 账户多），
    // Expanded 分到的高度就是 0，列表被完全挤出可视区 —— 表现为"白屏"。
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        top: true,
        bottom: false,
        child: RefreshIndicator(
          onRefresh: reload,
          color: AppColors.primary,
          child: CustomScrollView(
            // 内容不足一屏时也保持可滚动，保证下拉刷新始终可用
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _buildHeader()),
              ..._buildBodySlivers(),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAdd,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 4,
        tooltip: '记一笔',
        child: const Icon(Icons.add, size: 26),
      ),
    );
  }

  /// 列表区三态均走 sliver，避免任何一态因高度被挤没而白屏
  List<Widget> _buildBodySlivers() {
    if (_loading) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      ];
    }
    if (_records.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            message: _emptyMessage,
            icon: Icons.receipt_long_outlined,
            actionLabel: '立即记一笔',
            onAction: _openAdd,
          ),
        ),
      ];
    }
    return [_buildListSliver()];
  }

  /// 头部：大标题 + 汇总卡 + 维度切换 + 期间选择 + 账户筛选
  ///
  /// 汇总数字走 [_stats] 而不是自己 fold，这样"已报销的支出按净额计、
  /// 报销收入不重复计入"的口径与分析页、日历页完全一致。
  Widget _buildHeader() {
    final stats = _stats;
    final exp = stats.totalExpense;
    final inc = stats.totalIncome;

    return Container(
      color: AppColors.background,
      // 顶部安全区已由外层 SafeArea 处理，这里不再重复加状态栏高度
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          // 大标题行
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: Row(
              children: [
                const Text(
                  '明细',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                _headerAction(Icons.add, '新增', _openAdd),
              ],
            ),
          ),

          // 汇总卡（主色渐变）
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildSummaryCard(exp, inc),
          ),
          const SizedBox(height: 14),

          // 维度切换
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentTabs<StatsGranularity>(
              values: const [
                StatsGranularity.day,
                StatsGranularity.month,
                StatsGranularity.year,
              ],
              selected: _granularity,
              labelOf: (g) => '按${g.label}',
              onChanged: (g) {
                setState(() {
                  _granularity = g;
                  _collapsed.clear();
                });
                reload();
              },
            ),
          ),
          const SizedBox(height: 12),

          // 期间切换
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: PeriodSwitcher(
              label: _rangeLabel,
              canGoNext: !_isCurrentPeriod,
              onPrev: () => _shift(-1),
              onNext: () => _shift(1),
              onTapCenter: _granularity == StatsGranularity.day
                  ? () async {
                      final d = await pickDate(context, initial: _anchor);
                      if (d != null) {
                        setState(() => _anchor = StatsRange.dayStart(d));
                        reload();
                      }
                    }
                  : _pickMonthOrYear,
            ),
          ),
          const SizedBox(height: 12),

          // 账户筛选
          if (_accounts.length > 1) ...[
            _buildAccountFilterBar(),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }

  Widget _headerAction(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.fill,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, size: 21, color: AppColors.textPrimary),
          ),
        ),
      ),
    );
  }

  /// 汇总卡：主色渐变，支出为视觉重心
  ///
  /// [exp]/[inc] 已是**净额口径**（由 [_stats] 算出）。
  /// 若本区间有报销，额外挂一条说明，免得用户对不上
  /// "我明明花了 1000，怎么这里只有 200"。
  Widget _buildSummaryCard(double exp, double inc) {
    final balance = inc - exp;
    final reimbursed = _stats.totalReimbursed;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      decoration: BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppShape.brandShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '$_rangeLabel支出',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withOpacity(0.75),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${_records.length} 笔',
                  style: const TextStyle(
                      fontSize: 10.5,
                      color: Colors.white,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            child: Text(
              formatMoney(exp),
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: -0.5,
              ),
            ),
          ),
          if (reimbursed > 0) ...[
            const SizedBox(height: 7),
            Row(
              children: [
                Icon(Icons.receipt_long,
                    size: 12, color: Colors.white.withOpacity(0.80)),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '已扣除报销 ${formatMoney(reimbursed)}'
                    '（${_stats.reimbursedCount} 笔）',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withOpacity(0.80),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.14),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Row(
              children: [
                _cardStat('收入', formatMoney(inc)),
                Container(
                    width: 1,
                    height: 26,
                    color: Colors.white.withOpacity(0.22)),
                _cardStat('结余', formatMoney(balance)),
              ],
            ),
          ),
        ],
      ),
    );
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

  Widget _buildListSliver() {
    // 按日期分组，日期倒序
    final grouped = <String, List<BillRecord>>{};
    for (final r in _records) {
      final k = '${r.date.year}-${r.date.month.toString().padLeft(2, '0')}'
          '-${r.date.day.toString().padLeft(2, '0')}';
      grouped.putIfAbsent(k, () => []).add(r);
    }
    final keys = grouped.keys.toList()..sort((a, b) => b.compareTo(a));

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (ctx, i) {
            final key = keys[i];
            final dayRecords = grouped[key]!;
            final dayExp = dayRecords
                .where((r) => r.type == BillType.expense)
                .fold<double>(0.0, (s, r) => s + r.amount);
            final dayInc = dayRecords
                .where((r) => r.type == BillType.income)
                .fold<double>(0.0, (s, r) => s + r.amount);
            final collapsed = _collapsed.contains(key);

            return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: AppColors.cardBg,
            borderRadius: AppShape.card,
            boxShadow: AppShape.softShadow,
          ),
          child: Column(
            children: [
              // 日期分组头
              InkWell(
                onTap: () => setState(() {
                  if (collapsed) {
                    _collapsed.remove(key);
                  } else {
                    _collapsed.add(key);
                  }
                }),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
                  child: Row(
                    children: [
                      Container(
                        width: 3,
                        height: 15,
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Text(
                        _friendlyDay(key),
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        '${dayRecords.length}笔',
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textTertiary),
                      ),
                      const Spacer(),
                      if (dayExp > 0)
                        Text(
                          '-${formatMoney(dayExp)}',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.expense,
                          ),
                        ),
                      if (dayExp > 0 && dayInc > 0)
                        const SizedBox(width: 8),
                      if (dayInc > 0)
                        Text(
                          '+${formatMoney(dayInc)}',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.income,
                          ),
                        ),
                      const SizedBox(width: 6),
                      Icon(
                        collapsed ? Icons.expand_more : Icons.expand_less,
                        size: 18,
                        color: AppColors.textTertiary,
                      ),
                    ],
                  ),
                ),
              ),
              if (!collapsed) ...[
                const Divider(height: 1, indent: 16, endIndent: 16),
                ...dayRecords.map(_buildRecordTile),
              ],
            ],
          ),
        );
          },
          childCount: keys.length,
        ),
      ),
    );
  }

  Widget _buildRecordTile(BillRecord r) {
    final isExpense = r.type == BillType.expense;
    final color = isExpense ? AppColors.expense : AppColors.income;

    // 报销关联信息：
    // - 支出侧：这笔消费被报销了多少（仅当报销收入也在本区间时才算数）
    // - 收入侧：这笔收入是否已并入某笔支出
    final reimbursed = _stats.reimbursedOf(r);
    final isMerged = _stats.isMergedIncome(r);

    return InkWell(
      onTap: () => _openEdit(r),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withOpacity(0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                iconForCategory(r.category, r.type),
                size: 19,
                color: color,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          r.category,
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (reimbursed > 0) ...[
                        const SizedBox(width: 6),
                        _miniBadge('已报销', AppColors.accent),
                      ] else if (isMerged) ...[
                        const SizedBox(width: 6),
                        _miniBadge('报销收入', AppColors.income),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  // 报销相关说明单独一行，避免挤掉账户/备注
                  if (reimbursed > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '自付 ${formatMoney(r.amount - reimbursed)}'
                        '（已报销 ${formatMoney(reimbursed)}）',
                        style: const TextStyle(
                            fontSize: 11.5,
                            color: AppColors.accent,
                            fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    )
                  else if (isMerged)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        _stats.countedIncomeOf(r) > 0.005
                            ? '报销超出消费合计，净收入 '
                                '${formatMoney(_stats.countedIncomeOf(r))}'
                            : '已并入对应消费，不重复计入收入',
                        style: const TextStyle(
                            fontSize: 11.5,
                            color: AppColors.income,
                            fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  Row(
                    children: [
                      // 仅在"全部账户"视图下列出账户名，避免筛完还重复显示
                      if (_accountFilter == kAllAccounts) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: AppColors.fill,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            r.account,
                            style: const TextStyle(
                                fontSize: 10,
                                color: AppColors.textSecondary),
                          ),
                        ),
                        if (r.note.isNotEmpty) const SizedBox(width: 6),
                      ],
                      if (r.note.isNotEmpty)
                        Flexible(
                          child: Text(
                            r.note,
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.textTertiary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 金额显示**原始**发生额（那是这笔交易真实的数字），
            // 净额已在上面那行写清楚，汇总卡才是按净额统计
            Text(
              '${isExpense ? '-' : '+'}${formatMoney(r.amount)}',
              style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: color,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 9.5, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }

  /// 把 2026-09-21 转成"今天 / 昨天 / 09月21日 周一"
  String _friendlyDay(String isoDate) {
    final parts = isoDate.split('-');
    final d = DateTime(
        int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
    final today = StatsRange.dayStart(DateTime.now());
    final diff = today.difference(d).inDays;

    const weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];
    final wd = '周${weekdayNames[d.weekday - 1]}';
    final md = '${d.month.toString().padLeft(2, '0')}月'
        '${d.day.toString().padLeft(2, '0')}日';

    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (d.year != today.year) return '${d.year}年$md';
    return '$md $wd';
  }
}
