import 'dart:io';

import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'models.dart';
import 'stats.dart';

/// 账单导出为 Excel（.xlsx）
///
/// 设计要点：
/// 1. **金额写为数字而非字符串**，这样用户在 Excel 里可以直接求和、排序、
///    做透视表；写成 "¥12.00" 会变成文本，Excel 无法参与计算。
/// 2. **同时产出「明细」与「汇总」两个 sheet**：明细供逐条核对，
///    汇总供快速看结构。
/// 3. **方向（支出/收入）单独一列**，金额统一存正数——国内用户看账单
///    习惯"支出"就是支出，用正负号容易误读。
/// 4. 依赖 `excel 2.0.4`（Flutter 3.0 / Dart 2.17 能用的最高版本），
///    其 API 与 3.x/4.x 差异较大：单元格用 `updateCell`，
///    色值传十六进制字符串，列宽用 `setColWidth`。
class BillExporter {
  BillExporter._();

  // 与 App 主题一致的配色，导出的表格也保持同一套视觉
  static const _hexBrand = 'FF5B5BD6';
  static const _hexWhite = 'FFFFFFFF';
  static const _hexRowAlt = 'FFF1F2F7';
  static const _hexText = 'FF191A23';

  /// xlsx 的 MIME 类型，分享时声明清楚，让接收方能正确识别文件
  static const _xlsxMime =
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

  /// 导出并调起系统分享面板
  ///
  /// [granularity] 决定导出范围与文件名后缀：
  /// - day   → AI记账_账单_20260918.xlsx
  /// - month → AI记账_账单_202609.xlsx
  /// - year  → AI记账_账单_2026.xlsx
  ///
  /// [accountFilter] 为 `kAllAccounts` 或 null 时导出全部账户。
  ///
  /// 返回导出的文件绝对路径；失败抛出异常由调用方处理。
  static Future<String> export({
    required List<BillRecord> records,
    required DateTime anchor,
    required StatsGranularity granularity,
    String? accountFilter,
  }) async {
    final scope = scopeOf(anchor, granularity);
    final fileBase = fileBaseOf(anchor, granularity);

    final bytes = buildWorkbook(
      records: records,
      anchor: anchor,
      granularity: granularity,
      accountFilter: accountFilter,
    );

    // 写到应用缓存目录再交给系统分享面板，
    // 用户可自行选择"保存到文件"或直接发给微信等。
    final dir = await getTemporaryDirectory();
    final exportDir = Directory('${dir.path}/exports');
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }

    final safeAccount = (accountFilter == null || accountFilter == kAllAccounts)
        ? ''
        : '_${sanitize(accountFilter)}';
    final file = File('${exportDir.path}/$fileBase$safeAccount.xlsx');
    await file.writeAsBytes(bytes, flush: true);

    await Share.shareXFiles(
      [XFile(file.path, mimeType: _xlsxMime)],
      text: 'AI记账 · $scope 账单明细',
      subject: 'AI记账账单导出',
    );

    return file.path;
  }

  /// 只生成 xlsx 字节，不碰文件系统、不调分享面板。
  ///
  /// 抽出来是为了让测试能验证**真实产物**：直接解码这些字节、
  /// 断言单元格内容，而不是在测试里复刻一份写表逻辑
  /// （复刻的那份一旦和实现漂移，测试就会变成"假绿灯"）。
  static List<int> buildWorkbook({
    required List<BillRecord> records,
    required DateTime anchor,
    required StatsGranularity granularity,
    String? accountFilter,
  }) {
    final scope = scopeOf(anchor, granularity);
    final excel = Excel.createExcel();

    _writeDetailSheet(excel, records, scope, accountFilter);
    _writeSummarySheet(excel, records, scope, accountFilter);

    // createSheet 会留一个默认的空 "Sheet1"，删掉它避免多余页签
    if (excel.sheets.containsKey('Sheet1')) {
      excel.delete('Sheet1');
    }
    // 打开文件时默认停在"明细"页
    excel.setDefaultSheet('明细');

    final bytes = excel.encode();
    if (bytes == null) {
      throw Exception('Excel 生成失败');
    }
    return bytes;
  }

  // ---------------- 明细表 ----------------

  static void _writeDetailSheet(
    Excel excel,
    List<BillRecord> records,
    String scope,
    String? accountFilter,
  ) {
    final sheet = excel['明细'];

    // 用与页面完全相同的口径识别报销配对，保证导出的数字
    // 与 App 里看到的一致
    final stats = StatsResult(
      records: records,
      from: DateTime.now(),
      to: DateTime.now(),
      rangeLabel: scope,
    );

    final headerStyle = CellStyle(
      bold: true,
      fontSize: 11,
      fontColorHex: _hexWhite,
      backgroundColorHex: _hexBrand,
      horizontalAlign: HorizontalAlign.Center,
      verticalAlign: VerticalAlign.Center,
    );

    final header = <String>[
      '序号',
      '日期',
      '星期',
      '方向',
      '分类',
      '金额',
      '自付金额',
      '账户',
      '备注',
    ];

    // 表头
    for (var i = 0; i < header.length; i++) {
      sheet.updateCell(
        CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0),
        header[i],
        cellStyle: headerStyle,
      );
    }

    // 明细按日期升序，方便与纸质账本对照
    final sorted = List<BillRecord>.from(records)
      ..sort((a, b) {
        final c = a.date.compareTo(b.date);
        if (c != 0) return c;
        return a.createdAt.compareTo(b.createdAt);
      });

    final bodyStyle = CellStyle(
      fontSize: 11,
      fontColorHex: _hexText,
      verticalAlign: VerticalAlign.Center,
    );
    final moneyStyle = CellStyle(
      fontSize: 11,
      fontColorHex: _hexText,
      horizontalAlign: HorizontalAlign.Right,
      verticalAlign: VerticalAlign.Center,
    );

    for (var i = 0; i < sorted.length; i++) {
      final r = sorted[i];
      final row = i + 1;
      final isExpense = r.type == BillType.expense;

      void put(int col, Object? value, {CellStyle? style}) {
        sheet.updateCell(
          CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row),
          value,
          cellStyle: style ?? bodyStyle,
        );
      }

      put(0, i + 1);
      put(1, fmtDate(r.date));
      put(2, weekdayOf(r.date));
      put(3, isExpense ? '支出' : '收入');
      put(4, r.category);
      // 金额写数字，支出同样写正数，方向由"方向"列表达
      put(5, _round2(r.amount), style: moneyStyle);
      // 自付金额：支出被报销后实际承担的部分。
      // 写数字而非文本，用户可以直接对这一列求和得到真实支出。
      if (isExpense) {
        put(6, _round2(stats.effectiveExpenseOf(r)), style: moneyStyle);
      } else {
        // 报销收入：未超支时已并入支出冲减、本身不计收入，故留空；
        // 超出消费合计的净额是实打实多收的钱，照常计入
        final counted = stats.countedIncomeOf(r);
        final hide = stats.isMergedIncome(r) && counted <= 0.005;
        put(6, hide ? null : _round2(counted), style: moneyStyle);
      }
      put(7, r.account);

      // 备注列里补一句报销关系，方便人工核对
      final note = StringBuffer(r.note);
      if (isExpense) {
        final re = stats.reimbursedOf(r);
        if (re > 0) {
          if (note.isNotEmpty) note.write('；');
          note.write('已报销 ${_r2(re)}');
        }
      } else if (stats.isMergedIncome(r)) {
        if (note.isNotEmpty) note.write('；');
        final counted = stats.countedIncomeOf(r);
        note.write(counted > 0.005
            ? '报销超出消费合计，净收入 ${_r2(counted)}'
            : '报销收入，已并入对应消费');
      }
      put(8, note.toString());
    }

    // 合计行
    final totalRow = sorted.length + 1;
    final expense = stats.totalExpense;
    final income = stats.totalIncome;

    final sumStyle = CellStyle(
      bold: true,
      fontSize: 11,
      fontColorHex: _hexText,
      backgroundColorHex: _hexRowAlt,
      verticalAlign: VerticalAlign.Center,
    );

    void putSum(int col, Object? value) {
      sheet.updateCell(
        CellIndex.indexByColumnRow(columnIndex: col, rowIndex: totalRow),
        value,
        cellStyle: sumStyle,
      );
    }

    putSum(0, '合计');
    putSum(4, '支出/收入/结余');
    putSum(5, '${_r2(expense)} / ${_r2(income)} / ${_r2(income - expense)}');
    putSum(8, '共 ${sorted.length} 笔'
        '${stats.totalReimbursed > 0 ? '，含报销 ${_r2(stats.totalReimbursed)}' : ''}');

    // 列宽（单位：字符）
    sheet.setColWidth(0, 6);
    sheet.setColWidth(1, 12);
    sheet.setColWidth(2, 7);
    sheet.setColWidth(3, 7);
    sheet.setColWidth(4, 13);
    sheet.setColWidth(5, 12);
    sheet.setColWidth(6, 12);
    sheet.setColWidth(7, 12);
    sheet.setColWidth(8, 28);
  }

  // ---------------- 汇总表 ----------------

  static void _writeSummarySheet(
    Excel excel,
    List<BillRecord> records,
    String scope,
    String? accountFilter,
  ) {
    final sheet = excel['汇总'];

    // StatsResult 只依赖 records 做聚合，from/to/rangeLabel 仅用于展示
    final stats = StatsResult(
      records: records,
      from: DateTime.now(),
      to: DateTime.now(),
      rangeLabel: scope,
    );

    var row = 0;

    final sectionStyle = CellStyle(
      bold: true,
      fontSize: 11,
      fontColorHex: _hexWhite,
      backgroundColorHex: _hexBrand,
      verticalAlign: VerticalAlign.Center,
    );
    final keyStyle = CellStyle(
      bold: true,
      fontSize: 11,
      fontColorHex: _hexText,
      verticalAlign: VerticalAlign.Center,
    );
    final valStyle = CellStyle(
      fontSize: 11,
      fontColorHex: _hexText,
      verticalAlign: VerticalAlign.Center,
    );

    void sectionTitle(String text) {
      sheet.updateCell(
        CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row),
        text,
        cellStyle: sectionStyle,
      );
      sheet.updateCell(
        CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row),
        '',
        cellStyle: sectionStyle,
      );
      row++;
    }

    void kv(String label, String value) {
      sheet.updateCell(
        CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row),
        label,
        cellStyle: keyStyle,
      );
      sheet.updateCell(
        CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row),
        value,
        cellStyle: valStyle,
      );
      row++;
    }

    // ---- 导出信息 ----
    sectionTitle('导出信息');
    kv('统计范围', scope);
    kv('账户筛选',
        (accountFilter == null || accountFilter == kAllAccounts)
            ? '全部账户'
            : accountFilter);
    kv('导出时间', fmtDateTime(DateTime.now()));
    kv('记录笔数', '${stats.recordCount}');
    row++;

    // ---- 总体收支 ----
    sectionTitle('总体收支');
    kv('支出合计（已扣报销）', _r2(stats.totalExpense));
    kv('收入合计', _r2(stats.totalIncome));
    kv('结余', _r2(stats.balance));
    kv('有记账的天数', '${stats.dayCount}');
    kv('日均支出', _r2(stats.avgDailyExpense));
    row++;

    // ---- 报销与分摊 ----
    if (stats.totalReimbursed > 0) {
      sectionTitle('报销与分摊');
      kv('报销总额', _r2(stats.totalReimbursed));
      kv('被报销的支出笔数', '${stats.reimbursedCount}');
      row++;
    }

    // ---- 支出分类构成 ----
    sectionTitle('支出分类构成');
    final expCat = stats.byCategory(type: BillType.expense);
    if (expCat.isEmpty) {
      kv('（本期无支出记录）', '');
    } else {
      for (final s in expCat) {
        final pct = stats.totalExpense == 0
            ? 0.0
            : s.total / stats.totalExpense * 100;
        kv(s.label,
            '${_r2(s.total)}  （${pct.toStringAsFixed(1)}%，${s.count}笔）');
      }
    }
    row++;

    // ---- 收入分类构成 ----
    final incCat = stats.byCategory(type: BillType.income);
    if (incCat.isNotEmpty) {
      sectionTitle('收入分类构成');
      for (final s in incCat) {
        final pct =
            stats.totalIncome == 0 ? 0.0 : s.total / stats.totalIncome * 100;
        kv(s.label,
            '${_r2(s.total)}  （${pct.toStringAsFixed(1)}%，${s.count}笔）');
      }
      row++;
    }

    // ---- 最大单笔支出 ----
    final maxR = stats.maxExpense;
    if (maxR != null) {
      sectionTitle('最大单笔支出');
      kv('金额', _r2(maxR.amount));
      kv('分类', maxR.category);
      kv('日期', fmtDate(maxR.date));
      if (maxR.note.isNotEmpty) kv('备注', maxR.note);
    }

    sheet.setColWidth(0, 22);
    sheet.setColWidth(1, 44);
  }

  // ---------------- 工具（对测试公开） ----------------

  /// 统计范围的中文描述，例如 "2026年9月18日"
  static String scopeOf(DateTime anchor, StatsGranularity g) {
    switch (g) {
      case StatsGranularity.day:
        return '${anchor.year}年${anchor.month}月${anchor.day}日';
      case StatsGranularity.month:
        return '${anchor.year}年${anchor.month}月';
      case StatsGranularity.year:
        return '${anchor.year}年';
      case StatsGranularity.custom:
        return '${anchor.year}年${anchor.month}月${anchor.day}日';
    }
  }

  /// 文件名前缀，例如 "AI记账_账单_202609"
  static String fileBaseOf(DateTime anchor, StatsGranularity g) {
    final y = anchor.year.toString().padLeft(4, '0');
    final m = anchor.month.toString().padLeft(2, '0');
    final d = anchor.day.toString().padLeft(2, '0');
    switch (g) {
      case StatsGranularity.day:
        return 'AI记账_账单_$y$m$d';
      case StatsGranularity.month:
        return 'AI记账_账单_$y$m';
      case StatsGranularity.year:
        return 'AI记账_账单_$y';
      case StatsGranularity.custom:
        return 'AI记账_账单_$y$m$d';
    }
  }

  static String fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String fmtDateTime(DateTime d) =>
      '${fmtDate(d)} ${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  static const _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  static String weekdayOf(DateTime d) => _weekdays[d.weekday - 1];

  /// 账户名可能含 `/` `\` 空格等字符，替换掉避免写文件名失败
  static String sanitize(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_');

  /// 金额保留两位小数，避免导出 12.100000000000001 这种浮点尾差
  static double _round2(double v) => (v * 100).roundToDouble() / 100;

  static String _r2(double v) => _round2(v).toStringAsFixed(2);
}
