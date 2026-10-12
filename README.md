# accounting
一款**纯本地**的 Android 记账应用，专注个人收支记录、可视化分析与报销/平摊场景。所有数据存储在手机本地 SQLite，**不联网、不上传、无账号系统**，隐私完全由你自己掌控。

> 完整使用说明与功能口径见仓库内 [使用说明.md](./使用说明.md)。

## 功能特性

- **多账户管理**：支持现金、银行卡、支付宝、微信等账户，记录期初余额，自动计算各账户真实余额。
- **收支记账**：支出 / 收入分类记账，支持备注、日期、账户维度。
- **转账**：账户间互转单独记录，**不计入收支统计**，避免口径污染。
- **报销合并记账**：一笔报销可关联**多笔**消费账单，按净额记账（消费 − 报销），并支持与朋友**按比例平摊**；报销大于消费合计时，差额按净收入计入；多笔报销砸同一笔支出时按原额封顶
- **月度预算**：自定义月总预算与周期起始日（如发薪日 25 号起算），分析页实时显示剩余额度、进度与日均可用
- **可视化分析**：按日/月/年统计收支趋势，手绘图表展示，提供消费洞察。
- **Excel 导出**：按年/月/日维度导出账单明细到 Excel（含"自付金额"列）。
- **数据本地化**：SQLite 本地存储，数据库随应用版本平滑迁移，旧数据自动保留。

## 技术栈

| 层 | 技术 |
|---|---|
| 框架 | Flutter 3.0.0 / Dart 2.17 |
| 存储 | sqflite (SQLite) |
| 导出 | excel |
| 分享 | share_plus |
| 图表 | 自绘 CustomPainter |

## 环境要求

- Flutter SDK 3.0.x
- Dart 2.17.x
- Android SDK（compileSdk 33）
- JDK 17

> 国内网络可配置镜像加速：
> ```bash
> export PUB_HOSTED_URL=https://pub.flutter-io.cn
> export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
> ```

## 构建与运行

```bash
# 安装依赖
flutter pub get

# 调试运行
flutter run

# 构建 release APK
flutter build apk --release
# 产物位于 build/app/outputs/flutter-apk/app-release.apk
```

## 目录结构

```
lib/
  models.dart        # 数据模型（BillRecord / TransferRecord / AccountDef / BudgetSettings）
  db.dart            # 数据库与迁移（v1→v6 幂等迁移，含 settings 预算设置表）
  stats.dart         # 统计与净额核算 + 预算周期/剩余口径
  exporter.dart      # Excel 导出
  pages/             # 各页面（记账、明细、统计、账户、转账）
  widgets/           # 复用组件
test/                # 单元测试（报销/预算/导出/口径守恒等 120+ 用例）
```

## 隐私说明

- 所有账单数据仅存储在设备本地数据库（`/data/data/<包名>/databases/`）。
- 应用不申请网络权限，不与任何服务器通信。
- **开源贡献提醒**：请勿将包含真实账单的数据库文件（`.db`）提交到仓库。

## 开源协议

本项目基于 [MIT License](./LICENSE) 开源。你可以自由使用、修改、再发布，只需保留版权声明。

## 贡献

欢迎提交 Issue 与 Pull Request。提交前请运行：

```bash
flutter analyze
flutter test
```
