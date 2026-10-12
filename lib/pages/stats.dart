import 'package:flutter/material.dart';

import '../account_store.dart';
import '../db.dart';
import '../exporter.dart';
import '../models.dart';
import '../stats.dart';
import '../theme.dart';
import '../widgets/charts.dart';
import '../widgets/common.dart';

/// 统计分析页：按日 / 月 / 年 对消费进行可视化，并可按账户筛选
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => StatsPageState();
}

class StatsPageState extends State<StatsPage> {
  StatsGranularity _granularity = StatsGranularity.month;

  /// 锚点日期：根据粒度取其所在日 / 月 / 年
  DateTime _anchor = DateTime.now();

  /// 饼图/排行展示的维度：支出或收入
  BillType _chartType = BillType.expense;

  /// 账户筛选，默认"全部账户"
  String _accountFilter = kAllAccounts;
  List<AccountDef> _accounts = [];

  /// 预算设置（月总预算 + 周期起始日）
  BudgetSettings _budget = const BudgetSettings();

  /// 当前预算周期状态；未设置预算时为 null
  BudgetStatus? _budgetStatus;

  List<BillRecord> _records = [];
  bool _loading = true;

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
      if (_accountFilter != kAllAccounts &&
          list.every((a) => a.name != _accountFilter)) {
        _accountFilter = kAllAccounts;
      }
    });
    await _loadBudget();
    reload();
  }

  /// 读预算设置。与 reload 分开：改预算不需要重查整段账单
  Future<void> _loadBudget() async {
    try {
      final b = await BillDatabase.instance.loadBudget();
      if (!mounted) return;
      setState(() => _budget = b);
    } catch (_) {
      // 读失败就当没设过预算，不影响分析页其他内容
    }
  }

  Future<void> reload() async {
    if (!mounted) return;
    setState(() => _loading = true);

    try {
      final range = _range();
      final list = await BillDatabase.instance.queryBetween(
        range[0],
        range[1],
        account: _accountFilter,
      );
      if (!mounted) return;
      setState(() {
        _records = list;
        _loading = false;
      });
    } catch (_) {
      // 同明细页：查询失败也要退出 loading，避免停在转圈上被当成白屏
      if (!mounted) return;
      setState(() {
        _records = [];
        _loading = false;
      });
    }
    // 预算状态单独算：以「今天」为锚点，与页面浏览的区间无关
    _reloadBudgetStatus();
  }

  /// 重算当前预算周期状态。
  ///
  /// 两个刻意为之的决定：
  /// 1. **锚点是今天**，不是用户正在看的统计区间——预算回答的是"这个月
  ///    还能花多少"，翻到上个月的历史数据不该让预算数字乱跳；
  /// 2. **按全部账户统计**，不受页面上的账户筛选影响——月总预算是个人
  ///    总额，筛选只是查看角度。
  /// 口径与统计页保持一致：支出按报销冲减后的净额计。
  Future<void> _reloadBudgetStatus() async {
    if (!_budget.enabled) {
      if (!mounted) return;
      setState(() => _budgetStatus = null);
      return;
    }
    try {
      final today = DateTime.now();
      final period = StatsRange.budgetPeriod(today, _budget.startDay);
      final list = await BillDatabase.instance.queryBetween(
        period.start,
        period.end,
      );
      // 借 StatsResult 的分摊口径算净支出，避免两处各写一遍报销冲减
      final s = StatsResult(
        records: list,
        from: period.start,
        to: period.end,
        rangeLabel: '',
      );
      if (!mounted) return;
      setState(() {
        _budgetStatus = BudgetStatus.of(
          monthlyBudget: _budget.monthlyBudget,
          startDay: _budget.startDay,
          periodExpense: s.totalExpense,
          today: today,
        );
      });
    } catch (_) {
      // 算不出来就保持原状：预算卡是附加信息，不该拖垮整个分析页
    }
  }

  List<DateTime> _range() {
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
    });
    reload();
  }

  bool get _isCurrent {
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

  @override
  Widget build(BuildContext context) {
    final range = _range();
    final stats = StatsResult(
      records: _records,
      from: range[0],
      to: range[1],
      rangeLabel: _rangeLabel,
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        top: true,
        bottom: false,
        child: RefreshIndicator(
          onRefresh: reload,
          color: AppColors.primary,
          // 与明细页一致：头部参与滚动，避免高度超标时把图表区挤成 0 高度
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _buildHeader()),
              if (_loading)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child:
                      Center(child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else if (_records.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    message: _emptyMessage,
                    icon: Icons.insert_chart_outlined,
                  ),
                )
              else
                _buildContentSliver(stats),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- 导出 Excel ----------------

  /// 弹出导出选项：按日 / 按月 / 按年
  ///
  /// 导出粒度**独立于当前页面的浏览粒度**——用户可能正在看"按月"，
  /// 但想导出整年的流水，所以单独给一次选择。
  /// 导出范围以当前锚点日期为基准：
  /// - 按日 → 锚点那一天
  /// - 按月 → 锚点所在整月
  /// - 按年 → 锚点所在整年
  Future<void> _showExportSheet() async {
    final choice = await showModalBottomSheet<StatsGranularity>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.fillStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: const [
                  Icon(Icons.ios_share, size: 19, color: AppColors.primary),
                  SizedBox(width: 8),
                  Text(
                    '导出 Excel',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '导出内容含「明细」与「汇总」两个工作表',
                  style: TextStyle(
                      fontSize: 11.5, color: AppColors.textTertiary),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _exportOption(
              ctx,
              StatsGranularity.day,
              '按日导出',
              '${_anchor.year}年${_anchor.month}月${_anchor.day}日 当天流水',
              Icons.today_outlined,
            ),
            _exportOption(
              ctx,
              StatsGranularity.month,
              '按月导出',
              '${_anchor.year}年${_anchor.month}月 整月流水',
              Icons.calendar_month_outlined,
            ),
            _exportOption(
              ctx,
              StatsGranularity.year,
              '按年导出',
              '${_anchor.year}年 全年流水',
              Icons.calendar_today_outlined,
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );

    if (choice == null) return;
    await _doExport(choice);
  }

  Widget _exportOption(
    BuildContext sheetCtx,
    StatsGranularity g,
    String title,
    String subtitle,
    IconData icon,
  ) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.primary.withOpacity(0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, size: 19, color: AppColors.primary),
      ),
      title: Text(title,
          style: const TextStyle(
              fontSize: 14.5, fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle,
          style: const TextStyle(
              fontSize: 11.5, color: AppColors.textTertiary)),
      trailing: const Icon(Icons.chevron_right,
          size: 20, color: AppColors.textTertiary),
      onTap: () => Navigator.pop(sheetCtx, g),
    );
  }

  Future<void> _doExport(StatsGranularity g) async {
    final range = _rangeFor(g);
    final scopeLabel = BillExporter.scopeOf(_anchor, g);

    try {
      // 按所选粒度重新查一遍数据，不能直接用 _records
      // （当前页面可能停在"按月"，而用户选择的是"按年"）
      final records = await BillDatabase.instance.queryBetween(
        range[0],
        range[1],
        account: _accountFilter,
      );

      if (records.isEmpty) {
        if (!mounted) return;
        showToast(context, '$scopeLabel 没有可导出的记录');
        return;
      }

      await BillExporter.export(
        records: records,
        anchor: _anchor,
        granularity: g,
        accountFilter: _accountFilter,
      );

      if (!mounted) return;
      showToast(context, '已导出 $scopeLabel 共 ${records.length} 笔');
    } catch (e) {
      if (!mounted) return;
      showToast(context, '导出失败：$e');
    }
  }

  /// 指定粒度下锚点对应的日期区间（含首尾）
  List<DateTime> _rangeFor(StatsGranularity g) {
    switch (g) {
      case StatsGranularity.day:
      case StatsGranularity.custom:
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
    }
  }

  /// 空状态提示：区分"该账户无数据"与"该周期无数据"
  String get _emptyMessage {
    if (_accountFilter != kAllAccounts) {
      return '$_rangeLabel 的「$_accountFilter」暂无数据\n换个账户或换个周期看看';
    }
    return '$_rangeLabel 暂无数据\n先去记几笔账，这里就会有图表了';
  }

  /// 头部：大标题 + 维度切换 + 期间切换 + 账户筛选
  Widget _buildHeader() {
    return Container(
      color: AppColors.background,
      // 顶部安全区已由外层 SafeArea 处理，这里不再重复加状态栏高度
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: Row(
              children: [
                const Text(
                  '分析',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                Tooltip(
                  message: '导出 Excel',
                  child: Material(
                    color: AppColors.fill,
                    borderRadius: BorderRadius.circular(11),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(11),
                      onTap: _loading ? null : _showExportSheet,
                      child: const SizedBox(
                        width: 38,
                        height: 38,
                        child: Icon(Icons.ios_share,
                            size: 19, color: AppColors.textPrimary),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: '刷新',
                  child: Material(
                    color: AppColors.fill,
                    borderRadius: BorderRadius.circular(11),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(11),
                      onTap: reload,
                      child: const SizedBox(
                        width: 38,
                        height: 38,
                        child: Icon(Icons.refresh,
                            size: 20, color: AppColors.textPrimary),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
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
                setState(() => _granularity = g);
                reload();
              },
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: PeriodSwitcher(
              label: _rangeLabel,
              canGoNext: !_isCurrent,
              centerIcon: Icons.event,
              onPrev: () => _shift(-1),
              onNext: () => _shift(1),
              onTapCenter: () async {
                final d = await pickDate(context, initial: _anchor);
                if (d != null) {
                  setState(() => _anchor = d);
                  reload();
                }
              },
            ),
          ),
          const SizedBox(height: 12),
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

  /// 内容区同样走 sliver：与明细页保持一致，头部再高也不会挤没内容
  Widget _buildContentSliver(StatsResult stats) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 30),
      sliver: SliverList(
        delegate: SliverChildListDelegate([
          _buildOverviewCard(stats),
          const SizedBox(height: 12),
          _buildBudgetCard(),
          const SizedBox(height: 12),
          _buildTrendCard(stats),
          const SizedBox(height: 12),
          _buildCategoryCard(stats),
          const SizedBox(height: 12),
          if (_granularity != StatsGranularity.day) _buildWeekdayCard(stats),
          if (_granularity != StatsGranularity.day) const SizedBox(height: 12),
          _buildInsightCard(stats),
        ]),
      ),
    );
  }

  // ---------------- 概览 ----------------

  Widget _buildOverviewCard(StatsResult s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        gradient: AppColors.brandGradient,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppShape.brandShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${s.rangeLabel} 支出合计',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withOpacity(0.75),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          FittedBox(
            child: Text(
              formatMoney(s.totalExpense),
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: -0.5,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.fromLTRB(6, 14, 6, 14),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.14),
              borderRadius: BorderRadius.circular(13),
            ),
            // 原先 4 项挤在一行用 Expanded 平分宽度，像 ¥10,804.29 这种
            // 六七位数字会互相贴在一起，分不清哪个数字属于哪个标签。
            // 改为 2×2 网格：数字有独立的水平空间，右侧也不再被邻居侵蚀。
            child: Column(
              children: [
                Row(
                  children: [
                    _miniStat('收入', formatMoney(s.totalIncome)),
                    _miniStat('结余', formatMoney(s.balance)),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    _miniStat('笔数', '${s.recordCount}', unit: '笔'),
                    _miniStat(
                        '日均支出', formatMoney(s.avgDailyExpense)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 概览卡里的小指标块
  ///
  /// 用 Expanded 平分所在行，但数字改用 AutoSizeText 式的自适应缩小 +
  /// 标签与数字上下分层，保证长金额不会溢出到隔壁格子里。
  Widget _miniStat(String label, String value, {String? unit}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: Colors.white.withOpacity(0.68),
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 5),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: -0.2,
                    ),
                  ),
                  if (unit != null) ...[
                    const SizedBox(width: 2),
                    Text(
                      unit,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withOpacity(0.70),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 趋势 ----------------

  Widget _buildTrendCard(StatsResult s) {
    // 日视图 -> 展示当天的分类构成即可，趋势图意义不大
    // 月视图 -> 按日展示；年视图 -> 按月展示
    final isYear = _granularity == StatsGranularity.year;
    final slices = isYear ? s.byMonth() : s.byDay();
    final title = isYear ? '月度支出趋势' : '每日支出趋势';

    return SectionCard(
      title: title,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 14, 14),
        child: TrendChart(
          slices: slices,
          height: 200,
          showIncome: false,
        ),
      ),
    );
  }

  // ---------------- 分类构成 ----------------

  Widget _buildCategoryCard(StatsResult s) {
    final isExpense = _chartType == BillType.expense;
    final byCat = s.byCategory(type: _chartType);
    final total = byCat.fold<double>(0.0, (a, e) => a + e.total);
    final maxV = byCat.isEmpty ? 0.0 : byCat.first.total;

    return SectionCard(
      title: '分类构成',
      trailing: Container(
        decoration: BoxDecoration(
          color: AppColors.fill,
          borderRadius: BorderRadius.circular(9),
        ),
        padding: const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _chartTypeBtn('支出', BillType.expense),
            _chartTypeBtn('收入', BillType.income),
          ],
        ),
      ),
      child: byCat.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 34),
              child: Center(
                child: Text(
                  '本期没有该类型的记录',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.textSecondary),
                ),
              ),
            )
          : Column(
              children: [
                const SizedBox(height: 10),
                Center(
                  child: DonutChart(
                    slices: byCat,
                    size: 186,
                    strokeWidth: 24,
                    centerTitle: isExpense ? '总支出' : '总收入',
                    centerValue: formatMoney(total),
                  ),
                ),
                const SizedBox(height: 18),
                const Divider(height: 1, indent: 16, endIndent: 16),
                const SizedBox(height: 4),
                ...List.generate(byCat.length, (i) {
                  return BarRow(
                    slice: byCat[i],
                    maxValue: maxV,
                    color: AppColors.paletteAt(i),
                  );
                }),
                const SizedBox(height: 8),
              ],
            ),
    );
  }

  Widget _chartTypeBtn(String label, BillType t) {
    final selected = _chartType == t;
    return GestureDetector(
      onTap: () => setState(() => _chartType = t),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: const Color(0xFF1F2233).withOpacity(0.07),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  )
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color:
                selected ? AppColors.primary : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  // ---------------- 星期分布 ----------------

  Widget _buildWeekdayCard(StatsResult s) {
    final byWd = s.byWeekday();
    final hasData = byWd.any((e) => e.total > 0);
    if (!hasData) return const SizedBox.shrink();

    return SectionCard(
      title: '消费星期分布',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
        child: Column(
          children: [
            ColumnChart(slices: byWd, height: 160),
            const SizedBox(height: 8),
            const Text(
              '看看你的钱主要花在周几',
              style: TextStyle(fontSize: 11, color: AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 洞察小结 ----------------

  Widget _buildInsightCard(StatsResult s) {
    final insights = <String>[];

    final byCat = s.byCategory(type: BillType.expense);
    if (byCat.isNotEmpty && s.totalExpense > 0) {
      final top = byCat.first;
      final pct = top.total / s.totalExpense * 100;
      insights.add(
          '「${top.label}」是最大开销项，占支出的 ${pct.toStringAsFixed(1)}%（${formatMoney(top.total)}）。');
    }

    final maxR = s.maxExpense;
    if (maxR != null) {
      insights.add(
          '单笔最高支出：${formatMoney(maxR.amount)}，分类为「${maxR.category}」'
          '（${maxR.date.month}月${maxR.date.day}日）'
          '${maxR.note.isNotEmpty ? '，备注：${maxR.note}' : ''}。');
    }

    if (s.expenseDayCount > 0) {
      insights.add(
          '本期有 ${s.expenseDayCount} 天有消费，日均支出 ${formatMoney(s.avgDailyExpense)}。');
    }

    // 报销/分摊：明确告知支出已是净额，否则用户会觉得数字"少了"
    if (s.totalReimbursed > 0) {
      insights.add(
          '本期有 ${s.reimbursedCount} 笔消费被报销或分摊，'
          '合计 ${formatMoney(s.totalReimbursed)}；'
          '上面的支出已按「消费 − 报销」的实际自付口径统计'
          '（报销大于消费时，超出部分计入收入）。');
    }

    if (s.totalIncome > 0) {
      final rate = s.balance / s.totalIncome * 100;
      insights.add(
          '收入 ${formatMoney(s.totalIncome)}，结余 ${formatMoney(s.balance)}，储蓄率约 ${rate.toStringAsFixed(1)}%。');
    }

    final byWd = s.byWeekday();
    if (byWd.any((e) => e.total > 0)) {
      final top = byWd.reduce((a, b) => a.total >= b.total ? a : b);
      insights.add('花费最多的日子是${top.label}，累计 ${formatMoney(top.total)}。');
    }

    if (insights.isEmpty) return const SizedBox.shrink();

    return SectionCard(
      title: '数据洞察',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: insights
              .map((t) => Padding(
                    padding: const EdgeInsets.only(bottom: 11),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          margin: const EdgeInsets.only(top: 6),
                          width: 5,
                          height: 5,
                          decoration: const BoxDecoration(
                            color: AppColors.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            t,
                            style: const TextStyle(
                              fontSize: 13,
                              height: 1.6,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ))
              .toList(),
        ),
      ),
    );
  }

  // ---------------- 预算 ----------------

  /// 分析页预算卡：未设置时给一个设置入口，设置后展示剩余额度与进度
  Widget _buildBudgetCard() {
    final s = _budgetStatus;
    if (s == null) return _buildBudgetSetupCard();

    final overspent = s.overspent;
    // 进度条只画 0-1：超支时画满并用红色，别让宽度因子 >1 把布局撑爆
    final barRatio = s.ratio.clamp(0.0, 1.0);
    return SectionCard(
      title: '本月预算',
      trailing: IconButton(
        icon: const Icon(Icons.tune, size: 18, color: AppColors.textSecondary),
        tooltip: '预算设置',
        onPressed: _showBudgetSheet,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  overspent ? '已超支' : '剩余预算',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                Text(
                  '周期 ${_fmtDate(s.period.start)} ~ ${_fmtDate(s.period.end)}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                formatMoney(s.remaining.abs()),
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: overspent ? AppColors.expense : AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 8,
                child: Stack(
                  children: [
                    Container(color: AppColors.fill),
                    FractionallySizedBox(
                      widthFactor: barRatio,
                      child: Container(
                        color: overspent
                            ? AppColors.expense
                            : (s.ratio > 0.8
                                ? AppColors.accent
                                : AppColors.primary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _budgetStat('已用', formatMoney(s.used)),
                _budgetStat('剩余天数', '${s.daysLeft} 天'),
                _budgetStat('日均可用', formatMoney(s.dailyAvailable)),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '月总预算 ${formatMoney(s.budget)} · 共 ${s.totalDays} 天 · '
              '第 ${s.dayIndex} 天；支出按报销冲减后的净额统计',
              style: const TextStyle(
                fontSize: 11,
                height: 1.5,
                color: AppColors.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 预算卡里的小指标（白底深字，与概览卡的反白风格区分）
  Widget _budgetStat(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 10.5,
              color: AppColors.textTertiary,
            ),
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 未设置预算时的引导卡：点整张卡直接打开设置
  Widget _buildBudgetSetupCard() {
    return SectionCard(
      title: '本月预算',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _showBudgetSheet,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
            decoration: BoxDecoration(
              color: AppColors.fill,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.account_balance_wallet_outlined,
                    size: 20,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        '设置月预算',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        '自定义月总预算与周期起始日，剩余额度实时可见',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppColors.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 打开预算设置弹窗；保存成功后重新读取设置并重算预算状态
  Future<void> _showBudgetSheet() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _BudgetSheet(initial: _budget),
    );
    if (saved == true) {
      await _loadBudget();
      _reloadBudgetStatus();
    }
  }
}

/// 预算设置弹窗：月总预算 + 周期起始日
class _BudgetSheet extends StatefulWidget {
  const _BudgetSheet({required this.initial});

  final BudgetSettings initial;

  @override
  State<_BudgetSheet> createState() => _BudgetSheetState();
}

class _BudgetSheetState extends State<_BudgetSheet> {
  late final TextEditingController _budgetCtrl;
  late final TextEditingController _dayCtrl;
  late int _startDay;
  String? _error;

  /// 常用起始日：月初、月中、月末各取几个，剩下的走自定义输入
  static const _quickDays = [1, 5, 10, 15, 20, 25, 28];

  @override
  void initState() {
    super.initState();
    final mb = widget.initial.monthlyBudget;
    _budgetCtrl = TextEditingController(
      text: mb <= 0
          ? ''
          : (mb == mb.roundToDouble() ? mb.toStringAsFixed(0) : mb.toString()),
    );
    _startDay = widget.initial.startDay;
    _dayCtrl = TextEditingController(text: '$_startDay');
  }

  @override
  void dispose() {
    _budgetCtrl.dispose();
    _dayCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final b = double.tryParse(_budgetCtrl.text.trim());
    if (b == null || b <= 0) {
      setState(() => _error = '请输入大于 0 的月总预算');
      return;
    }
    // 起始日 clamp 到 1-28：31 号在 2 月不存在，周期计算会直接抛异常
    final d = int.tryParse(_dayCtrl.text.trim());
    final sd = (d ?? 1).clamp(1, 28);
    try {
      await BillDatabase.instance.saveBudget(
        BudgetSettings(monthlyBudget: b, startDay: sd),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '保存失败，请重试');
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  void _pickDay(int d) {
    setState(() {
      _startDay = d;
      _dayCtrl.text = '$d';
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        // 键盘弹起时把内容顶上去，否则输入框会被键盘挡住
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.fillStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: const [
                  Icon(Icons.savings_outlined,
                      size: 19, color: AppColors.primary),
                  SizedBox(width: 8),
                  Text(
                    '预算设置',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                '预算按全部账户统计；支出已按报销冲减后的净额计',
                style: TextStyle(
                    fontSize: 11.5, color: AppColors.textTertiary),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _budgetCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: '月总预算',
                  hintText: '例如 3000',
                  prefixText: '¥ ',
                  filled: true,
                  fillColor: AppColors.fill,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                '周期起始日',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: _quickDays.map((d) {
                  final sel = _startDay == d;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('$d 日'),
                      selected: sel,
                      onSelected: (_) => _pickDay(d),
                      selectedColor: AppColors.primary,
                      labelStyle: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: sel ? Colors.white : AppColors.textPrimary,
                      ),
                      backgroundColor: AppColors.fill,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _dayCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: '自定义起始日（1-28）',
                  hintText: '发薪日等任意一天',
                  filled: true,
                  fillColor: AppColors.fill,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (v) {
                  final d = int.tryParse(v.trim());
                  if (d != null && d >= 1 && d <= 28 && d != _startDay) {
                    setState(() => _startDay = d);
                  }
                },
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.expense,
                  ),
                ),
              ),
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _save,
                  style: ElevatedButton.styleFrom(
                    primary: AppColors.primary,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    '保存',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            // 已设过预算才给清除入口：存 0 即"未设置"，别让设了预算的用户
            // 除了改数字以外没有退路
            if (widget.initial.enabled)
              TextButton(
                onPressed: _clear,
                child: const Text(
                  '清除预算',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// 清除预算：写回 0（fromRows 会把 0 视为未设置），比"删两行 key"
  /// 更不容易留下半截状态
  Future<void> _clear() async {
    try {
      await BillDatabase.instance.saveBudget(const BudgetSettings());
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '清除失败，请重试');
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }
}
