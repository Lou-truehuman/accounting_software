import 'package:flutter/material.dart';

import 'db.dart';
import 'models.dart';

/// 账户列表缓存。
/// 各页面（记账、明细筛选、分析筛选、账户管理）共用同一份内存缓存，
/// 变更后调用 [load](force: true) 刷新。
class AccountStore {
  AccountStore._();
  static final AccountStore instance = AccountStore._();

  List<AccountDef> _cache = const [];
  bool _loaded = false;

  List<AccountDef> get cached => _cache;
  bool get loaded => _loaded;

  Future<List<AccountDef>> load({bool force = false}) async {
    if (_loaded && !force) return _cache;
    _cache = await BillDatabase.instance.loadAccounts();
    _loaded = true;
    return _cache;
  }

  /// 账户名 -> 图标（先在缓存里找，找不到再回落到内置图标表）
  IconData iconOf(String name) {
    for (final a in _cache) {
      if (a.name == name) return a.icon;
    }
    return iconForAccount(name);
  }

  /// 下拉筛选项：首项为"全部账户"，其余为具体账户
  List<String> filterOptions() => [kAllAccounts, ..._cache.map((e) => e.name)];
}
