import 'package:flutter/material.dart';

enum SceneCategory { ambient, productivity, information, entertainment, interactive, custom }

extension SceneCategoryText on SceneCategory {
  String get label => switch (this) {
        SceneCategory.ambient => 'Ambient',
        SceneCategory.productivity => 'Productivity',
        SceneCategory.information => 'Information',
        SceneCategory.entertainment => 'Entertainment',
        SceneCategory.interactive => 'Interactive',
        SceneCategory.custom => 'Custom',
      };
}

/// What the app knows about a scene beyond the name the board reports. This is the app-side description of the scenes
/// the firmware's scene table (SCENES[] in scenes2.h) contains; a scene the app does not know yet is shown under Custom
/// with a generic icon, so a newer firmware never hides a scene.
class SceneInfo {
  const SceneInfo(this.id, this.category, this.icon, this.blurb, {this.needs, this.hasPage = false});
  final String id;
  final SceneCategory category;
  final IconData icon;
  final String blurb;

  /// A capability the board must report (see /api/capabilities "features") for this scene to be useful.
  final String? needs;

  /// Has its own screen in the app (pomodoro, pet, ...) instead of the quick start sheet.
  final bool hasPage;
}

const sceneCatalog = <String, SceneInfo>{
  'eyes': SceneInfo('eyes', SceneCategory.interactive, Icons.remove_red_eye_rounded, 'Expressive robot eyes with 12 moods'),
  'char': SceneInfo('char', SceneCategory.interactive, Icons.emoji_nature_rounded, 'Your Muse character, alive on the display', hasPage: true),
  'ascii': SceneInfo('ascii', SceneCategory.interactive, Icons.bug_report_rounded, 'ASCII butterflies, koi, jellyfish, dragonflies, frogs, cranes and crabs. Tap to startle or feed them', hasPage: true),
  'buddy': SceneInfo('buddy', SceneCategory.interactive, Icons.smart_toy_rounded, 'A talking face for AI answers', hasPage: true),
  'pet': SceneInfo('pet', SceneCategory.interactive, Icons.pets_rounded, 'A pixel cat to feed, play with and pat', hasPage: true),
  'plasma': SceneInfo('plasma', SceneCategory.ambient, Icons.gradient_rounded, 'Slow colour clouds'),
  'stars': SceneInfo('stars', SceneCategory.ambient, Icons.auto_awesome_rounded, 'A starfield drifting past'),
  'matrix': SceneInfo('matrix', SceneCategory.ambient, Icons.code_rounded, 'Falling green code'),
  'life': SceneInfo('life', SceneCategory.ambient, Icons.grid_on_rounded, 'Conway\'s Game of Life'),
  'mandel': SceneInfo('mandel', SceneCategory.ambient, Icons.filter_vintage_rounded, 'Mandelbrot zoom'),
  'bounce': SceneInfo('bounce', SceneCategory.ambient, Icons.sports_basketball_rounded, 'A bouncing logo with your text'),
  'clock': SceneInfo('clock', SceneCategory.productivity, Icons.schedule_rounded, 'Analog clock (needs the time from the internet)'),
  'pomo': SceneInfo('pomo', SceneCategory.productivity, Icons.timer_rounded, 'Focus timer with breaks', hasPage: true),
  'weather': SceneInfo('weather', SceneCategory.information, Icons.wb_cloudy_rounded, 'Temperature, humidity and wind', needs: 'weather', hasPage: true),
  'ping': SceneInfo('ping', SceneCategory.information, Icons.network_check_rounded, 'Internet latency monitor'),
  'info': SceneInfo('info', SceneCategory.information, Icons.info_rounded, 'The Hub\'s address and status'),
  'pair': SceneInfo('pair', SceneCategory.information, Icons.qr_code_2_rounded, 'A QR code to pair another phone'),
  'nowplaying': SceneInfo('nowplaying', SceneCategory.entertainment, Icons.music_note_rounded, 'The song playing on your phone', needs: 'music', hasPage: true),
  'bars': SceneInfo('bars', SceneCategory.entertainment, Icons.equalizer_rounded, 'Music spectrum bars', needs: 'music', hasPage: true),
  'anim': SceneInfo('anim', SceneCategory.entertainment, Icons.animation_rounded, 'Your GIF or slideshow', needs: 'animations', hasPage: true),
  'canvas': SceneInfo('canvas', SceneCategory.custom, Icons.brush_rounded, 'Draw or send a photo', hasPage: true),
  'name': SceneInfo('name', SceneCategory.custom, Icons.badge_rounded, 'Your name in waves'),
  'message': SceneInfo('message', SceneCategory.interactive, Icons.chat_bubble_rounded, 'A message card'),
};

SceneInfo sceneInfo(String id) => sceneCatalog[id] ?? SceneInfo(id, SceneCategory.custom, Icons.apps_rounded, '');

/// The 13 moods the robot eyes support ("auto" lets the board choose by itself).
const moodsAll = ['auto', 'normal', 'happy', 'love', 'excited', 'surprised', 'wink', 'thinking', 'sleepy', 'sleeping', 'sad', 'angry', 'dizzy'];

/// Scenes that are system screens and not offered in the library.
const systemScenes = {'message'};
