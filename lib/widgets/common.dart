import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// 日期选择封装（统一品牌配色）
///
/// 注意两点，都是为了规避「选完日期后页面被压暗、点不动」的问题：
/// 1. 不在这里传 locale。语言由 MaterialApp 的 supportedLocales 统一决定。
///    若在此处单独指定 locale，而 App 未注册对应的 localizationsDelegates，
///    showDatePicker 会因拿不到 MaterialLocalizations 而构建失败——弹层已入栈
///    但页面渲染不出来，留下一个空白且拦截全部点击的遮罩。
/// 2. builder 里不要用 Theme.of(ctx).copyWith(...) 新建 ColorScheme。
///    每次 rebuild 都产生新实例会让弹层陷入重建循环动画，表现为闪烁或卡在遮罩。
///    改用固定的 light 主题，保持实例稳定。
final ThemeData _datePickerTheme = ThemeData(
  useMaterial3: false,
  primaryColor: AppColors.primary,
  colorScheme: const ColorScheme.light(
    primary: AppColors.primary,
    onPrimary: Colors.white,
    secondary: AppColors.accent,
    surface: Colors.white,
    onSurface: AppColors.textPrimary,
  ),
  textTheme: const TextTheme().apply(
    bodyColor: AppColors.textPrimary,
    displayColor: AppColors.textPrimary,
  ),
);

Future<DateTime?> pickDate(
  BuildContext context, {
  required DateTime initial,
  DateTime? first,
  DateTime? last,
}) {
  return showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: first ?? DateTime(2000, 1, 1),
    lastDate: last ?? DateTime(2100, 12, 31),
    builder: (ctx, child) => Theme(
      data: _datePickerTheme,
      child: child ?? const SizedBox.shrink(),
    ),
  );
}

/// 统一的金额输入框：两位小数、数字键盘
class MoneyField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  const MoneyField({
    super.key,
    required this.controller,
    this.label = '金额',
    this.autofocus = false,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
      ],
      onSubmitted: onSubmitted,
      style: const TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        labelText: label,
        prefixText: '¥ ',
        prefixStyle: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: AppColors.textSecondary,
        ),
        filled: true,
        fillColor: AppColors.fill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      ),
    );
  }
}

/// 空状态占位：带柔和底圈，避免大片空白显得"坏了"
class EmptyState extends StatelessWidget {
  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  const EmptyState({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.07),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 38, color: AppColors.primaryLight),
            ),
            const SizedBox(height: 18),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                height: 1.6,
                color: AppColors.textSecondary,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: onAction,
                style: ElevatedButton.styleFrom(
                  primary: AppColors.primary,
                  onPrimary: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 26, vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(actionLabel!,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 轻提示
void showToast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 13.5)),
        duration: const Duration(milliseconds: 1800),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.textPrimary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
}

/// 带标题的小卡片容器
class SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  final EdgeInsets padding;
  final EdgeInsets margin;

  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.padding = const EdgeInsets.symmetric(vertical: 6),
    this.margin = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: AppColors.cardBg,
        borderRadius: AppShape.card,
        boxShadow: AppShape.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 15, 16, 2),
            child: Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                    letterSpacing: 0.2,
                  ),
                ),
                const Spacer(),
                if (trailing != null) trailing!,
              ],
            ),
          ),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// 分段控制器（支出/收入、按日/月/年 等场景复用）
///
/// 用主色滑块替代高亮填充，视觉更轻、切换更顺。
class SegmentTabs<T> extends StatelessWidget {
  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final Color Function(T)? colorOf;
  final ValueChanged<T> onChanged;

  const SegmentTabs({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
    this.colorOf,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.fill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: values.map((v) {
          final isSel = v == selected;
          final activeColor = colorOf?.call(v) ?? AppColors.primary;
          return Expanded(
            child: GestureDetector(
              onTap: () {
                if (isSel) return;
                onChanged(v);
              },
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isSel ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                  boxShadow: isSel
                      ? [
                          BoxShadow(
                            color: const Color(0xFF1F2233).withOpacity(0.07),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          )
                        ]
                      : null,
                ),
                child: Text(
                  labelOf(v),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
                    color: isSel ? activeColor : AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// 横向滚动的筛选 chip 条（账户筛选等）
class FilterChipBar extends StatelessWidget {
  final List<FilterChipItem> items;
  final String selected;
  final ValueChanged<String> onChanged;
  final EdgeInsets padding;

  const FilterChipBar({
    super.key,
    required this.items,
    required this.selected,
    required this.onChanged,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final item = items[i];
          final isSel = item.value == selected;
          return GestureDetector(
            onTap: () {
              if (isSel) return;
              onChanged(item.value);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 13),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isSel ? AppColors.primary : AppColors.fill,
                borderRadius: BorderRadius.circular(17),
                boxShadow: isSel
                    ? [
                        BoxShadow(
                          color: AppColors.primary.withOpacity(0.25),
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
                    item.icon,
                    size: 14,
                    color: isSel ? Colors.white : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    item.label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: isSel ? FontWeight.w600 : FontWeight.w500,
                      color: isSel ? Colors.white : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class FilterChipItem {
  final String value;
  final String label;
  final IconData icon;

  const FilterChipItem({
    required this.value,
    required this.label,
    required this.icon,
  });
}

/// 顶部周期切换器（左右翻页 + 中间可点选）
class PeriodSwitcher extends StatelessWidget {
  final String label;
  final String? subtitle;
  final bool canGoNext;
  final IconData centerIcon;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onTapCenter;

  const PeriodSwitcher({
    super.key,
    required this.label,
    required this.onPrev,
    required this.onNext,
    required this.onTapCenter,
    this.subtitle,
    this.canGoNext = true,
    this.centerIcon = Icons.expand_more,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _navBtn(Icons.chevron_left, onPrev, enabled: true),
        Expanded(
          child: GestureDetector(
            onTap: onTapCenter,
            behavior: HitTestBehavior.opaque,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 3),
                    Icon(centerIcon,
                        size: 19, color: AppColors.textTertiary),
                  ],
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                        fontSize: 11.5, color: AppColors.textSecondary),
                  ),
                ],
              ],
            ),
          ),
        ),
        _navBtn(Icons.chevron_right, onNext, enabled: canGoNext),
      ],
    );
  }

  Widget _navBtn(IconData icon, VoidCallback onTap, {required bool enabled}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: enabled ? AppColors.fill : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(
              icon,
              size: 22,
              color: enabled ? AppColors.textPrimary : AppColors.textTertiary,
            ),
          ),
        ),
      ),
    );
  }
}
