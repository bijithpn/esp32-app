import 'package:flutter/material.dart';

import 'anim_editor.dart';
import 'buddy.dart';
import 'canvas_editor.dart';
import 'eyes.dart';
import 'music.dart';
import 'pet.dart';
import 'pomodoro.dart';
import 'weather.dart';

/// Scenes that get their own screen in the app instead of the generic start sheet.
Widget? specialPage(String id) {
  switch (id) {
    case 'eyes':
      return const RobotEyesScreen();
    case 'pomo':
      return const PomodoroScreen();
    case 'pet':
      return const PetScreen();
    case 'weather':
      return const WeatherPage();
    case 'buddy':
      return const BuddyScreen();
    case 'canvas':
      return const CanvasEditorScreen();
    case 'anim':
      return const AnimEditorScreen();
    case 'bars':
    case 'nowplaying':
      return const MusicPage();
  }
  return null;
}
