import 'package:flutter/material.dart';

import '../account_store.dart';
import '../db.dart';
import '../models.dart';
import '../stats.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// 转账记录页：查看与管理账户之间的资金划转
///
/// 为什么单独一个页面而不是塞进账单列表：
/// 账户间转账**既不是收入也不是支出**，它只是钱从左口袋换到右口袋。
/// 如果写进 bills 表，总支出/总收入/分类占比全部会被污染。
/// 所以它单独存 transfers 表，也单独在这里展示。
class TransferPage extends StatefulWidget {
  /// 作为独立页面打开（从账户页进入）时为 false
  final bool embedded;

  /// 转账发生变化后回调，供外层刷新账户余额
  final VoidCallback? onChanged;

  const TransferPage({super.key, this.embedded = false, this.onChanged});

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  List<AccountDef> _accounts = [];
  List<TransferRecord> _records = [];
  bool _loading = true;

  /// 默认展示当年
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

    final accounts = await AccountStore.instance.load();
    List<TransferRecord> list;
    try {
      list = await BillDatabase.instance.queryTransfersBetween(_from, _to);
    } catch (_) {
      list = [];
    }

    if (!mounted) return;
    setState(() {
      _accounts = accounts;
      _records = list;
      _loading = false;
    });
  }

  double get _totalAmount =>
      _records.fold<double>(0, (a, r) => a + r.amount);

  @override
  Widget build(BuildContext context) {
    final body = _loading
        ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
        : RefreshIndicator(
            onRefresh: _load,
            color: AppColors.primary,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                  16, widget.embedded ? 0 : 8, 16, 100),
              children: [
                _buildSummaryCard(),
                const SizedBox(height: 16),
                if (_records.isEmpty)
                  EmptyState(
                    message: '${_from.year} 年还没有转账记录\n'
                        '账户之间挪钱时记一笔，余额才算得准',
                    icon: Icons.swap_horiz,
                    actionLabel: '记一笔转账',
                    onAction: _accounts.length < 2
                        ? null
                        : () => _editTransfer(null),
                  )
                else ...[
                  Row(
                    children: [
                      const Text(
                        '转账记录',
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
                          '${_records.length} 笔',
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
                        for (int i = 0; i < _records.length; i++) ...[
                          if (i > 0) const Divider(height: 1, indent: 68),
                          _buildTile(_records[i]),
                        ],
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                _buildHintCard(),
              ],
            ),
          );

    if (widget.embedded) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: const Text('账户转账')),
        body: body,
        floatingActionButton: _accounts.length < 2
            ? null
            : FloatingActionButton(
                onPressed: () => _editTransfer(null),
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                child: const Icon(Icons.add, size: 26),
              ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        top: true,
        bottom: false,
        child: Column(
          children: [
            Container(
              color: AppColors.background,
              padding: const EdgeInsets.only(top: 12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 20, 14),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back,
                          color: AppColors.textPrimary),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Text(
                      '账户转账',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
      floatingActionButton: _accounts.length < 2
          ? null
          : FloatingActionButton(
              onPressed: () => _editTransfer(null),
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              child: const Icon(Icons.add, size: 26),
            ),
    );
  }

  /// 顶部汇总：本期转账总额
  Widget _buildSummaryCard() {
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
            '${_from.year} 年转账总额',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withOpacity(0.75),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          FittedBox(
            child: Text(
              formatMoney(_totalAmount),
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: -0.5,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.info_outline,
                  size: 13, color: Colors.white.withOpacity(0.72)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '转账不计入收支，只改变各账户的余额',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withOpacity(0.72),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTile(TransferRecord t) {
    return InkWell(
      onTap: () => _editTransfer(t),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
        child: Row(
          children: [
            // 转出 → 转入 的视觉表达
            SizedBox(
              width: 40,
              height: 40,
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    top: 2,
                    child: _miniIcon(AccountStore.instance.iconOf(t.fromAccount)),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: _miniIcon(
                          AccountStore.instance.iconOf(t.toAccount),
                          size: 17),
                    ),
                  ),
                ],
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
                          t.fromAccount,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(Icons.arrow_forward,
                            size: 13, color: AppColors.textTertiary),
                      ),
                      Flexible(
                        child: Text(
                          t.toAccount,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_fmtDate(t.date)}${t.note.isNotEmpty ? ' · ${t.note}' : ''}',
                    style: const TextStyle(
                        fontSize: 11.5, color: AppColors.textTertiary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              formatMoney(t.amount),
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: AppColors.primary,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.chevron_right,
                size: 20, color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }

  Widget _miniIcon(IconData icon, {double size = 22}) {
    return Container(
      width: size + 8,
      height: size + 8,
      decoration: BoxDecoration(
        color: AppColors.fill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: size * 0.62, color: AppColors.textSecondary),
    );
  }

  Widget _buildHintCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.06),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Icon(Icons.lightbulb_outline, size: 16, color: AppColors.primary),
          SizedBox(width: 9),
          Expanded(
            child: Text(
              '典型场景：把微信零钱提到银行卡、从支付宝转钱还信用卡。\n'
              '这类操作不是消费，记成转账才能如实反映各账户余额。',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.6,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 新增 / 编辑 ----------------

  /// [target] 为 null 表示新增
  Future<void> _editTransfer(TransferRecord? target) async {
    if (_accounts.length < 2) {
      showToast(context, '至少需要 2 个账户才能转账');
      return;
    }

    final isNew = target == null;
    final amountCtrl = TextEditingController(
      text: target == null
          ? ''
          : (target.amount == target.amount.roundToDouble()
              ? target.amount.toStringAsFixed(0)
              : target.amount.toStringAsFixed(2)),
    );
    final noteCtrl = TextEditingController(text: target?.note ?? '');

    String from = target?.fromAccount ?? _accounts[0].name;
    String to = target?.toAccount ?? _accounts[1].name;
    // 新建时保证转出/转入不重复
    if (to == from) {
      to = _accounts.firstWhere((a) => a.name != from).name;
    }
    DateTime date = target?.date ?? StatsRange.dayStart(DateTime.now());

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSt) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                    Row(
                      children: [
                        Text(
                          isNew ? '记一笔转账' : '编辑转账',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const Spacer(),
                        if (!isNew)
                          TextButton(
                            onPressed: () {
                              Navigator.pop(sheetCtx, false);
                              _confirmDelete(target);
                            },
                            style: TextButton.styleFrom(
                                primary: AppColors.expense),
                            child: const Text('删除'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // -------- 金额 --------
                    Container(
                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                      decoration: BoxDecoration(
                        color: AppColors.fill,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('转账金额',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Text('¥',
                                  style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.primary)),
                              const SizedBox(width: 6),
                              Expanded(
                                child: TextField(
                                  controller: amountCtrl,
                                  autofocus: true,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                          decimal: true),
                                  style: const TextStyle(
                                    fontSize: 30,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.primary,
                                    letterSpacing: -0.5,
                                  ),
                                  decoration: const InputDecoration(
                                    hintText: '0.00',
                                    hintStyle: TextStyle(
                                      fontSize: 30,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.textTertiary,
                                      letterSpacing: -0.5,
                                    ),
                                    isDense: true,
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // -------- 转出账户 --------
                    _buildAccountPicker(
                      title: '从哪个账户转出',
                      accounts: _accounts,
                      selected: from,
                      onPick: (name) {
                        setSt(() {
                          from = name;
                          // 转出与转入不能是同一个账户，自动错开
                          if (to == name) {
                            to = _accounts
                                .firstWhere((a) => a.name != name)
                                .name;
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 14),
                    Center(
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: AppColors.primary.withOpacity(0.10),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.arrow_downward,
                            size: 18, color: AppColors.primary),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // -------- 转入账户 --------
                    _buildAccountPicker(
                      title: '转到哪个账户',
                      accounts: _accounts,
                      selected: to,
                      onPick: (name) {
                        setSt(() {
                          to = name;
                          if (from == name) {
                            from = _accounts
                                .firstWhere((a) => a.name != name)
                                .name;
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 20),

                    // -------- 日期与备注 --------
                    Container(
                      decoration: BoxDecoration(
                        color: AppColors.fill,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        children: [
                          ListTile(
                            leading: const Icon(Icons.event,
                                size: 19, color: AppColors.textSecondary),
                            title: const Text('日期',
                                style: TextStyle(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w600)),
                            trailing: Text(
                              _fmtDate(date),
                              style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            onTap: () async {
                              final d = await pickDate(ctx, initial: date);
                              if (d != null) {
                                setSt(() => date = StatsRange.dayStart(d));
                              }
                            },
                          ),
                          const Divider(height: 1, indent: 56),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                            child: TextField(
                              controller: noteCtrl,
                              maxLength: 50,
                              decoration: const InputDecoration(
                                icon: Icon(Icons.edit_note,
                                    size: 19,
                                    color: AppColors.textSecondary),
                                hintText: '备注（选填），如"提现到银行卡"',
                                hintStyle: TextStyle(
                                    fontSize: 13,
                                    color: AppColors.textTertiary),
                                border: InputBorder.none,
                                counterText: '',
                              ),
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),

                    SizedBox(
                      height: 50,
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(sheetCtx, true),
                        style: ElevatedButton.styleFrom(
                          primary: AppColors.primary,
                          onPrimary: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        child: Text(
                          isNew ? '保存' : '保存修改',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );

    final amount = double.tryParse(amountCtrl.text.trim());
    final note = noteCtrl.text.trim();
    amountCtrl.dispose();
    noteCtrl.dispose();

    if (saved != true || !mounted) return;

    if (amount == null || amount <= 0) {
      showToast(context, '请输入有效金额');
      return;
    }
    if (amount > 99999999) {
      showToast(context, '金额过大，请检查输入');
      return;
    }

    final record = TransferRecord(
      id: target?.id,
      fromAccount: from,
      toAccount: to,
      amount: amount,
      note: note,
      date: date,
      createdAt: target?.createdAt ?? DateTime.now(),
    );

    try {
      if (isNew) {
        await BillDatabase.instance.insertTransfer(record);
      } else {
        await BillDatabase.instance.updateTransfer(record);
      }
    } catch (e) {
      if (!mounted) return;
      showToast(context, '保存失败：$e');
      return;
    }

    if (!mounted) return;
    showToast(context, isNew ? '转账已记录' : '转账已更新');
    widget.onChanged?.call();
    _load();
  }

  Widget _buildAccountPicker({
    required String title,
    required List<AccountDef> accounts,
    required String selected,
    required ValueChanged<String> onPick,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                fontSize: 12, color: AppColors.textSecondary)),
        const SizedBox(height: 9),
        Wrap(
          spacing: 9,
          runSpacing: 9,
          children: accounts.map((a) {
            final sel = a.name == selected;
            return GestureDetector(
              onTap: () => onPick(a.name),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: sel
                      ? AppColors.primary.withOpacity(0.10)
                      : AppColors.fill,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(
                    color: sel ? AppColors.primary : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(a.icon,
                        size: 15,
                        color: sel
                            ? AppColors.primary
                            : AppColors.textSecondary),
                    const SizedBox(width: 6),
                    Text(
                      a.name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            sel ? FontWeight.w700 : FontWeight.w500,
                        color: sel
                            ? AppColors.primary
                            : AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(TransferRecord t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除转账'),
        content: Text(
            '确认删除这笔「${t.fromAccount} → ${t.toAccount}」'
            '${formatMoney(t.amount)} 的转账吗？删除后无法恢复。'),
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

    await BillDatabase.instance.deleteTransfer(t.id!);
    if (!mounted) return;
    showToast(context, '转账已删除');
    widget.onChanged?.call();
    _load();
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}'
      '-${d.day.toString().padLeft(2, '0')}';
}
