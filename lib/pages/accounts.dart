import 'package:flutter/material.dart';

import '../account_store.dart';
import '../db.dart';
import '../models.dart';
import '../stats.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'transfer.dart';

/// 账户管理：增删改账户，并查看每个账户当前区间的收支
class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key, this.embedded = false, this.onChanged});

  /// 作为底部导航的一个 Tab 内嵌时置 true：此时 AppBar 不显示返回按钮。
  final bool embedded;

  /// 账户发生增删改名后回调，供外层刷新其它页面的筛选项
  final VoidCallback? onChanged;

  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  List<AccountDef> _accounts = [];
  Map<String, AccountSummary> _summary = {};
  bool _loading = true;

  /// 汇总区间：当年 1 月 1 日至今，覆盖全年视角
  late DateTime _from;
  late DateTime _to;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, 1, 1);
    _to = DateTime(now.year, 12, 31);
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);

    final list = await AccountStore.instance.load(force: true);
    final sums = await BillDatabase.instance.summaryByAccount(_from, _to);

    if (!mounted) return;
    setState(() {
      _accounts = list;
      _summary = {for (final s in sums) s.account: s};
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          // 头部：大标题
          Container(
            color: AppColors.background,
            padding:
                EdgeInsets.only(top: MediaQuery.of(context).padding.top + 12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Row(
                children: [
                  const Text(
                    '账户',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const Spacer(),
                  Tooltip(
                    message: '账户转账',
                    child: Material(
                      color: AppColors.fill,
                      borderRadius: BorderRadius.circular(11),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(11),
                        onTap: _accounts.length < 2 ? null : _openTransfers,
                        child: const SizedBox(
                          width: 38,
                          height: 38,
                          child: Icon(Icons.swap_horiz,
                              size: 20, color: AppColors.textPrimary),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: '新增账户',
                    child: Material(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(11),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(11),
                        onTap: () => _editAccount(null),
                        child: const SizedBox(
                          width: 38,
                          height: 38,
                          child: Icon(Icons.add,
                              size: 21, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(strokeWidth: 2))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                    children: [
                      _buildTotalCard(),
                      const SizedBox(height: 12),
                      if (_accounts.isEmpty)
                        EmptyState(
                          message: '还没有任何账户\n先新建一个，记账时就能选了',
                          icon: Icons.account_balance_wallet_outlined,
                          actionLabel: '新建账户',
                          onAction: () => _editAccount(null),
                        )
                      else ...[
                        Row(
                          children: [
                            const Text(
                              '我的账户',
                              style: TextStyle(
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
                                '${_accounts.length} 个',
                                style: const TextStyle(
                                    fontSize: 10.5,
                                    color: AppColors.textSecondary),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Container(
                          decoration: BoxDecoration(
                            color: AppColors.cardBg,
                            borderRadius: AppShape.card,
                            boxShadow: AppShape.softShadow,
                          ),
                          child: Column(
                            children: [
                              for (int i = 0; i < _accounts.length; i++) ...[
                                if (i > 0)
                                  const Divider(height: 1, indent: 68),
                                _buildAccountTile(_accounts[i]),
                              ],
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Icon(Icons.info_outline,
                                size: 16, color: AppColors.primary),
                            SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                '余额 = 期初余额 + 收入 + 转入 − 支出 − 转出。\n'
                                '点账户可设置期初余额；右上角可记账户间转账。\n'
                                '若某账户下已有账单，删除时会被拦截，避免误删历史数据。',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  height: 1.6,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 顶部总览卡：所有账户合计
  ///
  /// 这里展示的是**真实余额**，不是"收入减支出"：
  ///   余额 = 期初 + 收入 + 转入 − 支出 − 转出
  /// 转账在两账户间一进一出，合计恒为 0，不会虚增总额。
  Widget _buildTotalCard() {
    double totalExp = 0, totalInc = 0, totalBalance = 0;
    for (final s in _summary.values) {
      totalExp += s.expense;
      totalInc += s.income;
      totalBalance += s.balance;
    }

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
          Text(
            '全部账户总余额',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withOpacity(0.75),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          FittedBox(
            child: Text(
              formatMoney(totalBalance),
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
                _cardStat('累计支出', formatMoney(totalExp)),
                Container(
                    width: 1,
                    height: 26,
                    color: Colors.white.withOpacity(0.22)),
                _cardStat('累计收入', formatMoney(totalInc)),
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

  Widget _buildAccountTile(AccountDef a) {
    final s = _summary[a.name];
    final exp = s?.expense ?? 0;
    final inc = s?.income ?? 0;
    final init = s?.initialBalance ?? a.initialBalance;
    final tIn = s?.transferIn ?? 0;
    final tOut = s?.transferOut ?? 0;
    // 真实余额：期初 + 收入 + 转入 − 支出 − 转出
    final balance = s?.balance ?? init;

    // 副标题按信息量动态组装，没有的部分不占位置
    final parts = <String>[
      '支出 ${formatMoney(exp)}',
      '收入 ${formatMoney(inc)}',
      if (init != 0) '期初 ${formatMoney(init)}',
      if (tIn > 0) '转入 ${formatMoney(tIn)}',
      if (tOut > 0) '转出 ${formatMoney(tOut)}',
    ];

    return InkWell(
      onTap: () => _editAccount(a),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child:
                      Icon(a.icon, size: 19, color: AppColors.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a.name,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        parts.join(' · '),
                        style: const TextStyle(
                            fontSize: 11.5,
                            color: AppColors.textTertiary),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    FittedBox(
                      child: Text(
                        formatMoney(balance),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: balance >= 0
                              ? AppColors.income
                              : AppColors.expense,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 3),
                    const Text('余额',
                        style: TextStyle(
                            fontSize: 10,
                            color: AppColors.textTertiary)),
                  ],
                ),
                const SizedBox(width: 2),
                const Icon(Icons.chevron_right,
                    size: 20, color: AppColors.textTertiary),
              ],
            ),
            // 有转账时给一条转入/转出占比条，一眼看出资金流动
            if (tIn > 0 || tOut > 0) ...[
              const SizedBox(height: 11),
              _transferBar(tIn, tOut),
            ],
          ],
        ),
      ),
    );
  }

  /// 转入 / 转出 的比例条
  Widget _transferBar(double tIn, double tOut) {
    final total = tIn + tOut;
    final inRatio = total == 0 ? 0.0 : tIn / total;
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Row(
            children: [
              Expanded(
                flex: (inRatio * 1000).round().clamp(1, 999),
                child: Container(height: 5, color: AppColors.income),
              ),
              Expanded(
                flex: ((1 - inRatio) * 1000).round().clamp(1, 999),
                child: Container(height: 5, color: AppColors.expense),
              ),
            ],
          ),
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            const Icon(Icons.south_west,
                size: 11, color: AppColors.income),
            const SizedBox(width: 3),
            Text('转入 ${formatMoney(tIn)}',
                style: const TextStyle(
                    fontSize: 10, color: AppColors.textTertiary)),
            const SizedBox(width: 12),
            const Icon(Icons.north_east,
                size: 11, color: AppColors.expense),
            const SizedBox(width: 3),
            Text('转出 ${formatMoney(tOut)}',
                style: const TextStyle(
                    fontSize: 10, color: AppColors.textTertiary)),
          ],
        ),
      ],
    );
  }

  /// [target] 为 null 表示新建
  Future<void> _editAccount(AccountDef? target) async {
    final isNew = target == null;
    final nameCtrl = TextEditingController(text: target?.name ?? '');
    final initCtrl = TextEditingController(
      text: target == null || target.initialBalance == 0
          ? ''
          : (target.initialBalance == target.initialBalance.roundToDouble()
              ? target.initialBalance.toStringAsFixed(0)
              : target.initialBalance.toStringAsFixed(2)),
    );
    IconData picked = target?.icon ?? kAccountIconChoices.first;
    final formKey = GlobalKey<FormState>();

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(isNew ? '新建账户' : '编辑账户',
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w700)),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: nameCtrl,
                    maxLength: 10,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: '账户名称',
                      hintText: '如：招行储蓄卡',
                      counterText: '',
                      filled: true,
                      fillColor: AppColors.fill,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    validator: (v) {
                      final t = (v ?? '').trim();
                      if (t.isEmpty) return '请输入账户名称';
                      if (t == kAllAccounts) return '该名称为系统保留';
                      final dup = _accounts
                          .any((a) => a.name == t && a.name != target?.name);
                      if (dup) return '已存在同名账户';
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: initCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: InputDecoration(
                      labelText: '期初余额（选填）',
                      hintText: '0.00',
                      prefixText: '¥ ',
                      helperText: '开始记账前，这个账户里已有的钱',
                      helperStyle: const TextStyle(
                          fontSize: 11, color: AppColors.textTertiary),
                      filled: true,
                      fillColor: AppColors.fill,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    validator: (v) {
                      final t = (v ?? '').trim();
                      if (t.isEmpty) return null;
                      final d = double.tryParse(t);
                      if (d == null) return '请输入数字';
                      if (d.abs() > 999999999) return '金额过大';
                      return null;
                    },
                  ),
                  const SizedBox(height: 18),
                  const Text('选择图标',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: kAccountIconChoices.map((ic) {
                      final sel = ic.codePoint == picked.codePoint;
                      return GestureDetector(
                        onTap: () => setSt(() => picked = ic),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: sel
                                ? AppColors.primary.withOpacity(0.12)
                                : AppColors.fill,
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                              color: sel
                                  ? AppColors.primary
                                  : Colors.transparent,
                              width: 1.6,
                            ),
                          ),
                          child: Icon(
                            ic,
                            size: 19,
                            color: sel
                                ? AppColors.primary
                                : AppColors.textSecondary,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (!isNew)
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx, false);
                  _confirmDelete(target);
                },
                style: TextButton.styleFrom(primary: AppColors.expense),
                child: const Text('删除'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                if (formKey.currentState?.validate() != true) return;
                Navigator.pop(ctx, true);
              },
              style: TextButton.styleFrom(primary: AppColors.primary),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    final newName = nameCtrl.text.trim();
    final initText = initCtrl.text.trim();
    final initValue =
        initText.isEmpty ? 0.0 : (double.tryParse(initText) ?? 0.0);
    nameCtrl.dispose();
    initCtrl.dispose();

    if (saved != true || !mounted) return;

    if (isNew) {
      await BillDatabase.instance.addAccount(newName, picked);
      if (initValue != 0) {
        await BillDatabase.instance
            .updateAccountInitialBalance(newName, initValue);
      }
    } else {
      final oldName = target.name;
      if (oldName != newName) {
        await BillDatabase.instance.renameAccount(oldName, newName);
      }
      if (oldName != newName || picked.codePoint != target.icon.codePoint) {
        await BillDatabase.instance.updateAccountIcon(newName, picked);
      }
      // 期初余额改了才写库，避免无谓的写操作
      if (initValue != target.initialBalance) {
        await BillDatabase.instance
            .updateAccountInitialBalance(newName, initValue);
      }
    }

    if (!mounted) return;
    showToast(context, isNew ? '账户已创建' : '账户已更新');
    widget.onChanged?.call();
    _load();
  }

  /// 打开转账页；转账会改变余额，回来后必须刷新
  Future<void> _openTransfers() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TransferPage(onChanged: () => _load()),
      ),
    );
    if (!mounted) return;
    _load();
  }

  Future<void> _confirmDelete(AccountDef a) async {
    final used = await BillDatabase.instance.countByAccount(a.name);
    if (!mounted) return;

    if (used > 0) {
      showToast(context, '「${a.name}」下还有 $used 条账单，无法删除');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账户'),
        content: Text('确认删除账户「${a.name}」吗？该账户下暂无账单。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(primary: AppColors.expense),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await BillDatabase.instance.deleteAccount(a.name);
    if (!mounted) return;
    showToast(context, '账户已删除');
    widget.onChanged?.call();
    _load();
  }
}
