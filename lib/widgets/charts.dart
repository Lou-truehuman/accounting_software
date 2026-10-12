import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../stats.dart';
import '../theme.dart';

/// 环形图（甜甜圈图）：展示分类占比
/// 用 CustomPainter 手绘，避免引入体积较大的图表依赖
class DonutChart extends StatelessWidget {
  final List<Slice> slices;
  final double size;
  final double strokeWidth;
  final String centerTitle;
  final String centerValue;

  const DonutChart({
    super.key,
    required this.slices,
    this.size = 180,
    this.strokeWidth = 26,
    this.centerTitle = '合计',
    this.centerValue = '',
  });

  @override
  Widget build(BuildContext context) {
    final total = slices.fold<double>(0.0, (s, e) => s + e.total);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: _DonutPainter(
              values: slices.map((e) => e.total).toList(),
              colors: List.generate(
                  slices.length, (i) => AppColors.paletteAt(i)),
              strokeWidth: strokeWidth,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                centerTitle,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                centerValue.isEmpty ? formatMoney(total) : centerValue,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<double> values;
  final List<Color> colors;
  final double strokeWidth;

  _DonutPainter({
    required this.values,
    required this.colors,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<double>(0.0, (a, b) => a + b);
    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );

    if (total <= 0) {
      final bg = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = const Color(0xFFEDEFF2);
      canvas.drawArc(rect, 0, math.pi * 2, false, bg);
      return;
    }

    // 从 12 点方向开始顺时针绘制
    double start = -math.pi / 2;
    const gap = 0.028; // 扇区间隙（弧度），让相邻颜色分界更清楚

    for (int i = 0; i < values.length; i++) {
      if (values[i] <= 0) continue;
      final sweep = (values[i] / total) * math.pi * 2;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt
        ..color = colors[i % colors.length];
      // 只有扇区足够大时才留缝，否则小扇区会被缝完全吃掉
      final appliedGap = (sweep > gap * 2.5 && values.length > 1) ? gap : 0.0;
      canvas.drawArc(rect, start + appliedGap / 2, sweep - appliedGap, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.values != values || old.strokeWidth != strokeWidth;
}

/// 横向条形图：分类排行
class BarRow extends StatelessWidget {
  final Slice slice;
  final double maxValue;
  final Color color;
  final VoidCallback? onTap;

  const BarRow({
    super.key,
    required this.slice,
    required this.maxValue,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = maxValue <= 0
        ? 0.0
        : (slice.total / maxValue).clamp(0.0, 1.0).toDouble();

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                      color: color, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    slice.label,
                    style: const TextStyle(
                        fontSize: 14, color: AppColors.textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  formatMoney(slice.total),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: LayoutBuilder(
                    builder: (ctx, c) => Stack(
                      children: [
                        Container(
                          height: 6,
                          decoration: BoxDecoration(
                            color: const Color(0xFFEDEFF2),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 420),
                          curve: Curves.easeOutCubic,
                          height: 6,
                          width: c.maxWidth * ratio,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 46,
                  child: Text(
                    '${(ratio * 100).toStringAsFixed(1)}%',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 折线/面积趋势图：展示按日或按月的消费走势
class TrendChart extends StatelessWidget {
  final List<Slice> slices;
  final double height;
  final bool showIncome;

  const TrendChart({
    super.key,
    required this.slices,
    this.height = 200,
    this.showIncome = false,
  });

  @override
  Widget build(BuildContext context) {
    if (slices.isEmpty) {
      return SizedBox(
        height: height,
        child: const Center(
          child: Text('暂无数据',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        ),
      );
    }
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size(double.infinity, height),
        painter: _TrendPainter(
          expense: slices.map((e) => e.expense).toList(),
          income: slices.map((e) => e.income).toList(),
          labels: slices.map((e) => e.label).toList(),
          showIncome: showIncome,
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  final List<double> expense;
  final List<double> income;
  final List<String> labels;
  final bool showIncome;

  _TrendPainter({
    required this.expense,
    required this.income,
    required this.labels,
    required this.showIncome,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 40.0;
    const bottomPad = 26.0;
    const topPad = 12.0;
    const rightPad = 8.0;

    final plotW = size.width - leftPad - rightPad;
    final plotH = size.height - topPad - bottomPad;
    if (plotW <= 0 || plotH <= 0) return;

    // Y 轴上限：取支出与（可选）收入的最大值，向上取整到"好看"的刻度
    double maxV = 0;
    for (final v in expense) {
      if (v > maxV) maxV = v;
    }
    if (showIncome) {
      for (final v in income) {
        if (v > maxV) maxV = v;
      }
    }
    if (maxV <= 0) maxV = 100;
    maxV = _niceCeil(maxV);

    final gridPaint = Paint()
      ..color = const Color(0xFFEDEFF2)
      ..strokeWidth = 1;

    // 水平网格线 + Y 轴刻度
    const gridCount = 4;
    for (int i = 0; i <= gridCount; i++) {
      final y = topPad + plotH - (plotH * i / gridCount);
      canvas.drawLine(Offset(leftPad, y), Offset(size.width - rightPad, y), gridPaint);
      final tp = TextPainter(
        text: TextSpan(
          text: compactMoney(maxV * i / gridCount),
          style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: leftPad - 6);
      tp.paint(canvas, Offset(leftPad - 6 - tp.width, y - tp.height / 2));
    }

    final n = expense.length;
    // 只有一个点时把它放中间，避免除零
    double xAt(int i) =>
        n == 1 ? leftPad + plotW / 2 : leftPad + plotW * i / (n - 1);
    double yAt(double v) => topPad + plotH - (v / maxV) * plotH;

    // ----- 支出面积 + 折线 -----
    _drawSeries(
      canvas: canvas,
      values: expense,
      color: AppColors.expense,
      xAt: xAt,
      yAt: yAt,
      plotH: plotH,
      topPad: topPad,
      fill: true,
    );

    // ----- 收入折线 -----
    if (showIncome) {
      _drawSeries(
        canvas: canvas,
        values: income,
        color: AppColors.income,
        xAt: xAt,
        yAt: yAt,
        plotH: plotH,
        topPad: topPad,
        fill: false,
      );
    }

    // ----- X 轴标签：数据点多时抽样，避免文字重叠 -----
    final step = n <= 7 ? 1 : (n / 6).ceil();
    for (int i = 0; i < n; i += step) {
      final tp = TextPainter(
        text: TextSpan(
          text: labels[i],
          style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final x = xAt(i) - tp.width / 2;
      tp.paint(
        canvas,
        Offset(x.clamp(0, size.width - tp.width), topPad + plotH + 8),
      );
    }
  }

  void _drawSeries({
    required Canvas canvas,
    required List<double> values,
    required Color color,
    required double Function(int) xAt,
    required double Function(double) yAt,
    required double plotH,
    required double topPad,
    required bool fill,
  }) {
    if (values.isEmpty) return;
    final n = values.length;

    final path = Path();
    for (int i = 0; i < n; i++) {
      final pt = Offset(xAt(i), yAt(values[i]));
      if (i == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }

    // 面积填充
    if (fill && n > 1) {
      final area = Path.from(path);
      area.lineTo(xAt(n - 1), topPad + plotH);
      area.lineTo(xAt(0), topPad + plotH);
      area.close();
      final shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withOpacity(0.26), color.withOpacity(0.02)],
      ).createShader(
          Rect.fromLTWH(xAt(0), topPad, xAt(n - 1) - xAt(0), plotH));
      canvas.drawPath(area, Paint()..shader = shader);
    }

    // 折线
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );

    // 数据点：点少时画出来，点多时省略以保持清爽
    if (n <= 31) {
      for (int i = 0; i < n; i++) {
        canvas.drawCircle(
            Offset(xAt(i), yAt(values[i])), 2.6, Paint()..color = Colors.white);
        canvas.drawCircle(
          Offset(xAt(i), yAt(values[i])),
          2.6,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.8
            ..color = color,
        );
      }
    }
  }

  /// 把最大值向上取整到 1/2/5 × 10^n，让刻度显示成整数
  double _niceCeil(double v) {
    if (v <= 0) return 1;
    final exp = (math.log(v) / math.ln10).floor();
    final base = math.pow(10, exp).toDouble();
    final f = v / base;
    double nice;
    if (f <= 1) {
      nice = 1;
    } else if (f <= 2) {
      nice = 2;
    } else if (f <= 5) {
      nice = 5;
    } else {
      nice = 10;
    }
    return nice * base;
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) =>
      old.expense != expense || old.income != income;
}

/// 垂直柱状图：按星期分布等场景
class ColumnChart extends StatelessWidget {
  final List<Slice> slices;
  final double height;

  const ColumnChart({super.key, required this.slices, this.height = 170});

  @override
  Widget build(BuildContext context) {
    if (slices.isEmpty) {
      return SizedBox(
        height: height,
        child: const Center(
          child: Text('暂无数据',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        ),
      );
    }
    final maxV = slices.fold<double>(0.0, (m, e) => math.max(m, e.total));
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (int i = 0; i < slices.length; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      slices[i].total > 0 ? compactMoney(slices[i].total) : '',
                      style: const TextStyle(
                          fontSize: 9, color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 3),
                    LayoutBuilder(
                      builder: (ctx, c) {
                        final ratio = maxV <= 0
                            ? 0.0
                            : (slices[i].total / maxV)
                                .clamp(0.0, 1.0)
                                .toDouble();
                        const labelH = 20.0, gapH = 16.0;
                        final avail = height - labelH - gapH - 14;
                        return Container(
                          height: (avail * ratio).clamp(2.0, avail).toDouble(),
                          decoration: BoxDecoration(
                            color: AppColors.paletteAt(i),
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(4)),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 5),
                    SizedBox(
                      height: 20,
                      child: Text(
                        slices[i].label,
                        style: const TextStyle(
                            fontSize: 10, color: AppColors.textSecondary),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
