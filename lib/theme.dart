import 'package:flutter/material.dart';

/// 全局配色与主题定义
///
/// 设计基调：深邃的靛蓝紫作为品牌主色，配合柔和的灰紫背景与大量留白，
/// 让数字信息在浅色卡片上更突出，整体观感更接近现代金融类应用。
class AppColors {
  // -------- 品牌主色：靛蓝紫，稳重且有一定科技感 --------
  static const Color primary = Color(0xFF5B5BD6);
  static const Color primaryDark = Color(0xFF4038A8);
  static const Color primaryLight = Color(0xFF8B8BE8);

  /// 点缀色：用于强调、徽标、渐变收尾
  static const Color accent = Color(0xFF00B8A9);

  // -------- 背景与容器 --------
  static const Color background = Color(0xFFF4F5FA);
  static const Color cardBg = Colors.white;

  /// 中性填充：chip、输入的浅底
  static const Color fill = Color(0xFFF1F2F7);
  static const Color fillStrong = Color(0xFFE6E7EF);

  // -------- 语义色（国内习惯：支出暖红、收入稳绿）--------
  static const Color expense = Color(0xFFE5484D);
  static const Color income = Color(0xFF12A150);

  // -------- 文字层级 --------
  static const Color textPrimary = Color(0xFF191A23);
  static const Color textSecondary = Color(0xFF6E7180);
  static const Color textTertiary = Color(0xFF9CA0AF);

  static const Color divider = Color(0xFFEDEEF4);

  /// 分类图表配色（12 色，保证饼图相邻扇区可区分）
  static const List<Color> chartPalette = [
    Color(0xFF5B5BD6),
    Color(0xFFE5484D),
    Color(0xFFF5A524),
    Color(0xFF00B8A9),
    Color(0xFF9333EA),
    Color(0xFF0EA5E9),
    Color(0xFF65A30D),
    Color(0xFFDB2777),
    Color(0xFF7C3AED),
    Color(0xFFF97316),
    Color(0xFF0284C7),
    Color(0xFF78716C),
  ];

  static Color paletteAt(int index) =>
      chartPalette[index % chartPalette.length];

  /// 预算/占比进度条的通用渐变
  static const LinearGradient brandGradient = LinearGradient(
    colors: [Color(0xFF6D5BE8), Color(0xFF4B3FC4)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

/// 统一圆角与阴影，避免各页面各写一套
class AppShape {
  static const double cardRadius = 16;
  static const double chipRadius = 10;

  static BorderRadius get card => BorderRadius.circular(cardRadius);

  /// 极轻的投影：让卡片"浮"在灰底上，但不喧宾夺主
  static List<BoxShadow> get softShadow => [
        BoxShadow(
          color: const Color(0xFF1F2233).withOpacity(0.05),
          blurRadius: 16,
          offset: const Offset(0, 4),
        ),
      ];

  /// 主色卡片的投影
  static List<BoxShadow> get brandShadow => [
        BoxShadow(
          color: AppColors.primary.withOpacity(0.28),
          blurRadius: 22,
          offset: const Offset(0, 10),
        ),
      ];
}

/// 主题构建
ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: false,
    primaryColor: AppColors.primary,
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: const ColorScheme.light(
      primary: AppColors.primary,
      secondary: AppColors.accent,
      surface: AppColors.cardBg,
    ),
  );

  return base.copyWith(
    // 页面标题栏改为与背景同色，靠左侧大标题建立层级（详见各页 header）
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      centerTitle: false,
      titleSpacing: 20,
      iconTheme: IconThemeData(color: AppColors.textPrimary),
      titleTextStyle: TextStyle(
        color: AppColors.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
      ),
    ),
    cardTheme: CardTheme(
      color: AppColors.cardBg,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: AppShape.card),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.divider,
      thickness: 1,
      space: 1,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
    ),
    dialogTheme: DialogTheme(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    ),
  );
}
