import 'package:flutter_test/flutter_test.dart';

import 'package:ledger_book/db.dart';
import 'package:ledger_book/models.dart';
import 'package:ledger_book/stats.dart';

void main() {
  group('BillRecord 日期编解码', () {
    test('dateToInt / intToDate 应可逆', () {
      final d = DateTime(2026, 9, 21);
      final v = BillRecord.dateToInt(d);
      expect(v, 20260921);
      final back = BillRecord.intToDate(v);
      expect(back.year, 2026);
      expect(back.month, 9);
      expect(back.day, 21);
    });

    test('个位数月日应正确补零', () {
      final v = BillRecord.dateToInt(DateTime(2026, 1, 5));
      expect(v, 20260105);
    });
  });

  group('BillRecord 金额方向', () {
    test('支出为负、收入为正', () {
      final e = BillRecord(
        type: BillType.expense,
        amount: 100,
        category: '餐饮',
        date: DateTime(2026, 9, 21),
        createdAt: DateTime(2026, 9, 21),
      );
      final i = BillRecord(
        type: BillType.income,
        amount: 100,
        category: '工资',
        date: DateTime(2026, 9, 21),
        createdAt: DateTime(2026, 9, 21),
      );
      expect(e.signedAmount, -100);
      expect(i.signedAmount, 100);
    });
  });

  group('StatsResult 聚合', () {
    List<BillRecord> build() => [
          BillRecord(
            type: BillType.expense,
            amount: 30,
            category: '餐饮',
            date: DateTime(2026, 9, 1),
            createdAt: DateTime(2026, 9, 1),
          ),
          BillRecord(
            type: BillType.expense,
            amount: 70,
            category: '餐饮',
            date: DateTime(2026, 9, 1),
            createdAt: DateTime(2026, 9, 1),
          ),
          BillRecord(
            type: BillType.expense,
            amount: 200,
            category: '购物',
            date: DateTime(2026, 9, 2),
            createdAt: DateTime(2026, 9, 2),
          ),
          BillRecord(
            type: BillType.income,
            amount: 1000,
            category: '工资',
            date: DateTime(2026, 9, 5),
            createdAt: DateTime(2026, 9, 5),
          ),
        ];

    test('合计与结余正确', () {
      final s = StatsResult(
        records: build(),
        from: DateTime(2026, 9, 1),
        to: DateTime(2026, 9, 30),
        rangeLabel: '2026年9月',
      );
      expect(s.totalExpense, 300);
      expect(s.totalIncome, 1000);
      expect(s.balance, 700);
      expect(s.recordCount, 4);
      expect(s.dayCount, 3);
      // 日均的分母是"有支出的天数"（2 天），不是"有记账的天数"（3 天）：
      // 那 1 天只有收入，把它算进分母会平白稀释日均支出。
      // 引入报销功能后这点更明显——报销到账那天只有收入，
      // 若计入分母，日均支出会被越报越低。
      expect(s.expenseDayCount, 2);
      expect(s.avgDailyExpense, 150);
    });

    test('分类聚合按金额降序', () {
      final s = StatsResult(
        records: build(),
        from: DateTime(2026, 9, 1),
        to: DateTime(2026, 9, 30),
        rangeLabel: '2026年9月',
      );
      final byCat = s.byCategory();
      expect(byCat.length, 2);
      expect(byCat.first.key, '购物'); // 200 > 100
      expect(byCat.first.total, 200);
      expect(byCat.last.total, 100);
    });

    test('按日聚合应按时间升序', () {
      final s = StatsResult(
        records: build(),
        from: DateTime(2026, 9, 1),
        to: DateTime(2026, 9, 30),
        rangeLabel: '2026年9月',
      );
      final byDay = s.byDay();
      expect(byDay.map((e) => e.key).toList(),
          ['20260901', '20260902', '20260905']);
    });

    test('最大单笔支出正确', () {
      final s = StatsResult(
        records: build(),
        from: DateTime(2026, 9, 1),
        to: DateTime(2026, 9, 30),
        rangeLabel: '2026年9月',
      );
      expect(s.maxExpense!.amount, 200);
      expect(s.maxExpense!.category, '购物');
    });

    test('空数据不应崩溃', () {
      final s = StatsResult(
        records: [],
        from: DateTime(2026, 9, 1),
        to: DateTime(2026, 9, 30),
        rangeLabel: '2026年9月',
      );
      expect(s.totalExpense, 0);
      expect(s.balance, 0);
      expect(s.avgDailyExpense, 0);
      expect(s.maxExpense, isNull);
      expect(s.byCategory(), isEmpty);
    });
  });

  group('金额格式化', () {
    test('千分位与两位小数', () {
      expect(formatMoney(1234.5), '¥1,234.50');
      expect(formatMoney(0), '¥0.00');
      expect(formatMoney(1234567.891), '¥1,234,567.89');
      expect(formatMoney(-500), '-¥500.00');
    });

    test('紧凑格式', () {
      expect(compactMoney(15000), '1.5万');
      expect(compactMoney(2000), '2.0k');
      expect(compactMoney(50), '50');
    });
  });

  group('分类定义', () {
    test('支出与收入分类不混淆', () {
      expect(categoriesOf(BillType.expense).first.name, '餐饮');
      expect(categoriesOf(BillType.income).first.name, '工资');
      expect(
        categoriesOf(BillType.expense).every((c) => c.type == BillType.expense),
        isTrue,
      );
      expect(
        categoriesOf(BillType.income).every((c) => c.type == BillType.income),
        isTrue,
      );
    });
  });

  group('账户定义', () {
    test('默认账户为现金，且内置账户非空', () {
      expect(kDefaultAccount, '现金');
      expect(kBuiltinAccounts, isNotEmpty);
      expect(kBuiltinAccounts.first.name, kDefaultAccount);
    });

    test('内置账户不应包含筛选哨兵值', () {
      // kAllAccounts 只是筛选用的保留值，不能作为真实账户名出现
      expect(kBuiltinAccounts.any((a) => a.name == kAllAccounts), isFalse);
    });

    test('账户名不应重复', () {
      final names = kBuiltinAccounts.map((a) => a.name).toList();
      expect(names.toSet().length, names.length);
    });

    test('iconForAccount 未命中时应回落到默认图标', () {
      expect(iconForAccount('这个账户不存在').codePoint,
          kFallbackAccountIcon.codePoint);
      expect(iconForAccount('微信').codePoint,
          kBuiltinAccounts.firstWhere((a) => a.name == '微信').icon.codePoint);
    });
  });

  group('BillRecord 账户字段', () {
    test('未指定账户时默认落到现金', () {
      final r = BillRecord(
        type: BillType.expense,
        amount: 10,
        category: '餐饮',
        date: DateTime(2026, 9, 21),
        createdAt: DateTime(2026, 9, 21),
      );
      expect(r.account, kDefaultAccount);
    });

    test('toMap / fromMap 应保留账户字段', () {
      final r = BillRecord(
        id: 7,
        type: BillType.expense,
        amount: 88.5,
        category: '购物',
        account: '招行储蓄卡',
        note: '日用品',
        date: DateTime(2026, 9, 21),
        createdAt: DateTime(2026, 9, 21, 10, 30),
      );
      final back = BillRecord.fromMap(r.toMap());
      expect(back.id, 7);
      expect(back.account, '招行储蓄卡');
      expect(back.amount, 88.5);
      expect(back.category, '购物');
      expect(back.note, '日用品');
      expect(back.date, DateTime(2026, 9, 21));
    });

    test('老数据缺少 account 列时应回落，不丢记录', () {
      // 模拟 v1 数据库升级前写入的行：没有 account 键
      final legacy = <String, Object?>{
        'id': 1,
        'type': BillType.expense.value,
        'amount': 25.0,
        'category': '餐饮',
        'note': '',
        'date': 20260921,
        'created_at': DateTime(2026, 9, 21).millisecondsSinceEpoch,
      };
      final r = BillRecord.fromMap(legacy);
      expect(r.account, kDefaultAccount);
      expect(r.amount, 25.0);
    });
  });

  group('账户维度聚合', () {
    List<BillRecord> mixed() => [
          BillRecord(
            type: BillType.expense,
            amount: 100,
            category: '餐饮',
            account: '微信',
            date: DateTime(2026, 9, 1),
            createdAt: DateTime(2026, 9, 1),
          ),
          BillRecord(
            type: BillType.expense,
            amount: 50,
            category: '交通',
            account: '支付宝',
            date: DateTime(2026, 9, 2),
            createdAt: DateTime(2026, 9, 2),
          ),
          BillRecord(
            type: BillType.income,
            amount: 800,
            category: '工资',
            account: '银行卡',
            date: DateTime(2026, 9, 5),
            createdAt: DateTime(2026, 9, 5),
          ),
        ];

    test('筛选某账户后合计只含该账户', () {
      final all = mixed();
      final wx = all.where((r) => r.account == '微信').toList();
      final s = StatsResult(
        records: wx,
        from: DateTime(2026, 9, 1),
        to: DateTime(2026, 9, 30),
        rangeLabel: '2026年9月',
      );
      expect(s.totalExpense, 100);
      expect(s.totalIncome, 0);
      expect(s.recordCount, 1);
    });

    test('AccountSummary.net 为收入减支出', () {
      const s = AccountSummary(account: '银行卡', expense: 200, income: 800);
      expect(s.net, 600);
      const neg = AccountSummary(account: '微信', expense: 300);
      expect(neg.net, -300);
      expect(neg.income, 0);
    });

    test('按账户分组后各账户金额互不串扰', () {
      final all = mixed();
      final byAccount = <String, double>{};
      for (final r in all) {
        if (r.type != BillType.expense) continue;
        byAccount[r.account] = (byAccount[r.account] ?? 0) + r.amount;
      }
      expect(byAccount['微信'], 100);
      expect(byAccount['支付宝'], 50);
      expect(byAccount.containsKey('银行卡'), isFalse);
    });
  });
}
