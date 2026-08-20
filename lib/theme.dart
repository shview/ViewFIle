import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局主题：种子色 + 明暗模式，变更后 bump() 触发 MaterialApp 重建
class AppTheme {
  static const seedColors = <String, int>{
    '蓝': 0xFF4F8CFF,
    '紫': 0xFF9575FF,
    '青': 0xFF26A69A,
    '绿': 0xFF66BB6A,
    '橙': 0xFFFF8A65,
    '粉': 0xFFF06292,
    '红': 0xFFEF5350,
  };

  /// 通知 rebuild 的版本号
  static final changes = ValueNotifier<int>(0);
  static int seedValue = 0xFF4F8CFF;
  static int modeValue = 0; // 0=跟随系统 1=浅色 2=深色

  static ThemeMode get themeMode => switch (modeValue) {
        1 => ThemeMode.light,
        2 => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  static ThemeData get light => ThemeData(
        colorSchemeSeed: Color(seedValue),
        brightness: Brightness.light,
        useMaterial3: true,
      );

  static ThemeData get dark => ThemeData(
        colorSchemeSeed: Color(seedValue),
        brightness: Brightness.dark,
        useMaterial3: true,
      );

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    seedValue = p.getInt('seedColor') ?? 0xFF4F8CFF;
    modeValue = p.getInt('themeMode') ?? 0;
  }

  static Future<void> setSeed(int v) async {
    seedValue = v;
    (await SharedPreferences.getInstance()).setInt('seedColor', v);
    changes.value++;
  }

  static Future<void> setMode(int v) async {
    modeValue = v;
    (await SharedPreferences.getInstance()).setInt('themeMode', v);
    changes.value++;
  }
}
