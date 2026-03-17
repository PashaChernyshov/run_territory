import 'package:shared_preferences/shared_preferences.dart';

class PrefsStore {
  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  String? getString(String key) => _prefs?.getString(key);
  double? getDouble(String key) => _prefs?.getDouble(key);
  bool? getBool(String key) => _prefs?.getBool(key);

  Future<void> setString(String key, String value) async =>
      (await SharedPreferences.getInstance()).setString(key, value);
  Future<void> setDouble(String key, double value) async =>
      (await SharedPreferences.getInstance()).setDouble(key, value);
  Future<void> setBool(String key, bool value) async =>
      (await SharedPreferences.getInstance()).setBool(key, value);
}
