import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'account_store.dart';
import 'db.dart';
import 'pages/accounts.dart';
import 'pages/add_bill.dart';
import 'pages/bill_list.dart';
import 'pages/calendar.dart';
import 'pages/stats.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 不预置任何示例数据：首次启动即为空库，由用户从零开始记账。
  // 这里只做一次数据库预热，让内置账户表在首次进入页面时已就绪。
  await BillDatabase.instance.database;
  runApp(const LedgerApp());
}

class LedgerApp extends StatelessWidget {
  const LedgerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI记账',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      // 全部界面文案均为中文，日期选择器/长按菜单等系统组件也需要中文文案。
      // 这里显式声明支持的语言与本地化代理，避免 showDatePicker 找不到
      // MaterialLocalizations 而构建失败（表现为弹层遮罩残留、页面卡死）。
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const RootShell(),
    );
  }
}

/// 底部导航骨架，持有各页面 State 引用以便跨 Tab 刷新
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  final _listKey = GlobalKey<BillListPageState>();
  final _statsKey = GlobalKey<StatsPageState>();
  final _calendarKey = GlobalKey<CalendarPageState>();

  late final List<Widget> _pages = [
    BillListPage(key: _listKey),
    StatsPage(key: _statsKey),
    CalendarPage(key: _calendarKey),
    AccountsPage(embedded: true, onChanged: _onAccountsChanged),
  ];

  /// 记一笔后，其它页面需要感知数据变化才能显示最新结果
  Future<void> _quickAdd() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const AddBillPage()),
    );
    if (ok == true) _refreshAll();
  }

  /// 账户页作为 Tab 存在，增删改名后需要让明细/分析/日历重新拉取筛选项
  Future<void> _onAccountsChanged() async {
    await AccountStore.instance.load(force: true);
    if (!mounted) return;
    setState(() {});
    _refreshAll();
  }

  void _refreshAll() {
    _listKey.currentState?.reload();
    _statsKey.currentState?.reload();
    _calendarKey.currentState?.reload();
  }

  void _onTabTap(int i) {
    setState(() => _index = i);
    // 切换 Tab 时刷新，避免看到过期数据；账户页自行管理数据加载
    if (i < 3) _refreshAll();
  }

  static const _tabs = [
    _TabDef(Icons.receipt_long_outlined, Icons.receipt_long, '明细'),
    _TabDef(Icons.pie_chart_outline, Icons.pie_chart, '分析'),
    _TabDef(Icons.calendar_today_outlined, Icons.calendar_today, '日历'),
    _TabDef(Icons.account_balance_wallet_outlined,
        Icons.account_balance_wallet, '账户'),
  ];

  @override
  Widget build(BuildContext context) {
    // 明细页自带 FAB，这里只为"分析/日历"两个 Tab 提供快速记账入口
    final showFab = _index == 1 || _index == 2;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: IndexedStack(index: _index, children: _pages),
      floatingActionButton: showFab
          ? FloatingActionButton(
              onPressed: _quickAdd,
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              elevation: 4,
              tooltip: '记一笔',
              child: const Icon(Icons.add, size: 26),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      bottomNavigationBar: Container(
        padding: EdgeInsets.fromLTRB(
            16, 8, 16, 8 + MediaQuery.of(context).padding.bottom),
        color: Colors.white,
        child: Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: AppColors.fill,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              for (int i = 0; i < _tabs.length; i++)
                Expanded(child: _buildTab(i)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTab(int i) {
    final t = _tabs[i];
    final selected = _index == i;
    return GestureDetector(
      onTap: () => _onTabTap(i),
      behavior: HitTestBehavior.opaque,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(
              horizontal: selected ? 14 : 10, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(13),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: const Color(0xFF1F2233).withOpacity(0.08),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    )
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                selected ? t.activeIcon : t.icon,
                size: 20,
                color:
                    selected ? AppColors.primary : AppColors.textTertiary,
              ),
              if (selected) ...[
                const SizedBox(width: 6),
                Text(
                  t.label,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TabDef {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _TabDef(this.icon, this.activeIcon, this.label);
}
