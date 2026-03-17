import 'package:flutter/material.dart';
import 'app.dart';
import 'core/di/app_registry.dart';

void main() {
  final registry = buildAppRegistry();
  runApp(MapNowoeApp(registry: registry));
}
