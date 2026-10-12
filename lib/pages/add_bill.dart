import 'package:flutter/material.dart';

import '../account_store.dart';
import '../db.dart';
import '../models.dart';
import '../stats.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// 记一笔 / 编辑账单页面
class AddBillPage extends StatefulWidget {
  /// 传入则为编辑模式
  final BillRecord? editing;

  /// 新记账时默认选中的日期
  final DateTime? initialDate;

  /// 新记账时默认选中的账户
  final String? initialAccount;

  const AddBillPage({
    super.key,
    this.editing,
    this.initialDate,
    this.initialAccount,
  });

  @override
  State<AddBillPage> createState() => _AddBillPageState();
}

class _AddBillPageState extends State<AddBillPage> {
  late BillType _type;
  late String _category;
  late String _account;
  late DateTime _date;
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _amountFocus = FocusNode();

  List<AccountDef> _accounts = [];

  /// 报销/分摊：关联到的多笔支出账单 id（有序，保持用户选择顺序）
  final List<int> _linkedBillIds = [];

  /// 关联支出的详情缓存，用于在卡片上展示；id -> 记录
  final Map<int, BillRecord> _linkedBills = {};

  bool get _isEditing => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    _type = e?.type ?? BillType.expense;
    _category = e?.category ?? categoriesOf(_type).first.name;
    _account = e?.account ?? widget.initialAccount ?? kDefaultAccount;
    _date = e?.date ?? widget.initialDate ?? DateTime.now();
    if (e != null && e.linkedBillIds.isNotEmpty) {
      _linkedBillIds.addAll(e.linkedBillIds);
    }
    if (e != null) {
      final a = e.amount;
      _amountCtrl.text =
          a == a.roundToDouble() ? a.toStringAsFixed(0) : a.toStringAsFixed(2);
      _noteCtrl.text = e.note;
    }
    _loadAccounts();
    _loadLinkedBills();
  }

  /// 编辑一条已关联的收入时，把被关联的支出取出来用于展示。
  /// 顺手剔除已被删除的关联，避免保存时把脏 id 写回库。
  Future<void> _loadLinkedBills() async {
    if (_linkedBillIds.isEmpty) return;
    final map = <int, BillRecord>{};
    for (final id in List<int>.from(_linkedBillIds)) {
      try {
        final r = await BillDatabase.instance.findById(id);
        if (r != null && r.type == BillType.expense) map[id] = r;
      } catch (_) {
        // 关联的账单可能已被删除，静默降级为"未关联"
      }
    }
    if (!mounted) return;
    setState(() {
      _linkedBills
        ..clear()
        ..addAll(map);
      _linkedBillIds
        ..clear()
        ..addAll(map.keys);
    });
  }

  Future<void> _loadAccounts() async {
    final list = await AccountStore.instance.load();
    if (!mounted) return;
    setState(() {
      _accounts = list;
      if (list.isNotEmpty && !list.any((a) => a.name == _account)) {
        _account = list.first.name;
      }
    });
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  void _switchType(BillType t) {
    if (_type == t) return;
    setState(() {
      _type = t;
      final list = categoriesOf(t);
      if (!list.any((c) => c.name == _category)) {
        _category = list.first.name;
      }
      // 支出不存在"报销关联"的概念，切过去时顺手清掉，
      // 免得用户切回收入时看到一个莫名其妙还留着的关联
      if (t == BillType.expense) {
        _linkedBillIds.clear();
        _linkedBills.clear();
      }
    });
  }

  /// 已选关联支出的合计金额
  double get _linkedTotal =>
      _linkedBills.values.fold<double>(0, (a, b) => a + b.amount);

  /// 当前输入的报销金额
  double? get _enteredAmount => double.tryParse(_amountCtrl.text.trim());

  /// 报销金额 − 关联支出合计。>0 表示超额，超出部分将按净收入记账
  double get _surplus {
    final a = _enteredAmount;
    if (a == null || _linkedBills.isEmpty) return 0;
    return a - _linkedTotal;
  }

  /// 弹出支出账单多选选择器
  Future<void> _pickLinkedBills() async {
    final picked = await showModalBottomSheet<List<BillRecord>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => _LinkBillSheet(
        selectedIds: _linkedBillIds.toSet(),
        editingIncomeId: widget.editing?.id,
        accounts: _accounts,
      ),
    );
    if (picked == null) return;

    setState(() {
      _linkedBills.clear();
      for (final b in picked) {
        if (b.id != null) _linkedBills[b.id!] = b;
      }
      _linkedBillIds
        ..clear()
        ..addAll(_linkedBills.keys);
    });
  }

  Future<void> _save() async {
    final raw = _amountCtrl.text.trim();
    final amount = double.tryParse(raw);

    if (amount == null || amount <= 0) {
      showToast(context, '请输入有效金额');
      return;
    }
    if (amount > 99999999) {
      showToast(context, '金额过大，请检查输入');
      return;
    }

    // 报销金额**允许**大于关联支出的合计：超出部分会计为净收入
    // （钱确实多收了，不该拦）。这里只校验关联的账单还在不在，
    // 避免把已删除账单的 id 写回库，留下永远配不上对的脏关联。
    if (_type == BillType.income && _linkedBillIds.isNotEmpty) {
      for (final id in _linkedBillIds) {
        final exists = _linkedBills.containsKey(id) ||
            await BillDatabase.instance.findById(id) != null;
        if (!exists) {
          if (!mounted) return;
          showToast(context, '关联的账单已不存在，请重新选择');
          _linkedBillIds.remove(id);
          _linkedBills.remove(id);
          return;
        }
      }
    }

    final record = BillRecord(
      id: widget.editing?.id,
      type: _type,
      amount: amount,
      category: _category,
      account: _account,
      note: _noteCtrl.text.trim(),
      date: _date,
      createdAt: widget.editing?.createdAt ?? DateTime.now(),
      linkedBillIds:
          _type == BillType.income ? List<int>.from(_linkedBillIds) : const [],
    );

    if (_isEditing) {
      await BillDatabase.instance.update(record);
    } else {
      await BillDatabase.instance.insert(record);
    }

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isExpense = _type == BillType.expense;
    final accent = isExpense ? AppColors.expense : AppColors.income;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        // 与全局主题保持一致：不透明背景，避免透明 AppBar 触发的深色回退绘制
        backgroundColor: AppColors.background,
        surfaceTintColor: AppColors.background,
        title: Text(_isEditing ? '编辑账单' : '记一笔'),
        titleTextStyle: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w700,
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (_isEditing)
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline),
              onPressed: _confirmDelete,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 110),
        children: [
          // -------- 收支类型 --------
          SegmentTabs<BillType>(
            values: const [BillType.expense, BillType.income],
            selected: _type,
            labelOf: (t) => t.label,
            colorOf: (t) =>
                t == BillType.expense ? AppColors.expense : AppColors.income,
            onChanged: _switchType,
          ),
          const SizedBox(height: 16),

          // -------- 金额 --------
          _buildAmountCard(accent),
          const SizedBox(height: 16),

          // -------- 报销 / 分摊关联（仅收入类型）--------
          if (!isExpense) ...[
            _buildLinkCard(),
            const SizedBox(height: 16),
          ],

          // -------- 分类 --------
          SectionCard(
            title: '分类',
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Wrap(
              spacing: 12,
              runSpacing: 14,
              children: categoriesOf(_type).map((c) {
                final selected = c.name == _category;
                return GestureDetector(
                  onTap: () => setState(() => _category = c.name),
                  child: SizedBox(
                    width: 60,
                    child: Column(
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: selected
                                ? accent.withOpacity(0.12)
                                : AppColors.fill,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color:
                                  selected ? accent : Colors.transparent,
                              width: 1.6,
                            ),
                          ),
                          child: Icon(
                            c.icon,
                            size: 21,
                            color: selected ? accent : AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          c.name,
                          style: TextStyle(
                            fontSize: 11,
                            color: selected
                                ? AppColors.textPrimary
                                : AppColors.textSecondary,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),

          // -------- 账户 --------
          SectionCard(
            title: '账户',
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: _accounts.isEmpty
                ? const Text(
                    '暂无可选账户，请到「账户」页新建',
                    style: TextStyle(
                        fontSize: 13, color: AppColors.textSecondary),
                  )
                : Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: _accounts.map((a) {
                      final selected = a.name == _account;
                      return GestureDetector(
                        onTap: () => setState(() => _account = a.name),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 13, vertical: 10),
                          decoration: BoxDecoration(
                            color: selected
                                ? AppColors.primary.withOpacity(0.10)
                                : AppColors.fill,
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                              color: selected
                                  ? AppColors.primary
                                  : Colors.transparent,
                              width: 1.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                a.icon,
                                size: 16,
                                color: selected
                                    ? AppColors.primary
                                    : AppColors.textSecondary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                a.name,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: selected
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
          ),
          const SizedBox(height: 16),

          // -------- 日期与备注 --------
          Container(
            decoration: BoxDecoration(
              color: AppColors.cardBg,
              borderRadius: AppShape.card,
              boxShadow: AppShape.softShadow,
            ),
            child: Column(
              children: [
                ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16),
                  leading: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: const Icon(Icons.event,
                        size: 18, color: AppColors.primary),
                  ),
                  title: const Text('日期',
                      style: TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${_date.year}-${_date.month.toString().padLeft(2, '0')}'
                        '-${_date.day.toString().padLeft(2, '0')}',
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const Icon(Icons.chevron_right,
                          size: 20, color: AppColors.textTertiary),
                    ],
                  ),
                  onTap: _pickDate,
                ),
                const Divider(height: 1, indent: 68),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: TextField(
                    controller: _noteCtrl,
                    maxLength: 50,
                    decoration: const InputDecoration(
                      icon: Icon(Icons.edit_note,
                          size: 20, color: AppColors.textTertiary),
                      hintText: '备注（选填），如"和同事午餐"',
                      hintStyle: TextStyle(
                          fontSize: 13, color: AppColors.textTertiary),
                      border: InputBorder.none,
                      counterText: '',
                    ),
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ],
            ),
          ),

          if (!_isEditing) ...[
            const SizedBox(height: 12),
            Row(
              children: const [
                Icon(Icons.lightbulb_outline,
                    size: 14, color: AppColors.textTertiary),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '选择历史日期可以补记之前的账单',
                    style: TextStyle(
                        fontSize: 11.5, color: AppColors.textTertiary),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      bottomNavigationBar: Container(
        padding: EdgeInsets.fromLTRB(
          16,
          12,
          16,
          12 + MediaQuery.of(context).padding.bottom,
        ),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        child: SizedBox(
          height: 50,
          child: ElevatedButton(
            onPressed: _save,
            style: ElevatedButton.styleFrom(
              primary: accent,
              onPrimary: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(
              _isEditing ? '保存修改' : '保存',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
    );
  }

  /// 报销 / 分摊关联卡：把这笔收入挂到一笔或多笔支出上
  ///
  /// 关联后统计会按净额合并（详见 StatsResult 的注释），
  /// 所以这里必须把「消费 − 报销」这个结果讲清楚，
  /// 否则用户不知道关联与不关联在账面上有什么区别。
  /// 报销大于消费合计时，还要点明超出部分按净收入记账。
  Widget _buildLinkCard() {
    final has = _linkedBills.isNotEmpty;
    final surplus = _surplus;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: AppShape.card,
        boxShadow: AppShape.softShadow,
      ),
      child: InkWell(
        borderRadius: AppShape.card,
        onTap: _pickLinkedBills,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: (has ? AppColors.income : AppColors.textTertiary)
                          .withOpacity(0.10),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(
                      has ? Icons.link : Icons.link_off,
                      size: 18,
                      color: has ? AppColors.income : AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: const [
                            Text(
                              '关联消费账单',
                              style: TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary),
                            ),
                            SizedBox(width: 6),
                            _ReimburseBadge(),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          has
                              ? '已选 ${_linkedBills.length} 笔，合计 '
                                  '${formatMoney(_linkedTotal)}'
                              : '选填。可关联多笔，统计按「消费 − 报销」的净额计算',
                          style: TextStyle(
                            fontSize: has ? 12.5 : 11.5,
                            fontWeight: has ? FontWeight.w600 : FontWeight.w400,
                            color: has
                                ? AppColors.textPrimary
                                : AppColors.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (has)
                    GestureDetector(
                      onTap: () => setState(() {
                        _linkedBillIds.clear();
                        _linkedBills.clear();
                      }),
                      behavior: HitTestBehavior.opaque,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Text(
                          '清除',
                          style: TextStyle(
                              fontSize: 12.5, color: AppColors.textTertiary),
                        ),
                      ),
                    )
                  else
                    const Icon(Icons.chevron_right,
                        size: 20, color: AppColors.textTertiary),
                ],
              ),
              if (has) ...[
                const SizedBox(height: 8),
                // 已选支出逐行列示，每行可单独移除
                ..._linkedBills.values.map((b) => _linkedBillRow(b)),
              ],
              if (has && surplus > 0.005) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline,
                        size: 13, color: AppColors.accent),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        '报销超出消费合计 ${formatMoney(surplus)}，'
                        '超出部分将按净收入记账',
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.accent),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 已选关联支出的单行：分类 · 金额 · 日期 + 移除按钮
  Widget _linkedBillRow(BillRecord b) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: AppColors.expense.withOpacity(0.10),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(iconForCategory(b.category, BillType.expense),
                size: 15, color: AppColors.expense),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '${b.category} ${formatMoney(b.amount)} · ${_fmtDate(b.date)}',
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            onTap: () => setState(() {
              final id = b.id;
              if (id == null) return;
              _linkedBillIds.remove(id);
              _linkedBills.remove(id);
            }),
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close,
                  size: 16, color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  /// 金额输入卡：数字为绝对视觉重心
  Widget _buildAmountCard(Color accent) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppShape.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _type == BillType.expense ? '支出金额' : '收入金额',
                style: const TextStyle(
                    fontSize: 12.5, color: AppColors.textSecondary),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _category,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: accent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('¥',
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: accent)),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _amountCtrl,
                  focusNode: _amountFocus,
                  autofocus: !_isEditing,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    color: accent,
                    letterSpacing: -0.5,
                  ),
                  decoration: InputDecoration(
                    hintText: '0.00',
                    hintStyle: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w800,
                      color: accent.withOpacity(0.22),
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
          const SizedBox(height: 06),
          const Divider(height: 1),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await pickDate(
      context,
      initial: _date,
      first: DateTime(2000, 1, 1),
      last: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() => _date = StatsRange.dayStart(picked));
    }
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}'
      '-${d.day.toString().padLeft(2, '0')}';

  Future<void> _confirmDelete() async {
    final id = widget.editing!.id!;
    // 若这笔支出被报销过，删除会让那些收入失去依附对象。
    // 这里如实告知，而不是悄悄把收入也删掉——钱确实到账了。
    final linked = await BillDatabase.instance.queryIncomesLinkedTo(id);
    final linkedTotal = linked.fold<double>(0, (a, r) => a + r.amount);
    if (!mounted) return;

    final msg = linked.isEmpty
        ? '删除后无法恢复，确认删除这条记录吗？'
        : '这笔消费已被 ${linked.length} 笔报销关联'
            '（合计 ${formatMoney(linkedTotal)}）。\n'
            '删除后会从这些报销的关联列表里移除，不会被一并删除。';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账单'),
        content: Text(msg),
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

    // delete 内部会自动解除关联收入的链接
    await BillDatabase.instance.delete(id);
    if (!mounted) return;
    Navigator.of(context).pop('deleted');
  }
}

/// 「报销 / 分摊」小徽标，多处复用
class _ReimburseBadge extends StatelessWidget {
  const _ReimburseBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accent.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        '报销 / 分摊',
        style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            color: AppColors.accent),
      ),
    );
  }
}

/// 支出账单多选选择器：为一笔报销挑出它要冲减的多笔消费
class _LinkBillSheet extends StatefulWidget {
  /// 进入时已选中的支出 id
  final Set<int> selectedIds;

  /// 正在编辑的收入 id（若有），查"已被报销"时要把自己排除掉
  final int? editingIncomeId;

  final List<AccountDef> accounts;

  const _LinkBillSheet({
    required this.selectedIds,
    this.editingIncomeId,
    required this.accounts,
  });

  @override
  State<_LinkBillSheet> createState() => _LinkBillSheetState();
}

class _LinkBillSheetState extends State<_LinkBillSheet> {
  List<BillRecord> _all = [];
  bool _loading = true;
  String _keyword = '';
  final _searchCtrl = TextEditingController();

  /// 日期筛选项：all / today / yesterday / last7 / month / custom
  ///
  /// 报销经常是事后补的：出差回来才拿到发票，要冲减前几天的消费。
  // 没有日期筛选时，几百笔历史消费里翻一笔能翻到怀疑人生。
  String _dateFilter = 'all';

  /// 自定义日期范围的起止（含）；没选过为 null
  DateTime? _customFrom;
  DateTime? _customTo;

  /// 日期筛选对应的 yyyyMMdd 起止（含）；null 表示不限制
  int? _dateLo;
  int? _dateHi;

  /// 当前勾选的支出 id
  late final Set<int> _selected = Set<int>.from(widget.selectedIds);

  /// 每笔支出已被其他报销关联的金额合计（原始金额，仅供参考）
  Map<int, double> _linkedTotals = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await BillDatabase.instance.queryExpenseCandidates();
      final totals = await BillDatabase.instance.linkedIncomeTotals(
        list.where((r) => r.id != null).map((r) => r.id!).toSet(),
        exceptIncomeId: widget.editingIncomeId,
      );
      if (!mounted) return;
      setState(() {
        _all = list;
        _linkedTotals = totals;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _all = [];
        _loading = false;
      });
    }
  }

  /// 按关键词 + 日期筛选过滤：命中分类或备注，且日期落在筛选范围内
  List<BillRecord> get _filtered {
    final k = _keyword.trim().toLowerCase();
    return _all.where((r) {
      if (k.isNotEmpty &&
          !(r.category.toLowerCase().contains(k) ||
              r.note.toLowerCase().contains(k))) {
        return false;
      }
      // r.date 是 DateTime，统一换成 yyyyMMdd 整数再与筛选边界比
      final di = BillRecord.dateToInt(r.date);
      if (_dateLo != null && di < _dateLo!) return false;
      if (_dateHi != null && di > _dateHi!) return false;
      return true;
    }).toList();
  }

  /// 切换日期筛选，并把选项换算成 yyyyMMdd 起止供 _filtered 用。
  /// 换算一次存起来，避免每次过滤都重算 switch。
  void _applyDateFilter(String v) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    int d(DateTime x) => BillRecord.dateToInt(x);

    int? lo;
    int? hi;
    switch (v) {
      case 'today':
        lo = hi = d(today);
        break;
      case 'yesterday':
        final y = today.subtract(const Duration(days: 1));
        lo = hi = d(y);
        break;
      case 'last7':
        // 近 7 天含今天，往前推 6 天
        lo = d(today.subtract(const Duration(days: 6)));
        hi = d(today);
        break;
      case 'month':
        lo = d(DateTime(now.year, now.month, 1));
        hi = d(today);
        break;
      case 'custom':
        if (_customFrom == null || _customTo == null) return;
        lo = d(_customFrom!);
        hi = d(_customTo!);
        break;
      default:
        break;
    }
    setState(() {
      _dateFilter = v;
      _dateLo = lo;
      _dateHi = hi;
    });
  }

  /// 自定义范围：先选起始日，再选结束日（不早于起始日）。
  /// 两步都完成才真正切到 custom，中途返回保持原筛选不变。
  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final from =
        await pickDate(context, initial: _customFrom ?? now);
    if (from == null || !mounted) return;
    final to = await pickDate(
      context,
      initial: _customTo ?? from,
      first: from,
    );
    if (to == null || !mounted) return;
    setState(() {
      _customFrom = from;
      _customTo = to;
    });
    _applyDateFilter('custom');
  }

  String get _customLabel {
    if (_customFrom == null || _customTo == null) return '自定义';
    String f(DateTime d) => '${d.month}/${d.day}';
    return '${f(_customFrom!)}~${f(_customTo!)}';
  }

  double get _selectedTotal => _all
      .where((r) => r.id != null && _selected.contains(r.id))
      .fold<double>(0, (a, r) => a + r.amount);

  void _toggle(BillRecord r) {
    final id = r.id;
    if (id == null) return;
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollCtrl) => Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.fillStrong,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: const [
                Icon(Icons.receipt_long,
                    size: 19, color: AppColors.primary),
                SizedBox(width: 8),
                Text(
                  '选择要报销的消费',
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
                '只能关联支出账单；可多选，报销金额允许大于消费合计',
                style: TextStyle(
                    fontSize: 11.5, color: AppColors.textTertiary),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _keyword = v),
              decoration: InputDecoration(
                hintText: '搜索分类或备注',
                hintStyle: const TextStyle(
                    fontSize: 13, color: AppColors.textTertiary),
                prefixIcon: const Icon(Icons.search,
                    size: 19, color: AppColors.textTertiary),
                filled: true,
                fillColor: AppColors.fill,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              style: const TextStyle(fontSize: 14),
            ),
          ),
          const SizedBox(height: 10),
          // 日期筛选：报销多是事后补的，前几天的消费不好翻
          FilterChipBar(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            selected: _dateFilter,
            onChanged: (v) {
              if (v == 'custom') {
                _pickCustomRange();
                return;
              }
              _applyDateFilter(v);
            },
            items: [
              const FilterChipItem(
                  value: 'all', label: '全部', icon: Icons.all_inclusive),
              const FilterChipItem(
                  value: 'today', label: '今天', icon: Icons.today_outlined),
              const FilterChipItem(
                  value: 'yesterday', label: '昨天', icon: Icons.history),
              const FilterChipItem(
                  value: 'last7', label: '近7天', icon: Icons.date_range),
              const FilterChipItem(
                  value: 'month',
                  label: '本月',
                  icon: Icons.calendar_month_outlined),
              FilterChipItem(
                  value: 'custom',
                  label: _customLabel,
                  icon: Icons.edit_calendar_outlined),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(strokeWidth: 2))
                : list.isEmpty
                    ? Center(
                        child: Text(
                          _all.isEmpty
                              ? '还没有任何支出账单\n先去记一笔消费吧'
                              : '没有匹配的支出账单\n换个关键词或日期范围试试'
                                  '${_selected.isNotEmpty ? '\n已选中的 ${_selected.length} 笔不受筛选影响' : ''}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textTertiary),
                        ),
                      )
                    : ListView.separated(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                        itemCount: list.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, indent: 52),
                        itemBuilder: (_, i) => _tile(list[i]),
                      ),
          ),
          // 底部合计栏：多选场景下必须让用户随时看到"选了几笔、一共多少钱"
          Container(
            padding: EdgeInsets.fromLTRB(
                20, 10, 20, 10 + MediaQuery.of(context).padding.bottom),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: AppColors.divider)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '已选 ${_selected.length} 笔',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        formatMoney(_selectedTotal),
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: AppColors.income,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 44,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(
                      context,
                      _all
                          .where((r) =>
                              r.id != null && _selected.contains(r.id))
                          .toList(),
                    ),
                    style: ElevatedButton.styleFrom(
                      primary: AppColors.primary,
                      onPrimary: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text(
                      '完成',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(BillRecord r) {
    final id = r.id;
    final checked = id != null && _selected.contains(id);
    final linked = _linkedTotals[id] ?? 0;

    return InkWell(
      onTap: () => _toggle(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppColors.expense.withOpacity(0.10),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(iconForCategory(r.category, BillType.expense),
                  size: 18, color: AppColors.expense),
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
                  const SizedBox(height: 3),
                  Text(
                    '${_fmt(r.date)} · ${r.account}'
                    '${r.note.isNotEmpty ? ' · ${r.note}' : ''}',
                    style: const TextStyle(
                        fontSize: 11.5, color: AppColors.textTertiary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (linked > 0.005) ...[
                    const SizedBox(height: 3),
                    Text(
                      linked >= r.amount - 0.005
                          ? '已被其他报销报满'
                          : '已被其他报销关联 ${formatMoney(linked)}',
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: AppColors.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              formatMoney(r.amount),
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w800,
                color: AppColors.expense,
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              checked
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              size: 20,
              color: checked ? AppColors.primary : AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}'
      '-${d.day.toString().padLeft(2, '0')}';
}
