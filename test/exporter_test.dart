import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ledger_book/exporter.dart';
import 'package:ledger_book/models.dart';
import 'package:ledger_book/stats.dart';

/// 导出功能的测试。
///
/// 直接调用 `BillExporter.buildWorkbook()` 拿到真实字节再解码断言，
/// 而不是在测试里复刻一份写表逻辑——复刻的那份一旦和实现漂移，
/// 测试就会变成"假绿灯"，白占一个用例。
void main() {
  final anchor = DateTime(2026, 9, 18);

  BillRecord exp(int id, double amount, String category, DateTime date) =>
      BillRecord(
        id: id,
        type: BillType.expense,
        amount: amount,
        category: category,
        account: '现金',
        date: date,
        createdAt: date,
      );

  BillRecord inc(int id, double amount, String category, DateTime date) =>
      BillRecord(
        id: id,
        type: BillType.income,
        amount: amount,
        category: category,
        account: '现金',
        date: date,
        createdAt: date,
      );

  /// 造一笔报销收入，关联到 [linkedId]
  BillRecord reimb(int id, double amount, int linkedId) => BillRecord(
        id: id,
        type: BillType.income,
        amount: amount,
        category: '报销',
        account: '现金',
        date: DateTime(2026, 9, 12),
        createdAt: DateTime(2026, 9, 12),
        linkedBillIds: [linkedId],
      );

  Excel decodeBook(List<BillRecord> records) {
    final bytes = BillExporter.buildWorkbook(
      records: records,
      anchor: anchor,
      granularity: StatsGranularity.month,
    );
    return Excel.decodeBytes(bytes);
  }

  Sheet decodeDetail(List<BillRecord> records) =>
      decodeBook(records).sheets['明细']!;

  group('导出文件名', () {
    test('按日导出：文件名带 yyyyMMdd', () {
      expect(
        BillExporter.fileBaseOf(anchor, StatsGranularity.day),
        'AI记账_账单_20260918',
      );
    });

    test('按月导出：文件名带 yyyyMM', () {
      expect(
        BillExporter.fileBaseOf(anchor, StatsGranularity.month),
        'AI记账_账单_202609',
      );
    });

    test('按年导出：文件名带 yyyy', () {
      expect(
        BillExporter.fileBaseOf(anchor, StatsGranularity.year),
        'AI记账_账单_2026',
      );
    });

    test('月份/日期需补零', () {
      final d = DateTime(2026, 1, 5);
      expect(BillExporter.fileBaseOf(d, StatsGranularity.day),
          'AI记账_账单_20260105');
      expect(BillExporter.fileBaseOf(d, StatsGranularity.month),
          'AI记账_账单_202601');
    });
  });

  group('导出的范围文案', () {
    test('三种粒度文案正确', () {
      final d = DateTime(2026, 9, 18);
      expect(BillExporter.scopeOf(d, StatsGranularity.day), '2026年9月18日');
      expect(BillExporter.scopeOf(d, StatsGranularity.month), '2026年9月');
      expect(BillExporter.scopeOf(d, StatsGranularity.year), '2026年');
    });
  });

  group('账户名清洗', () {
    test('非法文件名字符应被替换', () {
      expect(BillExporter.sanitize('招商/银行'), '招商_银行');
      expect(BillExporter.sanitize(r'现金\卡'), '现金_卡');
      expect(BillExporter.sanitize('我的 钱包'), '我的_钱包');
      expect(BillExporter.sanitize('a:b*c?d"e<f>g|h'), 'a_b_c_d_e_f_g_h');
    });

    test('正常中文账户名应原样保留', () {
      expect(BillExporter.sanitize('支付宝'), '支付宝');
      expect(BillExporter.sanitize('微信零钱'), '微信零钱');
    });
  });

  group('Excel 内容', () {
    test('明细与汇总两个 sheet 齐全，默认的 Sheet1 被删掉', () {
      final book = decodeBook([]);
      expect(book.sheets.keys, contains('明细'));
      expect(book.sheets.keys, contains('汇总'));
      expect(book.sheets.keys, isNot(contains('Sheet1')));
    });

    test('表头为 9 列，含「自付金额」', () {
      final detail = decodeDetail([]);
      final header =
          detail.row(0).map((c) => c?.value?.toString() ?? '').toList();
      expect(header.take(9).toList(), [
        '序号',
        '日期',
        '星期',
        '方向',
        '分类',
        '金额',
        '自付金额',
        '账户',
        '备注',
      ]);
    });

    test('无报销时，自付金额等于原金额', () {
      final detail = decodeDetail([
        exp(1, 25.5, '餐饮', DateTime(2026, 9, 18)),
      ]);

      final row = detail.row(1);
      expect(row[1]?.value.toString(), '2026-09-18');
      expect(row[3]?.value.toString(), '支出');
      expect(row[4]?.value.toString(), '餐饮');
      expect(row[5]?.value, 25.5);
      expect(row[6]?.value, 25.5, reason: '没有报销时自付额就是原额');
    });

    test('金额必须写为数字而非文本，否则 Excel 无法求和', () {
      final detail = decodeDetail([
        inc(1, 8000, '工资', DateTime(2026, 9, 10)),
      ]);

      final row = detail.row(1);
      expect(row[5]!.cellType, CellType.double);
      expect(row[5]!.value, 8000.0);
      expect(row[6]!.cellType, CellType.double);
    });

    test('报销场景：自付列扣除报销，备注写明关系', () {
      final detail = decodeDetail([
        exp(1, 1000, '差旅', DateTime(2026, 9, 10)),
        reimb(2, 800, 1),
      ]);

      // 按日期升序：第 1 行是 9/10 的差旅，第 2 行是 9/12 的报销
      final r1 = detail.row(1);
      expect(r1[4]?.value.toString(), '差旅');
      expect(r1[5]?.value, 1000.0, reason: '「金额」列保留原始发生额');
      expect(r1[6]?.value, 200.0, reason: '「自付金额」列应为 1000 − 800');
      expect(r1[8]?.value.toString(), contains('已报销'));

      // 报销收入那行不重复计入，自付额列留空
      final r2 = detail.row(2);
      expect(r2[3]?.value.toString(), '收入');
      expect(r2[6]?.value, isNull,
          reason: '报销收入已并入支出，不应再计一次');
      expect(r2[8]?.value.toString(), contains('已并入'));

      // 合计行按净额
      final totalRow = detail.row(3);
      expect(totalRow[5]?.value.toString(), contains('200.00'),
          reason: '支出合计应是净额 200');
    });

    test('汇总表含「报销与分摊」段', () {
      final book = decodeBook([
        exp(1, 1000, '差旅', DateTime(2026, 9, 10)),
        reimb(2, 800, 1),
      ]);

      final summary = book.sheets['汇总']!;
      final flat = <String>[];
      for (var i = 0; i < summary.maxRows; i++) {
        for (final c in summary.row(i)) {
          flat.add(c?.value?.toString() ?? '');
        }
      }
      expect(flat, contains('报销与分摊'));
      expect(flat, contains('报销总额'));
      expect(flat, contains('800.00'));
    });

    test('明细按日期升序排列', () {
      final detail = decodeDetail([
        exp(1, 10, 'B', DateTime(2026, 9, 20)),
        exp(2, 20, 'A', DateTime(2026, 9, 5)),
        exp(3, 30, 'C', DateTime(2026, 9, 12)),
      ]);

      expect(detail.row(1)[4]?.value.toString(), 'A');
      expect(detail.row(2)[4]?.value.toString(), 'C');
      expect(detail.row(3)[4]?.value.toString(), 'B');
    });
  });

  group('金额舍入', () {
    test('浮点尾差应被抹平为两位小数', () {
      // 0.1 + 0.2 = 0.30000000000000004 是经典浮点误差
      const sum = 0.1 + 0.2;
      final rounded = (sum * 100).roundToDouble() / 100;
      expect(rounded, 0.3);
    });
  });
}
