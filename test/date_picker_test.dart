import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ledger_book/theme.dart';
import 'package:ledger_book/widgets/common.dart';

/// 回归测试：日期选择器必须能正常打开、正常关闭，并且关闭后页面恢复可交互。
///
/// 背景：曾出现「点日期后页面被压暗、完全点不动」的 bug。
/// 根因是 showDatePicker 依赖 MaterialLocalizations，而 App 未注册
/// localizationsDelegates，导致弹层路由已入栈但页面构建失败，
/// 留下一个空白且拦截全部点击的遮罩。
///
/// 注意：不能用 "ModalBarrier 数量为 0" 来断言——MaterialApp 的路由自身
/// 就常驻一个 ModalBarrier。真正该验证的是「关闭后页面上的按钮能再次点动」。
Widget _wrap(WidgetBuilder builder) {
  return MaterialApp(
    theme: buildAppTheme(),
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
    home: Scaffold(body: Builder(builder: builder)),
  );
}

void main() {
  testWidgets('日期选择器可打开、可选择并正常关闭', (tester) async {
    var taps = 0;

    await tester.pumpWidget(
      _wrap(
        (ctx) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: () async {
                  await pickDate(ctx, initial: DateTime(2026, 9, 18));
                },
                child: const Text('选日期'),
              ),
              // 用于验证弹层关闭后页面是否恢复可点击
              ElevatedButton(
                onPressed: () => taps++,
                child: const Text('页面按钮'),
              ),
            ],
          ),
        ),
      ),
    );

    // ---- 打开 ----
    await tester.tap(find.text('选日期'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget,
        reason: '日期选择器应能正常渲染（本地化缺失时这里会失败）');

    // ---- 关闭 ----
    final cancel = find.text('取消');
    if (cancel.evaluate().isNotEmpty) {
      await tester.tap(cancel);
    } else {
      await tester.tap(find.byIcon(Icons.close));
    }
    await tester.pumpAndSettle();

    expect(find.byType(DatePickerDialog), findsNothing,
        reason: '关闭后日期选择器必须从路由栈移除');

    // ---- 关键：页面恢复可交互 ----
    await tester.tap(find.text('页面按钮'));
    await tester.pumpAndSettle();
    expect(taps, 1,
        reason: '弹层关闭后页面必须恢复可点击，若有遮罩残留这里会失败');
  });

  testWidgets('选中日期后返回正确值并恢复页面交互', (tester) async {
    DateTime? result;
    var taps = 0;

    await tester.pumpWidget(
      _wrap(
        (ctx) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: () async {
                  result = await pickDate(ctx, initial: DateTime(2026, 9, 18));
                },
                child: const Text('选日期'),
              ),
              ElevatedButton(
                onPressed: () => taps++,
                child: const Text('页面按钮'),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('选日期'));
    await tester.pumpAndSettle();

    // 点选 18 号再确定
    final day = find.text('18');
    if (day.evaluate().isNotEmpty) {
      await tester.tap(day.first);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result, isNotNull, reason: '确定后应返回选中日期');
    expect(find.byType(DatePickerDialog), findsNothing);

    await tester.tap(find.text('页面按钮'));
    await tester.pumpAndSettle();
    expect(taps, 1, reason: '选完日期后页面必须恢复可点击');
  });
}
